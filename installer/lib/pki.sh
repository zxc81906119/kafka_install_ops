#!/usr/bin/env bash
# Internal PKI on the ops host: CA, the two shared certificates, per-app client certificates,
# MDS token key pair. Everything is regenerated only when missing, expiring or when SANs changed.
[[ -n ${_LIB_PKI_LOADED:-} ]] && return 0
_LIB_PKI_LOADED=1

readonly PKI_SUBJECT_SUFFIX="/OU=Confluent/O=PoC Bank/C=TW"

pki::keytool() { "$(install::java_home)/bin/keytool" "$@"; }

# Files under $PKI_DIR:
#   ca.crt / ca.key           the SIGNING CA (issues every leaf certificate)
#   ca-next.*  / ca-old.crt   only during a CA rotation (phase add / switch)
#   ca.pem                    the TRUST BUNDLE = ca.crt + ca-next.crt + ca-old.crt (whatever exists);
#                             this is what every node, truststore, OS / JDK trust store and client uses
# pki::needs_issue <cert> <wanted SAN list (comma separated, sorted)>
pki::needs_issue() {
  local crt=$1 want=$2 have
  [[ -f $crt ]] || return 0
  # cpctl certs rotate: CPCTL_PKI_REISSUE = "all" or comma separated names; once per run
  if [[ -n ${CPCTL_PKI_REISSUE:-} && ! -f $RUN_DIR/reissued.$(basename "$crt") ]]; then
    [[ $CPCTL_PKI_REISSUE == all || ,$CPCTL_PKI_REISSUE, == *,$(basename "$crt" .crt),* ]] && return 0
  fi
  openssl x509 -checkend $((PKI_RENEW_BEFORE_DAYS * 86400)) -noout -in "$crt" >/dev/null || return 0
  # signed by the current signing CA? (false after "rotate-ca --phase switch" -> re-issue)
  openssl verify -CAfile "$PKI_DIR/ca.crt" "$crt" >/dev/null 2>&1 || return 0
  [[ -z $want ]] && return 1
  have=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tail -n +2 |
    tr ',' '\n' | sed 's/^ *DNS://; s/^ *IP Address://' | sort -u | paste -sd, -)
  [[ $have != "$want" ]]
}

pki::_new_ca() { # <basename> <CN>
  openssl genrsa -out "$PKI_DIR/$1.key" "$PKI_KEY_BITS" 2>/dev/null
  chmod 0600 "$PKI_DIR/$1.key"
  openssl req -x509 -new -key "$PKI_DIR/$1.key" -sha256 -days "$PKI_CA_DAYS" -out "$PKI_DIR/$1.crt" \
    -subj "/CN=$2$PKI_SUBJECT_SUFFIX" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
}

pki::ca() {
  local crt=$PKI_DIR/ca.crt
  # migration from layouts where ca.pem was the (single) signing CA
  if [[ ! -f $crt && -f $PKI_DIR/ca.pem && -f $PKI_DIR/ca.key ]] && step::mutating; then
    cp -p "$PKI_DIR/ca.pem" "$crt"
    log::changed "PKI layout: signing CA now ca.crt, ca.pem becomes the trust bundle"
  fi
  if [[ -f $crt ]] && openssl x509 -checkend $((365 * 86400)) -noout -in "$crt" >/dev/null; then
    log::ok "signing CA valid until $(openssl x509 -enddate -noout -in "$crt" | cut -d= -f2)"
  else
    log::changed "create internal CA (RSA $PKI_KEY_BITS, $PKI_CA_DAYS days)"
    step::mutating || return 0
    pki::_new_ca ca "PoC Internal CA $(date +%Y%m%d)"
  fi
  pki::bundle
}

# pki::bundle -> rebuild ca.pem (trust bundle) from the CAs currently trusted
pki::bundle() {
  local t f
  t=$(mktemp)
  for f in ca.crt ca-next.crt ca-old.crt; do [[ -f $PKI_DIR/$f ]] && cat "$PKI_DIR/$f" >>"$t"; done
  # sha256, not cmp: minimal hosts have no diffutils
  if [[ -f $PKI_DIR/ca.pem && $(core::sha256 "$t") == $(core::sha256 "$PKI_DIR/ca.pem") ]]; then
    log::ok "trust bundle current ($(grep -c 'BEGIN CERTIFICATE' "$t") CA)"
    rm -f "$t"
    return 0
  fi
  log::changed "trust bundle ca.pem: $(grep -c 'BEGIN CERTIFICATE' "$t") CA ($(cd "$PKI_DIR" && ls ca.crt ca-next.crt ca-old.crt 2>/dev/null | paste -sd' ' -))"
  if step::mutating; then install -m 0644 "$t" "$PKI_DIR/ca.pem"; fi
  rm -f "$t"
}

# pki::split_bundle <bundle> <dir>  -> one file per CA certificate (ca-1.pem, ca-2.pem, ...)
pki::split_bundle() {
  awk -v d="$2" '/BEGIN CERTIFICATE/ {n++} {print > (d "/ca-" n ".pem")}' "$1"
}

