#!/usr/bin/env bash
# install/lab/mds-token-key-rotate.sh —— lab 專用：MDS token 金鑰實際輪替（7 台 controller／broker + REST + C3），同時量三種流量的影響
# where: ops02 （root；bank-sim.sh push 之後 install/ 在 ~/install）
#
# 做什麼：先把新金鑰派送到所有主機（新檔名，不影響運作）→ 依序切換＋重啟：controller → broker → REST → C3 → 驗證。結論記在 redesign/README.md「MDS token 金鑰輪替」。
#   流量 1：REST 經負載平衡（app 憑證；REST Proxy 內部用 token 連 broker）每 2 秒一次
#   流量 2：應用程式 SCRAM 寫入（不靠 token）每秒 5 筆，持續整段
#   流量 3：管理 client（svc-ops 憑證 → MDS token → TOKEN listener）每 10 秒一次
# 需要什麼：~/mds-key-test/new.key、new.pub（新金鑰對）。只在私鑰外洩時才換，不排輪替。
# 產出什麼：各主機換上新金鑰；操作機 ~/pki 的正本更新（舊的留一份 .old，確認後銷毀）；三種流量的結果印在畫面上。
# 能不能重跑：要先準備另一對新金鑰（.new 檔切換時就用掉了）。
set -uo pipefail
source ~/install/conf/site.env
source ~/install/lib/log.sh
source ~/install/lib/ssh.sh
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
WORK=$HOME/mds-key-test
NEW_KEY=$WORK/new.key
NEW_PUB=$WORK/new.pub
PROBE_LOG=$WORK/probe.log
: > "$PROBE_LOG"

section "準備：新金鑰對（實驗一用過的那把），派送到所有主機的暫存位置"

for host in $KAFKA_HOSTS; do
  if ! copy_to_tmp "$host" "$NEW_KEY" "$NEW_PUB"; then
    fail "$host scp"
  fi

  ssh_script "$host" <<'EOF'
sudo install -o root -g confluent -m 0640 /tmp/new.key /etc/confluent/ssl/mds-token-keypair.pem.new
sudo install -o root -g confluent -m 0640 /tmp/new.pub /etc/confluent/ssl/mds-token-public.pem.new
rm -f /tmp/new.key /tmp/new.pub
EOF
done

for host in $RESTS $C3_HOST; do
  if ! copy_to_tmp "$host" "$NEW_PUB"; then
    fail "$host scp"
  fi

  ssh_script "$host" <<'EOF'
if sudo install -o root -g confluent -m 0640 /tmp/new.pub /etc/confluent/ssl/mds-token-public.pem.new; then
  rm -f /tmp/new.pub
fi
EOF
done

ok "新金鑰已就位（.new），服務還在用舊的"

section "開始量流量"

# 流量 2：SCRAM producer，每秒 5 筆，跑 15 分鐘（最後看送失敗幾筆）
APP_CONF=$CONF_DIR/$FIRST_SCRAM_APP.properties
timeout 900 kafka-producer-perf-test --topic orders.events --num-records 4500 --throughput 5 --record-size 100 \
  --producer.config "$APP_CONF" --producer-props bootstrap.servers="$BROKER_CLIENT" acks=all retries=2147483647 delivery.timeout.ms=120000 \
  > "$WORK/scram-producer.log" 2>&1 &
producer_pid=$!

