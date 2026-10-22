item 18 1 n n "收集 diagnostics" "把各主機最近的日誌與 cluster 狀態打包,交給二線或原廠(經 ssh,需 HOST 權限)"
run() {
  local d="$OPMENU_OUT_DIR/diag-$(date +%Y%m%d-%H%M%S)-$OP_USER"
  be_collect_diag "$d" || return $?
  be_kafka kafka-topics --describe > "$d/topics.txt" 2>&1
  be_kafka kafka-consumer-groups --list > "$d/consumer-groups.txt" 2>&1
  be_disk_usage > "$d/disk.txt" 2>&1
  tar -C "$(dirname "$d")" -czf "$d.tgz" "$(basename "$d")" && rm -rf "$d"
  echo "已打包:$d.tgz($(du -h "$d.tgz" | cut -f1))"
}
