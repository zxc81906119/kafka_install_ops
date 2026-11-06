#!/usr/bin/env bash
# Kafka 維運操作選單(OP menu)— 進入點:載入設定與共用程式、登入、顯示選單、迴圈。
#
# 結構:
#   /etc/opmenu/opmenu.conf   這個環境的設定(連線位址、主機、命名規範);換環境只改這裡。範本見 opmenu.conf.example
#   lib/defaults.sh           所有設定項目與預設值(說明文件兼保險;opmenu.conf 沒設的才用它)
#   lib/common.sh             共用:項目登記、紀錄、確認、輸入驗證、執行流程、主機權限閘門、ssh 金鑰檔檢查
#   lib/kafka.sh              共用:以操作者身分跑 Kafka 工具、呼叫 MDS;91 用操作機上的緊急憑證檔
#   lib/hosts.sh              共用:ssh 到各主機重啟、看日誌、磁碟、診斷
#   lib/secrets/file.sh       91 緊急憑證從哪裡取:操作機上 root 才讀得到的檔案(預設 ~/secrets/svc-ops.pem,0600)
#   items/menu.list           選單對照表:每個項目一行(編號、層級、變更類、要確認、檔案、標題、說明);要加項目或改標題改這裡
#   items/<編號>-<名稱>.sh     每個選單項目一個檔:裡面的 run_<編號> 函式做事(例 items/21-restart-broker.sh 的 run_21)
#
# 用法:
#   opmenu.sh                     互動選單
#   opmenu.sh --list              列出所有項目
#   opmenu.sh --run 12 [參數]     直接執行一個項目(測試、排程用);--run menu 只印本人看得到的編號
#   環境變數(只在 OPMENU_ALLOW_ENV_OVERRIDE=1 時接受):OPMENU_USER / OPMENU_PASS(操作者 AD 帳密)、OPMENU_YES=1(略過確認)、OPMENU_REASON
set -uo pipefail

# 這支腳本所在目錄的絕對路徑
_script_dir=$(dirname "${BASH_SOURCE[0]}")
OPMENU_HOME=$(
  if cd "$_script_dir"; then
    pwd
  fi
)
unset _script_dir
export OPMENU_HOME

# ── 載入設定與共用程式 ──
# 設定檔：OPMENU_CONF 指定的、/etc/opmenu/opmenu.conf、程式目錄裡的 opmenu.conf，用找到的第一個
for _conf in "${OPMENU_CONF:-}" /etc/opmenu/opmenu.conf "$OPMENU_HOME/opmenu.conf"; do
  if [ -n "$_conf" ] && [ -f "$_conf" ]; then
    . "$_conf"
    break
  fi
done
unset _conf

. "$OPMENU_HOME/lib/defaults.sh"
. "$OPMENU_HOME/lib/common.sh"

# 測試用的環境變數（帳密、略過確認、原因）只在設定檔明確允許時才接受
if [ "${OPMENU_ALLOW_ENV_OVERRIDE:-0}" != 1 ]; then
  unset OPMENU_USER OPMENU_PASS OPMENU_YES OPMENU_REASON
fi

. "$OPMENU_HOME/lib/kafka.sh"
. "$OPMENU_HOME/lib/hosts.sh"

if ! . "$OPMENU_HOME/lib/secrets/file.sh"; then
  echo "找不到 lib/secrets/file.sh"
  exit 1
fi

# 讀選單對照表 items/menu.list、載入每個項目檔
if ! load_items "$OPMENU_HOME/items"; then
  exit 1
fi

