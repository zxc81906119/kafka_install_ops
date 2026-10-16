# shellcheck shell=bash
STEP_DESC="OP menu on the bastion: fixed accounts (identity = own AD login via MDS), node access account, break-glass RBAC"

step_inputs() {
  printf '%s\n' "${OPMENU:-off}" "${OPMENU_VERSION:-}" "${OPMENU_OS_USER:-}" "${OPMENU_NODE_USER:-}" \
    "${OPMENU_TICKET_MODE:-}" "${OPMENU_CHANGE_WINDOW:-}" "$PROFILE"
  inv::hosts jump; jump::node_hosts
  find "$CPCTL_HOME/templates/default/opmenu" -type f -exec cat {} +
  cat "$PKI_DIR/ca.pem" "$PKI_DIR/${OPMENU_BREAKGLASS:-none}.crt" 2>/dev/null || true
}

step_apply() {
  jump::enabled || { log::skipped "OP menu disabled (OPMENU=off or no jump host in the inventory)"; return 0; }
  local j h keys
  for j in $(inv::hosts jump); do role::jump::configure "$j"; done
  if ! step::mutating; then
    log::info "check mode: node access accounts are compared once the bastion key exists"
    return 0
  fi
  keys=$(jump::authorized_keys)
  for h in $(jump::node_hosts); do role::jump::node_access "$h" "$keys"; done
  # break-glass identity: RBAC SystemAdmin (not a super user: auditable, revocable with one binding)
  rbac::login
  rbac::ensure "User:$OPMENU_BREAKGLASS" SystemAdmin
}

step_verify() {
  jump::enabled || return 0
  local j
  for j in $(inv::hosts jump); do
    remote::exec "$j" "test -x /opt/opmenu/opmenu.sh && sudo -n -u $OPMENU_OS_USER /opt/opmenu/opmenu.sh --list >/dev/null" || return 1
  done
}
