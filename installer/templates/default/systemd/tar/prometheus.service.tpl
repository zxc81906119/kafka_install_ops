# Managed by cpctl (tar strategy) - embedded Prometheus of Control Center.
# The start script would otherwise keep config/data INSIDE the versioned install dir (lost on upgrade):
# point it at the same locations the RPM uses.
[Unit]
Description=Prometheus (Control Center) - tar install
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=cp-control-center
Group=confluent
Environment="CONFIG_PATH=/etc/confluent-control-center"
Environment="LOG_PATH=/var/log/confluent/control-center"
Environment="TSDB_PATH=/var/lib/confluent/control-center/prometheus/data"
ExecStart=/bin/bash ${C3_HOME}/bin/prometheus-start
TimeoutStopSec=180
Restart=always

[Install]
WantedBy=multi-user.target
