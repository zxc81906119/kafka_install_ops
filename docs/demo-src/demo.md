<!--meta
{"kicker":"密碼學資產盤點（CBOM）","title":"Demo 手冊","subtitle":"CBOMkit 平台＋web app 的 Jenkins pipeline：從前一天準備到收尾，每一步的指令、結果與畫面","header":"CBOM · Demo 手冊","author":"zxc81906119","facts":[["搭配簡報","Cbom 探討（docs/Cbom-探討.pptx）"],["展示內容","第一段：CBOMkit 平台掃描 web app，內建檢查與 OPA 檢查並排比較；第二段：同一個 web app 放進 Jenkins pipeline，關卡擋下違規，再把 CBOM 上傳到 CBOMkit"],["環境","Windows 11、Podman、Git Bash；和 Kafka lab 無關，但兩邊不能同時開（記憶體）"],["實測日期","2026-11-14（手冊裡的結果與畫面都是照著做出來的；CBOMkit 的四張細節畫面沿用 11-12 的）"]]}
-->
[[toc]]

# 1. 先看這一頁

## 1.1 要展示什麼

| 段落 | 做什麼 | 聽眾看到什麼 | 時間 |
|---|---|---|---|
| 第一段：CBOMkit 平台 | 貼一個 git 網址掃描 web app；同一份結果用兩套規則看；現場改一行規則 | 20 秒知道哪一行用了哪個演算法；規則是自己的、改了幾秒生效 | 約 12 分鐘 |
| 第二段：Jenkins pipeline | 同一個 web app 跑 pipeline 兩次 | 第一次紅色（關卡擋下違規）；第二次黃色（只標示），報告、CBOM 上傳到 CBOMkit | 約 10 分鐘（含等待 2 次各約 4 分鐘，等的時候講解） |

## 1.2 會用到的網址

| 名稱 | 網址 | 說明 |
|---|---|---|
| 網頁 A | http://localhost:28084 | CBOMkit，內建的檢查 |
| 網頁 B | http://localhost:28086 | CBOMkit，接 OPA（我們的規則） |
| Jenkins | http://localhost:18089/job/cbom-webapp/ | 帳號 `admin`；密碼在一個檔案裡（3.3 節） |

## 1.3 指令只有這幾個

全部在 **Git Bash**、在專案的根目錄執行。每個指令都是「`bash` ＋腳本＋一個動作」：

| 什麼時候 | 指令 | 做什麼 | 多久 |
|---|---|---|---|
| 開始前 | `bash install/lab/lab-power.sh stop` | 把 Kafka lab 停掉，讓出記憶體（只停不刪） | 約 2 分鐘 |
| 只做一次 | `bash cbom/webapp/lab.sh up` | 建好 web app 的 Jenkins | 約 5 分鐘 |
| 開始前 | `bash cbom/cbomkit-demo/demo.sh up --jenkins` | 啟動 CBOMkit 與 Jenkins | 約 25 秒 |
| 台上 | `bash cbom/cbomkit-demo/demo.sh check` | 在終端機比較兩套檢查 | 2 秒 |
| 台上 | `bash cbom/cbomkit-demo/demo.sh reload` | 改了規則之後重新載入 | 20–35 秒 |
| 結束後 | `bash cbom/cbomkit-demo/demo.sh down` | 收掉 CBOMkit，Jenkins 停下來 | 幾秒 |
| 結束後 | `bash install/lab/lab-power.sh start` | 把 Kafka lab 啟動回來 | 約 4 分鐘 |

> 台上真正要打的指令只有 `check` 和 `reload` 兩個，其餘都是滑鼠操作。其他指令在上台前就做完。

# 2. 前一天：準備與預演

目的：把要下載的東西都下載好、確認每個畫面都出得來、Jenkins 先跑過（第一次比較慢，而且跑過一次才有參數可以選）。

@role 講者 | Windows 的 Git Bash | 自己的帳號

## 2.1 把 Kafka lab 停掉

```bash
bash install/lab/lab-power.sh stop
```

