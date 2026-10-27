#!/usr/bin/env bash
# 第 22 站：License 到期監控 —— 讀生效中的 license（JWT）到期日；每天排程檢查、寫 syslog（手把手第 22 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；裝好之後跑一次 schedule，之後由 timer 每天跑 check）
#
# 用法：
#   bash steps/22-license.sh status      印出類型、到期日、剩幾天（不寫 syslog）
#   bash steps/22-license.sh check       同上，另寫 syslog（tag confluent-license）；timer 跑的就是這個
#   bash steps/22-license.sh schedule    裝操作機的 systemd timer（每天 08:00 跑 check，以 root 身分）
# 結束碼：0 正常、2 剩不到 LICENSE_WARN_DAYS 天（預設 90，和 C3 開始提示的天數相同）、1 已過期或讀不到
#
# 原廠沒有到期日的 JMX 指標，所以自己讀：broker 把生效中的 license 存在 _confluent-command topic，
# JWT 中間那段的 exp 就是到期時間（這裡只解開、不驗簽章；簽章由 broker 驗）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-status}
LICENSE_WARN_DAYS=${LICENSE_WARN_DAYS:-90}
TIMER_NAME=confluent-license-check

# read_license_claims：印出 JWT 的 payload（JSON）；讀不到就回 1
read_license_claims() {
  local jwt payload
  jwt=$(timeout 90 kafka-console-consumer --bootstrap-server "$BROKER_TOKEN" --consumer.config "$ADMIN_CLIENT_CONF" \
    --topic _confluent-command --from-beginning --timeout-ms 20000 2>/dev/null |
    grep -a -o 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' | tail -1)
  [ -n "$jwt" ] || return 1
  payload=$(cut -d. -f2 <<<"$jwt" | tr '_-' '/+')
  while [ $(( ${#payload} % 4 )) != 0 ]; do payload="$payload="; done
  base64 -d <<<"$payload" 2>/dev/null
}

# license_status <要不要寫 syslog：0|1>
license_status() {
  local to_syslog=$1 claims expires_at license_type days_left message
  section "22.1 生效中的 license"
  if ! claims=$(read_license_claims) || ! expires_at=$(grep -o '"exp":[0-9]*' <<<"$claims" | cut -d: -f2) || [ -z "$expires_at" ]; then
    [ "$to_syslog" = 1 ] && logger -t confluent-license -p user.err "license 讀不到（_confluent-command 沒有 JWT 或連不上 broker）"
    fail "license 讀不到（_confluent-command 沒有 JWT 或連不上 broker）"
    return 1
  fi
  license_type=$(grep -o '"licenseType":"[^"]*"' <<<"$claims" | cut -d'"' -f4)
  days_left=$(( (expires_at - $(date +%s)) / 86400 ))
  message="license ${license_type:-unknown} 到期 $(date -d "@$expires_at" +%F)，剩 $days_left 天"
  if [ "$days_left" -lt 0 ]; then
    [ "$to_syslog" = 1 ] && logger -t confluent-license -p user.err "已過期：$message"
    fail "已過期：$message"; return 1
  fi
  if [ "$days_left" -lt "$LICENSE_WARN_DAYS" ]; then
    [ "$to_syslog" = 1 ] && logger -t confluent-license -p user.warning "快到期：$message"
    warn "快到期：$message（不到 $LICENSE_WARN_DAYS 天）"; return 2
  fi
  [ "$to_syslog" = 1 ] && logger -t confluent-license -p user.info "$message"
  ok "$message"
}

# 22.2 排程：操作機的 systemd timer；「快到期」(rc 2) 不算服務失敗，告警看 syslog
schedule() {
  section "22.2 每天 08:00 檢查（systemd timer：$TIMER_NAME）"
  printf '[Unit]\nDescription=Confluent license expiry check\n\n[Service]\nType=oneshot\nUser=%s\nExecStart=/bin/bash %s check\nSuccessExitStatus=2\n' \
    "$(id -un)" "$INSTALL_DIR/steps/22-license.sh" | tee "/etc/systemd/system/$TIMER_NAME.service" >/dev/null
  printf '[Unit]\nDescription=Daily Confluent license expiry check\n\n[Timer]\nOnCalendar=*-*-* 08:00:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' |
    tee "/etc/systemd/system/$TIMER_NAME.timer" >/dev/null
  systemctl daemon-reload
  systemctl enable --now "$TIMER_NAME.timer" >/dev/null 2>&1 || die "timer 啟用失敗"
  systemctl start "$TIMER_NAME.service" || fail "第一次檢查失敗（看 journalctl -u $TIMER_NAME）"
  ok "下次執行：$(systemctl show "$TIMER_NAME.timer" -p NextElapseUSecRealtime --value)"
  ok "syslog：$(journalctl -t confluent-license -n 1 --no-pager -o cat)"
}

case $ACTION in
  status)   license_status 0; exit $?;;
  check)    license_status 1; exit $?;;
  schedule) schedule; finish_step;;
  *) die "用法：bash $0 status|check|schedule";;
esac
