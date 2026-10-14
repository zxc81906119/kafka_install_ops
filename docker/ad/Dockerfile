# Simulated Active Directory (Samba AD DC). RHEL/Rocky samba builds ship without AD DC support,
# so this one helper image is Debian based. It is environment scaffolding, not part of the install.
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        samba samba-ad-dc samba-ad-provision winbind krb5-user ldb-tools ldap-utils openssh-server sudo procps ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/samba/smb.conf

RUN useradd -m -s /bin/bash cpadmin \
    && install -d -m 0755 /etc/ssh/authorized_keys.d /run/sshd \
    && echo 'cpadmin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/cpadmin && chmod 0440 /etc/sudoers.d/cpadmin
COPY sshd-cp.conf /etc/ssh/sshd_config.d/10-cp.conf
COPY entrypoint.sh /usr/local/sbin/ad-entrypoint
RUN chmod 0755 /usr/local/sbin/ad-entrypoint

VOLUME ["/var/lib/samba", "/etc/samba"]
ENTRYPOINT ["/usr/local/sbin/ad-entrypoint"]
