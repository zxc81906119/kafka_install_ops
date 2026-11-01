run_23() {
  local svc="${1:-}" n="${2:-50}"; [ -n "$svc" ] || { echo "服務:$OPMENU_BROKER_SERVICES $OPMENU_AUX_SERVICES"; read -r -p "服務: " svc; }
  v_any_svc "$svc" || return 1; v_number "$n" "行數" || return 1
  local raw rc out   # 先取日誌與回傳碼再過濾:否則權限閘門拒絕或 ssh 失敗會被當成「沒有錯誤」
  raw=$(be_service_logs "$svc" "$n"); rc=$?
  [ $rc -eq 0 ] || { printf '%s\n' "$raw"; return $rc; }
  out=$(grep -i -E "ERROR|WARN" <<< "$raw" | tail -"$n"); printf '%s\n' "${out:-(最近 $n 行沒有錯誤或警告)}"
}
