#!/usr/bin/env bash
# install/lab/run-customer.sh —— lab：用「客戶模式」從零實跑到第 19 站（Windows Git Bash）
#
#   bash run-customer.sh                  從零（bank-sim reset），裝 site.env 的 CP_VERSION；驗收後接著跑 20、22–26 站，最後再驗收一次
#   CP_VERSION=8.2.4 bash run-customer.sh 指定版本（升級演練：先裝 8.2.4）
#   FROM=6 bash run-customer.sh           從第 6 段接著跑（段號在每段的 ######## 標題裡）；接著跑時 CP_VERSION 要和第一次一樣
#   TO=17 bash run-customer.sh            跑到第 17 段（第一次驗收）就停
#
# 客戶的 CyberArk 只有 PAM，程式碰不到 PVWA，所以 site.env 換成（install/README「lab 與客戶環境的設定差異」）：
#   SSH_KEY_SOURCE=agent
# 這幾項只改送進 lab 的那份（ops02、dl01），repo 裡的 site.env 不動。
#
# 正式環境由人做的事，這支扮演：
#   CyberArk     產生 cpadmin 金鑰對（bank-sim pvwa-key），PVWA 在 $LAB/pvwa/
#   工程師        把 cpadmin 私鑰從 PVWA 貼進操作機的 ssh-agent（不落地）；冷開機後要重貼
#   Secrets 團隊  產生 passphrase 放進 PVWA；把第 15 站產生的 master key 存進 PVWA
#   工程師        從 PVWA 取 passphrase 放進 ~/secrets/sp-passphrase.txt；master key 存好後記下「雜湊 單號」
set -uo pipefail
export MSYS_NO_PATHCONV=1
LAB_TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
BANK="bash $LAB_TOOLS_DIR/bank-sim.sh"
LAB=${LAB:-$HOME/kafka-lab}
PVWA_DIR=$LAB/pvwa
OPS_CONTAINER=lab-ops02-1
AGENT_SOCKET=/home/cpadmin/.ssh/engineer-agent.sock   # 工程師這次作業的 ssh-agent（容器重開就沒了）
started_at=$(date +%s)
# 扮演 LB 團隊（手把手 12.1）：腳本重啟 REST 前會寫 ~/lb-requests/ 的請求，bank-sim lb-watch 照做後回覆
LB_TEAM_STOP="${LAB:-$HOME/kafka-lab}/lb-watch.stop.$$"   # 每支 runner 自己的結束訊號（升級演練裡面還會再叫 run-customer.sh）
bash "$LAB_TOOLS_DIR/bank-sim.sh" lb-watch "$LB_TEAM_STOP" >> "${LAB:-$HOME/kafka-lab}/lb-watch.log" 2>&1 &
LB_TEAM_PID=$!
trap 'touch "$LB_TEAM_STOP"; kill $LB_TEAM_PID 2>/dev/null' EXIT

# stage <段號> <標題>：段號小於 FROM 或大於 TO 就略過這一段（回 1），否則印標題（回 0）
stage() {
  local number=$1; shift
  [ "$number" -ge "${FROM:-1}" ] || return 1
  [ "$number" -le "${TO:-99}" ] || return 1
  printf '\n######## %s %s (+%ss) ########\n' "$number" "$*" "$(( $(date +%s) - started_at ))"
}
# 在操作機以 cpadmin 跑 install.sh；帶上工程師 ssh-agent 的位置
install_on_ops() { docker exec -u cpadmin -w /home/cpadmin -e SSH_AUTH_SOCK="$AGENT_SOCKET" "$OPS_CONTAINER" bash install/install.sh "$@" </dev/null; }
# 隨時執行的站（20 以後）：直接跑那一支
step_on_ops() { local script=$1; shift; docker exec -u cpadmin -w /home/cpadmin -e SSH_AUTH_SOCK="$AGENT_SOCKET" "$OPS_CONTAINER" bash "install/steps/$script" "$@" </dev/null; }
# expect_wait_for_bank <rc> <站> [前置站]：install.sh 應該停在「第 <站> 站等銀行」（rc 2）。
# 給了前置站就再確認它已經做完（略過的站不會留完成標記，所以由呼叫的地方指定），不然可能是更早的站在等銀行
expect_wait_for_bank() {
  local exit_code=$1 step=$2 prerequisite_step=${3:-}
  if [ "$exit_code" != 2 ]; then echo "預期 $step 停在等銀行（rc 2），實際 rc=$exit_code"; exit 1; fi
  if [ -n "$prerequisite_step" ] && ! docker exec -u cpadmin "$OPS_CONTAINER" bash -c "ls ~/install-logs/$prerequisite_step-*.done" >/dev/null 2>&1; then
    echo "停在等銀行，但第 $prerequisite_step 站還沒做完：停的不是第 $step 站"; exit 1
  fi
}

