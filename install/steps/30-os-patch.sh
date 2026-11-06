#!/usr/bin/env bash
# 第 30 站：OS 修補與小版本更新 —— 一台一台 dnf update（Confluent 由 versionlock 擋住），該重開就重開、健康了才做下一台（手把手第 30 章）
# where: ops02 （root）
# run: on-demand（遷移主線的最後一段，不在 install.sh 的安裝順序裡；直接執行這支）；之後銀行每月發布 OS 修補時也是這支
#
# 做什麼：每月修補與小版本更新（9.6 → 9.8）是同一個動作，差別只在銀行的套件庫裡有什麼。
# 需要什麼：銀行的套件庫已同步到要更新的內容（手冊 30.0）；Confluent 套件已被 versionlock 鎖住（第 8 站）。
# 產出什麼：每台更新完的 OS；只有紀錄檔。回滾靠更新前的 VM／LVM 快照（手冊 30.5），不是這支。
# 能不能重跑：可以。已經更新過的主機 dnf update 沒有東西可更新。
#
# 用法：
#   bash steps/30-os-patch.sh plan          每台可更新幾個套件、目前與套件庫裡的 OS 版本、有沒有 confluent-*（有就是 versionlock 沒鎖好，停下來）
#   bash steps/30-os-patch.sh apply         broker 逐台 → controller（leader 最後）→ REST → C3 → 操作機；9.6 → 9.8 這種小版本更新也是這一個動作
#   bash steps/30-os-patch.sh verify [版本]  30.5 驗證：每台的 OS 版本（給了版本就必須相同）、versionlock 沒變、服務 active、under-replicated、REST 經 LB、C3
#   ONLY_HOSTS="kb01" bash steps/30-os-patch.sh apply   只做列出的主機
#   OS_REBOOT=auto|reboot|restart-services  「要重開機」時怎麼做：預設 auto——主機是容器（systemd-detect-virt -c）就改重啟平台服務
#                                           （lab 的容器共用 WSL2 的核心，不能真的重開機），否則 sudo systemctl reboot
#
# 每台：dnf update → dnf needs-restarting -r（要不要重開機）、-s（哪些平台服務要重啟）→ 照判斷做 → 等健康。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-plan}
ONLY_HOSTS=${ONLY_HOSTS:-}

# selected <主機>：沒有 ONLY_HOSTS 時全部都做；有的話只做列出的
selected() {
  if [ -z "$ONLY_HOSTS" ]; then
    return 0
  fi

  [[ " $ONLY_HOSTS " == *" $1 "* ]]
}

# 一台主機的更新（手冊的 os-patch-host.sh）：本身不重開、不重啟；印一行結果，失敗的訊息到 stderr、stdout 沒有結果行、結束碼 1
#   例：updated=124 reboot=yes services=none confluent=8.3.2 os=9.6>9.8
PATCH_HOST=$(cat <<'EOF'
os_version() {
  . /etc/os-release
  echo "$VERSION_ID"
}

# 1. 更新前：可更新幾個、OS 版本
count=$(sudo dnf -q check-update --refresh 2>/dev/null | awk '/^[a-zA-Z0-9]/ {c++} END {print c + 0}')
os_before=$(os_version)

# 2. 更新
if ! sudo dnf -y -q update >/dev/null 2>&1; then
  echo "$(hostname) dnf update 失敗" >&2
  exit 1
fi

# 3. Rocky 專屬：rocky-repos 更新會把預設 repo 檔（外網 mirrorlist）裝回來並啟用，離線的 lab 要再關掉；RHEL 不需要
sudo sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/rocky*.repo 2>/dev/null

# 4. 要不要重開機（needs-restarting -r：結束碼 0 = 不用）、哪些平台服務要重啟
if sudo dnf needs-restarting -r >/dev/null 2>&1; then
  reboot=no
else
  reboot=yes
fi

# 要重啟的服務名稱（排序、去重複），再接成逗號分隔：例 confluent-server,prometheus
matched=$(sudo dnf needs-restarting -s 2>/dev/null | grep -oE 'confluent-[a-z-]+|prometheus|alertmanager' | sort -u)
services=$(echo "$matched" | paste -sd, -)

if [ -z "$services" ]; then
  services=none
fi

# 5. 一行結果
confluent=$(rpm -qa 'confluent-*' --qf '%{VERSION}\n' | sort -u | paste -sd, -)
echo "updated=$count reboot=$reboot services=$services confluent=$confluent os=$os_before>$(os_version)"
EOF
)

