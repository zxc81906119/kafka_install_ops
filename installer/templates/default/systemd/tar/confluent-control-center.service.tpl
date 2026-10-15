# Managed by cpctl (tar strategy) - equivalent of the unit shipped in the C3 next-gen RPM.
[Unit]
Description=Confluent Control Center - tar install
Documentation=https://docs.confluent.io/
After=network-online.target prometheus.service alertmanager.service
Wants=network-online.target

[Service]
Type=simple
User=cp-control-center
Group=confluent
Environment="LOG_DIR=/var/log/confluent/control-center"
ExecStart=${C3_HOME}/bin/control-center-start /etc/confluent/control-center/control-center.properties
TimeoutStopSec=180
Restart=always
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
