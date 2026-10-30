# 2026-10-30 試用 license 到期：手冊 26.4 叢集重置

- 背景：銀行還不能買原廠 license，先用 30 天試用（存在 `_confluent-command`，從叢集第一次啟動算）。說明過：到期後重啟就停擺；正式環境一定要買；第一選擇是向原廠申請延長評估 license（26.3 換上，不丟資料）。
- 使用者決定：重置程序放 **26.4**；先實測、腳本版之後從零重跑。
- 程序（D.clusterreset）：23.3 備份 → 停服務＋reset-failed → `find -delete` 清資料與 C3 數字目錄（留 prometheus／alertmanager）→ 新 cluster id、帶 master key 以 cp-kafka 格式化（controller `--add-scram kafka-admin`）→ 啟動、等 MDS → kafka-internal 憑證建 svc-ops SystemAdmin → `cluster-restore-all.sh`（topic、全部 binding、SCRAM 用 ~/secrets 原密碼、配額、ACL、broker 動態設定）→ REST／C3 → 第 19 章驗收。
- 實測：兩輪都過；新試用期 = 重置當下 +30 天（licenseType trial）。
- 文件裡寫明：只用在採購前的測試／評估環境，做之前取得原廠同意；會清空訊息、offset、稽核 topic 舊紀錄（先用選單 43 匯出）；需要 OS 團隊臨時開安裝期 sudo。
- 陷阱：
  - `rm -rf dir/*` 漏隱藏檔 `.kafka_cleanshutdown`；經 ssh 的 `sudo rm dir/*` 萬用字元由 cpuser 展開，讀不到 0750 目錄 → 什麼都沒刪也不報錯。用 `sudo find … -delete`。
  - `echo $var` 展開 `Topic:*` 成 `/root` 的檔名 → 還原腳本開頭 `set -f`（23.6 的 metadata-restore.sh 也補了）。
  - 23.3 舊的 `acls.txt`（`grep . | sort`）把資源標頭和權限行拆開，無法還原 → 改一條一行。
  - 停 Java 服務會以 143 結束、systemd 標 failed → `reset-failed`。
- Docker Desktop 後端當掉（`sailor-ingest.sock rename … cannot be accessed`）：停 Docker 與 WSL，把 `%LOCALAPPDATA%\Docker\run` 改名再啟動。絕不 Reset to factory defaults。
