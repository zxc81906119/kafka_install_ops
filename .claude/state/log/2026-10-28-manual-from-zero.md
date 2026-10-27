# 2026-10-28 手冊從零實跑（客戶模式，新基底＋遷移主線）

2026-10-28 01:30 起，`run-full.sh customer` 從第 0 章跑到第 27 章，分段接續（每次失敗就修手冊、從失敗那一塊接著跑）。
紀錄：`~/kafka-lab-runs/run-customer-*-20261028-*.log`。這是**一次修補式的完整走完**，不是一次乾淨連續的跑；
腳本版（run-customer.sh）與第二次乾淨連續的手冊實跑還沒做。

## 實跑發現並已修的手冊／腳本問題
1. **17.7**：用了 `kafka_server_raft_metrics_current_leader`；三台 controller、基底 8.2.4 的叢集裡 Prometheus 完全沒有 raft 指標
   （controller 3462 條序列、106 條 kafka_controller_*，名稱含 raft 的 0）→ 驗證改用 `kafka_controller_kafkacontroller_activecontrollercount`。
   **待查**：遷移到 8.3.2 後三台 controller 是否出現 raft 指標（監控工作在 8.3.2 單台 controller 看過有）。
   17 章的「raft 指標有資料」與 KRaftNoLeader 等兩條告警都依賴它；沒有就永遠不會觸發，要依查證結果改。
2. **20.3.3、20.4.4** 的端點檢查塊前面沒有 `@role`，繼承到「Windows 終端」，在本機解析不了 poc.lab → 補 `@role 小安 | ops02 | root`。
3. **21.4–21.6**：各台 dnf 中繼資料是舊快取（剛上架的 8.3.2 找不到），安裝失敗被 `;` 吞掉 → 加 `--refresh`，失敗改 `|| { …; exit 1; }`，
   rolling 區塊的 ssh 加 `|| exit 1`；install/steps/21-upgrade.sh 同步。
4. **23.4／24.3**：`run()` 裡的 `"$@"` 與 master key 在本機就被展開，`kafka-storage format` 沒真的跑、錯誤被吞 → 改 `\$`。
5. **21.8／21.9 順序**：回滾演練（finalize 之前）原本排在 finalize 之後，演練後也沒升回去 → 調成「回滾演練」在前、補「升回去」指令塊，finalize 變 21.9。
6. **25.4／22.2**：systemd 單元沒有 `HOME`（root 服務不設），腳本用 `$HOME` → 單元加 `Environment=HOME=/root`。
7. **26（OS 9.6→9.8）**：`rocky-repos` 更新會把預設 repo 檔（外網 mirrorlist）裝回來並啟用 → 更新後再關掉（手冊＋26-os-patch.sh）；Rocky 專屬。
8. **16.3**：打包後沒有任何指令把新的選單包送進操作機，裝到的是第 2 章帶進去的舊包 → 16.3 補送進操作機的塊；2.4 改成先清掉再送、落地區沒有該目錄就不做。
9. 27.1：`dnf download` 在 RPM 已完整時掛住不動（連線 CLOSE-WAIT），手動 kill 後驗簽章；網路偶發，未改文件。

## 還沒確認的
- 25.2「改 role binding：」那次是空的（預期 403 Forbidden），事後手動重現是正常 403；疑似 kb04 剛加回時 MDS 還在穩定。
- 23.5 的 `kb04 MDS=000`（kb04 當時沒起來，是 24.3 之前的狀態問題）。
- 手冊 out 區塊多數是預期值，要等第二次乾淨連續跑再對一次。
- 腳本版 run-customer.sh 沒跑過新路徑；16 站（opmenu）送包的方式要看。
