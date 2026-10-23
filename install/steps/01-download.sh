#!/usr/bin/env bash
# 第 1 站：外網下載機 —— 抓 Confluent RPM、原廠公鑰、JMX exporter jar，產生 SHA256SUMS
# where: dl01 （下載機，root；落地區掛在 /out）
#
# 做什麼：設定 Confluent 官方 repo → 下載指定版本（含 Confluent 自己的相依）→ 驗原廠簽章 → 抓 jar 並核對 sha1
#         → 產生給銀行的 OS 套件清單 →（lab）順便抓 JDK → 產生整批的 SHA256SUMS。
# 產出：落地區的 rpm/、gpg-keys/、tools/、os-packages.txt、bank/（JDK）、SHA256SUMS
# 重跑：安全。已下載的 RPM 會 SKIPPED；JDK 已在且 sha256 相符就不重抓。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"

DOWNLOAD_DIR=${OUT:-/out}          # 落地區（lab：~/kafka-lab/landing 掛進 dl01 的 /out）
CP_MAJOR=${CP_VERSION%.*}          # 8.3.2 → 8.3（repo 網址用主版號）
[ -d "$DOWNLOAD_DIR" ] && [ -w "$DOWNLOAD_DIR" ] || die "$DOWNLOAD_DIR 不存在或不可寫：這支要在下載機以 root 執行"

section "1.1 設定 Confluent repo、匯入原廠公鑰"
mkdir -p "$DOWNLOAD_DIR"/{rpm,gpg-keys,tools}
curl -fsSL "https://packages.confluent.io/rpm/$CP_MAJOR/archive.key" -o "$DOWNLOAD_DIR/gpg-keys/confluent.asc" \
  || die "抓不到 archive.key（下載機沒有外網？）"
curl -fsSL https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key -o "$DOWNLOAD_DIR/gpg-keys/confluent-c3.asc" \
  || die "抓不到 C3 的 archive.key"
rpm --import "$DOWNLOAD_DIR/gpg-keys/confluent.asc" "$DOWNLOAD_DIR/gpg-keys/confluent-c3.asc"
if grep -qi confluent <<<"$(rpm -q gpg-pubkey --qf '%{SUMMARY}\n')"; then ok "原廠公鑰已匯入 rpm 資料庫"; else die "公鑰匯入失敗"; fi

cat > /etc/yum.repos.d/confluent.repo <<EOF
[confluent-$CP_MAJOR]
name=Confluent $CP_MAJOR
baseurl=https://packages.confluent.io/rpm/$CP_MAJOR
gpgcheck=1
gpgkey=https://packages.confluent.io/rpm/$CP_MAJOR/archive.key
enabled=1

[confluent-c3]
name=Confluent Control Center next-gen
baseurl=https://packages.confluent.io/confluent-control-center-next-gen/rpm/
gpgcheck=1
gpgkey=https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key
enabled=1
EOF
log "第一次會先抓 repo 中繼資料，等一兩分鐘是正常的"
available_versions=$(dnf -q list --showduplicates confluent-server confluent-control-center-next-gen 2>/dev/null)
if grep -q "$CP_VERSION" <<<"$available_versions"; then ok "repo 有 confluent-server $CP_VERSION"; else die "repo 裡找不到 confluent-server $CP_VERSION"; fi
if grep -q "$C3_VERSION" <<<"$available_versions"; then ok "repo 有 control-center-next-gen $C3_VERSION"; else die "repo 裡找不到 C3 $C3_VERSION"; fi

section "1.2 下載：指定精確版本（--resolve 連 Confluent 自己的相依一起抓；已存在的檔會 SKIPPED）"
log "約 3 GB；lab 的落地區是 Windows 資料夾，最後核對那段會很慢，耐心等"
dnf download --resolve --arch x86_64 --arch noarch --destdir "$DOWNLOAD_DIR/rpm" \
  "confluent-server-$CP_VERSION" "confluent-security-$CP_VERSION" "confluent-kafka-rest-$CP_VERSION" \
  "confluent-cli-$CP_VERSION" "confluent-control-center-next-gen-$C3_VERSION" 2>&1 | grep -v '^\[SKIPPED\]' | tee -a "$LOG_FILE"
