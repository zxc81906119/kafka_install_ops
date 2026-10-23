#!/usr/bin/env bash
# 第 19 站：稽核日誌 —— 專用低權限寫入帳號、敏感 topic 的事件分開放（365 天）、排除平台雜訊；密碼依 SECRETS_MODE 處理
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"; source "$D/lib/render.sh"; source "$D/lib/vault.sh"
[ "$AUDIT_LOG" = 1 ] || { log "AUDIT_LOG=$AUDIT_LOG：略過第 19 站"; exit 0; }
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
T=$D/templates; C=$PKI_DIR/certs; ADMIN=$CONF_DIR/client-admin.properties; MDS1=https://$(fqdn "${BROKERS%% *}"):8090
MODE=$(cat "$CONF_DIR/secrets.mode" 2>/dev/null || echo plain); log "密碼放法：$MODE（第 15／16 站留下的）"
SENS_TOPIC=$(grep -v '^#' "$D/conf/topics.txt" | awk -v p="$AUDIT_SENSITIVE_PREFIX" 'index($1,p)==1{print $1; exit}'); [ -n "$SENS_TOPIC" ] || die "conf/topics.txt 沒有以 $AUDIT_SENSITIVE_PREFIX 開頭的 topic"

section "19.1 專用寫入帳號 confluent-audit（SCRAM，只有 audit topic 的 Write／Manage，不是 super user）"
(umask 077; [ -s "$SECRETS_DIR/confluent-audit.pass" ] || openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS_DIR/confluent-audit.pass")
P=$(cat "$SECRETS_DIR/confluent-audit.pass"); kafka-configs --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN" --alter --entity-type users --entity-name confluent-audit --add-config "SCRAM-SHA-512=[iterations=8192,password=$P]" >/dev/null 2>&1 && ok "confluent-audit: scram" || fail "confluent-audit scram"; unset P
confluent login --url "$MDS1" --certificate-authority-path "$C/bank-root.pem" --certificate-only --client-cert-path "$C/svc-ops.crt" --client-key-path "$PKI_DIR/keys/svc-ops.key" >/dev/null 2>&1 || die "confluent login 失敗"
source "$CONF_DIR/kraft.env"
for r in DeveloperWrite DeveloperManage; do confluent iam rbac role-binding create --principal User:confluent-audit --role $r --resource Topic:confluent-audit-log-events --prefix --kafka-cluster "$CLUSTER_ID" >/dev/null 2>&1 </dev/null && ok "rbac confluent-audit $r Topic:confluent-audit-log-events PREFIXED" || fail "rbac $r"; done
[ "${FAILED:-0}" = 0 ] || die "19.1 失敗"

section "19.2 設定片段接在 common 後面（controller 與 broker），重新產生 7 台 server.properties、依 $MODE 處理密碼、派送"
export BROKER_CLIENT; BROKER_CLIENT=$(join_fqdn 9095 $BROKERS); export AUDIT_SENSITIVE_PREFIX
render "$T/audit.tpl" "$CONF_DIR/audit.rendered.tpl" BROKER_CLIENT AUDIT_SENSITIVE_PREFIX >/dev/null 2>&1 || true   # 密碼變數刻意留著，給第 16 站重跑時用
[ "$(grep -c 'security.event' "$CONF_DIR/audit.rendered.tpl")" = 11 ] || die "audit 片段渲染失敗"
export CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN
BASE_VARS="HOST_FQDN NODE_ID RACK CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN"
install -d -m 0700 "$CONF_DIR/audit"
case $MODE in
  sp|plain)
    export STORE_PASSWORD; STORE_PASSWORD=$(cat "$PKI_DIR/store.pass"); export LDAP_BIND_PASSWORD; LDAP_BIND_PASSWORD=$(cat "$SECRETS_DIR/ldap-bind.pass"); export AUDIT_PASSWORD; AUDIT_PASSWORD=$(cat "$SECRETS_DIR/confluent-audit.pass")
    VARS="$BASE_VARS STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD"; TD=$T; EXTRA=$CONF_DIR/audit.rendered.tpl;;
  conjur)
    vault_login_ops || die "ops 身分登入保管庫失敗"; tr -d '\n' < "$SECRETS_DIR/confluent-audit.pass" | vault_set audit-password && ok "set $VAULT_POLICY/audit-password" || die "保管庫沒有 audit-password 變數（policy 要先加）"; vault_logout
    sed -e "s|\${STORE_PASSWORD}|\${cyberark:$VAULT_POLICY/store-password:$VAULT_POLICY/store-password}|g" -e "s|\${AUDIT_PASSWORD}|\${cyberark:$VAULT_POLICY/audit-password:$VAULT_POLICY/audit-password}|g" "$CONF_DIR/audit.rendered.tpl" > "$CONF_DIR/conjur/audit.tpl"
    export VAULT_URL VAULT_ACCOUNT VAULT_POLICY; VARS="$BASE_VARS HOST_SHORT CONJUR_API_KEY VAULT_URL VAULT_ACCOUNT VAULT_POLICY"; TD=$CONF_DIR/conjur; EXTRA=$CONF_DIR/conjur/audit.tpl;;
