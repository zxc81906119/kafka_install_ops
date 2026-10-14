#!/usr/bin/env bash
# End-to-end checks used by step 10 and `cpctl verify`. Each check logs ok/error and never mutates config.
[[ -n ${_LIB_VERIFY_LOADED:-} ]] && return 0
_LIB_VERIFY_LOADED=1

VERIFY_FAILED=0
verify::pass() { log::ok "VERIFY $*"; }
verify::fail() { log::error "VERIFY $*"; VERIFY_FAILED=1; }
verify::check() { # <description> <command...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then verify::pass "$d"; else verify::fail "$d"; fi
}
verify::check_not() { # expect failure
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then verify::fail "$d"; else verify::pass "$d"; fi
}

verify::_client_dir() { local d=$STATE_DIR/client; mkdir -p "$d"; printf '%s' "$d"; }

# Client config files for the tests (machines and humans)
verify::scram_config() { # <app>
  local f
  f=$(verify::_client_dir)/$1-scram.properties
  cat >"$f" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$1" password="$(inv::secret "$(inv::app_secret_var "$1")")";
ssl.truststore.type=PKCS12
ssl.truststore.location=$PKI_DIR/truststore.p12
ssl.truststore.password=$STORE_PASSWORD
EOF
  chmod 0600 "$f"; printf '%s' "$f"
}

verify::ldap_config() { # <user> <password>
  local f
  f=$(verify::_client_dir)/$1-ldap.properties
  cat >"$f" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$1" password="$2";
ssl.truststore.type=PKCS12
ssl.truststore.location=$PKI_DIR/truststore.p12
ssl.truststore.password=$STORE_PASSWORD
EOF
  chmod 0600 "$f"; printf '%s' "$f"
}

verify::nocert_config() {
  local f
  f=$(verify::_client_dir)/nocert.properties
  printf 'security.protocol=SSL\nssl.truststore.type=PKCS12\nssl.truststore.location=%s\nssl.truststore.password=%s\n' \
    "$PKI_DIR/truststore.p12" "$STORE_PASSWORD" >"$f"
  printf '%s' "$f"
}

verify::produce() { # <bootstrap> <config> <topic> <message>
  local out
  out=$(printf '%s\n' "$4" | timeout 60 env KAFKA_HEAP_OPTS=-Xmx256m \
    KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
    /usr/bin/kafka-console-producer --bootstrap-server "$1" --producer.config "$2" --topic "$3" \
    --producer-property acks=all --producer-property max.block.ms=20000 --producer-property delivery.timeout.ms=30000 \
    --producer-property request.timeout.ms=15000 2>&1) || return 1
  ! grep -q -i -E 'authoriz|exception|error' <<<"$out"
}

verify::consume_contains() { # <bootstrap> <config> <topic> <group> <message>
  timeout 90 env KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
    /usr/bin/kafka-console-consumer --bootstrap-server "$1" --consumer.config "$2" --topic "$3" --group "$4" \
    --from-beginning --timeout-ms 45000 2>/dev/null | grep -qF "$5"
}

# REST v3 produce answers HTTP 200 and reports each record's outcome in the body ("error_code": 200 | 403xx ...)
verify::rest_produce_code() { # <url> <cert>
  curl -s --max-time 20 --cacert "$PKI_DIR/ca.pem" --cert "$PKI_DIR/$2.crt" --key "$PKI_DIR/$2.key" -X POST \
    -H "Content-Type: application/json" -d '{"value":{"type":"JSON","data":{"source":"cpctl-verify"}}}' "$1" |
    grep -o '"error_code":[0-9]*' | head -1 | cut -d: -f2
}

verify::has_scram() { # <user>
  kafka::admin kafka-configs --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$(kafka::admin_config)" \
    --describe --entity-type users --entity-name "$1" 2>/dev/null | grep -q SCRAM-SHA-512
}

verify::_locked() { remote::exec "$1" "sudo -n dnf versionlock list 2>/dev/null | grep -q confluent-server"; }

verify::rest_code() { # <url> <cert name|-> [curl args...]
  local url=$1 cert=$2; shift 2
  local certargs=()
  [[ $cert != - ]] && certargs=(--cert "$PKI_DIR/$cert.crt" --key "$PKI_DIR/$cert.key")
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 --cacert "$PKI_DIR/ca.pem" "${certargs[@]}" "$@" "$url" || true
}

