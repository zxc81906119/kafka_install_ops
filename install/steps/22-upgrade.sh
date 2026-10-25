#!/usr/bin/env bash
# 第 22 站：升級 Confluent 與 JDK —— 套件滾動升級、JDK 切換、finalize、回滾（手把手第 22 章）
# where: ops02 （cpadmin）
# run: on-demand（不在安裝順序裡；要升級時直接執行這支）
#
# 用法（照順序；每段結束都跑一次第 20 站驗收）：
#   bash steps/22-upgrade.sh plan                    22.1 升級前檢查：features、quorum、套件庫有沒有新版、under-replicated、已廢棄設定
#   bash steps/22-upgrade.sh backup                  22.2 每台 /etc/confluent 與 drop-in、features、操作機套件清單 → ~/upgrade-backup/<時間>/
#   bash steps/22-upgrade.sh packages [版本]         22.3–22.6 第一段：C3 → broker 逐台 → controller 逐台（leader 最後）→ REST → 操作機
#                                                   版本預設 site.env 的 CP_VERSION（升級前先改 site.env，之後重跑其他站才一致）
#   bash steps/22-upgrade.sh jdk <主版號>             22.7 第二段：切到 landing/bank/ 裡最新的 OpenJDK<主版號>U，C3 不動
#   CONFIRM_CLUSTER_ID=<cluster id> bash steps/22-upgrade.sh finalize <release>
#                                                   22.8 第三段：kafka-features upgrade --release-version <release>（例如 4.3）；不能退，所以要帶 cluster id 確認
#   bash steps/22-upgrade.sh rollback <主機> <版本>   22.9 finalize 之前：這台 JDK 切回最新的 jdk-21*、套件 downgrade 到 <版本>
#   bash steps/22-upgrade.sh c3 <版本>              只換 Control Center（手把手第 28 章）：比現在新就 install、比較舊就 downgrade（回滾）；
#                                                   套件要先上架到內部套件庫；做完把 site.env 的 C3_VERSION 改成同一版
#   ONLY_HOSTS="kb04" bash steps/22-upgrade.sh packages|jdk …   只做列出的主機（回滾後把那台升回去）；略過 C3、role binding、操作機
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
# selected <主機>：沒有 ONLY_HOSTS 時全部都做；有的話只做列出的
selected() { [ -z "$ONLY_HOSTS" ] || [[ " $ONLY_HOSTS " == *" $1 "* ]]; }
BACKUP_ROOT=$HOME/upgrade-backup
# 8.3 不能再有的設定（留在設定檔裡 broker 會起不來）
REMOVED_SETTINGS_REGEX='^(message.format.version|message.downconversion.enable|message.timestamp.difference.max.ms|log.message.format.version)'

quorum() { kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" --command-config "$INTERNAL_CLIENT_CONF" "$@" 2>/dev/null; }
features() { kafka-features --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" "$@" 2>/dev/null; }
under_replicated_count() { kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:; }
current_leader() { local leader_id; leader_id=$(quorum describe --status | awk '/LeaderId/{print $2}'); for host in $CONTROLLERS; do [ "$(node_id_of "$host")" = "$leader_id" ] && echo "$host"; done; }

# ---- 健康：每台做完都要等到這裡回 0 才做下一台 ----
wait_broker_healthy() {
  local host=$1 attempt under_replicated
  for attempt in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$(fqdn "$host"):8090/v1/metadata/id")" = 200 ] && break; sleep 5
  done
  for attempt in $(seq 1 60); do under_replicated=$(under_replicated_count); [ "$under_replicated" = 0 ] && break; sleep 5; done
  [ "$under_replicated" = 0 ]
}
# controller：quorum 的 replication 狀態裡這台的 Lag（第 4 欄：NodeId DirectoryId LogEndOffset Lag …）回到 0
wait_controller_caught_up() {
  local host=$1 node_id attempt lag
  node_id=$(node_id_of "$host"); sleep 10
  for attempt in $(seq 1 60); do lag=$(quorum describe --replication | awk -v id="$node_id" '$1 == id {print $4}'); [ "$lag" = 0 ] && return 0; sleep 5; done
  return 1
}
wait_rest_healthy() {
  local host=$1 attempt
  for attempt in $(seq 1 60); do
    [ "$(rest_app_curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$(fqdn "$host"):8082/v3/clusters")" = 200 ] && return 0; sleep 5
  done
  return 1
}
wait_healthy() { case $1 in kc*) wait_controller_caught_up "$1";; kb*) wait_broker_healthy "$1";; rest*) wait_rest_healthy "$1";; c3*) retry 40 10 curl -s -o /dev/null -f "https://$C3_FQDN:9021/";; esac; }

