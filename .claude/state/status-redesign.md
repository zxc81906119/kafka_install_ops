# Status — branch `redesign`

Updated: 2026-10-28 00:50（沒有動 lab；`lab-mon-*` 容器還在，舊叢集已壞，等人從零重建）

**剛做完（2026-10-27 夜～28 凌晨）：主機存取新做法（cpuser、一組金鑰放 `/secure/ssh`、PVWA＋PSMP 進操作機是 root、sudoers 逐一列出、手動換金鑰）已進手冊與腳本**，取代 cpadmin／ssh-agent／SSH Key Manager 那一套：journey.md（第 0、3、15、16、19.4–19.6 章與全書的 ops02 身分／路徑，圖與 build.js／run-chapter.js）、install/（lib/ssh.sh、site.env、03／16／19 站、bank-sim／run-customer／run-all／run-upgrade-drill、opmenu 測試、README）、opmenu/（金鑰檔取代 ssh-agent；sudo 寫法固定；測試 test-ssh-key／test-sudo-forms）、問題清單、README／CLAUDE.md／skills。**只做了靜態檢查，沒有 commit，沒有從零重跑**；該驗證的清單見 redesign/README.md「新做法已進手冊與腳本」與 log/2026-10-27-access-in-manual.md。

**進行中（2026-10-27 晚）：監控改成外部 Prometheus／Alertmanager／Grafana + JMX exporter**（手把手第 17 章整章重寫，另動第 1.4／1.6／2／7／13／14／19／23 章、install 17 站與 01／07／19 站、bank-sim 的 `monitoring`、問題清單第 11 章、redesign 新段落）。細節與證據見 log/2026-10-27-monitoring.md；決策見 redesign/README.md「監控改成外部…（2026-10-27 定案）」。**沒有 commit。** 狀態：
- 已驗證（拋棄式環境 `lab-mon-kc/kb/rest/c3`，因為真叢集起不來，見下）：官方 exporter 規則掛上 4 種程序、4 個 job 的 target、21 條告警規則載入且指標都存在、32 個官方 dashboard 佈建進 Grafana（datasource 與 uid 兩項修正）、Grafana `/api/ds/query` 查得到資料、兩種 webhook 格式送達（含 resolved）、dashboard 覆蓋率 253／816 panel。
- **沒驗證**：真正的 controller／broker／REST／C3 主機上的滾動重啟（舊 lab 的叢集因 `conjur.poc.lab` 不存在起不來，cold boot 後 crash loop；依規則沒修）。真實主機只做了 jar／設定／drop-in 的派送與 daemon-reload。第 17.4 的重啟區塊與驗證迴圈的 `out` 是從拋棄式環境量的（只有 kc01、kb01、rest01、c3-01 各一）；第 7 章防火牆加 7071（c3）、第 19 章 JMX 檢查加 c3-01（22／22）、第 23 章 kc03 等指標的迴圈、第 2 章檔案數（65／61）都是改字沒實跑。**要從零重跑 lab（run-full.sh customer、run-customer.sh）才算驗證**，重跑時先看 17.4／17.7 的 `out` 換成 10／10。
- 推翻舊結論：Confluent Server 8.3.2 的 JMX **有** `kafka_server_raft_metrics_*`（官方 kraft.json 18／18 panel 有資料）。要在三台 controller 的 lab 複驗。
- 待使用者決定／確認：問題清單 11.1、11.5–11.8；官方 dashboard 的 `job="kafka-broker"` 寫法在專用 controller 叢集會讓幾個 panel 空掉，要不要在佈建時 sed 修（目前不改，告警有涵蓋）；C3 的 RocksDB／Streams 序列要不要放行。
- 環境：舊 lab 的叢集是壞的（Conjur 依賴），Docker 我重新啟動過一次（原本沒開）。Docker 裡我留下：`lab-mon-prometheus／alertmanager／grafana／webhook`、`lab-mon-kc／kb／rest／c3`（拋棄式 Confluent）、映像 `lab-mon-cp:1`（5.2 GB）、`~/kafka-lab/bank-monitoring`、dl01 已啟動。ops02 的 `~/install` 是新 repo 版本，`~/monitoring/to-bank/` 與 `~/landing/monitoring/` 有新檔，c3-01 等十台多了 `40-jmx.conf`。

