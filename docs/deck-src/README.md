# RPM 安裝流程簡報

`docs/Confluent-RPM安裝流程.pptx`（給銀行主管的 14 頁）由這裡的 `install.js` + `install-steps.js`（pptxgenjs）產生。改內容就改原始碼，不要直接改 pptx。輸出路徑一定要帶，否則會寫到 `docs/deck-src/install.pptx`。

```bash
cd docs/deck-src
npm ci
node install.js "../Confluent-RPM安裝流程.pptx"
```

# 手冊導覽簡報

`docs/Confluent-手冊導覽.pptx`（給技術主管，54 張）照手冊章節分成安裝、維運、升級遷移三篇，圖配文字、不出現指令。內容在 `guide-slides.js`；圖取自手冊的 `journey-src/diagrams.js`，圖裡的指令由 `REWORD` 換成白話（手冊的圖不變），還留著指令就中斷產生。

版型是公司模板（不進 repo）：`guide.js` 算繪圖與圖示、產生 JSON，`guide-build.ps1` 用 PowerPoint 開模板填進去，所以要在裝了 PowerPoint 的 Windows 上跑。

```bash
cd docs/deck-src
node guide.js ./guide-build
powershell -ExecutionPolicy Bypass -File guide-build.ps1 -Template <模板.pptx> -BuildDir ./guide-build -Out "../Confluent-手冊導覽.pptx" -Images
```

`-Images` 把每張匯出成 PNG 到 `guide-build/slides` 供檢查版面；文字超出內容區時會印 `OVERFLOW`。模板路徑含中文或很長時，先複製到短路徑（PowerShell 5.1 與 PowerPoint 開檔會失敗）。

# 第 32 章方案簡報

`docs/Confluent-第32章-告警方案.pptx`（給技術主管）：銀行沒有 Prometheus 時，告警走 C3 內建 Prometheus（抓 10 台的 JMX exporter、套第 17 章同一份規則）加第二個 Alertmanager。每一頁的優先序是圖 → 表 → 文字（2026-11-08 使用者定案）：能畫就畫（`c3alert-diagrams.js` 的 12 張簡報專用圖，加上手冊的 c3alert 架構圖），列清單才用表，文字卡片最多 3 張、細節放講者備忘稿；每張圖後面緊接它的實際設定或表。不靠參照手冊：每台的 JMX exporter 設定、每個 job 保留的指標都直接寫進投影片，附錄的 26 條規則全文由 `c3alert.js` 建置時讀 `install/templates/confluent-alerts.yml` 產生（規則一改，重建就同步）。內容在 `c3alert-slides.js`，設定檔節選要和手冊 17.1、17.3、32.2、32.3 一致。版型同手冊導覽（公司模板），`guide-build.ps1` 多一種 code 版面（左邊設定檔、右邊說明）。

```bash
cd docs/deck-src
node c3alert.js ./c3alert-build
powershell -ExecutionPolicy Bypass -File guide-build.ps1 -Template <模板.pptx> -BuildDir ./c3alert-build -Out "../Confluent-第32章-告警方案.pptx" -Images
```
