#!/usr/bin/env bash
# Logging + Ansible-style recap. Counters live in files so subshells and parallel jobs can update them.
[[ -n ${_LIB_LOG_LOADED:-} ]] && return 0
_LIB_LOG_LOADED=1

log::_file() { printf '%s/%s.log' "$LOG_DIR" "$CPCTL_RUN_ID"; }
log::_counter() { printf '%s/%s.%s' "$RUN_DIR" "$CPCTL_RUN_ID" "$1"; }

log::_emit() { # level color message
  local level=$1 color=$2; shift 2
  local ts line
  ts=$(date '+%H:%M:%S')
  line=$(printf '[%s] %-7s %s' "$ts" "$level" "$*")
  printf '\033[%sm%s\033[0m\n' "$color" "$line" >&2
  [[ -d $LOG_DIR ]] && printf '%s\n' "$line" >>"$(log::_file)"
  return 0
}

log::_count() { [[ -d $RUN_DIR ]] && printf '.' >>"$(log::_counter "$1")"; return 0; }

log::info() { log::_emit INFO '0;37' "$@"; }
log::step() { log::_emit STEP '1;36' "$@"; }
log::warn() { log::_emit WARN '1;33' "$@"; log::_count warn; }
log::error() { log::_emit ERROR '1;31' "$@"; log::_count failed; }
log::ok() { log::_emit OK '0;32' "$@"; log::_count ok; }
log::changed() {
  if core::is_check_mode; then log::_emit WOULD '1;35' "$@"; else log::_emit CHANGED '1;33' "$@"; fi
  log::_count changed
}
log::skipped() { log::_emit SKIP '0;90' "$@"; log::_count skipped; }

log::count_of() { local f; f=$(log::_counter "$1"); [[ -f $f ]] && wc -c <"$f" | tr -d ' ' || echo 0; }

log::recap() {
  local ok changed skipped warn failed
  ok=$(log::count_of ok); changed=$(log::count_of changed); skipped=$(log::count_of skipped)
  warn=$(log::count_of warn); failed=$(log::count_of failed)
  printf '\n\033[1mRECAP\033[0m run=%s  ok=%s  changed=%s  skipped=%s  warn=%s  failed=%s%s\n' \
    "$CPCTL_RUN_ID" "$ok" "$changed" "$skipped" "$warn" "$failed" "$(core::is_check_mode && echo '  (check mode)')" >&2
  printf 'log: %s\n' "$(log::_file)" >&2
}

# Parse marker lines produced by remote ensure::* helpers:
#   ::ok:: msg | ::changed:: msg | ::skipped:: msg | ::warn:: msg
# Everything else is passed through as info. Returns 0; sets LOG_LAST_CHANGED=1 if any change was seen.
LOG_LAST_CHANGED=0
log::consume() {
  local prefix=$1 line
  LOG_LAST_CHANGED=0
  while IFS= read -r line; do
    case $line in
      ::ok::*) log::ok "$prefix ${line#::ok:: }" ;;
      ::changed::*) log::changed "$prefix ${line#::changed:: }"; LOG_LAST_CHANGED=1 ;;
      ::skipped::*) log::skipped "$prefix ${line#::skipped:: }" ;;
      ::warn::*) log::warn "$prefix ${line#::warn:: }" ;;
      *) [[ -n $line ]] && log::info "$prefix $line" ;;
    esac
  done
  return 0
}
