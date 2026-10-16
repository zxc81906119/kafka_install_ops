# core.sh — 固定流程(Template):登入身分 → 選單 → ticket → 確認 → 執行 → 記錄
# 這個檔案不知道 docker 或 VM 的存在;環境相依的事都透過 be_* 介面(lib/backend/*.sh)。
#
# backend 必須提供的介面(Strategy):
#   be_name                          後端名稱
#   be_truststore_path / be_truststore_password
#   be_kafka <工具> <參數...>         以操作者身分執行 Kafka 指令工具(連線設定由 core 提供:$OP_CLIENT_CONF)
#   be_mds_login <帳號> <密碼>        用 AD 帳密向 MDS 換 token;成功印出 token,失敗回傳非 0(2 = MDS 連不上)
#   be_mds <METHOD> <path> [json]     以操作者的 token 呼叫 MDS REST;印出 "HTTP 狀態碼" 於最後一行
#   be_bootstrap_kafka <工具> <參數>  以 bootstrap 身分執行 Kafka 指令工具(緊急模式;certificate 由後端保管)
#   be_bootstrap_mds <METHOD> <path> [json]
#   be_service_restart <服務>         重啟一個服務
#   be_service_logs <服務> <行數>     顯示服務日誌
#   be_clean_logs <服務> <天數>       清理超過 N 天的應用程式日誌檔
#   be_disk_usage                    顯示各 nodedata directory 用量
#   be_cert_list                     列出 certificate 檔與到期日
#   be_hosts                         node 清單
#   be_collect_diag <輸出目錄>        收集日誌與狀態到目錄
#   be_cleanup                       (選用)離開時的清理
#
# action 的註冊方式(Command):
#   reg <編號> <層級 1-4> <需 ticket y/n> <需確認 y/n> "<標題>" "<說明>"
#   並定義函式 act_<編號>;函式內用 $OP_USER、$OP_TICKET、be_* 介面;所有使用者輸入先過 lib/validate.sh 的 v_* 函式

declare -A ACT_TITLE ACT_DESC ACT_TIER ACT_TICKET ACT_CONFIRM
ACT_IDS=()
reg() { ACT_IDS+=("$1"); ACT_TIER[$1]="$2"; ACT_TICKET[$1]="$3"; ACT_CONFIRM[$1]="$4"; ACT_TITLE[$1]="$5"; ACT_DESC[$1]="${6:-}"; }

TIER_NAME=([1]="值班查看" [2]="服務操作" [3]="變更作業" [4]="授權與緊急")
C0=$'\033[0m'; CB=$'\033[1m'; CR=$'\033[31m'; CG=$'\033[32m'; CY=$'\033[33m'; CC=$'\033[36m'

core_log() { # core_log <結果> <項目> <對象/備註>;每個欄位都先去掉控制字元與分隔符,避免輸入偽造出另一行紀錄
  mkdir -p "$(dirname "$OPMENU_LOG")"
  local line; line=$(printf '%s | %s | %s | %s | ticket=%s | sid=%s | %s | %s' "$(date '+%F %T %z')" "$OPMENU_ENV_LABEL" "${OP_USER:-?}" "$(v_sanitize_log "$2")" "${OP_TICKET:--}" "${OP_SID:--}" "$1" "$(v_sanitize_log "${3:-}")")
  printf '%s\n' "$line" >> "$OPMENU_LOG"
  if [ "${OPMENU_SYSLOG:-0}" = 1 ] && command -v logger >/dev/null; then logger -t opmenu -p auth.info -- "$line" 2>/dev/null; fi
  return 0
}

core_log_pre_login() { OP_USER="$(id -un)" core_log "$@"; }   # 還沒登入時的紀錄(操作者欄填作業系統帳號)

core_cleanup() { core_lock_release; rm -f "${OP_CLIENT_CONF:-}" "${OP_LAST_RAW:-}"; declare -F be_cleanup >/dev/null && be_cleanup; return 0; }

