# Ops (operator) host: same base as nodes + tooling + the internal repo server (httpd + createrepo_c).
FROM cp-node:poc

ARG SHFMT_VERSION=3.10.0
ARG BATS_VERSION=1.11.1

RUN dnf -y --enablerepo=baseos,appstream,extras install epel-release \
    && dnf -y --enablerepo=baseos,appstream,epel install \
        rsync jq gettext util-linux openldap-clients httpd createrepo_c ShellCheck git-core \
    && dnf clean all \
    && sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/*.repo \
    && curl -fsSL -o /usr/local/bin/shfmt \
        "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" \
    && chmod 0755 /usr/local/bin/shfmt \
    && curl -fsSL "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz" | tar -xz -C /opt \
    && /opt/bats-core-${BATS_VERSION}/install.sh /usr/local

# Internal repo: /srv/repo served read-only on :8080
COPY repo-httpd.conf /etc/httpd/conf.d/cp-repo.conf
RUN sed -i 's/^Listen 80$/Listen 8080/' /etc/httpd/conf/httpd.conf \
    && rm -f /etc/httpd/conf.d/welcome.conf \
    && useradd -r -s /sbin/nologin repoadmin \
    && install -d -o repoadmin -g repoadmin -m 0755 /srv/repo \
    && install -d -o cpadmin -g cpadmin -m 0750 /var/lib/cp-installer \
    && systemctl enable httpd

# First boot: create cpadmin's key pair and publish the public key to the shared authorized_keys.d volume.
COPY cpadmin-keygen.sh /usr/local/sbin/cpadmin-keygen
COPY cpadmin-keygen.service /etc/systemd/system/cpadmin-keygen.service
RUN chmod 0755 /usr/local/sbin/cpadmin-keygen && systemctl enable cpadmin-keygen.service \
    && ln -s /opt/cp-installer/bin/cpctl /usr/local/bin/cpctl
