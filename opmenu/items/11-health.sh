# 項目 11：cluster 與身分鏈健康檢查
#
# 做什麼：一次看完叢集健不健康：
#   under-replicated／offline partition、在線的 broker、每台 MDS 回不回應、自己的 MDS token 還剩多久、controller quorum。
# 用到的設定（opmenu.conf）：
#   OPMENU_MDS_URL           MDS 位址，多台用逗號隔開
#   OPMENU_BROKER_SERVICES   設定的 broker 清單（用來算「應該有幾台」）
#   OPMENU_TOKEN_TTL         MDS token 的有效秒數
# 用到的共用函式：
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
#   be_http                  用 curl 連 HTTPS（帶銀行根憑證）（lib/kafka.sh）
# 改的時候要注意：
#   - 前兩項（under-replicated、offline）指令失敗就整個項目算失敗；後面幾項失敗只印出來，不中斷。
#   - controller quorum 要 ClusterAdmin，沒權限時印「略過」，不算失敗。

run_11() {
  # 1. under-replicated partition（應為空）
  echo "-- under-replicated partition(應為空):"
  be_kafka kafka-topics --describe --under-replicated-partitions
  if [ $? -ne 0 ]; then
    return 1
  fi

  # 2. offline partition（應為空）
  echo "-- offline partition(應為空):"
  be_kafka kafka-topics --describe --unavailable-partitions
  if [ $? -ne 0 ]; then
    return 1
  fi

  # 3. 在線的 broker（每台一行：主機:埠 (id: 編號）
  echo "-- broker 在線清單:"
  be_kafka kafka-broker-api-versions 2>&1 | grep -o -E '^[a-zA-Z0-9.-]+:[0-9]+ \(id: [0-9]+' | sort -u

  # 4. MDS：逐台問 /v1/metadata/id，200 就是正常
  echo "-- MDS(OPMENU_MDS_URL,逐台):"
  local url result code seconds
  for url in $(echo "$OPMENU_MDS_URL" | tr ',' ' '); do
    result=$(be_http -o /dev/null -w '%{http_code} %{time_total}' "$url/v1/metadata/id" 2>/dev/null)
    if [ $? -ne 0 ]; then
      result="連不上"
    fi

    code=$(echo "$result" | cut -d' ' -f1)
    seconds=$(echo "$result" | cut -d' ' -f2)
    if [ "$code" = 200 ]; then
      printf '  %-40s %s\n' "$url" "正常(${seconds}s)"
    else
      printf '  %-40s %s\n' "$url" "異常($result)"
    fi
  done

  # 5. 自己的 MDS token 用了多久、還剩多久
  local now used remaining
  now=$(date +%s)
  used=$(( now - ${OP_TOKEN_AT:-$now} ))
  remaining=$(( ${OPMENU_TOKEN_TTL:-3600} - used ))

  if [ "$remaining" -gt 0 ]; then
    echo "-- 你的 MDS token:已用 ${used}s,剩約 ${remaining}s"
  else
    echo "-- 你的 MDS token:已用 ${used}s,剩約 0s(已到期,請重新登入)"
  fi

  # 6. 在線的 broker 數，和設定的 broker 數比
  local expected live
  expected=$(echo $OPMENU_BROKER_SERVICES | wc -w)
  live=$(be_kafka kafka-broker-api-versions 2>/dev/null | grep -c '^[A-Za-z0-9._-]*:[0-9]* (id: ')

  if [ "$live" -lt "$expected" ]; then
    echo "-- broker 在線:$live / $expected(設定的 broker 數)  ← 有 broker 不在線"
  else
    echo "-- broker 在線:$live / $expected(設定的 broker 數)"
  fi

  # 7. controller quorum（要 ClusterAdmin；沒權限就略過）
  echo "-- controller quorum(需要 ClusterAdmin):"
  local quorum
  quorum=$(be_kafka kafka-metadata-quorum describe --status 2>&1)

  if echo "$quorum" | grep -q -i 'AuthorizationException'; then
    echo "  (沒有權限,略過)"
  else
    echo "$quorum" | grep -E 'LeaderId|CurrentVoters|HighWatermark' | sed 's/^/  /'
  fi

  # 8. AD：登入時已經驗證過
  echo "-- AD:登入時已通過 MDS 驗證,代表當時 MDS 到 AD 這段可用;之後若要重新確認請重新登入"
}
