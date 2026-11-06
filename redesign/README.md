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

---

## 11. 安裝帳號、SSH、sudo（行內有 CyberArk 的情況）

客戶有 CyberArk，分兩種用法：代登（PSMP）、用 SSH 定期換密碼（CPM）。套到我們的流程會是這樣：

### 1. 操作人員用 CyberArk 代登進操作機

- 操作人員用自己的 AD 帳號登入 CyberArk。
- CyberArk（PSMP）代登進操作機，身分是 cpadmin（安裝用帳號），全程錄影。
- 人不會知道 cpadmin 的密碼，也不用知道。

### 2. 操作機對各主機的 SSH 金鑰，交給 CyberArk 管（2026-10-27 已被取代）

> **2026-10-27 已被取代**：和客戶討論後改成「一組金鑰放操作機、user 叫 cpuser、人員經 PVWA＋PSMP 進操作機是 root」，見下方「和客戶討論後的主機存取做法」與「新做法已進手冊與腳本」。本段保留當時的討論，手冊與腳本已不是這樣做。

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
- **密碼放法決策樹（給客戶的三題，2026-10-23；Conjur／Summon 分支已於 2026-10-27 刪除，客戶情境只剩 16.4 落地加 CPM 人工處理）**：
  1. 有 Conjur？有 → 第 15 站（全部 `${cyberark:…}`，密碼不落地）。沒有 → 2。
  2. 保管庫故障時平台要能重啟？要 → 16.4（master key 落地 service.env）。可接受不行 → 16.8（Summon 不落地）。
  3. AD 查詢密碼由 CPM 管？是 → 加 16.9（該欄位改 Summon 注入），並開 A／B 兩組查詢帳號、CPM 只在放行時輪替。否 → 留在密文，換密碼走 16.3 重算。
  其他組合技術上可行但多一條信任鏈，不推薦。
- 只有 PAM 又想不落地：方案 A = FileConfigProvider ＋ systemd ExecStartPre 以 client 憑證打 CCP REST 寫到 tmpfs（/run，0700）；方案 B = 自寫 CCP ConfigProvider jar。PoC 先用 Secret Protection。

### 3. 操作機 ssh 進各主機的 cpadmin（2026-10-27 已被取代：帳號改叫 cpuser）

> **2026-10-27 已被取代**：和客戶討論後改成「一組金鑰放操作機、user 叫 cpuser、人員經 PVWA＋PSMP 進操作機是 root」，見下方「和客戶討論後的主機存取做法」與「新做法已進手冊與腳本」。本段保留當時的討論，手冊與腳本已不是這樣做。

- 有了私鑰，操作機就能 ssh 到 controller、broker、REST Proxy、C3 各台的 cpadmin，指令和今天做的一模一樣。
- 這是機器對機器的連線，不走 PSMP。PSMP 是給人用的，一條連線一個錄影 session，安裝迴圈幾十條連線走它不實際。

### 4. sudo 要另外談（CyberArk 金鑰解決不了這個）

- 安裝要 root 權限，cpadmin 是靠 sudo。兩種做法：
  - 行內 OS 團隊依變更單在各主機開 cpadmin 的 sudo，有時限，做完收回。
  - 行內有 OPM 的話，cpadmin 提權的每條指令經 OPM 授權跟記錄，不用改 sudoers。

### 5. 操作機上的帳號（2026-10-22 定案；2026-10-27 已被取代）

> **2026-10-27 已被取代**：和客戶討論後改成「一組金鑰放操作機、user 叫 cpuser、人員經 PVWA＋PSMP 進操作機是 root」，見下方「和客戶討論後的主機存取做法」與「新做法已進手冊與腳本」。本段保留當時的討論，手冊與腳本已不是這樣做。

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

## 手動實測的教訓（2026-10-20 起）

### 踩到的坑（腳本一定要處理）

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

### 憑證輪替（2026-10-23 定案，已實作：手把手第 20 章＋第 20 站，lab 實跑）

- 範圍：**leaf 換發**（同一個 CA，每年到期前）＋ **CA 三階段**（銀行換中繼／根：加新根 → 換 leaf → 移除舊根）。MDS token 金鑰不在此列（見上）。
- `kafka-internal` **維持 7 台共用一張**（申請單少；風險以 0640 權限＋定期輪替緩解）。
- 交付：手把手第 20 章（手打指令、lab 實跑）＋ `install/steps/20-cert-rotate.sh`。

### Secret Protection 的 master key 保管（2026-10-23 定案，lab 實測）

- **CyberArk 存兩個 object（同一個 safe、分開授權）**：`secret-protection/master-key`（給要啟動服務的一方；Summon 時是每台主機）、`secret-protection/passphrase`（只給平台工程師）。輪替時兩個一起更新，舊版本留著回滾。
- 為什麼兩樣都要（lab 用測試值實測）：
  - master key = passphrase ＋ 隨機 salt 推導；`confluent secret master-key generate` **每次都換新 salt**，同一個 passphrase 再產生一次是另一把 → **只存 passphrase 救不回 master key**（之前手把手 16.2「CyberArk 保管 passphrase，需要時重新推導」是錯的，已更正）。
  - `confluent secret file rotate --master-key` 要「目前的 master key（環境變數）＋舊 passphrase」兩樣都對才成功 → 只存 master key 就不能用 CLI 輪替。
  - 兩樣都遺失：產生新 master key、從操作機的明文來源重跑第 15 站重新加密並滾動重啟（不中斷服務）。
- 流程：master key 產生後**先交 CyberArk 保管、確認後才派送**。`install/` 新增 `VAULT_ACCESS=api|manual`：
  - api（lab）：腳本把 master key 寫進保管庫（不再只限 Summon）。
  - manual（客戶，只有 PVWA）：passphrase 由小安從 PVWA 取出放 `~/secrets/sp-passphrase.txt`；master key 產生後停下（rc 2），Secrets 團隊存進 PVWA、小安把「雜湊 單號」寫進 `~/secrets/master-key.custody`，再跑一次才派送；換了 master key 雜湊對不上會再停。lab 用隔離複本驗過四種情況。`SUMMON=1` 必須 `VAULT_ACCESS=api`。
- **只有 PAM 時 CyberArk 的角色＝保管與稽核，不參與執行期**；master key 落地 `service.env`（0600 root），擋得住設定檔外流、擋不住本機 root。要連 root 都擋，需要啟動時向外取的機制（CCP，或 Conjur＋Summon）。寫進手把手 16.7。
- **輪替（2026-10-25 定案，lab 實測）**：15.6 是原廠的 `confluent secret file rotate --master-key`，必須同時給舊 passphrase 與舊 master key（環境變數），CLI 也無法由 passphrase＋`security.properties` 重算 master key → PVWA 兩個 object 都要保管。**data key 不例行輪替**；懷疑外洩時換密碼本身（第 20 章、15.8）再重新加密。輪替週期問銀行（問題清單 8.7，預設每年＋保管人異動時）。
- **查明（2026-10-25，lab 實測）**：Confluent CLI v4.72 的 `--passphrase`／`--passphrase-new` 不認 `@檔案`（也不認 `-`），把「`@/home/cpadmin/secrets/…`」字串本身當 passphrase：PVWA 的 passphrase 從沒用到、知道路徑＋拿到 security.properties 就算得出 master key；檔名一換（16.6 的 mv）下一次輪替就失敗。改為給值 `"$(cat 檔案)"`（手把手 16.2、16.6、install 16）；16.5、16.6 結尾加「用 PVWA 的 passphrase 還能輪替、錯的被拒」檢查。代價：值短暫出現在行程參數 → 操作機 `/proc` 掛 `hidepid=2`（問題清單 4.6）。

### 作業系統版本（2026-10-23 定案）

- 以 **RHEL 9** 為準（lab：Rocky Linux 9 全程實跑）。RHEL 10.x 在 Confluent Platform 8.2／8.3 官方支援表上是 yes，C3 2.6 文件沒有另外列作業系統。
- RHEL 10 **先不處理、未實測**；之後要做時至少驗：`python3-dnf-plugin-versionlock`、原廠公鑰匯入與 `rpm -K`、C3 前置套件（cyrus-sasl、openssl-devel）、CPU 需支援 x86-64-v3。

### 升級與日常修補（2026-10-24 定案；Confluent＋JDK 已實作：手把手第 21 章＋第 21 站，lab 實跑）

- 範圍：**Confluent 小版與 patch**（滾動升級、回滾、features 升版）、**Control Center**、**JDK**（銀行交付新版 tar）、**OS 修補**（滾動 dnf update，Confluent 與 JDK 由 versionlock 保護）。
- **JDK 情境＝升 8.3 時一起從 21 換到 25**（使用者定案）。8.2.x 只支援 Java 17／21，8.3.x 支援 17／21／25（官方相容表）→ 分三段：① 8.2.4→8.3.2（維持 JDK 21，可 `dnf downgrade` 回滾）② JDK 21→25 逐台滾動（切 `/opt/java/current`，退回＝切回 21）③ 兩段都驗過才 features 升版（finalize）。要回 8.2 時先切回 JDK 21 再 downgrade。**C3 留在 JDK 21**（官方未寫 C3 2.6 支援 25）。
- 形式：和憑證輪替（第 20 章）一樣，先寫手把手新章（手打、lab 實跑），再寫 `install/steps/21-*.sh`（隨時執行，不在安裝順序裡）。
- （已併入主線，見最後一節「安裝基底改 8.2.x…」）lab 演練：用 `install/` 以 **8.2.4** 從零裝一套（硬碟上 `packages/rpm/confluent/` 有整套 8.2.4，或照第 1 站重新下載），再照新章升到 8.3.2；持續流量下量測遺失與失敗。C3 與 JDK 的演練要另外下載舊一版（C3 2.6.0 或更早、另一個 JDK 21.x）。
- 官方做法（CP 8.3 升級文件，2026-10-24 查）：
  - 順序：**Control Center 最先** → broker 逐台 → controller 逐台 → REST Proxy（所有 broker 升完後）→ 應用程式最後。照官方。
  - REST Proxy（RBAC）升級前先在 `_confluent-command` topic 加 ResourceOwner role binding。
  - features：全部升完後 `kafka-features --release-version 4.3` 先看 version-mapping 再 `upgrade`；升了之後只有新舊版之間沒有 metadata 變更才能降版，8.3 降版「可能要從備份還原」→ **finalize（features 升版）之前都可回滾，之後不行**。8.2.x 是 4.2-IV0／IV1，8.3 是 4.3-IV0。
  - 每台升級前：移除已廢棄的 `message.format.version` 等設定、備份 `/etc`；KRaft 升級需從 7.7.1 以後；所有元件同版，不跨版混用。
  - 官方寫法是 `yum remove` 舊版再 `install` 新版；我們的設定不在 RPM 的預設路徑（`/etc/confluent/…`），改用 `dnf install` 新版並更新 versionlock，實測時確認設定與 drop-in 不被覆蓋。

### 日常備份（2026-10-24 定案；2026-10-25 已實作：手把手第 25 章，lab 實跑）

- **三類分工**（使用者定案）：
  - 叢集中繼資料（RBAC、topic 與設定、配額、SCRAM 帳號清單、features）：**操作機排程每天匯出**（systemd timer，保留 N 天）＋ **OP menu 立即匯出**（變更前的快照，紀錄是本人；擴充現有 44「匯出權限清單」）。
  - 各台 `/etc/confluent` 與 drop-in：**銀行既有的主機備份系統**（客戶模式 cpadmin 私鑰只在變更時段的 agent 裡，操作機的排程無法 ssh 進各台）；lab 用每台自己的 timer 模擬。
  - 機敏資料（`~/pki`、`~/secrets`、master key）：**事件觸發**，安裝、換憑證、換密碼時交 CyberArk 保管，不排程（同第 15 站 master key 的做法）。
