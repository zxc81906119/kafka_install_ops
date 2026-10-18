#!/usr/bin/env bash
# Repo adapter "local": the ops host itself is the internal repository
# (createrepo_c + httpd), for banks without an artifact repository reachable from the target zone.
# Interface (other adapters - satellite / artifactory / nexus - implement the same functions):
#   repo::import    landing zone -> internal repo (verify first, never overwrite a published file)
#   repo::verify    internal repo is complete;  repo::verify_served  it answers at REPO_YUM_BASEURL
#   repo::list      what is published
[[ -n ${_LIB_REPO_LOADED:-} ]] && return 0
_LIB_REPO_LOADED=1

readonly REPO_LANDING=${REPO_LANDING:-/mnt/exchange}
readonly REPO_LOCAL_ROOT=${REPO_LOCAL_ROOT:-/srv/repo}
readonly REPO_OWNER=repoadmin

# umask 022: published files must stay world-readable for httpd (cpctl itself runs with umask 027)
# Every write below /srv/repo goes through node functions on the ops host (repo_node::*, as repoadmin with
# umask 022 so httpd can read): the same code runs under full sudo and under the restricted cpnode agent.
repo::server() { inv::hosts ops | head -1; }

# Map a landing-zone relative path to its published location.
repo::_dest() {
  case $1 in
    rpm/*) printf '%s/%s' "$REPO_LOCAL_ROOT" "$1" ;;
    tar/* | tools/*) printf '%s/raw/%s' "$REPO_LOCAL_ROOT" "$1" ;;
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
  remote::apply "$(repo::server)" rpm_node::import_keys "$REPO_LANDING"/gpg-keys/*.asc
  local bad=0 f
  while IFS= read -r -d '' f; do
    if ! grep -q 'digests signatures OK' <<<"$(rpm -K "$f" 2>/dev/null)"; then
      log::error "GPG signature check failed: ${f#$REPO_LANDING/}"
      bad=1
    fi
  done < <(find "$REPO_LANDING/rpm" -name '*.rpm' -print0 2>/dev/null)
  [[ $bad -eq 0 ]] || core::die "$E_PRECHECK" "unsigned or tampered RPMs in landing zone - import aborted"
  log::ok "all RPM signatures verified against vendor keys"
}

repo::import() {
  repo::_verify_landing
  local rel sum dest changed_dirs=() added=0 kept=0 conflicts=0
  declare -A dirty=()
  # All-or-nothing: find every conflict first, so a bad file late in the list never leaves
  # earlier files published without their repodata.
  while read -r sum rel; do
    rel=${rel#\*}
    dest=$(repo::_dest "$rel") || continue
    if [[ -f $dest && $(core::sha256 "$dest") != "$sum" ]]; then
      log::error "published file has different content: $rel"
      conflicts=$((conflicts + 1))
    fi
  done <"$REPO_LANDING/SHA256SUMS"
  [[ $conflicts -eq 0 ]] || core::die "$E_PRECHECK" "refusing to overwrite $conflicts published file(s) - nothing was published"
  while read -r sum rel; do
    rel=${rel#\*}
    dest=$(repo::_dest "$rel") || continue
    if [[ -f $dest ]]; then
      kept=$((kept + 1))
      continue
    fi
    if core::is_check_mode; then
      log::changed "would publish $rel"
    else
      remote::run "$(repo::server)" repo_node::publish "$REPO_LANDING/$rel" "$dest" >/dev/null
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
      remote::run "$(repo::server)" repo_node::createrepo "$d" >/dev/null
      log::changed "repodata rebuilt: ${d#$REPO_LOCAL_ROOT/}"
    else
      log::ok "repodata current: ${d#$REPO_LOCAL_ROOT/}"
    fi
  done
  # Audit trail: keep every manifest / checksum list / scan report that came with an import.
  if [[ $added -gt 0 ]] && ! core::is_check_mode; then
    local audit
    audit="$REPO_LOCAL_ROOT/manifests/$(date +%Y%m%d-%H%M%S)"
    remote::run "$(repo::server)" repo_node::mkdir "$audit" >/dev/null
    local m
    for m in SHA256SUMS manifest-rpm.json manifest-tar.json; do
      if [[ -f $REPO_LANDING/$m ]]; then remote::run "$(repo::server)" repo_node::publish "$REPO_LANDING/$m" "$audit/$m" >/dev/null; fi
    done
    if [[ -d $REPO_LANDING/report ]]; then remote::run "$(repo::server)" repo_node::copy_tree "$REPO_LANDING/report" "$audit/report" >/dev/null; fi
    log::info "audit copy: $audit"
  fi
  log::info "import summary: $added new, $kept already published"
}

# repo::verify -> the internal repo is complete (repo metadata of every yum repo present on the ops host).
# Whether it is SERVED is repo::verify_served (over HTTPS the server certificate exists only after step 02).
repo::verify() {
  local r rc=0
  for r in confluent adoptium os-deps; do
    if [[ -f $REPO_LOCAL_ROOT/rpm/$r/repodata/repomd.xml ]]; then
      log::ok "repo $r published in $REPO_LOCAL_ROOT/rpm/$r"
    else
      log::error "repo $r missing in $REPO_LOCAL_ROOT/rpm/$r"
      rc=1
    fi
  done
  return "$rc"
}

# repo::verify_served -> every yum repo answers at REPO_YUM_BASEURL (HTTPS: server certificate checked against
# the trust bundle); over HTTPS, plain HTTP on the old port must not serve the repo
repo::verify_served() {
  local r rc=0 base=${REPO_YUM_BASEURL%/} ca=()
  repo::tls && ca=(--cacert "$PKI_DIR/ca.pem")
  for r in confluent adoptium os-deps; do
    if curl -fsS "${ca[@]}" -o /dev/null "$base/$r/repodata/repomd.xml"; then
      log::ok "repo $r served at $base/$r"
    else
      log::error "repo $r not served at $base/$r"
      rc=1
    fi
  done
  return "$rc"
}

# ---- internal repo over HTTPS (REPO_YUM_BASEURL=https://...) ------------------------------------------
# The ops host serves the repo with the shared server certificate cp-server (its SAN contains the ops host).
# Plain HTTP stays configured but answers 403, so a node with a stale http:// baseurl fails loudly.
readonly REPO_TLS_CERT=/etc/pki/tls/certs/cp-repo.crt REPO_TLS_KEY=/etc/pki/tls/private/cp-repo.key

repo::tls() { [[ $REPO_YUM_BASEURL == https://* ]]; }

# repo::_served_quiet -> probe only (no log lines, no failure count): one repo answers at REPO_YUM_BASEURL
repo::_served_quiet() {
  local ca=()
  repo::tls && ca=(--cacert "$PKI_DIR/ca.pem")
  curl -fsS "${ca[@]}" -o /dev/null "${REPO_YUM_BASEURL%/}/confluent/repodata/repomd.xml" 2>/dev/null
}

repo::tls_port() {
  local hp=${REPO_YUM_BASEURL#https://}
  hp=${hp%%/*}
  [[ $hp == *:* ]] && printf '%s' "${hp##*:}" || printf '443'
}

repo::_httpd_conf() { # <out>
  local port name
  port=$(repo::tls_port)
  name=${REPO_YUM_BASEURL#https://}
  name=${name%%[:/]*}
  cat >"$1" <<EOF
# Managed by cpctl - internal repository, HTTPS only (plain HTTP answers 403)
DocumentRoot "$REPO_LOCAL_ROOT"
<Directory "$REPO_LOCAL_ROOT">
    Require all denied
</Directory>

Listen $port https
<VirtualHost *:$port>
    ServerName $name
    SSLEngine on
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLCertificateFile $REPO_TLS_CERT
    SSLCertificateKeyFile $REPO_TLS_KEY
    DocumentRoot "$REPO_LOCAL_ROOT"
    <Directory "$REPO_LOCAL_ROOT">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
        <LimitExcept GET HEAD OPTIONS>
            Require all denied
        </LimitExcept>
    </Directory>
</VirtualHost>
EOF
}

# repo::tls_configure -> certificate + key + vhost on the ops host; restart httpd only when something changed
repo::tls_configure() {
  local h changed=0 t
  h=$(inv::hosts ops | head -1)
  [[ -f $PKI_DIR/cp-server.crt && -f $PKI_DIR/cp-server.key ]] || core::die "$E_PRECHECK" "repo over HTTPS needs the cp-server certificate (step 03 / bank)"
  remote::put "$h" "$PKI_DIR/cp-server.crt" "$REPO_TLS_CERT" root root 0644; ((REMOTE_CHANGED)) && changed=1
  remote::put "$h" "$PKI_DIR/cp-server.key" "$REPO_TLS_KEY" root root 0600; ((REMOTE_CHANGED)) && changed=1
  t=$(render::tmp)
  repo::_httpd_conf "$t"
  remote::put "$h" "$t" /etc/httpd/conf.d/cp-repo.conf root root 0644; ((REMOTE_CHANGED)) && changed=1
  # mod_ssl's own default vhost (port 443, self-signed certificate) must not exist
  printf '# Managed by cpctl - default mod_ssl vhost disabled; the internal repo is served by cp-repo.conf\n' >"$t"
  remote::put "$h" "$t" /etc/httpd/conf.d/ssl.conf root root 0644; ((REMOTE_CHANGED)) && changed=1
  rm -f "$t"
  # restart when something changed - or when the repo is not actually served (an earlier run wrote the files
  # and failed before the restart: file comparison alone would never restart httpd again)
  if step::mutating && { ((changed)) || ! repo::_served_quiet; }; then
    remote::apply "$h" sys_node::httpd_restart || core::die "[$h] httpd rejected the repo configuration"
    log::changed "[$h] httpd restarted: repo served over HTTPS on port $(repo::tls_port)"
  fi
  return 0
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
readonly REPO_CA_FILE=/etc/pki/tls/certs/cp-repo-ca.pem

# repo::is_server <host> -> the host that serves the internal repo (reads it from disk, no network)
repo::is_server() { [[ $REPO_PROVIDER == local && $(inv::hosts ops | head -1) == "$1" ]]; }

# repo::base_for <host> -> baseurl for that host: the repo server itself uses file://, so it can install
# its own packages (JDK, mod_ssl) before the HTTPS listener and its certificate exist
repo::base_for() {
  if repo::is_server "$1"; then printf 'file://%s/rpm' "$REPO_LOCAL_ROOT"; else printf '%s' "${REPO_YUM_BASEURL%/}"; fi
}

# repo::tls_lines <host> -> sslverify + the CA file to pin (HTTPS clients only)
repo::tls_lines() {
  repo::tls && ! repo::is_server "$1" && printf 'sslverify=1\nsslcacert=%s\n' "$REPO_CA_FILE"
  return 0
}

# repo::clients -> every host that installs from the internal repo over the network
repo::clients() {
  local h
  for h in $(inv::hosts ops) $(inv::hosts controller) $(inv::hosts broker) $(inv::hosts rest) $(inv::hosts c3) $(inv::hosts jump); do
    repo::is_server "$h" || printf '%s\n' "$h"
  done
}

# repo::trust_push <host> -> the CA file dnf / curl pin for the repo (= trust bundle; follows rotations)
repo::trust_push() {
  repo::tls || return 0
  repo::is_server "$1" && return 0
  [[ -f $PKI_DIR/ca.pem ]] || core::die "$E_PRECHECK" "repo over HTTPS: no trust bundle yet ($PKI_DIR/ca.pem)"
  remote::put "$1" "$PKI_DIR/ca.pem" "$REPO_CA_FILE" root root 0644
}

