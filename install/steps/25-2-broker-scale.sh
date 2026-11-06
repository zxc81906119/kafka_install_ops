#!/usr/bin/env bash
# 25.2 節：broker 縮減與擴充（Self-Balancing 搬資料）（手把手25.2 節）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡）
#
# 做什麼：
#   bash steps/25-2-broker-scale.sh status        Self-Balancing 狀態、under-replicated、每台 broker 上的 replica 數
#   bash steps/25-2-broker-scale.sh remove kb04   kafka-remove-brokers 把 kb04 的 replica 全部搬走、它自己關機 → 停用服務
#   bash steps/25-2-broker-scale.sh add kb04      kb04 清空資料目錄、以觀察者格式化、啟動；Self-Balancing 自動把資料搬過去
#                                               全新主機先照第 3、5、7、8、10 站準備好（憑證 SAN 要有它的名稱）
#
# 永久縮減後，記得把那台從 site.env 的 BROKERS 拿掉，重跑第 12、13、16、17 站（bootstrap 名單）。
#
# 需要什麼：縮減後至少還有 3 台、沒有 under-replicated、Self-Balancing 是 ENABLED；~/conf/kraft.env；安裝期的 sudo（cpuser-ops 不允許清資料、格式化）。
# 產出什麼：remove：那台的服務停用、上面沒有 replica；add：那台重新加入、Self-Balancing 分批搬資料過去（要等一段時間才平均）。
# 能不能重跑：add 可以（每次都會再清空那一台）；remove 那台已經拿掉時 kafka-remove-brokers 會報錯，看 --describe。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-status}
TARGET_HOST=${2:-}
MIN_BROKERS=3   # topic 的 replication factor

# admin_tool <工具> <參數…>：用操作機的管理 client（svc-ops）；bootstrap 不含要動的那台
admin_tool() {
  local tool=$1
  shift
  "$tool" --bootstrap-server "$ADMIN_BOOTSTRAP" --command-config "$ADMIN_CLIENT_CONF" "$@" 2>/dev/null
}

# replicas_on <node id>：所有 topic 的 replica 名單裡出現這個 id 的次數
#   輸入：Topic: orders.events  Partition: 0  Leader: 101  Replicas: 101,104,102  Isr: 101,104,102
#   replicas_on 104 → 這種行有幾行含 104，例：80
replicas_on() {
  local replica_lists

  # 1. 每行的 Replicas: 欄位，例：101,104,102（前面要是空白，不算 AddingReplicas: 這種）
  replica_lists=$(admin_tool kafka-topics --describe \
    | grep -oE '(^|[[:space:]])Replicas: [0-9,]*' \
    | awk '{print $2}')

  # 2. 拆成一行一個 id，數等於這個 id 的有幾個
  tr ',' '\n' <<<"$replica_lists" | awk -v id="$1" '$0 == id {c++} END {print c + 0}'
}

# under_replicated_count：under-replicated 的 partition 數，例：0
under_replicated_count() {
  admin_tool kafka-topics --describe --under-replicated-partitions | awk '/Partition:/ {c++} END {print c + 0}'
}

# balancer_enabled：Self-Balancing 是 ENABLED 回 0
balancer_enabled() {
  grep -q 'Balancer status: ENABLED' <<<"$(admin_tool kafka-rebalance-cluster --status)"
}

# removal_block <node id>：kafka-remove-brokers --describe 裡這個 broker 那一段（從「Broker 104 removal status」到下一個 broker 之前）
#   輸入：Broker 104 removal status - SUCCESS／…／Broker 105 removal status - …
#   removal_block 104 → Broker 104 removal status - SUCCESS／…
removal_block() {
  # lint-ok: 要找出「某一台那一段」到下一段之前，grep／cut 做不到；上面有輸入輸出例子
  admin_tool kafka-remove-brokers --describe | awk -v id="$1" '/^Broker [0-9]+ removal status/ {on = ($2 == id)} on'
}

# brokers_except <主機>：其他 broker，一行一個
brokers_except() {
  local excluded=$1
  local host

  for host in $BROKERS; do
    if [ "$host" != "$excluded" ]; then
      echo "$host"
    fi
  done
}

