# Simulated BANK web server for the internal repository (repo01). It stands for a server the bank already
# runs and manages itself: cpctl has NO root and installs nothing here. What the bank gives the PoC team:
#   - a deploy account (repodeploy) that may write the document root over SSH, nothing else
#   - an HTTPS site that serves that document root read-only, with a certificate from the bank CA
# Deliberately NOT present: createrepo_c, rsync, sudo for cpadmin - the repo is built on the ops host and
# pushed with plain ssh + tar (see installer/lib/repo/local.sh, repo::push).
FROM cp-node:poc

RUN dnf -y --enablerepo=baseos,appstream install httpd mod_ssl \
    && dnf clean all \
    && sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/*.repo \
    && rm -f /etc/sudoers.d/cpadmin \
    && useradd -m -s /bin/bash repodeploy \
    && install -d -o repodeploy -g repodeploy -m 0755 /var/www/repo \
    && rm -f /etc/httpd/conf.d/welcome.conf /etc/httpd/conf.d/ssl.conf \
    && sed -i 's/^Listen 80$/# Listen 80 (HTTPS only, see repo.conf)/' /etc/httpd/conf/httpd.conf \
    && systemctl enable httpd

COPY sshd-repo.conf /etc/ssh/sshd_config.d/20-repo.conf
COPY repo.conf /etc/httpd/conf.d/repo.conf
