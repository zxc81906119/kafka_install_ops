# Status — branch `redesign`

Updated: 2026-10-30 09:30（lab 空著：手冊完整實跑後的狀態，8.3.2／JDK 25／OS 9.8／C3 2.6.1，監控容器已由 B.2 收掉）

## 現在在做什麼
10-29、10-30 的工作都做完並 commit：**手冊從第 0 章完整實跑通過**（407 塊）。沒有進行中的工作。

## 今天（10-29）做完
- 補章 22、24、27、28、30 保險；腳本版從零通過（34 段、7×42/42）；MDS 50003（mds_write）；docx 控制字元；選單 token 換新、91 逐台找 MDS；手冊不依賴 repo（第 0 章、選單交付物）。
- **手冊從第 2 章實跑到 B：386 塊全過**（紀錄 `~/kafka-lab-runs/run-customer-2-end-20261029-1044.log`）。逐塊比對 out 找到並修：
  - 維運群組 DeveloperRead 沒有 DescribeConfigs → 選單 11／21／27 被拒。**定案改回 DeveloperManage Topic:*** ＋ DeveloperRead Group:*（使用者：非不得已不用 ACL、不要選單多一支 Java）。redesign 有一段。
  - 30 章 lab 的 os-reboot.sh 把 kc／kb 上 disabled 的 confluent-kafka-rest 叫起來 → 只重啟 enabled unit；30.5 驗證會列出在跑的 unit。
  - 22.3 過期憑證用 `-not_after`（OS 9.6 的 OpenSSL 3.2 不支援）→ `openssl ca -startdate/-enddate`。
  - 選單 33：consumer 檢查失敗就拒絕刪除。
  - 新增手冊 11.3「RBAC 全貌」（D.rbacmodel：範圍、子 cluster、資源、10 個角色；從 MDS 印角色定義的指令與對照表）。
  - **28.6「MDS 的 8090 不能用時」做完**：手動實跑、手冊（第 28 章 16 塊照打全過）、腳本（mds-down／mds-back 實測過）；選單提示指向 28.6。
  - 第二輪 out 比對（數字不正規化）再修 6 處；build.js 擋 ``` 沒成對。
  - **C3 Streams／RocksDB 監控做完**：C3 收 kafka.streams:*（約 2,100 條）＋官方 kafka_streams.yml 規則（我方先命名帶 process-id 的幾項）；告警 5 條；手冊 17、22、24、B 照打全過；B.1 Streams dashboard 26/27、39/40。
  - 21 章換根憑證時同步 to-bank/prometheus/ca.pem（手冊四處＋21-cert-rotate.sh）。
  - 緊急主機模式不看群組（使用者定案，見 redesign）。
  - log：log/2026-10-29-operator-rbac.md。

## 下一步（依序）
1. ~~腳本版從零再跑一次~~ **通過**（23:00，rc 0；34 段、7×42/42、遷移與 OS 9.8 期間流量 0 遺失；途中修 02 站 SHA256SUMS、16 站 bob 檢查、KafkaProduceLatencyHigh）。
2. ~~JMX exporter 升 1.7.0＋keystore 密碼改環境變數~~ **做完**：手冊 2、3、17、B 照打全過（10 台 1.7.0、env=600、B.1 覆蓋率不變）；腳本 02／17 站已改（下一次腳本版從零跑會驗）。
3. ~~手冊從第 0 章完整實跑~~ **通過**（2026-10-30；log/2026-10-30-full-manual-run.md）。
4. 下一次腳本版從零跑時驗：exporter 1.7.0（02／17 站）、緊急主機模式不看群組（28-triage）。
- 待使用者決定／回覆銀行：換金鑰週期；omnibus 正式值。（已答：銀行沒有 Kafka Streams 應用；dashboard job label 維持官方名稱、不改官方檔；docs/evidence 不進版控。）

## 環境狀態
- lab：專案 `lab`，手冊實跑後的狀態；手動改過：kafka-operators 綁定已改、kc／kb 的 kafka-rest 已停、ops02 /opt/opmenu 的 items/33、opmenu.sh、lib/common.sh 已換新版；kafka-admin 密碼今天換過兩次（已存回 ~/secrets/kafka-admin.pass）。監控容器已由 B.2 收掉（要用時照 17.6、22.2 或 bank-sim monitoring／monitoring-blackbox 起回來）。
- Docker VM 約 10.7 GB，不要同時跑別的。
- 密碼檔：`~/kafka-lab/secrets.env`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node；跑手冊片段時 `export MSYS_NO_PATHCONV=1`。
