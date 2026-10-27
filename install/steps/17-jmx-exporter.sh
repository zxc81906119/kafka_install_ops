#!/usr/bin/env bash
# 第 17 站：讓行內的 Prometheus 抓指標 —— 每個 Java 程序掛 JMX exporter（7071、HTTPS、basic auth），產出給銀行監控團隊的檔
# where: ops02 （cpadmin）
#
# 何時用：JMX_EXPORTER=1。jar 在第 1.4 站已帶進來。
# 做什麼：
#   17.1 抓取密碼（設定檔只存加鹽 SHA-256）、exporter 設定 = 標頭（HTTPS、帳密）+ 規則（要抓哪些 MBean）
#   17.2 jar 與設定派送到 controller／broker／REST，drop-in 把 -javaagent 加進 KAFKA_OPTS／KAFKAREST_OPTS
#   17.3 滾動重啟；匿名要 401、帶帳密要看到指標
#   17.4 給銀行：scrape 設定、告警規則、根憑證、抓取密碼
# 注意：exporter 的 YAML 不支援 Secret Protection，keystore 密碼只能明文寫在裡面，所以檔案 0640 root:confluent。
# 重跑：安全（抓取密碼與鹽已存在就沿用）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"
if [ "$JMX_EXPORTER" != 1 ]; then log "JMX_EXPORTER=$JMX_EXPORTER：略過第 17 站"; exit 0; fi
EXPORTER_JAR=$(ls "$LANDING"/tools/jmx_prometheus_javaagent-*.jar 2>/dev/null | head -1)
[ -n "$EXPORTER_JAR" ] || die "$LANDING/tools 沒有 jmx_prometheus_javaagent jar（第 1.4 站）"
EXPORTER_JAR_NAME=$(basename "$EXPORTER_JAR")
SCRAPE_PASSWORD_FILE=$SECRETS_DIR/jmx-scrape.pass   # Prometheus 抓取用的密碼（給銀行一份）
SCRAPE_SALT_FILE=$SECRETS_DIR/jmx-scrape.salt       # 整個叢集共用一個鹽

section "17.1 抓取密碼與 exporter 設定的標頭"
install -d -m 0700 "$MONITORING_DIR"
(umask 077
 [ -s "$SCRAPE_PASSWORD_FILE" ] || openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SCRAPE_PASSWORD_FILE"
 [ -s "$SCRAPE_SALT_FILE" ] || openssl rand -hex 16 > "$SCRAPE_SALT_FILE")
export SALT HASH STORE_PASSWORD KS
SALT=$(cat "$SCRAPE_SALT_FILE")
# exporter 比對時算 sha256("<鹽>:<密碼>")，再用 Java 的 BigInteger.toString(16) 轉十六進位：開頭的 0 會被吃掉，
# 所以這裡也要去掉前導 0，否則雜湊剛好以 0 開頭時（機率 1/16）帳密永遠 401
HASH=$(printf '%s:%s' "$SALT" "$(cat "$SCRAPE_PASSWORD_FILE")" | sha256sum | cut -d' ' -f1 | sed 's/^0*//')
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
# 兩種標頭：controller 沒有 cp-server.p12，用 kafka-internal.p12；broker 與 REST 用 cp-server.p12
for KS in cp-server kafka-internal; do
  render_template "$TEMPLATE_DIR/jmx-header.yml" "$MONITORING_DIR/jmx-header-$KS.yml" KS STORE_PASSWORD HASH SALT || die "render jmx-header"
done
unset STORE_PASSWORD SALT HASH
ok "標頭 jmx-header-cp-server.yml、jmx-header-kafka-internal.yml；規則 kafka $(grep -c pattern "$TEMPLATE_DIR/jmx-rules-kafka.yml") 條、rest $(grep -c pattern "$TEMPLATE_DIR/jmx-rules-rest.yml") 條"

