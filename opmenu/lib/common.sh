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

# 層級的名稱（選單上分四區）
TIER_NAME=([1]="值班查看" [2]="服務操作" [3]="變更作業" [4]="授權與緊急")

# 畫面上的顏色：C0 恢復、CB 粗體、CR 紅、CG 綠、CY 黃、CC 青
C0=$'\033[0m'
CB=$'\033[1m'
CR=$'\033[31m'
CG=$'\033[32m'
CY=$'\033[33m'
CC=$'\033[36m'

# ── 紀錄 ──
# core_log <結果> <項目> <對象或備註>：在 OPMENU_LOG 加一行紀錄（OPMENU_SYSLOG=1 時也送 syslog）
#   一行的欄位（用 | 隔開）：時間 | 環境 | 操作者 | os=作業系統帳號 | 項目 | sid=這次登入的編號 | 結果 | 對象或備註
#   例：2026-11-01 10:00:00 +0800 | prod | alice | os=root | 21 重啟單一 broker | sid=1793… | OK | kb04…:confluent-server [rc=0 11s]
#   項目與備註先去掉控制字元、把 | 換成 /（v_sanitize_log），免得輸入的內容偽造出另一行紀錄
core_log() {
  local result="$1"
  local what
  local note
  local line

  what=$(v_sanitize_log "$2")
  note=$(v_sanitize_log "${3:-}")

  mkdir -p "$(dirname "$OPMENU_LOG")"

  line=$(printf '%s | %s | %s | os=%s | %s | sid=%s | %s | %s' "$(date '+%F %T %z')" "$OPMENU_ENV_LABEL" "${OP_USER:-?}" "$(id -un)" "$what" "${OP_SID:--}" "$result" "$note")
  printf '%s\n' "$line" >> "$OPMENU_LOG"

  if [ "${OPMENU_SYSLOG:-0}" = 1 ]; then
    if command -v logger > /dev/null; then
      logger -t opmenu -p auth.info -- "$line" 2> /dev/null
    fi
  fi

  return 0
}

# core_log_pre_login <結果> <項目> <對象或備註>：還沒登入時的紀錄，操作者欄填作業系統帳號
core_log_pre_login() {
  local OP_USER          # 只在這個函式裡蓋過 OP_USER（core_log 會用到它）
  OP_USER=$(id -un)
  core_log "$@"
}

# ── 交接檔：新密碼不印在畫面上，寫進操作者自己的交接目錄 ──
# core_handover_ready：交接目錄建得起來、寫得進去才回 0。改密碼「之前」先檢查，免得密碼改了卻交不出去
core_handover_ready() {
  # ( … ) 裡的 umask 只影響括號裡的指令：建出來的目錄只有自己讀得到
  if ( umask 077; mkdir -p "$OPMENU_HANDOVER_DIR" ) 2> /dev/null; then
    if [ -w "$OPMENU_HANDOVER_DIR" ]; then
      return 0
    fi
  fi

  echo "${CR}交接檔的目錄 $OPMENU_HANDOVER_DIR 建不起來或寫不進去，不改密碼${C0}"
  return 1
}

# core_handover_secret <帳號> <密碼>：把新密碼寫進交接檔（0600）；紀錄只記交接了哪個帳號、檔案在哪，不記密碼
core_handover_secret() {
  local account="$1"
  local secret="$2"
  local file

  if ! ( umask 077; mkdir -p "$OPMENU_HANDOVER_DIR" ); then
    return 1
  fi

  file="$OPMENU_HANDOVER_DIR/$account-$(date +%Y%m%d-%H%M%S).pass"

  if ! ( umask 077; printf '%s\n' "$secret" > "$file" ); then
    return 1
  fi

  echo "新密碼已寫到 $file（只有你讀得到）。請照應用程式團隊的交付方式交出去，完成後刪除：shred -u $file"
  core_log HANDOVER "$account" "$file"
}

# ── 確認 ──
# core_confirm "<將做什麼>"：印出將做什麼，請操作者輸入 yes；輸入 yes 才回 0
#   OPMENU_YES=1（測試、排程用，要設定檔允許）時不問，直接回 0
core_confirm() {
  local answer

  echo "${CY}將執行:$1${C0}"

  if [ "${OPMENU_YES:-0}" = 1 ]; then
    return 0
  fi

  read -r -p "確定要執行嗎?輸入 yes 繼續: " answer

  if [ "$answer" = yes ]; then
    return 0
  fi

  return 1
}

