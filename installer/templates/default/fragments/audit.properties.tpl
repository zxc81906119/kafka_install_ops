############################# Audit logs (production settings) #############################
# Writer = dedicated low-privilege SCRAM principal (not the broker principal), CLIENT listener.
# Routing (conf/audit.env): sensitive topics -> separate topic with longer retention; noise principals excluded.
confluent.security.event.logger.enable=true
confluent.security.event.logger.exporter.kafka.bootstrap.servers=${AUDIT_BOOTSTRAP}
confluent.security.event.logger.exporter.kafka.security.protocol=SASL_SSL
confluent.security.event.logger.exporter.kafka.sasl.mechanism=SCRAM-SHA-512
confluent.security.event.logger.exporter.kafka.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="${AUDIT_PRINCIPAL}" password="${AUDIT_PASSWORD}";
confluent.security.event.logger.exporter.kafka.ssl.truststore.type=PKCS12
confluent.security.event.logger.exporter.kafka.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.security.event.logger.exporter.kafka.ssl.truststore.password=${STORE_PASSWORD}
confluent.security.event.logger.exporter.kafka.topic.replicas=3
confluent.security.event.logger.exporter.kafka.topic.retention.ms=${AUDIT_RETENTION_MS}
confluent.security.event.router.config=${AUDIT_ROUTER_JSON}
