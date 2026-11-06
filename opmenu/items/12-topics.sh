# 項目 12：列出 topic 與 partition 狀態
#
# 做什麼：列出你有權限的 topic，以及每個 partition 的 leader、replica、ISR。
#   平台內部的 topic（底線開頭）不列。
# 用到的設定：沒有
# 用到的共用函式：
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
# 改的時候要注意：
#   - 先 --list（只會回你有權限的），再一個一個 describe。
#     直接 --describe 全部的話，只要有一個 topic 沒權限，整個指令就失敗。

run_12() {
  # 1. 列出你看得到的 topic，去掉底線開頭的內部 topic
  local all_topics topics

  all_topics=$(be_kafka kafka-topics --list 2>/dev/null)
  if [ $? -ne 0 ]; then
    echo "無法列出 topic(權限不足或連不上叢集)"
    return 1
  fi

  topics=$(echo "$all_topics" | grep -v '^_')
  if [ -z "$topics" ]; then
    echo "沒有你有權限的 topic"
    return 1
  fi

  # 2. 一個一個 describe：有 DescribeConfigs 權限就印明細，沒有就印一行說明
  local topic detail shown_any=no

  for topic in $topics; do
    detail=$(be_kafka kafka-topics --describe --topic "$topic" 2>/dev/null)

    if [ $? -eq 0 ]; then
      echo "$detail" | grep -E '^Topic:|Partition:' | sed -E 's/[[:space:]]+/ /g'
      shown_any=yes
    else
      echo "Topic: $topic  (看得到名稱,但沒有 DescribeConfigs 權限,無法顯示明細)"
    fi
  done

  # 3. 一個明細都沒印出來，就算失敗
  if [ "$shown_any" = no ]; then
    return 1
  fi

  return 0
}
