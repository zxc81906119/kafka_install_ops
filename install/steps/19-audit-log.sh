#!/usr/bin/env bash
# 第 19 站：稽核日誌 —— 專用低權限寫入帳號、敏感 topic 的事件分開放（365 天）、排除平台自己的雜訊
# where: ops02 （cpadmin）
#
# 何時用：AUDIT_LOG=1。
# 做什麼：
#   19.1 SCRAM 帳號 confluent-audit，只有 confluent-audit-log-events* 的 Write／Manage（不是 super user）
#   19.2 templates/audit.tpl 接在 common 後面 → 重新產生 7 台 server.properties → 密碼依 15／16 站的模式處理 → 派送、滾動重啟
#   19.3 製造事件：alice 寫敏感 topic（允許）、app 想讀敏感 topic（拒絕）→ 兩筆都要出現在 _sensitive
# 密碼怎麼放：看 ~/conf/secrets.mode（15、16 站留下的）
#   sp     重新加密（新增的 audit 密碼一起進 security.properties）；16.9 開著時 AD 查詢密碼一樣走 env
#   conjur audit 密碼寫進 Conjur，範本裡改成 ${cyberark:…}
#   plain  明文（沒做 15／16 的狀態，不建議）
# 重跑：安全。改路由規則＝改 templates/audit.tpl 再跑這一站。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"
source "$INSTALL_DIR/lib/vault.sh"
if [ "$AUDIT_LOG" != 1 ]; then log "AUDIT_LOG=$AUDIT_LOG：略過第 19 站"; exit 0; fi
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

SECRETS_MODE_IN_USE=$(cat "$CONF_DIR/secrets.mode" 2>/dev/null || echo plain)
AUDIT_PASSWORD_FILE=$SECRETS_DIR/confluent-audit.pass
AUDIT_FRAGMENT=$CONF_DIR/audit.rendered.tpl     # 換好主機清單、密碼變數還留著的片段（第 16 站重跑時也會用到）
AUDIT_CONF_DIR=$CONF_DIR/audit                  # 這一站產出的每台 server.properties
SENSITIVE_TOPIC=$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt" | awk -v prefix="$AUDIT_SENSITIVE_PREFIX" 'index($1, prefix) == 1 {print $1; exit}')
[ -n "$SENSITIVE_TOPIC" ] || die "conf/topics.txt 沒有以 $AUDIT_SENSITIVE_PREFIX 開頭的 topic（19.3 要用它製造事件）"
log "密碼放法：$SECRETS_MODE_IN_USE（15／16 站留下的）；敏感 topic：$AUDIT_SENSITIVE_PREFIX*（測試用 $SENSITIVE_TOPIC）"