# pki::issue <name> <comma separated DNS SANs or ""> [serverAuth,clientAuth]
# Produces <name>.key <name>.crt <name>.p12 (key + chain) under $PKI_DIR.
pki::issue() {
  local name=$1 sans=$2 eku=${3:-serverAuth,clientAuth}
  local key=$PKI_DIR/$name.key crt=$PKI_DIR/$name.crt csr=$PKI_DIR/$name.csr ext
  local want
  want=$(tr ',' '\n' <<<"$sans" | sed '/^$/d' | sort -u | paste -sd, -)
  if ! pki::needs_issue "$crt" "$want"; then
    log::ok "certificate $name valid, SANs match"
    return 0
  fi
  log::changed "issue certificate CN=$name (${want:-no SAN}; $eku; $PKI_CERT_DAYS days)"
  step::mutating || return 0
  ext=$(mktemp)
  {
    printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
    printf 'extendedKeyUsage=%s\n' "$eku"
    [[ -n $want ]] && printf 'subjectAltName=%s\n' "$(tr ',' '\n' <<<"$want" | sed 's/^/DNS:/' | paste -sd, -)"
  } >"$ext"
  # archive the previous certificate (rotation evidence / emergency rollback)
  if [[ -f $crt ]]; then
    local arch
    arch="$PKI_DIR/archive/$(date +%Y%m%d-%H%M%S)"
    install -d -m 0700 "$arch"
    cp -p "$PKI_DIR/$name".* "$arch/" 2>/dev/null || true
  fi
  openssl genrsa -out "$key" "$PKI_KEY_BITS" 2>/dev/null
  chmod 0600 "$key"
  openssl req -new -key "$key" -out "$csr" -subj "/CN=$name$PKI_SUBJECT_SUFFIX"
  openssl x509 -req -in "$csr" -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
    -days "$PKI_CERT_DAYS" -sha256 -extfile "$ext" -out "$crt" 2>/dev/null
  rm -f "$ext" "$csr"
  openssl pkcs12 -export -name "$name" -inkey "$key" -in "$crt" -certfile "$PKI_DIR/ca.crt" \
    -passout "pass:$STORE_PASSWORD" -out "$PKI_DIR/$name.p12"
  cat "$crt" "$PKI_DIR/ca.crt" >"$PKI_DIR/$name.chain.pem"
  touch "$RUN_DIR/reissued.$name.crt"
}

# truststore.p12 = every CA of the trust bundle (aliases internal-ca-1..N); rebuilt when the bundle changes
pki::truststore() {
  local ts=$PKI_DIR/truststore.p12 mark=$PKI_DIR/truststore.bundle.sha256 sha
  sha=$(core::sha256 "$PKI_DIR/ca.pem")
  if [[ -f $ts && -f $mark && $(cat "$mark") == "$sha" ]]; then
    log::ok "truststore matches the trust bundle"
    return 0
  fi
  log::changed "build truststore.p12 from the trust bundle ($(grep -c 'BEGIN CERTIFICATE' "$PKI_DIR/ca.pem") CA)"
  step::mutating || return 0
  local d f i=0
  d=$(mktemp -d)
  pki::split_bundle "$PKI_DIR/ca.pem" "$d"
  rm -f "$ts"
  for f in "$d"/ca-*.pem; do
    i=$((i + 1))
    pki::keytool -importcert -noprompt -alias "internal-ca-$i" -file "$f" \
      -keystore "$ts" -storetype PKCS12 -storepass "$STORE_PASSWORD" >/dev/null
  done
  rm -rf "$d"
  printf '%s' "$sha" >"$mark"
}

# pki::leaves -> the leaf certificates cpctl manages (shared certs + client certs of legacy REST apps)
pki::leaves() {
  printf '%s\n' kafka-internal cp-server
  [[ ${OPMENU:-off} == on ]] && printf '%s\n' "$OPMENU_BREAKGLASS"
  inv::apps rest
}

# pki::truststore_named <file> <password>  -> PKCS12 truststore of the trust bundle with its own password
# (for consumers outside the cluster, e.g. the bastion: never hand out STORE_PASSWORD, which also opens keystores)
pki::truststore_named() {
  local ts=$1 pw=$2 mark="$1.bundle.sha256" sha d f i=0
  sha=$(core::sha256 "$PKI_DIR/ca.pem")
  if [[ -f $ts && -f $mark && $(cat "$mark") == "$sha" ]]; then return 0; fi
  step::mutating || return 0
  d=$(mktemp -d)
  pki::split_bundle "$PKI_DIR/ca.pem" "$d"
  rm -f "$ts"
  for f in "$d"/ca-*.pem; do
    i=$((i + 1))
    pki::keytool -importcert -noprompt -alias "internal-ca-$i" -file "$f" -keystore "$ts" -storetype PKCS12 -storepass "$pw" >/dev/null
  done
  rm -rf "$d"
  printf '%s' "$sha" >"$mark"
  log::changed "truststore $(basename "$ts") rebuilt from the trust bundle"
}