# 每台一行：OS 版本、versionlock 的 confluent 套件數、已裝的 confluent 套件數、服務狀態（UNIT 空 = 不查）
#   例：9.8 9 9 active
VERIFY_HOST=$(cat <<'EOF'
. /etc/os-release

locked=$(sudo dnf -q versionlock list 2>/dev/null | awk '/confluent/ {c++} END {print c + 0}')
installed=$(rpm -qa 'confluent-*' | wc -l)
active=""

if [ -n "$UNIT" ]; then
  active=$(systemctl is-active "$UNIT")
fi

echo "$VERSION_ID $locked $installed $active"
EOF
)

# 每台一行（只看不改）：可更新幾個、其中 confluent-* 幾個、鎖住幾個 confluent 套件、目前的 OS 版本、套件庫裡 release 套件的版本
#   例：124 0 9 9.6 9.8
PLAN_HOST=$(cat <<'EOF'
. /etc/os-release

updates=$(sudo dnf -q check-update --refresh 2>/dev/null | awk '/^[a-zA-Z0-9]/ {print $1}')
os_package=$(rpm -q --whatprovides system-release --qf '%{NAME}\n' | head -1)
os_available=$(sudo dnf -q repoquery --latest-limit 1 --qf '%{version}' "$os_package" 2>/dev/null | head -1)

update_count=$(awk 'NF {c++} END {print c + 0}' <<<"$updates")
confluent_count=$(awk '/^confluent-/ {c++} END {print c + 0}' <<<"$updates")
locked=$(sudo dnf -q versionlock list 2>/dev/null | awk '/confluent/ {c++} END {print c + 0}')

echo "$update_count $confluent_count $locked $VERSION_ID ${os_available:-?}"
EOF
)

quorum() {
  kafka-metadata-quorum \
    --bootstrap-controller "$CONTROLLER_QUORUM" \
    --command-config "$INTERNAL_CLIENT_CONF" \
    "$@" 2>/dev/null
}

# under_replicated_count：under-replicated 的 partition 數，例 0
under_replicated_count() {
  kafka-topics \
    --bootstrap-server "$BROKER_TOKEN" \
    --command-config "$ADMIN_CLIENT_CONF" \
    --describe --under-replicated-partitions 2>/dev/null \
    | awk '/Partition:/ {c++} END {print c + 0}'
}

# current_leader：現在的 controller leader，例 kc02
current_leader() {
  local leader_id host

  leader_id=$(quorum describe --status | awk '/LeaderId/{print $2}')

  for host in $CONTROLLERS; do
    if [ "$(node_id_of "$host")" = "$leader_id" ]; then
      echo "$host"
    fi
  done
}

wait_broker_healthy() {
  local host=$1 attempt host_fqdn

  host_fqdn=$(fqdn "$host")

  # 每 10 秒看一次，最多 90 次
  for attempt in $(seq 1 90); do
    if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$host_fqdn:8090/v1/metadata/id")" = 200 ]; then
      if [ "$(under_replicated_count)" = 0 ]; then
        return 0
      fi
    fi

    sleep 10
  done

  return 1
}

wait_controller_caught_up() {
  local host=$1 node_id attempt lag

  node_id=$(node_id_of "$host")

  # 這台在 quorum 裡的 Lag（第 4 欄）回到 0：每 5 秒看一次，最多 90 次
  for attempt in $(seq 1 90); do
    # lint-ok: 第 1 欄等於 node id 的那一行取第 4 欄；grep 比對不到整個欄位
    lag=$(quorum describe --replication | awk -v id="$node_id" '$1 == id {print $4}')

    if [ "$lag" = 0 ]; then
      return 0
    fi

    sleep 5
  done

  return 1
}

wait_healthy() {
  local host=$1

  case $host in
    kb*)
      wait_broker_healthy "$host"
      ;;
    kc*)
      wait_controller_caught_up "$host"
      ;;
    rest*)
      retry 60 5 rest_app_curl -s -o /dev/null -f -m 5 "https://$(fqdn "$host"):8082/v3/clusters"
      ;;
    c3*)
      retry 60 10 curl -s -o /dev/null -f -m 5 "https://$C3_FQDN:9021/"
      ;;
    *)
      return 0
      ;;
  esac
}

# wait_no_under_replicated：剛做完 24 站（kb04 的 replica 還在追上）之類的操作，叢集要幾十秒才穩：最多等 5 分鐘，還不是 0 才算不健康
wait_no_under_replicated() {
  local attempt

  for attempt in $(seq 1 30); do
    if [ "$(under_replicated_count)" = 0 ]; then
      return 0
    fi

    sleep 10
  done

  return 1
}

# wait_for_ssh <主機>：重開機後等 ssh 回來：每 5 秒試一次，最多 60 次
wait_for_ssh() {
  local attempt

  for attempt in $(seq 1 60); do
    if ssh_run "$1" true 2>/dev/null; then
      return 0
    fi

    sleep 5
  done

  return 1
}

