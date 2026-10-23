#!/usr/bin/env bash
# 第 16 站：Secret Protection —— 密碼加密留在主機的 security.properties，master key 交 CyberArk 保管
# where: ops02 （cpadmin）
#
# 何時用：SECRETS_MODE=sp（銀行只有 PAM、沒有 Conjur）。和第 15 站二選一，不適用時直接略過。
# 三種組合（conf/site.env）：
#   SUMMON=0                           master key 落地在每台的 /etc/confluent/service.env（16.4；保管庫故障時仍能重啟）
#   SUMMON=1                           master key 不落地，啟動時 Summon 向保管庫取（16.8；保管庫要在線）
#   SUMMON=1 + LDAP_PASSWORD_VIA_ENV=1 AD 查詢密碼也不進密文，Summon 注入、${env:…} 讀（16.9；CPM 換密碼後只要滾動重啟）
# 做什麼（一次把 16.2–16.9 做完，只滾動重啟一次）：
#   16.1 確認保管庫裡有 passphrase（以及 Summon 需要的 master-key 變數、每台的身分、執行檔）
#   16.2 取 passphrase → 產生 master key（已有就沿用）
#   16.3 從明文範本重新產生每台的設定 → 加密密碼欄位（16.9：AD 查詢密碼那欄改成 ${env:…}）
#   16.8 master key 寫進保管庫（Summon 模式）
#   16.4 派送 properties、security.properties，以及 service.env 或 Summon 的設定
#   16.5 滾動重啟、驗證
# 產出：~/secrets/master.key、~/secrets/security.properties、~/conf/sp/<主機>.properties、~/conf/secrets.mode=sp
# 之後：換我們管的密碼（keystore 等）→ 重跑這一站；master key 輪替見手把手 16.6。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"
source "$INSTALL_DIR/lib/vault.sh"
if [ "$SECRETS_MODE" != sp ]; then log "SECRETS_MODE=$SECRETS_MODE：第 16 站不適用，略過"; exit 0; fi
if [ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && [ "$SUMMON" != 1 ]; then die "LDAP_PASSWORD_VIA_ENV=1 需要 SUMMON=1（注入靠 Summon）"; fi
export JAVA_HOME=/opt/java/current

SP_CONF_DIR=$CONF_DIR/sp                                # 每台產出的（加密後的）設定
MASTER_KEY_FILE=$SECRETS_DIR/master.key                 # master key（由 passphrase 推導，CLI 不保存）
LOCAL_SECRETS_FILE=$SECRETS_DIR/security.properties     # 所有主機共用的密文檔（操作機這份是正本）
REMOTE_SECRETS_PATH=/etc/confluent/secrets/security.properties
SUMMON_DIR=$LANDING/tools/summon                        # Summon 與 summon-conjur 兩個執行檔（下載機帶進來）

ask_bank "16.1 Secrets 團隊：保管庫（lab 用 Conjur 扮演 PAM Vault）放 $VAULT_POLICY/secret-protection/passphrase（銀行產生；只給 ops 與操作機讀）；" \
         "    操作機要有自己的身分 $VAULT_HOST_KEY。" \
         "$([ "$SUMMON" = 1 ] && echo "16.8 另加變數 $VAULT_POLICY/secret-protection/master-key（ops 可寫、所有主機可讀）；每台主機都要有身分；Summon 執行檔在 $SUMMON_DIR/。")" \
         "$([ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && echo "16.9 變數 $VAULT_POLICY/ldap-bind-password 要存在且主機可讀（CPM 換 AD 查詢密碼時同步更新它）。")"

section "16.1 確認保管庫的準備"
vault_http=$(curl -s --cacert "$VAULT_CA" -o /dev/null -m 10 -w '%{http_code}' "$VAULT_URL/")
if [ "$vault_http" = 200 ]; then ok "保管庫 $VAULT_URL：200"; else fail "保管庫 $VAULT_URL：$vault_http"; fi
if sudo test -s "$VAULT_HOST_KEY"; then ok "$OPS_HOST 的身分在"; else fail "$OPS_HOST 沒有 $VAULT_HOST_KEY"; fi
if vault_login_as_host "$OPS_HOST" 2>/dev/null; then
  if vault_exists secret-protection/passphrase; then ok "passphrase 讀得到"; else fail "secret-protection/passphrase 不存在或沒有讀取權"; fi
  vault_logout
else
  fail "操作機的身分登入保管庫失敗"
fi
if [ "$SUMMON" = 1 ]; then
  for host in $CLUSTER_HOSTS; do
    if ssh_run "$host" "sudo test -s $VAULT_HOST_KEY"; then ok "$host 的身分在"; else fail "$host 沒有 $VAULT_HOST_KEY"; fi
  done
  if [ -f "$SUMMON_DIR/SHA256SUMS" ] && (cd "$SUMMON_DIR" && sha256sum -c --quiet SHA256SUMS); then ok "Summon 執行檔 sha256 相符"
  else fail "$SUMMON_DIR 缺檔或 sha256 不符"; fi
  if [ -s "$VAULT_OPS_KEY" ]; then ok "$VAULT_OPS_KEY 在（寫 master key 用）"; else fail "沒有 $VAULT_OPS_KEY"; fi
fi
[ "$FAIL_COUNT" = 0 ] || wait_for_bank

section "16.2 取 passphrase、產生 master key（已有 master.key 就沿用：換掉會讓已派送的密文全部解不開）"
if [ -s "$MASTER_KEY_FILE" ]; then
  ok "沿用既有的 $MASTER_KEY_FILE 與 $LOCAL_SECRETS_FILE"
else
  vault_login_as_host "$OPS_HOST" || die "登入保管庫失敗"
  (umask 077; vault_get secret-protection/passphrase > "$SECRETS_DIR/sp-passphrase.txt")
  vault_logout
  [ "$(wc -c < "$SECRETS_DIR/sp-passphrase.txt")" -ge 16 ] || die "passphrase 太短或取值失敗"
  rm -f "$LOCAL_SECRETS_FILE"
  (umask 077; confluent secret master-key generate --local-secrets-file "$LOCAL_SECRETS_FILE" \
     --passphrase @"$SECRETS_DIR/sp-passphrase.txt" -o yaml | awk '/master_key/{print $2}' > "$MASTER_KEY_FILE")
  if [ "$(wc -c < "$MASTER_KEY_FILE")" -ge 40 ]; then ok "master key 產生（$MASTER_KEY_FILE，0600）"; else die "master key 產生失敗"; fi
fi

section "16.3 從明文範本重新產生每台設定，加密密碼欄位（密文集中在 security.properties）"
install -d -m 0700 "$SP_CONF_DIR"
export STORE_PASSWORD LDAP_BIND_PASSWORD
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
LDAP_BIND_PASSWORD=$(cat "$SECRETS_DIR/ldap-bind.pass")
export CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP REST_APPS
export HOST_FQDN NODE_ID RACK REST_ID
TEMPLATE_VARS="HOST_FQDN NODE_ID RACK REST_ID STORE_PASSWORD LDAP_BIND_PASSWORD CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP REST_APPS"
# 第 19 站做過的話，稽核日誌的設定片段要一起帶上（否則重跑這一站會把稽核設定蓋掉）
audit_fragment=""
if [ -f "$CONF_DIR/audit.rendered.tpl" ]; then
  audit_fragment=$CONF_DIR/audit.rendered.tpl
  # 片段裡還留著稽核寫入帳號的密碼變數（第 19 站刻意留給這裡處理）：一起換掉、一起加密
  export AUDIT_PASSWORD; AUDIT_PASSWORD=$(cat "$SECRETS_DIR/confluent-audit.pass")
  TEMPLATE_VARS="$TEMPLATE_VARS AUDIT_PASSWORD"
fi
for host in $CLUSTER_HOSTS; do
  HOST_FQDN=$(fqdn "$host"); NODE_ID=$(node_id_of "$host"); RACK=$(rack_of "$host"); REST_ID=$host
  out_file=$SP_CONF_DIR/$host.properties
  # shellcheck disable=SC2086
  case $host in
    kc*)   render_templates "$out_file" $TEMPLATE_VARS -- "$TEMPLATE_DIR/controller.tpl" "$TEMPLATE_DIR/common.tpl" $audit_fragment;;
    kb*)   render_templates "$out_file" $TEMPLATE_VARS -- "$TEMPLATE_DIR/broker.tpl" "$TEMPLATE_DIR/common.tpl" $audit_fragment;;
    rest*) render_template "$TEMPLATE_DIR/kafka-rest.tpl" "$out_file" $TEMPLATE_VARS;;
    c3*)   render_template "$TEMPLATE_DIR/control-center.tpl" "$out_file" $TEMPLATE_VARS;;
  esac || fail "$host: render"
