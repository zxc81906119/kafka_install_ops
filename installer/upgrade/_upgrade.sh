#!/usr/bin/env bash
# cpctl upgrade <plan|backup|stage|rolling|finalize|rollback> --to <version> [--role R] [--yes]
# Order follows the CP 8.3 upgrade guide: brokers one at a time, then controllers one at a time,
# then REST Proxies (drained from the LB). C3 (>= 2.2) is versioned independently.
[[ -n ${_UPGRADE_LOADED:-} ]] && return 0
_UPGRADE_LOADED=1

core::load_env "$CONF_DIR/compat.env"
readonly UPG_DIR=$STATE_DIR/upgrade

upgrade::_mm() { printf '%s' "${1%.*}"; }
upgrade::_v() {
  local v
  v="$1_$(tr . _ <<<"$(upgrade::_mm "$2")")"
  printf "%s" "${!v:-}"
}

upgrade::_versions() { # prints "host role version"
  local h
  for h in $(inv::hosts broker); do printf '%s broker %s\n' "$h" "$(install::version "$h")"; done
  for h in $(inv::hosts controller); do printf '%s controller %s\n' "$h" "$(install::version "$h")"; done
  for h in $(inv::hosts rest); do printf '%s rest %s\n' "$h" "$(install::rest_version "$h")"; done
}

upgrade::_cluster_healthy() {
  local h
  for h in $(inv::hosts broker); do kafka::_broker_healthy "$h" || return 1; done
}

upgrade::_finalized_release() {
  kafka::admin kafka-features --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$(kafka::admin_config)" \
    describe 2>/dev/null | awk '/Feature: confluent.metadata.version/ {for (i=1;i<=NF;i++) if ($i=="FinalizedVersionLevel:") print $(i+1)}'
}

