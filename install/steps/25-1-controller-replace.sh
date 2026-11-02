#!/usr/bin/env bash
# 25.1 節：換掉一台 controller（動態 quorum：移出舊成員 → 重新格式化成觀察者 → 追上 → 加入）（手把手25.1 節）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡）
#
# 做什麼：
#   bash steps/25-1-controller-replace.sh status        quorum 的成員、directory id、Lag
#   bash steps/25-1-controller-replace.sh replace kc03  kc03 的資料碟換新（或換了一台同名的新機器、已照第 3、5、7、8、10 站準備好）：
#                                                     移出「3＋舊 directory id」→ 清空並以觀察者格式化 → 啟動 → Lag 0 → add-controller
#
# 一次只換一台。換的過程中 quorum 只剩兩個成員、兩個都要在：這段時間不要重啟其他 controller。
# 換成不同名稱的主機不在這支：要另外重簽 kafka-internal（SAN）、改所有節點的 controller.quorum.bootstrap.servers。
#
# 需要什麼：其他兩台 controller 健康；~/conf/kraft.env（第 10 站的 cluster id）；安裝期的 sudo（cpuser-ops 不允許清資料、格式化）。
# 產出什麼：那台 controller 的資料目錄重建、新的 directory id；quorum 回到三個成員。
# 能不能重跑：可以；舊成員已經移出時會略過移出，接著做。但每次重跑都會再清空那一台。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-status}
TARGET_HOST=${2:-}

# quorum <controller 的 bootstrap> <子命令…>：kafka-metadata-quorum，用 kafka-internal 憑證
quorum() {
  local bootstrap=$1
  shift
  kafka-metadata-quorum --bootstrap-controller "$bootstrap" --command-config "$INTERNAL_CLIENT_CONF" "$@" 2>/dev/null
}

# controllers_except <主機>：其他 controller，用空白隔開，例：kc03 → kc01 kc02
controllers_except() {
  local excluded=$1
  local host

  for host in $CONTROLLERS; do
    if [ "$host" != "$excluded" ]; then
      echo "$host"
    fi
  done | paste -sd" "
}

# quorum_line <bootstrap> <node id>：describe --replication 裡這個 node 的那一行
#   例：3  eELCq6OM-4WuTdfGQSmOgQ  30989  0  …  Observer
quorum_line() {
  quorum "$1" describe --replication | awk -v id="$2" '$1 == id'
}

# lag_and_status <quorum_line 的輸出>：Lag 與最後一欄的狀態，例：0 Observer
lag_and_status() {
  awk '{print $4, $NF}' <<<"$1"
}

# status_of <quorum_line 的輸出>：最後一欄的狀態，例：Follower
status_of() {
  awk '{print $NF}' <<<"$1"
}

# directory_id_of <quorum_line 的輸出>：第二欄的 directory id
directory_id_of() {
  awk '{print $2}' <<<"$1"
}

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

# 清空資料目錄用 find -delete：rm -rf dir/* 漏點開頭的檔，而且萬用字元由 cpuser 展開時讀不到 0750 的目錄
FORMAT_AS_OBSERVER=$(cat <<'EOF'
# 1. 停服務、清空資料目錄（含點開頭的檔）
sudo systemctl stop confluent-server
sudo find /var/lib/kafka/data -mindepth 1 -delete

# 2. 以觀察者格式化（--no-initial-controllers：不是自己宣告成員）
run "${TOOL_ENV[@]}" kafka-storage format --cluster-id "$CLUSTER_ID" --config /etc/confluent/kafka/server.properties --no-initial-controllers 2>&1 | tail -1

# 3. 啟動，印新的 directory id
sudo systemctl start confluent-server
echo "directory.id=$(sudo sed -n 's/^directory.id=//p' /var/lib/kafka/data/meta.properties)"
EOF
)

# add-controller 要在新的那台跑：工具從 --command-config 指到的設定找資料目錄，讀出自己的 node id 與 directory id
ADD_CONTROLLER=$(cat <<'EOF'
add_controller_conf=/etc/confluent/kafka/add-controller.properties

# 1. 這台的 server.properties 加一行 security.protocol=SSL（0640 root:confluent，用完就刪）
sudo install -m 0640 -o root -g confluent /dev/null "$add_controller_conf"
sudo cat /etc/confluent/kafka/server.properties | sudo tee "$add_controller_conf" > /dev/null
echo security.protocol=SSL | sudo tee -a "$add_controller_conf" > /dev/null

# 2. 加入 quorum
run "${TOOL_ENV[@]}" kafka-metadata-quorum --bootstrap-controller "$BOOTSTRAP" --command-config "$add_controller_conf" add-controller 2>&1 | grep -v WARN | tail -1

# 3. 用完就刪
sudo rm -f "$add_controller_conf"
EOF
)

show_status() {
  section "25.1.1 quorum（NodeId DirectoryId LogEndOffset Lag … Status）"
  quorum "$CONTROLLER_QUORUM" describe --replication | awk 'NR == 1 || $1 < 100' | while read -r line; do
    log "$line"
  done
}

# metric_count <主機>：那台 7071 上 kafka_ 開頭的指標數，例：973
metric_count() {
  curl -s --cacert "$BANK_ROOT_CA" "https://$(fqdn "$1"):7071/metrics" | awk '/^kafka_/ {c++} END {print c + 0}'
}

