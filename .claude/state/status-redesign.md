# Status — branch `redesign`

Updated: 2026-10-28 10:50（**lab 使用中**：乾淨手冊實跑從零進行中，勿動 Docker）

## 現在在做什麼
`bash docs/journey-src/tools/run-full.sh customer` 從零跑（開始 10:46，紀錄 `~/kafka-lab-runs/run-customer-0-99-20261028-1046.log`，路徑也在 `~/kafka-lab-runs/current-log.txt`）。
這輪是最終版文字：cp-server 純 server 憑證＋c3-monitoring（9 張憑證）、移除兩條 raft 告警（19 條規則）。失敗就修、再從頭跑。

## 已完成（都已 commit，從未 push）
- 手把手 0–27 章（38 圖）＋ install 01–26 站；基底 OS 9.6／CP 8.2.4／C3 2.5.1／JDK 21 → 遷移 OS 9.8／CP 8.3.2／C3 2.6.1／JDK 25。
- 腳本版從零跑完（舊文字），結束碼 0，各段驗收 39/39。
- 2026-10-28：cp-server 改純 server（certs.txt、09／13／14／19／20 站、control-center.tpl、prometheus-generated.yml、手冊第 9／13／20 章、問題清單 6.2、圖）；19 站新增驗收「cp-server 只有 serverAuth 且連 9090 被拒」；第 17 章 raft 指標說明更正、兩條 raft 告警刪除。docx 已重建。

## 下一步
1. 手冊實跑完 → 逐行看紀錄＋`scan-log.sh`；特別確認：c3-01 檔案數 10、C3 對 9090／9093 連線正常（keystore alias c3-monitoring）、第 9 章 CSR／檔案數（9、21）、20.2 的數字、17 章告警規則載入數 19、17.9 覆蓋率重算。
2. 再 `bash install/lab/run-customer.sh` 從零（驗收會多一項，應 40/40）。
3. **章節重構（使用者 2026-10-28 已確認照 `redesign/chapter-restructure.md`：31 章＋2 附錄、維運章在遷移之前、15/17/18 維持分開）**：實跑與腳本重跑結束後，先改結構與編號（對照表寫改寫工具，改 install/steps 檔名、site.env、bank-sim、run-customer、run-chapter、run-full、圖、問題清單、README、CLAUDE.md、skills），跑一次確認等價，再補新內容。
4. **補章（使用者已同意，先手動實跑驗證、再做腳本；等 1、2 做完才動 lab）**：還原演練（25）、磁碟告警與換碟（17＋新節）、故障排查速查、新應用上線流程；細節 `log/2026-10-28-coverage-gaps-plan.md`。
5. 假的 omnibus 接收端（十欄位驗證）；可讀性尚未細改的章節（12、13、14、17、20.3／20.4、22–25、0.5.x）；15.3、18.3 out 區塊舊稱「第 18 站／16 站」。
- 待使用者決定／回覆銀行：`opmenu-emergency` 對 root 的意義；換金鑰週期；dashboard `job="kafka-broker"` 要不要 sed 修；C3 是否多放行 RocksDB／Streams；`docs/evidence/` 要不要版控；omnibus 固定值（source/ClassName/origin/hostname/sub_source）正式值。

- 已結案（2026-10-28）：repodeploy 是 lab 模擬「銀行把 RPM 放進 repo01」的帳號，cpuser 本來就不在 repo01；手冊與腳本這段不改，正式環境如何上架等銀行回覆。

## 環境狀態
- lab：專案 `lab`，**從零重建中**（run-full 會先拆掉整個 lab，只留 `~/kafka-lab/landing`、`~/kafka-lab/bank-os`）。四個 `lab-mon-*` 容器由跑本身處理。
- Docker VM 約 10.7 GB，不要同時跑別的；使用者其他專案的映像／卷不要動。
- 密碼檔：`~/kafka-lab/secrets.env`、`~/kafka-lab/pvwa/`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node／Edit／sed。補丁腳本放 scratchpad，用 `node` 跑。
- 背景 monitor 的過期通知可忽略。
