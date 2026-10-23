#!/usr/bin/env bash
# 第 15 站：把密碼搬進 CyberArk Conjur —— properties 只留 ${cyberark:…} 參照，服務啟動時向 Conjur 取值
# where: ops02 （cpadmin）
#
# 何時用：SECRETS_MODE=conjur（銀行有 Conjur）。和第 16 站二選一，不適用時直接略過。
# 做什麼：
#   15.1 確認銀行建好 Conjur、policy、每台主機的身分（host key）、我方寫值的身分（ops key）、jar 已送到
#   15.2 把目前在用的密碼寫進 Conjur，並以一台 broker 的身分讀回來確認
#   15.3 jar 派送到 /usr/share/java/cp-secrets/；銀行根憑證匯進 JDK 的 cacerts（provider 連 Conjur 走 JVM 預設信任庫）
#   15.4 範本裡的 ${STORE_PASSWORD}／${LDAP_BIND_PASSWORD} 改成 ${cyberark:…}，加上 provider 設定，產生並派送
#   15.5 drop-in 讓服務載入 jar（C3 用 CONTROL_CENTER_CLASSPATH），拿掉第 16 站的 drop-in，滾動重啟
#   15.6 驗證：沒有明文、provider 真的去了 Conjur、人員登入正常
# 產出：~/conf/conjur/（改過的範本與每台的設定）、~/conf/secrets.mode=conjur（第 19 站看這個）
# secret zero：每台 properties 裡的 cyberark.auth.apikey（0640）。換 AD 密碼＝改 AD、改 Conjur、滾動重啟（手把手 15.7）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"
source "$INSTALL_DIR/lib/vault.sh"
if [ "$SECRETS_MODE" != conjur ]; then log "SECRETS_MODE=$SECRETS_MODE：第 15 站不適用，略過"; exit 0; fi
export JAVA_HOME=/opt/java/current
CONJUR_CONF_DIR=$CONF_DIR/conjur      # 改成 ${cyberark:…} 的範本與每台產出的設定放這裡（原範本不動）

ask_bank "15.1 Secrets 團隊：建 Conjur（$VAULT_URL，憑證由銀行 CA 簽）、載入 policy「$VAULT_POLICY」：" \
         "    每台主機一個 host 身分（host/$VAULT_POLICY/<主機>）、一個寫值用的 user ops；" \
         "    變數 store-password、ldap-bind-password、audit-password、scram/<app>（主機只能讀，ops 能寫）；" \
         "    每台主機自己的 host API key 放到 $VAULT_HOST_KEY（0640 root:confluent），ops 的 API key 放到 $VAULT_OPS_KEY（0600）。" \
         "    provider jar（下載機 steps/15-conjur-provider-jar.sh 建的 4 個）隨落地區送到 $LANDING/tools/csid/。"

section "15.1 確認銀行的準備"
vault_http=$(curl -s --cacert "$VAULT_CA" -o /dev/null -m 10 -w '%{http_code}' "$VAULT_URL/")
if [ "$vault_http" = 200 ]; then ok "Conjur $VAULT_URL：200（憑證鏈由銀行根憑證驗過）"; else fail "Conjur $VAULT_URL：$vault_http"; fi
for host in $ALL_HOSTS; do
  if ssh_run "$host" "sudo test -s $VAULT_HOST_KEY"; then ok "$host：host key 在"; else fail "$host：沒有 $VAULT_HOST_KEY"; fi
