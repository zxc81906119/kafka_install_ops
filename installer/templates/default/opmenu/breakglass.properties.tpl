# Managed by cpctl - OP menu break-glass identity (INTERNAL listener, mTLS; RBAC SystemAdmin). Readable by opbootstrap only.
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/opmenu/bootstrap/breakglass.p12
ssl.keystore.password=${OPMENU_BREAKGLASS_STORE_PASSWORD}
ssl.key.password=${OPMENU_BREAKGLASS_STORE_PASSWORD}
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/opmenu/bootstrap/truststore.p12
ssl.truststore.password=${OPMENU_TRUSTSTORE_PASSWORD}
ssl.endpoint.identification.algorithm=https
