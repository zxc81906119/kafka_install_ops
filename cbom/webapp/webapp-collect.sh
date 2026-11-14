#!/usr/bin/env bash
# ============================================================================
# web app 的密碼學資產收集：照 app 的生命週期分三段，產出「原料目錄」給 cbom-tools 合併成 CBOM。
#
#   建置時（不需要 app 在跑）
#     build    ./mvnw verify → jar，以及建置自己產生的 SBOM（相依的函式庫）
#     source   原始碼掃描：cbomkit-action（容器），掃建置過的專案
#     files    原始碼目錄裡的憑證、私鑰、寫死的秘密：cbomkit-theia dir
#   部署物
#     image    建成容器映像；cbomkit-theia image 掃映像；讀映像裡 JDK 與 OS 的密碼設定
#   執行期（選用，要 app 跑起來）
#     runtime  用映像啟動 app（帶 JFR）→ 把端點打一輪 → testssl.sh 掃 TLS → 取回 JFR 的紀錄
#
#: 用法：
#:   bash webapp-collect.sh <步驟> --src <原始碼目錄> --raw <原料目錄> [--work <暫存目錄>]
#:   步驟：init build source files image runtime finish，一次一個；或 all（= init build source files image finish）
#:         all 加 --runtime 才會做執行期那段
#:   之後：bash cbom-report.sh all --raw <原料目錄> --out <輸出目錄>（和 Confluent Platform 共用的後半段）
#:   例：bash webapp-collect.sh all --src ~/crypto-lab --raw ~/cbom/raw-webapp --runtime
#
# 誰在哪裡執行：Jenkins agent（cbom/webapp/Jenkinsfile 一個 stage 叫一個步驟），或人在有 podman 的 Linux 主機上手動執行。
# 輸入：web app 的原始碼目錄（要有 pom.xml、mvnw、$APP_CONTAINERFILE；執行期另外要 $APP_EXERCISE）。
# 輸出：原料目錄。每個步驟產生的檔，與之後 cbom-tools 的哪一層讀它：
#   init     collect.env                                   這次的範圍（每一層都讀）
#   build    shared/jars/groups.txt、sbom-<雜湊>.json       建置產生的 SBOM              → LibraryLayer
#   source   shared/source/cbom.json                       cbomkit-action 掃原始碼      → SourceCodeLayer
#   files    shared/theia.json                             cbomkit-theia 掃原始碼目錄   → FilesLayer
#   image    shared/theia-image.json                       cbomkit-theia 掃映像         → ImageLayer
#            app/java.security、java-version.txt、java-security-effective.txt、os-crypto.txt → JdkSettingsLayer
#   runtime  app/tls/<埠>.json                             testssl.sh                   → TlsScanLayer
#            app/jfr/service.json                          JFR                          → RuntimeLayer
#            app/served/<埠>.pem                           這個埠出示的憑證（留作證據；web app 這條路沒有程式讀它）
#   暫存目錄（預設 <原料目錄>.work）放掃描工具的 log，finish 會刪掉；某一步失敗時它還在，訊息會指到裡面的 log。
#
# 需要：bash、curl、tar、unzip、openssl、podman（本機或連到遠端引擎都可以）、JDK 17 以上（java、jfr）、
#       $CBOM_HOME/bin 的 cbomkit-theia 與 testssl/testssl.sh（testssl.sh 另外要 host 或 dig、hexdump）、
#       $CBOM_HOME/lib/cbom-lib.sh、$CBOM_HOME/VERSIONS。
# 設定：下面「設定」一段的變數，可以用環境變數或 /etc/cbom/webapp.conf 改。
# 原料裡不會有金鑰內容：theia 只記位置與種類；finish 會再檢查一次。
# 結束碼：0 成功；64 沒給步驟（印用法）；1 參數不對；2 某一步失敗（訊息會說看哪個 log）或原料檢查不合格；
#         其他非 0：被叫的程式（mvnw、podman …）自己失敗（set -e，訊息在上面幾行）。
#         （沒給步驟時 cbom-report.sh 回 1、這支回 64，兩支不一樣。）
# ============================================================================
set -euo pipefail

