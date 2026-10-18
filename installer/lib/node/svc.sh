# Node-side service control. systemd when available (normal case, also in the PoC containers);
# otherwise falls back to the unit-file interpreter in cp-service.sh (see lib/os.sh).

svc::_systemd() { [[ -d /run/systemd/system ]]; }

svc::daemon_reload() {
  if [[ ${CPCTL_CHECK:-0} == 1 ]]; then return 0; fi
  svc::_systemd && systemctl daemon-reload
  return 0
}

# svc::enable <unit>
svc::enable() {
  local u=$1
  if systemctl is-enabled -q "$u" 2>/dev/null; then _mark ok "$u enabled"; return 0; fi
  _mark changed "enable $u"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || systemctl enable -q "$u"
}

# svc::start <unit>  (no-op if already active)
svc::start() {
  local u=$1
  if systemctl is-active -q "$u"; then _mark ok "$u active"; return 0; fi
  _mark changed "start $u"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || systemctl start "$u"
}

svc::restart() {
  local u=$1
  _mark changed "restart $u"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || systemctl restart "$u"
}

svc::stop() {
  local u=$1
  if ! systemctl is-active -q "$u"; then _mark ok "$u stopped"; return 0; fi
  _mark changed "stop $u"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || systemctl stop "$u"
}

# svc::disable <unit>  (a removed broker must not come back after a reboot)
svc::disable() {
  local u=$1
  if ! systemctl is-enabled -q "$u" 2>/dev/null; then _mark ok "$u disabled"; return 0; fi
  _mark changed "disable $u"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || systemctl disable -q "$u"
}

svc::is_active() { systemctl is-active -q "$1"; }

svc::status_line() { printf '%s %s\n' "$1" "$(systemctl is-active "$1" 2>/dev/null || true)"; }

# svc::journal <unit> [lines]
svc::journal() { journalctl -u "$1" -n "${2:-50}" --no-pager 2>/dev/null || true; }

# svc::wait_port <port> <timeout seconds>
svc::wait_port() {
  local p=$1 t=${2:-120} i
  for ((i = 0; i < t; i += 2)); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}
