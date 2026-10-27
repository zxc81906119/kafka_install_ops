# RPM 安裝流程簡報

`docs/Confluent-RPM安裝流程.pptx`（給銀行主管的 14 頁）由這裡的 `install.js` + `install-steps.js`（pptxgenjs）產生。改內容就改原始碼，不要直接改 pptx。輸出路徑一定要帶，否則會寫到 `docs/deck-src/install.pptx`。

```bash
cd docs/deck-src
npm ci
node install.js "../Confluent-RPM安裝流程.pptx"
```

## 客戶資訊整理簡報

`docs/Confluent-Kafka客戶資訊整理.pptx`（16 頁，圖多字少）由 `customer-info.js` 產生，是桌面草稿「整理 kafka 客戶資訊」重新分析後的版本（修正對照在最後一頁）。

```bash
cd docs/deck-src
node customer-info.js "../Confluent-Kafka客戶資訊整理.pptx"
```
