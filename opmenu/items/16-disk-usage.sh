# 項目 16：查看各主機的資料磁碟用量
#
# 做什麼：每台主機印一行資料目錄（OPMENU_DATA_DIR）的用量與剩餘空間。
# 用到的設定（opmenu.conf）：
#   OPMENU_HOSTS             要看的主機
#   OPMENU_DATA_DIR          資料目錄（例如 /var/lib/kafka）
# 用到的共用函式：
#   be_disk_usage            ssh 到每台主機跑 df（lib/hosts.sh）
# 改的時候要注意：
#   - 這是碰主機的項目：選單框架會先過主機權限閘門、確認 SSH 私鑰在（OPMENU_HOST_ITEMS 有列 16）。

run_16() {
  be_disk_usage
}
