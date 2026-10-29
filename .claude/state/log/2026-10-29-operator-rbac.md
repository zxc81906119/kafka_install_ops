# 2026-10-29 維運群組權限、手冊實跑結果

- 手冊從第 2 章實跑到附錄 B：386 塊全過、scan-log 無可疑；逐塊比對 out（scratchpad cmp-out.js）找到：
  - bob 用選單 11／21 被 Kafka 拒絕（DeveloperRead 沒有 DescribeConfigs）→ 改回 DeveloperManage Topic:*（使用者定案，見 redesign）。
  - 30 章 lab 的 os-reboot.sh「改重啟平台服務」把 kc／kb 上 disabled 的 confluent-kafka-rest 也叫起來（開了沒設定的 8082）→ 只重啟 enabled 的 unit；30.5 驗證改列 enabled 或在跑的 unit。腳本版（unit_of）沒有這個問題。
  - 22.3 的過期測試憑證用 `-not_after`（要 OpenSSL 3.4；OS 9.6 是 3.2.2），沒產生也沒報錯 → 改 `openssl ca -startdate/-enddate`，失敗就停。
  - 其餘 out 值：11 的 binding 表格式、5.x errors 每台 broker、21／27 的 openssl subject 格式、22.2 告警檔與條數、24 告警 24 條、27 用 ca/g2 簽、28.3 pending 是 CertificateProbeFailed（補說明）。
- 選單 33：consumer 檢查失敗就拒絕刪除（原本會照刪）。
- 使用者原則：非到不得已不用 ACL；不要選單多一支 Java。
- 手冊新增 11.3 RBAC 全貌（D.rbacmodel、從 MDS 印角色定義的指令、角色對照表）；D.rbac 的 bob 列更新。
- lab 狀態：kafka-operators 已改綁 DeveloperManage Topic:*（DeveloperRead Topic:* 已刪）；kc／kb 的 confluent-kafka-rest 已停；ops02 的 /opt/opmenu/items/33 已換新版。
