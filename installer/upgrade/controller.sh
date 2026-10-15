#!/usr/bin/env bash
# cpctl controller <add|remove|replace> --host <kcNN> [--old <kcNN>]
# KRaft dynamic quorum (KIP-853) membership changes, one voter at a time, each behind a lag gate.
#   replace = remove the old voter -> format the new node as observer -> wait caught up -> add-controller
# After a replace, update HOSTS_controller in conf/inventory.env and run: cpctl step 05_configure
[[ -n ${_CONTROLLER_LOADED:-} ]] && return 0
_CONTROLLER_LOADED=1

ctl::quorum() { # describe --replication | --status
  kafka::admin kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_BOOTSTRAP" \
    --command-config "$(kafka::admin_config)" describe "$1" 2>/dev/null
}

ctl::is_voter() { ctl::quorum --replication | awk -v id="$1" '$1 == id && ($NF == "Leader" || $NF == "Follower") {f=1} END {exit f ? 0 : 1}'; }
ctl::not_voter() { ! ctl::is_voter "$1"; }
ctl::observer_caught_up() { ctl::quorum --replication | awk -v id="$1" '$1 == id && $NF == "Observer" && $4 + 0 == 0 {f=1} END {exit f ? 0 : 1}'; }
ctl::dir_id() { ctl::quorum --replication | awk -v id="$1" '$1 == id {print $2; exit}'; }

# Client properties on a controller node for running add-controller locally (reads node.id + meta.properties).
ctl::node_command_config() {
  local h=$1 t
  t=$(render::tmp)
  {
    remote::exec "$h" "sudo -n cat $KAFKA_CONF"
    printf '\nsecurity.protocol=SSL\n'
  } >"$t"
  remote::put "$h" "$t" /etc/confluent/kafka/add-controller.properties root confluent 0640
  rm -f "$t"
}

ctl::remove() { # <host>
  local h=$1 id dir
  id=$(inv::get "$h" NODE_ID)
  ctl::is_voter "$id" || { log::ok "[$h] node $id is not a voter"; return 0; }
  dir=$(ctl::dir_id "$id")
  log::changed "[$h] remove-controller id=$id dir=$dir"
  step::mutating || return 0
  kafka::admin kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$(kafka::admin_config)" \
    remove-controller --controller-id "$id" --controller-directory-id "$dir"
  health::wait 120 "node $id no longer a voter" ctl::not_voter "$id"
  role::controller::stop "$h"
}

ctl::add() { # <host>
  local h=$1 id
  id=$(inv::get "$h" NODE_ID)
  [[ -n $id ]] || core::die "inventory: HOST_${h}_NODE_ID missing"
  if ctl::is_voter "$id"; then log::ok "[$h] node $id already a voter"; return 0; fi
  # bring the node up as an observer of the existing quorum
  install::prepare "$h"
  install::ensure "$h" install "$(install::version "$(inv::hosts broker | head -1)")" controller
  remote::put "$h" "$PKI_DIR/ca.pem" /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem root root 0644
  remote::apply "$h" java_node::trust_ca "$(install::java_home)" /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem
  role::controller::configure "$h"
  : >"$(handler::_file)"
  core::load_env "$STATE_DIR/kraft.env"
  remote::apply "$h" kafka_node::format "$CLUSTER_ID" "$KAFKA_CONF" "$(install::java_home)" "$(install::bin_dir)" "$(install::kafka_etc)" --no-initial-controllers
  role::controller::start "$h"
  step::mutating || return 0
  health::wait 300 "[$h] observer caught up with the metadata log" ctl::observer_caught_up "$id"
  ctl::node_command_config "$h"
  log::changed "[$h] add-controller id=$id"
  # the copied config may contain ${securepass:...}: pass the master key from the root-only service.env
  remote::exec "$h" "sudo -n bash -c 'set -a; . /etc/confluent/kafka/service.env 2>/dev/null || true; set +a; \
    sudo -u cp-kafka --preserve-env=CONFLUENT_SECURITY_MASTER_KEY env JAVA_HOME=$(install::java_home) KAFKA_HEAP_OPTS=-Xmx256m \
    $(install::bin kafka-metadata-quorum) --command-config /etc/confluent/kafka/add-controller.properties \
    --bootstrap-controller $CONTROLLER_BOOTSTRAP add-controller'"
  health::wait 180 "[$h] node $id is a voter" ctl::is_voter "$id"
}

controller::main() {
  local sub=${1:-}; shift || true
  local host="" old=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --host) host=$2; shift 2 ;;
      --old) old=$2; shift 2 ;;
      *) core::die "$E_USAGE" "unknown option $1" ;;
    esac
  done
  [[ -n $host ]] || core::die "$E_USAGE" "--host is required"
  role::common_vars
  # Bootstrap list = current voters + the spare, so the new node can find the quorum
  CONTROLLER_BOOTSTRAP=$(inv::endpoints controller "$PORT_CONTROLLER")
  case $sub in
    add) ctl::add "$host" ;;
    remove) ctl::remove "$host" ;;
    replace)
      [[ -n $old ]] || core::die "$E_USAGE" "replace needs --old <host>"
      log::info "replacing controller $old with $host (one voter change at a time)"
      # add first, remove second: 4 voters for a moment (majority 3) instead of dropping to 2
      ctl::add "$host"
      ctl::remove "$old"
      log::info "done. Now set HOSTS_controller to include $host instead of $old in conf/inventory.env, then: cpctl step 05_configure"
      ;;
    *) core::die "$E_USAGE" "controller add|remove|replace" ;;
  esac
  ctl::quorum --replication >&2 || true
}
