#!/usr/bin/env bash
# install/tools/load.sh —— 演練用的持續流量：升級、滾動重啟、換憑證時量「有沒有掉資料、REST 有沒有失敗」
# where: ops02 （root）
#
#   bash install/tools/load.sh start    背景開始送：SCRAM 應用程式直連（連號訊息、acks=all）＋ REST 應用程式經負載平衡（每秒一筆）
#   bash install/tools/load.sh stop     停止
#   bash install/tools/load.sh report   送出幾筆、讀回幾筆、缺哪幾號；REST 成功／失敗次數（要先 stop）
#
# 做什麼：連號的做法：每次 start 從 1 開始編號，report 只算這次 start 之後寫進去的（訊息時間戳），所以舊的訊息不會蓋掉遺失。
# 需要什麼：平台裝好（第 19 站之後），有 $FIRST_SCRAM_APP 的 client 設定（沒有就照同樣的寫法建一份）與 REST 應用程式的憑證。
# 產出什麼：狀態放在 ~/load/（每次 start 重來）。
# 能不能重跑：可以。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
export JAVA_HOME=/opt/java/current
export KAFKA_HEAP_OPTS=-Xmx256m
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

LOAD_DIR=$HOME/load
LOAD_TOPIC=orders.load                                 # app-orders 有 orders.* 的寫讀與建立權限
SCRAM_CLIENT_CONF=$CONF_DIR/$FIRST_SCRAM_APP.properties
REST_TOPIC=billing.events                              # app-legacy-billing 有 billing.* 的寫入權限
# shellcheck disable=SC2086  # BROKERS 是好幾台主機
CLIENT_BOOTSTRAP=$(host_port_list 9095 $BROKERS)
install -d -m 0700 "$LOAD_DIR"

# SCRAM 應用程式的連線設定：第 19、20 站做過就有；沒有就照同樣的寫法建一份
ensure_scram_client_conf() {
  local scram_password store_password

  if [ -f "$SCRAM_CLIENT_CONF" ]; then
    return 0
  fi

  scram_password=$(cat "$SECRETS_DIR/$FIRST_SCRAM_ACCOUNT.pass")
  store_password=$(cat "$PKI_DIR/store.pass")
  install -m 0600 /dev/null "$SCRAM_CLIENT_CONF"
  cat > "$SCRAM_CLIENT_CONF" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$FIRST_SCRAM_ACCOUNT" password="$scram_password";
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$store_password
EOF
}

start_load() {
  # 1. 連線設定、topic
  ensure_scram_client_conf
  kafka-topics --bootstrap-server "$CLIENT_BOOTSTRAP" --command-config "$SCRAM_CLIENT_CONF" --create --if-not-exists \
    --topic "$LOAD_TOPIC" --partitions 6 --replication-factor 3 --config min.insync.replicas=2 > /dev/null 2>&1

  # 2. 狀態歸零
  : > "$LOAD_DIR/produced.seq"
  : > "$LOAD_DIR/rest.log"
  date +%s%3N > "$LOAD_DIR/start.ms"
  touch "$LOAD_DIR/running"

  # 3. 直連：每 0.2 秒一個連號；producer 開冪等、無限重試，broker 輪流重啟時應該一筆都不掉
  (
    sequence=0

    while [ -f "$LOAD_DIR/running" ]; do
      sequence=$((sequence + 1))
      echo "$sequence"
      echo "$sequence" >> "$LOAD_DIR/produced.seq"
      sleep 0.2
    done | kafka-console-producer \
      --bootstrap-server "$CLIENT_BOOTSTRAP" \
      --producer.config "$SCRAM_CLIENT_CONF" \
      --topic "$LOAD_TOPIC" \
      --producer-property acks=all \
      --producer-property enable.idempotence=true \
      --producer-property delivery.timeout.ms=300000 \
      --producer-property retries=2147483647 > "$LOAD_DIR/producer.log" 2>&1
  ) < /dev/null > /dev/null 2>&1 &
  echo $! > "$LOAD_DIR/producer.pid"

  # 4. 經負載平衡的 REST：每秒一筆，記下 HTTP 狀態碼（沒有回應記 000）
  (
    source "$CONF_DIR/kraft.env"   # CLUSTER_ID

    while [ -f "$LOAD_DIR/running" ]; do
      http_code=$(rest_app_curl -s -o /dev/null -m 10 -w '%{http_code}' \
        --cacert "$BANK_ROOT_CA" \
        -X POST \
        -H 'Content-Type: application/json' \
        -d '{"value":{"type":"JSON","data":{"src":"load"}}}' \
        "https://$REST_VIP:8082/v3/clusters/$CLUSTER_ID/topics/$REST_TOPIC/records")
      echo "$(date +%T) $http_code" >> "$LOAD_DIR/rest.log"
      sleep 1
    done
  ) < /dev/null > /dev/null 2>&1 &
  echo $! > "$LOAD_DIR/rest.pid"

  echo "持續流量開始：直連 → $LOAD_TOPIC，REST → $REST_TOPIC"
}

