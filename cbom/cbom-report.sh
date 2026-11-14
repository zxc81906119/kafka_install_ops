#!/usr/bin/env bash
# ============================================================================
# 原料目錄 → CBOM → 規則判斷 → 報告。Confluent Platform 與 web app 的後半段相同，都叫這一支。
# （前半段「原料怎麼來」不同：cbom-collect.sh、webapp/webapp-collect.sh。）
#
#: 用法：
#:   bash cbom-report.sh <步驟> --raw <原料目錄> --out <輸出目錄> [--spec 1.7|1.6] [--cbomkit <網址> --project <名稱>]
#:                              [--expected <標準答案.json>]
#:   步驟：build     原料 → <輸出>/cbom.json（通過 CycloneDX 官方 schema 驗證）
#:         evaluate  先跑規則自己的測試，再判斷 → <輸出>/findings.json、<輸出>/counts.json
#:         report    <輸出>/report.html（單一檔，下載用）、<輸出>/html/index.html（樣式另放，給 Jenkins 顯示）
#:         upload    （選配）只留密碼學資產，上傳到 CBOMkit 平台供瀏覽；失敗不影響結果
#:         verdict   印出各等級的數量；合規回 0，有違規回 3
#:         inventory （選配，要給 --expected）拿這次的 cbom.json、findings.json 對標準答案 → <輸出>/inventory-check.txt；
#:                   只是量測，不影響合規結果（web app 用；Confluent Platform 沒有標準答案）
#:         all       build → evaluate → report → verdict（有給 --cbomkit 時 report 之後多做 upload；不含 inventory）
#:   例：bash cbom-report.sh all --raw ~/cbom/raw --out ~/cbom/out
#:       bash cbom-report.sh verdict --out ~/cbom/out
#:       bash cbom-report.sh inventory --out out --expected src/expected-inventory.json
#
# 誰在哪裡執行：Confluent Platform 是操作機的 root（手冊 33.8）或 Jenkins agent（cbom/Jenkinsfile）；
#               web app 是 Jenkins agent（cbom/webapp/Jenkinsfile）。兩邊都裝在 $CBOM_HOME/bin（預設 /opt/cbom/bin）。
# 輸入：原料目錄（格式見 lib/cbom-lib.sh 開頭；只有 build 讀它），其他步驟讀前一步在 <輸出> 產生的檔；
#       inventory 另外讀 --expected 給的標準答案（web app 是原始碼裡的 expected-inventory.json）。
# 輸出（都在 <輸出目錄>）：cbom.json、findings.json、counts.json、report.html、html/index.html＋html/report.css、
#       cbom-crypto-only.json（只有 upload）、inventory-check.txt（只有 inventory）。
# 需要：JDK 17 以上（java）、$CBOM_HOME/bin 的 cbom-tools.jar 與 opa、$CBOM_HOME/policy、$CBOM_HOME/lib/cbom-lib.sh；
#       upload 另外要 curl。
# 結束碼：0 成功（verdict：合規）；1 用法不對（沒給步驟、參數不認得、少了必要的參數）；
#         2 原料檢查不合格（check_raw）；3 不合規（只有 verdict 與 all 會回）；
#         其他非 0：java 或 opa 自己失敗（set -e，那個程式的結束碼原樣傳出來，訊息在它上面幾行）。
#         inventory 是量測：對出來有沒找到的項目也回 0，只有檔案讀不到才非 0。
# ============================================================================
set -euo pipefail

CBOM_HOME=${CBOM_HOME:-/opt/cbom}
# shellcheck disable=SC1091
source "$CBOM_HOME/lib/cbom-lib.sh"

jar=$CBOM_HOME/bin/cbom-tools.jar
opa=$CBOM_HOME/bin/opa
policy=$CBOM_HOME/policy

# 沒給步驟：印出檔頭「#:」開頭的那幾行當用法說明（sed 去掉開頭的「#:」與後面一個空白）
#   例：「#:   bash cbom-report.sh <步驟> …」→「  bash cbom-report.sh <步驟> …」
step=${1:-}
if [ -z "$step" ]; then
  sed -n 's/^#: \{0,1\}//p' "$0"
  exit 1
fi

shift

# 參數的預設值：--spec 沒給就是 1.7；--cbomkit、--project 只有 upload 用；--expected 只有 inventory 用
raw=
out=
spec=1.7
cbomkit=
project=
expected=

while [ $# -gt 0 ]; do
  case "$1" in
    --raw)
      raw=$2
      shift 2
      ;;
    --out)
      out=$2
      shift 2
      ;;
    --spec)
      spec=$2
      shift 2
      ;;
    --cbomkit)
      cbomkit=$2
      shift 2
      ;;
    --project)
      project=$2
      shift 2
      ;;
    --expected)
      expected=$2
      shift 2
      ;;
    *)
      fail 1 "不認得的參數 $1"
      ;;
  esac
done

if [ -z "$out" ]; then
  fail 1 "--out 要給（輸出目錄，例如 --out ~/cbom/out）"
fi

mkdir -p "$out/html"

