#!/usr/bin/env bash
# Role "c3": Control Center next-gen + its embedded Prometheus and Alertmanager (all from the C3 RPM).
# The C3 host must not carry any Confluent Platform package (class-loading conflicts).
[[ -n ${_ROLE_C3_LOADED:-} ]] && return 0
_ROLE_C3_LOADED=1

readonly C3_CONF=/etc/confluent/control-center/control-center.properties
readonly C3_PKG_ETC=/etc/confluent-control-center
readonly C3_UNITS=(prometheus alertmanager confluent-control-center)

role::c3::configure() {
  local host=$1 any_prom=0 any_c3=0
  role::common_vars
  export HOST_FQDN PROM_RETENTION
  HOST_FQDN=$(inv::fqdn "$host")
  local pr="PROM_RETENTION_$PROFILE"; PROM_RETENTION=${!pr}

  role::push_ssl "$host" ca.pem truststore.p12 cp-server.p12 cp-server.crt cp-server.key mds-public.pem
  [[ $REMOTE_CHANGED == 1 ]] && { any_prom=1; any_c3=1; }

  # Prometheus / Alertmanager: TLS + mandatory client certificates
  role::push_rendered "$host" web-config.yml.tpl "$C3_PKG_ETC/web-config-prom.yml" root confluent 0640
  [[ $REMOTE_CHANGED == 1 ]] && any_prom=1
  role::push_rendered "$host" web-config.yml.tpl "$C3_PKG_ETC/web-config-am.yml" root confluent 0640
  [[ $REMOTE_CHANGED == 1 ]] && any_prom=1
  role::push_rendered "$host" prometheus-generated.yml.tpl "$C3_PKG_ETC/prometheus-generated.yml" root confluent 0640
  [[ $REMOTE_CHANGED == 1 ]] && any_prom=1
  role::systemd_dropin "$host" prometheus prometheus-override.conf.tpl
  [[ $REMOTE_CHANGED == 1 ]] && any_prom=1

  # Control Center
  remote::apply "$host" ensure::dir /etc/confluent/control-center root confluent 0750
  role::push_properties "$host" control-center.properties.tpl "$C3_CONF" control-center
  [[ $REMOTE_CHANGED == 1 ]] && any_c3=1
  export CONFIG_FILE=$C3_CONF HEAP JAVA_HOME COMPONENT=control-center
  HEAP=$(inv::heap c3)
  JAVA_HOME=$(install::java_home)
  role::systemd_dropin "$host" confluent-control-center c3-override.conf.tpl
  [[ $REMOTE_CHANGED == 1 ]] && any_c3=1
  remote::apply "$host" ensure::dir /var/lib/confluent/control-center cp-control-center confluent 0750

  [[ $any_c3 == 1 || $any_prom == 1 ]] && handler::notify c3 "$host"
  return 0
}

role::c3::start() {
  local u
  for u in "${C3_UNITS[@]}"; do role::svc_start "$1" "$u"; done
}
role::c3::restart() {
  local u
  for u in "${C3_UNITS[@]}"; do remote::apply "$1" svc::restart "$u"; done
}
role::c3::stop() {
  local i
  for ((i = ${#C3_UNITS[@]} - 1; i >= 0; i--)); do remote::apply "$1" svc::stop "${C3_UNITS[$i]}"; done
}
role::c3::running() { remote::run "$1" svc::is_active confluent-control-center >/dev/null 2>&1; }

c3::_prom_ready() {
  [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$PKI_DIR/ca.pem" \
    --cert "$PKI_DIR/cp-server.crt" --key "$PKI_DIR/cp-server.key" \
    "https://$(inv::fqdn "$1"):$PORT_PROMETHEUS/-/ready") == 200 ]]
}
c3::_ui_up() {
  [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$PKI_DIR/ca.pem" \
    "https://$(inv::fqdn "$1"):$PORT_C3/") == 200 ]]
}

role::c3::health() {
  health::wait 120 "[$1] Prometheus ready (mTLS)" c3::_prom_ready "$1" &&
    health::wait 420 "[$1] Control Center UI on $PORT_C3" c3::_ui_up "$1"
}