section "17.2 派送 jar 與設定、drop-in 掛上 javaagent（7071 在第 7 站已開）"
for host in $KAFKA_HOSTS $RESTS; do
  case $host in
    kc*)   keystore=kafka-internal; rules=jmx-rules-kafka; config_path=/etc/confluent/kafka/jmx-exporter.yml;      opts_var=KAFKA_OPTS;;
    kb*)   keystore=cp-server;      rules=jmx-rules-kafka; config_path=/etc/confluent/kafka/jmx-exporter.yml;      opts_var=KAFKA_OPTS;;
    rest*) keystore=cp-server;      rules=jmx-rules-rest;  config_path=/etc/confluent/kafka-rest/jmx-exporter.yml; opts_var=KAFKAREST_OPTS;;
  esac
  (umask 077; cat "$MONITORING_DIR/jmx-header-$keystore.yml" "$TEMPLATE_DIR/$rules.yml" > "$MONITORING_DIR/jmx-$host.yml")
  # 落地區的檔是唯讀的，scp 會把唯讀帶過去；上次失敗留下的檔會擋住這次 scp，先刪
  ssh_run "$host" "rm -f /tmp/$EXPORTER_JAR_NAME /tmp/jmx-$host.yml" >/dev/null 2>&1
  copy_to_tmp "$host" "$EXPORTER_JAR" "$MONITORING_DIR/jmx-$host.yml" || { fail "$host: scp"; continue; }
  result=$(ssh_script "$host" HOST="$host" JAR="$EXPORTER_JAR_NAME" CONFIG="$config_path" UNIT="$(unit_of "$host")" OPTS_VAR="$opts_var" <<'EOF'
sudo install -d -m 0755 /opt/jmx-exporter
sudo install -m 0644 /tmp/$JAR /opt/jmx-exporter/$JAR
sudo install -o root -g confluent -m 0640 /tmp/jmx-$HOST.yml "$CONFIG"
rm -f /tmp/$JAR /tmp/jmx-$HOST.yml
printf '[Service]\nEnvironment="%s=-javaagent:/opt/jmx-exporter/%s=7071:%s"\n' "$OPTS_VAR" "$JAR" "$CONFIG" \
  | sudo tee /etc/systemd/system/$UNIT.service.d/40-jmx.conf >/dev/null
sudo systemctl daemon-reload
agent=$(systemctl show $UNIT -p Environment --value | tr ' ' '\n' | grep -o 'javaagent:[^ =]*' | head -1)
echo "$agent $(sudo wc -l < "$CONFIG") lines"
EOF
)
  case $result in "javaagent:/opt/jmx-exporter/$EXPORTER_JAR_NAME"*) ok "$host: $result";; *) fail "$host: $result";; esac
done
[ "$FAIL_COUNT" = 0 ] || die "派送失敗，不重啟"

section "17.3 滾動重啟、驗證端點（匿名 401、帶帳密看得到指標；憑證鏈用銀行根憑證驗，不用 -k）"
rolling_restart controllers brokers rests || die "滾動重啟有主機沒健康"
for host in $KAFKA_HOSTS $RESTS; do
  metrics_url=https://$(fqdn "$host"):7071/metrics
  anonymous_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$BANK_ROOT_CA" "$metrics_url")
  metric_count=$(curl -s --max-time 20 --cacert "$BANK_ROOT_CA" -u "prometheus:$(cat "$SCRAPE_PASSWORD_FILE")" "$metrics_url" | grep -cE '^(kafka_|jvm_)')
  if [ "$anonymous_code" = 401 ] && [ "$metric_count" -gt 100 ]; then ok "$host 匿名=$anonymous_code 指標=$metric_count"
  else fail "$host 匿名=$anonymous_code 指標=$metric_count"; fi
done

section "17.4 給銀行監控團隊的檔"
export CONTROLLER_TARGETS BROKER_TARGETS REST_TARGETS
# scrape 設定的 targets 寫法："kc01.poc.lab:7071", "kc02.poc.lab:7071"
quoted_targets() { local host; for host in "$@"; do printf '"%s:7071", ' "$(fqdn "$host")"; done | sed 's/, $//'; }
CONTROLLER_TARGETS=$(quoted_targets $CONTROLLERS)
BROKER_TARGETS=$(quoted_targets $BROKERS)
REST_TARGETS=$(quoted_targets $RESTS)
render_template "$TEMPLATE_DIR/prometheus-scrape.yml" "$MONITORING_DIR/prometheus-scrape.yml" CONTROLLER_TARGETS BROKER_TARGETS REST_TARGETS || die "render scrape"
cp "$TEMPLATE_DIR/alert-rules.yml" "$MONITORING_DIR/alert-rules.yml"
cp "$BANK_ROOT_CA" "$MONITORING_DIR/ca.pem"
(umask 077; cp "$SCRAPE_PASSWORD_FILE" "$MONITORING_DIR/scrape.pass")
chmod 0644 "$MONITORING_DIR/prometheus-scrape.yml" "$MONITORING_DIR/alert-rules.yml" "$MONITORING_DIR/ca.pem"
target_count=$(wc -w <<<"$KAFKA_HOSTS $RESTS")
ok "給銀行：$MONITORING_DIR/ 的 prometheus-scrape.yml、alert-rules.yml（$(grep -c 'alert:' "$MONITORING_DIR/alert-rules.yml") 條）、ca.pem、scrape.pass"
ask_bank "監控團隊：prometheus-scrape.yml 併入 scrape_configs；alert-rules.yml、ca.pem、scrape.pass（0600）放 /etc/prometheus/confluent/；確認 $target_count 個 target 都是 up。" \
         "    consumer lag 不是 broker 的 JMX 指標，要看 C3 或另接 lag exporter。"
finish_step
