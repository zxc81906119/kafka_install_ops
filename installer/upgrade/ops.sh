#!/usr/bin/env bash
# Day-2 operations
#   cpctl broker remove --host kbNN --yes   drain with Self-Balancing (kafka-remove-brokers), broker shuts down, stop it
#   cpctl broker add --host kbNN [--wipe]   install + configure + format + start a broker listed in HOSTS_broker;
#                                           Self-Balancing moves replicas onto the empty broker by itself
#   cpctl os patch [--role R|--host H] [--reboot] --yes
#                                           rolling OS patching: one host at a time behind the same health gates as a
#                                           rolling restart; Confluent / JDK stay put (versionlock)
#   cpctl health                            read-only health check with hints for the common failures
[[ -n ${_OPS_LOADED:-} ]] && return 0
_OPS_LOADED=1

ops::_admin() { kafka::admin "$@" --bootstrap-server "$(kafka::bootstrap_admin)" --command-config "$(kafka::admin_config)"; }

ops::_registered() { # <broker id> -> registered and not fenced
  [[ $(kafka::admin kafka-broker-api-versions --bootstrap-server "$(kafka::bootstrap_admin)" \
    --command-config "$(kafka::admin_config)" 2>/dev/null) == *"(id: $1 rack"*"isFenced: false"* ]]
}

ops::_replicas_on() { # <broker id> -> number of partition replicas the broker holds
  ops::_admin kafka-topics --describe 2>/dev/null |
    awk -v id="$1" '/Replicas:/ {for (i = 1; i <= NF; i++) if ($i == "Replicas:") {n = split($(i + 1), r, ","); for (j = 1; j <= n; j++) if (r[j] == id) c++}} END {print c + 0}'
}

ops::_empty() { [[ $(ops::_replicas_on "$1") == 0 ]]; }
ops::_not_empty() { (($(ops::_replicas_on "$1") > 0)); }
ops::_no_urp() { [[ $(ops::_urp) == 0 ]]; }
ops::_unreachable() { ! remote::reachable "$1"; }
ops::_urp() { ops::_admin kafka-topics --describe --under-replicated-partitions 2>/dev/null | grep -c 'Partition:' || true; }

ops::_sbc_enabled() { [[ $(ops::_admin kafka-rebalance-cluster --status 2>/dev/null) == *"Balancer status: ENABLED"* ]]; }

# ---- broker remove -----------------------------------------------------------------------------------------------
ops::broker_remove() {
  local host="" yes=0 id n left
  while [[ $# -gt 0 ]]; do
    case $1 in --host) host=$2; shift 2 ;; --yes) yes=1; shift ;; *) core::die "$E_USAGE" "unknown option $1" ;; esac
  done
  [[ -n $host && " $(inv::hosts broker | paste -sd' ' -) " == *" $host "* ]] || core::die "$E_USAGE" "usage: cpctl broker remove --host <broker in HOSTS_broker> --yes"
  id=$(inv::get "$host" NODE_ID)
  n=$(inv::hosts broker | wc -l)
  ((n - 1 >= 3)) || core::die "$E_GATE" "only $((n - 1)) brokers would remain - replication factor 3 needs at least 3"
  upgrade::_cluster_healthy || core::die "$E_GATE" "cluster not healthy (under-replicated partitions) - not removing a broker now"
  ops::_sbc_enabled || core::die "$E_GATE" "Self-Balancing is not running - kafka-remove-brokers needs it (cpctl health)"
  left=$(ops::_replicas_on "$id")
  log::info "[$host] broker $id holds $left partition replica(s); Self-Balancing moves them to the other brokers"
  ((yes)) || core::die "$E_USAGE" "re-run with --yes to drain and shut down broker $id ($host)"
  step::mutating || { log::changed "[$host] would remove broker $id"; return 0; }
  log::changed "[$host] kafka-remove-brokers --delete --broker-id $id"
  ops::_admin kafka-remove-brokers --delete --broker-id "$id" | sed 's/^/    /'
  health::wait 3600 "[$host] broker $id drained by Self-Balancing (0 replicas left)" ops::_empty "$id" ||
    core::die "$E_GATE" "[$host] replicas still on broker $id - see: kafka-remove-brokers --describe"
  health::wait 600 "[$host] removal complete (kafka-remove-brokers --describe)" ops::_removal_done "$id" ||
    core::die "$E_GATE" "[$host] removal not complete - see: kafka-remove-brokers --describe"
  ops::_admin kafka-remove-brokers --describe 2>/dev/null | awk -v id="$id" '/^Broker [0-9]+ removal status/ {on = ($2 == id)} on' | sed 's/^/    /' || true
  # the broker shut itself down; keep it down across reboots
  remote::apply "$host" svc::stop confluent-server
  remote::apply "$host" svc::disable confluent-server
  health::wait 300 "no under-replicated partitions" ops::_no_urp ||
    core::die "$E_GATE" "under-replicated partitions after removing broker $id"
  log::warn "next: take $host out of HOSTS_broker in conf/inventory.env and run 'cpctl install' (client bootstrap lists of REST Proxy, C3, the OP menu are re-rendered)"
}

