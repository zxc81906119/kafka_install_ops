#!/usr/bin/env bash
# 第 17 站：監控 —— 每個 Java 程序（controller、broker、REST Proxy、C3）掛 JMX exporter（7071、只用 HTTPS、不要帳密：存取控制靠防火牆只放行行內 Prometheus），
#           並產出給銀行監控團隊（行內 Prometheus／Alertmanager／Grafana）的設定、告警規則、官方 dashboard
# where: ops02 （root）
#
# 做什麼：
#   17.1 exporter 設定的標頭（HTTPS；keystore 密碼不寫進 YAML）；清掉舊版（10-30 以前）的抓取密碼與鹽
#   17.2 每台的 exporter 設定 = 標頭 + Confluent 官方規則（controller／broker／REST）或我們的小規則（C3）
#   17.3 jar 與設定派送、drop-in 把 -javaagent 加進 KAFKA_OPTS／KAFKAREST_OPTS／CONTROL_CENTER_OPTS
#   17.4 滾動重啟；HTTPS 看得到指標、不加密的 http:// 連不上
#   17.5 給銀行：scrape 設定、告警規則、Alertmanager 設定（兩種 webhook 格式）、Grafana datasource 與 32 個官方 dashboard、根憑證
# 需要什麼：JMX_EXPORTER=1；jar 與 Confluent 官方的規則檔（jmx-monitoring-stacks）在第 2.4 站已帶進 ~/landing。
# 產出什麼：~/monitoring 的 exporter 設定、~/monitoring/to-bank/（給銀行監控團隊）；每台的 7071。
# 不做：C3 內建的 Prometheus／Alertmanager 不動（C3 畫面還要用）；告警與 dashboard 只走行內那一套，不在 C3 建 alert trigger／action。
# 注意：exporter 的 YAML 不支援 Secret Protection；keystore 密碼用 ${JMX_KEYSTORE_PASSWORD} 從 root 0600 的環境檔帶進去，YAML 本身 0640 root:confluent。
# 能不能重跑：安全。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"

if [ "$JMX_EXPORTER" != 1 ]; then
  log "JMX_EXPORTER=$JMX_EXPORTER：略過第 17 站"
  exit 0
fi

EXPORTER_JAR=$(ls "$LANDING"/tools/jmx_prometheus_javaagent-*.jar 2>/dev/null | head -1)
if [ -z "$EXPORTER_JAR" ]; then
  die "$LANDING/tools 沒有 jmx_prometheus_javaagent jar（第 2.4 站）"
fi
EXPORTER_JAR_NAME=$(basename "$EXPORTER_JAR")

# Confluent 官方 jmx-monitoring-stacks（第 2.4 站，固定在一個 commit）
OFFICIAL=$LANDING/monitoring/jmx-monitoring-stacks
if [ ! -s "$OFFICIAL/COMMIT" ]; then
  die "$OFFICIAL 不存在：官方規則檔還沒帶進來（第 2.4 站）"
fi
OFFICIAL_RULES=$OFFICIAL/shared-assets/jmx-exporter
OFFICIAL_DASH=$OFFICIAL/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards
BANK_OUT=$MONITORING_DIR/to-bank

# metric_count <網址>：拿一次指標，數 kafka_、jvm_ 開頭的行（連不上就是 0）
metric_count() {
  curl -s --max-time 30 --cacert "$BANK_ROOT_CA" "$1" | awk '/^(kafka_|jvm_)/ {c++} END {print c + 0}'
}

# http_code <網址> [curl 參數…]：HTTP 狀態碼（連不上時是 000）
http_code() {
  local url=$1
  shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" "$url"
}

# quoted_targets <主機…>：scrape 設定的 targets 寫法
#   例：quoted_targets kc01 kc02 → "kc01.poc.lab:7071", "kc02.poc.lab:7071"
quoted_targets() {
  local host
  for host in "$@"; do
    printf '"%s:7071", ' "$(fqdn "$host")"
  done | sed 's/, $//'
}