- 排程身分：**新發唯讀的 `svc-backup` 應用憑證**（使用者定案），不用 super user 的 svc-ops。lab 實測的最小權限：RBAC `SecurityAdmin`（看 role binding；建 binding 回 403）＋ KRaft ACL：Topic `*` 與 Cluster 的 `Describe`、`DescribeConfigs`。內建 RBAC 角色沒有「只有 DescribeConfigs」的（`DeveloperManage` 連帶能建／刪／改，`DeveloperRead` 沒有 DescribeConfigs 且讀得到訊息），所以這兩項用 ACL。反向驗證：讀訊息、建 topic、改 role binding 都被拒。
- 實作：操作機 `~/conf/metadata-backup.sh`＋systemd timer（每天 02:00，保留 30 天，syslog tag `confluent-backup`）；7 個文字檔＋SHA256SUMS，比對兩天的備份用 sha256＋join（精簡 OS 沒有 diff）；features 的 Epoch 拿掉、ACL 排序，否則每天都「有變」。OP menu 立即匯出（擴充 44）**尚未做**。
- 交付：手把手新章＋install 新的一站。資料（訊息）本身不做檔案備份：叢集內靠 RF 3／min.insync 2；異地備援（Cluster Linking）依銀行 RPO／RTO 決定（尚未列入客戶問題清單）。

### 手冊主線改成客戶情境、全模式實測（2026-10-25 定案）

- 手冊主線＝客戶模式：CyberArk 只有 PAM（PSMP 代登、SSH Key Manager、PVWA 人工取放），密碼與金鑰由人從 PVWA 取放；Conjur／CCP／Summon 改成「銀行有才做」的選配（選配已於 2026-10-27 刪除，見下方同日定案）。
- 客戶有的用客戶的（AD、CA、OS 套件庫、NTP、LB、PAM、主機備份、行內 Prometheus）；客戶沒有的才用我們的機制（例如操作機的 systemd timer）。
- 銀行未回覆的事項：用我們的預設，文件標「待銀行確認」。
- 流程：Claude 自檢（順序、內容足夠、要改的內容）→ 直接改 → 從零實測四種模式（Conjur 與 provider 模式已於 2026-10-27 刪除）：客戶模式（手冊全書＋install 全站含 21–28）、有 Conjur 的選配模式、升級演練（8.2.4 起）、Secret Protection 與 Conjur provider 兩條密碼路徑各走一次。每次跑完都用 scan-log.sh 掃。

### C3、REST Proxy 改用自己的憑證（2026-11-05 定案）

- **定案**：`svc-c3`、`svc-rest` 同時有 serverAuth 與 clientAuth，C3／REST 的 listener 和 JMX exporter 都用自己的那張；CN 不變，RBAC 不用改。C3 內建 Prometheus、Alertmanager 的 server 端也用 `svc-c3`，c3-01 不再放 `cp-server`；代價是 `svc-c3`（SystemAdmin）的私鑰以 PEM 檔放在主機上（root:confluent 0640）。Prometheus 連 Alertmanager 也用 `svc-c3`（Alertmanager 只驗鏈與用途、不看 CN），`c3-monitoring` 拿掉，操作機的檢查改用 `svc-ops`。OP menu 緊急模式改用 `svc-ops`，`opmenu-breakglass` 拿掉（Kafka 稽核日誌分不出緊急操作，靠選單 EMERGENCY 紀錄、CyberArk 與 PSMP）。憑證 7 張：kafka-internal、cp-server、svc-rest、svc-c3、svc-ops、app-legacy-billing、svc-backup。`cp-server` 仍只有 serverAuth，取代下一節「svc-c3 只當 client」的部分。
- **原因**：C3 2.5.1 的 Armeria 健康檢查（MDS、9090、9093）用 REST listener 的 keystore 當 client 憑證，`metadata.ssl.*`、`prometheus.ssl.*` 在這條路徑沒有作用；`cp-server` 只有 serverAuth 就被拒，C3 判定 MDS 全部不健康，AD 使用者的登入與 API 全部失敗（500／502），但首頁 200、服務 active，所以自動檢查一直抓不到。
- **驗證**：lab 8.2.4 通過；C3 2.6.1、REST 8.3.2 待驗。手冊與腳本待改，並要加帶身分呼叫 C3 API 的驗收。

### 銀行沒有 Prometheus 時的告警（2026-11-05 定案，手冊第 32 章）

- **定案**：和第 17 章並存。C3 內建 Prometheus 抓 REST Proxy 7071；我們的規則放 `custom-rules-rest.yml`，群組層級 `labels: { target: omnibus }`；每台 Alertmanager 各有 `alert_relabel_configs`（內建 drop、第二台 keep）；第二個 Alertmanager 用 C3 內附的執行檔、獨立設定與 systemd，自訂 JSON 送 omnibus。基底的 C3 2.5.1 階段不開。
- **實測**：2.5.1 內附 Alertmanager 0.32.2 會把 payload 的字串再解析成 YAML（`a: b`→物件、`123`→數字、`007`→7）；0.34.0（C3 2.6.1）、0.34.1 都是字串。c3-change.sh 升到 2.6.1，我們改的 10 個檔雜湊不變。真 C3 trigger 帶 `rule_created_by: c3-10`、沒有 target，只到內建；action 由內建送預設格式。
- **未解**：原廠是否支援（文件寫不支援客戶自管 Prometheus／Alertmanager）；omnibus 欄位填法（問題清單 11.9）。

### cp-server 改成純 server 憑證（2026-10-25 討論；2026-10-28 定案並改進手冊與腳本）

- **定案（2026-10-28）**：cp-server 只有 serverAuth；新增 `c3-monitoring`（clientAuth、無 RBAC、無 SAN）給內建 Prometheus 連 Alertmanager（`prometheus-generated.yml` 的 tls_config，PEM，沒有 p12）和第 13／14／19 站的檢查指令用；C3 自己連 Prometheus／Alertmanager 的 keystore 用 `svc-c3.p12`（alias svc-c3，使用者 2026-10-28 指正：C3 用自己的 client 憑證即可）；憑證共 9 張。web-config 的 `cp-server.crt/.key` 是 Prometheus／Alertmanager 的 server 端，不變。第 20 章換發、C3 派送一起帶 c3-monitoring；問題清單 6.2 說明。19 站新增一項驗收：cp-server 只有 serverAuth 且拿來連 9090 被拒。**還沒從零實跑驗證**（下一輪乾淨手冊實跑與腳本重跑要確認：keystore alias 讀得到、C3 連線正常、cp-server 被拒）。

- 目標：cp-server 的 EKU 只留 serverAuth。現在當 client 用的只有 C3 ↔ 內建 Prometheus／Alertmanager（C3 的 keystore、prometheus-generated.yml 的 tls_config）與操作機的檢查指令（curl --cert cp-server 連 9090）。broker／REST／MDS／JMX exporter 只當 server 用；telemetry 用 kafka-internal。
- Claude 的建議（未定案）：另發 `c3-monitoring`（clientAuth、無 RBAC）給 C3 監控元件用；不用 svc-c3（它是 SystemAdmin，Prometheus 需要明文 PEM 私鑰）；檢查指令改用 svc-ops；已上線環境先改 C3 再換發 cp-server（21.2）；可選 `client_allowed_sans`（要先確認 C3 附的 Prometheus 版本支援）。

### JMX exporter 的身分認證（2026-10-25 定案）

- 維持現狀：HTTPS（主機憑證）＋ HTTP Basic auth（帳號 prometheus，主機上只存加鹽 SHA-256），不加 mTLS。
- 已知取捨：9 個 exporter 共用一組 scrape 密碼；keystore 密碼明文在 exporter YAML（0640 root:confluent）。
- 待問銀行：7071 是否只放行行內 Prometheus 的來源 IP（第 7 章 firewalld 目前對所有來源開放）；行內 Prometheus 抓其他系統用哪種認證。

### 只保留現行設計（2026-10-25 定案）

- 只保留現行設計：舊的 cpctl 安裝程式、cp-poc／cp-man 兩個 lab、舊手動安裝手冊、全流程簡報、主機準備清單、另設堡壘機的舊 OP menu 設計都已從 redesign 分支移除（只剩 main 分支的歷史）。
- 現行設計只有一種：操作機 ops02 同時是維運人員登入點（經 PSMP），OP menu 跑在操作機，碰主機用 cpadmin 金鑰（正本在 PVWA，只放進 ssh-agent），見手把手第 16 章。SSH 金鑰只有 cpadmin 一組。
- 同日確認：cpadmin 先用 `NOPASSWD` sudo；CPM 的 reconcile 帳號不用 cpadmin。
- 同日確認：super user 等級的私鑰（`svc-ops`、MDS token 簽章私鑰）**不另外放 PVWA safe**，維持 20.5「安裝完成後移到離線保管」。（2026-10-31 改：`svc-ops.key` 照 10-28「平台密碼與金鑰只放操作機」留在 `~/pki`，不移到離線保管；19.5、請銀行確認事項 8.8 已改。）

### REST Proxy 重啟前先從 LB 停用（2026-10-26 定案，lab 實測）

- 升級演練（腳本版）換 JDK 時重啟 REST，經 LB 失敗 4 次：nginx 社群版只有被動檢查（`max_fails`），NGINX Plus 才有主動檢查；就算有主動檢查也是停了才發現。
- 定案 A：每次重啟 REST 都是「LB 團隊停用 rest01 → 小安排空、重啟、200 → 恢復 rest01、停用 rest02 → … → 恢復」（手把手 12.1；lab 用 `~/kafka-lab/lb-member.sh` 扮演 LB 團隊，操作機 `~/conf/rest-restart.sh` 等 LB 連線歸零才動，60 秒沒歸零就停下）。lab 實測經 LB 每 0.2 秒一次：排空 99 次 0 失敗；對照組不排空 68 次 1 失敗。套用在 15.5、16.5、16.6、16.8、18.3、21（三處換證＋rolling-restart.sh 四處）、22.6、22.7、27.4。
- 問銀行：LB 設備與變更時段的配合方式（問題清單 5.6）。
- 腳本（49690bb）：rolling_restart／22／27 重啟 REST 前寫交握檔 `~/lb-requests/<主機>.down|up` 等 LB 團隊回覆（`LB_CONTROL=handshake|none`），lab 由 `bank-sim lb-watch` 回覆。OP menu 22（638dd07）：那台還有 LB 連線就拒絕。
- 實測：腳本版升級演練（2026-10-26）REST 1232 次 **0 失敗**（之前 4 失敗）、直連 6384 筆 0 遺失；手把手全書（客戶）五步 14 輪全部 200。

### C3 內建 Alertmanager 的 webhook 自訂 JSON（2026-10-26 實測；使用者尚未選方案）

（已被 2026-10-27 的外部監控定案取代）

lab 實測（provider 模式 lab，C3 2.6.1、內建 Alertmanager 0.34.0），結論分三層：

