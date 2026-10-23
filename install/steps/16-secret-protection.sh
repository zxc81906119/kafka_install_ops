#!/usr/bin/env bash
# 第 16 站：Secret Protection —— 密碼加密留在主機的 security.properties，master key 交 CyberArk 保管（只有 PAM 的銀行；與第 15 站二選一）
#   SUMMON=1：master key 不落地，啟動時由 Summon 向保管庫取（16.8）；LDAP_PASSWORD_VIA_ENV=1：AD 查詢密碼不進密文、Summon 注入 ${env:…}（16.9）
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"; source "$D/lib/render.sh"; source "$D/lib/vault.sh"
[ "$SECRETS_MODE" = sp ] || { log "SECRETS_MODE=$SECRETS_MODE：第 16 站不適用，略過"; exit 0; }
[ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && [ "$SUMMON" != 1 ] && die "LDAP_PASSWORD_VIA_ENV=1 需要 SUMMON=1（注入靠 Summon）"
export JAVA_HOME=/opt/java/current
T=$D/templates; C=$PKI_DIR/certs; SP=$CONF_DIR/sp; REMOTE_SEC=/etc/confluent/secrets/security.properties
REST_APPS=$(grep -v '^#' "$D/conf/apps.txt" | awk '$2=="cert"{print $1}' | paste -sd'|'); APP=${REST_APPS%%|*}
dest_of() { case $1 in rest*) echo /etc/confluent/kafka-rest/kafka-rest.properties;; c3*) echo /etc/confluent/control-center/control-center.properties;; *) echo /etc/confluent/kafka/server.properties;; esac; }
unit_of() { case $1 in rest*) echo confluent-kafka-rest;; c3*) echo confluent-control-center;; *) echo confluent-server;; esac; }
svc_of()  { case $1 in rest*) echo cp-kafka-rest;; c3*) echo cp-control-center;; *) echo cp-kafka;; esac; }
start_of(){ case $1 in rest*) echo "/usr/bin/kafka-rest-start /etc/confluent/kafka-rest/kafka-rest.properties";; c3*) echo "/usr/bin/control-center-start /etc/confluent/control-center/control-center.properties";; *) echo "/usr/bin/kafka-server-start /etc/confluent/kafka/server.properties";; esac; }

bank "16.1 Secrets 團隊：保管庫（lab 用 Conjur 扮演 PAM Vault）裡放 $VAULT_POLICY/secret-protection/passphrase（銀行產生，只給 ops 與操作機的 host 身分讀）；" \
     "    操作機要有自己的 host 身分 $VAULT_HOST_KEY。" \
     "$([ "$SUMMON" = 1 ] && echo "16.8 另加變數 $VAULT_POLICY/secret-protection/master-key（ops 可寫、所有主機可讀）；每台主機都要有 host 身分；Summon 兩個執行檔在 $LANDING/tools/summon/。")" \
     "$([ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && echo "16.9 變數 $VAULT_POLICY/ldap-bind-password 要存在且主機可讀（CPM 換 AD 查詢密碼時同步更新它）。")"
section "確認銀行的準備"
c=$(curl -s --cacert "$VAULT_CA" -o /dev/null -m 10 -w '%{http_code}' "$VAULT_URL/"); [ "$c" = 200 ] && ok "保管庫 $VAULT_URL：$c" || fail "保管庫 $VAULT_URL：$c"
sudo test -s "$VAULT_HOST_KEY" && ok "$OPS_HOST host key 在" || fail "$OPS_HOST 沒有 $VAULT_HOST_KEY"
if vault_login_host "$OPS_HOST" 2>/dev/null; then vault_has secret-protection/passphrase && ok "passphrase 讀得到" || fail "secret-protection/passphrase 不存在或無權讀"; vault_logout; else fail "操作機 host 身分登入保管庫失敗"; fi
if [ "$SUMMON" = 1 ]; then
  for h in $CLUSTER_HOSTS; do rsh "$h" "sudo test -s $VAULT_HOST_KEY" && ok "$h：host key 在" || fail "$h：沒有 $VAULT_HOST_KEY"; done
  [ -f "$LANDING/tools/summon/SHA256SUMS" ] && (cd "$LANDING/tools/summon" && sha256sum -c --quiet SHA256SUMS) && ok "Summon 執行檔 sha256 相符" || fail "$LANDING/tools/summon 缺檔或 sha256 不符"
  [ -s "$VAULT_OPS_KEY" ] && ok "$VAULT_OPS_KEY 在（寫 master key 用）" || fail "沒有 $VAULT_OPS_KEY"
fi
[ "${FAILED:-0}" = 0 ] || pending

