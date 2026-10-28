# 2026-10-28 腳本版從零實跑結果與下一步決定

- `bash install/lab/run-customer.sh` 從零跑完（31 段，結束碼 0）。中途接續 4 次，修了：驗收讀取等待 45 秒（consumer group 重新加入要 20–30 秒）、16 站空的 opmenu log 不再出錯、broker heap 512m→768m（OOM）、26 站等 under-replicated=0、C3 RPM 下載改 `dnf -q download --url` + `curl`（`dnf download` 1 GB 後卡住）。
- 各段驗收 39/39：基底、憑證換發後、遷移三段、回滾演練、finalize、OS 9.8、C3 2.6.1；OS 更新期間直連 0 遺失、REST 0 失敗。
- 發現：三台 controller 叢集在 8.2.4 與遷移後 8.3.2 的 Prometheus 都沒有 `kafka_server_raft_metrics_*`（controller job 有 3496 序列，raft 為 0；單台 standalone 才有）。第 17 章「有資料」的說法錯，兩條 raft 告警永遠不會觸發 → 待改。
- 使用者決定（AskUserQuestion）：把 cp-server 改成純 server 憑證（EKU 只有 serverAuth），改手冊＋腳本＋問題清單，然後從零重跑；改之前先收尾 session、壓縮 context，讓下一輪乾淨手冊實跑就是最終版，不多跑一輪。
- cp-server 改法十項（見 status「下一步」1）：新增 `c3-monitoring`（clientAuth only、無 RBAC，不用 svc-c3 因為它是 SystemAdmin）；C3 對 Prometheus／Alertmanager 的 keystore 與 alias、內建 Prometheus 的 tls_config、檢查指令都改用它。Prometheus／Alertmanager 的 web-config 只驗憑證鏈，不看 CN。

## 2026-10-28 夜：手冊 A→B 從零實跑（重構後第一次）
- 分三段跑完 346 個區塊：1–182（停在 20.3：我在脫鉤時把 mv passphrase 寫了兩次）、20–B（停在 29.1：落地區總表含上一輪舊的 opmenu 套件，16.3 換新包後對不上）、29–B 46 塊 0 失敗。兩處都已修（20.3 只記雜湊；29.1 只核對 rpm-target、2.6 排除 tools/opmenu）。
- 驗到的新東西：第 11 章 kafka-internal bootstrap＋19 條 binding；11.2 AD 斷線（alice 401、kafka-admin 列 10 個 topic、LDAPS 10 秒後恢復）；第 15 章自產 passphrase；第 16 章選單全顯示＋91 管理員閘門；第 20 章四個演練；C3 在 JDK 25 正常（29.7 約 80 秒回 200）。
- **真實缺口**：附錄 B 覆蓋率 0／816——21.3 換 CA 後銀行 Prometheus 的 ca.pem 沒換，抓 7071 全部 TLS 失敗。手冊 21.3.2／21.3.4／21.4.2／21.4.5 各加「銀行監控團隊換 ca.pem、重啟 Prometheus、10 個 target up」區塊（lab：bank-monitoring/prometheus/confluent/ca.pem）。
- **設計修正**：維運群組原本綁 DeveloperManage Topic:*（為了 DescribeConfigs），實測 bob 能建 topic；使用者決定收回，改 DeveloperRead Topic:*（rbac-opmenu.txt、16.2、opmenu README）。下一輪要驗 bob 的 11 健康檢查、21 重啟前檢查仍能跑。
- 18.3 稽核事件數改成實測（alice x1、bob host-ops x2、bob kafka-cluster DENIED x1）。

## 2026-10-29 02:02：腳本版從零重跑（重構後、脫鉤後、super user 改後）完成
- 29 段全過、結束碼 0、0 FAIL；八次驗收全 40/40（基底、憑證換發、遷移三段、回滾、finalize、OS 9.8、C3）；版本檢查三次「10 台都符合」（最後 OS 9.8／8.3.2／2.6.1／JDK 25，**含 c3-01 JDK 25**）；遷移段直連 8,310 筆 0 遺失、REST 1,572 次 0 失敗；OS 段 2,921 筆 0 遺失、REST 556 次 0 失敗。第 11 段 AD 斷線演練（腳本版新增）通過。紀錄 ~/kafka-lab-runs/script-final3-1028-2350.log。
- 14 個 WARN 都是預期的（16 站互動項目、license 試用版 29 天、縮減後提醒、容器不能重開機）。
