#!/usr/bin/env bash
# 第 4 站：主機存取 —— 我方只產生 ssh 金鑰；cpuser、sshd、公鑰、安裝期 sudo 是銀行 OS 團隊的事，這裡印出清單並逐台確認
# where: ops02 （root）
#
# 做什麼：確認私鑰的獨立 file system 已掛載 → 在那裡產生操作機的 ssh 金鑰對 → 印出 OS 團隊要做的事（含 cpuser 與公鑰行）
#         → 逐台確認：cpuser 金鑰登入與 sudo、密碼鎖定、sshd 只收金鑰；套件庫的部署帳號也要收這把公鑰。有任何一項沒好就 rc 2（等銀行），做完再跑一次。
# 產出：$SSH_KEY（root、0400，放在獨立 file system；不放 CyberArk、不備份，操作機重建就重新產生，由 OS 團隊重新佈署公鑰）
# 重跑：安全（金鑰已存在就沿用）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

section "4.2 操作機的 ssh 金鑰（$SSH_KEY）"
if [ "$SSH_KEY_REQUIRE_MOUNT" = 1 ] && ! mountpoint -q "$SSH_KEY_DIR"; then
  ask_bank "第 4 章 OS 團隊：在操作機掛載放 ssh 私鑰的獨立（加密）file system 到 $SSH_KEY_DIR（擁有者 root、0700；備份與快照排除這個掛載點）。"
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

ask_bank "第 4 章 OS 團隊（依變更單；每台主機，含操作機自己 $OPS_HOST）：" \
         "    4.1 建本機帳號 $SSH_USER：UID／GID 固定 $SSH_USER_ID、家目錄 /home/$SSH_USER、shell /bin/bash、密碼保持鎖定（不要設密碼）。" \
         "        /etc/ssh/sshd_config.d/50-cpuser.conf 寫 Match User $SSH_USER / PasswordAuthentication no / AuthenticationMethods publickey，重載 sshd。" \
         "    4.3 上面那一行公鑰行放進 /home/$SSH_USER/.ssh/authorized_keys（目錄 0700、檔 0600、擁有者 $SSH_USER）；$REPO_HOST 上 $REPO_DEPLOY_USER 的 authorized_keys 也放同一行。" \
         "        安裝與升級期的 sudo：/etc/sudoers.d/$SSH_USER 寫 $SSH_USER ALL=(ALL) NOPASSWD: ALL（0440，visudo -cf 檢查）；交付時移除（第 16、19 站）。"

section "4.4 確認：每台都能用 $SSH_USER 的金鑰登入、有安裝期 sudo、密碼鎖定且 sshd 只收金鑰（第一次會把主機金鑰記進 known_hosts）"
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

if [ "$FAIL_COUNT" -gt 0 ]; then
  log "OS 團隊還有 $FAIL_COUNT 項沒完成"
  wait_for_bank
fi
finish_step