# ── 使用者輸入的白名單檢查：每個會被放進指令、ssh、MDS 路徑或紀錄的字串都要先過這裡 ──
# 每個 v_* 通過回 0；不通過印「輸入不接受:…」並回 1。

# v_fail <原因>：印出不接受的原因，回 1
v_fail() {
  echo "輸入不接受:$1"
  return 1
}

# v_match <值> <樣式> <說明>：值要符合正規表示式樣式，例 v_match "$n" '^[0-9]{1,9}$' "只能是數字"
v_match() {
  local value="$1"
  local pattern="$2"
  local description="$3"

  if [[ "$value" =~ $pattern ]]; then
    return 0
  fi

  v_fail "$description(規則:$pattern)"
}

# v_in <值> "<清單>" <說明>：值要是清單（用空白隔開）裡的其中一個，例 v_in "$action" "add remove" "動作"
v_in() {
  local value="$1"
  local allowed="$2"
  local description="$3"
  local item

  for item in $allowed; do
    if [ "$item" = "$value" ]; then
      return 0
    fi
  done

  v_fail "$description:$value 不在允許清單內"
}

# 下面每一個都是一行：用 v_match 或 v_in 檢查一種輸入
v_number()    { v_match "$1" '^[0-9]{1,9}$' "${2:-數字}只能是數字"; }
v_host()      { v_in "$1" "$OPMENU_HOSTS" "主機"; }
v_broker_svc(){ v_in "$1" "$OPMENU_BROKER_SERVICES" "broker 服務"; }
v_aux_svc()   { v_in "$1" "$OPMENU_AUX_SERVICES" "服務"; }
v_any_svc()   { v_in "$1" "$OPMENU_BROKER_SERVICES $OPMENU_AUX_SERVICES" "服務"; }
v_topic_ro()  { v_match "$1" '^[A-Za-z0-9._-]{1,249}$' "topic 名稱含不允許的字元"; }   # 只讀項目:放寬到合法 topic 字元,但仍擋掉空白、分號等
v_group()     { v_match "$1" "$OPMENU_GROUP_PATTERN" "consumer group 名稱含不允許的字元"; }
v_svc_acct()  { v_match "$1" "$OPMENU_SVC_PATTERN" "帳號不符合命名規範"; }
v_prefix()    { v_match "$1" '^[A-Za-z0-9._-]{1,100}$' "prefix 含不允許的字元"; }
v_principal() { v_match "$1" '^(User|Group):[A-Za-z0-9._@-]{1,100}$' "principal 格式應為 User:<帳號> 或 Group:<群組>"; }
v_adgroup()   { v_match "$1" '^[A-Za-z0-9._-]{1,100}$' "AD 群組名稱含不允許的字元"; }
v_role()      { v_in "$1" "$OPMENU_ROLES_ALLOWED" "role"; }
v_rtype()     { v_in "$1" "Topic Group" "資源類型"; }
v_tool()      { v_in "$1" "$OPMENU_EMERGENCY_TOOLS" "緊急模式工具"; }

# v_topic <topic>：要符合命名規範（OPMENU_TOPIC_PATTERN），而且不是受保護的 topic（內部、稽核用）
v_topic() {
  local topic="$1"

  if ! v_match "$topic" "$OPMENU_TOPIC_PATTERN" "topic 名稱不符合命名規範"; then
    return 1
  fi

  if [[ "$topic" =~ $OPMENU_PROTECTED_TOPIC_PATTERN ]]; then
    v_fail "topic $topic 受保護(內部或 audit 用),選單不處理"
    return 1
  fi

  return 0
}

# v_offset_to <位置>：重設 offset 的位置只能是 earliest、latest，或 2026-01-31T00:00:00.000 這種時間
v_offset_to() {
  if [[ "$1" =~ ^(earliest|latest|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3})$ ]]; then
    return 0
  fi

  v_fail "重設位置只能是 earliest、latest 或 2026-01-31T00:00:00.000 這種格式"
}

# v_sanitize_log <文字>：寫進紀錄前，去掉控制字元（含換行），把欄位分隔符 | 換成 /
v_sanitize_log() {
  printf '%s' "$1" | tr -d '\000-\037\177' | tr '|' '/'
}

# ── 暫存檔與清理 ──
# core_cleanup：離開選單時（含 Ctrl+C）放掉並行鎖、刪掉連線設定與暫存檔、關掉 ssh 連線
core_cleanup() {
  core_lock_release
  rm -f "${OP_CLIENT_CONF:-}" "${OP_LAST_RAW:-}"

  if declare -F be_cleanup > /dev/null; then
    be_cleanup
  fi

  return 0
}

