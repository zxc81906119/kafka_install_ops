# 2026-10-29 手冊要能在沒有這個 git 專案的情況下照做（使用者提出）

## 查到的
- 建 lab 的內容沒有被刪：舊第 0 章 0.5 的 13 個指令塊在 10-28 重構時整段搬到附錄 A，逐行比對無遺失；compose.yml、四個 Dockerfile、
  sign.sh、密碼檔都用 `cat > … <<'EOF'` 寫在手冊裡。問題是位置：放在全書最後，第 1 章只在時間表提一句，讀者以為被刪了。
- 真正的 repo 依賴：16.3 打包選單要 `cd <放 opmenu/ 原始碼的目錄>`（run-full 以 sed 代換成 repo 路徑才跑得過）。
- 兩處說明文字引用 repo 路徑（第 1 章 `install/conf/site.env`、第 30 章 `install/tools/load.sh`）；另發現 29 章兩處仍寫 C3 留在 JDK 21（已改 25）。

## 定案（使用者）與做法
- 附錄 A 搬回開頭成為**第 0 章**（0.1–0.9），加概念圖 D.labbuild；全書引用 A.n → 0.n、「附錄 A」→「第 0 章」。
  run-chapter.js／run-full.sh 章號 0（"A" 為舊名別名），預設 0→B，從 0 開始才拆 lab。
- 選單改為**交付物**：`opmenu/package.sh <輸出目錄>` 產生 `opmenu-<日期>.<雜湊>.tar.gz`＋`SHA256SUMS`（不含 tests），和手冊一起交付；
  16.3 改成「複製進落地區 tools/opmenu、sha256sum -c」；run-full 實跑前呼叫 package.sh 並代換 `<交付物的目錄>`；bank-sim intake 也先打包。
- CLAUDE.md 記下原則：手冊必須在沒有 repo 時可照做。
## 待驗
- 手冊 0→B 從零實跑（第 0 章會拆掉重建 lab）驗證第 0 章與 16.3 的新寫法。
