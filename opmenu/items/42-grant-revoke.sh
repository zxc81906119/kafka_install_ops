item 42 4 y y "指派或移除權限" "只能綁 AD 群組,不能綁個人;可指派的 role 限於 OPMENU_ROLES_ALLOWED"
run() {
  local op="${1:-}" g="${2:-}" role="${3:-}" rtype="${4:-}" rname="${5:-}"
  [ -n "$op" ] || read -r -p "動作(add | remove): " op; [ -n "$g" ] || read -r -p "AD 群組(不含 Group:): " g; [ -n "$role" ] || read -r -p "role(例 DeveloperRead、Operator): " role
  v_in "$op" "add remove" "動作" || return 1; v_adgroup "$g" || return 1; v_role "$role" || return 1
  case "$role" in DeveloperRead|DeveloperWrite|DeveloperManage|ResourceOwner)
    [ -n "$rtype" ] || read -r -p "資源類型(Topic | Group): " rtype; [ -n "$rname" ] || read -r -p "名稱 prefix(例 orders.): " rname
    v_rtype "$rtype" || return 1; v_prefix "$rname" || return 1;;
  esac
  local m; [ "$op" = add ] && m=POST || m=DELETE
  core_confirm "$op  Group:$g  $role ${rtype:+$rtype:$rname*}" || return 1
  if [ -n "$rtype" ]; then be_mds "$m" "/security/1.0/principals/Group:$g/roles/$role/bindings" "$(k_bind_body "$rtype" "$rname" PREFIXED)" | k_http_ok
  else be_mds "$m" "/security/1.0/principals/Group:$g/roles/$role" "$(k_scope)" | k_http_ok; fi || { echo "MDS 回應失敗"; return 1; }
  echo "已完成:$op Group:$g $role"
}
