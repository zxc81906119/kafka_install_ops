# 項目 10：查看 leader 與 partition 分布（balance report）
#
# 做什麼：統計每台 broker 當了幾個 partition 的 leader、放了幾份 replica，看負載有沒有偏到某幾台。
#   只會統計你有權限看到的 topic。
# 用到的設定：沒有
# 用到的共用函式：
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
# 改的時候要注意：
#   - 統計與印表都在下面的 _item10_table（awk），輸入是 kafka-topics --describe 的 Partition 那幾行。

run_10() {
  local partitions

  # 1. 讀所有 partition 的分布（每個 partition 一行）
  partitions=$(be_kafka kafka-topics --describe | grep 'Partition:')

  if [ -z "$partitions" ]; then
    echo "沒有讀到 partition(沒有權限或沒有 topic)"
    return 1
  fi

  # 2. 依 broker 統計並印成表
  echo "$partitions" | _item10_table
}

# _item10_table：讀 kafka-topics --describe 的 Partition 行，依 broker 統計後印表
#
# 輸入（一個 partition 一行），例如：
#   Topic: orders.events  Partition: 0  Leader: 102  Replicas: 102,103,104  Isr: 102,103,104
# 輸出，例如：
#   partition 總數 90,broker 4 台
#   broker id    leader  replica  非preferred  leader偏離
#   101              23       68            0         2%
#   ...
#   - leader     這台目前是幾個 partition 的 leader
#   - replica    這台上面放了幾份 replica
#   - 非preferred  這台是 preferred leader（Replicas 清單的第一台），但目前 leader 在別台的 partition 數
#   - leader偏離  這台的 leader 數，比平均多（+）或少（-）幾 %
_item10_table() {
  awk '
    # 每一行（一個 partition）：找出 Leader 與 Replicas 欄位的值，累加到各 broker
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "Leader:")   leader   = $(i + 1)
        if ($i == "Replicas:") replicas = $(i + 1)
      }

      partitions++
      lead[leader]++
      brokers[leader] = 1

      n = split(replicas, r, ",")
      for (j = 1; j <= n; j++) {
        rep[r[j]]++
        brokers[r[j]] = 1
      }

      # Replicas 的第一台是 preferred leader；目前 leader 不是它，就記一筆
      if (r[1] != leader) not_preferred[r[1]]++
    }

    # 全部讀完：算平均、把 broker id 由小到大排好，再一台一行印出來
    END {
      count = 0
      for (b in brokers) {
        count++
        total_lead += lead[b]
        ids[count] = b
      }

      for (x = 1; x <= count; x++) {
        for (y = x + 1; y <= count; y++) {
          if (ids[y] + 0 < ids[x] + 0) { t = ids[x]; ids[x] = ids[y]; ids[y] = t }
        }
      }

      printf "partition 總數 %d,broker %d 台\n", partitions, count
      printf "%-10s %8s %8s %12s %10s\n", "broker id", "leader", "replica", "非preferred", "leader偏離"

      average = total_lead / count
      for (x = 1; x <= count; x++) {
        b = ids[x]
        deviation = 0
        if (average > 0) deviation = (lead[b] - average) / average * 100
        printf "%-10s %8d %8d %12d %9.0f%%\n", b, lead[b], rep[b], not_preferred[b], deviation
      }

      printf "(非preferred = 這台是 preferred leader,但目前 leader 在別台;偏離 = leader 數相對平均的百分比)\n"
    }
  '
}
