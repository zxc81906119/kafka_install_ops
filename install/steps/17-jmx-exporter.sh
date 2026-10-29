#!/usr/bin/env bash
# 第 17 站：監控 —— 每個 Java 程序（controller、broker、REST Proxy、C3）掛 JMX exporter（7071、HTTPS、basic auth），
#           並產出給銀行監控團隊（行內 Prometheus／Alertmanager／Grafana）的設定、告警規則、官方 dashboard
# where: ops02 （root）
#
# 何時用：JMX_EXPORTER=1。jar 與 Confluent 官方的規則檔（jmx-monitoring-stacks）在第 2.4 站已帶進 ~/landing。
# 做什麼：
#   17.1 抓取密碼（設定檔只存加鹽 SHA-256）、exporter 設定的標頭（HTTPS、帳密）
#   17.2 每台的 exporter 設定 = 標頭 + Confluent 官方規則（controller／broker／REST）或我們的小規則（C3）
#   17.3 jar 與設定派送、drop-in 把 -javaagent 加進 KAFKA_OPTS／KAFKAREST_OPTS／CONTROL_CENTER_OPTS
#   17.4 滾動重啟；匿名要 401、帶帳密要看到指標
#   17.5 給銀行：scrape 設定、告警規則、Alertmanager 設定（兩種 webhook 格式）、Grafana datasource 與 32 個官方 dashboard、根憑證、抓取密碼
# 不做：C3 內建的 Prometheus／Alertmanager 不動（C3 畫面還要用）；告警與 dashboard 只走行內那一套，不在 C3 建 alert trigger／action。
# 注意：exporter 的 YAML 不支援 Secret Protection，keystore 密碼只能明文寫在裡面，所以檔案 0640 root:confluent。
# 重跑：安全（抓取密碼與鹽已存在就沿用）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"
if [ "$JMX_EXPORTER" != 1 ]; then log "JMX_EXPORTER=$JMX_EXPORTER：略過第 17 站"; exit 0; fi
EXPORTER_JAR=$(ls "$LANDING"/tools/jmx_prometheus_javaagent-*.jar 2>/dev/null | head -1)
[ -n "$EXPORTER_JAR" ] || die "$LANDING/tools 沒有 jmx_prometheus_javaagent jar（第 2.4 站）"
EXPORTER_JAR_NAME=$(basename "$EXPORTER_JAR")
OFFICIAL=$LANDING/monitoring/jmx-monitoring-stacks     # Confluent 官方 jmx-monitoring-stacks（第 2.4 站，固定在一個 commit）
[ -s "$OFFICIAL/COMMIT" ] || die "$OFFICIAL 不存在：官方規則檔還沒帶進來（第 2.4 站）"
SCRAPE_PASSWORD_FILE=$SECRETS_DIR/jmx-scrape.pass   # Prometheus 抓取用的密碼（給銀行一份）
SCRAPE_SALT_FILE=$SECRETS_DIR/jmx-scrape.salt       # 整個叢集共用一個鹽

section "17.1 抓取密碼與 exporter 設定的標頭"
install -d -m 0700 "$MONITORING_DIR"
(umask 077
 [ -s "$SCRAPE_PASSWORD_FILE" ] || openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SCRAPE_PASSWORD_FILE"
 [ -s "$SCRAPE_SALT_FILE" ] || openssl rand -hex 16 > "$SCRAPE_SALT_FILE")
export SALT HASH KS
SALT=$(cat "$SCRAPE_SALT_FILE")
# exporter 比對時算 sha256("<鹽>:<密碼>")，再用 Java 的 BigInteger.toString(16) 轉十六進位：開頭的 0 會被吃掉，
# 所以這裡也要去掉前導 0，否則雜湊剛好以 0 開頭時（機率 1/16）帳密永遠 401
HASH=$(printf '%s:%s' "$SALT" "$(cat "$SCRAPE_PASSWORD_FILE")" | sha256sum | cut -d' ' -f1 | sed 's/^0*//')
# 兩種標頭：controller 沒有 cp-server.p12，用 kafka-internal.p12；broker、REST、C3 用 cp-server.p12
# keystore 密碼不寫進 YAML：寫 ${JMX_KEYSTORE_PASSWORD}（exporter 1.4 起支援），值在每台 /etc/confluent/jmx-exporter.env（root 0600），drop-in 用 EnvironmentFile 帶進去。
# 範本裡用佔位字串，渲染後才換成 ${…}（render_template 會把沒換掉的 ${…} 當錯誤）
for KS in cp-server kafka-internal; do
  render_template "$TEMPLATE_DIR/jmx-header.yml" "$MONITORING_DIR/jmx-header-$KS.yml" KS HASH SALT || die "render jmx-header"
  sed -i 's/@JMX_KEYSTORE_PASSWORD@/${JMX_KEYSTORE_PASSWORD}/' "$MONITORING_DIR/jmx-header-$KS.yml"
