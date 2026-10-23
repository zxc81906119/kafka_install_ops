# 2026-10-23 — 安裝腳本重寫（install/）

- 使用者定案（單選題）：涵蓋核心第 1–13 章；新建 `install/`，`installer/`（cpctl）保留做對照；驗證＝lab `down -v` 從零只靠新腳本裝起來。
- 設計：一章一支 `steps/NN-<章名>.sh`（01 在下載機跑，02–14 在操作機 cpadmin 跑）；共用只有 `lib/ssh.sh`（rsh/rcp/each）、`lib/render.sh`（envsubst 指定變數）、`lib/log.sh`（log/ok/fail/bank/pending/finish）；
  站點設定單一檔 `conf/site.env`；範本 `templates/*.tpl` 直接取自手把手第 10、12、13 章；銀行步驟用 `bank` 印「請銀行做」再驗證，沒做完 rc 2，`install.sh` 停下提示重跑。
- lab 專用：`install/lab/bank-sim.sh`（Windows Git Bash 扮演銀行：2.2 交換、3.x 準備、9.2 簽發）與 `install/lab/run-all.sh`（從零到第 14 章的全自動驗證）。
- 從零驗證通過（`install/lab/run-all.sh`，lab `down -v` 起算 24 分鐘，0 FAIL／0 WARN）：01 在 dl01（檔案已在落地區，dnf SKIPPED）→ 02–03 停等銀行（rc 2）→ bank-sim prepare → 03–09 停等銀行 → bank-sim sign → 09–14 全 ok：
  quorum leader 1、4 observer、MDS 4×200、alice SystemAdmin／carol DeveloperRead、REST 200/401/000、LB 200、C3 UI 50 秒、Prometheus 124 種指標。
- 寫腳本時修掉的坑：step 11 的 `| while read` 子 shell 會把 fail 計數丟掉（改 `done < <(…)`）；step 05 用 sudo install 放 /tmp/java.sh 後 cpadmin 刪不掉；step 08 versionlock 計數比對取錯欄位；render 檢查 `${…}` 的 regex 漏了含數字的變數名（C3_FQDN）。
- 冪等重跑驗證通過（同一 lab `install.sh --from 02` 到 14：0 FAIL、0 WARN 除第 6 站刻意的「不是全新主機」）。重跑才會出現、已修：
  第 4 站 `dnf list available` 在已裝主機只剩沒裝的套件 → 改 `repoquery`；第 8 站 `versionlock add` 對已鎖套件會加重複行 → 先查清單再加（手把手第 8 站的指令也有同樣行為，14.2「裝套件可重跑」那列待補一句，docx 未重建）。
  格式化、CSR、mds-token、密碼檔、cluster id 都正確略過；服務 restart 後 quorum／MDS／REST／C3 全部回 200。
- 收尾：journey 14.2 補 versionlock 重跑註記、docx 重建；lab 全部 stop。
- 16.9（AD 查詢密碼改 Summon 注入 + Kafka 內建 EnvVarConfigProvider）在 lab 實跑通過並併入 journey（docx 重建）；redesign 第 11 節補實作結果與「密碼放法決策樹」三題。
  lab 準備：15.1–15.2（Conjur、policy、host key、值）+ 全部第 16 章（含 16.8 Summon）用 run-chapter.js 部分重跑；install/ 不產生 ~/conf/*.tpl，16.3 需要時先把第 10/12/13 章的 heredoc 範本放回去。
  踩到：`confluent secret` 改寫後 properties 是 `key = value`，sed 要容許空白；alice 登入 200 證明不了 bind 可用（群組快取），要用「重啟後建 topic」這種需要群組查詢的動作。
- 下一個：install/ 延伸站 15–19 與驗收 20（主線驗 16+16.8+16.9、17、18、19、20；15 單獨驗）。
- 決定（使用者單選題）：客戶 CyberArk 只用在 PSM／PSMP 代登與 SSH 金鑰輪替，**沒有 CCP／CP／Conjur**。cpadmin 私鑰改為「人工從 PVWA 取、貼進 ssh-agent、不落地」；OP menu 維運期同一做法（lib/secrets/manual.sh）。
  連帶：第 16 站 master key 只能 16.4 落地 service.env（人工從 PVWA 取）；Summon、16.9 不適用；AD／SCRAM 密碼照銀行現行方式人工交付。redesign 第 11 節、第 12 節已更新。
- 可讀性整理（commit c03b222）：完整命名、每檔每段註解、遠端指令一律 ssh_script heredoc、衍生值集中 site.env、rolling_restart；不用 python（19 站、15 站 jar、bank-sim 改 grep／sed）；README 加「寫法約定」。
- 從零驗證到第 20 站通過（39/39）。途中修掉：16 站 16.9 要先把 ldap-bind-password 寫進保管庫（Summon 有一個變數取不到就整個失敗）；20 站 SCRAM app 讀回要用 app 自己 prefix 的 consumer group（orders-acceptance）。
  行內 Prometheus 9/9 up、9 rules；冷開機 broker 74s、C3 138s、broker 重試 1 次。
- OP menu：manual 來源改成「第一次做主機類項目、過權限閘門後才取私鑰」（OPMENU_SSH_KEY_LOAD=auto）；ccp.sh 改 sed 不用 python；三個單元測試通過。
- 查證：MDS token 私鑰的 passphrase 參數不在 Confluent 8.3 文件（未文件化）→ 不建議正式環境採用，列入給原廠的問題。MDS token 金鑰輪替方案待 lab 實驗。
- MDS token 金鑰輪替 lab 實測：公鑰檔放兩把只認第一把 → 無法零中斷；整套輪替 196 秒，REST 失敗 7/100（約 30 秒）、管理 client 3/20、SCRAM 0 失敗。lab 的 MDS 金鑰已換成新的（ops02 ~/pki 正本已更新，舊的留 .old）。腳本 install/lab/mds-token-key-*.sh，結論寫進 redesign 第 11 節。
- OP menu 新版打包 opmenu-20261023.42f62e71（含 manual、要用才取），lab 落地區已換、第 17 站重裝通過；人工模式實測 12/12（install/lab/opmenu-manual-test.sh，用 script 模擬終端機貼上）。
- conjur 模式驗證：第 15 站通過、第 19 站（conjur 分支）通過、第 20 站 38/38。途中修：install.sh --only 不再跳過 where 檢查；明文密碼判斷集中到 lib/render.sh 的 count_plaintext_passwords（jaas 行只看 password="…"）。
- OP menu 緊急主機模式（使用者單選題定案）：MDS 連不上時 opmenu-emergency 群組的人只能做 16 18 21 22 23，必填原因、標成未經 AD 驗證；derive 拆成 derive（要 MDS）＋ derive_local（ssh 允許主機清單）。
  lab 實測 14/14（install/lab/opmenu-emergency-test.sh）。OP menu 新包 opmenu-20261023.e1b6b24d。redesign 第 13 節、opmenu/README 已更新。
- lab 切回 Secret Protection＋Summon＋16.9（客戶的模式）：16、19、20 重跑 0 FAIL，驗收 39/39。修：「先 19 再重跑 16」時 16 沒把 AUDIT_PASSWORD 帶進稽核片段（正式環境換密碼重跑 16 會遇到）。
