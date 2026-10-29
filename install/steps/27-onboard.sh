#!/usr/bin/env bash
# 第 27 站：新應用上線 —— 從申請單到上線：topic、身分（SCRAM A／B 或憑證）、權限、配額、交付、驗證；下線反過來（手把手第 27 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；每個新系統跑一次 onboard，退役跑 retire；drill 是 lab／驗收用）
#
# 用法：
#   bash steps/27-onboard.sh onboard <系統> scram|cert <topic:partitions:保留天數>…   27.2–27.4：建 topic、帳號（scram：<app>-a／-b；cert：CSR 停在「請銀行簽」，回覆放 ~/pki/incoming/ 再跑一次）、binding、配額、交接檔
#   bash steps/27-onboard.sh verify  <系統> scram|cert <topic>                        27.5：用該身分寫一筆、讀一筆（cert：經 REST Proxy／LB POST）
#   bash steps/27-onboard.sh retire  <系統> scram|cert <topic>…                       27.6：解除 binding、SCRAM 覆寫隨機密碼（帳號留著）、憑證檔與 requests.txt 的那行拿掉、刪 topic（lab；正式環境等保留期）
#   lab 整條走一遍（run-customer 第 28 段）：onboard inventory scram → verify；onboard shipping cert（rc 2 停在請銀行簽）→ bank-sim.sh sign-app app-shipping → 再 onboard → verify；兩個 retire
#
# 帳號名 app-<系統>；topic 前綴 <系統>.；consumer group 前綴 <系統>-；配額用 conf/apps.txt 的預設（QUOTA_SCRAM／QUOTA_CERT）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-}
ADMIN=(--bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF")
MDS_URL=https://$(fqdn "${BROKERS%% *}"):8090
HANDOVER_DIR=${HANDOVER_DIR:-$HOME/handover}
QUOTA_SCRAM=${QUOTA_SCRAM:-producer_byte_rate=5242880,consumer_byte_rate=10485760,request_percentage=50}
QUOTA_CERT=${QUOTA_CERT:-producer_byte_rate=1048576,consumer_byte_rate=2097152,request_percentage=25}

cluster_id() { curl -s --cacert "$BANK_ROOT_CA" "$MDS_URL/v1/metadata/id" | grep -o '"id":"[^"]*"' | cut -d'"' -f4; }
cli() {   # confluent CLI 以 svc-ops 憑證登入後執行（用自己的 HOME，不動操作機原本的登入）
  local h=$CONF_DIR/.cli-onboard; install -d -m 0700 "$h"
  HOME=$h confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only --client-cert-path "$CERTS_DIR/svc-ops.crt" --client-key-path "$KEYS_DIR/svc-ops.key" >/dev/null 2>&1 || return 1
  HOME=$h confluent "$@"
}
bind()   { retry 3 5 cli iam rbac role-binding create --principal "User:$1" --role "$2" --resource "$3" --prefix --kafka-cluster "$CID" >/dev/null 2>&1; }
nbind()  { cli iam rbac role-binding list --principal "User:$1" --kafka-cluster "$CID" -o json 2>/dev/null | grep -c '"role"'; }
scram_conf() {   # scram_conf <帳號> <密碼檔> → 暫存 client 設定檔路徑
  local c; c=$(mktemp); (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="%s" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=%s/truststore.p12\nssl.truststore.password=%s\n' "$1" "$(cat "$2")" "$CERTS_DIR" "$(cat "$PKI_DIR/store.pass")" > "$c"); echo "$c"
}

topics() {   # topics <系統> <topic:partitions:天數>…
  local sys=$1; shift; local spec t p d
  section "27.2 建 topic（$sys）"
  for spec in "$@"; do IFS=: read -r t p d <<<"$spec"
    case $t in "$sys".*) ;; *) die "topic $t 要用 $sys. 前綴";; esac
    kafka-topics "${ADMIN[@]}" --create --if-not-exists --topic "$t" --partitions "${p:-3}" --replication-factor 3 --config "retention.ms=$(( ${d:-7} * 86400000 ))" >/dev/null 2>&1 && ok "$t：partitions ${p:-3}、RF 3、retention ${d:-7} 天" || fail "$t 建立失敗"
  done
}

