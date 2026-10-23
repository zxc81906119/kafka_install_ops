# install/ — 照手把手文件一章一支的安裝腳本

`docs/Confluent-安裝旅程-手把手.docx`（來源 `docs/journey-src/journey.md`）第 1–20 章的每一章，對應一支 `steps/NN-*.sh`。
腳本做的事、順序、檢查點都和文件一樣；文件是給人讀的，腳本是同一條路的自動化。看不懂某一步，翻文件同一章。

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
  lab/bank-sim.sh     lab 專用：Windows 端扮演銀行（公鑰派送、OS 套件庫、AD、NTP/LB、CA 簽發、檔案交換；延伸：conjur / sp / opmenu / prometheus / coldboot）
  lab/run-all.sh      lab 專用：down -v 從零到第 14 站全自動；EXT=1 再接 15–20
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
- 重跑是安全的：dnf、install、tee 都是覆蓋成一樣的內容；格式化看到 `meta.properties` 就略過；密碑檔、cluster id、MDS token 金鑰只在不存在時產生；topic 用 `--if-not-exists`。
- 密碼不進畫面、不進 log：`~/pki/store.pass`、`~/secrets/*.pass`（0600）讀進變數後交給 envsubst 或指令。

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

## 延伸站的開關（conf/site.env）

| 開關 | 意思 |
|---|---|
| `SECRETS_MODE=conjur|sp|plain` | 密碼放法：15 站（有 Conjur）／16 站（只有 PAM）／不處理。15 與 16 互斥，不適用的那支直接略過 |
| `SUMMON=1` | 16 站的 master key 不落地（16.8）；0 = 落地 `service.env` |
| `LDAP_PASSWORD_VIA_ENV=1` | 16 站 AD 查詢密碼不進密文、由 Summon 注入 `${env:…}`（16.9，需 SUMMON=1） |
| `OPMENU` `JMX_EXPORTER` `AUDIT_LOG` | 17／18／19 站要不要做 |
| `VAULT_*` | 保管庫位置、policy、身分檔路徑 |

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
```

`lab/bank-sim.sh` 的每個子命令就是文件裡橘色「銀行」標籤的區塊，只是從 Windows 端對容器執行；正式環境沒有這支。
