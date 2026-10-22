#!/usr/bin/env bash
# 第 11 站：帳號與權限 —— 操作機管理 client（svc-ops 憑證 → MDS token）、app 的 SCRAM、RBAC（人員綁 AD 群組）、配額、範例 topic
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"
export JAVA_HOME=/opt/java/current
C=$PKI_DIR/certs; BS=$BROKER_TOKEN; ADMIN=$CONF_DIR/client-admin.properties
MDS1=https://$(fqdn "${BROKERS%% *}"):8090

section "操作機的管理 client（走 TOKEN listener；svc-ops 是 super user）"
P=$(cat "$PKI_DIR/store.pass")
(umask 077; cat > "$ADMIN" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenCertificateLoginCallbackHandler
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required metadataServerUrls="$MDS_URLS";
ssl.keystore.type=PKCS12
ssl.keystore.location=$C/svc-ops.p12
ssl.keystore.password=$P
ssl.key.password=$P
ssl.truststore.type=PKCS12
ssl.truststore.location=$C/truststore.p12
ssl.truststore.password=$P
ssl.endpoint.identification.algorithm=https
EOF
); unset P
t=$(kafka-topics --bootstrap-server "$BS" --command-config "$ADMIN" --list 2>/dev/null)
grep -q '^_confluent-metadata-auth$' <<<"$t" && ok "憑證 → MDS token → TOKEN listener 這條路通了（$(wc -l <<<"$t") 個 topic）" || die "kafka-topics --list 失敗：$t"

section "應用程式的 SCRAM 帳號（密碼在 $SECRETS_DIR/<app>.pass，0600；已有的沿用）"
while read -r a auth quota; do
  [ "$auth" = scram ] || continue
  [ -s "$SECRETS_DIR/$a.pass" ] || (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS_DIR/$a.pass")
  P=$(cat "$SECRETS_DIR/$a.pass")
  kafka-configs --bootstrap-server "$BS" --command-config "$ADMIN" --alter --entity-type users --entity-name "$a" --add-config "SCRAM-SHA-512=[iterations=8192,password=$P]" >/dev/null 2>&1 </dev/null && ok "$a: scram" || fail "$a: scram"
  unset P
done < <(grep -v '^#' "$D/conf/apps.txt")
for a in $(grep -v '^#' "$D/conf/apps.txt" | awk '$2=="scram"{print $1}') kafka-admin; do
  r=$(kafka-configs --bootstrap-server "$BS" --command-config "$ADMIN" --describe --entity-type users --entity-name "$a" 2>/dev/null | grep -o 'SCRAM-SHA-512=[^,]*' | head -1)
  [ -n "$r" ] && ok "$a: $r" || fail "$a: 沒有 SCRAM 憑證"
done

section "RBAC：人員綁 AD 群組，服務與 app 各綁最小權限（conf/rbac.txt）"
confluent login --url "$MDS1" --certificate-authority-path "$C/bank-root.pem" --certificate-only --client-cert-path "$C/svc-ops.crt" --client-key-path "$PKI_DIR/keys/svc-ops.key" >/dev/null 2>&1 || die "confluent login（svc-ops 憑證）失敗"
source "$CONF_DIR/kraft.env"
while read -r p role res pat; do
  [ -n "$p" ] || continue
  args=(--principal "$p" --role "$role" --kafka-cluster "$CLUSTER_ID"); [ "$res" != "-" ] && args+=(--resource "$res"); [ "$pat" = PREFIXED ] && args+=(--prefix)
  confluent iam rbac role-binding create "${args[@]}" >/dev/null 2>&1 </dev/null && ok "$p $role ${res#-} ${pat#-}" || fail "$p $role ${res#-} ${pat#-}"
done < <(grep -v '^#' "$D/conf/rbac.txt")

section "配額與範例 topic"
while read -r a auth quota; do
  [ -n "$a" ] || continue; IFS=, read -r pr cr rp <<<"$quota"
  kafka-configs --bootstrap-server "$BS" --command-config "$ADMIN" --alter --entity-type users --entity-name "$a" --add-config "producer_byte_rate=$pr,consumer_byte_rate=$cr,request_percentage=$rp" >/dev/null 2>&1 </dev/null && ok "$a quota $quota" || fail "$a quota"
done < <(grep -v '^#' "$D/conf/apps.txt")
while read -r t parts; do
  [ -n "$t" ] || continue
  kafka-topics --bootstrap-server "$BS" --command-config "$ADMIN" --create --if-not-exists --topic "$t" --partitions "$parts" --replication-factor 3 --config min.insync.replicas=2 >/dev/null 2>&1 </dev/null && ok "topic $t ($parts partitions)" || fail "topic $t"
done < <(grep -v '^#' "$D/conf/topics.txt")

section "驗證權限真的靠 AD 群組：alice（kafka-admins）、carol（kafka-devs）用 AD 帳密登入 MDS 看自己的角色"
for u in alice carol; do
  r=$(CONFLUENT_PLATFORM_USERNAME=$u CONFLUENT_PLATFORM_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass") confluent login --url "$MDS1" --certificate-authority-path "$C/bank-root.pem" >/dev/null 2>&1 && confluent iam rbac role-binding list --principal "User:$u" --kafka-cluster "$CLUSTER_ID" -o json 2>/dev/null | grep -o '"role": *"[^"]*"' | sort -u | tr '\n' ' ')
  case $u in alice) want=SystemAdmin;; carol) want=DeveloperRead;; esac
  [[ $r == *"$want"* ]] && ok "$u: $r" || fail "$u: ${r:-登入或查詢失敗}"
done
confluent login --url "$MDS1" --certificate-authority-path "$C/bank-root.pem" --certificate-only --client-cert-path "$C/svc-ops.crt" --client-key-path "$PKI_DIR/keys/svc-ops.key" >/dev/null 2>&1
finish
