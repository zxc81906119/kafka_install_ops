# ============================================================================
# 密碼學資產合規規則（pipeline 與操作機用的那一份）
#
# 輸入：cbom-tools 產生的 CBOM（一個 JSON 檔，裡面的 components 是一個一個「元件」：
#       演算法、金鑰、憑證、TLS 端點、設定檔、函式庫…）
# 輸出：每個元件至少一筆「發現」（finding）：哪個元件、判成哪一級、哪條規則、原因、依據
# 執行：opa eval --data policy/ --input cbom.json --format json 'data.cbom.report'
# 測試：opa test policy/        （cbom_test.rego；改了規則一定要先跑）
#
# ---------------------------------------------------------------------------
# 等級有六種，由重到輕（只有「違規」會讓 pipeline 失敗）
#
#   violation           違規        現在就不合格，和量子電腦無關：已破解的演算法、太短的金鑰、
#                                   舊的 TLS、過期的憑證、寫死的金鑰
#   quantum-vulnerable  量子脆弱    現在安全，但量子電腦可破解；NIST IR 8547：2030 年後棄用、2035 年後禁用
#   warning             警告        建議改善
#   unknown             無法判斷    規則不認得，要人看
#   pass                通過
#   info                資訊        只是盤點（例如帶了哪些密碼函式庫）
#
# ---------------------------------------------------------------------------
# 沒學過 Rego 也看得懂：一條規則怎麼讀
#
#   # 判定：違規
#   # 條件：演算法或金鑰屬於「已破解」的家族
#   findings contains finding(c, "violation", "broken-algorithm",          ← 產生一筆發現：等級、規則名稱、
#       sprintf("%s 已不安全，不可再用", [family(c)]), basis_strength) if {     原因（%s 會換成後面的值）、依據
#       some c in keyed_assets                                             ← 對每一個「演算法或金鑰」元件 c
#       family(c) in broken_families                                       ← c 的家族在已破解名單裡
#   }
#
#   1. 大括號裡的每一行都是條件，全部成立（AND）才會產生這筆發現。
#   2. 「或」（OR）的寫法是把同一個名字寫兩次（例如下面的 weak_key 有兩段：RSA 類太短，或橢圓曲線類太短）。
#   3. not 是「不成立」。in 是「在這個名單裡」。
#   4. 一個元件可以同時中好幾條規則（例如 RSA-1024 配 MD5：金鑰太短、雜湊已破解各一筆）。
#   5. 沒有先後順序：規則寫在檔案的哪裡都一樣。
#
# 元件上的資料從哪裡來：cbom-tools 在每個元件加了「cbom:」開頭的屬性，規則用 prop(c, "名稱") 讀：
#   family（家族，例如 RSA、AES、SHA-1）、keySize（金鑰位元數）、digest（搭配的雜湊）、
#   mode（區塊加密的模式：ECB、CBC、GCM…）、padding（填充：PKCS1、OAEP、PKCS5…；這兩個看得出來才有）、
#   tlsVersion、source（從哪一種原料來的）、kind（檔案類的元件是哪一種）…
#
# ---------------------------------------------------------------------------
# 常見的修改
#
#   調門檻        改數字就好：例如 weak_key 的 2048、kdf-iterations 的 10000
#   加減名單      改「名單」那一節：例如把某個家族加進 broken_families
#   改等級        把規則裡的 "warning" 換成 "violation"（或反過來）
#   加一條規則    複製一條最像的，改規則名稱、原因、條件；再到 cbom_test.rego 加一個測試
#
# 依據：NIST IR 8547（後量子遷移時程）、FIPS 203／204／205（ML-KEM、ML-DSA、SLH-DSA）、
#       NIST SP 800-131A Rev.2（演算法與金鑰長度）、NIST SP 800-52 Rev.2（TLS）、NIST SP 800-38A（區塊加密的模式）。
# 已確認的門檻（2026-11-11）：TLS 1.2 是警告、AES-128 可接受、量子脆弱不讓 pipeline 失敗。
# ============================================================================
package cbom

# ============================================================================
# 一、名單（要調整判斷範圍，多半改這裡）
# ============================================================================

# 量子電腦可破解的（非對稱：公鑰加密、簽章、金鑰交換）
quantum_vulnerable_families := {"RSA", "ECDSA", "EdDSA", "ECDH", "EC", "DH", "DSA"}

