#!/usr/bin/env bash
# Single-operator lock: two people running cpctl at the same time on the ops host is refused.
[[ -n ${_LIB_LOCK_LOADED:-} ]] && return 0
_LIB_LOCK_LOADED=1

lock::acquire() {
  exec 9>"$STATE_DIR/cpctl.lock"
  flock -n 9 || core::die "another cpctl run holds $STATE_DIR/cpctl.lock (pid $(cat "$STATE_DIR/cpctl.pid" 2>/dev/null || echo ?))"
  printf '%s' "$$" >"$STATE_DIR/cpctl.pid"
}