# step_build：原料目錄 → <輸出>/cbom.json。先檢查原料（沒有私鑰、密碼都遮了），再由 cbom-tools 合併各層並驗證 schema
#   失敗代表：原料不合格（結束碼 2），或某一層的原料格式不對、產出的 CBOM 沒通過 CycloneDX schema（java 的訊息會說哪裡）
step_build() {
  if [ -z "$raw" ]; then
    fail 1 "build 要給 --raw"
  fi

  check_raw "$raw"
  java -jar "$jar" build "$raw" "$out/cbom.json" --spec "$spec"
}

# step_evaluate：<輸出>/cbom.json ＋ 規則（policy/）→ findings.json（每一筆發現與等級）、counts.json（各等級幾筆）
#   findings.json 是 opa eval 的完整回應（報告程式讀這個）；counts.json 只有數量那一小段，給人看與 Jenkins 顯示
#   失敗代表：規則的測試沒過（規則被改壞），或 cbom.json 不在（先做 build）
step_evaluate() {
  # 先跑規則自己的測試：規則檔被改壞的話在這裡就停
  "$opa" test "$policy/"
  "$opa" eval --data "$policy/" --input "$out/cbom.json" --format json "data.cbom.report" > "$out/findings.json"
  "$opa" eval --data "$policy/" --input "$out/cbom.json" --format raw "data.cbom.report.counts" > "$out/counts.json"
}

# step_report：cbom.json ＋ findings.json → 兩份內容相同的 HTML 報告
#   report.html       樣式寫在檔案裡，單一檔，下載後直接開
#   html/index.html   樣式另外放 html/report.css（--external-css）：Jenkins 的安全政策（CSP）不讓頁面用內嵌樣式
step_report() {
  java -jar "$jar" report "$out/cbom.json" "$out/findings.json" "$out/report.html"
  java -jar "$jar" report "$out/cbom.json" "$out/findings.json" "$out/html/index.html" --external-css
}

# step_upload：（選配）cbom.json → cbom-crypto-only.json → POST 到 CBOMkit 平台的 <網址>/api/v1/cbom/<專案名稱>
#   例：--cbomkit http://demo-opa-api:8081 --project crypto-lab-webapp
#   連不上或 CBOMkit 回錯誤（curl 失敗）只印一行訊息，不算失敗；
#   但前一步「挑出密碼學資產」（java crypto-only）失敗的話，這一步還是會失敗（set -e）
step_upload() {
  if [ -z "$cbomkit" ] || [ -z "$project" ]; then
    fail 1 "upload 要給 --cbomkit 與 --project"
  fi

  # CBOMkit 內建的合規檢查遇到沒有 cryptoProperties 的元件（file、library）會出錯：只送密碼學資產
  java -jar "$jar" crypto-only "$out/cbom.json" "$out/cbom-crypto-only.json"
  if curl -fsS -o /dev/null -X POST -H "Content-Type: application/json" \
    --data-binary "@$out/cbom-crypto-only.json" "$cbomkit/api/v1/cbom/$project"; then
    say "已上傳到 $cbomkit（專案 $project）"
  else
    # 要查原因：這台連不連得到 $cbomkit、CBOMkit API 容器的 log
    say "上傳 CBOMkit 失敗（它只是檢視器，不影響這次的結果）"
  fi
}

# step_inventory：（選配）對答案。cbom.json ＋ findings.json ＋ 標準答案 → inventory-check.txt（摘要同時印到畫面）
#   例：--out out --expected src/expected-inventory.json → out/inventory-check.txt（列出沒找到與等級不符的項目）
#   量測用：有項目沒找到也回 0；失敗只代表檔案讀不到（先做 build 與 evaluate，或 --expected 的路徑不對）
step_inventory() {
  if [ -z "$expected" ]; then
    fail 1 "inventory 要給 --expected（標準答案，例如 --expected src/expected-inventory.json）"
  fi

  if [ ! -f "$expected" ]; then
    fail 1 "找不到標準答案 $expected（--expected 要指到 expected-inventory.json）"
  fi

  java -jar "$jar" check-inventory "$out/cbom.json" "$out/findings.json" "$expected" "$out/inventory-check.txt"
}

# step_verdict：印一行結論，並用結束碼告訴呼叫的人。合規（規則的 compliant 是 true）回 0；有違規項目回 3
#   例：「合規：沒有違規項目 <counts.json 的內容：各等級的數量>」
#   只有等級是 violation 的發現算不合規；其他等級只出現在報告與數量裡
step_verdict() {
  local compliant counts

  compliant=$("$opa" eval --data "$policy/" --input "$out/cbom.json" --format raw "data.cbom.report.compliant")
  counts=$(cat "$out/counts.json")

  if [ "$compliant" = true ]; then
    echo "合規：沒有違規項目 $counts"
    return 0
  fi

  echo "不合規：有違規項目 $counts，看報告的「違規」一節"
  return 3
}

case "$step" in
  build) step_build ;;
  evaluate) step_evaluate ;;
  report) step_report ;;
  upload) step_upload ;;
  verdict) step_verdict ;;
  inventory) step_inventory ;;
  all)
    step_build
    step_evaluate
    step_report
    if [ -n "$cbomkit" ]; then
      step_upload
    fi

    step_verdict
    ;;
  *) fail 1 "不認得的步驟 $step（可以用的：build evaluate report upload verdict inventory all）" ;;
esac
