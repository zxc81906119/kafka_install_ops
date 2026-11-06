# 項目 13：查看 consumer group（lag 與成員數）
#
# 做什麼：看每個 consumer group 落後多少（lag）、有幾個成員在線。
#   可以輸入 group 名稱的開頭（prefix）只看某些 group；空的 = 全部（平台內部的 group 不列）。
# 用到的設定（opmenu.conf）：
#   OPMENU_INTERNAL_GROUP_PATTERN   平台內部 group 的樣式（例如遙測、C3 用的），「全部」時不列
# 用到的共用函式：
#   v_group                  檢查 group 名稱只含允許的字元（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
# 改的時候要注意：
#   - lag 與成員數是兩次查詢合在一起算的，計算在下面的 _item13_table（awk）。
#   - --run 13 時：完全沒給參數才問；給空字串（--run 13 ""）代表全部。

run_13() {
  local group=""

  # 1. 要看哪些 group（完全沒給參數時才問）
  if [ $# -ge 1 ]; then
    group="$1"
  else
    read -r -p "consumer group(空 = 全部;可輸入 prefix): " group
  fi

  if [ -n "$group" ]; then
    if ! v_group "$group"; then
      return 1
    fi
  fi

  # 2. 列出符合的 group
  local all_groups name list=""
  all_groups=$(be_kafka kafka-consumer-groups --list 2>/dev/null)

  if [ -z "$group" ]; then
    # 全部：不列平台內部的 group，免得遙測 group 的 lag 被看成應用程式落後
    list=$(echo "$all_groups" | grep -vE "$OPMENU_INTERNAL_GROUP_PATTERN")
    if [ -z "$list" ]; then
      echo "沒有應用程式的 consumer group(或你沒有權限)"
      return 1
    fi
  else
    # 指定 prefix：名稱以它開頭、而且不是底線開頭的
    for name in $all_groups; do
      case "$name" in
        _*) continue ;;
      esac

      case "$name" in
        "$group"*) list="$list $name" ;;
      esac
    done

    if [ -z "$list" ]; then
      echo "沒有名稱以 $group 開頭的 consumer group(或你沒有權限)"
      return 1
    fi
  fi

  # 3. 組出 --group a --group b … 的參數
  local args=()
  for name in $list; do
    args+=(--group "$name")
  done

  # 4. 查兩次：L = 各 partition 的 lag，M = 在線成員；兩份輸出接在一起交給 _item13_table 算
  {
    be_kafka kafka-consumer-groups --describe "${args[@]}" | sed 's/^/L /'
    be_kafka kafka-consumer-groups --describe --members "${args[@]}" | sed 's/^/M /'
  } | _item13_table
}

# _item13_table：把兩次查詢的結果合起來，印每個 partition 的 lag，以及每個 group 的合計
#
# 輸入（每行前面加了 L 或 M），例如：
#   L orders-app  orders.events  0  1500  1520  20  consumer-1-...  /172.35.0.10  consumer-1
#   L GROUP  TOPIC  PARTITION ...                                          ← 表頭，略過
#   M orders-app  consumer-1-...  /172.35.0.10  consumer-1  1                ← 一個在線成員
#   M Consumer group 'idle-app' has no active members.                     ← 沒有成員的 group
# 輸出，例如：
#   orders-app                     orders.events                     0  lag 20
#   == orders-app                     合計 lag 20,在線成員 1 個
#   （先印所有 partition 的行，再印各 group 的合計）
_item13_table() {
  awk '
    # L 行：第 2 欄 group、第 3 欄 topic、第 4 欄 partition、第 7 欄 lag（數字，或沒有 commit 時是 -）
    # lint-ok: awk 的條件語法，不是 shell 串接
    $1 == "L" && $2 != "GROUP" && NF >= 7 && $7 ~ /^[0-9-]+$/ {
      printf "1\t%-30s %-30s %4s  lag %s\n", $2, $3, $4, $7
      seen[$2] = 1
      if ($7 ~ /^[0-9]+$/) total[$2] += $7
    }

    # M 行：第 4 欄是 /IP 的才是一個在線成員
    # lint-ok: awk 的條件語法，不是 shell 串接
    $1 == "M" && $2 != "GROUP" && NF >= 6 && $4 ~ /^\// {
      seen[$2] = 1
      members[$2]++
    }

    # 沒有成員的 group：名稱在單引號裡
    # lint-ok: awk 的條件語法，不是 shell 串接
    $1 == "M" && /has no active members/ {
      if (match($0, /'"'"'[^'"'"']+'"'"'/)) seen[substr($0, RSTART + 1, RLENGTH - 2)] = 1
    }

    # 每個 group 一行合計
    END {
      for (g in seen) printf "2\t== %-30s 合計 lag %d,在線成員 %d 個\n", g, total[g], members[g]
    }
  ' | sort | cut -f2-
}
