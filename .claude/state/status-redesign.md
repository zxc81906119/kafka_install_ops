# Status — branch `redesign`

Updated: 2026-11-11 22:3x（手冊第 33 章〔CBOM＋OPA＋Jenkins〕完成並照手冊實跑通過；cbomlab 容器環境已刪；下一步搬 untitled9 的 web app；全部未 commit）

## 現在在做什麼
**CBOM（2026-11-11 起，log/2026-11-11-cbom-opa.md；設計在 redesign/README.md 最後一節）**：手冊第 33 章完成（33.1–33.11，整章照手冊在 lab 實跑通過；圖 `cbom`；問題清單第 13 節）。程式在 `cbom/`（`tools/` Maven 專案 56 個測試、`policy/` 22 個規則測試、`cbom-collect.sh`、`Jenkinsfile`、`build.sh`／`package.sh`；`dist/`、`out/` 不進 git）。lab：ops02 `/opt/cbom`、帳號 `cbomsvc`；容器 `lab-jenkins`（http://localhost:18088，檔案在 ~/kafka-lab/jenkins）；dl01 `~/cbom` 是建置環境。**下一步**：把 IdeaProjects/untitled9 的 web app（src、pom.xml、deploy、scripts）、demo/cbomkit、「Cbom 探討（公司模板）.pptx」與產生它的程式搬到 `cbom/` 底下（untitled9 本身不動） → 三個優化方向（web app 的 CBOM 與 CP 流程整合、CBOMkit 平台的定位〔順便驗它收不收 1.7〕、簡報內容） → web app 測完再談抽象化（先不重構）。還沒做：腳本版 `install/steps/33-*`、run-customer.sh 與手冊導覽簡報加第 33 章、含第 33 章的整本從零全跑。

**最終驗證（2026-11-08～09，log/2026-11-09-final-verify.md）**：手冊全跑完成並修正 → 重跑 17.8／32.4 兩次驗 since（通過）→ 32.5 新比對再驗（通過）→ 腳本從零全跑（完成：45／45 通過；中途 WSL 卡死與 Self-Balancing 後遺症都已處理，見 log），使用者同意 wsl --shutdown，已恢復，FROM=14 接著跑中）→ 填 29、30 章持續流量（完成）→ 重建全部 docx／pptx（完成 11-09 12:21）。使用者 11-09 會來看進度；commit 等使用者決定。

**第 32 章擴大完成（2026-11-07）**：告警規則統一成第 17 章一份 26 條，第 32 章 C3 Prometheus 抓 10 台 7071 套用同一份；C3 exporter 依 Kafka Streams 建議調整。手冊 17／24／32 章局部重跑、腳本 32／24 通過（log/2026-11-07-ch32-scope.md）。簡報 docs/Confluent-告警方案.pptx（24 張）、手冊導覽與兩份 docx 已重建。全部未 commit。之後交付前可整本從零再跑一次。

腳本版（install/）照手冊寫法改寫完成並實跑通過（log/2026-11-02-scripts-readable.md）；手冊導覽簡報完成（docs/Confluent-手冊導覽.pptx）。全部未 commit，等使用者決定。待決定：30.4 順序腳本與手冊不同。

手冊狀態：手冊版在 Podman 上逐章實跑＋逐章自檢（是否符合最終設計，不只指令對）**全部完成**：第 0–31 章與附錄 B（log/2026-10-31-podman-walkthrough.md 逐章紀錄）。沒有進行中的工作。