section "16.2 取 passphrase、產生 master key（已有 master.key 就沿用）"
if [ -s "$SECRETS_DIR/master.key" ]; then ok "沿用既有的 $SECRETS_DIR/master.key 與 security.properties"; else
  vault_login_host "$OPS_HOST" || die "登入保管庫失敗"
  (umask 077; vault_get secret-protection/passphrase > "$SECRETS_DIR/sp-passphrase.txt"); vault_logout
  [ "$(wc -c < "$SECRETS_DIR/sp-passphrase.txt")" -ge 16 ] || die "passphrase 太短或取值失敗"
  rm -f "$SECRETS_DIR/security.properties"
  (umask 077; confluent secret master-key generate --local-secrets-file "$SECRETS_DIR/security.properties" --passphrase @"$SECRETS_DIR/sp-passphrase.txt" -o yaml | awk '/master_key/{print $2}' > "$SECRETS_DIR/master.key")
  [ "$(wc -c < "$SECRETS_DIR/master.key")" -ge 40 ] && ok "master key 產生（$SECRETS_DIR/master.key，0600；由 passphrase 推導，CLI 不保存）" || die "master key 產生失敗"
fi

section "16.3 從明文範本重新產生每台設定，逐檔加密 password／credentials 欄位（密文集中在 security.properties）"
install -d -m 0700 "$SP"
export STORE_PASSWORD; STORE_PASSWORD=$(cat "$PKI_DIR/store.pass"); export LDAP_BIND_PASSWORD; LDAP_BIND_PASSWORD=$(cat "$SECRETS_DIR/ldap-bind.pass")
export CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP REST_APPS
VARS="HOST_FQDN NODE_ID RACK REST_ID STORE_PASSWORD LDAP_BIND_PASSWORD CONTROLLER_QUORUM BROKER_INTERNAL BROKER_TOKEN MDS_URLS AD_FQDN AD_LDAPS_PORT AD_BIND_DN AD_SEARCH_BASE AD_GROUP_SEARCH_BASE C3_FQDN REST_VIP REST_APPS"
EXTRA_TPL=""; [ -f "$CONF_DIR/audit.rendered.tpl" ] && EXTRA_TPL=$CONF_DIR/audit.rendered.tpl   # 第 19 站做過的話把稽核片段一起帶上
for h in $CLUSTER_HOSTS; do
  export HOST_FQDN; HOST_FQDN=$(fqdn "$h"); case $h in kc*|kb*) id_var=NODE_ID_$h; rack_var=RACK_$h; export NODE_ID=${!id_var} RACK=${!rack_var};; *) export NODE_ID=0 RACK=-;; esac; export REST_ID=$h
  out=$SP/$h.properties
  case $h in
    kc*) render_cat "$out" $VARS -- "$T/controller.tpl" "$T/common.tpl" $EXTRA_TPL;;
    kb*) render_cat "$out" $VARS -- "$T/broker.tpl" "$T/common.tpl" $EXTRA_TPL;;
    rest*) render "$T/kafka-rest.tpl" "$out" $VARS;;
    c3*) render "$T/control-center.tpl" "$out" $VARS;;
  esac || { fail "$h: render"; continue; }
