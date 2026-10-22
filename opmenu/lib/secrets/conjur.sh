# secrets/conjur.sh — 向 CyberArk Conjur 取機敏資料(lab 用 Conjur OSS 扮演 CyberArk;Conjur Enterprise 的 API 相同)
# 介面:secret_get <變數路徑>   成功把值印到 stdout(不含多餘換行),失敗回傳非 0 並印原因到 stderr
# 身分:OPMENU_CONJUR_IDENTITY(兩行 login=host/…、api_key=…;0640 root:opmenu)。token 只在記憶體,每次取值重新認證。
# 值不經命令列參數(--data-binary @- 從 stdin、Authorization 用 -K - 從 stdin),行程清單看不到。
secrets_name() { echo "conjur ($OPMENU_CONJUR_URL, $OPMENU_CONJUR_ACCOUNT)"; }
_conjur_identity() { [ -r "$OPMENU_CONJUR_IDENTITY" ] || { echo "讀不到 Conjur 身分檔 $OPMENU_CONJUR_IDENTITY(需要 opmenu 群組)" >&2; return 1; }
  local l k; l=$(sed -n 's/^login=//p' "$OPMENU_CONJUR_IDENTITY"); k=$(sed -n 's/^api_key=//p' "$OPMENU_CONJUR_IDENTITY")
  [ -n "$l" ] && [ -n "$k" ] || { echo "Conjur 身分檔格式應為 login=… 與 api_key=…" >&2; return 1; }
  printf '%s
%s
' "$l" "$k"; }
_urlenc() { local s="$1" o="" c; local i; for ((i=0;i<${#s};i++)); do c="${s:i:1}"; case "$c" in [A-Za-z0-9.~_-]) o+="$c";; *) o+=$(printf '%%%02X' "'$c");; esac; done; printf '%s' "$o"; }
secret_get() {
  local path="$1" login key tok
  { read -r login; read -r key; } < <(_conjur_identity) || return 1
  tok=$(printf '%s' "$key" | curl -sS -f --max-time 10 --cacert "$OPMENU_CA_PEM" -X POST --data-binary @- "$OPMENU_CONJUR_URL/authn/$OPMENU_CONJUR_ACCOUNT/$(_urlenc "$login")/authenticate" 2>/dev/null | base64 -w0) \
    && [ -n "$tok" ] || { echo "Conjur 認證失敗(身分 $login)" >&2; return 1; }
  printf 'header = "Authorization: Token token=\\"%s\\""\n' "$tok" | curl -sS -f --max-time 10 --cacert "$OPMENU_CA_PEM" -K - "$OPMENU_CONJUR_URL/secrets/$OPMENU_CONJUR_ACCOUNT/variable/$(_urlenc "$path")" \
    || { echo "Conjur 取值失敗:$path(沒有權限或變數不存在)" >&2; return 1; }
}