done
unset SALT HASH
(umask 077; printf 'JMX_KEYSTORE_PASSWORD=%s\n' "$(cat "$PKI_DIR/store.pass")" > "$MONITORING_DIR/jmx-exporter.env")
ok "標頭 jmx-header-cp-server.yml、jmx-header-kafka-internal.yml（keystore 密碼：$(grep -h 'password:' "$MONITORING_DIR"/jmx-header-*.yml | sort -u | sed 's/^ *//')）；jmx-exporter.env $(stat -c %a "$MONITORING_DIR/jmx-exporter.env")"

section "17.2 每台的 exporter 設定 = 標頭 + Confluent 官方規則（commit $(cut -c1-12 "$OFFICIAL/COMMIT")）"
OFFICIAL_RULES=$OFFICIAL/shared-assets/jmx-exporter
for role_spec in controller:kafka-internal:kafka_controller broker:cp-server:kafka_broker rest:cp-server:confluent_rest; do
  role=${role_spec%%:*}; rest_spec=${role_spec#*:}; keystore=${rest_spec%%:*}; official_rules=${rest_spec#*:}
  [ -s "$OFFICIAL_RULES/$official_rules.yml" ] || die "缺官方規則檔 $official_rules.yml"
  # 官方檔第一行是 YAML 的文件分隔線 ---，接在標頭後面會變成第二份文件，要去掉
  (umask 077; { cat "$MONITORING_DIR/jmx-header-$keystore.yml"; sed '1{/^---$/d}' "$OFFICIAL_RULES/$official_rules.yml"; } > "$MONITORING_DIR/jmx-$role.yml")
  log "$role：標頭 $keystore + 官方 $official_rules.yml → $(wc -l < "$MONITORING_DIR/jmx-$role.yml") 行"
done
# C3 沒有官方規則：我們的 rules-c3.yml（收 kafka.streams:* 與 Jetty；client-state 等帶 process-id 的 MBean 先自己命名）
# 後面接官方 kafka_streams.yml 的 rules（名稱和官方 Streams／RocksDB dashboard 對得上）；不收 C3 自己的 consumer／producer
[ -s "$OFFICIAL_RULES/kafka_streams.yml" ] || die "缺官方規則檔 kafka_streams.yml（第 2 章要帶進來）"
cp "$TEMPLATE_DIR/jmx-rules-c3.yml" "$MONITORING_DIR/rules-c3.yml"
(umask 077; { cat "$MONITORING_DIR/jmx-header-cp-server.yml" "$MONITORING_DIR/rules-c3.yml"; sed -n '/^rules:/,$p' "$OFFICIAL_RULES/kafka_streams.yml" | tail -n +2; } > "$MONITORING_DIR/jmx-c3.yml")
log "c3：標頭 cp-server + 我們的 rules-c3.yml + 官方 kafka_streams.yml 的 rules → $(wc -l < "$MONITORING_DIR/jmx-c3.yml") 行"
ok "4 份設定：jmx-controller.yml、jmx-broker.yml、jmx-rest.yml、jmx-c3.yml"

section "17.3 派送 jar 與設定、drop-in 掛上 javaagent（7071 在7.3 節已開）"
for host in $KAFKA_HOSTS $RESTS $C3_HOST; do
  case $host in
    kc*)   role=controller; config_path=/etc/confluent/kafka/jmx-exporter.yml;          opts_var=KAFKA_OPTS;;
    kb*)   role=broker;     config_path=/etc/confluent/kafka/jmx-exporter.yml;          opts_var=KAFKA_OPTS;;
    rest*) role=rest;       config_path=/etc/confluent/kafka-rest/jmx-exporter.yml;     opts_var=KAFKAREST_OPTS;;
    c3*)   role=c3;         config_path=/etc/confluent/control-center/jmx-exporter.yml; opts_var=CONTROL_CENTER_OPTS;;
  esac
  # 落地區的檔是唯讀的，scp 會把唯讀帶過去；上次失敗留下的檔會擋住這次 scp，先刪
  ssh_run "$host" "rm -f /tmp/$EXPORTER_JAR_NAME /tmp/jmx-$host.yml /tmp/jmx-$host.env" >/dev/null 2>&1
  cp "$MONITORING_DIR/jmx-$role.yml" "/tmp/jmx-$host.yml"; (umask 077; cp "$MONITORING_DIR/jmx-exporter.env" "/tmp/jmx-$host.env")
  copy_to_tmp "$host" "$EXPORTER_JAR" "/tmp/jmx-$host.yml" "/tmp/jmx-$host.env" || { fail "$host: scp"; rm -f "/tmp/jmx-$host.yml" "/tmp/jmx-$host.env"; continue; }
  rm -f "/tmp/jmx-$host.yml" "/tmp/jmx-$host.env"
  result=$(ssh_script "$host" HOST="$host" JAR="$EXPORTER_JAR_NAME" CONFIG="$config_path" UNIT="$(unit_of "$host")" OPTS_VAR="$opts_var" <<'EOF'
sudo install -d -m 0755 /opt/jmx-exporter
sudo rm -f /opt/jmx-exporter/jmx_prometheus_javaagent-*.jar
sudo install -m 0644 /tmp/$JAR /opt/jmx-exporter/$JAR
sudo install -o root -g confluent -m 0640 /tmp/jmx-$HOST.yml "$CONFIG"
sudo install -o root -g root -m 0600 /tmp/jmx-$HOST.env /etc/confluent/jmx-exporter.env
rm -f /tmp/$JAR /tmp/jmx-$HOST.yml /tmp/jmx-$HOST.env
printf '[Service]\nEnvironmentFile=/etc/confluent/jmx-exporter.env\nEnvironment="%s=-javaagent:/opt/jmx-exporter/%s=7071:%s"\n' "$OPTS_VAR" "$JAR" "$CONFIG" \
  | sudo tee /etc/systemd/system/$UNIT.service.d/40-jmx.conf >/dev/null
sudo systemctl daemon-reload
agent=$(systemctl show $UNIT -p Environment --value | tr ' ' '\n' | grep -o 'javaagent:[^ =]*' | head -1)
echo "$agent $(sudo wc -l "$CONFIG" | cut -d' ' -f1) lines env=$(sudo stat -c %a /etc/confluent/jmx-exporter.env)"
EOF
)
  case $result in "javaagent:/opt/jmx-exporter/$EXPORTER_JAR_NAME"*" env=600") ok "$host: $result";; *) fail "$host: $result";; esac
