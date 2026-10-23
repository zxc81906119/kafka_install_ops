#!/usr/bin/env bash
# 第 21 站：憑證輪替 —— leaf 換發（同一個 CA 或新 CA 簽），以及換 CA 時同步信任清單
# where: ops02 （cpadmin）
# run: on-demand（不在安裝順序裡；install.sh 照順序跑時略過，要換時直接執行這支）
#
# 用法：
#   bash steps/21-cert-rotate.sh status       每張憑證的序號與剩幾天、各端點實際出示的是哪一張
#   bash steps/21-cert-rotate.sh leaf         換發 conf/certs.txt 的全部 leaf：
#                                             第一次：新私鑰＋CSR 放 ~/pki/next/，印「請銀行簽」，停下（rc 2）
#                                             銀行放回 ~/pki/next/incoming/ 後再跑一次：檢查 → 做 keystore → 派送 → 滾動重啟 → 換成正本
#   bash steps/21-cert-rotate.sh trust-sync   銀行換好各主機 OS 的 bank-root.pem 之後，把我方的信任清單同步成一樣、滾動重啟：
#                                             換 CA 階段一（bank-root.pem 是新舊兩張根）、階段三（只剩新根）都是這個動作
# 換 CA 的三階段 = trust-sync（加新根）→ leaf（銀行用新 CA 簽）→ trust-sync（退舊根）；手把手 21.3。
#
# 不變的東西：檔名、路徑、keystore 密碼。所以 properties 一個字都不用改，Secret Protection 的密文也不用重算。
# 舊的正本留在 ~/pki/old-<日期時間>/。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"
source "$INSTALL_DIR/lib/vault.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-status}
REQUESTS_FILE=$PKI_DIR/requests.txt     # 第 9 站產生的：名稱 EKU SAN（換發時照用，CN／SAN／EKU 不變）
NEXT_DIR=$PKI_DIR/next                  # 這一輪的新私鑰、CSR、銀行回覆、成品
STORE_PASSWORD_FILE=$PKI_DIR/store.pass

# 要檢查出示憑證的端點：主機:埠 會出示哪一張
ENDPOINTS=""
for host in $CONTROLLERS; do ENDPOINTS+=" $(fqdn "$host"):9093=kafka-internal"; done
for host in $BROKERS; do ENDPOINTS+=" $(fqdn "$host"):9092=kafka-internal $(fqdn "$host"):9095=cp-server $(fqdn "$host"):8090=cp-server"; done
for host in $RESTS; do ENDPOINTS+=" $(fqdn "$host"):8082=cp-server"; done
ENDPOINTS+=" $C3_FQDN:9021=cp-server $C3_FQDN:9090=cp-server"

# 每台主機要換的憑證檔（來源檔名 → 目的地都在 /etc/confluent/ssl/）
files_for_host() {
  case $1 in
    kc*)   echo "certs/kafka-internal.p12";;
    kb*)   echo "certs/kafka-internal.p12 certs/cp-server.p12";;
    rest*) echo "certs/cp-server.p12 certs/svc-rest.p12";;
    c3*)   echo "certs/cp-server.p12 certs/cp-server.crt keys/cp-server.key certs/svc-c3.p12";;
  esac
}

serial_of_file()     { openssl x509 -in "$1" -noout -serial | cut -d= -f2; }
serial_of_endpoint() { openssl s_client -connect "$1" -servername "${1%:*}" </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; }

