# Confluent Platform 8.3 企業版 — 離線安裝 PoC

以 Docker 容器在 Windows 11 上模擬多台 RHEL 9 主機，驗證一套**離線、腳本化、冪等、可升級**的 Confluent Platform 企業版安裝流程。所有安裝動作都由「操作機」(ops01) 上的 `cpctl` 透過 SSH 執行；換成真實主機時只需修改 `installer/conf/*.env`。

| 元件 | 版本 | 數量 |
|---|---|---|
| Confluent Platform (Confluent Server, KRaft) | 8.3.2（升級演練起點 8.2.4） | controller ×3（動態 quorum）、broker ×4 |
| REST Proxy | 8.3.2 | ×2，前置 Nginx L4 負載平衡 |
| Control Center Next Gen（內建 Prometheus / Alertmanager） | 2.6.1 | ×1 |
| Eclipse Temurin JDK | 21 | 所有 Java 節點 |
| 模擬 AD（Samba AD DC） | Debian 12 | ×1（環境周邊） |

## 架構

```
Windows ──(8082 / 9021)── lb01  Nginx stream (L4 passthrough, source-hash 黏著) ── 唯一可連外的節點 (DMZ)
                             ├─ rest01 / rest02 :8082   REST Proxy (mTLS + RBAC)
                             └─ c3-01 :9021             Control Center (AD 帳密登入)
cpnet (internal, 無外網) ──────────────────────────────────────────────────────────
  ops01   操作機 + 內部 yum/raw repo (:8080)        ad01  AD (LDAPS :636)
  kc01-03 KRaft controller :9093 (mTLS)             kb01-04 broker + MDS :8090
```

### 身分與驗證

| 誰 | 對象 | 方式 | RBAC principal |
|---|---|---|---|
| controller ↔ controller、broker ↔ broker/controller | CONTROLLER / INTERNAL listener | mTLS，**共用內部憑證** `CN=kafka-internal` | `User:kafka-internal`（super user） |
| 應用程式 | Kafka（CLIENT :9095） | SASL_SSL SCRAM-SHA-512 | `User:<app>` |
| 應用程式 | REST Proxy（經 LB） | mTLS，每個 app 一張 client 憑證 | `User:<app>`（REST 以 MDS token 代理身分） |
| 人員 | Kafka CLI（LDAP :9096）、MDS、C3 | AD 帳密（LDAPS） | `Group:<AD 群組>` |
| REST Proxy / C3 本身 | MDS、TOKEN listener :9094 | AD 服務帳號 `svc-rest` / `svc-c3` | 各自獨立 |
| 所有伺服器的 HTTPS / TLS | — | **共用 server 憑證** `CN=cp-server`（SAN 含所有主機與 LB 名稱） | — |

- C3 / REST Proxy → Kafka 走 TOKEN listener（:9094）：單向 TLS，身分由 MDS 簽發的 OAUTHBEARER token 證明（RS256、效期 1 小時，與官方範例一致）。若資安要求伺服器之間一律雙向驗證，可把 `listener.name.token.ssl.client.auth` 改為 `required`，並讓 REST / C3 出示共用的 `cp-server` 憑證；改完需要滾動重啟。
- REST Proxy **只開放給 legacy app**（`conf/apps.env` 中 `APP_CHANNEL=rest`）。principal 對應規則由這份清單自動產生，且不使用 DEFAULT，因此其他憑證（伺服器、super user、一般 app）一律會被拒絕。一般 app 則以 SCRAM 直連 Kafka。
- `impersonation.protected.users` 由 super.users 加上所有 AD 服務帳號自動產生，不需手動維護。
- mTLS principal 依官方限制**不能套用群組授權**，所以每個 app 的 role binding 是由 `conf/apps.env` 逐一產生。
- 機器帳號不登入 C3（官方文件未記載這種用法）。C3 只給人員使用；C3 與 Prometheus、Alertmanager 之間全程 mTLS。

## 目錄