# 後量子演算法（NIST 標準）與混合式
quantum_safe_families := {"ML-KEM", "ML-KEM-hybrid", "ML-DSA", "SLH-DSA"}

# 已被破解或不安全的
broken_families := {"MD5", "MD2", "MD4", "SHA-1", "DES", "3DES", "RC4"}

# 對稱式、雜湊、金鑰衍生：量子電腦只讓強度減半（Grover），長度夠就可以
symmetric_families := {"AES", "ChaCha20", "Poly1305", "SHA-2", "SHA-3", "HMAC", "HKDF", "PBKDF2", "MGF1", "TLS-PRF"}

# 區塊加密（有 ECB、CBC、GCM 這些模式的）。RSA 不在這裡：JCA 的「RSA/ECB/…」只是寫法，RSA 沒有區塊模式
block_cipher_families := {"AES", "DES", "3DES"}

# 已不安全的雜湊（用在簽章或憑證上也算）
broken_digests := {"MD5", "SHA-1"}

# 報告上「依據」那一欄的文字
basis_pqc := "NIST IR 8547"

basis_strength := "NIST SP 800-131A Rev.2"

basis_tls := "NIST SP 800-52 Rev.2"

# 量子脆弱的原因（好幾條規則共用同一句）
reason_quantum := "量子電腦可破解（Shor 演算法）：2030 年後棄用、2035 年後禁用，要排進遷移計畫"

# ============================================================================
# 二、小工具（讀元件上的資料；平常不用改）
# ============================================================================

# prop(c, "family")：讀元件 c 的屬性 cbom:family；同名有多個值時取第一個。沒有這個屬性時，用到它的條件就不成立
prop(component, name) := value if {
	values := [p.value | some p in component.properties; p.name == concat("", ["cbom:", name])]
	count(values) > 0
	value := values[0]
}

# has_prop(c, "family")：元件 c 有沒有這個屬性
has_prop(component, name) if {
	some p in component.properties
	p.name == concat("", ["cbom:", name])
}

# number_prop(c, "keySize")：把屬性當數字讀（要比大小時用）
number_prop(component, name) := to_number(prop(component, name))

# settings(c, "ssl.enabled.protocols")：設定檔元件裡，鍵的結尾符合的每一個設定，回傳 [鍵, 值]
# （屬性名稱是 cbom:setting:<設定鍵>；同一個設定在不同 listener 會有不同的前綴，所以比結尾）
settings(component, suffix) := [[key, p.value] |
	some p in component.properties
	startswith(p.name, "cbom:setting:")
	key := substring(p.name, count("cbom:setting:"), -1)
	endswith(key, suffix)
]

# asset_type(c)：元件是哪一類。密碼學資產回 algorithm／related-crypto-material（金鑰）／certificate／protocol；
# 其他元件回它的 type（file、library）
asset_type(component) := component.cryptoProperties.assetType if component.type == "cryptographic-asset"

asset_type(component) := component.type if component.type != "cryptographic-asset"

# family(c)：元件的家族（RSA、AES、SHA-1…；cbom-tools 不認得的是 "unknown"）
family(component) := prop(component, "family")

# finding(...)：組出一筆發現
finding(component, level, rule, reason, basis) := {
	"bom-ref": component["bom-ref"],
	"name": component.name,
	"assetType": asset_type(component),
	"level": level,
	"rule": rule,
	"reason": reason,
	"basis": basis,
}

# ---- 元件分組：規則裡寫「some c in certificates」就是「對每一張憑證 c」 ----

# 演算法與金鑰（兩種用同一套規則判斷）
keyed_types := {"algorithm", "related-crypto-material"}

keyed_assets contains c if {
	some c in input.components
	asset_type(c) in keyed_types
}

# 憑證
certificates contains c if {
	some c in input.components
	asset_type(c) == "certificate"
}

# 協定（TLS 端點、SASL 機制）
protocols contains c if {
	some c in input.components
	asset_type(c) == "protocol"
}

# ---- 好幾條規則共用的判斷 ----

# 金鑰太短（和量子無關，現在就不合格）：RSA、DSA、DH 不到 2048 位元
weak_key(component) if {
	family(component) in {"RSA", "DSA", "DH"}
	number_prop(component, "keySize") < 2048
}

