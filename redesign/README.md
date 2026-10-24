# 安裝流程重新設計（討論紀錄）

從下載到交付，一項一項討論：每一項記錄「要做什麼／誰做／怎麼確認／對應」。
討論以使用者說明為主；這份文件只記錄已確認的決定與待確認的問題，不放未經討論的方案。

## 流程總表

| # | 階段 | 項目 | 狀態 |
|---|---|---|---|
| 1 | 外網 | 下載套件 | 討論中 |
| 2 | 外網 | 驗證（雜湊、簽章） | |
| 3 | 外網 | 產生交付目錄 | |
| 4 | 引進 | 掃描平台、開單 | |
| 5 | 引進 | 搬進內網 | |
| 6 | 引進 | 上架內部套件庫 | |
| 7 | 行內準備 | 主機、OS、DNS、NTP、OS 套件來源 | |
| 8 | 行內準備 | JDK 21 | |
| 9 | 行內準備 | AD 群組與查詢帳號 | |
| 10 | 行內準備 | 負載平衡、網路防火牆 | |
| 11 | 行內準備 | 安裝帳號、SSH、sudo 開放時段 | 已整理（CyberArk） |
| 12 | 憑證 | 申請（CSR）、銀行 CA 簽發、匯入檢查 | |
| 13 | 安裝 | 安裝前檢查 | |
| 14 | 安裝 | OS 調校 | |
| 15 | 安裝 | 安裝套件 | |
| 16 | 安裝 | 派送憑證、產生設定 | |
| 17 | 安裝 | 初始化、啟動 controller 與 broker | |
| 18 | 安裝 | SCRAM 帳號、RBAC、topic | |
| 19 | 安裝 | 啟動 REST Proxy、C3 | |
| 20 | 安裝 | OP 選單 | 不納入這次流程（2026-10-20 決定） |
| 21 | 驗收 | 端對端驗收 | |
| 22 | 收尾 | 移交、收回 sudo、文件 | |

維運（升級、換憑證、擴充、移除）在安裝流程之後討論。lab 模擬環境暫不討論。

---

## 1. 下載套件

### 已確認

| 項目 | 決定 |
|---|---|
| Confluent 套件 | RPM 格式（不用 tar.gz） |
| 非 RPM 檔案（JMX exporter jar、OP 選單 tar.gz） | 維持原格式 |
| JDK | 不在我們的下載與交付範圍，由客戶安裝（RPM 或 tar 皆可） |
| 客戶對 JDK 要做的事 | 把 tar 交給我們（lab：放在操作機 `~/jdk/` 附 sha256）；主機上的安裝由我們做 |
| 安裝位置 | `/opt/java/<版本目錄>`，`JAVA_HOME=/opt/java/jdk-21.0.12.1+1` |
| 全域設定 | **用 alternatives** 登記 `java`、`keytool`（RHEL 標準做法，與 RPM 版 JDK 相容、OS 管理員熟悉）＋ `/etc/profile.d/java.sh` 設 `JAVA_HOME`；服務另在 systemd drop-in 明確寫 `JAVA_HOME` 鎖定版本 |

### 套件相依與分工（已確認）

| 類別 | 說明 | 誰準備 |
|---|---|---|
| A. Confluent 依賴 Confluent | RPM 宣告的相依，dnf 自動帶入（例：`confluent-server` → `confluent-telemetry`） | **我們帶入** |
| B. Confluent 依賴非 Confluent | RPM 宣告、來自 OS 的相依（`rpm -qpR` 查得只有 `/usr/bin/bash`、`confluent-cli` 需要的 glibc） | 客戶放入套件庫 |
| C. 官方文件要求、RPM 未宣告 | 原廠文件要求各主機安裝的 OS 套件（例：C3 的 `cyrus-sasl`、`openssl-devel`） | 客戶放入套件庫 |

- 範圍涵蓋 controller、broker、REST Proxy、C3，以及操作機。
- 我們帶入的只有 Confluent 相關套件；其他套件由客戶準備，放入行內某個套件庫，供之後安裝使用。
- 安裝時由我們用 dnf 一併安裝：
  - B 類：dnf 依 RPM 的 `Requires` 自動帶入，不必寫在指令裡。
  - C 類：RPM 沒宣告，dnf 不會自動帶，安裝指令必須明確列出（例：`dnf install confluent-control-center-next-gen cyrus-sasl openssl-devel`）。
- 前提：執行 dnf 時客戶的套件庫必須啟用。目前程式用 `--disablerepo='*' --enablerepo='cp-internal-*'` 會擋掉客戶套件庫，第 15 項要調整。

### JDK 相關說明（已確認的事實）

- 需要 JDK 21 的主機：controller、broker、REST Proxy、C3、操作機。套件 web server、負載平衡不需要。
- RPM 裝的 JDK 有 `/usr/bin/java`（alternatives），不設 `JAVA_HOME` 也找得到；tar 裝的必須告訴程式路徑。
- `JAVA_HOME` 要設在三個地方，各給不同對象：

| 設定 | 給誰用 | 主機 |
|---|---|---|
| `/etc/profile.d/java.sh`（`JAVA_HOME`、`PATH`） | 人登入後手動下指令 | 五種要裝 JDK 的主機 |
| systemd drop-in 的 `Environment=JAVA_HOME=…` | 服務（systemd 不讀 `/etc/profile.d`） | controller、broker、REST、C3 |
| 腳本與 OP 選單設定檔明確寫 `JAVA_HOME` | 自動化程式（ssh 執行的非登入 shell 不讀 `/etc/profile.d`） | 操作機 |