done
unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD
[ "$FAIL_COUNT" = 0 ] || die "產生設定失敗"

export CONFLUENT_SECURITY_MASTER_KEY
CONFLUENT_SECURITY_MASTER_KEY=$(cat "$MASTER_KEY_FILE")
for host in $CLUSTER_HOSTS; do
  props_file=$SP_CONF_DIR/$host.properties
  # 16.9 的 AD 查詢密碼走 env 也在 sp_encrypt_props 裡（lib/render.sh；第 10／12／13 站重跑時用同一個）
  sp_encrypt_props "$props_file" || { fail "$host: encrypt"; continue; }
  ldap_note=""
  grep -q 'credentials *= *${env:LDAP_BIND_PASSWORD}' "$props_file" && ldap_note="，AD 查詢密碼走 env"
  encrypted_count=$(grep -c '\${securepass:' "$props_file")
  plaintext_count=$(count_plaintext_passwords "$props_file")
  if [ "$plaintext_count" = 0 ]; then ok "$host: $encrypted_count 個欄位加密，明文 0$ldap_note"
  else fail "$host: 還有 $plaintext_count 個明文密碼欄位"; fi
done
unset CONFLUENT_SECURITY_MASTER_KEY
[ "$FAIL_COUNT" = 0 ] || die "加密失敗"
ok "security.properties：$(grep -c '^[^_].*ENC\[' "$LOCAL_SECRETS_FILE") 筆密文"

