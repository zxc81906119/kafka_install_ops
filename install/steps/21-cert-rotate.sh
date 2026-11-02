#!/usr/bin/env bash
# 第 21 站：憑證輪替 —— leaf 換發（同一個 CA 或新 CA 簽），以及換 CA 時同步信任清單
# where: ops02 （root）
# run: on-demand（不在安裝順序裡；install.sh 照順序跑時略過，要換時直接執行這支）
#
# 用法：
#   bash steps/21-cert-rotate.sh status       每張憑證的序號與剩幾天、各端點實際出示的是哪一張
#   bash steps/21-cert-rotate.sh leaf         換發 conf/certs.txt 的全部 leaf：
#                                             第一次：新私鑰＋CSR 放 ~/pki/next/，印「請銀行簽」，停下（rc 2）
#                                             銀行放回 ~/pki/next/incoming/ 後再跑一次：檢查 → 做 keystore → 派送 → 滾動重啟 → 換成正本
#   bash steps/21-cert-rotate.sh trust-sync   銀行換好各主機 OS 的 bank-root.pem 之後，把我方的信任清單同步成一樣、滾動重啟：
#                                             換 CA 階段一（bank-root.pem 是新舊兩張根）、階段三（只剩新根）都是這個動作
#   bash steps/21-cert-rotate.sh chain <新中繼.pem>   leaf 不動，只把銀行給的新中繼重包進每個 p12（不用 CSR）→ 派送 → 滾動重啟 → 換成正本
#                                             用在：中繼同私鑰續簽；根換私鑰但中繼沿用私鑰、由新根重簽（手把手 21.0 判斷表的第 3、5、7 列）
# 換 CA 的三階段 = trust-sync（加新根）→ leaf（銀行用新 CA 簽）或 chain（中繼沿用私鑰時）→ trust-sync（退舊根）；手把手 21.3、21.4。
#
# 需要什麼：第 9 站的 ~/pki（requests.txt、store.pass）；要換的時段（會滾動重啟所有元件）。
# 產出什麼：新的 ~/pki/certs、~/pki/keys；舊的正本留在 ~/pki/old-<日期時間>/。
# 不變的東西：檔名、路徑、keystore 密碼。所以 properties 一個字都不用改，Secret Protection 的密文也不用重算。
# 能不能重跑：可以。leaf 在 ~/pki/next/ 還在時會接著做；檢查沒過時 next/ 留著，修好再跑一次。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

ACTION=${1:-status}
REQUESTS_FILE=$PKI_DIR/requests.txt     # 第 9 站產生的：名稱 EKU SAN（換發時照用，CN／SAN／EKU 不變）
NEXT_DIR=$PKI_DIR/next                  # 這一輪的新私鑰、CSR、銀行回覆、成品
STORE_PASSWORD_FILE=$PKI_DIR/store.pass

# 要檢查出示憑證的端點，寫法：主機:埠=會出示哪一張
ENDPOINTS=""
for host in $CONTROLLERS; do
  ENDPOINTS+=" $(fqdn "$host"):9093=kafka-internal"
done
for host in $BROKERS; do
  ENDPOINTS+=" $(fqdn "$host"):9092=kafka-internal $(fqdn "$host"):9095=cp-server $(fqdn "$host"):8090=cp-server"
done
for host in $RESTS; do
  ENDPOINTS+=" $(fqdn "$host"):8082=cp-server"
done
ENDPOINTS+=" $C3_FQDN:9021=cp-server $C3_FQDN:9090=cp-server"

# 每台的 7071（JMX exporter）是服務裡的 javaagent，讀同一個 keystore：controller 用 kafka-internal，其他用 cp-server（手把手 21.1、21.2.4）
if [ "$JMX_EXPORTER" = 1 ]; then
  for host in $CONTROLLERS; do
    ENDPOINTS+=" $(fqdn "$host"):7071=kafka-internal"
  done
  for host in $BROKERS $RESTS $C3_HOST; do
    ENDPOINTS+=" $(fqdn "$host"):7071=cp-server"
  done