# ── 登入 ──
# login：操作者本人的 AD 帳密 → 向 MDS 換 token；產生只有自己讀得到的 Kafka 連線設定檔（記憶體檔案系統）；推算沒填的設定
#   MDS 連不上時改走緊急主機模式（emergency_login）；帳密不對就結束
login() {
  local password="${OPMENU_PASS:-}"

  OP_SID="$(date +%s)-$$"   # 這次登入的編號（紀錄裡的 sid）

  # 1. 帳號：設定成「用作業系統登入帳號」就直接用；否則請操作者輸入 AD 帳號
  if [ "${OPMENU_USER_FROM_OS:-0}" = 1 ]; then
    OP_USER="$(id -un)"
    echo "操作者(作業系統登入帳號):$OP_USER"
  else
    OP_USER="${OPMENU_USER:-}"
    if [ -z "$OP_USER" ]; then
      read -r -p "AD 帳號: " OP_USER
    fi

    if ! [[ "$OP_USER" =~ ^[A-Za-z0-9._@-]{1,64}$ ]]; then
      echo "${CR}帳號含不允許的字元${C0}"
      exit 1
    fi
  fi

  # 2. 密碼（輸入時不顯示）
  if [ -z "$password" ]; then
    read -r -s -p "AD 密碼: " password
    echo
  fi

  # 3. 暫存檔：之後建的檔案都只有自己讀得到；先清掉上次被強制結束留下的
  umask 077
  core_sweep_residue
  OP_CLIENT_CONF="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"
  OP_LAST_RAW="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"

  # 離開時（正常結束、Ctrl+C、被終止、斷線）一律清理
  trap core_cleanup EXIT
  trap 'core_cleanup; exit 130' INT
  trap 'core_cleanup; exit 143' TERM
  trap 'core_cleanup; exit 129' HUP

  # 4. Kafka 連線設定：用 AD 帳密走 LDAP listener（SASL PLAIN over TLS）
  cat > "$OP_CLIENT_CONF" <<EOC
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$OP_USER" password="$password";
ssl.truststore.location=$(be_truststore_path)
ssl.truststore.type=PKCS12
ssl.truststore.password=$(be_truststore_password)
EOC

  # 5. 向 MDS 換 token：2 = MDS 連不上（改走緊急主機模式）；其他非 0 = 帳密不對
  local login_rc
  OP_TOKEN="$(be_mds_login "$OP_USER" "$password")"
  login_rc=$?

  if [ $login_rc -eq 2 ]; then
    unset password
    emergency_login   # 進不了緊急主機模式時，裡面會直接結束
    return 0
  fi

  if [ $login_rc -ne 0 ]; then
    echo "${CR}登入失敗:帳號或密碼不正確。${C0}"
    core_log AUTH_FAIL login ""
    exit 1
  fi

  # 登入不分大小寫，但 MDS 查權限時 userPrincipal 要和 token 的身分完全一致：
  #   之後一律用 token 的 sub（AD 回傳的寫法），查權限和紀錄才會和 Kafka 稽核日誌記的身分相同
  if ! OP_USER=$(token_subject "$OP_TOKEN"); then
    echo "${CR}登入失敗:token 裡沒有帳號資訊。${C0}"
    core_log AUTH_FAIL login "token 沒有 sub"
    exit 1
  fi

  OP_TOKEN_AT=$(date +%s)

  # 6. 推算沒填的設定（cluster ID、主機清單…）
  if ! derive; then
    core_log DERIVE_FAIL login ""
    exit 1
  fi

  unset password
  export OP_USER OP_CLIENT_CONF OP_LAST_RAW OP_TOKEN OP_TOKEN_AT OP_SID
}

