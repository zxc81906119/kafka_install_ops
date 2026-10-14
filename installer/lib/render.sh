#!/usr/bin/env bash
# Template rendering: ${VAR} placeholders only, every placeholder must be defined (no silent blanks).
[[ -n ${_LIB_RENDER_LOADED:-} ]] && return 0
_LIB_RENDER_LOADED=1

# render::find <name>  -> templates/<CP major.minor>/<name> if present, else templates/default/<name>
render::find() {
  local name=$1 v=${RENDER_VERSION:-$CP_VERSION}
  local mm=${v%.*}
  local p
  for p in "$CPCTL_HOME/templates/$mm/$name" "$CPCTL_HOME/templates/default/$name"; do
    [[ -f $p ]] && { printf '%s' "$p"; return 0; }
  done
  core::die "template not found: $name (version $mm)"
}

# render::to <template name> <output file>
render::to() {
  local tpl out=$2 vars=() v missing=()
  tpl=$(render::find "$1")
  # templates without placeholders are valid: grep finding nothing must not trip the ERR trap
  mapfile -t vars < <({ grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "$tpl" || true; } | sort -u | tr -d '${}')
  for v in "${vars[@]}"; do
    [[ -v $v ]] || missing+=("$v")
  done
  [[ ${#missing[@]} -eq 0 ]] || core::die "template $1: undefined variables: ${missing[*]}"
  local list=""
  for v in "${vars[@]}"; do
    export "${v?}"
    list+="\${$v} "
  done
  envsubst "$list" <"$tpl" >"$out"
}

# render::tmp  -> new temp file under the run dir (cleaned at exit)
render::tmp() { mktemp "$RUN_DIR/render.XXXXXX"; }
