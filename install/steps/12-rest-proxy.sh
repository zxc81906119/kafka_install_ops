#!/usr/bin/env bash
# 第 12 站：REST Proxy —— 只接受 client 憑證；principal 對應規則只列走 REST 的 app（不加 DEFAULT）
# where: ops02 （cpadmin）
#
# 做什麼：派送憑證 → kafka-rest.tpl 產生設定（principal 規則由 conf/apps.txt 的 cert 類 app 組成）
#         → drop-in → 啟動並測三種情況：legacy app 憑證 200、其他憑證 401、沒憑證 TLS 就拒絕（000）→ 經負載平衡 200。
# 重跑：安全。第 15 站做過（Secret Protection）就照樣加密。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"
[ -n "$REST_APPS" ] || die "conf/apps.txt 沒有走 REST 的 app（第二欄 cert）"

section "派送憑證"
for host in $RESTS; do
  copy_to_tmp "$host" "$CERTS_DIR/truststore.p12" "$CERTS_DIR/cp-server.p12" "$CERTS_DIR/svc-rest.p12" "$CERTS_DIR/mds-token-public.pem" \
    || { fail "$host: scp"; continue; }
  file_count=$(ssh_script "$host" <<'EOF'
sudo install -d -o root -g root -m 0755 /etc/confluent
sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka-rest
for file in truststore.p12 cp-server.p12 svc-rest.p12 mds-token-public.pem; do
  sudo install -o root -g confluent -m 0640 /tmp/$file /etc/confluent/ssl/
done
rm -f /tmp/*.p12 /tmp/mds-token-public.pem
sudo ls /etc/confluent/ssl | wc -l
EOF
)
  if [ "$file_count" = 4 ]; then ok "$host: 4 files"; else fail "$host: $file_count files"; fi
done

section "設定檔與 drop-in"
export STORE_PASSWORD HOST_FQDN REST_ID HEAP=$HEAP_REST
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
export BROKER_TOKEN MDS_URLS REST_VIP REST_APPS
# 第 15 站做過的話（Secret Protection），產生的明文設定先照第 15 站加密，共用的密文檔一起派送
secrets_mode=$(secrets_mode_in_use)
extra_files=(); [ "$secrets_mode" = sp ] && extra_files=("$SECRETS_DIR/security.properties")
log "密碼放法：$secrets_mode"
for host in $RESTS; do
  HOST_FQDN=$(fqdn "$host"); REST_ID=$host
  render_template "$TEMPLATE_DIR/kafka-rest.tpl" "$CONF_DIR/$host.kafka-rest.properties" \
    HOST_FQDN REST_ID STORE_PASSWORD BROKER_TOKEN MDS_URLS REST_VIP REST_APPS || { fail "$host: render"; continue; }
  protect_rendered_props "$CONF_DIR/$host.kafka-rest.properties" || { fail "$host: 密碼處理（$secrets_mode）"; continue; }
  render_template "$TEMPLATE_DIR/kafka-rest.dropin" "$CONF_DIR/$host.dropin" HEAP || { fail "$host: render dropin"; continue; }
  copy_to_tmp "$host" "$CONF_DIR/$host.kafka-rest.properties" "$CONF_DIR/$host.dropin" "${extra_files[@]}" || { fail "$host: scp"; continue; }
  # unresolved：還留著 ${…} 的行，config provider 的參照（securepass）不算
  result=$(ssh_script "$host" HOST="$host" <<'EOF'
sudo install -o root -g confluent -m 0640 /tmp/$HOST.kafka-rest.properties /etc/confluent/kafka-rest/kafka-rest.properties
if [ -f /tmp/security.properties ]; then
  sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets
  sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && rm -f /tmp/security.properties
fi
sudo install -d -m 0755 /etc/systemd/system/confluent-kafka-rest.service.d
sudo install -m 0644 /tmp/$HOST.dropin /etc/systemd/system/confluent-kafka-rest.service.d/10-override.conf
rm -f /tmp/$HOST.kafka-rest.properties /tmp/$HOST.dropin
sudo systemctl daemon-reload
props=/etc/confluent/kafka-rest/kafka-rest.properties
exec_file=$(systemctl show confluent-kafka-rest -p ExecStart --value | grep -o '/etc/[^ ]*properties')
echo "unresolved=$(sudo grep '\${' $props | grep -vc '\${securepass:') exec=$exec_file"
EOF
)
  if [ "$result" = "unresolved=0 exec=/etc/confluent/kafka-rest/kafka-rest.properties" ]; then ok "$host: $result"; else fail "$host: $result"; fi
done
unset STORE_PASSWORD
[ "$FAIL_COUNT" = 0 ] || die "設定或 drop-in 有問題，不啟動"

section "啟動（enable --now 不會重啟已在跑的服務，所以再 restart 一次）"
for host in $RESTS; do
  state=$(ssh_run "$host" 'sudo systemctl enable --now confluent-kafka-rest >/dev/null 2>&1; sudo systemctl restart confluent-kafka-rest; systemctl is-active confluent-kafka-rest')
  if [ "$state" = active ]; then ok "$host: $state"; else fail "$host: $state"; fi
done
sleep 40

section "三種情況：legacy app 憑證 200、其他憑證（svc-ops）401、沒憑證 000（TLS 直接拒絕）"
for host in $RESTS; do
  url=https://$(fqdn "$host"):8082/v3/clusters
  for attempt in 1 2 3 4 5 6; do
    with_app_cert=$(rest_app_curl -s -o /dev/null -m 30 -w '%{http_code}' "$url")
    [ "$with_app_cert" = 200 ] && break
    sleep 10
  done
  with_other_cert=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --cert "$CERTS_DIR/svc-ops.crt" --key "$KEYS_DIR/svc-ops.key" "$url")
  without_cert=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url")
  summary="legacy-app=$with_app_cert other-cert=$with_other_cert no-cert=$without_cert"
  if [ "$with_app_cert $with_other_cert $without_cert" = "200 401 000" ]; then ok "$host $summary"; else fail "$host $summary（預期 200 401 000）"; fi
done
via_lb=$(rest_app_curl -s -o /dev/null -m 30 -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters")
if [ "$via_lb" = 200 ]; then ok "經負載平衡（$REST_VIP）: $via_lb"; else fail "經負載平衡: $via_lb"; fi

section "12.1 之後重啟 REST Proxy 用的小腳本（先由 LB 團隊停用那一台，見手把手 12.1）"
install -m 0700 "$TEMPLATE_DIR/rest-restart.sh" "$CONF_DIR/rest-restart.sh" && ok "$CONF_DIR/rest-restart.sh"
finish_step
