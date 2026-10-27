# common.sh — 所有項目共用的東西:項目登記、紀錄、確認、輸入驗證、執行流程(時窗、並行鎖、結果判斷)、主機權限閘門、ssh 金鑰載入。
# 不知道環境細節:環境相依的事都透過 be_* 介面(lib/kafka.sh、lib/hosts.sh),機敏資料透過 secret_get(lib/secrets/*.sh)。
#
# 項目檔(items/<編號>-<名稱>.sh)的寫法:
#   item <編號> <層級 1-4> <變更類 y/n> <需確認 y/n> "<標題>" "<說明>"
#   run() { ...; }          # 函式內用 $OP_USER、be_* 介面;所有使用者輸入先過 v_* 函式;變更類 = 受並行鎖與變更時窗管制
# 載入時 run 會被改名成 act_<編號>,所以每個檔都可以叫 run。

declare -A ACT_TITLE ACT_DESC ACT_TIER ACT_CHANGE ACT_CONFIRM
ACT_IDS=()
item() { OP_ITEM_ID="$1"; ACT_IDS+=("$1"); ACT_TIER[$1]="$2"; ACT_CHANGE[$1]="$3"; ACT_CONFIRM[$1]="$4"; ACT_TITLE[$1]="$5"; ACT_DESC[$1]="${6:-}"; }
load_items() { # load_items <目錄>:每個檔先 source,再把它的 run 改名成 act_<編號>
  local f; for f in "$1"/[0-9]*.sh; do
    [ -f "$f" ] || continue; OP_ITEM_ID=""; unset -f run; . "$f"
    [ -n "$OP_ITEM_ID" ] && declare -F run >/dev/null || { echo "項目檔格式錯誤(缺 item 或 run):$f" >&2; return 1; }
    eval "$(declare -f run | sed "1s/^run /act_$OP_ITEM_ID /")"; unset -f run
  done; unset OP_ITEM_ID
}

TIER_NAME=([1]="值班查看" [2]="服務操作" [3]="變更作業" [4]="授權與緊急")
C0=$'\033[0m'; CB=$'\033[1m'; CR=$'\033[31m'; CG=$'\033[32m'; CY=$'\033[33m'; CC=$'\033[36m'

# ── 紀錄 ──
core_log() { # core_log <結果> <項目> <對象/備註>;每個欄位都先去掉控制字元與分隔符,避免輸入偽造出另一行紀錄
  mkdir -p "$(dirname "$OPMENU_LOG")"
  local line; line=$(printf '%s | %s | %s | os=%s | %s | sid=%s | %s | %s' "$(date '+%F %T %z')" "$OPMENU_ENV_LABEL" "${OP_USER:-?}" "$(id -un)" "$(v_sanitize_log "$2")" "${OP_SID:--}" "$1" "$(v_sanitize_log "${3:-}")")
  printf '%s\n' "$line" >> "$OPMENU_LOG"
  if [ "${OPMENU_SYSLOG:-0}" = 1 ] && command -v logger >/dev/null; then logger -t opmenu -p auth.info -- "$line" 2>/dev/null; fi
  return 0
}
core_log_pre_login() { OP_USER="$(id -un)" core_log "$@"; }   # 還沒登入時的紀錄(操作者欄填作業系統帳號)

# core_handover_ready：交接檔的目錄建得起來、寫得進去才回 0。改密碼「之前」先檢查，免得密碼改了卻交不出去
core_handover_ready() {
  ( umask 077; mkdir -p "$OPMENU_HANDOVER_DIR" ) 2>/dev/null && [ -w "$OPMENU_HANDOVER_DIR" ] && return 0
  echo "${CR}交接檔的目錄 $OPMENU_HANDOVER_DIR 建不起來或寫不進去，不改密碼${C0}"
  return 1
}
# core_handover_secret <帳號> <密碼>：新密碼不印在畫面上，寫進操作者自己家目錄的交接檔（0600）；紀錄只記交接了哪個帳號
core_handover_secret() {
  local account="$1" secret="$2" file
  ( umask 077; mkdir -p "$OPMENU_HANDOVER_DIR" ) || return 1
  file="$OPMENU_HANDOVER_DIR/$account-$(date +%Y%m%d-%H%M%S).pass"
  ( umask 077; printf '%s\n' "$secret" > "$file" ) || return 1
  echo "新密碼已寫到 $file（只有你讀得到）。請交給 Secrets 團隊存進 PVWA，或照應用程式團隊的交付方式，完成後刪除：shred -u $file"
  core_log HANDOVER "$account" "$file"
}

