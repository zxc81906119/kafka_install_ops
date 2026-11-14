# 2026-11-12 Demo 手冊與展示環境收尾

- 使用者定案：CBOMkit 平台＋web app＋它的 Jenkins 是「為了報告簡報所產生的」一整組展示環境；Kafka lab 只包含 CP 的 CBOM＋OPA。CP 的 Jenkinsfile 拿掉 `CBOMKIT_URL`（手冊本來就沒提 CBOMkit 平台）。
- 使用者要求：簡報當天要能順利 demo → 出一本 demo 手冊（指令、結果、截圖），指令要新人看得懂。
- 做了：
  - `docs/Cbom-Demo手冊.docx`（來源 `docs/demo-src/demo.md`；`node docs/journey-src/build.js ../demo-src/demo.md "../Cbom-Demo手冊.docx"`，在 journey-src 底下執行）。build.js 加了 `![images/x.png]`（PNG 截圖），章號齊全的檢查只套用在手把手。
  - 截圖：`node docs/demo-src/tools/shots.mjs <紅色那次> <黃色那次>`（無頭 Chrome；Jenkins 用基本認證標頭，密碼只讀檔）。CBOMkit 掃描那幾張沿用簡報的圖（數字實測相同：142 筆／84 個）。
  - 對照表：`node docs/demo-src/tools/compare.mjs <findings.json>`：同一份上傳的 CBOM（159 個）在 pipeline、CBOMkit＋OPA、CBOMkit 內建的判定。發現 `cbomkit-demo/policy/names.rego` 不認得 Java 的寫法 ARCFOUR、PBEWithMD5AndDES、SHA（判成 Quantum Safe，pipeline 判違規）；還沒修，手冊第 6 章照實寫。
  - `demo.sh`：改成 COMMAND-STYLE 的寫法（lint 0）；`down` 會把 cbom-jenkins 停下來（只停不刪）。README 過時的說法（只掃已 commit、git checkout 還原規則、untitled9 的路徑）改掉。
  - `install/lab/lab-power.sh`：stop 原本一個一個停要 7 分鐘，改成照啟動的相反順序一組一組同時停。
  - `cbom/build.sh` 在臨時容器建（映像 jenkins LTS jdk21、volume `cbom-build`）：實測通過；`cbom/golden.sh check` 八個檔都和基準相同。dl01 的快取用 `podman machine ssh` 裡的 tar 管線搬（`podman cp` 容器對容器 4 小時只搬 520K，不能用）。新 jar sha256 b5db71c9…（位元組和 dl01 建的不同，產出相同）。
- 實測數字（展示流程）：demo.sh up --jenkins 23 秒；scan 25 秒；reload 20 秒；cbom-webapp #3（關卡開）3 分 26 秒 FAILURE 違規 21；#4（執行期＋關卡關＋上傳）3 分 48 秒 UNSTABLE 違規 36、上傳 159 個（網頁顯示 270 筆）。
- 沒做：docx 的版面沒辦法在這台機器預覽；policy 目錄還沒進 git，所以規則還原是手動改回（手冊這樣寫）。

- 2026-11-13 使用者：Rego 規則要讓沒學過的人也能上手，改不了至少註解要清楚（判斷什麼、判成什麼）。
  - `cbom/policy/cbom.rego`：開頭加「一條規則怎麼讀」「常見的修改」；分十節；每條規則上面兩行「判定／條件」；重複的兩行條件收成 `keyed_assets`、`certificates`、`protocols` 三個分組。判定沒變：`opa test` 28/28、`golden.sh check` 八個相同。ops02、兩台 Jenkins 上放的還是舊檔（只差註解與寫法，結果相同），下次重放交付物時會換。
  - `cbom/cbomkit-demo/policy/quantum_safe.rego`、`names.rego`：只加註解（開頭的判斷順序表、四種結果與顏色、每條的編號、regex 符號說明），拿掉註解後程式碼和原本逐字相同；測試 12/12。BROKEN 那一行從第 58 行變第 91 行，Demo 手冊已改。
  - 這天 podman machine 是停的（電腦關過機），已 `podman machine start`；出現 win-sshproxy failed（podman 可用、podman compose 不能用，處理方式見 CLAUDE.md）。

