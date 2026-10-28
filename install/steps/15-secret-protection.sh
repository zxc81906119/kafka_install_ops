#!/usr/bin/env bash
# 第 15 站：Secret Protection —— 密碼加密留在主機的 security.properties，passphrase 與 master key 只留在操作機 ~/secrets（0600，root 才讀得到）
# where: ops02 （root）
#
# 何時用：SECRETS_MODE=sp（本案客戶）；SECRETS_MODE=plain 時直接略過。
# master key 落地在每台的 /etc/confluent/service.env（0600 root；開機不依賴任何外部系統）。
# 2026-10-28 定案：平台的密碼與金鑰不放 CyberArk（PVWA），都在操作機 root 才讀得到的位置（0600）：
#   master key   服務解密用；操作機這份（~/secrets/master.key）與各主機 service.env 各一份。只有 passphrase 算不回來（每次 generate 都換新的 salt）
#   passphrase   輪替 master key（20.3 rotate）時 CLI 要「目前的 master key＋舊 passphrase」兩樣都給；由工程師在操作機產生，存 ~/secrets/sp-passphrase.txt
# ~/secrets 與 ~/pki 的備份交給銀行自己的備份機制（操作機掉了，passphrase 就沒了；master key 還在各主機的 service.env）。
# 做什麼（一次把 15.1–15.5 做完，只滾動重啟一次）：
#   15.1 確認 passphrase 檔（還沒有 master key 又沒有 passphrase 檔時，由工程師在操作機產生：openssl rand，0600）
#   15.2 passphrase → 產生 master key（已有就沿用）
#   15.3 從明文範本重新產生每台的設定 → 加密密碼欄位
#   15.4 派送 properties、security.properties、service.env
#   15.5 滾動重啟、驗證
# 產出：~/secrets/sp-passphrase.txt、~/secrets/master.key、~/secrets/security.properties、~/conf/sp/<主機>.properties、~/conf/secrets.mode=sp
# 之後：換我們管的密碼（keystore 等）→ 重跑這一站；master key 輪替見手把手 20.3。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"
if [ "$SECRETS_MODE" != sp ]; then log "SECRETS_MODE=$SECRETS_MODE：第 15 站不適用，略過"; exit 0; fi
export JAVA_HOME=/opt/java/current

SP_CONF_DIR=$CONF_DIR/sp                                # 每台產出的（加密後的）設定
# 加密時的檔名就是 security.properties 裡密文的 key（${securepass:…:<檔名>/<欄位>}）：和手動 15.3 一致，依角色命名；20.4 換 AD 密碼時要用同一個名字更新
sp_name_of() { case $1 in rest*) echo "$1.kafka-rest.properties";; c3*) echo "$1.control-center.properties";; *) echo "$1.server.properties";; esac; }
MASTER_KEY_FILE=$SECRETS_DIR/master.key                 # master key（CLI 不保存；操作機這份 0600，各主機 service.env 另有一份）
PASSPHRASE_FILE=$SECRETS_DIR/sp-passphrase.txt          # 產生、輪替 master key 用的 passphrase（只在操作機，0600）
LOCAL_SECRETS_FILE=$SECRETS_DIR/security.properties     # 所有主機共用的密文檔（操作機這份是正本）
REMOTE_SECRETS_PATH=/etc/confluent/secrets/security.properties

section "15.1 passphrase（工程師在操作機產生，0600；已有 master key 就不需要）"
# 已經有 master key 就不需要 passphrase（日常重跑都是這種情況）
if [ -s "$MASTER_KEY_FILE" ]; then ok "已有 master key，這次不需要 passphrase"
else
  if [ ! -s "$PASSPHRASE_FILE" ]; then
    install -d -m 0700 "$SECRETS_DIR"
    (umask 077; openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > "$PASSPHRASE_FILE")
    ok "產生 passphrase：$PASSPHRASE_FILE（0600；值不顯示，請納入 ~/secrets 的備份）"
  fi
  if [ "$(wc -c < "$PASSPHRASE_FILE")" -ge 16 ] && [ "$(stat -c %a "$PASSPHRASE_FILE")" = 600 ]; then ok "$PASSPHRASE_FILE 在（0600）"
  else fail "$PASSPHRASE_FILE 至少 16 字元、權限要 0600"; fi
