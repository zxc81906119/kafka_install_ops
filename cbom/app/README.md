# crypto-lab：密碼學資產盤點的教學用 web app

## 這是什麼

一個 Spring Boot 4 的小 web app，**故意**把好的與不好的密碼學用法放在一起。它不是給人用的系統，是盤點工具的「考卷」：

- 拿盤點工具（原始碼掃描、秘密掃描、映像掃描、執行期錄製、TLS 掃描）來掃它，產出一份密碼學資產清單（CBOM）。
- 和標準答案 `expected-inventory.json`（49 項）對照，就知道工具找得到什麼、漏了什麼。
- 再用規則 `cbom/policy/cbom.rego` 判等級，看壞例子有沒有被判成違規。

所以這裡的壞例子（MD5、DES、寫死的金鑰、放在 repo 的私鑰…）**都是故意的，不要修掉**。每一處旁邊都有標記與原因。
`src/main/resources/crypto/` 的金鑰與憑證是 lab 專用的測試素材，刻意放進 git，不可用在別的地方。

掃這個 app 的 pipeline 在 `cbom/webapp/`（說明見 `cbom/webapp/README.md`），和 Kafka lab 無關。

## 目錄

| 路徑 | 內容 |
|---|---|
| `src/main/java/com/example/cryptolab/crypto/` | 每一類密碼學一個 Service（下表） |
| `src/main/java/com/example/cryptolab/web/` | `CryptoLabController`（`/api/lab/{類別}/{演算法}`）、`LabCategories`（類別清單，只定義一次）、`SecureController`（受保護的 `/api/secure/me`） |
| `src/main/java/com/example/cryptolab/config/` | `LabProperties`（對應 `application.yml` 的 `lab:` 區塊）、`SecurityConfig`（哪些路徑要 JWT） |
| `src/main/resources/application.yml` | TLS、keystore、JWT、寫死的金鑰等設定（設定本身也是盤點的對象） |
| `src/main/resources/crypto/` | `tls/`（HTTPS 憑證與 keystore）、`jwt/`（JWT 簽章金鑰 PEM）、`legacy/`（故意放的弱憑證） |
| `src/test/java/` | 三個測試（見「建置與測試」） |
| `expected-inventory.json` | 標準答案，49 項 |
| `scripts/exercise-api.sh` | 把每個端點打一次，讓執行期的錄製看得到每個演算法 |
| `scripts/generate-key-material.sh` | 重新產生 `crypto/` 底下的金鑰與憑證（平常不用跑） |
| `deploy/app/Containerfile`、`crypto.jfc` | 執行環境映像、JFR（執行期錄製）的設定 |

| Service | 示範什麼 | 端點 |
|---|---|---|
| `PasswordHashingService` | 密碼的儲存：bcrypt、Argon2、PBKDF2；壞例子 MD5、SHA-1 | `POST /api/lab/password/…` |
| `HashingService` | 雜湊與 MAC：SHA-2、SHA-3、HMAC；壞例子 MD5、SHA-1、HmacMD5 | `POST /api/lab/hash/…` |
| `SymmetricCryptoService` | 對稱式加密：AES-GCM、ChaCha20；舊做法 AES-CBC；壞例子 ECB、DES、3DES、固定 IV | `POST /api/lab/symmetric/…` |
| `SignatureService` | 數位簽章：RSA、RSA-PSS、ECDSA、Ed25519；壞例子 SHA1withRSA＋RSA-1024 | `POST /api/lab/signature/…` |
| `KeyExchangeService` | 金鑰交換與金鑰包裝：ECDH、X25519、DH、RSA-OAEP；壞例子 RSA PKCS#1 v1.5、DH-1024 | `POST /api/lab/key-exchange/…` |
| `JwtService` | JWT 簽發與驗證（函式庫 nimbus）：HS256、RS256、PS256、ES256；壞例子 alg=none | `POST /api/lab/jwt/…` |
| `TokenService` | 亂數：SecureRandom、DRBG；壞例子 java.util.Random | `GET /api/lab/token/…` |
| `KeyMaterialService` | 從 PEM 檔載入 JWT 金鑰（私鑰放在 repo 是壞例子） | 沒有自己的端點 |
| `TlsInfoService` | 列出 SSL bundle 裡的憑證與 TLS 設定（只讀不算） | `GET /api/lab/tls` |

