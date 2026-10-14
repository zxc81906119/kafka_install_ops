# Managed by cpctl - TLS for the embedded Prometheus / Alertmanager. Every client must present a cert from the internal CA.
tls_server_config:
  cert_file: /etc/confluent/ssl/cp-server.crt
  key_file: /etc/confluent/ssl/cp-server.key
  client_ca_file: /etc/confluent/ssl/ca.pem
  client_auth_type: RequireAndVerifyClientCert
  min_version: TLS12
