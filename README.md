# Confluent Platform 企業版 — 銀行離線安裝與遷移 PoC（8.2 → 8.3）

在完全離線的銀行環境安裝 Confluent Platform 企業版、再遷移到新版的**手動程序**，以及照同一條路寫成的安裝腳本。主線是「先裝**安裝基底**，再**遷移**到目標版本」：lab 在 Windows 11 的 Podman（WSL2 上的 rootful machine）以容器模擬 RHEL 9 主機與銀行各團隊（AD、CA、套件庫、CyberArk PVWA），從零自建、照手冊逐章實跑驗證。

| 元件 | 安裝基底（第 2–19 章） | 遷移目標（第 29、30、31 章） | 數量 |
|---|---|---|---|
| Confluent Platform（Confluent Server，KRaft） | 8.2.4 | 8.3.2 | controller ×3、broker ×4 |
| REST Proxy | 8.2.4 | 8.3.2 | ×2，前置 L4 負載平衡 |
| Control Center（內建 Prometheus／Alertmanager，只供 C3 畫面用） | 2.5.1 | 2.6.1 | ×1 |
| 監控：JMX exporter（4 種程序）＋ 銀行的 Prometheus、Alertmanager、Grafana | exporter 1.7.0（GitHub release，sha256＋GPG 核對）；Confluent 官方 jmx-monitoring-stacks 固定 commit | 同左 | 我方交付設定，銀行提供三套系統 |
| JDK（銀行以 tar 提供，裝到 `/opt/java/<dir>` + `/opt/java/current`） | 21 | 25（8.2.x 不支援 Java 25，所以基底只能是 21；8.3.x 支援 25，原廠建議版本仍是 21） | 所有 Java 節點（含 C3） |
| 作業系統（RHEL 9） | 9.6 | 9.8（小版本更新） | 所有主機 |

C3 的版本由原廠相容表決定：2.5.x 支援 CP 到 8.2.x，2.6.x 支援到 8.3.x，所以 CP 升 8.3 之前 C3 先升到 2.6.1。lab 的主機是 Rocky 9（vault 的 9.6 → 現行的 9.8），不是 RHEL，容器不能真的重開機。

## 文件

| 文件 | 給誰 | 來源 |
|---|---|---|
| `docs/Confluent-安裝旅程-手把手.docx` | 安裝工程師：每一步誰做、在哪台、敲什麼、看到什麼（第 0 章建 lab、第 1–32 章、附錄 B 監控覆蓋率；基底 → 遷移） | `docs/journey-src/journey.md`（`node build.js`） |
| `docs/Confluent-請銀行確認的事項.docx` | 銀行各團隊：待確認事項與我方預設 | `docs/questions-src/questions.md`（`node build.js`） |
| `docs/Confluent-RPM安裝流程.pptx` | 銀行主管：RPM 安裝流程 14 頁 | `docs/deck-src/install.js`、`install-steps.js` |
| `redesign/README.md` | 設計決策、教訓、待確認事項的紀錄 | 手寫 |

## 主機（`<主機>.poc.lab`）

| 主機 | 用途 | 誰管 |
|---|---|---|
| dl01 | 外網下載機，唯一能連 Internet | 我方 |
| ops02 | 操作機：安裝與維運的起點，也是維運人員登入、跑 OP menu 的地方。人員在 CyberArk 的 PVWA 網頁登入（AD 帳密＋MFA），由 PSMP 代登進來，**進去是 root**；連其他主機一律用 `cpuser` 與一把金鑰 | 我方（root；連主機用 cpuser） |
| kc01–kc03 | KRaft controller | 我方安裝，銀行提供主機 |
| kb01–kb04 | broker（含 MDS） | 同上 |
| rest01、rest02 | REST Proxy | 同上 |
| c3-01 | Control Center | 同上 |
| repo01 | 行內套件庫 web server（lab 兼 NTP） | 銀行 |
| ad01 | 行內 AD（lab 用 Samba） | 銀行 |
| lb01 | 負載平衡（lab 用 nginx） | 銀行 |
| PVWA、PSMP | CyberArk PAM：人員在 PVWA 網頁登入（AD 帳密＋MFA），由 PSMP 代登進操作機成為 root。這是平台和 CyberArk **唯一**的關係；平台的密碼與金鑰不放 CyberArk（lab 無法模擬登入，直接 `podman exec` 以 root 進） | 銀行 Secrets 團隊 |

## 手冊只有一種模式：客戶情境

Kafka 平台和銀行的 CyberArk 已脫鉤（2026-10-28 定案）：只剩「人員經 PVWA＋PSMP 登入操作機」這一件事；平台的密碼與金鑰不放 CyberArk，也沒有 CPM 自動輪替。應用面（Conjur、Summon、CCP／CP）完全沒用，2026-10-27 起手冊與腳本都已刪除這些選配。

| 項目 | 做法 |
|---|---|
| 平台密碼與金鑰 | Secret Protection 加密落地；passphrase、master key、SCRAM、緊急憑證等全部只放操作機 root 才讀得到的位置（`~/secrets`、`~/pki`，0600）；操作機的備份由銀行的備份機制處理並加密 |
| 人員進操作機 | PVWA 網頁登入（AD 帳密＋MFA）→ PSMP 代登 → root；沒有另外的堡壘機 |
| ssh 私鑰 | 一組 ed25519，放操作機獨立加密 file system `/secure/ssh`（root、0400）；不放 CyberArk、不備份；操作機重建就重新產生，OS 團隊重新佈署公鑰 |
| 各主機的 user | 每台（含操作機）本機帳號 `cpuser`（UID／GID 1500、鎖定密碼、只收金鑰）；公鑰只加 `from=` |
| root、`svc-mds-bind` | 人手動輪替（root 由銀行管；`svc-mds-bind` 換完要通知平台更新密文、滾動重啟） |

