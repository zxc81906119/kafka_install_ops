#!/usr/bin/env bash
# install/lab/run-upgrade-drill.sh —— lab：升級演練（Windows Git Bash），驗 install/steps/21-upgrade.sh
#
#   bash run-upgrade-drill.sh            客戶模式從零裝 8.2.4（run-customer.sh），再用 21-upgrade.sh 升到 8.3.2
#   SKIP_INSTALL=1 bash run-upgrade-drill.sh   lab 已經是 8.2.4（例如上一次中途停下）：直接從升級開始
#
# 流程（手把手第 21 章的順序，每段後驗收）：
#   plan → backup → packages（8.3.2，JDK 21）→ 驗收 → jdk 25 → 驗收 → rollback kb04 8.2.4 →
#   ONLY_HOSTS=kb04 升回 → finalize 不帶確認（要停下）→ 帶確認升版 → 驗收；全程持續流量，最後報遺失與失敗
set -uo pipefail
export MSYS_NO_PATHCONV=1
LAB_TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
OPS_CONTAINER=lab-ops02-1
FROM_VERSION=${FROM_VERSION:-8.2.4}
TO_VERSION=${TO_VERSION:-8.3.2}
NEW_JDK_MAJOR=${NEW_JDK_MAJOR:-25}
started_at=$(date +%s)
# 扮演 LB 團隊（手把手 12.1）：腳本重啟 REST 前會寫 ~/lb-requests/ 的請求，bank-sim lb-watch 照做後回覆
LB_TEAM_STOP="${LAB:-$HOME/kafka-lab}/lb-watch.stop.$$"   # 每支 runner 自己的結束訊號（升級演練裡面還會再叫 run-customer.sh）
bash "$LAB_TOOLS_DIR/bank-sim.sh" lb-watch "$LB_TEAM_STOP" >> "${LAB:-$HOME/kafka-lab}/lb-watch.log" 2>&1 &
LB_TEAM_PID=$!
trap 'touch "$LB_TEAM_STOP"; kill $LB_TEAM_PID 2>/dev/null' EXIT

# 在操作機以 root 跑一段指令；印標題與結束碼
on_ops() {
  local title=$1 command=$2 exit_code
  printf '\n######## %s (+%ss)\n' "$title" "$(( $(date +%s) - started_at ))"
  docker exec -w /root "$OPS_CONTAINER" bash -c "$command"
  exit_code=$?; echo "rc=$exit_code"; return "$exit_code"
}
acceptance() { on_ops "驗收（$1）" 'bash install/install.sh --only 19 2>&1 | grep -E "驗收：| FAIL "'; }

if [ "${SKIP_INSTALL:-0}" != 1 ]; then
  printf '######## 客戶模式從零裝 %s\n' "$FROM_VERSION"
  CP_VERSION=$FROM_VERSION TO=17 bash "$LAB_TOOLS_DIR/run-customer.sh" || { echo "安裝失敗"; exit 1; }   # 裝到第一次驗收就好
fi
# 升級前先改 site.env 的目標版本（第 21 章、21-upgrade.sh 的做法）
docker exec "$OPS_CONTAINER" sed -i "s/^CP_VERSION=[0-9.]*/CP_VERSION=$TO_VERSION/" /root/install/conf/site.env
on_ops "持續流量開始" 'bash install/tools/load.sh start'

on_ops "plan"   'bash install/steps/21-upgrade.sh plan 2>&1 | grep -E " ok | FAIL |目前|套件庫"' || exit 1
on_ops "backup" 'bash install/steps/21-upgrade.sh backup 2>&1 | grep -E " ok | FAIL |備份 →"' || exit 1
on_ops "packages $TO_VERSION" 'bash install/steps/21-upgrade.sh packages 2>&1 | grep -E " ok | FAIL |這輪|== |完成"' || exit 1
acceptance "$TO_VERSION＋JDK 21"
on_ops "jdk $NEW_JDK_MAJOR" "bash install/steps/21-upgrade.sh jdk $NEW_JDK_MAJOR 2>&1 | grep -E ' ok | FAIL |這輪|== |留在'" || exit 1
acceptance "$TO_VERSION＋JDK $NEW_JDK_MAJOR"
on_ops "rollback kb04 → $FROM_VERSION" "bash install/steps/21-upgrade.sh rollback kb04 $FROM_VERSION 2>&1 | grep -E ' ok | FAIL |WARN|jdk'" || exit 1
on_ops "kb04 升回（ONLY_HOSTS）" "ONLY_HOSTS=kb04 bash install/steps/21-upgrade.sh packages 2>&1 | grep -E ' ok | FAIL |略過' && ONLY_HOSTS=kb04 bash install/steps/21-upgrade.sh jdk $NEW_JDK_MAJOR 2>&1 | grep -E ' ok | FAIL |略過'" || exit 1
# 不帶確認：要停下（結束碼 1）並印出帶 cluster id 的指令
if on_ops "finalize 不帶確認（應停下）" 'bash install/steps/21-upgrade.sh finalize 4.3 2>&1 | grep -E "can be upgraded|CONFIRM" | tail -2; exit ${PIPESTATUS[0]}'; then
  echo "不帶確認竟然執行了 finalize"; exit 1
fi
on_ops "finalize 帶確認" 'source ~/conf/kraft.env; CONFIRM_CLUSTER_ID=$CLUSTER_ID bash install/steps/21-upgrade.sh finalize 4.3 2>&1 | grep -E "was upgraded|升版後"' || exit 1
acceptance "finalize 之後"
on_ops "持續流量結果" 'bash install/tools/load.sh stop; bash install/tools/load.sh report'
printf '\n######## 完成（%s 秒）\n' "$(( $(date +%s) - started_at ))"
