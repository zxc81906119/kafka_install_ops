#!/usr/bin/env bash
# 第 11 站：帳號與權限 —— 管理 client、app 的 SCRAM、RBAC（人員綁 AD 群組）、配額、範例 topic
# where: ops02 （cpadmin）
#
# 做什麼：
#   - 操作機的管理 client：svc-ops 憑證向 MDS 換 token，走 TOKEN listener（svc-ops 是 super user）
#   - conf/apps.txt 裡 scram 類的 app：建 SCRAM 帳號，密碼在 ~/secrets/<app>.pass
#   - conf/rbac.txt：role binding（人員綁 AD 群組，服務與 app 綁最小權限）
#   - conf/apps.txt 的配額、conf/topics.txt 的範例 topic
#   - 驗證：alice、carol 用 AD 帳密登入 MDS，看到的角色來自她們的 AD 群組
# 重跑：安全。SCRAM 密碼檔已存在就沿用（重設成同一個值）；role binding 重建是 no-op；topic 用 --if-not-exists。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
export JAVA_HOME=/opt/java/current

# 用 svc-ops 憑證登入 MDS（confluent CLI 的 RBAC 指令要用）
login_as_svc_ops() {
  confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
    --client-cert-path "$CERTS_DIR/svc-ops.crt" --client-key-path "$KEYS_DIR/svc-ops.key" >/dev/null 2>&1
}

section "操作機的管理 client（svc-ops 憑證 → MDS token → TOKEN listener）"
store_password=$(cat "$PKI_DIR/store.pass")
(umask 077; cat > "$ADMIN_CLIENT_CONF" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenCertificateLoginCallbackHandler
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required metadataServerUrls="$MDS_URLS";
ssl.keystore.type=PKCS12
ssl.keystore.location=$CERTS_DIR/svc-ops.p12
ssl.keystore.password=$store_password
ssl.key.password=$store_password
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$store_password
ssl.endpoint.identification.algorithm=https
EOF
)
unset store_password
topic_list=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --list 2>/dev/null)
if grep -qx '_confluent-metadata-auth' <<<"$topic_list"; then ok "憑證 → MDS token → TOKEN listener 這條路通了（$(wc -l <<<"$topic_list") 個 topic）"
else die "kafka-topics --list 失敗：$topic_list"; fi

section "應用程式的 SCRAM 帳號（密碼 ~/secrets/<app>.pass，0600；已有的沿用）"
for app in $SCRAM_APPS; do
  password_file=$SECRETS_DIR/$app.pass
  [ -s "$password_file" ] || (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$password_file")
  scram_config="SCRAM-SHA-512=[iterations=8192,password=$(cat "$password_file")]"
  if kafka-configs --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --alter \
       --entity-type users --entity-name "$app" --add-config "$scram_config" >/dev/null 2>&1; then ok "$app: scram"
  else fail "$app: scram"; fi
  unset scram_config
done
for user in $SCRAM_APPS kafka-admin; do
  scram_info=$(kafka-configs --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --describe \
                 --entity-type users --entity-name "$user" 2>/dev/null | grep -o 'SCRAM-SHA-512=[^,]*' | head -1)
  if [ -n "$scram_info" ]; then ok "$user: $scram_info"; else fail "$user: 沒有 SCRAM 憑證"; fi
done

section "RBAC：conf/rbac.txt 的每一行建一個 role binding"
login_as_svc_ops || die "confluent login（svc-ops 憑證）失敗"
source "$CONF_DIR/kraft.env"   # CLUSTER_ID
while read -r principal role resource pattern; do
  [ -n "$principal" ] || continue
  binding_args=(--principal "$principal" --role "$role" --kafka-cluster "$CLUSTER_ID")
  [ "$resource" != - ] && binding_args+=(--resource "$resource")
  [ "$pattern" = PREFIXED ] && binding_args+=(--prefix)
  if confluent iam rbac role-binding create "${binding_args[@]}" >/dev/null 2>&1 </dev/null; then ok "$principal $role ${resource#-} ${pattern#-}"
  else fail "$principal $role ${resource#-} ${pattern#-}"; fi
done < <(grep -v '^#' "$INSTALL_DIR/conf/rbac.txt")

section "配額（conf/apps.txt 第三欄：produce,consume bytes/s,request %）"
while read -r app auth_type quota; do
  [ -n "$app" ] || continue
  IFS=, read -r producer_rate consumer_rate request_percent <<<"$quota"
  if kafka-configs --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --alter --entity-type users --entity-name "$app" \
       --add-config "producer_byte_rate=$producer_rate,consumer_byte_rate=$consumer_rate,request_percentage=$request_percent" >/dev/null 2>&1 </dev/null
  then ok "$app quota $quota"; else fail "$app quota"; fi
done < <(grep -v '^#' "$INSTALL_DIR/conf/apps.txt")

section "範例 topic（conf/topics.txt；replication 3、min.insync.replicas 2）"
while read -r topic partitions; do
  [ -n "$topic" ] || continue
  if kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --create --if-not-exists \
       --topic "$topic" --partitions "$partitions" --replication-factor 3 --config min.insync.replicas=2 >/dev/null 2>&1 </dev/null
  then ok "topic $topic（$partitions partitions）"; else fail "topic $topic"; fi
done < <(grep -v '^#' "$INSTALL_DIR/conf/topics.txt")

section "驗證權限真的靠 AD 群組：alice（kafka-admins）應是 SystemAdmin、carol（kafka-devs）應是 DeveloperRead"
for person in alice carol; do
  case $person in alice) expected_role=SystemAdmin;; carol) expected_role=DeveloperRead;; esac
  roles=$(CONFLUENT_PLATFORM_USERNAME=$person CONFLUENT_PLATFORM_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass") \
          confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" >/dev/null 2>&1 \
          && confluent iam rbac role-binding list --principal "User:$person" --kafka-cluster "$CLUSTER_ID" -o json 2>/dev/null \
             | grep -o '"role": *"[^"]*"' | sort -u | tr '\n' ' ')
  case $roles in *"$expected_role"*) ok "$person: $roles";; *) fail "$person: ${roles:-登入或查詢失敗}";; esac
done
login_as_svc_ops   # 把 CLI 的登入切回 svc-ops，後面的站接著用
finish_step