`GET /api/lab` 會列出所有類別與每個類別可用的名稱。名稱結尾 `-weak` 是壞例子、`-legacy` 是舊做法、`-bc` 是用 BouncyCastle 輕量 API 的寫法。

## 四種標記

程式、`application.yml`、腳本的註解，以及標準答案的 `description`，只用這四種標記：

| 標記 | 意思 | 例子 |
|---|---|---|
| `[好例子]` | 現行建議的做法，量子電腦也只讓強度減半 | AES-256-GCM、SHA-256、HMAC-SHA256、PBKDF2、SecureRandom |
| `[可接受·量子脆弱]` | 現在安全，但量子電腦可破解，要排進後量子遷移計畫 | RSA-2048 以上、ECDSA、Ed25519、ECDH、X25519、TLS 1.3（傳統金鑰交換） |
| `[舊做法]` | 還沒被破解，但不建議，新系統不要用 | AES-CBC、HmacSHA1、TLS 1.2 |
| `[壞例子·故意]` | 現在就不合格，是故意放的 | MD5、SHA-1、DES、3DES、AES-ECB、固定 IV、RSA-1024、寫死的金鑰、alg=none |

每一處密碼學用法旁邊的註解格式固定：

```java
// [壞例子·故意] SHA1withRSA＋RSA-1024：SHA-1 已有實際碰撞、金鑰太短
//   標準答案：SIG-RSA-SHA1　pipeline 判定：違規
```

- **標準答案**：`expected-inventory.json` 裡對應的 `id`。「無（原因）」表示沒有對應的項目。
- **pipeline 判定**：規則 `cbom/policy/cbom.rego` 會把它判成哪一級。等級有六種，由重到輕：違規、量子脆弱、警告、無法判斷、通過、資訊；只有「違規」會讓 pipeline 失敗。
  - 「無（找不到）」＝盤點工具根本看不到，所以沒有判定。
  - 「待確認」＝判定取決於掃描工具實際回報了什麼（例如金鑰長度有沒有被掃到、秘密掃描有沒有命中），還沒對照實際的報告。（2026-11-13 已用工作 cbom-webapp 含執行期的那次報告全部對過，目前沒有「待確認」；加新例子時先寫待確認，跑過 pipeline 再填。）
  - 其他的判定是**依規則檔推得的**（演算法屬於哪個家族就判哪一級），同樣還沒有逐項對照實際的報告。

**標記和判定不一定相同**，這正是這個 app 要教的事：

| 例子 | 標記 | pipeline 判定 | 為什麼不同 |
|---|---|---|---|
| AES-ECB、AES-CBC 配固定 IV | 壞例子 | 通過 | 規則只看演算法是 AES，不看模式；CBOM 也不記錄 IV 怎麼來的 |
| RSA PKCS#1 v1.5 加密 | 壞例子 | 量子脆弱 | 規則只看 RSA 與金鑰長度，不看填充方式 |
| HmacSHA1 | 舊做法 | 警告 | 規則 `hmac-sha1`：HMAC 不受 SHA-1 碰撞影響，NIST 仍允許；但 SHA-1 在淘汰名單上，建議改 HMAC-SHA256 |
| java.util.Random、alg=none | 壞例子 | 無（找不到） | 沒有經過密碼學 API，工具看不到 |

上表的「pipeline 判定」是 2026-11-12 依當時的規則推得的現況。標準答案的 `expectedLevel` 寫的是**應該**判成哪一級：
AES-ECB 與 RSA PKCS#1 v1.5 加密應該是違規（規則要補上這兩條），所以這兩項的 `expectedLevel` 是 `violation`；
規則補上之後，程式註解裡這兩處的「pipeline 判定」要跟著改。
固定 IV、java.util.Random、alg=none 這幾類則是盤點工具本來就看不出來，只能靠程式碼審查。

## expected-inventory.json 的欄位

最外層是 `description`（這個檔的說明）與 `items`（49 項）。每一項：

