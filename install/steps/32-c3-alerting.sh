#!/usr/bin/env bash
# 第 32 站：銀行沒有 Prometheus 時的告警 —— C3 內建 Prometheus 抓 10 台的 7071、套第 17 站同一份規則，依 target label 分流，第二個 Alertmanager 送 omnibus
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；C3 升到 2.6.1 之後才做，銀行有 Prometheus 時走第 17 站）
#
# 做什麼：
#   bash steps/32-c3-alerting.sh install   32.2 第二個 Alertmanager；32.3 規則（第 17 站的檔加 target）、Prometheus 設定（抓 4 個 job、分流）
#   bash steps/32-c3-alerting.sh test      暫時放兩條一定成立的規則：有 target 的只到第二台、沒有的只到內建，測完拿掉
#   bash steps/32-c3-alerting.sh status    版本、服務、抓取、規則數、Alertmanager 清單
# 結束碼：0 成功；1 失敗
#
# 需要什麼：C3 2.6.1（內附 Alertmanager 0.34.0；2.5.1 內附的 0.32.2 會把字串欄位改成物件、數字）、第 17 站的 7071；c3-01 → 10 台 7071 的防火牆
# 產出什麼：c3-01 的 /etc/confluent/alertmanager-custom/alertmanager.yml、alertmanager-custom.service、
#           /etc/confluent-control-center/custom-rules-confluent.yml（templates/confluent-alerts.yml 每個群組加 target: omnibus）、
#           prometheus-generated.yml（4 個抓取 job，只留規則用得到的指標；分流）
# 能不能重跑：可以。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"

ACTION=${1:-install}
BUNDLED_ALERTMANAGER=/usr/libexec/confluent-control-center/linux_amd64/alertmanager/alertmanager-amd64

# require_c3_target_version：C3 內附的 Alertmanager 要是 0.34 以上，否則停下
require_c3_target_version() {
  local version_line version

  # 例：alertmanager, version 0.34.0 (branch: …) → 0.34.0
  version_line=$(ssh_run "$C3_HOST" "$BUNDLED_ALERTMANAGER --version 2>&1 | head -1")
  version=$(echo "$version_line" | grep -oE 'version [0-9.]+' | cut -d' ' -f2)

  case $version in
    0.34.*|0.35.*|0.36.*)
      ok "C3 內附 Alertmanager $version"
      ;;
    *)
      die "C3 內附 Alertmanager 是 ${version:-未知}：0.32.x 會改掉欄位型別，先把 C3 升到 $C3_TARGET_VERSION（第 29 站）"
      ;;
  esac
}

# restart_prometheus：重啟 C3 內建 Prometheus，等它就緒
restart_prometheus() {
  ssh_run "$C3_HOST" sudo systemctl restart prometheus

  retry 12 5 curl -s -o /dev/null -f \
    --cert "$CERTS_DIR/svc-ops.crt" \
    --key "$KEYS_DIR/svc-ops.key" \
    "https://$C3_FQDN:9090/-/ready"
}

# prom_query <PromQL>：問 C3 內建 Prometheus
prom_query() {
  curl -s -m 10 \
    --cert "$CERTS_DIR/svc-ops.crt" \
    --key "$KEYS_DIR/svc-ops.key" \
    -G "https://$C3_FQDN:9090/api/v1/query" \
    --data-urlencode "query=$1"
}

# JOBS：第 17 站的四個 job（PromQL 的 label 篩選）
JOBS='job=~"kafka-controller|kafka-broker|rest-proxy|control-center"'

# quoted_targets <主機…>："kc01.poc.lab:7071", "kc02.poc.lab:7071"（和第 17 站相同）
quoted_targets() {
  local host
  for host in "$@"; do
    printf '"%s:7071", ' "$(fqdn "$host")"
  done | sed 's/, $//'
}

