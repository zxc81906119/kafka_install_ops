item 41 4 n n "查看權限" "輸入 AD 群組或帳號,列出它的 role binding 與資源(需 SecurityAdmin 或 UserAdmin)"
run() {
  local p="${1:-}"; [ -n "$p" ] || read -r -p "principal(例 Group:kafka-ops 或 User:app-orders): " p
  v_principal "$p" || return 1
  echo "-- cluster 層級的 role:"; k_roles_of "$p" || return 1
  echo "-- 資源層級的 binding:"; k_show_mds POST "/security/1.0/lookup/rolebindings/principal/$p" "$(k_scope)"
}
