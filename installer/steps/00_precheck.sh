# shellcheck shell=bash
STEP_DESC="pre-flight checks: inventory, secrets, SSH, OS facts, DNS, clock, internal repo"

step_inputs() { cat "$CONF_DIR/inventory.env" "$CONF_DIR/apps.env"; }

precheck::inventory() {
  local ids dup s
  ids=$(for h in $(inv::hosts controller) $(inv::hosts controller_spare) $(inv::hosts broker); do inv::get "$h" NODE_ID; done)
  dup=$(sort <<<"$ids" | uniq -d)
  [[ -z $dup ]] || core::die "$E_PRECHECK" "duplicate node ids in inventory: $dup"
  [[ $(inv::hosts controller | wc -l) -ge 3 && $(($(inv::hosts controller | wc -l) % 2)) -eq 1 ]] ||
    core::die "$E_PRECHECK" "need an odd number (>=3) of controllers"
  [[ $(inv::hosts broker | wc -l) -ge 3 ]] || core::die "$E_PRECHECK" "need >= 3 brokers for RF=3 / min.insync=2"
  log::ok "inventory: $(inv::hosts controller | wc -l) controllers, $(inv::hosts broker | wc -l) brokers, $(inv::hosts rest | wc -l) REST, $(inv::hosts c3 | wc -l) C3"
  for s in AD_ADMIN_PASSWORD LDAP_BIND_PASSWORD SVC_REST_PASSWORD SVC_C3_PASSWORD SVC_CPCTL_PASSWORD KAFKA_ADMIN_PASSWORD STORE_PASSWORD; do
    inv::secret "$s" >/dev/null
  done
  for s in $(inv::apps scram); do inv::secret "$(inv::app_secret_var "$s")" >/dev/null; done
  log::ok "secrets present for all service accounts and apps"
}

precheck::host() {
  local h=$1 facts os tmpfree tmpnx skew
  if ! remote::reachable "$h"; then log::error "[$h] SSH as $SSH_USER failed"; return 1; fi
  facts=$(remote::run "$h" node::facts) || { log::error "[$h] cannot collect facts (sudo?)"; return 1; }
  os=$(sed -n 's/^os=//p' <<<"$facts")
  tmpfree=$(sed -n 's/^tmp_free_mb=//p' <<<"$facts")
  tmpnx=$(sed -n 's/^tmp_noexec=//p' <<<"$facts")
  skew=$(($(sed -n 's/^time_epoch=//p' <<<"$facts") - $(date +%s)))
  case $(inv::roles "$h" | head -1) in
    lb | ad) log::ok "[$h] reachable (appliance: $os)" ; return 0 ;;
  esac
  [[ $os =~ ^(rhel|rocky|almalinux|ol)-9 ]] && log::ok "[$h] OS $os" || log::warn "[$h] OS $os is not a RHEL 9 family release"
  [[ $tmpnx == no ]] && log::ok "[$h] /tmp is exec" || log::error "[$h] /tmp is mounted noexec (Confluent requires exec)"
  ((tmpfree >= 2000)) && log::ok "[$h] /tmp free ${tmpfree}MB" || log::warn "[$h] /tmp free ${tmpfree}MB < 2GB"
  ((${skew#-} <= 2)) && log::ok "[$h] clock skew ${skew}s" || log::error "[$h] clock skew ${skew}s (TLS/MDS tokens need < 2s)"
  local other fq
  for other in $(inv::all_hosts); do
    fq=$(inv::fqdn "$other")
    remote::exec "$h" "getent hosts $fq >/dev/null" || { log::error "[$h] cannot resolve $fq"; return 1; }
  done
  log::ok "[$h] resolves all cluster FQDNs; facts: $(grep -E '^(cpus|mem_mb|container|systemd)=' <<<"$facts" | paste -sd' ' -)"
}

step_apply() {
  core::require_cmd ssh scp openssl curl sha256sum envsubst flock
  precheck::inventory
  local h failed=0
  for h in $(inv::all_hosts); do precheck::host "$h" || failed=1; done
  [[ $failed == 0 ]] || core::die "$E_PRECHECK" "pre-flight failed (see errors above)"
  repo::verify || core::die "$E_PRECHECK" "internal repo not ready - run: cpctl repo import"
}

step_verify() { repo::verify >/dev/null; }