# core_sweep_residue：啟動時清掉自己上次留下的暫存檔與 ssh 連線目錄（行程被強制結束時，離開時的清理不會跑）
#   只清「自己的」、而且「留下它的行程已經不在」的。檔名長這樣：
#     opmenu.<行程編號>.<8 個亂數字元>      連線設定、輸出暫存
#     opmenu-ssh.<行程編號>.<8 個亂數字元>  ssh 連線重用的目錄
core_sweep_residue() {
  local file name pid

  for file in "$OPMENU_TMPDIR"/opmenu.*.???????? "$OPMENU_TMPDIR"/opmenu-ssh.*.????????; do
    # 沒有符合的檔時，迴圈會拿到樣式本身；不是自己的也不碰
    if [ ! -e "$file" ]; then
      continue
    fi
    if [ ! -O "$file" ]; then
      continue
    fi

    # 檔名的第二段（點隔開）是留下它的行程編號
    name=$(basename "$file")
    pid=$(echo "$name" | cut -d. -f2)

    # 那個行程還活著（而且不是殭屍行程）就留著
    if _process_alive "$pid"; then
      continue
    fi

    rm -rf "$file"
  done

  return 0
}

# _process_alive <行程編號>：行程還在、而且不是殭屍（已結束、等著被收的行程）才回 0
_process_alive() {
  local pid="$1"

  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  if ! kill -0 "$pid" 2> /dev/null; then
    return 1
  fi

  if grep -q '^State:.*Z' "/proc/$pid/status" 2> /dev/null; then
    return 1
  fi

  return 0
}

# ── 主機用的 SSH 私鑰 ──
# 就是操作機獨立 file system 上的檔案 OPMENU_SSH_KEY_FILE（root 0400，安裝與維運共用同一把）；不經 ssh-agent、不從保管庫取。
# core_check_ssh_key：碰主機之前確認它讀得到；沒有（例如 /secure/ssh 沒掛載）就擋下，不讓 ssh 去試別的金鑰
core_check_ssh_key() {
  if [ -n "${OPMENU_SSH_KEY_FILE:-}" ] && [ -r "$OPMENU_SSH_KEY_FILE" ]; then
    return 0
  fi

  echo "${CR}找不到主機用的 SSH 私鑰 ${OPMENU_SSH_KEY_FILE:-(OPMENU_SSH_KEY_FILE 未設定)}:確認放私鑰的獨立 file system(例如 /secure/ssh)已掛載,主機類動作暫時不可用${C0}"
  return 1
}

# core_item_touches_host <編號>：這個項目會不會碰主機（重啟、日誌、磁碟、診斷），也就是有沒有列在 OPMENU_HOST_ITEMS
core_item_touches_host() {
  _in_words "$1" "$OPMENU_HOST_ITEMS"
}
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
  local what="$1"

  # 沒有 token（緊急主機模式）就不處理
  if [ -z "${OP_TOKEN:-}" ] || [ -z "${OP_TOKEN_AT:-}" ]; then
    return 0
  fi

  # 1. 還沒到「該換新」的時間就不換
  local age limit
  age=$(( $(date +%s) - OP_TOKEN_AT ))
  limit=$(( ${OPMENU_TOKEN_TTL:-3600} - ${OPMENU_TOKEN_RENEW_MARGIN:-300} ))

  if [ "$age" -lt "$limit" ]; then
    return 0
  fi

  # 2. 從這次登入的連線設定取出密碼，向 MDS 換新 token
  local password token rc
  password=$(sed -n 's/^sasl\.jaas\.config=.* password="\(.*\)";$/\1/p' "$OP_CLIENT_CONF" 2> /dev/null)
  token=$(be_mds_login "$OP_USER" "$password")
  rc=$?
  unset password

  # 3. 換到了：記下新的 token 與時間
  if [ "$rc" = 0 ] && [ -n "$token" ]; then
    OP_TOKEN=$token
    OP_TOKEN_AT=$(date +%s)
    export OP_TOKEN OP_TOKEN_AT
    core_log TOKEN_RENEWED "$what" "token 已用 ${age}s,自動換新"
    return 0
  fi

  # 4. 換不到：這個動作不做，請操作者重新登入
  echo "${CR}登入已逾時,自動換新 token 失敗(AD 密碼改了,或 AD／MDS 不通):這個動作沒有執行,請離開後重新登入。${C0}"
  core_log TOKEN_RENEW_FAIL "$what" "token 已用 ${age}s,rc=$rc"
  return 1
}

