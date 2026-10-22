item 35 3 y y "更換 service account 密碼" "同帳號改密碼;舊密碼對新連線立即失效,application 要同步更換(需 ClusterAdmin)。零中斷的做法是兩個帳號 A/B 交替,見 redesign 筆記"
run() {
  local a="${1:-}"; [ -n "$a" ] || read -r -p "帳號: " a
  v_svc_acct "$a" || return 1
  core_confirm "更換 $a 的密碼;application 必須立刻換成新密碼" || return 1
  local pw; pw=$(k_gen_pw)
  be_kafka kafka-configs --alter --add-config "SCRAM-SHA-512=[password=$pw]" --entity-type users --entity-name "$a" || return $?
  echo "新密碼(只顯示這一次,請存入 CyberArk):$pw"
}
