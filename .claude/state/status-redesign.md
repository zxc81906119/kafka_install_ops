# Status — branch `redesign`

Updated: 2026-10-25 晚上（lab 使用中：Claude）

## 現在在做什麼
手把手（`docs/journey-src/journey.md`，第 0–28 章，三種模式 customer／conjur／provider）＋ `install/` 一章一支的腳本，
以 `lab` 專案從零實跑驗證所有模式。設計紀錄在 `redesign/README.md`；今天的細節在 `log/2026-10-25-cleanup-and-cyberark-gaps.md`。

## 做到哪
- e283fc5：只保留現行設計（舊 cpctl PoC、cp-poc／cp-man、windows/、舊手冊、全流程簡報、主機清單、jump01 設計全刪；磁碟資料與
  `cp-*:poc` 映像檔也刪了）。
- 手把手新增／修正（第二個 commit）：11.2 kafka-admin 用後換密碼、20.6 SSH Key Manager 換金鑰演練、3.1／3.4／16.x 正式環境
  不回顯貼法（`stty -echo`、`read -rs`、`ssh-add -t 10h`）、16.10 CPM 換 bind 密碼（客戶模式）、16.3 補 `AUDIT_PASSWORD`
  ＋「沒替換到的變數」檢查、16.5／16.6 結尾「用 PVWA 的 passphrase 還能輪替、錯的被拒」檢查、LDAP 錯誤數只算本次啟動後的
  `javax.naming`、26.5 補 demo topic。
- **重大發現**：Confluent CLI v4.72 的 `--passphrase @檔案` 是把路徑字串當 passphrase（PVWA 的值從沒用到）。已改成
  `"$(cat 檔案)"`（手把手 16.2／16.6、install 16）；代價是行程參數 → 問題清單 4.6 `hidepid=2`。
- 測試矩陣：客戶 0–21（240 塊）、provider 0–21（192 塊）、Conjur 0–21／23–28、install 客戶 1–25（38/38）、Conjur install（39/39）
  都通過，但都是在上述修正**之前**。第 16 章修正後在 lab 上重跑：passphrase 檢查兩次都「是」，16.10 bind 驗證 200。

## 下一步
1. 客戶模式從零全書重跑（0–21、23–28），驗證 11.2、16.x、20.6、26.5 的新寫法；再看一次 Conjur 模式第 16 章。
2. 升級演練：`~/kafka-lab/landing-extra/*` 搬回 `landing`，`run-upgrade-drill.sh`；再 `CP_VERSION=8.2.4 TO=17 run-customer.sh`
   後 `run-full.sh customer 22 23`。
3. CyberArk 缺口 4（svc-ops／MDS token 私鑰正本：建議放 PVWA 專屬 safe）待使用者決定。
- 從未 push。

## 環境狀態
- lab: **使用中（Claude）**。第 16 章是在做完第 21 章的 lab 上倒回重跑的：稽核寫入（confluent-audit）的 SCRAM 在 kb* 上一直
  失敗（16.3 舊寫法沒換 `AUDIT_PASSWORD`，已修），這個 lab 狀態不再用，下一輪從零重建。
- 密碼檔：`~/kafka-lab/secrets.env`、`~/kafka-lab/pvwa/`；ops02 `~/secrets/`、`~/pki/store.pass`。
- `install/tools/lint.sh` 沒有 shellcheck 時用 `koalaman/shellcheck:v0.10.0`。
