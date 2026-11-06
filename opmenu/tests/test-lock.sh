#!/usr/bin/env bash
# 測並行鎖（core_lock_acquire／core_lock_release）：有人拿著時拒絕、拿的人的行程已經不在就接手、放掉後可以再拿。
# 不需要叢集。鎖放在暫存目錄。
#   ./test-lock.sh      全部通過印 "ALL PASS",有失敗回傳 1
if ! cd "$(dirname "$0")/.."; then
  exit 1
fi

export OPMENU_HOME="$PWD" OPMENU_LOG="$(mktemp)" OPMENU_SYSLOG=0
. lib/defaults.sh
. lib/common.sh

OPMENU_LOCK_DIR="$(mktemp -d)/opmenu.lock.d"
OPMENU_LOCK_WAIT=0
OP_USER=tester

fails=0
check() {
  if eval "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    fails=$((fails + 1))
  fi
}

# 1. 沒人拿：拿得到，info 裡記了自己的行程編號與操作者
core_lock_acquire "31 建立 topic" > /dev/null
check "沒人拿時拿得到" '[ "$OP_LOCK_HELD" = 1 ] && [ -d "$OPMENU_LOCK_DIR" ]'
check "info 記了行程編號與操作者" 'grep -q "^$$ tester 31 建立 topic" "$OPMENU_LOCK_DIR/info"'

# 2. 別人（還活著的行程）拿著：拒絕，並說是誰在做
OP_LOCK_HELD=0
sleep 300 &
alive_pid=$!
echo "$alive_pid bob 33 刪除 topic | 2026-11-01 10:00:00" > "$OPMENU_LOCK_DIR/info"
out=$(core_lock_acquire "32 修改 retention")
rc=$?
check "別人拿著時拒絕" '[ $rc -ne 0 ]'
check "拒絕訊息說出是誰在做" '[[ "$out" == *"bob 33 刪除 topic"* ]]'
kill "$alive_pid" 2>/dev/null
wait "$alive_pid" 2>/dev/null

# 3. 拿著的行程已經不在：視為過期，接手
echo "999999 carol 34 新增帳號 | 2026-11-01 09:00:00" > "$OPMENU_LOCK_DIR/info"
core_lock_acquire "35 輪替密碼" > /dev/null
check "拿的人的行程已不在時接手" '[ "$OP_LOCK_HELD" = 1 ] && grep -q "^$$ tester 35" "$OPMENU_LOCK_DIR/info"'

# 4. 放掉：目錄消失，可以再拿
core_lock_release
check "放掉後鎖的目錄消失" '[ ! -d "$OPMENU_LOCK_DIR" ] && [ "$OP_LOCK_HELD" = 0 ]'
core_lock_acquire "36 重設 offset" > /dev/null
check "放掉後可以再拿" '[ "$OP_LOCK_HELD" = 1 ]'
core_lock_release

rm -rf "$(dirname "$OPMENU_LOCK_DIR")" "$OPMENU_LOG"

if [ $fails -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails 項失敗"
  exit 1
fi
