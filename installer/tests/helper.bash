# Shared setup for bats tests: an isolated state dir and a small fixture inventory. No cluster needed.
setup_cpctl() {
  export CPCTL_HOME
  CPCTL_HOME="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export CPCTL_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export CPCTL_CONF_DIR="$BATS_TEST_TMPDIR/conf"
  mkdir -p "$CPCTL_CONF_DIR"
  cat >"$CPCTL_CONF_DIR/inventory.env" <<'EOF'
PROFILE=poc
INSTALL_METHOD=rpm
REPO_PROVIDER=local
DOMAIN=test.lab
SSH_USER=cpadmin
HOSTS_controller="kc01 kc02 kc03"
HOSTS_broker="kb01 kb02"
HOSTS_c3="c3-01"
HOST_kc01_NODE_ID=1
HOST_c3_01_ROLEFLAG=yes
PORT_CONTROLLER=9093
HEAP_poc_broker=512m
EOF
  cat >"$CPCTL_CONF_DIR/versions.env" <<'EOF'
CP_VERSION=8.3.2
EOF
  cat >"$CPCTL_CONF_DIR/apps.env" <<'EOF'
APPS="app-a app-b app-legacy"
APP_CHANNEL_app_a=scram
APP_CHANNEL_app_legacy=rest
AD_SERVICE_ACCOUNTS="svc-x svc-y"
EOF
  # shellcheck source=/dev/null
  source "$CPCTL_HOME/lib/core.sh"
  trap - ERR
  set +e
  for f in log inventory render handler step; do
    # shellcheck source=/dev/null
    source "$CPCTL_HOME/lib/$f.sh"
  done
  # shellcheck source=/dev/null
  source "$CPCTL_HOME/roles/_role.sh"
  core::init_dirs
  inv::load
}

# Node-side helpers run locally as the current user (ownership = current user/group).
setup_node() {
  # shellcheck source=/dev/null
  source "$CPCTL_HOME/lib/node/ensure.sh"
  ME=$(id -un)
  MYGROUP=$(id -gn)
}
