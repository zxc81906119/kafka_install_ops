#!/usr/bin/env bash
# Kafka 維運操作選單(OP menu)— 進入點:載入設定與共用程式、登入、取 ssh 金鑰、顯示選單、迴圈。
#
# 結構:
#   /etc/opmenu/opmenu.conf   這個環境的設定(連線位址、主機、保管庫、命名規範);換環境只改這裡。範本見 opmenu.conf.example
#   lib/defaults.sh           所有設定項目與預設值(說明文件兼保險;opmenu.conf 沒設的才用它)
#   lib/common.sh             共用:項目登記、紀錄、確認、輸入驗證、執行流程、主機權限閘門、ssh 金鑰載入
#   lib/kafka.sh              共用:以操作者身分跑 Kafka 工具、呼叫 MDS;91 用保管庫憑證
#   lib/hosts.sh              共用:ssh 到各主機重啟、看日誌、磁碟、診斷
#   lib/secrets/<名稱>.sh     機敏資料從哪裡取:conjur | ccp | manual(OPMENU_SECRETS 選;manual = 沒有 CCP,維運人員從 PVWA 取出貼上)
#   items/<編號>-<名稱>.sh     每個選單項目一個檔:開頭 item 一行宣告,下面 run() 做事
#
# 用法:
#   opmenu.sh                     互動選單
#   opmenu.sh --list              列出所有項目
#   opmenu.sh --run 12 [參數]     直接執行一個項目(測試、排程用);--run menu 只印本人看得到的編號
#   環境變數(只在 OPMENU_ALLOW_ENV_OVERRIDE=1 時接受):OPMENU_USER / OPMENU_PASS(操作者 AD 帳密)、OPMENU_YES=1(略過確認)、OPMENU_REASON
set -uo pipefail
OPMENU_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPMENU_HOME
for _c in "${OPMENU_CONF:-}" /etc/opmenu/opmenu.conf "$OPMENU_HOME/opmenu.conf"; do [ -n "$_c" ] && [ -f "$_c" ] && { . "$_c"; break; }; done
. "$OPMENU_HOME/lib/defaults.sh"
. "$OPMENU_HOME/lib/common.sh"
if [ "${OPMENU_ALLOW_ENV_OVERRIDE:-0}" != 1 ]; then unset OPMENU_USER OPMENU_PASS OPMENU_YES OPMENU_REASON; fi   # 測試用的環境變數只在設定檔明確允許時才接受
. "$OPMENU_HOME/lib/kafka.sh"
. "$OPMENU_HOME/lib/hosts.sh"
. "$OPMENU_HOME/lib/secrets/$OPMENU_SECRETS.sh" || { echo "找不到 secrets 來源: $OPMENU_SECRETS"; exit 1; }
core_guard_host_actions   # 碰主機的介面先過權限閘門
load_items "$OPMENU_HOME/items" || exit 1

