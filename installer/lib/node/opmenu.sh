# Node-side helpers for the OP menu (bastion + node access account). Run as root. Check-then-act, CPCTL_CHECK aware.

# opmenu_node::jump_accounts <fixed os user> <bootstrap user>
#   opmenu group; fixed operator account whose login shell is the menu; system account holding the break-glass identity
opmenu_node::jump_accounts() {
  local u=$1 b=$2
  if getent group opmenu >/dev/null; then _mark ok "group opmenu"; else
    _mark changed "group opmenu"; _checking || groupadd opmenu; fi
  if id "$u" >/dev/null 2>&1; then
    if [[ $(getent passwd "$u" | cut -d: -f7) == /opt/opmenu/opmenu.sh && " $(id -nG "$u") " == *" opmenu "* ]]; then
      _mark ok "user $u (login shell = OP menu)"
    else
      _mark changed "user $u: login shell OP menu, group opmenu"; _checking || usermod -s /opt/opmenu/opmenu.sh -aG opmenu "$u"
    fi
  else
    _mark changed "user $u (fixed bastion account, login shell = OP menu)"
    _checking || useradd -m -G opmenu -s /opt/opmenu/opmenu.sh "$u"
  fi
  if id "$b" >/dev/null 2>&1; then _mark ok "user $b"; else
    _mark changed "user $b (holds the break-glass identity, nologin)"
    _checking || useradd -r -m -d /etc/opmenu/bootstrap -s /sbin/nologin "$b"
  fi
}

# opmenu_node::install_pkg <tar.gz on this node> <version>   -> /opt/opmenu-<version>, /opt/opmenu -> it
opmenu_node::install_pkg() {
  local pkg=$1 ver=$2 dir=/opt/opmenu-$2 t
  ensure::_guard "$dir"
  if [[ -x $dir/opmenu.sh ]]; then _mark ok "OP menu $ver installed"; else
    _mark changed "install OP menu $ver"
    if ! _checking; then
      t=$(mktemp -d)
      tar -xzf "$pkg" -C "$t"
      [[ -x $t/opmenu/opmenu.sh ]] || { _mark warn "package has no opmenu/opmenu.sh"; rm -rf "$t"; return 1; }
      chown -R root:root "$t/opmenu"; chmod -R go-w "$t/opmenu"
      mv "$t/opmenu" "$dir"; rm -rf "$t"
    fi
  fi
  ensure::symlink "$dir" /opt/opmenu
}

# opmenu_node::user_key <user>   ed25519 key pair for ssh to the nodes (private key never leaves this host)
opmenu_node::user_key() {
  local u=$1 h
  h=$(getent passwd "$u" | cut -d: -f6)
  if [[ -s $h/.ssh/id_ed25519 ]]; then _mark ok "ssh key of $u"; return 0; fi
  _mark changed "ssh key of $u (ed25519)"
  _checking && return 0
  install -d -o "$u" -g "$u" -m 0700 "$h/.ssh"
  sudo -u "$u" ssh-keygen -q -t ed25519 -N '' -C "$u@$(hostname -s)" -f "$h/.ssh/id_ed25519"
}

# opmenu_node::sshd_block <file with the block>   managed block at the END of sshd_config (Match must come last;
# a Match inside an early Include would swallow the rest of the main config), validated with sshd -t before reload
opmenu_node::sshd_block() {
  local blk=$1 cfg=/etc/ssh/sshd_config t
  local begin='# BEGIN cpctl opmenu' end='# END cpctl opmenu'
  t=$(mktemp /tmp/cpnode.XXXXXX)
  sed "/^$begin\$/,/^$end\$/d" "$cfg" >"$t"
  { printf '%s\n' "$begin"; cat "$blk"; printf '%s\n' "$end"; } >>"$t"
  if [[ $(sha256sum <"$t") == $(sha256sum <"$cfg") ]]; then _mark ok "sshd: OP menu block"; rm -f "$t"; return 0; fi
  _mark changed "sshd: OP menu block (ForceCommand, no forwarding)"
  if _checking; then rm -f "$t"; return 0; fi
  sshd -t -f "$t" || { _mark warn "sshd -t rejected the new config - not applied"; rm -f "$t"; return 1; }
  cp -p "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
  cat "$t" >"$cfg"; rm -f "$t"
  systemctl reload sshd
}

# opmenu_node::known_hosts <host...>   pinned host keys of the nodes in the global known_hosts (root-owned)
opmenu_node::known_hosts() {
  local t f=/etc/ssh/ssh_known_hosts
  t=$(mktemp /tmp/cpnode.XXXXXX)
  { printf '# Managed by cpctl - node host keys for the OP menu\n'; ssh-keyscan -T 5 -t ed25519 "$@" 2>/dev/null | sort; } >"$t"
  [[ $(grep -vc '^#' "$t") -eq $# ]] || { _mark warn "ssh-keyscan returned $(grep -vc '^#' "$t") of $# host keys"; rm -f "$t"; return 1; }
  ensure::file "$t" "$f" root root 0644
}

# opmenu_node::node_account <user> <authorized_keys line>
#   fixed node account used by the menu over ssh; key file root-owned so the account cannot add its own keys
opmenu_node::node_account() {
  local u=$1 key=$2 h t
  if id "$u" >/dev/null 2>&1; then _mark ok "user $u"; else
    _mark changed "user $u (fixed node account for the OP menu)"
    _checking && return 0
    useradd -m -s /bin/bash "$u"; passwd -l "$u" >/dev/null
  fi
  h=$(getent passwd "$u" | cut -d: -f6)
  ensure::dir "$h/.ssh" root "$u" 0750
  t=$(mktemp /tmp/cpnode.XXXXXX); printf '%s\n' "$key" >"$t"
  ensure::file "$t" "$h/.ssh/authorized_keys" root "$u" 0640
}