# 或：橢圓曲線類不到 224 位元
weak_key(component) if {
	family(component) in {"ECDSA", "ECDH", "EdDSA", "EC"}
	number_prop(component, "keySize") < 224
}

# HMAC 搭 SHA-1（HmacSHA1）：判警告而不是違規
hmac_sha1(component) if {
	family(component) == "HMAC"
	prop(component, "digest") == "SHA-1"
}

# ============================================================================
# 三、演算法、金鑰
# ============================================================================

# 判定：違規
# 條件：家族在「已破解」名單裡（MD5、SHA-1、DES、3DES、RC4…）
findings contains finding(c, "violation", "broken-algorithm",
	sprintf("%s 已不安全，不可再用", [family(c)]), basis_strength) if {
	some c in keyed_assets
	family(c) in broken_families
}

# 判定：違規
# 條件：本身沒問題，但搭配的雜湊是 MD5 或 SHA-1（例如 SHA1withRSA、HmacMD5）。HMAC 搭 SHA-1 例外（下一條）
findings contains finding(c, "violation", "broken-digest",
	sprintf("搭配的雜湊 %s 已不安全", [prop(c, "digest")]), basis_strength) if {
	some c in keyed_assets
	prop(c, "digest") in broken_digests
	not hmac_sha1(c)
}

# 判定：警告
# 條件：HMAC 搭 SHA-1（HmacSHA1）。SHA-1 的弱點是碰撞，HMAC 不靠抗碰撞，NIST 仍允許；但 SHA-1 在淘汰名單上，新系統不要用
#       HmacMD5、PBKDF2WithHmacSHA1 不在這個例外裡（照上一條判違規）
findings contains finding(c, "warning", "hmac-sha1",
	"HMAC-SHA1 目前仍可用（HMAC 不受 SHA-1 碰撞影響），但 SHA-1 已在淘汰名單，建議改 HMAC-SHA256", basis_strength) if {
	some c in keyed_assets
	hmac_sha1(c)
}

# 判定：違規
# 條件：金鑰太短（上面的 weak_key：RSA 類不到 2048、橢圓曲線類不到 224）
findings contains finding(c, "violation", "weak-key",
	sprintf("%s 金鑰 %s 位元太短", [family(c), prop(c, "keySize")]), basis_strength) if {
	some c in keyed_assets
	weak_key(c)
}

# 判定：違規
# 條件：區塊加密（AES、DES、3DES）用 ECB 模式。RSA/ECB/… 不會中（RSA 不在 block_cipher_families）
findings contains finding(c, "violation", "ecb-mode",
	"ECB 模式：相同的明文區塊加密後相同，會洩漏資料的樣式", "NIST SP 800-38A") if {
	some c in keyed_assets
	family(c) in block_cipher_families
	prop(c, "mode") == "ECB"
}

# 判定：違規（原本的量子脆弱判定照舊，兩筆並存）
# 條件：RSA 用來加密或傳輸金鑰（primitive 是 pke），而且填充是 PKCS#1 v1.5。
#       簽章用的 PKCS#1 v1.5（SHA256withRSA 這類，primitive 是 signature）不會中
findings contains finding(c, "violation", "rsa-pkcs1-encryption",
	"RSA 用 PKCS#1 v1.5 填充做加密或金鑰傳輸：2023 年底後禁用，改用 OAEP", basis_strength) if {
	some c in keyed_assets
	family(c) == "RSA"
	c.cryptoProperties.algorithmProperties.primitive == "pke"
	prop(c, "padding") == "PKCS1"
}

# 判定：量子脆弱
# 條件：家族在「量子電腦可破解」名單裡，而且金鑰不算太短（太短的已經判成違規，不重複列）
findings contains finding(c, "quantum-vulnerable", "quantum-vulnerable-algorithm", reason_quantum, basis_pqc) if {
	some c in keyed_assets
	family(c) in quantum_vulnerable_families
	not weak_key(c)
}

# 判定：通過
# 條件：後量子演算法 ML-KEM、ML-DSA、SLH-DSA
findings contains finding(c, "pass", "post-quantum-algorithm", "後量子演算法（NIST 標準）", "FIPS 203／204／205") if {
	some c in keyed_assets
	family(c) in {"ML-KEM", "ML-DSA", "SLH-DSA"}
}

