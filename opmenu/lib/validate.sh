# validate.sh — 使用者輸入的 allowlist 驗證(2026-10-06 加入)。
# 原則:每個會被放進指令、ssh、MDS 路徑或紀錄的字串,都要先過這裡;不符合就回傳 1 並印出原因。
# 驗證規則(樣式)都在 opmenu.conf / lib/defaults.sh,這裡只負責套用。

v_fail() { echo "輸入不接受:$1"; return 1; }
v_match() { [[ "$1" =~ $2 ]] || v_fail "$3(規則:$2)"; }                      # v_match <值> <樣式> <說明>
v_in()    { local x; for x in $2; do [ "$x" = "$1" ] && return 0; done; v_fail "$3:$1 不在允許清單內"; }   # v_in <值> "<清單>" <說明>

v_number()    { v_match "$1" '^[0-9]{1,9}$' "${2:-數字}只能是數字"; }
v_host()      { v_in "$1" "$OPMENU_HOSTS" "node"; }
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
