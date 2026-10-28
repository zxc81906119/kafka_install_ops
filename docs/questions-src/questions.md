<!--meta
{"kicker":"Confluent Platform 企業版 · 離線安裝與遷移（8.2 → 8.3）","title":"請銀行確認的事項","subtitle":"安裝前要先有答案的問題，以及沒有答案時我們的做法","header":"Confluent Platform 安裝與遷移 · 請銀行確認的事項","author":"zxc81906119","facts":[["適用版本","安裝基底：Confluent Platform 8.2.4、Control Center 2.5.1、JDK 21、RHEL 9.6；遷移目標：8.3.2、2.6.1、JDK 25、RHEL 9.8（以銀行實際的小版本為準）"],["驗證環境","RHEL 9 相容環境（Rocky Linux 9）模擬 11 台主機，離線安裝全程實跑"],["已知前提","主機不接 AD、只有固定帳號；CyberArk 只有 PAM（PVWA 網頁＋PSMP 代登、CPM 輪替 root 與 svc-mds-bind），沒有 CCP、Conjur"],["文件日期","2026-10-24"]]}
-->
[[toc]]

# 1. 怎麼看這份文件

每一題列出三件事：要問什麼、為什麼要知道、銀行還沒有答案時我們先怎麼做。「我們的預設」是在模擬環境驗證過的做法；銀行的答案不同時，我們依答案調整安裝步驟。

請各負責團隊填寫答案後回覆；同一題有多個團隊相關的，請由第一個列出的團隊彙整。

# 2. 離線引進（資安、檔案交換平台）

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 2.1 | 外網下載機由誰提供？能否連 `packages.confluent.io`、`repo1.maven.org`、`github.com`？ | 所有安裝檔都在下載機抓、驗證後才送進來 | 我方提供一台；只抓 Confluent 套件、監控用的 jar，以及 Confluent 官方的監控檔（GitHub 的 jmx-monitoring-stacks，固定在一個 commit：exporter 規則、告警規則、32 個 Grafana dashboard），OS 套件與 JDK 不下載 |
| 2.2 | 檔案交換的方式與單次大小上限？ | 整批約 3.1 GB | 超過上限就分批送，每批附各自的雜湊清單 |
| 2.3 | 放行標準：RPM 有原廠 GPG 簽章＋SHA256，是否足夠？jar、tar、GitHub 上的監控檔沒有原廠簽章，怎麼放行？ | 決定我們要準備哪些證明 | 附 SHA256SUMS 與驗證報告（RPM 原廠簽章逐一驗過、jar 比對 Maven 的雜湊、監控檔記下 commit 並列入 SHA256SUMS；監控檔都是純文字（YAML、JSON），可逐一審閱） |
| 2.4 | 之後補帶檔案（修補版、升級版）的申請流程與時程？ | 升級、修補都要再走一次 | 每次升級前兩週提出 |
| 2.5 | 我們先裝 Confluent Platform 8.2.4，再遷移到 8.3.2：兩套 RPM（各約 3 GB，其中 `confluent-security` 與 Control Center 各超過 1 GB）加兩個 JDK 合計約 6 GB，能否一次掃描、一次送進來？ | 遷移時才補帶要再等一輪開單；單檔大小上限會卡住 | 一次送兩套（安裝基底與遷移目標分在兩個目錄），遷移時直接上架；若平台有單次容量上限，分兩批 |

