# 2026-11-02 腳本版（install/）簡單化＋補手冊的內容修正

- 使用者決定：install/ 全部照手冊、OP menu 的規則改寫（一行一個指令、完整 if、步驟編號），行為不變；補上手冊實跑發現的內容修正；之後用 run-customer.sh 從零實跑完整主線。C3 2.6.0 RPM 沿用落地區的檔（比照手冊 31.1）。下載 koalaman/shellcheck:v0.10.0（使用者同意）跑 lint。
- lib/*.sh、install.sh、conf/site.env 主 session 改（函式名稱與輸出不變）；steps/、lab/、tools/ 分組改寫。
- 分組改寫完成（steps 02–30、lab、tools）；lint 乾淨。實跑要看的點：27 retire 的 bindings_from_json（解除 binding N 條）、24 usage 的 awk、25-1 final_checks 與 sudo install＋tee、18 的密文 key 改 <host>.server.properties、18／19 明文檢查現在真的數 jaas、19 A／B 登入改 ! grep、21 多 7071 端點、29 順序照手冊、30.4 順序刻意和手冊不同（待決定）。
- 19 的 A／B 帳號登入原本 grep -qv 是假綠燈（有一行不含例外就算過），改成出現就算失敗。
- 手冊導覽簡報（使用者 11-02 要求，給技術主管）：docs/Confluent-手冊導覽.pptx，54 張，公司模板（IISI_PPT_Template_2026，在使用者的 Downloads，不進 repo），分安裝／維運／升級遷移三篇，圖配文字、不出現指令。guide-slides.js（內容）、guide.js（算繪）、guide-build.ps1（PowerPoint COM 填模板）。PowerPoint COM 可以匯出 PNG，這台機器其實能檢查 pptx 版面。
- 順手修手冊的圖（diagrams.js，Word 已重建，未 commit）：C3／JMX 圖的「HTTPS + basic auth」改成只用 HTTPS（10-31 定案漏改）；版本路徑圖「第 1–20 章」改第 2–19 章；約 20 處文字超框縮短。
- 主線 run-customer.sh 從零實跑（run-script-20261102-1012.log）：34 段 rc=0，第 6 段後 0 個 FAIL，驗收每次 44/44（基底、憑證換發、8.3.2、JDK 25、finalize、OS 9.8、最後），版本三次「10 台都符合」；持續流量 遷移 13762 筆遺失 0／REST 2599 失敗 0，OS 更新 3309 筆遺失 0／REST 613 失敗 0。
- 實跑抓到的改寫退化：19-acceptance consumer_finds 把 consumer 輸出存變數再比對，--timeout-ms 只在沒新訊息才到期，遷移期間 REST 持續寫 billing.events 就永遠不結束（第 18 段卡 15 分鐘）。舊版靠 | grep -q 讓 SIGPIPE 結束。改成子 shell 關 pipefail 接 grep -m 1。手動結束卡住的 consumer 後，把修好的版本 podman cp 到 ops02（不重跑）；之後的驗收都用新版，持續流量下約 3 分鐘。
- OP menu 回歸（opmenu-items-test.sh）抓到真 bug：項目 17 `local expires` 沒初值，讀不到 license 的人（bob）set -u 中止（11-01 改寫造成，舊版是 && 串接）。已修 opmenu/items/17；掃描 opmenu、install 同類寫法（scratchpad/unset-audit.js）其他都是誤報。
- 測試工具的洞：opmenu-items-test、opmenu-hostkey-test 有 FAIL 結束碼仍是 0，已改成回 1。教訓：不能只看 rc，要看「N 項失敗」。
- 主線之外（run-script-after-*.log、run-script-redeliver-*.log）：重跑 03-14 後 44/44；OP menu 回歸修好後 47/47（修前 45/47）；金鑰與 sudoers 18/18；MDS token 金鑰實驗與實際輪替（REST 失敗 9 次 401、管理 client 失敗 3 次，SCRAM 只有換 leader 的重試 WARN，和 10-23 紀錄一致）後 44/44；26 站 reset 後 44/44；照交付路徑重打包 OP menu（opmenu-20261102.6fa2b757）、重跑 16 站後 44/44。lint 乾淨，opmenu/tests 9 支過。
- 沒實跑：21 chain、21 trust-sync（主線只跑 status、leaf）。最終版 consumer_finds 是第 18 段後才送上去的，沒有以最終程式碼再從零跑一次。
- 待使用者決定：30.4 順序（腳本：每台更新加重啟、操作機最後；手冊：REST 先只更新，C3、操作機做完才重啟 REST）。
- 使用者決定（11-02）：手冊 30.4 改成腳本的順序（REST 一台做完整再換下一台 → C3 → 操作機），README 的差異拿掉。指令都是原本驗過的，只調順序；lab 已是 9.8，這個順序的手冊要等下次從零才能照打實跑（腳本版已實跑過同一順序）。
- 使用者決定（11-02）：變更分成幾個 commit，不 push。
