#!/usr/bin/env bash
# 第 20 站：驗收與收尾 —— 一次跑完、結果能附在驗收文件裡：平台健康、安全（正反向）、應用程式端、維運；最後列出要收的東西
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
C=$PKI_DIR/certs; CA=/etc/pki/ca-trust/source/anchors/bank-root.pem; ADMIN=$CONF_DIR/client-admin.properties
B1=$(fqdn "${BROKERS%% *}"); KC1=$(fqdn "${CONTROLLERS%% *}"); R1=$(fqdn "${RESTS%% *}")
REST_APPS=$(grep -v '^#' "$D/conf/apps.txt" | awk '$2=="cert"{print $1}' | paste -sd'|'); APP=${REST_APPS%%|*}
SCRAM1=$(grep -v '^#' "$D/conf/apps.txt" | awk '$2=="scram"{print $1; exit}')
MODE=$(cat "$CONF_DIR/secrets.mode" 2>/dev/null || echo plain)
P=$(cat "$SECRETS_DIR/ad-test-users.pass")
ALL=0; chk() { local name=$1; shift; ALL=$((ALL+1)); if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }
mds() { curl -s --cacert "$CA" -u "$1:$2" -o /dev/null -w '%{http_code}' "https://$B1:8090/security/1.0/authenticate"; }; export -f mds; export CA B1
[ -f "$CONF_DIR/client-alice.properties" ] || (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=PLAIN\nsasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=%s/truststore.p12\nssl.truststore.password=%s\n' "$P" "$C" "$(cat "$PKI_DIR/store.pass")" > "$CONF_DIR/client-alice.properties")
[ -f "$CONF_DIR/$SCRAM1.properties" ] || (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="%s" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=%s/truststore.p12\nssl.truststore.password=%s\n' "$SCRAM1" "$(cat "$SECRETS_DIR/$SCRAM1.pass")" "$C" "$(cat "$PKI_DIR/store.pass")" > "$CONF_DIR/$SCRAM1.properties")

section "20.1 平台健康"
chk "controller quorum 有 leader" bash -c "kafka-metadata-quorum --bootstrap-controller $KC1:9093 --command-config $CONF_DIR/client-internal.properties describe --status | grep -q 'LeaderId: *[0-9]'"
for h in $KAFKA_HOSTS; do chk "$h confluent-server active" rsh "$h" 'systemctl is-active -q confluent-server'; done
for h in $BROKERS; do chk "$h MDS 8090 回 200" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://$(fqdn "$h"):8090/v1/metadata/id) = 200 ]"; done
chk "沒有 under-replicated partition" bash -c "[ \"\$(kafka-topics --bootstrap-server $BROKER_TOKEN --command-config $ADMIN --describe --under-replicated-partitions | grep -c Partition:)\" = 0 ]"
chk "沒有 offline partition" bash -c "[ \"\$(kafka-topics --bootstrap-server $BROKER_TOKEN --command-config $ADMIN --describe --unavailable-partitions | grep -c Partition:)\" = 0 ]"
chk "Self-Balancing 啟用" bash -c "kafka-rebalance-cluster --bootstrap-server $BROKER_TOKEN --command-config $ADMIN --status 2>/dev/null | grep -q 'Balancer status: ENABLED'"
chk "REST Proxy 經 LB 回 200（mTLS）" bash -c "[ \$(curl -s --cacert $CA --cert $C/$APP.crt --key $PKI_DIR/keys/$APP.key -o /dev/null -w '%{http_code}' https://$REST_VIP:8082/v3/clusters) = 200 ]"
chk "Control Center 9021 回 200" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://$C3_FQDN:9021/) = 200 ]"
chk "C3 的 Prometheus 有 broker 指標" bash -c "curl -s --cacert $CA --cert $C/cp-server.crt --key $PKI_DIR/keys/cp-server.key https://$C3_FQDN:9090/api/v1/label/__name__/values | grep -q confluent_kafka_server"
[ "$JMX_EXPORTER" = 1 ] && for h in ${CONTROLLERS%% *} ${BROKERS%% *} ${RESTS%% *}; do chk "$h JMX exporter 7071 要帳密" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://$(fqdn "$h"):7071/metrics) = 401 ]"; done
H1=${FAILED:-0}

section "20.2 安全：正向與反向"
chk "AD 帳密正確 → MDS 給 token" bash -c "[ \$(mds alice '$P') = 200 ]"
chk "AD 密碼錯 → 401" bash -c "[ \$(mds alice wrong-password) = 401 ]"
chk "不存在的帳號 → 401" bash -c "[ \$(mds nobody '$P') = 401 ]"
chk "carol 在自己 prefix 以外建 topic 被拒" bash -c "kafka-topics --bootstrap-server $B1:9096 --command-config <(sed 's/username=\"alice\"/username=\"carol\"/' $CONF_DIR/client-alice.properties) --create --topic ${AUDIT_SENSITIVE_PREFIX}carol-test --partitions 1 --replication-factor 3 2>&1 | grep -q TopicAuthorizationException"
chk "$SCRAM1 讀 ${AUDIT_SENSITIVE_PREFIX}* 被拒" bash -c "kafka-console-consumer --bootstrap-server $B1:9095 --consumer.config $CONF_DIR/$SCRAM1.properties --topic $(grep -v '^#' "$D/conf/topics.txt" | awk -v p="$AUDIT_SENSITIVE_PREFIX" 'index($1,p)==1{print $1; exit}') --max-messages 1 --timeout-ms 8000 2>&1 | grep -q TopicAuthorizationException"
chk "REST Proxy 不帶憑證 → 連線被拒" bash -c "! curl -s --cacert $CA --max-time 10 https://$REST_VIP:8082/v3/clusters -o /dev/null"
chk "REST Proxy 帶非 app 憑證（svc-ops）→ 401" bash -c "[ \$(curl -s --cacert $CA --cert $C/svc-ops.crt --key $PKI_DIR/keys/svc-ops.key -o /dev/null -w '%{http_code}' https://$REST_VIP:8082/v3/clusters) = 401 ]"
chk "CLIENT 9095 不帶 SASL → 失敗" bash -c "! kafka-topics --bootstrap-server $B1:9095 --command-config <(printf 'security.protocol=SSL\nssl.truststore.type=PKCS12\nssl.truststore.location=$C/truststore.p12\nssl.truststore.password=%s\n' \"\$(cat $PKI_DIR/store.pass)\") --list 2>/dev/null"
chk "用無關的 CA 驗 MDS 憑證會被拒（鏈驗證生效）" bash -c "! curl -s --max-time 10 --cacert <(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null -subj /CN=junk 2>/dev/null) https://$B1:8090/v1/metadata/id -o /dev/null"
if [ "$MODE" != plain ]; then
  for h in ${BROKERS%% *} ${RESTS%% *} $C3_HOST; do chk "$h properties 沒有明文密碼" rsh "$h" 'f=$(ls /etc/confluent/kafka/server.properties /etc/confluent/kafka-rest/kafka-rest.properties /etc/confluent/control-center/control-center.properties 2>/dev/null | head -1); [ "$(sudo grep -cE "^[^#].*(password|credentials|jaas.config) *= *[^$ ]" $f)" = 0 ]'; done
  [ "$MODE" = sp ] && [ "$SUMMON" = 1 ] && chk "${BROKERS%% *} 磁碟上沒有 master key（Summon）" rsh "${BROKERS%% *}" '[ "$(sudo grep -rl CONFLUENT_SECURITY_MASTER_KEY= /etc/confluent /etc/systemd/system 2>/dev/null | wc -l)" = 0 ]'
else warn "SECRETS_MODE=plain：properties 裡的密碼是明文（0640），正式環境請走第 15 或 16 站"; fi
chk "各主機 /etc/confluent/ssl 是 0750" rsh "${BROKERS%% *}" '[ "$(sudo stat -c %a /etc/confluent/ssl)" = 750 ]'
H2=$(( ${FAILED:-0} - H1 ))

section "20.3 應用程式端：$SCRAM1 SCRAM 直連寫讀；$APP 經 LB + REST Proxy（mTLS）寫，alice 讀到"
CID=$(curl -s --cacert $CA "https://$B1:8090/v1/metadata/id" | grep -o '"id":"[^"]*"' | cut -d'"' -f4); MSG="acceptance-$(date +%s)"
T1=$(grep -v '^#' "$D/conf/topics.txt" | awk '{print $1}' | grep "^${SCRAM1#app-}" | head -1); [ -n "$T1" ] || T1=$(grep -v '^#' "$D/conf/topics.txt" | awk 'NR==1{print $1}')
TB=$(grep -v '^#' "$D/conf/topics.txt" | awk '{print $1}' | grep "^${APP##*-}" | head -1); [ -n "$TB" ] || TB=$(grep -v '^#' "$D/conf/topics.txt" | awk 'END{print $1}')
chk "$SCRAM1 寫入 $T1" bash -c "echo $MSG | kafka-console-producer --bootstrap-server $B1:9095 --producer.config $CONF_DIR/$SCRAM1.properties --topic $T1"
chk "$SCRAM1 讀回自己寫的" bash -c "kafka-console-consumer --bootstrap-server $B1:9095 --consumer.config $CONF_DIR/$SCRAM1.properties --topic $T1 --group acceptance-$SCRAM1 --from-beginning --timeout-ms 15000 2>/dev/null | grep -q $MSG"
chk "$APP 經 REST Proxy 寫入 $TB（HTTP 200）" bash -c "[ \$(curl -s --cacert $CA --cert $C/$APP.crt --key $PKI_DIR/keys/$APP.key -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"value\":{\"type\":\"JSON\",\"data\":\"$MSG-rest\"}}' https://$REST_VIP:8082/v3/clusters/$CID/topics/$TB/records) = 200 ]"
chk "alice 在 $TB 看到那筆" bash -c "kafka-console-consumer --bootstrap-server $B1:9096 --consumer.config $CONF_DIR/client-alice.properties --topic $TB --group acceptance-alice --from-beginning --timeout-ms 15000 2>/dev/null | grep -q $MSG-rest"
H3=$(( ${FAILED:-0} - H1 - H2 ))

section "20.4 維運"
if [ "$OPMENU" = 1 ] && [ -x /opt/opmenu/opmenu.sh ]; then
  h=$(awk '{print $3}' <<<"$BROKERS"); [ -n "$h" ] || h=${BROKERS##* }
  r=$(sudo env OPMENU_USER=bob OPMENU_PASS="$P" OPMENU_YES=1 JAVA_HOME=/opt/java/current HOME=/home/$OPMENU_OS_USER runuser -p -u "$OPMENU_OS_USER" -- /opt/opmenu/opmenu.sh --run 21 "$(fqdn "$h"):confluent-server" 2>&1 </dev/null | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g' | tail -1)
  [[ $r == *已重啟* ]] && ok "bob 用選單重啟 $h：$r" || fail "選單重啟 $h：$r"
  for i in $(seq 1 30); do [ "$(curl -sk -o /dev/null -w '%{http_code}' "https://$(fqdn "$h"):8090/v1/metadata/id")" = 200 ] && break; sleep 5; done
  u=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN" --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:)
  [ "$i" -lt 30 ] && ok "$h MDS=200（~$((i*5))s）under-replicated=$u" || fail "$h 重啟後沒回來"
else log "OPMENU=0 或未安裝：略過選單重啟"; fi
bank "冷開機（全部主機同時關再開）由機房排程演練；預期 broker 等保管庫起來會重試（Restart=on-failure 每 10 秒）、C3 等 MDS 起來才啟動（第 13 站 drop-in）。lab：bash install/lab/bank-sim.sh coldboot"

section "20.5 收尾：留什麼、收什麼"
rm -rf /tmp/jmx-* /tmp/*.properties 2>/dev/null
bad=$(find ~ -maxdepth 3 -type f \( -name '*.key' -o -name '*.pass' -o -name 'master.key' -o -name '*.pem' -path '*/keys/*' \) ! -perm 600 2>/dev/null); [ -z "$bad" ] && ok "家目錄下的私鑰與密碼檔都是 0600" || fail "權限不是 0600：$(paste -sd' ' <<<"$bad")"
for h in ${CONTROLLERS%% *} ${BROKERS%% *} ${RESTS%% *} $C3_HOST; do
  r=$(rsh "$h" 'printf "/tmp 殘留 %s 個；sudoers %s" $(ls /tmp | grep -cv "^hsperfdata\|^systemd-private\|^lib.*\.so\|^com_\|^\.") "$(sudo ls /etc/sudoers.d | paste -sd,)"'); [[ $r == "/tmp 殘留 0 個"* ]] && ok "$h: $r" || warn "$h: $r"
done
log "留在操作機：$CONF_DIR（範本與產出的設定）、$PKI_DIR、$SECRETS_DIR（0600）、~/monitoring、~/install-logs；可刪：$LANDING、$REPO_DIR（$(du -sh "$LANDING" "$REPO_DIR" 2>/dev/null | cut -f1 | paste -sd' ')，套件庫才是正本）"
bank "交付時：OS 團隊移除各主機 /etc/sudoers.d/cpadmin（全權），只留 cpadmin-ops；$PKI_DIR/keys/svc-ops.key（super user）移到離線保管；~/.ssh/id_ed25519 正式環境改由 CyberArk 保管、操作機不留。"
log "驗收：$(( ALL - ${FAILED:-0} )) / $ALL 項通過（健康 FAIL=$H1、安全 FAIL=$H2、應用程式 FAIL=$H3）"
finish