# 3. 套件來源與 JDK（OS 團隊）

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 3.1 | OS 套件從哪裡裝：Satellite、制品庫（Nexus／Artifactory）、還是 web server？`.repo` 由誰設定？ | 每台主機要能 `dnf install` | 對 dnf 都一樣；由 OS 團隊設定 `.repo`，我們只檢查裝得到 |
| 3.2 | 下列 OS 套件是否都在套件來源裡：chrony、firewalld、cyrus-sasl、openssl-devel、python3-dnf-plugin-versionlock、gettext、createrepo_c？ | 安裝與 Control Center 需要 | 缺的請 OS 團隊補進套件來源 |
| 3.3 | Confluent 的 RPM 上架到行內制品庫，還是由操作機自建一個套件目錄？由誰上架？ | 決定上架步驟與權限 | 操作機建好索引，經 ssh 推到銀行的 web server 一個目錄；不需要在 web server 上裝工具 |
| 3.4 | JDK 由誰提供？tar 還是 RPM？版本？之後誰負責更新？Confluent Platform 8.2.x 只支援 Java 17／21，8.3.x 支援 17／21／25（原廠建議仍是 21）：遷移到 8.3 時要不要一起換到 JDK 25？ | 安裝基底一定是 JDK 21（8.2.x 不支援 25）；25 是遷移時才用，選 25 要和原廠支援確認 | 銀行交付 JDK 21 與 JDK 25 兩個 tar，我們安裝到 `/opt/java/` 並登記 `alternatives`；沒有要求用 25 時遷移只做套件與 finalize，JDK 留在 21 |
| 3.5 | 行內的 RHEL 9 套件庫現在是哪個小版本（例如 9.4、9.6）？套件庫是釘在特定小版本，還是追 RHEL 9 的最新？多久同步一次、誰操作？變更窗口前能否先同步到目標小版本？ | 我們的安裝基底假設是 9.6、遷移目標 9.8（lab 的假設）；`dnf update` 會一路更新到套件庫有的最新小版本，不是你以為的那一版；小版本更新要先有目標內容 | 步驟與小版本無關（手把手 26.0–26.5）：以銀行實際的小版本為準；套件庫若追最新，請釘住（或在變更窗口前同步到要的那一版）。更新前每台先做 VM 快照；更新時 Confluent 套件由 versionlock 鎖住，JDK 是 tar，兩者不受影響 |

# 4. 主機與帳號（OS 團隊、資安）

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 4.1 | 11 台主機的規格（CPU、記憶體、磁碟）？`/tmp` 是否設 noexec？ | heap 大小、資料磁碟；安裝程式要在 `/tmp` 執行 | `/tmp` 需可執行且至少 2 GB；heap 依記憶體設定 |
| 4.2 | 每台主機（含操作機自己）的安裝與維運 user `cpuser`（本機帳號、不設密碼、sshd 對它關閉密碼驗證、只收金鑰）由 OS 團隊在開機時建立？UID／GID 能否每台固定同一個（例如 1500）？ | 檔案在主機間複製時擁有者一致；安裝腳本與 ssh 設定只處理一個 user | 每台 `cpuser`，UID／GID 1500，家目錄 `/home/cpuser`，鎖定密碼 |
| 4.3 | sudo 怎麼開：安裝與升級期依變更單給 `cpuser` 全權（`/etc/sudoers.d/cpuser`），交付時移除，之後只留重啟、查看 confluent 服務狀態與日誌的窄規則（`/etc/sudoers.d/cpuser-ops`，逐一列出服務與指令寫法，不用萬用字元）？ | 安裝要 root 權限做套件、服務、設定；sudoers 比對完整參數，萬用字元會連其他服務一起放行 | 變更時段內全權、完成後收回，只留逐一列出的窄規則；由 OS 團隊管 |
| 4.4 | 人員怎麼進操作機：登入 CyberArk 的 PVWA 網頁（AD 帳密加 MFA）、選操作機的目標帳號，由 PSMP 代登，進去是 root？操作機是否可以不再有另外的堡壘機或個人本機帳號？ | 操作機是安裝與維運的唯一入口；追溯依據是 CyberArk 登入紀錄與 PSMP 錄影 | PVWA＋PSMP 登入操作機即 root，沒有個人本機帳號；誰在什麼時間進了 root 由 CyberArk 紀錄與錄影保存 |
| 4.5 | 操作機到各主機（含操作機自己）的 SSH 私鑰：放在操作機一個獨立、加密（例如 LUKS）的 file system（例如掛載在 `/secure/ssh`，要支援 POSIX 權限：xfs、ext4）、root 0400，備份與快照排除這個掛載點？開機時掛載與解鎖怎麼處理（自動或人工輸入）？沒掛載成功時有什麼處理流程？ | 磁碟、快照或備份被取走時私鑰不會跟著被讀出；沒掛載成功時 ssh 連不上各主機 | 獨立加密 file system；私鑰不放 CyberArk、不另外備份；操作機重建就重新產生金鑰對，由 OS 團隊重新佈署公鑰 |
| 4.6 | 各主機 cpuser 的 `authorized_keys` 公鑰由 OS 團隊依變更單放入，前面只加 `from="操作機 IP,127.0.0.1,::1"`（寫 IP、不寫主機名稱；操作機連自己時來源可能是這三種）？定期換金鑰（人工、新舊並存、不中斷）的週期與由誰執行？ | 私鑰被複製到別處也用不了；金鑰長期不換是風險 | 只加 `from=`，不加 `restrict`、`pty`；每年人工換一次，由平台工程師在操作機執行（手把手 19.6） |
| 4.7 | SELinux、透明大頁（THP）、核心參數（sysctl）的調整要開什麼變更單？ | Kafka 建議關閉 THP、調整部分核心參數 | 依角色寫進 `/etc/sysctl.d`，SELinux 維持 enforcing |
| 4.8 | Confluent CLI 的 passphrase、SCRAM 密碼只能從命令列給，執行那一瞬間會出現在操作機的行程參數：能登入操作機的只有經 PSMP 進來的人員（root，全程錄影），是否接受？ | `hidepid` 擋不住 root，所以靠 PVWA 的授權與 PSMP 的錄影管住「誰能進操作機」 | 接受；操作機只開放給 PSMP 代登的人員 |

