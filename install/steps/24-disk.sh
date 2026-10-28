#!/usr/bin/env bash
# 第 24 站：磁碟與容量 —— broker 資料盤怎麼看、怎麼警、快滿時怎麼做（手把手第 24 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；裝好、第 17 站做過之後跑 alerts 一次；usage 隨時可跑；drill 是 lab／驗收用）
#
# 用法：
#   bash steps/24-disk.sh usage    24.1 每個 broker 的資料盤：log dir 合計、partition 數、最大的三個 topic；每台 df
#   bash steps/24-disk.sh alerts   24.2 給銀行監控團隊第二個規則檔 to-bank/prometheus/confluent-alerts-disk.yml（KafkaLogDirOffline、資料盤用量範例）
#   bash steps/24-disk.sh drill    24.3 演練：建 orders.disk-demo 寫 5 MB → 縮短 retention 等 segment 被刪 → 把 partition 搬離第一台 broker → 清掉
#
# 擴容（24.4）是銀行 OS 團隊放大資料盤；換碟同 25.2（remove → 換 → add），不在這支。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-usage}
TEMPLATE_DIR=$INSTALL_DIR/templates
BANK_OUT=$MONITORING_DIR/to-bank
DEMO_TOPIC=orders.disk-demo
ADMIN=(--bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF")

# log_dirs_json：kafka-log-dirs 的 JSON（最後一行才是 JSON，前面是工具的提示）
log_dirs_json() { kafka-log-dirs "${ADMIN[@]}" --describe "$@" 2>/dev/null | tail -1; }

usage() {
  section "24.1 每個 broker 的 log dir：合計、partition 數、最大的三個 topic（kafka-log-dirs）"
  log_dirs_json | python3 -c '
import json, sys, collections
d = json.load(sys.stdin)
for b in sorted(d["brokers"], key=lambda b: b["broker"]):
    for ld in b["logDirs"]:
        by = collections.Counter()
        for p in ld["partitions"]:
            by[p["partition"].rsplit("-", 1)[0]] += p["size"]
        top = ", ".join("%s %.1f MB" % (t, s / 1048576) for t, s in by.most_common(3))
        print("broker %s %s: %.1f MB, %d partitions; 最大: %s" % (b["broker"], ld["logDir"], sum(by.values()) / 1048576, len(ld["partitions"]), top))' | tee -a "$LOG_FILE" || fail "kafka-log-dirs"
  section "24.1 每台 broker 的資料盤（df）"
  local h
  for h in $BROKERS; do
    ssh "$(fqdn "$h")" "df -h /var/lib/kafka | awk 'NR==2 {printf \"%s: %s 用 %s / %s（%s）掛在 %s\n\", \"$h\", \$1, \$3, \$2, \$5, \$6}'" | tee -a "$LOG_FILE" || fail "$h df"
  done
  log "（lab 的資料盤是容器的 overlay，顯示整個根目錄；正式環境 /var/lib/kafka 要是獨立掛載點）"
}

alerts() {
  section "24.2 給銀行監控團隊：to-bank/prometheus/confluent-alerts-disk.yml"
  [ -d "$BANK_OUT/prometheus" ] || die "沒有 $BANK_OUT/prometheus：先跑第 17 站"
  cp "$TEMPLATE_DIR/confluent-alerts-disk.yml" "$BANK_OUT/prometheus/confluent-alerts-disk.yml" || die "複製規則檔失敗"
  ok "confluent-alerts-disk.yml：$(grep -c 'alert:' "$BANK_OUT/prometheus/confluent-alerts-disk.yml") 條（KafkaLogDirOffline；KafkaDataDiskFillingUp 是給銀行 node_exporter 的範例）"
  ask_bank "監控團隊：confluent-alerts-disk.yml 放到 /etc/prometheus/confluent/（rule_files 用 confluent-alerts*.yml 就會載入）後 reload；KafkaDataDiskFillingUp 的 mountpoint／job 改成行內 node_exporter 的寫法"
}

# demo_sizes：演練 topic 每個 replica 的 KB，一行
demo_sizes() {
  log_dirs_json --topic-list "$DEMO_TOPIC" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(", ".join("broker %s %d KB" % (b["broker"], p["size"] // 1024) for b in sorted(d["brokers"], key=lambda b: b["broker"]) for ld in b["logDirs"] for p in ld["partitions"]))'
}

drill() {
  local first_id other_ids i s before after
  section "24.3 演練：$DEMO_TOPIC（segment 1 MB）寫 50000 筆 × 100 B"
  kafka-topics "${ADMIN[@]}" --create --if-not-exists --topic "$DEMO_TOPIC" --partitions 1 --replication-factor 3 --config segment.bytes=1048576 >/dev/null 2>&1 || die "建 $DEMO_TOPIC 失敗"
  kafka-producer-perf-test --topic "$DEMO_TOPIC" --num-records 50000 --throughput -1 --record-size 100 \
    --producer.config "$CONF_DIR/$FIRST_SCRAM_APP.properties" --producer-props "bootstrap.servers=$BROKER_CLIENT" 2>&1 | grep -q '^50000 records sent' || die "寫入失敗"
  sleep 3; before=$(demo_sizes); log "寫入後：$before"
  grep -qE '[4-9][0-9]{3} KB' <<<"$before" && ok "每個 replica 約 5 MB（多個 segment）" || fail "寫入後大小不如預期：$before"
  section "24.3 ① 縮短 retention（retention.ms=60000），等 broker 的 retention 檢查（預設每 5 分鐘）刪掉關掉的 segment"
  kafka-configs "${ADMIN[@]}" --alter --entity-type topics --entity-name "$DEMO_TOPIC" --add-config retention.ms=60000 >/dev/null 2>&1 || die "改 retention.ms 失敗"
  for i in $(seq 1 45); do s=$(demo_sizes); grep -qE '[1-9][0-9]{3} KB' <<<"$s" || break; sleep 10; done
  if grep -qE '[1-9][0-9]{3} KB' <<<"$s"; then fail "等了 $((i*10)) 秒 segment 還在：$s"; else ok "約 $((i*10)) 秒後只剩現用的 segment：$s"; fi
  section "24.3 ② 把 partition 搬離第一台 broker（kafka-reassign-partitions）"
  first_id=$(kafka-topics "${ADMIN[@]}" --describe --topic "$DEMO_TOPIC" 2>/dev/null | grep -o 'Replicas: [0-9,]*' | cut -d' ' -f2 | cut -d, -f1)
  other_ids=$(kafka-broker-api-versions "${ADMIN[@]}" 2>/dev/null | grep -o 'id: [0-9]*' | awk -v f="$first_id" '$2 != f {print $2}' | sort -n | head -3 | paste -sd,)
  [ "$(tr ',' '\n' <<<"$other_ids" | wc -l)" = 3 ] || die "找不到三台其他 broker（有：$other_ids）"
  printf '{"version":1,"partitions":[{"topic":"%s","partition":0,"replicas":[%s]}]}\n' "$DEMO_TOPIC" "$other_ids" > "$CONF_DIR/disk-demo-reassign.json"
  kafka-reassign-partitions "${ADMIN[@]}" --reassignment-json-file "$CONF_DIR/disk-demo-reassign.json" --execute >/dev/null 2>&1 || die "reassign --execute 失敗"
  for i in $(seq 1 30); do kafka-reassign-partitions "${ADMIN[@]}" --reassignment-json-file "$CONF_DIR/disk-demo-reassign.json" --verify 2>/dev/null | grep -q 'is completed' && break; sleep 5; done
  after=$(demo_sizes)
  if grep -q "broker $first_id " <<<"$after"; then fail "broker $first_id 上還有 replica：$after"; else ok "replica 從 broker $first_id 搬到 $other_ids：$after"; fi
  section "24.3 清掉演練物件"
  kafka-topics "${ADMIN[@]}" --delete --topic "$DEMO_TOPIC" >/dev/null 2>&1; rm -f "$CONF_DIR/disk-demo-reassign.json"
  log "已刪 $DEMO_TOPIC"
}

case $ACTION in
  usage)  usage; [ "$FAIL_COUNT" = 0 ];;
  alerts) alerts; finish_step;;
  drill)  drill; [ "$FAIL_COUNT" = 0 ];;
  *) sed -n '2,12p' "$0"; exit 1;;
esac
