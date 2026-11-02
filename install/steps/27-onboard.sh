#!/usr/bin/env bash
# 第 27 站：新應用上線 —— 從申請單到上線：topic、身分（SCRAM A／B 或憑證）、權限、配額、交付、驗證；下線反過來（手把手第 27 章）
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；每個新系統跑一次 onboard，退役跑 retire）
#
# 做什麼：照申請單替一個系統建 topic、帳號、binding、配額、交接檔（onboard），用該身分驗證（verify），退役時反過來（retire）。
# 需要什麼：第 11 站的 client-admin.properties、第 9 站的 ~/pki、第 12 站的 REST Proxy。
# 產出什麼：密碼檔 ~/secrets/app-<系統>*.pass（0600）、憑證 ~/pki/certs/app-<系統>.*、交接檔 ~/handover/（0600，交完刪）。
# 能不能重跑：可以。topic 用 --if-not-exists、密碼檔已有就沿用、binding 重建不會多一條；憑證收到回覆前結束碼是 2，銀行簽完再跑一次。
#
# 用法：
#   bash steps/27-onboard.sh onboard <系統> scram|cert <topic:partitions:保留天數>…   27.2–27.4：建 topic、帳號（scram：<app>-a／-b；cert：CSR 停在「請銀行簽」，回覆放 ~/pki/incoming/ 再跑一次）、binding、配額、交接檔
#   bash steps/27-onboard.sh verify  <系統> scram|cert <topic>                        27.5：用該身分寫一筆、讀一筆（cert：經 REST Proxy／LB POST）
#   bash steps/27-onboard.sh retire  <系統> scram|cert <topic>…                       27.6：解除 binding、SCRAM 覆寫隨機密碼（帳號留著）、憑證檔與 requests.txt 的那行拿掉、刪 topic（lab；正式環境等保留期）
#   lab 整條走一遍（run-customer 第 29 段）：onboard inventory scram → verify；onboard shipping cert（rc 2 停在請銀行簽）→ bank-sim.sh sign-app app-shipping → 再 onboard → verify；兩個 retire
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

# cluster_id：叢集 id，例 MkU3OEVBNTcwNTJENDM2Qk
cluster_id() {
  curl -s --cacert "$BANK_ROOT_CA" "$MDS_URL/v1/metadata/id" | grep -o '"id":"[^"]*"' | cut -d'"' -f4
}

# cli <confluent 的參數…>：confluent CLI 以 svc-ops 憑證登入後執行（用自己的 HOME，不動操作機原本的登入）
cli() {
  local cli_home=$CONF_DIR/.cli-onboard

  install -d -m 0700 "$cli_home"

  if ! HOME=$cli_home confluent login --url "$MDS_URL" --certificate-authority-path "$CERTS_DIR/bank-root.pem" --certificate-only --client-cert-path "$CERTS_DIR/svc-ops.crt" --client-key-path "$KEYS_DIR/svc-ops.key" >/dev/null 2>&1; then
    return 1
  fi

  HOME=$cli_home confluent "$@"
}

# add_binding <帳號> <角色> <資源>：建一條前綴 binding；只有 50003 才重送（mds_write）
add_binding() {
  mds_write cli iam rbac role-binding create --principal "User:$1" --role "$2" --resource "$3" --prefix --kafka-cluster "$CID" >/dev/null 2>&1
}

# binding_count <帳號>：這個帳號有幾條 binding，例 3
binding_count() {
  cli iam rbac role-binding list --principal "User:$1" --kafka-cluster "$CID" -o json 2>/dev/null | awk '/"role"/ {c++} END {print c + 0}'
}

# new_password_file <檔案>：產生 24 碼隨機密碼存進這個檔（0600）
new_password_file() {
  install -m 0600 /dev/null "$1"
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$1"
}

# scram_conf <帳號> <密碼檔>：做一份暫存的 client 設定（mktemp 是 0600，用完由呼叫的一方刪），印出它的路徑
scram_conf() {
  local conf_file

  conf_file=$(mktemp)
  cat > "$conf_file" <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$1" password="$(cat "$2")";
ssl.truststore.type=PKCS12
ssl.truststore.location=$CERTS_DIR/truststore.p12
ssl.truststore.password=$(cat "$PKI_DIR/store.pass")
EOF
  echo "$conf_file"
}

