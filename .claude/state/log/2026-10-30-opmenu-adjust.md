# 2026-10-30 OP menu 項目調整（使用者自檢後選定）

- 做法照三步：lab 先以 alice（SystemAdmin）、bob（Operator＋DeveloperManage）手動試原始指令 → 改 opmenu → 手冊 16.5／18.3／23.5 → 16 站腳本與 `install/lab/opmenu-items-test.sh`。
- 試出來的權限：配額 describe／alter 要叢集層級 DescribeConfigs／AlterConfigs（bob 被 `ClusterAuthorizationException`）；`_confluent-command` bob 讀不到 → 17 改看 `journalctl -t confluent-license` 最後一筆。
- 新項目：13 consumer group（lag＋在線成員）、15 查看配額、38 調整配額、17 加 license、43 查詢與匯出（合併 45）；拿掉 15 舊的 application 連線、45。選單：10 11 12 13 14 15 16 17 18 19 21 22 23 27 31 32 33 34 35 36 37 38 41 42 43 44 91。
- 13 查全部時遙測 group `ConfluentTelemetryReporterSampler-*`（lag 十幾萬、0 成員）會誤導 → `OPMENU_INTERNAL_GROUP_PATTERN`，C3 自己的 group（`poc-cluster*`）寫在 lab 的 opmenu.conf（16.3、templates/opmenu.conf）。
- 44 快照 vs 每日備份：先 7 個檔有 6 個不同 → ops02 沒有 `cmp`（改 sha256 比）；rbac.txt 少 binding → `printf '%s' "$arr" | sed` 最後一行沒換行，`read` 丟掉（權限清單 CSV 也一樣，13 筆 → 33 筆）。修完 7 個檔都相同；乾跑還原解析 33 條；23.6 drill 用新格式通過。
- 每日備份 rbac.txt 改格式（去對齊空白、排序、LC_ALL=C），手冊 23.3 原文重跑通過（rbac 48 行、15 principal）。
- 43 互動模式用 `script -qec` 測過：逐項問、最後問存檔、y 就存（0600）。時間改本地時間。
- 16 站新檢查在 ops02 單獨跑：13 在線 1、bob 15 拒絕、15 看得到配額、38 改了再改回、17 有 license，FAIL 0。
- 小地方：手冊第 18 章原本說 43／45 讀兩個 audit topic，其實只讀 `confluent-audit-log-events`；已更正並列為待確認（稽核要不要看 `_sensitive`）。
- 全項目回歸 `install/lab/opmenu-items-test.sh`：45/45 通過（新增 13 成員數、17 license、38→15、43 save、44 rbac.txt 的檢查）。
- 使用者選定：43 加選項看 `_sensitive`（一般／敏感／兩個都看，第 5 個參數 normal|sensitive|all）。`k_audit_fetch` 可讀多個 topic、依事件時間合併。lab：一般 658 筆、敏感 9 筆（alice 寫 payments.events、app-orders-a describe 被拒）、全部 DENIED 19 筆、carol 被拒。手冊 18.3 照原文跑過。請銀行確認事項加 9.5（哪些 topic 算敏感、保留多久）。
