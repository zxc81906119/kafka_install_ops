# 2026-10-21 — 手把手文件與專案設定

- 新增 `docs/journey-src/`（journey.md + diagrams.js + build.js，docx-js + resvg）→ `docs/Confluent-安裝旅程-手把手.docx`。
  故事主角「小安」；每步有角色標籤（我方／銀行）、一行指令、預期輸出；11 張圖。
- 使用者要求不依賴專案：第 0.5 章改為在 `~/kafka-lab` 用 heredoc 建 Dockerfile、compose、Samba AD、nginx、
  openssl 兩層 CA 與 `sign.sh`；JDK 由下載機從 Adoptium 抓當「銀行交付」；`/opt/java/current` 符號連結。
  **尚未從零實跑驗證。**
- 建立 `CLAUDE.md` 與 skills：build-docs、lab、bank-role、manual-step、redesign-notes。
- 建立 `.claude/state/`（status-<branch>.md、log/）作為跨 session／branch／worktree 的交接機制。
- 丟棄 `simplify-installer` branch 與其 stash（攤平版 step 05 樣板）：使用者決定不需要，新腳本改以手動實跑為依據。
- 2026-10-21 自檢手把手文件：補名詞小抄、檔案位置、時間預估、0.5.9 收工與重開、14.1 出問題先看哪裡、14.2 做錯怎麼重來；修正 3.1 root 進 ops02、3.2/第 4 站/1.3 會誤判的預期輸出。第 0 章自建環境仍未從零實跑。
- 2026-10-21 第 0 章從零實跑（`~/kafka-lab`，scratchpad `ch0.sh`）：10 個區塊全部通過。修了兩件事並寫回 journey.md：
  (1) Git Bash 的 openssl 是 Windows 原生程式，`sign.sh` 收到 `/c/Users/...` 會靜靜失敗 → 腳本內用 `cygpath -m` 轉路徑；
  (2) 網段與別的 compose 專案重疊（`Pool overlaps`）→ 改 172.35/172.36，並在 0.5.6、14.3 加陷阱說明。
  lb01 第一次 `up -d` 只起 13 台，再 `up -d` 一次即可。第 1–3 章實跑中（`ch123.sh`）。
- 2026-10-22 凌晨：第 1–14 章全部從零實跑通過（scratchpad 執行器 ch123.sh、ch5-14.sh、ch9-14.sh：每個 ```bash 區塊依 @role 的主機／身分執行，同主機連續區塊共用一個 shell）。
  文件修正：3.1 ssh 測試清單加 ops02（否則第 5 站 `ssh ops02` 會 Host key verification failed）；5 站變數寫 `~/jdk/jdk.env` 再 source；
  9.2 簽好的憑證放 `ca/exchange/signed/`（原本會把第 3 站的 ad01 憑證一起撿進 incoming，7 變 8）；4 站／10.2 的 dnf install 加 -q、>/dev/null；
  0.5.6 補「13 台時再 up -d 一次」；多處預期輸出改成實跑結果（版本清單、cyrus-sasl 兩行、port 排序、行數、topic 清單、metrics 數）。
  docx 已重建。lab：`lab` 專案 14 台 + dl01 全部在跑、叢集健康（REST via LB 200、C3 200）。
