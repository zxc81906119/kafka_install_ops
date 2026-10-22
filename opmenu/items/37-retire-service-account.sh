item 37 3 y y "下架 service account" "34 的反向:解除該帳號的 binding 並停用 SCRAM 帳號(憑證覆寫成隨機密碼,不刪除;需 ClusterAdmin 與 UserAdmin)"
run() {
  local a="${1:-}" prefix="${2:-}"; [ -n "$a" ] || read -r -p "帳號(例 app-orders): " a; [ -n "$prefix" ] || read -r -p "topic prefix(例 orders.): " prefix
  v_svc_acct "$a" || return 1; v_prefix "$prefix" || return 1
  echo "-- 目前的 binding:"; be_mds POST "/security/1.0/lookup/rolebindings/principal/User:$a" "$(k_scope)" | sed '$d'
  core_confirm "解除 $a 對 $prefix* 的 binding 並停用帳號;使用這個帳號的 application 會立刻無法連線" || return 1
  local r; for r in DeveloperRead DeveloperWrite; do k_unbind_user "$a" "$r" Topic "$prefix"; done; k_unbind_user "$a" DeveloperRead Group "$prefix"
  k_disable_scram "$a" && echo "帳號 $a 已下架"
}
