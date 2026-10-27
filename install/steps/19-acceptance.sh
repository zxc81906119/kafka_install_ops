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
# 只讀為主；19.3 會寫兩筆測試訊息，19.4 會重啟一台 broker。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"   # count_plaintext_passwords
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
SECRETS_MODE_IN_USE=$(cat "$CONF_DIR/secrets.mode" 2>/dev/null || echo plain)
APP_CLIENT_CONF=$CONF_DIR/$FIRST_SCRAM_APP.properties
SENSITIVE_TOPIC=$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt" | awk -v prefix="$AUDIT_SENSITIVE_PREFIX" 'index($1, prefix) == 1 {print $1; exit}')
TEST_USERS_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass")

CHECK_COUNT=0
# check "說明" <指令…>：指令成功就 ok，否則 fail；同時計數
check() {
  local description=$1; shift
  CHECK_COUNT=$((CHECK_COUNT + 1))
  if "$@" >/dev/null 2>&1; then ok "$description"; else fail "$description"; fi
}
# http_code <curl 參數…>：只印 HTTP 狀態碼
http_code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@"; }
# mds_login_code <帳號> <密碼>：用 AD 帳密向 MDS 要 token 的 HTTP 狀態碼
mds_login_code() { http_code --cacert "$BANK_ROOT_CA" -u "$1:$2" "$MDS_URL/security/1.0/authenticate"; }
# 下面的 check 會用 bash -c 跑，函式與變數要 export 進去
export -f http_code mds_login_code
export BANK_ROOT_CA MDS_URL

