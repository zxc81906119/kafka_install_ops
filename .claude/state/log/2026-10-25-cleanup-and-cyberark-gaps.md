# 2026-10-25 晚 — 舊 PoC 清除、CyberArk 缺口、16.10、Secret Protection 輪替

## 決定（使用者）
- 「只保留現行設計」：舊 cpctl（installer/）、docker/（cp-poc、cp-man）、windows/、舊手動手冊＋transcripts、全流程簡報、
  主機準備清單、jump01 堡壘機設計，從 redesign 分支全部刪除；磁碟資料（packages*、delivery、bank-ca）、舊容器／volume／
  網路／`cp-*:poc` 映像檔也刪除。README、CLAUDE.md、skills、memory 改寫為只描述現行設計。
- 客戶模式補 16.10（CPM 換 svc-mds-bind 密碼）；A／B 與「關掉自動排程」列問題清單 8.6。
- CyberArk 缺口：1 貼機密不回顯（可以改）、2 kafka-admin 用後換密碼（可以做；緊急帳號一組即可）、3 cpadmin 金鑰被換後
  重貼（可以寫）、5 釐清：ops02 就是維運登入點，SSH 金鑰只有 cpadmin 一組、6 cpadmin NOPASSWD＋reconcile 帳號不用 cpadmin、
  7 PSMP 指令白名單問銀行。4（super user 私鑰正本放 PVWA safe）待決定。
- MDS token 金鑰不輪替（再次確認）；data key 不例行輪替（懷疑外洩時換密碼本身）；master key 週期問銀行（8.7）。

## 做了什麼
- 手把手：3.1 `stty -echo; ssh-add -t 10h -`＋金鑰被換的陷阱；3.4／16.2／16.6／16.10 正式環境用 `read -rs` 貼法；
  0.4 規則；新增 11.2（kafka-admin 用後換密碼，輸出丟 /dev/null，新密碼先暫存）、20.6（SSH Key Manager 輪替演練）；
  16.7 兩行（rotate 需要 passphrase＋master key、data key 不例行換）；16.10 驗證改用 alice 登入 MDS（client-alice
  第 19 章才建）、密文參照 grep 容許空白；26.5 補「新建 demo topic、等下一分鐘再匯出」與清除（原本兩份備份一樣）。
- 問題清單：8.4 擴充、8.6、8.7、8.8。
- scan-log.sh：新增「冒號後沒有值」檢查（不受排除清單影響）；重掃舊紀錄抓到 16.10 與 26.5（客戶、Conjur 都是）。
- lint.sh 改用 koalaman/shellcheck:v0.10.0（舊映像檔刪除前換掉；實跑乾淨，故意錯的檔有抓到）。

## 實測
- provider 手把手 0–21：192 塊 0 失敗。
- 客戶手把手 0–21（第二輪；第一輪在 3.2 外網鏡像暫時失敗）：240 塊 0 失敗、掃描乾淨——但逐行看出 16.10 兩行錯（已修，見上）。
- Secret Protection（ops02 副本）：rotate 不給舊 master key → `master key is not exported`；不給 --passphrase → required；
  任一錯 → `incorrect master key passphrase`；`master-key generate` 對已有 key 的檔拒絕；openssl PBKDF2 常見參數算不出。
- **待查**：本輪實跑後 ops02 的 passphrase＋master key 無法再 rotate（四種組合都失敗、解密正常；metadata 時間＝16.6 那一刻）；
  副本上 16.2→16.3→16.6→16.10 重做可重複輪替。已在 lab 重跑第 16 章並插入檢查點（~/kafka-lab-runs/probe16.*）。
- `--add-config-file` 不能設 SCRAM（讀成 SCRAM_SHA_512）。

## 注意
- 測試時 kafka-configs 出錯把整串設定印出（臨時帳號，未建立）；另外查格式時印出了 lab 的 store.pass 到工具輸出（未進對話）。
  lab 值；下次從零重建會重產。新程序一律把 kafka-configs 輸出丟掉。
