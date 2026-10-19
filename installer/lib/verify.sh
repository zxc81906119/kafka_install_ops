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

# verify::breakglass_config -> SCRAM client of the break-glass super user kafka-admin (works without MDS)
verify::breakglass_config() {
  local f
  f=$(verify::_client_dir)/kafka-admin-scram.properties
  cat >"$f" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="kafka-admin" password="$(inv::secret KAFKA_ADMIN_PASSWORD)";
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
    KAFKA_OPTS="$(install::tools_opts)" JAVA_HOME="$(install::java_home)" \
    "$(install::bin kafka-console-producer)" --bootstrap-server "$1" --producer.config "$2" --topic "$3" \
    --producer-property acks=all --producer-property max.block.ms=20000 --producer-property delivery.timeout.ms=30000 \
    --producer-property request.timeout.ms=15000 2>&1) || return 1
  ! grep -q -i -E 'authoriz|exception|error' <<<"$out"
}

# verify::audit_has <topic> <principal> <granted true|false> [method regex]  -> such an event exists
verify::audit_has() {
  local out
  out=$(timeout 120 env KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS="$(install::tools_opts)" JAVA_HOME="$(install::java_home)" \
    "$(install::bin kafka-console-consumer)" --bootstrap-server "$(kafka::bootstrap_admin)" \
    --consumer.config "$(kafka::admin_config)" --topic "$1" --from-beginning --timeout-ms 30000 2>/dev/null || true)
  # aggregate first: jq 1.6 "-e" reports only the LAST input's result
  jq -e -n -R --arg p "$2" --argjson g "$3" --arg m "${4:-.}" '[inputs | fromjson? | select((.data.methodName | test($m))
    and .data.authenticationInfo.principal == $p and .data.authorizationInfo.granted == $g)] | length > 0' <<<"$out" >/dev/null
}

# verify::opmenu <conf> <ad user> <password> <item> [args...]
#   runs one menu item non-interactively AS THE FIXED BASTION ACCOUNT with someone's AD credentials (PoC test conf);
#   prints the menu output followed by "@@LOG@@ <last opmenu.log line>"
verify::opmenu() {
  local conf=$1 u=$2 pw=$3 j; shift 3
  j=$(inv::hosts jump | head -1)
  # node function: the password travels with the call (stdin of ssh), never on a command line
  remote::run "$j" opmenu_test::run "$conf" "$OPMENU_OS_USER" "$u" "$pw" "$@" 2>/dev/null || true
}
# verify::opmenu_result <output> -> the RESULT field of the logged line (OK / DENIED / AUTH_FAIL / FAIL ...)
verify::opmenu_result() { sed -n 's/^@@LOG@@ //p' <<<"$1" | awk -F' [|] ' '{print $7}'; }
verify::opmenu_user() { sed -n 's/^@@LOG@@ //p' <<<"$1" | awk -F' [|] ' '{print $3}'; }

