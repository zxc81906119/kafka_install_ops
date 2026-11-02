#!/usr/bin/env bash
# 第 6 站：上架到內部套件庫 —— 操作機建索引，用 tar 經 ssh 推給銀行 web server 的部署帳號
# where: ops02 （root）
#
# 做什麼：從銀行套件庫裝 createrepo_c、gettext → 組 ~/repo（RPM、公鑰、jar、SHA256SUMS）→ 建 repodata
#         → tar 串流經 ssh 解到 repo01 的 /var/www/repo（只動我們的目錄，銀行的 os/ 不受影響）→ 用 HTTPS 讀回來確認。
#         這裡只放安裝基底的 RPM（$LANDING/rpm）；遷移目標在第 29 章才上架。
# 需要：第 3 站驗過的 $LANDING、第 4 站部署帳號的金鑰可用。
# 產出：$REPO_DIR、repo01 上的 /var/www/repo/{confluent,gpg-keys,tools,SHA256SUMS}。
# 重跑：安全（覆蓋成一樣的內容）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

# count_published_packages：套件庫（HTTPS）上看得到幾個 confluent 套件
#   用 repoquery：不管本機裝了沒都會列；手把手的 dnf list available 會漏掉已裝的，重跑時數字就不對了
count_published_packages() {
  dnf -q repoquery --repofrompath=cp-test,"$REPO_URL/confluent/" --repo=cp-test --setopt=cp-test.gpgcheck=0 --qf '%{name}' 2>/dev/null \
    | awk '/confluent/ {count++} END {print count + 0}'
}

section "工具：createrepo_c、gettext（envsubst）從銀行套件庫安裝（--refresh：dnf 的套件清單快取 48 小時，剛上架的會找不到）"
if ! dnf -q -y --refresh install createrepo_c gettext >/dev/null; then
  die "裝不到 createrepo_c／gettext：確認銀行套件庫有 os-packages.txt 列的套件"
fi

ok "createrepo_c $(createrepo_c --version | head -1)、envsubst $(envsubst --version | head -1 | awk '{print $NF}')"

section "組目錄、建索引"
# 1. 要上架的東西：安裝基底的 RPM、原廠公鑰、jar、雜湊清單
mkdir -p "$REPO_DIR"/{confluent,gpg-keys,tools}
cp "$LANDING"/rpm/*.rpm "$REPO_DIR/confluent/"
cp "$LANDING"/gpg-keys/*.asc "$REPO_DIR/gpg-keys/"
cp "$LANDING"/tools/*.jar "$REPO_DIR/tools/"
cp "$LANDING/SHA256SUMS" "$REPO_DIR/"

# 2. 建 dnf 的索引
if ! createrepo_c -q "$REPO_DIR/confluent"; then
  die "createrepo_c 失敗"
fi

# 3. 確認索引產生了
if [ -f "$REPO_DIR/confluent/repodata/repomd.xml" ]; then
  ok "repodata 建好"
else
  die "createrepo_c 失敗"
fi

section "推上 $REPO_HOST（只解在 /var/www/repo 底下）"
# 1. 在操作機打包、經 ssh 交給部署帳號，在 repo01 解開
if ! tar -C "$REPO_DIR" -cf - . | ssh_run_as "$REPO_DEPLOY_USER" "$REPO_HOST" 'tar -C /var/www/repo -xpf -'; then
  die "推送失敗"
fi

# 2. 確認：上面有哪些目錄、confluent/ 底下有幾項
published=$(ssh_run_as "$REPO_DEPLOY_USER" "$REPO_HOST" 'echo "$(ls /var/www/repo | paste -sd" ")；confluent/ 有 $(ls /var/www/repo/confluent | wc -l) 個檔"')
ok "$REPO_HOST:/var/www/repo：$published"

section "從操作機用 HTTPS 讀回來（repoquery 不管本機裝了沒都會列；dnf list available 會漏掉已裝的）"
package_count=$(count_published_packages)

if [ "$package_count" -ge 11 ]; then
  ok "套件庫看得到 $package_count 個 confluent 套件"
else
  die "套件庫只看到 $package_count 個套件（預期 11）"
fi

finish_step
