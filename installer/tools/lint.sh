#!/usr/bin/env bash
# Static checks for every shell file in the installer (run on the ops host: shellcheck + shfmt are installed there).
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapfile -t files < <(find "$root" -type f \( -name '*.sh' -o -path "$root/bin/cpctl" \) | sort)
printf 'shellcheck: %s files\n' "${#files[@]}"
# SC1090/SC1091: dynamic sources are intentional (strategy files picked from the inventory)
# SC2034: variables consumed by templates through envsubst
shellcheck -x -S warning -e SC1090,SC1091,SC2034 -s bash "${files[@]}"
printf 'shfmt (diff only, 2-space indent)\n'
shfmt -i 2 -ci -d "${files[@]}" >/dev/null && echo "shfmt: clean" || echo "shfmt: formatting differences (non-blocking)"
