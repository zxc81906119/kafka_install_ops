#!/usr/bin/env bash
# Install strategy: tar.gz archives from the internal raw repo (INSTALL_METHOD=tar).
# Same interface as rpm.sh, so roles / steps / upgrade code are unchanged:
#   install::prepare <host>                         accounts, dirs, OS-deps repo (for C3 prerequisites)
#   install::ensure <host> <mode> <version> <role>  JDK + CP or C3 archive extracted side by side, symlink, units
#   install::version / install::rest_version <host>
#   install::bin_dir / bin / kafka_etc / c3_bin_dir / cli / java_home / tools_opts / unit / remove
# Integrity: CP and C3 archives carry no vendor signature -> the sha256 recorded at download time
# (SHA256SUMS, re-verified at repo import) is verified again on every node before extraction.
[[ -n ${_LIB_INSTALL_LOADED:-} ]] && return 0
_LIB_INSTALL_LOADED=1

readonly TAR_BASE=/opt/confluent
readonly TAR_RAW=${REPO_RAW_BASEURL%/}/tar

install::bin_dir() { printf '%s/current/bin' "$TAR_BASE"; }
install::bin() { printf '%s/%s' "$(install::bin_dir)" "$1"; }
install::kafka_etc() { printf '%s/current/etc/kafka' "$TAR_BASE"; }
install::c3_bin_dir() { printf '%s/c3-current/bin' "$TAR_BASE"; }
install::cli() { printf '%s/current/bin/confluent' "$TAR_BASE"; }   # the CP archive ships the CLI
install::java_home() { printf '/opt/java/current'; }
install::tools_opts() { printf -- '-Dlog4j2.configurationFile=%s/tools-log4j2.yaml' "$(install::kafka_etc)"; }

install::unit() {
  case $1 in
    controller | broker) printf 'confluent-server' ;;
    rest) printf 'confluent-kafka-rest' ;;
    c3) printf 'confluent-control-center' ;;
    prometheus) printf 'prometheus' ;;
    alertmanager) printf 'alertmanager' ;;
    *) core::die "no unit for role $1" ;;
  esac
}

# ---- archive bookkeeping on the ops host
install::_archive() { # <kind> [version] -> file name in /srv/repo/raw/tar
  local f
  case $1 in
    cp) f="confluent-$2.tar.gz" ;;
    c3) f="confluent-control-center-next-gen-$2.tar.gz" ;;
    jdk) f=$(cd "$REPO_LOCAL_ROOT/raw/tar" 2>/dev/null && ls OpenJDK${JDK_TAR_MAJOR}U-jdk_x64_linux_hotspot_*.tar.gz 2>/dev/null | sort -V | tail -1) ;;
  esac
  [[ -n $f && -f $REPO_LOCAL_ROOT/raw/tar/$f ]] ||
    core::die "$E_PRECHECK" "archive for '$1 ${2:-}' not in the internal repo (download with --method tar, then cpctl repo import)"
  printf '%s' "$f"
}

install::_sha() { # <file>  (cached per run: the archives are large)
  local c="$RUN_DIR/sha.$1"
  [[ -s $c ]] || sha256sum "$REPO_LOCAL_ROOT/raw/tar/$1" | awk '{print $1}' >"$c"
  cat "$c"
}

# install::_fetch <host> <file> <parent dir>  -> prints the archive top directory
install::_fetch() {
  local host=$1 file=$2 parent=$3 out rc=0
  out=$(remote::run "$host" tar_node::fetch_extract "$TAR_RAW/$file" "$(install::_sha "$file")" "$parent" 2>&1) || rc=$?
  log::consume "[$host]" < <(grep -v '^TOP=' <<<"$out")
  [[ $rc -eq 0 ]] || { log::error "[$host] fetch/extract $file failed (rc=$rc)"; return "$rc"; }
  sed -n 's/^TOP=//p' <<<"$out" | tail -1
}

install::_units() { # <host> <unit...>
  local host=$1; shift
  local u t changed=0
  export CP_HOME="$TAR_BASE/current" C3_HOME="$TAR_BASE/c3-current"
  for u in "$@"; do
    t=$(render::tmp)
    render::to "systemd/tar/$u.service.tpl" "$t"
    remote::put "$host" "$t" "/etc/systemd/system/$u.service" root root 0644
    [[ $REMOTE_CHANGED == 1 ]] && changed=1
    rm -f "$t"
  done
  [[ $changed == 1 ]] && remote::run "$host" svc::daemon_reload
  return 0
}

