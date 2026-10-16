#!/usr/bin/env bash
# Kafka 維運操作選單(OP menu)— 骨架
#
# 結構(可抽換實作):
#   opmenu.conf            這個環境的設定(連線位址、node、命名規範…);換環境只改這裡。範本見 opmenu.conf.example
#   lib/defaults.sh        所有設定項目與預設值(說明文件兼保險;opmenu.conf 沒設的才用它)
#   lib/core.sh            固定流程:登入身分、選單、ticket、確認、記錄(Template)
#   lib/backend/<名稱>.sh  環境相依的實作:怎麼跑 Kafka 工具、呼叫 MDS、重啟服務、看日誌、看磁碟、列 certificate(Strategy)
#   lib/ticket/<名稱>.sh   ticket 怎麼驗(Strategy):format 只檢查格式;http 向開單系統查;由 OPMENU_TICKET_CHECK 選
#   lib/actions/*.sh       每個選單項目一段,自帶編號、層級、是否需 ticket、是否需確認(Command)
#
# 用法:
#   ./opmenu.sh                     互動選單
#   ./opmenu.sh --list              列出所有項目
#   ./opmenu.sh --run 12 [參數]     直接執行一個項目(測試、排程用)
#   環境變數:OPMENU_USER / OPMENU_PASS(操作者 AD 帳密)、OPMENU_TICKET(ticket)、OPMENU_YES=1(略過確認)
set -uo pipefail
OPMENU_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPMENU_HOME
# 設定檔的優先順序:$OPMENU_CONF → /etc/opmenu/opmenu.conf(正式安裝)→ 程式目錄下的 opmenu.conf(測試)
for _c in "${OPMENU_CONF:-}" /etc/opmenu/opmenu.conf "$OPMENU_HOME/opmenu.conf"; do [ -n "$_c" ] && [ -f "$_c" ] && { . "$_c"; break; }; done
. "$OPMENU_HOME/lib/defaults.sh"
. "$OPMENU_HOME/lib/validate.sh"
. "$OPMENU_HOME/lib/core.sh"
# 測試用的環境變數(帳密、略過確認、ticket、原因)只在設定檔明確允許時才接受;正式環境 OPMENU_ALLOW_ENV_OVERRIDE=0,操作員塞不進這些值
if [ "${OPMENU_ALLOW_ENV_OVERRIDE:-0}" != 1 ]; then unset OPMENU_USER OPMENU_PASS OPMENU_YES OPMENU_TICKET OPMENU_REASON; fi
. "$OPMENU_HOME/lib/backend/$OPMENU_BACKEND.sh" || { echo "找不到 backend: $OPMENU_BACKEND"; exit 1; }
core_guard_host_actions   # 碰 node 的介面先過權限閘門(lib/core.sh)
. "$OPMENU_HOME/lib/ticket/$OPMENU_TICKET_CHECK.sh" || { echo "找不到 ticket 檢查方式: $OPMENU_TICKET_CHECK"; exit 1; }
for f in "$OPMENU_HOME"/lib/actions/*.sh; do . "$f"; done

# 當登入殼層時,ssh/su 送來的 "-c <指令>" 一律不執行,直接進選單;sshd ForceCommand 也是經殼層 -c 執行本程式,所以用 SSH_ORIGINAL_COMMAND 判斷有沒有人想繞過
if [ "${1:-}" = -c ]; then
  [ -n "${SSH_ORIGINAL_COMMAND:-}" ] && core_log_pre_login BYPASS_ATTEMPT "ssh 指令被擋" "$SSH_ORIGINAL_COMMAND"
  set --
fi
core_init "$@"