fi
[ "$FAIL_COUNT" = 0 ] || die "passphrase 檔不合格"

section "15.2 產生 master key（已有 master.key 就沿用：換掉會讓已派送的密文全部解不開）"
if [ -s "$MASTER_KEY_FILE" ]; then
  ok "沿用既有的 $MASTER_KEY_FILE 與 $LOCAL_SECRETS_FILE"
else
  [ "$(wc -c < "$PASSPHRASE_FILE")" -ge 16 ] || die "passphrase 太短或取值失敗"
  rm -f "$LOCAL_SECRETS_FILE"
  (umask 077; confluent secret master-key generate --local-secrets-file "$LOCAL_SECRETS_FILE" \
     --passphrase "$(cat "$PASSPHRASE_FILE")" -o yaml | awk '/master_key/{print $2}' > "$MASTER_KEY_FILE")
  if [ "$(wc -c < "$MASTER_KEY_FILE")" -ge 40 ]; then ok "master key 產生（$MASTER_KEY_FILE，0600）"; else die "master key 產生失敗"; fi
fi

section "15.3 從明文範本重新產生每台設定，加密密碼欄位（密文集中在 security.properties）"
install -d -m 0700 "$SP_CONF_DIR"
export STORE_PASSWORD LDAP_BIND_PASSWORD
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
LDAP_BIND_PASSWORD=$(cat "$SECRETS_DIR/ldap-bind.pass")
export CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP REST_APPS
export HOST_FQDN NODE_ID RACK REST_ID
TEMPLATE_VARS="HOST_FQDN NODE_ID RACK REST_ID STORE_PASSWORD LDAP_BIND_PASSWORD CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP REST_APPS"
# 第 18 站做過的話，稽核日誌的設定片段要一起帶上（否則重跑這一站會把稽核設定蓋掉）
audit_fragment=""
if [ -f "$CONF_DIR/audit.rendered.tpl" ]; then
  audit_fragment=$CONF_DIR/audit.rendered.tpl
  # 片段裡還留著稽核寫入帳號的密碼變數（第 18 站刻意留給這裡處理）：一起換掉、一起加密
  export AUDIT_PASSWORD; AUDIT_PASSWORD=$(cat "$SECRETS_DIR/confluent-audit.pass")
  TEMPLATE_VARS="$TEMPLATE_VARS AUDIT_PASSWORD"
fi
for host in $CLUSTER_HOSTS; do
  HOST_FQDN=$(fqdn "$host"); NODE_ID=$(node_id_of "$host"); RACK=$(rack_of "$host"); REST_ID=$host
  out_file=$SP_CONF_DIR/$(sp_name_of "$host")
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
  props_file=$SP_CONF_DIR/$(sp_name_of "$host")
  # 加密的規則在 lib/render.sh 的 sp_encrypt_props（第 10／12／13 站重跑時用同一個）
  sp_encrypt_props "$props_file" || { fail "$host: encrypt"; continue; }
  encrypted_count=$(grep -c '\${securepass:' "$props_file")
  plaintext_count=$(count_plaintext_passwords "$props_file")
  if [ "$plaintext_count" = 0 ]; then ok "$host: $encrypted_count 個欄位加密，明文 0"
  else fail "$host: 還有 $plaintext_count 個明文密碼欄位"; fi
done
unset CONFLUENT_SECURITY_MASTER_KEY
[ "$FAIL_COUNT" = 0 ] || die "加密失敗"
ok "security.properties：$(grep -c '^[^_].*ENC\[' "$LOCAL_SECRETS_FILE") 筆密文"