# 在 broker 上以 cp-kafka 跑 Kafka 工具：設定檔有 ${securepass:…}，工具也要 master key（沒做 Secret Protection 時不需要）
RUN_WITH_MASTER_KEY=$(cat <<'EOF'
run() {
  if sudo test -e /etc/confluent/service.env; then
    sudo bash -c '
      set -a
      . /etc/confluent/service.env
      set +a
      exec runuser -u cp-kafka -- env CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" "$@"
    ' run "$@"
  else
    sudo runuser -u cp-kafka -- "$@"
  fi
}
EOF
)

# 加回來的 broker 必須是空的。清空用 find -delete：rm -rf dir/* 漏點開頭的檔，而且萬用字元由 cpuser 展開時讀不到 0750 的目錄
FORMAT_EMPTY_BROKER=$(cat <<'EOF'
# 1. 停服務、清空資料目錄（含點開頭的檔）
sudo systemctl stop confluent-server
sudo find /var/lib/kafka/data -mindepth 1 -delete

# 2. 以觀察者格式化
run env \
  JAVA_HOME=/opt/java/current \
  KAFKA_HEAP_OPTS=-Xmx256m \
  KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
  kafka-storage format --cluster-id "$CLUSTER_ID" \
  --config /etc/confluent/kafka/server.properties \
  --no-initial-controllers 2>&1 | tail -1

# 3. 啟用並啟動
if sudo systemctl enable --now confluent-server >/dev/null 2>&1; then
  echo started
fi
EOF
)

show_status() {
  local host node_id

  section "25.2.1 Self-Balancing、under-replicated、每台的 replica 數"

  if balancer_enabled; then
    ok "Self-Balancing：ENABLED"
  else
    fail "Self-Balancing 不是 ENABLED（kafka-rebalance-cluster --status）"
  fi

  log "under-replicated：$(under_replicated_count)"

  for host in $BROKERS; do
    node_id=$(node_id_of "$host")
    log "$host（$node_id）：$(replicas_on "$node_id") 個 replica"
  done
}

remove_broker() {
  local host=$1
  local node_id remaining block attempt service_state cluster_brokers state_command id_lines

  # 1. 前置檢查
  node_id=$(node_id_of "$host")
  remaining=$(brokers_except "$host" | wc -l)

  if [ "$remaining" -lt "$MIN_BROKERS" ]; then
    die "拿掉 $host 之後只剩 $remaining 台，replication factor 3 至少要 3 台"
  fi

  if [ "$(under_replicated_count)" != 0 ]; then
    die "有 under-replicated partition，叢集不健康時不搬資料"
  fi

  if ! balancer_enabled; then
    die "Self-Balancing 不是 ENABLED，kafka-remove-brokers 要靠它"
  fi

  # 2. 送出移除
  section "25.2.2 拿掉 $host（$node_id 上有 $(replicas_on "$node_id") 個 replica）"

  admin_tool kafka-remove-brokers --delete --broker-id "$node_id" | grep -v WARN | while read -r line; do
    log "$line"
  done

  # 3. 等到 SUCCESS（或 FAIL）：每 30 秒看一次，最多 120 次
  for attempt in $(seq 1 120); do
    block=$(removal_block "$node_id")

    if grep -q 'removal status - SUCCESS' <<<"$block"; then
      break
    fi

    if grep -q FAIL <<<"$block"; then
      break
    fi

    sleep 30
  done

  log "$block"

  if ! grep -q 'removal status - SUCCESS' <<<"$block"; then
    die "$host 移除沒有完成（kafka-remove-brokers --describe）"
  fi

  # 4. broker 自己關掉了；停用服務，免得主機重開又加回來
  ssh_run "$host" 'sudo systemctl disable --now confluent-server >/dev/null 2>&1'
  state_command='echo $(systemctl is-active confluent-server) / $(systemctl is-enabled confluent-server)'
  service_state=$(ssh_run "$host" "$state_command")
  ok "$host confluent-server：$service_state"

  # 5. 確認：這台上沒有 replica、沒有 under-replicated、叢集裡已經沒有它
  if [ "$(replicas_on "$node_id")" = 0 ]; then
    ok "$node_id 上沒有 replica"
  else
    fail "$node_id 上還有 replica"
  fi

  if [ "$(under_replicated_count)" = 0 ]; then
    ok "沒有 under-replicated"
  else
    fail "有 under-replicated"
  fi

  id_lines=$(admin_tool kafka-broker-api-versions | grep -o '(id: [0-9]*' | grep -o '[0-9]*')
  cluster_brokers=$(sort <<<"$id_lines" | paste -sd' ')
  log "叢集裡的 broker：$cluster_brokers"
  warn "永久縮減：把 $host 從 site.env 的 BROKERS 拿掉，重跑第 12、13、16、17 站（bootstrap 名單），應用程式的設定也要改"
}