1. **Alertmanager 本身可以**：webhook 的 `payload` 自訂 JSON 可用（map 寫法、字串寫法、`range`、`toJson`）。陷阱：map 寫法會把含 `: ` 的值當 YAML 解成物件、把像數字的字串轉成數字（`"007"`→7）；字串寫法遇到含雙引號的文字會整串被當成一個 JSON 字串送出 → 一律用字串寫法加 `{{ toJson … }}`。一個通知群組一個 POST，要一筆告警一個 POST 用 `group_by: ['...']`。範本取不到 `.GroupKey`（預設格式有 groupKey）。
2. **C3 UI／API 的 Generic Webhook 不能設自訂內容**：前端表單只有「Webhook URL」，送給後端的是 `{webhook:{url, genericWebhook:{}}}`；C3 寫進 Alertmanager 的 `webhook_configs` 只有 `url`，所以走 UI 時送出的一定是 Alertmanager 預設格式（version 4）。C3 的「測試」鈕（`POST /2.0/alerts/actions/verify`）是 C3 的 Java 程式自己送的（User-Agent Apache-HttpClient），內容是佔位範例。UI 可建的條件共 23 種（broker／topic／consumer／cluster 狀態、延遲、under-replicated、offline partitions 等）。
3. **手改 `alertmanager-generated.yml` 不可行**：C3 在「改告警設定」與「**C3 啟動後約 1 分鐘**」重寫整份（逐位元組還原成它自己產生的版本）；重啟 C3 後手改的 payload 被蓋掉。只重啟 Alertmanager 則保留。C3 不會持續覆蓋（放 5 分鐘不變）。
4. **方案 C（可行）**：systemd drop-in `Environment=CONFIG_PATH=/etc/confluent/alertmanager`，目錄內放自己的 `alertmanager-generated.yml`（Alertmanager 以 cp-control-center 讀）與複製來的 `web-config-am.yml`。實測：重啟 C3 後我們的檔不動、Alertmanager 仍送自訂 JSON（User-Agent Alertmanager/0.34.0）。代價：C3 UI 之後建的動作寫進 C3 自己的檔，**不會生效**（Alertmanager 不讀），C3 通知 reload 時 Alertmanager 重新讀我們的檔，不報錯。
5. 其他：ops02 連 c3-01:9093 被防火牆擋（設計如此），測試要在 c3-01 本機用 `/etc/confluent/ssl/{ca.pem,cp-server.crt,cp-server.key}` 做 mTLS。C3 REST API 需要 Bearer token（向 MDS `/security/1.0/authenticate` 用 AD 帳密換），basic auth 回 401。trigger 的 body 是 protobuf JSON：`{name, clusterId, brokerClusters:{brokerClusters:[id]}, brokerMetric, condition, longValue}`。

6. **兩者同時生效（2026-10-27 實測，方案 E，建議）**：不要讓同一個 Alertmanager 吃兩份設定，而是讓 **Prometheus 把同一筆告警同時送給兩個 Alertmanager**：C3 內建的那個（C3 管，UI 建的動作照常、預設格式）和我們另外跑的第二個（我們管，自訂 JSON）。
   - 做法：`prometheus-generated.yml`（第 13 章我們自己建的，root:confluent 0640，C3 的服務帳號只能讀，**C3 不會重寫它**，重啟 C3 後雜湊不變）的 `alerting.alertmanagers` 加第二個目標 `127.0.0.1:9193`（http）；第二個 Alertmanager 是獨立的 systemd 服務（`--config.file=/etc/confluent/alertmanager-custom/alertmanager.yml --web.listen-address=127.0.0.1:9193 --cluster.listen-address=` 關掉 gossip，因為 C3 的那個已佔 9094），設定檔我們寫：只處理 `rule_created_by="c3-10"`（C3 trigger 產生的告警）、`group_by: ['...']`（一筆告警一個 POST）、webhook 帶 `send_resolved` 與 `payload`；Prometheus 用 `POST /-/reload`（`--web.enable-lifecycle` 已開）重新載入，不用重啟。
   - 實測（真正的 C3 trigger「BROKER_BYTES_IN > 0」觸發）：C3 UI 建的 webhook 收到預設格式 1 筆（標籤有 kafka_broker_id=101、current_metric_value）；第二個 Alertmanager 收到自訂格式 4 筆（broker 101–104 各一筆）。重啟 C3 後兩條路徑都仍運作。
   - 代價：同一個 trigger 若 C3 UI 與我們都設了 webhook，接收端會收到兩份（不同格式、不同時間：C3 的路由預設 group_wait 30 秒，我們設 5 秒）；多一個要維運的服務（用 C3 套件帶的同一支執行檔 `/usr/libexec/confluent-control-center/linux_amd64/alertmanager/alertmanager-amd64`，原廠沒有說可以這樣用，支援立場未知；也可改用開源 Alertmanager 的 tar，走離線引進）；Prometheus 只會把「它自己評估的規則」產生的告警送出去，銀行自己 Prometheus 的規則不經過這裡。
   - 同一個做法也適用於「想把 C3 的告警同時送到別的系統」。
7. **重大發現（手冊缺陷，已修）**：第 13 章我們自己建的 `prometheus-generated.yml` 漏了 C3 套件預設檔裡的 `otlp.promote_resource_attributes: ["host.hostname","java.version","kafka.broker.id","kafka.cluster.id","kafka.version","type"]` 與 `storage.tsdb.out_of_order_time_window: 10m`。沒有前者，指標沒有 `kafka_cluster_id`／`kafka_broker_id` 標籤，**C3 產生的所有 trigger 規則（都帶 kafka_cluster_id=~"…"）永遠比對不到資料，告警不會觸發**，而 C3 畫面看起來正常、之前的驗收也沒測出來。補上後 40 秒內帶標籤的資料點 0 → 78,558，C3 產生的 trigger expr 從 0 筆結果變 4 筆。已改手冊 13 章（設定＋陷阱說明＋驗證指令，預期「7」＝4 broker＋3 controller）與 install 的 prometheus-generated.yml 範本、13 站檢查。

選項（待使用者決定，之前使用者說先不處理）：A 只用 C3 UI（預設格式，要特定格式得加轉換點）；C 方案如上；A+D C3 UI webhook 指到轉換點；銀行自己的 Alertmanager／Dynatrace Events API。詳見 2026-10-26 對話：Dynatrace 對應（ProblemTitle→alertname／summary、ProblemDetailsText→annotations.description（我們規則缺，要補）、State→firing/resolved 轉 OPEN/RESOLVED、ProblemSeverity→要接收端決定、ProblemImpact→要在規則加 impact 標籤）。

### 只保留客戶情境：刪除 Conjur／provider 模式與 CyberArk 應用面（2026-10-27 定案）

- **刪掉什麼**：手把手第 15 章「把密碼搬進 CyberArk Conjur」（Conjur config provider）、Secret Protection 的 16.8（Summon）與 16.9（AD 查詢密碼經 Conjur 注入）、所有 `@only conjur`／`@only provider` 區塊；`conjur`、`provider` 兩種模式；install 的 `15-conjur-provider*.sh`、`lib/vault.sh`；`run-all.sh`／`EXT=1` 與 `OPMENU_SECRETS=conjur` 後端（opmenu 的 `lib/secrets/conjur.sh`）；lab 的 Conjur 容器。
- **為什麼**：客戶的 CyberArk 只有 PAM（PSMP、PVWA、CPM、SSH Key Manager），應用面（Conjur、Summon、CCP／CP）完全不用，這些選配沒有人會走，只增加維護與實測成本。
- **編號位移**：原第 N 章（N ≥ 16）一律變成第 N−1 章：16 Secret Protection→15、17 OP menu→16、18 JMX exporter→17、19 稽核日誌→18、20 驗收→19、21 憑證輪替→20、22 升級→21、23 license→22、24 controller 替換→23、25 broker 擴縮→24、26 中繼資料備份→25、27 OS 修補→26、28 C3 升級→27。手把手現在是第 0–27 章。Secret Protection 內的小節跟著位移，例如原 16.10（bind 驗證）變 15.8。
- **install 步驟改名**：`install/steps/` 由 01–27 變 01–26，`16-secret-protection.sh`→`15-secret-protection.sh`，以此類推到 `27-*`→`26-*`；原 `15-conjur-provider*.sh` 刪除。
- **本檔舊內容不改寫**：以下標了日期的歷史段落沿用**當時的舊編號**與當時討論過的 Conjur／provider 做法，視為歷史；現行做法只看手把手與 install。只有單純指向手把手章節的指標（憑證輪替、升級、備份、master key 保管等）已改成新編號。
- **歷史**：刪除前的完整內容在 git 裡，看刪除這次 commit 之前的版本即可。
- **待辦**：編號與內容都還沒有在 lab 上重跑（Docker 關閉中），必須從零重跑客戶模式（`run-full.sh customer`、`run-customer.sh`、升級演練）之後，才能說新編號驗證過。

### 和客戶討論後的主機存取做法（2026-10-27；已進手冊與腳本，見下一段）

和客戶討論後的做法，與上面「操作機對各主機的 SSH 金鑰，交給 CyberArk 管」那一段（金鑰只放 ssh-agent、不落地、SSH Key Manager 換金鑰）不同。客戶的 CyberArk：有 PAM（PVWA、PSMP、CPM），人員用 AD 帳密登入並已套用 MFA；沒有 CP、CCP、Conjur（對外文件一律不提之後會不會買）。

1. **人員進操作機**：人員先登入 CyberArk 的 PVWA 網頁（AD 帳密加 MFA），在網頁上選目標並啟動連線，背後由 PSMP 代登進操作機（2026-10-27 看銀行實際操作確認；目標是 RHEL 9，所以是 PSMP，不是 PSM），進去就是 root；沒有另外的堡壘機。
2. **一組 SSH 金鑰**：私鑰只放操作機 root（0400），連各主機（含操作機自己）都用它；公鑰放各主機安裝與維運 user 的 `authorized_keys`，可加 `from="操作機 IP"`、`restrict`、`pty`；登入不輸入密碼。
3. **安裝與維運 user 每台都叫 `cpuser`**（取代 cpadmin）：本機帳號、鎖定密碼、只靠金鑰、sshd 對它關閉密碼驗證；每台相同 UID／GID。
4. **sudo**：sudoers 限制指令、NOPASSWD。安裝與升級期是全權（`/etc/sudoers.d/cpuser`），交付後只留窄規則（`cpuser-ops`：重啟、查看狀態、查日誌）。窄規則逐一列出服務名稱，不用 `confluent-*`：sudoers 的 `*` 會比對空格，`systemctl restart confluent-* ` 會連 `confluent-server sshd` 一起放行。（`install/steps/16-opmenu.sh` 已改成逐一列出。）
5. **私鑰不放 CyberArk、不另外備份**：操作機重建時重新產生金鑰對，由 OS 團隊重新佈署公鑰。換金鑰人工做，新舊並存、不中斷（加新公鑰 → 逐台測新金鑰 → 換私鑰 → 刪舊公鑰）。
6. **OP menu**：OS 身分是 root，進選單時再用本人 AD 帳密。Kafka 動作走本人帳密，權限與稽核在 Kafka 端強制；碰主機那段在 root 前提下只是流程控管，繞得過，追溯靠 CyberArk 登入紀錄與 PSMP 錄影。討論過「OP menu 改依 OS 帳號（op／sp 開頭）分選單」：那要 PSMP 代登成角色帳號、私鑰改由專用服務帳號持有，也會放棄「Kafka 動作記到本人」；本案不採用。
7. **CPM 與零停機輪替**：CPM 還在，所以 A/B 兩組帳密與 CPM 自動輪替仍衝突（CPM 不知道哪組在用）。`svc-mds-bind` 維持單帳號、CPM 輪替，接受 MDS 查 AD 的短暫失敗；要零停機才改 A/B、關掉該帳號的 CPM 自動變更。SCRAM 應用帳號 CPM 沒有 Kafka plugin，一律人工。
8. **客戶提到「私鑰放不同 file system」**（2026-10-27）：客戶沒說原因，我方選最可能的目的——防磁碟、VM 快照或備份被取走後離線讀取——寫進 Word 4.2：私鑰放獨立且加密（LUKS）的 file system（例如 `/secure/ssh`），備份與快照排除該掛載點，要支援 POSIX 權限（xfs／ext4）。分開本身沒有安全效果（人員是 root，已掛載的都讀得到），效果來自加密與排除備份；掛載失敗時 ssh 連不上各主機，需要處理流程。實際原因待客戶確認。

**原本列為尚未改的地方**（手冊 3.1／15.x 的 ssh-agent 貼法、19.6 SSH Key Manager 演練、cpadmin 全部改 cpuser；`install/` 腳本與 `bank-sim.sh`；OP menu 的 ssh-agent 流程；sudoers 窄規則）：2026-10-27 當天已全部改進手冊與腳本，見下一段；**尚未從零重跑**。

