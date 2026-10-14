# Node-side helpers for the simulated Active Directory (Samba AD DC). PoC mode only.

ad::_exists() { # <ldb filter>
  ldbsearch -H /var/lib/samba/private/sam.ldb "$1" dn 2>/dev/null | grep -q '^dn:'
}

# ad::ensure_ou <ou dn>
ad::ensure_ou() {
  local dn=$1 rdn=${1%%,DC=*}
  if ldbsearch -H /var/lib/samba/private/sam.ldb -b "$dn" -s base dn 2>/dev/null | grep -q '^dn:'; then
    _mark ok "AD OU $dn"
    return 0
  fi
  _mark changed "AD OU $dn"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || samba-tool ou create "$rdn" >/dev/null
}

# ad::ensure_group <name> <ou rdn (e.g. OU=Groups,OU=Confluent)>
ad::ensure_group() {
  if ad::_exists "(&(objectClass=group)(sAMAccountName=$1))"; then _mark ok "AD group $1"; return 0; fi
  _mark changed "AD group $1"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || samba-tool group add "$1" --groupou="$2" >/dev/null
}

# ad::ensure_user <name> <password> <ou rdn>   (password is set only at creation)
ad::ensure_user() {
  if ad::_exists "(&(objectClass=user)(sAMAccountName=$1))"; then _mark ok "AD user $1"; return 0; fi
  _mark changed "AD user $1"
  [[ ${CPCTL_CHECK:-0} == 1 ]] && return 0
  samba-tool user create "$1" "$2" --userou="$3" >/dev/null
  samba-tool user setexpiry "$1" --noexpiry >/dev/null
}

# ad::ensure_member <group> <user>
ad::ensure_member() {
  if samba-tool group listmembers "$1" 2>/dev/null | grep -qx "$2"; then _mark ok "AD $2 in $1"; return 0; fi
  _mark changed "AD add $2 to $1"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || samba-tool group addmembers "$1" "$2" >/dev/null
}

