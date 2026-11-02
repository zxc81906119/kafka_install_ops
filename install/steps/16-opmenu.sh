#!/usr/bin/env bash
# 第 16 站：維運選單（OP menu） —— 維運人員用本人 AD 身分做 Kafka 作業；主機作業用 cpuser 與 /secure/ssh 的金鑰 ssh 過去
# where: ops02 （root）
#
# 何時用：OPMENU=1。選單裝在操作機（人員經 PSMP 登入就是 root，直接跑選單），主機上不放代理程式，只靠 sudoers 限制 cpuser 能跑的指令。
# 做什麼：
#   16.1 確認銀行送來選單套件
#   16.2 綁 conf/rbac-opmenu.txt 的 role binding；緊急憑證 PEM（私鑰＋憑證）由我方組好放 ~/secrets/opmenu-breakglass.pem（0600）
#   16.3 裝選單：/opt/opmenu、/etc/opmenu（設定、身分、truststore、known_hosts）、/var/log/opmenu
#   16.4 各主機加上 cpuser 的窄 sudo 規則 /etc/sudoers.d/cpuser-ops（逐一列出服務與指令寫法；全權那份由 OS 團隊在安裝完成後收回）
#   16.5 試跑：選單全部顯示，沒權限的做了被 Kafka／MDS 拒絕
#   16.6 收尾：沒有 ssh-agent、/dev/shm 與 /tmp 沒有私鑰
# 注意：操作者在操作機上是 root，選單的「主機權限閘門」（問 MDS 本人有沒有 Operator）是流程控管、不是硬性隔離；
#       追溯靠 CyberArk 的登入紀錄與 PSMP 錄影，Kafka 動作的權限與稽核由 Kafka 端依本人 AD 身分強制。
# 需要什麼：第 11 站的 RBAC 與 AD 群組、第 9 站的 opmenu-breakglass 憑證、第 4 站的 cpuser 金鑰、落地區的選單套件（opmenu/package.sh 產生）
# 產出什麼：/opt/opmenu、/etc/opmenu/*、/var/log/opmenu、~/secrets/opmenu-breakglass.pem、各主機 /etc/sudoers.d/cpuser-ops
# 能不能重跑：安全（選單目錄整個換新；role binding 重建是 no-op）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"

if [ "$OPMENU" != 1 ]; then
  log "OPMENU=$OPMENU：略過第 16 站"
  exit 0
fi

export JAVA_HOME=/opt/java/current
OPMENU_PACKAGE_DIR=$LANDING/tools/opmenu      # 手把手 16.3：我方交付的 opmenu-*.tar.gz＋SHA256SUMS（opmenu/package.sh 產生），隨落地區送進來
JOURNAL_LINES=200                             # 選單看日誌固定要這個行數（opmenu/lib/hosts.sh 的 _JOURNAL_LINES）；sudoers 要逐字相符，兩邊一起改

# 以某個 AD 身分非互動執行選單（試跑用）。正式環境維運人員是互動登入，自己輸入 AD 帳密。
run_menu_as() {
  local person=$1
  shift

  env OPMENU_USER="$person" OPMENU_PASS="$(cat "$SECRETS_DIR/ad-test-users.pass")" OPMENU_YES=1 OPMENU_REASON="第 16 站試跑" \
      JAVA_HOME=/opt/java/current /opt/opmenu/opmenu.sh --run "$@" 2>&1 </dev/null \
    | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g'
}

# package_checksum_ok <目錄>：那個目錄的 SHA256SUMS 檔在，而且核對得過
package_checksum_ok() {
  local package_dir=$1

  if [ ! -f "$package_dir/SHA256SUMS" ]; then
    return 1
  fi

  # 括號 = 在子 shell 裡 cd，不影響這支腳本的目前目錄
  (
    if ! cd "$package_dir"; then
      exit 1
    fi

    sha256sum -c --quiet SHA256SUMS
  )
}

# breakglass_pem_ok <檔案>：權限 0600，而且私鑰與憑證都在裡面
breakglass_pem_ok() {
  local pem_file=$1

  if [ "$(stat -c %a "$pem_file")" != 600 ]; then
    return 1
  fi

  if ! grep -q 'BEGIN .*PRIVATE KEY' "$pem_file"; then
    return 1
  fi

  if ! grep -q 'BEGIN CERTIFICATE' "$pem_file"; then
    return 1
  fi

  return 0
}

