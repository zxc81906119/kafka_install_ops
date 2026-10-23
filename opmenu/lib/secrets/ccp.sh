# secrets/ccp.sh —— 向 CyberArk PAM 的 Central Credential Provider（CCP）取機敏資料（範本：依行內 CCP 的 AppID、safe、object 命名調整；未實測）
#
# 介面：secret_get <object 名稱>   成功把值印到 stdout；失敗回傳非 0 並印原因到 stderr
# 身分：AppID + client 憑證（OPMENU_CCP_CERT／OPMENU_CCP_KEY，0640 root:opmenu）+ 來源 IP（在 CCP 端設定）。
# CCP 回 JSON，值在 "Content" 欄。只用 sed 取，不靠 python／jq。

secrets_name() { echo "ccp ($OPMENU_CCP_URL, AppID $OPMENU_CCP_APPID)"; }

MASK=$'\001'   # 暫時代替值裡跳脫的引號 \" 的字元（JSON 裡不會出現）

secret_get() {
  local object_name=$1 response content
  response=$(curl -sS -f --max-time 10 --cacert "$OPMENU_CA_PEM" --cert "$OPMENU_CCP_CERT" --key "$OPMENU_CCP_KEY" --get \
               --data-urlencode "AppID=$OPMENU_CCP_APPID" --data-urlencode "Safe=$OPMENU_CCP_SAFE" --data-urlencode "Object=$object_name" \
               "$OPMENU_CCP_URL") || { echo "CCP 取值失敗：$object_name" >&2; return 1; }
  # 1. 值裡跳脫的引號 \" 先換成 MASK，這樣「到下一個引號為止」就是整個值
  # 2. 取出 "Content":"……" 的值
  # 3. MASK 換回 "、JSON 的 \/ 換回 /
  content=$(printf '%s' "$response" \
    | sed "s/\\\\\"/$MASK/g" \
    | sed -n 's/.*"Content" *: *"\([^"]*\)".*/\1/p' \
    | sed "s/$MASK/\"/g; s|\\\\/|/|g")
  [ -n "$content" ] || { echo "CCP 回應裡沒有 Content：$object_name" >&2; return 1; }
  # 私鑰這種多行的值，JSON 裡換行寫成 \n：printf '%b' 會把它還原成真的換行
  printf '%b' "$content"
}