**已產出的文件**：`docs/Confluent-CyberArk登入與主機存取設計.docx`（資拓宏宇風格，來源 `docs/access-src/`，`node ../journey-src/build.js access.md ../<輸出>.docx ./diagrams.js`）。2026-10-27 已在 lab（11 台）實測文件的步驟：cpuser、金鑰登入、from= 擋別台、兩種 sudoers 規則、換金鑰 5 輪都通過；修了 from= 要含 ::1、sudoers 比對完整參數、換私鑰要連 .pub 成對更換三處。LUKS 與 ext4／xfs 只用 tmpfs 驗證，未測。桌面的「整理 kafka 客戶資訊」簡報重新分析後的版本已刪除（使用者決定，不需要）。

### 新做法已進手冊與腳本（2026-10-27）

**改了什麼**（客戶同意的做法，全部取代 cpadmin／ssh-agent／SSH Key Manager 那一套）：
- **登入**：人員在 PVWA 網頁登入（AD 帳密＋MFA）、選操作機按連線，PSMP 代登，進去是 root；沒有堡壘機。手冊所有「小安 | ops02 | cpadmin」改成 root；blocks 裡 ops02 本機的 `sudo` 拿掉。
- **一組金鑰**：操作機 `/secure/ssh/cpuser_ed25519`（root、0400，獨立加密 file system），ssh 到所有主機含自己；`~/.ssh/config` 讓手打的 `ssh kb01.poc.lab`、`scp` 都用它；註解 `cpuser-ops-<日期>`。不放 CyberArk、不備份。
- **cpuser**：每台本機帳號，UID／GID 1500、家目錄 /home/cpuser、鎖定密碼、`/etc/ssh/sshd_config.d/50-cpuser.conf`（`Match User cpuser`／`PasswordAuthentication no`／`AuthenticationMethods publickey`）；`authorized_keys` 只有 `from="<ops02 IP>,127.0.0.1,::1"`。
- **sudo**：安裝期 `/etc/sudoers.d/cpuser`（全權），交付後只留 `cpuser-ops`，逐一列出每個服務與指令寫法：`systemctl restart|status <服務>`、`journalctl -u <服務> -n 200 --no-pager`（服務只有 confluent-server、confluent-kafka-rest、confluent-control-center，每台只列自己的）。
- **換金鑰**：人工，手冊 19.6（新舊並存：產生 `.new` → 用舊鑰加新公鑰 → 逐台測新鑰 → 成對換私鑰與 `.pub` → 依註解刪舊公鑰與舊私鑰）。探針（每 0.2 秒連一次）預期：全程最多失敗 1 次，發生在換私鑰的瞬間，其他 0 次。
- **OP menu**：以 root 在操作機跑；主機 ssh 直接用金鑰檔（`OPMENU_SSH_KEY_FILE`），拿掉 ssh-agent 載入／`OPMENU_SSH_KEY_LOAD`／`OPMENU_SSH_KEY_SECRET`／`OPMENU_SSH_USER=cpadmin`；`lib/secrets/manual.sh` 留著，只給 91 緊急憑證用。看日誌改固定寫法（遠端 `-n 200 --no-pager`，本機 `tail`），收集診斷改逐服務（原本 `confluent-*`）。選單的主機權限閘門在 root 前提下是流程控管；緊急主機模式的 OS 群組變成「把 root 加進群組」的開關。
- **問題清單**：4.2–4.6、8.3、8.4、8.8、9.1、9.3 改寫；hidepid 那題（原 4.6）改成接受風險（4.8）。

**lab 怎麼模擬**：
- 沒有 PVWA／PSMP：lab 直接 `docker exec -it -w /root lab-ops02-1 bash`（root）；`~/kafka-lab/pvwa/` 只放平台密碼，不放 ssh 私鑰。
- 沒有 LUKS：compose 加一個具名 volume `ops-secure` 掛在 ops02 的 `/secure/ssh`（獨立掛載點，重啟還在，沒有加密）；`ops-home` 掛 `/root`。
- 銀行的動作：`install/lab/bank-sim.sh prepare`（和手冊 3.1.1／3.1.3 一樣）對每台主機（含 ops02）以 root 建 cpuser、sshd 設定、安裝期 sudo、放公鑰行；repo01 的 repodeploy 放同一行。原本共用的 `authorized_keys.d` volume 拿掉。映像不再內建 cpadmin 與 sudoers。
- CPM 與 SSH Key Manager 不模擬。

**還沒做／沒驗證**：全部只做了靜態檢查（bash -n、shellcheck、單元測試、文件建置）；lab 舊叢集已壞，等從零重建後用 `run-full.sh customer`、`run-customer.sh` 跑。要特別看：`mountpoint /secure/ssh` 在容器裡是否成立；`cpuser`（`!!` 鎖定）以金鑰登入；3.1.5 的 `from=` 拒絕訊息；16.4 窄規則的 9 種寫法結果；19.6 探針的失敗次數；`opmenu-hostkey-test.sh`、`opmenu-emergency-test.sh`（root 加進 opmenu-emergency 群組後 `runuser` 會不會讀到新群組）。

### 監控改成外部 Prometheus／Alertmanager／Grafana + JMX exporter（2026-10-27 定案）

**決定（使用者）**：監控與告警用 JMX exporter ＋ 銀行提供的 Prometheus、Alertmanager、Grafana，**不用 C3 內建的 Prometheus／Alertmanager 做告警**；收 C3、REST Proxy、broker、controller 的指標；匯入 Confluent 官方**全部** Grafana dashboard；告警用推薦規則。

- **誰提供什麼**：Prometheus、Alertmanager、Grafana 由銀行提供，我方交付設定（exporter 規則、scrape 設定、告警規則、Alertmanager 設定、Grafana datasource 與 dashboard）。lab 的 bank-sim 用 `lab-mon-prometheus／alertmanager／grafana／webhook` 四個容器扮演（`install/lab/bank-sim.sh monitoring`，收掉用 `monitoring-stop`；`reset` 會先收）。
- **C3 內建的不動**：C3 畫面還要用，第 13 章 otlp 設定照舊。手冊明講：告警與 dashboard 只走外部這套，不在 C3 建 alert trigger／action。手冊第 13 章原有「C3 畫面上建的 trigger 不會觸發」的字句已改成「C3 畫面的圖會空」。
- **官方來源**：`confluentinc/jmx-monitoring-stacks`（Apache-2.0），固定 commit `f376263fc6d7270185ab6abab9a8c379079e2a92`（2026-05-28，沒有 tag）。在下載機（第 1.4 站）用 GitHub 的 commit tarball 只取要用的路徑（47 個檔），放 `landing/monitoring/`，列進 `SHA256SUMS`（第 1.6 站），經第 2 站進操作機。repo 本身只放我們自己的設定與範本，不放官方 JSON。
- **exporter 規則**：一律用官方檔（controller `kafka_controller.yml`、broker `kafka_broker.yml`、REST `confluent_rest.yml`），前面接我們的 `httpServer` 標頭（HTTPS 用主機憑證；2026-10-31 起不要帳密，見下面「7071 只用 HTTPS」）。官方檔第一行的 `---` 要拿掉；官方自帶 `startDelaySeconds: 120`，controller、broker 重啟後前兩分鐘 7071 回 200 但沒有指標，驗證要等。舊的手寫 `jmx-rules-kafka.yml`、`jmx-rules-rest.yml`、`alert-rules.yml` 已刪。
- **job 與標籤**（dashboard 寫死）：`kafka-controller`、`kafka-broker`、`rest-proxy`、`control-center`；`env`（lab 用 `lab`）；`hostname` 由 `__address__` relabel。scrape 設定用 `scrape_config_files` 引用，不併進 `prometheus.yml`。
- **Grafana 要修兩件事**（實測）：(1) 官方 JSON 是匯入畫面格式，datasource 寫成 `${Prometheus}`，檔案佈建不替換（後端 `Data source not found`）→ 改成固定 uid `Prometheus`，datasource 也用這個 uid；(2) 四組 ZooKeeper／KRaft 成對的 dashboard 共用 uid（`kafka-cluster`、`kafka-topics`、`confluent-platform` 與 `kafka-stream`／`globalktable`），Grafana 只收第一個 → 重複的改 uid 並在標題加檔名。其餘 32 個原樣放，沒有對應元件的（Connect、ksqlDB、SR、Flink …）就是空的。
- **C3 能給什麼（lab 實測，2026-10-27）**：C3 沒有官方 exporter 設定。掛法：`CONTROL_CENTER_OPTS=-javaagent:…=7071:設定檔`（`control-center-run-class` 讀這個變數；只能放**一個** `-javaagent`，放兩個時 `-check_dir` 讀不到 `java.io.tmpdir`，C3 不起來）。C3 的 JVM 有兩萬多條序列，幾乎全是雜訊（`kafka_rest_jersey_*` 5,586、consumer 3,306、producer 1,913、streams／RocksDB 880、admin 470、Jetty 384 …）。我們只放行：JVM／process（內建 collector）、Kafka Streams `client_state`（0 CREATED、1 REBALANCING、2 RUNNING … 6 ERROR）／`alive_stream_threads`／`failed_stream_threads`、Jetty `request_rate`／`request_error_rate`，約 100 條。**C3 不給**：它處理了多少 telemetry、alert history、RocksDB 狀態（可加規則但序列數大）、使用者活動。官方沒有 C3 專用的 dashboard，`kafka-stream.json`／`kafka-streams-rocksdb.json` 對 C3 也是空的（我們沒放行那些序列）。
- **raft 指標（推翻 2026-10-25 的結論，待在三台 controller 的 lab 再驗）**：用官方規則抓，controller 與 broker 的 `kafka_server_raft_metrics_*`（current_leader、current_epoch、current_vote、number_of_voters、number_unknown_voter_connections、high_watermark、log_end_offset、append／fetch_records_rate、commit／election latency、poll_idle_ratio）**都有值**，官方 `kraft.json` 18／18 panel 有資料。2026-10-25 的 jshell 查不到的原因沒查清（那次是三台 controller 的 dynamic quorum，這次是單 controller `--standalone`；也可能是 jshell 的 MBean 查詢範圍或當時的 includeObjectNames 擋掉了 `kafka.server:type=raft-metrics`）。README「已知限制」第一條與手冊 17.10 的備註都改成「待複驗」。已據此加 `KRaftNoLeader`、`KRaftUnknownVoterConnections` 兩條告警。
- **哪些 dashboard／panel 有資料**：測試環境單 controller／broker／REST／C3、3 個 partition 的 topic、無 RBAC／audit／quota：32 個 dashboard、816 個 panel、253 個有資料（`docs/journey-src/tools/dashboard-coverage.py` 量；手冊 17.9 有完整表）。可用：`kraft.json` 18／18、`kafka-cluster-kraft.json` 75／80、`kafka-topics-kraft.json` 13／13、`kafka-transaction-coordinator.json` 10／10、`rest-proxy.json` 10／10、`confluent-audit.json` 5／6。**不通的 panel（Confluent Server 加專用 controller 的 KRaft）**：`kafka-cluster-kraft.json`「Offline Partitions Count」、`kafka-topics.json`「Total # of Topics／Partitions」、`kafka-cluster.json`／`confluent-platform.json` 的「Active Controllers」等——官方 query 把 controller 指標寫成 `job="kafka-broker"`，但專用 controller 的叢集裡這些只在 `job="kafka-controller"`（ZooKeeper 時代與 combined mode 才在 broker 上）；沒改官方 JSON（升級官方版本時才不用重修），告警 `KafkaOfflinePartitions` 有涵蓋。Tiered Storage、Cluster Linking 的 panel 沒開功能時是空的。**未驗證**：`confluent-rbac.json`（要 MDS／RBAC）、`kafka-quotas.json`（要設 quota）、稽核的 fallback panel——測試叢集沒開，要在正常 lab 補驗。
- **audit 與 quota dashboard（2026-10-31，Podman 從零重跑、8.3.2、稽核已開）**：`confluent-audit.json` 0／6，原因是 8.3.2 的 broker 沒有官方規則對應的 MBean `kafka.server:type=confluent-audit-metrics`（jshell attach 列全部 5,452 個 MBean 確認；稽核只以 producer `confluent-event-logger` 出現），手冊原寫的「啟用後 5／6」無法重現、已刪。`kafka-quotas.json` 0／6 是因為 `type=Produce,user=…` 只在有配額的帳號有流量時存在（閒置約 1 小時就消失），量的時候沒有流量。待確認：稽核寫入失敗要不要用 `confluent-event-logger` 的 producer 指標（record-error-rate）告警。
- **告警規則（22 條，`install/templates/confluent-alerts.yml`，每條都有 `severity`、`impact`、`summary`、`description`，註解標出處）**：
  - `official`（jmx-monitoring-stacks `prometheus-alerts/`）：`ConfluentTargetDown`（service_down，縮到我們四個 job）、`KafkaActiveControllerCountNotOne`、`KafkaOfflinePartitions`、`KafkaUncleanLeaderElections`（官方 `> 0` 對累計次數永遠成立，改看 10 分鐘增量）、`KafkaUnderReplicatedPartitions`（`for` 1 分改 5 分，滾動重啟會短暫 under-replicated）、`KafkaUnderMinIsrPartitions`。不收：官方兩條「Broker IO Activity」（用一個永遠小於 1 的 control-plane 指標，等於測試規則）、`high_load`（要 node exporter）、connector／zookeeper 規則（沒有元件）。
  - `confluent`（Confluent 監控指引）：`KafkaIsrShrinkingWithoutExpand`、`KafkaNetworkProcessorBusy`、`KafkaProduceLatencyHigh`（p99 > 500 ms）、`KRaftNoLeader`、`KRaftUnknownVoterConnections`。
  - `ours`：`KafkaRequestHandlerBusy`（官方有 `requesthandleravgidlepercent` 的累計值與 `_oneminuterate` 兩條序列，用後者）、`KRaftControllerMetadataLag`、`KRaftMetadataErrors`、`KRaftLeaderFlapping`（2026-10-25 的 controller 指標告警，保留）、`RestProxyErrors`（把每個 endpoint 的 `request_error_rate` 加總）、`RestProxyThreadPoolBusy`、`ControlCenterStreamsNotRunning`、`ControlCenterStreamThreadsFailed`、`JvmHeapHigh`、`JvmFileDescriptorsHigh`。每條 lab 都確認過指標存在；沒有 consumer lag 規則（lag 不是 broker 的 JMX 指標）。
