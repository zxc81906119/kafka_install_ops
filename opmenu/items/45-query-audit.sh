item 45 4 y n "查詢 audit 紀錄(依主體、結果篩選)" "最近 N 分鐘的 audit 事件,可依主體(例 alice)與結果(DENIED 或 ALLOWED)篩選,畫面顯示最後 50 筆;需要 audit topic 的 DeveloperRead(同 43)"
run() {
  local mins="${1:-60}" who="${2:-}" res="${3:-}"; v_number "$mins" "分鐘" || return 1
  if [ -n "$who" ]; then [[ "$who" == *:* ]] || who="User:$who"; v_principal "$who" || return 1; fi
  [ -z "$res" ] || v_in "$res" "DENIED ALLOWED" "結果" || return 1
  local f sel; f="$(mktemp "$OPMENU_TMPDIR/opmenu.$$.XXXXXXXX")"; sel="$f.sel"
  k_audit_fetch "$mins" "$f"
  [ -s "$f" ] || { rm -f "$f"; echo "最近 $mins 分鐘沒有讀到紀錄(或沒有權限)"; return 1; }
  if [ -n "$who" ]; then grep -iF "\"principal\":\"$who\"" "$f" > "$sel" || true; else cp "$f" "$sel"; fi
  case "$res" in DENIED) grep -F '"granted":false' "$sel" > "$f" || true;; ALLOWED) grep -F '"granted":true' "$sel" > "$f" || true;; *) cp "$sel" "$f";; esac
  echo "最近 $mins 分鐘符合 $(wc -l < "$f") 筆${who:+(主體 $who)}${res:+(結果 $res)};顯示最後 50 筆:"
  local line t pr m op rn g
  tail -50 "$f" | while IFS= read -r line; do
    t=$(printf '%s' "$line" | grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4); pr=$(printf '%s' "$line" | grep -o '"principal":"[^"]*"' | head -1 | cut -d'"' -f4)
    m=$(printf '%s' "$line" | grep -o '"methodName":"[^"]*"' | head -1 | cut -d'"' -f4); op=$(printf '%s' "$line" | grep -o '"operation":"[^"]*"' | head -1 | cut -d'"' -f4)
    rn=$(printf '%s' "$line" | grep -o '"resourceName":"[^"]*"' | tail -1 | cut -d'"' -f4); g=$(printf '%s' "$line" | grep -o '"granted":[a-z]*' | head -1 | cut -d: -f2)
    printf '%s %-16s %-20s %-14s %-26s %s\n' "${t%%.*}" "$pr" "$m" "$op" "$rn" "$([ "$g" = true ] && echo ALLOWED || echo DENIED)"
  done
  rm -f "$f" "$sel"
}
