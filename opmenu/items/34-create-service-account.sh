# 兩個帳號權限完全一樣：應用程式先用 -a；之後輪替密碼（35）換沒在用的那個，再請應用程式切過去，不中斷
run_34() {
  local base="${1:-}" prefix="${2:-}" mode="${3:-rw}"
  [ -n "$base" ] || read -r -p "應用程式名稱（例 app-orders，會建 app-orders-a、app-orders-b）: " base
  [ -n "$prefix" ] || read -r -p "topic prefix（例 orders.）: " prefix
  v_svc_acct "$base" || return 1; v_prefix "$prefix" || return 1; v_in "$mode" "rw ro" "模式" || return 1
  local suffix accounts=""; for suffix in $OPMENU_SVC_PAIR; do accounts+="$base$suffix "; done; accounts="${accounts% }"
  core_handover_ready || return 1
  core_confirm "建立帳號 $accounts，授權 $prefix* 的$([ "$mode" = ro ] && echo 讀取 || echo 讀寫)" || return 1
  local account role ok=1 created=""
  for account in $accounts; do
    be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$(k_gen_pw)]" --entity-type users --entity-name "$account" >/dev/null || { ok=0; break; }
    created+="$account "
    for role in DeveloperRead DeveloperWrite; do
      [ "$mode" = ro ] && [ "$role" = DeveloperWrite ] && continue
      be_mds POST "/security/1.0/principals/User:$account/roles/$role/bindings" "$(k_bind_body Topic "$prefix" PREFIXED)" | k_http_ok || { echo "$account binding $role 失敗"; ok=0; break 2; }
    done
    be_mds POST "/security/1.0/principals/User:$account/roles/DeveloperRead/bindings" "$(k_bind_body Group "$prefix" PREFIXED)" | k_http_ok || { echo "$account binding consumer group 失敗"; ok=0; break; }
  done
  if [ $ok = 0 ]; then   # 回滾：解除已綁的、停用帳號，不留下沒人管的帳號
    for account in $created; do
      for role in DeveloperRead DeveloperWrite; do k_unbind_user "$account" "$role" Topic "$prefix"; done
      k_unbind_user "$account" DeveloperRead Group "$prefix"; k_disable_scram "$account" >/dev/null 2>&1
    done
    echo "已回滾：$created帳號與 binding 都已移除"; return 1
  fi
  # 建帳號時的隨機密碼沒有交出去；現在才產生要交付的那組（兩個都要交，應用程式先用第一個）
  for account in $accounts; do
    local password; password=$(k_gen_pw)
    be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$password]" --entity-type users --entity-name "$account" >/dev/null || return 1
    core_handover_secret "$account" "$password" || { echo "$account 的新密碼交接失敗：用 35 重新產生"; return 1; }
    unset password
  done
  echo "帳號 $accounts 已建立；應用程式先用 ${accounts%% *}"
}
