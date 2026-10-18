#!/usr/bin/env bash
# Static checks for every shell file in the installer (run on the ops host: shellcheck + shfmt are installed there).
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t files < <(find "$root" -type f \( -name '*.sh' -o -name '*.main' -o -path "$root/bin/cpctl" \) | sort)
printf 'shellcheck: %s files\n' "${#files[@]}"
# SC1090/SC1091: dynamic sources are intentional (strategy files picked from the inventory)
# SC2034: variables consumed by templates through envsubst
shellcheck -x -S warning -e SC1090,SC1091,SC2034 -s bash "${files[@]}"
printf 'shfmt (diff only, 2-space indent)\n'
shfmt -i 2 -ci -d "${files[@]}" >/dev/null && echo "shfmt: clean" || echo "shfmt: formatting differences (non-blocking)"
# Project rule: no "producer | grep -q" pipelines. Under pipefail grep's early exit SIGPIPEs the producer and the
# test turns false at random (it once archived a managed certificate). Use: grep -q PAT <<<"$(producer)".
# Commands sent to remote shells as strings (no pipefail there) are exempt.
bad=$(grep -n -E '\|[[:space:]]*grep -[a-zA-Z]*q' "${files[@]}" | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#|remote::exec' || true)
if [[ -n $bad ]]; then printf 'pipe-to-grep -q (SIGPIPE race under pipefail):\n%s\n' "$bad"; exit 1; fi
echo "pipe-to-grep -q: none"
