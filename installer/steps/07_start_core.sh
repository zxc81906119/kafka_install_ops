# shellcheck shell=bash
# shellcheck disable=SC2046  # host names from the inventory never contain whitespace
STEP_DESC="start KRaft controllers, then brokers; gate on quorum and broker registration"

step_apply() {
  role::common_vars
  remote::parallel role::controller::start $(inv::hosts controller)
  step::mutating || return 0
  local h
  for h in $(inv::hosts controller); do role::controller::health "$h"; done
  remote::parallel role::broker::start $(inv::hosts broker)
  for h in $(inv::hosts broker); do role::broker::health "$h"; done
}

step_verify() {
  role::common_vars
  local out
  out=$(kafka::admin kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_BOOTSTRAP" \
    --command-config "$(kafka::controller_config)" describe --status 2>/dev/null) || return 1
  grep -q 'LeaderId:' <<<"$out" || return 1
  local h
  for h in $(inv::hosts broker); do kafka::_broker_healthy "$h" || return 1; done
}
