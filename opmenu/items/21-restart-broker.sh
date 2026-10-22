item 21 2 y y "重啟單一 broker" "一次只重啟一台;執行前檢查沒有 under-replicated 與 offline partition,否則拒絕"
run() {
  local svc="${1:-}"; [ -n "$svc" ] || { echo "可重啟的 broker:$OPMENU_BROKER_SERVICES"; read -r -p "要重啟的 broker: " svc; }
  v_broker_svc "$svc" || return 1
  local o rc urp off
  # 檢查本身失敗(沒權限、連不上叢集)時一律拒絕;不能用 "| grep -c" 把失敗數成 0 而放行
  o=$(be_kafka kafka-topics --describe --under-replicated-partitions 2>/dev/null); rc=$?
  [ $rc -eq 0 ] || { echo "無法檢查 under-replicated partition(權限不足或連不上叢集,rc=$rc),拒絕重啟"; return 1; }
  urp=$(grep -c "Partition:" <<< "$o")
  [ "$urp" = 0 ] || { echo "目前有 $urp 個 under-replicated partition,拒絕重啟(官方滾動重啟前提:先回到 0)"; return 1; }
  o=$(be_kafka kafka-topics --describe --unavailable-partitions 2>/dev/null); rc=$?
  [ $rc -eq 0 ] || { echo "無法檢查 offline partition(權限不足或連不上叢集,rc=$rc),拒絕重啟"; return 1; }
  off=$(grep -c "Partition:" <<< "$o")
  [ "$off" = 0 ] || { echo "目前有 $off 個 offline partition,拒絕重啟(先處理離線問題)"; return 1; }
  core_confirm "重啟 $svc;期間該台的 partition 會切換 leader" || return 1
  be_service_restart "$svc"
}