```out
停掉 Kafka lab：15 個容器（只停不刪，約 2 分鐘）
已停掉
```

確認真的停了：

```bash
bash install/lab/lab-power.sh status
```

```out
Kafka lab 沒有在跑的容器
```

## 2.2 確認兩個執行檔已經建好

```bash
ls cbom/dist
```

```out
VERSIONS  cbom-tools.jar  cbomkit-theia
```

三個檔都在就跳到 2.3。沒有的話先建（約 5 分鐘，要網路）：

```bash
bash cbom/build.sh
```

```out
cbom-tools 1.0.0
cbomkit-theia 1.1.2
dist/ 已更新，雜湊相符
```

（中間還有幾行版本與雜湊，最後一行是 `dist/ 已更新，雜湊相符` 就對了。）

## 2.3 建好 Jenkins（只做一次）

```bash
bash cbom/webapp/lab.sh up
```

```out
1/4 下載工具
opa 1.22.3 sha256-ok
testssl.sh 3.2.5 sha256-ok
2/4 準備檔案
3/4 建映像（第一次約 2 分鐘）
4/4 啟動 Jenkins
容器：running
Jenkins：http://localhost:18089/job/cbom-webapp/（帳號 admin，密碼在 /c/Users/<你的帳號>/cbom-lab/jenkins/secrets/admin.pass）
容器引擎：用戶端 5.4.2，主機 6.1.4
cbomkit-theia 1
testssl.sh 3.2.5
opa 1.22.3
web app 原始碼：8 個項目
lab：admin、工作 cbom-webapp 已設定
```

> 之後不用再跑這一步。只有改了 web app 的程式、規則或收集腳本時才重跑（重跑會清掉 Jenkins 的執行紀錄）。

## 2.4 啟動展示環境

```bash
bash cbom/cbomkit-demo/demo.sh up --jenkins
```

```out
1/4 資料庫
2/4 CBOMkit（內建檢查）
3/4 OPA + CBOMkit（OPA 檢查）
4/4 提供 web app 的 git repo
  等待 CBOMkit（內建檢查） OK
  等待 CBOMkit（OPA 檢查） OK

Demo is up.
  網頁 A（內建檢查）: http://localhost:28084
  網頁 B（OPA 檢查）: http://localhost:28086
  要掃描的 git 網址 : http://demo-git/local/crypto-lab
  Jenkins 已接上 demo 的網路
  等待 Jenkins OK
  Jenkins            : http://localhost:18089/job/cbom-webapp/
  工作的 CBOMKIT_URL : http://demo-builtin-api:8081（內建檢查）或 http://demo-opa-api:8081（OPA 檢查）
```

第一次要下載映像檔，會多幾分鐘。

>! 出現「可用記憶體 … MB，不到 3000 MB」就是 Kafka lab 還沒停（回 2.1），或有別的程式佔著記憶體。遊戲、IntelliJ、Chrome 的其他分頁先關掉。

## 2.5 Jenkins 先跑兩次

1. 照 3.3 節登入 Jenkins。
2. 第一次：左邊還沒有「帶參數建置」，按「馬上建置」（英文介面是 Build Now）。約 4–6 分鐘（第一次要下載 Maven 的套件），結果是**紅色**：這是對的，app 刻意放了違規的用法，關卡把它擋下來。
3. 第二次：照 5.3 節的參數再跑一次，結果是**黃色**。

這兩次的結果留著當備援：當天現場跑失敗或時間不夠，就打開這兩次給大家看。

## 2.6 整個流程走一遍

照第 4、5 章從頭做一次。做完後把 CBOMkit 的掃描紀錄清掉，當天從乾淨的畫面開始（Jenkins 的執行紀錄不受影響）：

```bash
bash cbom/cbomkit-demo/demo.sh down --purge
```

```out
demo stopped (purged)
```

# 3. 當天：上台前 15 分鐘

@role 講者 | Windows 的 Git Bash | 自己的帳號

## 3.1 停 Kafka lab、啟動展示環境

