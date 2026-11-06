#!/usr/bin/env bash
# 第 29 站：遷移到新版 Confluent 與 JDK —— 套件滾動升級、JDK 切換、finalize、回滾（手把手第 29 章；c3、publish c3 是第 31 章）
# where: ops02 （root）
# run: on-demand（遷移主線的一段，不在 install.sh 的安裝順序裡；直接執行這支）。版本都在 site.env：基底 CP_VERSION／C3_VERSION／JDK_MAJOR，目標 *_TARGET_*
#
# 做什麼：把平台從基底版本遷移到目標版本，分三段（套件、JDK、finalize），每段結束都可以停下來驗收。
# 需要什麼：基底已通過第 19 站驗收；landing/rpm-target/、landing/bank/ 的目標版本 RPM 與 JDK（第 2、3 站帶進來）。
# 產出什麼：~/upgrade-backup/<時間>/（29.2）；每台換好的套件與 JDK；adopt 之後 site.env 的基底版本是新的。
# 能不能重跑：可以。套件與 JDK 重跑只是再換一次、再重啟一次；finalize 做完不能退。
#
# 用法（照順序；每段結束都跑一次第 19 站驗收）：
#   bash steps/29-upgrade.sh publish [c3]            29.1 把 landing/rpm-target/（目標版本）加進內部套件庫（基底版本留著，回滾要用）；c3 = 把 landing/c3/（31.2 帶進來的單一 C3 版本）加進去
#   bash steps/29-upgrade.sh plan                    29.1 升級前檢查：features、quorum、套件庫有沒有目標版本、under-replicated、已廢棄設定
#   bash steps/29-upgrade.sh backup                  29.2 每台 /etc/confluent 與 drop-in、features、操作機套件清單 → ~/upgrade-backup/<時間>/
#   bash steps/29-upgrade.sh packages [版本]         29.3–29.6 第一段：C3 → broker 逐台 → controller 逐台（leader 最後）→ 操作機 → REST
#                                                   版本預設 site.env 的 CP_TARGET_VERSION；C3 換成 C3_TARGET_VERSION（2.5.x 只支援到 CP 8.2.x，所以 C3 先升）
#   bash steps/29-upgrade.sh jdk [主版號]            29.7 第二段：切到 landing/bank/ 裡最新的 OpenJDK<主版號>U（預設 JDK_TARGET_MAJOR）：controller → broker → 操作機 → C3 → REST
#   CONFIRM_CLUSTER_ID=<cluster id> bash steps/29-upgrade.sh finalize <release>
#                                                   29.9 第三段：kafka-features upgrade --release-version <release>（例如 4.3）；不能退，所以要帶 cluster id 確認
#   bash steps/29-upgrade.sh rollback <主機> [版本]   29.8 finalize 之前：這台 JDK 切回最新的 jdk-<JDK_MAJOR>*、套件 downgrade 到 <版本>（預設 CP_VERSION）
#   bash steps/29-upgrade.sh adopt                   29.10 遷移完成：把 site.env 的 CP_VERSION／C3_VERSION／JDK_MAJOR 改成目標值（之後新增主機、重跑第 8 站才會裝現行版本）
#   bash steps/29-upgrade.sh c3 <版本>              只換 Control Center（手把手 29.3 節、第 31 章）：比現在新就 install、比較舊就 downgrade（回滾）；
#                                                   套件要先上架到內部套件庫
#   ONLY_HOSTS="kb04" bash steps/29-upgrade.sh packages|jdk …   只做列出的主機（回滾後把那台升回去）；略過 C3、role binding、操作機
#
# 每台的步驟：versionlock 解開 → 這台裝的每個 Confluent 套件換成目標版本 → 鎖回 → daemon-reload
# （RPM 升級會換掉 unit 檔）→ 確認設定檔沒被動、ExecStart 指著我們的設定 → 重啟 → 等健康才做下一台。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-plan}
ONLY_HOSTS=${ONLY_HOSTS:-}          # 有值就只做這些主機（空白分隔）
BACKUP_ROOT=$HOME/upgrade-backup
# 8.3 不能再有的設定（基底 8.2 的範本本來就沒有，這裡是再確認一次）（留在設定檔裡 broker 會起不來）
REMOVED_SETTINGS_REGEX='^(message.format.version|message.downconversion.enable|'
REMOVED_SETTINGS_REGEX+='message.timestamp.difference.max.ms|log.message.format.version)'
C3_PACKAGE=confluent-control-center-next-gen

# selected <主機>：沒有 ONLY_HOSTS 時全部都做；有的話只做列出的
selected() {
  if [ -z "$ONLY_HOSTS" ]; then
    return 0
  fi

  [[ " $ONLY_HOSTS " == *" $1 "* ]]
}

