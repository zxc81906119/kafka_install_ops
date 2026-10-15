#!/usr/bin/env bash
# License status: the effective license is a JWT. Source = conf/license.txt if present, otherwise the
# (trial) license the brokers stored in the _confluent-command topic. Trial = 30 days; when it expires
# Confluent Server keeps running with errors, but security plugins (RBAC/MDS) and C3 fail at restart.
[[ -n ${_LIB_LICENSE_LOADED:-} ]] && return 0
_LIB_LICENSE_LOADED=1

readonly LICENSE_WARN_DAYS=${LICENSE_WARN_DAYS:-30}

license::_jwt() {
  if [[ -s $CONF_DIR/license.txt ]]; then
    tr -d '[:space:]' <"$CONF_DIR/license.txt"
    return 0
  fi
  KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS="$(install::tools_opts)" JAVA_HOME="$(install::java_home)" \
    timeout 60 "$(install::bin kafka-console-consumer)" --bootstrap-server "$(kafka::bootstrap_internal)" \
    --consumer.config "$(kafka::admin_config)" --topic _confluent-command --from-beginning --timeout-ms 20000 2>/dev/null |
    grep -a -o 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' | tail -1
}

# license::claims -> JSON payload of the JWT (not validated here; the brokers validate the signature)
license::claims() {
  local jwt p
  jwt=$(license::_jwt)
  [[ -n $jwt ]] || return 1
  p=$(cut -d. -f2 <<<"$jwt" | tr '_-' '/+')
  while ((${#p} % 4)); do p+='='; done
  base64 -d <<<"$p" 2>/dev/null
}

# license::status -> logs type / expiry / days left; returns 1 when expired, 2 when expiring soon
license::status() {
  local c type exp days src
  src=$([[ -s $CONF_DIR/license.txt ]] && echo "conf/license.txt" || echo "_confluent-command topic")
  c=$(license::claims) || { log::error "no license found (neither conf/license.txt nor a trial in _confluent-command)"; return 1; }
  type=$(jq -r '.licenseType // .aud // "unknown"' <<<"$c")
  exp=$(jq -r '.exp' <<<"$c")
  days=$(((exp - $(date +%s)) / 86400))
  if ((days < 0)); then
    log::error "license ($type, from $src) EXPIRED on $(date -d "@$exp" +%F)"
    return 1
  elif ((days < LICENSE_WARN_DAYS)); then
    log::warn "license ($type, from $src) expires $(date -d "@$exp" +%F): $days day(s) left"
    return 2
  fi
  log::ok "license ($type, from $src) valid until $(date -d "@$exp" +%F) ($days days)"
}