```bash
bash install/lab/lab-power.sh stop
```

```bash
bash cbom/cbomkit-demo/demo.sh up --jenkins
```

輸出和 2.1、2.4 一樣。最後看到 `Demo is up.` 和 `等待 Jenkins OK` 才算好。

## 3.2 開三個瀏覽器分頁

依序打開 1.2 節的三個網址：網頁 A、網頁 B、Jenkins。網頁 A 一開始長這樣（網頁 B 相同，只有左上角的標題不同）：

![images/cbomkit-a-home.png]

## 3.3 登入 Jenkins（不要在投影時做）

密碼是隨機產生的，存在一個檔案裡。在終端機把它印出來、複製：

```bash
cat ~/cbom-lab/jenkins/secrets/admin.pass
```

到 Jenkins 的登入頁，帳號填 `admin`，密碼貼上，登入。

![images/jenkins-login.png]

>! 這一步在接投影機**之前**做完，然後清掉終端機畫面（輸入 `clear`）。密碼不要出現在投影上。

## 3.4 其他準備

- 終端機：Git Bash 開在專案的根目錄，字放大。
- 編輯器：打開 `cbom/cbomkit-demo/policy/quantum_safe.rego`，捲到最下面 `decision` 那一段、有 `"rule": "BROKEN` 的那一行（第 91 行）。檔案開頭有一張「判斷的順序」表，講解規則時可以直接給大家看。
- 簡報：Cbom 探討。

# 4. 第一段：CBOMkit 平台（約 12 分鐘）

## 4.1 掃描 web app — 網頁 A

1. 在網頁 A 的 **Generate a new CBOM** 貼上網址，按 **Scan**：

```out
http://demo-git/local/crypto-lab
```

![images/cbomkit-generate.png]

2. 約 20 秒後出現 **Scan finished**，上方顯示 `142 cryptographic assets found.`
3. 看總覽：橫幅是 **Not compliant**，來源 **Basic Backend Compliance Service**（內建檢查）。第一個圓環：Not Applicable 約 46%、Unknown 約 31%、Not Quantum Safe 約 23%。

![images/cbomkit-overview.png]

4. 往下捲到 **List of all assets**：每個演算法都有「檔名:行號」。

![images/cbomkit-list.png]

> 講稿：「20 秒就知道程式在哪一行用了哪個演算法。黃色的 Not Quantum Safe 是 RSA、ECDSA 這類會被量子電腦破解的，要排進遷移計畫。」

> 142 是出現次數（同一個演算法在不同位置各算一次）；不重複的資產是 84 個，4.4 節終端機印的就是 84。有人問再講。

## 4.2 內建檢查的盲點 — 網頁 A

在清單找 **SHA-1**，按右邊的 ↗，看 Compliance：

![images/cbomkit-detail-sha1-compliance.png]

```out
Not Applicable — The asset has a symmetric primitive, so the Quantum Safe categorization is not applicable
```

> 講稿：「SHA-1 早就被破解了，但內建規則只看『量子安全』，對稱演算法和雜湊一律不分類，所以 MD5、SHA-1、DES 都是灰色的 Not Applicable。內建規則寫死在平台裡，我們改不了。」

## 4.3 換成我們的規則 — 網頁 B

1. 切到網頁 B，重新整理。**Explore previously scanned CBOMs** 已經有剛才那一筆（兩邊共用資料庫）。按 **See 142 cryptographic assets**，等 10–15 秒（OPA 每次打開才計算）。
2. 橫幅的來源變成 **Open Policy Agent Compliance Service**，圓環多了綠色的 **Quantum Safe**（約 32%）。

![images/cbomkit-opa-overview.png]

3. 再找 **SHA-1**，按 ↗，看 Compliance：

![images/cbomkit-opa-detail-sha1-compliance.png]

```out
Rule 'BROKEN：已被破解或不安全，應該立即汰換（CBOMkit 沒有「已破解」這一級，所以放在 Not Applicable）' fired on asset property 'name'='SHA-1'
```

