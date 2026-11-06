#!/usr/bin/env bash
# 測「主機用的 SSH 私鑰是檔案 OPMENU_SSH_KEY_FILE」:碰主機的項目在檔案不存在時被擋下、ssh 指令帶這把金鑰且不用 ssh-agent;不需要叢集或保管庫。
#   ./test-ssh-key.sh      全部通過印 "ALL PASS",有失敗回傳 1
if ! cd "$(dirname "$0")/.."; then
  exit 1
fi

OPMENU_LOG="$(mktemp)"
export OPMENU_HOME="$PWD" OPMENU_LOG OPMENU_SYSLOG=0 OPMENU_ALLOW_ENV_OVERRIDE=1 OPMENU_YES=1
export OPMENU_BROKER_SERVICES='kb01:confluent-server' OPMENU_HOSTS='kb01' OPMENU_KAFKA_CLUSTER_ID=test-cluster
. lib/defaults.sh
. lib/common.sh
. lib/kafka.sh
. lib/hosts.sh
# shellcheck source=/dev/null
load_items items
OP_USER=tester OP_LAST_RAW="$(mktemp)"

fails=0
check() {
  if eval "$2"; then
    echo "ok   - $1"
  else
    echo "FAIL - $1"
    fails=$((fails+1))
  fi
}

KEYDIR="$(mktemp -d)"
# ── 預設值:cpuser、/secure/ssh 底下的金鑰檔 ──
check "預設 ssh 帳號是 cpuser" '[ "$OPMENU_SSH_USER" = cpuser ]'
check "預設私鑰檔在 /secure/ssh" '[ "$OPMENU_SSH_KEY_FILE" = /secure/ssh/cpuser_ed25519 ]'
check "沒有 ssh-agent 相關設定" \
  '! declare -F core_load_ssh_key >/dev/null && ! declare -F core_unload_ssh_key >/dev/null && '\
'! declare -F core_ssh_key_on_demand >/dev/null && '\
'[ -z "${OPMENU_SSH_KEY_LOAD:-}" ] && [ -z "${OPMENU_SSH_KEY_SECRET:-}" ]'

# ── 檔案在不在 ──
OPMENU_SSH_KEY_FILE="$KEYDIR/missing"
core_check_ssh_key >/dev/null
rc=$?
check "私鑰檔不存在:回傳非 0" '[ $rc -ne 0 ]'

OPMENU_SSH_KEY_FILE=""
core_check_ssh_key >/dev/null
rc=$?
check "沒設定私鑰檔:回傳非 0" '[ $rc -ne 0 ]'

: > "$KEYDIR/k"
OPMENU_SSH_KEY_FILE="$KEYDIR/k"
core_check_ssh_key >/dev/null
rc=$?
check "私鑰檔在:回傳 0" '[ $rc -eq 0 ]'

# ── 碰主機的項目:沒有私鑰檔就擋下(BLOCKED),不呼叫後端 ──
be_name() {
  echo fake
}

be_mds() {
  printf '["ALLOWED"]\nHTTP 200'
}

CALLED=""
be_service_restart() {
  CALLED+="$1 "
  echo restarted
}

core_guard_host_actions
OPMENU_SSH_KEY_FILE="$KEYDIR/missing"
declare -A OP_VISIBLE=([21]=1)
out=$(core_run 21 kb01:confluent-server 2>&1)
rc=$?
check "沒有私鑰檔:21 被擋下、沒重啟" '[ $rc -ne 0 ] && [ -z "$CALLED" ] && [[ "$out" == *"找不到主機用的 SSH 私鑰"* ]]'
check "擋下有記錄 BLOCKED" 'grep -q "BLOCKED" "$OPMENU_LOG"'

# ── _ssh 的參數:帶私鑰檔、只用這把、不用 agent ──
OP_SSH_ARGS="$KEYDIR/args"
ssh() {
  printf '%s\n' "$@" > "$OP_SSH_ARGS"
}

OPMENU_SSH_KEY_FILE="$KEYDIR/k"
OPMENU_KNOWN_HOSTS="$KEYDIR/kh"
OPMENU_TMPDIR="$KEYDIR"
_ssh kb01 hostname
check "ssh 帶 -i 私鑰檔" 'grep -qx -- "-i" "$OP_SSH_ARGS" && grep -qx -- "$KEYDIR/k" "$OP_SSH_ARGS"'
check "ssh 只用指定的金鑰、不問 agent" \
  'grep -qx "IdentitiesOnly=yes" "$OP_SSH_ARGS" && grep -qx "IdentityAgent=none" "$OP_SSH_ARGS"'
check "ssh 以 cpuser 登入" 'grep -qx "cpuser@kb01" "$OP_SSH_ARGS"'
unset -f ssh

# ── 哪些項目算碰主機 ──
OPMENU_HOST_ITEMS="16 18 21 22 23 27"
check "21(第 2 層)算碰主機" "core_item_touches_host 21"
check "16 算碰主機" "core_item_touches_host 16"
check "12(看 topic)不算碰主機" "! core_item_touches_host 12"

rm -rf "$KEYDIR" "$OPMENU_LOG"

if [ $fails -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails 項失敗"
  exit 1
fi
