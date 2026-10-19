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
#   poc.sh agent-push        (administrator) install the agent + policy cpctl built (agent build) on every host, as root
#   poc.sh sudo-full         (administrator) give cpadmin full sudo again on every running host
#   poc.sh sudo-restrict [h] (administrator) cpadmin may run only the cpnode agent (all running hosts, or the given ones)
#   poc.sh web-cert          (bank) key + certificate for the repo web server repo01, signed by the bank CA
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
  local keys=(AD_ADMIN_PASSWORD LDAP_BIND_PASSWORD
    KAFKA_ADMIN_PASSWORD STORE_PASSWORD HUMAN_DEFAULT_PASSWORD SECRET_MASTER_PASSPHRASE MDS_TOKEN_PASSPHRASE AUDIT_PASSWORD JMX_EXPORTER_PASSWORD
    OPMENU_TRUSTSTORE_PASSWORD OPMENU_BREAKGLASS_STORE_PASSWORD)
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
  log "building cp-web:poc";  docker build -t cp-web:poc "$(winpath "$DOCKER_DIR/web")"
  log "building cp-c3:poc";   docker build -t cp-c3:poc "$(winpath "$DOCKER_DIR/c3")"
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
  [[ -n ${CPCTL_CP_VERSION:-} ]] && envs+=(-e "CPCTL_CP_VERSION=$CPCTL_CP_VERSION")
  [[ -n ${CPCTL_INSTALL_METHOD:-} ]] && envs+=(-e "CPCTL_INSTALL_METHOD=$CPCTL_INSTALL_METHOD")
  "${tty[@]}" "${envs[@]}" -u cpadmin -w /home/cpadmin "$(container ops01)" /usr/local/bin/cpctl "$@"
}


# The two actions below stand for the bank's system administrator: after "cpctl agent install --restrict" the
# installer account can neither replace the agent nor widen its own sudo. They act as root through docker exec.
# repo01 is the bank's own web server: no installer account, no agent
running_hosts() { docker ps --format '{{.Names}}' | sed -n 's/^cp-poc-\(.*\)-1$/\1/p' | grep -vx repo01 | sort; }

cmd_agent_push() {
  local agent h
  agent=$(mktemp)
  docker exec "$(container ops01)" cat /var/lib/cp-installer/agent/cpnode >"$agent" || die "no agent built - run: poc.sh cpctl agent build"
  log "agent $(sed -n 's/^readonly CPNODE_VERSION=//p' "$agent")"
  for h in $(running_hosts); do
    docker exec "$(container ops01)" cat /var/lib/cp-installer/agent/cpnode.conf | docker exec -i "$(container "$h")" sh -c 'install -d -m 0755 /etc/cpctl && cat > /etc/cpctl/cpnode.conf.new && chown root:root /etc/cpctl/cpnode.conf.new && chmod 0644 /etc/cpctl/cpnode.conf.new && mv -f /etc/cpctl/cpnode.conf.new /etc/cpctl/cpnode.conf'
    docker exec -i "$(container "$h")" sh -c 'install -d -m 0755 /usr/local/libexec/cpctl && cat > /usr/local/libexec/cpctl/cpnode.new && chown root:root /usr/local/libexec/cpctl/cpnode.new && chmod 0755 /usr/local/libexec/cpctl/cpnode.new && mv -f /usr/local/libexec/cpctl/cpnode.new /usr/local/libexec/cpctl/cpnode' <"$agent" &&
      log "[$h] agent installed"
  done
  rm -f "$agent"
}

cmd_sudo_full() {
  local h
  for h in $(running_hosts); do
    docker exec "$(container "$h")" sh -c 'printf "cpadmin ALL=(ALL) NOPASSWD: ALL\nDefaults:cpadmin !requiretty\n" > /etc/sudoers.d/cpadmin && chmod 0440 /etc/sudoers.d/cpadmin && visudo -cqf /etc/sudoers.d/cpadmin' &&
      log "[$h] cpadmin: full sudo"
  done
}

# Restrict cpadmin to the cpnode agent (the sudoers file cpctl built with "agent build"); validated before it is
# put in place. Used after a host container was recreated (it comes back with the image's full sudo).
cmd_sudo_restrict() {
  local h s
  s=$(mktemp)
  docker exec "$(container ops01)" cat /var/lib/cp-installer/agent/sudoers-cpadmin >"$s" || die "no sudoers built - run: poc.sh cpctl agent build"
  for h in ${*:-$(running_hosts)}; do
    docker exec -i "$(container "$h")" sh -c 'cat > /etc/sudoers.d/.cpadmin.new && chmod 0440 /etc/sudoers.d/.cpadmin.new && visudo -cqf /etc/sudoers.d/.cpadmin.new && mv -f /etc/sudoers.d/.cpadmin.new /etc/sudoers.d/cpadmin' <"$s" &&
      log "[$h] cpadmin: restricted to the cpnode agent"
  done
  rm -f "$s"
}

# The bank side of the repo web server: its TLS key and a certificate from the bank CA (bank-ca.sh sign).
# Idempotent: a certificate valid for 30 more days is kept. repo01 reads docker/web/tls/ when httpd starts.
cmd_web_cert() {
  local d csr
  d="$(winpath "$DOCKER_DIR/web/tls")"
  mkdir -p "$d"
  if [[ -f $d/repo.crt ]] && openssl x509 -in "$d/repo.crt" -noout -checkend 2592000 >/dev/null 2>&1; then
    log "repo01 certificate still valid: $(openssl x509 -in "$d/repo.crt" -noout -subject -enddate | paste -sd' ')"
    return 0
  fi
  csr="$d/repo.csr"
  openssl req -new -newkey rsa:3072 -nodes -keyout "$d/repo.key" -out "$csr" -subj "/CN=repo01.poc.lab/O=PoC Bank/C=TW" \
    -addext "subjectAltName=DNS:repo01.poc.lab,DNS:repo01" -addext "extendedKeyUsage=serverAuth" 2>/dev/null
  bash "$WIN_DIR/bank-ca.sh" sign "$csr" "$d/repo.crt"
  rm -f "$csr"
  log "repo01 certificate in docker/web/tls/ - (re)start httpd: poc.sh exec repo01 systemctl restart httpd"
}

main() {
  local cmd=${1:-}; shift || true
  case $cmd in
    secrets) cmd_secrets ;;
    build) cmd_build ;;
    up) cmd_up "$@" ;;
    start) ensure_docker; "${COMPOSE[@]}" --profile spare start ;;   # spare profile too: kc04 may be an active controller after the replacement drill
    stop) "${COMPOSE[@]}" --profile spare stop ;;
    down) "${COMPOSE[@]}" --profile spare down ;;
    reset) "${COMPOSE[@]}" --profile spare down -v ;;
    status) cmd_status ;;
    shell) cmd_shell "$@" ;;
    exec) local h=${1:?host}; shift; docker exec -i "$(container "$h")" "$@" ;;
    logs) docker logs --tail "${2:-200}" "$(container "${1:?host}")" ;;
    cpctl) cmd_cpctl "$@" ;;
    agent-push) cmd_agent_push ;;
    sudo-full) cmd_sudo_full ;;
    sudo-restrict) cmd_sudo_restrict "$@" ;;
    web-cert) cmd_web_cert ;;
    -h | --help | help | "") usage 0 ;;
    *) usage 1 ;;
  esac
}
main "$@"
