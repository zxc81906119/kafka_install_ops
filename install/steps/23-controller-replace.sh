#!/usr/bin/env bash
# 第 23 站：換掉一台 controller（動態 quorum：移出舊成員 → 重新格式化成觀察者 → 追上 → 加入）（手把手第 23 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡）
#
# 用法：
#   bash steps/23-controller-replace.sh status        quorum 的成員、directory id、Lag
#   bash steps/23-controller-replace.sh replace kc03  kc03 的資料碟換新（或換了一台同名的新機器、已照第 3、5、7、8、10 站準備好）：
#                                                     移出「3＋舊 directory id」→ 清空並以觀察者格式化 → 啟動 → Lag 0 → add-controller
#
# 一次只換一台。換的過程中 quorum 只剩兩個成員、兩個都要在：這段時間不要重啟其他 controller。
# 換成不同名稱的主機不在這支：要另外重簽 kafka-internal（SAN）、改所有節點的 controller.quorum.bootstrap.servers。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-status}
TARGET_HOST=${2:-}

# quorum <其他 controller 的 bootstrap> <子命令…>
quorum() { local bootstrap=$1; shift; kafka-metadata-quorum --bootstrap-controller "$bootstrap" --command-config "$INTERNAL_CLIENT_CONF" "$@" 2>/dev/null; }

# 在 controller 上以 cp-kafka 跑 Kafka 工具：設定檔有 ${securepass:…}，工具也要 master key
# （有 service.env 就讀它；沒做 Secret Protection 時不需要）
RUN_WITH_MASTER_KEY=$(cat <<'EOF'
run() {
  if sudo test -e /etc/confluent/service.env; then
    sudo bash -c 'set -a; . /etc/confluent/service.env; set +a; exec runuser -u cp-kafka -- env CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" "$@"' run "$@"
  else
    sudo runuser -u cp-kafka -- "$@"
  fi
}
TOOL_ENV=(env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml)
EOF
)

FORMAT_AS_OBSERVER=$(cat <<'EOF'
sudo systemctl stop confluent-server
sudo find /var/lib/kafka/data -mindepth 1 -delete
run "${TOOL_ENV[@]}" kafka-storage format --cluster-id "$CLUSTER_ID" --config /etc/confluent/kafka/server.properties --no-initial-controllers 2>&1 | tail -1
sudo systemctl start confluent-server
echo "directory.id=$(sudo sed -n 's/^directory.id=//p' /var/lib/kafka/data/meta.properties)"
EOF
)

ADD_CONTROLLER=$(cat <<'EOF'
sudo bash -c '( cat /etc/confluent/kafka/server.properties; echo security.protocol=SSL ) > /etc/confluent/kafka/add-controller.properties && chown root:confluent /etc/confluent/kafka/add-controller.properties && chmod 0640 /etc/confluent/kafka/add-controller.properties'
run "${TOOL_ENV[@]}" kafka-metadata-quorum --bootstrap-controller "$BOOTSTRAP" --command-config /etc/confluent/kafka/add-controller.properties add-controller 2>&1 | grep -v WARN | tail -1
sudo rm -f /etc/confluent/kafka/add-controller.properties
EOF
)

show_status() {
  section "23.1 quorum（NodeId DirectoryId LogEndOffset Lag … Status）"
  quorum "$CONTROLLER_QUORUM" describe --replication | awk 'NR == 1 || $1 < 100' | while read -r line; do log "$line"; done
}

replace() {
  local host=$1 node_id others old_dir new_dir attempt line
  [[ " $CONTROLLERS " == *" $host "* ]] || die "$host 不是 controller（site.env 的 CONTROLLERS）"
  node_id=$(node_id_of "$host")
  others=$(for h in $CONTROLLERS; do [ "$h" != "$host" ] && echo "$h"; done | paste -sd" ")
  # shellcheck disable=SC2086  # 主機名單要拆開
  others=$(host_port_list 9093 $others)
  [ -s "$CONF_DIR/kraft.env" ] || die "找不到 $CONF_DIR/kraft.env（第 10 站產生的 cluster id）"
  source "$CONF_DIR/kraft.env"

  section "23.3 移出舊成員 $node_id"
  old_dir=$(quorum "$others" describe --replication | awk -v id="$node_id" '$1 == id && $NF != "Observer" {print $2}')
  if [ -n "$old_dir" ]; then
    grep -q Leader <<<"$(quorum "$others" describe --replication | awk 'NR > 1 && $1 < 100')" || die "其他 controller 沒有 leader，不能動 quorum"
    quorum "$others" remove-controller --controller-id "$node_id" --controller-directory-id "$old_dir" >/dev/null || die "remove-controller 失敗"
    ok "移出 $node_id / $old_dir"
  else
    ok "$node_id 已經不是成員（上一次做到一半？），接著做"
  fi

  section "23.4 $host 清空、以觀察者格式化、啟動"
  new_dir=$(ssh_script "$host" CLUSTER_ID="$CLUSTER_ID" <<<"$RUN_WITH_MASTER_KEY
$FORMAT_AS_OBSERVER" | tee -a "$LOG_FILE" | sed -n 's/^directory.id=//p')
  [ -n "$new_dir" ] || die "$host 格式化失敗"
  [ "$new_dir" != "$old_dir" ] || die "$host 的 directory id 沒變（資料目錄沒有清空？）"
  for attempt in $(seq 1 60); do
    line=$(quorum "$others" describe --replication | awk -v id="$node_id" '$1 == id')
    [ "$(awk '{print $4, $NF}' <<<"$line")" = "0 Observer" ] && break; sleep 5
  done
  [ "$(awk '{print $4, $NF}' <<<"$line")" = "0 Observer" ] || die "$host 沒有追上（$line）"
  ok "$host 以觀察者追上（directory id $new_dir）"

  section "23.5 加回成員"
  ssh_script "$host" BOOTSTRAP="$others" <<<"$RUN_WITH_MASTER_KEY
$ADD_CONTROLLER" | while read -r line; do log "$line"; done
  for attempt in $(seq 1 30); do
    line=$(quorum "$CONTROLLER_QUORUM" describe --replication | awk -v id="$node_id" '$1 == id')
    [[ $(awk '{print $NF}' <<<"$line") =~ ^(Follower|Leader)$ ]] && [ "$(awk '{print $2}' <<<"$line")" = "$new_dir" ] && break; sleep 5
  done
  if [[ $(awk '{print $NF}' <<<"$line") =~ ^(Follower|Leader)$ ]]; then ok "$host 是成員（$(awk '{print $NF}' <<<"$line")，directory id $new_dir）"
  else fail "$host 沒有成為成員（$line）"; fi
  show_status
}

case $ACTION in
  status)  show_status;;
  replace) [ -n "$TARGET_HOST" ] || die "用法：bash $0 replace <controller>"; replace "$TARGET_HOST"; finish_step;;
  *) die "用法：bash $0 status|replace <controller>";;
esac