# fix_dashboards：修 $BANK_OUT/grafana/dashboards/*.json 的兩件事（和手冊 17.5 同一段 Python；JSON 用 sed 改不安全）
#   1. datasource 是匯入畫面用的佔位符 ${Prometheus}，檔案佈建不會替換 → 改成固定的 uid Prometheus
#   2. 成對的 ZooKeeper／KRaft 版本用同一個 uid，Grafana 只收第一個 → 後面的改自己的 uid 與標題
fix_dashboards() {
  DASHBOARD_DIR=$BANK_OUT/grafana/dashboards python3 - <<'EOF'
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
print('dashboards: %d, placeholder datasource fixed, uid shared with another file (renamed): %d'
      % (len(files), renamed))
EOF
}

section "17.1 exporter 設定的標頭（HTTPS，不要帳密）"
install -d -m 0700 "$MONITORING_DIR"

# 舊版（10-30 以前）7071 用 basic auth：抓取密碼與鹽已經不用了，留著只會讓人以為還要交給銀行
rm -f "$SECRETS_DIR/jmx-scrape.pass" "$SECRETS_DIR/jmx-scrape.salt" "$BANK_OUT/prometheus/scrape.pass"

# 1. 四種標頭：controller 用 kafka-internal.p12、broker 用 cp-server.p12、REST 用 svc-rest.p12、C3 用 svc-c3.p12
#    keystore 密碼不寫進 YAML：寫 ${JMX_KEYSTORE_PASSWORD}（exporter 1.4 起支援），值在每台 /etc/confluent/jmx-exporter.env（root 0600），drop-in 用 EnvironmentFile 帶進去。
#    範本裡用佔位字串，渲染後才換成 ${…}（render_template 會把沒換掉的 ${…} 當錯誤）
export KS
for KS in cp-server kafka-internal svc-c3 svc-rest; do
  if ! render_template "$TEMPLATE_DIR/jmx-header.yml" "$MONITORING_DIR/jmx-header-$KS.yml" KS; then
    die "render jmx-header"
  fi

  sed -i 's/@JMX_KEYSTORE_PASSWORD@/${JMX_KEYSTORE_PASSWORD}/' "$MONITORING_DIR/jmx-header-$KS.yml"
done

# 2. keystore 密碼的環境檔（0600）
install -m 0600 /dev/null "$MONITORING_DIR/jmx-exporter.env"
printf 'JMX_KEYSTORE_PASSWORD=%s\n' "$(cat "$PKI_DIR/store.pass")" > "$MONITORING_DIR/jmx-exporter.env"

# 3. 確認：YAML 裡的密碼是變數、環境檔 0600
password_line=$(grep -h 'password:' "$MONITORING_DIR"/jmx-header-*.yml | sort -u | sed 's/^ *//')
env_mode=$(stat -c %a "$MONITORING_DIR/jmx-exporter.env")
header_files="jmx-header-cp-server.yml、jmx-header-kafka-internal.yml、jmx-header-svc-c3.yml、jmx-header-svc-rest.yml"
ok "標頭 $header_files（keystore 密碼：$password_line）；jmx-exporter.env $env_mode"

# 4. 確認：沒有 authentication: 設定（要是 0；註解裡的字不算）
auth_count=$(awk '/^ *authentication:/ {c++} END {print c + 0}' "$MONITORING_DIR"/jmx-header-*.yml)
if [ "$auth_count" = 0 ]; then
  ok "標頭沒有 authentication 設定"
else
  fail "標頭有 $auth_count 行 authentication 設定（7071 不要帳密）"
fi

section "17.2 每台的 exporter 設定 = 標頭 + Confluent 官方規則（commit $(cut -c1-12 "$OFFICIAL/COMMIT")）"

# 舊版（basic auth 時代）留下的檔，有的話刪掉
for old_file in alert-rules.yml ca.pem prometheus-scrape.yml \
                rules-kafka.yml rules-rest.yml rules-jvm.yml scrape.pass; do
  rm -f "$MONITORING_DIR/$old_file"
done