quorum() {
  kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" \
    --command-config "$INTERNAL_CLIENT_CONF" "$@" 2>/dev/null
}

features() {
  kafka-features --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" "$@" 2>/dev/null
}

# under_replicated_count：under-replicated 的 partition 數，例 0
under_replicated_count() {
  kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" \
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

# finalized_metadata_version：features 現在的 metadata 版本，例 CP-8.2-IV1A
finalized_metadata_version() {
  local feature_line

  # 例：Feature: confluent.metadata.version  SupportedMinVersion: …  FinalizedVersionLevel: CP-8.2-IV1A  Epoch: 123
  feature_line=$(features describe | grep 'confluent.metadata.version')
  grep -oE '(^|[[:space:]])FinalizedVersionLevel:[[:space:]]+[^[:space:]]+' <<<"$feature_line" | awk '{print $2}'
}

# installed_c3_version：c3-01 上裝著的 C3 版本，例 2.5.1
installed_c3_version() {
  ssh_run "$C3_HOST" "rpm -q --qf '%{VERSION}' $C3_PACKAGE"
}

# ---- 健康：每台做完都要等到這裡回 0 才做下一台 ----

wait_broker_healthy() {
  local host=$1 attempt under_replicated mds_url

  mds_url=https://$(fqdn "$host"):8090/v1/metadata/id

  # 1. 等 MDS 回 200：每 5 秒看一次，最多 60 次
  for attempt in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$mds_url")" = 200 ]; then
      break
    fi

    sleep 5
  done

  # 2. 等 under-replicated 回到 0：每 5 秒看一次，最多 60 次
  for attempt in $(seq 1 60); do
    under_replicated=$(under_replicated_count)

    if [ "$under_replicated" = 0 ]; then
      break
    fi

    sleep 5
  done

  [ "$under_replicated" = 0 ]
}

# controller：quorum 的 replication 狀態裡這台的 Lag（第 4 欄：NodeId DirectoryId LogEndOffset Lag …）回到 0
wait_controller_caught_up() {
  local host=$1 node_id attempt lag

  node_id=$(node_id_of "$host")
  sleep 10

  for attempt in $(seq 1 60); do
    # describe --replication 裡這個 node 那一行的第 4 欄（Lag）
    lag=$(quorum describe --replication | grep -E "^[[:space:]]*$node_id[[:space:]]" | awk '{print $4}')

    if [ "$lag" = 0 ]; then
      return 0
    fi

    sleep 5
  done

  return 1
}

wait_rest_healthy() {
  local host=$1 attempt rest_url

  rest_url=https://$(fqdn "$host"):8082/v3/clusters

  for attempt in $(seq 1 60); do
    if [ "$(rest_app_curl -s -o /dev/null -m 5 -w '%{http_code}' "$rest_url")" = 200 ]; then
      return 0
    fi

    sleep 5
  done

  return 1
}

wait_healthy() {
  case $1 in
    kc*)
      wait_controller_caught_up "$1"
      ;;
    kb*)
      wait_broker_healthy "$1"
      ;;
    rest*)
      wait_rest_healthy "$1"
      ;;
    c3*)
      if ! retry 40 10 curl -s -o /dev/null -f "https://$C3_FQDN:9021/"; then
        return 1
      fi

      # 首頁不經過 MDS：再確認 alice 真的能從 C3 登入
      wait_c3_login
      ;;
  esac
}

# REST 重啟前請 LB 團隊停用、等連線排空（手把手 12.1）；其他角色什麼都不做
lb_out_if_rest() {
  local host=$1

  case $host in
    rest*)
      if ! lb_member "$host" down; then
        return 1
      fi

      if ! lb_drained "$host"; then
        return 1
      fi
      ;;
  esac
}

# REST 健康了請 LB 團隊恢復；其他角色什麼都不做
lb_in_if_rest() {
  local host=$1

  case $host in
    rest*)
      if ! lb_member "$host" up; then
        return 1
      fi
      ;;
  esac
}

