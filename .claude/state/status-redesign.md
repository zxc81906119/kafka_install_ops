# Status — branch `redesign`

Updated: 2026-11-01 晚（**lab 使用中（Podman kafka-lab），machine 開著**：OP menu 新寫法**完成並上線**：變更類項目新舊版輸出相同、44 快照＝每日備份、22／27 實跑過，/opt/opmenu 已換成新版交付物 opmenu-20261101.f866d235）

## 現在在做什麼
手冊版在 Podman 上逐章實跑＋逐章自檢（是否符合最終設計，不只指令對）**全部完成**：第 0–31 章與附錄 B（log/2026-10-31-podman-walkthrough.md 逐章紀錄）。沒有進行中的工作。

## 今天（10-31）做完
- lab 從 Docker Desktop 換到 Podman（rootful WSL2 machine `kafka-lab`），手冊與工具改成 podman；compose 用 docker-compose v5.5.1。
- 定案：7071 只用 HTTPS；protected.users 補 svc-backup、confluent-audit；svc-ops.key 留在操作機（取代「離線保管」）。
- 逐章自檢改掉的內容（重點）：21 章 7071 也算憑證端點（把關 13→17、17→19）；23.5 快照要和新備份比；25 章清目錄改 find -delete；20.1／22／24 的數字與題號；29、30 章的腳本名（29-upgrade.sh、30-os-patch.sh）；附錄 B 的 audit dashboard（8.3.2 沒有 confluent-audit-metrics MBean）與 quotas（沒流量）。
- 遷移後與 OS 9.8 後各重跑第 19 章：健康 22/22、安全 16/16、寫讀、冷開機都過。
- 下載（使用者同意）：prom/blackbox-exporter:v0.25.0、Rocky 9.8 更新集合 156 個 RPM／79 MB。C3 2.6.0 RPM 沿用 10-30 的檔（重驗簽章）。

## 下一步（候選）
1. ~~改腳本版 7071 只用 HTTPS~~ **做完**（4b63317：17-jmx-exporter.sh、19-acceptance.sh、jmx-header.yml、prometheus-scrape.yml；重跑會清掉舊的 jmx-scrape.pass／salt）。
2. 腳本版在 Podman 上從零實跑（`install/lab/run-customer.sh`）：使用者 10-31 決定改天跑。跑之前先決定 C3 2.6.0 RPM（1 GB）要不要重抓（建議改 run-customer.sh 沿用落地區已驗章的檔）；這次也會驗到 v5.6.1 的 `podman compose down -v／up -d`。
3. ~~移除 Docker Desktop~~ **做完**（10-31 晚，殘餘全清，C 槽剩約 290 GB）；compose 改用 Podman Desktop 的 Compose 擴充（v5.6.1），手冊 0.0 已改。第 0 章的 `podman compose up/down` 在 v5.6.1 上還沒從零實跑。
4. ~~OP menu 改成新手看得懂的寫法~~ **做完**（log/2026-11-01-opmenu-readable.md）：27 項＋lib＋登入改寫、9 支測試過；lab 唯讀 13 項、變更類 31–38／42／36／91 新舊版輸出相同（含拒絕的情況），44 快照 7 個清單和每日備份 sha256 相同，22、27 新版實跑過；交付物重打包（opmenu-20261101.f866d235）並照手冊 16.3 裝到 /opt/opmenu，16.3／16.4 的 out 相同。順手修：16.3 的 ssh-keyscan 在 OS 9.8 會把 `#` 註解行印到 stdout（known_hosts 20 行），手冊與 16-opmenu.sh 加 `grep -v "^#"`；項目數改數 `items/*.sh`（多了 menu.list）。
4b. **進行中**：手冊手動指令照 OP menu 規則改（log/2026-11-01-guide-readable.md；規則在 redesign/README.md 最後一節）。範圍全部章節，驗證分四批（0–9、10–19、20–28、29–31＋B），每批從第 0 章重建 lab 跑到該批最後一章。執行器 run-chapter.js 已改成每塊 trap ERR（任何一行失敗就停）。第 0–9 章改完並從零實跑通過（11-01 晚，74 塊、out 逐塊符合，修了 4 處 out）。第二批 10–19 文字改完，從零實跑 0–19 進行中（背景，run-customer-0-19-20261101-2112）。第三批 20–28 文字也改完（語法過；26.4 要另外手動驗）；等 0–19 跑完比對 out、commit，再接著跑 20–28（不重建，使用者 11-01 決定；失敗才從 0 重建）。
5. 待決定：稽核寫入失敗是否用 `confluent-event-logger` 的 producer 指標告警（redesign/README.md 394 之後）。
6. 舊待修清單（10-31 Docker 逐章時記的 4.5、10.4、13、14、16.5 out 小差異；18.4 稽核 topic min.insync.replicas）：Podman 這輪沒再出現問題，要不要結案待看。
- 待銀行回覆：換金鑰週期（4.6）、master key 週期（8.6）、omnibus、9.5、11.3／11.4、12.4。

## 環境狀態
- lab：**使用中（redesign）**：0–19 從零、20–28 接著跑完都通過；第四批 29–31＋B 接著跑（背景）。
- lab 信任根是 G3（21.4 之後）；簽新憑證用 `~/kafka-lab/ca/g2/sign.sh`（中繼 G2 由 G3 簽）。
- machine 不自動開（使用者 11-01）：要用時自己 `podman machine start kafka-lab`，關機前 `podman machine stop kafka-lab`。Podman Desktop 的 engine autostart 已關（Start on login 還開著）。`~/kafka-lab/start-lab.ps1` 只當修復工具（compose 因孤兒 kafka-lab-api.sock 壞掉時手動跑），啟動捷徑已刪。WSL2 11 GB（.wslconfig）。絕不 `podman machine rm/reset kafka-lab`（volume `ops-secure`）。
- 密碼檔：`~/kafka-lab/secrets.env`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node（替換字串用函式，避免 `$'`）；podman 指令前加 `MSYS_NO_PATHCONV=1`。
