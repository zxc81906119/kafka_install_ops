#!/usr/bin/env bash
# Manual walkthrough: PLAINTEXT kafka-rest.properties / control-center.properties (complete versions; manual 5.2.1 / 5.2.2)
# usage: gen-edge-properties.sh rest <host> <rest-id> | c3 <host>
set -euo pipefail
kind=$1 h=$2
S=/var/lib/cp-installer
set -a; . $S/secrets.env; set +a
D=$S/secret-protection/$h; install -d -m 0700 $D; umask 077
SP=$STORE_PASSWORD
MDSURLS=https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090
TOKEN_BS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094,kb04.poc.lab:9094
if [ "$kind" = rest ]; then
F=$D/kafka-rest.properties
cat > $F <<EOF
id=$3
listeners=https://0.0.0.0:8082
advertised.listeners=https://rest.poc.lab:8082
host.name=rest.poc.lab
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
ssl.keystore.password=$SP
ssl.key.password=$SP
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ssl.truststore.password=$SP
ssl.client.authentication=REQUIRED
ssl.enabled.protocols=TLSv1.3,TLSv1.2
kafka.rest.resource.extension.class=io.confluent.kafkarest.security.KafkaRestSecurityResourceExtension
rest.servlet.initializor.classes=io.confluent.common.security.jetty.initializer.AuthenticationHandler
confluent.rest.auth.propagate.method=SSL
confluent.rest.auth.ssl.principal.mapping.rules=RULE:.*CN=(app-legacy-billing)([^a-zA-Z0-9._-].*)?\$/\$1/
auth.ssl.principal.mapping.rules=RULE:.*CN=(app-legacy-billing)([^a-zA-Z0-9._-].*)?\$/\$1/
public.key.path=/etc/confluent/ssl/mds-public.pem
confluent.metadata.bootstrap.server.urls=$MDSURLS
confluent.metadata.http.auth.credentials.provider=BASIC
confluent.metadata.basic.auth.user.info=svc-rest:$SVC_REST_PASSWORD
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=$SP
bootstrap.servers=$TOKEN_BS
client.security.protocol=SASL_SSL
client.sasl.mechanism=OAUTHBEARER
client.sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenUserLoginCallbackHandler
client.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username="svc-rest" password="$SVC_REST_PASSWORD" metadataServerUrls="$MDSURLS";
client.ssl.truststore.type=PKCS12
client.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
client.ssl.truststore.password=$SP
client.ssl.endpoint.identification.algorithm=https
consumer.threads=8
consumer.instance.timeout.ms=300000
EOF
else
F=$D/control-center.properties
cat > $F <<EOF
confluent.controlcenter.id=10
confluent.controlcenter.name=poc-cluster
confluent.controlcenter.data.dir=/var/lib/confluent/control-center
confluent.controlcenter.internal.topics.replication=3
confluent.controlcenter.command.topic.replication=3
confluent.controlcenter.docs.host=docs.confluent.io
bootstrap.servers=$TOKEN_BS
confluent.controlcenter.streams.security.protocol=SASL_SSL
confluent.controlcenter.streams.sasl.mechanism=OAUTHBEARER
confluent.controlcenter.streams.sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenUserLoginCallbackHandler
confluent.controlcenter.streams.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username="svc-c3" password="$SVC_C3_PASSWORD" metadataServerUrls="$MDSURLS";
confluent.controlcenter.streams.ssl.truststore.type=PKCS12
confluent.controlcenter.streams.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.streams.ssl.truststore.password=$SP
confluent.metadata.bootstrap.server.urls=$MDSURLS
confluent.metadata.basic.auth.user.info=svc-c3:$SVC_C3_PASSWORD
confluent.metadata.http.auth.credentials.provider=BASIC
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=$SP
confluent.controlcenter.rest.authentication.method=BEARER
public.key.path=/etc/confluent/ssl/mds-public.pem
confluent.controlcenter.rest.listeners=https://0.0.0.0:9021
confluent.controlcenter.rest.ssl.keystore.type=PKCS12
confluent.controlcenter.rest.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.rest.ssl.keystore.password=$SP
confluent.controlcenter.rest.ssl.key.password=$SP
confluent.controlcenter.rest.ssl.truststore.type=PKCS12
confluent.controlcenter.rest.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.rest.ssl.truststore.password=$SP
confluent.controlcenter.prometheus.enable=true
confluent.controlcenter.prometheus.url=https://c3-01.poc.lab:9090
confluent.controlcenter.prometheus.rules.file=/etc/confluent-control-center/trigger_rules-generated.yml
confluent.controlcenter.prometheus.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.prometheus.ssl.truststore.password=$SP
confluent.controlcenter.prometheus.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.prometheus.ssl.keystore.password=$SP
confluent.controlcenter.prometheus.ssl.key.password=$SP
confluent.controlcenter.prometheus.alias.name=cp-server
confluent.controlcenter.alertmanager.url=https://c3-01.poc.lab:9093
confluent.controlcenter.alertmanager.config.file=/etc/confluent-control-center/alertmanager-generated.yml
confluent.controlcenter.alertmanager.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.alertmanager.ssl.truststore.password=$SP
confluent.controlcenter.alertmanager.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.alertmanager.ssl.keystore.password=$SP
confluent.controlcenter.alertmanager.ssl.key.password=$SP
confluent.controlcenter.alertmanager.alias.name=cp-server
EOF
fi
chmod 0600 $F
echo "$F: $(grep -c '=' $F) lines"