rpm_count=$(ls "$DOWNLOAD_DIR"/rpm/*.rpm 2>/dev/null | wc -l)
non_confluent_count=$(find "$DOWNLOAD_DIR/rpm" -maxdepth 1 -type f ! -name "confluent-*" | wc -l)
if [ "$rpm_count" -ge 11 ] && [ "$non_confluent_count" = 0 ]; then ok "$rpm_count 個 RPM，全部是 confluent-*"
else die "RPM 數量 $rpm_count（預期 11）、非 confluent 的檔 $non_confluent_count 個"; fi

section "1.3 驗原廠簽章、確認相依（非 Confluent 的相依應該只有 bash、glibc）"
bad_signature_count=$(rpm -K "$DOWNLOAD_DIR"/rpm/*.rpm | grep -vc 'digests signatures OK$' || true)
if [ "$bad_signature_count" = 0 ]; then ok "rpm -K：$rpm_count 個都是 digests signatures OK"
else die "$bad_signature_count 個 RPM 簽章不對（rpm -K $DOWNLOAD_DIR/rpm/*.rpm 看哪個）"; fi
other_dependencies=$(rpm -qpR "$DOWNLOAD_DIR"/rpm/*.rpm 2>/dev/null | grep -vE '^(confluent-|rpmlib\(|config\()' | sort -u \
  | xargs -d '\n' rpm -q --whatprovides | sed 's/-[0-9].*//' | sort -u | paste -sd' ')
if [ "$other_dependencies" = "bash glibc" ]; then ok "非 Confluent 相依只有 bash、glibc"
else warn "非 Confluent 相依：$other_dependencies（預期只有 bash glibc，請確認）"; fi

section "1.4 監控用的 jar（Maven Central 的 sha1 核對）、給銀行的 OS 套件清單"
JAR_NAME=jmx_prometheus_javaagent-$JMX_EXPORTER_VERSION.jar
JAR_URL=https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/$JMX_EXPORTER_VERSION/$JAR_NAME
[ -f "$DOWNLOAD_DIR/tools/$JAR_NAME" ] || curl -fsSL -o "$DOWNLOAD_DIR/tools/$JAR_NAME" "$JAR_URL" || die "抓不到 $JAR_NAME"
if [ "$(sha1sum "$DOWNLOAD_DIR/tools/$JAR_NAME" | cut -d' ' -f1)" = "$(curl -fsSL "$JAR_URL.sha1")" ]; then ok "$JAR_NAME sha1 符合 Maven Central"
else die "$JAR_NAME sha1 不符"; fi
# 平台需要的 OS 套件（由銀行的套件庫提供），列出在哪個 RHEL repo，交給銀行
dnf -q repoquery --latest-limit 1 --qf '%{name}\t%{version}-%{release}\t%{repoid}' \
  chrony firewalld cyrus-sasl openssl-devel python3-dnf-plugin-versionlock gettext createrepo_c | sort -u > "$DOWNLOAD_DIR/os-packages.txt"
ok "OS 套件清單 $DOWNLOAD_DIR/os-packages.txt（$(wc -l < "$DOWNLOAD_DIR/os-packages.txt") 行）：交給銀行放進套件庫"

if [ "$FETCH_JDK" = 1 ]; then
  section "1.5 替銀行抓 JDK（lab：下載機代勞；正式環境 FETCH_JDK=0，由銀行交付到 landing/bank/）"
  mkdir -p "$DOWNLOAD_DIR/bank"
  if ls "$DOWNLOAD_DIR"/bank/OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz >/dev/null 2>&1 \
     && (cd "$DOWNLOAD_DIR/bank" && sha256sum -c --quiet ./*.sha256 2>/dev/null); then
    ok "JDK 已在 $DOWNLOAD_DIR/bank 且 sha256 相符，不重抓"
  else
    # Adoptium API 回最新的 Temurin 21：取下載網址與官方 sha256
    jdk_metadata=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/21/hotspot?os=linux&architecture=x64&image_type=jdk&vendor=eclipse") \
      || die "Adoptium API 連不到"
    jdk_url=$(grep -o '"link": *"[^"]*\.tar\.gz"' <<<"$jdk_metadata" | head -1 | cut -d'"' -f4)
    jdk_sha256=$(grep -o '"checksum": *"[0-9a-f]\{64\}"' <<<"$jdk_metadata" | head -1 | cut -d'"' -f4)
    jdk_file=$(basename "$jdk_url")
    rm -f "$DOWNLOAD_DIR"/bank/OpenJDK21U-*
    curl -fsSL -o "$DOWNLOAD_DIR/bank/$jdk_file" "$jdk_url" && echo "$jdk_sha256  $jdk_file" > "$DOWNLOAD_DIR/bank/$jdk_file.sha256"
    if (cd "$DOWNLOAD_DIR/bank" && sha256sum -c --quiet "$jdk_file.sha256"); then ok "jdk-ok: $jdk_file"; else die "JDK sha256 不符"; fi
  fi
fi

section "1.6 整批的雜湊清單（之後每一關都用它核對）"
(cd "$DOWNLOAD_DIR" && find rpm tools gpg-keys -type f | LC_ALL=C sort | xargs sha256sum > SHA256SUMS)
ok "SHA256SUMS：$(wc -l < "$DOWNLOAD_DIR/SHA256SUMS") 個檔（JDK 是銀行的檔案，有自己的 .sha256，不列在這裡）"
log "下載機的工作到此結束。接下來：掃描、開單、送進操作機 → 操作機跑 steps/02-intake.sh"
finish_step
