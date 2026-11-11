#!/usr/bin/env bash
# package.sh <輸出目錄>：把 CBOM 工具打包成交付物（維護這個專案的人用；手冊第 33 章的讀者拿到的就是這兩個檔）
#   <輸出目錄>/cbom-kit-<日期>.<內容雜湊前 8 碼>.tar.gz   內容不同檔名就不同，不會蓋掉舊版
#   <輸出目錄>/SHA256SUMS                                讀者複製進落地區後用它核對（3.4 的做法）
# 交付物的內容（解開是 cbom-kit/）：
#   cbom-tools.jar      把原料做成 CBOM、把判斷結果做成報告（需要 JDK 17 以上）
#   cbomkit-theia       掃憑證檔的工具（我們從原廠原始碼編的靜態執行檔）
#   policy/             OPA 的規則與規則的測試
#   cbom-collect.sh     操作機上的收集腳本（手冊 33.4–33.7 的同一套指令）
#   Jenkinsfile         Jenkins pipeline（有的話）
#   VERSIONS            各元件的版本與 sha256
# 先跑 build.sh 產生 dist/；輸出目錄裡舊版的 tar 會先刪掉，只留這一版。
set -euo pipefail

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

if [ -f cbom/Jenkinsfile ]; then
  cp cbom/Jenkinsfile "$stage/cbom-kit/"
fi

# 在 Windows 上打包保不住執行權限：手冊 33.3 安裝時用 install -m 755 明確設定

# 3. 內容雜湊：所有檔案排好順序接起來算 sha256，取前 8 碼
file_list=$(cd "$stage" && find cbom-kit -type f | LC_ALL=C sort)
content_sha=$(cd "$stage" && echo "$file_list" | xargs cat | sha256sum)
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
