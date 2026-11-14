# ============================================================================
# 用「名稱」判斷一個演算法屬於哪一類（quantum_safe.rego 用這裡的結果）
#
#   broken_hash、sha1、weak_cipher、ecb_mode   已被破解或不安全
#   quantum_vulnerable                          非對稱，量子電腦可破解
#   pqc                                         後量子演算法
#
# 怎麼讀：每一行是「名稱符合這個樣式就算」。樣式是 regex（一種描述文字長相的寫法），最常用的幾個符號：
#   A|B        A 或 B                         例：RC4|RC2 比對 RC4，也比對 RC2
#   -?         前面那個字可有可無             例：SHA-?1 比對 SHA-1，也比對 SHA1
#   (?i)       不分大小寫
#   [^0-9]     「不是數字」的一個字           例：SHA-?1([^0-9]|$) 不會比對到 SHA-128
#   ^ 與 $     名稱的開頭與結尾
#
# 要加一個名稱：在對應那一行的樣式裡加上「|新名稱」。例：weak_cipher 那一行的 ...|Blowfish 後面加 |ARCFOUR。
# 每一行上面的註解都寫了「比對什麼、不比對什麼」，改完照那個例子在 quantum_safe_test.rego 加測試。
# 參數 t 是要比對的文字（演算法或金鑰的名稱）。
# 注意：OPA 的 regex 不支援 (?<!…)、(?!…) 這兩種寫法。
# ============================================================================
package lib.cbomlab.names

import rego.v1

# 只比對「完整的詞」，避免 "DES" 誤中 "DESCRIPTION"、"EC" 誤中 "SPEC"
# 例：word("DES") 比對 "DES-56-CBC"、"des"，但不比對 "MODES"（前後緊接英文字母就不算）
word(alternatives) := sprintf(`(?i)(^|[^A-Z])(%s)([^A-Z]|$)`, [alternatives])

# ---- 已破解或不安全 ----

# MD5（以及 MD2、MD4），也比對 JCA 寫法 "HmacMD5"（JFR 錄到的名稱）；但不比對 "MD50"、"CMD5"
broken_hash(t) if regex.match(`(?i)(^|[^A-Z]|Hmac)MD[245]([^0-9]|$)`, t)

# SHA1 / SHA-1，但不比對 SHA-128、SHA-1024
sha1(t) if regex.match(`(?i)SHA-?1([^0-9]|$)`, t)

# 不安全的對稱加密
weak_cipher(t) if regex.match(word("3?DES|DESede|TripleDES|TDEA|RC4|RC2|Blowfish"), t)

# ECB 模式。name 是元件名稱本身："RSA/ECB/OAEP..." 的 ECB 只是 JCA 的寫法，RSA 並沒有區塊模式，所以排除 RSA
ecb_mode(t, name) if {
	regex.match(word("ECB"), t)
	not regex.match(`(?i)^RSA`, name)
}

# ---- 量子脆弱（非對稱：Shor 演算法可以破解）----

# 橢圓曲線類演算法
elliptic_curve(t) if regex.match(`(?i)(^|[^A-Z])(EC|ECDH|ECDSA|ECIES)([^A-Z]|$)|X25519|X448|Ed25519|Ed448|EdDSA|secp\d+`, t)

# 傳統（非橢圓曲線）公鑰演算法：RSA、DSA、有限體 DH
# RSA 刻意不用 word()：要連 SHA256withRSA、RSASSA-PSS 這種「黏在一起」的名稱也算進來
classic_public_key(t) if regex.match(`(?i)RSA`, t)

classic_public_key(t) if regex.match(word("FFDH|DH"), t)

# JCA 的完整寫法：JFR 錄到的 KeyAgreement / KeyPairGenerator 演算法名稱是 "DiffieHellman"（不是 DH）
classic_public_key(t) if regex.match(`(?i)Diffie-?Hellman`, t)

# ML-DSA / SLH-DSA 是後量子簽章，名稱雖然含 DSA 但「不」量子脆弱：先拿掉再找 DSA
classic_public_key(t) if regex.match(`(?i)DSA`, regex.replace(t, `(?i)(ML|SLH)-DSA`, ""))

# 其他寫法的曲線 / 金鑰交換名稱（例如 TLS cipher suite 裡的 ECDHE、DHE，或 P-256）；刻意不限定完整的詞
other_classic_key_exchange(t) if regex.match(`(?i)XDH|brainpool|P-?(256|384|521)|DHE`, t)

# 以上任何一種 = 名稱看得出是量子脆弱的非對稱演算法。
# 但名稱裡有後量子成分的不算：混合式金鑰交換（例如 X25519MLKEM768 = X25519 + ML-KEM-768）
# 即使傳統的部分被破解，後量子的部分仍保護金鑰
quantum_vulnerable(t) if {
	classic_public_key(t)
	not pqc(t)
}

quantum_vulnerable(t) if {
	elliptic_curve(t)
	not pqc(t)
}

quantum_vulnerable(t) if {
	other_classic_key_exchange(t)
	not pqc(t)
}

# ---- 後量子演算法 ----
# 連字號可有可無：FIPS 203/204/205 寫 ML-KEM-768，TLS 群組名稱寫 X25519MLKEM768、MLKEM1024
pqc(t) if regex.match(`(?i)ML-?KEM|ML-?DSA|SLH-?DSA|Kyber|Dilithium|SPHINCS|Falcon`, t)
