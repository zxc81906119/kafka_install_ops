# Managed by cpctl (tar strategy) - equivalent of the unit shipped in the confluent-server RPM.
# ExecStart / heap / JAVA_HOME come from the drop-in confluent-server.service.d/10-cpctl.conf
[Unit]
Description=Confluent Server (Apache Kafka) - tar install
Documentation=https://docs.confluent.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cp-kafka
Group=confluent
ExecStart=${CP_HOME}/bin/kafka-server-start ${CP_HOME}/etc/kafka/server.properties
TimeoutStopSec=180
Restart=no

[Install]
WantedBy=multi-user.target