# topics <系統> <topic:partitions:天數>…：RF 固定 3；min.insync.replicas 是 broker 預設（第 10 站），不在這裡改
topics() {
  local sys=$1 spec topic partitions days
  shift

  section "27.2 建 topic（$sys）"

  for spec in "$@"; do
    # inventory.stock:3:3 → topic=inventory.stock partitions=3 days=3
    IFS=: read -r topic partitions days <<<"$spec"

    case $topic in
      "$sys".*)
        ;;
      *)
        die "topic $topic 要用 $sys. 前綴"
        ;;
    esac

    if kafka-topics "${ADMIN[@]}" --create --if-not-exists --topic "$topic" --partitions "${partitions:-3}" --replication-factor 3 --config "retention.ms=$(( ${days:-7} * 86400000 ))" >/dev/null 2>&1; then
      ok "$topic：partitions ${partitions:-3}、RF 3、retention ${days:-7} 天"
    else
      fail "$topic 建立失敗"
    fi
  done
}

# identity_scram <系統>：A／B 兩個帳號，權限一模一樣（kafka-configs 出錯會印出密碼，所以輸出全丟）
identity_scram() {
  local sys=$1 account role password_file

  section "27.3 SCRAM A／B 帳號、配額、binding（app-$sys-a／-b）"

  for account in "app-$sys-a" "app-$sys-b"; do
    # 1. 密碼檔（0600）；已經有就沿用
    password_file=$SECRETS_DIR/$account.pass

    if [ ! -s "$password_file" ]; then
      new_password_file "$password_file"
    fi

    # 2. SCRAM 帳號與配額
    if ! kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$account" --add-config "SCRAM-SHA-512=[iterations=8192,password=$(cat "$password_file")]" >/dev/null 2>&1; then
      fail "$account SCRAM"
      continue
    fi

    if ! kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$account" --add-config "$QUOTA_SCRAM" >/dev/null 2>&1; then
      fail "$account 配額"
    fi

    # 3. 三條 binding：<系統>. 前綴的寫與讀、<系統>- 前綴的 consumer group
    for role in DeveloperWrite DeveloperRead; do
      if ! add_binding "$account" "$role" "Topic:$sys."; then
        fail "$account $role"
      fi
    done

    if ! add_binding "$account" DeveloperRead "Group:$sys-"; then
      fail "$account Group"
    fi

    ok "$account：SCRAM、配額、binding $(binding_count "$account") 條"
  done
}

# split_reply <名稱>：銀行回覆的 incoming/<名稱>.crt 拆成 leaf（第一張）和 issuers（其餘的中繼 CA）（同 9.3）
#   incoming/app-x.crt → incoming/app-x.leaf.pem、incoming/app-x.issuers.pem
split_reply() {
  local name=$1

  awk -v n="$name" 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("incoming/" n ".part" c)}' "incoming/$name.crt"
  mv "incoming/$name.part1" "incoming/$name.leaf.pem"
  cat "incoming/$name".part[2-9] > "incoming/$name.issuers.pem" 2>/dev/null
  rm -f "incoming/$name".part*
}

# cert_pubkey <憑證>、key_pubkey <私鑰>：公鑰的 sha256 前 16 碼；兩個一樣 = 憑證和私鑰是一對
cert_pubkey() {
  openssl x509 -in "$1" -pubkey -noout | sha256sum | cut -c1-16
}

key_pubkey() {
  openssl pkey -in "$1" -pubout 2>/dev/null | sha256sum | cut -c1-16
}

# cert_cn <憑證>：CN，例 app-shipping
cert_cn() {
  openssl x509 -in "$1" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'
}

