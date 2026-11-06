#!/usr/bin/env bash
# package.sh <輸出目錄>：把選單打包成交付物（維護選單的人用；手冊第 16.3 節的讀者拿到的就是這兩個檔，不需要這個 git 專案）
#   <輸出目錄>/opmenu-<日期>.<內容雜湊前 8 碼>.tar.gz   內容不同檔名就不同，不會蓋掉舊版
#   <輸出目錄>/SHA256SUMS                               讀者複製進落地區後用它核對（3.4 的做法）
# 交付手冊時把這兩個檔一起給；輸出目錄裡舊版的 tar 會先刪掉，只留這一版。
set -euo pipefail

out=${1:?用法：bash package.sh <輸出目錄>}

# 1. 到這支腳本所在的 opmenu/ 的上一層（相對路徑的輸出目錄也從這裡算）
script_dir=$(dirname "$0")
cd "$script_dir/.."

# 2. 內容雜湊：tests/ 以外的所有檔案，排好順序接起來算 sha256，取前 8 碼
file_list=$(find opmenu -type f -not -path 'opmenu/tests/*' | LC_ALL=C sort)
content_sha=$(echo "$file_list" | xargs cat | sha256sum)
short_sha=$(echo "$content_sha" | cut -c1-8)
v="$(date +%Y%m%d).$short_sha"

# 3. 清掉舊版、打包
mkdir -p "$out"
rm -f "$out"/opmenu-*.tar.gz "$out/SHA256SUMS"
tar -czf "$out/opmenu-$v.tar.gz" --exclude='opmenu/tests' opmenu

# 4. 算核對用的 SHA256SUMS 並印出來
cd "$out"
sha256sum "opmenu-$v.tar.gz" > SHA256SUMS
cat SHA256SUMS
