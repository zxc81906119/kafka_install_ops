# shellcheck shell=bash
# shellcheck disable=SC2046  # host names from the inventory never contain whitespace
STEP_DESC="start REST Proxies and Control Center (+Prometheus/Alertmanager), apply load-balancer config"

step_apply() {
  role::common_vars
  remote::parallel role::rest::start $(inv::hosts rest)
  local h
  for h in $(inv::hosts c3); do role::c3::start "$h"; done
  role::lb::configure
  step::mutating || return 0
  for h in $(inv::hosts rest); do role::rest::health "$h"; done
  for h in $(inv::hosts c3); do role::c3::health "$h"; done
  for h in $(inv::hosts lb); do role::lb::health "$h"; done
}

step_verify() {
  local h
  for h in $(inv::hosts rest); do rest::_answers "$h" || return 1; done
  for h in $(inv::hosts c3); do c3::_ui_up "$h" || return 1; done
}
