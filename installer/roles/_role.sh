#!/usr/bin/env bash
# Role registry (Strategy). Every role implements the same interface:
#   role::<r>::configure <host>   render + push config; notify handler on change
#   role::<r>::start <host>       enable + start (no-op if running)
#   role::<r>::restart <host>
#   role::<r>::stop <host>
#   role::<r>::health <host>      gate used by rolling restarts / upgrades
[[ -n ${_ROLE_LOADED:-} ]] && return 0
_ROLE_LOADED=1

role::call() { # <role> <action> <host>
  local fn="role::$1::$2"
  declare -F "$fn" >/dev/null || core::die "role $1 does not implement $2"
  "$fn" "$3"
}

# Values shared by templates of several roles (exported for render::to).
role::common_vars() {
  export CONTROLLER_BOOTSTRAP MDS_URLS TOKEN_BOOTSTRAP BROKER_INTERNAL_BOOTSTRAP C3_FQDN AD_FQDN LDAP_BIND_DN LICENSE_LINE \
    SUPER_USERS IMPERSONATION_SUPER_USERS IMPERSONATION_PROTECTED_USERS REST_PRINCIPAL_RULES CLUSTER_NAME C3_DOCS_HOST
  CONTROLLER_BOOTSTRAP=$(inv::endpoints controller "$PORT_CONTROLLER")
  MDS_URLS=$(inv::endpoints broker "$PORT_MDS" https)
  TOKEN_BOOTSTRAP=$(inv::endpoints broker "$PORT_TOKEN")
  BROKER_INTERNAL_BOOTSTRAP=$(inv::endpoints broker "$PORT_INTERNAL")
  C3_FQDN=$(inv::fqdn "$(inv::hosts c3 | head -1)")
  AD_FQDN=$(inv::fqdn "$AD_HOST")
  LDAP_BIND_DN="CN=svc-mds-bind,OU=Service,$AD_OU"
  # kafka-internal: brokers/controllers; kafka-admin: SCRAM break-glass; svc-cpctl: AD installer account (RBAC bootstrap)
  SUPER_USERS="User:kafka-internal;User:kafka-admin;User:svc-cpctl"
  IMPERSONATION_SUPER_USERS="User:svc-rest"
  IMPERSONATION_PROTECTED_USERS=$(role::protected_users)
  REST_PRINCIPAL_RULES=$(role::rest_principal_rules)
  CLUSTER_NAME=poc-cluster
  C3_DOCS_HOST=docs.confluent.io
  if [[ -s $CONF_DIR/license.txt ]]; then
    LICENSE_LINE="confluent.license=$(tr -d '[:space:]' <"$CONF_DIR/license.txt")"
  else
    LICENSE_LINE="# confluent.license not set: evaluation mode (conf/license.txt is empty)"
  fi
  export STORE_PASSWORD LDAP_BIND_PASSWORD SVC_REST_PASSWORD SVC_C3_PASSWORD
  export AD_OU PORT_CONTROLLER PORT_INTERNAL PORT_TOKEN PORT_CLIENT PORT_LDAP PORT_MDS PORT_REST PORT_C3 \
    PORT_PROMETHEUS PORT_ALERTMANAGER LB_REST_NAME
}

# Never-impersonate list, derived (not hand-maintained): every super user + every AD service account.
role::protected_users() {
  local p out=() svc
  IFS=';' read -ra out <<<"$SUPER_USERS"
  for svc in $AD_SERVICE_ACCOUNTS; do
    p="User:$svc"
    printf '%s\n' "${out[@]}" | grep -qxF "$p" || out+=("$p")
  done
  core::join ';' "${out[@]}"
}

# REST Proxy accepts only legacy apps (APP_CHANNEL_<app>=rest): one rule matching exactly those CNs and
# deliberately NO ",DEFAULT" fallback - any other certificate (servers, humans, SCRAM apps) fails mapping.
role::rest_principal_rules() {
  local apps
  apps=$(inv::apps rest | paste -sd'|' -)
  [[ -n $apps ]] || core::die "$E_PRECHECK" "no app with APP_CHANNEL=rest in conf/apps.env, but REST Proxy hosts are defined"
  # exact CN match without a comma (rules are a comma-separated list): CN=app-x-evil does not match app-x
  printf 'RULE:.*CN=(%s)([^a-zA-Z0-9._-].*)?$/$1/' "$apps"
}

# role::render_block <fragment template>  -> rendered text on stdout
role::render_block() {
  local t
  t=$(render::tmp)
  render::to "fragments/$1" "$t"
  cat "$t"
  rm -f "$t"
}

# role::push_ssl <host> <file...>   from $PKI_DIR to /etc/confluent/ssl (root:confluent 0640)
role::push_ssl() {
  local host=$1; shift
  remote::apply "$host" ensure::dir /etc/confluent root root 0755
  remote::apply "$host" ensure::dir /etc/confluent/ssl root confluent 0750
  local f changed=0
  for f in "$@"; do
    remote::put "$host" "$PKI_DIR/$f" "/etc/confluent/ssl/$f" root confluent 0640
    [[ $REMOTE_CHANGED == 1 ]] && changed=1
  done
  REMOTE_CHANGED=$changed
}

# role::push_rendered <host> <template> <dest> <owner> <group> <mode>   -> REMOTE_CHANGED
role::push_rendered() {
  local host=$1 tpl=$2 dst=$3 o=$4 g=$5 m=$6 t
  t=$(render::tmp)
  render::to "$tpl" "$t"
  remote::put "$host" "$t" "$dst" "$o" "$g" "$m"
  rm -f "$t"
}

# role::systemd_dropin <host> <unit> <template>   (exports UNIT for the template)
role::systemd_dropin() {
  local host=$1 unit=$2 tpl=$3
  export UNIT=$unit
  remote::apply "$host" ensure::dir "/etc/systemd/system/$unit.service.d" root root 0755
  role::push_rendered "$host" "systemd/$tpl" "/etc/systemd/system/$unit.service.d/10-cpctl.conf" root root 0644
  if [[ $REMOTE_CHANGED == 1 ]]; then
    remote::run "$host" svc::daemon_reload
    REMOTE_CHANGED=1
  fi
}

role::svc_start() { # <host> <unit>
  remote::apply "$1" svc::enable "$2"
  remote::apply "$1" svc::start "$2"
}