## 目錄

```
docs/journey-src/   手把手來源 journey.md、圖 diagrams.js、build.js；tools/run-chapter.js（抽出指令塊）、
                    tools/run-full.sh（在 lab 照文件實跑）、tools/scan-log.sh（找 rc=0 但其實失敗的輸出）
docs/questions-src/ 請銀行確認的事項（questions.md → build.js）
docs/deck-src/      RPM 安裝流程簡報
install/            照手冊一章一支的安裝腳本（install.sh、steps/02–32（檔名照章號；第 7、25 章各拆成 07-1/2/3、25-1/2）、conf/site.env），說明見 install/README.md
                    install/lab/：lab 專用（bank-sim.sh 扮演銀行、run-customer.sh 從零跑整條主線＝基底＋遷移）
opmenu/             維運選單（OP menu）原始碼；經離線引進流程送進操作機（手把手第 16 章）
redesign/           設計討論紀錄
```

## lab

- 照手把手第 0 章在 `~/kafka-lab/` 自建（compose 專案 `lab`，14 台容器 + 下載機 `dl01`）。不依賴本 repo 的任何檔案。
- 照文件實跑：`bash docs/journey-src/tools/run-full.sh customer [起始章] [結束章]`（從第 0 章開始會先拆掉整個 lab，只留落地區 `~/kafka-lab/landing`〔`rpm/` = 基底、`rpm-target/` = 目標、`bank/` = 兩個 JDK〕和 OS 內容的下載快取 `bank-os/`）。
- 照腳本實跑：`bash install/lab/run-customer.sh`（從零跑整條主線：裝 8.2.4／9.6、驗收、遷移到 8.3.2／JDK 25、OS 更新到 9.8、再驗收；升級不再是另一個演練）。

## 日常維運：操作機上的 OP menu

**操作機（ops02）同時是維運人員的登入點**；完整程序見手把手第 16 章。原則是「作業系統帳號只管連線，身分一律用 AD」：

| 工作 | 工具 | 執行帳號 | 誰能做 |
|---|---|---|---|
| 平台變更（安裝、升級、憑證輪替、controller 替換） | 操作機上的手動程序（或 `install/` 腳本） | 操作機 root，連各主機用 `cpuser`（安裝與升級期 sudo 全權） | 平台工程師，變更時段 |
| 日常維運（查看、重啟、日誌、topic 與權限作業） | OP menu（操作機） | 操作機 root（經 PVWA＋PSMP 登入）；碰主機時用 `/secure/ssh` 的同一把金鑰以 cpuser ssh，sudo 只開逐一列出的寫法 | 依 AD 群組（Kafka RBAC） |
| 緊急處理 | OP menu 緊急模式 | `svc-ops` 憑證（操作機 `~/secrets/svc-ops.pem`，root 0600） | 有權限的人，必填原因，記為 EMERGENCY |

- SSH 金鑰只有一組（cpuser）；主機上的公鑰只加 `from="操作機 IP,127.0.0.1,::1"`，指令範圍由 sudoers 收窄（交付後只留 `cpuser-ops`：每個服務、每種指令寫法逐一列出，不用 `confluent-*` 萬用字元，因為 sudoers 比對完整參數）。
- Kafka 動作用本人 AD 帳密走 LDAP listener；碰主機之前，選單以本人 token 呼叫 MDS `PUT /security/1.0/authorize` 確認權限。選單紀錄與 Kafka 稽核日誌記的都是本人，紀錄同時送 syslog。
- 操作者在操作機上是 root，所以選單「碰主機前先問 MDS」是流程控管、不是硬性隔離；追溯靠 CyberArk 登入紀錄與 PSMP 錄影。Kafka 動作的權限與稽核由 Kafka 端依本人 AD 身分強制，繞不過。緊急憑證（91）直接讀操作機上的檔，把關是必填原因與 EMERGENCY 稽核記錄。

## 已知限制

- 監控（手把手第 17 章）：告警與 dashboard 只走銀行的 Prometheus／Alertmanager／Grafana；C3 內建的 Prometheus／Alertmanager 不動，也不在 C3 建 alert trigger／action。Confluent Server 的 raft 指標（`kafka_server_raft_metrics_*`）只有單台 controller 的環境抓得到；三台 controller 的叢集（8.2.4 與遷移後的 8.3.2 都實測）一條都沒有，所以不能用來告警，quorum 健康改用 `ActiveControllerCount`、`LastAppliedRecordLagMs`、`MetadataErrorCount`；官方 `kraft.json` dashboard 在三台 controller 叢集只有 10／18 個 panel 有值（靠 raft 指標的是空的）。另外官方 dashboard 有幾個 panel 在專用 controller 的 KRaft 叢集是空的（見手把手 B.1 與 redesign/README.md）。consumer lag 由 C3 畫面顯示，不是 broker 的 JMX 指標。第 17 章已在完整 lab 從零跑過（2026-10-30，手冊第 0 章到附錄 B 全部照打實跑）。
- CyberArk PAM 本身（PVWA 登入、PSMP 代登與錄影）與放私鑰的加密 file system（LUKS）無法在 lab 模擬：lab 直接以 root 進操作機，`/secure/ssh` 用獨立的 podman volume 代替（獨立掛載點，沒有加密）；只驗證我方拿到值之後的程序。
- MDS token 金鑰不排輪替（公鑰檔放兩把沒有用，無法零中斷切換）；只在私鑰外洩時用 `install/lab/mds-token-key-rotate.sh` 驗過的程序換。
