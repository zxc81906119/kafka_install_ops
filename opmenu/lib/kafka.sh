# kafka.sh — 以操作者身分跑 Kafka 工具、呼叫 MDS、換 token;91 用操作機上的緊急憑證檔。加上各項目共用的 Kafka / MDS 小工具。
# 假設操作機已安裝 Confluent 的指令工具與 curl。這裡不放任何環境值:全部讀 OPMENU_* 變數。
# 安全:帳密與 token 經 stdin 交給 curl(-K -),不進命令列;連線設定檔放記憶體檔案系統、離開時刪。
#
# be_* = 連到環境的介面（項目只透過它們碰 Kafka／MDS）；k_* = 各項目共用的小工具。

be_name() {
  echo vm
}

be_truststore_path() {
  echo "$OPMENU_TRUSTSTORE"
}

be_truststore_password() {
  cat "$OPMENU_TRUSTSTORE_PASSWORD_FILE"
}

# ── 呼叫 MDS ──
# _curl_q <值>：放進 curl 設定檔的值要跳脫 \ 和 "（例 pa"ss → pa\"ss）
_curl_q() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# _mds_curl <路徑> <curl 設定檔內容（多行）> [curl 參數...]：逐台 MDS 嘗試，第一台連得上的回應就印出來
#   MDS 可以填多台（OPMENU_MDS_URL，逗號隔開）。401／403 也算「連得上」，不換下一台。
#   帳密、token 放在 curl 設定檔內容裡，經 stdin（-K -）交給 curl，不會出現在命令列（ps 看不到）。
_mds_curl() {
  local path="$1"
  local config="$2"
  shift 2
  local url reply

  for url in $(echo "$OPMENU_MDS_URL" | tr ',' ' '); do
    reply=$(printf '%s\n' "$config" | curl -s --max-time 10 --cacert "$OPMENU_CA_PEM" -K - "$@" "$url$path")

    if [ $? -eq 0 ]; then
      printf '%s' "$reply"
      return 0
    fi
  done

  echo "MDS 全部連不上:$OPMENU_MDS_URL" >&2
  return 1
}

# be_mds_login <帳號> <密碼>：用 AD 帳密向 MDS 換 token，印出 token
#   回傳：0 = 換到了；1 = 帳密不對（MDS 沒給 token）；2 = MDS 全部連不上
be_mds_login() {
  local quoted_login reply token

  quoted_login=$(_curl_q "$1:$2")

  reply=$(_mds_curl /security/1.0/authenticate "user = \"$quoted_login\"" -H "Accept: application/json")
  if [ $? -ne 0 ]; then
    return 2
  fi

  token=$(printf '%s' "$reply" | grep -o '"auth_token":"[^"]*"' | cut -d'"' -f4)
  if [ -z "$token" ]; then
    return 1
  fi

  echo "$token"
}

# be_mds <方法> <路徑> [JSON 內容]：用本人的 token 呼叫 MDS，印出回應；最後一行固定是「HTTP <狀態碼>」
#   例：be_mds POST /security/1.0/lookup/role/SystemAdmin '{"clusters":{"kafka-cluster":"abc"}}'
#   回應也會另存一份到 OP_LAST_RAW（執行流程用它判斷是不是被拒絕）
be_mds() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local arguments=(-X "$method" -H "Content-Type: application/json" -w $'\nHTTP %{http_code}')

  if [ -n "$body" ]; then
    arguments+=(-d "$body")
  fi

  local quoted_token
  quoted_token=$(_curl_q "$OP_TOKEN")

  _mds_curl "$path" "header = \"Authorization: Bearer $quoted_token\"" "${arguments[@]}" | tee -a "$OP_LAST_RAW"
}

# be_cluster_id：向 MDS 問 Kafka cluster ID（不需要帳密）
#   回應裡找 "id":"<cluster ID>"；awk 用雙引號切欄位，只看第一筆，第 4 段就是值
be_cluster_id() {
  _mds_curl /v1/metadata/id "" | grep -o '"id":"[^"]*"' | awk -F\" 'NR==1 {print $4}'
}

# be_http [curl 參數...]：用 curl 連 HTTPS（帶銀行根憑證、10 秒逾時）
be_http() {
  curl -s --max-time 10 --cacert "$OPMENU_CA_PEM" "$@"
}