# 一台：Confluent 套件換成 <版本>（install 或 downgrade）、鎖回、daemon-reload、確認設定沒被動（手冊的 pkg-swap.sh 加上 c3-change.sh 的檢查）
# 換套件失敗：stderr 印原因、結束碼 1、stdout 沒有結果行，呼叫的一方就不重啟
CHANGE_PACKAGES=$(cat <<'EOF'
before=$(sudo sha256sum "$PROPS" | cut -c1-12)

# 1. 這台裝著的 Confluent 套件，換成這個版本的名稱，例：confluent-server-8.3.2 confluent-cli-8.3.2
packages=$(rpm -qa "confluent-*" --qf "%{NAME}-$VERSION ")

# 2. 解鎖、換版本、用新版本重新鎖
sudo dnf -q versionlock delete "confluent-*" >/dev/null

if ! sudo dnf -q -y --refresh "$DNF_ACTION" $packages >/dev/null; then
  echo "$(hostname) 換套件失敗" >&2
  exit 1
fi

if ! sudo dnf -q versionlock add $packages >/dev/null; then
  echo "$(hostname) 換套件失敗" >&2
  exit 1
fi

# 3. RPM 換掉了 systemd 的 unit 檔：重新載入，重啟時才會用新的定義
sudo systemctl daemon-reload

# 4. C3：RPM 換版本會把 C3 自己要寫的 generated 檔改回 root:root 644（lab 實測），改回來，不然之後改告警規則寫不進去
if [ -d /etc/confluent-control-center ]; then
  for file in alertmanager-generated.yml \
              trigger_rules-generated.yml \
              recording_rules-generated.yml \
              prometheus-generated-local.yml; do
    sudo chown cp-control-center:confluent "/etc/confluent-control-center/$file"
    sudo chmod 0640 "/etc/confluent-control-center/$file"
  done
fi

# 5. 一行結果：版本、設定檔有沒有被動、ExecStart 指向的設定檔
after=$(sudo sha256sum "$PROPS" | cut -c1-12)
exec_file=$(systemctl show "$UNIT" -p ExecStart --value | grep -o '/etc/[^ ]*properties' | head -1)

if [ "$before" = "$after" ]; then
  config=same
else
  config=CHANGED
fi

echo "$(rpm -q --qf '%{VERSION}' "$MAIN_PACKAGE") config=$config exec=$exec_file"
EOF
)

# change_packages_and_restart <主機> <版本> <install|downgrade>
change_packages_and_restart() {
  local host=$1 version=$2 dnf_action=$3 unit props main_package result

  unit=$(unit_of "$host")
  props=$(props_path_of "$host")

  case $host in
    rest*)
      main_package=confluent-kafka-rest
      ;;
    c3*)
      main_package=$C3_PACKAGE
      ;;
    *)
      main_package=confluent-server
      ;;
  esac

  # 1. 換套件；結果不是預期的那一行就不重啟
  result=$(ssh_script "$host" \
    VERSION="$version" \
    DNF_ACTION="$dnf_action" \
    UNIT="$unit" \
    PROPS="$props" \
    MAIN_PACKAGE="$main_package" <<<"$CHANGE_PACKAGES")

  if [ "$result" = "$version config=same exec=$props" ]; then
    ok "$host：$result"
  else
    fail "$host：$result（不重啟）"
    return 1
  fi

  # 2. REST：先請 LB 團隊停用
  if ! lb_out_if_rest "$host"; then
    return 1
  fi

  # 3. 重啟（C3 的套件裡也有 Prometheus、Alertmanager：一起重啟，才會跑新版的執行檔）
  case $host in
    c3*)
      ssh_run "$host" "sudo systemctl restart prometheus alertmanager $unit"
      ;;
    *)
      ssh_run "$host" "sudo systemctl restart $unit"
      ;;
  esac

  # 4. 等健康
  if wait_healthy "$host"; then
    ok "$host：重啟後健康"
  else
    fail "$host：重啟後沒有健康"
    return 1
  fi

  # 5. REST：請 LB 團隊恢復
  if ! lb_in_if_rest "$host"; then
    return 1
  fi
}

# next_controller <做完的清單> <第幾輪> <總輪數> <leader>：這一輪要做哪台；跳過做完的，最後一輪之前也跳過 leader
#   例：next_controller "" 1 3 kc02 → kc01；next_controller " kc01 kc03" 3 3 kc01 → kc02
next_controller() {
  local done_list=$1 round=$2 rounds=$3 leader=$4 candidate

  for candidate in $CONTROLLERS; do
    if [[ " $done_list " == *" $candidate "* ]]; then
      continue
    fi

    if [ "$candidate" = "$leader" ] && [ "$round" -lt "$rounds" ]; then
      continue
    fi

    echo "$candidate"
    return
  done
}

# for_each_controller_leader_last <函式>：controller 一台一台，每輪重查 leader（過程中會換人），leader 留到最後；函式失敗就停
for_each_controller_leader_last() {
  local callback=$1 done_list="" candidate rounds round leader host

  # 1. ONLY_HOSTS 沒列的，當作已經做完
  for candidate in $CONTROLLERS; do
    if ! selected "$candidate"; then
      done_list="$done_list $candidate"
    fi
  done

  rounds=$(( $(wc -w <<<"$CONTROLLERS") - $(wc -w <<<"$done_list") ))

  # 2. 一輪一台
  for round in $(seq 1 "$rounds"); do
    leader=$(current_leader)
    host=$(next_controller "$done_list" "$round" "$rounds" "$leader")

    log "這輪 leader=$leader，做 $host"

    if ! "$callback" "$host"; then
      return 1
    fi

    done_list="$done_list $host"
  done
}