if [ "$SUMMON" = 1 ]; then
  section "16.8 master key 寫進保管庫（去掉檔尾換行，否則 Summon 取回的值多一個換行，服務解不開密文）"
  vault_login_as_ops || die "ops 身分登入失敗"
  if tr -d '\n' < "$MASTER_KEY_FILE" | vault_set secret-protection/master-key; then ok "set $VAULT_POLICY/secret-protection/master-key"
  else die "寫 master key 失敗"; fi
  if [ "$LDAP_PASSWORD_VIA_ENV" = 1 ]; then
    # 16.9：Summon 啟動時要取這個值；只要 secrets.yml 裡有一個變數取不到，Summon 就整個失敗（連 master key 也拿不到）
    # 正式環境這個值由 CPM 換密碼時一併更新；這裡寫入目前在用的那組
    if tr -d '\n' < "$SECRETS_DIR/ldap-bind.pass" | vault_set ldap-bind-password; then ok "set $VAULT_POLICY/ldap-bind-password（AD 查詢密碼，Summon 注入用）"
    else die "寫 ldap-bind-password 失敗（policy 裡要有這個變數）"; fi
  fi
  vault_logout
fi

# ---- 16.4 派送：每台主機上要做的事 ----
# 共同：properties、security.properties 放到定位；拿掉第 15 站的 drop-in（從 conjur 切過來時）
INSTALL_PROPERTIES=$(cat <<'EOF'
set -e
sudo install -o root -g confluent -m 0640 /tmp/$HOST.properties "$PROPS"
sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets
sudo install -o root -g confluent -m 0640 /tmp/security.properties "$REMOTE_SECRETS"
rm -f /tmp/$HOST.properties /tmp/security.properties
sudo rm -f /etc/systemd/system/$UNIT.service.d/20-conjur.conf
EOF
)
# SUMMON=0：master key 放 service.env（0600 root），systemd 以 EnvironmentFile 讀進服務環境
SETUP_SERVICE_ENV=$(cat <<'EOF'
sudo install -o root -g root -m 0600 /tmp/service.env /etc/confluent/service.env && rm -f /tmp/service.env
sudo rm -f /etc/systemd/system/$UNIT.service.d/30-summon.conf
printf '[Service]\nEnvironmentFile=/etc/confluent/service.env\n' | sudo tee /etc/systemd/system/$UNIT.service.d/20-secret-protection.conf >/dev/null
sudo systemctl daemon-reload
echo "refs=$(sudo grep -c 'securepass:' "$PROPS") env=$(systemctl show $UNIT -p EnvironmentFiles --value | cut -d' ' -f1)"
EOF
)
# SUMMON=1：裝 Summon，ExecStart 改成「Summon 先向保管庫取值放進環境變數，再執行原本的啟動腳本」
#   /etc/conjur.conf      保管庫位置；/etc/conjur.identity  這台的身分（netrc 格式，0640 root:confluent，服務帳號讀得到）
#   /etc/confluent/secrets.yml  哪個環境變數對應保管庫的哪個變數
SETUP_SUMMON=$(cat <<'EOF'
sudo install -d -m 0755 /usr/local/lib/summon
sudo tar -xzf /tmp/summon-linux-amd64.tar.gz -C /usr/local/bin summon
sudo tar -xzf /tmp/summon-conjur-linux-amd64.tar.gz -C /usr/local/lib/summon summon-conjur
rm -f /tmp/summon*.tar.gz
sudo chmod 0755 /usr/local/bin/summon /usr/local/lib/summon/summon-conjur
printf 'appliance_url: %s\naccount: %s\ncert_file: %s\nnetrc_path: /etc/conjur.identity\n' "$VAULT_URL" "$VAULT_ACCOUNT" "$VAULT_CA" | sudo tee /etc/conjur.conf >/dev/null
printf 'machine %s/authn\n  login host/%s/%s\n  password %s\n' "$VAULT_URL" "$VAULT_POLICY" "$HOST" "$(sudo cat "$VAULT_HOST_KEY")" \
  | sudo install -m 0640 -o root -g confluent /dev/stdin /etc/conjur.identity
{
  echo "CONFLUENT_SECURITY_MASTER_KEY: !var $VAULT_POLICY/secret-protection/master-key"
  if [ "$WITH_LDAP_ENV" = 1 ]; then echo "LDAP_BIND_PASSWORD: !var $VAULT_POLICY/ldap-bind-password"; fi
} | sudo tee /etc/confluent/secrets.yml >/dev/null
printf '[Service]\nExecStart=\nExecStart=/usr/local/bin/summon -p /usr/local/lib/summon/summon-conjur -f /etc/confluent/secrets.yml %s\n' "$START_COMMAND" \
  | sudo tee /etc/systemd/system/$UNIT.service.d/30-summon.conf >/dev/null
sudo rm -f /etc/systemd/system/$UNIT.service.d/20-secret-protection.conf /etc/confluent/service.env
sudo systemctl daemon-reload
# 以服務帳號試跑 Summon：取回的 master key 要和操作機上的一樣（比對雜湊，不印值）
fetched_hash=$(sudo -u "$SERVICE_USER" /usr/local/bin/summon -p /usr/local/lib/summon/summon-conjur -f /etc/confluent/secrets.yml \
  printenv CONFLUENT_SECURITY_MASTER_KEY | tr -d '\n' | sha256sum | cut -c1-12)
key_check=$([ "$fetched_hash" = "$EXPECTED_KEY_HASH" ] && echo key-matches || echo MISMATCH)
exec_path=$(systemctl show $UNIT -p ExecStart --value | grep -o 'path=[^ ]*' | head -1 | cut -d= -f2)
echo "$key_check exec=$exec_path refs=$(sudo grep -c 'securepass:' "$PROPS")"
EOF
)

