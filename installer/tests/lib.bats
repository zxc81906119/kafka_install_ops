#!/usr/bin/env bats
# Unit tests for the cpctl framework (run on the ops host: bats installer/tests).
load helper

setup() { setup_cpctl; setup_node; }

# ---------- inventory (Repository)
@test "inv::hosts lists a role's hosts one per line" {
  run inv::hosts controller
  [ "$status" -eq 0 ]
  [ "${lines[*]}" = "kc01 kc02 kc03" ]
}

@test "inv::get maps hyphenated host names and falls back to a default" {
  [ "$(inv::get c3-01 ROLEFLAG)" = yes ]
  [ "$(inv::get kc02 NODE_ID 99)" = 99 ]
}

@test "inv::endpoints builds a comma separated FQDN list" {
  [ "$(inv::endpoints controller 9093)" = "kc01.test.lab:9093,kc02.test.lab:9093,kc03.test.lab:9093" ]
  [ "$(inv::endpoints broker 8090 https)" = "https://kb01.test.lab:8090,https://kb02.test.lab:8090" ]
}

@test "inv::apps splits apps by access channel (scram is the default)" {
  [ "$(inv::apps scram | paste -sd' ' -)" = "app-a app-b" ]
  [ "$(inv::apps rest)" = app-legacy ]
}

@test "inv::heap reads the profile specific value" {
  [ "$(inv::heap broker)" = 512m ]
}

# ---------- render
@test "render::to substitutes placeholders and leaves other dollar signs alone" {
  tpl_dir="$BATS_TEST_TMPDIR/tpl"; mkdir -p "$tpl_dir/default"
  printf 'a=${FOO}\nrule=RULE:.*CN=(x)$/$1/\n' >"$tpl_dir/default/t.tpl"
  render::find() { printf '%s' "$tpl_dir/default/$1"; }
  export FOO=bar
  render::to t.tpl "$BATS_TEST_TMPDIR/out"
  run cat "$BATS_TEST_TMPDIR/out"
  [ "${lines[0]}" = "a=bar" ]
  [ "${lines[1]}" = 'rule=RULE:.*CN=(x)$/$1/' ]
}

@test "render::to refuses undefined placeholders" {
  tpl_dir="$BATS_TEST_TMPDIR/tpl"; mkdir -p "$tpl_dir/default"
  printf 'x=${NOT_DEFINED_ANYWHERE}\n' >"$tpl_dir/default/u.tpl"
  render::find() { printf '%s' "$tpl_dir/default/$1"; }
  run render::to u.tpl "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *NOT_DEFINED_ANYWHERE* ]]
}

@test "render::to accepts templates without placeholders" {
  tpl_dir="$BATS_TEST_TMPDIR/tpl"; mkdir -p "$tpl_dir/default"
  printf 'static: true\n' >"$tpl_dir/default/s.tpl"
  render::find() { printf '%s' "$tpl_dir/default/$1"; }
  run render::to s.tpl "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/out")" = "static: true" ]
}

# ---------- ensure::* (idempotent primitives)
@test "ensure::file: new -> changed, same content -> ok, new content -> changed with backup" {
  d="$BATS_TEST_TMPDIR/n"; mkdir -p "$d"
  printf 'v1\n' >"$d/src"; run ensure::file "$d/src" "$d/dst" "$ME" "$MYGROUP" 0640
  [[ "$output" == *"::changed::"* ]]
  printf 'v1\n' >"$d/src"; run ensure::file "$d/src" "$d/dst" "$ME" "$MYGROUP" 0640
  [[ "$output" == *"::ok::"* ]]
  printf 'v2\n' >"$d/src"; run ensure::file "$d/src" "$d/dst" "$ME" "$MYGROUP" 0640
  [[ "$output" == *"content changed"* ]]
  [ "$(cat "$d/dst")" = v2 ]
  ls "$d"/dst.bak.* >/dev/null
}

