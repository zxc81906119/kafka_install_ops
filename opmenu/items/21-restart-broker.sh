# 項目 21：重啟單一 broker
#
# 做什麼：一次只重啟一台 broker。重啟前先確認叢集健康，不健康就不重啟：
#   - 沒有 under-replicated partition（有的話代表某些資料只剩不到 3 份，再停一台可能停擺）
#   - 沒有 offline partition（有的話代表已經有 partition 沒有 leader）
# 用到的設定（opmenu.conf）：
#   OPMENU_BROKER_SERVICES   可以重啟的 broker 清單，格式「主機:服務」，例如 kb01.poc.lab:confluent-server
# 用到的共用函式：
#   v_broker_svc             檢查輸入的 broker 在不在清單內（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   be_service_restart       ssh 到那台主機重啟服務（lib/hosts.sh）
# 改的時候要注意：
#   - 檢查「本身」失敗（沒權限、連不上叢集）時一律不重啟。不能把查不到當成 0 個而放行。
#   - 選單框架（common.sh 的 core_run）在呼叫這裡之前，已經檢查過變更時窗、並行鎖、主機權限閘門。

run_21() {
  local svc="${1:-}"

  # 1. 問要重啟哪一台（從 --run 21 <broker> 直接帶進來時就不問）
  if [ -z "$svc" ]; then
    echo "可重啟的 broker:$OPMENU_BROKER_SERVICES"
    read -r -p "要重啟的 broker: " svc
  fi

  if ! v_broker_svc "$svc"; then
    return 1
  fi

  # 2. 緊急主機模式（MDS 連不上）：查不到叢集狀態，只能警告，由操作者明確確認後才重啟
  if [ "${OP_EMERGENCY_HOST:-0}" = 1 ]; then
    echo "${CR}緊急主機模式:無法確認 under-replicated／offline partition。重啟可能讓還在服務的 partition 暫時沒有 leader。${C0}"

    if ! core_confirm "在無法確認叢集狀態下重啟 $svc"; then
      return 1
    fi

    be_service_restart "$svc"
    return $?
  fi

  # 3. 檢查 under-replicated partition
  local output count

  output=$(be_kafka kafka-topics --describe --under-replicated-partitions 2>/dev/null)
  if [ $? -ne 0 ]; then
    echo "無法檢查 under-replicated partition(權限不足或連不上叢集),拒絕重啟"
    return 1
  fi

  count=$(echo "$output" | grep -c "Partition:")
  if [ "$count" -ne 0 ]; then
    echo "目前有 $count 個 under-replicated partition,拒絕重啟(官方滾動重啟前提:先回到 0)"
    return 1
  fi

  # 4. 檢查 offline partition
  output=$(be_kafka kafka-topics --describe --unavailable-partitions 2>/dev/null)
  if [ $? -ne 0 ]; then
    echo "無法檢查 offline partition(權限不足或連不上叢集),拒絕重啟"
    return 1
  fi

  count=$(echo "$output" | grep -c "Partition:")
  if [ "$count" -ne 0 ]; then
    echo "目前有 $count 個 offline partition,拒絕重啟(先處理離線問題)"
    return 1
  fi

  # 5. 確認後重啟
  if ! core_confirm "重啟 $svc;期間該台的 partition 會切換 leader"; then
    return 1
  fi

  be_service_restart "$svc"
  return $?
}
