#!/usr/bin/env bats
# Unit tests for the cpctl framework (run on the ops host: bats installer/tests).
load helper

setup() { setup_cpctl; setup_node; }

# ---------- inventory (Repository)
@test "inv::hosts lists a role's hosts one per line" {
  run inv::hosts controller
  [ "$status" -eq 0 ]
  [ "${lines[*]}" = "kc01 kc02 kc03" ]
}

@test "inv::get maps hyphenated host names and falls back to a default" {
  [ "$(inv::get c3-01 ROLEFLAG)" = yes ]
  [ "$(inv::get kc02 NODE_ID 99)" = 99 ]
}

@test "inv::endpoints builds a comma separated FQDN list" {
  [ "$(inv::endpoints controller 9093)" = "kc01.test.lab:9093,kc02.test.lab:9093,kc03.test.lab:9093" ]
  [ "$(inv::endpoints broker 8090 https)" = "https://kb01.test.lab:8090,https://kb02.test.lab:8090" ]
}

@test "inv::apps splits apps by access channel (scram is the default)" {
  [ "$(inv::apps scram | paste -sd' ' -)" = "app-a app-b" ]
  [ "$(inv::apps rest)" = app-legacy ]
}

@test "inv::heap reads the profile specific value" {
  [ "$(inv::heap broker)" = 512m ]
}

# ---------- render
@test "render::to substitutes placeholders and leaves other dollar signs alone" {
  tpl_dir="$BATS_TEST_TMPDIR/tpl"; mkdir -p "$tpl_dir/default"
  printf 'a=${FOO}\nrule=RULE:.*CN=(x)$/$1/\n' >"$tpl_dir/default/t.tpl"
  render::find() { printf '%s' "$tpl_dir/default/$1"; }
  export FOO=bar
  render::to t.tpl "$BATS_TEST_TMPDIR/out"
  run cat "$BATS_TEST_TMPDIR/out"
  [ "${lines[0]}" = "a=bar" ]
  [ "${lines[1]}" = 'rule=RULE:.*CN=(x)$/$1/' ]
}

@test "render::to refuses undefined placeholders" {
  tpl_dir="$BATS_TEST_TMPDIR/tpl"; mkdir -p "$tpl_dir/default"
  printf 'x=${NOT_DEFINED_ANYWHERE}\n' >"$tpl_dir/default/u.tpl"
  render::find() { printf '%s' "$tpl_dir/default/$1"; }
  run render::to u.tpl "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *NOT_DEFINED_ANYWHERE* ]]
}

@test "render::to accepts templates without placeholders" {
  tpl_dir="$BATS_TEST_TMPDIR/tpl"; mkdir -p "$tpl_dir/default"
  printf 'static: true\n' >"$tpl_dir/default/s.tpl"
  render::find() { printf '%s' "$tpl_dir/default/$1"; }
  run render::to s.tpl "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = "static: true" ]
}

# ---------- ensure::* (idempotent primitives)
@test "ensure::file: new -> changed, same content -> ok, new content -> changed with backup" {
  d="$BATS_TEST_TMPDIR/n"; mkdir -p "$d"
  printf 'v1\n' >"$d/src"; run ensure::file "$d/src" "$d/dst" "$ME" "$MYGROUP" 0640
  [[ "$output" == *"::changed::"* ]]
  printf 'v1\n' >"$d/src"; run ensure::file "$d/src" "$d/dst" "$ME" "$MYGROUP" 0640
  [[ "$output" == *"::ok::"* ]]
  printf 'v2\n' >"$d/src"; run ensure::file "$d/src" "$d/dst" "$ME" "$MYGROUP" 0640
  [[ "$output" == *"content changed"* ]]
  [ "$(cat "$d/dst")" = v2 ]
  ls "$d"/dst.bak.* >/dev/null
}

@test "ensure::file in check mode reports but does not write" {
  d="$BATS_TEST_TMPDIR/c"; mkdir -p "$d"
  printf 'x\n' >"$d/src"
  CPCTL_CHECK=1 run ensure::file "$d/src" "$d/dst" "$ME" "$MYGROUP" 0640
  [[ "$output" == *"::changed::"* ]]
  [ ! -e "$d/dst" ]
}

