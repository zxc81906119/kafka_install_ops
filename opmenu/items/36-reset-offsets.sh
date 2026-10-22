item 36 3 y y "重設 consumer 讀取位置" "該 consumer group 必須先停止;可重設到最早、最新或指定時間"
run() {
  local g="${1:-}" to="${2:-}"; [ -n "$g" ] || read -r -p "consumer group: " g; [ -n "$to" ] || read -r -p "重設到(earliest | latest | 2026-01-31T00:00:00.000): " to
  v_group "$g" || return 1; v_offset_to "$to" || return 1
  local opt; case "$to" in earliest) opt="--to-earliest";; latest) opt="--to-latest";; *) opt="--to-datetime $to";; esac
  if be_kafka kafka-consumer-groups --describe --group "$g" --members 2>/dev/null | grep -q -E '^[^ ]+ +[^ ]+ +/'; then echo "consumer group $g 仍有成員在線,拒絕重設(先停止 application)"; return 1; fi
  echo "-- 預覽(不會執行):"; be_kafka kafka-consumer-groups --reset-offsets --group "$g" --all-topics $opt --dry-run || return $?
  core_confirm "重設 $g 的讀取位置到 $to" || return 1
  be_kafka kafka-consumer-groups --reset-offsets --group "$g" --all-topics $opt --execute
}
