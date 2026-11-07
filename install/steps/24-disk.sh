#!/usr/bin/env bash
# 第 24 站：磁碟與容量 —— broker 資料盤怎麼看、怎麼警、快滿時怎麼做（手把手第 24 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；裝好、第 17 站做過之後跑 alerts 一次；usage 隨時可跑；drill 是 lab／驗收用）
#
# 做什麼：
#   bash steps/24-disk.sh usage    24.1 每個 broker 的資料盤：log dir 合計、partition 數、最大的三個 topic；每台 df
#   bash steps/24-disk.sh alerts   24.2 給銀行監控團隊第二個規則檔 to-bank/prometheus/confluent-alerts-disk.yml（資料盤用量範例；log dir 離線已在第 17 章的規則）
#   bash steps/24-disk.sh drill    24.3 演練：建 orders.disk-demo 寫 5 MB → 縮短 retention 等 segment 被刪 → 再寫一次、把 partition 搬離第一台 broker → 清掉
#
# 擴容（24.4）是銀行 OS 團隊放大資料盤；換碟同 25.2（remove → 換 → add），不在這支。
#
# 需要什麼：第 14 站的檢查正常；alerts 要第 17 站做過；drill 要第 11 站的第一個 SCRAM 應用程式（client 設定檔）。
# 產出什麼：usage 只讀；alerts 在 ~/monitoring/to-bank/prometheus/ 多一個規則檔；drill 跑完不留東西。
# 能不能重跑：都可以（alerts 覆蓋同一個檔；drill 的 topic 用 --if-not-exists，最後刪掉）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-usage}
TEMPLATE_DIR=$INSTALL_DIR/templates
BANK_OUT=$MONITORING_DIR/to-bank
DEMO_TOPIC=orders.disk-demo
REASSIGN_JSON=$CONF_DIR/disk-demo-reassign.json
ADMIN=(--bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF")

# 在 broker 上印一行資料盤用量（df 看掛載點 /var/lib/kafka）
#   例：kb01: /dev/sdb1 用 149G / 1007G（16%）掛在 /var/lib/kafka
DISK_USAGE_LINE=$(cat <<'EOF'
if ! df_output=$(df -h /var/lib/kafka); then
  exit 1
fi

# df 第二行的欄位：裝置 總量 已用 可用 百分比 掛載點
read -r device size used available percent mount_point _ < <(tail -n +2 <<<"$df_output")

printf '%s: %s 用 %s / %s（%s）掛在 %s\n' "$HOST_SHORT_NAME" "$device" "$used" "$size" "$percent" "$mount_point"
EOF
)

# log_dirs_json <kafka-log-dirs 的其他參數…>：kafka-log-dirs 的 JSON（最後一行才是 JSON，前面是工具的提示）
log_dirs_json() {
  kafka-log-dirs "${ADMIN[@]}" --describe "$@" 2>/dev/null | tail -1
}

# partition_records <kafka-log-dirs 的其他參數…>：把 JSON 攤平成一個 partition 一行「broker log-dir partition 位元組」
#   不靠欄位順序：先拆成一行一個 token，大括號的層數決定在哪一層（2 = broker、3 = log dir、4 = partition）。
#   沒有任何 partition 的 log dir 印一行，partition 欄是「-」（這樣空的 broker 也看得到）。
#   輸入：{"brokers":[{"broker":101,"logDirs":[{"logDir":"/var/lib/kafka/data","error":null,"partitions":[{"partition":"orders.events-0","size":5498880,"offsetLag":0,"isFuture":false}]}]}],"version":1}
#   輸出：101 /var/lib/kafka/data orders.events-0 5498880
partition_records() {
  local token_pattern='[{}]|"broker":[0-9]+|"logDir":"[^"]*"|"partition":"[^"]*"|"size":[0-9]+'

  # lint-ok: 要照大括號層數攤平 JSON（主機沒有 jq），grep／cut 做不到；函式上面有輸入輸出例子
  log_dirs_json "$@" | grep -oE "$token_pattern" | awk -F'[:"]+' '
    /^\{/ {
      depth++
      next
    }
    /^\}/ {
      if (depth == 4) {
        partition_count++
        names[partition_count] = partition
        sizes[partition_count] = size
      }
      if (depth == 3) {
        if (partition_count == 0) {
          lines[++line_count] = log_dir " - 0"
        }
        for (i = 1; i <= partition_count; i++) {
          lines[++line_count] = log_dir " " names[i] " " sizes[i]
        }
        partition_count = 0
      }
      if (depth == 2) {
        for (i = 1; i <= line_count; i++) {
          print broker, lines[i]
        }
        line_count = 0
      }
      depth--
      next
    }
    /"broker"/    { broker = $3 }
    /"logDir"/    { log_dir = $3 }
    /"partition"/ { partition = $3 }
    /"size"/      { size = $3 }
  '
}

# usage_report：每個 broker 的每個 log dir 一行：合計、partition 數、最大的三個 topic
#   輸入（partition_records）：101 /var/lib/kafka/data orders.events-0 5498880
#   輸出：broker 101 /var/lib/kafka/data: 9.1 MB, 150 partitions; 最大: _confluent-telemetry-metrics 8.0 MB, __consumer_offsets 0.4 MB, orders.load 0.2 MB
usage_report() {
  # 第一段：每個 topic 一行「broker log-dir log-dir合計 partition數 topic topic合計」；sort：依 broker、log dir、topic 合計由大到小
  # 第二段：同一個 log dir 的頭三個 topic 接在同一行
  partition_records | awk '
    {
      key = $1 " " $2
      if ($3 != "-") {
        topic = $3
        sub(/-[0-9]+$/, "", topic)
        total[key] += $4
        partitions[key]++
        topic_total[key " " topic] += $4
      } else {
        total[key] += 0
      }
    }
    END {
      for (item in topic_total) {
        split(item, field, " ")
        key = field[1] " " field[2]
        print key, total[key], partitions[key] + 0, field[3], topic_total[item]
        seen[key] = 1
      }
      for (key in total) {
        if (!(key in seen)) {
          print key, 0, 0, "-", 0
        }
      }
    }
  ' | sort -k1,1n -k2,2 -k6,6nr | awk '
    function finish_line() {
      if (current != "") {
        print current
      }
    }
    {
      key = $1 " " $2
      if (key != last_key) {
        finish_line()
        last_key = key
        shown = 0
        current = sprintf("broker %s %s: %.1f MB, %d partitions; 最大: ", $1, $2, $3 / 1048576, $4)
      }
      if ($5 != "-" && shown < 3) {
        current = current (shown > 0 ? ", " : "") sprintf("%s %.1f MB", $5, $6 / 1048576)
        shown++
      }
    }
    END {
      finish_line()
    }
  '
}

usage() {
  local report host

  # 1. Kafka 自己知道每個 partition 占多少，不用 ssh 進主機
  section "24.1 每個 broker 的 log dir：合計、partition 數、最大的三個 topic（kafka-log-dirs）"
  report=$(usage_report)

  if [ -z "$report" ]; then
    fail "kafka-log-dirs"
  else
    tee -a "$LOG_FILE" <<<"$report"
  fi

  # 2. 資料盤本身還剩多少：df 看掛載點 /var/lib/kafka（資料目錄是 0750，掛載點 cpuser 不用 sudo）
  section "24.1 每台 broker 的資料盤（df）"

  for host in $BROKERS; do
    if ! ssh_script "$host" HOST_SHORT_NAME="$host" <<<"$DISK_USAGE_LINE" | tee -a "$LOG_FILE"; then
      fail "$host df"
    fi
  done

  log "（lab 的資料盤是容器的 overlay，顯示整個根目錄；正式環境 /var/lib/kafka 要是獨立掛載點）"
}

alerts() {
  local rules_file=$BANK_OUT/prometheus/confluent-alerts-disk.yml
  local rule_count message

  section "24.2 給銀行監控團隊：to-bank/prometheus/confluent-alerts-disk.yml"

  if [ ! -d "$BANK_OUT/prometheus" ]; then
    die "沒有 $BANK_OUT/prometheus：先跑第 17 站"
  fi

  if ! cp "$TEMPLATE_DIR/confluent-alerts-disk.yml" "$rules_file"; then
    die "複製規則檔失敗"
  fi

  rule_count=$(awk '/alert:/ {c++} END {print c + 0}' "$rules_file")
  ok "confluent-alerts-disk.yml：$rule_count 條（KafkaDataDiskFillingUp，給銀行 node_exporter 的範例）"
  message="監控團隊：confluent-alerts-disk.yml 放到 /etc/prometheus/confluent/"
  message+="（rule_files 用 confluent-alerts*.yml 就會載入）後 reload；"
  message+="KafkaDataDiskFillingUp 的 mountpoint／job 改成行內 node_exporter 的寫法"
  ask_bank "$message"
}

# demo_sizes：演練 topic 每個 replica 的 KB，一行
#   例：broker 101 5370 KB, broker 102 5370 KB, broker 103 5370 KB
demo_sizes() {
  partition_records --topic-list "$DEMO_TOPIC" | sort -k1,1n | awk '
    $3 != "-" {
      printf "%sbroker %s %d KB", separator, $1, $4 / 1024
      separator = ", "
    }
    END {
      print ""
    }
  '
}

# write_demo_records：寫 50000 筆 × 100 B（用第一個 SCRAM 應用程式的帳號）；全部送出回 0
write_demo_records() {
  local result

  result=$(kafka-producer-perf-test --topic "$DEMO_TOPIC" --num-records 50000 --throughput -1 --record-size 100 \
    --producer.config "$CONF_DIR/$FIRST_SCRAM_APP.properties" --producer-props "bootstrap.servers=$BROKER_CLIENT" 2>&1)

  grep -q '^50000 records sent' <<<"$result"
}

# host_of_broker_id <node id>：這個 node id 是哪一台 broker，例：101 → kb01
host_of_broker_id() {
  local host

  for host in $BROKERS; do
    if [ "$(node_id_of "$host")" = "$1" ]; then
      echo "$host"
      return
    fi
  done
}

drill() {
  local first_id first_host other_ids round sizes before after verify_result replica_count directory_count
  local replicas_text all_ids lowest_ids

  # 1. 示範 topic：1 個 partition、3 份 replica、segment 1 MB（預設 1 GB，這樣才看得到 segment 被刪）
  section "24.3 演練：$DEMO_TOPIC（segment 1 MB）寫 50000 筆 × 100 B"

  if ! kafka-topics "${ADMIN[@]}" --create --if-not-exists --topic "$DEMO_TOPIC" \
       --partitions 1 --replication-factor 3 --config segment.bytes=1048576 >/dev/null 2>&1; then
    die "建 $DEMO_TOPIC 失敗"
  fi

  if ! write_demo_records; then
    die "寫入失敗"
  fi

  sleep 3
  before=$(demo_sizes)
  log "寫入後：$before"

  if grep -qE '[4-9][0-9]{3} KB' <<<"$before"; then
    ok "每個 replica 約 5 MB（多個 segment）"
  else
    fail "寫入後大小不如預期：$before"
  fi

  # 2. ① 縮短 retention：每 10 秒看一次，最多 42 次（7 分鐘）
  section "24.3 ① 縮短 retention（retention.ms=60000），等 broker 的 retention 檢查（預設每 5 分鐘）刪掉關掉的 segment"

  if ! kafka-configs "${ADMIN[@]}" --alter --entity-type topics --entity-name "$DEMO_TOPIC" \
       --add-config retention.ms=60000 >/dev/null 2>&1; then
    die "改 retention.ms 失敗"
  fi

  for round in $(seq 1 42); do
    sizes=$(demo_sizes)

    if ! grep -qE '[1-9][0-9]{3} KB' <<<"$sizes"; then
      break
    fi

    sleep 10
  done

  if grep -qE '[1-9][0-9]{3} KB' <<<"$sizes"; then
    fail "等了 $((round * 10)) 秒 segment 還在：$sizes"
  else
    ok "約 $((round * 10)) 秒後只剩現用的 segment：$sizes"
  fi

  # 事後改回 broker 預設
  kafka-configs "${ADMIN[@]}" --alter --entity-type topics --entity-name "$DEMO_TOPIC" \
    --delete-config retention.ms >/dev/null 2>&1
  log "retention.ms 已改回 broker 預設"

  # 3. ② 再寫一次，讓它有東西可搬；新的 replica 名單不含第一台
  section "24.3 ② 把 partition 搬離第一台 broker（kafka-reassign-partitions）"

  if ! write_demo_records; then
    die "寫入失敗"
  fi

  sleep 3
  log "搬之前：$(demo_sizes)"

  # 第一份 replica 在哪台。例：Replicas: 101,102,103 → 101
  replicas_text=$(kafka-topics "${ADMIN[@]}" --describe --topic "$DEMO_TOPIC" 2>/dev/null | grep -o 'Replicas: [0-9,]*')
  first_id=$(cut -d' ' -f2 <<<"$replicas_text" | cut -d, -f1)
  first_host=$(host_of_broker_id "$first_id")

  # 其他 broker 取編號最小的三台，逗號分隔。例：102,103,104
  all_ids=$(kafka-broker-api-versions "${ADMIN[@]}" 2>/dev/null | grep -o 'id: [0-9]*' | cut -d' ' -f2)
  lowest_ids=$(grep -vx "$first_id" <<<"$all_ids" | sort -n | head -3)
  other_ids=$(paste -sd, <<<"$lowest_ids")
  replica_count=$(tr ',' '\n' <<<"$other_ids" | wc -l)

  if [ "$replica_count" != 3 ]; then
    die "找不到三台其他 broker（有：$other_ids）"
  fi

  printf '{"version":1,"partitions":[{"topic":"%s","partition":0,"replicas":[%s]}]}\n' \
    "$DEMO_TOPIC" "$other_ids" > "$REASSIGN_JSON"

  # 4. 開始搬，等 --verify 說 completed：每 5 秒看一次，最多 30 次
  if ! kafka-reassign-partitions "${ADMIN[@]}" --reassignment-json-file "$REASSIGN_JSON" --execute >/dev/null 2>&1; then
    die "reassign --execute 失敗"
  fi

  for round in $(seq 1 30); do
    verify_result=$(kafka-reassign-partitions "${ADMIN[@]}" \
      --reassignment-json-file "$REASSIGN_JSON" --verify 2>/dev/null)

    if grep -q 'is completed' <<<"$verify_result"; then
      break
    fi

    sleep 5
  done

  after=$(demo_sizes)

  if grep -q "broker $first_id " <<<"$after"; then
    fail "broker $first_id 上還有 replica：$after"
  else
    ok "replica 從 broker $first_id 搬到 $other_ids：$after"
  fi

  # 5. 第一台上那個 partition 的目錄要消失（資料目錄是 0750，萬用字元由 cpuser 展開時讀不到，所以用 sudo find；名稱完全相同才算）
  sleep 5
  directory_count=$(ssh_run "$first_host" "sudo find /var/lib/kafka/data -maxdepth 1 -name $DEMO_TOPIC-0" \
    | wc -l)

  if [ "$directory_count" = 0 ]; then
    ok "$first_host 上的目錄：不存在"
  else
    fail "$first_host 上的目錄：還在"
  fi

  # 6. 清掉示範 topic
  section "24.3 清掉演練物件"
  kafka-topics "${ADMIN[@]}" --delete --topic "$DEMO_TOPIC" >/dev/null 2>&1
  rm -f "$REASSIGN_JSON"
  log "已刪 $DEMO_TOPIC"
}

case $ACTION in
  usage)
    usage
    [ "$FAIL_COUNT" = 0 ]
    ;;
  alerts)
    alerts
    finish_step
    ;;
  drill)
    drill
    [ "$FAIL_COUNT" = 0 ]
    ;;
  *)
    sed -n '2,11p' "$0"
    exit 1
    ;;
esac