- 哪些情況讀得到 `/etc/profile.d`（RHEL 9）：login shell、interactive non-login（`/etc/bashrc` 補讀）、`ssh host 'cmd'`（sshd 啟動的 bash 讀 `~/.bashrc`）都讀得到；**systemd 服務、cron、sudo** 讀不到。`/usr/bin` 在所有情況的 PATH 裡，所以 alternatives（或 symlink）是唯一能涵蓋全部的方式；但服務仍在 unit 內明確寫 `JAVA_HOME`，避免 OS 團隊切換 alternatives 時服務跟著變。
- 2026-10-20 決定：改用 alternatives（原先「裝好即可、不設全域」的決定作廢）。

### 教訓（lab 實測）

- 給銀行的 OS 套件清單若用 `dnf download --resolve` 算，下載容器必須是乾淨的最小安裝，且**先下載、再安裝工具**：先裝了 `createrepo_c` 再下載，它的相依 `createrepo_c-libs` 就被當成已存在而漏掉（操作機安裝時才發現）。

### 影響（之後討論到時處理）

- 交付目錄、客戶主機準備清單：JDK 改為「客戶提供」。
- 安裝前檢查：確認每台的 `JAVA_HOME` 存在、版本為 21。
- 目前程式中的 tar 安裝方式、JDK 安裝與移除（`JDK_SOURCE`、`JDK_RETIRED`）在新設計中不需要。

---

## 11. 安裝帳號、SSH、sudo（行內有 CyberArk 的情況）

客戶有 CyberArk，分兩種用法：代登（PSMP）、用 SSH 定期換密碼（CPM）。套到我們的流程會是這樣：

### 1. 操作人員用 CyberArk 代登進操作機

- 操作人員用自己的 AD 帳號登入 CyberArk。
- CyberArk（PSMP）代登進操作機，身分是 cpadmin（安裝用帳號），全程錄影。
- 人不會知道 cpadmin 的密碼，也不用知道。

### 2. 操作機對各主機的 SSH 金鑰，交給 CyberArk 管

- 金鑰對由 CyberArk（CPM）產生，不是我們自己 `ssh-keygen`。私鑰只放 Vault。
- 公鑰由 CPM 自己 SSH 進每一台主機，寫進 cpadmin 的 `authorized_keys`（包含操作機自己，因為迴圈裡會 `ssh` 到自己）。輪替的時候也是它去換。
- 作業當天，人進操作機後到 PVWA 網頁取私鑰（要填變更單號，會留紀錄），放到操作機 cpadmin 的 `~/.ssh/` 底下，權限 0600。作業結束把副本刪掉。
- 行內如果願意在操作機裝 Credential Provider（CP agent），腳本可以直接跟 CyberArk 要私鑰，人就不用手動取。
- 2026-10-21 整理：私鑰怎麼到操作機有三種，CPM 只推公鑰、不會把私鑰放到操作機。
  A. 操作機裝 CP（或打 CCP）：腳本啟動時拉、用完丟，私鑰不落地（正式上線建議）。
     做法：`clipasswordsdk GetPassword … -o Password | ssh-add -`（CP）或 `curl --cert … AIMWebService/api/Accounts?AppID=…&Safe=…&Object=… | jq -r .Content | ssh-add -`（CCP），
     鑰匙只進 ssh-agent（可 `-t 4h`），作業結束 `ssh-agent -k`；第 3.1 站之後的 ssh／scp 指令都不用改。
  B. 操作機到各主機也走 PSMP：最乾淨，但 scp／批次 ssh 都要改寫，不建議。
  C. 人從 PVWA 取私鑰放 `~/.ssh`（上一點的作法）：和 lab 手動安裝完全相同（PoC 先用這個）。
  **2026-10-22 定案（客戶正式環境）：走 A 的 CCP 版**。操作機不裝 agent，安裝腳本開頭以 HTTPS 打 CCP（client 憑證＋來源 IP 驗身分）取 cpadmin 私鑰，直接 `ssh-add -` 進 ssh-agent，作業結束 `ssh-agent -k`。
  要請銀行準備：CCP 的 AppID（例如 confluent-ops，允許來源 = 操作機 IP、要求 client 憑證）、把 cpadmin 的 SSH key 帳號放進該 AppID 可讀的 safe、給操作機一張打 CCP 用的 client 憑證（可沿用 svc-ops 或另簽）。
  CCP 不需要 Conjur；Conjur 是 K8s／pipeline 用的另一條線。
  **2026-10-23 改定案：客戶沒有 CCP／CP**（CyberArk 只用在 PSM／PSMP 代登與 SSH 金鑰輪替，應用程式端完全沒用）。上面的 CCP 版不成立，改走 **C 的不落地版**：
  變更窗口內工程師經 PSMP 以 cpadmin 登入操作機，從 PVWA 取出「操作機 → 各主機」的 cpadmin 私鑰，直接貼進 ssh-agent（`eval $(ssh-agent -s); ssh-add -t 4h -`），
  不寫進 `~/.ssh`；作業結束 `ssh-agent -k`。輪替仍由 SSH Key Manager／CPM 負責（推公鑰到各主機）。安裝腳本開頭只確認 ssh-agent 裡有金鑰（`SSH_KEY_SOURCE=agent`）。
  維運期 OP menu 同一個做法：保管庫來源改 `lib/secrets/manual.sh`，選單登入後提示維運人員從 PVWA 取出私鑰貼上，只進選單自己的 ssh-agent，離開即清；緊急憑證（91）也是人工貼上。
  影響：第 16 站 master key 只能落地 `service.env`（16.4，人工從 PVWA 取），16.8 Summon、16.9 AD 密碼注入都不適用（`SUMMON=0`、`LDAP_PASSWORD_VIA_ENV=0`）；
  AD 查詢密碼、應用程式 SCRAM 密碼照銀行現行交付方式人工交付。