- **Alertmanager webhook 兩個範例**（`install/templates/alertmanager.yml`）：(a) 預設 JSON（version 4）；(b) `payload` 字串寫法加 `toJson`，欄位照 Dynatrace 問題通知（`State` OPEN／RESOLVED、`ProblemTitle`、`ProblemSeverity`（critical 對 ERROR，其餘 PERFORMANCE，範例）、`ProblemImpact`（規則的 `impact` 標籤）、`ProblemDetailsText`（規則的 `description` 註解）、`ProblemID`（Fingerprint，因為範本拿不到 `.GroupKey`）、`ImpactedEntity`、`Tags`、`StartTime`）。`group_by: ['...']` 一筆告警一個 POST。Alertmanager 0.34.1 實測：兩種都送達；`description` 含雙引號、冒號、`007` 都完整；Alertmanager 會把渲染結果重新編碼，所以鍵變成字母順序。接收端：lab 用 `lab-node:1` 跑十行的 `python3 http.server`，印出收到的 POST（ncat 會掉輸出）。
- **解除的行為（實測）**：把測試規則拿掉並 reload，Prometheus 不會對被拿掉的規則補送 resolved；Alertmanager 等告警過期（Prometheus 送的告警 `endsAt` 約 4 分鐘）才解除，再下一輪通知（`group_interval` 1 分）送 resolved，約 3–5 分鐘。真實的告警是條件消失，Prometheus 會直接送 resolved。把規則改成永遠不成立（`vector(1) < 0`）也沒有立刻的 resolved（改了 expr 就是新規則，舊的狀態直接丟掉）。
- **lab 陷阱**：(1) Alertmanager 在 lab（172.35.x.x 不是私有位址）起不來，`--cluster.listen-address=` 留空關掉 gossip（和 2026-10-26 在 C3 那個一樣）；(2) Prometheus 容器要用 `--add-host`；(3) `docker compose down -v` 前要先收 `lab-mon-*`（接在 labnet 上，網路刪不掉）；(4) Windows Git Bash 的 `python3` 是 Microsoft Store 的空殼，什麼都不印也不報錯，所有 Python 都要放進容器（`lab-node:1`）或操作機執行；(5) `sudo wc -l < 檔` 的 `<` 是用呼叫者身分開檔，會 Permission denied（舊的 install 17 站有同一個問題，已修）。
- **資源**：Prometheus 600 MB、Alertmanager 128 MB、Grafana 400 MB、webhook 64 MB（上限；實際約 77／19／90／10 MB）。
- **待銀行確認**：問題清單 11.1（四樣都由銀行提供？版本）、11.5（webhook 接收端與格式、token）、11.6（Grafana 佈建與登入）、11.7（Prometheus 容量）、11.8（確認不依賴 C3 告警）。
- **這次 lab 的限制**：叢集是舊的 provider 模式安裝，Conjur 已刪，cold boot 後 controller／broker／REST／C3 都因 `UnknownHostException: conjur.poc.lab` 起不來（crash loop）。照規則沒有修，改用拋棄式環境驗證：`lab-mon-kc／kb／rest／c3`（`lab-mon-cp:1` 映像：Confluent 8.3.2 與 C3 2.6.1 的 RPM 加 JDK 21，單 controller、單 broker、單 REST、單 C3，同一套 exporter 設定與 jar；同一張 `cp-server.p12` 的 SAN 涵蓋所有主機名）。真實主機只做了「派送 jar、設定、drop-in 加 daemon-reload」（`systemctl show -p Environment` 看得到 javaagent），**沒有重啟任何一台**。要正式驗收，從零重跑 lab 之後做第 17 章。

### 企業需求缺口分析（2026-10-24，對照原廠文件；使用者定案）

**2026-10-25 進度（lab 實跑）**：license 監控（第 23 章＋`23-license.sh`）、controller 替換（第 24 章＋`24-controller-replace.sh`）、broker 縮減／擴充（第 25 章＋`25-broker-scale.sh`）、日常備份（第 26 章）、換鏈（21.4＋`21-cert-rotate.sh chain`）都已實作並實跑。補強：第 6 章資料碟檔案系統檢查、10.3 `java.io.tmpdir` 選配（kb04 實測）、第 10 章明確設定 `metadata.log.dir`（kc01、kb01 實測）、第 18 章 KRaft quorum 告警、第 19 章稽核 topic RF 3 確認、第 22 章 JDK 25 註記。
- **raft 指標的完整結論（2026-10-25 lab 實測）**：JMX 沒有 `raft-metrics`；Confluent telemetry 有（`io.confluent.kafka.server/raft/*`，只在 kc02 白名單加 `io.confluent.kafka.server.raft.(?!.*delta).*` 時 C3 Prometheus 收到正確值）。但 C3 內建 Prometheus 收的 telemetry 沒有主機標籤，多台同名序列互撞 → out of order（400，整批被拒）；delta 類型 500。→ 不改 C3 白名單，quorum 告警用 JMX 的 controller 指標。
- **更正**：下面「README 說『不以 JMX 提供 raft 指標』與原廠文件矛盾」不成立。Apache Kafka 有 `kafka.server:type=raft-metrics`，但 Confluent Server 8.3.2 的 controller 上沒有這組 MBean（jshell 連進 JVM 列出全部 MBean 確認）；quorum 告警改用 controller 的 `LastAppliedRecordLagMs`、`MetadataErrorCount`、`NewActiveControllersCount`（第 18 章新增 3 條規則，行內 Prometheus 實測載入 12 條）。
- 第 19 章：兩個稽核 topic 本來就是 RF 3（`min.insync.replicas=1`），不用改；文件補上檢查指令與「可送專用稽核叢集」。

- 新章（先做）：**License 套用與到期監控**、**Controller 替換／增減（dynamic quorum）**、**Broker 擴充／縮減（Self-Balancing）**。都照「手打實跑 → 手把手 → 腳本」。
  - 已定案但這次沒選先做：日常備份、OS 修補、C3 升級；另列待議：滾動重啟 SOP、容量規劃、災難備援（Cluster Linking，lab 記憶體要評估）、Tiered Storage。
- 現有章節**全部補強**：
  - 第 3 章：主機在 VMware 時停用 vMotion 與磁碟快照（原廠：可能造成整個叢集中斷）；Kafka 資料碟與 OS 碟分開、RAID 10 優先、RAID 5 不建議。
  - 第 6／7 章：檔案系統 XFS／ext4 檢查；`java.io.tmpdir` 指到可執行的目錄，讓銀行的 `/tmp` 可以維持 noexec。
  - 第 10 章：明確設定 `metadata.log.dir`。
  - 第 18 章：KRaft quorum 告警（`kafka.server:type=raft-metrics`）；README 說「Confluent Server 不以 JMX 提供 raft 指標」與原廠文件矛盾，lab 實測後更正。
  - 第 19 章：稽核 topic 的 replication factor 應為 3；原廠建議可考慮送到專用叢集。
  - 第 22 章：註明 JDK 25 是支援版本、原廠建議仍是 21。
- 已自行抽查的原廠原文：trial 30 天、到期後 C3 起不來、Confluent Server 能起但持續報錯（license 頁）；vMotion／快照、RAID 10、XFS／ext4、用完整 JDK（deployment 頁）。子代理說原廠建議 `noatime`，該頁沒有寫，不採用。

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
| 原廠（Confluent） | `confluent.metadata.server.token.key.passphrase`（讓 MDS 讀 PKCS#8 加密的 token 私鑰）原廠文件查不到（8.3 MDS 設定參考只有 token.key.path／max.lifetime.ms／signature.algorithm），lab 試過可用：是否正式支援、會不會補文件？MDS token 公鑰檔能否放多把（做零中斷金鑰輪替）？ |
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
- 2026-10-22 已改程式並在 lab 實測（opmenu/，commit 待）：拿掉 docker 後端、ticket、清日誌、維護模式；新增 lib/secrets/{conjur,ccp}.sh（conjur 後端已於 2026-10-27 刪除）；
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

## 安裝基底改 8.2.x，主線遷移到 8.3.x／JDK 25／OS 9.8（2026-10-27 定案）

**決定**（使用者 2026-10-27 夜間，不再問）：原本「裝 8.3.2＋JDK 21 在 Rocky 9.8，升級另當一次演練」改成**主線就是遷移**。第 1–20 章裝**安裝基底**，第 21、26、27 章遷移到目標版本，章號 0–27 與站號 01–26 不變。
前面「升級與日常修補」一節裡的「lab 演練：用 install/ 以 8.2.4 從零裝一套再升」與 `run-upgrade-drill.sh`**已併入主線**（`install/lab/run-customer.sh` 一條路跑完，`run-upgrade-drill.sh`、`run-all.sh` 已刪），升級不再是選配。

| 層 | 安裝基底（第 1–20 章） | 遷移目標 | 在哪一章 | 依據／限制 |
|---|---|---|---|---|
| Confluent Platform | 8.2.4 | 8.3.2 | 21 | 套件滾動升級→JDK→finalize（features 4.3，之後不能退） |
| Control Center | **2.5.1** | 2.6.1 | 21.3（先升）、27 | 原廠相容表（docs.confluent.io Versions and interoperability，2026-10-28 查）：C3 2.5.x＝CP 7.5.11 以上、7.6.8 以上，到 8.2.x；2.6.x＝7.5.15 以上到 8.3.x。2.5.x 不支援 8.3，所以 CP 升 8.3 之前 C3 一定先升；2.6.x 也涵蓋 8.2.x，所以 C3 先升到 2.6.1 配著 8.2.4 仍在支援範圍內 |
| JDK | 21 | 25 | 21.7 | 8.2.x 只支援 Java 17／21，8.3.x 支援 17／21／25（原廠建議仍是 21）。基底只能是 21；C3 留在 21（原廠沒寫 C3 2.6 支援 25） |
| OS（RHEL 9） | 9.6 | 9.8 | 26.0–26.5 | 小版本更新；Confluent 與 JDK 被 versionlock／tar 擋住，只動 OS 套件 |