# 判定：通過
# 條件：混合式金鑰交換（例如 X25519MLKEM768）
findings contains finding(c, "pass", "hybrid-key-exchange",
	"混合式金鑰交換（傳統＋ML-KEM）：其中一個被破解仍然安全", "FIPS 203、NIST IR 8547") if {
	some c in keyed_assets
	family(c) == "ML-KEM-hybrid"
}

# 判定：通過（原因裡提醒新系統用 AES-256）
# 條件：AES，金鑰 128 位元
findings contains finding(c, "pass", "symmetric-128", "AES-128 可接受（量子安全等級 1）；新系統建議 AES-256", basis_pqc) if {
	some c in keyed_assets
	family(c) == "AES"
	number_prop(c, "keySize") == 128
}

# 判定：通過
# 條件：家族在「對稱式、雜湊、金鑰衍生」名單裡（AES-128 已經在上一條處理，這裡排除）
findings contains finding(c, "pass", "symmetric-ok", "對稱式、雜湊與金鑰衍生不受 Shor 演算法影響，強度足夠", basis_pqc) if {
	some c in keyed_assets
	family(c) in symmetric_families
	not aes_128(c)
}

aes_128(c) if {
	family(c) == "AES"
	number_prop(c, "keySize") == 128
}

# 判定：警告
# 條件：PBKDF2 的迭代次數不到 10000
findings contains finding(c, "warning", "kdf-iterations",
	sprintf("PBKDF2 迭代次數 %s 偏低（建議 10000 以上）", [prop(c, "iterations")]), "NIST SP 800-132") if {
	some c in input.components
	asset_type(c) == "algorithm"
	family(c) == "PBKDF2"
	number_prop(c, "iterations") < 10000
}

# 判定：無法判斷
# 條件：cbom-tools 認不出家族（family 是 "unknown"）。看過之後把它加進上面某個名單，就不會再出現
findings contains finding(c, "unknown", "unrecognized-algorithm", "規則不認得這個演算法，請人工判斷", "") if {
	some c in keyed_assets
	family(c) == "unknown"
}

# 判定：資訊
# 條件：原始碼掃描找到的金鑰或 salt，沒有家族
# （掃描只知道「這裡產生或設定了一把金鑰」與長度，不知道是哪個演算法的：判定看同一行的演算法元件）
findings contains finding(c, "info", "source-key-material",
	"程式裡產生或設定的金鑰或 salt：強度的判定看對應的演算法元件", "盤點") if {
	some c in input.components
	asset_type(c) == "related-crypto-material"
	prop(c, "source") == "source-code"
	not has_prop(c, "family")
}

# 判定：通過
# 條件：亂數產生器
findings contains finding(c, "pass", "random-generator", "亂數產生器：不受量子電腦影響", basis_pqc) if {
	some c in keyed_assets
	family(c) == "RNG"
}

# ============================================================================
# 四、秘密掃描找到的東西（cbomkit-theia；只有 web app 這類有原始碼或映像的對象才有）
# ============================================================================

# 判定：違規
# 條件：原始碼庫裡找到私鑰檔
findings contains finding(c, "violation", "private-key-in-repository",
	"私鑰放在原始碼庫裡：拿得到程式的人就拿得到金鑰", "NIST SP 800-57 Part 1") if {
	some c in input.components
	prop(c, "source") == "secret-scan"
	prop(c, "materialType") == "private-key"
}

# 判定：違規
# 條件：原始碼庫裡找到寫死的金鑰、密碼或 token
findings contains finding(c, "violation", "hardcoded-secret",
	"設定檔或程式裡寫死的金鑰或秘密", "NIST SP 800-57 Part 1") if {
	some c in input.components
	prop(c, "source") == "secret-scan"
	prop(c, "materialType") in {"key", "secret-key", "password", "token"}
}

# 判定：資訊
# 條件：找到 keystore 檔（看不出裡面是什麼；裡面的憑證另外列出）
findings contains finding(c, "info", "keystore-file", "keystore 檔：裡面的憑證另外列出", "盤點") if {
	some c in input.components
	prop(c, "source") in {"secret-scan", "image-scan"}
	prop(c, "materialType") == "unknown"
}

# 判定：無法判斷
# 條件：映像裡被秘密掃描命中的檔案（常是誤判，所以不直接判違規，請人確認）
findings contains finding(c, "unknown", "image-secret-candidate",
	"映像裡被秘密掃描命中的檔案：常是誤判（例如 java.security 的設定值），請人工確認", "") if {
	some c in input.components
	prop(c, "source") == "image-scan"
	prop(c, "materialType") in {"key", "secret-key", "password", "token", "private-key"}
}