# targets_up：四個 job 裡 up == 1 的台數
targets_up() {
  local reply

  reply=$(prom_query "count(up{$JOBS} == 1)")

  # 例：…"value":[1730000000.1,"10"]… → 10（以雙引號切開的第 4 欄）
  echo "$reply" | grep -oE '"value":\[[^,]*,"[0-9]*"' | cut -d'"' -f4
}

# rules_summary：告警規則數與 health 不是 ok 的數目，以空白分隔
#   health 的總數減掉 ok 的數目（grep -c 數到 0 時結束碼是 1，不用它）
rules_summary() {
  local reply alerting health_all health_ok

  reply=$(curl -s -m 10 \
    --cert "$CERTS_DIR/svc-ops.crt" \
    --key "$KEYS_DIR/svc-ops.key" \
    "https://$C3_FQDN:9090/api/v1/rules")
  alerting=$(echo "$reply" | grep -o '"type":"alerting"' | wc -l)
  health_all=$(echo "$reply" | grep -o '"health":"[a-z]*"' | wc -l)
  health_ok=$(echo "$reply" | grep -o '"health":"ok"' | wc -l)
  echo "$alerting $((health_all - health_ok))"
}

# alert_names <second|builtin>：那一台 Alertmanager 目前的告警名稱，逗號分隔
alert_names() {
  local alerts_json names

  if [ "$1" = second ]; then
    alerts_json=$(ssh_run "$C3_HOST" "curl -s -m 5 127.0.0.1:9193/api/v2/alerts")
  else
    alerts_json=$(ssh_run "$C3_HOST" "sudo curl -s -m 5 \
      --cacert /etc/confluent/ssl/ca.pem \
      --cert /etc/confluent/ssl/svc-c3.crt \
      --key /etc/confluent/ssl/svc-c3.key \
      https://$C3_FQDN:9093/api/v2/alerts")
  fi

  # 例："alertname":"RestProxyDown" → RestProxyDown（以雙引號切開的第 4 欄）
  names=$(echo "$alerts_json" | grep -o '"alertname":"[^"]*"' | cut -d'"' -f4)
  echo "$names" | sort -u | paste -sd, -
}

# has_alert <告警清單> <名稱>：清單裡有這個告警就回 0
#   例：has_alert "A,B" B → 回 0
has_alert() {
  local names

  names=$(echo "$1" | tr ',' '\n')
  grep -qx "$2" <<<"$names"
}

