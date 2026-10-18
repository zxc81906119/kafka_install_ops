#!/usr/bin/env bash
# Role "jump": the bastion running the OP menu (opmenu), plus the fixed node account it uses over ssh.
# Scenario (bank): bastion and nodes have fixed accounts only, no AD join.
#   bastion  opuser       fixed account, login shell = menu (sshd ForceCommand); identity = operator's own AD login
#            opbootstrap  holds the break-glass certificate; usable only through /usr/local/sbin/opmenu-bootstrap
#   nodes    kafkaops     ssh key of opuser, accepted only from the bastion; sudo = restart own unit, journalctl, clean logs
# cpadmin (cpctl) is not used by the menu: platform changes stay in cpctl, day-2 operations go through the menu.
[[ -n ${_ROLE_JUMP_LOADED:-} ]] && return 0
_ROLE_JUMP_LOADED=1

jump::enabled() { [[ ${OPMENU:-off} == on && -n $(inv::hosts jump) ]]; }

# systemd units a node may restart through the menu
jump::units_of() { # <host>
  local roles
  roles=" $(inv::roles "$1" | paste -sd' ' -) "
  case $roles in *" controller "* | *" broker "*) echo confluent-server ;; esac
  case $roles in *" rest "*) echo confluent-kafka-rest ;; esac
  case $roles in *" c3 "*) echo confluent-control-center ;; esac
  return 0
}

jump::node_hosts() { inv::hosts controller; inv::hosts broker; inv::hosts rest; inv::hosts c3; }

jump::vars() {
  role::common_vars
  core::load_env "$STATE_DIR/kraft.env"
  local h out=()
  export JUMP_FQDN OPMENU_LDAP_BOOTSTRAP OPMENU_BROKER_SERVICES OPMENU_AUX_SERVICES OPMENU_CONTROLLER_HOSTS CLUSTER_ID JAVA_HOME
  export OPMENU_ENV_LABEL OPMENU_NODE_USER OPMENU_TICKET_MODE OPMENU_CHANGE_WINDOW INSTALL_METHOD
  JUMP_FQDN=$(inv::fqdn "$(inv::hosts jump | head -1)")
  OPMENU_LDAP_BOOTSTRAP=$(inv::endpoints broker "$PORT_LDAP")
  for h in $(inv::hosts broker); do out+=("$(inv::fqdn "$h"):confluent-server"); done
  OPMENU_BROKER_SERVICES="${out[*]}"; out=()
  for h in $(inv::hosts rest); do out+=("$(inv::fqdn "$h"):confluent-kafka-rest"); done
  for h in $(inv::hosts c3); do out+=("$(inv::fqdn "$h"):confluent-control-center"); done
  OPMENU_AUX_SERVICES="${out[*]}"; out=()
  for h in $(inv::hosts controller); do out+=("$(inv::fqdn "$h")"); done
  OPMENU_CONTROLLER_HOSTS="${out[*]}"
  JAVA_HOME=$(install::java_home)
  export OPMENU_TRUSTSTORE_PASSWORD OPMENU_BREAKGLASS_STORE_PASSWORD
  OPMENU_TRUSTSTORE_PASSWORD=$(inv::secret OPMENU_TRUSTSTORE_PASSWORD)
  OPMENU_BREAKGLASS_STORE_PASSWORD=$(inv::secret OPMENU_BREAKGLASS_STORE_PASSWORD)
}

# sudoers are validated with visudo on the ops host BEFORE they reach the node (a broken file would lock out sudo)
jump::put_sudoers() { # <host> <local file> <name>
  /usr/sbin/visudo -cqf "$2" || core::die "$E_PRECHECK" "generated sudoers '$3' for $1 does not validate"
  remote::put "$1" "$2" "/etc/sudoers.d/$3" root root 0440
}

jump::put_tpl() { # <host> <template name> <dest> <owner> <group> <mode>   static file, no rendering
  remote::put "$1" "$(render::find "opmenu/$2")" "$3" "$4" "$5" "$6"
}

