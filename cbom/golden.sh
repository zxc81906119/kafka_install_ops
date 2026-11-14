#!/usr/bin/env bash
# golden.sh：改了 cbom-tools 或規則之後，確認產出沒有意外改變（維護這個專案的人用）
#
# 做法：用固定的兩份原料（Confluent Platform、web app 各一份）各產生 1.7 與 1.6 的 CBOM、判定結果、報告，
# 共八個檔，算雜湊，和上次記下的基準比。原料與基準放在 volume cbom-build 的 golden/（原料有 lab 的端點與憑證，不進 git）。
#
# 用法（Windows Git Bash；先 bash cbom/build.sh 建好 dist/）：
#   bash cbom/golden.sh check     比對；八個都相同才算過，不同的會列出來
#   bash cbom/golden.sh rebase    產出改變是預期的：把這次的結果記成新的基準
# 需要：podman 的 machine 在跑。不需要 Kafka lab。
#
# 輸入：cbom/dist/cbom-tools.jar、cbom/policy/（這次要檢查的版本）；volume cbom-build 的 golden/ 裡有
#   cp-raw/    固定的原料：Confluent Platform（cbom-collect.sh 收回來的整個原料目錄）
#   web-raw/   固定的原料：web app（webapp-collect.sh 收回來的整個原料目錄）
#   base.sha   上次記下的基準（八行「雜湊 檔名」）；prev.sha 是再上一次的
# 輸出：畫面上每個檔一行「相同  檔名」或「不同  檔名」；volume 裡的 golden/new.sha（這次的雜湊）、golden/now/out/（這次的產出）。
#       rebase 另外把 base.sha 換成這次的、舊的留在 prev.sha。
# 結束碼：0 八個都相同（rebase：已記成新基準）；3 有檔案和基準不同；1 還沒建 dist/，或 volume 裡沒有原料；
#         64 用法不對（動作不是 check 或 rebase）；其他非 0 是 java、opa 或 podman 自己失敗。
#
# 這台機器還沒有原料（第一次，或 volume 被刪掉）時怎麼建：
#   1. 各跑一次收集，拿到兩個原料目錄（Confluent Platform：手冊 33.4–33.7 或 Jenkins 的工作 cbom；
#      web app：Jenkins 的工作 cbom-webapp 或 webapp-collect.sh all）。
#   2. 開一個掛著 volume 的容器，把兩個目錄複製進去，名稱要是 cp-raw 與 web-raw：
#        podman run -d --name cbom-golden --user root --entrypoint sleep -v cbom-build:/root/cbom <BUILD_IMAGE> infinity
#        podman exec cbom-golden mkdir -p /root/cbom/golden
#        podman cp <Confluent Platform 的原料目錄> cbom-golden:/root/cbom/golden/cp-raw
#        podman cp <web app 的原料目錄> cbom-golden:/root/cbom/golden/web-raw
#        podman rm -f cbom-golden
#   3. bash cbom/golden.sh rebase（沒有舊基準時就是建立第一份）。
#   OPA 的執行檔在同一個 volume 的 cov/bin/opa（和 cbom/webapp/lab.sh 下載的是同一個檔，複製進去即可）。
set -euo pipefail
# Git Bash 會把 /root/cbom 這類參數改成 Windows 路徑：對這支腳本裡的 podman 全部關掉
export MSYS_NO_PATHCONV=1

BUILD_IMAGE=docker.io/jenkins/jenkins:2.580.2-lts-jdk21
CONTAINER=cbom-golden
BUILD_VOLUME=cbom-build

# 動作不對：印出檔頭第 2 到 10 行（用途與用法）當說明
action=${1:-}
if [ "$action" != check ] && [ "$action" != rebase ]; then
  sed -n '2,10p' "$0"
  exit 64
fi

script_dir=$(dirname "$0")
cd "$script_dir"

if [ ! -f dist/cbom-tools.jar ]; then
  echo "找不到 dist/cbom-tools.jar：先跑 bash cbom/build.sh"
  exit 1
fi

# 1. 臨時容器
#    映像和 build.sh 用同一個（有 JDK 21）；--entrypoint sleep … infinity：容器一直開著，讓後面的 podman exec 進去做事
#    -m 1500m：這個容器最多用 1.5 GB 記憶體
podman rm -f --ignore "$CONTAINER" > /dev/null
podman run -d --name "$CONTAINER" --user root --entrypoint sleep -m 1500m \
  -v "$BUILD_VOLUME:/root/cbom" "$BUILD_IMAGE" infinity > /dev/null