- 2026-10-22 原廠回覆「CCP 是 for Conjur」的釐清：Confluent 自家的 csid-secrets-providers 裡 CyberArk provider **只接 Conjur API**，不接 PAM 的 CCP。
  CCP 本身是 PAM 元件，應用程式直接打 CCP 拿 SCRAM 密碼不受影響；受影響的是平台端 properties 的密碼：
  銀行只有 PAM 時用不了該 provider → 維持 Secret Protection（master key 交 CyberArk 保管）。有 Conjur Enterprise ＋ Vault Synchronizer 才可能用。
  再問原廠：(a) provider 是否只支援 Conjur；(b) 只有 PAM＋CCP 時官方建議是否就是 Secret Protection；(c) Conjur provider 密碼輪替後要不要滾動重啟。
- 若銀行有 Conjur、走 csid-secrets-providers，每台主機啟動前的前置：Conjur policy（variables、host 身分、授權）；host 的 API key／憑證（secret zero，0600 落地）；
  信任 Conjur TLS；provider jar 進 classpath（配 Kafka 版本）；properties 改 `${cyberark:…}`；主機到 Conjur 443 通且 Conjur 高可用（連不到就起不來）。
  與 Secret Protection 的差別：落地的是每台一把 host key 而非一把 master key；啟動依賴外部系統在線。
- 2026-10-22 lab 實作結果（journey 第 15、16 章）：
  - Conjur provider 可用：五個範本的密碼欄位改 `${cyberark:<變數>:<變數>}`（key 必須等於路徑）；只帶 4 個 jar（common、annotations、cyberark、conjur-api），其餘相依主機已有；
    Kafka／REST 用 `CLASSPATH`，C3 要用 `CONTROL_CENTER_CLASSPATH`；provider 每個設定物件都重新初始化（啟動一次上千行日誌）；host API key 以明文落在 properties（secret zero）。
  - Secret Protection 可用：同一份 security.properties 發所有主機，master key 走 `EnvironmentFile=/etc/confluent/service.env`（0600）；master key 輪替 = rotate → 重派兩個檔 → 滾動重啟，全程 20 分鐘內。
  - 兩者都是啟動時讀一次，密碼輪替都要滾動重啟。
  - Summon（CyberArk 開源）可讓 Secret Protection 的 master key 不落地：`ExecStart=summon -p summon-conjur -f secrets.yml <原啟動腳本>`，值只在子程序環境變數；代價是啟動時保管庫要在線；主機上剩 /etc/conjur.identity（host 身分）。接 PAM 的 CCP 沒有官方 provider，可自寫（stdin 給 id、stdout 回值）。
  - **16.9（2026-10-23 lab 驗過）**：Secret Protection 的本質是密文「凍」在 security.properties，CPM 換了 AD 查詢密碼 broker 不會跟上。解法：那一個欄位不加密，由 Summon 把保管庫的值注入環境變數、properties 用 Kafka 內建 `EnvVarConfigProvider`（`config.providers = securepass,env`、`ldap.java.naming.security.credentials = ${env:LDAP_BIND_PASSWORD}`），不需 csid jar。
    驗證：改完滾動重啟後 alice 經 LDAP listener 建 topic 成功（群組查詢靠 bind 帳號、快取為空）、kb01 日誌 0 筆 LDAP 認證錯誤；AD 改密碼＋保管庫更新後只滾動重啟即生效。注意 `confluent secret` 改寫過的 properties 是 `key = value`（有空白）。
- **密碼放法決策樹（給客戶的三題，2026-10-23）**：
  1. 有 Conjur？有 → 第 15 站（全部 `${cyberark:…}`，密碼不落地）。沒有 → 2。
  2. 保管庫故障時平台要能重啟？要 → 16.4（master key 落地 service.env）。可接受不行 → 16.8（Summon 不落地）。
  3. AD 查詢密碼由 CPM 管？是 → 加 16.9（該欄位改 Summon 注入），並開 A／B 兩組查詢帳號、CPM 只在放行時輪替。否 → 留在密文，換密碼走 16.3 重算。
  其他組合技術上可行但多一條信任鏈，不推薦。
- 只有 PAM 又想不落地：方案 A = FileConfigProvider ＋ systemd ExecStartPre 以 client 憑證打 CCP REST 寫到 tmpfs（/run，0700）；方案 B = 自寫 CCP ConfigProvider jar。PoC 先用 Secret Protection。

### 3. 操作機 ssh 進各主機的 cpadmin

- 有了私鑰，操作機就能 ssh 到 controller、broker、REST Proxy、C3 各台的 cpadmin，指令和今天做的一模一樣。
- 這是機器對機器的連線，不走 PSMP。PSMP 是給人用的，一條連線一個錄影 session，安裝迴圈幾十條連線走它不實際。

### 4. sudo 要另外談（CyberArk 金鑰解決不了這個）

- 安裝要 root 權限，cpadmin 是靠 sudo。兩種做法：
  - 行內 OS 團隊依變更單在各主機開 cpadmin 的 sudo，有時限，做完收回。
  - 行內有 OPM 的話，cpadmin 提權的每條指令經 OPM 授權跟記錄，不用改 sudoers。

### 5. 操作機上的帳號（2026-10-22 定案）

> 這是客戶正式環境的長相，**不改 lab 與手把手文件的設計**：lab 維持 cpadmin 直接登入操作機、自己 ssh-keygen。

