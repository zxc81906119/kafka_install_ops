############################# TLS defaults: shared internal certificate (CONTROLLER / INTERNAL) #############################
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
ssl.keystore.password=${STORE_PASSWORD}
ssl.key.password=${STORE_PASSWORD}
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ssl.truststore.password=${STORE_PASSWORD}
ssl.client.auth=required
ssl.endpoint.identification.algorithm=https
ssl.enabled.protocols=TLSv1.3,TLSv1.2
# Java prints the DN in RFC 2253 order (C=..,O=..,CN=..): match CN anywhere
ssl.principal.mapping.rules=RULE:.*CN=([a-zA-Z0-9._-]+).*$/$1/,DEFAULT

############################# Authorization (RBAC via MDS + KRaft ACLs) #############################
authorizer.class.name=io.confluent.kafka.security.authorizer.ConfluentServerAuthorizer
confluent.authorizer.access.rule.providers=KRAFT_ACL,CONFLUENT
super.users=${SUPER_USERS}
allow.everyone.if.no.acl.found=false
confluent.metadata.server.token.key.path=/etc/confluent/ssl/mds-token-keypair.enc.pem
confluent.metadata.server.token.key.passphrase=${MDS_TOKEN_PASSPHRASE}
confluent.metadata.topic.replication.factor=3

############################# License #############################
${LICENSE_LINE}
confluent.license.topic.replication.factor=3

############################# Self-Balancing Clusters #############################
confluent.balancer.enable=true
confluent.balancer.topic.replication.factor=3
