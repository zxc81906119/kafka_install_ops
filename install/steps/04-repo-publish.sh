#!/usr/bin/env bash
# 第 4 站：上架到內部套件庫 —— 操作機建索引，用 tar 經 ssh 推給銀行 web server 的部署帳號
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"

section "工具：createrepo_c、gettext（envsubst）從銀行套件庫安裝（--refresh 避開 48 小時的 dnf 快取）"
sudo dnf -q -y --refresh install createrepo_c gettext >/dev/null || die "裝不到 createrepo_c / gettext：確認銀行套件庫有 os-packages.txt 列的套件"
ok "createrepo_c $(createrepo_c --version | head -1)、envsubst $(envsubst --version | head -1 | awk '{print $NF}')"

section "組目錄、建索引"
mkdir -p "$REPO_DIR"/{confluent,gpg-keys,tools}
cp "$LANDING"/rpm/*.rpm "$REPO_DIR/confluent/" && cp "$LANDING"/gpg-keys/*.asc "$REPO_DIR/gpg-keys/" && cp "$LANDING"/tools/*.jar "$REPO_DIR/tools/" && cp "$LANDING/SHA256SUMS" "$REPO_DIR/"
createrepo_c -q "$REPO_DIR/confluent" && test -f "$REPO_DIR/confluent/repodata/repomd.xml" && ok "repodata 建好" || die "createrepo_c 失敗"

section "推上 $REPO_HOST（只解在 /var/www/repo 底下，銀行的 os/ 不受影響）"
tar -C "$REPO_DIR" -cf - . | rsh_as "$REPO_DEPLOY_USER" "$REPO_HOST" 'tar -C /var/www/repo -xpf -' || die "推送失敗"
ok "$REPO_HOST:/var/www/repo：$(rsh_as "$REPO_DEPLOY_USER" "$REPO_HOST" 'ls /var/www/repo | paste -sd" "; ls /var/www/repo/confluent | wc -l' | paste -sd' ') 個檔"

section "從操作機用 HTTPS 讀回來"
n=$(dnf -q repoquery --repofrompath=cp-test,"$REPO_URL/confluent/" --repo=cp-test --setopt=cp-test.gpgcheck=0 --qf '%{name}' 2>/dev/null | grep -c confluent)   # repoquery：不管本機裝了沒都列
[ "$n" -ge 11 ] && ok "套件庫看得到 $n 個 confluent 套件" || die "套件庫只看到 $n 個套件（預期 11）"
finish
