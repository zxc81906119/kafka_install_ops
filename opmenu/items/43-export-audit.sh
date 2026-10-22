item 43 4 y n "匯出 audit 紀錄" "匯出最近 N 分鐘的紀錄到檔案,交給 auditor(需 audit topic 與 audit- consumer group prefix 的 DeveloperRead)"
run() {
  local mins="${1:-60}"; v_number "$mins" "分鐘" || return 1
  local f="$OPMENU_OUT_DIR/audit-$(date +%Y%m%d-%H%M%S)-$OP_USER.jsonl"
  k_audit_fetch "$mins" "$f"
  local c; c=$(grep -c '"type"' "$f"); [ "$c" -gt 0 ] || { echo "最近 $mins 分鐘沒有讀到紀錄(或沒有權限)"; return 1; }
  echo "已匯出最近 $mins 分鐘共 $c 筆:$f"
}
