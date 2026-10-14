#!/usr/bin/env bash
# Internal PKI on the ops host: CA, the two shared certificates, per-app client certificates,
# MDS token key pair. Everything is regenerated only when missing, expiring or when SANs changed.
[[ -n ${_LIB_PKI_LOADED:-} ]] && return 0
_LIB_PKI_LOADED=1

readonly PKI_SUBJECT_SUFFIX="/OU=Confluent/O=PoC Bank/C=TW"

pki::keytool() { "$(install::java_home)/bin/keytool" "$@"; }

# pki::needs_issue <cert> <wanted SAN list (comma separated, sorted)>
pki::needs_issue() {
  local crt=$1 want=$2 have
  [[ -f $crt ]] || return 0
  openssl x509 -checkend $((PKI_RENEW_BEFORE_DAYS * 86400)) -noout -in "$crt" >/dev/null || return 0
  [[ -z $want ]] && return 1
  have=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tail -n +2 |
    tr ',' '\n' | sed 's/^ *DNS://; s/^ *IP Address://' | sort -u | paste -sd, -)
  [[ $have != "$want" ]]
}

pki::ca() {
  local key=$PKI_DIR/ca.key crt=$PKI_DIR/ca.pem
  if [[ -f $crt ]] && openssl x509 -checkend $((365 * 86400)) -noout -in "$crt" >/dev/null; then
    log::ok "internal CA valid until $(openssl x509 -enddate -noout -in "$crt" | cut -d= -f2)"
    return 0
  fi
  log::changed "create internal CA (RSA $PKI_KEY_BITS, $PKI_CA_DAYS days)"
  step::mutating || return 0
  openssl genrsa -out "$key" "$PKI_KEY_BITS" 2>/dev/null
  chmod 0600 "$key"
  openssl req -x509 -new -key "$key" -sha256 -days "$PKI_CA_DAYS" -out "$crt" \
    -subj "/CN=PoC Internal CA$PKI_SUBJECT_SUFFIX" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
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
  openssl genrsa -out "$key" "$PKI_KEY_BITS" 2>/dev/null
  chmod 0600 "$key"
  openssl req -new -key "$key" -out "$csr" -subj "/CN=$name$PKI_SUBJECT_SUFFIX"
  openssl x509 -req -in "$csr" -CA "$PKI_DIR/ca.pem" -CAkey "$PKI_DIR/ca.key" -CAcreateserial \
    -days "$PKI_CERT_DAYS" -sha256 -extfile "$ext" -out "$crt" 2>/dev/null
  rm -f "$ext" "$csr"
  openssl pkcs12 -export -name "$name" -inkey "$key" -in "$crt" -certfile "$PKI_DIR/ca.pem" \
    -passout "pass:$STORE_PASSWORD" -out "$PKI_DIR/$name.p12"
  cat "$crt" "$PKI_DIR/ca.pem" >"$PKI_DIR/$name.chain.pem"
}

pki::truststore() {
  local ts=$PKI_DIR/truststore.p12
  if [[ -f $ts ]] && pki::keytool -list -keystore "$ts" -storetype PKCS12 -storepass "$STORE_PASSWORD" -alias internal-ca >/dev/null 2>&1 &&
    [[ $(stat -c %Y "$ts") -ge $(stat -c %Y "$PKI_DIR/ca.pem") ]]; then
    log::ok "truststore contains internal CA"
    return 0
  fi
  log::changed "build truststore.p12 (internal CA)"
  step::mutating || return 0
  rm -f "$ts"
  pki::keytool -importcert -noprompt -alias internal-ca -file "$PKI_DIR/ca.pem" \
    -keystore "$ts" -storetype PKCS12 -storepass "$STORE_PASSWORD" >/dev/null
}

pki::mds_keypair() {
  if [[ -f $PKI_DIR/mds-token-keypair.pem && -f $PKI_DIR/mds-public.pem ]]; then
    log::ok "MDS token key pair present"
    return 0
  fi
  log::changed "generate MDS token key pair (RSA 2048)"
  step::mutating || return 0
  openssl genrsa -out "$PKI_DIR/mds-token-keypair.pem" 2048 2>/dev/null
  chmod 0600 "$PKI_DIR/mds-token-keypair.pem"
  openssl rsa -in "$PKI_DIR/mds-token-keypair.pem" -pubout -out "$PKI_DIR/mds-public.pem" 2>/dev/null
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
