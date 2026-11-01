# 項目 27：滾動重啟所有 broker
#
# 做什麼：依設定的順序一台一台重啟 broker。每重啟一台，就等叢集回到健康（under-replicated 與 offline 都是 0、
#   所有 broker 在線，而且連續幾次都健康）才換下一台；任何一台出問題就停下來，後面的不動。
# 用到的設定（opmenu.conf）：
#   OPMENU_BROKER_SERVICES   broker 清單（也是重啟的順序）
#   OPMENU_ROLLING_SETTLE    每台重啟後先等幾秒，再開始檢查
#   OPMENU_ROLLING_TIMEOUT   每台最多等幾秒恢復
#   OPMENU_ROLLING_STABLE    要連續幾次健康才算恢復
# 用到的共用函式：
#   k_cluster_counts         印出「under-replicated 數 offline 數 在線 broker 數」（lib/kafka.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   be_service_restart       ssh 到那台主機重啟服務（lib/hosts.sh）
#   core_log                 寫一筆選單紀錄（lib/common.sh；每台開始、完成、失敗都記）
# 改的時候要注意：
#   - 剛重啟的那幾秒，broker 還沒被判定離線，叢集看起來是健康的；所以要先等 OPMENU_ROLLING_SETTLE 秒、再要求「連續幾次健康」。

run_27() {
  local brokers count
  brokers=$OPMENU_BROKER_SERVICES
  count=$(echo $brokers | wc -w)

  # 1. 至少要兩台：只有一台的話，重啟就是中斷服務
  if [ "$count" -lt 2 ]; then
    echo "只有 $count 台 broker,滾動重啟沒有意義(重啟就是中斷服務),請改用項目 21"
    return 1
  fi

  # 2. 開始前叢集要健康
  local counts urp off live
  counts=$(k_cluster_counts)
  urp=$(echo "$counts" | cut -d' ' -f1)
  off=$(echo "$counts" | cut -d' ' -f2)
  live=$(echo "$counts" | cut -d' ' -f3)

  if [ "$urp" != 0 ] || [ "$off" != 0 ] || [ "$live" != "$count" ]; then
    echo "cluster 目前不健康(under-replicated=$urp offline=$off 在線 broker=$live/$count),拒絕開始"
    return 1
  fi

  # 3. 確認
  if ! core_confirm "依序重啟 $brokers(共 $count 台,每台等 cluster 恢復才換下一台)"; then
    return 1
  fi

  # 4. 一台一台來
  local broker number=0

  for broker in $brokers; do
    number=$(( number + 1 ))
    echo "== [$number/$count] 重啟 $broker"
    core_log STEP "27 滾動重啟" "$broker 開始"

    # 4-1. 重啟這一台（失敗就停）
    if ! be_service_restart "$broker"; then
      echo "重啟 $broker 失敗,停止(後面的 broker 沒有動)"
      core_log STEP "27 滾動重啟" "$broker 失敗"
      return 1
    fi

    # 4-2. 先等一下，讓 broker 被判定離線、ISR 縮減
    echo "  先等 ${OPMENU_ROLLING_SETTLE}s(讓 broker 被判定離線、ISR 縮減,避免剛重啟時誤判健康)"
    sleep "$OPMENU_ROLLING_SETTLE"

    # 4-3. 每 10 秒看一次，連續 OPMENU_ROLLING_STABLE 次健康才算恢復；超過 OPMENU_ROLLING_TIMEOUT 秒就停
    local waited=0 healthy_in_a_row=0 recovered=no

    while [ "$waited" -lt "$OPMENU_ROLLING_TIMEOUT" ]; do
      counts=$(k_cluster_counts)
      urp=$(echo "$counts" | cut -d' ' -f1)
      off=$(echo "$counts" | cut -d' ' -f2)
      live=$(echo "$counts" | cut -d' ' -f3)

      if [ "$urp" = 0 ] && [ "$off" = 0 ] && [ "$live" = "$count" ]; then
        healthy_in_a_row=$(( healthy_in_a_row + 1 ))
      else
        healthy_in_a_row=0
      fi

      if [ "$healthy_in_a_row" -ge "$OPMENU_ROLLING_STABLE" ]; then
        recovered=yes
        break
      fi

      sleep 10
      waited=$(( waited + 10 ))
      echo "  等待 cluster 恢復…(${waited}s;under-replicated=$urp offline=$off 在線 $live/$count;連續健康 $healthy_in_a_row/$OPMENU_ROLLING_STABLE)"
    done

    if [ "$recovered" = no ]; then
      echo "超過 ${OPMENU_ROLLING_TIMEOUT}s cluster 沒有恢復,停止(不再重啟下一台)"
      core_log STEP "27 滾動重啟" "$broker 後逾時"
      return 1
    fi

    echo "  $broker 已回到 cluster,under-replicated 與 offline 都是 0"
    core_log STEP "27 滾動重啟" "$broker 完成"
  done

  echo "全部 $count 台 broker 已完成滾動重啟"
}