do_install() {
  local rules_file groups labelled rules expected up attempt alerting not_ok

  require_c3_target_version

  section "32.2 第二個 Alertmanager"
  export C3_OMNIBUS_WEBHOOK_URL

  if ! render_template \
    "$TEMPLATE_DIR/c3-second-alertmanager.yml" \
    "$CONF_DIR/c3-second-alertmanager.yml" \
    C3_OMNIBUS_WEBHOOK_URL; then
    die "render c3-second-alertmanager.yml"
  fi

  if ! copy_to_tmp "$C3_HOST" "$CONF_DIR/c3-second-alertmanager.yml" "$TEMPLATE_DIR/alertmanager-custom.service"; then
    die "scp"
  fi

  if ! ssh_script "$C3_HOST" <<'EOF'
set -e
sudo install -d -o root -g confluent -m 0750 /etc/confluent/alertmanager-custom
sudo install -d -o cp-control-center -g confluent -m 0750 /var/lib/alertmanager-custom
sudo install -o root -g confluent -m 0640 \
  /tmp/c3-second-alertmanager.yml \
  /etc/confluent/alertmanager-custom/alertmanager.yml
sudo install -o root -g root -m 0644 /tmp/alertmanager-custom.service /etc/systemd/system/alertmanager-custom.service
rm -f /tmp/c3-second-alertmanager.yml /tmp/alertmanager-custom.service
sudo systemctl daemon-reload
sudo systemctl enable alertmanager-custom > /dev/null 2>&1
sudo systemctl restart alertmanager-custom
EOF
  then
    die "第二個 Alertmanager 裝不起來"
  fi

  if retry 12 5 ssh_run "$C3_HOST" "curl -s -f -m 3 -o /dev/null 127.0.0.1:9193/-/ready"; then
    ok "alertmanager-custom 就緒（127.0.0.1:9193）"
  else
    die "alertmanager-custom 沒有就緒"
  fi

  section "32.3 規則（第 17 站的檔加 target）、Prometheus 設定（抓 4 個 job、分流）"
  rules_file=$CONF_DIR/custom-rules-confluent.yml

  # 每個群組的 name 那一行後面加兩行（sed 的 a：在那一行之後加一行）：labels: 和 target: omnibus
  sed -e '/^  - name: /a\    labels:' -e '/^  - name: /a\      target: omnibus' \
    "$TEMPLATE_DIR/confluent-alerts.yml" > "$rules_file"

  groups=$(grep -c '^  - name:' "$rules_file")
  labelled=$(grep -c 'target: omnibus' "$rules_file")
  rules=$(grep -c '^      - alert:' "$rules_file")

  if [ "$groups" = "$labelled" ]; then
    ok "custom-rules-confluent.yml：$groups 個群組都帶 target，$rules 條規則"
  else
    die "custom-rules-confluent.yml：$groups 個群組，只有 $labelled 個帶 target"
  fi

  export C3_FQDN CONTROLLER_TARGETS BROKER_TARGETS REST_TARGETS C3_TARGETS ENV_LABEL
  CONTROLLER_TARGETS=$(quoted_targets $CONTROLLERS)
  BROKER_TARGETS=$(quoted_targets $BROKERS)
  REST_TARGETS=$(quoted_targets $RESTS)
  C3_TARGETS=$(quoted_targets $C3_HOST)
  ENV_LABEL=$MONITOR_ENV_LABEL

  if ! render_template \
    "$TEMPLATE_DIR/prometheus-generated-c3-alerting.yml" \
    "$CONF_DIR/prometheus-generated.yml" \
    C3_FQDN CONTROLLER_TARGETS BROKER_TARGETS REST_TARGETS C3_TARGETS ENV_LABEL; then
    die "render prometheus-generated-c3-alerting.yml"
  fi

  if ! copy_to_tmp "$C3_HOST" "$CONF_DIR/prometheus-generated.yml" "$rules_file"; then
    die "scp"
  fi

  # 舊版第 32 站的 custom-rules-rest.yml 一併拿掉（新的規則檔已包含 REST Proxy）
  if ! ssh_script "$C3_HOST" <<'EOF'
set -e
cd /etc/confluent-control-center
sudo install -o root -g confluent -m 0640 /tmp/prometheus-generated.yml prometheus-generated.yml
sudo install -o root -g confluent -m 0640 /tmp/custom-rules-confluent.yml custom-rules-confluent.yml
sudo rm -f custom-rules-rest.yml
rm -f /tmp/prometheus-generated.yml /tmp/custom-rules-confluent.yml
EOF
  then
    die "放設定失敗"
  fi

  if ! restart_prometheus; then
    die "Prometheus 重啟後沒有就緒"
  fi

  expected=$(wc -w <<<"$CONTROLLERS $BROKERS $RESTS $C3_HOST" | tr -d ' ')

  # 抓取間隔 30 秒：最多等 3 分鐘
  for attempt in $(seq 1 18); do
    up=$(targets_up)

    if [ "$up" = "$expected" ]; then
      break
    fi

    sleep 10
  done

  if [ "$up" = "$expected" ]; then
    ok "抓到 $up / $expected 台"
  else
    fail "只抓到 ${up:-0} / $expected 台"
  fi

  # 規則每 60 秒算一次：health 全部 ok 最多等 2 分鐘
  for attempt in $(seq 1 12); do
    read -r alerting not_ok <<<"$(rules_summary)"

    if [ "$not_ok" = 0 ]; then
      break
    fi

    sleep 10
  done

  if [ "$alerting" != "$rules" ]; then
    fail "告警規則 $alerting 條（應該是 $rules 條）"
  elif [ "$not_ok" != 0 ]; then
    fail "告警規則 $alerting 條，health 不是 ok 的 $not_ok 條"
  else
    ok "告警規則 $alerting 條，health 都是 ok"
  fi
}