# 1. controller、broker、REST Proxy：標頭＋官方規則（檔案 0600）
#    寫法：角色:用哪份標頭:官方規則檔名
for role_spec in controller:kafka-internal:kafka_controller \
                 broker:cp-server:kafka_broker \
                 rest:svc-rest:confluent_rest; do
  role=$(cut -d: -f1 <<<"$role_spec")
  keystore=$(cut -d: -f2 <<<"$role_spec")
  official_rules=$(cut -d: -f3 <<<"$role_spec")
  role_config=$MONITORING_DIR/jmx-$role.yml

  if [ ! -s "$OFFICIAL_RULES/$official_rules.yml" ]; then
    die "缺官方規則檔 $official_rules.yml"
  fi

  # 官方檔第一行是 YAML 的文件分隔線 ---，接在標頭後面會變成第二份文件，要去掉
  install -m 0600 /dev/null "$role_config"
  cat "$MONITORING_DIR/jmx-header-$keystore.yml" > "$role_config"
  sed '1{/^---$/d}' "$OFFICIAL_RULES/$official_rules.yml" >> "$role_config"

  log "$role：標頭 $keystore + 官方 $official_rules.yml → $(wc -l < "$role_config") 行"
done

# 2. C3 沒有官方規則：我們的 rules-c3.yml（收 kafka.streams:* 與 Jetty；client-state 等帶 process-id 的 MBean 先自己命名）
#    後面接官方 kafka_streams.yml 的 rules（名稱和官方 Streams／RocksDB dashboard 對得上）；不收 C3 自己的 consumer／producer
if [ ! -s "$OFFICIAL_RULES/kafka_streams.yml" ]; then
  die "缺官方規則檔 kafka_streams.yml（第 2 章要帶進來）"
fi
cp "$TEMPLATE_DIR/jmx-rules-c3.yml" "$MONITORING_DIR/rules-c3.yml"
C3_CONFIG=$MONITORING_DIR/jmx-c3.yml
install -m 0600 /dev/null "$C3_CONFIG"
cat "$MONITORING_DIR/jmx-header-svc-c3.yml" "$MONITORING_DIR/rules-c3.yml" > "$C3_CONFIG"
sed -n '/^rules:/,$p' "$OFFICIAL_RULES/kafka_streams.yml" | tail -n +2 >> "$C3_CONFIG"
log "c3：標頭 svc-c3 + 我們的 rules-c3.yml + 官方 kafka_streams.yml 的 rules → $(wc -l < "$C3_CONFIG") 行"

# 3. 每個角色：httpServer 與 lowercaseOutputName 都是 1 行 = 標頭和規則都接上了
for role in controller broker rest c3; do
  role_config=$MONITORING_DIR/jmx-$role.yml
  http_server_lines=$(awk '/^httpServer:/ {c++} END {print c + 0}' "$role_config")
  lowercase_lines=$(awk '/^lowercaseOutputName: true/ {c++} END {print c + 0}' "$role_config")

  if [ "$http_server_lines" != 1 ] || [ "$lowercase_lines" != 1 ]; then
    fail "jmx-$role.yml：httpServer=$http_server_lines lowercaseOutputName=$lowercase_lines（兩個都要是 1）"
  fi
done
ok "4 份設定：jmx-controller.yml、jmx-broker.yml、jmx-rest.yml、jmx-c3.yml"