core_sweep_residue() { # 啟動時清掉自己上次留下的暫存檔與 ssh 連線目錄(行程被強制終止時 trap 不會跑);只清自己的、且所屬行程已不存在的
  local f pid
  for f in "$OPMENU_TMPDIR"/opmenu.*.???????? "$OPMENU_TMPDIR"/opmenu-ssh.*.????????; do
    [ -e "$f" ] && [ -O "$f" ] || continue
    pid="${f##*/opmenu}"; pid="${pid#-ssh}"; pid="${pid#.}"; pid="${pid%%.*}"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$pid/status" 2>/dev/null && continue   # 僵屍行程(沒有 init 收屍的容器會有)視為已結束
    rm -rf "$f"
  done
  return 0
}

core_identity() { # 操作者本人的 AD 帳密 → (1) 向 MDS 換 token(之後呼叫 MDS 用 token)(2) 產生只有自己能讀的 Kafka 連線設定檔(放記憶體檔案系統,離開時刪除)
  local pass="${OPMENU_PASS:-}"
  OP_SID="$(date +%s)-$$"
  if [ "${OPMENU_USER_FROM_OS:-0}" = 1 ]; then   # jump host 接 AD:身分就是登入作業系統的人,不給改(作業系統沒有把密碼交給程式,所以密碼仍要輸入)
    OP_USER="$(id -un)"; echo "操作者(作業系統登入帳號):$OP_USER"
  else
    OP_USER="${OPMENU_USER:-}"; if [ -z "$OP_USER" ]; then read -r -p "AD 帳號: " OP_USER; fi
    [[ "$OP_USER" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || { echo "${CR}帳號含不允許的字元${C0}"; exit 1; }
  fi
  if [ -z "$pass" ]; then read -r -s -p "AD 密碼: " pass; echo; fi
  umask 077
  core_sweep_residue
  OP_CLIENT_CONF="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"
  OP_LAST_RAW="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"
  trap core_cleanup EXIT
  trap 'core_cleanup; exit 130' INT
  trap 'core_cleanup; exit 143' TERM
  trap 'core_cleanup; exit 129' HUP
  cat > "$OP_CLIENT_CONF" <<EOC
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$OP_USER" password="$pass";
ssl.truststore.location=$(be_truststore_path)
ssl.truststore.type=PKCS12
ssl.truststore.password=$(be_truststore_password)
EOC
  local lrc; OP_TOKEN="$(be_mds_login "$OP_USER" "$pass")"; lrc=$?
  if [ $lrc -eq 2 ]; then echo "${CR}無法連到 MDS,請確認 cluster 狀態或通知管理員。${C0}"; core_log MDS_DOWN login ""; exit 1
  elif [ $lrc -ne 0 ]; then echo "${CR}登入失敗:帳號或密碼不正確。${C0}"; core_log AUTH_FAIL login ""; exit 1; fi
  OP_TOKEN_AT=$(date +%s)
  core_derive || { core_log DERIVE_FAIL login ""; exit 1; }
  # 密碼預設在換到 token 後就丟掉;只有 ssh 要用同一組 AD 密碼登入 node 時(OPMENU_SSH_AUTH=password)留在記憶體,不匯出、不落地
  if [ "${OPMENU_SSH_AUTH:-key}" = password ]; then OP_PASS="$pass"; fi
  unset pass
  export OP_USER OP_CLIENT_CONF OP_LAST_RAW OP_TOKEN OP_SID
}

core_require_ticket() { # 依 OPMENU_TICKET_MODE:required 必填、optional 可空、none 不問;怎麼驗由 lib/ticket/*.sh 的 ticket_check 決定
  OP_TICKET="${OPMENU_TICKET:-}"
  case "$OPMENU_TICKET_MODE" in
    none) OP_TICKET=""; export OP_TICKET; return 0;;
    optional) [ -n "$OP_TICKET" ] || read -r -p "Ticket ID(沒有可直接按 Enter): " OP_TICKET || OP_TICKET=""; [ -n "$OP_TICKET" ] || { export OP_TICKET; return 0; };;   # 讀不到輸入 = 沒有 ticket,放行
    *) while [ -z "$OP_TICKET" ]; do read -r -p "Ticket ID(例 CHG-2026-0001): " OP_TICKET || return 2; done;;   # 讀不到輸入(非互動、Ctrl-D)回傳 2 = 放棄
  esac
  local why; why=$(ticket_check "$OP_TICKET") || { echo "${CR}ticket 不接受:${why}${C0}"; OP_TICKET=""; OPMENU_TICKET=""; return 1; }
  export OP_TICKET
}

