#!/usr/bin/env bash
# Simulated BANK PKI (PoC only). Stands in for the bank's certificate authority, which in production is
# operated by the bank's security team - cpctl never holds these keys.
#
#   bank-ca.sh init                 root CA "G1" + issuing (intermediate) CA "01" under bank-ca/ (idempotent)
#   bank-ca.sh new-generation G2    a NEW root + issuing CA (simulates the bank rotating its CA); becomes current
#   bank-ca.sh root [gen]           path + SHA-256 fingerprint of the root (what the bank publishes)
#   bank-ca.sh sign <csr> <out> [--no-chain|--server-only]
#                                   bank policy check + sign with the current issuing CA;
#                                   <out> = certificate + issuing CA (the usual answer of a bank)
#                                   --no-chain / --server-only: deliberately wrong answers (rejection demo)
#   bank-ca.sh deliver-root [gen]   copy the root to ops01:/home/cpadmin/bank-root-<gen>.pem (file exchange)
#   bank-ca.sh exchange [--no-chain|--server-only]
#                                   PoC shortcut for the file exchange: fetch ops01 pki/requests/*.csr,
#                                   sign each, put the answers into ops01 pki/incoming/
#
# State: bank-ca/ in the project (gitignored). Leaf validity 365 days, issuing CA 10 years, root 20 years.
set -Eeuo pipefail
# shellcheck source=windows/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# openssl here is a native Windows binary and MSYS path conversion is off (lib.sh): use C:/... paths
BANK_DIR="$(winpath "${BANK_DIR:-$PROJECT_DIR/bank-ca}")"
BANK_ORG="/O=PoC Bank/C=TW"
OPS_CONTAINER="${OPS_CONTAINER:-cp-poc-ops01-1}"
OPS_PKI=/var/lib/cp-installer/pki
LEAF_DAYS=365

current() { cat "$BANK_DIR/CURRENT" 2>/dev/null || die "no bank CA yet - run: bank-ca.sh init"; }

new_generation() { # <gen>
  local g=$1 d=$BANK_DIR/$1
  [[ $g =~ ^G[0-9]+$ ]] || die "generation must look like G1, G2, ..."
  if [[ -f $d/issuing.crt ]]; then log "bank CA generation $g exists"; return 0; fi
  mkdir -p "$d"
  chmod 0700 "$d"
  openssl genrsa -out "$d/root.key" 4096 2>/dev/null
  openssl req -x509 -new -key "$d/root.key" -sha256 -days 7300 -out "$d/root.crt" \
    -subj "/CN=PoC Bank Root CA $g$BANK_ORG" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
  openssl genrsa -out "$d/issuing.key" 4096 2>/dev/null
  openssl req -new -key "$d/issuing.key" -sha256 -subj "/CN=PoC Bank Issuing CA $g-01$BANK_ORG" -out "$d/issuing.csr"
  printf '%s\n' "basicConstraints=critical,CA:TRUE,pathlen:0" "keyUsage=critical,keyCertSign,cRLSign" \
    "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid:always" >"$d/issuing.ext"
  openssl x509 -req -in "$d/issuing.csr" -CA "$d/root.crt" -CAkey "$d/root.key" -CAcreateserial \
    -days 3650 -sha256 -extfile "$d/issuing.ext" -out "$d/issuing.crt" 2>/dev/null
  rm -f "$d/issuing.csr" "$d/issuing.ext"
  printf '%s' "$g" >"$BANK_DIR/CURRENT"
  log "bank CA generation $g: root + issuing CA created (current)"
}

fingerprint() { openssl x509 -noout -fingerprint -sha256 -in "$1" | cut -d= -f2; }

# csr_ext <csr> <header> -> the value line of an extension in the CSR text
csr_ext() { openssl req -in "$1" -noout -text | awk -v h="$2" 'f {gsub(/^ +/, ""); print; exit} index($0, h) {f=1}'; }

