item 37 3 y y "下架 service account" "34 的反向：解除 A／B 兩個帳號（沒有 A／B 時是單一帳號）的 binding 並停用 SCRAM（憑證覆寫成隨機密碼，不刪除；需 ClusterAdmin 與 UserAdmin）"
run() {
  local base="${1:-}" prefix="${2:-}"
  [ -n "$base" ] || read -r -p "應用程式名稱（例 app-orders）: " base
  [ -n "$prefix" ] || read -r -p "topic prefix（例 orders.）: " prefix
  v_svc_acct "$base" || return 1; v_prefix "$prefix" || return 1
  local suffix accounts="" account role
  for suffix in $OPMENU_SVC_PAIR; do
    be_kafka kafka-configs --describe --entity-type users --entity-name "$base$suffix" 2>/dev/null | grep -q 'SCRAM-SHA-512=' && accounts+="$base$suffix "
  done
  [ -n "$accounts" ] || accounts=$base
  for account in $accounts; do echo "-- $account 目前的 binding："; be_mds POST "/security/1.0/lookup/rolebindings/principal/User:$account" "$(k_scope)" | sed '$d'; done
  core_confirm "解除 $accounts對 $prefix* 的 binding 並停用；使用這些帳號的 application 會立刻無法連線" || return 1
  for account in $accounts; do
    for role in DeveloperRead DeveloperWrite; do k_unbind_user "$account" "$role" Topic "$prefix"; done
    k_unbind_user "$account" DeveloperRead Group "$prefix"
    k_disable_scram "$account" >/dev/null && echo "帳號 $account 已下架"
  done
}
