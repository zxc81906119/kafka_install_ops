# Node-side OS hardening / services (step 01_os_baseline). Run as root. Check-then-act, CPCTL_CHECK aware.

# os_node::pkgs <package...>   OS packages from the internal os-deps mirror only (never the Internet)
os_node::pkgs() {
  local p missing=()
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [[ ${#missing[@]} -eq 0 ]]; then _mark ok "packages $*"; return 0; fi
  _mark changed "install ${missing[*]} (internal os-deps mirror)"
  _checking && return 0
  dnf -y -q --refresh --disablerepo='*' --enablerepo='cp-internal-os-deps' --setopt=install_weak_deps=False install "${missing[@]}"
}

# os_node::thp_report -> current THP mode (the unit itself is skipped by systemd inside containers)
os_node::thp_report() {
  local cur
  cur=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)
  if node::in_container; then
    _mark skipped "THP is a host-kernel setting (container: now '$cur'; disable-thp.service applies on real hosts)"
  elif [[ $cur == never ]]; then
    _mark ok "transparent hugepages: never"
  else
    _mark warn "transparent hugepages: $cur (expected never - reboot or start disable-thp.service)"
  fi
}

# os_node::chrony_sync -> reports whether chronyd follows a configured source
os_node::chrony_sync() {
  local src
  _checking && { _mark ok "chrony check skipped (check mode)"; return 0; }
  src=$(chronyc -n sources 2>/dev/null | awk '/^\^\*/ {print $2}')
  if [[ -z $src ]] && ! grep -q '^server ' /etc/chrony.conf && grep -q '^local stratum' /etc/chrony.conf; then
    _mark ok "chrony serves its local clock to the subnet (no upstream configured; prod: point NTP_SERVERS to the bank NTP)"
  elif [[ -n $src ]]; then
    _mark ok "chrony synchronised to $src (offset $(chronyc tracking 2>/dev/null | awk -F': ' '/System time/ {print $2}'))"
  else
    _mark warn "chrony has no selected source yet ($(chronyc -n sources 2>/dev/null | awk 'NR>2 {printf "%s %s; ", $1, $2}'))"
  fi
}

# os_node::firewall <port[/proto]...>   default zone allows ssh + these ports (tcp unless given); extras are reported, not removed
os_node::firewall() {
  local want=() have p add=() changed=0 FW_REMOVE_SERVICES=""
  for p in "$@"; do
    case $p in
      --remove=*) p=${p#--remove=}; FW_REMOVE_SERVICES=${p//,/ } ;;
      */*) want+=("$p") ;;
      *) want+=("$p/tcp") ;;
    esac
  done
  if ! systemctl is-active -q firewalld; then
    _mark changed "enable + start firewalld"
    if ! _checking; then systemctl enable -q --now firewalld || { _mark warn "firewalld cannot start here"; return 0; }; fi
  else
    _mark ok "firewalld active"
  fi
  _checking && ! systemctl is-active -q firewalld && return 0
  have=$(firewall-cmd --permanent --list-ports 2>/dev/null)
  for p in "${want[@]}"; do [[ " $have " == *" $p "* ]] || add+=("$p"); done
  if ! firewall-cmd --permanent --query-service=ssh >/dev/null 2>&1; then add+=(ssh); fi
  if [[ ${#add[@]} -eq 0 ]]; then
    _mark ok "firewall ports ${want[*]} + ssh open"
  else
    _mark changed "firewall: allow ${add[*]}"
    if ! _checking; then
      for p in "${add[@]}"; do
        if [[ $p == ssh ]]; then firewall-cmd -q --permanent --add-service=ssh; else firewall-cmd -q --permanent --add-port="$p"; fi
      done
      changed=1
    fi
  fi
  for p in $have; do
    [[ " ${want[*]} " == *" $p "* ]] || _mark warn "firewall: port $p open but not managed by cpctl"
  done
  # services opened by the OS default zone that a server does not need (FIREWALL_REMOVE_SERVICES)
  for p in ${FW_REMOVE_SERVICES:-}; do
    firewall-cmd --permanent --query-service="$p" >/dev/null 2>&1 || { _mark ok "firewall service $p closed"; continue; }
    _mark changed "firewall: remove service $p"
    _checking || { firewall-cmd -q --permanent --remove-service="$p"; changed=1; }
  done
  if [[ $changed == 1 ]]; then firewall-cmd -q --reload; fi
  return 0
}

# os_node::selinux <expected mode> <path...>   mode check + restorecon of our custom paths
os_node::selinux() {
  local mode=$1; shift
  local cur p todo
  if ! command -v getenforce >/dev/null || [[ $(getenforce 2>/dev/null) == Disabled ]]; then
    if node::in_container; then _mark skipped "SELinux not available in a container"; else _mark warn "SELinux is disabled (expected $mode)"; fi
    return 0
  fi
  cur=$(getenforce | tr '[:upper:]' '[:lower:]')
  [[ $cur == "$mode" ]] && _mark ok "SELinux $cur" || _mark warn "SELinux is $cur (expected $mode; change via /etc/selinux/config + reboot)"
  for p in "$@"; do
    [[ -e $p ]] || continue
    todo=$(restorecon -R -n -v "$p" 2>/dev/null | wc -l)
    if [[ $todo -eq 0 ]]; then _mark ok "SELinux contexts $p"; continue; fi
    _mark changed "restorecon $p ($todo labels)"
    _checking || restorecon -R "$p"
  done
}
