# 項目 43：查詢與匯出稽核紀錄
#
# 做什麼：讀稽核 topic 最近 N 分鐘的事件，可以只看某個身分、只看被拒（DENIED）或被允許（ALLOWED）的；
#   畫面顯示最後 50 筆，可以把符合的全部存成檔案交給 auditor。
#   可以選看一般稽核、敏感稽核（_sensitive，例如讀寫稽核 topic 本身），或兩個都看。
#   非互動用法：--run 43 <分鐘> [主體|-] [DENIED|ALLOWED|-] [save|-] [normal|sensitive|all]（- 代表不篩選；第 5 個預設 normal）
# 用到的設定（opmenu.conf）：
#   OPMENU_AUDIT_TOPIC             一般稽核 topic
#   OPMENU_AUDIT_SENSITIVE_TOPIC   敏感稽核 topic（沒有分的環境留空）
#   OPMENU_OUT_DIR                 匯出檔放哪裡
# 用到的共用函式：
#   v_number、v_principal、v_in    檢查輸入（lib/common.sh）
#   k_audit_fetch                  讀稽核 topic，留下最近 N 分鐘的事件（lib/kafka.sh）
# 改的時候要注意：
#   - 稽核事件是一行一個 JSON；篩選用 grep 找固定的欄位寫法（"principal":"…"、"granted":true／false）。
#   - 事件時間是 UTC，畫面改成操作機的本地時間。

run_43() {
  local minutes="${1:-}"
  local who="${2:-}"
  local result="${3:-}"
  local save="${4:-}"
  local which="${5:-}"

  # 1. 互動（沒給任何參數、而且是在終端機上）：逐項問
  if [ $# -eq 0 ] && [ -t 0 ]; then
    read -r -p "最近幾分鐘 [60]: " minutes
    read -r -p "主體(例 alice、User:app-orders-a;空 = 全部): " who
    read -r -p "結果(DENIED、ALLOWED;空 = 全部): " result

    if [ -n "${OPMENU_AUDIT_SENSITIVE_TOPIC:-}" ]; then
      read -r -p "看哪一個:1) 一般  2) 敏感(_sensitive)  3) 兩個都看 [1]: " which
      case "$which" in
        2) which=sensitive ;;
        3) which=all ;;
        *) which=normal ;;
      esac
    fi
  fi

  # 2. 預設值與「-」（= 不篩選）
  if [ -z "$minutes" ]; then
    minutes=60
  fi
  if [ "$who" = - ]; then
    who=""
  fi
  if [ "$result" = - ]; then
    result=""
  fi
  if [ "$save" = - ]; then
    save=""
  fi
  if [ -z "$which" ]; then
    which=normal
  fi

  # 3. 檢查輸入（主體沒寫 User: 或 Group: 的，當成 User:）
  if ! v_number "$minutes" "分鐘"; then
    return 1
  fi

  if [ -n "$who" ]; then
    case "$who" in
      *:*) ;;
      *) who="User:$who" ;;
    esac

    if ! v_principal "$who"; then
      return 1
    fi
  fi

  if [ -n "$result" ]; then
    if ! v_in "$result" "DENIED ALLOWED" "結果"; then
      return 1
    fi
  fi

  if [ -n "$save" ]; then
    if ! v_in "$save" "save" "第 4 個參數"; then
      return 1
    fi
  fi

  if ! v_in "$which" "normal sensitive all" "第 5 個參數"; then
    return 1
  fi

  # 4. 要讀哪幾個 topic
  local topics
  case "$which" in
    normal)    topics="$OPMENU_AUDIT_TOPIC" ;;
    sensitive) topics="$OPMENU_AUDIT_SENSITIVE_TOPIC" ;;
    all)       topics="$OPMENU_AUDIT_TOPIC $OPMENU_AUDIT_SENSITIVE_TOPIC" ;;
  esac

  if [ "$which" != normal ] && [ -z "${OPMENU_AUDIT_SENSITIVE_TOPIC:-}" ]; then
    echo "沒有設定 OPMENU_AUDIT_SENSITIVE_TOPIC(這個環境沒有分敏感 topic)"
    return 1
  fi

  # 5. 讀最近 N 分鐘的事件到暫存檔
  local events selected
  events="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"
  selected="$events.sel"

  k_audit_fetch "$minutes" "$events" $topics

  if [ ! -s "$events" ]; then
    rm -f "$events"
    echo "最近 $minutes 分鐘沒有讀到紀錄(或沒有權限)"
    return 1
  fi

  # 6. 篩選主體
  if [ -n "$who" ]; then
    grep -iF "\"principal\":\"$who\"" "$events" > "$selected"
  else
    cp "$events" "$selected"
  fi

  # 7. 篩選結果（篩完的結果放回 events）
  case "$result" in
    DENIED)  grep -F '"granted":false' "$selected" > "$events" ;;
    ALLOWED) grep -F '"granted":true' "$selected" > "$events" ;;
    *)       cp "$selected" "$events" ;;
  esac

  # 8. 印最後 50 筆
  local count filters=""
  count=$(wc -l < "$events")

  if [ -n "$who" ]; then
    filters="$filters(主體 $who)"
  fi
  if [ -n "$result" ]; then
    filters="$filters(結果 $result)"
  fi

  echo "最近 $minutes 分鐘符合 $count 筆($topics)$filters;顯示最後 50 筆:"

  local line
  tail -50 "$events" | while IFS= read -r line; do
    _item43_print_event "$line"
  done

  # 9. 要不要存檔（互動時才問）
  if [ -z "$save" ] && [ "$count" -gt 0 ] && [ -t 0 ]; then
    local answer
    read -r -p "把這 $count 筆存成檔案交給 auditor 嗎?[y/N]: " answer

    if [ "$answer" = y ]; then
      save=save
    fi
  fi

  local rc=0
  if [ "$save" = save ] && [ "$count" -gt 0 ]; then
    local out="$OPMENU_OUT_DIR/audit-$(date +%Y%m%d-%H%M%S)-$OP_USER.jsonl"

    # 存檔的權限是 0640（umask 027）
    if ( umask 027; cp "$events" "$out" ); then
      echo "已匯出 $count 筆:$out"
    else
      echo "存檔失敗:$out"
      rc=1
    fi
  fi

  rm -f "$events" "$selected"
  return $rc
}