- 2026-11-13 使用者要求用同一標準自檢 Java、腳本、web app、pipeline，之後選「四項都修、現在就做」；另外強調 shell 要照 COMMAND-STYLE、不同組之間空一行（lint 不檢查空行，靠人讀）。
  - 自檢（三個唯讀助手，約 7,300 行）：Java 22 檔 好懂 8／尚可 10／難懂 4；腳本與 pipeline 16 檔 4／9／3；web app 最弱（約 60 處密碼學用法沒標好壞、指向不存在的 EXTENDING.md）。
  - Java（cbom/tools）：全部檔頭與方法補註解；Algo.describe、TheiaAdapter.addTheia、ReportCommand.render、JdkSettingsLayer.javaSecurity 拆成小方法；刪 Cdx.byRef 與一個沒人用的多載；Algo 與 ReportCommand 檔頭加「怎麼改」。產出不變：build 成功、golden 八個相同（新 jar sha256 affede25…）。
  - 腳本與 pipeline：補註解與分組空行；行為修正＝package.sh 去掉 &&、demo.sh 等資料庫最多 60 秒、build.sh 也比對 Maven 版本、cbom-collect.sh 新增 note_failure（取 jar、syft、TLS 沒結果、kafka-configs、ssh 金鑰、JFR 失敗記一筆，最後回 2；--from-ssh 也會回 2，Jenkins 的收集 stage 會變紅）。golden.sh 把 volume 裡的 run.sh 併進腳本，檔頭寫「沒有原料時怎麼建」。lint 全部 0 筆。
  - web app（cbom/app）：只改註解。四種標記 [好例子]／[可接受·量子脆弱]／[舊做法]／[壞例子·故意]；75 處標「標準答案 id＋pipeline 判定」；新增 cbom/app/README.md（含怎麼加一個新例子）；14 處待確認已用實際報告填完。一行程式變更：CryptoLabInventoryConsistencyTest 的失敗訊息改指 README.md。
  - 驗證：展示流程用最終版重跑（scan 84 個、17／16／9／42；cbom-webapp #1 FAILURE 違規 21、#2 UNSTABLE 違規 36、上傳後三方對照表逐列相同）；畫面重截（shots.mjs 現在多拍 cbomkit-overview、cbomkit-list、report-webapp-violations），Demo 手冊重建。CP：run-full.sh customer 33 33 → 26 塊 rc=0（run-customer-33-33-20261113-1032.log），Jenkins cbom 兩次 SUCCESS（健康環境沒有誤判失敗）；故意把 ADMIN_CLIENT_CONF 指到不存在的檔 → 列出失敗步驟、結束碼 2。
  - 待使用者決定：報告文字「共 N 個密碼學資產」（N 含 file、library）與寫死的 X25519MLKEM768、等級用詞和 rego 不一致（改了要 rebase 基準）；函式庫位置寫死 /usr/share/java（web app 不對）；Main 的 --spec 重複時行為略變；cbomkit-demo 的 names.rego 不認得 ARCFOUR 等三個名稱；lint 要不要加分組空行的檢查；簡報 pptx 裡的 CBOMkit 清單截圖行號是舊的。
  - lab 現況：Kafka lab 在跑（15 個容器，CP 8.3.2，/opt/cbom 是今天的交付物）；展示環境已收掉（cbom-jenkins 停著，有 #1、#2 兩次紀錄）；podman machine 啟動時 win-sshproxy failed（podman compose 不能用，還沒處理）。

- 2026-11-13 晚 使用者：先不管寫法，只管 CBOM 做法的正確與合理；選了六項全做（判定漏掉的壞例子、web app 可重現的對答案、CP 完整性檢查、主機端收集失敗要抓得到、報告加「看不到什麼」、版本部署一致）。先前選的用詞／簡報／手冊文字更新先擱置。
  - 規則：`ecb-mode`（區塊加密用 ECB＝違規，RSA/ECB 不算）、`rsa-pkcs1-encryption`（RSA＋pke＋PKCS1 填充＝違規；依據 SP 800-131A Rev.2，從搜尋摘要確認，PDF 原文沒讀到）。元件新屬性 `cbom:mode`、`cbom:padding`。規則測試 37/37。
  - `cbom-tools.jar check-inventory <cbom> <findings> <expected> <輸出>`；`cbom/app/expected-inventory.json` 每項有 `expectedLevel`（含 `not-detectable`）；`cbom-report.sh inventory`；web app Jenkinsfile 多一個 stage「對答案」（不影響結果），產出 `out/inventory-check.txt`。
  - **更正涵蓋率：45／49，不是 46／49**。先前的第 46 項（KEM-RSA-PKCS1）是比對條件誤配到 RSA PKCS#1 簽章；原始碼掃描把 PKCS1Padding 的呼叫點回報成 RSA-2048（沒有 padding），JFR 也沒錄到，所以改列 not-detectable（看不到的共 4 項：PWD-BCRYPT、PWD-ARGON2、JWT-NONE、KEM-RSA-PKCS1）。另外收窄 5 項的 match（SHA-256、SHA-512、AES-GCM、ChaCha20、ECDSA）。實跑：找到 45、等級相符 45、不符 0。
  - 完整性檢查：`CollectionCheck`＋`BomSteps.COMPLETENESS`，CBOM 多一個 type=data 的元件「盤點完整性檢查」（`cbom:gap`）；規則 `collection-gap`（無法判斷）／`collection-complete`（通過）。固定原料與真實 CP、web app 都是 0 個缺口。
  - 主機端步驟：`<主機>/steps.done`（1、2、3、4、4b、5），少一步就 note_failure → 結束碼 2。反向測試：暫時移開 rest02 的 java.security → 「rest02 的收集步驟 4 沒有完成」、結束碼 2；已還原。
  - 報告多「盤點完整性」與「這份盤點看不到什麼」（Profile.blindSpots）。
  - 實跑：cbom-webapp #1 FAILURE 違規 22（多了 AES-ECB）、#2 UNSTABLE 違規 37；CP run-full 33 33 → 26 塊 rc=0（run-customer-33-33-20261113-2307.log），Jenkins cbom 兩次 SUCCESS，151 個元件、違規 0、量子脆弱 69、警告 3、無法判斷 0。基準已 rebase。兩邊部署的都是現在的版本。
  - 途中：machine 重啟後 lab-jenkins 的主機 port 轉送壞了（容器內 200、主機 000），`podman restart lab-jenkins` 就好。
  - 查證：cbomkit-action README＝引擎是 Sonar Cryptography、建議先建置（`CBOMKIT_JAVA_REQUIRE_BUILD` 預設 true）；CBOMkit README＝平台不建置，自己說會降低完整性與準確度，建議把 cbomkit-action 放進會建置的 pipeline。
  - **還沒跟上的（使用者說先不管）**：手冊第 33 章的文字與 out（元件數多 data=1、等級用詞、新的報告段落）、Demo 手冊的數字（違規 21／36 → 22／37、46 → 45）、兩份簡報的數字與截圖、cbom/webapp/README.md 與 CLAUDE.md 的「46／49」。