# 2. 原料要在：兩個原料目錄各有一個 collect.env
if ! podman exec "$CONTAINER" test -f /root/cbom/golden/cp-raw/collect.env; then
  podman rm -f "$CONTAINER" > /dev/null
  echo "volume $BUILD_VOLUME 裡沒有 golden/cp-raw：這台機器還沒有原料，做法寫在這支腳本的檔頭"
  exit 1
fi

if ! podman exec "$CONTAINER" test -f /root/cbom/golden/web-raw/collect.env; then
  podman rm -f "$CONTAINER" > /dev/null
  echo "volume $BUILD_VOLUME 裡沒有 golden/web-raw：這台機器還沒有原料，做法寫在這支腳本的檔頭"
  exit 1
fi

# 3. 這次的 jar 與規則送進去
podman exec "$CONTAINER" rm -rf /root/cbom/golden/now
podman exec "$CONTAINER" mkdir -p /root/cbom/golden/now
podman cp "$(cygpath -m dist/cbom-tools.jar)" "$CONTAINER:/root/cbom/golden/now/cbom-tools.jar"
podman cp "$(cygpath -m policy)" "$CONTAINER:/root/cbom/golden/now/policy"

# 4. 在容器裡產生八個檔、算雜湊、和基準逐行比
#    EOF 之間那一段在容器裡執行；整段放在 if 裡，失敗時先把結束碼記進 result，刪掉容器之後才結束
if podman exec -i -e HOME=/root "$CONTAINER" bash -e -s -- "$action" <<'EOF'
action=$1
cd ~/cbom/golden
jar=now/cbom-tools.jar
policy=now/policy
out=now/out
opa=~/cbom/cov/bin/opa
mkdir -p "$out"

# 4.1 兩份原料（cp、web）各做四件事：1.7 的 CBOM、1.6 的 CBOM、OPA 的判定、HTML 報告
for subject in cp web; do
  java -jar "$jar" build "$subject-raw" "$out/$subject-17.json" > /dev/null
  java -jar "$jar" build "$subject-raw" "$out/$subject-16.json" --spec 1.6 > /dev/null
  "$opa" eval -d "$policy" -i "$out/$subject-17.json" --format json "data.cbom.report" > "$out/$subject-findings.json"
  java -jar "$jar" report "$out/$subject-17.json" "$out/$subject-findings.json" "$out/$subject-report.html" > /dev/null
done

# 4.2 八個檔的雜湊寫到 new.sha，一行一個「雜湊的前 16 個字 檔名」
#     例：sha256sum 印「4d5d2825b48919e8…（共 64 個字）  cp-17.json」→ cut 留第 1–16 個字與第 65 個字以後
#         →「4d5d2825b48919e8  cp-17.json」
files="cp-17.json cp-16.json cp-findings.json cp-report.html web-17.json web-16.json web-findings.json web-report.html"
cd "$out"
# shellcheck disable=SC2086
sha256sum $files | cut -c1-16,65- > ../../new.sha
cd ~/cbom/golden

# 4.3 rebase：把這次的記成基準（有舊的就留一份在 prev.sha）
if [ "$action" = rebase ]; then
  if [ -f base.sha ]; then
    cp base.sha prev.sha
  fi

  cp new.sha base.sha
  echo "已記成新的基準（上一份留在 prev.sha）"
  cat base.sha
  exit 0
fi

# 4.4 check：一行一行比。用檔名到 base.sha 找同一個檔的雜湊
#     例：new.sha 的「4d5d2825b48919e8  cp-17.json」→ grep " cp-17.json$" base.sha → 取第 1 欄來比
if [ ! -f base.sha ]; then
  echo "還沒有基準（base.sha）：先 bash cbom/golden.sh rebase"
  exit 1
fi

different=0
while read -r hash name; do
  base=$(grep " $name\$" base.sha | cut -d' ' -f1)
  if [ "$hash" = "$base" ]; then
    echo "相同  $name"
  else
    echo "不同  $name"
    different=$((different + 1))
  fi
done < new.sha

if [ "$different" -gt 0 ]; then
  echo "有 $different 個檔和基準不同：是預期的就 bash cbom/golden.sh rebase"
  exit 3
fi

echo "八個檔都和基準相同"
EOF
then
  result=0
else
  # $? 在這裡是上面 podman exec（也就是容器裡那一段）的結束碼：3 = 有檔案不同
  result=$?
fi

podman rm -f "$CONTAINER" > /dev/null
exit "$result"
