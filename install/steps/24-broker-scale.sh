#!/usr/bin/env bash
# 第 24 站：broker 縮減與擴充（Self-Balancing 搬資料）（手把手第 24 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡）
#
# 用法：
#   bash steps/24-broker-scale.sh status        Self-Balancing 狀態、under-replicated、每台 broker 上的 replica 數
#   bash steps/24-broker-scale.sh remove kb04   kafka-remove-brokers 把 kb04 的 replica 全部搬走、它自己關機 → 停用服務
#   bash steps/24-broker-scale.sh add kb04      kb04 清空資料目錄、以觀察者格式化、啟動；Self-Balancing 自動把資料搬過去
#                                               全新主機先照第 3、5、7、8、10 站準備好（憑證 SAN 要有它的名稱）
#
# 永久縮減後，記得把那台從 site.env 的 BROKERS 拿掉，重跑第 12、13、17 站（bootstrap 名單）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-status}
TARGET_HOST=${2:-}
MIN_BROKERS=3   # topic 的 replication factor

# admin_tool <工具> <參數…>：用操作機的管理 client（svc-ops）；bootstrap 不含要動的那台
admin_tool() { local tool=$1; shift; "$tool" --bootstrap-server "$ADMIN_BOOTSTRAP" --command-config "$ADMIN_CLIENT_CONF" "$@" 2>/dev/null; }
replicas_on() {
  admin_tool kafka-topics --describe | awk -v id="$1" '/Replicas:/ {for (i = 1; i <= NF; i++) if ($i == "Replicas:") {n = split($(i + 1), r, ","); for (j = 1; j <= n; j++) if (r[j] == id) c++}} END {print c + 0}'
}
under_replicated_count() { admin_tool kafka-topics --describe --under-replicated-partitions | grep -c Partition:; }
balancer_enabled() { grep -q 'Balancer status: ENABLED' <<<"$(admin_tool kafka-rebalance-cluster --status)"; }
removal_block() { admin_tool kafka-remove-brokers --describe | awk -v id="$1" '/^Broker [0-9]+ removal status/ {on = ($2 == id)} on'; }

RUN_WITH_MASTER_KEY=$(cat <<'EOF'
run() {
  if sudo test -e /etc/confluent/service.env; then
    sudo bash -c 'set -a; . /etc/confluent/service.env; set +a; exec runuser -u cp-kafka -- env CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" "$@"' run "$@"
  else
    sudo runuser -u cp-kafka -- "$@"
  fi
}
EOF
)
FORMAT_EMPTY_BROKER=$(cat <<'EOF'
sudo systemctl stop confluent-server
sudo find /var/lib/kafka/data -mindepth 1 -delete
run env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml kafka-storage format --cluster-id "$CLUSTER_ID" --config /etc/confluent/kafka/server.properties --no-initial-controllers 2>&1 | tail -1
sudo systemctl enable --now confluent-server >/dev/null 2>&1 && echo started
EOF
)

show_status() {
  local host
  section "24.1 Self-Balancing、under-replicated、每台的 replica 數"
  if balancer_enabled; then ok "Self-Balancing：ENABLED"; else fail "Self-Balancing 不是 ENABLED（kafka-rebalance-cluster --status）"; fi
  log "under-replicated：$(under_replicated_count)"
  for host in $BROKERS; do log "$host（$(node_id_of "$host")）：$(replicas_on "$(node_id_of "$host")") 個 replica"; done
}