# show_status：每張憑證與每個端點
show_status() {
  local cert_name days endpoint expected served
  section "每張憑證（序號末 8 碼、剩幾天、簽發者）"
  for cert_name in $(awk '{print $1}' "$REQUESTS_FILE"); do
    days=$(( ($(date -d "$(openssl x509 -in "$CERTS_DIR/$cert_name.crt" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
    log "$(printf '%-19s %s  %3s 天  %s' "$cert_name" "$(serial_of_file "$CERTS_DIR/$cert_name.crt" | tail -c 9)" "$days" \
      "$(openssl x509 -in "$CERTS_DIR/$cert_name.crt" -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')")"
    [ "$days" -lt 30 ] && warn "$cert_name 剩 $days 天，該換了（bash $0 leaf）"
  done
  section "各端點實際出示的憑證（和正本一致才算換好）"
  for endpoint in $ENDPOINTS; do
    expected=$(serial_of_file "$CERTS_DIR/${endpoint#*=}.crt"); served=$(serial_of_endpoint "${endpoint%=*}")
    if [ "$served" = "$expected" ]; then ok "${endpoint%=*} 出示 ${endpoint#*=}（${served: -8}）"
    else fail "${endpoint%=*} 出示 ${served: -8}，正本是 ${expected: -8}"; fi
  done
}

# ---- leaf 第一段：新私鑰與 CSR ----
create_requests() {
  local cert_name eku san_names extensions
  section "21.2.1 新私鑰與 CSR（照 requests.txt：CN、SAN、EKU 不變）"
  install -d -m 0700 "$NEXT_DIR" "$NEXT_DIR/keys" "$NEXT_DIR/requests" "$NEXT_DIR/incoming" "$NEXT_DIR/certs"
  while read -r cert_name eku san_names; do
    (umask 077; openssl genrsa -out "$NEXT_DIR/keys/$cert_name.key" 2048 2>/dev/null)
    extensions=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku")
    [ "$san_names" != - ] && extensions+=(-addext "subjectAltName=$(tr ',' '\n' <<<"$san_names" | sed 's/^/DNS:/' | paste -sd,)")
    if openssl req -new -key "$NEXT_DIR/keys/$cert_name.key" -sha256 -subj "/CN=$cert_name/O=PoC Bank/C=TW" "${extensions[@]}" -out "$NEXT_DIR/requests/$cert_name.csr"
    then ok "$cert_name: csr"; else fail "$cert_name: openssl req"; fi
  done < "$REQUESTS_FILE"
}

# ---- leaf 第二段：銀行回覆檢查、做 keystore ----
check_and_build() {
  local cert_name eku san_names leaf problems cert_pubkey key_pubkey common_name actual_san expected_san days_left chain_ok issuer
  section "21.2.3 拆開回覆、五項檢查＋憑證鏈（對 OS 的 bank-root.pem 驗；換 CA 階段二時它是新舊兩張根）"
  for cert_name in $(awk '{print $1}' "$REQUESTS_FILE"); do
    awk -v out="$NEXT_DIR/incoming/$cert_name.part" 'BEGIN{n=0} /BEGIN CERT/{n++} {print > (out n)}' "$NEXT_DIR/incoming/$cert_name.crt"
    mv "$NEXT_DIR/incoming/$cert_name.part1" "$NEXT_DIR/incoming/$cert_name.leaf.pem"
    cat "$NEXT_DIR/incoming/$cert_name".part[2-9] > "$NEXT_DIR/incoming/$cert_name.issuers.pem" 2>/dev/null
    rm -f "$NEXT_DIR/incoming/$cert_name".part*
  done
  while read -r cert_name eku san_names; do
    leaf=$NEXT_DIR/incoming/$cert_name.leaf.pem
    cert_pubkey=$(openssl x509 -in "$leaf" -pubkey -noout | sha256sum | cut -c1-16)
    key_pubkey=$(openssl pkey -in "$NEXT_DIR/keys/$cert_name.key" -pubout 2>/dev/null | sha256sum | cut -c1-16)
    common_name=$(openssl x509 -in "$leaf" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')
    actual_san=$(openssl x509 -in "$leaf" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,)
    expected_san=$([ "$san_names" = - ] || tr ',' '\n' <<<"$san_names" | sort | paste -sd,)
    days_left=$(( ($(date -d "$(openssl x509 -in "$leaf" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
    chain_ok=$(openssl verify -CAfile "$BANK_ROOT_CA" -untrusted "$NEXT_DIR/incoming/$cert_name.issuers.pem" "$leaf" 2>&1 | grep -c ": OK")
    issuer=$(openssl x509 -in "$leaf" -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')
    problems=""
    [ "$cert_pubkey" = "$key_pubkey" ]  || problems+=" 私鑰不符"
    [ "$common_name" = "$cert_name" ]   || problems+=" CN=$common_name"
    [ "$actual_san" = "$expected_san" ] || problems+=" SAN 不同"
    [ "$days_left" -gt 30 ]             || problems+=" 只剩 $days_left 天"
    [ "$chain_ok" = 1 ]                 || problems+=" 憑證鏈驗不過"
    if [ -z "$problems" ]; then ok "$cert_name：檢查都過，效期 $days_left 天，簽發者 $issuer"; else fail "$cert_name:$problems"; fi
  done < "$REQUESTS_FILE"
  [ "$FAIL_COUNT" = 0 ] || die "有憑證沒通過檢查：退回銀行重簽（$NEXT_DIR 留著，修好後再跑一次）"
  section "做 keystore（同一個 keystore 密碼）"
  for cert_name in $(awk '{print $1}' "$REQUESTS_FILE"); do
    cat "$NEXT_DIR/incoming/$cert_name.leaf.pem" "$NEXT_DIR/incoming/$cert_name.issuers.pem" > "$NEXT_DIR/certs/$cert_name.crt"
    if openssl pkcs12 -export -name "$cert_name" -inkey "$NEXT_DIR/keys/$cert_name.key" -in "$NEXT_DIR/certs/$cert_name.crt" \
         -out "$NEXT_DIR/certs/$cert_name.p12" -passout file:"$STORE_PASSWORD_FILE"; then chmod 0600 "$NEXT_DIR/certs/$cert_name.p12"
    else fail "$cert_name: pkcs12"; fi
  done
  [ "$FAIL_COUNT" = 0 ] || die "做 keystore 失敗"
  ok "$NEXT_DIR/certs：$(ls "$NEXT_DIR/certs" | wc -l) 個檔"
}

# ---- leaf 第三段：派送、滾動重啟、確認出示新序號 ----
deploy_and_restart() {
  local host file_list endpoint expected served attempt
  section "21.2.4 派送（全部主機先放好；服務只在啟動時讀檔）→ 滾動重啟 → 確認每個端點出示新的"
  for host in $CLUSTER_HOSTS; do
    file_list=$(files_for_host "$host")
    # shellcheck disable=SC2086
    (cd "$NEXT_DIR" && copy_to_tmp "$host" $file_list) || { fail "$host: scp"; continue; }
    if ssh_script "$host" FILES="$(for f in $file_list; do basename "$f"; done | paste -sd' ')" <<'EOF'
for file in $FILES; do sudo install -o root -g confluent -m 0640 /tmp/$file /etc/confluent/ssl/$file && rm -f /tmp/$file; done
EOF
    then ok "$host: $(wc -w <<<"$file_list") 個檔"; else fail "$host: install"; fi
  done
  [ "$FAIL_COUNT" = 0 ] || die "派送失敗，不重啟（主機上的檔可能已經部分換了；修好後再跑一次）"
  rolling_restart controllers brokers rests || die "滾動重啟有主機沒健康"
  # C3 這台有三個服務吃憑證：Prometheus、Alertmanager 用 PEM，C3 用 p12
  ssh_run "$C3_HOST" 'for unit in prometheus alertmanager; do sudo systemctl restart $unit; done'
  rolling_restart c3 || die "C3 沒有健康"
  for endpoint in $ENDPOINTS; do
    expected=$(serial_of_file "$NEXT_DIR/certs/${endpoint#*=}.crt")
    for attempt in $(seq 1 30); do served=$(serial_of_endpoint "${endpoint%=*}"); [ "$served" = "$expected" ] && break; sleep 2; done   # controller 起來後 9093 要幾秒才開
    if [ "$served" = "$expected" ]; then ok "${endpoint%=*} 出示新的 ${endpoint#*=}"; else fail "${endpoint%=*} 出示 ${served: -8}，新的是 ${expected: -8}"; fi
  done
  [ "$FAIL_COUNT" = 0 ] || die "有端點還沒出示新憑證"
}

# ---- leaf 第四段：換成正本、交出去的那幾張 ----
promote() {
  local old_dir cert_name
  old_dir=$PKI_DIR/old-$(date +%Y%m%d-%H%M%S)
  section "21.2.5 換成正本（舊的移到 $old_dir）"
  install -d -m 0700 "$old_dir/keys" "$old_dir/certs" "$old_dir/requests" "$old_dir/incoming"
  for cert_name in $(awk '{print $1}' "$REQUESTS_FILE"); do
    mv "$KEYS_DIR/$cert_name.key" "$old_dir/keys/"; mv "$CERTS_DIR/$cert_name.crt" "$CERTS_DIR/$cert_name.p12" "$old_dir/certs/"
    install -m 0600 "$NEXT_DIR/keys/$cert_name.key" "$KEYS_DIR/"
    install -m 0644 "$NEXT_DIR/certs/$cert_name.crt" "$CERTS_DIR/"
    install -m 0600 "$NEXT_DIR/certs/$cert_name.p12" "$CERTS_DIR/"
    # CSR 與銀行回覆也換成這一輪的：第 9 站重跑時檢查的是「現在在用的」私鑰配回覆，不會拿上一輪的回覆來比而判成私鑰不符
    mv "$PKI_DIR/requests/$cert_name.csr" "$old_dir/requests/" 2>/dev/null
    mv "$PKI_DIR/incoming/$cert_name".* "$old_dir/incoming/" 2>/dev/null
    install -m 0644 "$NEXT_DIR/requests/$cert_name.csr" "$PKI_DIR/requests/"
    install -m 0644 "$NEXT_DIR/incoming/$cert_name.crt" "$PKI_DIR/incoming/"
  done
  rm -rf "$NEXT_DIR"
  ok "正本已換新"
  # 操作機自己用的兩張：管理 client（svc-ops）、查 quorum（kafka-internal）
  local topic_count leader_line
  topic_count=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --list 2>/dev/null | wc -l)
  if [ "$topic_count" -gt 0 ]; then ok "svc-ops 管理 client 可用（$topic_count 個 topic）"; else fail "svc-ops 管理 client 失敗"; fi
  leader_line=$(kafka-metadata-quorum --bootstrap-controller "$FIRST_CONTROLLER:9093" --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null | grep -o 'LeaderId: *[0-9]*')
  if [ -n "$leader_line" ]; then ok "kafka-internal 查 quorum 可用（$leader_line）"; else fail "kafka-internal 查 quorum 失敗"; fi
  # 緊急身分：保管庫裡那份要更新（沒有 CCP／Conjur 的銀行：交給 Secrets 團隊換 PVWA 裡的 object）
  if [ "$OPMENU" = 1 ] && [ "$OPMENU_SECRETS" = conjur ]; then
    if vault_login_as_ops && cat "$KEYS_DIR/opmenu-breakglass.key" "$CERTS_DIR/opmenu-breakglass.crt" | vault_set breakglass/pem; then ok "保管庫的 breakglass/pem 已更新"
    else fail "保管庫的 breakglass/pem 更新失敗"; fi
    vault_logout
  elif [ "$OPMENU" = 1 ]; then
    ask_bank "Secrets 團隊：PVWA 裡的緊急憑證換成新的（$KEYS_DIR/opmenu-breakglass.key + $CERTS_DIR/opmenu-breakglass.crt）。"
  fi
  local rest_app_code
  rest_app_code=$(rest_app_curl -s -o /dev/null -m 30 -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters")
  if [ "$rest_app_code" = 200 ]; then ok "新的 $FIRST_REST_APP 憑證經負載平衡 200"; else fail "新的 $FIRST_REST_APP 憑證：$rest_app_code"; fi
  ask_bank "應用程式團隊：新的 $(tr '|' ' ' <<<"$REST_APPS") 憑證在 $CERTS_DIR／$KEYS_DIR，請在你們的時段換上（舊的到期前都有效；換 CA 階段三之前一定要換）。"
}

# ---- trust-sync：我方信任清單跟著 OS 的 bank-root.pem ----
trust_sync() {
  local root_count root_file index alias_name host
  section "信任清單同步：以 $BANK_ROOT_CA 為準（銀行 OS 團隊先換好；換 CA 階段一是新舊兩張、階段三只剩新的）"
  root_count=$(grep -c 'BEGIN CERTIFICATE' "$BANK_ROOT_CA")
  [ "$root_count" -ge 1 ] || die "$BANK_ROOT_CA 裡沒有憑證"
  local work_dir; work_dir=$(mktemp -d)
  # 把 bundle 拆成一張一張，以 CN 當 alias 重建 truststore（舊的留 .old）
  awk -v out="$work_dir/root-" 'BEGIN{n=0} /BEGIN CERT/{n++} n>0 {print > (out n ".pem")}' "$BANK_ROOT_CA"
  cp -p "$CERTS_DIR/truststore.p12" "$CERTS_DIR/truststore.p12.old"
  rm -f "$work_dir/truststore.p12"
  for root_file in "$work_dir"/root-*.pem; do
    alias_name=$(openssl x509 -in "$root_file" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/' | tr 'A-Z ' 'a-z-')
    keytool -importcert -noprompt -alias "$alias_name" -file "$root_file" -keystore "$work_dir/truststore.p12" -storetype PKCS12 \
      -storepass:file "$STORE_PASSWORD_FILE" >/dev/null 2>&1 || die "匯入 $alias_name 失敗"
  done
  install -m 0600 "$work_dir/truststore.p12" "$CERTS_DIR/truststore.p12"
  cp "$BANK_ROOT_CA" "$CERTS_DIR/bank-root.pem"
  rm -rf "$work_dir"
  ok "truststore：$(keytool -list -keystore "$CERTS_DIR/truststore.p12" -storetype PKCS12 -storepass:file "$STORE_PASSWORD_FILE" 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | paste -sd' ')"
  for host in $CLUSTER_HOSTS; do
    copy_to_tmp "$host" "$CERTS_DIR/truststore.p12" || { fail "$host: scp"; continue; }
    ssh_run "$host" 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/ && rm -f /tmp/truststore.p12' || fail "$host: install"
  done
  # C3 的 Prometheus／Alertmanager 驗 client 用的 ca.pem
  copy_to_tmp "$C3_HOST" "$CERTS_DIR/bank-root.pem" && ssh_run "$C3_HOST" 'sudo install -o root -g confluent -m 0640 /tmp/bank-root.pem /etc/confluent/ssl/ca.pem && rm -f /tmp/bank-root.pem' \
    || fail "$C3_HOST: ca.pem"
  # OP menu 在操作機上的兩份
  if [ -d /etc/opmenu/ssl ]; then
    sudo install -m 0644 "$CERTS_DIR/truststore.p12" /etc/opmenu/ssl/truststore.p12 && sudo install -m 0644 "$CERTS_DIR/bank-root.pem" /etc/opmenu/ssl/ca.pem && ok "OP menu 的 truststore、ca.pem 已同步"
  fi
  # 走 Conjur provider 的：provider 連 Conjur 用 JDK 的 cacerts，也要跟著換
  if [ "$(cat "$CONF_DIR/secrets.mode" 2>/dev/null)" = conjur ]; then
    for host in $ALL_HOSTS; do
      copy_to_tmp "$host" "$CERTS_DIR/bank-root.pem" && ssh_script "$host" <<'EOF' || fail "$host: cacerts"
cacerts_tool() { sudo /opt/java/current/bin/keytool "$@" -cacerts -storepass changeit >/dev/null 2>&1; }
for alias_name in $(/opt/java/current/bin/keytool -list -cacerts -storepass changeit 2>/dev/null | grep -o '^bank-root[^,]*'); do cacerts_tool -delete -alias "$alias_name"; done
csplit -s -z -f /tmp/bank-root- /tmp/bank-root.pem '/BEGIN CERT/' '{*}'
index=0; for root_file in /tmp/bank-root-*; do cacerts_tool -importcert -noprompt -alias "bank-root-$index" -file "$root_file"; index=$((index + 1)); done
rm -f /tmp/bank-root.pem /tmp/bank-root-*
EOF
    done
    ok "JDK cacerts 已同步（Conjur provider 用）"
  fi
  [ "$FAIL_COUNT" = 0 ] || die "派送失敗，不重啟"
  rolling_restart controllers brokers rests || die "滾動重啟有主機沒健康"
  ssh_run "$C3_HOST" 'for unit in prometheus alertmanager; do sudo systemctl restart $unit; done'
  rolling_restart c3 || die "C3 沒有健康"
  local alice_login
  alice_login=$(curl -s --cacert "$BANK_ROOT_CA" -u "alice:$(cat "$SECRETS_DIR/ad-test-users.pass")" -o /dev/null -w '%{http_code}' "$MDS_URL/security/1.0/authenticate")
  if [ "$alice_login" = 200 ]; then ok "alice 登入 MDS（MDS 經 LDAPS 連 AD）：200"; else fail "alice 登入 MDS：$alice_login（AD 的憑證是不是還是舊 CA 簽的？）"; fi
  ask_bank "監控團隊：行內 Prometheus 抓 JMX exporter 用的 ca.pem 換成 $CERTS_DIR/bank-root.pem 這份（$root_count 張根）。" \
           "應用程式團隊：client 端的 truststore 也要有同樣的根（走 REST、SCRAM 直連的都要）。"
}

case $ACTION in
  status) show_status;;
  leaf)
    if [ -d "$NEXT_DIR/requests" ] && [ "$(ls "$NEXT_DIR/requests" | wc -l)" -gt 0 ]; then
      missing=$(for cert_name in $(awk '{print $1}' "$REQUESTS_FILE"); do [ -s "$NEXT_DIR/incoming/$cert_name.crt" ] || echo "$cert_name"; done | paste -sd' ')
      if [ -n "$missing" ]; then
        ask_bank "CA 窗口：簽 $NEXT_DIR/requests/*.csr，回覆（憑證＋簽發 CA，PEM）放到 $NEXT_DIR/incoming/<名稱>.crt。還缺：$missing"
        wait_for_bank
      fi
      check_and_build
      deploy_and_restart
      promote
    else
      create_requests
      ask_bank "21.2.2 CA 窗口：簽 $NEXT_DIR/requests/*.csr（照 CSR 的 CN、SAN、EKU，一年；換 CA 階段二時用新 CA 簽），" \
               "    回覆（憑證＋簽發 CA，PEM）放到 $NEXT_DIR/incoming/<名稱>.crt。放好後再跑一次：bash $0 leaf"
      wait_for_bank
    fi;;
  trust-sync) trust_sync;;
  *) die "用法：bash $0 status|leaf|trust-sync";;
esac
finish_step