# emergency_login：緊急主機模式。MDS 連不上時，AD 身分驗證與權限查詢都做不了。
#   不看任何群組：操作者都是經 PSMP 登入的 root，作業系統群組擋不住（root 能自己加入），所以 2026-10-29 定案直接開放（OPMENU_EMERGENCY_HOST=0 可關）。
#   只能做 OPMENU_EMERGENCY_ITEMS 這幾個主機類項目，必填原因；操作者標成「未經 AD 驗證」，每一筆紀錄都看得出是緊急模式（紀錄也送 syslog 時，共用帳號改不到）。
emergency_login() {
  core_log MDS_DOWN login ""
  echo "${CR}無法連到 MDS（Kafka 的權限服務），AD 登入做不了。${C0}"
  echo "Kafka 類的緊急操作（topic、設定、SCRAM 帳號）改用手把手 28.6 的 kafka-admin（SCRAM,9095,不經 MDS 與 AD）；用過當天照 20.2 換密碼。"

  # 1. 設定關掉了就結束
  if [ "${OPMENU_EMERGENCY_HOST:-1}" != 1 ]; then
    echo "緊急主機模式已關閉（OPMENU_EMERGENCY_HOST=0）：請確認 cluster 狀態或通知管理員。"
    core_log DENIED "emergency host mode" "disabled"
    exit 1
  fi

  # 2. 原因（至少 4 個字）
  local reason="${OPMENU_REASON:-}"
  if [ -z "$reason" ]; then
    read -r -p "緊急主機模式：請輸入原因（事故單號或說明）: " reason
  fi

  if [ ${#reason} -lt 4 ]; then
    echo "原因太短，不進入緊急主機模式"
    exit 1
  fi

  # 3. ssh 允許的主機清單（不用 MDS）
  if ! derive_local; then
    exit 1
  fi

  # 4. 標成緊急模式、記紀錄
  OP_EMERGENCY_HOST=1
  OP_USER="$OP_USER(緊急,未經AD驗證)"
  export OP_EMERGENCY_HOST OP_USER OP_CLIENT_CONF OP_LAST_RAW OP_SID

  core_log EMERGENCY_HOST login "$reason"
  echo "${CY}已進入緊急主機模式：只能做 $OPMENU_EMERGENCY_ITEMS（看日誌、磁碟、收集診斷、重啟服務）；每一步都留紀錄。${C0}"
}

# derive：登入後推算沒填的設定（opmenu.conf 有填的一律優先）
#   刻意不從 cluster 推算 broker 與主機清單：它們是重啟、ssh 的允許清單，必須是審過的固定設定
derive() {
  local id

  # cluster ID 沒填：問 MDS
  if [ -z "${OPMENU_KAFKA_CLUSTER_ID:-}" ]; then
    id="$(be_cluster_id)"

    if [ -z "$id" ]; then
      echo "${CR}無法從 MDS 取得 cluster ID,請在 opmenu.conf 設定 OPMENU_KAFKA_CLUSTER_ID${C0}"
      return 1
    fi

    dd OPMENU_KAFKA_CLUSTER_ID "$id"
  fi

  derive_local
}

# derive_local：只靠設定檔就算得出來的部分（不用 MDS），緊急主機模式也要做：
#   ssh 允許的主機清單 OPMENU_HOSTS（broker、輔助服務、controller 的主機）、replication factor 上限（不超過 broker 台數）
derive_local() {
  local broker_count

  if [ -z "${OPMENU_BROKER_SERVICES:-}" ]; then
    echo "${CR}請在 opmenu.conf 設定 OPMENU_BROKER_SERVICES(可重啟的 broker,主機:服務名)${C0}"
    return 1
  fi

  dd OPMENU_HOSTS "$(_hosts_of $OPMENU_BROKER_SERVICES ${OPMENU_AUX_SERVICES:-} ${OPMENU_CONTROLLER_HOSTS:-})"

  # replication factor 用預設值、而且 broker 台數比它少：降成台數
  broker_count=$(echo $OPMENU_BROKER_SERVICES | wc -w)

  if [ "${OP_SRC[OPMENU_REPLICATION]:-}" = default ] && [ "$broker_count" -lt "$OPMENU_REPLICATION" ]; then
    OPMENU_REPLICATION=$broker_count
    OP_SRC[OPMENU_REPLICATION]=derived
    export OPMENU_REPLICATION
  fi

  return 0
}

# ── 選單畫面與迴圈 ──
# show_menu：印出選單。依層級分四區（值班查看、服務操作、變更作業、授權與緊急），每區只印這個人看得到的項目
show_menu() {
  local tier id mark printed_header

  echo
  echo "${CB}=== Kafka 維運操作選單  [${CR}${OPMENU_ENV_LABEL}${C0}${CB}]  操作者:${OP_USER} ===${C0}"

  if [ -n "${OP_MENU_NOTE:-}" ]; then
    echo "${CY}${OP_MENU_NOTE}${C0}"
  fi

  for tier in 1 2 3 4; do
    printed_header=no

    for id in "${ACT_IDS[@]}"; do
      # 不是這一區的、看不到的（緊急主機模式）就跳過
      if [ "${ACT_TIER[$id]}" != "$tier" ]; then
        continue
      fi

      if [ "${OP_VISIBLE[$id]:-1}" != 1 ]; then
        continue
      fi

      # 這一區的第一個項目之前，先印區名
      if [ "$printed_header" = no ]; then
        echo "${CC}-- ${TIER_NAME[$tier]} --${C0}"
        printed_header=yes
      fi

      # 變更類的項目後面標「(變更)」
      mark=""
      if [ "${ACT_CHANGE[$id]}" = y ]; then
        mark="  (變更)"
      fi

      echo "  $id  ${ACT_TITLE[$id]}$mark"
    done
  done

  echo "  0  離開"
}

# menu：選單迴圈。印選單 → 讀編號 → 執行 → 再印選單，直到輸入 0、閒置逾時或讀不到輸入
menu() {
  local selection rc

  while true; do
    show_menu
    read -r "${OP_READ_TIMEOUT[@]}" "${OP_READ_EDIT[@]}" -p "請選擇: " selection
    rc=$?

    # read 逾時的結束碼大於 128；讀到檔尾（例如連線斷了）是 1
    if [ $rc -gt 128 ]; then
      echo
      echo "閒置逾時,登出"
      return
    fi

    if [ $rc -ne 0 ]; then
      echo
      echo "讀不到輸入,登出"
      return
    fi

    # 只留數字：方向鍵的跳脫序列、\r、空白都丟掉
    selection=$(echo "$selection" | tr -cd '0-9')
    if [ -z "$selection" ]; then
      continue
    fi

    if [ "$selection" = 0 ]; then
      return
    fi

    core_run "$selection"
  done
}

# list_items：--list 用，每個項目一行：編號、層級名稱、變更類、要確認、標題（用 tab 隔開）
list_items() {
  local id
  for id in "${ACT_IDS[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$id" \
      "${TIER_NAME[${ACT_TIER[$id]}]}" \
      "${ACT_CHANGE[$id]}" \
      "${ACT_CONFIRM[$id]}" \
      "${ACT_TITLE[$id]}"
  done
}

# print_visible_items：--run menu 用，印出這個人看得到的編號（測試用）
print_visible_items() {
  local id visible=""
  for id in "${ACT_IDS[@]}"; do
    if [ "${OP_VISIBLE[$id]}" = 1 ]; then
      visible="$visible $id"
    fi
  done
  echo "@@MENU@@$visible"
}

main() {
  # 選單當成登入殼層時，ssh／su 送來的 "-c <指令>" 一律不執行，直接進選單（並記下有人試著繞過）
  if [ "${1:-}" = -c ]; then
    if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
      core_log_pre_login BYPASS_ATTEMPT "ssh 指令被擋" "$SSH_ORIGINAL_COMMAND"
    fi
    set --
  fi

  # opmenu.sh --list：列出所有項目（不用登入）
  if [ "${1:-}" = --list ]; then
    list_items
    exit 0
  fi

  # opmenu.sh --run <編號> [參數...]：登入後直接執行一個項目（測試、排程用）
  if [ "${1:-}" = --run ]; then
    shift
    login
    core_menu_permissions   # 選單一律全顯示；這裡只處理緊急主機模式

    if [ "${1:-}" = menu ]; then
      print_visible_items
      exit 0
    fi

    core_run "$@"
    exit $?
  fi

  # 互動選單
  # 閒置逾時：Git Bash 的 read -t 對終端機會立刻讀到檔尾，所以在 Git Bash 上不用
  OP_READ_TIMEOUT=()
  if [ "${OPMENU_IDLE_TIMEOUT:-0}" -gt 0 ]; then
    case "$OSTYPE" in
      msys*|cygwin*) ;;
      *) OP_READ_TIMEOUT=(-t "$OPMENU_IDLE_TIMEOUT") ;;
    esac
  fi

  # 在終端機上輸入時，可以用方向鍵編輯（read -e）
  OP_READ_EDIT=()
  if [ -t 0 ]; then
    OP_READ_EDIT=(-e)
  fi

  login
  core_log LOGIN "login" ""

  core_menu_permissions
  menu

  core_log LOGOUT "logout" ""
}
main "$@"
