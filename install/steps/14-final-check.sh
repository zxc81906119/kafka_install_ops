#!/usr/bin/env bash
# 第 14 站：終點 —— 核心安裝做完，用手把手第 14 章的檢查清單確認整套健康
# where: ops02 （root）
#
# 做什麼：檢查每個服務 active、quorum 有 leader、每台 MDS 200、範例 topic 都在、REST 經負載平衡 200、
#         C3 UI 200、C3 的 Prometheus 收到 broker 指標。
# 需要什麼：第 10–13 站都做完
# 產出什麼：沒有，只有 ok／FAIL 的紀錄
# 能不能重跑：可以，只讀不寫。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
export JAVA_HOME=/opt/java/current

section "服務狀態"
for host in $KAFKA_HOSTS $RESTS; do
  unit=$(unit_of "$host")
  state=$(ssh_run "$host" "systemctl is-active $unit")

  if [ "$state" = active ]; then
    ok "$host $unit active"
  else
    fail "$host $unit $state"
  fi
done

c3_states=$(ssh_script "$C3_HOST" <<'EOF'
for unit in prometheus alertmanager confluent-control-center; do
  printf '%s=%s ' $unit "$(systemctl is-active $unit)"
done
EOF
)

case $c3_states in
  *inactive*|*failed*)
    fail "$C3_HOST $c3_states"
    ;;
  *)
    ok "$C3_HOST $c3_states"
    ;;
esac

section "叢集"

# 1. quorum 有 leader
quorum_status=$(kafka-metadata-quorum --bootstrap-controller "$FIRST_CONTROLLER:9093" \
  --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null)
leader_line=$(grep LeaderId <<<"$quorum_status" | tr -s ' ')

if grep -q '[1-9]' <<<"$leader_line"; then
  ok "quorum $leader_line"
else
  fail "quorum ${leader_line:-無回應}"
fi

# 2. 每台 MDS 回 200
for host in $BROKERS; do
  host_fqdn=$(fqdn "$host")
  http_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$host_fqdn:8090/v1/metadata/id")

  if [ "$http_code" = 200 ]; then
    ok "$host MDS=200"
  else
    fail "$host MDS=$http_code"
  fi
done

# 3. conf/topics.txt 的範例 topic 都在（第一欄是 topic 名稱）
existing_topics=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" \
  --list 2>/dev/null)
expected_topics=$(grep -v '^#' "$INSTALL_DIR/conf/topics.txt" | awk '{print $1}')

for topic in $expected_topics; do
  if grep -qx "$topic" <<<"$existing_topics"; then
    ok "topic $topic"
  else
    fail "topic $topic 不在"
  fi
done

section "對外"

# 1. REST Proxy 經負載平衡
via_lb=$(rest_app_curl -s -o /dev/null -m 30 -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters")

if [ "$via_lb" = 200 ]; then
  ok "REST 經負載平衡: 200"
else
  fail "REST 經負載平衡: $via_lb"
fi

# 2. C3 畫面
c3_ui=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$C3_FQDN:9021/")

if [ "$c3_ui" = 200 ]; then
  ok "C3 UI: 200"
else
  fail "C3 UI: $c3_ui"
fi

if wait_c3_login; then
  ok "alice 能從 C3 登入"
else
  fail "alice 不能從 C3 登入：$(c3_login_code)"
fi

# 3. 內建 Prometheus 收到幾種 Confluent 的指標
metric_names=$(curl -s -m 10 --cert "$CERTS_DIR/svc-ops.crt" --key "$KEYS_DIR/svc-ops.key" \
  "https://$C3_FQDN:9090/api/v1/label/__name__/values")
metric_kinds=$(grep -o 'confluent_kafka_server[a-z_]*' <<<"$metric_names" | sort -u | wc -l)

if [ "$metric_kinds" -gt 50 ]; then
  ok "C3 的 Prometheus 有 $metric_kinds 種 broker 指標"
else
  fail "C3 的 Prometheus 只有 $metric_kinds 種指標（剛啟動的話等一兩分鐘再跑）"
fi

finish_step
