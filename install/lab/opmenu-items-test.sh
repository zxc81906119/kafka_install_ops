#!/usr/bin/env bash
# lab 專用：OP menu 全部項目的回歸測試。在 ops02 以 cpadmin 跑；需要已裝好的 OP menu（第 17 站）。
# 每個項目用適合的身分非互動跑一次，看選單紀錄裡那一筆的結果是不是 OK；幾個項目另外驗實際效果：
#   17 各端點都看得到憑證；34 A／B 帳號建好、交接檔的密碼能登入；35 只換沒在用的那個；37 下架後登不進去
# 會動到叢集：21 重啟 kb03、22 重啟 rest02、27 滾動重啟全部 broker（最久，約 5 分鐘）；建刪測試用的 topic 與帳號
set -uo pipefail
source ~/install/conf/site.env
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
MENU_USER=$OPMENU_OS_USER
OUT=$HOME/opmenu-items-test; install -d -m 0700 "$OUT"
TEST_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass")
HANDOVER_DIR=/home/$MENU_USER/opmenu-handover
PASS_COUNT=0; FAIL_COUNT=0
check() { if eval "$2"; then echo "ok   $1"; PASS_COUNT=$((PASS_COUNT + 1)); else echo "FAIL $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi; }

# run_item <AD 帳號> <項目> [參數…]：非互動跑一次，畫面存在 $OUT/<項目>.txt；回傳選單紀錄裡這一筆的結果（OK／FAIL／DENIED…）
run_item() {
  local person=$1 item=$2; shift 2
  local before; before=$(sudo wc -l /var/log/opmenu/opmenu.log | cut -d" " -f1)   # 用 root 讀（重導向不是 sudo 做的）
  # shellcheck disable=SC2024  # 畫面輸出刻意由 cpadmin 寫進自己的目錄，不需要 root
  sudo env OPMENU_USER="$person" OPMENU_PASS="$TEST_PASSWORD" OPMENU_YES=1 OPMENU_REASON=regression JAVA_HOME=/opt/java/current HOME=/home/$MENU_USER \
       runuser -p -u "$MENU_USER" -- /opt/opmenu/opmenu.sh --run "$item" "$@" > "$OUT/$item.txt" 2>&1 </dev/null
  sed -i 's/\x1b\[[0-9;]*m//g' "$OUT/$item.txt"
  sudo tail -n +$((before + 1)) /var/log/opmenu/opmenu.log | grep -E "\| $item [^|]* \| sid=" | tail -1 | awk -F' \\| ' '{print $7}'
}
item_ok() { local result; result=$(run_item "$@"); check "$2 → $result" "[ '$result' = OK ]"; }

# SCRAM 帳號能不能登入（列 topic 成功就算）
scram_login_works() {
  local account=$1 password=$2 conf=$OUT/scram-$1.properties
  (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="%s" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=%s/truststore.p12\nssl.truststore.password=%s\n' \
     "$account" "$password" "$CERTS_DIR" "$(cat "$PKI_DIR/store.pass")" > "$conf")
  timeout 60 kafka-topics --bootstrap-server "$FIRST_BROKER:9095" --command-config "$conf" --list >/dev/null 2>&1
}
# 交接目錄是 op01 的 0700：glob 要由 root 展開（cpadmin 的 shell 看不到裡面，會把 * 原樣交給 sudo）
latest_handover() { sudo sh -c "ls -t $HANDOVER_DIR/$1-*.pass 2>/dev/null | head -1"; }
remove_test_handovers() { sudo sh -c "rm -f $HANDOVER_DIR/app-regtest-*.pass"; }

echo "== 第 1 層：值班查看"
item_ok alice 10
item_ok alice 11
item_ok carol 12
item_ok alice 13 ""
item_ok alice 14 orders.events
item_ok alice 15
item_ok bob 16
item_ok bob 17
valid_endpoints=$(grep -c '30 天以上' "$OUT/17.txt")
check "17 各端點都看得到有效憑證（$valid_endpoints 個）" "[ $valid_endpoints -ge 16 ]"
item_ok bob 18
item_ok alice 19

echo "== 第 2 層：服務操作"
item_ok bob 21 "kb03.$DOMAIN:confluent-server"
item_ok bob 22 "rest02.$DOMAIN:confluent-kafka-rest"
item_ok bob 23 "kb01.$DOMAIN:confluent-server" 5
# 27 開始前會檢查叢集健康（21 剛重啟 kb03，複本要一點時間追上）：等 under-replicated 回到 0 再跑
for attempt in $(seq 1 36); do
  under_replicated=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:)
  [ "$under_replicated" = 0 ] && break; sleep 5
done
item_ok bob 27

echo "== 第 3 層：變更作業"
item_ok alice 31 orders.regtest 1
item_ok alice 32 orders.regtest 3600000
item_ok alice 33 orders.regtest
remove_test_handovers
item_ok alice 34 app-regtest regtest.
password_a=$(sudo cat "$(latest_handover app-regtest-a)" 2>/dev/null); password_b=$(sudo cat "$(latest_handover app-regtest-b)" 2>/dev/null)
check "34 兩個帳號的交接檔都在（0600）" "[ -n '$password_a' ] && [ -n '$password_b' ] && [ \"\$(sudo stat -c %a '$(latest_handover app-regtest-a)')\" = 600 ]"
check "34 密碼沒有印在畫面上" "! grep -qF '$password_a' '$OUT/34.txt'"
check "34 交接檔的密碼能登入（-a、-b）" "scram_login_works app-regtest-a '$password_a' && scram_login_works app-regtest-b '$password_b'"
sleep 1
item_ok alice 35 app-regtest app-regtest-a
new_password_b=$(sudo cat "$(latest_handover app-regtest-b)")
check "35 只換沒在用的 -b（新密碼和原本不同）" "[ -n '$new_password_b' ] && [ '$new_password_b' != '$password_b' ]"
check "35 在用的 -a 不受影響（舊密碼照樣能登入）" "scram_login_works app-regtest-a '$password_a'"
check "35 -b 用新密碼能登入、舊密碼不行" "scram_login_works app-regtest-b '$new_password_b' && ! scram_login_works app-regtest-b '$password_b'"
# 36：先讓一個 consumer group 有讀取位置、停掉，再重設
timeout 60 kafka-console-consumer --bootstrap-server "$FIRST_BROKER:9095" --consumer.config "$CONF_DIR/$FIRST_SCRAM_APP.properties" --topic orders.events \
  --group orders-regtest --from-beginning --max-messages 1 --timeout-ms 20000 >/dev/null 2>&1
item_ok alice 36 orders-regtest earliest
item_ok alice 37 app-regtest regtest.
check "37 下架後 -a、-b 都登不進去" "! scram_login_works app-regtest-a '$password_a' && ! scram_login_works app-regtest-b '$new_password_b'"

echo "== 第 4 層：授權與稽核、緊急"
item_ok alice 41 Group:kafka-devs
item_ok alice 42 add kafka-devs DeveloperRead Topic regtest.
item_ok alice 42 remove kafka-devs DeveloperRead Topic regtest.
item_ok alice 43 60
item_ok alice 44
item_ok alice 45 60 alice
item_ok alice 91 kafka-topics --list

echo "== 收尾"
remove_test_handovers; rm -f "$OUT"/scram-*.properties
check "沒有殘留的 ssh-agent" "[ \"\$(pgrep -x ssh-agent | wc -l)\" = 0 ]"
echo "全部項目：$PASS_COUNT 項通過、$FAIL_COUNT 項失敗（畫面輸出在 $OUT/）"