ask_bank "16.3 選單套件 opmenu-*.tar.gz 隨落地區送到 $OPMENU_PACKAGE_DIR/。" \
         "16.4 OS 團隊：各主機 $SSH_USER 的 sudo 改成兩段式（永久只留 /etc/sudoers.d/$SSH_USER-ops 逐一列出的 restart／status／journalctl；安裝期的全權 /etc/sudoers.d/$SSH_USER 做完收回）。"

section "16.1 確認銀行的準備"
if package_checksum_ok "$OPMENU_PACKAGE_DIR"; then
  ok "opmenu 套件 sha256 相符"
else
  fail "$OPMENU_PACKAGE_DIR 缺檔或 sha256 不符"
fi

# 只有選單套件要等：91 緊急模式用的緊急憑證 PEM 由我方在 16.3 組好放在操作機 ~/secrets（0600）
if [ "$FAIL_COUNT" != 0 ]; then
  wait_for_bank
fi

section "16.2 role binding（conf/rbac-opmenu.txt：緊急身分 SystemAdmin、維運群組補 DescribeConfigs）"
if ! confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
     --client-cert-path "$CERTS_DIR/svc-ops.crt" --client-key-path "$KEYS_DIR/svc-ops.key" >/dev/null 2>&1; then
  die "confluent login 失敗"
fi

source "$CONF_DIR/kraft.env"   # CLUSTER_ID

# 每一行：principal、角色、資源（- = 整個 cluster）、比對方式（PREFIXED = 名稱開頭相同）
while read -r principal role resource pattern; do
  if [ -z "$principal" ]; then
    continue
  fi

  binding_args=(--principal "$principal" --role "$role" --kafka-cluster "$CLUSTER_ID")

  if [ "$resource" != - ]; then
    binding_args+=(--resource "$resource")
  fi

  if [ "$pattern" = PREFIXED ]; then
    binding_args+=(--prefix)
  fi

  if mds_write confluent iam rbac role-binding create "${binding_args[@]}" >/dev/null 2>&1 </dev/null; then
    ok "$principal $role ${resource#-} ${pattern#-}"
  else
    fail "$principal $role ${resource#-}"
  fi
done <<<"$(grep -v '^#' "$INSTALL_DIR/conf/rbac-opmenu.txt")"

if [ "$FAIL_COUNT" != 0 ]; then
  die "16.2 失敗"
fi

section "16.3 裝選單"

# 1. /opt/opmenu：選單本體（唯讀）；舊的整個換掉
rm -rf /opt/opmenu

if ! tar -xzf "$OPMENU_PACKAGE_DIR"/opmenu-*.tar.gz -C /opt; then
  die "解開 opmenu 套件失敗"
fi

chown -R root:root /opt/opmenu
chmod -R a+rX /opt/opmenu

# 2. /etc/opmenu：truststore、根憑證
install -d -m 0755 /etc/opmenu /etc/opmenu/ssl
install -m 0644 "$CERTS_DIR/truststore.p12" /etc/opmenu/ssl/truststore.p12
install -m 0600 "$PKI_DIR/store.pass" /etc/opmenu/ssl/truststore.pass
install -m 0644 "$BANK_ROOT_CA" /etc/opmenu/ssl/ca.pem

# 3. 各主機的 ssh 主機金鑰：選單只信這份清單（只留金鑰行，# 開頭的註解行不要）
cluster_fqdns=()
for host in $CLUSTER_HOSTS; do
  cluster_fqdns+=("$(fqdn "$host")")
done

ssh-keyscan -t ed25519 "${cluster_fqdns[@]}" 2>/dev/null | grep -v "^#" | sort | install -m 0644 /dev/stdin /etc/opmenu/known_hosts

# 4. /var/log/opmenu：選單紀錄與匯出檔
install -d -m 0750 -o root -g root /var/log/opmenu

# 5. 緊急憑證 PEM（91 用）：私鑰＋憑證串成一個檔，放操作機 ~/secrets（0600、root 才讀得到）；選單讀檔時會檢查權限與 owner
BREAKGLASS_PEM=$SECRETS_DIR/opmenu-breakglass.pem
install -d -m 0700 "$SECRETS_DIR"
install -m 0600 /dev/null "$BREAKGLASS_PEM"
cat "$KEYS_DIR/opmenu-breakglass.key" "$CERTS_DIR/opmenu-breakglass.crt" > "$BREAKGLASS_PEM"

