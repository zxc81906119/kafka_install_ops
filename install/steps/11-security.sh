#!/usr/bin/env bash
# 第 11 站：帳號與權限 —— 管理 client、app 的 SCRAM、RBAC（人員綁 AD 群組）、配額、範例 topic
# where: ops02 （root）
#
# 做什麼：
#   - bootstrap：唯一的 super user 是 kafka-internal（服務之間用）；用它的憑證登入 MDS 建第一條 role binding：User:svc-ops → SystemAdmin
#   - 操作機的管理 client：svc-ops 憑證向 MDS 換 token，走 TOKEN listener（svc-ops 不是 super user，權限來自 RBAC）
#   - conf/apps.txt 裡 scram 類的 app：每個建 <app>-a、<app>-b 兩個同權限的 SCRAM 帳號（A／B 輪替），密碼在 ~/secrets/<帳號>.pass
#   - conf/rbac.txt：role binding（人員綁 AD 群組，服務與 app 綁最小權限）
#   - conf/apps.txt 的配額、conf/topics.txt 的範例 topic
#   - 驗證：alice、carol 用 AD 帳密登入 MDS，看到的角色來自她們的 AD 群組
# 需要什麼：第 10 站的 broker 與 MDS、~/conf/kraft.env、~/secrets/ad-test-users.pass（測試人員的 AD 密碼）
# 產出什麼：~/conf/client-admin.properties、~/secrets/<帳號>.pass（0600）
# 能不能重跑：安全。SCRAM 密碼檔已存在就沿用（重設成同一個值）；role binding 重建是 no-op；topic 用 --if-not-exists。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
export JAVA_HOME=/opt/java/current

# login_with_cert <憑證名稱>：用憑證登入 MDS（confluent CLI 的 RBAC 指令要用）
#   kafka-internal 只在 bootstrap 用一次，之後都是 svc-ops
login_with_cert() {
  local cert_name=$1

  confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
    --client-cert-path "$CERTS_DIR/$cert_name.crt" --client-key-path "$KEYS_DIR/$cert_name.key" >/dev/null 2>&1
}

# roles_of_person <AD 帳號>：用本人的 AD 帳密登入 MDS，印他有哪些角色；登入失敗就什麼都不印
#   例：alice → "role": "SystemAdmin"
roles_of_person() {
  local person=$1 bindings_json

  if ! CONFLUENT_PLATFORM_USERNAME=$person CONFLUENT_PLATFORM_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass") \
       confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" >/dev/null 2>&1; then
    return 1
  fi

  bindings_json=$(confluent iam rbac role-binding list --principal "User:$person" --kafka-cluster "$CLUSTER_ID" \
    -o json 2>/dev/null)
  grep -o '"role": *"[^"]*"' <<<"$bindings_json" | sort -u | tr '\n' ' '
}

section "bootstrap：kafka-internal（唯一的 super user）登入 MDS，建第一條 role binding：User:svc-ops → SystemAdmin"
source "$CONF_DIR/kraft.env"   # CLUSTER_ID

if ! login_with_cert kafka-internal; then
  die "confluent login（kafka-internal 憑證）失敗"
fi

if mds_write confluent iam rbac role-binding create --principal User:svc-ops --role SystemAdmin \
     --kafka-cluster "$CLUSTER_ID" >/dev/null 2>&1 </dev/null; then
  ok "User:svc-ops SystemAdmin（由 kafka-internal 建立）"
else
  die "建不了 svc-ops 的第一條 role binding"
fi

if ! login_with_cert svc-ops; then
  die "confluent login（svc-ops 憑證）失敗"
fi

section "操作機的管理 client（svc-ops 憑證 → MDS token → TOKEN listener；svc-ops 的權限來自上面那條 binding）"
store_password=$(cat "$PKI_DIR/store.pass")
install -m 0600 /dev/null "$ADMIN_CLIENT_CONF"

cat > "$ADMIN_CLIENT_CONF" <<EOF
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
unset store_password

topic_list=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --list 2>/dev/null)

if grep -qx '_confluent-metadata-auth' <<<"$topic_list"; then
  topic_count=$(wc -l <<<"$topic_list")
  ok "憑證 → MDS token → TOKEN listener 這條路通了（$topic_count 個 topic）"
else
  die "kafka-topics --list 失敗：$topic_list"
fi

section "應用程式的 SCRAM 帳號：每個應用兩個同權限的帳號 <app>-a、<app>-b（A／B 輪替用；密碼 ~/secrets/<帳號>.pass，0600；已有的沿用）"

# 1. 帳號清單：app-orders → app-orders-a app-orders-b
scram_accounts=""
for app in $SCRAM_APPS; do
  for suffix in $SCRAM_SUFFIXES; do
    scram_accounts+="$app$suffix "
  done
