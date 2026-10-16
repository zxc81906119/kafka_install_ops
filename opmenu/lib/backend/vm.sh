# backend/vm.sh — RHEL 9 VM 環境(2026-10-06 起以 Rocky Linux 9 容器實測,見 demo/rocky/)
# 假設:jump host 已安裝 Confluent Platform 的指令工具與 curl;各 node 用 systemd 管理服務;jump host 可 ssh 到各 node,
#       node 上的 sudo 規則只開放指定指令(systemctl restart/status、journalctl、清理日誌腳本)。
# 這裡不放任何環境值:主機、服務名、路徑全部讀 opmenu.conf / lib/defaults.sh 的 OPMENU_* 變數。
# 安全(2026-10-06):主機名稱與服務名在這裡再驗一次(不信任呼叫端);ssh 用 -- 隔開;帳密與 token 經 stdin 交給 curl,不進命令列。

be_name() { echo vm; }
be_truststore_path() { echo "$OPMENU_TRUSTSTORE"; }
be_truststore_password() { cat "$OPMENU_TRUSTSTORE_PASSWORD_FILE"; }

# ssh 到 node:同一 session 對同一 node 只認證一次(ControlMaster);認證方式由 OPMENU_SSH_AUTH 決定
#   key      金鑰(預設);jump host 帳號的金鑰,或由 AD 集中發放
#   password 用操作員登入選單時的 AD 密碼(jump host 與 node 都接 AD 時);密碼只留在選單程序記憶體,經 sshpass 餵給 ssh
_ssh() { # _ssh <主機> <遠端指令字串>;主機必須在 OPMENU_HOSTS 清單內
  local h="$1"; shift
  v_host "$h" >/dev/null || { echo "後端拒絕:主機 $h 不在 OPMENU_HOSTS" >&2; return 1; }
  [ -n "${OP_SSH_CTL:-}" ] || { OP_SSH_CTL="$(umask 077 && mktemp -d "$OPMENU_TMPDIR/opmenu-ssh.$$.XXXXXXXX")"; export OP_SSH_CTL; }
  local o=(-o ControlMaster=auto -o "ControlPath=$OP_SSH_CTL/%C" -o "ControlPersist=${OPMENU_SSH_CONTROL_PERSIST:-600}" -o ConnectTimeout=10)
  local target="${OPMENU_SSH_USER:+$OPMENU_SSH_USER@}$h"
  if [ "${OPMENU_SSH_AUTH:-key}" = password ]; then
    command -v sshpass >/dev/null || { echo "OPMENU_SSH_AUTH=password 需要安裝 sshpass" >&2; return 1; }
    SSHPASS="${OP_PASS:-}" sshpass -e ssh "${o[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 -- "$target" "$@"
  else
    ssh "${o[@]}" -o BatchMode=yes -- "$target" "$@"
  fi
}
be_cleanup() { # 離開選單時關掉所有重用的 ssh 連線
  [ -n "${OP_SSH_CTL:-}" ] || return 0
  local s; for s in "$OP_SSH_CTL"/*; do [ -S "$s" ] && ssh -o "ControlPath=$s" -O exit dummy >/dev/null 2>&1; done
  rm -rf "$OP_SSH_CTL"
}

# curl 的帳密與 Authorization 標頭用 -K - 從 stdin 讀,不出現在行程清單;值裡的 \ 與 " 先跳脫
_curl_q() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }   # curl 設定檔的值:跳脫 \ 與 "(bash 內建替換,不依賴 sed)
_mds_curl() { # _mds_curl <path> <curl 設定檔內容(多行)> [curl 參數...];MDS 可填多台(逗號分隔),逐台嘗試;401/403 算連得上,不換台
  local p="$1" cfg="$2"; shift 2; local u out
  for u in ${OPMENU_MDS_URL//,/ }; do
    out=$(printf '%s\n' "$cfg" | curl -s --max-time 10 --cacert "$OPMENU_CA_PEM" -K - "$@" "$u$p") && { printf '%s' "$out"; return 0; }
  done
  echo "MDS 全部連不上:$OPMENU_MDS_URL" >&2; return 1
}
be_mds_login() { local out t; out=$(_mds_curl /security/1.0/authenticate "user = \"$(_curl_q "$1:$2")\"" -H "Accept: application/json") || return 2; t=$(printf '%s' "$out" | grep -o '"auth_token":"[^"]*"' | cut -d'"' -f4); [ -n "$t" ] && echo "$t"; }   # 回傳 2 = MDS 連不上
be_mds() { local m="$1" p="$2" b="${3:-}"; local a=(-X "$m" -H "Content-Type: application/json" -w $'\nHTTP %{http_code}'); [ -n "$b" ] && a+=(-d "$b"); _mds_curl "$p" "header = \"Authorization: Bearer $(_curl_q "$OP_TOKEN")\"" "${a[@]}" | tee -a "$OP_LAST_RAW"; }
_bootstrap() { sudo -n -u "$OPMENU_BOOTSTRAP_USER" "$OPMENU_BOOTSTRAP_WRAPPER" "$@"; }   # 包裝腳本以專用帳號執行,操作員讀不到 certificate;sudo 規則只開放這支腳本
be_bootstrap_mds() { _bootstrap mds "$@" | tee -a "$OP_LAST_RAW"; }

be_kafka() { # 直接用 jump host 本機安裝的指令工具
  local tool="$1"; shift
  local out rc
  out=$(KAFKA_HEAP_OPTS="-Xmx256m" "$tool" --bootstrap-server "$OPMENU_BOOTSTRAP" --command-config "$OP_CLIENT_CONF" "$@" 2>&1); rc=$?
  printf '%s\n' "$out" >> "$OP_LAST_RAW"
  printf '%s\n' "$out" | grep -v "^SLF4J\|^WARNING\|is deprecated"
  return $rc
}
be_bootstrap_kafka() { _bootstrap kafka "$@" 2>&1 | grep -v "^SLF4J\|^WARNING\|is deprecated" | tee -a "$OP_LAST_RAW"; }

# <服務> 的格式:<主機>:<systemd 服務名>,例如 kafka1.bank.local:confluent-server(清單在 OPMENU_BROKER_SERVICES / OPMENU_AUX_SERVICES)
# 遠端指令只由固定字串與已驗證的值組成;數值再驗一次
be_service_restart() { local host="${1%%:*}" svc="${1##*:}"; v_any_svc "$1" >/dev/null || return 1; _ssh "$host" "sudo systemctl restart '$svc'" && echo "已重啟 $host 的 $svc"; }
be_service_logs()    { local host="${1%%:*}" svc="${1##*:}" n="${2:-50}"; v_any_svc "$1" >/dev/null || return 1; v_number "$n" >/dev/null || return 1; _ssh "$host" "sudo journalctl -u '$svc' -n $n --no-pager"; }
be_clean_logs()      { local host="${1%%:*}" d="${2:-14}"; v_host "$host" >/dev/null || return 1; v_number "$d" >/dev/null || return 1; _ssh "$host" "sudo '$OPMENU_CLEAN_LOGS_CMD' $d"; }
be_disk_usage() { for h in $OPMENU_HOSTS; do printf '%-28s ' "$h"; _ssh "$h" "df -h '$OPMENU_DATA_DIR' 2>/dev/null | tail -1 | awk '{print \"磁碟用量 \" \$5 \"  剩餘 \" \$4}'"; done; }
be_cert_list() { for f in "$OPMENU_CERT_DIR"/*.pem; do [ -f "$f" ] || continue; openssl x509 -in "$f" -noout >/dev/null 2>&1 || continue; local st; if ! openssl x509 -in "$f" -noout -checkend 0 >/dev/null; then st="已過期"; elif ! openssl x509 -in "$f" -noout -checkend 604800 >/dev/null; then st="剩不到 7 天 ⚠⚠"; elif ! openssl x509 -in "$f" -noout -checkend 2592000 >/dev/null; then st="剩不到 30 天 ⚠"; elif ! openssl x509 -in "$f" -noout -checkend 7776000 >/dev/null; then st="剩不到 90 天"; else st="90 天以上"; fi; printf '%-32s %-26s %s\n' "$(basename "$f")" "$(openssl x509 -in "$f" -noout -enddate | cut -d= -f2)" "$st"; done; }
be_hosts() { echo "$OPMENU_HOSTS"; }
be_collect_diag() { local d="$1"; mkdir -p "$d"; for h in $OPMENU_HOSTS; do _ssh "$h" "sudo journalctl -u 'confluent-*' -n 500 --no-pager" > "$d/$h.log" 2>&1; done; }

# 推算用:cluster ID(MDS 不需帳密)與 broker 主機對應的服務名
be_cluster_id() { _mds_curl /v1/metadata/id "" | grep -o "\"id\":\"[^\"]*\"" | head -1 | cut -d"\"" -f4; }

# 一般 HTTP 呼叫(Alertmanager、探測 MDS 狀態);參數同 curl
be_http() { curl -s --max-time 10 --cacert "$OPMENU_CA_PEM" "$@"; }
# Alertmanager 呼叫:設了 OPMENU_ALERTMANAGER_AUTH_FILE 就帶 Basic 帳密(帳密用 -K - 從 stdin 給 curl,不出現在行程清單)
_am_auth() { if [ -n "${OPMENU_ALERTMANAGER_AUTH_CMD:-}" ]; then bash -c "$OPMENU_ALERTMANAGER_AUTH_CMD"; elif [ -n "${OPMENU_ALERTMANAGER_AUTH_FILE:-}" ]; then cat "$OPMENU_ALERTMANAGER_AUTH_FILE"; fi; }   # 帳密來源:指令(例如向 CyberArk 取)優先,其次檔案
be_am() { local a; a=$(_am_auth); if [ -n "$a" ]; then printf 'user = "%s"\n' "$(_curl_q "$a")" | curl -s --max-time 10 --cacert "$OPMENU_CA_PEM" -K - "$@"; else be_http "$@"; fi; }
