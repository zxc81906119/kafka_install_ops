#!/usr/bin/env bash
# PKI on the ops host: the two shared certificates, per-app client certificates, MDS token key pair.
# Certificates are (re)issued only when missing, expiring, SANs changed or not issued by the current issuer.
#   PKI_MODE=internal  cpctl's own CA (ca.crt / ca.key) signs every certificate
#   PKI_MODE=external  the bank's PKI signs; cpctl holds NO CA key:
#                        pending/<name>.key   new private key (never leaves the ops host)
#                        requests/<name>.csr + <name>.req.txt   -> handed to the bank
#                        incoming/<name>.crt  <- the bank's answer (leaf + intermediates, any order)
#                      the import checks key match, CN, SAN, EKU, validity and the chain to trust/*.pem
# trust/*.pem = trust anchors supplied from outside (bank roots). Honoured in BOTH modes, so a migration
# internal -> external first trusts both, then switches the certificates, then drops the internal CA.
[[ -n ${_LIB_PKI_LOADED:-} ]] && return 0
_LIB_PKI_LOADED=1

PKI_SUBJECT_SUFFIX=${PKI_SUBJECT_SUFFIX:-/OU=Confluent/O=PoC Bank/C=TW}

pki::keytool() { "$(install::java_home)/bin/keytool" "$@"; }

pki::external() { [[ ${PKI_MODE:-internal} == external ]]; }

