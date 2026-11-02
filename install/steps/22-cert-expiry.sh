#!/usr/bin/env bash
# 第 22 站：憑證到期監控（選配）—— 銀行 Prometheus 的 blackbox_exporter 探每個 TLS 端點實際出示的憑證；操作機每天讀 ~/pki/certs 的到期日（手把手第 22 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；第 17 站做過之後跑 files 一次；schedule 一次；check 隨時可跑）
#
# 用法：
#   bash steps/22-cert-expiry.sh files      22.2 給銀行監控團隊：to-bank/prometheus/{blackbox.yml, scrape-blackbox.yml, confluent-alerts-cert.yml, cert-expiry-rules-test.yml}
#                                           （lab：bank-sim.sh monitoring-blackbox 起 exporter、放進 Prometheus）
#   bash steps/22-cert-expiry.sh check      22.3 操作機這一端：~/conf/cert-expiry.sh 讀 ~/pki/certs 每一張憑證的剩餘天數，寫 syslog（tag confluent-cert）；rc 0／2 快到期／1 過期
#   bash steps/22-cert-expiry.sh schedule   22.3 操作機 systemd timer：每天 08:10 跑 check（行內有排程系統就改由它呼叫 ~/conf/cert-expiry.sh）
#
# 客戶沒有 blackbox_exporter 時只做 check＋schedule（＋選單 17）；files 是建議。
#
# 需要什麼：files 要第 17 站的 ~/monitoring/to-bank/；check、schedule 要第 9 站的 ~/pki/certs。
# 產出什麼：to-bank/prometheus/ 的四個檔；~/conf/cert-expiry.sh；timer confluent-cert-expiry。
# 能不能重跑：可以，都是覆蓋成一樣的內容。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/render.sh"

ACTION=${1:-check}
BANK_OUT=$MONITORING_DIR/to-bank
TIMER_NAME=confluent-cert-expiry
CERT_WARN_DAYS=${CERT_WARN_DAYS:-60}

# cert_targets：平台出示憑證的每一個 TLS 端點，組成 YAML 清單的寫法
#   controller 9093；broker 9092（INTERNAL）、9094（TOKEN）、9095（CLIENT）、8090（MDS）；REST 兩台與 LB；C3；AD（銀行的，順便看）
#   例："kc01.poc.lab:9093", "kc02.poc.lab:9093", …
cert_targets() {
  local host targets=""

  for host in $CONTROLLERS; do
    targets="$targets\"$(fqdn "$host"):9093\", "
  done

  for host in $BROKERS; do
    targets="$targets\"$(fqdn "$host"):9092\", \"$(fqdn "$host"):9094\", \"$(fqdn "$host"):9095\", \"$(fqdn "$host"):8090\", "
  done

  for host in $RESTS; do
    targets="$targets\"$(fqdn "$host"):8082\", "
  done

  targets="$targets\"$REST_VIP:8082\", \"$C3_FQDN:9021\", \"$AD_FQDN:$AD_LDAPS_PORT\""
  echo "$targets"
}

files() {
  local scrape_file endpoint_count alert_count

  section "22.2 給銀行監控團隊：blackbox 設定、scrape、規則、規則測試（$BANK_OUT/prometheus/）"

  if [ ! -d "$BANK_OUT/prometheus" ]; then
    die "沒有 $BANK_OUT/prometheus：先跑第 17 站"
  fi

  # 1. scrape 設定：每個端點一個 target，經 exporter 的 /probe
  export CERT_TARGETS ENV_LABEL BLACKBOX_ADDRESS
  CERT_TARGETS=$(cert_targets)
  ENV_LABEL=$MONITOR_ENV_LABEL
  BLACKBOX_ADDRESS=${BLACKBOX_ADDRESS:-BLACKBOX-EXPORTER:9115}
  scrape_file=$BANK_OUT/prometheus/scrape-blackbox.yml

  if ! render_template "$TEMPLATE_DIR/prometheus-scrape-blackbox.yml" "$scrape_file" CERT_TARGETS ENV_LABEL BLACKBOX_ADDRESS; then
    die "scrape-blackbox.yml"
  fi
  chmod 0644 "$scrape_file"

  # 2. blackbox 的模組、規則、規則的單元測試
  if ! cp "$TEMPLATE_DIR/blackbox.yml" "$TEMPLATE_DIR/confluent-alerts-cert.yml" "$TEMPLATE_DIR/cert-expiry-rules-test.yml" "$BANK_OUT/prometheus/"; then
    die "複製失敗"
  fi

  # 3. 結果
  endpoint_count=$(grep -o '"[^"]*:[0-9]*"' "$scrape_file" | wc -l)
  alert_count=$(awk '/alert:/ {c++} END {print c + 0}' "$BANK_OUT/prometheus/confluent-alerts-cert.yml")
  ok "scrape-blackbox.yml：$endpoint_count 個端點（blackbox 位址 $BLACKBOX_ADDRESS，銀行改成自己的）"
  ok "confluent-alerts-cert.yml：$alert_count 條；blackbox.yml（tls 模組，用 ca.pem 驗鏈）；cert-expiry-rules-test.yml（promtool test rules）"

  ask_bank "監控團隊：起 blackbox_exporter（blackbox.yml）；scrape-blackbox.yml 的 BLACKBOX-EXPORTER:9115 改成它的位址、放進 scrape_config_files；confluent-alerts-cert.yml 放進 rule_files；promtool test rules cert-expiry-rules-test.yml 驗規則（lab：bank-sim.sh monitoring-blackbox）"
}

