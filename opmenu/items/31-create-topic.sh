item 31 3 y y "建立 topic" "名稱須符合命名規範 <系統>.<名稱>;replication factor 固定為標準值"
run() {
  local t="${1:-}" p="${2:-}"; [ -n "$t" ] || read -r -p "topic 名稱: " t; [ -n "$p" ] || read -r -p "partition count: " p
  v_topic "$t" || return 1; v_number "$p" "partition count" || return 1
  core_confirm "建立 topic $t(partition $p、replica $OPMENU_REPLICATION)" || return 1
  be_kafka kafka-topics --create --topic "$t" --partitions "$p" --replication-factor "$OPMENU_REPLICATION"
}
