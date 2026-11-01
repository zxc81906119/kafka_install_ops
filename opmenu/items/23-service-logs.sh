# 項目 23：查看服務日誌（只看錯誤與警告）
#
# 做什麼：取一個服務最近的日誌，只印出 ERROR、WARN 的行。
# 用到的設定（opmenu.conf）：
#   OPMENU_BROKER_SERVICES、OPMENU_AUX_SERVICES   可以看的服務清單
# 用到的共用函式：
#   v_any_svc                檢查輸入的服務在不在清單內（lib/common.sh）
#   v_number                 檢查是數字（lib/common.sh）
#   be_service_logs          ssh 到那台主機讀 journalctl（lib/hosts.sh；一次最多 200 行）
# 改的時候要注意：
#   - 先拿到日誌和結束碼，再過濾。不然權限閘門拒絕或 ssh 失敗時，過濾完是空的，會被誤當成「沒有錯誤」。
#   - 這是碰主機的項目：選單框架會先過主機權限閘門（OPMENU_HOST_ITEMS 有列 23）。

run_23() {
  local svc="${1:-}"
  local lines="${2:-50}"

  # 1. 問要看哪一個服務
  if [ -z "$svc" ]; then
    echo "服務:$OPMENU_BROKER_SERVICES $OPMENU_AUX_SERVICES"
    read -r -p "服務: " svc
  fi

  if ! v_any_svc "$svc"; then
    return 1
  fi

  if ! v_number "$lines" "行數"; then
    return 1
  fi

  # 2. 取日誌（失敗就把錯誤訊息印出來，回傳失敗）
  local log rc
  log=$(be_service_logs "$svc" "$lines")
  rc=$?

  if [ $rc -ne 0 ]; then
    echo "$log"
    return $rc
  fi

  # 3. 只留 ERROR、WARN 的行
  local problems
  problems=$(echo "$log" | grep -i -E "ERROR|WARN" | tail -n "$lines")

  if [ -n "$problems" ]; then
    echo "$problems"
  else
    echo "(最近 $lines 行沒有錯誤或警告)"
  fi
}
