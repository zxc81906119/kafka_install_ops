# 手動安裝手冊產生器

`docs/Confluent-手動安裝手冊.docx` 由 `guide.md` 經 `build.js`（docx）產生。改內容就改 `guide.md`，不要直接改 docx。

`guide.md` 用的是 Markdown 的子集：`#`～`###` 標題、段落、`- ` 清單、`1. ` 編號、` ``` ` 程式碼區塊（可在清單內縮排）、`|` 表格（儲存格內的直線寫成 `\|`）、`> ` 說明框、`>! ` 或以「注意」開頭的警告框、行內 `` `code` `` 與 `**粗體**`。檔頭的 `<!--meta ... -->` 是封面資料（JSON），`[[toc]]` 放目錄。

```bash
cd docs/manual-src
npm ci
node build.js
```

## 實測紀錄

手冊經過一次「從零全程手動」實測(附錄 A.1),紀錄在 `transcripts/`:

- `01-download.log`(外網下載機)、`02-ops02.log`(操作機):每條指令、輸出與結束碼;不含任何密碼值。
- `cmd-*.txt`:各段實際執行的指令(由 `run.sh` 逐條執行並記錄;`{{ ... }}` 是一個多行指令)。
- `gen-*.sh`:照手冊 4.2.3、5.2 寫設定檔的腳本(密碼在執行時從操作機的 0600 密碼檔讀入)。

實測環境是另一套模擬主機:`docker compose -f docker/manual/compose.yml up -d`(專案 `cp-man`,操作機 ops02 為裸機)。AD 管理者密碼放在 `docker/manual/secrets.env`(不進版控),落地區是 `packages-manual/`(不進版控)。它和 cpctl 的 `cp-poc` 使用相同主機名稱,16 GB 的電腦上一次只跑一套。

## 版面

產生後用 Word 開啟時，目錄需要更新一次（Word 會詢問是否更新欄位；或在目錄上按右鍵 → 更新功能變數）。`render.ps1` 會用 Word 更新目錄並匯出 PDF，方便檢查版面。
