#!/usr/bin/env bash
# 第 2 站：外網下載機 —— 抓兩套 Confluent RPM（安裝基底與遷移目標）、原廠公鑰、JMX exporter jar，產生 SHA256SUMS
# where: dl01 （下載機，root；落地區掛在 /out）
#
# 做什麼：設定 Confluent 官方 repo → 下載「安裝基底」（CP_VERSION＋C3_VERSION）到 rpm/、「遷移目標」（CP_TARGET_VERSION＋C3_TARGET_VERSION）
#         到 rpm-target/（都含 Confluent 自己的相依）→ 驗原廠簽章 → 抓 jar 並核對 sha1 → 抓官方監控規則與 dashboard（固定 commit）
#         → 產生給銀行的 OS 套件清單（以 OS_BASE_VERSION 的內容為準）→（lab）順便抓兩個 JDK → 產生整批的 SHA256SUMS。
# 產出：落地區的 rpm/（基底）、rpm-target/（目標）、gpg-keys/、tools/、monitoring/、os-packages.txt、bank/（JDK 兩版）、SHA256SUMS
#       OS 套件本身（9.6 的完整內容、9.8 的更新集合）是銀行套件庫的事，不在這裡；lab 由 bank-sim.sh os-content 另外備（~/kafka-lab/bank-os/，不經檔案交換）
# 重跑：安全。已下載的 RPM 會 SKIPPED；JDK 已在且 sha256 相符就不重抓。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"

DOWNLOAD_DIR=${OUT:-/out}                  # 落地區（lab：~/kafka-lab/landing 掛進 dl01 的 /out）
CP_MAJOR=${CP_VERSION%.*}                  # 8.2.4 → 8.2（repo 網址用主版號）
CP_TARGET_MAJOR=${CP_TARGET_VERSION%.*}    # 8.3.2 → 8.3
[ -d "$DOWNLOAD_DIR" ] && [ -w "$DOWNLOAD_DIR" ] || die "$DOWNLOAD_DIR 不存在或不可寫：這支要在下載機以 root 執行"

section "2.1 設定 Confluent repo、匯入原廠公鑰"
mkdir -p "$DOWNLOAD_DIR"/{rpm,rpm-target,gpg-keys,tools}
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

[confluent-$CP_TARGET_MAJOR]
name=Confluent $CP_TARGET_MAJOR
baseurl=https://packages.confluent.io/rpm/$CP_TARGET_MAJOR
gpgcheck=1
gpgkey=https://packages.confluent.io/rpm/$CP_TARGET_MAJOR/archive.key
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
for version in "$CP_VERSION" "$CP_TARGET_VERSION"; do
  if grep -q "confluent-server.*$version" <<<"$available_versions"; then ok "repo 有 confluent-server $version"; else die "repo 裡找不到 confluent-server $version"; fi
done
for version in "$C3_VERSION" "$C3_TARGET_VERSION"; do
  if grep -q "control-center-next-gen.*$version" <<<"$available_versions"; then ok "repo 有 control-center-next-gen $version"; else die "repo 裡找不到 C3 $version"; fi
done

