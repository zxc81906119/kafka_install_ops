# 項目 33：刪除 topic
#
# 做什麼：刪除一個 topic。有 consumer 正在讀它時拒絕；受保護的 topic（內部、稽核用）不處理。
# 用到的設定（opmenu.conf）：
#   OPMENU_TOPIC_PATTERN、OPMENU_PROTECTED_TOPIC_PATTERN   命名規範與受保護的 topic
# 用到的共用函式：
#   v_topic                  檢查 topic 名稱符合命名規範、不是受保護的 topic（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
# 改的時候要注意：
#   - 「有沒有人在讀」的檢查本身失敗（沒有 Group 的 Describe 權限、連不上叢集）時一律拒絕：
#     不能把查不到當成「沒有 consumer」，而刪掉還有人在讀的 topic。
#   - 找誰在讀的比對在下面的 _item33_readers（awk）：精確比對 topic 欄，不用子字串。

run_33() {
  local topic="${1:-}"

  # 1. 問要刪哪個 topic
  if [ -z "$topic" ]; then
    read -r -p "要刪除的 topic: " topic
  fi

  if ! v_topic "$topic"; then
    return 1
  fi

  # 2. 一次列出所有 group 的成員與它們訂閱的 topic
  local members
  members=$(be_kafka kafka-consumer-groups --describe --all-groups --members --verbose 2>/dev/null)

  if [ $? -ne 0 ]; then
    echo "無法檢查哪些 consumer group 在讀這個 topic(權限不足或連不上叢集),拒絕刪除"
    return 1
  fi

  # 3. 有人在讀就拒絕
  local readers
  readers=$(echo "$members" | _item33_readers "$topic")

  if [ -n "$readers" ]; then
    echo "有 consumer 正在讀這個 topic:$(echo "$readers" | tr '\n' ' ');拒絕刪除"
    return 1
  fi

  # 4. 確認後刪除
  if ! core_confirm "刪除 topic $topic,資料不可復原"; then
    return 1
  fi

  be_kafka kafka-topics --delete --topic "$topic"
}

# _item33_readers <topic>：從「kafka-consumer-groups --describe --all-groups --members --verbose」的輸出，
#   找出有成員訂閱這個 topic 的 group 名稱，一行一個（不重複）
#
# 輸入（一個成員一行；最後一欄是它被分到的 topic 與 partition），例如：
#   GROUP        CONSUMER-ID   HOST          CLIENT-ID   #PARTITIONS  ASSIGNMENT
#   orders-app   consumer-1-…  /172.35.0.10  consumer-1  3            orders.events(0,1,2)
# 輸出，例如（找 orders.events 時）：
#   orders-app
_item33_readers() {
  awk -v topic="$1" '
    # 表頭與空行略過；其餘每一欄，等於 topic、或是「topic(」開頭的，就印出 group 名稱（第 1 欄）
    $1 !~ /^(GROUP|$)/ {
      for (i = 1; i <= NF; i++) {
        if ($i == topic || $i ~ "^" topic "\\(") {
          print $1
          break
        }
      }
    }
  ' | sort -u
}
