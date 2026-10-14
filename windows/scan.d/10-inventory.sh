#!/usr/bin/env bash
# Example scan hook: prints a package inventory (name / version / vendor) for the change ticket.
# Add more hooks here (e.g. 20-antivirus.sh, 30-trivy-sbom.sh); each receives the packages dir as $1.
set -euo pipefail
pkgdir=$1
echo "== package inventory =="
perl -0ne 'while (/"name": "([^"]+)",\s*"version": "([^"]+)",\s*"vendor": "([^"]*)"/g) { printf "%-40s %-22s %s\n", $1, $2, $3 }' \
  "$pkgdir/manifest-rpm.json"