# ── 選單上看得到哪些項目 ──
# 選單一律全部顯示；要做什麼直接選，沒權限的由 Kafka／MDS 在執行時拒絕（Kafka 動作以本人身分執行，權限由 Kafka 端依 RBAC 強制）。
# 唯一會隱藏項目的情況是緊急主機模式（MDS 連不上，AD 登入做不了）：只開放 OPMENU_EMERGENCY_ITEMS。
# core_menu_permissions：算出 OP_VISIBLE[編號]（1 = 看得到、0 = 隱藏）與選單上方的提示 OP_MENU_NOTE
core_menu_permissions() {
  local id

  declare -gA OP_VISIBLE=()   # -g：在函式裡宣告「全域」的對照表，離開函式後還留著
  OP_MENU_NOTE=""

  for id in "${ACT_IDS[@]}"; do
    OP_VISIBLE[$id]=1
  done

  if [ "${OP_EMERGENCY_HOST:-0}" = 1 ]; then
    for id in "${ACT_IDS[@]}"; do
      if ! _in_words "$id" "$OPMENU_EMERGENCY_ITEMS"; then
        OP_VISIBLE[$id]=0
      fi
    done

    OP_MENU_NOTE="緊急主機模式（MDS 連不上）：只能做主機類項目，每一步都記錄"
  fi
}

# ── 權限閘門：用本人的 token 問 MDS「我能不能做這件事」；任何錯誤一律視為拒絕 ──
# _core_authorize <資源類型:資源名稱:操作>：MDS 回 ALLOWED（而且 HTTP 200）才回 0
#   例：_core_authorize "Topic:__opmenu-host-ops:Alter"
_core_authorize() {
  local spec="$1"
  local resource_type resource_name operation body reply

  resource_type=$(echo "$spec" | cut -d: -f1)
  resource_name=$(echo "$spec" | cut -d: -f2)
  operation=$(echo "$spec" | cut -d: -f3)

  body=$(printf '{"userPrincipal":"User:%s","actions":[{"resourceType":"%s","resourceName":"%s","operation":"%s","scope":{"clusters":{"kafka-cluster":"%s"}}}]}' "$OP_USER" "$resource_type" "$resource_name" "$operation" "${OPMENU_KAFKA_CLUSTER_ID:-}")
  reply=$(be_mds PUT /security/1.0/authorize "$body" 2> /dev/null)

  if echo "$reply" | grep -qF '["ALLOWED"]'; then
    if echo "$reply" | grep -qF 'HTTP 200'; then
      return 0
    fi
  fi

  return 1
}

# core_admin_gate：用備用身分執行的項目（91 緊急模式）之前，確認「本人」有 OPMENU_ADMIN_AUTHZ 這個權限
core_admin_gate() {
  # 沒設定就不檢查
  if [ -z "${OPMENU_ADMIN_AUTHZ:-}" ]; then
    return 0
  fi

  if _core_authorize "$OPMENU_ADMIN_AUTHZ"; then
    return 0
  fi

  # 訊息裡有 "Authorization failed"，執行流程會把這一筆記成 DENIED
  echo "${CR}Authorization failed:這個項目以備用身分執行,需要本人有管理員權限($OPMENU_ADMIN_AUTHZ),你的群組沒有;請依變更單申請。${C0}"
  return 1
}

# core_host_gate：碰主機之前確認「本人」有 OPMENU_HOST_ACTION_AUTHZ 這個權限（同一次登入問過一次就記住）
#   主機端的 cpuser 是共用帳號，sudo 分不出是誰，所以碰主機前用本人的身分問 MDS。
#   注意：操作者在操作機上是 root，這道閘門是流程控管、不是硬性隔離（root 可以直接用金鑰 ssh）；追溯靠 CyberArk 的登入紀錄與 PSMP 錄影。
core_host_gate() {
  # 緊急主機模式：MDS 連不上，問不到權限；只開放 OPMENU_EMERGENCY_ITEMS，必填原因、記 EMERGENCY_HOST
  if [ "${OP_EMERGENCY_HOST:-0}" = 1 ]; then
    return 0
  fi

  # 沒設定就不檢查；這次登入已經通過就不再問
  if [ -z "${OPMENU_HOST_ACTION_AUTHZ:-}" ]; then
    return 0
  fi
  if [ "${OP_HOST_OK:-0}" = 1 ]; then
    return 0
  fi

  if _core_authorize "$OPMENU_HOST_ACTION_AUTHZ"; then
    OP_HOST_OK=1
    return 0
  fi

  # 訊息裡有 "Authorization failed"，執行流程會把這一筆記成 DENIED
  echo "${CR}主機類動作 Authorization failed:需要叢集層級權限($OPMENU_HOST_ACTION_AUTHZ),你的群組沒有;請依變更單申請。${C0}"
  return 1
}
# 「碰主機」的介面（lib/hosts.sh 的 be_service_restart、be_service_logs、be_disk_usage、be_collect_diag）
# 每一個開頭都自己呼叫 core_host_gate：新增項目時不管走哪一條路呼叫它們，都會先過閘門。新增碰主機的 be_* 函式時也要這樣寫。

