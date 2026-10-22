item 14 1 n n "查看某個 topic 的設定" "retention、partition count、replication factor"
run() {
  local t="${1:-}"; [ -n "$t" ] || read -r -p "topic 名稱: " t; v_topic_ro "$t" || return 1
  be_kafka kafka-configs --describe --entity-type topics --entity-name "$t" --all | grep -E "retention.ms|cleanup.policy|min.insync.replicas" | sed -E 's/\s+sensitive=.*//'
  be_kafka kafka-topics --describe --topic "$t" | head -1
}
