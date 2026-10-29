#!/usr/bin/env bash
# 第 30 站：OS 修補與小版本更新 —— 一台一台 dnf update（Confluent 由 versionlock 擋住），該重開就重開、健康了才做下一台（手把手第 30 章）
# where: ops02 （root）
# run: on-demand（遷移主線的最後一段，不在 install.sh 的安裝順序裡；直接執行這支）；之後銀行每月發布 OS 修補時也是這支
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
selected() { [ -z "$ONLY_HOSTS" ] || [[ " $ONLY_HOSTS " == *" $1 "* ]]; }

PATCH_HOST=$(cat <<'EOF'
count=$(sudo dnf -q check-update --refresh 2>/dev/null | grep -c '^[a-zA-Z0-9]')
os_before=$(. /etc/os-release; echo "$VERSION_ID")
sudo dnf -y -q update >/dev/null 2>&1 || { echo "result=failed"; exit 1; }
# Rocky 專屬：rocky-repos 更新會把預設 repo 檔（外網 mirrorlist）裝回來並啟用，離線的 lab 要再關掉；RHEL 不需要
sudo sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/rocky*.repo 2>/dev/null
reboot=$(sudo dnf needs-restarting -r >/dev/null 2>&1 && echo no || echo yes)
services=$(sudo dnf needs-restarting -s 2>/dev/null | grep -oE 'confluent-[a-z-]+|prometheus|alertmanager' | sort -u | paste -sd, -)
echo "updated=$count reboot=$reboot services=${services:-none} confluent=$(rpm -qa 'confluent-*' --qf '%{VERSION}\n' | sort -u | paste -sd, -) os=$os_before>$(. /etc/os-release; echo "$VERSION_ID")"
EOF
)
# 每台一行：OS 版本、versionlock 的 confluent 套件數、已裝的 confluent 套件數、服務狀態（UNIT 空 = 不查）
VERIFY_HOST=$(cat <<'EOF'
echo "$(. /etc/os-release; echo "$VERSION_ID") $(sudo dnf -q versionlock list 2>/dev/null | grep -c confluent) $(rpm -qa 'confluent-*' | wc -l) $([ -n "$UNIT" ] && systemctl is-active "$UNIT")"
EOF
)
PLAN_HOST=$(cat <<'EOF'
updates=$(sudo dnf -q check-update --refresh 2>/dev/null | awk '/^[a-zA-Z0-9]/{print $1}')
os_package=$(rpm -q --whatprovides system-release --qf '%{NAME}\n' | head -1)
os_available=$(sudo dnf -q repoquery --latest-limit 1 --qf '%{version}' "$os_package" 2>/dev/null | head -1)
echo "$(grep -c . <<<"$updates") $(grep -c '^confluent-' <<<"$updates") $(sudo dnf -q versionlock list 2>/dev/null | grep -c confluent) $(. /etc/os-release; echo "$VERSION_ID") ${os_available:-?}"
EOF
)

quorum() { kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" --command-config "$INTERNAL_CLIENT_CONF" "$@" 2>/dev/null; }
under_replicated_count() { kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:; }
current_leader() { local leader_id host; leader_id=$(quorum describe --status | awk '/LeaderId/{print $2}'); for host in $CONTROLLERS; do [ "$(node_id_of "$host")" = "$leader_id" ] && echo "$host"; done; }

wait_healthy() {
  local host=$1 attempt lag
  case $host in
    kb*) for attempt in $(seq 1 90); do
           [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$(fqdn "$host"):8090/v1/metadata/id")" = 200 ] && [ "$(under_replicated_count)" = 0 ] && { wait_mds_writer; return; }; sleep 10
         done;;
    kc*) for attempt in $(seq 1 90); do
           lag=$(quorum describe --replication | awk -v id="$(node_id_of "$host")" '$1 == id {print $4}'); [ "$lag" = 0 ] && return 0; sleep 5
         done;;
    rest*) retry 60 5 rest_app_curl -s -o /dev/null -f -m 5 "https://$(fqdn "$host"):8082/v3/clusters" && return 0;;
    c3*) retry 60 10 curl -s -o /dev/null -f -m 5 "https://$C3_FQDN:9021/" && return 0;;
    *) return 0;;
  esac
  return 1
}

# patch_one <主機>：修補、照 needs-restarting 的判斷重開機或重啟、等健康
patch_one() {
  local host=$1 result unit
  if [ "$host" = "$OPS_HOST" ]; then result=$(bash -s <<<"$PATCH_HOST"); else result=$(ssh_script "$host" <<<"$PATCH_HOST"); fi
  [[ $result == updated=* ]] || { fail "$host dnf update 失敗"; return 1; }
  log "$host：$result"
  local drained=0
  if [[ $host == rest* ]] && { [[ $result == *reboot=yes* ]] || ! [[ $result == *services=none* ]]; }; then
    lb_member "$host" down && lb_drained "$host" || return 1; drained=1   # 手把手 12.1
  fi
  if [[ $result == *reboot=yes* ]]; then
    [ "$host" = "$OPS_HOST" ] && { warn "操作機自己要重開機：其他主機都做完了，請手動 sudo systemctl reboot"; return 0; }
    local reboot_mode=${OS_REBOOT:-auto}
    if [ "$reboot_mode" = auto ]; then
      if ssh_run "$host" 'systemd-detect-virt -cq'; then reboot_mode=restart-services; else reboot_mode=reboot; fi
    fi
    if [ "$reboot_mode" = restart-services ]; then
      # lab：容器共用 WSL2 的核心，kernel／systemd 沒有真的換；重啟平台服務讓 JVM 載入新的 glibc，是「該重開機」的最接近做法
      warn "$host：要重開機，但這台是容器（或 OS_REBOOT=restart-services）：改重啟平台服務"
      case $host in c3*) ssh_run "$host" 'sudo systemctl restart prometheus alertmanager confluent-control-center';; *) ssh_run "$host" "sudo systemctl restart $(unit_of "$host")";; esac
    else
      ssh_run "$host" 'sudo systemctl reboot' || true
      sleep 30
    fi
  else
    for unit in $(sed -n 's/.*services=\([^ ]*\).*/\1/p' <<<"$result" | tr ',' ' '); do
      [ "$unit" = none ] && continue
      ssh_run "$host" "sudo systemctl restart $unit" && log "$host：重啟 $unit"
    done
  fi
  if wait_healthy "$host"; then ok "$host 健康"; else fail "$host 修補後沒有恢復健康"; return 1; fi
  [ "$drained" = 1 ] && { lb_member "$host" up || return 1; }
  return 0
}

