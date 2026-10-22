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