```
windows/        Git Bash：環境控制 poc.sh、外網下載 download-packages.sh、驗證 verify-packages.sh、掃描 hook scan.d/、
                OP menu 打包 package-opmenu.sh
opmenu/         堡壘機上的維運操作選單（OP menu）原始碼；經離線引進流程打包、由 cpctl step 11 部署
docker/         模擬主機 image（node / ops / ad / lb）與 compose.yml（jump01 = 模擬堡壘機）
packages/       落地區（不進版控）：RPM、GPG key、SHA256SUMS、manifest、驗證報告
installer/      掛載到 ops01:/opt/cp-installer
  bin/cpctl     唯一入口
  conf/         inventory / versions / apps / os-tuning / compat / secrets（secrets 不進版控）
  lib/          框架：core log inventory remote(Facade) render handler(Observer) step(Template Method) …
  lib/node/     送到目標主機執行的冪等原語（ensure::*、svc::*、kafka/ad 輔助）
  lib/install/  安裝 Strategy：rpm（預設、建議）/ tar（版本並存 + symlink）
  lib/repo/     內部 repo Adapter：local（createrepo_c + httpd）
  roles/        角色 Strategy：controller broker rest c3 lb ad jump（堡壘機）
  steps/        安裝流程 00–11（11 = OP menu）
  upgrade/      升級、controller 替換、uninstall
  templates/    設定檔模板（依版本 templates/<major.minor>/，無則 default/）
  tools/        lint.sh（shellcheck + shfmt）、load.sh（演練用持續流量）
docs/           全流程簡報（deck-src/ 產生）、手動安裝手冊 Confluent-手動安裝手冊.docx（manual-src/ 產生）
```

想知道 cpctl 每一步實際做了什麼，請看 `docs/Confluent-手動安裝手冊.docx`：離線引進、步驟 00–11、tar.gz 安裝方式都拆成不經 cpctl 的手動指令（指令、設定檔內容、驗證、對應的 cpctl 函式），並附在備用節點 kc03 上實際手動跑過的紀錄。

## 快速開始（Windows 11 + Docker Desktop，Git Bash）

```bash
cp windows/wslconfig.example "$USERPROFILE/.wslconfig"   # 建議 12GB，修改後執行 wsl --shutdown
bash windows/poc.sh secrets                # 產生 installer/conf/secrets.env（只產生缺少的值）
bash windows/poc.sh build                  # 建立模擬主機 image（需外網，只做一次）
bash windows/download-packages.sh          # 外網下載機：dnf download --resolve + GPG 驗證 + manifest
bash windows/verify-packages.sh            # 放行前驗證：sha256、原廠簽章、掃描 hook → report/
bash windows/poc.sh up                     # 啟動 13 台模擬主機
bash windows/poc.sh cpctl repo import      # 落地區 → 內部 repo（先驗證，同名不同內容一律拒絕）
bash windows/poc.sh cpctl install          # 步驟 00–10，可中斷後重跑
bash windows/poc.sh cpctl verify           # 端到端驗證（48 項）
```

瀏覽器開啟 `https://localhost:9021`（C3，需信任 `ops01:/var/lib/cp-installer/pki/ca.pem`），用 `conf/apps.env` 中的 AD 帳號登入（例如 `alice`，密碼為 `HUMAN_DEFAULT_PASSWORD`）。

## 離線軟體引進流程（建議與銀行討論的方案）

```
外網下載機 ─▶ 驗證 / 掃描 ─▶ 安全檔案交換 ─▶ 內部 repo ─▶ 部署機
download-     verify-        （PoC：packages/    cpctl repo     dnf install（gpgcheck=1）
packages.sh   packages.sh     唯讀掛載到 ops01）   import          + versionlock
```