add_broker() {
  local host=$1
  local node_id attempt replicas under_replicated format_script rebalance_lines
  local moved=no

  node_id=$(node_id_of "$host")

  if [ ! -s "$CONF_DIR/kraft.env" ]; then
    die "找不到 $CONF_DIR/kraft.env（第 10 站產生的 cluster id）"
  fi

  source "$CONF_DIR/kraft.env"

  # 1. 清空、以觀察者格式化、啟動
  section "25.2.3 $host 清空、以觀察者格式化、啟動"
  format_script="$RUN_WITH_MASTER_KEY
$FORMAT_EMPTY_BROKER"

  ssh_script "$host" CLUSTER_ID="$CLUSTER_ID" <<<"$format_script" | while read -r line; do
    log "$line"
  done

  # 2. 等 MDS 回 200：每 5 秒看一次，最多 60 次
  if retry 60 5 curl -s -o /dev/null -f -m 5 "https://$(fqdn "$host"):8090/v1/metadata/id"; then
    ok "$host MDS 200"
  else
    die "$host 起不來（sudo journalctl -u confluent-server -n 50）"
  fi

  # 3. 等 Self-Balancing 搬資料過來（它不是馬上動，lab 等過十幾分鐘）：每 30 秒看一次，最多 120 次
  section "25.2.3 等 Self-Balancing 把資料搬到 $node_id"

  for attempt in $(seq 1 120); do
    replicas=$(replicas_on "$node_id")
    under_replicated=$(under_replicated_count)

    if [ "$replicas" -gt 0 ]; then
      if [ "$under_replicated" = 0 ]; then
        moved=yes
        break
      fi
    fi

    sleep 30
  done

  if [ "$moved" = yes ]; then
    ok "$node_id 上有 $replicas 個 replica、沒有 under-replicated（約 $((attempt * 30)) 秒）"
  else
    fail "$node_id 上 $replicas 個 replica、under-replicated $under_replicated（kafka-rebalance-cluster --describe）"
  fi

  # 4. Self-Balancing 為什麼在搬（EMPTY_BROKER = 發現空的 broker）
  rebalance_lines=$(admin_tool kafka-rebalance-cluster --describe | grep -iE 'status|broker' | head -5)

  if [ -n "$rebalance_lines" ]; then
    while read -r line; do
      log "$line"
    done <<<"$rebalance_lines"
  fi
}

# 管理工具的 bootstrap：有指定主機時不含那一台
if [ -n "$TARGET_HOST" ]; then
  if [[ " $BROKERS " != *" $TARGET_HOST "* ]]; then
    die "$TARGET_HOST 不是 broker（site.env 的 BROKERS）"
  fi

  OTHER_BROKERS=$(brokers_except "$TARGET_HOST")
  # shellcheck disable=SC2086  # 主機名單要拆開
  ADMIN_BOOTSTRAP=$(host_port_list 9094 $OTHER_BROKERS)
else
  ADMIN_BOOTSTRAP=$BROKER_TOKEN
fi

case $ACTION in
  status)
    show_status
    ;;
  remove)
    if [ -z "$TARGET_HOST" ]; then
      die "用法：bash $0 remove <broker>"
    fi

    remove_broker "$TARGET_HOST"
    finish_step
    ;;
  add)
    if [ -z "$TARGET_HOST" ]; then
      die "用法：bash $0 add <broker>"
    fi

    add_broker "$TARGET_HOST"
    finish_step
    ;;
  *)
    die "用法：bash $0 status|remove <broker>|add <broker>"
    ;;
esac
