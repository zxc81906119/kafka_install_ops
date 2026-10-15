#!/usr/bin/env bash
# Repo adapter "local": the ops host itself is the internal repository
# (createrepo_c + httpd), for banks without an artifact repository reachable from the target zone.
# Interface (other adapters - satellite / artifactory / nexus - implement the same functions):
#   repo::import    landing zone -> internal repo (verify first, never overwrite a published file)
#   repo::verify    internal repo is complete and served
#   repo::list      what is published
[[ -n ${_LIB_REPO_LOADED:-} ]] && return 0
_LIB_REPO_LOADED=1

readonly REPO_LANDING=${REPO_LANDING:-/mnt/exchange}
readonly REPO_LOCAL_ROOT=${REPO_LOCAL_ROOT:-/srv/repo}
readonly REPO_OWNER=repoadmin

# umask 022: published files must stay world-readable for httpd (cpctl itself runs with umask 027)
repo::_as_owner() { sudo -n -u "$REPO_OWNER" bash -c 'umask 022; exec "$@"' _ "$@"; }

# Map a landing-zone relative path to its published location.
repo::_dest() {
  case $1 in
    rpm/*) printf '%s/%s' "$REPO_LOCAL_ROOT" "$1" ;;
    tar/*) printf '%s/raw/%s' "$REPO_LOCAL_ROOT" "$1" ;;
    gpg-keys/*) printf '%s/%s' "$REPO_LOCAL_ROOT" "$1" ;;
    *) return 1 ;;
  esac
}

repo::_verify_landing() {
  [[ -f $REPO_LANDING/SHA256SUMS ]] || core::die "$E_PRECHECK" "no SHA256SUMS in landing zone $REPO_LANDING"
  log::info "verifying checksums in landing zone ($(wc -l <"$REPO_LANDING/SHA256SUMS") files)"
  if ! (cd "$REPO_LANDING" && sha256sum --quiet -c SHA256SUMS); then
    core::die "$E_PRECHECK" "checksum mismatch in landing zone - import aborted, nothing was published"
  fi
  log::ok "landing zone checksums match SHA256SUMS"
  local k
  for k in "$REPO_LANDING"/gpg-keys/*.asc; do sudo -n rpm --import "$k"; done
  local bad=0 f
  while IFS= read -r -d '' f; do
    if ! rpm -K "$f" 2>/dev/null | grep -q 'digests signatures OK'; then
      log::error "GPG signature check failed: ${f#$REPO_LANDING/}"
      bad=1
    fi
  done < <(find "$REPO_LANDING/rpm" -name '*.rpm' -print0 2>/dev/null)
  [[ $bad -eq 0 ]] || core::die "$E_PRECHECK" "unsigned or tampered RPMs in landing zone - import aborted"
  log::ok "all RPM signatures verified against vendor keys"
}

repo::import() {
  repo::_verify_landing
  local rel sum dest changed_dirs=() added=0 kept=0
  declare -A dirty=()
  while read -r sum rel; do
    rel=${rel#\*}
    dest=$(repo::_dest "$rel") || continue
    if [[ -f $dest ]]; then
      if [[ $(core::sha256 "$dest") == "$sum" ]]; then
        kept=$((kept + 1))
        continue
      fi
      core::die "$E_PRECHECK" "refusing to overwrite published file with different content: $rel"
    fi
    if core::is_check_mode; then
      log::changed "would publish $rel"
    else
      repo::_as_owner install -D -m 0644 "$REPO_LANDING/$rel" "$dest"
      log::changed "published $rel"
    fi
    added=$((added + 1))
    [[ $rel == rpm/* ]] && dirty[$(dirname "$dest")]=1
  done <"$REPO_LANDING/SHA256SUMS"
  local d
  for d in "$REPO_LOCAL_ROOT"/rpm/*/; do
    d=${d%/}
    if [[ -n ${dirty[$d]:-} || ! -f $d/repodata/repomd.xml ]]; then
      if core::is_check_mode; then log::changed "would rebuild repodata $d"; continue; fi
      repo::_as_owner createrepo_c -q --update "$d"
      log::changed "repodata rebuilt: ${d#$REPO_LOCAL_ROOT/}"
    else
      log::ok "repodata current: ${d#$REPO_LOCAL_ROOT/}"
    fi
  done
  # Audit trail: keep every manifest / checksum list / scan report that came with an import.
  if [[ $added -gt 0 ]] && ! core::is_check_mode; then
    local audit
    audit="$REPO_LOCAL_ROOT/manifests/$(date +%Y%m%d-%H%M%S)"
    repo::_as_owner install -d -m 0755 "$audit"
    local m
    for m in SHA256SUMS manifest-rpm.json manifest-tar.json; do
      [[ -f $REPO_LANDING/$m ]] && repo::_as_owner install -m 0644 "$REPO_LANDING/$m" "$audit/$m"
    done
    if [[ -d $REPO_LANDING/report ]]; then repo::_as_owner cp -r "$REPO_LANDING/report" "$audit/"; fi
    log::info "audit copy: $audit"
  fi
  log::info "import summary: $added new, $kept already published"
}

repo::verify() {
  local r rc=0 base=${REPO_YUM_BASEURL%/}
  for r in confluent adoptium os-deps; do
    if curl -fsS -o /dev/null "$base/$r/repodata/repomd.xml"; then
      log::ok "repo $r served at $base/$r"
    else
      log::error "repo $r not served at $base/$r"
      rc=1
    fi
  done
  return "$rc"
}

repo::list() {
  local r
  for r in "$REPO_LOCAL_ROOT"/rpm/*/; do
    printf '== %s\n' "$(basename "$r")"
    find "$r" -maxdepth 1 -name '*.rpm' -printf '%f\n' | sort -V | sed 's/^/   /'
  done
  [[ -d $REPO_LOCAL_ROOT/raw ]] && { printf '== raw\n'; find "$REPO_LOCAL_ROOT/raw" -type f -printf '   %P\n'; }
  return 0
}
