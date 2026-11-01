#!/usr/bin/env bash
# 測選單顯示與閘門:選單一律全部顯示;只有緊急主機模式會隱藏項目(直接輸入也擋);91 這類以備用身分執行的項目要先過管理員閘門。
# 不需要叢集:MDS 以假的函式代替。
#   ./test-menu-all.sh      全部通過印 "ALL PASS",有失敗回傳 1
cd "$(dirname "$0")/.." || exit 1
OPMENU_LOG="$(mktemp)"
export OPMENU_HOME="$PWD" OPMENU_LOG OPMENU_SYSLOG=0 OPMENU_YES=1 OPMENU_ALLOW_ENV_OVERRIDE=1
export OPMENU_BROKER_SERVICES='kb01:confluent-server' OPMENU_HOSTS='kb01' OPMENU_KAFKA_CLUSTER_ID=test-cluster
. lib/defaults.sh; . lib/common.sh
OPMENU_SSH_KEY_FILE="$(mktemp)"   # 主機類項目要有私鑰檔才不會被擋(私鑰檢查另有 test-ssh-key.sh)
# shellcheck source=/dev/null
load_items items
OP_USER=tester OP_LAST_RAW="$(mktemp)"

# 假 MDS:主機閘門與管理員閘門各自由變數決定
HOST=DENIED ADMIN=DENIED MDS_UP=1 CALLS_FILE="$(mktemp)"
be_name() { echo fake; }
be_mds() {
  echo call >> "$CALLS_FILE"; [ "$MDS_UP" = 1 ] || return 1
  case "$3" in *__opmenu-host-ops*) printf '["%s"]\nHTTP 200' "$HOST";; *'"kafka-cluster","operation":"Alter"'*) printf '["%s"]\nHTTP 200' "$ADMIN";; *) printf '["DENIED"]\nHTTP 200';; esac
}
run_12() { echo "ran 12"; }; run_23() { echo "ran 23"; }; run_31() { echo "ran 31"; }; run_91() { echo "ran 91"; }

fails=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
visible() { local id r=""; for id in "${ACT_IDS[@]}"; do [ "${OP_VISIBLE[$id]}" = 1 ] && r+="$id "; done; printf '%s' "$r"; }

# 一般登入:全部顯示,不問 MDS
: > "$CALLS_FILE"; core_menu_permissions
check "一般登入:全部項目都顯示" '[ "$(visible | wc -w)" = "${#ACT_IDS[@]}" ]'
check "一般登入:選單不問 MDS" '[ "$(wc -l < "$CALLS_FILE")" = 0 ]'
out=$(core_run 12); check "查看類 12 直接執行" '[[ "$out" == *"ran 12"* ]]'
out=$(core_run 31 orders.x 1); check "變更類 31 直接執行(權限由 Kafka 在執行時判斷)" '[[ "$out" == *"ran 31"* ]]'

# 主機類:執行前過主機閘門
HOST=DENIED; OP_HOST_OK=0; out=$(core_run 23 kb01:confluent-server); rc=$?
check "沒有 Operator:23 被主機閘門擋下" '[ $rc -ne 0 ] && [[ "$out" != *"ran 23"* ]] && grep -q "| 23 .*| DENIED | host gate" "$OPMENU_LOG"'
HOST=ALLOWED; OP_HOST_OK=0; out=$(core_run 23 kb01:confluent-server); check "有 Operator:23 執行" '[[ "$out" == *"ran 23"* ]]'

# 91:以備用身分執行,本人要先過管理員閘門
ADMIN=DENIED; out=$(core_run 91 kafka-topics --list); rc=$?
check "非管理員:91 被管理員閘門擋下並記錄" '[ $rc -ne 0 ] && [[ "$out" != *"ran 91"* && "$out" == *"Authorization failed"* ]] && grep -q "| 91 .*| DENIED | admin gate" "$OPMENU_LOG"'
ADMIN=ALLOWED; out=$(core_run 91 kafka-topics --list); check "管理員:91 執行" '[[ "$out" == *"ran 91"* ]]'
MDS_UP=0; ADMIN=ALLOWED; out=$(core_run 91 kafka-topics --list); rc=$?
check "MDS 問不到:91 一律拒絕" '[ $rc -ne 0 ] && [[ "$out" != *"ran 91"* ]]'
MDS_UP=1

# 緊急主機模式:只開放 OPMENU_EMERGENCY_ITEMS,其他直接輸入也擋
OP_EMERGENCY_HOST=1; core_menu_permissions; v=$(visible)
check "緊急主機模式:只顯示 ${OPMENU_EMERGENCY_ITEMS}" '[ "$(echo $v)" = "$(echo $OPMENU_EMERGENCY_ITEMS)" ] && [[ "$OP_MENU_NOTE" == *"緊急主機模式"* ]]'
out=$(core_run 31 orders.x 1); rc=$?
check "緊急主機模式:直接輸入 31 被擋並記錄" '[ $rc -ne 0 ] && [[ "$out" != *"ran 31"* ]] && grep -q "| 31 .*| DENIED | not in emergency items" "$OPMENU_LOG"'
OP_EMERGENCY_HOST=0

rm -f "$OPMENU_LOG" "$OP_LAST_RAW" "$CALLS_FILE" "$OPMENU_SSH_KEY_FILE"
[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails 項失敗"; exit 1; }
