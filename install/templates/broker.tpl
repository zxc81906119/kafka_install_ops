# broker ${HOST_FQDN}
process.roles=broker
node.id=${NODE_ID}
broker.rack=${RACK}
controller.quorum.bootstrap.servers=${CONTROLLER_QUORUM}
controller.listener.names=CONTROLLER
log.dirs=/var/lib/kafka/data
# metadata log (__cluster_metadata) stays here even if more log.dirs are added later (default = first log.dirs entry)
metadata.log.dir=/var/lib/kafka/data

############################# Listeners #############################
listeners=INTERNAL://${HOST_FQDN}:9092,TOKEN://${HOST_FQDN}:9094,CLIENT://${HOST_FQDN}:9095,LDAP://${HOST_FQDN}:9096
advertised.listeners=INTERNAL://${HOST_FQDN}:9092,TOKEN://${HOST_FQDN}:9094,CLIENT://${HOST_FQDN}:9095,LDAP://${HOST_FQDN}:9096
listener.security.protocol.map=CONTROLLER:SSL,INTERNAL:SSL,TOKEN:SASL_SSL,CLIENT:SASL_SSL,LDAP:SASL_SSL
inter.broker.listener.name=INTERNAL
principal.builder.class=io.confluent.kafka.security.authenticator.OAuthKafkaPrincipalBuilder

############################# External listeners: shared server certificate #############################
listener.name.token.ssl.keystore.type=PKCS12
listener.name.token.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
listener.name.token.ssl.keystore.password=${STORE_PASSWORD}
listener.name.token.ssl.key.password=${STORE_PASSWORD}
listener.name.token.ssl.client.auth=none
listener.name.client.ssl.keystore.type=PKCS12
listener.name.client.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
listener.name.client.ssl.keystore.password=${STORE_PASSWORD}
listener.name.client.ssl.key.password=${STORE_PASSWORD}
listener.name.client.ssl.client.auth=none
listener.name.ldap.ssl.keystore.type=PKCS12
listener.name.ldap.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
listener.name.ldap.ssl.keystore.password=${STORE_PASSWORD}
listener.name.ldap.ssl.key.password=${STORE_PASSWORD}
listener.name.ldap.ssl.client.auth=none

# TOKEN: MDS-issued OAuth bearer tokens
listener.name.token.sasl.enabled.mechanisms=OAUTHBEARER
listener.name.token.oauthbearer.sasl.server.callback.handler.class=io.confluent.kafka.server.plugins.auth.token.TokenBearerValidatorCallbackHandler
listener.name.token.oauthbearer.sasl.login.callback.handler.class=io.confluent.kafka.server.plugins.auth.token.TokenBearerServerLoginCallbackHandler
listener.name.token.oauthbearer.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required publicKeyPath="/etc/confluent/ssl/mds-token-public.pem";
listener.name.token.principal.builder.class=io.confluent.kafka.security.authenticator.OAuthKafkaPrincipalBuilder

# CLIENT: SCRAM credentials stored in the KRaft metadata log
listener.name.client.sasl.enabled.mechanisms=SCRAM-SHA-512
listener.name.client.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required;

# LDAP: username/password checked against Active Directory
listener.name.ldap.sasl.enabled.mechanisms=PLAIN
listener.name.ldap.plain.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required;
listener.name.ldap.plain.sasl.server.callback.handler.class=io.confluent.security.auth.provider.ldap.LdapAuthenticateCallbackHandler

############################# Metadata Service (MDS) #############################
confluent.metadata.server.listeners=https://0.0.0.0:8090
confluent.metadata.server.advertised.listeners=https://${HOST_FQDN}:8090
confluent.metadata.server.ssl.keystore.type=PKCS12
confluent.metadata.server.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.metadata.server.ssl.keystore.password=${STORE_PASSWORD}
confluent.metadata.server.ssl.key.password=${STORE_PASSWORD}
confluent.metadata.server.ssl.truststore.type=PKCS12
confluent.metadata.server.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.server.ssl.truststore.password=${STORE_PASSWORD}
confluent.metadata.server.ssl.client.authentication=REQUESTED
confluent.metadata.server.auth.ssl.principal.mapping.rules=RULE:.*CN=([a-zA-Z0-9._-]+).*$/$1/,DEFAULT
confluent.metadata.server.authentication.method=BEARER
confluent.metadata.server.user.store=LDAP
confluent.metadata.server.token.signature.algorithm=RS256
confluent.metadata.server.token.max.lifetime.ms=3600000
confluent.metadata.server.impersonation.super.users=User:svc-rest
confluent.metadata.server.impersonation.protected.users=User:kafka-internal;User:kafka-admin;User:svc-ops;User:svc-mds-bind;User:svc-rest;User:svc-c3;User:svc-backup;User:confluent-audit

############################# Cluster defaults #############################
default.replication.factor=3
min.insync.replicas=2
num.partitions=3
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
unclean.leader.election.enable=false
auto.create.topics.enable=false
confluent.cluster.link.enable=false