section "17.3 派送 jar 與設定、drop-in 掛上 javaagent（7071 在 7.3 節已開）"
for host in $KAFKA_HOSTS $RESTS $C3_HOST; do
  # 1. 這台的角色、設定檔放哪、放 javaagent 的環境變數
  case $host in
    kc*)
      role=controller
      config_path=/etc/confluent/kafka/jmx-exporter.yml
      opts_var=KAFKA_OPTS
      ;;
    kb*)
      role=broker
      config_path=/etc/confluent/kafka/jmx-exporter.yml
      opts_var=KAFKA_OPTS
      ;;
    rest*)
      role=rest
      config_path=/etc/confluent/kafka-rest/jmx-exporter.yml
      opts_var=KAFKAREST_OPTS
      ;;
    c3*)
      role=c3
      config_path=/etc/confluent/control-center/jmx-exporter.yml
      opts_var=CONTROL_CENTER_OPTS
      ;;
  esac

  # 2. 落地區的檔是唯讀的，scp 會把唯讀帶過去；上次失敗留下的檔會擋住這次 scp，先刪
  ssh_run "$host" "rm -f /tmp/$EXPORTER_JAR_NAME /tmp/jmx-$host.yml /tmp/jmx-$host.env" >/dev/null 2>&1

  # 3. 這台的設定檔與環境檔先複製到 /tmp（環境檔 0600），和 jar 一起送過去，再刪掉 /tmp 的副本
  cp "$MONITORING_DIR/jmx-$role.yml" "/tmp/jmx-$host.yml"
  install -m 0600 "$MONITORING_DIR/jmx-exporter.env" "/tmp/jmx-$host.env"

  if ! copy_to_tmp "$host" "$EXPORTER_JAR" "/tmp/jmx-$host.yml" "/tmp/jmx-$host.env"; then
    fail "$host: scp"
    rm -f "/tmp/jmx-$host.yml" "/tmp/jmx-$host.env"
    continue
  fi

  rm -f "/tmp/jmx-$host.yml" "/tmp/jmx-$host.env"

  # 4. 在那台放好檔案、寫 drop-in；印 javaagent 的 jar 路徑、設定檔行數、環境檔權限
  host_unit=$(unit_of "$host")
  result=$(ssh_script "$host" HOST="$host" JAR="$EXPORTER_JAR_NAME" CONFIG="$config_path" \
             UNIT="$host_unit" OPTS_VAR="$opts_var" <<'EOF'
sudo install -d -m 0755 /opt/jmx-exporter
sudo rm -f /opt/jmx-exporter/jmx_prometheus_javaagent-*.jar
sudo install -m 0644 /tmp/$JAR /opt/jmx-exporter/$JAR
sudo install -o root -g confluent -m 0640 /tmp/jmx-$HOST.yml "$CONFIG"
sudo install -o root -g root -m 0600 /tmp/jmx-$HOST.env /etc/confluent/jmx-exporter.env
rm -f /tmp/$JAR /tmp/jmx-$HOST.yml /tmp/jmx-$HOST.env

# drop-in：讀環境檔，在 $OPTS_VAR 裡掛 javaagent（聽 7071；DROPIN 沒加引號，裡面的變數會換成值）
sudo tee /etc/systemd/system/$UNIT.service.d/40-jmx.conf >/dev/null <<DROPIN
[Service]
EnvironmentFile=/etc/confluent/jmx-exporter.env
Environment="$OPTS_VAR=-javaagent:/opt/jmx-exporter/$JAR=7071:$CONFIG"
DROPIN
sudo systemctl daemon-reload

environment_words=$(systemctl show $UNIT -p Environment --value | tr ' ' '\n')
agent=$(grep -o 'javaagent:[^ =]*' <<<"$environment_words" | head -1)
lines=$(sudo wc -l "$CONFIG" | cut -d' ' -f1)
echo "$agent $lines lines env=$(sudo stat -c %a /etc/confluent/jmx-exporter.env)"
EOF
)

  # 5. 判斷結果
  case $result in
    "javaagent:/opt/jmx-exporter/$EXPORTER_JAR_NAME"*" env=600")
      ok "$host: $result"
      ;;
    *)
      fail "$host: $result"
      ;;
  esac
done

if [ "$FAIL_COUNT" != 0 ]; then
  die "派送失敗，不重啟"
fi

section "17.4 滾動重啟、驗證端點（HTTPS 看得到指標、不加密的 http:// 連不上；憑證鏈用銀行根憑證驗，不用 -k）"
if ! rolling_restart controllers brokers rests c3; then
  die "滾動重啟有主機沒健康"
fi

for host in $KAFKA_HOSTS $RESTS $C3_HOST; do
  metrics_url=https://$(fqdn "$host"):7071/metrics

  # 1. controller／broker 的官方規則帶 startDelaySeconds: 120，重啟後前兩分鐘 7071 回 200 但沒有指標：
  #    等到有指標再算（超過 20 行）；每 10 秒試一次，最多 30 次
  count_of_metrics=0
  for attempt in $(seq 1 30); do
    count_of_metrics=$(metric_count "$metrics_url")

    if [ "$count_of_metrics" -gt 20 ]; then
      break
    fi

    sleep 10
  done

  # 2. https 用銀行根憑證驗要是 200；不加密的 http 要連不上（000）
  https_code=$(http_code "$metrics_url" --cacert "$BANK_ROOT_CA")
  host_fqdn=$(fqdn "$host")
  http_code_plain=$(http_code "http://$host_fqdn:7071/metrics")

  # 3. 判斷結果
  if [ "$https_code" = 200 ] && [ "$http_code_plain" = 000 ] && [ "$count_of_metrics" -gt 20 ]; then
    ok "$host https=$https_code http=$http_code_plain 指標=$count_of_metrics"
  else
    fail "$host https=$https_code http=$http_code_plain 指標=$count_of_metrics"
  fi
