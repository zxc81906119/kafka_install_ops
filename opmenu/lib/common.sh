# common.sh — 所有項目共用的東西:項目登記、紀錄、確認、輸入驗證、執行流程(時窗、並行鎖、結果判斷)、主機權限閘門、ssh 私鑰檔檢查。
# 不知道環境細節:環境相依的事都透過 be_* 介面(lib/kafka.sh、lib/hosts.sh),機敏資料透過 secret_get(lib/secrets/*.sh)。
#
# 要改選單（新增項目、改標題、改層級）：改 items/menu.list，一行一個項目。
# 要改某個項目做的事：改 items/<編號>-<名稱>.sh 裡的 run_<編號> 函式（例如 items/21-restart-broker.sh 的 run_21）。
#   函式內用 $OP_USER、be_* 介面;所有使用者輸入先過 v_* 函式;變更類 = 受並行鎖與變更時窗管制。

# ── 項目登記 ──
# load_items 讀完 items/menu.list 之後，這些變數裡就有每個項目的資料（[編號] 取值，例如 ${ACT_TITLE[21]}）：
#   ACT_IDS              所有編號，照表上的順序
#   ACT_TIER[編號]        層級 1-4
#   ACT_CHANGE[編號]      變更類 y／n
#   ACT_CONFIRM[編號]     要確認 y／n
#   ACT_TITLE[編號]       標題
#   ACT_DESC[編號]        說明
declare -A ACT_TITLE ACT_DESC ACT_TIER ACT_CHANGE ACT_CONFIRM
ACT_IDS=()

