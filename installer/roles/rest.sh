#!/usr/bin/env bash
# Role "rest": Confluent REST Proxy (mTLS for machines, RBAC through MDS impersonation).
[[ -n ${_ROLE_REST_LOADED:-} ]] && return 0
_ROLE_REST_LOADED=1

readonly REST_CONF=/etc/confluent/kafka-rest/kafka-rest.properties

role::rest::configure() {
  local host=$1 any=0
  role::common_vars
  export HOST_FQDN REST_ID
  HOST_FQDN=$(inv::fqdn "$host")
  REST_ID=$(inv::get "$host" REST_ID "$host")
  role::push_ssl "$host" ca.pem truststore.p12 cp-server.p12 mds-public.pem; [[ $REMOTE_CHANGED == 1 ]] && any=1
  remote::apply "$host" ensure::dir /etc/confluent/kafka-rest root confluent 0750
  role::push_properties "$host" kafka-rest.properties.tpl "$REST_CONF" kafka-rest
  [[ $REMOTE_CHANGED == 1 ]] && any=1
  role::jmx_exporter "$host" kafka-rest rules-rest.yml cp-server; [[ $REMOTE_CHANGED == 1 ]] && any=1
  export CONFIG_FILE=$REST_CONF HEAP JAVA_HOME COMPONENT=kafka-rest
  HEAP=$(inv::heap rest)
  JAVA_HOME=$(install::java_home)
  role::systemd_dropin "$host" confluent-kafka-rest rest-override.conf.tpl
  [[ $REMOTE_CHANGED == 1 ]] && any=1
  [[ $any == 1 ]] && handler::notify rest "$host"
  return 0
}

role::rest::start() { role::svc_start "$1" confluent-kafka-rest; }
role::rest::restart() { remote::apply "$1" svc::restart confluent-kafka-rest; }
role::rest::stop() { remote::apply "$1" svc::stop confluent-kafka-rest; }

# HTTP status of GET /v3/clusters with a client certificate (default: the shared server cert).
rest::http_code() { # <host> [cert name]
  local host=$1 cert=${2:-cp-server}
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$PKI_DIR/ca.pem" \
    --cert "$PKI_DIR/$cert.crt" --key "$PKI_DIR/$cert.key" "https://$(inv::fqdn "$host"):$PORT_REST/v3/clusters"
}

rest::_answers() { [[ $(rest::http_code "$1") =~ ^(200|401|403)$ ]]; }

role::rest::health() {
  local host=$1
  health::wait 180 "[$host] REST Proxy answers on $PORT_REST (mTLS)" rest::_answers "$host"
}

role::rest::running() { remote::run "$1" svc::is_active confluent-kafka-rest >/dev/null 2>&1; }
