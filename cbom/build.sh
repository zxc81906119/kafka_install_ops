#!/usr/bin/env bash
# build.sh：建出兩個執行檔，放到 cbom/dist/（維護這個專案的人用）
#   cbom/dist/cbom-tools.jar     我們的程式（cbom/tools 的 Maven 專案，含相依套件；順便跑全部單元測試）
#   cbom/dist/cbomkit-theia      PQCA 的 cbomkit-theia：原廠只發行原始碼與容器映像，這裡從指定版本的原始碼編成靜態執行檔
#   cbom/dist/VERSIONS           各元件的版本與 sha256
# where: Windows Git Bash；只需要 podman 的 machine 在跑、連得到網路。不需要 Kafka lab（2026-11-12 起不再用下載機 dl01）。
#
# 在一個臨時的建置容器裡做，做完就刪；建置用的工具（Go、Maven）、下載的原始碼與相依套件留在 volume cbom-build，
# 下次不用重抓。版本寫在下面，改版本就改這裡（Go、Maven 已安裝的版本和這裡不同就重抓；theia 照版本取原始碼）。
# 兩個使用者（Confluent Platform 的交付物、web app 的 lab）都拿 dist/ 的檔。
#
# 用法：bash cbom/build.sh（沒有參數；在哪個目錄執行都可以）
# 輸入：cbom/tools/（Maven 專案）；網路上的 Go、Maven、cbomkit-theia 原始碼。
# 輸出：cbom/dist/ 的三個檔（上面列的）；建置失敗時 dist/ 不動。
# 結束碼：0 建好而且取回的檔雜湊相符；1 建置失敗（Maven 編譯或單元測試、Go 編譯、下載或雜湊核對），或取回的檔和容器裡的不同。
#         容器起不來、檔案送不進去時是 podman 自己的結束碼（set -e）。
set -euo pipefail
# Git Bash 會把 /root/cbom 這類參數改成 Windows 路徑：對這支腳本裡的 podman 全部關掉
export MSYS_NO_PATHCONV=1

THEIA_VERSION=1.1.2
GO_VERSION=1.27.4
MAVEN_VERSION=3.9.16
# 建置容器的映像：要有 JDK 21、curl、tar。用官方 Jenkins 映像只是因為它自帶 JDK 21，而且 lab 本來就有
BUILD_IMAGE=docker.io/jenkins/jenkins:2.580.2-lts-jdk21
BUILD_CONTAINER=cbom-build
BUILD_VOLUME=cbom-build

script_dir=$(dirname "$0")
cd "$script_dir"
mkdir -p dist

# 1. 建置容器（上次沒收乾淨的先刪）；Maven 專案送進去（target/ 不送）
#    --entrypoint sleep … infinity：容器什麼都不做、一直開著，讓後面的 podman exec 進去做事
#    -m 2g：這個容器最多用 2 GB 記憶體（podman machine 的記憶體是所有容器共用的，給建置一個上限）
#    cygpath -m：podman 是 Windows 程式，路徑要給它 C:/… 的寫法
podman rm -f --ignore "$BUILD_CONTAINER" > /dev/null
podman run -d --name "$BUILD_CONTAINER" --user root --entrypoint sleep -m 2g \
  -v "$BUILD_VOLUME:/root/cbom" "$BUILD_IMAGE" infinity > /dev/null

#    容器裡的目錄：proj/ 每次重送，dl/（下載的檔）與 out/（建出來的檔）留在 volume
podman exec "$BUILD_CONTAINER" rm -rf /root/cbom/proj
podman exec "$BUILD_CONTAINER" mkdir -p /root/cbom/dl /root/cbom/out
podman cp "$(cygpath -m tools)" "$BUILD_CONTAINER:/root/cbom/proj"
podman exec "$BUILD_CONTAINER" rm -rf /root/cbom/proj/target

# 2. 在容器裡準備工具並建置（工具已經在、版本也對就不重抓；下載後都核對原廠的雜湊）
#    EOF 之間那一段在容器裡執行（bash -e：任何一行失敗就停）；三個版本用參數 $1 $2 $3 傳進去。
#    整段放在 if 裡：失敗時不立刻結束，先記成 built=no，到第 3 步把容器刪掉之後才回報
if podman exec -i -e HOME=/root "$BUILD_CONTAINER" bash -e -s -- "$THEIA_VERSION" "$GO_VERSION" "$MAVEN_VERSION" <<'EOF'
theia_version=$1
go_version=$2
maven_version=$3

cd ~/cbom/dl

# 2.1 Go：雜湊從 go.dev 的版本清單取
#     沒裝過，或已安裝的版本不是指定的那一版（go version 印「go version go1.27.4 linux/amd64」）才下載
if [ ! -x ~/cbom/go/bin/go ] || ! ~/cbom/go/bin/go version | grep -q "go$go_version "; then
  go_tar=go$go_version.linux-amd64.tar.gz
  curl -fsSL -o "$go_tar" "https://go.dev/dl/$go_tar"

  # 版本清單是 JSON，沒有 jq：先去掉空白與換行，再用 grep -o 一步一步取
  #   go_entry 例："filename":"go1.27.4.linux-amd64.tar.gz","os":"linux","arch":"amd64","version":"go1.27.4","sha256":"ab12…"
  #   go_sha   例："sha256":"ab12…" 用雙引號切開的第 4 段 → ab12…
  go_list=$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | tr -d ' \n')
  go_entry=$(echo "$go_list" | grep -o "\"filename\":\"$go_tar\"[^}]*")
  go_sha=$(echo "$go_entry" | grep -o '"sha256":"[0-9a-f]*"' | cut -d'"' -f4)
  echo "$go_sha  $go_tar" | sha256sum -c -

  # 雜湊對了才換掉舊的
  rm -rf ~/cbom/go
  tar -xzf "$go_tar" -C ~/cbom
