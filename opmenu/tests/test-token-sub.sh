#!/usr/bin/env bash
# test-token-sub.sh：token_subject 取出 token 的 sub（AD 回傳的帳號寫法）；解不出來回 1。不需要叢集。
set -uo pipefail
SCRIPT_DIR=$(dirname "$0")
HERE=$(
  if cd "$SCRIPT_DIR/.."; then
    pwd
  fi
)

# 只取出要測的函式，不載入整支 common.sh
eval "$(sed -n '/^token_subject() {/,/^}/p' "$HERE/lib/common.sh")"

pass=0
total=0
check() {
  total=$((total + 1))

  if eval "$2"; then
    pass=$((pass + 1))
  else
    echo "FAIL: $1"
  fi
}

# make_token <payload JSON>：組出 JWT 形狀的字串（base64url、不補 =）
make_token() {
  local encoded url_safe
  encoded=$(printf '%s' "$1" | base64 -w0)
  url_safe=$(printf '%s' "$encoded" | tr '+/' '-_' | tr -d '=')

  printf 'eyJhbGciOiJSUzI1NiJ9.%s.signature' "$url_safe"
}

check "全大寫的 sub" '[ "$(token_subject "$(make_token "{\"sub\":\"ZZCASEUSER\",\"exp\":1}")")" = ZZCASEUSER ]'
check "小寫的 sub" '[ "$(token_subject "$(make_token "{\"exp\":1,\"sub\":\"alice\"}")")" = alice ]'
check "payload 長度不是 4 的倍數也解得開" '[ "$(token_subject "$(make_token "{\"sub\":\"ab\"}")")" = ab ]'
check "沒有 sub：回 1" '! token_subject "$(make_token "{\"exp\":1}")" > /dev/null'
check "不是 token：回 1" '! token_subject "not-a-token" > /dev/null'
check "空字串：回 1" '! token_subject "" > /dev/null'

echo "token_subject：$pass / $total 通過"
[ "$pass" = "$total" ]