ops::_removal_done() { # <broker id> -> "Broker <id> removal status - SUCCESS." and every sub-task COMPLETED
  local block
  block=$(ops::_admin kafka-remove-brokers --describe 2>/dev/null |
    awk -v id="$1" '/^Broker [0-9]+ removal status/ {on = ($2 == id)} on')
  [[ $block == *"removal status - SUCCESS"* && $block != *FAIL* && $(grep -c 'COMPLETED' <<<"$block") -ge 3 ]]
}

# ---- broker add --------------------------------------------------------------------------------------------------
ops::broker_add() {
  local host="" wipe=0 id meta
  while [[ $# -gt 0 ]]; do
    case $1 in --host) host=$2; shift 2 ;; --wipe) wipe=1; shift ;; *) core::die "$E_USAGE" "unknown option $1" ;; esac
  done
  [[ -n $host && " $(inv::hosts broker | paste -sd' ' -) " == *" $host "* ]] ||
    core::die "$E_USAGE" "usage: cpctl broker add --host <host> [--wipe]  (add the host to HOSTS_broker with HOST_<h>_NODE_ID / _RACK first)"
  id=$(inv::get "$host" NODE_ID)
  [[ -n $id && -n $(inv::get "$host" RACK) ]] || core::die "$E_USAGE" "HOST_$(core::varname "$host")_NODE_ID and _RACK must be set in conf/inventory.env"
  remote::reachable "$host" || core::die "$E_PRECHECK" "[$host] not reachable over ssh"
  if ops::_registered "$id"; then log::ok "[$host] broker $id is already part of the cluster"; return 0; fi
  # a previously removed broker still has its old log directory: the old replicas must not come back
  meta=$(remote::run "$host" kafka_node::meta cluster.id 2>/dev/null || true)
  if [[ -n $meta ]]; then
    ((wipe)) || core::die "$E_USAGE" "[$host] data directory is formatted (cluster $meta) - re-run with --wipe to empty it before re-adding"
    remote::apply "$host" svc::stop confluent-server
    remote::apply "$host" kafka_node::wipe
  fi
  remote::apply "$host" svc::enable confluent-server
  # the normal install converges this host (packages, OS, certificates, config, format, start) and leaves the
  # others untouched; certificate SANs: a NEW host name needs re-issued certificates first (cpctl certs rotate)
  log::step "==== installing broker $host (id $id)"
  step::run_all
  health::wait 300 "[$host] broker $id registered" ops::_registered "$id" || core::die "$E_GATE" "[$host] broker $id did not register"
  health::wait 1800 "[$host] Self-Balancing moved replicas onto broker $id" ops::_not_empty "$id" ||
    log::warn "[$host] still empty - check: kafka-rebalance-cluster --describe"
  health::wait 1800 "no under-replicated partitions" ops::_no_urp || core::die "$E_GATE" "under-replicated partitions after adding broker $id"
  log::ok "[$host] broker $id holds $(ops::_replicas_on "$id") replica(s)"
}

# ---- OS patching ---------------------------------------------------------------------------------------------------
# ops::_patch_order -> "host role" lines: brokers, controllers (followers, leader last), REST, C3
ops::_patch_order() {
  local h
  for h in $(inv::hosts broker); do printf '%s broker\n' "$h"; done
  for h in $(upgrade::_controller_order); do printf '%s controller\n' "$h"; done
  for h in $(inv::hosts rest); do printf '%s rest\n' "$h"; done
  for h in $(inv::hosts c3); do printf '%s c3\n' "$h"; done
}

