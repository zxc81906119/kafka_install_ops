# Node-side part of the RPM install strategy (shipped with remote::run).

# rpm_node::import_keys <key file...>   keys were staged by the ops host (already verified there)
rpm_node::import_keys() {
  local k fpr
  for k in "$@"; do
    fpr=$(gpg --show-keys --with-colons "$k" 2>/dev/null | awk -F: '/^fpr/ {print tolower(substr($10, 33)); exit}')
    if [[ -n $fpr ]] && rpm -q "gpg-pubkey-${fpr: -8}" >/dev/null 2>&1; then
      _mark ok "rpm key $(basename "$k") imported"
      continue
    fi
    _mark changed "rpm --import $(basename "$k")"
    [[ ${CPCTL_CHECK:-0} == 1 ]] || rpm --import "$k"
  done
}

# rpm_node::installed <name>  -> version or empty
rpm_node::installed() { rpm -q --qf '%{VERSION}' "$1" 2>/dev/null | grep -v 'not installed' || true; }

# rpm_node::ensure <mode> <name=version>...
#   mode=install : install if absent; a different installed version is an error (use cpctl upgrade)
#   mode=upgrade : move to exactly this version (upgrade or downgrade), keeping versionlock in sync
rpm_node::ensure() {
  local mode=$1; shift
  local spec name ver cur todo=() unlock=()
  for spec in "$@"; do
    name=${spec%%=*}; ver=${spec#*=}
    cur=$(rpm_node::installed "$name")
    if [[ $cur == "$ver" ]]; then
      _mark ok "package $name-$ver"
      continue
    fi
    if [[ -n $cur && $mode == install ]]; then
      _mark warn "package $name is $cur, expected $ver - refusing to change versions during install (use: cpctl upgrade)"
      return 3
    fi
    _mark changed "package $name ${cur:+$cur -> }$ver"
    todo+=("$name-$ver")
    [[ -n $cur ]] && unlock+=("$name")
  done
  if [[ ${#todo[@]} -gt 0 && ${CPCTL_CHECK:-0} != 1 ]]; then
    local dnf=(dnf -y -q --disablerepo='*' --enablerepo='cp-internal-*' --setopt=install_weak_deps=False)
    # the pulled-in confluent-* packages are locked too (see rpm_node::lock_deps): unlock them for the move
    local deps=()
    mapfile -t deps < <(rpm_node::_confluent_installed | sed 's/-[^-]*-[^-]*$//')
    unlock+=("${deps[@]}")
    if [[ ${#unlock[@]} -gt 0 ]]; then
      dnf versionlock delete "${unlock[@]}" >/dev/null 2>&1 || true
    fi
    if [[ $mode == upgrade ]]; then
      "${dnf[@]}" install "${todo[@]}" || "${dnf[@]}" downgrade "${todo[@]}"
    else
      "${dnf[@]}" install "${todo[@]}"
    fi
    local p
    for p in "${todo[@]}"; do dnf versionlock add "$p" >/dev/null 2>&1 || true; done
  fi
  rpm_node::lock_deps
}

# installed confluent-* packages as name-version-release
rpm_node::_confluent_installed() { rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 'confluent-*' 2>/dev/null | sort; }

# rpm_node::lock_deps -> every installed confluent-* package is version-locked, including the ones pulled in
# as dependencies (confluent-common, -rest-utils, -telemetry, ...), so an OS patch run cannot move them
# away from the version confluent-server was tested with.
rpm_node::lock_deps() {
  local locked p n
  locked=$(dnf versionlock list 2>/dev/null)
  while read -r p; do
    [[ -n $p ]] || continue
    n=$(sed 's/-[^-]*-[^-]*$//' <<<"$p")
    if grep -q "^$n-[0-9]*:" <<<"$locked"; then continue; fi
    _mark changed "versionlock dependency $p"
    [[ ${CPCTL_CHECK:-0} == 1 ]] || dnf versionlock add "$p" >/dev/null 2>&1 || true
  done < <(rpm_node::_confluent_installed)
}

# rpm_node::locked -> versionlock list
rpm_node::locked() { dnf versionlock list 2>/dev/null | grep -v '^Last metadata' || true; }

rpm_node::remove() {
  local p present=()
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 && present+=("$p"); done
  [[ ${#present[@]} -eq 0 ]] && { _mark ok "packages absent"; return 0; }
  _mark changed "remove ${present[*]}"
  [[ ${CPCTL_CHECK:-0} == 1 ]] && return 0
  local deps=()
  mapfile -t deps < <(rpm_node::_confluent_installed | sed 's/-[^-]*-[^-]*$//')
  dnf versionlock delete "${present[@]}" "${deps[@]}" >/dev/null 2>&1 || true
  dnf -y -q remove "${present[@]}"
}