# result_field <欄位> <結果行>：PATCH_HOST 那一行某個欄位的值
#   例：result_field reboot "updated=124 reboot=yes services=none …" → yes
result_field() {
  grep -o "$1=[^ ]*" <<<"$2" | cut -d= -f2
}

# restart_platform_services <主機>：這台的平台服務都重啟一次（C3 先重啟它內建的 Prometheus 與 Alertmanager）
restart_platform_services() {
  local host=$1

  case $host in
    c3*)
      ssh_run "$host" 'sudo systemctl restart prometheus alertmanager confluent-control-center'
      ;;
    *)
      ssh_run "$host" "sudo systemctl restart $(unit_of "$host")"
      ;;
  esac
}

# reboot_host <主機>：重開機並等 ssh 回來；主機是容器（或 OS_REBOOT=restart-services）就改重啟平台服務
reboot_host() {
  local host=$1 reboot_mode=${OS_REBOOT:-auto}

  if [ "$reboot_mode" = auto ]; then
    if ssh_run "$host" 'systemd-detect-virt -cq'; then
      reboot_mode=restart-services
    else
      reboot_mode=reboot
    fi
  fi

  if [ "$reboot_mode" = restart-services ]; then
    # lab：容器共用 WSL2 的核心，kernel／systemd 沒有真的換；重啟平台服務讓 JVM 載入新的 glibc，是「該重開機」的最接近做法
    warn "$host：要重開機，但這台是容器（或 OS_REBOOT=restart-services）：改重啟平台服務"
    restart_platform_services "$host"
    return 0
  fi

  ssh_run "$host" 'sudo systemctl reboot' 2>/dev/null
  sleep 20

  if ! wait_for_ssh "$host"; then
    fail "$host 重開機後 ssh 沒有回來"
    return 1
  fi
}

# restart_listed_services <主機> <services 欄位>：只有服務要重啟（不用重開機）時
restart_listed_services() {
  local host=$1 services=$2 unit unit_list

  if [ "$services" = none ]; then
    return 0
  fi

  # C3 的三個服務一起、照這個順序重啟；其他主機只重啟列出來的
  case $host in
    c3*)
      unit_list="prometheus alertmanager confluent-control-center"
      ;;
    *)
      unit_list=$(tr ',' ' ' <<<"$services")
      ;;
  esac

  for unit in $unit_list; do
    if ssh_run "$host" "sudo systemctl restart $unit"; then
      log "$host：重啟 $unit"
    fi
  done
}

# patch_one <主機>：修補、照 needs-restarting 的判斷重開機或重啟、等健康
patch_one() {
  local host=$1 result reboot_needed services drained=0

  # 1. 更新（操作機自己 root 直接跑）
  if [ "$host" = "$OPS_HOST" ]; then
    result=$(bash -s <<<"$PATCH_HOST")
  else
    result=$(ssh_script "$host" <<<"$PATCH_HOST")
  fi

  case $result in
    updated=*)
      ;;
    *)
      fail "$host dnf update 失敗"
      return 1
      ;;
  esac

  log "$host：$result"

  reboot_needed=$(result_field reboot "$result")
  services=$(result_field services "$result")

  # 2. REST 要重開或重啟：先請 LB 團隊停用、等連線排空（手把手 12.1）
  case $host in
    rest*)
      if [ "$reboot_needed" = yes ] || [ "$services" != none ]; then
        if ! lb_member "$host" down; then
          return 1
        fi

        if ! lb_drained "$host"; then
          return 1
        fi

        drained=1
      fi
      ;;
  esac

  # 3. 照判斷做
  if [ "$reboot_needed" = yes ]; then
    if [ "$host" = "$OPS_HOST" ]; then
      warn "操作機自己要重開機：其他主機都做完了，請手動 sudo systemctl reboot"
      return 0
    fi

    if ! reboot_host "$host"; then
      return 1
    fi
  else
    restart_listed_services "$host" "$services"
  fi

  # 4. 等健康
  if wait_healthy "$host"; then
    ok "$host 健康"
  else
    fail "$host 修補後沒有恢復健康"
    return 1
  fi

  # 5. REST：請 LB 團隊恢復
  if [ "$drained" = 1 ]; then
    if ! lb_member "$host" up; then
      return 1
    fi
  fi

  return 0
}