ops::os_patch() {
  local only_role="" only_host="" reboot=0 yes=0 h role
  while [[ $# -gt 0 ]]; do
    case $1 in
      --role) only_role=$2; shift 2 ;;
      --host) only_host=$2; shift 2 ;;
      --reboot) reboot=1; shift ;;
      --yes) yes=1; shift ;;
      *) core::die "$E_USAGE" "unknown option $1" ;;
    esac
  done
  role::common_vars
  upgrade::_cluster_healthy || core::die "$E_GATE" "cluster not healthy - not starting rolling OS patching"
  while read -r h role; do
    [[ -n $only_role && $role != "$only_role" ]] && continue
    [[ -n $only_host && $h != "$only_host" ]] && continue
    log::step "---- [$h] $role: OS patching$( ((reboot)) && echo ' + reboot')"
    if ! step::mutating || ((!yes)); then
      CPCTL_CHECK=1 remote::apply "$h" sys_node::os_update     # dry run: only lists what would be updated
      log::info "[$h] dry run - nothing changed (add --yes to patch)"
      continue
    fi
    [[ $role == rest ]] && lb::drain "$h"
    role::call "$role" stop "$h"
    remote::apply "$h" sys_node::os_update
    if ((reboot)); then
      remote::apply "$h" sys_node::reboot
      if ! remote::run "$h" node::in_container >/dev/null 2>&1; then
        health::wait 120 "[$h] going down" ops::_unreachable "$h" || true
        health::wait 900 "[$h] back after reboot" remote::reachable "$h" || core::die "$E_GATE" "[$h] did not come back after reboot"
      fi
    fi
    role::call "$role" start "$h"
    role::call "$role" health "$h" || core::die "$E_GATE" "[$h] $role failed its health gate after patching - stop here"
    [[ $role == rest ]] && lb::undrain
  done < <(ops::_patch_order)
  log::info "not patched by this command: the ops host itself, the load balancer, AD, the bastion - patch them in their own window"
}

# ---- health check (read-only) --------------------------------------------------------------------------------------
readonly HEALTH_DISK_WARN=${HEALTH_DISK_WARN:-75} HEALTH_DISK_CRIT=${HEALTH_DISK_CRIT:-85}
HEALTH_RC=0
ops::_warn() { log::warn "$*"; ((HEALTH_RC == 0)) && HEALTH_RC=2; return 0; }   # a critical (1) is never downgraded
ops::_crit() { log::error "$*"; HEALTH_RC=1; return 0; }

# ops::_hint <journal text> -> the usual cause of a service that does not start
ops::_hint() {
  case $1 in
    *"No space left on device"*) echo "disk full: free space in the data / log directory (cpctl health: disk)" ;;
    *"Address already in use"*) echo "port taken by another process: ss -ltnp | grep <port>" ;;
    *"keystore password was incorrect"* | *"Keystore was tampered"*) echo "keystore password does not match the .p12 (STORE_PASSWORD / Secret Protection master key)" ;;
    *"PKIX path"* | *"certificate_unknown"* | *"SSLHandshakeException"*) echo "TLS trust: the peer's certificate does not chain to truststore.p12 (CA rotation step skipped?)" ;;
    *"Invalid cluster.id"* | *"meta.properties"*) echo "data directory formatted for another cluster: kafka-storage info -c <config>" ;;
    *"securepass"* | *"master key"* | *"CONFLUENT_SECURITY_MASTER_KEY"*) echo "Secret Protection: master key missing in /etc/confluent/kafka/service.env" ;;
    *"LoginException"* | *"retrieving token"*) echo "MDS token: the brokers' MDS was not ready when this service started - restart it" ;;
    *"Connection refused"*"636"* | *"LDAP"*"timed out"*) echo "AD / LDAPS not reachable from this host (port 636, CA of the AD certificate)" ;;
    *"OutOfMemoryError"*) echo "heap too small (HEAP_<profile>_<role> in conf/inventory.env)" ;;
    *) echo "see: journalctl -u <unit> -n 200" ;;
  esac
}

ops::_unit_check() { # <host> <unit>
  local st j
  st=$(remote::run "$1" svc::status_line "$2" 2>/dev/null | awk '{print $2}')
  if [[ $st == active ]]; then log::ok "[$1] $2 active"; return 0; fi
  j=$(remote::run "$1" svc::journal "$2" 80 2>/dev/null || true)
  ops::_crit "[$1] $2 ${st:-unknown} - likely cause: $(ops::_hint "$j")"
  grep -iE 'error|exception|fail' <<<"$j" | tail -3 | sed 's/^/      /' || true
}

