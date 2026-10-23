#!/usr/bin/env bash
# 第 13 站：Control Center —— 內建 Prometheus、Alertmanager（mTLS、吃 PEM）與 C3（人員用 AD 帳密登入）
# where: ops02 （cpadmin）
#
# 做什麼：派送憑證 → Prometheus／Alertmanager 的 TLS 與設定（*-generated.yml 要給 C3 自己能寫）
#         → control-center.tpl 產生設定 → drop-in（含「等 MDS 起來才啟動」：C3 比 MDS 先起來會卡住不開 9021）
#         → 依序啟動 prometheus、alertmanager、C3，等 UI 回 200。
# 重跑：安全。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"

section "派送憑證（Prometheus／Alertmanager 是 Go 程式，吃 PEM：cp-server.crt／.key、ca.pem）"
copy_to_tmp "$C3_HOST" "$CERTS_DIR/truststore.p12" "$CERTS_DIR/cp-server.p12" "$CERTS_DIR/cp-server.crt" "$KEYS_DIR/cp-server.key" \
  "$CERTS_DIR/bank-root.pem" "$CERTS_DIR/svc-c3.p12" "$CERTS_DIR/mds-token-public.pem" || die "scp 失敗"
file_count=$(ssh_script "$C3_HOST" <<'EOF'
sudo install -d -o root -g root -m 0755 /etc/confluent
sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/control-center
for file in truststore.p12 cp-server.p12 cp-server.crt cp-server.key svc-c3.p12 mds-token-public.pem; do
  sudo install -o root -g confluent -m 0640 /tmp/$file /etc/confluent/ssl/
done
sudo install -o root -g confluent -m 0640 /tmp/bank-root.pem /etc/confluent/ssl/ca.pem
rm -f /tmp/*.p12 /tmp/cp-server.* /tmp/bank-root.pem /tmp/mds-token-public.pem
sudo ls /etc/confluent/ssl | wc -l
EOF
)
if [ "$file_count" = 7 ]; then ok "$C3_HOST: 7 files"; else die "$C3_HOST: $file_count files（預期 7）"; fi

section "Prometheus、Alertmanager 的 TLS（要求 client 憑證）與設定"
export C3_FQDN
render_template "$TEMPLATE_DIR/prometheus-generated.yml" "$CONF_DIR/prometheus-generated.yml" C3_FQDN || die "render prometheus-generated.yml"
copy_to_tmp "$C3_HOST" "$TEMPLATE_DIR/web-config-prom.yml" "$CONF_DIR/prometheus-generated.yml" "$TEMPLATE_DIR/prometheus.dropin" || die "scp"
generated_owner=$(ssh_script "$C3_HOST" <<'EOF'
cd /etc/confluent-control-center || exit 1
sudo install -o root -g confluent -m 0640 /tmp/web-config-prom.yml web-config-prom.yml
sudo install -o root -g confluent -m 0640 /tmp/web-config-prom.yml web-config-am.yml        # Alertmanager 用同一份 TLS 設定
sudo install -o root -g confluent -m 0640 /tmp/prometheus-generated.yml prometheus-generated.yml
# 這四個檔 C3 啟動時自己會寫：擁有者不是 cp-control-center 就會 AccessDeniedException
for file in alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml; do
  sudo chown cp-control-center:confluent $file
  sudo chmod 0640 $file
done
sudo install -d -m 0755 /etc/systemd/system/prometheus.service.d
sudo install -m 0644 /tmp/prometheus.dropin /etc/systemd/system/prometheus.service.d/10-override.conf
rm -f /tmp/web-config-prom.yml /tmp/prometheus-generated.yml /tmp/prometheus.dropin
sudo systemctl daemon-reload
sudo stat -c %U alertmanager-generated.yml
EOF
)
if [ "$generated_owner" = cp-control-center ]; then ok "$C3_HOST: prometheus config ok（generated 檔屬 $generated_owner）"; else die "$C3_HOST: $generated_owner"; fi

section "C3 設定檔與 drop-in"
export STORE_PASSWORD BROKER_TOKEN MDS_URLS HEAP=$HEAP_C3 MDS_FIRST=$FIRST_BROKER
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
render_template "$TEMPLATE_DIR/control-center.tpl" "$CONF_DIR/$C3_HOST.control-center.properties" STORE_PASSWORD BROKER_TOKEN MDS_URLS C3_FQDN \
  || die "render control-center.properties"
unset STORE_PASSWORD
render_template "$TEMPLATE_DIR/control-center.dropin" "$CONF_DIR/$C3_HOST.dropin" HEAP MDS_FIRST || die "render dropin"
copy_to_tmp "$C3_HOST" "$CONF_DIR/$C3_HOST.control-center.properties" "$CONF_DIR/$C3_HOST.dropin" || die "scp"
result=$(ssh_script "$C3_HOST" HOST="$C3_HOST" <<'EOF'
props=/etc/confluent/control-center/control-center.properties
sudo install -o root -g confluent -m 0640 /tmp/$HOST.control-center.properties $props
sudo install -d -o cp-control-center -g confluent -m 0750 /var/lib/confluent/control-center
sudo install -d -m 0755 /etc/systemd/system/confluent-control-center.service.d
sudo install -m 0644 /tmp/$HOST.dropin /etc/systemd/system/confluent-control-center.service.d/10-override.conf
rm -f /tmp/$HOST.control-center.properties /tmp/$HOST.dropin
sudo systemctl daemon-reload
exec_file=$(systemctl show confluent-control-center -p ExecStart --value | grep -o '/etc/[^ ]*properties')
echo "unresolved=$(sudo grep -c '${' $props) exec=$exec_file"
EOF
)
if [ "$result" = "unresolved=0 exec=/etc/confluent/control-center/control-center.properties" ]; then ok "$C3_HOST: $result"; else die "$C3_HOST: $result"; fi

section "依序啟動，等 UI（第一次 30–120 秒；冷開機要等 MDS 可能到 3 分鐘）"
states=$(ssh_script "$C3_HOST" <<'EOF'
for unit in prometheus alertmanager confluent-control-center; do
  sudo systemctl enable --now $unit >/dev/null 2>&1
  sudo systemctl restart $unit
  sleep 3
  printf '%s=%s ' $unit "$(systemctl is-active $unit)"
done
EOF
)
log "$states"
prometheus_ready=$(curl -s -o /dev/null -m 10 -w '%{http_code}' --cert "$CERTS_DIR/cp-server.crt" --key "$KEYS_DIR/cp-server.key" "https://$C3_FQDN:9090/-/ready")
if [ "$prometheus_ready" = 200 ]; then ok "prometheus=$prometheus_ready"; else fail "prometheus=$prometheus_ready"; fi
for attempt in $(seq 1 30); do
  c3_ui=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$C3_FQDN:9021/")
  [ "$c3_ui" = 200 ] && break
  sleep 10
done
if [ "$c3_ui" = 200 ]; then ok "c3 ui=200，約 $((attempt * 10)) 秒"; else fail "c3 ui=$c3_ui（sudo journalctl -u confluent-control-center -n 100）"; fi
log "瀏覽器開 https://$C3_FQDN:9021（lab：https://localhost:19021），用 alice 登入（密碼在 $SECRETS_DIR/ad-test-users.pass）"
finish_step
