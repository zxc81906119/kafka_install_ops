#!/usr/bin/env bash
# run-full.sh <customer> [起始章] [結束章]  ——（兩端都含；章是 0–33、B（A 是 0 的舊名）；順序 0 → 1 … 33 → B） 照手把手的指令塊在 lab 上實跑（Windows Git Bash）
#
#   bash run-full.sh customer          從第 0 章（建 lab）跑到附錄 B（= 整條遷移主線：基底 CP 8.2.4／JDK 21／OS 9.6 → 第 29、30、31 章遷移到 8.3.2／JDK 25／OS 9.8）：
#                                      先把 lab 整個拆掉（只保留落地區 ~/kafka-lab/landing 和銀行 OS 內容的下載快取 ~/kafka-lab/bank-os；舊的 landing-extra 會整理進 landing）
#   bash run-full.sh customer 15 19    只跑第 15–19 章（不拆 lab，接著現有的狀態）
#
# 模式只剩 customer（CyberArk 只有 PAM）。執行檔與紀錄放 $OUT_DIR（預設 ~/kafka-lab-runs/），
# 跑完用 scan-log.sh 掃「rc 是 0 但其實失敗」的輸出。結束碼：執行檔的結束碼；有可疑輸出也算失敗。
set -uo pipefail
export MSYS_NO_PATHCONV=1

# 安裝 Podman 之前就開著的 Git Bash 找不到 podman
if ! command -v podman >/dev/null 2>&1; then
  podman_dir=$(cygpath -u "$LOCALAPPDATA")/Programs/Podman
  export PATH="$podman_dir:$PATH"
fi

MODE=${1:?用法：bash $0 customer [起始章] [結束章]}
FROM=${2:-0}
TO=${3:-end}

# 建 lab 原本是附錄 A，2026-10-29 搬回開頭成為第 0 章
if [ "$FROM" = A ]; then
  FROM=0
fi

if [ "$TO" = A ]; then
  TO=0
fi

script_dir=$(dirname "$0")
TOOLS_DIR=$(
  if ! cd "$script_dir"; then
    exit 1
  fi

  pwd
)
REPO_DIR=$(
  if ! cd "$TOOLS_DIR/../../.."; then
    exit 1
  fi

  pwd
)
LAB=$HOME/kafka-lab
OUT_DIR=${OUT_DIR:-$HOME/kafka-lab-runs}
mkdir -p "$OUT_DIR"
stamp=$(date +%Y%m%d-%H%M)
runner="$OUT_DIR/run-$MODE-$FROM-$TO-$stamp.sh"
log="${runner%.sh}.log"

# Node 是 Windows 程式：路徑先轉成 C:/… 再給它（MSYS_NO_PATHCONV=1 時 Git Bash 不會自動轉）
chapter_tool=$(cygpath -m "$TOOLS_DIR/run-chapter.js")
journey_file=$(cygpath -m "$REPO_DIR/docs/journey-src/journey.md")
runner_file=$(cygpath -m "$runner")

if ! MODE=$MODE node "$chapter_tool" "$journey_file" "$FROM" "$TO" "$runner_file"; then
  exit 1
fi

if ! grep -q "BLOCK" "$runner"; then
  echo "第 $FROM 章到第 $TO 章沒有任何指令塊：範圍寫錯了？" >&2
  exit 1
fi

# 16.3 選單是交付物（tar＋SHA256SUMS）：lab 實跑時先用 opmenu/package.sh 產生，把手冊的佔位目錄換成它
DELIVERY=$OUT_DIR/delivery-opmenu

if ! bash "$REPO_DIR/opmenu/package.sh" "$DELIVERY" >/dev/null; then
  exit 1
fi

sed -i "s#<交付物的目錄>#$DELIVERY#" "$runner"

# 33.2 CBOM 工具也是交付物：dist/ 是 cbom/build.sh 建出來的（要 dl01 在跑，所以不在這裡建）
if grep -q "<CBOM 交付物的目錄>" "$runner"; then
  CBOM_DELIVERY=$OUT_DIR/delivery-cbom

  if ! bash "$REPO_DIR/cbom/package.sh" "$CBOM_DELIVERY" >/dev/null; then
    echo "第 33 章需要 CBOM 的交付物：先跑 bash cbom/build.sh" >&2
    exit 1
  fi

  sed -i "s#<CBOM 交付物的目錄>#$CBOM_DELIVERY#" "$runner"
fi

# 從第 0 章開始：拆掉整個 lab（容器、volume、下載機、第 17 章的 lab-mon-* 監控容器），只留落地區
if [ "$FROM" = 0 ]; then
  echo "拆掉 lab（保留 $LAB/landing 與 $LAB/bank-os；舊版面的 landing-extra 併進 landing）"
  if [ -f "$LAB/compose.yml" ]; then
    # 這些容器接在 lab_labnet 上，不先收掉 down -v 刪不掉網路
    podman rm -f lab-mon-prometheus lab-mon-alertmanager lab-mon-grafana lab-mon-webhook >/dev/null 2>&1
    # 第 33 章的 lab Jenkins 也接在 lab 的網路上
    podman rm -f lab-jenkins >/dev/null 2>&1

    (
      if cd "$LAB"; then
        podman compose -f compose.yml down -v >/dev/null 2>&1
      fi
    )
  fi

  podman rm -f dl01 bank-prometheus >/dev/null 2>&1

  if [ -d "$LAB" ]; then
    find "$LAB" -mindepth 1 -maxdepth 1 ! -name landing ! -name landing-extra ! -name bank-os -exec rm -rf {} +
  fi

  # 舊版面（8.3.2 在 landing/rpm、8.2.4 在 landing-extra/）→ landing/rpm = 基底、landing/rpm-target = 目標（只搬檔案）
  bank_sim=$(cygpath -m "$REPO_DIR/install/lab/bank-sim.sh")

  if ! bash "$bank_sim" landing-layout; then
    exit 1
  fi
fi

echo "執行 $runner（紀錄 $log）"
bash "$runner" > "$log" 2>&1
rc=$?
bash "$TOOLS_DIR/scan-log.sh" "$log"
scan=$?
echo "結束碼 $rc；紀錄 $log"

if [ "$rc" = 0 ] && [ "$scan" = 0 ]; then
  exit 0
fi

exit 1
