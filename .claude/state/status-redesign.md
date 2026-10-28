# Status — branch `redesign`

Updated: 2026-10-28 10:50（**lab 使用中**：乾淨手冊實跑從零進行中，勿動 Docker）

## 現在在做什麼
`bash docs/journey-src/tools/run-full.sh customer` 從零跑（開始 10:46，紀錄 `~/kafka-lab-runs/run-customer-0-99-20261028-1046.log`，路徑也在 `~/kafka-lab-runs/current-log.txt`）。
這輪是最終版文字：cp-server 純 server 憑證＋c3-monitoring（9 張憑證）、移除兩條 raft 告警（19 條規則）。失敗就修、再從頭跑。

## 已完成（都已 commit，從未 push）
- 手把手 0–27 章（38 圖）＋ install 01–26 站；基底 OS 9.6／CP 8.2.4／C3 2.5.1／JDK 21 → 遷移 OS 9.8／CP 8.3.2／C3 2.6.1／JDK 25。
- 腳本版從零跑完（舊文字），結束碼 0，各段驗收 39/39。
- 2026-10-28：cp-server 改純 server（certs.txt、09／13／14／19／20 站、control-center.tpl、prometheus-generated.yml、手冊第 9／13／20 章、問題清單 6.2、圖）；19 站新增驗收「cp-server 只有 serverAuth 且連 9090 被拒」；第 17 章 raft 指標說明更正、兩條 raft 告警刪除。docx 已重建。

## 進行中（2026-10-28 下午）
- **與 CyberArk 脫鉤已改完（手冊、install、opmenu、README、CLAUDE.md、問題清單第 8 章、access Word），docx 都重建**；**尚未實跑**。改動重點：15 站工程師自己產生 passphrase；16 的緊急憑證改讀 `~/secrets/opmenu-breakglass.pem`（設定名 `OPMENU_BREAKGLASS_PEM`）；run-customer.sh 段號變 1–28（刪掉三個 Secrets 團隊 stage）。腳本版重跑**之前被我停掉時沒停乾淨、跑到第 9 站，已全部殺掉**；下一輪從零重跑。
- 待使用者回覆：`OPMENU_MENU_AUTHZ` 要不要明寫進派送的 opmenu.conf＋手冊 16.3 加項目→權限表。
- 已 commit：C3 連內建 Prometheus／Alertmanager 改用 svc-c3；手冊 19.2 新增 cp-server 被拒檢查（16/16，未實跑）。

## 下一步（使用者 2026-10-28 同意照此順序）
1. 目前的腳本版從零重跑（16:25 起，驗 cp-server／c3-monitoring／raft／脫鉤／C3 依賴）跑完 → 逐行看紀錄＋scan-log；27 個 FAIL 是第 5 段預期的「03 等銀行」。
2. **super user 只剩 kafka-internal**（redesign/README.md 最後一節）：common.tpl、第 10 章；第 11 章 bootstrap 用 kafka-internal 憑證建第一條 binding（svc-ops → SystemAdmin）、rbac.txt 加 svc-ops／kafka-admin SystemAdmin、11.2 說法；新增「停 ad01 → alice 401、kafka-admin 9095 仍可用 → 開回」驗證（放 11 或 19）；10／11 站；README／CLAUDE.md、第 19 章「svc-ops 是 super user」字樣。
3. **章節重構**（redesign/chapter-restructure.md）：對照表＋改寫工具，改手冊、install/steps 檔名、site.env、bank-sim、run-customer、run-chapter、run-full、圖、問題清單、README、CLAUDE.md、skills；grep 殘留舊編號。
4. 從零重跑手冊（run-full）與腳本（run-customer），一輪驗 2、3 和 OP menu 全顯示（16 站要先重打包 opmenu，手冊 16.5 新輸出實測）。
5. 補章（先手動實跑再做腳本，依新結構寫）：還原演練、磁碟告警與換碟、故障排查速查、新應用上線流程；之後憑證到期監控（選配，blackbox＋每日腳本）。
6. 順手：問題清單加題（跨機房 DR、svc-ops 私鑰離線保管方式、UserAdmin 專門團隊、AD 636 只放行 broker）；kraft.json 哪 8 個 panel 空；第 18 章 __opmenu-host-ops authorize 次數重量；假 omnibus 接收端；可讀性未細改章節（12、13、14、17、20.3／20.4、22–25、0.5.x）與 15.3、18.3 舊稱。
- 待使用者決定／回覆銀行：`opmenu-emergency` 對 root 的意義；換金鑰週期；dashboard `job="kafka-broker"` 要不要 sed 修；C3 是否多放行 RocksDB／Streams；`docs/evidence/` 要不要版控；omnibus 固定值正式值。
- 已結案（2026-10-28）：repodeploy 是 lab 模擬銀行上架的帳號，不改；cpuser 本來就不在 repo01。

## 環境狀態
- lab：專案 `lab`，**從零重建中**（run-full 會先拆掉整個 lab，只留 `~/kafka-lab/landing`、`~/kafka-lab/bank-os`）。四個 `lab-mon-*` 容器由跑本身處理。
- Docker VM 約 10.7 GB，不要同時跑別的；使用者其他專案的映像／卷不要動。
- 密碼檔：`~/kafka-lab/secrets.env`、`~/kafka-lab/pvwa/`；ops02 `~/secrets/`、`~/pki/store.pass`、私鑰 `/secure/ssh`（volume `ops-secure`）。
- Git Bash 的 `python3` 是 Store 空殼：改檔用 node／Edit／sed。補丁腳本放 scratchpad，用 `node` 跑。
- 背景 monitor 的過期通知可忽略。