# 把送進 lab 的 site.env 換成客戶模式（ops02 與 dl01 兩份）
apply_customer_settings() {
  local settings="s/^SSH_KEY_SOURCE=.*/SSH_KEY_SOURCE=agent/;"
  [ -n "${CP_VERSION:-}" ] && settings+=" s/^CP_VERSION=[0-9.]*/CP_VERSION=$CP_VERSION/;"
  docker exec "$OPS_CONTAINER" sed -i "$settings" /home/cpadmin/install/conf/site.env
  docker exec dl01 sed -i "$settings" /root/install/conf/site.env
  docker exec "$OPS_CONTAINER" grep -E '^(SSH_KEY_SOURCE|CP_VERSION)=' /home/cpadmin/install/conf/site.env | cut -d' ' -f1
}

# 工程師：開這次作業的 ssh-agent，把 PVWA 取出的私鑰貼進去（ssh-add -，從 stdin，不寫檔）
engineer_loads_key() {
  # 客戶模式沒有自己產生金鑰，~/.ssh 可能還不存在
  docker exec -u cpadmin "$OPS_CONTAINER" bash -c "install -d -m 0700 ~/.ssh; rm -f $AGENT_SOCKET; ssh-agent -a $AGENT_SOCKET >/dev/null"
  docker exec -i -u cpadmin -e SSH_AUTH_SOCK="$AGENT_SOCKET" "$OPS_CONTAINER" ssh-add - < "$PVWA_DIR/cpadmin_ed25519"
  docker exec -u cpadmin -e SSH_AUTH_SOCK="$AGENT_SOCKET" "$OPS_CONTAINER" ssh-add -l
}

# Secrets 團隊放 passphrase 進 PVWA；工程師取出放進操作機（0600）
passphrase_from_pvwa() {
  mkdir -p "$PVWA_DIR"
  [ -s "$PVWA_DIR/sp-passphrase.txt" ] || (umask 077; openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > "$PVWA_DIR/sp-passphrase.txt")
  docker exec -i -u cpadmin "$OPS_CONTAINER" bash -c 'umask 077; cat > ~/secrets/sp-passphrase.txt; wc -c < ~/secrets/sp-passphrase.txt' < "$PVWA_DIR/sp-passphrase.txt"
}

# Secrets 團隊把 master key 存進 PVWA；工程師記下「雜湊 單號」
master_key_into_pvwa() {
  docker exec -u cpadmin "$OPS_CONTAINER" cat /home/cpadmin/secrets/master.key > "$PVWA_DIR/master-key.txt"; chmod 600 "$PVWA_DIR/master-key.txt"
  docker exec -u cpadmin "$OPS_CONTAINER" bash -c 'umask 077; echo "$(tr -d "\n" < ~/secrets/master.key | sha256sum | cut -c1-12) CHG-LAB-0001" > ~/secrets/master-key.custody; cat ~/secrets/master-key.custody'
}

