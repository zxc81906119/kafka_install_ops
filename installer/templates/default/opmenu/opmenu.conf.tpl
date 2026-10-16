# Managed by cpctl - OP menu on the bastion ${JUMP_FQDN}. Do not edit by hand (changes are overwritten).
# Scenario: bastion and nodes use fixed accounts (not joined to AD). The OS account is shared, so it is NOT the
# identity: operators log in to the menu with their own AD credentials (verified by MDS). Kafka RBAC decides Kafka
# actions; host actions are gated by MDS authorize (OPMENU_HOST_ACTION_AUTHZ) before the shared node account is used.
OPMENU_BACKEND=vm
OPMENU_ENV_LABEL=${OPMENU_ENV_LABEL}
OPMENU_LOG=/var/log/opmenu/opmenu.log
OPMENU_OUT_DIR=/var/log/opmenu
OPMENU_SYSLOG=1
OPMENU_ALLOW_ENV_OVERRIDE=0

# Kafka: LDAP listener (SASL PLAIN -> AD) with the operator's own credentials; MDS on every broker
OPMENU_BOOTSTRAP='${OPMENU_LDAP_BOOTSTRAP}'
OPMENU_MDS_URL='${MDS_URLS}'
OPMENU_KAFKA_CLUSTER_ID='${CLUSTER_ID}'
OPMENU_CERT_DIR=/etc/opmenu/certs

# Allowlists for restart and ssh (from the inventory, reviewed through change management)
OPMENU_BROKER_SERVICES='${OPMENU_BROKER_SERVICES}'
OPMENU_AUX_SERVICES='${OPMENU_AUX_SERVICES}'
OPMENU_CONTROLLER_HOSTS='${OPMENU_CONTROLLER_HOSTS}'
OPMENU_DATA_DIR=/var/lib/kafka/data

# Fixed accounts
OPMENU_USER_FROM_OS=0
OPMENU_SSH_USER=${OPMENU_NODE_USER}
OPMENU_SSH_AUTH=key
OPMENU_HOST_ACTION_AUTHZ='Topic:__opmenu-host-ops:Describe'

# Policy
OPMENU_TICKET_MODE=${OPMENU_TICKET_MODE}
OPMENU_TICKET_CHECK=format
OPMENU_CHANGE_WINDOW='${OPMENU_CHANGE_WINDOW}'
OPMENU_IDLE_TIMEOUT=900
OPMENU_AUDIT_TOPIC=confluent-audit-log-events

# Break-glass (item 91): certificate identity over the INTERNAL listener, used only through opmenu-bootstrap
OPMENU_BREAKGLASS_BOOTSTRAP='${BROKER_INTERNAL_BOOTSTRAP}'

# Kafka CLI tools of the installed Confluent Platform (install strategy: ${INSTALL_METHOD})
export PATH="${BIN_DIR}:$PATH" JAVA_HOME="${JAVA_HOME}"