plan() {
  local repo_versions under_replicated host found

  section "29.1 升級前檢查"

  # 1. 現在的版本與套件庫
  log "目前 metadata 版本：$(finalized_metadata_version)；quorum leader：$(current_leader)"
  local repo_server_versions
  repo_server_versions=$(dnf -q --refresh list --showduplicates confluent-server 2>/dev/null \
    | awk '/confluent-internal/{print $2}' \
    | paste -sd' ')
  log "套件庫裡的 confluent-server：$repo_server_versions"

  repo_versions=$(dnf -q list --showduplicates confluent-server "$C3_PACKAGE" 2>/dev/null)

  if grep -q "confluent-server.*$CP_TARGET_VERSION" <<<"$repo_versions"; then
    ok "套件庫有目標版本 confluent-server $CP_TARGET_VERSION"
  else
    fail "套件庫沒有 $CP_TARGET_VERSION：先跑 publish（目標版本照第 1、2 站已經在 rpm-target/）"
  fi

  if grep -q "control-center-next-gen.*$C3_TARGET_VERSION" <<<"$repo_versions"; then
    ok "套件庫有目標版本 C3 $C3_TARGET_VERSION"
  else
    fail "套件庫沒有 C3 $C3_TARGET_VERSION：先跑 publish"
  fi

  log "C3 現在 $(installed_c3_version)：原廠相容表 2.5.x 支援到 CP 8.2.x，要升 8.3 就得先升到 2.6.x（第一段第一步）"

  # 2. 沒有沒追上的複本
  under_replicated=$(under_replicated_count)

  if [ "$under_replicated" = 0 ]; then
    ok "under-replicated=0"
  else
    fail "under-replicated=$under_replicated：先處理再升級"
  fi

  # 3. 8.3 拿掉的設定：每台 server.properties 裡要是 0 行
  for host in $KAFKA_HOSTS; do
    found=$(ssh_run "$host" "sudo grep -cE '$REMOVED_SETTINGS_REGEX' /etc/confluent/kafka/server.properties")

    if [ "$found" = 0 ]; then
      ok "$host：沒有已廢棄的設定"
    else
      fail "$host：$found 個已廢棄的設定（從範本拿掉再重跑第 10 站）"
    fi
  done
}

backup() {
  local backup_dir host tar_command

  backup_dir=$BACKUP_ROOT/$(date +%Y%m%d-%H%M)

  section "29.2 備份 → $backup_dir"

  install -d -m 0700 "$backup_dir"

  # master key（service.env）不進備份：master key 只放操作機 ~/secrets（0600）與各主機的 service.env，備份檔就不必當機敏資料保管
  # drop-in 目錄用絕對路徑找、再去掉開頭的 /（tar 用 -C /，要相對路徑）；$( ) 在那台主機上展開
  # shellcheck disable=SC2016  # 這段字串要送到那台主機才展開
  tar_command='sudo tar -czf - -C / --exclude=etc/confluent/service.env etc/confluent '
  # shellcheck disable=SC2016  # 這段字串要送到那台主機才展開
  tar_command+='$(ls -d /etc/systemd/system/confluent-*.service.d 2>/dev/null | cut -c2-)'

  # 1. 每台的 /etc/confluent 與 systemd drop-in，打包回操作機
  for host in $CLUSTER_HOSTS; do
    if ssh_run "$host" "$tar_command" > "$backup_dir/$host.tar.gz"; then
      ok "$host $(du -h "$backup_dir/$host.tar.gz" | cut -f1)"
    else
      fail "$host 備份失敗"
    fi
  done

  # 2. features 狀態、操作機的套件清單
  features describe > "$backup_dir/features.txt"
  rpm -qa 'confluent-*' | sort > "$backup_dir/ops02-packages.txt"
  chmod -R go-rwx "$backup_dir"
}

# upgrade_controller <主機>：給 for_each_controller_leader_last 用；版本是 packages 設好的 NEW_CP_VERSION
upgrade_controller() {
  change_packages_and_restart "$1" "$NEW_CP_VERSION" install
}

