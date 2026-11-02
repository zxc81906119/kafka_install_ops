#!/usr/bin/env bash
# 第 9 站：憑證 —— 私鑰與 CSR 在操作機產生（私鑰不離開行內）；銀行 CA 簽；回來逐張檢查後做成 keystore
# where: ops02 （root）
#
# 做什麼：依 conf/certs.txt 產生私鑰與 CSR → 等銀行 CA 簽回 incoming/ → 拆 leaf 與中繼 → 五項檢查 + 憑證鏈
#         → 做成 PKCS12 keystore、只放銀行根憑證的 truststore、MDS token 金鑰對。
# 需要：銀行根憑證已在操作機（第 5 站）、keytool（7.1 節）。第一次跑會停在「請銀行簽」（rc 2），回覆放進 incoming/ 再跑一次。
# 產出：$CERTS_DIR（*.crt、*.p12、truststore.p12、bank-root.pem、mds-token-public.pem）、$KEYS_DIR、$PKI_DIR/store.pass
# 重跑：安全。已有的私鑰、CSR、store.pass、MDS token 金鑰都沿用（換掉會讓已派送的東西失效）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"

REQUESTS_FILE=$PKI_DIR/requests.txt   # 每行：名稱 EKU SAN清單（由 conf/certs.txt 展開）
INCOMING_DIR=$PKI_DIR/incoming        # 銀行回覆放這裡：<名稱>.crt（leaf + 簽發 CA）

# san_list kafka|all：逗號分隔的 SAN 名稱清單（FQDN 與短名都放）
#   例：san_list kafka → kc01.poc.lab,kc01,kc02.poc.lab,kc02,…
san_list() {
  local hosts host

  case $1 in
    kafka)
      hosts=$KAFKA_HOSTS
      ;;
    all)
      hosts="$ALL_HOSTS $LB_HOST"
      ;;
  esac

  {
    for host in $hosts; do
      fqdn "$host"
      echo "$host"
    done

    if [ "$1" = all ]; then
      echo "$REST_VIP"
      echo "$C3_VIP"
      echo localhost
    fi
  } | paste -sd,
}

# dns_san_list <逗號分隔的主機名稱>：換成 subjectAltName 的寫法
#   例：dns_san_list kc01.poc.lab,kc01 → DNS:kc01.poc.lab,DNS:kc01
dns_san_list() {
  tr ',' '\n' <<<"$1" | sed 's/^/DNS:/' | paste -sd,
}

# write_requests：conf/certs.txt 展開成申請清單（印到 stdout），每行「名稱 EKU SAN清單」；沒有 SAN 寫 -
write_requests() {
  local cert_name eku san_kind

  grep -v '^#' "$INSTALL_DIR/conf/certs.txt" | while read -r cert_name eku san_kind; do
    if [ -z "$cert_name" ]; then
      continue
    fi

    if [ "$san_kind" = - ]; then
      echo "$cert_name $eku -"
    else
      echo "$cert_name $eku $(san_list "$san_kind")"
    fi
  done
}

# missing_replies：銀行還沒回覆的憑證名稱，空白分隔（都回了就印空的）
missing_replies() {
  local cert_name rest

  while read -r cert_name rest; do
    if [ ! -s "$INCOMING_DIR/$cert_name.crt" ]; then
      echo "$cert_name"
    fi
  done < "$REQUESTS_FILE" | paste -sd' '
}

# split_reply <名稱>：銀行回覆的 incoming/<名稱>.crt 拆成 leaf（第一張）和 issuers（其餘的中繼 CA）
#   例：incoming/svc-ops.crt → incoming/svc-ops.leaf.pem、incoming/svc-ops.issuers.pem
split_reply() {
  local cert_name=$1

  # 每遇到一行 BEGIN CERTIFICATE 就換寫下一個檔：.part1、.part2…
  awk -v out="$INCOMING_DIR/$cert_name.part" 'BEGIN{count=0} /BEGIN CERT/{count++} {print > (out count)}' "$INCOMING_DIR/$cert_name.crt"

  mv "$INCOMING_DIR/$cert_name.part1" "$INCOMING_DIR/$cert_name.leaf.pem"
  cat "$INCOMING_DIR/$cert_name".part[2-9] > "$INCOMING_DIR/$cert_name.issuers.pem" 2>/dev/null

  # :? = 變數是空的就停下來，不執行 rm
  rm -f "${INCOMING_DIR:?}/${cert_name:?}".part*
}

