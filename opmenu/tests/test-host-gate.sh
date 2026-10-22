#!/usr/bin/env bash
# 測主機類動作的權限閘門(core_host_gate)與 21 重啟前檢查「失敗即拒絕」;不需要叢集:後端以假的函式代替。
#   ./test-host-gate.sh      全部通過印 "ALL PASS",有失敗回傳 1
cd "$(dirname "$0")/.." || exit 1
OPMENU_LOG="$(mktemp)"
export OPMENU_HOME="$PWD" OPMENU_LOG OPMENU_SYSLOG=0 OPMENU_YES=1 OPMENU_ALLOW_ENV_OVERRIDE=1
export OPMENU_BROKER_SERVICES='kb01:confluent-server' OPMENU_HOSTS='kb01' OPMENU_KAFKA_CLUSTER_ID=test-cluster
. lib/defaults.sh; . lib/common.sh
# shellcheck source=/dev/null
load_items items
OP_USER=tester OP_LAST_RAW="$(mktemp)"

# 假後端:MDS authorize 的回應、kafka 工具的成敗由變數控制;重啟只留紀錄
MDS_REPLY='["ALLOWED"]'; MDS_RC=0; KAFKA_RC=0; RESTARTED=""
be_name() { echo fake; }
BODY_FILE="$(mktemp)"
be_mds() { printf '%s' "$3" > "$BODY_FILE"; [ "$MDS_RC" = 0 ] || return 1; printf '%s\nHTTP 200' "$MDS_REPLY"; }   # 在 $(...) 裡被呼叫:請求內容寫檔才帶得出來
be_kafka() { [ "$KAFKA_RC" = 0 ] || { echo "org.apache.kafka.common.errors.TimeoutException"; return 1; }; echo ""; }
be_service_restart() { RESTARTED+="$1 "; echo "restarted $1"; }
be_service_logs() { echo "log line"; }
core_guard_host_actions

fails=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }
reset() { unset OP_HOST_OK; RESTARTED=""; }

reset; be_service_restart kb01:confluent-server >/dev/null
check "ALLOWED:重啟有執行" '[ "$RESTARTED" = "kb01:confluent-server " ]'
check "問 MDS 時用的是操作者本人" '[[ "$(cat "$BODY_FILE")" == *"\"userPrincipal\":\"User:tester\""* ]]'
check "問的是設定的資源與 cluster" '[[ "$(cat "$BODY_FILE")" == *"__opmenu-host-ops"* && "$(cat "$BODY_FILE")" == *"test-cluster"* ]]'

reset; MDS_REPLY='["DENIED"]'; out=$(be_service_restart kb01:confluent-server); rc=$?
check "DENIED:不重啟、回傳失敗" '[[ "$out" != *restarted* ]] && [ $rc -ne 0 ]'
check "DENIED:訊息讓 core 記成 DENIED" '[[ "$out" == *"Authorization failed"* ]]'

reset; MDS_REPLY='["DENIED"]'; be_service_logs kb01:confluent-server >/dev/null; rc=$?
check "看日誌也受閘門管" '[ $rc -ne 0 ]'

reset; MDS_REPLY='["DENIED"]'; out=$(act_23 kb01:confluent-server 20); rc=$?
check "23 看日誌:閘門拒絕時回報失敗,不是「沒有錯誤」(原本記成 OK)" '[ $rc -ne 0 ] && [[ "$out" == *"Authorization failed"* ]] && [[ "$out" != *"沒有錯誤"* ]]'

reset; MDS_REPLY='["ALLOWED"]'; MDS_RC=1; be_service_restart kb01:confluent-server >/dev/null; rc=$?
check "MDS 連不上:一律拒絕" '[ -z "$RESTARTED" ] && [ $rc -ne 0 ]'

reset; MDS_RC=0; MDS_REPLY='garbage'; be_service_restart kb01:confluent-server >/dev/null; rc=$?
check "回應看不懂:一律拒絕" '[ -z "$RESTARTED" ] && [ $rc -ne 0 ]'

reset; MDS_REPLY='["DENIED"]'; OPMENU_HOST_ACTION_AUTHZ='' be_service_restart kb01:confluent-server >/dev/null
check "設為空字串:不檢查(node 用本人帳號時)" '[ -n "$RESTARTED" ]'

reset; MDS_REPLY='["ALLOWED"]'; KAFKA_RC=1; out=$(act_21 kb01:confluent-server); rc=$?
check "21:檢查指令失敗時拒絕重啟(原本會放行)" '[[ "$out" != *restarted* ]] && [ $rc -ne 0 ] && [[ "$out" == *"無法檢查"* ]]'

reset; KAFKA_RC=0; act_21 kb01:confluent-server >/dev/null
check "21:檢查通過時照常重啟" '[ "$RESTARTED" = "kb01:confluent-server " ]'

rm -f "$OPMENU_LOG" "$OP_LAST_RAW" "$BODY_FILE"
[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails 項失敗"; exit 1; }