identity_scram() {   # identity_scram <系統>：A／B 帳號、配額、binding
  local sys=$1 a r
  section "27.3 SCRAM A／B 帳號、配額、binding（app-$sys-a／-b）"
  for a in "app-$sys-a" "app-$sys-b"; do
    [ -s "$SECRETS_DIR/$a.pass" ] || (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS_DIR/$a.pass")
    kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$a" --add-config "SCRAM-SHA-512=[iterations=8192,password=$(cat "$SECRETS_DIR/$a.pass")]" >/dev/null 2>&1 || { fail "$a SCRAM"; continue; }
    kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$a" --add-config "$QUOTA_SCRAM" >/dev/null 2>&1 || fail "$a 配額"
    for r in DeveloperWrite DeveloperRead; do bind "$a" "$r" "Topic:$sys." || fail "$a $r"; done
    bind "$a" DeveloperRead "Group:$sys-" || fail "$a Group"
    ok "$a：SCRAM、配額、binding $(nbind "$a") 條"
  done
}

identity_cert() {   # identity_cert <系統>：CSR → 等銀行簽 → 檢查、.crt、.p12（自己的密碼）→ binding、配額
  local sys=$1 n="app-$sys" leaf k1 k2 cn chain r
  section "27.3 憑證身分（$n）"
  cd "$PKI_DIR" || die "沒有 $PKI_DIR"
  # incoming 的憑證要配得上這台的私鑰才算數：沒有私鑰就是別處留下的舊檔，重新產生 CSR
  if [ ! -s "incoming/$n.crt" ] || [ ! -s "keys/$n.key" ]; then
    rm -f incoming/$n.*
    grep -q "^$n " requests.txt || printf '%-18s clientAuth             -\n' "$n" >> requests.txt
    [ -s "keys/$n.key" ] || (umask 077; openssl genrsa -out "keys/$n.key" 2048 2>/dev/null)
    openssl req -new -key "keys/$n.key" -sha256 -subj "/CN=$n/O=PoC Bank/C=TW" -addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=clientAuth" -out "requests/$n.csr" || die "CSR 失敗"
    ask_bank "CA 窗口：簽 ~/pki/requests/$n.csr（clientAuth），憑證鏈放回 ~/pki/incoming/$n.crt（lab：bank-sim.sh sign-app $n）"
    wait_for_bank "incoming/$n.crt"
  fi
  awk -v n="$n" 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("incoming/" n ".part" c)}' "incoming/$n.crt"; mv "incoming/$n.part1" "incoming/$n.leaf.pem"; cat incoming/$n.part[2-9] > "incoming/$n.issuers.pem" 2>/dev/null; rm -f incoming/$n.part*
  leaf=incoming/$n.leaf.pem
  k1=$(openssl x509 -in "$leaf" -pubkey -noout | sha256sum | cut -c1-16); k2=$(openssl pkey -in "keys/$n.key" -pubout 2>/dev/null | sha256sum | cut -c1-16)
  cn=$(openssl x509 -in "$leaf" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')
  chain=$(openssl verify -CAfile "$BANK_ROOT_CA" -untrusted "incoming/$n.issuers.pem" "$leaf" 2>&1 | grep -c ': OK')
  [ "$k1" = "$k2" ] && [ "$cn" = "$n" ] && [ "$chain" = 1 ] && ok "憑證檢查：key ok、CN ok、chain ok" || die "憑證檢查失敗（key $([ "$k1" = "$k2" ] && echo ok || echo MISMATCH)、CN $cn、chain $chain）"
  cat "incoming/$n.leaf.pem" "incoming/$n.issuers.pem" > "certs/$n.crt"
  [ -s "$SECRETS_DIR/$n-p12.pass" ] || (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS_DIR/$n-p12.pass")
  openssl pkcs12 -export -name "$n" -inkey "keys/$n.key" -in "certs/$n.crt" -out "certs/$n.p12" -passout "file:$SECRETS_DIR/$n-p12.pass" && chmod 0600 "certs/$n.p12" && ok "certs/$n.crt、certs/$n.p12（密碼 $SECRETS_DIR/$n-p12.pass）" || fail "p12"
  for r in DeveloperWrite DeveloperRead; do bind "$n" "$r" "Topic:$sys." || fail "$n $r"; done
  kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$n" --add-config "$QUOTA_CERT" >/dev/null 2>&1 || fail "$n 配額"
  ok "$n：binding $(nbind "$n") 條、配額"
  rest_allowlist "$n" add
}

# rest_allowlist <CN> add|remove：REST Proxy 只放行 apps.txt 列出的 CN（第 12 站的 principal mapping 規則）；改 apps.txt 再重跑第 12 站（重新產生規則、兩台 REST 重啟）
rest_allowlist() {
  local n=$1 op=$2 apps=$INSTALL_DIR/conf/apps.txt first_rest=${RESTS%% *}
  section "27.3 REST Proxy 的 CN 白名單：$op $n（conf/apps.txt → 第 12 站重跑）"
  if [ "$op" = add ]; then grep -q "^$n " "$apps" || printf '%-19s cert   %s\n' "$n" "$(sed 's/producer_byte_rate=//; s/,consumer_byte_rate=/,/; s/,request_percentage=/,/' <<<"$QUOTA_CERT")" >> "$apps"
  else sed -i "/^$n /d" "$apps"; fi
  if bash "$INSTALL_DIR/install.sh" --only 12 >/dev/null 2>&1; then ok "第 12 站重跑：規則 $(grep -o 'CN=([^)]*)' "$CONF_DIR/$first_rest.kafka-rest.properties" 2>/dev/null | head -1)，兩台 REST 已重啟"
  else fail "第 12 站重跑失敗（看 ~/install-logs 最新的 12-rest-proxy）"; fi
}

handover() {   # handover <系統> scram|cert
  local sys=$1 kind=$2 f a
  section "27.4 交接檔（$HANDOVER_DIR，0600；交完刪）"
  install -d -m 0700 "$HANDOVER_DIR"
  if [ "$kind" = scram ]; then
    f=$HANDOVER_DIR/app-$sys-$(date +%F).txt
    (umask 077; { echo "app-$sys（$(date +%F)）：bootstrap $BROKER_CLIENT；SASL_SSL／SCRAM-SHA-512；平常用 -a"; for a in "app-$sys-a" "app-$sys-b"; do echo "$a $(cat "$SECRETS_DIR/$a.pass")"; done; } > "$f")
  else
    f=$HANDOVER_DIR/app-$sys; install -d -m 0700 "$f"
    cp "$CERTS_DIR/app-$sys.p12" "$CERTS_DIR/bank-root.pem" "$f/" && (umask 077; echo "p12 密碼另送：$(cat "$SECRETS_DIR/app-$sys-p12.pass")；網址 https://$REST_VIP:8082" > "$f/README-password.txt")
    chmod 0600 "$f"/*
  fi
  ok "交接檔：$(find "$f" -type f -printf '%m %f ' | sed 's/ $//')"
}

onboard() {
  local sys=${1:-} kind=${2:-}; shift 2 || die "用法：$0 onboard <系統> scram|cert <topic:partitions:天數>…"
  [ -n "$sys" ] && [ "$kind" = scram -o "$kind" = cert ] && [ $# -ge 1 ] || die "用法：$0 onboard <系統> scram|cert <topic:partitions:天數>…"
  CID=$(cluster_id); [ -n "$CID" ] || die "拿不到 cluster id（MDS？）"
  topics "$sys" "$@"
  if [ "$kind" = scram ]; then identity_scram "$sys"; else identity_cert "$sys"; fi
  handover "$sys" "$kind"
}

verify() {   # verify <系統> scram|cert <topic>
  local sys=${1:-} kind=${2:-} t=${3:-} c m got code cid
  [ -n "$sys" ] && [ -n "$t" ] || die "用法：$0 verify <系統> scram|cert <topic>"
  section "27.5 驗證（$sys，$kind，$t）"
  m="onboard-$(date +%s)"
  if [ "$kind" = scram ]; then
    c=$(scram_conf "app-$sys-a" "$SECRETS_DIR/app-$sys-a.pass")
    echo "$m" | kafka-console-producer --bootstrap-server "$BROKER_CLIENT" --producer.config "$c" --topic "$t" >/dev/null 2>&1 &&
      got=$(kafka-console-consumer --bootstrap-server "$BROKER_CLIENT" --consumer.config "$c" --topic "$t" --group "$sys-check" --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null | grep -c "^$m$")
    rm -f "$c"
    [ "${got:-0}" = 1 ] && ok "app-$sys-a 寫一筆、讀回 1 筆" || fail "app-$sys-a 寫讀失敗（got=${got:-0}）"
  else
    cid=$(cluster_id)
    # REST v3 produce 一律 HTTP 200：成功與否看回應 JSON 的 error_code（200 成功、40301 沒權限）
    code=$(curl -s --cacert "$BANK_ROOT_CA" --cert "$CERTS_DIR/app-$sys.crt" --key "$KEYS_DIR/app-$sys.key" -X POST -H 'Content-Type: application/json' -d "{\"value\":{\"type\":\"JSON\",\"data\":\"$m\"}}" "https://$REST_VIP:8082/v3/clusters/$cid/topics/$t/records" | grep -o '"error_code":[0-9]*' | cut -d: -f2)
    [ "$code" = 200 ] && ok "app-$sys 經 REST Proxy／LB 寫入 $t：error_code 200" || fail "app-$sys 經 REST 寫入：error_code $code"
  fi
}

retire() {   # retire <系統> scram|cert <topic>…
  local sys=${1:-} kind=${2:-}; shift 2 || die "用法：$0 retire <系統> scram|cert <topic>…"
  [ -n "$sys" ] || die "用法：$0 retire <系統> scram|cert <topic>…"
  local p t b role rtype rname pat n=0 principals
  CID=$(cluster_id)
  section "27.6 下線（$sys）：解除 binding、配額；SCRAM 覆寫；憑證檔拿掉；刪 topic"
  if [ "$kind" = scram ]; then principals="app-$sys-a app-$sys-b"; else principals="app-$sys"; fi
  for p in $principals; do
    while IFS='|' read -r role rtype rname pat; do [ -n "$role" ] || continue
      retry 3 5 cli iam rbac role-binding delete --principal "User:$p" --role "$role" --resource "$rtype:$rname" $([ "$pat" = PREFIXED ] && echo --prefix) --kafka-cluster "$CID" --force >/dev/null 2>&1 && n=$((n+1))
    done < <(cli iam rbac role-binding list --principal "User:$p" --kafka-cluster "$CID" -o json 2>/dev/null | python3 -c 'import json,sys; [print("|".join([b["role"], b.get("resource_type",""), b.get("name",""), b.get("pattern_type","")])) for b in json.load(sys.stdin)]')
    kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$p" --delete-config producer_byte_rate,consumer_byte_rate,request_percentage >/dev/null 2>&1
    if [ "$kind" = scram ]; then
      kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$p" --add-config "SCRAM-SHA-512=[iterations=8192,password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)]" >/dev/null 2>&1; rm -f "$SECRETS_DIR/$p.pass"
    fi
  done
  ok "解除 binding $n 條、配額拿掉$([ "$kind" = scram ] && echo "、SCRAM 密碼覆寫成隨機值（帳號留著）")"
  if [ "$kind" = cert ]; then
    (cd "$PKI_DIR" && sed -i "/^app-$sys /d" requests.txt && rm -f "keys/app-$sys.key" "requests/app-$sys.csr" incoming/app-$sys.* "certs/app-$sys.crt" "certs/app-$sys.p12") ; rm -f "$SECRETS_DIR/app-$sys-p12.pass"
    ok "憑證：requests.txt 那行、私鑰、CSR、憑證、p12 已拿掉（到期不續）"
    rest_allowlist "app-$sys" remove
  fi
  rm -rf "$HANDOVER_DIR/app-$sys-"*.txt "$HANDOVER_DIR/app-$sys"
  for t in "$@"; do kafka-topics "${ADMIN[@]}" --delete --topic "$t" >/dev/null 2>&1 && ok "刪 topic $t" || fail "刪 topic $t"; done
  for p in $principals; do [ "$(nbind "$p")" = 0 ] || fail "$p 還有 binding"; done
}

case $ACTION in
  onboard) onboard "${2:-}" "${3:-}" "${@:4}"; [ "$FAIL_COUNT" = 0 ];;
  verify)  verify "${2:-}" "${3:-}" "${4:-}"; [ "$FAIL_COUNT" = 0 ];;
  retire)  retire "${2:-}" "${3:-}" "${@:4}"; [ "$FAIL_COUNT" = 0 ];;
  *) sed -n '2,12p' "$0"; exit 1;;
esac
