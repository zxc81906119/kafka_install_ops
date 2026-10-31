# 2026-10-31 Podman 上照手冊逐章從零跑（每章自檢內容是否符合最終設計）

- 環境：Podman machine kafka-lab（rootful、WSL2 11 GB）；labtest 已刪；Docker Desktop 關閉。
- 第 0 章：13 塊（10 rc=0、3 略過），0.0 新節照原文通過。自檢：CyberArk、/secure/ssh、cpuser／sudo、9.6 凍結都符合。修：0.1 前提改「0.0 已做完」；labbuild 圖加 0.0 那一層。待驗：0.6 lb01 對應 Windows 18082／19021（Podman 是否轉埠，第 12、13 章測）。
- 第 1 章（無指令）自檢：版本路徑表的章號是舊的（1–20／21、26、27 → 2–19／29、30、31）；時間表 22、24、27、28 還寫「待補」（填 lab 實測）；名詞小抄 mTLS 說 Prometheus 用 mTLS（7071 已改 HTTPS only）。已改。
- 第 2 章：12 塊全過（數字和 Docker 那輪相同）；自檢無問題。
- 第 3 章：第一次停在 3.2——`podman cp 來源/. 容器:/目錄/` 目的目錄不存在會報錯（Docker 會自動建）。3.2 先 `install -d /root/landing`；5.1 的 `/var/www/repo/os` 一樣不存在，先修。自檢：3.3「72 files OK」→ 73；3.2 補「從頭做 79、lab 重跑 83（tools/opmenu、c3/）」。重跑 4 塊全過。
- 第 4 章：6 塊全過。自檢：設計都符合（PVWA＋PSMP→root、/secure/ssh、from=、兩段式 sudo、不放 CyberArk）。修：輪替章節「20.3、20.4、20.5、20」→「20.2–20.6」；4.1「四件事」→「三件事」；4.5 out 改成實際的 `host=172.35.0.31`（Docker、Podman 都不反查）。
- 第 5 章：10 塊全過（5.1 先建 /var/www/repo/os 的修正生效）。自檢無問題。埠對應先驗：Windows localhost:18082／19021 → curl rc=35（TCP 連到 lb01 的 nginx，後端還沒起來），`podman port` 有 8082→18082、9021→19021；第 12、13 章再驗 200。
- 第 6 章：4 塊全過；自檢：只上架基底、ssh＋tar 推給 repodeploy（銀行上架方式待回覆）符合；修「第 第 4 章」錯字（全書一起掃）。
- 第 7 章：14 塊全過；broker 仍是 errors=2——查出 `sysctl -w` 失敗也回 0（直接寫 /proc/sys/net/core/rmem_max 是 Permission denied），可行性測試那句「Podman 改得動」是誤判，已更正 feasibility log 與 redesign；手冊 7.3「errors=2，VM 上是 0」本來就對。自檢：7.3 防火牆後補「7071 沒有帳密，存取控制靠防火牆，拿到 Prometheus 位址後只放行它（11.4）」；「進7.3」空格。
- 第 8 章：3 塊全過。自檢：「第 29 章由腳本解開 versionlock」→「逐台解開、換完再鎖回（29.3–29.6）」（手冊是手打指令）。
- 第 9 章：6 塊全過（9 張 CSR、9 張簽發、檢查全 ok、21 個檔）。自檢：憑證表補用途——cp-server 也是 C3 內建 Prometheus／Alertmanager 與 broker／REST／C3 的 7071；kafka-internal 也是 controller 的 7071。
- 第 10 章：11 塊全過（Podman 上第一次起 Kafka 正常）。自檢：super.users 只有 kafka-internal、kafka-admin 只是 SCRAM 緊急帳號、TOKEN／CLIENT／LDAP 不要求 client 憑證，符合。補：10.4 的 MDS 日誌位置（metadata-service.log，不在 journal）；格式化的 `WARN 'share'` 說明（待修清單那一項）。
- **待使用者決定**：broker 的 `confluent.metadata.server.impersonation.protected.users` 沒有後來新增的平台身分 `confluent-audit`（18）、`svc-backup`（23）。要補的話改手冊第 10 章與 install/templates/broker.tpl，第 12 章 REST 起來後實測冒用被拒。
- 使用者決定補 protected.users（svc-backup、confluent-audit）：lab 手動改 ~/conf/broker.tpl、kb0*.server.properties、派送、逐台重啟（MDS 200、9 個身分），手冊第 10 章與 install/templates/broker.tpl 跟著改。第 12 章要實測：REST 冒用 svc-backup 被拒。
- 第 11 章：13 塊全過（25 條 binding、alice SystemAdmin／carol DeveloperRead、密碼檔 600、11.2 alice 401／kafka-admin 10 個／AD 開回 200）。自檢無問題。
- 第 12 章：11 塊全過（三種憑證情況、經 LB 200、12.1 演練 107 次 0 失敗）。自檢符合（只有 client 憑證、對應規則只列 REST 的 app、無 DEFAULT、重啟前 LB 停用）。
  - 埠對應實測：Windows `openssl s_client -connect localhost:18082` 拿到 CN=cp-server（銀行簽發 CA），不帶 client 憑證 rc=56 → Windows→Podman 轉埠→lb01→REST 通。
  - protected.users 實測：rest01 暫時把 svc-backup 加進 CN 對應規則（LB 先停用 rest01），app-legacy-billing 200、svc-backup 401（日誌 `Error while impersonating user svc-backup`）；還原規則、重啟、LB 恢復。
