#!/usr/bin/env bash
# 第 19 站：驗收與收尾 —— 一次跑完、結果能附在驗收文件裡：平台健康、安全（正反向）、應用程式端、維運；最後列出要收的東西
# where: ops02 （root）
#
# 做什麼：
#   19.1 平台健康：服務、quorum、MDS、沒有 under-replicated／offline partition、Self-Balancing、REST、C3、指標、JMX exporter
#   19.2 安全：該過的過、該擋的擋（AD 帳密、RBAC、REST 憑證、SASL、憑證鏈、明文密碼、master key）
#   19.3 應用程式端：SCRAM app 直連寫讀；REST app 經負載平衡寫，alice 讀得到
#   19.4 維運：bob 用選單重啟一台 broker；冷開機交給機房演練（lab：bank-sim.sh coldboot）
#   19.5 收尾：權限檢查、殘留檔、要留什麼要收什麼
# 需要什麼：第 2–18 站都做完。
# 產出什麼：最後一行「驗收：N / N 項通過」（lab/run-customer.sh 會找這一行與 FAIL，文字不要改）。
# 能不能重跑：可以。只讀為主；19.3 會寫兩筆測試訊息；19.4 只提醒，不重啟。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"   # count_plaintext_passwords、secrets_mode_in_use

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

SECRETS_MODE_IN_USE=$(secrets_mode_in_use)
APP_CLIENT_CONF=$CONF_DIR/$FIRST_SCRAM_APP.properties
TEST_USERS_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass")
FIRST_BROKER_HOST=${BROKERS%% *}
SAMPLE_HOSTS="${CONTROLLERS%% *} $FIRST_BROKER_HOST ${RESTS%% *} $C3_HOST"   # 每個角色抽一台
REST_APP_CERT_OPTIONS=(--cert "$CERTS_DIR/$FIRST_REST_APP.crt" --key "$KEYS_DIR/$FIRST_REST_APP.key")
CHECK_COUNT=0

# first_topic_with_prefix <prefix>：conf/topics.txt 裡第一個以它開頭的 topic
#   例：first_topic_with_prefix orders. → orders.events
first_topic_with_prefix() {
  local prefix=$1 topic_names topic_name

  # 第一欄是 topic 名稱
  topic_names=$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt" | awk '{print $1}')

  for topic_name in $topic_names; do
    if [[ $topic_name == "$prefix"* ]]; then
      echo "$topic_name"
      return 0
    fi
  done
}

SENSITIVE_TOPIC=$(first_topic_with_prefix "$AUDIT_SENSITIVE_PREFIX")

# check "說明" <指令…>：指令成功就 ok，否則 fail；同時計數（指令的輸出不印）
check() {
  local description=$1
  shift
  CHECK_COUNT=$((CHECK_COUNT + 1))

  if "$@" >/dev/null 2>&1; then
    ok "$description"
  else
    fail "$description"
  fi
}

# ---- 下面每個小函式是一項檢查：結束碼 0 = 通過（「被拒」的檢查，被拒才回 0） ----

# http_is <期望的狀態碼> <網址> [curl 參數…]：網址回的 HTTP 狀態碼是不是期望的（連不上時是 000）
http_is() {
  local expected=$1 url=$2 actual
  shift 2
  actual=$(curl -s -o /dev/null -m 15 -w '%{http_code}' --cacert "$BANK_ROOT_CA" "$@" "$url")
  [ "$actual" = "$expected" ]
}

# mds_login_is <期望的狀態碼> <帳號> <密碼>：用 AD 帳密向 MDS 要 token，回的狀態碼是不是期望的
mds_login_is() {
  http_is "$1" "$MDS_URL/security/1.0/authenticate" -u "$2:$3"
}

# quorum_has_leader：controller quorum 有 leader
quorum_has_leader() {
  local output
  output=$(kafka-metadata-quorum --bootstrap-controller "$FIRST_CONTROLLER:9093" \
    --command-config "$INTERNAL_CLIENT_CONF" describe --status)
  grep -q 'LeaderId: *[0-9]' <<<"$output"
}