core_confirm() { # core_confirm "<將做什麼>"
  echo "${CY}將執行:$1${C0}"
  [ "${OPMENU_YES:-0}" = 1 ] && return 0
  read -r -p "確定要執行嗎?輸入 yes 繼續: " a; [ "$a" = yes ]
}

_core_run() { # 固定流程(外面包一層 core_run 負責放掉並行鎖)
  local id="$1"; shift
  [ -n "${ACT_TITLE[$id]:-}" ] || { echo "沒有這個項目:$id"; return 1; }
  echo; echo "${CB}[$id] ${ACT_TITLE[$id]}${C0}  (${TIER_NAME[${ACT_TIER[$id]}]})"
  [ -n "${ACT_DESC[$id]}" ] && echo "  ${ACT_DESC[$id]}"
  OP_TICKET=""
  if [ "${ACT_TICKET[$id]}" = y ]; then
    local trc; until core_require_ticket; do trc=$?; [ "$trc" = 2 ] && { echo "沒有 ticket,放棄"; core_log ABORT "$id ${ACT_TITLE[$id]}" "$*"; return 1; }; done
  fi
  if [ "${ACT_TICKET[$id]}" = y ]; then   # 變更類項目:先看時窗,再搶並行鎖
    if ! core_window_ok && ! _in_words "$id" "$OPMENU_WINDOW_EXEMPT"; then
      echo "${CR}目前不在允許變更的時窗內(OPMENU_CHANGE_WINDOW=$OPMENU_CHANGE_WINDOW)${C0}"; core_log BLOCKED "$id ${ACT_TITLE[$id]}" "outside change window"; return 1
    fi
    core_lock_acquire "$id ${ACT_TITLE[$id]}" || { core_log BLOCKED "$id ${ACT_TITLE[$id]}" "lock held"; return 1; }
  fi
  local rc shown t0; shown="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"; t0=$(date +%s)
  : > "$OP_LAST_RAW"
  "act_$id" "$@" 2>&1 | tee "$shown"; rc=${PIPESTATUS[0]}   # 邊執行邊顯示(項目裡的提問與確認要即時看到),同時側錄一份用來判斷結果
  local raw; raw="$(cat "$OP_LAST_RAW" "$shown")"          # 工具的原始輸出(action 可能過濾掉錯誤訊息,所以 backend 另存一份)
  rm -f "$shown"
  local note="$* [rc=$rc $(( $(date +%s) - t0 ))s]"
  if [ $rc -eq 0 ]; then
    core_log OK "$id ${ACT_TITLE[$id]}" "$note"
  elif printf '%s' "$raw" | grep -q -i "AuthorizationException\|not authorized\|Authorization failed\|HTTP 403"; then
    echo "${CR}Kafka 拒絕:你的群組沒有這項權限,請依 ticket 申請。${C0}"; core_log DENIED "$id ${ACT_TITLE[$id]}" "$note"
  elif printf '%s' "$raw" | grep -q -i "SaslAuthenticationException\|Authentication failed\|HTTP 401"; then
    if [ -n "${OP_TOKEN_AT:-}" ] && [ $(( $(date +%s) - OP_TOKEN_AT )) -ge "${OPMENU_TOKEN_TTL:-3600}" ]; then
      echo "${CR}登入已逾時(token 到期),請離開後重新登入。${C0}"; core_log TOKEN_EXPIRED "$id ${ACT_TITLE[$id]}" "$note"
    else
      echo "${CR}登入失敗:帳號或密碼不正確。${C0}"; core_log AUTH_FAIL "$id ${ACT_TITLE[$id]}" "$note"
    fi
  else
    echo "${CR}執行失敗(見上方訊息)${C0}"; core_log FAIL "$id ${ACT_TITLE[$id]}" "$note"
  fi
  return $rc
}

