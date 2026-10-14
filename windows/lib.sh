#!/usr/bin/env bash
# Shared helpers for the Windows (Git Bash) side scripts.
[[ -n ${_WIN_LIB_LOADED:-} ]] && return 0
_WIN_LIB_LOADED=1

set -Eeuo pipefail

# Git Bash rewrites /unix/paths into C:/Program Files/Git/... when calling Windows binaries (docker.exe).
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

WIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$WIN_DIR/.." && pwd)"
DOCKER_DIR="$PROJECT_DIR/docker"
PACKAGES_DIR="$PROJECT_DIR/packages"
CONF_DIR="$PROJECT_DIR/installer/conf"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Windows path for docker -v arguments (docker.exe does not understand /c/Users/...).
winpath() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
COMPOSE=(docker compose -f "$(winpath "$DOCKER_DIR/compose.yml")")

# Refuse CRLF in anything that will run on Linux.
# Uses perl on purpose: the Cygwin-built bash shipped with some Git for Windows
# versions expands the ANSI-C quoted carriage return to an empty grep pattern.
check_crlf() {
  local bad
  bad=$(find "$PROJECT_DIR/installer" "$PROJECT_DIR/docker" "$PROJECT_DIR/windows" -type f -print0 |
    xargs -0 perl -ne 'if (/\x0d$/) { print "$ARGV\n"; close ARGV }' 2>/dev/null || true)
  [[ -z $bad ]] || die "CRLF line endings found (convert to LF):"$'\n'"$bad"
}

ensure_docker() {
  if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then return 0; fi
  local exe="/c/Program Files/Docker/Docker/Docker Desktop.exe"
  [[ -x $exe ]] || die "Docker Desktop not found at $exe"
  log "starting Docker Desktop"
  "$exe" >/dev/null 2>&1 &
  local i
  for i in $(seq 1 60); do
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1 && return 0
    sleep 3
  done
  die "Docker engine did not become ready"
}

# Load conf/versions.env (single source of truth for versions).
load_versions() {
  # shellcheck source=/dev/null
  source "$CONF_DIR/versions.env"
}