core_confirm() { # core_confirm "<將做什麼>"
  echo "${CY}將執行:$1${C0}"
  [ "${OPMENU_YES:-0}" = 1 ] && return 0
  read -r -p "確定要執行嗎?輸入 yes 繼續: " a; [ "$a" = yes ]
}

# ── 使用者輸入的 allowlist 驗證:每個會被放進指令、ssh、MDS 路徑或紀錄的字串都要先過這裡 ──
v_fail() { echo "輸入不接受:$1"; return 1; }
v_match() { [[ "$1" =~ $2 ]] || v_fail "$3(規則:$2)"; }                      # v_match <值> <樣式> <說明>
v_in()    { local x; for x in $2; do [ "$x" = "$1" ] && return 0; done; v_fail "$3:$1 不在允許清單內"; }   # v_in <值> "<清單>" <說明>
v_number()    { v_match "$1" '^[0-9]{1,9}$' "${2:-數字}只能是數字"; }
v_host()      { v_in "$1" "$OPMENU_HOSTS" "主機"; }
v_broker_svc(){ v_in "$1" "$OPMENU_BROKER_SERVICES" "broker 服務"; }
v_aux_svc()   { v_in "$1" "$OPMENU_AUX_SERVICES" "服務"; }
v_any_svc()   { v_in "$1" "$OPMENU_BROKER_SERVICES $OPMENU_AUX_SERVICES" "服務"; }
v_topic()     { v_match "$1" "$OPMENU_TOPIC_PATTERN" "topic 名稱不符合命名規範" || return 1
                [[ "$1" =~ $OPMENU_PROTECTED_TOPIC_PATTERN ]] && { v_fail "topic $1 受保護(內部或 audit 用),選單不處理"; return 1; }; return 0; }
v_topic_ro()  { v_match "$1" '^[A-Za-z0-9._-]{1,249}$' "topic 名稱含不允許的字元"; }   # 只讀項目:放寬到合法 topic 字元,但仍擋掉空白、分號等
v_group()     { v_match "$1" "$OPMENU_GROUP_PATTERN" "consumer group 名稱含不允許的字元"; }
v_svc_acct()  { v_match "$1" "$OPMENU_SVC_PATTERN" "帳號不符合命名規範"; }
v_prefix()    { v_match "$1" '^[A-Za-z0-9._-]{1,100}$' "prefix 含不允許的字元"; }
v_principal() { v_match "$1" '^(User|Group):[A-Za-z0-9._@-]{1,100}$' "principal 格式應為 User:<帳號> 或 Group:<群組>"; }
v_adgroup()   { v_match "$1" '^[A-Za-z0-9._-]{1,100}$' "AD 群組名稱含不允許的字元"; }
v_role()      { v_in "$1" "$OPMENU_ROLES_ALLOWED" "role"; }
v_rtype()     { v_in "$1" "Topic Group" "資源類型"; }
v_offset_to() { [[ "$1" =~ ^(earliest|latest|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3})$ ]] || v_fail "重設位置只能是 earliest、latest 或 2026-01-31T00:00:00.000 這種格式"; }
v_tool()      { v_in "$1" "$OPMENU_EMERGENCY_TOOLS" "緊急模式工具"; }
v_sanitize_log() { printf '%s' "$1" | tr -d '\000-\037\177' | tr '|' '/'; }   # 紀錄欄位:去掉控制字元(含換行),分隔符 | 換成 /

# ── 暫存檔與清理 ──
core_cleanup() { core_lock_release; rm -f "${OP_CLIENT_CONF:-}" "${OP_LAST_RAW:-}"; declare -F be_cleanup >/dev/null && be_cleanup; core_unload_ssh_key; return 0; }
core_sweep_residue() { # 啟動時清掉自己上次留下的暫存檔與 ssh 連線目錄(行程被強制終止時 trap 不會跑);只清自己的、且所屬行程已不存在的
  local f pid
  for f in "$OPMENU_TMPDIR"/opmenu.*.???????? "$OPMENU_TMPDIR"/opmenu-ssh.*.????????; do
    [ -e "$f" ] && [ -O "$f" ] || continue
    pid="${f##*/opmenu}"; pid="${pid#-ssh}"; pid="${pid#.}"; pid="${pid%%.*}"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$pid/status" 2>/dev/null && continue
    rm -rf "$f"
  done
  return 0
}

