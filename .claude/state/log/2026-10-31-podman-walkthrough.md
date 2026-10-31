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
