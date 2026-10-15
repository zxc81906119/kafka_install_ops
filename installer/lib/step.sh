#!/usr/bin/env bash
# Template Method runner for steps/*.sh and upgrade/*.sh.
# A step file defines:
#   STEP_DESC          one-line description (required)
#   step_apply         converge the target state (required; must be idempotent)
#   step_verify        cheap read-only check that the state is correct (optional)
#   step_inputs        prints anything the step depends on; part of the stamp hash (optional)
# The runner handles logging, timing, stamps, check mode and handler flushing.
[[ -n ${_LIB_STEP_LOADED:-} ]] && return 0
_LIB_STEP_LOADED=1

step::_path() {
  local name=$1 dir=${2:-steps} f
  for f in "$CPCTL_HOME/$dir/$name.sh" "$CPCTL_HOME/$dir/$name"*.sh; do
    [[ -f $f ]] && { printf '%s' "$f"; return 0; }
  done
  core::die "$E_USAGE" "no such step: $name"
}

step::list() { local f; for f in "$CPCTL_HOME/${1:-steps}"/[0-9][0-9]_*.sh; do basename "$f" .sh; done; }

# True when the step may mutate (i.e. not in check mode). Use around raw commands.
step::mutating() { ! core::is_check_mode; }

# step::run <step name> [dir]
step::run() {
  local file name
  file=$(step::_path "$1" "${2:-steps}")
  name=$(basename "$file" .sh)
  (
    STEP_DESC=""
    step_inputs() { :; }
    step_verify() { return 0; }
    # shellcheck source=/dev/null
    source "$file"
    log::step "==== $name: $STEP_DESC"
    local t0=$SECONDS hash stamp="$STAMP_DIR/$name"
    # stamp = step file + its declared inputs + ALL library/role code (a code change must re-run the step)
    hash=$( { cat "$file"; step_inputs; cat "$CPCTL_HOME"/lib/*.sh "$CPCTL_HOME"/lib/*/*.sh "$CPCTL_HOME"/roles/*.sh; } |
      sha256sum | awk '{print $1}')
    if [[ $CPCTL_FORCE != 1 && -f $stamp && $(cat "$stamp") == "$hash" ]] && ! core::is_check_mode; then
      if step_verify >/dev/null 2>&1; then
        log::skipped "$name: inputs unchanged since last success and verify passed"
        exit 0
      fi
      log::warn "$name: inputs unchanged but verify failed (drift) - re-applying"
    fi
    step_apply
    handler::flush
    if ! core::is_check_mode; then
      step_verify || core::die "$E_GATE" "$name: verification failed"
      printf '%s' "$hash" >"$stamp"
    fi
    log::info "$name done in $((SECONDS - t0))s"
  )
}

# step::run_all [--from NN] [dir]
step::run_all() {
  local from="" dir=steps s
  while [[ $# -gt 0 ]]; do
    case $1 in
      --from) from=$2; shift 2 ;;
      *) dir=$1; shift ;;
    esac
  done
  for s in $(step::list "$dir"); do
    if [[ -n $from && $s < $from ]]; then continue; fi
    step::run "$s" "$dir"
  done
}

step::status() {
  local s
  printf '%-28s %s\n' STEP "LAST SUCCESS"
  for s in $(step::list); do
    if [[ -f $STAMP_DIR/$s ]]; then
      printf '%-28s %s\n' "$s" "$(date -r "$STAMP_DIR/$s" '+%F %T')"
    else
      printf '%-28s %s\n' "$s" "-"
    fi
  done
}