# ---------- 設定 ----------
if [ -f /etc/cbom/webapp.conf ]; then
  # shellcheck disable=SC1091
  source /etc/cbom/webapp.conf
fi

# ${名稱:-預設值}：環境變數或 webapp.conf 已經給了就用給的，沒給才用冒號後面的預設值
CBOM_HOME=${CBOM_HOME:-/opt/cbom}

# 要盤點的 app：名稱（pom.xml 的 artifactId）、HTTPS 的埠、映像名稱、Containerfile 在原始碼裡的位置
APP_NAME=${APP_NAME:-crypto-lab}
APP_PORT=${APP_PORT:-8443}
APP_IMAGE=${APP_IMAGE:-localhost/crypto-lab-web:cbom}
APP_CONTAINERFILE=${APP_CONTAINERFILE:-deploy/app/Containerfile}

# 執行期：映像裡的 JFR 設定檔、原始碼裡「把端點打一輪」的腳本、app 容器接的網路與記憶體上限
APP_JFR_SETTINGS=${APP_JFR_SETTINGS:-/deployments/crypto.jfc}
APP_EXERCISE=${APP_EXERCISE:-scripts/exercise-api.sh}
APP_NETWORK=${APP_NETWORK:-cbomnet}
APP_MEMORY=${APP_MEMORY:-768m}

# 寫進 CBOM 的網域與環境名稱（報告裡 app 的位置顯示成 app.<網域>:<埠>）
APP_DOMAIN=${APP_DOMAIN:-cbom.test}
ENV_NAME=${ENV_NAME:-weblab}

# 原始碼掃描的映像；它的 JVM 給 2g 的 heap、容器上限 3g（映像預設的 heap 是 16 GB，見 step_source）
ACTION_IMAGE=${ACTION_IMAGE:-ghcr.io/cbomkit/cbomkit-action:2.3.0}
ACTION_HEAP=${ACTION_HEAP:-2g}
ACTION_MEMORY=${ACTION_MEMORY:-3g}

# theia 會記住第一次執行時開的功能，所以每次都明確指定
THEIA_PLUGINS=${THEIA_PLUGINS:-certificates,secrets,javasecurity,opensslconf,problematicca}

# 共用的函式：say、fail、check_raw（和 Confluent Platform 的收集腳本同一份）
# shellcheck disable=SC1091
source "$CBOM_HOME/lib/cbom-lib.sh"

# ---------- 參數 ----------
# 沒給步驟：印出檔頭「#:」開頭的那幾行當用法說明（sed 去掉開頭的「#:」與後面一個空白）
step=${1:-}
if [ -z "$step" ]; then
  sed -n 's/^#: \{0,1\}//p' "$0"
  exit 64
fi

shift

src=
raw=
work=
with_runtime=no

while [ $# -gt 0 ]; do
  case "$1" in
    --src)
      src=$2
      shift 2
      ;;
    --raw)
      raw=$2
      shift 2
      ;;
    --work)
      work=$2
      shift 2
      ;;
    --runtime)
      with_runtime=yes
      shift
      ;;
    *)
      fail 1 "不認得的參數 $1"
      ;;
  esac
done

if [ -z "$src" ] || [ -z "$raw" ]; then
  fail 1 "--src 與 --raw 都要給（例：--src ~/crypto-lab --raw ~/cbom/raw-webapp）"
fi

if [ ! -f "$src/pom.xml" ]; then
  fail 1 "$src 裡沒有 pom.xml（--src 要指到 web app 原始碼的最上層）"
fi

# 沒給 --work：暫存目錄放在原料目錄旁邊。例：--raw /x/raw → /x/raw.work
if [ -z "$work" ]; then
  work=$raw.work
fi

# 三個目錄都換成完整路徑：後面有的步驟會 cd 到別的目錄，相對路徑會指錯地方
mkdir -p "$raw" "$work"
src=$(realpath "$src")
raw=$(realpath "$raw")
work=$(realpath "$work")