verify::opmenu_section() {
  local t=/etc/opmenu/opmenu-test.conf pw j out
  pw=$(inv::secret HUMAN_DEFAULT_PASSWORD)
  j=$(inv::hosts jump | head -1)
  log::step "---- OP menu on the bastion (fixed accounts; identity = own AD login)"
  out=$(verify::opmenu "$t" alice "$pw" 12)
  verify::check "alice (kafka-admins) lists topics through the menu" test "$(verify::opmenu_result "$out")" = OK
  verify::check "the menu logs the AD identity (alice), not the shared OS account $OPMENU_OS_USER" test "$(verify::opmenu_user "$out")" = alice
  out=$(verify::opmenu "$t" alice wrong-password 12)
  verify::check "wrong AD password is rejected at menu login" test "$(verify::opmenu_result "$out")" = AUTH_FAIL
  out=$(verify::opmenu "$t" bob "$pw" 23 "$(inv::fqdn "$(inv::hosts broker | head -1)"):confluent-server" 20)
  verify::check "bob (kafka-operators) may run a host action (broker logs over ssh as $OPMENU_NODE_USER)" test "$(verify::opmenu_result "$out")" = OK
  out=$(verify::opmenu "$t" carol "$pw" 23 "$(inv::fqdn "$(inv::hosts broker | head -1)"):confluent-server" 20)
  verify::check "carol (kafka-devs) is stopped by the host-action gate (MDS authorize)" test "$(verify::opmenu_result "$out")" = DENIED
  out=$(verify::opmenu "$t" carol "$pw" 22 "$(inv::fqdn "$(inv::hosts rest | head -1)"):confluent-kafka-rest")
  verify::check "carol cannot restart REST Proxy through the shared node account" test "$(verify::opmenu_result "$out")" = DENIED
  # item 21 must refuse when its safety check cannot run (it used to count a failed check as "0 under-replicated")
  remote::run "$j" opmenu_test::broken_conf on
  out=$(verify::opmenu /tmp/opmenu-broken.conf alice "$pw" 21 "$(inv::fqdn "$(inv::hosts broker | head -1)"):confluent-server")
  verify::check "item 21 refuses to restart when the safety check fails (fail closed)" \
    bash -c '[[ $1 == *"無法檢查"* && $1 != *"已重啟"* ]]' _ "$out"
  remote::run "$j" opmenu_test::broken_conf off
  out=$(verify::opmenu "$t" alice "$pw" 91 kafka-topics --list)
  verify::check "break-glass (item 91) runs as the certificate identity through opbootstrap" \
    bash -c '[[ $1 == *"orders.events"* ]]' _ "$out"
  verify::check "break-glass use is logged as EMERGENCY with the operator's name" \
    remote::run "$j" opmenu_test::logged '| alice | 91 bootstrap .*| EMERGENCY |'
  out=$(remote::run "$j" opmenu_test::shell_as "$OPMENU_OS_USER" || true)
  verify::check "the fixed account gets no shell: 'su - $OPMENU_OS_USER -c id' does not run id" bash -c '[[ $1 != *"uid="* ]]' _ "$out"
  verify::check_not "the bastion account cannot read the break-glass key" \
    remote::run "$j" opmenu_test::read_as "$OPMENU_OS_USER" /etc/opmenu/bootstrap/breakglass.key
}

verify::consume_contains() { # <bootstrap> <config> <topic> <group> <message>
  local out attempt
  # one retry: right after rolling restarts the group coordinator may still be moving
  for attempt in 1 2; do
    # capture first: "consumer | grep -q" would SIGPIPE the consumer under pipefail
    out=$(timeout 90 env KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS="$(install::tools_opts)" JAVA_HOME="$(install::java_home)" \
      "$(install::bin kafka-console-consumer)" --bootstrap-server "$1" --consumer.config "$2" --topic "$3" --group "$4" \
      --from-beginning --timeout-ms 45000 2>/dev/null || true)
    grep -qF "$5" <<<"$out" && return 0
    [[ $attempt == 1 ]] && log::info "consume check: message not seen yet, retrying once"
  done
  return 1
}

# REST v3 produce answers HTTP 200 and reports each record's outcome in the body ("error_code": 200 | 403xx ...)
verify::rest_produce_code() { # <url> <cert>
  curl -s --max-time 20 --cacert "$PKI_DIR/ca.pem" --cert "$PKI_DIR/$2.crt" --key "$PKI_DIR/$2.key" -X POST \
    -H "Content-Type: application/json" -d '{"value":{"type":"JSON","data":{"source":"cpctl-verify"}}}' "$1" |
    grep -o '"error_code":[0-9]*' | head -1 | cut -d: -f2
}

verify::has_scram() { # <user>
  grep -q SCRAM-SHA-512 <<<"$(kafka::admin kafka-configs --bootstrap-server "$(kafka::bootstrap_admin)" --command-config "$(kafka::admin_config)" \
    --describe --entity-type users --entity-name "$1" 2>/dev/null)"
}

# verify::sbc_enabled <admin config> -> Self-Balancing runs (on the active controller; it stays STARTING when the
# controllers lack inter.broker.listener.name)
verify::sbc_enabled() {
  [[ $(kafka::admin kafka-rebalance-cluster --bootstrap-server "$(kafka::bootstrap_admin)" --command-config "$1" \
    --status 2>/dev/null) == *"Balancer status: ENABLED"* ]]
}

