# Managed by cpctl - drop-in for the RPM-provided ${UNIT}.service
[Service]
Environment="METRICS_RETENTION_DAYS=${PROM_RETENTION}"
Environment="PROMETHEUS_HOST=0.0.0.0"
Environment="PROMETHEUS_PORT=${PORT_PROMETHEUS}"
