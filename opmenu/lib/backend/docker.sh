# backend/docker.sh — docker compose 的測試環境
# 實作 core.sh 要求的 be_* 介面;Kafka 工具用 cp-server 映像在同一個網路裡執行。
# 這裡不放任何環境值:全部讀 opmenu.conf / lib/defaults.sh 的 OPMENU_* 變數。
export MSYS_NO_PATHCONV=1
_hostpath() { ( cd "$1" && { pwd -W 2>/dev/null || pwd; } ); }   # Windows 的 Git Bash 要給 docker 原生路徑
OPMENU_CERTS_HOST_DIR="${OPMENU_CERTS_HOST_DIR:-$(_hostpath "$OPMENU_HOME/../certs")}"              # 掛進容器當 /etc/kafka/secrets
OPMENU_CLIENTS_HOST_DIR="${OPMENU_CLIENTS_HOST_DIR:-$(_hostpath "$OPMENU_HOME/../config/clients")}"  # 放 bootstrap 的連線設定
OPMENU_LOG_HOST_DIR="$(mkdir -p "$OPMENU_HOME/log" && _hostpath "$OPMENU_HOME/log")"

be_name() { echo docker; }
be_truststore_path() { echo "$OPMENU_TRUSTSTORE"; }
be_truststore_password() { cat "$OPMENU_CERTS_HOST_DIR/$(basename "$OPMENU_TRUSTSTORE_PASSWORD_FILE")"; }

docker() { command docker "$@" </dev/null; }   # 所有 docker 指令的 stdin 接 /dev/null:Windows 的 docker 會動到終端機輸入,讓互動選單誤以為讀到 EOF 而登出
_curl() { command docker run --rm -i --network "$OPMENU_DOCKER_NETWORK" -v "$OPMENU_CERTS_HOST_DIR:/etc/kafka/secrets:ro" --entrypoint curl "$OPMENU_DOCKER_CURL_IMAGE" -s --max-time 10 --cacert "$OPMENU_CA_PEM" "$@"; }   # 這裡要 -i:curl 設定從 stdin 讀
# curl 的帳密與 Authorization 標頭用 -K - 從 stdin 讀,不出現在行程清單;值裡的 \ 與 " 先跳脫
_curl_q() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }   # curl 設定檔的值:跳脫 \ 與 "(bash 內建替換,不依賴 sed)
# MDS 可填多台(逗號分隔):逐台嘗試,連得上的那台就用(HTTP 401/403 算連得上,不會換台)
_mds_curl() { # _mds_curl <path> <curl 設定檔內容> [curl 參數...]
  local p="$1" cfg="$2"; shift 2; local u out
  for u in ${OPMENU_MDS_URL//,/ }; do out=$(printf '%s\n' "$cfg" | _curl -K - "$@" "$u$p") && { printf '%s' "$out"; return 0; }; done
  echo "MDS 全部連不上:$OPMENU_MDS_URL" >&2; return 1
}

# AD 帳密 → MDS token(密碼只用這一次)
be_mds_login() { local out t; out=$(_mds_curl /security/1.0/authenticate "user = \"$(_curl_q "$1:$2")\"" -H "Accept: application/json") || return 2; t=$(printf '%s' "$out" | grep -o '"auth_token":"[^"]*"' | cut -d'"' -f4); [ -n "$t" ] && echo "$t"; }   # 回傳 2 = MDS 連不上

# 以操作者的 token 呼叫 MDS;最後一行印 "HTTP <code>"
be_mds() { local m="$1" p="$2" b="${3:-}"; local a=(-X "$m" -H "Content-Type: application/json" -w $'\nHTTP %{http_code}'); [ -n "$b" ] && a+=(-d "$b"); _mds_curl "$p" "header = \"Authorization: Bearer $(_curl_q "$OP_TOKEN")\"" "${a[@]}" | tee -a "$OP_LAST_RAW"; }
be_bootstrap_mds() { local m="$1" p="$2" b="${3:-}"; local a=(-X "$m" --cert /etc/kafka/secrets/client-bootstrap.pem --key /etc/kafka/secrets/client-bootstrap.key -H "Content-Type: application/json" -w $'\nHTTP %{http_code}'); [ -n "$b" ] && a+=(-d "$b"); _mds_curl "$p" "" "${a[@]}" | tee -a "$OP_LAST_RAW"; }

_kafka_with_conf() { # _kafka_with_conf <主機上的設定檔路徑> <工具> <參數...>
  local conf="$1" tool="$2"; shift 2
  local conf_dir conf_name; conf_dir="$(_hostpath "$(dirname "$conf")")"; conf_name="$(basename "$conf")"
  local out rc
  out=$(docker run --rm --network "$OPMENU_DOCKER_NETWORK" \
    -v "$OPMENU_CERTS_HOST_DIR:/etc/kafka/secrets:ro" -v "$conf_dir/$conf_name:/op/client.properties:ro" -v "$OPMENU_LOG_HOST_DIR:/op/log" \
    -e KAFKA_OPTS="" -e KAFKA_HEAP_OPTS="-Xmx256m" --entrypoint "$tool" "$OPMENU_DOCKER_IMAGE" \
    --bootstrap-server "$OPMENU_BOOTSTRAP" --command-config /op/client.properties "$@" 2>&1); rc=$?
  printf '%s\n' "$out" >> "$OP_LAST_RAW"          # 原始輸出留給 core 判斷「被拒」或「登入失敗」
  printf '%s\n' "$out" | grep -v "^SLF4J\|^WARNING\|is deprecated"
  return $rc
}
be_kafka() { _kafka_with_conf "$OP_CLIENT_CONF" "$@"; }
# 緊急模式:bootstrap 的連線設定由後端保管(正式環境:只有專用帳號讀得到,經 sudo 使用)
be_bootstrap_kafka() { _kafka_with_conf "$OPMENU_CLIENTS_HOST_DIR/token-bootstrap.properties" "$@"; }

# 容器名稱也要在設定清單內(不信任呼叫端)
be_service_restart() { v_any_svc "$1" >/dev/null || return 1; docker restart "$1" >/dev/null || return 1
  case "$1" in broker*) bash "$OPMENU_HOME/../scripts/broker-heal.sh" "$1" >/dev/null 2>&1 || true;; esac   # demo 專用的最後手段:broker 重啟起不來(已知原因:刪除過 SCRAM 憑證,見 RUNBOOK 第 19 章)就清空它的資料目錄重建;正式環境(vm.sh)沒有這個行為
  echo "已重啟 $1"; }