done
[ "$FAIL_COUNT" = 0 ] || die "派送失敗，不重啟"

section "17.4 滾動重啟、驗證端點（匿名 401、帶帳密看得到指標；憑證鏈用銀行根憑證驗，不用 -k）"
rolling_restart controllers brokers rests c3 || die "滾動重啟有主機沒健康"
# controller／broker 的官方規則帶 startDelaySeconds: 120，重啟後前兩分鐘 7071 回 200 但沒有指標：等到有指標再算
for host in $KAFKA_HOSTS $RESTS $C3_HOST; do
  metrics_url=https://$(fqdn "$host"):7071/metrics
  anonymous_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$BANK_ROOT_CA" "$metrics_url")
  metric_count=0
  for _ in $(seq 1 30); do
    metric_count=$(curl -s --max-time 20 --cacert "$BANK_ROOT_CA" -u "prometheus:$(cat "$SCRAPE_PASSWORD_FILE")" "$metrics_url" | grep -cE '^(kafka_|jvm_)')
    [ "$metric_count" -gt 20 ] && break; sleep 10
  done
  if [ "$anonymous_code" = 401 ] && [ "$metric_count" -gt 20 ]; then ok "$host 匿名=$anonymous_code 指標=$metric_count"
  else fail "$host 匿名=$anonymous_code 指標=$metric_count"; fi
done