ops::health() {
  local h u d used mnt out
  role::common_vars
  HEALTH_RC=0
  log::step "---- services"
  for h in $(inv::hosts controller) $(inv::hosts broker); do ops::_unit_check "$h" confluent-server; done
  for h in $(inv::hosts rest); do ops::_unit_check "$h" confluent-kafka-rest; done
  for h in $(inv::hosts c3); do for u in prometheus alertmanager confluent-control-center; do ops::_unit_check "$h" "$u"; done; done

  log::step "---- disk (warn ${HEALTH_DISK_WARN}%, critical ${HEALTH_DISK_CRIT}%)"
  for h in $(inv::hosts controller) $(inv::hosts broker); do
    for d in /var/lib/kafka/data /var/log/kafka; do
      read -r used _ mnt <<<"$(remote::run "$h" sys_node::disk "$d" 2>/dev/null)" || true
      if [[ -z ${used:-} ]]; then ops::_warn "[$h] $d: no df output"
      elif ((used >= HEALTH_DISK_CRIT)); then ops::_crit "[$h] $d ${used}% used (mount $mnt) - free space or extend before the broker stops"
      elif ((used >= HEALTH_DISK_WARN)); then ops::_warn "[$h] $d ${used}% used (mount $mnt)"
      else log::ok "[$h] $d ${used}% used"; fi
    done
  done

  log::step "---- KRaft quorum"
  out=$(kafka::admin kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$(kafka::controller_config)" describe --replication 2>/dev/null) ||
    ops::_crit "quorum not reachable at $CONTROLLER_BOOTSTRAP"
  if [[ -n $out ]]; then
    awk 'NR > 1 {printf "    node %-4s %-9s lag %s\n", $1, $NF, $4}' <<<"$out"
    [[ $out == *Leader* ]] || ops::_crit "no quorum leader"
    awk 'NR > 1 && $NF != "Observer" && $4 + 0 > 1000 {bad = 1} END {exit !bad}' <<<"$out" && ops::_warn "a voter lags more than 1000 records"
  fi

  log::step "---- partitions"
  local n
  n=$(ops::_admin kafka-topics --describe --unavailable-partitions 2>/dev/null | grep -c 'Partition:' || true)
  ((n == 0)) && log::ok "no offline partitions" || ops::_crit "$n offline partition(s): kafka-topics --describe --unavailable-partitions"
  n=$(ops::_admin kafka-topics --describe --under-min-isr-partitions 2>/dev/null | grep -c 'Partition:' || true)
  ((n == 0)) && log::ok "no partition below min.insync.replicas" || ops::_crit "$n partition(s) below min ISR: producers with acks=all fail"
  n=$(ops::_urp)
  ((n == 0)) && log::ok "no under-replicated partitions" || ops::_warn "$n under-replicated partition(s) (a broker down or slow?)"
  ops::_sbc_enabled && log::ok "Self-Balancing running" || ops::_warn "Self-Balancing not running (controllers need inter.broker.listener.name=INTERNAL)"

  log::step "---- AD / MDS"
  local mds
  mds="https://$(inv::fqdn "$(inv::hosts broker | head -1)"):$PORT_MDS/security/1.0/authenticate"
  if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$PKI_DIR/ca.pem" \
    --cert "$PKI_DIR/svc-cpctl.crt" --key "$PKI_DIR/svc-cpctl.key" "$mds") == 200 ]]; then
    log::ok "MDS issues a token to the svc-cpctl certificate (MDS up)"
  else
    ops::_crit "MDS refuses the svc-cpctl certificate - check MDS (broker 8090) and the certificate (cpctl certs status)"
  fi
  # people log in with AD: the bind account must work (a human login fails with 401 when AD / LDAPS / svc-mds-bind is broken)
  if remote::exec "$(inv::hosts broker | head -1)" "timeout 5 bash -c '</dev/tcp/$(inv::fqdn "$AD_HOST")/636'" 2>/dev/null; then
    log::ok "AD (LDAPS 636) reachable from the brokers"
  else
    ops::_crit "AD LDAPS 636 not reachable from the brokers - people cannot log in"
  fi

  log::step "---- REST Proxy / Control Center"
  for h in $(inv::hosts rest); do role::rest::health "$h" >/dev/null 2>&1 && log::ok "[$h] REST Proxy answers" || ops::_crit "[$h] REST Proxy does not answer"; done
  for h in $(inv::hosts c3); do role::c3::health "$h" >/dev/null 2>&1 && log::ok "[$h] Control Center answers" || ops::_crit "[$h] Control Center does not answer (after a cold start: restart it once MDS is up)"; done

  log::step "---- certificates"
  pki::status || ops::_warn "certificate attention needed (see above)"
  certs::served || ops::_warn "a service presents a certificate that is not the current one"

  log::step "---- license"
  license::status >/dev/null 2>&1 || ops::_warn "license: see cpctl license status"
  return "$HEALTH_RC"
}

ops::main() {
  local group=${1:-} sub=${2:-}
  shift 2 || true
  case "$group $sub" in
    "broker remove") ops::broker_remove "$@" ;;
    "broker add") ops::broker_add "$@" ;;
    "os patch") ops::os_patch "$@" ;;
    "health "*) ops::health ;;
    *) core::die "$E_USAGE" "usage: cpctl broker add|remove --host H | cpctl os patch [--role R|--host H] [--reboot] [--yes] | cpctl health" ;;
  esac
}
