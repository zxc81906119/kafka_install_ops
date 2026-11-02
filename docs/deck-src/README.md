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
