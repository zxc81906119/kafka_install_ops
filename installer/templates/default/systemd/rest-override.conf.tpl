# Managed by cpctl - drop-in for the RPM-provided ${UNIT}.service
[Service]
ExecStart=
ExecStart=/usr/bin/kafka-rest-start ${CONFIG_FILE}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="KAFKAREST_HEAP_OPTS=-Xms${HEAP} -Xmx${HEAP}"
EnvironmentFile=-/etc/confluent/${COMPONENT}/service.env
LimitNOFILE=65536
Restart=on-failure
RestartSec=10
