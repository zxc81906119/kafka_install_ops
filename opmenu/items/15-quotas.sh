# 項目 15：查看配額
#
# 做什麼：列出帳號的配額（每秒可以寫多少、讀多少、佔 broker 執行緒的百分比）。可以只看一個帳號，空的 = 全部。
# 用到的設定（opmenu.conf）：
#   OPMENU_QUOTA_KEYS        要顯示哪幾種配額、照什麼順序
# 用到的共用函式：
#   v_svc_acct               檢查帳號名稱符合命名規範（lib/common.sh）
#   k_quota_lines            讀配額，每個帳號整理成一行（lib/kafka.sh）
# 改的時候要注意：
#   - --run 15 時：完全沒給參數才問；給空字串（--run 15 ""）代表全部。

run_15() {
  local account=""

  # 1. 要看哪個帳號（完全沒給參數時才問）
  if [ $# -ge 1 ]; then
    account="$1"
  else
    read -r -p "帳號(空 = 全部): " account
  fi

  if [ -n "$account" ]; then
    if ! v_svc_acct "$account"; then
      return 1
    fi
  fi

  # 2. 讀配額
  local lines
  lines=$(k_quota_lines "$account")
  if [ $? -ne 0 ]; then
    return 1
  fi

  if [ -z "$lines" ]; then
    if [ -n "$account" ]; then
      echo "帳號 $account 沒有設定配額"
    else
      echo "沒有設定配額"
    fi
    return 0
  fi

  # 3. 印表
  printf '%-28s %s\n' "帳號" "配額(bytes/秒;request_percentage = 佔 broker 執行緒的百分比)"
  echo "$lines"
}