section "16.4 派送：properties、security.properties，$([ "$SUMMON" = 1 ] && echo 'Summon（執行檔、保管庫位置、身分、secrets.yml、ExecStart）' || echo 'service.env + EnvironmentFile')"
expected_key_hash=$(tr -d '\n' < "$MASTER_KEY_FILE" | sha256sum | cut -c1-12)
[ "$SUMMON" = 1 ] || (umask 077; echo "CONFLUENT_SECURITY_MASTER_KEY=$(cat "$MASTER_KEY_FILE")" > "$SP_CONF_DIR/service.env")
for host in $CLUSTER_HOSTS; do
  case $host in kc*|kb*) with_ldap_env=$LDAP_PASSWORD_VIA_ENV;; *) with_ldap_env=0;; esac   # 只有 controller／broker 有 LDAP 設定
  if [ "$SUMMON" = 1 ]; then
    copy_to_tmp "$host" "$SP_CONF_DIR/$host.properties" "$LOCAL_SECRETS_FILE" "$SUMMON_DIR/summon-linux-amd64.tar.gz" "$SUMMON_DIR/summon-conjur-linux-amd64.tar.gz" \
      || { fail "$host: scp"; continue; }
    result=$(ssh_script "$host" HOST="$host" UNIT="$(unit_of "$host")" PROPS="$(props_path_of "$host")" REMOTE_SECRETS="$REMOTE_SECRETS_PATH" \
               SERVICE_USER="$(service_user_of "$host")" START_COMMAND="$(start_command_of "$host")" WITH_LDAP_ENV="$with_ldap_env" \
               VAULT_URL="$VAULT_URL" VAULT_ACCOUNT="$VAULT_ACCOUNT" VAULT_POLICY="$VAULT_POLICY" VAULT_CA="$VAULT_CA" VAULT_HOST_KEY="$VAULT_HOST_KEY" \
               EXPECTED_KEY_HASH="$expected_key_hash" <<<"$INSTALL_PROPERTIES
$SETUP_SUMMON")
    case $result in "key-matches exec=/usr/local/bin/summon"*) ok "$host: $result";; *) fail "$host: $result";; esac
  else
    copy_to_tmp "$host" "$SP_CONF_DIR/$host.properties" "$LOCAL_SECRETS_FILE" "$SP_CONF_DIR/service.env" || { fail "$host: scp"; continue; }
    result=$(ssh_script "$host" HOST="$host" UNIT="$(unit_of "$host")" PROPS="$(props_path_of "$host")" REMOTE_SECRETS="$REMOTE_SECRETS_PATH" \
               <<<"$INSTALL_PROPERTIES
$SETUP_SERVICE_ENV")
    case $result in *"env=/etc/confluent/service.env") ok "$host: $result";; *) fail "$host: $result";; esac
  fi
