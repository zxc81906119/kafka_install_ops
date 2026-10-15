# shellcheck shell=bash
# shellcheck disable=SC2046  # host names from the inventory never contain whitespace
STEP_DESC="KRaft storage format: dynamic quorum (--initial-controllers), SCRAM bootstrap admin"

readonly KRAFT_ENV=$STATE_DIR/kraft.env

# Cluster id + one directory id per controller, generated once and reused forever (idempotency).
kraft::ids() {
  if [[ ! -f $KRAFT_ENV ]]; then
    step::mutating || { log::changed "would generate cluster id and controller directory ids"; return 0; }
    {
      printf 'CLUSTER_ID=%s\n' "$(kafka::admin kafka-storage random-uuid)"
      local h
      for h in $(inv::hosts controller) $(inv::hosts controller_spare); do
        printf 'DIR_ID_%s=%s\n' "$(core::varname "$h")" "$(kafka::admin kafka-storage random-uuid)"
      done
    } >"$KRAFT_ENV"
    chmod 0600 "$KRAFT_ENV"
    log::changed "generated cluster id and controller directory ids ($KRAFT_ENV)"
  fi
  core::load_env "$KRAFT_ENV"
}

kraft::initial_controllers() {
  local h out=() id dir
  for h in $(inv::hosts controller); do
    id=$(inv::get "$h" NODE_ID)
    dir="DIR_ID_$(core::varname "$h")"
    out+=("$id@$(inv::fqdn "$h"):$PORT_CONTROLLER:${!dir}")
  done
  core::join , "${out[@]}"
}

kraft::format_controller() {
  remote::apply "$1" kafka_node::format "$CLUSTER_ID" "$KAFKA_CONF" "$(install::java_home)" "$(install::bin_dir)" "$(install::kafka_etc)" \
    --initial-controllers "$(kraft::initial_controllers)" \
    --add-scram "SCRAM-SHA-512=[name=kafka-admin,password=$(inv::secret KAFKA_ADMIN_PASSWORD)]" \
    --add-scram "SCRAM-SHA-512=[name=$AUDIT_PRINCIPAL,password=$(inv::secret AUDIT_PASSWORD)]"
}

kraft::format_broker() {
  remote::apply "$1" kafka_node::format "$CLUSTER_ID" "$KAFKA_CONF" "$(install::java_home)" "$(install::bin_dir)" "$(install::kafka_etc)" --no-initial-controllers
}

step_apply() {
  kraft::ids
  [[ -n ${CLUSTER_ID:-} ]] || return 0
  log::info "cluster.id=$CLUSTER_ID  initial controllers=$(kraft::initial_controllers)"
  remote::parallel kraft::format_controller $(inv::hosts controller)
  remote::parallel kraft::format_broker $(inv::hosts broker)
}

step_verify() {
  core::load_env "$KRAFT_ENV"
  local h
  for h in $(inv::hosts controller) $(inv::hosts broker); do
    [[ $(remote::run "$h" kafka_node::meta cluster.id) == "$CLUSTER_ID" ]] || return 1
  done
}