## 2026-11-14 HMAC-SHA1 降為警告、Demo 彩排、文件與簡報跟上、commit

- 使用者決定：HMAC 搭 SHA-1 判「警告」（規則 `hmac-sha1`，NIST 仍允許；HmacMD5、PBKDF2 搭 SHA-1 仍是違規）。規則測試 38／38；基準只有 web-findings、web-report 改變，已 rebase。操作機 `/opt/cbom/policy` 與 `cbom-jenkins` 都是新規則。
- Demo 彩排（照 Demo 手冊）：停 Kafka lab 1 分 41 秒；`lab.sh up`；`demo.sh up --jenkins` 18 秒；#1 紅（違規 21、量子脆弱 30、無法判斷 3、警告 1，2 分 45 秒）；有執行期的那次黃（違規 35、量子脆弱 71、無法判斷 3、警告 3，3 分 23 秒），對答案 45／49、不符 0；check 17／16／9／42，改規則後 26／16／0／42，改回後相同；reload 這次 33 秒（手冊改成 20–35 秒）。
- 教訓：清單裡「最上面那一筆」取決於先掃描還是先上傳。彩排時先跑 Jenkins 再掃描，shots.mjs 拍「pipeline 上傳的那一份」拍到平台的 142 筆。照台上的順序（purge → 掃描 → pipeline 上傳）重做才對（270 筆）。拍完一定要看 `cbomkit-b-upload.txt` 的筆數。
- cbom-jenkins 現在留著 #1（紅）與 #3（黃、有上傳）；#2 和 #3 內容相同，為了簡報截圖只留兩筆而刪掉。CBOMkit 的掃描紀錄留著（平台掃描 1 筆＋上傳 1 筆）。
- 涵蓋率用對答案工具的比對條件重量（scratchpad 的 stage-coverage.js，結果和 check-inventory 一致）：平台 26（不是 27）；pipeline 累計 26 → 35 → 37 → 45。簡報 `DATA`、兩份 README、CLAUDE.md 已改。
- 三方對照表（Demo 手冊第 6 章）：已破解 17 → 16、新增「HMAC 搭 SHA-1」2 個（警告）、其他演算法 2 → 1。
- 手冊第 33 章照手冊重跑 26／26（run-customer-33-33-20261114-0918.log），`out` 更新：PASS 38/38；手動路徑 173 個元件（含 data=1）、量子脆弱 73；Jenkins 151 個元件、約 360 秒；等級用詞改成「無法判斷」「資訊」；「怎麼讀報告」加盤點完整性與「看不到什麼」。
- 簡報截圖：新增 `cbom/deck/shots.mjs webapp|cp <report.html>`（八張）；報告多了「盤點完整性」一行，兩份簡報 reportGuide 的編號比例改成 0.2／0.305／0.505／0.8。用 PowerPoint 匯出改過的投影片看過。
- 還沒做：`install/steps/33-*` 腳本版、run-customer.sh 與手冊導覽簡報加第 33 章、整本從零全跑。報告上「量子脆弱」的數字（元件數 61）和 Jenkins 摘要（判定筆數 71）口徑不同，還沒統一說明。