# ── 登入:操作者本人的 AD 帳密 → 向 MDS 換 token;產生只有自己能讀的 Kafka 連線設定檔(記憶體檔案系統);推算沒填的設定;取 ssh 金鑰 ──
login() {
  local pass="${OPMENU_PASS:-}"
  OP_SID="$(date +%s)-$$"
  if [ "${OPMENU_USER_FROM_OS:-0}" = 1 ]; then OP_USER="$(id -un)"; echo "操作者(作業系統登入帳號):$OP_USER"
  else
    OP_USER="${OPMENU_USER:-}"; if [ -z "$OP_USER" ]; then read -r -p "AD 帳號: " OP_USER; fi
    [[ "$OP_USER" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || { echo "${CR}帳號含不允許的字元${C0}"; exit 1; }
  fi
  if [ -z "$pass" ]; then read -r -s -p "AD 密碼: " pass; echo; fi
  umask 077
  core_sweep_residue
  OP_CLIENT_CONF="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"
  OP_LAST_RAW="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"
  trap core_cleanup EXIT; trap 'core_cleanup; exit 130' INT; trap 'core_cleanup; exit 143' TERM; trap 'core_cleanup; exit 129' HUP
  cat > "$OP_CLIENT_CONF" <<EOC
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$OP_USER" password="$pass";
ssl.truststore.location=$(be_truststore_path)
ssl.truststore.type=PKCS12
ssl.truststore.password=$(be_truststore_password)
EOC
  local lrc; OP_TOKEN="$(be_mds_login "$OP_USER" "$pass")"; lrc=$?
  if [ $lrc -eq 2 ]; then echo "${CR}無法連到 MDS,請確認 cluster 狀態或通知管理員。${C0}"; core_log MDS_DOWN login ""; exit 1
  elif [ $lrc -ne 0 ]; then echo "${CR}登入失敗:帳號或密碼不正確。${C0}"; core_log AUTH_FAIL login ""; exit 1; fi
  OP_TOKEN_AT=$(date +%s)
  derive || { core_log DERIVE_FAIL login ""; exit 1; }
  unset pass
  export OP_USER OP_CLIENT_CONF OP_LAST_RAW OP_TOKEN OP_SID
  core_load_ssh_key || true   # 取不到金鑰不擋登入:Kafka 類項目照常,主機類項目執行時才失敗
}

# 登入後推算沒填的設定(opmenu.conf 有填的一律優先)。刻意不從 cluster 推算 broker 與主機清單:它們是重啟、ssh 的允許清單,必須是審過的固定設定
derive() {
  local id n
  if [ -z "${OPMENU_KAFKA_CLUSTER_ID:-}" ]; then
    id="$(be_cluster_id)"; [ -n "$id" ] || { echo "${CR}無法從 MDS 取得 cluster ID,請在 opmenu.conf 設定 OPMENU_KAFKA_CLUSTER_ID${C0}"; return 1; }
    dd OPMENU_KAFKA_CLUSTER_ID "$id"
  fi
  [ -n "${OPMENU_BROKER_SERVICES:-}" ] || { echo "${CR}請在 opmenu.conf 設定 OPMENU_BROKER_SERVICES(可重啟的 broker,主機:服務名)${C0}"; return 1; }
  dd OPMENU_HOSTS "$(_hosts_of $OPMENU_BROKER_SERVICES ${OPMENU_AUX_SERVICES:-} ${OPMENU_CONTROLLER_HOSTS:-})"
  n=$(printf '%s\n' $OPMENU_BROKER_SERVICES | wc -l)
  if [ "${OP_SRC[OPMENU_REPLICATION]:-}" = default ] && [ "$n" -lt "$OPMENU_REPLICATION" ]; then OPMENU_REPLICATION=$n; OP_SRC[OPMENU_REPLICATION]=derived; export OPMENU_REPLICATION; fi
  return 0
}

# ── 選單畫面與迴圈 ──
menu() {
  while true; do
    echo; echo "${CB}=== Kafka 維運操作選單  [${CR}${OPMENU_ENV_LABEL}${C0}${CB}]  操作者:${OP_USER} ===${C0}"
    [ -n "${OP_MENU_NOTE:-}" ] && echo "${CY}${OP_MENU_NOTE}${C0}"
    local t id
    for t in 1 2 3 4; do
      local any=0
      for id in "${ACT_IDS[@]}"; do [ "${ACT_TIER[$id]}" = "$t" ] || continue; [ "${OP_VISIBLE[$id]:-1}" = 1 ] || continue; [ $any = 0 ] && { echo "${CC}-- ${TIER_NAME[$t]} --${C0}"; any=1; }
        printf '  %s  %s%s\n' "$id" "${ACT_TITLE[$id]}" "$([ "${ACT_CHANGE[$id]}" = y ] && echo '  (變更)')"; done
    done
    echo "  0  離開"
    local sel rc; read -r "${OP_READ_TIMEOUT[@]}" "${OP_READ_EDIT[@]}" -p "請選擇: " sel; rc=$?
    if [ $rc -gt 128 ]; then echo; echo "閒置逾時,登出"; return; elif [ $rc -ne 0 ]; then echo; echo "讀不到輸入,登出"; return; fi   # read 逾時回傳 >128;EOF 回傳 1
    sel="$(printf '%s' "$sel" | tr -cd '0-9')"   # 只取數字:方向鍵的跳脫序列、\r、空白都丟掉
    [ -z "$sel" ] && continue
    [ "$sel" = 0 ] && return
    core_run "$sel"
  done
}

main() {
  if [ "${1:-}" = -c ]; then   # 當登入殼層時,ssh/su 送來的 "-c <指令>" 一律不執行,直接進選單
    [ -n "${SSH_ORIGINAL_COMMAND:-}" ] && core_log_pre_login BYPASS_ATTEMPT "ssh 指令被擋" "$SSH_ORIGINAL_COMMAND"
    set --
  fi
  if [ "${1:-}" = --list ]; then local id; for id in "${ACT_IDS[@]}"; do printf '%s\t%s\t%s\t%s\t%s\n' "$id" "${TIER_NAME[${ACT_TIER[$id]}]}" "${ACT_CHANGE[$id]}" "${ACT_CONFIRM[$id]}" "${ACT_TITLE[$id]}"; done; exit 0; fi
  if [ "${1:-}" = --run ]; then
    shift; login; core_menu_permissions
    if [ "${1:-}" = menu ]; then local id v=""; for id in "${ACT_IDS[@]}"; do [ "${OP_VISIBLE[$id]}" = 1 ] && v+="$id "; done; printf '@@MENU@@ %s\n' "${v% }"; exit 0; fi
    core_run "$@"; exit $?
  fi
  OP_READ_TIMEOUT=(); if [ "${OPMENU_IDLE_TIMEOUT:-0}" -gt 0 ] && [[ "$OSTYPE" != msys* && "$OSTYPE" != cygwin* ]]; then OP_READ_TIMEOUT=(-t "$OPMENU_IDLE_TIMEOUT"); fi   # Git Bash 的 read -t 對終端機會立刻 EOF,那裡不用
  OP_READ_EDIT=(); [ -t 0 ] && OP_READ_EDIT=(-e)
  login; core_log LOGIN "login" ""; core_menu_permissions; menu; core_log LOGOUT "logout" ""
}
main "$@"