- 第 13 章：5 塊全過（C3 UI 50 s、kafka_broker_id 7）。自檢：「操作機連不到 9090（防火牆只開 9021）」不對（7.3 有開 9090、19.2 也從操作機連）→ 改成「9090 要 client 憑證，在 c3-01 用 c3-monitoring 查」。13 章節點數那項待修：手冊已寫「>0、穩定 7、剛啟動 5」，不用改。埠對應：Windows localhost:19021 → HTTP 200（CN=cp-server），0.6 兩側都驗完。
- 第 14 章：1 塊全過。out 的 C3 topic `2-6-1` → `2-5-1`（待修清單）。自檢：14.2 格式化重來用 `rm -rf …/*`（CLAUDE.md 陷阱：經 ssh 什麼都沒刪、漏隱藏檔）→ `sudo find … -mindepth 1 -delete`；14.1 broker 列補 metadata-service.log。
- 待第 25 章處理：25.1（6951 行附近）、25.2（7121 行附近）清資料用 rm -rf …/*（以 root 展開，刪得到但漏隱藏檔）→ 改 find -mindepth 1 -delete 再實測。
- 第 15 章：13 塊全過；protected.users 保留（一開始以為沒有：encrypt 會把整份重排成 `key = value`，用 `欄位=` 比對會找不到）。自檢無問題。
- 第 16 章：16 塊全過。自檢：開頭說「91 用於 MDS 故障時」與設計相反（91 要 MDS 換 token）→ 改成「AD 處理不了時用 91；MDS 也不通時選單進緊急主機模式、Kafka 類用 28.6 kafka-admin」。
- 第 17 章：23 塊過，第 24 塊遇到 Windows podman 客戶端經 ssh 連 machine 斷線（`ssh: handshake failed … wsarecv`，machine 正常、沒有當機），只重跑 24、25 塊通過。結果與 Docker 輪一致（https=200 http=000、up 10／10、22 條規則、32 dashboard、兩種 webhook firing／resolved）。自檢：17.5「抓取密碼放檔案不放設定裡」殘留 → 改成「只有 scheme https 與 tls_config，沒有帳密」。
- 第 18 章：8 塊全過（_sensitive 2 筆、43 篩 bob 2 筆存檔、敏感 1 筆、carol 被拒、RF 3）。自檢無問題；待修清單的 18.4 min.insync.replicas=1：手冊已寫明是刻意（少一台 broker 不停寫），劃掉。
- 第 19 章：7 塊全過，一次就健康 22／22、安全 16／16、應用程式寫讀、選單重啟 kb03、Podman 上冷開機（compose stop／start：MDS 86 s、C3 153 s、重試 0）。**安裝基底 0–19 章在 Podman 上照手冊從零跑完。**
- 待使用者決定：19.5 建議 `svc-ops.key`（SystemAdmin）交付後「移到離線保管」，和 10-28 定案「平台密碼與金鑰只放操作機」有出入。
- 順帶：lab 容器沒有 `unzip`（找 jar 時靜默失敗，改用 grep）；SecurePassConfigProvider 在 confluent-server／metadata-service、REST 的 confluent-security、C3 自己的 RPM 裡，不用另裝 jar。

## svc-ops.key 留在操作機（使用者 2026-10-31 選定）
- 19.5 原寫「安裝完成後建議移到離線保管」，和 10-28「平台密碼與金鑰只放操作機」矛盾；改為留在 `~/pki`（0600），追溯靠 PVWA 登入紀錄、PSMP 錄影、Kafka 稽核日誌（User:svc-ops）。
- 已改：journey 19.5（兩處）、questions 8.8（改成告知）、redesign/README.md、`19-acceptance.sh` 的交付提醒；questions docx 已重建。

## 第 20 章通過（Podman，2026-10-31 19:04）
- 23 塊 rc=0；kafka-admin 換密碼、master key 輪替＋滾動重啟（MDS 200、C3 200、alice 200）、svc-mds-bind 換密碼（7 行密文、LDAP 錯誤 0）、SSH 換金鑰（探針 28 次 0 失敗）、SCRAM A／B（600 筆 0 錯誤）。
- 自檢：20.1 總表 master key 的「保管人異動」不合 10-28 定案（沒有保管人）→ 改「每年（待銀行確認 8.6）；疑似外洩時」；SSH 金鑰補題號 4.6。
- 20.4 out 的 security.properties 行數 151 是舊值，從零建起是 170。

## 第 21 章通過（Podman，2026-10-31 19:17）
- 81 塊 rc=0：leaf 換發、換 CA 三階段（G2）、換鏈三階段（G3）；每次拿掉舊根後舊憑證/舊鏈 → REST 000，新的 200，alice/套件庫 200，Prometheus 10/10。
- 自檢：7071（JMX exporter，只用 HTTPS）也出示伺服器憑證，拿掉舊根後銀行 Prometheus 只信新根 → 21.1 補 kc01/rest01/c3-01:7071（11 行），21.3 把關 13→17、21.4 把關 17→19；21.2.4 說明 7071 讀服務的 keystore、隨服務重啟。刪兩個空的 @role；三處說明段落移到小安的指令前。

## 第 22 章通過（Podman，2026-10-31 20:32）
- 9 塊 rc=0；blackbox 24/24 up、promtool SUCCESS、規則 25 條 0 錯；操作機腳本 10 張、5 天／過期兩個分支與 syslog 正確；timer 08:10。
- 使用者同意下載 prom/blackbox-exporter:v0.25.0（Podman machine 新建，原本沒有）。
- 自檢：22.1 的表補 7071／C3 9090（同一張憑證，7071 過期時 ConfluentTargetDown 會響，不另外探）；章首「規則 24 條」改 25（17 章 22＋3）。

## 第 23 章通過（Podman，2026-10-31 20:38）
- 13 塊 rc=0；svc-backup 反向（讀訊息/建 topic/改 binding 都被拒）、匯出 7 檔密碼字樣 0、timer、比對、還原演練（topic＋binding 3＋SCRAM＋配額，9095 寫讀 ok）。
- 發現：23.5 OP menu 44 快照和「最新一份備份」比對，那份帶著剛刪的 orders.backup-demo → topics/topic-configs 不同。改成先匯出一份新備份再拍快照比（手動驗證 7 檔全相同）；快照權限 33→32（從零的實際值）。
- 自檢：章首順序補 23.6；第 24 章章首「19 → 21 條」待查（17 章後已是 22 條）。

## 第 24 章通過（Podman，2026-10-31 20:44）
- 9 塊 rc=0；規則 27 條 0 錯、retention 縮短 250 秒後三個 replica 0 KB、reassign 4 秒 kb01 目錄消失。
- 自檢：章首「19 → 21 條」改成「多 2 條（17 章後 22→24，做過 22 章 25→27）」。

## 第 25 章通過（Podman，2026-10-31 20:52）
- 14 塊 rc=0；換 kc03（新 directory id，MDS 全程 200）、kb04 縮減 71 個 replica 約 12 分、空 broker 加回 1020 秒後 104 上 10 個 replica、背景 6 萬筆 0 ERROR／2 次 leader 重送。
- 改：25.1.2／25.2.3 清資料目錄 rm -rf dir/* → find -mindepth 1 -delete（腳本版本來就是）；format 輸出 4.3-IV0B → 基底的 4.2-IV1A；scan-log EXPECTED 加「ERROR 行）：0；」（第 14 塊誤報）。
- 使用者問：重建要新 cluster id？答：第 25 章沿用原 cluster id、只換 directory id，零停機；只有 26.4 試用期重置才用新 cluster id（停機約 15 分）。

## 第 26 章通過（Podman，2026-10-31 21:29）
- 26.1／26.2 3 塊 rc=0（trial 剩 29 天、rc=2、timer 08:00）；26.4 重置 8 塊照設計略過（on-demand, destructive；10-30 在 Docker lab 實跑過）。
- 自檢無需修改：license JWT 放 ~/secrets 0600、不放 CyberArk；重置後用 kafka-internal 建第一條 binding（同第 11 章）。

## 第 27 章通過（Podman，2026-10-31 21:31）
- 15 塊 rc=0；SCRAM A／B、app-shipping 用 ca/g2 簽、REST 白名單＋12.1 重啟、寫自己的 200／別人的 40301、下線全部清乾淨。
- 自檢：27.3 選 CA 目錄的說明補 21.4（中繼改由 G3 簽，仍在 ca/g2）。

## 第 28 章通過（Podman，2026-10-31 21:34）
- 14 塊 rc=0；28.3 kb04 停掉 → 270 秒兩條 firing → 重啟 20 秒歸零 → 150 秒解除；28.6 擋 8090 → 緊急主機模式（31 DENIED）、kafka-admin 9095 照常、恢復後換密碼。
- 改：28.1 svc-mds-bind 密碼換了指向 20.4（原寫 15 章）；scan-log EXPECTED 加「 8090=000 9095=通」（28.6 擋 8090 是預期）。

## 第 29 章通過（Podman，2026-10-31 21:45–22:07）＋遷移後驗收
- 27 塊 rc=0：C3 2.6.1（4 個 generated 檔回 cp-control-center）、broker／controller（leader 最後）／REST／ops02 → 8.3.2、全部 JDK 25、kb04 回滾 8.2.4/JDK 21 再升回、finalize CP-8.3-IV0B。
- 遷移後重跑第 19 章：健康 22/22、安全 16/16、應用程式寫讀、冷開機 MDS 79 s／C3 135 s。
- 改：章首「第 1–20 章」→ 2–19；「第 1、2 章隨落地區」→ 2、3；29.8「下面這一段」順序；29.10 `21-upgrade.sh` → `29-upgrade.sh`。

## 第 30 章通過（Podman，2026-10-31 22:14）＋ OS 9.8 後驗收
- 使用者同意下載 Rocky 9.8 更新集合（156 個 RPM、79 MB，鏡像比 10-30 多 2 個）與 Rocky 10 中繼資料。
- 12 塊 rc=0：每台 120–126 個更新、confluent-* 0 個、Rocky 10 判斷會停；broker → controller（leader 最後）→ REST／C3／ops02 全部 9.8，鎖 = 裝，REST 照 12.1 重啟。
- 之後第 19 章：健康 22/22、安全 16/16、寫讀、冷開機 MDS 117 s／C3 151 s。
- 改：30.5 `26-os-patch.sh` → `30-os-patch.sh`；更新集合大小改引 30.0；刪空的 @role；空格。
