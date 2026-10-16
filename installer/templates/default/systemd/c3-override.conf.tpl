# Managed by cpctl - drop-in for the RPM-provided ${UNIT}.service
[Service]
# Cold start of the whole site (power outage): C3 started before MDS gets stuck ("client has already been closed")
# and never opens :9021. Wait for any MDS (max 5 min), then start anyway. $$ = literal $ for the shell (systemd).
ExecStartPre=/bin/sh -c 'for i in $$(seq 1 60); do for u in $$(echo "${MDS_URLS}" | tr , " "); do curl -fs --max-time 5 --cacert /etc/confluent/ssl/ca.pem -o /dev/null "$$u/v1/metadata/id" && exit 0; done; sleep 5; done; echo "MDS not reachable after 5 min - starting anyway"; exit 0'
TimeoutStartSec=420
ExecStart=
ExecStart=${C3_BIN_DIR}/control-center-start ${CONFIG_FILE}
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="CONTROL_CENTER_HEAP_OPTS=-Xms${HEAP} -Xmx${HEAP}"
EnvironmentFile=-/etc/confluent/${COMPONENT}/service.env
LimitNOFILE=65536
Restart=on-failure
RestartSec=10
