# Status — branch `redesign`

Updated: 2026-10-29 19:00（lab 空著，遷移完成後的狀態；監控容器已由 B.2 收掉）

## 現在在做什麼
手冊實跑收尾、28.6、C3 Streams／RocksDB 監控都做完並 commit；下一項是腳本版從零再跑一次。

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
  - log：log/2026-10-29-operator-rbac.md。

## 下一步（依序）
1. 腳本版從零再跑一次（驗今天全部改動：rbac-opmenu.txt、選單 33／28.6 訊息、28-triage mds-down／mds-back、17 站 C3 規則與 22 條告警、21 站同步 to-bank ca.pem）。
- 待使用者決定／回覆銀行：opmenu-emergency 對 root 的意義；換金鑰週期；dashboard job label；docs/evidence 版控；omnibus 正式值；銀行有沒有 Kafka Streams 應用。

## 環境狀態
- lab：專案 `lab`，手冊實跑後的狀態；手動改過：kafka-operators 綁定已改、kc／kb 的 kafka-rest 已停、ops02 /opt/opmenu 的 items/33、opmenu.sh、lib/common.sh 已換新版；kafka-admin 密碼今天換過兩次（已存回 ~/secrets/kafka-admin.pass）。監控容器已由 B.2 收掉（要用時照 17.6、22.2 或 bank-sim monitoring／monitoring-blackbox 起回來）。
- Docker VM 約 10.7 GB，不要同時跑別的。
- 密碼檔：`~/kafka-lab/secrets.env`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node；跑手冊片段時 `export MSYS_NO_PATHCONV=1`。
