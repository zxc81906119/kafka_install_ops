# install/ — 照手把手文件一章一支的安裝腳本

`docs/Confluent-安裝旅程-手把手.docx`（來源 `docs/journey-src/journey.md`）第 1–28 章的每一章，對應一支 `steps/NN-*.sh`（手把手只教手打指令，兩者的對照在下面「每一站」）。
腳本做的事、順序、檢查點都和文件一樣；文件是給人讀的，腳本是同一條路的自動化。看不懂某一步，翻文件同一章。

**作業系統**：以 RHEL 9 為準（lab 用 Rocky Linux 9 從零跑到第 20 站）。RHEL 10 是 Confluent Platform 8.2 起官方支援的，但這些腳本**沒有在 RHEL 10 實測過**；要上 RHEL 10 之前至少先驗 versionlock 外掛、原廠公鑰匯入與驗章、C3 前置套件，以及 CPU 是否支援 x86-64-v3。

```
install/
  install.sh          依序跑 steps/（--list / --from NN / --to NN / --only NN）
  conf/site.env       站點設定：主機名稱、版本、AD、heap、目錄。每個環境只改這一個檔
  conf/certs.txt      要請銀行 CA 簽的憑證（名稱、EKU、SAN 種類）
  conf/apps.txt       應用程式：SCRAM 直連或憑證走 REST、配額
  conf/rbac.txt       role binding（人員綁 AD 群組，服務與 app 綁最小權限）
  conf/topics.txt     範例 topic
  lib/ssh.sh          ssh_run / ssh_run_as / ssh_script（heredoc 原樣送過去）/ copy_to_tmp / restart_and_wait / rolling_restart
  lib/render.sh       render_template / render_templates / encrypt_passwords / ldap_password_from_env / count_plaintext_passwords
  lib/log.sh          section / log / ok / warn / fail / die / ask_bank / wait_for_bank / finish_step —— 畫面 + ~/install-logs/
  lib/vault.sh        vault_login_as_ops / vault_login_as_host / vault_get / vault_set / vault_exists（Conjur 版；客戶只有 PAM／CCP 時換這一個檔）
  templates/          *.tpl（properties 範本，取自文件第 10、12、13 章）、*.dropin（systemd）、Prometheus 設定
  steps/01–14         核心：下載到 C3、總檢查
  steps/15–20         延伸：15 Conjur provider（含下載機建 jar 的 15-…-jar）、16 Secret Protection（+Summon、+AD 密碼注入）、17 OP menu、18 JMX exporter、19 稽核日誌、20 驗收
  steps/21–27         隨時：21 憑證輪替（status｜leaf｜chain｜trust-sync）、22 升級（plan｜backup｜packages｜jdk｜finalize｜rollback｜c3）、
                      23 license 監控（status｜check｜schedule）、24 換 controller（status｜replace）、25 broker 增減（status｜remove｜add）、
                      26 日常備份（grant｜run｜schedule｜compare）、27 OS 修補（plan｜apply）；照順序安裝時略過
  tools/load.sh       演練用持續流量：start／stop／report（直連遺失幾筆、REST 失敗幾次）
  lab/bank-sim.sh     lab 專用：Windows 端扮演銀行（公鑰派送、OS 套件庫、AD、NTP/LB、CA 簽發、檔案交換；延伸：conjur / sp / opmenu / prometheus / coldboot）
  lab/run-all.sh      lab 專用：down -v 從零到第 14 站全自動；EXT=1 再接 15–20
  tools/lint.sh       靜態檢查：shellcheck（含送到遠端的 heredoc）＋「pipefail 下不准 | grep -q」；沒有 shellcheck 時用 docker image koalaman/shellcheck 跑
```

## 怎麼跑

| 在哪 | 誰 | 指令 | 說明 |
|---|---|---|---|
| 下載機 | root | `bash install/steps/01-download.sh` | 第 1 站。落地區掛在 `/out`（可用 `OUT=` 改） |
| 操作機 | cpadmin | `bash install/install.sh` | 第 2 站起依序跑；第 1 站只提示「請在 dl01 執行」 |
| 操作機 | cpadmin | `bash install/install.sh --from 09` | 銀行做完後從某一站續跑 |
| 操作機 | cpadmin | `bash install/install.sh --list` | 看每站是否 done（`~/install-logs/<step>.done`） |

