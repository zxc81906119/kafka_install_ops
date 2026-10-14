#!/usr/bin/env bash
# cpctl uninstall --yes-really : remove services, packages, configs and Kafka data on all cluster hosts.
# Keeps: the internal repo (/srv/repo), the PKI (state/pki) and the AD objects - so a reinstall is quick.
[[ -n ${_UNINSTALL_LOADED:-} ]] && return 0
_UNINSTALL_LOADED=1

uninstall::host() { # <host> <role>
  local h=$1 role=$2 u
  case $role in
    c3) for u in confluent-control-center alertmanager prometheus; do remote::apply "$h" svc::stop "$u" || true; done ;;
    rest) remote::apply "$h" svc::stop confluent-kafka-rest || true ;;
    *) remote::apply "$h" svc::stop confluent-server || true ;;
  esac
  install::remove "$h" "$role"
  remote::apply "$h" ensure::absent /etc/confluent
  for u in confluent-server confluent-kafka-rest confluent-control-center prometheus alertmanager; do
    remote::apply "$h" ensure::absent "/etc/systemd/system/$u.service.d"
  done
  remote::apply "$h" ensure::absent /var/lib/kafka
  remote::apply "$h" ensure::absent /var/lib/confluent
  remote::run "$h" svc::daemon_reload
}

uninstall::main() {
  local h
  for h in $(inv::hosts rest); do uninstall::host "$h" rest; done
  for h in $(inv::hosts c3); do uninstall::host "$h" c3; done
  for h in $(inv::hosts broker); do uninstall::host "$h" broker; done
  for h in $(inv::hosts controller) $(inv::hosts controller_spare); do
    remote::reachable "$h" && uninstall::host "$h" controller
  done
  for h in $(inv::hosts lb); do remote::apply "$h" ensure::absent /etc/nginx/stream.d/cp.conf; remote::exec "$h" "sudo -n nginx -s reload" || true; done
  rm -f "$STATE_DIR/kraft.env" "$STAMP_DIR"/* "$STATE_DIR/client"/*.properties
  rm -rf "$STATE_DIR/cli-home"
  log::info "uninstalled. Kept: internal repo, PKI ($PKI_DIR), AD accounts. Reinstall with: cpctl install"
}
