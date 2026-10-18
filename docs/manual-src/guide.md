<!--meta
{"kicker":"Confluent Platform 8.3.2 企業版 · 離線安裝 PoC","title":"手動安裝手冊","subtitle":"不經 cpctl,一步一步看懂每個步驟做了什麼","header":"Confluent Platform 8.3.2 手動安裝手冊","author":"zxc81906119","facts":[["適用版本","Confluent Platform 8.3.2(Kafka 4.3)、Control Center Next Gen 2.6.1、Temurin JDK 21"],["目標環境","RHEL 9 / Rocky 9,離線(只能連內部 repo)"],["對照腳本","installer/bin/cpctl(commit ab38715)"],["驗證方式","不經 cpctl,從外網下載到整套叢集與 OP menu 全程手動實測(附錄 A)"],["文件日期","2026-10-16"]]}
-->
[[toc]]

# 1. 閱讀指引與總覽

## 1.1 這份手冊的用途

cpctl 把整個安裝流程包成冪等的腳本,執行起來很方便,但看不到每一步實際做了什麼。這份手冊把同一套流程**拆成手動指令**,和腳本完全脫鉤:照著做,不需要 cpctl 也能裝出同樣的叢集;對照著讀,就能知道 cpctl 的每個步驟背後在做什麼。

範圍:

- 離線軟體引進與內部 repo(第 2 章)
- 安裝步驟 00–11(第 3–6 章),每一步都對應到 cpctl 的同名 step
- tar.gz 安裝方式(第 7 章),也就是不用 RPM 的替代做法
- 版本升級(第 8 章):滾動升級、回滾、finalize
- 憑證輪替與 CA 輪替(第 9 章):不停機換憑證、三階段換 CA
- 實測紀錄(附錄 A):在一套全新的模擬環境中,從外網下載開始、完全照本手冊手動裝完整套叢集並驗收,再於持續負載下演練升級與憑證/CA 輪替(全部 0 遺失);另外在備用節點上以 rpm 與 tar.gz 各做一次單節點安裝。實測中發現的問題都已修進手冊
- 手冊引用的檔案完整內容(附錄 D),手動安裝時不需要 cpctl 專案

> 手冊中的主機名稱、IP、版本號都取自 PoC 的 `installer/conf/*.env`。搬到正式環境時,把這些值換成正式環境的值即可,指令本身不變。

## 1.2 每一步的寫法

每個步驟都用同樣的格式,方便查找:

| 欄位 | 內容 |
|---|---|
| 目的 | 為什麼要做這一步 |
| 主機 / 帳號 | 在哪幾台主機、用哪個帳號執行 |
| 手動指令 | 可以直接複製貼上的指令(密碼一律寫成 `<password>`) |
| 設定檔內容 | 這一步寫出的檔案長什麼樣子 |
| 驗證 | 怎麼確認做對了、預期看到什麼 |
| 對應 cpctl | cpctl 裡負責這件事的 step 或函式 |
| 注意事項 | 容易出錯的地方 |

指令慣例:

- 以 `$` 開頭的範例是在**操作機 ops01** 上以 `cpadmin` 執行;要在節點上做的事,一律寫成 `ssh <host> "sudo ..."`,和 cpctl 的派送方式相同(cpctl 也是從 ops01 經 SSH 執行)。
- `sudo` 底下用萬用字元(`*`)時,要讓 root 來展開,例如 `sudo find <dir> -mindepth 1 -delete`;寫成 `sudo rm -rf <dir>/*` 時,`*` 是由 cpadmin 的 shell 展開的,cpadmin 讀不到 0750 的目錄,結果什麼都沒刪(附錄 A 實際踩到)。

>! 密碼、私鑰、master key 不要直接打在指令列上(會留在 shell history 與 `ps` 輸出)。手冊中凡是 `<password>` 的地方,實務上請從權限 600 的檔案讀取,或用環境變數傳入。

## 1.3 拓樸與主機

| 主機 | IP | 角色 | 說明 |
|---|---|---|---|
| ops01 | 172.30.0.10 | 操作機、內部 repo | 執行所有安裝指令;httpd :8443（HTTPS，3.3.0）提供 yum 與 raw repo;內部 CA 也在這台 |
| ad01 | 172.30.0.11 | AD(Samba) | LDAPS 636;正式環境是行內 AD |
| lb01 | 172.30.0.12 | Nginx L4 | REST :8082、C3 :9021 的 TCP passthrough;唯一對外的主機 |
| jump01 | 172.30.0.13 | 堡壘機 | OP menu(固定帳號 opuser) |
| kc01、kc02、kc04 | 172.30.0.21/22/24 | KRaft controller | node.id 1、2、4(動態 quorum) |
| kc03 | 172.30.0.23 | 備用 controller | node.id 3;本手冊的手動驗證機 |
| kb01–kb04 | 172.30.0.31–34 | broker + MDS | node.id 101–104;kb01/02 為 rack-a,kb03/04 為 rack-b |
| rest01、rest02 | 172.30.0.41/42 | REST Proxy | mTLS + RBAC |
| c3-01 | 172.30.0.51 | Control Center | 含 Prometheus、Alertmanager |

所有主機的 FQDN 為 `<host>.poc.lab`;另有兩個別名 `rest.poc.lab`、`c3.poc.lab` 指向 lb01。

## 1.4 帳號

| 帳號 | 在哪裡 | 用途 |
|---|---|---|
| cpadmin | 所有主機 | SSH 安裝帳號;只用金鑰登入,sudo 權限只開安裝需要的指令 |
| repoadmin | ops01 | 內部 repo 目錄的擁有者;httpd 只有讀權 |
| cp-kafka / cp-kafka-rest / cp-control-center | 各服務主機 | 服務執行帳號;system user、nologin、不可 SSH;群組都是 `confluent` |
| kafka-internal(憑證) | kc、kb | controller 與 broker 之間的 mTLS 身分;super user |
| kafka-admin(SCRAM) | Kafka | 管理用帳號,format 時寫入 |
| svc-mds-bind、svc-rest、svc-c3 | AD | MDS 查 LDAP、REST Proxy 代理身分、C3 服務帳號 |
| opuser / opbootstrap / kafkaops | jump01、各節點 | OP menu 的固定帳號(第 6 章) |

## 1.5 埠號

| Port | 協定 | 用途 |
|---|---|---|
| 9093 | SSL(mTLS) | KRaft controller |
| 9092 | SSL(mTLS) | INTERNAL,broker 之間 |
| 9094 | SASL_SSL / OAUTHBEARER | TOKEN,C3 與 REST Proxy 代理使用者 |
| 9095 | SASL_SSL / SCRAM-SHA-512 | CLIENT,應用程式 |
| 9096 | SASL_SSL / PLAIN + LDAP | LDAP,人用 AD 帳密直連 |
| 8090 | HTTPS | MDS(RBAC) |
| 8082 | HTTPS(mTLS) | REST Proxy |
| 9021 | HTTPS | Control Center |
| 9090 / 9093 | HTTPS(mTLS) | c3-01 上的 Prometheus / Alertmanager |
| 7071 | HTTPS + basic auth | JMX exporter(各 Java 節點) |
| 8443 | HTTPS | ops01 內部 repo(3.3.0 起;憑證 cp-server,節點以 `sslcacert` 固定信任的 CA) |
| 8080 | HTTP | ops01 內部 repo:只在第 2 章建 repo 時使用;3.3.0 之後一律回 403 |

## 1.6 步驟一覽

| 步驟 | 內容 | 主機 | 本手冊 |
|---|---|---|---|
| 離線引進 | 外網下載 → 驗證 → 檔案交換 → 匯入內部 repo | Windows、ops01 | 第 2 章 |
| 00_precheck | 安裝前檢查(連線、sudo、node.id、磁碟、離線性) | 全部 | 3.1 |
| 01_os_baseline | 帳號、limits、sysctl、chrony、firewalld、SELinux、THP | 全部 | 3.2 |
| 02_distribute | repo 設定與套件安裝(rpm)或解壓(tar) | 全部 | 3.3 |
| 03_pki | 內部 CA、共用憑證、truststore、MDS token 金鑰 | ops01 → 全部 | 3.4 |
| 04_ad_bootstrap | AD 服務帳號、群組、測試使用者 | ad01 | 4.1 |
| 05_configure | server.properties、systemd drop-in、Secret Protection | kc、kb | 4.2 |
| 06_kraft_format | cluster id、動態 quorum 格式化 | kc、kb | 4.3 |
| 07_start_core | 依序啟動 controller、broker,健康檢查 | kc、kb | 4.4 |
| 08_security_bootstrap | SCRAM、RBAC role binding、稽核日誌 | ops01 | 5.1 |
| 09_start_edge | REST Proxy、C3、Nginx | rest、c3、lb | 5.2 |
| 10_verify | 整體驗收(48 項) | ops01 | 5.3 |
| 11_opmenu | 堡壘機 OP menu | jump01、各節點 | 第 6 章 |
| (維運)升級 | 新版本引進、滾動升級、回滾、finalize | 全部 | 第 8 章 |
| (維運)憑證 / CA 輪替 | 重簽憑證;CA 三階段 add → switch → retire | 全部 | 第 9 章 |

## 1.7 rpm 與 tar.gz 兩種安裝方式

預設用 RPM:有原廠 GPG 簽章、附帶 systemd unit、可以用 `dnf versionlock` 鎖版本,也能接上 RHEL 原本的維運流程。tar.gz 是替代做法,適用於不能用 RPM 的環境。兩者只有「程式放在哪裡、怎麼啟動」不同,設定檔、憑證、資料目錄完全一樣:

| 項目 | rpm | tar.gz |
|---|---|---|
| 程式位置 | `/usr/bin`、`/usr/share/java`(RPM 管理) | `/opt/confluent/confluent-8.3.2`,經 `/opt/confluent/current` |
| JDK | `/usr/lib/jvm/temurin-21-jdk` | `/opt/java/jdk-21.0.12.1+1`,經 `/opt/java/current` |
| systemd unit | RPM 附帶,加我們的 drop-in | 自己提供 unit,再加 drop-in |
| 服務帳號 | RPM scriptlet 建立 | 手動 `useradd` |
| 鎖版本 | `dnf versionlock` | current symlink 就是唯一的有效版本 |
| 升級 / 回滾 | `dnf install` / `dnf downgrade` | 解壓新版、切換 symlink / 切回舊版 |
| 設定、憑證、資料 | `/etc/confluent`、`/var/lib/kafka`(相同) | 相同 |

第 3–6 章以 rpm 為主線;tar.gz 的差異集中在第 7 章。

# 2. 離線軟體引進與內部 repo

> 適用：Confluent Platform 8.3.2 離線安裝 PoC。本文把 `windows/*.sh`、`installer/lib/repo/local.sh`、`installer/steps/00_precheck.sh` 做的事情拆成人工可逐行執行的指令。
> 所有版本號、路徑、主機名都取自 `installer/conf/versions.env` 與 `installer/conf/inventory.env`（2026-10-16 版）。密碼一律以 `<password>` 表示。

## 2.0 流程總覽

```
[外網下載機 Rocky 9 (root)]                     [內網 ops01 (cpadmin → sudo repoadmin)]
 1.2 dnf download --resolve  → rpm/                1.9  落地區 /mnt/exchange (唯讀)
 1.3 curl tar.gz             → tar/                1.10 sha256sum -c + rpm -K   (再驗一次)
 1.4 curl JMX exporter jar   → tools/              1.11 install -D 到 /srv/repo (不覆寫)
 1.5 opmenu 打包             → tools/              1.12 createrepo_c --update
 1.6 sha256sum               → SHA256SUMS          1.13 稽核副本 /srv/repo/manifests/<時間>/
 1.7 驗證閘門 + scan.d       → report/             1.14 curl :8080 驗證 (repo verify / list)
 1.8 實體/核准管道搬運  ───────────────────────────►  1.15 00_precheck
```

內部 repo 最終目錄（ops01 實際狀態）：

```
/srv/repo/                       (repoadmin:repoadmin 0755，httpd :8080 DocumentRoot)
├── rpm/confluent/   *.rpm + repodata/   (21 個：CP 8.3.2 與 8.2.4 各 10 個 + C3 2.6.1)
├── rpm/adoptium/    temurin-21-jdk-21.0.12.1.0.1-0.x86_64.rpm + repodata/
├── rpm/os-deps/     43 個 OS 相依套件 (chrony, firewalld, cyrus-sasl, openssl-devel, fontconfig…) + repodata/
├── raw/tar/         confluent-8.3.2.tar.gz, confluent-8.2.4.tar.gz,
│                    confluent-control-center-next-gen-2.6.1.tar.gz,
│                    OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz
├── raw/tools/       jmx_prometheus_javaagent-1.0.1.jar, opmenu-<日期>.<sha8>.tar.gz
├── gpg-keys/        confluent.asc, confluent-c3.asc, adoptium.asc, rocky-9.asc
└── manifests/<YYYYmmdd-HHMMSS>/  SHA256SUMS, manifest-rpm.json, manifest-tar.json, report/
```

對外 URL：`http://ops01.poc.lab:8080/rpm/<repo>`（= `REPO_YUM_BASEURL`）與 `http://ops01.poc.lab:8080/raw`（= `REPO_RAW_BASEURL`）。 3.3.0 之後改為 `https://ops01.poc.lab:8443/...`（PoC 的 `inventory.env` 已是 https）。

## 2.1 版本控制：`installer/conf/versions.env`

**目的**：所有版本的唯一來源（single source of truth）。外網下載與內網安裝讀同一份檔案，確保「下載的」就是「要裝的」，且永遠指定精確版本、不用 latest。

**在哪台／帳號**：在版控（Windows 開發機）編輯；變更需走變更單。外網下載機與 ops01 都讀同一版本的檔案（PoC 中 ops01 以唯讀方式掛載 `/opt/cp-installer`）。

**設定檔內容（現行值，節錄）**：

```bash
CP_VERSION=8.3.2
CP_RELEASE=8.3                 # repo 路徑段與 finalize 的 metadata 版本
CP_UPGRADE_FROM=8.2.4          # 為升級演練保留在內部 repo 的舊版
CP_UPGRADE_FROM_RELEASE=8.2
C3_VERSION=2.6.1
JDK_PACKAGE=temurin-21-jdk
JDK_VERSION=21.0.12.1.0.1      # RPM version（不含 -release）

CONFLUENT_RPM_BASE=https://packages.confluent.io/rpm
CONFLUENT_GPG_KEY=https://packages.confluent.io/rpm/8.3/archive.key
C3_RPM_BASE=https://packages.confluent.io/confluent-control-center-next-gen/rpm/
C3_GPG_KEY=https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key
ADOPTIUM_RPM_BASE=https://packages.adoptium.net/artifactory/rpm/rhel/9/x86_64
ADOPTIUM_GPG_KEY=https://packages.adoptium.net/artifactory/api/gpg/key/public
CONFLUENT_TAR_BASE=https://packages.confluent.io/archive

PKGS_CONTROLLER="confluent-server confluent-security"
PKGS_BROKER="confluent-server confluent-security"
PKGS_REST="confluent-kafka-rest confluent-security"
PKGS_OPS="confluent-server confluent-security confluent-cli"
PKGS_JUMP="confluent-server confluent-security"
PKGS_C3="confluent-control-center-next-gen"
PKGS_C3_OS="cyrus-sasl openssl-devel"
PKGS_OS_BASELINE="chrony firewalld"

JDK_TAR_MAJOR=21
JMX_EXPORTER_VERSION=1.0.1
JMX_EXPORTER_URL=https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar
OPMENU_VERSION=20261016.f03b18c0
```

**驗證**：

```bash
bash -n installer/conf/versions.env && echo syntax-ok
grep -E '^(CP_VERSION|C3_VERSION|JDK_VERSION|JMX_EXPORTER_VERSION|OPMENU_VERSION)=' installer/conf/versions.env
```

預期：`syntax-ok`，並列出上述五個值。

**對應 cpctl**：`windows/lib.sh` 的 `load_versions()`；cpctl 端為 `inv::load()`（`core::load_env` 以 `set -a; source` 載入）。

**注意事項／陷阱**：
- 只能是 bash 可 source 的 `KEY=VALUE`；不可有 CRLF（`windows/lib.sh` 的 `check_crlf` 會擋）。
- `JDK_VERSION` 是 RPM 的 version 欄位（`dnf repoquery temurin-21-jdk` 查得），**不含** `-0` release；tar 策略則用 `JDK_TAR_MAJOR=21` 自動取該主版最新 GA，兩者可能不是同一小版。
- `OPMENU_VERSION` 由 `windows/package-opmenu.sh` 自動改寫（2.5），手動流程需自行更新。
- 演練時可用環境變數 `CPCTL_CP_VERSION=8.2.4` 暫時安裝舊版而不改檔；手動流程請直接以 8.2.4 套件名稱操作。

## 2.2 外網下載：RPM（Confluent / C3 / Temurin / OS 相依）

**目的**：在「與目標主機同一個基底映像」的乾淨 Rocky 9 上用 `dnf download --resolve`，一次取得目標主機缺少的所有相依套件，並依來源 repo 分類成 `confluent / adoptium / os-deps` 三個內部 repo。

**在哪台／帳號**：外網下載機（PoC：以 `cp-node:poc` 映像啟動的一次性容器；正式：與行內 RHEL 9 基線相同的乾淨 VM），`root`。輸出目錄以 `/out` 表示（PoC 對應 Windows 專案的 `packages/`）。

**手動指令**：

```bash
mkdir -p /tmp/stage /out/gpg-keys /out/rpm/confluent /out/rpm/adoptium /out/rpm/os-deps
sed -i 's/^enabled=0/enabled=1/' /etc/yum.repos.d/rocky*.repo
```

寫入上游 repo 定義（僅下載機使用，目標主機永遠看不到），檔案 `/etc/yum.repos.d/upstream-confluent.repo`：

```ini
[confluent-8.3]
name=Confluent 8.3
baseurl=https://packages.confluent.io/rpm/8.3
gpgcheck=1
gpgkey=https://packages.confluent.io/rpm/8.3/archive.key
enabled=1
[confluent-8.2]
name=Confluent 8.2
baseurl=https://packages.confluent.io/rpm/8.2
gpgcheck=1
gpgkey=https://packages.confluent.io/rpm/8.3/archive.key
enabled=1
[confluent-c3]
name=Confluent Control Center next-gen
baseurl=https://packages.confluent.io/confluent-control-center-next-gen/rpm/
gpgcheck=1
gpgkey=https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key
enabled=1
[adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/rhel/9/x86_64
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
enabled=1
```

取得並匯入 GPG 公鑰：

```bash
curl -fsSL https://packages.confluent.io/rpm/8.3/archive.key -o /out/gpg-keys/confluent.asc
curl -fsSL https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key -o /out/gpg-keys/confluent-c3.asc
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public -o /out/gpg-keys/adoptium.asc
cp /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9 /out/gpg-keys/rocky-9.asc
for k in /out/gpg-keys/*.asc; do rpm --import "$k"; done
dnf -q makecache
```

分五組下載（**每組一個 transaction**，兩個 CP 版本不可放同一組）：

```bash
dnf -q download --resolve --arch x86_64 --arch noarch --destdir /tmp/stage confluent-server-8.3.2 confluent-security-8.3.2 confluent-kafka-rest-8.3.2 confluent-cli-8.3.2
dnf -q download --resolve --arch x86_64 --arch noarch --destdir /tmp/stage confluent-server-8.2.4 confluent-security-8.2.4 confluent-kafka-rest-8.2.4 confluent-cli-8.2.4
dnf -q download --resolve --arch x86_64 --arch noarch --destdir /tmp/stage confluent-control-center-next-gen-2.6.1 cyrus-sasl openssl-devel
dnf -q download --resolve --arch x86_64 --arch noarch --destdir /tmp/stage temurin-21-jdk-21.0.12.1.0.1
dnf -q download --resolve --arch x86_64 --arch noarch --destdir /tmp/stage chrony firewalld
```

依來源 repo 分類（Confluent 三個 repo → confluent；adoptium → adoptium；其餘 → os-deps；已存在的同名檔不覆蓋）：

```bash
dnf -q repoquery --repo confluent-8.3 --repo confluent-8.2 --repo confluent-c3 --qf '%{name}' | sort -u > /tmp/cp-names
dnf -q repoquery --repo adoptium --qf '%{name}' | sort -u > /tmp/ad-names
for f in /tmp/stage/*.rpm; do
  n=$(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null)
  if grep -qx "$n" /tmp/cp-names; then d=confluent; elif grep -qx "$n" /tmp/ad-names; then d=adoptium; else d=os-deps; fi
  [ -f "/out/rpm/$d/$(basename "$f")" ] || mv "$f" "/out/rpm/$d/"
done
```

在下載機上先驗一次簽章：

```bash
find /out/rpm -name '*.rpm' -print0 | xargs -0 rpm -K | grep -v 'digests signatures OK'
```

產生 `manifest-rpm.json`（每個 RPM 的 repo / file / name / version / vendor / sha256 / size，以及 `generated_at`、`downloaded_by`、`sources`、`gpg_verified: true`）。手動可用：

```bash
for f in /out/rpm/*/*.rpm; do printf '%s|%s|%s\n' "$(basename "$(dirname "$f")")" "$(rpm -qp --qf '%{NAME}|%{VERSION}-%{RELEASE}|%{VENDOR}' "$f")" "$(sha256sum "$f" | awk '{print $1}')"; done > /out/manifest-rpm.txt
```

（腳本版以 python3 輸出 JSON；手動時若變更單接受文字清單即可，否則沿用腳本內那段 python。）

**驗證**：

```bash
ls /out/rpm/confluent | wc -l     # 預期 21（只下載 8.3.2、不含升級演練用的 8.2.4 時為 11）
ls /out/rpm/adoptium              # 預期 temurin-21-jdk-21.0.12.1.0.1-0.x86_64.rpm
ls /out/rpm/os-deps | wc -l       # 預期 43（隨 Rocky 9 更新而變）
find /out/rpm -name '*.rpm' -print0 | xargs -0 rpm -K | grep -vc 'digests signatures OK'   # 預期 0
```

`rpm -K` 單筆預期輸出：`confluent-server-8.3.2-1.noarch.rpm: digests signatures OK`。`grep -c` 的計數為 0 時結束碼是 1，這裡看的是印出的數字，不是結束碼。

**操作機自己的工具（沒有行內 OS 鏡像時）**：內部 repo 主機需要 `httpd`、`createrepo_c`（以及 `jq`、`openldap-clients`）。正式環境從行內 RHEL 鏡像或 RHEL 安裝光碟（BaseOS/AppStream）安裝；連這些都沒有時，在同一台下載機一併下載到 `bootstrap/`，跟著落地區一起進內網（2.9 直接安裝這些檔案）：

```bash
mkdir -p /out/bootstrap
dnf -q download --resolve --arch x86_64 --arch noarch --destdir /out/bootstrap httpd createrepo_c jq openldap-clients
ls /out/bootstrap | wc -l     # 實測 18 個
```

**對應 cpctl**：`windows/download-packages.sh --method rpm`（或 `both`）→ 容器內 `windows/download-in-container.sh`。

**注意事項／陷阱**：
- 下載機必須與目標主機**同一基底**（同 RHEL/Rocky 小版與同樣已安裝套件），否則 `--resolve` 會漏抓或多抓 OS 相依。
- `confluent-cli` 在 RPM 策略中是獨立 RPM（`confluent-cli-8.3.2-1.x86_64.rpm`），只裝在 ops01（`PKGS_OPS`）。
- C3 的 GPG key 與 Confluent 8.3 key 內容相同（兩檔 sha256 一致），重複不是錯誤。
- 首次下載約 3 GB；重跑只會補新檔（同名檔不覆蓋）。

## 2.3 外網下載：tar.gz（CP、C3、Temurin JDK；CLI 隨 CP 封存）

**目的**：提供 `INSTALL_METHOD=tar` 策略所需的封存檔，並為升級／回退演練保留舊版 CP 封存。Temurin 以官方 API 提供的 checksum 驗證；CP/C3 官方未公布 checksum，只能在下載當下記錄 sha256。

**在哪台／帳號**：外網下載機，`root`（或任一可寫 `/out/tar` 的帳號）。

**手動指令**：

```bash
mkdir -p /out/tar && cd /out/tar
curl -fsSL --retry 3 -o confluent-8.3.2.tar.gz.part https://packages.confluent.io/archive/8.3/confluent-8.3.2.tar.gz && mv confluent-8.3.2.tar.gz.part confluent-8.3.2.tar.gz
curl -fsSL --retry 3 -o confluent-control-center-next-gen-2.6.1.tar.gz.part https://packages.confluent.io/confluent-control-center-next-gen/archive/confluent-control-center-next-gen-2.6.1.tar.gz && mv confluent-control-center-next-gen-2.6.1.tar.gz.part confluent-control-center-next-gen-2.6.1.tar.gz
curl -fsSL --retry 3 -o confluent-8.2.4.tar.gz.part https://packages.confluent.io/archive/8.2/confluent-8.2.4.tar.gz && mv confluent-8.2.4.tar.gz.part confluent-8.2.4.tar.gz
```

Temurin 21：先查 API 取得下載連結、檔名、官方 sha256：

```bash
curl -fsSL 'https://api.adoptium.net/v3/assets/latest/21/hotspot?os=linux&architecture=x64&image_type=jdk&vendor=eclipse' | python3 -c 'import json,sys; a=json.load(sys.stdin)[0]; p=a["binary"]["package"]; print(p["link"]); print(p["name"]); print(p["checksum"]); print(a["release_name"])'
```

本次結果：檔名 `OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz`，release `jdk-21.0.12.1+1`。

```bash
curl -fsSL --retry 3 -o OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz <上一步的 link>
echo "<上一步的 checksum>  OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz" | sha256sum -c
sha256sum *.tar.gz > /out/manifest-tar.txt
```

**驗證**：

```bash
ls -l /out/tar
```

預期四個檔，大小約：JDK 207 MB、confluent-8.2.4 1.24 GB、confluent-8.3.2 1.35 GB、C3 2.6.1 1.14 GB；JDK 的 `sha256sum -c` 顯示 `OK`。本次記錄的 sha256（`manifest-tar.json`）：

```
ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94  OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz
3c69b6e651f140c94ea7b85d5473d7d6049324b0cec9b7e477e6ca2612ba0e68  confluent-8.2.4.tar.gz
946433221bae8272de416694060322aef0c9c8b3086da9574f86d6cb0d698c2f  confluent-8.3.2.tar.gz
8389b4d3d68c466126f80ecdb6e3e74d7ab8e808af549260713356e44ffaed8b  confluent-control-center-next-gen-2.6.1.tar.gz
```

**對應 cpctl**：`windows/download-packages.sh --method tar` → `windows/download-tar-in-container.sh`（`fetch()` 以 `.part` 暫存後改名；`manifest-tar.json` 寫在 `/out` 根目錄）。

**注意事項／陷阱**：
- Confluent CLI 在 tar 策略**不需另外下載**，就是 CP 封存內的 `bin/confluent`。
- Temurin 的 API 是「該主版最新 GA」，換天重跑可能抓到更新的小版而產生**新檔名**；安裝端取 `/srv/repo/raw/tar/OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz` 中 `sort -V` 最新的一個。
- 已存在且非空的檔不會重抓；中斷時殘留的 `.part` 要手動刪除。
- CP/C3 封存沒有官方 checksum，信任基礎只有「下載當下的 sha256 + 之後全程比對」，變更單應註明。

## 2.4 外網下載：Prometheus JMX exporter（javaagent jar）

**目的**：外部監控用的 javaagent 也必須走同一條離線引進鏈；以 Maven Central 公布的 sha1 驗證。

**在哪台／帳號**：外網下載機，`root`。

**手動指令**：

```bash
mkdir -p /out/tools && cd /out/tools
curl -fsSL --retry 3 -o jmx_prometheus_javaagent-1.0.1.jar https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar
curl -fsSL https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar.sha1
sha1sum jmx_prometheus_javaagent-1.0.1.jar
```

**驗證**：上兩行輸出的 sha1 必須完全相同；檔案大小 2,886,599 bytes。

**對應 cpctl**：`windows/download-in-container.sh` 末段（屬 `--method rpm`；只選 `--method tar` 時**不會**下載 jar）。

**注意事項／陷阱**：
- 安裝端固定找 `raw/tools/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar`（`roles/_role.sh` 的 `role::jmx_exporter`）；改版本要同時改 `JMX_EXPORTER_VERSION` 與 `JMX_EXPORTER_URL`。
- Maven Central 只提供 sha1（無 GPG 驗證於此流程），之後由 SHA256SUMS 接手。

## 2.5 內部軟體打包：OP menu（opmenu tarball）

**目的**：把跳板機 OP menu 程式（內部自製軟體）打成**可重現**的 tarball，以內容雜湊作版本號，使同內容永遠得到同版本、改了內容一定得到新版本，進而不可能覆蓋已發佈的版本。

**在哪台／帳號**：開發機（Git Bash 或任一 Linux，需 GNU tar ≥ 1.28、gzip、perl），一般使用者。來源目錄 `opmenu/`。

**手動指令**：

```bash
cd /c/Users/user/IdeaProjects/untitled7
grep -rl $'\r' opmenu/opmenu.sh opmenu/lib opmenu/README.md opmenu/opmenu.conf.example   # 有輸出 = 有 CRLF 檔案,先修正再打包
stage=$(mktemp -d) && mkdir -p "$stage/opmenu"
cp -r opmenu/opmenu.sh opmenu/lib opmenu/README.md opmenu/opmenu.conf.example "$stage/opmenu/"
[ -f opmenu/test-host-gate.sh ] && cp opmenu/test-host-gate.sh "$stage/opmenu/"
tar --sort=name --mtime='2026-01-01 00:00:00' --owner=0 --group=0 --numeric-owner -C "$stage" -cf "$stage/opmenu.tar" opmenu
gzip -n -9 "$stage/opmenu.tar"
sha=$(sha256sum "$stage/opmenu.tar.gz" | awk '{print $1}'); ver="$(date +%Y%m%d).${sha:0:8}"; echo "$ver"
install -m 0644 "$stage/opmenu.tar.gz" "packages/tools/opmenu-$ver.tar.gz"
sed -i "s/^OPMENU_VERSION=.*/OPMENU_VERSION=$ver/" installer/conf/versions.env
rm -rf "$stage"
```

（腳本另會把這一行寫入 `packages/SHA256SUMS`；手動時直接在 2.6 重算整份即可。）

**驗證**：

```bash
tar -tzf packages/tools/opmenu-$ver.tar.gz | head
grep '^OPMENU_VERSION=' installer/conf/versions.env
```

預期：內容只有 `opmenu/opmenu.sh`、`opmenu/lib/...`、`opmenu/README.md`、`opmenu/opmenu.conf.example`（可能有 `test-host-gate.sh`），沒有 log、環境設定或帳密；`OPMENU_VERSION` 等於剛算出的 `$ver`。

**對應 cpctl**：`windows/package-opmenu.sh [來源目錄]`。

**注意事項／陷阱**：
- 只打包白名單檔案；`/etc/opmenu/opmenu.conf` 由 cpctl 在安裝時另行產生，**不可**放入包內。
- 內容雜湊相同但日期不同 → 版本字串不同（`date` 前綴），會在 repo 多出一個內容相同的新檔；這是預期行為，但會累積舊版（現況 `raw/tools/` 已有 3 個 opmenu 版本，安裝只取 `OPMENU_VERSION` 那一個）。
- 不可省略 `--sort/--mtime/--owner/-n`，否則同內容每次 sha 都不同。
- 精簡的 Linux 主機可能沒有 perl;CRLF 檢查用上面的 `grep -rl $'\r'` 即可(全程實測時下載機就沒有 perl)。
- 不同版本的 GNU tar 打出的位元組可能不同,換一台機器打包會得到另一個版本號;以實際匯入 repo 的檔名為準。

## 2.6 產生 SHA256SUMS

**目的**：整個落地區的完整性清單，是內網端「驗證 → 發佈 → 不覆寫」判斷的唯一依據。

**在哪台／帳號**：外網下載機（Linux），任一可寫輸出目錄的帳號。

**手動指令**：

```bash
cd /out
find rpm tar tools gpg-keys -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS
wc -l SHA256SUMS
```

**驗證**：`wc -l` 預期 77（65 RPM + 4 tar + 4 tools + 4 gpg-keys，以目前落地區為準）；格式為 `<64 hex>  <相對路徑>`，例如：

```
a46d5d3ab75c3c86dddf1bfd2957a067a24b1c6b2d2ed2bc69294bf970c5160b  gpg-keys/adoptium.asc
```

**對應 cpctl**：`windows/download-packages.sh` 最後一段（在 Linux 容器內執行）。

**注意事項／陷阱**：
- 請在 Linux 上算：腳本註明 Git Bash 的 `sha256sum` 對數 GB 檔案不可靠。
- 只收 `rpm/ tar/ tools/ gpg-keys/` 四個目錄；`manifest-*.json`、`report/` 不在清單內（它們之後只做稽核副本）。
- 路徑必須是相對路徑，內網端在落地區根目錄 `cd` 後執行 `sha256sum -c`。

## 2.7 外網驗證閘門（checksum + GPG + scan.d 掃描）

**目的**：檔案跨入內網**之前**的最後一道檢查，並產生可附在變更單上的驗證報告。

**在哪台／帳號**：外網下載機（PoC：Windows 以 `cp-node:poc` 容器唯讀掛載 `packages/` 至 `/p`），任一帳號（`rpm --import` 需 root）。

**手動指令**：

```bash
cd /out && mkdir -p report
report=report/verify-$(date +%Y%m%d-%H%M%S).txt
{ echo "== sha256 =="; sha256sum -c --quiet SHA256SUMS && echo "all $(wc -l <SHA256SUMS) files match SHA256SUMS"; } | tee "$report"
for k in gpg-keys/*.asc; do rpm --import "$k"; done
echo "== gpg ==" | tee -a "$report"
find rpm -name '*.rpm' -print0 | xargs -0 rpm -K | grep -v 'digests signatures OK' | sed 's/^/BAD: /' | tee -a "$report"
echo "all $(find rpm -name '*.rpm' | wc -l) RPMs checked" | tee -a "$report"
bash /c/Users/user/IdeaProjects/untitled7/windows/scan.d/10-inventory.sh /out | tee -a "$report"
```

`scan.d/10-inventory.sh` 只是範例 hook：從 `manifest-rpm.json` 印出「名稱 / 版本 / 廠商」清單。可再放 `20-antivirus.sh`、`30-trivy-sbom.sh` 等，每支收到落地區路徑為 `$1`，依檔名順序執行。

**驗證**：報告內容預期：

```
== sha256 ==
all 77 files match SHA256SUMS
== gpg ==
all 65 RPMs have valid vendor signatures
== package inventory ==
confluent-ce-kafka-http-server           8.2.4-1                Confluent, Inc.
...
```

`== gpg ==` 下方不應出現任何 `BAD:` 行。

**對應 cpctl**：`windows/verify-packages.sh`（寫 `packages/report/verify-<時間>.txt`）。

**注意事項／陷阱**：
- tar.gz 與 jar 不是 RPM，**沒有 GPG 驗證**，只靠 SHA256SUMS（以及 2.3/2.4 的廠商 checksum）。
- 外網閘門通過不代表內網可省略驗證：2.10 會在內網再做一次（防搬運途中被竄改）。
- `verify-packages.sh` 的 hook 若失敗，`tee` 會吃掉退出碼（`pipefail` 下仍會中止腳本，但報告可能不完整），人工執行時請逐支確認輸出。

## 2.8 搬運至內網落地區

**目的**：經行內核准管道（媒體、檔案交換區）把整個 `packages/` 目錄原封不動送到內網操作機的落地區。

**在哪台／帳號**：依行內流程；PoC 由 docker compose 將 `../packages` **唯讀**掛載為 `ops01:/mnt/exchange`。

**手動指令**（正式環境示意：落地區唯讀掛載或由交換區複製後設為唯讀）：

```bash
ls -la /mnt/exchange
findmnt -no OPTIONS /mnt/exchange
```

**驗證**：`/mnt/exchange` 下應有 `SHA256SUMS`、`manifest-rpm.json`、`manifest-tar.json`、`gpg-keys/`、`rpm/`、`tar/`、`tools/`、`report/`；掛載選項含 `ro`。

**對應 cpctl**：無（`REPO_LANDING=/mnt/exchange` 為 `local.sh` 預設值，可用環境變數覆寫）。

**注意事項／陷阱**：
- 必須帶 `report/` 與 `manifest-*.json` 一起搬，匯入時會留存為稽核證據。
- 落地區保持唯讀，避免有人在內網端「修補」檔案導致 checksum 不符。

## 2.9 內部 repo 主機準備（ops01：httpd :8080 + createrepo_c + repoadmin）

**目的**：沒有 Satellite/Artifactory/Nexus 時，由操作機自己擔任內部 yum repo 與原始檔（raw）伺服器；以專用帳號 `repoadmin` 擁有內容，httpd 只允許讀取。

**在哪台／帳號**：ops01，`root`（一次性；PoC 已在 `docker/ops/Dockerfile` 建置時完成）。

**手動指令**：

```bash
dnf -y install httpd createrepo_c                 # 有行內 RHEL 鏡像或安裝光碟時
# 沒有時,改裝落地區 bootstrap/ 的檔案;直接裝本機 RPM 檔時 dnf 預設不驗簽章(localpkg_gpgcheck=0),要先自己驗
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9          # 正式環境:RPM-GPG-KEY-redhat-release
rpm -K /mnt/exchange/bootstrap/*.rpm | grep -vc 'digests signatures OK'      # 必須是 0
dnf -y -q --disablerepo='*' install /mnt/exchange/bootstrap/*.rpm
sed -i 's/^Listen 80$/Listen 8080/' /etc/httpd/conf/httpd.conf
rm -f /etc/httpd/conf.d/welcome.conf
useradd -r -s /sbin/nologin repoadmin
install -d -o repoadmin -g repoadmin -m 0755 /srv/repo
install -d -o cpadmin -g cpadmin -m 0750 /var/lib/cp-installer
vi /etc/httpd/conf.d/cp-repo.conf
systemctl enable --now httpd
firewall-cmd --permanent --add-port=8080/tcp && firewall-cmd --reload
```

**設定檔內容** `/etc/httpd/conf.d/cp-repo.conf`：

```apache
DocumentRoot "/srv/repo"
<Directory "/srv/repo">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
    <LimitExcept GET HEAD OPTIONS>
        Require all denied
    </LimitExcept>
</Directory>
```

**驗證**：

```bash
httpd -t
systemctl is-active httpd
ss -ltnp | grep 8080
stat -c '%U:%G %a %n' /srv/repo
curl -s -o /dev/null -w '%{http_code}\n' -X PUT http://ops01.poc.lab:8080/x
rpm -q httpd createrepo_c
```

預期：`Syntax OK`、`active`、httpd 在 `0.0.0.0:8080` LISTEN、`repoadmin:repoadmin 755 /srv/repo`、PUT 回 `405`、`httpd-2.4.62-13.el9_8.6.x86_64`、`createrepo_c-0.20.1-4.el9.x86_64`（PoC 實際版本）。

**對應 cpctl**：無（屬環境建置；這裡的 HTTP 8080 只在第 2 章使用；3.3.0 起改為 HTTPS 8443，防火牆由 `conf/os-tuning.env` 的 `FIREWALL_EXTRA_ops="8443"` 在 01_os_baseline 處理）。

**注意事項／陷阱**：
- 正式環境 httpd / createrepo_c 從行內 RHEL repo 或 RHEL 安裝光碟安裝;兩者都沒有時才用落地區的 `bootstrap/`(全程實測即採此方式,18 個 RPM)。
- 精簡 OS 可能沒有 `ss`;改用 `curl` 實測(GET 200、PUT 405)即可。
- SELinux enforcing 時 `/srv/repo` 需標 `httpd_sys_content_t`（`semanage fcontext -a -t httpd_sys_content_t '/srv/repo(/.*)?' && restorecon -Rv /srv/repo`），PoC 容器未啟用 SELinux，未驗證。
- `Options Indexes` 是為了讓人與 `curl` 能列目錄；若行內資安不允許目錄列表可移除，不影響 dnf。

## 2.10 內網匯入第 1 步：在落地區再次驗證

**目的**：內網端獨立重做完整性與簽章驗證；任何一個檔案不符就**整批不發佈**。

**在哪台／帳號**：ops01，`cpadmin`（`rpm --import` 需 `sudo`）。

**手動指令**：

```bash
cd /mnt/exchange
wc -l < SHA256SUMS
sha256sum --quiet -c SHA256SUMS && echo "landing zone checksums match SHA256SUMS"
for k in /mnt/exchange/gpg-keys/*.asc; do sudo -n rpm --import "$k"; done
find /mnt/exchange/rpm -name '*.rpm' -print0 | xargs -0 rpm -K | grep -v 'digests signatures OK'
```

**驗證**：`sha256sum` 印出 `landing zone checksums match SHA256SUMS`；最後一行指令**無任何輸出**（表示全部 `digests signatures OK`）。`rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n'` 應含：

```
gpg-pubkey-0c2bf624-60904208 Confluent Packaging <packages@confluent.io> public key
gpg-pubkey-65f8f04b-6193bd34 Adoptium GPG Key (DEB/RPM Signing Key) <temurin-dev@eclipse.org> public key
gpg-pubkey-350d275d-6279464b Rocky Enterprise Software Foundation - Release key 2022 <releng@rockylinux.org> public key
```

**對應 cpctl**：`cpctl repo import` → `repo::_verify_landing()`（失敗時 exit code 3 = `E_PRECHECK`，訊息 `checksum mismatch in landing zone - import aborted, nothing was published` 或 `unsigned or tampered RPMs in landing zone - import aborted`）。

**注意事項／陷阱**：
- 簽章驗證用的是 ops01 系統 rpmdb 的公鑰；若從未 `rpm --import`，`rpm -K` 會顯示 `digests SIGNATURES NOT OK`（缺鑰），不是檔案壞掉。
- 受限 sudo（`SUDO_MODE=restricted`，3.0.3）下，cpadmin 不能直接 `sudo rpm --import`；cpctl 改由 agent 的 `rpm_node::import_keys` 匯入。手動匯入時由管理員以 root 執行。

## 2.11 內網匯入第 2 步：發佈檔案到 /srv/repo（絕不覆寫）

**目的**：把 SHA256SUMS 列出的每個檔案依類型放到發佈位置；已存在且 sha256 相同 → 略過；已存在但內容不同 → **拒絕**。保證已發佈的檔案永遠不被悄悄替換。

**在哪台／帳號**：ops01，`cpadmin` 以 `sudo -u repoadmin` 寫入（umask 022，讓 httpd 可讀）。

**路徑對應**：

| 落地區 | 發佈位置 |
|---|---|
| `rpm/<repo>/x.rpm` | `/srv/repo/rpm/<repo>/x.rpm` |
| `tar/x.tar.gz` | `/srv/repo/raw/tar/x.tar.gz` |
| `tools/x` | `/srv/repo/raw/tools/x` |
| `gpg-keys/x.asc` | `/srv/repo/gpg-keys/x.asc` |
| 其他 | 忽略 |

**手動指令**（先做「衝突預檢」，全部通過才實際發佈，相當於 `cpctl --check repo import`）：

```bash
cd /mnt/exchange
dest_of() { case $1 in rpm/*|gpg-keys/*) echo "/srv/repo/$1" ;; tar/*|tools/*) echo "/srv/repo/raw/$1" ;; *) return 1 ;; esac; }
while read -r sum rel; do rel=${rel#\*}; d=$(dest_of "$rel") || continue; if [ -f "$d" ]; then [ "$(sha256sum "$d" | awk '{print $1}')" = "$sum" ] || echo "CONFLICT: $rel"; else echo "would publish $rel"; fi; done < SHA256SUMS
```

確認沒有任何 `CONFLICT:` 行後才執行：

```bash
while read -r sum rel; do rel=${rel#\*}; d=$(dest_of "$rel") || continue; [ -f "$d" ] && continue; sudo -n -u repoadmin bash -c 'umask 022; exec install -D -m 0644 "$1" "$2"' _ "/mnt/exchange/$rel" "$d" && echo "published $rel"; done < SHA256SUMS
```

**驗證**：

```bash
cd /mnt/exchange && while read -r sum rel; do d=$(dest_of "$rel") || continue; echo "$sum  $d"; done < SHA256SUMS | sha256sum --quiet -c && echo all-published-match
stat -c '%U:%G %a %n' /srv/repo/raw/tar/* /srv/repo/gpg-keys/*
```

預期：`all-published-match`；所有檔案 `repoadmin:repoadmin 644`。

**對應 cpctl**：`cpctl repo import` → `repo::import()`、`repo::_dest()`、`repo::_as_owner()`；摘要訊息 `import summary: <N> new, <M> already published`。

**注意事項／陷阱**：
- **同名不同 sha256 一律拒絕**（`refusing to overwrite published file with different content: <rel>`）。要更新內容必須換檔名（換版本）；opmenu 以內容雜湊命名正是為此。
- 一定要先跑完預檢迴圈、確定沒有任何 `CONFLICT:` 才發佈,否則清單後段的衝突會讓前段的新檔已經發佈、repodata 卻還沒重建。cpctl 也是先整批檢查、有任何衝突就全部不發佈(2026-10-16 修正;舊版是逐檔邊查邊發佈)。
- 不會刪除任何已發佈檔；舊版（如 CP 8.2.4、舊 opmenu）會一直保留，清理需另立變更。
- cpctl 本身以 umask 027 執行，所以一定要經 `repoadmin` + `umask 022` 寫入，否則 httpd 讀不到（403）。

## 2.12 內網匯入第 3 步：建立 / 更新 repodata（createrepo_c）

**目的**：讓 dnf 能把 `/srv/repo/rpm/<repo>` 當 yum repo 使用。只重建本次有新增 RPM 的目錄，或尚無 `repodata/repomd.xml` 的目錄。

**在哪台／帳號**：ops01，`cpadmin` → `sudo -u repoadmin`。

**手動指令**：

```bash
sudo -n -u repoadmin bash -c 'umask 022; exec createrepo_c -q --update "$1"' _ /srv/repo/rpm/confluent
sudo -n -u repoadmin bash -c 'umask 022; exec createrepo_c -q --update "$1"' _ /srv/repo/rpm/adoptium
sudo -n -u repoadmin bash -c 'umask 022; exec createrepo_c -q --update "$1"' _ /srv/repo/rpm/os-deps
```

**驗證**：

```bash
ls /srv/repo/rpm/*/repodata/repomd.xml
zcat /srv/repo/rpm/confluent/repodata/*-primary.xml.gz | grep -c '<package '
```

預期：三個 `repomd.xml` 都存在；confluent 的 package 數 = `ls /srv/repo/rpm/confluent/*.rpm | wc -l`（目前 21）。

**對應 cpctl**：`repo::import()` 中段（訊息 `repodata rebuilt: rpm/<repo>` 或 `repodata current: rpm/<repo>`）。

**注意事項／陷阱**：
- 重跑 createrepo_c 永遠安全（`--update` 只處理變動），人工時三個都跑也無妨。
- 若 `repodata/` 舊檔是 root 建立的，repoadmin 會無法更新 → 先 `chown -R repoadmin:repoadmin /srv/repo`。
- 目標主機的 dnf metadata 有快取，新增套件後節點端可能需 `dnf clean metadata --disablerepo='*' --enablerepo='cp-internal-*'`。

## 2.13 內網匯入第 4 步：留存稽核副本

**目的**：每次有新檔發佈時，把當次的 SHA256SUMS、manifest、驗證報告原樣留存在 repo，形成可追溯的引進紀錄。

**在哪台／帳號**：ops01，`cpadmin` → `sudo -u repoadmin`。只在本次「新增檔案數 > 0」時執行。

**手動指令**：

```bash
ts=$(date +%Y%m%d-%H%M%S)
sudo -n -u repoadmin bash -c 'umask 022; exec install -d -m 0755 "$1"' _ /srv/repo/manifests/$ts
for m in SHA256SUMS manifest-rpm.json manifest-tar.json; do [ -f /mnt/exchange/$m ] && sudo -n -u repoadmin bash -c 'umask 022; exec install -m 0644 "$1" "$2"' _ /mnt/exchange/$m /srv/repo/manifests/$ts/$m; done
sudo -n -u repoadmin bash -c 'umask 022; exec cp -r "$1" "$2"' _ /mnt/exchange/report /srv/repo/manifests/$ts/
```

**驗證**：

```bash
ls /srv/repo/manifests/ | tail -1
ls -R /srv/repo/manifests/$ts
```

預期：`SHA256SUMS  manifest-rpm.json  manifest-tar.json  report/verify-*.txt`。

**對應 cpctl**：`repo::import()` 結尾（訊息 `audit copy: /srv/repo/manifests/<ts>`）。

**注意事項／陷阱**：沒有新檔（全部 already published）時 cpctl 不建立稽核目錄；`--check` 模式也不建立。

## 2.14 驗證內部 repo 有在服務 / 列出已發佈內容

**目的**：確認三個 yum repo 都能經 HTTP 取得 metadata，並列出目前發佈了哪些套件與原始檔，作為安裝前的閘門。

**在哪台／帳號**：ops01（或任一能連 ops01:8080 的節點），`cpadmin`。

**手動指令**（= `cpctl repo verify`）：

```bash
for r in confluent adoptium os-deps; do curl -fsS -o /dev/null http://ops01.poc.lab:8080/rpm/$r/repodata/repomd.xml && echo "repo $r served at http://ops01.poc.lab:8080/rpm/$r" || echo "repo $r NOT served"; done
curl -s -o /dev/null -w '%{http_code} %{size_download}\n' http://ops01.poc.lab:8080/raw/tools/jmx_prometheus_javaagent-1.0.1.jar
```

（= `cpctl repo list`）：

```bash
for r in /srv/repo/rpm/*/; do echo "== $(basename "$r")"; find "$r" -maxdepth 1 -name '*.rpm' -printf '   %f\n' | sort -V; done
echo "== raw"; find /srv/repo/raw -type f -printf '   %P\n'
```

**驗證**：預期

```
repo confluent served at http://ops01.poc.lab:8080/rpm/confluent
repo adoptium served at http://ops01.poc.lab:8080/rpm/adoptium
repo os-deps served at http://ops01.poc.lab:8080/rpm/os-deps
200 2886599
```

`list` 會列出 `== confluent / == adoptium / == os-deps / == raw` 四段，raw 段含 `tar/confluent-8.3.2.tar.gz`、`tools/opmenu-20261016.f03b18c0.tar.gz` 等。

**對應 cpctl**：`cpctl repo verify` → `repo::verify()`；`cpctl repo list` → `repo::list()`。`cpctl install` 開頭也會先跑 `repo::verify`。

**注意事項／陷阱**：
- `repo verify` 只檢查三個 RPM repo 的 `repomd.xml`，**不檢查** raw 的 tar/jar/opmenu；這些在對應步驟（tar 安裝、JMX exporter、11_opmenu）才會以 `... not in the internal repo` 失敗。手動時請一併確認：`raw/tar/confluent-8.3.2.tar.gz`（tar 策略）、`raw/tools/jmx_prometheus_javaagent-1.0.1.jar`、`raw/tools/opmenu-$OPMENU_VERSION.tar.gz` 存在。
- 節點端使用此 repo 的 `/etc/yum.repos.d/cp-internal.repo`（`[cp-internal-confluent]`、`[cp-internal-adoptium]`、`[cp-internal-os-deps]`，`gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-<key>`）由後續步驟（`install::prepare`，01/02 步）佈署，不在本章範圍。

# 3. 安裝前準備、OS 基線、套件與憑證(步驟 00–03)

## 3.0 共通前提

### 3.0.1 主機與角色（`conf/inventory.env`）

| 角色 | 主機 | 01 OS 基線 | 02 套件 | 03 CA 信任 |
|---|---|---|---|---|
| ops（操作機 + 內部 repo + NTP server + PKI） | ops01 | 是 | 是（先做） | 是 |
| controller | kc01 kc02 kc04 | 是 | 是 | 是 |
| controller_spare | kc03 | 否（cpctl 不處理，但 SAN 有列入） | 否 | 否 |
| broker | kb01 kb02 kb03 kb04 | 是 | 是 | 是 |
| rest | rest01 rest02 | 是 | 是 | 是 |
| c3 | c3-01 | 是 | 是 | 是 |
| jump（堡壘機 / OP menu） | jump01 | 是 | 是 | 是 |
| lb / ad | lb01 / ad01 | 否 | 否 | 否（但 cp-server 憑證 SAN 有列入） |

FQDN = `<host>.poc.lab`。

### 3.0.2 帳號

| 帳號 | 在哪裡 | 用途 | 誰建立 |
|---|---|---|---|
| `cpadmin` | 所有主機 | 安裝帳號：ops01 上執行 cpctl / PKI；以 SSH 金鑰（ed25519）登入各節點後 `sudo` 執行。 | 前置（PoC：Docker image `useradd -m -s /bin/bash cpadmin`；正式環境：銀行帳號開通流程） |
| `cp-kafka`（群組 `confluent`） | controller / broker | Kafka 服務帳號（nologin） | RPM scriptlet（rpm 策略）或手動 `useradd`（tar 策略） |
| `cp-kafka-rest`（群組 `confluent`） | rest（RPM 依賴也會帶到 broker） | REST Proxy 服務帳號 | 同上 |
| `cp-control-center`（群組 `confluent`） | c3 | C3 服務帳號 | 同上 |

cpctl 的遠端執行方式是 `ssh cpadmin@<host> sudo bash -s`（把冪等函式 pipe 進 root bash）。手動操作等價於：**以 cpadmin SSH 登入目標主機，所有寫入系統目錄的動作前面加 `sudo`**。下面的指令皆以此為準；PKI（3.4）則在 ops01 以 cpadmin 身分**不加 sudo** 執行。

### 3.0.3 cpadmin 前置（cpctl 不做，必須先完成）

```bash
# 每台主機（root）
useradd -m -s /bin/bash cpadmin
install -d -m 0755 /etc/ssh/authorized_keys.d
# ops01 上產生金鑰（cpadmin）
sudo -u cpadmin ssh-keygen -q -t ed25519 -N '' -C "cpadmin@ops01" -f /home/cpadmin/.ssh/id_ed25519
# 公鑰放到每台節點的 /etc/ssh/authorized_keys.d/cpadmin（0644）
```

`/etc/ssh/sshd_config.d/10-cp.conf`（PoC 節點）：

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u
UseDNS no
```

sudoers：
- PoC（`/etc/sudoers.d/cpadmin`，0440）：
  ```
  cpadmin ALL=(ALL) NOPASSWD: ALL
  Defaults:cpadmin !requiretty
  ```
- 正式環境：**受限 sudo**（`SUDO_MODE=restricted`）。cpadmin 唯一能以 root 執行的程式是 cpctl 的 node agent `/usr/local/libexec/cpctl/cpnode`，而且**不能帶參數**：
  - 要做的動作從 stdin 傳入，以 NUL 分隔：函式名稱與參數。所以 sudo 的紀錄裡不會出現密碼。
  - agent 只執行它內建、有命名空間的函式（例如 `ensure::file`、`sys_node::nginx_reload`），不接受任何 shell 片段。
  - 會寫入或刪除的路徑，要符合 `/etc/cpctl/cpnode.conf` 的允許清單（來源 `installer/conf/cpnode.paths`）。
  - 不會設 setuid / setgid。
  - 要安裝的檔案必須是 cpadmin 自己放在 `/tmp/cpctl.*` 的檔案。
  - sudoers drop-in 只能給 OP menu 的固定帳號。cpadmin 改不了自己的 sudoers。
  - 每次呼叫都記在 `/var/log/cpnode.log`（密碼遮蔽）。
  ```
  # /etc/sudoers.d/cpadmin（root:root 0440）
  Defaults:cpadmin !requiretty
  Defaults:cpadmin logfile=/var/log/sudo-cpadmin.log
  cpadmin ALL=(root) NOPASSWD: /usr/local/libexec/cpctl/cpnode ""
  ```
  手動建立（由擁有完整 sudo 的管理員，在每台主機上做一次；agent 檔由 ops01 `cpctl agent build` 產生，或 `cat installer/lib/node/*.sh installer/lib/install/*.node.sh installer/node/cpnode.main` 再加上版本標頭）：
  ```bash
  sudo install -d -o root -g root -m 0755 /usr/local/libexec/cpctl /etc/cpctl
  sudo install -o root -g root -m 0755 /tmp/cpnode /usr/local/libexec/cpctl/cpnode
  sudo install -o root -g root -m 0644 /tmp/cpnode.conf /etc/cpctl/cpnode.conf      # 允許清單、OP menu 帳號、測試函式開關
  sudo visudo -cf /tmp/cpadmin.sudoers && sudo install -o root -g root -m 0440 /tmp/cpadmin.sudoers /etc/sudoers.d/cpadmin
  ```
  **驗證**：
  ```bash
  sudo -n -l                                         # 只列出 /usr/local/libexec/cpctl/cpnode ""
  sudo -n id                                         # 拒絕（a password is required / not allowed）
  printf '%s\0' 0 0 --version | sudo -n /usr/local/libexec/cpctl/cpnode            # agent 版本
  printf '%s\0' 0 0 ensure::absent /etc/hosts | sudo -n /usr/local/libexec/cpctl/cpnode   # DENIED path not allowed
  sudo tail -3 /var/log/cpnode.log                   # （管理員）每次呼叫一行：誰、哪個函式、參數
  ```
  **對應 cpctl**：`cpctl agent install --restrict`（最後一次用完整 sudo 安裝 agent、政策檔與上面的 sudoers），之後 `conf/inventory.env` 設 `SUDO_MODE=restricted`；`cpctl agent status` 查每台的 agent 版本與 sudo 模式。
  **實測**：cp-man 手動（kb03，附錄 A.6）與 cp-poc 全叢集（cpctl，附錄 A.5：受限後完整安裝 changed=0、無拒絕）。

  > 注意：受限之後 cpadmin **不能自己更新 agent**。cpctl 改版時如果節點端程式碼有變，cpctl 會比對版本並停下，提示由管理員安裝新的 agent（PoC：`windows/poc.sh agent-push`）。這正是受限的目的：root 執行的程式只能經過管理員審核後更換。

  > 注意：安裝程式要管理 systemd unit、套件與設定檔，**本質上仍然接近 root 權限**。例如 systemd drop-in 可以讓服務以 root 執行指令。受限 sudo 能做到的是：
  > - 沒有互動式 root shell、沒有任意指令。
  > - root 只執行固定、有版本的程式碼。
  > - 每個動作都有紀錄。
  > - 明顯的提權路徑（改自己的 sudoers、setuid、讀任意檔案）被擋下。
  >
  > 建議再搭配銀行的帳號管理：cpadmin 平時停用，變更窗口才啟用。

驗證：
```bash
ssh cpadmin@kb01.poc.lab 'sudo -n true && echo SUDO_OK'      # → SUDO_OK
```

### 3.0.4 sudo 與 glob 的陷阱（通用）

- `sudo rm -rf /dir/*` 的 `*` 是由**呼叫者（cpadmin）的 shell** 展開；cpadmin 讀不到 0750/0700 目錄時展開失敗 → 變成刪除字面上叫 `*` 的檔案（什麼也沒刪）。請改用 root 展開：
  `sudo find /dir -mindepth 1 -delete` 或 `sudo bash -c 'rm -rf /dir/*'`。
- 最小化 OS image 可能沒有 `/etc/sysctl.d`、`/etc/systemd/journald.conf.d`：寫檔前先 `sudo install -d -m 0755 <dir>`。
- 最小化 OS 沒有 `diffutils`（沒有 `diff`/`cmp`），比對檔案請用 `sha256sum`。
- 同樣的道理也適用於「列出」:`sudo stat /etc/confluent/kafka/*` 在 cpadmin 讀不到該目錄時什麼都不會印。要看權限請用 `sudo find <dir> -maxdepth 1 -printf '%u:%g %m %p\n'`。
- **操作機本身也是安裝對象時**,不要把要派送的檔案暫存在 `/tmp/<同名>`:對操作機自己執行的那一輪若有 `rm -f /tmp/<檔名>`,就會刪掉還要派送給其他主機的原始檔(全程實測時就因此讓 11 台主機沒拿到 repo 設定)。暫存檔放在 `/var/lib/cp-installer/` 底下。
- `$?` 要在下一個指令之前取用:`echo "$(hostname) rc=$?"` 印出的是 `hostname` 的結果,不是前一個指令的。先 `rc=$?` 再印。

### 3.0.5 密碼檔(ops01,cpadmin)

**目的**:所有密碼集中在操作機上一個 0600 的檔案,後面的步驟一律從這裡讀成環境變數,不在指令列輸入、不出現在 history。正式環境可改由 vault 提供,讀取方式相同。

**手動指令**(AD 管理者密碼由 AD 團隊提供;其他值隨機產生):

```bash
cd /var/lib/cp-installer && umask 077
install -m 0600 /dev/null secrets.env
printf 'AD_ADMIN_PASSWORD=%s\n' '<由 AD 團隊提供>' >> secrets.env        # 只有 PoC 自建 AD 時需要
for k in LDAP_BIND_PASSWORD SVC_REST_PASSWORD SVC_C3_PASSWORD SVC_CPCTL_PASSWORD KAFKA_ADMIN_PASSWORD \
         STORE_PASSWORD HUMAN_DEFAULT_PASSWORD SECRET_MASTER_PASSPHRASE MDS_TOKEN_PASSPHRASE AUDIT_PASSWORD \
         JMX_EXPORTER_PASSWORD OPMENU_TRUSTSTORE_PASSWORD OPMENU_BREAKGLASS_STORE_PASSWORD \
         APP_APP_ORDERS_PASSWORD APP_APP_PAYMENTS_PASSWORD APP_APP_LEGACY_BILLING_PASSWORD; do
  grep -q "^$k=" secrets.env || printf '%s=%sAa1-\n' "$k" "$(openssl rand -hex 12)" >> secrets.env
done
```

之後每個步驟需要密碼時:`set -a; . /var/lib/cp-installer/secrets.env; set +a`。

**驗證**:`stat -c '%U:%G %a' secrets.env` → `cpadmin:cpadmin 600`;`sed 's/=.*/=<password>/' secrets.env` 列出 17 個名稱(只看名稱,不印值)。

**對應 cpctl**:`windows/poc.sh secrets`(產生 `installer/conf/secrets.env`)。

## 3.1 步驟 00:安裝前預檢(00_precheck)

**目的**：在動任何主機之前確認：inventory 結構正確、所有密碼都有填、每台主機 SSH/sudo 可用、OS 與 /tmp 條件、時鐘誤差、DNS 互相解析，以及內部 repo 可用。此步驟**不修改任何東西**。

**在哪台／帳號**：ops01，`cpadmin`（以 `cpadmin` 的 SSH 金鑰登入各主機，遠端再 `sudo -n` 取 facts）。

檢查對象（`inv::all_hosts`，順序 ops→ad→lb→controller→broker→rest→c3）：`ops01 ad01 lb01 kc01 kc02 kc04 kb01 kb02 kb03 kb04 rest01 rest02 c3-01`。`kc03`（controller_spare）只參與 node id 重複檢查；`jump01` 不在此清單。

### 3.1.1 操作機必要指令

```bash
for c in ssh scp openssl curl sha256sum envsubst flock; do command -v "$c" >/dev/null || echo "MISSING $c"; done
```

預期：無輸出。（cpctl：`core::require_cmd`）

### 3.1.2 Inventory 結構

```bash
cd /opt/cp-installer/conf
grep -E '^HOST_(kc0[1-4]|kb0[1-4])_NODE_ID=' inventory.env | cut -d= -f2 | sort | uniq -d
grep '^HOSTS_controller=' inventory.env
grep '^HOSTS_broker=' inventory.env
```

預期：第一行無輸出（node id 1,2,3,4,101,102,103,104 不重複）；controller `kc01 kc02 kc04` = 3 台（須 ≥3 且為奇數）；broker `kb01 kb02 kb03 kb04` = 4 台（須 ≥3，對應 RF=3 / min.insync=2）。

cpctl 成功訊息：`inventory: 3 controllers, 4 brokers, 2 REST, 1 C3`。

### 3.1.3 密碼存在性（不印出值）

```bash
cd /opt/cp-installer/conf
for s in AD_ADMIN_PASSWORD LDAP_BIND_PASSWORD SVC_REST_PASSWORD SVC_C3_PASSWORD SVC_CPCTL_PASSWORD KAFKA_ADMIN_PASSWORD STORE_PASSWORD SECRET_MASTER_PASSPHRASE MDS_TOKEN_PASSPHRASE APP_APP_ORDERS_PASSWORD APP_APP_PAYMENTS_PASSWORD; do grep -q "^$s=." secrets.env && echo "$s ok" || echo "$s MISSING"; done
```

預期：每行皆 `ok`。App 密碼只檢查 `APP_CHANNEL_*=scram` 的 app（`app-orders`、`app-payments`；`app-legacy-billing` 走 REST，不檢查），變數名規則 `APP_<app 大寫、- 改 _>_PASSWORD`。cpctl 訊息：`secrets present for all service accounts and apps`；缺少時 `secret <NAME> is not set in conf/secrets.env`。

### 3.1.4 每台主機：SSH、sudo、OS facts、/tmp、時鐘

以 kb01 為例，對清單中每台重複：

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 cpadmin@kb01.poc.lab true && echo ssh-ok
ssh -o BatchMode=yes cpadmin@kb01.poc.lab 'sudo -n true && echo sudo-ok'
ssh -o BatchMode=yes cpadmin@kb01.poc.lab '. /etc/os-release; echo os=$ID-$VERSION_ID'
ssh -o BatchMode=yes cpadmin@kb01.poc.lab 'findmnt -no OPTIONS /tmp'
ssh -o BatchMode=yes cpadmin@kb01.poc.lab 'df -Pm /tmp | tail -1'
echo "skew=$(( $(ssh -o BatchMode=yes cpadmin@kb01.poc.lab date +%s) - $(date +%s) ))"
ssh -o BatchMode=yes cpadmin@kb01.poc.lab 'nproc; free -m | head -2; systemctl is-system-running'
```

一次全部主機（只看 SSH 與 OS）：

```bash
for h in ops01 ad01 lb01 kc01 kc02 kc04 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do printf '%-8s ' $h; ssh -o BatchMode=yes -o ConnectTimeout=8 cpadmin@$h.poc.lab 'sudo -n true && . /etc/os-release && echo $ID-$VERSION_ID' || echo FAIL; done
```

**判定標準**（`precheck::host`）：

| 項目 | 合格 | 不合格時 |
|---|---|---|
| SSH（BatchMode，金鑰） | 成功 | ERROR `SSH as cpadmin failed`，該主機失敗 |
| `sudo -n` 收集 facts | 成功 | ERROR `cannot collect facts (sudo?)`，該主機失敗 |
| lb01 / ad01 | 只要能連線即 OK（appliance，PoC 為 debian-13 / debian-12） | — |
| OS | `rhel/rocky/almalinux/ol-9*`（PoC：`rocky-9.8`） | WARN |
| /tmp 掛載選項 | **不含** `noexec` | ERROR（Confluent 需要 exec） |
| /tmp 可用空間 | ≥ 2000 MB | WARN |
| 時鐘誤差 | ≤ 2 秒（TLS/MDS token） | ERROR |
| DNS | 能 `getent hosts` 全部 13 台 FQDN | ERROR，該主機失敗 |

### 3.1.5 DNS 互相解析

```bash
for h in ops01 ad01 lb01 kc01 kc02 kc04 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh -o BatchMode=yes cpadmin@kb01.poc.lab "getent hosts $h.poc.lab >/dev/null" || echo "kb01 cannot resolve $h.poc.lab"; done
```

預期：無輸出（對每台來源主機都要跑一次）。例：`getent hosts kc01.poc.lab` → `172.30.0.21     kc01.poc.lab`。

### 3.1.6 內部 repo

同 2.14 的 `repo verify` 指令；三個 repo 都要 `served`。不合格時 cpctl 訊息：`internal repo not ready - run: cpctl repo import`。

**對應 cpctl**：`cpctl step 00_precheck`（或 `cpctl install` 的第一步）；函式 `precheck::inventory`、`precheck::host`、`step_apply`、`step_verify`（= `repo::verify`）。遠端 facts 由 `node::facts`（`lib/node/ensure.sh`）以 `ssh cpadmin@<fqdn> "sudo -n -u root bash -s"` 送入執行。

**注意事項／陷阱**：
- /tmp noexec 與時鐘誤差都是**阻擋項目**:有任何一台不合格就不要往下做。cpctl 會讓該主機預檢失敗(2026-10-16 修正;舊版只記 ERROR、步驟仍可能通過)。
- 步驟戳記（stamp）：`/var/lib/cp-installer/stamps/00_precheck` = 步驟檔 + `inventory.env` + `apps.env` + 所有 lib/roles 程式碼的雜湊。內容未變且 repo verify 通過時，再跑 cpctl 會顯示 `skipped`；**主機狀態變了（例如時鐘飄移）cpctl 不會重檢**，需 `cpctl --force step 00_precheck`。手動流程每次都完整執行即可。
- 第一次 SSH 使用 `StrictHostKeyChecking=accept-new`，會自動信任新主機金鑰；正式環境建議事先佈署 `known_hosts`。
- 時鐘誤差是以「ops01 時間」為基準，ops01 本身時鐘錯誤時全部主機都會被判失敗。
- 失敗退出碼為 3（`E_PRECHECK`）。

## 3.2 步驟 01:OS 基線（`01_os_baseline.sh`）

對 ops、controller、broker、rest、c3、jump 每台主機依序執行 3.2.1–3.2.11(3.2.7 會用到內部 repo,所以先做 3.3.1.1–3.3.1.2 的 repo 設定與 GPG 金鑰)。ops01 要最先做,因為它是其他主機的 NTP server;時間同步在 3.2.9 最後的驗證確認。

### 3.2.1 核心參數（sysctl）

- **目的**：提高連線佇列（所有主機）、Kafka 需要大量 mmap（controller/broker）、broker 低 swap 與較大 socket buffer、髒頁回寫調整。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **依角色的參數**（`conf/os-tuning.env`）：

| 角色 | 參數 |
|---|---|
| 全部 | `net.core.somaxconn=4096`、`net.ipv4.tcp_max_syn_backlog=4096` |
| controller + broker | `vm.max_map_count=262144` |
| broker | `vm.swappiness=1`、`vm.dirty_background_ratio=5`、`vm.dirty_ratio=60`、`net.core.rmem_max=2097152`、`net.core.wmem_max=2097152`、`net.ipv4.tcp_rmem=4096 65536 2097152`、`net.ipv4.tcp_wmem=4096 65536 2097152` |

- **設定檔** `/etc/sysctl.d/90-confluent.conf`（root:root 0644）。

  broker（實機應有的完整內容）：
  ```
  vm.max_map_count = 262144
  vm.swappiness = 1
  vm.dirty_background_ratio = 5
  vm.dirty_ratio = 60
  net.core.rmem_max = 2097152
  net.core.wmem_max = 2097152
  net.ipv4.tcp_rmem = 4096 65536 2097152
  net.ipv4.tcp_wmem = 4096 65536 2097152
  net.core.somaxconn = 4096
  net.ipv4.tcp_max_syn_backlog = 4096
  ```
  controller：
  ```
  vm.max_map_count = 262144
  net.core.somaxconn = 4096
  net.ipv4.tcp_max_syn_backlog = 4096
  ```
  ops / rest / c3 / jump：
  ```
  net.core.somaxconn = 4096
  net.ipv4.tcp_max_syn_backlog = 4096
  ```
- **手動指令**（以 broker 為例；其他角色只放對應行）：
  ```bash
  sudo install -d -m 0755 /etc/sysctl.d          # 最小化 image 沒有這個目錄
  sudo tee /etc/sysctl.d/90-confluent.conf >/dev/null <<'EOF'
  vm.max_map_count = 262144
  vm.swappiness = 1
  vm.dirty_background_ratio = 5
  vm.dirty_ratio = 60
  net.core.rmem_max = 2097152
  net.core.wmem_max = 2097152
  net.ipv4.tcp_rmem = 4096 65536 2097152
  net.ipv4.tcp_wmem = 4096 65536 2097152
  net.core.somaxconn = 4096
  net.ipv4.tcp_max_syn_backlog = 4096
  EOF
  sudo chmod 0644 /etc/sysctl.d/90-confluent.conf
  sudo sysctl -p /etc/sysctl.d/90-confluent.conf
  ```
- **驗證**：
  ```bash
  sysctl vm.max_map_count vm.swappiness net.core.somaxconn net.ipv4.tcp_rmem
  # 期望（broker 實機）：
  # vm.max_map_count = 262144
  # vm.swappiness = 1
  # net.core.somaxconn = 4096
  # net.ipv4.tcp_rmem = 4096	65536	2097152
  ```
- **對應 cpctl**：`os::baseline_host` → `ensure::sysctl`（每個 key 一次：先刪同名行再 append，然後 `sysctl -w`）。
- **注意事項**：
  - 【僅實機】`vm.*`、`kernel.*` 在容器內不可設定（屬於 host kernel），cpctl 只檢查、**不寫入檔案**，所以 PoC 容器的 `90-confluent.conf` 裡沒有 `vm.*` 行；kb01 目前 `vm.swappiness = 60`（WSL2 host 值，cpctl 回報 warn）。`vm.max_map_count=262144` 在 PoC 是靠 WSL2 host 設好的。
  - 部分 `net.core.*`（rmem_max/wmem_max）在容器內是唯讀的。**`sysctl -w` 與 `sysctl -p` 設定失敗時結束碼仍是 0**,只在畫面印出 `setting key ...: No such file or directory`,所以不能用結束碼判斷。正確做法是設定後讀回比對:`sudo sysctl -q -w "$k=$v"; [ "$(sysctl -n $k | tr -s '\t ' '  ')" = "$v" ]`,不一致的參數不要寫進檔案(全程實測時 broker 的這兩項就是如此)。
  - `tcp_rmem` 的值用空白分隔；conf 檔中寫成 `4096,65536,2097152` 是 cpctl 內部表示法，手動時不要用逗號。
  - cpctl 寫入順序依 append 而定，檔案內行序可能與上表不同，不影響結果。

### 3.2.2 行程限制（limits）

- **目的**：Kafka 需要大量 file descriptor（每個 segment / socket 一個）。systemd 單元另由 step 05 的 drop-in 設 `LimitNOFILE`，這裡是給以 `confluent` 群組身分互動執行工具時用。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **設定檔** `/etc/security/limits.d/90-confluent.conf`（root:root 0644）：
  ```
  # Managed by cpctl
  @confluent soft nofile 128000
  @confluent hard nofile 128000
  @confluent soft nproc 65536
  @confluent hard nproc 65536
  ```
- **手動指令**：
  ```bash
  sudo tee /etc/security/limits.d/90-confluent.conf >/dev/null <<'EOF'
  # Managed by cpctl
  @confluent soft nofile 128000
  @confluent hard nofile 128000
  @confluent soft nproc 65536
  @confluent hard nproc 65536
  EOF
  sudo chmod 0644 /etc/security/limits.d/90-confluent.conf
  ```
- **驗證**：`cat /etc/security/limits.d/90-confluent.conf`；服務啟動後 `cat /proc/$(pgrep -f kafka.Kafka)/limits | grep 'open files'`。
- **對應 cpctl**：`os::baseline_host`（`remote::put` → `ensure::file`）。
- **注意事項**：pam_limits 不作用於 systemd 服務；服務的上限以 unit / drop-in 的 `LimitNOFILE` 為準。`confluent` 群組要到 step 02 才存在，limits 檔先放無妨。

### 3.2.3 journald 容量

- **目的**：限制 journal 佔用（預設可吃到檔案系統 10%）。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **設定檔** `/etc/systemd/journald.conf.d/90-confluent.conf`（目錄 root:root 0755，檔案 0644）：
  ```
  # Managed by cpctl
  [Journal]
  SystemMaxUse=1G
  ```
- **手動指令**：
  ```bash
  sudo install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d
  sudo tee /etc/systemd/journald.conf.d/90-confluent.conf >/dev/null <<'EOF'
  # Managed by cpctl
  [Journal]
  SystemMaxUse=1G
  EOF
  sudo chmod 0644 /etc/systemd/journald.conf.d/90-confluent.conf
  sudo systemctl restart systemd-journald
  ```
- **驗證**：`systemd-analyze cat-config systemd/journald.conf | grep SystemMaxUse` → `SystemMaxUse=1G`；`journalctl --disk-usage`。
- **對應 cpctl**：`os::baseline_host`（`ensure::dir` + `ensure::file`）。
- **注意事項**：cpctl **沒有**重啟 journald（設定在下次 journald 重啟/開機才生效）；手動時建議如上補一次 restart。

### 3.2.4 時區

- **目的**：所有主機統一 Asia/Taipei，日誌與稽核時間一致。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **手動指令**：
  ```bash
  sudo ln -sfn /usr/share/zoneinfo/Asia/Taipei /etc/localtime
  # 實機也可用：sudo timedatectl set-timezone Asia/Taipei
  ```
- **驗證**：`ls -l /etc/localtime` → `/etc/localtime -> /usr/share/zoneinfo/Asia/Taipei`；`date` 顯示 `CST`。
- **對應 cpctl**：`ensure::symlink`。
- **注意事項**：容器內 `timedatectl` 通常無法使用，因此 cpctl 直接做 symlink。

### 3.2.5 滾動日誌保留（tmpfiles）

- **目的**：log4j2 只會滾動不會刪除；用 systemd-tmpfiles 每日清掉 14 天前的舊檔。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **設定檔** `/etc/tmpfiles.d/90-confluent-logs.conf`（root:root 0644）：
  ```
  # Managed by cpctl - delete rolled Confluent logs after 14 days (systemd-tmpfiles-clean.timer)
  e /var/log/kafka - - - 14d
  e /var/log/confluent - - - 14d
  ```
- **手動指令**：
  ```bash
  sudo tee /etc/tmpfiles.d/90-confluent-logs.conf >/dev/null <<'EOF'
  # Managed by cpctl - delete rolled Confluent logs after 14 days (systemd-tmpfiles-clean.timer)
  e /var/log/kafka - - - 14d
  e /var/log/confluent - - - 14d
  EOF
  sudo chmod 0644 /etc/tmpfiles.d/90-confluent-logs.conf
  sudo systemctl enable systemd-tmpfiles-clean.timer   # static unit，已由 timers.target 拉起時不需動作
  ```
- **驗證**：`systemctl is-enabled systemd-tmpfiles-clean.timer` → `static`（或 `enabled`）；`systemctl list-timers systemd-tmpfiles-clean.timer`；乾跑：`sudo systemd-tmpfiles --clean --dry-run /etc/tmpfiles.d/90-confluent-logs.conf`（舊版 systemd 無 `--dry-run` 就略過）。
- **對應 cpctl**：`os::baseline_host` + `svc::enable systemd-tmpfiles-clean.timer`。
- **注意事項**：`e` 型別只清**內容**、不建立目錄；目錄不存在時會被忽略。age 依 atime/mtime/ctime 最新者判斷，正在寫入的 `server.log` 不會被刪。

### 3.2.6 /etc/confluent

- **目的**：建立 Confluent 設定根目錄（step 05 放 properties、ssl）。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **手動指令**：`sudo install -d -o root -g root -m 0755 /etc/confluent`
- **驗證**：`stat -c '%U:%G:%a' /etc/confluent` → `root:root:755`
- **對應 cpctl**：`ensure::dir`。

### 3.2.7 OS 套件（chrony、firewalld）與內部 repo 定義

- **目的**：時間同步與主機防火牆套件，**只能**從內部 os-deps 鏡像安裝（不連 Internet）。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **前置**：repo 定義檔與 GPG 金鑰（內容與指令見 3.3.1，step 01 與 02 共用、冪等）。
- **手動指令**：
  ```bash
  rpm -q chrony firewalld || \
  sudo dnf -y -q --refresh --disablerepo='*' --enablerepo='cp-internal-os-deps' \
       --setopt=install_weak_deps=False install chrony firewalld
  ```
- **驗證**：`rpm -q chrony firewalld` → `chrony-4.8-1.el9.x86_64`、`firewalld-1.3.4-20.el9_8.noarch`（PoC 鏡像版本）。
- **對應 cpctl**：`install::prepare`、`os_node::pkgs $PKGS_OS_BASELINE`。

### 3.2.8 透明大頁（THP）關閉 —【僅實機】

- **目的**：Kafka 建議 THP=never，避免延遲尖峰與記憶體膨脹。
- **主機 / 帳號**：controller、broker；cpadmin + sudo。
- **設定檔** `/etc/systemd/system/disable-thp.service`（root:root 0644）：
  ```
  # Managed by cpctl - Kafka recommends transparent hugepages = never
  [Unit]
  Description=Disable transparent hugepages (Confluent Platform)
  DefaultDependencies=no
  After=sysinit.target local-fs.target
  Before=confluent-server.service
  ConditionVirtualization=!container

  [Service]
  Type=oneshot
  ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag'

  [Install]
  WantedBy=basic.target
  ```
- **手動指令**：
  ```bash
  sudo tee /etc/systemd/system/disable-thp.service >/dev/null <<'EOF'
  （上方內容）
  EOF
  sudo chmod 0644 /etc/systemd/system/disable-thp.service
  sudo systemctl daemon-reload
  sudo systemctl enable disable-thp.service
  sudo systemctl start disable-thp.service     # 實機立即生效；cpctl 只 enable，靠下次開機生效
  ```
- **驗證**：
  ```bash
  cat /sys/kernel/mm/transparent_hugepage/enabled   # 實機期望：always madvise [never]
  cat /sys/kernel/mm/transparent_hugepage/defrag    # 實機期望：... [never]
  systemctl is-enabled disable-thp.service          # enabled
  ```
  容器內會看到 `always [madvise] never`，且 `systemctl status disable-thp` 顯示 `ConditionVirtualization=!container was not met`（正常，cpctl 標 skipped）。
- **對應 cpctl**：`os::services_host`、`svc::daemon_reload`、`svc::enable`、`os_node::thp_report`。
- **注意事項**：cpctl 不 `start` 這個單元；若 thp_report 顯示 warn，手動 `systemctl start disable-thp` 或重開機。RHEL 也可改用 `grubby --update-kernel=ALL --args=transparent_hugepage=never`（需重開機）；兩者擇一即可。

### 3.2.9 時間同步（chrony）

- **目的**：Kafka / Kerberos / TLS / 稽核都依賴時間一致。PoC：ops01 對 172.30.0.0/24 提供時間（local stratum 10）；其餘主機跟 ops01。正式環境改指銀行 NTP。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **設定檔** `/etc/chrony.conf`（root:root 0644）：

  ops01（NTP server，自己在 `NTP_SERVERS` 名單中，所以不寫 `server` 行）：
  ```
  # Managed by cpctl
  driftfile /var/lib/chrony/drift
  makestep 1.0 3
  rtcsync
  logdir /var/log/chrony
  allow 172.30.0.0/24
  local stratum 10
  ```
  其他所有主機：
  ```
  # Managed by cpctl
  server ops01.poc.lab iburst
  driftfile /var/lib/chrony/drift
  makestep 1.0 3
  rtcsync
  logdir /var/log/chrony
  ```
  `/etc/sysconfig/chronyd`（root:root 0644）：
  - 容器（PoC）：`OPTIONS="-F 2 -x"`（`-x` = 只追蹤不調整系統時鐘，容器共用 host 時鐘）
  - 實機：`OPTIONS="-F 2"`
- **手動指令**（以非 ops 主機、實機為例）：
  ```bash
  sudo tee /etc/chrony.conf >/dev/null <<'EOF'
  # Managed by cpctl
  server ops01.poc.lab iburst
  driftfile /var/lib/chrony/drift
  makestep 1.0 3
  rtcsync
  logdir /var/log/chrony
  EOF
  # 判斷是否容器：test -f /.dockerenv || systemd-detect-virt -c -q
  echo 'OPTIONS="-F 2"' | sudo tee /etc/sysconfig/chronyd >/dev/null      # 容器改成 "-F 2 -x"
  sudo chmod 0644 /etc/chrony.conf /etc/sysconfig/chronyd
  sudo systemctl enable chronyd
  sudo systemctl restart chronyd
  ```
- **驗證**（等幾秒讓 chrony 選到來源）：
  ```bash
  chronyc -n sources
  # 期望（kb01）：^* 172.30.0.10   10   6   377 ...   （^* = 已選定的來源）
  chronyc tracking | grep 'System time'
  ```
  ops01：`chronyc -n sources` 沒有來源是正常的（只服務本機時鐘）。
- **對應 cpctl**：`os::services_host`（chrony 段）、`svc::enable`/`svc::restart`；第二輪 `os::time_report` → `os_node::chrony_sync`。
- **注意事項**：ops01 必須先完成（它是 server），且 ops01 防火牆要開 `123/udp`（3.2.10）。正式環境要把 `NTP_SERVERS` 換成銀行 NTP，ops01 也不再 `allow`/`local stratum`。

### 3.2.10 主機防火牆（firewalld）

- **目的**：預設區域只允許 ssh + 該主機角色需要的埠；關閉 Rocky/RHEL 預設開的 `cockpit`、`dhcpv6-client`。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **各角色埠**（由 `inventory.env` 的 PORT_* 推導 + `FIREWALL_EXTRA_*`）：

| 主機 | 開放（tcp 除非註明） |
|---|---|
| ops01 | 8443（內部 repo HTTPS）、123/udp（NTP server）、ssh |
| kc01 kc02 kc04 | 9093（CONTROLLER）、7071（JMX exporter）、ssh |
| kb01–kb04 | 9092（INTERNAL）、9094（TOKEN）、9095（CLIENT）、9096（LDAP）、8090（MDS）、7071、ssh |
| rest01 rest02 | 8082、7071、ssh |
| c3-01 | 9021（C3）、9090（Prometheus）、ssh |
| jump01 | 只有 ssh |

- **手動指令**（以 broker 為例）：
  ```bash
  sudo systemctl enable --now firewalld
  for p in 7071/tcp 8090/tcp 9092/tcp 9094/tcp 9095/tcp 9096/tcp; do
    sudo firewall-cmd -q --permanent --add-port=$p
  done
  sudo firewall-cmd -q --permanent --add-service=ssh
  for s in cockpit dhcpv6-client; do
    sudo firewall-cmd --permanent --query-service=$s >/dev/null 2>&1 && sudo firewall-cmd -q --permanent --remove-service=$s
  done
  sudo firewall-cmd -q --reload
  ```
  其他角色把 `for p in ...` 換成上表的埠；ops01 為 `8443/tcp 123/udp`；jump01 不加埠。
- **驗證**：
  ```bash
  sudo firewall-cmd --permanent --list-all | grep -E ' services| ports'
  # kb01 期望：
  #   services: ssh
  #   ports: 7071/tcp 8090/tcp 9092/tcp 9094/tcp 9095/tcp 9096/tcp
  ```
- **對應 cpctl**：`os::fw_ports`、`os_node::firewall`。
- **注意事項**：
  - cpctl 只**加**不**刪**埠：多出來的埠只會 warn（`port X open but not managed by cpctl`），手動也請人工判斷。
  - 若銀行只用網路防火牆，可設 `FIREWALLD=off` 整段跳過。
  - 注意 controller 的 9093 與 C3 內嵌 Alertmanager 的 9093（`PORT_ALERTMANAGER`）同號，但在不同主機，cpctl 未在 c3 開 9093（Alertmanager 僅本機使用）。
  - 容器內 firewalld 能跑（PoC 已驗證）；若某環境啟不起來，cpctl 只 warn。

### 3.2.11 SELinux —【僅實機】

- **目的**：確認 enforcing，並對 Confluent 自訂路徑重新套用預設 context。
- **主機 / 帳號**：所有 01 主機；cpadmin + sudo。
- **手動指令**：
  ```bash
  getenforce                                          # 期望 Enforcing
  for p in /etc/confluent /var/lib/kafka /var/log/kafka /var/log/confluent /opt/confluent /opt/jmx-exporter; do
    [ -e "$p" ] || continue
    n=$(sudo restorecon -R -n -v "$p" | wc -l)
    [ "$n" -eq 0 ] || sudo restorecon -R "$p"
  done
  ```
- **驗證**：`getenforce` → `Enforcing`；`sudo restorecon -R -n -v /etc/confluent | wc -l` → `0`；`ls -Zd /etc/confluent`。
- **對應 cpctl**：`os_node::selinux enforcing <SELINUX_PATHS>`。
- **注意事項**：
  - 容器內沒有 `getenforce`（kb01：`getenforce: command not found`），cpctl 標 skipped。
  - cpctl **不會**切換模式（Permissive → Enforcing 需改 `/etc/selinux/config` + 重開機，屬變更管理）。
  - 這些路徑在 step 01 時多半還不存在（step 02/05 才建立）；**每次新增檔案（尤其 tar 解壓到 /opt/confluent、/opt/java）後都要再跑一次 restorecon**。cpctl 是每次重跑 01 時處理。`/opt/java` 不在 cpctl 的 `SELINUX_PATHS` 名單內;tar.gz 方式在實機上請一併對 `/opt/java` 執行 restorecon(容器內無法驗證)。

## 3.3 步驟 02:派送套件（`02_distribute.sh`）

- **目的**：從內部 repo 安裝**精確版本**的 JDK 與 Confluent 元件，並防止 OS patch 意外升級。
- **主機順序**：**ops01 先做**（step 03 的 keytool 需要 JDK），其餘主機（kc01 kc02 kc04、kb01–kb04、rest01–02、c3-01、jump01）可平行。
- **帳號**：cpadmin + sudo。
- **策略**：`conf/inventory.env` 的 `INSTALL_METHOD=rpm`（PoC 預設、銀行建議）或 `tar`。兩者擇一，不要混用。
- **內部 repo**（ops01 httpd，`/srv/repo` → `https://ops01.poc.lab:8443/`，3.3.0）：
  - `rpm/confluent/`（CP + C3 RPM）、`rpm/adoptium/`、`rpm/os-deps/`
  - `raw/tar/`（OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz、confluent-8.3.2.tar.gz、confluent-control-center-next-gen-2.6.1.tar.gz、以及升級演練用的 confluent-8.2.4.tar.gz）
  - `gpg-keys/`（confluent.asc、adoptium.asc、rocky-9.asc、confluent-c3.asc）
  - `manifests/<時間戳>/SHA256SUMS`

### 3.3.0 內部 repo 改走 HTTPS（在任何節點安裝之前）

- **目的**：節點從內部 repo 下載套件時走 HTTPS，伺服器身分由憑證證明，傳輸內容也加密。RPM 本身已有 GPG 簽章、tar.gz 有 sha256，但 **repo 的 metadata 沒有簽章**；改走 HTTPS 後，中間人無法把舊版、或藏掉某個版本的 metadata 塞給節點。
- **做法**：
  - repo 主機（ops01）用共用伺服器憑證 `cp-server` 提供 `https://ops01.poc.lab:8443/`；它的 SAN 本來就含 `ops01`、`ops01.poc.lab`（3.4.5）。
  - 節點的 repo 定義檔加上 `sslcacert`，只信任我們的信任 bundle。
  - 原本的 HTTP 8080 保留設定、但一律回 403，防火牆也不再開放 8080；舊設定的節點會立刻失敗，不會繼續用明文。
- **順序上的問題與解法**：
  - 節點要先信任憑證才能裝套件，憑證卻是 3.4 才簽。所以本節先把 3.4 的「簽發」部分提前做，這部分只用 openssl。
  - ops01 自己改讀磁碟上的 repo（`file://`），不經網路，所以它在 HTTPS 還沒好之前就能裝 JDK 與 mod_ssl。
- **前提**：`mod_ssl` 已經走第 2 章的離線引進進了 `rpm/os-deps`（`versions.env` 的 `PKGS_OPS_OS="mod_ssl"`）。
- **主機 / 帳號**：ops01，cpadmin + sudo。

**1) ops01 自己的 repo 定義改為讀磁碟**

```bash
sudo tee /etc/yum.repos.d/cp-internal.repo >/dev/null <<'EOF'
# Managed by cpctl - internal mirror only (public repos are not reachable from this network)
[cp-internal-confluent]
name=Internal mirror - Confluent Platform and Control Center
baseurl=file:///srv/repo/rpm/confluent
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-confluent

[cp-internal-adoptium]
name=Internal mirror - Eclipse Temurin
baseurl=file:///srv/repo/rpm/adoptium
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-adoptium

[cp-internal-os-deps]
name=Internal mirror - OS dependencies
baseurl=file:///srv/repo/rpm/os-deps
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
EOF
# GPG 金鑰同 3.3.1.2；ops01 的套件同 3.3.1.3，另加 mod_ssl（版本 = os-deps 裡的版本）
v=$(rpm -qp --qf '%{VERSION}' /srv/repo/rpm/os-deps/mod_ssl-[0-9]*.rpm | sort -V | tail -1)
sudo dnf -y -q --refresh --disablerepo='*' --enablerepo='cp-internal-*' install "mod_ssl-$v"
rpm -q mod_ssl httpd
```

**2) 簽發憑證（提前做 3.4 的簽發部分）**

- 內部 CA：照 3.4.1（CA 與 `ca.pem`）、3.4.3–3.4.6 簽出 `cp-server` 等憑證。3.4.2 的 truststore 需要 keytool，留到 3.4 再做。
- 銀行 CA：照 3.4.9.1–3.4.9.3 取得 root、送出申請、匯入銀行簽回的 `cp-server`。**沒有拿到 cp-server 之前，節點都不能開始裝**。

**3) httpd 改走 HTTPS**

```bash
cd /var/lib/cp-installer/pki
sudo install -o root -g root -m 0644 cp-server.crt /etc/pki/tls/certs/cp-repo.crt      # leaf（+ 銀行模式下的中繼）
sudo install -o root -g root -m 0600 cp-server.key /etc/pki/tls/private/cp-repo.key
sudo tee /etc/httpd/conf.d/cp-repo.conf >/dev/null <<'EOF'
# Managed by cpctl - internal repository, HTTPS only (plain HTTP answers 403)
DocumentRoot "/srv/repo"
<Directory "/srv/repo">
    Require all denied
</Directory>

Listen 8443 https
<VirtualHost *:8443>
    ServerName ops01.poc.lab
    SSLEngine on
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLCertificateFile /etc/pki/tls/certs/cp-repo.crt
    SSLCertificateKeyFile /etc/pki/tls/private/cp-repo.key
    DocumentRoot "/srv/repo"
    <Directory "/srv/repo">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
        <LimitExcept GET HEAD OPTIONS>
            Require all denied
        </LimitExcept>
    </Directory>
</VirtualHost>
EOF
# mod_ssl 自帶的預設 vhost（443、自簽憑證）不要用：內容換成一行註解（RPM 升級不會覆蓋改過的設定檔）
echo '# Managed by cpctl - default mod_ssl vhost disabled; the internal repo is served by cp-repo.conf' | sudo tee /etc/httpd/conf.d/ssl.conf >/dev/null
sudo httpd -t && sudo systemctl restart httpd
sudo firewall-cmd --permanent --add-port=8443/tcp && sudo firewall-cmd --permanent --remove-port=8080/tcp && sudo firewall-cmd --reload
sudo firewall-cmd --list-ports     # 8443/tcp 在、8080/tcp 不在（新環境 3.2 已只開 8443；照舊版建的環境要補這一步，實測時 cp-man 就缺了）
```

- **驗證**：
  ```bash
  P=/var/lib/cp-installer/pki
  for r in confluent adoptium os-deps; do
    curl -fsS --cacert $P/ca.pem -o /dev/null https://ops01.poc.lab:8443/rpm/$r/repodata/repomd.xml && echo "repo $r served over HTTPS"; done
  curl -s -o /dev/null -w 'HTTP 8080: %{http_code}\n' http://ops01.poc.lab:8080/rpm/confluent/repodata/repomd.xml   # 403
  # 不帶 --cacert 的結果取決於這台是否已在 3.4.8 把 CA 放進 OS trust store（ops01 已放，所以會是 200）；節點只信任 sslcacert 指定的檔案
  openssl s_client -connect ops01.poc.lab:8443 -servername ops01.poc.lab </dev/null 2>/dev/null | grep -c 'BEGIN CERTIFICATE'   # 內部 CA 1；銀行 2（leaf + 中繼）
  sudo ss -ltnp | grep -E ':(443|8443|8080) '    # 只有 8443 與 8080；443 不能出現
  ```
- **對應 cpctl**：`REPO_YUM_BASEURL=https://...` 時，step 02 在 ops01 裝完後依序執行 `pki::issue_all`、`repo::tls_configure`、`repo::verify_served`，然後才讓其他主機安裝；step 03 每次也會更新 repo 憑證與節點的 `cp-repo-ca.pem`，所以憑證或 CA 輪替時會跟著換。
- **注意事項**：
  - 憑證輪替（第 9 章）之後要重做第 3) 步的兩個 `install` 與 `systemctl restart httpd`，節點的 `cp-repo-ca.pem` 也要換成新的 `ca.pem`；否則 repo 繼續出示舊憑證，舊 CA 退役後節點就裝不了套件。
  - 第 2 章的 2.14 是在本節之前做的，所以那時用 HTTP 檢查；完成本節後改用上面的 HTTPS 指令。

### 3.3.1 RPM 策略

### 3.3.1.1 repo 定義檔

- **先放 repo 的 CA 檔**（HTTPS，3.3.0；ops01 自己不需要，它讀磁碟）：dnf 只信任這個檔裡的 CA。
  ```bash
  # ops01（cpadmin）
  scp /var/lib/cp-installer/pki/ca.pem kb01.poc.lab:/tmp/cp-repo-ca.pem
  # 目標主機（cpadmin + sudo）
  sudo install -o root -g root -m 0644 /tmp/cp-repo-ca.pem /etc/pki/tls/certs/cp-repo-ca.pem && rm -f /tmp/cp-repo-ca.pem
  ```
- **設定檔** `/etc/yum.repos.d/cp-internal.repo`（root:root 0644）：
  ```
  # Managed by cpctl - internal mirror only (public repos are not reachable from this network)
  [cp-internal-confluent]
  name=Internal mirror - Confluent Platform and Control Center
  baseurl=https://ops01.poc.lab:8443/rpm/confluent
  enabled=1
  gpgcheck=1
  gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-confluent
  sslverify=1
  sslcacert=/etc/pki/tls/certs/cp-repo-ca.pem

  [cp-internal-adoptium]
  name=Internal mirror - Eclipse Temurin
  baseurl=https://ops01.poc.lab:8443/rpm/adoptium
  enabled=1
  gpgcheck=1
  gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-adoptium
  sslverify=1
  sslcacert=/etc/pki/tls/certs/cp-repo-ca.pem

  [cp-internal-os-deps]
  name=Internal mirror - OS dependencies
  baseurl=https://ops01.poc.lab:8443/rpm/os-deps
  enabled=1
  gpgcheck=1
  gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
  sslverify=1
  sslcacert=/etc/pki/tls/certs/cp-repo-ca.pem
  ```
- **手動指令**（目標主機）：
  ```bash
  sudo tee /etc/yum.repos.d/cp-internal.repo >/dev/null <<'EOF'
  （上方內容）
  EOF
  sudo chmod 0644 /etc/yum.repos.d/cp-internal.repo
  ```
- **驗證**（一定要從節點做，而且要實際下載 metadata：`dnf repolist` 只列出設定、不連線，不能當驗證）：
  ```bash
  sudo dnf -q --refresh --disablerepo='*' --enablerepo='cp-internal-*' makecache; echo rc=$?      # rc=0、沒有錯誤
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://ops01.poc.lab:8080/rpm/confluent/repodata/repomd.xml   # 000（防火牆已關）或 403
  ```
  實測（cp-man）：11 台節點 makecache 全部 rc=0。換成不存在的 CA 檔就失敗（`Curl error (77)`），證明 `sslcacert` 生效。另外，ops 主機防火牆沒開 8443 時節點會得到 `No route to host`。
- **對應 cpctl**：`install::_repo_file`、`repo::trust_push`（`REPO_YUM_BASEURL` 是 `https://` 才加 `sslcacert`；repo 主機本身用 `file://`）。
- **注意**：C3 RPM 也放在 `rpm/confluent`，與 CP 共用 Confluent 金鑰（confluent-c3.asc 與 confluent.asc 大小相同，PoC 中為同一把）。公有 repo 在 image 中已全部 `enabled=0`。`cp-repo-ca.pem` 就是信任 bundle `ca.pem`，CA 輪替時要跟著換（3.3.0 注意事項）。

### 3.3.1.2 GPG 金鑰匯入

- **目的**：`gpgcheck=1` 需要先信任三把簽章金鑰；金鑰由 ops01 經 scp 傳送（ops01 在下載時已驗證）。
- **手動指令**：
  ```bash
  # 在 ops01（cpadmin）
  for k in confluent adoptium rocky-9; do
    scp /srv/repo/gpg-keys/$k.asc kb01.poc.lab:/tmp/RPM-GPG-KEY-cp-$k
  done
  # 在目標主機（cpadmin + sudo）
  for k in confluent adoptium rocky-9; do
    sudo install -o root -g root -m 0644 /tmp/RPM-GPG-KEY-cp-$k /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-$k
    rm -f /tmp/RPM-GPG-KEY-cp-$k
  done
  # 匯入前先核對指紋
  for k in confluent adoptium rocky-9; do gpg --show-keys /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-$k; done
  sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-confluent
  sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-adoptium
  sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
  ```
- **驗證**：
  ```bash
  rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n'
  # 期望包含：
  # gpg-pubkey-0c2bf624-60904208 Confluent Packaging <packages@confluent.io> public key
  # gpg-pubkey-65f8f04b-6193bd34 Adoptium GPG Key (DEB/RPM Signing Key) <temurin-dev@eclipse.org> public key
  # gpg-pubkey-350d275d-6279464b Rocky Enterprise Software Foundation - Release key 2022 <releng@rockylinux.org> public key
  ```
- **對應 cpctl**：`install::prepare`、`rpm_node::import_keys`（以指紋末 8 碼查 `gpg-pubkey-<8碼>` 判斷是否已匯入）。
- **注意事項**：正式環境的 OS 金鑰應換成 RHEL 的 `RPM-GPG-KEY-redhat-release`（PoC 用 Rocky 9）。

### 3.3.1.3 依角色安裝精確版本 + versionlock

- **套件**（`versions.env`；JDK 一律 `temurin-21-jdk-21.0.12.1.0.1`）：

| 主機 | 安裝規格 |
|---|---|
| ops01 | `temurin-21-jdk-21.0.12.1.0.1 confluent-server-8.3.2 confluent-security-8.3.2 confluent-cli-8.3.2` |
| kc01 kc02 kc04、kb01–kb04、jump01 | `temurin-21-jdk-21.0.12.1.0.1 confluent-server-8.3.2 confluent-security-8.3.2` |
| rest01 rest02 | `temurin-21-jdk-21.0.12.1.0.1 confluent-kafka-rest-8.3.2 confluent-security-8.3.2` |
| c3-01 | `temurin-21-jdk-21.0.12.1.0.1 confluent-control-center-next-gen-2.6.1 cyrus-sasl-2.1.27 openssl-devel-3.5.8` |

  （c3 的 OS 依賴版本取自 `/srv/repo/rpm/os-deps` 內最新的 RPM：cyrus-sasl-2.1.27-22.el9_7、openssl-devel-3.5.8-2.el9_8。jump01 只需 Kafka CLI 工具，不跑服務。）

- **手動指令**（以 broker 為例）：
  ```bash
  # 1) 先確認沒有裝錯版本（install 模式下若已有其他版本應停止，改走升級程序）
  rpm -q --qf '%{NAME} %{VERSION}\n' temurin-21-jdk confluent-server confluent-security
  # 2) 安裝
  sudo dnf -y -q --disablerepo='*' --enablerepo='cp-internal-*' --setopt=install_weak_deps=False \
       install temurin-21-jdk-21.0.12.1.0.1 confluent-server-8.3.2 confluent-security-8.3.2
  # 3) 鎖版本:直接指定的套件,加上一起被拉進來的 confluent-* 相依套件(與 cpctl 相同)
  for p in temurin-21-jdk-21.0.12.1.0.1 confluent-server-8.3.2 confluent-security-8.3.2; do
    sudo dnf versionlock add "$p"
  done
  for p in $(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 'confluent-*'); do sudo dnf versionlock add "$p"; done
  ```
  c3-01：
  ```bash
  sudo dnf -y -q --disablerepo='*' --enablerepo='cp-internal-*' --setopt=install_weak_deps=False \
       install temurin-21-jdk-21.0.12.1.0.1 confluent-control-center-next-gen-2.6.1 cyrus-sasl-2.1.27 openssl-devel-3.5.8
  for p in temurin-21-jdk-21.0.12.1.0.1 confluent-control-center-next-gen-2.6.1 cyrus-sasl-2.1.27 openssl-devel-3.5.8; do
    sudo dnf versionlock add "$p"
  done
  ```
- **驗證**：
  ```bash
  rpm -q --qf '%{VERSION}\n' confluent-server        # 8.3.2（controller/broker 必須相符；這是 cpctl step_verify）
  sudo dnf -q versionlock list
  # kb01 期望：
  # temurin-21-jdk-0:21.0.12.1.0.1-0.*
  # confluent-server-1:8.3.2-1.*
  # confluent-security-0:8.3.2-1.*
  # rest01：temurin-21-jdk…、confluent-kafka-rest-0:8.3.2-1.*、confluent-security-0:8.3.2-1.*
  # c3-01 ：temurin-21-jdk…、cyrus-sasl-0:2.1.27-22.el9_7.*、openssl-devel-1:3.5.8-2.el9_8.*、confluent-control-center-next-gen-0:2.6.1-1.*
  # ops01 ：多一行 confluent-cli-0:8.3.2-1.*
  getent passwd cp-kafka cp-kafka-rest ; getent group confluent     # RPM scriptlet 建立的服務帳號
  ls -l /usr/lib/jvm/temurin-21-jdk/bin/java
  ```
- **對應 cpctl**：`distribute::host` → `install::prepare` + `install::ensure` → `rpm_node::ensure install <name=ver>...`；`step_verify` → `install::version`。
- **注意事項**：
  - 需要 `python3-dnf-plugin-versionlock`（PoC image 已預裝；RHEL 最小安裝要先從 os-deps 裝）。
  - `confluent-server-8.3.2` 會拉入相依（confluent-common、rest-utils、ce-kafka-http-server、kafka-rest、server-rest、metadata-service、telemetry），這些相依套件也要鎖(上面第 3 步的第二個迴圈),否則 OS 修補時可能被單獨升級。升級時先 `dnf versionlock delete` 所有 confluent-* 再安裝新版、再重新鎖定。cpctl 自 2026-10-16 起也會鎖定相依套件(`rpm_node::lock_deps`)。
  - RPM 的 JDK `cacerts` 是 symlink → `/etc/pki/ca-trust/extracted/java/cacerts`（由 `update-ca-trust` 產生），與 3.8 有關。
  - 已安裝不同版本時 cpctl（install 模式）回傳錯誤並拒絕變更，需走 `cpctl upgrade`；手動同理，不要直接 `dnf install` 覆蓋。

### 3.3.2 tar 策略（`INSTALL_METHOD=tar`）

佈局：
```
/opt/java/jdk-21.0.12.1+1/                 /opt/java/current -> /opt/java/jdk-21.0.12.1+1
/opt/confluent/confluent-8.3.2/            /opt/confluent/current -> /opt/confluent/confluent-8.3.2
/opt/confluent/confluent-control-center-next-gen-2.6.1/   /opt/confluent/c3-current -> 該目錄（僅 c3）
/opt/confluent/.cpctl/<archive>.sha256     冪等標記（內容："<sha256> <頂層目錄>"）
/var/cache/cp-installer/                    下載快取
```

### 3.3.2.1 repo 定義（僅 OS 依賴）與 Rocky 金鑰

`/etc/yum.repos.d/cp-internal.repo`（root:root 0644）：
```
# Managed by cpctl - internal OS dependencies only
[cp-internal-os-deps]
name=Internal mirror - OS dependencies
baseurl=https://ops01.poc.lab:8443/rpm/os-deps
sslverify=1
sslcacert=/etc/pki/tls/certs/cp-repo-ca.pem
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
```
```bash
# ops01：scp /srv/repo/gpg-keys/rocky-9.asc <host>:/tmp/RPM-GPG-KEY-cp-rocky-9
sudo install -o root -g root -m 0644 /tmp/RPM-GPG-KEY-cp-rocky-9 /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-cp-rocky-9
```

### 3.3.2.2 服務帳號與目錄（RPM scriptlet 的替代）

| 角色 | 指令 |
|---|---|
| controller / broker（含 spare） | `sudo groupadd -r confluent`（若無）<br>`sudo useradd -r -g confluent -d /var/lib/kafka -M -s /sbin/nologin -c "Confluent (cp-kafka)" cp-kafka`<br>`sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka /var/log/kafka` |
| rest | `sudo useradd -r -g confluent -d /tmp -M -s /sbin/nologin -c "Confluent (cp-kafka-rest)" cp-kafka-rest`<br>`sudo install -d -o cp-kafka-rest -g confluent -m 0770 /var/log/confluent`<br>`sudo install -d -o cp-kafka-rest -g confluent -m 0750 /var/log/confluent/kafka-rest` |
| c3 | `sudo useradd -r -g confluent -d /var/lib/confluent/control-center -M -s /sbin/nologin -c "Confluent (cp-control-center)" cp-control-center`<br>`sudo install -d -o root -g root -m 0755 /var/lib/confluent`<br>`sudo install -d -o cp-control-center -g confluent -m 0750 /var/lib/confluent/control-center`<br>`sudo install -d -o cp-control-center -g confluent -m 0770 /var/log/confluent`<br>`sudo install -d -o cp-control-center -g confluent -m 0750 /var/log/confluent/control-center` |
| ops | `getent group confluent >/dev/null \|\| sudo groupadd -r confluent` |
| jump | 無 |

（`install -d` 對已存在目錄不改 owner/mode，必要時再補 `sudo chown`/`chmod`。）

### 3.3.2.3 取得 sha256（ops01）

```bash
cd /srv/repo/raw/tar
sha256sum OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz confluent-8.3.2.tar.gz confluent-control-center-next-gen-2.6.1.tar.gz
# 並與下載時記錄的值比對：
grep tar.gz /srv/repo/manifests/<最新時間戳>/SHA256SUMS
# PoC 實際值：
# ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94  tar/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz
# 946433221bae8272de416694060322aef0c9c8b3086da9574f86d6cb0d698c2f  tar/confluent-8.3.2.tar.gz
# 8389b4d3d68c466126f80ecdb6e3e74d7ab8e808af549260713356e44ffaed8b  tar/confluent-control-center-next-gen-2.6.1.tar.gz
```
CP 與 C3 tar 沒有原廠簽章，完整性只靠這組 sha256，**每台節點解壓前都要再驗一次**。

### 3.3.2.4 下載、驗證、解壓（每個 archive 一次；以 JDK + CP 為例）

```bash
# 目標主機（cpadmin + sudo）。以函式包起來方便重複使用：
fetch_extract() {  # <file> <sha256> <parent dir>
  local f=$1 sha=$2 parent=$3 top
  sudo install -d -m 0755 "$parent" /opt/confluent/.cpctl /var/cache/cp-installer
  sudo curl -fsS --retry 3 --cacert /etc/pki/tls/certs/cp-repo-ca.pem -o /var/cache/cp-installer/$f.part https://ops01.poc.lab:8443/raw/tar/$f
  sudo mv /var/cache/cp-installer/$f.part /var/cache/cp-installer/$f
  echo "$sha  /var/cache/cp-installer/$f" | sha256sum -c - || { sudo rm -f /var/cache/cp-installer/$f; return 4; }
  top=$(sudo tar -tzf /var/cache/cp-installer/$f | head -1 | cut -d/ -f1)
  sudo tar -xzf /var/cache/cp-installer/$f -C "$parent" --no-same-owner
  sudo chown -R root:root "$parent/$top"
  sudo chmod -R go-w "$parent/$top"
  printf '%s %s\n' "$sha" "$top" | sudo tee /opt/confluent/.cpctl/$f.sha256 >/dev/null
  echo "TOP=$top"
}
fetch_extract OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94 /opt/java
#   → TOP=jdk-21.0.12.1+1
fetch_extract confluent-8.3.2.tar.gz 946433221bae8272de416694060322aef0c9c8b3086da9574f86d6cb0d698c2f /opt/confluent
#   → TOP=confluent-8.3.2
# 僅 c3-01：
fetch_extract confluent-control-center-next-gen-2.6.1.tar.gz 8389b4d3d68c466126f80ecdb6e3e74d7ab8e808af549260713356e44ffaed8b /opt/confluent
#   → TOP=confluent-control-center-next-gen-2.6.1
```
（c3-01 不解 CP archive；ops01、jump01 只要 JDK + CP archive，不建 systemd unit。）

### 3.3.2.5 current symlink

```bash
sudo ln -sfn /opt/java/jdk-21.0.12.1+1 /opt/java/current
sudo ln -sfn /opt/confluent/confluent-8.3.2 /opt/confluent/current                                   # 非 c3
sudo ln -sfn /opt/confluent/confluent-control-center-next-gen-2.6.1 /opt/confluent/c3-current        # 僅 c3
```
- install 模式：若 `current` 已指向**其他** CP 版本，停止（那是升級，cpctl 拒絕）。JDK symlink cpctl 一律以 upgrade 模式處理（直接改指）。
- 切換 symlink 就是 tar 策略的升級 / 回退方式。

### 3.3.2.6 c3：OS 依賴 + 預設設定檔

```bash
sudo dnf -y -q --disablerepo='*' --enablerepo='cp-internal-*' --setopt=install_weak_deps=False install cyrus-sasl-2.1.27 openssl-devel-3.5.8
sudo dnf versionlock add cyrus-sasl-2.1.27 openssl-devel-3.5.8
# 只補缺少的預設檔，絕不覆蓋既有檔
sudo install -d -m 0755 /etc/confluent-control-center
for f in /opt/confluent/confluent-control-center-next-gen-2.6.1/etc/confluent-control-center/*; do
  [ -f "$f" ] && [ ! -e "/etc/confluent-control-center/$(basename "$f")" ] && sudo install -m 0644 "$f" /etc/confluent-control-center/
done
```
（注意 glob 由 cpadmin 展開；該目錄 root:root 0755 + go-w，cpadmin 可讀，所以這裡可行。）

### 3.3.2.7 自有 systemd unit（root:root 0644，之後 `sudo systemctl daemon-reload`）

`CP_HOME=/opt/confluent/current`、`C3_HOME=/opt/confluent/c3-current` 已代入。ExecStart/heap/JAVA_HOME 會由 step 05 的 drop-in（`<unit>.service.d/10-cpctl.conf`）覆寫。

controller / broker：`/etc/systemd/system/confluent-server.service`
```
# Managed by cpctl (tar strategy) - equivalent of the unit shipped in the confluent-server RPM.
# ExecStart / heap / JAVA_HOME come from the drop-in confluent-server.service.d/10-cpctl.conf
[Unit]
Description=Confluent Server (Apache Kafka) - tar install
Documentation=https://docs.confluent.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cp-kafka
Group=confluent
ExecStart=/opt/confluent/current/bin/kafka-server-start /opt/confluent/current/etc/kafka/server.properties
TimeoutStopSec=180
Restart=no

[Install]
WantedBy=multi-user.target
```
rest：`/etc/systemd/system/confluent-kafka-rest.service`
```
# Managed by cpctl (tar strategy) - equivalent of the unit shipped in the confluent-kafka-rest RPM.
[Unit]
Description=Confluent REST Proxy - tar install
Documentation=https://docs.confluent.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cp-kafka-rest
Group=confluent
Environment="LOG_DIR=/var/log/confluent/kafka-rest"
ExecStart=/opt/confluent/current/bin/kafka-rest-start /opt/confluent/current/etc/kafka-rest/kafka-rest.properties
TimeoutStopSec=180
Restart=no

[Install]
WantedBy=multi-user.target
```
c3：`/etc/systemd/system/confluent-control-center.service`
```
# Managed by cpctl (tar strategy) - equivalent of the unit shipped in the C3 next-gen RPM.
[Unit]
Description=Confluent Control Center - tar install
Documentation=https://docs.confluent.io/
After=network-online.target prometheus.service alertmanager.service
Wants=network-online.target

[Service]
Type=simple
User=cp-control-center
Group=confluent
Environment="LOG_DIR=/var/log/confluent/control-center"
ExecStart=/opt/confluent/c3-current/bin/control-center-start /etc/confluent/control-center/control-center.properties
TimeoutStopSec=180
Restart=always
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
```
c3：`/etc/systemd/system/prometheus.service`
```
# Managed by cpctl (tar strategy) - embedded Prometheus of Control Center.
# The start script would otherwise keep config/data INSIDE the versioned install dir (lost on upgrade):
# point it at the same locations the RPM uses.
[Unit]
Description=Prometheus (Control Center) - tar install
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=cp-control-center
Group=confluent
Environment="CONFIG_PATH=/etc/confluent-control-center"
Environment="LOG_PATH=/var/log/confluent/control-center"
Environment="TSDB_PATH=/var/lib/confluent/control-center/prometheus/data"
ExecStart=/bin/bash /opt/confluent/c3-current/bin/prometheus-start
TimeoutStopSec=180
Restart=always

[Install]
WantedBy=multi-user.target
```
c3：`/etc/systemd/system/alertmanager.service`
```
# Managed by cpctl (tar strategy) - embedded Alertmanager of Control Center.
[Unit]
Description=Alertmanager (Control Center) - tar install
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=cp-control-center
Group=confluent
Environment="CONFIG_PATH=/etc/confluent-control-center"
Environment="LOG_PATH=/var/log/confluent/control-center"
Environment="DATA_PATH=/var/lib/confluent/control-center/alertmanager/"
ExecStart=/bin/bash /opt/confluent/c3-current/bin/alertmanager-start
TimeoutStopSec=180
Restart=always

[Install]
WantedBy=multi-user.target
```

- **驗證（tar）**：
  ```bash
  readlink /opt/java/current /opt/confluent/current     # → /opt/java/jdk-21.0.12.1+1、/opt/confluent/confluent-8.3.2
  cat /opt/confluent/.cpctl/confluent-8.3.2.tar.gz.sha256   # → 9464…8c2f confluent-8.3.2
  /opt/java/current/bin/java -version                   # → openjdk version "21.0.12.1" ...（Temurin）
  /opt/confluent/current/bin/kafka-topics --version     # → 8.3.2-ce（需 JAVA_HOME=/opt/java/current 或 PATH）
  systemctl cat confluent-server | head -3
  stat -c '%U:%G' /opt/confluent/confluent-8.3.2        # → root:root
  ```
  cpctl 的版本判斷就是 `basename $(readlink /opt/confluent/current)` 去掉 `confluent-` 前綴。
- **對應 cpctl**：`install::prepare`（tar.sh）、`tar_node::account`、`ensure::dir`、`install::_archive`、`install::_sha`、`install::_fetch` → `tar_node::fetch_extract`、`tar_node::switch`、`tar_node::seed_dir`、`install::_units`、`svc::daemon_reload`。
- **注意事項（tar）**：
  - 工具路徑變成 `/opt/confluent/current/bin/...`，不在 PATH；JAVA_HOME = `/opt/java/current`。step 05 之後的手動指令要用這些路徑（RPM 為 `/usr/bin`、`/usr/lib/jvm/temurin-21-jdk`）。
  - `tar -tzf | head -1` 會讓 tar 收到 SIGPIPE（rc 141），在 `set -o pipefail` 下別誤判為錯誤。
  - archive 約 1.1–1.3 GB，`/var/cache/cp-installer` 需預留空間；快取檔 sha 正確時 cpctl 不重抓。
  - tar 策略的 JDK `cacerts` 是 JDK 目錄內的**實體檔**；切換 JDK 版本後要重做 3.4.8 的匯入。
  - 移除舊版本時，`/opt/confluent/confluent-[0-9]*` 這類 glob 要在**節點上以 root 展開**（cpctl 的 `tar_node::remove_paths` 就是這樣做）：`sudo bash -c 'rm -rf /opt/confluent/confluent-8.2.4'` 或 `sudo find /opt/confluent -maxdepth 1 -name 'confluent-8.2.*' -exec rm -rf {} +`。
  - SELinux 實機：解壓後執行 `sudo restorecon -R /opt/confluent /opt/java`。

## 3.4 步驟 03:內部 PKI（`03_pki.sh` + `lib/pki.sh`）

- **主機 / 帳號**：3.4.1–3.4.6 在 **ops01 以 cpadmin（不加 sudo）** 執行，工作目錄 `PKI_DIR=/var/lib/cp-installer/pki`；3.4.7（派送）與 3.4.8（信任）在各節點 cpadmin + sudo。
- **參數**（`inventory.env`）：`PKI_MODE=internal|external`（誰簽發，external = 銀行 CA，見 3.4.9）、`PKI_KEY_BITS=3072`、`PKI_CA_DAYS=3650`、`PKI_CERT_DAYS=365`、`PKI_RENEW_BEFORE_DAYS=30`；subject 後綴 `/OU=Confluent/O=PoC Bank/C=TW`；密碼 `STORE_PASSWORD`、`MDS_TOKEN_PASSPHRASE`（`conf/secrets.env`，Secret Protection 管理）。
- **keytool**：`/usr/lib/jvm/temurin-21-jdk/bin/keytool`（RPM）或 `/opt/java/current/bin/keytool`（tar）——所以 ops01 必須先完成 step 02。

準備（ops01，cpadmin）：
```bash
install -d -m 0700 /var/lib/cp-installer/pki      # 父目錄 /var/lib/cp-installer 為 cpadmin:cpadmin 0750
cd /var/lib/cp-installer/pki
umask 077
KT=/usr/lib/jvm/temurin-21-jdk/bin/keytool        # tar 策略：/opt/java/current/bin/keytool
# 密碼放環境變數，不要出現在指令列 / history：
read -rsp 'STORE_PASSWORD: ' STORE_PASSWORD; echo; export STORE_PASSWORD
read -rsp 'MDS_TOKEN_PASSPHRASE: ' MDS_TOKEN_PASSPHRASE; echo; export MDS_TOKEN_PASSPHRASE
```
> cpctl 實際使用 `-passout "pass:<password>"`；手動建議改用 `-passout env:STORE_PASSWORD`、keytool `-storepass:env STORE_PASSWORD`，效果相同但密碼不會出現在 `ps` / history。

### 3.4.1 建立內部 CA（RSA 3072、10 年）

- **目的**：簽發所有 leaf 憑證的根 CA；`ca.pem` 是發給所有節點的「信任 bundle」。
- **手動指令**：
  ```bash
  openssl genrsa -out ca.key 3072
  chmod 0600 ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 3650 -out ca.crt \
    -subj "/CN=PoC Internal CA $(date +%Y%m%d)/OU=Confluent/O=PoC Bank/C=TW" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
  # 信任 bundle：ca.crt (+ ca-next.crt + ca-old.crt，只有 CA 輪替期間才存在)
  cat ca.crt > ca.pem
  chmod 0644 ca.pem
  ```
- **驗證**：
  ```bash
  openssl x509 -in ca.crt -noout -subject -dates -ext basicConstraints,keyUsage
  # subject=CN=PoC Internal CA 2026xxxx, OU=Confluent, O=PoC Bank, C=TW
  # X509v3 Basic Constraints: critical  CA:TRUE
  # X509v3 Key Usage: critical  Certificate Sign, CRL Sign
  openssl x509 -in ca.crt -noout -text | grep 'Public-Key'     # Public-Key: (3072 bit)
  ```
- **對應 cpctl**：`pki::ca`、`pki::_new_ca`、`pki::bundle`。
- **注意事項**：cpctl 只在 CA 不存在或 365 天內到期時才重建；**CA 一旦建立就不要重跑 3.4.1**（會讓所有憑證失效）。CA 輪替走 `cpctl certs rotate-ca`（ca-next/ca-old 兩階段）。PoC 現存 CA 的 CN 為 `PoC Internal CA 202610151003`（輪替產生，含時分）。`ca.key` 是最高機密，正式環境建議離線保存 / HSM。

### 3.4.2 truststore.p12

- **目的**：給 Java 元件的 PKCS12 truststore，包含 bundle 內每一張 CA（alias `internal-ca-1..N`）。
- **手動指令**：
  ```bash
  d=$(mktemp -d)
  awk -v d="$d" '/BEGIN CERTIFICATE/ {n++} {print > (d "/ca-" n ".pem")}' ca.pem
  rm -f truststore.p12.new                 # 先建在旁邊，最後改名：啟動中的 client 不會讀到缺檔 / 只有部分 CA 的 truststore
  i=0; for f in "$d"/ca-*.pem; do i=$((i+1))
    "$KT" -importcert -noprompt -alias "internal-ca-$i" -file "$f" \
      -keystore truststore.p12.new -storetype PKCS12 -storepass:env STORE_PASSWORD
  done
  rm -rf "$d"
  mv -f truststore.p12.new truststore.p12
  sha256sum ca.pem | awk '{printf "%s",$1}' > truststore.bundle.sha256
  ```
- **驗證**：`"$KT" -list -keystore truststore.p12 -storepass:env STORE_PASSWORD` → `internal-ca-1, ..., trustedCertEntry`。
- **對應 cpctl**：`pki::truststore`、`pki::split_bundle`（bundle 的 sha 改變才重建）。

### 3.4.3 簽發憑證的共用程序

每張 leaf 憑證（`<name>`、`<SAN>`、`<EKU>`）：
```bash
issue() {  # <name> <EKU> [SAN 逗號清單]
  local n=$1 eku=$2 sans=${3:-}
  { printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
    printf 'extendedKeyUsage=%s\n' "$eku"
    [ -n "$sans" ] && printf 'subjectAltName=%s\n' "$(tr ',' '\n' <<<"$sans" | sort -u | sed 's/^/DNS:/' | paste -sd, -)"
  } > "$n.ext"
  # 若已有舊憑證，先歸檔：install -d -m 0700 archive/$(date +%Y%m%d-%H%M%S) && cp -p $n.* 該目錄/
  openssl genrsa -out "$n.key" 3072
  chmod 0600 "$n.key"
  openssl req -new -key "$n.key" -out "$n.csr" -subj "/CN=$n/OU=Confluent/O=PoC Bank/C=TW"
  openssl x509 -req -in "$n.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 365 -sha256 -extfile "$n.ext" -out "$n.crt"
  rm -f "$n.ext" "$n.csr"
  openssl pkcs12 -export -name "$n" -inkey "$n.key" -in "$n.crt" -certfile ca.crt \
    -passout env:STORE_PASSWORD -out "$n.p12"
  cat "$n.crt" ca.crt > "$n.chain.pem"
}
```
`ext` 檔實際內容範例（kafka-internal）：
```
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:kb01,DNS:kb01.poc.lab,DNS:kb02,DNS:kb02.poc.lab,DNS:kb03,DNS:kb03.poc.lab,DNS:kb04,DNS:kb04.poc.lab,DNS:kc01,DNS:kc01.poc.lab,DNS:kc02,DNS:kc02.poc.lab,DNS:kc03,DNS:kc03.poc.lab,DNS:kc04,DNS:kc04.poc.lab
```

### 3.4.4 kafka-internal（controller + broker 共用，CONTROLLER / INTERNAL 監聽器 mTLS）

- **目的**：叢集內部 mTLS 的共用身分，principal = `kafka-internal`（即 super user）。SAN 涵蓋所有 controller（含 spare kc03）與 broker 的短名與 FQDN。
- **手動指令**：
  ```bash
  issue kafka-internal serverAuth,clientAuth \
    kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc04.poc.lab,kc04,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04
  ```
- **驗證**：
  ```bash
  openssl x509 -in kafka-internal.crt -noout -subject -ext subjectAltName,extendedKeyUsage
  # subject=CN=kafka-internal, OU=Confluent, O=PoC Bank, C=TW
  # DNS:kb01, DNS:kb01.poc.lab, ... DNS:kc04, DNS:kc04.poc.lab   （共 16 個）
  # TLS Web Server Authentication, TLS Web Client Authentication
  openssl verify -CAfile ca.pem kafka-internal.crt          # kafka-internal.crt: OK
  ```
- **對應 cpctl**：`pki::issue kafka-internal "$(pki::sans_internal)" serverAuth,clientAuth`。

### 3.4.5 cp-server（所有伺服器共用：外部監聽器、MDS、REST、C3、Prometheus、LDAPS…）

- **目的**：對外 TLS 端點的共用伺服器憑證；SAN = `inv::all_hosts`（ops ad lb controller broker rest c3）+ spare + LB 虛擬名稱 + localhost。**jump01 不在 SAN 內**（它不提供 TLS 服務）。
- **手動指令**：
  ```bash
  issue cp-server serverAuth,clientAuth \
    ops01.poc.lab,ops01,ad01.poc.lab,ad01,lb01.poc.lab,lb01,kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc04.poc.lab,kc04,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04,rest01.poc.lab,rest01,rest02.poc.lab,rest02,c3-01.poc.lab,c3-01,kc03.poc.lab,kc03,rest.poc.lab,c3.poc.lab,localhost
  ```
- **驗證**：
  ```bash
  openssl x509 -in cp-server.crt -noout -ext subjectAltName | tail -n +2 | tr ',' '\n' | wc -l    # 31
  # DNS:ad01, DNS:ad01.poc.lab, DNS:c3-01, DNS:c3-01.poc.lab, DNS:c3.poc.lab, DNS:kb01, ... DNS:localhost,
  # DNS:ops01, DNS:ops01.poc.lab, DNS:rest.poc.lab, DNS:rest01, DNS:rest01.poc.lab, DNS:rest02, DNS:rest02.poc.lab
  openssl verify -CAfile ca.pem cp-server.crt               # cp-server.crt: OK
  ```
- **對應 cpctl**：`pki::issue cp-server "$(pki::sans_server)" serverAuth,clientAuth`。
- **注意事項**：增減主機或改 LB 名稱後 SAN 不符，cpctl 會自動重簽（比對排序後的 SAN 清單）；手動時須記得重簽並重新派送、滾動重啟。共用憑證的私鑰遍布所有伺服器（含 ad01/lb01 的 SAN），這是 PoC 的簡化設計，資安審查時要說明。

### 3.4.6 應用程式 client 憑證 + MDS token 金鑰

- **目的**：
  - 只有走 REST Proxy mTLS 的 legacy app 需要 client 憑證（principal = CN）：PoC 為 `app-legacy-billing`（`APP_CHANNEL_app_legacy_billing=rest`）。`app-orders`、`app-payments` 走 SCRAM，不發憑證。
  - `OPMENU=on` → 另發 break-glass 身分 `opmenu-breakglass`（OP menu 第 91 項，RBAC SystemAdmin）。
  - MDS 用 RSA 2048 金鑰對簽發 / 驗證 OAuth token；節點只拿 AES-256 加密的 PKCS#8 私鑰。
- **手動指令**：
  ```bash
  issue app-legacy-billing clientAuth          # 無 SAN
  issue opmenu-breakglass clientAuth           # 僅 OPMENU=on

  # MDS token key pair（已存在就不要重建：重建會讓所有已發 token 失效）
  openssl genrsa -out mds-token-keypair.pem 2048
  chmod 0600 mds-token-keypair.pem
  openssl rsa -in mds-token-keypair.pem -pubout -out mds-public.pem
  openssl pkcs8 -topk8 -v2 aes256 -in mds-token-keypair.pem -passout env:MDS_TOKEN_PASSPHRASE -out mds-token-keypair.enc.pem
  chmod 0600 mds-token-keypair.enc.pem
  ```
- **驗證**：
  ```bash
  openssl x509 -in app-legacy-billing.crt -noout -subject -ext extendedKeyUsage
  # subject=CN=app-legacy-billing, OU=Confluent, O=PoC Bank, C=TW
  # TLS Web Client Authentication
  openssl pkey -in mds-token-keypair.enc.pem -passin env:MDS_TOKEN_PASSPHRASE -noout && echo ENC_OK
  openssl verify -CAfile ca.pem kafka-internal.crt cp-server.crt      # 兩行 OK（cpctl step_verify）
  ls -l /var/lib/cp-installer/pki
  ```
  期望檔案權限：私鑰類(`*.key`、`*.p12`、`ca.key`、`mds-token-keypair*.pem`)一定是 0600;照本節以 `umask 077` 操作時,`*.crt`、`*.chain.pem`、`truststore.p12` 也會是 0600(cpctl 產生的是 0640,兩者都可以,目錄已是 0700);`ca.pem` 0644;全部 cpadmin:cpadmin。
- **對應 cpctl**：`pki::issue <app> "" clientAuth`（迴圈 `inv::apps rest`）、`pki::issue $OPMENU_BREAKGLASS`、`pki::prune`（不再受管的憑證移至 `archive/retired-<ts>/`）、`pki::mds_keypair`。
- **注意事項**：
  - 未加密的 `mds-token-keypair.pem` 仍留在 ops01 的 PKI 目錄（0600）；節點上若殘留要刪除（3.4.7）。
  - REST Proxy 只接受上述 CN（principal mapping 規則由 app 清單產生，step 05）。
  - App 改成 SCRAM 後，cpctl 會把它的憑證移到 archive，手動也應同樣處理並撤銷 RBAC。
  - OpenSSL 3 預設的 PKCS12 加密（AES-256-CBC + PBKDF2）Java 21 可讀；若要給舊版 Java 8 用戶端，需加 `-legacy`。

### 3.4.7 派送到 /etc/confluent/ssl（cpctl 於 step 05 由各角色執行）

- **目的**：每台伺服器只拿到自己角色需要的檔案。
- **各角色檔案**：

| 角色 | 檔案 |
|---|---|
| controller | `ca.pem truststore.p12 kafka-internal.p12 mds-token-keypair.enc.pem mds-public.pem` |
| broker | controller 的全部 + `cp-server.p12` |
| rest | `ca.pem truststore.p12 cp-server.p12 mds-public.pem` |
| c3 | `ca.pem truststore.p12 cp-server.p12 cp-server.crt cp-server.key mds-public.pem` |

  （jump01 的 opmenu truststore / break-glass keystore 由 step 11 處理，不在此範圍。）
- **權限**：`/etc/confluent` root:root 0755、`/etc/confluent/ssl` root:confluent 0750、檔案 root:confluent 0640（`confluent` 群組由 step 02 建立）。
- **手動指令**（以 kb01 為例）：
  ```bash
  # ops01（cpadmin）
  cd /var/lib/cp-installer/pki
  scp ca.pem truststore.p12 kafka-internal.p12 mds-token-keypair.enc.pem mds-public.pem cp-server.p12 kb01.poc.lab:/tmp/
  # kb01（cpadmin + sudo）
  sudo install -d -o root -g root -m 0755 /etc/confluent
  sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl
  for f in ca.pem truststore.p12 kafka-internal.p12 mds-token-keypair.enc.pem mds-public.pem cp-server.p12; do
    sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/$f && rm -f /tmp/$f
  done
  sudo rm -f /etc/confluent/ssl/mds-token-keypair.pem     # 舊版留下的未加密金鑰不可存在（controller/broker）
  ```
- **驗證**：
  ```bash
  sudo ls -l /etc/confluent/ssl
  # -rw-r----- 1 root confluent ... ca.pem / cp-server.p12 / kafka-internal.p12 / mds-public.pem / mds-token-keypair.enc.pem / truststore.p12
  sudo -u cp-kafka test -r /etc/confluent/ssl/kafka-internal.p12 && echo READABLE
  sudo openssl pkcs12 -in /etc/confluent/ssl/cp-server.p12 -nokeys -passin env:STORE_PASSWORD | openssl x509 -noout -subject
  ```
- **對應 cpctl**：`role::push_ssl`（`roles/_role.sh`），呼叫端 `kafka::_configure`、`rest`、`c3` 角色；`ensure::absent /etc/confluent/ssl/mds-token-keypair.pem`。
- **注意事項**：私鑰與 keystore(`*.p12`、`*.key`、`*keypair*.pem`)換新時**不要在節點上留舊檔備份**,舊私鑰應從節點上消失;操作機的 PKI 目錄已有歸檔。清除舊備份時 glob 要由 root 展開:`sudo find /etc/confluent/ssl -name '*.bak.*' -delete`。cpctl 自 2026-10-16 起不再為這類檔案留備份,03 步驟也會刪掉舊版留下的備份。

### 3.4.8 主機信任內部 CA（OS trust anchors + JDK cacerts）

- **目的**：讓 curl/openssl/ldap 工具（OS store）以及自行建立 HTTPS/LDAPS client 的 Java 元件（JDK 預設 truststore）信任內部 CA，而不必在指令列傳 truststore 密碼。
- **主機 / 帳號**：ops01、kc01 kc02 kc04、kb01–kb04、rest01–02、c3-01、jump01；cpadmin + sudo。
- **手動指令**（每台）：
  ```bash
  # 1) OS trust anchor（ops01 上 scp /var/lib/cp-installer/pki/ca.pem <host>:/tmp/cp-internal-ca.pem）
  sudo install -o root -g root -m 0644 /tmp/cp-internal-ca.pem /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem
  sudo update-ca-trust extract

  # 2) JDK cacerts：bundle 中每張 CA 一個 alias cp-ca-<SHA256 指紋前 16 碼小寫>
  JH=/usr/lib/jvm/temurin-21-jdk            # tar 策略：/opt/java/current
  d=$(mktemp -d)
  awk -v d="$d" '/BEGIN CERTIFICATE/ {n++} {print > (d "/ca-" n ".pem")}' /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem
  for f in "$d"/ca-*.pem; do
    fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f' | cut -c1-16)
    sudo "$JH/bin/keytool" -list -cacerts -storepass changeit -alias "cp-ca-$fp" >/dev/null 2>&1 || \
    sudo "$JH/bin/keytool" -importcert -noprompt -cacerts -storepass changeit -alias "cp-ca-$fp" -file "$f"
  done
  rm -rf "$d"
  # 3) 移除不在 bundle 內的舊 alias（cp-ca-* 及舊名 cp-internal-ca）
  sudo "$JH/bin/keytool" -list -cacerts -storepass changeit | grep -oE '^(cp-ca-[0-9a-f]+|cp-internal-ca)'
  #   對不在本次清單的 alias：sudo "$JH/bin/keytool" -delete -cacerts -storepass changeit -alias <alias>
  ```
  （`changeit` 是 JDK cacerts 公開的預設密碼，不是機密。）
- **驗證**：
  ```bash
  openssl x509 -in /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem -noout -fingerprint -sha256
  # sha256 Fingerprint=31:6E:D0:E1:06:2C:C9:5C:...   （PoC 現行 CA）
  sudo /usr/lib/jvm/temurin-21-jdk/bin/keytool -list -cacerts -storepass changeit | grep cp-ca
  # cp-ca-316ed0e1062cc95c, Oct 15, 2026, trustedCertEntry,
  trust list --filter=ca-anchors | grep -A3 'PoC Internal'
  curl -sS -o /dev/null -w '%{http_code}\n' https://kb01.poc.lab:8090/      # step 07 之後：不出現憑證錯誤
  ```
- **對應 cpctl**：`step_apply`（03_pki.sh）中的 `remote::put … anchors/cp-internal-ca.pem` + `update-ca-trust extract`，以及 `java_node::trust_ca`（`lib/node/kafka.sh`）。
- **注意事項**：
  - RPM 版 Temurin 的 `lib/security/cacerts` 是 symlink → `/etc/pki/ca-trust/extracted/java/cacerts`；`keytool -cacerts` 實際寫到 OS 產生的檔案，**下一次 `update-ca-trust extract` 會覆蓋掉 `cp-ca-*` alias**。因 CA 已在 anchors，Java 仍然信任（以 OS 產生的 alias），只是 `cp-ca-*` 標記消失；cpctl 每次重跑 03 都會補回。手動的順序一定是**先 update-ca-trust，再 keytool**。
  - tar 版 JDK 的 cacerts 是 JDK 目錄內實體檔，不受 update-ca-trust 影響，但 JDK 版本切換後要重做。
  - **不要在 `/etc/pki/ca-trust/source/anchors/` 留備份檔**：p11-kit 會讀取 anchors 內的**所有檔案**(不只 `.pem`),留在這裡的 `cp-internal-ca.pem.bak.<ts>` 會讓已退役的 CA 繼續被信任。撰寫本手冊時在 kb01 發現這個問題(`trust list` 同時列出現行 CA 與已退役的 `PoC Internal CA`),cpctl 已修正:anchors 的備份改放 `/var/backups/cp-installer/`,03 步驟也會把舊版本留下的備份移出並重跑 `update-ca-trust extract`。手動輪替 CA 時,備份請放在 anchors 目錄以外。
  - CA 輪替期間 `ca.pem` 是多張 CA 的 bundle，上述 awk 切檔即為此設計。

### 3.4.9 銀行 CA 簽發（PKI_MODE=external）

正式環境的憑證由銀行的 PKI 簽發：銀行有 root CA 與簽發用的中繼 CA（intermediate），**我們手上沒有任何 CA 私鑰**，只拿到 root 憑證。憑證的結構不變（`kafka-internal`、`cp-server`、app 與 break-glass 的 client 憑證，用途與 SAN 同 3.4.4–3.4.6），只有「誰簽」改變：

| | 內部 CA（3.4.1–3.4.6） | 銀行 CA（本節） |
|---|---|---|
| 誰簽 | ops01 上的 `ca.key` | 銀行；ops01 只產生私鑰與 CSR |
| 信任 bundle `ca.pem` | `ca.crt` | `trust/*.pem`（銀行 root，只有 root） |
| `<name>.crt` 內容 | leaf | **leaf + 中繼 CA**（伺服器必須送出完整鏈，對方只信任 root） |
| `<name>.p12` | key + leaf + 內部 CA | key + leaf + 中繼 CA |
| 一張憑證要幾次執行 | 1 次 | 2 次：先產生申請，銀行簽回後再匯入 |

PoC 用 `windows/bank-ca.sh` 模擬銀行（root `PoC Bank Root CA G1` → 中繼 `PoC Bank Issuing CA G1-01`，`pathlen:0`），CA 私鑰在 Windows 端的 `bank-ca/`，ops01 碰不到。

**檔案位置**（ops01，`/var/lib/cp-installer/pki`）：

| 路徑 | 內容 | 誰用 |
|---|---|---|
| `trust/<name>.pem` | 銀行 root（`cpctl certs trust add` 放入） | 信任 bundle |
| `pending/<name>.key` | 新私鑰（0600，**永遠不離開 ops01**） | 匯入時配對 |
| `requests/<name>.csr`、`<name>.req.txt` | CSR 與申請單 | **交給銀行** |
| `incoming/<name>.crt` | 銀行的回覆（leaf + 中繼，順序不拘，可含 root） | 匯入 |

### 3.4.9.1 取得銀行 root

- **手動指令**（ops01，cpadmin）：
  ```bash
  install -d -m 0750 trust
  openssl x509 -in ~/bank-root-g1.pem -noout -subject -fingerprint -sha256 -ext basicConstraints
  # subject=CN=PoC Bank Root CA G1, O=PoC Bank, C=TW
  # sha256 Fingerprint=B4:F5:04:CA:...      ← 一定要和銀行用「另一個管道」公布的指紋比對
  # X509v3 Basic Constraints: critical  CA:TRUE
  openssl x509 -in ~/bank-root-g1.pem -out trust/bank-root-g1.pem && chmod 0644 trust/bank-root-g1.pem
  ```
- **對應 cpctl**：`cpctl certs trust add ~/bank-root-g1.pem --name bank-root-g1`（檢查是 CA、只有一張、一年內不到期，印出指紋）。首次安裝加 `--no-rollout`，之後 `cpctl install` 會帶入。
- **注意事項**：銀行若提供**專用的中繼 CA** 給 Kafka 使用，可以把中繼 CA 當成信任錨點放進 `trust/`（而不是 root），這樣只有這張中繼簽的憑證才會被信任；cpctl 的檢查用 `-partial_chain`，Java 本來就接受任何信任錨點。

### 3.4.9.2 產生私鑰、CSR 與申請單

- **手動指令**（以 kafka-internal 為例；SAN 與 EKU 同 3.4.4）：
  ```bash
  install -d -m 0700 pending && install -d -m 0750 requests incoming
  n=kafka-internal
  openssl genrsa -out pending/$n.key 3072 && chmod 0600 pending/$n.key
  openssl req -new -key pending/$n.key -sha256 -subj "/CN=$n/OU=Confluent/O=PoC Bank/C=TW" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth,clientAuth" \
    -addext "subjectAltName=DNS:kb01,DNS:kb01.poc.lab,...,DNS:kc04.poc.lab" \
    -out requests/$n.csr
  ```
  申請單 `requests/<name>.req.txt`（cpctl 產生的實際內容）：
  ```
  Certificate request kafka-internal  (cpctl, 2026-10-17 ...)

  Subject            : CN = kafka-internal, OU = Confluent, O = PoC Bank, C = TW
  Key                : RSA 3072 (the private key stays on the ops host)
  Validity requested : 365 days
  Key usage          : digitalSignature, keyEncipherment
  Extended key usage : serverAuth, clientAuth
                       BOTH are required: the service presents this certificate as server and as client
  SAN (DNS)          : kb01,kb01.poc.lab,...,kc04,kc04.poc.lab
  Used by            : controllers + brokers: CONTROLLER / INTERNAL listeners (server AND client ...)
  Return format      : PEM - the certificate followed by the issuing intermediate CA(s); the root is optional
  CSR SHA-256        : ...
  ```
- **驗證**：
  ```bash
  openssl req -in requests/$n.csr -noout -verify -text | grep -A1 -E 'Alternative|Extended Key'
  # verify OK / DNS:kb01, ... / TLS Web Server Authentication, TLS Web Client Authentication
  ```
- **對應 cpctl**：`pki::request`（由 `pki::_issue_external` 在需要時呼叫：沒有憑證、即將到期、SAN 不符、不是銀行簽的，或 `cpctl certs rotate`）。
- **注意事項**：把 `.csr` 與 `.req.txt` 交給銀行（行內檔案交換流程），**私鑰不交出去**。`kafka-internal` 與 `cp-server` 一定要同時有 serverAuth 與 clientAuth（理由見 3.4.4、3.4.5），這是銀行最常漏掉的地方，申請單特別註明。

### 3.4.9.3 匯入銀行的回覆（先檢查，全部通過才換上）

- **手動指令**（`incoming/$n.crt` 是銀行的回覆）：
  ```bash
  n=kafka-internal; in=incoming/$n.crt; w=$(mktemp -d)
  awk -v d="$w" '/BEGIN CERTIFICATE/ {k++} {print > (d "/c-" k ".pem")}' "$in"
  # 1) 哪一張是 leaf：公鑰和 pending 私鑰一致的那張
  kp=$(openssl pkey -in pending/$n.key -pubout)
  for f in "$w"/c-*.pem; do [ "$(openssl x509 -in $f -noout -pubkey)" = "$kp" ] && leaf=$f; done; echo "leaf=$leaf"
  # 2) CN、不是 CA、SAN、EKU、效期
  openssl x509 -in "$leaf" -noout -subject -ext basicConstraints,subjectAltName,extendedKeyUsage -dates
  # 3) 憑證鏈：leaf + 中繼（自簽的 root 不放進去）→ 銀行 root
  cat "$leaf" > $w/chain.pem
  for f in "$w"/c-*.pem; do
    [ "$f" = "$leaf" ] && continue
    [ "$(openssl x509 -in $f -noout -subject_hash)" = "$(openssl x509 -in $f -noout -issuer_hash)" ] && continue
    cat "$f" >> $w/chain.pem
  done
  openssl verify -partial_chain -CAfile <(cat trust/*.pem) -untrusted $w/chain.pem $w/chain.pem    # OK
  # 4) 全部通過才換上（舊檔先歸檔，同 3.4.3）
  install -m 0600 pending/$n.key $n.key
  install -m 0640 $w/chain.pem $n.crt && cp $n.crt $n.chain.pem
  openssl pkcs12 -export -name $n -inkey $n.key -in $n.crt -passout env:STORE_PASSWORD -out $n.p12
  rm -f pending/$n.key; rm -rf "$w"     # incoming / requests 移到 archive/
  ```
  （手動版第 3 步假設回覆只有一張中繼；cpctl 依 issuer 逐層排出正確順序，多層中繼也可以。）
- **檢查項目與拒絕訊息**（cpctl `pki::check_signed`，任何一項不過就**完全不換**，原有憑證繼續使用）：

| 檢查 | 不通過時 |
|---|---|
| 有一張憑證的公鑰與 pending 私鑰相同 | `no certificate in the file matches the pending private key` |
| CN = 申請的名稱（CN 就是 Kafka / RBAC principal） | `subject CN is '...', requested '...'` |
| 不是 CA 憑證 | `it is a CA certificate` |
| SAN 與申請完全相同 | `SAN differs - requested [...], received [...]` |
| EKU 含申請的每一項 | `extended key usage lacks clientAuth` |
| 已生效、`PKI_RENEW_BEFORE_DAYS` 內不到期 | `not valid before ...` / `expires ...` |
| 鏈到 `trust/` 的銀行 root（檔案內要有中繼） | `does not chain to a bank root in trust/ ...` |

- **驗證**：
  ```bash
  grep -c 'BEGIN CERTIFICATE' kafka-internal.crt                                  # 2（leaf + 中繼）
  openssl verify -partial_chain -CAfile ca.pem -untrusted kafka-internal.crt kafka-internal.crt   # OK
  openssl pkcs12 -in kafka-internal.p12 -nokeys -passin env:STORE_PASSWORD | grep -c 'BEGIN CERT' # 2
  ```
- **對應 cpctl**：`pki::import`、`pki::check_signed`；`cpctl install` 遇到「還在等銀行、且沒有可用舊憑證」的申請會停在 03（`waiting for the bank: ...`），可用的舊憑證則繼續使用、只發警告。
- **注意事項**：
  - 伺服器端一定要送出中繼 CA：Java 用 p12 裡的整條鏈；Prometheus（`cert_file`）、Samba LDAPS（`cert.pem`）、curl `--cert` 都直接讀 `<name>.crt`，所以 `.crt` 本身就是 leaf + 中繼。實測時 Prometheus 9090 與 LDAPS 636 原本只送 1 張（內部 CA 模式不需要），換成銀行憑證後送 2 張。
  - **信任銀行 root = 信任銀行簽的每一張憑證**。principal 取自 CN（`RULE:.*CN=(...)`），若銀行替別的系統簽了 `CN=kafka-internal`，對方就是 super user。要求銀行：Kafka 的 CN 由 RA 管控不重複，或提供專用中繼 CA（3.4.9.1 注意事項）；Prometheus / Alertmanager 的 mTLS 不檢查 CN，任何銀行憑證都能連上。
  - 銀行沒有提供 CRL / OCSP 時，Kafka 不會檢查撤銷；懷疑私鑰外洩時要立即輪替（9.2）並請銀行撤銷。

# 4. 叢集核心:AD、設定檔、格式化、啟動(步驟 04–07)

本章對應 cpctl 的 `04_ad_bootstrap`、`05_configure`、`06_kraft_format`、`07_start_core`,以及 `cpctl controller add|remove|replace`(`installer/upgrade/controller.sh`)。

所有數值取自 `installer/conf/inventory.env`、`apps.env`、`audit.env`、`versions.env`,以及 PoC 節點上實際產生的檔案(commit ab38715)。密碼一律寫成 `<password>` 或 `<xxx-password>`。

## 4.0 共用變數(在 ops01 以 cpadmin 執行)

後面的指令都假設先在 ops01 的 shell 定義下列變數(不含任何密碼):

```bash
$ export S=/var/lib/cp-installer              # cpctl 的 STATE_DIR
$ export PKI=$S/pki                          # 03_pki 產生的 CA、憑證、keystore
$ export CB=kc01.poc.lab:9093,kc02.poc.lab:9093,kc04.poc.lab:9093      # controller bootstrap
$ export BI=kb01.poc.lab:9092,kb02.poc.lab:9092,kb03.poc.lab:9092,kb04.poc.lab:9092  # broker INTERNAL
$ export ADMIN_CFG=$S/client/internal.properties   # 管理用 client 設定(內部憑證 = super user)
$ export JAVA_HOME=/usr/lib/jvm/temurin-21-jdk KAFKA_HEAP_OPTS=-Xmx256m \
         KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
```

`$ADMIN_CFG`(0600,cpadmin)內容如下,cpctl 在第一次需要時由 `kafka::admin_config` 產生:

```properties
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=/var/lib/cp-installer/pki/kafka-internal.p12
ssl.keystore.password=<store-password>
ssl.key.password=<store-password>
ssl.truststore.type=PKCS12
ssl.truststore.location=/var/lib/cp-installer/pki/truststore.p12
ssl.truststore.password=<store-password>
ssl.endpoint.identification.algorithm=https
```

```bash
$ install -m 0600 /dev/null $ADMIN_CFG && vi $ADMIN_CFG     # 先建 0600 的空檔再填內容
```

> 路徑以 RPM 安裝方式為準(`/usr/bin`、`/etc/kafka`、`/usr/lib/jvm/temurin-21-jdk`)。tar.gz 方式請把 `/usr/bin/kafka-*` 換成 `/opt/confluent/current/bin/kafka-*`、`/etc/kafka` 換成 tar 的 `etc/kafka`、JAVA_HOME 換成 `/opt/java/current`(見第 7 章)。

## 4.1 步驟 04:Active Directory(04_ad_bootstrap)

`PROFILE=poc` 時由安裝者自己把 Samba AD(ad01)設定好:換上內部 CA 簽的 LDAPS 憑證、建立 OU、服務帳號、群組與測試使用者。`PROFILE=prod` 時 AD 歸行內 AD 團隊管理,這一步**只做檢查**,缺什麼就開單請 AD 團隊建立。

要建立的物件(取自 `conf/apps.env`、`inventory.env`):

| 類型 | 名稱 | 位置 |
|---|---|---|
| OU | `OU=Confluent`、`OU=Users,OU=Confluent`、`OU=Groups,OU=Confluent`、`OU=Service,OU=Confluent` | `DC=corp,DC=poc,DC=lab` 底下 |
| 服務帳號 | `svc-mds-bind`(MDS 查 AD 用的 bind 帳號)、`svc-rest`、`svc-c3`、`svc-cpctl` | `OU=Service,OU=Confluent` |
| 群組 | `kafka-admins`、`kafka-operators`、`kafka-devs` | `OU=Groups,OU=Confluent` |
| 測試使用者 | `alice`→kafka-admins、`bob`→kafka-operators、`carol`→kafka-devs | `OU=Users,OU=Confluent` |

### 4.1.1 LDAPS 憑證(僅 PoC)

**目的**:MDS 與 broker 用 LDAPS(636)連 AD,並以內部 CA 的 truststore 驗證 AD 的憑證。Samba 預設是自簽憑證,必須換成內部 CA 簽發、SAN 含 `ad01.poc.lab` 的憑證,否則 TLS 握手失敗。

**主機 / 帳號**:從 ops01(cpadmin)把檔案送到 ad01,在 ad01 以 root(sudo)安裝。

**手動指令**:

```bash
# PoC 直接沿用共用的伺服器憑證 cp-server(03_pki 已把 ad01.poc.lab 放進 SAN)
$ scp $PKI/cp-server.key $PKI/cp-server.crt $PKI/ca.pem ad01.poc.lab:/tmp/
$ ssh ad01.poc.lab "sudo install -o root -g root -m 0600 /tmp/cp-server.key /var/lib/samba/private/tls/key.pem && \
    sudo install -o root -g root -m 0644 /tmp/cp-server.crt /var/lib/samba/private/tls/cert.pem && \
    sudo install -o root -g root -m 0644 /tmp/ca.pem /var/lib/samba/private/tls/ca.pem && \
    sudo rm -f /tmp/cp-server.key /tmp/cp-server.crt /tmp/ca.pem"
# 讓 samba 重新讀憑證:容器的 entrypoint 會在 samba 結束後 2 秒自動重啟它
$ ssh ad01.poc.lab "sudo pkill -x samba || true"; sleep 5
```

`/etc/samba/smb.conf` 中對應的設定(provision 時已寫入,不需修改):

```ini
tls enabled = Yes
tls keyfile = tls/key.pem
tls certfile = tls/cert.pem
tls cafile = tls/ca.pem
```

**驗證**(不需帳號,匿名讀 RootDSE,但會驗證憑證鏈):

```bash
$ LDAPTLS_CACERT=$PKI/ca.pem ldapsearch -LLL -x -o nettimeout=5 -H ldaps://ad01.poc.lab:636 -s base -b "" namingContexts
dn:
namingContexts: DC=corp,DC=poc,DC=lab
...
$ openssl s_client -connect ad01.poc.lab:636 -CAfile $PKI/ca.pem -verify_return_error </dev/null 2>/dev/null | grep -E "subject=|Verify return code"
Verify return code: 0 (ok)
```

**對應 cpctl**:`role::ad::configure`(roles/ad.sh)、健康檢查 `ad::_ldaps_tls_ok`(最多等 120 秒)。

**注意事項**:
- 只有內容有變時 cpctl 才會 `pkill samba`。正式環境的 DC 不是這樣重啟,憑證由 AD 團隊負責,本節整個跳過。
- `key.pem` 必須是 0600,samba 對私鑰權限很嚴格,權限太寬會拒絕啟用 TLS。
- 憑證輪替(新舊 CA 並存)時 `ca.pem` 可能是 bundle,這是正常的。

### 4.1.2 OU、服務帳號、群組、使用者(僅 PoC)

**目的**:讓 MDS 的 LDAP 設定(`ldap.user.search.base=OU=Confluent,...`、`ldap.group.search.base=OU=Groups,OU=Confluent,...`)找得到使用者與群組,並備好各元件要用的服務帳號。

**主機 / 帳號**:ad01,root(`samba-tool` 直接寫本機 `sam.ldb`)。

**手動指令**(每一項先查再建,重跑不會出錯):

```bash
$ ssh ad01.poc.lab 'sudo bash -s' <<'EOF'
set -e
LDB=/var/lib/samba/private/sam.ldb
# 1) OU(samba-tool ou create 接受去掉 DC=... 的相對 DN)
for ou in "OU=Confluent" "OU=Users,OU=Confluent" "OU=Groups,OU=Confluent" "OU=Service,OU=Confluent"; do
  ldbsearch -H $LDB -b "$ou,DC=corp,DC=poc,DC=lab" -s base dn 2>/dev/null | grep -q '^dn:' \
    && echo "ok  $ou" || samba-tool ou create "$ou"
done
# 2) 群組
for g in kafka-admins kafka-operators kafka-devs; do
  ldbsearch -H $LDB "(&(objectClass=group)(sAMAccountName=$g))" dn | grep -q '^dn:' \
    && echo "ok  $g" || samba-tool group add "$g" --groupou="OU=Groups,OU=Confluent"
done
EOF
```

服務帳號與使用者需要密碼,請**逐一互動輸入**(不帶密碼參數時 `samba-tool user create` 會提示輸入,不會留在 history):

```bash
# 服務帳號:svc-mds-bind 用 LDAP_BIND_PASSWORD、svc-rest 用 SVC_REST_PASSWORD、
#           svc-c3 用 SVC_C3_PASSWORD、svc-cpctl 用 SVC_CPCTL_PASSWORD(皆在 conf/secrets.env)
$ ssh -t ad01.poc.lab "sudo samba-tool user create svc-mds-bind --userou='OU=Service,OU=Confluent'"
New Password: <password>
Retype Password: <password>
User 'svc-mds-bind' added successfully
$ ssh ad01.poc.lab "sudo samba-tool user setexpiry svc-mds-bind --noexpiry"
#   svc-rest、svc-c3、svc-cpctl 同上

# 測試使用者(密碼 HUMAN_DEFAULT_PASSWORD)與群組成員
$ ssh -t ad01.poc.lab "sudo samba-tool user create alice --userou='OU=Users,OU=Confluent'"
$ ssh ad01.poc.lab "sudo samba-tool user setexpiry alice --noexpiry && sudo samba-tool group addmembers kafka-admins alice"
$ ssh -t ad01.poc.lab "sudo samba-tool user create bob --userou='OU=Users,OU=Confluent'"
$ ssh ad01.poc.lab "sudo samba-tool user setexpiry bob --noexpiry && sudo samba-tool group addmembers kafka-operators bob"
$ ssh -t ad01.poc.lab "sudo samba-tool user create carol --userou='OU=Users,OU=Confluent'"
$ ssh ad01.poc.lab "sudo samba-tool user setexpiry carol --noexpiry && sudo samba-tool group addmembers kafka-devs carol"
```

使用者是否已存在:`sudo ldbsearch -H /var/lib/samba/private/sam.ldb "(&(objectClass=user)(sAMAccountName=alice))" dn`。

**不需互動的做法(全程實測採用)**:`samba-tool` 不是在終端機上執行時,會從 stdin 讀兩次密碼。密碼從 ops01 的密碼檔(3.0.5)經管線送過去,不出現在指令列、`ps` 或 history:

```bash
$ set -a; . $S/secrets.env; set +a
$ printf '%s\n%s\n' "$LDAP_BIND_PASSWORD" "$LDAP_BIND_PASSWORD" | \
    ssh ad01.poc.lab "sudo samba-tool user create svc-mds-bind --userou='OU=Service,OU=Confluent' 2>&1 | tail -1"
User 'svc-mds-bind' added successfully
$ ssh ad01.poc.lab "sudo samba-tool user setexpiry svc-mds-bind --noexpiry"
```

其他帳號同理:svc-rest(`SVC_REST_PASSWORD`)、svc-c3(`SVC_C3_PASSWORD`)、svc-cpctl(`SVC_CPCTL_PASSWORD`)放 `OU=Service,OU=Confluent`;alice、bob、carol(`HUMAN_DEFAULT_PASSWORD`)放 `OU=Users,OU=Confluent`,再 `samba-tool group addmembers` 加入群組。

**驗證**:

```bash
$ ssh ad01.poc.lab "sudo samba-tool ou list"
OU=Users,OU=Confluent
OU=Groups,OU=Confluent
OU=Service,OU=Confluent
OU=Confluent
OU=Domain Controllers
$ ssh ad01.poc.lab "sudo samba-tool group listmembers kafka-admins"
alice
# 以 svc-mds-bind 經 LDAPS bind(與 MDS 實際做的事相同);-W 互動輸入密碼
$ LDAPTLS_CACERT=$PKI/ca.pem ldapsearch -LLL -x -o nettimeout=5 -H ldaps://ad01.poc.lab:636 \
    -D "CN=svc-mds-bind,OU=Service,OU=Confluent,DC=corp,DC=poc,DC=lab" -W \
    -b "DC=corp,DC=poc,DC=lab" "(sAMAccountName=svc-mds-bind)" dn
dn: CN=svc-mds-bind,OU=Service,OU=Confluent,DC=corp,DC=poc,DC=lab
```

**對應 cpctl**:`role::ad::accounts`(roles/ad.sh)→ 節點端 `ad::ensure_ou`、`ad::ensure_group`、`ad::ensure_user`、`ad::ensure_member`(lib/node/ad.sh);健康檢查 `role::ad::health` → `ad::_ldaps_ok`(最多等 90 秒)。

**注意事項**:
- 密碼**只在建立時設定**;帳號已存在時 cpctl 不會改密碼。若 `secrets.env` 的密碼改了,要自己用 `samba-tool user setpassword` 同步,否則 MDS bind 失敗。
- `ldap.user.search.base` 是 `OU=Confluent`(含 Users 與 Service 兩個子 OU),所以服務帳號也能被 MDS 當成「使用者」認證(REST、C3 用 svc-rest / svc-c3 登入 MDS 就靠這個)。
- 群組的 DN 會被 `ldap.group.member.attribute.pattern=CN=([^,]+),.*` 解析成使用者名稱,所以使用者的 CN 必須等於 sAMAccountName(`samba-tool user create` 預設如此;正式 AD 若 CN 是中文姓名就要改 pattern 或改用 `ldap.user.memberof.attribute`)。
- cpctl 的 `ad::ldapsearch` 用 `-w <password>`,手動時建議改 `-W`(互動)或 `-y <0600 檔案>`。

### 4.1.3 正式環境:只檢查(PROFILE=prod)

**目的**:正式 AD 由 AD 團隊建立物件;安裝前確認服務帳號與群組都已存在、bind 帳號可用、LDAPS 憑證可被內部 CA 驗證。

**主機 / 帳號**:ops01,cpadmin;以 `svc-mds-bind` bind。

**手動指令**:

```bash
$ BIND="CN=svc-mds-bind,OU=Service,OU=Confluent,DC=corp,DC=poc,DC=lab"
$ install -m 0600 /dev/null ~/.bindpw && vi ~/.bindpw     # 寫入 LDAP_BIND_PASSWORD(檔尾不要換行)
$ for n in svc-mds-bind svc-rest svc-c3 svc-cpctl; do
    LDAPTLS_CACERT=$PKI/ca.pem ldapsearch -LLL -x -o nettimeout=5 -H ldaps://ad01.poc.lab:636 \
      -D "$BIND" -y ~/.bindpw -b "DC=corp,DC=poc,DC=lab" "(sAMAccountName=$n)" dn | grep -q '^dn:' \
      && echo "OK  account $n" || echo "MISSING account $n"
  done
$ for g in kafka-admins kafka-operators kafka-devs; do
    LDAPTLS_CACERT=$PKI/ca.pem ldapsearch -LLL -x -o nettimeout=5 -H ldaps://ad01.poc.lab:636 \
      -D "$BIND" -y ~/.bindpw -b "DC=corp,DC=poc,DC=lab" "(&(objectClass=group)(cn=$g))" dn | grep -q '^dn:' \
      && echo "OK  group $g" || echo "MISSING group $g"
  done
$ rm -f ~/.bindpw
```

**驗證**:全部印出 `OK`。有 `MISSING` 就停下來開單給 AD 團隊,不要往下做(cpctl 以 `E_PRECHECK` 結束)。多台 DC(`AD_LDAP_HOSTS="ad01 ad02"`)時每台都要測一次。

**對應 cpctl**:`role::ad::check_accounts`(roles/ad.sh)。

**注意事項**:prod 模式不會換 AD 憑證,所以 AD 的 LDAPS 憑證必須由行內 CA 簽發,且該 CA 要在 `truststore.p12` 裡,否則 MDS 啟動後所有 LDAP 認證都會失敗。

## 4.2 步驟 05:產生並派送設定(05_configure)

**目的**:為每台 controller / broker 產生 `server.properties`(含 listener、TLS、RBAC/MDS、LDAP、audit、telemetry),用 Secret Protection 把所有密碼換成密文參照,連同憑證、JMX exporter 設定、systemd drop-in 一起派送到節點。本節只講 controller 與 broker;REST、C3 在 5.2。

執行順序(cpctl 也是這個順序):

1. 5.1 在 ops01 產生 Secret Protection master key(整個叢集只做一次)
2. 5.2 派送憑證到 `/etc/confluent/ssl`
3. 5.3 產生明文 `server.properties`(只存在 ops01 的 0700 目錄)
4. 5.4 用 `confluent secret file encrypt` 加密,派送加密後的 `server.properties`、`security.properties`、`service.env`
5. 5.5 JMX exporter
6. 5.6 systemd drop-in
7. 5.7 資料目錄
8. 5.8 服務已在跑的話,逐台滾動重啟

各主機的值:

| 主機 | 角色 | node.id | broker.rack | heap(poc) | keystore(JMX exporter) |
|---|---|---|---|---|---|
| kc01 / kc02 / kc04 | controller | 1 / 2 / 4 | – | 384m | kafka-internal |
| kb01 / kb02 | broker | 101 / 102 | rack-a | 512m | cp-server |
| kb03 / kb04 | broker | 103 / 104 | rack-b | 512m | cp-server |

### 4.2.1 Secret Protection master key(ops01,只做一次)

**目的**:之後所有 `.properties` 裡的密碼都會被這把 master key 衍生的資料金鑰加密。master key 只放在 ops01(0600)與各節點的 `service.env`(root 0600),設定檔本身不含明文密碼。

**主機 / 帳號**:ops01,cpadmin。

**手動指令**:

```bash
$ install -d -m 0700 $S/secret-protection $S/cli-home
$ set -a; . $S/secrets.env; set +a
$ test -s $S/secret-protection/master.key && echo "已存在,不要重新產生" || \
  printf '%s' "$SECRET_MASTER_PASSPHRASE" | HOME=$S/cli-home confluent secret master-key generate \
    --local-secrets-file $S/secret-protection/master.secrets \
    --passphrase=- -o json \
  | jq -r .master_key > $S/secret-protection/master.key
$ chmod 0600 $S/secret-protection/master.key $S/secret-protection/master.secrets
```

`--passphrase=-` 讓 CLI 從 stdin 讀 passphrase(`SECRET_MASTER_PASSPHRASE`),不出現在指令列與 `ps`;全程實測採用此寫法。畫面會提示「Save the master key. It cannot be retrieved later.」,master key 已存到 `master.key`。

**驗證**:

```bash
$ ls -l $S/secret-protection/master.key $S/secret-protection/master.secrets
-rw------- 1 cpadmin cpadmin  45 ... master.key
-rw------- 1 cpadmin cpadmin 169 ... master.secrets
$ grep -o '^[^=]*' $S/secret-protection/master.secrets      # 只看 key 名稱
_metadata.master_key.0.salt
_metadata.symmetric_key.0.created_at
_metadata.symmetric_key.0.envvar
...
```

**對應 cpctl**:`sp::master_key`(lib/secretprotect.sh),在 `05_configure` 的 `step_apply` 開頭、平行設定之前呼叫一次(用 `flock` 避免平行工作產生兩把 key)。

**注意事項**:
- **master key 只能有一把**。重新產生 = 所有節點的 `security.properties` 都要重新加密、全部服務重啟。`master.key` 遺失而節點的 `service.env` 也沒了,密文就救不回來,只能從 `secrets.env` 重新加密。
- `master.secrets` 是每台節點 `security.properties` 的起始模板(內含加密過的資料金鑰,不含明文)。

### 4.2.2 派送憑證

**目的**:把 03_pki 產生的 keystore / truststore / MDS token 金鑰放到節點的 `/etc/confluent/ssl`,讓 `cp-kafka` 可讀、其他帳號不可讀。

**主機 / 帳號**:ops01 → 每台 controller / broker;節點上 root。

| 檔案 | controller | broker | 用途 |
|---|---|---|---|
| `ca.pem` | ✓ | ✓ | 內部 CA(bundle) |
| `truststore.p12` | ✓ | ✓ | 所有 TLS 連線的 truststore |
| `kafka-internal.p12` | ✓ | ✓ | 共用內部憑證(CN=kafka-internal,super user):CONTROLLER / INTERNAL listener、MDS client |
| `mds-token-keypair.enc.pem` | ✓ | ✓ | MDS 簽 token 的私鑰(已用 MDS_TOKEN_PASSPHRASE 加密) |
| `mds-public.pem` | ✓ | ✓ | 驗 token 的公鑰 |
| `cp-server.p12` | – | ✓ | 對外 listener(TOKEN/CLIENT/LDAP)與 MDS 的伺服器憑證 |

**手動指令**(以 kb01 為例;controller 去掉 `cp-server.p12`):

```bash
$ H=kb01.poc.lab
$ FILES="ca.pem truststore.p12 kafka-internal.p12 mds-token-keypair.enc.pem mds-public.pem cp-server.p12"
$ ssh $H "mkdir -p /tmp/cpssl && chmod 0700 /tmp/cpssl"
$ (cd $PKI && scp $FILES $H:/tmp/cpssl/)
$ ssh $H "sudo install -d -o root -g root -m 0755 /etc/confluent && \
          sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl && \
          for f in $FILES; do sudo install -o root -g confluent -m 0640 /tmp/cpssl/\$f /etc/confluent/ssl/\$f; done && \
          sudo rm -rf /tmp/cpssl /etc/confluent/ssl/mds-token-keypair.pem"
```

**驗證**:

```bash
$ ssh kb01.poc.lab "sudo stat -c '%U:%G %a %n' /etc/confluent/ssl /etc/confluent/ssl/*" | grep -v '\.bak\.'
root:confluent 750 /etc/confluent/ssl
root:confluent 640 /etc/confluent/ssl/ca.pem
root:confluent 640 /etc/confluent/ssl/cp-server.p12
root:confluent 640 /etc/confluent/ssl/kafka-internal.p12
root:confluent 640 /etc/confluent/ssl/mds-public.pem
root:confluent 640 /etc/confluent/ssl/mds-token-keypair.enc.pem
root:confluent 640 /etc/confluent/ssl/truststore.p12
$ ssh kb01.poc.lab "sudo -u cp-kafka head -c0 /etc/confluent/ssl/kafka-internal.p12 && echo readable-by-cp-kafka"
readable-by-cp-kafka
```

**對應 cpctl**:`role::push_ssl`(roles/_role.sh),由 `kafka::_configure` 呼叫;移除舊明文金鑰用 `ensure::absent`。

**注意事項**:
- 擁有者必須是 `root:confluent`、0640,目錄 `root:confluent` 0750。服務帳號 `cp-kafka` 屬於 `confluent` 群組才讀得到;若做成 `root:root` 0600,broker 啟動時會報 keystore 讀不到。
- 早期版本的明文 `mds-token-keypair.pem` 不可以留在節點上。
- cpctl 覆寫檔案前會留 `*.bak.<時間戳>`,手動做時建議也先備份。

### 4.2.3 產生 server.properties(明文,只在 ops01)

**目的**:依角色把 template + 共用 fragment 組成完整設定。cpctl 用 `envsubst` 代入 `${VAR}`,任何變數沒定義就直接中止,避免產生空白值。手動做時,可以照下列內容在 ops01 的 `$S/secret-protection/<host>/server.properties`(0600)寫出,再交給 5.4 加密。

**主機 / 帳號**:ops01,cpadmin。明文檔**不離開 ops01**。

```bash
$ H=kb01; install -d -m 0700 $S/secret-protection/$H
$ install -m 0600 /dev/null $S/secret-protection/$H/server.properties
$ vi $S/secret-protection/$H/server.properties      # 依下列內容填寫
```

也可以直接用 template 產生(需要先 export template 用到的所有變數):

```bash
# 例:檢查 template 用到哪些變數
$ grep -oh '\${[A-Za-z_][A-Za-z0-9_]*}' installer/templates/default/broker.properties.tpl \
    installer/templates/default/fragments/*.tpl | sort -u
```

broker 的 template 是 `templates/default/broker.properties.tpl`,controller 是 `controller.properties.tpl`;兩者都插入 fragment `common-server`、`audit`、`ldap`、`telemetry`(位於 `templates/default/fragments/`)。以下依主題分段列出 **kb01** 的實際內容(取自節點上的檔案,密碼改為佔位符)。

### 4.2.3.1 角色與 KRaft

```properties
process.roles=broker
node.id=101
broker.rack=rack-a
# 動態 quorum(KIP-853):只寫 bootstrap servers,不寫 controller.quorum.voters
controller.quorum.bootstrap.servers=kc01.poc.lab:9093,kc02.poc.lab:9093,kc04.poc.lab:9093
controller.listener.names=CONTROLLER
log.dirs=/var/lib/kafka/data
```

controller(以 kc01 為例):

```properties
process.roles=controller
node.id=1
controller.quorum.bootstrap.servers=kc01.poc.lab:9093,kc02.poc.lab:9093,kc04.poc.lab:9093
controller.listener.names=CONTROLLER
listeners=CONTROLLER://kc01.poc.lab:9093
advertised.listeners=CONTROLLER://kc01.poc.lab:9093
listener.security.protocol.map=CONTROLLER:SSL,INTERNAL:SSL
# Self-Balancing 在 active controller 上執行，經由這個 listener 名稱連到 broker（4.2.3.3 注意事項）
inter.broker.listener.name=INTERNAL
log.dirs=/var/lib/kafka/data
```

### 4.2.3.2 Listeners(broker)

| listener | port | protocol | 認證 | 用途 | keystore |
|---|---|---|---|---|---|
| CONTROLLER | 9093 | SSL | mTLS(kafka-internal) | controller 之間、broker → controller | kafka-internal.p12 |
| INTERNAL | 9092 | SSL | mTLS(kafka-internal) | broker 之間、管理工具 | kafka-internal.p12 |
| TOKEN | 9094 | SASL_SSL | OAUTHBEARER(MDS token) | C3、REST Proxy(impersonation) | cp-server.p12 |
| CLIENT | 9095 | SASL_SSL | SCRAM-SHA-512 | 應用程式、audit writer | cp-server.p12 |
| LDAP | 9096 | SASL_SSL | PLAIN → AD | 人員用 CLI | cp-server.p12 |
| MDS | 8090 | HTTPS | LDAP basic / token / client cert | RBAC、token 簽發 | cp-server.p12 |

```properties
listeners=INTERNAL://kb01.poc.lab:9092,TOKEN://kb01.poc.lab:9094,CLIENT://kb01.poc.lab:9095,LDAP://kb01.poc.lab:9096
advertised.listeners=INTERNAL://kb01.poc.lab:9092,TOKEN://kb01.poc.lab:9094,CLIENT://kb01.poc.lab:9095,LDAP://kb01.poc.lab:9096
listener.security.protocol.map=CONTROLLER:SSL,INTERNAL:SSL,TOKEN:SASL_SSL,CLIENT:SASL_SSL,LDAP:SASL_SSL
inter.broker.listener.name=INTERNAL
principal.builder.class=io.confluent.kafka.security.authenticator.OAuthKafkaPrincipalBuilder

# 對外 listener 用共用伺服器憑證,不要求 client 憑證(認證交給 SASL)
listener.name.token.ssl.keystore.type=PKCS12
listener.name.token.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
listener.name.token.ssl.keystore.password=<store-password>
listener.name.token.ssl.key.password=<store-password>
listener.name.token.ssl.client.auth=none
#   listener.name.client.ssl.* 與 listener.name.ldap.ssl.* 同上(5 行各一組)

# TOKEN:驗 MDS 簽發的 OAuth bearer token
listener.name.token.sasl.enabled.mechanisms=OAUTHBEARER
listener.name.token.oauthbearer.sasl.server.callback.handler.class=io.confluent.kafka.server.plugins.auth.token.TokenBearerValidatorCallbackHandler
listener.name.token.oauthbearer.sasl.login.callback.handler.class=io.confluent.kafka.server.plugins.auth.token.TokenBearerServerLoginCallbackHandler
listener.name.token.oauthbearer.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required publicKeyPath="/etc/confluent/ssl/mds-public.pem";
listener.name.token.principal.builder.class=io.confluent.kafka.security.authenticator.OAuthKafkaPrincipalBuilder

# CLIENT:SCRAM 帳密存在 KRaft metadata log
listener.name.client.sasl.enabled.mechanisms=SCRAM-SHA-512
listener.name.client.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required;

# LDAP:帳密交給 AD 驗證
listener.name.ldap.sasl.enabled.mechanisms=PLAIN
listener.name.ldap.plain.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required;
listener.name.ldap.plain.sasl.server.callback.handler.class=io.confluent.security.auth.provider.ldap.LdapAuthenticateCallbackHandler
```

### 4.2.3.3 TLS 預設與授權(common-server fragment,controller / broker 共用)

```properties
# 預設 TLS = 共用內部憑證(CONTROLLER / INTERNAL listener 用)
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
ssl.keystore.password=<store-password>
ssl.key.password=<store-password>
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ssl.truststore.password=<store-password>
ssl.client.auth=required
ssl.endpoint.identification.algorithm=https
ssl.enabled.protocols=TLSv1.3,TLSv1.2
# Java 以 RFC 2253 順序(C=..,O=..,CN=..)印 DN,所以 CN 可能在任何位置
ssl.principal.mapping.rules=RULE:.*CN=([a-zA-Z0-9._-]+).*$/$1/,DEFAULT

# 授權:RBAC(CONFLUENT)+ KRaft ACL
authorizer.class.name=io.confluent.kafka.security.authorizer.ConfluentServerAuthorizer
confluent.authorizer.access.rule.providers=KRAFT_ACL,CONFLUENT
super.users=User:kafka-internal;User:kafka-admin;User:svc-cpctl
allow.everyone.if.no.acl.found=false
confluent.metadata.server.token.key.path=/etc/confluent/ssl/mds-token-keypair.enc.pem
confluent.metadata.server.token.key.passphrase=<mds-token-passphrase>
confluent.metadata.topic.replication.factor=3

# License:conf/license.txt 為空 = 評估模式(只輸出一行註解);有授權時為 confluent.license=<license>
# confluent.license not set: evaluation mode (conf/license.txt is empty)
confluent.license.topic.replication.factor=3

# Self-Balancing Clusters
confluent.balancer.enable=true
confluent.balancer.topic.replication.factor=3
```

>! **Self-Balancing 要在 controller 設 `inter.broker.listener.name=INTERNAL`**（4.2.3.1）。KRaft 下 SBC 跑在 active controller，用這個 listener 名稱到 broker 的 metadata 找連線位址；沒設時預設是 `PLAINTEXT`，SBC 永遠停在 `STARTING`，`data-balancer.log` 出現 `Bootstrap server endpoint was not provided ... could not be found with a listener name ListenerName(PLAINTEXT)`。這個問題在 2026-10-18 才發現（之前的驗收沒有檢查 SBC 狀態），已補進手冊、cpctl 與 `cpctl verify`。
>
> 驗證（step 07 之後）：`kafka-rebalance-cluster --bootstrap-server "$B" --command-config "$CFG" --status` → `Balancer status: ENABLED`；`sudo grep 'transitioned from STARTING to RUNNING' /var/log/kafka/data-balancer.log`（active controller 上）。
>
> 已經在運作的叢集補正（每台 controller，再依 follower → leader 順序逐台重啟、每台等 lag 0）。Secret Protection 加密過的設定檔被改寫成 `key = value`（等號兩邊有空白），比對時要容許空白：
> `sudo sed -i -E 's/^listener\.security\.protocol\.map *= *CONTROLLER:SSL$/listener.security.protocol.map = CONTROLLER:SSL,INTERNAL:SSL\ninter.broker.listener.name = INTERNAL/' /etc/confluent/kafka/server.properties`

### 4.2.3.4 MDS(Metadata Service)

broker(MDS 本體,每台 broker 都跑):

```properties
confluent.metadata.server.listeners=https://0.0.0.0:8090
confluent.metadata.server.advertised.listeners=https://kb01.poc.lab:8090
confluent.metadata.server.ssl.keystore.type=PKCS12
confluent.metadata.server.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.metadata.server.ssl.keystore.password=<store-password>
confluent.metadata.server.ssl.key.password=<store-password>
confluent.metadata.server.ssl.truststore.type=PKCS12
confluent.metadata.server.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.server.ssl.truststore.password=<store-password>
# 人員用 LDAP basic auth、REST Proxy 可帶 client 憑證 → 兩種都接受
confluent.metadata.server.ssl.client.authentication=REQUESTED
confluent.metadata.server.auth.ssl.principal.mapping.rules=RULE:.*CN=([a-zA-Z0-9._-]+).*$/$1/,DEFAULT
confluent.metadata.server.authentication.method=BEARER
confluent.metadata.server.user.store=LDAP
confluent.metadata.server.token.signature.algorithm=RS256
confluent.metadata.server.token.max.lifetime.ms=3600000
# 只有 REST Proxy 可代替使用者操作;super user 與所有服務帳號永遠不能被代替
confluent.metadata.server.impersonation.super.users=User:svc-rest
confluent.metadata.server.impersonation.protected.users=User:kafka-internal;User:kafka-admin;User:svc-cpctl;User:svc-mds-bind;User:svc-rest;User:svc-c3;User:confluent-audit;User:opmenu-breakglass
```

`impersonation.protected.users` 由 cpctl 自動推導:`super.users` + `AD_SERVICE_ACCOUNTS` + `AUDIT_PRINCIPAL` + (OPMENU=on 時)`OPMENU_BREAKGLASS`,不要手動維護另一份清單。

controller(KRaft controller 上的 MDS 元件,從 broker 的 INTERNAL listener 讀 RBAC 資料):

```properties
confluent.metadata.server.kraft.controller.enabled=true
confluent.metadata.bootstrap.servers=kb01.poc.lab:9092,kb02.poc.lab:9092,kb03.poc.lab:9092,kb04.poc.lab:9092
confluent.metadata.security.protocol=SSL
confluent.metadata.ssl.keystore.type=PKCS12
confluent.metadata.ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
confluent.metadata.ssl.keystore.password=<store-password>
confluent.metadata.ssl.key.password=<store-password>
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=<store-password>
```

### 4.2.3.5 LDAP(ldap fragment,controller / broker 共用)

```properties
ldap.java.naming.factory.initial=com.sun.jndi.ldap.LdapCtxFactory
ldap.com.sun.jndi.ldap.connect.timeout=3000
ldap.com.sun.jndi.ldap.read.timeout=5000
# 多台 DC 以空白分隔,JNDI 依序 failover(AD_LDAP_HOSTS)
ldap.java.naming.provider.url=ldaps://ad01.poc.lab:636
# 群組成員快取每 60 秒更新;AD 連不上超過 retry timeout(1 天)後快取失效,群組授權會失敗
ldap.refresh.interval.ms=60000
ldap.retry.timeout.ms=86400000
ldap.java.naming.security.protocol=SSL
ldap.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ldap.ssl.truststore.password=<store-password>
ldap.ssl.truststore.type=PKCS12
ldap.java.naming.security.authentication=simple
ldap.java.naming.security.principal=CN=svc-mds-bind,OU=Service,OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.java.naming.security.credentials=<ldap-bind-password>
ldap.search.mode=GROUPS
ldap.user.search.base=OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.user.search.scope=2
ldap.user.object.class=user
ldap.user.name.attribute=sAMAccountName
ldap.group.search.base=OU=Groups,OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.group.search.scope=2
ldap.group.object.class=group
ldap.group.name.attribute=cn
ldap.group.member.attribute=member
ldap.group.member.attribute.pattern=CN=([^,]+),.*
```

### 4.2.3.6 叢集預設與副本數(只有 broker)

```properties
default.replication.factor=3
min.insync.replicas=2
num.partitions=3
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
unclean.leader.election.enable=false
auto.create.topics.enable=false
confluent.cluster.link.enable=false
```

### 4.2.3.7 Audit log(audit fragment,controller / broker 共用)

```properties
confluent.security.event.logger.enable=true
# 寫入者 = 專用低權限 SCRAM 帳號 confluent-audit,走 CLIENT listener(不用 broker 自己的身分)
confluent.security.event.logger.exporter.kafka.bootstrap.servers=kb01.poc.lab:9095,kb02.poc.lab:9095,kb03.poc.lab:9095,kb04.poc.lab:9095
confluent.security.event.logger.exporter.kafka.security.protocol=SASL_SSL
confluent.security.event.logger.exporter.kafka.sasl.mechanism=SCRAM-SHA-512
confluent.security.event.logger.exporter.kafka.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="confluent-audit" password="<audit-password>";
confluent.security.event.logger.exporter.kafka.ssl.truststore.type=PKCS12
confluent.security.event.logger.exporter.kafka.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.security.event.logger.exporter.kafka.ssl.truststore.password=<store-password>
confluent.security.event.logger.exporter.kafka.topic.replicas=3
# 90 天(AUDIT_RETENTION_DAYS × 86400000)
confluent.security.event.logger.exporter.kafka.topic.retention.ms=7776000000
# 路由(單行 JSON,由 conf/audit.env 產生):payments.* 的 produce/consume(允許+拒絕)與被拒絕的 describe
# 送到 _sensitive topic(保留 365 天);排除 kafka-internal 與 svc-c3 以控制量
confluent.security.event.router.config={"destinations":{"topics":{"confluent-audit-log-events":{"retention_ms":7776000000},"confluent-audit-log-events_sensitive":{"retention_ms":31536000000}}},"default_topics":{"allowed":"confluent-audit-log-events","denied":"confluent-audit-log-events"},"excluded_principals":["User:kafka-internal","User:svc-c3"],"routes":{"crn:///kafka=*/topic=payments.*":{"produce":{"allowed":"confluent-audit-log-events_sensitive","denied":"confluent-audit-log-events_sensitive"},"consume":{"allowed":"confluent-audit-log-events_sensitive","denied":"confluent-audit-log-events_sensitive"},"describe":{"allowed":"","denied":"confluent-audit-log-events_sensitive"}}}}
```

router JSON 也可用 jq 從 `audit.env` 產生(與 `role::audit_router_json` 相同邏輯),避免手打出錯。

### 4.2.3.8 Telemetry(送指標給 Control Center 的 Prometheus,controller / broker 共用)

```properties
metric.reporters=io.confluent.telemetry.reporter.TelemetryReporter
confluent.telemetry.exporter._c3.type=http
confluent.telemetry.exporter._c3.enabled=true
# 很長的 regex(單行),完整內容見附錄 D.1,原樣複製
confluent.telemetry.exporter._c3.metrics.include=<附錄 D.1 的完整 regex>
confluent.telemetry.exporter._c3.client.base.url=https://c3-01.poc.lab:9090/api/v1/otlp
confluent.telemetry.exporter._c3.client.compression=gzip
# Prometheus OTLP receiver 走 mTLS,不用 API key;值必須存在,填 dummy
confluent.telemetry.exporter._c3.api.key=dummy
confluent.telemetry.exporter._c3.api.secret=dummy
confluent.telemetry.exporter._c3.https.ssl.keystore.type=PKCS12
confluent.telemetry.exporter._c3.https.ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
confluent.telemetry.exporter._c3.https.ssl.keystore.password=<store-password>
confluent.telemetry.exporter._c3.https.ssl.key.password=<store-password>
confluent.telemetry.exporter._c3.https.ssl.truststore.type=PKCS12
confluent.telemetry.exporter._c3.https.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.telemetry.exporter._c3.https.ssl.truststore.password=<store-password>
confluent.telemetry.exporter._c3.https.ssl.protocol=TLSv1.3
confluent.telemetry.exporter._c3.buffer.pending.batches.max=80
confluent.telemetry.exporter._c3.buffer.batch.items.max=4000
confluent.telemetry.exporter._c3.buffer.inflight.submissions.max=10
confluent.telemetry.metrics.collector.interval.ms=60000
confluent.telemetry.remoteconfig._confluent.enabled=false
# 離線 / 銀行政策:不送任何資料給 Confluent(Health+ 關閉);上面的本地 _c3 exporter 不受影響
confluent.telemetry.enabled=false
confluent.consumer.lag.emitter.enabled=true
```

### 4.2.4 Secret Protection 加密與派送

**目的**:把明文 `server.properties` 中所有密碼欄位換成 `${securepass:...}` 參照,密文放在 `/etc/confluent/kafka/security.properties`;服務啟動時用環境變數 `CONFLUENT_SECURITY_MASTER_KEY` 解開。

**主機 / 帳號**:加密在 ops01(cpadmin);派送到節點以 root 安裝。

**要加密哪些 key**:規則與 `sp::keys` 相同 —— key 名稱結尾是 `password`、`credentials`、`passphrase`、`basic.auth.user.info`,以及 `sasl.jaas.config` 裡的 `password=`(寫成 `<key>/<LoginModule>/password`)。用下列 awk 從明文檔算出逗號分隔清單:

```bash
$ H=kb01; D=$S/secret-protection/$H
$ KEYS=$(awk -F= '
    /^[[:space:]]*#/ || !/=/ { next }
    { k=$1; gsub(/[[:space:]]/,"",k); v=substr($0,index($0,"=")+1)
      if (v ~ /^[[:space:]]*$/ || v ~ /\$\{securepass:/) next
      if (k ~ /(password|credentials|passphrase|basic\.auth\.user\.info)$/) { print k; next }
      if (k ~ /sasl\.jaas\.config$/ && v ~ /password=/) { split(v,w,/[[:space:]]+/); m=(w[1]==""?w[2]:w[1]); print k "/" m "/password" } }' \
    $D/server.properties | paste -sd, -)
$ echo "$KEYS" | tr , '\n'
```

kb01 的結果(20 個;controller 為 14 個,沒有 `listener.name.*` 與 `confluent.metadata.server.ssl.*`,多了 `confluent.metadata.ssl.*`):

```text
ssl.keystore.password
ssl.key.password
ssl.truststore.password
confluent.metadata.server.token.key.passphrase
confluent.security.event.logger.exporter.kafka.sasl.jaas.config/org.apache.kafka.common.security.scram.ScramLoginModule/password
confluent.security.event.logger.exporter.kafka.ssl.truststore.password
listener.name.token.ssl.keystore.password
listener.name.token.ssl.key.password
listener.name.client.ssl.keystore.password
listener.name.client.ssl.key.password
listener.name.ldap.ssl.keystore.password
listener.name.ldap.ssl.key.password
confluent.metadata.server.ssl.keystore.password
confluent.metadata.server.ssl.key.password
confluent.metadata.server.ssl.truststore.password
ldap.ssl.truststore.password
ldap.java.naming.security.credentials
confluent.telemetry.exporter._c3.https.ssl.keystore.password
confluent.telemetry.exporter._c3.https.ssl.key.password
confluent.telemetry.exporter._c3.https.ssl.truststore.password
```

**加密**(每台主機一次;`confluent secret file encrypt` 會**就地改寫** `--config-file`):

```bash
$ install -m 0600 $S/secret-protection/master.secrets $D/kafka.security.properties   # 以 master.secrets 為起點
$ CONFLUENT_SECURITY_MASTER_KEY=$(cat $S/secret-protection/master.key) \
  HOME=$S/cli-home confluent secret file encrypt \
    --config-file $D/server.properties \
    --local-secrets-file $D/kafka.security.properties \
    --remote-secrets-file /etc/confluent/kafka/security.properties \
    --config "$KEYS"
$ grep -c securepass $D/server.properties          # 必須 > 0
```

(cpctl 另外把加密前明文的 sha256 存成 `$D/server.properties.plain.sha256`,下次明文沒變就不重新加密。手動做時請在加密**前**自己記下:`sha256sum $D/server.properties | awk '{print $1}' > $D/server.properties.plain.sha256`。)

加密後 `server.properties` 的密碼欄位長這樣(檔案也會被改寫成 `key = value` 格式):

```properties
ssl.keystore.password = ${securepass:/etc/confluent/kafka/security.properties:server.properties/ssl.keystore.password}
confluent.security.event.logger.exporter.kafka.sasl.jaas.config = org.apache.kafka.common.security.scram.ScramLoginModule required username="confluent-audit" password=${securepass:/etc/confluent/kafka/security.properties:server.properties/confluent.security.event.logger.exporter.kafka.sasl.jaas.config/org.apache.kafka.common.security.scram.ScramLoginModule/password};
```

**派送**(三個檔案,擁有者與權限不同):

```bash
$ H=kb01; D=$S/secret-protection/$H
$ install -m 0600 /dev/null /tmp/service.env.$H && \
  printf 'CONFLUENT_SECURITY_MASTER_KEY=%s\n' "$(cat $S/secret-protection/master.key)" > /tmp/service.env.$H
$ ssh $H.poc.lab "mkdir -p /tmp/cpcfg && chmod 0700 /tmp/cpcfg"
$ scp $D/server.properties $D/kafka.security.properties $H.poc.lab:/tmp/cpcfg/
$ scp /tmp/service.env.$H $H.poc.lab:/tmp/cpcfg/service.env && rm -f /tmp/service.env.$H
$ ssh $H.poc.lab "sudo install -d -o root -g confluent -m 0750 /etc/confluent/kafka && \
    sudo install -o root -g confluent -m 0640 /tmp/cpcfg/server.properties /etc/confluent/kafka/server.properties && \
    sudo install -o root -g confluent -m 0640 /tmp/cpcfg/kafka.security.properties /etc/confluent/kafka/security.properties && \
    sudo install -o root -g root      -m 0600 /tmp/cpcfg/service.env /etc/confluent/kafka/service.env && \
    sudo rm -rf /tmp/cpcfg"
```

| 檔案 | 擁有者 | 權限 | 內容 |
|---|---|---|---|
| `/etc/confluent/kafka/server.properties` | root:confluent | 0640 | 加密後設定(只有 `${securepass:...}`) |
| `/etc/confluent/kafka/security.properties` | root:confluent | 0640 | 密文 + 加密的資料金鑰 |
| `/etc/confluent/kafka/service.env` | root:root | 0600 | `CONFLUENT_SECURITY_MASTER_KEY=<master-key>` |

**驗證**:

```bash
$ ssh kb01.poc.lab "sudo grep -ciE '(password|passphrase|credentials) *= *[^\$ ]' /etc/confluent/kafka/server.properties"
0                                   # 沒有任何明文密碼
$ ssh kb01.poc.lab "sudo grep -c securepass /etc/confluent/kafka/server.properties; sudo grep -c '^server.properties/' /etc/confluent/kafka/security.properties"
22
20
$ ssh kb01.poc.lab "sudo stat -c '%U:%G %a %n' /etc/confluent/kafka/server.properties /etc/confluent/kafka/security.properties /etc/confluent/kafka/service.env"
root:confluent 640 /etc/confluent/kafka/server.properties
root:confluent 640 /etc/confluent/kafka/security.properties
root:root 600 /etc/confluent/kafka/service.env
```

**對應 cpctl**:`role::push_properties` → `sp::push` → `sp::protect`、`sp::keys`、`sp::master_key`(lib/secretprotect.sh)。

**注意事項**:
- `service.env` 必須是 root 0600:systemd 以 root 讀 `EnvironmentFile` 後再切換成 cp-kafka,所以 cp-kafka 不需要(也不應該)能讀這個檔。
- 加密使用隨機 IV,同樣的明文每次加密結果都不同。cpctl 以明文的 sha256 快取結果(`server.properties.plain.sha256`),明文沒變就沿用舊密文,才不會每次跑都觸發重啟。手動做時同理:**沒改設定就不要重新加密**。
- 所有在節點上讀這個 `server.properties` 的工具(`kafka-storage format`、`kafka-metadata-quorum --command-config` 等)都需要 `CONFLUENT_SECURITY_MASTER_KEY`,見 4.3 與 4.5。
- `api.secret=dummy` 不符合加密規則(結尾不是 password),會以明文保留,這是預期的。
- 加密時的 `--remote-secrets-file` 必須是節點上的最終路徑,因為它會寫進每個 `${securepass:<路徑>:...}`。

### 4.2.5 JMX exporter(JMX_EXPORTER=on)

**目的**:讓行內 Prometheus 以 HTTPS + basic auth 抓 JVM / Kafka 指標(port 7071)。設定檔只放密碼的加鹽 SHA-256,不放明文抓取密碼。

**主機 / 帳號**:ops01 → 每台 controller / broker;root。

**手動指令**:

```bash
$ JAR=jmx_prometheus_javaagent-1.0.1.jar           # versions.env JMX_EXPORTER_VERSION=1.0.1
$ ls /srv/repo/raw/tools/$JAR                     # 內部 repo 必須已有這個 jar
$ test -s $S/jmx-exporter.salt || (openssl rand -hex 16 > $S/jmx-exporter.salt; chmod 0600 $S/jmx-exporter.salt)
$ SALT=$(cat $S/jmx-exporter.salt)
$ HASH=$(printf '%s:%s' "$SALT" '<jmx-exporter-password>' | sha256sum | awk '{print $1}')
```

`/etc/confluent/kafka/jmx-exporter.yml`(root:confluent 0640)= 下列標頭 + 附錄 D.2 的 `rules-kafka.yml` 原樣接在後面:

```yaml
httpServer:
  ssl:
    keyStore:
      filename: /etc/confluent/ssl/cp-server.p12     # controller 用 kafka-internal.p12
      password: <store-password>
      type: PKCS12
    certificate:
      alias: cp-server                               # controller 用 kafka-internal
  authentication:
    basic:
      username: prometheus
      passwordHash: <HASH>
      algorithm: SHA-256
      salt: <SALT>
lowercaseOutputName: true
lowercaseOutputLabelNames: true
# 以下接 rules-kafka.yml(includeObjectNames / excludeObjectNames / rules)
```

```bash
$ ssh kb01.poc.lab "sudo install -d -o root -g root -m 0755 /opt/jmx-exporter"
$ scp /srv/repo/raw/tools/$JAR kb01.poc.lab:/tmp/ && scp jmx-exporter.yml kb01.poc.lab:/tmp/
$ ssh kb01.poc.lab "sudo install -o root -g root -m 0644 /tmp/$JAR /opt/jmx-exporter/$JAR && \
    sudo install -o root -g confluent -m 0640 /tmp/jmx-exporter.yml /etc/confluent/kafka/jmx-exporter.yml && \
    sudo rm -f /tmp/$JAR /tmp/jmx-exporter.yml"
```

**驗證**(服務啟動後):

```bash
$ curl -s --cacert $PKI/ca.pem -u prometheus:'<jmx-exporter-password>' https://kb01.poc.lab:7071/metrics | grep -m1 '^jvm_'
$ curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem https://kb01.poc.lab:7071/metrics
401
```

**對應 cpctl**:`role::jmx_exporter`(roles/_role.sh)。

**注意事項**:
- controller 沒有 `cp-server.p12`,改用 `kafka-internal.p12`(其 SAN 已涵蓋 kc*)。
- salt 每個叢集固定一個(存在 `$S/jmx-exporter.salt`),換 salt 會讓所有節點的檔案改變而觸發重啟。
- 這個 YAML 內有 keystore 的明文密碼(JMX exporter 不支援 securepass),所以必須維持 root:confluent 0640。

### 4.2.6 systemd drop-in

**目的**:不改 RPM 提供的 `confluent-server.service`,用 drop-in 指定設定檔路徑、JAVA_HOME、heap、log4j2、JMX javaagent,以及載入 master key 的 `service.env`。

**主機 / 帳號**:每台 controller / broker;root。

`/etc/systemd/system/confluent-server.service.d/10-cpctl.conf`(root:root 0644),kb01 的實際內容:

```ini
# Managed by cpctl - drop-in for the RPM-provided confluent-server.service
[Service]
ExecStart=
ExecStart=/usr/bin/kafka-server-start /etc/confluent/kafka/server.properties
Environment="JAVA_HOME=/usr/lib/jvm/temurin-21-jdk"
Environment="KAFKA_HEAP_OPTS=-Xms512m -Xmx512m"
Environment="KAFKA_LOG4J_OPTS=-Dlog4j2.configurationFile=/etc/kafka/log4j2.yaml"
Environment="LOG_DIR=/var/log/kafka"
Environment="KAFKA_OPTS=-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar=7071:/etc/confluent/kafka/jmx-exporter.yml"
EnvironmentFile=-/etc/confluent/kafka/service.env
LimitNOFILE=128000
TimeoutStopSec=180
Restart=on-failure
RestartSec=10
```

controller 只差 heap(`-Xms384m -Xmx384m`)。`JMX_EXPORTER=off` 時 `KAFKA_OPTS=` 為空字串。

```bash
$ ssh kb01.poc.lab "sudo install -d -o root -g root -m 0755 /etc/systemd/system/confluent-server.service.d"
$ scp 10-cpctl.conf kb01.poc.lab:/tmp/
$ ssh kb01.poc.lab "sudo install -o root -g root -m 0644 /tmp/10-cpctl.conf /etc/systemd/system/confluent-server.service.d/10-cpctl.conf && \
    sudo rm -f /tmp/10-cpctl.conf && sudo systemctl daemon-reload"
```

**驗證**:

```bash
$ ssh kb01.poc.lab "systemctl cat confluent-server | grep -E '^# /|ExecStart=/|EnvironmentFile'"
# /usr/lib/systemd/system/confluent-server.service
# /etc/systemd/system/confluent-server.service.d/10-cpctl.conf
ExecStart=/usr/bin/kafka-server-start /etc/confluent/kafka/server.properties
EnvironmentFile=-/etc/confluent/kafka/service.env
```

**對應 cpctl**:`role::systemd_dropin`(roles/_role.sh),template `templates/default/systemd/kafka-override.conf.tpl`。

**注意事項**:
- 第一行空的 `ExecStart=` 是必要的,用來清掉 RPM unit 原本的 ExecStart,否則 systemd 會報「有多個 ExecStart」。
- `EnvironmentFile=-` 的 `-` 代表檔案不存在也不報錯;但 Secret Protection 開啟時少了 `service.env`,服務會因為解不開 `${securepass:...}` 而啟動失敗。
- 改完 drop-in 一定要 `systemctl daemon-reload`。tar.gz 安裝方式的 unit 不同(`templates/default/systemd/tar/`)。

### 4.2.7 資料目錄

```bash
$ ssh kb01.poc.lab "sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka/data"
$ ssh kb01.poc.lab "sudo stat -c '%U:%G %a %n' /var/lib/kafka /var/lib/kafka/data"
cp-kafka:confluent 750 /var/lib/kafka
cp-kafka:confluent 750 /var/lib/kafka/data
```

對應 cpctl:`kafka::_configure` 中的 `ensure::dir /var/lib/kafka/data cp-kafka confluent 0750`。

### 4.2.8 已在執行的服務:滾動重啟

第一次安裝時服務還沒啟動,這一步不用做。之後若改了設定(任何一個檔案內容有變),**一次一台**重啟,順序 controller → broker,每台都等健康檢查通過(4.4.3、4.4.5)再做下一台:

```bash
$ for h in kc01 kc02 kc04; do ssh $h.poc.lab "sudo systemctl restart confluent-server"; <等 4.4.3 的 lag 0>; done
$ for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab "sudo systemctl restart confluent-server"; <等 4.4.5 的 under-replicated 為空>; done
```

對應 cpctl:`handler::notify`(記在 `$S/handlers.pending`)與 `handler::flush`(lib/handler.sh)。

### 4.2.9 本步驟的整體驗證

```bash
$ for h in kc01 kc02 kc04 kb01 kb02 kb03 kb04; do ssh $h.poc.lab "sudo test -s /etc/confluent/kafka/server.properties && echo $h ok"; done
```

對應 cpctl:`05_configure` 的 `step_verify`。

## 4.3 步驟 06:KRaft 儲存格式化(06_kraft_format)

**目的**:在每個節點的 `/var/lib/kafka/data` 寫入 `meta.properties`(cluster.id、node.id、directory.id)。controller 以**動態 quorum**(KIP-853,`kraft.version=1`)格式化,初始 voter 為 1、2、4;同時寫入兩個 SCRAM 帳號 `kafka-admin`(break-glass 管理員)與 `confluent-audit`(audit writer)。broker 只格式化為 observer。

### 4.3.1 產生 cluster id 與 directory id(ops01,只做一次)

**主機 / 帳號**:ops01,cpadmin。

```bash
$ test -f $S/kraft.env && echo "已存在,沿用" || {
    install -m 0600 /dev/null $S/kraft.env
    echo "CLUSTER_ID=$(kafka-storage random-uuid)" >> $S/kraft.env
    for h in kc01 kc02 kc04 kc03; do echo "DIR_ID_$h=$(kafka-storage random-uuid)" >> $S/kraft.env; done
  }
$ . $S/kraft.env
$ INITIAL="1@kc01.poc.lab:9093:$DIR_ID_kc01,2@kc02.poc.lab:9093:$DIR_ID_kc02,4@kc04.poc.lab:9093:$DIR_ID_kc04"
$ echo "$CLUSTER_ID  $INITIAL"
```

格式:`<node.id>@<host>:<port>:<directory.id>`,以逗號分隔。PoC 的 cluster id 為 `jjRYywATQBGIf11rBTcNGg`。

**對應 cpctl**:`kraft::ids`、`kraft::initial_controllers`(steps/06_kraft_format.sh)。

**注意事項**:`kraft.env` 產生一次後**永遠沿用**。重新產生 cluster id 等於另一個叢集,已格式化的節點會全部拒絕(見 4.3.4)。備用 controller kc03 的 directory id 也預先產生,但不放進 `--initial-controllers`。

### 4.3.2 格式化 controller(kc01、kc02、kc04)

**主機 / 帳號**:每台 controller;以 **cp-kafka** 執行 `kafka-storage`(資料目錄的擁有者),root 負責讀 `service.env`。

**手動指令**(以 kc01 為例;先確認尚未格式化):

```bash
$ ssh kc01.poc.lab "sudo cat /var/lib/kafka/data/meta.properties 2>/dev/null || echo NOT-FORMATTED"
NOT-FORMATTED
$ ssh kc01.poc.lab "sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka/data"
$  ssh kc01.poc.lab "sudo bash -c \"set -a; . /etc/confluent/kafka/service.env; set +a; \
    sudo -u cp-kafka --preserve-env=CONFLUENT_SECURITY_MASTER_KEY env JAVA_HOME=/usr/lib/jvm/temurin-21-jdk KAFKA_HEAP_OPTS=-Xmx256m \
    KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
    /usr/bin/kafka-storage format --cluster-id $CLUSTER_ID --config /etc/confluent/kafka/server.properties \
      --initial-controllers '$INITIAL' \
      --add-scram 'SCRAM-SHA-512=[name=kafka-admin,password=<kafka-admin-password>]' \
      --add-scram 'SCRAM-SHA-512=[name=confluent-audit,password=<audit-password>]' \
    | grep -vi scram\""
Formatting dynamic metadata voter directory /var/lib/kafka/data with confluent.metadata.version 4.3-IV0B.
```

(controller 帶 `--initial-controllers` 時訊息是「dynamic metadata voter directory」;broker 與之後新增的 controller 用 `--no-initial-controllers`,訊息是「metadata directory」。)

kc02、kc04 用**完全相同**的 `$CLUSTER_ID`、`$INITIAL` 與 `--add-scram`。指令開頭多一個空白是刻意的(搭配 `HISTCONTROL=ignorespace`,含密碼的指令不進 history)。`$CLUSTER_ID`、`$INITIAL` 在 ops01 端展開後才送到節點。

**對應 cpctl**:`kraft::format_controller` → 節點端 `kafka_node::format`(lib/node/kafka.sh)。

### 4.3.3 格式化 broker(kb01–kb04)

```bash
$ ssh kb01.poc.lab "sudo bash -c \"set -a; . /etc/confluent/kafka/service.env; set +a; \
    sudo -u cp-kafka --preserve-env=CONFLUENT_SECURITY_MASTER_KEY env JAVA_HOME=/usr/lib/jvm/temurin-21-jdk KAFKA_HEAP_OPTS=-Xmx256m \
    KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
    /usr/bin/kafka-storage format --cluster-id $CLUSTER_ID --config /etc/confluent/kafka/server.properties --no-initial-controllers\""
```

**對應 cpctl**:`kraft::format_broker` → `kafka_node::format`。

### 4.3.4 驗證與冪等

```bash
$ for h in kc01 kc02 kc04 kb01 kb02 kb03 kb04; do
    printf '%s ' $h; ssh $h.poc.lab "sudo sed -n 's/^\(cluster.id\|node.id\|directory.id\)=//p' /var/lib/kafka/data/meta.properties | paste -sd' '"
  done
kc01 jjRYywATQBGIf11rBTcNGg yWE5-5XwTFmNSxtKslzuyA 1
kb01 jjRYywATQBGIf11rBTcNGg bgR7F3SPIqBlfYeT64moTg 101
...
```

kc01 的 `meta.properties` 實際內容:

```properties
cluster.id=jjRYywATQBGIf11rBTcNGg
directory.id=yWE5-5XwTFmNSxtKslzuyA
node.id=1
version=1
```

預期:所有節點 `cluster.id` 相同;controller 的 `directory.id` 等於 `kraft.env` 中對應的 `DIR_ID_<host>`;檔案擁有者為 cp-kafka。

冪等規則(與 `kafka_node::format` 相同):

| meta.properties | 動作 |
|---|---|
| 不存在 | 執行 format |
| 存在且 cluster.id 相同 | 不動(已格式化) |
| 存在但 cluster.id 不同 | **停止**,不要重新格式化;先查清楚為什麼 |

對已格式化的目錄再跑 format 會得到 `Log directory /var/lib/kafka/data is already formatted. Use --ignore-formatted ...`,不要加 `--ignore-formatted` 硬做。

**對應 cpctl**:`06_kraft_format` 的 `step_verify`(用 `kafka_node::meta cluster.id` 比對)。

**注意事項**:
- `kafka-storage` 必須以 **cp-kafka** 執行;以 root 執行會讓 `meta.properties` 與 bootstrap checkpoint 變成 root 擁有,broker 啟動時寫不進去。
- 設定檔含 `${securepass:...}`,`kafka-storage` 也要解密,所以要帶 `CONFLUENT_SECURITY_MASTER_KEY`。上面的寫法由 root 讀 `service.env` 後,用 `--preserve-env` 傳給 cp-kafka,master key 不會出現在指令列。(cpctl 也是這樣做;2026-10-16 之前的版本是以 `env CONFLUENT_SECURITY_MASTER_KEY=...` 帶入,執行瞬間會出現在 `ps`。)
- `--add-scram` 的密碼會出現在指令列與 `ps`;指令前加空白避免進 history,並在 PoC 以外改用專用的一次性 shell。cpctl 會用 `grep -vi scram` 把含 SCRAM 的輸出行濾掉。
- `--add-scram` 只在 controller 格式化時有意義(寫進 bootstrap metadata);叢集起來後再新增 SCRAM 帳號要用 `kafka-configs --alter --add-config SCRAM-SHA-512=...`(步驟 08)。
- 使用 `--initial-controllers` 格式化後 `kraft.version` 為 1(動態 quorum),**不能降回 0**(靜態 `controller.quorum.voters`)。所有 controller 的 `--initial-controllers` 字串必須完全一致。
- 格式化前 5.x 的設定必須已派送完成(`kafka-storage` 會讀 `server.properties` 的 `node.id`、`log.dirs`、`process.roles`)。

## 4.4 步驟 07:啟動核心(07_start_core)

**目的**:先啟動三台 controller 形成 quorum,確認每個 voter 都跟上(lag 0)後,再啟動四台 broker,確認每台都已註冊、未被 fence、MDS 有回應、沒有 under-replicated partition。

### 4.4.1 啟動 controller

**主機 / 帳號**:kc01、kc02、kc04;root(systemctl)。三台**同時**啟動(單獨一台選不出 leader)。

```bash
$ for h in kc01 kc02 kc04; do ssh $h.poc.lab "sudo systemctl enable -q confluent-server && sudo systemctl start confluent-server" & done; wait
```

**對應 cpctl**:`role::controller::start` → `role::svc_start`(`svc::enable` + `svc::start`,已在跑就不動)。

### 4.4.2 controller 健康檢查(ops01)

```bash
# 1) port 9093 開了(每台最多等 180 秒)
$ for h in kc01 kc02 kc04; do timeout 3 bash -c "exec 3<>/dev/tcp/$h.poc.lab/9093" && echo "$h 9093 open"; done
# 2) quorum 狀態
$ kafka-metadata-quorum --bootstrap-controller $CB --command-config $ADMIN_CFG describe --status
ClusterId:              jjRYywATQBGIf11rBTcNGg
LeaderId:               4
LeaderEpoch:            29
HighWatermark:          227223
MaxFollowerLag:         0
MaxFollowerLagTimeMs:   366
CurrentVoters:          [{"id": 1, "directoryId": "yWE5-5XwTFmNSxtKslzuyA", "endpoints": ["CONTROLLER://kc01.poc.lab:9093"]}, {"id": 2, ...}, {"id": 4, ...}]
CurrentObservers:       [...]
```

### 4.4.3 每個 voter 都跟上(lag 0)

```bash
$ kafka-metadata-quorum --bootstrap-controller $CB --command-config $ADMIN_CFG describe --replication
NodeId	DirectoryId           	LogEndOffset	Lag	LastFetchTimestamp	LastCaughtUpTimestamp	Status
4     	gIrea9u4RGOZQU1Xn1JJAw	227235      	0  	...	...	Leader
1     	yWE5-5XwTFmNSxtKslzuyA	227235      	0  	...	...	Follower
2     	fiI33QRPTKa8xDvu6kCPmw	227235      	0  	...	...	Follower
```

判斷方式(與 cpctl 相同):對每個 node.id,第 4 欄 `Lag` 為 0 且最後一欄是 `Leader` 或 `Follower`:

```bash
$ for id in 1 2 4; do kafka-metadata-quorum --bootstrap-controller $CB --command-config $ADMIN_CFG describe --replication \
    | awk -v id=$id '$1==id && ($NF=="Leader"||$NF=="Follower") && $4+0==0 {ok=1} END {print id, (ok?"caught-up":"NOT-READY")}'; done
1 caught-up
2 caught-up
4 caught-up
```

再確認動態 quorum:

```bash
$ kafka-features --bootstrap-controller $CB --command-config $ADMIN_CFG describe | grep kraft.version
Feature: kraft.version   SupportedMinVersion: 0   SupportedMaxVersion: 1   FinalizedVersionLevel: 1   Epoch: ...
```

**對應 cpctl**:`role::controller::health` → `health::tcp`、`kafka::_controller_caught_up`(每台最多等 240 秒)。

### 4.4.4 啟動 broker

controller 全部 caught-up 後才做:

```bash
$ for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab "sudo systemctl enable -q confluent-server && sudo systemctl start confluent-server" & done; wait
```

**對應 cpctl**:`role::broker::start`。

### 4.4.5 broker 健康檢查(ops01)

```bash
# 1) INTERNAL 9092 與 MDS 8090 開了(各最多等 240 秒)
$ for h in kb01 kb02 kb03 kb04; do for p in 9092 8090; do timeout 3 bash -c "exec 3<>/dev/tcp/$h.poc.lab/$p" && echo "$h $p open"; done; done

# 2) 每台 broker 都註冊且未被 fence
$ kafka-broker-api-versions --bootstrap-server $BI --command-config $ADMIN_CFG | grep '(id:'
kb01.poc.lab:9092 (id: 101 rack: rack-a isFenced: false) -> (
kb02.poc.lab:9092 (id: 102 rack: rack-a isFenced: false) -> (
kb04.poc.lab:9092 (id: 104 rack: rack-b isFenced: false) -> (
kb03.poc.lab:9092 (id: 103 rack: rack-b isFenced: false) -> (

# 3) 沒有 under-replicated partition(輸出必須是空的)
$ kafka-topics --bootstrap-server $BI --command-config $ADMIN_CFG --describe --under-replicated-partitions

# 4) broker 出現在 quorum 的 observer
$ kafka-metadata-quorum --bootstrap-controller $CB --command-config $ADMIN_CFG describe --replication | awk '$NF=="Observer"'
104   6oFCjuQum6rqO-jKWqzqIQ   227235   0   ...   Observer
...
```

MDS 回應(不需認證):

```bash
$ curl -s --cacert $PKI/ca.pem https://kb01.poc.lab:8090/v1/metadata/id
{"id":"jjRYywATQBGIf11rBTcNGg","scope":{"path":[],"clusters":{"kafka-cluster":"jjRYywATQBGIf11rBTcNGg"}}}
```

MDS 叢集成員(需要認證,未認證回 401;以 AD 使用者互動輸入密碼):

```bash
$ curl -s --cacert $PKI/ca.pem -u alice https://kb01.poc.lab:8090/security/1.0/activenodes/https
Enter host password for user 'alice': <password>
["https://kb01.poc.lab:8090","https://kb02.poc.lab:8090","https://kb03.poc.lab:8090","https://kb04.poc.lab:8090"]
```

全程實測結果:帶 alice 帳密回 200 與上面的 JSON,未帶帳密回 401。此時還沒有任何 role binding(08 才建),可見這個查詢只需要通過 AD 認證。不想互動輸入時,可把帳密寫進 0600 的 netrc 檔:`printf 'machine kb01.poc.lab login alice password %s\n' "$HUMAN_DEFAULT_PASSWORD" > ~/.netrc-alice`,再用 `curl --netrc-file ~/.netrc-alice ...`,用完刪除。

**對應 cpctl**:`role::broker::health` → `health::tcp`、`kafka::_broker_healthy`(broker-api-versions 找 `(id: <id> rack`、under-replicated 為空;最多等 300 秒)。`07_start_core` 的 `step_verify` 再檢查一次 quorum 有 `LeaderId:` 與每台 broker 健康。`/v1/metadata/id` 與 `activenodes` 不在 07 的 gate 內(cpctl 只檢查 8090 port),是手動時建議加做的檢查。

**注意事項**:
- broker 早於 controller 啟動不會壞,但會一直重試連 controller;依順序做才容易判斷問題在哪一層。
- 第一次啟動時 under-replicated 檢查可能短暫不為空(內部 topic 正在建立),等它清空即可。
- 這時 RBAC 還沒有任何 role binding(步驟 08 才建),只有 `super.users` 能操作;`alice` 打 `activenodes` 若回 403,先改用 08 之後再測。
- 啟動失敗先看 `journalctl -u confluent-server -n 100` 與 `/var/log/kafka/server.log`;常見原因:`service.env` 不存在(securepass 解不開)、檔案權限讓 cp-kafka 讀不到、`meta.properties` 的 node.id 與設定不符。

## 4.5 Controller 的新增與移除(cpctl controller add | remove | replace)

動態 quorum 下 voter 的增減是線上操作,不必停叢集。原則:**一次只變動一個 voter**,每次變動後等 lag 0 再做下一步;替換時「先加後減」(暫時 4 個 voter,多數為 3),不要先減成 2 個。

### 4.5.1 新增 controller(以備用機 kc03,node.id 3 為例)

**目的**:讓新節點先以 observer 身分加入並追上 metadata log,再由它自己發出 `add-controller` 成為 voter。

**主機 / 帳號**:ops01(cpadmin)準備與檢查;kc03 上 root / cp-kafka 執行。

**手動指令**:

1. 安裝套件與信任內部 CA(同步驟 02、03;JDK truststore 匯入 `ca.pem`)。
2. 依 5.2–5.7 為 kc03 產生並派送設定(`node.id=3`,`listeners=CONTROLLER://kc03.poc.lab:9093`)。`controller.quorum.bootstrap.servers` 維持現有 voter `kc01,kc02,kc04` 即可。
3. 以 observer 格式化(**不帶** `--initial-controllers`,也不需要 `--add-scram`),然後啟動:

```bash
$ ssh kc03.poc.lab "sudo bash -c \"set -a; . /etc/confluent/kafka/service.env; set +a; \
    sudo -u cp-kafka --preserve-env=CONFLUENT_SECURITY_MASTER_KEY env JAVA_HOME=/usr/lib/jvm/temurin-21-jdk KAFKA_HEAP_OPTS=-Xmx256m \
    KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
    kafka-storage format --cluster-id $CLUSTER_ID --config /etc/confluent/kafka/server.properties --no-initial-controllers\""
Formatting metadata directory /var/lib/kafka/data with confluent.metadata.version 4.3-IV0B.
$ ssh kc03.poc.lab "sudo systemctl enable -q confluent-server && sudo systemctl start confluent-server"
```

4. 等 kc03 以 observer 追上(Status=Observer、Lag=0,最多約 5 分鐘):

```bash
$ kafka-metadata-quorum --bootstrap-controller $CB --command-config $ADMIN_CFG describe --replication | awk '$1==3'
3     	QZR-4oqubnW7p4s1HjNfEQ	224393      	0  	...	...	Observer
```

5. 在 kc03 **本機**建立 `add-controller.properties` = 自己的 `server.properties` + `security.protocol=SSL`,再以 cp-kafka 執行 `add-controller`:

```bash
$ ssh kc03.poc.lab "sudo cp /etc/confluent/kafka/server.properties /etc/confluent/kafka/add-controller.properties && \
    echo security.protocol=SSL | sudo tee -a /etc/confluent/kafka/add-controller.properties >/dev/null && \
    sudo chown root:confluent /etc/confluent/kafka/add-controller.properties && \
    sudo chmod 0640 /etc/confluent/kafka/add-controller.properties"
$ ssh kc03.poc.lab "sudo bash -c \"set -a; . /etc/confluent/kafka/service.env; set +a; \
    sudo -u cp-kafka --preserve-env=CONFLUENT_SECURITY_MASTER_KEY env JAVA_HOME=/usr/lib/jvm/temurin-21-jdk KAFKA_HEAP_OPTS=-Xmx256m \
    KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
    kafka-metadata-quorum --command-config /etc/confluent/kafka/add-controller.properties \
      --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc04.poc.lab:9093 add-controller\""
Added controller 3 with directory id QZR-4oqubnW7p4s1HjNfEQ and endpoints: CONTROLLER://kc03.poc.lab:9093
```

輸出前可能有一行 `WARN Validation failed for class io.confluent.telemetry.provider.KafkaClientProvider`,可忽略(admin client 讀到 broker 端的 telemetry 設定)。

**驗證**:

```bash
$ kafka-metadata-quorum --bootstrap-controller $CB --command-config $ADMIN_CFG describe --replication | awk '$NF!="Observer"'
NodeId	DirectoryId           	LogEndOffset	Lag	...	Status
1     	yWE5-5XwTFmNSxtKslzuyA	224435      	0  	...	Leader
2     	fiI33QRPTKa8xDvu6kCPmw	224435      	0  	...	Follower
3     	QZR-4oqubnW7p4s1HjNfEQ	224435      	0  	...	Follower
4     	gIrea9u4RGOZQU1Xn1JJAw	224435      	0  	...	Follower
```

6. 永久保留新 voter 時:把 `conf/inventory.env` 的 `HOSTS_controller` 改成包含 kc03,重新產生並派送**所有**節點的設定(步驟 05,主要是 `controller.quorum.bootstrap.servers`),再依 5.8 滾動重啟。

**對應 cpctl**:`cpctl controller add --host kc03` → `ctl::add`、`ctl::observer_caught_up`、`ctl::node_command_config`、`ctl::is_voter`(installer/upgrade/controller.sh)。

**注意事項**:
- `add-controller` **必須在新節點上**用它自己的設定執行:工具從 `--command-config` 讀 `node.id`、`controller.listener.names`、`advertised.listeners`,並從 `log.dirs` 的 `meta.properties` 讀 directory id。在 ops01 執行會加錯節點或失敗。
- 補 `security.protocol=SSL` 是因為 controller 的設定裡沒有這個 client 參數(只有 `listener.security.protocol.map`),admin client 預設會用 PLAINTEXT 連 9093 而失敗。
- 複製出來的設定含 `${securepass:...}`,所以同樣要帶 master key;`add-controller.properties` 維持 root:confluent 0640。
- 必須等 observer lag 0 才 add,否則新 voter 拖慢 commit。

### 4.5.2 移除 controller

**目的**:把某個 voter 移出 quorum(例如要汰換硬體),之後才能安全停機。

**主機 / 帳號**:ops01(cpadmin)發出 remove;被移除的節點以 root 停服務。

```bash
# 1) 找出要移除節點的 directory id(第 2 欄)
$ DIR=$(kafka-metadata-quorum --bootstrap-controller $CB --command-config $ADMIN_CFG describe --replication | awk '$1==3 {print $2; exit}')
$ echo $DIR
QZR-4oqubnW7p4s1HjNfEQ
# 2) 移除 voter
$ kafka-metadata-quorum --bootstrap-controller $CB --command-config $ADMIN_CFG \
    remove-controller --controller-id 3 --controller-directory-id $DIR
Removed  KRaft controller 3 with directory id QZR-4oqubnW7p4s1HjNfEQ
# 3) 確認已不是 voter(最多等 120 秒),再停機
$ kafka-metadata-quorum --bootstrap-controller $CB --command-config $ADMIN_CFG describe --replication \
    | awk '$1==3 && ($NF=="Leader"||$NF=="Follower")' | wc -l
0
$ ssh kc03.poc.lab "sudo systemctl disable -q --now confluent-server"
```

**對應 cpctl**:`cpctl controller remove --host kc03` → `ctl::remove`、`ctl::dir_id`、`ctl::not_voter`。

**注意事項**:
- `--controller-directory-id` 必須是**目前 voter 的那一個**。同一個 node.id 可能出現多列(例如節點重新格式化過、舊的 observer 紀錄尚未消失,PoC 的 kc03 目前就看得到兩列 `3`),要取 Status 為 Leader / Follower 的那一列,不要取 Observer 列。
- 剩下的 voter 數不可低於能維持多數的數量;3 → 2 時再壞一台就失去 quorum。替換請用「先加後減」:`cpctl controller replace --host <新> --old <舊>`。
- 被移除的節點若要再加回來,先清空 `/var/lib/kafka/data`(`sudo find /var/lib/kafka/data -mindepth 1 -delete`),重新以 `--no-initial-controllers` 格式化(會得到新的 directory id),再走 8.1。
- 移除後同樣要更新 `HOSTS_controller` 並重跑步驟 05,讓所有節點的 `controller.quorum.bootstrap.servers` 不再列出它。
- 動態 quorum 的 add / remove 只在 `kraft.version=1` 時可用;以靜態 `controller.quorum.voters` 建立的叢集不能這樣做。

# 5. 安全設定、邊緣元件與驗收(步驟 08–10)

> 對象：Confluent Platform 8.3.2 離線安裝 PoC（INSTALL_METHOD=rpm、PROFILE=poc、SECRET_PROTECTION=on、JMX_EXPORTER=on、OPMENU=on）。
> 所有值取自 `installer/conf/*.env` 與容器內實際產生的檔案；密碼一律寫成 `<password>`，請從保管庫（vault）取得，**不要**寫進 shell history。
> 以下指令都不經過 cpctl；括號中的「對應 cpctl」只是讓您對照原始碼。

## 5.0 共通前提

| 項目 | 值 |
|---|---|
| 操作主機 | `ops01.poc.lab`，帳號 `cpadmin`（cpctl 的狀態目錄 `/var/lib/cp-installer` 為 `cpadmin:cpadmin 0750`，`pki/` 為 0700） |
| 遠端執行方式 | cpctl 以 `ssh cpadmin@<fqdn>` 登入節點，再 `sudo bash -s`（root）執行節點端函式。手動時請在節點上 `sudo -i` 變成 root 再操作 |
| Cluster ID | `jjRYywATQBGIf11rBTcNGg`（`/var/lib/cp-installer/kraft.env` 的 `CLUSTER_ID`） |
| Broker INTERNAL（mTLS, 9092） | `kb01.poc.lab:9092,kb02.poc.lab:9092,kb03.poc.lab:9092,kb04.poc.lab:9092` |
| Broker CLIENT（SCRAM, 9095）/ LDAP（PLAIN→AD, 9096）/ TOKEN（OAUTHBEARER, 9094） | 同上主機，各換埠號 |
| Controller（9093） | `kc01.poc.lab:9093,kc02.poc.lab:9093,kc04.poc.lab:9093` |
| MDS | `https://kb01.poc.lab:8090,...,https://kb04.poc.lab:8090` |
| PKI 目錄（ops01） | `/var/lib/cp-installer/pki`（`ca.pem` 信任鏈、`kafka-internal.*`、`cp-server.*`、`app-legacy-billing.*`、`opmenu-breakglass.*`、`truststore.p12`） |

在 ops01 上，先設定一次 CLI 環境（之後的 Kafka 工具指令都假設已執行）：

```bash
# ops01, cpadmin
export JAVA_HOME=/usr/lib/jvm/temurin-21-jdk
export KAFKA_HEAP_OPTS=-Xmx256m
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml   # 工具專用 log4j，避免寫進 broker log
export B=kb01.poc.lab:9092,kb02.poc.lab:9092,kb03.poc.lab:9092,kb04.poc.lab:9092
export CB=kc01.poc.lab:9093,kc02.poc.lab:9093,kc04.poc.lab:9093
export CFG=/var/lib/cp-installer/client/internal.properties
export PKI=/var/lib/cp-installer/pki
export CID=jjRYywATQBGIf11rBTcNGg
export MDS=https://kb01.poc.lab:8090
```

`$CFG`（管理用 client 設定，super user `User:kafka-internal`，0600；cpctl 在 `kafka::admin_config` 第一次需要時才產生）：

```properties
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=/var/lib/cp-installer/pki/kafka-internal.p12
# 以下 <password> 都是 STORE_PASSWORD
ssl.keystore.password=<password>
ssl.key.password=<password>
ssl.truststore.type=PKCS12
ssl.truststore.location=/var/lib/cp-installer/pki/truststore.p12
ssl.truststore.password=<password>
ssl.endpoint.identification.algorithm=https
```

手動推檔的慣例（等同 cpctl 的 `remote::put` + `ensure::file`）：先 `scp` 到節點 `/tmp`，比對 sha256，不同時先備份 `<檔名>.bak.YYYYmmddHHMMSS` 再 `install -o <owner> -g <group> -m <mode>`：

```bash
scp ./file cpadmin@<host>.poc.lab:/tmp/file.new
ssh cpadmin@<host>.poc.lab 'sudo bash -c "
  [ -f /dest/file ] && cmp -s /tmp/file.new /dest/file && { echo unchanged; rm -f /tmp/file.new; exit 0; }
  [ -f /dest/file ] && cp -p /dest/file /dest/file.bak.$(date +%Y%m%d%H%M%S)
  install -o root -g confluent -m 0640 /tmp/file.new /dest/file && rm -f /tmp/file.new"'
```

> 陷阱：正式環境的 cpadmin 是受限 sudo（只能執行 cpnode agent，見 3.0.3 的 sudoers）；本手冊的 `install`、`useradd`、`visudo`、`nginx -s reload` 這類手動指令要由擁有完整 sudo 的管理員執行。PoC 映像檔是完整 sudo。

## 5.1 步驟 08:安全初始化（`steps/08_security_bootstrap.sh`）

執行順序（與 `step_apply` 相同）：SCRAM 使用者 → MDS 登入 → audit 綁定 → svc-c3 SystemAdmin → 服務帳號綁定（svc-rest）→ AD 群組綁定 → 每個 app 的 `User:` 綁定 → 範例 topic。
前提：07 已啟動 controller/broker、MDS 可用、AD（ad01）裡已有 04 建立的帳號與群組。

### 5.1.1 SCRAM 使用者（直連 Kafka 的 app + audit writer）

- **目的**：`APP_CHANNEL=scram` 的 app（`app-orders`、`app-payments`）透過 CLIENT listener（9095, SASL_SSL SCRAM-SHA-512）直連 broker；audit logger 也用專屬低權限 SCRAM 帳號 `confluent-audit` 寫稽核 topic。`app-legacy-billing`（channel=rest）**刻意不建** SCRAM 憑證，它只能走 REST Proxy + mTLS。
- **主機/帳號**：ops01 / cpadmin（以 `User:kafka-internal` 憑證連 INTERNAL listener）。
- **手動指令**：

```bash
# 先檢查是否已存在（冪等）
kafka-configs --bootstrap-server "$B" --command-config "$CFG" \
  --describe --entity-type users --entity-name app-orders

# 建立（每個使用者一次）；密碼來源：APP_APP_ORDERS_PASSWORD / APP_APP_PAYMENTS_PASSWORD / AUDIT_PASSWORD
# 行首加空白 + HISTCONTROL=ignorespace，避免密碼進 history
export HISTCONTROL=ignorespace
 kafka-configs --bootstrap-server "$B" --command-config "$CFG" --alter \
  --entity-type users --entity-name app-orders \
  --add-config 'SCRAM-SHA-512=[iterations=8192,password=<password>]'
 kafka-configs --bootstrap-server "$B" --command-config "$CFG" --alter \
  --entity-type users --entity-name app-payments \
  --add-config 'SCRAM-SHA-512=[iterations=8192,password=<password>]'
 kafka-configs --bootstrap-server "$B" --command-config "$CFG" --alter \
  --entity-type users --entity-name confluent-audit \
  --add-config 'SCRAM-SHA-512=[iterations=8192,password=<password>]'
```

- **驗證**：

```bash
kafka-configs --bootstrap-server "$B" --command-config "$CFG" --describe --entity-type users
```
預期（順序不定）：
```
SCRAM credential configs for user-principal 'kafka-admin' are SCRAM-SHA-512=iterations=4096
SCRAM credential configs for user-principal 'app-payments' are SCRAM-SHA-512=iterations=8192
SCRAM credential configs for user-principal 'confluent-audit' are SCRAM-SHA-512=iterations=8192
SCRAM credential configs for user-principal 'app-orders' are SCRAM-SHA-512=iterations=8192
```
且**不應**出現 `app-legacy-billing`。

- **對應 cpctl**：`security::scram_user`、`inv::apps scram`、`inv::app_secret_var`。
- **注意事項**：
  - `kafka-admin`（iterations=4096）與新叢集上的 `confluent-audit` 是在 06 `kafka-storage format --add-scram` 時寫入的；08 只是補齊。
  - `--add-config` 的密碼會短暫出現在 `ps` 輸出中,所以指令開頭加空白(不進 history),並在只有安裝人員能登入的操作機上執行;密碼從密碼檔讀成變數帶入(`password=$APP_APP_ORDERS_PASSWORD`),不要手打。
  - **不要改用 `--add-config-file`**:全程實測證實它不支援 SCRAM 憑證,而且錯誤訊息 `Invalid credential property SCRAM_SHA_512=[iterations=8192,password=...]` 會**把密碼原文印在畫面與紀錄裡**。實測時因此外洩了 3 組密碼,處理方式是遮蔽紀錄並全部換新(見下一點)。
  - **叢集還沒就緒時不要執行**:`kafka-configs` 連不上(例如 `Timed out waiting for a node assignment`)時,錯誤訊息 `Error while executing config command with args '...'` 會把**整串參數,包括 `--add-config` 裡的密碼**印出來。先確認 broker 都已註冊(4.4.5)再建 SCRAM 帳號;要存檔的輸出先經過遮蔽(例如 `sed -E 's/password=[^],]*/password=<hidden>/g'`)。實測重置叢集時因此又外洩 2 組,已遮蔽並換新(附錄 A.3)。
  - 改密碼 = 再次 `--alter --add-config`(覆蓋);舊連線不會斷,新連線才生效。
  - **改 `confluent-audit` 的密碼**時,controller 與 broker 的 `server.properties` 也寫著這組密碼(4.2.3.7),要重新產生、加密、派送(4.2.3–4.2.4),再一台一台滾動重啟(4.2.8)。改完 SCRAM 到該節點重啟之前,這台的稽核寫入會認證失敗(broker log 出現 `Failed authentication`),全部重啟完就停止。實測 7 台滾動重啟後,30 秒內不再新增任何失敗。

### 5.1.2 MDS 登入（Confluent CLI）

- **目的**：之後的 RBAC 綁定都透過 MDS 建立；以 AD 安裝帳號 `svc-cpctl`（同時列在 `super.users`）登入。
- **主機/帳號**：ops01 / cpadmin。
- **手動指令**：

```bash
export HOME_CLI=/var/lib/cp-installer/cli-home    # cpctl 用的 CLI 設定目錄（HOME 指向此處）
mkdir -p "$HOME_CLI"
 HOME=$HOME_CLI CONFLUENT_PLATFORM_USERNAME=svc-cpctl CONFLUENT_PLATFORM_PASSWORD='<password>' \
  confluent login --url https://kb01.poc.lab:8090 \
  --certificate-authority-path /var/lib/cp-installer/pki/ca.pem
alias cfl='HOME=/var/lib/cp-installer/cli-home confluent'
```

- **驗證**：`cfl iam rbac role-binding list --principal User:svc-c3 --kafka-cluster $CID` 能列出結果（未登入會提示需 login）。
- **對應 cpctl**：`rbac::login`、`rbac::cli`。
- **注意事項**：Confluent CLI v4.72.0（`/usr/bin/confluent`）。MDS 的 token 有效期有限，長時間操作中斷後重新 login 即可。

### 5.1.3 RBAC 角色綁定（完整清單）

- **目的**：最小權限。人員用 AD 群組綁定；mTLS 憑證身分（REST 的 legacy app）**不能**用群組綁定（官方限制），所以每個 app 一律綁在 `User:<app>`。
- **主機/帳號**：ops01 / cpadmin（已 5.1.2 登入）。
- **規格語法**（`conf/apps.env`）：`<Role>` = cluster 層級；`<Role>:<ResourceType>:<Name>:<LITERAL|PREFIXED>` = 資源層級。
- **手動指令**（Confluent CLI；每一行都是一筆綁定）：

```bash
# (a) audit writer：只能寫/管理 audit topic（prefix 涵蓋 _sensitive）
cfl iam rbac role-binding create --principal User:confluent-audit --role DeveloperWrite  --kafka-cluster $CID --resource Topic:confluent-audit-log-events --prefix
cfl iam rbac role-binding create --principal User:confluent-audit --role DeveloperManage --kafka-cluster $CID --resource Topic:confluent-audit-log-events --prefix

# (b) Control Center 服務帳號必須是 SystemAdmin（C3 官方需求）
cfl iam rbac role-binding create --principal User:svc-c3 --role SystemAdmin --kafka-cluster $CID

# (c) REST Proxy 服務帳號：安全外掛自己驗 license，要能讀 license 相關 topic（LITERAL）
cfl iam rbac role-binding create --principal User:svc-rest --role DeveloperRead --kafka-cluster $CID --resource Topic:_confluent-license
cfl iam rbac role-binding create --principal User:svc-rest --role DeveloperRead --kafka-cluster $CID --resource Topic:_confluent-command
cfl iam rbac role-binding create --principal User:svc-rest --role DeveloperRead --kafka-cluster $CID --resource Topic:__internal_confluent_only_broker_info

# (d) 人員 AD 群組
cfl iam rbac role-binding create --principal Group:kafka-admins    --role SystemAdmin --kafka-cluster $CID
cfl iam rbac role-binding create --principal Group:kafka-operators --role Operator    --kafka-cluster $CID
cfl iam rbac role-binding create --principal Group:kafka-devs --role DeveloperRead --kafka-cluster $CID --resource Topic:orders. --prefix
cfl iam rbac role-binding create --principal Group:kafka-devs --role DeveloperRead --kafka-cluster $CID --resource Group:dev-   --prefix

# (e) 應用程式（一律 User:<app>）
cfl iam rbac role-binding create --principal User:app-orders --role DeveloperWrite  --kafka-cluster $CID --resource Topic:orders. --prefix
cfl iam rbac role-binding create --principal User:app-orders --role DeveloperRead   --kafka-cluster $CID --resource Topic:orders. --prefix
cfl iam rbac role-binding create --principal User:app-orders --role DeveloperRead   --kafka-cluster $CID --resource Group:orders- --prefix
cfl iam rbac role-binding create --principal User:app-orders --role DeveloperManage --kafka-cluster $CID --resource Topic:orders. --prefix
cfl iam rbac role-binding create --principal User:app-payments --role DeveloperWrite --kafka-cluster $CID --resource Topic:payments. --prefix
cfl iam rbac role-binding create --principal User:app-payments --role DeveloperRead  --kafka-cluster $CID --resource Topic:payments. --prefix
cfl iam rbac role-binding create --principal User:app-legacy-billing --role DeveloperWrite --kafka-cluster $CID --resource Topic:billing.  --prefix
cfl iam rbac role-binding create --principal User:app-legacy-billing --role DeveloperRead  --kafka-cluster $CID --resource Topic:billing.  --prefix
cfl iam rbac role-binding create --principal User:app-legacy-billing --role DeveloperRead  --kafka-cluster $CID --resource Group:billing- --prefix
```

  不用 CLI 時，等價的 MDS REST（以 svc-cpctl basic auth）：

```bash
# cluster 層級角色
curl -s --cacert $PKI/ca.pem -u 'svc-cpctl:<password>' -H 'Content-Type: application/json' -X POST \
  "$MDS/security/1.0/principals/User:svc-c3/roles/SystemAdmin" \
  -d "{\"clusters\":{\"kafka-cluster\":\"$CID\"}}"
# 資源層級角色（PREFIXED / LITERAL）
curl -s --cacert $PKI/ca.pem -u 'svc-cpctl:<password>' -H 'Content-Type: application/json' -X POST \
  "$MDS/security/1.0/principals/User:app-orders/roles/DeveloperWrite/bindings" \
  -d "{\"scope\":{\"clusters\":{\"kafka-cluster\":\"$CID\"}},\"resourcePatterns\":[{\"resourceType\":\"Topic\",\"name\":\"orders.\",\"patternType\":\"PREFIXED\"}]}"
```

- **驗證**（唯讀 lookup，PoC 實測輸出）：

```bash
for p in User:app-orders Group:kafka-admins User:svc-rest User:confluent-audit User:svc-c3; do
  curl -s --cacert $PKI/ca.pem -u 'svc-cpctl:<password>' -H 'Content-Type: application/json' -X POST \
    -d "{\"clusters\":{\"kafka-cluster\":\"$CID\"}}" "$MDS/security/1.0/lookup/principal/$p/resources"; echo
done
```
```
{"User:app-orders":{"DeveloperWrite":[{"resourceType":"Topic","name":"orders.","patternType":"PREFIXED"}],"DeveloperRead":[{"resourceType":"Group","name":"orders-","patternType":"PREFIXED"},{"resourceType":"Topic","name":"orders.","patternType":"PREFIXED"}],"DeveloperManage":[{"resourceType":"Topic","name":"orders.","patternType":"PREFIXED"}]}}
{"Group:kafka-admins":{"SystemAdmin":[]}}
{"User:svc-rest":{"DeveloperRead":[{"resourceType":"Topic","name":"__internal_confluent_only_broker_info","patternType":"LITERAL"},{"resourceType":"Topic","name":"_confluent-command","patternType":"LITERAL"},{"resourceType":"Topic","name":"_confluent-license","patternType":"LITERAL"}]}}
{"User:confluent-audit":{"DeveloperWrite":[{"resourceType":"Topic","name":"confluent-audit-log-events","patternType":"PREFIXED"}],"DeveloperManage":[{"resourceType":"Topic","name":"confluent-audit-log-events","patternType":"PREFIXED"}]}}
{"User:svc-c3":{"SystemAdmin":[]}}
```
  或 `cfl iam rbac role-binding list --principal User:app-orders --kafka-cluster $CID -o json`。

- **對應 cpctl**：`rbac::ensure`（先 `rbac::bindings_json` 比對 role/resource_type/name/pattern_type，缺的才 create）、`core::varname`（`kafka-admins` → `kafka_admins`）。
- **注意事項**：
  - `create` 不是冪等的判斷依據；重複建立通常無害，但請先 `list` 再建，保持與 cpctl 相同行為。
  - PREFIXED 的名字要含分隔符（`orders.`、`orders-`），否則 `orders` 也會吃到 `ordersX`。
  - REST 進來的 legacy app 憑證被 mapping 成 `User:app-legacy-billing`，所以 RBAC 一定綁 `User:`，綁 `Group:` 永遠不會生效。
  - `svc-cpctl`、`kafka-internal`、`kafka-admin` 是 `super.users`，不需要綁定。

### 5.1.4 svc-rest impersonation（設定在 broker，不在 08）

- **目的**：REST Proxy 以 `svc-rest` 向 MDS 取得「代表 app 身分」的 impersonation token；只有 `svc-rest` 可以 impersonate，且永遠不能冒充 super user、服務帳號、audit writer、break-glass。
- **在哪裡**：每台 broker `/etc/confluent/kafka/server.properties`（05 渲染，`broker.properties.tpl` 第 74–75 行）。
- **設定檔內容**（實際值）：

```properties
super.users = User:kafka-internal;User:kafka-admin;User:svc-cpctl
confluent.metadata.server.impersonation.super.users = User:svc-rest
# 自動推導：所有 super.users + AD_SERVICE_ACCOUNTS + AUDIT_PRINCIPAL + OPMENU_BREAKGLASS（OPMENU=on 時）
confluent.metadata.server.impersonation.protected.users = User:kafka-internal;User:kafka-admin;User:svc-cpctl;User:svc-mds-bind;User:svc-rest;User:svc-c3;User:confluent-audit;User:opmenu-breakglass
```
- **驗證**：`ssh cpadmin@kb01.poc.lab 'sudo grep impersonation /etc/confluent/kafka/server.properties'`。
- **對應 cpctl**：`role::common_vars`（`IMPERSONATION_SUPER_USERS`）、`role::protected_users`。
- **注意事項**：手動新增服務帳號時，記得同步加入 protected.users 並滾動重啟 broker；這份清單是推導出來的，不要只在一處手改。

### 5.1.5 Audit log 路由（設定在 controller + broker，principal 在 08）

- **目的**：稽核事件寫入 `confluent-audit-log-events`（保留 90 天）；`payments.` 開頭 topic 的 produce/consume（允許與拒絕）以及被拒的 describe 另送 `confluent-audit-log-events_sensitive`（保留 365 天）；排除大量噪音的 `User:kafka-internal`、`User:svc-c3`。Writer 是 1.1 建立的 `confluent-audit`（CLIENT listener 9095, SCRAM），不是 broker 自己的身分。
- **設定檔內容**（`fragments/audit.properties.tpl`，在 `/etc/confluent/kafka/server.properties`，密碼經 Secret Protection 加密）：

```properties
confluent.security.event.logger.enable=true
confluent.security.event.logger.exporter.kafka.bootstrap.servers=kb01.poc.lab:9095,kb02.poc.lab:9095,kb03.poc.lab:9095,kb04.poc.lab:9095
confluent.security.event.logger.exporter.kafka.security.protocol=SASL_SSL
confluent.security.event.logger.exporter.kafka.sasl.mechanism=SCRAM-SHA-512
confluent.security.event.logger.exporter.kafka.sasl.jaas.config=...ScramLoginModule required username="confluent-audit" password="<password>";
confluent.security.event.logger.exporter.kafka.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.security.event.logger.exporter.kafka.topic.replicas=3
# 90 天
confluent.security.event.logger.exporter.kafka.topic.retention.ms=7776000000
confluent.security.event.router.config=<下列 JSON 壓成一行>
```
  router JSON（排版後）：
```json
{
  "destinations": {"topics": {
    "confluent-audit-log-events":           {"retention_ms": 7776000000},
    "confluent-audit-log-events_sensitive": {"retention_ms": 31536000000}}},
  "default_topics": {"allowed": "confluent-audit-log-events", "denied": "confluent-audit-log-events"},
  "excluded_principals": ["User:kafka-internal", "User:svc-c3"],
  "routes": {
    "crn:///kafka=*/topic=payments.*": {
      "produce":  {"allowed": "confluent-audit-log-events_sensitive", "denied": "confluent-audit-log-events_sensitive"},
      "consume":  {"allowed": "confluent-audit-log-events_sensitive", "denied": "confluent-audit-log-events_sensitive"},
      "describe": {"allowed": "", "denied": "confluent-audit-log-events_sensitive"}}}
}
```
- **驗證**：
```bash
kafka-topics --bootstrap-server "$B" --command-config "$CFG" --describe --topic confluent-audit-log-events
kafka-topics --bootstrap-server "$B" --command-config "$CFG" --describe --topic confluent-audit-log-events_sensitive
# 讀幾筆事件（JSON，每行一筆）
kafka-console-consumer --bootstrap-server "$B" --consumer.config "$CFG" \
  --topic confluent-audit-log-events_sensitive --from-beginning --timeout-ms 30000 | head -3
```
- **對應 cpctl**：`role::audit_router_json`、`role::common_vars`（`AUDIT_*`）、08 的 `rbac::ensure "User:$AUDIT_PRINCIPAL"`。
- **注意事項**：
  - describe 的 `allowed` 設成空字串＝不記錄（量太大）；只記被拒的 describe，因為被拒的 producer 在 metadata 階段就失敗，根本不會送 Produce。
  - 綁定若缺，audit logger 無法寫入，broker log 會持續出現授權錯誤，但不影響業務流量。

### 5.1.6 範例 topic

- **目的**：建立 PoC 驗證用 topic，RF=3、`min.insync.replicas=2`。
- **主機/帳號**：ops01 / cpadmin。
- **手動指令**：

```bash
for t in orders.events:6 payments.events:6 billing.events:3; do
  kafka-topics --bootstrap-server "$B" --command-config "$CFG" --create --if-not-exists \
    --topic "${t%%:*}" --partitions "${t#*:}" --replication-factor 3 --config min.insync.replicas=2
done
```
- **驗證**：`kafka-topics --bootstrap-server "$B" --command-config "$CFG" --describe --topic orders.events` → `PartitionCount: 6  ReplicationFactor: 3  Configs: min.insync.replicas=2`，每個 partition 的 ISR 為 3 個 broker（跨 rack-a / rack-b）。
- **對應 cpctl**：`security::topic`；step 驗證 `step_verify`（describe `orders.events`）。

### 5.1.7 Client 配額（每個 app 一組）

- **目的**：限制每個應用程式能用的流量與 broker 執行緒，避免一個失控的 app 拖垮其他 app。配額掛在 Kafka principal `User:<app>` 上：
  - SCRAM 直連的 app，principal 就是 SCRAM 帳號。
  - REST Proxy 的 legacy app 一樣受限：REST Proxy 以該 app 的身分（impersonation，`User:app-legacy-billing`）連 Kafka。
- **主機/帳號**：ops01 / cpadmin（同 5.1.1，`$B`、`$CFG`）。
- **數值**（`conf/apps.env` 的 `APP_QUOTA_<app>`，PoC 值）：

| app | producer_byte_rate | consumer_byte_rate | request_percentage |
|---|---|---|---|
| app-orders | 5242880（5 MiB/s） | 10485760（10 MiB/s） | 50 |
| app-payments | 5242880 | 10485760 | 50 |
| app-legacy-billing | 1048576（1 MiB/s） | 2097152（2 MiB/s） | 25 |

  - byte_rate 是**每台 broker** 的上限（4 台 broker = 叢集合計最多約 4 倍）。
  - `request_percentage` 是 broker 一條 request-handler / network 執行緒的百分比；超過時 broker 延遲回應（throttle），**不會斷線、不會丟訊息**。
- **手動指令**：

```bash
# 先看目前的配額（沒有設定時沒有輸出）
kafka-configs --bootstrap-server "$B" --command-config "$CFG" \
  --describe --entity-type users --entity-name app-orders
# 設定（重跑會覆蓋成同樣的值，可重複執行）
kafka-configs --bootstrap-server "$B" --command-config "$CFG" --alter \
  --entity-type users --entity-name app-orders \
  --add-config 'producer_byte_rate=5242880,consumer_byte_rate=10485760,request_percentage=50'
kafka-configs --bootstrap-server "$B" --command-config "$CFG" --alter \
  --entity-type users --entity-name app-payments \
  --add-config 'producer_byte_rate=5242880,consumer_byte_rate=10485760,request_percentage=50'
kafka-configs --bootstrap-server "$B" --command-config "$CFG" --alter \
  --entity-type users --entity-name app-legacy-billing \
  --add-config 'producer_byte_rate=1048576,consumer_byte_rate=2097152,request_percentage=25'
# 拿掉某一項（例如不再限制 request_percentage）
#   ... --alter --entity-type users --entity-name app-orders --delete-config request_percentage
```

- **驗證**：

```bash
kafka-configs --bootstrap-server "$B" --command-config "$CFG" --describe --entity-type users --entity-name app-orders
```
預期（數字以科學記號印出，順序不固定）：
```
Quota configs for user-principal 'app-orders' are consumer_byte_rate=1.048576E7, request_percentage=50.0, producer_byte_rate=5242880.0
```
實際限流的驗證（要等 5.3 建好 client 設定檔 `$CD/app-orders-scram.properties` 之後做）：以 app-orders 身分持續壓測（broker 以約 10 秒的視窗計算速率，短時間的突發不會被限）：
```bash
kafka-topics --bootstrap-server "$B" --command-config "$CFG" --create --topic orders.quota-test --partitions 1 --replication-factor 3 --config retention.ms=3600000
kafka-producer-perf-test --topic orders.quota-test --num-records 15000 --record-size 10000 --throughput -1 \
  --producer.config $CD/app-orders-scram.properties --producer-props bootstrap.servers="$BC" acks=1 linger.ms=20 batch.size=262144 --print-metrics \
  | grep -E 'records sent|produce-throttle-time-(avg|max)' | grep -v node-
```
實測（PoC，2026-10-18）：
```
7827 records sent, 1553.0 records/sec (14.81 MB/sec), ...     ← 一開始的突發
2626 records sent, 523.5 records/sec (4.99 MB/sec), ...       ← 之後被壓在 5 MiB/s（單一 partition = 單一 broker）
producer-metrics:produce-throttle-time-avg:{client-id=perf-producer-client} : 26.102     ← > 0 表示 broker 有延遲回應
```
測完刪除測試 topic：`kafka-topics ... --delete --topic orders.quota-test`。

- **對應 cpctl**：`security::quota`（step 08，`APP_QUOTA_<app>`；只管 `producer_byte_rate`、`consumer_byte_rate`、`request_percentage`、`controller_mutation_rate` 四項，`apps.env` 拿掉的項目會從叢集刪除）。
- **注意事項**：
  - **不要隨手設「所有使用者的預設配額」**（`--entity-default`）：它也會限制 svc-c3、REST Proxy 代理的身分、稽核寫入帳號。`QUOTA_USER_DEFAULT` 預設留空，要設之前先估好這些服務帳號的流量。
  - broker 之間的複寫（`kafka-internal`）不受 client 配額影響。
  - 配額要依實際壓測與業務量調整；PoC 值只用來驗證機制。

## 5.2 步驟 09:啟動 REST Proxy、Control Center、套用 LB（`steps/09_start_edge.sh`）

> 設定檔是 05（configure）就已推到節點的；09 只做 enable + start、套 Nginx 設定、再做健康檢查。以下把兩部分一起寫，方便手動重建。

### 5.2.1 REST Proxy（rest01、rest02）

- **目的**：只給 legacy app（`APP_CHANNEL=rest`，目前只有 `app-legacy-billing`）用：HTTPS + **強制** client 憑證；憑證 CN 經 principal mapping 變成 `app-legacy-billing`，REST Proxy 再以 `svc-rest` 向 MDS 換 impersonation token，用該 app 的身分透過 TOKEN listener（9094）存取 Kafka，由 RBAC 決定權限。
- **主機/帳號**：rest01、rest02 / root（ops01 的 cpadmin 經 ssh + sudo）。
- **檔案**：

| 路徑 | 擁有者/權限 | 來源 |
|---|---|---|
| `/etc/confluent/ssl/{ca.pem,truststore.p12,cp-server.p12,mds-public.pem}` | root:confluent 0640（目錄 0750） | ops01 `$PKI` |
| `/etc/confluent/kafka-rest/kafka-rest.properties` | root:confluent 0640 | `kafka-rest.properties.tpl`（Secret Protection 加密後） |
| `/etc/confluent/kafka-rest/security.properties` | root:confluent 0640 | `confluent secret file encrypt` 產生的密文 |
| `/etc/confluent/kafka-rest/service.env` | root:root 0600 | `CONFLUENT_SECURITY_MASTER_KEY=<master key>` |
| `/etc/confluent/kafka-rest/jmx-exporter.yml` | root:confluent 0640 | 見 5.4 |
| `/etc/systemd/system/confluent-kafka-rest.service.d/10-cpctl.conf` | root:root 0644 | `rest-override.conf.tpl` |

- **設定檔內容**(rest01 的明文完整版,共 36 項;全程實測即照此寫出。rest02 只差 `id=rest-02`。寫好後依 4.2.4 加密,`--remote-secrets-file /etc/confluent/kafka-rest/security.properties`,實測加密 7 個 key):

```properties
id=rest-01
listeners=https://0.0.0.0:8082
# client 只看到 LB 名稱
advertised.listeners=https://rest.poc.lab:8082
host.name=rest.poc.lab
# HTTPS + 強制 client 憑證
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
ssl.keystore.password=<store-password>
ssl.key.password=<store-password>
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ssl.truststore.password=<store-password>
ssl.client.authentication=REQUIRED
ssl.enabled.protocols=TLSv1.3,TLSv1.2
# RBAC:以憑證認證,以該 principal 行事(兩個 mapping key 都要設,8.3.2 實際套用的是 auth.ssl.principal.mapping.rules)
kafka.rest.resource.extension.class=io.confluent.kafkarest.security.KafkaRestSecurityResourceExtension
rest.servlet.initializor.classes=io.confluent.common.security.jetty.initializer.AuthenticationHandler
confluent.rest.auth.propagate.method=SSL
confluent.rest.auth.ssl.principal.mapping.rules=RULE:.*CN=(app-legacy-billing)([^a-zA-Z0-9._-].*)?$/$1/
auth.ssl.principal.mapping.rules=RULE:.*CN=(app-legacy-billing)([^a-zA-Z0-9._-].*)?$/$1/
public.key.path=/etc/confluent/ssl/mds-public.pem
# MDS(以 svc-rest 身分)
confluent.metadata.bootstrap.server.urls=https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090
confluent.metadata.http.auth.credentials.provider=BASIC
confluent.metadata.basic.auth.user.info=svc-rest:<svc-rest-password>
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=<store-password>
# Kafka client:TOKEN listener + OAUTHBEARER(MDS token)
bootstrap.servers=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094,kb04.poc.lab:9094
client.security.protocol=SASL_SSL
client.sasl.mechanism=OAUTHBEARER
client.sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenUserLoginCallbackHandler
client.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username="svc-rest" password="<svc-rest-password>" metadataServerUrls="https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090";
client.ssl.truststore.type=PKCS12
client.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
client.ssl.truststore.password=<store-password>
client.ssl.endpoint.identification.algorithm=https
consumer.threads=8
consumer.instance.timeout.ms=300000
```

加密後會自動多出 `config.providers=securepass` 與 `config.providers.securepass.class=...SecurePassConfigProvider` 兩行。

>! Java properties 沒有「行尾註解」:`id=rest-01   # 說明` 的值會變成 `rest-01   # 說明`。註解一定要獨立一行。

  其他檔案(REST 主機,`/etc/confluent/kafka-rest` 目錄 root:confluent 0750):`service.env`(root 0600,內容同 4.2.4)、`jmx-exporter.yml`(root:confluent 0640,標頭同 4.2.5、keystore 用 `cp-server.p12`,後面接附錄 D.3 的 `rules-rest.yml`),以及 `/opt/jmx-exporter/` 的 jar。

  systemd drop-in：
```ini
[Service]
ExecStart=
ExecStart=/usr/bin/kafka-rest-start /etc/confluent/kafka-rest/kafka-rest.properties
Environment="JAVA_HOME=/usr/lib/jvm/temurin-21-jdk"
Environment="KAFKAREST_HEAP_OPTS=-Xms512m -Xmx512m"
Environment="KAFKAREST_OPTS=-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar=7071:/etc/confluent/kafka-rest/jmx-exporter.yml"
EnvironmentFile=-/etc/confluent/kafka-rest/service.env
LimitNOFILE=65536
Restart=on-failure
RestartSec=10
```

- **手動指令**：
```bash
# (ops01) Secret Protection：明文 -> 加密設定 + 密文檔（每台主機一份；master key 在 /var/lib/cp-installer/secret-protection/master.key）
 CONFLUENT_SECURITY_MASTER_KEY='<master key>' HOME=/var/lib/cp-installer/cli-home confluent secret file encrypt \
   --config-file ./kafka-rest.properties \
   --local-secrets-file ./kafka-rest.security.properties \
   --remote-secrets-file /etc/confluent/kafka-rest/security.properties \
   --config 'ssl.keystore.password,ssl.key.password,ssl.truststore.password,confluent.metadata.basic.auth.user.info,confluent.metadata.ssl.truststore.password,client.sasl.jaas.config/org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule/password,client.ssl.truststore.password'
# （--local-secrets-file 需先複製一份 /var/lib/cp-installer/secret-protection/master.secrets 作起點；
#  --config 清單 = 所有以 password/credentials/passphrase/basic.auth.user.info 結尾的 key + 每個 sasl.jaas.config 內的 password，cpctl 以 sp::keys 自動產生，上列為依此規則推導）
# 推檔（見 5.0 的慣例）後，在 rest01 / rest02 上（root）：
systemctl daemon-reload
systemctl enable confluent-kafka-rest
systemctl start confluent-kafka-rest
```
- **驗證**（ops01，最多等 180 秒）：
```bash
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem --cert $PKI/app-legacy-billing.crt --key $PKI/app-legacy-billing.key https://rest01.poc.lab:8082/v3/clusters   # 200
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem --cert $PKI/cp-server.crt --key $PKI/cp-server.key https://rest01.poc.lab:8082/v3/clusters                   # 401（不在 legacy 清單）
curl -s -o /dev/null -w '%{http_code} exit=%{exitcode}\n' --cacert $PKI/ca.pem https://rest01.poc.lab:8082/v3/clusters                                                     # 000 exit=56（TLS 層拒絕）
```
  cpctl 健康判斷只要 200/401/403 任一（服務有回應）即可。
- **對應 cpctl**：`role::rest::configure`（05）、`role::rest::start`、`role::rest::health`、`rest::_answers`、`rest::http_code`、`role::rest_principal_rules`、`sp::push`/`sp::protect`。
- **注意事項**：
  - mapping rule **刻意沒有** `,DEFAULT`：任何不在清單上的憑證（伺服器、super user、人員、SCRAM app）都會 mapping 失敗 → 401。新增 legacy app 時，要改 `apps.env`、簽發 `CN=<app>` 憑證、重新渲染並重啟 REST。
  - regex 尾段 `([^a-zA-Z0-9._-].*)?$` 確保 `CN=app-legacy-billing-evil` 不會被當成 `app-legacy-billing`。
  - 只設 `confluent.rest.auth.ssl.principal.mapping.rules` 不夠：8.3.2 實測要同時設 `auth.ssl.principal.mapping.rules`，否則被 impersonate 的是完整 DN，`User:<app>` 綁定永遠對不上。
  - Secret Protection 加密是隨機 IV，每次加密內容都不同；cpctl 以明文 sha256 快取來避免無謂重啟，手動操作時只在明文有變時才重新加密。

### 5.2.2 Control Center Next Gen 2.6.1 + Prometheus + Alertmanager（c3-01）

- **目的**：C3 Next Gen 透過 broker telemetry（OTLP → 內建 Prometheus :9090）取得指標；Prometheus 與 Alertmanager（:9093）都用 TLS 並**強制** client 憑證；C3 UI（:9021）用 HTTPS，人員以 AD 帳號經 MDS 登入（BEARER）。
- **主機/帳號**：c3-01 / root。C3 主機**不得**安裝任何 CP 套件（類別載入衝突），只裝 `confluent-control-center-next-gen` 與 OS 前置 `cyrus-sasl openssl-devel`。
- **檔案**：
  - `/etc/confluent/ssl/{ca.pem,truststore.p12,cp-server.p12,cp-server.crt,cp-server.key,mds-public.pem}` root:confluent 0640
  - `/etc/confluent-control-center/web-config-prom.yml`、`web-config-am.yml`（同一份內容）root:confluent 0640
  - `/etc/confluent-control-center/prometheus-generated.yml` root:confluent 0640
  - `/etc/systemd/system/prometheus.service.d/10-cpctl.conf`、`/etc/systemd/system/confluent-control-center.service.d/10-cpctl.conf` 0644
  - `/etc/confluent/control-center/control-center.properties` root:confluent 0640（Secret Protection）
  - `/var/lib/confluent/control-center` cp-control-center:confluent 0750
- **設定檔內容**：

  `web-config-*.yml`（RPM 的 `prometheus-start` / `alertmanager-start` 以 `--web.config.file=$CONFIG_PATH/web-config-prom.yml|web-config-am.yml` 讀取）：
```yaml
tls_server_config:
  cert_file: /etc/confluent/ssl/cp-server.crt
  key_file: /etc/confluent/ssl/cp-server.key
  client_ca_file: /etc/confluent/ssl/ca.pem
  client_auth_type: RequireAndVerifyClientCert   # 沒有內部 CA 簽發的 client 憑證一律拒絕
  min_version: TLS12
```
  `prometheus-generated.yml`(完整內容;Alertmanager 以 mTLS 連 9093,`scrape_configs:` 留空,因為指標由 OTLP receiver 推入):
```yaml
global:
  scrape_interval: 60s
  evaluation_interval: 60s
alerting:
  alertmanagers:
    - scheme: https
      tls_config:
        ca_file: /etc/confluent/ssl/ca.pem
        cert_file: /etc/confluent/ssl/cp-server.crt
        key_file: /etc/confluent/ssl/cp-server.key
      static_configs:
        - targets:
            - c3-01.poc.lab:9093
rule_files:
  - 'recording_rules-generated.yml'
  - 'trigger_rules-generated.yml'
scrape_configs:
```

  `prometheus` drop-in(保留天數 PoC 為 2d、正式環境 15d;systemd 設定檔沒有行尾註解,說明不要寫在同一行):
```ini
[Service]
Environment="METRICS_RETENTION_DAYS=2d"
Environment="PROMETHEUS_HOST=0.0.0.0"
Environment="PROMETHEUS_PORT=9090"
```
  `confluent-control-center` drop-in（**等 MDS** 的 override）：
```ini
[Service]
# 全站冷啟動時，若 C3 比 MDS 先起來會卡住（"client has already been closed"）且永遠不開 9021。
# 最多等 5 分鐘任一台 MDS 回應 /v1/metadata/id，然後無論如何都啟動。$$ = systemd 中的字面 $
ExecStartPre=/bin/sh -c 'for i in $$(seq 1 60); do for u in $$(echo "https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090" | tr , " "); do curl -fs --max-time 5 --cacert /etc/confluent/ssl/ca.pem -o /dev/null "$$u/v1/metadata/id" && exit 0; done; sleep 5; done; echo "MDS not reachable after 5 min - starting anyway"; exit 0'
TimeoutStartSec=420
ExecStart=
ExecStart=/usr/bin/control-center-start /etc/confluent/control-center/control-center.properties
Environment="JAVA_HOME=/usr/lib/jvm/temurin-21-jdk"
Environment="CONTROL_CENTER_HEAP_OPTS=-Xms1536m -Xmx1536m"
EnvironmentFile=-/etc/confluent/control-center/service.env
LimitNOFILE=65536
Restart=on-failure
RestartSec=10
```
  `control-center.properties`(明文完整版,共 47 項;依 4.2.4 加密,`--remote-secrets-file /etc/confluent/control-center/security.properties`,實測加密 13 個 key;另放 `service.env`(root 0600)):
```properties
confluent.controlcenter.id=10
confluent.controlcenter.name=poc-cluster
confluent.controlcenter.data.dir=/var/lib/confluent/control-center
confluent.controlcenter.internal.topics.replication=3
confluent.controlcenter.command.topic.replication=3
confluent.controlcenter.docs.host=docs.confluent.io
# Kafka:TOKEN listener + MDS token(svc-c3)
bootstrap.servers=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094,kb04.poc.lab:9094
confluent.controlcenter.streams.security.protocol=SASL_SSL
confluent.controlcenter.streams.sasl.mechanism=OAUTHBEARER
confluent.controlcenter.streams.sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenUserLoginCallbackHandler
confluent.controlcenter.streams.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username="svc-c3" password="<svc-c3-password>" metadataServerUrls="https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090";
confluent.controlcenter.streams.ssl.truststore.type=PKCS12
confluent.controlcenter.streams.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.streams.ssl.truststore.password=<store-password>
# RBAC:人員以 AD 帳密經 MDS 登入
confluent.metadata.bootstrap.server.urls=https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090
confluent.metadata.basic.auth.user.info=svc-c3:<svc-c3-password>
confluent.metadata.http.auth.credentials.provider=BASIC
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=<store-password>
confluent.controlcenter.rest.authentication.method=BEARER
public.key.path=/etc/confluent/ssl/mds-public.pem
# HTTPS UI
confluent.controlcenter.rest.listeners=https://0.0.0.0:9021
confluent.controlcenter.rest.ssl.keystore.type=PKCS12
confluent.controlcenter.rest.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.rest.ssl.keystore.password=<store-password>
confluent.controlcenter.rest.ssl.key.password=<store-password>
confluent.controlcenter.rest.ssl.truststore.type=PKCS12
confluent.controlcenter.rest.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.rest.ssl.truststore.password=<store-password>
# 內建 Prometheus / Alertmanager(mTLS,client 憑證 = cp-server)
confluent.controlcenter.prometheus.enable=true
confluent.controlcenter.prometheus.url=https://c3-01.poc.lab:9090
confluent.controlcenter.prometheus.rules.file=/etc/confluent-control-center/trigger_rules-generated.yml
confluent.controlcenter.prometheus.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.prometheus.ssl.truststore.password=<store-password>
confluent.controlcenter.prometheus.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.prometheus.ssl.keystore.password=<store-password>
confluent.controlcenter.prometheus.ssl.key.password=<store-password>
confluent.controlcenter.prometheus.alias.name=cp-server
confluent.controlcenter.alertmanager.url=https://c3-01.poc.lab:9093
confluent.controlcenter.alertmanager.config.file=/etc/confluent-control-center/alertmanager-generated.yml
confluent.controlcenter.alertmanager.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.alertmanager.ssl.truststore.password=<store-password>
confluent.controlcenter.alertmanager.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.alertmanager.ssl.keystore.password=<store-password>
confluent.controlcenter.alertmanager.ssl.key.password=<store-password>
confluent.controlcenter.alertmanager.alias.name=cp-server
```
- **手動指令**（c3-01，root；**順序固定**）：
```bash
systemctl daemon-reload
for u in prometheus alertmanager confluent-control-center; do systemctl enable "$u"; systemctl start "$u"; done
# 停止時反向：confluent-control-center -> alertmanager -> prometheus
```
- **驗證**：
```bash
# ops01：Prometheus 就緒（帶憑證，最多等 120 秒）
curl -s --cacert $PKI/ca.pem --cert $PKI/cp-server.crt --key $PKI/cp-server.key https://c3-01.poc.lab:9090/-/ready   # Prometheus Server is Ready.
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem https://c3-01.poc.lab:9090/-/ready                       # 000（無憑證，TLS 拒絕）
# ops01：C3 UI（最多等 420 秒；冷啟動含等 MDS 的 5 分鐘）
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem https://c3-01.poc.lab:9021/                             # 200
# c3-01 本機:Alertmanager(要 sudo:cpadmin 讀不到 0640 的 cp-server.key,不加 sudo 會得到 curl exit 58)
sudo curl -s --cacert /etc/confluent/ssl/ca.pem --cert /etc/confluent/ssl/cp-server.crt --key /etc/confluent/ssl/cp-server.key https://c3-01.poc.lab:9093/-/ready   # OK
systemctl is-active prometheus alertmanager confluent-control-center   # active x3
```
- **對應 cpctl**：`role::c3::configure`（05）、`role::c3::start`、`role::c3::health`、`c3::_prom_ready`、`c3::_ui_up`。
- **注意事項**：
  - firewalld 在 c3-01 只開 `9021/tcp 9090/tcp`（broker 推 OTLP 到 9090），9093 只供本機 Prometheus/C3 使用；從 ops01 測 9093 會得到 `No route to host`，這是預期行為。
  - 9093 同時也是 controller 埠，但在不同主機上，不衝突。
  - `/etc/confluent-control-center/` 裡的 `*.rpmnew` / `*.rpmsave` 是 RPM 升級留下的，cpctl 管理的是沒有後綴的檔案。
  - 先起 Prometheus 再起 C3；若 C3 卡在「MDS 未就緒」，確認 broker 的 MDS 正常後 `systemctl restart confluent-control-center` 即可。

### 5.2.3 Nginx stream（lb01）

- **目的**：既有 Nginx 只做 L4 passthrough；TLS（含 client 憑證）在 REST Proxy / C3 端終止，所以 mTLS 身分不會在 LB 遺失。REST 用 `hash $remote_addr consistent` 讓同一 client 黏住同一台（v2 consumer instance 有狀態）。cpctl 只擁有 `/etc/nginx/stream.d/cp.conf` 一個檔。
- **主機/帳號**：lb01 / root。前提：`/etc/nginx/nginx.conf` 已有 `stream { include /etc/nginx/stream.d/*.conf; }`（PoC：nginx 1.28.3）。
- **設定檔內容**（`/etc/nginx/stream.d/cp.conf`，root:root 0644）：
```nginx
upstream cp_rest {
    hash $remote_addr consistent;
    server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s;
    server rest02.poc.lab:8082 max_fails=2 fail_timeout=10s;   # 摘除（drain）時在行尾加 " down"
}
upstream cp_c3 {
    server c3-01.poc.lab:9021 max_fails=2 fail_timeout=10s;
}
server { listen 8082; proxy_pass cp_rest; proxy_connect_timeout 3s; proxy_timeout 10m; }
server { listen 9021; proxy_pass cp_c3;   proxy_connect_timeout 3s; proxy_timeout 1h;  }
```
- **手動指令**（lb01，root）：
```bash
install -o root -g root -m 0644 /tmp/cp.conf.new /etc/nginx/stream.d/cp.conf
nginx -t -q && nginx -s reload      # nginx -t 失敗就不要 reload；先還原 .bak 檔
```
- **驗證**：
```bash
# lb01(LB 設備不一定有 ss;實測的 Debian 版 nginx image 就沒有,改看生效中的設定)
sudo nginx -T 2>/dev/null | grep -E 'listen|server .*:'
# ops01（DNS：rest.poc.lab、c3.poc.lab 指向 lb01）
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem --cert $PKI/app-legacy-billing.crt --key $PKI/app-legacy-billing.key https://rest.poc.lab:8082/v3/clusters  # 200
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem https://c3.poc.lab:9021/                                                                                # 200
```
- **對應 cpctl**：`role::lb::configure` → `lb::apply_config`、`lb::upstream_lines`、`role::lb::health`（`health::tcp` 8082、9021，各等 60 秒）；滾動升級用 `lb::drain` / `lb::undrain`。
- **注意事項**：OSS Nginx 沒有 runtime API，摘除後端只能改檔 + reload；reload 不會中斷既有連線，但 `proxy_timeout 10m` 內的長連線會留在舊 worker 上。

### 5.2.4 Step 09 的總驗證

`step_verify`：每台 REST 回 200/401/403；每台 C3 `https://c3-01.poc.lab:9021/` = 200。

## 5.3 步驟 10:端對端驗證（`steps/10_verify.sh` + `lib/verify.sh`）

- **目的**：唯讀檢查整個平台（不改任何設定），任一項失敗就以 `E_GATE` 結束。`--check` 模式下跳過（需要真的叢集）。
- **主機/帳號**：ops01 / cpadmin。
- **對應 cpctl**：`verify::run_all`（`verify::check` 期望成功、`verify::check_not` 期望失敗）；`cpctl verify` 相同。
- 測試用 client 設定檔放在 `/var/lib/cp-installer/client/`（0600）：`<app>-scram.properties`、`<user>-ldap.properties`、`nocert.properties`。
- 測試訊息字串：`cpctl-verify-<RUN_ID>`；手動時自訂即可（例如 `manual-$(date +%s)`）。

先準備手動用的 client 設定（ops01）：
```bash
CD=/var/lib/cp-installer/client
cat > $CD/app-orders-scram.properties <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-orders" password="<password>";
ssl.truststore.type=PKCS12
ssl.truststore.location=/var/lib/cp-installer/pki/truststore.p12
ssl.truststore.password=<password>
EOF
# <user>-ldap.properties：同上，改 sasl.mechanism=PLAIN 與 PlainLoginModule username="alice" password="<password>"
# nocert.properties：只有 security.protocol=SSL + truststore（沒有 keystore）
chmod 0600 $CD/*.properties
P() { printf '%s\n' "$4" | kafka-console-producer --bootstrap-server "$1" --producer.config "$2" --topic "$3" \
  --producer-property acks=all --producer-property max.block.ms=20000 --producer-property delivery.timeout.ms=30000 \
  --producer-property request.timeout.ms=15000; }   # 成功 = 無輸出；失敗會印出 Authorization / Exception
BC=kb01.poc.lab:9095,kb02.poc.lab:9095,kb03.poc.lab:9095,kb04.poc.lab:9095
BL=kb01.poc.lab:9096,kb02.poc.lab:9096,kb03.poc.lab:9096,kb04.poc.lab:9096
```

### 5.3.1 檢查清單（共 48 項；PoC 現況）

| # | 類別 | 檢查 | 預期 |
|---|---|---|---|
| 1 | KRaft | quorum 有 leader | 成功 |
| 2 | KRaft | voters 數 = controller 數（3），每個都有 directoryId（dynamic quorum） | 成功 |
| 3 | KRaft | `kraft.version` FinalizedVersionLevel = 1 | 成功 |
| – | KRaft | `confluent.metadata.version` 等級（僅 info，不計分） | – |
| 4 | Brokers | 4 台 broker 已註冊 | 成功 |
| 5 | Brokers | rack awareness：同時有 rack-a、rack-b | 成功 |
| 6 | 內部 mTLS | controller 拒絕沒有憑證的 client | 失敗＝通過 |
| 7 | 內部 mTLS | controller 接受 kafka-internal 憑證 | 成功 |
| 8 | SCRAM+RBAC | app-orders 寫入 orders.events | 成功 |
| 9 | SCRAM+RBAC | app-orders 讀回該訊息（group `orders-verify`） | 成功 |
| 10 | SCRAM+RBAC | app-orders 寫 payments.events 被拒 | 失敗＝通過 |
| 11 | SCRAM+RBAC | 錯誤 SCRAM 密碼被拒 | 失敗＝通過 |
| 12 | LDAP+群組 | alice（kafka-admins→SystemAdmin）寫 payments.events | 成功 |
| 13 | LDAP+群組 | carol（kafka-devs 唯讀）寫 orders.events 被拒 | 失敗＝通過 |
| 14 | MDS | alice 以 basic auth 取得 token → 200 | 200 |
| 15 | MDS | 錯誤密碼 → 401 | 401 |
| 16 | REST via LB | app-legacy-billing 憑證 GET /v3/clusters = 200 | 200 |
| 17 | REST via LB | 無 client 憑證被 TLS 拒絕 | ≠200 |
| 18 | REST via LB | app-legacy-billing 寫 billing.events，record `error_code` 200 | 200 |
| 19 | REST via LB | app-legacy-billing 寫 orders.events，`error_code` 40301 | 40301 |
| 20 | REST via LB | cp-server 憑證不能用 REST | ≠200 |
| 21 | REST via LB | kafka-internal 憑證不能用 REST | ≠200 |
| (+) | REST via LB | 若 PKI 目錄有 SCRAM app 的舊憑證（`app-orders.crt` 等），每張各一項 ≠200（PoC 目前沒有） | ≠200 |
| 22 | REST via LB | app-legacy-billing 沒有 SCRAM 憑證 | 失敗＝通過 |
| 23 | C3/監控 | C3 UI via LB `https://c3.poc.lab:9021` = 200 | 200 |
| 24 | C3/監控 | Prometheus 拒絕沒有憑證的 client | ≠200 |
| 25 | C3/監控 | Prometheus 有 `io_confluent_kafka_server*` 指標（首次 scrape 約需 2 分鐘） | >0 |
| 26 | Audit | `confluent-audit-log-events` 存在 | 成功 |
| 27 | Audit | sensitive topic 有 User:alice 允許的 `kafka.Produce`（來自 #12） | 成功 |
| 28 | Audit | sensitive topic 有 User:app-orders 被拒事件（來自 #10） | 成功 |
| 29 | Audit | audit writer `confluent-audit` 不在 super.users | 成功 |
| 30–33 | 離線 | kb01、rest01、c3-01、ops01 連不到 `https://packages.confluent.io` | 失敗＝通過 |
| 34 | 套件 | kb01 的 CP 版本已鎖定（rpm：`dnf versionlock`） | 成功 |
| 35 | 套件 | c3-01 沒有 CP 套件（confluent-server / confluent-common / /opt/confluent/current） | 失敗＝通過 |
| 36 | JMX exporter | 每台 controller/broker/REST：HTTPS、匿名 401、帶帳密有指標（JMX_EXPORTER=on） | 成功 |
| 37–47 | OP 選單 | 11 項（見 5.3.9；僅在 11 已執行過才跑） | 見下 |
| 48 | 憑證 | kb01:8090 MDS 實際出示的序號 = `$PKI/cp-server.crt` 序號 | 相同 |
| – | 憑證/授權 | `pki::status`（即將到期只警告）、`license::status`（過期才算失敗；評估模式只警告） | – |

### 5.3.2 KRaft 與 broker（#1–#5）
```bash
kafka-metadata-quorum --bootstrap-controller "$CB" --command-config "$CFG" describe --status
#  LeaderId: <1|2|4>；CurrentVoters 內 3 筆，每筆都有 "directoryId"
kafka-features --bootstrap-controller "$CB" --command-config "$CFG" describe | grep kraft.version
#  Feature: kraft.version ... FinalizedVersionLevel: 1
kafka-features --bootstrap-server "$B" --command-config "$CFG" describe | grep confluent.metadata.version
kafka-broker-api-versions --bootstrap-server "$B" --command-config "$CFG" | grep '(id:'
#  4 行（id: 101..104），且 rack: rack-a / rack-b 都出現
```

### 5.3.3 內部 mTLS（#6–#7）
```bash
timeout 40 kafka-metadata-quorum --bootstrap-controller "$CB" --command-config $CD/nocert.properties describe --status   # 應失敗（SSL handshake）
kafka-metadata-quorum --bootstrap-controller "$CB" --command-config "$CFG" describe --status                            # 應成功
```

### 5.3.4 App over SCRAM + RBAC（#8–#11）
```bash
M=manual-$(date +%s)
P "$BC" $CD/app-orders-scram.properties orders.events "$M"                      # 無錯誤
kafka-console-consumer --bootstrap-server "$BC" --consumer.config $CD/app-orders-scram.properties \
  --topic orders.events --group orders-verify --from-beginning --timeout-ms 45000 | grep -F "$M"   # 找得到
P "$BC" $CD/app-orders-scram.properties payments.events "$M"                    # TopicAuthorizationException
# 錯誤密碼：用 PLAIN/錯密碼的設定打 CLIENT listener -> 認證失敗
```

### 5.3.5 人員 LDAP + MDS（#12–#15）
```bash
P "$BL" $CD/alice-ldap.properties payments.events "$M-alice"                    # 成功
P "$BL" $CD/carol-ldap.properties orders.events  "$M-carol"                     # 被拒
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem -u 'alice:<password>' https://kb01.poc.lab:8090/security/1.0/authenticate   # 200
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem -u 'alice:wrong'      https://kb01.poc.lab:8090/security/1.0/authenticate   # 401
```

### 5.3.6 REST Proxy 經 LB（#16–#22）
```bash
BASE=https://rest.poc.lab:8082/v3/clusters
C="--cacert $PKI/ca.pem --cert $PKI/app-legacy-billing.crt --key $PKI/app-legacy-billing.key"
curl -s -o /dev/null -w '%{http_code}\n' $C $BASE                               # 200
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem $BASE             # 000
for t in billing.events orders.events; do
  curl -s $C -X POST -H 'Content-Type: application/json' \
    -d '{"value":{"type":"JSON","data":{"source":"manual"}}}' "$BASE/$CID/topics/$t/records" | grep -o '"error_code":[0-9]*' | head -1
done                                                                            # "error_code":200 / "error_code":40301
for c in cp-server kafka-internal; do
  curl -s -o /dev/null -w "$c %{http_code}\n" --cacert $PKI/ca.pem --cert $PKI/$c.crt --key $PKI/$c.key "$BASE/$CID/topics"
done                                                                            # 401（不能是 200）
kafka-configs --bootstrap-server "$B" --command-config "$CFG" --describe --entity-type users --entity-name app-legacy-billing   # 不含 SCRAM-SHA-512
```
注意：REST v3 produce 的 HTTP 狀態是 200，成功與否要看 body 內每筆 record 的 `error_code`。

### 5.3.7 C3 與 Prometheus（#23–#25）
```bash
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem https://c3.poc.lab:9021/                       # 200
curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem https://c3-01.poc.lab:9090/-/ready              # 000
curl -s --cacert $PKI/ca.pem --cert $PKI/cp-server.crt --key $PKI/cp-server.key \
  https://c3-01.poc.lab:9090/api/v1/label/__name__/values | grep -o 'io_confluent_kafka_server[a-z_]*' | sort -u | wc -l   # > 0
```

### 5.3.8 Audit、離線、套件、JMX（#26–#36）
```bash
kafka-topics --bootstrap-server "$B" --command-config "$CFG" --describe --topic confluent-audit-log-events
kafka-console-consumer --bootstrap-server "$B" --consumer.config "$CFG" --topic confluent-audit-log-events_sensitive \
  --from-beginning --timeout-ms 30000 2>/dev/null |
  jq -R -n '[inputs|fromjson?|select(.data.authenticationInfo.principal=="User:alice" and .data.authorizationInfo.granted==true and (.data.methodName|test("^kafka.Produce$")))]|length'   # > 0
#  同上把 principal 換成 User:app-orders、granted==false -> > 0
ssh cpadmin@kb01.poc.lab 'sudo grep "^super.users" /etc/confluent/kafka/server.properties'   # 不含 User:confluent-audit
for h in kb01 rest01 c3-01; do ssh cpadmin@$h.poc.lab 'curl -s -m 5 -o /dev/null https://packages.confluent.io; echo rc=$?'; done   # rc≠0
curl -s -m 5 -o /dev/null https://packages.confluent.io; echo rc=$?                                                            # ops01 本機，rc≠0
ssh cpadmin@kb01.poc.lab 'sudo dnf versionlock list | grep confluent-server'                                                 # 有輸出
ssh cpadmin@c3-01.poc.lab 'rpm -q confluent-server confluent-common; test -e /opt/confluent/current; echo $?'                # not installed / 1
# JMX：見 5.4 monitoring check
```

### 5.3.9 OP 選單（#37–#47，在 jump01 上以 opuser 非互動執行）

測試只在 PROFILE=poc 才可行：用 `/etc/opmenu/opmenu-test.conf`（`OPMENU_ALLOW_ENV_OVERRIDE=1`）以環境變數帶入 AD 帳密與工單號。結果看 `/var/log/opmenu/opmenu.log` 最後一行（以 ` | ` 分隔，第 3 欄＝AD 使用者，第 7 欄＝RESULT）。

```bash
# ops01 -> jump01
R() { ssh cpadmin@jump01.poc.lab "sudo -n -u opuser env OPMENU_CONF=${CONF:-/etc/opmenu/opmenu-test.conf} OPMENU_USER=$1 OPMENU_PASS='$2' \
  OPMENU_TICKET=CHG-2026-0001 OPMENU_YES=1 OPMENU_REASON=verify /opt/opmenu/opmenu.sh --run ${*:3} </dev/null 2>&1; \
  echo \"@@LOG@@ \$(sudo -n tail -1 /var/log/opmenu/opmenu.log)\""; }
R alice '<password>' 12                                            # #37 RESULT=OK；#38 第 3 欄=alice（不是 opuser）
R alice wrong-password 12                                          # #39 AUTH_FAIL
R bob   '<password>' 23 kb01.poc.lab:confluent-server 20           # #40 OK（經 ssh kafkaops 看 broker log）
R carol '<password>' 23 kb01.poc.lab:confluent-server 20           # #41 DENIED（MDS authorize 擋下主機操作）
R carol '<password>' 22 rest01.poc.lab:confluent-kafka-rest        # #42 DENIED（不能重啟 REST）
# #43 item 21 安全檢查無法執行時必須拒絕（fail closed）
ssh cpadmin@jump01.poc.lab "printf '. /etc/opmenu/opmenu-test.conf\nOPMENU_BOOTSTRAP=nowhere.invalid:9096\n' | sudo -n tee /tmp/opmenu-broken.conf >/dev/null; sudo -n chmod 0644 /tmp/opmenu-broken.conf"
CONF=/tmp/opmenu-broken.conf R alice '<password>' 21 kb01.poc.lab:confluent-server   # 輸出含「無法檢查」且不含「已重啟」
ssh cpadmin@jump01.poc.lab 'sudo -n rm -f /tmp/opmenu-broken.conf'
R alice '<password>' 91 kafka-topics --list                        # #44 輸出含 orders.events（break-glass 憑證身分）
ssh cpadmin@jump01.poc.lab "sudo -n grep -q '| alice | 91 bootstrap .*| EMERGENCY |' /var/log/opmenu/opmenu.log && echo ok"   # #45
ssh cpadmin@jump01.poc.lab 'sudo -n su - opuser -c id </dev/null 2>&1'   # #46 輸出不可含 uid=
ssh cpadmin@jump01.poc.lab 'sudo -n -u opuser cat /etc/opmenu/bootstrap/breakglass.key'   # #47 必須 Permission denied
```
警告：#43 的 item 21 是「重啟 broker」；fail-closed 檢查前務必確認 broken conf 已生效，否則會真的重啟。

### 5.3.10 憑證（#48）
```bash
openssl s_client -connect kb01.poc.lab:8090 -servername kb01.poc.lab </dev/null 2>/dev/null | openssl x509 -noout -serial
openssl x509 -noout -serial -in $PKI/cp-server.crt          # 兩者相同
```

## 5.4 外部監控（JMX exporter、`cpctl monitoring export|check`）

- **目的**：讓銀行既有的 Prometheus/Alertmanager 抓取每台 controller / broker / REST 的指標（與 C3 內建 Prometheus 分開）。Exporter 以 javaagent 跑在 :7071，HTTPS（用節點自己的 keystore）+ basic auth（設定檔只存 salted SHA-256 雜湊）。
- **在哪裡設定**：05（configure）時，`role::jmx_exporter`；09 不另外處理。
  - jar：`/srv/repo/raw/tools/jmx_prometheus_javaagent-1.0.1.jar` → 各節點 `/opt/jmx-exporter/`（root 0644）
  - 設定：`/etc/confluent/<kafka|kafka-rest>/jmx-exporter.yml`（root:confluent 0640）= `exporter-http.yml.tpl` + `rules-kafka.yml` / `rules-rest.yml`
  - keystore：broker 與 REST 用 `cp-server`，controller 用 `kafka-internal`
  - 啟動參數：`-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar=7071:/etc/confluent/<comp>/jmx-exporter.yml`（broker/controller 走 `KAFKA_OPTS`，REST 走 `KAFKAREST_OPTS`）
  - firewalld 需開 7071/tcp（銀行 Prometheus → 每台 controller/broker/REST）
- **設定檔內容**：
```yaml
httpServer:
  ssl:
    keyStore:
      filename: /etc/confluent/ssl/cp-server.p12      # controller 為 kafka-internal.p12
      password: <password>
      type: PKCS12
    certificate:
      alias: cp-server
  authentication:
    basic:
      username: prometheus
      passwordHash: <sha256 hex>
      algorithm: SHA-256
      salt: <salt>                                     # /var/lib/cp-installer/jmx-exporter.salt，每叢集固定
lowercaseOutputName: true
lowercaseOutputLabelNames: true
# 以下接 rules-kafka.yml / rules-rest.yml
```
  雜湊算法（ops01）：`printf '%s:%s' "$(cat /var/lib/cp-installer/jmx-exporter.salt)" '<password>' | sha256sum | awk '{print $1}'`（salt 不存在時 `openssl rand -hex 16` 產生一次，0600）。
- **`cpctl monitoring export` 的手動等價**：在 `/var/lib/cp-installer/monitoring/`（0700）產生：
  - `prometheus-scrape.yml`：三個 job `confluent-controller` / `confluent-broker` / `confluent-rest`，`scheme: https`、`scrape_interval: 30s`、`tls_config.ca_file: /etc/prometheus/confluent/ca.pem`、`basic_auth.username: prometheus`、`password_file: /etc/prometheus/confluent/jmx-exporter.password`（密碼走 vault，不寫在檔案）、targets 為各主機 `<fqdn>:7071`、label `cluster: poc-cluster`
  - `alert-rules.yml`：複製 `templates/default/monitoring/alert-rules.yml`（9 條：KafkaTargetDown〔critical〕、KafkaUnderReplicatedPartitions、KafkaUnderMinIsrPartitions〔critical〕、KafkaOfflinePartitions〔critical〕、KafkaActiveControllerCount〔critical〕、KafkaRequestHandlerSaturated、KafkaNetworkProcessorSaturated、KafkaProduceLatencyHigh、JvmHeapHigh）
  - `ca.pem`（CA 輪替後要重新匯出）、`README.txt`
- **`cpctl monitoring check` 的手動等價**（ops01）：
```bash
for h in kc01 kc02 kc04 kb01 kb02 kb03 kb04 rest01 rest02; do
  u=https://$h.poc.lab:7071/metrics
  a=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert $PKI/ca.pem $u)           # 預期 401
  m=$(curl -s --max-time 20 --cacert $PKI/ca.pem -u 'prometheus:<password>' $u | grep -cE '^(kafka_|jvm_)')   # 預期 > 0
  echo "$h anon=$a metrics=$m"
done
```
- **注意事項**：
  - 先把輸出存到變數再 grep（`curl | grep -q` 在 `pipefail` 下會因 SIGPIPE 誤判失敗）。
  - consumer lag 不是 broker JMX 指標：用 C3 或另外的 lag exporter。
  - salt 固定是為了冪等（同輸入 → 同檔案 → 不重啟）；換 salt 或換密碼都會觸發滾動重啟。

# 6. 堡壘機 OP menu(步驟 11)

## 6.0 概要

情境（銀行）：跳板機與節點**不加入 AD**，只有固定帳號。

| 主機 | 帳號 | 用途 |
|---|---|---|
| jump01 | `opuser` | 固定操作帳號；login shell = 選單（sshd `ForceCommand`）。**身分＝操作員自己的 AD 帳號**（選單登入時由 MDS 驗證），OS 帳號共用所以不是身分 |
| jump01 | `opbootstrap` | 系統帳號（nologin），持有 break-glass 憑證；只能透過 `/usr/local/sbin/opmenu-bootstrap` 使用 |
| 各節點 | `kafkaops` | 只接受 jump01 IP 來的 opuser 金鑰；sudo 只能重啟自己的 unit、看 journalctl、清舊 log |

`cpadmin`（cpctl）不被選單使用：平台變更走 cpctl，日常維運走選單。
啟用條件：`OPMENU=on` 且 inventory 有 `HOSTS_jump`。前提：jump01 已裝 `confluent-server confluent-security`（只用 Kafka CLI，不跑服務；`PKGS_JUMP`）、03 已簽 `opmenu-breakglass` 憑證、`/srv/repo/raw/tools/opmenu-20261016.f03b18c0.tar.gz` 已匯入內部 repo。

## 6.1 固定帳號（jump01）

- **目的**：建立 `opmenu` 群組、`opuser`（shell=選單、在 opmenu 群組）、`opbootstrap`（系統帳號、家目錄 `/etc/opmenu/bootstrap`、nologin，**刻意不在** opmenu 群組）。
- **主機/帳號**：jump01 / root。
- **手動指令**：
```bash
getent group opmenu || groupadd opmenu
if id opuser >/dev/null 2>&1; then usermod -s /opt/opmenu/opmenu.sh -aG opmenu opuser
else useradd -m -G opmenu -s /opt/opmenu/opmenu.sh opuser; fi
id opbootstrap >/dev/null 2>&1 || useradd -r -m -d /etc/opmenu/bootstrap -s /sbin/nologin opbootstrap
```
- **驗證**：
```bash
getent passwd opuser opbootstrap; getent group opmenu
# opuser:x:1001:1002::/home/opuser:/opt/opmenu/opmenu.sh
# opbootstrap:x:991:991::/etc/opmenu/bootstrap:/sbin/nologin
# opmenu:x:1001:opuser
```
- **對應 cpctl**：`opmenu_node::jump_accounts`。
- **注意事項**：`/opt/opmenu/opmenu.sh` 若不在 `/etc/shells`，部分 PAM/FTP 設定會拒絕登入；ssh 本身靠 ForceCommand 不受影響。`useradd -r -m -d /etc/opmenu/bootstrap` 會順手建立目錄（含 skel 檔），6.4 再修正權限。此時選單程式還沒裝(6.2),`useradd` 會警告 `missing or non-executable shell '/opt/opmenu/opmenu.sh'`,屬正常,6.2 裝好後就存在。

## 6.2 安裝 opmenu 套件（從內部 repo）

- **目的**：以內容定址的版本（`OPMENU_VERSION=20261016.f03b18c0`）安裝到 `/opt/opmenu-<版本>`，`/opt/opmenu` 為 symlink，可並存多版、快速回退。
- **主機/帳號**：ops01（cpadmin）→ jump01（root）。
- **手動指令**：
```bash
# ops01
V=20261016.f03b18c0
test -f /srv/repo/raw/tools/opmenu-$V.tar.gz        # 不存在：先在 Windows 端 package-opmenu.sh，再 repo import
scp /srv/repo/raw/tools/opmenu-$V.tar.gz cpadmin@jump01.poc.lab:/tmp/
# jump01（root）
V=20261016.f03b18c0
install -d -o root -g root -m 0755 /var/cache/cp-installer
install -o root -g root -m 0644 /tmp/opmenu-$V.tar.gz /var/cache/cp-installer/opmenu-$V.tar.gz
if [ ! -x /opt/opmenu-$V/opmenu.sh ]; then
  t=$(mktemp -d); tar -xzf /var/cache/cp-installer/opmenu-$V.tar.gz -C "$t"
  test -x "$t/opmenu/opmenu.sh" || { echo "package has no opmenu/opmenu.sh"; exit 1; }
  chown -R root:root "$t/opmenu"; chmod -R go-w "$t/opmenu"
  mv "$t/opmenu" /opt/opmenu-$V; rm -rf "$t"
fi
ln -sfn /opt/opmenu-$V /opt/opmenu
```
- **驗證**：`ls -l /opt | grep opmenu` → `opmenu -> /opt/opmenu-20261016.f03b18c0`；`test -x /opt/opmenu/opmenu.sh && echo ok`。
- **對應 cpctl**：`role::jump::configure`（套件段）、`opmenu_node::install_pkg`、`ensure::symlink`。
- **注意事項**：程式碼必須 root 擁有且不可被 group/other 寫入，否則 opuser 可竄改自己的 login shell。

## 6.3 /etc/opmenu 設定與信任材料

- **目的**：選單用自己的 truststore（**獨立密碼** `OPMENU_TRUSTSTORE_PASSWORD`；`STORE_PASSWORD` 同時能開 keystore，絕不放到跳板機）；`opmenu.conf` 不含任何密碼。
- **主機/帳號**：ops01（cpadmin）建 truststore → jump01（root）。
- **手動指令**：
```bash
# ops01：由 ca.pem（可能含多張 CA，輪替期間）建 PKCS12 truststore
cd /var/lib/cp-installer/pki
d=$(mktemp -d); awk -v d="$d" '/BEGIN CERT/{n++} {print > (d "/ca-" n ".pem")}' ca.pem
rm -f opmenu-truststore.p12; i=0
for f in "$d"/ca-*.pem; do i=$((i+1))
  /usr/lib/jvm/temurin-21-jdk/bin/keytool -importcert -noprompt -alias internal-ca-$i -file "$f" \
    -keystore opmenu-truststore.p12 -storetype PKCS12 -storepass '<password>'
done; rm -rf "$d"
# jump01（root）
install -d -o root -g root   -m 0755 /etc/opmenu
install -d -o root -g opmenu -m 0750 /etc/opmenu/certs
install -o root -g opmenu -m 0640 /tmp/opmenu-truststore.p12 /etc/opmenu/certs/truststore.p12
( umask 027; printf '%s' '<password>' > /etc/opmenu/certs/truststore_creds ); chown root:opmenu /etc/opmenu/certs/truststore_creds; chmod 0640 /etc/opmenu/certs/truststore_creds
install -o root -g opmenu -m 0644 /tmp/ca.pem             /etc/opmenu/certs/ca.pem
install -o root -g opmenu -m 0644 /tmp/cp-server.crt      /etc/opmenu/certs/cp-server.pem        # 選單 item 17 顯示到期日用
install -o root -g opmenu -m 0644 /tmp/kafka-internal.crt /etc/opmenu/certs/kafka-internal.pem
install -o root -g root   -m 0644 /tmp/opmenu.conf        /etc/opmenu/opmenu.conf
install -d -o root -g opmenu -m 2775 /var/log/opmenu      # setgid：log 檔群組固定為 opmenu
# 僅 PROFILE=poc（自動化測試用，prod 絕不產生）
printf '. /etc/opmenu/opmenu.conf\nOPMENU_ALLOW_ENV_OVERRIDE=1\n' > /etc/opmenu/opmenu-test.conf
chown root:opmenu /etc/opmenu/opmenu-test.conf; chmod 0640 /etc/opmenu/opmenu-test.conf
```
- **設定檔內容**（`/etc/opmenu/opmenu.conf`，實際值）：
```bash
OPMENU_BACKEND=vm
OPMENU_ENV_LABEL=POC
OPMENU_LOG=/var/log/opmenu/opmenu.log
OPMENU_OUT_DIR=/var/log/opmenu
OPMENU_SYSLOG=1
OPMENU_ALLOW_ENV_OVERRIDE=0                     # 正式設定不接受環境變數覆蓋
# Kafka：LDAP listener（SASL PLAIN -> AD），用操作員自己的帳密；MDS 在每台 broker
OPMENU_BOOTSTRAP='kb01.poc.lab:9096,kb02.poc.lab:9096,kb03.poc.lab:9096,kb04.poc.lab:9096'
OPMENU_MDS_URL='https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090'
OPMENU_KAFKA_CLUSTER_ID='jjRYywATQBGIf11rBTcNGg'
OPMENU_CERT_DIR=/etc/opmenu/certs
# 允許重啟 / ssh 的白名單（來自 inventory）
OPMENU_BROKER_SERVICES='kb01.poc.lab:confluent-server kb02.poc.lab:confluent-server kb03.poc.lab:confluent-server kb04.poc.lab:confluent-server'
OPMENU_AUX_SERVICES='rest01.poc.lab:confluent-kafka-rest rest02.poc.lab:confluent-kafka-rest c3-01.poc.lab:confluent-control-center'
OPMENU_CONTROLLER_HOSTS='kc01.poc.lab kc02.poc.lab kc04.poc.lab'
OPMENU_DATA_DIR=/var/lib/kafka/data
# 固定帳號
OPMENU_USER_FROM_OS=0                           # 不以 OS 帳號當身分
OPMENU_SSH_USER=kafkaops
OPMENU_SSH_AUTH=key
OPMENU_HOST_ACTION_AUTHZ='Topic:__opmenu-host-ops:Describe'   # 主機操作前先問 MDS authorize
# 政策
OPMENU_TICKET_MODE=required
OPMENU_TICKET_CHECK=format
OPMENU_CHANGE_WINDOW=''                         # 空＝不限制
OPMENU_IDLE_TIMEOUT=900
OPMENU_AUDIT_TOPIC=confluent-audit-log-events
OPMENU_BREAKGLASS_BOOTSTRAP='kb01.poc.lab:9092,kb02.poc.lab:9092,kb03.poc.lab:9092,kb04.poc.lab:9092'   # INTERNAL（mTLS）
export PATH="/usr/bin:$PATH" JAVA_HOME="/usr/lib/jvm/temurin-21-jdk"
```
- **驗證**：`ls -la /etc/opmenu /etc/opmenu/certs`（certs 為 `root:opmenu 0750`；truststore.p12、truststore_creds 為 0640）。
- **對應 cpctl**：`jump::vars`、`pki::truststore_named`、`role::push_rendered opmenu/opmenu.conf.tpl`。
- **注意事項**：CA 輪替（`cpctl certs rotate-ca`）後要重建 opmenu truststore 並重推（cpctl 以 `opmenu-truststore.p12.bundle.sha256` 判斷）。

## 6.4 Break-glass 憑證（opbootstrap）

- **目的**：選單 item 91（緊急）與第二人查詢使用的憑證身分 `CN=opmenu-breakglass`（RBAC SystemAdmin，**不是** super user：可稽核、一筆綁定即可撤銷）。重新匯出成獨立密碼的 p12，只有 opbootstrap 讀得到；操作員永遠看不到憑證。
- **主機/帳號**：ops01（cpadmin）→ jump01（root）。
- **手動指令**：
```bash
# ops01：.crt 比 .bg.p12 新時才重做
cd /var/lib/cp-installer/pki
 openssl pkcs12 -export -name opmenu-breakglass -inkey opmenu-breakglass.key -in opmenu-breakglass.crt \
   -certfile ca.crt -passout 'pass:<password>' -out opmenu-breakglass.bg.p12     # OPMENU_BREAKGLASS_STORE_PASSWORD
chmod 0600 opmenu-breakglass.bg.p12
# jump01（root）：全部 opbootstrap:opbootstrap
install -d -o opbootstrap -g opbootstrap -m 0700 /etc/opmenu/bootstrap
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-breakglass.bg.p12 /etc/opmenu/bootstrap/breakglass.p12
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-breakglass.crt    /etc/opmenu/bootstrap/breakglass.pem
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-breakglass.key    /etc/opmenu/bootstrap/breakglass.key
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-truststore.p12    /etc/opmenu/bootstrap/truststore.p12   # 自有一份：opbootstrap 進不了 certs/
install -o opbootstrap -g opbootstrap -m 0644 /tmp/ca.pem                   /etc/opmenu/bootstrap/ca.pem
install -o opbootstrap -g opbootstrap -m 0600 /tmp/breakglass.properties    /etc/opmenu/bootstrap/breakglass.properties
install -o root -g root -m 0755 /tmp/opmenu-bootstrap /usr/local/sbin/opmenu-bootstrap
shred -u /tmp/opmenu-breakglass.key /tmp/opmenu-breakglass.bg.p12 2>/dev/null
```
- **設定檔內容**：
  `breakglass.properties`：
```properties
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/opmenu/bootstrap/breakglass.p12
ssl.keystore.password=<password>
ssl.key.password=<password>
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/opmenu/bootstrap/truststore.p12
ssl.truststore.password=<password>
ssl.endpoint.identification.algorithm=https
```
  `/usr/local/sbin/opmenu-bootstrap` 介面：`opmenu-bootstrap kafka <kafka-*工具> <參數>`（只允許 `kafka-*`，自動帶 `--bootstrap-server $OPMENU_BREAKGLASS_BOOTSTRAP --command-config breakglass.properties`）；`opmenu-bootstrap mds <METHOD> <path> [json]`（以 break-glass 憑證呼叫 MDS，最後一行 `HTTP <code>`，多台 MDS 依序嘗試）。腳本完整內容見附錄 D.4,原樣放到 `/usr/local/sbin/opmenu-bootstrap`(root:root 0755)。
- **驗證**：
```bash
ls -la /etc/opmenu/bootstrap                                   # 目錄 0700、金鑰/p12/properties 0600，皆 opbootstrap
sudo -u opbootstrap /usr/local/sbin/opmenu-bootstrap kafka kafka-topics --list | grep orders.events   # 需先完成 6.9 綁定
sudo -n -u opuser cat /etc/opmenu/bootstrap/breakglass.key     # Permission denied
```
- **對應 cpctl**：`role::jump::configure`（break-glass 段）、`jump::put_tpl`。
- **注意事項**：`OPMENU_BREAKGLASS` 也被加入 broker 的 `impersonation.protected.users`，REST Proxy 不能冒充它。

## 6.5 sudoers（jump01，visudo 先驗證）

- **目的**：opuser 唯一的 sudo 權限：以 opbootstrap 身分執行 wrapper。
- **主機/帳號**：ops01 驗證 → jump01（root）安裝。
- **手動指令**：
```bash
# ops01
printf '# Managed by cpctl - OP menu bastion\nopuser ALL=(opbootstrap) NOPASSWD: /usr/local/sbin/opmenu-bootstrap\n' > /tmp/opmenu.sudoers
/usr/sbin/visudo -cqf /tmp/opmenu.sudoers && echo valid        # 不合法就停：壞掉的 sudoers 會鎖死 sudo
scp /tmp/opmenu.sudoers cpadmin@jump01.poc.lab:/tmp/
# jump01（root）
install -o root -g root -m 0440 /tmp/opmenu.sudoers /etc/sudoers.d/opmenu
visudo -c
```
- **驗證**：`sudo -l -U opuser` → `(opbootstrap) NOPASSWD: /usr/local/sbin/opmenu-bootstrap`。
- **對應 cpctl**：`jump::put_sudoers`。

## 6.6 sshd Match 區塊（jump01）

- **目的**：opmenu 群組成員透過 ssh 也只能進選單，禁止所有 forwarding / tunnel。
- **主機/帳號**：jump01 / root。
- **設定檔內容**（`/etc/ssh/cpctl-opmenu.block`，附加在 `sshd_config` **最後**，前後有標記）：
```
# BEGIN cpctl opmenu
PermitUserEnvironment no
Match Group opmenu
  ForceCommand /opt/opmenu/opmenu.sh
  AllowTcpForwarding no
  AllowAgentForwarding no
  X11Forwarding no
  PermitTunnel no
  PermitTTY yes
# END cpctl opmenu
```
- **手動指令**：
```bash
cfg=/etc/ssh/sshd_config; t=$(mktemp)
sed '/^# BEGIN cpctl opmenu$/,/^# END cpctl opmenu$/d' "$cfg" > "$t"         # 移除舊區塊
{ echo '# BEGIN cpctl opmenu'; cat /etc/ssh/cpctl-opmenu.block; echo '# END cpctl opmenu'; } >> "$t"
sshd -t -f "$t" || { echo "sshd -t rejected"; rm -f "$t"; exit 1; }
cp -p "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
cat "$t" > "$cfg"; rm -f "$t"                                                # cat > 保留原檔權限/SELinux label
systemctl reload sshd
```
- **驗證**：`tail -12 /etc/ssh/sshd_config`；`sshd -T -C user=opuser,host=x,addr=127.0.0.1 | grep -i forcecommand` → `forcecommand /opt/opmenu/opmenu.sh`。另開一個 session 確認自己仍能以 cpadmin 登入後再關舊 session。全程實測時,reload 後立刻 ssh 的那一次失敗(rc=255),幾秒後重試就正常;所以 reload 後稍等再測,不要因為第一次失敗就以為被鎖在外面。
- **對應 cpctl**：`opmenu_node::sshd_block`。
- **注意事項**：`Match` 必須在最後；放在前面的 `Include`（例如 `sshd_config.d/`）裡會吞掉其後所有主設定。

## 6.7 opuser 的 ssh 金鑰與 known_hosts（jump01）

- **目的**：opuser 以 ed25519 金鑰 ssh 到節點（私鑰不離開跳板機）；節點 host key 預先釘在全域 `/etc/ssh/ssh_known_hosts`（root 擁有，opuser 不能改）。
- **主機/帳號**：jump01 / root。
- **手動指令**：
```bash
h=$(getent passwd opuser | cut -d: -f6)
if [ ! -s $h/.ssh/id_ed25519 ]; then
  install -d -o opuser -g opuser -m 0700 $h/.ssh
  sudo -u opuser ssh-keygen -q -t ed25519 -N '' -C "opuser@$(hostname -s)" -f $h/.ssh/id_ed25519
fi
N="kc01.poc.lab kc02.poc.lab kc04.poc.lab kb01.poc.lab kb02.poc.lab kb03.poc.lab kb04.poc.lab rest01.poc.lab rest02.poc.lab c3-01.poc.lab"
t=$(mktemp)
{ echo '# Managed by cpctl - node host keys for the OP menu'; ssh-keyscan -T 5 -t ed25519 $N 2>/dev/null | sort; } > "$t"
[ "$(grep -vc '^#' "$t")" -eq 10 ] || { echo "keyscan incomplete"; exit 1; }
install -o root -g root -m 0644 "$t" /etc/ssh/ssh_known_hosts; rm -f "$t"
```
- **驗證**：`grep -vc '^#' /etc/ssh/ssh_known_hosts` → `10`；`ls -la ~opuser/.ssh` → `id_ed25519`（0600）、`id_ed25519.pub`。
- **對應 cpctl**：`opmenu_node::user_key`、`opmenu_node::known_hosts`。
- **注意事項**：`ssh-keyscan` 是首次信任（TOFU）；生產環境應以節點 console 上的 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` 指紋人工比對。opuser 的 shell 是選單，所以要用 `sudo -u opuser <cmd>`（直接執行），不要用 `su - opuser`。節點 host key 重產後需重跑此步。

## 6.8 各節點的 kafkaops 帳號（kc01 kc02 kc04 kb01–kb04 rest01 rest02 c3-01）

- **目的**：選單經 ssh 使用的固定節點帳號；只接受 jump01 IP 來的 opuser 金鑰；sudo 精確到「本機 unit」。
- **主機/帳號**：ops01（cpadmin）取公鑰 → 每個節點（root）。
- **手動指令**：
```bash
# ops01：組 authorized_keys 行（來源 IP 綁定）
IP=$(getent hosts jump01.poc.lab | awk '{print $1; exit}')            # PoC：172.30.0.13
PUB=$(ssh cpadmin@jump01.poc.lab 'sudo -n cat ~opuser/.ssh/id_ed25519.pub')
printf 'from="%s",no-port-forwarding,no-agent-forwarding,no-X11-forwarding %s\n' "$IP" "$PUB" > /tmp/kafkaops.authorized_keys
# ops01：每台節點的 sudoers（UNIT 依角色：kc*/kb* = confluent-server；rest* = confluent-kafka-rest；c3-01 = confluent-control-center）
UNIT=confluent-server
cat > /tmp/opmenu-kafkaops.sudoers <<EOF
# Managed by cpctl - fixed node account of the OP menu: only these commands, only these units
Defaults:kafkaops !requiretty
kafkaops ALL=(root) NOPASSWD: /usr/bin/systemctl restart $UNIT
kafkaops ALL=(root) NOPASSWD: NOEXEC: /usr/bin/journalctl -u $UNIT -n * --no-pager
kafkaops ALL=(root) NOPASSWD: NOEXEC: /usr/bin/journalctl -u confluent-\* -n 500 --no-pager
kafkaops ALL=(root) NOPASSWD: /usr/local/sbin/opmenu-clean-logs
EOF
/usr/sbin/visudo -cqf /tmp/opmenu-kafkaops.sudoers && echo valid
# 節點（root）
id kafkaops >/dev/null 2>&1 || { useradd -m -s /bin/bash kafkaops; passwd -l kafkaops; }
h=$(getent passwd kafkaops | cut -d: -f6)
install -d -o root -g kafkaops -m 0750 $h/.ssh
install -o root -g kafkaops -m 0640 /tmp/kafkaops.authorized_keys $h/.ssh/authorized_keys   # root 擁有：帳號不能自己加 key
install -o root -g root -m 0755 /tmp/opmenu-clean-logs /usr/local/sbin/opmenu-clean-logs
install -o root -g root -m 0440 /tmp/opmenu-kafkaops.sudoers /etc/sudoers.d/opmenu-kafkaops
visudo -c
```
- **設定檔內容**：`opmenu-clean-logs <天數>`：只刪 `/var/log/kafka`、`/var/log/confluent` 下 `*.log.*`、`*.log-*`、`*.gz` 且 `-mtime +N`（N≥1）的檔案；絕不碰 Kafka 資料目錄與目前的 log。腳本完整內容見附錄 D.5(root:root 0755)。
- **驗證**（kb01 實際）：
```bash
passwd -S kafkaops                         # kafkaops LK ...（Password locked.）
ls -la ~kafkaops/.ssh                      # drwxr-x--- root kafkaops；authorized_keys -rw-r----- root kafkaops
cut -c1-80 ~kafkaops/.ssh/authorized_keys  # from="172.30.0.13",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 ...
sudo -l -U kafkaops                        # 只列出上面 4 條
# 從 jump01：sudo -u opuser ssh kafkaops@kb01.poc.lab sudo -n /usr/bin/journalctl -u confluent-server -n 5 --no-pager
```
- **對應 cpctl**：`jump::authorized_keys`、`role::jump::node_access`、`opmenu_node::node_account`、`jump::units_of`、`jump::node_hosts`、`jump::put_sudoers`。
- **注意事項**：
  - sudoers 的命令比對是**完全字串**：選單必須以 `/usr/bin/systemctl restart confluent-server` 原樣呼叫；多一個參數就會要求密碼（帳號已鎖 → 失敗）。
  - `NOEXEC` 防止從 pager 逃逸到 shell。
  - `from="<ip>"` 綁 jump01 IP；跳板機換 IP 或新增第二台跳板機，需重產所有節點的 authorized_keys（一台跳板機一行）。
  - 本步只在非 check 模式執行（需先有跳板機公鑰）。

## 6.9 Break-glass 的 RBAC 綁定

- **目的**：給 `User:opmenu-breakglass` SystemAdmin。
- **主機/帳號**：ops01 / cpadmin（已 5.1.2 MDS 登入）。
- **手動指令**：
```bash
cfl iam rbac role-binding create --principal User:opmenu-breakglass --role SystemAdmin --kafka-cluster $CID
```
- **驗證**：MDS lookup → `{"User:opmenu-breakglass":{"SystemAdmin":[]}}`。
- **對應 cpctl**：11 `step_apply` 結尾的 `rbac::ensure "User:$OPMENU_BREAKGLASS" SystemAdmin`。
- **注意事項**：撤銷 = `cfl iam rbac role-binding delete --principal User:opmenu-breakglass --role SystemAdmin --kafka-cluster $CID`（立即生效，不需重啟）。

## 6.10 Step 11 總驗證
```bash
ssh cpadmin@jump01.poc.lab 'test -x /opt/opmenu/opmenu.sh && sudo -n -u opuser /opt/opmenu/opmenu.sh --list >/dev/null && echo ok'
```
完整功能測試見 5.3.9（`cpctl verify` 在 11 的 stamp 存在後才會跑選單相關 11 項）。

# 7. tar.gz 安裝方式

這一章說明不用 RPM、改用 tar.gz 安裝時,和 rpm 主線不同的地方。以下指令都在 kc03 上實際跑過(附錄 A 第 H 段),以 controller 為例;broker 完全相同,REST Proxy 只差 unit 名稱(`confluent-kafka-rest`)與服務帳號(`cp-kafka-rest`)。

不變的部分:01 OS 基線、03 憑證、05 設定檔(`/etc/confluent/kafka/*`)、06 格式化參數、07 啟動順序都和 rpm 相同。設定檔裡沒有寫死任何 RPM 路徑,可以直接沿用。

## 7.1 服務帳號與目錄

目的:RPM 安裝時,服務帳號與目錄由 RPM scriptlet 建立;tar.gz 沒有 scriptlet,要自己建。

主機 / 帳號:kc、kb(cp-kafka);rest(cp-kafka-rest);c3(cp-control-center)。cpadmin 經 sudo。

```
ssh kc03.poc.lab "getent group confluent >/dev/null || sudo groupadd -r confluent"
ssh kc03.poc.lab "id cp-kafka >/dev/null 2>&1 || sudo useradd -r -g confluent -d /var/lib/kafka -M -s /sbin/nologin -c 'Confluent (cp-kafka)' cp-kafka"
ssh kc03.poc.lab "sudo install -d -m 0750 -o cp-kafka -g confluent /var/lib/kafka /var/log/kafka"
```

驗證:

```
ssh kc03.poc.lab "id cp-kafka; sudo ls -ld /var/lib/kafka /var/log/kafka"
uid=993(cp-kafka) gid=997(confluent) groups=997(confluent)
drwxr-x--- 3 cp-kafka confluent 4096 Oct 16 11:09 /var/lib/kafka
drwxr-x--- 2 cp-kafka confluent 4096 Oct 16 11:09 /var/log/kafka
```

對應 cpctl:`install::prepare`(`lib/install/tar.sh`)→ `tar_node::account`、`ensure::dir`。

## 7.2 從內部 repo 取檔並驗證 sha256

目的:節點自己從 ops01 的 raw repo 下載 tar.gz,解壓前再驗一次 sha256。檔案在引進時已驗過,這裡再驗是為了防止傳輸中或 repo 上的檔案被換掉。

主機 / 帳號:所有 Java 節點;cpadmin 經 sudo。預期的 sha256 取自引進時產生的 `SHA256SUMS`(第 2 章)。

```
ssh kc03.poc.lab "sudo install -d -m 0755 /var/cache/cp-installer /opt/java /opt/confluent"
ssh kc03.poc.lab "cd /var/cache/cp-installer && sudo curl -fsS --cacert /etc/pki/tls/certs/cp-repo-ca.pem -o OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz https://ops01.poc.lab:8443/raw/tar/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz && sudo curl -fsS --cacert /etc/pki/tls/certs/cp-repo-ca.pem -o confluent-8.3.2.tar.gz https://ops01.poc.lab:8443/raw/tar/confluent-8.3.2.tar.gz"
ssh kc03.poc.lab "cd /var/cache/cp-installer && echo 'ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94  OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz' | sha256sum -c && echo '946433221bae8272de416694060322aef0c9c8b3086da9574f86d6cb0d698c2f  confluent-8.3.2.tar.gz' | sha256sum -c"
```

驗證:兩行都是 `OK`;再看壓縮檔最上層的目錄名稱,下一步解壓與 symlink 會用到:

```
ssh kc03.poc.lab "tar -tzf /var/cache/cp-installer/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz | head -1; tar -tzf /var/cache/cp-installer/confluent-8.3.2.tar.gz | head -1"
jdk-21.0.12.1+1/
confluent-8.3.2/
```

>! sha256 不符就停下來,不要解壓。cpctl 遇到不符時會刪掉快取檔並中止(`tar_node::fetch_extract` 回傳 4)。

## 7.3 解壓與 current symlink

目的:每個版本解壓到自己的目錄並存,服務一律從 `current` 啟動。升級時解壓新版、切換 symlink;回滾時切回舊版目錄即可。程式檔一律由 root 擁有、其他人不可寫,服務帳號只能讀。

```
ssh kc03.poc.lab "sudo tar -xzf /var/cache/cp-installer/OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz -C /opt/java --no-same-owner"
ssh kc03.poc.lab "sudo tar -xzf /var/cache/cp-installer/confluent-8.3.2.tar.gz -C /opt/confluent --no-same-owner"
ssh kc03.poc.lab "sudo chown -R root:root /opt/java/jdk-21.0.12.1+1 /opt/confluent/confluent-8.3.2 && sudo chmod -R go-w /opt/java/jdk-21.0.12.1+1 /opt/confluent/confluent-8.3.2"
ssh kc03.poc.lab "sudo ln -sfn /opt/java/jdk-21.0.12.1+1 /opt/java/current && sudo ln -sfn /opt/confluent/confluent-8.3.2 /opt/confluent/current"
```

驗證:

```
ssh kc03.poc.lab "ls -l /opt/java/current /opt/confluent/current; /opt/java/current/bin/java -version 2>&1 | head -1"
lrwxrwxrwx 1 root root 30 Oct 16 12:15 /opt/confluent/current -> /opt/confluent/confluent-8.3.2
lrwxrwxrwx 1 root root 25 Oct 16 12:15 /opt/java/current -> /opt/java/jdk-21.0.12.1+1
openjdk version "21.0.12.1" 2026-08-18 LTS
```

對應 cpctl:`install::ensure` → `tar_node::fetch_extract`(下載、驗證、解壓,並在 `/opt/confluent/.cpctl/` 留下記號,重跑時跳過)、`tar_node::switch`。

>! 安裝時如果 `current` 已經指向別的版本,cpctl 會拒絕切換(要走 `cpctl upgrade`)。手動操作時也一樣:安裝階段只建立 symlink,不要順手換版本。

## 7.4 systemd unit 與 drop-in

目的:RPM 會附帶 `confluent-server.service`;tar.gz 沒有,要自己提供一份等效的 unit。drop-in 和 rpm 版只差三個路徑:`ExecStart` 的 bin、`JAVA_HOME`、`log4j2.yaml`,都改指向 `current`。

`/etc/systemd/system/confluent-server.service`(root:root 0644):

```
[Unit]
Description=Confluent Server (Apache Kafka) - tar install
Documentation=https://docs.confluent.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cp-kafka
Group=confluent
ExecStart=/opt/confluent/current/bin/kafka-server-start /opt/confluent/current/etc/kafka/server.properties
TimeoutStopSec=180
Restart=no

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/confluent-server.service.d/10-cpctl.conf`(root:root 0644;controller 的 heap 為 PoC 值):

```
[Service]
ExecStart=
ExecStart=/opt/confluent/current/bin/kafka-server-start /etc/confluent/kafka/server.properties
Environment="JAVA_HOME=/opt/java/current"
Environment="KAFKA_HEAP_OPTS=-Xms384m -Xmx384m"
Environment="KAFKA_LOG4J_OPTS=-Dlog4j2.configurationFile=/opt/confluent/current/etc/kafka/log4j2.yaml"
Environment="LOG_DIR=/var/log/kafka"
Environment="KAFKA_OPTS=-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar=7071:/etc/confluent/kafka/jmx-exporter.yml"
EnvironmentFile=-/etc/confluent/kafka/service.env
LimitNOFILE=128000
TimeoutStopSec=180
Restart=on-failure
RestartSec=10
```

兩個檔案先在 ops01 準備好,再派送到節點:

```
scp -q confluent-server.service 10-cpctl.conf kc03.poc.lab:/tmp/
ssh kc03.poc.lab "sudo install -m 0644 -o root -g root /tmp/confluent-server.service /etc/systemd/system/confluent-server.service"
ssh kc03.poc.lab "sudo install -d -m 0755 /etc/systemd/system/confluent-server.service.d && sudo install -m 0644 -o root -g root /tmp/10-cpctl.conf /etc/systemd/system/confluent-server.service.d/10-cpctl.conf"
ssh kc03.poc.lab "rm -f /tmp/confluent-server.service /tmp/10-cpctl.conf && sudo systemctl daemon-reload"
```

驗證:unit 來自 `/etc/systemd/system`、drop-in 有載入、實際的 ExecStart 是 drop-in 那一行:

```
ssh kc03.poc.lab "systemctl show confluent-server -p FragmentPath -p DropInPaths -p User"
User=cp-kafka
FragmentPath=/etc/systemd/system/confluent-server.service
DropInPaths=/etc/systemd/system/confluent-server.service.d/10-cpctl.conf
```

對應 cpctl:`install::_units` 渲染 `templates/default/systemd/tar/confluent-server.service.tpl`(`CP_HOME=/opt/confluent/current`);drop-in 由 05_configure 渲染 `kafka-override.conf.tpl`,其中 `BIN_DIR`、`JAVA_HOME`、`KAFKA_ETC` 來自 `install::bin_dir`、`install::java_home`、`install::kafka_etc`。

## 7.5 JDK 信任內部 CA

目的:tar 版的 JDK 有自己的 `cacerts`,和 RPM 版的 JDK 是不同的檔案,要再匯入一次內部 CA。別名用 CA 憑證 SHA-256 指紋的前 16 碼,和 cpctl 相同,CA 輪替時才能辨識新舊。

```
ssh kc03.poc.lab "sudo /opt/java/current/bin/keytool -importcert -noprompt -cacerts -storepass changeit -alias cp-ca-316ed0e1062cc95c -file /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem"
ssh kc03.poc.lab "sudo /opt/java/current/bin/keytool -list -cacerts -storepass changeit -alias cp-ca-316ed0e1062cc95c | head -1"
cp-ca-316ed0e1062cc95c, Oct 16, 2026, trustedCertEntry,
```

對應 cpctl:`java_node::trust_ca`。

> 升級 JDK(解壓新版、切換 `/opt/java/current`)之後,新 JDK 的 cacerts 也要再匯入一次。

## 7.6 格式化、啟動、加入 quorum

和 4.3、4.4 相同,只是工具改用 `/opt/confluent/current/bin/`、`JAVA_HOME=/opt/java/current`,工具的 log 設定用 `/opt/confluent/current/etc/kafka/tools-log4j2.yaml`:

```
ssh kc03.poc.lab "sudo bash -c \"set -a; . /etc/confluent/kafka/service.env; set +a; sudo -u cp-kafka --preserve-env=CONFLUENT_SECURITY_MASTER_KEY env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/opt/confluent/current/etc/kafka/tools-log4j2.yaml /opt/confluent/current/bin/kafka-storage format --cluster-id jjRYywATQBGIf11rBTcNGg --config /etc/confluent/kafka/server.properties --no-initial-controllers\""
ssh kc03.poc.lab "sudo systemctl enable -q confluent-server && sudo systemctl start confluent-server"
```

驗證:服務是用 tar 的 JDK 啟動的,且以 observer 身分追上 metadata(Lag 0):

```
ssh kc03.poc.lab "systemctl is-active confluent-server; ps -o args= -u cp-kafka | grep -o '/opt/java/current/bin/java' | head -1"
active
/opt/java/current/bin/java
```

加入 quorum 的 `add-controller` 也是同一條指令,換成 tar 的工具路徑即可(完整說明見 4.5)。實測結果:

```
Added controller 3 with directory id Oh37yuEAl48M83WgLnaOHA and endpoints: CONTROLLER://kc03.poc.lab:9093
```

## 7.7 升級與回滾(tar.gz)

| 動作 | 做法 |
|---|---|
| 升級 | 下載並驗證新版 tar.gz → 解壓到 `/opt/confluent/confluent-<新版>` → 逐台:停服務 → `ln -sfn` 切換 `current` → 啟動 → 健康檢查通過才換下一台 |
| 回滾 | 舊版目錄還在,逐台把 `current` 切回舊版並重啟(metadata version 尚未 finalize 前才可回滾) |
| 移除 | 停用服務,刪除 unit、drop-in、`/opt/confluent/confluent-<版本>`;設定與資料目錄另外處理 |

對應 cpctl:`cpctl upgrade stage|rolling|rollback`(`tar_node::switch upgrade`)。

# 8. 版本升級(rpm)

本章以 Confluent Platform 8.2.4 → 8.3.2 為例,說明不停機的滾動升級。順序依 CP 8.3 官方升級指引:**broker 逐台 → controller 逐台(leader 最後)→ REST Proxy(先從 LB 摘除)**;全部完成並觀察一段時間後,才執行不可逆的 **finalize**。Control Center 2.6 與 CP 版本獨立,只要相容表支援目標版本就不必一起升。

整章在 2026-10-16/17 的全程實測環境(附錄 A.3)中照做過一次:持續送收訊息,**0 筆遺失、REST 0 次失敗**,中途也演練了一次回滾。

> 實測環境的 controller 是 kc01–kc03、操作機是 ops02;本手冊其他章節用 cpctl PoC 的 kc01、kc02、kc04 與 ops01。指令裡的主機清單請依實際環境替換。

## 8.0 共用變數與健康檢查函式(ops01,cpadmin)

```bash
$ cat >> ~/manual.env <<'EOF'
export FROM=8.2.4 TO=8.3.2 TO_RELEASE=4.3
BROKERS="kb01 kb02 kb03 kb04" CONTROLLERS="kc01 kc02 kc04" RESTS="rest01 rest02"
# broker 健康:已註冊且未 fence、沒有 under-replicated partition、MDS 有回應
broker_ok() { local id=$((100 + ${1#kb0})); kafka-broker-api-versions --bootstrap-server $B --command-config $CFG 2>/dev/null | grep -q "(id: $id rack: [a-z-]* isFenced: false)" && [ -z "$(kafka-topics --bootstrap-server $B --command-config $CFG --describe --under-replicated-partitions 2>/dev/null)" ] && curl -sf -o /dev/null --cacert $PKI/ca.pem https://$1.poc.lab:8090/v1/metadata/id; }
# controller 健康:是 voter 且 lag 0
ctl_ok() { local id=${1#kc0}; kafka-metadata-quorum --bootstrap-controller $CB --command-config $CFG describe --replication 2>/dev/null | awk -v id=$id '$1==id && ($NF=="Leader"||$NF=="Follower") && $4+0==0 {ok=1} END {exit !ok}'; }
# 最多等 300 秒;取樣一次不算數(寫入瞬間 lag 可能短暫不是 0)
wait_for() { local i; for i in $(seq 1 60); do "$@" && { echo "  healthy after ~$((i*5))s"; return 0; }; sleep 5; done; echo "  NOT HEALTHY after 300s - stop here"; return 1; }
EOF
$ . ~/manual.env
```

`$B`、`$CB`、`$CFG`、`$PKI`、`$CID`、`$MDS` 見 4.0 與 5.0。

## 8.1 引進新版本

升級要用的套件和第一次安裝走同一條路:外網下載 → 驗證閘門 → 落地區 → 內網匯入(第 2 章)。只需要在 2.2 多下載一組新版本:

```bash
# 外網下載機:上游 repo 加上新版本的 baseurl(例如 https://packages.confluent.io/rpm/8.3),然後
dnf -q download --resolve --arch x86_64 --arch noarch --destdir /tmp/stage \
  confluent-server-8.3.2 confluent-security-8.3.2 confluent-kafka-rest-8.3.2 confluent-cli-8.3.2
```

接著照 2.2 的方式分類、照 2.6–2.7 重新產生 SHA256SUMS 並跑驗證閘門,再照 2.10–2.14 在內網匯入。

**驗證**:重新匯入時,已發佈的檔案會被略過,只有新版本被發佈。實測結果是 `published 10 files`,confluent repo 從 11 個套件變成 21 個(新舊版本並存)。舊版本**一定要留在 repo**,回滾(8.6)要用。

>! 節點上的 dnf 會快取 repo metadata。新版本匯入後,節點端的安裝指令一定要加 `--refresh`,否則會出現 `Unable to find a match: confluent-server-8.3.2`(實測時就因此第一次安裝失敗)。

## 8.2 升級前檢查(不改任何東西)

任何一項不通過就**停在這裡**,處理完再重來。

```bash
$ . ~/manual.env
# 1) 目前版本
$ for h in $BROKERS $CONTROLLERS; do echo "$h $(ssh $h.poc.lab "rpm -q --qf '%{VERSION}' confluent-server")"; done
$ for h in $RESTS; do echo "$h $(ssh $h.poc.lab "rpm -q --qf '%{VERSION}' confluent-kafka-rest")"; done
# 2) 目標版本已在內部 repo(從任一節點看)
$ ssh kb01.poc.lab "sudo dnf -q --refresh --disablerepo='*' --enablerepo=cp-internal-confluent list --showduplicates confluent-server"
confluent-server.noarch    1:8.2.4-1    cp-internal-confluent
confluent-server.noarch    1:8.3.2-1    cp-internal-confluent
# 3) 8.3 已移除的靜態設定不可出現(每台都要是 0)
$ for h in $BROKERS $CONTROLLERS; do echo "$h $(ssh $h.poc.lab "sudo grep -cE '^(message.format.version|message.downconversion.enable|message.timestamp.difference.max.ms)' /etc/confluent/kafka/server.properties")"; done
# 4) 叢集健康(用 wait_for 重試,不只取樣一次)
$ for h in $BROKERS; do wait_for broker_ok $h || break; done; for h in $CONTROLLERS; do wait_for ctl_ok $h || break; done
# 5) 憑證剩餘天數(升級期間不要碰到到期)
$ for n in cp-server kafka-internal; do echo "$n $(( ($(date -d "$(openssl x509 -enddate -noout -in $PKI/$n.crt | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )) days"; done
# 6) 目前 finalize 的 metadata 版本(之後 finalize 會用到)
$ kafka-features --bootstrap-server $B --command-config $CFG describe | grep -E 'confluent.metadata.version|kraft.version'
Feature: confluent.metadata.version  SupportedMinVersion: CP-7.3-IV3  SupportedMaxVersion: CP-8.2-IV1A  FinalizedVersionLevel: CP-8.2-IV1A
```

7) 相容性(查官方相容表):Control Center 2.6.x 支援 CP 7.5–8.3;CP 8.3 支援 JDK 17、21、25;8.2 → 8.3 可直接升級。

**對應 cpctl**:`cpctl upgrade plan --to 8.3.2`(`upgrade::plan`)。

>! 實測時第一次的前置檢查有一台 controller 顯示不健康,但腳本只印出結果、沒有停下,升級就接著開始了。事後確認只是取樣當下 lag 短暫不是 0。前置檢查要**有任何一項失敗就停**,健康檢查要重試數次再下結論。

## 8.3 備份

```bash
$ . ~/manual.env; set -a; . $S/secrets.env; set +a
$ BK=$S/upgrade/backup-$(date +%Y%m%d-%H%M%S); install -d -m 0700 $BK
# 每台的 /etc/confluent 與 systemd drop-in
$ for h in $CONTROLLERS $BROKERS $RESTS c3-01; do ssh $h.poc.lab "sudo tar -czf - -C / etc/confluent etc/systemd/system 2>/dev/null" > $BK/$h-etc.tgz; done
# 叢集層級的狀態
$ kafka-topics   --bootstrap-server $B --command-config $CFG --describe > $BK/topics.txt
$ kafka-configs  --bootstrap-server $B --command-config $CFG --describe --entity-type users > $BK/scram-users.txt
$ kafka-features --bootstrap-server $B --command-config $CFG describe > $BK/features.txt
$ kafka-acls     --bootstrap-server $B --command-config $CFG --list > $BK/acls.txt
# RBAC 綁定(每個 principal 一份 JSON;svc-cpctl 帳密放 0600 netrc)
$ install -m 0600 /dev/null ~/.netrc-mds && printf 'machine kb01.poc.lab login svc-cpctl password %s\n' "$SVC_CPCTL_PASSWORD" > ~/.netrc-mds
$ for p in User:svc-c3 User:svc-rest User:confluent-audit User:opmenu-breakglass Group:kafka-admins Group:kafka-operators Group:kafka-devs User:app-orders User:app-payments User:app-legacy-billing; do
    curl -s --cacert $PKI/ca.pem --netrc-file ~/.netrc-mds -H 'Content-Type: application/json' -X POST \
      -d "{\"clusters\":{\"kafka-cluster\":\"$CID\"}}" "$MDS/security/1.0/lookup/principal/$p/resources" > "$BK/rbac-${p/:/_}.json"
  done; rm -f ~/.netrc-mds
$ cp $S/kraft.env $BK/; echo "$TO" > $BK/target; ln -sfn $BK $S/upgrade/last-backup
```

**驗證**:`ls -la $BK` 有 10 台主機的 `*-etc.tgz`(各 12–23 KB)、`topics.txt`、`scram-users.txt`、`features.txt`、10 份 `rbac-*.json`、`kraft.env`、`target`。`target` 是 finalize 前的檢查依據(8.8)。

**對應 cpctl**:`cpctl upgrade backup --to 8.3.2`。

## 8.4 持續負載(建議)

升級期間讓一個 producer 持續送帶序號的訊息(acks=all),另一路每秒經 LB 打一次 REST v3,結束後比對有沒有遺失。工具內容見附錄 D.6,放在 ops01 的 `/var/lib/cp-installer/manual/load.sh`:

```bash
$ bash load.sh start </dev/null >/var/lib/cp-installer/load/start.out 2>&1; cat /var/lib/cp-installer/load/start.out
load started (topic orders.load)
```

>! 啟動背景工作時,一定要把輸出導到檔案(如上)。實測時直接在一個有管線的指令裡啟動,背景的 producer 一直佔著管線,讓那條指令永遠不會結束。

## 8.5 broker 逐台升級

每台:**停服務 → 解除所有 confluent-* 的版本鎖 → 裝新版(相依套件一起升) → 重新鎖定 → `daemon-reload` → 啟動 → 健康才換下一台**。

```bash
$ . ~/manual.env
$ for h in $BROKERS; do
    echo "== $h -> $TO ($(date +%T))"
    ssh $h.poc.lab "TO=$TO bash -s" <<'EOS'
set -e
sudo systemctl stop confluent-server
sudo dnf versionlock delete $(rpm -qa --qf '%{NAME}\n' 'confluent-*') >/dev/null 2>&1
sudo dnf -y -q --refresh --disablerepo='*' --enablerepo='cp-internal-*' --setopt=install_weak_deps=False \
     install confluent-server-$TO confluent-security-$TO
for p in $(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 'confluent-*'); do sudo dnf -q versionlock add "$p"; done
sudo systemctl daemon-reload
sudo systemctl start confluent-server
rpm -q confluent-server confluent-common
EOS
    wait_for broker_ok $h || break
  done
```

實測輸出(每台):

```
== kb01 -> 8.3.2 (09:17:58)
confluent-server-8.3.2-1.noarch confluent-common-8.3.2-1.noarch
  healthy after ~10s
```

**注意事項**:
- `sudo systemctl daemon-reload` 是必要的:RPM 升級會換掉 `/usr/lib/systemd/system/confluent-server.service`,沒有 reload 時每次啟動都會警告「unit file changed on disk」。實測第一輪漏了這步,事後在每台補做,警告才消失。
- 設定檔在 `/etc/confluent`,RPM 升級不會動到;drop-in 也不受影響。8.2 → 8.3 沒有必改的設定。
- 一次只動一台;`wait_for` 回傳失敗就停下來處理,或回滾(8.6)。

**對應 cpctl**:`cpctl upgrade rolling --to 8.3.2 --role broker`(`upgrade::host`)。

## 8.6 回滾(finalize 之前才可以)

finalize 之前,metadata 版本還停在舊版(實測 `CP-8.2-IV1A`),所以任何一台都能退回舊版。做法和升級相同,只是裝回舊版;`dnf install` 遇到較舊版本時改用 `downgrade`:

```bash
$ ssh kb04.poc.lab "V=$FROM bash -s" <<'EOS'
set -e
sudo systemctl stop confluent-server
sudo dnf versionlock delete $(rpm -qa --qf '%{NAME}\n' 'confluent-*') >/dev/null 2>&1
D=(sudo dnf -y -q --refresh --disablerepo='*' --enablerepo='cp-internal-*' --setopt=install_weak_deps=False)
"${D[@]}" install confluent-server-$V confluent-security-$V 2>/dev/null || "${D[@]}" downgrade $(rpm -qa --qf '%{NAME}\n' 'confluent-*' | sed "s/\$/-$V/")
for p in $(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 'confluent-*'); do sudo dnf -q versionlock add "$p"; done
sudo systemctl daemon-reload && sudo systemctl start confluent-server
EOS
$ wait_for broker_ok kb04
```

實測:kb04 退回 8.2.4(健康 ~10 秒),再升回 8.3.2(健康 ~10 秒),期間負載沒有遺失。

全部回滾的順序與升級**相反**:REST → controller → broker。

>! finalize(8.8)之後就**不能**回滾了;要回到舊版只能從備份重建叢集。

**對應 cpctl**:`cpctl upgrade rollback --to 8.2.4`。

## 8.7 controller 逐台升級(follower 先、leader 最後)

```bash
$ L=$(kafka-metadata-quorum --bootstrap-controller $CB --command-config $CFG describe --status | awk '/LeaderId:/ {print $2}')
$ ORDER="$(for h in $CONTROLLERS; do [ "${h#kc0}" != "$L" ] && echo $h; done) kc0$L"; echo "leader $L; order: $ORDER"
$ for h in $ORDER; do
    ssh $h.poc.lab "TO=$TO bash -s" <<'EOS'
set -e
sudo systemctl stop confluent-server
sudo dnf versionlock delete $(rpm -qa --qf '%{NAME}\n' 'confluent-*') >/dev/null 2>&1
sudo dnf -y -q --refresh --disablerepo='*' --enablerepo='cp-internal-*' --setopt=install_weak_deps=False install confluent-server-$TO confluent-security-$TO
for p in $(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 'confluent-*'); do sudo dnf -q versionlock add "$p"; done
sudo systemctl daemon-reload && sudo systemctl start confluent-server
EOS
    wait_for ctl_ok $h || break
  done
$ kafka-metadata-quorum --bootstrap-controller $CB --command-config $CFG describe --status | grep -E 'LeaderId|MaxFollowerLag'
```

實測:leader 是 node 2,順序為 kc01 → kc03 → kc02,每台約 10 秒恢復;最後一台(原 leader)重啟時 leadership 自動移到 node 3,`MaxFollowerLag: 0`。

**對應 cpctl**:`upgrade::_controller_order`、`cpctl upgrade rolling --role controller`。

## 8.8 REST Proxy 逐台(先從 LB 摘除)

開源版 Nginx 沒有 runtime API,摘除的做法是在 upstream 把那台標成 `down`、`nginx -t` 通過後 `reload`;升級完成再拿掉 `down`。`lbconf <要摘除的主機>` 依 5.2.3 的內容產生 `cp.conf`(要摘除的那台行尾加 ` down`),派送到 lb01 並 reload;`lbconf ""` 表示全部放回:

```bash
$ lbconf() {
    { echo 'upstream cp_rest {'; echo '    hash $remote_addr consistent;'
      for r in $RESTS; do printf '    server %s.poc.lab:8082 max_fails=2 fail_timeout=10s%s;\n' $r "$([ "$r" = "$1" ] && echo ' down')"; done
      echo '}'; echo 'upstream cp_c3 {'; echo '    server c3-01.poc.lab:9021 max_fails=2 fail_timeout=10s;'; echo '}'
      echo 'server { listen 8082; proxy_pass cp_rest; proxy_connect_timeout 3s; proxy_timeout 10m; }'
      echo 'server { listen 9021; proxy_pass cp_c3;   proxy_connect_timeout 3s; proxy_timeout 1h;  }'; } > $S/manual/cp.conf.new
    scp -q $S/manual/cp.conf.new lb01.poc.lab:/tmp/cp.conf.new
    ssh lb01.poc.lab 'sudo install -o root -g root -m 0644 /tmp/cp.conf.new /etc/nginx/stream.d/cp.conf && rm -f /tmp/cp.conf.new && sudo nginx -t -q && sudo nginx -s reload'
  }
$ for h in $RESTS; do
    lbconf $h; sleep 5                                   # 摘除,等既有連線結束
    ssh $h.poc.lab "TO=$TO bash -s" <<'EOS'
set -e
sudo systemctl stop confluent-kafka-rest
sudo dnf versionlock delete $(rpm -qa --qf '%{NAME}\n' 'confluent-*') >/dev/null 2>&1
sudo dnf -y -q --refresh --disablerepo='*' --enablerepo='cp-internal-*' --setopt=install_weak_deps=False install confluent-kafka-rest-$TO confluent-security-$TO
for p in $(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 'confluent-*'); do sudo dnf -q versionlock add "$p"; done
sudo systemctl daemon-reload && sudo systemctl start confluent-kafka-rest
EOS
    rest_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --cacert $PKI/ca.pem --cert $PKI/app-legacy-billing.crt --key $PKI/app-legacy-billing.key https://$h.poc.lab:8082/v3/clusters)" = 200 ]; }
    wait_for rest_ok || break
    lbconf ""                                            # 放回
  done
```

實測:每台摘除後升級,約 15 秒恢復;經 LB 的 REST 呼叫 0 次失敗。

**對應 cpctl**:`lb::drain`、`lb::undrain`、`cpctl upgrade rolling --role rest`。

## 8.9 確認零遺失

```bash
$ bash load.sh stop && bash load.sh report
SCRAM producer : 3572 produced, 3572 consumed (written since 09:17:40), 0 missing
REST v3 via LB : 91 ok, 0 failed      ← 實測時的數字;91 次遠少於演練時間應有的次數,見附錄 A.3.2 註
```

判斷依據是 `0 missing` 與 `0 failed`,而且 `consumed` 必須等於 `produced`、REST 的次數要和演練時間相符(約每 1.1 秒一次;明顯偏少表示 REST 迴圈中途停了)。報告只算本次 `start` 之後寫入的訊息:每次 `start` 序號都從 1 開始,topic 又保留之前的訊息,若從頭全部算,舊訊息會把新的遺失蓋掉(實測時的舊版報告就有這個問題,附錄 A.3.2 註)。上面的數字是依 broker 上的資料重新核對的結果。

>! 負載要先 `stop` 才能 `report`:報告讀到 topic 30 秒沒有新訊息才結束,負載還在跑就永遠不會結束。

## 8.10 finalize(不可逆)

全部 broker、controller 都是新版,也已經觀察過一段時間(正式環境建議至少數天,期間仍可回滾)、確認備份目標就是這個版本後,才把 metadata 版本升上去:

```bash
# 前提
$ for h in $BROKERS $CONTROLLERS; do [ "$(ssh $h.poc.lab "rpm -q --qf '%{VERSION}' confluent-server")" = "$TO" ] || echo "$h NOT at $TO"; done
$ cat $S/upgrade/last-backup/target                      # 必須是 8.3.2
# 先看這個 release 會把各 feature 升到哪裡
$ kafka-features --bootstrap-server $B --command-config $CFG version-mapping --release-version $TO_RELEASE
confluent.metadata.version=137 (4.3)
kraft.version=1
transaction.version=2
...
# 執行
$ kafka-features --bootstrap-server $B --command-config $CFG upgrade --release-version $TO_RELEASE
confluent.metadata.version was upgraded to 137.
...
$ kafka-features --bootstrap-server $B --command-config $CFG describe | grep confluent.metadata.version
Feature: confluent.metadata.version  SupportedMinVersion: CP-7.3-IV3  SupportedMaxVersion: CP-8.3-IV0B  FinalizedVersionLevel: CP-8.3-IV0B
```

`release-version` 是 Kafka 的版本號:CP 8.3 → `4.3`、CP 8.2 → `4.2`。Confluent Server 使用自己的 `confluent.metadata.version`(實測 `CP-8.2-IV1A` → `CP-8.3-IV0B`);`metadata.version` 欄位顯示 `UNKNOWN` 是正常的。

**對應 cpctl**:`cpctl upgrade finalize --to 8.3.2`(會要求輸入 cluster id 確認)。

## 8.11 收尾

- 操作機與跳板機上的 Kafka 工具、Confluent CLI 也升到新版(同 8.5 的安裝步驟,不需要重啟任何服務)。
- 跑一次第 5.3 的驗收。
- 正式環境:舊版本的套件留在內部 repo,直到確定不再需要回滾。

# 9. 憑證輪替與 CA 輪替

憑證效期 1 年(`PKI_CERT_DAYS=365`)、內部 CA 10 年。本章說明兩種換法:

| 情境 | 做什麼 | 輪數 |
|---|---|---|
| 9.2 憑證輪替 | 同一張 CA 重簽 `kafka-internal`、`cp-server`(到期前,或懷疑私鑰外洩) | 1 輪滾動重啟 |
| 9.3 CA 輪替 | 換掉內部 CA 本身 | 3 輪滾動重啟(add → switch → retire) |
| 9.4 遷移到銀行 CA | 內部 CA 換成銀行 PKI(`PKI_MODE=external`,3.4.9) | 3 輪(同 9.3 的三階段) |
| 9.5 銀行 CA 下的輪替 | 憑證到期重簽、銀行換 root | 1 輪 / 3 輪 |

9.2、9.3 在 2026-10-17 的全程實測環境中,於持續負載下做過(附錄 A.3);9.4 在 cp-poc 用 cpctl 做過(附錄 A.4)。每一輪 16 個 TLS 端點都確認換成新憑證,REST 都是 0 次失敗;SCRAM 直連的負載都是 0 筆遺失。9.3.2 switch 在 A.3 的負載量測無效(附錄 A.3.2 註),2026-10-18 已照本章重做:1,383 筆 0 遺失、REST 250 次 0 失敗(附錄 A.6)。9.4 照本章手動做過一次(A.6),也以 cpctl 做過一次(A.4)。

**為什麼不停機**:所有連線兩端都信任同一份 CA bundle。憑證輪替時 CA 沒變,新舊憑證都能互通;CA 輪替則先讓所有人同時信任新舊兩張 CA(add),再換憑證(switch),最後才移除舊 CA(retire),任何時刻連線兩端都至少有一張共同信任的 CA。

## 9.1 共用函式(ops01,cpadmin)

每一輪都由下列動作組成。函式的完整內容見附錄 D.7,存成 `~/rotate-lib.sh`,用法是 `. ~/rotate-lib.sh` 後呼叫:

| 函式 | 做什麼 | 對應章節 |
|---|---|---|
| `issue <名稱> <EKU> [SAN]` | 先把舊檔歸檔到 `$PKI/archive/<時間>-<名稱>/`,再用目前的 `ca.crt` 簽新憑證、產生 p12 | 3.4.3 |
| `truststores` | 依 `ca.pem`(可能含 2 張 CA)重建 `truststore.p12` 與選單用的 `opmenu-truststore.p12` | 3.4.2、6.3 |
| `push_all_ssl` | 依角色把 `ca.pem`、`truststore.p12`、keystore 派送到 10 台的 `/etc/confluent/ssl` | 3.4.7 |
| `trust_all` | 12 台主機的 OS trust anchor 換成 `ca.pem`;JDK cacerts 只保留 bundle 裡的 CA(多的刪掉) | 3.4.8 |
| `push_ad` | ad01 的 LDAPS 憑證與 CA,重啟 samba,等 LDAPS 恢復 | 4.1.1 |
| `push_jump` | 跳板機的 opmenu truststore、顯示用的憑證、break-glass 憑證 | 6.3、6.4 |
| `push_repo` | repo over HTTPS：repo 主機的憑證換成 cp-server、每台節點的 `cp-repo-ca.pem` 換成 `ca.pem`，並確認每台都還能下載 metadata | 3.3.0、3.3.1.1 |
| `restart_all` | 逐台重啟並等健康:controller(leader 最後)→ broker → REST(先從 LB 摘除)→ C3 | 4.2.8、8.8 |
| `served` | 列出 16 個 TLS 端點**實際出示**的憑證序號與簽發 CA | — |

`served` 檢查的端點:controller 9093、broker 9092/8090(MDS)/9095、REST 8082、C3 9021、Prometheus 9090、AD 636、JMX exporter 7071。

>! keystore / truststore 是服務啟動時載入記憶體的,**檔案換了不代表服務在用新的**。每一輪都要滾動重啟,最後一定用 `served` 確認端點出示的是新憑證。

## 9.2 憑證輪替(同一張 CA)

```bash
$ bash load.sh start </dev/null >/var/lib/cp-installer/load/start.out 2>&1      # 建議:持續負載(附錄 D.6)
$ . ~/rotate-lib.sh
$ served                                                   # 換之前,記下目前的序號
$ issue kafka-internal serverAuth,clientAuth $SANS_INTERNAL
$ issue cp-server serverAuth,clientAuth $SANS_SERVER
$ openssl verify -CAfile $PKI/ca.pem $PKI/kafka-internal.crt $PKI/cp-server.crt
$ push_all_ssl
$ push_ad
$ push_jump
$ push_repo                                                # repo over HTTPS (3.3.0): new cp-server on the repo server
$ restart_all
$ served                                                   # 每個端點的序號都要變成新的
$ bash load.sh stop && bash load.sh report
```

實測結果(節錄):

```
issued kafka-internal serial=...75EE issuer=PoC Internal CA 20261016
issued cp-server serial=...75EF issuer=PoC Internal CA 20261016
kc01:9093      ...75EE PoC Internal CA 20261016          ← 原本 ...75EA
kb01:8090      ...75EF PoC Internal CA 20261016          ← 原本 ...75EB
...(16 個端點全部換新)
SCRAM producer : 1210 produced, ..., 0 missing
REST v3 via LB : 214 ok, 0 failed
```

**注意事項**:
- `$SANS_INTERNAL`、`$SANS_SERVER` 必須和第一次簽發時相同(3.4.4、3.4.5);主機有增減時就是更新 SAN 的時機。
- legacy app 的 client 憑證(`app-legacy-billing`)要另外簽,新的 `.p12` 交給應用程式團隊;舊憑證在到期前仍可使用。
- 操作機上的管理設定(`$CFG`)直接引用 `$PKI` 的檔案,自動用到新憑證。

**對應 cpctl**:`cpctl certs rotate`(`--cert` 可指定其他憑證)。

## 9.3 CA 輪替(三個階段)

每個階段結束都要確認結果,才能進入下一階段。建議每個階段之間留觀察時間;**應用程式在 add 之後、switch 之前,要換上新的 truststore(含兩張 CA)**,否則 switch 之後它們不認得新憑證。

### 9.3.1 第 1 階段 add:建立新 CA,所有人同時信任新舊兩張

```bash
$ . ~/rotate-lib.sh
$ cd $PKI && umask 077
$ openssl genrsa -out ca-next.key 3072
$ openssl req -x509 -new -key ca-next.key -sha256 -days 3650 -out ca-next.crt \
    -subj "/CN=PoC Internal CA $(date +%Y%m%d%H%M)/OU=Confluent/O=PoC Bank/C=TW" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
$ cat ca.crt ca-next.crt > ca.pem && chmod 0644 ca.pem     # bundle:舊 + 新
$ truststores && push_all_ssl && trust_all && push_ad && push_jump && push_repo
$ restart_all
```

**驗證**:

```bash
$ for h in kc01 kb01 rest01 c3-01; do ssh $h.poc.lab "sudo /usr/lib/jvm/temurin-21-jdk/bin/keytool -list -keystore /etc/confluent/ssl/truststore.p12 -storepass <store-password> | grep -c trustedCertEntry"; done
2   (每台)
# trust_all 的輸出:每台 "OS anchors=2 JDK=2"
$ served          # 仍是舊 CA 簽的憑證(這個階段不換憑證)
```

實測:12 台主機 OS 與 JDK 都是 2 張 CA,負載 0 遺失、REST 0 失敗。

### 9.3.2 第 2 階段 switch:新 CA 開始簽章,所有憑證重簽

```bash
$ cd $PKI && umask 077
$ arch=archive/ca-$(date +%Y%m%d-%H%M%S); install -d -m 0700 $arch && cp -p ca.crt ca.key ca.srl $arch/
$ mv ca.crt ca-old.crt && rm -f ca.key ca.srl              # 舊 CA 不再簽章(私鑰只留在 archive)
$ mv ca-next.crt ca.crt && mv ca-next.key ca.key
$ cat ca.crt ca-old.crt > ca.pem && chmod 0644 ca.pem      # bundle:新 + 舊
$ issue kafka-internal serverAuth,clientAuth $SANS_INTERNAL
$ issue cp-server serverAuth,clientAuth $SANS_SERVER
$ issue app-legacy-billing clientAuth
$ issue opmenu-breakglass clientAuth
$ truststores && push_all_ssl && trust_all && push_ad && push_jump && push_repo
$ restart_all
$ served          # 簽發者應全部是新 CA
```

實測:4 張憑證都由新 CA(`PoC Internal CA 202610170944`)簽發,16 個端點全部出示新 CA 的憑證;REST 0 失敗。SCRAM 負載這一段當時沒有量到(附錄 A.3.2 註);2026-10-18 重做:1,383 筆 0 遺失、REST 250 次 0 失敗(附錄 A.6)。

`app-legacy-billing.p12` 這時要交給應用程式團隊;舊憑證(舊 CA 簽的)在 retire 之前仍然有效,給對方切換的時間。

### 9.3.3 第 3 階段 retire:移除舊 CA

**前提**(任何一項不成立就不要做):

```bash
$ for n in kafka-internal cp-server app-legacy-billing opmenu-breakglass; do openssl verify -CAfile $PKI/ca.crt $PKI/$n.crt; done   # 全部 OK
$ served | grep -vc "<新 CA 的名稱>"                       # 必須是 0
# 所有使用 client 憑證的應用程式都已換上新憑證
```

```bash
$ cd $PKI && arch=archive/ca-old-$(date +%Y%m%d-%H%M%S); install -d -m 0700 $arch && mv ca-old.crt $arch/
$ cat ca.crt > ca.pem && chmod 0644 ca.pem                 # bundle:只剩新 CA
$ truststores && push_all_ssl && trust_all && push_ad && push_jump && push_repo
$ restart_all
```

**驗證**:舊 CA 不再被信任,舊 CA 簽的憑證會被拒:

```
kb01 OS-anchors JDK-aliases: 1 1
REST with the OLD-CA app certificate: 000 exit=56     ← TLS 層拒絕
REST with the NEW app certificate:    200
```

實測:12 台都只剩 1 張 CA;負載 0 遺失、REST 0 失敗。

**對應 cpctl**:`cpctl certs rotate-ca --phase add|switch|retire`。

**注意事項**:
- `trust_all` 會把 JDK cacerts 裡**不在 bundle 中**的 `cp-ca-*` 別名刪掉,retire 時舊 CA 才會真正從 JDK 消失。OS trust anchor 目錄不可留舊檔的備份(3.4.8)。
- 舊 CA 的私鑰只留在操作機的 `archive/`,正式環境應離線保存或銷毀。
- 跳板機的 break-glass 憑證在 switch 時一起重簽,`push_jump` 會重新匯出並派送。

## 9.4 從內部 CA 遷移到銀行 CA(不停機)

和 9.3 一樣分三個階段,差別是新 CA 由銀行持有:我們只拿到銀行 root,新憑證要經過「產生申請 → 銀行簽 → 檢查後匯入」(3.4.9)。每個階段都在 ops 主機以 cpadmin 執行,用到 9.1 的共用函式;其中銀行專用的兩個:

| 函式 | 做什麼 | 對應章節 |
|---|---|---|
| `request <名稱> <EKU> [SAN]` | 新私鑰放 `pending/`(不離開 ops 主機),CSR 放 `requests/` | 3.4.9.2 |
| `import_signed <名稱> <EKU> [SAN]` | 檢查 `incoming/<名稱>.crt`(私鑰配對、CN、不是 CA、SAN、EKU、效期、鏈到 `trust/` 的 root),全部通過才換上 `.key/.crt/.p12`;任何一項不過就印 `REJECTED` 並且什麼都不換 | 3.4.9.3 |

| 階段 | `ca.pem`(信任 bundle)的內容 | 憑證由誰簽 | 滾動重啟 |
|---|---|---|---|
| 開始 | 內部 CA | 內部 CA | — |
| 1 add | 內部 CA + 銀行 root | 內部 CA | 是 |
| 2 switch | 內部 CA + 銀行 root | **銀行** | 是 |
| 3 retire | 銀行 root | 銀行 | 是 |

### 9.4.1 第 1 階段 add:所有人同時信任內部 CA 與銀行 root

```bash
$ . ~/rotate-lib.sh && cd $PKI
# 銀行交付的 root:先核對,再放進 trust/(只放 root,不放中繼)
$ openssl x509 -in ~/bank-root-g1.pem -noout -subject -fingerprint -sha256 -ext basicConstraints
subject=CN=PoC Bank Root CA G1, O=PoC Bank, C=TW
sha256 Fingerprint=B4:F5:04:CA:...            ← 與銀行從另一個管道公布的指紋逐字比對
X509v3 Basic Constraints: critical  CA:TRUE
$ install -d -m 0750 trust
$ openssl x509 -in ~/bank-root-g1.pem -out trust/bank-root-g1.pem && chmod 0644 trust/bank-root-g1.pem
$ cat ca.crt trust/*.pem > ca.pem && chmod 0644 ca.pem      # bundle:內部 CA + 銀行 root
$ grep -c 'BEGIN CERTIFICATE' ca.pem                         # 2
$ truststores && push_all_ssl && trust_all && push_ad && push_jump && push_repo
$ restart_all
```

**驗證**:同 9.3.1 —— 各服務的 truststore 與每台的 OS / JDK 都是 2 張 CA;`served` 仍然出示內部 CA 簽的憑證(這個階段不換憑證)。

實測(手動,cp-man,附錄 A.6):12 台都是 2 張 CA,repo 11 台正常;負載 1,415 筆 0 遺失、REST 255 次 0 失敗。

>! **應用程式要在這個階段換上含銀行 root 的 truststore 並重啟**(直連 Kafka 的 SCRAM app、REST 的 legacy app 都一樣)。Java 只在啟動時載入 truststore:沒有重啟的程式,在第 2 階段 broker 改出示銀行憑證後就連不上(`PKIX path building failed`)。實測時就發生過(附錄 A.4.2)。

### 9.4.2 第 2 階段 switch:改由銀行簽發

```bash
$ . ~/rotate-lib.sh
# 1) 產生 4 份申請(私鑰留在 pending/;SAN 與 EKU 同 3.4.4–3.4.6)
$ request kafka-internal serverAuth,clientAuth $SANS_INTERNAL
$ request cp-server serverAuth,clientAuth $SANS_SERVER
$ request app-legacy-billing clientAuth
$ request opmenu-breakglass clientAuth
$ ls $PKI/requests                       # 把這些 .csr 連同申請單交給銀行;私鑰不交出去
# 2) 銀行簽回後,每張放成 $PKI/incoming/<名稱>.crt(PoC:Windows 端 bash windows/bank-ca.sh exchange)
# 3) 檢查並匯入;任何一張 REJECTED 就停,請銀行重簽
$ import_signed kafka-internal serverAuth,clientAuth $SANS_INTERNAL
$ import_signed cp-server serverAuth,clientAuth $SANS_SERVER
$ import_signed app-legacy-billing clientAuth
$ import_signed opmenu-breakglass clientAuth
# 4) 派送(信任 bundle 不變,只有 keystore 與憑證換新)、滾動重啟
$ push_all_ssl && push_ad && push_jump && push_repo
$ restart_all
$ served                                 # 簽發者都應是 PoC Bank Issuing CA G1-01
```

**拒絕的例子**(故意讓銀行只簽 serverAuth):

```
REJECTED kafka-internal: extended key usage lacks clientAuth (TLS Web Server Authentication) - nothing installed
```

這時什麼都沒換:服務繼續用原本的憑證,`pending/` 的私鑰也還在。請銀行用同一份 CSR 重簽,覆蓋 `incoming/` 後再跑一次 `import_signed`。

**驗證**:每個 TLS 端點都要送出 2 張憑證(leaf + 中繼),否則只信任 root 的對方會驗證失敗:

```bash
$ for ep in kc01:9093 kb01:9092 kb01:8090 rest01:8082 c3-01:9021 c3-01:9090 ad01:636; do
    printf '%-12s %s\n' $ep "$(openssl s_client -connect ${ep%:*}.poc.lab:${ep#*:} -showcerts </dev/null 2>/dev/null | grep -c 'BEGIN CERTIFICATE')"; done
kc01:9093    2
...
c3-01:9090   2      ← Prometheus、LDAPS 直接讀 .crt,所以 .crt 必須是 leaf + 中繼(3.4.9.3)
ad01:636     2
```

`app-legacy-billing.p12` 這時交給應用程式團隊;舊憑證(內部 CA 簽的)在第 3 階段之前仍可使用。

實測(手動,cp-man,附錄 A.6):4 張憑證都由 `PoC Bank Issuing CA G2-01` 簽發、`.crt` 都是 2 張;16 個端點加上 repo 的 8443 都出示新憑證並送出 2 張。

**對應 cpctl**:`PKI_MODE=external` 後 `cpctl certs rotate --cert all` 跑兩次(第 1 次產生申請,銀行簽回後第 2 次檢查、匯入、派送、滾動重啟)。

### 9.4.3 第 3 階段 retire:移除內部 CA

**前提**(任何一項不成立就不要做):

```bash
$ . ~/rotate-lib.sh && cd $PKI
$ for n in kafka-internal cp-server app-legacy-billing opmenu-breakglass; do
    openssl verify -partial_chain -CAfile <(cat trust/*.pem) -untrusted $n.crt $n.crt; done     # 4 行 OK
$ served | grep -c 'Internal CA'          # 0:所有端點都已出示銀行簽的憑證
$ ls pending incoming                      # 都是空的:沒有還在等銀行的申請
# 所有使用 client 憑證的應用程式都已換上銀行簽的憑證
```

```bash
$ arch=archive/ca-internal-$(date +%Y%m%d-%H%M%S); install -d -m 0700 $arch
$ mv ca.crt ca.key ca.srl $arch/ 2>/dev/null; ls $arch      # 內部 CA 私鑰從此只在 archive/
$ cat trust/*.pem > ca.pem && chmod 0644 ca.pem               # bundle:只剩銀行 root
$ truststores && push_all_ssl && trust_all && push_ad && push_jump && push_repo
$ restart_all
```

**驗證**:每台 OS / JDK 只剩 1 張 CA;內部 CA 簽的舊 app 憑證被 TLS 拒絕,銀行簽的可以:

```bash
$ old=$(ls -d $PKI/archive/*-app-legacy-billing | tail -1)
$ curl -s -o /dev/null -w '%{http_code} exit=' --cacert $PKI/ca.pem --cert $old/app-legacy-billing.crt --key $old/app-legacy-billing.key https://rest.poc.lab:8082/v3/clusters; echo $?
000 exit=56
$ curl -s -o /dev/null -w '%{http_code}\n' --cacert $PKI/ca.pem --cert $PKI/app-legacy-billing.crt --key $PKI/app-legacy-billing.key https://rest.poc.lab:8082/v3/clusters
200
```

實測(手動,cp-man,附錄 A.6):12 台只剩銀行 root;舊 app 憑證 exit 56、銀行簽的 200;switch 加 retire 期間負載 3,015 筆 0 遺失、REST 542 次 0 失敗。

>! 內部 CA 的私鑰這時只在 `archive/`。觀察期過後,依銀行規定離線保存或銷毀。之後 `issue`(3.4.3)不能再用 —— 所有憑證都改走 `request` + `import_signed`。

**對應 cpctl**:`cpctl certs trust remove internal`(先做上述前提檢查,通過才移除並滾動重啟)。

## 9.5 銀行 CA 下的輪替

銀行模式下我們沒有 CA 私鑰,所以 9.2 的 `issue` 與 9.3 的 CA 輪替都不能用,改成下表的做法。每一列都在持續負載下做(9.2 的 `load.sh`)。

| 情境 | 手動做法 | 對應 cpctl |
|---|---|---|
| 憑證到期(每年)、懷疑私鑰外洩 | `request` → 銀行簽 → `import_signed` → `push_all_ssl && push_ad && push_jump && push_repo` → `restart_all` → `served`(同 9.4.2,只做要換的那幾張) | `cpctl certs rotate` 跑兩次 |
| SAN 改變(增減主機) | 同上,`$SANS_INTERNAL` / `$SANS_SERVER` 用新的主機清單 | 同上(cpctl 比對 SAN 不符會自動產生申請) |
| 銀行中繼 CA 換新、root 不變 | 只需重簽 leaf(同第 1 列);`trust/` 不變 | `cpctl certs rotate --cert all` |
| 銀行換 root | 三階段:新 root 放進 `trust/`、`cat trust/*.pem > ca.pem`(同 9.4.1,這時有新舊兩個 root)→ 4 張全部 `request` / `import_signed`(同 9.4.2)→ 舊 root 移到 `archive/`、`cat trust/*.pem > ca.pem`(同 9.4.3) | `certs trust add <新 root>` → `certs rotate --cert all` → `certs trust remove <舊 root>` |

- 到期提醒:`openssl x509 -enddate -noout -in $PKI/<名稱>.crt`;到期前 30 天(`PKI_RENEW_BEFORE_DAYS`)就要送申請,銀行的簽發時間要算進去(對應 `cpctl certs status`)。
- 銀行換 root 時,應用程式同樣要在第 1 階段之後換上含新 root 的 truststore 並重啟(9.4.1 的警告)。
- PoC 模擬銀行換 root:Windows 端 `bash windows/bank-ca.sh new-generation G2`、`deliver-root G2`,之後的 `exchange` 都由 G2 簽發。

# 10. 日常維運

本章在 ops 主機以 cpadmin 執行，環境變數同 5.1：`$B`（broker INTERNAL 9092 清單）、`$CFG`（`kafka-internal` 憑證的 admin 設定）、`$CB`（controller 9093 清單）、`$P=/var/lib/cp-installer/pki`。

## 10.1 健康檢查與常見故障

每天（或告警時）照下表依序看；任何一項不對，先看「常見故障」再動手。

| 項目 | 手動指令 | 正常 |
|---|---|---|
| 服務 | `ssh <host> systemctl is-active confluent-server`（REST：`confluent-kafka-rest`；c3-01：`prometheus alertmanager confluent-control-center`） | `active` |
| 磁碟 | `ssh <host> sudo df -P /var/lib/kafka/data /var/log/kafka`（資料目錄是 cp-kafka 的 0750，不加 sudo 會 Permission denied） | 使用率 < 75%（> 85% 要立即處理） |
| quorum | `kafka-metadata-quorum --bootstrap-controller "$CB" --command-config "$CFG" describe --replication` | 有一個 Leader；voter 的 Lag 接近 0 |
| 離線 partition | `kafka-topics --bootstrap-server "$B" --command-config "$CFG" --describe --unavailable-partitions` | 沒有輸出 |
| 低於 min ISR | `kafka-topics ... --describe --under-min-isr-partitions` | 沒有輸出（有的話 `acks=all` 的 producer 會失敗） |
| URP | `kafka-topics ... --describe --under-replicated-partitions` | 沒有輸出 |
| Self-Balancing | `kafka-rebalance-cluster --bootstrap-server "$B" --command-config "$CFG" --status` | `Balancer status: ENABLED` |
| MDS / AD | `curl -s -o /dev/null -w '%{http_code}\n' --cacert $P/ca.pem -K ~/svc-cpctl.netrc-curl https://kb01.poc.lab:8090/security/1.0/authenticate` | `200`（MDS 正常、AD bind 與 LDAPS 正常） |
| REST / C3 | `curl -s -o /dev/null -w '%{http_code}\n' --cacert $P/ca.pem --cert $P/app-legacy-billing.crt --key $P/app-legacy-billing.key https://rest.poc.lab:8082/v3/clusters`；`curl -s -o /dev/null -w '%{http_code}\n' --cacert $P/ca.pem https://c3.poc.lab:9021/` | `200` |
| 憑證效期 | `for n in kafka-internal cp-server app-legacy-billing opmenu-breakglass; do openssl x509 -in $P/$n.crt -noout -enddate; done` | 都在 30 天以後（銀行簽發要提前送件） |
| 端點出示的憑證 | 9.1 的 `served` | 序號與 `$P` 下的檔案相同 |
| license | 5.4 的 license 檢查 | 未過期；剩餘天數充足 |

`~/svc-cpctl.netrc-curl`（0600）內容一行 `user = "svc-cpctl:<password>"`，讓密碼不出現在指令列。

**常見故障**（服務起不來時先看 `sudo journalctl -u <unit> -n 200 --no-pager`）：

| 記錄裡的關鍵字 | 原因 | 處理 |
|---|---|---|
| `No space left on device` | 資料或 log 磁碟滿 | 先確認是哪個 topic 長大（`kafka-log-dirs --describe`），調整保留或擴充磁碟；不要手動刪 partition 目錄 |
| `Address already in use` | 埠被其他程序佔用（或上一個程序還沒結束） | `sudo ss -ltnp \| grep <port>` 找出程序 |
| `keystore password was incorrect`、`Keystore was tampered` | `.p12` 與設定裡的密碼不一致 | 換 keystore 後要同步密碼；Secret Protection 的設定要重新加密（3.0.5） |
| `PKIX path building failed`、`certificate_unknown` | 對方的憑證鏈不到本機 truststore | CA 輪替漏了步驟，或用戶端沒換 truststore（9.3、9.4.1） |
| `Invalid cluster.id`、`meta.properties` | 資料目錄是別的叢集格式化的 | `sudo -u cp-kafka kafka-storage info -c /etc/confluent/kafka/server.properties` 確認；不要重新格式化有資料的節點 |
| `securepass`、`master key` | Secret Protection 的 master key 沒有傳給服務 | 檢查 `/etc/confluent/kafka/service.env`（0600）與 systemd drop-in 的 `EnvironmentFile` |
| `LoginException ... retrieving token`（C3、REST） | 啟動時 MDS 還沒好 | 等 broker 的 MDS 起來後重啟該服務 |
| `Connection refused` 到 636、LDAP 逾時 | AD / LDAPS 連不上 | 檢查 AD、防火牆、AD 憑證的 CA 是否在 truststore |
| `OutOfMemoryError` | heap 不足 | 調整 systemd drop-in 的 `KAFKA_HEAP_OPTS`（`HEAP_<profile>_<role>`） |
| SBC 一直 `STARTING`，`listener name ListenerName(PLAINTEXT)` | controller 沒設 `inter.broker.listener.name` | 4.2.3.1 / 4.2.3.3 注意事項 |

**對應 cpctl**：`cpctl health`（唯讀；正常 rc=0、有警告 rc=2、有嚴重問題 rc=1；服務不是 active 時，會從 journal 比對上表給出可能原因）。

**實測**：cp-man 手動逐項執行（附錄 A.6）；cp-poc 停掉 rest01 時 `cpctl health` 回報嚴重、rc=1（附錄 A.5）。

## 10.2 broker 縮減（移除一台 broker）

- **原理**：由 Self-Balancing 把該 broker 上的 partition replica 全部搬到其他 broker，搬完自動關閉該 broker。不需要手寫 reassignment 計畫。
- **前提**：
  - 移除後至少還有 3 台 broker（RF=3）。
  - 沒有 URP。
  - SBC 是 `ENABLED`（10.1）。
  - 磁碟空間足夠接收搬過來的資料。
- **手動指令**（以 kb04 = broker id 104 為例）：
  ```bash
  # 1) 目前這台有多少 replica
  kafka-topics --bootstrap-server "$B" --command-config "$CFG" --describe | grep -c 'Replicas:.*\b104\b'
  # 2) 交給 Self-Balancing：搬走、然後關閉 broker 104
  kafka-remove-brokers --bootstrap-server "$B" --command-config "$CFG" --delete --broker-id 104
  # 3) 追蹤進度，直到搬移與關閉都是完成狀態
  kafka-remove-brokers --bootstrap-server "$B" --command-config "$CFG" --describe
  # 4) broker 104 已經沒有任何 replica、也不在 broker 清單
  kafka-topics --bootstrap-server "$B" --command-config "$CFG" --describe | grep -c 'Replicas:.*\b104\b'   # 0
  kafka-broker-api-versions --bootstrap-server "$B" --command-config "$CFG" | grep -c '(id: 104 '     # 0
  # 5) 不讓它開機後再起來
  ssh kb04.poc.lab 'sudo systemctl stop confluent-server; sudo systemctl disable confluent-server'
  ```
- **之後**：
  - 把 kb04 從 broker 清單拿掉（各元件的 bootstrap 清單：REST Proxy、C3、OP menu、應用程式設定）。
  - 憑證的 SAN 可以保留，下次輪替時再整理。
  - 這台的資料目錄在重新加入前要清空（10.3）。
- **驗證**：`kafka-topics ... --describe --under-replicated-partitions` 沒有輸出；持續負載 0 遺失（9.2 的 `load.sh`）。
- **對應 cpctl**：`cpctl broker remove --host kb04 --yes`（含上述前提檢查與等待；完成後提示修改 `HOSTS_broker` 並重跑 `cpctl install`）。
- **實測**：持續負載下 0 遺失、REST 0 失敗 —— 手動（cp-man）9,974 筆 / 1,830 次（搬移約 13 分鐘），cpctl（cp-poc）6,795 筆 / 1,235 次（約 2 分鐘）；附錄 A.5、A.6。

## 10.3 broker 擴充（加入一台 broker）

- **前提**：
  - 新主機做完 3.1–3.3：OS 基線、套件、信任 bundle。
  - 新主機在 `cp-server`、`kafka-internal` 的 SAN 裡。**新的主機名稱要先重簽憑證**：內部 CA 用 9.2，銀行 CA 用 9.5。
  - 決定好 node id 與 rack。
- **手動指令**（以重新加入 kb04 為例；全新的主機只做第 2 步以後）：
  ```bash
  # 1) 曾經是叢集成員的主機：清空舊資料（舊的 replica 不能回來）
  ssh kb04.poc.lab 'sudo systemctl stop confluent-server; sudo find /var/lib/kafka/data -mindepth 1 -delete'
  # 2) 設定檔同 4.2（node.id=104、broker.rack=rack-b），以 --no-initial-controllers 格式化（4.3），啟動（4.4）
  #    格式化同 4.3.3：Secret Protection 的 master key 從 root 才能讀的 service.env 經環境變數傳給 kafka-storage
  ssh kb04.poc.lab "sudo bash -c \"set -a; . /etc/confluent/kafka/service.env; set +a; \
    sudo -u cp-kafka --preserve-env=CONFLUENT_SECURITY_MASTER_KEY env JAVA_HOME=/usr/lib/jvm/temurin-21-jdk KAFKA_HEAP_OPTS=-Xmx256m \
    KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
    /usr/bin/kafka-storage format --cluster-id $CLUSTER_ID --config /etc/confluent/kafka/server.properties --no-initial-controllers\""
  ssh kb04.poc.lab 'sudo systemctl enable --now confluent-server'
  # 3) 註冊成功，然後 Self-Balancing 自動把 replica 搬上來（空的 broker 加入就會觸發）
  kafka-broker-api-versions --bootstrap-server "$B" --command-config "$CFG" | grep '(id: 104 '
  kafka-rebalance-cluster --bootstrap-server "$B" --command-config "$CFG" --describe
  kafka-topics --bootstrap-server "$B" --command-config "$CFG" --describe | grep -c 'Replicas:.*\b104\b'   # 逐漸 > 0
  ```
- **驗證**：broker 104 有 replica、沒有 URP、負載 0 遺失。
- **對應 cpctl**：把主機加進 `HOSTS_broker`（含 `HOST_<h>_NODE_ID`、`_RACK`）後執行 `cpctl broker add --host kb04 [--wipe]`；它跑一次 `cpctl install` 收斂這台主機，並等 SBC 把資料搬上去。
- **實測**：重新加入後 12 秒內註冊；SBC 把資料搬回，cp-poc 約 4 分鐘，cp-man 較慢（20 分鐘內 10–20 個 replica，仍在進行）。

## 10.4 OS 修補（滾動，必要時重開機）

- **原理**：一次只動一台，順序和閘門跟 rolling restart 相同。
  - 順序：broker → controller（follower 先、leader 最後）→ REST（先從 LB 摘除）→ C3。
  - Confluent 與 JDK 被 `dnf versionlock` 鎖住（3.3.1.3），所以 `dnf update` 只會更新 OS 套件。
- **每台的手動指令**（kb01 為例）：
  ```bash
  # 0) 叢集健康（10.1：沒有 URP、quorum 正常）
  ssh kb01.poc.lab 'sudo dnf versionlock list | grep -c confluent'      # 鎖住的套件數 > 0
  ssh kb01.poc.lab 'sudo dnf -q check-update | wc -l'                   # 可更新的數量
  ssh kb01.poc.lab 'sudo systemctl stop confluent-server'                # 正常關閉（leader 交出去）
  ssh kb01.poc.lab 'sudo dnf -y update'
  ssh kb01.poc.lab 'rpm -q --last kernel-core | head -1; uname -r'       # 新 kernel ≠ 執行中的 kernel → 需要重開
  ssh kb01.poc.lab 'sudo systemctl reboot'                               # 需要時
  # 等 ssh 回來、confluent-server 自動啟動（enabled）
  # 1) 閘門：broker 重新註冊、沒有 URP，才換下一台（同 8.5）
  ```
  REST：先在 LB 把那台標成 `down` 並 reload（8.7），修補完再拿掉。controller：每台之後確認 lag 為 0；leader 放最後。
- **不在範圍**：ops 主機自己（cpctl / 手冊指令都在這台執行）、LB、AD、堡壘機，各自另排維護窗口。
- **驗證**：每台修補後 `rpm -q confluent-server` 版本不變；全程持續負載 0 遺失。
- **對應 cpctl**：`cpctl os patch [--role broker|controller|rest|c3] [--host H] [--reboot] --yes`；不加 `--yes` 只列出每台可更新的套件，不做任何變更。容器（PoC）不能重開機，`--reboot` 只會重啟服務並提示。
- **實測**：cpctl 全叢集（cp-poc）1,929 筆 0 遺失、REST 335 次 0 失敗；手動三台（cp-man）299 筆 0 遺失、REST 54 次 0 失敗；PoC 的 repo 沒有 OS 更新，容器不能重開機（附錄 A.5、A.6）。

# 附錄 A. 手動驗證紀錄

這份手冊做過兩次實測,都完全不呼叫 cpctl:

| 實測 | 範圍 | 環境 |
|---|---|---|
| A.1 全程從零(2026-10-16) | 第 2–6 章全部:從外網下載、建 repo,到 15 台主機的整套叢集、驗收、OP menu | 獨立的一套模擬主機(`docker/manual/compose.yml`,專案 `cp-man`),操作機 ops02 從裸機開始 |
| A.2 單節點(2026-10-16) | 一台 controller 從裸機到加入既有叢集:rpm 一次、tar.gz 一次 | 備用節點 kc03,接到 cpctl 建好的叢集 |
| A.3 升級與輪替(2026-10-16/17) | 第 8、9 章:8.2.4 → 8.3.2 升級(含回滾、finalize)、憑證輪替、CA 三階段輪替,全程持續負載 | 同 A.1 的環境 |
| A.4 銀行 CA(2026-10-17) | 3.4.9、9.4、9.5:內部 CA 遷移到模擬銀行 CA、銀行換 root(G1 → G2),持續負載 | cp-poc,**用 cpctl** 執行(驗證 cpctl 的外部 CA 模式) |
| A.5 維運強化(2026-10-18) | 5.1.7 配額、3.3.0 repo HTTPS、3.0.3 受限 sudo、第 10 章日常維運 | cp-poc,用 cpctl |
| A.6 手動實測(2026-10-18) | 上一列各章 + 9.3 CA switch 重做 + 9.4 銀行 CA 遷移,照手冊手動 | cp-man,不用 cpctl |

## A.1 全程從零實測

### A.1.1 做法

- 另建一套與 PoC 相同拓樸的模擬主機:3 台 controller(kc01–kc03)、4 台 broker、2 台 REST、C3、LB、AD、跳板機,以及**裸機狀態的操作機 ops02**(沒有 httpd、沒有 repo、沒有任何工具)。原本 cpctl 的叢集停機但不刪資料。
- 外網下載機是一台可上網、與節點同 base image 的 Rocky 9,從零下載到新的落地區 `packages-manual/`。
- 照手冊章節順序,在 ops02 以 cpadmin 逐條執行。多行指令(heredoc)照手冊原樣貼上執行。
- 所有指令、輸出、結束碼都記錄在 `docs/manual-src/transcripts/`:`01-download.log`(下載機)、`02-ops02.log`(操作機,約 2,800 行);每一段的指令檔是 `cmd-*.txt`。紀錄中沒有任何密碼值:密碼一律從 ops02 的 0600 密碼檔(3.0.5)讀成變數,紀錄只看得到變數名稱。

### A.1.2 結果

| 章節 | 內容 | 結果 |
|---|---|---|
| 2.2–2.7 | 下載 RPM(confluent 11、adoptium 1、os-deps 43)、tar.gz、JMX jar、打包 OP menu、SHA256SUMS(81 檔)、驗證閘門 | 通過;81 檔 sha256 相符、73 個 RPM 簽章全部 OK |
| 2.9 | 裸機 ops02 建 repo 主機(httpd :8080、repoadmin) | 通過;GET 200、PUT 405 |
| 2.10–2.14 | 落地區再驗證、預檢衝突、發佈 63 檔、建 repodata、稽核副本 | 通過;三個 yum repo 都在服務 |
| 3.0–3.1 | cpadmin 金鑰、密碼檔、預檢 14 台 | 通過;時鐘誤差 ≤1 秒、DNS 互相解析 |
| 3.2 | OS 基線 12 台 | 通過(第一次失敗,見 A.1.3 #1、#2);ops02 成為 NTP server,各台 `^*` 選定 |
| 3.3 | 依角色安裝精確版本 + versionlock | 通過;c3-01 只有 C3、沒有任何 CP 套件 |
| 3.4 | 新 CA、4 張憑證、MDS token 金鑰、派送、OS 與 JDK 信任 | 通過;`openssl verify` 全部 OK,cp-server SAN 29 個 |
| 4.1 | AD:LDAPS 換內部 CA 憑證、4 OU、3 群組、4 服務帳號、3 使用者 | 通過;`Verify return code: 0 (ok)`,svc-mds-bind 經 LDAPS 查詢正常 |
| 4.2 | 照 4.2.3 逐段寫 7 份 server.properties、加密、JMX、drop-in | 通過;**照手冊寫出的設定 key 與 cpctl 產生的完全一致**(broker 141、controller 97,加密後各多 2 行 config.providers);明文密碼 0 筆 |
| 4.3 | 動態 quorum 格式化(voter 1、2、3)、broker 格式化 | 通過;重跑會被 `already formatted` 擋下 |
| 4.4 | 啟動 controller、broker,健康檢查 | 通過;kraft.version=1、4 台 broker 未 fence、under-replicated 為空、MDS 回應 |
| 5.1 | SCRAM、MDS 登入、19 筆 RBAC 綁定、範例 topic、稽核 topic | 通過(發生 1 次密碼外洩,見 A.1.3 #9,已處理並換密碼) |
| 5.2 | REST ×2、C3 + Prometheus + Alertmanager、Nginx | 通過;legacy 憑證 200、其他憑證 401、無憑證 TLS 拒絕;C3 UI 約 50 秒後 200 |
| 5.3 | 驗收 #1–#36、#48 | 37 項全部符合預期;Prometheus 有 121 種 Kafka 指標 |
| 6 | OP menu:固定帳號、套件、設定、break-glass、sudoers、sshd、kafkaops ×10、RBAC | 通過 |
| 5.3.9 | OP menu 驗收 #37–#47 | 11 項全部符合預期;#43 fail-closed 時 kb01 確實沒有被重啟 |

### A.1.3 實測發現、已修進手冊的問題

| # | 現象 | 原因 | 修正 |
|---|---|---|---|
| 1 | 11 台主機 `Unknown repo: cp-internal-os-deps` | 操作機 ops02 自己排第一台;它那一輪的 `rm -f /tmp/cp-internal.repo` 刪掉了還要派送給別台的原始檔 | 3.0.4:操作機也是安裝對象時,暫存檔不要放 `/tmp` 同名路徑 |
| 2 | broker 的 `sysctl -p` 印出 `setting key "net.core.rmem_max": No such file or directory` | 容器內這兩個參數唯讀;`sysctl -w`、`-p` 失敗時結束碼仍是 0 | 3.2.1:設定後讀回比對,不一致就不寫入 |
| 3 | 下載機 `perl: No such file or directory`(rc=127) | 精簡 Linux 沒有 perl | 2.5:CRLF 檢查改用 `grep -rl $'\r'` |
| 4 | 手冊沒有「準備密碼檔」的步驟 | 原本只有預檢「密碼是否存在」 | 新增 3.0.5 |
| 5 | AD 帳號建立要互動輸入密碼 | — | 4.1.2:`samba-tool` 非終端機時從 stdin 讀密碼,可經管線送入 |
| 6 | master key 的 passphrase 寫在指令列 | — | 4.2.1:改用 `--passphrase=-` 從 stdin 讀 |
| 7 | 手冊省略 telemetry regex、rules-kafka.yml、opmenu-bootstrap、opmenu-clean-logs 的內容(要求「從模板複製」) | 手動安裝時操作機上沒有 cpctl 專案 | 新增附錄 D,收錄完整內容 |
| 8 | controller 格式化訊息與手冊不同 | 帶 `--initial-controllers` 時是「dynamic metadata voter directory」 | 4.3.2 改正 |
| 9 | **`kafka-configs --add-config-file` 失敗,錯誤訊息印出 3 組 SCRAM 密碼原文** | 該選項不支援 SCRAM 憑證(手冊原本建議用它避免 `ps` 外洩) | 5.1.1 撤除建議並加警告;實測當下遮蔽紀錄、3 組密碼全部換新 |
| 10 | 換 confluent-audit 密碼後 broker log 出現 `Failed authentication` | 稽核寫入者的密碼也在各節點設定裡,節點重啟前仍用舊密碼 | 5.1.1:換密碼要重新加密設定並滾動重啟;實測 7 台重啟後不再增加 |
| 11 | REST 與 C3 設定照手冊寫不完整(各少十幾項,多處「...」) | 手冊只列「重點」 | 5.2.1、5.2.2 改為完整版(REST 36 項、C3 47 項)與完整的 `prometheus-generated.yml` |
| 12 | 手冊中有 `key=value   # 註解`、`Environment="..."   # 註解` 的寫法 | properties 與 systemd 都沒有行尾註解,`#` 之後會變成值的一部分 | 全部改成獨立一行的註解 |
| 13 | Alertmanager 驗證 `curl` exit 58 | cpadmin 讀不到 0640 的 `cp-server.key` | 5.2.2 改用 `sudo curl` |
| 14 | lb01 `ss: command not found` | LB 設備(Debian 版 nginx image)沒有 `ss` | 5.2.3 改用 `nginx -T` 與經 LB 的 curl |
| 15 | `opmenu.conf` 少一項 | 手冊漏列 `OPMENU_OUT_DIR=/var/log/opmenu` | 6.3 補上 |
| 16 | sshd reload 後立即 ssh 失敗(rc=255),幾秒後正常 | reload 當下的暫時性連線失敗 | 6.6 註明稍等再測 |
| 17 | `sudo stat /etc/confluent/kafka/*` 什麼都沒印 | `*` 由 cpadmin 展開,讀不到 0750 目錄 | 3.0.4:列目錄也要由 root 展開(`sudo find`) |
| 18 | 離線檢查一度顯示「連得到外網」 | `echo "$(hostname) rc=$?"` 的 `$?` 被 `$(hostname)` 覆蓋 | 3.0.4:先 `rc=$?` 再印;重測四台都 rc=6(連不到) |
| 19 | 6.4 驗證寫「需先完成 4.9 綁定」、3.2 開頭寫「3.2.11 時間同步」、引用已刪除的「不確定事項」 | 筆記整理時的編號錯誤 | 改正 |

## A.2 單節點實測(kc03:rpm 與 tar.gz)

### A.2.1 做法

把備用 controller kc03 重建成裸機(只有 OS、sshd 與 cpadmin),從 ops01 以 cpadmin 逐條執行手冊指令,把 kc03 從零裝成 controller、加入正在運作的叢集、再移出;接著移除 RPM 改用 tar.gz 再做一次。叢集層級的資產(內部 CA、cluster id、Secret Protection master key)沿用 cpctl 先前建立的。紀錄在 `ops01:/var/lib/cp-installer/manual/kc03-transcript.log`。

### A.2.2 結果

| 段落 | 內容 | 手冊章節 | 結果 |
|---|---|---|---|
| A | 內部 repo 設定、匯入原廠 GPG 金鑰 | 3.3 | 通過;`dnf repolist` 看到 3 個內部 repo |
| B | OS 基線:chrony、firewalld、sysctl、limits、journald、時區、THP unit | 3.2 | 通過(發現 A.2.3 #1) |
| C | RPM 安裝精確版本、versionlock | 3.3 | 通過;3 個套件鎖定 |
| D | OS 與 JDK 信任內部 CA、`/etc/confluent/ssl` | 3.4 | 通過;`Verify return code: 0 (ok)` |
| E | 設定檔、Secret Protection 加密(14 個 key) | 4.2 | 通過;明文密碼 0 筆 |
| F | 格式化(observer)、啟動、`add-controller` | 4.3–4.5 | 通過;kc03 成為 voter,Lag 0 |
| G | `remove-controller` | 4.5 | 通過;quorum 回到 1、2、4 |
| H0 | 移除 RPM(改走 tar.gz) | 7 | 通過(發現 A.2.3 #2) |
| H | tar.gz:取檔驗 sha256、解壓、symlink、unit、drop-in、JDK 信任、格式化、啟動、`add-controller` | 7 | 通過;kc03 以 tar 版成為 voter,JMX exporter 回 401(TLS 通、需帳密) |
| I | 移出 quorum、還原成備用狀態 | A.2.4 | 通過;quorum 1、2、4,`cpctl verify` failed=0 |

### A.2.3 發現的問題

| # | 現象 | 原因 | 修正(已寫入手冊) |
|---|---|---|---|
| 1 | `tee: /etc/sysctl.d/90-confluent.conf: No such file or directory` | 精簡版 OS 沒有 `/etc/sysctl.d` 目錄 | 先 `sudo install -d -m 0755 /etc/sysctl.d` |
| 2 | 改用 tar.gz 時 `kafka-storage format` 回報 `already formatted` | `sudo rm -rf /var/lib/kafka/data/*` 的 `*` 由 cpadmin 展開,實際沒有刪到任何檔案 | 改用 `sudo find /var/lib/kafka/data -mindepth 1 -delete` |
| 3 | `curl --cacert /etc/confluent/ssl/ca.pem` 回 rc=77 | `ca.pem` 是 root:confluent 0640,cpadmin 讀不到 | 用 OS trust store(3.4 已匯入內部 CA) |
| 4 | ops01 重開機後 `/tmp` 下準備好的檔案不見了 | `/tmp` 是 tmpfs | 要保留的檔案放在 `/var/lib/cp-installer/` 底下 |

### A.2.4 還原成備用狀態

演練結束後,把 kc03 移出 quorum,刪除 Confluent 相關的檔案;OS 基線、repo 設定與 CA 信任保留,之後 `cpctl controller replace` 仍可用 kc03 當新節點。

```
$ kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc04.poc.lab:9093 --command-config /var/lib/cp-installer/client/internal.properties remove-controller --controller-id 3 --controller-directory-id Oh37yuEAl48M83WgLnaOHA
Removed  KRaft controller 3 with directory id Oh37yuEAl48M83WgLnaOHA
ssh kc03.poc.lab "sudo systemctl disable -q --now confluent-server && sudo rm -f /etc/systemd/system/confluent-server.service && sudo rm -rf /etc/systemd/system/confluent-server.service.d && sudo systemctl daemon-reload"
ssh kc03.poc.lab "sudo rm -rf /opt/confluent /opt/java /opt/jmx-exporter /var/cache/cp-installer /etc/confluent && sudo find /var/lib/kafka /var/log/kafka -mindepth 1 -delete"
```

>! `remove-controller` 一定要帶 `--controller-directory-id`,而且要先移出 quorum 再停服務。順序反過來時,quorum 會暫時少一個 voter,剩下的 voter 再掛一台就無法過半。

## A.3 升級與輪替實測(2026-10-16/17)

### A.3.1 做法

在 A.1 的全程實測環境(cp-man)上:

1. 照第 2 章引進 CP 8.2.4(下載、驗證閘門、內網匯入)。重新匯入時只發佈新增的 10 個 RPM,已發佈的 81 個檔案全部略過。
2. 演練準備(不是手冊步驟):把叢集重置成 8.2.4,重建 RBAC 綁定與範例 topic。
3. 照第 8 章升級到 8.3.2:中途回滾一台,最後 finalize。
4. 照第 9 章依序做憑證輪替、CA 輪替的 add、switch、retire。

每一段都在持續負載下進行:SCRAM producer 帶序號、acks=all;REST v3 每秒一次經 LB。紀錄在 `02-ops02.log`(接在 A.1 之後)與 `03-download-8.2.4.log`,指令檔是 `cmd-8.*.txt`、`cmd-9.*.txt`。

### A.3.2 結果

| 演練 | 重點 | 負載結果 |
|---|---|---|
| 8 升級 8.2.4 → 8.3.2 | broker 4 台、controller 3 台(leader 最後)、REST 2 台(先從 LB 摘除);kb04 回滾到 8.2.4 再升回;finalize `CP-8.2-IV1A` → `CP-8.3-IV0B` | 0 遺失(兩個 producer:3,572 筆 + 4,161 筆,見下方註);REST 只記到 91 次(見下方註) |
| 9.2 憑證輪替 | 16 個端點序號全部換新 | 1,210 筆 0 遺失 ✓;REST 214 次 0 失敗 |
| 9.3.1 CA add | 12 台 OS 與 JDK 都信任 2 張 CA,各服務 truststore 2 張 | 1,484 筆 0 遺失 ✓;REST 263 次 0 失敗 |
| 9.3.2 CA switch | 4 張憑證改由新 CA 簽發,16 個端點都出示新 CA 的憑證 | **SCRAM 負載無效**(producer 一筆都沒有寫入,見下方註);REST 268 次 0 失敗 |
| 9.3.3 CA retire | 12 台都只剩新 CA;舊 CA 簽的 app 憑證被 TLS 拒絕(exit 56),新憑證 200 | 1,476 筆 0 遺失 ✓;REST 263 次 0 失敗 |

**註(2026-10-17 重新核對)**:當時 load.sh 的報告有缺陷(A.4.3 #4):每次 `start` 序號從 1 開始,報告卻從頭讀整個 topic,舊訊息會蓋掉新的遺失(上表各段的 `consumed` 都是同一個數字 7,238)。事後在 broker 上以 `kafka-dump-log` 讀出每筆訊息的 producer ID,逐次核對:

| 演練 | producer | 結果 |
|---|---|---|
| 升級 | 本次啟動的 producer | 1–3,572 連續,0 遺失 |
| 升級 | 8.2.3 第一次啟動(卡住的那次,見 A.3.3 #5)其實一直在背景執行 | 升級期間 3,078–7,238 連續,0 遺失;它另有 15 個缺號,全部在主機休眠 / 喚醒的時間點(10-16 17:00、10-17 05:38、08:07,每次 5 筆),與升級無關 |
| 9.2、9.3.1、9.3.3 | 各一個 | 1,210、1,484、1,476 筆,序號都連續,**確認 0 遺失** |
| 9.3.2 CA switch | **沒有** | 這段時間 topic 裡沒有任何訊息:producer 一筆都沒寫入。log 已被下一段覆蓋,無法確定原因;最可能是 producer 啟動時,操作機上的 `truststore.p12` 正在原地重建(先 `rm` 再匯入),JVM 讀到缺檔或只有部分 CA 的 truststore。truststore 的重建已改成建在旁邊再改名(3.4.2、D.7、cpctl 同步修正) |

所以 9.3.2 這一段只證明了 REST(268 次 0 失敗),SCRAM 直連的不中斷沒有被證明。以同樣三階段做的銀行 root 輪替(A.4,switch + retire 4,530 筆 0 遺失)可作為佐證,但那是 cpctl 而不是本章的手動程序。 **2026-10-18 已重做(附錄 A.6):switch 1,383 筆 0 遺失、REST 250 次 0 失敗;同時也重做 add、retire,都是 0 遺失。**

**REST 計數**:各段 REST 約每 1.1 秒呼叫一次,次數應與演練時間相符。9.2、9.3.1–9.3.3 都相符(4–5 分鐘、214–268 次);升級約 12 分鐘卻只有 91 次,表示 REST 迴圈中途就結束了 —— 舊版 load.sh 在第一次失敗的呼叫時會直接結束(A.4.3 #3),所以升級期間「REST 0 失敗」沒有被證明,很可能至少有一次失敗。 升級沒有重跑;它的 REST 步驟與輪替時用的摘除程序相同,2026-10-18 手動輪替的 5 個階段 REST 都是 0 失敗且次數與時間相符(附錄 A.6)。

### A.3.3 發現並已修進手冊的問題

| # | 現象 | 原因 | 修正 |
|---|---|---|---|
| 1 | 節點安裝新版本時 `Unable to find a match: confluent-server-8.2.4` | 節點的 dnf metadata 還是匯入前的快取 | 8.1:新版本匯入後,節點端安裝一律加 `--refresh` |
| 2 | 每次重啟都警告 `unit file ... changed on disk` | RPM 換版會換掉 unit 檔,但沒有 `daemon-reload` | 8.5–8.8:裝完新版、啟動前先 `systemctl daemon-reload` |
| 3 | 重置時資料沒有清掉,8.2.4 讀到 8.3.2 的資料而起不來 | `[ -d /var/lib/kafka/data ]` 由 cpadmin 判斷,進不了 0750 的目錄,結果被當成不存在而跳過 | 附錄 C:用 sudo 做事之前的檢查也要 `sudo test -d` |
| 4 | 前置檢查顯示一台 controller 不健康,但升級照樣開始 | 檢查只取樣一次(寫入瞬間 lag 短暫不是 0),而且腳本沒有在失敗時停下 | 8.0、8.2:健康檢查一律重試;前置檢查任一項失敗就停 |
| 5 | 啟動持續負載的那條指令永遠不結束 | 背景 producer 佔住了指令的輸出管線 | 8.4:背景工作的輸出導到檔案 |
| 6 | 重置後 C3 顯示 active 卻不開 9021(`LoginException ... retrieving token`) | C3 啟動時 MDS 還不能發 token,之後不會自己重試 | 重啟 C3 即可(5.2.2 注意事項已有) |
| 7 | **`kafka-configs` 執行失敗時,錯誤訊息把整串參數(含 `--add-config` 的密碼)印出** | 叢集還沒就緒時建 SCRAM 帳號 | 5.1.1:建 SCRAM 前先確認叢集已就緒;輸出經過遮蔽再記錄。實測當下已遮蔽紀錄、兩組密碼換新 |

## A.4 銀行 CA 實測(2026-10-17,cp-poc,cpctl)

### A.4.1 做法

1. Windows 端以 `windows/bank-ca.sh` 建立模擬銀行 PKI:`PoC Bank Root CA G1` → `PoC Bank Issuing CA G1-01`(CA 私鑰只在 Windows 端,ops01 拿不到)。
2. 照 9.4 三個階段,把 cp-poc 從內部 CA 遷移到銀行 CA;中間故意讓銀行只簽 serverAuth 一次,確認會被拒。
3. 照 9.5 模擬銀行換 root:建立 G2(`Root CA G2` → `Issuing CA G2-01`),再走一次三階段(trust add G2 → 憑證改由 G2 簽 → trust remove G1)。

每段都在持續負載下(附錄 D.6 的 load.sh);另以 `bursts.sh`(依時間把 topic 切成一次次的負載,檢查每次的序號是否連續)獨立比對。

### A.4.2 結果

| 演練 | 重點 | 負載結果 |
|---|---|---|
| 9.4 遷移(add → switch → retire) | add 後抽查 6 台(ops01、kc01、kb01、rest01、c3-01、jump01),OS 與 JDK 都是 2 張 CA;switch 後 16 個端點都出示銀行簽的憑證、都送出 2 張(Prometheus 9090、LDAPS 636 原本只送 1 張);retire 後同 6 台只剩 1 張,內部 CA 簽的 app 憑證與 cp-server 被 REST、Prometheus 拒絕(exit 56),銀行簽的 200 | REST 前 291 次 0 失敗;SCRAM producer 見下方說明 |
| 拒絕測試 | 銀行只簽 serverAuth → `kafka-internal REJECTED: extended key usage lacks clientAuth`,rc=4,什麼都沒換 | — |
| 9.5 換 root:add G2 | trust bundle 與 truststore 為 G1 + G2,滾動重啟 failed=0 | 2,171 筆 0 遺失;REST 387 次 0 失敗 |
| 9.5 換 root:switch + retire G1 | 16 個端點都改出示 G2-01 簽的憑證(鏈 2 張);G1 簽的 app 憑證被拒(exit 56) | 4,530 筆 0 遺失;REST 817 次 0 失敗 |
| 收尾 | `cpctl verify` failed=0;`cpctl install` 連跑兩次,第二次 changed=0 | — |

**遷移那一段的 producer**:負載在 add **之前**就啟動,它的 JVM 一直用啟動時載入、只含內部 CA 的 truststore。switch 後 broker 重啟、改出示銀行憑證,它就連不上(`PKIX path building failed`),序號 6154–9352 沒有送出(3,199 筆;叢集沒有遺失任何已確認寫入的訊息,是用戶端送不進來)。這正是 9.4.1 警告的情況:**應用程式要在 add 之後、switch 之前換上新的 truststore(並重啟)**。換 root 那一輪照這個順序做(add 之後重啟負載),全程 0 遺失。

### A.4.3 發現並已修正的問題

| # | 現象 | 原因 | 修正 |
|---|---|---|---|
| 1 | 銀行憑證被拒(ERROR)之後,`cpctl certs rotate` 還是繼續派送、重啟,最後 rc=0 | `cpctl` 以 `certs::main && rc=0 \|\| rc=$?` 呼叫;bash 在 `&&`/`\|\|` 裡會關掉整個函式的 errexit,失敗的步驟不會中止 | `certs` 改在開啟 errexit 的子 shell 執行;實測拒絕時停在 03,rc=4 |
| 2 | 設定 / 憑證變更造成的 REST 重啟沒有先從 LB 摘除 | 只有 `upgrade rolling` 會摘除;handler 直接重啟(開源 Nginx 只有被動檢查,會有請求失敗) | handler 重啟 REST 前先 `lb::drain`,健康後 `lb::undrain` |
| 3 | 負載工具的 REST 計數停在 291 | 第一次失敗的呼叫沒有 JSON,`grep` 找不到 → `pipefail` + `set -e` 讓迴圈結束 | load.sh 的 REST 迴圈改為記錄失敗、繼續執行 |
| 4 | **報告的「0 遺失」不可靠** | 每次 `start` 序號從 1 開始,topic 保留之前的訊息;報告從頭讀整個 topic,舊的訊息會蓋掉新的遺失(`consumed` 在多次演練都是同一個數字) | 報告只計算本次 `start` 之後寫入的訊息(記錄時間戳);A.3 的數字另行重新核對(A.3.2 註) |
| 5 | Prometheus 9090、LDAPS 636 只送 leaf | 這兩個服務直接讀 `.crt`;內部 CA 模式下對方本來就信任簽發者 | 銀行 CA 模式下 `.crt` = leaf + 中繼(3.4.9.3) |
| 6 | 同一環境第二次 `cpctl certs rotate` 不會重簽 | 「本次已重簽」的標記檔留在 `$STATE_DIR/run`,從未清除 | 標記檔加上 run id |
| 7 | 報告用的 consumer 被拒(`GroupAuthorizationException`) | app-orders 的 RBAC 只允許 `orders-*` 的 consumer group | 核對用的 consumer 一律用 `orders-load-report-*` |

## A.5 維運強化實測（2026-10-18，cp-poc，cpctl）

client 配額、repo HTTPS、受限 sudo、日常維運指令，都在 cp-poc 以 cpctl 實測。手動程序（5.1.7、3.3.0、3.0.3、第 10 章）另在 cp-man 照手冊執行，見 A.6。

| 項目 | 做法 | 結果 |
|---|---|---|
| client 配額（5.1.7） | step 08 套用 3 個 app 的配額；app-orders 以 10 KB 訊息持續壓測 | 一開始突發 14.8 MB/s，之後穩定 **4.99 MB/s**（= 5 MiB/s 上限），`produce-throttle-time-avg` 26 ms；`cpctl verify` 新增 3 項配額檢查通過 |
| repo HTTPS（3.3.0） | 離線引進 mod_ssl（11 個新 RPM，經驗證閘門）→ `cpctl install` | 8443 以 cp-server（G2-01 簽）提供三個 repo；HTTP 8080 回 403；11 台節點的 repo 檔都 pin `cp-repo-ca.pem`；之後完整安裝 changed=0 |
| 受限 sudo（3.0.3） | `cpctl agent install --restrict`，先學習模式再強制 | 15 台 `sudo -l` 只剩 `cpnode ""`、`sudo id` 被拒；學習模式收集到 11 類路徑補進允許清單；強制模式下 `install --force` ok=1071、changed=0、failed=0、無拒絕；`cpctl verify` 68 項通過；node 程式碼一改，cpctl 就以版本不符停下，管理員安裝新 agent 後恢復 |
| Self-Balancing | 檢查 `kafka-rebalance-cluster --status` | **發現 SBC 從未啟動**（controller 缺 `inter.broker.listener.name`）；修正後 `STARTING → RUNNING`，`cpctl verify` 新增檢查 |
| broker 縮減 / 擴充（10.2、10.3） | 持續負載下 `cpctl broker remove --host kb04 --yes`，再 `cpctl broker add --host kb04 --wipe` | SBC 約 2 分鐘搬走 kb04 的 120 個 replica 並關閉它；加回後約 4 分鐘把資料搬回；**6,795 筆 0 遺失、REST 1,235 次 0 失敗** |
| OS 修補（10.4） | 持續負載下 `cpctl os patch --reboot --yes`（全叢集） | 順序 kb01–kb04 → kc02、kc04 → kc01（leader）→ rest01、rest02（各先摘除）→ c3-01；**1,929 筆 0 遺失、REST 335 次 0 失敗**（PoC repo 沒有 OS 更新；容器不能重開機，只重啟服務） |
| 健康檢查（10.1） | 停掉 rest01 的 REST Proxy | `cpctl health` 回報 service failed、REST 無回應、端點沒有出示憑證，rc=1；恢復後 rc=2（只剩試用 license 警告） |

**發現並已修正的問題**：

| # | 現象 | 原因 | 修正 |
|---|---|---|---|
| 1 | Self-Balancing 一直 `STARTING`（`kafka-remove-brokers` 回 `BalancerOfflineException`） | KRaft 下 SBC 在 controller 上，以 `inter.broker.listener.name`（預設 PLAINTEXT）找 broker 位址 | controller 設 `inter.broker.listener.name=INTERNAL` 與 `INTERNAL:SSL`（4.2.3.1、4.2.3.3） |
| 2 | 第一次 HTTPS 設定失敗後，重跑仍沒有提供 HTTPS | 檔案已在上一次寫入，比對「沒變」就不重啟 httpd | 除了檔案有變，實際沒有在服務時也重啟（以實際狀態為準） |
| 3 | httpd 設定測試失敗 | 寫成 `httpd -t -q`（`-q` 是 nginx 的選項） | 改為 `httpd -t` |
| 4 | broker 已移除，等待卻逾時 | `kafka-remove-brokers --describe` 的格式是 `Broker 104 removal status - SUCCESS.` 加上子任務 `COMPLETED` | 依該 broker 的整段判斷（含單元測試） |
| 5 | `cpctl health` 有嚴重問題時 rc 仍是 2 | 後面的警告把 rc 從 1 蓋成 2 | 嚴重優先 |
| 6 | 受限模式下 node 函式自己產生的暫存檔被擋 | 允許清單只接受呼叫者的 `/tmp/cpctl.*` | 另接受 root 擁有的 `/tmp/cpnode.*`（呼叫者無法產生 root 擁有的檔案） |

## A.6 手動實測（2026-10-18，cp-man，不用 cpctl）

照本手冊的指令在 cp-man 逐條執行（`transcripts/05-ops02-2026-10-18.log`，指令檔 `cmd-10*.txt`）。範圍：
- 今天新增或修改的章節：4.2.3.1 / 4.2.3.3 SBC 補正、5.1.7、3.3.0、3.3.1.1、3.0.3、9.4、第 10 章。
- 重做 A.3 中沒有證明的 9.3 內部 CA switch。
- 負載工具都是修正後的版本（只計算本次寫入的訊息、REST 失敗會被計數）。

| 演練 | 重點 | 負載結果 |
|---|---|---|
| SBC 補正（4.2.3.3） | cp-man 也是 `STARTING`；加設定（注意 `key = value` 格式）並逐台重啟 controller 後 `ENABLED` | — |
| client 配額（5.1.7） | 3 個 app 設定完成；壓測從 15.0 MB/s 降到 **4.99 MB/s**，throttle 平均 25 ms | — |
| repo HTTPS（3.3.0、3.3.1.1） | 照 2.10–2.14 引進 mod_ssl（102 檔 sha 相符、簽章 0 錯誤、發佈 11 個）；8443 提供服務；11 台節點 `makecache` 全部成功；8080 被防火牆關閉；換成別的 CA 檔就失敗（sslcacert 生效） | — |
| 9.3 內部 CA 輪替：add | 12 台 OS / JDK 都是 2 張 CA；repo 11 台正常 | 1,525 筆 0 遺失；REST 271 次 0 失敗 |
| 9.3 內部 CA 輪替：**switch** | 4 張憑證改由新 CA 簽發；repo 憑證一起換新 | **1,383 筆 0 遺失；REST 250 次 0 失敗**（A.3 中沒證明的那一段） |
| 9.3 內部 CA 輪替：retire | 每台只剩 1 張 CA；舊 CA 簽的 app 憑證被拒（exit 56） | 1,501 筆 0 遺失；REST 270 次 0 失敗 |
| 9.4 遷移到銀行 CA：add | 12 台都信任內部 CA + 銀行 root G2 | 1,415 筆 0 遺失；REST 255 次 0 失敗 |
| 9.4 拒絕的例子 | 銀行只簽 serverAuth → `REJECTED ... lacks clientAuth`，什麼都沒換、pending 私鑰保留 | — |
| 9.4 switch + retire | 4 張銀行憑證（`.crt` 皆 2 張）；16 個端點與 repo 8443 都出示 G2-01 簽的憑證且送 2 張；retire 後只剩銀行 root；內部 CA 簽的舊 app 憑證被拒（exit 56）、銀行簽的 200 | **3,015 筆 0 遺失；REST 542 次 0 失敗** |
| broker 縮減 / 擴充（10.2、10.3） | `kafka-remove-brokers` 約 13 分鐘搬完 131 個 replica 並關閉 kb04；重新格式化加入，12 秒註冊；SBC 開始把資料搬回（20 分鐘內 10–20 個，仍在進行） | **9,974 筆 0 遺失；REST 1,830 次 0 失敗** |
| OS 修補（10.4） | broker kb02、follower kc01、rest01（先摘除）各一台；versionlock 鎖住 9 個套件，版本不變 | 299 筆 0 遺失；REST 54 次 0 失敗 |
| 健康檢查（10.1） | 表中各項逐一執行；停掉 rest01 時 journal 可看到停止原因 | — |
| 受限 sudo（3.0.3） | kb03：依手冊用 `cat` 組出的 agent，版本與 `cpctl agent build` 相同；`sudo -l` 只剩 agent；`sudo id`、刪 `/etc/hosts`、寫入給 cpadmin 的 sudoers、`bash -c` 都被拒並記錄；之後恢復完整 sudo | — |

**REST 在升級期間的不中斷**（A.3.2 註中沒證明的項目）：升級沒有重跑。但升級的 REST 步驟（8.8：先在 LB 標成 `down`、處理、再放回）和 9.1 `restart_all` 的 REST 部分是同一個程序。今天手動的 5 個輪替階段各用了一次，REST 都是 0 失敗，次數也和時間相符。

**發現並已修正的問題**：

| # | 現象 | 原因 | 修正 |
|---|---|---|---|
| 1 | 手動用 sed 改 controller 設定沒有作用 | Secret Protection 加密後的檔案是 `key = value`（等號兩邊有空白） | 4.2.3.3：比對要容許空白（附指令） |
| 2 | 節點連 repo 8443 得到 `No route to host` | 照舊版 3.2 建的環境，防火牆只開 8080 | 3.3.0：開 8443、關 8080 |
| 3 | 節點的 repo 檢查都「通過」，其實連不上 | `dnf repolist` 不下載 metadata | 3.3.1.1 改用 `dnf makecache`；cpctl verify 也改成從節點檢查 |
| 4 | 「不帶 `--cacert` 應被拒」的預期不成立 | ops 主機在 3.4.8 已把 CA 放進 OS trust store | 3.3.0 改寫說明 |
| 5 | repo 憑證在 CA 輪替後仍是舊的 | 9.1 的函式沒有處理 repo | 新增 `push_repo`，加入每個階段 |
| 6 | 退役後用舊憑證測試卻得到 exit 58 | `import_signed` 歸檔時把舊憑證蓋成銀行的回覆 | 回覆另存為 `<名稱>.bank-answer.pem`；重測 exit 56 |
| 7 | 10.3 的格式化指令在 Secret Protection 下會失敗 | 沒有傳 master key | 改用 4.3.3 的寫法 |
| 8 | 10.1 的磁碟檢查 `Permission denied` | 資料目錄是 cp-kafka 的 0750 | 加 `sudo` |

# 附錄 B. 只在實體主機才會生效的項目

PoC 用容器模擬主機,有些設定屬於整台機器的 kernel 或開機流程,容器內無法設定。cpctl 在容器內會把這些項目標示為 `skipped(container)`,只做檢查;正式機要實際套用。

| 項目 | 設定 | 正式機做法 |
|---|---|---|
| 記憶體映射 | `vm.max_map_count=262144` | 寫入 `/etc/sysctl.d/90-confluent.conf`,`sysctl --system` |
| Swap 與 page cache | `vm.swappiness=1`、`vm.dirty_background_ratio=5`、`vm.dirty_ratio=60` | 同上;並關閉或縮小 swap |
| Transparent Huge Pages | `never` | `disable-thp.service`(開機時寫入 `/sys/kernel/mm/transparent_hugepage/enabled`)或 tuned profile |
| SELinux | enforcing | 為 `/etc/confluent`、`/var/lib/kafka`(tar 另加 `/opt/confluent`)設定 file context,為非標準 port 加 port label,`restorecon` |
| 磁碟 | `log.dirs` 用獨立磁碟、XFS、`noatime` | `/etc/fstab` |
| 時間同步 | chrony 指向行內 NTP | 容器內以 `OPTIONS="-F 2 -x"` 執行(不調整時鐘,容器共用主機時鐘);正式機改為 `OPTIONS="-F 2"`,並確認偏移小於 1 秒 |
| 時區 | `Asia/Taipei` | 容器內只做 `/etc/localtime` symlink;正式機用 `timedatectl set-timezone Asia/Taipei` |
| 部分網路參數 | `net.core.rmem_max`、`net.core.wmem_max` | 容器內可能無法設定(只出現警告);正式機寫入 sysctl.d |
| 名稱解析 | FQDN 正反解一致 | 行內 DNS;PoC 用固定 IP 與 `/etc/hosts` |

# 附錄 C. 常見陷阱

| 陷阱 | 說明 |
|---|---|
| `sudo` 底下的萬用字元 | `*` 由呼叫者的 shell 展開;目錄呼叫者讀不到時會什麼都沒做。改用 `sudo find ... -mindepth 1 -delete` 或 `sudo sh -c '...'` |
| 檔案權限 | 設定檔與憑證為 root:confluent 0640,服務帳號靠群組讀取;`service.env`(含 master key)為 root 0600,由 systemd 讀取 |
| `cmd \| grep -q` | 在 `set -o pipefail` 下,grep 提早結束會讓前面的指令收到 SIGPIPE,整條管線被判定失敗。先把輸出存到變數再比對 |
| 精簡版 OS | 可能沒有 `/etc/sysctl.d`、`diff` 等;寫檔前先 `install -d`,比較檔案用 sha256 |
| JDK cacerts | 每一個 JDK(RPM 版、tar 版、升級後的新版)都有自己的 cacerts,都要匯入內部 CA |
| quorum 變更 | 一次只變動一個 voter;先 `add-controller` 再 `remove-controller`;每一步都等 Lag 歸零 |
| `kraft.version` | 動態 quorum(`kraft.version=1`)啟用後無法降回 |
| 版本鎖定 | rpm 用 `dnf versionlock`,避免日常 `dnf update` 誤升級 Kafka;升級時先 `versionlock delete` |
| 操作機的 `/tmp` | 若為 tmpfs,重開機會清空;要保留的檔案放 `/var/lib/cp-installer/` |
| 操作機也是安裝對象 | 對自己執行的那一輪若會 `rm -f /tmp/<檔名>`,會刪掉還要派送給別台的原始檔;暫存檔放別處 |
| `sysctl` 的結束碼 | 設定失敗(參數唯讀或不存在)時 `sysctl -w`、`sysctl -p` 仍回傳 0;設定後要讀回比對 |
| `kafka-configs --add-config-file` | 不支援 SCRAM 憑證,而且錯誤訊息會印出密碼原文;SCRAM 只用 `--add-config` |
| 行尾註解 | `.properties` 與 systemd unit 都沒有行尾註解,`key=value  # 說明` 的 `#` 之後會變成值;註解要獨立一行 |
| 密碼不進指令列 | 從 0600 密碼檔讀成變數;`samba-tool` 從 stdin 讀、`confluent secret master-key generate --passphrase=-`、`curl --netrc-file`、`keytool -storepass:env` |
| 讀 0640 的憑證 | `/etc/confluent/ssl/*` 為 root:confluent 0640,cpadmin 讀不到;節點上的驗證指令要加 `sudo`(或改用 OS trust store) |
| sudo 之前的檢查 | `[ -d /var/lib/kafka/data ]` 由 cpadmin 判斷時,進不了 0750 的目錄就會當成不存在;判斷也要用 `sudo test -d` |
| 新版本匯入後 | 節點的 dnf metadata 有快取,安裝新版本要加 `--refresh`,否則找不到套件 |
| RPM 換版後 | unit 檔可能被換掉,啟動前先 `systemctl daemon-reload` |
| 健康檢查 | 取樣一次不算數(例如 controller lag 在寫入瞬間可能不是 0);重試數次再下結論,前置檢查失敗就停 |
| 工具錯誤訊息 | `kafka-configs` 失敗時會把整串參數印出來(含 `--add-config` 的密碼);在叢集就緒後再執行,輸出經遮蔽再存檔 |
| 背景工作 | 在有管線的指令裡啟動背景程式,它會佔住管線讓指令不結束;輸出導到檔案 |


# 附錄 D. 手冊引用的檔案完整內容

手動安裝時操作機上沒有 cpctl 專案,以下檔案請從本附錄原樣複製。內容與 `installer/templates/default/` 相同。

## D.1 telemetry 的 metrics.include(4.2.3.8)

一整行,不可換行;controller 與 broker 相同。

```properties
confluent.telemetry.exporter._c3.metrics.include=io.confluent.kafka.server.request.(?!.*delta).*|io.confluent.kafka.server.server.broker.state|io.confluent.kafka.server.replica.manager.leader.count|io.confluent.kafka.server.request.queue.size|io.confluent.kafka.server.broker.topic.failed.produce.requests.rate.1.min|io.confluent.kafka.server.tier.archiver.total.lag|io.confluent.kafka.server.request.total.time.ms.p99|io.confluent.kafka.server.broker.topic.failed.fetch.requests.rate.1.min|io.confluent.kafka.server.broker.topic.total.fetch.requests.rate.1.min|io.confluent.kafka.server.partition.caught.up.replicas.count|io.confluent.kafka.server.partition.observer.replicas.count|io.confluent.kafka.server.tier.tasks.num.partitions.in.error|io.confluent.kafka.server.broker.topic.bytes.out.rate.1.min|io.confluent.kafka.server.request.total.time.ms.p95|io.confluent.kafka.server.controller.active.controller.count|io.confluent.kafka.server.session.expire.listener.zookeeper.disconnects.total|io.confluent.kafka.server.request.total.time.ms.p999|io.confluent.kafka.server.controller.active.broker.count|io.confluent.kafka.server.request.handler.pool.request.handler.avg.idle.percent.rate.1.min|io.confluent.kafka.server.session.expire.listener.zookeeper.disconnects.rate.1.min|io.confluent.kafka.server.controller.unclean.leader.elections.rate.1.min|io.confluent.kafka.server.replica.manager.partition.count|io.confluent.kafka.server.controller.unclean.leader.elections.total|io.confluent.kafka.server.partition.replicas.count|io.confluent.kafka.server.broker.topic.total.produce.requests.rate.1.min|io.confluent.kafka.server.controller.offline.partitions.count|io.confluent.kafka.server.socket.server.network.processor.avg.idle.percent|io.confluent.kafka.server.partition.under.replicated|io.confluent.kafka.server.log.log.start.offset|io.confluent.kafka.server.log.tier.size|io.confluent.kafka.server.log.size|io.confluent.kafka.server.tier.fetcher.bytes.fetched.total|io.confluent.kafka.server.request.total.time.ms.p50|io.confluent.kafka.server.tenant.consumer.lag.offsets|io.confluent.kafka.server.session.expire.listener.zookeeper.expires.rate.1.min|io.confluent.kafka.server.log.log.end.offset|io.confluent.kafka.server.broker.topic.bytes.in.rate.1.min|io.confluent.kafka.server.partition.under.min.isr|io.confluent.kafka.server.partition.in.sync.replicas.count|io.confluent.telemetry.http.exporter.batches.dropped|io.confluent.telemetry.http.exporter.items.total|io.confluent.telemetry.http.exporter.items.succeeded|io.confluent.telemetry.http.exporter.send.time.total.millis|io.confluent.kafka.server.controller.leader.election.rate.(?!.*delta).*|io.confluent.telemetry.http.exporter.batches.failed
```

## D.2 rules-kafka.yml(4.2.5,接在 controller / broker 的 jmx-exporter.yml 標頭後面)

```yaml
# Confluent Server (controllers + brokers): only the MBean domains alerting and capacity planning need
# (JVM metrics jvm_* come from the exporter's built-in collectors)
includeObjectNames:
  - "kafka.server:*"
  - "kafka.controller:*"
  - "kafka.network:type=RequestMetrics,name=RequestsPerSec,*"
  - "kafka.network:type=RequestMetrics,name=TotalTimeMs,*"
  - "kafka.network:type=SocketServer,*"
  - "kafka.log:type=LogFlushStats,*"
excludeObjectNames:
  - "kafka.server:type=*,clientId=*,*"
rules:
  # ...PerSec meters -> counters
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+)PerSec\w*, (.+)=(.+), (.+)=(.+)><>Count'
    name: kafka_$1_$2_$3_total
    type: COUNTER
    labels: { "$4": "$5", "$6": "$7" }
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+)PerSec\w*, (.+)=(.+)><>Count'
    name: kafka_$1_$2_$3_total
    type: COUNTER
    labels: { "$4": "$5" }
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+)PerSec\w*><>Count'
    name: kafka_$1_$2_$3_total
    type: COUNTER
  # meters without PerSec: RequestHandlerAvgIdlePercent (0..1, one-minute rate)
  - pattern: 'kafka.server<type=KafkaRequestHandlerPool, name=RequestHandlerAvgIdlePercent><>OneMinuteRate'
    name: kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent
    type: GAUGE
  # request latency percentiles
  - pattern: 'kafka.network<type=RequestMetrics, name=TotalTimeMs, request=(.+)><>(\d+)thPercentile'
    name: kafka_network_requestmetrics_totaltimems
    type: GAUGE
    labels: { request: "$1", quantile: "0.$2" }
  # gauges: UnderReplicatedPartitions, ActiveControllerCount, OfflinePartitionsCount, ...
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+), (.+)=(.+)><>Value'
    name: kafka_$1_$2_$3
    type: GAUGE
    labels: { "$4": "$5" }
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+)><>Value'
    name: kafka_$1_$2_$3
    type: GAUGE
  - pattern: 'kafka.network<type=SocketServer><>([a-z-]+): (.+)'
    name: kafka_network_socketserver_$1
    type: GAUGE
```

## D.3 rules-rest.yml(5.2.1,接在 REST Proxy 的 jmx-exporter.yml 標頭後面)

```yaml
# REST Proxy: Jetty / REST request metrics + JVM
includeObjectNames:
  - "kafka.rest:type=jetty-metrics,*"
  - "kafka.rest:type=jersey-metrics,*"
rules:
  - pattern: 'kafka.rest<type=jetty-metrics><>([a-z-]+): (.+)'
    name: kafka_rest_jetty_$1
    type: GAUGE
  - pattern: 'kafka.rest<type=jersey-metrics><>([a-z0-9.-]+): (.+)'
    name: kafka_rest_jersey_$1
    type: GAUGE
```

## D.4 /usr/local/sbin/opmenu-bootstrap(6.4,jump01,root:root 0755)

```bash
#!/bin/bash
# Managed by cpctl - break-glass wrapper for the OP menu (item 91 and second-person queries).
# Runs as opbootstrap through sudo; operators never read the certificate. Same interface as the opmenu demo wrapper:
#   opmenu-bootstrap kafka <tool> <args...>       Kafka CLI as the break-glass identity (INTERNAL listener, mTLS)
#   opmenu-bootstrap mds <METHOD> <path> [json]   MDS call with the break-glass certificate; last line "HTTP <code>"
set -uo pipefail
. /etc/opmenu/opmenu.conf
B=/etc/opmenu/bootstrap
case "${1:-}" in
  kafka)
    tool="${2:?tool}"; shift 2
    case "$tool" in kafka-*) ;; *) echo "only kafka-* tools are allowed"; exit 2 ;; esac
    exec env KAFKA_HEAP_OPTS="-Xmx256m" "$tool" --bootstrap-server "$OPMENU_BREAKGLASS_BOOTSTRAP" --command-config "$B/breakglass.properties" "$@" ;;
  mds)
    m="${2:?METHOD}"; p="${3:?path}"; b="${4:-}"
    a=(-s --max-time 10 --cacert "$B/ca.pem" -X "$m" --cert "$B/breakglass.pem" --key "$B/breakglass.key"
      -H "Content-Type: application/json" -w $'\nHTTP %{http_code}')
    [ -n "$b" ] && a+=(-d "$b")
    for u in ${OPMENU_MDS_URL//,/ }; do out=$(curl "${a[@]}" "$u$p") && { printf '%s' "$out"; exit 0; }; done
    echo "MDS unreachable: $OPMENU_MDS_URL" >&2; exit 1 ;;
  *) echo "usage: opmenu-bootstrap kafka <tool> ... | mds <METHOD> <path> [json]"; exit 2 ;;
esac
```

## D.5 /usr/local/sbin/opmenu-clean-logs(6.8,各節點,root:root 0755)

```bash
#!/bin/bash
# Managed by cpctl - delete rolled Confluent application logs older than N days (OP menu item 24, via sudo).
# Only the log directories; never the Kafka data directory. Minimum 1 day; current log files are never touched.
set -u
days="${1:?days}"
[[ "$days" =~ ^[0-9]+$ && "$days" -ge 1 ]] || { echo "days must be a number >= 1"; exit 2; }
n=0
for d in /var/log/kafka /var/log/confluent; do
  [ -d "$d" ] || continue
  c=$(find "$d" -type f \( -name '*.log.*' -o -name '*.log-*' -o -name '*.gz' \) -mtime +"$days" -print -delete | wc -l)
  n=$((n + c))
done
echo "deleted $n rolled log files older than $days days ($(hostname))"
```

## D.6 演練用持續負載 load.sh(8.4、9.2;放在操作機 /var/lib/cp-installer/manual/load.sh)

一個 producer 以 SCRAM 每 0.2 秒送一筆帶序號的訊息(acks=all、idempotent),另一路每秒經 LB 呼叫一次 REST v3;`report` 比對送出與讀回的序號。使用前要有 3.4 的 `truststore.p12` 與 5.3 的 `app-orders-scram.properties`。

```bash
#!/usr/bin/env bash
# Continuous traffic for upgrade / failover drills (run on the ops host as cpadmin).
#   tools/load.sh start   background producers: SCRAM (numbered, acks=all) + REST v3 via the LB
#   tools/load.sh stop
#   tools/load.sh report  produced vs. consumed (gaps = lost messages), REST success / failure counts
set -Eeuo pipefail
STATE=/var/lib/cp-installer
DIR=$STATE/load
PKI=$STATE/pki
TOPIC=orders.load
BOOT=kb01.poc.lab:9095,kb02.poc.lab:9095,kb03.poc.lab:9095,kb04.poc.lab:9095
CFG=$STATE/client/app-orders-scram.properties
# Kafka tools from whichever install strategy is present on the ops host (tar first, then RPM)
if [[ -x /opt/confluent/current/bin/kafka-topics ]]; then
  export PATH=/opt/confluent/current/bin:$PATH JAVA_HOME=/opt/java/current
  KAFKA_ETC=/opt/confluent/current/etc/kafka
else
  KAFKA_ETC=/etc/kafka
fi
export KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=$KAFKA_ETC/tools-log4j2.yaml
mkdir -p "$DIR"

start() {
  [[ -f $CFG ]] || { echo "run 'cpctl verify' once first (creates $CFG)"; exit 1; }
  kafka-topics --bootstrap-server "${BOOT%%,*}" --command-config "$CFG" --create --if-not-exists \
    --topic "$TOPIC" --partitions 6 --replication-factor 3 --config min.insync.replicas=2 >/dev/null 2>&1 || true
  : >"$DIR/produced.seq"
  date +%s%3N >"$DIR/start.ms"   # the report only counts messages written after this
  : >"$DIR/rest.log"   # per run: the report must not count earlier runs (or a torn write from an unclean shutdown)
  (
    i=0
    while [[ -f $DIR/running ]]; do
      i=$((i + 1)); printf '%s\n' "$i"; printf '%s\n' "$i" >>"$DIR/produced.seq"; sleep 0.2
    done | kafka-console-producer --bootstrap-server "$BOOT" --producer.config "$CFG" --topic "$TOPIC" \
      --producer-property acks=all --producer-property enable.idempotence=true \
      --producer-property delivery.timeout.ms=300000 --producer-property retries=2147483647 \
      >"$DIR/producer.log" 2>&1
  ) &
  echo $! >"$DIR/producer.pid"
  (
    . "$STATE/kraft.env"
    while [[ -f $DIR/running ]]; do
      # "|| true": a failed call (no JSON -> grep finds nothing) must be counted, not end the loop (set -e + pipefail)
      code=$(curl -s -m 10 --cacert "$PKI/ca.pem" --cert "$PKI/app-legacy-billing.crt" --key "$PKI/app-legacy-billing.key" \
        -X POST -H 'Content-Type: application/json' -d '{"value":{"type":"JSON","data":{"src":"rest-load"}}}' \
        "https://rest.poc.lab:8082/v3/clusters/$CLUSTER_ID/topics/billing.events/records" | grep -o '"error_code":[0-9]*' | cut -d: -f2 || true)
      printf '%s %s\n' "$(date +%T)" "${code:-noresponse}" >>"$DIR/rest.log"
      sleep 1
    done
  ) &
  echo $! >"$DIR/rest.pid"
  echo "load started (topic $TOPIC)"
}

stop() {
  rm -f "$DIR/running"
  sleep 3
  local p
  for p in producer rest; do [[ -f $DIR/$p.pid ]] && kill "$(cat "$DIR/$p.pid")" 2>/dev/null || true; done
  echo "load stopped"
}

report() {
  local produced consumed missing since
  [[ -f $DIR/running ]] && { echo "stop the load first (the report reads until the topic is idle for 30 s)"; exit 1; }
  produced=$(wc -l <"$DIR/produced.seq")
  # sequence numbers restart at 1 on every start and the topic keeps earlier runs: count only messages
  # written since this run started (record timestamp), otherwise old messages would hide lost ones
  since=$(cat "$DIR/start.ms" 2>/dev/null || echo 0)
  kafka-console-consumer --bootstrap-server "$BOOT" --consumer.config "$CFG" --topic "$TOPIC" \
    --group "orders-load-report-$$" --from-beginning --timeout-ms 30000 --property print.timestamp=true 2>/dev/null |
    awk -F'\t' -v s="$since" '{t=$1; sub(/^CreateTime:/, "", t)} t >= s && $2 ~ /^[0-9]+$/ {print $2}' |
    sort -n -u >"$DIR/consumed.seq" || true
  consumed=$(wc -l <"$DIR/consumed.seq")
  missing=$(comm -23 <(sort -u "$DIR/produced.seq") <(sort -u "$DIR/consumed.seq") | wc -l)
  printf 'SCRAM producer : %s produced, %s consumed (written since %s), %s missing\n' "$produced" "$consumed" \
    "$(date -d "@$((since / 1000))" +%T)" "$missing"
  printf 'REST v3 via LB : %s ok, %s failed\n' "$(grep -c ' 200$' "$DIR/rest.log" || true)" "$(grep -vc ' 200$' "$DIR/rest.log" || true)"
  grep -v ' 200$' "$DIR/rest.log" | head -5 || true
}

case ${1:-} in
  start) touch "$DIR/running"; start ;;
  stop) stop ;;
  report) report ;;
  *) echo "usage: $0 start|stop|report"; exit 2 ;;
esac
```

## D.7 輪替用共用函式 rotate-lib.sh(第 9 章;存成 ~/rotate-lib.sh)

這是全程實測環境的版本(操作機 ops02、controller kc01–kc03)。用在其他環境時,請替換 `SANS_INTERNAL`、`SANS_SERVER` 與各函式裡的主機清單。

```bash
# Manual walkthrough helpers for certificate / CA rotation (ops02, cpadmin). Source after ~/manual.env.
# Every function is a plain sequence of the commands in manual chapter 9; nothing here is cpctl.
. ~/manual.env
set -a; . $S/secrets.env; set +a

# issue <name> <EKU> [SANs]  (same as 3.4.3; archives the previous files first)
issue() {
  local n=$1 eku=$2 sans=${3:-} arch
  ( cd $PKI && umask 077
    if [ -f $n.crt ]; then arch=archive/$(date +%Y%m%d-%H%M%S)-$n; install -d -m 0700 $arch; cp -p $n.* $arch/; fi
    { printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
      printf 'extendedKeyUsage=%s\n' "$eku"
      [ -n "$sans" ] && printf 'subjectAltName=%s\n' "$(tr ',' '\n' <<<"$sans" | sort -u | sed 's/^/DNS:/' | paste -sd, -)"
    } > $n.ext
    openssl genrsa -out $n.key 3072 2>/dev/null
    openssl req -new -key $n.key -out $n.csr -subj "/CN=$n/OU=Confluent/O=PoC Bank/C=TW"
    openssl x509 -req -in $n.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -sha256 -extfile $n.ext -out $n.crt 2>/dev/null
    rm -f $n.ext $n.csr
    openssl pkcs12 -export -name $n -inkey $n.key -in $n.crt -certfile ca.crt -passout env:STORE_PASSWORD -out $n.p12
    cat $n.crt ca.crt > $n.chain.pem
    echo "issued $n serial=$(openssl x509 -in $n.crt -noout -serial | cut -d= -f2) issuer=$(openssl x509 -in $n.crt -noout -issuer | sed 's/.*CN=\([^,]*\).*/\1/')" )
}
SANS_INTERNAL=kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04
SANS_SERVER=ops02.poc.lab,ops02,ad01.poc.lab,ad01,lb01.poc.lab,lb01,kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04,rest01.poc.lab,rest01,rest02.poc.lab,rest02,c3-01.poc.lab,c3-01,rest.poc.lab,c3.poc.lab,localhost

# request <name> <EKU> [SANs]  (bank CA, 3.4.9.2): new key in pending/ (never leaves this host), CSR in requests/
request() {
  ( cd $PKI && umask 077 && install -d -m 0700 pending && install -d -m 0750 requests incoming
    n=$1; ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$2")
    [ -n "${3:-}" ] && ext+=(-addext "subjectAltName=$(tr ',' '\n' <<<"$3" | sort -u | sed 's/^/DNS:/' | paste -sd, -)")
    openssl genrsa -out pending/$n.key 3072 2>/dev/null && chmod 0600 pending/$n.key
    openssl req -new -key pending/$n.key -sha256 -subj "/CN=$n/OU=Confluent/O=PoC Bank/C=TW" "${ext[@]}" -out requests/$n.csr
    echo "request $n: EKU=$2 SANs=$(openssl req -in requests/$n.csr -noout -text | grep -o 'DNS:' | wc -l) -> requests/$n.csr" )
}

# import_signed <name> <EKU> [SANs]  (bank CA, 3.4.9.3): checks incoming/<name>.crt; installs ONLY if every check passes
import_signed() {
  ( cd $PKI && umask 077
    n=$1 eku=$2 want=$(tr ',' '\n' <<<"${3:-}" | sed '/^$/d' | sort -u | paste -sd, -)
    w=$(mktemp -d); awk -v d="$w" '/BEGIN CERTIFICATE/ {k++} {print > (d "/c-" k ".pem")}' incoming/$n.crt
    fail() { echo "REJECTED $n: $* - nothing installed"; rm -rf "$w"; exit 1; }
    kp=$(openssl pkey -in pending/$n.key -pubout); leaf=
    for f in "$w"/c-*.pem; do [ "$(openssl x509 -in $f -noout -pubkey)" = "$kp" ] && leaf=$f; done
    [ -n "$leaf" ] || fail "no certificate in the file matches pending/$n.key"
    cn=$(openssl x509 -in $leaf -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')
    [ "$cn" = "$n" ] || fail "CN is '$cn'"
    [[ $(openssl x509 -in $leaf -noout -ext basicConstraints 2>/dev/null) == *CA:TRUE* ]] && fail "it is a CA certificate"
    have=$(openssl x509 -in $leaf -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr ',' '\n' | sed 's/^ *DNS://; /^ *$/d' | sort -u | paste -sd, -)
    [ "$have" = "$want" ] || fail "SAN [$have], requested [$want]"
    e=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage 2>/dev/null | tail -n +2 | sed 's/^ *//')
    [[ ,$eku, == *,serverAuth,* && $e != *"Server Authentication"* ]] && fail "extended key usage lacks serverAuth ($e)"
    [[ ,$eku, == *,clientAuth,* && $e != *"Client Authentication"* ]] && fail "extended key usage lacks clientAuth ($e)"
    openssl x509 -in $leaf -noout -checkend $((30 * 86400)) >/dev/null || fail "expires within 30 days"
    cat $leaf > $w/chain.pem
    for f in "$w"/c-*.pem; do
      [ $f = $leaf ] && continue
      [ "$(openssl x509 -in $f -noout -subject_hash)" = "$(openssl x509 -in $f -noout -issuer_hash)" ] && continue
      cat $f >> $w/chain.pem
    done
    cat trust/*.pem > $w/roots.pem
    openssl verify -partial_chain -CAfile $w/roots.pem -untrusted $w/chain.pem $w/chain.pem >/dev/null || fail "does not chain to a root in trust/ (intermediate missing?)"
    arch=archive/$(date +%Y%m%d-%H%M%S)-$n; install -d -m 0700 $arch
    # previous files keep their names; the bank answer and the CSR get their own (an answer named $n.crt would
    # overwrite the archived previous certificate)
    cp -p $n.crt $n.key $n.p12 $n.chain.pem $arch/ 2>/dev/null; mv incoming/$n.crt $arch/$n.bank-answer.pem; mv requests/$n.csr $arch/ 2>/dev/null
    install -m 0600 pending/$n.key $n.key && install -m 0640 $w/chain.pem $n.crt && cp $n.crt $n.chain.pem
    openssl pkcs12 -export -name $n -inkey $n.key -in $n.crt -passout env:STORE_PASSWORD -out $n.p12
    rm -f pending/$n.key; rm -rf "$w"
    echo "imported $n serial=$(openssl x509 -in $n.crt -noout -serial | cut -d= -f2) issuer=$(openssl x509 -in $n.crt -noout -issuer | sed 's/.*CN=\([^,]*\).*/\1/') certs-in-file=$(grep -c BEGIN $n.crt)" )
}

# truststores from the bundle ca.pem (3.4.2 and 6.3): truststore.p12 (STORE_PASSWORD), opmenu-truststore.p12 (own password)
truststores() {
  ( cd $PKI && umask 077
    d=$(mktemp -d); awk -v d="$d" '/BEGIN CERTIFICATE/ {n++} {print > (d "/ca-" n ".pem")}' ca.pem
    # build beside the target, then rename: a client starting meanwhile must not load a missing / partial truststore
    rm -f truststore.p12.new opmenu-truststore.p12.new; i=0
    for f in "$d"/ca-*.pem; do i=$((i+1))
      $JAVA_HOME/bin/keytool -importcert -noprompt -alias internal-ca-$i -file "$f" -keystore truststore.p12.new -storetype PKCS12 -storepass:env STORE_PASSWORD >/dev/null
      $JAVA_HOME/bin/keytool -importcert -noprompt -alias internal-ca-$i -file "$f" -keystore opmenu-truststore.p12.new -storetype PKCS12 -storepass:env OPMENU_TRUSTSTORE_PASSWORD >/dev/null
    done; rm -rf "$d"
    mv -f truststore.p12.new truststore.p12 && mv -f opmenu-truststore.p12.new opmenu-truststore.p12
    echo "truststores rebuilt with $i CA(s): $(grep -c 'BEGIN CERT' ca.pem) in ca.pem" )
}

# push_ssl <host> <files...>  -> /etc/confluent/ssl (root:confluent 0640), as in 3.4.7
push_ssl() {
  local h=$1; shift
  ( cd $PKI && scp -q "$@" $h.poc.lab:/tmp/ )
  ssh $h.poc.lab "for f in $*; do sudo install -o root -g confluent -m 0640 /tmp/\$f /etc/confluent/ssl/\$f && rm -f /tmp/\$f; done"
}
push_all_ssl() {  # role-specific file sets (3.4.7)
  local h
  for h in kc01 kc02 kc03; do push_ssl $h ca.pem truststore.p12 kafka-internal.p12; done
  for h in kb01 kb02 kb03 kb04; do push_ssl $h ca.pem truststore.p12 kafka-internal.p12 cp-server.p12; done
  for h in rest01 rest02; do push_ssl $h ca.pem truststore.p12 cp-server.p12; done
  push_ssl c3-01 ca.pem truststore.p12 cp-server.p12 cp-server.crt cp-server.key
  echo "pushed /etc/confluent/ssl to 10 hosts"
}

# trust_all -> OS trust anchor = bundle, JDK cacerts = exactly the bundle's CAs (3.4.8)
trust_all() {
  local h
  for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01 jump01; do
    scp -q $PKI/ca.pem $h.poc.lab:/tmp/cp-internal-ca.pem
    ssh $h.poc.lab 'bash -s' <<'EOS'
set -e
sudo install -o root -g root -m 0644 /tmp/cp-internal-ca.pem /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem; rm -f /tmp/cp-internal-ca.pem
sudo update-ca-trust extract
JH=/usr/lib/jvm/temurin-21-jdk; d=$(mktemp -d); want=""
awk -v d="$d" '/BEGIN CERTIFICATE/ {n++} {print > (d "/ca-" n ".pem")}' /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem
for f in "$d"/ca-*.pem; do
  fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f' | cut -c1-16); want="$want cp-ca-$fp"
  sudo $JH/bin/keytool -list -cacerts -storepass changeit -alias cp-ca-$fp >/dev/null 2>&1 || sudo $JH/bin/keytool -importcert -noprompt -cacerts -storepass changeit -alias cp-ca-$fp -file "$f" >/dev/null
done; rm -rf "$d"
for a in $(sudo $JH/bin/keytool -list -cacerts -storepass changeit | grep -oE '^cp-ca-[0-9a-f]+'); do case " $want " in *" $a "*) ;; *) sudo $JH/bin/keytool -delete -cacerts -storepass changeit -alias $a ;; esac; done
echo "$(hostname): OS anchors=$(trust list --filter=ca-anchors | grep -c -E 'label: PoC (Internal CA|Bank Root)') JDK=$(sudo $JH/bin/keytool -list -cacerts -storepass changeit | grep -c '^cp-ca-')"
EOS
  done
}

# ad01 LDAPS (4.1.1) and jump01 (6.3 / 6.4) trust material
push_ad() {
  scp -q $PKI/cp-server.key $PKI/cp-server.crt $PKI/ca.pem ad01.poc.lab:/tmp/
  ssh ad01.poc.lab "sudo install -o root -g root -m 0600 /tmp/cp-server.key /var/lib/samba/private/tls/key.pem && sudo install -o root -g root -m 0644 /tmp/cp-server.crt /var/lib/samba/private/tls/cert.pem && sudo install -o root -g root -m 0644 /tmp/ca.pem /var/lib/samba/private/tls/ca.pem && sudo rm -f /tmp/cp-server.key /tmp/cp-server.crt /tmp/ca.pem && sudo pkill -x samba || true"
  local i; for i in $(seq 1 24); do sleep 5; LDAPTLS_CACERT=$PKI/ca.pem ldapsearch -LLL -x -o nettimeout=5 -H ldaps://ad01.poc.lab:636 -s base -b "" namingContexts >/dev/null 2>&1 && { echo "ad01 LDAPS back after ~$((i*5))s"; return 0; }; done; echo "ad01 LDAPS NOT back"
}
push_jump() {
  ( cd $PKI && umask 077 && openssl pkcs12 -export -name opmenu-breakglass -inkey opmenu-breakglass.key -in opmenu-breakglass.crt $([ -f ca.crt ] && echo "-certfile ca.crt") -passout env:OPMENU_BREAKGLASS_STORE_PASSWORD -out opmenu-breakglass.bg.p12 )
  ( cd $PKI && scp -q opmenu-truststore.p12 ca.pem cp-server.crt kafka-internal.crt opmenu-breakglass.bg.p12 opmenu-breakglass.crt opmenu-breakglass.key jump01.poc.lab:/tmp/ )
  ssh jump01.poc.lab 'sudo bash -s' <<'EOS'
set -e
install -o root -g opmenu -m 0640 /tmp/opmenu-truststore.p12 /etc/opmenu/certs/truststore.p12
install -o root -g opmenu -m 0644 /tmp/ca.pem /etc/opmenu/certs/ca.pem
install -o root -g opmenu -m 0644 /tmp/cp-server.crt /etc/opmenu/certs/cp-server.pem
install -o root -g opmenu -m 0644 /tmp/kafka-internal.crt /etc/opmenu/certs/kafka-internal.pem
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-truststore.p12 /etc/opmenu/bootstrap/truststore.p12
install -o opbootstrap -g opbootstrap -m 0644 /tmp/ca.pem /etc/opmenu/bootstrap/ca.pem
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-breakglass.bg.p12 /etc/opmenu/bootstrap/breakglass.p12
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-breakglass.crt /etc/opmenu/bootstrap/breakglass.pem
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-breakglass.key /etc/opmenu/bootstrap/breakglass.key
shred -u /tmp/opmenu-breakglass.key /tmp/opmenu-breakglass.bg.p12 2>/dev/null; rm -f /tmp/opmenu-truststore.p12 /tmp/ca.pem /tmp/cp-server.crt /tmp/kafka-internal.crt /tmp/opmenu-breakglass.crt
echo "jump01: opmenu trust material and break-glass updated"
EOS
}

# push_repo  (3.3.0): the internal repo over HTTPS follows every rotation - repo server certificate = cp-server,
# every node pins ca.pem as cp-repo-ca.pem; then each node must still download the repo metadata
push_repo() {
  ( cd $PKI && sudo install -o root -g root -m 0644 cp-server.crt /etc/pki/tls/certs/cp-repo.crt &&
    sudo install -o root -g root -m 0600 cp-server.key /etc/pki/tls/private/cp-repo.key &&
    sudo httpd -t >/dev/null 2>&1 && sudo systemctl restart httpd && echo "repo server: $(openssl x509 -in cp-server.crt -noout -serial)" )
  local h
  for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01 jump01; do
    scp -q $PKI/ca.pem $h.poc.lab:/tmp/cp-repo-ca.pem
    ssh $h.poc.lab "sudo install -o root -g root -m 0644 /tmp/cp-repo-ca.pem /etc/pki/tls/certs/cp-repo-ca.pem && rm -f /tmp/cp-repo-ca.pem && sudo dnf -q --refresh --disablerepo='*' --enablerepo='cp-internal-*' makecache >/dev/null 2>&1 && echo \"\$(hostname): repo OK\" || echo \"\$(hostname): REPO FAILED\""
  done
}

# rolling restart of everything that holds keystores/truststores in memory: controllers -> brokers -> REST (drained) -> C3
broker_ok() { local id=$((100 + ${1#kb0})); kafka-broker-api-versions --bootstrap-server $B --command-config $CFG 2>/dev/null | grep -q "(id: $id rack: [a-z-]* isFenced: false)" && [ -z "$(kafka-topics --bootstrap-server $B --command-config $CFG --describe --under-replicated-partitions 2>/dev/null)" ]; }
ctl_ok() { local id=${1#kc0}; kafka-metadata-quorum --bootstrap-controller $CB --command-config $CFG describe --replication 2>/dev/null | awk -v id=$id '$1==id && ($NF=="Leader"||$NF=="Follower") && $4+0==0 {ok=1} END {exit !ok}'; }
wait_for() { local i; for i in $(seq 1 60); do "$@" && { echo "  healthy after ~$((i*5))s"; return 0; }; sleep 5; done; echo "  NOT HEALTHY - stop here"; return 1; }
lbconf() {
  { echo 'upstream cp_rest {'; echo '    hash $remote_addr consistent;'
    for r in rest01 rest02; do printf '    server %s.poc.lab:8082 max_fails=2 fail_timeout=10s%s;\n' $r "$([ "$r" = "$1" ] && echo ' down')"; done
    echo '}'; echo 'upstream cp_c3 {'; echo '    server c3-01.poc.lab:9021 max_fails=2 fail_timeout=10s;'; echo '}'
    echo 'server { listen 8082; proxy_pass cp_rest; proxy_connect_timeout 3s; proxy_timeout 10m; }'
    echo 'server { listen 9021; proxy_pass cp_c3;   proxy_connect_timeout 3s; proxy_timeout 1h;  }'; } > $S/manual/cp.conf.new
  scp -q $S/manual/cp.conf.new lb01.poc.lab:/tmp/cp.conf.new
  ssh lb01.poc.lab 'sudo install -o root -g root -m 0644 /tmp/cp.conf.new /etc/nginx/stream.d/cp.conf && rm -f /tmp/cp.conf.new && sudo nginx -t -q && sudo nginx -s reload 2>/dev/null'
}
restart_all() {
  local h L
  L=$(kafka-metadata-quorum --bootstrap-controller $CB --command-config $CFG describe --status | awk '/LeaderId:/ {print $2}')
  for h in $(for c in kc01 kc02 kc03; do [ "${c#kc0}" != "$L" ] && echo $c; done) kc0$L; do echo "restart $h ($(date +%T))"; ssh $h.poc.lab 'sudo systemctl restart confluent-server'; wait_for ctl_ok $h || return 1; done
  for h in kb01 kb02 kb03 kb04; do echo "restart $h ($(date +%T))"; ssh $h.poc.lab 'sudo systemctl restart confluent-server'; sleep 10; wait_for broker_ok $h || return 1; done
  for h in rest01 rest02; do
    echo "restart $h (drained, $(date +%T))"; lbconf $h; sleep 5; ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'
    rok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --cacert $PKI/ca.pem --cert $PKI/app-legacy-billing.crt --key $PKI/app-legacy-billing.key https://$h.poc.lab:8082/v3/clusters)" = 200 ]; }
    wait_for rok || return 1; lbconf ""
  done
  echo "restart c3-01 ($(date +%T))"; ssh c3-01.poc.lab 'for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done'
  c3ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --cacert $PKI/ca.pem https://c3-01.poc.lab:9021/)" = 200 ]; }
  wait_for c3ok
}

# served -> serial and issuer each TLS endpoint presents right now
served() {
  local ep s
  for ep in kc01:9093 kc02:9093 kc03:9093 kb01:9092 kb01:8090 kb02:8090 kb03:8090 kb04:8090 kb04:9095 rest01:8082 rest02:8082 c3-01:9021 c3-01:9090 ad01:636 kb01:7071 kc01:7071; do
    s=$(openssl s_client -connect ${ep%:*}.poc.lab:${ep#*:} -CAfile $PKI/ca.pem -cert $PKI/kafka-internal.crt -key $PKI/kafka-internal.key </dev/null 2>/dev/null | openssl x509 -noout -serial -issuer 2>/dev/null | sed 's/serial=//; s/issuer=.*CN=\([^,]*\).*/\1/' | paste -sd' ')
    printf '%-14s %s\n' $ep "${s:-no certificate}"
  done
}
```
