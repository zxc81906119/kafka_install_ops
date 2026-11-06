#!/usr/bin/env bash
# install/lab/opmenu-items-test.sh —— lab 專用：OP menu 全部項目的回歸測試
# where: ops02 （root）
#
# 做什麼：每個項目用適合的身分非互動跑一次，看選單紀錄裡那一筆的結果是不是 OK；幾個項目另外驗實際效果：
#   13 有在線成員數；17 各端點都看得到憑證、有 license 那一行；34 A／B 帳號建好、交接檔的密碼能登入；35 只換沒在用的那個；
#   38 改的配額 15 看得到；37 下架後登不進去；43 存檔；44 快照有 rbac.txt
# 需要什麼：已裝好的 OP menu（第 16 站）。
# 產出什麼：每項 ok／FAIL 印在畫面上，畫面輸出存在 ~/opmenu-items-test/。
# 會動到叢集：21 重啟 kb03、22 重啟 rest02、27 滾動重啟全部 broker（最久，約 5 分鐘）；建刪測試用的 topic 與帳號。
# 能不能重跑：可以（測試用的 topic、帳號、交接檔都會清掉）。
set -uo pipefail
source ~/install/conf/site.env
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
OUT=$HOME/opmenu-items-test
install -d -m 0700 "$OUT"
TEST_PASSWORD=$(cat "$SECRETS_DIR/ad-test-users.pass")
HANDOVER_DIR=$HOME/opmenu-handover
PASS_COUNT=0
FAIL_COUNT=0

