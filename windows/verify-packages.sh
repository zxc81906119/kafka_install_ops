#!/usr/bin/env bash
# Internet-side verification gate, run BEFORE the files cross into the internal network:
#   1. every file matches SHA256SUMS
#   2. every RPM carries a valid vendor GPG signature
#   3. optional scan hooks in windows/scan.d/*.sh (antivirus, Trivy/Grype SBOM, ...)
# Writes packages/report/verify-<timestamp>.txt (kept with the import as audit evidence).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ensure_docker
[[ -f $PACKAGES_DIR/SHA256SUMS ]] || die "no SHA256SUMS - run windows/download-packages.sh first"
mkdir -p "$PACKAGES_DIR/report"
report="$PACKAGES_DIR/report/verify-$(date +%Y%m%d-%H%M%S).txt"

log "checksums + GPG signatures (inside a cp-node container)"
docker run --rm -v "$(winpath "$PACKAGES_DIR"):/p:ro" cp-node:poc bash -c '
  set -e
  cd /p
  echo "== sha256 =="
  sha256sum -c --quiet SHA256SUMS && echo "all $(wc -l <SHA256SUMS) files match SHA256SUMS"
  echo "== gpg =="
  for k in gpg-keys/*.asc; do rpm --import "$k"; done
  bad=0
  while IFS= read -r -d "" f; do
    r=$(rpm -K "$f")
    case $r in *"digests signatures OK"*) ;; *) echo "BAD: $r"; bad=1 ;; esac
  done < <(find rpm -name "*.rpm" -print0)
  [ $bad -eq 0 ] && echo "all $(find rpm -name "*.rpm" | wc -l) RPMs have valid vendor signatures"
  exit $bad
' | tee "$report"

shopt -s nullglob
for hook in "$WIN_DIR"/scan.d/*.sh; do
  log "scan hook: $(basename "$hook")"
  bash "$hook" "$PACKAGES_DIR" | tee -a "$report"
done
log "verification report: $report"
