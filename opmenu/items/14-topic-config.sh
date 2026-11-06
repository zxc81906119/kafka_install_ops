# 項目 14：查看某個 topic 的設定
#
# 做什麼：印出一個 topic 的 retention、cleanup policy、min.insync.replicas，以及 partition 數與 replication factor。
# 用到的設定：沒有
# 用到的共用函式：
#   v_topic_ro               檢查 topic 名稱只含合法字元（唯讀項目用，比 v_topic 寬鬆）（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
# 改的時候要注意：
#   - 想多看哪個設定，就把名稱加進下面 grep 的清單。

run_14() {
  local topic="${1:-}"

  # 1. 要看哪個 topic
  if [ -z "$topic" ]; then
    read -r -p "topic 名稱: " topic
  fi

  if ! v_topic_ro "$topic"; then
    return 1
  fi

  # 2. 這幾個設定的值（去掉後面 sensitive=… 那一串）
  be_kafka kafka-configs --describe --entity-type topics --entity-name "$topic" --all \
    | grep -E 'retention.ms|cleanup.policy|min.insync.replicas' \
    | sed -E 's/\s+sensitive=.*//'

  # 3. partition 數與 replication factor（describe 的第一行）
  be_kafka kafka-topics --describe --topic "$topic" | head -1
}