**C3 基底版本的證據**：2.5.x 的最新版是 2.5.1（2026-06-23）；原廠 release notes 2.5.0–2.6.1 沒有 OTLP／telemetry 設定的變更、沒有標示 breaking change。兩個 RPM 都只相依 bash；把 2.5.1 和 2.6.1 RPM 的 `/etc/confluent-control-center/` 逐檔比對（2026-10-28，各取前 30 MB 的 payload），唯一差別是 `control-center-dev.properties` 多一行 `confluent.controlcenter.docs.host`（2.6.0 新增，我們不用 dev 檔）；`prometheus-generated-local.yml` 的 `otlp`／`storage` 兩段兩版逐字相同，所以第 13 章設定兩版通用。2.6.1 的升級注意：舊的 JavaMail 寄信功能移除（我們不用 C3 的告警動作，不影響）。已知問題：CP 8.3.x 上用 OAuth client assertion 的元件起不來（我們不用 OAuth）。

**落地區版面**：`landing/rpm/` = 基底（CP 8.2.4×10＋C3 2.5.1）、`landing/rpm-target/` = 目標（8.3.2×10＋C3 2.6.1）、`landing/bank/` = JDK 21 與 25、`landing/c3/` = 第 27 章帶進來的單一 C3 版本（2.6.0，演練用）。SHA256SUMS 涵蓋 `rpm rpm-target tools gpg-keys monitoring`（72 行）。兩套一次掃描、一次送進去（約 6 GB），遷移時只在內部套件庫上架（21.1），不用再開單。`landing-extra/` 取消。
OS 內容（9.6 完整套件庫、9.6→9.8 更新集合）是**銀行套件庫的內容**，不是我們交付的檔案，所以不在落地區：lab 放在 `~/kafka-lab/bank-os/{9.6,9.8-updates,9.8}`，由 `bank-sim.sh os-content` 在拋棄式容器裡備好；`landing/os-packages.txt` 只是給銀行的清單（9.6 的版本號）。

**lab 的事實與陷阱**（2026-10-27/28 驗證）：
- `rockylinux/rockylinux:9.6` 映像裡預設 repo 的 mirrorlist 用 `$releasever`（=9），`dnf install` 會裝到**最新的 9.8 套件**，必須改用 vault（`dl.rockylinux.org/vault/rocky/9.6/{BaseOS,AppStream,extras}`）；9.6 不在 `pub/`，9.8 不在 vault。映像 tag 改 `lab-node:96`、`lab-web:96`，舊的 9.8 映像是 `lab-node:1`，不會被誤用。vault 9.6 裡的套件比映像新（glibc el9_6.14 → el9_6.24），映像建置時 `dnf update` 一次，起點才是「9.6 最新修補」。
- 拋棄式容器驗證（`rockylinux:9.6` → `lab-mig-node:96`）：9.6 套件集合（同一份套件清單、先下載再裝工具）71 個 RPM、20 MB、約 53–97 秒；裝好之後對 `pub/rocky/9.8` 做 `dnf update --downloadonly`：148 個待更新、更新集合 152 個 RPM、78 MB、約 160 秒（無 kernel：容器沒有）；用本地 repo（createrepo）`dnf update` 9 秒到 `/etc/rocky-release` = 9.8；versionlock 鎖住的 `jq` 不動（與 Confluent 的 versionlock 同機制）；systemd 容器更新 glibc／systemd 後仍是 running、sshd／chronyd active；`dnf needs-restarting -r` 說要重開機（glibc、systemd、dbus-broker）。9.6、9.8 的 RPM 簽章都用同一把 `RPM-GPG-KEY-Rocky-9`，`gpgcheck=1` 可以維持。
- 容器不能重開機：`systemctl reboot` 回「Call to Reboot failed: Could not activate remote peer」（logind 被 mask）；`systemd-detect-virt -c` 在 lab 回 `wsl`。第 26 章、`26-os-patch.sh`、`rest-restart.sh -r` 遇到容器就改重啟平台服務（讓 JVM 載入新的 glibc）。**這不是重開機的驗證**：開機順序、fstab、網卡、核心模組、kernel 更新都沒測到，正式環境第一次要排變更窗口並先在測試環境走一遍。
- dnf 陷阱：用 `--downloaddir` 下載的更新集合，如果同一個目錄又拿來當 `file://` repo 並執行 `dnf update`，RPM 在裝完後會被刪掉（實測目錄只剩 repodata）。先複製出一份再建索引。
- Rocky 不是 RHEL：訂閱管理（`subscription-manager release --set`）、Satellite content view 的行為 lab 都沒有；RHEL 小版本不支援降版，回滾答案是更新前的 VM 快照。

**程序（對應手把手）**：21.1 目標版本上架（基底留著）→ 21.3 C3 先換（`c3-change.sh` 在這裡建，27 沿用）→ 21.4–21.6 套件（broker→controller→REST→操作機）→ 21.7 JDK 25 → 21.8 finalize → 21.10 確認版本、記下新基準（`21-upgrade.sh adopt` 改 `site.env`）；26.0 銀行同步套件庫到 9.8 → 26.1 預覽（`dnf upgrade --assumeno`）→ 26.2–26.4 逐台更新 → 26.5 驗證、限制、回滾、換成別的小版本；27 單獨換 C3 版本（2.6.0 退回、升回 2.6.1）。`install/lab/run-customer.sh` 一條路：基底→驗收→憑證換發→遷移（每段驗收、持續流量）→ 22–25 → OS 9.8（持續流量）→ 27 → 驗收。

**尚未驗證（要等從零重跑）**：整條路在 lab 上的實跑（手把手與腳本都是）、第 17 章在 8.2.4／2.5.1 上的指標覆蓋（表格是 8.3.2／2.6.1 的實測）、C3 2.5.1 → 2.6.1 的換版本行為（generated 檔擁有者）、小版本更新在 11 台上的時間與持續流量數字、各章 `out` 區塊的新數字（第 21 章的實測數字仍是 2026-10-26 升級演練的，標在文中）。

**待問客戶**（已進問題清單）：行內套件庫現在的 RHEL 小版本、是釘版還是追最新、何時同步（3.5）；JDK 要不要換 25（3.4）；兩套 RPM 約 6 GB 能否一次送（2.5）。

### 與 CyberArk 脫鉤：平台密碼與金鑰不再放 PVWA（2026-10-28 定案）

使用者說明並確認：Kafka lab 與 CyberArk 已脫鉤，**只剩一件事和 CyberArk 有關**：人員登入 CyberArk（PVWA 網頁，AD＋MFA）→ PSMP 代登 → 進操作機是 root；root 才讀得到 `/secure/ssh` 的 cpuser 私鑰（0400）。

- 平台的密碼與金鑰（Secret Protection 的 passphrase 與 master key、`svc-mds-bind`、測試人員密碼、應用程式 SCRAM、`store.pass`、`kafka-admin`、緊急憑證 `opmenu-breakglass`、JMX 抓取密碼、`confluent-audit`、license）**全部只留在操作機 root 才讀得到的位置（0600）**，不再交 Secrets 團隊存進 PVWA、不再「從 PVWA 取出」。
- CPM 輪替（root、`svc-mds-bind`）全部拿掉，改手動輪替。`svc-mds-bind` **維持單一帳號**（2026-10-30 使用者確認：銀行 AD 通常只給一個服務帳號）：AD 換密碼與平台更新密文、滾動重啟排在同一張變更單、同一個時段（手把手 20.4）；銀行願意給兩組時才改 A／B（問題清單 8.5）。A／B 只用在應用程式的 SCRAM 帳號（20.6）。
- 後果要在文件講清楚：①操作機掉了，passphrase 就沒了（master key 還在各主機的 service.env），所以 `~/secrets`、`~/pki` 的備份由銀行自己的備份機制處理（問題清單新增一題）；②OP menu 91 緊急憑證改成讀操作機上的檔，不再從 PVWA 貼上；操作者本來就是 root，91 的把關只剩「必填原因＋稽核記錄」，不是硬性隔離。
- 動到：手把手第 0、3、11、15、16、17、18、19、20、25 章與 6465 行 license；install（site.env、15／16／19／20 站、lab 的 bank-sim／run-customer、opmenu 的 91 取憑證方式與提示字、README）；問題清單；README／CLAUDE.md；CyberArk 登入設計 Word（只保留登入與金鑰那段）。

### super user 只剩 kafka-internal；svc-ops、kafka-admin 改綁 RBAC SystemAdmin（2026-10-28 定案）

- 使用者指出：授權判斷在每台 broker 的 authorizer（binding 讀自 `_confluent-metadata-auth`），MDS 的 REST／AD 掛掉不影響授權；`kafka-admin` 走 SCRAM（憑據在 KRaft）所以認證也不靠 MDS／AD。因此人用的緊急帳號不需要 `super.users`。authorizer 本身起不來時 `super.users` 也救不了（檢查就在 authorizer 裡）。
- 定案：`super.users=User:kafka-internal`；`svc-ops`、`kafka-admin` 都綁 `SystemAdmin`；第 11 章 bootstrap 用 `kafka-internal` 憑證登入 MDS 建第一條 binding（`User:svc-ops → SystemAdmin`），之後全部用 `svc-ops`。
- 新增驗證（第 11 章或第 19 章）：停 ad01 → alice 向 MDS 要 token 失敗、`kafka-admin` 從 9095 仍可列／建 topic → 開回 ad01、alice 恢復。
- 動到：第 10 章（`common.tpl` 的 super.users、說明）、第 11 章開頭與 `rbac.txt`、11.2、第 19 章「svc-ops 是 super user」的收尾說明；install 10／11 站；README／CLAUDE.md。等目前腳本重跑結束後改，再從零重跑。

### C3 的 JDK 也換成 25（2026-10-28 定案）

