# ticket/http.sh — 向客戶的開單系統查 ticket(範本,未實測;依實際 API 調整 _ticket_fetch 與 OPMENU_TICKET_OK_PATTERN)
# 介面:ticket_check <ticket>  通過回傳 0;不通過印出原因並回傳非 0
_ticket_fetch() { curl -s -f --max-time 10 "$OPMENU_TICKET_URL/$1"; }   # 假設 GET <網址>/<ticket> 回傳含狀態的 JSON
ticket_check() {
  [[ "$1" =~ $OPMENU_TICKET_PATTERN ]] || { echo "ticket 格式不符(規則:$OPMENU_TICKET_PATTERN)"; return 1; }
  [ -n "$OPMENU_TICKET_URL" ] || { echo "沒有設定 OPMENU_TICKET_URL"; return 1; }
  local r; r=$(_ticket_fetch "$1") || { echo "查不到 ticket $1(開單系統沒有回應或單不存在)"; return 1; }
  printf '%s' "$r" | grep -q -E "$OPMENU_TICKET_OK_PATTERN" || { echo "ticket $1 尚未核准"; return 1; }
}