section "19.1 專用寫入帳號 confluent-audit"
(umask 077; [ -s "$AUDIT_PASSWORD_FILE" ] || openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$AUDIT_PASSWORD_FILE")
scram_config="SCRAM-SHA-512=[iterations=8192,password=$(cat "$AUDIT_PASSWORD_FILE")]"
if kafka-configs --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --alter --entity-type users --entity-name confluent-audit \
     --add-config "$scram_config" >/dev/null 2>&1; then ok "confluent-audit: scram"; else fail "confluent-audit: scram"; fi
unset scram_config
confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
  --client-cert-path "$CERTS_DIR/svc-ops.crt" --client-key-path "$KEYS_DIR/svc-ops.key" >/dev/null 2>&1 || die "confluent login 失敗"
source "$CONF_DIR/kraft.env"   # CLUSTER_ID
for role in DeveloperWrite DeveloperManage; do
  # prefix 綁定同時涵蓋 confluent-audit-log-events 與 confluent-audit-log-events_sensitive
  if confluent iam rbac role-binding create --principal User:confluent-audit --role $role --resource Topic:confluent-audit-log-events --prefix \
       --kafka-cluster "$CLUSTER_ID" >/dev/null 2>&1 </dev/null; then ok "confluent-audit $role Topic:confluent-audit-log-events PREFIXED"
  else fail "confluent-audit $role"; fi
done
[ "$FAIL_COUNT" = 0 ] || die "19.1 失敗"

section "19.2 設定片段：寫入者、路由（$AUDIT_SENSITIVE_PREFIX* → _sensitive）、保留天數"
export AUDIT_SENSITIVE_PREFIX BROKER_CLIENT
# 只換主機清單與 prefix；${STORE_PASSWORD}、${AUDIT_PASSWORD} 留著，下面依密碼放法處理（所以這裡 render 會報「還有沒換掉的」，是預期的）
render_template "$TEMPLATE_DIR/audit.tpl" "$AUDIT_FRAGMENT" BROKER_CLIENT AUDIT_SENSITIVE_PREFIX 2>/dev/null || true
[ "$(grep -c 'security.event' "$AUDIT_FRAGMENT")" = 11 ] || die "audit 片段產生失敗"

export CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN
export HOST_FQDN NODE_ID RACK HOST_SHORT
COMMON_VARS="HOST_FQDN NODE_ID RACK CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN"
install -d -m 0700 "$AUDIT_CONF_DIR"
case $SECRETS_MODE_IN_USE in
  sp|plain)
    export STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD
    STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
    LDAP_BIND_PASSWORD=$(cat "$SECRETS_DIR/ldap-bind.pass")
    AUDIT_PASSWORD=$(cat "$AUDIT_PASSWORD_FILE")
    TEMPLATE_VARS="$COMMON_VARS STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD"
    SOURCE_TEMPLATES=$TEMPLATE_DIR           # 明文範本，渲染後再加密
    AUDIT_TEMPLATE=$AUDIT_FRAGMENT;;
  conjur)
    vault_login_as_ops || die "ops 身分登入保管庫失敗"
    if tr -d '\n' < "$AUDIT_PASSWORD_FILE" | vault_set audit-password; then ok "set $VAULT_POLICY/audit-password"
    else die "保管庫沒有 audit-password 變數（policy 要先加）"; fi
    vault_logout
    sed -e "s|\${STORE_PASSWORD}|\${cyberark:$VAULT_POLICY/store-password:$VAULT_POLICY/store-password}|g" \
        -e "s|\${AUDIT_PASSWORD}|\${cyberark:$VAULT_POLICY/audit-password:$VAULT_POLICY/audit-password}|g" "$AUDIT_FRAGMENT" > "$CONF_DIR/conjur/audit.tpl"
    export VAULT_URL VAULT_ACCOUNT VAULT_POLICY CONJUR_API_KEY
    TEMPLATE_VARS="$COMMON_VARS HOST_SHORT CONJUR_API_KEY VAULT_URL VAULT_ACCOUNT VAULT_POLICY"
    SOURCE_TEMPLATES=$CONF_DIR/conjur        # 第 15 站改成 ${cyberark:…} 的範本
    AUDIT_TEMPLATE=$CONF_DIR/conjur/audit.tpl;;
esac
[ "$SECRETS_MODE_IN_USE" = sp ] && export CONFLUENT_SECURITY_MASTER_KEY=$(cat "$SECRETS_DIR/master.key")

for host in $KAFKA_HOSTS; do
  HOST_FQDN=$(fqdn "$host"); NODE_ID=$(node_id_of "$host"); RACK=$(rack_of "$host"); HOST_SHORT=$host
  [ "$SECRETS_MODE_IN_USE" = conjur ] && CONJUR_API_KEY=$(ssh_run "$host" "sudo cat $VAULT_HOST_KEY")
  case $host in kc*) role_template=$SOURCE_TEMPLATES/controller.tpl;; *) role_template=$SOURCE_TEMPLATES/broker.tpl;; esac
  props_file=$AUDIT_CONF_DIR/$host.properties
  # shellcheck disable=SC2086
  render_templates "$props_file" $TEMPLATE_VARS -- "$role_template" "$SOURCE_TEMPLATES/common.tpl" "$AUDIT_TEMPLATE" || { fail "$host: render"; continue; }
  upload_files=("$props_file")
  if [ "$SECRETS_MODE_IN_USE" = sp ]; then
    [ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && sed -i 's|^ldap.java.naming.security.credentials=.*|ldap.java.naming.security.credentials=${env:LDAP_BIND_PASSWORD}|' "$props_file"
    encrypt_passwords "$props_file" "$SECRETS_DIR/security.properties" /etc/confluent/secrets/security.properties || { fail "$host: encrypt"; continue; }
    [ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && ldap_password_from_env "$props_file"
    upload_files+=("$SECRETS_DIR/security.properties")
  fi
  copy_to_tmp "$host" "${upload_files[@]}" || { fail "$host: scp"; continue; }
  result=$(ssh_script "$host" HOST="$host" <<'EOF'
props=/etc/confluent/kafka/server.properties
sudo install -o root -g confluent -m 0640 /tmp/$HOST.properties $props && rm -f /tmp/$HOST.properties
if [ -f /tmp/security.properties ]; then
  sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && rm -f /tmp/security.properties
fi
plaintext=$(sudo grep -cE '^[^#].*(password|credentials|jaas.config) *= *[^$ ]' $props)
echo "audit_lines=$(sudo grep -c security.event $props) plaintext=$plaintext"
EOF
)
  if [ "$SECRETS_MODE_IN_USE" = plain ]; then
    case $result in audit_lines=11*) ok "$host: $result（plain 模式，密碼是明文）";; *) fail "$host: $result";; esac
  else
    if [ "$result" = "audit_lines=11 plaintext=0" ]; then ok "$host: $result"; else fail "$host: $result"; fi
  fi
