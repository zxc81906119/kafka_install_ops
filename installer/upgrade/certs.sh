#!/usr/bin/env bash
# cpctl certs status | rotate [--cert NAME[,NAME]] | rotate-ca --phase add|switch|retire
#
# Leaf rotation (yearly): re-issue the shared certificates, push, rolling restart behind health gates.
#   Default set = kafka-internal,cp-server + the service identities (SERVICE_CERTS). App client certs (legacy REST apps) only with --cert / --cert all,
#   because the new key + certificate must also be handed to the application team.
#
# CA rotation (three runs, each one a complete rolling restart; zero downtime because every node trusts
# old AND new CA while certificates are being switched):
#   add     create ca-next, trust bundle = ca + ca-next  -> every truststore / OS / JDK store trusts both
#   switch  ca-next becomes the signing CA, the old one stays trusted as ca-old; every leaf is re-issued
#           (legacy apps: hand out their new certificate now - their old one keeps working until retire)
#   retire  drop ca-old from the bundle; only after every node and app presents a new-CA certificate
#
# External CA (PKI_MODE=external, the bank signs) - same three phases, driven by the bank:
#   cpctl certs trust add <root.pem>      every node trusts the new root as well        (= add)
#   cpctl certs rotate --cert all         requests -> bank signs -> run again: import  (= switch)
#   cpctl certs trust remove <name>       drop the old root / "internal" = our own CA   (= retire)
# The migration internal CA -> bank CA is exactly this sequence (manual 9.4).
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
  local names
  names=$(printf '%s\n' kafka-internal cp-server ${SERVICE_CERTS:-} | paste -sd, -)
  while [[ $# -gt 0 ]]; do
    case $1 in
      --cert) names=$2; shift 2 ;;
      *) core::die "$E_USAGE" "unknown option $1" ;;
    esac
  done
  log::step "==== certificate rotation: $names"
  export CPCTL_PKI_REISSUE=$names
  if pki::external; then
    # pass 1 writes the requests and stops; pass 2 (after the bank answered) imports and rolls out.
    # While any request is open, only import - never request again what the bank already answered.
    if [[ -n $(pki::pending) ]]; then
      log::info "open requests: $(pki::pending | paste -sd' ' -) - importing the answers in incoming/"
      export CPCTL_PKI_REISSUE=""
    fi
    CPCTL_FORCE=1 step::run 03_pki
    local n open=()
    for n in $(pki::pending); do [[ -f $PKI_DIR/incoming/$n.crt ]] || open+=("$n"); done
    if ((${#open[@]} > 0)); then
      log::warn "requests for the bank: ${open[*]}"
      log::warn "hand over $PKI_DIR/requests/<name>.csr + <name>.req.txt; put each answer into $PKI_DIR/incoming/<name>.crt"
      log::warn "then run again: cpctl certs rotate --cert $(core::join , "${open[@]}")   (the running services keep their current certificates)"
      return 0
    fi
  fi
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
  if pki::external; then
    core::die "$E_USAGE" "PKI_MODE=external: the bank rotates its CA - cpctl certs trust add <new root> / certs rotate --cert all / certs trust remove <old root>"
  fi
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

# ---- trust anchors supplied from outside (bank roots): trust/<name>.pem --------------------------------

certs::trust_list() {
  local f
  for f in $(pki::roots); do
    log::info "$(basename "$f" .pem): $(pki::subject "$f"), until $(date -d "$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)" +%F), sha256 $(openssl x509 -noout -fingerprint -sha256 -in "$f" | cut -d= -f2)"
  done
  [[ -f $PKI_DIR/ca.crt ]] && log::info "internal: $(pki::subject "$PKI_DIR/ca.crt") (cpctl's own CA)"
  return 0
}

# certs trust add <file> [--name N] -> check it is a CA certificate, store as trust/<N>.pem, roll out
certs::trust_add() {
  local file="" name="" rollout=1
  while [[ $# -gt 0 ]]; do
    case $1 in
      --name) name=$2; shift 2 ;;
      --no-rollout) rollout=0; shift ;;   # first install: the anchor is needed before step 03 ever ran
      -*) core::die "$E_USAGE" "unknown option $1" ;;
      *) file=$1; shift ;;
    esac
  done
  [[ -f $file ]] || core::die "$E_USAGE" "usage: cpctl certs trust add <root.pem> [--name bank-root-g1]"
  [[ $(grep -c 'BEGIN CERTIFICATE' "$file") == 1 ]] || core::die "$E_USAGE" "$file must contain exactly one certificate"
  [[ $(openssl x509 -in "$file" -noout -ext basicConstraints 2>/dev/null) == *CA:TRUE* ]] ||
    core::die "$E_USAGE" "$file is not a CA certificate (basicConstraints CA:TRUE missing)"
  openssl x509 -checkend $((365 * 86400)) -noout -in "$file" >/dev/null ||
    core::die "$E_USAGE" "$file expires within a year"
  [[ -n $name ]] || name=$(basename "$file" | sed 's/\.[^.]*$//')
  [[ $name =~ ^[A-Za-z0-9._-]+$ && $name != internal ]] || core::die "$E_USAGE" "invalid name '$name'"
  local fp
  fp=$(openssl x509 -noout -fingerprint -sha256 -in "$file" | cut -d= -f2)
  log::info "trust anchor $name: $(pki::subject "$file")"
  log::info "  SHA-256 fingerprint $fp  <- compare with the value the bank published (separate channel)"
  [[ $(openssl x509 -noout -subject_hash -in "$file") == "$(openssl x509 -noout -issuer_hash -in "$file")" ]] ||
    log::warn "  not self-signed: an intermediate as trust anchor (accepted: only certificates under it are trusted)"
  if [[ -f $PKI_DIR/trust/$name.pem ]] && [[ $(core::sha256 "$PKI_DIR/trust/$name.pem") == $(core::sha256 "$file") ]]; then
    log::ok "trust/$name.pem present"
  else
    [[ -f $PKI_DIR/trust/$name.pem ]] && core::die "$E_USAGE" "trust/$name.pem exists with other content - choose another --name"
    log::changed "trust anchor added: trust/$name.pem"
    if step::mutating; then
      install -d -m 0750 "$PKI_DIR/trust"
      openssl x509 -in "$file" -out "$PKI_DIR/trust/$name.pem"
      chmod 0644 "$PKI_DIR/trust/$name.pem"
    fi
  fi
  if ((rollout)); then certs::rollout; else log::info "not rolled out (--no-rollout): cpctl install picks it up"; fi
}

