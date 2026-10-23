#!/usr/bin/env bash
# 第 18 站：讓行內的 Prometheus 抓指標 —— 每個 Java 程序掛 JMX exporter javaagent（7071、HTTPS、basic auth），產出給銀行監控團隊的三個檔
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"; source "$D/lib/render.sh"
[ "$JMX_EXPORTER" = 1 ] || { log "JMX_EXPORTER=$JMX_EXPORTER：略過第 18 站"; exit 0; }
T=$D/templates; C=$PKI_DIR/certs; M=$HOME/monitoring; CA=/etc/pki/ca-trust/source/anchors/bank-root.pem
JAR=$(ls "$LANDING"/tools/jmx_prometheus_javaagent-*.jar 2>/dev/null | head -1); [ -n "$JAR" ] || die "$LANDING/tools 沒有 jmx_prometheus_javaagent jar（第 1.4 站）"; JARN=$(basename "$JAR")
REST_APPS=$(grep -v '^#' "$D/conf/apps.txt" | awk '$2=="cert"{print $1}' | paste -sd'|'); APP=${REST_APPS%%|*}

section "18.1 抓取密碼（只存加鹽 SHA-256）與設定檔（keystore 密碼只能明文寫在這個 YAML，所以 0640 root:confluent）"
install -d -m 0700 "$M"
(umask 077; [ -s "$SECRETS_DIR/jmx-scrape.pass" ] || openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS_DIR/jmx-scrape.pass"; [ -s "$SECRETS_DIR/jmx-scrape.salt" ] || openssl rand -hex 16 > "$SECRETS_DIR/jmx-scrape.salt")
export SALT; SALT=$(cat "$SECRETS_DIR/jmx-scrape.salt"); export HASH; HASH=$(printf '%s:%s' "$SALT" "$(cat "$SECRETS_DIR/jmx-scrape.pass")" | sha256sum | cut -d' ' -f1 | sed 's/^0*//')   # exporter 用 BigInteger.toString(16) 比對，前導 0 會被吃掉
export STORE_PASSWORD; STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
for ks in cp-server kafka-internal; do export KS=$ks; render "$T/jmx-header.yml" "$M/jmx-header-$ks.yml" KS STORE_PASSWORD HASH SALT || die "render jmx-header"; done
unset STORE_PASSWORD SALT HASH
ok "headers: jmx-header-cp-server.yml jmx-header-kafka-internal.yml；rules: kafka $(grep -c pattern "$T/jmx-rules-kafka.yml") patterns, rest $(grep -c pattern "$T/jmx-rules-rest.yml") patterns"

section "18.2 派送 jar 與設定、第四個 drop-in 把 -javaagent 放進 KAFKA_OPTS／KAFKAREST_OPTS（7071 在第 7 站已開）"
for h in $KAFKA_HOSTS $RESTS; do
  case $h in kc*) ks=kafka-internal; rules=jmx-rules-kafka; cfg=/etc/confluent/kafka/jmx-exporter.yml; u=confluent-server; var=KAFKA_OPTS;; kb*) ks=cp-server; rules=jmx-rules-kafka; cfg=/etc/confluent/kafka/jmx-exporter.yml; u=confluent-server; var=KAFKA_OPTS;; *) ks=cp-server; rules=jmx-rules-rest; cfg=/etc/confluent/kafka-rest/jmx-exporter.yml; u=confluent-kafka-rest; var=KAFKAREST_OPTS;; esac
  (umask 077; cat "$M/jmx-header-$ks.yml" "$T/$rules.yml" > "$M/jmx-$h.yml")
  rsh "$h" "rm -f /tmp/$JARN /tmp/jmx-$h.yml" >/dev/null 2>&1   # 上次失敗留下的唯讀檔會擋 scp
  rcp "$h" "$JAR" "$M/jmx-$h.yml" || { fail "$h: scp"; continue; }
  r=$(rsh "$h" "sudo install -d -m 0755 /opt/jmx-exporter && sudo install -m 0644 /tmp/$JARN /opt/jmx-exporter/$JARN && sudo install -o root -g confluent -m 0640 /tmp/jmx-$h.yml $cfg && rm -f /tmp/$JARN /tmp/jmx-$h.yml && printf '[Service]\nEnvironment=\"$var=-javaagent:/opt/jmx-exporter/$JARN=7071:$cfg\"\n' | sudo tee /etc/systemd/system/$u.service.d/40-jmx.conf >/dev/null && sudo systemctl daemon-reload && echo \"\$(systemctl show $u -p Environment --value | tr ' ' '\n' | grep -o 'javaagent:[^ =]*' | head -1) \$(sudo wc -l $cfg | cut -d' ' -f1) lines\"")
  [[ $r == javaagent:/opt/jmx-exporter/$JARN* ]] && ok "$h: $r" || fail "$h: $r"