# ── 跑 Kafka 指令工具 ──
# be_kafka <工具> [參數...]：在操作機上跑 Kafka 指令工具，以操作者本人的 AD 身分（LDAP listener）
#   例：be_kafka kafka-topics --describe --topic orders.events
#   工具的原始輸出另存一份到 OP_LAST_RAW；畫面上去掉 SLF4J、WARNING 這類雜訊
be_kafka() {
  local tool="$1"
  shift
  local output rc

  output=$(KAFKA_HEAP_OPTS="-Xmx256m" "$tool" \
    --bootstrap-server "$OPMENU_BOOTSTRAP" \
    --command-config "$OP_CLIENT_CONF" \
    "$@" 2>&1)
  rc=$?

  printf '%s\n' "$output" >> "$OP_LAST_RAW"
  printf '%s\n' "$output" | grep -v '^SLF4J\|^WARNING\|is deprecated'

  return $rc
}

# be_bootstrap_kafka <工具> [參數...]：91 緊急模式用備用憑證跑 Kafka 指令工具
#   client 憑證（PEM：私鑰＋憑證鏈）從操作機上 0600 的檔案（OPMENU_BREAKGLASS_PEM）讀進記憶體檔案系統，
#   組成「用憑證向 MDS 換 token」的連線設定，用完即刪。憑證身分（例 User:svc-ops）在 MDS 綁 SystemAdmin；broker 端不需要任何改動。
be_bootstrap_kafka() {
  local tool="$1"
  shift

  if [ -z "${OPMENU_BREAKGLASS_PEM:-}" ]; then
    echo "沒有設定 OPMENU_BREAKGLASS_PEM(緊急模式憑證 PEM 的檔案路徑)" >&2
    return 1
  fi

  # 1. 憑證讀進暫存檔（0600），確認是「私鑰＋憑證」
  local pem conf
  pem=$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")
  conf=$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")

  if ! secret_get "$OPMENU_BREAKGLASS_PEM" > "$pem"; then
    rm -f "$pem" "$conf"
    return 1
  fi

  if ! grep -q 'BEGIN .*PRIVATE KEY' "$pem" || ! grep -q 'BEGIN CERTIFICATE' "$pem"; then
    echo "緊急憑證檔不是 PEM 私鑰 + 憑證" >&2
    rm -f "$pem" "$conf"
    return 1
  fi

  # 2. 憑證換 token 要找一台活著的 MDS：逐台問 /v1/metadata/id，用第一台回 200 的（不能假設 metadataServerUrls 會自己換台）
  local url mds=""
  for url in $(echo "$OPMENU_MDS_URL" | tr ',' ' '); do
    if [ "$(be_http -o /dev/null -w "%{http_code}" "$url/v1/metadata/id" 2> /dev/null)" = 200 ]; then
      mds=$url
      break
    fi
  done

  if [ -z "$mds" ]; then
    echo "所有 MDS 都連不上($OPMENU_MDS_URL):緊急憑證換不到 token。Kafka 的緊急操作改用手把手 28.6 的 kafka-admin(SCRAM,9095)" >&2
    rm -f "$pem" "$conf"
    return 1
  fi

  # 3. 連線設定：OAUTHBEARER，token 由憑證向那台 MDS 換
  cat > "$conf" <<EOC
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenCertificateLoginCallbackHandler
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required metadataServerUrls="$mds";
confluent.metadata.ssl.keystore.type=PEM
confluent.metadata.ssl.keystore.location=$pem
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=$(be_truststore_path)
confluent.metadata.ssl.truststore.password=$(be_truststore_password)
ssl.truststore.type=PKCS12
ssl.truststore.location=$(be_truststore_path)
ssl.truststore.password=$(be_truststore_password)
EOC

  # 4. 執行，然後馬上刪掉憑證與設定
  local output rc
  output=$(KAFKA_HEAP_OPTS="-Xmx256m" "$tool" \
    --bootstrap-server "$OPMENU_BREAKGLASS_BOOTSTRAP" \
    --command-config "$conf" \
    "$@" 2>&1)
  rc=$?
  rm -f "$pem" "$conf"

  printf '%s\n' "$output" >> "$OP_LAST_RAW"
  printf '%s\n' "$output" | grep -v '^SLF4J\|^WARNING\|is deprecated'

  return $rc
}

