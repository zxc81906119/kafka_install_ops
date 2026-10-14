# shellcheck shell=bash
STEP_DESC="install packages from the internal repo (exact versions, GPG-checked, versionlocked)"

step_inputs() { cat "$CONF_DIR/versions.env"; printf '%s\n' "$CP_VERSION" "$INSTALL_METHOD" "$REPO_YUM_BASEURL"; }

distribute::host() {
  local h=$1 role
  role=$(inv::roles "$h" | grep -E '^(ops|controller|broker|rest|c3)$' | head -1)
  install::prepare "$h"
  local ver=$CP_VERSION
  [[ $role == ops ]] && ver=$CP_TOOLS_VERSION
  install::ensure "$h" install "$ver" "$role"
}

step_apply() {
  local hosts=()
  mapfile -t hosts < <(inv::hosts ops; inv::hosts controller; inv::hosts broker; inv::hosts rest; inv::hosts c3)
  # ops first (it needs the JDK for keytool in 03_pki), then everything else in parallel
  distribute::host "${hosts[0]}"
  remote::parallel distribute::host "${hosts[@]:1}"
}

step_verify() {
  local h v
  for h in $(inv::hosts controller) $(inv::hosts broker); do
    v=$(install::version "$h")
    [[ $v == "$CP_VERSION" ]] || { log::error "[$h] confluent-server is '$v', expected $CP_VERSION"; return 1; }
  done
}
