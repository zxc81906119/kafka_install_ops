#!/usr/bin/env bash
# 第 15 站（下載機部分）：從原始碼建 Confluent 的 CyberArk（Conjur）config provider jar，只挑主機上沒有的 4 個 jar
# where: dl01 （下載機，root；只有 SECRETS_MODE=conjur 需要）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"
OUT=${OUT:-/out}
[ -d "$OUT" ] && [ -w "$OUT" ] || die "$OUT 不存在或不可寫：這支要在下載機以 root 執行"
if [ -f "$OUT/tools/csid/SHA256SUMS" ] && (cd "$OUT/tools/csid" && sha256sum -c --quiet SHA256SUMS 2>/dev/null) && [ "$(ls "$OUT"/tools/csid/*.jar | wc -l)" = 4 ]; then ok "$OUT/tools/csid 已有 4 個 jar 且 sha256 相符，略過建置"; finish; exit 0; fi

section "Maven 從原始碼建（第一次要抓相依，約 15–20 分鐘）；root pom 的 S3 外掛公開 repo 抓不到，先拿掉"
dnf -q -y install maven-openjdk21 git python3 unzip >/dev/null || die "裝不到 maven/git（下載機要有外網的 OS repo）"
mkdir -p ~/.m2 && cat > ~/.m2/settings.xml <<'EOF'
<settings><profiles><profile><id>confluent</id><activation><activeByDefault>true</activeByDefault></activation>
<repositories><repository><id>confluent</id><url>https://packages.confluent.io/maven/</url></repository></repositories>
<pluginRepositories><pluginRepository><id>confluent</id><url>https://packages.confluent.io/maven/</url></pluginRepository></pluginRepositories>
</profile></profiles></settings>
EOF
cd /tmp && rm -rf csid-secrets-providers && git clone -q --depth 1 https://github.com/confluentinc/csid-secrets-providers.git || die "git clone 失敗"
cd csid-secrets-providers && log "$(git log -1 --format='commit %h %cd')"
python3 - <<'EOF'
import re
p="pom.xml"; s=open(p).read(); s=re.sub(r"<extensions>.*?</extensions>","",s,flags=re.S); open(p,"w").write(s)
EOF
mvn -q -B -pl common,cyberark -am -DskipTests package 2>&1 | grep -E "BUILD|ERROR" | head -5 | tee -a "$LOG_FILE"
z=$(ls cyberark/target/components/packages/confluentinc-csid-secrets-provider-cyberark-*.zip 2>/dev/null | head -1); [ -n "$z" ] || die "沒有產出 zip（看上面的 ERROR）"
mkdir -p "$OUT/tools/csid" && rm -f "$OUT"/tools/csid/*.jar && unzip -q -j -o "$z" "*/lib/csid-secrets-provider-*.jar" "*/lib/conjur-api-*.jar" -d "$OUT/tools/csid"
(cd "$OUT/tools/csid" && sha256sum ./*.jar > SHA256SUMS)
n=$(ls "$OUT"/tools/csid/*.jar | wc -l); [ "$n" = 4 ] && ok "$OUT/tools/csid：$n 個 jar（$(ls "$OUT/tools/csid" | paste -sd' ')）" || die "jar 數量 $n（預期 4）"
log "這四個檔連同既有的 SHA256SUMS 一起走第 2 站的流程進內網（lab：bank-sim intake 會一起複製）"
finish
