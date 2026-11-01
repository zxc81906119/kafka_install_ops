# 項目 18：收集診斷資料
#
# 做什麼：把各主機最近的服務日誌、topic 與 consumer group 清單、磁碟用量打包成一個 .tgz，給二線或原廠用。
# 用到的設定（opmenu.conf）：
#   OPMENU_OUT_DIR           打包檔放哪裡
# 用到的共用函式：
#   be_collect_diag          ssh 到每台主機收服務日誌（lib/hosts.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
#   be_disk_usage            每台主機的磁碟用量（lib/hosts.sh）
# 改的時候要注意：
#   - 這是碰主機的項目：選單框架會先過主機權限閘門（OPMENU_HOST_ITEMS 有列 18）。
#   - 包裡不放密碼、私鑰、master key。

run_18() {
  # 1. 這次的暫存目錄：時間＋操作者，打包後刪掉
  local dir
  dir="$OPMENU_OUT_DIR/diag-$(date +%Y%m%d-%H%M%S)-$OP_USER"

  # 2. 各主機的服務日誌
  be_collect_diag "$dir"
  if [ $? -ne 0 ]; then
    return 1
  fi

  # 3. 叢集的 topic、consumer group 清單與磁碟用量
  be_kafka kafka-topics --describe > "$dir/topics.txt" 2>&1
  be_kafka kafka-consumer-groups --list > "$dir/consumer-groups.txt" 2>&1
  be_disk_usage > "$dir/disk.txt" 2>&1

  # 4. 打包，成功才刪暫存目錄
  if ! tar -C "$(dirname "$dir")" -czf "$dir.tgz" "$(basename "$dir")"; then
    echo "打包失敗:$dir"
    return 1
  fi

  rm -rf "$dir"
  echo "已打包:$dir.tgz($(du -h "$dir.tgz" | cut -f1))"
}