| 欄位 | 意義 |
|---|---|
| `id` | 這一項的代號，程式註解的「標準答案：」寫的就是它。開頭表示類別：`PWD` 密碼雜湊、`HASH` 雜湊、`MAC`、`SYM` 對稱式、`SIG` 簽章、`KEX` 金鑰交換、`KEM` 金鑰包裝、`KDF` 金鑰衍生、`RNG` 亂數、`JWT`、`LIB` 函式庫、`CERT` 憑證、`KEY` 金鑰檔、`SECRET` 寫死的秘密、`JRE` 執行環境映像、`TLS` |
| `layer` | 這項資產在哪一層（下表） |
| `expectedLevel` | **照規則的標準，這一項應該被判成哪一級**（不是現在實際判成哪一級；兩者不同就是要抓的問題）。七種值見下面「expectedLevel 的七種值」 |
| `description` | 給人看的說明；壞例子與舊做法開頭有標記 |
| `match` | 不分大小寫的正規表示式：拿 CBOM 來對答案時，CBOM 裡有元件的名稱符合它，這一項就算「找到」 |
| `kind` | `match` 要比對哪一種元件。沒寫＝密碼學資產（cryptographic-asset）；`library`＝函式庫（比對 `group:name`）；`any`＝任何元件的名稱與位置 |
| `assetType` | 只比對某一類密碼學資產（目前只有 `protocol`，用在 TLS 版本） |
| `locationMatch` | 元件被找到的位置也要符合這個正規表示式（目前只用在 JWT：呼叫者要是 `nimbusds`，才算是 JWT 用的，而不是別處的同名演算法） |
| `endpoints` | 對應的 `類別/演算法`（也就是 `/api/lab/{類別}/{演算法}`）。只有 L1 的項目有。`CryptoLabInventoryConsistencyTest` 檢查這個欄位 |
| `note` | 補充：哪種工具看得到、看不到，或判讀時要注意的事 |

### expectedLevel 的七種值

前六種就是 `cbom/policy/cbom.rego` 的六個等級，第七種是標準答案自己的：

| 值 | 中文 | 什麼時候填 |
|---|---|---|
| `violation` | 違規 | 已破解的演算法或雜湊（MD5、SHA-1、DES、3DES）、金鑰太短（RSA／DH 不到 2048、橢圓曲線不到 224）、過期的憑證、舊的 TLS、私鑰放在原始碼庫、寫死的金鑰或秘密、區塊加密用 ECB 模式、RSA 用 PKCS#1 v1.5 填充做加密或金鑰傳輸 |
| `quantum-vulnerable` | 量子脆弱 | 非對稱（RSA、ECDSA、Ed25519、ECDH、X25519、DH）而且長度足夠；TLS 1.3 沒有後量子金鑰交換 |
| `warning` | 警告 | TLS 1.2 |
| `unknown` | 無法判斷 | 要人看的（例如映像裡被秘密掃描命中的檔案，常是誤判） |
| `pass` | 通過 | 對稱式、雜湊、金鑰衍生、亂數，強度足夠 |
| `info` | 資訊 | 只是盤點：函式庫、映像裡的密碼設定檔 |
| `not-detectable` | 預期找不到 | 盤點工具本來就看不到的（見「pipeline 找不到的 3 項」） |

填的原則：

- 一項對到好幾個元件時，填其中**最重**的那一級（例如 `KEX-DH` 同時含 dh-2048 與 dh-1024-weak，填 `violation`）。
- 工具找得到元件、但看不出那個壞處的（例如 `SYM-AES-CBC` 的固定 IV、`RNG` 裡的 java.util.Random），填工具看得到的那部分應得的等級，並在 `note` 寫明「壞例子的部分工具看不出來，只能靠程式碼審查」。
- 簽章用的 RSA PKCS#1 v1.5（SHA256withRSA、RS256）不算違規，是量子脆弱。

### 怎麼對答案

比對由 `cbom-tools.jar` 的 `check-inventory` 做：

```bash
java -jar cbom-tools.jar check-inventory <cbom.json> <findings.json> <expected-inventory.json> <輸出.txt>
```

Jenkins 的工作 `cbom-webapp` 每次執行都會跑，結果在 `out/inventory-check.txt`。它回報兩種問題：「沒找到」與「找到但等級不對」。比對規則：

- `match`、`locationMatch` 是不分大小寫的正規表示式。
- `kind`：`crypto`（沒寫時的預設）只看密碼學資產；`library` 比套件座標（`group:name`）或名稱；`any` 連元件的位置一起比。
- `assetType` 有給的話，元件的類別要相同。
- 符合的元件可能不只一個：實際等級取其中**最重**的，再和 `expectedLevel` 比。
- `expectedLevel` 是 `not-detectable` 的項目，預期找不到。

