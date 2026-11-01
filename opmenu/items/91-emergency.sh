_emergency_ok() { # _emergency_ok <工具> <參數...>:工具要在清單內;參數中屬於「動作」的選項都要在該工具允許的動作內;不得覆寫連線設定
  local tool="$1"; shift; v_tool "$tool" || return 1
  local allowed="" e; for e in $OPMENU_EMERGENCY_ACTIONS; do [ "${e%%=*}" = "$tool" ] && allowed="${e#*=}"; done
  [ -n "$allowed" ] || { echo "緊急模式沒有為 $tool 定義允許的動作(OPMENU_EMERGENCY_ACTIONS)"; return 1; }
  local a found=0; for a in "$@"; do
    case "$a" in --bootstrap-server|--command-config|--bootstrap-controller) echo "緊急模式不允許覆寫連線設定($a)"; return 1;; esac
    case "$a" in --list|--describe|--create|--alter|--delete|--add|--remove|--reset-offsets|--execute|--generate|--verify|describe|add|remove) found=1; v_in "$a" "${allowed//,/ }" "$tool 的動作" || return 1;; esac
  done
  [ $found = 1 ] || { echo "緊急模式的參數必須包含一個動作(例如 --list、--describe)"; return 1; }
}
run_91() {
  local tool="${1:-}"; [ -n "$tool" ] || read -r -p "要執行的 Kafka 工具(例 kafka-topics): " tool
  local args=("${@:2}"); if [ ${#args[@]} = 0 ]; then read -r -p "參數: " -a args; fi
  _emergency_ok "$tool" "${args[@]}" || return 1
  local reason="${OPMENU_REASON:-}"; [ -n "$reason" ] || read -r -p "原因(必填,會記錄): " reason
  [ -n "$reason" ] || { echo "緊急模式必須填原因"; return 1; }
  core_confirm "以備用憑證(SystemAdmin)執行:$tool ${args[*]}(原因:$reason)" || return 1
  core_log EMERGENCY "91 breakglass" "$tool ${args[*]} | 原因=$reason"
  be_bootstrap_kafka "$tool" "${args[@]}"
}