# pki::prune -> leaf certificates no longer managed (e.g. an app moved from REST to SCRAM) leave the
# working directory for archive/retired-<ts>/ so they are neither rotated, trusted nor handed out again
pki::prune() {
  local f n arch="" managed
  # captured once: "pki::leaves | grep -q" SIGPIPEs under pipefail and once archived the managed cp-server
  managed=" $(pki::leaves | paste -sd' ' -) "
  [[ $managed == *" kafka-internal "* && $managed == *" cp-server "* ]] || core::die "pki::prune: managed list broken: $managed"
  for f in "$PKI_DIR"/*.crt; do
    [[ -f $f ]] || continue
    n=$(basename "$f" .crt)
    [[ $n == ca || $n == ca-next || $n == ca-old ]] && continue
    [[ $managed == *" $n "* ]] && continue
    log::changed "retire unmanaged certificate $n (moved to archive/)"
    step::mutating || continue
    [[ -n $arch ]] || { arch="$PKI_DIR/archive/retired-$(date +%Y%m%d-%H%M%S)"; install -d -m 0700 "$arch"; }
    mv "$PKI_DIR/$n".{crt,key,p12,chain.pem} "$arch/" 2>/dev/null || true
  done
  return 0
}

# pki::status -> one line per certificate (CAs first): issuer, expiry, days left.
# rc 0 = all fine, 2 = something expires within PKI_RENEW_BEFORE_DAYS or is not signed by the signing CA
pki::status() {
  local f n end days rc=0 kind
  for n in ca ca-next ca-old $(pki::leaves); do
    f=$PKI_DIR/$n.crt
    [[ -f $f ]] || continue
    case $n in ca) kind="signing CA" ;; ca-next) kind="next CA (rotation)" ;; ca-old) kind="old CA (rotation)" ;; *) kind=leaf ;; esac
    end=$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)
    days=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
    if ((days < PKI_RENEW_BEFORE_DAYS)); then
      log::warn "certificate $n ($kind) expires $(date -d "$end" +%F) ($days days) - run: cpctl certs rotate"
      rc=2
    elif [[ $kind == leaf ]] && ! openssl verify -CAfile "$PKI_DIR/ca.crt" "$f" >/dev/null 2>&1; then
      log::warn "certificate $n is not signed by the current signing CA - run: cpctl certs rotate-ca --phase switch"
      rc=2
    else
      log::ok "certificate $n ($kind) valid until $(date -d "$end" +%F) ($days days)"
    fi
  done
  log::info "trust bundle ca.pem: $(grep -c 'BEGIN CERTIFICATE' "$PKI_DIR/ca.pem" 2>/dev/null || echo 0) CA"
  return "$rc"
}

# pki::served_serial <host:port> -> serial of the certificate a TLS endpoint presents right now
pki::served_serial() {
  openssl s_client -connect "$1" -servername "${1%%:*}" </dev/null 2>/dev/null |
    openssl x509 -noout -serial 2>/dev/null | cut -d= -f2
}
pki::serial() { openssl x509 -noout -serial -in "$PKI_DIR/$1.crt" | cut -d= -f2; }

pki::mds_keypair() {
  if [[ -f $PKI_DIR/mds-token-keypair.pem && -f $PKI_DIR/mds-public.pem ]]; then
    log::ok "MDS token key pair present"
  else
    log::changed "generate MDS token key pair (RSA 2048)"
    step::mutating || return 0
    openssl genrsa -out "$PKI_DIR/mds-token-keypair.pem" 2048 2>/dev/null
    chmod 0600 "$PKI_DIR/mds-token-keypair.pem"
    openssl rsa -in "$PKI_DIR/mds-token-keypair.pem" -pubout -out "$PKI_DIR/mds-public.pem" 2>/dev/null
  fi
  # Nodes only ever get the encrypted PKCS#8 form (AES-256); the passphrase is itself secret-protected.
  local enc=$PKI_DIR/mds-token-keypair.enc.pem
  if [[ -f $enc ]] && openssl pkey -in "$enc" -passin "pass:$(inv::secret MDS_TOKEN_PASSPHRASE)" -noout 2>/dev/null; then
    log::ok "MDS token key pair encrypted (PKCS#8, AES-256)"
    return 0
  fi
  log::changed "encrypt MDS token private key (PKCS#8, AES-256)"
  step::mutating || return 0
  openssl pkcs8 -topk8 -v2 aes256 -in "$PKI_DIR/mds-token-keypair.pem" \
    -passout "pass:$(inv::secret MDS_TOKEN_PASSPHRASE)" -out "$enc"
  chmod 0600 "$enc"
}

# SAN lists
pki::sans_internal() {
  local h out=()
  for h in $(inv::hosts controller) $(inv::hosts controller_spare) $(inv::hosts broker); do
    out+=("$(inv::fqdn "$h")" "$h")
  done
  core::join , "${out[@]}"
}

pki::sans_server() {
  local h out=()
  for h in $(inv::all_hosts) $(inv::hosts controller_spare); do out+=("$(inv::fqdn "$h")" "$h"); done
  out+=("$LB_REST_NAME" "$LB_C3_NAME" localhost)
  core::join , "${out[@]}"
}
