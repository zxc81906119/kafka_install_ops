# shellcheck shell=bash
STEP_DESC="security bootstrap: SCRAM users for apps, RBAC role bindings (groups, services, apps), sample topics"

step_inputs() { cat "$CONF_DIR/apps.env" "$CONF_DIR/audit.env"; }

security::scram_user() { # <user> <password>
  local u=$1 pw=$2 cfg
  cfg=$(kafka::admin_config)
  if grep -q 'SCRAM-SHA-512' <<<"$(kafka::admin kafka-configs --bootstrap-server "$(kafka::bootstrap_internal)" \
    --command-config "$cfg" --describe --entity-type users --entity-name "$u" 2>/dev/null)"; then
    log::ok "SCRAM user $u"
    return 0
  fi
  log::changed "SCRAM user $u"
  step::mutating || return 0
  kafka::admin kafka-configs --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" \
    --alter --entity-type users --entity-name "$u" --add-config "SCRAM-SHA-512=[iterations=8192,password=$pw]" >/dev/null
}

security::topic() { # <name> [partitions]
  local t=$1 p=${2:-6} cfg
  cfg=$(kafka::admin_config)
  if kafka::admin kafka-topics --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" \
    --describe --topic "$t" >/dev/null 2>&1; then
    log::ok "topic $t"
    return 0
  fi
  log::changed "topic $t (partitions=$p, RF=3, min.insync=2)"
  step::mutating || return 0
  kafka::admin kafka-topics --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" \
    --create --if-not-exists --topic "$t" --partitions "$p" --replication-factor 3 --config min.insync.replicas=2 >/dev/null
}

step_apply() {
  local app var spec g
  # SCRAM users only for apps on the direct Kafka path (legacy REST apps get no Kafka password)
  for app in $(inv::apps scram); do security::scram_user "$app" "$(inv::secret "$(inv::app_secret_var "$app")")"; done

  # audit-log writer (also created at format time on new clusters): only the audit topics, nothing else
  security::scram_user "$AUDIT_PRINCIPAL" "$(inv::secret AUDIT_PASSWORD)"

  rbac::login
  for spec in $AUDIT_BINDINGS; do rbac::ensure "User:$AUDIT_PRINCIPAL" "$spec"; done
  # Control Center service account must be SystemAdmin (documented C3 requirement)
  rbac::ensure User:svc-c3 SystemAdmin
  local svc
  for svc in ${SERVICE_ACCOUNTS:-}; do
    var="SERVICE_BINDINGS_$(core::varname "$svc")"
    for spec in ${!var:-}; do rbac::ensure "User:$svc" "$spec"; done
  done
  for g in $AD_GROUPS; do
    var="GROUP_BINDINGS_$(core::varname "$g")"
    for spec in ${!var:-}; do rbac::ensure "Group:$g" "$spec"; done
  done
  # mTLS principals cannot use group bindings -> one binding set per application user
  for app in $APPS; do
    var="APP_BINDINGS_$(core::varname "$app")"
    for spec in ${!var:-}; do rbac::ensure "User:$app" "$spec"; done
  done

  local t
  for t in $TOPICS; do security::topic "${t%%:*}" "${t#*:}"; done
}

step_verify() {
  kafka::admin kafka-topics --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$(kafka::admin_config)" \
    --describe --topic orders.events >/dev/null 2>&1
}