upgrade::plan() {
  local to=$1 from_mm to_mm ok=1 line h role v
  to_mm=$(upgrade::_mm "$to")
  log::step "---- upgrade plan to $to"
  local cur
  cur=$(upgrade::_versions)
  printf '%s\n' "$cur" | awk '{printf "    %-8s %-11s %s\n", $1, $2, $3}' >&2
  from_mm=$(awk '{print $3}' <<<"$cur" | sort -V | head -1 | cut -d. -f1,2)
  if [[ " $UPGRADE_PATHS " == *" $from_mm>$to_mm "* ]]; then log::ok "path $from_mm -> $to_mm is supported"
  else log::error "path $from_mm -> $to_mm is not in conf/compat.env UPGRADE_PATHS"; ok=0; fi
  local c3var
  c3var="C3_SUPPORTS_$(tr . _ <<<"$(upgrade::_mm "$C3_VERSION")")"
  if [[ " ${!c3var:-} " == *" $to_mm "* ]]; then log::ok "Control Center $C3_VERSION supports CP $to_mm"
  else log::error "Control Center $C3_VERSION does not list CP $to_mm"; ok=0; fi
  local jdkvar jmaj=${JDK_VERSION%%.*}
  jdkvar="JDK_SUPPORTS_$(tr . _ <<<"$to_mm")"
  if [[ " ${!jdkvar:-} " == *" $jmaj "* ]]; then log::ok "JDK $jmaj supported by CP $to_mm"
  else log::error "JDK $jmaj not supported by CP $to_mm"; ok=0; fi
  # target packages must already be in the internal repo
  if find "$REPO_LOCAL_ROOT/rpm/confluent" -name "confluent-server-$to-*.rpm" | grep -q .; then
    log::ok "confluent-server-$to present in the internal repo"
  else log::error "confluent-server-$to not in the internal repo (cpctl repo import first)"; ok=0; fi
  # forbidden static configs
  local forb
  forb=$(upgrade::_v FORBIDDEN_CONFIGS "$to")
  for h in $(inv::hosts broker) $(inv::hosts controller); do
    for v in $forb; do
      if remote::exec "$h" "sudo -n grep -q '^$v=' /etc/confluent/kafka/server.properties"; then
        log::error "[$h] static config $v must be removed before upgrading to $to_mm"; ok=0
      fi
    done
  done
  [[ $ok == 1 ]] && log::ok "no forbidden static configs"
  # cluster health and certificate lifetime
  if upgrade::_cluster_healthy; then log::ok "cluster healthy (all brokers registered, no URP)"
  else log::error "cluster not healthy - fix before upgrading"; ok=0; fi
  local days
  days=$(( ($(date -d "$(openssl x509 -enddate -noout -in "$PKI_DIR/cp-server.crt" | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
  ((days > 14)) && log::ok "server certificate valid for $days more days" || log::warn "server certificate expires in $days days"
  log::info "metadata release currently finalized: $(upgrade::_finalized_release)"
  log::info "order: brokers (one by one) -> controllers (followers first, leader last) -> REST (LB drain) ; finalize is a separate, irreversible command"
  [[ $ok == 1 ]]
}

upgrade::backup() {
  local to=$1 dir h
  dir="$UPG_DIR/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  for h in $(inv::hosts controller) $(inv::hosts broker) $(inv::hosts rest) $(inv::hosts c3); do
    remote::exec "$h" "sudo -n tar -czf - -C / etc/confluent etc/systemd/system 2>/dev/null" >"$dir/$h-etc.tgz"
    log::ok "[$h] /etc/confluent + systemd drop-ins saved"
  done
  local cfg
  cfg=$(kafka::admin_config)
  kafka::admin kafka-topics --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" --describe >"$dir/topics.txt" 2>/dev/null
  kafka::admin kafka-configs --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" --describe --entity-type users >"$dir/scram-users.txt" 2>/dev/null || true
  kafka::admin kafka-features --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" describe >"$dir/features.txt" 2>/dev/null
  kafka::admin kafka-acls --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$cfg" --list >"$dir/acls.txt" 2>/dev/null || true
  rbac::login
  local p
  for p in User:svc-c3 $(printf 'Group:%s ' $AD_GROUPS) $(printf 'User:%s ' $APPS); do
    rbac::bindings_json "$p" >"$dir/rbac-${p//:/_}.json"
  done
  cp "$STATE_DIR/kraft.env" "$dir/"
  printf '%s\n' "$to" >"$dir/target"
  ln -sfn "$dir" "$UPG_DIR/last-backup"
  log::ok "backup written to $dir"
}

upgrade::stage() {
  local to=$1 h
  find "$REPO_LOCAL_ROOT/rpm/confluent" -name "confluent-server-$to-*.rpm" | grep -q . ||
    core::die "$E_PRECHECK" "confluent-server-$to not in the internal repo"
  log::info "rendering configuration with templates for $(upgrade::_mm "$to") (check mode, nothing is pushed)"
  (
    export CPCTL_CHECK=1 CPCTL_DIFF=1 RENDER_VERSION=$to
    for h in $(inv::hosts broker) $(inv::hosts controller); do role::call "$(inv::roles "$h" | head -1)" configure "$h"; done
    for h in $(inv::hosts rest); do role::rest::configure "$h"; done
  )
  log::ok "staged: packages available, configuration diff shown above (no changes applied)"
}

# One host: stop -> package upgrade/downgrade -> re-render config -> start -> health gate
upgrade::host() { # <host> <role> <version>
  local h=$1 role=$2 ver=$3
  log::step "---- [$h] $role -> $ver"
  [[ $role == rest ]] && lb::drain "$h"
  role::call "$role" stop "$h"
  install::ensure "$h" upgrade "$ver" "$role"
  RENDER_VERSION=$ver role::call "$role" configure "$h"
  : >"$(handler::_file)"
  role::call "$role" start "$h"
  role::call "$role" health "$h" || core::die "$E_GATE" "[$h] failed its health gate after moving to $ver - stop here; rollback: cpctl upgrade rollback --to <previous>"
  [[ $role == rest ]] && lb::undrain
  return 0
}

upgrade::_controller_order() { # followers first, leader last
  local leader h
  leader=$(kafka::admin kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_BOOTSTRAP" --command-config "$(kafka::admin_config)" \
    describe --status 2>/dev/null | awk '/LeaderId:/ {print $2}')
  for h in $(inv::hosts controller); do [[ $(inv::get "$h" NODE_ID) != "$leader" ]] && printf '%s\n' "$h"; done
  for h in $(inv::hosts controller); do [[ $(inv::get "$h" NODE_ID) == "$leader" ]] && printf '%s\n' "$h"; done
  return 0
}

upgrade::rolling() { # <version> <role|all>
  local ver=$1 only=${2:-all} h cur
  role::common_vars
  upgrade::_cluster_healthy || core::die "$E_GATE" "cluster not healthy - refusing to start a rolling upgrade"
  if [[ $only == all || $only == broker ]]; then
    for h in $(inv::hosts broker); do
      cur=$(install::version "$h")
      if [[ $cur == "$ver" ]]; then log::ok "[$h] broker already at $ver"; continue; fi
      step::mutating && upgrade::host "$h" broker "$ver" || log::changed "[$h] would upgrade broker $cur -> $ver"
    done
  fi
  if [[ $only == all || $only == controller ]]; then
    for h in $(upgrade::_controller_order); do
      cur=$(install::version "$h")
      if [[ $cur == "$ver" ]]; then log::ok "[$h] controller already at $ver"; continue; fi
      step::mutating && upgrade::host "$h" controller "$ver" || log::changed "[$h] would upgrade controller $cur -> $ver"
    done
  fi
  if [[ $only == all || $only == rest ]]; then
    for h in $(inv::hosts rest); do
      cur=$(install::rest_version "$h")
      if [[ $cur == "$ver" ]]; then log::ok "[$h] REST Proxy already at $ver"; continue; fi
      step::mutating && upgrade::host "$h" rest "$ver" || log::changed "[$h] would upgrade REST Proxy $cur -> $ver"
    done
  fi
}

upgrade::finalize() { # <version> <yes>
  local ver=$1 yes=$2 rel cur h
  rel=$(upgrade::_v KAFKA_RELEASE "$ver")
  [[ -n $rel ]] || core::die "no KAFKA_RELEASE for $ver in conf/compat.env"
  for h in $(inv::hosts broker) $(inv::hosts controller); do
    [[ $(install::version "$h") == "$ver" ]] || core::die "$E_GATE" "[$h] is not at $ver yet - finish the rolling upgrade first"
  done
  [[ -f $UPG_DIR/last-backup/target && $(cat "$UPG_DIR/last-backup/target") == "$ver" ]] ||
    core::die "$E_GATE" "no backup taken for target $ver (run: cpctl upgrade backup --to $ver)"
  cur=$(upgrade::_finalized_release)
  log::info "metadata.version finalized now: $cur ; mapping for release $rel:"
  kafka::admin kafka-features --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$(kafka::admin_config)" \
    version-mapping --release-version "$rel" >&2
  if [[ $yes != 1 ]]; then
    core::load_env "$STATE_DIR/kraft.env"
    printf 'Finalizing makes the downgrade path to older versions unavailable.\nType the cluster id (%s) to continue: ' "$CLUSTER_ID" >&2
    local answer
    read -r answer
    [[ $answer == "$CLUSTER_ID" ]] || core::die "aborted"
  fi
  if ! step::mutating; then log::changed "would run kafka-features upgrade --release-version $rel"; return 0; fi
  kafka::admin kafka-features --bootstrap-server "$(kafka::bootstrap_internal)" --command-config "$(kafka::admin_config)" \
    upgrade --release-version "$rel"
  log::changed "metadata finalized: $cur -> $(upgrade::_finalized_release)"
}

upgrade::rollback() { # <previous version>
  local ver=$1 h
  role::common_vars
  local rel
  rel=$(upgrade::_v KAFKA_RELEASE "$ver")
  log::info "rollback target $ver (release $rel); finalized metadata is $(upgrade::_finalized_release)"
  # reverse order: REST, controllers, brokers
  for h in $(inv::hosts rest); do
    [[ $(install::rest_version "$h") == "$ver" ]] && { log::ok "[$h] REST already at $ver"; continue; }
    step::mutating && upgrade::host "$h" rest "$ver" || log::changed "[$h] would roll back REST to $ver"
  done
  for h in $(upgrade::_controller_order); do
    [[ $(install::version "$h") == "$ver" ]] && { log::ok "[$h] controller already at $ver"; continue; }
    step::mutating && upgrade::host "$h" controller "$ver" || log::changed "[$h] would roll back controller to $ver"
  done
  for h in $(inv::hosts broker); do
    [[ $(install::version "$h") == "$ver" ]] && { log::ok "[$h] broker already at $ver"; continue; }
    step::mutating && upgrade::host "$h" broker "$ver" || log::changed "[$h] would roll back broker to $ver"
  done
}

upgrade::main() {
  local sub=$1; shift || true
  local to="" role=all yes=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --to) to=$2; shift 2 ;;
      --role) role=$2; shift 2 ;;
      --yes) yes=1; shift ;;
      *) core::die "$E_USAGE" "unknown option $1" ;;
    esac
  done
  [[ -n $to ]] || core::die "$E_USAGE" "--to <version> is required"
  role::common_vars
  case $sub in
    plan) upgrade::plan "$to" ;;
    backup) upgrade::backup "$to" ;;
    stage) upgrade::stage "$to" ;;
    rolling) upgrade::rolling "$to" "$role" ;;
    finalize) upgrade::finalize "$to" "$yes" ;;
    rollback) upgrade::rollback "$to" ;;
    *) core::die "$E_USAGE" "unknown upgrade command: $sub" ;;
  esac
}
