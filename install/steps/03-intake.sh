#!/usr/bin/env bash
# 第 3 站：把東西送進銀行 —— 掃描與開單、檔案交換是銀行的事；我方在操作機再驗一次
# where: ops02 （root）
#
# 做什麼：印出銀行要做的事 → 檔案送到後，用一起送進來的 SHA256SUMS 核對、用原廠公鑰驗 RPM 簽章。
# 需要：落地區整包已送到 $LANDING（銀行的檔案交換）。
# 產出：無（只核對；原廠公鑰匯入操作機的 rpm 資料庫）。
# 重跑：安全（只讀不寫）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"

# landing_checksums_ok：用 SHA256SUMS 核對落地區（不符的檔案會一個一個列出來；sha256sum 要在落地區跑）
landing_checksums_ok() {
  (
    if ! cd "$LANDING"; then
      exit 1
    fi

    sha256sum -c --quiet SHA256SUMS
  )
}

scan_request="3.1 資安：落地區所有檔案（rpm/ 安裝基底、rpm-target/ 遷移目標、tools/、gpg-keys/、monitoring/、SHA256SUMS、"
scan_request+="bank/ 的兩個 JDK）上傳行內惡意程式掃描平台取得 OK 報告；"

ask_bank "$scan_request" \
         "    開單附安裝檔、掃描報告、SHA256SUMS。注意 confluent-security（約 1 GB）、C3（約 1 GB）單檔超過 1 GB，先確認平台上限；兩套合計約 6 GB。" \
         "3.2 檔案交換：核准後把整個落地區送到操作機 $LANDING（唯讀 a-w）。"

section "3.3 進內網後再驗一次（證明搬運途中沒被動過）"
# 1. 檔案送到了沒
if [ ! -f "$LANDING/SHA256SUMS" ]; then
  fail "$LANDING/SHA256SUMS 不存在：檔案還沒送到操作機"
  wait_for_bank
fi

# 2. 核對 sha256
if landing_checksums_ok; then
  ok "$(wc -l < "$LANDING/SHA256SUMS") 個檔 sha256 全部相符"
else
  die "SHA256SUMS 核對失敗：檔案和下載機上的不一樣，退回重送"
fi

# 3. 驗原廠簽章：rpm -K 只認 rpm 資料庫裡的公鑰，所以先匯入原廠公鑰
if ! rpm --import "$LANDING/gpg-keys/confluent.asc" "$LANDING/gpg-keys/confluent-c3.asc"; then
  die "匯入原廠公鑰失敗"
fi

rpm_count=$(ls "$LANDING"/rpm/*.rpm "$LANDING"/rpm-target/*.rpm | wc -l)
bad_signature_count=$(rpm -K "$LANDING"/rpm/*.rpm "$LANDING"/rpm-target/*.rpm \
  | awk '!/digests signatures OK$/ {c++} END {print c + 0}')

if [ "$bad_signature_count" = 0 ]; then
  ok "rpm -K：兩套共 $rpm_count 個 RPM 都是 digests signatures OK"
else
  die "$bad_signature_count 個 RPM 原廠簽章不符"
fi

finish_step
