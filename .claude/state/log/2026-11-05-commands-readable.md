# 2026-11-05 指令可讀性整理

- 使用者要求開跑前先檢查所有指令是否新手能快速上手，重點是可維護性高。
- 定案（使用者選）：手冊拿掉函式、直接寫指令（寧可重複）；範圍手冊、install、opmenu 全部；改完從零全跑手冊與腳本版。
- 規則：docs/journey-src/tools/COMMAND-STYLE.md；檢查：docs/journey-src/tools/lint-commands.js。腳本可保留函式；手冊寫到磁碟的交付腳本可保留函式。
- 不用 jq：主機沒裝，也不在銀行需求清單（只在 lab 的 OS 套件庫）。JSON 用 grep -o + cut。
- 基準：手冊 742 筆、install 490 筆、opmenu 165 筆（lint 初版，含誤判與套件清單）。
- 2026-11-05：手冊已改完合併（lint 0；bash 434→461 塊；函式只留寫到磁碟的 9 支腳本；全本 bash -n 通過，未實跑）。
- 改寫前快照：scratchpad/before-readable/sources.tar（journey.md、install、opmenu）。全部改動都還沒 commit。
- 使用者要關機出門。續做順序：1) node docs/journey-src/tools/lint-commands.js --summary 看 install 第 21–32 站與 opmenu 剩多少，補完，opmenu 跑 tests；2) 更新 redesign/README.md 舊規則（「包成小函式」已不適用）與 CLAUDE.md 指向 COMMAND-STYLE.md；3) 從零全跑手冊，比對 log（特別看 C3 登入、第 21 章 podman exec -i 經 Git Bash 的 stdin、第 32 章分流、run-customer.sh:85）；4) 腳本版全跑；5) 重建 docx。改寫前快照在 scratchpad/before-readable/sources.tar（暫存目錄，可能被清）。全部未 commit。
- 2026-11-06 手冊從零全跑（run-customer-0-end-20261105-2302.log）：461 塊，rc=0 449、略過 12、失敗 0；scan-log 沒有可疑輸出。第 19 章健康 22/22、安全 17/17；alice 從 C3 登入每次都是 200；第 32 章 OPEN／RESOLVED 全字串、分流正確（第二台只有 C3RestProxyDown、C3 trigger 只進內建）。out 比對（遮掉日期、版本、序號、耗時）剩 36 塊差異，都是正常變動或 26.4 略過；只有 16.6 的 out 是舊的選單紀錄，已改。中途因 Minecraft 等程式讓 commit 只剩 1.3 GB，podman pause lab-ops02-1 暫停、使用者關掉程式後 unpause 接著跑，沒有影響。
- 2026-11-06 腳本版：第 1–13 段通過；第 14 段 WSL 半卡住（實體記憶體 0.4 GB，wsl.exe 進不了 distro，compose 失效）→ 使用者同意 wsl --shutdown → FROM=14；冷開機 MDS 95 s、C3 128 s；基底與遷移後驗收 45/45 共 5 次。第 31 段第一次失敗：10:29:46 四台 broker 同時 heartbeat timeout（VM 頓住），之後 kc03 上的 Self-Balancing 狀態壞掉（IllegalStateException: Replica metrics have more windows than partition metrics），kafka-remove-brokers 一律 RebalancePlanComputationException；重啟 Self-Balancing 所在的 controller（kc03）、等 7 分鐘後重跑就成功，搬回 kb04 約 20 分鐘。第 32 段（OS 9.8）進行到 kb02 時使用者要求停止（又開了 Minecraft、IntelliJ、Chrome，commit 1.8 GB）。剩 FROM=32。
- 文件自檢（使用者要求）：手冊導覽簡報補第 32 章（55 張）、章數 34、C3 svc-c3 與第 32 章例外、緊急模式 svc-ops、AD 群組限制；RPM 簡報驗收 45；diagrams 總覽 20–32、OP menu 圖 svc-ops；install/opmenu/tools README、CLAUDE.md 章號與新規則連結。全部重建。舊的 CyberArk 設計 docx 未動（使用者選）。
- 2026-11-06 腳本版 FROM=32 跑完（結束碼 0、FAIL 0）：OS 9.8 逐台更新期間 REST 經 LB 401 次失敗 0；OS 9.8 後驗收 45/45、10 台都是 OS 9.8／8.3.2／C3 2.6.1／JDK 25；31 章 C3 2.6.0 退回再升回；32 章分流（第二台只有 Chapter32WithTarget、內建只有 Chapter32NoTarget）、omnibus 10 個欄位全字串；最後驗收 45/45。指令可讀性整理至此手冊與腳本都驗證完畢，等使用者決定 commit。
