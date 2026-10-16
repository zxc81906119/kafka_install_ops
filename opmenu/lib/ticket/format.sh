# ticket/format.sh — ticket 只檢查格式(客戶沒有可查詢的開單系統時用)
# 介面:ticket_check <ticket>  通過回傳 0;不通過印出原因並回傳非 0
ticket_check() { [[ "$1" =~ $OPMENU_TICKET_PATTERN ]] || { echo "ticket 格式不符(規則:$OPMENU_TICKET_PATTERN)"; return 1; }; }