# 判定：資訊
# 條件：映像裡的 OpenSSL 設定檔或信任庫
findings contains finding(c, "info", "image-crypto-file", "執行環境映像裡的密碼學設定或信任庫", "盤點") if {
	some c in input.components
	prop(c, "kind") in {"openssl-config", "trust-store"}
}

# ============================================================================
# 五、憑證
# ============================================================================

# 判定：違規
# 條件：到期日比現在早
findings contains finding(c, "violation", "certificate-expired",
	sprintf("憑證已過期（%s）", [c.cryptoProperties.certificateProperties.notValidAfter]), basis_strength) if {
	some c in certificates
	time.parse_rfc3339_ns(c.cryptoProperties.certificateProperties.notValidAfter) < time.now_ns()
}

# 判定：違規
# 條件：憑證的簽章用 MD5 或 SHA-1
findings contains finding(c, "violation", "certificate-broken-digest",
	sprintf("憑證簽章用的雜湊 %s 已不安全", [prop(c, "signatureDigest")]), basis_strength) if {
	some c in certificates
	prop(c, "signatureDigest") in broken_digests
}

# 判定：違規
# 條件：憑證的金鑰太短（上面的 weak_key）
findings contains finding(c, "violation", "certificate-weak-key",
	sprintf("憑證的 %s 金鑰 %s 位元太短", [family(c), prop(c, "keySize")]), basis_strength) if {
	some c in certificates
	weak_key(c)
}

# 判定：量子脆弱（原因最後會註明有效期有沒有跨過 2030／2035 年）
# 條件：憑證的金鑰家族在「量子電腦可破解」名單裡，而且金鑰不算太短
findings contains finding(c, "quantum-vulnerable", "certificate-quantum-vulnerable",
	sprintf("憑證金鑰 %s、簽章 %s：%s%s", [prop(c, "keyAlgorithm"), prop(c, "signatureAlgorithm"), reason_quantum, deadline_note(c)]),
	basis_pqc) if {
	some c in certificates
	family(c) in quantum_vulnerable_families
	not weak_key(c)
}

# 上一條原因最後那一句：到期日在 2035 年以後、在 2030 年以後、都不是（由上往下，第一個符合的算數）
deadline_note(c) := "；有效期跨過 2035 年（禁用），優先處理" if {
	time.parse_rfc3339_ns(c.cryptoProperties.certificateProperties.notValidAfter) >= time.parse_rfc3339_ns("2035-01-01T00:00:00Z")
} else := "；有效期跨過 2030 年（棄用），優先處理" if {
	time.parse_rfc3339_ns(c.cryptoProperties.certificateProperties.notValidAfter) >= time.parse_rfc3339_ns("2030-01-01T00:00:00Z")
} else := ""

# 判定：通過
# 條件：憑證用後量子簽章
findings contains finding(c, "pass", "certificate-post-quantum", "憑證使用後量子簽章", "FIPS 204／205") if {
	some c in certificates
	family(c) in quantum_safe_families
}

# ============================================================================
# 六、TLS（實際連到端點掃出來的，或執行期錄到的交握）
# ============================================================================

tls_version(c) := prop(c, "tlsVersion")

# 判定：違規
# 條件：伺服器接受 TLS 1.1、1.0 或 SSL
findings contains finding(c, "violation", "tls-obsolete-version",
	sprintf("%s 已禁用", [c.name]), basis_tls) if {
	some c in protocols
	tls_version(c) in {"1.1", "1.0", "SSLv3", "SSLv2"}
}

# 判定：警告
# 條件：伺服器接受 TLS 1.2
findings contains finding(c, "warning", "tls-1.2",
	"TLS 1.2 的金鑰交換只有傳統演算法，用不了後量子金鑰交換；規劃只留 TLS 1.3", "NIST SP 800-52 Rev.2、NIST IR 8547") if {
	some c in protocols
	tls_version(c) == "1.2"
}

# 判定：違規
# 條件：伺服器接受 3DES／IDEA 的 cipher suite
findings contains finding(c, "violation", "tls-3des", "伺服器接受 3DES／IDEA 的 cipher suite", basis_tls) if {
	some c in protocols
	prop(c, "tripleDesCiphers") == "offered"
}

