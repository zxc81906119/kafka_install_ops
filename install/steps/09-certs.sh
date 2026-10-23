#!/usr/bin/env bash
# 第 9 站：憑證 —— 私鑰與 CSR 在操作機產生（私鑰不離開行內）；銀行 CA 簽；回來逐張檢查後做成 keystore
# where: ops02 （cpadmin）
#
# 做什麼：依 conf/certs.txt 產生私鑰與 CSR → 等銀行 CA 簽回 incoming/ → 拆 leaf 與中繼 → 五項檢查 + 憑證鏈
#         → 做成 PKCS12 keystore、只放銀行根憑證的 truststore、MDS token 金鑰對。
# 產出：$CERTS_DIR（*.crt、*.p12、truststore.p12、bank-root.pem、mds-token-public.pem）、$KEYS_DIR、$PKI_DIR/store.pass
# 重跑：安全。已有的私鑰、CSR、store.pass、MDS token 金鑰都沿用（換掉會讓已派送的東西失效）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"

REQUESTS_FILE=$PKI_DIR/requests.txt   # 每行：名稱 EKU SAN清單（由 conf/certs.txt 展開）
INCOMING_DIR=$PKI_DIR/incoming        # 銀行回覆放這裡：<名稱>.crt（leaf + 簽發 CA）

# san_list kafka|all → 逗號分隔的 SAN 名稱清單（FQDN 與短名都放）
san_list() {
  local hosts host
  case $1 in kafka) hosts=$KAFKA_HOSTS;; all) hosts="$ALL_HOSTS $LB_HOST";; esac
  {
    for host in $hosts; do fqdn "$host"; echo "$host"; done
    if [ "$1" = all ]; then echo "$REST_VIP"; echo "$C3_VIP"; echo localhost; fi
  } | paste -sd,
}

