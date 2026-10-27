#!/usr/bin/env bash
# 第 3 站：銀行準備好了嗎 —— 我方只產生 ssh 金鑰；其餘是銀行各團隊的事，這裡印出清單並逐項確認
# where: ops02 （root）
#
# 做什麼：確認私鑰的獨立 file system 已掛載 → 在那裡產生操作機的 ssh 金鑰對 → 印出銀行要做的事（含 cpuser 與公鑰行）→ 逐項確認：
#         cpuser 金鑰登入與 sudo、根憑證信任、OS 套件庫、JDK、LDAPS、密碼檔、負載平衡。有任何一項沒好就 rc 2（等銀行），銀行做完再跑一次。
# 產出：$SSH_KEY（root、0400，放在獨立 file system；不放 CyberArk、不備份，操作機重建就重新產生，由 OS 團隊重新佈署公鑰）
# 重跑：安全（金鑰已存在就沿用）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

section "3.1 操作機的 ssh 金鑰（$SSH_KEY）"
if [ "$SSH_KEY_REQUIRE_MOUNT" = 1 ] && ! mountpoint -q "$SSH_KEY_DIR"; then
  ask_bank "3.1 OS 團隊：在操作機掛載放 ssh 私鑰的獨立（加密）file system 到 $SSH_KEY_DIR（擁有者 root、0700；備份與快照排除這個掛載點）。"
  fail "$SSH_KEY_DIR 不是獨立掛載點（SSH_KEY_REQUIRE_MOUNT=1）"
  wait_for_bank
fi
install -d -m 0700 "$SSH_KEY_DIR"
if [ ! -f "$SSH_KEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "cpuser-ops-$(date +%Y%m%d)" -f "$SSH_KEY" || die "ssh-keygen 失敗"
  chmod 0400 "$SSH_KEY"
fi
key_state=$(stat -c '%U:%G %a' "$SSH_KEY")
if [ "$key_state" = "root:root 400" ]; then ok "私鑰 $SSH_KEY（$key_state）"; else fail "私鑰 $SSH_KEY 擁有者與權限是 $key_state，應為 root:root 400"; fi
# 手動操作時 ssh 不用每次帶 -i：操作機（root）連各主機一律用 cpuser 與這把金鑰
install -d -m 0700 ~/.ssh
if ! grep -q '^# cpuser-ops' ~/.ssh/config 2>/dev/null; then
  printf '# cpuser-ops：操作機連各主機一律用 %s 與這把金鑰\nHost *.%s localhost\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n' \
    "$SSH_USER" "$DOMAIN" "$SSH_USER" "$SSH_KEY" >> ~/.ssh/config
  chmod 0600 ~/.ssh/config
fi
public_key_line=$(authorized_keys_line)
ok "公鑰行（整行、不換行，放進每台 cpuser 的 authorized_keys）：$public_key_line"

ask_bank "3.1 OS 團隊（依變更單；每台主機，含操作機自己 $OPS_HOST）：" \
         "    a. 建本機帳號 $SSH_USER：UID／GID 固定 $SSH_USER_ID、家目錄 /home/$SSH_USER、shell /bin/bash、密碼保持鎖定（不要設密碼）。" \
         "    b. /etc/ssh/sshd_config.d/50-cpuser.conf 寫 Match User $SSH_USER / PasswordAuthentication no / AuthenticationMethods publickey，重載 sshd。" \
         "    c. 上面那一行公鑰行放進 /home/$SSH_USER/.ssh/authorized_keys（目錄 0700、檔 0600、擁有者 $SSH_USER）；$REPO_HOST 上 $REPO_DEPLOY_USER 的 authorized_keys 也放同一行。" \
         "    d. 安裝與升級期的 sudo：/etc/sudoers.d/$SSH_USER 寫 $SSH_USER ALL=(ALL) NOPASSWD: ALL（0440，visudo -cf 檢查）；交付時移除（第 16、19 站）。" \
         "3.2 OS 團隊：每台主機信任銀行根憑證（$BANK_ROOT_CA + update-ca-trust），並有指向 OS 套件庫的 .repo（含 os-packages.txt 的套件）。" \
         "3.3 OS 團隊：JDK 21 的 tar 與 .sha256 放到 $LANDING/bank/。" \
         "3.4 AD 團隊：群組 kafka-admins、kafka-operators、kafka-devs；唯讀帳號 $AD_BIND_DN；測試人員 alice/bob/carol；" \
         "    LDAPS 憑證由銀行 CA 簽；密碼交付到 $SECRETS_DIR/ldap-bind.pass（查詢帳號）、ad-test-users.pass（測試人員），0600。" \
         "3.5 網路團隊：行內 NTP（$NTP_SERVER）可用；負載平衡 $LB_HOST 的 8082 轉到 ${RESTS// /、} 的 8082，$REST_VIP 指到它。"

section "確認 3.1：每台都能用 $SSH_USER 的金鑰登入、有安裝期 sudo、密碼鎖定且 sshd 只收金鑰（第一次會把主機金鑰記進 known_hosts）"
for host in $ALL_HOSTS; do
  answer=$(ssh_script "$host" <<'EOF' 2>&1
me=$(id -un)
sudo_state=$(sudo -n true 2>/dev/null && echo sudo || echo no-sudo)
uid=$(id -u)
lock_state=$(sudo -n getent shadow "$me" 2>/dev/null | cut -d: -f2 | cut -c1)
sshd_state=$(sudo -n sshd -T -C "user=$me,host=localhost,addr=127.0.0.1" 2>/dev/null | awk '/^passwordauthentication /{p=$2} /^authenticationmethods /{m=$2} END{print p, m}')
echo "$me $(hostname) $sudo_state $uid $lock_state $sshd_state"
EOF
)
  expected="$SSH_USER $host sudo $SSH_USER_ID ! no publickey"
  if [ "$answer" = "$expected" ]; then ok "$host：$answer"; else fail "$host：$answer（應為：$expected）"; fi
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
