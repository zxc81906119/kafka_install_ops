#!/usr/bin/env bash
# 第 28 站：故障排查速查 —— 一分鐘快照、「一台 broker 掉了」的演練（手把手第 28 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；出事先跑 snapshot；drill／recover 是 lab 與驗收用）
#
# 用法：
#   bash steps/28-triage.sh snapshot            28.2 quorum leader、broker 在線、under-replicated／offline、每台 MDS、REST 經 LB、C3（全綠 rc 0，否則 rc 1）
#   bash steps/28-triage.sh drill <broker>      28.3 broker 已被銀行停掉（lab：bank-sim.sh broker-stop）：確認症狀（在線少一台、under-replicated > 0、那台 MDS 連不上、REST／C3 照常）
#   bash steps/28-triage.sh recover <broker>    28.3 ssh 過去 systemctl restart（cpuser-ops 允許的寫法），等 under-replicated 歸零、MDS 回 200
#   bash steps/28-triage.sh mds-down            28.6 8090 已被擋（lab：bank-sim.sh mds-block on）：選單指向 28.6、緊急主機模式、kafka-admin 做 topic 操作
#   bash steps/28-triage.sh mds-back            28.6 8090 開回之後：MDS 200、選單照常，照 20.2 換 kafka-admin 密碼
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

# ── 28.6 MDS 的 8090 不能用時 ──
# kafka-admin（SCRAM，CLIENT 9095）的連線設定：放暫存目錄（0600），用完刪；密碼不印
ka_conf() {   # ka_conf <輸出檔> <密碼檔>
  (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=SCRAM-SHA-512\nssl.truststore.type=PKCS12\nssl.truststore.location=%s\nssl.truststore.password=%s\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="kafka-admin" password="%s";\n' \
    "$CERTS_DIR/truststore.p12" "$(cat "$PKI_DIR/store.pass")" "$(cat "$2")" > "$1")
}
ka_login() { kafka-topics --bootstrap-server "$BROKER_CLIENT" --command-config "$1" --list >/dev/null 2>&1; }   # ka_login <設定檔>：登得進 9095 回 0
# lab 才有測試人員的密碼檔；沒有就略過選單的檢查（正式環境由人實際登入確認）
menu_as() { local u=$1; shift; [ -s "$SECRETS_DIR/ad-test-users.pass" ] || return 2
  env OPMENU_USER="$u" OPMENU_PASS="$(cat "$SECRETS_DIR/ad-test-users.pass")" OPMENU_YES=1 OPMENU_REASON="28.6 演練" JAVA_HOME=/opt/java/current /opt/opmenu/opmenu.sh --run "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }

mds_down() {   # 8090 已被擋（lab：bank-sim.sh mds-block on）
  local h codes="" out t
  section "28.6 MDS 連不上：選單、緊急主機模式、kafka-admin"
  for h in $BROKERS; do codes+="$h=$(mds_code "$h") "; done
  log "MDS：$codes"
  grep -q '=200' <<<"$codes" && fail "還有 MDS 回 200（8090 沒擋成？）" || ok "每台 MDS 都連不上"
  for h in $BROKERS; do timeout 5 bash -c "</dev/tcp/$(fqdn "$h")/9095" 2>/dev/null || fail "$h 的 9095 也不通"; done
  out=$(menu_as bob 11); case $? in
    2) warn "沒有測試人員密碼檔，略過選單檢查";;
    *) grep -q '28.6 的 kafka-admin' <<<"$out" && ok "選單登入失敗，並指向 28.6" || fail "選單沒有指向 28.6：$(head -3 <<<"$out" | tr '\n' ' ')";;
  esac
  menu_emergency | grep -q EMERGENCY_OK && ok "緊急主機模式（不看群組）：23 看日誌可以、31 建 topic 被擋" || fail "緊急主機模式不如預期"
  t=$(mktemp -d); ka_conf "$t/ka.properties" "$SECRETS_DIR/kafka-admin.pass"
  local A=(--bootstrap-server "$BROKER_CLIENT" --command-config "$t/ka.properties")
  log "kafka-admin：topic $(kafka-topics "${A[@]}" --list 2>/dev/null | wc -l) 個；under-replicated $(kafka-topics "${A[@]}" --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:)"
  if kafka-topics "${A[@]}" --create --topic orders.mds-down --partitions 3 --replication-factor 3 >/dev/null 2>&1 &&
     kafka-configs "${A[@]}" --alter --entity-type topics --entity-name orders.mds-down --add-config retention.ms=86400000 >/dev/null 2>&1 &&
     kafka-topics "${A[@]}" --delete --topic orders.mds-down >/dev/null 2>&1; then ok "kafka-admin（9095）建 topic、改 retention、刪 topic，不經 MDS 與 AD"
  else fail "kafka-admin 的 topic 操作失敗"; fi
  rm -rf "$t"
}

