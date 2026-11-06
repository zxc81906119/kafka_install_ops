#!/usr/bin/env bash
# 第 28 站：故障排查速查 —— 一分鐘快照、「一台 broker 掉了」的演練（手把手第 28 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；出事先跑 snapshot；drill／recover 是 lab 與驗收用）
#
# 做什麼：snapshot 一次看 quorum、broker、partition、MDS、REST、C3；其他子命令是 lab 與驗收用的演練。
# 需要什麼：第 11 站的 client 設定、第 12 站的 REST 憑證、第 16 站的選單（mds-down／mds-back 才用到）。
# 產出什麼：只有紀錄檔；mds-back 會換掉 kafka-admin 的密碼（~/secrets/kafka-admin.pass）。
# 能不能重跑：可以。只有 recover 會重啟服務、mds-back 會換密碼。
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
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-snapshot}
# 管理 client 的 bootstrap 給所有 broker：出事的可能就是第一台
ADMIN=(--bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF")
REST_APP=$FIRST_REST_APP

# leader_id：quorum 的 leader 是哪個 node id，例 2；空白 = controller 沒有 leader（最嚴重）
leader_id() {
  kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" \
      --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null \
    | grep -oE '^LeaderId: *[0-9]+' \
    | grep -oE '[0-9]+'
}

# online：在線的 broker 短名，例 kb01 kb02 kb03
online() {
  local full_names

  # 1. 工具輸出每台開頭的主機名稱，例：kb01.poc.lab:9094 → kb01.poc.lab
  full_names=$(kafka-broker-api-versions "${ADMIN[@]}" 2>/dev/null | grep -oE '^[a-z0-9.-]+:[0-9]+' | cut -d: -f1)

  # 2. 只留短名，排好順序放同一行
  cut -d. -f1 <<<"$full_names" | sort | paste -sd' '
}

# under_rep、offline：under-replicated／沒有 leader 的 partition 數，例 0
under_rep() {
  kafka-topics "${ADMIN[@]}" --describe --under-replicated-partitions 2>/dev/null \
    | awk '/Partition:/ {c++} END {print c + 0}'
}

offline() {
  kafka-topics "${ADMIN[@]}" --describe --unavailable-partitions 2>/dev/null \
    | awk '/Partition:/ {c++} END {print c + 0}'
}

# mds_code <主機>：那台 MDS（8090）的 HTTP 狀態碼；連不上是 000
mds_code() {
  curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://$(fqdn "$1"):8090/v1/metadata/id"
}

# rest_code：REST 經 LB 的 HTTP 狀態碼（用應用程式的憑證）
rest_code() {
  curl -s -m 30 -o /dev/null -w '%{http_code}' \
    --cacert "$CERTS_DIR/bank-root.pem" \
    --cert "$CERTS_DIR/$REST_APP.crt" \
    --key "$KEYS_DIR/$REST_APP.key" \
    "https://$REST_VIP:8082/v3/clusters"
}

# c3_code：C3 畫面的 HTTP 狀態碼
c3_code() {
  curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$C3_FQDN:9021/"
}

# mds_status：逐台印 MDS 的狀態碼，例 kb01=200 kb02=200 kb03=200 kb04=000
mds_status() {
  local host

  for host in $BROKERS; do
    printf '%s=%s ' "$host" "$(mds_code "$host")"
  done
}

# count_not_200 <mds_status 的輸出>：有幾台不是 200，例 "kb01=200 kb04=000 " → 1
count_not_200() {
  tr ' ' '\n' <<<"$1" | awk '/=/ && !/=200/ {c++} END {print c + 0}'
}

snapshot() {
  local leader online_list online_count under_replicated offline_count mds_line bad=0 broker_total

  section "28.2 一分鐘快照"

  # 1. 收集
  leader=$(leader_id)
  online_list=$(online)
  under_replicated=$(under_rep)
  offline_count=$(offline)
  online_count=$(wc -w <<<"$online_list")
  broker_total=$(wc -w <<<"$BROKERS")
  mds_line=$(mds_status)

  # 2. 印出來
  log "quorum leader：${leader:-無}；broker 在線：$online_count / $broker_total（$online_list）"
  log "under-replicated：$under_replicated；offline：$offline_count"
  log "MDS：$mds_line"
  log "REST 經 LB：$(rest_code)；C3：$(c3_code)"

  # 3. 判斷
  if [ -z "$leader" ]; then
    fail "controller 沒有 leader"
    bad=1
  fi

  if [ "$online_count" != "$broker_total" ]; then
    fail "broker 不是全部在線"
    bad=1
  fi

  if [ "$under_replicated" != 0 ] || [ "$offline_count" != 0 ]; then
    fail "有 under-replicated／offline partition"
    bad=1
  fi

  if [ "$(count_not_200 "$mds_line")" != 0 ]; then
    fail "有 broker 的 MDS 不回 200"
    bad=1
  fi

  if [ "$bad" = 0 ]; then
    ok "全綠"
  fi

  return "$bad"
}

# 那一台的三件事：服務狀態、ExecStart 指向的設定、日誌最後一行（sudo 的寫法要和 cpuser-ops 列的一字不差）
THREE_THINGS=$(cat <<'EOF'
state=$(systemctl is-active confluent-server)
exec_file=$(systemctl show confluent-server -p ExecStart --value | grep -o '/etc/[^ ]*properties')
last_line=$(sudo journalctl -u confluent-server -n 200 --no-pager | tail -1 | cut -c1-120)
echo "  is-active：$state；ExecStart：$exec_file；日誌最後一行：$last_line"
EOF
)

# drill <broker>：那台已被停掉，確認症狀
drill() {
  local broker=$1 online_list under_replicated offline_count code rest c3 missing replicas_and_isr

  if [ -z "$broker" ]; then
    die "用法：$0 drill <broker>"
  fi

  section "28.3 症狀：$broker 的服務被停掉之後"

  # 1. 收集；多看一個 under-replicated 的 partition，看缺的是哪個 broker id
  online_list=$(online)
  under_replicated=$(under_rep)
  offline_count=$(offline)
  code=$(mds_code "$broker")
  rest=$(rest_code)
  c3=$(c3_code)
  replicas_and_isr=$(kafka-topics "${ADMIN[@]}" --describe --under-replicated-partitions 2>/dev/null \
    | grep -oE 'Replicas: [0-9,]+\s+Isr: [0-9,]+' \
    | head -1)
  missing=$(tr '\t' ' ' <<<"$replicas_and_isr")

  log "broker 在線：$online_list；under-replicated：$under_replicated；offline：$offline_count；缺的例子：$missing"
  log "$broker 的 MDS：$code；REST 經 LB：$rest；C3：$c3"

  # 2. 判斷
  if grep -qw "$broker" <<<"$online_list"; then
    fail "$broker 還在線上（沒停成？）"
  else
    ok "$broker 不在線上"
  fi

  if [ "$under_replicated" -gt 0 ]; then
    ok "under-replicated $under_replicated（$broker 的 replica 不同步）"
  else
    fail "under-replicated 是 0"
  fi

  if [ "$offline_count" = 0 ]; then
    ok "offline 0（RF 3，少一台還有 leader）"
  else
    fail "有 offline partition：$offline_count"
  fi

  if [ "$code" != 200 ]; then
    ok "$broker 的 MDS 連不上（$code）"
  else
    fail "$broker 的 MDS 還回 200"
  fi

  if [ "$rest" = 200 ] && [ "$c3" = 200 ]; then
    ok "REST 經 LB、C3 照常"
  else
    fail "REST／C3 受影響（$rest／$c3）"
  fi

  # 3. 那一台的三件事
  log "那一台的三件事："
  ssh_script "$broker" <<<"$THREE_THINGS" | tee -a "$LOG_FILE"
}

# recover <broker>：重啟那一台（cpuser-ops 允許的寫法），等歸零
recover() {
  local broker=$1 attempt under_replicated code online_count online_list

  if [ -z "$broker" ]; then
    die "用法：$0 recover <broker>"
  fi

  section "28.3 處理：重啟 $broker，等 under-replicated 歸零、MDS 回 200"

  # 1. 重啟
  if ! ssh_run "$broker" 'sudo systemctl restart confluent-server' >/dev/null 2>&1; then
    die "$broker 重啟失敗"
  fi

  if ! ssh_run "$broker" 'systemctl is-active confluent-server' >/dev/null 2>&1; then
    die "$broker 重啟失敗"
  fi

  # 2. 等 under-replicated 歸零、MDS 回 200：每 10 秒看一次，最多 30 次
  for attempt in $(seq 1 30); do
    under_replicated=$(under_rep)
    code=$(mds_code "$broker")

    if [ "$under_replicated" = 0 ] && [ "$code" = 200 ]; then
      break
    fi

    sleep 10
  done

  # 3. 判斷
  online_list=$(online)
  online_count=$(wc -w <<<"$online_list")

  if [ "$under_replicated" = 0 ] && [ "$code" = 200 ]; then
    ok "約 $((attempt * 10)) 秒：under-replicated 0、$broker MDS 200、broker 在線 $online_count / $(wc -w <<<"$BROKERS")"
  else
    fail "等了 $((attempt * 10)) 秒還沒好：under-replicated $under_replicated、MDS $code"
  fi
}

# ── 28.6 MDS 的 8090 不能用時 ──

# ka_conf <輸出檔> <密碼檔>：kafka-admin（SCRAM，CLIENT 9095）的連線設定；放暫存目錄（0600），用完刪；密碼不印
ka_conf() {
  install -m 0600 /dev/null "$1"
  cat > "$1" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$(cat "$PKI_DIR/store.pass")
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="kafka-admin" password="$(cat "$2")";
EOF
}

# ka_login <設定檔>：登得進 9095 回 0
ka_login() {
  kafka-topics --bootstrap-server "$BROKER_CLIENT" --command-config "$1" --list >/dev/null 2>&1
}

# strip_colors：拿掉選單輸出裡的顏色控制碼
strip_colors() {
  sed 's/\x1b\[[0-9;]*m//g'
}

# menu_as <人員> <選單項目與參數…>：以這個人員跑選單，印出輸出。
# lab 才有測試人員的密碼檔；沒有就回 2，略過選單的檢查（正式環境由人實際登入確認）
menu_as() {
  local user=$1
  local test_password
  shift

  if [ ! -s "$SECRETS_DIR/ad-test-users.pass" ]; then
    return 2
  fi

  test_password=$(cat "$SECRETS_DIR/ad-test-users.pass")

  env OPMENU_USER="$user" \
    OPMENU_PASS="$test_password" \
    OPMENU_YES=1 \
    OPMENU_REASON="28.6 演練" \
    JAVA_HOME=/opt/java/current \
    /opt/opmenu/opmenu.sh --run "$@" 2>&1 | strip_colors
}

# menu_emergency：MDS 連不上時選單直接進緊急主機模式（2026-10-29 起不看群組）；印 EMERGENCY_OK 代表符合預期
menu_emergency() {
  local log_output create_output first_broker

  first_broker=$(fqdn "${BROKERS%% *}")
  log_output=$(menu_as bob 23 "$first_broker:confluent-server" 3)
  create_output=$(menu_as bob 31 orders.em 1)

  if ! grep -q '已進入緊急主機模式' <<<"$log_output"; then
    return 1
  fi

  if ! grep -q 'kafka-server-start' <<<"$log_output"; then
    return 1
  fi

  if ! grep -q '在緊急主機模式不開放' <<<"$create_output"; then
    return 1
  fi

  echo EMERGENCY_OK
}

# kafka_admin_topic_ops <kafka-admin 連線選項…>：建 topic、改 retention、刪 topic；有一步失敗就回 1
kafka_admin_topic_ops() {
  if ! kafka-topics "$@" --create --topic orders.mds-down --partitions 3 --replication-factor 3 >/dev/null 2>&1; then
    return 1
  fi

  if ! kafka-configs "$@" --alter --entity-type topics --entity-name orders.mds-down \
       --add-config retention.ms=86400000 >/dev/null 2>&1; then
    return 1
  fi

  if ! kafka-topics "$@" --delete --topic orders.mds-down >/dev/null 2>&1; then
    return 1
  fi
}

# mds_down：8090 已被擋（lab：bank-sim.sh mds-block on）
mds_down() {
  local host codes menu_output menu_rc temp_dir topic_count under_replicated

  section "28.6 MDS 連不上：選單、緊急主機模式、kafka-admin"

  # 1. 8090 不通、9095 還通
  codes=$(mds_status)
  log "MDS：$codes"

  if grep -q '=200' <<<"$codes"; then
    fail "還有 MDS 回 200（8090 沒擋成？）"
  else
    ok "每台 MDS 都連不上"
  fi

  for host in $BROKERS; do
    if ! timeout 5 bash -c "</dev/tcp/$(fqdn "$host")/9095" 2>/dev/null; then
      fail "$host 的 9095 也不通"
    fi
  done

  # 2. 選單：AD 登入失敗，畫面指向 28.6
  menu_output=$(menu_as bob 11)
  menu_rc=$?

  if [ "$menu_rc" = 2 ]; then
    warn "沒有測試人員密碼檔，略過選單檢查"
  elif grep -q '28.6 的 kafka-admin' <<<"$menu_output"; then
    ok "選單登入失敗，並指向 28.6"
  else
    fail "選單沒有指向 28.6：$(head -3 <<<"$menu_output" | tr '\n' ' ')"
  fi

  # 3. 緊急主機模式：主機類開放、Kafka 類擋下
  if grep -q EMERGENCY_OK <<<"$(menu_emergency)"; then
    ok "緊急主機模式（不看群組）：23 看日誌可以、31 建 topic 被擋"
  else
    fail "緊急主機模式不如預期"
  fi

  # 4. kafka-admin（9095）：不經 MDS 與 AD
  temp_dir=$(mktemp -d)
  ka_conf "$temp_dir/ka.properties" "$SECRETS_DIR/kafka-admin.pass"

  local kafka_admin=(--bootstrap-server "$BROKER_CLIENT" --command-config "$temp_dir/ka.properties")

  topic_count=$(kafka-topics "${kafka_admin[@]}" --list 2>/dev/null | wc -l)
  under_replicated=$(kafka-topics "${kafka_admin[@]}" --describe --under-replicated-partitions 2>/dev/null \
    | awk '/Partition:/ {c++} END {print c + 0}')
  log "kafka-admin：topic $topic_count 個；under-replicated $under_replicated"

  if kafka_admin_topic_ops "${kafka_admin[@]}"; then
    ok "kafka-admin（9095）建 topic、改 retention、刪 topic，不經 MDS 與 AD"
  else
    fail "kafka-admin 的 topic 操作失敗"
  fi

  rm -rf "$temp_dir"
}

# mds_back：8090 開回之後，確認恢復，照 20.2 換 kafka-admin 密碼（用過就換）
mds_back() {
  local attempt codes menu_output menu_rc temp_dir new_password

  section "28.6 恢復：MDS、選單、換 kafka-admin 密碼"

  # 1. 等每台 MDS 回 200：每 5 秒看一次，最多 12 次
  for attempt in $(seq 1 12); do
    codes=$(mds_status)

    if [ "$(count_not_200 "$codes")" = 0 ]; then
      break
    fi

    sleep 5
  done

  log "MDS：$codes"

  if [ "$(count_not_200 "$codes")" != 0 ]; then
    fail "還有 MDS 不回 200"
  else
    ok "每台 MDS 回 200"
  fi

  # 2. 選單照常登入（沒有測試人員密碼檔就略過）
  menu_output=$(menu_as bob 11)
  menu_rc=$?

  if [ "$menu_rc" != 2 ]; then
    if grep -q -- '-- broker 在線:' <<<"$menu_output"; then
      ok "選單照常登入"
    else
      fail "選單還登不進：$(head -2 <<<"$menu_output" | tr '\n' ' ')"
    fi
  fi

  # 3. 換密碼（kafka-configs 出錯會把密碼印出來，所以輸出全丟）
  temp_dir=$(mktemp -d)
  install -m 0600 /dev/null "$temp_dir/new.pass"
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$temp_dir/new.pass"

  new_password=$(cat "$temp_dir/new.pass")

  kafka-configs "${ADMIN[@]}" --alter \
    --add-config "SCRAM-SHA-512=[iterations=8192,password=$new_password]" \
    --entity-type users --entity-name kafka-admin >/dev/null 2>&1

  # 4. 新的登得進、舊的被拒，才把新密碼存回去
  ka_conf "$temp_dir/new.properties" "$temp_dir/new.pass"
  ka_conf "$temp_dir/old.properties" "$SECRETS_DIR/kafka-admin.pass"
  sleep 5

  if ka_login "$temp_dir/new.properties" && ! ka_login "$temp_dir/old.properties"; then
    install -m 0600 "$temp_dir/new.pass" "$SECRETS_DIR/kafka-admin.pass"
    ok "kafka-admin 換好密碼（新的登入成功、舊的被拒），已存回 kafka-admin.pass"
  else
    fail "kafka-admin 換密碼沒有生效；kafka-admin.pass 沒動"
  fi

  rm -rf "$temp_dir"
}

# 結束碼：snapshot、menu-emergency 是函式自己的回傳值；其他看有沒有 fail
case $ACTION in
  snapshot)
    snapshot
    exit $?
    ;;
  menu-emergency)
    menu_emergency
    exit $?
    ;;
  mds-down)
    mds_down
    ;;
  mds-back)
    mds_back
    ;;
  drill)
    drill "${2:-}"
    ;;
  recover)
    recover "${2:-}"
    ;;
  *)
    sed -n '2,18p' "$0"
    exit 1
    ;;
esac

# 沒有 finish_step：出事時隨時會再跑，不留 .done 標記
if [ "$FAIL_COUNT" != 0 ]; then
  exit 1
fi