- **安裝期**：工程師經 PSMP **直接以 cpadmin 登入操作機**（`ssh <本人 Vault 帳號>@cpadmin@ops@psmp`）。cpadmin@操作機是 CyberArk 納管的帳號（金鑰在 Vault、CPM 輪替、PSMP 代登），人的身分由 PSMP 錄影與 Vault 稽核記錄，不另外切帳號。
  安裝期間 cpadmin 在操作機有 sudo（變更單時段內開、做完收回）；安裝腳本開頭打 CCP 取「操作機 → 各主機」的 cpadmin 私鑰進 ssh-agent。
- **維運期**：維運人員用自己的 opxx 個人帳號（本機帳號，OS 團隊建）登入，跑銀行自己的 OP menu／維運腳本；不切 cpadmin、沒有 sudo。
- 不需要 spxx 這類平台工程師個人帳號；不需要「sudo -u cpadmin」的切換規則。
- 工作目錄就是 cpadmin 的家目錄（`~/pki`、`~/conf`、`~/secrets`…，0600／0700），和 lab 完全一致。
- 各主機（kc、kb、rest、c3）只有 cpadmin（只收 CPM 推的公鑰）。
- CyberArk 要管的 SSH key 帳號：cpadmin@操作機（PSMP 進操作機用）＋ cpadmin@各主機（操作機經 CCP 取、ssh 出去用）＋ 每個 opxx 一組（PSMP 進操作機用）。
- **第二跳（操作機 → 各主機 cpadmin）是唯一沒有 PSMP 記人的一段**：追溯靠時間對齊 PSMP session（誰在操作機的 cpadmin）＋ CCP 取用紀錄（AppID 幾點取私鑰）＋ 各主機 sshd／sudo 日誌（SIEM）。
  強化：cpadmin@操作機 在 PSMP 設 exclusive（同時只准一條 session）；各主機 authorized_keys 加 `from="操作機 IP"`；sshd `LogLevel VERBOSE` 記公鑰指紋；ssh-add -t 4h、作業結束 ssh-agent -k；主機日誌送 SIEM。
  資安若仍不接受，備案是第二跳也走 PSMP（方案 B），代價是安裝腳本的 ssh／scp 全部改寫。

### 和今天 lab 的差別

就兩個：金鑰不是你在 ops02 產生的，是從 Vault 取的；公鑰不是我（扮演銀行）手動放的，是 CPM 推的。其他指令都一樣。

### 問客戶「有哪些 CyberArk 元件」的問法（2026-10-22）

不問元件名稱，照功能問；答得出來就代表元件在：

| # | 問法 | 對應元件 | 沒有時的替代 |
|---|---|---|---|
| 1 | 人員 ssh 到 Linux 是否一律經 CyberArk 代登？格式 `ssh 帳號@目標@哪台`？有錄影？ | PSMP | 人直接 ssh，靠 OS 日誌 |
| 2 | root 密碼與服務帳號 SSH 金鑰是否由 CyberArk 產生／輪替並推公鑰到主機？週期？ | CPM + SSH Key Manager | OS 團隊手動 |
| 3 | 應用程式／腳本能否用 HTTPS 向 CyberArk 要密碼？AppID 怎麼申請、IP 還是憑證驗？URL？ | CCP | CP agent 或 PVWA 手動 |
| 4 | 有沒有 Conjur（Enterprise／Cloud）？PAM safe 有沒有同步過去？ | Conjur + Vault Synchronizer | Secret Protection |
| 5 | Linux sudo 提權是否經 CyberArk？ | OPM | OS 團隊依變更單開 sudo |
| 6 | 申請帳號／取密碼／看紀錄的網頁？要變更單號？ | PVWA | — |
| 7 | 誰管 CyberArk？safe 誰建、AppID 誰核？ | 組織 | 決定申請單送誰 |
| 8 | 操作機可否有本機個人帳號 spxx／opxx？還是主機一律接 AD？ | — | — |
| 9 | 操作機到 CCP／Conjur 的 443 是否開放？ | 網路 | — |

### 要跟客戶確認（細項）

1. 操作機可以持有受 CyberArk 管理的金鑰去連各主機嗎？還是每條連線都要走 PSMP？（後者安裝時間會拉很長）
2. cpadmin 的 sudo 怎麼開：OS 團隊依變更單開，還是走 OPM？
3. 請銀行開 CCP 的 AppID 給操作機（來源 IP＋client 憑證驗證），並把 cpadmin 的 SSH key 帳號放進對應 safe；CCP 的 URL 與憑證要求是什麼？（已不考慮裝 CP agent）
4. 唯讀的 AD 查詢帳號（svc-mds-bind）要不要納入 CPM 輪替？不輪替最省事，輪替就要配合 broker 滾動重啟。
   2026-10-22 建議：正式環境用**兩組帳號 A／B 交替**（svc-mds-bind-a／-b，同 OU、同唯讀權限）：CPM 只改閒置的那組 → 平台切換 bind 設定並滾動重啟 → 驗證後 CPM 再改原本在用的那組。零中斷，節奏由平台控制；CyberArk 端設為手動觸發輪替。單一帳號直接改密碼會讓新登入／新 token 失敗到 broker 重啟完成為止。
5. 經 PSMP 進操作機時，OS 帳號是共用的 cpadmin（人的身分只在 PSMP 錄影與 Vault 稽核裡）。銀行接受嗎？
   若要求 OS 層看到個人，操作機就得加入 AD、每人一個 OS 帳號再 sudo -u cpadmin，會改掉「主機不接 AD」的前提。