role::jump::configure() {
  local host=$1 pkg t
  jump::vars
  remote::apply "$host" opmenu_node::jump_accounts "$OPMENU_OS_USER" opbootstrap

  # program: from the internal repo (offline intake), content-addressed version
  pkg="opmenu-$OPMENU_VERSION.tar.gz"
  [[ -f $REPO_LOCAL_ROOT/raw/tools/$pkg ]] || core::die "$E_PRECHECK" "$pkg not in the internal repo (windows/package-opmenu.sh, cpctl repo import)"
  remote::apply "$host" ensure::dir /var/cache/cp-installer root root 0755
  remote::put "$host" "$REPO_LOCAL_ROOT/raw/tools/$pkg" "/var/cache/cp-installer/$pkg" root root 0644
  remote::apply "$host" opmenu_node::install_pkg "/var/cache/cp-installer/$pkg" "$OPMENU_VERSION"

  # trust material: own truststore password (STORE_PASSWORD also opens keystores - never on the bastion)
  remote::apply "$host" ensure::dir /etc/opmenu root root 0755
  remote::apply "$host" ensure::dir /etc/opmenu/certs root opmenu 0750
  pki::truststore_named "$PKI_DIR/opmenu-truststore.p12" "$OPMENU_TRUSTSTORE_PASSWORD"
  remote::put "$host" "$PKI_DIR/opmenu-truststore.p12" /etc/opmenu/certs/truststore.p12 root opmenu 0640
  t=$(render::tmp); printf '%s' "$OPMENU_TRUSTSTORE_PASSWORD" >"$t"
  remote::put "$host" "$t" /etc/opmenu/certs/truststore_creds root opmenu 0640; rm -f "$t"
  remote::put "$host" "$PKI_DIR/ca.pem" /etc/opmenu/certs/ca.pem root opmenu 0644
  remote::put "$host" "$PKI_DIR/cp-server.crt" /etc/opmenu/certs/cp-server.pem root opmenu 0644          # item 17: expiry
  remote::put "$host" "$PKI_DIR/kafka-internal.crt" /etc/opmenu/certs/kafka-internal.pem root opmenu 0644

  # configuration (no secrets inside: readable by opbootstrap's wrapper too)
  role::push_rendered "$host" opmenu/opmenu.conf.tpl /etc/opmenu/opmenu.conf root root 0644
  if [[ $PROFILE == poc ]]; then
    # automated tests only (env overrides for user/password/ticket); never rendered for PROFILE=prod
    t=$(render::tmp); printf '. /etc/opmenu/opmenu.conf\nOPMENU_ALLOW_ENV_OVERRIDE=1\n' >"$t"
    remote::put "$host" "$t" /etc/opmenu/opmenu-test.conf root opmenu 0640; rm -f "$t"
  fi
  remote::apply "$host" ensure::dir /var/log/opmenu root opmenu 2775

  # break-glass identity: re-exported with its own password, readable by opbootstrap only
  remote::apply "$host" ensure::dir /etc/opmenu/bootstrap opbootstrap opbootstrap 0700
  if [[ ! -f $PKI_DIR/$OPMENU_BREAKGLASS.bg.p12 || $PKI_DIR/$OPMENU_BREAKGLASS.crt -nt $PKI_DIR/$OPMENU_BREAKGLASS.bg.p12 ]] && step::mutating; then
    pki::export_p12 "$OPMENU_BREAKGLASS" "$OPMENU_BREAKGLASS_STORE_PASSWORD" "$PKI_DIR/$OPMENU_BREAKGLASS.bg.p12"
    chmod 0600 "$PKI_DIR/$OPMENU_BREAKGLASS.bg.p12"
  fi
  remote::put "$host" "$PKI_DIR/$OPMENU_BREAKGLASS.bg.p12" /etc/opmenu/bootstrap/breakglass.p12 opbootstrap opbootstrap 0600
  remote::put "$host" "$PKI_DIR/$OPMENU_BREAKGLASS.crt" /etc/opmenu/bootstrap/breakglass.pem opbootstrap opbootstrap 0600
  remote::put "$host" "$PKI_DIR/$OPMENU_BREAKGLASS.key" /etc/opmenu/bootstrap/breakglass.key opbootstrap opbootstrap 0600
  # own copies of the trust material: opbootstrap is deliberately not in the opmenu group (cannot enter /etc/opmenu/certs)
  remote::put "$host" "$PKI_DIR/opmenu-truststore.p12" /etc/opmenu/bootstrap/truststore.p12 opbootstrap opbootstrap 0600
  remote::put "$host" "$PKI_DIR/ca.pem" /etc/opmenu/bootstrap/ca.pem opbootstrap opbootstrap 0644
  role::push_rendered "$host" opmenu/breakglass.properties.tpl /etc/opmenu/bootstrap/breakglass.properties opbootstrap opbootstrap 0600
  jump::put_tpl "$host" opmenu-bootstrap /usr/local/sbin/opmenu-bootstrap root root 0755

  # sudo: the fixed account may only run the wrapper as opbootstrap
  t=$(render::tmp)
  printf '# Managed by cpctl - OP menu bastion\n%s ALL=(opbootstrap) NOPASSWD: /usr/local/sbin/opmenu-bootstrap\n' "$OPMENU_OS_USER" >"$t"
  jump::put_sudoers "$host" "$t" opmenu; rm -f "$t"

  # sshd: members of opmenu only ever get the menu (also over ssh), no forwarding
  remote::put "$host" "$(render::find opmenu/sshd-opmenu.block)" /etc/ssh/cpctl-opmenu.block root root 0644
  remote::apply "$host" opmenu_node::sshd_block /etc/ssh/cpctl-opmenu.block

  # ssh to the nodes: key of the fixed account + pinned host keys
  local nodes=() h
  for h in $(jump::node_hosts); do nodes+=("$(inv::fqdn "$h")"); done
  remote::apply "$host" opmenu_node::user_key "$OPMENU_OS_USER"
  remote::apply "$host" opmenu_node::known_hosts "${nodes[@]}"
}

