# install/ — 照手把手文件一章一支的安裝腳本

`docs/Confluent-安裝旅程-手把手.docx`（來源 `docs/journey-src/journey.md`）第 2–31 章的每一章，對應一支 `steps/NN-*.sh`（檔名照章號；第 7 章三支 07-1/2/3、第 25 章兩支 25-1/2；第 1 章與兩個附錄沒有腳本）（手把手只教手打指令，兩者的對照在下面「每一站」）。
腳本做的事、順序、檢查點都和文件一樣；文件是給人讀的，腳本是同一條路的自動化。看不懂某一步，翻文件同一章。

**版本路徑**：主線是「先裝安裝基底、再遷移」——基底 Confluent Platform 8.2.4＋Control Center 2.5.1＋JDK 21＋RHEL 9.6（第 2–19 站），遷移到 8.3.2＋2.6.1＋JDK 25＋RHEL 9.8（第 29、30 站，第 31 站單獨換 C3 版本）。版本都在 `conf/site.env`：基底 `CP_VERSION`／`C3_VERSION`／`JDK_MAJOR`／`OS_BASE_VERSION`，目標 `*_TARGET_*`。

**作業系統**：以 RHEL 9 為準（lab 用 Rocky Linux 9.6 → 9.8 從零跑完整條路；容器不能真的重開機，26 站遇到「要重開機」改重啟平台服務）。RHEL 10 是 Confluent Platform 8.2 起官方支援的，但這些腳本**沒有在 RHEL 10 實測過**；要上 RHEL 10 之前至少先驗 versionlock 外掛、原廠公鑰匯入與驗章、C3 前置套件，以及 CPU 是否支援 x86-64-v3。