fi

# 2.2 Maven：雜湊是 Apache 提供的 sha512
#     沒裝過，或已安裝的版本不是指定的那一版（mvn -v 第一行印「Apache Maven 3.9.16 (…)」）才下載
if [ ! -x ~/cbom/maven/bin/mvn ] || ! ~/cbom/maven/bin/mvn -v | grep -q "Apache Maven $maven_version "; then
  maven_tar=apache-maven-$maven_version-bin.tar.gz
  curl -fsSL -o "$maven_tar" "https://dlcdn.apache.org/maven/maven-3/$maven_version/binaries/$maven_tar"
  maven_sha=$(curl -fsSL "https://downloads.apache.org/maven/maven-3/$maven_version/binaries/$maven_tar.sha512")
  echo "$maven_sha  $maven_tar" | sha512sum -c -

  # 雜湊對了才換掉舊的（--strip-components=1：去掉 tar 裡最外層的目錄 apache-maven-<版本>/）
  rm -rf ~/cbom/maven
  mkdir -p ~/cbom/maven
  tar -xzf "$maven_tar" -C ~/cbom/maven --strip-components=1
fi

# 2.3 cbomkit-theia：指定版本的原始碼，編成不依賴系統函式庫的執行檔
theia_tar=cbomkit-theia-$theia_version.tar.gz
if [ ! -f "$theia_tar" ]; then
  curl -fsSL -o "$theia_tar" "https://github.com/cbomkit/cbomkit-theia/archive/refs/tags/v$theia_version.tar.gz"
fi

rm -rf ~/cbom/src
mkdir -p ~/cbom/src
tar -xzf "$theia_tar" -C ~/cbom/src

cd ~/cbom/src/cbomkit-theia-$theia_version
# GOPATH、GOCACHE：下載的相依套件與編譯快取放在 volume 裡，下次不用重抓
# GOFLAGS=-mod=mod：照 go.mod 下載相依套件；GOTOOLCHAIN=local：只用我們裝的這一版 Go，不讓它自己去抓別版
# CGO_ENABLED=0：不連結系統的 C 函式庫，編出來的檔拿到別台 Linux 都能跑；-trimpath -ldflags "-s -w"：去掉路徑與除錯資訊
export PATH=~/cbom/go/bin:$PATH GOPATH=~/cbom/gopath GOCACHE=~/cbom/gocache
export GOFLAGS=-mod=mod GOTOOLCHAIN=local CGO_ENABLED=0
go build -trimpath -ldflags "-s -w" -o ~/cbom/out/cbomkit-theia .

# 2.4 我們的程式：編譯、跑單元測試、打成一個 jar（JDK 用映像自帶的 21；相依套件放在 volume 裡）
cd ~/cbom/proj
~/cbom/maven/bin/mvn -q -B -Dmaven.repo.local=/root/cbom/m2 package
cp target/cbom-tools.jar ~/cbom/out/cbom-tools.jar

# 2.5 版本與雜湊
#     cbom-tools 的版本取 pom.xml 第一個 <version>。例：「  <version>1.0.0</version>」→ grep -o 得「<version>1.0.0」→ 1.0.0
cd ~/cbom/out
{
  echo "cbom-tools $(grep -m1 -o '<version>[^<]*' ~/cbom/proj/pom.xml | cut -d'>' -f2)"
  echo "cbomkit-theia $theia_version"
  echo "# cbomkit-theia：原始碼 $theia_tar 的 sha256 $(sha256sum ~/cbom/dl/$theia_tar | cut -d' ' -f1)，用 Go $go_version 編譯"
  sha256sum cbom-tools.jar cbomkit-theia
} > VERSIONS

cat VERSIONS
EOF
then
  built=yes
else
  built=no
fi

# 3. 取回來（要在刪容器之前），核對和容器裡的雜湊相同
if [ "$built" = yes ]; then
  for file in cbom-tools.jar cbomkit-theia VERSIONS; do
    podman cp "$BUILD_CONTAINER:/root/cbom/out/$file" "$(cygpath -m "dist/$file")"
  done
fi

podman rm -f "$BUILD_CONTAINER" > /dev/null

if [ "$built" != yes ]; then
  echo "建置失敗（上面有 Maven 或 Go 的訊息）；dist/ 沒有動"
  exit 1
fi

# VERSIONS 裡最後兩行是容器裡算的「雜湊  檔名」，挑出來交給 sha256sum -c 對取回來的檔
cd dist
if grep -E ' (cbom-tools\.jar|cbomkit-theia)$' VERSIONS | sha256sum -c --quiet -; then
  echo "dist/ 已更新，雜湊相符"
else
  echo "取回來的檔和建置容器裡的不一樣（podman cp 途中出錯？再跑一次 bash cbom/build.sh）"
  exit 1
fi