# load_items <items 目錄>：讀選單對照表，載入每個項目檔
load_items() {
  local items_dir="$1"
  local table="$items_dir/menu.list"
  local id tier change confirm file title desc

  if [ ! -f "$table" ]; then
    echo "找不到選單對照表：$table" >&2
    return 1
  fi

  # 一次讀一行，用 | 切成 7 個欄位
  while IFS='|' read -r id tier change confirm file title desc; do
    # 略過空行與 # 開頭的說明
    if [ -z "$id" ]; then
      continue
    fi
    case "$id" in
      "#"*) continue ;;
    esac

    # 載入項目檔
    if [ ! -f "$items_dir/$file" ]; then
      echo "選單對照表的第 $id 項：找不到檔案 $items_dir/$file" >&2
      return 1
    fi
    . "$items_dir/$file"

    # 項目檔裡一定要有 run_<編號> 這個函式（declare -F 只查「有沒有這個函式」，不執行它）
    if ! declare -F "run_$id" > /dev/null; then
      echo "項目檔 $file 裡沒有 run_$id 函式" >&2
      return 1
    fi

    # 記下這個項目
    ACT_IDS+=("$id")
    ACT_TIER[$id]="$tier"
    ACT_CHANGE[$id]="$change"
    ACT_CONFIRM[$id]="$confirm"
    ACT_TITLE[$id]="$title"
    ACT_DESC[$id]="$desc"
  done < "$table"

  if [ ${#ACT_IDS[@]} -eq 0 ]; then
    echo "選單對照表 $table 裡沒有任何項目" >&2
    return 1
  fi
  return 0
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
  echo "新密碼已寫到 $file（只有你讀得到）。請照應用程式團隊的交付方式交出去，完成後刪除：shred -u $file"
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
core_cleanup() { core_lock_release; rm -f "${OP_CLIENT_CONF:-}" "${OP_LAST_RAW:-}"; declare -F be_cleanup >/dev/null && be_cleanup; return 0; }
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

# ── 主機用的 SSH 私鑰:就是操作機獨立 file system 上的檔案 OPMENU_SSH_KEY_FILE(root 0400,安裝與維運共用同一把);不經 ssh-agent、不從保管庫取 ──
# 碰主機之前確認它讀得到;沒有(例如 /secure/ssh 沒掛載)就擋下,不讓 ssh 去試別的金鑰
core_check_ssh_key() {
  [ -n "${OPMENU_SSH_KEY_FILE:-}" ] && [ -r "$OPMENU_SSH_KEY_FILE" ] && return 0
  echo "${CR}找不到主機用的 SSH 私鑰 ${OPMENU_SSH_KEY_FILE:-(OPMENU_SSH_KEY_FILE 未設定)}:確認放私鑰的獨立 file system(例如 /secure/ssh)已掛載,主機類動作暫時不可用${C0}"
  return 1
}
# 這個項目會不會碰主機（重啟、日誌、磁碟、診斷）：OPMENU_HOST_ITEMS 列出的編號
core_item_touches_host() { _in_words "$1" "$OPMENU_HOST_ITEMS"; }
# ── 執行一個項目 ──
# 每個項目都照同樣的順序，任何一關不過就不執行，並寫一筆紀錄：
#   1. 有沒有這個編號
#   2. 緊急主機模式有沒有開放這個項目
#   3. 變更類：是不是在變更時窗內、拿不拿得到並行鎖
#   4. MDS token 快到期就先換新
#   5. 碰主機的項目：主機權限閘門、主機用的 SSH 私鑰在不在
#   6. 用備用身分執行的項目（91）：本人要先過管理員閘門
#   7. 執行 run_<編號>，邊執行邊顯示
#   8. 依結果寫紀錄（core_log_result）
# core_run <編號> [參數...]：選單和 --run 都從這裡進來；不管成功失敗，最後都放掉並行鎖
core_run() {
  local rc
  _core_run "$@"
  rc=$?
  core_lock_release
  return $rc
}

_core_run() {
  local id="$1"
  shift

  # 1. 有沒有這個編號
  local title="${ACT_TITLE[$id]:-}"
  if [ -z "$title" ]; then
    echo "沒有這個項目:$id"
    return 1
  fi
  local what="$id $title"   # 紀錄裡「項目」那一欄寫的字

  # 2. 緊急主機模式（MDS 連不上）只開放部分項目；直接輸入編號也一樣擋下
  if [ "${OP_VISIBLE[$id]:-1}" != 1 ]; then
    echo "${CR}項目 $id 在緊急主機模式不開放(只能做 OPMENU_EMERGENCY_ITEMS 列的主機類項目)。Kafka 類操作改用手把手 28.6 的 kafka-admin。${C0}"
    core_log DENIED "$what" "not in emergency items"
    return 1
  fi

  echo
  echo "${CB}[$id] $title${C0}  (${TIER_NAME[${ACT_TIER[$id]}]})"
  if [ -n "${ACT_DESC[$id]}" ]; then
    echo "  ${ACT_DESC[$id]}"
  fi

  # 3. 變更類：時窗與並行鎖
  if [ "${ACT_CHANGE[$id]}" = y ]; then
    if ! core_window_ok; then
      if ! _in_words "$id" "$OPMENU_WINDOW_EXEMPT"; then
        echo "${CR}目前不在允許變更的時窗內(OPMENU_CHANGE_WINDOW=$OPMENU_CHANGE_WINDOW)${C0}"
        core_log BLOCKED "$what" "outside change window"
        return 1
      fi
    fi
    if ! core_lock_acquire "$what"; then
      core_log BLOCKED "$what" "lock held"
      return 1
    fi
  fi

  # 4. token 快到期就先換新（換不到就不做這個動作）
  if ! core_token_fresh "$what"; then
    return 1
  fi

  # 5. 碰主機的項目：先過權限閘門，再確認主機用的私鑰檔在（沒掛載就擋下）
  if core_item_touches_host "$id"; then
    if ! core_host_gate; then
      core_log DENIED "$what" "host gate"
      return 1
    fi
    if ! core_check_ssh_key; then
      core_log BLOCKED "$what" "no ssh key file"
      return 1
    fi
  fi

  # 6. 用備用身分執行的項目（91）：Kafka 檢查的是備用憑證、不是本人，所以本人要先過管理員閘門
  if _in_words "$id" "$OPMENU_ADMIN_ITEMS"; then
    if ! core_admin_gate; then
      core_log DENIED "$what" "admin gate"
      return 1
    fi
  fi

  # 7. 執行：輸出邊顯示邊另存一份（tee），項目裡的提問與確認才看得到；結果判斷要用存下來的那份
  local shown started rc
  shown="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"
  started=$(date +%s)
  : > "$OP_LAST_RAW"                 # 清空：be_kafka、be_mds 會把工具的原始輸出（含被項目過濾掉的錯誤訊息）寫進這裡
  "run_$id" "$@" 2>&1 | tee "$shown"
  rc=${PIPESTATUS[0]}                # 管線裡第一個指令（run_<編號>）的結束碼；直接用 $? 拿到的是 tee 的

  # 8. 依結果寫紀錄
  local all_output elapsed
  all_output="$(cat "$OP_LAST_RAW" "$shown")"
  rm -f "$shown"
  elapsed=$(( $(date +%s) - started ))
  core_log_result "$what" "$rc" "$all_output" "$* [rc=$rc ${elapsed}s]"
  return $rc
}

# core_log_result <項目> <結束碼> <輸出> <備註>：依結束碼與輸出裡的關鍵字，判斷是成功、被 Kafka 拒絕、登入問題，還是其他失敗
core_log_result() {
  local what="$1" rc="$2" output="$3" note="$4"

  if [ "$rc" -eq 0 ]; then
    core_log OK "$what" "$note"
    return 0
  fi

  if printf '%s' "$output" | grep -q -i "AuthorizationException\|not authorized\|Authorization failed\|HTTP 403"; then
    echo "${CR}Kafka 拒絕:你的群組沒有這項權限,請依變更單申請。${C0}"
    core_log DENIED "$what" "$note"
    return 0
  fi

  if printf '%s' "$output" | grep -q -i "SaslAuthenticationException\|Authentication failed\|HTTP 401"; then
    local token_age=0
    if [ -n "${OP_TOKEN_AT:-}" ]; then
      token_age=$(( $(date +%s) - OP_TOKEN_AT ))
    fi
    if [ -n "${OP_TOKEN_AT:-}" ] && [ "$token_age" -ge "${OPMENU_TOKEN_TTL:-3600}" ]; then
      echo "${CR}登入已逾時(token 到期),請離開後重新登入。${C0}"
      core_log TOKEN_EXPIRED "$what" "$note"
    else
      echo "${CR}登入失敗:帳號或密碼不正確。${C0}"
      core_log AUTH_FAIL "$what" "$note"
    fi
    return 0
  fi

  echo "${CR}執行失敗(見上方訊息)${C0}"
  core_log FAIL "$what" "$note"
  return 0
}

# core_token_fresh <項目>:MDS token 用了超過「OPMENU_TOKEN_TTL − OPMENU_TOKEN_RENEW_MARGIN」就自動換新(每個動作開始前在主 shell 呼叫,
# 換到的 token 才留得住;項目裡的 be_mds 多半在 $(...) 子 shell 裡跑)。帳密取自本次登入的 Kafka 連線設定 OP_CLIENT_CONF
# (0600,離開選單即刪),不另外保存。換不到(AD 密碼改了、AD 或 MDS 不通)就不執行這個動作,請操作者重新登入。緊急主機模式沒有 token,不處理。
core_token_fresh() {
  [ -n "${OP_TOKEN:-}" ] && [ -n "${OP_TOKEN_AT:-}" ] || return 0
  local age limit pass token rc
  age=$(( $(date +%s) - OP_TOKEN_AT )); limit=$(( ${OPMENU_TOKEN_TTL:-3600} - ${OPMENU_TOKEN_RENEW_MARGIN:-300} ))
  [ "$age" -lt "$limit" ] && return 0
  pass=$(sed -n 's/^sasl\.jaas\.config=.* password="\(.*\)";$/\1/p' "$OP_CLIENT_CONF" 2>/dev/null)
  token=$(be_mds_login "$OP_USER" "$pass"); rc=$?; unset pass
  if [ "$rc" = 0 ] && [ -n "$token" ]; then
    OP_TOKEN=$token; OP_TOKEN_AT=$(date +%s); export OP_TOKEN OP_TOKEN_AT
    core_log TOKEN_RENEWED "$1" "token 已用 ${age}s,自動換新"; return 0
  fi
  echo "${CR}登入已逾時,自動換新 token 失敗(AD 密碼改了,或 AD／MDS 不通):這個動作沒有執行,請離開後重新登入。${C0}"
  core_log TOKEN_RENEW_FAIL "$1" "token 已用 ${age}s,rc=$rc"; return 1
}

# ── 選單一律全部顯示;要做什麼直接選,沒權限的由 Kafka / MDS 在執行時拒絕(Kafka 動作以本人身分執行,權限由 Kafka 端依 RBAC 強制)。
#    唯一會隱藏項目的情況是緊急主機模式(MDS 連不上,AD 登入做不了):只開放 OPMENU_EMERGENCY_ITEMS ──
core_menu_permissions() { # -> OP_VISIBLE[<id>] = 1 / 0
  declare -gA OP_VISIBLE=(); OP_MENU_NOTE=""
  local id
  for id in "${ACT_IDS[@]}"; do OP_VISIBLE[$id]=1; done
  if [ "${OP_EMERGENCY_HOST:-0}" = 1 ]; then
    for id in "${ACT_IDS[@]}"; do _in_words "$id" "$OPMENU_EMERGENCY_ITEMS" || OP_VISIBLE[$id]=0; done
    OP_MENU_NOTE="緊急主機模式（MDS 連不上）：只能做主機類項目，每一步都記錄"
  fi
}
# ── 管理員閘門:用備用身分執行的項目(91 緊急模式)前,用本人的 token 問 MDS 本人有沒有 OPMENU_ADMIN_AUTHZ;任何錯誤一律視為拒絕 ──
core_admin_gate() {
  [ -n "${OPMENU_ADMIN_AUTHZ:-}" ] || return 0
  local rt rn op body out
  IFS=: read -r rt rn op <<< "$OPMENU_ADMIN_AUTHZ"
  body=$(printf '{"userPrincipal":"User:%s","actions":[{"resourceType":"%s","resourceName":"%s","operation":"%s","scope":{"clusters":{"kafka-cluster":"%s"}}}]}' "$OP_USER" "$rt" "$rn" "$op" "${OPMENU_KAFKA_CLUSTER_ID:-}")
  out=$(be_mds PUT /security/1.0/authorize "$body" 2>/dev/null)
  if [[ "$out" == *'["ALLOWED"]'* && "$out" == *'HTTP 200'* ]]; then return 0; fi
  echo "${CR}Authorization failed:這個項目以備用身分執行,需要本人有管理員權限($OPMENU_ADMIN_AUTHZ),你的群組沒有;請依變更單申請。${C0}"   # 含 "Authorization failed",會記成 DENIED
  return 1
}

# ── 主機類動作的權限閘門:主機端的 cpuser 是共用帳號,sudo 分不出是誰,所以碰主機前用本人的 token 問 MDS;任何錯誤一律視為拒絕。
#    注意:操作者在操作機上是 root,這道閘門是流程控管、不是硬性隔離(root 可以直接用金鑰 ssh);追溯靠 CyberArk 的登入紀錄與 PSMP 錄影 ──
core_host_gate() {
  [ "${OP_EMERGENCY_HOST:-0}" = 1 ] && return 0   # 緊急主機模式：MDS 連不上，問不到權限；只開放 OPMENU_EMERGENCY_ITEMS，必填原因、記 EMERGENCY_HOST
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
# 「碰主機」的介面（lib/hosts.sh 的 be_service_restart、be_service_logs、be_disk_usage、be_collect_diag）
# 每一個開頭都自己呼叫 core_host_gate：新增項目時不管走哪一條路呼叫它們，都會先過閘門。新增碰主機的 be_* 函式時也要這樣寫。

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