remove_broker() {
  local host=$1 node_id remaining block attempt
  node_id=$(node_id_of "$host")
  remaining=$(for h in $BROKERS; do [ "$h" != "$host" ] && echo "$h"; done | wc -l)
  [ "$remaining" -ge "$MIN_BROKERS" ] || die "拿掉 $host 之後只剩 $remaining 台，replication factor 3 至少要 3 台"
  [ "$(under_replicated_count)" = 0 ] || die "有 under-replicated partition，叢集不健康時不搬資料"
  balancer_enabled || die "Self-Balancing 不是 ENABLED，kafka-remove-brokers 要靠它"

  section "24.2 拿掉 $host（$node_id 上有 $(replicas_on "$node_id") 個 replica）"
  admin_tool kafka-remove-brokers --delete --broker-id "$node_id" | grep -v WARN | while read -r line; do log "$line"; done
  for attempt in $(seq 1 120); do
    block=$(removal_block "$node_id")
    grep -q 'removal status - SUCCESS' <<<"$block" && break
    grep -q FAIL <<<"$block" && break
    sleep 30
  done
  log "$block"
  grep -q 'removal status - SUCCESS' <<<"$block" || die "$host 移除沒有完成（kafka-remove-brokers --describe）"
  # broker 自己關掉了；停用服務，免得主機重開又加回來
  ssh_run "$host" 'sudo systemctl disable --now confluent-server >/dev/null 2>&1'
  ok "$host confluent-server：$(ssh_run "$host" 'echo $(systemctl is-active confluent-server) / $(systemctl is-enabled confluent-server)')"
  [ "$(replicas_on "$node_id")" = 0 ] && ok "$node_id 上沒有 replica" || fail "$node_id 上還有 replica"
  [ "$(under_replicated_count)" = 0 ] && ok "沒有 under-replicated" || fail "有 under-replicated"
  warn "永久縮減：把 $host 從 site.env 的 BROKERS 拿掉，重跑第 12、13、17 站（bootstrap 名單），應用程式的設定也要改"
}

add_broker() {
  local host=$1 node_id attempt replicas under_replicated
  node_id=$(node_id_of "$host")
  [ -s "$CONF_DIR/kraft.env" ] || die "找不到 $CONF_DIR/kraft.env（第 10 站產生的 cluster id）"
  source "$CONF_DIR/kraft.env"
  section "24.3 $host 清空、以觀察者格式化、啟動"
  ssh_script "$host" CLUSTER_ID="$CLUSTER_ID" <<<"$RUN_WITH_MASTER_KEY
$FORMAT_EMPTY_BROKER" | while read -r line; do log "$line"; done
  retry 60 5 curl -s -o /dev/null -f -m 5 "https://$(fqdn "$host"):8090/v1/metadata/id" && ok "$host MDS 200" || die "$host 起不來（sudo journalctl -u confluent-server -n 50）"
  section "24.3 等 Self-Balancing 把資料搬到 $node_id"
  for attempt in $(seq 1 120); do
    replicas=$(replicas_on "$node_id"); under_replicated=$(under_replicated_count)
    [ "$replicas" -gt 0 ] && [ "$under_replicated" = 0 ] && break; sleep 30
  done
  if [ "$replicas" -gt 0 ] && [ "$under_replicated" = 0 ]; then ok "$node_id 上有 $replicas 個 replica、沒有 under-replicated（約 $((attempt * 30)) 秒）"
  else fail "$node_id 上 $replicas 個 replica、under-replicated $under_replicated（kafka-rebalance-cluster --describe）"; fi
}

if [ -n "$TARGET_HOST" ]; then
  [[ " $BROKERS " == *" $TARGET_HOST "* ]] || die "$TARGET_HOST 不是 broker（site.env 的 BROKERS）"
  other_brokers=$(for h in $BROKERS; do [ "$h" != "$TARGET_HOST" ] && echo "$h"; done | paste -sd" ")
  # shellcheck disable=SC2086  # 主機名單要拆開
  ADMIN_BOOTSTRAP=$(host_port_list 9094 $other_brokers)
else
  ADMIN_BOOTSTRAP=$BROKER_TOKEN
fi

case $ACTION in
  status) show_status;;
  remove) [ -n "$TARGET_HOST" ] || die "用法：bash $0 remove <broker>"; remove_broker "$TARGET_HOST"; finish_step;;
  add)    [ -n "$TARGET_HOST" ] || die "用法：bash $0 add <broker>"; add_broker "$TARGET_HOST"; finish_step;;
  *) die "用法：bash $0 status|remove <broker>|add <broker>";;
esac
