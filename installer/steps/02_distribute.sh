# shellcheck shell=bash
STEP_DESC="install packages from the internal repo (exact versions, GPG-checked, versionlocked)"

step_inputs() { cat "$CONF_DIR/versions.env"; printf '%s\n' "$CP_VERSION" "$INSTALL_METHOD" "$REPO_YUM_BASEURL"; }

distribute::host() {
  local h=$1 role
  role=$(inv::roles "$h" | grep -E '^(ops|controller|broker|rest|c3|jump)$' | head -1)
  install::prepare "$h"
  local ver=$CP_VERSION
  [[ $role == ops ]] && ver=$CP_TOOLS_VERSION
  install::ensure "$h" install "$ver" "$role"
}

step_apply() {
  local hosts=()
  mapfile -t hosts < <(inv::hosts ops; inv::hosts controller; inv::hosts broker; inv::hosts rest; inv::hosts c3; inv::hosts jump)
  # ops first (it needs the JDK for keytool in 03_pki), then everything else in parallel
  distribute::host "${hosts[0]}"
  # internal repo over HTTPS: the repo server needs its certificate (cp-server) before any other host can
  # install - so the certificates are issued here already (openssl only; with the bank CA this is where the
  # install waits for the bank's answers), then the HTTPS listener is configured and checked
  if repo::tls; then
    pki::issue_all
    repo::tls_configure
    if step::mutating; then repo::verify_served || core::die "$E_GATE" "internal repo not served over HTTPS at $REPO_YUM_BASEURL"; fi
  fi
  remote::parallel distribute::host "${hosts[@]:1}"
}

step_verify() {
  local h v
  for h in $(inv::hosts controller) $(inv::hosts broker); do
    v=$(install::version "$h")
    [[ $v == "$CP_VERSION" ]] || { log::error "[$h] confluent-server is '$v', expected $CP_VERSION"; return 1; }
  done
}
