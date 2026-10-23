item 35 3 y y "輪替 service account 密碼（A／B）" "一個應用程式有 -a、-b 兩個帳號：只換「應用程式現在沒在用的那個」，換完請應用程式切過去，不中斷。新密碼寫進交接檔、不顯示（需 ClusterAdmin）"
# 單一帳號（沒有 -a／-b）的舊應用程式：改密碼會讓它的新連線立刻失敗，要明確確認；建議先用 34 建好 A／B 再遷移
run() {
  local base="${1:-}" in_use="${2:-}"
  [ -n "$base" ] || read -r -p "應用程式名稱（例 app-orders）: " base
  v_svc_acct "$base" || return 1
  core_handover_ready || return 1
  local suffix pair=() account
  for suffix in $OPMENU_SVC_PAIR; do
    be_kafka kafka-configs --describe --entity-type users --entity-name "$base$suffix" 2>/dev/null | grep -q 'SCRAM-SHA-512=' && pair+=("$base$suffix")
  done
  if [ ${#pair[@]} -lt 2 ]; then
    echo "${CR}$base 沒有 A／B 兩個帳號：改密碼會讓使用 $base 的應用程式新連線立刻失敗（中斷）。${C0}"
    be_kafka kafka-configs --describe --entity-type users --entity-name "$base" 2>/dev/null | grep -q 'SCRAM-SHA-512=' || { echo "也沒有 $base 這個帳號"; return 1; }
    core_confirm "在中斷的情況下更換 $base 的密碼（應用程式要同時換）" || return 1
    local password; password=$(k_gen_pw)
    be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$password]" --entity-type users --entity-name "$base" >/dev/null || return 1
    core_handover_secret "$base" "$password" || { echo "交接失敗：$base 的密碼已改，請再跑一次 35 重新產生"; return 1; }
    return 0
  fi
  echo "-- 這組帳號上次輪替（選單紀錄）："
  for account in "${pair[@]}"; do
    printf '  %-28s %s\n' "$account" "$(grep -F "| HANDOVER | " "$OPMENU_LOG" 2>/dev/null | grep -F "| $account |" | tail -1 | cut -d'|' -f1 | sed 's/ *$//' || true)"
  done
  [ -n "$in_use" ] || read -r -p "應用程式現在用的是哪一個（${pair[*]}）: " in_use
  local rotate=""; for account in "${pair[@]}"; do [ "$account" = "$in_use" ] || rotate=$account; done
  _in_words "$in_use" "${pair[*]}" || { echo "$in_use 不是 ${pair[*]} 其中之一"; return 1; }
  core_confirm "更換 $rotate 的密碼（應用程式現在用 $in_use，不受影響）" || return 1
  local password; password=$(k_gen_pw)
  be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$password]" --entity-type users --entity-name "$rotate" >/dev/null || return 1
  core_handover_secret "$rotate" "$password" || { echo "交接失敗：$rotate 的密碼已改，請再跑一次 35 重新產生"; return 1; }
  unset password
  echo "下一步：請應用程式改用 $rotate 與新密碼；下次輪替時換 $in_use"
}
