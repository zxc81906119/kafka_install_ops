# Simulated "bare" RHEL 9 host: systemd + sshd + sudo + base OS tools only.
# No JDK / Confluent here - those are delivered offline by the ops host.
FROM rockylinux/rockylinux:9.8

RUN dnf -y install \
        systemd openssh-server openssh-clients sudo \
        tar gzip openssl procps-ng nmap-ncat hostname iproute less which findutils \
        python3-dnf-plugin-versionlock dnf-plugins-core ca-certificates \
    && dnf clean all \
    && rm -f /etc/yum.repos.d/*.repo.rpmnew

# Installer account (SSH only, key based). Service accounts are created by the RPMs.
RUN useradd -m -s /bin/bash cpadmin \
    && install -d -m 0755 /etc/ssh/authorized_keys.d

COPY sshd-cp.conf /etc/ssh/sshd_config.d/10-cp.conf
# PoC only: full sudo for cpadmin. See installer/conf/sudoers.d/cpadmin.restricted for the bank baseline.
COPY sudoers-cpadmin /etc/sudoers.d/cpadmin
RUN chmod 0440 /etc/sudoers.d/cpadmin \
    && systemctl enable sshd \
    && systemctl mask systemd-logind.service getty.target console-getty.service systemd-udevd.service \
    && sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/*.repo
# Public repos are disabled: at runtime the host only sees the internal repo (offline).

STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