core_menu() {
  while true; do
    echo; echo "${CB}=== Kafka 維運操作選單  [${CR}${OPMENU_ENV_LABEL}${C0}${CB}]  後端:$(be_name)  操作者:${OP_USER} ===${C0}"
    local t
    for t in 1 2 3 4; do
      local any=0
      for id in "${ACT_IDS[@]}"; do [ "${ACT_TIER[$id]}" = "$t" ] || continue; [ $any = 0 ] && { echo "${CC}-- ${TIER_NAME[$t]} --${C0}"; any=1; }
        printf '  %s  %s%s\n' "$id" "${ACT_TITLE[$id]}" "$([ "${ACT_TICKET[$id]}" = y ] && [ "$OPMENU_TICKET_MODE" != none ] && echo '  (需 ticket)')"; done
    done
    echo "  0  離開"
    local sel rc; read -r "${OP_READ_TIMEOUT[@]}" "${OP_READ_EDIT[@]}" -p "請選擇: " sel; rc=$?
    [ "${OPMENU_DEBUG:-0}" = 1 ] && core_log DEBUG "menu-read" "rc=$rc sel=[$sel] timeout=[${OP_READ_TIMEOUT[*]}]"
    if [ $rc -gt 128 ]; then echo; echo "閒置逾時,登出"; return; elif [ $rc -ne 0 ]; then echo; echo "讀不到輸入,登出"; return; fi   # read 逾時回傳 >128;EOF 回傳 1
    sel="$(printf '%s' "$sel" | tr -cd '0-9')"   # 只取數字:方向鍵的跳脫序列、\r、空白都丟掉
    [ -z "$sel" ] && continue
    [ "$sel" = 0 ] && return
    core_run "$sel"
  done
}

core_init() {
  if [ "${1:-}" = --list ]; then for id in "${ACT_IDS[@]}"; do printf '%s\t%s\t%s\t%s\t%s\n' "$id" "${TIER_NAME[${ACT_TIER[$id]}]}" "${ACT_TICKET[$id]}" "${ACT_CONFIRM[$id]}" "${ACT_TITLE[$id]}"; done; exit 0; fi
  if [ "${1:-}" = --run ]; then shift; core_identity; core_run "$@"; exit $?; fi
  # 閒置逾時用 read -t;Git Bash(MSYS/Cygwin)的 read -t 對終端機會立刻回傳 EOF(實測 bash 5.3.15),所以那裡不用;OPMENU_IDLE_TIMEOUT=0 也可關閉
  OP_READ_TIMEOUT=(); if [ "${OPMENU_IDLE_TIMEOUT:-0}" -gt 0 ] && [[ "$OSTYPE" != msys* && "$OSTYPE" != cygwin* ]]; then OP_READ_TIMEOUT=(-t "$OPMENU_IDLE_TIMEOUT"); fi
  OP_READ_EDIT=(); [ -t 0 ] && OP_READ_EDIT=(-e)   # 終端機互動時用行編輯(方向鍵不會變成亂碼進到輸入裡)
  core_identity; core_log LOGIN "login" ""; core_menu; core_log LOGOUT "logout" ""
}