# verify::quota_matches <app> -> the user quota in the cluster equals APP_QUOTA_<app> (values compared as numbers)
verify::quota_matches() {
  local var have want
  var="APP_QUOTA_$(core::varname "$1")"
  want=$(tr ' ' '\n' <<<"${!var:-}" | sed '/^$/d' | awk -F= '{printf "%s=%.0f\n", $1, $2}' | sort)
  have=$(kafka::admin kafka-configs --bootstrap-server "$(kafka::bootstrap_admin)" --command-config "$(kafka::admin_config)" \
    --describe --entity-type users --entity-name "$1" 2>/dev/null | sed -n 's/^Quota configs.* are //p' | tr ',' '\n' |
    sed 's/^ *//' | awk -F= 'NF == 2 {printf "%s=%.0f\n", $1, $2}' | sort)
  [[ -n $want && $have == "$want" ]]
}


# verify::mds_cert_sub <name> -> MDS issues a token to the client certificate <name> and its principal (sub) is <name>
verify::mds_cert_sub() {
  local t p
  t=$(curl -s --max-time 10 --cacert "$PKI_DIR/ca.pem" --cert "$PKI_DIR/$1.crt" --key "$PKI_DIR/$1.key" \
    "https://$(inv::fqdn "$(inv::hosts broker | head -1)"):$PORT_MDS/security/1.0/authenticate" | jq -r '.auth_token // empty')
  [[ -n $t ]] || return 1
  p=$(cut -d. -f2 <<<"$t" | tr '_-' '/+')
  while ((${#p} % 4)); do p+='='; done
  [[ $(base64 -d <<<"$p" 2>/dev/null | jq -r .sub) == "$1" ]]
}

# verify::cert_identity <host> <config file> -> the component gets its MDS token from its certificate:
# token login by certificate configured, no MDS user/password (basic.auth.user.info) left in the file
verify::cert_identity() {
  local conf
  conf=$(remote::run "$1" sys_node::read_conf "$2") || return 1
  grep -q 'TokenCertificateLoginCallbackHandler' <<<"$conf" && ! grep -q 'basic\.auth\.user\.info' <<<"$conf"
}

# verify::_mds <path> [curl args...] -> MDS call authenticated with the svc-cpctl certificate
verify::_mds() {
  local p=$1 t mds
  shift
  mds="https://$(inv::fqdn "$(inv::hosts broker | head -1)"):$PORT_MDS"
  t=$(curl -s --max-time 10 --cacert "$PKI_DIR/ca.pem" --cert "$PKI_DIR/svc-cpctl.crt" --key "$PKI_DIR/svc-cpctl.key" \
    "$mds/security/1.0/authenticate" | jq -r '.auth_token // empty') || return 1
  curl -s --max-time 10 --cacert "$PKI_DIR/ca.pem" -H "Authorization: Bearer $t" "$@" "$mds$p"
}

# verify::no_roles <principal> -> no RBAC role binding on the Kafka cluster
verify::no_roles() {
  local cid
  cid=$(rbac::cluster_id)
  [[ $(verify::_mds "/security/1.0/lookup/principal/$1/resources" -X POST -H 'Content-Type: application/json' \
    -d "{\"clusters\":{\"kafka-cluster\":\"$cid\"}}") == '{}' ]]
}

# verify::c3_as_human <user> <password> -> C3 lists the Kafka cluster for a person logged in through MDS (AD)
verify::c3_as_human() {
  local t
  t=$(printf 'user = "%s:%s"\n' "$1" "$2" | curl -s -K - --max-time 10 --cacert "$PKI_DIR/ca.pem" \
    "https://$(inv::fqdn "$(inv::hosts broker | head -1)"):$PORT_MDS/security/1.0/authenticate" | jq -r '.auth_token // empty')
  [[ -n $t ]] || return 1
  [[ $(curl -s --max-time 20 --cacert "$PKI_DIR/ca.pem" -H "Authorization: Bearer $t" \
    "https://$(inv::fqdn "$(inv::hosts c3 | head -1)"):$PORT_C3/2.0/clusters/kafka") == *'"clusterId"'* ]]
}

verify::rest_code() { # <url> <cert name|-> [curl args...]
  local url=$1 cert=$2; shift 2
  local certargs=()
  [[ $cert != - ]] && certargs=(--cert "$PKI_DIR/$cert.crt" --key "$PKI_DIR/$cert.key")
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 --cacert "$PKI_DIR/ca.pem" "${certargs[@]}" "$@" "$url" || true
}

verify::run_all() {
  role::common_vars
  local cfg ccfg cid boot_client boot_ldap first_broker msg
  cfg=$(kafka::admin_config)
  ccfg=$(kafka::controller_config)
  core::load_env "$STATE_DIR/kraft.env"
  cid=$CLUSTER_ID
  boot_client=$(inv::endpoints broker "$PORT_CLIENT")
  boot_ldap=$(inv::endpoints broker "$PORT_LDAP")
  first_broker=$(inv::fqdn "$(inv::hosts broker | head -1)")
  msg="cpctl-verify-$CPCTL_RUN_ID"

  log::step "---- KRaft dynamic quorum"
  local q
  q=$(kafka::admin kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$ccfg" describe --status 2>&1 || true)
  grep -q 'LeaderId:' <<<"$q" && verify::pass "quorum has a leader ($(grep -o 'LeaderId:[^ ]*' <<<"$q" | head -1))" || verify::fail "quorum has no leader"
  local voters
  voters=$(grep -o '"directoryId"' <<<"$(grep 'CurrentVoters' <<<"$q")" | wc -l)
  [[ $voters -eq $(inv::hosts controller | wc -l) ]] && verify::pass "$voters voters, each with a directory id (dynamic quorum)" ||
    verify::fail "expected $(inv::hosts controller | wc -l) voters with directory ids, got $voters"
  kafka::admin kafka-features --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$ccfg" describe 2>/dev/null |
    grep -E 'Feature: kraft.version.*FinalizedVersionLevel: 1' -q && verify::pass "kraft.version finalized at 1" || verify::fail "kraft.version is not 1"
  local mv
  mv=$(kafka::admin kafka-features --bootstrap-server "$(kafka::bootstrap_admin)" --command-config "$cfg" describe 2>/dev/null |
    awk '/Feature: confluent.metadata.version/ {for (i=1;i<=NF;i++) if ($i=="FinalizedVersionLevel:") print $(i+1)}')
  log::info "metadata.version finalized level: ${mv:-?}"

  log::step "---- Brokers"
  local reg
  reg=$(kafka::admin kafka-broker-api-versions --bootstrap-server "$(kafka::bootstrap_admin)" --command-config "$cfg" 2>/dev/null | grep -c '(id:' || true)
  [[ $reg -eq $(inv::hosts broker | wc -l) ]] && verify::pass "$reg brokers registered" || verify::fail "only $reg brokers registered"
  local racks
  racks=$(kafka::admin kafka-broker-api-versions --bootstrap-server "$(kafka::bootstrap_admin)" --command-config "$cfg" 2>/dev/null | grep -o 'rack: [^)]*' | sort -u | paste -sd' ' -)
  [[ $racks == *rack-a* && $racks == *rack-b* ]] && verify::pass "rack awareness: $racks" || verify::fail "racks: $racks"
  verify::check "Self-Balancing is running (balancer status ENABLED)" verify::sbc_enabled "$cfg"

  log::step "---- Internal mTLS (shared internal certificate)"
  verify::check_not "controller rejects a client without certificate" timeout 40 env KAFKA_HEAP_OPTS=-Xmx128m \
    KAFKA_OPTS="$(install::tools_opts)" JAVA_HOME="$(install::java_home)" "$(install::bin kafka-metadata-quorum)" \
    --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$(verify::nocert_config)" describe --status
  verify::check "controller accepts the shared internal certificate (super user)" kafka::admin kafka-metadata-quorum \
    --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$ccfg" describe --status

  log::step "---- Applications over SCRAM (CLIENT listener) + RBAC"
  verify::check "app-orders produces to orders.events (RBAC DeveloperWrite)" verify::produce "$boot_client" "$(verify::scram_config app-orders)" orders.events "$msg"
  verify::check "app-orders consumes it back (DeveloperRead topic + group)" verify::consume_contains "$boot_client" "$(verify::scram_config app-orders)" orders.events orders-verify "$msg"
  verify::check_not "app-orders is denied on payments.events (no binding)" verify::produce "$boot_client" "$(verify::scram_config app-orders)" payments.events "$msg"
  verify::check_not "wrong SCRAM password is rejected" verify::produce "$boot_client" "$(verify::ldap_config app-orders x)" orders.events "$msg"

  log::step "---- Service identities by certificate (AD holds only the bind account svc-mds-bind)"
  local svc
  for svc in ${SERVICE_CERTS:-}; do
    verify::check "MDS issues a token to the $svc certificate, principal $svc (no AD account, no password)" verify::mds_cert_sub "$svc"
  done
  verify::check "[$(inv::hosts rest | head -1)] REST Proxy: MDS and Kafka identity from svc-rest certificate, no MDS password" \
    verify::cert_identity "$(inv::hosts rest | head -1)" "$REST_CONF"
  verify::check "[$(inv::hosts c3 | head -1)] Control Center: MDS and Kafka identity from svc-c3 certificate, no MDS password" \
    verify::cert_identity "$(inv::hosts c3 | head -1)" "$C3_CONF"

  verify::check "cpctl manages the brokers as svc-cpctl (MDS token on the TOKEN listener, not the internal certificate)" \
    kafka::admin kafka-topics --bootstrap-server "$(kafka::bootstrap_admin)" --command-config "$cfg" --list
  verify::check "break-glass kafka-admin (SCRAM, no MDS needed) can administer the cluster" \
    kafka::admin kafka-topics --bootstrap-server "$boot_client" --command-config "$(verify::breakglass_config)" --list

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
  local qa var
  for qa in $APPS; do
    var="APP_QUOTA_$(core::varname "$qa")"
    if [[ -n ${!var:-} ]]; then verify::check "client quota of $qa applied (${!var})" verify::quota_matches "$qa"; fi
  done

  log::step "---- Control Center and monitoring"
  local c3
  c3=$(inv::fqdn "$(inv::hosts c3 | head -1)")
  verify::check "C3 UI via LB https://$LB_C3_NAME:$PORT_C3 = 200" test "$(verify::rest_code "https://$LB_C3_NAME:$PORT_C3/" -)" = 200
  verify::check "C3 serves the cluster to an AD user (alice's MDS token)" verify::c3_as_human alice "$(inv::secret HUMAN_DEFAULT_PASSWORD)"
  verify::check "the shared server certificate (User:cp-server) holds no RBAC role (C3 runs as svc-c3)" verify::no_roles User:cp-server
  verify::check_not "Prometheus rejects clients without a certificate" test "$(verify::rest_code "https://$c3:$PORT_PROMETHEUS/-/ready" -)" = 200
  local series
  series=$(curl -s --max-time 20 --cacert "$PKI_DIR/ca.pem" --cert "$PKI_DIR/cp-server.crt" --key "$PKI_DIR/cp-server.key" \
    "https://$c3:$PORT_PROMETHEUS/api/v1/label/__name__/values" | grep -o 'io_confluent_kafka_server[a-z_]*' | sort -u | wc -l || true)
  [[ ${series:-0} -gt 0 ]] && verify::pass "Prometheus receives broker/controller metrics ($series metric names)" ||
    verify::fail "no io_confluent_kafka_server metrics in Prometheus yet (first scrape can take ~2 min)"

  log::step "---- Audit, packages, offline"
  if repo::tls; then
    if repo::remote_web; then
      verify::check "internal repo served by $REPO_WEB_HOST over HTTPS, identical to the ops build (repomd.xml of every repo)" repo::verify_served
    else
      verify::check "internal repo served over HTTPS; the server certificate chains to the trust bundle" repo::_served_quiet
    fi
    # from a NODE, with the CA file dnf pins: a check on the repo host itself would not see its firewall
    local node
    node=$(inv::hosts broker | head -1)
    verify::check "[$node] reaches the repo over HTTPS with the pinned CA (cp-repo-ca.pem)" \
      remote::exec "$node" "curl -fsS --max-time 10 --cacert /etc/pki/tls/certs/cp-repo-ca.pem -o /dev/null ${REPO_YUM_BASEURL%/}/confluent/repodata/repomd.xml"
    local plain
    if repo::remote_web; then plain="http://$REPO_WEB_HOST/rpm/confluent/repodata/repomd.xml"; else plain="http://$(inv::fqdn "$(repo::server)"):8080/rpm/confluent/repodata/repomd.xml"; fi
    verify::check_not "plain HTTP does not serve the repo ($plain answers 403 or nothing)" \
      bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$1") == 200 ]]' _ "$plain"
  fi
  verify::check "audit log topic $AUDIT_TOPIC exists" kafka::admin kafka-topics --bootstrap-server "$(kafka::bootstrap_admin)" --command-config "$cfg" --describe --topic "$AUDIT_TOPIC"
  # earlier checks: alice produced to payments.events (allowed), app-orders tried (denied) -> routed to the sensitive topic
  verify::check "audit: allowed produce of User:alice on payments.* is in $AUDIT_SENSITIVE_TOPIC" verify::audit_has "$AUDIT_SENSITIVE_TOPIC" User:alice true "^kafka.Produce$"
  verify::check "audit: denied access of User:app-orders to payments.* is in $AUDIT_SENSITIVE_TOPIC" verify::audit_has "$AUDIT_SENSITIVE_TOPIC" User:app-orders false
  verify::check "audit writer is the dedicated principal $AUDIT_PRINCIPAL (not a super user)" \
    bash -c '[[ ";$1;" != *";User:$2;"* ]]' _ "$SUPER_USERS" "$AUDIT_PRINCIPAL"
  local h
  for h in $(inv::hosts broker | head -1) $(inv::hosts rest | head -1) $(inv::hosts c3) $(inv::hosts ops); do
    verify::check_not "[$h] has no Internet access (offline)" remote::exec "$h" "curl -s -m 5 -o /dev/null https://packages.confluent.io"
  done
  verify::check "[$(inv::hosts broker | head -1)] CP version is pinned ($INSTALL_METHOD: $( [[ $INSTALL_METHOD == rpm ]] && echo 'dnf versionlock' || echo 'current symlink'))" \
    install::pinned "$(inv::hosts broker | head -1)"
  for h in $(inv::hosts c3); do
    verify::check_not "[$h] has no Confluent Platform packages (C3 host must stay clean)" remote::exec "$h" "rpm -q confluent-server confluent-common >/dev/null 2>&1 || test -e /opt/confluent/current"
  done

  if [[ ${JMX_EXPORTER:-off} == on ]]; then
    log::step "---- External monitoring (JMX exporter)"
    verify::check "every controller / broker / REST exporter: HTTPS, auth required, metrics served" monitoring::check
  fi

  # OP menu: only once step 11 has run (fresh installs verify in step 10, before the bastion exists)
  if jump::enabled && [[ -f $STAMP_DIR/11_opmenu ]]; then verify::opmenu_section; fi

  log::step "---- Certificates"
  pki::status || true   # expiring soon / not yet switched = warning only (cpctl certs status shows served certs too)
  verify::check "[$first_broker] MDS presents the current cp-server certificate" \
    test "$(pki::served_serial "$first_broker:$PORT_MDS")" = "$(pki::serial cp-server)"

  log::step "---- License"
  local lrc=0
  license::status || lrc=$?
  [[ $lrc -eq 1 ]] && VERIFY_FAILED=1   # expired = failure; expiring soon / trial = warning only
  [[ -s $CONF_DIR/license.txt ]] || log::warn "evaluation mode: put the purchased license in conf/license.txt before go-live"
  return "$VERIFY_FAILED"
}