sign() { # <csr> <out> [--no-chain|--server-only]
  local csr=$1 out=$2 mode=${3:-} g d ext san eku bits subj
  g=$(current) d=$BANK_DIR/$g
  openssl req -in "$csr" -noout -verify >/dev/null 2>&1 || die "$csr: CSR signature invalid"
  bits=$(openssl req -in "$csr" -noout -text | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p')
  ((bits >= 2048)) || die "$csr: policy - RSA key of at least 2048 bit required (got ${bits:-?})"
  subj=$(openssl req -in "$csr" -noout -subject -nameopt oneline | sed 's/^subject= *//')
  [[ $subj == *"CN = "* ]] || die "$csr: policy - subject without CN"
  [[ $(csr_ext "$csr" "Basic Constraints") == *CA:TRUE* ]] && die "$csr: policy - CA certificates are not issued"
  san=$(csr_ext "$csr" "Subject Alternative Name" | sed 's/IP Address:/IP:/g; s/, /,/g')
  eku=$(csr_ext "$csr" "Extended Key Usage" | sed 's/TLS Web Server Authentication/serverAuth/; s/TLS Web Client Authentication/clientAuth/; s/, /,/g')
  [[ -n $eku ]] || die "$csr: policy - extended key usage must be requested"
  [[ $eku =~ ^(serverAuth|clientAuth)(,(serverAuth|clientAuth))?$ ]] || die "$csr: policy - EKU '$eku' not allowed"
  [[ $mode == --server-only ]] && eku=serverAuth
  ext=$(mktemp -p "$BANK_DIR")
  {
    printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature,keyEncipherment" \
      "extendedKeyUsage=$eku" "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid,issuer"
    [[ -n $san ]] && printf 'subjectAltName=%s\n' "$san"
  } >"$ext"
  openssl x509 -req -in "$csr" -CA "$d/issuing.crt" -CAkey "$d/issuing.key" -CAcreateserial \
    -days "$LEAF_DAYS" -sha256 -extfile "$ext" -out "$out.tmp" 2>/dev/null
  rm -f "$ext"
  if [[ $mode == --no-chain ]]; then mv "$out.tmp" "$out"; else cat "$out.tmp" "$d/issuing.crt" >"$out"; rm -f "$out.tmp"; fi
  log "signed $(basename "$csr") -> $(basename "$out")  ($subj; EKU $eku; issuer Issuing CA $g-01${mode:+; $mode})"
}

ops() { docker exec -i -u cpadmin "$OPS_CONTAINER" "$@"; }

deliver_root() {
  local g=${1:-$(current)}
  [[ -f $BANK_DIR/$g/root.crt ]] || die "no generation $g"
  ops sh -c "cat > /home/cpadmin/bank-root-${g,,}.pem" <"$BANK_DIR/$g/root.crt"
  log "delivered root $g to $OPS_CONTAINER:/home/cpadmin/bank-root-${g,,}.pem"
  log "SHA-256 fingerprint (published by the bank on a separate channel): $(fingerprint "$BANK_DIR/$g/root.crt")"
}

exchange() {
  local mode=${1:-} box n f
  box="$BANK_DIR/exchange/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$box/in" "$box/out"
  ops sh -c "cd $OPS_PKI/requests 2>/dev/null && tar -cf - *.csr *.req.txt 2>/dev/null || true" | tar -xf - -C "$box/in"
  n=0
  for f in "$box"/in/*.csr; do
    [[ -f $f ]] || continue
    sign "$f" "$box/out/$(basename "$f" .csr).crt" "$mode"
    n=$((n + 1))
  done
  ((n > 0)) || { warn "no requests in $OPS_CONTAINER:$OPS_PKI/requests"; return 0; }
  tar -cf - -C "$box/out" . | ops sh -c "mkdir -p $OPS_PKI/incoming && tar -xf - -C $OPS_PKI/incoming --no-same-owner"
  log "$n answer(s) delivered to $OPS_CONTAINER:$OPS_PKI/incoming/ (copy kept in ${box#"$(winpath "$PROJECT_DIR")"/})"
}

main() {
  local cmd=${1:-}; shift || true
  mkdir -p "$BANK_DIR"
  chmod 0700 "$BANK_DIR" 2>/dev/null || true
  case $cmd in
    init) if [[ -f $BANK_DIR/CURRENT ]]; then log "bank CA initialised (current $(current))"; else new_generation G1; fi ;;
    new-generation) new_generation "${1:?generation, e.g. G2}" ;;
    root) local g=${1:-$(current)}; printf '%s\nSHA-256 %s\n' "$BANK_DIR/$g/root.crt" "$(fingerprint "$BANK_DIR/$g/root.crt")" ;;
    sign) sign "${1:?csr}" "${2:?out}" "${3:-}" ;;
    deliver-root) deliver_root "${1:-}" ;;
    exchange) exchange "${1:-}" ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
}
main "$@"
