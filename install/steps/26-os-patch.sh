#!/usr/bin/env bash
# 第 26 站：OS 修補 —— 一台一台 dnf update（Confluent 由 versionlock 擋住），該重開就重開、健康了才做下一台（手把手第 26 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；銀行每月發布 OS 修補之後執行）
#
# 用法：
#   bash steps/26-os-patch.sh plan          每台可更新幾個套件、有沒有 confluent-*（有就是 versionlock 沒鎖好，停下來）
#   bash steps/26-os-patch.sh apply         broker 逐台 → controller（leader 最後）→ REST → C3 → 操作機
#   ONLY_HOSTS="kb01" bash steps/26-os-patch.sh apply   只做列出的主機
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
sudo dnf -y -q update >/dev/null 2>&1 || { echo "result=failed"; exit 1; }
reboot=$(sudo dnf needs-restarting -r >/dev/null 2>&1 && echo no || echo yes)
services=$(sudo dnf needs-restarting -s 2>/dev/null | grep -oE 'confluent-[a-z-]+|prometheus|alertmanager' | sort -u | paste -sd' ' -)
echo "updated=$count reboot=$reboot services=${services:-none} confluent=$(rpm -qa 'confluent-*' --qf '%{VERSION}\n' | sort -u | paste -sd, -)"
EOF
)
PLAN_HOST=$(cat <<'EOF'
updates=$(sudo dnf -q check-update --refresh 2>/dev/null | awk '/^[a-zA-Z0-9]/{print $1}')
echo "$(grep -c . <<<"$updates") $(grep -c '^confluent-' <<<"$updates") $(sudo dnf -q versionlock list 2>/dev/null | grep -c confluent)"
EOF
)

quorum() { kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" --command-config "$INTERNAL_CLIENT_CONF" "$@" 2>/dev/null; }
under_replicated_count() { kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:; }
current_leader() { local leader_id host; leader_id=$(quorum describe --status | awk '/LeaderId/{print $2}'); for host in $CONTROLLERS; do [ "$(node_id_of "$host")" = "$leader_id" ] && echo "$host"; done; }

wait_healthy() {
  local host=$1 attempt lag
  case $host in
    kb*) for attempt in $(seq 1 90); do
           [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$(fqdn "$host"):8090/v1/metadata/id")" = 200 ] && [ "$(under_replicated_count)" = 0 ] && return 0; sleep 10
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
    ssh_run "$host" 'sudo systemctl reboot' || true
    sleep 30
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
  section "26.1 修補前：under-replicated、每台可更新的套件、versionlock"
  [ "$(under_replicated_count)" = 0 ] && ok "沒有 under-replicated" || fail "有 under-replicated：叢集不健康時不修補"
  for host in $CONTROLLERS $BROKERS $RESTS $C3_HOST $OPS_HOST; do
    if [ "$host" = "$OPS_HOST" ]; then counts=$(bash -s <<<"$PLAN_HOST"); else counts=$(ssh_script "$host" <<<"$PLAN_HOST"); fi
    read -r updates confluent_updates locked <<<"$counts"
    if [ "$confluent_updates" != 0 ]; then fail "$host：更新清單裡有 $confluent_updates 個 confluent 套件（versionlock 沒鎖好，照第 8 站重新鎖）"
    else ok "$host：可更新 $updates 個、鎖住 $locked 個 confluent 套件"; fi
  done
}

apply() {
  local host leader
  plan
  [ "$FAIL_COUNT" = 0 ] || die "修補前檢查沒過"
  section "26.2 broker 逐台"
  for host in $BROKERS; do selected "$host" && { patch_one "$host" || die "停在 $host"; }; done
  section "26.3 controller 逐台，leader 最後"
  leader=$(current_leader)
  for host in $(for h in $CONTROLLERS; do [ "$h" != "$leader" ] && echo "$h"; done) $leader; do
    selected "$host" && { patch_one "$host" || die "停在 $host"; }
  done
  section "26.4 REST Proxy、C3、操作機"
  for host in $RESTS $C3_HOST $OPS_HOST; do selected "$host" && { patch_one "$host" || die "停在 $host"; }; done
}

case $ACTION in
  plan)  plan; finish_step;;
  apply) apply; finish_step;;
  *) die "用法：bash $0 plan|apply";;
esac
