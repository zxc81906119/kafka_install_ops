#!/usr/bin/env bash
# lab 專用：在 ops02 以 cpadmin 跑。需要已裝好的 OP menu（第 17 站）。
# OP menu「緊急主機模式」實測：用測試設定把 MDS 位址指到不通的埠，模擬 MDS 掛掉。
#   1. 不在 opmenu-emergency 群組 → 擋下，什麼都不能做
#   2. 加進群組 → 只看得到 16 18 21 22 23；Kafka 類（31 建 topic）不能做
#   3. 23 看日誌照常；21 重啟 broker 會警告「無法確認叢集狀態」並要確認，然後重啟
#   4. 紀錄：EMERGENCY_HOST、操作者標成「未經 AD 驗證」、原因有記
#   最後把 op01 移出群組、刪測試設定
set -uo pipefail
source ~/install/conf/site.env
MENU_USER=$OPMENU_OS_USER
TEST_CONF=/etc/opmenu/opmenu-emergency-test.conf
EMERGENCY_GROUP=opmenu-emergency
OUT=$HOME/opmenu-emergency-test; install -d -m 0700 "$OUT"
PASS_COUNT=0; FAIL_COUNT=0
check() { if eval "$2"; then echo "ok   $1"; PASS_COUNT=$((PASS_COUNT + 1)); else echo "FAIL $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi; }

# 測試設定：MDS 指到 8091（沒有服務在聽）→ 選單會判定 MDS 連不上
{ sudo cat /etc/opmenu/opmenu.conf; echo "OPMENU_MDS_URL=https://$FIRST_BROKER:8091"; } | sudo install -m 0644 /dev/stdin "$TEST_CONF"
sudo groupadd -f "$EMERGENCY_GROUP"

# run_menu <AD 帳號> <輸出檔> <項目…>：非互動跑一次（OPMENU_YES=1 自動確認，原因由 OPMENU_REASON 給）
run_menu() {
  local person=$1 out_file=$2; shift 2
  # shellcheck disable=SC2024  # 畫面輸出刻意由 cpadmin 寫進自己的目錄，不需要 root
  sudo env OPMENU_CONF="$TEST_CONF" OPMENU_USER="$person" OPMENU_PASS="$(cat "$SECRETS_DIR/ad-test-users.pass")" OPMENU_YES=1 \
       OPMENU_REASON="INC-0001 MDS 無回應，lab 演練" JAVA_HOME=/opt/java/current HOME=/home/$MENU_USER \
       runuser -p -u "$MENU_USER" -- /opt/opmenu/opmenu.sh --run "$@" > "$out_file" 2>&1 </dev/null
  sed -i 's/\x1b\[[0-9;]*m//g' "$out_file"
}

echo "== 1. $MENU_USER 不在 $EMERGENCY_GROUP 群組"
sudo gpasswd -d "$MENU_USER" "$EMERGENCY_GROUP" >/dev/null 2>&1
run_menu bob "$OUT/1.txt" menu
check "判定 MDS 連不上" "grep -q '無法連到 MDS' '$OUT/1.txt'"
check "不在群組：擋下" "grep -q '只開放給作業系統群組' '$OUT/1.txt' && ! grep -q '@@MENU@@' '$OUT/1.txt'"

echo "== 2. 加進群組（事故時 OS 團隊臨時加入）"
sudo gpasswd -a "$MENU_USER" "$EMERGENCY_GROUP" >/dev/null
run_menu bob "$OUT/2.txt" menu
visible=$(grep '@@MENU@@' "$OUT/2.txt" | cut -d' ' -f2-)
check "進入緊急主機模式" "grep -q '已進入緊急主機模式' '$OUT/2.txt'"
check "只看得到 16 18 21 22 23（實際：$visible）" "[ '$visible' = '16 18 21 22 23' ]"
run_menu bob "$OUT/2b.txt" 31 orders.emergency 1
check "Kafka 類（31 建 topic）不能做" "grep -q '不在你的選單內' '$OUT/2b.txt'"

echo "== 3. 主機類項目"
run_menu bob "$OUT/3a.txt" 23 "kb04.$DOMAIN:confluent-server" 5
check "23 看日誌照常" "grep -q '23 查看服務日誌 .* | OK |' <<<\"\$(sudo tail -20 /var/log/opmenu/opmenu.log)\""
# 服務的啟動時間（systemd 記的）：重啟前後不同，才算真的重啟了
started_before=$(ssh -o BatchMode=yes kb04.$DOMAIN "systemctl show confluent-server -p ActiveEnterTimestampMonotonic --value")
run_menu bob "$OUT/3b.txt" 21 "kb04.$DOMAIN:confluent-server"
started_after=$(ssh -o BatchMode=yes kb04.$DOMAIN "systemctl show confluent-server -p ActiveEnterTimestampMonotonic --value")
check "21 重啟前警告「無法確認叢集狀態」" "grep -q '無法確認 under-replicated' '$OUT/3b.txt'"
check "21 回報重啟完成" "grep -q '已重啟 kb04' '$OUT/3b.txt'"
check "kb04 的服務真的重啟過（啟動時間變了）" "[ '$started_before' != '$started_after' ]"
for attempt in $(seq 1 30); do [ "$(curl -sk -o /dev/null -w '%{http_code}' "https://kb04.$DOMAIN:8090/v1/metadata/id")" = 200 ] && break; sleep 5; done
check "kb04 重啟後回來（MDS 200）" "[ $attempt -lt 30 ]"

echo "== 4. 紀錄"
recent_log=$(sudo tail -30 /var/log/opmenu/opmenu.log)
check "有 EMERGENCY_HOST 與原因" "grep -q 'EMERGENCY_HOST .*INC-0001' <<<\"\$recent_log\""
check "操作者標成未經 AD 驗證" "grep -q 'bob(緊急,未經AD驗證) .*21 重啟單一 broker' <<<\"\$recent_log\""
check "不在群組那次記為 DENIED" "grep -q 'emergency host mode | sid=.* | DENIED' <<<\"\$recent_log\""

echo "== 收尾"
sudo gpasswd -d "$MENU_USER" "$EMERGENCY_GROUP" >/dev/null 2>&1
sudo rm -f "$TEST_CONF"
check "$MENU_USER 已移出 $EMERGENCY_GROUP" "! grep -qw $EMERGENCY_GROUP <<<\"\$(id -nG $MENU_USER)\""
echo "緊急主機模式：$PASS_COUNT 項通過、$FAIL_COUNT 項失敗（畫面輸出在 $OUT/）"
