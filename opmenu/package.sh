#!/usr/bin/env bash
# package.sh <輸出目錄>：把選單打包成交付物（維護選單的人用；手冊第 16.3 節的讀者拿到的就是這兩個檔，不需要這個 git 專案）
#   <輸出目錄>/opmenu-<日期>.<內容雜湊前 8 碼>.tar.gz   內容不同檔名就不同，不會蓋掉舊版
#   <輸出目錄>/SHA256SUMS                               讀者複製進落地區後用它核對（3.4 的做法）
# 交付手冊時把這兩個檔一起給；輸出目錄裡舊版的 tar 會先刪掉，只留這一版。
set -euo pipefail
out=${1:?用法：bash package.sh <輸出目錄>}
src=$(cd "$(dirname "$0")/.." && pwd)            # 這支腳本所在的 opmenu/ 的上一層
cd "$src"
v=$(date +%Y%m%d).$(find opmenu -type f -not -path 'opmenu/tests/*' | LC_ALL=C sort | xargs cat | sha256sum | cut -c1-8)
mkdir -p "$out"; rm -f "$out"/opmenu-*.tar.gz "$out/SHA256SUMS"
tar -czf "$out/opmenu-$v.tar.gz" --exclude='opmenu/tests' opmenu
(cd "$out" && sha256sum "opmenu-$v.tar.gz" > SHA256SUMS && cat SHA256SUMS)
