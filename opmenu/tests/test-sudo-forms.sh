#!/usr/bin/env bash
# 測選單送到主機的每一種 sudo 寫法,都在 /etc/sudoers.d/cpuser-ops 逐一列出的清單裡(sudoers 比對完整參數,多帶任何參數都會被擋);
# 不需要叢集:ssh 以假的函式代替,只收集送出的遠端指令。
#   ./test-sudo-forms.sh      全部通過印 "ALL PASS",有失敗回傳 1
cd "$(dirname "$0")/.." || exit 1
OPMENU_LOG="$(mktemp)"
export OPMENU_HOME="$PWD" OPMENU_LOG OPMENU_SYSLOG=0 OPMENU_YES=1 OPMENU_ALLOW_ENV_OVERRIDE=1
export OPMENU_BROKER_SERVICES='kb01.poc.lab:confluent-server kb02.poc.lab:confluent-server'
export OPMENU_AUX_SERVICES='rest01.poc.lab:confluent-kafka-rest c3-01.poc.lab:confluent-control-center'
export OPMENU_CONTROLLER_HOSTS='kc01.poc.lab'
export OPMENU_HOSTS='kb01.poc.lab kb02.poc.lab rest01.poc.lab c3-01.poc.lab kc01.poc.lab'
. lib/defaults.sh; . lib/common.sh; . lib/hosts.sh

fails=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi; }

# 假 _ssh:把送到「<主機>」的遠端指令記下來
SENT="$(mktemp)"
_ssh() { printf '%s\t%s\n' "$1" "$2" >> "$SENT"; }

# 主機上 sudoers 逐一列出的寫法(和 install/steps/16-opmenu.sh 的規則一致):每個服務 restart、status、journalctl -u <服務> -n <固定行數> --no-pager
allowed_forms() { # <服務> → 一行一種寫法(sudo 後面的部分,引號已去掉)
  local u="$1"
  echo "systemctl restart $u"; echo "systemctl status $u"; echo "journalctl -u $u -n $_JOURNAL_LINES --no-pager"
}
# 取出遠端指令字串裡每一個 "sudo -n …" 的指令(到 | 或 && 或字串結尾為止),去掉單引號
sudo_forms_in() { grep -o 'sudo -n [^|&]*' <<<"$1" | sed -e 's/^sudo -n //' -e "s/'//g" -e 's/ *$//'; }

check "journalctl 固定行數是 200(要和 16-opmenu.sh 的 JOURNAL_LINES 一致)" '[ "$_JOURNAL_LINES" = 200 ]'
if [ -f ../install/steps/16-opmenu.sh ]; then
  check "16-opmenu.sh 的 JOURNAL_LINES 和選單一致" 'grep -q "^JOURNAL_LINES=$_JOURNAL_LINES " ../install/steps/16-opmenu.sh'
fi

# ── 重啟 ──
: > "$SENT"; be_service_restart kb01.poc.lab:confluent-server >/dev/null; be_service_restart rest01.poc.lab:confluent-kafka-rest >/dev/null; be_service_restart c3-01.poc.lab:confluent-control-center >/dev/null
bad=0; while IFS=$'\t' read -r host cmd; do
  for form in $(sudo_forms_in "$cmd" | tr ' ' '~'); do form=${form//\~/ }
    unit=${form##* }; allowed_forms "$unit" | grep -qxF "$form" || { echo "  不在清單:$host: sudo $form"; bad=1; }
  done
done < "$SENT"
check "be_service_restart 的 sudo 寫法都在清單裡" '[ $bad -eq 0 ]'
check "restart 的 sudo 寫法有出現(沒有萬用字元)" '[ "$(grep -c "sudo -n systemctl restart " "$SENT")" = 3 ] && ! grep -q "confluent-\*" "$SENT"'

# ── 看日誌:不管要看幾行,送出的 journalctl 參數都一樣 ──
: > "$SENT"; be_service_logs kb01.poc.lab:confluent-server 5 >/dev/null 2>&1; be_service_logs kb01.poc.lab:confluent-server 100 >/dev/null 2>&1; be_service_logs kb01.poc.lab:confluent-server 5000 >/dev/null 2>&1
forms=$(while IFS=$'\t' read -r host cmd; do sudo_forms_in "$cmd"; done < "$SENT" | sort -u)
check "看日誌:5、100、5000 行送到主機的 sudo 寫法只有一種" '[ "$(wc -l <<<"$forms")" = 1 ]'
check "看日誌的寫法在清單裡" 'allowed_forms confluent-server | grep -qxF "$forms"'
check "看日誌:行數在本機 tail" 'grep -q "| tail -n 5\$" <(sed -n 1p "$SENT" | cut -f2)'

# ── 收集診斷:每台只收自己有的服務,不用 confluent-* ──
: > "$SENT"; be_collect_diag "$(mktemp -d)" >/dev/null 2>&1
bad=0; while IFS=$'\t' read -r host cmd; do
  case $host in kb01.poc.lab|kb02.poc.lab|kc01.poc.lab) want=confluent-server;; rest01.poc.lab) want=confluent-kafka-rest;; c3-01.poc.lab) want=confluent-control-center;; esac
  for form in $(sudo_forms_in "$cmd" | tr ' ' '~'); do form=${form//\~/ }
    allowed_forms "$want" | grep -qxF "$form" || { echo "  不在清單:$host: sudo $form"; bad=1; }
  done
done < "$SENT"
check "be_collect_diag 每台只收自己的服務、寫法都在清單裡" '[ $bad -eq 0 ]'
check "be_collect_diag 五台都有收" '[ "$(cut -f1 "$SENT" | sort -u | wc -l)" = 5 ]'
check "be_collect_diag 沒有萬用字元" '! grep -q "confluent-\*" "$SENT"'

rm -f "$SENT" "$OPMENU_LOG"
[ $fails -eq 0 ] && echo "ALL PASS" || { echo "$fails 項失敗"; exit 1; }