section "2.2 下載：兩套精確版本（--resolve 連 Confluent 自己的相依一起抓；已存在的檔會 SKIPPED）"
log "每套約 3 GB；lab 的落地區是 Windows 資料夾，最後核對那段會很慢，耐心等"
# 每套只開自己的 repo：不然 --resolve 可能把另一版的 confluent-common 抓進來
download_set() {
  local destination=$1 cp_version=$2 cp_major=$3 c3_version=$4
  dnf download --resolve --arch x86_64 --arch noarch --destdir "$destination" --disablerepo='*' --enablerepo="confluent-$cp_major,confluent-c3" \
    "confluent-server-$cp_version" "confluent-security-$cp_version" "confluent-kafka-rest-$cp_version" \
    "confluent-cli-$cp_version" "confluent-control-center-next-gen-$c3_version" 2>&1 | grep -v '^\[SKIPPED\]' | tee -a "$LOG_FILE"
}
download_set "$DOWNLOAD_DIR/rpm" "$CP_VERSION" "$CP_MAJOR" "$C3_VERSION"
download_set "$DOWNLOAD_DIR/rpm-target" "$CP_TARGET_VERSION" "$CP_TARGET_MAJOR" "$C3_TARGET_VERSION"
for set_dir in rpm rpm-target; do
  rpm_count=$(ls "$DOWNLOAD_DIR/$set_dir"/*.rpm 2>/dev/null | wc -l)
  non_confluent_count=$(find "$DOWNLOAD_DIR/$set_dir" -maxdepth 1 -type f ! -name "confluent-*" | wc -l)
  if [ "$rpm_count" = 11 ] && [ "$non_confluent_count" = 0 ]; then ok "$set_dir/：$rpm_count 個 RPM，全部是 confluent-*"
  else die "$set_dir/：RPM 數量 $rpm_count（預期 11）、非 confluent 的檔 $non_confluent_count 個"; fi
done

section "2.3 驗原廠簽章、確認相依（非 Confluent 的相依應該只有 bash、glibc）"
bad_signature_count=$(rpm -K "$DOWNLOAD_DIR"/rpm/*.rpm "$DOWNLOAD_DIR"/rpm-target/*.rpm | grep -vc 'digests signatures OK$' || true)
if [ "$bad_signature_count" = 0 ]; then ok "rpm -K：兩套共 $(ls "$DOWNLOAD_DIR"/rpm/*.rpm "$DOWNLOAD_DIR"/rpm-target/*.rpm | wc -l) 個都是 digests signatures OK"
else die "$bad_signature_count 個 RPM 簽章不對（rpm -K $DOWNLOAD_DIR/rpm*/*.rpm 看哪個）"; fi
other_dependencies=$(rpm -qpR "$DOWNLOAD_DIR"/rpm/*.rpm "$DOWNLOAD_DIR"/rpm-target/*.rpm 2>/dev/null | grep -vE '^(confluent-|rpmlib\(|config\()' | sort -u \
  | xargs -d '\n' rpm -q --whatprovides | sed 's/-[0-9].*//' | sort -u | paste -sd' ')
if [ "$other_dependencies" = "bash glibc" ]; then ok "非 Confluent 相依只有 bash、glibc"
else warn "非 Confluent 相依：$other_dependencies（預期只有 bash glibc，請確認）"; fi

section "2.4 監控用的 jar（Maven Central 的 sha1 核對）、Confluent 官方監控規則與 dashboard、給銀行的 OS 套件清單"
JAR_NAME=jmx_prometheus_javaagent-$JMX_EXPORTER_VERSION.jar
JAR_URL=https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/$JMX_EXPORTER_VERSION/$JAR_NAME
[ -f "$DOWNLOAD_DIR/tools/$JAR_NAME" ] || curl -fsSL -o "$DOWNLOAD_DIR/tools/$JAR_NAME" "$JAR_URL" || die "抓不到 $JAR_NAME"
if [ "$(sha1sum "$DOWNLOAD_DIR/tools/$JAR_NAME" | cut -d' ' -f1)" = "$(curl -fsSL "$JAR_URL.sha1")" ]; then ok "$JAR_NAME sha1 符合 Maven Central"
else die "$JAR_NAME sha1 不符"; fi
# Confluent 官方的 JMX 規則、告警規則、Grafana dashboard（jmx-monitoring-stacks，Apache-2.0）：固定在 site.env 的 commit，只取要用的路徑
MONITORING_DIR_OUT=$DOWNLOAD_DIR/monitoring/jmx-monitoring-stacks
if [ "$(cat "$MONITORING_DIR_OUT/COMMIT" 2>/dev/null)" = "$MONITORING_STACKS_COMMIT" ]; then ok "jmx-monitoring-stacks 已在落地區（commit ${MONITORING_STACKS_COMMIT:0:12}），不重抓"
else
  rm -rf "$DOWNLOAD_DIR/monitoring" /tmp/jms-x; mkdir -p "$DOWNLOAD_DIR/monitoring" /tmp/jms-x
  curl -fsSL "https://github.com/confluentinc/jmx-monitoring-stacks/archive/$MONITORING_STACKS_COMMIT.tar.gz" \
    | tar -xz -C /tmp/jms-x --wildcards '*/LICENSE' '*/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards/*' \
        '*/jmxexporter-prometheus-grafana/assets/grafana/provisioning/datasources/*' '*/jmxexporter-prometheus-grafana/assets/prometheus/*' \
        '*/shared-assets/jmx-exporter/kafka_broker.yml' '*/shared-assets/jmx-exporter/kafka_controller.yml' '*/shared-assets/jmx-exporter/confluent_rest.yml' '*/shared-assets/jmx-exporter/kafka_streams.yml' \
    || die "抓不到 jmx-monitoring-stacks（下載機沒有外網，或 github.com 連不到）"
  mv /tmp/jms-x/jmx-monitoring-stacks-* "$MONITORING_DIR_OUT" && echo "$MONITORING_STACKS_COMMIT" > "$MONITORING_DIR_OUT/COMMIT"
  rm -rf /tmp/jms-x
  ok "jmx-monitoring-stacks commit ${MONITORING_STACKS_COMMIT:0:12}：$(find "$MONITORING_DIR_OUT" -type f | wc -l) 個檔、dashboard $(ls "$MONITORING_DIR_OUT"/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards/*.json | wc -l) 個"
fi
# 平台需要的 OS 套件（由銀行的套件庫提供），列出在哪個 RHEL repo，交給銀行。
# 下載機的 OS repo 要停在安裝基底的小版本（lab：Rocky vault $OS_BASE_VERSION，手把手 A.7；預設的 repo 會跟著最新的小版本走，版本號就不對了）。
# 銀行套件庫之後同步到 OS_TARGET_VERSION 時這幾個會更新（手把手 30.5）
dnf -q repoquery --latest-limit 1 --qf '%{name}\t%{version}-%{release}\t%{repoid}' \
  chrony firewalld cyrus-sasl openssl-devel python3-dnf-plugin-versionlock gettext createrepo_c | sort -u > "$DOWNLOAD_DIR/os-packages.txt"
ok "OS 套件清單 $DOWNLOAD_DIR/os-packages.txt（$(wc -l < "$DOWNLOAD_DIR/os-packages.txt") 行）：交給銀行放進套件庫"

if [ "$FETCH_JDK" = 1 ]; then
  section "2.5 替銀行抓 JDK（lab：下載機代勞；正式環境 FETCH_JDK=0，由銀行交付到 landing/bank/）：基底 $JDK_MAJOR 與遷移目標 $JDK_TARGET_MAJOR 各一個"
  mkdir -p "$DOWNLOAD_DIR/bank"
  for jdk_major in "$JDK_MAJOR" "$JDK_TARGET_MAJOR"; do
    if ls "$DOWNLOAD_DIR"/bank/OpenJDK"${jdk_major}"U-jdk_x64_linux_hotspot_*.tar.gz >/dev/null 2>&1 \
       && (cd "$DOWNLOAD_DIR/bank" && sha256sum -c --quiet ./OpenJDK"${jdk_major}"U-*.sha256 2>/dev/null); then
      ok "JDK $jdk_major 已在 $DOWNLOAD_DIR/bank 且 sha256 相符，不重抓"
      continue
    fi
    # Adoptium API 回該主版本最新的 Temurin：取下載網址與官方 sha256
    jdk_metadata=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/$jdk_major/hotspot?os=linux&architecture=x64&image_type=jdk&vendor=eclipse") \
      || die "Adoptium API 連不到"
    jdk_url=$(grep -o '"link": *"[^"]*\.tar\.gz"' <<<"$jdk_metadata" | head -1 | cut -d'"' -f4)
    jdk_sha256=$(grep -o '"checksum": *"[0-9a-f]\{64\}"' <<<"$jdk_metadata" | head -1 | cut -d'"' -f4)
    jdk_file=$(basename "$jdk_url")
    rm -f "$DOWNLOAD_DIR"/bank/OpenJDK"${jdk_major}"U-*
    curl -fsSL -o "$DOWNLOAD_DIR/bank/$jdk_file" "$jdk_url" && echo "$jdk_sha256  $jdk_file" > "$DOWNLOAD_DIR/bank/$jdk_file.sha256"
    if (cd "$DOWNLOAD_DIR/bank" && sha256sum -c --quiet "$jdk_file.sha256"); then ok "jdk-ok: $jdk_file"; else die "JDK $jdk_major sha256 不符"; fi
  done
fi

section "2.6 整批的雜湊清單（之後每一關都用它核對）"
# 選單（tools/opmenu/）是另外交付的，有自己的 SHA256SUMS，16.3 單獨核對；不列進這份（重新打包後檔名會變）
(cd "$DOWNLOAD_DIR" && find rpm rpm-target tools gpg-keys monitoring -type f -not -path "tools/opmenu/*" | LC_ALL=C sort | xargs sha256sum > SHA256SUMS)
ok "SHA256SUMS：$(wc -l < "$DOWNLOAD_DIR/SHA256SUMS") 個檔（JDK 是銀行的檔案，有自己的 .sha256，不列在這裡）"
log "下載機的工作到此結束。接下來：掃描、開單、送進操作機 → 操作機跑 steps/03-intake.sh"
finish_step