# ── 主機用的 SSH 私鑰:登入後從保管庫取,只進這個選單自己的 ssh-agent(不落地);離開時 agent 一起結束 ──
core_load_ssh_key() {
  [ -n "${OPMENU_SSH_KEY_SECRET:-}" ] || return 0
  command -v ssh-agent >/dev/null && command -v ssh-add >/dev/null || { echo "${CR}找不到 ssh-agent / ssh-add${C0}"; return 1; }
  local out; out=$(ssh-agent -s) || return 1
  eval "$(printf '%s\n' "$out" | grep -E '^(SSH_AUTH_SOCK|SSH_AGENT_PID)=' | sed 's/; export.*//')"; export SSH_AUTH_SOCK SSH_AGENT_PID
  OP_SSH_AGENT_PID="$SSH_AGENT_PID"
  if ! secret_get "$OPMENU_SSH_KEY_SECRET" | ssh-add -q -t "${OPMENU_SSH_KEY_TTL:-14400}" - 2>/dev/null; then
    echo "${CR}無法從保管庫取得主機用的 SSH 私鑰($OPMENU_SSH_KEY_SECRET),主機類動作將不可用${C0}"; core_log SSH_KEY_FAIL login "$OPMENU_SSH_KEY_SECRET"; core_unload_ssh_key; return 1
  fi
  core_log SSH_KEY_LOADED login "$OPMENU_SSH_KEY_SECRET ttl=${OPMENU_SSH_KEY_TTL:-14400}"
}
core_unload_ssh_key() { [ -n "${OP_SSH_AGENT_PID:-}" ] || return 0; ssh-agent -k >/dev/null 2>&1; kill "$OP_SSH_AGENT_PID" 2>/dev/null; unset OP_SSH_AGENT_PID SSH_AUTH_SOCK SSH_AGENT_PID; return 0; }
# 私鑰什麼時候取：auto = on-demand（人工從 PVWA 貼上，等到真的要碰主機才取）；login = 登入就取
core_ssh_key_on_demand() {
  case "${OPMENU_SSH_KEY_LOAD:-auto}" in on-demand) return 0;; login) return 1;; *) return 0;; esac
}
# 這個項目會不會碰主機：OPMENU_MENU_AUTHZ 裡標成 HOST 的（重啟、日誌、磁碟、診斷）
core_item_touches_host() {
  local id="$1" tok k v spec=""
  for tok in $OPMENU_MENU_AUTHZ; do
    k="${tok%%=*}"; v="${tok#*=}"
    if [ "$k" = "$id" ] || { [[ "$k" == *'*' ]] && [ "${ACT_TIER[$id]}" = "${k%\*}" ]; }; then spec="$v"; fi
  done
  [ "$spec" = HOST ]
}
# 確保 ssh-agent 裡有私鑰：已經有就不再取；沒有就取一次（manual 會提示從 PVWA 貼上）
core_ensure_ssh_key() {
  [ -n "${OPMENU_SSH_KEY_SECRET:-}" ] || return 0
  if [ -n "${OP_SSH_AGENT_PID:-}" ] && ssh-add -l >/dev/null 2>&1; then return 0; fi
  core_unload_ssh_key
  core_load_ssh_key
}