- 每一步 rc 0 成功、rc 2 **等銀行**（印出「請銀行做」清單；銀行做完後 `--from` 同一站重跑）、其他 rc 失敗（看 `~/install-logs/` 最新的 log）。
- 銀行的事腳本**不代做**，只印清單並驗證結果：第 2 站的掃描與交換、第 3 站的公鑰／套件庫／根憑證／JDK／AD／NTP／LB、第 9 站的簽發。
- 重跑是安全的：dnf、install、tee 都是覆蓋成一樣的內容；格式化看到 `meta.properties` 就略過；密碼檔、cluster id、MDS token 金鑰只在不存在時產生；topic 用 `--if-not-exists`。
- 密碼不進畫面、不進 log：`~/pki/store.pass`、`~/secrets/*.pass`（0600）讀進變數後交給 envsubst 或指令。

## 每一站：在哪跑、會在哪裡停下

手把手文件只教手打指令；這張表是兩者的對照。指令都在操作機以 cpadmin 執行，除非另外註明。

| 站 | 指令 | 會停下等銀行（rc 2）／注意 |
|---|---|---|
| 1 | 下載機（root）`bash install/steps/01-download.sh` | 落地區預設 `/out`（`OUT=` 可改）；已下載的檔案 `dnf download` 會 SKIPPED |
| 2 | `bash install/install.sh --only 02` | 掃描、開單、檔案交換是銀行的事：印清單；送到後核對 SHA256SUMS 與原廠簽章 |
| 3 | `--only 03` | 我方只產生 ssh 金鑰（`SSH_KEY_SOURCE=file` 時）；金鑰登入、根憑證、OS 套件庫、JDK、LDAPS、負載平衡任一項沒好就停 |
| 4–8 | `--only 04` … `--only 08` | 6 只讀；8 裝套件並 versionlock |
| 9 | `--only 09` | 第一次產生私鑰與 CSR 後停在「請銀行簽」；回覆放進 `~/pki/incoming/` 再跑一次 |
| 10 | `--only 10` | 重跑時設定或 drop-in 有變、服務在跑的主機一台一台重啟；16 做過會照樣加密，19 做過會帶上稽核設定 |
| 11–13 | `--only 11` … `--only 13` | 12、13 重跑時 16 做過會照樣加密 |
| 14 | `--only 14` | 只讀的總檢查。2–14 可一次跑：`bash install/install.sh --to 14` |
| 15 | 下載機 `bash install/steps/15-conjur-provider-jar.sh`，再 `--only 15` | `SECRETS_MODE=conjur` 才用；15.7、15.8 的演練不在腳本裡 |
| 16 | `--only 16` | `SECRETS_MODE=sp` 才用；`VAULT_ACCESS=manual` 時：沒有 passphrase 檔會停；master key 產生後停下等 Secrets 團隊存進 PVWA、記單號（`~/secrets/master-key.custody`）；16.6 輪替不在腳本裡 |
| 17 | `--only 17` | `OPMENU=1`；`OPMENU_SECRETS=manual` 時要維運人員互動登入試跑主機類項目 |
| 18 | `--only 18` | `JMX_EXPORTER=1`；給銀行監控團隊的檔在 `~/monitoring/` |
| 19 | `--only 19` | `AUDIT_LOG=1`；密碼依 `~/conf/secrets.mode`（15／16 留下的）處理 |
| 20 | `--only 20` | 印「驗收：N / N 項通過」；冷開機（20.4）交給機房演練 |
| 21 | `bash install/steps/21-cert-rotate.sh status｜leaf｜chain 新中繼.pem｜trust-sync` | 不在安裝順序裡。`leaf` 第一次停在「請銀行簽」，回覆放進 `~/pki/next/incoming/` 再跑；`chain` 用在中繼沒換私鑰（leaf 不重簽、只把新中繼重包進 p12）；換 CA 三階段 = `trust-sync` → `leaf`（或 `chain`）→ `trust-sync`。先看手把手 21.0 判斷是哪一種 |
| 22 | `bash install/steps/22-upgrade.sh plan｜backup｜packages｜jdk 25｜finalize 4.3｜rollback 主機 版本` | 不在安裝順序裡。先改 `site.env` 的 `CP_VERSION`；每段結束跑第 20 站；finalize 要帶 `CONFIRM_CLUSTER_ID`（不能退）；rollback 只在 finalize 之前；`c3 <版本>` 只換 Control Center（手把手第 28 章），比現在新就升、舊就退，Prometheus、Alertmanager 一起重啟，C3 自己寫的 generated 檔擁有者會改回 `cp-control-center` |
| 23 | `bash install/steps/23-license.sh status｜check｜schedule` | 不在安裝順序裡。`schedule` 裝操作機的 systemd timer（每天 08:00 跑 `check`，寫 syslog tag `confluent-license`）；rc 0 正常、2 剩不到 `LICENSE_WARN_DAYS`（預設 90）天、1 過期或讀不到 |
| 24 | `bash install/steps/24-controller-replace.sh status｜replace kc03` | 不在安裝順序裡。同名主機（換碟或換機器且已照 3、5、7、8、10 站準備好）：移出舊成員 → 清空並以觀察者格式化 → 追上 → `add-controller`；一次一台 |
| 25 | `bash install/steps/25-broker-scale.sh status｜remove kb04｜add kb04` | 不在安裝順序裡。`remove` 由 Self-Balancing 搬走 replica、停用服務；`add` 清空並以觀察者格式化、啟動，Self-Balancing 自動搬回；永久縮減後改 `BROKERS`、重跑 12、13、17 站 |
| 26 | `bash install/steps/26-metadata-backup.sh grant｜run｜schedule｜compare` | 不在安裝順序裡。`svc-backup` 憑證由第 9 站一起發（`conf/certs.txt`）；`grant` 給最小權限（SecurityAdmin＋Topic／Cluster 的 Describe、DescribeConfigs ACL）並做反向檢查；`schedule` 裝每天 02:00 的 timer（和手把手 26.4 同名，裝哪一個都是同一個 timer）；備份在 `~/backup/metadata/`，保留 `KEEP_DAYS`（預設 30）天 |
| 27 | `bash install/steps/27-os-patch.sh plan｜apply` | 不在安裝順序裡。broker 逐台 → controller（leader 最後）→ REST → C3 → 操作機；每台 `dnf update` 後用 `dnf needs-restarting` 判斷重開機或重啟平台服務，健康了才下一台；`plan` 看到 `confluent-*` 在更新清單就停（versionlock 沒鎖好）；`ONLY_HOSTS` 只做列出的主機 |

