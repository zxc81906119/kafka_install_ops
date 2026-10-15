# Managed by cpctl - Prometheus JMX exporter (javaagent) for ${JMX_COMPONENT} on ${HOST_FQDN}
# HTTPS with the node's certificate; basic auth with a salted SHA-256 hash (no plaintext scrape password here)
httpServer:
  ssl:
    keyStore:
      filename: /etc/confluent/ssl/${JMX_KEYSTORE}.p12
      password: ${STORE_PASSWORD}
      type: PKCS12
    certificate:
      alias: ${JMX_KEYSTORE}
  authentication:
    basic:
      username: ${JMX_EXPORTER_USER}
      passwordHash: ${JMX_PASSWORD_HASH}
      algorithm: SHA-256
      salt: ${JMX_PASSWORD_SALT}
lowercaseOutputName: true
lowercaseOutputLabelNames: true
