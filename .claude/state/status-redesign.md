# Status — branch `redesign`

Updated: 2026-10-31 23:40（**lab 使用中（Podman kafka-lab）**：手冊版從零跑完 0 → B；Docker Desktop 已移除；compose 由 Podman Desktop 擴充提供）

## 現在在做什麼
手冊版在 Podman 上逐章實跑＋逐章自檢（是否符合最終設計，不只指令對）**全部完成**：第 0–31 章與附錄 B（log/2026-10-31-podman-walkthrough.md 逐章紀錄）。沒有進行中的工作。

## 今天（10-31）做完
- lab 從 Docker Desktop 換到 Podman（rootful WSL2 machine `kafka-lab`），手冊與工具改成 podman；compose 用 docker-compose v5.5.1。
- 定案：7071 只用 HTTPS；protected.users 補 svc-backup、confluent-audit；svc-ops.key 留在操作機（取代「離線保管」）。
- 逐章自檢改掉的內容（重點）：21 章 7071 也算憑證端點（把關 13→17、17→19）；23.5 快照要和新備份比；25 章清目錄改 find -delete；20.1／22／24 的數字與題號；29、30 章的腳本名（29-upgrade.sh、30-os-patch.sh）；附錄 B 的 audit dashboard（8.3.2 沒有 confluent-audit-metrics MBean）與 quotas（沒流量）。
- 遷移後與 OS 9.8 後各重跑第 19 章：健康 22/22、安全 16/16、寫讀、冷開機都過。
- 下載（使用者同意）：prom/blackbox-exporter:v0.25.0、Rocky 9.8 更新集合 156 個 RPM／79 MB。C3 2.6.0 RPM 沿用 10-30 的檔（重驗簽章）。

## 下一步（候選）
1. 改腳本版：`17-jmx-exporter.sh`、`19-acceptance.sh`（健康與安全兩項）、`templates/jmx-header.yml`、`prometheus-scrape.yml` → 7071 只用 HTTPS；同步手冊這次的修正（21 章 7071 把關、23.5 快照比對等，若腳本有對應）。
2. 腳本版在 Podman 上從零實跑（`install/lab/run-customer.sh`）。
3. ~~移除 Docker Desktop~~ **做完**（10-31 晚，殘餘全清，C 槽剩約 290 GB）；compose 改用 Podman Desktop 的 Compose 擴充（v5.6.1），手冊 0.0 已改。第 0 章的 `podman compose up/down` 在 v5.6.1 上還沒從零實跑。
4. 待決定：稽核寫入失敗是否用 `confluent-event-logger` 的 producer 指標告警（redesign/README.md 394 之後）。
5. 舊待修清單（10-31 Docker 逐章時記的 4.5、10.4、13、14、16.5 out 小差異；18.4 稽核 topic min.insync.replicas）：Podman 這輪沒再出現問題，要不要結案待看。
- 待銀行回覆：換金鑰週期（4.6）、master key 週期（8.6）、omnibus、9.5、11.3／11.4、12.4。

## 環境狀態
- lab：Podman machine `kafka-lab`，compose 專案 `lab`（14 台＋dl01），10-31 照手冊從零建。監控容器（lab-mon-*）B.2 已收；要再用跑 `bank-sim.sh monitoring`。license trial 到 2026-11-30。
- lab 信任根是 G3（21.4 之後）；簽新憑證用 `~/kafka-lab/ca/g2/sign.sh`（中繼 G2 由 G3 簽）。
- WSL2 11 GB（.wslconfig），Docker Desktop 不要同時開。絕不 `podman machine rm/reset kafka-lab`（volume `ops-secure`）。
- 密碼檔：`~/kafka-lab/secrets.env`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node（替換字串用函式，避免 `$'`）；podman 指令前加 `MSYS_NO_PATHCONV=1`。