# ── 各項目共用的小工具 ──
# k_scope：MDS 請求裡的 scope（這個 Kafka cluster），例 {"clusters":{"kafka-cluster":"abc"}}
k_scope() {
  printf '{"clusters":{"kafka-cluster":"%s"}}' "$OPMENU_KAFKA_CLUSTER_ID"
}

# k_bind_body <資源類型> <名稱> <比對方式>：建／刪 binding 的 JSON，例 k_bind_body Topic orders. PREFIXED
k_bind_body() {
  local scope format
  scope=$(k_scope)
  format='{"scope":%s,"resourcePatterns":[{"resourceType":"%s","name":"%s","patternType":"%s"}]}'

  printf "$format" "$scope" "$1" "$2" "$3"
}

# k_http_ok：從 stdin 讀 be_mds 的回應，最後一行是 HTTP 2xx 才回 0（用法：be_mds … | k_http_ok）
k_http_ok() {
  tail -1 | grep -q -E "HTTP 2[0-9][0-9]"
}

# k_show_mds <方法> <路徑> [JSON]：呼叫 MDS、印出回應（去掉最後一行 HTTP 狀態）；不是 2xx 回 1
k_show_mds() {
  local reply
  reply=$(be_mds "$@")

  printf '%s\n' "$reply" | sed '$d'
  printf '%s\n' "$reply" | k_http_ok
}

# k_roles_of <principal>：這個 principal 在 cluster 層級有哪些 role
k_roles_of() {
  k_show_mds POST "/security/1.0/lookup/principals/$1/roleNames" "$(k_scope)"
}

# k_gen_pw：產生 20 個字元的隨機密碼（只有英文字母與數字）
k_gen_pw() {
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20
}

# k_disable_scram <帳號>：停用帳號 = 把 SCRAM 密碼覆寫成沒人知道的隨機值；帳號本來就沒有 SCRAM 憑證時不動作
#   不用 --delete-config：實測刪除 SCRAM 憑證後，下一次重啟 broker 會失敗。
k_disable_scram() {
  local account="$1"

  if ! be_kafka kafka-configs --describe \
      --entity-type users \
      --entity-name "$account" 2> /dev/null \
      | grep -q "SCRAM-SHA-512="; then
    echo "帳號 $account 沒有 SCRAM 憑證,略過"
    return 0
  fi

  be_kafka kafka-configs --alter \
    --add-config "SCRAM-SHA-512=[password=$(k_gen_pw)]" \
    --entity-type users \
    --entity-name "$account"
}

# k_unbind_user <帳號> <role> <資源類型> <名稱 prefix>：解除一條 binding（失敗不印、不中斷）
k_unbind_user() {
  local body
  body=$(k_bind_body "$3" "$4" PREFIXED)

  be_mds DELETE "/security/1.0/principals/User:$1/roles/$2/bindings" "$body" > /dev/null 2>&1
}

# k_cluster_counts：印「<under-replicated 數> <offline 數> <在線 broker 數>」，例 "0 0 4"
#   哪一項的指令失敗：under-replicated／offline 印 999、在線 broker 印 0（都會被當成不健康）
k_cluster_counts() {
  local output under_replicated offline live

  output=$(be_kafka kafka-topics --describe --under-replicated-partitions 2> /dev/null)
  if [ $? -eq 0 ]; then
    under_replicated=$(printf '%s\n' "$output" | grep -c "Partition:")
  else
    under_replicated=999
  fi

  output=$(be_kafka kafka-topics --describe --unavailable-partitions 2> /dev/null)
  if [ $? -eq 0 ]; then
    offline=$(printf '%s\n' "$output" | grep -c "Partition:")
  else
    offline=999
  fi

  output=$(be_kafka kafka-broker-api-versions 2> /dev/null)
  if [ $? -eq 0 ]; then
    live=$(printf '%s\n' "$output" | grep -c '^[A-Za-z0-9._-]*:[0-9]* (id: ')
  else
    live=0
  fi

  echo "$under_replicated $offline $live"
}

