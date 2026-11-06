#!/usr/bin/env bash
# 第 26 站：License 到期監控 —— 讀生效中的 license（JWT）到期日；每天排程檢查、寫 syslog（手把手第 26 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；裝好之後跑一次 schedule，之後由 timer 每天跑 check）
#
# 做什麼：
#   bash steps/26-license.sh status      印出類型、到期日、剩幾天（不寫 syslog）
#   bash steps/26-license.sh check       同上，另寫 syslog（tag confluent-license）；timer 跑的就是這個
#   bash steps/26-license.sh schedule    裝操作機的 systemd timer（每天 08:00 跑 check，以 root 身分）
#   bash steps/26-license.sh reset       26.4 試用期到期時重置測試／評估環境的叢集（清空資料、新 cluster id、從 23.3 的備份全部建回來）；
#                                        要輸入現在的 cluster id 確認（不互動時 RESET_CONFIRM=<cluster id>）；先取得原廠同意
# 結束碼：0 正常、2 剩不到 LICENSE_WARN_DAYS 天（預設 90，和 C3 開始提示的天數相同）、1 已過期或讀不到
#
# 原廠沒有到期日的 JMX 指標，所以自己讀：broker 把生效中的 license 存在 _confluent-command topic，
# JWT 中間那段的 exp 就是到期時間（這裡只解開、不驗簽章；簽章由 broker 驗）。
#
# 需要什麼：叢集已運作、~/conf/client-admin.properties；reset 另外要安裝期的 sudo、23 站的 svc-backup。
# 產出什麼：status、check 只讀（check 寫 syslog）；schedule 裝 timer；reset 清空叢集後建回來。
# 能不能重跑：status、check、schedule 可以；reset 每跑一次就清空一次叢集。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-status}
LICENSE_WARN_DAYS=${LICENSE_WARN_DAYS:-90}
TIMER_NAME=confluent-license-check

