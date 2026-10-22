#!/usr/bin/env bash
# install.sh — 依序執行 steps/NN-*.sh（手把手文件一章一支）。在操作機以 cpadmin 執行。
#   bash install.sh              從頭跑到第 14 站（第 1 站在下載機跑，這裡只提示）
#   bash install.sh --from 09    從第 9 站起
#   bash install.sh --only 12    只跑第 12 站
#   bash install.sh --list       列出步驟與完成狀態
# 任一步 rc≠0 就停：rc 2 表示「等銀行」，銀行做完後用 --from 重跑同一步。
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
LOG_DIR=${LOG_DIR:-$HOME/install-logs}
from=02; to=99; only=""; list=0
while [ $# -gt 0 ]; do case $1 in --from) from=$2; shift 2;; --to) to=$2; shift 2;; --only) only=$2; from=$2; to=$2; shift 2;; --list) list=1; shift;; *) echo "用法：$0 [--list] [--from NN] [--to NN] [--only NN]"; exit 1;; esac; done

if [ $list = 1 ]; then
  for s in "$D"/steps/[0-9][0-9]-*.sh; do
    n=$(basename "$s" .sh); where=$(awk '/^# where:/{print $3; exit}' "$s"); title=$(sed -n '2s/^# //p' "$s" | sed 's/ —.*//')
    printf '%-20s %-6s %-8s %s\n' "$n" "$where" "$([ -f "$LOG_DIR/$n.done" ] && echo done || echo -)" "$title"
  done; exit 0
fi

me=$(hostname -s)
for s in "$D"/steps/[0-9][0-9]-*.sh; do
  n=$(basename "$s" .sh); nn=${n%%-*}
  [ "$nn" \< "$from" ] && continue; [ "$nn" \> "$to" ] && continue
  where=$(awk '/^# where:/{print $3; exit}' "$s")
  if [ "$where" != "$me" ] && [ -z "$only" ]; then echo "== $n：請在 $where 執行 bash steps/$n.sh（這台是 $me，略過）"; continue; fi
  echo; echo "================ $n ================"
  bash "$s"; rc=$?
  case $rc in
    0) ;;
    2) echo; echo "== $n 在等銀行。銀行做完後：bash $0 --from $nn"; exit 2;;
    *) echo; echo "== $n 失敗（rc=$rc）。修好後：bash $0 --from $nn"; exit $rc;;
  esac
done
echo; echo "全部完成。log 在 $LOG_DIR/"
