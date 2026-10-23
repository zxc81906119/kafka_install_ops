# install/lib/render.sh —— 由範本產生設定檔、處理設定檔裡的密碼
#
# 範本（templates/*.tpl）裡寫 ${變數}，envsubst 換成目前環境的值。只換「呼叫時列出來的」變數；
# 其他 ${…}（${securepass:…}、${cyberark:…}、${env:…} 這些給 config provider 的參照）原樣保留。
# 輸出檔一律 0600（裡面可能有密碼）。
#
#   render_template  <範本> <輸出檔> <變數名…>                 一個範本 → 一個檔
#   render_templates <輸出檔> <變數名…> -- <範本…>             幾個範本接起來成一個檔（例如 broker.tpl + common.tpl）
#   encrypt_passwords <設定檔> <本機密文檔> <主機上密文檔路徑>   Secret Protection：明文密碼欄位 → ${securepass:…}
#   ldap_password_from_env <設定檔>                            AD 查詢密碼改由環境變數提供（手把手 16.9）
#   count_plaintext_passwords <設定檔>                         還剩幾個明文密碼欄位（驗收用，應為 0）
#   sp_encrypt_props <設定檔>                                  第 16 站的加密（含 16.9 AD 查詢密碼走 env）；要 CONFLUENT_SECURITY_MASTER_KEY
#   secrets_mode_in_use                                        目前的密碼放法：plain／sp／conjur（15、16 站留下的 conf/secrets.mode）
#   protect_rendered_props <設定檔>                            第 10／12／13 站重跑時用：依目前的放法處理剛產生的明文設定

# envsubst 要的變數清單格式："${A} ${B} …"
_envsubst_names() {
  local name list=""
  for name in "$@"; do list+="\${$name} "; done
  echo "$list"
}

# 輸出檔裡還有沒換掉的 ${大寫變數}，表示呼叫時漏列了變數
_check_no_leftover() {
  local out_file=$1 leftover
  leftover=$(grep -c '\${[A-Za-z0-9_]*}' "$out_file" || true)
  [ "$leftover" = 0 ] && return 0
  echo "render: $out_file 還有 $leftover 個沒換掉的 \${…}（呼叫時漏列變數？）" >&2
  return 1
}

render_template() {
  local template=$1 out_file=$2; shift 2
  (umask 077; envsubst "$(_envsubst_names "$@")" < "$template" > "$out_file")
  _check_no_leftover "$out_file"
}

render_templates() {
  local out_file=$1 template
  local names=(); shift
  while [ "$1" != "--" ]; do names+=("$1"); shift; done
  shift   # 跳過 --
  (
    umask 077
    : > "$out_file"
    for template in "$@"; do
      envsubst "$(_envsubst_names "${names[@]}")" < "$template" >> "$out_file"
      echo >> "$out_file"
    done
  )
  _check_no_leftover "$out_file"
}

# 什麼算「明文密碼欄位」：key 含 password／credentials／jaas.config，值不是 ${…} 參照。
# 等號兩邊允許空白：confluent secret 改寫過的檔是「key = value」。
PASSWORD_FIELD_REGEX='^[^#].*(password|credentials|jaas\.config) *= *[^$ ]'

# 需要 CONFLUENT_SECURITY_MASTER_KEY 在環境裡。已經是 ${…} 參照的欄位不會被碰。
encrypt_passwords() {
  local props_file=$1 local_secrets_file=$2 remote_secrets_path=$3
  local password_keys
  password_keys=$(grep -E "$PASSWORD_FIELD_REGEX" "$props_file" | sed 's/ *=.*//' | paste -sd,)
  [ -n "$password_keys" ] || return 0
  confluent secret file encrypt --config-file "$props_file" \
    --local-secrets-file "$local_secrets_file" --remote-secrets-file "$remote_secrets_path" \
    --config "$password_keys" >/dev/null
}

# 在 encrypt_passwords 之後呼叫：AD 查詢密碼那一欄換成 ${env:LDAP_BIND_PASSWORD}，
# config.providers 加上 Kafka 內建的 env provider（值由 Summon 在服務啟動時放進環境變數）。
ldap_password_from_env() {
  local props_file=$1
  sed -i -e 's|^ldap.java.naming.security.credentials *=.*|ldap.java.naming.security.credentials = ${env:LDAP_BIND_PASSWORD}|' \
         -e 's|^config.providers *=.*|config.providers = securepass,env|' \
         -e '/^config.providers.env.class *=/d' "$props_file"
  grep -q '^config.providers *=' "$props_file" || echo 'config.providers = securepass,env' >> "$props_file"
  echo 'config.providers.env.class = org.apache.kafka.common.config.provider.EnvVarConfigProvider' >> "$props_file"
}

# 明文密碼的判斷（驗收用）：
#   1. key 本身是 password／credentials 的欄位（例如 ssl.keystore.password），值不是 ${…} 參照
#   2. jaas.config 裡的 password="…"，值不是 ${…} 參照（像 ScramLoginModule required; 這種沒有密碼的 jaas 不算）
count_plaintext_passwords() {
  local props_file=$1
  {
    grep -E '^[^#=]*(password|credentials) *= *[^$ ]' "$props_file" | grep -v 'jaas.config'
    grep -E '^[^#=]*jaas.config *=' "$props_file" | grep -E 'password="[^$]'
  } | wc -l
}

# 第 16 站對一個剛產生的明文設定檔做的事：
#   16.9（LDAP_PASSWORD_VIA_ENV=1、而且這個檔有 AD 查詢密碼）：那一欄先換成 ${env:…}，加密時就不會被收進密文
#   其他密碼欄位 → ${securepass:…}，密文寫進 $SECRETS_DIR/security.properties（所有主機共用的那份）
sp_encrypt_props() {
  local props_file=$1 with_ldap_env=0
  if [ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && grep -q '^ldap.java.naming.security.credentials' "$props_file"; then
    with_ldap_env=1
    sed -i 's|^ldap.java.naming.security.credentials=.*|ldap.java.naming.security.credentials=${env:LDAP_BIND_PASSWORD}|' "$props_file"
  fi
  encrypt_passwords "$props_file" "$SECRETS_DIR/security.properties" /etc/confluent/secrets/security.properties || return 1
  [ "$with_ldap_env" = 1 ] && ldap_password_from_env "$props_file"
  return 0
}

secrets_mode_in_use() { cat "$CONF_DIR/secrets.mode" 2>/dev/null || echo plain; }

# 第 15／16 站做過以後，重跑第 10／12／13 站產生的設定是明文的；直接派送會把主機上的設定寫回明文。
#   plain   不用處理
#   sp      照第 16 站加密；呼叫的站要把 $SECRETS_DIR/security.properties 一起派送
#   conjur  不自動處理（參照要從改寫過的範本產生）：回 1，請改跑第 15 站
protect_rendered_props() {
  local props_file=$1 mode
  mode=$(secrets_mode_in_use)
  case $mode in
    plain) return 0;;
    sp) ;;
    *) echo "密碼放法是 $mode：這一站不自動改寫，請改跑第 15 站" >&2; return 1;;
  esac
  CONFLUENT_SECURITY_MASTER_KEY=$(cat "$SECRETS_DIR/master.key") sp_encrypt_props "$props_file" || return 1
  [ "$(count_plaintext_passwords "$props_file")" = 0 ]
}