# 5. 網路（網路團隊）

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 5.1 | 第 12 章的連線由誰開？主機上的 firewalld 可否由我們依角色設定？ | 每個元件要開的 port 不同 | 我們依角色只開必要的 port＋ssh |
| 5.2 | 主機名稱解析用 DNS 還是 `/etc/hosts`？FQDN 命名規則？ | 憑證上的名稱必須和連線名稱一致 | 使用 DNS，名稱在申請憑證前確定 |
| 5.3 | NTP 來源？ | 憑證與 token 要求時鐘誤差 2 秒內 | 指向行內 NTP |
| 5.4 | REST Proxy 前的負載平衡：設備型態、VIP 名稱、能否做 L4 直通（不解 TLS）？ | 應用程式用 client 憑證，必須由 REST Proxy 自己驗 | L4 直通、依來源 IP 黏著 |
| 5.5 | 維運人員從哪個網段連 Control Center（9021）？ | Control Center 直連，不經負載平衡 | 從維運網段（跳板或 VDI）直連 |
| 5.6 | 變更時段內，LB 團隊能否配合「停用 REST Proxy 的一台 → 我方重啟 → 恢復 → 換另一台」？由誰操作、怎麼聯絡？LB 有沒有主動健康檢查（REST 是雙向 TLS）？ | 只靠被動檢查時，REST 每重啟一次就有幾秒的請求失敗（lab 升級演練實測 4 次）；先停用再重啟可以做到 0 失敗 | 每次重啟 REST 前由 LB 團隊停用該台、我方確認排空後重啟、200 後通知恢復（手把手 12.1） |

