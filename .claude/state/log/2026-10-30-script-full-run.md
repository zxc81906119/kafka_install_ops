# 2026-10-30 腳本版從零實跑（run-customer.sh）

- 紀錄：`~/kafka-lab-runs/run-customer-full-20261030-1745.log`，17:45–20:31（9796 s），34 段，rc=0。
- 驗收 6 次都 42/42（基底、遷移各段、finalize 後、OS 9.8 後、C3 回滾後）；最後狀態 10 台 OS 9.8、CP 8.3.2、C3 2.6.1、JDK 25。
- 這次要驗的三件都過：exporter 1.7.0（sha256＋GPG）；28.6 緊急主機模式不看群組（23 可、31 擋）＋kafka-admin 經 9095 操作 topic；23 站 `acls.txt` 一條一行、23.6 還原演練全過、26 站 license 剩 29 天 WARN。
- 預期中的 FAIL：第 4 站 18:01 銀行還沒開 cpuser（12 筆），銀行做完重跑通過。
- **找到假通過**：11.2 AD 斷線演練（`bank-sim.sh ad-drill`）拿 `~/conf/app-orders.properties` 當 kafka-admin 連線設定的底，但腳本版要到第 19 站才產生這個檔（手冊在第 11 章前段就建了）。沒有設定 → kafka-topics 在 stdout 印 `Error while executing topic command`，`grep -c .` 算成 1 個 topic → 判定通過。
  - 修：ad-drill 自己組 SASL_SSL／SCRAM 設定（truststore＋`~/pki/store.pass`）；手冊 11.2 與 ad-drill 計數改 `grep -vc -e '^Error' -e '^$'`。
  - 重跑 ad-drill：alice 401、kafka-admin 列出 20 個、AD 開回 alice 200；錯密碼反向測試算成 0。手冊 docx 重建。
- 教訓：用「數行數」判斷成功時，工具的錯誤訊息可能印在 stdout；要排除錯誤行，或比對一個一定存在的名稱。
- 21:50、22:58 兩輪含 OP menu 調整的從零實跑都中斷：Windows 22:02–23:05 當機 5 次（Kernel-Power 41；BugCheck 0x7E，可能的驅動 rtwlanu.sys＝Realtek USB 無線網卡，dump 在 C:\Windows\Minidump），之後 Docker 又出現 sailor-ingest.sock 問題（run 目錄改名 run.old-20261030-2252 修好）。使用者決定先處理網卡（更新驅動或改有線）再重跑。
