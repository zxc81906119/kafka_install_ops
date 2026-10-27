#!/usr/bin/env bash
# 第 10 站：controller 與 broker —— 派送憑證、產生設定、systemd drop-in、格式化（只做一次）、啟動、看 quorum 與 MDS
# where: ops02 （root）
#
# 做什麼：
#   10.1 每台放 truststore、kafka-internal、MDS token 金鑰；broker 多 cp-server（對外 listener 與 MDS 用）
#   10.2 controller.tpl／broker.tpl + common.tpl → 每台的 server.properties（密碼從檔案讀進變數）
#   10.3 drop-in 讓 RPM 的服務改讀我們的設定、JAVA_HOME、heap；**確認 ExecStart 指向我們的檔**
#   10.4 產生 cluster id → controller 以動態 quorum 格式化（順便寫入緊急用的 kafka-admin SCRAM）→ broker 格式化 → 啟動
# 產出：~/conf/<主機>.server.properties、~/conf/kraft.env（cluster id）、~/conf/client-internal.properties
# 重跑：安全。格式化看到 meta.properties 就略過；cluster id 與 kafka-admin 密碼只在不存在時產生。
#       第 15 站做過（Secret Protection）就照樣加密；第 18 站做過就帶上稽核設定。
#       設定檔或 drop-in 有變、服務已在跑的主機，10.4 會一台一台重啟（沒變的不動）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"
export JAVA_HOME=/opt/java/current

