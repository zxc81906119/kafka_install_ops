# Managed by cpctl (tar strategy) - equivalent of the unit shipped in the confluent-kafka-rest RPM.
[Unit]
Description=Confluent REST Proxy - tar install
Documentation=https://docs.confluent.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cp-kafka-rest
Group=confluent
Environment="LOG_DIR=/var/log/confluent/kafka-rest"
ExecStart=${CP_HOME}/bin/kafka-rest-start ${CP_HOME}/etc/kafka-rest/kafka-rest.properties
TimeoutStopSec=180
Restart=no

[Install]
WantedBy=multi-user.target
