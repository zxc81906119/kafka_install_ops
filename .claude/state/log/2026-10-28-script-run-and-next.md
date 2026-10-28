# 2026-10-28 腳本版從零實跑結果與下一步決定

- `bash install/lab/run-customer.sh` 從零跑完（31 段，結束碼 0）。中途接續 4 次，修了：驗收讀取等待 45 秒（consumer group 重新加入要 20–30 秒）、16 站空的 opmenu log 不再出錯、broker heap 512m→768m（OOM）、26 站等 under-replicated=0、C3 RPM 下載改 `dnf -q download --url` + `curl`（`dnf download` 1 GB 後卡住）。
- 各段驗收 39/39：基底、憑證換發後、遷移三段、回滾演練、finalize、OS 9.8、C3 2.6.1；OS 更新期間直連 0 遺失、REST 0 失敗。
- 發現：三台 controller 叢集在 8.2.4 與遷移後 8.3.2 的 Prometheus 都沒有 `kafka_server_raft_metrics_*`（controller job 有 3496 序列，raft 為 0；單台 standalone 才有）。第 17 章「有資料」的說法錯，兩條 raft 告警永遠不會觸發 → 待改。
- 使用者決定（AskUserQuestion）：把 cp-server 改成純 server 憑證（EKU 只有 serverAuth），改手冊＋腳本＋問題清單，然後從零重跑；改之前先收尾 session、壓縮 context，讓下一輪乾淨手冊實跑就是最終版，不多跑一輪。
- cp-server 改法十項（見 status「下一步」1）：新增 `c3-monitoring`（clientAuth only、無 RBAC，不用 svc-c3 因為它是 SystemAdmin）；C3 對 Prometheus／Alertmanager 的 keystore 與 alias、內建 Prometheus 的 tls_config、檢查指令都改用它。Prometheus／Alertmanager 的 web-config 只驗憑證鏈，不看 CN。