done
[ "${FAILED:-0}" = 0 ] || die "派送失敗，不重啟"

section "18.3 滾動重啟、驗證端點（匿名 401、帶帳密有指標、憑證鏈用銀行根憑證驗）"
for h in $CONTROLLERS; do restart_wait "$h" confluent-server - | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
for h in $BROKERS; do restart_wait "$h" confluent-server "https://$(fqdn "$h"):8090/v1/metadata/id" | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
export RW_CURL_OPTS="--cert $C/$APP.crt --key $PKI_DIR/keys/$APP.key"
for h in $RESTS; do restart_wait "$h" confluent-kafka-rest "https://$(fqdn "$h"):8082/v3/clusters" | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
unset RW_CURL_OPTS
[ "${FAILED:-0}" = 0 ] || die "滾動重啟有主機沒健康"
for h in $KAFKA_HOSTS $RESTS; do
  u=https://$(fqdn "$h"):7071/metrics; a=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert $CA "$u"); m=$(curl -s --max-time 20 --cacert $CA -u "prometheus:$(cat "$SECRETS_DIR/jmx-scrape.pass")" "$u" | grep -cE '^(kafka_|jvm_)')
  [ "$a" = 401 ] && [ "$m" -gt 100 ] && ok "$h anon=$a metrics=$m" || fail "$h anon=$a metrics=$m"
done

section "18.4 給銀行監控團隊的檔：scrape 設定、告警規則、根憑證、抓取密碼（密碼另經保管庫交付）"
export CONTROLLER_TARGETS; CONTROLLER_TARGETS=$(for h in $CONTROLLERS; do printf '"%s:7071", ' "$(fqdn "$h")"; done | sed 's/, $//')
export BROKER_TARGETS; BROKER_TARGETS=$(for h in $BROKERS; do printf '"%s:7071", ' "$(fqdn "$h")"; done | sed 's/, $//')
export REST_TARGETS; REST_TARGETS=$(for h in $RESTS; do printf '"%s:7071", ' "$(fqdn "$h")"; done | sed 's/, $//')
render "$T/prometheus-scrape.yml" "$M/prometheus-scrape.yml" CONTROLLER_TARGETS BROKER_TARGETS REST_TARGETS || die "render scrape"
cp "$T/alert-rules.yml" "$M/alert-rules.yml" && cp $CA "$M/ca.pem" && (umask 077; cp "$SECRETS_DIR/jmx-scrape.pass" "$M/scrape.pass") && chmod 0644 "$M/prometheus-scrape.yml" "$M/alert-rules.yml" "$M/ca.pem"
ok "給銀行：$M/{prometheus-scrape.yml,alert-rules.yml,ca.pem,scrape.pass}（$(grep -c 'alert:' "$M/alert-rules.yml") 條規則、$(wc -w <<<"$KAFKA_HOSTS $RESTS") 個 target）"
bank "監控團隊：把 prometheus-scrape.yml 併入 scrape_configs、alert-rules.yml 與 ca.pem 放 /etc/prometheus/confluent/、scrape.pass（0600）同目錄；確認 $(wc -w <<<"$KAFKA_HOSTS $RESTS") 個 target 都 up。" \
     "    exporter 的 YAML 含 keystore 明文密碼（0640 root:confluent，不能放寬）；consumer lag 不是 broker JMX 指標，看 C3 或另接 lag exporter。"
finish
