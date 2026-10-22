# secrets/ccp.sh — 向 CyberArk PAM 的 Central Credential Provider(CCP)取機敏資料(範本:依行內 CCP 的 AppID、safe、object 命名調整;未實測)
# 介面:secret_get <object 名稱>   成功把值印到 stdout,失敗回傳非 0 並印原因到 stderr
# 身分:AppID + client 憑證(OPMENU_CCP_CERT / OPMENU_CCP_KEY,0640 root:opmenu)+ 來源 IP(在 CCP 端設定)。
# CCP 回 JSON,密碼或私鑰內容在 "Content" 欄;這裡用 python3 解析(jq 不一定有)。
secrets_name() { echo "ccp ($OPMENU_CCP_URL, AppID $OPMENU_CCP_APPID)"; }
secret_get() {
  local obj="$1" out
  out=$(curl -sS -f --max-time 10 --cacert "$OPMENU_CA_PEM" --cert "$OPMENU_CCP_CERT" --key "$OPMENU_CCP_KEY" \
        --get --data-urlencode "AppID=$OPMENU_CCP_APPID" --data-urlencode "Safe=$OPMENU_CCP_SAFE" --data-urlencode "Object=$obj" "$OPMENU_CCP_URL") \
    || { echo "CCP 取值失敗:$obj" >&2; return 1; }
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.stdout.write(d["Content"])' 2>/dev/null \
    || { echo "CCP 回應裡沒有 Content:$obj" >&2; return 1; }
}