- **RPM 為主**：使用原廠 GPG 簽章，套件自帶 systemd unit，也能接上 RHEL 9 的 Satellite／dnf 維運流程。
- **tar.gz 為替代策略**（`INSTALL_METHOD=tar`，或執行時用 `CPCTL_INSTALL_METHOD=tar` 覆寫）：適合不允許安裝第三方 RPM、或希望多版本並存的環境。

  | 項目 | RPM | tar |
  |---|---|---|
  | 套件來源 | 內部 yum repo（gpgcheck=1） | 內部 raw repo `/raw/tar/`；節點下載後**比對 sha256**，相符才解壓 |
  | 完整性 | 原廠 GPG 簽章 | CP / C3 原廠**沒有提供簽章**，只能依賴下載時記錄的 sha256；Temurin JDK 有比對原廠 checksum |
  | 安裝位置 | `/usr/bin`、`/usr/share/java` | `/opt/confluent/confluent-<版本>/`，`current` symlink 指向目前版本；C3 用 `c3-current`；JDK 在 `/opt/java/current` |
  | 服務帳號、systemd unit | RPM 自動建立 | cpctl 建立：帳號名稱、unit 名稱、路徑都和 RPM 版相同，所以 drop-in、角色、升級流程共用 |
  | 升級 / 回滾 | `dnf install` / `dnf downgrade` | 解壓新版到另一個目錄 → 切換 `current`；回滾就是把 symlink 切回舊版 |
  | 防止誤升級 | `dnf versionlock` | 不受 OS 套件管理影響；切換版本只能透過 `cpctl upgrade` |
  | C3 前置套件 | yum | 仍從內部 OS 相依 repo 安裝（cyrus-sasl、openssl-devel） |

  **tar 策略實測結果**（2026-10-14）：
  - 安裝 8.2.4：34/34 驗證通過；以 `install --force` 重跑一次，結果 **changed=0**。
  - 演練順序：8.2.4 → 8.3.2 → 回滾 8.2.4 → 8.3.2 → finalize。全程有持續流量，SCRAM 寫入 5,320 筆、**0 筆遺失**，REST 0 失敗。
  - 回滾約 3.5 分鐘（RPM 的 `dnf downgrade` 約 8 分鐘），因為舊版目錄還在，只要切換 symlink 再重啟。
  - **磁碟規劃**：
    - 每個版本目錄約 1.6–1.8GB，多個版本會並存。
    - 下載的壓縮檔快取在 `/var/cache/cp-installer`，每台約 2.7GB。
    - 正式環境請預留空間，或在 finalize 之後手動清除舊版目錄與快取。
- **內部 repo 的實作可替換**：安裝只依賴標準 yum `baseurl`。行內若有 Satellite、Artifactory 或 Nexus，只要換掉 `lib/repo/` 的匯入 adapter 並修改 `REPO_*_BASEURL`。若行內沒有任何制品庫，就用 `local`，由操作機自己提供 repo。
- **舊版本一律保留**：`dnf downgrade` 回滾需要舊版套件，而且 Confluent 會把 EOL 版本從官方 repo 移除。
- **稽核軌跡**：每次匯入都把 `SHA256SUMS`、`manifest-rpm.json`、驗證報告保存在 `/srv/repo/manifests/<時間>/`。

## cpctl 指令

| 指令 | 說明 |
|---|---|
| `cpctl install [--from NN]` | 依序執行步驟 00–10；失敗修正後可從失敗的步驟續跑 |
| `cpctl step NN_name` | 只執行單一步驟 |
| `cpctl install --check --diff` | 乾跑：列出會變更的項目與設定差異（密碼遮罩），不做任何變更 |
| `cpctl verify` / `cpctl status` | 端到端驗證 / 各步驟最後成功時間與服務狀態 |
| `cpctl upgrade plan\|backup\|stage\|rolling\|finalize\|rollback --to <ver>` | 滾動升級（見下方 SOP） |
| `cpctl controller replace --old kc03 --host kc04` | 動態 quorum 成員替換 |
| `cpctl certs status` | 憑證到期日，以及各服務**目前實際出示**的憑證序號 |
| `cpctl certs rotate [--cert a,b\|all]` | 重簽 leaf 憑證（預設 kafka-internal、cp-server），滾動重啟 |
| `cpctl certs rotate-ca --phase add\|switch\|retire` | 不停機的 CA 輪替（分三次執行） |
| `cpctl certs trust list\|add <root.pem>\|remove <名稱>\|internal` | 銀行 CA 的信任錨點（`PKI_MODE=external`）；`remove internal` 移除自建 CA |
| `cpctl license status` | 生效中的 license（檔案或試用）、到期日、剩餘天數 |
| `cpctl monitoring export\|check` | 產生給行內 Prometheus 的 scrape 設定與告警規則 / 檢查所有 exporter |
| `cpctl uninstall --yes-really` | 移除套件、設定與資料；保留內部 repo、PKI、AD 帳號 |

步驟：`00 precheck` → `01 os_baseline` → `02 distribute`（RPM）→ `03 pki` → `04 ad_bootstrap` → `05 configure` → `06 kraft_format`（`--initial-controllers` 動態 quorum）→ `07 start_core` → `08 security_bootstrap`（SCRAM、RBAC、topic）→ `09 start_edge`（REST、C3、LB）→ `10 verify` → `11 opmenu`（堡壘機的維運選單；`OPMENU=off` 時略過）。