# upgrade_ops_tools <版本>：操作機自己的 kafka-*、confluent 指令（root 直接跑，沒有服務要重啟）
upgrade_ops_tools() {
  local version=$1 ops_packages

  ops_packages=$(rpm -qa "confluent-*" --qf "%{NAME}-$version ")
  dnf -q versionlock delete "confluent-*" >/dev/null

  # shellcheck disable=SC2086  # 套件清單要拆成多個參數
  if ! dnf -q -y --refresh install $ops_packages >/dev/null; then
    die "$OPS_HOST 套件"
  fi

  # shellcheck disable=SC2086  # 套件清單要拆成多個參數
  if ! dnf -q versionlock add $ops_packages >/dev/null; then
    die "$OPS_HOST 套件"
  fi

  ok "$OPS_HOST：$(rpm -q --qf '%{VERSION}' confluent-server)"
}

packages() {
  local host c3_installed

  NEW_CP_VERSION=${1:-$CP_TARGET_VERSION}

  # 1. C3 先（ONLY_HOSTS 時略過）
  if [ -z "$ONLY_HOSTS" ]; then
    section "29.3 Control Center 先（$C3_HOST）：→ $C3_TARGET_VERSION（原廠相容表：2.5.x 到 CP 8.2.x、2.6.x 到 8.3.x）"

    c3_installed=$(installed_c3_version)

    if [ "$c3_installed" = "$C3_TARGET_VERSION" ]; then
      if wait_healthy "$C3_HOST"; then
        ok "C3 已經是 $c3_installed（C3_TARGET_VERSION），UI 200"
      else
        fail "C3 UI 沒有 200"
      fi
    else
      if ! change_packages_and_restart "$C3_HOST" "$C3_TARGET_VERSION" install; then
        die "C3 升級失敗"
      fi
    fi
  fi

  # 2. broker 逐台
  section "29.4 broker 逐台 → $NEW_CP_VERSION"

  for host in $BROKERS; do
    if ! selected "$host"; then
      continue
    fi

    if ! change_packages_and_restart "$host" "$NEW_CP_VERSION" install; then
      die "停在 $host"
    fi
  done

  # 3. controller 逐台，leader 最後
  section "29.5 controller 逐台（每輪重查 leader，leader 最後）"

  if ! for_each_controller_leader_last upgrade_controller; then
    die "controller 升級停下"
  fi

  # 4. ONLY_HOSTS：只剩 REST，沒有 role binding 與操作機
  if [ -n "$ONLY_HOSTS" ]; then
    for host in $RESTS; do
      if ! selected "$host"; then
        continue
      fi

      if ! change_packages_and_restart "$host" "$NEW_CP_VERSION" install; then
        die "停在 $host"
      fi
    done

    log "ONLY_HOSTS=$ONLY_HOSTS：略過 role binding 與操作機"
    return 0
  fi

  # 5. 原廠要求：RBAC 環境升 REST Proxy 之前，先給它在 _confluent-command 的 ResourceOwner
  section "29.6 REST Proxy（先給 svc-rest 在 _confluent-command 的 ResourceOwner）與操作機"

  source "$CONF_DIR/kraft.env"   # CLUSTER_ID

  if ! confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
    --client-cert-path "$CERTS_DIR/svc-ops.crt" --client-key-path "$KEYS_DIR/svc-ops.key" >/dev/null 2>&1; then
    die "confluent login（svc-ops）失敗"
  fi

  if mds_write confluent iam rbac role-binding create \
    --principal User:svc-rest --role ResourceOwner --resource Topic:_confluent-command \
    --kafka-cluster "$CLUSTER_ID" >/dev/null 2>&1; then
    ok "User:svc-rest ResourceOwner Topic:_confluent-command"
  else
    fail "role binding"
  fi

  # 6. 操作機自己的工具（手冊 29.6：先換操作機，再換 REST）
  upgrade_ops_tools "$NEW_CP_VERSION"

  # 7. REST 一台一台（change_packages_and_restart 裡會請 LB 團隊停用、恢復）
  for host in $RESTS; do
    if ! change_packages_and_restart "$host" "$NEW_CP_VERSION" install; then
      die "停在 $host"
    fi
  done

  log "第一段完成：跑第 19 站驗收；features 還沒升，隨時可以 rollback"
}

# 一台：解壓新 JDK、切 /opt/java/current（手冊的 jdk-switch.sh）；哪一步失敗就停，current 不切
SWITCH_JDK=$(cat <<'EOF'
set -e

sudo tar -xzf "/tmp/$JDK_TAR_NAME" -C /opt/java
rm -f "/tmp/$JDK_TAR_NAME"
sudo chown -R root:root "/opt/java/$JDK_DIR"
sudo ln -sfn "/opt/java/$JDK_DIR" /opt/java/current
readlink /opt/java/current
EOF
)