# 判定：警告
# 條件：伺服器接受 CBC 類的舊 cipher suite
findings contains finding(c, "warning", "tls-cbc", "伺服器接受 CBC 類的舊 cipher suite，建議只留 AEAD（GCM、ChaCha20-Poly1305）", basis_tls) if {
	some c in protocols
	prop(c, "obsoleteCiphers") == "offered"
}

# 判定：通過
# 條件：TLS 1.3，而且伺服器支援後量子混合金鑰交換
findings contains finding(c, "pass", "tls-1.3-pqc",
	"TLS 1.3，伺服器支援後量子混合金鑰交換；實際用不用取決於用戶端也要支援", "FIPS 203、NIST IR 8547") if {
	some c in protocols
	tls_version(c) == "1.3"
	prop(c, "pqcKeyExchange") == "offered"
}

# 判定：量子脆弱
# 條件：TLS 1.3，但伺服器沒有後量子金鑰交換群組
findings contains finding(c, "quantum-vulnerable", "tls-1.3-classical",
	"TLS 1.3，但伺服器沒有後量子金鑰交換群組：連線內容可被「先蒐集、日後解密」", basis_pqc) if {
	some c in protocols
	tls_version(c) == "1.3"
	prop(c, "pqcKeyExchange") == "none"
}

# 判定：資訊
# 條件：執行期（JFR）錄到的 TLS 1.3 交握（看得到版本與 cipher suite，看不到金鑰交換群組，所以不判等級）
findings contains finding(c, "info", "tls-1.3-observed",
	sprintf("錄製期間實際完成的交握：%s", [prop(c, "cipherSuite")]), "執行期證據（JFR）") if {
	some c in protocols
	tls_version(c) == "1.3"
	prop(c, "source") == "runtime"
}

# ============================================================================
# 七、SASL（Kafka 的帳號驗證機制）
# ============================================================================

# 判定：通過
# 條件：SCRAM-SHA-256／512，而且迭代次數夠
findings contains finding(c, "pass", "sasl-scram", "SCRAM：以雜湊驗證密碼，不受 Shor 演算法影響", basis_pqc) if {
	some c in protocols
	startswith(prop(c, "saslMechanism"), "SCRAM-SHA-")
	not scram_weak(c)
}

# SCRAM 的迭代次數太少：最少的那一筆不到 4096
scram_weak(c) if number_prop(c, "scramMinIterations") < 4096

# 判定：警告
# 條件：SCRAM 的迭代次數太少
findings contains finding(c, "warning", "sasl-scram-iterations",
	sprintf("SCRAM 迭代次數最少 %s，低於 4096", [prop(c, "scramMinIterations")]), "RFC 5802") if {
	some c in protocols
	scram_weak(c)
}

# 判定：資訊
# 條件：PLAIN
findings contains finding(c, "info", "sasl-plain", "PLAIN：密碼原樣交給伺服器驗證，安全性完全靠 TLS", basis_tls) if {
	some c in protocols
	prop(c, "saslMechanism") == "PLAIN"
}

# 判定：資訊
# 條件：OAUTHBEARER
findings contains finding(c, "info", "sasl-oauthbearer", "OAUTHBEARER：安全性取決於 token 的簽章演算法（另列）與 TLS", "") if {
	some c in protocols
	prop(c, "saslMechanism") == "OAUTHBEARER"
}

# 判定：無法判斷
# 條件：以上三種以外的 SASL 機制
findings contains finding(c, "unknown", "sasl-unrecognized", "規則不認得這個 SASL 機制，請人工判斷", "") if {
	some c in protocols
	mechanism := prop(c, "saslMechanism")
	not startswith(mechanism, "SCRAM-SHA-")
	not mechanism in {"PLAIN", "OAUTHBEARER"}
}

# ============================================================================
# 八、設定檔與檔案（元件的 cbom:kind 說它是哪一種）
# ============================================================================

# ---- 平台的設定檔（kind = platform-config）----

obsolete_protocol_names := {"TLSv1", "TLSv1.1", "SSLv3", "SSLv2Hello"}

# 判定：違規
# 條件：ssl.enabled.protocols 列了舊的 TLS／SSL 版本
findings contains finding(c, "violation", "config-obsolete-tls",
	sprintf("%s 啟用了 %s", [setting[0], setting[1]]), basis_tls) if {
	some c in input.components
	prop(c, "kind") == "platform-config"
	some setting in settings(c, "ssl.enabled.protocols")
	some protocol in split(setting[1], ",")
	trim_space(protocol) in obsolete_protocol_names
}