## 今天（10-31）做完
- lab 從 Docker Desktop 換到 Podman（rootful WSL2 machine `kafka-lab`），手冊與工具改成 podman；compose 用 docker-compose v5.5.1。
- 定案：7071 只用 HTTPS；protected.users 補 svc-backup、confluent-audit；svc-ops.key 留在操作機（取代「離線保管」）。
- 逐章自檢改掉的內容（重點）：21 章 7071 也算憑證端點（把關 13→17、17→19）；23.5 快照要和新備份比；25 章清目錄改 find -delete；20.1／22／24 的數字與題號；29、30 章的腳本名（29-upgrade.sh、30-os-patch.sh）；附錄 B 的 audit dashboard（8.3.2 沒有 confluent-audit-metrics MBean）與 quotas（沒流量）。
- 遷移後與 OS 9.8 後各重跑第 19 章：健康 22/22、安全 16/16、寫讀、冷開機都過。
- 下載（使用者同意）：prom/blackbox-exporter:v0.25.0、Rocky 9.8 更新集合 156 個 RPM／79 MB。C3 2.6.0 RPM 沿用 10-30 的檔（重驗簽章）。

## 下一步（候選）
0. **回來先談（使用者 11-04 交代）**：AD 登入 cn、大小寫實測、OP menu 權限查詢、AD 長時間失敗的說法與告警、請銀行確認事項；細節見 log/2026-11-03-lab-wiped.md 最後一段。
1. ~~改腳本版 7071 只用 HTTPS~~ **做完**（4b63317：17-jmx-exporter.sh、19-acceptance.sh、jmx-header.yml、prometheus-scrape.yml；重跑會清掉舊的 jmx-scrape.pass／salt）。
2. 腳本版在 Podman 上從零實跑（`install/lab/run-customer.sh`）：使用者 10-31 決定改天跑。跑之前先決定 C3 2.6.0 RPM（1 GB）要不要重抓（建議改 run-customer.sh 沿用落地區已驗章的檔）；這次也會驗到 v5.6.1 的 `podman compose down -v／up -d`。
3. ~~移除 Docker Desktop~~ **做完**（10-31 晚，殘餘全清，C 槽剩約 290 GB）；compose 改用 Podman Desktop 的 Compose 擴充（v5.6.1），手冊 0.0 已改。第 0 章的 `podman compose up/down` 在 v5.6.1 上還沒從零實跑。
4. ~~OP menu 改成新手看得懂的寫法~~ **做完**（log/2026-11-01-opmenu-readable.md）：27 項＋lib＋登入改寫、9 支測試過；lab 唯讀 13 項、變更類 31–38／42／36／91 新舊版輸出相同（含拒絕的情況），44 快照 7 個清單和每日備份 sha256 相同，22、27 新版實跑過；交付物重打包（opmenu-20261101.f866d235）並照手冊 16.3 裝到 /opt/opmenu，16.3／16.4 的 out 相同。順手修：16.3 的 ssh-keyscan 在 OS 9.8 會把 `#` 註解行印到 stdout（known_hosts 20 行），手冊與 16-opmenu.sh 加 `grep -v "^#"`；項目數改數 `items/*.sh`（多了 menu.list）。
4b. **完成**（11-02）：手冊手動指令照 OP menu 規則改（log/2026-11-01-guide-readable.md；規則在 redesign/README.md 最後一節）。範圍全部章節，驗證分四批（0–9、10–19、20–28、29–31＋B），每批從第 0 章重建 lab 跑到該批最後一章。執行器 run-chapter.js 已改成每塊 trap ERR（任何一行失敗就停）。第 0–9 章改完並從零實跑通過（11-01 晚，74 塊、out 逐塊符合，修了 4 處 out）。第二批 10–19 文字改完，從零實跑 0–19 進行中（背景，run-customer-0-19-20261101-2112）。第三批 20–28 文字也改完（語法過；26.4 要另外手動驗）；等 0–19 跑完比對 out、commit，再接著跑 20–28（不重建，使用者 11-01 決定；失敗才從 0 重建）。
5. 待決定：稽核寫入失敗是否用 `confluent-event-logger` 的 producer 指標告警（redesign/README.md 394 之後）。
6. 舊待修清單（10-31 Docker 逐章時記的 4.5、10.4、13、14、16.5 out 小差異；18.4 稽核 topic min.insync.replicas）：Podman 這輪沒再出現問題，要不要結案待看。
- 待銀行回覆：換金鑰週期（4.6）、master key 週期（8.6）、omnibus、9.5、11.3／11.4、12.4。