fi

# files_for_host <主機>：每台要換的憑證檔（來源檔名 → 目的地都在 /etc/confluent/ssl/）
files_for_host() {
  case $1 in
    kc*)
      echo "certs/kafka-internal.p12"
      ;;
    kb*)
      echo "certs/kafka-internal.p12 certs/cp-server.p12"
      ;;
    rest*)
      echo "certs/cp-server.p12 certs/svc-rest.p12"
      ;;
    c3*)
      echo "certs/cp-server.p12 certs/cp-server.crt keys/cp-server.key certs/c3-monitoring.crt keys/c3-monitoring.key certs/svc-c3.p12"
      ;;
  esac
}

# request_names：requests.txt 裡每張憑證的名稱
request_names() {
  awk '{print $1}' "$REQUESTS_FILE"
}

# serial_of_file <憑證檔>：完整序號
serial_of_file() {
  openssl x509 -in "$1" -noout -serial | cut -d= -f2
}

# serial_of_endpoint <主機:埠>：那個端點實際出示的憑證序號（還沒開始聽時是空的）
serial_of_endpoint() {
  openssl s_client -connect "$1" -servername "${1%:*}" </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2
}

# second_serial：stdin 的 PEM 裡第二張（中繼）的序號
second_serial() {
  awk '/BEGIN CERT/{n++} n==2' | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2
}

# chain_of_file <憑證鏈檔>：「leaf 序號:中繼序號」
chain_of_file() {
  local leaf_serial intermediate_serial
  leaf_serial=$(serial_of_file "$1")
  intermediate_serial=$(second_serial < "$1")
  echo "$leaf_serial:$intermediate_serial"
}

# chain_of_endpoint <主機:埠>：那個端點出示的「leaf 序號:中繼序號」
chain_of_endpoint() {
  local presented leaf_serial intermediate_serial
  presented=$(openssl s_client -connect "$1" -servername "${1%:*}" -showcerts </dev/null 2>/dev/null)
  leaf_serial=$(openssl x509 -noout -serial 2>/dev/null <<<"$presented" | cut -d= -f2)
  intermediate_serial=$(second_serial <<<"$presented")
  echo "$leaf_serial:$intermediate_serial"
}

# common_name_of_subject <憑證檔>：subject 的 CN
common_name_of_subject() {
  openssl x509 -in "$1" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'
}

# common_name_of_issuer <憑證檔>：簽發者的 CN，例 PoC Bank Issuing CA 01
common_name_of_issuer() {
  openssl x509 -in "$1" -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'
}

# days_left <憑證檔>：還有幾天到期
days_left() {
  local end_date
  end_date=$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)
  echo $(( ($(date -d "$end_date" +%s) - $(date +%s)) / 86400 ))
}

# san_of_cert <憑證檔>：SAN 排好順序，逗號分隔（沒有就是空的）
#   例：DNS:kc01, DNS:kc01.poc.lab → kc01,kc01.poc.lab
san_of_cert() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,
}

# sorted_list <逗號分隔的清單>：排好順序（- 表示沒有，印空的）
sorted_list() {
  if [ "$1" != - ]; then
    tr ',' '\n' <<<"$1" | sort | paste -sd,
  fi
}

# san_addext <逗號分隔的主機名稱>：換成 subjectAltName 的寫法
#   例：kc01.poc.lab,kc01 → DNS:kc01.poc.lab,DNS:kc01
san_addext() {
  tr ',' '\n' <<<"$1" | sed 's/^/DNS:/' | paste -sd,
}

# missing_replies：銀行回覆還沒放進 next/incoming/ 的憑證名稱（空白分隔）
missing_replies() {
  local cert_name missing=""

  for cert_name in $(request_names); do
    if [ ! -s "$NEXT_DIR/incoming/$cert_name.crt" ]; then
      missing+="${missing:+ }$cert_name"
    fi
  done

  echo "$missing"
}

