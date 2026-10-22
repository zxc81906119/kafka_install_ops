#!/usr/bin/env bash
# 第 10 站：controller 與 broker —— 派送憑證、產生設定、systemd drop-in、格式化（只做一次）、啟動、看 quorum 與 MDS
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"; source "$D/lib/render.sh"
export JAVA_HOME=/opt/java/current
T=$D/templates; C=$PKI_DIR/certs

section "10.1 派送憑證（controller 4 個檔，broker 多 cp-server.p12；目錄 root:confluent 0750、檔案 0640）"
for h in $KAFKA_HOSTS; do
  case $h in kb*) extra=$C/cp-server.p12;; *) extra="";; esac
  rcp "$h" "$C/truststore.p12" "$C/kafka-internal.p12" "$PKI_DIR/keys/mds-token.key" "$C/mds-token-public.pem" $extra || { fail "$h: scp"; continue; }
  r=$(rsh "$h" 'sudo install -d -o root -g root -m 0755 /etc/confluent && sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka && for f in /tmp/truststore.p12 /tmp/kafka-internal.p12 /tmp/mds-token-public.pem /tmp/cp-server.p12; do [ -f $f ] && sudo install -o root -g confluent -m 0640 $f /etc/confluent/ssl/; done; sudo install -o root -g confluent -m 0640 /tmp/mds-token.key /etc/confluent/ssl/mds-token-keypair.pem; rm -f /tmp/*.p12 /tmp/mds-token*; sudo ls /etc/confluent/ssl | paste -sd" "')
  case $h in kb*) want=5;; *) want=4;; esac
  [ "$(wc -w <<<"$r")" = "$want" ] && ok "$h: $r" || fail "$h: $r"
done

section "10.2 設定檔：範本 + envsubst（密碼從檔案讀進變數，不出現在畫面上）"
install -d -m 0700 "$CONF_DIR"
export STORE_PASSWORD; STORE_PASSWORD=$(cat "$PKI_DIR/store.pass"); export LDAP_BIND_PASSWORD; LDAP_BIND_PASSWORD=$(cat "$SECRETS_DIR/ldap-bind.pass")
export CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN
VARS="HOST_FQDN NODE_ID RACK STORE_PASSWORD LDAP_BIND_PASSWORD CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN"
for h in $KAFKA_HOSTS; do
  id_var=NODE_ID_$h; rack_var=RACK_$h
  export HOST_FQDN; HOST_FQDN=$(fqdn "$h"); export NODE_ID=${!id_var} RACK=${!rack_var}
  case $h in kc*) tpl=$T/controller.tpl;; *) tpl=$T/broker.tpl;; esac
  # shellcheck disable=SC2086
  render_cat "$CONF_DIR/$h.server.properties" $VARS -- "$tpl" "$T/common.tpl" || { fail "$h: render"; continue; }
  rcp "$h" "$CONF_DIR/$h.server.properties" || { fail "$h: scp"; continue; }
  r=$(rsh "$h" "sudo install -o root -g confluent -m 0640 /tmp/$h.server.properties /etc/confluent/kafka/server.properties && rm -f /tmp/$h.server.properties && echo \"\$(sudo grep -c . /etc/confluent/kafka/server.properties) lines, unresolved=\$(sudo grep -c '\\\${' /etc/confluent/kafka/server.properties)\"")
  [[ $r == *"unresolved=0" ]] && ok "$h: $r" || fail "$h: $r"
done
unset STORE_PASSWORD LDAP_BIND_PASSWORD

section "10.3 systemd drop-in 與目錄（最後一定要看到 exec 指向我們的設定檔）"
for h in $KAFKA_HOSTS; do
  case $h in kc*) export HEAP=$HEAP_CONTROLLER;; *) export HEAP=$HEAP_BROKER;; esac
  render "$T/confluent-server.dropin" "$CONF_DIR/$h.dropin" HEAP || { fail "$h: render dropin"; continue; }
  rsh "$h" 'sudo install -d -m 0755 /etc/systemd/system/confluent-server.service.d && sudo tee /etc/systemd/system/confluent-server.service.d/10-override.conf >/dev/null' < "$CONF_DIR/$h.dropin"
  r=$(rsh "$h" "sudo systemctl daemon-reload && sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka/data && sudo install -d -o cp-kafka -g confluent -m 0755 /var/log/kafka && printf 'heap=%s exec=%s data=%s' $HEAP \"\$(systemctl show confluent-server -p ExecStart --value | grep -o '/etc/[^ ]*properties')\" \"\$(sudo stat -c %U:%G:%a /var/lib/kafka/data)\"")
  [[ $r == *"exec=/etc/confluent/kafka/server.properties data=cp-kafka:confluent:750" ]] && ok "$h: $r" || fail "$h: $r（drop-in 沒生效就會用 RPM 預設設定起來）"
done
[ "${FAILED:-0}" = 0 ] || die "設定或 drop-in 有問題，不啟動"

