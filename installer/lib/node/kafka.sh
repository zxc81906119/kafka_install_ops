# Node-side helpers for Confluent Server (controller / broker). Run as root unless noted.

readonly KAFKA_DATA=/var/lib/kafka/data

# kafka_node::meta <key>  -> value from meta.properties (empty if not formatted)
kafka_node::meta() { sed -n "s/^$1=//p" "$KAFKA_DATA/meta.properties" 2>/dev/null || true; }

# kafka_node::format <cluster id> <config> <java home> <bin dir> <kafka etc dir> <format args...>
# Runs kafka-storage format as cp-kafka once. Already formatted with the same cluster id -> ok;
# formatted with a different cluster id -> error (never reformat a node silently).
kafka_node::format() {
  local cid=$1 cfg=$2 jh=$3 bindir=$4 etc=$5; shift 5
  local have
  have=$(kafka_node::meta cluster.id)
  if [[ -n $have ]]; then
    if [[ $have == "$cid" ]]; then _mark ok "storage formatted (cluster.id=$cid)"; return 0; fi
    _mark warn "storage belongs to cluster $have, expected $cid - refusing to reformat"
    return 3
  fi
  _mark changed "kafka-storage format (cluster.id=$cid)"
  [[ ${CPCTL_CHECK:-0} == 1 ]] && return 0
  install -d -o cp-kafka -g confluent -m 0750 "$KAFKA_DATA"
  sudo -u cp-kafka env JAVA_HOME="$jh" KAFKA_HEAP_OPTS=-Xmx256m \
    KAFKA_OPTS="-Dlog4j2.configurationFile=$etc/tools-log4j2.yaml" \
    "$bindir/kafka-storage" format --cluster-id "$cid" --config "$cfg" "$@" | grep -v -i scram || true
  [[ -f $KAFKA_DATA/meta.properties ]] || { _mark warn "format did not create meta.properties"; return 1; }
}

# kafka_node::wipe  (uninstall / drill helper) - removes data dir content
kafka_node::wipe() {
  if [[ ! -d $KAFKA_DATA ]] || [[ -z $(ls -A "$KAFKA_DATA" 2>/dev/null) ]]; then _mark ok "data dir empty"; return 0; fi
  _mark changed "wipe $KAFKA_DATA"
  [[ ${CPCTL_CHECK:-0} == 1 ]] || rm -rf "${KAFKA_DATA:?}"/*
}

# java_node::trust_ca <java home> <ca pem> <storepass>
# Imports the internal CA into the JDK default truststore (lets components that build their own
# HTTPS/LDAPS clients trust internal endpoints without passing truststore passwords on the command line).
java_node::trust_ca() {
  local jh=$1 ca=$2 cacerts
  cacerts=$(readlink -f "$jh/lib/security/cacerts")
  if "$jh/bin/keytool" -list -cacerts -storepass changeit -alias cp-internal-ca >/dev/null 2>&1; then
    _mark ok "JDK truststore has internal CA ($cacerts)"
    return 0
  fi
  _mark changed "import internal CA into JDK truststore ($cacerts)"
  [[ ${CPCTL_CHECK:-0} == 1 ]] && return 0
  "$jh/bin/keytool" -importcert -noprompt -cacerts -storepass changeit -alias cp-internal-ca -file "$ca" >/dev/null
}
