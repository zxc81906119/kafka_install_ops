#!/usr/bin/env bash
# 第 18 站：稽核日誌 —— 專用低權限寫入帳號、敏感 topic 的事件分開放（365 天）、排除平台自己的雜訊
# where: ops02 （root）
#
# 做什麼：
#   18.1 SCRAM 帳號 confluent-audit，只有 confluent-audit-log-events* 的 Write／Manage（不是 super user）
#   18.2 templates/audit.tpl 接在 common 後面 → 重新產生 7 台 server.properties → 密碼依第 15 站的模式處理 → 派送、滾動重啟
#   18.3 製造事件：alice 寫敏感 topic（允許）、app 想讀敏感 topic（拒絕）→ 兩筆都要出現在 _sensitive
# 需要什麼：AUDIT_LOG=1；第 11 站的 RBAC。密碼怎麼放看 ~/conf/secrets.mode（第 15 站留下的）：
#   sp     重新加密（新增的 audit 密碼一起進 security.properties）
#   plain  明文（沒做第 15 站的狀態，不建議）
# 產出什麼：~/secrets/confluent-audit.pass、~/conf/audit.rendered.tpl（第 10、15 站重跑時會帶上）、~/conf/audit/<主機>.server.properties
# 能不能重跑：安全。改路由規則＝改 templates/audit.tpl 再跑這一站。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"

if [ "$AUDIT_LOG" != 1 ]; then
  log "AUDIT_LOG=$AUDIT_LOG：略過第 18 站"
  exit 0
fi

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

SECRETS_MODE_IN_USE=$(secrets_mode_in_use)
AUDIT_PASSWORD_FILE=$SECRETS_DIR/confluent-audit.pass
AUDIT_FRAGMENT=$CONF_DIR/audit.rendered.tpl     # 換好主機清單、密碼變數還留著的片段（第 15 站重跑時也會用到）
AUDIT_CONF_DIR=$CONF_DIR/audit                  # 這一站產出的每台 server.properties
APP_CLIENT_CONF=$CONF_DIR/$FIRST_SCRAM_APP.properties
# conf/topics.txt 裡第一個以 $AUDIT_SENSITIVE_PREFIX 開頭的 topic（第一欄是 topic 名稱）
SENSITIVE_TOPIC=""
topic_names=$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt" | awk '{print $1}')

for topic_name in $topic_names; do
  if [[ $topic_name == "$AUDIT_SENSITIVE_PREFIX"* ]]; then
    SENSITIVE_TOPIC=$topic_name
    break
  fi
done

if [ -z "$SENSITIVE_TOPIC" ]; then
  die "conf/topics.txt 沒有以 $AUDIT_SENSITIVE_PREFIX 開頭的 topic（18.3 要用它製造事件）"
fi
log "密碼放法：$SECRETS_MODE_IN_USE（第 15 站留下的）；敏感 topic：$AUDIT_SENSITIVE_PREFIX*（測試用 $SENSITIVE_TOPIC）"

# plaintext_count_on_host <主機>：那台 server.properties 裡還有幾個明文密碼欄位
#   count_plaintext_passwords 會把檔案讀兩次，所以先存成暫存檔（mktemp 0600，用完即刪），不能用 <(…)：管線只讀得到一次
plaintext_count_on_host() {
  local host=$1 props_copy count
  props_copy=$(mktemp)
  if ! ssh_run "$host" "sudo cat /etc/confluent/kafka/server.properties" > "$props_copy"; then
    rm -f "$props_copy"
    echo "讀不到"
    return
  fi

  count=$(count_plaintext_passwords "$props_copy")
  rm -f "$props_copy"
  echo "$count"
}

section "18.1 專用寫入帳號 confluent-audit"

# 1. 寫入帳號的密碼（已經有就沿用；檔案 0600）
if [ ! -s "$AUDIT_PASSWORD_FILE" ]; then
  install -m 0600 /dev/null "$AUDIT_PASSWORD_FILE"
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$AUDIT_PASSWORD_FILE"
fi

# 2. 建 SCRAM 帳號
scram_config="SCRAM-SHA-512=[iterations=8192,password=$(cat "$AUDIT_PASSWORD_FILE")]"
if kafka-configs --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" \
     --alter --entity-type users --entity-name confluent-audit \
     --add-config "$scram_config" >/dev/null 2>&1; then
  ok "confluent-audit: scram"
else
  fail "confluent-audit: scram"
fi
unset scram_config

# 3. 權限：svc-ops 登入 MDS 來綁
if ! confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
     --client-cert-path "$CERTS_DIR/svc-ops.crt" --client-key-path "$KEYS_DIR/svc-ops.key" >/dev/null 2>&1; then
  die "confluent login 失敗"
fi
source "$CONF_DIR/kraft.env"   # CLUSTER_ID

