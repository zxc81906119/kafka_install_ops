# Node-side idempotent primitives. Shipped to the target host on every remote::run call
# (no agent to install). They run as root and print markers that the ops side turns into
# ok/changed counts:  ::ok:: <msg> | ::changed:: <msg> | ::skipped:: <msg> | ::warn:: <msg>
# CPCTL_CHECK=1 -> report what would change, change nothing.

_mark() { printf '::%s:: %s\n' "$1" "$2"; }
_checking() { [[ ${CPCTL_CHECK:-0} == 1 ]]; }

node::in_container() { [[ -f /.dockerenv ]] || systemd-detect-virt -c -q 2>/dev/null; }
node::has_systemd() { [[ -d /run/systemd/system ]]; }

# ensure::dir <path> <owner> <group> <mode>
ensure::dir() {
  local p=$1 o=$2 g=$3 m=$4
  if [[ -d $p && $(stat -c '%U:%G:%a' "$p") == "$o:$g:${m#0}" ]]; then
    _mark ok "dir $p"
    return 0
  fi
  _mark changed "dir $p ($o:$g $m)"
  _checking && return 0
  install -d -o "$o" -g "$g" -m "$m" "$p"
  chown "$o:$g" "$p"; chmod "$m" "$p"
}

# ensure::file <staged tmp file> <dest> <owner> <group> <mode>
# Content compared by sha256. On change the previous file is kept as <dest>.bak.<timestamp>.
ensure::file() {
  local src=$1 dst=$2 o=$3 g=$4 m=$5
  local new old=""
  new=$(sha256sum "$src" | awk '{print $1}')
  [[ -f $dst ]] && old=$(sha256sum "$dst" | awk '{print $1}')
  if [[ $new == "$old" ]]; then
    if [[ $(stat -c '%U:%G:%a' "$dst") != "$o:$g:${m#0}" ]]; then
      _mark changed "perms $dst ($o:$g $m)"
      _checking || { chown "$o:$g" "$dst"; chmod "$m" "$dst"; }
    else
      _mark ok "file $dst"
    fi
    rm -f "$src"
    return 0
  fi
  if [[ -n $old ]]; then
    _mark changed "file $dst (content changed)"
    if [[ ${CPCTL_DIFF:-0} == 1 ]]; then
      if command -v diff >/dev/null; then
        diff -u "$dst" "$src" | sed -e 's/^/    /' | head -80 | grep -v -i -E 'password|secret|credentials' || true
      else # minimal OS without diffutils: removed / added lines (order-insensitive)
        { grep -Fxv -f "$src" "$dst" | sed 's/^/    -/'; grep -Fxv -f "$dst" "$src" | sed 's/^/    +/'; } |
          head -80 | grep -v -i -E 'password|secret|credentials|securepass|ENC\[' || true
      fi
    fi
  else
    _mark changed "file $dst (new)"
  fi
  if _checking; then rm -f "$src"; return 0; fi
  [[ -d $(dirname "$dst") ]] || install -d "$(dirname "$dst")"   # never touch an existing dir's mode
  [[ -n $old ]] && cp -p "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
  install -o "$o" -g "$g" -m "$m" "$src" "$dst"
  rm -f "$src"
}

# ensure::symlink <target> <link>
ensure::symlink() {
  local t=$1 l=$2
  if [[ -L $l && $(readlink "$l") == "$t" ]]; then _mark ok "symlink $l -> $t"; return 0; fi
  _mark changed "symlink $l -> $t"
  _checking && return 0
  ln -sfn "$t" "$l"
}

# ensure::absent <path>
ensure::absent() {
  if [[ ! -e $1 && ! -L $1 ]]; then _mark ok "absent $1"; return 0; fi
  _mark changed "remove $1"
  _checking || rm -rf -- "$1"
}

