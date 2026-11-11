# 2026-11-08～09 交付新人前的最終驗證（手冊＋腳本都從零全跑）

## 手冊從零全跑（run-customer-0-end-20261108-2126.log）
- 459 塊：rc=0 447、略過 12（26.4 清空叢集等破壞性程序）、失敗 0；約 3.5 小時。
- rc=0 但其實不對、靠逐塊比對 out（compare-masked.js）才找到的兩處：
  - **29.6**：在 broker 逐台重啟之後建 svc-rest 的 ResourceOwner，第一次就碰到 50003（auth topic 的 leader 剛搬家），binding 沒建成。手冊改成「只有 50003 再送一次，其他錯誤整段印出」（和腳本的 mds_write 一樣）；在 lab 補建並驗證新寫法。
  - **32.5**：C3 2.6.1 的 trigger 告警名稱是 `<trigger 名稱>$$<guid>`，手冊用 `"alertname":"chapter32-test"` 完整比對，永遠比不到（out 寫內建有，實際印 `內建=[]`）。改成比對 annotation `"trigger":"chapter32-test"`。手動驗證：告警確實只進內建 Alertmanager（4 筆，每台 broker 一筆）。腳本版用的是自己的規則，不受影響。
- out 更新成實測：13 節點數 7、17.2／17.3 c3 126 行、22.3 8 張憑證、23.3 rbac 45 行／principal 14、快照 31 筆、28.2 pending JvmHeapHigh（GC 前短暫過 90%，前一次全跑也一樣）、28.3 三條 firing（含 KafkaFencedBrokers；之前寫「演練在 5 分鐘前就重啟」是錯的）、30.0 155 個 RPM／80 MB／226、32.3 序列數（C3 55、broker 689）、B.1 292 個 panel。
- B.1：C3 exporter 調整（alive／failed stream threads 改成數值指標，給告警用）讓官方 `kafka-stream.json` 少 3 個 panel、`globalktable.json` 少 1 個；這是已定案的取捨，B.1 補上說明。第 32 章簡報的序列數同步改。
- 16818（第 29 章持續流量）、18417（第 30 章）的數字只有腳本版有量（run-customer.sh 段 22、32），等腳本全跑後填。

## 教訓
- scan-log 只抓錯誤字樣；「檢查指令本身寫錯所以印空值」只有逐塊比對 out 才看得到。交付前一定要跑 compare-masked。

## 手冊版收尾驗證（11-09 01:xx）
- 17.8、32.4 各連跑兩次（抽成暫時的 md 用 run-chapter.js 跑；監控容器先用 `bank-sim.sh monitoring` 開回）：第二次只看到這一次的 4 行，since 修正有效。
- 新版 32.5 實跑：`第二台=[] 內建=["chapter32-test"]`，和 out 一致；trigger 刪除 200，我們的兩個檔仍是 root。
- 接著腳本從零全跑（run-customer.sh）。

## 腳本從零全跑：第 14 段冷開機時 WSL 卡死（11-09 02:14）
- 紀錄 ~/kafka-lab-runs/script-customer-0-20261109-0139.log：段 1–13 全部 ok（基底裝完、18 稽核、17.6 銀行監控起來），段 14（19.4 冷開機）的 `podman compose stop` 失敗，`grep -c Stopped` 印 0 → exit 1。
- 原因：WSL VM 記憶體用滿（11 GB 用 10.6 GB、可用 362 MB；容器合計約 10.4 GB，C3 1.8 GB、broker 各 1.3 GB），wsl.exe 對 VM 的呼叫逾時（`Wsl/Service/0x8007274c`）；compose 要先用 wsl.exe 問 machine 狀態（`get machine connection URI: could not find a matching machine`），接著連 ssh 6012 也被斷。
- 恢復只能 `wsl --shutdown`（要使用者同意）；之後 `podman machine start kafka-lab`，從第 14 段接著跑：`FROM=14 bash install/lab/run-customer.sh`（第 14 段本來就是全部停掉再開）。
- 使用者同意後 `wsl --shutdown`（rc=0）→ 殺掉舊 win-sshproxy、`podman machine stop`、刪孤兒 socket、`podman machine start`；lab 14＋監控 4 台都回來、compose 可用。`FROM=14` 接著跑（script-customer-from14-*.log）。
- 第 14–30 段通過；第 29 章持續流量：直連 10,348 筆遺失 0、REST 1,918 次失敗 0（已填手冊 29 章）。
- 第 31 段（25.2 移除 kb04）10:46 失敗：`RebalancePlanComputationException`，kc02（跑 balancer 的 controller）日誌 `Replica metrics have more windows than partition metrics`＝早上 WSL 卡死、machine 重啟的後遺症（CLAUDE.md 已記）。重啟 kc02 的 confluent-server（leader 換到 kc01、Lag 0），等 7 分鐘後 `FROM=31` 接著跑（script-customer-from31-*.log）。
- 簡報：附錄 A 改成節選（使用者要「看得出方案的重要設定」，不要完整檔、不要 sed）：Prometheus 抓取節選、分流（alert_relabel_configs）、規則檔帶 target: omnibus 的片段、第二個 Alertmanager 節選；附錄 B 不變。已重建 36 張。

## 腳本從零全跑：完成（11-09 11:47）
- 重啟 kc02 後 `FROM=31` 接著跑：kb04 移除 SUCCESS、加回、第 32–35 段全部 ok，exit=0；最終驗收 45／45 通過（健康 0、安全 0、應用程式 0 失敗）。
- 第一段紀錄的 12 行 FAIL 是第 4 站在銀行建 cpuser 之前的預期拒絕（設計如此，第 7 段銀行補上後通過）。
- 第 30 章持續流量（OS 9.6→9.8，約 15 分鐘）：直連 3,261 筆遺失 0、REST 605 次失敗 0 → 已填手冊 30 章。
- 手冊導覽簡報：guide-slides.js 的 disk 圖文字替換表跟著 disk 圖（5 步）更新（kafka-configs／kafka-delete-records／kafka-reassign-／partitions）。
- 11-09 12:21 全部文件重建完成（手冊 docx、問題清單 docx、RPM 簡報、手冊導覽 55 張、第 32 章 36 張）；lab 閒置。全部未 commit。
- 11-10 告警簡報拿掉章節引用（每頁「第 32 章｜」、封面、表格依據、備忘稿；使用者：不要著重哪章），檔名改成 docs/Confluent-告警方案.pptx（git mv；CLAUDE.md、deck-src/README.md 同步）；兩條路徑圖的 omnibus 方塊文字統一成「行內事件系統」。
- 11-10 omnibus 欄位：使用者的範例（10-26）有 5 個固定值（source、ClassName、origin、hostname、sub_source），其他是 Dynatrace 變數；第 17 章全照抄，第 32 章 origin=c3-embedded、hostname=動態（我們暫定）。使用者決定維持現狀等銀行回覆，問法不逐欄列出，統一問「omnibus JSON 中不確定的欄位值」（問題清單 11.5 問、11.11 指向 11.5；簡報結論頁待確認與兩段備忘稿同步）。