@test "ensure::file never changes the mode of an existing parent directory" {
  d="$BATS_TEST_TMPDIR/p"; mkdir -p "$d/conf"; chmod 0750 "$d/conf"
  printf 'x\n' >"$d/src"
  ensure::file "$d/src" "$d/conf/f" "$ME" "$MYGROUP" 0640 >/dev/null
  [ "$(stat -c %a "$d/conf")" = 750 ]
}

@test "backups never stay in the trust anchors (every file there is trusted), elsewhere they stay next to the file" {
  ensure::_consumes_all /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem
  run ensure::_consumes_all /etc/confluent/kafka/server.properties; [ "$status" -ne 0 ]
  run ensure::_consumes_all /etc/sysctl.d/90-confluent.conf; [ "$status" -ne 0 ]
  [[ $ENSURE_BACKUP_DIR == /var/* ]]
}

@test "no backup is ever kept for private keys / keystores on the nodes" {
  ensure::_is_key_material /etc/confluent/ssl/kafka-internal.p12
  ensure::_is_key_material /etc/confluent/ssl/cp-server.key
  ensure::_is_key_material /etc/confluent/ssl/mds-token-keypair.enc.pem
  ensure::_is_key_material /etc/opmenu/bootstrap/breakglass.p12
  run ensure::_is_key_material /etc/confluent/ssl/ca.pem; [ "$status" -ne 0 ]
  run ensure::_is_key_material /etc/confluent/kafka/server.properties; [ "$status" -ne 0 ]
  run ensure::_is_key_material /tmp/x.p12; [ "$status" -ne 0 ]
}

@test "repo import is all-or-nothing: one conflicting file -> nothing is published" {
  local land="$BATS_TEST_TMPDIR/land" repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$land/tools" "$repo/raw/tools"
  echo a >"$land/tools/a.jar"; echo b-new >"$land/tools/b.jar"; echo b-old >"$repo/raw/tools/b.jar"
  (cd "$land" && sha256sum tools/a.jar tools/b.jar >SHA256SUMS)
  run bash -c '
    REPO_LANDING=$1 REPO_LOCAL_ROOT=$2
    source "$CPCTL_HOME/lib/core.sh"; source "$CPCTL_HOME/lib/log.sh"; source "$CPCTL_HOME/lib/repo/local.sh"
    trap - ERR; set +e
    repo::_verify_landing() { :; }
    repo::_as_owner() { "$@"; }
    repo::import' _ "$land" "$repo"
  [ "$status" -ne 0 ]
  [[ $output == *"nothing was published"* ]]
  [ ! -e "$repo/raw/tools/a.jar" ]
}

@test "ensure::dir and ensure::symlink converge and then report ok" {
  d="$BATS_TEST_TMPDIR/s"
  run ensure::dir "$d" "$ME" "$MYGROUP" 0750; [[ "$output" == *"::changed::"* ]]
  run ensure::dir "$d" "$ME" "$MYGROUP" 0750; [[ "$output" == *"::ok::"* ]]
  run ensure::symlink /etc "$d/l"; [[ "$output" == *"::changed::"* ]]
  run ensure::symlink /etc "$d/l"; [[ "$output" == *"::ok::"* ]]
}

# ---------- step runner (Template Method + stamps)
@test "step::run skips when inputs are unchanged and verify passes, re-applies on drift" {
  mkdir -p "$BATS_TEST_TMPDIR/steps"
  cat >"$BATS_TEST_TMPDIR/steps/50_demo.sh" <<EOF
STEP_DESC="demo"
step_apply() { echo applied >>"$BATS_TEST_TMPDIR/apply.log"; touch "$BATS_TEST_TMPDIR/state.ok"; }
step_verify() { [[ -f "$BATS_TEST_TMPDIR/state.ok" ]]; }
EOF
  step::_path() { printf '%s' "$BATS_TEST_TMPDIR/steps/50_demo.sh"; }
  step::run 50_demo 2>/dev/null
  step::run 50_demo 2>/dev/null
  [ "$(wc -l <"$BATS_TEST_TMPDIR/apply.log")" -eq 1 ]   # second run skipped
  rm -f "$BATS_TEST_TMPDIR/state.ok"                      # simulate drift
  step::run 50_demo 2>/dev/null
  [ "$(wc -l <"$BATS_TEST_TMPDIR/apply.log")" -eq 2 ]   # re-applied
}

# ---------- handler (Observer)
@test "handler::notify de-duplicates and persists across runs" {
  handler::notify broker kb01
  handler::notify broker kb01
  CPCTL_RUN_ID=another-run handler::notify broker kb02
  [ "$(wc -l <"$(handler::_file)")" -eq 2 ]
}

# ---------- generated security settings
@test "protected users = super users + every AD service account, no duplicates" {
  SUPER_USERS="User:kafka-internal;User:svc-x"
  [ "$(role::protected_users)" = "User:kafka-internal;User:svc-x;User:svc-y" ]
}

@test "REST principal rule accepts exactly the legacy CNs, has no DEFAULT and no comma" {
  rule=$(role::rest_principal_rules)
  [ "$rule" = 'RULE:.*CN=(app-legacy)([^a-zA-Z0-9._-].*)?$/$1/' ]
  [[ "$rule" != *,* ]]
  # behaves like Kafka's mapper: exact CN only
  re='.*CN=(app-legacy)([^a-zA-Z0-9._-].*)?$'
  [[ "C=TW,O=Bank,CN=app-legacy" =~ $re ]]
  ! [[ "C=TW,O=Bank,CN=app-legacy-evil" =~ $re ]]
  ! [[ "C=TW,O=Bank,CN=app-a" =~ $re ]]
}

# ---------- audit log routing (conf/audit.env -> confluent.security.event.router.config)
@test "audit router: default + sensitive topics, retention, exclusions, routes incl. denied describe" {
  AUDIT_TOPIC=confluent-audit-log-events AUDIT_SENSITIVE_TOPIC=confluent-audit-log-events_sensitive
  AUDIT_RETENTION_DAYS=90 AUDIT_SENSITIVE_RETENTION_DAYS=365
  AUDIT_SENSITIVE_PREFIXES="payments. cards." AUDIT_EXCLUDED_PRINCIPALS="User:kafka-internal User:svc-c3"
  j=$(role::audit_router_json)
  [ "$(jq -r '.default_topics.denied' <<<"$j")" = confluent-audit-log-events ]
  [ "$(jq -r '.destinations.topics["confluent-audit-log-events_sensitive"].retention_ms' <<<"$j")" = 31536000000 ]
  [ "$(jq -c '.excluded_principals' <<<"$j")" = '["User:kafka-internal","User:svc-c3"]' ]
  [ "$(jq -r '.routes | keys | join(" ")' <<<"$j")" = "crn:///kafka=*/topic=cards.* crn:///kafka=*/topic=payments.*" ]
  [ "$(jq -r '.routes["crn:///kafka=*/topic=payments.*"].describe.allowed' <<<"$j")" = "" ]
  [ "$(jq -r '.routes["crn:///kafka=*/topic=payments.*"].consume.denied' <<<"$j")" = confluent-audit-log-events_sensitive ]
  [[ $j != *$'\n'* ]]   # one line (properties value)
}

# ---------- PKI: only managed leaves are rotated / checked
@test "managed leaf certificates = shared certs + legacy REST apps only" {
  # shellcheck source=/dev/null
  source "$CPCTL_HOME/lib/pki.sh"
  [ "$(pki::leaves | paste -sd' ' -)" = "kafka-internal cp-server app-legacy" ]
}

# ---------- OS: firewall ports derived from roles
@test "firewall ports follow the host roles" {
  # shellcheck source=/dev/null
  source "$CPCTL_HOME/steps/01_os_baseline.sh"
  PORT_CONTROLLER=9093 PORT_JMX_EXPORTER=7071 PORT_INTERNAL=9092 PORT_TOKEN=9094 PORT_CLIENT=9095 PORT_LDAP=9096
  PORT_MDS=8090 PORT_REST=8082 PORT_C3=9021 PORT_PROMETHEUS=9090 FIREWALL_EXTRA_ops=8080
  [ "$(os::fw_ports controller)" = "7071 9093" ]
  [ "$(os::fw_ports broker)" = "7071 8090 9092 9094 9095 9096" ]
  [ "$(os::fw_ports c3)" = "9021 9090" ]
  [ "$(os::fw_ports ops)" = "8080" ]
}

# ---------- OP menu (bastion)
@test "break-glass certificate is managed (rotated, never pruned) only when the OP menu is on" {
  # shellcheck source=/dev/null
  source "$CPCTL_HOME/lib/pki.sh"
  OPMENU=off
  [[ $(pki::leaves | paste -sd' ' -) != *opmenu-breakglass* ]]
  OPMENU=on OPMENU_BREAKGLASS=opmenu-breakglass
  [ "$(pki::leaves | paste -sd' ' -)" = "kafka-internal cp-server opmenu-breakglass app-legacy" ]
}

@test "node access: a node may restart only its own units; the bastion opens no service port" {
  # shellcheck source=/dev/null
  source "$CPCTL_HOME/roles/jump.sh"
  HOSTS_rest="rest01" HOSTS_jump="jump01"
  [ "$(jump::units_of kc01)" = "confluent-server" ]
  [ "$(jump::units_of kb01)" = "confluent-server" ]
  [ "$(jump::units_of rest01)" = "confluent-kafka-rest" ]
  [ "$(jump::units_of c3-01)" = "confluent-control-center" ]
  [ -z "$(jump::units_of jump01)" ]
  # shellcheck source=/dev/null
  source "$CPCTL_HOME/steps/01_os_baseline.sh"
  [ -z "$(os::fw_ports jump)" ]
}

# ---------- PKI external CA (bank): request -> answer -> checks before import
# bank_setup: root + issuing CA in $B; trust/ holds the root only (what the bank hands over)
bank_setup() {
  # shellcheck source=/dev/null
  source "$CPCTL_HOME/lib/pki.sh"
  export PKI_MODE=external PKI_KEY_BITS=2048 PKI_CERT_DAYS=365 PKI_RENEW_BEFORE_DAYS=30 CPCTL_RUN_ID=t
  B=$BATS_TEST_TMPDIR/bank
  mkdir -p "$B" "$PKI_DIR/trust"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$B/root.key" -subj "/CN=Test Bank Root" -days 30 -out "$B/root.crt" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout "$B/int.key" -subj "/CN=Test Bank Issuing" -out "$B/int.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign\n' >"$B/int.ext"
  openssl x509 -req -in "$B/int.csr" -CA "$B/root.crt" -CAkey "$B/root.key" -CAcreateserial -days 3000 \
    -extfile "$B/int.ext" -out "$B/int.crt" 2>/dev/null
  cp "$B/root.crt" "$PKI_DIR/trust/bank-root.pem"
}
# bank_sign <name> <eku> [SAN ext value] -> leaf only in $B/<name>.leaf
bank_sign() {
  { printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=%s\n' "$2"; [ -n "${3:-}" ] && printf 'subjectAltName=%s\n' "$3"; } >"$B/$1.ext"
  openssl x509 -req -in "$PKI_DIR/requests/$1.csr" -CA "$B/int.crt" -CAkey "$B/int.key" -CAcreateserial -days 365 \
    -extfile "$B/$1.ext" -out "$B/$1.leaf" 2>/dev/null
}
check() { pki::check_signed "$1" "$2" "$3" "$4" "$PKI_DIR/pending/$1.key"; }

@test "external CA: request has key, CSR with SAN + both EKUs, and a request sheet" {
  bank_setup
  pki::request kafka-internal "kb01,kb01.test.lab" serverAuth,clientAuth
  [ -f "$PKI_DIR/pending/kafka-internal.key" ]
  [ "$(stat -c %a "$PKI_DIR/pending/kafka-internal.key")" = 600 ]
  t=$(openssl req -in "$PKI_DIR/requests/kafka-internal.csr" -noout -text)
  [[ $t == *"DNS:kb01, DNS:kb01.test.lab"* ]]
  [[ $t == *"TLS Web Server Authentication, TLS Web Client Authentication"* ]]
  grep -q "BOTH are required" "$PKI_DIR/requests/kafka-internal.req.txt"
  [ "$(pki::pending)" = kafka-internal ]
}

@test "external CA: a correct answer (any order, root included) passes; chain = leaf then intermediate" {
  bank_setup
  pki::request cp-server "a.test.lab,b.test.lab" serverAuth,clientAuth
  bank_sign cp-server serverAuth,clientAuth "DNS:b.test.lab,DNS:a.test.lab"
  cat "$B/root.crt" "$B/int.crt" "$B/cp-server.leaf" >"$B/answer.pem"
  run check cp-server "a.test.lab,b.test.lab" serverAuth,clientAuth "$B/answer.pem"
  [ "$status" -eq 0 ]
  chain=${output#* }
  [ "$(grep -c 'BEGIN CERTIFICATE' "$chain")" = 2 ]
  [ "$(openssl x509 -in "$chain" -noout -subject)" = "subject=CN=cp-server, OU=Confluent, O=PoC Bank, C=TW" ]
  [ "$(sed -n '/END/,$p' "$chain" | sed 1d | openssl x509 -noout -subject)" = "subject=CN=Test Bank Issuing" ]
}

@test "external CA: rejected without the intermediate, without clientAuth, with other SANs or another key" {
  bank_setup
  pki::request kafka-internal "kb01" serverAuth,clientAuth
  bank_sign kafka-internal serverAuth,clientAuth "DNS:kb01"
  run check kafka-internal kb01 serverAuth,clientAuth "$B/kafka-internal.leaf"
  [ "$status" -eq "$E_GATE" ]; [[ $output == *"does not chain to a bank root"* ]]
  bank_sign kafka-internal serverAuth "DNS:kb01"
  cat "$B/kafka-internal.leaf" "$B/int.crt" >"$B/a.pem"
  run check kafka-internal kb01 serverAuth,clientAuth "$B/a.pem"
  [ "$status" -eq "$E_GATE" ]; [[ $output == *"lacks clientAuth"* ]]
  bank_sign kafka-internal serverAuth,clientAuth "DNS:kb02"
  cat "$B/kafka-internal.leaf" "$B/int.crt" >"$B/a.pem"
  run check kafka-internal kb01 serverAuth,clientAuth "$B/a.pem"
  [ "$status" -eq "$E_GATE" ]; [[ $output == *"SAN differs"* ]]
  pki::request cp-server "" clientAuth
  bank_sign cp-server clientAuth
  cat "$B/cp-server.leaf" "$B/int.crt" >"$B/a.pem"
  run check kafka-internal kb01 serverAuth,clientAuth "$B/a.pem"
  [ "$status" -eq "$E_GATE" ]; [[ $output == *"matches the pending private key"* ]]
}

@test "external CA: a dedicated intermediate can be the only trust anchor" {
  bank_setup
  cp "$B/int.crt" "$PKI_DIR/trust/bank-root.pem"
  pki::request app-x "" clientAuth
  bank_sign app-x clientAuth
  run check app-x "" clientAuth "$B/app-x.leaf"
  [ "$status" -eq 0 ]
  pki::verify_current "$B/app-x.leaf"
}

@test "truststore is rebuilt beside the target and renamed into place (never missing / partial)" {
  bank_setup
  [ -x /usr/lib/jvm/temurin-21-jdk/bin/keytool ] || skip "no JDK"
  install::java_home() { echo /usr/lib/jvm/temurin-21-jdk; }
  cat "$PKI_DIR/trust/bank-root.pem" "$B/int.crt" >"$PKI_DIR/ca.pem"
  echo old >"$PKI_DIR/t.p12"
  ino=$(stat -c %i "$PKI_DIR/t.p12")
  pki::_build_truststore "$PKI_DIR/t.p12" changeit
  [ "$(stat -c %i "$PKI_DIR/t.p12")" != "$ino" ]               # a new file, not rewritten in place
  [ "$(ls "$PKI_DIR" | grep -c '\.new\.')" = 0 ]
  [ "$(pki::keytool -list -keystore "$PKI_DIR/t.p12" -storepass changeit | grep -c trustedCertEntry)" = 2 ]
}
