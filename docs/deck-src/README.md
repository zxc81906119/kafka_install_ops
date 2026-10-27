# RPM 安裝流程簡報

`docs/Confluent-RPM安裝流程.pptx`（給銀行主管的 14 頁）由這裡的 `install.js` + `install-steps.js`（pptxgenjs）產生。改內容就改原始碼，不要直接改 pptx。輸出路徑一定要帶，否則會寫到 `docs/deck-src/install.pptx`。

```bash
cd docs/deck-src
npm ci
node install.js "../Confluent-RPM安裝流程.pptx"
```
