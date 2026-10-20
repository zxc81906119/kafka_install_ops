# shellcheck shell=bash
STEP_DESC="end-to-end verification (quorum, mTLS, SCRAM, AD/LDAP, RBAC, REST via LB, C3, offline)"

step_inputs() { date +%s; }   # always runs

step_apply() {
  step::mutating || { log::skipped "verification is read-only but needs a running cluster; skipped in check mode"; return 0; }
  verify::run_all || core::die "$E_GATE" "verification found failures (see VERIFY lines above)"
}