# cert_pubkey <憑證>、key_pubkey <私鑰>：公鑰的 sha256 前 16 碼；兩個一樣 = 憑證和私鑰是一對
cert_pubkey() {
  openssl x509 -in "$1" -pubkey -noout | sha256sum | cut -c1-16
}

key_pubkey() {
  openssl pkey -in "$1" -pubout 2>/dev/null | sha256sum | cut -c1-16
}

# cert_cn <憑證>：CN，例 kafka-internal
cert_cn() {
  openssl x509 -in "$1" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'
}

# cert_san <憑證>：SAN 裡的主機名稱，排好順序、逗號分隔，例 kb01,kb01.poc.lab,…（沒有 SAN 就是空的）
cert_san() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,
}

# sorted_list <逗號分隔的清單>：排好順序，用來和 cert_san 比；"-"（沒有 SAN）印空的
sorted_list() {
  if [ "$1" != - ]; then
    tr ',' '\n' <<<"$1" | sort | paste -sd,
  fi
}

# cert_eku <憑證>：用途，例 TLSWebServerAuthentication,TLSWebClientAuthentication
cert_eku() {
  openssl x509 -in "$1" -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' '
}

# eku_long_name <申請單寫的 EKU>：換成憑證上印的名稱
#   例：serverAuth,clientAuth → TLSWebServerAuthentication,TLSWebClientAuthentication
eku_long_name() {
  sed 's/serverAuth/TLSWebServerAuthentication/; s/clientAuth/TLSWebClientAuthentication/' <<<"$1"
}

# cert_days <憑證>：還有幾天到期
cert_days() {
  local end_date

  end_date=$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)
  echo $(( ($(date -d "$end_date" +%s) - $(date +%s)) / 86400 ))
}

section "9.1 產生私鑰與 CSR（已有的不重產）"
# 1. 目錄；keystore 的密碼（24 個英數字，檔案 0600；已有就沿用）
install -d -m 0700 "$PKI_DIR" "$KEYS_DIR" "$PKI_DIR/requests" "$INCOMING_DIR" "$CERTS_DIR"

if [ ! -s "$PKI_DIR/store.pass" ]; then
  install -m 0600 /dev/null "$PKI_DIR/store.pass"
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$PKI_DIR/store.pass"
fi

# 2. 申請清單
write_requests > "$REQUESTS_FILE"

# 3. 清單上每一張：私鑰（0600）與 CSR；有 SAN 的多加一行 subjectAltName
while read -r cert_name eku san_names; do
  if [ -f "$PKI_DIR/requests/$cert_name.csr" ] && [ -f "$KEYS_DIR/$cert_name.key" ]; then
    ok "$cert_name: csr 已存在"
    continue
  fi

  install -m 0600 /dev/null "$KEYS_DIR/$cert_name.key"
  openssl genrsa -out "$KEYS_DIR/$cert_name.key" 2048 2>/dev/null

  extensions=(
    -addext "basicConstraints=critical,CA:FALSE"
    -addext "keyUsage=critical,digitalSignature,keyEncipherment"
    -addext "extendedKeyUsage=$eku"
  )

  if [ "$san_names" != - ]; then
    extensions+=(-addext "subjectAltName=$(dns_san_list "$san_names")")
  fi

  if openssl req -new -key "$KEYS_DIR/$cert_name.key" -sha256 -subj "/CN=$cert_name/O=PoC Bank/C=TW" "${extensions[@]}" -out "$PKI_DIR/requests/$cert_name.csr"; then
    ok "$cert_name: csr ok"
  else
    fail "$cert_name: openssl req 失敗"
  fi
done < "$REQUESTS_FILE"

if [ "$FAIL_COUNT" != 0 ]; then
  die "CSR 產生失敗"
fi

# 清單上所有憑證的名稱（空白分隔），後面的 ask_bank 與迴圈都用它
certificate_names=$(awk '{print $1}' "$REQUESTS_FILE" | paste -sd' ')

ask_bank "9.2 CA 窗口：簽 $PKI_DIR/requests/*.csr（照 CSR 的 CN、SAN、EKU，一年），回覆「憑證 + 簽發 CA」串成一個 PEM 檔，" \
         "    放到 $INCOMING_DIR/<名稱>.crt（$certificate_names）。"

missing=$(missing_replies)

if [ -n "$missing" ]; then
  log "incoming/ 還缺：$missing"
  wait_for_bank
fi

