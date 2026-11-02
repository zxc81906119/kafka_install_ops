#!/usr/bin/env bash
# install/lab/mds-token-key-dual-test.sh —— lab 專用：MDS token 金鑰輪替實驗，第二版（公鑰檔放兩把有沒有用）
# where: ops02 （root；bank-sim.sh push 之後 install/ 在 ~/install）
#
# 做什麼：token 先用 curl 向「指定的 MDS」取、存成檔，client 直接拿這個檔連 broker
#   （第一版用 Confluent 的 TokenUserLoginCallbackHandler，它會自己挑 MDS，token 來源不受控）；只動 kb04，最後還原。
#   結論記在 redesign/README.md「MDS token 金鑰輪替」。
# 需要什麼：~/mds-key-test/ 有新金鑰（new.key、new.pub）與舊＋新兩把的公鑰檔（both.pub）。
# 產出什麼：每種組合「接受／拒絕」印在畫面上。
# 能不能重跑：可以（結束時 kb04 還原成正式金鑰）。
set -uo pipefail
source ~/install/conf/site.env
source ~/install/lib/ssh.sh
export JAVA_HOME=/opt/java/current
WORK=$HOME/mds-key-test
TEST_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass")
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")

# fetch_token <MDS 主機> <輸出檔>：向那台 MDS 取 token 存成檔；拿不到回 1
#   MDS 回應的例子：{"auth_token":"eyJ...","token_type":"Bearer",...} → eyJ...
fetch_token() {
  local mds_host=$1 output_file=$2

  curl -s --cacert "$BANK_ROOT_CA" -u "alice:$TEST_PASSWORD" "https://$mds_host.$DOMAIN:8090/security/1.0/authenticate" \
    | sed -n 's/.*"auth_token":"\([^"]*\)".*/\1/p' > "$output_file"

  [ -s "$output_file" ]
}

# refusal_reason：err.txt 裡第一個看得出原因的片段
refusal_reason() {
  grep -o 'SaslAuthenticationException.\{0,80\}\|Authentication failed.\{0,40\}\|ConfigException.\{0,120\}' "$WORK/err.txt" | head -1
}

# try_listener <MDS 主機> <broker 主機>：用 MDS 主機簽的 token，連 broker 主機的 TOKEN listener（DescribeConfigs 指定那台）
try_listener() {
  local issuer=$1 broker=$2 token_file=$WORK/token-$1.jwt conf=$WORK/file-token.properties

  # 1. 取 token
  if ! fetch_token "$issuer" "$token_file"; then
    echo "$issuer：拿不到 token"
    return
  fi

  # 2. client 設定：token 來自檔案（0600，裡面有 truststore 密碼）
  install -m 0600 /dev/null "$conf"
  cat > "$conf" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=file:$token_file
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$STORE_PASSWORD
EOF

  # 3. 連線、判斷
  if KAFKA_OPTS="-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml -Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=file:$token_file" \
     timeout 60 kafka-configs --bootstrap-server "$broker.$DOMAIN:9094" --command-config "$conf" \
       --describe --entity-type brokers --entity-name "$(node_id_of "$broker")" > /dev/null 2> "$WORK/err.txt"; then
    echo "  $issuer 簽的 token → $broker 的 TOKEN listener：接受"
  else
    echo "  $issuer 簽的 token → $broker 的 TOKEN listener：拒絕（$(refusal_reason)）"
  fi
}

# set_kb04_keys <私鑰> <公鑰檔> <說明>：kb04 換上這組金鑰、重啟 broker、等 MDS 回來
set_kb04_keys() {
  local key_file=$1 public_file=$2 label=$3

  # 1. 放上去
  copy_to_tmp kb04 "$key_file" "$public_file"
  ssh_script kb04 KEYPAIR="/tmp/$(basename "$key_file")" PUBLIC="/tmp/$(basename "$public_file")" <<'EOF'
sudo install -o root -g confluent -m 0640 "$KEYPAIR" /etc/confluent/ssl/mds-token-keypair.pem
sudo install -o root -g confluent -m 0640 "$PUBLIC" /etc/confluent/ssl/mds-token-public.pem
rm -f "$KEYPAIR" "$PUBLIC"
EOF

  # 2. 重啟
  echo "-- kb04：$label"
  restart_and_wait kb04 confluent-server "https://kb04.$DOMAIN:8090/v1/metadata/id" | sed 's/^/   /'
  sleep 10
}

echo "== 基準（四台都是舊金鑰）"
try_listener kb01 kb04
try_listener kb04 kb01

echo "== 對照：kb04 只有新公鑰＋新私鑰"
set_kb04_keys "$WORK/new.key" "$WORK/new.pub" "公鑰=新、私鑰=新"
try_listener kb04 kb04     # 應接受：新簽新驗
try_listener kb01 kb04     # 應拒絕：舊簽新驗
try_listener kb04 kb01     # 應拒絕：新簽舊驗（混合期會發生的事）

echo "== 重點：kb04 公鑰檔放兩把（舊在前、新在後），私鑰=新"
set_kb04_keys "$WORK/new.key" "$WORK/both.pub" "公鑰=舊+新、私鑰=新"
try_listener kb04 kb04     # 新簽：第二把公鑰有沒有被用到？
try_listener kb01 kb04     # 舊簽：第一把

echo "== 再換順序：公鑰檔新在前、舊在後"
cat "$WORK/new.pub" "$CERTS_DIR/mds-token-public.pem" > "$WORK/both-newfirst.pub"
set_kb04_keys "$WORK/new.key" "$WORK/both-newfirst.pub" "公鑰=新+舊、私鑰=新"
try_listener kb04 kb04
try_listener kb01 kb04

echo "== 還原 kb04"
set_kb04_keys "$KEYS_DIR/mds-token.key" "$CERTS_DIR/mds-token-public.pem" "還原"
try_listener kb04 kb04
try_listener kb01 kb04
rm -f "$WORK"/token-*.jwt "$WORK/file-token.properties" "$WORK/err.txt"