# ── 小工具 ──
# _in_words <字> "<一串字>"：這個字在那一串（用空白隔開）裡面就回 0，例 _in_words 21 "16 18 21" → 0
_in_words() {
  local word="$1"
  local item

  for item in $2; do
    if [ "$item" = "$word" ]; then
      return 0
    fi
  done

  return 1
}

# ── 並行鎖：同一時間只允許一個人做變更類項目（只在同一台操作機有效）──
# 鎖就是一個目錄 OPMENU_LOCK_DIR：建得出來 = 拿到鎖（mkdir 不會兩個人同時成功）；裡面的 info 記著誰在用：
#   <行程編號> <操作者> <項目> | <時間>，例：12345 alice 31 建立 topic | 2026-11-01 10:00:00
# core_lock_acquire <項目>：拿鎖。拿著的人的行程已經不在，就當成過期、接手；等超過 OPMENU_LOCK_WAIT 秒就放棄
core_lock_acquire() {
  local what="$1"
  local dir="$OPMENU_LOCK_DIR"
  local waited=0
  local holder holder_pid holder_desc

  mkdir -p "$(dirname "$dir")" 2> /dev/null

  # umask 000：讓每個操作者都能刪掉這個鎖（前一個人的行程不在時要能接手）
  while ! ( umask 000; mkdir "$dir" ) 2> /dev/null; do
    holder=$(cat "$dir/info" 2> /dev/null)
    holder_pid=$(echo "$holder" | cut -d' ' -f1)
    holder_desc=$(echo "$holder" | cut -d' ' -f2-)

    # 拿著的人的行程已經不在：過期，刪掉再拿一次
    if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2> /dev/null && [ ! -d "/proc/$holder_pid" ]; then
      rm -rf "$dir"
      continue
    fi

    # 等太久了：放棄，告訴操作者是誰在做
    if [ "$waited" -ge "${OPMENU_LOCK_WAIT:-0}" ]; then
      echo "${CR}目前有其他變更作業進行中($holder_desc),請稍後再試${C0}"
      return 1
    fi

    sleep 2
    waited=$(( waited + 2 ))
  done

  printf '%s %s %s | %s\n' "$$" "$OP_USER" "$what" "$(date '+%F %T')" > "$dir/info"
  chmod 666 "$dir/info" 2> /dev/null
  OP_LOCK_HELD=1
}

# core_lock_release：自己拿著鎖才刪
core_lock_release() {
  if [ "${OP_LOCK_HELD:-0}" = 1 ]; then
    rm -rf "$OPMENU_LOCK_DIR"
  fi

  OP_LOCK_HELD=0
  return 0
}

