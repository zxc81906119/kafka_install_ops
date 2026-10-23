# secrets/manual.sh —— 機敏資料由人從 CyberArk PVWA 取出後貼上（銀行沒有 CCP／CP 時用）
#
# 介面：secret_get <object 名稱>   把貼上的內容印到 stdout；沒有終端機、或什麼都沒貼，回傳非 0 並印原因到 stderr
#
# 流程：選單需要某個值（登入後的 cpadmin 私鑰、91 緊急模式的憑證 PEM）時，提示維運人員到 PVWA 取出指定的 object，
#       貼到畫面上、按 Ctrl-D 結束。內容只經過管線交給 ssh-agent 或暫存檔（0600，用完即刪），不寫進任何設定。
# 取用紀錄、雙人覆核、變更單號都在 PVWA 那一端；選單這裡只記「哪個 object 被要求、誰要的」。
#
# 設定（opmenu.conf）：OPMENU_SECRETS=manual
#   OPMENU_SSH_KEY_SECRET     PVWA 上 cpadmin 私鑰的 object 名稱（只用來提示，例如 "Safe KAFKA-OPS / cpadmin-hosts"）
#   OPMENU_BREAKGLASS_SECRET  PVWA 上緊急憑證的 object 名稱

secrets_name() { echo "manual (從 PVWA 取出後貼上)"; }

secret_get() {
  local object_name=$1 pasted
  if [ ! -r /dev/tty ]; then
    echo "需要人工貼上 $object_name，但目前沒有終端機（非互動執行）" >&2
    return 1
  fi
  {
    echo
    echo "請到 CyberArk PVWA 取出：$object_name"
    echo "整段貼在下面（私鑰或 PEM 都是多行），貼完按 Enter 再按 Ctrl-D。畫面不會顯示貼上的內容。"
  } > /dev/tty
  # 關掉回顯，貼上的內容不會留在畫面或終端機的捲動紀錄裡
  stty -echo < /dev/tty 2>/dev/null
  pasted=$(cat < /dev/tty)
  stty echo < /dev/tty 2>/dev/null
  echo > /dev/tty
  if [ -z "$pasted" ]; then
    echo "沒有貼上任何內容：$object_name" >&2
    return 1
  fi
  printf '%s\n' "$pasted"
}
