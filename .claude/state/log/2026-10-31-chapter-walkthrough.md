# 2026-10-31 手冊逐章實跑（使用者每章看完才往下）

- 用 `run-full.sh customer <章> <章>` 一章一章跑，每章列出指令、作用、結果給使用者看。第 0–13 章全部通過（rc=0、沒有可疑輸出）。
- 跑完要一起修的手冊小地方：
  - 4.5 out 寫 `host=kb01.poc.lab`，實跑是 `host=172.35.0.31`（sshd 沒反查）：out 不寫死主機名。
  - 10.4 格式化 controller 時 8.2.4 的 kafka-storage 印 `WARN 'share' in group.coordinator.rebalance.protocols is deprecated`（不是我們的設定）：out 補說明。
  - 13 章第 5 塊「帶 kafka_broker_id 的節點數」：檢查只要 >0 就停，印出當下回報到的數（這次 5，之後是 7 = 3 controller＋4 broker）；改成等到 7／7。
  - 14 章 out 的 topic 寫 `poc-cluster-2-6-1-10-…`，基底是 C3 2.5.1，實跑是 `2-5-1`。
  - 16.5 第 12 塊 out 的兩行 kb04 日誌：23 只列 error／warn 字樣的行，最近 10 行沒有時就沒輸出（這次沒有）；out 要註明。
  - 18.4 稽核 topic 是 broker 自建、min.insync.replicas=1：銀行若要求稽核紀錄至少寫 2 份才算成功，可改 2（列入待確認）。
- 使用者決定：JMX exporter 7071 只用 HTTPS、拿掉 basic auth（redesign 2026-10-31）。第 17 章前先在 lab 手動試，再改手冊。
- 7071 只用 HTTPS：先在 kb01 手動試（只有 httpServer.ssl 的標頭＋官方 broker 規則）：匿名＋銀行根憑證 200、11,787 條指標；http:// 000（rc=52）；只信任別的公開 CA rc=60。注意：試的時候 `set -x` 會印出 keystore 密碼那行（被擋下，改用步驟記號）；從 stdin 餵腳本時 ssh 要 `-n`；ops02 的系統 CA 清單已含銀行根憑證，測「不信任」要另取一張公開 CA。
- 手冊改：17 章開頭、17.1（新標頭、清掉舊 jmx-scrape.*）、17.4（https=200 http=000）、17.5（scrape 設定拿掉 basic_auth、不交 scrape.pass）、17.6／22 章清單、19 章驗收「7071 只走 HTTPS」、25.1.5、B.2；17.2／17.3 out 行數（少 6 行：153／431／49／128）。questions 11.3（資安是否接受 HTTPS＋來源限制）、11.4（來源限制是唯一的存取控制）。
- 照新手冊跑第 17 章：25 塊全 rc=0；10 台 https=200 http=000；銀行 Prometheus 不帶帳密 up 10／10、告警規則 22 條載入 0 錯、Grafana 32 個 dashboard；17.8 兩種 webhook（default、omnibus）firing／resolved 都收到。scan-log 把 `http=000` 當可疑（`=000 `）→ EXPECTED 加 `http=000 metrics=`，重掃乾淨。
- 腳本（17-jmx-exporter.sh、19-acceptance.sh、templates/jmx-header.yml、prometheus-scrape.yml）待手冊版跑完再改。
- 第 19 章：健康 22／22，安全 15／16——19.2 還有一項「JMX exporter 匿名 → 401」（17 章改手冊時漏了）。改成「JMX exporter 不加密的 HTTP → 連不上」（http 000），19.2 照手冊原文重跑 16／16。19.3 應用程式寫讀、19.4 選單重啟與冷開機（MDS 75 s、C3 139 s）、19.5 收尾都過。
- scan-log 漏報：那行 `FAIL JMX exporter 匿名 → 401` 含 EXPECTED 的 `→ 401` 被濾掉。改成 `FAIL ` 開頭的行一律算可疑；今天 0–19 章的紀錄重掃，只有 19 章這一行。