# 登入後推算沒填的設定(opmenu.conf 有填的一律優先,不覆蓋)。推算不出來就明確報錯,不猜。
# 只推算「不依賴 cluster 即時狀態」的值:
#   cluster ID   ← MDS /v1/metadata/id(不需帳密;權威來源,算錯會在 role binding 時立刻看得出來)
#   node 清單     ← OPMENU_BROKER_SERVICES、OPMENU_AUX_SERVICES 的主機 + OPMENU_CONTROLLER_HOSTS
#   replication factor 預設值 ← min(3, OPMENU_BROKER_SERVICES 的 broker 數)
# 刻意不從 cluster 推算 broker 與 node 清單:它們是重啟、ssh 的允許清單,必須是經變更管理審過的固定設定;
# 而且 broker 掛掉後就不在 cluster 的清單裡(實測),正是最需要重啟的那台會消失。
core_derive() {
  local id n
  if [ -z "${OPMENU_KAFKA_CLUSTER_ID:-}" ]; then
    id="$(be_cluster_id)"
    [ -n "$id" ] || { echo "${CR}無法從 MDS 取得 cluster ID,請在 opmenu.conf 設定 OPMENU_KAFKA_CLUSTER_ID${C0}"; return 1; }
    dd OPMENU_KAFKA_CLUSTER_ID "$id"
  fi
  [ -n "${OPMENU_BROKER_SERVICES:-}" ] || { echo "${CR}請在 opmenu.conf 設定 OPMENU_BROKER_SERVICES(可重啟的 broker,主機:服務名)${C0}"; return 1; }
  dd OPMENU_HOSTS "$(_hosts_of $OPMENU_BROKER_SERVICES ${OPMENU_AUX_SERVICES:-} ${OPMENU_CONTROLLER_HOSTS:-})"
  n=$(printf '%s\n' $OPMENU_BROKER_SERVICES | wc -l)
  if [ "${OP_SRC[OPMENU_REPLICATION]:-}" = default ] && [ "$n" -lt "$OPMENU_REPLICATION" ]; then OPMENU_REPLICATION=$n; OP_SRC[OPMENU_REPLICATION]=derived; export OPMENU_REPLICATION; fi
  return 0
}

# ── 主機類動作的權限閘門(2026-10-16)──
# 主機上的動作(重啟、看日誌、清日誌、磁碟、收集診斷)經 ssh/docker 用 node 的帳號執行;當 node 是「共用維運帳號」時,
# node 的 sudo 規則分不出是誰,任何通過 AD 驗證的人都能重啟服務。所以在碰 node 之前,用操作者本人的 token 問 MDS:
# 「我對 OPMENU_HOST_ACTION_AUTHZ 這個資源有沒有權限」(MDS 會展開 AD 群組;只能問自己,不能代別人問)。
# 任何錯誤(MDS 連不上、回應看不懂)一律視為拒絕。OPMENU_HOST_ACTION_AUTHZ 設為空字串 = 不檢查(node 用本人帳號時)。
core_host_gate() {
  [ -n "${OPMENU_HOST_ACTION_AUTHZ:-}" ] || return 0
  [ "${OP_HOST_OK:-0}" = 1 ] && return 0
  local rt rn op body out
  IFS=: read -r rt rn op <<< "$OPMENU_HOST_ACTION_AUTHZ"
  body=$(printf '{"userPrincipal":"User:%s","actions":[{"resourceType":"%s","resourceName":"%s","operation":"%s","scope":{"clusters":{"kafka-cluster":"%s"}}}]}' \
    "$OP_USER" "$rt" "$rn" "$op" "${OPMENU_KAFKA_CLUSTER_ID:-}")
  out=$(be_mds PUT /security/1.0/authorize "$body" 2>/dev/null)
  if [[ "$out" == *'["ALLOWED"]'* && "$out" == *'HTTP 200'* ]]; then OP_HOST_OK=1; return 0; fi
  # 訊息含 "Authorization failed",core 會把結果記成 DENIED
  echo "${CR}主機類動作 Authorization failed:需要叢集層級權限($OPMENU_HOST_ACTION_AUTHZ),你的群組沒有;請依 ticket 申請。${C0}"
  return 1
}

# Decorator:把後端所有「碰 node」的介面包上 core_host_gate。放在 core 而不是各項目裡,新增項目或換後端都不會漏掉。
core_guard_host_actions() {
  local f
  for f in be_service_restart be_service_logs be_clean_logs be_disk_usage be_collect_diag; do
    declare -F "$f" >/dev/null || continue
    eval "_unguarded_$(declare -f "$f")"
    eval "$f() { core_host_gate || return 1; _unguarded_$f \"\$@\"; }"
  done
}

# ── 並行鎖與變更時窗(批 B)──
_in_words() { local x; for x in $2; do [ "$x" = "$1" ] && return 0; done; return 1; }

core_run() { _core_run "$@"; local rc=$?; core_lock_release; return $rc; }