menu_emergency() {   # MDS 連不上時選單直接進緊急主機模式（2026-10-29 起不看群組）；印 EMERGENCY_OK 代表符合預期
  local a b
  a=$(menu_as bob 23 "$(fqdn "${BROKERS%% *}"):confluent-server" 3); b=$(menu_as bob 31 orders.em 1)
  grep -q '已進入緊急主機模式' <<<"$a" && grep -q 'kafka-server-start' <<<"$a" && grep -q '在緊急主機模式不開放' <<<"$b" && echo EMERGENCY_OK
}

mds_back() {   # 8090 開回之後：確認恢復，照 20.2 換 kafka-admin 密碼（用過就換）
  local h codes="" t out
  section "28.6 恢復：MDS、選單、換 kafka-admin 密碼"
  for i in $(seq 1 12); do codes=""; for h in $BROKERS; do codes+="$h=$(mds_code "$h") "; done; grep -q -v '=200' <<<"$(tr ' ' '\n' <<<"$codes" | grep .)" || break; sleep 5; done
  log "MDS：$codes"; grep -q -v '=200' <<<"$(tr ' ' '\n' <<<"$codes" | grep .)" && fail "還有 MDS 不回 200" || ok "每台 MDS 回 200"
  out=$(menu_as bob 11); [ $? = 2 ] || { grep -q -- '-- broker 在線:' <<<"$out" && ok "選單照常登入" || fail "選單還登不進：$(head -2 <<<"$out" | tr '\n' ' ')"; }
  t=$(mktemp -d); (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$t/new.pass")
  kafka-configs "${ADMIN[@]}" --alter --add-config "SCRAM-SHA-512=[password=$(cat "$t/new.pass")]" --entity-type users --entity-name kafka-admin >/dev/null 2>&1   # 出錯會把密碼印出來，所以丟掉
  ka_conf "$t/new.properties" "$t/new.pass"; ka_conf "$t/old.properties" "$SECRETS_DIR/kafka-admin.pass"
  sleep 5
  if ka_login "$t/new.properties" && ! ka_login "$t/old.properties"; then install -m 0600 "$t/new.pass" "$SECRETS_DIR/kafka-admin.pass"; ok "kafka-admin 換好密碼（新的登入成功、舊的被拒），已存回 kafka-admin.pass"
  else fail "kafka-admin 換密碼沒有生效；kafka-admin.pass 沒動"; fi
  rm -rf "$t"
}

case $ACTION in
  snapshot) snapshot;;
  mds-down) mds_down; [ "$FAIL_COUNT" = 0 ];;
  menu-emergency) menu_emergency;;
  mds-back) mds_back; [ "$FAIL_COUNT" = 0 ];;
  drill)    drill "${2:-}"; [ "$FAIL_COUNT" = 0 ];;
  recover)  recover "${2:-}"; [ "$FAIL_COUNT" = 0 ];;
  *) sed -n '2,12p' "$0"; exit 1;;
esac
