#!/usr/bin/env bash
# install/lab/run-all.sh — lab 從零到第 14 站的全自動驗證（Windows Git Bash）。
# 流程：reset → push → [dl01] 01 → bank intake → [ops02] 02–03（等銀行）→ bank prepare → 03–09（等銀行）→ bank sign → 09–14
#   bash run-all.sh            含 reset（down -v），跑到第 14 站
#   bash run-all.sh --no-reset 用現有 lab
#   EXT=1 bash run-all.sh      再接延伸站：銀行建 Conjur／變數／opmenu 身分 → 15–19（依 site.env 的開關）→ 行內 Prometheus → 冷開機 → 20 驗收
set -uo pipefail
export MSYS_NO_PATHCONV=1
H=$(cd "$(dirname "$0")" && pwd); B="bash $H/bank-sim.sh"
ops() { docker exec -u cpadmin -w /home/cpadmin lab-ops02-1 bash install/install.sh "$@" </dev/null; }
t0=$(date +%s); mark() { printf '\n######## %s (+%ss) ########\n' "$*" "$(( $(date +%s) - t0 ))"; }

[ "${1:-}" = --no-reset ] || { mark reset; $B reset; }
mark push; $B push
mark "01 download (dl01)"; docker exec dl01 bash /root/install/steps/01-download.sh </dev/null || exit 1
mark "bank: intake"; $B intake
mark "02–03"; ops --to 03; rc=$?; [ $rc = 2 ] || { echo "預期 03 停在等銀行（rc 2），實際 rc=$rc"; exit 1; }
mark "bank: prepare"; $B prepare
mark "03–09"; ops --from 03 --to 09; rc=$?; [ $rc = 2 ] || { echo "預期 09 停在等銀行（rc 2），實際 rc=$rc"; exit 1; }
mark "bank: sign"; $B sign
mark "09–14"; ops --from 09 || exit 1
if [ "${EXT:-0}" = 1 ]; then
  mark "bank: conjur / sp / opmenu（15.1、16.1+16.8、17.1）"; $B conjur && $B sp && $B opmenu || exit 1
  mark "15–19"; ops --from 15 --to 19 || exit 1
  mark "bank: prometheus（18.5）"; $B prometheus
  mark "bank: coldboot（20.4）"; $B coldboot
  mark "20"; ops --from 20 || exit 1
fi
mark "完成"; ops --list
