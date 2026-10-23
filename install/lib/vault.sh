# install/lib/vault.sh — 保管庫存取（Conjur 版；lab 用 Conjur OSS 扮演 CyberArk）
# 客戶只有 PAM／CCP 時換掉這一個檔，函式名稱與參數不變：
#   vault_login_ops            以小安的寫值身分取 token（VAULT_OPS_KEY）
#   vault_login_host [主機]    以主機的 host 身分取 token（本機或 ssh 到該主機讀 VAULT_HOST_KEY）
#   vault_get <變數>           印出值（不含換行）；變數相對於 VAULT_POLICY，例如 store-password、scram/app-orders
#   vault_set <變數>           從 stdin 讀值原樣寫入（密碼類要先 tr -d 換行；私鑰／PEM 多行就不要去）
#   vault_has <變數>           變數存在且讀得到 → rc 0
# token 放在 VAULT_TOKEN（只在這個 shell 的環境裡），用完 vault_logout。
VAULT_CA=${VAULT_CA:-/etc/pki/ca-trust/source/anchors/bank-root.pem}

_venc() { printf '%s' "$1" | sed 's|/|%2F|g; s|@|%40|g'; }
VAULT_TOKEN=${VAULT_TOKEN:-}
_vauth() { # <login> <API key 內容>   （不用 pipeline，否則 export 會留在子 shell）
  local login=$1 key=$2 t
  t=$(printf '%s' "$key" | curl -sS --cacert "$VAULT_CA" -X POST --data-binary @- "$VAULT_URL/authn/$VAULT_ACCOUNT/$(_venc "$login")/authenticate" | base64 -w0)
  [ -n "$t" ] && [ "${#t}" -gt 20 ] || { echo "vault: 認證失敗（$login）" >&2; return 1; }
  export VAULT_TOKEN=$t
}
vault_login_ops()  { vault_login_ops_as "ops@$VAULT_POLICY"; }
vault_login_ops_as() { [ -s "$VAULT_OPS_KEY" ] || { echo "vault: 沒有 $VAULT_OPS_KEY" >&2; return 1; }; _vauth "$1" "$(cat "$VAULT_OPS_KEY")"; }
vault_login_host() {
  local h=${1:-$(hostname -s)} k
  if [ "$h" = "$(hostname -s)" ]; then k=$(sudo cat "$VAULT_HOST_KEY"); else k=$(ssh -o BatchMode=yes -o LogLevel=ERROR "$(fqdn "$h")" "sudo cat $VAULT_HOST_KEY"); fi
  [ -n "$k" ] || { echo "vault: 讀不到 $h 的 host key" >&2; return 1; }
  _vauth "host/$VAULT_POLICY/$h" "$k"
}
vault_get() { curl -sS -f --cacert "$VAULT_CA" -H "Authorization: Token token=\"$VAULT_TOKEN\"" "$VAULT_URL/secrets/$VAULT_ACCOUNT/variable/$(_venc "$VAULT_POLICY/$1")"; }
vault_set() { curl -sS -f --cacert "$VAULT_CA" -H "Authorization: Token token=\"$VAULT_TOKEN\"" -X POST --data-binary @- "$VAULT_URL/secrets/$VAULT_ACCOUNT/variable/$(_venc "$VAULT_POLICY/$1")"; }
vault_has() { vault_get "$1" >/dev/null 2>&1; }
vault_logout() { unset VAULT_TOKEN; }