# check <說明> <條件（一段 shell）>：條件成立算通過
check() {
  if eval "$2"; then
    echo "ok   $1"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# log_result_since <行號> <項目>：選單紀錄裡這行之後、這個項目最後一筆的結果（第 7 欄）
#   輸入的一行：時間 | 主機 | 帳號 | 群組 | 13 查看 consumer lag  | sid=… | OK | …  → OK
log_result_since() {
  local line_number=$1 item=$2 matching_lines
  local field_separator=' \\| '

  # 1. 這行之後、這個項目的所有紀錄
  # lint-ok: 引號裡的 | 是 regex，只有一個是管線
  matching_lines=$(tail -n +$((line_number + 1)) /var/log/opmenu/opmenu.log | grep -E "\| $item [^|]* \| sid=")

  # 2. 最後一筆的第 7 欄
  tail -1 <<<"$matching_lines" | awk -F "$field_separator" '{print $7}'
}

# run_item <AD 帳號> <項目> [參數…]：非互動跑一次，畫面存在 $OUT/<項目>.txt；回傳選單紀錄裡這一筆的結果（OK／FAIL／DENIED…）
run_item() {
  local person=$1 item=$2 lines_before
  shift 2

  lines_before=$(wc -l < /var/log/opmenu/opmenu.log)

  env OPMENU_USER="$person" OPMENU_PASS="$TEST_PASSWORD" \
       OPMENU_YES=1 OPMENU_REASON=regression JAVA_HOME=/opt/java/current \
       /opt/opmenu/opmenu.sh --run "$item" "$@" > "$OUT/$item.txt" 2>&1 < /dev/null

  sed -i 's/\x1b\[[0-9;]*m//g' "$OUT/$item.txt"
  log_result_since "$lines_before" "$item"
}

# item_ok <AD 帳號> <項目> [參數…]：跑一次，結果要是 OK
item_ok() {
  local result

  result=$(run_item "$@")
  check "$2 → $result" "[ '$result' = OK ]"
}

# SCRAM 帳號能不能登入（列 topic 成功就算）
scram_login_works() {
  local account=$1 password=$2 conf=$OUT/scram-$1.properties store_password

  store_password=$(cat "$PKI_DIR/store.pass")
  install -m 0600 /dev/null "$conf"
  cat > "$conf" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$account" password="$password";
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$store_password
EOF

  timeout 60 kafka-topics --bootstrap-server "$FIRST_BROKER:9095" --command-config "$conf" --list > /dev/null 2>&1
}

# 交接目錄是 root 自己的 0700（選單以 root 跑）
latest_handover() { ls -t "$HANDOVER_DIR"/"$1"-*.pass 2> /dev/null | head -1; }

remove_test_handovers() { rm -f "$HANDOVER_DIR"/app-regtest-*.pass; }

# 34：兩個密碼都拿到，交接檔是 0600
handover_files_ok() {
  if [ -z "$password_a" ]; then
    return 1
  fi

  if [ -z "$password_b" ]; then
    return 1
  fi

  local handover_file
  handover_file=$(latest_handover app-regtest-a)
  [ "$(stat -c %a "$handover_file")" = 600 ]
}

# 34：-a、-b 都能用交接檔的密碼登入
both_handover_logins_work() {
  if ! scram_login_works app-regtest-a "$password_a"; then
    return 1
  fi

  scram_login_works app-regtest-b "$password_b"
}

# 35：-b 拿到不同的新密碼
password_b_changed() {
  if [ -z "$new_password_b" ]; then
    return 1
  fi

  [ "$new_password_b" != "$password_b" ]
}

# 35：-b 新密碼能登入、舊密碼不行
only_new_password_b_works() {
  if ! scram_login_works app-regtest-b "$new_password_b"; then
    return 1
  fi

  ! scram_login_works app-regtest-b "$password_b"
}

# 38：改的配額在 15 的畫面上看得到
quota_visible_in_item_15() {
  if [ "$quota_seen" != OK ]; then
    return 1
  fi

  grep -q 'app-regtest-a .*producer_byte_rate=1048576 request_percentage=10' "$OUT/15.txt"
}

# 37：下架後 -a、-b 都登不進去
both_logins_refused() {
  if scram_login_works app-regtest-a "$password_a"; then
    return 1
  fi

  ! scram_login_works app-regtest-b "$new_password_b"
}

# 43：sensitive 讀的是 _sensitive，而且有 payments 的事件
sensitive_audit_visible() {
  if ! grep -q '_sensitive)' "$OUT/43.txt"; then
    return 1
  fi

  grep -q payments "$OUT/43.txt"
}

# under_replicated_count：叢集現在 under-replicated 的 partition 數
under_replicated_count() {
  kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" \
    --describe --under-replicated-partitions 2> /dev/null \
    | awk '/Partition:/ {c++} END {print c + 0}'
}

echo "== 第 1 層：值班查看"
item_ok alice 10
item_ok alice 11
item_ok carol 12
item_ok alice 13 ""
check "13 每個 group 都有合計 lag 與在線成員數" "grep -q '在線成員 [0-9]* 個' '$OUT/13.txt'"
item_ok alice 14 orders.events
item_ok alice 15 ""
item_ok bob 16
item_ok bob 17
valid_endpoints=$(awk '/30 天以上/ {c++} END {print c + 0}' "$OUT/17.txt")
check "17 各端點都看得到有效憑證（$valid_endpoints 個）" "[ $valid_endpoints -ge 16 ]"
check "17 有 license 那一行（bob 讀不到 _confluent-command，顯示每日檢查的紀錄）" "grep -q '^license：' '$OUT/17.txt'"
item_ok bob 18
item_ok alice 19

echo "== 第 2 層：服務操作"
item_ok bob 21 "kb03.$DOMAIN:confluent-server"
item_ok bob 22 "rest02.$DOMAIN:confluent-kafka-rest"
item_ok bob 23 "kb01.$DOMAIN:confluent-server" 5

# 27 開始前會檢查叢集健康（21 剛重啟 kb03，複本要一點時間追上）：等 under-replicated 回到 0 再跑（每 5 秒看一次，最多 36 次）
for attempt in $(seq 1 36); do
  under_replicated=$(under_replicated_count)

  if [ "$under_replicated" = 0 ]; then
    break
  fi

  sleep 5
done

item_ok bob 27

echo "== 第 3 層：變更作業"
item_ok alice 31 orders.regtest 1
item_ok alice 32 orders.regtest 3600000
item_ok alice 33 orders.regtest
remove_test_handovers
item_ok alice 34 app-regtest regtest.
handover_a=$(latest_handover app-regtest-a)
handover_b=$(latest_handover app-regtest-b)
password_a=$(cat "$handover_a" 2> /dev/null)
password_b=$(cat "$handover_b" 2> /dev/null)
check "34 兩個帳號的交接檔都在（0600）" handover_files_ok
check "34 密碼沒有印在畫面上" "! grep -qF '$password_a' '$OUT/34.txt'"
check "34 交接檔的密碼能登入（-a、-b）" both_handover_logins_work
sleep 1
item_ok alice 35 app-regtest app-regtest-a
handover_b=$(latest_handover app-regtest-b)
new_password_b=$(cat "$handover_b")
check "35 只換沒在用的 -b（新密碼和原本不同）" password_b_changed
check "35 在用的 -a 不受影響（舊密碼照樣能登入）" "scram_login_works app-regtest-a '$password_a'"
check "35 -b 用新密碼能登入、舊密碼不行" only_new_password_b_works

# 36：先讓一個 consumer group 有讀取位置、停掉，再重設
timeout 60 kafka-console-consumer --bootstrap-server "$FIRST_BROKER:9095" \
  --consumer.config "$CONF_DIR/$FIRST_SCRAM_APP.properties" --topic orders.events \
  --group orders-regtest --from-beginning --max-messages 1 --timeout-ms 20000 > /dev/null 2>&1
item_ok alice 36 orders-regtest earliest
item_ok alice 38 app-regtest-a producer_byte_rate=1048576,request_percentage=10
quota_seen=$(run_item alice 15 app-regtest-a)
check "38 改的配額 15 看得到" quota_visible_in_item_15
item_ok alice 38 app-regtest-a producer_byte_rate=-,request_percentage=-
item_ok alice 37 app-regtest regtest.
check "37 下架後 -a、-b 都登不進去" both_logins_refused

echo "== 第 4 層：授權與稽核、緊急"
item_ok alice 41 Group:kafka-devs
item_ok alice 42 add kafka-devs DeveloperRead Topic regtest.
item_ok alice 42 remove kafka-devs DeveloperRead Topic regtest.
audit_files_before=$(ls /var/log/opmenu/audit-*.jsonl 2> /dev/null | wc -l)
item_ok alice 43 60
item_ok alice 43 60 alice - save
item_ok alice 43 600 - - - sensitive
check "43 sensitive 讀的是 _sensitive（有 payments 的事件）" sensitive_audit_visible
audit_files_after=$(ls /var/log/opmenu/audit-*.jsonl 2> /dev/null | wc -l)
check "43 save 存了檔" "[ $audit_files_after -gt $audit_files_before ]"
item_ok alice 44
item_ok alice 44 snapshot
latest_snapshot=$(ls -dt /var/log/opmenu/snapshot-* | head -1)
check "44 快照有 rbac.txt（每個 principal 一段）" "grep -q '^== ' '$latest_snapshot/rbac.txt'"
item_ok alice 91 kafka-topics --list

echo "== 收尾"
remove_test_handovers
rm -f "$OUT"/scram-*.properties
check "沒有 ssh-agent（選單不開 agent）" "[ \"\$(pgrep -x ssh-agent | wc -l)\" = 0 ]"
echo "全部項目：$PASS_COUNT 項通過、$FAIL_COUNT 項失敗（畫面輸出在 $OUT/）"

# 有任何一項失敗，結束碼就不是 0（呼叫的人才知道）
if [ "$FAIL_COUNT" != 0 ]; then
  exit 1
fi
