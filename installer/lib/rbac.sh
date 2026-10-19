#!/usr/bin/env bash
# RBAC through the Confluent CLI (MDS), logged in with the svc-cpctl client certificate (no AD account).
# Idempotent: existing bindings are listed first; only missing ones are created.
[[ -n ${_LIB_RBAC_LOADED:-} ]] && return 0
_LIB_RBAC_LOADED=1

rbac::cli() { HOME=$STATE_DIR/cli-home /usr/bin/confluent "$@"; }

rbac::login() {
  mkdir -p "$STATE_DIR/cli-home"
  local url
  url="https://$(inv::fqdn "$(inv::hosts broker | head -1)"):$PORT_MDS"
  rbac::cli login --url "$url" --certificate-authority-path "$PKI_DIR/ca.pem" --certificate-only \
    --client-cert-path "$PKI_DIR/svc-cpctl.crt" --client-key-path "$PKI_DIR/svc-cpctl.key" >/dev/null ||
    core::die "MDS login with the svc-cpctl certificate failed ($url)"
  log::ok "logged in to MDS $url as svc-cpctl (client certificate)"
}

rbac::cluster_id() { core::load_env "$STATE_DIR/kraft.env"; printf '%s' "$CLUSTER_ID"; }

# rbac::bindings_json <principal>  -> JSON array of existing bindings on the Kafka cluster
rbac::bindings_json() {
  rbac::cli iam rbac role-binding list --principal "$1" --kafka-cluster "$(rbac::cluster_id)" -o json 2>/dev/null || echo '[]'
}

# rbac::ensure <principal> <binding spec>
#   spec: <Role>  |  <Role>:<ResourceType>:<Name>:<LITERAL|PREFIXED>
rbac::ensure() {
  local principal=$1 spec=$2 role rtype="" name="" pattern="" json have
  IFS=: read -r role rtype name pattern <<<"$spec"
  json=$(rbac::bindings_json "$principal")
  if [[ -z $rtype ]]; then
    have=$(jq -r --arg r "$role" '[.[] | select(.role == $r and ((.resource_type // "") == "" or .resource_type == "Cluster"))] | length' <<<"$json" 2>/dev/null || echo 0)
  else
    have=$(jq -r --arg r "$role" --arg t "$rtype" --arg n "$name" --arg p "${pattern:-LITERAL}" \
      '[.[] | select(.role == $r and .resource_type == $t and .name == $n and ((.pattern_type // "LITERAL") == $p))] | length' <<<"$json" 2>/dev/null || echo 0)
  fi
  if [[ ${have:-0} -gt 0 ]]; then
    log::ok "rbac $principal $spec"
    return 0
  fi
  log::changed "rbac $principal $spec"
  step::mutating || return 0
  local args=(iam rbac role-binding create --principal "$principal" --role "$role" --kafka-cluster "$(rbac::cluster_id)")
  if [[ -n $rtype ]]; then
    args+=(--resource "$rtype:$name")
    [[ $pattern == PREFIXED ]] && args+=(--prefix)
  fi
  rbac::cli "${args[@]}" >/dev/null
}
