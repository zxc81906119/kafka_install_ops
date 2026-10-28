#!/usr/bin/env bash
# lab 專用：在 ops02 以 root 跑。需要已裝好的 OP menu（第 16 站）；會 ssh 到 kb04、rest02、c3-01、kc01（只讀、建一個臨時帳號後刪掉）。
# OP menu「主機金鑰檔」與 sudoers 窄規則實測（取代舊的 ssh-agent 貼上測試）：
#   A. bob 看 kb04 的日誌（主機類）：用 /secure/ssh 的金鑰檔連線，照常執行；沒有 ssh-agent、不提示貼上
#   B. 私鑰檔暫時移走：主機類項目被擋下（BLOCKED），Kafka 類項目（12）不受影響
#   C. carol（沒有主機權限）看日誌：權限閘門先擋
#   D. 各主機的 /etc/sudoers.d/cpuser-ops：用臨時帳號 sudotest 套同一份規則，驗證只放行逐一列出的寫法
#      （restart／status／journalctl -u <自己的服務> -n 200 --no-pager 放行；多帶參數、別的服務、萬用字元那類寫法一律拒絕）。
#      不動 cpuser 自己的全權規則，所以安裝期也能跑。
set -uo pipefail
source ~/install/conf/site.env
source ~/install/lib/ssh.sh
export JAVA_HOME=/opt/java/current
OUT=$HOME/opmenu-hostkey-test; install -d -m 0700 "$OUT"
TEST_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass")
PASS_COUNT=0; FAIL_COUNT=0
check() { if eval "$2"; then echo "ok   $1"; PASS_COUNT=$((PASS_COUNT + 1)); else echo "FAIL $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi; }
KEY_AWAY=$SSH_KEY.away
restore_key() { [ -f "$KEY_AWAY" ] && mv "$KEY_AWAY" "$SSH_KEY"; return 0; }
trap restore_key EXIT

run_menu() {   # run_menu <AD 帳號> <輸出檔> <項目與參數…>
  local person=$1 out_file=$2; shift 2
  env OPMENU_USER="$person" OPMENU_PASS="$TEST_PASSWORD" OPMENU_YES=1 OPMENU_REASON=hostkey-test \
      /opt/opmenu/opmenu.sh --run "$@" > "$out_file" 2>&1 </dev/null
  sed -i 's/\x1b\[[0-9;]*m//g' "$out_file"
}
last_log() { tail -n "${1:-5}" /var/log/opmenu/opmenu.log; }

echo "== A. bob 看 kb04 的日誌（用金鑰檔）"
run_menu bob "$OUT/a.txt" 23 "kb04.$DOMAIN:confluent-server" 5
check "選單紀錄：bob 的 23 號 OK" "grep -q '| bob | .*23 查看服務日誌 .* | OK |' <<<\"\$(last_log 10)\""
check "沒有提示貼上私鑰" "! grep -q '貼上' '$OUT/a.txt'"
check "操作機沒有 ssh-agent" "[ \"\$(pgrep -x ssh-agent | wc -l)\" = 0 ]"

echo "== B. 私鑰檔暫時移走"
mv "$SSH_KEY" "$KEY_AWAY"
run_menu bob "$OUT/b.txt" 23 "kb04.$DOMAIN:confluent-server" 5
check "主機類項目被擋下並說明" "grep -q '找不到主機用的 SSH 私鑰' '$OUT/b.txt'"
check "選單紀錄：BLOCKED（no ssh key file）" "grep -q '23 查看服務日誌 .* | BLOCKED |.*no ssh key file' <<<\"\$(last_log 10)\""
run_menu carol "$OUT/b2.txt" 12
check "Kafka 類項目（12）照常" "grep -q 'orders.events' '$OUT/b2.txt'"
restore_key
check "私鑰檔已放回（root:root 400）" "[ \"\$(stat -c '%U:%G %a' '$SSH_KEY')\" = 'root:root 400' ]"

echo "== C. carol（沒有主機權限）看日誌"
run_menu carol "$OUT/c.txt" 23 "kb04.$DOMAIN:confluent-server" 5
check "權限閘門先擋" "grep -q 'Authorization failed' '$OUT/c.txt'"

echo "== D. sudoers 窄規則（臨時帳號 sudotest 套同一份規則）"
for host in kb04 kc01 rest02 "$C3_HOST"; do
  unit=$(unit_of "$host")
  result=$(ssh_script "$host" UNIT="$unit" SSH_USER="$SSH_USER" <<'EOF' 2>&1
sudo useradd -M -s /usr/sbin/nologin sudotest 2>/dev/null
trap 'sudo rm -f /etc/sudoers.d/zz-sudotest; sudo userdel sudotest 2>/dev/null' EXIT
sudo sed "s/^$SSH_USER /sudotest /" "/etc/sudoers.d/$SSH_USER-ops" | sudo install -m 0440 /dev/stdin /etc/sudoers.d/zz-sudotest
sudo visudo -cf /etc/sudoers.d/zz-sudotest >/dev/null || { echo "visudo 失敗"; exit 0; }
can() { sudo -u sudotest sudo -n -l "$@" >/dev/null 2>&1 && echo yes || echo no; }
echo "allowed: $(can /usr/bin/systemctl restart "$UNIT") $(can /usr/bin/systemctl status "$UNIT") $(can /usr/bin/journalctl -u "$UNIT" -n 200 --no-pager)"
echo "denied: $(can /usr/bin/systemctl restart sshd) $(can /usr/bin/systemctl restart "$UNIT" sshd) $(can /usr/bin/systemctl status "$UNIT" sshd) $(can /usr/bin/journalctl -u "$UNIT") $(can /usr/bin/journalctl -u "$UNIT" -n 5 --no-pager) $(can /usr/bin/journalctl -D /etc) $(can /usr/bin/journalctl -u sshd -n 200 --no-pager) $(can /usr/bin/systemctl restart confluent-other) $(can /usr/bin/systemctl stop "$UNIT")"
EOF
)
  check "$host（$unit）放行：restart、status、journalctl -n 200" "[ \"\$(grep '^allowed:' <<<\"\$result\")\" = 'allowed: yes yes yes' ]"
  check "$host 拒絕：別的服務、多帶參數、-D、stop（9 種寫法全部 no）" "[ \"\$(grep '^denied:' <<<\"\$result\")\" = 'denied: no no no no no no no no no' ]"
done
check "臨時帳號已清掉" "[ \"\$(ssh_run kb04 'id sudotest 2>/dev/null | wc -l')\" = 0 ]"

echo "== 收尾"
check "沒有 ssh-agent、/dev/shm 與選單暫存沒有私鑰" "[ \"\$(pgrep -x ssh-agent | wc -l)\" = 0 ] && [ \"\$(grep -rls 'PRIVATE KEY' /dev/shm /var/log/opmenu 2>/dev/null | wc -l)\" = 0 ]"
echo "主機金鑰與 sudoers：$PASS_COUNT 項通過、$FAIL_COUNT 項失敗（畫面輸出在 $OUT/）"
