#!/usr/bin/env bash
# 第 2 站：把東西送進銀行 —— 掃描與開單、檔案交換是銀行的事；我方在操作機再驗一次
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"

bank "2.1 資安：落地區所有檔案（rpm/、tools/、gpg-keys/、SHA256SUMS、bank/ 的 JDK）上傳行內惡意程式掃描平台取得 OK 報告；" \
     "    開單附安裝檔、掃描報告、SHA256SUMS。注意 confluent-security（1.1 GB）、C3（1.0 GB）單檔超過 1 GB，先確認平台上限。" \
     "2.2 檔案交換：核准後由行內檔案交換平台把整個落地區送到操作機 $LANDING（擁有者 cpadmin，唯讀 a-w）。"

section "2.3 進內網後再驗一次（證明搬運途中沒被動過）"
[ -f "$LANDING/SHA256SUMS" ] || { fail "$LANDING/SHA256SUMS 不存在：檔案還沒送到操作機"; pending; }
(cd "$LANDING" && sha256sum -c --quiet SHA256SUMS) && ok "$(wc -l < "$LANDING/SHA256SUMS") files OK（sha256 全部相符）" || die "SHA256SUMS 核對失敗：檔案和下載機上的不一致，退回重送"
sudo rpm --import "$LANDING"/gpg-keys/confluent.asc "$LANDING"/gpg-keys/confluent-c3.asc || die "匯入原廠公鑰失敗"
n=$(ls "$LANDING"/rpm/*.rpm | wc -l); bad=$(rpm -K "$LANDING"/rpm/*.rpm | grep -vc 'digests signatures OK$' || true)
[ "$bad" = 0 ] && ok "rpm -K：$n 個 RPM 都是 digests signatures OK" || die "$bad 個 RPM 原廠簽章不符"
finish
