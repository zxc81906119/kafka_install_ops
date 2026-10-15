# shellcheck shell=bash
# shellcheck disable=SC2206  # sysctl lists are intentionally word-split
STEP_DESC="OS baseline: sysctl, limits, journald, timezone, THP, chrony, firewalld, SELinux (conf/os-tuning.env)"

step_inputs() { cat "$CONF_DIR/os-tuning.env" "$CONF_DIR/inventory.env"; inv::all_hosts; inv::hosts controller_spare; }

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
  # log retention: rolled log files older than LOG_RETENTION_DAYS are deleted by the daily tmpfiles timer
  t=$(render::tmp)
  {
    printf '# Managed by cpctl - delete rolled Confluent logs after %s days (systemd-tmpfiles-clean.timer)\n' "$LOG_RETENTION_DAYS"
    for d in $LOG_DIRS; do printf 'e %s - - - %sd\n' "$d" "$LOG_RETENTION_DAYS"; done
  } >"$t"
  remote::put "$h" "$t" /etc/tmpfiles.d/90-confluent-logs.conf root root 0644
  rm -f "$t"
  remote::apply "$h" svc::enable systemd-tmpfiles-clean.timer
  remote::apply "$h" ensure::dir /etc/confluent root root 0755
  os::services_host "$h" "$roles"
}

# tcp ports a host must accept, derived from its roles (+ FIREWALL_EXTRA_<role>)
os::fw_ports() { # <roles>
  local roles=" $1 " out=() r var
  case $roles in *" controller "*) out+=("$PORT_CONTROLLER" "$PORT_JMX_EXPORTER") ;; esac
  case $roles in *" broker "*) out+=("$PORT_INTERNAL" "$PORT_TOKEN" "$PORT_CLIENT" "$PORT_LDAP" "$PORT_MDS" "$PORT_JMX_EXPORTER") ;; esac
  case $roles in *" rest "*) out+=("$PORT_REST" "$PORT_JMX_EXPORTER") ;; esac
  case $roles in *" c3 "*) out+=("$PORT_C3" "$PORT_PROMETHEUS") ;; esac
  for r in $1; do var="FIREWALL_EXTRA_$(core::varname "$r")"; out+=(${!var:-}); done
  printf '%s\n' "${out[@]}" | sort -un | paste -sd' ' -
}

# THP, chrony, firewalld, SELinux - packages from the internal os-deps mirror only
os::services_host() {
  local h=$1 roles=$2 t s fqdn
  fqdn=$(inv::fqdn "$h")
  install::prepare "$h"   # internal repo definition (also done by step 02; idempotent)
  remote::apply "$h" os_node::pkgs $PKGS_OS_BASELINE

  # transparent hugepages (controllers / brokers)
  case " $roles " in *" controller "* | *" broker "*)
    t=$(render::tmp)
    cat >"$t" <<EOF
# Managed by cpctl - Kafka recommends transparent hugepages = $THP_MODE
[Unit]
Description=Disable transparent hugepages (Confluent Platform)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=confluent-server.service
ConditionVirtualization=!container

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo $THP_MODE > /sys/kernel/mm/transparent_hugepage/enabled; echo $THP_MODE > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
    remote::put "$h" "$t" /etc/systemd/system/disable-thp.service root root 0644
    rm -f "$t"
    [[ $REMOTE_CHANGED == 1 ]] && remote::run "$h" svc::daemon_reload
    remote::apply "$h" svc::enable disable-thp.service
    remote::apply "$h" os_node::thp_report
    ;;
  esac

  # time sync
  t=$(render::tmp)
  {
    printf '# Managed by cpctl\n'
    for s in $NTP_SERVERS; do [[ $s == "$fqdn" ]] || printf 'server %s iburst\n' "$s"; done
    printf 'driftfile /var/lib/chrony/drift\nmakestep 1.0 3\nrtcsync\nlogdir /var/log/chrony\n'
    if [[ " $NTP_SERVERS " == *" $fqdn "* ]]; then printf 'allow %s\nlocal stratum 10\n' "$NTP_SERVER_ALLOW"; fi
  } >"$t"
  remote::put "$h" "$t" /etc/chrony.conf root root 0644; local chg=$REMOTE_CHANGED
  # containers share the host clock: -x = follow and report, never step/slew it
  remote::exec "$h" 'test -f /.dockerenv || systemd-detect-virt -c -q' && printf 'OPTIONS="-F 2 -x"\n' >"$t" || printf 'OPTIONS="-F 2"\n' >"$t"
  remote::put "$h" "$t" /etc/sysconfig/chronyd root root 0644; [[ $REMOTE_CHANGED == 1 ]] && chg=1
  rm -f "$t"
  remote::apply "$h" svc::enable chronyd
  if [[ $chg == 1 ]] && step::mutating; then remote::apply "$h" svc::restart chronyd; else remote::apply "$h" svc::start chronyd; fi

  # host firewall
  if [[ $FIREWALLD == on ]]; then
    local ports
    ports=$(os::fw_ports "$roles")
    [[ " $NTP_SERVERS " == *" $fqdn "* ]] && ports+=" 123/udp"
    # shellcheck disable=SC2086
    remote::apply "$h" os_node::firewall "--remove=${FIREWALL_REMOVE_SERVICES// /,}" $ports
  fi

  # shellcheck disable=SC2086
  remote::apply "$h" os_node::selinux "$SELINUX_MODE" $SELINUX_PATHS
}

# second pass: chrony needs a few seconds after (re)start before a source is selected
os::time_report() {
  local h
  for h in "$@"; do remote::apply "$h" os_node::chrony_sync; done
}

step_apply() {
  core::load_env "$CONF_DIR/os-tuning.env"
  local h
  local hosts
  hosts=$({ inv::hosts ops; inv::hosts controller; inv::hosts broker; inv::hosts rest; inv::hosts c3; })
  for h in $hosts; do
    os::baseline_host "$h"
  done
  # shellcheck disable=SC2086
  os::time_report $hosts
}
