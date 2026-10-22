item 19 1 n n "查看生效中的設定(effective configuration)" "每個值的來源:conf = opmenu.conf、derived = 自動推算、default = 預設"
run() {
  local n v
  for n in ENV_LABEL BOOTSTRAP MDS_URL BREAKGLASS_BOOTSTRAP KAFKA_CLUSTER_ID CERT_DIR TRUSTSTORE CA_PEM CONTROLLER_HOSTS BROKER_SERVICES AUX_SERVICES HOSTS DATA_DIR REPLICATION SSH_USER KNOWN_HOSTS SECRETS CONJUR_URL CONJUR_IDENTITY SSH_KEY_SECRET BREAKGLASS_SECRET CHANGE_WINDOW; do
    v="OPMENU_$n"; printf '%-22s %-9s %s\n' "$n" "${OP_SRC[$v]:-default}" "${!v:-(empty)}"
  done
}