# 6. 憑證（CA 窗口）

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 6.1 | 憑證申請流程、申請單格式、從申請到簽回要多久？ | 安裝第 9 站要等簽回 | 我們產生私鑰與 CSR（私鑰不離開操作機），附申請單 |
| 6.2 | 同一張憑證可否同時有 serverAuth 與 clientAuth？簽發時會不會調整 SAN？ | controller 與 broker 之間（kafka-internal）兩端都要出示憑證；對外服務的 server 憑證（cp-server）與各 client 憑證（含 C3 連自己 Prometheus 用的 c3-monitoring）各自只用一種 | kafka-internal 兩種用途同一張；cp-server 只要 serverAuth；其餘 client 憑證只要 clientAuth；SAN 照 CSR。一共 9 張，請確認 CA 範本兩種用途都能簽 |
| 6.3 | 回覆的格式：是否包含中繼 CA？ | 憑證鏈要完整 | PEM，leaf 後接中繼 CA |
| 6.4 | 效期多久？到期前誰提醒？換根或中繼 CA 時會不會提前通知？ | 換 CA 要分三階段、各主機的信任清單要配合 | 效期一年；換 CA 提前一個月通知 |
| 6.5 | 根憑證放進每台主機的作業系統信任清單，由誰做？ | 所有連線都靠它驗證 | OS 團隊放進 `/etc/pki/ca-trust/source/anchors/` |

# 7. AD（AD 團隊）

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 7.1 | 平台查 AD 用的唯讀帳號（svc-mds-bind）由誰建立？密碼是否納入 CPM 自動輪替？ | 換密碼時平台要滾動重啟才會生效 | 不自動輪替，由我們依變更單換；可以的話建兩組（-a／-b）交替，換密碼不中斷 |
| 7.2 | 平台用的群組（管理、維運、開發、稽核）命名與成員由誰管理？ | 權限只綁群組，不綁個人 | 群組由 AD 團隊依申請單管理 |
| 7.3 | LDAPS 用哪幾台 DC？憑證由哪個 CA 簽？ | 平台要能驗 DC 的憑證、DC 故障時切換 | 設兩台以上，連線逾時 3 秒 |
| 7.4 | 維運人員用 AD 帳密登入 Control Center 是否可以？是否要求 MFA？ | Control Center 只支援帳號密碼 | AD 帳密登入，不做 MFA |

# 8. CyberArk（Secrets 團隊）

已知：只有 PAM（PVWA 網頁＋PSMP 代登、CPM 輪替 root 與 svc-mds-bind），沒有 CCP、Conjur，程式不能直接向 CyberArk 取值。平台的密碼加密後留在主機上（Confluent Secret Protection），解密用的 master key 由 CyberArk 保管。

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 8.1 | 平台加密用的兩個值（passphrase、master key）放哪個 safe？誰可以取用？ | 兩個都要存：master key 用於重建主機與復原，passphrase 用於輪替 master key | 同一個 safe、兩個 object 分開授權：passphrase 只給平台工程師 |
| 8.2 | master key 產生後由誰存進 PVWA：Secrets 團隊代存，還是平台工程師有權限自己存？ | 確認存好之前不會上線 | Secrets 團隊代存，存好後回覆單號 |
| 8.3 | 從 PVWA 取用（passphrase、master key、緊急憑證）是否要雙人覆核？要填什麼單號？ | 安裝與輪替都會用到 | 依變更單號取用 |
| 8.4 | root 與 `svc-mds-bind` 由 CPM 輪替：輪替排程多久一次、變更時段內能否暫停？（操作機到各主機的 SSH 私鑰**不**放 CyberArk，由操作機自己管，見 4.5、4.6） | root 密碼換了，PSMP 代登要跟上；做到一半被換會讓作業中斷 | CPM 管理 root 與 svc-mds-bind；變更時段內暫停輪替 |
| 8.5 | 應用程式現在怎麼拿資料庫密碼？Kafka 的應用程式密碼是否照同一套方式交付？ | 決定應用程式密碼的交付流程 | 照現行方式；新密碼由維運選單產生後交 Secrets 團隊登錄 |
| 8.6 | AD 查詢帳號 `svc-mds-bind` 的密碼若由 CPM 管：可否關掉自動排程、改成依變更單觸發並通知平台？或開 A／B 兩組帳號交替？ | 這個密碼加密後固定在主機上，CPM 悄悄換掉的話，broker 下次重啟時權限服務起不來 | 依變更單觸發、單一帳號；CPM 換完由平台工程師從 PVWA 取新值、更新密文、滾動重啟（約 10 分鐘，不中斷應用程式） |
| 8.7 | 平台加密用的 master key 多久輪替一次？依哪一條規範？規範是否要求「加密金鑰本身」（data key）也定期更換？ | 決定 15.6 的輪替週期；data key 定期更換要另外排程 | master key 每年輪替一次，保管人異動時也換；data key 不例行更換，懷疑外洩時改換密碼本身並重新加密 |
| 8.8 | 經 PSMP 登入操作機後：是否有指令白名單（要能執行 `ssh`、`scp`、`sudo`、`ssh-keygen`）？錄影或指令紀錄是否會記下鍵盤輸入的內容？ | 平台工程師在操作機以 root 執行安裝與換金鑰，並從 PVWA 貼上密碼 | 允許上述指令；貼上機密時一律關閉回顯（`stty -echo`／`read -s`），畫面與錄影不會出現值 |

