#!/usr/bin/env bash
# build.sh：在 lab 的下載機（dl01，連得到網路）建出交付用的兩個執行檔，放到 cbom/dist/（維護這個專案的人用）
#   cbom/dist/cbom-tools.jar     我們的程式（cbom/tools 的 Maven 專案，含相依套件；順便跑全部單元測試）
#   cbom/dist/cbomkit-theia      PQCA 的 cbomkit-theia：原廠只發行原始碼與容器映像，這裡從指定版本的原始碼編成靜態執行檔
#   cbom/dist/VERSIONS           各元件的版本與 sha256
# where: Windows Git Bash；需要 lab 的 dl01 容器在跑。手冊的讀者不需要這支：他們拿到的是 package.sh 打包好的交付物。
#
# 建置用的工具（Go、Maven）只留在 dl01 的 ~/cbom，不進平台。版本寫在下面，改版本就改這裡。
set -euo pipefail
export MSYS_NO_PATHCONV=1

THEIA_VERSION=1.1.2
GO_VERSION=1.27.4
MAVEN_VERSION=3.9.16

script_dir=$(dirname "$0")
cd "$script_dir"
mkdir -p dist

# 1. 把 Maven 專案送到 dl01（target/ 不送）
podman exec dl01 rm -rf /root/cbom/proj
podman exec dl01 mkdir -p /root/cbom/dl /root/cbom/out
podman cp "$(cygpath -m tools)" dl01:/root/cbom/proj
podman exec dl01 rm -rf /root/cbom/proj/target

# 2. 在 dl01 上準備工具並建置（工具已經在就不重抓；下載後都核對原廠的雜湊）
podman exec -i dl01 bash -e -s -- "$THEIA_VERSION" "$GO_VERSION" "$MAVEN_VERSION" <<'EOF'
theia_version=$1
go_version=$2
maven_version=$3
cd ~/cbom/dl

# 2.1 Go：雜湊從 go.dev 的版本清單取
if [ ! -x ~/cbom/go/bin/go ] || ! ~/cbom/go/bin/go version | grep -q "go$go_version "; then
  go_tar=go$go_version.linux-amd64.tar.gz
  curl -fsSL -o "$go_tar" "https://go.dev/dl/$go_tar"
  go_list=$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | tr -d ' \n')
  go_entry=$(echo "$go_list" | grep -o "\"filename\":\"$go_tar\"[^}]*")
  go_sha=$(echo "$go_entry" | grep -o '"sha256":"[0-9a-f]*"' | cut -d'"' -f4)
  echo "$go_sha  $go_tar" | sha256sum -c -
  rm -rf ~/cbom/go
  tar -xzf "$go_tar" -C ~/cbom
fi

# 2.2 Maven：雜湊是 Apache 提供的 sha512
if [ ! -x ~/cbom/maven/bin/mvn ]; then
  maven_tar=apache-maven-$maven_version-bin.tar.gz
  curl -fsSL -o "$maven_tar" "https://dlcdn.apache.org/maven/maven-3/$maven_version/binaries/$maven_tar"
  maven_sha=$(curl -fsSL "https://downloads.apache.org/maven/maven-3/$maven_version/binaries/$maven_tar.sha512")
  echo "$maven_sha  $maven_tar" | sha512sum -c -
  mkdir -p ~/cbom/maven
  tar -xzf "$maven_tar" -C ~/cbom/maven --strip-components=1
fi

# 2.3 建置用的 JDK：銀行給的 JDK 21（落地區的 tar）
if [ ! -x ~/cbom/jdk/bin/java ]; then
  mkdir -p ~/cbom/jdk
  tar -xzf /out/bank/OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz -C ~/cbom/jdk --strip-components=1
fi

# 2.4 cbomkit-theia：指定版本的原始碼，編成不依賴系統函式庫的執行檔
theia_tar=cbomkit-theia-$theia_version.tar.gz
if [ ! -f "$theia_tar" ]; then
  curl -fsSL -o "$theia_tar" "https://github.com/cbomkit/cbomkit-theia/archive/refs/tags/v$theia_version.tar.gz"
fi
rm -rf ~/cbom/src
mkdir -p ~/cbom/src
tar -xzf "$theia_tar" -C ~/cbom/src
cd ~/cbom/src/cbomkit-theia-$theia_version
export PATH=~/cbom/go/bin:$PATH GOPATH=~/cbom/gopath GOCACHE=~/cbom/gocache GOFLAGS=-mod=mod GOTOOLCHAIN=local CGO_ENABLED=0
go build -trimpath -ldflags "-s -w" -o ~/cbom/out/cbomkit-theia .

# 2.5 我們的程式：編譯、跑單元測試、打成一個 jar
cd ~/cbom/proj
JAVA_HOME=~/cbom/jdk ~/cbom/maven/bin/mvn -q -B package
cp target/cbom-tools.jar ~/cbom/out/cbom-tools.jar

# 2.6 版本與雜湊
cd ~/cbom/out
{
  echo "cbom-tools $(grep -m1 -o '<version>[^<]*' ~/cbom/proj/pom.xml | cut -d'>' -f2)"
  echo "cbomkit-theia $theia_version"
  echo "# cbomkit-theia：原始碼 $theia_tar 的 sha256 $(sha256sum ~/cbom/dl/$theia_tar | cut -d' ' -f1)，用 Go $go_version 編譯"
  sha256sum cbom-tools.jar cbomkit-theia
} > VERSIONS
cat VERSIONS
EOF

# 3. 取回來，核對和 dl01 上的雜湊相同
for file in cbom-tools.jar cbomkit-theia VERSIONS; do
  podman cp "dl01:/root/cbom/out/$file" "$(cygpath -m "dist/$file")"
done

cd dist
if grep -E ' (cbom-tools\.jar|cbomkit-theia)$' VERSIONS | sha256sum -c --quiet -; then
  echo "dist/ 已更新，雜湊相符"
else
  echo "取回來的檔和 dl01 上的不一樣"
  exit 1
fi
