#!/usr/bin/env bash
# lab 專用：在 ops02 以 cpadmin 跑。需要已裝好的 OP menu（第 17 站）與 ~/.ssh/id_ed25519（模擬從 PVWA 取出的那把）。
# OP menu 人工模式（OPMENU_SECRETS=manual）實測。在 ops02 以 cpadmin 跑；用 script 開虛擬終端機，模擬維運人員從 PVWA 貼上私鑰。
#   A. Kafka 類項目（12 看 topic）：不應該要求貼私鑰
#   B. 主機類項目（23 看日誌）：應該提示到 PVWA 取 → 貼上 → 正常執行；貼的內容不出現在畫面
#   C. 主機類項目但什麼都不貼（直接 Ctrl-D）：應該擋下、不執行
#   D. 沒有主機權限的人（carol）做主機類項目：權限閘門先擋，不應該要求貼私鑰
#   最後：沒有殘留的 ssh-agent、磁碟上沒有私鑰
set -uo pipefail
source ~/install/conf/site.env
MENU_USER=$OPMENU_OS_USER
MANUAL_CONF=/etc/opmenu/opmenu-manual-test.conf
OUT=$HOME/opmenu-manual-test; install -d -m 0700 "$OUT"
TEST_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass")
PASS_COUNT=0; FAIL_COUNT=0
check() { if eval "$2"; then echo "ok   $1"; PASS_COUNT=$((PASS_COUNT + 1)); else echo "FAIL $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi; }

# 測試用設定：和正式的一樣，只把來源改成 manual、object 名稱改成 PVWA 上看得到的說明
sudo sed -e 's|^OPMENU_SECRETS=.*|OPMENU_SECRETS=manual|' \
         -e 's|^OPMENU_SSH_KEY_SECRET=.*|OPMENU_SSH_KEY_SECRET="Safe KAFKA-OPS / cpadmin-hosts（SSH key）"|' \
         -e 's|^OPMENU_BREAKGLASS_SECRET=.*|OPMENU_BREAKGLASS_SECRET="Safe KAFKA-OPS / opmenu-breakglass（PEM）"|' \
         /etc/opmenu/opmenu.conf | sudo install -m 0644 /dev/stdin "$MANUAL_CONF"

# menu_in_terminal <AD 帳號> <輸出檔> <項目與參數…>：在虛擬終端機裡跑一次選單；stdin 的內容會被「打字」進那個終端機
menu_in_terminal() {
  local person=$1 out_file=$2; shift 2
  local command="sudo env OPMENU_CONF=$MANUAL_CONF OPMENU_USER=$person OPMENU_PASS='$TEST_PASSWORD' OPMENU_YES=1 OPMENU_REASON=manual-test JAVA_HOME=/opt/java/current HOME=/home/$MENU_USER runuser -p -u $MENU_USER -- /opt/opmenu/opmenu.sh --run $*"
  script -q -e -c "$command" /dev/null > "$out_file" 2>&1
  sed -i 's/\x1b\[[0-9;]*m//g; s/\r//g' "$out_file"
}

echo "== A. carol 看 topic（Kafka 類）"
menu_in_terminal carol "$OUT/a.txt" 12 </dev/null
check "沒有要求貼私鑰" "! grep -q 'PVWA' '$OUT/a.txt'"
check "項目照常執行（列出 topic）" "grep -q 'orders.events' '$OUT/a.txt'"

echo "== B. bob 看 kb04 的日誌（主機類），貼上私鑰"
{ sleep 8; cat ~/.ssh/id_ed25519; printf '\n\004'; } | menu_in_terminal bob "$OUT/b.txt" 23 "kb04.$DOMAIN:confluent-server" 5
check "提示到 PVWA 取私鑰" "grep -q '請到 CyberArk PVWA 取出：Safe KAFKA-OPS / cpadmin-hosts' '$OUT/b.txt'"
check "貼上的私鑰沒有出現在畫面" "! grep -q 'PRIVATE KEY' '$OUT/b.txt'"
# 畫面內容會隨 kb04 最近的日誌而變，改看選單自己的紀錄：bob 這次的 23 號結果是 OK
check "項目照常執行（選單紀錄：bob 的 23 號 OK）" "grep -q '| bob | .*23 查看服務日誌 .* | OK |' <<<\"\$(sudo tail -10 /var/log/opmenu/opmenu.log)\""

echo "== C. bob 看日誌，但什麼都不貼"
{ sleep 8; printf '\004'; } | menu_in_terminal bob "$OUT/c.txt" 23 "kb04.$DOMAIN:confluent-server" 5
check "提示到 PVWA 取私鑰" "grep -q '請到 CyberArk PVWA' '$OUT/c.txt'"
check "沒貼就不執行（取不到私鑰）" "grep -q '無法從保管庫取得主機用的 SSH 私鑰' '$OUT/c.txt'"

echo "== D. carol 看日誌（沒有主機權限）"
menu_in_terminal carol "$OUT/d.txt" 23 "kb04.$DOMAIN:confluent-server" 5 </dev/null
check "權限閘門先擋（或選單上看不到）" "grep -q 'Authorization failed\|不在你的選單內' '$OUT/d.txt'"
check "沒有要求貼私鑰" "! grep -q 'PVWA' '$OUT/d.txt'"

echo "== 收尾"
sleep 2
check "沒有殘留的 ssh-agent" "[ \"\$(pgrep -x ssh-agent | wc -l)\" = 0 ]"
check "磁碟上沒有私鑰（op01 家目錄、/dev/shm、選單暫存）" "[ \"\$(sudo grep -rls 'PRIVATE KEY' /home/$MENU_USER /dev/shm /var/log/opmenu 2>/dev/null | wc -l)\" = 0 ]"
check "選單紀錄有 SSH_KEY_LOADED（B）與 SSH_KEY_FAIL（C）" "recent=\$(sudo tail -30 /var/log/opmenu/opmenu.log); grep -q SSH_KEY_LOADED <<<\"\$recent\" && grep -q SSH_KEY_FAIL <<<\"\$recent\""
sudo rm -f "$MANUAL_CONF"
echo "人工模式：$PASS_COUNT 項通過、$FAIL_COUNT 項失敗（畫面輸出在 $OUT/）"