# 一台：Confluent 套件換成 <版本>（install 或 downgrade）、鎖回、daemon-reload、確認設定沒被動，重啟
CHANGE_PACKAGES=$(cat <<'EOF'
before=$(sudo sha256sum "$PROPS" | cut -c1-12)
packages=$(rpm -qa "confluent-*" --qf "%{NAME}-$VERSION ")
sudo dnf -q versionlock delete "confluent-*" >/dev/null
sudo dnf -q -y "$DNF_ACTION" $packages >/dev/null && sudo dnf -q versionlock add $packages >/dev/null
sudo systemctl daemon-reload
# C3：RPM 換版本會把 C3 自己要寫的 generated 檔改回 root:root 644（lab 實測），改回來，不然之後改告警規則寫不進去
if [ -d /etc/confluent-control-center ]; then
  for file in alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml; do
    sudo chown cp-control-center:confluent /etc/confluent-control-center/$file && sudo chmod 0640 /etc/confluent-control-center/$file
  done
fi
after=$(sudo sha256sum "$PROPS" | cut -c1-12)
exec_file=$(systemctl show "$UNIT" -p ExecStart --value | grep -o '/etc/[^ ]*properties')
echo "$(rpm -q --qf '%{VERSION}' "$MAIN_PACKAGE") config=$([ "$before" = "$after" ] && echo same || echo CHANGED) exec=$exec_file"
EOF
)
# change_packages_and_restart <主機> <版本> <install|downgrade>
change_packages_and_restart() {
  local host=$1 version=$2 dnf_action=$3 unit props main_package result
  unit=$(unit_of "$host"); props=$(props_path_of "$host")
  case $host in rest*) main_package=confluent-kafka-rest;; c3*) main_package=confluent-control-center-next-gen;; *) main_package=confluent-server;; esac
  result=$(ssh_script "$host" VERSION="$version" DNF_ACTION="$dnf_action" UNIT="$unit" PROPS="$props" MAIN_PACKAGE="$main_package" <<<"$CHANGE_PACKAGES")
  case $result in "$version config=same exec=$props") ok "$host：$result";; *) fail "$host：$result（不重啟）"; return 1;; esac
  # C3 的套件裡也有 Prometheus、Alertmanager：一起重啟，才會跑新版的執行檔
  case $host in c3*) ssh_run "$host" "sudo systemctl restart prometheus alertmanager $unit";; *) ssh_run "$host" "sudo systemctl restart $unit";; esac
  if wait_healthy "$host"; then ok "$host：重啟後健康"; else fail "$host：重啟後沒有健康"; return 1; fi
}

# controller 一台一台，每輪重查 leader（過程中會換人），leader 留到最後
for_each_controller_leader_last() {
  local callback=$1 done_list="" round leader host candidate
  for candidate in $CONTROLLERS; do selected "$candidate" || done_list="$done_list $candidate"; done
  local remaining; remaining=$(( $(wc -w <<<"$CONTROLLERS") - $(wc -w <<<"$done_list") ))
  for round in $(seq 1 "$remaining"); do
    leader=$(current_leader); host=""
    for candidate in $CONTROLLERS; do
      [[ " $done_list " == *" $candidate "* ]] && continue
      [ "$candidate" = "$leader" ] && [ "$round" -lt "$remaining" ] && continue
      host=$candidate; break
    done
    log "這輪 leader=$leader，做 $host"
    "$callback" "$host" || return 1
    done_list="$done_list $host"
  done
}

