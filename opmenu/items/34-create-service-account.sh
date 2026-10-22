item 34 3 y y "新增 service account" "建 SCRAM 帳號並 bind 該系統 topic prefix 的讀寫權限;密碼由系統產生,只顯示一次;binding 失敗會回滾(建帳號需 ClusterAdmin;綁權限需 UserAdmin)"
run() {
  local a="${1:-}" prefix="${2:-}" mode="${3:-rw}"; [ -n "$a" ] || read -r -p "帳號(例 app-orders): " a; [ -n "$prefix" ] || read -r -p "topic prefix(例 orders.): " prefix
  v_svc_acct "$a" || return 1; v_prefix "$prefix" || return 1; v_in "$mode" "rw ro" "模式" || return 1
  core_confirm "建立帳號 $a,授權 $prefix* 的讀寫" || return 1
  local pw; pw=$(k_gen_pw)
  be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$pw]" --entity-type users --entity-name "$a" || return $?
  local r ok=1; for r in DeveloperRead DeveloperWrite; do
    [ "$mode" = ro ] && [ "$r" = DeveloperWrite ] && continue
    be_mds POST "/security/1.0/principals/User:$a/roles/$r/bindings" "$(k_bind_body Topic "$prefix" PREFIXED)" | k_http_ok || { echo "binding $r 失敗"; ok=0; break; }
  done
  [ $ok = 1 ] && { be_mds POST "/security/1.0/principals/User:$a/roles/DeveloperRead/bindings" "$(k_bind_body Group "$prefix" PREFIXED)" | k_http_ok || { echo "binding consumer group 失敗"; ok=0; }; }
  if [ $ok = 0 ]; then   # 回滾:解除已綁的、停用帳號,不留下沒人管的帳號
    for r in DeveloperRead DeveloperWrite; do k_unbind_user "$a" "$r" Topic "$prefix"; done; k_unbind_user "$a" DeveloperRead Group "$prefix"
    k_disable_scram "$a" >/dev/null 2>&1
    echo "已回滾:帳號 $a 與 binding 都已移除"; return 1
  fi
  echo "帳號 $a 已建立;密碼(只顯示這一次,請存入 CyberArk):$pw"
}