# 9. 維運選單與紀錄（維運、資安）

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 9.1 | AD 服務故障時，誰可以把 root 加進緊急群組（opmenu-emergency）？事後誰移出？（操作者都是 root，所以這個群組是緊急主機模式的開關） | 緊急時只能用這個模式做重啟、看日誌 | OS 團隊依事故單加入，結案後移出 |
| 9.2 | 維運選單產生的應用程式新密碼寫在操作者自己的交接檔（只有本人讀得到）：交給誰、交接後由誰刪？ | 密碼不顯示在畫面上 | 交 Secrets 團隊登錄 PVWA，登錄後由操作者刪除 |
| 9.3 | 選單操作紀錄、Kafka 稽核日誌是否要送 SIEM？方式與保留期間？ | 操作機上人員是 root、主機端是共用的 cpuser，追溯要靠 CyberArk 登入紀錄、PSMP 錄影與集中紀錄 | 送 syslog；稽核日誌敏感 topic 保留 365 天，其他 90 天 |
| 9.4 | 變更時段？ | 升級、重啟、輪替都要排 | 依銀行變更時段 |

# 10. 應用程式（應用程式團隊）

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 10.1 | 有哪些應用程式？各自直連 Kafka（帳號密碼）還是經 REST Proxy（client 憑證）？ | 決定要建的帳號、憑證與權限 | 新應用直連；只有舊應用走 REST Proxy |
| 10.2 | 應用程式收到認證失敗時，會不會重新取密碼再重連？ | 決定換密碼要不要停機 | 每個應用兩個帳號（-a／-b）交替，換密碼不停機 |
| 10.3 | topic 命名規則？各應用的流量與配額？ | 權限依 topic 前綴授予，配額防止單一應用拖垮叢集 | 前綴授權、每個應用設配額 |
| 10.4 | 應用程式的語言與 Kafka client 版本？是否支援 SCRAM-SHA-512？ | 認證方式要 client 支援 | SCRAM-SHA-512 |

# 11. 監控（監控團隊、機房）

