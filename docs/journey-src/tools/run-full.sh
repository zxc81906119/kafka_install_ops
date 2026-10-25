#!/usr/bin/env bash
# run-full.sh <customer|conjur|provider> [起始章] [結束章（不含）]  —— 照手把手的指令塊在 lab 上實跑（Windows Git Bash）
#
#   bash run-full.sh customer          從第 0 章跑到最後：先把 lab 整個拆掉（保留落地區 ~/kafka-lab/landing、landing-extra）
#   bash run-full.sh conjur 15 21      只跑第 15–20 章（不拆 lab，接著現有的狀態）
#
# 模式決定跑哪些塊（journey.md 的 @only，見 run-chapter.js）。執行檔與紀錄放 $OUT_DIR（預設 ~/kafka-lab-runs/），
# 跑完用 scan-log.sh 掃「rc 是 0 但其實失敗」的輸出。結束碼：執行檔的結束碼；有可疑輸出也算失敗。
set -uo pipefail
export MSYS_NO_PATHCONV=1
MODE=${1:?用法：bash $0 customer|conjur|provider [起始章] [結束章]}
FROM=${2:-0}; TO=${3:-99}
TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$TOOLS_DIR/../../.." && pwd)
LAB=$HOME/kafka-lab
OUT_DIR=${OUT_DIR:-$HOME/kafka-lab-runs}
mkdir -p "$OUT_DIR"
stamp=$(date +%Y%m%d-%H%M)
runner="$OUT_DIR/run-$MODE-$FROM-$TO-$stamp.sh"; log="${runner%.sh}.log"

MODE=$MODE node "$TOOLS_DIR/run-chapter.js" "$REPO_DIR/docs/journey-src/journey.md" "$FROM" "$TO" "$runner" || exit 1
# 17.3 打包選單：文件寫的是佔位的原始碼目錄
sed -i "s#<放 opmenu/ 原始碼的目錄>#$REPO_DIR#" "$runner"

# 從第 0 章開始：拆掉整個 lab（容器、volume、下載機、行內 Prometheus），只留落地區
if [ "$FROM" = 0 ]; then
  echo "拆掉 lab（保留 $LAB/landing、landing-extra）"
  if [ -f "$LAB/compose.yml" ]; then
    (cd "$LAB" && docker compose -f compose.yml $([ -f conjur.yml ] && echo "-f conjur.yml") down -v >/dev/null 2>&1)
  fi
  docker rm -f dl01 bank-prometheus >/dev/null 2>&1
  [ -d "$LAB" ] && find "$LAB" -mindepth 1 -maxdepth 1 ! -name landing ! -name landing-extra -exec rm -rf {} +
fi

echo "執行 $runner（紀錄 $log）"
bash "$runner" > "$log" 2>&1; rc=$?
bash "$TOOLS_DIR/scan-log.sh" "$log"; scan=$?
echo "結束碼 $rc；紀錄 $log"
[ "$rc" = 0 ] && [ "$scan" = 0 ]
