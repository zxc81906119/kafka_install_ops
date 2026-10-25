# Confluent Platform 8.3 企業版 — 銀行離線安裝 PoC

在完全離線的銀行環境安裝 Confluent Platform 企業版的**手動程序**，以及照同一條路寫成的安裝腳本。lab 在 Windows 11 的 Docker Desktop 上以容器模擬 RHEL 9 主機與銀行各團隊（AD、CA、套件庫、CyberArk PVWA），從零自建、照手冊逐章實跑驗證。

| 元件 | 版本 | 數量 |
|---|---|---|
| Confluent Platform（Confluent Server，KRaft） | 8.3.2（升級演練起點 8.2.4） | controller ×3、broker ×4 |
| REST Proxy | 8.3.2 | ×2，前置 L4 負載平衡 |
| Control Center（內建 Prometheus／Alertmanager） | 2.6.1 | ×1 |
| JDK | 21（銀行以 tar 提供，裝到 `/opt/java/<dir>` + `/opt/java/current`） | 所有 Java 節點 |

## 文件

| 文件 | 給誰 | 來源 |
|---|---|---|
| `docs/Confluent-安裝旅程-手把手.docx` | 安裝工程師：每一步誰做、在哪台、敲什麼、看到什麼（第 0–28 章） | `docs/journey-src/journey.md`（`node build.js`） |
| `docs/Confluent-請銀行確認的事項.docx` | 銀行各團隊：待確認事項與我方預設 | `docs/questions-src/questions.md`（`node build.js`） |
| `docs/Confluent-RPM安裝流程.pptx` | 銀行主管：RPM 安裝流程 14 頁 | `docs/deck-src/install.js`、`install-steps.js` |
| `redesign/README.md` | 設計決策、教訓、待確認事項的紀錄 | 手寫 |

## 主機（`<主機>.poc.lab`）

| 主機 | 用途 | 誰管 |
|---|---|---|
| dl01 | 外網下載機，唯一能連 Internet | 我方 |
| ops02 | 操作機：安裝與維運的起點，也是維運人員（經 PSMP）登入、跑 OP menu 的地方 | 我方（帳號 cpadmin） |
| kc01–kc03 | KRaft controller | 我方安裝，銀行提供主機 |
| kb01–kb04 | broker（含 MDS） | 同上 |
| rest01、rest02 | REST Proxy | 同上 |
| c3-01 | Control Center | 同上 |
| repo01 | 行內套件庫 web server（lab 兼 NTP） | 銀行 |
| ad01 | 行內 AD（lab 用 Samba） | 銀行 |
| lb01 | 負載平衡（lab 用 nginx） | 銀行 |
| PVWA | CyberArk PAM：密碼、金鑰的正本，人工取放（lab 用 `~/kafka-lab/pvwa/` 資料夾模擬） | 銀行 Secrets 團隊 |

## 手冊的三種模式

主線是本案客戶的情境；選配段落在 `journey.md` 以 `@only` 標示，docx 裡印成紫色「◆ 這一段只在：…」。

| 模式 | 銀行的 CyberArk | 平台密碼怎麼放 |
|---|---|---|
| `customer`（主線） | 只有 PAM（PVWA、PSMP、SSH Key Manager、CPM） | Secret Protection 加密落地；master key、passphrase 正本在 PVWA；cpadmin 私鑰從 PVWA 貼進 ssh-agent，不落地 |
| `conjur` | PAM + Conjur | Secret Protection；master key 經 Summon 啟動時取（16.8）；AD 查詢密碼注入（16.9） |
| `provider` | PAM + Conjur | Conjur config provider（第 15 站），properties 只留參照 |

## 目錄

