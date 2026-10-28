# kafka.sh — 以操作者身分跑 Kafka 工具、呼叫 MDS、換 token;91 用操作機上的緊急憑證檔。加上各項目共用的 Kafka / MDS 小工具。
# 假設操作機已安裝 Confluent 的指令工具與 curl。這裡不放任何環境值:全部讀 OPMENU_* 變數。
# 安全:帳密與 token 經 stdin 交給 curl(-K -),不進命令列;連線設定檔放記憶體檔案系統、離開時刪。

be_name() { echo vm; }
be_truststore_path() { echo "$OPMENU_TRUSTSTORE"; }
be_truststore_password() { cat "$OPMENU_TRUSTSTORE_PASSWORD_FILE"; }

_curl_q() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }   # curl 設定檔的值:跳脫 \ 與 "
_mds_curl() { # _mds_curl <path> <curl 設定檔內容(多行)> [curl 參數...];MDS 可填多台(逗號分隔),逐台嘗試;401/403 算連得上,不換台
  local p="$1" cfg="$2"; shift 2; local u out
  for u in ${OPMENU_MDS_URL//,/ }; do
    out=$(printf '%s\n' "$cfg" | curl -s --max-time 10 --cacert "$OPMENU_CA_PEM" -K - "$@" "$u$p") && { printf '%s' "$out"; return 0; }
  done
  echo "MDS 全部連不上:$OPMENU_MDS_URL" >&2; return 1
}
be_mds_login() { local out t; out=$(_mds_curl /security/1.0/authenticate "user = \"$(_curl_q "$1:$2")\"" -H "Accept: application/json") || return 2; t=$(printf '%s' "$out" | grep -o '"auth_token":"[^"]*"' | cut -d'"' -f4); [ -n "$t" ] && echo "$t"; }   # 回傳 2 = MDS 連不上
be_mds() { local m="$1" p="$2" b="${3:-}"; local a=(-X "$m" -H "Content-Type: application/json" -w $'\nHTTP %{http_code}'); [ -n "$b" ] && a+=(-d "$b"); _mds_curl "$p" "header = \"Authorization: Bearer $(_curl_q "$OP_TOKEN")\"" "${a[@]}" | tee -a "$OP_LAST_RAW"; }
be_cluster_id() { _mds_curl /v1/metadata/id "" | grep -o "\"id\":\"[^\"]*\"" | head -1 | cut -d"\"" -f4; }
be_http() { curl -s --max-time 10 --cacert "$OPMENU_CA_PEM" "$@"; }

be_kafka() { # 操作機本機的指令工具,以操作者本人的 AD 身分(LDAP listener)
  local tool="$1"; shift; local out rc
  out=$(KAFKA_HEAP_OPTS="-Xmx256m" "$tool" --bootstrap-server "$OPMENU_BOOTSTRAP" --command-config "$OP_CLIENT_CONF" "$@" 2>&1); rc=$?
  printf '%s\n' "$out" >> "$OP_LAST_RAW"
  printf '%s\n' "$out" | grep -v "^SLF4J\|^WARNING\|is deprecated"
  return $rc
}

# 91 緊急模式:client 憑證(PEM:私鑰 + 憑證鏈)從操作機上 0600 的檔案(OPMENU_BREAKGLASS_PEM)讀進記憶體檔案系統,組成「憑證向 MDS 換 token」的連線設定,用完即刪。
# 憑證身分(例 User:opmenu-breakglass)在 MDS 綁 SystemAdmin;broker 端不需要任何改動。
be_bootstrap_kafka() {
  local tool="$1"; shift
  [ -n "${OPMENU_BREAKGLASS_PEM:-}" ] || { echo "沒有設定 OPMENU_BREAKGLASS_PEM(緊急模式憑證 PEM 的檔案路徑)" >&2; return 1; }
  local pem conf out rc mds
  pem="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"; conf="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"
  secret_get "$OPMENU_BREAKGLASS_PEM" > "$pem" || { rm -f "$pem" "$conf"; return 1; }
  grep -q 'BEGIN .*PRIVATE KEY' "$pem" && grep -q 'BEGIN CERTIFICATE' "$pem" || { echo "緊急憑證檔不是 PEM 私鑰 + 憑證" >&2; rm -f "$pem" "$conf"; return 1; }
  mds="${OPMENU_MDS_URL%%,*}"
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
  out=$(KAFKA_HEAP_OPTS="-Xmx256m" "$tool" --bootstrap-server "$OPMENU_BREAKGLASS_BOOTSTRAP" --command-config "$conf" "$@" 2>&1); rc=$?
  rm -f "$pem" "$conf"
  printf '%s\n' "$out" >> "$OP_LAST_RAW"
  printf '%s\n' "$out" | grep -v "^SLF4J\|^WARNING\|is deprecated"
  return $rc
}

# ── 各項目共用的小工具 ──
k_scope() { printf '{"clusters":{"kafka-cluster":"%s"}}' "$OPMENU_KAFKA_CLUSTER_ID"; }
k_bind_body() { printf '{"scope":%s,"resourcePatterns":[{"resourceType":"%s","name":"%s","patternType":"%s"}]}' "$(k_scope)" "$1" "$2" "$3"; }
k_http_ok() { tail -1 | grep -q -E "HTTP 2[0-9][0-9]"; }
k_show_mds() { local out; out="$(be_mds "$@")"; printf '%s\n' "$out" | sed '$d'; printf '%s\n' "$out" | k_http_ok; }   # 印回應(去掉 HTTP 狀態列);非 2xx 回傳 1
k_roles_of() { k_show_mds POST "/security/1.0/lookup/principals/$1/roleNames" "$(k_scope)"; }
k_gen_pw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }
# 停用帳號 = 把 SCRAM 憑證覆寫成隨機密碼,不用 --delete-config:實測刪除 SCRAM 憑證後,下一次重啟 broker 會失敗。帳號本來就沒有憑證時不動作。
k_disable_scram() { local a="$1"; be_kafka kafka-configs --describe --entity-type users --entity-name "$a" 2>/dev/null | grep -q "SCRAM-SHA-512=" || { echo "帳號 $a 沒有 SCRAM 憑證,略過"; return 0; }; be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$(k_gen_pw)]" --entity-type users --entity-name "$a"; }
k_unbind_user() { be_mds DELETE "/security/1.0/principals/User:$1/roles/$2/bindings" "$(k_bind_body "$3" "$4" PREFIXED)" >/dev/null 2>&1; }
k_cluster_counts() { # 印 "<under-replicated> <offline> <在線 broker 數>";工具失敗的欄位印 999(視為不健康)
  local o rc urp off live
  o=$(be_kafka kafka-topics --describe --under-replicated-partitions 2>/dev/null); rc=$?
  if [ $rc -eq 0 ]; then urp=$(printf '%s\n' "$o" | grep -c "Partition:"); else urp=999; fi
  o=$(be_kafka kafka-topics --describe --unavailable-partitions 2>/dev/null); rc=$?
  if [ $rc -eq 0 ]; then off=$(printf '%s\n' "$o" | grep -c "Partition:"); else off=999; fi
  o=$(be_kafka kafka-broker-api-versions 2>/dev/null); rc=$?
  if [ $rc -eq 0 ]; then live=$(printf '%s\n' "$o" | grep -c '^[A-Za-z0-9._-]*:[0-9]* (id: '); else live=0; fi
  echo "$urp $off $live"
}
k_audit_fetch() { # k_audit_fetch <分鐘> <輸出檔>:讀 audit topic,用事件時間留下最近 N 分鐘的事件
  local mins="$1" f="$2" since; since=$(( ($(date +%s) - mins*60) * 1000 ))
  be_kafka kafka-console-consumer --topic "$OPMENU_AUDIT_TOPIC" --from-beginning --timeout-ms 15000 --group "${OPMENU_AUDIT_GROUP_PREFIX}$OP_USER-$$-$RANDOM" --consumer-property enable.auto.commit=false 2>/dev/null \
    | awk -v s="$since" '{ if (match($0, /"time":"[0-9T:.-]+Z?"/)) { t=substr($0, RSTART+8, RLENGTH-9); gsub(/[-:TZ]/, " ", t); split(t, a, " "); ts=mktime(a[1]" "a[2]" "a[3]" "a[4]" "a[5]" "int(a[6]), 1)*1000; if (ts >= s) print } }' > "$f" || true
}
