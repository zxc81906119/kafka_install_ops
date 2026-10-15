#!/usr/bin/env bash
# Internet-side "download host": fetch every offline package into packages/ (the landing zone).
#   download-packages.sh [--method rpm|tar|both]
# RPMs are resolved inside a throw-away container built from the SAME base image as the target hosts,
# so `dnf download --resolve` pulls exactly the OS dependencies those hosts are missing.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

method=rpm
while [[ $# -gt 0 ]]; do
  case $1 in
    --method) method=$2; shift 2 ;;
    -h | --help) sed -n '2,5p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

ensure_docker
docker image inspect cp-node:poc >/dev/null 2>&1 || die "image cp-node:poc missing - run: windows/poc.sh build"
mkdir -p "$PACKAGES_DIR"

if [[ $method == rpm || $method == both ]]; then
  log "resolving and downloading RPMs (this pulls ~3GB the first time)"
  docker run --rm \
    -v "$(winpath "$PACKAGES_DIR"):/out" \
    -v "$(winpath "$CONF_DIR/versions.env"):/in/versions.env:ro" \
    -v "$(winpath "$WIN_DIR/download-in-container.sh"):/in/download.sh:ro" \
    -e DOWNLOADED_BY="${USERNAME:-$USER}@$(hostname)" \
    cp-node:poc bash /in/download.sh
fi

if [[ $method == tar || $method == both ]]; then
  log "downloading tar.gz archives (CP, C3, Temurin JDK, Confluent CLI)"
  docker run --rm \
    -v "$(winpath "$PACKAGES_DIR"):/out" \
    -v "$(winpath "$CONF_DIR/versions.env"):/in/versions.env:ro" \
    -v "$(winpath "$WIN_DIR/download-tar-in-container.sh"):/in/download-tar.sh:ro" \
    -e DOWNLOADED_BY="${USERNAME:-$USER}@$(hostname)" \
    cp-node:poc bash /in/download-tar.sh
fi

log "writing SHA256SUMS (inside a Linux container: Git Bash sha256sum is unreliable on multi-GB files)"
docker run --rm -v "$(winpath "$PACKAGES_DIR"):/out" cp-node:poc bash -c \
  'cd /out && find rpm tar tools gpg-keys -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum >SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS'
log "done: $(wc -l <"$PACKAGES_DIR/SHA256SUMS") files listed; next run windows/verify-packages.sh"
