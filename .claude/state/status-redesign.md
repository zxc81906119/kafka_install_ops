# Status — branch `redesign`

Updated: 2026-10-28（lab：專案 `lab` 起著，叢集在最終遷移狀態，沒有人在用；下一步會拆掉從零重建）

## 現在在做什麼
客戶情境（CyberArk 只有 PAM）的手把手（`docs/journey-src/journey.md`，第 0–27 章，38 張圖）＋ `install/` 腳本（01–26 站）。
主線＝**安裝基底 → 遷移**：基底 OS 9.6／CP 8.2.4／C3 2.5.1／JDK 21（第 1–20 章）→ 遷移到 OS 9.8／CP 8.3.2／C3 2.6.1／JDK 25（第 21、26、27 章）。
設計決策在 `redesign/README.md`；細節在 `log/2026-10-27-*`、`log/2026-10-28-*`。

## 做到哪（除標註外都已 commit，從未 push）
- 刪 Conjur／provider／CCP 與模式機制；手把手 0–27、步驟檔 01–26。
- 監控改成「JMX exporter＋銀行的 Prometheus／Alertmanager／Grafana」（第 17 章）；webhook 兩種格式，自訂那種照銀行 IBM Netcool/OMNIbus 十欄位規格（固定值是範例值，待銀行確認）。
- 主機存取新做法：PVWA 網頁登入（AD＋MFA）→ PSMP → 操作機 root；一組金鑰 `/secure/ssh`；各主機 `cpuser`；公鑰只帶 `from=`；sudoers 逐一列出；手動換金鑰。Word：`docs/Confluent-CyberArk登入與主機存取設計.docx`。
- 可讀性整理（全章）＋20 張概念圖。
- **驗證**：腳本版從零跑完整條路，結束碼 0，各段驗收 39/39（基底、憑證換發、遷移三段、回滾演練、OS 9.8、C3），遷移期間直連 0 遺失、REST 0 失敗。手冊走完 0–27 但是修補式（9 個問題），**還沒有乾淨實跑**。
- **未 commit**（本次收尾一起 commit）：27.1 與 `run-customer.sh` 的 C3 RPM 下載改成 `dnf --url` + `curl`（`dnf download` 1 GB 後行程卡住）。

## 下一步（順序已定）
1. **cp-server 改成純 server 憑證**（使用者選「改手冊＋腳本＋問題清單，並從零重跑」，讓下一輪實跑就是最終版）：
   cp-server 只留 serverAuth；新增 client 憑證 `c3-monitoring`（clientAuth、無 RBAC，不用 svc-c3）；C3 兩個 keystore＋alias、`prometheus-generated.yml` 的 tls_config、13 章檢查指令 `--cert` 都改用它；
   動第 9、13、20 章與清單表、`09-certs.sh`、`13-control-center.sh`、`templates/prometheus-generated.yml`、`20-cert-rotate.sh`、`bank-sim.sh`（CA 依 EKU 簽）、問題清單；
   驗證：`openssl x509 -ext extendedKeyUsage` 只有 serverAuth；cp-server 當 client 憑證連 Alertmanager 應被拒；c3-monitoring 通過；驗收 39/39。已上線環境順序：先換 C3 再換發 cp-server。
2. **raft 指標**：三台 controller 叢集（8.2.4、8.3.2 都）Prometheus 裡沒有任何 raft 指標（單台 standalone 才有）。改第 17 章（17.9 覆蓋率、17.10 說法）與 `install/templates/confluent-alerts.yml` 的 KRaftNoLeader、unknown_voter 兩條（永遠不會觸發）→ 改用 `kafka_controller_kafkacontroller_activecontrollercount`。
3. 之後：`bash docs/journey-src/tools/run-full.sh customer`（乾淨、不中斷；失敗就修再重頭）→ `bash install/lab/run-customer.sh` 從零；逐行看紀錄＋`scan-log.sh`；重建 docx；commit。
4. 假的 omnibus 接收端（驗十欄位）：VM 記憶體不緊時再做；Netcool/OMNIbus 無社群版。
5. 可讀性尚未細改：第 12、13、14、17、20.3／20.4、22–25 章內文、0.5.x；15.3、18.3 的 out 區塊有舊稱「第 18 站／16 站」。
- 待使用者決定／回覆銀行：repodeploy 與 cpuser 並存；`opmenu-emergency` 對 root 的意義；換金鑰週期；dashboard 的 `job="kafka-broker"` 要不要 sed 修；C3 是否多放行 RocksDB／Streams 指標；`docs/evidence/`（SCRAM 截圖，未追蹤）要不要版控。

## 環境狀態
- lab：專案 `lab`（14 台＋dl01）在最終狀態（OS 9.8、CP 8.3.2、C3 2.6.1、JDK 25，c3-01 留 21）；`lab-mon-prometheus／alertmanager／grafana／webhook` 在跑（Grafana `localhost:13000`，僅 lab）。從零重跑會先拆掉整個 lab，只留落地區。
- 落地區 `~/kafka-lab/landing`、銀行 OS 內容 `~/kafka-lab/bank-os`；執行紀錄 `~/kafka-lab-runs/`。
- Docker VM 約 10.7 GB，不要同時跑別的；Docker 裡使用者其他專案的映像／卷**不要動**。
- 密碼檔：`~/kafka-lab/secrets.env`、`~/kafka-lab/pvwa/`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node／Edit／sed。run-chapter 切片續跑要補前 4 行與 ops02 heredoc 開頭行；heredoc 腳本裡 `ssh` 要加 `-n`。
- 背景 monitor 的過期通知（bb71uf6q4 等）可忽略。
