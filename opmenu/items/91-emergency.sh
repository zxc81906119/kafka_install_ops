# 項目 91：緊急模式（以備用憑證執行一個指令）
#
# 做什麼：一般權限處理不了時，用備用憑證（User:svc-ops，SystemAdmin）跑一個 Kafka 工具指令。
#   工具與動作只限 OPMENU_EMERGENCY_ACTIONS 列的；必填原因；每一次都記一筆 EMERGENCY；事後必須檢討。
#   憑證從操作機上 0600 的檔案讀（OPMENU_BREAKGLASS_PEM），用完即丟。
# 用到的設定（opmenu.conf）：
#   OPMENU_EMERGENCY_TOOLS   可以用的工具（例如 kafka-topics kafka-configs …）
#   OPMENU_EMERGENCY_ACTIONS 每個工具允許的動作，格式「工具=動作,動作」，例如 kafka-topics=--list,--describe
#   OPMENU_BREAKGLASS_PEM    備用憑證（私鑰＋憑證鏈）的檔案路徑
# 用到的共用函式：
#   v_tool、v_in             檢查工具與動作在清單內（lib/common.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   core_log                 寫 EMERGENCY 紀錄（lib/common.sh）
#   be_bootstrap_kafka       用備用憑證跑 Kafka 工具（lib/kafka.sh）
# 改的時候要注意：
#   - 選單框架（core_run）會先確認「本人」有管理員權限（OPMENU_ADMIN_ITEMS 列了 91），才會走到這裡。
#   - 不允許參數裡改連線設定（--bootstrap-server 等），免得連到別的叢集或換掉身分。

run_91() {
  local tool="${1:-}"

  # 1. 問工具
  if [ -z "$tool" ]; then
    read -r -p "要執行的 Kafka 工具(例 kafka-topics): " tool
  fi

  # 2. 工具後面的參數（從 --run 帶進來的，或互動時輸入一行；read -a 會把那一行切成一個一個參數）
  local args=()
  if [ $# -ge 2 ]; then
    shift
    args=("$@")
  else
    read -r -p "參數: " -a args
  fi

  # 3. 檢查工具與動作都在允許的清單內
  if ! _item91_allowed "$tool" "${args[@]}"; then
    return 1
  fi

  # 4. 原因（必填）
  local reason="${OPMENU_REASON:-}"
  if [ -z "$reason" ]; then
    read -r -p "原因(必填,會記錄): " reason
  fi

  if [ -z "$reason" ]; then
    echo "緊急模式必須填原因"
    return 1
  fi

  # 5. 確認、記 EMERGENCY、執行
  if ! core_confirm "以備用憑證(SystemAdmin)執行:$tool ${args[*]}(原因:$reason)"; then
    return 1
  fi

  core_log EMERGENCY "91 breakglass" "$tool ${args[*]} | 原因=$reason"
  be_bootstrap_kafka "$tool" "${args[@]}"
}

# _item91_allowed <工具> <參數...>：工具要在清單內；參數裡屬於「動作」的選項都要在這個工具允許的動作內；
#   不得覆寫連線設定；至少要有一個動作。不允許時印出原因、回傳 1。
#   例：OPMENU_EMERGENCY_ACTIONS 有 kafka-topics=--list,--describe 時，
#       kafka-topics --describe --topic x → 允許；kafka-topics --delete --topic x → 不允許
_item91_allowed() {
  local tool="$1"
  shift

  # 1. 工具要在清單內
  if ! v_tool "$tool"; then
    return 1
  fi

  # 2. 找出這個工具允許的動作（「工具=動作,動作」那一項，等號後面的部分，逗號換成空白）
  local entry allowed=""
  for entry in $OPMENU_EMERGENCY_ACTIONS; do
    if [ "$(echo "$entry" | cut -d= -f1)" = "$tool" ]; then
      allowed=$(echo "$entry" | cut -d= -f2- | tr ',' ' ')
    fi
  done

  if [ -z "$allowed" ]; then
    echo "緊急模式沒有為 $tool 定義允許的動作(OPMENU_EMERGENCY_ACTIONS)"
    return 1
  fi

  # 3. 逐一看參數：不能改連線設定；是「動作」的，要在允許的清單內
  local argument found_action=no
  local action_words="--list --describe --create --alter --delete --add --remove --reset-offsets"
  action_words="$action_words --execute --generate --verify describe add remove"

  for argument in "$@"; do
    case "$argument" in
      --bootstrap-server|--command-config|--bootstrap-controller)
        echo "緊急模式不允許覆寫連線設定($argument)"
        return 1
        ;;
    esac

    if _in_words "$argument" "$action_words"; then
      found_action=yes
      if ! v_in "$argument" "$allowed" "$tool 的動作"; then
        return 1
      fi
    fi
  done

  # 4. 至少要有一個動作
  if [ "$found_action" = no ]; then
    echo "緊急模式的參數必須包含一個動作(例如 --list、--describe)"
    return 1
  fi

  return 0
}