```
install/
  install.sh          依序跑 steps/（--list / --from NN / --to NN / --only NN）
  conf/site.env       站點設定：主機名稱、版本、AD、heap、目錄。每個環境只改這一個檔
  conf/certs.txt      要請銀行 CA 簽的憑證（名稱、EKU、SAN 種類）
  conf/apps.txt       應用程式：SCRAM 直連或憑證走 REST、配額
  conf/rbac.txt       role binding（人員綁 AD 群組，服務與 app 綁最小權限）
  conf/topics.txt     範例 topic
  lib/ssh.sh          ssh_run / ssh_run_as / ssh_script（heredoc 原樣送過去）/ copy_to_tmp / restart_and_wait / rolling_restart —— 以 cpuser 與 /secure/ssh 的金鑰連線；ops_from_addrs / authorized_keys_line
  lib/render.sh       render_template / render_templates / encrypt_passwords / ldap_password_from_env / count_plaintext_passwords
  lib/log.sh          section / log / ok / warn / fail / die / ask_bank / wait_for_bank / finish_step —— 畫面 + ~/install-logs/
  templates/          *.tpl（properties 範本，取自文件第 10、12、13 章）、*.dropin（systemd）、監控設定（exporter 規則、Prometheus scrape、告警規則、Alertmanager、Grafana datasource）
  steps/02–14         核心：02 下載、03 引進、04 主機存取（ssh 金鑰、cpuser）、05 銀行準備、06 上架、07-1 JDK／07-2 檢查／07-3 OS 調校、08 套件、09 憑證、10–13 服務、14 總檢查
  steps/15–19         延伸：15 Secret Protection、16 OP menu、17 監控（JMX exporter＋行內 Prometheus／Alertmanager／Grafana 的設定）、18 稽核日誌、19 驗收
  steps/21–30         隨時／維運／遷移：21 憑證輪替（status｜leaf｜chain｜trust-sync）、23 日常備份（grant｜run｜schedule｜compare）、
                      25-1 換 controller（status｜replace）、25-2 broker 增減（status｜remove｜add）、26 license 監控（status｜check｜schedule）、
                      29 遷移到新版（publish｜plan｜backup｜packages｜jdk｜finalize｜rollback｜adopt｜c3）、30 OS 修補與小版本更新（plan｜apply｜verify）；
                      照順序安裝時略過（29、30 是遷移主線，由人或 lab/run-customer.sh 依序呼叫）。第 20 章（密碼與金鑰輪替）的演練分散在 11／15／19 站的既有程式與 OP menu，沒有獨立一支

## 怎麼跑

| 在哪 | 誰 | 指令 | 說明 |
|---|---|---|---|
| 下載機 | root | `bash install/steps/02-download.sh` | 第 2 站。落地區掛在 `/out`（可用 `OUT=` 改） |
| 操作機 | root | `bash install/install.sh` | 第 3 站起依序跑；第 2 站只提示「請在 dl01 執行」 |
| 操作機 | root | `bash install/install.sh --from 09` | 銀行做完後從某一站續跑 |
| 操作機 | root | `bash install/install.sh --list` | 看每站是否 done（`~/install-logs/<step>.done`） |

- 每一步 rc 0 成功、rc 2 **等銀行**（印出「請銀行做」清單；銀行做完後 `--from` 同一站重跑）、其他 rc 失敗（看 `~/install-logs/` 最新的 log）。
- 銀行的事腳本**不代做**，只印清單並驗證結果：第 3 站的掃描與交換、第 4、5 站的公鑰／套件庫／根憑證／JDK／AD／NTP／LB、第 9 站的簽發。
- 重跑是安全的：dnf、install、tee 都是覆蓋成一樣的內容；格式化看到 `meta.properties` 就略過；密碼檔、cluster id、MDS token 金鑰只在不存在時產生；topic 用 `--if-not-exists`。
- 密碼不進畫面、不進 log：`~/pki/store.pass`、`~/secrets/*.pass`（0600）讀進變數後交給 envsubst 或指令。

## 每一站：在哪跑、會在哪裡停下

手把手文件只教手打指令；這張表是兩者的對照。指令都在操作機以 root 執行（人員經 CyberArk PVWA 網頁＋PSMP 登入就是 root；lab 直接 `podman exec -it lab-ops02-1 bash`），到各主機一律用 cpuser 與 `/secure/ssh/cpuser_ed25519` 這把金鑰，除非另外註明。

| 站 | 指令 | 會停下等銀行（rc 2）／注意 |
|---|---|---|
| 2 | 下載機（root）`bash install/steps/02-download.sh` | 落地區預設 `/out`（`OUT=` 可改）；一次抓兩套：`rpm/` = 安裝基底（CP_VERSION＋C3_VERSION）、`rpm-target/` = 遷移目標，加兩個 JDK（`bank/`）；已下載的檔案 `dnf download` 會 SKIPPED。OS 套件本身不在這裡（銀行套件庫的事；`os-packages.txt` 只是清單） |
| 3 | `bash install/install.sh --only 03` | 掃描、開單、檔案交換是銀行的事：印清單（兩套 RPM 合計約 6 GB，一次送）；送到後核對 SHA256SUMS 與兩套 RPM 的原廠簽章 |
| 4 | `--only 04` | 我方只在獨立 file system（`/secure/ssh`，沒掛載就停）產生 ssh 金鑰對並印出公鑰行；各主機的 cpuser＋sshd 設定＋公鑰＋安裝期 sudo 是 OS 團隊的事；cpuser 金鑰登入（含 sudo、密碼鎖定、sshd 只收金鑰）、根憑證、OS 套件庫、JDK、LDAPS、負載平衡任一項沒好就停 |
| 5 | `--only 05` | 只確認銀行的事：每台的根憑證信任與 OS 套件庫、JDK tar 與 sha256、LDAPS 憑證鏈與密碼檔、負載平衡在聽；沒好就停（rc 2） |
| 6–8 | `--only 06` … `--only 08` | 7 是三支（07-1 JDK、07-2 檢查只讀、07-3 OS 調校）；8 裝套件並 versionlock |
| 9 | `--only 09` | 第一次產生私鑰與 CSR 後停在「請銀行簽」；回覆放進 `~/pki/incoming/` 再跑一次 |
| 10 | `--only 10` | 重跑時設定或 drop-in 有變、服務在跑的主機一台一台重啟；15 做過會照樣加密，18 做過會帶上稽核設定 |
| 11–13 | `--only 11` … `--only 13` | 11 替每個 scram 類應用建 `<app>-a`、`<app>-b` 兩個同權限帳號（A／B 輪替，手把手 20.6；驗收與稽核用 -a）；12、13 重跑時 15 做過會照樣加密 |
| 14 | `--only 14` | 只讀的總檢查。3–14 可一次跑：`bash install/install.sh --to 14` |
| 15 | `--only 15` | `SECRETS_MODE=sp` 才用；沒有 passphrase 檔且沒有 master key 時，由工程師在操作機自己產生（`~/secrets/sp-passphrase.txt`，0600），接著產生 master key（`~/secrets/master.key`），不用等任何人；20.3 輪替不在腳本裡 |
| 16 | `--only 16` | `OPMENU=1`；選單以 root 跑；16.4 寫每台的 `/etc/sudoers.d/cpuser-ops`（逐一列出服務與寫法）；重啟、看日誌要維運人員互動登入選單試跑（`lab/opmenu-hostkey-test.sh` 驗 sudoers 與私鑰檔） |
| 17 | `--only 17` | `JMX_EXPORTER=1`；給銀行監控團隊的檔在 `~/monitoring/to-bank/`（prometheus／alertmanager／grafana）；官方規則與 dashboard 取自 `~/landing/monitoring/`（第 2 站帶進來）；C3 內建 Prometheus／Alertmanager 不動 |
| 18 | `--only 18` | `AUDIT_LOG=1`；密碼依 `~/conf/secrets.mode`（15 留下的）處理 |
| 19 | `--only 19` | 印「驗收：N / N 項通過」；冷開機（19.4）交給機房演練 |
| 21 | `bash install/steps/21-cert-rotate.sh status｜leaf｜chain 新中繼.pem｜trust-sync` | 不在安裝順序裡。`leaf` 第一次停在「請銀行簽」，回覆放進 `~/pki/next/incoming/` 再跑；`chain` 用在中繼沒換私鑰（leaf 不重簽、只把新中繼重包進 p12）；換 CA 三階段 = `trust-sync` → `leaf`（或 `chain`）→ `trust-sync`。先看手把手 21.0 判斷是哪一種 |
| 22 | `bash install/steps/22-cert-expiry.sh files｜check｜schedule` | 不在安裝順序裡（選配，lab 必做）。`files` 給銀行 `to-bank/prometheus/{blackbox.yml, scrape-blackbox.yml（每個 TLS 端點一個 target）, confluent-alerts-cert.yml（< 60 天 warning、< 14 天 critical、探不到）, cert-expiry-rules-test.yml（promtool）}`，lab 由 `bank-sim.sh monitoring-blackbox` 起 exporter 並載入；`check` 操作機讀 `~/pki/certs` 每張憑證剩幾天，寫 syslog tag `confluent-cert`（rc 0／2／1）；`schedule` 每天 08:10 的 timer |
| 23 | `bash install/steps/23-metadata-backup.sh grant｜run｜schedule｜compare｜restore <備份目錄> <topic|-> <帳號|->｜drill｜restore-all <備份目錄>` | 不在安裝順序裡。`svc-backup` 憑證由第 9 站一起發（`conf/certs.txt`）；`grant` 給最小權限（SecurityAdmin＋Topic／Cluster 的 Describe、DescribeConfigs ACL）並做反向檢查；`schedule` 裝每天 02:00 的 timer（和手把手 23.4 同名，裝哪一個都是同一個 timer）；備份在 `~/backup/metadata/`，保留 `KEEP_DAYS`（預設 30）天；`restore-all` 給 26 站 `reset` 用（應用程式 topic、全部 binding、SCRAM、配額、ACL、broker 動態設定） |
| 24 | `bash install/steps/24-disk.sh usage｜alerts｜drill` | 不在安裝順序裡。`usage` 每台 broker 的 log dir 合計、最大的 topic、`df`；`alerts` 給銀行第二個規則檔 `to-bank/prometheus/confluent-alerts-disk.yml`（`KafkaLogDirOffline`＋銀行 node_exporter 的資料盤用量範例；lab 由 `bank-sim.sh monitoring-reload` 載入）；`drill` 建 `orders.disk-demo` 寫 5 MB、縮短 retention 等 segment 被刪（最多 5 分鐘）、`kafka-reassign-partitions` 把 partition 搬離第一台 broker，再清掉。擴容是銀行 OS 團隊放大資料盤，換碟走 25.2 |
| 27 | `bash install/steps/27-onboard.sh onboard <系統> scram｜cert <topic:partitions:天數>…｜verify <系統> scram｜cert <topic>｜retire <系統> scram｜cert <topic>…` | 不在安裝順序裡。`onboard`：topic（`<系統>.` 前綴、RF 3）、身分（scram：`app-<系統>-a／-b`＋配額＋binding；cert：CSR 停在「請銀行簽」rc 2，憑證鏈放 `~/pki/incoming/` 再跑一次 → 檢查、`.crt`、`.p12` 自己的密碼、binding、配額）、交接檔 `~/handover/`；cert 還會把 CN 加進 `conf/apps.txt` 並重跑第 12 站（REST Proxy 只放行白名單 CN，兩台 REST 重啟）；`verify` 用該身分寫讀一筆（cert 經 REST／LB，看回應的 `error_code`）；`retire` 解除 binding、SCRAM 覆寫隨機密碼（帳號留著）、憑證檔拿掉、刪 topic。lab 的銀行簽章：`bank-sim.sh sign-app app-<系統>` |
| 28 | `bash install/steps/28-triage.sh snapshot｜drill <broker>｜recover <broker>` | 不在安裝順序裡。`snapshot` 一分鐘快照（quorum leader、broker 在線、under-replicated／offline、每台 MDS、REST 經 LB、C3；全綠 rc 0）；`drill` 在銀行停掉一台 broker 之後確認症狀（lab：`bank-sim.sh broker-stop kb04`，告警用 `bank-sim.sh alerts-wait`／`alerts-clear`）；`recover` 以 cpuser-ops 允許的 `systemctl restart` 救回並等歸零 |
| 25.1 | `bash install/steps/25-1-controller-replace.sh status｜replace kc03` | 不在安裝順序裡。同名主機（換碟或換機器且已照 3、5、7、8、10 站準備好）：移出舊成員 → 清空並以觀察者格式化 → 追上 → `add-controller`；一次一台 |
| 25.2 | `bash install/steps/25-2-broker-scale.sh status｜remove kb04｜add kb04` | 不在安裝順序裡。`remove` 由 Self-Balancing 搬走 replica、停用服務；`add` 清空並以觀察者格式化、啟動，Self-Balancing 自動搬回；永久縮減後改 `BROKERS`、重跑 12、13、16 站 |
| 26 | `bash install/steps/26-license.sh status｜check｜schedule｜reset` | 不在安裝順序裡。`schedule` 裝操作機的 systemd timer（每天 08:00 跑 `check`，寫 syslog tag `confluent-license`）；rc 0 正常、2 剩不到 `LICENSE_WARN_DAYS`（預設 90）天、1 過期或讀不到；`reset` = 手把手 26.4（試用到期時重置測試／評估環境的叢集：備份、清空、新 cluster id、全部建回來；要輸入現在的 cluster id 確認，不互動時 `RESET_CONFIRM=<cluster id>`；先取得原廠同意） |
| 29 | `bash install/steps/29-upgrade.sh publish｜plan｜backup｜packages｜jdk｜finalize 4.3｜rollback 主機｜adopt`（`c3 <版本>`、`publish c3` 見右） | 遷移主線，不在 install.sh 的順序裡。版本取自 `site.env` 的 `*_TARGET_*`；`publish` 把 `rpm-target/` 上架（基底留著）；`packages` 先換 C3（2.5.1 → 2.6.1，因為 2.5.x 不支援 8.3）再 broker → controller（leader 最後）→ REST → 操作機；每段結束跑第 19 站；`jdk` 預設換成 `JDK_TARGET_MAJOR`；finalize 要帶 `CONFIRM_CLUSTER_ID`（不能退）；rollback 只在 finalize 之前（預設退回 `CP_VERSION`）；`adopt` 把 `site.env` 的基底版本改成目標值。`c3 <版本>` 只換 Control Center（手把手第 31 章），比現在新就升、舊就退，Prometheus、Alertmanager 一起重啟，C3 自己寫的 generated 檔擁有者會改回 `cp-control-center`；`publish c3` 上架 `landing/c3/` 的單一 C3 RPM |
| 30 | `bash install/steps/30-os-patch.sh plan｜apply｜verify [版本]` | 不在安裝順序裡。每月修補與小版本更新（9.6 → 9.8）同一套：broker 逐台 → controller（leader 最後）→ REST → C3 → 操作機；每台 `dnf update` 後用 `dnf needs-restarting` 判斷重開機或重啟平台服務（主機是容器時自動改重啟平台服務），健康了才下一台；`plan` 印目前與套件庫裡的 OS 版本，看到 `confluent-*` 在更新清單就停（versionlock 沒鎖好）；`verify 9.8` 檢查每台的 OS 版本、versionlock、服務、under-replicated、REST 經 LB、C3；`ONLY_HOSTS` 只做列出的主機。銀行把套件庫同步到新的小版本是銀行的事（lab：`bank-sim.sh os-sync`） |

## lab 與客戶環境的設定差異（conf/site.env）

與 CyberArk 唯一的關係是人員登入（PVWA 網頁＋PSMP 代登）。平台的密碼與金鑰（passphrase、master key、緊急憑證、`svc-mds-bind` 等）只留在操作機 root 才讀得到的位置（`~/secrets`、`~/pki`，0600），不放 PVWA；root 與 `svc-mds-bind` 的密碼也由人手動輪替（沒有 CPM）。
人員登入 PVWA 後由 PSMP 代登進操作機就是 root；lab 沒有 PVWA／PSMP，直接 `podman exec` 以 root 進操作機。操作機到各主機一律 cpuser＋一把金鑰
（放在獨立加密 file system `/secure/ssh`；lab 用 podman volume 模擬那個獨立 file system，LUKS 無法模擬）。下面這些要換：

| 設定 | lab | 客戶 | 為什麼 |
|---|---|---|---|
| `SSH_KEY_DIR`、`SSH_KEY_REQUIRE_MOUNT` | `/secure/ssh`（podman volume）、`1` | 銀行規範的掛載點（名稱只是範例）、`1` | 私鑰放獨立（加密）file system，不放系統碟、不備份 |
| `SSH_USER`、`SSH_USER_ID`、`SSH_FROM_ADDRS` | `cpuser`、`1500`、空（= 操作機 IP＋127.0.0.1＋::1） | 同左 | 每台同名同 UID；公鑰只加 `from=` |
| `FETCH_JDK` | `1` | `0` | 兩個 JDK（21、25）由銀行交付到 `landing/bank/` |
| `OPMENU_ENV_LABEL` | `LAB` | `PROD`／`UAT` | |
| 主機、`DOMAIN`、`REPO_URL`、AD 的 DN、`NTP_SERVER`、`HEAP_*` | lab 值 | 實際值 | heap 依主機記憶體調整 |

舊做法（cpadmin、私鑰貼進 ssh-agent）已在 lab 從零整套跑過（2026-10-24，CP 8.2.4）；2026-10-27 改成 cpuser＋`/secure/ssh` 金鑰檔＋root 操作機、2026-10-28 把主線改成「基底 8.2.4／9.6 → 遷移 8.3.2／9.8」後**尚未從零重跑**（需要先重建 lab）。選單重啟 broker（19.4）要人互動登入，列為人工驗收項目。

## 安裝完之後還會用到的

- **改了設定**（範本、`site.env` 的 heap 等）：重跑對應的站（10／12／13）。10 只重啟設定有變的主機；做過 16 會照樣加密，不會把明文寫回主機。
- **換我方管的密碼**（keystore 密碼、AD 查詢密碼）：改 0600 密碼檔後重跑第 15 站（重新加密、滾動重啟）。
- **改稽核規則**：改 `templates/audit.tpl` 後重跑第 18 站。
- **換憑證**：第 21 站（見上表）。

## 寫法約定（改腳本前先看）

目標是「翻到那一章就能改」，所以每支腳本都照同一個樣子寫：

1. **檔頭**：第 2 行是標題（install.sh --list 會顯示），`# where:` 一行寫在哪台跑，接著寫「做什麼／需要什麼／產出什麼／能不能重跑」。
2. **段落 = 手把手的小節**：`section "10.2 …"` 對 `## 10.2`；每段前面一行註解說「為什麼這樣做」，不寫「做了什麼」（程式本身就是）。
3. **遠端多行指令一律用 `ssh_script 主機 變數=值 <<'EOF' … EOF`**：heredoc 裡的 `$`、引號都在那台主機展開，和手打一樣，不跳脫。
   同一段遠端指令要用好幾次（例如 15 站），先存成有名字的變數（`SETUP_SERVICE_ENV=$(cat <<EOF … EOF)`），再 `ssh_script 主機 … <<<"$SETUP_SERVICE_ENV"`。
4. **名字寫完整**：路徑與常數用全大寫完整英文（`CERTS_DIR`、`FIRST_BROKER`、`ADMIN_CLIENT_CONF`），迴圈與暫存用小寫完整英文（`host`、`result`、`props_file`）；
   不用 `D`、`C`、`r`、`h` 這種單字母。各站共用的衍生值都在 `conf/site.env` 的下半段，先找那裡再自己取名。
5. **判斷拆兩行**：先把結果放進變數，再 `if [ "$result" = "…" ]; then ok …; else fail …; fi`，或 `case $result in 模式) ok;; *) fail;; esac`；不疊 `&& … || …` 三層。
6. **密碼**：從 0600 檔讀進變數、用完 `unset`；不放在 `ssh_script` 的參數（會出現在遠端的程序清單），不印出來。
7. **只用 bash 與 RHEL 標準指令**：ssh、curl、openssl、sed、awk、grep、tar、dnf、systemctl，加上 Confluent 自己的 CLI。不用 python、node、jq；解析 JSON 用 grep／sed（例子：18 站稽核事件）。
8. **每支結尾 `finish_step`**：有 `fail` 就整站失敗；銀行還沒做完用 `wait_for_bank`（rc 2）。
9. **改完先跑 `bash install/tools/lint.sh`**，乾淨了再上 lab。真的要例外時在那一行上面寫 `# shellcheck disable=SCxxxx  # 原因`。

## 延伸站的開關（conf/site.env）

| 開關 | 意思 |
|---|---|
| `SECRETS_MODE=sp|plain` | 密碼放法：第 15 站 Secret Protection（只有 PAM）／不處理（不建議，15 站直接略過） |
| `OPMENU` `JMX_EXPORTER` `AUDIT_LOG` | 16／17／18 站要不要做 |

選單的緊急憑證（91）是操作機上的檔案 `~/secrets/opmenu-breakglass.pem`（0600、owner 是執行者，16 站組好、20 站換發時舊的另存 `.prev`），選單設定項 `OPMENU_BREAKGLASS_PEM` 可改路徑；主機用的 ssh 私鑰就是 `/secure/ssh` 的那個檔。兩者都不經 PVWA。

15 站一次把 15.1–15.5 做完，只滾動重啟一次；18 站依 `~/conf/secrets.mode`（15 站留下的）決定密碼怎麼放。

## 和文件的差異（刻意的）

- 主機清單、版本、AD DN、heap 在 `conf/site.env`，範本裡用 `${CONTROLLER_QUORUM}` 這類變數；文件裡是寫死的 lab 名稱。
- REST Proxy 的 principal 對應規則由 `conf/apps.txt` 裡 `cert` 類的 app 產生（文件只有 app-legacy-billing 一個）。
- 7.2 節「主機是乾淨的」在已安裝過的主機只警告，讓整套可以重跑。
- 第 14 站的總檢查多了逐項 ok／FAIL，而不是一段輸出讓人自己對。

## lab 驗證

```bash
bash install/lab/run-customer.sh       # 從零跑整條主線：基底（8.2.4／C3 2.5.1／JDK 21／OS 9.6）→ 第 19 站驗收 → 21 憑證輪替 → 29 遷移（C3、8.3.2、JDK 25、finalize）→ 26、23、25-1、25-2 → 30 OS 9.8 → 31 → 驗收；每段之後驗收，遷移期間持續流量。FROM=N 從第 N 段接著跑、TO=N 跑到第 N 段、IDEMPOTENCE=1 在基底裝完後再重跑 02–14 驗冪等
bash install/lab/opmenu-hostkey-test.sh # 選單的私鑰檔與 sudoers 窄規則實測（第 16 站之後）
```

`lab/bank-sim.sh` 的每個子命令就是文件裡橘色「銀行」標籤的區塊，只是從 Windows 端對容器執行；正式環境沒有這支。
