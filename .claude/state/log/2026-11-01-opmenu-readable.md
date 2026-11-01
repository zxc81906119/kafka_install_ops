# 2026-11-01 OP menu 改成新手看得懂的寫法（第一步：框架＋第 21 項）

- 使用者先問 OP menu 的設計與實作評價（優點：分層、權限交給 Kafka、失敗即拒絕、輸入白名單、機敏資料不上命令列；風險：43 稽核從頭讀 90 天、AD 密碼含 " 或 \ 會壞 JAAS（推論未測）、靠解析 CLI 文字輸出、每個動作開 JVM、bash 1,700 行可維護性）。
- 使用者決定：可維護性優先，寫給不熟 shell 的人（規則記在 redesign/README.md 最後一節）。範圍先 OP menu；先改框架＋21 給使用者看。
- 做了：
  - items/menu.list 選單對照表（27 項，檔頭有欄位說明）；項目檔的 item 行搬進表、run() 改名 run_<編號>（其他 26 項內容不動）。
  - common.sh：load_items 改讀對照表（沒有 eval）；_core_run 照步驟 1–8 改寫、結果判斷拆成 core_log_result；拿掉 core_guard_host_actions（eval 裝飾器），改成 hosts.sh 四個碰主機的函式開頭自己呼叫 core_host_gate。
  - hosts.sh：be_service_restart 改新寫法；opmenu.sh：show_menu／menu／list_items／print_visible_items／main 改新寫法。
  - items/21-restart-broker.sh 全部改寫（開頭四段註解、步驟 1–5）。
  - tests：act_ → run_；test-host-gate 改用真的 hosts.sh、只假 _ssh；test-sudo-forms 設 OP_HOST_OK=1。7 支全過。
  - README 的結構表與寫法規則更新。
- lab 實測（新版放 ops02 /root/opmenu-new，/opt/opmenu 沒動）：--list 27 項、alice --run menu 27 個編號、bob 12、alice／bob 21 重啟 kb04（檢查→確認→active）、不在清單的主機被拒；紀錄 OK／FAIL 正確。
- 注意：在 ops02 上用 heredoc 餵多個指令時，ssh 會吃掉後面的 stdin；選單呼叫要 </dev/null。
- 下一步：使用者看過 21 的風格後，再改其餘 26 項與 lib 的其他函式；改完更新交付物（package.sh）與手冊 16 章的 out（若有變）。
- 使用者（11-01）：不相關的行之間要有空白行。21、load_items、core_run／_core_run、core_log_result、be_service_restart、show_menu／menu／main 已加；規則補進 redesign 與 opmenu README；7 支測試全過。
