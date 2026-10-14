#!/usr/bin/env bash
# Idempotent: create cpadmin's SSH key once and publish the public key for all simulated hosts.
set -euo pipefail
home=/home/cpadmin
pub_dir=/etc/ssh/authorized_keys.d
install -d -o cpadmin -g cpadmin -m 0700 "$home/.ssh"
if [[ ! -f $home/.ssh/id_ed25519 ]]; then
  sudo -u cpadmin ssh-keygen -q -t ed25519 -N '' -C "cpadmin@ops01" -f "$home/.ssh/id_ed25519"
fi
if ! cmp -s "$home/.ssh/id_ed25519.pub" "$pub_dir/cpadmin" 2>/dev/null; then
  install -m 0644 "$home/.ssh/id_ed25519.pub" "$pub_dir/cpadmin"
fi
