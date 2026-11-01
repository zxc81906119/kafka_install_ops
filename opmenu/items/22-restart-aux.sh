# 項目 22：重啟 REST Proxy 或 Control Center
#
# 做什麼：重啟一台輔助服務（REST Proxy、Control Center）。
#   REST Proxy 前面有負載平衡：要先請 LB 團隊停用這一台，確認沒有連線進來才重啟，重啟完再請 LB 團隊恢復（手把手 12.1）。
# 用到的設定（opmenu.conf）：
#   OPMENU_AUX_SERVICES      可以重啟的服務清單，格式「主機:服務」，例如 rest01.poc.lab:confluent-kafka-rest
#   OPMENU_LB_HOST           負載平衡的主機名稱（用來數從 LB 進來的連線；沒設就不檢查）
# 用到的共用函式：
#   v_aux_svc                檢查輸入的服務在不在清單內（lib/common.sh）
#   be_lb_connections        那台 REST 上從負載平衡進來的連線數（lib/hosts.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   be_service_restart       ssh 到那台主機重啟服務（lib/hosts.sh）
# 改的時候要注意：
#   - 這是碰主機的項目：選單框架會先過主機權限閘門（OPMENU_HOST_ITEMS 有列 22）。

run_22() {
  local svc="${1:-}"

  # 1. 問要重啟哪一個服務
  if [ -z "$svc" ]; then
    echo "可重啟的服務:$OPMENU_AUX_SERVICES"
    read -r -p "要重啟的服務: " svc
  fi

  if ! v_aux_svc "$svc"; then
    return 1
  fi

  # 拆開「主機:服務」：冒號前是主機，冒號後是服務名
  local host unit
  host=$(echo "$svc" | cut -d: -f1)
  unit=$(echo "$svc" | cut -d: -f2)

  # 2. REST Proxy：LB 團隊要先停用這一台（還有連線進來就不重啟）
  if [ "$unit" = confluent-kafka-rest ]; then
    local connections
    connections=$(be_lb_connections "$host")

    if [ -n "$connections" ] && [ "$connections" != 0 ]; then
      echo "$host 還有 $connections 條從負載平衡進來的連線：請先請 LB 團隊停用 $host，停用後再重啟"
      return 1
    fi

    if ! core_confirm "重啟 $svc（LB 團隊已經停用 $host）"; then
      return 1
    fi

    if ! be_service_restart "$svc"; then
      return 1
    fi

    echo "下一步：請 LB 團隊恢復 $host"
    return 0
  fi

  # 3. 其他服務（Control Center）：確認後直接重啟
  if ! core_confirm "重啟 $svc"; then
    return 1
  fi

  be_service_restart "$svc"
  return $?
}