| # | 問題 | 為什麼要知道 | 我們的預設 |
|---|---|---|---|
| 11.1 | 監控採「JMX exporter＋行內 Prometheus＋行內 Alertmanager＋行內 Grafana」，行內 Prometheus、Alertmanager、Grafana 的版本與位置？ | 我們交付設定，不安裝這三套；版本影響設定寫法（自訂 webhook 內容要較新的 Alertmanager，我們在 0.34.1 實測；Prometheus 2.43 以上才有 scrape_config_files，我們用 3.5.0） | 銀行提供；我方交付 scrape 設定、21 條告警規則、Alertmanager 設定、Grafana 的 datasource 與 Confluent 官方 32 個 dashboard、根憑證、抓取密碼 |
| 11.2 | 機房斷電演練時的開機順序可否配合（controller → broker → REST Proxy／Control Center）？ | 全部同時開機時 Control Center 要等權限服務起來 | 已加上等待機制；仍建議依順序開機 |
| 11.3 | 行內 Prometheus 抓其他系統（主機、資料庫）用哪種認證：不加密、HTTPS＋帳密，還是 HTTPS＋client 憑證（mTLS）？ | 跟著行內既有慣例走，維運與稽核最省事 | HTTPS＋帳密（9 台共用一組抓取密碼，主機上只存加鹽雜湊）；要 mTLS 須另發 Prometheus 的 client 憑證 |
| 11.4 | 每台的 7071 可否只放行行內 Prometheus 的來源位址？請提供位址（或網段） | 抓取帳密是共用的，限制來源可以縮小外洩後的影響範圍 | 主機防火牆目前對所有來源開放 7071；拿到位址後改成只放行它 |
| 11.5 | 告警要送到哪裡？接收端是 IBM Netcool/OMNIbus（下稱 omnibus）；我們送的 JSON 欄位（附範例）符合它的接收規格嗎？要不要認證（API token）？ | 我們準備了兩種 webhook 範例：Alertmanager 預設的 JSON，和照 omnibus 規格自訂的 JSON（source、ClassName、msg_catalog、msg、state、severity、sub_origin、origin、hostname、sub_source）；其中 source、ClassName、origin、hostname、sub_source 先填你們提供的範例值，請確認正式值 | 兩種都交付，銀行留一種；欄位對應（例如 critical → ERROR）依行內的定義改範本。token 放檔案、不寫進設定 |
| 11.6 | Grafana 怎麼放 dashboard 與 datasource：檔案佈建（provisioning）還是手動匯入？登入用 AD（LDAP／SSO）嗎？誰能改 dashboard？ | 32 個官方 dashboard 以檔案佈建最容易維護與重建；Grafana 的權限要和平台的 RBAC 分開想 | 檔案佈建、唯讀；datasource 名稱與 uid 固定為 Prometheus |
| 11.7 | 行內 Prometheus 的容量與保留天數？ | Confluent 官方的 exporter 規則依 topic、partition 產生序列，broker 每台可到上萬條，partition 多時要評估 | 我方提供序列數的估算（每 1,000 個 partition 約增加多少）；保留天數由銀行定 |
| 11.8 | 確認：告警與 dashboard 只用行內這一套，不在 Control Center 建 alert trigger／action（C3 內建的 Prometheus、Alertmanager 只給 C3 畫面用） | C3 內建 Alertmanager 的設定會被 C3 重寫、webhook 內容不能自訂 | 如此設計；請銀行確認沒有別的流程依賴 C3 的告警功能 |

# 12. 附件：要開的連線

| 從 | 到 | port | 用途 |
|---|---|---|---|
| 應用程式 | broker | 9095 | 應用程式直連（帳號密碼，TLS） |
| 應用程式 | 負載平衡 VIP | 8082 | 經 REST Proxy 的應用程式（client 憑證） |
| 負載平衡 | REST Proxy | 8082 | 轉發（L4 直通） |
| 維運人員（跳板／VDI） | Control Center | 9021 | 瀏覽器 |
| 人員的 Kafka 工具 | broker | 9096 | AD 帳密登入 |
| controller、broker | controller | 9093 | 叢集共識（雙向憑證） |
| broker | broker | 9092 | 複寫（雙向憑證） |
| REST Proxy、Control Center、操作機 | broker | 9094、8090 | 憑證換 token 後連線；權限服務（MDS） |
| broker | AD 的 DC | 636 | LDAPS 查人員與群組 |
| 操作機 | 所有平台主機 | 22 | 安裝與維運（ssh，cpuser；來源限制在操作機） |
| 所有平台主機 | 套件庫 | 443 | dnf 安裝 |
| 所有平台主機 | NTP | 123/udp | 校時 |
| 行內 Prometheus | controller、broker、REST Proxy、Control Center | 7071 | 抓指標（HTTPS＋帳密） |
| 行內 Alertmanager | 行內事件系統（omnibus） | 由銀行定 | 告警 webhook |
| Control Center | 自己 | 9090 | 內建 Prometheus（不對外） |