section "10.1 派送憑證（目錄 root:confluent 0750、檔案 0640）"
for host in $KAFKA_HOSTS; do
  files=("$CERTS_DIR/truststore.p12" "$CERTS_DIR/kafka-internal.p12" "$KEYS_DIR/mds-token.key" "$CERTS_DIR/mds-token-public.pem")
  case $host in kb*) files+=("$CERTS_DIR/cp-server.p12"); expected_count=5;; *) expected_count=4;; esac
  copy_to_tmp "$host" "${files[@]}" || { fail "$host: scp"; continue; }
  installed=$(ssh_script "$host" <<'EOF'
sudo install -d -o root -g root -m 0755 /etc/confluent
sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka
for file in truststore.p12 kafka-internal.p12 mds-token-public.pem cp-server.p12; do
  [ -f /tmp/$file ] && sudo install -o root -g confluent -m 0640 /tmp/$file /etc/confluent/ssl/
done
sudo install -o root -g confluent -m 0640 /tmp/mds-token.key /etc/confluent/ssl/mds-token-keypair.pem
rm -f /tmp/*.p12 /tmp/mds-token*
sudo ls /etc/confluent/ssl | paste -sd' '
EOF
)
  if [ "$(wc -w <<<"$installed")" = "$expected_count" ]; then ok "$host: $installed"; else fail "$host: $installed"; fi
done

# 設定檔或 drop-in 有變的主機：服務已經在跑的話，10.4 要重啟它才會讀到新設定（enable --now 不會重啟在跑的服務）。
# 憑證（10.1）不算：p12 每次重新產生內容都不同，算進來會每次都重啟；換憑證走第 20 站。
RESTART_NEEDED_HOSTS=""
mark_restart_needed() { RESTART_NEEDED_HOSTS="$RESTART_NEEDED_HOSTS $1"; }
restart_needed() { [[ " $RESTART_NEEDED_HOSTS " == *" $1 "* ]]; }

section "10.2 設定檔：範本 + envsubst"
install -d -m 0700 "$CONF_DIR"
export STORE_PASSWORD LDAP_BIND_PASSWORD
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
LDAP_BIND_PASSWORD=$(cat "$SECRETS_DIR/ldap-bind.pass")
export CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN
TEMPLATE_VARS="HOST_FQDN NODE_ID RACK STORE_PASSWORD LDAP_BIND_PASSWORD CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN"
# 第 18 站做過的話，稽核日誌的設定片段要一起帶上（否則重跑這一站會把稽核設定蓋掉）
audit_fragment=""
if [ -f "$CONF_DIR/audit.rendered.tpl" ]; then
  audit_fragment=$CONF_DIR/audit.rendered.tpl
  export AUDIT_PASSWORD; AUDIT_PASSWORD=$(cat "$SECRETS_DIR/confluent-audit.pass")
  TEMPLATE_VARS="$TEMPLATE_VARS AUDIT_PASSWORD"
fi
# 第 15 站做過的話（Secret Protection），產生的明文設定先照第 15 站加密，共用的密文檔一起派送
secrets_mode=$(secrets_mode_in_use)
extra_files=(); [ "$secrets_mode" = sp ] && extra_files=("$SECRETS_DIR/security.properties")
log "密碼放法：$secrets_mode$([ -n "$audit_fragment" ] && echo '；帶上第 18 站的稽核設定')"
for host in $KAFKA_HOSTS; do
  export HOST_FQDN NODE_ID RACK
  HOST_FQDN=$(fqdn "$host"); NODE_ID=$(node_id_of "$host"); RACK=$(rack_of "$host")
  case $host in kc*) role_template=$TEMPLATE_DIR/controller.tpl;; *) role_template=$TEMPLATE_DIR/broker.tpl;; esac
  props_file=$CONF_DIR/$host.server.properties
  # shellcheck disable=SC2086
  render_templates "$props_file" $TEMPLATE_VARS -- "$role_template" "$TEMPLATE_DIR/common.tpl" $audit_fragment || { fail "$host: render"; continue; }
  protect_rendered_props "$props_file" || { fail "$host: 密碼處理（$secrets_mode）"; continue; }
  copy_to_tmp "$host" "$props_file" "${extra_files[@]}" || { fail "$host: scp"; continue; }
  # unresolved：還留著 ${…} 的行，config provider 的參照（securepass）不算
  result=$(ssh_script "$host" UPLOADED="/tmp/$host.server.properties" <<'EOF'
props=/etc/confluent/kafka/server.properties
before=$(sudo sha256sum $props 2>/dev/null | cut -c1-64)
sudo install -o root -g confluent -m 0640 "$UPLOADED" $props && rm -f "$UPLOADED"
if [ -f /tmp/security.properties ]; then
  sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets
  sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && rm -f /tmp/security.properties
fi
changed=$([ "$before" = "$(sudo sha256sum $props | cut -c1-64)" ] && echo no || echo yes)
echo "$(sudo grep -c . $props) lines, unresolved=$(sudo grep '\${' $props | grep -vc '\${securepass:') changed=$changed"
EOF
)
  case $result in *"unresolved=0 changed="*) ok "$host: $result";; *) fail "$host: $result";; esac
  [[ $result == *changed=yes ]] && mark_restart_needed "$host"
done
unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD

section "10.3 systemd drop-in 與目錄（ExecStart 若還是 /etc/kafka/server.properties，服務會用 RPM 預設設定起來：沒加密、沒認證）"
for host in $KAFKA_HOSTS; do
  export HEAP
  case $host in kc*) HEAP=$HEAP_CONTROLLER;; *) HEAP=$HEAP_BROKER;; esac
  render_template "$TEMPLATE_DIR/confluent-server.dropin" "$CONF_DIR/$host.dropin" HEAP || { fail "$host: render dropin"; continue; }
  copy_to_tmp "$host" "$CONF_DIR/$host.dropin" || { fail "$host: scp"; continue; }
  result=$(ssh_script "$host" UPLOADED="/tmp/$host.dropin" <<'EOF'
sudo install -d -m 0755 /etc/systemd/system/confluent-server.service.d
dropin=/etc/systemd/system/confluent-server.service.d/10-override.conf
before=$(sudo sha256sum $dropin 2>/dev/null | cut -c1-64)
sudo install -m 0644 "$UPLOADED" $dropin && rm -f "$UPLOADED"
sudo systemctl daemon-reload
sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka/data
sudo install -d -o cp-kafka -g confluent -m 0755 /var/log/kafka
exec_file=$(systemctl show confluent-server -p ExecStart --value | grep -o '/etc/[^ ]*properties')
changed=$([ "$before" = "$(sudo sha256sum $dropin | cut -c1-64)" ] && echo no || echo yes)
echo "exec=$exec_file data=$(sudo stat -c %U:%G:%a /var/lib/kafka/data) changed=$changed"
EOF
)
  case $result in "exec=/etc/confluent/kafka/server.properties data=cp-kafka:confluent:750 changed="*) ok "$host: heap=$HEAP $result";; *) fail "$host: $result";; esac
  [[ $result == *changed=yes ]] && mark_restart_needed "$host"
done
[ "$FAIL_COUNT" = 0 ] || die "設定或 drop-in 有問題，不啟動"

section "10.4 cluster id、格式化（只做一次）"
KRAFT_ENV=$CONF_DIR/kraft.env      # CLUSTER_ID 與每台 controller 的 directory id
if [ ! -s "$KRAFT_ENV" ]; then
  (umask 077
   echo "CLUSTER_ID=$(kafka-storage random-uuid)"
   for controller in $CONTROLLERS; do echo "DIR_ID_$controller=$(kafka-storage random-uuid)"; done) > "$KRAFT_ENV"
  ok "新的 cluster id 與 controller directory id 寫到 $KRAFT_ENV"
fi
[ -s "$SECRETS_DIR/kafka-admin.pass" ] || (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS_DIR/kafka-admin.pass")
source "$KRAFT_ENV"
# 動態 quorum 的初始成員：<node.id>@<主機>:9093:<directory id>,…
INITIAL_CONTROLLERS=$(for controller in $CONTROLLERS; do
  dir_id_var=DIR_ID_$controller
  printf '%s@%s:9093:%s,' "$(node_id_of "$controller")" "$(fqdn "$controller")" "${!dir_id_var}"
done | sed 's/,$//')

# 格式化在每台主機上以 cp-kafka 身分跑。FORMAT_ARGS 由呼叫端給（controller 與 broker 不同）。
# controller 另外把 /tmp/kafka-admin.pass 寫成緊急用的 SCRAM 帳號（不依賴 MDS，平常不用）。
FORMAT_STORAGE=$(cat <<'EOF'
if sudo test -f /var/lib/kafka/data/meta.properties; then echo "already formatted"; exit 0; fi
scram_args=()
if [ -f /tmp/kafka-admin.pass ]; then
  scram_args=(--add-scram "SCRAM-SHA-512=[name=kafka-admin,password=$(cat /tmp/kafka-admin.pass)]")
  rm -f /tmp/kafka-admin.pass
fi
sudo -u cp-kafka env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
  kafka-storage format --cluster-id "$CLUSTER_ID" --config /etc/confluent/kafka/server.properties $FORMAT_ARGS "${scram_args[@]}" 2>&1 \
  | grep -vi scram | tail -1
echo "cluster.id=$(sudo sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)"
EOF
)
for host in $CONTROLLERS; do
  copy_to_tmp "$host" "$SECRETS_DIR/kafka-admin.pass" || { fail "$host: scp"; continue; }
  result=$(ssh_script "$host" CLUSTER_ID="$CLUSTER_ID" FORMAT_ARGS="--initial-controllers $INITIAL_CONTROLLERS" <<<"$FORMAT_STORAGE")
  ssh_run "$host" 'rm -f /tmp/kafka-admin.pass'   # 已格式化時腳本提早結束，這裡確保密碼檔不留
  case $result in *"already formatted"*|*"cluster.id=$CLUSTER_ID") ok "$host: $(tr '\n' ' ' <<<"$result")";; *) fail "$host: $result";; esac
done
for host in $BROKERS; do
  result=$(ssh_script "$host" CLUSTER_ID="$CLUSTER_ID" FORMAT_ARGS="--no-initial-controllers" <<<"$FORMAT_STORAGE")
  case $result in *"already formatted"*|*"cluster.id=$CLUSTER_ID") ok "$host: $(tr '\n' ' ' <<<"$result")";; *) fail "$host: $result";; esac
done
[ "$FAIL_COUNT" = 0 ] || die "格式化失敗"

section "10.4 操作機連 controller 的 client 設定（kafka-internal 憑證）"
store_password=$(cat "$PKI_DIR/store.pass")
(umask 077; cat > "$INTERNAL_CLIENT_CONF" <<EOF
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=$CERTS_DIR/kafka-internal.p12
ssl.keystore.password=$store_password
ssl.key.password=$store_password
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$store_password
ssl.endpoint.identification.algorithm=https
EOF
)
unset store_password
ok "$INTERNAL_CLIENT_CONF"

section "10.4 啟動 controller，看 quorum 有沒有 leader"
for host in $CONTROLLERS; do
  if restart_needed "$host" && ssh_run "$host" 'systemctl is-active -q confluent-server'; then
    # 已經在跑、設定有變：一台一台重啟（起來了才做下一台）
    result=$(restart_and_wait "$host" confluent-server -)
    case $result in *after*) ok "設定有變，已重啟：$result";; *) fail "$result";; esac
    continue
  fi
  state=$(ssh_run "$host" 'sudo systemctl enable --now confluent-server >/dev/null 2>&1; sleep 1; systemctl is-active confluent-server')
  if [ "$state" = active ]; then ok "$host: $state"; else fail "$host: $state（sudo journalctl -u confluent-server -n 50）"; fi
done
sleep 20
quorum_status=$(kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null)
leader_line=$(grep LeaderId <<<"$quorum_status" | tr -s ' ')
if grep -q 'LeaderId: [1-9]' <<<"$leader_line"; then ok "quorum $leader_line，voters $(grep CurrentVoters <<<"$quorum_status" | grep -o '"id": [0-9]*' | wc -l) 台"
else die "controller quorum 沒有 leader：$quorum_status"; fi

section "10.4 啟動 broker，確認註冊成 observer、MDS 回 200"
for host in $BROKERS; do
  if restart_needed "$host" && ssh_run "$host" 'systemctl is-active -q confluent-server'; then
    # 已經在跑、設定有變：一台一台重啟，等 MDS 回 200 才做下一台
    result=$(restart_and_wait "$host" confluent-server "https://$(fqdn "$host"):8090/v1/metadata/id")
    case $result in *after*) ok "設定有變，已重啟：$result";; *) fail "$result";; esac
    continue
  fi
  state=$(ssh_run "$host" 'sudo systemctl enable --now confluent-server >/dev/null 2>&1; sleep 1; systemctl is-active confluent-server')
  if [ "$state" = active ]; then ok "$host: $state"; else fail "$host: $state"; fi
done
log "等 broker 註冊與 MDS 起來（約 45 秒）"
sleep 45
observer_count=$(kafka-metadata-quorum --bootstrap-controller "$FIRST_CONTROLLER:9093" --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null \
  | grep CurrentObservers | grep -o '"id": [0-9]*' | wc -l)
if [ "$observer_count" = "$(wc -w <<<"$BROKERS")" ]; then ok "CurrentObservers：$observer_count 台 broker"; else fail "CurrentObservers 只有 $observer_count 台"; fi
for host in $BROKERS; do
  for attempt in 1 2 3 4 5 6; do
    http_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$(fqdn "$host"):8090/v1/metadata/id")
    [ "$http_code" = 200 ] && break
    sleep 10
  done
  if [ "$http_code" = 200 ]; then ok "$host MDS=200"; else fail "$host MDS=$http_code"; fi
done
finish_step