### 冪等性

- 所有變更都經過 `ensure::*`：先比較目前狀態，一致就報 `ok`，不一致才動作並報 `changed`（設定檔以 sha256 比對，覆蓋前保留 `.bak.<時間>`）。
- 設定有變時只通知 handler，之後逐台重啟並通過健康檢查（health gate）才處理下一台。待重啟清單保存在 `state/handlers.pending`，中斷後不會遺失。
- 驗收結果：在已安裝的環境再跑一次 `cpctl install --force` 得到 **changed=0**（993 ok、0 failed，含 48 項 verify；2026-10-16，含堡壘機與 OP menu）。
- 程式規則：禁止 `指令 | grep -q`（pipefail 下 grep 提早結束會讓前段收到 SIGPIPE 而隨機誤判），一律寫成 `grep -q 樣式 <<<"$(指令)"`；`tools/lint.sh` 會擋下違規。精簡 OS 沒有 diffutils，檔案比對一律用 sha256。

## 正式營運需要的設定（對照官方文件補齊）

| 項目 | 做法 | 驗證 |
|---|---|---|
| Secret Protection | 所有 `.properties` 的密碼（含 JAAS 內的 password）以 `confluent secret file encrypt` 加密成 `${securepass:...}`；master key 只存在操作機（0600）與各節點 root-only 的 `service.env` | 全節點掃描 0 筆明文密碼；重跑 changed=0 |
| MDS token 私鑰 | 節點只拿到 PKCS#8 AES-256 加密版，passphrase 本身也經 Secret Protection | 舊的明文私鑰會被自動移除 |
| 憑證輪替 | leaf：`certs rotate`；CA：三階段（add → switch → retire），過程中所有節點同時信任新舊 CA；JDK / OS trust store 依 bundle 指紋同步 | 2026-10-17 以修正後的負載工具量測：銀行 root 三階段輪替（cpctl）**4,530 筆 0 遺失、REST 817 次 0 失敗**；手動程序的結果與重新核對見手冊附錄 A.3、A.4（舊版負載報告無法區分各次執行，早先的數字不再引用） |
| 銀行 CA | `PKI_MODE=external`：CSR 交銀行簽、回覆經檢查才匯入（缺 clientAuth、缺中繼、SAN 不符、私鑰不符都拒絕且什麼都不換）；`.crt` / `.p12` 帶中繼 CA；信任錨點 `cpctl certs trust` | cp-poc 自建 CA → 銀行 CA 三階段遷移；銀行換 root（G1 → G2）三階段：4,530 筆 0 遺失、REST 817 次 0 失敗；舊 CA 簽的憑證被拒（exit 56） |
| License 監控 | 從 `conf/license.txt` 或 `_confluent-command` 讀 JWT 解出到期日；30 天內警告、過期即 verify 失敗 | `cpctl license status` |
| Log 保留 | log4j2 只輪替不刪除 → `systemd-tmpfiles` 每日刪除 `LOG_RETENTION_DAYS`（預設 14 天）前的檔案；journald 上限 1G | step 01 |
| LDAP 韌性 | 多台 AD（`AD_LDAP_HOSTS`）、連線逾時 3 秒、群組快取 60 秒更新，AD 中斷時沿用快取最長 24 小時 | 憑證輪替時 Samba 重啟，登入不中斷 |
| Telemetry | `confluent.telemetry.enabled=false`（不送 Confluent Cloud / Health+）；只保留送往 C3 Prometheus 的 `_c3` exporter | — |
| **稽核日誌** | 專用低權限 SCRAM 帳號 `confluent-audit`（只有稽核 topic 的 DeveloperWrite/Manage），不使用 broker 身分；`payments.*` 的 produce/consume（允許＋拒絕）與**被拒絕的 describe** 導向 `confluent-audit-log-events_sensitive`（保留 365 天），其餘 90 天；排除 `kafka-internal`、`svc-c3` 的雜訊（`conf/audit.env`） | verify：alice 的允許事件、app-orders 的拒絕事件都已進入敏感稽核 topic |
| **外部監控** | Prometheus JMX exporter（javaagent，**同樣經離線引進流程**：下載機驗 sha1 → SHA256SUMS → repo import → SSH 派送）；HTTPS（節點憑證）＋ basic auth（加鹽 SHA-256，節點上沒有明文密碼）；`cpctl monitoring export` 產出 scrape 設定、9 條告警規則、CA bundle 給行內 Prometheus | 9 個 exporter 皆需認證、可抓取；以 C3 附的 Prometheus 載入匯出檔實測：9/9 target up、9 條規則全部 ok |
| **OS 層** | THP=never（`disable-thp.service`，容器內由 systemd 自動略過）；chrony 指向 `NTP_SERVERS`（PoC 由 ops01 提供時間）；firewalld 依角色只開必要 port＋ssh，關閉預設的 cockpit / dhcpv6-client；SELinux 檢查 enforcing 並對自訂路徑 restorecon。chrony、firewalld 由內部 os-deps repo 安裝 | 不在清單上的 port 被擋、ssh 正常；第二次執行全部 ok |

