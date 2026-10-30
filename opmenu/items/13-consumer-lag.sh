item 13 1 n n "查看 consumer group(lag 與成員數)" "每個 partition 的 lag,每個 group 的合計 lag 與在線成員數(0 = 應用程式沒在跑);直接按 Enter 查全部(只會看到你有權限的),或輸入名稱 prefix、完整名稱"
run() {
  local g="${1:-}"; [ -n "$g" ] || [ $# -ge 1 ] || read -r -p "consumer group(空 = 全部;可輸入 prefix): " g
  [ -z "$g" ] || v_group "$g" || return 1
  local args=() list x
  if [ -z "$g" ]; then   # 全部:平台內部的 group(OPMENU_INTERNAL_GROUP_PATTERN)不列,免得遙測 group 的 lag 被看成應用程式落後
    list=$(be_kafka kafka-consumer-groups --list 2>/dev/null | grep -vE "$OPMENU_INTERNAL_GROUP_PATTERN")
    [ -n "$list" ] || { echo "沒有應用程式的 consumer group(或你沒有權限)"; return 1; }
  else
    list=$(be_kafka kafka-consumer-groups --list 2>/dev/null | grep -v '^_' | grep "^${g//./\.}")
    [ -n "$list" ] || { echo "沒有名稱以 $g 開頭的 consumer group(或你沒有權限)"; return 1; }
  fi
  for x in $list; do args+=(--group "$x"); done
  # 兩次查詢接在一起給 awk:L = 各 partition 的 lag,M = 在線成員(第 3 欄 HOST 是 /IP)
  { be_kafka kafka-consumer-groups --describe "${args[@]}" | sed 's/^/L /'
    be_kafka kafka-consumer-groups --describe --members "${args[@]}" | sed 's/^/M /'; } | awk '
    $1=="L" && $2!="GROUP" && NF>=7 && $7 ~ /^[0-9-]+$/ { printf "1\t%-30s %-30s %4s  lag %s\n", $2, $3, $4, $7; seen[$2]=1; if ($7 ~ /^[0-9]+$/) tot[$2]+=$7 }
    $1=="M" && $2!="GROUP" && NF>=6 && $4 ~ /^\// { seen[$2]=1; mem[$2]++ }
    $1=="M" && /has no active members/ { if (match($0, /'"'"'[^'"'"']+'"'"'/)) seen[substr($0, RSTART+1, RLENGTH-2)]=1 }
    END { for (g in seen) printf "2\t== %-30s 合計 lag %d,在線成員 %d 個\n", g, tot[g], mem[g] }' | sort | cut -f2-
}
