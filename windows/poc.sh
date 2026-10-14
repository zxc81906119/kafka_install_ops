#!/usr/bin/env bash
# PoC environment controller (run from Git Bash on Windows).
#   poc.sh secrets           generate installer/conf/secrets.env once (idempotent)
#   poc.sh build             build the simulated host images (needs internet, run once)
#   poc.sh up                start all hosts (add --spare to also start kc04)
#   poc.sh stop|start        stop/start containers, keeping their state
#   poc.sh down              remove containers (installed software is lost, volumes kept)
#   poc.sh reset             remove containers AND volumes (full clean slate)
#   poc.sh status            container status
#   poc.sh shell <host>      interactive shell (ops01 opens as cpadmin)
#   poc.sh exec <host> cmd   run a command as root inside a host
#   poc.sh logs <host>       container logs
#   poc.sh cpctl <args>      run cpctl on ops01 as cpadmin
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

gen_pass() { # 20 random alnum chars + fixed complexity suffix (AD password policy)
  local p
  p=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)
  printf '%sAa1-' "$p"
}

cmd_secrets() {
  local f="$CONF_DIR/secrets.env"
  [[ -f "$CONF_DIR/apps.env" ]] || die "missing $CONF_DIR/apps.env"
  # shellcheck source=/dev/null
  source "$CONF_DIR/apps.env"
  local keys=(AD_ADMIN_PASSWORD LDAP_BIND_PASSWORD SVC_REST_PASSWORD SVC_C3_PASSWORD SVC_CPCTL_PASSWORD
    KAFKA_ADMIN_PASSWORD STORE_PASSWORD HUMAN_DEFAULT_PASSWORD SECRET_MASTER_PASSPHRASE)
  local app
  for app in $APPS; do keys+=("APP_$(tr 'a-z-' 'A-Z_' <<<"$app")_PASSWORD"); done
  touch "$f"
  local k added=0
  for k in "${keys[@]}"; do
    if ! grep -q "^${k}=" "$f"; then
      printf '%s=%s\n' "$k" "$(gen_pass)" >>"$f"
      added=$((added + 1))
    fi
  done
  log "secrets: $added new value(s) in $f (existing values kept)"
}

cmd_build() {
  ensure_docker
  check_crlf
  log "building cp-node:poc"; docker build -t cp-node:poc "$(winpath "$DOCKER_DIR/node")"
  log "building cp-ops:poc";  docker build -t cp-ops:poc "$(winpath "$DOCKER_DIR/ops")"
  log "building cp-ad:poc";   docker build -t cp-ad:poc "$(winpath "$DOCKER_DIR/ad")"
  log "building cp-lb:poc";   docker build -t cp-lb:poc "$(winpath "$DOCKER_DIR/lb")"
}

cmd_up() {
  ensure_docker
  check_crlf
  [[ -f "$CONF_DIR/secrets.env" ]] || cmd_secrets
  local profile=()
  [[ ${1:-} == --spare ]] && profile=(--profile spare)
  "${COMPOSE[@]}" "${profile[@]}" up -d
  log "waiting for ops01 to publish the cpadmin key"
  local i
  for i in $(seq 1 30); do
    docker exec cp-poc-ops01-1 test -s /etc/ssh/authorized_keys.d/cpadmin 2>/dev/null && break
    sleep 2
  done
  cmd_status
}

cmd_status() { "${COMPOSE[@]}" --profile spare ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'; }

container() { printf 'cp-poc-%s-1' "$1"; }

cmd_shell() {
  local host=${1:?host}; local c; c=$(container "$host")
  local tty=(docker exec -it)
  [[ -t 1 ]] && command -v winpty >/dev/null && [[ -n ${MSYSTEM:-} ]] && tty=(winpty docker exec -it)
  if [[ $host == ops01 ]]; then
    "${tty[@]}" -u cpadmin -w /home/cpadmin "$c" bash -l
  else
    "${tty[@]}" "$c" bash -l
  fi
}

cmd_cpctl() {
  local tty=(docker exec -i)
  [[ -t 1 ]] && tty=(docker exec -it)
  local envs=()
  [[ -n ${CPCTL_CP_VERSION:-} ]] && envs=(-e "CPCTL_CP_VERSION=$CPCTL_CP_VERSION")
  "${tty[@]}" "${envs[@]}" -u cpadmin -w /home/cpadmin "$(container ops01)" /usr/local/bin/cpctl "$@"
}

main() {
  local cmd=${1:-}; shift || true
  case $cmd in
    secrets) cmd_secrets ;;
    build) cmd_build ;;
    up) cmd_up "$@" ;;
    start) ensure_docker; "${COMPOSE[@]}" start ;;
    stop) "${COMPOSE[@]}" --profile spare stop ;;
    down) "${COMPOSE[@]}" --profile spare down ;;
    reset) "${COMPOSE[@]}" --profile spare down -v ;;
    status) cmd_status ;;
    shell) cmd_shell "$@" ;;
    exec) local h=${1:?host}; shift; docker exec -i "$(container "$h")" "$@" ;;
    logs) docker logs --tail "${2:-200}" "$(container "${1:?host}")" ;;
    cpctl) cmd_cpctl "$@" ;;
    -h | --help | help | "") usage 0 ;;
    *) usage 1 ;;
  esac
}
main "$@"