**進行中（2026-10-27）：刪除 Conjur／provider 模式與 CyberArk 應用面**，三個 agent 同時改：手把手（journey-src）、install／opmenu、其餘文件（README、CLAUDE.md、問題清單、簡報、redesign、skills）。新編號：第 N 章（N≥16）→ N−1，手把手第 0–27 章，install/steps 01–26。**還沒有在 lab 重跑任何東西**；必須從零跑客戶模式（`run-full.sh customer`、`run-customer.sh`、升級演練）之後，新編號才算驗證過。細節見 log/2026-10-27-remove-conjur.md。以下「做到哪」「下一步」裡的章節編號，除非特別標示，都是**刪除前的舊編號**。

## 現在在做什麼
手把手（`docs/journey-src/journey.md`，第 0–27 章，只剩客戶模式；刪除 Conjur／provider 前是第 0–28 章三種模式）＋ `install/` 一章一支的腳本，
以 `lab` 專案從零實跑驗證。設計紀錄在 `redesign/README.md`；今天的細節在 `log/2026-10-25-cleanup-and-cyberark-gaps.md`。

## 做到哪
- e283fc5：只保留現行設計（舊 cpctl PoC、cp-poc／cp-man、windows/、舊手冊、全流程簡報、主機清單、jump01 設計全刪；磁碟資料與
  `cp-*:poc` 映像檔也刪了）。
- 手把手新增／修正（第二個 commit）：11.2 kafka-admin 用後換密碼、20.6 SSH Key Manager 換金鑰演練、3.1／3.4／16.x 正式環境
  不回顯貼法（`stty -echo`、`read -rs`、`ssh-add -t 10h`）、16.10 CPM 換 bind 密碼（客戶模式）、16.3 補 `AUDIT_PASSWORD`
  ＋「沒替換到的變數」檢查、16.5／16.6 結尾「用 PVWA 的 passphrase 還能輪替、錯的被拒」檢查、LDAP 錯誤數只算本次啟動後的
  `javax.naming`、26.5 補 demo topic。
- **重大發現**：Confluent CLI v4.72 的 `--passphrase @檔案` 是把路徑字串當 passphrase（PVWA 的值從沒用到）。已改成
  `"$(cat 檔案)"`（手把手 16.2／16.6、install 16）；代價是行程參數 → 問題清單 4.6 `hidepid=2`。
- 測試矩陣：客戶 0–21（240 塊）、provider 0–21（192 塊）、Conjur 0–21／23–28、install 客戶 1–25（38/38）、Conjur install（39/39）
  都通過，但都是在上述修正**之前**。第 16 章修正後在 lab 上重跑：passphrase 檢查兩次都「是」，16.10 bind 驗證 200。