# pki::roots -> the trust anchors supplied from outside (trust/*.pem), one path per line
pki::roots() {
  local f
  for f in "$PKI_DIR"/trust/*.pem; do [[ -f $f ]] && printf '%s\n' "$f"; done
  return 0
}

# pki::_cat_roots <out file>   (empty file when there are none)
pki::_cat_roots() {
  local f
  : >"$1"
  while read -r f; do [[ -n $f ]] && cat "$f" >>"$1"; done < <(pki::roots)
  return 0
}

# pki::verify_with <CA file> <crt> -> the leaf (first certificate of <crt>) chains to a CA of the file; further
# certificates in <crt> serve as intermediates. -partial_chain: a dedicated bank intermediate may be the anchor.
pki::verify_with() {
  [[ -s $1 && -f $2 ]] || return 1
  openssl verify -partial_chain -CAfile "$1" -untrusted "$2" "$2" >/dev/null 2>&1
}

# pki::verify_current <crt> -> issued by the CURRENT issuer (internal: ca.crt, external: a trust/ anchor)
pki::verify_current() {
  local ca rc=1
  if pki::external; then
    ca=$(mktemp)
    pki::_cat_roots "$ca"
    if pki::verify_with "$ca" "$1"; then rc=0; fi
    rm -f "$ca"
    return "$rc"
  fi
  pki::verify_with "$PKI_DIR/ca.crt" "$1"
}

# pki::verify_trusted <crt> -> chains to the trust bundle ca.pem (what every node trusts right now)
pki::verify_trusted() { pki::verify_with "$PKI_DIR/ca.pem" "$1"; }

# pki::sans <crt> -> DNS / IP SANs, sorted, comma separated
pki::sans() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 |
    tr ',' '\n' | sed 's/^ *DNS://; s/^ *IP Address://; /^ *$/d' | sort -u | paste -sd, -
}

# "re-issued in this run" marker: cpctl certs rotate re-issues a certificate once per run, not on every step
pki::_mark() { printf '%s/%s.reissued.%s' "$RUN_DIR" "$CPCTL_RUN_ID" "$1"; }

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
  if [[ -n ${CPCTL_PKI_REISSUE:-} && ! -f $(pki::_mark "$(basename "$crt" .crt)") ]]; then
    [[ $CPCTL_PKI_REISSUE == all || ,$CPCTL_PKI_REISSUE, == *,$(basename "$crt" .crt),* ]] && return 0
  fi
  openssl x509 -checkend $((PKI_RENEW_BEFORE_DAYS * 86400)) -noout -in "$crt" >/dev/null || return 0
  # issued by the current issuer? (false after "rotate-ca --phase switch" or PKI_MODE=external -> re-issue)
  pki::verify_current "$crt" || return 0
  [[ -z $want ]] && return 1
  have=$(pki::sans "$crt")
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
  if pki::external; then
    pki::trust_anchors
    pki::bundle
    return 0
  fi
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

# pki::trust_anchors (external mode) -> the bank roots are present and still valid
pki::trust_anchors() {
  local f n=0 end
  while read -r f; do
    [[ -n $f ]] || continue
    n=$((n + 1))
    end=$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)
    openssl x509 -checkend 0 -noout -in "$f" >/dev/null || core::die "$E_PRECHECK" "trust anchor $(basename "$f") expired $end"
    log::ok "trust anchor $(basename "$f" .pem): $(pki::subject "$f") (until $(date -d "$end" +%F))"
  done < <(pki::roots)
  ((n > 0)) || core::die "$E_PRECHECK" "PKI_MODE=external but no bank root in $PKI_DIR/trust/ - run: cpctl certs trust add <root.pem>"
  if [[ -f $PKI_DIR/ca.crt ]]; then
    log::info "internal CA still in the trust bundle (migration) - retire it with: cpctl certs trust remove internal"
  fi
}

pki::subject() { openssl x509 -noout -subject -nameopt oneline -in "$1" | sed 's/^subject= *//'; }
pki::issuer() { openssl x509 -noout -issuer -nameopt oneline -in "$1" | sed 's/^issuer= *//'; }

# pki::bundle -> rebuild ca.pem (trust bundle) from the CAs currently trusted
pki::bundle() {
  local t f
  t=$(mktemp)
  for f in ca.crt ca-next.crt ca-old.crt; do [[ -f $PKI_DIR/$f ]] && cat "$PKI_DIR/$f" >>"$t"; done
  while read -r f; do [[ -n $f ]] && cat "$f" >>"$t"; done < <(pki::roots)
  [[ -s $t ]] || core::die "$E_PRECHECK" "the trust bundle would be empty"
  # sha256, not cmp: minimal hosts have no diffutils
  if [[ -f $PKI_DIR/ca.pem && $(core::sha256 "$t") == $(core::sha256 "$PKI_DIR/ca.pem") ]]; then
    log::ok "trust bundle current ($(grep -c 'BEGIN CERTIFICATE' "$t") CA)"
    rm -f "$t"
    return 0
  fi
  log::changed "trust bundle ca.pem: $(grep -c 'BEGIN CERTIFICATE' "$t") CA ($(cd "$PKI_DIR" && ls ca.crt ca-next.crt ca-old.crt trust/*.pem 2>/dev/null | paste -sd' ' -))"
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
  if pki::external; then
    pki::_issue_external "$name" "$want" "$eku"
    return 0
  fi
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
  pki::_archive "$name"   # previous certificate: rotation evidence / emergency rollback
  openssl genrsa -out "$key" "$PKI_KEY_BITS" 2>/dev/null
  chmod 0600 "$key"
  openssl req -new -key "$key" -out "$csr" -subj "/CN=$name$PKI_SUBJECT_SUFFIX"
  openssl x509 -req -in "$csr" -CA "$PKI_DIR/ca.crt" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
    -days "$PKI_CERT_DAYS" -sha256 -extfile "$ext" -out "$crt" 2>/dev/null
  rm -f "$ext" "$csr"
  openssl pkcs12 -export -name "$name" -inkey "$key" -in "$crt" -certfile "$PKI_DIR/ca.crt" \
    -passout "pass:$STORE_PASSWORD" -out "$PKI_DIR/$name.p12"
  cat "$crt" "$PKI_DIR/ca.crt" >"$PKI_DIR/$name.chain.pem"
  touch "$(pki::_mark "$name")"
}

# pki::_archive <name> -> copy the current files of a certificate to archive/<ts>/
pki::_archive() {
  local arch
  [[ -f $PKI_DIR/$1.crt ]] || return 0
  arch="$PKI_DIR/archive/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$arch"
  cp -p "$PKI_DIR/$1".{crt,key,p12,chain.pem} "$arch/" 2>/dev/null || true
}

# ---- external CA (the bank) ---------------------------------------------------------------------------

pki::_purpose() {
  case $1 in
    kafka-internal) echo "controllers + brokers: CONTROLLER / INTERNAL listeners (server AND client of the same TLS connection), telemetry client to Prometheus" ;;
    cp-server) echo "all servers: Kafka client listeners, MDS, REST Proxy, Control Center, Prometheus, LDAPS; client of C3 / Prometheus towards Prometheus / Alertmanager" ;;
    "${OPMENU_BREAKGLASS:-}") echo "OP menu break-glass identity (client certificate, RBAC SystemAdmin)" ;;
    svc-rest) echo "service identity of REST Proxy towards MDS and Kafka (client certificate, principal User:svc-rest, impersonation)" ;;
    svc-c3) echo "service identity of Control Center towards MDS and Kafka (client certificate, principal User:svc-c3, SystemAdmin)" ;;
    svc-cpctl) echo "service identity of the installer cpctl towards MDS (client certificate, principal User:svc-cpctl, super user)" ;;
    *) echo "client certificate of application $1 (REST Proxy mTLS, principal User:$1)" ;;
  esac
}

