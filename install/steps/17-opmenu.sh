#!/usr/bin/env bash
# 第 17 站：維運選單（OP menu） —— 操作機上給維運人員的文字選單：本人 AD 身分做 Kafka 作業；主機作業以 cpadmin ssh、私鑰啟動時從保管庫取進 ssh-agent
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"; source "$D/lib/render.sh"; source "$D/lib/vault.sh"
[ "$OPMENU" = 1 ] || { log "OPMENU=$OPMENU：略過第 17 站"; exit 0; }
export JAVA_HOME=/opt/java/current
T=$D/templates; C=$PKI_DIR/certs; OPU=$OPMENU_OS_USER
MDS1=https://$(fqdn "${BROKERS%% *}"):8090

bank "17.1 Secrets 團隊：保管庫加 host 身分 host/$VAULT_POLICY/opmenu 與兩個變數 $VAULT_POLICY/ssh/cpadmin、$VAULT_POLICY/breakglass/pem（opmenu 可讀、ops 可寫）；" \
     "    opmenu 的 API key 交到操作機 root 的 /root/opmenu.key。" \
     "17.3 OS 團隊：操作機上建維運人員的本機帳號（lab：$OPU）；選單套件 opmenu-*.tar.gz 隨落地區送到 $LANDING/tools/opmenu/。" \
     "17.4 OS 團隊：各主機 cpadmin 的 sudo 改成兩段式（永久只留 restart／status／journalctl 三件事；安裝期全權做完收回）。"
section "確認銀行的準備"
sudo test -s /root/opmenu.key && ok "/root/opmenu.key 在" || { sudo test -s /etc/opmenu/conjur.identity && ok "/etc/opmenu/conjur.identity 已存在（之前裝過）" || fail "沒有 /root/opmenu.key"; }
[ -f "$LANDING/tools/opmenu/SHA256SUMS" ] && (cd "$LANDING/tools/opmenu" && sha256sum -c --quiet SHA256SUMS) && ok "opmenu 套件 sha256 相符" || fail "$LANDING/tools/opmenu 缺檔或 sha256 不符"
[ -s "$VAULT_OPS_KEY" ] && ok "$VAULT_OPS_KEY 在" || fail "沒有 $VAULT_OPS_KEY"
[ "${FAILED:-0}" = 0 ] || pending

section "17.2 把值寫進保管庫（cpadmin 私鑰、緊急憑證 PEM），綁權限（緊急身分 SystemAdmin；維運群組補 DescribeConfigs）"
vault_login_ops || die "ops 身分登入失敗"
vault_set ssh/cpadmin < ~/.ssh/id_ed25519 && ok "ssh key stored（正式環境是 CPM 產生的那把）" || fail "ssh/cpadmin"
cat "$PKI_DIR/keys/opmenu-breakglass.key" "$C/opmenu-breakglass.crt" | vault_set breakglass/pem && ok "breakglass pem stored" || fail "breakglass/pem"
vault_logout
confluent login --url "$MDS1" --certificate-authority-path "$C/bank-root.pem" --certificate-only --client-cert-path "$C/svc-ops.crt" --client-key-path "$PKI_DIR/keys/svc-ops.key" >/dev/null 2>&1 || die "confluent login 失敗"
source "$CONF_DIR/kraft.env"
while read -r p role res pat; do
  [ -n "$p" ] || continue
  args=(--principal "$p" --role "$role" --kafka-cluster "$CLUSTER_ID"); [ "$res" != "-" ] && args+=(--resource "$res"); [ "$pat" = PREFIXED ] && args+=(--prefix)
  confluent iam rbac role-binding create "${args[@]}" >/dev/null 2>&1 </dev/null && ok "rbac $p $role ${res#-} ${pat#-}" || fail "rbac $p $role"
done < <(grep -v '^#' "$D/conf/rbac-opmenu.txt")
[ "${FAILED:-0}" = 0 ] || die "17.2 失敗"