# 判定：違規
# 條件：ssl.endpoint.identification.algorithm 是空的（關閉了主機名驗證）
findings contains finding(c, "violation", "config-hostname-verification-off",
	sprintf("%s 是空的：關閉了主機名驗證", [setting[0]]), basis_tls) if {
	some c in input.components
	prop(c, "kind") == "platform-config"
	some setting in settings(c, "ssl.endpoint.identification.algorithm")
	trim_space(setting[1]) == ""
}

# 判定：通過
# 條件：上面兩種違規都沒有
findings contains finding(c, "pass", "config-ok", "設定檔沒有啟用舊的 TLS 版本，也沒有關閉主機名驗證", basis_tls) if {
	some c in input.components
	prop(c, "kind") == "platform-config"
	not config_violation(c)
}

# 設定檔有違規：啟用了舊的 TLS
config_violation(c) if {
	some setting in settings(c, "ssl.enabled.protocols")
	some protocol in split(setting[1], ",")
	trim_space(protocol) in obsolete_protocol_names
}

# 或：關閉了主機名驗證
config_violation(c) if {
	some setting in settings(c, "ssl.endpoint.identification.algorithm")
	trim_space(setting[1]) == ""
}

# ---- JDK 的 java.security（kind = java-security）----

# 這些一定要在 jdk.tls.disabledAlgorithms 裡
required_disabled := ["SSLv3", "TLSv1", "TLSv1.1", "RC4", "3DES_EDE_CBC"]

# jdk_missing(c)：上面那幾個裡，還沒被停用的
jdk_missing(c) := [name |
	some name in required_disabled
	not jdk_disabled(c, name)
]

# 已停用：jdk.tls.disabledAlgorithms 的清單裡有這個名稱
jdk_disabled(c, name) if {
	some setting in settings(c, "jdk.tls.disabledAlgorithms")
	some item in split(setting[1], ",")
	trim_space(item) == name
}

# 或：有的 JDK（跟著 OS 密碼政策的）把 RC4 拆成 RC4_40、RC4_128 幾項寫，也算停用了 RC4
jdk_disabled(c, name) if {
	some setting in settings(c, "jdk.tls.disabledAlgorithms")
	some item in split(setting[1], ",")
	startswith(trim_space(item), concat("", [name, "_"]))
	name == "RC4"
}

# 判定：違規
# 條件：該停用的還有沒停用的
findings contains finding(c, "violation", "jdk-weak-not-disabled",
	sprintf("java.security 沒有停用：%s", [concat("、", jdk_missing(c))]), basis_tls) if {
	some c in input.components
	prop(c, "kind") == "java-security"
	count(jdk_missing(c)) > 0
}

# 判定：通過
# 條件：該停用的都停用了
findings contains finding(c, "pass", "jdk-ok", "java.security 已停用 SSLv3、TLS 1.0／1.1、RC4、3DES", basis_tls) if {
	some c in input.components
	prop(c, "kind") == "java-security"
	count(jdk_missing(c)) == 0
}

# 判定：資訊（不影響合規結果，但要讓人知道）
# 條件：JDK 實際生效的值和 java.security 檔案寫的不同
findings contains finding(c, "info", "jdk-effective-differs",
	sprintf("JDK 實際生效的值和 java.security 檔案不同：%s（另有設定檔，或這個 JDK 跟著 OS 的密碼政策）", [prop(c, "differsFromFile")]), "盤點") if {
	some c in input.components
	prop(c, "kind") == "java-security"
	has_prop(c, "differsFromFile")
}

# ---- OS 的密碼政策（kind = os-crypto-policy）----

# 判定：違規
# 條件：crypto-policies 是 LEGACY
findings contains finding(c, "violation", "os-crypto-legacy", "OS 的 crypto-policies 是 LEGACY：允許已不安全的演算法", basis_strength) if {
	some c in input.components
	prop(c, "kind") == "os-crypto-policy"
	startswith(prop(c, "setting:crypto-policies"), "LEGACY")
}