# split_reply <名稱>：incoming/<名稱>.crt 拆成 leaf（第一張）和 issuers（其餘的中繼 CA）
split_reply() {
  local part_prefix=$NEXT_DIR/incoming/$1.part

  # 每遇到一行 BEGIN CERTIFICATE 就換寫下一個檔：.part1、.part2…
  awk -v out="$part_prefix" 'BEGIN{n=0} /BEGIN CERT/{n++} {print > (out n)}' "$NEXT_DIR/incoming/$1.crt"

  mv "${part_prefix}1" "$NEXT_DIR/incoming/$1.leaf.pem"
  cat "$part_prefix"[2-9] > "$NEXT_DIR/incoming/$1.issuers.pem" 2>/dev/null
  rm -f "$part_prefix"*
}

# copy_next_files <主機> <next/ 底下的相對路徑，空白分隔>：把這些檔放到那台的 /tmp/
copy_next_files() {
  local host=$1 file_list=$2
  (
    if ! cd "$NEXT_DIR"; then
      exit 1
    fi

    # shellcheck disable=SC2086  # file_list 要拆成一個一個檔
    copy_to_tmp "$host" $file_list
  )
}

# restart_c3_embedded：C3 這台的 Prometheus、Alertmanager（用 PEM）；C3 本身由 rolling_restart c3 重啟
restart_c3_embedded() {
  ssh_script "$C3_HOST" <<'EOF'
for unit in prometheus alertmanager; do
  sudo systemctl restart $unit
done
EOF
}

# install_in_ssl_dir <主機> </tmp 裡的檔名> </etc/confluent/ssl 裡的檔名>：放到定位（root:confluent 0640），成功才刪 /tmp 的
install_in_ssl_dir() {
  ssh_script "$1" TMP_NAME="$2" SSL_NAME="$3" <<'EOF'
if ! sudo install -o root -g confluent -m 0640 /tmp/$TMP_NAME /etc/confluent/ssl/$SSL_NAME; then
  exit 1
fi

rm -f /tmp/$TMP_NAME
EOF
}

# verify_code_of_endpoint <主機:埠>：用 $BANK_ROOT_CA 驗那個端點的憑證，印 Verify return code（0 = 驗得過；沒有回應是空的）
verify_code_of_endpoint() {
  openssl s_client -connect "$1" -servername "${1%%:*}" -CAfile "$BANK_ROOT_CA" </dev/null 2>/dev/null \
    | sed -n 's/.*Verify return code: \([0-9]*\).*/\1/p' | tail -1
}

# truststore_aliases：truststore.p12 裡有哪些 alias（空白分隔）
truststore_aliases() {
  keytool -list -keystore "$CERTS_DIR/truststore.p12" -storetype PKCS12 -storepass:file "$STORE_PASSWORD_FILE" 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | paste -sd' '
}

