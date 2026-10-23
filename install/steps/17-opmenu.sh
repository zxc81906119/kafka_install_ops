#!/usr/bin/env bash
# 第 17 站：維運選單（OP menu） —— 維運人員用本人 AD 身分做 Kafka 作業；主機作業以 cpadmin ssh，私鑰啟動時從保管庫取
# where: ops02 （cpadmin）
#
# 何時用：OPMENU=1。選單裝在操作機，主機上不放代理程式，只靠 sudoers 限制 cpadmin 能跑的指令。
# 做什麼：
#   17.1 確認銀行開好選單的保管庫身分、送來選單套件
#   17.2 把 cpadmin 私鑰、緊急憑證 PEM 寫進保管庫；綁 conf/rbac-opmenu.txt 的 role binding
#   17.3 裝選單：維運人員帳號與 opmenu 群組、/opt/opmenu、/etc/opmenu（設定、身分、truststore、known_hosts）
#   17.4 各主機加上 cpadmin 的窄 sudo 規則（全權那份由 OS 團隊在安裝完成後收回）
#   17.5 試跑：alice／bob／carol 看到的選單不同、bob 能重啟一台 broker、看不到的項目會被擋、alice 能用緊急模式
#   17.6 收尾：沒有 ssh-agent、磁碟上沒有私鑰、維運帳號讀不到 cpadmin 的檔案
# 重跑：安全（選單目錄整個換新；保管庫的值覆蓋；role binding 重建是 no-op）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"
source "$INSTALL_DIR/lib/vault.sh"
if [ "$OPMENU" != 1 ]; then log "OPMENU=$OPMENU：略過第 17 站"; exit 0; fi
export JAVA_HOME=/opt/java/current
OPMENU_PACKAGE_DIR=$LANDING/tools/opmenu      # windows/package-opmenu.sh 打的包，隨落地區送進來
MENU_USER=$OPMENU_OS_USER                     # 維運人員的本機帳號

# 以某個 AD 身分非互動執行選單（試跑用）。正式環境維運人員是互動登入，自己輸入 AD 帳密。
run_menu_as() {
  local person=$1; shift
  sudo env OPMENU_USER="$person" OPMENU_PASS="$(cat "$SECRETS_DIR/ad-test-users.pass")" OPMENU_YES=1 OPMENU_REASON="第 17 站試跑" \
       JAVA_HOME=/opt/java/current HOME=/home/$MENU_USER \
       runuser -p -u "$MENU_USER" -- /opt/opmenu/opmenu.sh --run "$@" 2>&1 </dev/null \
    | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g'
}

ask_bank "17.1 Secrets 團隊：保管庫加身分 host/$VAULT_POLICY/opmenu 與兩個變數 $VAULT_POLICY/ssh/cpadmin、$VAULT_POLICY/breakglass/pem" \
         "    （opmenu 可讀、ops 可寫）；opmenu 的 API key 交到操作機 root 的 /root/opmenu.key。" \
         "17.3 OS 團隊：操作機上建維運人員的本機帳號（lab：$MENU_USER）；選單套件 opmenu-*.tar.gz 隨落地區送到 $OPMENU_PACKAGE_DIR/。" \
         "17.4 OS 團隊：各主機 cpadmin 的 sudo 改成兩段式（永久只留 restart／status／journalctl；安裝期的全權做完收回）。"

