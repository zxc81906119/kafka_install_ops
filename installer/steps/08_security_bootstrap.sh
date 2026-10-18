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

readonly QUOTA_KEYS="producer_byte_rate consumer_byte_rate request_percentage controller_mutation_rate"

# security::quota_now <entity args...> -> "key=value" per line, values as integers (describe prints 1.048576E7)
security::quota_now() {
  kafka::admin kafka-configs --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$(kafka::admin_config)" \
    --describe --entity-type users "$@" 2>/dev/null |
    sed -n 's/.* are //p' | tr ',' '\n' | sed 's/^ *//' |
    awk -F= 'NF == 2 {printf "%s=%.0f\n", $1, $2}' | sort
}

# security::quota <label> <wanted "k=v k=v"> <entity args...>   e.g. --entity-name app-orders | --entity-default
security::quota() {
  local label=$1 want=$2; shift 2
  local have wanted k add=() del=()
  have=$(security::quota_now "$@")
  wanted=$(tr ' ' '\n' <<<"$want" | sed '/^$/d' | awk -F= '{printf "%s=%.0f\n", $1, $2}' | sort)
  if [[ $have == "$wanted" ]]; then
    log::ok "quota $label ${want:-none}"
    return 0
  fi
  for k in $QUOTA_KEYS; do
    if grep -q "^$k=" <<<"$wanted"; then
      add+=("$(grep "^$k=" <<<"$wanted")")
    elif grep -q "^$k=" <<<"$have"; then
      del+=("$k")
    fi
  done
  log::changed "quota $label: ${have//$'\n'/ } -> ${want:-none}"
  step::mutating || return 0
  local args=()
  ((${#add[@]})) && args+=(--add-config "$(core::join , "${add[@]}")")
  ((${#del[@]})) && args+=(--delete-config "$(core::join , "${del[@]}")")
  kafka::admin kafka-configs --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$(kafka::admin_config)" \
    --alter --entity-type users "$@" "${args[@]}" >/dev/null
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

  # client quotas (Kafka user quotas; REST apps share the principal through impersonation)
  for app in $APPS; do
    var="APP_QUOTA_$(core::varname "$app")"
    security::quota "User:$app" "${!var:-}" --entity-name "$app"
  done
  security::quota "user default" "${QUOTA_USER_DEFAULT:-}" --entity-default

  local t
  for t in $TOPICS; do security::topic "${t%%:*}" "${t#*:}"; done
}

step_verify() {
  kafka::admin kafka-topics --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$(kafka::admin_config)" \
    --describe --topic orders.events >/dev/null 2>&1
}