plan() {
  local host counts updates confluent_updates locked os_current os_available

  section "30.1 修補前：under-replicated、每台可更新的套件、versionlock"

  # 1. 開始前叢集是健康的
  if wait_no_under_replicated; then
    ok "沒有 under-replicated"
  else
    fail "有 under-replicated（等了 5 分鐘還是有）：叢集不健康時不修補"
  fi

  # 2. 每台：confluent-* 不在更新清單裡、套件庫的主版本和這台一樣
  for host in $CONTROLLERS $BROKERS $RESTS $C3_HOST $OPS_HOST; do
    if [ "$host" = "$OPS_HOST" ]; then
      counts=$(bash -s <<<"$PLAN_HOST")
    else
      counts=$(ssh_script "$host" <<<"$PLAN_HOST")
    fi

    read -r updates confluent_updates locked os_current os_available <<<"$counts"

    if [ "$confluent_updates" != 0 ]; then
      fail "$host：更新清單裡有 $confluent_updates 個 confluent 套件（versionlock 沒鎖好，照第 8 站重新鎖）"
    elif [ "$os_available" != "?" ] && [ "${os_available%%.*}" != "${os_current%%.*}" ]; then
      fail "$host：套件庫是 ${os_available%%.*}.x 的內容，不是 ${os_current%%.*}.x（小版本更新只能在同一主版本內；請 OS 團隊修套件庫，問題清單 3.6）"
    else
      ok "$host：OS $os_current（套件庫的 release 套件 $os_available，主版本一致）、可更新 $updates 個、鎖住 $locked 個 confluent 套件"
    fi
  done
}

# patch_if_selected <主機>：ONLY_HOSTS 有列（或沒設）才修補；失敗就停
patch_if_selected() {
  local host=$1

  if ! selected "$host"; then
    return 0
  fi

  if ! patch_one "$host"; then
    die "停在 $host"
  fi
}

# controllers_leader_last：controller 的順序，另外兩台在前、leader 最後，例 kc01 kc03 kc02
controllers_leader_last() {
  local leader host

  leader=$(current_leader)

  for host in $CONTROLLERS; do
    if [ "$host" != "$leader" ]; then
      echo "$host"
    fi
  done

  echo "$leader"
}

apply() {
  local host

  # 1. 修補前檢查
  plan

  if [ "$FAIL_COUNT" != 0 ]; then
    die "修補前檢查沒過"
  fi

  # 2. broker 逐台
  section "30.2 broker 逐台"

  for host in $BROKERS; do
    patch_if_selected "$host"
  done

  # 3. controller 逐台，leader 最後
  section "30.3 controller 逐台，leader 最後"

  for host in $(controllers_leader_last); do
    patch_if_selected "$host"
  done

  # 4. REST Proxy、C3、操作機（操作機最後、自己修自己）
  section "30.4 REST Proxy、C3、操作機"

  for host in $RESTS $C3_HOST $OPS_HOST; do
    patch_if_selected "$host"
  done
}

# verify [版本]：30.5 驗證。給了版本（例如 9.8）每台的 OS 版本都要相同；versionlock 數量等於已裝的 confluent 套件數；服務 active；叢集與入口都健康
verify() {
  local expected_os=${1:-} host result unit locked installed active os_version rest_code c3_code

  section "30.5 驗證：OS 版本、versionlock、服務、叢集"

  # 1. 每台
  for host in $CONTROLLERS $BROKERS $RESTS $C3_HOST $OPS_HOST; do
    if [ "$host" = "$OPS_HOST" ]; then
      unit=""
      result=$(UNIT="" bash -s <<<"$VERIFY_HOST")
    else
      unit=$(unit_of "$host")
      result=$(ssh_script "$host" UNIT="$unit" <<<"$VERIFY_HOST")
    fi

    read -r os_version locked installed active <<<"$result"

    if [ -n "$expected_os" ] && [ "$os_version" != "$expected_os" ]; then
      fail "$host：OS $os_version（應為 $expected_os）"
    elif [ "$locked" != "$installed" ]; then
      fail "$host：versionlock $locked 個、已裝 confluent 套件 $installed 個"
    elif [ -n "$unit" ] && [ "$active" != active ]; then
      fail "$host：$unit $active"
    else
      ok "$host：OS $os_version、鎖 $locked／裝 $installed、${unit:-（無服務）} ${active:-}"
    fi
  done

  # 2. 叢集：沒有 under-replicated；REST 經 LB 與 C3 都回 200
  if [ "$(under_replicated_count)" = 0 ]; then
    ok "under-replicated=0"
  else
    fail "有 under-replicated"
  fi

  rest_code=$(rest_app_curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters")
  c3_code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$C3_FQDN:9021/")

  if [ "$rest_code" = 200 ]; then
    ok "REST 經 LB（$REST_VIP）200"
  else
    fail "REST 經 LB $rest_code"
  fi

  if [ "$c3_code" = 200 ]; then
    ok "C3 200"
  else
    fail "C3 $c3_code"
  fi
}

case $ACTION in
  plan)
    plan
    finish_step
    ;;
  apply)
    apply
    finish_step
    ;;
  verify)
    shift
    verify "$@"
    finish_step
    ;;
  *)
    die "用法：bash $0 plan|apply|verify [版本]"
    ;;
esac
