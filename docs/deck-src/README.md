# 簡報產生器

`docs/Confluent-離線安裝PoC-全流程.pptx` 由這裡的 `build.js`（pptxgenjs）產生。改內容就改 `build.js`，不要直接改 pptx。
實測數字（重跑驗收、驗證項數、OP menu 測試結果）放在 `numbers.json`，每次重新實測後更新。

```bash
cd docs/deck-src
npm ci
node build.js "../Confluent-離線安裝PoC-全流程.pptx"
```
