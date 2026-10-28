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
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/render.sh"

ACTION=${1:-check}
TEMPLATE_DIR=$INSTALL_DIR/templates
BANK_OUT=$MONITORING_DIR/to-bank
TIMER_NAME=confluent-cert-expiry
CERT_WARN_DAYS=${CERT_WARN_DAYS:-60}

# 平台出示憑證的每一個 TLS 端點：controller 9093；broker 9092（INTERNAL）、9094（TOKEN）、9095（CLIENT）、8090（MDS）；REST 兩台與 LB；C3；AD（銀行的，順便看）
cert_targets() {
  local h t=""
  for h in $CONTROLLERS; do t="$t\"$(fqdn "$h"):9093\", "; done
  for h in $BROKERS; do t="$t\"$(fqdn "$h"):9092\", \"$(fqdn "$h"):9094\", \"$(fqdn "$h"):9095\", \"$(fqdn "$h"):8090\", "; done
  for h in $RESTS; do t="$t\"$(fqdn "$h"):8082\", "; done
  t="$t\"$REST_VIP:8082\", \"$C3_FQDN:9021\", \"$AD_FQDN:$AD_LDAPS_PORT\""
  echo "$t"
}

files() {
  section "22.2 給銀行監控團隊：blackbox 設定、scrape、規則、規則測試（$BANK_OUT/prometheus/）"
  [ -d "$BANK_OUT/prometheus" ] || die "沒有 $BANK_OUT/prometheus：先跑第 17 站"
  export CERT_TARGETS ENV_LABEL BLACKBOX_ADDRESS
  CERT_TARGETS=$(cert_targets); ENV_LABEL=$MONITOR_ENV_LABEL; BLACKBOX_ADDRESS=${BLACKBOX_ADDRESS:-BLACKBOX-EXPORTER:9115}
  render_template "$TEMPLATE_DIR/prometheus-scrape-blackbox.yml" "$BANK_OUT/prometheus/scrape-blackbox.yml" CERT_TARGETS ENV_LABEL BLACKBOX_ADDRESS || die "scrape-blackbox.yml"
  chmod 0644 "$BANK_OUT/prometheus/scrape-blackbox.yml"
  cp "$TEMPLATE_DIR/blackbox.yml" "$TEMPLATE_DIR/confluent-alerts-cert.yml" "$TEMPLATE_DIR/cert-expiry-rules-test.yml" "$BANK_OUT/prometheus/" || die "複製失敗"
  ok "scrape-blackbox.yml：$(grep -o '"[^"]*:[0-9]*"' "$BANK_OUT/prometheus/scrape-blackbox.yml" | wc -l) 個端點（blackbox 位址 $BLACKBOX_ADDRESS，銀行改成自己的）"
  ok "confluent-alerts-cert.yml：$(grep -c 'alert:' "$BANK_OUT/prometheus/confluent-alerts-cert.yml") 條；blackbox.yml（tls 模組，用 ca.pem 驗鏈）；cert-expiry-rules-test.yml（promtool test rules）"
  ask_bank "監控團隊：起 blackbox_exporter（blackbox.yml）；scrape-blackbox.yml 的 BLACKBOX-EXPORTER:9115 改成它的位址、放進 scrape_config_files；confluent-alerts-cert.yml 放進 rule_files；promtool test rules cert-expiry-rules-test.yml 驗規則（lab：bank-sim.sh monitoring-blackbox）"
}

check() {
  section "22.3 操作機：~/pki/certs 每一張憑證的剩餘天數（warning < $CERT_WARN_DAYS 天）"
  install -m 0700 "$TEMPLATE_DIR/cert-expiry.sh" "$CONF_DIR/cert-expiry.sh" || die "複製 cert-expiry.sh 失敗"
  local rc; WARN_DAYS=$CERT_WARN_DAYS bash "$CONF_DIR/cert-expiry.sh" "$CERTS_DIR" | tee -a "$LOG_FILE"; rc=${PIPESTATUS[0]}
  case $rc in 0) ok "都在 $CERT_WARN_DAYS 天以上（rc 0）";; 2) warn "有憑證快到期（rc 2）：照第 21 章換發";; *) fail "有過期或讀不到的憑證（rc $rc）";; esac
  log "syslog：$(journalctl -t confluent-cert -n 1 --no-pager -o cat)"
}

schedule() {
  section "22.3 每天 08:10 檢查（systemd timer：$TIMER_NAME）"
  [ -x "$CONF_DIR/cert-expiry.sh" ] || install -m 0700 "$TEMPLATE_DIR/cert-expiry.sh" "$CONF_DIR/cert-expiry.sh"
  printf '[Unit]\nDescription=Confluent certificate expiry check\n\n[Service]\nType=oneshot\nEnvironment=HOME=/root\nEnvironment=WARN_DAYS=%s\nExecStart=/bin/bash %s %s\nSuccessExitStatus=2\n' \
    "$CERT_WARN_DAYS" "$CONF_DIR/cert-expiry.sh" "$CERTS_DIR" | tee "/etc/systemd/system/$TIMER_NAME.service" >/dev/null
  printf '[Unit]\nDescription=Daily Confluent certificate expiry check\n\n[Timer]\nOnCalendar=*-*-* 08:10:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' |
    tee "/etc/systemd/system/$TIMER_NAME.timer" >/dev/null
  systemctl daemon-reload
  systemctl enable --now "$TIMER_NAME.timer" >/dev/null 2>&1 || die "timer 啟用失敗"
  systemctl start "$TIMER_NAME.service" || fail "第一次檢查失敗（看 journalctl -u $TIMER_NAME）"
  ok "下次執行：$(systemctl show "$TIMER_NAME.timer" -p NextElapseUSecRealtime --value)"
  ok "syslog：$(journalctl -t confluent-cert -n 1 --no-pager -o cat)"
}

case $ACTION in
  files)    files; finish_step;;
  check)    check; [ "$FAIL_COUNT" = 0 ];;
  schedule) schedule; finish_step;;
  *) sed -n '2,12p' "$0"; exit 1;;
esac