section "17.1 確認銀行的準備（選單的機敏資料來源：OPMENU_SECRETS=$OPMENU_SECRETS）"
if [ -f "$OPMENU_PACKAGE_DIR/SHA256SUMS" ] && (cd "$OPMENU_PACKAGE_DIR" && sha256sum -c --quiet SHA256SUMS); then ok "opmenu 套件 sha256 相符"
else fail "$OPMENU_PACKAGE_DIR 缺檔或 sha256 不符"; fi
case $OPMENU_SECRETS in
  conjur)   # lab：選單用自己的保管庫身分取值
    if sudo test -s /root/opmenu.key; then ok "/root/opmenu.key 在"
    elif sudo test -s /etc/opmenu/conjur.identity; then ok "/etc/opmenu/conjur.identity 已存在（之前裝過）"
    else fail "沒有 /root/opmenu.key"; fi
    if [ -s "$VAULT_OPS_KEY" ]; then ok "$VAULT_OPS_KEY 在"; else fail "沒有 $VAULT_OPS_KEY"; fi;;
  manual)   # 客戶：沒有 CCP，維運人員登入選單後自己從 PVWA 取出貼上；這裡沒有東西要準備
    ok "manual：cpadmin 私鑰與緊急憑證由維運人員從 PVWA 取出貼上（PVWA 上的 object 名稱寫在 opmenu.conf）";;
  ccp)      # 有 CCP 的銀行：選單以 client 憑證打 CCP（設定見 opmenu/lib/secrets/ccp.sh）
    ok "ccp：AppID、client 憑證請照 opmenu/README 準備";;
esac
[ "$FAIL_COUNT" = 0 ] || wait_for_bank

if [ "$OPMENU_SECRETS" = conjur ]; then
  section "17.2 值寫進保管庫（cpadmin 私鑰、緊急憑證 PEM）"
  vault_login_as_ops || die "ops 身分登入失敗"
  if vault_set ssh/cpadmin < ~/.ssh/id_ed25519; then ok "ssh/cpadmin 寫入"; else fail "ssh/cpadmin"; fi
  if cat "$KEYS_DIR/opmenu-breakglass.key" "$CERTS_DIR/opmenu-breakglass.crt" | vault_set breakglass/pem; then ok "breakglass/pem 寫入"; else fail "breakglass/pem"; fi
  vault_logout
else
  ask_bank "17.2 Secrets 團隊：cpadmin 私鑰（SSH Key Manager 管的那把）與緊急憑證 PEM（$KEYS_DIR/opmenu-breakglass.key + $CERTS_DIR/opmenu-breakglass.crt）" \
           "    放進 PVWA 的 safe，開給維運群組取用（建議雙人覆核、要填變更單號）。緊急憑證交付後操作機上的私鑰可移到離線保管。"
fi

section "17.2 role binding（conf/rbac-opmenu.txt：緊急身分 SystemAdmin、維運群組補 DescribeConfigs）"
confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only \
  --client-cert-path "$CERTS_DIR/svc-ops.crt" --client-key-path "$KEYS_DIR/svc-ops.key" >/dev/null 2>&1 || die "confluent login 失敗"
source "$CONF_DIR/kraft.env"   # CLUSTER_ID
while read -r principal role resource pattern; do
  [ -n "$principal" ] || continue
  binding_args=(--principal "$principal" --role "$role" --kafka-cluster "$CLUSTER_ID")
  [ "$resource" != - ] && binding_args+=(--resource "$resource")
  [ "$pattern" = PREFIXED ] && binding_args+=(--prefix)
  if retry 3 5 confluent iam rbac role-binding create "${binding_args[@]}" >/dev/null 2>&1 </dev/null; then ok "$principal $role ${resource#-} ${pattern#-}"
  else fail "$principal $role ${resource#-}"; fi
done < <(grep -v '^#' "$INSTALL_DIR/conf/rbac-opmenu.txt")
[ "$FAIL_COUNT" = 0 ] || die "17.2 失敗"

section "17.3 裝選單"
sudo groupadd -f opmenu
id "$MENU_USER" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash -G opmenu "$MENU_USER"
sudo usermod -aG opmenu "$MENU_USER"
# /opt/opmenu：選單本體（唯讀，root 擁有）
sudo rm -rf /opt/opmenu
sudo tar -xzf "$OPMENU_PACKAGE_DIR"/opmenu-*.tar.gz -C /opt || die "解開 opmenu 套件失敗"
sudo chown -R root:root /opt/opmenu && sudo chmod -R a+rX /opt/opmenu
# /etc/opmenu：保管庫身分（opmenu 群組可讀）、truststore、根憑證、各主機的主機金鑰（ssh 嚴格比對用）
sudo install -d -m 0755 /etc/opmenu /etc/opmenu/ssl
if [ "$OPMENU_SECRETS" = conjur ] && sudo test -s /root/opmenu.key; then
  sudo bash -c 'printf "login=host/%s/opmenu\napi_key=%s\n" "$1" "$(cat /root/opmenu.key)" | install -m 0640 -o root -g opmenu /dev/stdin /etc/opmenu/conjur.identity && rm -f /root/opmenu.key' _ "$VAULT_POLICY"
