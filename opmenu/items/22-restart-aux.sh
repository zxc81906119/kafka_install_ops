item 22 2 y y "重啟 REST Proxy 或 C3" "影響經 REST Proxy 的 application 與管理介面的使用者"
run() {
  local svc="${1:-}"; [ -n "$svc" ] || { echo "可重啟的服務:$OPMENU_AUX_SERVICES"; read -r -p "要重啟的服務: " svc; }
  v_aux_svc "$svc" || return 1
  core_confirm "重啟 $svc" || return 1
  be_service_restart "$svc"
}
