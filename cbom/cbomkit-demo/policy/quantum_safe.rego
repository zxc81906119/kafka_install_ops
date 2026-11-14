# ============================================================================
# 「接 OPA 的 CBOMkit」（網頁 B）用的規則：每個密碼學資產判成四種結果之一
#
# CBOMkit 打開一份 CBOM 時，把整份 CBOM 送給 OPA，OPA 用這個檔案判斷，回傳每個資產一筆：
#   rule    哪一條規則判的（網頁上 Compliance 那一欄顯示的文字）
#   result  結果，只能是下面四種（CBOMkit 2.3.0 只認得這四個字）
#
#   result 的值            網頁上顯示         顏色
#   quantum-safe           Quantum Safe       綠
#   quantum-vulnerable     Not Quantum Safe   黃
#   na                     Not Applicable     灰
#   unknown                Unknown            藍
#
# ---------------------------------------------------------------------------
# 判斷的順序：每個資產由上往下看，第一條符合的就決定，後面的不再看（在檔案最下面的 decision）
#
#   順序  規則                 符合的條件                                      結果
#   1     PQC                  名稱是後量子演算法（ML-KEM、ML-DSA…）           quantum-safe
#   2     BROKEN               名稱是已被破解的（MD5、SHA-1、DES、RC4、ECB…）  na
#   3     QUANTUM-VULNERABLE   是演算法，而且是非對稱的（RSA、ECDSA、DH…）     quantum-vulnerable
#   4     SYMMETRIC            是演算法，而且是對稱加密或雜湊（AES、SHA-256…） quantum-safe
#   5     CERT                 是憑證，簽章演算法是非對稱的                    quantum-vulnerable
#   6     KEY                  是金鑰，而且是非對稱的                          quantum-vulnerable
#   7     TLS                  是協定，名稱有 tls                              quantum-vulnerable
#   8     UNKNOWN              以上都不符合                                    unknown
#
# 要改某一條的結果：到最下面的 decision 找那一條，改 "result": 後面的字（只能用上面四種）。
# 例：把第 2 條 BROKEN 的 "na" 改成 "quantum-vulnerable"，已被破解的演算法在網頁上就從灰色變黃色。
# 要改「哪些名稱算已被破解／非對稱／後量子」：改 names.rego。
#
# 改完之後：bash cbom/cbomkit-demo/demo.sh reload（約 20 秒），再重新整理網頁 B。
# 測試：quantum_safe_test.rego（指令在 ../README.md 的「維護」）。
#
# 兩個限制（CBOMkit 的）：
#   - package 必須是 policies.quantum_safe（網頁一律用政策名稱 quantum_safe）。
#   - 這個 package 的「每一個」輸出都會被當成結果清單，所以裡面只能有 findings 這一個值；
#     其他要用到的值（assets、by_ref）放在 lib.rego。函式（有括號的）不算輸出，可以留在這裡。
#
# 和 pipeline 的規則（cbom/policy/cbom.rego，六級）是分開的兩份：這份只回答「會不會被量子電腦破解」。
# ============================================================================
package policies.quantum_safe

import data.lib.cbomkit.assets
import data.lib.cbomkit.by_ref
import data.lib.cbomlab.names
import rego.v1

# ---------- 讀資產上的資料（c 是一個資產）----------

# name_of(c)：資產的名稱，轉成小寫。
# 掃描工具把金鑰命名成 "key@<一串編號>"：編號裡的 "ec"、"dh" 會被誤認成演算法，所以比對前先拿掉
name_of(c) := regex.replace(lower(object.get(c, "name", "")), `@[0-9a-f-]{36}$`, "")

# primitive(c)：演算法的種類（CBOM 的欄位）：pke 公鑰加密、signature 簽章、hash 雜湊、block-cipher 區塊加密…
primitive(c) := object.get(c, ["cryptoProperties", "algorithmProperties", "primitive"], "")