> 講稿：「同一份掃描結果，換成我們的規則：AES-256、SHA-256 這類判成量子安全，已被破解的會明確寫出原因。規則是一個文字檔，放在 git 裡，可以審查、可以測試。」

## 4.4 終端機並排比較

@role 講者 | Windows 的 Git Bash | 自己的帳號

```bash
bash cbom/cbomkit-demo/demo.sh check
```

```out
CBOM：pkg:github/demo-git/local/crypto-lab@fa59099（84 個密碼學資產）

等級                內建檢查   OPA 檢查
Not Quantum Safe          17         17
Quantum Safe               0         16
Not Applicable            25          9
Unknown                   42         42

等級不同：對稱加密與雜湊，內建不分類，OPA 判成量子安全
  SHA3                 內建：Not Applicable    OPA：Quantum Safe（規則 SYMMETRIC）
  AES-GCM              內建：Not Applicable    OPA：Quantum Safe（規則 SYMMETRIC）
  AES-128-GCM          內建：Not Applicable    OPA：Quantum Safe（規則 SYMMETRIC）

等級相同、原因不同：已被破解的演算法（內建只說「不分類對稱」，OPA 說出它已被破解）
  SHA-1                內建：Not Applicable    OPA：Not Applicable（規則 BROKEN）
  DES-56               內建：Not Applicable    OPA：Not Applicable（規則 BROKEN）
  3DES-168             內建：Not Applicable    OPA：Not Applicable（規則 BROKEN）
```

（`@` 後面那串是這次 git repo 的編號，每次啟動都不同。）

## 4.5 現場改規則

情境：「公司規定，已被破解的演算法要顯示成不安全（黃色），不要藏在灰色的 Not Applicable 裡。」

1. 在編輯器裡，`quantum_safe.rego` 第 91 行（有 `"rule": "BROKEN` 的那一行；下一行的註解也寫了要改什麼），把行尾的

```out
"result": "na"
```

改成

```out
"result": "quantum-vulnerable"
```

存檔。

2. 重新載入規則（20–35 秒）：

```bash
bash cbom/cbomkit-demo/demo.sh reload
```

```out
OPA reloaded policy/（重新整理網頁 B 就是新規則的結果）
```

3. 再比較一次：

```bash
bash cbom/cbomkit-demo/demo.sh check
```

```out
等級                內建檢查   OPA 檢查
Not Quantum Safe          17         26
Quantum Safe               0         16
Not Applicable            25          0
Unknown                   42         42
```

9 個已被破解的演算法從 Not Applicable 變成 Not Quantum Safe（17 → 26）。內建檢查那一欄完全沒變。重新整理網頁 B 也看得到黃色變多。

> 講稿：「規則改一行、幾秒生效，不用改平台、不用重新掃描。」

4. **改回來**（講完這一段就做，不要留到最後）：同一行改回 `"result": "na"`，存檔，再跑一次 `reload`，再跑一次 `check`，OPA 那一欄回到 17、16、9、42 才算改回來了。

## 4.6 這一段的小結

| 只用 CBOMkit 平台能做到 | 做不到 |
|---|---|
| 貼網址掃原始碼（Java、Python、Go、C#） | 設定檔裡的金鑰、映像檔、實際 TLS 連線、執行期才用到的密碼學 |
| 圖形化總覽、每個資產的位置 | 一份可以存檔、分享的報表；和上一次比較 |
| 用自己的規則分類（接 OPA） | 等級只有四種（放不進「已被破解」）；結果打開時才算、不保存；不能擋 build |

> 講稿：「快速盤點、讓大家看得懂，CBOMkit 很適合。要正式治理，還需要搭配 CI pipeline。」接第二段。

# 5. 第二段：Jenkins pipeline（約 10 分鐘）

每次建置約 4 分鐘。做法是**先按下去，等的時候講解**；時間不夠就直接打開前一天跑好的那兩次（5.5 節）。

## 5.1 工作頁

切到 Jenkins 的分頁。左下角 Builds 是之前跑過的紀錄：紅色的叉是失敗，黃色的驚嘆號是「不穩定」（跑完了，但有問題要看）。

