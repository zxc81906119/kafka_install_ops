# Managed by cpctl - KRaft controller ${HOST_FQDN}. Do not edit by hand (changes are overwritten).
process.roles=controller
node.id=${NODE_ID}
# Dynamic quorum (KIP-853): no static controller.quorum.voters
controller.quorum.bootstrap.servers=${CONTROLLER_BOOTSTRAP}
controller.listener.names=CONTROLLER
listeners=CONTROLLER://${HOST_FQDN}:${PORT_CONTROLLER}
advertised.listeners=CONTROLLER://${HOST_FQDN}:${PORT_CONTROLLER}
listener.security.protocol.map=CONTROLLER:SSL
log.dirs=/var/lib/kafka/data

${COMMON_BLOCK}

############################# MDS on KRaft controllers #############################
confluent.metadata.server.kraft.controller.enabled=true
# The RBAC store (_confluent-metadata-auth) is read from the brokers' INTERNAL listener with the shared internal cert
confluent.metadata.bootstrap.servers=${BROKER_INTERNAL_BOOTSTRAP}
confluent.metadata.security.protocol=SSL
confluent.metadata.ssl.keystore.type=PKCS12
confluent.metadata.ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
confluent.metadata.ssl.keystore.password=${STORE_PASSWORD}
confluent.metadata.ssl.key.password=${STORE_PASSWORD}
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=${STORE_PASSWORD}

${LDAP_BLOCK}

${TELEMETRY_BLOCK}