本目錄的測試（`CryptoLabInventoryConsistencyTest`）只讀 `endpoints`，不讀上面這些欄位。

| `layer` | 是什麼 | 項數 | pipeline 的哪個步驟會找到（`cbom/webapp/webapp-collect.sh`） |
|---|---|---|---|
| `L1 source` | 程式裡用到的演算法 | 35 | `source`（原始碼掃描）；透過函式庫用的（JWT）與亂數要靠 `runtime` 的 JFR 錄製 |
| `L2 dependency` | 帶進來的密碼函式庫 | 4 | `build`（建置時產生的 SBOM） |
| `L3 config/keys` | 原始碼目錄裡的憑證、金鑰檔、寫死的秘密 | 5 | `files`（cbomkit-theia 掃目錄） |
| `L4 runtime image` | 執行環境映像裡的密碼設定與被命中的檔案 | 2 | `image`（cbomkit-theia 掃映像） |
| `L5 runtime TLS` | app 跑起來後實際開放的 TLS 版本與金鑰交換群組 | 3 | `runtime`（testssl.sh） |

L1–L5 與步驟的對應是從兩邊的內容推得的；標準答案是 2026-11-11 從舊專案搬來的，`layer` 的名稱沿用舊的分層，和現在 pipeline 的步驟名稱不是同一套。

注意兩件事：

- **一項可能同時涵蓋好例子與壞例子**：`RNG`（SecureRandom 與 java.util.Random）、`SYM-AES-CBC`（隨機 IV 與固定 IV）、`KEX-DH`（2048 與 1024）、`HASH-MD5`／`HASH-SHA1`（一般雜湊與密碼雜湊）。這一項「找到」不代表壞例子被分辨出來。
- `JWT-*` 的 `layer` 寫 `L1 source`，但 `note` 說原始碼掃描看不到：它們是程式用到的演算法（所以歸 L1），只是要靠執行期才找得到。

## pipeline 找不到的 4 項

這條 pipeline 找到 45／49（2026-11-14 實測，含執行期；不含執行期是 37）。找不到的 4 項在標準答案裡的 `expectedLevel` 是 `not-detectable`，每次建置的實際結果看 `out/inventory-check.txt`：

| id | 是什麼 | 為什麼找不到 |
|---|---|---|
| `PWD-BCRYPT` | bcrypt（Spring 的 `BCryptPasswordEncoder`） | Spring 的純 Java 實作，不經過 JDK 的 JCA；程式裡沒有演算法字串，原始碼掃描與 JFR 都看不到 |
| `PWD-ARGON2` | Argon2id（Spring 的 `Argon2PasswordEncoder`） | Spring 再呼叫 BouncyCastle 輕量 API，同樣不經過 JCA |
| `JWT-NONE` | 沒有簽章的 JWT（alg=none） | 沒有用到任何演算法，就沒有 CBOM 元件；只能靠程式碼審查或 SAST |
| `KEM-RSA-PKCS1` | RSA 加密用 PKCS#1 v1.5 填充（`RSA/ECB/PKCS1Padding`） | 原始碼掃描把這個呼叫點回報成 `RSA-2048`，沒有填充方式；JFR 也沒錄到。規則 `rsa-pkcs1-encryption` 已經寫好，等工具回報得出填充才會觸發 |

## 怎麼加一個新例子

以「在雜湊類加一個 SHA-384」為例。要改四個地方，**程式、標準答案、測試要一起改**，否則 `./mvnw -B verify` 會失敗。

1. **程式**：`src/main/java/com/example/cryptolab/crypto/HashingService.java`
   - 在 `ALGORITHMS` 清單加上名稱（好例子直接取名，例如 `sha384`；壞例子結尾加 `-weak`，舊做法加 `-legacy`）。
   - 在 `switch` 加一個 `case`。**直接寫出 `getInstance("SHA-384")`，不要抽成共用的 helper**：原始碼掃描靠呼叫點上的字串常數認演算法。
   - `case` 上面加兩到三行註解（格式見「四種標記」）：標記、原因、標準答案的 id、pipeline 判定。判定不確定就寫「待確認」。
   - 檔頭的例子清單也加上這個名稱。
