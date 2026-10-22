#!/usr/bin/env bash
# 第 14 站：終點 —— 全部做完，用這幾條確認整套是健康的（手把手第 14 章的檢查清單）
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"
export JAVA_HOME=/opt/java/current
C=$PKI_DIR/certs; APP=$(grep -v '^#' "$D/conf/apps.txt" | awk '$2=="cert"{print $1}' | head -1)

for h in $KAFKA_HOSTS; do r=$(rsh "$h" 'systemctl is-active confluent-server'); [ "$r" = active ] && ok "$h confluent-server $r" || fail "$h confluent-server $r"; done
for h in $RESTS; do r=$(rsh "$h" 'systemctl is-active confluent-kafka-rest'); [ "$r" = active ] && ok "$h confluent-kafka-rest $r" || fail "$h confluent-kafka-rest $r"; done
r=$(rsh "$C3_HOST" 'for u in prometheus alertmanager confluent-control-center; do printf "%s=%s " $u $(systemctl is-active $u); done'); [[ $r != *inactive* && $r != *failed* ]] && ok "$C3_HOST $r" || fail "$C3_HOST $r"
q=$(kafka-metadata-quorum --bootstrap-controller "$(fqdn "${CONTROLLERS%% *}"):9093" --command-config "$CONF_DIR/client-internal.properties" describe --status 2>/dev/null | grep LeaderId | tr -s ' '); grep -q '[1-9]' <<<"$q" && ok "quorum $q" || fail "quorum ${q:-無回應}"
for h in $BROKERS; do c=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$(fqdn "$h"):8090/v1/metadata/id"); [ "$c" = 200 ] && ok "$h MDS=$c" || fail "$h MDS=$c"; done
t=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$CONF_DIR/client-admin.properties" --list 2>/dev/null | grep -v '^_' | paste -sd' '); for x in $(grep -v '^#' "$D/conf/topics.txt" | awk '{print $1}'); do grep -qw "$x" <<<"$t" && ok "topic $x" || fail "topic $x 不在：$t"; done
c=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --cert "$C/$APP.crt" --key "$PKI_DIR/keys/$APP.key" "https://$REST_VIP:8082/v3/clusters"); [ "$c" = 200 ] && ok "rest via LB: $c" || fail "rest via LB: $c"
c=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$C3_FQDN:9021/"); [ "$c" = 200 ] && ok "c3 ui: $c" || fail "c3 ui: $c"
m=$(curl -s -m 10 --cert "$C/cp-server.crt" --key "$PKI_DIR/keys/cp-server.key" "https://$C3_FQDN:9090/api/v1/label/__name__/values" | grep -o 'confluent_kafka_server[a-z_]*' | sort -u | wc -l); [ "$m" -gt 50 ] && ok "metrics in prometheus: $m kinds" || fail "metrics in prometheus: $m kinds（剛啟動的話等一兩分鐘再跑）"
finish
