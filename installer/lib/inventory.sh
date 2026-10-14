#!/usr/bin/env bash
# Repository over conf/inventory.env. Callers never read inventory variables directly.
[[ -n ${_LIB_INV_LOADED:-} ]] && return 0
_LIB_INV_LOADED=1

inv::load() {
  core::load_env "$CONF_DIR/inventory.env"
  core::load_env "$CONF_DIR/versions.env"
  core::load_env "$CONF_DIR/apps.env"
  [[ -f $CONF_DIR/secrets.env ]] && core::load_env "$CONF_DIR/secrets.env"
  return 0
}

# inv::hosts <role>   -> one host per line
inv::hosts() {
  local var
  var="HOSTS_$(core::varname "$1")"
  local h
  for h in ${!var:-}; do printf '%s\n' "$h"; done
}

# inv::roles <host>   -> roles the host belongs to
inv::roles() {
  local host=$1 role
  for role in controller broker rest c3 lb ad ops controller_spare; do
    inv::hosts "$role" | grep -qx "$host" && printf '%s\n' "$role"
  done
  return 0
}

inv::get() { # <host> <KEY> [default]
  local var
  var="HOST_$(core::varname "$1")_$2"
  if [[ -n ${!var:-} ]]; then printf '%s' "${!var}"; else printf '%s' "${3:-}"; fi
}

inv::fqdn() { printf '%s.%s' "$1" "$DOMAIN"; }

inv::all_hosts() {
  local r
  for r in ops ad lb controller broker rest c3; do inv::hosts "$r"; done | awk '!seen[$0]++'
}

inv::heap() { local v="HEAP_${PROFILE}_$1"; printf '%s' "${!v}"; }

# Comma separated list "<fqdn>:<port>" for a role.
inv::endpoints() { # <role> <port> [scheme]
  local role=$1 port=$2 scheme=${3:-} h out=()
  while IFS= read -r h; do out+=("${scheme:+$scheme://}$(inv::fqdn "$h"):$port"); done < <(inv::hosts "$role")
  core::join , "${out[@]}"
}

inv::secret() { # <NAME>  (fails if missing so we never run with an empty password)
  local v=$1
  [[ -n ${!v:-} ]] || core::die "$E_PRECHECK" "secret $v is not set in conf/secrets.env"
  printf '%s' "${!v}"
}

# inv::apps <scram|rest>  -> apps using that access channel (conf/apps.env APP_CHANNEL_<app>)
inv::apps() {
  local app var
  for app in $APPS; do
    var="APP_CHANNEL_$(core::varname "$app")"
    [[ ${!var:-scram} == "$1" ]] && printf '%s\n' "$app"
  done
  return 0
}

inv::app_secret_var() { printf 'APP_%s_PASSWORD' "$(tr 'a-z-' 'A-Z_' <<<"$1")"; }
