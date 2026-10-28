#!/usr/bin/env bash
# 測 91 緊急憑證的來源(lib/secrets/file.sh):預設路徑、權限必須 0600/0400 且 owner 是執行者、空檔與不存在的檔被拒絕;不需要叢集。
#   ./test-secret-file.sh      全部通過印 "ALL PASS",有失敗回傳 1
cd "$(dirname "$0")/.." || exit 1
export OPMENU_HOME="$PWD" OPMENU_LOG="$(mktemp)" OPMENU_SYSLOG=0
. lib/defaults.sh; . lib/secrets/file.sh
fails=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

DIR="$(mktemp -d)"; F="$DIR/pem"
check "預設緊急憑證檔在 ~/secrets/opmenu-breakglass.pem" '[ "$OPMENU_BREAKGLASS_PEM" = "$HOME/secrets/opmenu-breakglass.pem" ]'
secret_get "$DIR/none" >/dev/null 2>&1; rc=$?
check "檔案不存在:拒絕" '[ $rc -ne 0 ]'
printf 'x\n' > "$F"; chmod 600 "$F"
if [ "$(stat -c %a "$F")" != 600 ]; then   # Windows Git Bash 的 chmod 不會真的改權限:略過權限相關的檢查,只在 Linux 跑
  echo "skip - 這個環境的 chmod 無效(stat 回 $(stat -c %a "$F")),略過權限檢查"; rm -rf "$DIR"
  [ $fails = 0 ] && echo "ALL PASS (權限檢查略過)" || { echo "$fails FAIL"; exit 1; }; exit 0
fi
check "0600 且 owner 是自己:讀得到內容" '[ "$(secret_get "$F")" = x ]'
chmod 400 "$F"
check "0400:讀得到內容" '[ "$(secret_get "$F")" = x ]'
chmod 644 "$F"; secret_get "$F" >/dev/null 2>&1; rc=$?
check "0644:拒絕" '[ $rc -ne 0 ]'
chmod 640 "$F"; secret_get "$F" >/dev/null 2>&1; rc=$?
check "0640:拒絕" '[ $rc -ne 0 ]'
: > "$F"; chmod 600 "$F"; secret_get "$F" >/dev/null 2>&1; rc=$?
check "空檔:拒絕" '[ $rc -ne 0 ]'
secret_get "" >/dev/null 2>&1; rc=$?
check "沒指定路徑:拒絕" '[ $rc -ne 0 ]'
rm -rf "$DIR"
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
