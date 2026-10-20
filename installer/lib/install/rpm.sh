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

install::_repo_file() { # <out> <host>
  local out=$1 base tls
  base=$(repo::base_for "$2")
  tls=$(repo::tls_lines "$2")
  cat >"$out" <<EOF
# Managed by cpctl - internal mirror only (public repos are not reachable from this network)
[cp-internal-confluent]
name=Internal mirror - Confluent Platform and Control Center
baseurl=$base/confluent
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-confluent
$tls
[cp-internal-adoptium]
name=Internal mirror - Eclipse Temurin
baseurl=$base/adoptium
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-adoptium
$tls
[cp-internal-os-deps]
name=Internal mirror - OS dependencies
baseurl=$base/os-deps
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
$tls
EOF
}

install::prepare() {
  local host=$1 tmp k
  repo::trust_push "$host"
  tmp=$(render::tmp)
  install::_repo_file "$tmp" "$host"
  remote::put "$host" "$tmp" /etc/yum.repos.d/cp-internal.repo root root 0644
  for k in "${INSTALL_KEYS[@]}"; do
    remote::put "$host" "$REPO_LOCAL_ROOT/gpg-keys/$k.asc" "/etc/pki/rpm-gpg/RPM-GPG-KEY-cp-$k" root root 0644
  done
  remote::apply "$host" rpm_node::import_keys /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-confluent \
    /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-adoptium /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
}

install::packages_for() {
  local v="PKGS_${1^^}"
  printf '%s\n' ${!v}
}

# install::ensure <host> <install|upgrade> <cp version> <role>
install::ensure() {
  local host=$1 mode=$2 ver=$3 role=$4 specs=() os=() p
  # exact versions + versionlock: Confluent and the JDK (a JDK change means a planned rolling restart)
  specs+=("$JDK_PACKAGE=$(install::jdk_version)")
  if [[ $role == c3 ]]; then
    specs+=("confluent-control-center-next-gen=$C3_VERSION")
    os+=($PKGS_C3_OS)
  else
    for p in $(install::packages_for "$role"); do specs+=("$p=$ver"); done
  fi
  # the repo server needs httpd's TLS module to serve the internal repo over HTTPS
  if repo::is_server "$host" && repo::tls; then os+=(${PKGS_OPS_OS:-}); fi
  remote::apply "$host" rpm_node::ensure "$mode" "${specs[@]}"
  # other OS packages: any version the OS repo has, not locked (they follow the bank's OS patching)
  if [[ ${#os[@]} -gt 0 ]]; then remote::apply "$host" os_node::pkgs_unlocked "${os[@]}"; fi
}

# OS dependencies are pinned to whatever version was imported into the internal repo.
install::os_dep_version() {
  local f
  f=$(find "$REPO_LOCAL_ROOT/rpm/os-deps" -name "$1-[0-9]*.rpm" 2>/dev/null | sort -V | tail -1)
  [[ -n $f ]] || core::die "OS dependency $1 not found in the internal repo"
  rpm -qp --qf '%{VERSION}' "$f" 2>/dev/null
}

# install::available <cp version>  -> target packages are published in the internal repo
install::available() { [[ -n $(find "$REPO_LOCAL_ROOT/rpm/confluent" -name "confluent-server-$1-*.rpm") ]]; }

# install::pinned <host>  -> the installed version is protected against accidental OS patching
install::pinned() { remote::run "$1" sys_node::versionlocked confluent-server >/dev/null; }

install::version() { remote::run "$1" rpm_node::installed confluent-server 2>/dev/null || true; }
install::rest_version() { remote::run "$1" rpm_node::installed confluent-kafka-rest 2>/dev/null || true; }

# Paths (the tar strategy implements the same functions with /opt/... locations)
install::bin_dir() { printf '/usr/bin'; }
install::bin() { printf '%s/%s' "$(install::bin_dir)" "$1"; }
install::kafka_etc() { printf '/etc/kafka'; }            # shipped log4j2.yaml / tools-log4j2.yaml
install::c3_bin_dir() { printf '/usr/bin'; }
install::cli() { printf '/usr/bin/confluent'; }
install::java_home() { printf '%s' "${JDK_HOME:-/usr/lib/jvm/temurin-21-jdk}"; }

# install::jdk_version -> exact JDK version to install: the OS repo's (JDK_SOURCE=os) or the pinned vendor one
install::jdk_version() {
  if [[ ${JDK_SOURCE:-vendor} == os ]]; then install::os_dep_version "$JDK_PACKAGE"; else printf '%s' "$JDK_VERSION"; fi
}

# install::jdk_hosts -> every host that runs Java (the hosts step 02 installs)
install::jdk_hosts() { inv::hosts ops; inv::hosts controller; inv::hosts broker; inv::hosts rest; inv::hosts c3; inv::hosts jump; }

# install::retire_jdk -> remove the JDK packages nothing runs on any more (JDK_RETIRED). Called by step 05 only
# after every restart with the new JAVA_HOME passed its health gate.
install::retire_jdk() {
  [[ -n ${JDK_RETIRED:-} ]] || return 0
  local h old=()
  read -ra old <<<"$JDK_RETIRED"
  for h in $(install::jdk_hosts); do remote::apply "$h" rpm_node::remove "${old[@]}"; done
}
install::tools_opts() { printf -- '-Dlog4j2.configurationFile=%s/tools-log4j2.yaml' "$(install::kafka_etc)"; }

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