## lab 與客戶環境的設定差異（conf/site.env）

客戶的 CyberArk 只有 PAM（PSM／PSMP 代登、SSH 金鑰輪替），沒有 CCP／Conjur，程式碰不到保管庫，所以下面這些要換：

| 設定 | lab | 客戶 | 為什麼 |
|---|---|---|---|
| `SSH_KEY_SOURCE` | `file` | `agent` | cpadmin 私鑰變更窗口內從 PVWA 取出貼進 ssh-agent，不落地 |
| `FETCH_JDK` | `1` | `0` | JDK 由銀行交付到 `landing/bank/` |
| `VAULT_ACCESS` | `api` | `manual` | passphrase 由人從 PVWA 取出；master key 由 Secrets 團隊存進 PVWA |
| `SUMMON` | `1` | `0` | Summon 要能自動向保管庫取值；客戶的 master key 落地 `service.env`（0600 root） |
| `LDAP_PASSWORD_VIA_ENV` | `1` | `0` | 需要 Summon；客戶的 AD 查詢密碼加密在 `security.properties`，換密碼後重跑第 16 站 |
| `OPMENU_SECRETS` | `conjur` | `manual` | 維運人員做主機類項目時才從 PVWA 貼上私鑰 |
| `OPMENU_OS_USER`、`OPMENU_ENV_LABEL` | `op01`、`LAB` | 實際帳號、`PROD`／`UAT` | |
| 主機、`DOMAIN`、`REPO_URL`、AD 的 DN、`NTP_SERVER`、`HEAP_*` | lab 值 | 實際值 | heap 依主機記憶體調整 |

客戶這組設定已在 lab 從零整套跑過（2026-10-24，CP 8.2.4，`install/lab/run-customer.sh`）：第 20 站驗收 38/38；選單的主機類項目（20.4 bob 重啟 broker）因為要人在終端機貼私鑰，列為人工驗收項目。

## 安裝完之後還會用到的

- **改了設定**（範本、`site.env` 的 heap 等）：重跑對應的站（10／12／13）。10 只重啟設定有變的主機；做過 16 會照樣加密，不會把明文寫回主機。
- **換我方管的密碼**（keystore 密碼、AD 查詢密碼）：改 0600 密碼檔後重跑第 16 站（重新加密、滾動重啟）。
- **改稽核規則**：改 `templates/audit.tpl` 後重跑第 19 站。
- **換憑證**：第 21 站（見上表）。

## 寫法約定（改腳本前先看）

目標是「翻到那一章就能改」，所以每支腳本都照同一個樣子寫：

