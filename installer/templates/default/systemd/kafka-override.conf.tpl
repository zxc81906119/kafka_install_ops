# Managed by cpctl - drop-in for the RPM-provided ${UNIT}.service
[Service]
ExecStart=
ExecStart=/usr/bin/kafka-server-start ${CONFIG_FILE}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="KAFKA_HEAP_OPTS=-Xms${HEAP} -Xmx${HEAP}"
Environment="KAFKA_LOG4J_OPTS=-Dlog4j2.configurationFile=/etc/kafka/log4j2.yaml"
Environment="LOG_DIR=/var/log/kafka"
EnvironmentFile=-/etc/confluent/${COMPONENT}/service.env
LimitNOFILE=128000
TimeoutStopSec=180
Restart=on-failure
RestartSec=10
