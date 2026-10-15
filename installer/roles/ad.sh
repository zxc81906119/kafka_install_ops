#!/usr/bin/env bash
# Role "ad": Active Directory.
#   PROFILE=poc  : the simulated Samba AD DC is configured by cpctl (TLS cert, OUs, groups, accounts)
#   PROFILE=prod : AD belongs to the bank's AD team; cpctl only CHECKS that the requested objects exist
[[ -n ${_ROLE_AD_LOADED:-} ]] && return 0
_ROLE_AD_LOADED=1

ad::ldapsearch() { # <bind user> <password> <filter> [attrs...]
  local who=$1 pw=$2 filter=$3; shift 3
  LDAPTLS_CACERT=$PKI_DIR/ca.pem ldapsearch -LLL -x -o nettimeout=5 -H "ldaps://$(inv::fqdn "$AD_HOST"):636" \
    -D "$who" -w "$pw" -b "$AD_BASE_DN" "$filter" "$@"
}

ad::bind_dn() { printf 'CN=%s,OU=Service,%s' "$1" "$AD_OU"; }

role::ad::configure() {
  local host=$AD_HOST changed=0
  remote::put "$host" "$PKI_DIR/cp-server.key" /var/lib/samba/private/tls/key.pem root root 0600
  [[ $REMOTE_CHANGED == 1 ]] && changed=1
  remote::put "$host" "$PKI_DIR/cp-server.crt" /var/lib/samba/private/tls/cert.pem root root 0644
  [[ $REMOTE_CHANGED == 1 ]] && changed=1
  remote::put "$host" "$PKI_DIR/ca.pem" /var/lib/samba/private/tls/ca.pem root root 0644
  [[ $REMOTE_CHANGED == 1 ]] && changed=1
  if [[ $changed == 1 ]] && step::mutating; then
    remote::exec "$host" "sudo -n pkill -x samba || true"
    log::changed "[$host] samba restarted with the internal-CA certificate"
    sleep 5
  fi
}

role::ad::accounts() {
  local host=$AD_HOST g u pair app
  local ou_users="OU=Users,OU=Confluent" ou_groups="OU=Groups,OU=Confluent" ou_svc="OU=Service,OU=Confluent"
  remote::apply "$host" ad::ensure_ou "$AD_OU"
  remote::apply "$host" ad::ensure_ou "$ou_users,$AD_BASE_DN"
  remote::apply "$host" ad::ensure_ou "$ou_groups,$AD_BASE_DN"
  remote::apply "$host" ad::ensure_ou "$ou_svc,$AD_BASE_DN"
  remote::apply "$host" ad::ensure_user svc-mds-bind "$(inv::secret LDAP_BIND_PASSWORD)" "$ou_svc"
  remote::apply "$host" ad::ensure_user svc-rest "$(inv::secret SVC_REST_PASSWORD)" "$ou_svc"
  remote::apply "$host" ad::ensure_user svc-c3 "$(inv::secret SVC_C3_PASSWORD)" "$ou_svc"
  remote::apply "$host" ad::ensure_user svc-cpctl "$(inv::secret SVC_CPCTL_PASSWORD)" "$ou_svc"
  for g in $AD_GROUPS; do remote::apply "$host" ad::ensure_group "$g" "$ou_groups"; done
  for pair in $AD_USERS; do
    u=${pair%%:*}; g=${pair#*:}
    remote::apply "$host" ad::ensure_user "$u" "$(inv::secret HUMAN_DEFAULT_PASSWORD)" "$ou_users"
    remote::apply "$host" ad::ensure_member "$g" "$u"
  done
}

# Production: verify only (accounts are requested from the AD team).
role::ad::check_accounts() {
  local rc=0 who pw name
  who=$(ad::bind_dn svc-mds-bind); pw=$(inv::secret LDAP_BIND_PASSWORD)
  for name in $AD_SERVICE_ACCOUNTS; do
    if grep -q '^dn:' <<<"$(ad::ldapsearch "$who" "$pw" "(sAMAccountName=$name)" dn)"; then log::ok "AD account $name"
    else log::error "AD account $name missing (request it from the AD team)"; rc=1; fi
  done
  for name in $AD_GROUPS; do
    if grep -q '^dn:' <<<"$(ad::ldapsearch "$who" "$pw" "(&(objectClass=group)(cn=$name))" dn)"; then log::ok "AD group $name"
    else log::error "AD group $name missing"; rc=1; fi
  done
  return "$rc"
}

# LDAPS up and certificate chain valid (anonymous RootDSE, no account needed yet)
ad::_ldaps_tls_ok() {
  grep -q "^namingContexts:" <<<"$(LDAPTLS_CACERT=$PKI_DIR/ca.pem ldapsearch -LLL -x -o nettimeout=5 -H "ldaps://$(inv::fqdn "$AD_HOST"):636" \
    -s base -b "" namingContexts)"
}

ad::_ldaps_ok() {
  ad::ldapsearch "$(ad::bind_dn svc-mds-bind)" "$(inv::secret LDAP_BIND_PASSWORD)" "(sAMAccountName=svc-mds-bind)" dn |
    grep -q '^dn:'
}

role::ad::start() { :; }
role::ad::restart() { remote::exec "$AD_HOST" "sudo -n pkill -x samba || true"; }
role::ad::stop() { :; }
role::ad::health() {
  health::wait 90 "[$AD_HOST] LDAPS bind as svc-mds-bind (cert chain verified)" ad::_ldaps_ok
}
