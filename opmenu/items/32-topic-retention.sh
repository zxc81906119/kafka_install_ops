# 項目 32：修改 topic 的保留時間（retention）
#
# 做什麼：把一個 topic 的 retention.ms 改成新的值；確認前先顯示目前的值。
# 用到的設定（opmenu.conf）：
#   OPMENU_TOPIC_PATTERN     topic 命名規範
# 用到的共用函式：
#   v_topic                  檢查 topic 名稱符合命名規範、不是受保護的 topic（lib/common.sh）
#   v_number                 檢查是數字（lib/common.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
# 改的時候要注意：
#   - 單位是毫秒：一天 = 86400000。

run_32() {
  local topic="${1:-}"
  local retention_ms="${2:-}"

  # 1. 問 topic 名稱與新的 retention
  if [ -z "$topic" ]; then
    read -r -p "topic 名稱: " topic
  fi

  if [ -z "$retention_ms" ]; then
    read -r -p "新的 retention(毫秒): " retention_ms
  fi

  if ! v_topic "$topic"; then
    return 1
  fi

  if ! v_number "$retention_ms" "retention"; then
    return 1
  fi

  # 2. 讀目前的值（讀不到就顯示「未知」）
  local current
  current=$(be_kafka kafka-configs --describe --entity-type topics --entity-name "$topic" --all 2>/dev/null \
    | grep -o 'retention.ms=[0-9-]*' \
    | head -1)

  if [ -z "$current" ]; then
    current="未知"
  fi

  # 3. 確認後修改
  if ! core_confirm "修改 $topic 的 retention:$current → retention.ms=$retention_ms"; then
    return 1
  fi

  be_kafka kafka-configs --alter --entity-type topics --entity-name "$topic" --add-config "retention.ms=$retention_ms"
}
