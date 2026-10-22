item 13 1 n n "查看 consumer lag" "直接按 Enter 查全部(只會看到你有權限的);或輸入名稱 prefix、完整名稱"
run() {
  local g="${1:-}"; [ -n "$g" ] || [ $# -ge 1 ] || read -r -p "consumer group(空 = 全部;可輸入 prefix): " g
  [ -z "$g" ] || v_group "$g" || return 1
  local args=()
  if [ -z "$g" ]; then args=(--all-groups)
  else
    local list; list=$(be_kafka kafka-consumer-groups --list 2>/dev/null | grep -v '^_' | grep "^${g//./\.}")
    [ -n "$list" ] || { echo "沒有名稱以 $g 開頭的 consumer group(或你沒有權限)"; return 1; }
    local x; for x in $list; do args+=(--group "$x"); done
  fi
  be_kafka kafka-consumer-groups --describe "${args[@]}" | awk '
    $1=="GROUP" { next }
    NF>=6 && $6 ~ /^[0-9-]+$/ { printf "1\t%-30s %-30s %4s  lag %s\n", $1, $2, $3, $6; if ($6 ~ /^[0-9]+$/) tot[$1]+=$6; else tot[$1]+=0 }
    END { for (g in tot) printf "2\t== %-30s 合計 lag %d\n", g, tot[g] }' | sort | cut -f2-
}