fi
sudo install -m 0644 "$CERTS_DIR/truststore.p12" /etc/opmenu/ssl/truststore.p12
sudo install -m 0640 -g opmenu "$PKI_DIR/store.pass" /etc/opmenu/ssl/truststore.pass
sudo install -m 0644 "$VAULT_CA" /etc/opmenu/ssl/ca.pem
ssh-keyscan -t ed25519 $(for host in $CLUSTER_HOSTS; do fqdn "$host"; done) 2>/dev/null | sort | sudo install -m 0644 /dev/stdin /etc/opmenu/known_hosts
# /var/log/opmenu：選單紀錄與匯出檔（opmenu 群組可寫）
sudo install -d -m 2775 -o root -g opmenu /var/log/opmenu
# 設定檔只填推算不出來的值：連線位址、可重啟的服務清單、保管庫
export ENV_LABEL=$OPMENU_ENV_LABEL OPMENU_SECRETS VAULT_URL VAULT_ACCOUNT VAULT_POLICY BOOTSTRAP_LDAP=$BROKER_LDAP
export BROKER_SERVICES AUX_SERVICES CONTROLLER_HOSTS
BROKER_SERVICES=$(for host in $BROKERS; do printf '%s:confluent-server ' "$(fqdn "$host")"; done | sed 's/ $//')
AUX_SERVICES=$(for host in $RESTS; do printf '%s:confluent-kafka-rest ' "$(fqdn "$host")"; done; printf '%s:confluent-control-center' "$C3_FQDN")
CONTROLLER_HOSTS=$(for host in $CONTROLLERS; do fqdn "$host"; done | paste -sd' ')
render_template "$TEMPLATE_DIR/opmenu.conf" "$CONF_DIR/opmenu.conf" ENV_LABEL OPMENU_SECRETS BOOTSTRAP_LDAP BROKER_SERVICES AUX_SERVICES CONTROLLER_HOSTS VAULT_URL VAULT_ACCOUNT VAULT_POLICY \
  || die "render opmenu.conf"
sudo install -m 0644 "$CONF_DIR/opmenu.conf" /etc/opmenu/opmenu.conf
listed_items=$(sudo runuser -u "$MENU_USER" -- /opt/opmenu/opmenu.sh --list 2>/dev/null | wc -l)
if [ "$listed_items" -gt 20 ]; then ok "opmenu $(ls /opt/opmenu/items | wc -l) 個項目、known_hosts $(wc -l < /etc/opmenu/known_hosts) 把、$(id "$MENU_USER")"
else die "opmenu --list 失敗（只列出 $listed_items 項）"; fi

section "17.4 各主機 cpadmin 的窄 sudo 規則（restart／status／journalctl confluent-*）"
for host in $CLUSTER_HOSTS; do
  if ssh_script "$host" <<'EOF'
echo 'cpadmin ALL=(root) NOPASSWD: /usr/bin/systemctl restart confluent-*, /usr/bin/systemctl status confluent-*, /usr/bin/journalctl -u confluent-*' \
  | sudo install -m 0440 /dev/stdin /etc/sudoers.d/cpadmin-ops
sudo visudo -cf /etc/sudoers.d/cpadmin-ops >/dev/null
EOF
  then ok "$host: cpadmin-ops"; else fail "$host: sudoers"; fi
done
ask_bank "安裝全部完成後：OS 團隊移除各主機的 /etc/sudoers.d/cpadmin（全權），只留 cpadmin-ops；之後安裝／升級依變更單臨時開。"

section "17.5 試跑：三種身分看到的選單不一樣"
declare -A visible_items
for person in alice bob carol; do
  visible_items[$person]=$(run_menu_as "$person" menu | grep '@@MENU@@' | cut -d' ' -f2-)
  log "$person 看得到：${visible_items[$person]}"