# show_status：每張憑證與每個端點
show_status() {
  local cert_name cert_file days serial_tail issuer endpoint address expected served

  section "每張憑證（序號末 8 碼、剩幾天、簽發者）"
  for cert_name in $(request_names); do
    cert_file=$CERTS_DIR/$cert_name.crt
    days=$(days_left "$cert_file")
    serial_tail=$(serial_of_file "$cert_file" | tail -c 9)
    issuer=$(common_name_of_issuer "$cert_file")

    log "$(printf '%-19s %s  %3s 天  %s' "$cert_name" "$serial_tail" "$days" "$issuer")"

    if [ "$days" -lt 30 ]; then
      warn "$cert_name 剩 $days 天，該換了（bash $0 leaf）"
    fi
  done

  section "各端點實際出示的憑證（和正本一致才算換好）"
  for endpoint in $ENDPOINTS; do
    address=${endpoint%=*}
    cert_name=${endpoint#*=}
    expected=$(serial_of_file "$CERTS_DIR/$cert_name.crt")
    served=$(serial_of_endpoint "$address")

    if [ "$served" = "$expected" ]; then
      ok "$address 出示 $cert_name（${served: -8}）"
    else
      fail "$address 出示 ${served: -8}，正本是 ${expected: -8}"
    fi
  done
}

# ---- leaf 第一段：新私鑰與 CSR ----
create_requests() {
  local cert_name eku san_names extensions

  section "21.2.1 新私鑰與 CSR（照 requests.txt：CN、SAN、EKU 不變）"
  install -d -m 0700 "$NEXT_DIR" "$NEXT_DIR/keys" "$NEXT_DIR/requests" "$NEXT_DIR/incoming" "$NEXT_DIR/certs"

  while read -r cert_name eku san_names; do
    # 1. 新私鑰（0600）
    install -m 0600 /dev/null "$NEXT_DIR/keys/$cert_name.key"
    openssl genrsa -out "$NEXT_DIR/keys/$cert_name.key" 2048 2>/dev/null

    # 2. CSR 的 extension；有 SAN 的多加一行 subjectAltName
    extensions=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku")
    if [ "$san_names" != - ]; then
      extensions+=(-addext "subjectAltName=$(san_addext "$san_names")")
    fi

    # 3. CSR
    if openssl req -new -key "$NEXT_DIR/keys/$cert_name.key" -sha256 -subj "/CN=$cert_name/O=PoC Bank/C=TW" "${extensions[@]}" -out "$NEXT_DIR/requests/$cert_name.csr"; then
      ok "$cert_name: csr"
    else
      fail "$cert_name: openssl req"
    fi
  done < "$REQUESTS_FILE"
}

# ---- chain 第一段：現在的私鑰與 leaf ＋ 銀行給的新中繼，放進 next/（之後和 leaf 共用檢查、派送、換成正本） ----
prepare_chain() {
  local new_chain_file=$1 cert_name

  if [ ! -s "$new_chain_file" ]; then
    die "找不到新中繼的 PEM：$new_chain_file（銀行給的中繼憑證；若有多層中繼依序放在同一個檔）"
  fi

  if [ -e "$NEXT_DIR" ]; then
    die "$NEXT_DIR 已經存在（上一輪還沒做完？）：確認後刪掉再跑"
  fi

  section "21.4 換鏈：leaf 不動，配上新中繼 $(common_name_of_subject "$new_chain_file")（簽發者 $(common_name_of_issuer "$new_chain_file")）"
  install -d -m 0700 "$NEXT_DIR" "$NEXT_DIR/keys" "$NEXT_DIR/requests" "$NEXT_DIR/incoming" "$NEXT_DIR/certs"

  for cert_name in $(request_names); do
    install -m 0600 "$KEYS_DIR/$cert_name.key" "$NEXT_DIR/keys/"
    install -m 0644 "$PKI_DIR/requests/$cert_name.csr" "$NEXT_DIR/requests/"

    # 現在的 leaf（憑證鏈檔的第一張）＋ 新中繼
    awk '/BEGIN CERT/{n++} n==1' "$CERTS_DIR/$cert_name.crt" > "$NEXT_DIR/incoming/$cert_name.crt"
    cat "$new_chain_file" >> "$NEXT_DIR/incoming/$cert_name.crt"

    ok "$cert_name：leaf 序號 $(serial_of_file "$CERTS_DIR/$cert_name.crt" | tail -c 9) 不變，換上新中繼"
  done
}

# ---- leaf 第二段：銀行回覆檢查、做 keystore ----
check_and_build() {
  local cert_name eku san_names leaf key_file cert_pubkey key_pubkey common_name actual_san expected_san problems days

  section "21.2.3 拆開回覆、五項檢查＋憑證鏈（對 OS 的 bank-root.pem 驗；換 CA 階段二時它是新舊兩張根）"

  # 1. 拆開每一張回覆
  for cert_name in $(request_names); do
    split_reply "$cert_name"
  done

  # 2. 每一張：私鑰相符、CN、SAN、剩幾天、整條鏈驗得到銀行根憑證
  while read -r cert_name eku san_names; do
    leaf=$NEXT_DIR/incoming/$cert_name.leaf.pem
    key_file=$NEXT_DIR/keys/$cert_name.key
    cert_pubkey=$(openssl x509 -in "$leaf" -pubkey -noout | sha256sum | cut -c1-16)
    key_pubkey=$(openssl pkey -in "$key_file" -pubout 2>/dev/null | sha256sum | cut -c1-16)
    common_name=$(common_name_of_subject "$leaf")
    actual_san=$(san_of_cert "$leaf")
    expected_san=$(sorted_list "$san_names")
    days=$(days_left "$leaf")
    problems=""

    if [ "$cert_pubkey" != "$key_pubkey" ]; then
      problems+=" 私鑰不符"
    fi

    if [ "$common_name" != "$cert_name" ]; then
      problems+=" CN=$common_name"
    fi

    if [ "$actual_san" != "$expected_san" ]; then
      problems+=" SAN 不同"
    fi

    if [ "$days" -le 30 ]; then
      problems+=" 只剩 $days 天"
    fi

    if ! openssl verify -CAfile "$BANK_ROOT_CA" -untrusted "$NEXT_DIR/incoming/$cert_name.issuers.pem" "$leaf" >/dev/null 2>&1; then
      problems+=" 憑證鏈驗不過"
    fi

    if [ -z "$problems" ]; then
      ok "$cert_name：檢查都過，效期 $days 天，簽發者 $(common_name_of_issuer "$leaf")"
    else
      fail "$cert_name:$problems"
    fi
  done < "$REQUESTS_FILE"

  if [ "$FAIL_COUNT" != 0 ]; then
    die "有憑證沒通過檢查：退回銀行重簽（$NEXT_DIR 留著，修好後再跑一次）"
  fi

  section "做 keystore（同一個 keystore 密碼）"
  for cert_name in $(request_names); do
    cat "$NEXT_DIR/incoming/$cert_name.leaf.pem" "$NEXT_DIR/incoming/$cert_name.issuers.pem" > "$NEXT_DIR/certs/$cert_name.crt"

    if openssl pkcs12 -export -name "$cert_name" -inkey "$NEXT_DIR/keys/$cert_name.key" -in "$NEXT_DIR/certs/$cert_name.crt" \
         -out "$NEXT_DIR/certs/$cert_name.p12" -passout file:"$STORE_PASSWORD_FILE"; then
      chmod 0600 "$NEXT_DIR/certs/$cert_name.p12"
    else
      fail "$cert_name: pkcs12"
    fi
  done

  if [ "$FAIL_COUNT" != 0 ]; then
    die "做 keystore 失敗"
  fi

  ok "$NEXT_DIR/certs：$(ls "$NEXT_DIR/certs" | wc -l) 個檔"
}

# ---- leaf 第三段：派送、滾動重啟、確認出示新序號 ----
deploy_and_restart() {
  local host file_list file_names endpoint address cert_name expected served attempt

  section "21.2.4 派送（全部主機先放好；服務只在啟動時讀檔）→ 滾動重啟 → 確認每個端點出示新的"

  # 1. 全部主機先放好
  for host in $CLUSTER_HOSTS; do
    file_list=$(files_for_host "$host")

    if ! copy_next_files "$host" "$file_list"; then
      fail "$host: scp"
      continue
    fi

    # 遠端要的是檔名：certs/cp-server.p12 → cp-server.p12
    file_names=$(tr ' ' '\n' <<<"$file_list" | xargs -n1 basename | paste -sd' ')

    if ssh_script "$host" FILES="$file_names" <<'EOF'
for file in $FILES; do
  if ! sudo install -o root -g confluent -m 0640 /tmp/$file /etc/confluent/ssl/$file; then
    exit 1
  fi

  rm -f /tmp/$file
done
EOF
    then
      ok "$host: $(wc -w <<<"$file_list") 個檔"
    else
      fail "$host: install"
    fi
  done

  if [ "$FAIL_COUNT" != 0 ]; then
    die "派送失敗，不重啟（主機上的檔可能已經部分換了；修好後再跑一次）"
  fi

  # 2. 滾動重啟
  if ! rolling_restart controllers brokers rests; then
    die "滾動重啟有主機沒健康"
  fi

  # C3 這台有三個服務吃憑證：Prometheus、Alertmanager 用 PEM，C3 用 p12
  restart_c3_embedded

  if ! rolling_restart c3; then
    die "C3 沒有健康"
  fi

  # 3. 比「leaf 序號：中繼序號」：換發時 leaf 變、換鏈時中繼變，兩種都看得出來
  for endpoint in $ENDPOINTS; do
    address=${endpoint%=*}
    cert_name=${endpoint#*=}
    expected=$(chain_of_file "$NEXT_DIR/certs/$cert_name.crt")

    # controller 起來後 9093 要幾秒才開：每 2 秒看一次，最多 30 次
    for attempt in $(seq 1 30); do
      served=$(chain_of_endpoint "$address")

      if [ "$served" = "$expected" ]; then
        break
      fi

      sleep 2
    done

    if [ "$served" = "$expected" ]; then
      ok "$address 出示新的 $cert_name"
    else
      fail "$address 出示 ${served}，新的是 ${expected}"
    fi
  done

  if [ "$FAIL_COUNT" != 0 ]; then
    die "有端點還沒出示新憑證"
  fi
}

# ---- leaf 第四段：換成正本、交出去的那幾張 ----
promote() {
  local old_dir cert_name topic_count leader_line breakglass_pem rest_app_code old_rest_app_code

  old_dir=$PKI_DIR/old-$(date +%Y%m%d-%H%M%S)

  section "21.2.5 換成正本（舊的移到 $old_dir）"

  # 1. 舊的搬到 old-<日期時間>/，新的放回正本位置（私鑰與 p12 0600）
  install -d -m 0700 "$old_dir/keys" "$old_dir/certs" "$old_dir/requests" "$old_dir/incoming"

  for cert_name in $(request_names); do
    mv "$KEYS_DIR/$cert_name.key" "$old_dir/keys/"
    mv "$CERTS_DIR/$cert_name.crt" "$CERTS_DIR/$cert_name.p12" "$old_dir/certs/"
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

  # 2. 操作機自己用的兩張：管理 client（svc-ops）、查 quorum（kafka-internal）
  topic_count=$(kafka-topics --bootstrap-server "$BROKER_TOKEN" --command-config "$ADMIN_CLIENT_CONF" --list 2>/dev/null | wc -l)
  if [ "$topic_count" -gt 0 ]; then
    ok "svc-ops 管理 client 可用（$topic_count 個 topic）"
  else
    fail "svc-ops 管理 client 失敗"
  fi

  leader_line=$(kafka-metadata-quorum --bootstrap-controller "$FIRST_CONTROLLER:9093" --command-config "$INTERNAL_CLIENT_CONF" describe --status 2>/dev/null | grep -o 'LeaderId: *[0-9]*')
  if [ -n "$leader_line" ]; then
    ok "kafka-internal 查 quorum 可用（$leader_line）"
  else
    fail "kafka-internal 查 quorum 失敗"
  fi

  # 3. 緊急身分：選單 91 讀的 ~/secrets/opmenu-breakglass.pem 換成新憑證（舊的另存 .prev.pem，到期前都還有效）
  if [ "$OPMENU" = 1 ] && [ -f "$KEYS_DIR/opmenu-breakglass.key" ]; then
    breakglass_pem=$SECRETS_DIR/opmenu-breakglass.pem

    if [ -f "$breakglass_pem" ]; then
      install -m 0600 "$breakglass_pem" "$SECRETS_DIR/opmenu-breakglass.prev.pem"
    fi

    install -m 0600 /dev/null "$breakglass_pem"
    cat "$KEYS_DIR/opmenu-breakglass.key" "$CERTS_DIR/opmenu-breakglass.crt" > "$breakglass_pem"
    ok "新憑證已放到 $breakglass_pem（0600；舊的另存 $SECRETS_DIR/opmenu-breakglass.prev.pem）"
  fi

  # 4. 應用程式的憑證：新的（交給應用程式團隊）要能用；舊的在效期內也還能用（只提醒，換發時舊的可能已過期）
  rest_app_code=$(rest_app_curl -s -o /dev/null -m 30 -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters")
  if [ "$rest_app_code" = 200 ]; then
    ok "新的 $FIRST_REST_APP 憑證經負載平衡 200"
  else
    fail "新的 $FIRST_REST_APP 憑證：$rest_app_code"
  fi

  old_rest_app_code=$(curl -s --cert "$old_dir/certs/$FIRST_REST_APP.crt" --key "$old_dir/keys/$FIRST_REST_APP.key" -o /dev/null -m 30 -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters")
  if [ "$old_rest_app_code" = 200 ]; then
    ok "舊的 $FIRST_REST_APP 憑證（還在效期內）經負載平衡 200"
  else
    warn "舊的 $FIRST_REST_APP 憑證：$old_rest_app_code（過期了就是正常的；沒過期的話，應用程式還沒換之前會連不上）"
  fi

  ask_bank "應用程式團隊：新的 $(tr '|' ' ' <<<"$REST_APPS") 憑證在 $CERTS_DIR／$KEYS_DIR，請在你們的時段換上（舊的到期前都有效；換 CA 階段三之前一定要換）。"
}

# ---- trust-sync：我方信任清單跟著 OS 的 bank-root.pem ----
trust_sync() {
  local root_count endpoint address verify_code unverified=0 work_dir root_file alias_name host alice_login

  section "信任清單同步：以 $BANK_ROOT_CA 為準（銀行 OS 團隊先換好；換 CA 階段一是新舊兩張、階段三只剩新的）"

  root_count=$(awk '/BEGIN CERTIFICATE/ {c++} END {print c + 0}' "$BANK_ROOT_CA")
  if [ "$root_count" -lt 1 ]; then
    die "$BANK_ROOT_CA 裡沒有憑證"
  fi

  # 1. 先確認每個端點出示的憑證都驗得過「即將生效」的信任清單。換 CA 階段三（只剩新根）時，
  #    我方的 leaf 若還是舊 CA 簽的，同步下去 broker 就驗不過 controller、整個叢集起不來（lab 實際發生過）
  for endpoint in $ENDPOINTS; do
    address=${endpoint%=*}
    verify_code=$(verify_code_of_endpoint "$address")

    if [ "$verify_code" = 0 ]; then
      ok "$address 驗得過"
    else
      fail "$address 驗不過（${verify_code:-沒有回應}）"
      unverified=1
    fi
  done

  if [ "$unverified" != 0 ]; then
    die "有端點出示的憑證驗不過新的信任清單：先做 leaf（銀行用新 CA 簽），再同步；什麼都沒改"
  fi

  # 2. 把 bundle 拆成一張一張，以 CN 當 alias 重建 truststore（舊的留 .old）
  work_dir=$(mktemp -d)
  awk -v out="$work_dir/root-" 'BEGIN{n=0} /BEGIN CERT/{n++} n>0 {print > (out n ".pem")}' "$BANK_ROOT_CA"
  cp -p "$CERTS_DIR/truststore.p12" "$CERTS_DIR/truststore.p12.old"
  rm -f "$work_dir/truststore.p12"

  for root_file in "$work_dir"/root-*.pem; do
    alias_name=$(common_name_of_subject "$root_file" | tr 'A-Z ' 'a-z-')

    if ! keytool -importcert -noprompt -alias "$alias_name" -file "$root_file" -keystore "$work_dir/truststore.p12" -storetype PKCS12 \
         -storepass:file "$STORE_PASSWORD_FILE" >/dev/null 2>&1; then
      die "匯入 $alias_name 失敗"
    fi
  done

  install -m 0600 "$work_dir/truststore.p12" "$CERTS_DIR/truststore.p12"
  cp "$BANK_ROOT_CA" "$CERTS_DIR/bank-root.pem"
  rm -rf "$work_dir"
  ok "truststore：$(truststore_aliases)"

  # 3. 派送 truststore
  for host in $CLUSTER_HOSTS; do
    if ! copy_to_tmp "$host" "$CERTS_DIR/truststore.p12"; then
      fail "$host: scp"
      continue
    fi

    if ! install_in_ssl_dir "$host" truststore.p12 truststore.p12; then
      fail "$host: install"
    fi
  done

  # 4. C3 的 Prometheus／Alertmanager 驗 client 用的 ca.pem
  if ! copy_to_tmp "$C3_HOST" "$CERTS_DIR/bank-root.pem"; then
    fail "$C3_HOST: ca.pem"
  elif ! install_in_ssl_dir "$C3_HOST" bank-root.pem ca.pem; then
    fail "$C3_HOST: ca.pem"
  fi

  # 5. OP menu 在操作機上的兩份
  if [ -d /etc/opmenu/ssl ]; then
    if ! install -m 0644 "$CERTS_DIR/truststore.p12" /etc/opmenu/ssl/truststore.p12; then
      fail "OP menu 的 truststore 同步失敗"
    elif ! install -m 0644 "$CERTS_DIR/bank-root.pem" /etc/opmenu/ssl/ca.pem; then
      fail "OP menu 的 ca.pem 同步失敗"
    else
      ok "OP menu 的 truststore、ca.pem 已同步"
    fi
  fi

  # 6. 17.5 交給銀行的 to-bank/prometheus/ca.pem 也要跟著換：之後重新交付 to-bank/ 時才不會把舊根帶回去（Prometheus 會全部抓不到）
  if [ -d "$MONITORING_DIR/to-bank/prometheus" ]; then
    if install -m 0644 "$CERTS_DIR/bank-root.pem" "$MONITORING_DIR/to-bank/prometheus/ca.pem"; then
      ok "to-bank/prometheus/ca.pem 已同步（$root_count 張根）"
    else
      fail "to-bank/prometheus/ca.pem 同步失敗"
    fi
  fi

  if [ "$FAIL_COUNT" != 0 ]; then
    die "派送失敗，不重啟"
  fi

  # 7. 滾動重啟
  if ! rolling_restart controllers brokers rests; then
    die "滾動重啟有主機沒健康"
  fi

  restart_c3_embedded

  if ! rolling_restart c3; then
    die "C3 沒有健康"
  fi

  # 8. MDS 還連得上 AD
  alice_login=$(curl -s --cacert "$BANK_ROOT_CA" -u "alice:$(cat "$SECRETS_DIR/ad-test-users.pass")" -o /dev/null -w '%{http_code}' "$MDS_URL/security/1.0/authenticate")
  if [ "$alice_login" = 200 ]; then
    ok "alice 登入 MDS（MDS 經 LDAPS 連 AD）：200"
  else
    fail "alice 登入 MDS：$alice_login（AD 的憑證是不是還是舊 CA 簽的？）"
  fi

  ask_bank "監控團隊：行內 Prometheus 抓 JMX exporter 用的 ca.pem 換成 $CERTS_DIR/bank-root.pem 這份（$root_count 張根）。" \
           "應用程式團隊：client 端的 truststore 也要有同樣的根（走 REST、SCRAM 直連的都要）。"
}

# run_leaf：next/requests 已經有東西就接著做（缺回覆就再停一次）；沒有就是第一次
run_leaf() {
  local request_count=0 missing

  if [ -d "$NEXT_DIR/requests" ]; then
    request_count=$(ls "$NEXT_DIR/requests" | wc -l)
  fi

  if [ "$request_count" -gt 0 ]; then
    missing=$(missing_replies)

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
  fi
}

case $ACTION in
  status)
    show_status
    ;;
  leaf)
    run_leaf
    ;;
  chain)
    prepare_chain "${2:?用法：bash $0 chain <新中繼.pem>}"
    check_and_build
    deploy_and_restart
    promote
    ;;
  trust-sync)
    trust_sync
    ;;
  *)
    die "用法：bash $0 status|leaf|chain <新中繼.pem>|trust-sync"
    ;;
esac

finish_step
