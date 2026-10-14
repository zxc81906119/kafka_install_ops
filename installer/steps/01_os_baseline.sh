# shellcheck shell=bash
# shellcheck disable=SC2206  # sysctl lists are intentionally word-split
STEP_DESC="OS baseline: sysctl, limits, journald, timezone (values from conf/os-tuning.env)"

step_inputs() { cat "$CONF_DIR/os-tuning.env"; inv::all_hosts; inv::hosts controller_spare; }

os::baseline_host() {
  local h=$1 roles kv k v
  roles=$(inv::roles "$h" | paste -sd' ' -)
  # kernel parameters per role
  local list=()
  case " $roles " in *" controller "* | *" broker "*) list+=($SYSCTL_KAFKA) ;; esac
  case " $roles " in *" broker "*) list+=($SYSCTL_BROKER) ;; esac
  list+=($SYSCTL_ALL)
  for kv in "${list[@]}"; do
    k=${kv%%=*}; v=${kv#*=}
    remote::apply "$h" ensure::sysctl "$k" "${v//,/ }" /etc/sysctl.d/90-confluent.conf
  done
  # process limits (systemd units also set LimitNOFILE through our drop-ins)
  local t
  t=$(render::tmp)
  printf '# Managed by cpctl\n@confluent soft nofile %s\n@confluent hard nofile %s\n@confluent soft nproc %s\n@confluent hard nproc %s\n' \
    "$LIMIT_NOFILE" "$LIMIT_NOFILE" "$LIMIT_NPROC" "$LIMIT_NPROC" >"$t"
  remote::put "$h" "$t" /etc/security/limits.d/90-confluent.conf root root 0644
  printf '# Managed by cpctl\n[Journal]\nSystemMaxUse=%s\n' "$JOURNAL_MAX_USE" >"$t"
  remote::apply "$h" ensure::dir /etc/systemd/journald.conf.d root root 0755
  remote::put "$h" "$t" /etc/systemd/journald.conf.d/90-confluent.conf root root 0644
  rm -f "$t"
  remote::apply "$h" ensure::symlink "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  remote::apply "$h" ensure::dir /etc/confluent root root 0755
}

step_apply() {
  core::load_env "$CONF_DIR/os-tuning.env"
  local h
  for h in $(inv::hosts ops) $(inv::hosts controller) $(inv::hosts broker) $(inv::hosts rest) $(inv::hosts c3); do
    os::baseline_host "$h"
  done
}
