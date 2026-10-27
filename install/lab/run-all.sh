#!/usr/bin/env bash
# install/lab/run-all.sh —— lab 從零全自動驗證（Windows Git Bash）
#
#   bash run-all.sh              down -v 從零，跑到第 14 站
#   bash run-all.sh --no-reset   用現有 lab 重跑（驗冪等）
#   第 15 站起（Secret Protection、選單、驗收…）由 run-customer.sh 從零跑到第 19 站
#
# 流程裡的「銀行」動作都由 bank-sim.sh 代做；安裝本身只靠 install.sh，和正式環境一樣。
set -uo pipefail
export MSYS_NO_PATHCONV=1
LAB_TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
BANK="bash $LAB_TOOLS_DIR/bank-sim.sh"
# 扮演 LB 團隊（手把手 12.1）：腳本重啟 REST 前會寫 ~/lb-requests/ 的請求，bank-sim lb-watch 照做後回覆
LB_TEAM_STOP="${LAB:-$HOME/kafka-lab}/lb-watch.stop.$$"   # 每支 runner 自己的結束訊號（升級演練裡面還會再叫 run-customer.sh）
bash "$LAB_TOOLS_DIR/bank-sim.sh" lb-watch "$LB_TEAM_STOP" >> "${LAB:-$HOME/kafka-lab}/lb-watch.log" 2>&1 &
LB_TEAM_PID=$!
trap 'touch "$LB_TEAM_STOP"; kill $LB_TEAM_PID 2>/dev/null' EXIT
started_at=$(date +%s)

# 在操作機以 cpadmin 跑 install.sh（參數照傳）
install_on_ops() { docker exec -u cpadmin -w /home/cpadmin lab-ops02-1 bash install/install.sh "$@" </dev/null; }
# 印一行分隔與經過的秒數，log 裡好找
milestone() { printf '\n######## %s (+%ss) ########\n' "$*" "$(( $(date +%s) - started_at ))"; }
# install.sh 應該停在「等銀行」（rc 2）的地方
expect_wait_for_bank() {
  local exit_code=$1 step=$2
  [ "$exit_code" = 2 ] && return 0
  echo "預期 $step 停在等銀行（rc 2），實際 rc=$exit_code"
  exit 1
}

if [ "${1:-}" != --no-reset ]; then milestone "reset"; $BANK reset; fi
milestone "push install/ 到 ops02 與 dl01"; $BANK push
milestone "01 download（dl01）"; docker exec dl01 bash /root/install/steps/01-download.sh </dev/null || exit 1
milestone "銀行：檔案交換"; $BANK intake
milestone "02–03"; install_on_ops --to 03; expect_wait_for_bank $? 03
milestone "銀行：公鑰、套件庫、根憑證、AD、NTP、LB"; $BANK prepare
milestone "03–09"; install_on_ops --from 03 --to 09; expect_wait_for_bank $? 09
milestone "銀行：CA 簽發"; $BANK sign
milestone "09–14"; install_on_ops --from 09 --to 14 || exit 1
milestone "完成"; install_on_ops --list
