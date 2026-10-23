#!/usr/bin/env bash
# 第 3 站：銀行準備好了嗎 —— 我方只產生 ssh 金鑰；其餘是銀行各團隊的事，這裡印出清單並逐項確認
# where: ops02 （cpadmin）
#
# 做什麼：產生操作機的 ssh 金鑰對 → 印出銀行要做的事 → 逐項確認：金鑰登入、根憑證信任、OS 套件庫、JDK、
#         LDAPS、密碼檔、負載平衡。有任何一項沒好就 rc 2（等銀行），銀行做完再跑一次。
# 產出：~/.ssh/id_ed25519（私鑰不離開操作機；正式環境可由 CyberArk 產生與派送）
# 重跑：安全（金鑰已存在就沿用）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

section "3.1 操作機的 ssh 金鑰"
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "cpadmin@$OPS_HOST" -f ~/.ssh/id_ed25519
ok "公鑰：$(cat ~/.ssh/id_ed25519.pub)"

ask_bank "3.1 OS 團隊：上面這把公鑰放進每台主機（$ALL_HOSTS）cpadmin 的 authorized_keys，以及 $REPO_HOST 上 $REPO_DEPLOY_USER 的。" \
         "3.2 OS 團隊：每台主機信任銀行根憑證（$BANK_ROOT_CA + update-ca-trust），並有指向 OS 套件庫的 .repo（含 os-packages.txt 的套件）。" \
         "3.3 OS 團隊：JDK 21 的 tar 與 .sha256 放到 $LANDING/bank/。" \
         "3.4 AD 團隊：群組 kafka-admins、kafka-operators、kafka-devs；唯讀帳號 $AD_BIND_DN；測試人員 alice/bob/carol；" \
         "    LDAPS 憑證由銀行 CA 簽；密碼交付到 $SECRETS_DIR/ldap-bind.pass（查詢帳號）、ad-test-users.pass（測試人員），0600。" \
         "3.5 網路團隊：行內 NTP（$NTP_SERVER）可用；負載平衡 $LB_HOST 的 8082 轉到 ${RESTS// /、} 的 8082，$REST_VIP 指到它。"

section "確認 3.1：每台都能用金鑰登入（第一次會把主機金鑰記進 known_hosts）"
for host in $ALL_HOSTS; do
  answer=$(ssh_run "$host" hostname 2>&1)
  if [ "$answer" = "$host" ]; then ok "$host"; else fail "$host：$answer"; fi
done
answer=$(ssh_run_as "$REPO_DEPLOY_USER" "$REPO_HOST" hostname 2>&1)
if [ "$answer" = "$REPO_HOST" ]; then ok "$REPO_DEPLOY_USER@$REPO_HOST"; else fail "$REPO_DEPLOY_USER@$REPO_HOST：$answer"; fi

section "確認 3.2：根憑證信任與 OS 套件庫"
for host in $ALL_HOSTS; do
  result=$(ssh_script "$host" ROOT_CA="$BANK_ROOT_CA" REPO_URL="$REPO_URL" <<'EOF' 2>&1
anchor=$([ -f "$ROOT_CA" ] && echo anchor || echo no-anchor)
os_repo=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$REPO_URL/os/repodata/repomd.xml")
echo "$anchor $os_repo"
EOF
)
  if [ "$result" = "anchor 200" ]; then ok "$host：bank-root.pem 在、OS 套件庫 200"; else fail "$host：$result"; fi
done

section "確認 3.3：JDK tar 與 sha256"
jdk_tar=$(ls "$LANDING"/bank/*.tar.gz 2>/dev/null | head -1)
if [ -n "$jdk_tar" ] && (cd "$LANDING/bank" && sha256sum -c --quiet ./*.sha256); then ok "JDK：$(basename "$jdk_tar") sha256 相符"
else fail "JDK tar 不在 $LANDING/bank 或 sha256 不符"; fi

section "確認 3.4：LDAPS 憑證鏈、密碼檔"
ldaps_verify=$(openssl s_client -connect "$AD_FQDN:$AD_LDAPS_PORT" -CAfile "$BANK_ROOT_CA" </dev/null 2>/dev/null | grep "Verify return code")
case $ldaps_verify in *"0 (ok)"*) ok "LDAPS $AD_FQDN:$AD_LDAPS_PORT：$ldaps_verify";; *) fail "LDAPS：${ldaps_verify:-連不上}";; esac
for password_file in ldap-bind ad-test-users; do
  path=$SECRETS_DIR/$password_file.pass
  if [ ! -s "$path" ]; then fail "$path 不存在"; continue; fi
  mode=$(stat -c %a "$path")
  if [ "$mode" = 600 ]; then ok "$path（0600）"; else fail "$path 權限 $mode，應為 600"; fi
done

section "確認 3.5：負載平衡在聽（REST 還沒啟動，只看 8082 有沒有開）"
if nc -z -w 3 "$(fqdn "$LB_HOST")" 8082; then ok "$LB_HOST:8082 開著"; else fail "$LB_HOST:8082 連不上"; fi
if getent hosts "$REST_VIP" >/dev/null; then ok "$REST_VIP 解析得到"; else fail "$REST_VIP 解析不到"; fi

if [ "$FAIL_COUNT" -gt 0 ]; then
  log "銀行還有 $FAIL_COUNT 項沒完成"
  wait_for_bank
fi
finish_step
