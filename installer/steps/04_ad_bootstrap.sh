# shellcheck shell=bash
STEP_DESC="Active Directory: LDAPS certificate + service accounts/groups (PoC) or verification only (prod)"

step_inputs() { printf '%s\n' "$PROFILE" "$AD_USERS" "$AD_GROUPS"; core::sha256 "$PKI_DIR/cp-server.crt" 2>/dev/null || true; }

step_apply() {
  if [[ $PROFILE == prod ]]; then
    log::info "PROFILE=prod: AD is owned by the AD team - checking only"
    role::ad::check_accounts || core::die "$E_PRECHECK" "missing AD objects - raise a request to the AD team"
    return 0
  fi
  role::ad::configure
  if step::mutating; then
    health::wait 120 "[$AD_HOST] LDAPS answers with the internal-CA certificate" ad::_ldaps_tls_ok
  fi
  role::ad::accounts
  # explicit if: a trailing "cond && cmd" would make the step fail in --check mode
  if step::mutating; then role::ad::health; fi
}

step_verify() { role::ad::health; }