section "17.5 給銀行監控團隊的檔：$MONITORING_DIR/to-bank/"
BANK_OUT=$MONITORING_DIR/to-bank
rm -rf "$BANK_OUT"; install -d "$BANK_OUT/prometheus" "$BANK_OUT/alertmanager" "$BANK_OUT/grafana/dashboards"
export CONTROLLER_TARGETS BROKER_TARGETS REST_TARGETS C3_TARGETS ENV_LABEL
# scrape 設定的 targets 寫法："kc01.poc.lab:7071", "kc02.poc.lab:7071"
quoted_targets() { local host; for host in "$@"; do printf '"%s:7071", ' "$(fqdn "$host")"; done | sed 's/, $//'; }
CONTROLLER_TARGETS=$(quoted_targets $CONTROLLERS)
BROKER_TARGETS=$(quoted_targets $BROKERS)
REST_TARGETS=$(quoted_targets $RESTS)
C3_TARGETS=$(quoted_targets $C3_HOST)
ENV_LABEL=$MONITOR_ENV_LABEL
render_template "$TEMPLATE_DIR/prometheus-scrape.yml" "$BANK_OUT/prometheus/scrape-confluent.yml" CONTROLLER_TARGETS BROKER_TARGETS REST_TARGETS C3_TARGETS ENV_LABEL || die "render scrape"
cp "$TEMPLATE_DIR/confluent-alerts.yml" "$BANK_OUT/prometheus/confluent-alerts.yml"
cp "$BANK_ROOT_CA" "$BANK_OUT/prometheus/ca.pem"
(umask 077; cp "$SCRAPE_PASSWORD_FILE" "$BANK_OUT/prometheus/scrape.pass")
cp "$TEMPLATE_DIR/alertmanager.yml" "$BANK_OUT/alertmanager/alertmanager.yml"
cp "$TEMPLATE_DIR/grafana-datasource.yml" "$BANK_OUT/grafana/datasource-prometheus.yml"
# 官方 dashboard：原樣複製後修兩件事（落地區的檔是唯讀的，複製出來要加回寫入權限）
#  1. datasource 是匯入畫面用的佔位符 ${Prometheus}，檔案佈建不會替換 → 改成固定的 uid Prometheus
#  2. 成對的 ZooKeeper／KRaft 版本用同一個 uid，Grafana 只收第一個 → 後面的改自己的 uid 與標題
OFFICIAL_DASH=$OFFICIAL/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards
cp "$OFFICIAL_DASH"/*.json "$OFFICIAL_DASH/dashboard.yml" "$BANK_OUT/grafana/dashboards/"
chmod u+w "$BANK_OUT"/grafana/dashboards/*
DASHBOARD_DIR=$BANK_OUT/grafana/dashboards python3 - <<'EOF' || die "dashboard 處理失敗"
import collections, glob, json, os
files = sorted(glob.glob(os.path.join(os.environ['DASHBOARD_DIR'], '*.json')))
seen = collections.defaultdict(list)
for f in files:
    d = json.loads(open(f, encoding='utf-8').read().replace('${Prometheus}', 'Prometheus'))
    seen[d['uid']].append((f, d))
renamed = 0
for uid, group in seen.items():
    for i, (f, d) in enumerate(group):
        if i > 0:
            stem = os.path.basename(f)[:-5]
            d['uid'] = (uid + '-' + stem)[:40]
            d['title'] = d['title'] + ' [' + stem + ']'
            renamed += 1
        json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('dashboards: %d, placeholder datasource fixed, uid shared with another file (renamed): %d' % (len(files), renamed))
EOF
ok "給銀行：to-bank/prometheus（scrape-confluent.yml、confluent-alerts.yml $(grep -c 'alert:' "$BANK_OUT/prometheus/confluent-alerts.yml") 條、ca.pem、scrape.pass）、to-bank/alertmanager、to-bank/grafana（datasource、$(ls "$BANK_OUT"/grafana/dashboards/*.json | wc -l) 個 dashboard）"
target_count=$(wc -w <<<"$KAFKA_HOSTS $RESTS $C3_HOST")
ask_bank "監控團隊：prometheus/ 放進行內 Prometheus（scrape-confluent.yml 用 scrape_config_files 引用，confluent-alerts.yml 放進 rule_files，ca.pem、scrape.pass(0600) 放 /etc/prometheus/confluent/）；" \
         "    alertmanager/alertmanager.yml 併入行內 Alertmanager（webhook 網址換成行內的，兩種格式留一種）；grafana/ 的 datasource 與 dashboards/ 放進 Grafana 的 provisioning；" \
         "    確認 $target_count 個 target 都是 up、告警規則載入、dashboard 都在。C3 內建的 Prometheus／Alertmanager 不動，不在 C3 建 alert trigger／action。" \
         "    consumer lag 不是 broker 的 JMX 指標，要看 C3 或另接 lag exporter。"
finish_step