section "10.4 格式化（只做一次；meta.properties 已存在就略過）、啟動"
if [ ! -s "$CONF_DIR/kraft.env" ]; then
  (umask 077; { echo "CLUSTER_ID=$(kafka-storage random-uuid)"; for c in $CONTROLLERS; do echo "DIR_ID_$c=$(kafka-storage random-uuid)"; done; } > "$CONF_DIR/kraft.env")
  ok "新的 cluster id 與 controller directory id 寫到 $CONF_DIR/kraft.env"
fi
[ -s "$SECRETS_DIR/kafka-admin.pass" ] || (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS_DIR/kafka-admin.pass")
source "$CONF_DIR/kraft.env"
IC=$(for c in $CONTROLLERS; do v=DIR_ID_$c; id=NODE_ID_$c; printf '%s@%s:9093:%s,' "${!id}" "$(fqdn "$c")" "${!v}"; done | sed 's/,$//')
FMT='sudo -u cp-kafka env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml kafka-storage format --cluster-id '"$CLUSTER_ID"' --config /etc/confluent/kafka/server.properties'
for h in $CONTROLLERS; do
  if rsh "$h" 'sudo test -f /var/lib/kafka/data/meta.properties'; then ok "$h: 已格式化，略過"; continue; fi
  rcp "$h" "$SECRETS_DIR/kafka-admin.pass" || { fail "$h: scp"; continue; }
  r=$(rsh "$h" "P=\$(cat /tmp/kafka-admin.pass); rm -f /tmp/kafka-admin.pass; $FMT --initial-controllers $IC --add-scram \"SCRAM-SHA-512=[name=kafka-admin,password=\$P]\" 2>&1 | grep -v -i scram | tail -1; echo \"cluster.id=\$(sudo sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)\"")
  [[ $r == *"cluster.id=$CLUSTER_ID" ]] && ok "$h: $r" || fail "$h: $r"
done
for h in $BROKERS; do
  if rsh "$h" 'sudo test -f /var/lib/kafka/data/meta.properties'; then ok "$h: 已格式化，略過"; continue; fi
  r=$(rsh "$h" "$FMT --no-initial-controllers 2>&1 | tail -1; echo \"cluster.id=\$(sudo sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties) node.id=\$(sudo sed -n 's/^node.id=//p' /var/lib/kafka/data/meta.properties)\"")
  [[ $r == *"cluster.id=$CLUSTER_ID node.id="* ]] && ok "$h: $r" || fail "$h: $r"
done
[ "${FAILED:-0}" = 0 ] || die "格式化失敗"

P=$(cat "$PKI_DIR/store.pass")
(umask 077; cat > "$CONF_DIR/client-internal.properties" <<EOF
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=$C/kafka-internal.p12
ssl.keystore.password=$P
ssl.key.password=$P
ssl.truststore.type=PKCS12
ssl.truststore.location=$C/truststore.p12
ssl.truststore.password=$P
ssl.endpoint.identification.algorithm=https
EOF
); unset P

for h in $CONTROLLERS; do r=$(rsh "$h" 'sudo systemctl enable --now confluent-server >/dev/null 2>&1; sleep 1; systemctl is-active confluent-server'); [ "$r" = active ] && ok "$h: $r" || fail "$h: $r（sudo journalctl -u confluent-server -n 50）"; done
sleep 20
q=$(kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" --command-config "$CONF_DIR/client-internal.properties" describe --status 2>/dev/null | grep -E "LeaderId|CurrentVoters")
grep -q 'LeaderId: *[1-9]' <<<"$q" && ok "quorum：$(tr -s ' ' <<<"$q" | paste -sd';' | cut -c1-160)" || die "controller quorum 沒有 leader：$q"

for h in $BROKERS; do r=$(rsh "$h" 'sudo systemctl enable --now confluent-server >/dev/null 2>&1; sleep 1; systemctl is-active confluent-server'); [ "$r" = active ] && ok "$h: $r" || fail "$h: $r"; done
log "等 broker 註冊與 MDS 起來（約 45 秒）"; sleep 45
obs=$(kafka-metadata-quorum --bootstrap-controller "$(fqdn "${CONTROLLERS%% *}"):9093" --command-config "$CONF_DIR/client-internal.properties" describe --status 2>/dev/null | grep CurrentObservers | grep -o '"id": [0-9]*' | wc -l)
[ "$obs" = "$(wc -w <<<"$BROKERS")" ] && ok "CurrentObservers：$obs 台 broker" || fail "CurrentObservers 只有 $obs 台"
for h in $BROKERS; do
  for i in 1 2 3 4 5 6; do c=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$(fqdn "$h"):8090/v1/metadata/id"); [ "$c" = 200 ] && break; sleep 10; done
  [ "$c" = 200 ] && ok "$h MDS=200" || fail "$h MDS=$c"
done
finish
