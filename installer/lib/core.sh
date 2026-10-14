#!/usr/bin/env bash
# Core: strict mode, error trap with stack trace, paths, small utilities.
[[ -n ${_LIB_CORE_LOADED:-} ]] && return 0
_LIB_CORE_LOADED=1

set -Eeuo pipefail
# Default IFS on purpose: inventory lists (APPS, PKGS_*, SYSCTL_*) are space separated.
umask 027

readonly CPCTL_HOME="${CPCTL_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly CONF_DIR="${CPCTL_CONF_DIR:-$CPCTL_HOME/conf}"
readonly STATE_DIR="${CPCTL_STATE_DIR:-/var/lib/cp-installer}"
readonly PKI_DIR="$STATE_DIR/pki"
readonly STAMP_DIR="$STATE_DIR/stamps"
readonly LOG_DIR="$STATE_DIR/logs"
readonly RUN_DIR="$STATE_DIR/run"

# Exit codes
readonly E_USAGE=2
readonly E_PRECHECK=3
readonly E_GATE=4

# Execution modes (exported so remote helpers and subshells see them)
export CPCTL_CHECK="${CPCTL_CHECK:-0}"   # 1 = dry run: report what would change, change nothing
export CPCTL_FORCE="${CPCTL_FORCE:-0}"   # 1 = ignore step stamps
export CPCTL_RUN_ID="${CPCTL_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"

core::on_error() {
  local rc=$? cmd=$BASH_COMMAND i
  # E_USAGE / E_PRECHECK / E_GATE were raised by core::die, which already printed the reason
  [[ $rc == "$E_USAGE" || $rc == "$E_PRECHECK" || $rc == "$E_GATE" ]] && exit "$rc"
  printf '\033[1;31m[FAILED]\033[0m rc=%s cmd: %s\n' "$rc" "$cmd" >&2
  for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
    printf '    at %s (%s:%s)\n' "${FUNCNAME[$i]}" "${BASH_SOURCE[$i]:-?}" "${BASH_LINENO[$((i - 1))]}" >&2
  done
  exit "$rc"
}
trap core::on_error ERR

core::die() {
  local rc=1
  [[ $1 =~ ^[0-9]+$ ]] && { rc=$1; shift; }
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit "$rc"
}

core::require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || core::die "$E_PRECHECK" "required command not found: $c"; done
}

core::is_check_mode() { [[ $CPCTL_CHECK == 1 ]]; }

# Join remaining args with $1 as separator.
core::join() { local IFS="$1"; shift; printf '%s' "$*"; }

# Convert "c3-01" -> "c3_01" for variable names.
core::varname() { printf '%s' "${1//[-.]/_}"; }

# Load a KEY=VALUE env file into the current shell.
core::load_env() {
  local f=$1
  [[ -f $f ]] || core::die "$E_PRECHECK" "missing config file: $f"
  set -a
  # shellcheck source=/dev/null
  source "$f"
  set +a
}

core::sha256() { sha256sum "$1" | awk '{print $1}'; }

core::init_dirs() {
  mkdir -p "$STATE_DIR" "$PKI_DIR" "$STAMP_DIR" "$LOG_DIR" "$RUN_DIR"
  chmod 0700 "$PKI_DIR"
}
