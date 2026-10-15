# Managed by cpctl (tar strategy) - embedded Alertmanager of Control Center.
[Unit]
Description=Alertmanager (Control Center) - tar install
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=cp-control-center
Group=confluent
Environment="CONFIG_PATH=/etc/confluent-control-center"
Environment="LOG_PATH=/var/log/confluent/control-center"
Environment="DATA_PATH=/var/lib/confluent/control-center/alertmanager/"
ExecStart=/bin/bash ${C3_HOME}/bin/alertmanager-start
TimeoutStopSec=180
Restart=always

[Install]
WantedBy=multi-user.target