section "9.1 產生私鑰與 CSR（已有的不重產）"
install -d -m 0700 "$PKI_DIR" "$KEYS_DIR" "$PKI_DIR/requests" "$INCOMING_DIR" "$CERTS_DIR"
[ -s "$PKI_DIR/store.pass" ] || (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$PKI_DIR/store.pass")
grep -v '^#' "$INSTALL_DIR/conf/certs.txt" | while read -r cert_name eku san_kind; do
  [ -n "$cert_name" ] || continue
  if [ "$san_kind" = - ]; then echo "$cert_name $eku -"; else echo "$cert_name $eku $(san_list "$san_kind")"; fi
done > "$REQUESTS_FILE"

while read -r cert_name eku san_names; do
  if [ -f "$PKI_DIR/requests/$cert_name.csr" ] && [ -f "$KEYS_DIR/$cert_name.key" ]; then ok "$cert_name: csr 已存在"; continue; fi
  (umask 077; openssl genrsa -out "$KEYS_DIR/$cert_name.key" 2048 2>/dev/null)
  extensions=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku")
  [ "$san_names" != - ] && extensions+=(-addext "subjectAltName=$(tr ',' '\n' <<<"$san_names" | sed 's/^/DNS:/' | paste -sd,)")
  if openssl req -new -key "$KEYS_DIR/$cert_name.key" -sha256 -subj "/CN=$cert_name/O=PoC Bank/C=TW" "${extensions[@]}" -out "$PKI_DIR/requests/$cert_name.csr"
  then ok "$cert_name: csr ok"; else fail "$cert_name: openssl req 失敗"; fi
done < "$REQUESTS_FILE"
[ "$FAIL_COUNT" = 0 ] || die "CSR 產生失敗"

ask_bank "9.2 CA 窗口：簽 $PKI_DIR/requests/*.csr（照 CSR 的 CN、SAN、EKU，一年），回覆「憑證 + 簽發 CA」串成一個 PEM 檔，" \
         "    放到 $INCOMING_DIR/<名稱>.crt（$(awk '{print $1}' "$REQUESTS_FILE" | paste -sd' ')）。"
missing=$(while read -r cert_name _; do [ -s "$INCOMING_DIR/$cert_name.crt" ] || echo "$cert_name"; done < "$REQUESTS_FILE" | paste -sd' ')
if [ -n "$missing" ]; then log "incoming/ 還缺：$missing"; wait_for_bank; fi

section "9.3 拆開回覆：第一張是 leaf，其餘是中繼（簽發 CA）"
for cert_name in $(awk '{print $1}' "$REQUESTS_FILE"); do
  awk -v out="$INCOMING_DIR/$cert_name.part" 'BEGIN{n=0} /BEGIN CERT/{n++} {print > (out n)}' "$INCOMING_DIR/$cert_name.crt"
  mv "$INCOMING_DIR/$cert_name.part1" "$INCOMING_DIR/$cert_name.leaf.pem"
  cat "$INCOMING_DIR/$cert_name".part[2-9] > "$INCOMING_DIR/$cert_name.issuers.pem" 2>/dev/null
  rm -f "$INCOMING_DIR/$cert_name".part*
  log "$cert_name: $(grep -c 'BEGIN CERT' "$INCOMING_DIR/$cert_name.issuers.pem") 張中繼"
done

section "五項檢查（私鑰相符、CN、SAN、EKU、效期 > 30 天）＋ 整條鏈驗到銀行根憑證；有一項不 ok 就退回銀行重簽"
while read -r cert_name eku san_names; do
  leaf=$INCOMING_DIR/$cert_name.leaf.pem
  cert_pubkey=$(openssl x509 -in "$leaf" -pubkey -noout | sha256sum | cut -c1-16)
  key_pubkey=$(openssl pkey -in "$KEYS_DIR/$cert_name.key" -pubout 2>/dev/null | sha256sum | cut -c1-16)
  common_name=$(openssl x509 -in "$leaf" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')
  actual_san=$(openssl x509 -in "$leaf" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,)
  expected_san=$([ "$san_names" = - ] || tr ',' '\n' <<<"$san_names" | sort | paste -sd,)
  actual_eku=$(openssl x509 -in "$leaf" -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' ')
  expected_eku=$(sed 's/serverAuth/TLSWebServerAuthentication/; s/clientAuth/TLSWebClientAuthentication/' <<<"$eku")
  days_left=$(( ($(date -d "$(openssl x509 -in "$leaf" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
  chain_ok=$(openssl verify -CAfile "$BANK_ROOT_CA" -untrusted "$INCOMING_DIR/$cert_name.issuers.pem" "$leaf" 2>&1 | grep -c ": OK")

  problems=""
  [ "$cert_pubkey" = "$key_pubkey" ] || problems+=" 私鑰不符"
  [ "$common_name" = "$cert_name" ]  || problems+=" CN=$common_name"
  [ "$actual_san" = "$expected_san" ] || problems+=" SAN 不同"
  [ "$actual_eku" = "$expected_eku" ] || problems+=" EKU=$actual_eku"
  [ "$days_left" -gt 30 ]            || problems+=" 只剩 $days_left 天"
  [ "$chain_ok" = 1 ]                || problems+=" 憑證鏈驗不過"
  if [ -z "$problems" ]; then ok "$cert_name key/cn/san/eku/chain ok，效期 $days_left 天"; else fail "$cert_name:$problems"; fi
done < "$REQUESTS_FILE"
[ "$FAIL_COUNT" = 0 ] || die "有憑證沒通過檢查：退回銀行重簽，不往下做"

section "正式檔案：*.crt（leaf+中繼）、*.p12 keystore、truststore（只放銀行根憑證）、MDS token 金鑰對"
for cert_name in $(awk '{print $1}' "$REQUESTS_FILE"); do
  cat "$INCOMING_DIR/$cert_name.leaf.pem" "$INCOMING_DIR/$cert_name.issuers.pem" > "$CERTS_DIR/$cert_name.crt"
  if openssl pkcs12 -export -name "$cert_name" -inkey "$KEYS_DIR/$cert_name.key" -in "$CERTS_DIR/$cert_name.crt" \
       -out "$CERTS_DIR/$cert_name.p12" -passout file:"$PKI_DIR/store.pass"; then chmod 0600 "$CERTS_DIR/$cert_name.p12"
  else fail "$cert_name: pkcs12"; fi
done
cp "$BANK_ROOT_CA" "$CERTS_DIR/bank-root.pem"
rm -f "$CERTS_DIR/truststore.p12"
if keytool -importcert -noprompt -alias bank-root -file "$CERTS_DIR/bank-root.pem" -keystore "$CERTS_DIR/truststore.p12" \
     -storetype PKCS12 -storepass:file "$PKI_DIR/store.pass" >/dev/null 2>&1; then ok "truststore.p12（只有 bank-root）"; else fail "truststore"; fi
# MDS 簽 token 用的金鑰對，不經銀行。已存在就不重產：換了會讓已派送到各台的公鑰失效
if [ -f "$KEYS_DIR/mds-token.key" ]; then ok "mds-token 金鑰對已存在，沿用"
else
  (umask 077; openssl genrsa -out "$KEYS_DIR/mds-token.key" 2048 2>/dev/null)
  if openssl rsa -in "$KEYS_DIR/mds-token.key" -pubout -out "$CERTS_DIR/mds-token-public.pem" 2>/dev/null; then ok "mds-token 金鑰對"; else fail "mds-token"; fi
fi
ok "certs/ 共 $(ls "$CERTS_DIR" | wc -l) 個檔"
finish_step
