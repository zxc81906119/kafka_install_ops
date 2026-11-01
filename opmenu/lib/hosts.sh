# hosts.sh — ssh 到各主機做事:重啟、看日誌、磁碟、收集診斷;憑證到期日。
# 操作機(人員經 PSMP 登入就是 root)以 cpuser ssh 到各主機(和安裝同一個帳號、同一把金鑰),私鑰是檔案 OPMENU_SSH_KEY_FILE
# (操作機獨立 file system 上,root 0400;沒有 ssh-agent、不從保管庫取),主機金鑰只信管理員建的 OPMENU_KNOWN_HOSTS。
# 主機上 cpuser 的 sudo 只開放逐一列出的寫法(/etc/sudoers.d/cpuser-ops):sudoers 比對完整的參數,所以這裡的 sudo 寫法必須固定:
#   sudo -n systemctl restart <服務>
#   sudo -n journalctl -u <服務> -n 200 --no-pager        (行數固定 _JOURNAL_LINES;要少看幾行在本機 tail,不改遠端的參數)
# 改這裡的 sudo 寫法,就要同步改 install/steps/16-opmenu.sh 的 sudoers 規則與手把手 16.4,並跑 tests/test-sudo-forms.sh。
# 主機名稱與服務名在這裡再驗一次(不信任呼叫端);遠端指令只由固定字串與已驗證的值組成;ssh 用 -- 隔開。
# 碰主機的 be_* 函式（重啟、日誌、磁碟、診斷）第一行都先呼叫 core_host_gate（lib/common.sh 的主機權限閘門）。
#
# <服務> 的格式:<主機>:<systemd 服務名>,例如 kb01.poc.lab:confluent-server(清單在 OPMENU_BROKER_SERVICES / OPMENU_AUX_SERVICES)

_JOURNAL_LINES=200   # 遠端 journalctl 的固定行數(要和 sudoers 規則一致)

# _ssh <主機> <遠端指令字串>：以 cpuser ssh 到主機執行指令
#   主機必須在 OPMENU_HOSTS 清單內；同一次登入對同一台主機只認證一次（ControlMaster：之後的 ssh 重用同一條連線）
_ssh() {
  local host="$1"
  shift

  # 1. 主機要在清單內
  if ! v_host "$host" > /dev/null; then
    echo "後端拒絕:主機 $host 不在 OPMENU_HOSTS" >&2
    return 1
  fi

  # 2. 這次登入第一次 ssh：建一個只有自己讀得到的目錄放重用的連線
  if [ -z "${OP_SSH_CTL:-}" ]; then
    OP_SSH_CTL=$(umask 077 && mktemp -d "$OPMENU_TMPDIR/opmenu-ssh.$$.XXXXXXXX")
    export OP_SSH_CTL
  fi

  # 3. ssh 的選項：重用連線、10 秒連不上就放棄、不問任何問題、只信 OPMENU_KNOWN_HOSTS 裡的主機金鑰、只用指定的私鑰
  local options=(
    -o ControlMaster=auto
    -o "ControlPath=$OP_SSH_CTL/%C"
    -o "ControlPersist=${OPMENU_SSH_CONTROL_PERSIST:-600}"
    -o ConnectTimeout=10
    -o BatchMode=yes
    -o "UserKnownHostsFile=$OPMENU_KNOWN_HOSTS"
    -o StrictHostKeyChecking=yes
    -i "$OPMENU_SSH_KEY_FILE"
    -o IdentitiesOnly=yes
    -o IdentityAgent=none
  )

  ssh "${options[@]}" -- "${OPMENU_SSH_USER}@$host" "$@"
}