do_test() {
  local second builtin attempt

  section "暫時放兩條一定成立的規則"

  if ! ssh_script "$C3_HOST" <<'EOF'
set -e
cd /etc/confluent-control-center
sudo cp -p custom-rules-confluent.yml /tmp/custom-rules-confluent.yml.keep
sudo tee -a custom-rules-confluent.yml > /dev/null <<'RULES'
      - alert: Chapter32WithTarget
        expr: vector(1)
        labels: { severity: warning, impact: SERVICE, instance: chapter32 }
        annotations: { summary: "with target", description: 'test: 007 "quoted" a: b' }
  - name: chapter32-no-target
    rules:
      - alert: Chapter32NoTarget
        expr: vector(1)
        labels: { severity: warning, impact: SERVICE, instance: chapter32 }
        annotations: { summary: "no target", description: "test" }
RULES
EOF
  then
    die "放測試規則失敗"
  fi

  if ! restart_prometheus; then
    fail "Prometheus 重啟後沒有就緒"
  fi

  # 規則每 60 秒算一次：最多等 3 分鐘
  for attempt in $(seq 1 18); do
    second=$(alert_names second)
    builtin=$(alert_names builtin)

    if has_alert "$second" Chapter32WithTarget; then
      if has_alert "$builtin" Chapter32NoTarget; then
        break
      fi
    fi

    sleep 10
  done

  log "第二台：[$second]；內建：[$builtin]"

  # 第二台：要有 Chapter32WithTarget，不能有 Chapter32NoTarget
  if has_alert "$second" Chapter32WithTarget; then
    if has_alert "$second" Chapter32NoTarget; then
      fail "沒有 target 的也到了第二台：[$second]"
    else
      ok "有 target 的只到第二台"
    fi
  else
    fail "第二台沒有收到有 target 的告警：[$second]"
  fi

  # 內建：要有 Chapter32NoTarget，不能有 Chapter32WithTarget
  if has_alert "$builtin" Chapter32NoTarget; then
    if has_alert "$builtin" Chapter32WithTarget; then
      fail "有 target 的也到了內建：[$builtin]"
    else
      ok "沒有 target 的只到內建"
    fi
  else
    fail "內建沒有收到沒有 target 的告警：[$builtin]"
  fi

  section "拿掉測試規則"

  if ! ssh_script "$C3_HOST" <<'EOF'
cd /etc/confluent-control-center
sudo cp -p /tmp/custom-rules-confluent.yml.keep custom-rules-confluent.yml
sudo rm -f /tmp/custom-rules-confluent.yml.keep
EOF
  then
    fail "還原規則失敗"
  fi

  if restart_prometheus; then
    ok "規則已還原"
  else
    fail "Prometheus 重啟後沒有就緒"
  fi
}

do_status() {
  log "C3：$(ssh_run "$C3_HOST" 'rpm -q confluent-control-center-next-gen')"
  log "alertmanager-custom：$(ssh_run "$C3_HOST" 'systemctl is-active alertmanager-custom')"
  log "抓到：$(targets_up) 台；告警規則數、health 不是 ok 的數目：$(rules_summary)"
  log "第二台告警：[$(alert_names second)]；內建告警：[$(alert_names builtin)]"
}

case $ACTION in
  install)
    do_install
    ;;
  test)
    do_test
    ;;
  status)
    do_status
    ;;
  *)
    die "用法：bash $0 install|test|status"
    ;;
esac

finish_step