# ── 變更時窗：變更類項目只能在 OPMENU_CHANGE_WINDOW 設定的時段做 ──
# 設定的寫法：一個時段「星期 開始-結束」，多個時段用分號隔開，例如
#   'Mon-Fri 22:00-06:00;Sat,Sun 00:00-23:59'
#   - 星期可以寫英文縮寫（Mon … Sun）或數字（1 = 週一 … 7 = 週日），範圍用 -、多個用逗號，* = 每天
#   - 結束比開始早（例如 22:00-06:00）代表跨午夜：週一 22:00 到週二 06:00 都算「週一的時段」
# core_window_ok：現在在時段內（或沒設時段）就回 0
#   測試用：OPMENU_NOW_OVERRIDE="<星期 1-7> <HH:MM>" 指定「現在」（只在 OPMENU_ALLOW_ENV_OVERRIDE=1 時生效）
core_window_ok() {
  # 沒設時段 = 不限制
  if [ -z "${OPMENU_CHANGE_WINDOW:-}" ]; then
    return 0
  fi

  # 1. 現在是星期幾、幾點幾分
  local now=""
  if [ "${OPMENU_ALLOW_ENV_OVERRIDE:-0}" = 1 ]; then
    now="${OPMENU_NOW_OVERRIDE:-}"
  fi
  if [ -z "$now" ]; then
    now=$(date '+%u %H:%M')   # %u：星期一是 1、星期日是 7
  fi

  local today yesterday now_minutes
  today=$(echo "$now" | cut -d' ' -f1)
  now_minutes=$(_minutes_of "$(echo "$now" | cut -d' ' -f2)")
  yesterday=$(( (today + 5) % 7 + 1 ))   # 週一的前一天是週日（7）

  # 2. 一個時段一行（分號換成換行），逐一比對
  local windows window days range start end
  windows=$(echo "$OPMENU_CHANGE_WINDOW" | tr ';' '\n')

  while IFS= read -r window; do
    # 去掉前後的空白；空的跳過
    window=$(echo "$window" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [ -z "$window" ]; then
      continue
    fi

    # 「星期」是第一個字，「開始-結束」是最後一個字
    days=$(echo "$window" | awk '{print $1}')
    range=$(echo "$window" | awk '{print $NF}')
    start=$(_minutes_of "$(echo "$range" | cut -d- -f1)")
    end=$(_minutes_of "$(echo "$range" | cut -d- -f2)")

    if [ "$start" -le "$end" ]; then
      # 當天的時段：今天在星期範圍內，而且在開始與結束之間
      if _day_in "$today" "$days" && [ "$now_minutes" -ge "$start" ] && [ "$now_minutes" -le "$end" ]; then
        return 0
      fi
    else
      # 跨午夜的時段：今天在範圍內、而且已經過了開始時間；或昨天在範圍內、而且還沒到結束時間
      if _day_in "$today" "$days" && [ "$now_minutes" -ge "$start" ]; then
        return 0
      fi
      if _day_in "$yesterday" "$days" && [ "$now_minutes" -le "$end" ]; then
        return 0
      fi
    fi
  done <<EOF
$windows
EOF

  return 1
}

# _minutes_of <HH:MM>：換成從午夜算起的分鐘數，例 _minutes_of 22:30 → 1350
#   10# 讓 08、09 這種開頭是 0 的數字照十進位算（不然 bash 會當成八進位而出錯）
_minutes_of() {
  local hours minutes
  hours=$(echo "$1" | cut -d: -f1)
  minutes=$(echo "$1" | cut -d: -f2)
  echo $(( 10#$hours * 60 + 10#$minutes ))
}

# _day_num <星期>：英文縮寫或數字換成 1-7（週一是 1、週日是 7；0 也當週日），認不得就回 1
_day_num() {
  local day
  day=$(echo "$1" | tr 'A-Z' 'a-z')

  case "$day" in
    mon|1) echo 1 ;;
    tue|2) echo 2 ;;
    wed|3) echo 3 ;;
    thu|4) echo 4 ;;
    fri|5) echo 5 ;;
    sat|6) echo 6 ;;
    sun|7|0) echo 7 ;;
    *) return 1 ;;
  esac
}

# _day_in <1-7> <星期範圍>：這一天在不在範圍內。範圍例如 "Mon-Fri"、"Sat,Sun"、"1-5"、"*"、"Fri-Mon"（跨週末）
_day_in() {
  local day="$1"
  local spec="$2"
  local part first last current

  if [ "$spec" = '*' ]; then
    return 0
  fi

  # 逗號隔開的每一段：一天（Sat），或一個範圍（Mon-Fri）
  for part in $(echo "$spec" | tr ',' ' '); do
    case "$part" in
      *-*)
        if ! first=$(_day_num "$(echo "$part" | cut -d- -f1)"); then
          continue
        fi
        if ! last=$(_day_num "$(echo "$part" | cut -d- -f2)"); then
          continue
        fi

        # 從 first 一天一天往後走到 last（過了週日就回到週一）
        current=$first
        while true; do
          if [ "$current" = "$day" ]; then
            return 0
          fi
          if [ "$current" = "$last" ]; then
            break
          fi
          current=$(( current % 7 + 1 ))
        done
        ;;
      *)
        if ! first=$(_day_num "$part"); then
          continue
        fi
        if [ "$first" = "$day" ]; then
          return 0
        fi
        ;;
    esac
  done

  return 1
}
