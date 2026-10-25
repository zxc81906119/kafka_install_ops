# 2026-10-25 手把手自檢：主線改成客戶情境

使用者定案（redesign「手冊主線改成客戶情境、全模式實測」）：主線＝客戶模式（CyberArk 只有 PAM，人工 PVWA 取放），
Conjur／CCP／Summon 移成選配；自檢後直接改、直接測；四種模式都從零實測；未確認事項用預設並標「待銀行確認」。

## 一、目前和客戶情境不符的地方（主線要改）

| 章 | 現在 | 客戶實際 | 改法 |
|---|---|---|---|
| 3.1 | 小安在 ops02 `ssh-keygen`，私鑰放 `~/.ssh` | CyberArk SSH Key Manager 產生金鑰對、推公鑰；私鑰在 PVWA，工程師每次作業貼進 ssh-agent（不落地） | 銀行（lab：Lab 管理員）產生金鑰放「PVWA」（lab：`~/kafka-lab/pvwa/`）、推公鑰；小安開 agent（固定 socket）、貼私鑰；冷開機後重貼 |
| 3.4、10.4、11 | 密碼產生後只放 ops02 `~/secrets` | 交 Secrets 團隊放 PVWA（正本），小安手上是工作副本 | 加「交付保管」步驟（lab：複製進 pvwa/），標明哪些密碼、哪個 object |
| 14 | 「15／16 二選一」 | 客戶沒有 Conjur | 主線＝16；15 標為選配（銀行有 Conjur 才做） |
| 16.1、16.2、16.6 | 用 Conjur 扮演 PAM（要先做 15.1） | Secrets 團隊在 PVWA 開兩個 object；小安人工取 passphrase、交 master key、記單號 | 改成 PVWA 人工流程（lab：pvwa/ 資料夾），不再依賴 15.1；Conjur 寫法留作選配 |
| 16.8、16.9 | 主線裡的選配，需 Conjur | 客戶沒有 | 標「選配：需要 Conjur」，客戶模式跳過 |
| 17 | 選單的 SSH 私鑰、breakglass 從 Conjur 取（`OPMENU_SECRETS=conjur`） | `manual`：維運人員從 PVWA 取私鑰貼進選單；breakglass 由 Secrets 團隊依程序提供 | 主線改 manual；Conjur 版留作選配 |
| 20.4 | 冷開機含 Conjur、Summon 重試 | 沒有 Conjur；ssh-agent 會隨操作機重開而消失 | 主線不含 Conjur；冷開機後重貼私鑰 |
| 21.2.5、21.3.3、21.4.4 | breakglass PEM 寫進 Conjur；銀行換鏈包含 conjur 伺服器 | 新 PEM 交 Secrets 團隊放 PVWA；銀行伺服器只有 AD、套件庫 | 主線改 PVWA 交付；conjur 那段標選配 |

## 二、順序

- `svc-backup` 憑證在第 26 章才發 → 移到第 9 章和其他憑證一起發（8 張）。
- license 監控（23.2）、每日備份（26.2–26.4）是交付項目，不是「上線之後」：章號不動（避免整本與 install 站號重編），
  在 0.4 寫清楚「交付前：0–20 與 23.2、26；上線後：21、22、24、25、27、28」，20.5 的交付清單列出這兩個排程。
- 第 15 章（選配）放在第 16 章（主線）前面：維持位置，章首標「選配：銀行有 Conjur 才做；客戶模式直接跳到第 16 章」。

## 三、內容不足

- 0.2 環境地圖沒有 PVWA（CyberArk PAM）的位置；0.4 的時間表沒有 23–28。
- 排程（23.2、26.4）、行內 Prometheus 認證（18）、7071 來源限制：標「待銀行確認」並指到請銀行確認事項 11.3、11.4。
- 第 19 章沒有 Conjur provider 環境的做法（provider 模式要實測，需要補）。

## 四、測試方式

run-chapter.js 加模式（customer／conjur／provider）：手把手用 `@only <模式>` 標記只在某些模式做的段落，
其他模式跳過。四種實測：
1. 客戶模式：從零，手把手 0–28（跳過 15、16.8、16.9、Conjur 選配段）＋ install 客戶模式全站（含 21–28）。
2. Conjur 模式：從零，手把手含 15、16.8、16.9、17 的 Conjur 版＋ install lab 模式。
3. provider 模式：從零，15 之後不做 16，接 17–20（Conjur provider 管密碼）。
4. 升級演練：8.2.4 起，第 22 章＋ run-upgrade-drill.sh。
每次跑完 `docs/journey-src/tools/scan-log.sh`。