# cbomkit-theia 的位置：正常裝在 bin/；bin/ 裡沒有時改用 $CBOM_HOME 最上層的那一個
theia=$CBOM_HOME/bin/cbomkit-theia
if [ ! -x "$theia" ]; then
  theia=$CBOM_HOME/cbomkit-theia
fi

# find_jar：印出建置出來的 jar 的路徑（Spring Boot 重新打包前的 .original 副檔名不是 .jar，不會被選到）；沒有就停
#   例：jar=$(find_jar) → /…/src/target/crypto-lab-1.0.0.jar
find_jar() {
  local jar

  jar=$(find "$src/target" -maxdepth 1 -name '*.jar' | head -1)
  if [ -z "$jar" ]; then
    fail 2 "$src/target 裡沒有 jar：先做 build"
  fi

  echo "$jar"
}

# ---------- init：清空原料目錄，寫這次的範圍 ----------
# step_init：清掉上次的原料與暫存，產生 collect.env（格式和 Confluent Platform 的收集腳本相同，每一層都讀）
#   web app 只有一台「主機」叫 app、一種角色叫 webapp；主機目錄是 <原料>/app/
step_init() {
  local app_version action_version theia_version testssl_version
  local near_artifact

  rm -rf "$raw" "$work"
  mkdir -p "$raw/app" "$raw/shared" "$work"

  # app 的版本：pom.xml 裡 <artifactId>app 名稱</artifactId> 後面 3 行內的 <version>
  #   例：「<version>1.0.0</version>」→ grep -o 得「<version>1.0.0」→ 用 > 切開取第 2 段 → 1.0.0
  near_artifact=$(grep -m1 -A3 "<artifactId>$APP_NAME</artifactId>" "$src/pom.xml")
  app_version=$(echo "$near_artifact" | grep -o '<version>[^<]*' | cut -d'>' -f2)

  # 各工具的版本，寫進 collect.env 的 TOOLS
  # ${ACTION_IMAGE##*:}：去掉最後一個冒號以前的部分。例：ghcr.io/cbomkit/cbomkit-action:2.3.0 → 2.3.0
  action_version=${ACTION_IMAGE##*:}
  theia_version=$(grep '^cbomkit-theia ' "$CBOM_HOME/VERSIONS" | cut -d' ' -f2)
  # testssl.sh 的版本訊息帶顏色控制碼：直接取「數字.數字.數字」
  testssl_version=$("$CBOM_HOME/bin/testssl/testssl.sh" --version | grep -o '[0-9]*\.[0-9]*\.[0-9]*' | head -1)

  # CP_VERSION 這個欄位名稱是沿用 Confluent Platform 那邊的，web app 在這裡放 app 自己的版本
  # SUBJECT_NAME、SUBJECT_TYPE：CBOM 的盤點對象（只有 web app 要寫）
  cat > "$raw/collect.env" <<EOF
PROFILE=webapp
DOMAIN=$APP_DOMAIN
ENV=$ENV_NAME
CP_VERSION=$app_version
COLLECTED_AT=$(date +%Y-%m-%dT%H:%M:%S%:z)
ALL_ROLES=webapp
ROLES=webapp
HOSTS=app:webapp
JFR_SECONDS=
TOOLS=$(grep '^cbom-tools ' "$CBOM_HOME/VERSIONS"), cbomkit-action $action_version, cbomkit-theia $theia_version, testssl.sh $testssl_version
SUBJECT_NAME=$APP_NAME web app
SUBJECT_TYPE=application
EOF

  say "原料目錄 $raw；對象 $APP_NAME $app_version"
}

# ---------- build：建置，取 SBOM ----------
# step_build：用專案自己的 mvnw 建置並跑測試；建置時 cyclonedx-maven-plugin 順便產生 SBOM（相依的函式庫清單）
#   產出 shared/jars/groups.txt、shared/jars/sbom-<雜湊>.json（→ LibraryLayer）
#   失敗代表：編譯或測試沒過（mvnw 的訊息在上面），或 pom.xml 沒有產生 SBOM 的 plugin
step_build() {
  local jar sbom digest

  # 括號裡是子 shell：cd 只在裡面有效，出來還在原來的目錄
  say "建置（./mvnw verify，含測試）"
  (
    cd "$src"
    bash ./mvnw -B -q verify
  )

  jar=$(find_jar)
  sbom=$src/target/classes/META-INF/sbom/application.cdx.json
  if [ ! -f "$sbom" ]; then
    fail 2 "建置沒有產生 SBOM：$sbom（pom.xml 要有 cyclonedx-maven-plugin）"
  fi

  # 函式庫那層照 jar 的雜湊分組；web app 只有一組，主機名稱是 app
  #   組的雜湊 = jar 的 sha256 前 12 碼。groups.txt 例：「3f9a1c0b77de app」
  digest=$(sha256sum "$jar" | cut -c1-12)
  mkdir -p "$raw/shared/jars"
  echo "$digest app" > "$raw/shared/jars/groups.txt"
  cp "$sbom" "$raw/shared/jars/sbom-$digest.json"
  say "jar $(basename "$jar")；SBOM 元件 $(grep -c '"bom-ref"' "$sbom") 個"
}

# ---------- source：原始碼掃描 ----------
# step_source：用 cbomkit-action（容器）掃 Java 原始碼裡呼叫密碼學 API 的地方
#   產出 shared/source/cbom.json（→ SourceCodeLayer）；掃描的 log 在 <暫存>/source-scan.log
#   失敗代表：掃描工具自己出錯（看那個 log），或還沒做 build
step_source() {
  local jar container

  # 容器名稱加上這支腳本的程序編號（$$），同時跑兩次也不會撞名。例：cbom-source-12345
  jar=$(find_jar)
  container=cbom-source-$$

  # 1. 掃描工具要「建置過的專案」：原始碼、編好的 class、相依的 jar（從 Spring Boot 的 jar 裡取出）
  #    複製一份到暫存目錄（不含打包好的 jar 與 .git）；unzip -j：不保留 jar 裡的目錄結構，檔案直接放進 dependency/
  rm -rf "$work/workspace"
  mkdir -p "$work/workspace"
  tar -C "$src" --exclude='target/*.jar' --exclude='target/*.original' --exclude='.git' -cf - . \
    | tar -xf - -C "$work/workspace"

  mkdir -p "$work/workspace/target/dependency"
  unzip -q -j "$jar" 'BOOT-INF/lib/*.jar' -d "$work/workspace/target/dependency"
  say "相依的 jar $(find "$work/workspace/target/dependency" -name '*.jar' | wc -l) 個"

  # 2. 建容器、把專案送進去（還沒啟動）
  #    映像預設的 heap 是 16 GB：自己指定。容器和這支腳本不一定在同一台（遠端引擎），所以檔案用 podman cp 進出
  #    GITHUB_* 與 CBOMKIT_*：這個工具本來是給 GitHub Actions 用的，靠這幾個環境變數知道專案在哪、結果放哪
  podman rm -f --ignore "$container" > /dev/null
  podman create --name "$container" --memory "$ACTION_MEMORY" \
    -e GITHUB_WORKSPACE=/workspace -e GITHUB_OUTPUT=/tmp/github-output \
    -e CBOMKIT_OUTPUT_DIR=/workspace/target/cbom -e CBOMKIT_LANGUAGES=java \
    -e CBOMKIT_JAVA_JAR_DIR=/workspace/target/dependency \
    --entrypoint java "$ACTION_IMAGE" "-Xmx$ACTION_HEAP" -jar /cbomkit-action/CBOMkit-action.jar > /dev/null
  tar -C "$work" -cf - workspace | podman cp - "$container:/"

  # 3. 啟動並等它掃完（start -a：接著看它的輸出，掃完才回來）
  #    < /dev/null：不讓它讀標準輸入（這支腳本若是從標準輸入送進來的，會被它讀走）
  if ! podman start -a "$container" < /dev/null > "$work/source-scan.log" 2>&1; then
    podman rm -f "$container" > /dev/null
    fail 2 "原始碼掃描失敗，看 $work/source-scan.log"
  fi

  # 4. 結果取回來（要在刪容器之前），收掉容器與暫存的專案
  mkdir -p "$raw/shared/source"
  podman cp "$container:/workspace/target/cbom/cbom.json" "$raw/shared/source/cbom.json"
  podman rm -f "$container" > /dev/null
  rm -rf "$work/workspace"

  # 印出 log 裡「Scanned N files」那一行，去掉前面的時間與類別名稱（最後一個「 - 」以前的部分）
  #   例：「12:00:01 INFO  o.p.Scanner - Scanned 42 files in 3s」→「Scanned 42 files in 3s」（log 格式是舉例）
  say "$(grep -E 'Scanned [0-9]+ files' "$work/source-scan.log" | sed 's/^.* - //')"
}

# ---------- files：原始碼目錄裡的憑證、私鑰、秘密 ----------
# step_files：用 cbomkit-theia 掃原始碼目錄裡的憑證檔、私鑰檔、寫死的秘密（只記位置與種類，不記內容）
#   產出 shared/theia.json（→ FilesLayer）；log 在 <暫存>/theia-dir.log
step_files() {
  # 不含建置結果，位置才是 repo 裡的路徑
  rm -rf "$work/srcdir"
  mkdir -p "$work/srcdir"
  tar -C "$src" --exclude='./target' --exclude='.git' -cf - . | tar -xf - -C "$work/srcdir"

  if ! "$theia" dir "$work/srcdir" -p "$THEIA_PLUGINS" > "$raw/shared/theia.json" 2> "$work/theia-dir.log"; then
    fail 2 "cbomkit-theia dir 失敗，看 $work/theia-dir.log"
  fi

  rm -rf "$work/srcdir"
  say "原始碼目錄：元件 $(grep -c '"evidence"' "$raw/shared/theia.json") 個"
}

# ---------- image：建映像、掃映像、讀映像裡的設定 ----------
# step_image：把 app 建成容器映像，掃映像裡的憑證與秘密，再讀映像裡 JDK 與 OS 的密碼設定
#   產出 shared/theia-image.json（→ ImageLayer）；
#        app/java.security、java-version.txt、java-security-effective.txt、os-crypto.txt（→ JdkSettingsLayer）
#   失敗代表：映像建不起來（Containerfile 或 jar 不在：先做 build），或 theia 出錯（看 <暫存>/theia-image.log）
step_image() {
  local bom_option=()

  # 1. 建映像
  say "建映像 $APP_IMAGE"
  podman build -q -f "$src/$APP_CONTAINERFILE" -t "$APP_IMAGE" "$src" > /dev/null

  # 2. 掃映像：theia 讀映像的 tar 檔；有原始碼層的 CBOM 就帶進去，讓它對照映像裡的 java.security
  #    bom_option 是陣列：沒有那個檔時是空的，"${bom_option[@]}" 展開成「什麼都沒有」；有的話展開成「-b 檔名」兩個參數
  podman save -o "$work/app-image.tar" "$APP_IMAGE"
  if [ -f "$raw/shared/source/cbom.json" ]; then
    bom_option=(-b "$raw/shared/source/cbom.json")
  fi

  if ! "$theia" image "$work/app-image.tar" "${bom_option[@]}" -p "$THEIA_PLUGINS" \
    > "$raw/shared/theia-image.json" 2> "$work/theia-image.log"; then
    fail 2 "cbomkit-theia image 失敗，看 $work/theia-image.log"
  fi

  rm -f "$work/app-image.tar"
  say "映像：元件 $(grep -c '"evidence"' "$raw/shared/theia-image.json") 個（含映像內建的 CA 憑證，合併時只記張數）"

  # 3. 映像裡實際生效的 JDK 與 OS 密碼設定（和 Confluent Platform 每台主機收的檔同樣格式）
  #    每個檔都是用映像開一個臨時容器（--rm：跑完就刪）執行一小段指令，把輸出存下來
  #    JDK 的目錄：java 指令的真實位置往上兩層。例：/usr/lib/jvm/java-21/bin/java → /usr/lib/jvm/java-21
  #    （三層 $(…) 是在映像裡的 sh 執行的字串，不是這支腳本的巢狀寫法）
  podman run --rm --entrypoint sh "$APP_IMAGE" -c \
    'cat "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")/conf/security/java.security"' \
    > "$raw/app/java.security"
  podman run --rm --entrypoint sh "$APP_IMAGE" -c \
    'java -version 2>&1; dirname "$(dirname "$(readlink -f "$(command -v java)")")"' \
    > "$raw/app/java-version.txt"
  # 檔案寫的不一定就是生效的（Red Hat 的 JDK 會跟著 OS 的密碼政策）：請映像裡的 JDK 印出實際生效的設定
  podman run --rm --entrypoint java "$APP_IMAGE" -XshowSettings:security:all -version \
    > "$raw/app/java-security-effective.txt" 2>&1
  podman run --rm --entrypoint sh "$APP_IMAGE" -c \
    'update-crypto-policies --show; cat /etc/redhat-release; openssl version 2>/dev/null || echo "openssl（映像裡沒有這個指令）"' \
    > "$raw/app/os-crypto.txt"
  say "映像的 JDK：$(head -1 "$raw/app/java-version.txt")；OS 密碼政策：$(head -1 "$raw/app/os-crypto.txt")"
}

# ---------- runtime：啟動、打端點、TLS 掃描、JFR ----------
# step_runtime：用映像把 app 跑起來（帶 JFR 錄製），打一輪端點，掃 TLS，停掉後取回 JFR 紀錄
#   產出 app/tls/<埠>.json（→ TlsScanLayer）、app/jfr/service.json（→ RuntimeLayer）、app/served/<埠>.pem；
#        collect.env 的 JFR_SECONDS 填上這一段花的秒數
#   失敗代表：app 起不來（會印容器 log 的最後 20 行）、testssl.sh 沒掃成、或 JFR 檔取不回來
step_runtime() {
  local container address url started
  local recording
  local ready=no
  local chain
  local seconds requests handshakes

  container=cbom-app-$$
  started=$(date +%s)

  # 0. 啟動 app 容器
  #    JAVA_OPTS_APPEND 是 Red Hat OpenJDK 映像的啟動腳本認得的變數；結束時把錄到的寫成 /tmp/app.jfr
  #    -Xmx256m：app 的 heap 上限（容器的上限是 $APP_MEMORY，預設 768m，其餘留給 JVM 的其他記憶體）
  podman rm -f --ignore "$container" > /dev/null
  recording="name=cbom,settings=$APP_JFR_SETTINGS,filename=/tmp/app.jfr,dumponexit=true"
  podman run -d --name "$container" --network "$APP_NETWORK" --memory "$APP_MEMORY" \
    -e JAVA_OPTS_APPEND="-Xmx256m -XX:StartFlightRecording=$recording" \
    "$APP_IMAGE" > /dev/null

  # 容器在 $APP_NETWORK 這個網路上的 IP（這支腳本和 app 容器要在同一個網路才連得到）
  address=$(podman inspect "$container" --format "{{(index .NetworkSettings.Networks \"$APP_NETWORK\").IPAddress}}")
  url=https://$address:$APP_PORT
  say "app 容器 $container（$address），等它啟動"

  # 最多試 60 次：每次 curl 最多等 3 秒（-m 3），沒通再等 3 秒。
  # 所以連線被拒絕（app 還沒開埠）時約 3 分鐘放棄；連線卡住不回應時最久約 6 分鐘
  for _ in $(seq 1 60); do
    if curl -sk -m 3 -o /dev/null "$url/api/lab"; then
      ready=yes
      break
    fi

    sleep 3
  done

  if [ "$ready" != yes ]; then
    podman logs "$container" 2>&1 | tail -20 >&2
    podman rm -f "$container" > /dev/null
    fail 2 "app 沒有在 3 分鐘內啟動"
  fi

  # 1. 把端點打一輪（app 自己提供的腳本），JFR 才錄得到實際用到的演算法
  bash "$src/$APP_EXERCISE" "$url" >&2

  # 2. 這個埠實際出示的憑證（sed 只留每張憑證從 BEGIN 到 END 的那幾行）
  mkdir -p "$raw/app/served" "$raw/app/tls" "$raw/app/jfr"
  chain=$(openssl s_client -connect "$address:$APP_PORT" -showcerts < /dev/null 2> /dev/null)
  echo "$chain" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "$raw/app/served/$APP_PORT.pem"

  # 3. TLS 掃描（和 Confluent Platform 那條路同樣的選項）
  #    -p 支援哪些 TLS 版本、-s 標準的 cipher 類別、-f forward secrecy（含金鑰交換群組）、-S 伺服器的預設與憑證資訊；
  #    --nodns none 與 --ip：不查 DNS，只掃我們給的位址（app.$APP_DOMAIN 這個名稱只是寫進結果用的）
  #    testssl.sh 有發現項目時結束碼也不是 0，所以不當成失敗；真的沒掃成要看 JSON 裡有沒有 scanProblem
  if ! "$CBOM_HOME/bin/testssl/testssl.sh" --quiet --color 0 --nodns none --ip "$address" -p -s -f -S \
    --jsonfile "$raw/app/tls/$APP_PORT.json" "app.$APP_DOMAIN:$APP_PORT" > "$work/testssl.log" 2>&1; then
    say "testssl.sh 回報非 0（有發現項目時也會這樣），紀錄在 $work/testssl.log"
  fi

  if grep -q '"scanProblem"' "$raw/app/tls/$APP_PORT.json"; then
    podman rm -f "$container" > /dev/null
    fail 2 "testssl.sh 沒掃成：$(grep -A4 '"scanProblem"' "$raw/app/tls/$APP_PORT.json" | grep finding)"
  fi

  # 4. 停掉 app（JVM 結束時寫出 JFR），取回來轉成 JSON
  #    stop -t 30：給 JVM 最多 30 秒正常結束並寫完 JFR 檔，超過才強制停（強制停的話檔案會不完整）
  podman stop -t 30 "$container" > /dev/null
  podman cp "$container:/tmp/app.jfr" "$work/app.jfr"
  podman rm -f "$container" > /dev/null
  jfr print --json --events jdk.SecurityProviderService,jdk.TLSHandshake "$work/app.jfr" > "$raw/app/jfr/service.json"
  rm -f "$work/app.jfr"

  # 5. 這一段花了幾秒填進 collect.env（「JFR_SECONDS=」→「JFR_SECONDS=95」），印出錄到幾筆
  seconds=$(($(date +%s) - started))
  # 用 awk 數：一筆都沒有時 grep -c 會回 1
  requests=$(awk '/"jdk.SecurityProviderService"/ {c++} END {print c + 0}' "$raw/app/jfr/service.json")
  handshakes=$(awk '/"jdk.TLSHandshake"/ {c++} END {print c + 0}' "$raw/app/jfr/service.json")
  sed -i "s/^JFR_SECONDS=.*/JFR_SECONDS=$seconds/" "$raw/collect.env"
  say "執行期 $seconds 秒：演算法請求 $requests 筆，TLS 交握 $handshakes 筆"
}

# ---------- finish：檢查原料 ----------
# step_finish：交出去之前的檢查（check_raw：collect.env 完整、沒有私鑰內容），刪掉暫存目錄，列出原料裡的檔
#   失敗代表：原料不合格（結束碼 2，訊息會說是哪一項）
step_finish() {
  check_raw "$raw"

  rm -rf "$work"
  say "收集完成：$(du -sh "$raw" | cut -f1)，$raw"

  # 列出每個檔，把前面的原料目錄換成兩個空白。例：/x/raw/shared/theia.json →「  shared/theia.json」
  find "$raw" -type f | sed "s#^$raw/#  #" | sort >&2
}

case "$step" in
  init) step_init ;;
  build) step_build ;;
  source) step_source ;;
  files) step_files ;;
  image) step_image ;;
  runtime) step_runtime ;;
  finish) step_finish ;;
  all)
    step_init
    step_build
    step_source
    step_files
    step_image
    if [ "$with_runtime" = yes ]; then
      step_runtime
    fi

    step_finish
    ;;
  *) fail 1 "不認得的步驟 $step（可以用的：init build source files image runtime finish all）" ;;
esac
