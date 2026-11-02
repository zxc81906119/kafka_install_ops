#!/usr/bin/env bash
# 第 10 站：controller 與 broker —— 派送憑證、產生設定、systemd drop-in、格式化（只做一次）、啟動、看 quorum 與 MDS
# where: ops02 （root）
#
# 做什麼：
#   10.1 每台放 truststore、kafka-internal、MDS token 金鑰；broker 多 cp-server（對外 listener 與 MDS 用）
#   10.2 controller.tpl／broker.tpl + common.tpl → 每台的 server.properties（密碼從檔案讀進變數）
#   10.3 drop-in 讓 RPM 的服務改讀我們的設定、JAVA_HOME、heap；**確認 ExecStart 指向我們的檔**
#   10.4 產生 cluster id → controller 以動態 quorum 格式化（順便寫入緊急用的 kafka-admin SCRAM）→ broker 格式化 → 啟動
# 需要什麼：第 8 站的套件、第 9 站的憑證（~/pki）、~/pki/store.pass、~/secrets/ldap-bind.pass
# 產出什麼：~/conf/<主機>.server.properties、~/conf/kraft.env（cluster id）、~/conf/client-internal.properties、~/secrets/kafka-admin.pass
# 能不能重跑：安全。格式化看到 meta.properties 就略過；cluster id 與 kafka-admin 密碼只在不存在時產生。
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
  # 1. 這台要的檔案：controller 4 個；broker 多一個對外 listener 用的 cp-server.p12
  files=("$CERTS_DIR/truststore.p12" "$CERTS_DIR/kafka-internal.p12" "$KEYS_DIR/mds-token.key" "$CERTS_DIR/mds-token-public.pem")
  case $host in
    kb*)
      files+=("$CERTS_DIR/cp-server.p12")
      expected_count=5
      ;;
    *)
      expected_count=4
      ;;
  esac

  # 2. 送過去
  if ! copy_to_tmp "$host" "${files[@]}"; then
    fail "$host: scp"
    continue
  fi

  # 3. 在那台放到定位，印出放了哪些檔
  installed=$(ssh_script "$host" <<'EOF'
sudo install -d -o root -g root -m 0755 /etc/confluent
sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka

for file in truststore.p12 kafka-internal.p12 mds-token-public.pem cp-server.p12; do
  if [ -f /tmp/$file ]; then
    sudo install -o root -g confluent -m 0640 /tmp/$file /etc/confluent/ssl/
  fi
done

# MDS 簽 token 用的私鑰，放上去時改名成 mds-token-keypair.pem
sudo install -o root -g confluent -m 0640 /tmp/mds-token.key /etc/confluent/ssl/mds-token-keypair.pem
rm -f /tmp/*.p12 /tmp/mds-token*

sudo ls /etc/confluent/ssl | paste -sd' '
EOF
)

  # 4. 判斷結果
  installed_count=$(wc -w <<<"$installed")
  if [ "$installed_count" = "$expected_count" ]; then
    ok "$host: $installed"
  else
    fail "$host: $installed"
  fi
done

# 設定檔或 drop-in 有變的主機：服務已經在跑的話，10.4 要重啟它才會讀到新設定（enable --now 不會重啟在跑的服務）。
# 憑證（10.1）不算：p12 每次重新產生內容都不同，算進來會每次都重啟；換憑證走第 21 章。
RESTART_NEEDED_HOSTS=""
mark_restart_needed() { RESTART_NEEDED_HOSTS="$RESTART_NEEDED_HOSTS $1"; }
restart_needed() { [[ " $RESTART_NEEDED_HOSTS " == *" $1 "* ]]; }

section "10.2 設定檔：範本 + envsubst"
install -d -m 0700 "$CONF_DIR"

# 1. 密碼從 0600 檔讀進變數，這一節結束就 unset
export STORE_PASSWORD
export LDAP_BIND_PASSWORD
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
LDAP_BIND_PASSWORD=$(cat "$SECRETS_DIR/ldap-bind.pass")

# 2. envsubst 只換下面列出來的變數
export CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN
TEMPLATE_VARS="HOST_FQDN NODE_ID RACK STORE_PASSWORD LDAP_BIND_PASSWORD CONTROLLER_QUORUM BROKER_INTERNAL AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN"

# 3. 第 18 站做過的話，稽核日誌的設定片段要一起帶上（否則重跑這一站會把稽核設定蓋掉）
audit_fragment=""
audit_note=""
if [ -f "$CONF_DIR/audit.rendered.tpl" ]; then
  audit_fragment=$CONF_DIR/audit.rendered.tpl
  audit_note="；帶上第 18 站的稽核設定"
  export AUDIT_PASSWORD
  AUDIT_PASSWORD=$(cat "$SECRETS_DIR/confluent-audit.pass")
  TEMPLATE_VARS="$TEMPLATE_VARS AUDIT_PASSWORD"
fi

# 4. 第 15 站做過的話（Secret Protection），產生的明文設定先照第 15 站加密，共用的密文檔一起派送
secrets_mode=$(secrets_mode_in_use)
extra_files=()
if [ "$secrets_mode" = sp ]; then
  extra_files=("$SECRETS_DIR/security.properties")
fi
log "密碼放法：$secrets_mode$audit_note"

# 5. 每台：產生 → 依放法處理密碼 → 派送 → 確認
for host in $KAFKA_HOSTS; do
  export HOST_FQDN NODE_ID RACK
  HOST_FQDN=$(fqdn "$host")
  NODE_ID=$(node_id_of "$host")
  RACK=$(rack_of "$host")

  case $host in
    kc*)
      role_template=$TEMPLATE_DIR/controller.tpl
      ;;
    *)
      role_template=$TEMPLATE_DIR/broker.tpl
      ;;
  esac

  props_file=$CONF_DIR/$host.server.properties

  # shellcheck disable=SC2086
  if ! render_templates "$props_file" $TEMPLATE_VARS -- "$role_template" "$TEMPLATE_DIR/common.tpl" $audit_fragment; then
    fail "$host: render"
    continue
  fi

  if ! protect_rendered_props "$props_file"; then
    fail "$host: 密碼處理（$secrets_mode）"
    continue
  fi

  if ! copy_to_tmp "$host" "$props_file" "${extra_files[@]}"; then
    fail "$host: scp"
    continue
  fi

  # unresolved：還留著 ${…} 的行，config provider 的參照（securepass）不算
  result=$(ssh_script "$host" UPLOADED="/tmp/$host.server.properties" <<'EOF'
props=/etc/confluent/kafka/server.properties

# 1. 放上去之前的雜湊（第一次沒有這個檔，是空的）
before=$(sudo sha256sum $props 2>/dev/null | cut -c1-64)

# 2. 放到定位
if sudo install -o root -g confluent -m 0640 "$UPLOADED" $props; then
  rm -f "$UPLOADED"
fi

# 3. 第 15 站做過才有密文檔
if [ -f /tmp/security.properties ]; then
  sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets

  if sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties; then
    rm -f /tmp/security.properties
  fi
fi

# 4. 內容有沒有變
after=$(sudo sha256sum $props | cut -c1-64)
if [ "$before" = "$after" ]; then
  changed=no
else
  changed=yes
fi

# 5. 行數、沒換掉的 ${（要是 0）
lines=$(sudo grep -c . $props)
unresolved=$(sudo awk '/\$\{/ && !/\$\{securepass:/ {count++} END {print count + 0}' $props)
echo "$lines lines, unresolved=$unresolved changed=$changed"
EOF
)

  case $result in
    *"unresolved=0 changed="*)
      ok "$host: $result"
      ;;
    *)
      fail "$host: $result"
      ;;
  esac

  if [[ $result == *changed=yes ]]; then
    mark_restart_needed "$host"
  fi
done
unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD

section "10.3 systemd drop-in 與目錄（ExecStart 若還是 /etc/kafka/server.properties，服務會用 RPM 預設設定起來：沒加密、沒認證）"
for host in $KAFKA_HOSTS; do
  # 1. 這台的 heap
  export HEAP
  case $host in
    kc*)
      HEAP=$HEAP_CONTROLLER
      ;;
    *)
      HEAP=$HEAP_BROKER
      ;;
  esac

  # 2. 產生 drop-in、送過去
  if ! render_template "$TEMPLATE_DIR/confluent-server.dropin" "$CONF_DIR/$host.dropin" HEAP; then
    fail "$host: render dropin"
    continue
  fi

  if ! copy_to_tmp "$host" "$CONF_DIR/$host.dropin"; then
    fail "$host: scp"
    continue
  fi

  # 3. 在那台放到定位、建目錄、回報 ExecStart 與資料目錄
  result=$(ssh_script "$host" UPLOADED="/tmp/$host.dropin" <<'EOF'
sudo install -d -m 0755 /etc/systemd/system/confluent-server.service.d
dropin=/etc/systemd/system/confluent-server.service.d/10-override.conf

before=$(sudo sha256sum $dropin 2>/dev/null | cut -c1-64)

if sudo install -m 0644 "$UPLOADED" $dropin; then
  rm -f "$UPLOADED"
fi

sudo systemctl daemon-reload

sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka/data
sudo install -d -o cp-kafka -g confluent -m 0755 /var/log/kafka

after=$(sudo sha256sum $dropin | cut -c1-64)
if [ "$before" = "$after" ]; then
  changed=no
else
  changed=yes
fi

exec_file=$(systemctl show confluent-server -p ExecStart --value | grep -o '/etc/[^ ]*properties')
data=$(sudo stat -c %U:%G:%a /var/lib/kafka/data)
echo "exec=$exec_file data=$data changed=$changed"
EOF
)

  # 4. 判斷結果
  case $result in
    "exec=/etc/confluent/kafka/server.properties data=cp-kafka:confluent:750 changed="*)
      ok "$host: heap=$HEAP $result"
      ;;
    *)
      fail "$host: $result"
      ;;
  esac

  if [[ $result == *changed=yes ]]; then
    mark_restart_needed "$host"
  fi
done

if [ "$FAIL_COUNT" != 0 ]; then
  die "設定或 drop-in 有問題，不啟動"
fi

section "10.4 cluster id、格式化（只做一次）"

# 1. cluster id 與每台 controller 的 directory id（只在不存在時產生；檔案 0600）
KRAFT_ENV=$CONF_DIR/kraft.env
if [ ! -s "$KRAFT_ENV" ]; then
  install -m 0600 /dev/null "$KRAFT_ENV"
  echo "CLUSTER_ID=$(kafka-storage random-uuid)" > "$KRAFT_ENV"

  for controller in $CONTROLLERS; do
    echo "DIR_ID_$controller=$(kafka-storage random-uuid)" >> "$KRAFT_ENV"
  done

  ok "新的 cluster id 與 controller directory id 寫到 $KRAFT_ENV"
fi

# 2. 緊急備用的管理帳號 kafka-admin 的密碼（只在不存在時產生；檔案 0600）
if [ ! -s "$SECRETS_DIR/kafka-admin.pass" ]; then
  install -m 0600 /dev/null "$SECRETS_DIR/kafka-admin.pass"
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS_DIR/kafka-admin.pass"
fi

source "$KRAFT_ENV"

# initial_controllers_list：動態 quorum 的初始成員，寫法是 <node.id>@<主機>:9093:<directory id>，逗號分隔
#   例：1@kc01.poc.lab:9093:AAA,2@kc02.poc.lab:9093:BBB,3@kc03.poc.lab:9093:CCC
initial_controllers_list() {
  local controller dir_id_var list=""

  for controller in $CONTROLLERS; do
    dir_id_var=DIR_ID_$controller
    list="$list,$(node_id_of "$controller")@$(fqdn "$controller"):9093:${!dir_id_var}"
  done

  echo "${list#,}"
}
INITIAL_CONTROLLERS=$(initial_controllers_list)

# 格式化在每台主機上以 cp-kafka 身分跑。FORMAT_ARGS 由呼叫端給（controller 與 broker 不同）。
# controller 另外把 /tmp/kafka-admin.pass 寫成緊急用的 SCRAM 帳號（不依賴 MDS，平常不用）。
FORMAT_STORAGE=$(cat <<'EOF'
if sudo test -f /var/lib/kafka/data/meta.properties; then
  echo "already formatted"
  exit 0
fi

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

# 3. controller：動態 quorum，並寫入 kafka-admin 的 SCRAM 帳號
for host in $CONTROLLERS; do
  if ! copy_to_tmp "$host" "$SECRETS_DIR/kafka-admin.pass"; then
    fail "$host: scp"
    continue
  fi

  result=$(ssh_script "$host" CLUSTER_ID="$CLUSTER_ID" FORMAT_ARGS="--initial-controllers $INITIAL_CONTROLLERS" <<<"$FORMAT_STORAGE")

  # 已格式化時那段腳本提早結束，這裡確保密碼檔不留
  ssh_run "$host" 'rm -f /tmp/kafka-admin.pass'

  case $result in
    *"already formatted"*|*"cluster.id=$CLUSTER_ID")
      ok "$host: $(tr '\n' ' ' <<<"$result")"
      ;;
    *)
      fail "$host: $result"
      ;;
  esac
done

# 4. broker：格式化成觀察者（不參與 quorum 投票）
for host in $BROKERS; do
  result=$(ssh_script "$host" CLUSTER_ID="$CLUSTER_ID" FORMAT_ARGS="--no-initial-controllers" <<<"$FORMAT_STORAGE")

  case $result in
    *"already formatted"*|*"cluster.id=$CLUSTER_ID")
      ok "$host: $(tr '\n' ' ' <<<"$result")"
      ;;
    *)
      fail "$host: $result"
      ;;
  esac
done

if [ "$FAIL_COUNT" != 0 ]; then
  die "格式化失敗"
fi

section "10.4 操作機連 controller 的 client 設定（kafka-internal 憑證）"
store_password=$(cat "$PKI_DIR/store.pass")
install -m 0600 /dev/null "$INTERNAL_CLIENT_CONF"

cat > "$INTERNAL_CLIENT_CONF" <<EOF
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
unset store_password
ok "$INTERNAL_CLIENT_CONF"

# enable_and_show_state <主機>：開機自動啟動並啟動服務（已在跑的不會重啟），印 active／failed…
enable_and_show_state() {
  ssh_script "$1" <<'EOF'
sudo systemctl enable --now confluent-server >/dev/null 2>&1
sleep 1
systemctl is-active confluent-server
EOF
}

# count_quorum_ids <欄位名稱> <describe --status 的輸出>：那個欄位列了幾台
#   例：CurrentVoters: [{"id": 1, …}, {"id": 2, …}, {"id": 3, …}] → 3
count_quorum_ids() {
  grep "$1" <<<"$2" | grep -o '"id": [0-9]*' | wc -l
}

section "10.4 啟動 controller，看 quorum 有沒有 leader"
for host in $CONTROLLERS; do
  # 1. 已經在跑、設定有變：一台一台重啟（起來了才做下一台）
  if restart_needed "$host"; then
    if ssh_run "$host" 'systemctl is-active -q confluent-server'; then
      result=$(restart_and_wait "$host" confluent-server -)

      case $result in
        *after*)
          ok "設定有變，已重啟：$result"
          ;;
        *)
          fail "$result"
          ;;
      esac

      continue
    fi
  fi

  # 2. 其他情況：啟動（已在跑、設定沒變的不動）
  state=$(enable_and_show_state "$host")
  if [ "$state" = active ]; then
    ok "$host: $state"
  else
    fail "$host: $state（sudo journalctl -u confluent-server -n 50）"
  fi
done

sleep 20

# 3. 3 台都在、有一個 leader；沒有 leader 就不啟動 broker
quorum_status=$(kafka-metadata-quorum --bootstrap-controller "$CONTROLLER_QUORUM" --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null)
leader_line=$(grep LeaderId <<<"$quorum_status" | tr -s ' ')

if grep -q 'LeaderId: [1-9]' <<<"$leader_line"; then
  voter_count=$(count_quorum_ids CurrentVoters "$quorum_status")
  ok "quorum $leader_line，voters $voter_count 台"
else
  die "controller quorum 沒有 leader：$quorum_status"
fi

section "10.4 啟動 broker，確認註冊成 observer、MDS 回 200"
for host in $BROKERS; do
  # 1. 已經在跑、設定有變：一台一台重啟，等 MDS 回 200 才做下一台
  if restart_needed "$host"; then
    if ssh_run "$host" 'systemctl is-active -q confluent-server'; then
      result=$(restart_and_wait "$host" confluent-server "https://$(fqdn "$host"):8090/v1/metadata/id")

      case $result in
        *after*)
          ok "設定有變，已重啟：$result"
          ;;
        *)
          fail "$result"
          ;;
      esac

      continue
    fi
  fi

  # 2. 其他情況：啟動（已在跑、設定沒變的不動）
  state=$(enable_and_show_state "$host")
  if [ "$state" = active ]; then
    ok "$host: $state"
  else
    fail "$host: $state"
  fi
done

log "等 broker 註冊與 MDS 起來（約 45 秒）"
sleep 45

# 3. 全部 broker 都以觀察者註冊到 quorum
quorum_status=$(kafka-metadata-quorum --bootstrap-controller "$FIRST_CONTROLLER:9093" --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null)
observer_count=$(count_quorum_ids CurrentObservers "$quorum_status")
broker_count=$(wc -w <<<"$BROKERS")

if [ "$observer_count" = "$broker_count" ]; then
  ok "CurrentObservers：$observer_count 台 broker"
else
  fail "CurrentObservers 只有 $observer_count 台"
fi

# 4. 每台的 MDS（8090）回 200：每 10 秒試一次，最多 6 次
for host in $BROKERS; do
  for attempt in 1 2 3 4 5 6; do
    http_code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "https://$(fqdn "$host"):8090/v1/metadata/id")

    if [ "$http_code" = 200 ]; then
      break
    fi

    sleep 10
  done

  if [ "$http_code" = 200 ]; then
    ok "$host MDS=200"
  else
    fail "$host MDS=$http_code"
  fi
done

finish_step