# 判定：通過
# 條件：crypto-policies 不是 LEGACY（DEFAULT、FUTURE、FIPS）
findings contains finding(c, "pass", "os-crypto-ok",
	sprintf("OS 的 crypto-policies：%s", [prop(c, "setting:crypto-policies")]), basis_strength) if {
	some c in input.components
	prop(c, "kind") == "os-crypto-policy"
	not startswith(prop(c, "setting:crypto-policies"), "LEGACY")
}

# ---- keystore、truststore、私鑰檔的權限 ----

key_file_kinds := {"keystore", "truststore", "private-key-file"}

# 其他使用者讀得到：權限的最後一碼不是 0（例如 0644；0640、0600 才對）
world_readable(c) if not endswith(prop(c, "mode"), "0")

# 判定：違規
# 條件：其他使用者讀得到
findings contains finding(c, "violation", "key-file-permission",
	sprintf("權限 %s：其他使用者讀得到", [prop(c, "mode")]), "最小權限") if {
	some c in input.components
	prop(c, "kind") in key_file_kinds
	world_readable(c)
}

# 判定：通過
# 條件：其他使用者讀不到
findings contains finding(c, "pass", "key-file-ok",
	sprintf("權限 %s（%s），其他使用者讀不到", [prop(c, "mode"), prop(c, "owner")]), "最小權限") if {
	some c in input.components
	prop(c, "kind") in key_file_kinds
	not world_readable(c)
}

# ============================================================================
# 九、函式庫
# ============================================================================

# 判定：資訊
# 條件：套件帶的密碼函式庫（例如 BouncyCastle）
findings contains finding(c, "info", "crypto-library",
	"原廠套件帶的密碼函式庫：內部怎麼使用看不到，版本的弱點由弱點掃描負責", "盤點") if {
	some c in input.components
	prop(c, "kind") == "crypto-library"
}

# ============================================================================
# 十、盤點完整性（cbom-tools 依原料算出「該有而沒有的」，放在 cbom:kind 是 collection-check 的那個元件）
# ============================================================================

# collection_gaps(c)：這個元件記的每個缺口（屬性 cbom:gap，一個缺口一筆）
collection_gaps(c) := [p.value | some p in c.properties; p.name == "cbom:gap"]

# 原因的文字：缺口 5 個以內全部列出；超過 5 個只列前 5 個，加上總數
gap_reason(gaps) := sprintf("盤點有 %d 個缺口：%s", [count(gaps), concat("；", gaps)]) if count(gaps) <= 5

gap_reason(gaps) := sprintf("盤點有 %d 個缺口，前 5 個：%s", [count(gaps), concat("；", array.slice(gaps, 0, 5))]) if count(gaps) > 5

# 判定：無法判斷
# 條件：有缺口（少了原料的那一部分沒有盤到，報告不能代表它）
findings contains finding(c, "unknown", "collection-gap", gap_reason(collection_gaps(c)), "盤點") if {
	some c in input.components
	prop(c, "kind") == "collection-check"
	count(collection_gaps(c)) > 0
}

# 判定：通過
# 條件：沒有缺口
findings contains finding(c, "pass", "collection-complete", "盤點完整：該有的原料都收到了", "盤點") if {
	some c in input.components
	prop(c, "kind") == "collection-check"
	count(collection_gaps(c)) == 0
}

# ============================================================================
# 十一、收尾（平常不用改）
# ============================================================================

# 沒有任何規則處理到的元件，補一筆「無法判斷」，確保每個元件都有結果
covered contains f["bom-ref"] if some f in findings

findings_all contains f if some f in findings

# 判定：無法判斷
# 條件：上面沒有任何一條規則處理到這個元件
findings_all contains finding(c, "unknown", "no-rule", "沒有規則處理這個元件，請人工判斷", "") if {
	some c in input.components
	not c["bom-ref"] in covered
}

# 某一級有幾個元件（一個元件中好幾條同級的規則只算一個）
count_level(level) := count({f["bom-ref"] | some f in findings_all; f.level == level})

# pipeline 讀的結果：全部的發現、各級的數量、合不合規
report := {
	"findings": sort_findings,
	"counts": {
		"violation": count_level("violation"),
		"quantum-vulnerable": count_level("quantum-vulnerable"),
		"warning": count_level("warning"),
		"unknown": count_level("unknown"),
	},
	# 只有「違規」算不合規；量子脆弱與警告不擋
	"compliant": count_level("violation") == 0,
}

sort_findings := sort([f | some f in findings_all])