for role in DeveloperWrite DeveloperManage; do
  # prefix 綁定同時涵蓋 confluent-audit-log-events 與 confluent-audit-log-events_sensitive
  if mds_write confluent iam rbac role-binding create --principal User:confluent-audit --role $role \
       --resource Topic:confluent-audit-log-events --prefix \
       --kafka-cluster "$CLUSTER_ID" >/dev/null 2>&1 </dev/null; then
    ok "confluent-audit $role Topic:confluent-audit-log-events PREFIXED"
  else
    fail "confluent-audit $role"
  fi
done

if [ "$FAIL_COUNT" != 0 ]; then
  die "18.1 失敗"
fi

section "18.2 設定片段：寫入者、路由（$AUDIT_SENSITIVE_PREFIX* → _sensitive）、保留天數"

# 1. 設定片段：只換主機清單與 prefix；${STORE_PASSWORD}、${AUDIT_PASSWORD} 留著，下面依密碼放法處理
#    （所以這裡 render 會報「還有沒換掉的」，是預期的，不看它的結束碼）
export AUDIT_SENSITIVE_PREFIX BROKER_CLIENT
render_template "$TEMPLATE_DIR/audit.tpl" "$AUDIT_FRAGMENT" BROKER_CLIENT AUDIT_SENSITIVE_PREFIX 2>/dev/null

audit_line_count=$(awk '/security.event/ {c++} END {print c + 0}' "$AUDIT_FRAGMENT")
if [ "$audit_line_count" != 11 ]; then
  die "audit 片段產生失敗"
fi

# 2. 範本要的變數與密碼（密碼讀進變數，用完 unset）
case $SECRETS_MODE_IN_USE in
  sp|plain)
    ;;
  *)
    die "密碼放法是 $SECRETS_MODE_IN_USE：不認得"
    ;;
esac

export CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE \
  AD_GROUP_SEARCH_BASE AD_GROUP_SEARCH_FILTER AD_GROUP_MEMBER_PATTERN C3_FQDN
export HOST_FQDN NODE_ID RACK
export STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
LDAP_BIND_PASSWORD=$(cat "$SECRETS_DIR/ldap-bind.pass")
AUDIT_PASSWORD=$(cat "$AUDIT_PASSWORD_FILE")
TEMPLATE_VARS="HOST_FQDN NODE_ID RACK CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN "
TEMPLATE_VARS+="AD_SEARCH_BASE AD_GROUP_SEARCH_BASE AD_GROUP_SEARCH_FILTER AD_GROUP_MEMBER_PATTERN C3_FQDN "
TEMPLATE_VARS+="STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD"

if [ "$SECRETS_MODE_IN_USE" = sp ]; then
  CONFLUENT_SECURITY_MASTER_KEY=$(cat "$SECRETS_DIR/master.key")
  export CONFLUENT_SECURITY_MASTER_KEY
fi

# 3. 7 台：產生設定、加密、派送
install -d -m 0700 "$AUDIT_CONF_DIR"
for host in $KAFKA_HOSTS; do
  HOST_FQDN=$(fqdn "$host")
  NODE_ID=$(node_id_of "$host")
  RACK=$(rack_of "$host")

  case $host in
    kc*)
      role_template=$TEMPLATE_DIR/controller.tpl
      ;;
    *)
      role_template=$TEMPLATE_DIR/broker.tpl
      ;;
  esac

  # 檔名就是密文的 key（${securepass:…:<檔名>/<欄位>}）：要和第 15 站、手冊 15.3 同一個名字 <主機>.server.properties，
  # 否則之後 confluent secret file update（換 AD 密碼）只會新增幾行，主機上用的還是舊密文
  props_file=$AUDIT_CONF_DIR/$host.server.properties

  # shellcheck disable=SC2086  # TEMPLATE_VARS 要拆成一個一個變數名
  if ! render_templates "$props_file" $TEMPLATE_VARS -- \
       "$role_template" "$TEMPLATE_DIR/common.tpl" "$AUDIT_FRAGMENT"; then
    fail "$host: render"
    continue
  fi

  upload_files=("$props_file")
  if [ "$SECRETS_MODE_IN_USE" = sp ]; then
    if ! encrypt_passwords "$props_file" "$SECRETS_DIR/security.properties" \
         /etc/confluent/secrets/security.properties; then
      fail "$host: encrypt"
      continue
    fi

    upload_files+=("$SECRETS_DIR/security.properties")
  fi

  if ! copy_to_tmp "$host" "${upload_files[@]}"; then
    fail "$host: scp"
    continue
  fi

  result=$(ssh_script "$host" HOST="$host" <<'EOF'
props=/etc/confluent/kafka/server.properties

if sudo install -o root -g confluent -m 0640 /tmp/$HOST.server.properties $props; then
  rm -f /tmp/$HOST.server.properties
fi

if [ -f /tmp/security.properties ]; then
  if sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties; then
    rm -f /tmp/security.properties
  fi
fi

echo "audit_lines=$(sudo grep -c security.event $props)"
EOF
)
  result="$result plaintext=$(plaintext_count_on_host "$host")"

  if [ "$SECRETS_MODE_IN_USE" = plain ]; then
    case $result in
      audit_lines=11*)
        ok "$host: $result（plain 模式，密碼是明文）"
        ;;
      *)
        fail "$host: $result"
        ;;
    esac
  else
    if [ "$result" = "audit_lines=11 plaintext=0" ]; then
      ok "$host: $result"
    else
      fail "$host: $result"
    fi
  fi