stage 1 "reset" && { $BANK reset; }
stage 2 "push install/、換成客戶模式" && { $BANK push && apply_customer_settings; }
# 接著跑時（FROM>2）lab 裡那份 site.env 可能被 push 蓋回 lab 模式：每次都再套一次客戶設定
[ "${FROM:-1}" -gt 2 ] && apply_customer_settings
stage 3 "01 download（dl01）" && { docker exec dl01 bash /root/install/steps/01-download.sh </dev/null || exit 1; }
stage 4 "銀行：檔案交換" && { $BANK intake; }
stage 5 "02–03（ssh-agent 還是空的，03 應停下）" && { install_on_ops --to 03; expect_wait_for_bank $? 03; }
stage 6 "CyberArk 產生 cpadmin 金鑰、工程師貼進 ssh-agent" && { $BANK pvwa-key && engineer_loads_key || exit 1; }
stage 7 "銀行：公鑰（CyberArk 那把）、套件庫、根憑證、AD、NTP、LB" && { $BANK prepare; }
stage 8 "03–09" && { install_on_ops --from 03 --to 09; expect_wait_for_bank $? 09 08; }
stage 9 "銀行：CA 簽發" && { $BANK sign; }
stage 10 "09–14" && { install_on_ops --from 09 --to 14 || exit 1; }
stage 11 "Secrets 團隊：passphrase 放進 PVWA；工程師取出放進操作機" && { passphrase_from_pvwa; }
stage 12 "15（產生 master key 後應停下等保管）" && { install_on_ops --from 15 --to 15; expect_wait_for_bank $? 15 14; }
stage 13 "Secrets 團隊：master key 存進 PVWA；工程師記單號" && { master_key_into_pvwa; }
stage 14 "15–18" && { install_on_ops --from 15 --to 18 || exit 1; }
stage 15 "銀行：行內 Prometheus 接上（17.5）" && { $BANK prometheus; }
stage 16 "機房：冷開機（19.4）；工程師重新貼私鑰" && { $BANK coldboot && engineer_loads_key || exit 1; }
stage 17 "19 驗收" && { install_on_ops --from 19 || exit 1; }
stage 18 "20 憑證：status、leaf 換發（第一次停在等銀行簽）" && {
  step_on_ops 20-cert-rotate.sh status || exit 1
  step_on_ops 20-cert-rotate.sh leaf; [ $? = 2 ] || { echo "20 leaf 第一次應停在等銀行（rc 2）"; exit 1; }
  $BANK sign-next && step_on_ops 20-cert-rotate.sh leaf || exit 1
}
stage 19 "22 license：status、schedule" && {
  step_on_ops 22-license.sh status; rc=$?; [ $rc = 0 ] || [ $rc = 2 ] || exit 1   # 試用版不到 90 天是 rc 2
  step_on_ops 22-license.sh schedule || exit 1
}
stage 20 "25 日常備份：grant、run、schedule、compare" && {
  step_on_ops 25-metadata-backup.sh grant && step_on_ops 25-metadata-backup.sh run || exit 1
  sleep 61; step_on_ops 25-metadata-backup.sh schedule && step_on_ops 25-metadata-backup.sh compare || exit 1
}
stage 21 "23 換 controller（kc03 清空重建）" && { step_on_ops 23-controller-replace.sh replace kc03 || exit 1; }
stage 22 "24 broker 縮減與擴充（kb04）" && { step_on_ops 24-broker-scale.sh remove kb04 && step_on_ops 24-broker-scale.sh add kb04 || exit 1; }
stage 23 "26 OS 修補" && { step_on_ops 26-os-patch.sh apply || exit 1; }
stage 24 "19 驗收（20–26 做完再一次）" && { install_on_ops --from 19 || exit 1; }
stage 25 "完成" && { install_on_ops --list; }
# TO= 讓最後幾段被略過時，最後一個 stage 會回 1；走到這裡就是成功
exit 0