# ── 執行一個項目的固定流程:看得到嗎 → 時窗 → 並行鎖 → 執行 → 依輸出判斷結果 → 記錄 ──
_core_run() {
  local id="$1"; shift
  [ -n "${ACT_TITLE[$id]:-}" ] || { echo "沒有這個項目:$id"; return 1; }
  if [ "${OP_VISIBLE[$id]:-1}" != 1 ]; then   # 選單上看不到的項目(你的權限不足)不能執行:直接輸入編號一樣擋下並記錄
    echo "${CR}項目 $id 不在你的選單內(你的 AD 群組沒有這項權限),請依變更單申請。${C0}"
    core_log DENIED "$id ${ACT_TITLE[$id]}" "not in menu"; return 1
  fi
  echo; echo "${CB}[$id] ${ACT_TITLE[$id]}${C0}  (${TIER_NAME[${ACT_TIER[$id]}]})"
  [ -n "${ACT_DESC[$id]}" ] && echo "  ${ACT_DESC[$id]}"
  if [ "${ACT_CHANGE[$id]}" = y ]; then
    if ! core_window_ok && ! _in_words "$id" "$OPMENU_WINDOW_EXEMPT"; then
      echo "${CR}目前不在允許變更的時窗內(OPMENU_CHANGE_WINDOW=$OPMENU_CHANGE_WINDOW)${C0}"; core_log BLOCKED "$id ${ACT_TITLE[$id]}" "outside change window"; return 1
    fi
    core_lock_acquire "$id ${ACT_TITLE[$id]}" || { core_log BLOCKED "$id ${ACT_TITLE[$id]}" "lock held"; return 1; }
  fi
  # 碰主機的項目：先過權限閘門，再確保私鑰在 ssh-agent 裡。要在這裡（主 shell）做：
  # 項目本身在管線裡執行（子 shell），在那裡載入的 ssh-agent 下一個項目就看不到了
  if core_item_touches_host "$id"; then
    core_host_gate || { core_log DENIED "$id ${ACT_TITLE[$id]}" "host gate"; return 1; }
    core_ensure_ssh_key || { core_log BLOCKED "$id ${ACT_TITLE[$id]}" "no ssh key"; return 1; }
  fi
  local rc shown t0; shown="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"; t0=$(date +%s)
  : > "$OP_LAST_RAW"
  "act_$id" "$@" 2>&1 | tee "$shown"; rc=${PIPESTATUS[0]}   # 邊執行邊顯示(項目裡的提問與確認要即時看到),同時側錄一份用來判斷結果
  local raw; raw="$(cat "$OP_LAST_RAW" "$shown")"          # 工具的原始輸出(項目可能過濾掉錯誤訊息,所以後端另存一份)
  rm -f "$shown"
  local note="$* [rc=$rc $(( $(date +%s) - t0 ))s]"
  if [ $rc -eq 0 ]; then
    core_log OK "$id ${ACT_TITLE[$id]}" "$note"
  elif printf '%s' "$raw" | grep -q -i "AuthorizationException\|not authorized\|Authorization failed\|HTTP 403"; then
    echo "${CR}Kafka 拒絕:你的群組沒有這項權限,請依變更單申請。${C0}"; core_log DENIED "$id ${ACT_TITLE[$id]}" "$note"
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
core_run() { _core_run "$@"; local rc=$?; core_lock_release; return $rc; }

# ── 動態選單:登入後用本人的 token 一次問 MDS,只顯示有權限的項目(MDS 會展開 AD 群組)。只影響「看得到什麼」,執行時照樣檢查 ──
core_item_authz() { # core_item_authz <id> -> 這個項目需要的權限 <資源類型>:<名稱>:<操作>;空 = 不限制。設定見 OPMENU_MENU_AUTHZ(後面的覆蓋前面的)
  local id="$1" tok k v spec=""
  for tok in $OPMENU_MENU_AUTHZ; do
    k="${tok%%=*}"; v="${tok#*=}"
    if [ "$k" = "$id" ] || { [[ "$k" == *'*' ]] && [ "${ACT_TIER[$id]}" = "${k%\*}" ]; }; then spec="$v"; fi
  done
  case "$spec" in HOST) spec="$OPMENU_HOST_ACTION_AUTHZ";; ADMIN) spec="$OPMENU_ADMIN_AUTHZ";; AUDIT) spec="$OPMENU_AUDIT_AUTHZ";; -) spec="";; esac
  printf '%s' "$spec"
}
core_menu_permissions() { # -> OP_VISIBLE[<id>] = 1 / 0;問不到或回應看不懂 = 全部顯示並提示
  declare -gA OP_VISIBLE=(); OP_MENU_NOTE=""
  local id spec i rt rn op actions="" out answer
  for id in "${ACT_IDS[@]}"; do OP_VISIBLE[$id]=1; done
  if [ "${OP_EMERGENCY_HOST:-0}" = 1 ]; then   # 緊急主機模式：問不了 MDS，只開放 OPMENU_EMERGENCY_ITEMS
    for id in "${ACT_IDS[@]}"; do _in_words "$id" "$OPMENU_EMERGENCY_ITEMS" || OP_VISIBLE[$id]=0; done
    OP_MENU_NOTE="緊急主機模式（MDS 連不上）：只能做主機類項目，每一步都記錄"
    return 0
  fi
  [ "${OPMENU_MENU_FILTER:-1}" = 1 ] || return 0
  local specs=(); declare -A seen=() ok=()
  for id in "${ACT_IDS[@]}"; do spec=$(core_item_authz "$id"); [ -n "$spec" ] && [ -z "${seen[$spec]:-}" ] && { seen[$spec]=1; specs+=("$spec"); }; done
  [ ${#specs[@]} -gt 0 ] || return 0
  for spec in "${specs[@]}"; do
    IFS=: read -r rt rn op <<< "$spec"
    actions+=$(printf '%s{"resourceType":"%s","resourceName":"%s","operation":"%s","scope":{"clusters":{"kafka-cluster":"%s"}}}' "${actions:+,}" "$rt" "$rn" "$op" "${OPMENU_KAFKA_CLUSTER_ID:-}")
  done
  out=$(be_mds PUT /security/1.0/authorize "$(printf '{"userPrincipal":"User:%s","actions":[%s]}' "$OP_USER" "$actions")" 2>/dev/null)
  answer=$(printf '%s\n' "$out" | grep -o '^\[.*\]' | head -1 | tr -d '[]" ')
  local res=(); IFS=, read -ra res <<< "$answer"
  if [[ "$out" != *'HTTP 200'* ]] || [ ${#res[@]} -ne ${#specs[@]} ]; then
    OP_MENU_NOTE="無法取得你的權限清單,先顯示全部項目(執行時仍會檢查權限)"; core_log MENU_ALL "menu" "authorize failed"; return 0
  fi
  for i in "${!specs[@]}"; do [ "${res[$i]}" = ALLOWED ] && ok[${specs[$i]}]=1; done
  for id in "${ACT_IDS[@]}"; do spec=$(core_item_authz "$id"); [ -z "$spec" ] || [ -n "${ok[$spec]:-}" ] || OP_VISIBLE[$id]=0; done
}

# ── 主機類動作的權限閘門:主機端的 cpadmin 是共用帳號,sudo 分不出是誰,所以碰主機前用本人的 token 問 MDS;任何錯誤一律視為拒絕 ──
core_host_gate() {
  [ "${OP_EMERGENCY_HOST:-0}" = 1 ] && return 0   # 緊急主機模式：授權在登入時看過作業系統群組 OPMENU_EMERGENCY_GROUP
  [ -n "${OPMENU_HOST_ACTION_AUTHZ:-}" ] || return 0
  [ "${OP_HOST_OK:-0}" = 1 ] && return 0
  local rt rn op body out
  IFS=: read -r rt rn op <<< "$OPMENU_HOST_ACTION_AUTHZ"
  body=$(printf '{"userPrincipal":"User:%s","actions":[{"resourceType":"%s","resourceName":"%s","operation":"%s","scope":{"clusters":{"kafka-cluster":"%s"}}}]}' "$OP_USER" "$rt" "$rn" "$op" "${OPMENU_KAFKA_CLUSTER_ID:-}")
  out=$(be_mds PUT /security/1.0/authorize "$body" 2>/dev/null)
  if [[ "$out" == *'["ALLOWED"]'* && "$out" == *'HTTP 200'* ]]; then OP_HOST_OK=1; return 0; fi
  echo "${CR}主機類動作 Authorization failed:需要叢集層級權限($OPMENU_HOST_ACTION_AUTHZ),你的群組沒有;請依變更單申請。${C0}"   # 含 "Authorization failed",會記成 DENIED
  return 1
}
core_guard_host_actions() { # Decorator:把所有「碰主機」的介面包上 core_host_gate;新增項目或換後端都不會漏掉
  local f
  for f in be_service_restart be_service_logs be_disk_usage be_collect_diag; do
    declare -F "$f" >/dev/null || continue
    eval "_unguarded_$(declare -f "$f")"
    eval "$f() { core_host_gate || return 1; _unguarded_$f \"\$@\"; }"
  done
}

# ── 並行鎖與變更時窗 ──
_in_words() { local x; for x in $2; do [ "$x" = "$1" ] && return 0; done; return 1; }
core_lock_acquire() { # mkdir 是原子的;持有者的行程已不存在就視為過期。只在同一台操作機有效
  local d="$OPMENU_LOCK_DIR" waited=0 holder hp
  mkdir -p "$(dirname "$d")" 2>/dev/null
  while ! ( umask 000; mkdir "$d" ) 2>/dev/null; do
    holder="$(cat "$d/info" 2>/dev/null)"; hp="${holder%% *}"
    if [ -n "$hp" ] && ! kill -0 "$hp" 2>/dev/null && [ ! -d "/proc/$hp" ]; then rm -rf "$d"; continue; fi
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
    else { _day_in "$dow" "$days" && [ "$nm" -ge "$sm" ]; } && return 0; { _day_in "$prev" "$days" && [ "$nm" -le "$em" ]; } && return 0; fi
  done
  return 1
}
