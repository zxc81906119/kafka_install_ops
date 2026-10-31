# Status — branch `redesign`

Updated: 2026-10-31 15:00（lab：Docker 版仍在跑，停在第 20 章，不再接續；改為換 Podman（redesign 2026-10-31）：下一步是下載獨立版 docker-compose、在 Podman machine labtest 上手動建 lab，再改第 0 章與全書指令）

## 現在在做什麼
試用 license 到期的處理寫成手冊 **26.4「試用期到期：申請延長，或重置測試環境的叢集」** 並實測兩輪（log/2026-10-30-trial-reset.md）。沒有進行中的工作。

## 今天（10-30）做完
- 手冊從第 0 章完整實跑通過（407 塊；log/2026-10-30-full-manual-run.md）。
- 手冊殘留的 CyberArk 保管說法清掉（f9bcd44）；docs/evidence 不進版控；job label 不改官方檔；銀行沒有 Streams 應用。
- Docker Desktop 後端當掉（socket 檔壞）→ 把 `%LOCALAPPDATA%\Docker\run` 改名（`run.old-20261030`）後恢復。
- 26.4：重置程序第一輪手動實跑、手冊寫好（D.clusterreset 圖在前；8 塊，`@role` 第 4 欄「整本實跑不執行」→ run-chapter.js 略過）、第二輪照手冊原文實跑全過（ACL 4 條建回、第 19 章健康 22/22、安全 16/16、應用程式寫讀過；新試用期到 2026-11-29）。
- 23.3 `acls.txt` 改成一條一行（`TYPE|name|pattern|principal|host|op|perm`，舊格式排序後無法還原）；手冊與 `install/steps/23-metadata-backup.sh` 都改；23.6 `metadata-restore.sh` 加 `set -f`（`Topic:*`）。

## 下一步（候選）
1. ~~26.4 包成腳本~~ **做完**：`26-license.sh reset`（輸入現在的 cluster id 確認）＋`23-metadata-backup.sh restore-all`；lab 實跑通過（約 8 分鐘，ACL 4、binding 33），錯的確認被拒，之後第 19 站 42/42。
2. ~~腳本版從零再跑一次~~ **做完**（20:31，34 段 rc=0，驗收 6 次 42/42；log/2026-10-30-script-full-run.md）。找到 11.2 ad-drill 假通過（腳本版當時還沒有 app-orders.properties，錯誤行被算成 1 個 topic），bank-sim.sh 與手冊 11.2 已修、重跑通過。
3. ~~銀行確認事項加 license 題~~ **做完**：12.4（docx 已重建）。
- 待銀行回覆：換金鑰週期；omnibus 正式值。

## OP menu 調整：做完（2026-10-30，log/2026-10-30-opmenu-adjust.md）
- 13 consumer group（lag＋在線成員）、15 查看配額、38 調整配額（新）、17 加 license、43 查詢與匯出（合併 45，可選一般／敏感 _sensitive／全部）、44 快照補 rbac.txt、ACL 新格式（7 檔和每日備份 sha256 相同）。
- 每日備份 rbac.txt 去對齊空白、LC_ALL=C 排序；順手修 44 CSV 少最後一筆、23.6 叢集層級 binding、11.2 ad-drill 假通過。
- 驗證：手冊 16.5／18.3／23.3／23.5 原文在 lab 跑過；16 站新檢查 FAIL 0；回歸 45/45；23.6 drill 通過。
- 還沒做：腳本版與手冊版都還沒從零重跑一次（含這些改動）。

## 手冊逐章實跑（2026-10-31，log/2026-10-31-chapter-walkthrough.md）
- 第 0–19 章照手冊原文跑完（安裝基底 CP 8.2.4／C3 2.5.1／JDK 21／OS 9.6）。第 20 章跑了 20.2（kafka-admin 換密碼）與 20.3 的前段（新 master key 產生、派送 10 台、kc01–03、kb01 已重啟），12:31 停下。下次：開機後先確認 14 台容器與服務都起來（新 master key），再 `run-full.sh customer 20 20` 整章重跑（20.2／20.3 再做一次沒有副作用）。
- 途中定案並已改手冊：7071 只用 HTTPS（17 章、19.2、25.1.5、B.2、questions 11.3／11.4）。scan-log 修了兩處（http=000 是預期；FAIL 開頭一律可疑）。
- 待做：① 待修清單（log 裡列的 4.5、10.4、13、14、16.5 out 小差異；18.4 稽核 topic min.insync.replicas 列入待確認）；② 手冊版跑完後改腳本（17-jmx-exporter.sh、19-acceptance.sh 健康與安全兩項、templates/jmx-header.yml、prometheus-scrape.yml），再腳本版從零實跑。

## 環境狀態
- lab：專案 `lab`，由腳本版 10-30 17:45 從零建出並跑完整條主線：OS 9.8、CP 8.3.2、C3 2.6.1、JDK 25；license trial 到 2026-11-29。
- Docker VM 約 10.7 GB，不要同時跑別的。絕不按 Docker Desktop 的 Reset to factory defaults（會清掉 volume `ops-secure`）。
- 密碼檔：`~/kafka-lab/secrets.env`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node；跑手冊片段時 `export MSYS_NO_PATHCONV=1`。
