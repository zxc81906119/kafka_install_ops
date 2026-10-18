# Node-side root actions that used to be ad-hoc "sudo -n <command>" strings on the ops side. As named functions they
# run the same way under full sudo (bundle over "bash -s") and under restricted sudo (cpnode agent, see node/cpnode.main).

# sys_node::trust_extract -> rebuild the OS trust store from the anchors
sys_node::trust_extract() { _checking || update-ca-trust extract; }

# sys_node::nonempty <file> -> exit status only (read-only probe of a root-readable file)
sys_node::nonempty() { [[ -s $1 ]]; }

# sys_node::read_conf <file> -> contents of a Confluent configuration file (only below /etc/confluent)
sys_node::read_conf() {
  [[ $1 == /etc/confluent/* && $1 != *..* ]] || { _mark warn "read_conf: $1 is not below /etc/confluent"; return 1; }
  cat -- "$1"
}

# sys_node::conf_has_key <file> <key> -> exit 0 when "<key>=" is set in the file (below /etc/confluent)
sys_node::conf_has_key() {
  [[ $1 == /etc/confluent/* && $1 != *..* ]] || return 2
  grep -q "^$2=" "$1"
}

# sys_node::backup_etc -> tar.gz of /etc/confluent and the systemd drop-ins on stdout
sys_node::backup_etc() { tar -czf - -C / etc/confluent etc/systemd/system 2>/dev/null; }

# sys_node::versionlocked <package> -> exit 0 when the package is version-locked
sys_node::versionlocked() { [[ $(dnf versionlock list 2>/dev/null) == *"$1"* ]]; }

# sys_node::group <name> -> system group exists
sys_node::group() {
  if getent group "$1" >/dev/null; then _mark ok "group $1"; return 0; fi
  _mark changed "group $1"
  _checking || groupadd -r "$1"
}

# sys_node::httpd_restart -> config test, then restart (repo server)
sys_node::httpd_restart() {
  _checking && return 0
  local out
  out=$(httpd -t 2>&1) || { _mark warn "httpd -t rejected the configuration: $(tail -1 <<<"$out")"; return 1; }
  systemctl restart httpd
}

# sys_node::nginx_reload -> config test, then graceful reload (load balancer)
sys_node::nginx_reload() {
  _checking && return 0
  nginx -t -q || { _mark warn "nginx -t rejected the configuration"; return 1; }
  nginx -s reload
}

# sys_node::samba_restart -> the PoC Samba AD DC is started by its container entrypoint; killing it restarts it
sys_node::samba_restart() { _checking || pkill -x samba || true; }

# kafka_node::add_controller <java home> <kafka-metadata-quorum> <bootstrap controllers>
# The copied client config may contain ${securepass:...}: the master key comes from the root-only service.env and
# reaches the tool through the environment (runuser keeps it), never through the command line.
kafka_node::add_controller() {
  _checking && return 0
  (
    set -a
    # shellcheck source=/dev/null
    . /etc/confluent/kafka/service.env 2>/dev/null || true
    set +a
    export JAVA_HOME=$1 KAFKA_HEAP_OPTS=-Xmx256m
    runuser -u cp-kafka -- "$2" --command-config /etc/confluent/kafka/add-controller.properties \
      --bootstrap-controller "$3" add-controller
  )
}

# opmenu_node::pubkey <user> -> that account's ssh public key (bastion)
opmenu_node::pubkey() {
  local home
  home=$(getent passwd "$1" | cut -d: -f6)
  [[ -n $home ]] && cat "$home/.ssh/id_ed25519.pub"
}

# opmenu_node::selftest <menu account> -> the menu lists its items when run as the fixed account
opmenu_node::selftest() { [[ -x /opt/opmenu/opmenu.sh ]] && runuser -u "$1" -- /opt/opmenu/opmenu.sh --list >/dev/null; }

# ---- internal repo (ops host): files are published as repoadmin with umask 022 (world-readable for httpd)
readonly REPO_NODE_ROOT=/srv/repo REPO_NODE_LANDING=/mnt/exchange
repo_node::_as() { runuser -u repoadmin -- bash -c 'umask 022; exec "$@"' _ "$@"; }
repo_node::_below() { [[ $1 == "$2"/* && $1 != *..* ]] || { _mark warn "path $1 is not below $2"; return 1; }; }
# repo_node::publish <landing file> <dest>
repo_node::publish() {
  repo_node::_below "$1" "$REPO_NODE_LANDING" && repo_node::_below "$2" "$REPO_NODE_ROOT" || return 1
  repo_node::_as install -D -m 0644 "$1" "$2"
}
# repo_node::mkdir <dir>
repo_node::mkdir() { repo_node::_below "$1" "$REPO_NODE_ROOT" && repo_node::_as install -d -m 0755 "$1"; }
# repo_node::copy_tree <landing dir> <dest dir>
repo_node::copy_tree() {
  repo_node::_below "$1" "$REPO_NODE_LANDING" && repo_node::_below "$2" "$REPO_NODE_ROOT" || return 1
  repo_node::_as cp -r "$1" "$2"
}
# repo_node::createrepo <repo dir>
repo_node::createrepo() { repo_node::_below "$1" "$REPO_NODE_ROOT" && repo_node::_as createrepo_c -q --update "$1"; }

# ---- PoC acceptance tests of the OP menu (cpctl verify). Under the cpnode agent they are available only when
# /etc/cpctl/cpnode.conf sets CPNODE_TEST_FUNCTIONS=1 (PROFILE=poc).
# opmenu_test::run <conf> <menu account> <AD user> <AD password> <item> [args...]
#   -> menu output, then "@@LOG@@ <last opmenu.log line>"
opmenu_test::run() {
  local conf=$1 acct=$2 u=$3 pw=$4
  shift 4
  runuser -u "$acct" -- env OPMENU_CONF="$conf" OPMENU_USER="$u" OPMENU_PASS="$pw" OPMENU_TICKET=CHG-2026-0001 \
    OPMENU_YES=1 OPMENU_REASON=verify /opt/opmenu/opmenu.sh --run "$@" </dev/null 2>&1 || true
  printf '@@LOG@@ %s\n' "$(tail -1 /var/log/opmenu/opmenu.log)"
}
# opmenu_test::broken_conf on|off -> a menu config whose bootstrap server does not exist
opmenu_test::broken_conf() {
  if [[ $1 == on ]]; then
    printf '. /etc/opmenu/opmenu-test.conf\nOPMENU_BOOTSTRAP=nowhere.invalid:9096\n' >/tmp/opmenu-broken.conf
    chmod 0644 /tmp/opmenu-broken.conf
  else
    rm -f /tmp/opmenu-broken.conf
  fi
}
# opmenu_test::logged <basic regex> -> exit 0 when a line of the menu log matches
opmenu_test::logged() { grep -q -- "$1" /var/log/opmenu/opmenu.log; }
# opmenu_test::shell_as <account> -> what "su - <account> -c id" prints (must not be an id line)
opmenu_test::shell_as() { su - "$1" -c id </dev/null 2>&1 || true; }
# opmenu_test::read_as <account> <file> -> exit 0 when the account can read the file (must fail for secrets)
opmenu_test::read_as() { runuser -u "$1" -- cat -- "$2" >/dev/null 2>&1; }

# ---- OS patching (cpctl os patch) --------------------------------------------------------------------------------
# sys_node::os_update -> apply OS updates from the configured OS repos; Confluent / JDK packages are version-locked
# (rpm strategy) or not RPMs at all (tar strategy), so they are never moved by this
sys_node::os_update() {
  local n
  n=$(dnf -q check-update 2>/dev/null | awk 'NF == 3 && $1 ~ /\./' | wc -l || true)
  if [[ ${n:-0} -eq 0 ]]; then _mark ok "no OS updates available"; return 0; fi
  _mark changed "$n OS package update(s)"
  _checking && return 0
  dnf -y -q update
}

# sys_node::needs_reboot -> exit 0 when the running kernel is older than the newest installed one
sys_node::needs_reboot() {
  local newest
  newest=$(rpm -q --last kernel-core 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-core-//')
  [[ -n $newest && $newest != "$(uname -r)" ]]
}

# sys_node::reboot -> reboot in the background (the ssh session must be able to return first)
sys_node::reboot() {
  _checking && return 0
  if node::in_container; then _mark warn "container: no reboot (restart of the services only)"; return 0; fi
  _mark changed "reboot"
  systemd-run --on-active=3 --timer-property=AccuracySec=1 /usr/bin/systemctl reboot >/dev/null
}

# ---- health probes (cpctl health; read-only) -----------------------------------------------------------------------
# sys_node::disk <path> -> "<used%> <avail> <mount>" of the file system holding the path
sys_node::disk() { df -P "$1" 2>/dev/null | awk 'NR == 2 {sub("%", "", $5); print $5, $4, $6}'; }
