item 33 3 y y "刪除 topic" "有 consumer 在線時拒絕;受保護的 topic 不處理"
run() {
  local t="${1:-}"; [ -n "$t" ] || read -r -p "要刪除的 topic: " t
  v_topic "$t" || return 1
  # 一次描述全部 group,找出成員正在訂閱這個 topic 的 group(精確比對 topic 欄,不用子字串)
  local active; active=$(be_kafka kafka-consumer-groups --describe --all-groups --members --verbose 2>/dev/null | awk -v t="$t" '$1 !~ /^(GROUP|$)/ { for (i=1;i<=NF;i++) if ($i == t || $i ~ "^" t "\\(") { print $1; break } }' | sort -u)
  [ -z "$active" ] || { echo "有 consumer 正在讀這個 topic:$(echo "$active" | tr '\n' ' ');拒絕刪除"; return 1; }
  core_confirm "刪除 topic $t,資料不可復原" || return 1
  be_kafka kafka-topics --delete --topic "$t"
}
