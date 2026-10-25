# 2026-10-24 夜 → 10-25 凌晨：全書重跑、21.4 換鏈、第 23–26 章、補強（lab 模式，Claude 自主進行）

使用者睡前交代：「早上要做完，我要驗收」。

## 全書重跑（第 0–21 章，189 塊）
- 185 塊 rc=0；4 塊是 `-it` 互動指令，依設計略過。第 21 章（G2 三階段＋13 個端點的 G2 檢查）這次完整通過，21.3.4 不再讓叢集斷掉；17 章末 kb04 的全權 sudo 有還原，18.2、19.2 在 kb04 上都成功。
- **被遮住的失敗**（rc 0 但其實失敗）：3.4 隨機產生的 AD 測試帳號密碼不符 Samba 複雜度（大寫、小寫、數字），alice/bob/carol 沒建 →
  15.6、15.7、16.5、16.6 的「alice login」都是 401；16.9 alice 建 topic 空白；17.5 選單「登入失敗」；17.6 紀錄 AUTH_FAIL。
  - 修：guide 0.5（AD 管理員密碼）、3.4、16 章兩處演練、bank-sim 都改成「重抽到三類字元齊全」；3.4／bank-sim 建帳號失敗時整段回非 0。
  - lab：補建三個帳號（新密碼），ops02 `~/secrets/ad-test-users.pass` 已更新；17.5、第 11 章角色檢查、第 14 章清單補跑通過。
  - 下次掃描遮蔽失敗要加：`ERROR`、`登入失敗`、`login: 401`、`AUTH_FAIL`。
- 17.5 的預期輸出更正：bob 看不到 43／45（稽核紀錄要 audit topic 讀取權限，沒有綁給 operators）。

## 21.4 換鏈（G3 新根、中繼 G2 沿用私鑰由 G3 重簽）
- 手打 12 塊一次通過：階段一加 G3 → 銀行三台與我方 7 張 p12 換鏈（leaf 序號不變）→ 18 個端點都出示「中繼由 G3 簽」才進階段三 → 拿掉 G2。
- 反向：同一張 leaf、同一把私鑰，配舊鏈 REST 000（被拒）、配新鏈 200。
- `21-cert-rotate.sh chain` 用「中繼同私鑰續簽」（序號 …DA30 → …DA31）實跑通過，19 個端點比對「leaf 序號：中繼序號」都對。
- 21.0 判斷表補成 8 列（加了根同私鑰續簽＋中繼續簽／換私鑰兩列）。
- 小坑：Windows 的 openssl 算的公鑰雜湊和 ops02 的不同（PEM 換行字元），只能各自那一邊比。

## 新章
- 第 23 章 license：從 `_confluent-command` 讀 JWT 的 exp；試用版剩 29 天 → rc 2；systemd timer 每天 08:00，`SuccessExitStatus=2`；syslog tag `confluent-license`。正式 license 套用（23.3）未實測（沒有正式 license）。`23-license.sh status|check|schedule` 通過。
- 第 24 章換 controller（kc03 資料碟換新）：remove-controller → 清空 → `--no-initial-controllers` 格式化 → 觀察者追上 → 在新主機上 add-controller；約 5 分鐘，MDS/REST/C3 不斷。格式化與 add-controller 要 master key（service.env 或 Summon）。`24-controller-replace.sh replace kc03` 通過。
- 第 25 章 broker 縮減／擴充（kb04）：`kafka-remove-brokers --delete` 2 分鐘（另一次 14 分鐘：Self-Balancing 還在搬前一輪）；加回後 Self-Balancing 約 17 分鐘才開始搬（EMPTY_BROKER）；20 分鐘持續寫入 60000 筆 0 錯誤。quorum 觀察者清單會殘留已移除的 104 → 改用 `kafka-broker-api-versions` 的 broker 清單。
- 第 26 章日常備份：`svc-backup` 憑證；最小權限 = RBAC SecurityAdmin ＋ KRaft ACL（Topic * 與 Cluster 的 Describe、DescribeConfigs）；反向：讀訊息、建 topic、改 role binding 都拒。7 個文字檔＋SHA256SUMS，每天 02:00，保留 30 天；比對用 sha256＋join（features 的 Epoch 拿掉、ACL 排序）。`26-metadata-backup.sh grant|run|schedule|compare` 通過。`conf/certs.txt` 加 svc-backup。

## 補強
- 第 6 章：資料碟檔案系統檢查（lab 是 overlay）；`/tmp` 不能 noexec 的原因（kb04 的 /tmp 確實有 lz4 原生程式庫）。
- 10.3：`java.io.tmpdir` 選配（`JAVA_TOOL_OPTIONS`，不和 javaagent 的 `KAFKA_OPTS` 衝突）；kb04 實測後還原。
- 第 10 章：controller／broker 範本明確寫 `metadata.log.dir`（guide 與 install 範本）；kc01、kb01 實測。lab 其他 5 台的 properties 還沒有這行（值等於預設，下次重新產生設定時帶入）。
- 第 18 章：Confluent Server 8.3.2 **沒有** `kafka.server:type=raft-metrics`（jshell attach 列出全部 MBean 確認）→ README 原說法正確，redesign 的「矛盾」更正；新增 3 條 quorum 告警（LastAppliedRecordLagMs、MetadataErrorCount、NewActiveControllersCount），行內 Prometheus 載入 12 條、9/9 target。install 範本同步。
- 第 19 章：稽核 topic 兩個都 RF 3、min.insync 1；補檢查指令與「可送專用稽核叢集」。
- 第 22 章：JDK 25 是支援、原廠建議仍 21 的註記。

## lab 現況
- CA：根 G3（ca/g3）、簽發 CA「Issuing CA G2」由 G3 簽（ca/g2/issuing.crt 是續簽後的那張）；`ca/g2/sign.sh` 簽出的鏈就是新鏈。
- kc03 的 directory id 換過兩次；kb04 移除又加回兩次。
- ops02 上有 `~/install`（從 repo 複製，lab 模式 site.env）、兩個 timer（confluent-license-check、confluent-metadata-backup，都指向 install 腳本）。
