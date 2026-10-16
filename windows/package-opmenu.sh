#!/usr/bin/env bash
# Package the OP menu (opmenu/, internal software) for the offline intake chain:
#   source dir -> packages/tools/opmenu-<date>.<sha8>.tar.gz + SHA256SUMS line -> verify-packages -> repo import
# Only the program is shipped (no logs, no environment conf, no credentials); cpctl renders /etc/opmenu/opmenu.conf.
# The version is content-addressed, so a changed opmenu can never overwrite a published one (repo import refuses that).
#
#   bash windows/package-opmenu.sh [opmenu source dir]      default: opmenu/ in this project
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

src=${1:-$PROJECT_DIR/opmenu}
[[ -n $src && -f $src/opmenu.sh && -d $src/lib ]] || die "usage: package-opmenu.sh <opmenu source dir> (must contain opmenu.sh and lib/)"
src=$(cd "$src" && pwd)

# allowlist of what goes into the package
files=(opmenu.sh lib README.md opmenu.conf.example)
[[ -f $src/test-host-gate.sh ]] && files+=(test-host-gate.sh)

# CRLF check with perl (some Git Bash builds expand $'\r' to an empty pattern)
if find "${files[@]/#/$src/}" -type f -print0 | xargs -0 perl -ne 'if (/\r$/) { print "$ARGV\n"; exit 1 }'; then :; else die "CRLF line endings in $src - fix before packaging"; fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/opmenu"
(cd "$src" && cp -r "${files[@]}" "$stage/opmenu/")
# reproducible archive: same content -> same bytes -> same version
tar --sort=name --mtime='2026-01-01 00:00:00' --owner=0 --group=0 --numeric-owner -C "$stage" -cf "$stage/opmenu.tar" opmenu
gzip -n -9 "$stage/opmenu.tar"
sha=$(sha256sum "$stage/opmenu.tar.gz" | awk '{print $1}')
ver="$(date +%Y%m%d).${sha:0:8}"
name="opmenu-$ver.tar.gz"

mkdir -p "$PACKAGES_DIR/tools"
if [[ -f $PACKAGES_DIR/tools/$name ]]; then
  log "already packaged: tools/$name"
else
  install -m 0644 "$stage/opmenu.tar.gz" "$PACKAGES_DIR/tools/$name"
  log "packaged tools/$name (sha256 $sha)"
fi
# SHA256SUMS: one line per file (download-packages.sh rebuilds the whole list later and keeps this file)
touch "$PACKAGES_DIR/SHA256SUMS"
grep -v " tools/$name\$" "$PACKAGES_DIR/SHA256SUMS" >"$stage/sums" || true
printf '%s  tools/%s\n' "$sha" "$name" >>"$stage/sums"
cp "$stage/sums" "$PACKAGES_DIR/SHA256SUMS"
# the installer installs exactly this version
if grep -q '^OPMENU_VERSION=' "$CONF_DIR/versions.env"; then
  sed -i "s/^OPMENU_VERSION=.*/OPMENU_VERSION=$ver/" "$CONF_DIR/versions.env"
else
  printf '\n# OP menu for the bastion (internal software, packaged by windows/package-opmenu.sh)\nOPMENU_VERSION=%s\n' "$ver" >>"$CONF_DIR/versions.env"
fi
log "versions.env: OPMENU_VERSION=$ver"
log "next: bash windows/verify-packages.sh ; bash windows/poc.sh cpctl repo import"
