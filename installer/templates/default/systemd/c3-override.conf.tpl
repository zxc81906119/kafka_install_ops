# Managed by cpctl - drop-in for the RPM-provided ${UNIT}.service
[Service]
ExecStart=
ExecStart=/usr/bin/control-center-start ${CONFIG_FILE}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="CONTROL_CENTER_HEAP_OPTS=-Xms${HEAP} -Xmx${HEAP}"
EnvironmentFile=-/etc/confluent/${COMPONENT}/service.env
LimitNOFILE=65536
Restart=on-failure
RestartSec=10