# certs trust remove <name|internal> -> only when every certificate and every served endpoint chains to the rest
certs::trust_remove() {
  local name=${1:-} f keep n
  [[ -n $name ]] || core::die "$E_USAGE" "usage: cpctl certs trust remove <name>|internal"
  if [[ $name == internal ]]; then
    pki::external || core::die "$E_USAGE" "PKI_MODE=internal still needs its own CA - set PKI_MODE=external first"
    f=$PKI_DIR/ca.crt
  else
    f=$PKI_DIR/trust/$name.pem
  fi
  if [[ ! -f $f ]]; then
    log::ok "trust anchor $name not present"
    certs::rollout
    return 0
  fi
  # what stays trusted
  keep=$(mktemp)
  : >"$keep"
  for n in $(pki::roots); do [[ $n == "$f" ]] || cat "$n" >>"$keep"; done
  if ! pki::external; then cat "$PKI_DIR/ca.crt" >>"$keep"; fi
  [[ -s $keep ]] || core::die "$E_GATE" "removing $name would leave no trust anchor"
  for n in $(pki::leaves); do
    pki::verify_with "$keep" "$PKI_DIR/$n.crt" ||
      { rm -f "$keep"; core::die "$E_GATE" "$n.crt still depends on $name ($(pki::issuer "$PKI_DIR/$n.crt")) - rotate it first: cpctl certs rotate --cert $n"; }
  done
  rm -f "$keep"
  [[ -n $(pki::pending) ]] && core::die "$E_GATE" "open certificate requests: $(pki::pending | paste -sd' ' -) - finish them first"
  if step::mutating; then certs::served || core::die "$E_GATE" "a service still presents an old certificate - not removing $name"; fi
  log::changed "remove trust anchor $name ($(pki::subject "$f"))"
  if step::mutating; then
    if [[ $name == internal ]]; then
      certs::_archive_ca ca.crt ca.key ca.srl ca-next.crt ca-next.key ca-old.crt
      rm -f "$PKI_DIR"/ca.crt "$PKI_DIR"/ca.key "$PKI_DIR"/ca.srl "$PKI_DIR"/ca-next.* "$PKI_DIR"/ca-old.crt
      log::warn "the internal CA private key is now only in $PKI_DIR/archive/ - store it offline or destroy it"
    else
      certs::_archive_ca "trust/$name.pem"
      rm -f "$f"
    fi
  fi
  certs::rollout
}

certs::trust() {
  local sub=${1:-}; shift || true
  case $sub in
    list) certs::trust_list ;;
    add) certs::trust_add "$@" ;;
    remove) certs::trust_remove "$@" ;;
    *) core::die "$E_USAGE" "usage: cpctl certs trust list|add <root.pem> [--name N]|remove <name>|internal" ;;
  esac
}

certs::main() {
  local sub=${1:-}; shift || true
  role::common_vars
  case $sub in
    status) certs::status ;;
    rotate) certs::rotate "$@" ;;
    rotate-ca) certs::rotate_ca "$@" ;;
    trust) certs::trust "$@" ;;
    *) core::die "$E_USAGE" "usage: cpctl certs status|rotate [--cert a,b|all]|rotate-ca --phase add|switch|retire|trust list|add|remove" ;;
  esac
}
