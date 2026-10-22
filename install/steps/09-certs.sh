#!/usr/bin/env bash
# 第 9 站：憑證 —— 私鑰與 CSR 在操作機產生（私鑰不離開行內）；銀行 CA 簽；回來逐張檢查後做成 keystore
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"

section "9.1 產生私鑰與 CSR（已有的不重產）"
install -d -m 0700 "$PKI_DIR" "$PKI_DIR"/{keys,requests,incoming,certs}
[ -s "$PKI_DIR/store.pass" ] || (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$PKI_DIR/store.pass")
san_list() {   # kafka | all → 逗號分隔的名稱清單
  local hosts; case $1 in kafka) hosts=$KAFKA_HOSTS;; all) hosts="$ALL_HOSTS $LB_HOST";; esac
  { for h in $hosts; do echo "$(fqdn "$h")"; echo "$h"; done; [ "$1" = all ] && { echo "$REST_VIP"; echo "$C3_VIP"; echo localhost; }; } | paste -sd,
}
grep -v '^#' "$D/conf/certs.txt" | while read -r name eku kind; do
  [ -n "$name" ] || continue
  case $kind in -) san=-;; *) san=$(san_list "$kind");; esac
  echo "$name $eku $san"
done > "$PKI_DIR/requests.txt"
while read -r name eku san; do
  if [ -f "$PKI_DIR/requests/$name.csr" ] && [ -f "$PKI_DIR/keys/$name.key" ]; then ok "$name: csr 已存在"; continue; fi
  (umask 077; openssl genrsa -out "$PKI_DIR/keys/$name.key" 2048 2>/dev/null)
  ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku")
  [ "$san" != "-" ] && ext+=(-addext "subjectAltName=$(tr ',' '\n' <<<"$san" | sed 's/^/DNS:/' | paste -sd,)")
  openssl req -new -key "$PKI_DIR/keys/$name.key" -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" "${ext[@]}" -out "$PKI_DIR/requests/$name.csr" && ok "$name: csr ok" || fail "$name: openssl req 失敗"
done < "$PKI_DIR/requests.txt"
[ "${FAILED:-0}" = 0 ] || die "CSR 產生失敗"

bank "9.2 CA 窗口：簽 $PKI_DIR/requests/*.csr（照 CSR 的 CN、SAN、EKU，一年），回覆「憑證 + 簽發 CA」PEM 串成一個檔，" \
     "    放到 $PKI_DIR/incoming/<名稱>.crt（$(awk '{print $1}' "$PKI_DIR/requests.txt" | paste -sd' ')）。"
missing=$(while read -r n _; do [ -s "$PKI_DIR/incoming/$n.crt" ] || echo "$n"; done < "$PKI_DIR/requests.txt" | paste -sd' ')
[ -z "$missing" ] || { log "incoming/ 還缺：$missing"; pending; }

section "9.3 拆開回覆（第一張是 leaf，其餘是中繼）"
cd "$PKI_DIR" || die "no $PKI_DIR"
for n in $(awk '{print $1}' requests.txt); do
  awk -v n="$n" 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("incoming/" n ".part" c)}' "incoming/$n.crt"
  mv "incoming/$n.part1" "incoming/$n.leaf.pem"; cat incoming/"$n".part[2-9] > "incoming/$n.issuers.pem" 2>/dev/null; rm -f incoming/"$n".part*
  log "$n: $(grep -c 'BEGIN CERT' "incoming/$n.issuers.pem") issuer(s)"
done

section "五項檢查（私鑰相符、CN、SAN、EKU、效期）＋ 整條鏈驗到銀行根憑證；任何一項不 ok 就退回銀行重簽"
ROOT=/etc/pki/ca-trust/source/anchors/bank-root.pem
while read -r name eku san; do
  leaf=incoming/$name.leaf.pem
  k1=$(openssl x509 -in "$leaf" -pubkey -noout | sha256sum | cut -c1-16); k2=$(openssl pkey -in "keys/$name.key" -pubout 2>/dev/null | sha256sum | cut -c1-16)
  cn=$(openssl x509 -in "$leaf" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')
  have_san=$(openssl x509 -in "$leaf" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,)
  want_san=$([ "$san" = "-" ] && echo "" || tr ',' '\n' <<<"$san" | sort | paste -sd,)
  have_eku=$(openssl x509 -in "$leaf" -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' ')
  want_eku=$(sed 's/serverAuth/TLSWebServerAuthentication/; s/clientAuth/TLSWebClientAuthentication/' <<<"$eku")
  days=$(( ($(date -d "$(openssl x509 -in "$leaf" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
  chain=$(openssl verify -CAfile $ROOT -untrusted "incoming/$name.issuers.pem" "$leaf" 2>&1 | grep -c ": OK")
  r=$(printf 'key=%s cn=%s san=%s eku=%s days=%s chain=%s' "$([ "$k1" = "$k2" ] && echo ok || echo MISMATCH)" "$([ "$cn" = "$name" ] && echo ok || echo "$cn")" "$([ "$have_san" = "$want_san" ] && echo ok || echo DIFF)" "$([ "$have_eku" = "$want_eku" ] && echo ok || echo "$have_eku")" "$days" "$([ "$chain" = 1 ] && echo ok || echo FAIL)")
  [ "$r" = "key=ok cn=ok san=ok eku=ok days=$days chain=ok" ] && [ "$days" -gt 30 ] && ok "$name $r" || fail "$name $r"
done < requests.txt
[ "${FAILED:-0}" = 0 ] || die "有憑證沒通過檢查：退回銀行重簽，不往下做"

section "正式檔案：certs/*.crt（leaf+中繼）、*.p12 keystore、truststore（只放銀行根憑證）、MDS token 金鑰對"
for n in $(awk '{print $1}' requests.txt); do
  cat "incoming/$n.leaf.pem" "incoming/$n.issuers.pem" > "certs/$n.crt"
  openssl pkcs12 -export -name "$n" -inkey "keys/$n.key" -in "certs/$n.crt" -out "certs/$n.p12" -passout file:store.pass && chmod 0600 "certs/$n.p12" || fail "$n: pkcs12"
done
cp $ROOT certs/bank-root.pem
rm -f certs/truststore.p12
keytool -importcert -noprompt -alias bank-root -file certs/bank-root.pem -keystore certs/truststore.p12 -storetype PKCS12 -storepass:file store.pass >/dev/null 2>&1 && ok "truststore.p12（只有 bank-root）" || fail "truststore"
if [ -f keys/mds-token.key ]; then ok "mds-token 金鑰對已存在（不重產：換了會讓已派送的 token 公鑰失效）"; else
  (umask 077; openssl genrsa -out keys/mds-token.key 2048 2>/dev/null) && openssl rsa -in keys/mds-token.key -pubout -out certs/mds-token-public.pem 2>/dev/null && ok "mds-token 金鑰對" || fail "mds-token"
fi
ok "certs/ 共 $(ls certs | wc -l) 個檔"
finish
