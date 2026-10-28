# secrets/file.sh —— 機敏資料從操作機上只有 root 讀得到的檔案取（唯一的來源）
#
# 介面：secret_get <檔案路徑>   把檔案內容印到 stdout；檔案不存在、權限或 owner 不對、是空的，回傳非 0 並印原因到 stderr
#
# 現在只有 91 緊急模式用它(取 client 憑證 PEM,預設 ~/secrets/opmenu-breakglass.pem)。主機用的 SSH 私鑰不經過這裡:它是操作機獨立 file system 上的檔案(OPMENU_SSH_KEY_FILE)。
# 平台的密碼與金鑰不放 CyberArk:都在操作機 root 才讀得到的位置(0600)。檔案權限必須是 0600 或 0400、owner 是執行者本人,否則拒絕(避免別人讀得到的檔案被當成緊急憑證)。
# 這裡不提示貼上、不連任何保管庫;讀到的內容只經過管線交給暫存檔(0600,用完即刪)。誰在什麼時候要了這份憑證,由呼叫端(91)記 EMERGENCY 稽核。
#
# 設定（opmenu.conf）：
#   OPMENU_BREAKGLASS_PEM  緊急憑證 PEM(私鑰 + 憑證鏈)的檔案路徑

secrets_name() { echo "file (操作機上 0600 的檔案)"; }

secret_get() {
  local file=$1 mode owner
  if [ -z "$file" ]; then
    echo "沒有指定檔案路徑" >&2
    return 1
  fi
  if [ ! -f "$file" ]; then
    echo "找不到檔案：$file" >&2
    return 1
  fi
  mode=$(stat -c '%a' "$file" 2>/dev/null) || { echo "讀不到檔案屬性：$file" >&2; return 1; }
  owner=$(stat -c '%u' "$file" 2>/dev/null)
  if [ "$mode" != 600 ] && [ "$mode" != 400 ]; then
    echo "檔案權限必須是 0600 或 0400（現在是 $mode），拒絕使用：$file" >&2
    return 1
  fi
  if [ "$owner" != "$(id -u)" ]; then
    echo "檔案的 owner 必須是執行者本人，拒絕使用：$file" >&2
    return 1
  fi
  if [ ! -s "$file" ]; then
    echo "檔案是空的：$file" >&2
    return 1
  fi
  cat "$file"
}
