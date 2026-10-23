#!/usr/bin/env bash
# 第 15 站（下載機部分）：建 Confluent 的 CyberArk（Conjur）config provider jar，只挑主機上沒有的 4 個
# where: dl01 （下載機，root；只有 SECRETS_MODE=conjur 需要）
#
# 為什麼要自己建：provider 不是 RPM，也沒有放 Maven Central，只有原始碼和 Confluent Hub 的打包方式。
# 為什麼只挑 4 個 jar：zip 裡的 Jersey、HK2、Jakarta 等相依 Confluent Server 本來就有（而且比較新），
#   CLASSPATH 排在最前面，全部放進去會蓋掉 Kafka 自己的。
# 產出：落地區 tools/csid/ 的 4 個 jar 與 SHA256SUMS（之後和其他檔一樣走第 2 站進內網）
# 重跑：安全。已經有 4 個 jar 且 sha256 相符就不重建。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"

DOWNLOAD_DIR=${OUT:-/out}
JAR_DIR=$DOWNLOAD_DIR/tools/csid
[ -d "$DOWNLOAD_DIR" ] && [ -w "$DOWNLOAD_DIR" ] || die "$DOWNLOAD_DIR 不存在或不可寫：這支要在下載機以 root 執行"

if [ -f "$JAR_DIR/SHA256SUMS" ] && (cd "$JAR_DIR" && sha256sum -c --quiet SHA256SUMS 2>/dev/null) && [ "$(ls "$JAR_DIR"/*.jar | wc -l)" = 4 ]; then
  ok "$JAR_DIR 已有 4 個 jar 且 sha256 相符，不重建"
  finish_step
  exit 0
fi

section "Maven 從原始碼建（第一次要抓相依，約 15–20 分鐘）"
dnf -q -y install maven-openjdk21 git unzip >/dev/null || die "裝不到 maven／git／unzip（下載機要能連外網的 OS repo）"
# Confluent 的 Maven repo（provider 的相依在這裡）
mkdir -p ~/.m2 && cat > ~/.m2/settings.xml <<'EOF'
<settings><profiles><profile><id>confluent</id><activation><activeByDefault>true</activeByDefault></activation>
<repositories><repository><id>confluent</id><url>https://packages.confluent.io/maven/</url></repository></repositories>
<pluginRepositories><pluginRepository><id>confluent</id><url>https://packages.confluent.io/maven/</url></pluginRepository></pluginRepositories>
</profile></profiles></settings>
EOF
cd /tmp && rm -rf csid-secrets-providers
git clone -q --depth 1 https://github.com/confluentinc/csid-secrets-providers.git || die "git clone 失敗"
cd csid-secrets-providers || die "沒有原始碼目錄"
log "$(git log -1 --format='commit %h %cd')"
# root pom 有一個只給 Confluent 內部發布用的 S3 外掛（aws-maven），公開 repo 抓不到：先把 <extensions> … </extensions> 整段刪掉
sed -i '/<extensions>/,/<\/extensions>/d' pom.xml
if grep -q '<extensions>' pom.xml; then die "pom.xml 的 <extensions> 沒刪乾淨"; fi
mvn -q -B -pl common,cyberark -am -DskipTests package 2>&1 | grep -E "BUILD|ERROR" | head -5 | tee -a "$LOG_FILE"
hub_zip=$(ls cyberark/target/components/packages/confluentinc-csid-secrets-provider-cyberark-*.zip 2>/dev/null | head -1)
[ -n "$hub_zip" ] || die "沒有產出 Confluent Hub zip（看上面的 ERROR）"

section "從 zip 挑出主機上沒有的 4 個 jar"
mkdir -p "$JAR_DIR" && rm -f "$JAR_DIR"/*.jar
unzip -q -j -o "$hub_zip" "*/lib/csid-secrets-provider-*.jar" "*/lib/conjur-api-*.jar" -d "$JAR_DIR"
(cd "$JAR_DIR" && sha256sum ./*.jar > SHA256SUMS)
jar_count=$(ls "$JAR_DIR"/*.jar | wc -l)
if [ "$jar_count" = 4 ]; then ok "$JAR_DIR：$(ls "$JAR_DIR" | paste -sd' ')"; else die "jar 數量 $jar_count（預期 4）"; fi
log "這 4 個 jar 和 SHA256SUMS 一起走第 2 站進內網（lab：bank-sim.sh intake 會一起送）"
finish_step