esac
[ "$MODE" = sp ] && { export CONFLUENT_SECURITY_MASTER_KEY; CONFLUENT_SECURITY_MASTER_KEY=$(cat "$SECRETS_DIR/master.key"); }
for h in $KAFKA_HOSTS; do
  export HOST_FQDN; HOST_FQDN=$(fqdn "$h"); id_var=NODE_ID_$h; rack_var=RACK_$h; export NODE_ID=${!id_var} RACK=${!rack_var} HOST_SHORT=$h
  [ "$MODE" = conjur ] && { export CONJUR_API_KEY; CONJUR_API_KEY=$(rsh "$h" "sudo cat $VAULT_HOST_KEY"); }
  case $h in kc*) tpl=$TD/controller.tpl;; *) tpl=$TD/broker.tpl;; esac
  f=$CONF_DIR/audit/$h.properties
  render_cat "$f" $VARS -- "$tpl" "$TD/common.tpl" "$EXTRA" || { fail "$h: render"; continue; }
  if [ "$MODE" = sp ]; then
    [ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && sed -i 's|^ldap.java.naming.security.credentials=.*|ldap.java.naming.security.credentials=${env:LDAP_BIND_PASSWORD}|' "$f"
    protect_file "$f" "$SECRETS_DIR/security.properties" /etc/confluent/secrets/security.properties || { fail "$h: encrypt"; continue; }
    [ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && ldap_via_env "$f"
    rcp "$h" "$f" "$SECRETS_DIR/security.properties" || { fail "$h: scp"; continue; }
    r=$(rsh "$h" "sudo install -o root -g confluent -m 0640 /tmp/$h.properties /etc/confluent/kafka/server.properties && sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && rm -f /tmp/$h.properties /tmp/security.properties && echo \"audit_lines=\$(sudo grep -c security.event /etc/confluent/kafka/server.properties) plaintext=\$(sudo grep -cE '^[^#].*(password|credentials|jaas.config) *= *[^$ ]' /etc/confluent/kafka/server.properties)\"")
  else
    rcp "$h" "$f" || { fail "$h: scp"; continue; }
    r=$(rsh "$h" "sudo install -o root -g confluent -m 0640 /tmp/$h.properties /etc/confluent/kafka/server.properties && rm -f /tmp/$h.properties && echo \"audit_lines=\$(sudo grep -c security.event /etc/confluent/kafka/server.properties) plaintext=\$(sudo grep -cE '^[^#].*(password|credentials|jaas.config) *= *[^$ ]' /etc/confluent/kafka/server.properties)\"")
  fi
  if [ "$MODE" = plain ]; then [[ $r == audit_lines=11* ]] && ok "$h: $r（plain 模式，密碼是明文）" || fail "$h: $r"; else [ "$r" = "audit_lines=11 plaintext=0" ] && ok "$h: $r" || fail "$h: $r"; fi
done
unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD CONJUR_API_KEY CONFLUENT_SECURITY_MASTER_KEY
[ "${FAILED:-0}" = 0 ] || die "派送失敗，不重啟"
for h in $CONTROLLERS; do restart_wait "$h" confluent-server - | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
for h in $BROKERS; do restart_wait "$h" confluent-server "https://$(fqdn "$h"):8090/v1/metadata/id" | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
[ "${FAILED:-0}" = 0 ] || die "滾動重啟有主機沒健康"
sleep 20; t=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN" --list 2>/dev/null | grep -c '^confluent-audit-log-events'); [ "$t" = 2 ] && ok "audit topic 2 個（預設 + _sensitive）" || fail "audit topic 只有 $t 個"

section "19.3 製造事件、讀回來：alice 寫 $SENS_TOPIC（允許→_sensitive）、app-orders 想讀它（拒絕→_sensitive）"
[ -f "$CONF_DIR/client-alice.properties" ] || (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=PLAIN\nsasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=%s/truststore.p12\nssl.truststore.password=%s\n' "$(cat "$SECRETS_DIR/ad-test-users.pass")" "$C" "$(cat "$PKI_DIR/store.pass")" > "$CONF_DIR/client-alice.properties")
[ -f "$CONF_DIR/app-orders.properties" ] || (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-orders" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=%s/truststore.p12\nssl.truststore.password=%s\n' "$(cat "$SECRETS_DIR/app-orders.pass")" "$C" "$(cat "$PKI_DIR/store.pass")" > "$CONF_DIR/app-orders.properties")
B1=$(fqdn "${BROKERS%% *}")
echo "audit-test-$(date +%s)" | kafka-console-producer --bootstrap-server "$B1:9096" --producer.config "$CONF_DIR/client-alice.properties" --topic "$SENS_TOPIC" >/dev/null 2>&1 && ok "alice: produced to $SENS_TOPIC" || fail "alice produce"
kafka-console-consumer --bootstrap-server "$B1:9095" --consumer.config "$CONF_DIR/app-orders.properties" --topic "$SENS_TOPIC" --group orders-sneak --max-messages 1 --timeout-ms 10000 2>&1 | grep -q 'TopicAuthorizationException' && ok "app-orders on $SENS_TOPIC: TopicAuthorizationException" || fail "app-orders 讀 $SENS_TOPIC 沒被拒"
sleep 10
r=$(kafka-console-consumer --bootstrap-server "$B1:9096" --consumer.config "$CONF_DIR/client-alice.properties" --topic confluent-audit-log-events_sensitive --from-beginning --timeout-ms 20000 2>/dev/null | python3 -c '
import sys, json
a=d=0
for line in sys.stdin:
    try: e=json.loads(line)["data"]
    except Exception: continue
    p=e.get("authenticationInfo",{}).get("principal"); g=e.get("authorizationInfo",{}).get("granted"); m=e.get("methodName","").split(".")[-1]
    if p=="User:alice" and m=="Produce" and g: a+=1
    if p=="User:app-orders" and not g: d+=1
print("alice_produce_allowed=%d app_orders_denied=%d"%(a,d))')
[[ $r == alice_produce_allowed=[1-9]* && $r == *app_orders_denied=[1-9]* ]] && ok "_sensitive：$r" || fail "_sensitive：$r"
log "預設只記管理／授權事件；一般 topic 的 produce／consume 只在路由列出的 topic（$AUDIT_SENSITIVE_PREFIX*）才記。改規則＝改 templates/audit.tpl 重跑這一站。"
finish
