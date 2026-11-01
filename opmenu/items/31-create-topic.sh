# 項目 31：建立 topic
#
# 做什麼：建立一個 topic，partition 數由操作者輸入，replication factor 固定用 OPMENU_REPLICATION。
# 用到的設定（opmenu.conf）：
#   OPMENU_TOPIC_PATTERN     topic 命名規範（例如 <系統>.<名稱>）
#   OPMENU_REPLICATION       replication factor（預設 3；broker 不到 3 台時自動降成台數）
# 用到的共用函式：
#   v_topic                  檢查 topic 名稱符合命名規範、不是受保護的 topic（lib/common.sh）
#   v_number                 檢查是數字（lib/common.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
# 改的時候要注意：
#   - 有沒有權限建 topic 由 Kafka 依 RBAC 判斷；沒權限時 Kafka 會拒絕，選單紀錄記成 DENIED。

run_31() {
  local topic="${1:-}"
  local partitions="${2:-}"

  # 1. 問 topic 名稱與 partition 數
  if [ -z "$topic" ]; then
    read -r -p "topic 名稱: " topic
  fi

  if [ -z "$partitions" ]; then
    read -r -p "partition count: " partitions
  fi

  if ! v_topic "$topic"; then
    return 1
  fi

  if ! v_number "$partitions" "partition count"; then
    return 1
  fi

  # 2. 確認後建立
  if ! core_confirm "建立 topic $topic(partition $partitions、replica $OPMENU_REPLICATION)"; then
    return 1
  fi

  be_kafka kafka-topics --create --topic "$topic" --partitions "$partitions" --replication-factor "$OPMENU_REPLICATION"
}