done
alice_count=$(wc -w <<<"${visible_items[alice]}"); bob_count=$(wc -w <<<"${visible_items[bob]}"); carol_count=$(wc -w <<<"${visible_items[carol]}")
if [ "$alice_count" -gt "$bob_count" ] && [ "$bob_count" -gt "$carol_count" ] && [ "$carol_count" -gt 0 ]; then ok "選單依 AD 群組遞減：alice $alice_count > bob $bob_count > carol $carol_count"
else fail "選單數量不符預期：alice $alice_count、bob $bob_count、carol $carol_count"; fi
if grep -qw 91 <<<"${visible_items[alice]}" && ! grep -qw 91 <<<"${visible_items[bob]}"; then ok "91 緊急模式只有 alice（SystemAdmin）看得到"; else fail "91 的可見性不對"; fi

# 下面這幾項要動主機（ssh 用 cpadmin 私鑰）或用緊急憑證；manual 模式的值要人在終端機貼上，非互動試跑做不了
if [ "$OPMENU_SECRETS" = manual ]; then
  warn "OPMENU_SECRETS=manual：健康檢查、重啟、緊急模式要由維運人員互動登入試跑（貼上 PVWA 取出的私鑰）"
else
  health_line=$(run_menu_as bob 11 | grep -E '^-- broker 在線:' | head -1)
  case $health_line in *"$(wc -w <<<"$BROKERS") / "*) ok "bob 11 健康檢查：$health_line";; *) fail "bob 11：${health_line:-無輸出}";; esac
  blocked_line=$(run_menu_as bob 31 orders.x 1 | tail -1)
  case $blocked_line in *"不在你的選單內"*) ok "bob 直接輸入 31（建 topic）被擋";; *) fail "bob 31：$blocked_line";; esac
  restart_host=${BROKERS##* }
  restart_line=$(run_menu_as bob 21 "$(fqdn "$restart_host"):confluent-server" | tail -1)
  case $restart_line in *"已重啟"*) ok "bob 21 重啟 $restart_host：$restart_line";; *) fail "bob 21：$restart_line";; esac
  for attempt in $(seq 1 30); do
    [ "$(curl -sk -o /dev/null -w '%{http_code}' "https://$(fqdn "$restart_host"):8090/v1/metadata/id")" = 200 ] && break
    sleep 5
  done
  if [ "$attempt" -lt 30 ]; then ok "$restart_host 的 MDS 回 200（約 $((attempt * 5)) 秒）"; else fail "$restart_host 重啟後 MDS 沒回來"; fi
  breakglass_topics=$(run_menu_as alice 91 kafka-topics --list | grep -c '^[a-z_]')
  if [ "$breakglass_topics" -gt 3 ]; then ok "alice 91 緊急模式（保管庫的備用憑證）列出 $breakglass_topics 個 topic"; else fail "alice 91：$breakglass_topics"; fi

fi

section "17.6 收尾檢查"
agent_count=$(pgrep -x ssh-agent | wc -l)
keys_on_disk=$(sudo grep -rls 'PRIVATE KEY' "/home/$MENU_USER" /dev/shm 2>/dev/null | wc -l)
reads_identity=$(sudo runuser -u "$MENU_USER" -- cat /etc/opmenu/conjur.identity >/dev/null 2>&1 && echo yes || echo no)
reads_cpadmin_secrets=$(sudo runuser -u "$MENU_USER" -- ls "$SECRETS_DIR" >/dev/null 2>&1 && echo YES || echo no)
summary="ssh-agent=$agent_count 磁碟上的私鑰=$keys_on_disk $MENU_USER讀得到身分檔=$reads_identity $MENU_USER讀得到cpadmin密碼=$reads_cpadmin_secrets"
if [ "$agent_count $keys_on_disk $reads_identity $reads_cpadmin_secrets" = "0 0 yes no" ]; then ok "$summary"; else fail "$summary"; fi
sudo tail -3 /var/log/opmenu/opmenu.log | cut -c1-110 | tee -a "$LOG_FILE"
finish_step