# ---- interface
install::prepare() {
  local host=$1 role
  role=$(inv::roles "$host" | grep -E '^(ops|controller|broker|rest|c3|controller_spare|jump)$' | head -1)
  # OS packages (C3 prerequisites, chrony, firewalld) still come from the internal OS-deps yum repo
  local tmp
  tmp=$(render::tmp)
  printf '# Managed by cpctl - internal OS dependencies only\n[cp-internal-os-deps]\nname=Internal mirror - OS dependencies\nbaseurl=%s/os-deps\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9\n' \
    "${REPO_YUM_BASEURL%/}" >"$tmp"
  remote::put "$host" "$tmp" /etc/yum.repos.d/cp-internal.repo root root 0644
  remote::put "$host" "$REPO_LOCAL_ROOT/gpg-keys/rocky-9.asc" /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9 root root 0644
  remote::apply "$host" rpm_node::import_keys /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
  # service accounts and directories (the RPM scriptlets do this in the rpm strategy)
  case $role in
    controller | broker | controller_spare)
      remote::apply "$host" tar_node::account cp-kafka /var/lib/kafka
      remote::apply "$host" ensure::dir /var/lib/kafka cp-kafka confluent 0750
      remote::apply "$host" ensure::dir /var/log/kafka cp-kafka confluent 0750
      ;;
    rest)
      remote::apply "$host" tar_node::account cp-kafka-rest /tmp
      remote::apply "$host" ensure::dir /var/log/confluent cp-kafka-rest confluent 0770
      remote::apply "$host" ensure::dir /var/log/confluent/kafka-rest cp-kafka-rest confluent 0750
      ;;
    c3)
      remote::apply "$host" tar_node::account cp-control-center /var/lib/confluent/control-center
      remote::apply "$host" ensure::dir /var/lib/confluent root root 0755
      remote::apply "$host" ensure::dir /var/lib/confluent/control-center cp-control-center confluent 0750
      remote::apply "$host" ensure::dir /var/log/confluent cp-control-center confluent 0770
      remote::apply "$host" ensure::dir /var/log/confluent/control-center cp-control-center confluent 0750
      ;;
    ops)
      remote::run "$host" bash -c 'getent group confluent >/dev/null || groupadd -r confluent' >/dev/null
      ;;
  esac
}

install::os_dep_version() {
  local f
  f=$(find "$REPO_LOCAL_ROOT/rpm/os-deps" -name "$1-[0-9]*.rpm" 2>/dev/null | sort -V | tail -1)
  [[ -n $f ]] || core::die "OS dependency $1 not found in the internal repo"
  rpm -qp --qf '%{VERSION}' "$f" 2>/dev/null
}

# install::ensure <host> <install|upgrade> <cp version> <role>
install::ensure() {
  local host=$1 mode=$2 ver=$3 role=$4 top
  # JDK (shared by every Java role)
  top=$(install::_fetch "$host" "$(install::_archive jdk)" /opt/java) || return 1
  [[ -n $top ]] && remote::apply "$host" tar_node::switch upgrade /opt/java/current "$top"
  if [[ $role == c3 ]]; then
    local p specs=()
    for p in $PKGS_C3_OS; do specs+=("$p=$(install::os_dep_version "$p")"); done
    remote::apply "$host" rpm_node::ensure install "${specs[@]}"
    top=$(install::_fetch "$host" "$(install::_archive c3 "$C3_VERSION")" "$TAR_BASE") || return 1
    [[ -n $top ]] || return 0
    remote::apply "$host" tar_node::switch "$mode" "$TAR_BASE/c3-current" "$top" || return 1
    remote::apply "$host" tar_node::seed_dir "$TAR_BASE/$top/etc/confluent-control-center" /etc/confluent-control-center
    install::_units "$host" confluent-control-center prometheus alertmanager
    return 0
  fi
  top=$(install::_fetch "$host" "$(install::_archive cp "$ver")" "$TAR_BASE") || return 1
  [[ -n $top ]] || return 0
  remote::apply "$host" tar_node::switch "$mode" "$TAR_BASE/current" "$top" || return 1
  case $role in
    controller | broker | controller_spare) install::_units "$host" confluent-server ;;
    rest) install::_units "$host" confluent-kafka-rest ;;
    ops | jump) : ;; # tools only (kafka-*, confluent CLI from the same archive) - no service
  esac
}

install::available() { [[ -f $REPO_LOCAL_ROOT/raw/tar/confluent-$1.tar.gz ]]; }

# tar installs are outside the package manager: "pinned" = the current symlink is the only active version
install::pinned() { [[ -n $(install::version "$1") ]]; }

install::version() { remote::run "$1" tar_node::current "$TAR_BASE/current" 2>/dev/null | sed -n 's/^confluent-//p'; }
install::rest_version() { install::version "$1"; }

install::remove() {
  local host=$1 role=$2
  case $role in
    # patterns stay quoted here: they are expanded on the target node, not on the ops host
    c3) remote::apply "$host" tar_node::remove_paths "$TAR_BASE/c3-current" "$TAR_BASE/confluent-control-center-next-gen-*" \
      /etc/systemd/system/confluent-control-center.service /etc/systemd/system/prometheus.service /etc/systemd/system/alertmanager.service ;;
    rest) remote::apply "$host" tar_node::remove_paths "$TAR_BASE/current" "$TAR_BASE/confluent-[0-9]*" /etc/systemd/system/confluent-kafka-rest.service ;;
    *) remote::apply "$host" tar_node::remove_paths "$TAR_BASE/current" "$TAR_BASE/confluent-[0-9]*" /etc/systemd/system/confluent-server.service ;;
  esac
  remote::apply "$host" tar_node::remove_paths "$TAR_BASE/.cpctl"
}
