# shellcheck shell=bash
STEP_DESC="internal PKI: CA, shared internal cert, shared server cert, app client certs, MDS token keys"

step_inputs() { pki::sans_internal; pki::sans_server; printf '%s\n' "$APPS" "$PKI_KEY_BITS" "$PKI_CERT_DAYS"; date +%Y-%m; }

step_apply() {
  pki::ca
  pki::truststore
  # controllers + brokers: one shared certificate for CONTROLLER / INTERNAL mTLS (principal kafka-internal)
  pki::issue kafka-internal "$(pki::sans_internal)" serverAuth,clientAuth
  # all servers: one shared certificate for external listeners, MDS, REST, C3, Prometheus, LDAPS
  pki::issue cp-server "$(pki::sans_server)" serverAuth,clientAuth
  # machines: client certificates ONLY for legacy apps that use REST Proxy (principal = CN)
  local app
  for app in $(inv::apps rest); do pki::issue "$app" "" clientAuth; done
  # OP menu break-glass identity (menu item 91; RBAC SystemAdmin, key held by opbootstrap on the bastion)
  if [[ ${OPMENU:-off} == on ]]; then pki::issue "$OPMENU_BREAKGLASS" "" clientAuth; fi
  pki::prune
  pki::mds_keypair
  [[ -f $PKI_DIR/ca.pem ]] || return 0   # check mode on a fresh host

  # every Java host trusts the internal CA (OS store + JDK default store)
  local h
  for h in $(inv::hosts ops) $(inv::hosts controller) $(inv::hosts broker) $(inv::hosts rest) $(inv::hosts c3) $(inv::hosts jump); do
    remote::put "$h" "$PKI_DIR/ca.pem" /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem root root 0644
    if [[ $REMOTE_CHANGED == 1 ]] && step::mutating; then remote::exec "$h" "sudo -n update-ca-trust extract"; fi
    remote::apply "$h" java_node::trust_ca "$(install::java_home)" /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem
  done
}

step_verify() {
  openssl verify -CAfile "$PKI_DIR/ca.pem" "$PKI_DIR/kafka-internal.crt" "$PKI_DIR/cp-server.crt" >/dev/null
}
