#!/usr/bin/env bash
# 第 26 站：License 到期監控 —— 讀生效中的 license（JWT）到期日；每天排程檢查、寫 syslog（手把手第 26 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；裝好之後跑一次 schedule，之後由 timer 每天跑 check）
#
# 用法：
#   bash steps/26-license.sh status      印出類型、到期日、剩幾天（不寫 syslog）
#   bash steps/26-license.sh check       同上，另寫 syslog（tag confluent-license）；timer 跑的就是這個
#   bash steps/26-license.sh schedule    裝操作機的 systemd timer（每天 08:00 跑 check，以 root 身分）
#   bash steps/26-license.sh reset       26.4 試用期到期時重置測試／評估環境的叢集（清空資料、新 cluster id、從 23.3 的備份全部建回來）；
#                                        要輸入現在的 cluster id 確認（不互動時 RESET_CONFIRM=<cluster id>）；先取得原廠同意
# 結束碼：0 正常、2 剩不到 LICENSE_WARN_DAYS 天（預設 90，和 C3 開始提示的天數相同）、1 已過期或讀不到
#
# 原廠沒有到期日的 JMX 指標，所以自己讀：broker 把生效中的 license 存在 _confluent-command topic，
# JWT 中間那段的 exp 就是到期時間（這裡只解開、不驗簽章；簽章由 broker 驗）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
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
  section "26.1 生效中的 license"
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

# 26.2 排程：操作機的 systemd timer；「快到期」(rc 2) 不算服務失敗，告警看 syslog
schedule() {
  section "26.2 每天 08:00 檢查（systemd timer：$TIMER_NAME）"
  printf '[Unit]\nDescription=Confluent license expiry check\n\n[Service]\nType=oneshot\nUser=%s\nExecStart=/bin/bash %s check\nSuccessExitStatus=2\n' \
    "$(id -un)" "$INSTALL_DIR/steps/26-license.sh" | tee "/etc/systemd/system/$TIMER_NAME.service" >/dev/null
  printf '[Unit]\nDescription=Daily Confluent license expiry check\n\n[Timer]\nOnCalendar=*-*-* 08:00:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' |
    tee "/etc/systemd/system/$TIMER_NAME.timer" >/dev/null
  systemctl daemon-reload
  systemctl enable --now "$TIMER_NAME.timer" >/dev/null 2>&1 || die "timer 啟用失敗"
  systemctl start "$TIMER_NAME.service" || fail "第一次檢查失敗（看 journalctl -u $TIMER_NAME）"
  ok "下次執行：$(systemctl show "$TIMER_NAME.timer" -p NextElapseUSecRealtime --value)"
  ok "syslog：$(journalctl -t confluent-license -n 1 --no-pager -o cat)"
}