## 日常維運：堡壘機上的 OP menu（固定帳號情境）

客戶情境：堡壘機與各主機**都不接 AD、只有固定帳號**。設計原則是「作業系統帳號只管連線，身分一律用 AD」：

| 工作 | 工具 | 執行帳號 | 誰能做 |
|---|---|---|---|
| 平台變更（安裝、升級、憑證輪替、controller 替換） | cpctl（操作機） | `cpadmin`（只給 cpctl，金鑰登入） | 平台工程師，變更時段 |
| 日常維運（查看、重啟、日誌、topic 與權限作業） | OP menu（堡壘機） | 堡壘機 `opuser` → 各主機 `kafkaops` | 依 AD 群組（Kafka RBAC） |
| 緊急處理（item 91） | OP menu → `opmenu-bootstrap` | `opbootstrap` 保管的 `opmenu-breakglass` 憑證 | 有權限的人，必填原因，記為 EMERGENCY |

| 帳號 | 在哪 | 限制 |
|---|---|---|
| `opuser` | 堡壘機 | 登入殼層就是選單；sshd `ForceCommand`，不能轉埠、不能 scp；選單內以**本人 AD 帳密**登入（`OPMENU_USER_FROM_OS=0`） |
| `opbootstrap` | 堡壘機 | nologin；保管緊急用憑證，`opuser` 只能經 sudo 執行包裝腳本，讀不到私鑰 |
| `kafkaops` | 每台 controller / broker / REST / C3 | 只接受**來自堡壘機 IP** 的 `opuser` 金鑰；金鑰檔屬 root，帳號不能自行加 key；sudo 只能重啟**自己那台**的服務、`journalctl`（NOEXEC）、清理日誌腳本 |

**為什麼共用帳號也能追溯與控管**
- Kafka 動作：用本人 AD 帳密走 LDAP listener，RBAC 依 AD 群組決定；選單紀錄與 Kafka 稽核日誌都是本人。
- 主機動作：碰 node 之前，選單以本人 token 呼叫 MDS `PUT /security/1.0/authorize`（預設要求叢集層級的 Topic Describe，即 Operator 以上）。MDS 會展開 AD 群組，而且只能問自己。
- 紀錄同時送 syslog（共用帳號改得到本機檔案，改不到 SIEM）。

**部署（離線引進）**：`windows/package-opmenu.sh` 打包 `opmenu/` → `packages/tools/opmenu-<日期>.<sha8>.tar.gz`（版本由內容決定，內容不同就不會覆蓋）→ `verify-packages.sh` → `cpctl repo import` → `cpctl step 11_opmenu`。版本切換是 `/opt/opmenu` symlink，舊版保留可切回。

**對 opmenu 的修補（2026-10-16，原始專案同步修改）**：主機類動作的權限閘門；item 21（重啟單一 broker）的前置檢查失敗時拒絕（原本會放行）。

## 升級 SOP（依 CP 8.3 官方文件：broker 先、controller 後）

```bash
cpctl upgrade plan     --to 8.3.2   # 檢查升級路徑、C3/JDK 相容性、repo 是否已有目標版本、禁用設定、叢集健康、憑證效期
cpctl upgrade backup   --to 8.3.2   # 備份 /etc/confluent、systemd drop-in、topic/ACL/SCRAM/feature 清單、RBAC 綁定
cpctl upgrade stage    --to 8.3.2   # 以新版模板產生設定並顯示差異（不變更）
cpctl upgrade rolling  --to 8.3.2   # broker 逐台 → controller（follower 先、leader 最後）→ REST（先從 LB 排空）
cpctl upgrade rollback --to 8.2.4   # finalize 之前都可回滾（dnf downgrade）
cpctl upgrade finalize --to 8.3.2   # kafka-features upgrade --release-version，之後不可回滾，需輸入 cluster id 確認
```