verify::run_all() {
  role::common_vars
  local cfg cid boot_client boot_ldap first_broker msg
  cfg=$(kafka::admin_config)
  core::load_env "$STATE_DIR/kraft.env"
  cid=$CLUSTER_ID
  boot_client=$(inv::endpoints broker "$PORT_CLIENT")
  boot_ldap=$(inv::endpoints broker "$PORT_LDAP")
  first_broker=$(inv::fqdn "$(inv::hosts broker | head -1)")
  msg="cpctl-verify-$CPCTL_RUN_ID"

  log::step "---- KRaft dynamic quorum"
  local q
  q=$(kafka::admin kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$cfg" describe --status 2>&1 || true)
  grep -q 'LeaderId:' <<<"$q" && verify::pass "quorum has a leader ($(grep -o 'LeaderId:[^ ]*' <<<"$q" | head -1))" || verify::fail "quorum has no leader"
  local voters
  voters=$(grep -o '"directoryId"' <<<"$(grep 'CurrentVoters' <<<"$q")" | wc -l)
  [[ $voters -eq $(inv::hosts controller | wc -l) ]] && verify::pass "$voters voters, each with a directory id (dynamic quorum)" ||
    verify::fail "expected $(inv::hosts controller | wc -l) voters with directory ids, got $voters"
  kafka::admin kafka-features --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$cfg" describe 2>/dev/null |
    grep -E 'Feature: kraft.version.*FinalizedVersionLevel: 1' -q && verify::pass "kraft.version finalized at 1" || verify::fail "kraft.version is not 1"
  local mv
  mv=$(kafka::admin kafka-features --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" describe 2>/dev/null |
    awk '/Feature: confluent.metadata.version/ {for (i=1;i<=NF;i++) if ($i=="FinalizedVersionLevel:") print $(i+1)}')
  log::info "metadata.version finalized level: ${mv:-?}"

  log::step "---- Brokers"
  local reg
  reg=$(kafka::admin kafka-broker-api-versions --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" 2>/dev/null | grep -c '(id:' || true)
  [[ $reg -eq $(inv::hosts broker | wc -l) ]] && verify::pass "$reg brokers registered" || verify::fail "only $reg brokers registered"
  local racks
  racks=$(kafka::admin kafka-broker-api-versions --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" 2>/dev/null | grep -o 'rack: [^)]*' | sort -u | paste -sd' ' -)
  [[ $racks == *rack-a* && $racks == *rack-b* ]] && verify::pass "rack awareness: $racks" || verify::fail "racks: $racks"

  log::step "---- Internal mTLS (shared internal certificate)"
  verify::check_not "controller rejects a client without certificate" timeout 40 env KAFKA_HEAP_OPTS=-Xmx128m \
    KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml /usr/bin/kafka-metadata-quorum \
    --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$(verify::nocert_config)" describe --status
  verify::check "controller accepts the shared internal certificate (super user)" kafka::admin kafka-metadata-quorum \
    --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$cfg" describe --status

  log::step "---- Applications over SCRAM (CLIENT listener) + RBAC"
  verify::check "app-orders produces to orders.events (RBAC DeveloperWrite)" verify::produce "$boot_client" "$(verify::scram_config app-orders)" orders.events "$msg"
  verify::check "app-orders consumes it back (DeveloperRead topic + group)" verify::consume_contains "$boot_client" "$(verify::scram_config app-orders)" orders.events orders-verify "$msg"
  verify::check_not "app-orders is denied on payments.events (no binding)" verify::produce "$boot_client" "$(verify::scram_config app-orders)" payments.events "$msg"
  verify::check_not "wrong SCRAM password is rejected" verify::produce "$boot_client" "$(verify::ldap_config app-orders x)" orders.events "$msg"

  log::step "---- Humans over LDAP (AD) + group RBAC"
  local pw
  pw=$(inv::secret HUMAN_DEFAULT_PASSWORD)
  verify::check "alice (kafka-admins -> SystemAdmin) can produce to payments.events" verify::produce "$boot_ldap" "$(verify::ldap_config alice "$pw")" payments.events "$msg-alice"
  verify::check_not "carol (kafka-devs, read-only) cannot produce to orders.events" verify::produce "$boot_ldap" "$(verify::ldap_config carol "$pw")" orders.events "$msg-carol"
  verify::check "MDS issues a token to alice (LDAP basic auth)" test "$(curl -s -o /dev/null -w '%{http_code}' --cacert "$PKI_DIR/ca.pem" -u "alice:$pw" "https://$first_broker:$PORT_MDS/security/1.0/authenticate")" = 200
  verify::check "MDS rejects a wrong password" test "$(curl -s -o /dev/null -w '%{http_code}' --cacert "$PKI_DIR/ca.pem" -u "alice:wrong" "https://$first_broker:$PORT_MDS/security/1.0/authenticate")" = 401

  log::step "---- REST Proxy through the load balancer (legacy apps only: mTLS + RBAC)"
  local base="https://$LB_REST_NAME:$PORT_REST/v3/clusters" legacy
  legacy=$(inv::apps rest | head -1)
  verify::check "$legacy (legacy app) certificate: GET /v3/clusters via LB = 200" test "$(verify::rest_code "$base" "$legacy")" = 200
  verify::check_not "no client certificate is rejected at TLS level" test "$(verify::rest_code "$base" -)" = 200
  verify::check "$legacy produces via REST v3 to billing.events (record error_code 200)" test "$(verify::rest_produce_code "$base/$cid/topics/billing.events/records" "$legacy")" = 200
  verify::check "$legacy via REST v3 to orders.events is denied (record error_code 40301)" test "$(verify::rest_produce_code "$base/$cid/topics/orders.events/records" "$legacy")" = 40301
  # certificates that are not on the legacy list must not get through REST (servers, super users, humans)
  local other
  # also the SCRAM apps' certificates if any were issued before the legacy-only policy
  for other in cp-server kafka-internal $(for a in $(inv::apps scram); do [[ -f $PKI_DIR/$a.crt ]] && printf "%s " "$a"; done); do
    verify::check_not "$other certificate cannot use REST Proxy (not a legacy app)" test "$(verify::rest_code "$base/$cid/topics" "$other")" = 200
  done
  verify::check_not "$legacy has no SCRAM credential (REST-only identity)" verify::has_scram "$legacy"

  log::step "---- Control Center and monitoring"
  local c3
  c3=$(inv::fqdn "$(inv::hosts c3 | head -1)")
  verify::check "C3 UI via LB https://$LB_C3_NAME:$PORT_C3 = 200" test "$(verify::rest_code "https://$LB_C3_NAME:$PORT_C3/" -)" = 200
  verify::check_not "Prometheus rejects clients without a certificate" test "$(verify::rest_code "https://$c3:$PORT_PROMETHEUS/-/ready" -)" = 200
  local series
  series=$(curl -s --max-time 20 --cacert "$PKI_DIR/ca.pem" --cert "$PKI_DIR/cp-server.crt" --key "$PKI_DIR/cp-server.key" \
    "https://$c3:$PORT_PROMETHEUS/api/v1/label/__name__/values" | grep -o 'io_confluent_kafka_server[a-z_]*' | sort -u | wc -l || true)
  [[ ${series:-0} -gt 0 ]] && verify::pass "Prometheus receives broker/controller metrics ($series metric names)" ||
    verify::fail "no io_confluent_kafka_server metrics in Prometheus yet (first scrape can take ~2 min)"

  log::step "---- Audit, packages, offline"
  verify::check "audit log topic confluent-audit-log-events exists" kafka::admin kafka-topics --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" --describe --topic confluent-audit-log-events
  local h
  for h in $(inv::hosts broker | head -1) $(inv::hosts rest | head -1) $(inv::hosts c3) $(inv::hosts ops); do
    verify::check_not "[$h] has no Internet access (offline)" remote::exec "$h" "curl -s -m 5 -o /dev/null https://packages.confluent.io"
  done
  verify::check "[$(inv::hosts broker | head -1)] confluent-server is versionlocked" verify::_locked "$(inv::hosts broker | head -1)"
  for h in $(inv::hosts c3); do
    verify::check_not "[$h] has no Confluent Platform packages (C3 host must stay clean)" remote::exec "$h" "rpm -q confluent-server confluent-common >/dev/null 2>&1"
  done

  if [[ ! -s $CONF_DIR/license.txt ]]; then
    log::warn "no license configured (conf/license.txt) - running in evaluation mode"
  fi
  return "$VERIFY_FAILED"
}
