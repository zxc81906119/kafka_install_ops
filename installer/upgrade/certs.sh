#!/usr/bin/env bash
# cpctl certs status | rotate [--cert NAME[,NAME]] | rotate-ca --phase add|switch|retire
#
# Leaf rotation (yearly): re-issue the shared certificates, push, rolling restart behind health gates.
#   Default set = kafka-internal,cp-server. App client certs (legacy REST apps) only with --cert / --cert all,
#   because the new key + certificate must also be handed to the application team.
#
# CA rotation (three runs, each one a complete rolling restart; zero downtime because every node trusts
# old AND new CA while certificates are being switched):
#   add     create ca-next, trust bundle = ca + ca-next  -> every truststore / OS / JDK store trusts both
#   switch  ca-next becomes the signing CA, the old one stays trusted as ca-old; every leaf is re-issued
#           (legacy apps: hand out their new certificate now - their old one keeps working until retire)
#   retire  drop ca-old from the bundle; only after every node and app presents a new-CA certificate
[[ -n ${_CERTS_LOADED:-} ]] && return 0
_CERTS_LOADED=1

# certs::rollout -> push PKI material everywhere; handlers restart one node at a time with health gates
certs::rollout() {
  export CPCTL_FORCE=1
  step::run 03_pki
  step::run 04_ad_bootstrap
  step::run 05_configure
  # bastion: truststore of the new bundle, re-issued break-glass certificate
  if jump::enabled; then step::run 11_opmenu; fi
}

# certs::served -> every TLS endpoint presents the certificate currently on the ops host
certs::served() {
  local h rc=0 want have
  want=$(pki::serial cp-server)
  for h in $(inv::hosts broker); do
    have=$(pki::served_serial "$(inv::fqdn "$h"):$PORT_MDS")
    [[ $have == "$want" ]] && log::ok "[$h] MDS presents cp-server serial $want" ||
      { log::warn "[$h] MDS presents serial ${have:-none}, expected $want"; rc=2; }
  done
  for h in $(inv::hosts rest); do
    have=$(pki::served_serial "$(inv::fqdn "$h"):$PORT_REST")
    [[ $have == "$want" ]] && log::ok "[$h] REST presents cp-server serial $want" ||
      { log::warn "[$h] REST presents serial ${have:-none}, expected $want"; rc=2; }
  done
  want=$(pki::serial kafka-internal)
  for h in $(inv::hosts controller); do
    have=$(pki::served_serial "$(inv::fqdn "$h"):$PORT_CONTROLLER")
    [[ $have == "$want" ]] && log::ok "[$h] CONTROLLER listener presents kafka-internal serial $want" ||
      { log::warn "[$h] CONTROLLER listener presents serial ${have:-none}, expected $want"; rc=2; }
  done
  return "$rc"
}

certs::status() {
  local rc=0
  pki::status || rc=$?
  log::step "---- certificates presented by the running services"
  certs::served || rc=$?
  return "$rc"
}

certs::rotate() {
  local names=kafka-internal,cp-server
  while [[ $# -gt 0 ]]; do
    case $1 in
      --cert) names=$2; shift 2 ;;
      *) core::die "$E_USAGE" "unknown option $1" ;;
    esac
  done
  log::step "==== certificate rotation: $names"
  export CPCTL_PKI_REISSUE=$names
  certs::rollout
  step::mutating || return 0
  certs::served || core::die "$E_GATE" "some services still present the old certificate"
  [[ $names == all || $names == *app-* ]] && log::warn "hand the re-issued app certificates to the application teams ($PKI_DIR/<app>.p12)"
  return 0
}

certs::_archive_ca() { # <basename...>
  local arch f
  arch="$PKI_DIR/archive/ca-$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$arch"
  for f in "$@"; do [[ -f $PKI_DIR/$f ]] && cp -p "$PKI_DIR/$f" "$arch/"; done
  return 0
}

certs::rotate_ca() {
  local phase=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --phase) phase=$2; shift 2 ;;
      *) core::die "$E_USAGE" "unknown option $1" ;;
    esac
  done
  case $phase in
    add)
      if [[ -f $PKI_DIR/ca-next.crt ]]; then
        log::ok "next CA exists ($(openssl x509 -noout -subject -in "$PKI_DIR/ca-next.crt" | sed 's/^subject=//'))"
      elif [[ -f $PKI_DIR/ca-old.crt ]]; then
        core::die "$E_USAGE" "a CA rotation is already past 'switch' - finish it with: cpctl certs rotate-ca --phase retire"
      else
        log::changed "create next CA (RSA $PKI_KEY_BITS, $PKI_CA_DAYS days)"
        if step::mutating; then pki::_new_ca ca-next "PoC Internal CA $(date +%Y%m%d%H%M)"; fi
      fi
      certs::rollout
      ;;
    switch)
      if [[ -f $PKI_DIR/ca-next.crt ]]; then
        log::changed "signing CA: ca-next -> ca, previous CA stays trusted as ca-old"
        if step::mutating; then
          certs::_archive_ca ca.crt ca.key ca.srl
          mv "$PKI_DIR/ca.crt" "$PKI_DIR/ca-old.crt"
          rm -f "$PKI_DIR/ca.key" "$PKI_DIR/ca.srl"   # the old CA never signs again (copy kept in archive/)
          mv "$PKI_DIR/ca-next.crt" "$PKI_DIR/ca.crt"
          mv "$PKI_DIR/ca-next.key" "$PKI_DIR/ca.key"
        fi
      elif [[ -f $PKI_DIR/ca-old.crt ]]; then
        log::ok "signing CA already switched (resuming the rollout)"
      else
        core::die "$E_USAGE" "no CA rotation in progress - start with: cpctl certs rotate-ca --phase add"
      fi
      # every leaf is now "not signed by ca.crt" -> pki::needs_issue re-issues all of them
      certs::rollout
      if step::mutating; then
        certs::served || core::die "$E_GATE" "some services still present an old-CA certificate"
        log::warn "hand the re-issued app certificates to the application teams ($(inv::apps rest | paste -sd' ' -))"
      fi
      ;;
    retire)
      [[ -f $PKI_DIR/ca-next.crt ]] && core::die "$E_USAGE" "ca-next exists: run --phase switch first"
      if [[ -f $PKI_DIR/ca-old.crt ]]; then
        local n
        for n in $(pki::leaves); do
          openssl verify -CAfile "$PKI_DIR/ca.crt" "$PKI_DIR/$n.crt" >/dev/null 2>&1 ||
            core::die "$E_GATE" "$n.crt is not signed by the current CA - not retiring the old CA"
        done
        if step::mutating; then certs::served || core::die "$E_GATE" "a service still presents an old certificate - not retiring"; fi
        log::changed "retire old CA $(openssl x509 -noout -subject -in "$PKI_DIR/ca-old.crt" | sed 's/^subject=//')"
        if step::mutating; then certs::_archive_ca ca-old.crt && rm -f "$PKI_DIR/ca-old.crt"; fi
      else
        log::ok "no old CA in the trust bundle"
      fi
      certs::rollout
      ;;
    *) core::die "$E_USAGE" "usage: cpctl certs rotate-ca --phase add|switch|retire" ;;
  esac
}

certs::main() {
  local sub=${1:-}; shift || true
  role::common_vars
  case $sub in
    status) certs::status ;;
    rotate) certs::rotate "$@" ;;
    rotate-ca) certs::rotate_ca "$@" ;;
    *) core::die "$E_USAGE" "usage: cpctl certs status|rotate [--cert a,b|all]|rotate-ca --phase add|switch|retire" ;;
  esac
}
