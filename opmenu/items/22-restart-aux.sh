run_22() {
  local svc="${1:-}"; [ -n "$svc" ] || { echo "可重啟的服務:$OPMENU_AUX_SERVICES"; read -r -p "要重啟的服務: " svc; }
  v_aux_svc "$svc" || return 1
  if [ "${svc##*:}" = confluent-kafka-rest ]; then   # REST：先請 LB 團隊停用這一台，重啟完再恢復（手把手 12.1）
    local host="${svc%%:*}" connections
    connections=$(be_lb_connections "$host")
    if [ -n "$connections" ] && [ "$connections" != 0 ]; then echo "$host 還有 $connections 條從負載平衡進來的連線：請先請 LB 團隊停用 $host，停用後再重啟"; return 1; fi
    core_confirm "重啟 $svc（LB 團隊已經停用 $host）" || return 1
    be_service_restart "$svc" && echo "下一步：請 LB 團隊恢復 $host"
    return
  fi
  core_confirm "重啟 $svc" || return 1
  be_service_restart "$svc"
}