if breakglass_pem_ok "$BREAKGLASS_PEM"; then
  ok "緊急憑證 PEM：$BREAKGLASS_PEM（0600）"
else
  die "緊急憑證 PEM 組不起來：$BREAKGLASS_PEM"
fi

# 6. 設定檔只填推算不出來的值：連線位址、可重啟的服務清單、緊急憑證檔路徑
export ENV_LABEL=$OPMENU_ENV_LABEL
export BOOTSTRAP_LDAP=$BROKER_LDAP
export BREAKGLASS_PEM SSH_USER SSH_KEY
export BROKER_SERVICES AUX_SERVICES CONTROLLER_HOSTS LB_FQDN

# 選單 22 重啟 REST 前確認 LB 已經停用那一台
LB_FQDN=$(fqdn "$LB_HOST")

# 可以重啟的 broker，空白分隔。例：kb01.poc.lab:confluent-server kb02.poc.lab:confluent-server …
BROKER_SERVICES=""
for host in $BROKERS; do
  BROKER_SERVICES="$BROKER_SERVICES $(fqdn "$host"):confluent-server"
done
BROKER_SERVICES=${BROKER_SERVICES# }

# 可以重啟的 REST Proxy 與 C3。例：rest01.poc.lab:confluent-kafka-rest … c3-01.poc.lab:confluent-control-center
AUX_SERVICES=""
for host in $RESTS; do
  AUX_SERVICES="$AUX_SERVICES$(fqdn "$host"):confluent-kafka-rest "
done
AUX_SERVICES="$AUX_SERVICES$C3_FQDN:confluent-control-center"

# controller 主機，空白分隔。例：kc01.poc.lab kc02.poc.lab kc03.poc.lab
CONTROLLER_HOSTS=""
for host in $CONTROLLERS; do
  CONTROLLER_HOSTS="$CONTROLLER_HOSTS $(fqdn "$host")"
done
CONTROLLER_HOSTS=${CONTROLLER_HOSTS# }

if ! render_template "$TEMPLATE_DIR/opmenu.conf" "$CONF_DIR/opmenu.conf" ENV_LABEL BREAKGLASS_PEM BOOTSTRAP_LDAP BROKER_SERVICES AUX_SERVICES CONTROLLER_HOSTS LB_FQDN SSH_USER SSH_KEY; then
  die "render opmenu.conf"
fi

install -m 0644 "$CONF_DIR/opmenu.conf" /etc/opmenu/opmenu.conf

# 7. 選單讀得到設定、項目都在
listed_items=$(/opt/opmenu/opmenu.sh --list 2>/dev/null | wc -l)

if [ "$listed_items" -gt 20 ]; then
  item_count=$(ls /opt/opmenu/items/*.sh | wc -l)
  known_host_count=$(wc -l < /etc/opmenu/known_hosts)
  ok "opmenu $item_count 個項目、known_hosts $known_host_count 把"
else
  die "opmenu --list 失敗（只列出 $listed_items 項）"
fi

section "16.4 各主機 $SSH_USER 的窄 sudo 規則 /etc/sudoers.d/$SSH_USER-ops（逐一列出，不用萬用字元）"
# 規則比對的是完整的參數：選單實際用到的每一種寫法都要列出來，多帶任何參數都會被擋。
# 選單用到的 sudo 寫法（opmenu/lib/hosts.sh）：systemctl restart <服務>、journalctl -u <服務> -n $JOURNAL_LINES --no-pager。
# 再加 systemctl status <服務>（維運人員手動看狀態用）。controller／broker 只列 confluent-server，REST 只列 confluent-kafka-rest，C3 只列 confluent-control-center。
for host in $CLUSTER_HOSTS; do
  unit=$(unit_of "$host")

  ssh_script "$host" UNIT="$unit" SSH_USER="$SSH_USER" JOURNAL_LINES="$JOURNAL_LINES" <<'EOF'
sudo install -m 0440 /dev/stdin "/etc/sudoers.d/$SSH_USER-ops" <<RULE
$SSH_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart $UNIT, \\
    /usr/bin/systemctl status $UNIT, \\
    /usr/bin/journalctl -u $UNIT -n $JOURNAL_LINES --no-pager
RULE

sudo visudo -cf "/etc/sudoers.d/$SSH_USER-ops" >/dev/null
EOF
  sudoers_result=$?

  if [ "$sudoers_result" = 0 ]; then
    ok "$host: $SSH_USER-ops（$unit）"
  else
    fail "$host: sudoers"
  fi
done

ask_bank "安裝全部完成後：OS 團隊移除各主機的 /etc/sudoers.d/$SSH_USER（全權），只留 $SSH_USER-ops；之後安裝／升級依變更單臨時開。"

section "16.5 試跑：選單全部顯示，沒權限的做了被 Kafka 拒絕"

# 1. 選單不依權限過濾：bob、alice 看到同一份
menu_bob=$(run_menu_as bob menu | grep '@@MENU@@' | cut -d' ' -f2-)
menu_alice=$(run_menu_as alice menu | grep '@@MENU@@' | cut -d' ' -f2-)

menus_same=no
if [ -n "$menu_bob" ]; then
  if [ "$menu_bob" = "$menu_alice" ]; then
    menus_same=yes
  fi
fi

if [ "$menus_same" = yes ]; then
  menu_item_count=$(wc -w <<<"$menu_bob")
  ok "bob 與 alice 看到同一份選單（$menu_item_count 項）"
else
  fail "選單應該全部顯示：bob「$menu_bob」alice「$menu_alice」"
fi

# 2. 維運群組是 Operator＋DeveloperManage Topic:*（2026-10-29 定案）：健康檢查要 DescribeConfigs，能建刪 topic，但不能改權限
bob_health=$(run_menu_as bob 11)

bob_health_ok=no
if grep -q -- '-- broker 在線:' <<<"$bob_health"; then
  if ! grep -q "Kafka 拒絕" <<<"$bob_health"; then
    bob_health_ok=yes
  fi
fi

if [ "$bob_health_ok" = yes ]; then
  ok "bob（維運）11 健康檢查跑得完（under-replicated／offline 檢查要 DescribeConfigs）"
else
  bob_health_error=$(grep -m2 -E '拒絕|failed' <<<"$bob_health" | tr '\n' ' ')
  fail "bob 的 11 健康檢查：$bob_health_error"
fi

bob_grant=$(run_menu_as bob 42 add kafka-devs DeveloperRead Topic orders. | tail -1)

if grep -q "拒絕" <<<"$bob_grant"; then
  ok "bob（維運）改權限（42）被 MDS 拒絕"
else
  fail "bob 改權限應被拒：$bob_grant"
fi

bob_91=$(run_menu_as bob 91 kafka-topics --list | tail -3)

if grep -q "Authorization failed" <<<"$bob_91"; then
  ok "bob 進 91 緊急模式被管理員閘門擋下"
else
  fail "bob 的 91 應被擋：$bob_91"
fi

# 3. alice（SystemAdmin）建 topic；重跑時上一輪的示範 topic 可能還在，先刪
run_menu_as alice 33 orders.optest >/dev/null 2>&1

alice_create=$(run_menu_as alice 31 orders.optest 1 | tail -1)

if grep -q "Created topic" <<<"$alice_create"; then
  ok "alice（SystemAdmin）建 topic orders.optest"
else
  fail "alice 建 topic：$alice_create"
fi

# 4. 35：A／B 輪替——只換應用程式沒在用的那個帳號（用 app-payments 示範，app-orders 留給 19 站驗收與手把手 20.6）
SECOND_SCRAM_APP=$(awk '{print $2}' <<<"$SCRAM_APPS")
SECOND_SCRAM_APP=${SECOND_SCRAM_APP:-$FIRST_SCRAM_APP}

rotate_out=$(run_menu_as alice 35 "$SECOND_SCRAM_APP" "$SECOND_SCRAM_APP-a" | tail -3)

if grep -q "下一步：請應用程式改用 $SECOND_SCRAM_APP-b" <<<"$rotate_out"; then
  ok "35 換了閒置的 $SECOND_SCRAM_APP-b，應用程式用的 -a 不受影響"
else
  fail "35：$rotate_out"
fi

if shred -u "$HOME"/opmenu-handover/"$SECOND_SCRAM_APP"-b-*.pass 2>/dev/null; then
  log "35 的交接檔已 shred（lab 不交付）"
fi

# 5. 13：在線成員數。開一個 60 秒的 consumer（svc-ops 的管理連線：這時還沒有應用程式的 client 設定，第 19 站才產生）
timeout 60 kafka-console-consumer --bootstrap-server "$BROKER_TOKEN" --consumer.config "$ADMIN_CLIENT_CONF" --topic orders.events --group orders-optest >/dev/null 2>&1 &
sleep 20

group_out=$(run_menu_as bob 13 orders-optest | grep '^==')

if grep -q '在線成員 1 個' <<<"$group_out"; then
  ok "13 consumer group：$group_out"
else
  fail "13 應看到 orders-optest 有 1 個在線成員：$group_out"
fi

# 6. 15／38：配額要叢集層級 DescribeConfigs／AlterConfigs：bob（維運）看不到，alice（管理）改了再改回
bob_quota=$(run_menu_as bob 15 "" | tail -1)

if grep -q "拒絕" <<<"$bob_quota"; then
  ok "bob（維運）看配額（15）被 Kafka 拒絕"
else
  fail "bob 看配額應被拒"
fi

quota_account=$FIRST_SCRAM_APP-b
quota_before=$(run_menu_as alice 15 "$quota_account" | tail -1)
producer_before=$(grep -o 'producer_byte_rate=[0-9]*' <<<"$quota_before" | cut -d= -f2)

if [ -n "$producer_before" ]; then
  ok "15 配額：$quota_before"
else
  fail "15 看不到 $quota_account 的配額：$quota_before"
fi

quota_changed=$(run_menu_as alice 38 "$quota_account" producer_byte_rate=4194304 | grep '^改後')
quota_back=$(run_menu_as alice 38 "$quota_account" "producer_byte_rate=${producer_before:-5242880}" | grep '^改後')

quota_round_trip_ok=no
if grep -q 'producer_byte_rate=4194304' <<<"$quota_changed"; then
  # 改回去的那一行後面補一個空白再比對，才不會把 5242880 比成 52428801
  if grep -q "producer_byte_rate=${producer_before:-x} " <<<"$quota_back "; then
    quota_round_trip_ok=yes
  fi
fi

if [ "$quota_round_trip_ok" = yes ]; then
  ok "38 改配額再改回（$quota_account producer_byte_rate 4194304 → $producer_before）"
else
  fail "38：$quota_changed / $quota_back"
fi

# 7. 17：license 到期日（alice 讀得到 _confluent-command）
license_line=$(run_menu_as alice 17 | grep '^license')

if grep -q '到期 [0-9-]*，剩' <<<"$license_line"; then
  ok "17 $license_line"
else
  fail "17 沒有 license 到期日：$license_line"
fi

# 健康檢查、重啟、緊急模式要動主機（ssh 用 $SSH_KEY）或用緊急憑證（讀 ~/secrets/opmenu-breakglass.pem、要人填原因），非互動試跑做不了
warn "重啟、看日誌要由維運人員互動登入試跑（手把手 16.5）；緊急模式要互動填原因"

section "16.6 收尾檢查"

# 1. 沒有 ssh-agent；/dev/shm、/tmp 裡沒有私鑰；金鑰檔還是 root 0400
agent_count=$(pgrep -x ssh-agent | wc -l)
keys_on_disk=$(grep -rls 'PRIVATE KEY' /dev/shm /tmp 2>/dev/null | wc -l)
key_file_state=$(stat -c '%U:%G %a' "$SSH_KEY")
summary="ssh-agent=$agent_count /dev/shm 與 /tmp 的私鑰=$keys_on_disk；金鑰檔 $key_file_state"

if [ "$agent_count $keys_on_disk $key_file_state" = "0 0 root:root 400" ]; then
  ok "$summary"
else
  fail "$summary"
fi

# 2. 選單紀錄的最後幾行
if [ -s /var/log/opmenu/opmenu.log ]; then
  tail -3 /var/log/opmenu/opmenu.log | cut -c1-110 | tee -a "$LOG_FILE"
else
  warn "選單紀錄還是空的（還沒有人用選單做事）；互動試跑後在 /var/log/opmenu/opmenu.log"
fi

finish_step
