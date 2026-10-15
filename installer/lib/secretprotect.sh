#!/usr/bin/env bash
# Secret Protection (Confluent "confluent secret"): no plaintext password in any rendered .properties file.
#   - one master key per cluster, generated once from SECRET_MASTER_PASSPHRASE, kept on the ops host (0600)
#   - every key ending in password / credentials / passphrase / user.info, and the password inside every
#     sasl.jaas.config, is replaced by ${securepass:...}; ciphertexts go to /etc/confluent/<comp>/security.properties
#   - the services get CONFLUENT_SECURITY_MASTER_KEY from /etc/confluent/<comp>/service.env (root, 0600)
# Encryption is not deterministic (random IV), so results are cached by the sha256 of the plaintext:
# unchanged plaintext -> identical files -> no restart (idempotency).
[[ -n ${_LIB_SP_LOADED:-} ]] && return 0
_LIB_SP_LOADED=1

readonly SP_DIR=$STATE_DIR/secret-protection

sp::enabled() { [[ ${SECRET_PROTECTION:-on} == on ]]; }

sp::cli() { HOME=$STATE_DIR/cli-home "$(install::cli)" "$@"; }

# sp::master_key -> prints the master key (creates it once)
sp::master_key() {
  install -d -m 0700 "$SP_DIR"
  # serialized: configure jobs run in parallel and must never create two different master keys
  exec 8>"$SP_DIR/.lock"
  flock 8
  if [[ ! -s $SP_DIR/master.key ]]; then
    local out
    out=$(sp::cli secret master-key generate --local-secrets-file "$SP_DIR/master.secrets" \
      --passphrase "$(inv::secret SECRET_MASTER_PASSPHRASE)" -o json) || core::die "master key generation failed"
    jq -r '.master_key' <<<"$out" >"$SP_DIR/master.key"
    chmod 0600 "$SP_DIR/master.key" "$SP_DIR/master.secrets"
    log::changed "Secret Protection master key created ($SP_DIR, 0600)"
  fi
  cat "$SP_DIR/master.key"
  flock -u 8
}

# sp::keys <properties file> -> comma separated list of keys / JAAS paths to encrypt
sp::keys() {
  awk -F= '
    /^[[:space:]]*#/ || !/=/ { next }
    {
      k = $1; gsub(/[[:space:]]/, "", k)
      v = substr($0, index($0, "=") + 1)
      if (v ~ /^[[:space:]]*$/ || v ~ /\$\{securepass:/) next
      if (k ~ /(password|credentials|passphrase|basic\.auth\.user\.info)$/) { print k; next }
      if (k ~ /sasl\.jaas\.config$/ && v ~ /password=/) {
        split(v, w, /[[:space:]]+/); m = (w[1] == "" ? w[2] : w[1]); print k "/" m "/password"
      }
    }' "$1" | paste -sd, -
}

# sp::protect <host> <component> <plaintext file> <dest name>
# Leaves "$SP_DIR/<host>/<dest name>" (encrypted config) and ".../<component>.security.properties" (ciphertexts).
sp::protect() {
  local host=$1 comp=$2 plain=$3 name=$4
  local d="$SP_DIR/$host" sha keys
  install -d -m 0700 "$d"
  sha=$(core::sha256 "$plain")
  if [[ -f $d/$name.plain.sha256 && $(cat "$d/$name.plain.sha256") == "$sha" && -f $d/$name && -f $d/$comp.security.properties ]]; then
    return 0   # reuse previous ciphertext: same input, same output files
  fi
  keys=$(sp::keys "$plain")
  install -m 0600 "$plain" "$d/$name"
  [[ -n $keys ]] || { printf '%s' "$sha" >"$d/$name.plain.sha256"; : >"$d/$comp.security.properties"; return 0; }
  install -m 0600 "$SP_DIR/master.secrets" "$d/$comp.security.properties"
  CONFLUENT_SECURITY_MASTER_KEY=$(sp::master_key) sp::cli secret file encrypt --config-file "$d/$name" \
    --local-secrets-file "$d/$comp.security.properties" \
    --remote-secrets-file "/etc/confluent/$comp/security.properties" --config "$keys" >/dev/null ||
    core::die "[$host] confluent secret file encrypt failed for $name"
  grep -q 'securepass' "$d/$name" || core::die "[$host] $name was not encrypted"
  printf '%s' "$sha" >"$d/$name.plain.sha256"
}

# sp::push <host> <component> <plaintext file> <dest path> <owner> <group> <mode>   -> REMOTE_CHANGED
sp::push() {
  local host=$1 comp=$2 plain=$3 dst=$4 o=$5 g=$6 m=$7 name any=0
  name=$(basename "$dst")
  sp::master_key >/dev/null
  sp::protect "$host" "$comp" "$plain" "$name"
  local d="$SP_DIR/$host"
  remote::put "$host" "$d/$name" "$dst" "$o" "$g" "$m"; [[ $REMOTE_CHANGED == 1 ]] && any=1
  remote::put "$host" "$d/$comp.security.properties" "/etc/confluent/$comp/security.properties" root confluent 0640
  [[ $REMOTE_CHANGED == 1 ]] && any=1
  local env
  env=$(render::tmp)
  printf 'CONFLUENT_SECURITY_MASTER_KEY=%s\n' "$(sp::master_key)" >"$env"
  remote::put "$host" "$env" "/etc/confluent/$comp/service.env" root root 0600; [[ $REMOTE_CHANGED == 1 ]] && any=1
  rm -f "$env"
  REMOTE_CHANGED=$any
}
