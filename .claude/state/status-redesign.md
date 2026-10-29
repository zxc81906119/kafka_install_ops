# Status — branch `redesign`

Updated: 2026-10-29 17:20（lab 空著：手冊實跑已完成，lab 停在遷移完成後的狀態，8.3.2／JDK 25／OS 9.8／C3 2.6.1）

## 現在在做什麼
手冊實跑結果收尾：已修 out 值與三個問題、加 11.3 RBAC 全貌，正在重建 docx 後 commit。

## 今天（10-29）做完
- 補章 22、24、27、28、30 保險；腳本版從零通過（34 段、7×42/42）；MDS 50003（mds_write）；docx 控制字元；選單 token 換新、91 逐台找 MDS；手冊不依賴 repo（第 0 章、選單交付物）。
- **手冊從第 2 章實跑到 B：386 塊全過**（紀錄 `~/kafka-lab-runs/run-customer-2-end-20261029-1044.log`）。逐塊比對 out 找到並修：
  - 維運群組 DeveloperRead 沒有 DescribeConfigs → 選單 11／21／27 被拒。**定案改回 DeveloperManage Topic:*** ＋ DeveloperRead Group:*（使用者：非不得已不用 ACL、不要選單多一支 Java）。redesign 有一段。
  - 30 章 lab 的 os-reboot.sh 把 kc／kb 上 disabled 的 confluent-kafka-rest 叫起來 → 只重啟 enabled unit；30.5 驗證會列出在跑的 unit。
  - 22.3 過期憑證用 `-not_after`（OS 9.6 的 OpenSSL 3.2 不支援）→ `openssl ca -startdate/-enddate`。
  - 選單 33：consumer 檢查失敗就拒絕刪除。
  - 新增手冊 11.3「RBAC 全貌」（D.rbacmodel：範圍、子 cluster、資源、10 個角色；從 MDS 印角色定義的指令與對照表）。
  - log：log/2026-10-29-operator-rbac.md。

## 下一步（依序）
1. 第 28 章新增 28.6「MDS 的 8090 不能用時」：lab 由「銀行網路團隊」在 kb01–04 用 firewalld 暫拿掉 8090 → 選單登入失敗、91 提示 → `kafka-admin`（SCRAM、9095）做 topic 類操作 → 開回 8090 → 照 20.2 換 kafka-admin 密碼。先手動實跑再寫。
2. C3 Streams／RocksDB 監控（使用者要加）：C3 的 jmx 規則改為官方 `kafka_streams.yml` 只收 `kafka.streams:*`（我們的 client_state、Jetty 規則放前面）；先在 lab 量序列數、確認 C3 的 MBean key 順序不會讓官方 pattern 拆錯 label；告警（背景錯誤、丟棄紀錄、處理停滯）→ 手冊 17 章／附錄 B → 腳本 17 站；更正 redesign「C3 維持精簡」。
3. 腳本版從零再跑一次（驗今天全部改動，含 rbac-opmenu.txt 與選單 33）。
- 待使用者決定／回覆銀行：bob 有 Group Read＋Topic Describe，選單 36 能重設任何 group 的 offset（不是這次造成的）要不要收；opmenu-emergency 對 root 的意義；換金鑰週期；dashboard job label；docs/evidence 版控；omnibus 正式值；銀行有沒有 Kafka Streams 應用。

## 環境狀態
- lab：專案 `lab`，手冊實跑後的狀態；手動改過：kafka-operators 綁定已改、kc／kb 的 kafka-rest 已停、ops02 /opt/opmenu/items/33 已換新版。四個 `lab-mon-*` 與 `lab-mon-blackbox` 在跑。
- Docker VM 約 10.7 GB，不要同時跑別的。
- 密碼檔：`~/kafka-lab/secrets.env`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node；跑手冊片段時 `export MSYS_NO_PATHCONV=1`。
