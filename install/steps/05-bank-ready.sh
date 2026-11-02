#!/usr/bin/env bash
# 第 5 站：銀行準備好了嗎 —— 套件庫與根憑證、JDK tar、AD、NTP 與負載平衡都是銀行各團隊的事，這裡印出清單並逐項確認
# where: ops02 （root）
#
# 做什麼：印出銀行要做的事 → 逐項確認：每台的根憑證信任與 OS 套件庫、JDK tar 與 sha256、LDAPS 憑證鏈與密碼檔、負載平衡在聽。
#         有任何一項沒好就 rc 2（等銀行），銀行做完再跑一次。
# 需要：第 4 站做完（各主機能用 cpuser 的金鑰登入）。
# 產出：無（只確認）。
# 重跑：安全。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

# jdk_checksum_ok <tar 的完整路徑>：用旁邊的 .sha256 核對（sha256sum 要在 bank/ 裡跑）
jdk_checksum_ok() {
  (
    if ! cd "$LANDING/bank"; then
      exit 1
    fi

    sha256sum -c --quiet "$(basename "$1").sha256"
  )
}

ask_bank "5.1 OS 團隊：每台主機信任銀行根憑證（$BANK_ROOT_CA + update-ca-trust），並有指向 OS 套件庫的 .repo（含 os-packages.txt 的套件）。" \
         "5.2 OS 團隊：JDK $JDK_MAJOR（安裝基底）與 JDK $JDK_TARGET_MAJOR（遷移目標，第 29 章用）的 tar 與 .sha256 放到 $LANDING/bank/。" \
         "5.3 AD 團隊：群組 kafka-admins、kafka-operators、kafka-devs；唯讀帳號 $AD_BIND_DN；測試人員 alice/bob/carol；" \
         "    LDAPS 憑證由銀行 CA 簽；密碼交付到 $SECRETS_DIR/ldap-bind.pass（查詢帳號）、ad-test-users.pass（測試人員），0600。" \
         "5.4 網路團隊：行內 NTP（$NTP_SERVER）可用；負載平衡 $LB_HOST 的 8082 轉到 ${RESTS// /、} 的 8082，$REST_VIP 指到它。"

section "確認 5.1：根憑證信任與 OS 套件庫"
for host in $ALL_HOSTS; do
  result=$(ssh_script "$host" ROOT_CA="$BANK_ROOT_CA" REPO_URL="$REPO_URL" <<'EOF' 2>&1
if [ -f "$ROOT_CA" ]; then
  anchor=anchor
else
  anchor=no-anchor
fi

os_repo=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$REPO_URL/os/repodata/repomd.xml")
echo "$anchor $os_repo"
EOF
)

  if [ "$result" = "anchor 200" ]; then
    ok "$host：bank-root.pem 在、OS 套件庫 200"
  else
    fail "$host：$result"
  fi
done

section "確認 5.2：JDK tar 與 sha256"
for jdk_major in "$JDK_MAJOR" "$JDK_TARGET_MAJOR"; do
  jdk_tar=$(ls "$LANDING"/bank/OpenJDK"${jdk_major}"U-*.tar.gz 2>/dev/null | sort -V | tail -1)

  if [ -z "$jdk_tar" ]; then
    fail "JDK $jdk_major 的 tar 不在 $LANDING/bank 或 sha256 不符"
    continue
  fi

  if jdk_checksum_ok "$jdk_tar"; then
    ok "JDK $jdk_major：$(basename "$jdk_tar") sha256 相符"
  else
    fail "JDK $jdk_major 的 tar 不在 $LANDING/bank 或 sha256 不符"
  fi
done

section "確認 5.3：LDAPS 憑證鏈、密碼檔"
ldaps_verify=$(openssl s_client -connect "$AD_FQDN:$AD_LDAPS_PORT" -CAfile "$BANK_ROOT_CA" </dev/null 2>/dev/null | grep "Verify return code")

case $ldaps_verify in
  *"0 (ok)"*)
    ok "LDAPS $AD_FQDN:$AD_LDAPS_PORT：$ldaps_verify"
    ;;
  *)
    fail "LDAPS：${ldaps_verify:-連不上}"
    ;;
esac

for password_file in ldap-bind ad-test-users; do
  path=$SECRETS_DIR/$password_file.pass

  if [ ! -s "$path" ]; then
    fail "$path 不存在"
    continue
  fi

  mode=$(stat -c %a "$path")

  if [ "$mode" = 600 ]; then
    ok "$path（0600）"
  else
    fail "$path 權限 $mode，應為 600"
  fi
done

section "確認 5.4：負載平衡在聽（REST 還沒啟動，只看 8082 有沒有開）"
if nc -z -w 3 "$(fqdn "$LB_HOST")" 8082; then
  ok "$LB_HOST:8082 開著"
else
  fail "$LB_HOST:8082 連不上"
fi

if getent hosts "$REST_VIP" >/dev/null; then
  ok "$REST_VIP 解析得到"
else
  fail "$REST_VIP 解析不到"
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  log "銀行還有 $FAIL_COUNT 項沒完成"
  wait_for_bank
fi

finish_step
