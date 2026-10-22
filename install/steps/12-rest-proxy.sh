#!/usr/bin/env bash
# 第 12 站：REST Proxy —— 只接受 client 憑證，principal 對應規則只列走 REST 的 app（不加 DEFAULT）
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"; source "$D/lib/render.sh"
T=$D/templates; C=$PKI_DIR/certs

section "派送憑證"
for h in $RESTS; do
  rcp "$h" "$C/truststore.p12" "$C/cp-server.p12" "$C/svc-rest.p12" "$C/mds-token-public.pem" || { fail "$h: scp"; continue; }
  r=$(rsh "$h" 'sudo install -d -o root -g root -m 0755 /etc/confluent && sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka-rest && for f in truststore.p12 cp-server.p12 svc-rest.p12 mds-token-public.pem; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12 /tmp/mds-token-public.pem; sudo ls /etc/confluent/ssl | wc -l')
  [ "$r" = 4 ] && ok "$h: $r files" || fail "$h: $r files"
done

section "設定檔與 drop-in（principal 對應規則由 conf/apps.txt 的 cert 類 app 產生）"
REST_APPS=$(grep -v '^#' "$D/conf/apps.txt" | awk '$2=="cert"{print $1}' | paste -sd'|')
[ -n "$REST_APPS" ] || die "conf/apps.txt 沒有走 REST 的 app（auth=cert）"
export STORE_PASSWORD; STORE_PASSWORD=$(cat "$PKI_DIR/store.pass"); export BROKER_TOKEN MDS_URLS REST_VIP REST_APPS HEAP=$HEAP_REST
for h in $RESTS; do
  export HOST_FQDN; HOST_FQDN=$(fqdn "$h"); export REST_ID=$h
  render "$T/kafka-rest.tpl" "$CONF_DIR/$h.kafka-rest.properties" HOST_FQDN REST_ID STORE_PASSWORD BROKER_TOKEN MDS_URLS REST_VIP REST_APPS || { fail "$h: render"; continue; }
  render "$T/kafka-rest.dropin" "$CONF_DIR/$h.dropin" HEAP || { fail "$h: render dropin"; continue; }
  rcp "$h" "$CONF_DIR/$h.kafka-rest.properties" || { fail "$h: scp"; continue; }
  rsh "$h" 'sudo install -d -m 0755 /etc/systemd/system/confluent-kafka-rest.service.d && sudo tee /etc/systemd/system/confluent-kafka-rest.service.d/10-override.conf >/dev/null' < "$CONF_DIR/$h.dropin"
  r=$(rsh "$h" "sudo install -o root -g confluent -m 0640 /tmp/$h.kafka-rest.properties /etc/confluent/kafka-rest/kafka-rest.properties && rm -f /tmp/$h.kafka-rest.properties && sudo systemctl daemon-reload && printf 'config %s lines, unresolved=%s, exec=%s' \"\$(sudo grep -c . /etc/confluent/kafka-rest/kafka-rest.properties)\" \"\$(sudo grep -c '\\\${' /etc/confluent/kafka-rest/kafka-rest.properties)\" \"\$(systemctl show confluent-kafka-rest -p ExecStart --value | grep -o '/etc/[^ ]*properties')\"")
  [[ $r == *"unresolved=0, exec=/etc/confluent/kafka-rest/kafka-rest.properties" ]] && ok "$h: $r" || fail "$h: $r"
done
unset STORE_PASSWORD
[ "${FAILED:-0}" = 0 ] || die "設定或 drop-in 有問題，不啟動"

section "啟動（enable --now 不會重啟已在跑的服務，所以再 restart 一次）並測三種情況：legacy app 200、其他憑證 401、沒憑證被 TLS 拒絕"
for h in $RESTS; do r=$(rsh "$h" 'sudo systemctl enable --now confluent-kafka-rest >/dev/null 2>&1; sudo systemctl restart confluent-kafka-rest; systemctl is-active confluent-kafka-rest'); [ "$r" = active ] && ok "$h: $r" || fail "$h: $r"; done
sleep 40
APP=${REST_APPS%%|*}
for h in $RESTS; do
  u=https://$(fqdn "$h"):8082/v3/clusters
  for i in 1 2 3 4 5 6; do a=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --cert "$C/$APP.crt" --key "$PKI_DIR/keys/$APP.key" "$u"); [ "$a" = 200 ] && break; sleep 10; done
  o=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --cert "$C/svc-ops.crt" --key "$PKI_DIR/keys/svc-ops.key" "$u"); n=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$u")
  [ "$a $o $n" = "200 401 000" ] && ok "$h legacy-app=$a other-cert=$o no-cert=$n" || fail "$h legacy-app=$a other-cert=$o no-cert=$n（預期 200 401 000）"
done
lb=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --cert "$C/$APP.crt" --key "$PKI_DIR/keys/$APP.key" "https://$REST_VIP:8082/v3/clusters")
[ "$lb" = 200 ] && ok "via LB ($REST_VIP): $lb" || fail "via LB: $lb"
finish
