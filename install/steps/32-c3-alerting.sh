#!/usr/bin/env bash
# 第 32 站：銀行沒有 Prometheus 時的 REST Proxy 告警 —— C3 內建 Prometheus 抓 REST Proxy，依 target label 分流，第二個 Alertmanager 送 omnibus
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；C3 升到 2.6.1 之後才做，銀行有 Prometheus 時走第 17 站）
#
# 做什麼：
#   bash steps/32-c3-alerting.sh install   32.2 第二個 Alertmanager；32.3 規則、Prometheus 設定（抓取、分流）
#   bash steps/32-c3-alerting.sh test      暫時放兩條一定成立的規則：有 target 的只到第二台、沒有的只到內建，測完拿掉
#   bash steps/32-c3-alerting.sh status    版本、服務、抓取、Alertmanager 清單
# 結束碼：0 成功；1 失敗
#
# 需要什麼：C3 2.6.1（內附 Alertmanager 0.34.0；2.5.1 內附的 0.32.2 會把字串欄位改成物件、數字）、第 17 站的 7071
# 產出什麼：c3-01 的 /etc/confluent/alertmanager-custom/alertmanager.yml、alertmanager-custom.service、
#           /etc/confluent-control-center/custom-rules-rest.yml、prometheus-generated.yml（多抓取與分流）
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

# rest_targets_up：REST Proxy 抓到幾台
rest_targets_up() {
  local reply

  reply=$(prom_query 'sum(up{job="rest-proxy"})')

  # 例：…"value":[1730000000.1,"2"]… → 2（以雙引號切開的第 4 欄）
  echo "$reply" | grep -oE '"value":\[[^,]*,"[0-9]*"' | cut -d'"' -f4
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
  echo "$1" | tr ',' '\n' | grep -qx "$2"
}

do_install() {
  local targets host up attempt

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

  section "32.3 規則、Prometheus 設定（抓取、分流）"
  targets=""

  for host in $RESTS; do
    # 第二台之後，前面先加逗號
    if [ -n "$targets" ]; then
      targets="$targets, "
    fi

    targets="$targets\"$(fqdn "$host"):7071\""
  done

  export C3_FQDN REST_SCRAPE_TARGETS=$targets

  if ! render_template \
    "$TEMPLATE_DIR/prometheus-generated-c3-alerting.yml" \
    "$CONF_DIR/prometheus-generated.yml" \
    C3_FQDN REST_SCRAPE_TARGETS; then
    die "render prometheus-generated-c3-alerting.yml"
  fi

  if ! copy_to_tmp "$C3_HOST" "$CONF_DIR/prometheus-generated.yml" "$TEMPLATE_DIR/c3-custom-rules-rest.yml"; then
    die "scp"
  fi

  if ! ssh_script "$C3_HOST" <<'EOF'
set -e
cd /etc/confluent-control-center
sudo install -o root -g confluent -m 0640 /tmp/prometheus-generated.yml prometheus-generated.yml
sudo install -o root -g confluent -m 0640 /tmp/c3-custom-rules-rest.yml custom-rules-rest.yml
rm -f /tmp/prometheus-generated.yml /tmp/c3-custom-rules-rest.yml
EOF
  then
    die "放設定失敗"
  fi

  if ! restart_prometheus; then
    die "Prometheus 重啟後沒有就緒"
  fi

  # 抓取間隔 60 秒：最多等 3 分鐘
  for attempt in $(seq 1 18); do
    up=$(rest_targets_up)

    if [ "$up" = "$(wc -w <<<"$RESTS" | tr -d ' ')" ]; then
      break
    fi

    sleep 10
  done

  if [ "$up" = "$(wc -w <<<"$RESTS" | tr -d ' ')" ]; then
    ok "REST Proxy 抓到 $up 台"
  else
    fail "REST Proxy 只抓到 ${up:-0} 台"
  fi
}

do_test() {
  local second builtin attempt

  section "暫時放兩條一定成立的規則"

  if ! ssh_script "$C3_HOST" <<'EOF'
set -e
cd /etc/confluent-control-center
sudo cp -p custom-rules-rest.yml /tmp/custom-rules-rest.yml.keep
sudo tee -a custom-rules-rest.yml > /dev/null <<'RULES'
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
sudo cp -p /tmp/custom-rules-rest.yml.keep custom-rules-rest.yml
sudo rm -f /tmp/custom-rules-rest.yml.keep
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
  log "REST Proxy 抓到：$(rest_targets_up) 台"
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
