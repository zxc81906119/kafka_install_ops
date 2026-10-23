# install/lib/ssh.sh —— 操作機對各主機的連線（cpadmin 金鑰登入；要 root 的動作在遠端用 sudo）
#
# 需要先 source conf/site.env（用到 fqdn）。主機一律傳短名（kb01），函式自己補成 FQDN。
#
#   ssh_run          <主機> <一行指令>                  在那台主機跑一行指令
#   ssh_run_as       <帳號> <主機> <一行指令>           用別的帳號登入（例如套件庫的 repodeploy）
#   ssh_script       <主機> [變數=值 …] <<'EOF' … EOF    把 heredoc 原樣送過去用 bash 跑；多行指令一律用這個
#   copy_to_tmp      <主機> <檔案…>                     檔案放到那台主機的 /tmp/（之後在遠端 sudo install 到定位、再刪）
#   restart_and_wait <主機> <服務> [健康檢查網址|-] [最多等幾秒]   重啟一台並等它健康
#   rolling_restart  <角色…>                          controllers／brokers／rests／c3 依序一台一台重啟

SSH_OPTIONS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR)

ssh_run() {
  local host=$1; shift
  ssh "${SSH_OPTIONS[@]}" "$(fqdn "$host")" "$@"
}

ssh_run_as() {
  local user=$1 host=$2; shift 2
  ssh "${SSH_OPTIONS[@]}" "$user@$(fqdn "$host")" "$@"
}

# ssh_script 用法：
#
#   result=$(ssh_script kb01 PROPS_FILE=/etc/confluent/kafka/server.properties <<'EOF'
#   echo "lines=$(sudo grep -c . "$PROPS_FILE")"
#   EOF
#   )
#
# - heredoc 寫成 <<'EOF'（有引號）：裡面的 $、引號、$(…) 都在「那台主機上」展開，和在那台手打一樣，不用跳脫。
# - 要帶本機的值，就寫成「變數=值」參數，遠端用 $變數 取用。
# - 參數會出現在遠端的程序清單裡：只傳路徑、主機名這類；密碼不要這樣傳（先 copy_to_tmp 成檔、或在遠端從保管庫取）。
ssh_script() {
  local host=$1; shift
  local env_args=""
  [ $# -gt 0 ] && env_args=$(printf '%q ' "$@")
  ssh "${SSH_OPTIONS[@]}" "$(fqdn "$host")" "env $env_args bash -s"
}

copy_to_tmp() {
  local host=$1; shift
  scp -q "${SSH_OPTIONS[@]}" "$@" "$(fqdn "$host"):/tmp/"
}

# restart_and_wait 的健康檢查（第三個參數）：
#   -               只等 systemd 顯示 active（controller 用）
#   https://…       等它回 HTTP 200（broker 的 MDS、REST Proxy、C3 用）
#   REST Proxy 要帶 client 憑證：呼叫前 export HEALTH_CURL_OPTIONS="--cert … --key …"
# 成功印「<主機> <服務> … after ~N秒」並回 0；逾時印原因並回 1。
restart_and_wait() {
  local host=$1 unit=$2 health_url=${3:--} max_seconds=${4:-300}
  local round http_code
  ssh_run "$host" "sudo systemctl restart $unit" || { echo "$host: restart $unit 失敗"; return 1; }
  for round in $(seq 1 $((max_seconds / 5))); do
    if [ "$health_url" = - ]; then
      if ssh_run "$host" "systemctl is-active -q $unit"; then echo "$host $unit active after ~$((round * 5))s"; return 0; fi
    else
      http_code=$(curl -sk ${HEALTH_CURL_OPTIONS:-} -o /dev/null -m 5 -w '%{http_code}' "$health_url")
      if [ "$http_code" = 200 ]; then echo "$host $unit 200 after ~$((round * 5))s"; return 0; fi
    fi
    sleep 5
  done
  echo "$host $unit 沒有在 ${max_seconds}s 內健康（看日誌：sudo journalctl -u $unit -n 50）"
  return 1
}

# rolling_restart <角色…>：依序滾動重啟，角色可以是 controllers brokers rests c3（照給的順序）。
# 一台起來、健康了才做下一台；每台結果用 ok／fail 記下（需要 lib/log.sh）。全部健康回 0。
rolling_restart() {
  local role host result failures=0
  export HEALTH_CURL_OPTIONS
  for role in "$@"; do
    case $role in
      controllers) for host in $CONTROLLERS; do
                     result=$(restart_and_wait "$host" confluent-server -)
                     case $result in *after*) ok "$result";; *) fail "$result"; failures=$((failures + 1));; esac
                   done;;
      brokers)     for host in $BROKERS; do
                     result=$(restart_and_wait "$host" confluent-server "https://$(fqdn "$host"):8090/v1/metadata/id")
                     case $result in *after*) ok "$result";; *) fail "$result"; failures=$((failures + 1));; esac
                   done;;
      rests)       HEALTH_CURL_OPTIONS=$(rest_app_curl_options)
                   for host in $RESTS; do
                     result=$(restart_and_wait "$host" confluent-kafka-rest "https://$(fqdn "$host"):8082/v3/clusters")
                     case $result in *after*) ok "$result";; *) fail "$result"; failures=$((failures + 1));; esac
                   done
                   HEALTH_CURL_OPTIONS="";;
      c3)          result=$(restart_and_wait "$C3_HOST" confluent-control-center "https://$C3_FQDN:9021/" 420)   # C3 第一次起來最慢
                   case $result in *after*) ok "$result";; *) fail "$result"; failures=$((failures + 1));; esac;;
    esac
  done
  [ "$failures" = 0 ]
}
