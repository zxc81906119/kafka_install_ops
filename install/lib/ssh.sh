# install/lib/ssh.sh — 操作機對各主機的 ssh / scp（cpadmin 金鑰登入，sudo 在遠端那一側）
# 需要先 source conf/site.env（用到 DOMAIN、fqdn）。

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR)

# rsh <主機短名> <指令…>        在一台主機執行；指令可以是多行字串
rsh() { local h=$1; shift; ssh "${SSH_OPTS[@]}" "$(fqdn "$h")" "$@"; }

# rsh_as <帳號> <主機短名> <指令…>  用別的帳號（例如 repodeploy）
rsh_as() { local u=$1 h=$2; shift 2; ssh "${SSH_OPTS[@]}" "$u@$(fqdn "$h")" "$@"; }

# rcp <主機短名> <檔案…>          把檔案放到該主機的 /tmp/（之後遠端用 sudo install 搬到定位、再 rm）
rcp() { local h=$1; shift; scp -q "${SSH_OPTS[@]}" "$@" "$(fqdn "$h"):/tmp/"; }

# each "<主機清單>" <指令…>       同一條指令跑每台，輸出前面加主機名
each() { local hosts=$1 h; shift; for h in $hosts; do rsh "$h" "$@" 2>&1 | sed "s/^/$h: /"; done; }

# 給遠端 shell 用的時間戳與主機前綴，常見寫法：rsh $h "echo \"\$(hostname): …\""

# restart_wait <主機> <unit> [健康檢查 URL|-] [逾時秒]   重啟一台並等它健康（滾動重啟一次呼叫一台）
#   URL 給 - 時只等 systemd active；給 https://… 時等它回 200（MDS、REST、C3 都用這個）
#   REST 的 URL 需要 client 憑證：先 export RW_CURL_OPTS='--cert … --key …'
restart_wait() {
  local h=$1 u=$2 url=${3:--} max=${4:-300} i code
  rsh "$h" "sudo systemctl restart $u" || { echo "$h: restart $u 失敗"; return 1; }
  for i in $(seq 1 $((max / 5))); do
    if [ "$url" = - ]; then rsh "$h" "systemctl is-active -q $u" && { echo "$h $u active after ~$((i * 5))s"; return 0; }
    else code=$(curl -sk ${RW_CURL_OPTS:-} -o /dev/null -m 5 -w '%{http_code}' "$url"); [ "$code" = 200 ] && { echo "$h $u 200 after ~$((i * 5))s"; return 0; }; fi
    sleep 5
  done
  echo "$h $u 沒有在 ${max}s 內健康（sudo journalctl -u $u -n 50）"; return 1
}
