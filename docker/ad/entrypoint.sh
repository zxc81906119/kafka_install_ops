#!/usr/bin/env bash
# Provision the Samba AD domain once, then keep samba running (restarted if killed, e.g. after a TLS cert swap).
set -euo pipefail

: "${AD_REALM:?}" "${AD_DOMAIN:?}" "${AD_ADMIN_PASSWORD:?}"

if [[ ! -f /var/lib/samba/private/sam.ldb ]]; then
  echo "[ad] provisioning domain ${AD_REALM}"
  rm -f /etc/samba/smb.conf
  samba-tool domain provision \
    --use-rfc2307 \
    --realm="${AD_REALM}" \
    --domain="${AD_DOMAIN}" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --adminpass="${AD_ADMIN_PASSWORD}" \
    --option="dns forwarder = 127.0.0.11" \
    --option="tls enabled = yes" \
    --option="tls keyfile = tls/key.pem" \
    --option="tls certfile = tls/cert.pem" \
    --option="tls cafile = tls/ca.pem"
fi
cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf

/usr/sbin/sshd

while true; do
  echo "[ad] starting samba"
  samba --foreground --no-process-group --debug-stdout || true
  echo "[ad] samba exited, restarting in 2s"
  sleep 2
done
