#!/usr/bin/env bash
# Build the set of files that actually goes to the bank (scan platform, ticket, transfer) from packages/.
#   make-delivery.sh [--with-upgrade] [--with-tar] [--with-os-deps] [--out DIR]
# Default: Confluent RPMs of CP_VERSION + C3, their confluent-* dependencies, Confluent public keys,
# JMX exporter, current OP menu. JDK and OS packages come from the bank's RHEL repo and are left out.
# Writes DIR/SHA256SUMS, DIR/manifest-rpm.json and DIR/DELIVERY.txt; then run: verify-packages.sh DIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

up=0 tar=0 os=0 out=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --with-upgrade) up=1; shift ;;
    --with-tar) tar=1; shift ;;
    --with-os-deps) os=1; shift ;;
    --out) out=$2; shift 2 ;;
    -h | --help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

ensure_docker
[[ -f $PACKAGES_DIR/manifest-rpm.json ]] || die "no manifest-rpm.json - run windows/download-packages.sh first"
# shellcheck source=/dev/null
CP_VERSION=$(source "$CONF_DIR/versions.env" && echo "$CP_VERSION")
out=${out:-$PROJECT_DIR/delivery/cp-$CP_VERSION-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$out"

log "building delivery in $out"
docker run --rm \
  -v "$(winpath "$PACKAGES_DIR"):/p:ro" \
  -v "$(winpath "$out"):/d" \
  -v "$(winpath "$CONF_DIR/versions.env"):/in/versions.env:ro" \
  -v "$(winpath "$WIN_DIR/make-delivery-in-container.sh"):/in/make.sh:ro" \
  -e WITH_UPGRADE=$up -e WITH_TAR=$tar -e WITH_OS_DEPS=$os \
  cp-node:poc bash /in/make.sh
log "done: $out/DELIVERY.txt; next run windows/verify-packages.sh $out"
