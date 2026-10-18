# Node-side part of the tar.gz install strategy (shipped with remote::run).
# Layout:  /opt/confluent/<archive top dir>/   versions side by side
#          /opt/confluent/current -> confluent-<ver>         (CP)
#          /opt/confluent/c3-current -> <c3 top dir>          (Control Center)
#          /opt/java/current -> <jdk top dir>
# Markers in /opt/confluent/.cpctl/<archive>.sha256 make extraction idempotent.

readonly TAR_CACHE=/var/cache/cp-installer
readonly TAR_MARKS=/opt/confluent/.cpctl

# tar_node::account <user> <home>   system account, group confluent, no login (what the RPMs do)
tar_node::account() {
  local u=$1 home=$2
  if ! getent group confluent >/dev/null; then
    _mark changed "group confluent"
    [[ ${CPCTL_CHECK:-0} == 1 ]] || groupadd -r confluent
  fi
  if id "$u" >/dev/null 2>&1; then _mark ok "user $u"; return 0; fi
  _mark changed "user $u (system, nologin)"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || useradd -r -g confluent -d "$home" -M -s /sbin/nologin -c "Confluent ($u)" "$u"
}

# tar_node::fetch_extract <url> <sha256> <parent dir>   -> prints the archive's top directory on stdout (last line)
tar_node::fetch_extract() {
  local url=$1 sha=$2 parent=$3 file top mark
  ensure::_guard "$parent"
  file=$(basename "$url")
  mark="$TAR_MARKS/$file.sha256"
  install -d -m 0755 "$parent" "$TAR_MARKS" "$TAR_CACHE"
  if [[ -f $mark && $(cat "$mark") == "$sha"* && -d $parent/$(cut -d' ' -f2 "$mark") ]]; then
    _mark ok "extracted $file"
    printf 'TOP=%s\n' "$(cut -d' ' -f2 "$mark")"
    return 0
  fi
  _mark changed "fetch + verify + extract $file"
  if [[ ${CPCTL_CHECK:-0} == 1 ]]; then printf 'TOP=\n'; return 0; fi
  local cached=$TAR_CACHE/$file
  if [[ ! -f $cached || $(sha256sum "$cached" | awk '{print $1}') != "$sha" ]]; then
    # internal repo over HTTPS: pin the CA file cpctl ships for the repo (cp-repo-ca.pem)
    local ca=()
    [[ -f /etc/pki/tls/certs/cp-repo-ca.pem ]] && ca=(--cacert /etc/pki/tls/certs/cp-repo-ca.pem)
    curl -fsS --retry 3 "${ca[@]}" -o "$cached.part" "$url"
    mv "$cached.part" "$cached"
  fi
  local have
  have=$(sha256sum "$cached" | awk '{print $1}')
  if [[ $have != "$sha" ]]; then
    rm -f "$cached"
    _mark warn "sha256 mismatch for $file (got $have) - refusing to extract"
    return 4
  fi
  # head closes the pipe early -> tar gets SIGPIPE (141); that is expected, not an error
  top=$({ tar -tzf "$cached" 2>/dev/null || true; } | head -1 | cut -d/ -f1)
  [[ -n $top ]] || { _mark warn "cannot read archive $file"; return 4; }
  tar -xzf "$cached" -C "$parent" --no-same-owner
  chown -R root:root "$parent/$top"
  chmod -R go-w "$parent/$top"
  printf '%s %s\n' "$sha" "$top" >"$mark"
  printf 'TOP=%s\n' "$top"
}

# tar_node::current <link>  -> basename of the symlink target (empty if absent)
tar_node::current() { [[ -L $1 ]] && basename "$(readlink "$1")" || true; }

# tar_node::switch <mode> <link> <target dir name>
#   install: refuse to move an existing link to another version (use cpctl upgrade)
#   upgrade: move the link (this IS the upgrade / rollback for the tar strategy)
tar_node::switch() {
  local mode=$1 link=$2 target=$3 cur
  ensure::_guard "$link"
  cur=$(tar_node::current "$link")
  if [[ $cur == "$target" ]]; then _mark ok "$link -> $target"; return 0; fi
  if [[ -n $cur && $mode == install ]]; then
    _mark warn "$link points to $cur, expected $target - refusing to switch versions during install (use: cpctl upgrade)"
    return 3
  fi
  _mark changed "$link -> $target${cur:+ (was $cur)}"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || ln -sfn "$(dirname "$link")/$target" "$link"
}

# tar_node::seed_dir <source dir> <dest dir>   copy shipped default files once, never overwrite
tar_node::seed_dir() {
  local src=$1 dst=$2 f n=0
  ensure::_guard "$dst"
  install -d -m 0755 "$dst"
  for f in "$src"/*; do
    [[ -f $f && ! -e $dst/$(basename "$f") ]] || continue
    n=$((n + 1))
    [[ ${CPCTL_CHECK:-0} == 1 ]] || install -m 0644 "$f" "$dst/"
  done
  if [[ $n -gt 0 ]]; then _mark changed "seeded $n default file(s) into $dst"; else _mark ok "defaults present in $dst"; fi
}

# tar_node::remove_paths <path or glob>...   (globs are expanded HERE, on the node)
tar_node::remove_paths() {
  local pat p any=0
  for p in "$@"; do ensure::_guard "$p"; done
  shopt -s nullglob
  for pat in "$@"; do
    # shellcheck disable=SC2206
    local matches=($pat)
    for p in "${matches[@]}"; do
    [[ -e $p || -L $p ]] || continue
    any=1
    _mark changed "remove $p"
    [[ ${CPCTL_CHECK:-0} == 1 ]] || rm -rf -- "$p"
    done
  done
  shopt -u nullglob
  [[ $any == 1 ]] || _mark ok "nothing to remove"
}