# 並行鎖:mkdir 是原子的;持有者的行程已不存在就視為過期。只在同一台跳板機有效(多台跳板機要改用共用檔案系統上的目錄)。
core_lock_acquire() { # core_lock_acquire <說明>
  local d="$OPMENU_LOCK_DIR" waited=0 holder hp
  mkdir -p "$(dirname "$d")" 2>/dev/null
  while ! ( umask 000; mkdir "$d" ) 2>/dev/null; do
    holder="$(cat "$d/info" 2>/dev/null)"; hp="${holder%% *}"
    if [ -n "$hp" ] && ! kill -0 "$hp" 2>/dev/null && [ ! -d "/proc/$hp" ]; then rm -rf "$d"; continue; fi   # 持有者不在了:過期,清掉重搶
    [ "$waited" -ge "${OPMENU_LOCK_WAIT:-0}" ] && { echo "${CR}目前有其他變更作業進行中(${holder#* }),請稍後再試${C0}"; return 1; }
    sleep 2; waited=$((waited+2))
  done
  printf '%s %s %s | %s\n' "$$" "$OP_USER" "$1" "$(date '+%F %T')" > "$d/info"; chmod 666 "$d/info" 2>/dev/null
  OP_LOCK_HELD=1
}
core_lock_release() { [ "${OP_LOCK_HELD:-0}" = 1 ] && rm -rf "$OPMENU_LOCK_DIR"; OP_LOCK_HELD=0; return 0; }

_day_num() { case "${1,,}" in mon|1) echo 1;; tue|2) echo 2;; wed|3) echo 3;; thu|4) echo 4;; fri|5) echo 5;; sat|6) echo 6;; sun|7|0) echo 7;; *) return 1;; esac; }
_day_in() { # _day_in <1-7> <規格>:規格如 "Mon-Fri"、"Sat,Sun"、"1-5"、"*"
  local d="$1" spec="$2" tok a b x; [ "$spec" = '*' ] && return 0
  local IFS=,; for tok in $spec; do
    if [[ "$tok" == *-* ]]; then
      a=$(_day_num "${tok%-*}") || continue; b=$(_day_num "${tok#*-}") || continue
      x=$a; while :; do [ "$x" = "$d" ] && return 0; [ "$x" = "$b" ] && break; x=$(( x % 7 + 1 )); done
    else a=$(_day_num "$tok") || continue; [ "$a" = "$d" ] && return 0; fi
  done; return 1
}
core_window_ok() { # 在時窗內(或沒設限)回傳 0。OPMENU_NOW_OVERRIDE="<1-7> <HH:MM>" 只有測試用(OPMENU_ALLOW_ENV_OVERRIDE=1)
  [ -n "${OPMENU_CHANGE_WINDOW:-}" ] || return 0
  local now=""; [ "${OPMENU_ALLOW_ENV_OVERRIDE:-0}" = 1 ] && now="${OPMENU_NOW_OVERRIDE:-}"
  [ -n "$now" ] || now="$(date '+%u %H:%M')"
  local dow="${now%% *}" hm="${now##* }" nm prev w days range s e sm em; local -a W
  nm=$(( 10#${hm%%:*} * 60 + 10#${hm##*:} )); prev=$(( (dow + 5) % 7 + 1 ))
  IFS=';' read -ra W <<< "$OPMENU_CHANGE_WINDOW"
  for w in "${W[@]}"; do
    w="${w#"${w%%[![:space:]]*}"}"; w="${w%"${w##*[![:space:]]}"}"; [ -n "$w" ] || continue
    days="${w%% *}"; range="${w##* }"; s="${range%-*}"; e="${range#*-}"
    sm=$(( 10#${s%%:*} * 60 + 10#${s##*:} )); em=$(( 10#${e%%:*} * 60 + 10#${e##*:} ))
    if [ "$sm" -le "$em" ]; then { _day_in "$dow" "$days" && [ "$nm" -ge "$sm" ] && [ "$nm" -le "$em" ]; } && return 0
    else { _day_in "$dow" "$days" && [ "$nm" -ge "$sm" ]; } && return 0; { _day_in "$prev" "$days" && [ "$nm" -le "$em" ]; } && return 0; fi   # 跨午夜:起始那天的晚上、或隔天的清晨
  done
  return 1
}