8. 應用程式 SCRAM 密碼輪替：Kafka 同帳號同 mechanism 只有一組密碼，`kafka-configs --alter` 是直接覆蓋；已建立的連線不受影響（除非設 `connections.max.reauth.ms`），新連線即失敗。
   建議和 AD 一樣用 **兩個帳號 A／B**（`<app>-a`／`<app>-b`，同 SHA-512、同 role binding 與配額）交替；不建議「SHA-256／SHA-512 各一組密碼」的技巧（要永久開 SHA-256、app 要同時改 mechanism）。
   要問 app 團隊：client 收到 SaslAuthenticationException 後會不會重新向 CCP／Conjur 取密碼再重連？會的話單帳號即可。
7. 行內的 CyberArk 是只有 PAM，還是 PAM＋Conjur（Secrets Manager）？兩者各有自己的保管庫；Confluent 的 config provider 只接 Conjur，應用程式拿 SCRAM 密碼則 CCP 或 Conjur 都可。
   有 Conjur 的話再問：Vault Synchronizer（PAM safe → Conjur 單向同步，只支援 Conjur Enterprise）有沒有部署、哪個 safe 可以給 Confluent 用；有的話平台密碼放 PAM safe 由 CPM 管，Conjur 變數路徑會是 `<policy>/<safe>/<帳號>/password` 的固定格式。
6. CyberArk 要管兩組 SSH key 帳號：cpadmin@ops02（PSMP 進操作機用）與 cpadmin@各主機（操作機出去用，公鑰可加 from="操作機 IP"）。

### 備註：C3 和操作機同台

技術上可以，但先想兩件事：C3 很吃資源（heap 數 GB 加內建 Prometheus），會跟操作機上的作業互相影響；操作機原本只開 ssh，同台後要多開 9021 給瀏覽器。建議維持分開，真要合併主機規格要按 C3 來。

---

## 手動實測進度（cp-man，2026-10-20）

全程由使用者在操作機 ops02 手動下指令，不用 cpctl。lab 由 Claude 扮演銀行（AD、CA 簽發、repo01 的 OS 套件庫與 NTP、LB、主機帳號開通）。

| 項目 | 狀態 |
|---|---|
| 1–6 下載、驗證、搬進內網、上架 repo01（httpd + createrepo_c） | 完成 |
| 8 JDK 21（銀行給 tar；`/opt/java`、alternatives、`/etc/profile.d/java.sh`） | 完成 |
| 13 安裝前檢查、14 OS 調校、15 套件安裝 + versionlock | 完成 |
| 12 憑證（7 張 CSR → 銀行 CA → 匯入前檢查 → PKCS12、truststore、MDS token 金鑰） | 完成 |
| 16–17 controller/broker 設定、格式化、啟動 | 完成 |
| 18 SCRAM、RBAC、配額、topic；alice/carol AD 登入驗證 | 完成 |
| 19 REST Proxy ×2（經 LB）、C3（Prometheus/Alertmanager mTLS） | 完成 |
| 20 OP 選單 | 不納入 |
| 21 端對端驗收、22 收尾 | 待做 |
| 延後：Secret Protection、audit log 路由、JMX exporter | 待做 |

### 踩到的坑（新腳本一定要處理）

1. **RPM 服務用預設設定啟動**：`systemctl start` 前若 drop-in 沒生效，服務會讀 RPM 預設的 properties（REST Proxy 變成無加密 HTTP、C3 連不上 Kafka）。腳本在 start 前必須檢查 `systemctl show <unit> -p ExecStart` 指向我們的設定檔；而且 `enable --now` 對已在跑的服務不重啟，設定變更要明確 `restart`。
2. **C3 要能寫 `/etc/confluent-control-center/*-generated.yml`**（alertmanager、trigger_rules、recording_rules、prometheus-generated-local）：擁有者要是 `cp-control-center:confluent`，不能全部設成 root。
3. **確認用的指令要 `sudo`**：`/etc/confluent/ssl`、`/var/lib/kafka` 是 0750，cpadmin 直接 `ls`/`stat` 會 Permission denied，誤以為步驟失敗。
4. **下載機**：先下載再裝工具（見上方教訓）；lab 用 9p 掛載時 `dnf download` 的 checksum 核對會非常慢，應先下載到容器內磁碟再複製出來。
5. **lab 環境問題（非設定）**：Docker Desktop VM 的 netlink 卡死，所有容器 `ip addr` 掛住 → Java 名稱解析卡在原生呼叫 → broker TOKEN listener 執行緒全部排隊、9094 堆滿 CLOSE-WAIT。重啟 broker 無效，只能重啟 Docker Desktop。判斷方式：任一容器 `timeout 5 ip addr` 卡住。

### MDS token 金鑰輪替（2026-10-23 lab 實測）

- 這把金鑰不是銀行 CA 簽的憑證，沒有到期日；**只在外洩或政策要求時換**，不排例行輪替。
- **公鑰檔放兩把沒有用**：broker 的 TOKEN listener 只用檔案裡的第一把（新+舊時舊鑰簽的被拒、舊+新時新鑰簽的被拒）；MDS 自己的 REST API 也只認自己私鑰對應的那把（別台簽的 → 401）。所以做不到「先加新公鑰、再換私鑰、再拿掉舊的」的零中斷三階段。
- 實際做法（lab 實跑，`install/lab/mds-token-key-rotate.sh`）：新金鑰先派送到所有主機（`.new`，不影響運作）→ 檔案一次全部換上 → 滾動重啟 controller → broker → REST → C3 → 驗證 → 操作機正本換新、舊的離線銷毀。
  切換 196 秒，影響只在靠 token 的路：REST 經負載平衡 100 次失敗 7 次（集中約 30 秒，401／逾時）、管理 client 20 次失敗 3 次；**應用程式 SCRAM 寫入 0 失敗**（只有換 leader 的自動重試），broker 之間、人員 LDAP 登入不受影響。
