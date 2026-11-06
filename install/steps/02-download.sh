#!/usr/bin/env bash
# 第 2 站：外網下載機 —— 抓兩套 Confluent RPM（安裝基底與遷移目標）、原廠公鑰、JMX exporter jar，產生 SHA256SUMS
# where: dl01 （下載機，root；落地區掛在 /out）
#
# 做什麼：設定 Confluent 官方 repo → 下載「安裝基底」（CP_VERSION＋C3_VERSION）到 rpm/、「遷移目標」（CP_TARGET_VERSION＋C3_TARGET_VERSION）
#         到 rpm-target/（都含 Confluent 自己的相依）→ 驗原廠簽章 → 抓 jar 並核對 sha256 與 GPG 簽章 → 抓官方監控規則與 dashboard（固定 commit）
#         → 產生給銀行的 OS 套件清單（以 OS_BASE_VERSION 的內容為準）→（lab）順便抓兩個 JDK → 產生整批的 SHA256SUMS。
# 需要：能連外網；落地區（$OUT，預設 /out）可寫。
# 產出：落地區的 rpm/（基底）、rpm-target/（目標）、gpg-keys/、tools/、monitoring/、os-packages.txt、bank/（JDK 兩版）、SHA256SUMS
#       OS 套件本身（9.6 的完整內容、9.8 的更新集合）是銀行套件庫的事，不在這裡；lab 由 bank-sim.sh os-content 另外備（~/kafka-lab/bank-os/，不經檔案交換）
# 重跑：安全。已下載的 RPM 會 SKIPPED；jar 與監控檔已在就不重抓；JDK 每次問 Adoptium 最新版，同一版已在且 sha256 相符就不重抓。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"

DOWNLOAD_DIR=${OUT:-/out}                  # 落地區（lab：~/kafka-lab/landing 掛進 dl01 的 /out）
CP_MAJOR=${CP_VERSION%.*}                  # 8.2.4 → 8.2（repo 網址用主版號）
CP_TARGET_MAJOR=${CP_TARGET_VERSION%.*}    # 8.3.2 → 8.3

if [ ! -d "$DOWNLOAD_DIR" ]; then
  die "$DOWNLOAD_DIR 不存在或不可寫：這支要在下載機以 root 執行"
fi

if [ ! -w "$DOWNLOAD_DIR" ]; then
  die "$DOWNLOAD_DIR 不存在或不可寫：這支要在下載機以 root 執行"
fi

# download_set <目的目錄> <CP 版本> <CP 主版號> <C3 版本>：下載一套精確版本；輸出裡的 [SKIPPED]（已下載過的檔）不印
#   每套只開自己的 repo：不然 --resolve 可能把另一版的 confluent-common 抓進來
download_set() {
  local destination=$1
  local cp_version=$2
  local cp_major=$3
  local c3_version=$4

  dnf download --resolve --arch x86_64 --arch noarch --destdir "$destination" \
    --disablerepo='*' --enablerepo="confluent-$cp_major,confluent-c3" \
    "confluent-server-$cp_version" "confluent-security-$cp_version" "confluent-kafka-rest-$cp_version" \
    "confluent-cli-$cp_version" "confluent-control-center-next-gen-$c3_version" 2>&1 \
    | grep -v '^\[SKIPPED\]' | tee -a "$LOG_FILE"
}

# other_os_packages <RPM…>：這些 RPM 相依的 OS 套件名稱（去掉 Confluent 自己的和 rpm 內部用的），排好、空白分隔
#   例：other_os_packages rpm/*.rpm → bash glibc
other_os_packages() {
  local needs package_names

  needs=$(rpm -qpR "$@" 2>/dev/null | grep -vE '^(confluent-|rpmlib\(|config\()' | sort -u)
  package_names=$(xargs -d '\n' rpm -q --whatprovides <<<"$needs" | sed 's/-[0-9].*//')
  sort -u <<<"$package_names" | paste -sd' '
}

# jdk_checksum_ok <tar 檔名>：用旁邊的 .sha256 核對 bank/ 裡的 tar（sha256sum 要在檔案所在的目錄跑）
jdk_checksum_ok() {
  (
    if ! cd "$DOWNLOAD_DIR/bank"; then
      exit 1
    fi

    sha256sum -c --quiet "$1.sha256"
  )
}

section "2.1 設定 Confluent repo、匯入原廠公鑰"
# 1. 放下載檔案的目錄
mkdir -p "$DOWNLOAD_DIR"/{rpm,rpm-target,gpg-keys,tools}

# 2. 下載 Confluent 的簽章公鑰（Confluent Platform 一個網址、C3 一個網址）
cp_key_url="https://packages.confluent.io/rpm/$CP_MAJOR/archive.key"
c3_key_url=https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key

if ! curl -fsSL "$cp_key_url" -o "$DOWNLOAD_DIR/gpg-keys/confluent.asc"; then
  die "抓不到 archive.key（下載機沒有外網？）"
fi

if ! curl -fsSL "$c3_key_url" -o "$DOWNLOAD_DIR/gpg-keys/confluent-c3.asc"; then
  die "抓不到 C3 的 archive.key"
fi

# 3. 匯入，確認 rpm 認得它
rpm --import "$DOWNLOAD_DIR/gpg-keys/confluent.asc" "$DOWNLOAD_DIR/gpg-keys/confluent-c3.asc"

if grep -qi confluent <<<"$(rpm -q gpg-pubkey --qf '%{SUMMARY}\n')"; then
  ok "原廠公鑰已匯入 rpm 資料庫"
else
  die "公鑰匯入失敗"
fi

# 4. 三個原廠 repo（8.2、8.3、Control Center）
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

# 5. 要用的四個版本都在 repo 裡
log "第一次會先抓 repo 中繼資料，等一兩分鐘是正常的"
available_versions=$(dnf -q list --showduplicates confluent-server confluent-control-center-next-gen 2>/dev/null)

for version in "$CP_VERSION" "$CP_TARGET_VERSION"; do
  if grep -q "confluent-server.*$version" <<<"$available_versions"; then
    ok "repo 有 confluent-server $version"
  else
    die "repo 裡找不到 confluent-server $version"
  fi
done

for version in "$C3_VERSION" "$C3_TARGET_VERSION"; do
  if grep -q "control-center-next-gen.*$version" <<<"$available_versions"; then
    ok "repo 有 control-center-next-gen $version"
  else
    die "repo 裡找不到 C3 $version"
  fi
done

section "2.2 下載：兩套精確版本（--resolve 連 Confluent 自己的相依一起抓；已存在的檔會 SKIPPED）"
log "每套約 3 GB；lab 的落地區是 Windows 資料夾，最後核對那段會很慢，耐心等"

# 1. 安裝基底、遷移目標各一套
download_set "$DOWNLOAD_DIR/rpm" "$CP_VERSION" "$CP_MAJOR" "$C3_VERSION"
download_set "$DOWNLOAD_DIR/rpm-target" "$CP_TARGET_VERSION" "$CP_TARGET_MAJOR" "$C3_TARGET_VERSION"

# 2. 兩套各 11 個，全部是 confluent-*
for set_dir in rpm rpm-target; do
  rpm_count=$(ls "$DOWNLOAD_DIR/$set_dir"/*.rpm 2>/dev/null | wc -l)
  non_confluent_count=$(find "$DOWNLOAD_DIR/$set_dir" -maxdepth 1 -type f ! -name "confluent-*" | wc -l)

  if [ "$rpm_count" = 11 ] && [ "$non_confluent_count" = 0 ]; then
    ok "$set_dir/：$rpm_count 個 RPM，全部是 confluent-*"
  else
    die "$set_dir/：RPM 數量 $rpm_count（預期 11）、非 confluent 的檔 $non_confluent_count 個"
  fi
done

section "2.3 驗原廠簽章、確認相依（非 Confluent 的相依應該只有 bash、glibc）"
# 1. 每個 RPM 都要是 digests signatures OK：數不是的有幾個
bad_signature_count=$(rpm -K "$DOWNLOAD_DIR"/rpm/*.rpm "$DOWNLOAD_DIR"/rpm-target/*.rpm \
  | awk '!/digests signatures OK$/ {c++} END {print c + 0}')
rpm_count=$(ls "$DOWNLOAD_DIR"/rpm/*.rpm "$DOWNLOAD_DIR"/rpm-target/*.rpm | wc -l)

if [ "$bad_signature_count" = 0 ]; then
  ok "rpm -K：兩套共 $rpm_count 個都是 digests signatures OK"
else
  die "$bad_signature_count 個 RPM 簽章不對（rpm -K $DOWNLOAD_DIR/rpm*/*.rpm 看哪個）"
fi

# 2. 非 Confluent 的相依
other_dependencies=$(other_os_packages "$DOWNLOAD_DIR"/rpm/*.rpm "$DOWNLOAD_DIR"/rpm-target/*.rpm)

if [ "$other_dependencies" = "bash glibc" ]; then
  ok "非 Confluent 相依只有 bash、glibc"
else
  warn "非 Confluent 相依：$other_dependencies（預期只有 bash glibc，請確認）"
fi

section "2.4 監控用的 jar（GitHub release，sha256＋GPG 核對）、Confluent 官方監控規則與 dashboard、給銀行的 OS 套件清單"
# 1.1 以後的 jar 只在 GitHub release（Maven Central 的 io.prometheus.jmx 停在 1.0.1）；核對 release 附的 sha256 與 GPG 簽章（site.env 的指紋）
JAR_NAME=jmx_prometheus_javaagent-$JMX_EXPORTER_VERSION.jar
JAR_URL=https://github.com/prometheus/jmx_exporter/releases/download/$JMX_EXPORTER_VERSION/$JAR_NAME
JAR_FILE=$DOWNLOAD_DIR/tools/$JAR_NAME

# 1. 舊版的 jar 刪掉（留著的話第 17 站會抓到兩個）；這一版還沒有才下載
find "$DOWNLOAD_DIR/tools" -maxdepth 1 -name 'jmx_prometheus_javaagent-*.jar' ! -name "$JAR_NAME" -delete

if [ ! -f "$JAR_FILE" ]; then
  if ! curl -fsSL -o "$JAR_FILE" "$JAR_URL"; then
    die "抓不到 $JAR_NAME"
  fi
fi

# 2. 下載它的 sha256 與簽章
if ! curl -fsSL -o "/tmp/$JAR_NAME.sha256" "$JAR_URL.sha256"; then
  die "抓不到 $JAR_NAME 的 .sha256／.asc"
fi

if ! curl -fsSL -o "/tmp/$JAR_NAME.asc" "$JAR_URL.asc"; then
  die "抓不到 $JAR_NAME 的 .sha256／.asc"
fi

# 3. 核對 sha256（對不上就刪掉 jar，不帶進行內）
actual_sha256=$(sha256sum "$JAR_FILE" | cut -d' ' -f1)
expected_sha256=$(cut -c1-64 "/tmp/$JAR_NAME.sha256")

if [ "$actual_sha256" = "$expected_sha256" ]; then
  ok "$JAR_NAME sha256 符合 release"
else
  rm -f "$JAR_FILE" "/tmp/$JAR_NAME".*
  die "$JAR_NAME sha256 不符"
fi

# 4. 核對 GPG 簽章：公鑰依指紋從 keys.openpgp.org 取（簽章不是這把金鑰就刪掉 jar）
if ! curl -fsSL "https://keys.openpgp.org/vks/v1/by-fingerprint/$JMX_EXPORTER_GPG_FPR" | gpg --import 2>/dev/null; then
  rm -f "$JAR_FILE" "/tmp/$JAR_NAME".*
  die "$JAR_NAME GPG 簽章驗不過"
fi

gpg_status=$(gpg --status-fd 1 --verify "/tmp/$JAR_NAME.asc" "$JAR_FILE" 2>/dev/null)

if grep -q "VALIDSIG $JMX_EXPORTER_GPG_FPR" <<<"$gpg_status"; then
  ok "$JAR_NAME GPG 簽章（$JMX_EXPORTER_GPG_FPR）"
else
  rm -f "$JAR_FILE" "/tmp/$JAR_NAME".*
  die "$JAR_NAME GPG 簽章驗不過"
fi

# 5. 核對用的檔案刪掉
rm -f "/tmp/$JAR_NAME".*

# Confluent 官方的 JMX 規則、告警規則、Grafana dashboard（jmx-monitoring-stacks，Apache-2.0）：固定在 site.env 的 commit，只取要用的路徑
MONITORING_DIR_OUT=$DOWNLOAD_DIR/monitoring/jmx-monitoring-stacks
MONITORING_ARCHIVE_URL=https://github.com/confluentinc/jmx-monitoring-stacks/archive/$MONITORING_STACKS_COMMIT.tar.gz
MONITORING_PATHS=(
  '*/LICENSE'
  '*/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards/*'
  '*/jmxexporter-prometheus-grafana/assets/grafana/provisioning/datasources/*'
  '*/jmxexporter-prometheus-grafana/assets/prometheus/*'
  '*/shared-assets/jmx-exporter/kafka_broker.yml'
  '*/shared-assets/jmx-exporter/kafka_controller.yml'
  '*/shared-assets/jmx-exporter/confluent_rest.yml'
  '*/shared-assets/jmx-exporter/kafka_streams.yml'
)
downloaded_commit=$(cat "$MONITORING_DIR_OUT/COMMIT" 2>/dev/null)

if [ "$downloaded_commit" = "$MONITORING_STACKS_COMMIT" ]; then
  ok "jmx-monitoring-stacks 已在落地區（commit ${MONITORING_STACKS_COMMIT:0:12}），不重抓"
else
  # 1. 舊的一份清掉，下載這個 commit 的壓縮檔，只解開要用的路徑
  rm -rf "$DOWNLOAD_DIR/monitoring" /tmp/jms-x
  mkdir -p "$DOWNLOAD_DIR/monitoring" /tmp/jms-x

  if ! curl -fsSL "$MONITORING_ARCHIVE_URL" | tar -xz -C /tmp/jms-x --wildcards "${MONITORING_PATHS[@]}"; then
    die "抓不到 jmx-monitoring-stacks（下載機沒有外網，或 github.com 連不到）"
  fi

  # 2. 放到落地區，記下 commit
  if mv /tmp/jms-x/jmx-monitoring-stacks-* "$MONITORING_DIR_OUT"; then
    echo "$MONITORING_STACKS_COMMIT" > "$MONITORING_DIR_OUT/COMMIT"
  fi

  rm -rf /tmp/jms-x

  # 3. 結果：檔案數、dashboard 數
  monitoring_file_count=$(find "$MONITORING_DIR_OUT" -type f | wc -l)
  dashboards_dir=$MONITORING_DIR_OUT/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards
  dashboard_count=$(ls "$dashboards_dir"/*.json | wc -l)
  short_commit=${MONITORING_STACKS_COMMIT:0:12}
  ok "jmx-monitoring-stacks commit $short_commit：$monitoring_file_count 個檔、dashboard $dashboard_count 個"
fi

# 平台需要的 OS 套件（由銀行的套件庫提供），列出在哪個 RHEL repo，交給銀行。
# 下載機的 OS repo 要停在安裝基底的小版本（lab：Rocky vault $OS_BASE_VERSION，手把手 0.7；預設的 repo 會跟著最新的小版本走，版本號就不對了）。
# 銀行套件庫之後同步到 OS_TARGET_VERSION 時這幾個會更新（手把手 30.5）
dnf -q repoquery --latest-limit 1 --qf '%{name}\t%{version}-%{release}\t%{repoid}' \
  chrony firewalld cyrus-sasl openssl-devel python3-dnf-plugin-versionlock gettext createrepo_c \
  | sort -u > "$DOWNLOAD_DIR/os-packages.txt"
ok "OS 套件清單 $DOWNLOAD_DIR/os-packages.txt（$(wc -l < "$DOWNLOAD_DIR/os-packages.txt") 行）：交給銀行放進套件庫"

if [ "$FETCH_JDK" = 1 ]; then
  section "2.5 替銀行抓 JDK（lab：下載機代勞；正式環境 FETCH_JDK=0，由銀行交付到 landing/bank/）：基底 $JDK_MAJOR 與遷移目標 $JDK_TARGET_MAJOR 各一個"
  mkdir -p "$DOWNLOAD_DIR/bank"

  for jdk_major in "$JDK_MAJOR" "$JDK_TARGET_MAJOR"; do
    # 1. 問 Adoptium：這一版最新的 tar 在哪裡、官方的 sha256 是多少
    adoptium_url="https://api.adoptium.net/v3/assets/latest/$jdk_major/hotspot"
    adoptium_url+="?os=linux&architecture=x64&image_type=jdk&vendor=eclipse"

    if ! jdk_metadata=$(curl -fsSL "$adoptium_url"); then
      die "Adoptium API 連不到"
    fi

    jdk_url=$(grep -o '"link": *"[^"]*\.tar\.gz"' <<<"$jdk_metadata" | head -1 | cut -d'"' -f4)
    jdk_sha256=$(grep -o '"checksum": *"[0-9a-f]\{64\}"' <<<"$jdk_metadata" | head -1 | cut -d'"' -f4)
    jdk_file=$(basename "$jdk_url")

    # 2. 官方的 sha256 存成旁邊的 .sha256 檔；已經有同一版而且對得上就不重抓
    echo "$jdk_sha256  $jdk_file" > "$DOWNLOAD_DIR/bank/$jdk_file.sha256"

    if [ -f "$DOWNLOAD_DIR/bank/$jdk_file" ]; then
      if jdk_checksum_ok "$jdk_file" >/dev/null 2>&1; then
        ok "JDK $jdk_major 已在 $DOWNLOAD_DIR/bank 且 sha256 相符，不重抓"
        continue
      fi
    fi

    # 3. 下載（斷線時最多重試 3 次）
    curl -fsSL --retry 3 --retry-all-errors --retry-delay 5 -o "$DOWNLOAD_DIR/bank/$jdk_file" "$jdk_url"

    # 4. 核對（對不上就刪掉）
    if jdk_checksum_ok "$jdk_file"; then
      ok "jdk-ok: $jdk_file"
    else
      rm -f "$DOWNLOAD_DIR/bank/$jdk_file" "$DOWNLOAD_DIR/bank/$jdk_file.sha256"
      die "JDK $jdk_major sha256 不符"
    fi
  done
fi

section "2.6 整批的雜湊清單（之後每一關都用它核對）"
# 選單（tools/opmenu/）是另外交付的，有自己的 SHA256SUMS，16.3 單獨核對；不列進這份（重新打包後檔名會變）
(
  if ! cd "$DOWNLOAD_DIR"; then
    exit 1
  fi

  find rpm rpm-target tools gpg-keys monitoring -type f -not -path "tools/opmenu/*" \
    | LC_ALL=C sort \
    | xargs sha256sum > SHA256SUMS
)
ok "SHA256SUMS：$(wc -l < "$DOWNLOAD_DIR/SHA256SUMS") 個檔（JDK 是銀行的檔案，有自己的 .sha256，不列在這裡）"
log "下載機的工作到此結束。接下來：掃描、開單、送進操作機 → 操作機跑 steps/03-intake.sh"
finish_step
