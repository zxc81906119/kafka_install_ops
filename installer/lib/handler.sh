#!/usr/bin/env bash
# Observer-style change handlers: steps notify "restart <role> on <host>" only when something changed;
# handler::flush performs the restarts afterwards, one host at a time, each behind a health gate.
[[ -n ${_LIB_HANDLER_LOADED:-} ]] && return 0
_LIB_HANDLER_LOADED=1

# Persistent across runs: a run that fails before flushing must not lose pending restarts.
handler::_file() { printf '%s/handlers.pending' "$STATE_DIR"; }

# handler::notify <role> <host>
handler::notify() {
  local f
  f=$(handler::_file)
  grep -qxF "$1 $2" "$f" 2>/dev/null || printf '%s %s\n' "$1" "$2" >>"$f"
}

# handler::flush [role...]   Restart order follows the given roles (default: safe cluster order).
handler::flush() {
  local f roles=("$@") role host
  f=$(handler::_file)
  [[ -s $f ]] || return 0
  # parallel configure jobs ran in subshells: make sure gate variables (bootstrap lists...) exist here
  role::common_vars
  [[ ${#roles[@]} -gt 0 ]] || roles=(controller broker rest c3 lb)
  for role in "${roles[@]}"; do
    while IFS= read -r host; do
      grep -qxF "$role $host" "$f" || continue
      if declare -F "role::$role::running" >/dev/null && ! "role::$role::running" "$host"; then
        log::skipped "[$host] $role not running yet - new configuration applies at first start"
      elif core::is_check_mode; then
        log::changed "[$host] would restart $role"
      else
        log::info "[$host] restarting $role (configuration changed)"
        role::call "$role" restart "$host"
        role::call "$role" health "$host" || core::die "$E_GATE" "[$host] $role failed its health gate after restart"
      fi
      sed -i "\|^$role $host\$|d" "$f"
    done < <(inv::hosts "$role")
  done
}