# 測試用的 client 設定，沒有就建
if [ ! -f "$ALICE_CLIENT_CONF" ]; then
  (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=PLAIN\nsasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=%s/truststore.p12\nssl.truststore.password=%s\n' \
     "$TEST_USERS_PASSWORD" "$CERTS_DIR" "$(cat "$PKI_DIR/store.pass")" > "$ALICE_CLIENT_CONF")
fi
if [ ! -f "$APP_CLIENT_CONF" ]; then
  (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="%s" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=%s/truststore.p12\nssl.truststore.password=%s\n' \
     "$FIRST_SCRAM_APP" "$(cat "$SECRETS_DIR/$FIRST_SCRAM_APP.pass")" "$CERTS_DIR" "$(cat "$PKI_DIR/store.pass")" > "$APP_CLIENT_CONF")
fi

section "19.1 平台健康"
check "controller quorum 有 leader" bash -c "kafka-metadata-quorum --bootstrap-controller $FIRST_CONTROLLER:9093 --command-config $INTERNAL_CLIENT_CONF describe --status | grep -q 'LeaderId: *[0-9]'"
for host in $KAFKA_HOSTS; do check "$host confluent-server active" ssh_run "$host" 'systemctl is-active -q confluent-server'; done
for host in $BROKERS; do check "$host MDS 8090 回 200" bash -c "[ \"\$(http_code --cacert \$BANK_ROOT_CA https://$(fqdn "$host"):8090/v1/metadata/id)\" = 200 ]"; done
check "沒有 under-replicated partition" bash -c "[ \"\$(kafka-topics --bootstrap-server $BROKER_TOKEN --command-config $ADMIN_CLIENT_CONF --describe --under-replicated-partitions | grep -c Partition:)\" = 0 ]"
check "沒有 offline partition" bash -c "[ \"\$(kafka-topics --bootstrap-server $BROKER_TOKEN --command-config $ADMIN_CLIENT_CONF --describe --unavailable-partitions | grep -c Partition:)\" = 0 ]"
check "Self-Balancing 啟用" bash -c "kafka-rebalance-cluster --bootstrap-server $BROKER_TOKEN --command-config $ADMIN_CLIENT_CONF --status 2>/dev/null | grep -q 'Balancer status: ENABLED'"
check "REST Proxy 經負載平衡回 200（mTLS）" bash -c "[ \"\$(http_code --cacert \$BANK_ROOT_CA $(rest_app_curl_options) https://$REST_VIP:8082/v3/clusters)\" = 200 ]"
check "Control Center 9021 回 200" bash -c "[ \"\$(http_code --cacert \$BANK_ROOT_CA https://$C3_FQDN:9021/)\" = 200 ]"
check "C3 的 Prometheus 有 broker 指標" bash -c "curl -s --cacert $BANK_ROOT_CA --cert $CERTS_DIR/cp-server.crt --key $KEYS_DIR/cp-server.key https://$C3_FQDN:9090/api/v1/label/__name__/values | grep -q confluent_kafka_server"
if [ "$JMX_EXPORTER" = 1 ]; then
  for host in ${CONTROLLERS%% *} ${BROKERS%% *} ${RESTS%% *} $C3_HOST; do
    check "$host JMX exporter 7071 要帳密" bash -c "[ \"\$(http_code --cacert \$BANK_ROOT_CA https://$(fqdn "$host"):7071/metrics)\" = 401 ]"
  done
fi
health_failures=$FAIL_COUNT

section "19.2 安全：正向與反向"
check "AD 帳密正確 → MDS 給 token（200）" bash -c "[ \"\$(mds_login_code alice '$TEST_USERS_PASSWORD')\" = 200 ]"
check "AD 密碼錯 → 401" bash -c "[ \"\$(mds_login_code alice wrong-password)\" = 401 ]"
check "不存在的帳號 → 401" bash -c "[ \"\$(mds_login_code nobody '$TEST_USERS_PASSWORD')\" = 401 ]"
check "carol 在自己的 prefix 以外建 topic 被拒" bash -c "kafka-topics --bootstrap-server $FIRST_BROKER:9096 --command-config <(sed 's/username=\"alice\"/username=\"carol\"/' $ALICE_CLIENT_CONF) --create --topic ${AUDIT_SENSITIVE_PREFIX}carol-test --partitions 1 --replication-factor 3 2>&1 | grep -q TopicAuthorizationException"
check "$FIRST_SCRAM_APP 讀 $SENSITIVE_TOPIC 被拒" bash -c "kafka-console-consumer --bootstrap-server $FIRST_BROKER:9095 --consumer.config $APP_CLIENT_CONF --topic $SENSITIVE_TOPIC --max-messages 1 --timeout-ms 8000 2>&1 | grep -q TopicAuthorizationException"
check "REST Proxy 不帶憑證 → TLS 就拒絕" bash -c "! curl -s --cacert $BANK_ROOT_CA --max-time 10 https://$REST_VIP:8082/v3/clusters -o /dev/null"
check "REST Proxy 帶非 app 憑證（svc-ops）→ 401" bash -c "[ \"\$(http_code --cacert \$BANK_ROOT_CA --cert $CERTS_DIR/svc-ops.crt --key $KEYS_DIR/svc-ops.key https://$REST_VIP:8082/v3/clusters)\" = 401 ]"
check "CLIENT 9095 不帶 SASL → 失敗" bash -c "! kafka-topics --bootstrap-server $FIRST_BROKER:9095 --command-config <(printf 'security.protocol=SSL\nssl.truststore.type=PKCS12\nssl.truststore.location=$CERTS_DIR/truststore.p12\nssl.truststore.password=%s\n' \"\$(cat $PKI_DIR/store.pass)\") --list"
# 主機的 OS 已經信任銀行根憑證，所以「不帶 CA」不會失敗；要用一張無關的 CA 才測得出鏈驗證
check "用無關的 CA 驗 MDS 憑證會被拒（鏈驗證生效）" bash -c "! curl -s --max-time 10 --cacert <(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null -subj /CN=junk 2>/dev/null) $MDS_URL/v1/metadata/id -o /dev/null"
if [ "$SECRETS_MODE_IN_USE" != plain ]; then
  for host in ${BROKERS%% *} ${RESTS%% *} $C3_HOST; do
    plaintext_count=$(count_plaintext_passwords <(ssh_run "$host" "sudo cat $(props_path_of "$host")"))
    check "$host 的設定檔沒有明文密碼" test "$plaintext_count" = 0
  done
else
  warn "SECRETS_MODE=plain：設定檔裡的密碼是明文（0640），正式環境請走第 15 站"
fi
check "/etc/confluent/ssl 是 0750" ssh_run "${BROKERS%% *}" '[ "$(sudo stat -c %a /etc/confluent/ssl)" = 750 ]'
security_failures=$((FAIL_COUNT - health_failures))

section "19.3 應用程式端"
cluster_id=$(curl -s --cacert "$BANK_ROOT_CA" "$MDS_URL/v1/metadata/id" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
test_message="acceptance-$(date +%s)"
# 每個 app 用自己 prefix 的 topic：app-orders → orders.events；app-legacy-billing → billing.events
# consumer group 也要在 app 自己的 prefix 底下（conf/rbac.txt：app-orders 只能用 orders- 開頭的 group）
scram_app_group=${FIRST_SCRAM_APP#app-}-acceptance
scram_app_topic=$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt" | awk '{print $1}' | grep "^${FIRST_SCRAM_APP#app-}\." | head -1)
rest_app_topic=$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt" | awk '{print $1}' | grep "^${FIRST_REST_APP##*-}\." | head -1)
check "$FIRST_SCRAM_APP（SCRAM 直連）寫入 $scram_app_topic" bash -c "echo $test_message | kafka-console-producer --bootstrap-server $FIRST_BROKER:9095 --producer.config $APP_CLIENT_CONF --topic $scram_app_topic"
check "$FIRST_SCRAM_APP 讀回自己寫的" bash -c "kafka-console-consumer --bootstrap-server $FIRST_BROKER:9095 --consumer.config $APP_CLIENT_CONF --topic $scram_app_topic --group $scram_app_group --from-beginning --timeout-ms 45000 2>/dev/null | grep -q $test_message"
rest_body="{\"value\":{\"type\":\"JSON\",\"data\":\"$test_message-rest\"}}"
check "$FIRST_REST_APP 經負載平衡 + REST Proxy（mTLS）寫入 $rest_app_topic" bash -c "[ \"\$(http_code --cacert \$BANK_ROOT_CA $(rest_app_curl_options) -X POST -H 'Content-Type: application/json' -d '$rest_body' https://$REST_VIP:8082/v3/clusters/$cluster_id/topics/$rest_app_topic/records)\" = 200 ]"
check "alice 在 $rest_app_topic 讀到那筆" bash -c "kafka-console-consumer --bootstrap-server $FIRST_BROKER:9096 --consumer.config $ALICE_CLIENT_CONF --topic $rest_app_topic --group acceptance-alice --from-beginning --timeout-ms 45000 2>/dev/null | grep -q $test_message-rest"
application_failures=$((FAIL_COUNT - health_failures - security_failures))

section "19.4 維運"
if [ "$OPMENU" = 1 ]; then
  # 選單要維運人員本人互動登入（輸入 AD 帳密），非互動做不到（第 16 站同樣只提醒）
  warn "人工驗收項目：維運人員（bob）互動登入選單（經 PSMP 進操作機），選 21 重啟一台 broker；成功後把選單紀錄那一行附在驗收文件"
else
  log "OPMENU=0 或選單沒裝：略過選單重啟"
fi
cold_boot_expectation="master key 在各主機的 service.env，開機不依賴 PVWA；controller → broker 依序回來"
ask_bank "冷開機（全部主機同時關再開）由機房排程演練。預期：$cold_boot_expectation，" \
         "    C3 等 MDS 起來才啟動（第 13 站的 drop-in）。lab：bash install/lab/bank-sim.sh coldboot"

section "19.5 收尾：留什麼、收什麼"
rm -rf /tmp/jmx-* /tmp/*.properties 2>/dev/null
wrong_permissions=$(find ~ -maxdepth 3 -type f \( -name '*.key' -o -name '*.pass' -o -name 'master.key' \) ! -perm 600 2>/dev/null)
if [ -z "$wrong_permissions" ]; then ok "家目錄下的私鑰與密碼檔都是 0600"; else fail "權限不是 0600：$(paste -sd' ' <<<"$wrong_permissions")"; fi
for host in ${CONTROLLERS%% *} ${BROKERS%% *} ${RESTS%% *} $C3_HOST; do
  leftovers=$(ssh_script "$host" <<'EOF'
# JVM 自己的暫存檔（hsperfdata、lib*.so、com_*）不算殘留
tmp_leftovers=$(find /tmp -mindepth 1 -maxdepth 1 ! -name '.*' ! -name 'hsperfdata*' ! -name 'systemd-private*' ! -name 'lib*.so*' ! -name 'com_*' | wc -l)
echo "/tmp 殘留 $tmp_leftovers 個；sudoers $(sudo ls /etc/sudoers.d | paste -sd,)"
EOF
)
  case $leftovers in "/tmp 殘留 0 個"*) ok "$host: $leftovers";; *) warn "$host: $leftovers";; esac
done
log "留在操作機：$CONF_DIR（範本產出的設定）、$PKI_DIR、$SECRETS_DIR（0600）、$MONITORING_DIR、~/install-logs"
log "可以刪：$LANDING、$REPO_DIR（$(du -sh "$LANDING" "$REPO_DIR" 2>/dev/null | cut -f1 | paste -sd' ')；套件庫才是正本）"
ask_bank "交付時：OS 團隊移除各主機 /etc/sudoers.d/$SSH_USER（全權），只留 $SSH_USER-ops；$KEYS_DIR/svc-ops.key（super user）移到離線保管；" \
         "    $SSH_KEY 留在操作機的獨立 file system（root、0400；不放 CyberArk、不備份，操作機重建就重新產生並重新佈署公鑰）。"
log "驗收：$((CHECK_COUNT - FAIL_COUNT)) / $CHECK_COUNT 項通過（健康失敗 $health_failures、安全失敗 $security_failures、應用程式失敗 $application_failures）"
finish_step
