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
  [[ ${#todo[@]} -eq 0 || ${CPCTL_CHECK:-0} == 1 ]] && return 0
  local dnf=(dnf -y -q --disablerepo='*' --enablerepo='cp-internal-*' --setopt=install_weak_deps=False)
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
}

# rpm_node::locked -> versionlock list
rpm_node::locked() { dnf versionlock list 2>/dev/null | grep -v '^Last metadata' || true; }

rpm_node::remove() {
  local p present=()
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 && present+=("$p"); done
  [[ ${#present[@]} -eq 0 ]] && { _mark ok "packages absent"; return 0; }
  _mark changed "remove ${present[*]}"
  [[ ${CPCTL_CHECK:-0} == 1 ]] && return 0
  dnf versionlock delete "${present[@]}" >/dev/null 2>&1 || true
  dnf -y -q remove "${present[@]}"
}