# ---- 15.4 派送：每台主機上要做的事 ----
# properties、security.properties 放到定位；master key 放 service.env（0600 root），systemd 以 EnvironmentFile 讀進服務環境
INSTALL_PROPERTIES=$(cat <<'EOF2'
set -e
sudo install -o root -g confluent -m 0640 /tmp/$SPNAME "$PROPS"
sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets
sudo install -o root -g confluent -m 0640 /tmp/security.properties "$REMOTE_SECRETS"
rm -f /tmp/$SPNAME /tmp/security.properties
EOF2
)
SETUP_SERVICE_ENV=$(cat <<'EOF2'
sudo install -o root -g root -m 0600 /tmp/service.env /etc/confluent/service.env && rm -f /tmp/service.env
printf '[Service]\nEnvironmentFile=/etc/confluent/service.env\n' | sudo tee /etc/systemd/system/$UNIT.service.d/20-secret-protection.conf >/dev/null
sudo systemctl daemon-reload
echo "refs=$(sudo grep -c 'securepass:' "$PROPS") env=$(systemctl show $UNIT -p EnvironmentFiles --value | cut -d' ' -f1)"
EOF2
)

section "15.4 派送：properties、security.properties，service.env + EnvironmentFile"
(umask 077; echo "CONFLUENT_SECURITY_MASTER_KEY=$(cat "$MASTER_KEY_FILE")" > "$SP_CONF_DIR/service.env")
for host in $CLUSTER_HOSTS; do
  copy_to_tmp "$host" "$SP_CONF_DIR/$(sp_name_of "$host")" "$LOCAL_SECRETS_FILE" "$SP_CONF_DIR/service.env" || { fail "$host: scp"; continue; }
  result=$(ssh_script "$host" HOST="$host" SPNAME="$(sp_name_of "$host")" UNIT="$(unit_of "$host")" PROPS="$(props_path_of "$host")" REMOTE_SECRETS="$REMOTE_SECRETS_PATH" \
             <<<"$INSTALL_PROPERTIES
$SETUP_SERVICE_ENV")
  case $result in *"env=/etc/confluent/service.env") ok "$host: $result";; *) fail "$host: $result";; esac
done
rm -f "$SP_CONF_DIR/service.env"
[ "$FAIL_COUNT" = 0 ] || die "派送失敗，不重啟"

section "15.5 滾動重啟、驗證"
rolling_restart controllers brokers rests c3 || die "滾動重啟有主機沒健康"
alice_login=$(curl -s --cacert "$BANK_ROOT_CA" -u "alice:$(cat "$SECRETS_DIR/ad-test-users.pass")" -o /dev/null -w '%{http_code}' "$MDS_URL/security/1.0/authenticate")
if [ "$alice_login" = 200 ]; then ok "alice 登入 MDS：200"; else fail "alice 登入 MDS：$alice_login"; fi

# 最後確認一台 broker：設定檔沒有明文密碼（規則在 lib/render.sh）、master key 落地的檔數（service.env 1 個）
check_host=${BROKERS%% *}
plaintext_count=$(count_plaintext_passwords <(ssh_run "$check_host" "sudo cat /etc/confluent/kafka/server.properties"))
master_key_files=$(ssh_run "$check_host" "sudo grep -rl CONFLUENT_SECURITY_MASTER_KEY= /etc/confluent /etc/systemd/system 2>/dev/null | wc -l")
if [ "$plaintext_count" = 0 ] && [ "$master_key_files" = 1 ]; then
  ok "$check_host：明文密碼 0、磁碟上有 master key 的檔 $master_key_files 個"
else
  fail "$check_host：明文密碼 $plaintext_count、磁碟上有 master key 的檔 $master_key_files 個（預期 0、1）"
fi
echo sp > "$CONF_DIR/secrets.mode"
finish_step
