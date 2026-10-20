#!/usr/bin/env bash
# 測動態選單(core_menu_permissions):依 MDS 回答只顯示有權限的項目;看不到的項目直接輸入編號也會被擋並記錄;
# MDS 問不到時全部顯示(執行時仍會檢查)。不需要叢集:MDS 以假的函式代替。
#   ./test-menu-filter.sh      全部通過印 "ALL PASS",有失敗回傳 1
cd "$(dirname "$0")" || exit 1
OPMENU_LOG="$(mktemp)"
export OPMENU_HOME="$PWD" OPMENU_LOG OPMENU_SYSLOG=0 OPMENU_YES=1 OPMENU_ALLOW_ENV_OVERRIDE=1
export OPMENU_BROKER_SERVICES='kb01:confluent-server' OPMENU_HOSTS='kb01' OPMENU_KAFKA_CLUSTER_ID=test-cluster OPMENU_TICKET_MODE=none
. lib/defaults.sh; . lib/validate.sh; . lib/core.sh
# shellcheck source=/dev/null
for f in lib/actions/*.sh; do . "$f"; done
OP_USER=tester OP_LAST_RAW="$(mktemp)"

# 假 MDS:依請求裡的資源回答;HOST / ADMIN / AUDIT 三種權限各自由變數決定
HOST=DENIED ADMIN=DENIED AUDIT=DENIED MDS_UP=1 CALLS_FILE="$(mktemp)"
be_name() { echo fake; }
be_mds() {
  echo call >> "$CALLS_FILE"; [ "$MDS_UP" = 1 ] || return 1   # 在 $(...) 裡被呼叫:用檔案計次
  local body="$3" a ans=() IFS=$'\n'
  for a in $(printf '%s' "$body" | grep -o '"resourceName":"[^"]*","operation":"[^"]*"'); do
    case "$a" in
      *__opmenu-host-ops*) ans+=("\"$HOST\"");; *'"kafka-cluster","operation":"Alter"'*) ans+=("\"$ADMIN\"");;
      *confluent-audit-log-events*) ans+=("\"$AUDIT\"");; *) ans+=('"DENIED"');;
    esac
  done
  local IFS=,; printf '[%s]\nHTTP 200' "${ans[*]}"
}
act_12() { echo "ran 12"; }; act_23() { echo "ran 23"; }; act_31() { echo "ran 31"; }; act_43() { echo "ran 43"; }

fails=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
visible() { local id r=""; for id in "${ACT_IDS[@]}"; do [ "${OP_VISIBLE[$id]}" = 1 ] && r+="$id "; done; printf '%s' "$r"; }

# 開發(carol):只有查看類
HOST=DENIED ADMIN=DENIED AUDIT=DENIED; : > "$CALLS_FILE"; core_menu_permissions; v=$(visible)
check "開發:只看到查看類(1x、沒有 16、18)" '[[ " $v " == *" 12 "* && " $v " != *" 16 "* && " $v " != *" 18 "* && " $v " != *" 21 "* && " $v " != *" 31 "* ]]'
check "開發:只問 MDS 一次" '[ "$(wc -l < "$CALLS_FILE")" = 1 ]'
out=$(core_run 23 kb01:confluent-server); rc=$?
check "開發:直接輸入看不到的 23 → 擋下、不執行" '[ $rc -ne 0 ] && [[ "$out" != *"ran 23"* && "$out" == *"不在你的選單內"* ]]'
check "開發:擋下有記錄 DENIED / not in menu" 'grep -q "| tester | 23 .*| DENIED | not in menu" "$OPMENU_LOG"'
out=$(core_run 12); check "開發:看得到的 12 照常執行" '[[ "$out" == *"ran 12"* ]]'

# 維運(bob):多了碰主機的項目,沒有變更與稽核
HOST=ALLOWED ADMIN=DENIED AUDIT=DENIED; core_menu_permissions; v=$(visible)
check "維運:看得到 16、18、2x,看不到 3x、4x" '[[ " $v " == *" 16 "* && " $v " == *" 21 "* && " $v " == *" 27 "* && " $v " != *" 31 "* && " $v " != *" 42 "* && " $v " != *" 91 "* ]]'
out=$(core_run 23 kb01:confluent-server); check "維運:23 照常執行" '[[ "$out" == *"ran 23"* ]]'

# 稽核權限另外給:只多 43、45
HOST=DENIED ADMIN=DENIED AUDIT=ALLOWED; core_menu_permissions; v=$(visible)
check "只有稽核權限:多了 43、45,沒有 41、42、44" '[[ " $v " == *" 43 "* && " $v " == *" 45 "* && " $v " != *" 41 "* && " $v " != *" 44 "* ]]'

# 管理員(alice):全部
HOST=ALLOWED ADMIN=ALLOWED AUDIT=ALLOWED; core_menu_permissions
check "管理員:全部項目都看得到" '[ "$(visible | wc -w)" = "${#ACT_IDS[@]}" ]'

# MDS 問不到:全部顯示 + 提示(執行時仍檢查)
MDS_UP=0; core_menu_permissions
check "MDS 問不到:全部顯示並提示" '[ "$(visible | wc -w)" = "${#ACT_IDS[@]}" ] && [[ "$OP_MENU_NOTE" == *"無法取得"* ]]'
MDS_UP=1

# 設定可覆蓋:後面的優先,"-" = 不限制
OPMENU_MENU_AUTHZ='3*=ADMIN 31=-' HOST=DENIED ADMIN=DENIED AUDIT=DENIED; core_menu_permissions; v=$(visible)
check "設定覆蓋:3*=ADMIN 31=- → 31 看得到、32 看不到" '[[ " $v " == *" 31 "* && " $v " != *" 32 "* ]]'
OPMENU_MENU_FILTER=0; core_menu_permissions
check "OPMENU_MENU_FILTER=0:全部顯示(舊行為)" '[ "$(visible | wc -w)" = "${#ACT_IDS[@]}" ]'

rm -f "$OPMENU_LOG" "$OP_LAST_RAW" "$CALLS_FILE"
[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails 項失敗"; exit 1; }