# 26.4 試用期到期、原廠來不及給延長 license 時，重置「測試／評估」環境的叢集（先取得原廠同意）：
#   備份 → 停服務 → 清資料 → 新 cluster id 格式化 → 啟動、svc-ops 第一條權限 → 從備份全部建回來 → REST、C3 → license
#   會清空訊息、consumer 讀到的位置、稽核 topic 的舊紀錄；需要安裝期的 sudo（OS 團隊臨時開）。
#   要確認：互動時輸入現在的 cluster id；不互動時用環境變數 RESET_CONFIRM=<現在的 cluster id>。
reset_cluster() {
  local old_id new_id dir host unit result round ready dir_id_var initial_controllers missing format_storage cli_home rest_code c3_code
  [ -s "$CONF_DIR/kraft.env" ] || die "找不到 $CONF_DIR/kraft.env"
  old_id=$(sed -n 's/^CLUSTER_ID=//p' "$CONF_DIR/kraft.env")
  section "26.4 重置叢集 $old_id（會清空所有訊息；只用在測試／評估環境，先取得原廠同意）"
  if [ -t 0 ] && [ -z "${RESET_CONFIRM:-}" ]; then read -r -p "確定要重置就輸入現在的 cluster id：" RESET_CONFIRM; fi
  [ "${RESET_CONFIRM:-}" = "$old_id" ] || die "沒有確認（RESET_CONFIRM 不是現在的 cluster id），不重置"

  section "26.4 第 1 步：備份（23.3）"
  bash "$INSTALL_DIR/steps/23-metadata-backup.sh" run || die "備份失敗，不重置"
  dir=$(ls -d "$HOME/backup/metadata"/20* | tail -1)
  missing=$(grep -o "SCRAM credential configs for user-principal '[^']*'" "$dir/users.txt" | cut -d"'" -f2 |
    while read -r u; do [ -s "$SECRETS_DIR/$u.pass" ] || echo "$u"; done | paste -sd' ')
  [ -z "$missing" ] || die "這些 SCRAM 帳號沒有密碼檔，重置後建不回來：$missing（先補 $SECRETS_DIR/<帳號>.pass）"
  ok "備份 $dir（topic $(grep -c '^Topic:' "$dir/topics.txt")、principal $(grep -c '^== ' "$dir/rbac.txt")、ACL $(grep -c '|' "$dir/acls.txt")）"

  section "26.4 第 2 步：停服務（C3 → REST → broker → controller）"
  for host in $C3_HOST $RESTS $BROKERS $CONTROLLERS; do
    if [ "$host" = "$C3_HOST" ]; then unit=confluent-control-center; elif [[ " $RESTS " = *" $host "* ]]; then unit=confluent-kafka-rest; else unit=confluent-server; fi
    ssh_run "$host" "sudo systemctl stop $unit; sudo systemctl reset-failed $unit 2>/dev/null; true"
    result=$(ssh_run "$host" "systemctl is-active $unit")
    if [ "$result" = inactive ]; then ok "$host $unit=$result"; else fail "$host $unit=$result"; fi
  done
  [ "$FAIL_COUNT" = 0 ] || die "有服務停不下來"

  section "26.4 第 3 步：清資料（find -delete：rm -rf dir/* 漏隱藏檔、萬用字元由 cpuser 展開時讀不到 0750 的目錄）"
  for host in $CONTROLLERS $BROKERS; do
    result=$(ssh_run "$host" 'sudo find /var/lib/kafka/data -mindepth 1 -delete; sudo find /var/lib/kafka/data -mindepth 1 | wc -l')
    if [ "$result" = 0 ]; then ok "$host /var/lib/kafka/data 剩 0 個"; else fail "$host /var/lib/kafka/data 剩 $result 個"; fi
  done
  result=$(ssh_run "$C3_HOST" 'sudo find /var/lib/confluent/control-center -mindepth 1 -maxdepth 1 -name "[0-9]*" -exec rm -rf {} +; sudo find /var/lib/confluent/control-center -mindepth 1 -maxdepth 1 -name "[0-9]*" | wc -l')
  if [ "$result" = 0 ]; then ok "$C3_HOST Streams 狀態目錄剩 0 個（prometheus、alertmanager 留著）"; else fail "$C3_HOST Streams 狀態目錄剩 $result 個"; fi
  [ "$FAIL_COUNT" = 0 ] || die "資料沒清乾淨"

  section "26.4 第 4 步：新 cluster id、格式化（帶 master key）"
  cp -p "$CONF_DIR/kraft.env" "$CONF_DIR/kraft.env.before-reset-$(date +%Y%m%d-%H%M)"
  (umask 077
   echo "CLUSTER_ID=$(kafka-storage random-uuid)"
   for host in $CONTROLLERS; do echo "DIR_ID_$host=$(kafka-storage random-uuid)"; done) > "$CONF_DIR/kraft.env"
  source "$CONF_DIR/kraft.env"; new_id=$CLUSTER_ID
  initial_controllers=$(for host in $CONTROLLERS; do dir_id_var=DIR_ID_$host
    printf '%s@%s:9093:%s,' "$(node_id_of "$host")" "$(fqdn "$host")" "${!dir_id_var}"; done | sed 's/,$//')
  # 做過第 15 站之後設定檔是密文：以 cp-kafka 跑、帶 service.env 的 master key（和 25.1、25.2 同一個寫法）
  format_storage=$(cat <<'REMOTE'
scram_args=()
if [ -f /tmp/kafka-admin.pass ]; then scram_args=(--add-scram "SCRAM-SHA-512=[name=kafka-admin,password=$(cat /tmp/kafka-admin.pass)]"); rm -f /tmp/kafka-admin.pass; fi
tool=(env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
      kafka-storage format --cluster-id "$CLUSTER_ID" --config /etc/confluent/kafka/server.properties $FORMAT_ARGS "${scram_args[@]}")
if sudo test -e /etc/confluent/service.env; then
  sudo bash -c 'set -a; . /etc/confluent/service.env; set +a; exec runuser -u cp-kafka -- env CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" "$@"' run "${tool[@]}" 2>&1 | grep -vi scram | tail -1
else
  sudo runuser -u cp-kafka -- "${tool[@]}" 2>&1 | grep -vi scram | tail -1
fi
echo "cluster.id=$(sudo sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)"
REMOTE
)
  for host in $CONTROLLERS; do
    copy_to_tmp "$host" "$SECRETS_DIR/kafka-admin.pass" || { fail "$host: scp"; continue; }
    result=$(ssh_script "$host" CLUSTER_ID="$new_id" FORMAT_ARGS="--initial-controllers $initial_controllers" <<<"$format_storage")
    ssh_run "$host" 'rm -f /tmp/kafka-admin.pass'
    case $result in *"cluster.id=$new_id") ok "$host: $(tr '\n' ' ' <<<"$result")";; *) fail "$host: $result";; esac
  done
  for host in $BROKERS; do
    result=$(ssh_script "$host" CLUSTER_ID="$new_id" FORMAT_ARGS="--no-initial-controllers" <<<"$format_storage")
    case $result in *"cluster.id=$new_id") ok "$host: $(tr '\n' ' ' <<<"$result")";; *) fail "$host: $result";; esac
  done
  [ "$FAIL_COUNT" = 0 ] || die "格式化失敗（舊的 kraft.env 另存在 $CONF_DIR/kraft.env.before-reset-*）"
  ok "新的 cluster id：$new_id（舊的：$old_id）"

  section "26.4 第 5 步：啟動 controller、broker，等 quorum 與 MDS"
  for host in $CONTROLLERS; do ssh_run "$host" 'sudo systemctl start confluent-server'; done
  for round in $(seq 1 60); do
    kafka-metadata-quorum --bootstrap-controller "$(host_port_list 9093 $CONTROLLERS)" --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null | grep -q 'LeaderId: *[0-9]' && break
    sleep 5
  done
  [ "$round" -lt 60 ] && ok "controller quorum 有 leader（約 $((round * 5)) 秒）" || die "controller quorum 沒有 leader"
  for host in $BROKERS; do ssh_run "$host" 'sudo systemctl start confluent-server'; done
  for round in $(seq 1 72); do
    ready=0; for host in $BROKERS; do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' --cacert "$BANK_ROOT_CA" "https://$(fqdn "$host"):8090/v1/metadata/id")" = 200 ] && ready=$((ready+1)); done
    [ "$ready" = "$(wc -w <<<"$BROKERS")" ] && break
    sleep 5
  done
  [ "$ready" = "$(wc -w <<<"$BROKERS")" ] && ok "broker 的 MDS 回 200：$ready 台（約 $((round * 5)) 秒）" || die "MDS 只有 $ready 台回 200"
  result=$(curl -s --cacert "$BANK_ROOT_CA" "https://$(fqdn "${BROKERS%% *}"):8090/v1/metadata/id" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
  [ "$result" = "$new_id" ] && ok "MDS 看到的 cluster id = 新的" || die "MDS 看到的 cluster id 是 $result"

  section "26.4 第 6 步：第一條權限 svc-ops → SystemAdmin（kafka-internal 憑證，同第 11 站）"
  cli_home=$(mktemp -d)
  HOME=$cli_home confluent login --url "https://$(fqdn "${BROKERS%% *}"):8090" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
    --client-cert-path "$CERTS_DIR/kafka-internal.crt" --client-key-path "$KEYS_DIR/kafka-internal.key" >/dev/null 2>&1 || { rm -rf "$cli_home"; die "kafka-internal 登不進 MDS"; }
  if mds_write env HOME="$cli_home" confluent iam rbac role-binding create --principal User:svc-ops --role SystemAdmin --kafka-cluster "$new_id" >/dev/null; then ok "User:svc-ops SystemAdmin"
  else rm -rf "$cli_home"; die "建不了 svc-ops 的 SystemAdmin"; fi
  rm -rf "$cli_home"

  section "26.4 第 7 步：從 $dir 全部建回來"
  bash "$INSTALL_DIR/steps/23-metadata-backup.sh" restore-all "$dir" || fail "有東西沒建回來（看上面的 FAIL）"

  section "26.4 第 8 步：啟動 REST Proxy、C3"
  for host in $RESTS; do ssh_run "$host" 'sudo systemctl start confluent-kafka-rest'; done
  ssh_run "$C3_HOST" 'sudo systemctl start confluent-control-center'
  for round in $(seq 1 84); do
    rest_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' $(rest_app_curl_options) --cacert "$BANK_ROOT_CA" "https://$REST_VIP:8082/v3/clusters")
    c3_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' --cacert "$BANK_ROOT_CA" "https://$C3_FQDN:9021/")
    [ "$rest_code" = 200 ] && [ "$c3_code" = 200 ] && break
    sleep 5
  done
  if [ "$rest_code" = 200 ]; then ok "REST 經 LB 回 200"; else fail "REST 經 LB 回 $rest_code"; fi
  if [ "$c3_code" = 200 ]; then ok "C3 回 200（約 $((round * 5)) 秒）"; else fail "C3 回 $c3_code"; fi
  license_status 0
  log "接著照第 19 站驗收：bash $INSTALL_DIR/steps/19-acceptance.sh；做完請 OS 團隊收回安裝期的 sudo"
}

case $ACTION in
  status)   license_status 0; exit $?;;
  check)    license_status 1; exit $?;;
  schedule) schedule; finish_step;;
  reset)    reset_cluster; finish_step;;
  *) die "用法：bash $0 status|check|schedule|reset";;
esac
