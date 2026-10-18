# shellcheck shell=bash
STEP_DESC="PKI: trust bundle, shared internal cert, shared server cert, app client certs, MDS token keys"

step_inputs() {
  pki::sans_internal; pki::sans_server; printf '%s\n' "$APPS" "$PKI_KEY_BITS" "$PKI_CERT_DAYS" "${PKI_MODE:-internal}" "$REPO_YUM_BASEURL"; date +%Y-%m
  # external CA: a new request, an answer from the bank or a new trust anchor must re-run the step
  ls -l "$PKI_DIR"/pending "$PKI_DIR"/incoming 2>/dev/null || true
  cat "$PKI_DIR"/trust/*.pem 2>/dev/null || true
}

step_apply() {
  pki::issue_all
  pki::truststore
  pki::prune
  pki::mds_keypair
  [[ -f $PKI_DIR/ca.pem ]] || return 0   # check mode on a fresh host

  # every Java host trusts the bundle (OS store + JDK default store)
  local h
  for h in $(inv::hosts ops) $(inv::hosts controller) $(inv::hosts broker) $(inv::hosts rest) $(inv::hosts c3) $(inv::hosts jump); do
    remote::put "$h" "$PKI_DIR/ca.pem" /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem root root 0644
    if [[ $REMOTE_CHANGED == 1 ]] && step::mutating; then remote::apply "$h" sys_node::trust_extract; fi
    remote::apply "$h" ensure::anchor_backups_moved
    remote::apply "$h" ensure::key_backups_removed
    remote::apply "$h" java_node::trust_ca "$(install::java_home)" /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem
  done
  # internal repo over HTTPS: the repo server certificate (cp-server) and the CA file dnf / curl pin to
  # follow every certificate or CA rotation
  if repo::tls; then
    repo::tls_configure
    for h in $(repo::clients); do repo::trust_push "$h"; done
  fi
}

step_verify() {
  pki::verify_trusted "$PKI_DIR/kafka-internal.crt" && pki::verify_trusted "$PKI_DIR/cp-server.crt"
}