done
rm -f "$SP_CONF_DIR/service.env"
[ "$FAIL_COUNT" = 0 ] || die "派送失敗，不重啟"

section "16.5 滾動重啟、驗證"
rolling_restart controllers brokers rests c3 || die "滾動重啟有主機沒健康"
alice_login=$(curl -s --cacert "$VAULT_CA" -u "alice:$(cat "$SECRETS_DIR/ad-test-users.pass")" -o /dev/null -w '%{http_code}' "$MDS_URL/security/1.0/authenticate")
if [ "$alice_login" = 200 ]; then ok "alice 登入 MDS：200"; else fail "alice 登入 MDS：$alice_login"; fi

if [ "$LDAP_PASSWORD_VIA_ENV" = 1 ]; then
  # alice 登入只用她自己的帳密、群組快取也撐得住，證明不了查詢帳號 bind 成功。
  # 重啟後快取是空的：alice 經 LDAP listener 建 topic 時，MDS 一定要用查詢帳號到 AD 找她的群組才會放行。
  export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
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
  test_topic=ldap-check-$(date +%s)
  create_result=$(kafka-topics --bootstrap-server "$FIRST_BROKER:9096" --command-config "$ALICE_CLIENT_CONF" --create --topic "$test_topic" \
                    --partitions 1 --replication-factor 3 2>&1 | grep -o 'Created topic\|TopicAuthorizationException' | head -1)
  kafka-topics --bootstrap-server "$FIRST_BROKER:9096" --command-config "$ALICE_CLIENT_CONF" --delete --topic "$test_topic" >/dev/null 2>&1
  if [ "$create_result" = "Created topic" ]; then ok "重啟後 alice 經 LDAP listener 建 topic 成功：查詢帳號用注入的密碼 bind 成功"
  else fail "alice 建 topic：${create_result:-失敗}（查詢帳號 bind 可能失敗）"; fi
fi

# 最後確認一台 broker：設定檔沒有明文密碼（規則在 lib/render.sh）、master key 落地的檔數（Summon 0，service.env 1）
check_host=${BROKERS%% *}
plaintext_count=$(count_plaintext_passwords <(ssh_run "$check_host" "sudo cat /etc/confluent/kafka/server.properties"))
master_key_files=$(ssh_run "$check_host" "sudo grep -rl CONFLUENT_SECURITY_MASTER_KEY= /etc/confluent /etc/systemd/system 2>/dev/null | wc -l")
if [ "$SUMMON" = 1 ]; then expected_master_key_files=0; else expected_master_key_files=1; fi
if [ "$plaintext_count" = 0 ] && [ "$master_key_files" = "$expected_master_key_files" ]; then
  ok "$check_host：明文密碼 0、磁碟上有 master key 的檔 $master_key_files 個"
else
  fail "$check_host：明文密碼 $plaintext_count、磁碟上有 master key 的檔 $master_key_files 個（預期 0、$expected_master_key_files）"
fi
echo sp > "$CONF_DIR/secrets.mode"
finish_step
