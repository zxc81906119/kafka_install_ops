run_27() {
  local svcs=($OPMENU_BROKER_SERVICES) n urp off live; n=${#svcs[@]}
  [ "$n" -ge 2 ] || { echo "只有 $n 台 broker,滾動重啟沒有意義(重啟就是中斷服務),請改用項目 21"; return 1; }
  read -r urp off live <<<"$(k_cluster_counts)"
  { [ "$urp" = 0 ] && [ "$off" = 0 ] && [ "$live" = "$n" ]; } || { echo "cluster 目前不健康(under-replicated=$urp offline=$off 在線 broker=$live/$n),拒絕開始"; return 1; }
  core_confirm "依序重啟 ${svcs[*]}(共 $n 台,每台等 cluster 恢復才換下一台)" || return 1
  local s i=0 waited ok good
  for s in "${svcs[@]}"; do
    i=$((i+1)); echo "== [$i/$n] 重啟 $s"; core_log STEP "27 滾動重啟" "$s 開始"
    be_service_restart "$s" || { echo "重啟 $s 失敗,停止(後面的 broker 沒有動)"; core_log STEP "27 滾動重啟" "$s 失敗"; return 1; }
    echo "  先等 ${OPMENU_ROLLING_SETTLE}s(讓 broker 被判定離線、ISR 縮減,避免剛重啟時誤判健康)"; sleep "$OPMENU_ROLLING_SETTLE"
    waited=0; ok=0; good=0
    while [ "$waited" -lt "$OPMENU_ROLLING_TIMEOUT" ]; do
      read -r urp off live <<<"$(k_cluster_counts)"
      if [ "$urp" = 0 ] && [ "$off" = 0 ] && [ "$live" = "$n" ]; then good=$((good+1)); [ "$good" -ge "$OPMENU_ROLLING_STABLE" ] && { ok=1; break; }; else good=0; fi
      sleep 10; waited=$((waited+10))
      echo "  等待 cluster 恢復…(${waited}s;under-replicated=$urp offline=$off 在線 $live/$n;連續健康 $good/$OPMENU_ROLLING_STABLE)"
    done
    [ $ok = 1 ] || { echo "超過 ${OPMENU_ROLLING_TIMEOUT}s cluster 沒有恢復,停止(不再重啟下一台)"; core_log STEP "27 滾動重啟" "$s 後逾時"; return 1; }
    echo "  $s 已回到 cluster,under-replicated 與 offline 都是 0"; core_log STEP "27 滾動重啟" "$s 完成"
  done
  echo "全部 $n 台 broker 已完成滾動重啟"
}