# read_license_claims：印出 JWT 的 payload（JSON）；讀不到就回 1
#   例：{"iss":"Confluent","exp":1795000000,"licenseType":"trial",…}
read_license_claims() {
  local jwt payload

  # 1. 從 _confluent-command 讀出最後一個 JWT（eyJ 開頭、三段用點隔開）
  jwt=$(timeout 90 kafka-console-consumer --bootstrap-server "$BROKER_TOKEN" --consumer.config "$ADMIN_CLIENT_CONF" \
    --topic _confluent-command --from-beginning --timeout-ms 20000 2>/dev/null |
    grep -a -o 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' | tail -1)

  if [ -z "$jwt" ]; then
    return 1
  fi

  # 2. 中間那段是 base64url：換回一般 base64 的字元、補 = 到 4 的倍數，再解開
  payload=$(cut -d. -f2 <<<"$jwt" | tr '_-' '/+')

  while [ $(( ${#payload} % 4 )) != 0 ]; do
    payload="$payload="
  done

  base64 -d <<<"$payload" 2>/dev/null
}

# write_syslog <要不要寫：0|1> <優先度> <訊息>
write_syslog() {
  if [ "$1" = 1 ]; then
    logger -t confluent-license -p "$2" "$3"
  fi
}

# license_status <要不要寫 syslog：0|1>
license_status() {
  local to_syslog=$1
  local claims expires_at="" license_type days_left message

  section "26.1 生效中的 license"

  # 1. 讀 JWT、取到期時間（exp 是 Unix 秒數）
  if claims=$(read_license_claims); then
    expires_at=$(grep -o '"exp":[0-9]*' <<<"$claims" | cut -d: -f2)
  fi

  if [ -z "$expires_at" ]; then
    write_syslog "$to_syslog" user.err "license 讀不到（_confluent-command 沒有 JWT 或連不上 broker）"
    fail "license 讀不到（_confluent-command 沒有 JWT 或連不上 broker）"
    return 1
  fi

  # 2. 類型、剩幾天
  license_type=$(grep -o '"licenseType":"[^"]*"' <<<"$claims" | cut -d'"' -f4)
  days_left=$(( (expires_at - $(date +%s)) / 86400 ))
  message="license ${license_type:-unknown} 到期 $(date -d "@$expires_at" +%F)，剩 $days_left 天"

  # 3. 已過期 → err、1；剩不到 LICENSE_WARN_DAYS 天 → warning、2；其他 → info、0
  if [ "$days_left" -lt 0 ]; then
    write_syslog "$to_syslog" user.err "已過期：$message"
    fail "已過期：$message"
    return 1
  fi

  if [ "$days_left" -lt "$LICENSE_WARN_DAYS" ]; then
    write_syslog "$to_syslog" user.warning "快到期：$message"
    warn "快到期：$message（不到 $LICENSE_WARN_DAYS 天）"
    return 2
  fi

  write_syslog "$to_syslog" user.info "$message"
  ok "$message"
}

# 26.2 排程：操作機的 systemd timer；「快到期」(rc 2) 不算服務失敗，告警看 syslog
schedule() {
  local service_file=/etc/systemd/system/$TIMER_NAME.service
  local timer_file=/etc/systemd/system/$TIMER_NAME.timer
  local next_run last_syslog

  section "26.2 每天 08:00 檢查（systemd timer：$TIMER_NAME）"

  # 1. service：跑一次 check；結束碼 2（快到期）不算失敗
  cat > "$service_file" <<EOF
[Unit]
Description=Confluent license expiry check

[Service]
Type=oneshot
User=$(id -un)
ExecStart=/bin/bash $INSTALL_DIR/steps/26-license.sh check
SuccessExitStatus=2
EOF

  # 2. timer：每天 08:00；關機錯過的話開機後補跑（Persistent）
  cat > "$timer_file" <<'EOF'
[Unit]
Description=Daily Confluent license expiry check

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # 3. 啟用 timer，並立刻跑一次
  systemctl daemon-reload

  if ! systemctl enable --now "$TIMER_NAME.timer" >/dev/null 2>&1; then
    die "timer 啟用失敗"
  fi

  if ! systemctl start "$TIMER_NAME.service"; then
    fail "第一次檢查失敗（看 journalctl -u $TIMER_NAME）"
  fi

  # 4. 下次什麼時候跑、syslog 最新的一行
  next_run=$(systemctl show "$TIMER_NAME.timer" -p NextElapseUSecRealtime --value)
  last_syslog=$(journalctl -t confluent-license -n 1 --no-pager -o cat)
  ok "下次執行：$next_run"
  ok "syslog：$last_syslog"
}

# scram_users_without_password <備份目錄>：有 SCRAM、但 ~/secrets 沒有密碼檔的帳號，用空白隔開
#   輸入（users.txt）：SCRAM credential configs for user-principal 'app-orders-a' are SCRAM-SHA-512=iterations=8192
#   輸出：app-inventory-a app-inventory-b
scram_users_without_password() {
  local user

  for user in $(grep -o "SCRAM credential configs for user-principal '[^']*'" "$1/users.txt" | cut -d"'" -f2); do
    if [ ! -s "$SECRETS_DIR/$user.pass" ]; then
      echo "$user"
    fi
  done | paste -sd' '
}

# initial_controllers_value：kafka-storage format --initial-controllers 要的值（讀 kraft.env 的 DIR_ID_<主機>）
#   例：1@kc01.poc.lab:9093:AAA,2@kc02.poc.lab:9093:BBB,3@kc03.poc.lab:9093:CCC
initial_controllers_value() {
  local host dir_id_var

  for host in $CONTROLLERS; do
    dir_id_var=DIR_ID_$host
    printf '%s@%s:9093:%s,' "$(node_id_of "$host")" "$(fqdn "$host")" "${!dir_id_var}"
  done | sed 's/,$//'
}

# mds_ready_count：broker 裡 MDS 回 200 的台數，例：4
mds_ready_count() {
  local host code url
  local ready=0

  for host in $BROKERS; do
    url=https://$(fqdn "$host"):8090/v1/metadata/id
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' --cacert "$BANK_ROOT_CA" "$url")

    if [ "$code" = 200 ]; then
      ready=$((ready + 1))
    fi
  done

  echo "$ready"
}

# 做過第 15 站之後設定檔是密文：以 cp-kafka 跑、帶 service.env 的 master key（和 25.1、25.2 同一個寫法）
# controller 另外寫入 kafka-admin：密碼檔先 copy_to_tmp 到那台，讀完就刪
FORMAT_STORAGE=$(cat <<'EOF'
# 1. 有密碼檔（controller）就帶 --add-scram，讀完就刪
scram_args=()

if [ -f /tmp/kafka-admin.pass ]; then
  scram_args=(--add-scram "SCRAM-SHA-512=[name=kafka-admin,password=$(cat /tmp/kafka-admin.pass)]")
  rm -f /tmp/kafka-admin.pass
fi

# 2. 格式化（scram 那一行不印）
# shellcheck disable=SC2206  # FORMAT_ARGS 要拆成多個參數
tool=(
  env
  JAVA_HOME=/opt/java/current
  KAFKA_HEAP_OPTS=-Xmx256m
  KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
  kafka-storage format
  --cluster-id "$CLUSTER_ID"
  --config /etc/confluent/kafka/server.properties
  $FORMAT_ARGS
  "${scram_args[@]}"
)

if sudo test -e /etc/confluent/service.env; then
  sudo bash -c '
    set -a
    . /etc/confluent/service.env
    set +a
    exec runuser -u cp-kafka -- env CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" "$@"
  ' run "${tool[@]}" 2>&1 | grep -vi scram | tail -1
else
  sudo runuser -u cp-kafka -- "${tool[@]}" 2>&1 | grep -vi scram | tail -1
fi

# 3. 寫進 meta.properties 的 cluster id
echo "cluster.id=$(sudo sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)"
EOF
)

# 26.4 試用期到期、原廠來不及給延長 license 時，重置「測試／評估」環境的叢集（先取得原廠同意）：
#   備份 → 停服務 → 清資料 → 新 cluster id 格式化 → 啟動、svc-ops 第一條權限 → 從備份全部建回來 → REST、C3 → license
#   會清空訊息、consumer 讀到的位置、稽核 topic 的舊紀錄；需要安裝期的 sudo（OS 團隊臨時開）。
#   要確認：互動時輸入現在的 cluster id；不互動時用環境變數 RESET_CONFIRM=<現在的 cluster id>。
reset_cluster() {
  local old_id new_id dir host unit result round ready broker_count leader_found
  local initial_controllers missing cli_home rest_code c3_code quorum_status
  local topic_count principal_count acl_count c3_streams_find mds_url

  if [ ! -s "$CONF_DIR/kraft.env" ]; then
    die "找不到 $CONF_DIR/kraft.env"
  fi

  old_id=$(sed -n 's/^CLUSTER_ID=//p' "$CONF_DIR/kraft.env")
  section "26.4 重置叢集 $old_id（會清空所有訊息；只用在測試／評估環境，先取得原廠同意）"

  if [ -t 0 ]; then
    if [ -z "${RESET_CONFIRM:-}" ]; then
      read -r -p "確定要重置就輸入現在的 cluster id：" RESET_CONFIRM
    fi
  fi

  if [ "${RESET_CONFIRM:-}" != "$old_id" ]; then
    die "沒有確認（RESET_CONFIRM 不是現在的 cluster id），不重置"
  fi

  # 第 1 步：備份；每個 SCRAM 帳號在 ~/secrets 有沒有密碼檔
  section "26.4 第 1 步：備份（23.3）"

  if ! bash "$INSTALL_DIR/steps/23-metadata-backup.sh" run; then
    die "備份失敗，不重置"
  fi

  dir=$(ls -d "$HOME/backup/metadata"/20* | tail -1)
  missing=$(scram_users_without_password "$dir")

  # 27.6 已下線的帳號（密碼被覆寫、密碼檔已刪）也會列在這裡，本來就不該建回來，所以不擋（手把手 26.4）
  if [ -n "$missing" ]; then
    warn "這些 SCRAM 帳號沒有密碼檔、重置後不會建回來：$missing（27.6 已下線的帳號本來就沒有密碼檔，不是失敗；還在用的帳號要先補 $SECRETS_DIR/<帳號>.pass，或之後另外發新密碼）"
  fi

  topic_count=$(awk '/^Topic:/ {c++} END {print c + 0}' "$dir/topics.txt")
  principal_count=$(awk '/^== / {c++} END {print c + 0}' "$dir/rbac.txt")
  acl_count=$(awk '/\|/ {c++} END {print c + 0}' "$dir/acls.txt")
  ok "備份 $dir（topic $topic_count、principal $principal_count、ACL $acl_count）"

  # 第 2 步：Java 收到停止訊號以 143 結束、被標成 failed，所以順手 reset-failed
  section "26.4 第 2 步：停服務（C3 → REST → broker → controller）"

  for host in $C3_HOST $RESTS $BROKERS $CONTROLLERS; do
    unit=$(unit_of "$host")
    ssh_run "$host" "sudo systemctl stop $unit"
    ssh_run "$host" "sudo systemctl reset-failed $unit 2>/dev/null"
    result=$(ssh_run "$host" "systemctl is-active $unit")

    if [ "$result" = inactive ]; then
      ok "$host $unit=$result"
    else
      fail "$host $unit=$result"
    fi
  done

  if [ "$FAIL_COUNT" != 0 ]; then
    die "有服務停不下來"
  fi

  # 第 3 步：清 controller、broker 的資料目錄與 C3 的 Streams 狀態（數字開頭的目錄）
  section "26.4 第 3 步：清資料（find -delete：rm -rf dir/* 漏隱藏檔、萬用字元由 cpuser 展開時讀不到 0750 的目錄）"

  for host in $CONTROLLERS $BROKERS; do
    ssh_run "$host" 'sudo find /var/lib/kafka/data -mindepth 1 -delete'
    result=$(ssh_run "$host" 'sudo find /var/lib/kafka/data -mindepth 1 | wc -l')

    if [ "$result" = 0 ]; then
      ok "$host /var/lib/kafka/data 剩 0 個"
    else
      fail "$host /var/lib/kafka/data 剩 $result 個"
    fi
  done

  c3_streams_find='sudo find /var/lib/confluent/control-center -mindepth 1 -maxdepth 1 -name "[0-9]*"'
  ssh_run "$C3_HOST" "$c3_streams_find -exec rm -rf {} +"
  result=$(ssh_run "$C3_HOST" "$c3_streams_find | wc -l")

  if [ "$result" = 0 ]; then
    ok "$C3_HOST Streams 狀態目錄剩 0 個（prometheus、alertmanager 留著）"
  else
    fail "$C3_HOST Streams 狀態目錄剩 $result 個"
  fi

  if [ "$FAIL_COUNT" != 0 ]; then
    die "資料沒清乾淨"
  fi

  # 第 4 步：舊的 kraft.env 另存；新的 cluster id 與 controller 的 directory id（0600）；格式化
  section "26.4 第 4 步：新 cluster id、格式化（帶 master key）"
  cp -p "$CONF_DIR/kraft.env" "$CONF_DIR/kraft.env.before-reset-$(date +%Y%m%d-%H%M)"
  install -m 0600 /dev/null "$CONF_DIR/kraft.env"
  echo "CLUSTER_ID=$(kafka-storage random-uuid)" >> "$CONF_DIR/kraft.env"

  for host in $CONTROLLERS; do
    echo "DIR_ID_$host=$(kafka-storage random-uuid)" >> "$CONF_DIR/kraft.env"
  done

  source "$CONF_DIR/kraft.env"
  new_id=$CLUSTER_ID
  initial_controllers=$(initial_controllers_value)

  for host in $CONTROLLERS; do
    if ! copy_to_tmp "$host" "$SECRETS_DIR/kafka-admin.pass"; then
      fail "$host: scp"
      continue
    fi

    result=$(ssh_script "$host" CLUSTER_ID="$new_id" \
      FORMAT_ARGS="--initial-controllers $initial_controllers" <<<"$FORMAT_STORAGE")
    ssh_run "$host" 'rm -f /tmp/kafka-admin.pass'

    case $result in
      *"cluster.id=$new_id")
        ok "$host: $(tr '\n' ' ' <<<"$result")"
        ;;
      *)
        fail "$host: $result"
        ;;
    esac
  done

  for host in $BROKERS; do
    result=$(ssh_script "$host" CLUSTER_ID="$new_id" FORMAT_ARGS="--no-initial-controllers" <<<"$FORMAT_STORAGE")

    case $result in
      *"cluster.id=$new_id")
        ok "$host: $(tr '\n' ' ' <<<"$result")"
        ;;
      *)
        fail "$host: $result"
        ;;
    esac
  done

  if [ "$FAIL_COUNT" != 0 ]; then
    die "格式化失敗（舊的 kraft.env 另存在 $CONF_DIR/kraft.env.before-reset-*）"
  fi

  ok "新的 cluster id：$new_id（舊的：$old_id）"

  # 第 5 步：啟動 controller，等 quorum 有 leader（每 5 秒看一次，最多 60 次）
  section "26.4 第 5 步：啟動 controller、broker，等 quorum 與 MDS"

  for host in $CONTROLLERS; do
    ssh_run "$host" 'sudo systemctl start confluent-server'
  done

  leader_found=no

  for round in $(seq 1 60); do
    quorum_status=$(kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" \
      --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null)

    if grep -q 'LeaderId: *[0-9]' <<<"$quorum_status"; then
      leader_found=yes
      break
    fi

    sleep 5
  done

  if [ "$leader_found" = yes ]; then
    ok "controller quorum 有 leader（約 $((round * 5)) 秒）"
  else
    die "controller quorum 沒有 leader"
  fi

  # 啟動 broker，等每台 MDS 都回 200（每 5 秒看一次，最多 72 次）
  for host in $BROKERS; do
    ssh_run "$host" 'sudo systemctl start confluent-server'
  done

  broker_count=$(wc -w <<<"$BROKERS")

  for round in $(seq 1 72); do
    ready=$(mds_ready_count)

    if [ "$ready" = "$broker_count" ]; then
      break
    fi

    sleep 5
  done

  if [ "$ready" = "$broker_count" ]; then
    ok "broker 的 MDS 回 200：$ready 台（約 $((round * 5)) 秒）"
  else
    die "MDS 只有 $ready 台回 200"
  fi

  # MDS 看到的要是新的 cluster id
  mds_url=https://$(fqdn "${BROKERS%% *}"):8090
  result=$(curl -s --cacert "$BANK_ROOT_CA" "$mds_url/v1/metadata/id" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

  if [ "$result" = "$new_id" ]; then
    ok "MDS 看到的 cluster id = 新的"
  else
    die "MDS 看到的 cluster id 是 $result"
  fi

  # 第 6 步：叢集剛起來一條 binding 都沒有；super.users 只有 kafka-internal，只有它能寫第一條
  section "26.4 第 6 步：第一條權限 svc-ops → SystemAdmin（kafka-internal 憑證，同第 11 站）"
  cli_home=$(mktemp -d)

  if ! HOME=$cli_home confluent login --url "$mds_url" \
    --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
    --client-cert-path "$CERTS_DIR/kafka-internal.crt" \
    --client-key-path "$KEYS_DIR/kafka-internal.key" >/dev/null 2>&1; then
    rm -rf "$cli_home"
    die "kafka-internal 登不進 MDS"
  fi

  if mds_write env HOME="$cli_home" confluent iam rbac role-binding create \
       --principal User:svc-ops --role SystemAdmin --kafka-cluster "$new_id" >/dev/null; then
    ok "User:svc-ops SystemAdmin"
  else
    rm -rf "$cli_home"
    die "建不了 svc-ops 的 SystemAdmin"
  fi

  rm -rf "$cli_home"

  # 第 7 步：從第 1 步的備份全部建回來
  section "26.4 第 7 步：從 $dir 全部建回來"

  if ! bash "$INSTALL_DIR/steps/23-metadata-backup.sh" restore-all "$dir"; then
    fail "有東西沒建回來（看上面的 FAIL）"
  fi

  # 第 8 步：啟動 REST Proxy、C3，等兩個都回 200（每 5 秒看一次，最多 84 次）
  section "26.4 第 8 步：啟動 REST Proxy、C3"

  for host in $RESTS; do
    ssh_run "$host" 'sudo systemctl start confluent-kafka-rest'
  done

  ssh_run "$C3_HOST" 'sudo systemctl start confluent-control-center'

  for round in $(seq 1 84); do
    rest_code=$(rest_app_curl -s -o /dev/null -m 5 -w '%{http_code}' --cacert "$BANK_ROOT_CA" \
      "https://$REST_VIP:8082/v3/clusters")
    c3_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' --cacert "$BANK_ROOT_CA" "https://$C3_FQDN:9021/")

    if [ "$rest_code" = 200 ]; then
      if [ "$c3_code" = 200 ]; then
        break
      fi
    fi

    sleep 5
  done

  if [ "$rest_code" = 200 ]; then
    ok "REST 經 LB 回 200"
  else
    fail "REST 經 LB 回 $rest_code"
  fi

  if [ "$c3_code" = 200 ]; then
    ok "C3 回 200（約 $((round * 5)) 秒）"
  else
    fail "C3 回 $c3_code"
  fi

  license_status 0
  log "接著照第 19 站驗收：bash $INSTALL_DIR/steps/19-acceptance.sh；做完請 OS 團隊收回安裝期的 sudo"
}

case $ACTION in
  status)
    license_status 0
    exit $?
    ;;
  check)
    license_status 1
    exit $?
    ;;
  schedule)
    schedule
    finish_step
    ;;
  reset)
    reset_cluster
    finish_step
    ;;
  *)
    usage='status|check|schedule|reset'
    die "用法：bash $0 $usage"
    ;;
esac
