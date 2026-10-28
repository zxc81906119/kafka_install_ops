confluent.controlcenter.id=10
confluent.controlcenter.name=poc-cluster
confluent.controlcenter.data.dir=/var/lib/confluent/control-center
confluent.controlcenter.internal.topics.replication=3
confluent.controlcenter.command.topic.replication=3
# confluent.license not set: evaluation mode

############################# Kafka connection (TOKEN listener, MDS tokens as svc-c3) #############################
bootstrap.servers=${BROKER_TOKEN}
confluent.controlcenter.streams.security.protocol=SASL_SSL
confluent.controlcenter.streams.sasl.mechanism=OAUTHBEARER
confluent.controlcenter.streams.sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenCertificateLoginCallbackHandler
confluent.controlcenter.streams.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required metadataServerUrls="${MDS_URLS}";
confluent.controlcenter.streams.ssl.keystore.type=PKCS12
confluent.controlcenter.streams.ssl.keystore.location=/etc/confluent/ssl/svc-c3.p12
confluent.controlcenter.streams.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.streams.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.streams.ssl.truststore.type=PKCS12
confluent.controlcenter.streams.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.streams.ssl.truststore.password=${STORE_PASSWORD}

############################# RBAC (humans log in with AD credentials through MDS) #############################
confluent.metadata.bootstrap.server.urls=${MDS_URLS}
confluent.controlcenter.rest.proxy.ssl.keystore.type=PKCS12
confluent.controlcenter.rest.proxy.ssl.keystore.location=/etc/confluent/ssl/svc-c3.p12
confluent.controlcenter.rest.proxy.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.rest.proxy.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.rest.proxy.ssl.truststore.type=PKCS12
confluent.controlcenter.rest.proxy.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.rest.proxy.ssl.truststore.password=${STORE_PASSWORD}
confluent.metadata.ssl.keystore.type=PKCS12
confluent.metadata.ssl.keystore.location=/etc/confluent/ssl/svc-c3.p12
confluent.metadata.ssl.keystore.password=${STORE_PASSWORD}
confluent.metadata.ssl.key.password=${STORE_PASSWORD}
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.rest.authentication.method=BEARER
public.key.path=/etc/confluent/ssl/mds-token-public.pem

############################# HTTPS UI #############################
confluent.controlcenter.rest.listeners=https://0.0.0.0:9021
confluent.controlcenter.rest.ssl.keystore.type=PKCS12
confluent.controlcenter.rest.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.rest.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.rest.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.rest.ssl.truststore.type=PKCS12
confluent.controlcenter.rest.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.rest.ssl.truststore.password=${STORE_PASSWORD}

############################# Embedded Prometheus / Alertmanager (mTLS) #############################
confluent.controlcenter.prometheus.enable=true
confluent.controlcenter.prometheus.url=https://${C3_FQDN}:9090
confluent.controlcenter.prometheus.rules.file=/etc/confluent-control-center/trigger_rules-generated.yml
confluent.controlcenter.prometheus.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.prometheus.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.ssl.keystore.location=/etc/confluent/ssl/c3-monitoring.p12
confluent.controlcenter.prometheus.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.alias.name=c3-monitoring
confluent.controlcenter.alertmanager.url=https://${C3_FQDN}:9093
confluent.controlcenter.alertmanager.config.file=/etc/confluent-control-center/alertmanager-generated.yml
confluent.controlcenter.alertmanager.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.alertmanager.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.keystore.location=/etc/confluent/ssl/c3-monitoring.p12
confluent.controlcenter.alertmanager.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.alias.name=c3-monitoring