section "17.3 裝選單：$OPU 與 opmenu 群組、/opt/opmenu（唯讀）、/etc/opmenu（設定、保管庫身分、truststore、known_hosts）、/var/log/opmenu"
sudo groupadd -f opmenu && (id "$OPU" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash -G opmenu "$OPU") && sudo usermod -aG opmenu "$OPU"
sudo rm -rf /opt/opmenu && sudo tar -xzf "$LANDING"/tools/opmenu/opmenu-*.tar.gz -C /opt && sudo chown -R root:root /opt/opmenu && sudo chmod -R a+rX /opt/opmenu || die "解開 opmenu 失敗"
sudo install -d -m 0755 /etc/opmenu /etc/opmenu/ssl
if sudo test -s /root/opmenu.key; then sudo bash -c 'printf "login=host/'"$VAULT_POLICY"'/opmenu\napi_key=%s\n" "$(cat /root/opmenu.key)" | install -m 0640 -o root -g opmenu /dev/stdin /etc/opmenu/conjur.identity && rm -f /root/opmenu.key'; fi
sudo install -m 0644 "$C/truststore.p12" /etc/opmenu/ssl/truststore.p12 && sudo install -m 0640 -g opmenu "$PKI_DIR/store.pass" /etc/opmenu/ssl/truststore.pass && sudo install -m 0644 "$VAULT_CA" /etc/opmenu/ssl/ca.pem
ssh-keyscan -t ed25519 $(for h in $CLUSTER_HOSTS; do fqdn "$h"; done) 2>/dev/null | sort | sudo install -m 0644 /dev/stdin /etc/opmenu/known_hosts
sudo install -d -m 2775 -o root -g opmenu /var/log/opmenu
export ENV_LABEL=$OPMENU_ENV_LABEL VAULT_URL VAULT_ACCOUNT VAULT_POLICY
export BOOTSTRAP_LDAP; BOOTSTRAP_LDAP=$(join_fqdn 9096 $BROKERS)
export BROKER_SERVICES; BROKER_SERVICES=$(for h in $BROKERS; do printf '%s:confluent-server ' "$(fqdn "$h")"; done | sed 's/ $//')
export AUX_SERVICES; AUX_SERVICES=$(for h in $RESTS; do printf '%s:confluent-kafka-rest ' "$(fqdn "$h")"; done; printf '%s:confluent-control-center' "$C3_FQDN")
export CONTROLLER_HOSTS; CONTROLLER_HOSTS=$(for h in $CONTROLLERS; do fqdn "$h"; done | paste -sd' ')
render "$T/opmenu.conf" "$CONF_DIR/opmenu.conf" ENV_LABEL BOOTSTRAP_LDAP BROKER_SERVICES AUX_SERVICES CONTROLLER_HOSTS VAULT_URL VAULT_ACCOUNT VAULT_POLICY || die "render opmenu.conf"
sudo install -m 0644 "$CONF_DIR/opmenu.conf" /etc/opmenu/opmenu.conf
n=$(sudo runuser -u "$OPU" -- /opt/opmenu/opmenu.sh --list 2>/dev/null | wc -l)
[ "$n" -gt 20 ] && ok "opmenu $(ls /opt/opmenu/items | wc -l) items（--list 列出 $n 項）; known_hosts $(wc -l < /etc/opmenu/known_hosts) keys; $(id "$OPU")" || die "opmenu --list 失敗（$n 項）"

section "17.4 各主機 cpadmin 的 sudo 兩段式：加上窄規則（全權那份由 OS 團隊在安裝完成後收回）"
for h in $CLUSTER_HOSTS; do
  rsh "$h" 'printf "cpadmin ALL=(root) NOPASSWD: /usr/bin/systemctl restart confluent-*, /usr/bin/systemctl status confluent-*, /usr/bin/journalctl -u confluent-*\n" | sudo install -m 0440 /dev/stdin /etc/sudoers.d/cpadmin-ops && sudo visudo -cf /etc/sudoers.d/cpadmin-ops >/dev/null' && ok "$h: cpadmin-ops" || fail "$h: sudoers"