# be_cleanup：離開選單時關掉所有重用的 ssh 連線、刪掉放連線的目錄
be_cleanup() {
  local socket

  if [ -z "${OP_SSH_CTL:-}" ]; then
    return 0
  fi

  for socket in "$OP_SSH_CTL"/*; do
    if [ -S "$socket" ]; then
      ssh -o "ControlPath=$socket" -O exit dummy > /dev/null 2>&1
    fi
  done

  rm -rf "$OP_SSH_CTL"
}

# be_service_restart <主機:服務>：ssh 到那台主機重啟服務，再確認它是 active
#   例：be_service_restart kb01.poc.lab:confluent-server
#   主機上的 sudo 規則（/etc/sudoers.d/cpuser-ops）只允許 "systemctl restart <服務>" 這個固定寫法，改寫法要同步改規則
be_service_restart() {
  local service="$1"

  # 碰主機前先過權限閘門（見 common.sh 的 core_host_gate）
  if ! core_host_gate; then
    return 1
  fi

  # 服務必須在設定檔的清單內（不信任呼叫端傳來的值）
  if ! v_any_svc "$service" > /dev/null; then
    return 1
  fi

  # 拆開「主機:服務」：冒號前是主機，冒號後是服務名
  local host svc
  host=$(echo "$service" | cut -d: -f1)
  svc=$(echo "$service" | cut -d: -f2)

  # 重啟，再確認是 active（兩個都要成功）
  if ! _ssh "$host" "sudo -n systemctl restart '$svc' && systemctl is-active '$svc'"; then
    echo "重啟 $host 的 $svc 失敗（見上方訊息）"
    return 1
  fi

  echo "已重啟 $host 的 $svc"
  return 0
}

# be_service_logs <主機:服務> [行數]：那個服務最近幾行日誌（預設 50，最多 _JOURNAL_LINES）
#   遠端一律讀固定的 _JOURNAL_LINES 行（sudo 規則只允許這個寫法），要少看幾行在本機用 tail 切
be_service_logs() {
  local service="$1"
  local lines="${2:-50}"

  if ! core_host_gate; then
    return 1
  fi

  if ! v_any_svc "$service" > /dev/null; then
    return 1
  fi

  if ! v_number "$lines" > /dev/null; then
    return 1
  fi

  if [ "$lines" -gt "$_JOURNAL_LINES" ]; then
    echo "(一次最多看 $_JOURNAL_LINES 行,改看 $_JOURNAL_LINES 行)" >&2
    lines=$_JOURNAL_LINES
  fi

  local host svc
  host=$(echo "$service" | cut -d: -f1)
  svc=$(echo "$service" | cut -d: -f2)

  _ssh "$host" "sudo -n journalctl -u '$svc' -n $_JOURNAL_LINES --no-pager | tail -n $lines"
}

# be_disk_usage：每台主機印一行資料目錄（OPMENU_DATA_DIR）的用量與剩餘空間
#   例：kb01.poc.lab                 磁碟用量 5%  剩餘 968G
be_disk_usage() {
  local host

  if ! core_host_gate; then
    return 1
  fi

  for host in $OPMENU_HOSTS; do
    printf '%-28s ' "$host"
    _ssh "$host" "df -h '$OPMENU_DATA_DIR' 2>/dev/null | tail -1 | awk '{print \"磁碟用量 \" \$5 \"  剩餘 \" \$4}'"
  done
}

# _host_units <主機>：這台主機上選單管得到的 systemd 服務（broker／輔助服務清單裡這台的，加上 controller 主機的 confluent-server）
#   例：_host_units kb01.poc.lab → confluent-server
_host_units() {
  local host="$1"
  local service units=""

  for service in $OPMENU_BROKER_SERVICES ${OPMENU_AUX_SERVICES:-}; do
    if [ "$(echo "$service" | cut -d: -f1)" = "$host" ]; then
      units="$units$(echo "$service" | cut -d: -f2) "
    fi
  done

  if _in_words "$host" "${OPMENU_CONTROLLER_HOSTS:-}"; then
    units="${units}confluent-server "
  fi

  echo "$units"
}

# be_collect_diag <目錄>：每台主機一個 <主機>.log，裡面是這台每個服務最近 _JOURNAL_LINES 行日誌（逐一服務收，不用萬用字元）
be_collect_diag() {
  local dir="$1"
  local host unit

  if ! core_host_gate; then
    return 1
  fi

  mkdir -p "$dir"

  for host in $OPMENU_HOSTS; do
    : > "$dir/$host.log"

    for unit in $(_host_units "$host"); do
      {
        echo "== $unit"
        _ssh "$host" "sudo -n journalctl -u '$unit' -n $_JOURNAL_LINES --no-pager"
      } >> "$dir/$host.log" 2>&1
    done
  done
}

# be_hosts：選單管得到的主機清單
be_hosts() {
  echo "$OPMENU_HOSTS"
}

# be_lb_connections <主機>：那台 8082 上從負載平衡進來的連線數；沒設 OPMENU_LB_HOST（或查不到它的 IP）就什麼都不印（不檢查）
be_lb_connections() {
  local host="$1"
  local lb_ip

  if [ -z "${OPMENU_LB_HOST:-}" ]; then
    return 0
  fi

  lb_ip=$(getent hosts "$OPMENU_LB_HOST" | awk '{print $1}')
  if [ -z "$lb_ip" ]; then
    return 0
  fi

  _ssh "$host" "ss -Htn state established '( sport = :8082 )'" | grep -c " $lb_ip:"
}

# _tls_endpoints：17 要檢查哪些端點出示的憑證（主機:埠，空白隔開）
#   OPMENU_TLS_ENDPOINTS 有設就用它；沒設就由服務清單推算：controller 9093、broker 9092／9095／8090、REST 8082、C3 9021
_tls_endpoints() {
  if [ -n "${OPMENU_TLS_ENDPOINTS:-}" ]; then
    echo "$OPMENU_TLS_ENDPOINTS"
    return
  fi

  local host service list=""

  for host in ${OPMENU_CONTROLLER_HOSTS:-}; do
    list="$list $host:9093"
  done

  for service in $OPMENU_BROKER_SERVICES; do
    host=$(echo "$service" | cut -d: -f1)
    list="$list $host:9092 $host:9095 $host:8090"
  done

  for service in ${OPMENU_AUX_SERVICES:-}; do
    host=$(echo "$service" | cut -d: -f1)

    case "$(echo "$service" | cut -d: -f2)" in
      confluent-kafka-rest)     list="$list $host:8082" ;;
      confluent-control-center) list="$list $host:9021" ;;
    esac
  done

  echo $list
}

# be_cert_list：各端點「實際出示」的憑證（不是操作機上的檔案）：憑證名稱、簽發者、到期日、還剩多久
be_cert_list() {
  local endpoint pem subject issuer end_date status

  printf '%-28s %-16s %-26s %-26s %s\n' "端點" "憑證" "簽發者" "到期" "狀態"

  for endpoint in $(_tls_endpoints); do
    # 1. 連過去拿對方出示的憑證（-servername 用主機名稱）
    pem=$(openssl s_client -connect "$endpoint" -servername "$(echo "$endpoint" | cut -d: -f1)" < /dev/null 2> /dev/null | openssl x509 2> /dev/null)

    if [ -z "$pem" ]; then
      printf '%-28s %s\n' "$endpoint" "連不上或沒有出示憑證"
      continue
    fi

    # 2. 憑證名稱（CN）、簽發者、到期日
    subject=$(echo "$pem" | openssl x509 -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')
    issuer=$(echo "$pem" | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')
    end_date=$(echo "$pem" | openssl x509 -noout -enddate | cut -d= -f2)

    # 3. 還剩多久（-checkend <秒>：那麼多秒之後還有效就回 0）
    status=$(_cert_status "$pem")

    printf '%-28s %-16s %-26s %-26s %s\n' "$endpoint" "$subject" "$issuer" "$end_date" "$status"
  done
}

# _cert_status <PEM>：已過期、剩不到 7 天、剩不到 30 天，或 30 天以上
_cert_status() {
  local pem="$1"

  if ! echo "$pem" | openssl x509 -noout -checkend 0 > /dev/null; then
    echo "已過期"
  elif ! echo "$pem" | openssl x509 -noout -checkend 604800 > /dev/null; then
    echo "剩不到 7 天 ⚠⚠"
  elif ! echo "$pem" | openssl x509 -noout -checkend 2592000 > /dev/null; then
    echo "剩不到 30 天 ⚠（該換發了）"
  else
    echo "30 天以上"
  fi
}
