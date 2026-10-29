#!/usr/bin/env bash
# mds-writer-ready.sh [最多等幾秒，預設 300]：等 MDS 的寫入者就緒才回 0（手把手第 11 章開頭）。
# 判斷依據是 MDS 自己寫在 _confluent-metadata-auth 的 Status 紀錄：每次 broker 進出，寫入者重選（generationId 加一），
# 先寫 INITIALIZING、就緒後寫 INITIALIZED。每個 partition 最新的 Status 都是 INITIALIZED、generationId 都一樣，才可以寫 role binding。
# 8090 回 200 不代表可以寫：寫入者換人的那幾秒，寫入會回 50003（not the current leader）。
# 用 kafka-internal 憑證讀（INTERNAL 9092，不經 MDS），印一行結果。結束碼：0 就緒、1 等不到。
max_wait=${1:-300}
export JAVA_HOME=${JAVA_HOME:-/opt/java/current} KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
bootstrap=${MDS_READY_BOOTSTRAP:-kb01.poc.lab:9092,kb02.poc.lab:9092,kb03.poc.lab:9092,kb04.poc.lab:9092}
client_conf=${MDS_READY_CLIENT_CONF:-/root/conf/client-internal.properties}
topic=_confluent-metadata-auth
status_lines() {   # 整個 topic 讀一次（5 秒沒有新資料就結束），每個 partition 取最新一筆 Status：印「partition 狀態 generation」
  timeout 60 kafka-console-consumer --bootstrap-server "$bootstrap" --command-config "$client_conf" --topic "$topic" --from-beginning \
    --timeout-ms 5000 --formatter-property print.partition=true 2>/dev/null |
    sed -nE 's/^Partition:([0-9]+).*"_type":"Status","status":"([A-Z_]*)","generationId":([0-9]*).*/\1 \2 \3/p' |
    awk '{last[$1] = $0} END {for (p in last) print last[p]}' | sort -n
}
started=$(date +%s)
while :; do
  lines=$(status_lines); total=$(grep -c . <<<"$lines"); ready=$(grep -c ' INITIALIZED ' <<<"$lines"); gens=$(awk '{print $3}' <<<"$lines" | sort -u | grep -c .)
  waited=$(( $(date +%s) - started ))
  if [ "$total" -gt 0 ] && [ "$ready" = "$total" ] && [ "$gens" = 1 ]; then
    echo "MDS 寫入者就緒：$ready / $total 個 partition INITIALIZED，generation $(awk 'NR==1{print $3}' <<<"$lines")（等了 ${waited} 秒）"; exit 0
  fi
  if [ "$waited" -ge "$max_wait" ]; then
    echo "MDS 寫入者等了 ${waited} 秒還沒就緒：$(tr '\n' ';' <<<"$lines")（看 /var/log/kafka/metadata-service.log，手把手 28.4）"; exit 1
  fi
  sleep 5
done
