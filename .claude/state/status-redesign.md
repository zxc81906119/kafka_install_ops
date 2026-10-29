# Status — branch `redesign`

Updated: 2026-10-29 10:55（**lab 使用中**：手冊從第 2 章續跑中，`run-full.sh customer 2`，紀錄 `~/kafka-lab-runs/run-customer-2-end-20261029-1044.log`，結束碼寫進 `~/kafka-lab-runs/run-full-2-B.rc`）

## 現在在做什麼
手冊（journey.md）從零實跑，驗今天所有改動。第 0 章（建 lab，13 塊）已過；2.4 因 `kafka_streams.yml` 重複列兩次停過（已修，從第 2 章續跑）。
失敗就修文件、從失敗那章續跑（`bash docs/journey-src/tools/run-full.sh customer <章>`；從 0 開始會拆 lab）。跑完：逐行看紀錄＋scan-log、修 out 值、重建 docx。

## 今天（10-29）做完、已 commit（從未 push）
- 補章：22 憑證到期監控、24 磁碟與容量、27 新應用上線、28 故障排查、30 套件庫主版本保險（各章 log 見 log/2026-10-29-ch*.md）。
- **腳本版從零重跑通過**（10:36，rc 0）：34 段、7 次驗收全部 42/42；遷移與 OS 9.8 期間持續流量 0 遺失。
- MDS 事故（20.4 密文 key 名）修正＋CLAUDE.md 陷阱：log/2026-10-29-mds-ldap-cipher-incident.md。
- **MDS 寫 binding 偶發 50003**：原因＝MDS 內部 producer retries=0，auth topic leader 搬家後第一筆失敗（lab 重現）。使用者定案：只對這個錯誤再送一次（`mds_write`），曾做的「等寫入者就緒」已撤回。log/2026-10-29-mds-50003.md。
- 手把手 docx 打不開：16.5 有實體 ESC 字元 → 改 `\x1b`，build.js 擋控制字元（使用者確認可開）。
- C3 Streams／RocksDB 監控：**使用者要加**（10:00 先說精簡，之後改口要加）。已做：第 2 章引進官方 `kafka_streams.yml`（48／79 個檔）。**未做**：lab 實測序列數與 INFO 層級指標、規則檔、告警、手冊 17 章／附錄 B、更正 redesign「C3 維持精簡」那段。參考：docs.confluent.io Kafka Streams Metrics（屬性類 RocksDB 指標是 INFO）。
- OP menu：MDS token 到期前自動換新（`core_token_fresh`，`tests/test-token-renew.sh`）；91 逐台找活著的 MDS（`tests/test-breakglass-mds.sh`）；證明操作機不直連 AD（blackhole ad01 實測）。
- 手冊要能在沒有 repo 時照做：附錄 A 搬回開頭成**第 0 章**（0.1–0.9，圖 D.labbuild，run-full 章號 0、"A" 為別名）；選單改為**交付物**（`opmenu/package.sh` → tar＋SHA256SUMS，16.3 複製並核對）。log/2026-10-29-manual-without-repo.md。

## 下一步（依序）
1. 等手冊實跑跑完（大約數小時；16.3 用的選單是 10:44 打包的，**不含 91 逐台找 MDS 的修正**，那個靠單元測試）。修失敗、修 out 值、重建兩份 docx、commit。
2. 第 28 章新增一節「MDS 的 8090 不能用時」：lab 由「銀行網路團隊」在 kb01–04 用 firewalld 暫拿掉 8090 → 選單登入失敗、91 提示 → 用 `kafka-admin`（SCRAM、9095，`~/secrets/kafka-admin.pass`）做 topic 類操作 → 開回 8090 → 照 20.2 換 kafka-admin 密碼。先手動實跑再寫（91 的提示文字已指向「28.6」）。
3. C3 Streams／RocksDB 監控（見上「未做」）：手動實測 → 規則（命名照官方 kafka_streams.yml，範圍收窄）→ 告警（背景錯誤、丟棄紀錄、處理停滯）→ 手冊 → 腳本（17 站）。
4. 從零腳本版再跑一次驗 1–3 的改動（run-customer）。
- 待使用者決定／回覆銀行：`opmenu-emergency` 對 root 的意義；換金鑰週期；dashboard `job="kafka-broker"` 要不要 sed 修；`docs/evidence/` 要不要版控；omnibus 固定值正式值；銀行有沒有 Kafka Streams 應用。

## 環境狀態
- lab：專案 `lab`，第 0 章剛重建（10:37）；四個 `lab-mon-*` 與 `lab-mon-blackbox` 由手冊第 17、22 章建立。
- Docker VM 約 10.7 GB，不要同時跑別的；使用者其他專案的映像／卷不要動。
- 密碼檔：`~/kafka-lab/secrets.env`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node（補丁寫成 scratchpad 的 .js 檔，含 `${...}`、反引號、跳脫字元的內容放文字檔再讀進來）。
- 背景：run-full 續跑（task bjuvptxce）、Monitor b934byui7（30 分鐘到期要重接）。舊 monitor 的過期通知可忽略。