# identity_cert <系統>：CSR → 等銀行簽 → 檢查、.crt、.p12（自己的密碼，不用平台的 store.pass）→ binding、配額
identity_cert() {
  local sys=$1
  local name="app-$sys"
  local leaf key_result cn chain role

  section "27.3 憑證身分（$name）"

  if ! cd "$PKI_DIR"; then
    die "沒有 $PKI_DIR"
  fi

  # 1. 還沒有回覆就產生 CSR、請銀行簽，到這裡結束（rc 2）
  # incoming 的憑證要配得上這台的私鑰才算數：沒有私鑰就是別處留下的舊檔，重新產生 CSR
  if [ ! -s "incoming/$name.crt" ] || [ ! -s "keys/$name.key" ]; then
    rm -f "incoming/$name".*

    if ! grep -q "^$name " requests.txt; then
      printf '%-18s clientAuth             -\n' "$name" >> requests.txt
    fi

    if [ ! -s "keys/$name.key" ]; then
      install -m 0600 /dev/null "keys/$name.key"
      openssl genrsa -out "keys/$name.key" 2048 2>/dev/null
    fi

    if ! openssl req -new -key "keys/$name.key" -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=clientAuth" \
      -out "requests/$name.csr"; then
      die "CSR 失敗"
    fi

    ask_bank "CA 窗口：簽 ~/pki/requests/$name.csr（clientAuth），憑證鏈放回 ~/pki/incoming/$name.crt（lab：bank-sim.sh sign-app $name）"
    wait_for_bank "incoming/$name.crt"
  fi

  # 2. 拆開回覆、檢查：私鑰相符、CN、鏈驗得到銀行根憑證
  split_reply "$name"
  leaf=incoming/$name.leaf.pem

  if [ "$(cert_pubkey "$leaf")" = "$(key_pubkey "keys/$name.key")" ]; then
    key_result=ok
  else
    key_result=MISMATCH
  fi

  cn=$(cert_cn "$leaf")
  chain=$(openssl verify -CAfile "$BANK_ROOT_CA" -untrusted "incoming/$name.issuers.pem" "$leaf" 2>&1 | awk '/: OK/ {c++} END {print c + 0}')

  if [ "$key_result" != ok ] || [ "$cn" != "$name" ] || [ "$chain" != 1 ]; then
    die "憑證檢查失敗（key $key_result、CN $cn、chain $chain）"
  fi

  ok "憑證檢查：key ok、CN ok、chain ok"

  # 3. 正式的 PEM（leaf＋中繼）；交給應用程式的 p12 用它自己的密碼（0600）
  cat "incoming/$name.leaf.pem" "incoming/$name.issuers.pem" > "certs/$name.crt"

  if [ ! -s "$SECRETS_DIR/$name-p12.pass" ]; then
    new_password_file "$SECRETS_DIR/$name-p12.pass"
  fi

  if openssl pkcs12 -export -name "$name" -inkey "keys/$name.key" -in "certs/$name.crt" -out "certs/$name.p12" -passout "file:$SECRETS_DIR/$name-p12.pass"; then
    chmod 0600 "certs/$name.p12"
    ok "certs/$name.crt、certs/$name.p12（密碼 $SECRETS_DIR/$name-p12.pass）"
  else
    fail "p12"
  fi

  # 4. 兩條 binding：<系統>. 前綴的寫與讀；配額設在這個 principal 上
  for role in DeveloperWrite DeveloperRead; do
    if ! add_binding "$name" "$role" "Topic:$sys."; then
      fail "$name $role"
    fi
  done

  if ! kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$name" --add-config "$QUOTA_CERT" >/dev/null 2>&1; then
    fail "$name 配額"
  fi

  ok "$name：binding $(binding_count "$name") 條、配額"

  # 5. REST Proxy 的 CN 白名單
  rest_allowlist "$name" add
}

# quota_numbers <配額設定>：配額只留數字，apps.txt 的寫法
#   例：producer_byte_rate=1048576,consumer_byte_rate=2097152,request_percentage=25 → 1048576,2097152,25
quota_numbers() {
  sed 's/producer_byte_rate=//; s/,consumer_byte_rate=/,/; s/,request_percentage=/,/' <<<"$1"
}

