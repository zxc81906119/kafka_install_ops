# 2026-11-01 手冊的手動指令改成新手看得懂的寫法

- 使用者決定：全部章節（0→B，419 塊；296 塊有 >200 字的行、167 塊 &&／|| 串 4 次以上）照 OP menu 的規則改。
- 失敗停止：「先檢查、後動手」拆兩塊，看到預期輸出再做下一塊；貼上的指令裡不用 exit。run-full.sh 那邊由執行器負責：run-chapter.js 每塊前 `trap '…STOP at block N; exit 1' ERR`、塊後 `trap - ERR`（不開子 shell，變數照樣帶到下一塊）。小手冊測過：中間一行失敗會停在那塊、if 與 && 裡的失敗不算、變數帶過去。
- 驗證：分四批（0–9、10–19、20–28、29–31＋B），每批從第 0 章重建 lab 跑到該批最後一章（多數章節不能單獨重跑）。
- 第 0 章（先給使用者看）：0.0 建 machine 改成步驟＋if；Dockerfile 一個 RUN 做一件事（sshd 設定、nginx stream 區塊、lb-entrypoint 改成 heredoc 檔再 COPY；映像會多幾層、略大）；AD entrypoint 加步驟、`|| true` 改 if；0.5 CA 拆成四步、issuing.ext 用 heredoc；sign.sh 重寫（四段說明、to_win／csr_ext 小函式附例子、七個步驟、EKU 用 case）；secrets.env 用 good_password 小函式；dl01 三步；0.9 表格拿掉 && 與過時的「開機排程」「下載機沒有 restart 政策」，加「關 Windows 之前 machine stop」。
- 單獨驗過：sign.sh 新舊版對 8 種 CSR（合格 2、各種拒絕 6）輸出與結束碼相同，簽出的 extensions 相同、鏈 OK；good_password 4 例；14 塊 bash -n。還沒在 lab 從零跑（等 1–9 章改完一起跑）。
- 注意：在 Git Bash 測 openssl 要先 `export MSYS_NO_PATHCONV=1`，不然 -subj "/CN=…" 被轉成路徑。