# pki::_issue_external <name> <SANs> <eku>
#   open request + answer in incoming/ -> import ; open request only -> waiting ; otherwise request when needed
pki::_issue_external() {
  local name=$1 want=$2 eku=$3
  local key=$PKI_DIR/pending/$name.key in=$PKI_DIR/incoming/$name.crt
  if [[ -f $key && -f $in ]]; then
    log::changed "import the bank-signed certificate $name (incoming/$name.crt)"
    step::mutating || return 0
    pki::import "$name" "$want" "$eku"
    return 0
  fi
  if [[ -f $key ]]; then
    log::warn "certificate $name: waiting for the bank - hand over requests/$name.csr + $name.req.txt, put the answer into $PKI_DIR/incoming/$name.crt"
    return 0
  fi
  [[ -f $in ]] && log::warn "incoming/$name.crt has no open request - ignored (request first: cpctl certs rotate --cert $name)"
  if ! pki::needs_issue "$PKI_DIR/$name.crt" "$want"; then
    log::ok "certificate $name valid, SANs match, issued under a bank root"
    return 0
  fi
  log::changed "certificate request CN=$name (${want:-no SAN}; $eku) -> requests/$name.csr for the bank"
  step::mutating || return 0
  pki::request "$name" "$want" "$eku"
  touch "$(pki::_mark "$name")"
}

# pki::request <name> <SANs> <eku> -> pending/<name>.key, requests/<name>.csr, requests/<name>.req.txt
pki::request() {
  local name=$1 want=$2 eku=$3 key csr sheet san=""
  install -d -m 0700 "$PKI_DIR/pending"
  install -d -m 0750 "$PKI_DIR/requests" "$PKI_DIR/incoming"
  key=$PKI_DIR/pending/$name.key csr=$PKI_DIR/requests/$name.csr sheet=$PKI_DIR/requests/$name.req.txt
  [[ -n $want ]] && san=$(tr ',' '\n' <<<"$want" | sed 's/^/DNS:/' | paste -sd, -)
  openssl genrsa -out "$key" "$PKI_KEY_BITS" 2>/dev/null
  chmod 0600 "$key"
  local ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment"
    -addext "extendedKeyUsage=$eku")
  [[ -n $san ]] && ext+=(-addext "subjectAltName=$san")
  openssl req -new -key "$key" -sha256 -subj "/CN=$name$PKI_SUBJECT_SUFFIX" "${ext[@]}" -out "$csr"
  {
    printf 'Certificate request %s  (cpctl, %s, run %s)\n\n' "$name" "$(date '+%F %T')" "$CPCTL_RUN_ID"
    printf 'Subject            : %s\n' "$(openssl req -in "$csr" -noout -subject -nameopt oneline | sed 's/^subject= *//')"
    printf 'Key                : RSA %s (the private key stays on the ops host)\n' "$PKI_KEY_BITS"
    printf 'Validity requested : %s days\n' "$PKI_CERT_DAYS"
    printf 'Key usage          : digitalSignature, keyEncipherment\n'
    printf 'Extended key usage : %s\n' "${eku//,/, }"
    if [[ $eku == *serverAuth* && $eku == *clientAuth* ]]; then
      printf '                     BOTH are required: the service presents this certificate as server and as client\n'
    fi
    printf 'SAN (DNS)          : %s\n' "${want:-none}"
    printf 'Used by            : %s\n' "$(pki::_purpose "$name")"
    printf 'Return format      : PEM - the certificate followed by the issuing intermediate CA(s); the root is optional\n'
    printf 'CSR SHA-256        : %s\n' "$(core::sha256 "$csr")"
  } >"$sheet"
}