be_service_logs() { v_any_svc "$1" >/dev/null || return 1; v_number "${2:-50}" >/dev/null || return 1; docker logs --tail "${2:-50}" "$1" 2>&1; }
be_clean_logs() { v_host "$1" >/dev/null || return 1; v_number "$2" >/dev/null || return 1; echo "容器環境的日誌由 docker 管理,沒有可清理的日誌檔(正式環境:刪除 $1 上超過 $2 天的日誌檔)"; }
be_disk_usage() { for c in $OPMENU_HOSTS; do printf '%-16s ' "$c"; docker exec "$c" sh -c "du -sh $OPMENU_DATA_DIR 2>/dev/null | cut -f1; df -h $OPMENU_DATA_DIR 2>/dev/null | tail -1 | awk '{print \"  磁碟用量 \" \$5 \"  剩餘 \" \$4}'" 2>/dev/null | tr '\n' ' '; echo; done; }
be_cert_list() {
  docker run --rm -v "$OPMENU_CERTS_HOST_DIR:/certs:ro" --entrypoint sh "$OPMENU_DOCKER_OPENSSL_IMAGE" -c '
    for f in /certs/*.pem; do [ -f "$f" ] || continue; openssl x509 -in "$f" -noout >/dev/null 2>&1 || continue
      if ! openssl x509 -in "$f" -noout -checkend 0 >/dev/null; then st="已過期"; elif ! openssl x509 -in "$f" -noout -checkend 604800 >/dev/null; then st="剩不到 7 天 ⚠⚠"; elif ! openssl x509 -in "$f" -noout -checkend 2592000 >/dev/null; then st="剩不到 30 天 ⚠"; elif ! openssl x509 -in "$f" -noout -checkend 7776000 >/dev/null; then st="剩不到 90 天"; else st="90 天以上"; fi
      printf "%-32s %-26s %s\n" "$(basename $f)" "$(openssl x509 -in $f -noout -enddate | cut -d= -f2)" "$st"; done'
}
be_hosts() { echo "$OPMENU_HOSTS"; }
be_collect_diag() { local d="$1"; mkdir -p "$d"; for c in $OPMENU_HOSTS; do docker logs --tail 500 "$c" > "$d/$c.log" 2>&1; done; docker ps --format '{{.Names}} {{.Status}}' > "$d/containers.txt"; }

# 推算用:cluster ID(MDS 不需帳密)與 broker 主機對應的服務名
be_cluster_id() { _mds_curl /v1/metadata/id "" | grep -o "\"id\":\"[^\"]*\"" | head -1 | cut -d"\"" -f4; }

# 一般 HTTP 呼叫(Alertmanager、探測 MDS 狀態);參數同 curl
be_http() { _curl "$@"; }
# Alertmanager 呼叫:設了 OPMENU_ALERTMANAGER_AUTH_FILE 就帶 Basic 帳密(帳密用 -K - 從 stdin 給 curl,不出現在行程清單)
_am_auth() { if [ -n "${OPMENU_ALERTMANAGER_AUTH_CMD:-}" ]; then bash -c "$OPMENU_ALERTMANAGER_AUTH_CMD"; elif [ -n "${OPMENU_ALERTMANAGER_AUTH_FILE:-}" ]; then cat "$OPMENU_ALERTMANAGER_AUTH_FILE"; fi; }   # 帳密來源:指令(例如向 CyberArk 取)優先,其次檔案
be_am() { local a; a=$(_am_auth); if [ -n "$a" ]; then printf 'user = "%s"\n' "$(_curl_q "$a")" | _curl -K - "$@"; else _curl "$@"; fi; }