- 原本「C3 留在 21」的理由是原廠對 Control Center 只寫「最低 Java 17」、沒明列 25（[Control Center System Requirements](https://docs.confluent.io/control-center/current/installation/system-requirements.html)），CP 8.3 的建議版本也是 21（[Supported Versions](https://docs.confluent.io/platform/current/installation/versions-interoperability.html)）。使用者決定全部節點一致用 25；手冊 29.7、29.10、第 31 章表格、`29-upgrade.sh jdk`、`run-customer.sh expect_versions`、README 已改。上線前向原廠支援確認 C3 2.6 在 Java 25 的支援。**尚未實跑**（下一輪從零）。

### 應用程式 SCRAM 帳號一律 A／B 兩個（2026-10-29 做完）

- 第 11 章／11 站對 `apps.txt` 裡 scram 類的應用各建 `<app>-a`、`<app>-b`（同一組 binding 與配額；`rbac.txt` 明寫兩行）；驗收、稽核、持續流量用 -a（`FIRST_SCRAM_ACCOUNT`）。
- 20.6：手動輪替演練（-a 背景寫入 600 筆 0 錯誤、換 -b、新密碼成功舊密碼被拒、應用切到 -b 寫讀一筆）；16.5／16 站加 OP menu 35 的試跑（用 app-payments）。19 站多兩項：-a、-b 都能登入（42/42）。
- lab 實測：2026-10-29 凌晨手動 11 章 12/12、19 站 42/42、20.6 手動通過。

### 補章做完：22、24、27、28、23.6、20.6、30 保險（2026-10-29）

- **第 24 章 磁碟與容量**：`kafka-log-dirs` 整理每台合計與最大 topic；第二個規則檔 `confluent-alerts-disk.yml`（`KafkaLogDirOffline` 我方、`KafkaDataDiskFillingUp` 給銀行 node_exporter 的範例）；縮短 retention 與 `kafka-reassign-partitions` 在 lab 實做。空間不是改完就回來：等 broker 的 retention 檢查（預設 5 分鐘）。
- **第 28 章 故障排查**：症狀表 → 一分鐘快照 → 「一台 broker 掉了」演練（告警 firing 300 秒、重啟後 20 秒歸零）→ 錯誤訊息表 → 選單 18 收 diagnostics。
- **第 27 章 新應用上線**：兩種應用（SCRAM A／B 直連、憑證走 REST）。**REST Proxy 只放行白名單 CN**（第 12 章 `auth.ssl.principal.mapping.rules`，來源 `apps.txt`）：新 REST 應用要把 CN 加進兩台 REST 的規則並照 12.1 重啟；腳本版是改 `apps.txt` 重跑第 12 站。REST v3 produce 一律 HTTP 200，成敗看回應的 `error_code`。
- **第 22 章 憑證到期監控（選配）**：銀行 Prometheus 的 blackbox_exporter `tls` 模組探 24 個端點（mTLS 的 listener 也會出示 server 憑證，不需 client 憑證）＋三條規則＋`promtool test rules`；操作機每天 `cert-expiry.sh` 讀 `~/pki/certs`（含 client 憑證）寫 syslog。客戶沒有 blackbox 就只做第二層＋選單 17（問題清單 11.10）。
- **第 30 章保險**：30.1 比對套件庫 release 套件的主版本；lab 用 dl01 對 Rocky 10 公開倉庫證明會停（問題清單 3.6）。
- **教訓（2026-10-29 事故）**：20.4 用錯 Secret Protection 的密文 key 名（`kb01.server.properties` vs 腳本版的 `kb01.properties`），broker 靠群組快取撐到重啟才爆成 `Waiting for all of the authorizer futures` → 10 分鐘自殺循環，連鎖讓整個 MDS 層卡死。真相只在 `/var/log/kafka/metadata-service.log`。已統一命名（第 15 站依角色 `<主機>.server.properties` 等）、20.4 改從設定檔的參照讀 key 名、28 章指到正確的日誌。

### C3 的監控：收 Kafka Streams 與 RocksDB（2026-10-29 定案，取代當天稍早的「維持精簡」）

- 使用者先說 C3 是管理用不用太在意，之後改口：照官網與其他資料加上建議的監控。
- exporter：只收 `kafka.streams:*`（加 Jetty），規則＝我方開頭幾條＋官方 `kafka_streams.yml` 的 rules（名稱對得上官方 `kafka-stream.json`、`kafka-streams-rocksdb.json`）。不收 C3 自己的 consumer／producer、REST endpoint（上萬條）。lab 實測（C3 2.6.1）約 2,100 條：RocksDB 1,092（`AlertHistoryStore`、`commander`）、thread 403、task 247；以前寫的「好幾千條」不對。
- 官方規則對 C3 的兩個坑（lab 實證）：`stream-metrics`、`stream-thread-metrics` 多帶 `process-id`，官方規則把 UUID 拼進名稱（`kafka_streams_stream_metrics_process_id_<uuid>_..._client_state`，每次重啟換名）→ `client-state`、`recording-level`、`thread-state` 由我方先命名；`stream-topic-metrics` 四個 key，官方把 `processor-node-id` 塞進 `task_id` → 我方一條。
- 告警（control-center 群組 5 條）：StreamsNotRunning（client_state ≥ 4）、StreamThreadsFailed（改用官方的 `failed_stream_threads` label）、**StreamsStalled**（thread 的 poll_rate = 0 十分鐘；閒置也約每秒 10 次）、**RocksDBBackgroundErrors**（15 分鐘內增加）、**DroppedRecords**（task 的丟棄率 > 0 十分鐘）。用的都是 recording level INFO 的指標（官方文件：RocksDB 屬性類指標、dropped-records 是 INFO）。
- 順帶修：`max by (instance)` 聚合的規則都改 `by (instance, hostname)`，否則 summary 的 hostname 是空的。
- 2026-10-30 使用者確認：銀行目前沒有自己的 Kafka Streams 應用，Streams／RocksDB 的 dashboard 與告警只用在 C3。之後若有，應用程式的 exporter 掛同一份官方 `kafka_streams.yml` 規則即可（但要避開 C3 那幾個帶 process-id 的坑，見上）。

### OP menu 與 MDS／AD 的關係、token 自動換新（2026-10-29）

- **操作機不直連 AD**（實測）：操作機加 blackhole 路由擋掉 ad01 → 直接連 636 失敗；alice 經選單登入、11 健康檢查、12 列 topic 照常，錯密碼仍被拒；同時段操作機開出的連線中，到 636／389 的 0 條；對照 kb01 上連 ad01:636 的連線 5 條。AD 帳密只由 broker（MDS `/security/1.0/authenticate`、LDAP listener 9096）去驗。
- **與 MDS 的認證**：登入時一次 basic auth 換 MDS token，之後都用 Bearer token；Kafka 動作用本人 AD 帳密走 SASL PLAIN（9096）；91 用憑證換 token。選單不用 confluent CLI。
- **token 換新（使用者定案：到期前自動換新）**：每個動作開始前，token 用了超過 TTL − 300 秒就用本次登入的帳密重新 authenticate（`core_token_fresh`，主 shell 執行），記 `TOKEN_RENEWED`；失敗不執行動作、記 `TOKEN_RENEW_FAIL`、請重新登入。帳密取自 session 原本就有的 Kafka 連線設定（0600、離開即刪），不另外保存。`tests/test-token-renew.sh` 11 項；lab 以 TTL=300 對真 MDS 驗過。

### MDS 不能用時的緊急路徑（2026-10-29 定案）

- MDS 內建在 broker：authorizer 沒就緒的 broker 只開 9092，對 client 的 9094／9095／9096 都不開（10-29 事故實測），所以「所有 MDS 都卡住」時任何身分都進不去。
- 部分失效時：91（緊急憑證換 MDS token）原本只帶第一台 MDS → 改成逐台問 `/v1/metadata/id`、用第一台回 200 的；全部連不上就停下並指向 kafka-admin 程序（`tests/test-breakglass-mds.sh`）。
- `kafka-admin`（SCRAM、9095、SystemAdmin）是唯一不經 MDS 也不經 AD 的管理身分（授權由 broker 本機的 binding 快取判斷）。使用者定案：**維持手動、不進選單**；手冊第 28 章加「MDS 的 8090 不能用時」一節（lab 擋 8090 實測後補），用完照 20.2 換密碼。

### 維運群組的 topic 權限改回 DeveloperManage（2026-10-29 定案）
- 10-28 為了不讓維運建 topic 改成 `DeveloperRead Topic:*`，10-29 手冊實跑發現選單 11 健康檢查、21／27 重啟前檢查全被 Kafka 拒絕：`kafka-topics --describe` 對每個 topic 都要 DescribeConfigs（加 `--under-replicated-partitions` 也一樣，authorizer 日誌實證），DeveloperRead 沒有；而且 DeveloperRead 有 Read，維運反而讀得到所有訊息。
- MDS 的角色定義（8.3.2 實測）：有 Topic DescribeConfigs 的只有 DeveloperManage、ClusterAdmin、ResourceOwner、SystemAdmin，全都連帶能建、刪 topic；CP 不能自訂角色。
- 考慮過：ACL 單獨補 DescribeConfigs（lab 實測可行，使用者：非不得已不用 ACL）；選單改用 Java 呼叫 describeTopics（只要 Describe，使用者不要選單多一支 Java）；改讀 JMX 指標。
- 定案：`Group:kafka-operators` = Operator（cluster）＋ DeveloperManage `Topic:*` ＋ DeveloperRead `Group:*`（13／15／18／33 要 Group Describe，最小的角色是 DeveloperRead）。維運能建、刪 topic，讀不到訊息。
- 順帶修：選單 33 刪 topic 前的 consumer 檢查失敗時原本當成「沒有 consumer」照刪，改成檢查失敗就拒絕。
- 手冊 11.3 新增 RBAC 全貌（範圍、子 cluster、資源、10 個角色的實際操作，指令從 MDS 讀）。
- 選單 36（重設 consumer 讀取位置）維運也能做（Group:* 的 DeveloperRead 帶 Read）：使用者定案**不收**，重設 offset 屬於維運工作（依應用團隊的變更單）。RBAC 收不乾淨：Group 有 Describe 的內建角色只有 DeveloperRead（＋Read，能重設）與 DeveloperManage（＋Delete，能刪停掉的 group）。

### JMX exporter 升到 1.7.0、keystore 密碼不再明文（2026-10-29 定案，待 lab 實測）
- 原本 1.0.1（約 2024 年，沒有特別理由）。1.7.0（2026-10-06）修 SSL 下 JVM 關閉卡住、HTTP server 安全邊界、認證快取、缺屬性 NPE，支援 PEM；1.6.0 加 basic auth 防時序攻擊；1.4.0 起 YAML 可用環境變數。使用者選 1.7.0。
- exporter YAML 的 keystore 明文密碼改從環境變數讀（systemd drop-in 的 EnvironmentFile，0600 root）。文件只寫 PEM 私鑰密碼支援 `${ENV}`、keystore 密碼省略時讀 `javax.net.ssl.keyStorePassword`（系統屬性會出現在 ps，不用）；release notes 說 1.4.0 起 keystore 密碼可用環境變數 → lab 先試 `keyStore.password: ${VAR}`，不行再比較 PEM 方案。
- 驗證：重跑第 17 章（指標名稱、數量）與附錄 B 覆蓋率。

### 緊急主機模式不再看作業系統群組（2026-10-29 定案）
- 使用者：MDS／AD 不通時，非 AD 相關的選單項目直接開放，不管群組。原因：操作者都是經 PSMP 登入的 root，`opmenu-emergency` 只能加「root」（等於所有人），root 也能自己加入，擋不住人。
- 選單：`OPMENU_EMERGENCY_GROUP` 拿掉，改 `OPMENU_EMERGENCY_HOST`（預設 1 開放、0 關閉）；仍只開放 16 18 21 22 23、必填原因、記 EMERGENCY_HOST、身分標「未經 AD 驗證」。
- 手冊 28.6 拿掉 OS 團隊加入／移出群組與重新登入；第 16 章表格拿掉群組；請銀行確認事項 9.1 改為告知（不接受可設 0 關閉）。腳本：bank-sim 的 emergency-group、28-triage 的群組判斷與 su - 都拿掉；lab 的 opmenu-emergency-test.sh 刪除（由 28-triage mds-down 取代）。

### dashboard job label、docs/evidence（2026-10-30 定案）
- scrape job 名稱維持 `kafka-controller`、`kafka-broker`、`rest-proxy`、`control-center`（加上 `cert-expiry`），`env`、`hostname` 兩個 label：官方 dashboard 寫死這些名稱（`job="kafka-broker"` 250 處、`job="kafka-controller"` 32 處），銀行要沿用，不能照自己的命名規則改。
- 官方 dashboard 不改：專用 controller 的 KRaft 叢集裡，`job="kafka-broker"` 查 controller 才有的指標（主力 `kafka-cluster-kraft.json` 只有 Offline Partitions Count 一格；舊版 ZooKeeper 時代的三張也有）會是空的，由告警 `KafkaOfflinePartitions` 涵蓋，附錄 B 已說明。不打補丁，換官方版本時也不用重做。
- `docs/evidence/`（實測截圖）不進版控，已移出並加進 `.gitignore`；檔案留在本機。

### OP menu 項目調整（2026-10-30 定案）
- 使用者自檢後選定：修 44 快照、合併 43＋45 與 13＋15、補 license 與配額；不做 partition 數、備份狀態、12＋14 合併。
- 13 改為「consumer group（lag 與成員數）」：每個 group 的合計 lag 與在線成員數（0 個 = 應用程式沒在跑）；查全部時不列 `OPMENU_INTERNAL_GROUP_PATTERN` 的平台內部 group（C3 遙測、工具的臨時 group、C3 自己的 group），不然遙測 group 動輒十幾萬的 lag 會被看成應用程式落後。
- 15 改為「查看配額」（第 1 層），新增 38「調整配額」（第 3 層：並行鎖、變更時窗、確認；值填 `-` 拿掉）。兩個都要叢集層級 DescribeConfigs／AlterConfigs，維運（Operator＋DeveloperManage）看不到，實測被拒。
- 43 合併成「查詢與匯出 audit」：依主體、結果篩選，最後問要不要存檔（非互動用第 4 個參數 `save`）；45 拿掉。時間改成操作機本地時間。原本 43／45 只讀 `OPMENU_AUDIT_TOPIC`（手冊第 18 章說兩個都讀，是錯的）。
- 17 加 license 到期日：本人讀得到 `_confluent-command` 就即時讀（同 26.1）；讀不到（維運通常沒有）改顯示 26.2 每日檢查在 syslog 的最後一筆。
- 44 快照補 `rbac.txt`、ACL 改成和 23.3 一樣一條一行，7 個檔和每日備份逐位元組相同（lab 實測 sha256 全部相同），23.6、26.4 的還原程式可以直接拿快照還原。為此每日備份的 `rbac.txt` 也去掉 CLI 表格的對齊空白、binding 排序；ACL、帳號、role binding 一律 `LC_ALL=C` 排序（ops02 是 C.UTF-8，銀行的 RHEL 多半是 en_US.UTF-8，排序結果會不同）。
- 順手修掉的既有 bug：44 的權限清單 CSV 每個 principal 的每個 role 都少了最後一個資源（`printf '%s' | sed` 沒有結尾換行，`read` 丟掉最後一行；lab 13 筆 → 33 筆）；23.6 單一帳號還原遇到叢集層級 binding 會帶錯的 `--resource Cluster:`（改成看資源名稱）；11.2 AD 斷線演練的 kafka-admin 檢查在腳本版是假通過（見 log/2026-10-30-script-full-run.md）。
- 43 加選項（使用者 2026-10-30 選定）：一般、敏感（`OPMENU_AUDIT_SENSITIVE_TOPIC`，預設 `<一般>_sensitive`）、兩個都看（依事件時間合併）；非互動第 5 個參數 `normal|sensitive|all`。稽核群組綁 audit topic 的 prefix 就兩個都讀得到。哪些 topic 算敏感由銀行定（lab 的 `payments.*` 只是例子，請銀行確認事項 9.5）。

### JMX exporter 7071 只用 HTTPS，拿掉 basic auth（2026-10-31 定案；手冊 10-31 在 Podman 逐章實跑，腳本 10-31 改完）
- 使用者決定：7071 只做 HTTPS（銀行根憑證驗得過鏈），不用 basic auth，也不用 mTLS。指標只讀、沒有訊息內容與密碼；少一組要交給銀行、要同步輪替的抓取密碼。
- 代價：連得到 7071 的人都讀得到平台結構資訊（topic、consumer group、client id）。存取控制改成只靠網路：請銀行確認事項 11.4（7071 只放行行內 Prometheus 的來源位址）變成必要條件。
- 要改：手冊 17.1／17.4／17.5、19 章驗收、25.1.5、B.2；`install/steps/17-jmx-exporter.sh`、`19-acceptance.sh`、`templates/jmx-header.yml`、`prometheus-scrape.yml`；questions 11.4。照三步：逐章手冊實跑到第 17 章前，先在 lab 手動試，再改手冊、照手冊跑，最後改腳本。

### lab 改用 Podman，移除 Docker Desktop（2026-10-31 定案）
- 使用者決定：lab 最後只留 Podman（CLI＋WSL2 上的 rootful machine），Docker Desktop 移除（10-31 晚已移除）。docker-compose 原本是自己下載的獨立版、用 `compose_providers` 指定；10-31 晚改成 Podman Desktop 的 Compose 擴充（system-wide，放在 WindowsApps、PATH 上找得到，不寫 `containers.conf`）。手冊與腳本的指令改寫成 `podman …`／`podman compose …`（不靠 alias）。
- 可行性測試（log/2026-10-31-podman-feasibility.md）：compose 名稱、systemd、固定 IP、firewalld、sysctl、cp／exec 都可行；要另外處理 `podman-restart.service`、Windows 開機啟動 machine、記憶體（.wslconfig）。真實度和 Docker 完全相同（共用 WSL2 kernel；net.core.rmem_max／wmem_max 一樣改不了：可行性測試時以為改得動，是因為 `sysctl -w` 失敗也回 0，2026-10-31 第 7 章實跑更正）。
- 順序：先換 Podman（三步：在 Podman 上手動建 lab → 改第 0 章與全書的 docker 指令、lab 腳本、實跑工具、CLAUDE.md → 照手冊從零逐章跑，再腳本版從零），兩邊都過才移除 Docker Desktop。Docker 上第 20 章之後的逐章實跑不再接續。

### REST 不能冒用的身分補上 svc-backup、confluent-audit（2026-10-31 定案）
- `confluent.metadata.server.impersonation.protected.users` 原本只列到 opmenu-breakglass；後來新增的平台身分 `svc-backup`（23）、`confluent-audit`（18）沒在清單裡。使用者決定補上：所有平台服務身分都不能被 REST Proxy 冒用。手冊第 10 章與 install/templates/broker.tpl 已改；lab（Podman）手動改 ~/conf 與 4 台 broker、逐台重啟，MDS 200。第 12 章實測冒用被拒。

### OP menu 寫給不熟 shell 的維護人員（2026-11-01 定案，完成）
- 使用者決定：最優先是可維護性。維護的人不是 shell 高手，要一眼看出「要改的位置在哪」「改不改得動」。指令盡量用新手會用的，一行一個指令，能慢慢寫就慢慢寫，不為簡短而壓縮。
- 規則：一行一個指令；判斷寫完整的 `if … then … fi`，不用 `&&`／`||` 串接；不用 `eval`、不在執行中改函式名稱；選單用純文字對照表 `items/menu.list`（編號、層級、變更類、要確認、檔案、標題、說明）；項目檔開頭固定四段註解（做什麼、用到的設定、用到的共用函式、改的時候要注意），函式裡照步驟編號；不相關的幾行之間空一行（例如「執行檢查」和「判斷結果」之間）；複雜的文字處理包成有名字的小函式並附輸入／輸出例子；寧可多幾行、有重複。
- 順序：先 OP menu（install/ 等看過再決定）；先做框架＋第 21 項給使用者看，確認風格後再改其餘 26 項。
- 完成（2026-11-01）：27 項＋lib＋登入改寫，lab 上唯讀與變更類項目新舊版輸出相同、44 快照＝每日備份，交付物 opmenu-20261101.f866d235 已裝到 /opt/opmenu。

### 手冊的手動指令也照同樣寫法（2026-11-01 定案，進行中）
- 使用者決定：全部章節（0→B，419 個指令塊）都改，讓安裝與維運人員好照著做。驗證分四批（0–9、10–19、20–28、29–31＋B）：每改完一批就從第 0 章重建 lab 跑到那批的最後一章，逐行對 `out`（多數章節不能單獨重跑）。先改第 0 章給使用者看寫法。
- 規則沿用 OP menu：一行一個指令、判斷寫完整的 `if`、不用 `&&`／`||` 串接、步驟用註解編號、不相關的行之間空一行、長的設定值先放進有名字的變數。
- 失敗時怎麼停：「先檢查、後動手」拆成兩塊，前一塊看到預期輸出（例如 `OK`）才做下一塊；不在貼上的指令裡用 `exit`（會關掉終端機）。`run-full.sh` 由執行器負責：每塊用 `trap … ERR` 執行，任何一行失敗就停（不開子 shell，變數照樣帶到下一塊，和人在同一個終端機照打一樣）。
- 寫法補充（2026-11-01，第二批改寫時發現）：執行器每塊用 `trap … ERR`，所以「結果可能是 0 或失敗才正常」的指令不能寫成 `x=$(指令)`：
  - 計數可能是 0：用 `awk '/…/ {c++} END {print c + 0}'`，不用 `grep -c`（找不到時結束碼是 1）。
  - 等服務起來時 curl 可能連不上：直接寫在 `if [ "$(curl …)" = 200 ]` 或 `echo`／`printf` 的參數裡，不要先 `code=$(curl …)`（2026-11-05 起手冊不再包成小函式）。
  - 送到容器或遠端主機的整段腳本用 `bash -e -s <<'EOF'`（裡面任何一行失敗就停、外面那塊跟著停）；只看不改的檢查用 `bash -s`。要給遠端的值用 `bash -s -- 值…` 傳成 `$1`、`$2`，heredoc 加引號，不再跳脫。

## 指令寫法再收緊（2026-11-05 使用者定案）
- 最優先仍是可維護性。手冊人照打的指令**不定義函式**，直接寫指令，寧可重複；手冊寫到磁碟的交付腳本與 install、opmenu 的腳本可以有函式。
- 全部規則在 `docs/journey-src/tools/COMMAND-STYLE.md`，用 `docs/journey-src/tools/lint-commands.js` 檢查（一行 120 字、管線 3 段、不巢狀 `$( )`、一塊 60 行等）；例外要寫 `# lint-ok: 原因`。
- 不用 `jq`：主機沒裝，也不在銀行的需求清單。

## 9092／9093 的來源（2026-11-05 定案）
- 操作機要能連 controller 9093（查 quorum、確認憑證）和 broker 9092（確認憑證）：第 10 章 broker 還沒啟動時，只能直接問 controller。不改成走 broker。bootstrap 第一條 binding 走 MDS 8090，不經過 9092，不需要另一個 super user。
- 要收窄時白名單是 controller、broker、操作機；lab 的 7.3 目前對所有來源開放，等銀行回覆問題清單 5.8 再決定要不要改成限制來源。

## AD 群組成員 pattern（2026-11-05，使用者同意，lab 實測）
- `ldap.group.member.attribute.pattern=CN=([^,]+),.*OU=<使用者根 OU>,.*`。不符合的 member 安靜略過，不報錯。代價：根 OU 外的人在群組裡也沒有權限。
- 舊 pattern `CN=([^,]+),.*` 的實測：子群組成員 DENIED（原廠文件也寫不支援巢狀群組）；和子群組同 CN 的使用者 ALLOWED；member 在 user search base 外 → 401；OU 內外同 CN，OU 內那個 ALLOWED。新 pattern 下後兩個 ALLOWED 都變 DENIED，OU 內的直接成員仍 ALLOWED。
- 全大寫 cn：三種大小寫登入 MDS、C3 都 200，sub 都是 ZZCASEUSER；OP menu 三種大小寫都通過碰主機的權限檢查，紀錄都是 ZZCASEUSER。

## AD 群組查詢範圍（2026-11-04，使用者定案，暫定）
- 只查 Kafka 用的群組，用**名稱前綴**：`ldap.group.search.base` 指到銀行的群組根 OU（scope 2），加 `ldap.group.search.filter=(cn=KAFKA_*)`。銀行應該不會另開子 OU，所以不用專用 OU（先前的想法已取消）。
- 群組名暫定 `KAFKA_` 開頭、全大寫（`KAFKA_ADMINS` 等），RBAC 綁定和 AD 寫法完全一致。
- 實測（2026-11-04，lab 8.2.4，同一人同時在 4 個群組）：沒有 filter 時 3 個群組的權限都有；`(cn=KAFKA*)` 大小寫都比對得到（kafka-zzin、KAFKA_ZZUP 有，zzout-grp 沒有）；`(cn=kafka-*)` 只剩 kafka-zzin。既有帳號不受影響。手冊第 10 章、common.tpl、site.env（`AD_GROUP_SEARCH_FILTER`）已加；lab 用 `(cn=kafka-*)`。
- **RBAC 的群組名有分大小寫**（實測）：`Group:kafka_zzlow` 對不到 AD 的 `KAFKA_ZZLOW`，沒有 filter 時也一樣 DENIED。
- 只影響群組；人員的 `ldap.user.search.base` 仍要涵蓋所有會登入的人。待銀行確認（請銀行確認的事項 7.6）。