# k_license_claims：生效中的 license（JWT）存在 _confluent-command：以本人身分讀出最後一個，印出中間那段（payload）的 JSON（手把手 26.1）
#   讀不到回 1。JWT 長這樣：eyJ…（header）.eyJ…（payload）.…（簽章），payload 是 base64url，要補 = 才能解
k_license_claims() {
  local jwt payload

  jwt=$(be_kafka kafka-console-consumer \
      --topic _confluent-command \
      --from-beginning \
      --timeout-ms 20000 2> /dev/null \
    | grep -a -o 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' \
    | tail -1)

  if [ -z "$jwt" ]; then
    return 1
  fi

  # 取第二段，base64url 換回 base64（_ → /、- → +），長度補到 4 的倍數
  payload=$(printf '%s' "$jwt" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#payload} % 4 )) != 0 ]; do
    payload="$payload="
  done

  printf '%s' "$payload" | base64 -d 2> /dev/null
}

# k_quota_lines [帳號]：每個有配額的帳號一行「帳號 項目=值 …」（項目照 OPMENU_QUOTA_KEYS 的順序，1.048576E7 這種寫法換成整數）
#   工具失敗時印出錯誤的前幾行、回傳非 0
#   輸入（kafka-configs --describe --entity-type users），例如：
#     Quota configs for user-principal 'app-orders-a' are producer_byte_rate=1048576.0, consumer_byte_rate=2097152.0
#   輸出，例如：
#     app-orders-a                 producer_byte_rate=1048576 consumer_byte_rate=2097152
k_quota_lines() {
  local arguments=(--describe --entity-type users)
  local output rc

  if [ -n "${1:-}" ]; then
    arguments+=(--entity-name "$1")
  fi

  output=$(be_kafka kafka-configs "${arguments[@]}")
  rc=$?

  if [ $rc -ne 0 ]; then
    printf '%s\n' "$output" | grep -m3 -iE 'exception|error'
    return $rc
  fi

  printf '%s\n' "$output" | awk -v keys="$OPMENU_QUOTA_KEYS" '
    /^Quota configs for/ {
      # 帳號在單引號裡；沒有的是「預設」配額
      who = "(預設)"
      if (match($0, /'"'"'[^'"'"']+'"'"'/)) who = substr($0, RSTART + 1, RLENGTH - 2)

      # " are " 後面是「項目=值, 項目=值」
      s = $0
      sub(/.* are /, "", s)
      n = split(s, kv, /, */)
      delete val
      for (i = 1; i <= n; i++) {
        split(kv[i], p, "=")
        val[p[1]] = sprintf("%.0f", p[2])
      }

      # 照 OPMENU_QUOTA_KEYS 的順序印
      line = sprintf("%-28s", who)
      m = split(keys, k, " ")
      for (i = 1; i <= m; i++) {
        if (k[i] in val) line = line " " k[i] "=" val[k[i]]
      }
      print line
    }
  ' | LC_ALL=C sort
}

# k_audit_fetch <分鐘> <輸出檔> [topic…]：讀稽核 topic（預設 OPMENU_AUDIT_TOPIC），只留下最近 N 分鐘的事件（用事件裡的時間），
#   多個 topic 依時間合併，一行一個事件（JSON）寫進輸出檔
#   每次用一個新的 consumer group（不 commit），不影響別人、也不會因為上次讀過就少讀
k_audit_fetch() {
  local minutes="$1"
  local out_file="$2"
  shift 2
  local since topic

  # 最早要留的時間（毫秒）
  since=$(( ($(date +%s) - minutes * 60) * 1000 ))

  for topic in "${@:-$OPMENU_AUDIT_TOPIC}"; do
    be_kafka kafka-console-consumer \
      --topic "$topic" \
      --from-beginning \
      --timeout-ms 15000 \
      --group "${OPMENU_AUDIT_GROUP_PREFIX}$OP_USER-$$-$RANDOM" \
      --consumer-property enable.auto.commit=false 2> /dev/null
  done | awk -v s="$since" '
    # 取出 "time":"2026-11-01T01:02:03.456Z"，換成毫秒；夠新的就在前面加上時間（排序用）
    {
      if (match($0, /"time":"[0-9T:.-]+Z?"/)) {
        t = substr($0, RSTART + 8, RLENGTH - 9)
        gsub(/[-:TZ]/, " ", t)
        split(t, a, " ")
        ts = mktime(a[1] " " a[2] " " a[3] " " a[4] " " a[5] " " int(a[6]), 1) * 1000
        if (ts >= s) print ts "\t" $0
      }
    }
  ' | sort -n -s -k1,1 | cut -f2- > "$out_file"

  return 0
}
