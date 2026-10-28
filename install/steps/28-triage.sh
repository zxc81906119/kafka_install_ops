#!/usr/bin/env bash
# 第 28 站：故障排查速查 —— 一分鐘快照、「一台 broker 掉了」的演練（手把手第 28 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；出事先跑 snapshot；drill／recover 是 lab 與驗收用）
#
# 用法：
#   bash steps/28-triage.sh snapshot            28.2 quorum leader、broker 在線、under-replicated／offline、每台 MDS、REST 經 LB、C3（全綠 rc 0，否則 rc 1）
#   bash steps/28-triage.sh drill <broker>      28.3 broker 已被銀行停掉（lab：bank-sim.sh broker-stop）：確認症狀（在線少一台、under-replicated > 0、那台 MDS 連不上、REST／C3 照常）
#   bash steps/28-triage.sh recover <broker>    28.3 ssh 過去 systemctl restart（cpuser-ops 允許的寫法），等 under-replicated 歸零、MDS 回 200
#
# 告警（ConfluentTargetDown、KafkaUnderReplicatedPartitions）在銀行 Prometheus 看：lab 用 bank-sim.sh alerts-wait／alerts-clear。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-snapshot}
# 管理 client 的 bootstrap 給所有 broker：出事的可能就是第一台
ADMIN=(--bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF")
REST_APP=$FIRST_REST_APP

leader_id()   { kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null | grep -oE '^LeaderId: *[0-9]+' | grep -oE '[0-9]+'; }
online()      { kafka-broker-api-versions "${ADMIN[@]}" 2>/dev/null | grep -oE '^[a-z0-9.-]+:[0-9]+' | cut -d: -f1 | cut -d. -f1 | sort | paste -sd' '; }
under_rep()   { kafka-topics "${ADMIN[@]}" --describe --under-replicated-partitions 2>/dev/null | grep -c 'Partition:'; }
offline()     { kafka-topics "${ADMIN[@]}" --describe --unavailable-partitions 2>/dev/null | grep -c 'Partition:'; }
mds_code()    { curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://$(fqdn "$1"):8090/v1/metadata/id"; }
rest_code()   { curl -s -m 30 -o /dev/null -w '%{http_code}' --cacert "$CERTS_DIR/bank-root.pem" --cert "$CERTS_DIR/$REST_APP.crt" --key "$KEYS_DIR/$REST_APP.key" "https://$REST_VIP:8082/v3/clusters"; }
c3_code()     { curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$C3_FQDN:9021/"; }

snapshot() {
  local leader on ur off mds h bad=0 n
  section "28.2 一分鐘快照"
  leader=$(leader_id); on=$(online); ur=$(under_rep); off=$(offline)
  n=$(wc -w <<<"$on"); mds=$(for h in $BROKERS; do printf '%s=%s ' "$h" "$(mds_code "$h")"; done)
  log "quorum leader：${leader:-無}；broker 在線：$n / $(wc -w <<<"$BROKERS")（$on）"
  log "under-replicated：$ur；offline：$off"
  log "MDS：$mds"
  log "REST 經 LB：$(rest_code)；C3：$(c3_code)"
  [ -n "$leader" ] || { fail "controller 沒有 leader"; bad=1; }
  [ "$n" = "$(wc -w <<<"$BROKERS")" ] || { fail "broker 不是全部在線"; bad=1; }
  [ "$ur" = 0 ] && [ "$off" = 0 ] || { fail "有 under-replicated／offline partition"; bad=1; }
  grep -qv '=200' <<<"$(tr ' ' '\n' <<<"$mds" | grep .)" && { fail "有 broker 的 MDS 不回 200"; bad=1; }
  [ "$bad" = 0 ] && ok "全綠"
  return $bad
}

drill() {   # drill <broker>：那台已被停掉，確認症狀
  local b=$1 on ur off code rest c3 missing
  [ -n "$b" ] || die "用法：$0 drill <broker>"
  section "28.3 症狀：$b 的服務被停掉之後"
  on=$(online); ur=$(under_rep); off=$(offline); code=$(mds_code "$b"); rest=$(rest_code); c3=$(c3_code)
  missing=$(kafka-topics "${ADMIN[@]}" --describe --under-replicated-partitions 2>/dev/null | grep -oE 'Replicas: [0-9,]+\s+Isr: [0-9,]+' | head -1 | tr '\t' ' ')
  log "broker 在線：$on；under-replicated：$ur；offline：$off；缺的例子：$missing"
  log "$b 的 MDS：$code；REST 經 LB：$rest；C3：$c3"
  grep -qw "$b" <<<"$on" && fail "$b 還在線上（沒停成？）" || ok "$b 不在線上"
  [ "$ur" -gt 0 ] && ok "under-replicated $ur（$b 的 replica 不同步）" || fail "under-replicated 是 0"
  [ "$off" = 0 ] && ok "offline 0（RF 3，少一台還有 leader）" || fail "有 offline partition：$off"
  [ "$code" != 200 ] && ok "$b 的 MDS 連不上（$code）" || fail "$b 的 MDS 還回 200"
  [ "$rest" = 200 ] && [ "$c3" = 200 ] && ok "REST 經 LB、C3 照常" || fail "REST／C3 受影響（$rest／$c3）"
  log "那一台的三件事："
  ssh "$(fqdn "$b")" "echo \"  is-active：\$(systemctl is-active confluent-server)；ExecStart：\$(systemctl show confluent-server -p ExecStart --value | grep -o '/etc/[^ ]*properties')；日誌最後一行：\$(sudo journalctl -u confluent-server -n 200 --no-pager | tail -1 | cut -c1-120)\"" | tee -a "$LOG_FILE"
}

recover() {   # recover <broker>：重啟那一台（cpuser-ops 允許的寫法），等歸零
  local b=$1 i ur code n
  [ -n "$b" ] || die "用法：$0 recover <broker>"
  section "28.3 處理：重啟 $b，等 under-replicated 歸零、MDS 回 200"
  ssh "$(fqdn "$b")" 'sudo systemctl restart confluent-server && systemctl is-active confluent-server' >/dev/null 2>&1 || die "$b 重啟失敗"
  for i in $(seq 1 30); do ur=$(under_rep); code=$(mds_code "$b"); [ "$ur" = 0 ] && [ "$code" = 200 ] && break; sleep 10; done
  n=$(wc -w <<<"$(online)")
  if [ "$ur" = 0 ] && [ "$code" = 200 ]; then ok "約 $((i*10)) 秒：under-replicated 0、$b MDS 200、broker 在線 $n / $(wc -w <<<"$BROKERS")"
  else fail "等了 $((i*10)) 秒還沒好：under-replicated $ur、MDS $code"; fi
}

case $ACTION in
  snapshot) snapshot;;
  drill)    drill "${2:-}"; [ "$FAIL_COUNT" = 0 ];;
  recover)  recover "${2:-}"; [ "$FAIL_COUNT" = 0 ];;
  *) sed -n '2,12p' "$0"; exit 1;;
esac
