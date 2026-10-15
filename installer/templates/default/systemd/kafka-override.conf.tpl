# Managed by cpctl - drop-in for the RPM-provided ${UNIT}.service
[Service]
ExecStart=
ExecStart=${BIN_DIR}/kafka-server-start ${CONFIG_FILE}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="KAFKA_HEAP_OPTS=-Xms${HEAP} -Xmx${HEAP}"
Environment="KAFKA_LOG4J_OPTS=-Dlog4j2.configurationFile=${KAFKA_ETC}/log4j2.yaml"
Environment="LOG_DIR=/var/log/kafka"
Environment="KAFKA_OPTS=${JMX_AGENT_OPTS}"
EnvironmentFile=-/etc/confluent/${COMPONENT}/service.env
LimitNOFILE=128000
TimeoutStopSec=180
Restart=on-failure
RestartSec=10
