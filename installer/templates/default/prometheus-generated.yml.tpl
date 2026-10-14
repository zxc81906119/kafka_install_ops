# Managed by cpctl - embedded Prometheus for Control Center (metrics arrive via the OTLP receiver).
global:
  scrape_interval: 60s
  evaluation_interval: 60s

# Alertmanager over mTLS
alerting:
  alertmanagers:
    - scheme: https
      tls_config:
        ca_file: /etc/confluent/ssl/ca.pem
        cert_file: /etc/confluent/ssl/cp-server.crt
        key_file: /etc/confluent/ssl/cp-server.key
      static_configs:
        - targets:
            - ${HOST_FQDN}:${PORT_ALERTMANAGER}

rule_files:
  - 'recording_rules-generated.yml'
  - 'trigger_rules-generated.yml'

scrape_configs:
