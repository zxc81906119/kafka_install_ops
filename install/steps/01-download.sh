#!/usr/bin/env bash
# 第 1 站：外網下載機 —— 抓 Confluent RPM、原廠公鑰、JMX exporter jar，產生 SHA256SUMS
# where: dl01 （下載機，root；落地區掛在 /out）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"
OUT=${OUT:-/out}
[ -d "$OUT" ] && [ -w "$OUT" ] || die "$OUT 不存在或不可寫：這支要在下載機（落地區掛在 $OUT）以 root 執行"
MAJOR=${CP_VERSION%.*}   # 8.3

section "1.1 設定 Confluent repo、匯入原廠公鑰"
mkdir -p "$OUT"/{rpm,gpg-keys,tools}
curl -fsSL "https://packages.confluent.io/rpm/$MAJOR/archive.key" -o "$OUT/gpg-keys/confluent.asc" || die "抓不到 archive.key（下載機沒有外網？）"
curl -fsSL https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key -o "$OUT/gpg-keys/confluent-c3.asc" || die "抓不到 C3 archive.key"
rpm --import "$OUT/gpg-keys/confluent.asc" "$OUT/gpg-keys/confluent-c3.asc"
rpm -q gpg-pubkey --qf '%{SUMMARY}\n' | grep -qi confluent && ok "原廠公鑰已匯入 rpm 資料庫" || die "公鑰匯入失敗"
cat > /etc/yum.repos.d/confluent.repo <<EOF
[confluent-$MAJOR]
name=Confluent $MAJOR
baseurl=https://packages.confluent.io/rpm/$MAJOR
gpgcheck=1
gpgkey=https://packages.confluent.io/rpm/$MAJOR/archive.key
enabled=1

[confluent-c3]
name=Confluent Control Center next-gen
baseurl=https://packages.confluent.io/confluent-control-center-next-gen/rpm/
gpgcheck=1
gpgkey=https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key
enabled=1
EOF
log "第一次會先抓 repo 中繼資料，等一兩分鐘是正常的"
avail=$(dnf -q list --showduplicates confluent-server confluent-control-center-next-gen 2>/dev/null)
grep -q "$CP_VERSION" <<<"$avail" && ok "repo 有 confluent-server $CP_VERSION" || die "repo 裡找不到 confluent-server $CP_VERSION"
grep -q "$C3_VERSION" <<<"$avail" && ok "repo 有 control-center-next-gen $C3_VERSION" || die "repo 裡找不到 C3 $C3_VERSION"

section "1.2 下載：指定精確版本（--resolve 連 Confluent 自己的相依一起抓；已存在的檔會 SKIPPED）"
log "約 3 GB；lab 落地區是 Windows 資料夾，最後核對那段會很慢，耐心等"
dnf download --resolve --arch x86_64 --arch noarch --destdir "$OUT/rpm" \
  "confluent-server-$CP_VERSION" "confluent-security-$CP_VERSION" "confluent-kafka-rest-$CP_VERSION" "confluent-cli-$CP_VERSION" \
  "confluent-control-center-next-gen-$C3_VERSION" 2>&1 | grep -v '^\[SKIPPED\]' | tee -a "$LOG_FILE"
n=$(ls "$OUT"/rpm/*.rpm 2>/dev/null | wc -l); other=$(ls "$OUT/rpm" | grep -vc '^confluent-' || true)
[ "$n" -ge 11 ] && [ "$other" = 0 ] && ok "$n 個 RPM，全部是 confluent-*" || die "RPM 數量 $n（預期 11）、非 confluent 檔 $other"

section "1.3 驗原廠簽章、確認相依"
bad=$(rpm -K "$OUT"/rpm/*.rpm | grep -vc 'digests signatures OK$' || true)
[ "$bad" = 0 ] && ok "rpm -K：$n 個都是 digests signatures OK" || die "$bad 個 RPM 簽章不對（rpm -K $OUT/rpm/*.rpm）"
deps=$(rpm -qpR "$OUT"/rpm/*.rpm 2>/dev/null | grep -vE '^(confluent-|rpmlib\(|config\()' | sort -u | xargs -d '\n' rpm -q --whatprovides | sed 's/-[0-9].*//' | sort -u | paste -sd' ')
[ "$deps" = "bash glibc" ] && ok "非 Confluent 相依只有 bash、glibc" || warn "非 Confluent 相依：$deps（預期只有 bash glibc，請確認）"

section "1.4 監控用的 jar（Maven Central sha1 核對）、給銀行的 OS 套件清單"
J=jmx_prometheus_javaagent-$JMX_EXPORTER_VERSION.jar; U=https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/$JMX_EXPORTER_VERSION/$J
[ -f "$OUT/tools/$J" ] || curl -fsSL -o "$OUT/tools/$J" "$U" || die "抓不到 $J"
[ "$(sha1sum "$OUT/tools/$J" | cut -d' ' -f1)" = "$(curl -fsSL "$U.sha1")" ] && ok "$J sha1 符合 Maven Central" || die "$J sha1 不符"
dnf -q repoquery --latest-limit 1 --qf '%{name}\t%{version}-%{release}\t%{repoid}' chrony firewalld cyrus-sasl openssl-devel python3-dnf-plugin-versionlock gettext createrepo_c | sort -u > "$OUT/os-packages.txt"
ok "OS 套件清單 $OUT/os-packages.txt（$(wc -l < "$OUT/os-packages.txt") 行）：交給銀行放進套件庫"

if [ "$FETCH_JDK" = 1 ]; then
  section "1.5 替銀行抓 JDK（lab：下載機代勞；正式環境 FETCH_JDK=0，由銀行交付到 landing/bank/）"
  mkdir -p "$OUT/bank"
  if ls "$OUT"/bank/OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz >/dev/null 2>&1 && (cd "$OUT/bank" && sha256sum -c --quiet ./*.sha256 2>/dev/null); then
    ok "JDK 已在 $OUT/bank 且 sha256 相符，略過下載"
  else
    meta=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/21/hotspot?os=linux&architecture=x64&image_type=jdk&vendor=eclipse") || die "Adoptium API 連不到"
    url=$(grep -o '"link": *"[^"]*\.tar\.gz"' <<<"$meta" | head -1 | cut -d'"' -f4); sha=$(grep -o '"checksum": *"[0-9a-f]\{64\}"' <<<"$meta" | head -1 | cut -d'"' -f4); f=$(basename "$url")
    rm -f "$OUT"/bank/OpenJDK21U-*; curl -fsSL -o "$OUT/bank/$f" "$url" && echo "$sha  $f" > "$OUT/bank/$f.sha256"
    (cd "$OUT/bank" && sha256sum -c --quiet "$f.sha256") && ok "jdk-ok: $f" || die "JDK sha256 不符"
  fi
fi

section "1.6 整批的雜湊清單"
(cd "$OUT" && find rpm tools gpg-keys -type f | LC_ALL=C sort | xargs sha256sum > SHA256SUMS)
ok "SHA256SUMS：$(wc -l < "$OUT/SHA256SUMS") 個檔（JDK 是銀行的檔案，有自己的 .sha256，不列在這裡）"
log "下載機的工作到此結束。接下來：掃描、開單、送進操作機 → 操作機跑 steps/02-intake.sh"
finish