done
bank "安裝全部完成後，OS 團隊移除各主機的 /etc/sudoers.d/cpadmin（全權），只留 cpadmin-ops；之後安裝／升級再依變更單臨時開。"

section "17.5 試跑：三種身分看到的選單不一樣（非互動 --run；正式環境把 OPMENU_ALLOW_ENV_OVERRIDE 拿掉）"
P=$(cat "$SECRETS_DIR/ad-test-users.pass")
op() { local u=$1; shift; sudo env OPMENU_USER="$u" OPMENU_PASS="$P" OPMENU_YES=1 OPMENU_REASON="第 17 站試跑" JAVA_HOME=/opt/java/current HOME=/home/$OPU runuser -p -u "$OPU" -- /opt/opmenu/opmenu.sh --run "$@" 2>&1 </dev/null | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g'; }
declare -A MENU
for u in alice bob carol; do MENU[$u]=$(op $u menu | grep '@@MENU@@' | cut -d' ' -f2-); log "$u: ${MENU[$u]}"; done
[ "$(wc -w <<<"${MENU[alice]}")" -gt "$(wc -w <<<"${MENU[bob]}")" ] && [ "$(wc -w <<<"${MENU[bob]}")" -gt "$(wc -w <<<"${MENU[carol]}")" ] && [ "$(wc -w <<<"${MENU[carol]}")" -gt 0 ] && ok "選單依 AD 群組遞減：alice > bob > carol > 0" || fail "選單數量不符預期"
grep -qw 91 <<<"${MENU[alice]}" && ! grep -qw 91 <<<"${MENU[bob]}" && ok "91 緊急模式只有 alice（SystemAdmin）看得到" || fail "91 的可見性不對"
r=$(op bob 11 | grep -E '^-- broker 在線:' | head -1); [[ $r == *"$(wc -w <<<"$BROKERS") / "* ]] && ok "bob 11 健康檢查：$r" || fail "bob 11：${r:-無輸出}"
r=$(op bob 31 orders.x 1 | tail -1); [[ $r == *"不在你的選單內"* ]] && ok "bob 直接打 31 被擋" || fail "bob 31：$r"
h=${BROKERS##* }; r=$(op bob 21 "$(fqdn "$h"):confluent-server" | tail -1); [[ $r == *"已重啟"* ]] && ok "bob 21 重啟 $h：$r" || fail "bob 21：$r"
for i in $(seq 1 30); do [ "$(curl -sk -o /dev/null -w '%{http_code}' "https://$(fqdn "$h"):8090/v1/metadata/id")" = 200 ] && break; sleep 5; done; [ "$i" -lt 30 ] && ok "$h MDS 回 200（~$((i*5))s）" || fail "$h 重啟後 MDS 沒回來"
r=$(op alice 91 kafka-topics --list | grep -c '^[a-z_]'); [ "$r" -gt 3 ] && ok "alice 91 緊急模式（保管庫憑證）列出 $r 個 topic" || fail "alice 91：$r"
unset P

section "17.6 收尾檢查：沒有 ssh-agent、磁碟上沒有私鑰、$OPU 讀得到保管庫身分檔但讀不到 cpadmin 的檔案"
r="ssh-agent=$(pgrep -x ssh-agent | wc -l) keys_on_disk=$(sudo grep -rls 'PRIVATE KEY' /home/$OPU /dev/shm 2>/dev/null | wc -l) reads_identity=$(sudo runuser -u "$OPU" -- cat /etc/opmenu/conjur.identity >/dev/null 2>&1 && echo yes || echo no) reads_cpadmin_secrets=$(sudo runuser -u "$OPU" -- ls "$SECRETS_DIR" >/dev/null 2>&1 && echo YES || echo no)"
[ "$r" = "ssh-agent=0 keys_on_disk=0 reads_identity=yes reads_cpadmin_secrets=no" ] && ok "$r" || fail "$r"
sudo tail -3 /var/log/opmenu/opmenu.log | cut -c1-110 | tee -a "$LOG_FILE"
finish
