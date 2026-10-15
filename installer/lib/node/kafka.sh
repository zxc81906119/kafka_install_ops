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
  # Secret Protection: the config holds ${securepass:...} references -> the tool needs the master key too
  local mk=""
  [[ -f /etc/confluent/kafka/service.env ]] && mk=$(sed -n 's/^CONFLUENT_SECURITY_MASTER_KEY=//p' /etc/confluent/kafka/service.env)
  sudo -u cp-kafka env JAVA_HOME="$jh" KAFKA_HEAP_OPTS=-Xmx256m ${mk:+CONFLUENT_SECURITY_MASTER_KEY="$mk"} \
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
# The file may be a BUNDLE (CA rotation): every CA gets alias cp-ca-<fingerprint>, stale cp-ca-* aliases
# (and the legacy cp-internal-ca alias) are removed, so the JDK trusts exactly the bundle.
java_node::trust_ca() {
  local jh=$1 bundle=$2 cacerts kt d f fp alias want=() have
  kt=("$jh/bin/keytool" -cacerts -storepass changeit)
  cacerts=$(readlink -f "$jh/lib/security/cacerts")
  d=$(mktemp -d)
  awk -v d="$d" '/BEGIN CERTIFICATE/ {n++} {print > (d "/ca-" n ".pem")}' "$bundle"
  for f in "$d"/ca-*.pem; do
    fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f' | cut -c1-16)
    alias="cp-ca-$fp"
    want+=("$alias")
    if "${kt[0]}" -list "${kt[@]:1}" -alias "$alias" >/dev/null 2>&1; then
      _mark ok "JDK truststore has $alias"
    else
      _mark changed "JDK truststore: import $alias ($cacerts)"
      [[ ${CPCTL_CHECK:-0} == 1 ]] || "${kt[0]}" -importcert -noprompt "${kt[@]:1}" -alias "$alias" -file "$f" >/dev/null
    fi
  done
  rm -rf "$d"
  have=$("${kt[0]}" -list "${kt[@]:1}" 2>/dev/null | grep -o -E '^(cp-ca-[0-9a-f]+|cp-internal-ca)' || true)
  for alias in $have; do
    [[ " ${want[*]} " == *" $alias "* ]] && continue
    _mark changed "JDK truststore: remove $alias (no longer in the trust bundle)"
    [[ ${CPCTL_CHECK:-0} == 1 ]] || "${kt[0]}" -delete "${kt[@]:1}" -alias "$alias" >/dev/null
  done
}