plan() {
  section "22.1 升級前檢查"
  local finalized
  finalized=$(features describe | awk '/confluent.metadata.version/{for(i=1;i<=NF;i++) if($i=="FinalizedVersionLevel:") print $(i+1)}')
  log "目前 metadata 版本：$finalized；quorum leader：$(current_leader)"
  log "套件庫裡的 confluent-server：$(dnf -q --refresh list --showduplicates confluent-server 2>/dev/null | awk '/confluent-internal/{print $2}' | paste -sd' ')"
  if grep -q "$CP_VERSION" <<<"$(dnf -q list --showduplicates confluent-server 2>/dev/null)"; then ok "套件庫有目標版本 $CP_VERSION"; else fail "套件庫沒有 $CP_VERSION：照第 1–4 站帶進來"; fi
  local under_replicated; under_replicated=$(under_replicated_count)
  if [ "$under_replicated" = 0 ]; then ok "under-replicated=0"; else fail "under-replicated=$under_replicated：先處理再升級"; fi
  for host in $KAFKA_HOSTS; do
    local found; found=$(ssh_run "$host" "sudo grep -cE '$REMOVED_SETTINGS_REGEX' /etc/confluent/kafka/server.properties")
    if [ "$found" = 0 ]; then ok "$host：沒有已廢棄的設定"; else fail "$host：$found 個已廢棄的設定（從範本拿掉再重跑第 10 站）"; fi
  done
}

backup() {
  local backup_dir; backup_dir=$BACKUP_ROOT/$(date +%Y%m%d-%H%M)
  section "22.2 備份 → $backup_dir"
  install -d -m 0700 "$backup_dir"
  for host in $CLUSTER_HOSTS; do
    # master key（service.env）與保管庫身分不進備份：正本在 CyberArk，備份檔就不必當機敏資料保管
    if ssh_run "$host" 'sudo tar -czf - -C / --exclude=etc/confluent/service.env --exclude=etc/confluent/conjur etc/confluent $(ls -d etc/systemd/system/confluent-*.service.d 2>/dev/null)' > "$backup_dir/$host.tar.gz"
    then ok "$host $(du -h "$backup_dir/$host.tar.gz" | cut -f1)"; else fail "$host 備份失敗"; fi
  done
  features describe > "$backup_dir/features.txt"
  rpm -qa 'confluent-*' | sort > "$backup_dir/ops02-packages.txt"
  chmod -R go-rwx "$backup_dir"
}