- **2026-10-23 定案：不排輪替**。只在私鑰外洩時換，用 `install/lab/mds-token-key-rotate.sh` 驗過的程序（排維護時段、事前通知走 REST 的應用程式約半分鐘可能 401）；不寫進手把手。
- `confluent.metadata.server.token.key.passphrase`（讓 MDS 讀加密私鑰）原廠文件查不到 → 不採用，私鑰維持 PEM 0640 root:confluent；資安若要求加密先問原廠（第 12 節）。

### 憑證輪替（2026-10-23 定案，已實作：手把手第 21 章＋第 21 站，lab 實跑）

- 範圍：**leaf 換發**（同一個 CA，每年到期前）＋ **CA 三階段**（銀行換中繼／根：加新根 → 換 leaf → 移除舊根）。MDS token 金鑰不在此列（見上）。
- `kafka-internal` **維持 7 台共用一張**（申請單少；風險以 0640 權限＋定期輪替緩解）。
- 交付：手把手第 21 章（手打指令、lab 實跑）＋ `install/steps/21-cert-rotate.sh`。

### Secret Protection 的 master key 保管（2026-10-23 定案，lab 實測）

- **CyberArk 存兩個 object（同一個 safe、分開授權）**：`secret-protection/master-key`（給要啟動服務的一方；Summon 時是每台主機）、`secret-protection/passphrase`（只給平台工程師）。輪替時兩個一起更新，舊版本留著回滾。
- 為什麼兩樣都要（lab 用測試值實測）：
  - master key = passphrase ＋ 隨機 salt 推導；`confluent secret master-key generate` **每次都換新 salt**，同一個 passphrase 再產生一次是另一把 → **只存 passphrase 救不回 master key**（之前手把手 16.2「CyberArk 保管 passphrase，需要時重新推導」是錯的，已更正）。
  - `confluent secret file rotate --master-key` 要「目前的 master key（環境變數）＋舊 passphrase」兩樣都對才成功 → 只存 master key 就不能用 CLI 輪替。
  - 兩樣都遺失：產生新 master key、從操作機的明文來源重跑第 16 站重新加密並滾動重啟（不中斷服務）。
- 流程：master key 產生後**先交 CyberArk 保管、確認後才派送**。`install/` 新增 `VAULT_ACCESS=api|manual`：
  - api（lab）：腳本把 master key 寫進保管庫（不再只限 Summon）。
  - manual（客戶，只有 PVWA）：passphrase 由小安從 PVWA 取出放 `~/secrets/sp-passphrase.txt`；master key 產生後停下（rc 2），Secrets 團隊存進 PVWA、小安把「雜湊 單號」寫進 `~/secrets/master-key.custody`，再跑一次才派送；換了 master key 雜湊對不上會再停。lab 用隔離複本驗過四種情況。`SUMMON=1` 必須 `VAULT_ACCESS=api`。
- **只有 PAM 時 CyberArk 的角色＝保管與稽核，不參與執行期**；master key 落地 `service.env`（0600 root），擋得住設定檔外流、擋不住本機 root。要連 root 都擋，需要啟動時向外取的機制（CCP，或 Conjur＋Summon）。寫進手把手 16.7。

### 作業系統版本（2026-10-23 定案）

- 以 **RHEL 9** 為準（lab：Rocky Linux 9 全程實跑）。RHEL 10.x 在 Confluent Platform 8.2／8.3 官方支援表上是 yes，C3 2.6 文件沒有另外列作業系統。
- RHEL 10 **先不處理、未實測**；之後要做時至少驗：`python3-dnf-plugin-versionlock`、原廠公鑰匯入與 `rpm -K`、C3 前置套件（cyrus-sasl、openssl-devel）、CPU 需支援 x86-64-v3。

### 升級與日常修補（2026-10-24 定案；Confluent＋JDK 已實作：手把手第 22 章＋第 22 站，lab 實跑）

- 範圍：**Confluent 小版與 patch**（滾動升級、回滾、features 升版）、**Control Center**、**JDK**（銀行交付新版 tar）、**OS 修補**（滾動 dnf update，Confluent 與 JDK 由 versionlock 保護）。
- **JDK 情境＝升 8.3 時一起從 21 換到 25**（使用者定案）。8.2.x 只支援 Java 17／21，8.3.x 支援 17／21／25（官方相容表）→ 分三段：① 8.2.4→8.3.2（維持 JDK 21，可 `dnf downgrade` 回滾）② JDK 21→25 逐台滾動（切 `/opt/java/current`，退回＝切回 21）③ 兩段都驗過才 features 升版（finalize）。要回 8.2 時先切回 JDK 21 再 downgrade。**C3 留在 JDK 21**（官方未寫 C3 2.6 支援 25）。
- 形式：和第 21 章一樣，先寫手把手新章（手打、lab 實跑），再寫 `install/steps/22-*.sh`（隨時執行，不在安裝順序裡）。
- lab 演練：用 `install/` 以 **8.2.4** 從零裝一套（硬碟上 `packages/rpm/confluent/` 有整套 8.2.4，或照第 1 站重新下載），再照新章升到 8.3.2；持續流量下量測遺失與失敗。C3 與 JDK 的演練要另外下載舊一版（C3 2.6.0 或更早、另一個 JDK 21.x）。
- 官方做法（CP 8.3 升級文件，2026-10-24 查）：
  - 順序：**Control Center 最先** → broker 逐台 → controller 逐台 → REST Proxy（所有 broker 升完後）→ 應用程式最後。舊 cpctl 沒有把 C3 排在最前面，新章照官方。
  - REST Proxy（RBAC）升級前先在 `_confluent-command` topic 加 ResourceOwner role binding。
  - features：全部升完後 `kafka-features --release-version 4.3` 先看 version-mapping 再 `upgrade`；升了之後只有新舊版之間沒有 metadata 變更才能降版，8.3 降版「可能要從備份還原」→ **finalize（features 升版）之前都可回滾，之後不行**。8.2.x 是 4.2-IV0／IV1，8.3 是 4.3-IV0。
  - 每台升級前：移除已廢棄的 `message.format.version` 等設定、備份 `/etc`；KRaft 升級需從 7.7.1 以後；所有元件同版，不跨版混用。
  - 官方寫法是 `yum remove` 舊版再 `install` 新版；我們的設定不在 RPM 的預設路徑（`/etc/confluent/…`），比照 cpctl 用 `dnf install` 新版並更新 versionlock，實測時確認設定與 drop-in 不被覆蓋。

