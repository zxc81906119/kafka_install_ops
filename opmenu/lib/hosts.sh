# hosts.sh — ssh 到各主機做事:重啟、看日誌、磁碟、收集診斷;憑證到期日。
# 操作機(人員經 PSMP 登入就是 root)以 cpuser ssh 到各主機(和安裝同一個帳號、同一把金鑰),私鑰是檔案 OPMENU_SSH_KEY_FILE
# (操作機獨立 file system 上,root 0400;沒有 ssh-agent、不從保管庫取),主機金鑰只信管理員建的 OPMENU_KNOWN_HOSTS。
# 主機上 cpuser 的 sudo 只開放逐一列出的寫法(/etc/sudoers.d/cpuser-ops):sudoers 比對完整的參數,所以這裡的 sudo 寫法必須固定:
#   sudo -n systemctl restart <服務>
#   sudo -n journalctl -u <服務> -n 200 --no-pager        (行數固定 _JOURNAL_LINES;要少看幾行在本機 tail,不改遠端的參數)
# 改這裡的 sudo 寫法,就要同步改 install/steps/16-opmenu.sh 的 sudoers 規則與手把手 16.4,並跑 tests/test-sudo-forms.sh。
# 主機名稱與服務名在這裡再驗一次(不信任呼叫端);遠端指令只由固定字串與已驗證的值組成;ssh 用 -- 隔開。

_JOURNAL_LINES=200   # 遠端 journalctl 的固定行數(要和 sudoers 規則一致)

