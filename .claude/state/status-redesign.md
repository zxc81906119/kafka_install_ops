# Status — branch `redesign`

Updated: 2026-10-27（lab 關閉：Docker Desktop 沒開；沒有人在用）

## 現在在做什麼
手把手（`docs/journey-src/journey.md`，第 0–28 章，三種模式 customer／conjur／provider）＋ `install/` 一章一支的腳本，
以 `lab` 專案從零實跑驗證所有模式。設計紀錄在 `redesign/README.md`；今天的細節在 `log/2026-10-25-cleanup-and-cyberark-gaps.md`。

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
0. （已驗證）provider 第 21 章修正與第 13 章 otlp 修正都在從零重跑通過。C3 告警實測結論見 redesign/README.md「C3 內建 Alertmanager 的 webhook 自訂 JSON」：UI 不能自訂、手改會被 C3 重啟蓋掉、方案 C（CONFIG_PATH drop-in）可行但 UI 之後建的動作不生效；**方案 E（Prometheus 同時送兩個 Alertmanager）兩邊都生效**（實測）。另發現第 13 章缺 otlp.promote_resource_attributes（已修，需從零重跑第 13 章驗證）。待使用者選方案、是否把 E 寫進手冊第 18 章。
1. ~~客戶模式從零全書重跑~~ 2026-10-25 22:40 通過：0–21 247 塊、23–28 34 塊，0 失敗；11.2／16.x／20.6／26.5 輸出逐行確認。之後再看一次 Conjur 模式第 16 章。
2. 升級演練 2026-10-26 完成：手把手第 22 章（8.2.4 起點）12 塊全過；腳本版 run-upgrade-drill.sh 全段 38/38×4、直連 6053 筆 0 遺失、**REST 失敗 4 次**（02:13:33–36，JDK 25 段重啟 REST；手冊與腳本都沒有先從 LB 拿掉 REST，只靠 nginx max_fails）→ 待使用者決定排空做法。run-customer.sh 結束碼修正 f41f053。
3. CyberArk 缺口 4：使用者決定不做（維持 20.5 離線保管）。
4. REST 重啟前先由 LB 停用（使用者選 A，2026-10-26）：手把手 3.5／12.1＋16 處（4324245）；install 建兩支小工具（c2…）、腳本 rolling_restart／22／27 走交握檔 ~/lb-requests、lab 由 bank-sim lb-watch 扮演 LB 團隊（49690bb）；OP menu 22 有 LB 連線就拒絕（638dd07）。
5. 使用者外出（2026-10-26 09:20）交代：盡量完成所有任務。排程：① 客戶手把手 0–21、23–28＋8.2.4→第 22 章（跑中）② 腳本版升級演練（驗 LB 交握、REST 應 0 失敗）③ Conjur 手把手 0–21、23–28 ④ provider 手把手 0–21。每輪逐行看、修、commit。
   - ① 2026-10-26 13:06 通過：客戶 0–21 319 塊、23–28 39 塊、8.2.4（腳本）→ 第 22 章 24 塊，0 失敗；五步共 14 輪全部「排空 0 秒、200」，12.1 演練 94 次 0 失敗。
   - ② 2026-10-26 14:35 通過：腳本版升級演練，LB 交握 8 次全部自動回覆；直連 6384 筆 0 遺失、**REST 1232 次 0 失敗**（上一輪沒排空是 4 失敗）、驗收 38/38×4。
   - ③ Conjur 手把手 0–21、23–28 通過（319+39 塊，0 失敗）。
   - ④ provider 0–22：2026-10-27 從零重跑通過（324 塊、253 執行、0 失敗，五步 20 輪 REST 全 200）。上一輪在 21.3.3 倒掉（JDK cacerts 沒有新根，PKIX path building failed）已修（423a97f）：21.3.2／21.3.4／21.4.2／21.4.5 的 provider 專用 cacerts 區塊逐台驗證（加新根後每台 2、刪舊根後每台 1），階段二重啟後 controller／broker 全 active、MDS 200。第 13 章新加的 otlp 設定與標籤檢查也通過（剛啟動 5，穩定後 7）。
6. 2026-10-27 和客戶討論後的主機存取做法（PSMP 代登 root、一組 SSH 金鑰放操作機 root 0400、每台 `cpuser`、sudoers 白名單、私鑰不放 CyberArk 也不備份）已記在 redesign/README.md「和客戶討論後的主機存取做法」；**手冊、install/、OP menu 還是舊設計（cpadmin、ssh-agent、SSH Key Manager）**，客戶正式採用後才改，改了要從零重跑。產出：`docs/Confluent-CyberArk登入與主機存取設計.docx`（來源 docs/access-src/）、`docs/Confluent-Kafka客戶資訊整理.pptx`（來源 docs/deck-src/customer-info.js）。細節見 log/2026-10-27-access-design-docs.md。
7. 待辦（要 lab）：驗證換金鑰／公鑰佈署／鎖定密碼只靠金鑰的指令；install/steps/17-opmenu.sh 的 sudoers 改成逐一列出服務（現行 `confluent-*` 會放行多個 unit）；客戶與 Conjur 模式重跑第 13 章（otlp 修正只在 provider 驗證過）；provider 模式第 22 章。待使用者決定：webhook 方案（A／A＋D／C／E）與是否寫進第 18 章、`docs/evidence/` 是否納入版控。
- 從未 push。

## 環境狀態
- lab: 空閒（2026-10-27 05:00，provider 模式第 0–21 章做完，叢集健康：controller／broker active、MDS 200、C3 200）。
- 密碼檔：`~/kafka-lab/secrets.env`、`~/kafka-lab/pvwa/`；ops02 `~/secrets/`、`~/pki/store.pass`。
- `install/tools/lint.sh` 沒有 shellcheck 時用 `koalaman/shellcheck:v0.10.0`。
