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
1. ~~客戶模式從零全書重跑~~ 2026-10-25 22:40 通過：0–21 247 塊、23–28 34 塊，0 失敗；11.2／16.x／20.6／26.5 輸出逐行確認。之後再看一次 Conjur 模式第 16 章。
2. 升級演練 2026-10-26 完成：手把手第 22 章（8.2.4 起點）12 塊全過；腳本版 run-upgrade-drill.sh 全段 38/38×4、直連 6053 筆 0 遺失、**REST 失敗 4 次**（02:13:33–36，JDK 25 段重啟 REST；手冊與腳本都沒有先從 LB 拿掉 REST，只靠 nginx max_fails）→ 待使用者決定排空做法。run-customer.sh 結束碼修正 f41f053。
3. CyberArk 缺口 4：使用者決定不做（維持 20.5 離線保管）。
4. REST 重啟前先由 LB 停用（使用者選 A，2026-10-26）：手把手 3.5／12.1＋16 處（4324245）；install 建兩支小工具（c2…）、腳本 rolling_restart／22／27 走交握檔 ~/lb-requests、lab 由 bank-sim lb-watch 扮演 LB 團隊（49690bb）；OP menu 22 有 LB 連線就拒絕（638dd07）。
5. 使用者外出（2026-10-26 09:20）交代：盡量完成所有任務。排程：① 客戶手把手 0–21、23–28＋8.2.4→第 22 章（跑中）② 腳本版升級演練（驗 LB 交握、REST 應 0 失敗）③ Conjur 手把手 0–21、23–28 ④ provider 手把手 0–21。每輪逐行看、修、commit。
   - ① 2026-10-26 13:06 通過：客戶 0–21 319 塊、23–28 39 塊、8.2.4（腳本）→ 第 22 章 24 塊，0 失敗；五步共 14 輪全部「排空 0 秒、200」，12.1 演練 94 次 0 失敗。
   - ② 2026-10-26 14:35 通過：腳本版升級演練，LB 交握 8 次全部自動回覆；直連 6384 筆 0 遺失、**REST 1232 次 0 失敗**（上一輪沒排空是 4 失敗）、驗收 38/38×4。
   - ③④ 跑中（Conjur 手把手 0–21、23–28 → provider 0–21）。
- 從未 push。

## 環境狀態
- lab: **使用中（Claude）**：驗證 REST 排空（4324245）：客戶模式 0–21、23–28 從零 → 8.2.4（腳本）→ 手把手第 22 章。landing-extra 的升級套件會暫時複製進 landing，跑完自動刪。
- 密碼檔：`~/kafka-lab/secrets.env`、`~/kafka-lab/pvwa/`；ops02 `~/secrets/`、`~/pki/store.pass`。
- `install/tools/lint.sh` 沒有 shellcheck 時用 `koalaman/shellcheck:v0.10.0`。
