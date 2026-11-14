# CBOMkit 平台 Demo

用 **CBOMkit 平台**掃描我們的 web app（crypto-lab），並排比較**兩套合規檢查**：

| | 網頁 | 合規檢查 | 規則在哪裡 |
|---|---|---|---|
| **網頁 A** | http://localhost:28084 | CBOMkit **內建**的 quantum_safe 檢查 | CBOMkit 程式裡寫死，不能改 |
| **網頁 B** | http://localhost:28086 | **OPA**（Open Policy Agent） | `policy/quantum_safe.rego`，我們自己寫、可以改 |

兩組 CBOMkit 共用同一個資料庫：在任一邊掃描一次，兩邊都看得到同一份 CBOM，差別只在「用哪套規則判斷」。


這個目錄是獨立的：只掃 web app（`cbom/app`）的原始碼，自己的容器名稱（`demo-` 開頭）、網路與 port。要連同 web app 的 Jenkins 一起開（把 pipeline 產出的 CBOM 上傳到這裡看），先 `bash cbom/webapp/lab.sh up` 建好 Jenkins，之後用 `bash cbom/cbomkit-demo/demo.sh up --jenkins`（見 `cbom/webapp/README.md`）。

```text
                      ┌─ demo-builtin-api（內建檢查）────────────── 網頁 A :28084
demo-db（共用資料庫）─┤
                      └─ demo-opa-api ──► demo-opa（policy/*.rego）── 網頁 B :28086
                              ▲
demo-git（nginx：提供 web app 的 git repo，因為 CBOMkit 只接受 http(s) 的 git 網址）
```

---

## 使用方式

需要：podman（Windows 請在 **Git Bash** 執行）、Node.js 20 以上、git。指令都在 repo 根目錄執行。

```bash
bash cbom/cbomkit-demo/demo.sh up
```

```text
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
```

約 10 秒（第一次要下載映像檔，需要網路、約幾分鐘）。其他指令：

| 指令 | 做什麼 |
|---|---|
| `bash cbom/cbomkit-demo/demo.sh scan` | 不用網頁，直接請 CBOMkit 掃描 web app，掃完印出比較表（網頁操作的備援） |
| `bash cbom/cbomkit-demo/demo.sh check` | 在終端機比較兩套檢查的結果（最新一次掃描） |
| `bash cbom/cbomkit-demo/demo.sh reload` | 改了 `policy/` 的規則之後，讓 OPA 重新載入（約 5 秒） |
| `bash cbom/cbomkit-demo/demo.sh down` | 結束（web app 的 Jenkins 只停不刪）；加 `--purge` 連掃描紀錄一起刪掉，回到全新狀態 |

> 掃的是 `cbom/app` **現在的檔案**（已 commit 與還沒 commit 的都算）：`up` 時把它們做成一個臨時的 git repo。改了程式要重新 `up` 再掃。
>
> 簡報當天照著做的完整步驟（含 Jenkins 那一段與每一步的畫面）：`docs/Cbom-Demo手冊.docx`。

---

## Demo 腳本（約 15 分鐘）

### 事前準備（demo 前一天）

1. 跑一次 `bash cbom/cbomkit-demo/demo.sh up`，確認映像檔都下載好、兩個網頁打得開。
2. 想從乾淨的畫面開始：`bash cbom/cbomkit-demo/demo.sh down --purge`，demo 當天再 `up`。
3. demo 約需 3 GB 可用記憶體：不夠時 `up` 會停下來，先停掉其他用不到的容器（`podman ps` 看有哪些）再啟動。
4. 瀏覽器開兩個分頁：網頁 A、網頁 B。

### ① 開場（1 分鐘）

> 「後量子密碼遷移的第一步是盤點：我們的程式用了哪些密碼學、在哪裡。CBOMkit 是 IBM 開源的平台，貼一個 git 網址就能產生密碼學清單（CBOM）。今天示範兩件事：它能掃出什麼，以及怎麼讓它用**我們自己的規則**判斷。」

