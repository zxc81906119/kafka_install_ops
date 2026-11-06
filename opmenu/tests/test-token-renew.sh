#!/usr/bin/env bash
# 測 MDS token 自動換新(core_token_fresh):每個動作開始前,token 用了超過「壽命 − 邊際」就用本次登入的帳密換新;
# 換不到就不執行動作。不需要叢集:be_mds_login、be_kafka 以假的函式代替。
#   ./test-token-renew.sh      全部通過印 "ALL PASS",有失敗回傳 1
if ! cd "$(dirname "$0")/.."; then
  exit 1
fi

OPMENU_LOG="$(mktemp)"
export OPMENU_HOME="$PWD" OPMENU_LOG OPMENU_SYSLOG=0 OPMENU_YES=1 OPMENU_ALLOW_ENV_OVERRIDE=1
export OPMENU_BROKER_SERVICES='kb01:confluent-server' OPMENU_HOSTS='kb01' OPMENU_KAFKA_CLUSTER_ID=test-cluster
export OPMENU_TOKEN_TTL=3600 OPMENU_TOKEN_RENEW_MARGIN=300
. lib/defaults.sh
. lib/common.sh
# shellcheck source=/dev/null
load_items items
OP_USER=alice OP_LAST_RAW="$(mktemp)"
OP_CLIENT_CONF="$(mktemp)"

JAAS_MODULE='org.apache.kafka.common.security.plain.PlainLoginModule'
JAAS_LINE="sasl.jaas.config=$JAAS_MODULE required username=\"alice\" password=\"S3cret-pw\";"
printf 'security.protocol=SASL_SSL\nsasl.mechanism=PLAIN\n%s\n' "$JAAS_LINE" > "$OP_CLIENT_CONF"

# 假後端:登入成敗由 LOGIN_RC 控制,記下被呼叫幾次、拿到什麼帳密;kafka 工具記下有沒有被呼叫
# 這些假函式在 $(...) 子 shell 裡被呼叫，計數寫檔才帶得回來
LOGIN_RC=0
LOGIN_ARGS_FILE="$(mktemp)"
LOGIN_COUNT="$(mktemp)"
KAFKA_MARK="$(mktemp)"

logins() {
  wc -l < "$LOGIN_COUNT" | tr -d " "
}

kafka_called() {
  if [ -s "$KAFKA_MARK" ]; then
    echo 1
  else
    echo 0
  fi
}

be_mds_login() {
  echo x >> "$LOGIN_COUNT"
  echo "$1:$2" > "$LOGIN_ARGS_FILE"

  if [ "$LOGIN_RC" = 0 ]; then
    echo "new-token-$(logins)"
  fi

  return "$LOGIN_RC"
}

be_kafka() {
  echo x > "$KAFKA_MARK"
  echo "Topic: orders.events"
}

reset_marks() {
  : > "$LOGIN_COUNT"
  : > "$KAFKA_MARK"
}

fails=0
check() {
  if eval "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    fails=$((fails+1))
  fi
}

now=$(date +%s)

OP_TOKEN=old-token
OP_TOKEN_AT=$((now - 60))
reset_marks
core_token_fresh "12 test" >/dev/null
rc=$?
check "token 才用 60 秒:不換、照常執行" '[ $rc = 0 ] && [ "$(logins)" = 0 ] && [ "$OP_TOKEN" = old-token ]'

OP_TOKEN=old-token
OP_TOKEN_AT=$((now - 3400))
reset_marks
LOGIN_RC=0
core_token_fresh "12 test" >/dev/null
rc=$?
check "用了 3400 秒(超過 3600−300):自動換新" '[ $rc = 0 ] && [ "$(logins)" = 1 ] && [ "$OP_TOKEN" = new-token-1 ]'
check "換新用的是本次登入的帳密(取自 OP_CLIENT_CONF)" '[ "$(cat "$LOGIN_ARGS_FILE")" = "alice:S3cret-pw" ]'
check "換新後時間歸零" '[ $(( $(date +%s) - OP_TOKEN_AT )) -lt 5 ]'
check "紀錄有 TOKEN_RENEWED" 'grep -q TOKEN_RENEWED "$OPMENU_LOG"'
check "紀錄裡沒有密碼" '! grep -q S3cret-pw "$OPMENU_LOG"'

OP_TOKEN=old-token
OP_TOKEN_AT=$((now - 3700))
reset_marks
LOGIN_RC=1
out=$(core_run 12 2>&1)
rc=$?
check "換不到(AD 密碼改了):動作不執行、回傳失敗" '[ $rc -ne 0 ] && [ "$(kafka_called)" = 0 ]'
check "換不到:告訴操作者重新登入" '[[ "$out" == *"請離開後重新登入"* ]]'
check "換不到:紀錄有 TOKEN_RENEW_FAIL" 'grep -q TOKEN_RENEW_FAIL "$OPMENU_LOG"'

OP_TOKEN=old-token
OP_TOKEN_AT=$((now - 3400))
reset_marks
LOGIN_RC=0
out=$(core_run 12 2>&1)
rc=$?
check "快到期時跑 12:先換新再執行" '[ $rc = 0 ] && [ "$(kafka_called)" = 1 ] && [[ "$out" == *orders.events* ]]'

OP_TOKEN=""
OP_TOKEN_AT=""
reset_marks
core_token_fresh "93 test" >/dev/null
rc=$?
check "緊急主機模式(沒有 token):不換、不擋" '[ $rc = 0 ] && [ "$(logins)" = 0 ]'

rm -f "$OPMENU_LOG" "$OP_LAST_RAW" "$OP_CLIENT_CONF" "$LOGIN_ARGS_FILE" "$LOGIN_COUNT" "$KAFKA_MARK"

if [ "$fails" = 0 ]; then
  echo "ALL PASS"
else
  echo "$fails 項失敗"
  exit 1
fi