stop_load() {
  local process

  # 1. 讓兩個迴圈自己結束
  rm -f "$LOAD_DIR/running"
  sleep 3

  # 2. 還在的就收掉
  for process in producer rest; do
    if [ -f "$LOAD_DIR/$process.pid" ]; then
      kill "$(cat "$LOAD_DIR/$process.pid")" 2> /dev/null
    fi
  done

  pkill -u "$(id -un)" -f "kafka-console-producer.*$LOAD_TOPIC" 2> /dev/null
  echo "持續流量停止"
}

# since_start_numbers <start 的毫秒>：讀 stdin 的 console-consumer 輸出，只留 start 之後寫進去的編號
#   輸入：CreateTime:1761700000000<TAB>123 → 輸出：123
since_start_numbers() {
  # lint-ok: 要比較時間數字，grep 做不到；輸入輸出例子寫在函式上面
  awk -F'\t' -v since="$1" '
    {
      created = $1
      sub(/^CreateTime:/, "", created)
    }
    created >= since && $2 ~ /^[0-9]+$/ { # lint-ok: awk 語法
      print $2
    }
  '
}

report_load() {
  local since produced consumed missing rest_ok rest_failed

  if [ -f "$LOAD_DIR/running" ]; then
    echo "先 stop（report 會讀到 topic 30 秒沒有新訊息為止）"
    exit 1
  fi

  since=$(cat "$LOAD_DIR/start.ms" 2> /dev/null)
  since=${since:-0}

  # 1. 只算這次 start 之後寫進去的（CreateTime ≥ start），編號去重後和送出的比
  kafka-console-consumer \
    --bootstrap-server "$CLIENT_BOOTSTRAP" \
    --consumer.config "$SCRAM_CLIENT_CONF" \
    --topic "$LOAD_TOPIC" \
    --group "orders-load-report-$$" \
    --from-beginning \
    --timeout-ms 30000 \
    --property print.timestamp=true 2> /dev/null \
    | since_start_numbers "$since" \
    | sort -n -u > "$LOAD_DIR/consumed.seq"

  # 2. 兩邊都照字串排序才能給 comm 比；送出了卻沒讀回的就是遺失
  sort -u "$LOAD_DIR/produced.seq" > "$LOAD_DIR/produced.sorted"
  sort -u "$LOAD_DIR/consumed.seq" > "$LOAD_DIR/consumed.sorted"
  produced=$(wc -l < "$LOAD_DIR/produced.seq")
  consumed=$(wc -l < "$LOAD_DIR/consumed.seq")
  missing=$(comm -23 "$LOAD_DIR/produced.sorted" "$LOAD_DIR/consumed.sorted" | wc -l)

  # 3. REST：rest.log 一行是「時間 HTTP 碼」
  rest_ok=$(awk '$2 == "200" {c++} END {print c + 0}' "$LOAD_DIR/rest.log")
  rest_failed=$(awk '$2 != "200" {c++} END {print c + 0}' "$LOAD_DIR/rest.log")

  # 4. 結果
  echo "直連（SCRAM）：送出 $produced 筆、讀回 $consumed 筆、遺失 $missing 筆（自 $(date -d "@$((since / 1000))" +%T) 起）"
  echo "REST（經負載平衡）：成功 $rest_ok 次、失敗 $rest_failed 次"

  if [ "$rest_failed" -gt 0 ]; then
    # lint-ok: 第 2 欄不是 200 的行，取前 5 行
    awk '$2 != "200"' "$LOAD_DIR/rest.log" | head -5
  fi

  return 0
}

case ${1:-} in
  start)
    start_load
    ;;
  stop)
    stop_load
    ;;
  report)
    report_load
    ;;
  *)
    echo "用法：$0 start|stop|report"
    exit 2
    ;;
esac