# switch_jdk_on <主機>：送 tar、切 JDK、重啟、等健康、確認程序真的用新的 java。tar 與目錄是 jdk 設好的 JDK_TAR_PATH、JDK_DIR_NAME
switch_jdk_on() {
  local host=$1 unit linked process_java

  unit=$(unit_of "$host")

  # 1. 送 tar、切 JDK
  if ! copy_to_tmp "$host" "$JDK_TAR_PATH"; then
    fail "$host scp"
    return 1
  fi

  local jdk_tar_name
  jdk_tar_name=$(basename "$JDK_TAR_PATH")

  if ! linked=$(ssh_script "$host" JDK_TAR_NAME="$jdk_tar_name" JDK_DIR="$JDK_DIR_NAME" <<<"$SWITCH_JDK"); then
    fail "$host：切 JDK 失敗"
    return 1
  fi

  # 2. 重啟、等健康（REST 前後請 LB 團隊停用、恢復）
  if ! lb_out_if_rest "$host"; then
    return 1
  fi

  ssh_run "$host" "sudo systemctl restart $unit"

  if ! wait_healthy "$host"; then
    fail "$host：換 JDK 後沒有健康"
    return 1
  fi

  if ! lb_in_if_rest "$host"; then
    return 1
  fi

  # 3. 那個服務正在跑的 java 執行檔
  local main_pid
  main_pid=$(ssh_run "$host" "systemctl show $unit -p MainPID --value")
  process_java=$(ssh_run "$host" "sudo readlink /proc/$main_pid/exe")

  if [ "$process_java" = "/opt/java/$JDK_DIR_NAME/bin/java" ]; then
    ok "$host：$linked，程序用 $process_java"
  else
    fail "$host：程序用 $process_java"
  fi
}

# jdk_sha256_ok <tar 檔名>：landing/bank/ 裡這個 tar 的 sha256 對不對（subshell：不改變目前的目錄）
jdk_sha256_ok() {
  (
    if ! cd "$LANDING/bank"; then
      exit 1
    fi

    sha256sum -c --quiet "$1.sha256"
  )
}

# switch_jdk_on_ops：操作機自己（root）；沒有服務，只切連結
switch_jdk_on_ops() {
  if ! tar -xzf "$JDK_TAR_PATH" -C /opt/java; then
    die "$OPS_HOST：切 JDK 失敗"
  fi

  if ! chown -R root:root "/opt/java/$JDK_DIR_NAME"; then
    die "$OPS_HOST：切 JDK 失敗"
  fi

  if ! ln -sfn "/opt/java/$JDK_DIR_NAME" /opt/java/current; then
    die "$OPS_HOST：切 JDK 失敗"
  fi

  ok "$OPS_HOST：$(java -version 2>&1 | head -1)"
}

jdk() {
  local major=${1:-$JDK_TARGET_MAJOR} host

  # 1. 銀行給的 tar（有好幾個就取最新的），核對 sha256
  JDK_TAR_PATH=$(ls "$LANDING"/bank/OpenJDK"${major}"U-jdk_x64_linux_hotspot_*.tar.gz 2>/dev/null | sort -V | tail -1)

  if [ -z "$JDK_TAR_PATH" ]; then
    die "$LANDING/bank/ 沒有 OpenJDK${major}U 的 tar（銀行交付）"
  fi

  if ! jdk_sha256_ok "$(basename "$JDK_TAR_PATH")"; then
    die "$(basename "$JDK_TAR_PATH") 的 sha256 不符"
  fi

  # tar 裡的頂層目錄，例：jdk-25.0.5+8
  JDK_DIR_NAME=$(tar -tzf "$JDK_TAR_PATH" | head -1 | cut -d/ -f1)

  section "29.7 JDK $JDK_MAJOR → $JDK_DIR_NAME（controller、broker、REST、C3、操作機）"

  # 2. controller（leader 最後）
  if ! for_each_controller_leader_last switch_jdk_on; then
    die "controller 換 JDK 停下"
  fi

  # 3. broker 逐台
  for host in $BROKERS; do
    if ! selected "$host"; then
      continue
    fi

    if ! switch_jdk_on "$host"; then
      die "停在 $host"
    fi
  done

  # 4. 操作機（ONLY_HOSTS 時略過）
  if [ -n "$ONLY_HOSTS" ]; then
    log "ONLY_HOSTS=$ONLY_HOSTS：略過操作機"
  else
    switch_jdk_on_ops
  fi

  # 5. C3，再來 REST（switch_jdk_on 裡會請 LB 團隊停用、恢復）
  for host in $C3_HOST $RESTS; do
    if ! selected "$host"; then
      continue
    fi

    if ! switch_jdk_on "$host"; then
      die "停在 $host"
    fi
  done

  if [ -z "$ONLY_HOSTS" ]; then
    log "第二段完成：跑第 19 站驗收"
  fi
}

