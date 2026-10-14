# shellcheck shell=bash
# shellcheck disable=SC2046  # host names from the inventory never contain whitespace
STEP_DESC="render and push configuration for every role (restart only what changed, rolling)"

step_inputs() {
  cat "$CONF_DIR/inventory.env" "$CONF_DIR/apps.env" "$CONF_DIR/versions.env"
  find "$CPCTL_HOME/templates" "$CPCTL_HOME/roles" -type f -exec cat {} + ; cat "$PKI_DIR"/*.crt 2>/dev/null || true
  [[ -f $CONF_DIR/license.txt ]] && cat "$CONF_DIR/license.txt"; return 0
}

step_apply() {
  local role
  for role in controller broker rest c3; do
    remote::parallel "role::$role::configure" $(inv::hosts "$role")
  done
  # handler notifications were written by parallel jobs; flush restarts running services only
}

step_verify() {
  local h
  for h in $(inv::hosts controller) $(inv::hosts broker); do
    remote::exec "$h" "sudo -n test -s /etc/confluent/kafka/server.properties" || return 1
  done
}
