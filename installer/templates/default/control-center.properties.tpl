# Managed by cpctl - Control Center ${HOST_FQDN}. Do not edit by hand.
confluent.controlcenter.id=10
confluent.controlcenter.name=${CLUSTER_NAME}
confluent.controlcenter.data.dir=/var/lib/confluent/control-center
confluent.controlcenter.internal.topics.replication=3
confluent.controlcenter.command.topic.replication=3
confluent.controlcenter.docs.host=${C3_DOCS_HOST}
${LICENSE_LINE}

############################# Kafka connection (TOKEN listener, MDS tokens) #############################
bootstrap.servers=${TOKEN_BOOTSTRAP}
confluent.controlcenter.streams.security.protocol=SASL_SSL
confluent.controlcenter.streams.sasl.mechanism=OAUTHBEARER
# MDS token for svc-c3, fetched with the svc-c3 client certificate (streams.ssl.keystore.*) - no AD account
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
# C3's own calls to MDS authenticate with the svc-c3 client certificate (User:svc-c3, SystemAdmin) - not with
# cp-server, the UI certificate every server shares: the proxy store is the client side of C3's REST calls
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
public.key.path=/etc/confluent/ssl/mds-public.pem

############################# HTTPS UI #############################
confluent.controlcenter.rest.listeners=https://0.0.0.0:${PORT_C3}
confluent.controlcenter.rest.ssl.keystore.type=PKCS12
confluent.controlcenter.rest.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.rest.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.rest.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.rest.ssl.truststore.type=PKCS12
confluent.controlcenter.rest.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.rest.ssl.truststore.password=${STORE_PASSWORD}

############################# Embedded Prometheus / Alertmanager (mTLS) #############################
confluent.controlcenter.prometheus.enable=true
confluent.controlcenter.prometheus.url=https://${HOST_FQDN}:${PORT_PROMETHEUS}
confluent.controlcenter.prometheus.rules.file=/etc/confluent-control-center/trigger_rules-generated.yml
confluent.controlcenter.prometheus.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.prometheus.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.prometheus.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.alias.name=cp-server
confluent.controlcenter.alertmanager.url=https://${HOST_FQDN}:${PORT_ALERTMANAGER}
confluent.controlcenter.alertmanager.config.file=/etc/confluent-control-center/alertmanager-generated.yml
confluent.controlcenter.alertmanager.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.alertmanager.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.alertmanager.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.alias.name=cp-server