plan() {
  local host counts
  section "30.1 修補前：under-replicated、每台可更新的套件、versionlock"
  # 剛做完 24 站（kb04 的 replica 還在追上）之類的操作，叢集要幾十秒才穩：最多等 5 分鐘，還不是 0 才算不健康
  wait_no_under_replicated() { local i; for i in $(seq 1 30); do [ "$(under_replicated_count)" = 0 ] && return 0; sleep 10; done; return 1; }
  if wait_no_under_replicated; then ok "沒有 under-replicated"; else fail "有 under-replicated（等了 5 分鐘還是有）：叢集不健康時不修補"; fi
  for host in $CONTROLLERS $BROKERS $RESTS $C3_HOST $OPS_HOST; do
    if [ "$host" = "$OPS_HOST" ]; then counts=$(bash -s <<<"$PLAN_HOST"); else counts=$(ssh_script "$host" <<<"$PLAN_HOST"); fi
    read -r updates confluent_updates locked os_current os_available <<<"$counts"
    if [ "$confluent_updates" != 0 ]; then fail "$host：更新清單裡有 $confluent_updates 個 confluent 套件（versionlock 沒鎖好，照第 8 站重新鎖）"
    elif [ "$os_available" != "?" ] && [ "${os_available%%.*}" != "${os_current%%.*}" ]; then fail "$host：套件庫是 ${os_available%%.*}.x 的內容，不是 ${os_current%%.*}.x（小版本更新只能在同一主版本內；請 OS 團隊修套件庫，問題清單 3.6）"
    else ok "$host：OS $os_current（套件庫的 release 套件 $os_available，主版本一致）、可更新 $updates 個、鎖住 $locked 個 confluent 套件"; fi
  done
}

apply() {
  local host leader
  plan
  [ "$FAIL_COUNT" = 0 ] || die "修補前檢查沒過"
  section "30.2 broker 逐台"
  for host in $BROKERS; do selected "$host" && { patch_one "$host" || die "停在 $host"; }; done
  section "30.3 controller 逐台，leader 最後"
  leader=$(current_leader)
  for host in $(for h in $CONTROLLERS; do [ "$h" != "$leader" ] && echo "$h"; done) $leader; do
    selected "$host" && { patch_one "$host" || die "停在 $host"; }
  done
  section "30.4 REST Proxy、C3、操作機"
  for host in $RESTS $C3_HOST $OPS_HOST; do selected "$host" && { patch_one "$host" || die "停在 $host"; }; done
}

# verify [版本]：30.5 驗證。給了版本（例如 9.8）每台的 OS 版本都要相同；versionlock 數量等於已裝的 confluent 套件數；服務 active；叢集與入口都健康
verify() {
  local expected_os=${1:-} host result unit locked installed active os_version rest_code c3_code
  section "30.5 驗證：OS 版本、versionlock、服務、叢集"
  for host in $CONTROLLERS $BROKERS $RESTS $C3_HOST $OPS_HOST; do
    unit=$(unit_of "$host"); [ "$host" = "$OPS_HOST" ] && unit=""
    if [ "$host" = "$OPS_HOST" ]; then result=$(UNIT="" bash -s <<<"$VERIFY_HOST"); else result=$(ssh_script "$host" UNIT="$unit" <<<"$VERIFY_HOST"); fi
    read -r os_version locked installed active <<<"$result"
    if [ -n "$expected_os" ] && [ "$os_version" != "$expected_os" ]; then fail "$host：OS $os_version（應為 $expected_os）"
    elif [ "$locked" != "$installed" ]; then fail "$host：versionlock $locked 個、已裝 confluent 套件 $installed 個"
    elif [ -n "$unit" ] && [ "$active" != active ]; then fail "$host：$unit $active"
    else ok "$host：OS $os_version、鎖 $locked／裝 $installed、${unit:-（無服務）} ${active:-}"; fi
  done
  if [ "$(under_replicated_count)" = 0 ]; then ok "under-replicated=0"; else fail "有 under-replicated"; fi
  rest_code=$(rest_app_curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters")
  c3_code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$C3_FQDN:9021/")
  if [ "$rest_code" = 200 ]; then ok "REST 經 LB（$REST_VIP）200"; else fail "REST 經 LB $rest_code"; fi
  if [ "$c3_code" = 200 ]; then ok "C3 200"; else fail "C3 $c3_code"; fi
}

case $ACTION in
  plan)  plan; finish_step;;
  apply) apply; finish_step;;
  verify) shift; verify "$@"; finish_step;;
  *) die "用法：bash $0 plan|apply|verify [版本]";;
esac