### 日常備份（2026-10-24 定案，待實作）

- **三類分工**（使用者定案）：
  - 叢集中繼資料（RBAC、topic 與設定、配額、SCRAM 帳號清單、features）：**操作機排程每天匯出**（systemd timer，保留 N 天）＋ **OP menu 立即匯出**（變更前的快照，紀錄是本人；擴充現有 44「匯出權限清單」）。
  - 各台 `/etc/confluent` 與 drop-in：**銀行既有的主機備份系統**（客戶模式 cpadmin 私鑰只在變更時段的 agent 裡，操作機的排程無法 ssh 進各台）；lab 用每台自己的 timer 模擬。
  - 機敏資料（`~/pki`、`~/secrets`、master key）：**事件觸發**，安裝、換憑證、換密碼時交 CyberArk 保管，不排程（同第 16 站 master key 的做法）。
- 排程身分：**新發唯讀的 `svc-backup` 應用憑證**（使用者定案），不用 super user 的 svc-ops。查原廠：SecurityAdmin 可「查看他人 role binding、不能管理」；topic 設定、配額、SCRAM 清單需要的最低權限待 lab 實測。
- 交付：手把手新章＋install 新的一站。資料（訊息）本身不做檔案備份：叢集內靠 RF 3／min.insync 2；異地備援（Cluster Linking）依銀行 RPO／RTO，列為客戶問題。

## 12. 給客戶的總問題清單（2026-10-22，依安裝旅程整理）

> 2026-10-24：依目前的定案改寫成可以直接交給銀行的文件 `docs/Confluent-請銀行確認的事項.docx`（來源 `docs/questions-src/questions.md`，每題附「為什麼要知道」與「沒有答案時我們的預設」）。原廠題不在裡面，仍在下表。

| 組 | 題目 |
|---|---|
| 離線引進 | 下載機由誰提供、能否跑 Maven／git；落地區交換方式與大小上限；掃描放行標準（RPM GPG＋SHA256 夠嗎？jar／tar 怎麼放行）；後續補帶檔案的流程與時程 |
| 套件來源與 JDK | OS 套件來源型態（Satellite／制品庫／mirror／媒體）與 .repo 由誰配；清單套件是否都在、版本是否鎖；Confluent RPM 上架到行內制品庫還是操作機自架、誰上架；JDK 21 誰提供、tar 或 RPM、路徑、誰更新 |
| 主機與帳號 | 11 台規格、/tmp noexec；主機接不接 AD；cpadmin 誰建、sudo 怎麼開與收回；opxx 維運帳號與指令範圍；SELinux／THP／sysctl 變更單 |
| 網路 | port 清單誰開、主機 firewalld 可否由我們管；DNS 或 /etc/hosts、FQDN；NTP 來源；REST 前的 LB 型態與 VIP；C3 9021 從哪個網段連 |
| 憑證 | CA 申請流程與時程；會不會改 SAN／EKU、serverAuth＋clientAuth 同一張可否；回覆格式；效期與輪替；根憑證進 OS trust store／JDK cacerts 由誰 |
| AD | svc-mds-bind 誰建、可否兩組 A／B；群組命名與管理；LDAPS 用哪台 DC、憑證、備援；人員 AD 帳密登入 C3 可否、MFA |
| 原廠（Confluent） | `confluent.metadata.server.token.key.passphrase`（讓 MDS 讀 PKCS#8 加密的 token 私鑰）原廠文件查不到（8.3 MDS 設定參考只有 token.key.path／max.lifetime.ms／signature.algorithm），舊 cpctl 用過、lab 可用：是否正式支援、會不會補文件？MDS token 公鑰檔能否放多把（做零中斷金鑰輪替）？ |
| CyberArk | （2026-10-23 已知：只有 PSM／PSMP 代登＋SSH 金鑰輪替，無 CCP／CP／Conjur）PVWA 取用私鑰與 master key 要不要雙人覆核、要填什麼單號；master key 放哪個 safe；應用程式現在怎麼拿資料庫密碼（SCRAM 照同一套）；元件清單（照功能問）；CCP AppID 申請與驗身分；CPM 管 cpadmin 金鑰與 from= 限制；Conjur 有無與型態、host 身分、policy 誰載、443 通否；只有 PAM 時 master key 放哪個 safe；保管庫故障時平台能否重啟 |
| 應用程式 | 直連 SCRAM 或經 REST 各幾個；app 怎麼拿密碼、認證失敗會否重取；topic 命名與配額；client 語言與 SCRAM-SHA-512 支援 |
| 監控維運 | 日誌送 SIEM 方式與保留；行內 Prometheus 抓 JMX exporter；稽核日誌保留與去向；變更時段；冷開機順序 |

## 13. OP menu（第 20 項）定案（2026-10-22）

