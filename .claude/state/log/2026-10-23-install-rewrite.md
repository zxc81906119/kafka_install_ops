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
- 收尾：OP menu 回歸第 3 輪 34/35 的 6 敗查明是測試腳本 glob 在 cpadmin 展開（看不到 op01 0700 目錄），改 `sudo sh -c`，未重跑；OP menu 本身交接檔已正確寫出（0600、目錄 0700）。
  install/README.md 被 JS replace 的 $＋反引號 替換符號重複插入的 39 行已刪除、第 3 點補回。lab stop。
- OP menu 回歸重跑 37/37 全過；redesign 第 13 節、opmenu/README 補上 A／B、交接檔、17 看端點、回歸指令；redesign 憑證輪替標題改為已實作。
- install/tools/lint.sh（shellcheck＋遠端 heredoc 抽出檢查＋pipefail 下禁 `| grep -q`；沒 shellcheck 時用 docker image cp-ops:poc）。修掉：install.sh 站號字串比較（`--from 9` 一站都不跑 → 改 10# 數字比）、01／19 的 `| grep -q`、rest_app_curl 包裝、13／20 遠端片段、測試腳本的 check 字串。
  21 站 promote 也換 requests/、incoming/（否則輪替後重跑 09 判成私鑰不符；lab 的 incoming 已用現行憑證補回）。lab 重跑 09、12、13、14、17、19 0 FAIL；16＋20 → 39/39。
  發現：在 sp 模式下重跑 12／13（或 10）會把設定檔寫回明文，要接著重跑 16（20 會抓到：明文密碼 2 項）。處理方式待使用者決定。
- 使用者定案（單選）：sp 模式下重跑 10／12／13 要自動接著加密。做法：lib/render.sh 加 sp_encrypt_props（16 也改用它）、secrets_mode_in_use、protect_rendered_props；10／12／13 派送前呼叫並帶上 security.properties；遠端 unresolved 檢查不算 provider 參照；conjur 模式這幾站停下請改跑 15。
  同類問題一起修：19 之後重跑 10 會把稽核設定蓋掉 → 10 也帶 audit.rendered.tpl。
  lab（不跑 16）：10 → 滾動重啟 → 12 → 13 → 20：39/39；10 台 plaintext=0、kc/kb audit 設定都在。注意：10 重跑只寫檔不重啟（enable --now），要生效需滾動重啟。
- 第 10 站重跑：設定檔／drop-in 依 sha256 判斷有沒有變，有變且服務在跑的主機在 10.4 一台一台重啟（controller 等 active、broker 等 MDS 200）；憑證不算（p12 每次重產）。
  lab：A 不改 → 7 台 changed=no、0 重啟；B 手改 kc03、kb04 → 只重啟這兩台、設定還原；20 驗收 39/39。
- 手把手文件：新增 0.6「install/ 腳本」、第 1–21 章各加「對應腳本」框；docx 已重建（commit 652a79d）。
- 圖：往左畫的箭頭頭畫反（resvg 對 orient=auto-start-reverse），改 orient=auto；16 章 passphrase 箭頭方向改 Vault→操作機；JMX 標籤移位（commit 5d5767a）。
- master key 保管（使用者定案：兩個都存、分開兩個 object 同一個 safe）。lab 實測：generate 每次換 salt（passphrase 算不回 master key）；rotate 要 master key＋舊 passphrase。
  install：VAULT_ACCESS=api|manual；16.2 產生後先交保管（api 寫保管庫；manual 停下等 PVWA、custody 檔「雜湊 單號」），確認後才派送。manual 用隔離複本驗 4 情況；api 重跑 16 → 20 驗收 39/39。
  手把手 16：intro、16.1 開兩個變數、16.2 更正錯誤說法＋存 master key、16.6 輪替後存新 key、16.7 CyberArk 角色／擋得住擋不住／遺失怎麼辦、16.8 只加 hosts 讀權（policy 在 lab Conjur 驗 201）；壞掉的 tr -d 換行修好。redesign 加定案段。docx 待使用者關閉 Word 後重建。
- 使用者要求從第 0 章重頭驗證：lab 全刪（留 landing、images、docker image）。
- 手把手：每個 bash 指令塊上方自動標在哪台執行、換機器附 docker exec（容器→容器先 exit）；移除 21 個對應腳本框與 0.6（之後另寫腳本文件），0.6 的陷阱搬到 16.7。
- 2026-10-24：問題清單文件、升級定案（JDK 21→25 三段、C3 留 21）；寫 run-customer.sh（bank-sim pvwa-key、reset/coldboot 不需 conjur.yml、17.6 只算維運帳號的 agent、身分檔只在 conjur 檢查）；第 0 章從文件重建；開始客戶模式 8.2.4 從零。
- 客戶模式從零（CP 8.2.4，run-customer.sh）：第 20 站 38/38（20.4 選單主機項目改為人工驗收）；kb 每台 master key 檔 1、明文 0、操作機無 cpadmin 私鑰檔、17.6 過、Prometheus 9/9、冷開機 MDS 62s／C3 126s。途中修：.ssh 目錄、ops02 /tmp 是 tmpfs（docker cp 看不到→改 stdin）、bank-sim AD 冪等判斷對不上 Samba 輸出（重跑 prepare 產生新密碼檔→broker 卡在 authorizer、無錯誤訊息；已寫進手把手 14.1 陷阱）。新增 install/tools/load.sh（持續流量，自 cpctl 改寫，未實測）。
- 升級演練（lab，客戶模式）8.2.4→8.3.2（JDK21）→ JDK25 → kb04 回滾演練 → finalize 4.3：直連 14009/14009 遺失 0；REST 2/2684 失敗（402，兩次都在 controller 重啟時，試用 license）；驗收三次 38/38。發現：RPM 升級換 unit 檔要 daemon-reload；leader 會換人、每台前重查；quorum replication 的 Lag 是第 4 欄；svc-rest 要加 _confluent-command ResourceOwner；JDK25 Unsafe 警告；4.3 一併開 share/ELR/streams。修：05 站與手把手第 5 章挑 JDK 用 sort -V（bank/ 有兩版時原本挑到舊的）。
- 驗證 A（文件）：客戶模式從零 8.2.4（53 分，38/38）→ 照手把手第 22 章 13 塊（22.9 回滾移到 finalize 前、加 kb04 升回）全部 rc=0 → 驗收 38/38。文件修：22.1 預期輸出少已安裝那行、JDK 21 版本號改 21.0.x。22-upgrade.sh 加 ONLY_HOSTS（回滾後單台升回）。
- 使用者要用記憶體：中斷驗證 B（packages 中途）、停容器、關 Docker Desktop、wsl --shutdown。審查 23 項已修（d7f4c31），待全書實跑驗證。
- 2026-10-24 夜：run-upgrade-drill.sh（新）全流程通過：客戶模式 8.2.4 → 22-upgrade.sh plan/backup/packages（驗收 38/38）/jdk 25（38/38）/rollback kb04/ONLY_HOSTS 升回/finalize 不帶確認停下、帶確認升版（38/38）；直連 7367/7367 遺失 0、REST 1/1360（402，controller 期間）。