# ensure::sysctl <key> <value> <conf file>
# Containers: non-namespaced keys (vm.*) cannot be set -> only checked (skipped/warn).
ensure::sysctl() {
  local k=$1 v=$2 f=$3 cur
  cur=$(sysctl -n "$k" 2>/dev/null | tr -s '\t ' ' ' || true)
  local want
  want=$(tr -s '\t ' ' ' <<<"$v")
  local line="$k = $v"
  local persisted=0
  grep -qxF "$line" "$f" 2>/dev/null && persisted=1
  if [[ $cur == "$want" && $persisted == 1 ]]; then _mark ok "sysctl $k=$v"; return 0; fi
  if node::in_container && [[ $k == vm.* || $k == kernel.* ]]; then
    if [[ $cur == "$want" ]]; then _mark ok "sysctl $k=$v (host kernel)"
    else _mark warn "sysctl $k is $cur, want $v (container: set it on the WSL2/host kernel)"; fi
    return 0
  fi
  if node::in_container && ! _checking && [[ $cur != "$want" ]]; then
    # some net.core.* keys are host-wide too: probe once, report instead of "changing" every run
    if ! sysctl -q -w "$k=$v" >/dev/null 2>&1 || [[ $(sysctl -n "$k" | tr -s "	 " " ") != "$want" ]]; then
      _mark warn "sysctl $k is $cur, want $v (not settable inside the container; set on the host kernel)"
      return 0
    fi
  fi
  _mark changed "sysctl $k=$v (was ${cur:-unset})"
  _checking && return 0
  install -d -m 0755 "$(dirname "$f")"
  touch "$f"
  sed -i "\\|^${k}[ =]|d" "$f"
  printf '%s\n' "$line" >>"$f"
  sysctl -q -w "$k=$v" >/dev/null 2>&1 || _mark warn "sysctl -w $k failed (read-only in this environment?)"
}

# ensure::line <file> <exact line>   (append if missing)
ensure::line() {
  local f=$1 l=$2
  if grep -qxF -- "$l" "$f" 2>/dev/null; then _mark ok "line in $f"; return 0; fi
  _mark changed "line in $f: $l"
  _checking || printf '%s\n' "$l" >>"$f"
}

# ensure::user_exists <user>   (service users are created by RPM scriptlets - we only verify)
ensure::user_exists() {
  if id "$1" >/dev/null 2>&1; then _mark ok "user $1 exists"; else _mark warn "user $1 missing"; return 1; fi
}

# ensure::ca_trust <pem file>  -> OS trust store (curl/openssl/LDAP tools)
ensure::ca_trust() {
  local src=$1 dst=/etc/pki/ca-trust/source/anchors/cp-internal-ca.pem
  if [[ -f $dst && $(sha256sum <"$src") == $(sha256sum <"$dst") ]]; then _mark ok "OS trust has internal CA"; return 0; fi
  _mark changed "OS trust: install internal CA"
  _checking && return 0
  install -m 0644 "$src" "$dst"
  update-ca-trust extract
}

# node::facts -> key=value lines used by precheck/os_baseline
node::facts() {
  printf 'os=%s\n' "$(. /etc/os-release && echo "$ID-$VERSION_ID")"
  printf 'kernel=%s\n' "$(uname -r)"
  printf 'container=%s\n' "$(node::in_container && echo yes || echo no)"
  printf 'systemd=%s\n' "$(node::has_systemd && echo yes || echo no)"
  printf 'fqdn=%s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'cpus=%s\n' "$(nproc)"
  printf 'mem_mb=%s\n' "$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  printf 'disk_var_free_mb=%s\n' "$(df -Pm /var | awk 'NR==2 {print $4}')"
  printf 'tmp_free_mb=%s\n' "$(df -Pm /tmp | awk 'NR==2 {print $4}')"
  printf 'tmp_noexec=%s\n' "$(grep -q noexec <<<"$(findmnt -no OPTIONS /tmp 2>/dev/null)" && echo yes || echo no)"
  printf 'nofile=%s\n' "$(ulimit -n)"
  printf 'time_epoch=%s\n' "$(date +%s)"
}