done
unset STORE_PASSWORD LDAP_BIND_PASSWORD
[ "${FAILED:-0}" = 0 ] || die "render 失敗"
export CONFLUENT_SECURITY_MASTER_KEY; CONFLUENT_SECURITY_MASTER_KEY=$(cat "$SECRETS_DIR/master.key")
for h in $CLUSTER_HOSTS; do
  f=$SP/$h.properties
  if [ "$LDAP_PASSWORD_VIA_ENV" = 1 ]; then sed -i 's|^ldap.java.naming.security.credentials=.*|ldap.java.naming.security.credentials=${env:LDAP_BIND_PASSWORD}|' "$f"; fi
  protect_file "$f" "$SECRETS_DIR/security.properties" "$REMOTE_SEC" || { fail "$h: encrypt"; continue; }
  [ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && grep -q '^ldap.java.naming.security.credentials' "$f" && ldap_via_env "$f"
  pc=$(plaintext_count "$f"); r="$(grep -c '${securepass:' "$f") encrypted, plaintext=$pc$([ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && grep -q 'env:LDAP_BIND_PASSWORD' "$f" && echo ', ldap via env')"; [ "$pc" = 0 ] && ok "$h: $r" || fail "$h: $r"
done
unset CONFLUENT_SECURITY_MASTER_KEY
[ "${FAILED:-0}" = 0 ] || die "加密失敗"
ok "security.properties：$(grep -c '^[^_].*ENC\[' "$SECRETS_DIR/security.properties") entries"

if [ "$SUMMON" = 1 ]; then
  section "16.8 master key 寫進保管庫（去掉檔尾換行，否則 Summon 取回的值多一個換行、服務解不開密文）"
  vault_login_ops || die "ops 身分登入失敗"
  tr -d '\n' < "$SECRETS_DIR/master.key" | vault_set secret-protection/master-key && ok "set $VAULT_POLICY/secret-protection/master-key" || die "寫 master key 失敗"
  vault_logout
fi

section "16.4 派送：properties、security.properties（0640 root:confluent）$([ "$SUMMON" = 1 ] && echo '、Summon（執行檔、conjur.conf、host 身分檔、secrets.yml、30-summon drop-in）' || echo '、service.env（0600 root）+ EnvironmentFile drop-in')；拿掉第 15 站的 20-conjur.conf（若有）"
[ "$SUMMON" = 1 ] || (umask 077; echo "CONFLUENT_SECURITY_MASTER_KEY=$(cat "$SECRETS_DIR/master.key")" > "$SP/service.env")
for h in $CLUSTER_HOSTS; do
  u=$(unit_of "$h"); dst=$(dest_of "$h"); svc=$(svc_of "$h")
  files="$SP/$h.properties $SECRETS_DIR/security.properties"; [ "$SUMMON" = 1 ] && files="$files $LANDING/tools/summon/summon-linux-amd64.tar.gz $LANDING/tools/summon/summon-conjur-linux-amd64.tar.gz" || files="$files $SP/service.env"
  rcp "$h" $files || { fail "$h: scp"; continue; }
  common="sudo install -o root -g confluent -m 0640 /tmp/$h.properties $dst && sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets && sudo install -o root -g confluent -m 0640 /tmp/security.properties $REMOTE_SEC && rm -f /tmp/$h.properties /tmp/security.properties && sudo rm -f /etc/systemd/system/$u.service.d/20-conjur.conf"
  if [ "$SUMMON" = 1 ]; then
    secrets_yml='CONFLUENT_SECURITY_MASTER_KEY: !var '"$VAULT_POLICY"'/secret-protection/master-key\n'; [ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && case $h in kc*|kb*) secrets_yml+='LDAP_BIND_PASSWORD: !var '"$VAULT_POLICY"'/ldap-bind-password\n';; esac
    r=$(rsh "$h" "$common && sudo install -d -m 0755 /usr/local/lib/summon && sudo tar -xzf /tmp/summon-linux-amd64.tar.gz -C /usr/local/bin summon && sudo tar -xzf /tmp/summon-conjur-linux-amd64.tar.gz -C /usr/local/lib/summon summon-conjur && rm -f /tmp/summon*.tar.gz && sudo chmod 0755 /usr/local/bin/summon /usr/local/lib/summon/summon-conjur && printf 'appliance_url: $VAULT_URL\naccount: $VAULT_ACCOUNT\ncert_file: $VAULT_CA\nnetrc_path: /etc/conjur.identity\n' | sudo tee /etc/conjur.conf >/dev/null && printf 'machine $VAULT_URL/authn\n  login host/$VAULT_POLICY/$h\n  password %s\n' \"\$(sudo cat $VAULT_HOST_KEY)\" | sudo install -m 0640 -o root -g confluent /dev/stdin /etc/conjur.identity && printf '$secrets_yml' | sudo tee /etc/confluent/secrets.yml >/dev/null && printf '[Service]\nExecStart=\nExecStart=/usr/local/bin/summon -p /usr/local/lib/summon/summon-conjur -f /etc/confluent/secrets.yml $(start_of "$h")\n' | sudo tee /etc/systemd/system/$u.service.d/30-summon.conf >/dev/null && sudo rm -f /etc/systemd/system/$u.service.d/20-secret-protection.conf /etc/confluent/service.env && sudo systemctl daemon-reload && a=\$(sudo -u $svc /usr/local/bin/summon -p /usr/local/lib/summon/summon-conjur -f /etc/confluent/secrets.yml printenv CONFLUENT_SECURITY_MASTER_KEY | tr -d '\n' | sha256sum | cut -c1-12) && echo \"summon as $svc: \$([ \$a = $(tr -d '\n' < "$SECRETS_DIR/master.key" | sha256sum | cut -c1-12) ] && echo key-matches || echo MISMATCH) exec=\$(systemctl show $u -p ExecStart --value | grep -o 'path=[^ ]*' | head -1 | cut -d= -f2) refs=\$(sudo grep -c 'securepass:' $dst)\"")
    [[ $r == *"key-matches exec=/usr/local/bin/summon"* ]] && ok "$h: $r" || fail "$h: $r"
  else
    r=$(rsh "$h" "$common && sudo install -o root -g root -m 0600 /tmp/service.env /etc/confluent/service.env && rm -f /tmp/service.env && sudo rm -f /etc/systemd/system/$u.service.d/30-summon.conf && printf '[Service]\nEnvironmentFile=/etc/confluent/service.env\n' | sudo tee /etc/systemd/system/$u.service.d/20-secret-protection.conf >/dev/null && sudo systemctl daemon-reload && echo \"refs=\$(sudo grep -c 'securepass:' $dst) env=\$(systemctl show $u -p EnvironmentFiles --value | cut -d' ' -f1)\"")
    [[ $r == *"env=/etc/confluent/service.env" ]] && ok "$h: $r" || fail "$h: $r"
  fi
done
rm -f "$SP/service.env"
[ "${FAILED:-0}" = 0 ] || die "派送失敗，不重啟"

section "16.5 滾動重啟、驗證"
for h in $CONTROLLERS; do restart_wait "$h" confluent-server - | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
for h in $BROKERS; do restart_wait "$h" confluent-server "https://$(fqdn "$h"):8090/v1/metadata/id" | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
export RW_CURL_OPTS="--cert $C/$APP.crt --key $PKI_DIR/keys/$APP.key"
for h in $RESTS; do restart_wait "$h" confluent-kafka-rest "https://$(fqdn "$h"):8082/v3/clusters" | tee -a "$LOG_FILE" | grep -q after || fail "$h restart"; done
unset RW_CURL_OPTS
restart_wait "$C3_HOST" confluent-control-center "https://$C3_FQDN:9021/" 420 | tee -a "$LOG_FILE" | grep -q after || fail "$C3_HOST restart"
[ "${FAILED:-0}" = 0 ] || die "滾動重啟有主機沒健康"
c=$(curl -s --cacert "$VAULT_CA" -u "alice:$(cat "$SECRETS_DIR/ad-test-users.pass")" -o /dev/null -w '%{http_code}' "https://$(fqdn "${BROKERS%% *}"):8090/security/1.0/authenticate"); [ "$c" = 200 ] && ok "alice 登入 MDS：$c" || fail "alice 登入：$c"
if [ "$LDAP_PASSWORD_VIA_ENV" = 1 ]; then
  export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
  [ -f "$CONF_DIR/client-alice.properties" ] || (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=PLAIN\nsasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=%s/truststore.p12\nssl.truststore.password=%s\n' "$(cat "$SECRETS_DIR/ad-test-users.pass")" "$C" "$(cat "$PKI_DIR/store.pass")" > "$CONF_DIR/client-alice.properties")
  t=ldap-check-$(date +%s); r=$(kafka-topics --bootstrap-server "$(fqdn "${BROKERS%% *}"):9096" --command-config "$CONF_DIR/client-alice.properties" --create --topic "$t" --partitions 1 --replication-factor 3 2>&1 | grep -o 'Created topic\|TopicAuthorizationException' | head -1)
  kafka-topics --bootstrap-server "$(fqdn "${BROKERS%% *}"):9096" --command-config "$CONF_DIR/client-alice.properties" --delete --topic "$t" >/dev/null 2>&1
  [ "$r" = "Created topic" ] && ok "重啟後（群組快取為空）alice 經 LDAP listener 建 topic：$r → 查詞帳號用注入的密碼 bind 成功" || fail "alice 建 topic：${r:-失敗}（查詢帳號 bind 可能失敗）"
fi
h=${BROKERS%% *}
r=$(rsh "$h" "echo \"plaintext=\$(sudo grep -cE '^[^#].*(password|credentials|jaas.config) *= *[^$ ]' /etc/confluent/kafka/server.properties) master_key_on_disk=\$(sudo grep -rl CONFLUENT_SECURITY_MASTER_KEY= /etc/confluent /etc/systemd/system 2>/dev/null | wc -l)\"")
if [ "$SUMMON" = 1 ]; then [ "$r" = "plaintext=0 master_key_on_disk=0" ] && ok "$h: $r（主程序是 Summon，master key 只在 Java 子程序的環境）" || fail "$h: $r"; else [ "$r" = "plaintext=0 master_key_on_disk=1" ] && ok "$h: $r（service.env）" || fail "$h: $r"; fi
echo sp > "$CONF_DIR/secrets.mode"
log "之後：換 keystore 等我們管的密碼 → 重跑這一站（重算密文、派送、滾動重啟）；master key 輪替見手把手 16.6；$([ "$LDAP_PASSWORD_VIA_ENV" = 1 ] && echo 'CPM 換 AD 查詢密碼 → 只需滾動重啟 controller/broker' || echo 'AD 查詢密碼換了 → 重跑這一站')"
finish