packages() {
  local version=${1:-$CP_VERSION}
  if [ -z "$ONLY_HOSTS" ]; then
  section "22.3 Control Center 先（$C3_HOST）"
  local c3_installed; c3_installed=$(ssh_run "$C3_HOST" "rpm -q --qf '%{VERSION}' confluent-control-center-next-gen")
  if [ "$c3_installed" = "$C3_VERSION" ]; then
    if wait_healthy "$C3_HOST"; then ok "C3 $c3_installed 不用換（site.env 的 C3_VERSION），UI 200"; else fail "C3 UI 沒有 200"; fi
  else
    change_packages_and_restart "$C3_HOST" "$C3_VERSION" install || die "C3 升級失敗"
  fi
  fi
  section "22.4 broker 逐台 → $version"
  for host in $BROKERS; do selected "$host" || continue; change_packages_and_restart "$host" "$version" install || die "停在 $host"; done
  section "22.5 controller 逐台（每輪重查 leader，leader 最後）"
  upgrade_controller() { change_packages_and_restart "$1" "$version" install; }
  for_each_controller_leader_last upgrade_controller || die "controller 升級停下"
  if [ -n "$ONLY_HOSTS" ]; then
    for host in $RESTS; do selected "$host" || continue; change_packages_and_restart "$host" "$version" install || die "停在 $host"; done
    log "ONLY_HOSTS=$ONLY_HOSTS：略過 role binding 與操作機"; return 0
  fi
  section "22.6 REST Proxy（先給 svc-rest 在 _confluent-command 的 ResourceOwner）與操作機"
  source "$CONF_DIR/kraft.env"   # CLUSTER_ID
  confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
    --client-cert-path "$CERTS_DIR/svc-ops.crt" --client-key-path "$KEYS_DIR/svc-ops.key" >/dev/null 2>&1 || die "confluent login（svc-ops）失敗"
  if retry 3 5 confluent iam rbac role-binding create --principal User:svc-rest --role ResourceOwner --resource Topic:_confluent-command \
       --kafka-cluster "$CLUSTER_ID" >/dev/null 2>&1; then ok "User:svc-rest ResourceOwner Topic:_confluent-command"; else fail "role binding"; fi
  for host in $RESTS; do change_packages_and_restart "$host" "$version" install || die "停在 $host"; done
  local ops_packages; ops_packages=$(rpm -qa "confluent-*" --qf "%{NAME}-$version ")
  sudo dnf -q versionlock delete "confluent-*" >/dev/null
  # shellcheck disable=SC2086  # 套件清單要拆成多個參數
  if sudo dnf -q -y install $ops_packages >/dev/null && sudo dnf -q versionlock add $ops_packages >/dev/null; then ok "$OPS_HOST：$(rpm -q --qf '%{VERSION}' confluent-server)"
  else fail "$OPS_HOST 套件"; fi
  log "第一段完成：跑第 20 站驗收；features 還沒升，隨時可以 rollback"
}

# 一台：解壓新 JDK、切 /opt/java/current、重啟（操作機沒有服務，只切連結）
SWITCH_JDK=$(cat <<'EOF'
sudo tar -xzf "/tmp/$JDK_TAR_NAME" -C /opt/java && rm -f "/tmp/$JDK_TAR_NAME"
sudo chown -R root:root "/opt/java/$JDK_DIR"
sudo ln -sfn "/opt/java/$JDK_DIR" /opt/java/current
readlink /opt/java/current
EOF
)
jdk() {
  local major=${1:?用法：jdk <主版號>，例如 jdk 25} jdk_tar jdk_dir
  jdk_tar=$(ls "$LANDING"/bank/OpenJDK"${major}"U-jdk_x64_linux_hotspot_*.tar.gz 2>/dev/null | sort -V | tail -1)
  [ -n "$jdk_tar" ] || die "$LANDING/bank/ 沒有 OpenJDK${major}U 的 tar（銀行交付）"
  (cd "$LANDING/bank" && sha256sum -c --quiet "$(basename "$jdk_tar").sha256") || die "$(basename "$jdk_tar") 的 sha256 不符"
  jdk_dir=$(tar -tzf "$jdk_tar" | head -1 | cut -d/ -f1)
  section "22.7 JDK → $jdk_dir（$C3_HOST 不動）"
  switch_jdk_on() {
    local host=$1 linked process_java
    copy_to_tmp "$host" "$jdk_tar" || { fail "$host scp"; return 1; }
    linked=$(ssh_script "$host" JDK_TAR_NAME="$(basename "$jdk_tar")" JDK_DIR="$jdk_dir" <<<"$SWITCH_JDK")
    ssh_run "$host" "sudo systemctl restart $(unit_of "$host")"
    wait_healthy "$host" || { fail "$host：換 JDK 後沒有健康"; return 1; }
    process_java=$(ssh_run "$host" "sudo readlink /proc/\$(systemctl show $(unit_of "$host") -p MainPID --value)/exe")
    case $process_java in "/opt/java/$jdk_dir/bin/java") ok "$host：$linked，程序用 $process_java";; *) fail "$host：程序用 $process_java";; esac
  }
  for_each_controller_leader_last switch_jdk_on || die "controller 換 JDK 停下"
  for host in $BROKERS $RESTS; do selected "$host" || continue; switch_jdk_on "$host" || die "停在 $host"; done
  [ -n "$ONLY_HOSTS" ] && { log "ONLY_HOSTS=$ONLY_HOSTS：略過操作機"; return 0; }
  sudo tar -xzf "$jdk_tar" -C /opt/java && sudo chown -R root:root "/opt/java/$jdk_dir" && sudo ln -sfn "/opt/java/$jdk_dir" /opt/java/current
  ok "$OPS_HOST：$(java -version 2>&1 | head -1)"
  log "$C3_HOST 留在 $(ssh_run "$C3_HOST" 'readlink /opt/java/current')；第二段完成：跑第 20 站驗收"
}

