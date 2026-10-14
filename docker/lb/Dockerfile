# Simulated existing L4 load balancer appliance (open-source Nginx, stream module).
# Nginx itself is not installed by cpctl; cpctl only renders and applies /etc/nginx/stream.d/*.conf over SSH.
FROM nginx:1.28

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server sudo procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash cpadmin \
    && install -d -m 0755 /etc/ssh/authorized_keys.d /run/sshd /etc/nginx/stream.d \
    && echo 'cpadmin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/cpadmin && chmod 0440 /etc/sudoers.d/cpadmin \
    && printf '\nstream {\n    include /etc/nginx/stream.d/*.conf;\n}\n' >> /etc/nginx/nginx.conf \
    && rm -f /etc/nginx/conf.d/default.conf
COPY sshd-cp.conf /etc/ssh/sshd_config.d/10-cp.conf
COPY entrypoint.sh /usr/local/sbin/lb-entrypoint
RUN chmod 0755 /usr/local/sbin/lb-entrypoint

ENTRYPOINT ["/usr/local/sbin/lb-entrypoint"]