# rest_allowlist <CN> add|remove：REST Proxy 只放行 apps.txt 列出的 CN（第 12 站的 principal mapping 規則）；
# 改 apps.txt 再重跑第 12 站（重新產生規則、兩台 REST 重啟）
rest_allowlist() {
  local name=$1 operation=$2 apps_file=$INSTALL_DIR/conf/apps.txt first_rest=${RESTS%% *} rule

  section "27.3 REST Proxy 的 CN 白名單：$operation $name（conf/apps.txt → 第 12 站重跑）"

  if [ "$operation" = add ]; then
    if ! grep -q "^$name " "$apps_file"; then
      printf '%-19s cert   %s\n' "$name" "$(quota_numbers "$QUOTA_CERT")" >> "$apps_file"
    fi
  else
    sed -i "/^$name /d" "$apps_file"
  fi

  if bash "$INSTALL_DIR/install.sh" --only 12 >/dev/null 2>&1; then
    rule=$(grep -o 'CN=([^)]*)' "$CONF_DIR/$first_rest.kafka-rest.properties" 2>/dev/null | head -1)
    ok "第 12 站重跑：規則 $rule，兩台 REST 已重啟"
  else
    fail "第 12 站重跑失敗（看 ~/install-logs 最新的 12-rest-proxy）"
  fi
}

