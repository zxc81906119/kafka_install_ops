item 33 3 y y "刪除 topic" "有 consumer 在線時拒絕;受保護的 topic 不處理"
run() {
  local t="${1:-}"; [ -n "$t" ] || read -r -p "要刪除的 topic: " t
  v_topic "$t" || return 1
  # 一次描述全部 group,找出成員正在訂閱這個 topic 的 group(精確比對 topic 欄,不用子字串)
  # 檢查本身失敗(沒有 Group 的 Describe、連不上叢集)時一律拒絕:不能把失敗當成「沒有 consumer」而刪掉還在讀的 topic
  local o rc active; o=$(be_kafka kafka-consumer-groups --describe --all-groups --members --verbose 2>/dev/null); rc=$?
  [ $rc -eq 0 ] || { echo "無法檢查哪些 consumer group 在讀這個 topic(權限不足或連不上叢集,rc=$rc),拒絕刪除"; return 1; }
  active=$(printf '%s\n' "$o" | awk -v t="$t" '$1 !~ /^(GROUP|$)/ { for (i=1;i<=NF;i++) if ($i == t || $i ~ "^" t "\\(") { print $1; break } }' | sort -u)
  [ -z "$active" ] || { echo "有 consumer 正在讀這個 topic:$(echo "$active" | tr '\n' ' ');拒絕刪除"; return 1; }
  core_confirm "刪除 topic $t,資料不可復原" || return 1
  be_kafka kafka-topics --delete --topic "$t"
}
