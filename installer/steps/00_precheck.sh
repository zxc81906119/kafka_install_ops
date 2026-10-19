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
  for s in AD_ADMIN_PASSWORD LDAP_BIND_PASSWORD KAFKA_ADMIN_PASSWORD STORE_PASSWORD SECRET_MASTER_PASSPHRASE MDS_TOKEN_PASSPHRASE; do
    inv::secret "$s" >/dev/null
  done
  for s in $(inv::apps scram); do inv::secret "$(inv::app_secret_var "$s")" >/dev/null; done
  log::ok "secrets present for all service accounts and apps"
}

precheck::host() {
  local h=$1 facts os tmpfree tmpnx skew rc=0
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
  # blocking: Confluent cannot run with noexec /tmp, and TLS / MDS tokens fail with clock skew
  if [[ $tmpnx == no ]]; then log::ok "[$h] /tmp is exec"; else log::error "[$h] /tmp is mounted noexec (Confluent requires exec)"; rc=1; fi
  ((tmpfree >= 2000)) && log::ok "[$h] /tmp free ${tmpfree}MB" || log::warn "[$h] /tmp free ${tmpfree}MB < 2GB"
  if ((${skew#-} <= 2)); then log::ok "[$h] clock skew ${skew}s"; else log::error "[$h] clock skew ${skew}s (TLS/MDS tokens need < 2s)"; rc=1; fi
  local other fq
  for other in $(inv::all_hosts); do
    fq=$(inv::fqdn "$other")
    remote::exec "$h" "getent hosts $fq >/dev/null" || { log::error "[$h] cannot resolve $fq"; return 1; }
  done
  log::ok "[$h] resolves all cluster FQDNs; facts: $(grep -E '^(cpus|mem_mb|container|systemd)=' <<<"$facts" | paste -sd' ' -)"
  return "$rc"
}

step_apply() {
  core::require_cmd ssh scp openssl curl sha256sum envsubst flock
  precheck::inventory
  local h failed=0
  for h in $(inv::all_hosts); do precheck::host "$h" || failed=1; done
  [[ $failed == 0 ]] || core::die "$E_PRECHECK" "pre-flight failed (see errors above)"
  repo::verify || core::die "$E_PRECHECK" "internal repo not ready - run: cpctl repo import"
  if repo::remote_web; then
    repo::verify_served || core::die "$E_PRECHECK" "internal repo not served by $REPO_WEB_HOST - run: cpctl repo push"
  fi
}

step_verify() { repo::verify >/dev/null; }
