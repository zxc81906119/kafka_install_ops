# install/lib/ssh.sh —— 操作機（root）對各主機的連線：用 $SSH_KEY 那一把私鑰以 $SSH_USER（cpuser）登入；要 root 的動作在遠端用 sudo
#
# 需要先 source conf/site.env（用到 fqdn、SSH_USER、SSH_KEY）。主機一律傳短名（kb01），函式自己補成 FQDN。
#
#   ssh_run          <主機> <一行指令>                  在那台主機跑一行指令
#   ssh_run_as       <帳號> <主機> <一行指令>           用別的帳號登入（例如套件庫的 repodeploy；同一把金鑰）
#   ssh_script       <主機> [變數=值 …] <<'EOF' … EOF    把 heredoc 原樣送過去用 bash 跑；多行指令一律用這個
#   copy_to_tmp      <主機> <檔案…>                     檔案放到那台主機的 /tmp/（之後在遠端 sudo install 到定位、再刪）
#   restart_and_wait <主機> <服務> [健康檢查網址|-] [最多等幾秒]   重啟一台並等它健康
#   rolling_restart  <角色…>                          controllers／brokers／rests／c3 依序一台一台重啟

SSH_OPTIONS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR)

# ops_from_addrs：公鑰 authorized_keys 行的 from= 要列的來源位址（逗號分隔、不加空格）。
#   SSH_FROM_ADDRS 有設就照用；沒設 = 操作機的 IPv4 + 127.0.0.1 + ::1
#   （操作機連自己時 sshd 看到的來源可能是這三種之一；用 localhost 連線時 ssh 先走 IPv6，所以 ::1 一定要列）
ops_from_addrs() {
  local ops_ip
  if [ -n "${SSH_FROM_ADDRS:-}" ]; then echo "$SSH_FROM_ADDRS"; return; fi
  ops_ip=$(getent ahostsv4 "$(fqdn "$OPS_HOST")" | awk 'NR==1{print $1}')
  echo "$ops_ip,127.0.0.1,::1"
}
# authorized_keys_line：要放進每台 cpuser 的 authorized_keys 的整行（只有來源限制 from=，沒有 restrict、pty）
authorized_keys_line() { printf 'from="%s" %s\n' "$(ops_from_addrs)" "$(cat "$SSH_KEY.pub")"; }

ssh_run() {
  local host=$1; shift
  ssh "${SSH_OPTIONS[@]}" "$SSH_USER@$(fqdn "$host")" "$@"
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
  ssh "${SSH_OPTIONS[@]}" "$SSH_USER@$(fqdn "$host")" "env $env_args bash -s"
}

copy_to_tmp() {
  local host=$1; shift
  scp -q "${SSH_OPTIONS[@]}" "$@" "$SSH_USER@$(fqdn "$host"):/tmp/"
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

# lb_member <主機> down|up：請 LB 團隊停用／恢復這台 REST Proxy（手把手 12.1）。
#   LB_CONTROL=handshake：寫請求檔 $LB_REQUEST_DIR/<主機>.<down|up>，等 LB 團隊回覆 <請求>.done（有終端機時按 Enter 就算回覆）
#   LB_CONTROL=none：環境沒有 LB，只記一筆警告
lb_member() {
  local host=$1 action=$2 request waited answer verb
  case $action in down) verb=停用;; up) verb=恢復;; *) fail "lb_member：$action"; return 1;; esac
  if [ "${LB_CONTROL:-handshake}" = none ]; then warn "LB_CONTROL=none：沒有請 LB 團隊$verb $host"; return 0; fi
  install -d -m 0700 "$LB_REQUEST_DIR"
  request=$LB_REQUEST_DIR/$host.$action
  rm -f "$request.done"; : > "$request"
  if [ -t 0 ]; then
    ask_bank "LB 團隊：$verb REST Proxy $host（pool member $(fqdn "$host"):8082）"
    read -r -p "LB 團隊$verb完成後按 Enter：" answer; touch "$request.done"
  else
    log "等 LB 團隊$verb $host（請求 $request；做完後 touch $request.done）"
    for waited in $(seq 0 2 "${LB_WAIT_SECONDS:-1800}"); do [ -f "$request.done" ] && break; sleep 2; done
  fi
  if [ -f "$request.done" ]; then rm -f "$request" "$request.done"; ok "LB 團隊已$verb $host"; return 0; fi
  fail "$host：${LB_WAIT_SECONDS:-1800} 秒內 LB 團隊沒有回覆（$verb）"; return 1
}

# lb_drained <主機>：等那台 8082 上從負載平衡進來的連線歸零（最多 60 秒）；歸零了才可以重啟
lb_drained() {
  local host=$1 lb_ip connections waited
  lb_ip=$(getent hosts "$(fqdn "$LB_HOST")" | awk '{print $1}')
  for waited in $(seq 0 2 60); do
    connections=$(ssh_run "$host" "ss -Htn state established '( sport = :8082 )'" | grep -c " $lb_ip:")
    [ "$connections" = 0 ] && { ok "$host：LB 的連線已排空（等了 ${waited} 秒）"; return 0; }
    sleep 2
  done
  fail "$host：60 秒後 LB 還有 $connections 條連線進來（LB 團隊停用了嗎？）"; return 1
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
                   done
                   wait_mds_writer || failures=$((failures + 1));;   # 8090 回 200 之後，MDS 的寫入者還要重選一次
      rests)       HEALTH_CURL_OPTIONS=$(rest_app_curl_options)
                   for host in $RESTS; do   # 先請 LB 團隊停用、排空，才重啟；健康了再恢復（手把手 12.1）
                     lb_member "$host" down && lb_drained "$host" || { failures=$((failures + 1)); break; }
                     result=$(restart_and_wait "$host" confluent-kafka-rest "https://$(fqdn "$host"):8082/v3/clusters")
                     case $result in *after*) ok "$result";; *) fail "$result"; failures=$((failures + 1)); break;; esac
                     lb_member "$host" up || { failures=$((failures + 1)); break; }
                   done
                   HEALTH_CURL_OPTIONS="";;
      c3)          result=$(restart_and_wait "$C3_HOST" confluent-control-center "https://$C3_FQDN:9021/" 420)   # C3 第一次起來最慢
                   case $result in *after*) ok "$result";; *) fail "$result"; failures=$((failures + 1));; esac;;
    esac
  done
  [ "$failures" = 0 ]
}
