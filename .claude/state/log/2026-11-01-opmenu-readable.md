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
- 使用者確認風格 OK（11-01），出門前關機；下次實作其餘 26 項。machine 已由 Claude 停掉。
- 關機前 podman machine stop 後 kafka-lab-api.sock 仍在（win-sshproxy 可能早就被 Claude 的工具一起結束），已手動刪除。

## 其餘 26 項改寫完成（11-01 下午）
- 10–19、22、23、27、31–38、41–44、91 全部照規則改寫：開頭四段註解、步驟編號、完整 if、段落空行；長的 awk 包成 _item<編號>_xxx 小函式並附輸入／輸出例子（10、13、33、44）；34 拆成建帳號／綁權限／回滾三個小函式（取代 break 2）；38、91 的字串切割改 cut／tr；44 的 CSV 筆數改用檔案行數算（取代 process substitution 裡累加），快照各檔的 awk／sed／sort 一字不改（要和每日備份 sha256 相同，待 lab 比對）。
- 語法 27/27、7 支測試全過；項目裡已沒有 eval、&& {、<<<、${x%…}。
- 使用者提議（11-01）：手冊的手動指令之後也照同樣規則改，讓安裝與維運人員更好做事。等 OP menu 做完再討論範圍（400 多個指令塊，每章都要 lab 重跑）。
- common.sh 全部改完：紀錄、交接檔、確認、v_*（多行的 v_match／v_in／v_topic／v_offset_to）、清理（pid 改用 cut、拆出 _process_alive）、token 換新、選單可見性、兩個閘門共用 _core_authorize、並行鎖、變更時窗（拆出 _minutes_of，用 heredoc 讀每個時段）。先寫 tests/test-change-window.sh（19 例）與 test-lock.sh（7 例）對舊版跑過確認案例正確，改完新版同樣全過；9 支測試全過。
- lib 全部改完：defaults.sh 的 d／dd／_hosts_of 與兩段推算（新舊版 65 個設定值與來源逐一比對相同）、secrets/file.sh、hosts.sh（送到主機的遠端指令字串一字不改，test-sudo-forms 過）、kafka.sh（_curl_q 改 sed，" 與 \ 跳脫結果相同）、opmenu.sh 的載入／login／emergency_login／derive。OP menu 本身已沒有 eval；9 支測試全過。待 lab 逐項實跑。

## lab 比對新舊版（11-01 晚，ops02：舊 /opt/opmenu、新 /root/opmenu-new）
- 唯讀項目 alice 各跑一次、正規化時間後比對：10、12、13、14、15、16、17、19、23、41、43、44（CSV）完全相同；11 只差 HighWatermark（叢集持續增加的計數，正常）。44 的 CSV 新舊 sha256 相同。比對腳本在 scratchpad/opmenu-compare.sh（ops02 沒有 diff／cmp，改用 sha256＋awk 列出不同的行）。
- 還沒做（下次）：變更類項目實跑（31 建 → 32 改 retention → 33 刪；34 建帳號 → 38 配額 → 35 輪替 → 37 下架；42 加／移除權限；36 重設 offset；22 重啟 REST；27 滾動重啟；91 緊急模式）；44 snapshot 和每日備份 sha256 比對（手冊 23.5）；全部過了再更新交付物（package.sh）與 /opt/opmenu。
- 之後：使用者想把手冊的手動指令也改成同樣寫法，OP menu 做完再討論範圍。
