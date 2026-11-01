# 參數(非互動):<分鐘> [主體|-] [DENIED|ALLOWED|-] [save|-] [normal|sensitive|all(預設 normal)];互動時沒給參數就逐項問
run_43() {
  local mins="${1:-}" who="${2:-}" res="${3:-}" save="${4:-}" which="${5:-}"
  if [ $# -eq 0 ] && [ -t 0 ]; then
    read -r -p "最近幾分鐘 [60]: " mins
    read -r -p "主體(例 alice、User:app-orders-a;空 = 全部): " who
    read -r -p "結果(DENIED、ALLOWED;空 = 全部): " res
    [ -z "${OPMENU_AUDIT_SENSITIVE_TOPIC:-}" ] || { read -r -p "看哪一個:1) 一般  2) 敏感(_sensitive)  3) 兩個都看 [1]: " which; case "$which" in 2) which=sensitive;; 3) which=all;; *) which=normal;; esac; }
  fi
  mins="${mins:-60}"; [ "$who" = - ] && who=""; [ "$res" = - ] && res=""; [ "$save" = - ] && save=""; which="${which:-normal}"
  v_number "$mins" "分鐘" || return 1
  if [ -n "$who" ]; then [[ "$who" == *:* ]] || who="User:$who"; v_principal "$who" || return 1; fi
  [ -z "$res" ] || v_in "$res" "DENIED ALLOWED" "結果" || return 1
  [ -z "$save" ] || v_in "$save" "save" "第 4 個參數" || return 1
  v_in "$which" "normal sensitive all" "第 5 個參數" || return 1
  local topics=()
  case "$which" in normal) topics=("$OPMENU_AUDIT_TOPIC");; sensitive) topics=("$OPMENU_AUDIT_SENSITIVE_TOPIC");; all) topics=("$OPMENU_AUDIT_TOPIC" "$OPMENU_AUDIT_SENSITIVE_TOPIC");; esac
  local x; for x in "${topics[@]}"; do [ -n "$x" ] || { echo "沒有設定 OPMENU_AUDIT_SENSITIVE_TOPIC(這個環境沒有分敏感 topic)"; return 1; }; done
  local f sel; f="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"; sel="$f.sel"
  k_audit_fetch "$mins" "$f" "${topics[@]}"
  [ -s "$f" ] || { rm -f "$f"; echo "最近 $mins 分鐘沒有讀到紀錄(或沒有權限)"; return 1; }
  if [ -n "$who" ]; then grep -iF "\"principal\":\"$who\"" "$f" > "$sel" || true; else cp "$f" "$sel"; fi
  case "$res" in DENIED) grep -F '"granted":false' "$sel" > "$f" || true;; ALLOWED) grep -F '"granted":true' "$sel" > "$f" || true;; *) cp "$sel" "$f";; esac
  local n; n=$(wc -l < "$f")
  echo "最近 $mins 分鐘符合 $n 筆(${topics[*]})${who:+(主體 $who)}${res:+(結果 $res)};顯示最後 50 筆:"
  local line t pr m op rn g
  tail -50 "$f" | while IFS= read -r line; do
    t=$(printf '%s' "$line" | grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4); pr=$(printf '%s' "$line" | grep -o '"principal":"[^"]*"' | head -1 | cut -d'"' -f4)
    m=$(printf '%s' "$line" | grep -o '"methodName":"[^"]*"' | head -1 | cut -d'"' -f4); op=$(printf '%s' "$line" | grep -o '"operation":"[^"]*"' | head -1 | cut -d'"' -f4)
    rn=$(printf '%s' "$line" | grep -o '"resourceName":"[^"]*"' | tail -1 | cut -d'"' -f4); g=$(printf '%s' "$line" | grep -o '"granted":[a-z]*' | head -1 | cut -d: -f2)
    t=$(date -d "$t" '+%F %T' 2>/dev/null || echo "${t%%.*}")   # 事件時間是 UTC,畫面改成操作機的本地時間
    printf '%s %-16s %-20s %-14s %-26s %s\n' "$t" "$pr" "$m" "$op" "$rn" "$([ "$g" = true ] && echo ALLOWED || echo DENIED)"
  done
  if [ -z "$save" ] && [ "$n" -gt 0 ] && [ -t 0 ]; then local a; read -r -p "把這 $n 筆存成檔案交給 auditor 嗎?[y/N]: " a; [ "$a" = y ] && save=save; fi
  local rc=0
  if [ "$save" = save ] && [ "$n" -gt 0 ]; then
    local out="$OPMENU_OUT_DIR/audit-$(date +%Y%m%d-%H%M%S)-$OP_USER.jsonl"
    if ( umask 027; cp "$f" "$out" ); then echo "已匯出 $n 筆:$out"; else echo "存檔失敗:$out"; rc=1; fi
  fi
  rm -f "$f" "$sel"
  return $rc
}
