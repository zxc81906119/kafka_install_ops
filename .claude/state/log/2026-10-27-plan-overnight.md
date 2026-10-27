# 2026-10-27 夜間計畫（使用者睡前交代，早上檢查）

使用者的指示依序（都已確認，不要再問）：

1. **監控改成外部**：JMX exporter + 銀行提供的 Prometheus／Alertmanager／Grafana；C3 內建的保留但告警不用；controller／broker／REST／C3 都抓；官方 dashboard（jmx-monitoring-stacks）全部引入；告警規則用官方／建議；webhook 給兩種範例（預設 JSON、自訂 JSON template）。lab 用 lab-mon-* 容器扮演銀行。**背景工作 afb9df7037c82e28f 進行中**（改手冊第 17 章、1–2、13、install/steps/17、bank-sim、問題清單、設計紀錄）。
2. **新的主機存取做法放進手冊＋安裝腳本＋OP menu**：PSMP 代登 root、一組 SSH 金鑰（操作機獨立 file system，例如 /secure/ssh）、每台 `cpuser`（本機帳號、鎖定密碼、只靠金鑰）、公鑰只用 `from="操作機 IP,127.0.0.1,::1"`、sudoers 安裝期全權／交付後逐一列出服務、換金鑰新舊並存。依 docs/access-src/access.md 與 redesign/README.md「和客戶討論後的主機存取做法」。cpadmin 全部改 cpuser；ssh-agent／SSH Key Manager 的做法拿掉。
3. **遷移路徑重整**（使用者 10/27 夜間追加）：
   - 安裝基底改成 **Confluent 8.2.x（8.2.4）＋ JDK 21 ＋ OS 9.6**，主線再「遷移」到 **8.3.x（8.3.2）＋ JDK 25 ＋ OS 9.8**。8.2.x 不支援 JDK 25，所以基底一定是 JDK 21。
   - 第 21 章（升級 Confluent 與 JDK）從選配演練變成主線；第 26 章（OS 修補）加 9.6→9.8 小版本更新演練；第 27 章（升級 C3）配合 8.2 的 C3 版本（要查相容性與 RPM，目前 C3 裝 2.6.1）。
   - 落地區：8.3.2 在 landing、8.2.4 在 landing-extra，要對調；9.6 的 OS 內容要從 Rocky vault（dl.rockylinux.org/vault/rocky/9.6）下載；Rocky 9.6 映像 rockylinux/rockylinux:9.6 存在，9.8 倉庫在 pub/rocky/9.8（2026-10-27 都查過可連）。
   - `run-customer.sh` 與 `run-upgrade-drill.sh` 合併成一條完整遷移流程。
   - 限制：Rocky 不是 RHEL；容器不能真的重開機（核心是 WSL2 的）。
4. **最後：從零重跑 lab 驗證**（使用者說「你可以等等弄完然後從零跑」）：`run-full.sh customer`（手冊）、`run-customer.sh`（腳本）、遷移／升級演練。逐行檢查輸出，修到通過為止。

## 順序
1 → 2 → 3 → 4。1、2、3 會動同一批檔案（journey.md、install/、bank-sim.sh），**不要同時開**，一個做完再做下一個。

## 規則（沿用）
不 push；碰到要使用者決定的事就暫停那一項並記在狀態檔，不自己猜；不刪不是自己建的東西（Docker 裡有使用者其他專案的映像／容器／卷，不要動）；lab 只剩舊 provider 模式叢集，Conjur 已刪，服務重啟可能起不來，從零重跑時會整個重建。
