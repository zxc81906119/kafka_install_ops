#!/usr/bin/env bash
# Health gates used by start/rolling/upgrade flows.
[[ -n ${_LIB_HEALTH_LOADED:-} ]] && return 0
_LIB_HEALTH_LOADED=1

# health::wait <timeout seconds> <description> <command...>
health::wait() {
  local timeout=$1 desc=$2; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS - start >= timeout)); then
      log::error "timeout after ${timeout}s waiting for: $desc"
      return 1
    fi
    sleep 3
  done
  log::ok "$desc"
}

# health::tcp <host> <port>  (from the ops host)
health::tcp() { timeout 3 bash -c "exec 3<>/dev/tcp/$(inv::fqdn "$1")/$2" 2>/dev/null; }
