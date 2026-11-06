# 項目 36：重設 consumer group 的讀取位置（offset）
#
# 做什麼：把一個 consumer group 的讀取位置移到最前面（earliest）、最後面（latest）或某個時間點。
#   group 還有成員在線時拒絕；先預覽（--dry-run）給操作者看，確認後才真的執行。
# 用到的設定：沒有
# 用到的共用函式：
#   v_group                  檢查 group 名稱只含允許的字元（lib/common.sh）
#   v_offset_to              檢查重設位置的格式（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
# 改的時候要注意：
#   - 應用程式要先停：成員在線時重設不會生效，Kafka 也會拒絕。

run_36() {
  local group="${1:-}"
  local reset_to="${2:-}"

  # 1. 問 group 與要重設到哪裡
  if [ -z "$group" ]; then
    read -r -p "consumer group: " group
  fi

  if [ -z "$reset_to" ]; then
    read -r -p "重設到(earliest | latest | 2026-01-31T00:00:00.000): " reset_to
  fi

  if ! v_group "$group"; then
    return 1
  fi

  if ! v_offset_to "$reset_to"; then
    return 1
  fi

  # 2. 換成指令的參數（時間點要兩個參數：--to-datetime 和時間，所以用陣列）
  local position=()
  case "$reset_to" in
    earliest) position=(--to-earliest) ;;
    latest)   position=(--to-latest) ;;
    *)        position=(--to-datetime "$reset_to") ;;
  esac

  # 3. 還有成員在線就拒絕（成員那一行的第 3 欄是 /IP）
  if be_kafka kafka-consumer-groups --describe --group "$group" --members 2>/dev/null \
      | grep -q -E '^[^ ]+ +[^ ]+ +/'; then
    echo "consumer group $group 仍有成員在線,拒絕重設(先停止 application)"
    return 1
  fi

  # 4. 先預覽（不會改任何東西）
  echo "-- 預覽(不會執行):"

  be_kafka kafka-consumer-groups --reset-offsets --group "$group" --all-topics "${position[@]}" --dry-run
  if [ $? -ne 0 ]; then
    return 1
  fi

  # 5. 確認後執行
  if ! core_confirm "重設 $group 的讀取位置到 $reset_to"; then
    return 1
  fi

  be_kafka kafka-consumer-groups --reset-offsets --group "$group" --all-topics "${position[@]}" --execute
}