section "9.3 拆開回覆：第一張是 leaf，其餘是中繼（簽發 CA）"
for cert_name in $certificate_names; do
  split_reply "$cert_name"
  issuer_count=$(awk '/BEGIN CERT/ {count++} END {print count + 0}' "$INCOMING_DIR/$cert_name.issuers.pem")
  log "$cert_name: $issuer_count 張中繼"
done

section "五項檢查（私鑰相符、CN、SAN、EKU、效期 > 30 天）＋ 整條鏈驗到銀行根憑證；有一項不 ok 就退回銀行重簽"
while read -r cert_name eku san_names; do
  leaf=$INCOMING_DIR/$cert_name.leaf.pem
  problems=""

  # 1. 私鑰相符
  if [ "$(cert_pubkey "$leaf")" != "$(key_pubkey "$KEYS_DIR/$cert_name.key")" ]; then
    problems+=" 私鑰不符"
  fi

  # 2. CN 就是申請的名稱
  common_name=$(cert_cn "$leaf")

  if [ "$common_name" != "$cert_name" ]; then
    problems+=" CN=$common_name"
  fi

  # 3. SAN 和申請的一樣
  if [ "$(cert_san "$leaf")" != "$(sorted_list "$san_names")" ]; then
    problems+=" SAN 不同"
  fi

  # 4. EKU 和申請的一樣
  actual_eku=$(cert_eku "$leaf")

  if [ "$actual_eku" != "$(eku_long_name "$eku")" ]; then
    problems+=" EKU=$actual_eku"
  fi

  # 5. 效期還夠
  days_left=$(cert_days "$leaf")

  if [ "$days_left" -le 30 ]; then
    problems+=" 只剩 $days_left 天"
  fi

  # 6. 整條鏈驗得到銀行根憑證
  if ! openssl verify -CAfile "$BANK_ROOT_CA" -untrusted "$INCOMING_DIR/$cert_name.issuers.pem" "$leaf" >/dev/null 2>&1; then
    problems+=" 憑證鏈驗不過"
  fi

  # 7. 一張一行結果
  if [ -z "$problems" ]; then
    ok "$cert_name key/cn/san/eku/chain ok，效期 $days_left 天"
  else
    fail "$cert_name:$problems"
  fi
done < "$REQUESTS_FILE"

if [ "$FAIL_COUNT" != 0 ]; then
  die "有憑證沒通過檢查：退回銀行重簽，不往下做"
fi

section "正式檔案：*.crt（leaf+中繼）、*.p12 keystore、truststore（只放銀行根憑證）、MDS token 金鑰對"
# 1. 每一張：正式的 PEM（leaf＋中繼）與 PKCS12 keystore（0600）
for cert_name in $certificate_names; do
  cat "$INCOMING_DIR/$cert_name.leaf.pem" "$INCOMING_DIR/$cert_name.issuers.pem" > "$CERTS_DIR/$cert_name.crt"

  if openssl pkcs12 -export -name "$cert_name" -inkey "$KEYS_DIR/$cert_name.key" -in "$CERTS_DIR/$cert_name.crt" -out "$CERTS_DIR/$cert_name.p12" -passout file:"$PKI_DIR/store.pass"; then
    chmod 0600 "$CERTS_DIR/$cert_name.p12"
  else
    fail "$cert_name: pkcs12"
  fi
done

# 2. truststore：只放銀行根憑證
cp "$BANK_ROOT_CA" "$CERTS_DIR/bank-root.pem"
rm -f "$CERTS_DIR/truststore.p12"

if keytool -importcert -noprompt -alias bank-root -file "$CERTS_DIR/bank-root.pem" -keystore "$CERTS_DIR/truststore.p12" -storetype PKCS12 -storepass:file "$PKI_DIR/store.pass" >/dev/null 2>&1; then
  ok "truststore.p12（只有 bank-root）"
else
  fail "truststore"
fi

# 3. MDS 簽 token 用的金鑰對，不經銀行。已存在就不重產：換了會讓已派送到各台的公鑰失效
if [ -f "$KEYS_DIR/mds-token.key" ]; then
  ok "mds-token 金鑰對已存在，沿用"
else
  install -m 0600 /dev/null "$KEYS_DIR/mds-token.key"
  openssl genrsa -out "$KEYS_DIR/mds-token.key" 2048 2>/dev/null

  if openssl rsa -in "$KEYS_DIR/mds-token.key" -pubout -out "$CERTS_DIR/mds-token-public.pem" 2>/dev/null; then
    ok "mds-token 金鑰對"
  else
    fail "mds-token"
  fi
fi

ok "certs/ 共 $(ls "$CERTS_DIR" | wc -l) 個檔"
finish_step
