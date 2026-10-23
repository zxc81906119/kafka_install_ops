#!/usr/bin/env bash
# 第 15 站：把密碼搬進 CyberArk Conjur —— properties 只留 ${cyberark:…} 參照，服務啟動時向 Conjur 取（銀行有 Conjur 才用；與第 16 站二選一）
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"; source "$D/lib/render.sh"; source "$D/lib/vault.sh"
[ "$SECRETS_MODE" = conjur ] || { log "SECRETS_MODE=$SECRETS_MODE：第 15 站不適用，略過"; exit 0; }
export JAVA_HOME=/opt/java/current
T=$D/templates; C=$PKI_DIR/certs
SCRAM_APPS=$(grep -v '^#' "$D/conf/apps.txt" | awk '$2=="scram"{print $1}')

bank "15.1 Secrets 團隊：建 Conjur（$VAULT_URL，憑證由銀行 CA 簽）、載入 policy「$VAULT_POLICY」：11 台主機各一個 host 身分（host/$VAULT_POLICY/<主機>）、一個寫值用的 user ops、" \
     "    變數 store-password、ldap-bind-password、audit-password、scram/<app>（主機只能讀，ops 能寫）；" \
     "    每台主機自己的 host API key 放到 $VAULT_HOST_KEY（0640 root:confluent），ops 的 API key 放到 $VAULT_OPS_KEY（0600）。" \
     "    provider jar（下載機 steps/15a 建的 4 個 jar）隨落地區送到 $LANDING/tools/csid/。"
section "確認銀行的準備"
c=$(curl -s --cacert "$VAULT_CA" -o /dev/null -m 10 -w '%{http_code}' "$VAULT_URL/"); [ "$c" = 200 ] && ok "Conjur $VAULT_URL：$c（憑證鏈由銀行根憑證驗過）" || fail "Conjur $VAULT_URL：$c"
for h in $ALL_HOSTS; do rsh "$h" "sudo test -s $VAULT_HOST_KEY" && ok "$h：host key 在" || fail "$h：沒有 $VAULT_HOST_KEY"; done
[ -s "$VAULT_OPS_KEY" ] && ok "$VAULT_OPS_KEY 在" || fail "沒有 $VAULT_OPS_KEY"
[ "$(ls "$LANDING"/tools/csid/*.jar 2>/dev/null | wc -l)" = 4 ] && ok "provider jar 4 個" || fail "$LANDING/tools/csid 沒有 4 個 jar（先在下載機跑 steps/15-conjur-provider-jar.sh）"
[ "${FAILED:-0}" = 0 ] || pending

section "15.2 把目前在用的密碼寫進 Conjur（值從 0600 檔讀，不出現在畫面上），再以 kb01 的 host 身分讀一次確認主機拿得到"
vault_login_ops || die "ops 身分登入 Conjur 失敗"
tr -d '\n' < "$PKI_DIR/store.pass" | vault_set store-password && ok "set $VAULT_POLICY/store-password" || fail "store-password"
tr -d '\n' < "$SECRETS_DIR/ldap-bind.pass" | vault_set ldap-bind-password && ok "set $VAULT_POLICY/ldap-bind-password" || fail "ldap-bind-password"
for a in $SCRAM_APPS; do tr -d '\n' < "$SECRETS_DIR/$a.pass" | vault_set "scram/$a" && ok "set $VAULT_POLICY/scram/$a" || fail "scram/$a"; done
vault_logout
vault_login_host "${BROKERS%% *}" && [ "$(vault_get store-password)" = "$(tr -d '\n' < "$PKI_DIR/store.pass")" ] && ok "${BROKERS%% *} 以 host 身分讀 store-password：相符" || fail "${BROKERS%% *} host 身分讀值失敗或不符"
vault_logout
[ "${FAILED:-0}" = 0 ] || die "寫值失敗"