# _item43_print_event <一行 JSON>：從一筆稽核事件取出時間、主體、方法、操作、資源、結果，印成一行
#
# 輸入（一行 JSON，這裡只列用到的欄位），例如：
#   {"time":"2026-11-01T01:02:03.456Z", … "principal":"User:alice", … "methodName":"kafka.CreateTopics",
#    "operation":"Create", … "resourceName":"orders.new", … "granted":false …}
# 輸出，例如：
#   2026-11-01 09:02:03 User:alice       kafka.CreateTopics   Create         orders.new                 DENIED
_item43_print_event() {
  local line="$1"
  local time principal method operation resource granted verdict

  time=$(echo "$line" | grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4)
  principal=$(echo "$line" | grep -o '"principal":"[^"]*"' | head -1 | cut -d'"' -f4)
  method=$(echo "$line" | grep -o '"methodName":"[^"]*"' | head -1 | cut -d'"' -f4)
  operation=$(echo "$line" | grep -o '"operation":"[^"]*"' | head -1 | cut -d'"' -f4)
  resource=$(echo "$line" | grep -o '"resourceName":"[^"]*"' | tail -1 | cut -d'"' -f4)
  granted=$(echo "$line" | grep -o '"granted":[a-z]*' | head -1 | cut -d: -f2)

  # 事件時間是 UTC，換成操作機的本地時間；換不了就去掉小數點後面
  local local_time
  local_time=$(date -d "$time" '+%F %T' 2>/dev/null)
  if [ -z "$local_time" ]; then
    local_time=$(echo "$time" | cut -d. -f1)
  fi

  verdict=DENIED
  if [ "$granted" = true ]; then
    verdict=ALLOWED
  fi

  printf '%s %-16s %-20s %-14s %-26s %s\n' "$local_time" "$principal" "$method" "$operation" "$resource" "$verdict"
}