### ② 掃描我們的 web app（3 分鐘）— 網頁 A

1. 網頁 A → **Generate a new CBOM** → 貼上 `http://demo-git/local/crypto-lab` → **Scan**。
2. 約 20 秒後出現 **Scan finished**，上方顯示 `142 cryptographic assets found.`（142 是出現次數；同一個演算法在不同位置各算一次，不重複的資產是 84 個）。
3. 看總覽：
   - 橫幅：**Not compliant**，來源 **Basic Backend Compliance Service**（內建檢查）。
   - 第一個圓環：Not Applicable 約 46%、Unknown 約 31%、Not Quantum Safe 約 23%。
4. 往下捲到 **List of all assets**：每個演算法都有 **檔名:行號**，點一下 ↗ 可以看細節。

> 「20 秒就知道程式在哪一行用了哪個演算法。黃色的 Not Quantum Safe 是 RSA、ECDSA 這類會被量子電腦破解的，要排進遷移計畫。」

### ③ 內建檢查的盲點（2 分鐘）— 網頁 A

在清單找 **SHA-1**，點 ↗ → Compliance：

```text
Not Applicable — The asset has a symmetric primitive, so the Quantum Safe categorization is not applicable
```

> 「SHA-1 早就被破解了，但內建規則只看『量子安全』，對稱演算法和雜湊一律不分類，所以 MD5、SHA-1、DES 都是灰色的 Not Applicable。內建規則寫死在平台裡，我們改不了。」

### ④ 換成我們的規則（3 分鐘）— 網頁 B

1. 網頁 B 的 **Explore previously scanned CBOMs** 已經有剛才那一筆（兩邊共用資料庫），點 **See 142 cryptographic assets**（OPA 每次打開才計算，約 10–15 秒）。
2. 橫幅的來源變成 **Open Policy Agent Compliance Service**，圓環多了綠色的 **Quantum Safe**（約 32%）。
3. 再點 **SHA-1** 的 ↗ → Compliance：

```text
Rule 'BROKEN：已被破解或不安全，應該立即汰換（CBOMkit 沒有「已破解」這一級，所以放在 Not Applicable）' fired on asset property 'name'='SHA-1'
```

> 「同一份掃描結果，換成我們的規則：AES-256、SHA-256 這類對稱演算法判成量子安全，已被破解的會明確寫出原因。規則是一個文字檔，放在 git 裡，可以審查、可以測試。」

（清單上的標籤文字仍是 `Not Applicable: we only categorize asymmetric algorithms`：每個等級的標籤是網頁寫死的，看 Compliance 細節才是我們的規則說明。）

### ⑤ 終端機並排比較（1 分鐘）

```bash
bash cbom/cbomkit-demo/demo.sh check
```

```text
CBOM：pkg:github/demo-git/local/crypto-lab@…（84 個密碼學資產）

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

### ⑥ 現場改規則（2 分鐘）

情境：「公司規定，已被破解的演算法要顯示成不安全（黃色），不要藏在灰色的 Not Applicable 裡。」

1. 打開 `cbom/cbomkit-demo/policy/quantum_safe.rego`，找到 `"rule": "BROKEN` 那一行，把結尾的 `"result": "na"` 改成 `"result": "quantum-vulnerable"`，存檔。
2. 重新載入規則：

   ```bash
   bash cbom/cbomkit-demo/demo.sh reload
   ```

3. 重新整理網頁 B（或再跑一次 `check`）：

   ```text
   等級                內建檢查   OPA 檢查
   Not Quantum Safe          17         26
   Quantum Safe               0         16
   Not Applicable            25          0
   Unknown                   42         42
   ```

   9 個已被破解的演算法從灰色變成黃色。網頁 A（內建）完全不受影響。

4. demo 完把規則改回來：同一行改回 `"result": "na"`，存檔，再 `reload`；跑 `check` 看到 OPA 那一欄回到 17／16／9／42 才算改回來了。

> 「規則改一行、幾秒生效，不用改平台、不用重新掃描。」

### ⑦ 收尾：能做到與做不到（2 分鐘）

