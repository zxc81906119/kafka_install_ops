# Managed by cpctl. L4 passthrough only: TLS (and client certificates) terminate on REST Proxy / C3.
upstream cp_rest {
    # v2 consumer instances are stateful -> the same client must keep hitting the same REST Proxy
    hash $remote_addr consistent;
${REST_UPSTREAMS}
}

server {
    listen ${PORT_REST};
    proxy_pass cp_rest;
    proxy_connect_timeout 3s;
    proxy_timeout 10m;
}
${C3_LB_BLOCK}
