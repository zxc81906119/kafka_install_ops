#!/usr/bin/env bash
# 測「主機用的 SSH 私鑰從保管庫取進 ssh-agent、離開時清掉」(core_load_ssh_key / core_unload_ssh_key);不需要叢集或保管庫:secret_get 以假的函式代替。
#   ./test-ssh-key.sh      全部通過印 "ALL PASS",有失敗回傳 1
cd "$(dirname "$0")/.." || exit 1
command -v ssh-agent >/dev/null && command -v ssh-keygen >/dev/null || { echo "需要 ssh-agent 與 ssh-keygen"; exit 1; }
OPMENU_LOG="$(mktemp)"
export OPMENU_HOME="$PWD" OPMENU_LOG OPMENU_SYSLOG=0 OPMENU_ALLOW_ENV_OVERRIDE=1
. lib/defaults.sh; . lib/common.sh
OP_USER=tester

# 假保管庫:回一把臨時產生的私鑰;SECRET_OK=0 時模擬取不到
KEYDIR="$(mktemp -d)"; ssh-keygen -q -t ed25519 -N '' -f "$KEYDIR/k" >/dev/null
SECRET_OK=1
secret_get() { [ "$SECRET_OK" = 1 ] || { echo "fake: denied" >&2; return 1; }; cat "$KEYDIR/k"; }

fails=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

OPMENU_SSH_KEY_SECRET='kafka/ssh/cpadmin'; OPMENU_SSH_KEY_TTL=60
core_load_ssh_key; rc=$?
check "取得金鑰:回傳 0" '[ $rc -eq 0 ]'
check "agent 裡有一把金鑰" '[ "$(ssh-add -l 2>/dev/null | wc -l)" = 1 ]'
check "金鑰指紋和保管庫給的一樣" '[ "$(ssh-add -l | awk "{print \$2}")" = "$(ssh-keygen -lf "$KEYDIR/k.pub" | awk "{print \$2}")" ]'
check "磁碟上沒有私鑰副本(只在 agent 記憶體)" '! grep -rqs "PRIVATE KEY" "${OPMENU_TMPDIR}"/opmenu.* 2>/dev/null'
check "有記錄 SSH_KEY_LOADED" 'grep -q "SSH_KEY_LOADED" "$OPMENU_LOG"'
pid="$OP_SSH_AGENT_PID"
core_unload_ssh_key
for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
check "離開後 agent 結束" '! kill -0 "$pid" 2>/dev/null'
check "環境變數已清掉" '[ -z "${SSH_AUTH_SOCK:-}" ]'

SECRET_OK=0; core_load_ssh_key >/dev/null 2>&1; rc=$?
check "保管庫取不到:回傳非 0、沒有留下 agent" '[ $rc -ne 0 ] && [ -z "${OP_SSH_AGENT_PID:-}" ]'
check "取不到有記錄 SSH_KEY_FAIL" 'grep -q "SSH_KEY_FAIL" "$OPMENU_LOG"'

OPMENU_SSH_KEY_SECRET=''; core_load_ssh_key; rc=$?
check "沒設定 SSH_KEY_SECRET:不取、回傳 0" '[ $rc -eq 0 ] && [ -z "${OP_SSH_AGENT_PID:-}" ]'

rm -rf "$KEYDIR" "$OPMENU_LOG"
[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails 項失敗"; exit 1; }