done
if [ -s "$VAULT_OPS_KEY" ]; then ok "$VAULT_OPS_KEY 在"; else fail "沒有 $VAULT_OPS_KEY"; fi
jar_count=$(ls "$LANDING"/tools/csid/*.jar 2>/dev/null | wc -l)
if [ "$jar_count" = 4 ]; then ok "provider jar 4 個"; else fail "$LANDING/tools/csid 有 $jar_count 個 jar（預期 4；先在下載機跑 steps/15-conjur-provider-jar.sh）"; fi
[ "$FAIL_COUNT" = 0 ] || wait_for_bank

section "15.2 把目前在用的密碼寫進 Conjur（值從 0600 檔讀，不出現在畫面上）"
vault_login_as_ops || die "ops 身分登入 Conjur 失敗"
if tr -d '\n' < "$PKI_DIR/store.pass" | vault_set store-password; then ok "set $VAULT_POLICY/store-password"; else fail "store-password"; fi
if tr -d '\n' < "$SECRETS_DIR/ldap-bind.pass" | vault_set ldap-bind-password; then ok "set $VAULT_POLICY/ldap-bind-password"; else fail "ldap-bind-password"; fi
for app in $SCRAM_APPS; do
  if tr -d '\n' < "$SECRETS_DIR/$app.pass" | vault_set "scram/$app"; then ok "set $VAULT_POLICY/scram/$app"; else fail "scram/$app"; fi
done
vault_logout
check_host=${BROKERS%% *}
if vault_login_as_host "$check_host" && [ "$(vault_get store-password)" = "$(tr -d '\n' < "$PKI_DIR/store.pass")" ]; then ok "$check_host 以自己的身分讀 store-password：相符"
else fail "$check_host 以自己的身分讀值失敗或不符"; fi
vault_logout
[ "$FAIL_COUNT" = 0 ] || die "寫值失敗"

section "15.3 派送 jar、讓 JDK 信任銀行根憑證"
for host in $ALL_HOSTS; do
  copy_to_tmp "$host" "$LANDING"/tools/csid/*.jar || { fail "$host: scp"; continue; }
  result=$(ssh_script "$host" ROOT_CA="$BANK_ROOT_CA" <<'EOF'
sudo install -d -m 0755 /usr/share/java/cp-secrets
sudo install -m 0644 /tmp/*.jar /usr/share/java/cp-secrets/ && rm -f /tmp/*.jar
sudo /opt/java/current/bin/keytool -importcert -noprompt -cacerts -storepass changeit -alias bank-root -file "$ROOT_CA" >/dev/null 2>&1
in_cacerts=$(/opt/java/current/bin/keytool -list -cacerts -storepass changeit -alias bank-root >/dev/null 2>&1 && echo ok || echo missing)
echo "$(ls /usr/share/java/cp-secrets | wc -l) jars, cacerts=$in_cacerts"
EOF
)
  if [ "$result" = "4 jars, cacerts=ok" ]; then ok "$host: $result"; else fail "$host: $result"; fi
done
[ "$FAIL_COUNT" = 0 ] || die "jar 派送失敗"

section "15.4 範本改成參照：\${cyberark:<變數>:<變數>}（provider 回傳的 key 就是變數路徑，所以寫兩次）"
install -d -m 0700 "$CONJUR_CONF_DIR"
for template_name in common controller broker kafka-rest control-center; do
  sed -e "s|\${STORE_PASSWORD}|\${cyberark:$VAULT_POLICY/store-password:$VAULT_POLICY/store-password}|g" \
      -e "s|\${LDAP_BIND_PASSWORD}|\${cyberark:$VAULT_POLICY/ldap-bind-password:$VAULT_POLICY/ldap-bind-password}|g" \
      "$TEMPLATE_DIR/$template_name.tpl" > "$CONJUR_CONF_DIR/$template_name.tpl"
  # provider 本身的設定只要放在「每份設定檔都會有的」範本：common（controller、broker）、kafka-rest、control-center
  case $template_name in common|kafka-rest|control-center) cat "$TEMPLATE_DIR/conjur.tpl" >> "$CONJUR_CONF_DIR/$template_name.tpl";; esac
done
# broker 範本裡 listener 專用的 keystore 密碼也要換到，漏了 broker 起來會報 keystore password was incorrect
templates_with_plain_vars=$(grep -l 'STORE_PASSWORD\|LDAP_BIND_PASSWORD' "$CONJUR_CONF_DIR"/*.tpl | wc -l)
if [ "$templates_with_plain_vars" = 0 ]; then ok "還留著明文密碼變數的範本：0"; else die "還有 $templates_with_plain_vars 個範本留著 \${STORE_PASSWORD}"; fi

export CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP REST_APPS
export VAULT_URL VAULT_ACCOUNT VAULT_POLICY HOST_FQDN NODE_ID RACK REST_ID HOST_SHORT CONJUR_API_KEY
TEMPLATE_VARS="HOST_FQDN NODE_ID RACK REST_ID HOST_SHORT CONJUR_API_KEY CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP REST_APPS VAULT_URL VAULT_ACCOUNT VAULT_POLICY"
for host in $CLUSTER_HOSTS; do
  HOST_FQDN=$(fqdn "$host"); NODE_ID=$(node_id_of "$host"); RACK=$(rack_of "$host"); REST_ID=$host; HOST_SHORT=$host
  CONJUR_API_KEY=$(ssh_run "$host" "sudo cat $VAULT_HOST_KEY")   # 每台用自己的身分向 Conjur 認證
  out_file=$CONJUR_CONF_DIR/$host.properties
  # shellcheck disable=SC2086
  case $host in
    kc*)   render_templates "$out_file" $TEMPLATE_VARS -- "$CONJUR_CONF_DIR/controller.tpl" "$CONJUR_CONF_DIR/common.tpl";;
    kb*)   render_templates "$out_file" $TEMPLATE_VARS -- "$CONJUR_CONF_DIR/broker.tpl" "$CONJUR_CONF_DIR/common.tpl";;
    rest*) render_template "$CONJUR_CONF_DIR/kafka-rest.tpl" "$out_file" $TEMPLATE_VARS;;
    c3*)   render_template "$CONJUR_CONF_DIR/control-center.tpl" "$out_file" $TEMPLATE_VARS;;
  esac || { fail "$host: render"; continue; }
  copy_to_tmp "$host" "$out_file" || { fail "$host: scp"; continue; }
  result=$(ssh_script "$host" UPLOADED="/tmp/$host.properties" PROPS="$(props_path_of "$host")" <<'EOF'
sudo install -o root -g confluent -m 0640 "$UPLOADED" "$PROPS" && rm -f "$UPLOADED"
references=$(sudo grep -c '${cyberark:' "$PROPS")
unresolved=$(sudo grep '${' "$PROPS" | grep -vc '${cyberark:')
plaintext=$(sudo grep -cE '^[a-z.]*password=[^$]' "$PROPS")
echo "refs=$references unresolved=$unresolved plaintext=$plaintext"
EOF
)
  case $result in *"unresolved=0 plaintext=0") ok "$host: $result";; *) fail "$host: $result";; esac
done
unset CONJUR_API_KEY
[ "$FAIL_COUNT" = 0 ] || die "設定派送失敗"

section "15.5 服務載入 jar（Kafka／REST 看 CLASSPATH，C3 只看 CONTROL_CENTER_CLASSPATH），滾動重啟"
for host in $CLUSTER_HOSTS; do
  case $host in c3*) classpath_var=CONTROL_CENTER_CLASSPATH;; *) classpath_var=CLASSPATH;; esac
  result=$(ssh_script "$host" UNIT="$(unit_of "$host")" CLASSPATH_VAR="$classpath_var" <<'EOF'
dropin_dir=/etc/systemd/system/$UNIT.service.d
printf '[Service]\nEnvironment="%s=/usr/share/java/cp-secrets/*"\n' "$CLASSPATH_VAR" | sudo tee $dropin_dir/20-conjur.conf >/dev/null
# 從第 16 站切過來時，拿掉 Secret Protection 的 drop-in 與 master key
sudo rm -f $dropin_dir/20-secret-protection.conf $dropin_dir/30-summon.conf /etc/confluent/service.env
sudo systemctl daemon-reload
systemctl show $UNIT -p Environment --value | tr ' ' '\n' | grep -o '[A-Z_]*CLASSPATH=[^ ]*'
EOF
)
  case $result in *"CLASSPATH=/usr/share/java/cp-secrets/*"*) ok "$host: $result";; *) fail "$host: $result";; esac
done
[ "$FAIL_COUNT" = 0 ] || die "drop-in 失敗"
rolling_restart controllers brokers rests c3 || die "滾動重啟有主機沒健康"

section "15.6 驗證：主機上沒有明文、provider 真的有去 Conjur、人員登入正常"
for host in ${BROKERS%% *} ${RESTS%% *} $C3_HOST; do
  result=$(ssh_script "$host" PROPS="$(props_path_of "$host")" UNIT="$(unit_of "$host")" <<'EOF'
plaintext=$(sudo grep -cE '^[a-z.]*password=[^$]' "$PROPS")
provider_log_lines=$(sudo journalctl -u "$UNIT" --since '-10min' --no-pager | grep -ci cyberark)
echo "plaintext=$plaintext provider_log=$provider_log_lines"
EOF
)
  case $result in plaintext=0*provider_log=0) fail "$host: $result（沒看到 provider 的日誌）";; plaintext=0*) ok "$host: $result";; *) fail "$host: $result";; esac
done
alice_login=$(curl -s --cacert "$VAULT_CA" -u "alice:$(cat "$SECRETS_DIR/ad-test-users.pass")" -o /dev/null -w '%{http_code}' "$MDS_URL/security/1.0/authenticate")
if [ "$alice_login" = 200 ]; then ok "alice 登入 MDS：200"; else fail "alice 登入 MDS：$alice_login"; fi
echo conjur > "$CONF_DIR/secrets.mode"
finish_step