section "15.3 派送 jar 到 /usr/share/java/cp-secrets/，並讓 JDK 的 cacerts 信任銀行根憑證（provider 連 Conjur 走 JVM 預設信任庫）"
for h in $ALL_HOSTS; do
  rcp "$h" "$LANDING"/tools/csid/*.jar || { fail "$h: scp"; continue; }
  r=$(rsh "$h" 'sudo install -d -m 0755 /usr/share/java/cp-secrets && sudo install -m 0644 /tmp/*.jar /usr/share/java/cp-secrets/ && rm -f /tmp/*.jar && sudo /opt/java/current/bin/keytool -importcert -noprompt -cacerts -storepass changeit -alias bank-root -file /etc/pki/ca-trust/source/anchors/bank-root.pem >/dev/null 2>&1; echo "$(ls /usr/share/java/cp-secrets | wc -l) jars, cacerts=$(/opt/java/current/bin/keytool -list -cacerts -storepass changeit -alias bank-root >/dev/null 2>&1 && echo ok || echo missing)"')
  [ "$r" = "4 jars, cacerts=ok" ] && ok "$h: $r" || fail "$h: $r"
done
[ "${FAILED:-0}" = 0 ] || die "jar 派送失敗"

section "15.4 properties 只留參照：所有範本的 \${STORE_PASSWORD}／\${LDAP_BIND_PASSWORD} 換成 \${cyberark:<變數>:<變數>}，三個有 provider 設定的範本接上 conjur.tpl"
install -d -m 0700 "$CONF_DIR/conjur"
for t in common controller broker kafka-rest control-center; do
  sed -e "s|\${STORE_PASSWORD}|\${cyberark:$VAULT_POLICY/store-password:$VAULT_POLICY/store-password}|g" -e "s|\${LDAP_BIND_PASSWORD}|\${cyberark:$VAULT_POLICY/ldap-bind-password:$VAULT_POLICY/ldap-bind-password}|g" "$T/$t.tpl" > "$CONF_DIR/conjur/$t.tpl"
  case $t in common|kafka-rest|control-center) cat "$T/conjur.tpl" >> "$CONF_DIR/conjur/$t.tpl";; esac
done
left=$(grep -l 'STORE_PASSWORD\|LDAP_BIND_PASSWORD' "$CONF_DIR"/conjur/*.tpl | wc -l); [ "$left" = 0 ] && ok "還留著明文密碼變數的範本：0（broker 範本 listener 專用的 keystore 密碼也要換到，否則起來會報 keystore password was incorrect）" || die "還有 $left 個範本留著 \${STORE_PASSWORD}"
export CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP VAULT_URL VAULT_ACCOUNT VAULT_POLICY
export REST_APPS; REST_APPS=$(grep -v '^#' "$D/conf/apps.txt" | awk '$2=="cert"{print $1}' | paste -sd'|')
VARS="HOST_FQDN NODE_ID RACK REST_ID HOST_SHORT CONJUR_API_KEY CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP REST_APPS VAULT_URL VAULT_ACCOUNT VAULT_POLICY"
dest_of() { case $1 in rest*) echo /etc/confluent/kafka-rest/kafka-rest.properties;; c3*) echo /etc/confluent/control-center/control-center.properties;; *) echo /etc/confluent/kafka/server.properties;; esac; }
unit_of() { case $1 in rest*) echo confluent-kafka-rest;; c3*) echo confluent-control-center;; *) echo confluent-server;; esac; }
for h in $CLUSTER_HOSTS; do
  export HOST_FQDN; HOST_FQDN=$(fqdn "$h"); export HOST_SHORT=$h; export CONJUR_API_KEY; CONJUR_API_KEY=$(rsh "$h" "sudo cat $VAULT_HOST_KEY")
  case $h in kc*|kb*) id_var=NODE_ID_$h; rack_var=RACK_$h; export NODE_ID=${!id_var} RACK=${!rack_var};; *) export NODE_ID=0 RACK=-;; esac; export REST_ID=$h
  out=$CONF_DIR/conjur/$h.properties
  case $h in
    kc*) render_cat "$out" $VARS -- "$CONF_DIR/conjur/controller.tpl" "$CONF_DIR/conjur/common.tpl";;
    kb*) render_cat "$out" $VARS -- "$CONF_DIR/conjur/broker.tpl" "$CONF_DIR/conjur/common.tpl";;
    rest*) render "$CONF_DIR/conjur/kafka-rest.tpl" "$out" $VARS;;
    c3*) render "$CONF_DIR/conjur/control-center.tpl" "$out" $VARS;;
  esac || { fail "$h: render"; continue; }
  dst=$(dest_of "$h")
  rcp "$h" "$out" || { fail "$h: scp"; continue; }
  r=$(rsh "$h" "sudo install -o root -g confluent -m 0640 /tmp/$h.properties $dst && rm -f /tmp/$h.properties && echo \"refs=\$(sudo grep -c '\\\${cyberark:' $dst) unresolved=\$(sudo grep '\\\${' $dst | grep -vc '\\\${cyberark:') plaintext=\$(sudo grep -cE '^[a-z.]*password=[^\$]' $dst)\"")
  [[ $r == *"unresolved=0 plaintext=0" ]] && ok "$h: $r" || fail "$h: $r"
done
unset CONJUR_API_KEY
[ "${FAILED:-0}" = 0 ] || die "設定派送失敗"

section "15.5 讓服務載入 jar（Kafka／REST 看 CLASSPATH，C3 只看 CONTROL_CENTER_CLASSPATH），拿掉第 16 站的 drop-in（若有），滾動重啟"
for h in $CLUSTER_HOSTS; do
  u=$(unit_of "$h"); case $h in c3*) v=CONTROL_CENTER_CLASSPATH;; *) v=CLASSPATH;; esac
  r=$(rsh "$h" "printf '[Service]\nEnvironment=\"$v=/usr/share/java/cp-secrets/*\"\n' | sudo tee /etc/systemd/system/$u.service.d/20-conjur.conf >/dev/null && sudo rm -f /etc/systemd/system/$u.service.d/20-secret-protection.conf /etc/systemd/system/$u.service.d/30-summon.conf /etc/confluent/service.env && sudo systemctl daemon-reload && systemctl show $u -p Environment --value | tr ' ' '\n' | grep -o '[A-Z_]*CLASSPATH=[^ ]*'")
  [[ $r == *"CLASSPATH=/usr/share/java/cp-secrets/*"* ]] && ok "$h: $r" || fail "$h: $r"
done
[ "${FAILED:-0}" = 0 ] || die "drop-in 失敗"
for h in $CONTROLLERS; do restart_wait "$h" confluent-server - | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
for h in $BROKERS; do restart_wait "$h" confluent-server "https://$(fqdn "$h"):8090/v1/metadata/id" | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
APP=${REST_APPS%%|*}; export RW_CURL_OPTS="--cert $C/$APP.crt --key $PKI_DIR/keys/$APP.key"
for h in $RESTS; do restart_wait "$h" confluent-kafka-rest "https://$(fqdn "$h"):8082/v3/clusters" | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
unset RW_CURL_OPTS
restart_wait "$C3_HOST" confluent-control-center "https://$C3_FQDN:9021/" 420 | tee -a "$LOG_FILE" | grep -q after || fail "$C3_HOST restart"
[ "${FAILED:-0}" = 0 ] || die "滾動重啟有主機沒健康"

section "15.6 驗證：主機上沒有明文、provider 真的有去 Conjur、人員登入正常"
for h in ${BROKERS%% *} ${RESTS%% *} $C3_HOST; do
  r=$(rsh "$h" "echo \"plaintext=\$(sudo grep -cE '^[a-z.]*password=[^\$]' $(dest_of "$h")) provider_log=\$(sudo journalctl -u $(unit_of "$h") --since '-10min' --no-pager | grep -ci cyberark)\"")
  [[ $r == plaintext=0* && $r != *provider_log=0 ]] && ok "$h: $r" || fail "$h: $r"
done
c=$(curl -s --cacert "$VAULT_CA" -u "alice:$(cat "$SECRETS_DIR/ad-test-users.pass")" -o /dev/null -w '%{http_code}' "https://$(fqdn "${BROKERS%% *}"):8090/security/1.0/authenticate"); [ "$c" = 200 ] && ok "alice 登入 MDS：$c" || fail "alice 登入：$c"
echo conjur > "$CONF_DIR/secrets.mode"
log "secret zero：各主機 properties 裡的 cyberark.auth.apikey（0640）；換 AD 密碼＝改 AD、改 Conjur 的值、滾動重啟（手把手 15.7）"
finish