# no_partitions <describe 的選項>：kafka-topics --describe 加這個選項時，列不出任何 partition
no_partitions() {
  local count
  count=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --describe "$1" \
    | awk '/Partition:/ {c++} END {print c + 0}')
  [ "$count" = 0 ]
}

# balancer_enabled：Self-Balancing 是啟用的
balancer_enabled() {
  local output
  output=$(kafka-rebalance-cluster --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" \
    --status 2>/dev/null)
  grep -q 'Balancer status: ENABLED' <<<"$output"
}

# c3_prometheus_has_broker_metrics：C3 內建的 Prometheus 有 broker 的指標
c3_prometheus_has_broker_metrics() {
  local names
  names=$(curl -s --cacert "$BANK_ROOT_CA" --cert "$CERTS_DIR/svc-ops.crt" --key "$KEYS_DIR/svc-ops.key" \
    "https://$C3_FQDN:9090/api/v1/label/__name__/values")
  grep -q confluent_kafka_server <<<"$names"
}

# jmx_https_only <主機>：那台的 7071 用 HTTPS 回 200，不加密的 HTTP 連不上（000）
jmx_https_only() {
  local host_fqdn
  host_fqdn=$(fqdn "$1")

  if ! http_is 200 "https://$host_fqdn:7071/metrics"; then
    return 1
  fi

  http_is 000 "http://$host_fqdn:7071/metrics"
}

# carol_create_denied：carol 在自己 prefix 以外建 topic，要被 Kafka 拒絕
#   連線設定借 alice 那一份，帳號換成 carol（測試帳號共用同一個密碼；暫存檔 0600，用完即刪）
carol_create_denied() {
  local carol_conf output
  carol_conf=$(mktemp)
  sed 's/username="alice"/username="carol"/' "$ALICE_CLIENT_CONF" > "$carol_conf"

  output=$(kafka-topics --bootstrap-server "$FIRST_BROKER:9096" --command-config "$carol_conf" \
    --create --topic "${AUDIT_SENSITIVE_PREFIX}carol-test" --partitions 1 --replication-factor 3 2>&1)

  rm -f "$carol_conf"
  grep -q TopicAuthorizationException <<<"$output"
}

# app_cannot_read_sensitive：SCRAM app 讀敏感 topic，要被拒絕
app_cannot_read_sensitive() {
  local output
  output=$(kafka-console-consumer --bootstrap-server "$FIRST_BROKER:9095" --consumer.config "$APP_CLIENT_CONF" \
    --topic "$SENSITIVE_TOPIC" --max-messages 1 --timeout-ms 8000 2>&1)
  grep -q TopicAuthorizationException <<<"$output"
}

# rest_without_cert_refused：不帶 client 憑證連 REST Proxy，TLS 那一關就要失敗
rest_without_cert_refused() {
  if curl -s --cacert "$BANK_ROOT_CA" --max-time 10 "https://$REST_VIP:8082/v3/clusters" -o /dev/null; then
    return 1
  fi

  return 0
}

# client_listener_without_sasl_fails：連 9095 只做 TLS、不做 SASL，要失敗（暫存設定檔 0600，用完即刪）
client_listener_without_sasl_fails() {
  local tls_only_conf result
  tls_only_conf=$(mktemp)
  echo "security.protocol=SSL" > "$tls_only_conf"
  echo "ssl.truststore.type=PKCS12" >> "$tls_only_conf"
  echo "ssl.truststore.location=$CERTS_DIR/truststore.p12" >> "$tls_only_conf"
  echo "ssl.truststore.password=$(cat "$PKI_DIR/store.pass")" >> "$tls_only_conf"

  if kafka-topics --bootstrap-server "$FIRST_BROKER:9095" --command-config "$tls_only_conf" --list; then
    result=1
  else
    result=0
  fi

  rm -f "$tls_only_conf"
  return $result
}

# wrong_ca_rejected：用一張無關的自簽 CA 去驗 MDS 的憑證，要失敗（代表 client 端的鏈驗證有效）
#   主機的 OS 已經信任銀行根憑證，所以「不帶 CA」不會失敗；要用一張無關的 CA 才測得出鏈驗證
wrong_ca_rejected() {
  local junk_ca result
  junk_ca=$(mktemp)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null \
    -subj /CN=junk -out "$junk_ca" 2>/dev/null

  if curl -s --max-time 10 --cacert "$junk_ca" "$MDS_URL/v1/metadata/id" -o /dev/null; then
    result=1
  else
    result=0
  fi

  rm -f "$junk_ca"
  return $result
}

# plaintext_count_on_host <主機>：那台的設定檔裡還有幾個明文密碼欄位
#   count_plaintext_passwords 會把檔案讀兩次，所以先存成暫存檔（mktemp 0600，用完即刪），不能用 <(…)：管線只讀得到一次
plaintext_count_on_host() {
  local host=$1 props_copy count
  props_copy=$(mktemp)
  if ! ssh_run "$host" "sudo cat $(props_path_of "$host")" > "$props_copy"; then
    rm -f "$props_copy"
    echo "讀不到"
    return
  fi

  count=$(count_plaintext_passwords "$props_copy")
  rm -f "$props_copy"
  echo "$count"
}

# master_key_only_in_service_env <主機>：那台的 /etc/confluent、/etc/systemd/system 底下，只有 service.env 一個檔有 master key
master_key_only_in_service_env() {
  ssh_script "$1" <<'EOF'
count=$(sudo grep -rl CONFLUENT_SECURITY_MASTER_KEY= /etc/confluent /etc/systemd/system 2>/dev/null | wc -l)
[ "$count" = 1 ]
EOF
}

# cp_server_is_not_a_client：cp-server 只有 serverAuth；拿它當 client 憑證連 C3 的 Prometheus 要被拒，svc-ops 則連得上
cp_server_is_not_a_client() {
  local eku
  eku=$(openssl x509 -in "$CERTS_DIR/cp-server.crt" -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' ')

  if [ "$eku" != TLSWebServerAuthentication ]; then
    return 1
  fi

  if ! curl -sf -m 15 --cacert "$BANK_ROOT_CA" --cert "$CERTS_DIR/svc-ops.crt" --key "$KEYS_DIR/svc-ops.key" \
       "https://$C3_FQDN:9090/-/ready"; then
    return 1
  fi

  if curl -sf -m 15 --cacert "$BANK_ROOT_CA" --cert "$CERTS_DIR/cp-server.crt" --key "$KEYS_DIR/cp-server.key" \
       "https://$C3_FQDN:9090/-/ready"; then
    return 1
  fi

  return 0
}

# app_can_produce <topic> <訊息>：SCRAM app 直連 9095 寫一筆
app_can_produce() {
  echo "$2" | kafka-console-producer --bootstrap-server "$FIRST_BROKER:9095" \
    --producer.config "$APP_CLIENT_CONF" --topic "$1"
}

# account_can_login <帳號> <topic> <group>：這個 SCRAM 帳號連得上（輸出裡有 SaslAuthenticationException 以外的行）
#   連線設定借 app 那一份，帳號密碼換掉（暫存檔 0600，用完即刪）
account_can_login() {
  local account=$1 topic=$2 group=$3 account_conf account_password output old_login new_login
  account_conf=$(mktemp)
  account_password=$(cat "$SECRETS_DIR/$account.pass")
  old_login='username="[^"]*" password="[^"]*"'
  new_login="username=\"$account\" password=\"$account_password\""
  sed "s/$old_login/$new_login/" "$APP_CLIENT_CONF" > "$account_conf"
  unset account_password new_login

  output=$(kafka-console-consumer --bootstrap-server "$FIRST_BROKER:9095" --consumer.config "$account_conf" \
    --topic "$topic" --group "$group" --max-messages 1 --timeout-ms 8000 2>&1)

  rm -f "$account_conf"

  # 輸出裡只要出現一次認證失敗，就是登不進去（其他行不算數）
  if grep -q SaslAuthenticationException <<<"$output"; then
    return 1
  fi

  return 0
}

# consumer_finds <client 設定> <埠> <topic> <group> <訊息>：從頭讀，讀得到這筆訊息
#   不能把 consumer 的輸出先存進變數再比對：--timeout-ms 只在「沒有新訊息」時才到期，topic 持續有流量（遷移期間的 load.sh）時 consumer 永遠不會結束。
#   所以接 grep -m 1：找到第一筆就結束，consumer 下一次寫輸出時跟著結束。沒有訊息時最多等 45 秒。
#   這一段關掉 pipefail（只在這個子 shell）：consumer 是被這樣停掉的，結束碼不是 0，結果只看 grep。
consumer_finds() {
  local client_conf=$1 port=$2 topic=$3 group=$4 message=$5

  (
    set +o pipefail
    kafka-console-consumer --bootstrap-server "$FIRST_BROKER:$port" --consumer.config "$client_conf" \
      --topic "$topic" --group "$group" --from-beginning --timeout-ms 45000 2>/dev/null \
      | grep -m 1 "$message" > /dev/null
  )
}

# 測試用的 client 設定，沒有就建（檔案 0600）
store_password=$(cat "$PKI_DIR/store.pass")

if [ ! -f "$ALICE_CLIENT_CONF" ]; then
  install -m 0600 /dev/null "$ALICE_CLIENT_CONF"
  cat > "$ALICE_CLIENT_CONF" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="$TEST_USERS_PASSWORD";
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$store_password
EOF
fi

if [ ! -f "$APP_CLIENT_CONF" ]; then
  app_password=$(cat "$SECRETS_DIR/$FIRST_SCRAM_ACCOUNT.pass")
  install -m 0600 /dev/null "$APP_CLIENT_CONF"
  cat > "$APP_CLIENT_CONF" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$FIRST_SCRAM_ACCOUNT" password="$app_password";
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$store_password
EOF
  unset app_password
fi
unset store_password

section "19.1 平台健康"

# 1. KRaft 與服務
check "controller quorum 有 leader" quorum_has_leader

for host in $KAFKA_HOSTS; do
  check "$host confluent-server active" ssh_run "$host" 'systemctl is-active -q confluent-server'
done

# 2. MDS
for host in $BROKERS; do
  check "$host MDS 8090 回 200" http_is 200 "https://$(fqdn "$host"):8090/v1/metadata/id"
done

# 3. partition 與 Self-Balancing
check "沒有 under-replicated partition" no_partitions --under-replicated-partitions
check "沒有 offline partition" no_partitions --unavailable-partitions
check "Self-Balancing 啟用" balancer_enabled

# 4. REST Proxy、C3
check "REST Proxy 經負載平衡回 200（mTLS）" http_is 200 "https://$REST_VIP:8082/v3/clusters" "${REST_APP_CERT_OPTIONS[@]}"
check "Control Center 9021 回 200" http_is 200 "https://$C3_FQDN:9021/"
check "C3 的 Prometheus 有 broker 指標" c3_prometheus_has_broker_metrics

# 5. JMX exporter
if [ "$JMX_EXPORTER" = 1 ]; then
  for host in $SAMPLE_HOSTS; do
    check "$host JMX exporter 7071 只走 HTTPS" jmx_https_only "$host"
  done
fi

health_failures=$FAIL_COUNT

section "19.2 安全：正向與反向"

# 1. AD 身分（MDS 去 AD 驗帳密）
check "AD 帳密正確 → MDS 給 token（200）" mds_login_is 200 alice "$TEST_USERS_PASSWORD"
check "AD 密碼錯 → 401" mds_login_is 401 alice wrong-password
check "不存在的帳號 → 401" mds_login_is 401 nobody "$TEST_USERS_PASSWORD"
unset TEST_USERS_PASSWORD

# 2. Kafka 的授權
check "carol 在自己的 prefix 以外建 topic 被拒" carol_create_denied
check "$FIRST_SCRAM_APP 讀 $SENSITIVE_TOPIC 被拒" app_cannot_read_sensitive

# 3. 連線方式
check "REST Proxy 不帶憑證 → TLS 就拒絕" rest_without_cert_refused
check "REST Proxy 帶非 app 憑證（svc-ops）→ 401" http_is 401 "https://$REST_VIP:8082/v3/clusters" \
  --cert "$CERTS_DIR/svc-ops.crt" --key "$KEYS_DIR/svc-ops.key"
check "CLIENT 9095 不帶 SASL → 失敗" client_listener_without_sasl_fails
if [ "$JMX_EXPORTER" = 1 ]; then
  check "JMX exporter 不加密的 HTTP → 連不上" http_is 000 "http://$FIRST_BROKER:7071/metrics"
fi
check "用無關的 CA 驗 MDS 憑證會被拒（鏈驗證生效）" wrong_ca_rejected

# 4. 機敏資料與檔案權限
if [ "$SECRETS_MODE_IN_USE" != plain ]; then
  for host in $FIRST_BROKER_HOST ${RESTS%% *} $C3_HOST; do
    plaintext_count=$(plaintext_count_on_host "$host")
    check "$host 的設定檔沒有明文密碼" test "$plaintext_count" = 0
  done

  check "$FIRST_BROKER_HOST 磁碟上的 master key 只有 service.env 一個" master_key_only_in_service_env "$FIRST_BROKER_HOST"
else
  warn "SECRETS_MODE=plain：設定檔裡的密碼是明文（0640），正式環境請走第 15 站"
fi

check "/etc/confluent/ssl 是 0750" ssh_run "$FIRST_BROKER_HOST" '[ "$(sudo stat -c %a /etc/confluent/ssl)" = 750 ]'
check "cp-server 只有 serverAuth，拿來當 client 憑證連 C3 的 Prometheus 被拒" cp_server_is_not_a_client
check "alice 能從 C3 登入（C3 連得到 MDS）" wait_c3_login

security_failures=$((FAIL_COUNT - health_failures))

section "19.3 應用程式端"
cluster_id=$(curl -s --cacert "$BANK_ROOT_CA" "$MDS_URL/v1/metadata/id" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
test_message="acceptance-$(date +%s)"

# 每個 app 用自己 prefix 的 topic：app-orders → orders.events；app-legacy-billing → billing.events
# consumer group 也要在 app 自己的 prefix 底下（conf/rbac.txt：app-orders 只能用 orders- 開頭的 group）
scram_app_group=${FIRST_SCRAM_APP#app-}-acceptance
scram_app_topic=$(first_topic_with_prefix "${FIRST_SCRAM_APP#app-}.")
rest_app_group=${FIRST_REST_APP##*-}-acceptance
rest_app_topic=$(first_topic_with_prefix "${FIRST_REST_APP##*-}.")
rest_body="{\"value\":{\"type\":\"JSON\",\"data\":\"$test_message-rest\"}}"

# 1. SCRAM app 直連寫一筆；A／B 兩個帳號都登入得了；讀回自己寫的那筆
check "$FIRST_SCRAM_APP（SCRAM 直連）寫入 $scram_app_topic" app_can_produce "$scram_app_topic" "$test_message"

for suffix in $SCRAM_SUFFIXES; do
  check "$FIRST_SCRAM_APP$suffix（A／B 兩個帳號）能用 SCRAM 登入" account_can_login \
    "$FIRST_SCRAM_APP$suffix" "$scram_app_topic" "$scram_app_group-$suffix"
done

check "$FIRST_SCRAM_APP 讀回自己寫的" consumer_finds \
  "$APP_CLIENT_CONF" 9095 "$scram_app_topic" "$scram_app_group" "$test_message"

# 2. REST app 經負載平衡 + REST Proxy 寫一筆；alice 讀得到
rest_records_url="https://$REST_VIP:8082/v3/clusters/$cluster_id/topics/$rest_app_topic/records"
check "$FIRST_REST_APP 經負載平衡 + REST Proxy（mTLS）寫入 $rest_app_topic" http_is 200 "$rest_records_url" \
  "${REST_APP_CERT_OPTIONS[@]}" -X POST -H 'Content-Type: application/json' -d "$rest_body"
check "alice 在 $rest_app_topic 讀到那筆" consumer_finds \
  "$ALICE_CLIENT_CONF" 9096 "$rest_app_topic" "$rest_app_group" "$test_message-rest"

application_failures=$((FAIL_COUNT - health_failures - security_failures))

section "19.4 維運"
if [ "$OPMENU" = 1 ]; then
  # 選單要維運人員本人互動登入（輸入 AD 帳密），非互動做不到（第 16 站同樣只提醒）
  warn "人工驗收項目：維運人員（bob）互動登入選單（經 PSMP 進操作機），選 21 重啟一台 broker；成功後把選單紀錄那一行附在驗收文件"
else
  log "OPMENU=0 或選單沒裝：略過選單重啟"
fi

cold_boot_expectation="master key 在各主機的 service.env，開機不依賴任何外部系統；controller → broker 依序回來"
ask_bank "冷開機（全部主機同時關再開）由機房排程演練。預期：$cold_boot_expectation，" \
         "    C3 等 MDS 起來才啟動（第 13 站的 drop-in）。lab：bash install/lab/bank-sim.sh coldboot"

section "19.5 收尾：留什麼、收什麼"

# 1. 操作機 /tmp 裡安裝期間的暫存
rm -rf /tmp/jmx-* /tmp/*.properties 2>/dev/null

# 2. 家目錄底下的金鑰與密碼檔都要是 0600
wrong_permissions=$(find ~ -maxdepth 3 -type f \( -name '*.key' -o -name '*.pass' -o -name 'master.key' \) \
  ! -perm 600 2>/dev/null)
if [ -z "$wrong_permissions" ]; then
  ok "家目錄下的私鑰與密碼檔都是 0600"
else
  fail "權限不是 0600：$(paste -sd' ' <<<"$wrong_permissions")"
fi

# 3. 各主機：/tmp 的殘留、sudoers.d 裡有哪些檔
for host in $SAMPLE_HOSTS; do
  leftovers=$(ssh_script "$host" <<'EOF'
# JVM 自己的暫存檔（hsperfdata、lib*.so、com_*）不算殘留
tmp_leftovers=$(find /tmp -mindepth 1 -maxdepth 1 \
  ! -name '.*' ! -name 'hsperfdata*' ! -name 'systemd-private*' ! -name 'lib*.so*' ! -name 'com_*' \
  | wc -l)
echo "/tmp 殘留 $tmp_leftovers 個；sudoers $(sudo ls /etc/sudoers.d | paste -sd,)"
EOF
)

  case $leftovers in
    "/tmp 殘留 0 個"*)
      ok "$host: $leftovers"
      ;;
    *)
      warn "$host: $leftovers"
      ;;
  esac
done

# 4. 要留什麼、要收什麼
landing_sizes=$(du -sh "$LANDING" "$REPO_DIR" 2>/dev/null | cut -f1 | paste -sd' ')
log "留在操作機：$CONF_DIR（範本產出的設定）、$PKI_DIR、$SECRETS_DIR（0600）、$MONITORING_DIR、~/install-logs"
log "可以刪：$LANDING、$REPO_DIR（$landing_sizes；套件庫才是正本）"
handover_request="交付時：OS 團隊移除各主機 /etc/sudoers.d/$SSH_USER（全權），只留 $SSH_USER-ops；"
handover_request+="$KEYS_DIR/svc-ops.key（SystemAdmin）和其他金鑰一樣留在操作機（0600）；"

ask_bank "$handover_request" \
         "    $SSH_KEY 留在操作機的獨立 file system（root、0400；不放 CyberArk、不備份，操作機重建就重新產生並重新佈署公鑰）。"

failure_summary="健康失敗 $health_failures、安全失敗 $security_failures、應用程式失敗 $application_failures"
log "驗收：$((CHECK_COUNT - FAIL_COUNT)) / $CHECK_COUNT 項通過（$failure_summary）"
finish_step