done
unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD CONJUR_API_KEY CONFLUENT_SECURITY_MASTER_KEY
[ "$FAIL_COUNT" = 0 ] || die "派送失敗，不重啟"
rolling_restart controllers brokers || die "滾動重啟有主機沒健康"
sleep 20
audit_topic_count=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --list 2>/dev/null | grep -c '^confluent-audit-log-events')
if [ "$audit_topic_count" = 2 ]; then ok "audit topic 2 個（預設 + _sensitive）"; else fail "audit topic 只有 $audit_topic_count 個"; fi

section "19.3 製造事件、讀回來"
# alice 的 client 設定（LDAP listener、AD 帳密）與一個 SCRAM app 的 client 設定，沒有就建
if [ ! -f "$ALICE_CLIENT_CONF" ]; then
  (umask 077; cat > "$ALICE_CLIENT_CONF" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="$(cat "$SECRETS_DIR/ad-test-users.pass")";
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$(cat "$PKI_DIR/store.pass")
EOF
)
fi
APP_CLIENT_CONF=$CONF_DIR/$FIRST_SCRAM_APP.properties
if [ ! -f "$APP_CLIENT_CONF" ]; then
  (umask 077; cat > "$APP_CLIENT_CONF" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$FIRST_SCRAM_APP" password="$(cat "$SECRETS_DIR/$FIRST_SCRAM_APP.pass")";
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$(cat "$PKI_DIR/store.pass")
EOF
)
fi
if echo "audit-test-$(date +%s)" | kafka-console-producer --bootstrap-server "$FIRST_BROKER:9096" --producer.config "$ALICE_CLIENT_CONF" --topic "$SENSITIVE_TOPIC" >/dev/null 2>&1
then ok "alice 寫入 $SENSITIVE_TOPIC（允許，應記到 _sensitive）"; else fail "alice 寫入 $SENSITIVE_TOPIC 失敗"; fi
if kafka-console-consumer --bootstrap-server "$FIRST_BROKER:9095" --consumer.config "$APP_CLIENT_CONF" --topic "$SENSITIVE_TOPIC" --group audit-sneak \
     --max-messages 1 --timeout-ms 10000 2>&1 | grep -q 'TopicAuthorizationException'
then ok "$FIRST_SCRAM_APP 讀 $SENSITIVE_TOPIC 被拒（拒絕，應記到 _sensitive）"; else fail "$FIRST_SCRAM_APP 讀 $SENSITIVE_TOPIC 沒被拒"; fi
sleep 10   # 等事件寫進 audit topic
# 每個事件是一行 JSON。只用 grep 數：同一行裡同時有「誰」「做什麼」「准或拒」的就算一筆
sensitive_events=$(kafka-console-consumer --bootstrap-server "$FIRST_BROKER:9096" --consumer.config "$ALICE_CLIENT_CONF" \
                     --topic confluent-audit-log-events_sensitive --from-beginning --timeout-ms 20000 2>/dev/null | tr -d ' ')
alice_produce_allowed=$(grep '"principal":"User:alice"' <<<"$sensitive_events" | grep '"methodName":"kafka.Produce"' | grep -c '"granted":true')
app_denied=$(grep "\"principal\":\"User:$FIRST_SCRAM_APP\"" <<<"$sensitive_events" | grep -c '"granted":false')
event_counts="alice 寫入（允許）$alice_produce_allowed 筆、$FIRST_SCRAM_APP（拒絕）$app_denied 筆"
if [ "$alice_produce_allowed" -gt 0 ] && [ "$app_denied" -gt 0 ]; then ok "_sensitive 裡：$event_counts"; else fail "_sensitive 裡：$event_counts"; fi
log "預設只記管理／授權事件；一般 topic 的 produce／consume 只在路由列出的 topic（$AUDIT_SENSITIVE_PREFIX*）才記。"
finish_step
