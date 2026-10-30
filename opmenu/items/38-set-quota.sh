item 38 3 y y "調整配額(quota)" "改一個帳號的 producer_byte_rate、consumer_byte_rate(bytes/秒)或 request_percentage;顯示改前改後;值填 - 表示拿掉那一項(需 ClusterAdmin)"
# 參數(非互動):<帳號> <項目=值[,項目=值…]>
run() {
  local u="${1:-}" spec="${2:-}" kv k v add="" del="" cur
  [ -n "$u" ] || read -r -p "帳號: " u; v_svc_acct "$u" || return 1
  cur=$(k_quota_lines "$u") || return 1
  echo "目前:${cur:-(沒有設定配額)}"
  [ -n "$spec" ] || read -r -p "要改的項目(例 producer_byte_rate=1048576,request_percentage=25;值填 - 拿掉): " spec
  [ -n "$spec" ] || { echo "沒有要改的項目"; return 1; }
  for kv in ${spec//,/ }; do
    k="${kv%%=*}"; v="${kv#*=}"; [ "$k" != "$kv" ] || { v_fail "要寫成 項目=值:$kv"; return 1; }
    v_in "$k" "$OPMENU_QUOTA_KEYS" "配額項目" || return 1
    if [ "$v" = - ]; then del+="$k,"; else v_number "$v" "$k 的值" || return 1; add+="$k=$v,"; fi
  done
  core_confirm "帳號 $u 的配額:${add:+設定 ${add%,}}${add:+${del:+;}}${del:+拿掉 ${del%,}}" || return 1
  if [ -n "$add" ]; then be_kafka kafka-configs --alter --entity-type users --entity-name "$u" --add-config "${add%,}" || return 1; fi
  if [ -n "$del" ]; then be_kafka kafka-configs --alter --entity-type users --entity-name "$u" --delete-config "${del%,}" || return 1; fi
  cur=$(k_quota_lines "$u") || return 1
  echo "改後:${cur:-(沒有設定配額)}"
}