1. **檔頭**：第 2 行是標題（install.sh --list 會顯示），`# where:` 一行寫在哪台跑，接著寫「做什麼／需要什麼／產出什麼／能不能重跑」。
2. **段落 = 手把手的小節**：`section "10.2 …"` 對 `## 10.2`；每段前面一行註解說「為什麼這樣做」，不寫「做了什麼」（程式本身就是）。
3. **遠端多行指令一律用 `ssh_script 主機 變數=值 <<'EOF' … EOF`**：heredoc 裡的 `$`、引號都在那台主機展開，和手打一樣，不跳脫。
   同一段遠端指令要用好幾次（例如 16 站），先存成有名字的變數（`SETUP_SUMMON=$(cat <<EOF … EOF)`），再 `ssh_script 主機 … <<<"$SETUP_SUMMON"`。
4. **名字寫完整**：路徑與常數用全大寫完整英文（`CERTS_DIR`、`FIRST_BROKER`、`ADMIN_CLIENT_CONF`），迴圈與暫存用小寫完整英文（`host`、`result`、`props_file`）；
   不用 `D`、`C`、`r`、`h` 這種單字母。各站共用的衍生值都在 `conf/site.env` 的下半段，先找那裡再自己取名。
5. **判斷拆兩行**：先把結果放進變數，再 `if [ "$result" = "…" ]; then ok …; else fail …; fi`，或 `case $result in 模式) ok;; *) fail;; esac`；不疊 `&& … || …` 三層。
6. **密碼**：從 0600 檔讀進變數、用完 `unset`；不放在 `ssh_script` 的參數（會出現在遠端的程序清單），不印出來。
7. **只用 bash 與 RHEL 標準指令**：ssh、curl、openssl、sed、awk、grep、tar、dnf、systemctl，加上 Confluent 自己的 CLI。不用 python、node、jq；解析 JSON 用 grep／sed（例子：19 站稽核事件、opmenu/lib/secrets/ccp.sh）。
8. **每支結尾 `finish_step`**：有 `fail` 就整站失敗；銀行還沒做完用 `wait_for_bank`（rc 2）。
9. **改完先跑 `bash install/tools/lint.sh`**，乾淨了再上 lab。真的要例外時在那一行上面寫 `# shellcheck disable=SCxxxx  # 原因`。

## 延伸站的開關（conf/site.env）

| 開關 | 意思 |
|---|---|
| `SECRETS_MODE=conjur|sp|plain` | 密碼放法：15 站（有 Conjur）／16 站（只有 PAM）／不處理。15 與 16 互斥，不適用的那支直接略過 |
| `SUMMON=1` | 16 站的 master key 不落地（16.8）；0 = 落地 `service.env` |
| `LDAP_PASSWORD_VIA_ENV=1` | 16 站 AD 查詢密碼不進密文、由 Summon 注入 `${env:…}`（16.9，需 SUMMON=1） |
| `OPMENU` `JMX_EXPORTER` `AUDIT_LOG` | 17／18／19 站要不要做 |
| `VAULT_ACCESS=api|manual` | 程式能不能直接讀寫保管庫；manual 時 16 站的 passphrase 與 master key 都經人從 PVWA 取存 |
| `OPMENU_SECRETS=conjur|ccp|manual` | 選單的 cpadmin 私鑰、緊急憑證從哪取 |
| `VAULT_*` | 保管庫位置、policy、身分檔路徑（api 時用） |

16 站一次把 16.3–16.9 做完，只滾動重啟一次；19 站依 `~/conf/secrets.mode`（15／16 留下的）決定密碼怎麼放。

## 和文件的差異（刻意的）

- 主機清單、版本、AD DN、heap 在 `conf/site.env`，範本裡用 `${CONTROLLER_QUORUM}` 這類變數；文件裡是寫死的 lab 名稱。
- REST Proxy 的 principal 對應規則由 `conf/apps.txt` 裡 `cert` 類的 app 產生（文件只有 app-legacy-billing 一個）。
- 第 6 站「主機是乾淨的」在已安裝過的主機只警告，讓整套可以重跑。
- 第 14 站的總檢查多了逐項 ok／FAIL，而不是一段輸出讓人自己對。

## lab 驗證

```bash
bash install/lab/run-all.sh            # down -v 從零；約 1.5–2 小時（下載機已有檔案時 dnf download 會 SKIPPED）
bash install/lab/run-all.sh --no-reset # 用現有 lab 重跑（驗冪等）
EXT=1 bash install/lab/run-all.sh      # 從零一路到第 20 站（約 1 小時）
bash install/lab/run-customer.sh       # 客戶模式從零到第 20 站（PVWA、Secrets 團隊、工程師貼私鑰都由它扮演）；FROM=N 從第 N 段接著跑
```

`lab/bank-sim.sh` 的每個子命令就是文件裡橘色「銀行」標籤的區塊，只是從 Windows 端對容器執行；正式環境沒有這支。