pki::_reject() { # <name> <reason>
  core::die "$E_GATE" "certificate $1 REJECTED: $2 - nothing was installed; ask the bank for a corrected certificate (request sheet: requests/$1.req.txt)"
}

# pki::check_signed <name> <SANs> <eku> <answer file> <private key> -> prints "<work dir> <chain file>",
# chain = leaf followed by its intermediates in issuing order (self-signed roots left out). Dies with the reason.
pki::check_signed() {
  local name=$1 want=$2 eku=$3 in=$4 key=$5
  local d f leaf="" kp cn have e u nb roots chain cur next i
  d=$(mktemp -d)
  pki::split_bundle "$in" "$d"
  kp=$(openssl pkey -in "$key" -pubout 2>/dev/null)
  for f in "$d"/ca-*.pem; do
    [[ -f $f ]] || continue
    if [[ $(openssl x509 -in "$f" -noout -pubkey 2>/dev/null) == "$kp" ]]; then leaf=$f; break; fi
  done
  [[ -n $leaf ]] || pki::_reject "$name" "no certificate in the file matches the pending private key (wrong file, or the answer to another request)"
  cn=$(openssl x509 -in "$leaf" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')
  [[ $cn == "$name" ]] || pki::_reject "$name" "subject CN is '$cn', requested '$name' (the CN is the Kafka / RBAC principal)"
  if [[ $(openssl x509 -in "$leaf" -noout -ext basicConstraints 2>/dev/null) == *CA:TRUE* ]]; then
    pki::_reject "$name" "it is a CA certificate"
  fi
  have=$(pki::sans "$leaf")
  [[ $have == "$want" ]] || pki::_reject "$name" "SAN differs - requested [${want:-none}], received [${have:-none}]"
  e=$(openssl x509 -in "$leaf" -noout -ext extendedKeyUsage 2>/dev/null | tail -n +2 | sed 's/^ *//')
  for u in ${eku//,/ }; do
    case $u in
      serverAuth) [[ $e == *"TLS Web Server Authentication"* ]] ;;
      clientAuth) [[ $e == *"TLS Web Client Authentication"* ]] ;;
    esac || pki::_reject "$name" "extended key usage lacks $u (received: ${e:-none})"
  done
  nb=$(openssl x509 -startdate -noout -in "$leaf" | cut -d= -f2)
  (($(date -d "$nb" +%s) <= $(date +%s) + 300)) || pki::_reject "$name" "not valid before $nb (clock skew?)"
  openssl x509 -checkend $((PKI_RENEW_BEFORE_DAYS * 86400)) -noout -in "$leaf" >/dev/null ||
    pki::_reject "$name" "expires $(openssl x509 -enddate -noout -in "$leaf" | cut -d= -f2), within PKI_RENEW_BEFORE_DAYS=$PKI_RENEW_BEFORE_DAYS"
  # chain in issuing order: leaf, the intermediate that issued it, ... (each issuer looked up in the file)
  chain=$d/chain.pem
  cat "$leaf" >"$chain"
  cur=$leaf
  for i in 1 2 3 4 5; do
    next=""
    for f in "$d"/ca-*.pem; do
      [[ $f == "$leaf" || $f == "$cur" ]] && continue
      [[ $(openssl x509 -in "$f" -noout -subject_hash) == "$(openssl x509 -in "$f" -noout -issuer_hash)" ]] && continue
      [[ $(openssl x509 -in "$f" -noout -subject_hash) == "$(openssl x509 -in "$cur" -noout -issuer_hash)" ]] || continue
      next=$f
      break
    done
    [[ -n $next ]] || break
    cat "$next" >>"$chain"
    cur=$next
  done
  : "$i"
  roots=$d/roots.pem
  pki::_cat_roots "$roots"
  if ! pki::verify_with "$roots" "$chain"; then
    e=$(openssl verify -partial_chain -CAfile "$roots" -untrusted "$chain" "$chain" 2>&1 | grep -m1 'error' || true)
    pki::_reject "$name" "does not chain to a bank root in trust/ (${e:-no trust anchor}) - the file must contain the issuing intermediate CA"
  fi
  printf '%s %s\n' "$d" "$chain"
}