@test "ensure::file in check mode reports but does not write" {
  d="$BATS_TEST_TMPDIR/c"; mkdir -p "$d"
  printf 'x\n' >"$d/src"
  CPCTL_CHECK=1 run ensure::file "$d/src" "$d/dst" "$ME" "$MYGROUP" 0640
  [[ "$output" == *"::changed::"* ]]
  [ ! -e "$d/dst" ]
}

@test "ensure::file never changes the mode of an existing parent directory" {
  d="$BATS_TEST_TMPDIR/p"; mkdir -p "$d/conf"; chmod 0750 "$d/conf"
  printf 'x\n' >"$d/src"
  ensure::file "$d/src" "$d/conf/f" "$ME" "$MYGROUP" 0640 >/dev/null
  [ "$(stat -c %a "$d/conf")" = 750 ]
}

@test "ensure::dir and ensure::symlink converge and then report ok" {
  d="$BATS_TEST_TMPDIR/s"
  run ensure::dir "$d" "$ME" "$MYGROUP" 0750; [[ "$output" == *"::changed::"* ]]
  run ensure::dir "$d" "$ME" "$MYGROUP" 0750; [[ "$output" == *"::ok::"* ]]
  run ensure::symlink /etc "$d/l"; [[ "$output" == *"::changed::"* ]]
  run ensure::symlink /etc "$d/l"; [[ "$output" == *"::ok::"* ]]
}

# ---------- step runner (Template Method + stamps)
@test "step::run skips when inputs are unchanged and verify passes, re-applies on drift" {
  mkdir -p "$BATS_TEST_TMPDIR/steps"
  cat >"$BATS_TEST_TMPDIR/steps/50_demo.sh" <<EOF
STEP_DESC="demo"
step_apply() { echo applied >>"$BATS_TEST_TMPDIR/apply.log"; touch "$BATS_TEST_TMPDIR/state.ok"; }
step_verify() { [[ -f "$BATS_TEST_TMPDIR/state.ok" ]]; }
EOF
  step::_path() { printf '%s' "$BATS_TEST_TMPDIR/steps/50_demo.sh"; }
  step::run 50_demo 2>/dev/null
  step::run 50_demo 2>/dev/null
  [ "$(wc -l <"$BATS_TEST_TMPDIR/apply.log")" -eq 1 ]   # second run skipped
  rm -f "$BATS_TEST_TMPDIR/state.ok"                      # simulate drift
  step::run 50_demo 2>/dev/null
  [ "$(wc -l <"$BATS_TEST_TMPDIR/apply.log")" -eq 2 ]   # re-applied
}

# ---------- handler (Observer)
@test "handler::notify de-duplicates and persists across runs" {
  handler::notify broker kb01
  handler::notify broker kb01
  CPCTL_RUN_ID=another-run handler::notify broker kb02
  [ "$(wc -l <"$(handler::_file)")" -eq 2 ]
}

# ---------- generated security settings
@test "protected users = super users + every AD service account, no duplicates" {
  SUPER_USERS="User:kafka-internal;User:svc-x"
  [ "$(role::protected_users)" = "User:kafka-internal;User:svc-x;User:svc-y" ]
}

@test "REST principal rule accepts exactly the legacy CNs, has no DEFAULT and no comma" {
  rule=$(role::rest_principal_rules)
  [ "$rule" = 'RULE:.*CN=(app-legacy)([^a-zA-Z0-9._-].*)?$/$1/' ]
  [[ "$rule" != *,* ]]
  # behaves like Kafka's mapper: exact CN only
  re='.*CN=(app-legacy)([^a-zA-Z0-9._-].*)?$'
  [[ "C=TW,O=Bank,CN=app-legacy" =~ $re ]]
  ! [[ "C=TW,O=Bank,CN=app-legacy-evil" =~ $re ]]
  ! [[ "C=TW,O=Bank,CN=app-a" =~ $re ]]
}