```
docs/journey-src/   手把手來源 journey.md、圖 diagrams.js、build.js；tools/run-chapter.js（依模式抽出指令塊）、
                    tools/run-full.sh（在 lab 照文件實跑）、tools/scan-log.sh（找 rc=0 但其實失敗的輸出）
docs/questions-src/ 請銀行確認的事項（questions.md → build.js）
docs/deck-src/      RPM 安裝流程簡報
install/            照手冊一章一支的安裝腳本（install.sh、steps/01–27、conf/site.env），說明見 install/README.md
                    install/lab/：lab 專用（bank-sim.sh 扮演銀行、run-customer.sh／run-all.sh 從零跑、升級演練）
opmenu/             維運選單（OP menu）原始碼；經離線引進流程送進操作機（手把手第 17 章）
redesign/           設計討論紀錄
```

## lab

- 照手把手第 0 章在 `~/kafka-lab/` 自建（compose 專案 `lab`，14 台容器 + 下載機 `dl01`）。不依賴本 repo 的任何檔案。
- 照文件實跑：`bash docs/journey-src/tools/run-full.sh <customer|conjur|provider> [起始章] [結束章]`（從第 0 章開始會先拆掉整個 lab，只留落地區）。
- 照腳本實跑：`bash install/lab/run-customer.sh`（客戶模式）、`EXT=1 bash install/lab/run-all.sh`（Conjur 模式）、`bash install/lab/run-upgrade-drill.sh`（從 8.2.4 升級）。

## 日常維運：操作機上的 OP menu

**操作機（ops02）同時是維運人員的登入點**；完整程序見手把手第 17 章。原則是「作業系統帳號只管連線，身分一律用 AD」：

| 工作 | 工具 | 執行帳號 | 誰能做 |
|---|---|---|---|
| 平台變更（安裝、升級、憑證輪替、controller 替換） | 操作機上的手動程序（或 `install/` 腳本） | `cpadmin`（私鑰正本在 PVWA，只放進 ssh-agent） | 平台工程師，變更時段 |
| 日常維運（查看、重啟、日誌、topic 與權限作業） | OP menu（操作機） | 維運人員的本機帳號（經 PSMP 登入）；碰主機時用 cpadmin 金鑰，從 PVWA 取出貼進選單自己的 ssh-agent，結束即清除 | 依 AD 群組（Kafka RBAC） |
| 緊急處理 | OP menu 緊急模式 | `opmenu-breakglass` 憑證（正本在 PVWA） | 有權限的人，必填原因，記為 EMERGENCY |

- SSH 金鑰只有 cpadmin 一組；主機上的公鑰可加 `from="操作機 IP"`、`restrict`，指令範圍由 sudoers 收窄（交付後只留 `cpadmin-ops` 窄規則）。
- Kafka 動作用本人 AD 帳密走 LDAP listener；碰主機之前，選單以本人 token 呼叫 MDS `PUT /security/1.0/authorize` 確認權限。選單紀錄與 Kafka 稽核日誌記的都是本人，紀錄同時送 syslog。
- 選單取私鑰的來源由 `OPMENU_SECRETS` 決定：本案只有 PVWA，用 `manual`；銀行有 Conjur 時用 `conjur`。

## 已知限制

- Confluent Server 不以 JMX 提供 raft 指標（2026-10-25 在 8.3.2 的 controller 列出全部 MBean 確認）；raft 指標只在 Confluent telemetry 裡，送進 C3 內建 Prometheus 時沒有主機標籤、多台會互撞，不適合告警。手把手第 18 章改用 controller 的 `LastAppliedRecordLagMs`、`MetadataErrorCount`、`NewActiveControllersCount`、`ActiveControllerCount` 告警。consumer lag 由 C3 顯示。
- CyberArk PAM 本身（PVWA 取用核准、CPM 排程、PSMP 代登與錄影、SSH Key Manager 推送）無法在 lab 模擬，只驗證我方拿到值之後的程序；Conjur 用的是 Conjur OSS。
- MDS token 金鑰不排輪替（公鑰檔放兩把沒有用，無法零中斷切換）；只在私鑰外洩時用 `install/lab/mds-token-key-rotate.sh` 驗過的程序換。
