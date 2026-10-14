# Managed by cpctl - REST Proxy ${HOST_FQDN}. Do not edit by hand.
id=${REST_ID}
listeners=https://0.0.0.0:${PORT_REST}
# Clients only ever see the load-balancer name; v2 consumer stickiness is handled by the LB (source hash).
advertised.listeners=https://${LB_REST_NAME}:${PORT_REST}
host.name=${LB_REST_NAME}

############################# HTTPS + mandatory client certificates (machines) #############################
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
ssl.keystore.password=${STORE_PASSWORD}
ssl.key.password=${STORE_PASSWORD}
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ssl.truststore.password=${STORE_PASSWORD}
ssl.client.authentication=REQUIRED
ssl.enabled.protocols=TLSv1.3,TLSv1.2

############################# RBAC: authenticate by certificate, act as that principal #############################
kafka.rest.resource.extension.class=io.confluent.kafkarest.security.KafkaRestSecurityResourceExtension
rest.servlet.initializor.classes=io.confluent.common.security.jetty.initializer.AuthenticationHandler
confluent.rest.auth.propagate.method=SSL
confluent.rest.auth.ssl.principal.mapping.rules=${REST_PRINCIPAL_RULES}
# The mapping actually applied to the client certificate before impersonation (verified in 8.3.2;
# without it the full DN "C=..,O=..,CN=app" is impersonated and RBAC bindings on User:<app> never match)
auth.ssl.principal.mapping.rules=${REST_PRINCIPAL_RULES}
public.key.path=/etc/confluent/ssl/mds-public.pem

# MDS (impersonation tokens). REST Proxy authenticates to MDS as its own AD service account.
confluent.metadata.bootstrap.server.urls=${MDS_URLS}
confluent.metadata.http.auth.credentials.provider=BASIC
confluent.metadata.basic.auth.user.info=svc-rest:${SVC_REST_PASSWORD}
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=${STORE_PASSWORD}

############################# Kafka client (TOKEN listener, impersonated principal) #############################
bootstrap.servers=${TOKEN_BOOTSTRAP}
client.security.protocol=SASL_SSL
client.sasl.mechanism=OAUTHBEARER
# REST Proxy's own identity on Kafka (license fetch, metadata): MDS token for svc-rest.
# Requests from apps are then executed with impersonation tokens for the client-certificate principal.
client.sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenUserLoginCallbackHandler
client.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username="svc-rest" password="${SVC_REST_PASSWORD}" metadataServerUrls="${MDS_URLS}";
client.ssl.truststore.type=PKCS12
client.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
client.ssl.truststore.password=${STORE_PASSWORD}
client.ssl.endpoint.identification.algorithm=https

# v2 consumer instances are stateful: keep enough threads, expire idle instances
consumer.threads=8
consumer.instance.timeout.ms=300000
