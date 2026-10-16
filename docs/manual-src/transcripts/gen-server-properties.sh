#!/usr/bin/env bash
# Manual walkthrough: write the PLAINTEXT server.properties for one host exactly as listed in manual 4.2.3.1–4.2.3.8.
# usage: gen-server-properties.sh <host> <controller|broker> <node.id> [rack]
# Passwords come from $S/secrets.env (0600) at run time; output: $S/secret-protection/<host>/server.properties (0600)
set -euo pipefail
h=$1 role=$2 id=$3 rack=${4:-}
S=/var/lib/cp-installer
set -a; . $S/secrets.env; set +a
D=$S/secret-protection/$h
install -d -m 0700 $D
umask 077
F=$D/server.properties
fq=$h.poc.lab
CB=kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093
BROKERS="kb01 kb02 kb03 kb04"
csv() { local p=$1 out="" b; for b in $BROKERS; do out+="${out:+,}$b.poc.lab:$p"; done; printf '%s' "$out"; }
SP=$STORE_PASSWORD

{
echo "# Written by hand from the manual (4.2.3) - $role $fq"
# ---- 4.2.3.1 角色與 KRaft
if [ "$role" = broker ]; then
cat <<EOF
process.roles=broker
node.id=$id
broker.rack=$rack
controller.quorum.bootstrap.servers=$CB
controller.listener.names=CONTROLLER
log.dirs=/var/lib/kafka/data
EOF
else
cat <<EOF
process.roles=controller
node.id=$id
controller.quorum.bootstrap.servers=$CB
controller.listener.names=CONTROLLER
listeners=CONTROLLER://$fq:9093
advertised.listeners=CONTROLLER://$fq:9093
listener.security.protocol.map=CONTROLLER:SSL
log.dirs=/var/lib/kafka/data
EOF
fi
# ---- 4.2.3.2 Listeners(broker)
if [ "$role" = broker ]; then
cat <<EOF
listeners=INTERNAL://$fq:9092,TOKEN://$fq:9094,CLIENT://$fq:9095,LDAP://$fq:9096
advertised.listeners=INTERNAL://$fq:9092,TOKEN://$fq:9094,CLIENT://$fq:9095,LDAP://$fq:9096
listener.security.protocol.map=CONTROLLER:SSL,INTERNAL:SSL,TOKEN:SASL_SSL,CLIENT:SASL_SSL,LDAP:SASL_SSL
inter.broker.listener.name=INTERNAL
principal.builder.class=io.confluent.kafka.security.authenticator.OAuthKafkaPrincipalBuilder
EOF
for l in token client ldap; do
cat <<EOF
listener.name.$l.ssl.keystore.type=PKCS12
listener.name.$l.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
listener.name.$l.ssl.keystore.password=$SP
listener.name.$l.ssl.key.password=$SP
listener.name.$l.ssl.client.auth=none
EOF
done
cat <<'EOF'
listener.name.token.sasl.enabled.mechanisms=OAUTHBEARER
listener.name.token.oauthbearer.sasl.server.callback.handler.class=io.confluent.kafka.server.plugins.auth.token.TokenBearerValidatorCallbackHandler
listener.name.token.oauthbearer.sasl.login.callback.handler.class=io.confluent.kafka.server.plugins.auth.token.TokenBearerServerLoginCallbackHandler
listener.name.token.oauthbearer.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required publicKeyPath="/etc/confluent/ssl/mds-public.pem";
listener.name.token.principal.builder.class=io.confluent.kafka.security.authenticator.OAuthKafkaPrincipalBuilder
listener.name.client.sasl.enabled.mechanisms=SCRAM-SHA-512
listener.name.client.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required;
listener.name.ldap.sasl.enabled.mechanisms=PLAIN
listener.name.ldap.plain.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required;
listener.name.ldap.plain.sasl.server.callback.handler.class=io.confluent.security.auth.provider.ldap.LdapAuthenticateCallbackHandler
EOF
fi
# ---- 4.2.3.3 TLS 預設與授權(共用)
cat <<EOF
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
ssl.keystore.password=$SP
ssl.key.password=$SP
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ssl.truststore.password=$SP
ssl.client.auth=required
ssl.endpoint.identification.algorithm=https
ssl.enabled.protocols=TLSv1.3,TLSv1.2
ssl.principal.mapping.rules=RULE:.*CN=([a-zA-Z0-9._-]+).*\$/\$1/,DEFAULT
authorizer.class.name=io.confluent.kafka.security.authorizer.ConfluentServerAuthorizer
confluent.authorizer.access.rule.providers=KRAFT_ACL,CONFLUENT
super.users=User:kafka-internal;User:kafka-admin;User:svc-cpctl
allow.everyone.if.no.acl.found=false
confluent.metadata.server.token.key.path=/etc/confluent/ssl/mds-token-keypair.enc.pem
confluent.metadata.server.token.key.passphrase=$MDS_TOKEN_PASSPHRASE
confluent.metadata.topic.replication.factor=3
# confluent.license not set: evaluation mode
confluent.license.topic.replication.factor=3
confluent.balancer.enable=true
confluent.balancer.topic.replication.factor=3
EOF
# ---- 4.2.3.4 MDS
if [ "$role" = broker ]; then
cat <<EOF
confluent.metadata.server.listeners=https://0.0.0.0:8090
confluent.metadata.server.advertised.listeners=https://$fq:8090
confluent.metadata.server.ssl.keystore.type=PKCS12
confluent.metadata.server.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.metadata.server.ssl.keystore.password=$SP
confluent.metadata.server.ssl.key.password=$SP
confluent.metadata.server.ssl.truststore.type=PKCS12
confluent.metadata.server.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.server.ssl.truststore.password=$SP
confluent.metadata.server.ssl.client.authentication=REQUESTED
confluent.metadata.server.auth.ssl.principal.mapping.rules=RULE:.*CN=([a-zA-Z0-9._-]+).*\$/\$1/,DEFAULT
confluent.metadata.server.authentication.method=BEARER
confluent.metadata.server.user.store=LDAP
confluent.metadata.server.token.signature.algorithm=RS256
confluent.metadata.server.token.max.lifetime.ms=3600000
confluent.metadata.server.impersonation.super.users=User:svc-rest
confluent.metadata.server.impersonation.protected.users=User:kafka-internal;User:kafka-admin;User:svc-cpctl;User:svc-mds-bind;User:svc-rest;User:svc-c3;User:confluent-audit;User:opmenu-breakglass
EOF
else
cat <<EOF
confluent.metadata.server.kraft.controller.enabled=true
confluent.metadata.bootstrap.servers=$(csv 9092)
confluent.metadata.security.protocol=SSL
confluent.metadata.ssl.keystore.type=PKCS12
confluent.metadata.ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
confluent.metadata.ssl.keystore.password=$SP
confluent.metadata.ssl.key.password=$SP
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=$SP
EOF
fi
# ---- 4.2.3.5 LDAP(共用)
cat <<EOF
ldap.java.naming.factory.initial=com.sun.jndi.ldap.LdapCtxFactory
ldap.com.sun.jndi.ldap.connect.timeout=3000
ldap.com.sun.jndi.ldap.read.timeout=5000
ldap.java.naming.provider.url=ldaps://ad01.poc.lab:636
ldap.refresh.interval.ms=60000
ldap.retry.timeout.ms=86400000
ldap.java.naming.security.protocol=SSL
ldap.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ldap.ssl.truststore.password=$SP
ldap.ssl.truststore.type=PKCS12
ldap.java.naming.security.authentication=simple
ldap.java.naming.security.principal=CN=svc-mds-bind,OU=Service,OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.java.naming.security.credentials=$LDAP_BIND_PASSWORD
ldap.search.mode=GROUPS
ldap.user.search.base=OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.user.search.scope=2
ldap.user.object.class=user
ldap.user.name.attribute=sAMAccountName
ldap.group.search.base=OU=Groups,OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.group.search.scope=2
ldap.group.object.class=group
ldap.group.name.attribute=cn
ldap.group.member.attribute=member
ldap.group.member.attribute.pattern=CN=([^,]+),.*
EOF
# ---- 4.2.3.6 叢集預設(broker)
if [ "$role" = broker ]; then
cat <<'EOF'
default.replication.factor=3
min.insync.replicas=2
num.partitions=3
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
unclean.leader.election.enable=false
auto.create.topics.enable=false
confluent.cluster.link.enable=false
EOF
fi
# ---- 4.2.3.7 Audit(共用)
cat <<EOF
confluent.security.event.logger.enable=true
confluent.security.event.logger.exporter.kafka.bootstrap.servers=$(csv 9095)
confluent.security.event.logger.exporter.kafka.security.protocol=SASL_SSL
confluent.security.event.logger.exporter.kafka.sasl.mechanism=SCRAM-SHA-512
confluent.security.event.logger.exporter.kafka.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="confluent-audit" password="$AUDIT_PASSWORD";
confluent.security.event.logger.exporter.kafka.ssl.truststore.type=PKCS12
confluent.security.event.logger.exporter.kafka.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.security.event.logger.exporter.kafka.ssl.truststore.password=$SP
confluent.security.event.logger.exporter.kafka.topic.replicas=3
confluent.security.event.logger.exporter.kafka.topic.retention.ms=7776000000
EOF
cat <<'EOF'
confluent.security.event.router.config={"destinations":{"topics":{"confluent-audit-log-events":{"retention_ms":7776000000},"confluent-audit-log-events_sensitive":{"retention_ms":31536000000}}},"default_topics":{"allowed":"confluent-audit-log-events","denied":"confluent-audit-log-events"},"excluded_principals":["User:kafka-internal","User:svc-c3"],"routes":{"crn:///kafka=*/topic=payments.*":{"produce":{"allowed":"confluent-audit-log-events_sensitive","denied":"confluent-audit-log-events_sensitive"},"consume":{"allowed":"confluent-audit-log-events_sensitive","denied":"confluent-audit-log-events_sensitive"},"describe":{"allowed":"","denied":"confluent-audit-log-events_sensitive"}}}}
EOF
# ---- 4.2.3.8 Telemetry(共用);metrics.include 從手冊附錄(模板)原樣取
cat <<EOF
metric.reporters=io.confluent.telemetry.reporter.TelemetryReporter
confluent.telemetry.exporter._c3.type=http
confluent.telemetry.exporter._c3.enabled=true
$(grep '^confluent.telemetry.exporter._c3.metrics.include=' $S/manual/ref/telemetry.properties.tpl)
confluent.telemetry.exporter._c3.client.base.url=https://c3-01.poc.lab:9090/api/v1/otlp
confluent.telemetry.exporter._c3.client.compression=gzip
confluent.telemetry.exporter._c3.api.key=dummy
confluent.telemetry.exporter._c3.api.secret=dummy
confluent.telemetry.exporter._c3.https.ssl.keystore.type=PKCS12
confluent.telemetry.exporter._c3.https.ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
confluent.telemetry.exporter._c3.https.ssl.keystore.password=$SP
confluent.telemetry.exporter._c3.https.ssl.key.password=$SP
confluent.telemetry.exporter._c3.https.ssl.truststore.type=PKCS12
confluent.telemetry.exporter._c3.https.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.telemetry.exporter._c3.https.ssl.truststore.password=$SP
confluent.telemetry.exporter._c3.https.ssl.protocol=TLSv1.3
confluent.telemetry.exporter._c3.buffer.pending.batches.max=80
confluent.telemetry.exporter._c3.buffer.batch.items.max=4000
confluent.telemetry.exporter._c3.buffer.inflight.submissions.max=10
confluent.telemetry.metrics.collector.interval.ms=60000
confluent.telemetry.remoteconfig._confluent.enabled=false
confluent.telemetry.enabled=false
confluent.consumer.lag.emitter.enabled=true
EOF
} > $F
chmod 0600 $F
echo "$F: $(grep -c '=' $F) lines"