# asset_type(c)：資產是哪一類：algorithm 演算法、certificate 憑證、related-crypto-material 金鑰、protocol 協定
asset_type(c) := object.get(c, ["cryptoProperties", "assetType"], "")

# ---------- 分類（用名稱判斷的細節在 names.rego）----------
# 同一個名字寫好幾行＝「或」：任何一行成立就算

# 後量子演算法
pqc(c) if names.pqc(name_of(c))

# 已被破解或不安全：MD5 類、SHA-1、不安全的加密（DES、RC4…）、ECB 模式
broken(c) if names.broken_hash(name_of(c))

broken(c) if names.sha1(name_of(c))

broken(c) if names.weak_cipher(name_of(c))

broken(c) if names.ecb_mode(name_of(c), name_of(c))

# 非對稱（量子電腦可破解）：種類是公鑰加密、簽章、金鑰交換，或名稱看得出來（RSA、ECDSA…）
asymmetric(c) if primitive(c) in {"pke", "signature", "key-agree", "kem"}

asymmetric(c) if names.quantum_vulnerable(name_of(c))

# 對稱加密、雜湊這一類（量子電腦只讓強度減半）
symmetric(c) if primitive(c) in {"block-cipher", "stream-cipher", "ae", "hash", "mac", "kdf", "drbg", "xof"}

# cert_signature(c)：憑證 c 的簽章演算法（憑證上記的是另一個資產的編號，用 by_ref 找到那個資產）
cert_signature(c) := by_ref[object.get(c, ["cryptoProperties", "certificateProperties", "signatureAlgorithmRef"], "")]

# ---------- 判斷：由上往下，第一條符合的決定（else 就是「不然的話」）----------
# 每一條的格式：{"rule": 顯示在網頁上的說明, "result": 結果} if { 條件（每一行都要成立） }
decision(c) := {"rule": "PQC：後量子演算法", "result": "quantum-safe"} if {
	# 1 → Quantum Safe（綠）
	pqc(c)
} else := {"rule": "BROKEN：已被破解或不安全，應該立即汰換（CBOMkit 沒有「已破解」這一級，所以放在 Not Applicable）", "result": "na"} if {
	# 2 → Not Applicable（灰）。demo 時把上一行行尾的 "na" 改成 "quantum-vulnerable"，就變成黃色
	broken(c)
} else := {"rule": "QUANTUM-VULNERABLE：非對稱演算法，可被量子電腦破解", "result": "quantum-vulnerable"} if {
	# 3 → Not Quantum Safe（黃）
	asset_type(c) == "algorithm"
	asymmetric(c)
} else := {"rule": "SYMMETRIC：128-bit 以上的對稱演算法與雜湊，NIST 認為至少達到 PQC 安全類別 1", "result": "quantum-safe"} if {
	# 4 → Quantum Safe（綠）
	asset_type(c) == "algorithm"
	symmetric(c)
} else := {"rule": "CERT：憑證的簽章演算法是非對稱的", "result": "quantum-vulnerable"} if {
	# 5 → Not Quantum Safe（黃）
	asset_type(c) == "certificate"
	asymmetric(cert_signature(c))
} else := {"rule": "KEY：非對稱金鑰", "result": "quantum-vulnerable"} if {
	# 6 → Not Quantum Safe（黃）
	asset_type(c) == "related-crypto-material"
	asymmetric(c)
} else := {"rule": "TLS：TLS 1.2 / 1.3 目前的金鑰交換都是傳統演算法", "result": "quantum-vulnerable"} if {
	# 7 → Not Quantum Safe（黃）
	asset_type(c) == "protocol"
	regex.match(`tls`, name_of(c))
} else := {"rule": "UNKNOWN：規則沒有涵蓋", "result": "unknown"}

# 8（上面最後一行）→ Unknown（藍）：前面七條都不符合

# ---------- 輸出：每個密碼學資產一筆（判斷結果，加上是哪個資產）----------
findings contains f if {
	some c in assets
	d := decision(c)
	f := object.union(d, {"bom-ref": c["bom-ref"], "property": "name", "value": c.name})
}