| 只用 CBOMkit 平台能做到 | 做不到 |
|---|---|
| 貼網址掃原始碼（Java、Python、Go、C#） | 設定檔裡的金鑰、映像檔、實際 TLS 連線、執行期才用到的密碼學 |
| 圖形化總覽、每個資產的位置 | 一份可以存檔、分享的報表；和上一次比較 |
| 用自己的規則分類（接 OPA） | 等級只有四種（放不進「已被破解」）；結果打開時才算、不保存；不能擋 build |

> 「快速盤點、讓大家看得懂，CBOMkit 很適合。要正式治理（找出所有地方、每次建置自動檢查、擋下新的弱密碼學），還需要搭配 CI pipeline。」

### 結束

```bash
bash cbom/cbomkit-demo/demo.sh down
```

---

## 疑難排解

| 症狀 | 處理 |
|---|---|
| `up` 卡在「等待 CBOMkit」很久 | 記憶體不足或還在下載映像檔：`podman ps -a` 看容器狀態，`podman logs demo-builtin-api` 看 log |
| 網頁 B 打開 CBOM 一直轉圈 | OPA 每次重新計算，等 10–15 秒；超過 30 秒看 `podman logs demo-opa-api` |
| 改了規則，結果沒變 | 要執行 `bash cbom/cbomkit-demo/demo.sh reload`（OPA 只在啟動時讀規則） |
| `check` 說 OPA 回報錯誤 | Rego 可能有語法錯誤：`podman logs demo-opa` 會指出哪一行；改好後 `reload` |
| 掃描結果沒有最新的程式 | git repo 是 `up` 的時候做的：重新 `up`，再掃一次 |
| 網頁 A 的 Scan 沒反應 | 用備援：`bash cbom/cbomkit-demo/demo.sh scan`，掃完到網頁 A、B 重新整理就看得到 |

---

## 維護

| 檔案 | 內容 | 什麼時候改 |
|---|---|---|
| `demo.sh` | 啟動、掃描、比較、停止（每個指令一個函式） | 要加步驟時 |
| `demo.conf` | 映像檔版本、port、要掃的分支與網址 | 改 port、升級 CBOMkit / OPA 版本 |
| `check.mjs` | 向兩組 CBOMkit 問同一份 CBOM 的合規結果並比較（只用 Node 內建功能，不用 npm install） | 要改比較表的格式時 |
| `policy/quantum_safe.rego` | OPA 的規則：每個資產由上往下，第一條符合的決定等級 | 要改分類方式時 |
| `policy/names.rego` | 用演算法名稱判斷「已被破解 / 非對稱 / 後量子」 | 要加新的演算法名稱時 |
| `policy/lib.rego` | 規則用的輔助值（CBOMkit 要求規則的 package 裡只能有 findings，所以放在這裡） | 很少 |
| `policy/quantum_safe_test.rego` | 規則的單元測試 | 改規則時一起改 |

**改規則之後先跑測試**（在 `cbom/cbomkit-demo/` 底下執行；Git Bash 要加 `MSYS_NO_PATHCONV=1`）：

```bash
MSYS_NO_PATHCONV=1 podman run --rm -v "$(pwd -W 2>/dev/null || pwd)/policy:/p:ro,Z" docker.io/openpolicyagent/opa:1.22.2-static test /p
```

```text
PASS: 12/12
```

**和 pipeline 規則的關係**：這裡的 `policy/` 是給 CBOMkit 用的（結果只有四種）；pipeline 用的是 `cbom/policy/cbom.rego`（六級）。兩份各自維護，判斷演算法名稱的邏輯相同，改其中一邊時看一下另一邊要不要跟著改。

**CBOMkit 的限制（2.3.0 實測）**：掃描只接受 http(s) 的 git 網址（所以用 nginx 提供本機 repo）；合規檢查只能「內建」或「OPA」二選一，所以兩套檢查要開兩組 CBOMkit；網頁標題不能有空白（網頁映像檔用 `sed` 代換標題）。