## 環境狀態
- **2026-11-11 lab 使用中（redesign，本 session）**：CBOM 章節手動驗證（dl01 下載工具與建置；ops02 收集、掃描）。
- 2026-11-09 12:2x：lab 閒置（腳本從零全跑完成：8.3.2／C3 2.6.1／JDK 25／OS 9.8、第 32 章已裝）；cbomlab 8 台已提醒使用者開回。
- 2026-11-07 晚：lab 開著（8.3.2／C3 2.6.1，第 32 章新版已裝）；lab-mon-grafana／prometheus／alertmanager／blackbox 已停（需要時 17.6、22.2 會重建），webhook 開著；cbomlab 與 amazing_panini 在 wsl --shutdown 後沒有起來（不是我們的，沒動）。
- 2026-11-06 14:00：lab 閒置（腳本版跑完，平台在 8.3.2／C3 2.6.1／JDK 25／OS 9.8，第 32 章告警已裝）；machine 開著。
- lab：**使用者同意 Claude 實測（可破壞）**：8.2.4，第 12、13、17 章已跑、14–16 未做；kc／kb 已套 cn＋mapping＋filter；c3-01 留著 C3 Prometheus 測試設定（見 log/2026-11-03-lab-wiped.md 最後一段）。OP menu 交付物在 ~/opmenu-delivery。
- machine 不自動開（使用者 11-01）：要用時自己 `podman machine start kafka-lab`，關機前 `podman machine stop kafka-lab`。Podman Desktop 的 engine autostart 已關（Start on login 還開著）。`~/kafka-lab/start-lab.ps1` 只當修復工具（compose 因孤兒 kafka-lab-api.sock 壞掉時手動跑），啟動捷徑已刪。WSL2 11 GB（.wslconfig）。絕不 `podman machine rm/reset kafka-lab`（volume `ops-secure`）。
- 密碼檔：`~/kafka-lab/secrets.env`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node（替換字串用函式，避免 `$'`）；podman 指令前加 `MSYS_NO_PATHCONV=1`。

- 2026-11-04 c3-01 測試狀態：`alertmanager-custom` 已改用 `/usr/local/bin/alertmanager-0.34.1`，停 rest01 的 OPEN／RESOLVED 與字串型別都驗過；rest01 已開回。細節見 log/2026-11-03-lab-wiped.md。
- 2026-11-05 發現：手冊第 13 章的 C3 設定下，C3 連不上 MDS（client 憑證用了 cp-server）；根因與 lab 暫時修法見 log/2026-11-03-lab-wiped.md，手冊與腳本待修。
- 2026-11-05 lab 使用中（redesign，手冊從零實跑，接著腳本版實跑）。手冊、腳本、問題清單、圖已改（憑證各元件自用、第 32 章 C3 告警、OP menu 用 token sub、帶身分的 C3 驗收），都還沒 commit。
- 2026-11-05 憑證再縮減：拿掉 c3-monitoring、opmenu-breakglass（共 7 張）；手冊、腳本、選單、問題清單已改；接著手冊從零全跑、再腳本版全跑。
- 2026-11-05 14:3x：12:18 那輪手冊全跑因工作階段結束而中斷（38 塊、0 失敗），machine 也停了；重新開機、清 lab 後再跑一次。
- 2026-11-05 使用者說晚點再測：手冊全跑已手動停止（lab 停在第 15.5 節中途，不可接著用）。下一步：使用者說了再從零跑手冊（run-full.sh customer），接著 run-customer.sh。下次跑之前：machine 若停著要先 start；清 lab 見 log/2026-11-05-c3-client-cert.md。全部還沒 commit。
