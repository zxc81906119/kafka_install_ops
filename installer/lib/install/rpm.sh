#!/usr/bin/env bash
# Install strategy: RPM from the internal yum repo (default, recommended for RHEL 9 banks).
# Interface (shared with tar.sh):
#   install::prepare <host>                         repo definition + GPG keys
#   install::ensure <host> <mode> <version> <role>  role packages + JDK at exact versions
#   install::version <host>                         installed CP version
#   install::bin <tool>                             absolute path of a CP tool on the node
#   install::etc_dir / install::unit <role>
[[ -n ${_LIB_INSTALL_LOADED:-} ]] && return 0
_LIB_INSTALL_LOADED=1

readonly INSTALL_KEYS=(confluent adoptium rocky-9)

install::_repo_file() {
  local out=$1
  local base=${REPO_YUM_BASEURL%/}
  cat >"$out" <<EOF
# Managed by cpctl - internal mirror only (public repos are not reachable from this network)
[cp-internal-confluent]
name=Internal mirror - Confluent Platform and Control Center
baseurl=$base/confluent
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-confluent

[cp-internal-adoptium]
name=Internal mirror - Eclipse Temurin
baseurl=$base/adoptium
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-adoptium

[cp-internal-os-deps]
name=Internal mirror - OS dependencies
baseurl=$base/os-deps
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
EOF
}

install::prepare() {
  local host=$1 tmp k
  tmp=$(render::tmp)
  install::_repo_file "$tmp"
  remote::put "$host" "$tmp" /etc/yum.repos.d/cp-internal.repo root root 0644
  for k in "${INSTALL_KEYS[@]}"; do
    remote::put "$host" "$REPO_LOCAL_ROOT/gpg-keys/$k.asc" "/etc/pki/rpm-gpg/RPM-GPG-KEY-cp-$k" root root 0644
  done
  remote::apply "$host" rpm_node::import_keys /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-confluent \
    /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-adoptium /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
}

# install::packages_for <role> -> package names
install::packages_for() {
  local v="PKGS_${1^^}"
  printf '%s\n' ${!v}
}

# install::ensure <host> <install|upgrade> <cp version> <role>
install::ensure() {
  local host=$1 mode=$2 ver=$3 role=$4 specs=() p
  specs+=("$JDK_PACKAGE=$JDK_VERSION")
  if [[ $role == c3 ]]; then
    specs+=("confluent-control-center-next-gen=$C3_VERSION")
    for p in $PKGS_C3_OS; do specs+=("$p=$(install::os_dep_version "$p")"); done
  else
    for p in $(install::packages_for "$role"); do specs+=("$p=$ver"); done
  fi
  remote::apply "$host" rpm_node::ensure "$mode" "${specs[@]}"
}

# OS dependencies are pinned to whatever version was imported into the internal repo.
install::os_dep_version() {
  local f
  f=$(find "$REPO_LOCAL_ROOT/rpm/os-deps" -name "$1-[0-9]*.rpm" 2>/dev/null | sort -V | tail -1)
  [[ -n $f ]] || core::die "OS dependency $1 not found in the internal repo"
  rpm -qp --qf '%{VERSION}' "$f" 2>/dev/null
}

install::version() { remote::run "$1" rpm_node::installed confluent-server 2>/dev/null || true; }
install::rest_version() { remote::run "$1" rpm_node::installed confluent-kafka-rest 2>/dev/null || true; }

install::bin() { printf '/usr/bin/%s' "$1"; }
install::java_home() { printf '/usr/lib/jvm/temurin-21-jdk'; }

# install::unit <role> -> systemd unit shipped by the RPM
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

install::remove() {
  local host=$1 role=$2
  case $role in
    c3) remote::apply "$host" rpm_node::remove confluent-control-center-next-gen ;;
    *) mapfile -t _pk < <(install::packages_for "$role"); remote::apply "$host" rpm_node::remove "${_pk[@]}" ;;
  esac
}