# pki::import <name> <SANs> <eku> -> after the checks: <name>.crt (leaf + intermediates), .key, .p12, .chain.pem
pki::import() {
  local name=$1 want=$2 eku=$3
  local in=$PKI_DIR/incoming/$1.crt key=$PKI_DIR/pending/$1.key
  local out d chain arch
  out=$(pki::check_signed "$name" "$want" "$eku" "$in" "$key") || exit "$?"
  d=${out%% *} chain=${out#* }
  pki::_archive "$name"
  install -m 0600 "$key" "$PKI_DIR/$name.key"
  install -m 0640 "$chain" "$PKI_DIR/$name.crt"
  install -m 0640 "$chain" "$PKI_DIR/$name.chain.pem"
  openssl pkcs12 -export -name "$name" -inkey "$PKI_DIR/$name.key" -in "$PKI_DIR/$name.crt" \
    -passout "pass:$STORE_PASSWORD" -out "$PKI_DIR/$name.p12"
  arch="$PKI_DIR/archive/$(date +%Y%m%d-%H%M%S)-request-$name"
  install -d -m 0700 "$arch"
  mv "$in" "$PKI_DIR/requests/$name.csr" "$PKI_DIR/requests/$name.req.txt" "$arch/" 2>/dev/null || true
  rm -f "$key"
  rm -rf "$d"
  touch "$(pki::_mark "$name")"
  log::changed "imported $name: serial $(pki::serial "$name"), issuer $(pki::issuer "$PKI_DIR/$name.crt"), until $(date -d "$(openssl x509 -enddate -noout -in "$PKI_DIR/$name.crt" | cut -d= -f2)" +%F)"
}

# pki::pending -> names with an open request (key generated, nothing imported yet)
pki::pending() {
  local f
  for f in "$PKI_DIR"/pending/*.key; do [[ -f $f ]] && basename "$f" .key; done
  return 0
}

# pki::pending_gate -> stop while an open request has no usable predecessor (first install, expired, untrusted)
pki::pending_gate() {
  local n missing=()
  for n in $(pki::pending); do
    [[ -f $PKI_DIR/incoming/$n.crt ]] && continue
    if [[ -f $PKI_DIR/$n.crt ]] && openssl x509 -checkend 0 -noout -in "$PKI_DIR/$n.crt" >/dev/null &&
      pki::verify_trusted "$PKI_DIR/$n.crt"; then
      continue
    fi
    missing+=("$n")
  done
  ((${#missing[@]} == 0)) && return 0
  core::die "$E_GATE" "waiting for the bank: ${missing[*]} - hand over $PKI_DIR/requests/*.csr + *.req.txt, put each answer into $PKI_DIR/incoming/<name>.crt, then re-run"
}

# pki::export_p12 <name> <password> <out> -> key + certificate chain under another password
pki::export_p12() {
  local extra=()
  pki::external || extra=(-certfile "$PKI_DIR/ca.crt")
  openssl pkcs12 -export -name "$1" -inkey "$PKI_DIR/$1.key" -in "$PKI_DIR/$1.crt" "${extra[@]}" \
    -passout "pass:$2" -out "$3"
}

# truststore.p12 = every CA of the trust bundle (aliases internal-ca-1..N); rebuilt when the bundle changes
# pki::_build_truststore <file> <password> -> PKCS12 with every CA of the bundle (aliases internal-ca-1..N).
# Built next to the target and renamed into place: a client starting during the rebuild must never load a
# missing or half-filled truststore (it would trust nothing - or only some - of the CAs for its whole lifetime).
pki::_build_truststore() {
  local ts=$1 pw=$2 new="$1.new.$$" d f i=0
  d=$(mktemp -d)
  pki::split_bundle "$PKI_DIR/ca.pem" "$d"
  rm -f "$new"
  for f in "$d"/ca-*.pem; do
    i=$((i + 1))
    pki::keytool -importcert -noprompt -alias "internal-ca-$i" -file "$f" -keystore "$new" -storetype PKCS12 -storepass "$pw" >/dev/null
  done
  rm -rf "$d"
  chmod 0640 "$new"
  mv -f "$new" "$ts"
}

pki::truststore() {
  local ts=$PKI_DIR/truststore.p12 mark=$PKI_DIR/truststore.bundle.sha256 sha
  sha=$(core::sha256 "$PKI_DIR/ca.pem")
  if [[ -f $ts && -f $mark && $(cat "$mark") == "$sha" ]]; then
    log::ok "truststore matches the trust bundle"
    return 0
  fi
  log::changed "build truststore.p12 from the trust bundle ($(grep -c 'BEGIN CERTIFICATE' "$PKI_DIR/ca.pem") CA)"
  step::mutating || return 0
  pki::_build_truststore "$ts" "$STORE_PASSWORD"
  printf '%s' "$sha" >"$mark"
}

# pki::leaves -> the leaf certificates cpctl manages (shared certs, service identities, client certs of legacy REST apps)
pki::leaves() {
  printf '%s\n' kafka-internal cp-server
  local svc
  for svc in ${SERVICE_CERTS:-}; do printf '%s\n' "$svc"; done
  [[ ${OPMENU:-off} == on ]] && printf '%s\n' "$OPMENU_BREAKGLASS"
  inv::apps rest
}

# pki::truststore_named <file> <password>  -> PKCS12 truststore of the trust bundle with its own password
# (for consumers outside the cluster, e.g. the bastion: never hand out STORE_PASSWORD, which also opens keystores)
pki::truststore_named() {
  local ts=$1 pw=$2 mark="$1.bundle.sha256" sha
  sha=$(core::sha256 "$PKI_DIR/ca.pem")
  if [[ -f $ts && -f $mark && $(cat "$mark") == "$sha" ]]; then return 0; fi
  step::mutating || return 0
  pki::_build_truststore "$ts" "$pw"
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
  for f in $(pki::roots); do
    end=$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)
    log::ok "trust anchor $(basename "$f" .pem) ($(pki::subject "$f")) valid until $(date -d "$end" +%F)"
  done
  for n in ca ca-next ca-old $(pki::leaves); do
    f=$PKI_DIR/$n.crt
    [[ -f $f ]] || continue
    case $n in ca) kind="internal CA" ;; ca-next) kind="next CA (rotation)" ;; ca-old) kind="old CA (rotation)" ;; *) kind=leaf ;; esac
    end=$(openssl x509 -enddate -noout -in "$f" | cut -d= -f2)
    days=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
    if ((days < PKI_RENEW_BEFORE_DAYS)); then
      log::warn "certificate $n ($kind) expires $(date -d "$end" +%F) ($days days) - run: cpctl certs rotate"
      rc=2
    elif [[ $kind == leaf ]] && ! pki::verify_current "$f"; then
      if pki::external; then
        log::warn "certificate $n is not issued under a bank root in trust/ - run: cpctl certs rotate --cert $n"
      else
        log::warn "certificate $n is not signed by the current signing CA - run: cpctl certs rotate-ca --phase switch"
      fi
      rc=2
    else
      log::ok "certificate $n ($kind) valid until $(date -d "$end" +%F) ($days days)"
    fi
  done
  for n in $(pki::pending); do
    if [[ -f $PKI_DIR/incoming/$n.crt ]]; then
      log::warn "certificate $n: the bank's answer is in incoming/ - import with: cpctl certs rotate --cert $n"
    else
      log::warn "certificate $n: request open (requests/$n.csr), waiting for the bank"
    fi
    rc=2
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

# pki::issue_all -> every managed certificate (step 03; step 02 too when the internal repo is served over HTTPS,
# because the repo server needs cp-server before any node can install a package). Stops while the bank has
# not answered a request that has no usable predecessor.
pki::issue_all() {
  pki::ca
  # controllers + brokers: one shared certificate for CONTROLLER / INTERNAL mTLS (principal kafka-internal)
  pki::issue kafka-internal "$(pki::sans_internal)" serverAuth,clientAuth
  # all servers: one shared certificate for external listeners, MDS, REST, C3, Prometheus, LDAPS, repo
  pki::issue cp-server "$(pki::sans_server)" serverAuth,clientAuth
  # machines: client certificates ONLY for legacy apps that use REST Proxy (principal = CN)
  local app
  for app in $(inv::apps rest); do pki::issue "$app" "" clientAuth; done
  # service identities towards MDS (REST Proxy, Control Center, cpctl): certificate instead of an AD account
  local svc
  for svc in ${SERVICE_CERTS:-}; do pki::issue "$svc" "" clientAuth; done
  # OP menu break-glass identity (menu item 91; RBAC SystemAdmin, key held by opbootstrap on the bastion)
  if [[ ${OPMENU:-off} == on ]]; then pki::issue "$OPMENU_BREAKGLASS" "" clientAuth; fi
  if pki::external && step::mutating; then pki::pending_gate; fi
  return 0
}