finalize() {
  local release=${1:?用法：finalize <release>，例如 finalize 4.3}
  source "$CONF_DIR/kraft.env"
  section "22.8 finalize：features → $release（之後不能退回舊版）"
  features version-mapping --release-version "$release" | tee -a "$LOG_FILE"
  features upgrade --release-version "$release" --dry-run | tee -a "$LOG_FILE"
  if [ "${CONFIRM_CLUSTER_ID:-}" != "$CLUSTER_ID" ]; then
    log "確定前兩段都驗收過了，再帶上 cluster id 執行：CONFIRM_CLUSTER_ID=$CLUSTER_ID bash $0 finalize $release"
    exit 1
  fi
  features upgrade --release-version "$release" | tee -a "$LOG_FILE"
  log "升版後：$(features describe | awk '/confluent.metadata.version/{for(i=1;i<=NF;i++) if($i=="FinalizedVersionLevel:") print $(i+1)}')"
}

rollback() {
  local host=${1:?用法：rollback <主機> <版本>} version=${2:?用法：rollback <主機> <版本>}
  section "22.9 回滾 $host → $version（JDK 先切回最新的 jdk-21*）"
  if grep -q "CP-${version%.*}" <<<"$(features describe | grep confluent.metadata.version)"; then :; else
    warn "features 已經不是 ${version%.*}：finalize 之後 downgrade 不保證可行"
  fi
  ssh_run "$host" 'sudo ln -sfn "$(ls -d /opt/java/jdk-21* | sort -V | tail -1)" /opt/java/current && readlink /opt/java/current'
  change_packages_and_restart "$host" "$version" downgrade || die "$host 回滾失敗"
}

# c3 <版本>：只換 Control Center；比現在新就 install、比較舊就 downgrade
c3() {
  local target=${1:?用法：bash $0 c3 <版本>} installed action
  installed=$(ssh_run "$C3_HOST" "rpm -q --qf '%{VERSION}' confluent-control-center-next-gen")
  section "28 Control Center $installed → $target（$C3_HOST）"
  [ "$installed" = "$target" ] && { ok "已經是 $target"; return 0; }
  action=install; [ "$(printf '%s
' "$installed" "$target" | sort -V | tail -1)" = "$installed" ] && action=downgrade
  change_packages_and_restart "$C3_HOST" "$target" "$action" || die "C3 換版本失敗"
  [ "$target" = "$C3_VERSION" ] || warn "site.env 的 C3_VERSION 還是 $C3_VERSION：改成 $target，之後重跑其他站才一致"
}

case $ACTION in
  plan|backup) "$ACTION";;
  packages|jdk|finalize|rollback|c3) shift; "$ACTION" "$@";;
  *) sed -n '5,17p' "$0"; exit 1;;
esac
finish_step