check() {
  local rc

  section "22.3 操作機：~/pki/certs 每一張憑證的剩餘天數（warning < $CERT_WARN_DAYS 天）"

  if ! install -m 0700 "$TEMPLATE_DIR/cert-expiry.sh" "$CONF_DIR/cert-expiry.sh"; then
    die "複製 cert-expiry.sh 失敗"
  fi

  # 1. 跑一次（輸出同時進紀錄檔；結束碼要的是腳本的，不是 tee 的）
  WARN_DAYS=$CERT_WARN_DAYS bash "$CONF_DIR/cert-expiry.sh" "$CERTS_DIR" | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}

  # 2. 判斷結果
  case $rc in
    0)
      ok "都在 $CERT_WARN_DAYS 天以上（rc 0）"
      ;;
    2)
      warn "有憑證快到期（rc 2）：照第 21 章換發"
      ;;
    *)
      fail "有過期或讀不到的憑證（rc $rc）"
      ;;
  esac

  log "syslog：$(journalctl -t confluent-cert -n 1 --no-pager -o cat)"
}

schedule() {
  section "22.3 每天 08:10 檢查（systemd timer：$TIMER_NAME）"

  if [ ! -x "$CONF_DIR/cert-expiry.sh" ]; then
    install -m 0700 "$TEMPLATE_DIR/cert-expiry.sh" "$CONF_DIR/cert-expiry.sh"
  fi

  # 1. service：跑一次腳本（結束碼 2 = 有快到期，不算服務失敗）
  cat > "/etc/systemd/system/$TIMER_NAME.service" <<EOF
[Unit]
Description=Confluent certificate expiry check

[Service]
Type=oneshot
Environment=HOME=/root
Environment=WARN_DAYS=$CERT_WARN_DAYS
ExecStart=/bin/bash $CONF_DIR/cert-expiry.sh $CERTS_DIR
SuccessExitStatus=2
EOF

  # 2. timer：每天 08:10（關機錯過的，開機後補跑）
  cat > "/etc/systemd/system/$TIMER_NAME.timer" <<'EOF'
[Unit]
Description=Daily Confluent certificate expiry check

[Timer]
OnCalendar=*-*-* 08:10:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # 3. 啟用 timer，並馬上跑一次
  systemctl daemon-reload

  if ! systemctl enable --now "$TIMER_NAME.timer" >/dev/null 2>&1; then
    die "timer 啟用失敗"
  fi

  if ! systemctl start "$TIMER_NAME.service"; then
    fail "第一次檢查失敗（看 journalctl -u $TIMER_NAME）"
  fi

  ok "下次執行：$(systemctl show "$TIMER_NAME.timer" -p NextElapseUSecRealtime --value)"
  ok "syslog：$(journalctl -t confluent-cert -n 1 --no-pager -o cat)"
}

case $ACTION in
  files)
    files
    finish_step
    ;;
  check)
    check

    if [ "$FAIL_COUNT" != 0 ]; then
      exit 1
    fi
    ;;
  schedule)
    schedule
    finish_step
    ;;
  *)
    sed -n '2,12p' "$0"
    exit 1
    ;;
esac
