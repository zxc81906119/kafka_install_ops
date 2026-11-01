# 項目 41：查看某個身分的權限
#
# 做什麼：列出一個 principal（AD 群組或帳號）有哪些 role：cluster 層級的，以及綁在 topic／group 上的。
# 用到的設定：沒有
# 用到的共用函式：
#   v_principal              檢查格式是 User:<帳號> 或 Group:<群組>（lib/common.sh）
#   k_roles_of               cluster 層級的 role（lib/kafka.sh）
#   k_show_mds、k_scope      呼叫 MDS 並印回應（lib/kafka.sh）
# 改的時候要注意：
#   - 要有 SecurityAdmin 或 UserAdmin 才查得到別人的 binding（由 MDS 判斷）。

run_41() {
  local principal="${1:-}"

  # 1. 問要查誰
  if [ -z "$principal" ]; then
    read -r -p "principal(例 Group:kafka-ops 或 User:app-orders): " principal
  fi

  if ! v_principal "$principal"; then
    return 1
  fi

  # 2. cluster 層級的 role
  echo "-- cluster 層級的 role:"

  if ! k_roles_of "$principal"; then
    return 1
  fi

  # 3. 資源層級的 binding
  echo "-- 資源層級的 binding:"
  k_show_mds POST "/security/1.0/lookup/rolebindings/principal/$principal" "$(k_scope)"
}