# final_checks <controller>：那台的監控端點（官方規則有 startDelaySeconds: 120，剛啟動兩分鐘內是空的）與每台 MDS
final_checks() {
  local host=$1
  local round broker mds_status=""

  section "25.1.5 最後確認：$host 的監控端點、每台 MDS"

  if [ "$JMX_EXPORTER" = 1 ]; then
    for round in $(seq 1 24); do
      if [ "$(metric_count "$host")" -gt 20 ]; then
        break
      fi

      sleep 10
    done

    if [ "$(metric_count "$host")" -gt 20 ]; then
      ok "$host 7071：$(metric_count "$host") 個指標"
    else
      fail "$host 7071 沒有指標（curl https://$(fqdn "$host"):7071/metrics）"
    fi
  fi

  for broker in $BROKERS; do
    mds_status="$mds_status$broker MDS=$(curl -s -o /dev/null -m 5 -w '%{http_code}' --cacert "$BANK_ROOT_CA" "https://$(fqdn "$broker"):8090/v1/metadata/id") "
  done

  log "$mds_status"
}

replace() {
  local host=$1
  local node_id others old_dir new_dir attempt line voters
  local format_script add_script

  if [[ " $CONTROLLERS " != *" $host "* ]]; then
    die "$host 不是 controller（site.env 的 CONTROLLERS）"
  fi

  node_id=$(node_id_of "$host")
  # shellcheck disable=SC2046  # 主機名單要拆開
  others=$(host_port_list 9093 $(controllers_except "$host"))

  if [ ! -s "$CONF_DIR/kraft.env" ]; then
    die "找不到 $CONF_DIR/kraft.env（第 10 站產生的 cluster id）"
  fi

  source "$CONF_DIR/kraft.env"

  # 1. 移出舊成員（node id＋舊的 directory id）；已經不是成員就略過
  section "25.1.3 移出舊成員 $node_id"
  old_dir=$(quorum "$others" describe --replication | awk -v id="$node_id" '$1 == id && $NF != "Observer" {print $2}')

  if [ -n "$old_dir" ]; then
    if ! grep -q Leader <<<"$(quorum "$others" describe --replication | awk 'NR > 1 && $1 < 100')"; then
      die "其他 controller 沒有 leader，不能動 quorum"
    fi

    if ! quorum "$others" remove-controller --controller-id "$node_id" --controller-directory-id "$old_dir" >/dev/null; then
      die "remove-controller 失敗"
    fi

    ok "移出 $node_id / $old_dir"
    sleep 5
    voters=$(quorum "$others" describe --status | grep CurrentVoters | grep -o '"id": [0-9]*' | cut -d' ' -f2 | paste -sd' ')
    log "目前的成員：$voters"
  else
    ok "$node_id 已經不是成員（上一次做到一半？），接著做"
  fi

  # 2. 清空、以觀察者格式化、啟動
  section "25.1.4 $host 清空、以觀察者格式化、啟動"
  format_script="$RUN_WITH_MASTER_KEY
$FORMAT_AS_OBSERVER"
  new_dir=$(ssh_script "$host" CLUSTER_ID="$CLUSTER_ID" <<<"$format_script" | tee -a "$LOG_FILE" | sed -n 's/^directory.id=//p')

  if [ -z "$new_dir" ]; then
    die "$host 格式化失敗"
  fi

  if [ "$new_dir" = "$old_dir" ]; then
    die "$host 的 directory id 沒變（資料目錄沒有清空？）"
  fi

  # 3. 等它追上（Lag 0、Observer）：每 5 秒看一次，最多 60 次
  for attempt in $(seq 1 60); do
    line=$(quorum_line "$others" "$node_id")

    if [ "$(lag_and_status "$line")" = "0 Observer" ]; then
      break
    fi

    sleep 5
  done

  if [ "$(lag_and_status "$line")" != "0 Observer" ]; then
    die "$host 沒有追上（$line）"
  fi

  ok "$host 以觀察者追上（directory id $new_dir）"

  # 4. 加回成員
  section "25.1.5 加回成員"
  add_script="$RUN_WITH_MASTER_KEY
$ADD_CONTROLLER"

  ssh_script "$host" BOOTSTRAP="$others" <<<"$add_script" | while read -r line; do
    log "$line"
  done

  # 5. 等它成為成員（Follower 或 Leader，而且是新的 directory id）：每 5 秒看一次，最多 30 次
  for attempt in $(seq 1 30); do
    line=$(quorum_line "$CONTROLLER_QUORUM" "$node_id")

    case $(status_of "$line") in
      Follower|Leader)
        if [ "$(directory_id_of "$line")" = "$new_dir" ]; then
          break
        fi
        ;;
    esac

    sleep 5
  done

  case $(status_of "$line") in
    Follower|Leader)
      ok "$host 是成員（$(status_of "$line")，directory id $new_dir）"
      ;;
    *)
      fail "$host 沒有成為成員（$line）"
      ;;
  esac

  show_status
  final_checks "$host"
}

case $ACTION in
  status)
    show_status
    ;;
  replace)
    if [ -z "$TARGET_HOST" ]; then
      die "用法：bash $0 replace <controller>"
    fi

    replace "$TARGET_HOST"
    finish_step
    ;;
  *)
    die "用法：bash $0 status|replace <controller>"
    ;;
esac