- **不在主機放任何 agent／forced-command 程式**；主機端只靠 sudoers。
- 跑在操作機，維運人員用自己的 opxx 本機帳號執行；Kafka 身分用本人 AD 帳密向 MDS 換 token（現有機制不變）。
- 主機類動作（重啟、看日誌）：選單啟動時經 CCP 取「和安裝同一把」cpadmin 私鑰進 ssh-agent，普通 ssh 到各主機 cpadmin 執行 `sudo systemctl restart`／`sudo journalctl`；結束 `ssh-agent -k`。
- 各主機 cpadmin 的 sudoers 分兩段：**永久窄規則**（`systemctl restart/status confluent-*`、`journalctl -u confluent-*`）＋ **變更時段全權**（安裝、升級時 OS 團隊依變更單開 ALL，做完收回）。
- 保留：第 1 層值班查看、第 3 層變更作業、第 4 層授權與稽核、91 緊急模式；第 2 層只留重啟與看日誌。
- 拿掉：ticket 機制、清理日誌（由第 7 站的 tmpfiles 處理）、docker 後端、雙人確認（早已移除）。
- 91 緊急模式的 opmenu-breakglass 憑證放 CyberArk，執行時經 CCP 取，不落地。
- 紀錄：本機檔（opxx 本人、項目、時間、結果）；是否送 SIEM 待問客戶（總問題清單第 9 組）。
- 追溯：選單紀錄（人）＋ CCP 取用紀錄（AppID、時間）＋ 主機 sshd／sudo 日誌（cpadmin 從操作機 IP）。
- 2026-10-22 已改程式並在 lab 實測（opmenu/，commit 待）：拿掉 docker 後端、ticket、清日誌、維護模式；新增 lib/secrets/{conjur,ccp}.sh；
  登入後 `secret_get` 取 cpadmin 私鑰 `ssh-add -` 進選單自己的 ssh-agent（TTL）、離開時 agent 結束；91 用保管庫的 PEM 憑證（TokenCertificateLoginCallbackHandler、PEM keystore）換 token；
  ssh 只信管理員建的 /etc/opmenu/known_hosts。lab 實測：bob/carol/alice 三種身分的動態選單、隱藏項目直接輸入被擋、23/16/22/21/27 經 cpadmin ssh 成功、kb04 換成兩段式 sudoers 後重啟與看日誌仍可、91 經 Conjur 取憑證成功、離開後無 agent 殘留、磁碟無私鑰。
  踩到：Conjur 身分檔最後一行沒換行 read 失敗；`kafka-topics --describe` 需要 DescribeConfigs → 維運群組要 Operator＋DeveloperManage Topic:*（見 opmenu/README）。
- 2026-10-22 重排：opmenu.sh 只管登入與選單；lib/common.sh、kafka.sh、hosts.sh、secrets/；items/<編號>-<名稱>.sh 一項一檔（item 宣告 + run）；tests/。重排後單元測試 3/3、lab smoke 12 項通過，行為不變。
- **2026-10-23 客戶沒有 CCP**：機敏資料來源加 `manual`（`lib/secrets/manual.sh`）：選單提示維運人員到 PVWA 取出 object、貼上（不回顯）、只進選單自己的 ssh-agent。
  私鑰改成**要用才取**（`OPMENU_SSH_KEY_LOAD=auto`：manual 時 on-demand、其他來源登入就取）：第一次做主機類項目、而且**先過主機權限閘門**才要求貼上，只看 Kafka 的人、沒有主機權限的人都不會被要求。
  掛在主 shell 執行項目之前（項目在管線的子 shell 裡跑，在那裡載入的 agent 下一個項目看不到）。lab 實測 12/12（`install/lab/opmenu-manual-test.sh`）。`ccp.sh` 改用 sed 解 JSON，不用 python。
- **2026-10-23 緊急主機模式（使用者定案）**：MDS 連不上時（AD 登入做不了），作業系統群組 `opmenu-emergency`（平常空，事故時 OS 團隊臨時加人）的人可以進入；
  只開放 16 磁碟、18 收集診斷、21 重啟 broker、22 重啟 REST／C3、23 看日誌（Kafka 類全部不開）；必填原因；操作者標成「<AD 帳號>(緊急,未經AD驗證)」、記 EMERGENCY_HOST；
  主機權限閘門改由登入時的群組檢查代替；21 的 under-replicated／offline 檢查做不了時改成警告＋確認。lab 實測 14/14（`install/lab/opmenu-emergency-test.sh`，MDS 指到不通的埠模擬故障）。
  要問客戶：誰能把人加進 opmenu-emergency、事後誰移出、紀錄送不送 SIEM。
- **2026-10-23 服務帳號 A／B 與密碼交接**：34 一次建 `<名稱>-a`、`<名稱>-b` 兩個 SCRAM 帳號（同樣的權限）；應用程式先用 -a。
  35 只換「沒在用的那個」（操作者指定在用的帳號），應用程式改用新帳號後，舊帳號下次再換，換密碼不必停機；37 兩個一起下架。
  新密碼**不顯示在畫面**，寫到操作者自己的交接檔 `$HOME/opmenu-handover/<帳號>-<時間>.pass`（目錄 0700、檔 0600），交給 Secrets 團隊存進 PVWA 後刪除；
  改密碼前先確認交接目錄寫得進去，寫不進去就不改；交接失敗時，該項目記為 FAIL。
  17 改看各端點**實際出示**的憑證（openssl s_client，`OPMENU_TLS_ENDPOINTS`），不再讀主機上的檔案，換發後忘了重啟會被看出來。
  全項目回歸 `install/lab/opmenu-items-test.sh`：37/37（每個項目實跑，加驗 17 的 18 個端點、34/35/37 的實際登入結果；21／22／27 真的重啟）。
  要問客戶：交接檔怎麼交給 Secrets 團隊（PVWA 由誰登錄）、交接後由誰刪。
