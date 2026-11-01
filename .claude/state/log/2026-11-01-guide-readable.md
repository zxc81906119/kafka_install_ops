# 2026-11-01 手冊的手動指令改成新手看得懂的寫法

- 使用者決定：全部章節（0→B，419 塊；296 塊有 >200 字的行、167 塊 &&／|| 串 4 次以上）照 OP menu 的規則改。
- 失敗停止：「先檢查、後動手」拆兩塊，看到預期輸出再做下一塊；貼上的指令裡不用 exit。run-full.sh 那邊由執行器負責：run-chapter.js 每塊前 `trap '…STOP at block N; exit 1' ERR`、塊後 `trap - ERR`（不開子 shell，變數照樣帶到下一塊）。小手冊測過：中間一行失敗會停在那塊、if 與 && 裡的失敗不算、變數帶過去。
- 驗證：分四批（0–9、10–19、20–28、29–31＋B），每批從第 0 章重建 lab 跑到該批最後一章（多數章節不能單獨重跑）。
- 第 0 章（先給使用者看）：0.0 建 machine 改成步驟＋if；Dockerfile 一個 RUN 做一件事（sshd 設定、nginx stream 區塊、lb-entrypoint 改成 heredoc 檔再 COPY；映像會多幾層、略大）；AD entrypoint 加步驟、`|| true` 改 if；0.5 CA 拆成四步、issuing.ext 用 heredoc；sign.sh 重寫（四段說明、to_win／csr_ext 小函式附例子、七個步驟、EKU 用 case）；secrets.env 用 good_password 小函式；dl01 三步；0.9 表格拿掉 && 與過時的「開機排程」「下載機沒有 restart 政策」，加「關 Windows 之前 machine stop」。
- 單獨驗過：sign.sh 新舊版對 8 種 CSR（合格 2、各種拒絕 6）輸出與結束碼相同，簽出的 extensions 相同、鏈 OK；good_password 4 例；14 塊 bash -n。還沒在 lab 從零跑（等 1–9 章改完一起跑）。
- 注意：在 Git Bash 測 openssl 要先 `export MSYS_NO_PATHCONV=1`，不然 -subj "/CN=…" 被轉成路徑。
- 使用者看過第 0 章：OK，往下做（11-01）。commit 451ccc6。
- 第 1–9 章改完：1.4 加「一行一個指令、先檢查再動手拆兩塊、失敗分支最後一行 false」的讀法說明；送進容器／遠端主機的整段腳本一律 `bash -e -s <<'EOF'`（只看不改的檢查用 `bash -s`）；4.2 拆成「mountpoint」與「建金鑰」兩塊；3.4、16.3 共用的送檔塊改成 if／else（不再用 exit 0）；檢查類（sha256、jar 簽章、JDK、repodata）失敗分支印原因＋false；9.3 五項檢查拆成 cert_pubkey／cert_cn／cert_san／sorted_list／cert_eku／cert_days 小函式；lb-member.sh 重寫（新舊 status／down／up／錯誤用法輸出相同）。install/templates/java.sh 跟著改成 if（順便修正註解的章號 21→29）。
- 驗證：60 塊 bash -n 全過；lab 上只讀檢查塊（4.4、6、7.2 五塊、9.1、9.3）新舊輸出相同（9.3 目前因第 21 章換過 CA 是 MISMATCH／FAIL，新舊一致）。