done

# 2. 每個帳號：沒有密碼檔就產生，在 Kafka 設 SCRAM 憑據（kafka-configs 出錯時會印出整段設定含密碼，所以輸出不留）
for app in $scram_accounts; do
  password_file=$SECRETS_DIR/$app.pass

  if [ ! -s "$password_file" ]; then
    install -m 0600 /dev/null "$password_file"
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$password_file"
  fi

  scram_config="SCRAM-SHA-512=[iterations=8192,password=$(cat "$password_file")]"

  if kafka-configs --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --alter \
       --entity-type users --entity-name "$app" --add-config "$scram_config" >/dev/null 2>&1; then
    ok "$app: scram"
  else
    fail "$app: scram"
  fi

  unset scram_config
done

# 3. 確認：這些帳號，加上第 10 站建的 kafka-admin，都有 SCRAM 憑據
for user in $scram_accounts kafka-admin; do
  scram_info=$(kafka-configs --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --describe \
                 --entity-type users --entity-name "$user" 2>/dev/null | grep -o 'SCRAM-SHA-512=[^,]*' | head -1)

  if [ -n "$scram_info" ]; then
    ok "$user: $scram_info"
  else
    fail "$user: 沒有 SCRAM 憑證"
  fi
done

section "RBAC：conf/rbac.txt 的每一行建一個 role binding"
# 每一行：principal、角色、資源（- = 整個 cluster）、比對方式（PREFIXED = 名稱開頭相同）
while read -r principal role resource pattern; do
  if [ -z "$principal" ]; then
    continue
  fi

  binding_args=(--principal "$principal" --role "$role" --kafka-cluster "$CLUSTER_ID")

  if [ "$resource" != - ]; then
    binding_args+=(--resource "$resource")
  fi

  if [ "$pattern" = PREFIXED ]; then
    binding_args+=(--prefix)
  fi

  if mds_write confluent iam rbac role-binding create "${binding_args[@]}" >/dev/null 2>&1 </dev/null; then
    ok "$principal $role ${resource#-} ${pattern#-}"
  else
    fail "$principal $role ${resource#-} ${pattern#-}"
  fi
done <<<"$(grep -v '^#' "$INSTALL_DIR/conf/rbac.txt")"

section "配額（conf/apps.txt 第三欄：produce,consume bytes/s,request %；scram 類的 -a、-b 兩個帳號各設一份）"
while read -r app auth_type quota; do
  if [ -z "$app" ]; then
    continue
  fi

  # 1. 第三欄拆開：5242880,10485760,50 → 三個值
  producer_rate=$(cut -d, -f1 <<<"$quota")
  consumer_rate=$(cut -d, -f2 <<<"$quota")
  request_percent=$(cut -d, -f3 <<<"$quota")

  # 2. 要設哪些帳號：scram 類是 -a、-b 兩個，其他就是 app 本身
  accounts=$app
  if [ "$auth_type" = scram ]; then
    accounts=""

    for suffix in $SCRAM_SUFFIXES; do
      accounts+="$app$suffix "
    done
  fi

  # 3. 設配額
  for account in $accounts; do
    quota_config="producer_byte_rate=$producer_rate,consumer_byte_rate=$consumer_rate"
    quota_config+=",request_percentage=$request_percent"

    if kafka-configs --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" \
         --alter --entity-type users --entity-name "$account" \
         --add-config "$quota_config" >/dev/null 2>&1 </dev/null; then
      ok "$account quota $quota"
    else
      fail "$account quota"
    fi
  done
done <<<"$(grep -v '^#' "$INSTALL_DIR/conf/apps.txt")"

section "範例 topic（conf/topics.txt；replication 3、min.insync.replicas 2）"
while read -r topic partitions; do
  if [ -z "$topic" ]; then
    continue
  fi

  if kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --create --if-not-exists \
       --topic "$topic" --partitions "$partitions" --replication-factor 3 \
       --config min.insync.replicas=2 >/dev/null 2>&1 </dev/null; then
    ok "topic $topic（$partitions partitions）"
  else
    fail "topic $topic"
  fi
done <<<"$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt")"

section "驗證權限真的靠 AD 群組：alice（kafka-admins）應是 SystemAdmin、carol（kafka-devs）應是 DeveloperRead"
for person in alice carol; do
  case $person in
    alice)
      expected_role=SystemAdmin
      ;;
    carol)
      expected_role=DeveloperRead
      ;;
  esac

  roles=$(roles_of_person "$person")

  case $roles in
    *"$expected_role"*)
      ok "$person: $roles"
      ;;
    *)
      fail "$person: ${roles:-登入或查詢失敗}"
      ;;
  esac
done

# 把 CLI 的登入切回 svc-ops，後面的站接著用
login_with_cert svc-ops

finish_step
