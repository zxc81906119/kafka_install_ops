#!/usr/bin/env bash
# External monitoring hand-off: what the bank's Prometheus / Alertmanager team needs to scrape the cluster.
#   cpctl monitoring export -> $STATE_DIR/monitoring/{prometheus-scrape.yml, alert-rules.yml, ca.pem, README.txt}
#   cpctl monitoring check  -> every exporter answers over HTTPS with basic auth, and rejects anonymous scrapes
[[ -n ${_LIB_MONITORING_LOADED:-} ]] && return 0
_LIB_MONITORING_LOADED=1

monitoring::targets() { # <role> -> "  - host:port" lines
  local h
  for h in $(inv::hosts "$1"); do printf "          - '%s:%s'\n" "$(inv::fqdn "$h")" "$PORT_JMX_EXPORTER"; done
}

monitoring::export() {
  local d=$STATE_DIR/monitoring role
  install -d -m 0700 "$d"
  {
    printf '# Managed by cpctl - add these jobs to the bank Prometheus (scrape_configs:)\n'
    printf '# The scrape password is JMX_EXPORTER_PASSWORD (hand over via the vault, never in this file)\n'
    printf 'scrape_configs:\n'
    for role in controller broker rest; do
      cat <<EOF
  - job_name: confluent-$role
    scheme: https
    scrape_interval: 30s
    tls_config:
      ca_file: /etc/prometheus/confluent/ca.pem
    basic_auth:
      username: $JMX_EXPORTER_USER
      password_file: /etc/prometheus/confluent/jmx-exporter.password
    static_configs:
      - targets:
$(monitoring::targets "$role")
        labels:
          cluster: poc-cluster
EOF
    done
  } >"$d/prometheus-scrape.yml"
  cp "$(render::find monitoring/alert-rules.yml)" "$d/alert-rules.yml"
  cp "$PKI_DIR/ca.pem" "$d/ca.pem"
  cat >"$d/README.txt" <<EOF
Confluent Platform - external monitoring hand-off ($(date +%F))
  prometheus-scrape.yml  jobs confluent-controller / -broker / -rest (HTTPS, basic auth, port $PORT_JMX_EXPORTER)
  alert-rules.yml        rule_files: entry for Prometheus; route severity=critical to paging in Alertmanager
  ca.pem                 internal CA trust bundle (re-export after: cpctl certs rotate-ca)
Firewall: bank Prometheus -> every controller / broker / REST host, TCP $PORT_JMX_EXPORTER
EOF
  log::ok "monitoring hand-off written to $d ($(ls "$d" | paste -sd' ' -))"
}

monitoring::check() {
  local h rc=0 pw url out
  pw=$(inv::secret JMX_EXPORTER_PASSWORD)
  for h in $(inv::hosts controller) $(inv::hosts broker) $(inv::hosts rest); do
    url="https://$(inv::fqdn "$h"):$PORT_JMX_EXPORTER/metrics"
    if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$PKI_DIR/ca.pem" "$url") != 401 ]]; then
      log::error "[$h] JMX exporter does not require authentication"; rc=1; continue
    fi
    # capture first: "curl | grep -q" dies of SIGPIPE under pipefail
    out=$(curl -s --max-time 20 --cacert "$PKI_DIR/ca.pem" -u "$JMX_EXPORTER_USER:$pw" "$url" || true)
    if grep -q -E '^(kafka_|jvm_)' <<<"$out"; then
      log::ok "[$h] JMX exporter serves metrics (HTTPS + basic auth)"
    else
      log::error "[$h] JMX exporter: no metrics at $url"; rc=1
    fi
  done
  return "$rc"
}
