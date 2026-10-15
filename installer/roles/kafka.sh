#!/usr/bin/env bash
# Roles "controller" and "broker" (Confluent Server). Same package and unit, different config.
[[ -n ${_ROLE_KAFKA_LOADED:-} ]] && return 0
_ROLE_KAFKA_LOADED=1

readonly KAFKA_CONF=/etc/confluent/kafka/server.properties

kafka::_configure() { # <role> <host>
  local role=$1 host=$2 any=0
  role::common_vars
  export HOST_FQDN NODE_ID RACK COMMON_BLOCK LDAP_BLOCK TELEMETRY_BLOCK AUDIT_BLOCK
  HOST_FQDN=$(inv::fqdn "$host")
  NODE_ID=$(inv::get "$host" NODE_ID)
  [[ -n $NODE_ID ]] || core::die "inventory: HOST_${host}_NODE_ID missing"
  RACK=$(inv::get "$host" RACK rack-default)
  COMMON_BLOCK=$(role::render_block common-server.properties.tpl)
  LDAP_BLOCK=$(role::render_block ldap.properties.tpl)
  TELEMETRY_BLOCK=$(role::render_block telemetry.properties.tpl)
  AUDIT_BLOCK=$(role::render_block audit.properties.tpl)

  local ssl=(ca.pem truststore.p12 kafka-internal.p12 mds-token-keypair.enc.pem mds-public.pem)
  [[ $role == broker ]] && ssl+=(cp-server.p12)
  role::push_ssl "$host" "${ssl[@]}"; [[ $REMOTE_CHANGED == 1 ]] && any=1
  # the unencrypted token key from earlier versions must not stay on the node
  remote::apply "$host" ensure::absent /etc/confluent/ssl/mds-token-keypair.pem

  remote::apply "$host" ensure::dir /etc/confluent/kafka root confluent 0750
  role::push_properties "$host" "$role.properties.tpl" "$KAFKA_CONF" kafka
  [[ $REMOTE_CHANGED == 1 ]] && any=1

  # controllers have no cp-server.p12: their exporter serves the internal certificate (SANs cover kc*)
  role::jmx_exporter "$host" kafka rules-kafka.yml "$([[ $role == broker ]] && echo cp-server || echo kafka-internal)"
  [[ $REMOTE_CHANGED == 1 ]] && any=1

  export CONFIG_FILE=$KAFKA_CONF HEAP JAVA_HOME COMPONENT=kafka
  HEAP=$(inv::heap "$role")
  JAVA_HOME=$(install::java_home)
  role::systemd_dropin "$host" "$(install::unit "$role")" kafka-override.conf.tpl
  [[ $REMOTE_CHANGED == 1 ]] && any=1

  remote::apply "$host" ensure::dir /var/lib/kafka/data cp-kafka confluent 0750
  [[ $any == 1 ]] && handler::notify "$role" "$host"
  return 0
}

kafka::_running() { remote::run "$1" svc::is_active confluent-server >/dev/null 2>&1; }

# Admin client config on the ops host: super-user via the shared internal certificate.
kafka::admin_config() {
  local f=$STATE_DIR/client/internal.properties
  if [[ ! -f $f ]]; then
    mkdir -p "$STATE_DIR/client"
    cat >"$f" <<EOF
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=$PKI_DIR/kafka-internal.p12
ssl.keystore.password=$STORE_PASSWORD
ssl.key.password=$STORE_PASSWORD
ssl.truststore.type=PKCS12
ssl.truststore.location=$PKI_DIR/truststore.p12
ssl.truststore.password=$STORE_PASSWORD
ssl.endpoint.identification.algorithm=https
EOF
    chmod 0600 "$f"
  fi
  printf '%s' "$f"
}

kafka::bootstrap_internal() { inv::endpoints broker "$PORT_INTERNAL"; }

# kafka::admin <tool> [args...]  run a Kafka CLI tool on the ops host as the internal super-user
kafka::admin() {
  local tool=$1; shift
  KAFKA_HEAP_OPTS="-Xmx256m" KAFKA_OPTS="$(install::tools_opts)" JAVA_HOME="$(install::java_home)" \
    "$(install::bin "$tool")" "$@"
}

role::controller::configure() { kafka::_configure controller "$1"; }
role::broker::configure() { kafka::_configure broker "$1"; }

role::controller::start() { role::svc_start "$1" confluent-server; }
role::broker::start() { role::svc_start "$1" confluent-server; }
role::controller::restart() { remote::apply "$1" svc::restart confluent-server; }
role::broker::restart() { remote::apply "$1" svc::restart confluent-server; }
role::controller::stop() { remote::apply "$1" svc::stop confluent-server; }
role::broker::stop() { remote::apply "$1" svc::stop confluent-server; }

role::controller::health() {
  local host=$1
  health::wait 180 "[$host] controller port $PORT_CONTROLLER open" health::tcp "$host" "$PORT_CONTROLLER" || return 1
  health::wait 240 "[$host] quorum lag 0" kafka::_controller_caught_up "$host"
}

kafka::_controller_caught_up() {
  local id
  id=$(inv::get "$1" NODE_ID)
  kafka::admin kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_BOOTSTRAP" \
    --command-config "$(kafka::admin_config)" describe --replication 2>/dev/null |
    awk -v id="$id" '$1 == id && ($NF == "Leader" || $NF == "Follower") && $4 + 0 == 0 { ok = 1 } END { exit ok ? 0 : 1 }'
}

role::broker::health() {
  local host=$1
  health::wait 240 "[$host] broker port $PORT_INTERNAL open" health::tcp "$host" "$PORT_INTERNAL" || return 1
  health::wait 240 "[$host] MDS port $PORT_MDS open" health::tcp "$host" "$PORT_MDS" || return 1
  health::wait 300 "[$host] broker registered and no under-replicated partitions" kafka::_broker_healthy "$host"
}

kafka::_broker_healthy() {
  local host=$1 id cfg out
  id=$(inv::get "$host" NODE_ID)
  cfg=$(kafka::admin_config)
  out=$(kafka::admin kafka-broker-api-versions --bootstrap-server "$(kafka::bootstrap_internal)" \
    --command-config "$cfg" 2>/dev/null || true)
  grep -qF "(id: $id rack" <<<"$out" || return 1
  out=$(kafka::admin kafka-topics --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" \
    --describe --under-replicated-partitions 2>/dev/null) || return 1
  [[ -z $out ]]
}

role::controller::running() { kafka::_running "$1"; }
role::broker::running() { kafka::_running "$1"; }