## 下一步
0. （舊編號；provider 已刪除）第 21 章修正與第 13 章 otlp 修正曾在從零重跑通過。C3 告警實測結論見 redesign/README.md「C3 內建 Alertmanager 的 webhook 自訂 JSON」：UI 不能自訂、手改會被 C3 重啟蓋掉、方案 C（CONFIG_PATH drop-in）可行但 UI 之後建的動作不生效；**方案 E（Prometheus 同時送兩個 Alertmanager）兩邊都生效**（實測）。另發現第 13 章缺 otlp.promote_resource_attributes（已修，需從零重跑第 13 章驗證）。待使用者選方案、是否把 E 寫進手冊第 17 章（新編號）。
1. ~~客戶模式從零全書重跑~~ 2026-10-25 22:40 通過：0–21 247 塊、23–28 34 塊，0 失敗；11.2／16.x／20.6／26.5 輸出逐行確認。（Conjur 模式已刪除）
2. 升級演練 2026-10-26 完成：手把手第 22 章（8.2.4 起點）12 塊全過；腳本版 run-upgrade-drill.sh 全段 38/38×4、直連 6053 筆 0 遺失、**REST 失敗 4 次**（02:13:33–36，JDK 25 段重啟 REST；手冊與腳本都沒有先從 LB 拿掉 REST，只靠 nginx max_fails）→ 待使用者決定排空做法。run-customer.sh 結束碼修正 f41f053。
3. CyberArk 缺口 4：使用者決定不做（維持離線保管，舊編號 20.5）。
4. REST 重啟前先由 LB 停用（使用者選 A，2026-10-26）：手把手 3.5／12.1＋16 處（4324245）；install 建兩支小工具（c2…）、腳本 rolling_restart／22／27 走交握檔 ~/lb-requests、lab 由 bank-sim lb-watch 扮演 LB 團隊（49690bb）；OP menu 22 有 LB 連線就拒絕（638dd07）。
5. 使用者外出（2026-10-26 09:20）交代：盡量完成所有任務。排程：① 客戶手把手 0–21、23–28＋8.2.4→第 22 章（跑中）② 腳本版升級演練（驗 LB 交握、REST 應 0 失敗）③④（Conjur、provider 手把手，已刪除）。每輪逐行看、修、commit。
   - ① 2026-10-26 13:06 通過：客戶 0–21 319 塊、23–28 39 塊、8.2.4（腳本）→ 第 22 章 24 塊，0 失敗；五步共 14 輪全部「排空 0 秒、200」，12.1 演練 94 次 0 失敗。
   - ② 2026-10-26 14:35 通過：腳本版升級演練，LB 交握 8 次全部自動回覆；直連 6384 筆 0 遺失、**REST 1232 次 0 失敗**（上一輪沒排空是 4 失敗）、驗收 38/38×4。
   - ③ Conjur 手把手通過（歷史；模式已於 2026-10-27 刪除）。
   - ④ provider 0–22（歷史；模式已於 2026-10-27 刪除）：2026-10-27 從零重跑通過（324 塊、253 執行、0 失敗，五步 20 輪 REST 全 200）。上一輪在 21.3.3 倒掉（JDK cacerts 沒有新根，PKIX path building failed）已修（423a97f）：21.3.2／21.3.4／21.4.2／21.4.5 的 provider 專用 cacerts 區塊逐台驗證（加新根後每台 2、刪舊根後每台 1），階段二重啟後 controller／broker 全 active、MDS 200。第 13 章新加的 otlp 設定與標籤檢查也通過（剛啟動 5，穩定後 7）。
6. 2026-10-27 和客戶討論後的主機存取做法（PSMP 代登 root、一組 SSH 金鑰放操作機 root 0400、每台 `cpuser`、sudoers 白名單、私鑰不放 CyberArk 也不備份）已記在 redesign/README.md「和客戶討論後的主機存取做法」；手冊、install/、OP menu 已在 2026-10-28 凌晨改成新設計（見最上面），**尚未從零重跑**。產出：`docs/Confluent-CyberArk登入與主機存取設計.docx`（來源 docs/access-src/）。（客戶資訊整理簡報已依使用者決定刪除。）使用者說晚點會請我從零重跑 lab，驗證手冊與腳本（需要 Docker Desktop；目前 lab 是舊的 provider 模式狀態，Conjur 已清掉）。細節見 log/2026-10-27-access-design-docs.md。
7. 待辦（要 lab）：驗證換金鑰（19.6）／公鑰佈署（3.1）／鎖定密碼只靠金鑰的指令、16.4 窄規則（已改成逐一列出）、`opmenu-hostkey-test.sh`；客戶模式在刪除 Conjur 後從零重跑（必做，驗證新編號；含 `run-full.sh customer`、`run-customer.sh`、`run-upgrade-drill.sh`，第 13 章 otlp 修正也在這輪驗）。待使用者決定：webhook 方案（A／A＋D／C／E）與是否寫進第 17 章（新編號）、`docs/evidence/` 是否納入版控。
- 從未 push。

## 環境狀態
- lab: 空閒（2026-10-27 05:00，當時 provider 模式第 0–21 章做完，叢集健康：controller／broker active、MDS 200、C3 200）。
- 密碼檔：`~/kafka-lab/secrets.env`、`~/kafka-lab/pvwa/`；ops02 `~/secrets/`、`~/pki/store.pass`。
- `install/tools/lint.sh` 沒有 shellcheck 時用 `koalaman/shellcheck:v0.10.0`。
