# 項目 42：指派或移除權限
#
# 做什麼：替一個 AD 群組加上或拿掉一個 role。只能綁 AD 群組，不能綁個人（人員的權限一律跟著群組走）。
#   Developer 類與 ResourceOwner 要指定資源（Topic 或 Group）與名稱 prefix；其他 role 是 cluster 層級。
# 用到的設定（opmenu.conf）：
#   OPMENU_ROLES_ALLOWED     可以指派的 role 清單
# 用到的共用函式：
#   v_in、v_adgroup、v_role、v_rtype、v_prefix   檢查輸入（lib/common.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   be_mds、k_bind_body、k_scope、k_http_ok      呼叫 MDS、判斷回應成功（lib/kafka.sh）
# 改的時候要注意：
#   - 要有 UserAdmin（或 SecurityAdmin）才改得了 binding（由 MDS 判斷）。

run_42() {
  local action="${1:-}"
  local group="${2:-}"
  local role="${3:-}"
  local resource_type="${4:-}"
  local resource_prefix="${5:-}"

  # 1. 問要做什麼、哪個群組、哪個 role
  if [ -z "$action" ]; then
    read -r -p "動作(add | remove): " action
  fi

  if [ -z "$group" ]; then
    read -r -p "AD 群組(不含 Group:): " group
  fi

  if [ -z "$role" ]; then
    read -r -p "role(例 DeveloperRead、Operator): " role
  fi

  if ! v_in "$action" "add remove" "動作"; then
    return 1
  fi

  if ! v_adgroup "$group"; then
    return 1
  fi

  if ! v_role "$role"; then
    return 1
  fi

  # 2. 綁在資源上的 role：再問資源類型與名稱 prefix
  if _in_words "$role" "DeveloperRead DeveloperWrite DeveloperManage ResourceOwner"; then
    if [ -z "$resource_type" ]; then
      read -r -p "資源類型(Topic | Group): " resource_type
    fi

    if [ -z "$resource_prefix" ]; then
      read -r -p "名稱 prefix(例 orders.): " resource_prefix
    fi

    if ! v_rtype "$resource_type"; then
      return 1
    fi

    if ! v_prefix "$resource_prefix"; then
      return 1
    fi
  fi

  # 3. 確認
  local target=""
  if [ -n "$resource_type" ]; then
    target="$resource_type:$resource_prefix*"
  fi

  if ! core_confirm "$action  Group:$group  $role $target"; then
    return 1
  fi

  # 4. add 用 POST、remove 用 DELETE；有資源的綁在資源上，沒有的是 cluster 層級
  local method=DELETE
  if [ "$action" = add ]; then
    method=POST
  fi

  local ok=yes
  if [ -n "$resource_type" ]; then
    local body
    body=$(k_bind_body "$resource_type" "$resource_prefix" PREFIXED)

    if ! be_mds "$method" "/security/1.0/principals/Group:$group/roles/$role/bindings" "$body" | k_http_ok; then
      ok=no
    fi
  else
    if ! be_mds "$method" "/security/1.0/principals/Group:$group/roles/$role" "$(k_scope)" | k_http_ok; then
      ok=no
    fi
  fi

  if [ "$ok" = no ]; then
    echo "MDS 回應失敗"
    return 1
  fi

  echo "已完成:$action Group:$group $role"
}
