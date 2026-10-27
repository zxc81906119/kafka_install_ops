#!/usr/bin/env bash
# install.sh —— 依序執行 steps/NN-*.sh（手把手文件一章一支）。在操作機以 cpadmin 執行。
#
#   bash install.sh              從第 2 站跑到最後（第 1 站在下載機跑，這裡只提示）
#   bash install.sh --from 09    從第 9 站起
#   bash install.sh --to 14      跑到第 14 站為止
#   bash install.sh --only 12    只跑第 12 站
#   bash install.sh --list       列出每一站、在哪台跑、是否已完成
#
# 每一站的結束碼：0 成功；2 等銀行（印出「請銀行做」清單，做完用 --from 重跑同一站）；其他 = 失敗。
# 任一站不是 0 就停。紀錄在 ~/install-logs/。
set -uo pipefail
INSTALL_DIR=$(cd "$(dirname "$0")" && pwd)
LOG_DIR=${LOG_DIR:-$HOME/install-logs}

from_step=02
to_step=99
only_step=""
list_only=0
while [ $# -gt 0 ]; do
  case $1 in
    --from) from_step=$2; shift 2;;
    --to)   to_step=$2; shift 2;;
    --only) only_step=$2; from_step=$2; to_step=$2; shift 2;;
    --list) list_only=1; shift;;
    *) echo "用法：$0 [--list] [--from NN] [--to NN] [--only NN]"; exit 1;;
  esac
done

# 從步驟檔的檔頭讀出「在哪台跑」（# where: 那一行）與標題（第 2 行，—— 之前）
where_of() { awk '/^# where:/{print $3; exit}' "$1"; }
title_of() { sed -n '2s/^# //p' "$1" | sed 's/ ——.*//'; }

if [ "$list_only" = 1 ]; then
  for step_file in "$INSTALL_DIR"/steps/[0-9][0-9]-*.sh; do
    step_name=$(basename "$step_file" .sh)
    done_mark=$([ -f "$LOG_DIR/$step_name.done" ] && echo "done" || echo "-")
    printf '%-24s %-6s %-6s %s\n' "$step_name" "$(where_of "$step_file")" "$done_mark" "$(title_of "$step_file")"
  done
  exit 0
fi

this_host=$(hostname -s)
for step_file in "$INSTALL_DIR"/steps/[0-9][0-9]-*.sh; do
  step_name=$(basename "$step_file" .sh)
  step_number=${step_name%%-*}
  # 站號一律當十進位數字比（10# 讓 08、09 不被當成八進位）：--from 9 和 --from 09 一樣
  (( 10#$step_number < 10#$from_step )) && continue
  (( 10#$step_number > 10#$to_step )) && continue
  run_on=$(where_of "$step_file")
  if [ "$run_on" != "$this_host" ]; then   # --only 也一樣：不是這台的步驟（例如下載機那支）一律略過
    echo "== $step_name：請在 $run_on 執行 bash steps/$step_name.sh（這台是 $this_host，略過）"
    continue
  fi
  if grep -q '^# run: on-demand' "$step_file" && [ -z "$only_step" ]; then   # 不在安裝順序裡的（例如憑證輪替）：要用時直接執行那支
    echo "== $step_name：要用時再執行（bash steps/$step_name.sh），照順序安裝時略過"
    continue
  fi
  echo
  echo "================ $step_name ================"
  bash "$step_file"
  exit_code=$?
  case $exit_code in
    0) ;;
    2) echo; echo "== $step_name 在等銀行。銀行做完後：bash $0 --from $step_number"; exit 2;;
    *) echo; echo "== $step_name 失敗（rc=$exit_code）。修好後：bash $0 --from $step_number"; exit "$exit_code";;
  esac
done
echo
echo "全部完成。紀錄在 $LOG_DIR/"
