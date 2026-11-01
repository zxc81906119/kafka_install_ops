run_32() {
  local t="${1:-}" ms="${2:-}"; [ -n "$t" ] || read -r -p "topic 名稱: " t; [ -n "$ms" ] || read -r -p "新的 retention(毫秒): " ms
  v_topic "$t" || return 1; v_number "$ms" "retention" || return 1
  local cur; cur=$(be_kafka kafka-configs --describe --entity-type topics --entity-name "$t" --all 2>/dev/null | grep -o 'retention.ms=[0-9-]*' | head -1)
  core_confirm "修改 $t 的 retention:${cur:-未知} → retention.ms=$ms" || return 1
  be_kafka kafka-configs --alter --entity-type topics --entity-name "$t" --add-config "retention.ms=$ms"
}