done

section "17.5 給銀行監控團隊的檔：$MONITORING_DIR/to-bank/"

# 1. 每次重新產生：先清掉整個 to-bank/，再建三個資料夾
rm -rf "$BANK_OUT"
install -d "$BANK_OUT/prometheus" "$BANK_OUT/alertmanager" "$BANK_OUT/grafana/dashboards"

# 2. scrape 設定：job 名稱和標籤是官方 dashboard 寫死的
export CONTROLLER_TARGETS BROKER_TARGETS REST_TARGETS C3_TARGETS ENV_LABEL
CONTROLLER_TARGETS=$(quoted_targets $CONTROLLERS)
BROKER_TARGETS=$(quoted_targets $BROKERS)
REST_TARGETS=$(quoted_targets $RESTS)
C3_TARGETS=$(quoted_targets $C3_HOST)
ENV_LABEL=$MONITOR_ENV_LABEL
if ! render_template "$TEMPLATE_DIR/prometheus-scrape.yml" "$BANK_OUT/prometheus/scrape-confluent.yml" \
     CONTROLLER_TARGETS BROKER_TARGETS REST_TARGETS C3_TARGETS ENV_LABEL; then
  die "render scrape"
fi

# 3. 告警規則、根憑證、Alertmanager、Grafana datasource
cp "$TEMPLATE_DIR/confluent-alerts.yml" "$BANK_OUT/prometheus/confluent-alerts.yml"
cp "$BANK_ROOT_CA" "$BANK_OUT/prometheus/ca.pem"
cp "$TEMPLATE_DIR/alertmanager.yml" "$BANK_OUT/alertmanager/alertmanager.yml"
cp "$TEMPLATE_DIR/grafana-datasource.yml" "$BANK_OUT/grafana/datasource-prometheus.yml"

# 4. 官方 dashboard：原樣複製後修兩件事（落地區的檔是唯讀的，複製出來要加回寫入權限）
cp "$OFFICIAL_DASH"/*.json "$OFFICIAL_DASH/dashboard.yml" "$BANK_OUT/grafana/dashboards/"
chmod u+w "$BANK_OUT"/grafana/dashboards/*
if ! fix_dashboards; then
  die "dashboard 處理失敗"
fi

# 5. 結果
alert_count=$(awk '/alert:/ {c++} END {print c + 0}' "$BANK_OUT/prometheus/confluent-alerts.yml")
dashboard_count=$(ls "$BANK_OUT"/grafana/dashboards/*.json | wc -l)
prometheus_files="to-bank/prometheus（scrape-confluent.yml、confluent-alerts.yml $alert_count 條、ca.pem）"
grafana_files="to-bank/grafana（datasource、$dashboard_count 個 dashboard）"
ok "給銀行：$prometheus_files、to-bank/alertmanager、$grafana_files"

target_count=$(wc -w <<<"$KAFKA_HOSTS $RESTS $C3_HOST")
prometheus_request="監控團隊：prometheus/ 放進行內 Prometheus（scrape-confluent.yml 用 scrape_config_files 引用，"
prometheus_request+="confluent-alerts.yml 放進 rule_files，ca.pem 放 /etc/prometheus/confluent/；"
prometheus_request+="7071 沒有帳密，防火牆只放行行內 Prometheus 的來源位址）；"

alertmanager_request="    alertmanager/alertmanager.yml 併入行內 Alertmanager（webhook 網址換成行內的，兩種格式留一種）；"
alertmanager_request+="grafana/ 的 datasource 與 dashboards/ 放進 Grafana 的 provisioning；"

confirm_request="    確認 $target_count 個 target 都是 up、告警規則載入、dashboard 都在。"
confirm_request+="C3 內建的 Prometheus／Alertmanager 不動，不在 C3 建 alert trigger／action。"

ask_bank "$prometheus_request" \
         "$alertmanager_request" \
         "$confirm_request" \
         "    consumer lag 不是 broker 的 JMX 指標，要看 C3 或另接 lag exporter。"
finish_step