![images/jenkins-job.png]

## 5.2 第一次：關卡開著（預期紅色）

1. 按左邊的「帶參數建置」。
2. 參數都不用改（`GATE` 已經勾著），按綠色的「建置」。

![images/jenkins-params.png]

3. 等的時候講 pipeline 在做什麼（簡報「pipeline 做了哪些事」那一頁）：建置 → 原始碼掃描 → 找秘密 → 建映像、掃映像 → 合併成一份 CBOM → OPA 判斷 → 報告。
4. 約 3 分鐘後變成紅色。點進那一次（例如 #3）：

![images/jenkins-build-red.png]

標題下面那一行是結果摘要：

```out
執行期 無｜{"quantum-vulnerable":30,"unknown":3,"violation":21,"warning":1}
```

意思：違規 21 項、量子脆弱 30 項、無法判斷 3 項、警告 1 項。有違規，而且關卡開著，所以這次建置失敗。

5. 按左邊的「CBOM 合規報告」看報告。最上面是結論與各級的數量，往下是每一項違規：哪個演算法、在哪個檔案第幾行、為什麼違規。

![images/report-webapp-violations.png]

> 講稿：「紅色不是壞掉，是關卡在做它該做的事：有人把 MD5、寫死的金鑰放進程式，這次建置就過不了。這是 CBOMkit 平台做不到的。」

## 5.3 第二次：關卡關掉、加執行期、上傳 CBOMkit（預期黃色）

1. 回到工作頁，再按「帶參數建置」，這次改三個地方：

| 參數 | 改成 | 意思 |
|---|---|---|
| `RUNTIME_EVIDENCE` | 打勾 | 把 app 真的跑起來，看實際的 TLS 連線與執行時用到的演算法 |
| `GATE` | 取消打勾 | 有違規也不讓建置失敗，只標示 |
| `CBOMKIT_URL` | 貼上下面這一行 | 把 CBOM 上傳到 CBOMkit（接 OPA 的那一組） |

```out
http://demo-opa-api:8081
```

>! 這個網址是 Jenkins 容器看到的 CBOMkit（容器名稱＋內部的 port），**不是**瀏覽器用的 `localhost:28086`。照貼就好，不要改。

2. 按「建置」，約 4 分鐘後變成黃色。點進去：

![images/jenkins-build-yellow.png]

```out
執行期 有｜{"quantum-vulnerable":71,"unknown":3,"violation":35,"warning":3}
```

加了執行期之後，違規從 21 變 35、量子脆弱從 30 變 71：有些密碼學只有跑起來才看得到（實際協商出來的 TLS、函式庫內部用的演算法）。

3. 按「CBOM 合規報告」：

![images/jenkins-report.png]

4. 上方「建構產出檔案」可以下載 `cbom.json`（完整的 CBOM）、`findings.json`（每一項的判定）、`report.html`（報告，可以直接寄給別人）、`inventory-check.txt`（對答案：web app 刻意放的 49 個例子，這次找到幾個、等級對不對；有執行期的這一次是找到 45 個、等級全部相符，另外 4 個是工具看不到的）。

## 5.4 在 CBOMkit 看 pipeline 上傳的 CBOM — 網頁 B

1. 切到網頁 B，按右上角 **Start over** 回首頁（或重新整理）。清單最上面多了一筆 **crypto-lab-webapp**，這就是 pipeline 剛上傳的。

![images/cbomkit-b-home.png]

2. 按它的 **See 270 cryptographic assets**，等 10–15 秒：

![images/cbomkit-b-upload.png]

> 講稿：「平台自己掃原始碼找到 142 筆；pipeline 上傳的這一份有 270 筆，因為多了金鑰檔、映像檔、執行期看到的。平台負責讓大家看得懂，pipeline 負責找得全、擋得住，兩個搭配著用。」

> 270 是出現次數；不重複的資產是 159 個（pipeline 的紀錄寫「只留密碼學資產：159 個」）。