## 從 PoC 移到正式環境的差異

| 項目 | PoC | 正式環境 |
|---|---|---|
| sudo | cpadmin 擁有完整 NOPASSWD sudo | 依 `conf/sudoers.d/cpadmin.restricted` 由資安審核後收斂 |
| AD | Samba 模擬，由 cpctl 建立帳號 | `PROFILE=prod`：由 AD 團隊依申請單建立，cpctl 只檢查 |
| 憑證 | `PKI_MODE=external`：模擬銀行 CA（`windows/bank-ca.sh`，root + 中繼）簽發；cp-poc 已由自建 CA 不停機遷移過來 | 同一流程，銀行實際簽發：cpctl 產生私鑰 + CSR + 申請單（`pki/requests/`），銀行回覆放 `pki/incoming/`，檢查 key、CN、SAN、EKU、效期、憑證鏈後才換上；truststore 只放銀行 root（手冊 3.4.9、9.4、9.5） |
| heap / retention | `PROFILE=poc` 數值 | `PROFILE=prod`（官方建議值） |
| 核心參數 | vm.* 等只能在 WSL2 主機設定（腳本會警告）；容器重開後 net.* 會回到預設值，下一次 cpctl 會偵測並修正（2026-10-16 實測：4 台 broker 各 2 項） | 腳本直接寫入 `/etc/sysctl.d`，開機自動套用 |
| THP / SELinux | 容器共用 WSL2 核心：THP 只回報、SELinux 不存在 → `skipped` | `disable-thp.service` 生效；SELinux enforcing＋restorecon |
| 時間同步 | chrony 以 `-x` 執行（只跟隨不調整共用時鐘），ops01 當 NTP 來源 | `NTP_SERVERS` 改為行內 NTP，移除 `-x` |
| 防火牆 | firewalld 只作用在各容器自己的網路命名空間 | 依實際網段與行內網路防火牆政策調整，或 `FIREWALLD=off` |
| 內部 repo 傳輸 | HTTP（RPM 有 gpgcheck，其餘檔案有 sha256） | 建議改用 HTTPS |
| License | 未設定，以評估模式執行 | 放入 `conf/license.txt` |

## 已知限制與風險

- `kafka-internal` 憑證由所有 controller 和 broker 共用，而且是 super user：任何一台的私鑰外洩，等於整個叢集被取得。緩解方式：私鑰權限 0640、以 `cpctl certs rotate` 定期（或事故時立即）輪替；正式環境也可以改成每台各自一張憑證。
- JMX exporter 的 keystore 密碼必須以明文寫在 exporter 的 YAML（0640 root:confluent；YAML 不支援 Secret Protection）。scrape 密碼則只存雜湊。
- Confluent Server 不以 JMX 提供 raft 指標；controller quorum 健康以 `ActiveControllerCount` 告警，詳細狀態用 `cpctl verify`。consumer lag 不是 broker JMX 指標，由 C3 顯示（或另接 lag exporter）。
- svc-cpctl 是安裝用的 bootstrap 帳號，列在 `super.users` 中；安裝完成後建議停用，需要時再由 break-glass 程序啟用。
- 在 Docker Desktop 上，從 Windows 發出的請求來源 IP 都相同，LB 的 source-hash 黏著會把它們全部送到同一台 REST Proxy；負載分散要從 cpnet 內的不同來源驗證。
- **整個環境冷開機**（例如停電後所有主機同時開機）：C3 若比 MDS 先啟動，會卡在「client has already been closed」且不開 9021（2026-10-16 實測）。已在 C3 的 systemd drop-in 加上啟動前等待 MDS（最多 5 分鐘，逾時仍會啟動）。正式環境的開機順序建議仍是 controller → broker → REST / C3。
- 模擬環境用 `bash windows/poc.sh start` 啟動時會帶 `spare` profile：controller 替換演練後 kc04 是正式 voter，少了它 quorum 只剩兩台。