_ssh() { # _ssh <主機> <遠端指令字串>;主機必須在 OPMENU_HOSTS 清單內;同一 session 對同一主機只認證一次(ControlMaster)
  local h="$1"; shift
  v_host "$h" >/dev/null || { echo "後端拒絕:主機 $h 不在 OPMENU_HOSTS" >&2; return 1; }
  [ -n "${OP_SSH_CTL:-}" ] || { OP_SSH_CTL="$(umask 077 && mktemp -d "$OPMENU_TMPDIR/opmenu-ssh.$$.XXXXXXXX")"; export OP_SSH_CTL; }
  local o=(-o ControlMaster=auto -o "ControlPath=$OP_SSH_CTL/%C" -o "ControlPersist=${OPMENU_SSH_CONTROL_PERSIST:-600}" -o ConnectTimeout=10 -o BatchMode=yes -o "UserKnownHostsFile=$OPMENU_KNOWN_HOSTS" -o StrictHostKeyChecking=yes -i "$OPMENU_SSH_KEY_FILE" -o IdentitiesOnly=yes -o IdentityAgent=none)
  ssh "${o[@]}" -- "${OPMENU_SSH_USER}@$h" "$@"
}
be_cleanup() { # 離開選單時關掉所有重用的 ssh 連線
  [ -n "${OP_SSH_CTL:-}" ] || return 0
  local s; for s in "$OP_SSH_CTL"/*; do [ -S "$s" ] && ssh -o "ControlPath=$s" -O exit dummy >/dev/null 2>&1; done
  rm -rf "$OP_SSH_CTL"
}

# <服務> 的格式:<主機>:<systemd 服務名>,例如 kb01.poc.lab:confluent-server(清單在 OPMENU_BROKER_SERVICES / OPMENU_AUX_SERVICES)
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
be_service_logs()    { core_host_gate || return 1; local host="${1%%:*}" svc="${1##*:}" n="${2:-50}"; v_any_svc "$1" >/dev/null || return 1; v_number "$n" >/dev/null || return 1
  [ "$n" -le "$_JOURNAL_LINES" ] || { echo "(一次最多看 $_JOURNAL_LINES 行,改看 $_JOURNAL_LINES 行)" >&2; n=$_JOURNAL_LINES; }
  _ssh "$host" "sudo -n journalctl -u '$svc' -n $_JOURNAL_LINES --no-pager | tail -n $n"; }
be_disk_usage() { core_host_gate || return 1; local h; for h in $OPMENU_HOSTS; do printf '%-28s ' "$h"; _ssh "$h" "df -h '$OPMENU_DATA_DIR' 2>/dev/null | tail -1 | awk '{print \"磁碟用量 \" \$5 \"  剩餘 \" \$4}'"; done; }
# 這台主機上選單管得到的 systemd 服務(broker/輔助服務清單 + controller 主機的 confluent-server);診斷逐一服務收集,不用萬用字元
_host_units() { local h="$1" s out=""; for s in $OPMENU_BROKER_SERVICES ${OPMENU_AUX_SERVICES:-}; do [ "${s%%:*}" = "$h" ] && out+="${s##*:} "; done
  case " ${OPMENU_CONTROLLER_HOSTS:-} " in *" $h "*) out+="confluent-server ";; esac; echo "$out"; }
be_collect_diag() { core_host_gate || return 1; local d="$1" h u; mkdir -p "$d"; for h in $OPMENU_HOSTS; do : > "$d/$h.log"
    for u in $(_host_units "$h"); do { echo "== $u"; _ssh "$h" "sudo -n journalctl -u '$u' -n $_JOURNAL_LINES --no-pager"; } >> "$d/$h.log" 2>&1; done; done; }
be_hosts() { echo "$OPMENU_HOSTS"; }
# be_lb_connections <主機>：那台 8082 上從負載平衡進來的連線數；沒設 OPMENU_LB_HOST 就不印（不檢查）
be_lb_connections() { local ip; [ -n "${OPMENU_LB_HOST:-}" ] || return 0; ip=$(getent hosts "$OPMENU_LB_HOST" | awk '{print $1}'); [ -n "$ip" ] || return 0; _ssh "$1" "ss -Htn state established '( sport = :8082 )'" | grep -c " $ip:"; }
# be_cert_list：各端點實際出示的憑證（不是操作機上的檔案）。端點清單 OPMENU_TLS_ENDPOINTS，空 = 由服務清單推算
_tls_endpoints() {
  [ -n "${OPMENU_TLS_ENDPOINTS:-}" ] && { echo "$OPMENU_TLS_ENDPOINTS"; return; }
  local host svc list=""
  for host in ${OPMENU_CONTROLLER_HOSTS:-}; do list+="$host:9093 "; done
  for svc in $OPMENU_BROKER_SERVICES; do host=${svc%%:*}; list+="$host:9092 $host:9095 $host:8090 "; done
  for svc in ${OPMENU_AUX_SERVICES:-}; do
    host=${svc%%:*}
    case ${svc##*:} in confluent-kafka-rest) list+="$host:8082 ";; confluent-control-center) list+="$host:9021 ";; esac
  done
  echo "${list% }"
}
be_cert_list() {
  local endpoint pem status subject issuer end_date
  printf '%-28s %-16s %-26s %-26s %s\n' "端點" "憑證" "簽發者" "到期" "狀態"
  for endpoint in $(_tls_endpoints); do
    pem=$(openssl s_client -connect "$endpoint" -servername "${endpoint%:*}" </dev/null 2>/dev/null | openssl x509 2>/dev/null)
    if [ -z "$pem" ]; then printf '%-28s %s\n' "$endpoint" "連不上或沒有出示憑證"; continue; fi
    subject=$(openssl x509 -noout -subject -nameopt sep_comma_plus,sname <<<"$pem" | sed 's/.*CN=\([^,]*\).*/\1/')
    issuer=$(openssl x509 -noout -issuer -nameopt sep_comma_plus,sname <<<"$pem" | sed 's/.*CN=\([^,]*\).*/\1/')
    end_date=$(openssl x509 -noout -enddate <<<"$pem" | cut -d= -f2)
    if ! openssl x509 -noout -checkend 0 <<<"$pem" >/dev/null; then status="已過期"
    elif ! openssl x509 -noout -checkend 604800 <<<"$pem" >/dev/null; then status="剩不到 7 天 ⚠⚠"
    elif ! openssl x509 -noout -checkend 2592000 <<<"$pem" >/dev/null; then status="剩不到 30 天 ⚠（該換發了）"
    else status="30 天以上"; fi
    printf '%-28s %-16s %-26s %-26s %s\n' "$endpoint" "$subject" "$issuer" "$end_date" "$status"
  done
}
