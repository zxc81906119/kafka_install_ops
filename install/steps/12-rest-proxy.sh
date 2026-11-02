#!/usr/bin/env bash
# 第 12 站：REST Proxy —— 只接受 client 憑證；principal 對應規則只列走 REST 的 app（不加 DEFAULT）
# where: ops02 （root）
#
# 做什麼：派送憑證 → kafka-rest.tpl 產生設定（principal 規則由 conf/apps.txt 的 cert 類 app 組成）
#         → drop-in → 啟動並測三種情況：legacy app 憑證 200、其他憑證 401、沒憑證 TLS 就拒絕（000）→ 經負載平衡 200。
# 需要什麼：第 10、11 站的 broker、MDS、RBAC；第 9 站的 svc-rest 與 cert 類 app 的憑證；銀行的負載平衡
# 產出什麼：~/conf/<主機>.kafka-rest.properties、~/conf/rest-restart.sh（之後重啟 REST 用，手把手 12.1）
# 能不能重跑：安全。第 15 站做過（Secret Protection）就照樣加密。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/render.sh"

if [ -z "$REST_APPS" ]; then
  die "conf/apps.txt 沒有走 REST 的 app（第二欄 cert）"
fi

section "派送憑證"
for host in $RESTS; do
  if ! copy_to_tmp "$host" "$CERTS_DIR/truststore.p12" "$CERTS_DIR/cp-server.p12" "$CERTS_DIR/svc-rest.p12" "$CERTS_DIR/mds-token-public.pem"; then
    fail "$host: scp"
    continue
  fi

  file_count=$(ssh_script "$host" <<'EOF'
sudo install -d -o root -g root -m 0755 /etc/confluent
sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka-rest

for file in truststore.p12 cp-server.p12 svc-rest.p12 mds-token-public.pem; do
  sudo install -o root -g confluent -m 0640 /tmp/$file /etc/confluent/ssl/
done

rm -f /tmp/*.p12 /tmp/mds-token-public.pem

sudo ls /etc/confluent/ssl | wc -l
EOF
)

  if [ "$file_count" = 4 ]; then
    ok "$host: 4 files"
  else
    fail "$host: $file_count files"
  fi
done

section "設定檔與 drop-in"

# 1. 範本要的變數；密碼從 0600 檔讀進變數，這一節結束就 unset
export STORE_PASSWORD HOST_FQDN REST_ID
export HEAP=$HEAP_REST
STORE_PASSWORD=$(cat "$PKI_DIR/store.pass")
export BROKER_TOKEN MDS_URLS REST_VIP REST_APPS

# 2. 第 15 站做過的話（Secret Protection），產生的明文設定先照第 15 站加密，共用的密文檔一起派送
secrets_mode=$(secrets_mode_in_use)
extra_files=()
if [ "$secrets_mode" = sp ]; then
  extra_files=("$SECRETS_DIR/security.properties")
fi
log "密碼放法：$secrets_mode"

# 3. 每台：產生 → 依放法處理密碼 → 產生 drop-in → 派送 → 確認
for host in $RESTS; do
  HOST_FQDN=$(fqdn "$host")
  REST_ID=$host
  props_file=$CONF_DIR/$host.kafka-rest.properties

  if ! render_template "$TEMPLATE_DIR/kafka-rest.tpl" "$props_file" HOST_FQDN REST_ID STORE_PASSWORD BROKER_TOKEN MDS_URLS REST_VIP REST_APPS; then
    fail "$host: render"
    continue
  fi

  if ! protect_rendered_props "$props_file"; then
    fail "$host: 密碼處理（$secrets_mode）"
    continue
  fi

  if ! render_template "$TEMPLATE_DIR/kafka-rest.dropin" "$CONF_DIR/$host.dropin" HEAP; then
    fail "$host: render dropin"
    continue
  fi

  if ! copy_to_tmp "$host" "$props_file" "$CONF_DIR/$host.dropin" "${extra_files[@]}"; then
    fail "$host: scp"
    continue
  fi

  # unresolved：還留著 ${…} 的行，config provider 的參照（securepass）不算
  result=$(ssh_script "$host" HOST="$host" <<'EOF'
props=/etc/confluent/kafka-rest/kafka-rest.properties

# 1. 設定檔放到定位
sudo install -o root -g confluent -m 0640 /tmp/$HOST.kafka-rest.properties $props

# 2. 第 15 站做過才有密文檔
if [ -f /tmp/security.properties ]; then
  sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets

  if sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties; then
    rm -f /tmp/security.properties
  fi
fi

# 3. drop-in：用我們的設定檔啟動
sudo install -d -m 0755 /etc/systemd/system/confluent-kafka-rest.service.d
sudo install -m 0644 /tmp/$HOST.dropin /etc/systemd/system/confluent-kafka-rest.service.d/10-override.conf
rm -f /tmp/$HOST.kafka-rest.properties /tmp/$HOST.dropin
sudo systemctl daemon-reload

# 4. 確認：沒換掉的 ${（要是 0）、ExecStart 指向我們的設定檔
exec_file=$(systemctl show confluent-kafka-rest -p ExecStart --value | grep -o '/etc/[^ ]*properties')
unresolved=$(sudo awk '/\$\{/ && !/\$\{securepass:/ {count++} END {print count + 0}' $props)
echo "unresolved=$unresolved exec=$exec_file"
EOF
)

  if [ "$result" = "unresolved=0 exec=/etc/confluent/kafka-rest/kafka-rest.properties" ]; then
    ok "$host: $result"
  else
    fail "$host: $result"
  fi
done
unset STORE_PASSWORD

if [ "$FAIL_COUNT" != 0 ]; then
  die "設定或 drop-in 有問題，不啟動"
fi

section "啟動（enable --now 不會重啟已在跑的服務，所以再 restart 一次）"
for host in $RESTS; do
  state=$(ssh_script "$host" <<'EOF'
sudo systemctl enable --now confluent-kafka-rest >/dev/null 2>&1
sudo systemctl restart confluent-kafka-rest
systemctl is-active confluent-kafka-rest
EOF
)

  if [ "$state" = active ]; then
    ok "$host: $state"
  else
    fail "$host: $state"
  fi
done

sleep 40

section "三種情況：legacy app 憑證 200、其他憑證（svc-ops）401、沒憑證 000（TLS 直接拒絕）"
for host in $RESTS; do
  url=https://$(fqdn "$host"):8082/v3/clusters

  # 1. legacy app 的憑證：每 10 秒試一次，最多 6 次（剛起來可能還沒好）
  for attempt in 1 2 3 4 5 6; do
    with_app_cert=$(rest_app_curl -s -o /dev/null -m 30 -w '%{http_code}' "$url")

    if [ "$with_app_cert" = 200 ]; then
      break
    fi

    sleep 10
  done

  # 2. 其他憑證、不帶憑證
  with_other_cert=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --cert "$CERTS_DIR/svc-ops.crt" --key "$KEYS_DIR/svc-ops.key" "$url")
  without_cert=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url")

  # 3. 判斷結果
  summary="legacy-app=$with_app_cert other-cert=$with_other_cert no-cert=$without_cert"

  if [ "$with_app_cert $with_other_cert $without_cert" = "200 401 000" ]; then
    ok "$host $summary"
  else
    fail "$host $summary（預期 200 401 000）"
  fi
done

via_lb=$(rest_app_curl -s -o /dev/null -m 30 -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters")

if [ "$via_lb" = 200 ]; then
  ok "經負載平衡（$REST_VIP）: $via_lb"
else
  fail "經負載平衡: $via_lb"
fi

section "12.1 之後重啟 REST Proxy 用的小腳本（先由 LB 團隊停用那一台，見手把手 12.1）"
if install -m 0700 "$TEMPLATE_DIR/rest-restart.sh" "$CONF_DIR/rest-restart.sh"; then
  ok "$CONF_DIR/rest-restart.sh"
fi

finish_step
