#!/usr/bin/env bash
# Continuous traffic for upgrade / failover drills (run on the ops host as cpadmin).
#   tools/load.sh start   background producers: SCRAM (numbered, acks=all) + REST v3 via the LB
#   tools/load.sh stop
#   tools/load.sh report  produced vs. consumed (gaps = lost messages), REST success / failure counts
set -Eeuo pipefail
STATE=/var/lib/cp-installer
DIR=$STATE/load
PKI=$STATE/pki
TOPIC=orders.load
BOOT=kb01.poc.lab:9095,kb02.poc.lab:9095,kb03.poc.lab:9095,kb04.poc.lab:9095
CFG=$STATE/client/app-orders-scram.properties
# Kafka tools from whichever install strategy is present on the ops host (tar first, then RPM)
if [[ -x /opt/confluent/current/bin/kafka-topics ]]; then
  export PATH=/opt/confluent/current/bin:$PATH JAVA_HOME=/opt/java/current
  KAFKA_ETC=/opt/confluent/current/etc/kafka
else
  KAFKA_ETC=/etc/kafka
fi
export KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=$KAFKA_ETC/tools-log4j2.yaml
mkdir -p "$DIR"

start() {
  [[ -f $CFG ]] || { echo "run 'cpctl verify' once first (creates $CFG)"; exit 1; }
  kafka-topics --bootstrap-server "${BOOT%%,*}" --command-config "$CFG" --create --if-not-exists \
    --topic "$TOPIC" --partitions 6 --replication-factor 3 --config min.insync.replicas=2 >/dev/null 2>&1 || true
  : >"$DIR/produced.seq"
  : >"$DIR/rest.log"   # per run: the report must not count earlier runs (or a torn write from an unclean shutdown)
  (
    i=0
    while [[ -f $DIR/running ]]; do
      i=$((i + 1)); printf '%s\n' "$i"; printf '%s\n' "$i" >>"$DIR/produced.seq"; sleep 0.2
    done | kafka-console-producer --bootstrap-server "$BOOT" --producer.config "$CFG" --topic "$TOPIC" \
      --producer-property acks=all --producer-property enable.idempotence=true \
      --producer-property delivery.timeout.ms=300000 --producer-property retries=2147483647 \
      >"$DIR/producer.log" 2>&1
  ) &
  echo $! >"$DIR/producer.pid"
  (
    . "$STATE/kraft.env"
    while [[ -f $DIR/running ]]; do
      code=$(curl -s -m 10 --cacert "$PKI/ca.pem" --cert "$PKI/app-legacy-billing.crt" --key "$PKI/app-legacy-billing.key" \
        -X POST -H 'Content-Type: application/json' -d '{"value":{"type":"JSON","data":{"src":"rest-load"}}}' \
        "https://rest.poc.lab:8082/v3/clusters/$CLUSTER_ID/topics/billing.events/records" | grep -o '"error_code":[0-9]*' | cut -d: -f2)
      printf '%s %s\n' "$(date +%T)" "${code:-noresponse}" >>"$DIR/rest.log"
      sleep 1
    done
  ) &
  echo $! >"$DIR/rest.pid"
  echo "load started (topic $TOPIC)"
}

stop() {
  rm -f "$DIR/running"
  sleep 3
  local p
  for p in producer rest; do [[ -f $DIR/$p.pid ]] && kill "$(cat "$DIR/$p.pid")" 2>/dev/null || true; done
  echo "load stopped"
}

report() {
  local produced consumed missing
  produced=$(wc -l <"$DIR/produced.seq")
  kafka-console-consumer --bootstrap-server "$BOOT" --consumer.config "$CFG" --topic "$TOPIC" \
    --group "orders-load-report-$$" --from-beginning --timeout-ms 30000 2>/dev/null | grep -E '^[0-9]+$' | sort -n -u >"$DIR/consumed.seq" || true
  consumed=$(wc -l <"$DIR/consumed.seq")
  missing=$(comm -23 <(sort -u "$DIR/produced.seq") <(sort -u "$DIR/consumed.seq") | wc -l)
  printf 'SCRAM producer : %s produced, %s consumed, %s missing\n' "$produced" "$consumed" "$missing"
  printf 'REST v3 via LB : %s ok, %s failed\n' "$(grep -c ' 200$' "$DIR/rest.log" || true)" "$(grep -vc ' 200$' "$DIR/rest.log" || true)"
  grep -v ' 200$' "$DIR/rest.log" | head -5 || true
}

case ${1:-} in
  start) touch "$DIR/running"; start ;;
  stop) stop ;;
  report) report ;;
  *) echo "usage: $0 start|stop|report"; exit 2 ;;
esac
