# install/ — 照手把手文件一章一支的安裝腳本

`docs/Confluent-安裝旅程-手把手.docx`（來源 `docs/journey-src/journey.md`）第 1–14 章的每一章，對應一支 `steps/NN-*.sh`。
腳本做的事、順序、檢查點都和文件一樣；文件是給人讀的，腳本是同一條路的自動化。看不懂某一步，翻文件同一章。

```
install/
  install.sh          依序跑 steps/（--list / --from NN / --to NN / --only NN）
  conf/site.env       站點設定：主機名稱、版本、AD、heap、目錄。每個環境只改這一個檔
  conf/certs.txt      要請銀行 CA 簽的憑證（名稱、EKU、SAN 種類）
  conf/apps.txt       應用程式：SCRAM 直連或憑證走 REST、配額
  conf/rbac.txt       role binding（人員綁 AD 群組，服務與 app 綁最小權限）
  conf/topics.txt     範例 topic
  lib/ssh.sh          rsh / rsh_as / rcp / each —— 操作機對各主機的 ssh、scp
  lib/render.sh       render / render_cat —— envsubst 只換列出來的 ${變數}
  lib/log.sh          log / ok / fail / die / bank / pending / finish —— 畫面 + ~/install-logs/
  templates/          *.tpl（properties 範本，取自文件第 10、12、13 章）、*.dropin（systemd）、Prometheus 設定
  steps/01–14         一章一支
  lab/bank-sim.sh     lab 專用：Windows 端扮演銀行（公鑰派送、OS 套件庫、AD、NTP/LB、CA 簽發、檔案交換）
  lab/run-all.sh      lab 專用：down -v 從零到第 14 站全自動
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

## 和文件的差異（刻意的）

- 主機清單、版本、AD DN、heap 在 `conf/site.env`，範本裡用 `${CONTROLLER_QUORUM}` 這類變數；文件裡是寫死的 lab 名稱。
- REST Proxy 的 principal 對應規則由 `conf/apps.txt` 裡 `cert` 類的 app 產生（文件只有 app-legacy-billing 一個）。
- 第 6 站「主機是乾淨的」在已安裝過的主機只警告，讓整套可以重跑。
- 第 14 站的總檢查多了逐項 ok／FAIL，而不是一段輸出讓人自己對。

## lab 驗證

```bash
bash install/lab/run-all.sh            # down -v 從零；約 1.5–2 小時（下載機已有檔案時 dnf download 會 SKIPPED）
bash install/lab/run-all.sh --no-reset # 用現有 lab 重跑（驗冪等）
```

`lab/bank-sim.sh` 的每個子命令就是文件裡橘色「銀行」標籤的區塊，只是從 Windows 端對容器執行；正式環境沒有這支。