# handover <系統> scram|cert：交接檔（內容不印到畫面）
handover() {
  local sys=$1 kind=$2 target account file_list

  section "27.4 交接檔（$HANDOVER_DIR，0600；交完刪）"

  install -d -m 0700 "$HANDOVER_DIR"

  if [ "$kind" = scram ]; then
    # 直連的系統：bootstrap、協定、兩個帳號的密碼
    target=$HANDOVER_DIR/app-$sys-$(date +%F).txt
    install -m 0600 /dev/null "$target"
    echo "app-$sys（$(date +%F)）：bootstrap $BROKER_CLIENT；SASL_SSL／SCRAM-SHA-512；平常用 -a" >> "$target"

    for account in "app-$sys-a" "app-$sys-b"; do
      echo "$account $(cat "$SECRETS_DIR/$account.pass")" >> "$target"
    done
  else
    # 走 REST 的系統：p12、銀行根憑證；p12 的密碼放另一個檔（分開送）
    target=$HANDOVER_DIR/app-$sys
    install -d -m 0700 "$target"

    if cp "$CERTS_DIR/app-$sys.p12" "$CERTS_DIR/bank-root.pem" "$target/"; then
      install -m 0600 /dev/null "$target/README-password.txt"
      echo "p12 密碼另送：$(cat "$SECRETS_DIR/app-$sys-p12.pass")；網址 https://$REST_VIP:8082" > "$target/README-password.txt"
    fi

    chmod 0600 "$target"/*
  fi

  file_list=$(find "$target" -type f -printf '%m %f ' | sed 's/ $//')
  ok "交接檔：$file_list"
}

onboard() {
  local sys=${1:-} kind=${2:-}

  if [ $# -lt 2 ]; then
    die "用法：$0 onboard <系統> scram|cert <topic:partitions:天數>…"
  fi

  shift 2

  # 1. 檢查參數
  if [ -z "$sys" ] || [ $# -lt 1 ]; then
    die "用法：$0 onboard <系統> scram|cert <topic:partitions:天數>…"
  fi

  case $kind in
    scram|cert)
      ;;
    *)
      die "用法：$0 onboard <系統> scram|cert <topic:partitions:天數>…"
      ;;
  esac

  # 2. binding 要用的 cluster id
  CID=$(cluster_id)

  if [ -z "$CID" ]; then
    die "拿不到 cluster id（MDS？）"
  fi

  # 3. topic、身分、交接檔
  topics "$sys" "$@"

  if [ "$kind" = scram ]; then
    identity_scram "$sys"
  else
    identity_cert "$sys"
  fi

  handover "$sys" "$kind"
}

# verify_scram <系統> <topic> <訊息>：寫一筆、用 <系統>- 前綴的 group 讀回
verify_scram() {
  local sys=$1 topic=$2 message=$3 conf_file got=0

  conf_file=$(scram_conf "app-$sys-a" "$SECRETS_DIR/app-$sys-a.pass")

  if echo "$message" | kafka-console-producer --bootstrap-server "$BROKER_CLIENT" --producer.config "$conf_file" --topic "$topic" >/dev/null 2>&1; then
    got=$(kafka-console-consumer --bootstrap-server "$BROKER_CLIENT" --consumer.config "$conf_file" --topic "$topic" --group "$sys-check" --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null | awk -v m="$message" '$0 == m {c++} END {print c + 0}')
  fi

  rm -f "$conf_file"

  if [ "$got" = 1 ]; then
    ok "app-$sys-a 寫一筆、讀回 1 筆"
  else
    fail "app-$sys-a 寫讀失敗（got=$got）"
  fi
}

# verify_cert <系統> <topic> <訊息>：經 LB POST 一筆
# REST v3 produce 一律 HTTP 200：成功與否看回應 JSON 的 error_code（200 成功、40301 沒權限）
verify_cert() {
  local sys=$1 topic=$2 message=$3 cluster body url code

  cluster=$(cluster_id)
  body="{\"value\":{\"type\":\"JSON\",\"data\":\"$message\"}}"
  url=https://$REST_VIP:8082/v3/clusters/$cluster/topics/$topic/records
  code=$(curl -s --cacert "$BANK_ROOT_CA" --cert "$CERTS_DIR/app-$sys.crt" --key "$KEYS_DIR/app-$sys.key" -X POST -H 'Content-Type: application/json' -d "$body" "$url" | grep -o '"error_code":[0-9]*' | cut -d: -f2)

  if [ "$code" = 200 ]; then
    ok "app-$sys 經 REST Proxy／LB 寫入 $topic：error_code 200"
  else
    fail "app-$sys 經 REST 寫入：error_code $code"
  fi
}

# verify <系統> scram|cert <topic>
verify() {
  local sys=${1:-} kind=${2:-} topic=${3:-} message

  if [ -z "$sys" ] || [ -z "$topic" ]; then
    die "用法：$0 verify <系統> scram|cert <topic>"
  fi

  section "27.5 驗證（$sys，$kind，$topic）"

  message="onboard-$(date +%s)"

  if [ "$kind" = scram ]; then
    verify_scram "$sys" "$topic" "$message"
  else
    verify_cert "$sys" "$topic" "$message"
  fi
}

# bindings_from_json：role-binding list -o json 的輸出（一個欄位一行）→ 一行一條「角色|資源類型|名稱|比對方式」
#   例：
#     "role": "DeveloperRead",
#     "resource_type": "Topic",
#     "name": "inventory.",
#     "pattern_type": "PREFIXED"
#   → DeveloperRead|Topic|inventory.|PREFIXED
bindings_from_json() {
  awk -F'"' '
    /"role":/          {role = $4}
    /"resource_type":/ {type = $4}
    /"name":/          {name = $4}
    /"pattern_type":/  {pattern = $4}
    /}/ {
      if (role != "") {
        print role "|" type "|" name "|" pattern
      }
      role = ""
      type = ""
      name = ""
      pattern = ""
    }
  '
}

# remove_bindings <帳號>：解除這個帳號的每一條 binding，印出成功解除幾條（只有 50003 才重送：mds_write）
remove_bindings() {
  local account=$1 list_file role resource_type resource_name pattern removed=0

  list_file=$(mktemp)
  cli iam rbac role-binding list --principal "User:$account" --kafka-cluster "$CID" -o json 2>/dev/null | bindings_from_json > "$list_file"

  while IFS='|' read -r role resource_type resource_name pattern; do
    if [ -z "$role" ]; then
      continue
    fi

    if [ "$pattern" = PREFIXED ]; then
      if mds_write cli iam rbac role-binding delete --principal "User:$account" --role "$role" --resource "$resource_type:$resource_name" --prefix --kafka-cluster "$CID" --force >/dev/null 2>&1; then
        removed=$((removed + 1))
      fi
    else
      if mds_write cli iam rbac role-binding delete --principal "User:$account" --role "$role" --resource "$resource_type:$resource_name" --kafka-cluster "$CID" --force >/dev/null 2>&1; then
        removed=$((removed + 1))
      fi
    fi
  done < "$list_file"

  rm -f "$list_file"
  echo "$removed"
}

# retire <系統> scram|cert <topic>…
retire() {
  local sys=${1:-} kind=${2:-}

  if [ $# -lt 2 ]; then
    die "用法：$0 retire <系統> scram|cert <topic>…"
  fi

  shift 2

  if [ -z "$sys" ]; then
    die "用法：$0 retire <系統> scram|cert <topic>…"
  fi

  local principal topic removed removed_total=0 principals done_message

  CID=$(cluster_id)

  section "27.6 下線（$sys）：解除 binding、配額；SCRAM 覆寫；憑證檔拿掉；刪 topic"

  if [ "$kind" = scram ]; then
    principals="app-$sys-a app-$sys-b"
  else
    principals="app-$sys"
  fi

  # 1. 每個帳號：解除 binding、拿掉配額；SCRAM 密碼覆寫成隨機值（帳號留著，稽核日誌裡的名字才查得到）、刪掉密碼檔
  for principal in $principals; do
    removed=$(remove_bindings "$principal")
    removed_total=$((removed_total + removed))

    kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$principal" --delete-config producer_byte_rate,consumer_byte_rate,request_percentage >/dev/null 2>&1

    if [ "$kind" = scram ]; then
      kafka-configs "${ADMIN[@]}" --alter --entity-type users --entity-name "$principal" --add-config "SCRAM-SHA-512=[iterations=8192,password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)]" >/dev/null 2>&1
      rm -f "$SECRETS_DIR/$principal.pass"
    fi
  done

  done_message="解除 binding $removed_total 條、配額拿掉"

  if [ "$kind" = scram ]; then
    done_message="$done_message、SCRAM 密碼覆寫成隨機值（帳號留著）"
  fi

  ok "$done_message"

  # 2. 憑證：從 requests.txt 拿掉、私鑰與憑證刪掉（到期不續）；CN 也從 REST 的白名單拿掉
  if [ "$kind" = cert ]; then
    sed -i "/^app-$sys /d" "$PKI_DIR/requests.txt"
    rm -f "$PKI_DIR/keys/app-$sys.key" "$PKI_DIR/requests/app-$sys.csr" "$PKI_DIR/incoming/app-$sys".* "$PKI_DIR/certs/app-$sys.crt" "$PKI_DIR/certs/app-$sys.p12"
    rm -f "$SECRETS_DIR/app-$sys-p12.pass"
    ok "憑證：requests.txt 那行、私鑰、CSR、憑證、p12 已拿掉（到期不續）"

    rest_allowlist "app-$sys" remove
  fi

  # 3. 交接檔
  rm -rf "$HANDOVER_DIR/app-$sys-"*.txt "$HANDOVER_DIR/app-$sys"

  # 4. topic（正式環境等保留期過了再刪）
  for topic in "$@"; do
    if kafka-topics "${ADMIN[@]}" --delete --topic "$topic" >/dev/null 2>&1; then
      ok "刪 topic $topic"
    else
      fail "刪 topic $topic"
    fi
  done

  # 5. 確認沒有剩下的 binding
  for principal in $principals; do
    if [ "$(binding_count "$principal")" != 0 ]; then
      fail "$principal 還有 binding"
    fi
  done
}

case $ACTION in
  onboard)
    onboard "${2:-}" "${3:-}" "${@:4}"
    ;;
  verify)
    verify "${2:-}" "${3:-}" "${4:-}"
    ;;
  retire)
    retire "${2:-}" "${3:-}" "${@:4}"
    ;;
  *)
    sed -n '2,17p' "$0"
    exit 1
    ;;
esac

# 沒有 finish_step：這一站每個系統都會再跑，不留 .done 標記
if [ "$FAIL_COUNT" != 0 ]; then
  exit 1
fi