finalize() {
  local release=${1:-}

  if [ -z "$release" ]; then
    die "用法：finalize <release>，例如 finalize 4.3"
  fi

  source "$CONF_DIR/kraft.env"

  section "29.9 finalize：features → $release（之後不能退回舊版）"

  # 1. 先看會升哪些 feature，再預演
  features version-mapping --release-version "$release" | tee -a "$LOG_FILE"
  features upgrade --release-version "$release" --dry-run | tee -a "$LOG_FILE"

  # 2. 不能退，所以要帶 cluster id 確認
  if [ "${CONFIRM_CLUSTER_ID:-}" != "$CLUSTER_ID" ]; then
    log "確定前兩段都驗收過了，再帶上 cluster id 執行：CONFIRM_CLUSTER_ID=$CLUSTER_ID bash $0 finalize $release"
    exit 1
  fi

  # 3. 正式升
  features upgrade --release-version "$release" | tee -a "$LOG_FILE"
  log "升版後：$(finalized_metadata_version)"
}

rollback() {
  local host=${1:-} version=${2:-$CP_VERSION} metadata_line

  if [ -z "$host" ]; then
    die "用法：rollback <主機> [版本]"
  fi

  section "29.8 回滾 $host → $version（JDK 先切回最新的 jdk-$JDK_MAJOR*）"

  # 1. features 已經不是舊版，就是 finalize 過了
  metadata_line=$(features describe | grep confluent.metadata.version)

  if ! grep -q "CP-${version%.*}" <<<"$metadata_line"; then
    warn "features 已經不是 ${version%.*}：finalize 之後 downgrade 不保證可行"
  fi

  # 2. JDK 先切回去（舊版不支援新的 JDK；舊的目錄還在）
  ssh_script "$host" JDK_MAJOR="$JDK_MAJOR" <<'EOF'
old_jdk=$(ls -d /opt/java/jdk-"$JDK_MAJOR"* | sort -V | tail -1)
sudo ln -sfn "$old_jdk" /opt/java/current
readlink /opt/java/current
EOF

  # 3. 套件退回、重啟、等健康
  if ! change_packages_and_restart "$host" "$version" downgrade; then
    die "$host 回滾失敗"
  fi
}

# newest_version <版本> <版本>：兩個版本裡比較新的，例 2.6.0 2.6.1 → 2.6.1
newest_version() {
  printf '%s\n' "$1" "$2" | sort -V | tail -1
}

# c3 <版本>：只換 Control Center；比現在新就 install、比較舊就 downgrade
c3() {
  local target=${1:-} installed action

  if [ -z "$target" ]; then
    die "用法：bash $0 c3 <版本>"
  fi

  installed=$(installed_c3_version)

  section "31 Control Center $installed → $target（$C3_HOST）"

  if [ "$installed" = "$target" ]; then
    ok "已經是 $target"
    return 0
  fi

  if [ "$(newest_version "$installed" "$target")" = "$installed" ]; then
    action=downgrade
  else
    action=install
  fi

  if ! change_packages_and_restart "$C3_HOST" "$target" "$action"; then
    die "C3 換版本失敗"
  fi
}

# adopt：遷移做完了，site.env 的基底版本換成目標值（只改版本那幾行）
adopt() {
  local site_env=$INSTALL_DIR/conf/site.env

  section "29.10 site.env 的基底版本改成目標版本"

  sed -i \
    -e "s/^CP_VERSION=[0-9.]*/CP_VERSION=$CP_TARGET_VERSION/" \
    -e "s/^C3_VERSION=[0-9.]*/C3_VERSION=$C3_TARGET_VERSION/" \
    -e "s/^JDK_MAJOR=[0-9]*/JDK_MAJOR=$JDK_TARGET_MAJOR/" \
    "$site_env"

  ok "$(grep -E '^(CP_VERSION|C3_VERSION|JDK_MAJOR)=' "$site_env" | cut -d' ' -f1 | paste -sd' ')"
}

# rpm_target_sums_ok：落地區 SHA256SUMS 裡 rpm-target/ 那些行核對得上（subshell：不改變目前的目錄）
rpm_target_sums_ok() {
  (
    if ! cd "$LANDING"; then
      exit 1
    fi

    grep " rpm-target/" SHA256SUMS | sha256sum -c --quiet
  )
}

