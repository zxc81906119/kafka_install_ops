#!/usr/bin/env bash
# Facade over SSH/SCP: every remote action in cpctl goes through these functions.
# Changing jump hosts, SSH options or the transport (e.g. a bank's PAM gateway) only touches this file.
[[ -n ${_LIB_REMOTE_LOADED:-} ]] && return 0
_LIB_REMOTE_LOADED=1

REMOTE_SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8
  -o ServerAliveInterval=15 -o LogLevel=ERROR)
REMOTE_RETRIES=${REMOTE_RETRIES:-3}

remote::_target() { printf '%s@%s' "$SSH_USER" "$(inv::fqdn "$1")"; }

# Node-side function bundle: shipped on stdin with every remote::run call (no agent to install).
remote::_bundle() {
  local f
  for f in "$CPCTL_HOME"/lib/node/*.sh "$CPCTL_HOME"/lib/install/*.node.sh; do
    [[ -f $f ]] && cat "$f" && printf '\n'
  done
}

# remote::exec <host> <command string>   (runs as SSH_USER, retries on SSH transport errors only)
remote::exec() {
  local host=$1; shift
  local attempt=1 rc
  while :; do
    rc=0
    ssh "${REMOTE_SSH_OPTS[@]}" "$(remote::_target "$host")" "$*" || rc=$?
    # 255 = ssh transport error -> retry with backoff; anything else is the command's own exit code
    if [[ $rc -ne 255 || $attempt -ge $REMOTE_RETRIES ]]; then return "$rc"; fi
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

# remote::run <host> [--user U] <function> [args...]
# Runs a node-side bundle function as root (default) or as another user via sudo.
#   SUDO_MODE=full        the function bundle travels on stdin to "sudo bash -s" (no agent to install)
#   SUDO_MODE=restricted  the installed cpnode agent runs it ("sudo cpnode", no arguments; the call travels on stdin
#                         NUL separated, so nothing - no password - appears on a command line or in sudo's log)
remote::run() {
  local host=$1; shift
  local as=root
  if [[ ${1:-} == --user ]]; then as=$2; shift 2; fi
  if remote::restricted; then
    [[ $as == root ]] || core::die "$E_USAGE" "SUDO_MODE=restricted: running node functions as '$as' is not supported"
    remote::_agent_ok "$host"
    remote::_retry_ssh "$host" "sudo -n $AGENT_PATH" < <(printf '%s\0' "$CPCTL_CHECK" "${CPCTL_DIFF:-0}" "$@")
    return
  fi
  local call
  call=$(printf '%q ' "$@")
  local script
  script=$(
    printf 'set -Eeuo pipefail\nexport CPCTL_CHECK=%q CPCTL_DIFF=%q\n' "$CPCTL_CHECK" "${CPCTL_DIFF:-0}"
    remote::_bundle
    printf '%s\n' "$call"
  )
  remote::_retry_ssh "$host" "sudo -n -u $as bash -s" <<<"$script"
}

# remote::_retry_ssh <host> <remote command>   (stdin is passed on; it is buffered so a retry can resend it)
remote::_retry_ssh() {
  local host=$1 cmd=$2 input attempt=1 rc
  input=$(mktemp)
  cat >"$input"
  while :; do
    rc=0
    ssh "${REMOTE_SSH_OPTS[@]}" "$(remote::_target "$host")" "$cmd" <"$input" || rc=$?
    if [[ $rc -ne 255 || $attempt -ge $REMOTE_RETRIES ]]; then rm -f "$input"; return "$rc"; fi
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

remote::restricted() { [[ ${SUDO_MODE:-full} == restricted && ${CPCTL_SUDO_FULL:-0} != 1 ]]; }

# remote::_agent_ok <host> -> the installed agent is the version this cpctl was built for (checked once per run)
remote::_agent_ok() {
  local mark="$RUN_DIR/$CPCTL_RUN_ID.agent.$1" have want
  [[ -f $mark ]] && return 0
  want=$(agent::version)
  have=$(printf '%s\0' 0 0 --version | ssh "${REMOTE_SSH_OPTS[@]}" "$(remote::_target "$1")" "sudo -n $AGENT_PATH" 2>/dev/null) || have=""
  [[ $have == "$want" ]] || core::die "$E_PRECHECK" "[$1] cpnode agent is ${have:-not installed}, this cpctl needs $want - run 'cpctl agent build' and have an administrator install $AGENT_DIR/cpnode as $AGENT_PATH (root:root 0755) on every host (manual: cpadmin sudo)"
  : >"$mark"
}

# remote::apply <host> <function> [args...]  -> runs and feeds ::markers:: into the log/recap.
# Sets REMOTE_CHANGED=1 when the remote side reported a change.
REMOTE_CHANGED=0
remote::apply() {
  local host=$1; shift
  local out rc=0
  out=$(remote::run "$host" "$@" 2>&1) || rc=$?
  log::consume "[$host]" <<<"$out"
  REMOTE_CHANGED=$LOG_LAST_CHANGED
  if [[ $rc -ne 0 ]]; then log::error "[$host] $1 failed (rc=$rc)"; return "$rc"; fi
  return 0
}

# remote::put <host> <local file> <dest> <owner> <group> <mode>
# Copies to a temp path and lets ensure::file decide (sha256 compare -> install + backup, or ok).
remote::put() {
  local host=$1 src=$2 dst=$3 owner=$4 group=$5 mode=$6
  local tmp
  tmp="/tmp/cpctl.$CPCTL_RUN_ID.$RANDOM.$(basename "$dst")"
  local attempt=1
  until scp -q "${REMOTE_SSH_OPTS[@]}" "$src" "$(remote::_target "$host"):$tmp"; do
    [[ $attempt -ge $REMOTE_RETRIES ]] && { log::error "[$host] scp $src failed"; return 1; }
    sleep $((attempt * 2)); attempt=$((attempt + 1))
  done
  remote::apply "$host" ensure::file "$tmp" "$dst" "$owner" "$group" "$mode"
}

# remote::fetch <host> <remote path> <local path>
remote::fetch() {
  scp -q "${REMOTE_SSH_OPTS[@]}" "$(remote::_target "$1"):$2" "$3"
}

# remote::parallel <function> <host...>
# Runs "<function> <host>" for each host concurrently (local function, typically calling remote::*).
# Output lines are prefixed per host by the callee's own logging; returns non-zero if any failed.
remote::parallel() {
  local fn=$1; shift
  local -A pids=()
  local h failed=()
  for h in "$@"; do
    "$fn" "$h" &
    pids[$h]=$!
  done
  for h in "${!pids[@]}"; do
    wait "${pids[$h]}" || failed+=("$h")
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    log::error "parallel $fn failed on: ${failed[*]}"
    return 1
  fi
}

remote::reachable() { remote::exec "$1" true >/dev/null 2>&1; }