done
unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD CONFLUENT_SECURITY_MASTER_KEY

if [ "$FAIL_COUNT" != 0 ]; then
  die "派送失敗，不重啟"
fi

# 4. 滾動重啟；等 20 秒，兩個稽核 topic 都建好了
if ! rolling_restart controllers brokers; then
  die "滾動重啟有主機沒健康"
fi
sleep 20

audit_topic_count=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" \
  --list 2>/dev/null \
  | awk '/^confluent-audit-log-events/ {c++} END {print c + 0}')
if [ "$audit_topic_count" = 2 ]; then
  ok "audit topic 2 個（預設 + _sensitive）"
else
  fail "audit topic 只有 $audit_topic_count 個"
fi

section "18.3 製造事件、讀回來"

# 1. alice 的 client 設定（LDAP listener、AD 帳密）與一個 SCRAM app 的 client 設定，沒有就建（檔案 0600）
store_password=$(cat "$PKI_DIR/store.pass")

if [ ! -f "$ALICE_CLIENT_CONF" ]; then
  alice_password=$(cat "$SECRETS_DIR/ad-test-users.pass")
  install -m 0600 /dev/null "$ALICE_CLIENT_CONF"
  cat > "$ALICE_CLIENT_CONF" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="$alice_password";
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$store_password
EOF
  unset alice_password
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

# 2. alice 往敏感 topic 寫一筆（允許、敏感）
if echo "audit-test-$(date +%s)" | kafka-console-producer --bootstrap-server "$FIRST_BROKER:9096" \
     --producer.config "$ALICE_CLIENT_CONF" --topic "$SENSITIVE_TOPIC" >/dev/null 2>&1; then
  ok "alice 寫入 $SENSITIVE_TOPIC（允許，應記到 _sensitive）"
else
  fail "alice 寫入 $SENSITIVE_TOPIC 失敗"
fi

# 3. app 讀敏感 topic（沒有權限：拒絕、敏感）；group 用 app 自己 prefix 底下的（和手冊 18.3 一樣），被拒的才會是 topic 權限
consumer_output=$(kafka-console-consumer --bootstrap-server "$FIRST_BROKER:9095" \
     --consumer.config "$APP_CLIENT_CONF" --topic "$SENSITIVE_TOPIC" \
     --group "${FIRST_SCRAM_APP#app-}-sneak" --max-messages 1 --timeout-ms 10000 2>&1)
if grep -q 'TopicAuthorizationException' <<<"$consumer_output"; then
  ok "$FIRST_SCRAM_APP 讀 $SENSITIVE_TOPIC 被拒（拒絕，應記到 _sensitive）"
else
  fail "$FIRST_SCRAM_APP 讀 $SENSITIVE_TOPIC 沒被拒"
fi

# 4. 等事件寫進 audit topic，讀回來
sleep 10
sensitive_events=$(kafka-console-consumer --bootstrap-server "$FIRST_BROKER:9096" \
                     --consumer.config "$ALICE_CLIENT_CONF" \
                     --topic confluent-audit-log-events_sensitive --from-beginning --timeout-ms 20000 2>/dev/null \
                     | tr -d ' ')

# 5. 每個事件是一行 JSON：同一行裡同時有「誰」「做什麼」「准或拒」的就算一筆
alice_produce_allowed=$(awk \
  '/"principal":"User:alice"/ && /"methodName":"kafka.Produce"/ && /"granted":true/ {c++} END {print c + 0}' \
  <<<"$sensitive_events")
app_denied=$(awk -v principal="\"principal\":\"User:$FIRST_SCRAM_ACCOUNT\"" \
  'index($0, principal) && /"granted":false/ {c++} END {print c + 0}' \
  <<<"$sensitive_events")

# 6. 判斷結果
event_counts="alice 寫入（允許）$alice_produce_allowed 筆、$FIRST_SCRAM_APP（拒絕）$app_denied 筆"
if [ "$alice_produce_allowed" -gt 0 ] && [ "$app_denied" -gt 0 ]; then
  ok "_sensitive 裡：$event_counts"
else
  fail "_sensitive 裡：$event_counts"
fi

log "預設只記管理／授權事件；一般 topic 的 produce／consume 只在路由列出的 topic（$AUDIT_SENSITIVE_PREFIX*）才記。"
finish_step