2. **標準答案**：`expected-inventory.json`
   - 已經有對應的項目（同一個演算法）：在那一項的 `endpoints` 加上 `"hash/sha384"`。
   - 沒有：加一項，填 `id`、`layer`（程式裡的演算法是 `L1 source`）、`expectedLevel`、`description`（壞例子開頭寫 `[壞例子·故意]`）、`match`、`endpoints`。
   - **填 `expectedLevel`**：照「expectedLevel 的七種值」的標準，寫這一項應該被判成哪一級。加進既有的項目時，也要看那一項的 `expectedLevel` 還是不是最重的那一級（例如在通過的項目裡加了一個違規的例子，就要改成 `violation`，或另開一項）。
   - `match` 要小心不要誤中別的演算法（例如 `SHA-?1(?![0-9])` 後面那段的意思是「1 的後面不能再接數字」）。
3. **測試**：
   - `src/test/java/com/example/cryptolab/CryptoLabApplicationTests.java`：只有雜湊類要改，在 `HASH_BITS` 加上新演算法的輸出位元數（`Map.entry("sha384", 384)`）。其他類別的測試直接走 `ALGORITHMS` 清單，不用改。
   - `CryptoLabControllerTest`、`CryptoLabInventoryConsistencyTest` 不用改：它們從 `LabCategories` 讀清單。後者會檢查第 2 步有沒有做。
4. **`scripts/exercise-api.sh`**：不用改。它向 `GET /api/lab` 要清單，新的演算法會自動被打到。

如果是**新的類別**（新的 Service），另外要：

5. 新的 Service 放一個公開的靜態清單 `ALGORITHMS`（或 `KINDS`）。
6. `src/main/java/com/example/cryptolab/web/LabCategories.java`：在 `ALL` 加一行，`values` 直接引用 Service 的清單（不要另外抄一份）。
7. `src/main/java/com/example/cryptolab/web/CryptoLabController.java`：加建構子參數與一個 endpoint 方法。
8. `CryptoLabApplicationTests.java`：加一個測試，走新 Service 的清單、檢查結果正確。
9. `GET /api/lab` 目錄的 key 格式（「方法 空白 路徑」）不能改，`scripts/exercise-api.sh` 靠它解析。

如果加的不是演算法，而是**憑證、金鑰檔或設定**（L2–L5）：改 `scripts/generate-key-material.sh` 或 `application.yml`，在 `expected-inventory.json` 加一項（沒有 `endpoints`，但一樣要填 `expectedLevel`）。這類項目測試不會檢查，要自己核對。

改完之後：跑建置與測試；要讓 Jenkins 用到新的內容，再跑一次 `bash cbom/webapp/lab.sh up`。

## 建置與測試

```bash
./mvnw -B verify
```

Windows 這台沒有裝 JDK，平常不在本機跑：實際是在 Jenkins 的工作 `cbom-webapp` 裡跑（`cbom/webapp/webapp-collect.sh` 的 `build` 步驟，環境用 `bash cbom/webapp/lab.sh up` 建立，細節見 `cbom/webapp/README.md`）。

三個測試各保證什麼：

| 測試 | 保證 |
|---|---|
| `CryptoLabApplicationTests` | 每個例子（好的與壞的）都真的算得出正確的結果；`/api/secure/me` 只收 RS256 的 JWT |
| `web/CryptoLabControllerTest` | 每個端點回 200、名稱錯誤回 400、`GET /api/lab` 目錄的格式沒變 |
| `CryptoLabInventoryConsistencyTest` | 每個演算法端點都寫進了標準答案的 `endpoints`，標準答案也沒有多出不存在的端點；每個 Service 的清單都登記在 `LabCategories`。**只管有 `endpoints` 的 35 項**，其餘 14 項不檢查 |

測試不判斷好壞：壞例子也要「跑得動」，盤點工具在執行期才錄得到它。

## 腳本

| 腳本 | 什麼時候用 |
|---|---|
| `scripts/exercise-api.sh <網址>` | app 跑起來之後把每個端點打一次。pipeline 的 `runtime` 步驟會叫它，平常不用自己跑 |
| `scripts/generate-key-material.sh` | 憑證快到期（有效期 825 天）或要換金鑰類型時才跑；會覆蓋 `src/main/resources/crypto/` 的所有檔案。需要 openssl 與 keytool |

兩支都照 `docs/journey-src/tools/COMMAND-STYLE.md` 寫；改完跑：

```bash
node docs/journey-src/tools/lint-commands.js cbom/app/scripts/generate-key-material.sh cbom/app/scripts/exercise-api.sh
```
