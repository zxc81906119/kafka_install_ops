run_12() { # 先 --list(只回你有權限的),再逐一 describe:直接 --describe 全部時,只要有一個沒權限整個指令就失敗
  local list t out ok=0; list=$(be_kafka kafka-topics --list 2>/dev/null | grep -v '^_') || return $?
  [ -n "$list" ] || { echo "沒有你有權限的 topic"; return 1; }
  for t in $list; do
    if out=$(be_kafka kafka-topics --describe --topic "$t" 2>/dev/null); then printf '%s\n' "$out" | grep -E "^Topic:|Partition:" | sed -E 's/[[:space:]]+/ /g'; ok=1
    else echo "Topic: $t  (看得到名稱,但沒有 DescribeConfigs 權限,無法顯示明細)"; fi
  done
  [ $ok = 1 ]
}
