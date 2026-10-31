# 2026-10-31 Podman 上照手冊逐章從零跑（每章自檢內容是否符合最終設計）

- 環境：Podman machine kafka-lab（rootful、WSL2 11 GB）；labtest 已刪；Docker Desktop 關閉。
- 第 0 章：13 塊（10 rc=0、3 略過），0.0 新節照原文通過。自檢：CyberArk、/secure/ssh、cpuser／sudo、9.6 凍結都符合。修：0.1 前提改「0.0 已做完」；labbuild 圖加 0.0 那一層。待驗：0.6 lb01 對應 Windows 18082／19021（Podman 是否轉埠，第 12、13 章測）。
- 第 1 章（無指令）自檢：版本路徑表的章號是舊的（1–20／21、26、27 → 2–19／29、30、31）；時間表 22、24、27、28 還寫「待補」（填 lab 實測）；名詞小抄 mTLS 說 Prometheus 用 mTLS（7071 已改 HTTPS only）。已改。
