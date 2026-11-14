#!/usr/bin/env bash
# package.sh <輸出目錄>：把 CBOM 工具打包成交付物（維護這個專案的人用；手冊第 33 章的讀者拿到的就是這兩個檔）
#   <輸出目錄>/cbom-kit-<日期>.<內容雜湊前 8 碼>.tar.gz   內容不同檔名就不同，不會蓋掉舊版
#   <輸出目錄>/SHA256SUMS                                讀者複製進落地區後用它核對（3.4 的做法）
# 交付物的內容（解開是 cbom-kit/）：
#   cbom-tools.jar      把原料做成 CBOM、把判斷結果做成報告（需要 JDK 17 以上）
#   cbomkit-theia       掃憑證檔的工具（我們從原廠原始碼編的靜態執行檔）
#   policy/             OPA 的規則與規則的測試
#   cbom-collect.sh     操作機上的收集腳本（手冊 33.4–33.7 的同一套指令）
#   cbom-report.sh      原料 → CBOM → 規則判斷 → 報告（手冊 33.8；Jenkins 也叫這一支）
#   lib/cbom-lib.sh     上面兩支腳本共用的函式
#   Jenkinsfile         Jenkins pipeline（有的話）
#   VERSIONS            各元件的版本與 sha256
# 先跑 build.sh 產生 dist/；輸出目錄裡舊版的 tar 會先刪掉，只留這一版。
#
# 誰在哪裡執行：維護的人在 Windows Git Bash；docs/journey-src/tools/run-full.sh 跑第 33 章時也會叫它。
# 用法例子：bash cbom/package.sh ~/kafka-lab/landing/cbom（目錄是舉例；相對路徑從專案根目錄算）
# 結束碼：0 打包完成；1 沒給輸出目錄，或 cbom/dist/ 還沒建好；其他非 0 是 cp、tar 自己失敗（set -e）。
set -euo pipefail

# ${1:?訊息}：沒給第一個參數就印出這個訊息並結束（結束碼 1）
out=${1:?用法：bash package.sh <輸出目錄>}

# 1. 到 cbom/ 的上一層（相對路徑的輸出目錄也從這裡算）
script_dir=$(dirname "$0")
cd "$script_dir/.."

if [ ! -f cbom/dist/cbom-tools.jar ] || [ ! -f cbom/dist/cbomkit-theia ]; then
  echo "cbom/dist/ 還沒有建好的檔：先跑 bash cbom/build.sh"
  exit 1
fi

# 2. 把要交付的檔排進暫存目錄 cbom-kit/
stage=$(mktemp -d)
mkdir -p "$stage/cbom-kit/policy"
cp cbom/dist/cbom-tools.jar cbom/dist/cbomkit-theia cbom/dist/VERSIONS "$stage/cbom-kit/"
cp cbom/policy/*.rego "$stage/cbom-kit/policy/"
cp cbom/cbom-collect.sh "$stage/cbom-kit/"
cp cbom/cbom-report.sh "$stage/cbom-kit/"
mkdir -p "$stage/cbom-kit/lib"
cp cbom/lib/cbom-lib.sh "$stage/cbom-kit/lib/"

if [ -f cbom/Jenkinsfile ]; then
  cp cbom/Jenkinsfile "$stage/cbom-kit/"
fi

# web app 那條路（cbom/webapp/）不進這一包：它不屬於 Confluent Platform 的交付物，環境由 cbom/webapp/lab.sh 直接從這個專案建

# 在 Windows 上打包保不住執行權限：手冊 33.3 安裝時用 install -m 755 明確設定

# 3. 內容雜湊：所有檔案排好順序接起來算 sha256，取前 8 碼
#    先記下現在的目錄（專案根目錄），進暫存目錄算完再回來：第 4 步相對路徑的輸出目錄要從專案根目錄算
#    LC_ALL=C sort：固定用位元組順序排，雜湊才不會因為機器的語系設定而不同
start_dir=$(pwd)
cd "$stage"
file_list=$(find cbom-kit -type f | LC_ALL=C sort)
content_sha=$(echo "$file_list" | xargs cat | sha256sum)
cd "$start_dir"
#    檔名用的版本。例：20261113.3fa9c2d1（日期.內容雜湊前 8 碼）
short_sha=$(echo "$content_sha" | cut -c1-8)
v="$(date +%Y%m%d).$short_sha"

# 4. 清掉舊版、打包
mkdir -p "$out"
rm -f "$out"/cbom-kit-*.tar.gz "$out/SHA256SUMS"
tar -czf "$out/cbom-kit-$v.tar.gz" -C "$stage" cbom-kit
rm -rf "$stage"

# 5. 算核對用的 SHA256SUMS 並印出來
cd "$out"
sha256sum "cbom-kit-$v.tar.gz" > SHA256SUMS
cat SHA256SUMS
