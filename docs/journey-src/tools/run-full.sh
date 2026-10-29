#!/usr/bin/env bash
# run-full.sh <customer> [起始章] [結束章]  ——（兩端都含；章是 0–31、B（A 是 0 的舊名）；順序 0 → 1 … 31 → B） 照手把手的指令塊在 lab 上實跑（Windows Git Bash）
#
#   bash run-full.sh customer          從第 0 章（建 lab）跑到附錄 B（= 整條遷移主線：基底 CP 8.2.4／JDK 21／OS 9.6 → 第 29、30、31 章遷移到 8.3.2／JDK 25／OS 9.8）：
#                                      先把 lab 整個拆掉（只保留落地區 ~/kafka-lab/landing 和銀行 OS 內容的下載快取 ~/kafka-lab/bank-os；舊的 landing-extra 會整理進 landing）
#   bash run-full.sh customer 15 19    只跑第 15–19 章（不拆 lab，接著現有的狀態）
#
# 模式只剩 customer（CyberArk 只有 PAM）。執行檔與紀錄放 $OUT_DIR（預設 ~/kafka-lab-runs/），
# 跑完用 scan-log.sh 掃「rc 是 0 但其實失敗」的輸出。結束碼：執行檔的結束碼；有可疑輸出也算失敗。
set -uo pipefail
export MSYS_NO_PATHCONV=1
MODE=${1:?用法：bash $0 customer [起始章] [結束章]}
FROM=${2:-0}; TO=${3:-end}
[ "$FROM" = A ] && FROM=0; [ "$TO" = A ] && TO=0   # 建 lab 原本是附錄 A，2026-10-29 搬回開頭成為第 0 章
TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$TOOLS_DIR/../../.." && pwd)
LAB=$HOME/kafka-lab
OUT_DIR=${OUT_DIR:-$HOME/kafka-lab-runs}
mkdir -p "$OUT_DIR"
stamp=$(date +%Y%m%d-%H%M)
runner="$OUT_DIR/run-$MODE-$FROM-$TO-$stamp.sh"; log="${runner%.sh}.log"

# Node 是 Windows 程式：路徑先轉成 C:/… 再給它（MSYS_NO_PATHCONV=1 時 Git Bash 不會自動轉）
MODE=$MODE node "$(cygpath -m "$TOOLS_DIR/run-chapter.js")" "$(cygpath -m "$REPO_DIR/docs/journey-src/journey.md")" "$FROM" "$TO" "$(cygpath -m "$runner")" || exit 1
grep -q "BLOCK" "$runner" || { echo "第 $FROM 章到第 $TO 章沒有任何指令塊：範圍寫錯了？" >&2; exit 1; }
# 16.3 選單是交付物（tar＋SHA256SUMS）：lab 實跑時先用 opmenu/package.sh 產生，把手冊的佔位目錄換成它
DELIVERY=$OUT_DIR/delivery-opmenu; bash "$REPO_DIR/opmenu/package.sh" "$DELIVERY" >/dev/null || exit 1
sed -i "s#<交付物的目錄>#$DELIVERY#" "$runner"

# 從第 0 章開始：拆掉整個 lab（容器、volume、下載機、第 17 章的 lab-mon-* 監控容器），只留落地區
if [ "$FROM" = 0 ]; then
  echo "拆掉 lab（保留 $LAB/landing 與 $LAB/bank-os；舊版面的 landing-extra 併進 landing）"
  if [ -f "$LAB/compose.yml" ]; then
    docker rm -f lab-mon-prometheus lab-mon-alertmanager lab-mon-grafana lab-mon-webhook >/dev/null 2>&1   # 接在 lab_labnet 上，不先收掉 down -v 刪不掉網路
    (cd "$LAB" && docker compose -f compose.yml down -v >/dev/null 2>&1)
  fi
  docker rm -f dl01 bank-prometheus >/dev/null 2>&1
  [ -d "$LAB" ] && find "$LAB" -mindepth 1 -maxdepth 1 ! -name landing ! -name landing-extra ! -name bank-os -exec rm -rf {} +
  # 舊版面（8.3.2 在 landing/rpm、8.2.4 在 landing-extra/）→ landing/rpm = 基底、landing/rpm-target = 目標（只搬檔案）
  bash "$(cygpath -m "$REPO_DIR/install/lab/bank-sim.sh")" landing-layout || exit 1
fi

echo "執行 $runner（紀錄 $log）"
bash "$runner" > "$log" 2>&1; rc=$?
bash "$TOOLS_DIR/scan-log.sh" "$log"; scan=$?
echo "結束碼 $rc；紀錄 $log"
[ "$rc" = 0 ] && [ "$scan" = 0 ]