## 5.5 備援：現場不跑，直接看跑好的

時間不夠或現場跑失敗時，在工作頁左下角的 Builds 點前一天的那兩次（紅色那次與黃色那次），照 5.2 的第 4–5 步、5.3 的第 2–4 步講。上傳到 CBOMkit 的那一份如果前一天用 `--purge` 清掉了，5.4 改成口頭說明加上這本手冊的圖。

# 6. 有人問：同一份 CBOM，三個地方判的一樣嗎？

不一樣，因為等級的種類不同。下面是 2026-11-14 把 pipeline 上傳的那一份（159 個資產）在三個地方逐一比對的結果：

| 資產 | 個數 | pipeline（六級） | CBOMkit＋OPA（四種） | CBOMkit 內建（四種） |
|---|---|---|---|---|
| 非對稱演算法，例如 RSA、ECDSA | 55 | 量子脆弱 | Not Quantum Safe | Not Quantum Safe |
| 金鑰太短，例如 RSA-1024 | 2 | **違規** | Not Quantum Safe | Not Quantum Safe |
| 已被破解，例如 MD5、SHA-1、DES、RC4；或 AES 用 ECB 模式 | 16 | **違規** | Not Applicable（規則寫明已被破解） | Not Applicable |
| HMAC 搭 SHA-1（HmacSHA1） | 2 | 警告（NIST 仍允許，建議改 HMAC-SHA256） | Not Applicable（規則寫明已被破解） | Not Applicable |
| 用了已破解雜湊的簽章，例如 SHA1withRSA | 5 | **違規** | Not Applicable（規則寫明已被破解） | Not Quantum Safe |
| 已被破解，但名稱是另一種寫法：ARCFOUR、PBEWithMD5AndDES、SHA | 3 | **違規** | Quantum Safe（規則不認得這個寫法） | Not Applicable |
| 對稱加密與雜湊，強度足夠，例如 AES-256、SHA-256 | 42 | 通過 | Quantum Safe | Not Applicable |
| 憑證 | 4 | 違規 2、量子脆弱 2 | Not Quantum Safe | Unknown |
| TLS 協定 | 3 | 量子脆弱、警告（TLS 1.2）、資訊各 1 | Not Quantum Safe | Unknown |
| 金鑰與秘密（私鑰檔、寫死的金鑰） | 26 | 違規 7、量子脆弱 3、無法判斷 3、資訊 13 | Not Quantum Safe 9、Unknown 17 | Unknown |
| 其他演算法 | 1 | 通過 | Unknown | Unknown |

三個重點：

- CBOMkit 只回答「會不會被量子電腦破解」，所以「已被破解」「金鑰太短」「私鑰放在程式庫裡」「憑證過期」這些**違規**，在平台上看不出來；只有 pipeline 的規則分得出來，也只有 pipeline 能擋。
- 接上 OPA 之後，平台的結果比內建的清楚（對稱演算法有分類、憑證與協定不再是 Unknown），但等級還是只有四種。
- 第 5 列是一個實際的落差：執行期看到的名稱是 Java 的寫法（ARCFOUR 就是 RC4），平台那份規則的名稱清單沒有這幾個，所以判成了量子安全；pipeline 的規則認得。兩份規則是分開維護的，這就是代價。

要重做這張表：展示環境開著、pipeline 上傳過之後，把那一次的 `findings.json` 下載下來，執行 `node docs/demo-src/tools/compare.mjs <findings.json 的路徑>`。

# 7. 結束後

@role 講者 | Windows 的 Git Bash | 自己的帳號

1. 確認 4.5 的規則已經改回來（`check` 的 OPA 那一欄是 17、16、9、42）。
2. 收掉展示環境（CBOMkit 的容器刪掉、掃描紀錄留著；Jenkins 只是停下來）：

```bash
bash cbom/cbomkit-demo/demo.sh down
```

```out
demo stopped
```

3. 把 Kafka lab 啟動回來（約 4 分鐘）：

```bash
bash install/lab/lab-power.sh start
```

