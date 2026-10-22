#!/usr/bin/env bash
# 第 13 站：Control Center —— 內建 Prometheus、Alertmanager（mTLS、PEM）與 C3（AD 帳密登入，等 MDS 起來才啟動）
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"; source "$D/lib/render.sh"
T=$D/templates; C=$PKI_DIR/certs; h=$C3_HOST

section "派送憑證（Prometheus/Alertmanager 是 Go 程式，吃 PEM）"
rcp "$h" "$C/truststore.p12" "$C/cp-server.p12" "$C/cp-server.crt" "$PKI_DIR/keys/cp-server.key" "$C/bank-root.pem" "$C/svc-c3.p12" "$C/mds-token-public.pem" || die "scp 失敗"
r=$(rsh "$h" 'sudo install -d -o root -g root -m 0755 /etc/confluent && sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/control-center && for f in truststore.p12 cp-server.p12 cp-server.crt cp-server.key svc-c3.p12 mds-token-public.pem; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; sudo install -o root -g confluent -m 0640 /tmp/bank-root.pem /etc/confluent/ssl/ca.pem; rm -f /tmp/*.p12 /tmp/cp-server.* /tmp/bank-root.pem /tmp/mds-token-public.pem; sudo ls /etc/confluent/ssl | wc -l')
[ "$r" = 7 ] && ok "$h: $r files" || die "$h: $r files（預期 7）"

section "Prometheus、Alertmanager 的 TLS 與設定；*-generated.yml 是 C3 自己會寫的檔，擁有者要是 cp-control-center"
export C3_FQDN; render "$T/prometheus-generated.yml" "$CONF_DIR/prometheus-generated.yml" C3_FQDN || die "render prometheus-generated"
rcp "$h" "$T/web-config-prom.yml" "$CONF_DIR/prometheus-generated.yml" "$T/prometheus.dropin" || die "scp"
r=$(rsh "$h" 'cd /etc/confluent-control-center && sudo install -o root -g confluent -m 0640 /tmp/web-config-prom.yml web-config-prom.yml && sudo install -o root -g confluent -m 0640 /tmp/web-config-prom.yml web-config-am.yml && sudo install -o root -g confluent -m 0640 /tmp/prometheus-generated.yml prometheus-generated.yml && sudo chown cp-control-center:confluent alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml && sudo chmod 0640 alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml && sudo install -d -m 0755 /etc/systemd/system/prometheus.service.d && sudo install -m 0644 /tmp/prometheus.dropin /etc/systemd/system/prometheus.service.d/10-override.conf && rm -f /tmp/web-config-prom.yml /tmp/prometheus-generated.yml /tmp/prometheus.dropin && sudo systemctl daemon-reload && sudo stat -c "%U" alertmanager-generated.yml')
[ "$r" = cp-control-center ] && ok "$h: prometheus config ok（generated 檔屬 $r）" || die "$h: $r"

section "C3 設定檔與 drop-in（ExecStartPre 等 MDS：C3 比 MDS 先起來會卡住不開 9021）"
export STORE_PASSWORD; STORE_PASSWORD=$(cat "$PKI_DIR/store.pass"); export BROKER_TOKEN MDS_URLS HEAP=$HEAP_C3; export MDS_FIRST; MDS_FIRST=$(fqdn "${BROKERS%% *}")
render "$T/control-center.tpl" "$CONF_DIR/$h.control-center.properties" STORE_PASSWORD BROKER_TOKEN MDS_URLS C3_FQDN || die "render control-center"
render "$T/control-center.dropin" "$CONF_DIR/$h.dropin" HEAP MDS_FIRST || die "render dropin"
unset STORE_PASSWORD
rcp "$h" "$CONF_DIR/$h.control-center.properties" "$CONF_DIR/$h.dropin" || die "scp"
r=$(rsh "$h" "sudo install -o root -g confluent -m 0640 /tmp/$h.control-center.properties /etc/confluent/control-center/control-center.properties && sudo install -d -o cp-control-center -g confluent -m 0750 /var/lib/confluent/control-center && sudo install -d -m 0755 /etc/systemd/system/confluent-control-center.service.d && sudo install -m 0644 /tmp/$h.dropin /etc/systemd/system/confluent-control-center.service.d/10-override.conf && rm -f /tmp/$h.control-center.properties /tmp/$h.dropin && sudo systemctl daemon-reload && printf 'config %s lines, unresolved=%s, exec=%s' \"\$(sudo grep -c . /etc/confluent/control-center/control-center.properties)\" \"\$(sudo grep -c '\\\${' /etc/confluent/control-center/control-center.properties)\" \"\$(systemctl show confluent-control-center -p ExecStart --value | grep -o '/etc/[^ ]*properties')\"")
[[ $r == *"unresolved=0, exec=/etc/confluent/control-center/control-center.properties" ]] && ok "$h: $r" || die "$h: $r"

section "依序啟動，等 UI（第一次 30–120 秒；冷開機等 MDS 可能到 3 分鐘）"
rsh "$h" 'for u in prometheus alertmanager confluent-control-center; do sudo systemctl enable --now $u >/dev/null 2>&1; sudo systemctl restart $u; sleep 3; printf "%s=%s " $u "$(systemctl is-active $u)"; done' | tee -a "$LOG_FILE"; echo
p=$(curl -s -o /dev/null -m 10 -w '%{http_code}' --cert "$C/cp-server.crt" --key "$PKI_DIR/keys/cp-server.key" "https://$C3_FQDN:9090/-/ready"); [ "$p" = 200 ] && ok "prometheus=$p" || fail "prometheus=$p"
for i in $(seq 1 30); do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$C3_FQDN:9021/"); [ "$c" = 200 ] && break; sleep 10; done
[ "$c" = 200 ] && ok "c3 ui=$c after ~$((i*10))s" || fail "c3 ui=$c（sudo journalctl -u confluent-control-center -n 100）"
log "瀏覽器開 https://$C3_FQDN:9021（lab：https://localhost:19021），用 alice 登入（密碼在 $SECRETS_DIR/ad-test-users.pass）"
finish
