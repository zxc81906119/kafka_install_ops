# hosts.sh — ssh 到各主機做事:重啟、看日誌、磁碟、收集診斷;憑證到期日。
# 操作機以 cpadmin ssh 到各主機(和安裝同一個帳號),私鑰在 ssh-agent 裡(lib/common.sh 的 core_load_ssh_key 載入),
# 主機金鑰只信管理員建的 OPMENU_KNOWN_HOSTS;主機上 cpadmin 的 sudo 只開放 systemctl restart/status confluent-*、journalctl -u confluent-*。
# 主機名稱與服務名在這裡再驗一次(不信任呼叫端);遠端指令只由固定字串與已驗證的值組成;ssh 用 -- 隔開。

_ssh() { # _ssh <主機> <遠端指令字串>;主機必須在 OPMENU_HOSTS 清單內;同一 session 對同一主機只認證一次(ControlMaster)
  local h="$1"; shift
  v_host "$h" >/dev/null || { echo "後端拒絕:主機 $h 不在 OPMENU_HOSTS" >&2; return 1; }
  [ -n "${OP_SSH_CTL:-}" ] || { OP_SSH_CTL="$(umask 077 && mktemp -d "$OPMENU_TMPDIR/opmenu-ssh.$$.XXXXXXXX")"; export OP_SSH_CTL; }
  local o=(-o ControlMaster=auto -o "ControlPath=$OP_SSH_CTL/%C" -o "ControlPersist=${OPMENU_SSH_CONTROL_PERSIST:-600}" -o ConnectTimeout=10 -o BatchMode=yes -o "UserKnownHostsFile=$OPMENU_KNOWN_HOSTS" -o StrictHostKeyChecking=yes)
  ssh "${o[@]}" -- "${OPMENU_SSH_USER}@$h" "$@"
}
be_cleanup() { # 離開選單時關掉所有重用的 ssh 連線
  [ -n "${OP_SSH_CTL:-}" ] || return 0
  local s; for s in "$OP_SSH_CTL"/*; do [ -S "$s" ] && ssh -o "ControlPath=$s" -O exit dummy >/dev/null 2>&1; done
  rm -rf "$OP_SSH_CTL"
}

# <服務> 的格式:<主機>:<systemd 服務名>,例如 kb01.poc.lab:confluent-server(清單在 OPMENU_BROKER_SERVICES / OPMENU_AUX_SERVICES)
be_service_restart() { local host="${1%%:*}" svc="${1##*:}"; v_any_svc "$1" >/dev/null || return 1; _ssh "$host" "sudo -n systemctl restart '$svc' && systemctl is-active '$svc'" && echo "已重啟 $host 的 $svc"; }
be_service_logs()    { local host="${1%%:*}" svc="${1##*:}" n="${2:-50}"; v_any_svc "$1" >/dev/null || return 1; v_number "$n" >/dev/null || return 1; _ssh "$host" "sudo -n journalctl -u '$svc' -n $n --no-pager"; }
be_disk_usage() { local h; for h in $OPMENU_HOSTS; do printf '%-28s ' "$h"; _ssh "$h" "df -h '$OPMENU_DATA_DIR' 2>/dev/null | tail -1 | awk '{print \"磁碟用量 \" \$5 \"  剩餘 \" \$4}'"; done; }
be_collect_diag() { local d="$1" h; mkdir -p "$d"; for h in $OPMENU_HOSTS; do _ssh "$h" "sudo -n journalctl -u 'confluent-*' -n 500 --no-pager" > "$d/$h.log" 2>&1; done; }
be_hosts() { echo "$OPMENU_HOSTS"; }
be_cert_list() { local f st; for f in "$OPMENU_CERT_DIR"/*.pem "$OPMENU_CERT_DIR"/*.crt; do [ -f "$f" ] || continue; openssl x509 -in "$f" -noout >/dev/null 2>&1 || continue; if ! openssl x509 -in "$f" -noout -checkend 0 >/dev/null; then st="已過期"; elif ! openssl x509 -in "$f" -noout -checkend 604800 >/dev/null; then st="剩不到 7 天 ⚠⚠"; elif ! openssl x509 -in "$f" -noout -checkend 2592000 >/dev/null; then st="剩不到 30 天 ⚠"; elif ! openssl x509 -in "$f" -noout -checkend 7776000 >/dev/null; then st="剩不到 90 天"; else st="90 天以上"; fi; printf '%-32s %-26s %s\n' "$(basename "$f")" "$(openssl x509 -in "$f" -noout -enddate | cut -d= -f2)" "$st"; done; }