# jump::authorized_keys -> one authorized_keys line per bastion: its fixed account's key, accepted only from its IP
jump::authorized_keys() {
  local j ip pub
  for j in $(inv::hosts jump); do
    ip=$(getent hosts "$(inv::fqdn "$j")" | awk '{print $1; exit}')
    [[ -n $ip ]] || core::die "$E_PRECHECK" "cannot resolve $(inv::fqdn "$j")"
    pub=$(remote::run "$j" opmenu_node::pubkey "$OPMENU_OS_USER") || core::die "[$j] no ssh key for $OPMENU_OS_USER"
    printf 'from="%s",no-port-forwarding,no-agent-forwarding,no-X11-forwarding %s\n' "$ip" "$pub"
  done
}

# role::jump::node_access <node host> <authorized_keys content>
role::jump::node_access() {
  local host=$1 keys=$2 t u units
  remote::apply "$host" opmenu_node::node_account "$OPMENU_NODE_USER" "$keys"
  jump::put_tpl "$host" opmenu-clean-logs /usr/local/sbin/opmenu-clean-logs root root 0755
  units=$(jump::units_of "$host")
  t=$(render::tmp)
  {
    printf '# Managed by cpctl - fixed node account of the OP menu: only these commands, only these units\n'
    printf 'Defaults:%s !requiretty\n' "$OPMENU_NODE_USER"
    for u in $units; do printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl restart %s\n' "$OPMENU_NODE_USER" "$u"; done
    # NOEXEC: no shell escape through a pager even if --no-pager were dropped
    for u in $units; do printf '%s ALL=(root) NOPASSWD: NOEXEC: /usr/bin/journalctl -u %s -n * --no-pager\n' "$OPMENU_NODE_USER" "$u"; done
    printf '%s ALL=(root) NOPASSWD: NOEXEC: /usr/bin/journalctl -u confluent-\\* -n 500 --no-pager\n' "$OPMENU_NODE_USER"
    printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/opmenu-clean-logs\n' "$OPMENU_NODE_USER"
  } >"$t"
  jump::put_sudoers "$host" "$t" "opmenu-$OPMENU_NODE_USER"; rm -f "$t"
}