# 流量 1、3：輪詢
(
  round=0

  while true; do
    # 流量 1：每一輪
    code=$(rest_app_curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters")
    echo "$(date +%s) rest $code" >> "$PROBE_LOG"

    # 流量 3：每 5 輪
    if [ $((round % 5)) = 0 ]; then
      if timeout 30 kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --list > /dev/null 2>&1; then
        echo "$(date +%s) admin ok" >> "$PROBE_LOG"
      else
        echo "$(date +%s) admin FAIL" >> "$PROBE_LOG"
      fi
    fi

    round=$((round + 1))
    sleep 2
  done
) &
probe_pid=$!

sleep 30   # 先量 30 秒基準

section "切換：每台把 .new 換上、重啟，等健康再做下一台"
switch_at=$(date +%s)
echo "$switch_at switch-start" >> "$PROBE_LOG"

SWITCH_KAFKA=$(cat <<'EOF'
sudo mv /etc/confluent/ssl/mds-token-keypair.pem.new /etc/confluent/ssl/mds-token-keypair.pem
sudo mv /etc/confluent/ssl/mds-token-public.pem.new /etc/confluent/ssl/mds-token-public.pem
EOF
)

SWITCH_PUBLIC_ONLY=$(cat <<'EOF'
sudo mv /etc/confluent/ssl/mds-token-public.pem.new /etc/confluent/ssl/mds-token-public.pem
EOF
)

# 檔案先全部換好（服務讀檔只在啟動時）
for host in $KAFKA_HOSTS; do
  ssh_script "$host" <<<"$SWITCH_KAFKA"
done

for host in $RESTS $C3_HOST; do
  ssh_script "$host" <<<"$SWITCH_PUBLIC_ONLY"
done

rolling_restart controllers brokers rests c3

switch_done=$(date +%s)
echo "$switch_done switch-done" >> "$PROBE_LOG"
ok "切換用了 $((switch_done - switch_at)) 秒"

sleep 60   # 切完再量 60 秒
kill "$probe_pid" 2> /dev/null
kill "$producer_pid" 2> /dev/null
wait 2> /dev/null

section "結果"

# probe.log 的一行：<unix 秒> rest <HTTP 碼>、<unix 秒> admin ok|FAIL
#   rest_failures：REST 失敗的那些行
rest_failures() {
  awk '$2 == "rest" && $3 != "200"' "$PROBE_LOG"
}

#   admin_failures：管理 client 失敗的那些行
admin_failures() {
  awk '$2 == "admin" && $3 == "FAIL"' "$PROBE_LOG"
}

# 1. REST 經負載平衡
rest_total=$(awk '$2 == "rest" {c++} END {print c + 0}' "$PROBE_LOG")
rest_bad=$(rest_failures | awk 'END {print NR}')
rest_detail=""

if [ "$rest_bad" -gt 0 ]; then
  first_bad=$(rest_failures | head -1 | cut -d' ' -f1)
  last_bad=$(rest_failures | tail -1 | cut -d' ' -f1)
  rest_codes=$(rest_failures | awk '{print $3}' | sort | uniq -c | paste -sd' ')
  rest_detail="（切換開始後第 $((first_bad - switch_at)) 秒到第 $((last_bad - switch_at)) 秒；失敗碼 $rest_codes）"
fi

log "REST 經負載平衡：$rest_total 次，失敗 $rest_bad 次$rest_detail"

# 2. 管理 client
admin_total=$(awk '$2 == "admin" {c++} END {print c + 0}' "$PROBE_LOG")
admin_bad=$(admin_failures | awk 'END {print NR}')
admin_detail=""

if [ "$admin_bad" -gt 0 ]; then
  first_bad=$(admin_failures | head -1 | cut -d' ' -f1)
  last_bad=$(admin_failures | tail -1 | cut -d' ' -f1)
  admin_detail="（第 $((first_bad - switch_at)) 秒到第 $((last_bad - switch_at)) 秒）"
fi

log "管理 client（token）：$admin_total 次，失敗 $admin_bad 次$admin_detail"

# 3. SCRAM producer
producer_summary=$(grep -o '[0-9]* records sent.*' "$WORK/scram-producer.log" | tail -1 | cut -c1-120)
producer_errors=$(awk 'tolower($0) ~ /error|exception/ {c++} END {print c + 0}' "$WORK/scram-producer.log")
log "SCRAM producer：$producer_summary；錯誤 $producer_errors 行"

# 4. 切換後的登入與畫面
alice_login=$(curl -s --cacert "$BANK_ROOT_CA" -u "alice:$(cat "$SECRETS_DIR/ad-test-users.pass")" -o /dev/null -w '%{http_code}' "$MDS_URL/security/1.0/authenticate")
c3_ui=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$C3_FQDN:9021/")
log "切換後：alice 登入 MDS $alice_login、C3 UI $c3_ui"

section "新金鑰成為正式的：更新操作機上的正本（舊的留一份 .old，確認後銷毀）"
cp -p "$KEYS_DIR/mds-token.key" "$KEYS_DIR/mds-token.key.old"
cp -p "$CERTS_DIR/mds-token-public.pem" "$CERTS_DIR/mds-token-public.pem.old"
install -m 0600 "$NEW_KEY" "$KEYS_DIR/mds-token.key"
install -m 0644 "$NEW_PUB" "$CERTS_DIR/mds-token-public.pem"
ok "ops02 的 ~/pki 已更新"