```out
啟動 Kafka lab（照順序，約 4 分鐘）
Kafka lab 的服務都起來了
```

# 8. 出狀況怎麼辦

| 症狀 | 處理 |
|---|---|
| `demo.sh up` 說可用記憶體不到 3000 MB | Kafka lab 沒停：`bash install/lab/lab-power.sh stop`；再不夠就關掉其他程式 |
| `demo.sh up` 說「找不到容器 cbom-jenkins」 | 還沒建 Jenkins：`bash cbom/webapp/lab.sh up`，再 `demo.sh up --jenkins` |
| `up` 卡在「等待 CBOMkit」很久 | 第一次在下載映像檔，等它；超過 3 分鐘看 `podman logs demo-builtin-api` |
| 網頁 A 的 Scan 沒反應 | 改用指令掃：`bash cbom/cbomkit-demo/demo.sh scan`（約 25 秒），掃完重新整理網頁 A、B |
| 網頁 B 打開 CBOM 一直轉圈 | OPA 每次重新計算，等 10–15 秒；超過 30 秒重新整理再點一次 |
| 改了規則，結果沒變 | 有沒有存檔；有沒有跑 `reload` |
| `check` 說 OPA 回報錯誤 | 規則改壞了（少了引號或逗號）：把那一行改回原樣，`reload` |
| Jenkins 上傳 CBOMkit 那一步失敗 | `CBOMKIT_URL` 填成了 `localhost`：要填 `http://demo-opa-api:8081`。或啟動時沒加 `--jenkins`：`demo.sh up --jenkins` 重來 |
| CBOMkit 的網頁說 Invalid CBOM | 上傳的不是 pipeline 產出的那一份；pipeline 的 CBOM 都帶 `serialNumber`，不會有這個問題 |
| Jenkins 建置跑很久（超過 8 分鐘） | 記憶體不夠：改用 5.5 的備援，結束後再查 |
| `lab-power.sh start` 最後說「這幾台的服務還沒起來」，或中間出現 `Cannot connect to Podman` | 和 podman 的連線偶爾會斷一下：再跑一次 `bash install/lab/lab-power.sh start`（已經在跑的不受影響），最後用 `status` 確認 |
| 整台很慢、指令沒反應 | 記憶體吃緊。關掉其他程式；真的不動了，改用簡報裡的截圖講完，不要在台上重開機器 |

# 9. 附錄：今天實測的數字

| 項目 | 數字 |
|---|---|
| 停 Kafka lab | 15 個容器，1 分 41 秒 |
| 啟動 Kafka lab | 約 4 分鐘 |
| 啟動展示環境 | 18 秒 |
| CBOMkit 掃描 | 約 25 秒；142 筆（84 個資產） |
| 內建檢查 | Not Quantum Safe 17、Quantum Safe 0、Not Applicable 25、Unknown 42 |
| OPA 檢查 | Not Quantum Safe 17、Quantum Safe 16、Not Applicable 9、Unknown 42 |
| 改規則之後的 OPA 檢查 | Not Quantum Safe 26、Quantum Safe 16、Not Applicable 0、Unknown 42 |
| 重新載入規則 | 20–35 秒 |
| pipeline，關卡開、沒有執行期 | 2 分 45 秒；失敗（紅色）；違規 21、量子脆弱 30、無法判斷 3、警告 1 |
| pipeline，關卡關、有執行期、上傳 | 3 分 23 秒；不穩定（黃色）；違規 35、量子脆弱 71、無法判斷 3、警告 3 |
| 對答案（49 個刻意放的例子） | 沒有執行期：找到 37 個；有執行期：找到 45 個，等級全部相符；4 個是工具看不到的（bcrypt、Argon2、JWT `alg=none`、RSA PKCS#1 v1.5 加密） |
| 上傳到 CBOMkit 的 CBOM | 159 個資產（網頁顯示 270 筆） |

執行期那一次的數字每次可能差一點（看當下實際發生了哪些連線）；其他數字只要 web app 的程式沒改就不會變。
