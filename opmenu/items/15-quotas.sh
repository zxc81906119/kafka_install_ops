item 15 1 n n "查看配額(quota)" "每個帳號的 producer_byte_rate、consumer_byte_rate(bytes/秒)與 request_percentage;直接按 Enter 查全部,或輸入帳號(需叢集層級的 DescribeConfigs:ClusterAdmin 或 SystemAdmin)"
run() {
  local u="${1:-}"; [ -n "$u" ] || [ $# -ge 1 ] || read -r -p "帳號(空 = 全部): " u
  [ -z "$u" ] || v_svc_acct "$u" || return 1
  local lines; lines=$(k_quota_lines "$u") || return 1
  if [ -z "$lines" ]; then echo "${u:+帳號 $u }沒有設定配額"; return 0; fi
  printf '%-28s %s\n' "帳號" "配額(bytes/秒;request_percentage = 佔 broker 執行緒的百分比)"; printf '%s\n' "$lines"
}
