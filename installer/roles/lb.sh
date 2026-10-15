#!/usr/bin/env bash
# Role "lb": existing Nginx appliance. cpctl only owns /etc/nginx/stream.d/cp.conf.
[[ -n ${_ROLE_LB_LOADED:-} ]] && return 0
_ROLE_LB_LOADED=1

readonly LB_CONF=/etc/nginx/stream.d/cp.conf

# lb::upstream_lines [down_host...]  -> server lines; hosts listed are marked "down" (drain)
lb::upstream_lines() {
  local h line
  for h in $(inv::hosts rest); do
    line="    server $(inv::fqdn "$h"):$PORT_REST max_fails=2 fail_timeout=10s"
    if [[ " $* " == *" $h "* ]]; then line+=" down"; fi
    printf '%s;\n' "$line"
  done
}

# lb::apply_config [down_host...]
lb::apply_config() {
  local lb
  role::common_vars
  export REST_UPSTREAMS
  REST_UPSTREAMS=$(lb::upstream_lines "$@")
  for lb in $(inv::hosts lb); do
    role::push_rendered "$lb" nginx-stream.conf.tpl "$LB_CONF" root root 0644
    if [[ $REMOTE_CHANGED == 1 ]] && step::mutating; then
      remote::exec "$lb" "sudo -n nginx -t -q && sudo -n nginx -s reload" ||
        core::die "[$lb] nginx -t rejected the new configuration"
      log::changed "[$lb] nginx reloaded"
    fi
  done
}

role::lb::configure() { lb::apply_config; }
role::lb::start() { :; }
role::lb::restart() { remote::exec "$1" "sudo -n nginx -s reload"; }
role::lb::stop() { :; }
role::lb::health() {
  health::wait 60 "[$1] LB listening on $PORT_REST" health::tcp "$1" "$PORT_REST" &&
    health::wait 60 "[$1] LB listening on $PORT_C3" health::tcp "$1" "$PORT_C3"
}

# Drain / undrain one REST Proxy (used by rolling upgrades). OSS Nginx has no runtime API.
lb::drain() { log::info "draining $1 from the load balancer"; lb::apply_config "$1"; sleep 5; }
lb::undrain() { log::info "returning all REST Proxies to the load balancer"; lb::apply_config; }