# landing_dir_sums_ok <目錄名>：landing/<目錄名>/ 自己的 SHA256SUMS 核對得上（subshell：不改變目前的目錄）
landing_dir_sums_ok() {
  (
    if ! cd "$LANDING/$1"; then
      exit 1
    fi

    sha256sum -c --quiet SHA256SUMS
  )
}

# check_c3_dependencies <目錄名>：31.2。RPM 不替你查前置套件，所以印出 RPM 宣告的相依，並確認 c3-01 上兩個前置套件都在
check_c3_dependencies() {
  local source_dir=$1 declared installed requires

  requires=$(rpm -qpR "$LANDING/$source_dir"/confluent-control-center-next-gen-*.rpm 2>/dev/null \
    | grep -vE '^(rpmlib|/)')
  declared=$(sort -u <<<"$requires" | paste -sd';' -)
  log "RPM 宣告的相依：$declared"

  if ! installed=$(ssh_run "$C3_HOST" 'rpm -q cyrus-sasl openssl-devel'); then
    die "$C3_HOST 缺 C3 的前置套件（$(paste -sd' ' <<<"$installed")）：請銀行 OS 團隊放進套件庫並安裝"
  fi

  log "$C3_HOST 的前置套件：$(paste -sd' ' <<<"$installed")"
}

# publish [c3]：landing/rpm-target/（目標版本）加進內部套件庫；只推 confluent/，基底版本留著（回滾要用）
publish() {
  local source_dir=${1:-rpm-target}   # 預設 rpm-target（目標版本，第 1、2 站已帶進來）；c3 = 第 31 章帶進來的單一 C3 版本
  local rpm_list c3_versions server_versions

  section "29.1 上架：$LANDING/$source_dir/ → 內部套件庫"

  # 1. 有檔案、sha256 核對得上
  rpm_list=$(ls "$LANDING/$source_dir"/*.rpm 2>/dev/null)

  if [ -z "$rpm_list" ]; then
    die "$LANDING/$source_dir/ 沒有 RPM：照第 1、2 站（或 31.1、31.2）把檔案帶進來"
  fi

  if [ "$source_dir" = rpm-target ]; then
    if ! rpm_target_sums_ok; then
      die "落地區 SHA256SUMS 的 rpm-target 核對失敗"
    fi
  else
    if ! landing_dir_sums_ok "$source_dir"; then
      die "$source_dir/SHA256SUMS 核對失敗"
    fi

    check_c3_dependencies "$source_dir"
  fi

  # 2. 加進內部套件庫的 confluent/（舊版不刪，回滾要用），更新索引
  mkdir -p "$REPO_DIR/confluent"
  cp "$LANDING/$source_dir"/*.rpm "$REPO_DIR/confluent/"

  if ! createrepo_c -q --update "$REPO_DIR/confluent"; then
    die "createrepo_c 失敗"
  fi

  # 3. 只推 confluent/ 這個目錄到套件庫
  if ! tar -C "$REPO_DIR" -cf - confluent \
     | ssh_run_as "$REPO_DEPLOY_USER" "$REPO_HOST" 'tar -C /var/www/repo -xpf -'; then
    die "推送失敗"
  fi

  # 4. 確認套件庫裡有哪些版本（--refresh：剛推上去）
  if [ "$source_dir" != rpm-target ]; then
    local c3_lines
    c3_lines=$(dnf -q --refresh --showduplicates list "$C3_PACKAGE" 2>/dev/null | awk '/confluent-internal/{print $2}')
    c3_versions=$(sort -uV <<<"$c3_lines" | paste -sd' ')
    ok "套件庫的 C3：$c3_versions"
    return 0
  fi

  # 例：1:8.2.4-1 1:8.3.2-1 → 8.2.4 8.3.2
  local server_lines
  server_lines=$(dnf -q --refresh --showduplicates list confluent-server 2>/dev/null \
    | awk '/confluent-internal/{print $2}')
  server_versions=$(sed 's/^1://; s/-1$//' <<<"$server_lines" | sort -uV | paste -sd' ')

  if [[ " $server_versions " == *" $CP_TARGET_VERSION "* && " $server_versions " == *" $CP_VERSION "* ]]; then
    ok "套件庫的 confluent-server：$server_versions"
  else
    fail "套件庫的 confluent-server 是「$server_versions」，應同時有 $CP_VERSION 與 $CP_TARGET_VERSION"
  fi
}

case $ACTION in
  plan|backup|adopt)
    "$ACTION"
    ;;
  # lint-ok: case 的選項用 | 分隔，不是管線
  publish|packages|jdk|finalize|rollback|c3)
    shift
    "$ACTION" "$@"
    ;;
  *)
    sed -n '11,27p' "$0"
    exit 1
    ;;
esac

finish_step
