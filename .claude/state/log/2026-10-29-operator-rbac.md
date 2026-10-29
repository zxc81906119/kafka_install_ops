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

## 28.6 MDS 的 8090 不能用時（手動實跑 → 手冊 → 腳本，都過）
- lab 由網路團隊在 kb01–04 加 runtime rich rule 擋操作機（172.35.0.10）→ 8090；REST、C3、broker 之間不受影響。
- 選單：登入失敗時、緊急主機模式擋下 Kafka 項目時，都指向 28.6 的 kafka-admin（opmenu.sh、lib/common.sh）。
- 緊急主機模式：手冊原本只在 16 章表格寫「OS 團隊建 opmenu-emergency」，沒有指令真的建；28.6 由 OS 團隊 `groupadd -f` 後加 root。群組要**重新登入**才生效（lab 用 `su - root`）。
- kafka-admin（9095）：列 topic、under-replicated、建 topic、改 retention、刪 topic 都可以；用完照 20.2 換密碼。做不到：改 role binding、91 緊急憑證（也要 MDS）。
- 腳本：bank-sim `mds-block on|off`、`emergency-group add|remove`；28-triage.sh `mds-down`、`mds-back`（mds-back 自動換 kafka-admin 密碼）；run-customer 第 28 段接上（演練失敗也會開回、移出群組）。
- 第二輪 out 比對（數字不正規化，scratchpad cmp-num.js）：B.2 漏收 lab-mon-blackbox、17.7 舊值、21.2.3 檔數 18、25.2.3 把 NOT_LEADER 重試警告算成錯誤、27.4 bank-root.pem 變 700（改 install -m 0600）、3.2／16.3 數量。
- build.js 新增：``` 沒成對或少了某一章就停（這次 25.2.3 多插一個 ``` 讓 run-chapter 找不到第 28 章）。
- 我的疏失：檢查 kafka-admin 設定檔時把 truststore 密碼印到聊天（lab，只保護公開的根憑證）；之後檢查設定檔一律濾掉含 password 的行。
