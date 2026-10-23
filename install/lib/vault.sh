# install/lib/vault.sh —— 保管庫存取（Conjur 版；lab 用 Conjur OSS 扮演銀行的 CyberArk）
#
# 客戶只有 PAM／CCP 時換掉這一個檔，函式名稱與用法不變。需要 site.env 的 VAULT_*。
#
#   vault_login_as_ops            以我方寫值用的身分（ops）登入：可讀可寫
#   vault_login_as_host [主機]    以某台主機自己的身分登入：只能讀；不給主機就是本機
#   vault_get    <變數>           印出值。變數名相對於 VAULT_POLICY，例如 store-password、scram/app-orders
#   vault_set    <變數>           從 stdin 讀值原樣寫入。密碼先 tr -d '\n' 去掉換行；私鑰、PEM 是多行，不要去
#   vault_exists <變數>           讀得到 → rc 0
#   vault_logout                  丟掉 token
#
# 登入後 token 放在 VAULT_TOKEN，只存在這支步驟的 shell 裡。

VAULT_CA=${VAULT_CA:-/etc/pki/ca-trust/source/anchors/bank-root.pem}   # 驗保管庫憑證用的銀行根憑證
VAULT_TOKEN=${VAULT_TOKEN:-}

# 變數路徑放進網址前要把 / 和 @ 編碼
_url_encode() {
  printf '%s' "$1" | sed 's|/|%2F|g; s|@|%40|g'
}

# _vault_authenticate <登入名> <API key>：用 API key 換 token。
# 不能寫成「… | _vault_authenticate」：管線的右邊在子 shell 跑，export 的 token 會不見。
_vault_authenticate() {
  local login=$1 api_key=$2 token
  token=$(printf '%s' "$api_key" \
    | curl -sS --cacert "$VAULT_CA" -X POST --data-binary @- "$VAULT_URL/authn/$VAULT_ACCOUNT/$(_url_encode "$login")/authenticate" \
    | base64 -w0)
  if [ "${#token}" -le 20 ]; then
    echo "vault: 登入失敗（$login）" >&2
    return 1
  fi
  export VAULT_TOKEN=$token
}

vault_login_as_ops() {
  [ -s "$VAULT_OPS_KEY" ] || { echo "vault: 沒有 $VAULT_OPS_KEY" >&2; return 1; }
  _vault_authenticate "ops@$VAULT_POLICY" "$(cat "$VAULT_OPS_KEY")"
}

vault_login_as_host() {
  local host=${1:-$(hostname -s)} api_key
  if [ "$host" = "$(hostname -s)" ]; then
    api_key=$(sudo cat "$VAULT_HOST_KEY")
  else
    api_key=$(ssh -o BatchMode=yes -o LogLevel=ERROR "$(fqdn "$host")" "sudo cat $VAULT_HOST_KEY")
  fi
  [ -n "$api_key" ] || { echo "vault: 讀不到 $host 的 $VAULT_HOST_KEY" >&2; return 1; }
  _vault_authenticate "host/$VAULT_POLICY/$host" "$api_key"
}

_vault_variable_url() {
  echo "$VAULT_URL/secrets/$VAULT_ACCOUNT/variable/$(_url_encode "$VAULT_POLICY/$1")"
}

vault_get() {
  curl -sS -f --cacert "$VAULT_CA" -H "Authorization: Token token=\"$VAULT_TOKEN\"" "$(_vault_variable_url "$1")"
}

vault_set() {
  curl -sS -f --cacert "$VAULT_CA" -H "Authorization: Token token=\"$VAULT_TOKEN\"" -X POST --data-binary @- "$(_vault_variable_url "$1")"
}

vault_exists() { vault_get "$1" >/dev/null 2>&1; }
vault_logout() { unset VAULT_TOKEN; }
