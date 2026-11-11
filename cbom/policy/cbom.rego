# 密碼學資產合規規則（輸入：cbom-tools 產生的 CycloneDX CBOM）
#
#   opa eval --data policy/ --input cbom.json --format json 'data.cbom.report'
#
# 每個元件至少一筆 finding：
#   bom-ref、name、assetType、level、rule、reason（為什麼）、basis（依據）
# level 由重到輕：
#   violation           現在就不合格（和量子電腦無關：已破解的演算法、過短的金鑰、舊的 TLS、過期的憑證）
#   quantum-vulnerable  量子脆弱：現在安全，但量子電腦可破解；NIST IR 8547 的時程是 2030 年後棄用、2035 年後禁用
#   warning             建議改善（不擋 pipeline）
#   unknown             規則不認得，要人看
#   pass                通過
#   info                只是盤點資訊（例如帶了哪些密碼函式庫）
#
# 依據：NIST IR 8547（後量子遷移時程）、FIPS 203／204／205（ML-KEM、ML-DSA、SLH-DSA）、
#       NIST SP 800-131A Rev.2（演算法與金鑰長度）、NIST SP 800-52 Rev.2（TLS）。
# 門檻要調整時改這個檔就好，程式不用動（2026-11-11 與使用者確認：TLS 1.2 是 warning、AES-128 可接受、
# 量子脆弱不讓 pipeline 失敗）。
package cbom

# ---------- 名單 ----------

quantum_vulnerable_families := {"RSA", "ECDSA", "EdDSA", "ECDH", "DH", "DSA"}

quantum_safe_families := {"ML-KEM", "ML-KEM-hybrid", "ML-DSA", "SLH-DSA"}

broken_families := {"MD5", "MD2", "MD4", "SHA-1", "DES", "3DES", "RC4"}

# 對稱式、雜湊、金鑰衍生：量子電腦只讓強度減半（Grover），長度夠就可以
symmetric_families := {"AES", "ChaCha20", "SHA-2", "SHA-3", "HMAC", "HKDF", "PBKDF2"}

broken_digests := {"MD5", "SHA-1"}

basis_pqc := "NIST IR 8547"

basis_strength := "NIST SP 800-131A Rev.2"

basis_tls := "NIST SP 800-52 Rev.2"

reason_quantum := "量子電腦可破解（Shor 演算法）：2030 年後棄用、2035 年後禁用，要排進遷移計畫"

# ---------- 小工具 ----------

# 元件的 cbom: 屬性；同名有多個值時取第一個
prop(component, name) := value if {
	values := [p.value | some p in component.properties; p.name == concat("", ["cbom:", name])]
	count(values) > 0
	value := values[0]
}

has_prop(component, name) if {
	some p in component.properties
	p.name == concat("", ["cbom:", name])
}

number_prop(component, name) := to_number(prop(component, name))

# 設定檔元件的某個設定（屬性名稱是 cbom:setting:<設定鍵>）；回傳所有符合結尾的 [鍵, 值]
settings(component, suffix) := [[key, p.value] |
	some p in component.properties
	startswith(p.name, "cbom:setting:")
	key := substring(p.name, count("cbom:setting:"), -1)
	endswith(key, suffix)
]

asset_type(component) := component.cryptoProperties.assetType if component.type == "cryptographic-asset"

asset_type(component) := component.type if component.type != "cryptographic-asset"

family(component) := prop(component, "family")

finding(component, level, rule, reason, basis) := {
	"bom-ref": component["bom-ref"],
	"name": component.name,
	"assetType": asset_type(component),
	"level": level,
	"rule": rule,
	"reason": reason,
	"basis": basis,
}

# 金鑰太短（和量子無關，現在就不合格）
weak_key(component) if {
	family(component) in {"RSA", "DSA", "DH"}
	number_prop(component, "keySize") < 2048
}

weak_key(component) if {
	family(component) in {"ECDSA", "ECDH", "EdDSA"}
	number_prop(component, "keySize") < 224
}

# ---------- 演算法、金鑰 ----------

keyed_types := {"algorithm", "related-crypto-material"}

findings contains finding(c, "violation", "broken-algorithm",
	sprintf("%s 已不安全，不可再用", [family(c)]), basis_strength) if {
	some c in input.components
	asset_type(c) in keyed_types
	family(c) in broken_families
}

findings contains finding(c, "violation", "broken-digest",
	sprintf("搭配的雜湊 %s 已不安全", [prop(c, "digest")]), basis_strength) if {
	some c in input.components
	asset_type(c) in keyed_types
	prop(c, "digest") in broken_digests
}

findings contains finding(c, "violation", "weak-key",
	sprintf("%s 金鑰 %s 位元太短", [family(c), prop(c, "keySize")]), basis_strength) if {
	some c in input.components
	asset_type(c) in keyed_types
	weak_key(c)
}

findings contains finding(c, "quantum-vulnerable", "quantum-vulnerable-algorithm", reason_quantum, basis_pqc) if {
	some c in input.components
	asset_type(c) in keyed_types
	family(c) in quantum_vulnerable_families
	not weak_key(c)
}

findings contains finding(c, "pass", "post-quantum-algorithm", "後量子演算法（NIST 標準）", "FIPS 203／204／205") if {
	some c in input.components
	asset_type(c) in keyed_types
	family(c) in {"ML-KEM", "ML-DSA", "SLH-DSA"}
}

findings contains finding(c, "pass", "hybrid-key-exchange",
	"混合式金鑰交換（傳統＋ML-KEM）：其中一個被破解仍然安全", "FIPS 203、NIST IR 8547") if {
	some c in input.components
	asset_type(c) in keyed_types
	family(c) == "ML-KEM-hybrid"
}

findings contains finding(c, "pass", "symmetric-128", "AES-128 可接受（量子安全等級 1）；新系統建議 AES-256", basis_pqc) if {
	some c in input.components
	asset_type(c) in keyed_types
	family(c) == "AES"
	number_prop(c, "keySize") == 128
}

findings contains finding(c, "pass", "symmetric-ok", "對稱式、雜湊與金鑰衍生不受 Shor 演算法影響，強度足夠", basis_pqc) if {
	some c in input.components
	asset_type(c) in keyed_types
	family(c) in symmetric_families
	not aes_128(c)
}

aes_128(c) if {
	family(c) == "AES"
	number_prop(c, "keySize") == 128
}

findings contains finding(c, "warning", "kdf-iterations",
	sprintf("PBKDF2 迭代次數 %s 偏低（建議 10000 以上）", [prop(c, "iterations")]), "NIST SP 800-132") if {
	some c in input.components
	asset_type(c) == "algorithm"
	family(c) == "PBKDF2"
	number_prop(c, "iterations") < 10000
}

findings contains finding(c, "unknown", "unrecognized-algorithm", "規則不認得這個演算法，請人工判斷", "") if {
	some c in input.components
	asset_type(c) in keyed_types
	family(c) == "unknown"
}

# ---------- 憑證 ----------

findings contains finding(c, "violation", "certificate-expired",
	sprintf("憑證已過期（%s）", [c.cryptoProperties.certificateProperties.notValidAfter]), basis_strength) if {
	some c in input.components
	asset_type(c) == "certificate"
	time.parse_rfc3339_ns(c.cryptoProperties.certificateProperties.notValidAfter) < time.now_ns()
}

findings contains finding(c, "violation", "certificate-broken-digest",
	sprintf("憑證簽章用的雜湊 %s 已不安全", [prop(c, "signatureDigest")]), basis_strength) if {
	some c in input.components
	asset_type(c) == "certificate"
	prop(c, "signatureDigest") in broken_digests
}

findings contains finding(c, "violation", "certificate-weak-key",
	sprintf("憑證的 %s 金鑰 %s 位元太短", [family(c), prop(c, "keySize")]), basis_strength) if {
	some c in input.components
	asset_type(c) == "certificate"
	weak_key(c)
}

findings contains finding(c, "quantum-vulnerable", "certificate-quantum-vulnerable",
	sprintf("憑證金鑰 %s、簽章 %s：%s%s", [prop(c, "keyAlgorithm"), prop(c, "signatureAlgorithm"), reason_quantum, deadline_note(c)]),
	basis_pqc) if {
	some c in input.components
	asset_type(c) == "certificate"
	family(c) in quantum_vulnerable_families
	not weak_key(c)
}

# 憑證的有效期跨過遷移時程的話，優先處理
deadline_note(c) := "；有效期跨過 2035 年（禁用），優先處理" if {
	time.parse_rfc3339_ns(c.cryptoProperties.certificateProperties.notValidAfter) >= time.parse_rfc3339_ns("2035-01-01T00:00:00Z")
} else := "；有效期跨過 2030 年（棄用），優先處理" if {
	time.parse_rfc3339_ns(c.cryptoProperties.certificateProperties.notValidAfter) >= time.parse_rfc3339_ns("2030-01-01T00:00:00Z")
} else := ""

findings contains finding(c, "pass", "certificate-post-quantum", "憑證使用後量子簽章", "FIPS 204／205") if {
	some c in input.components
	asset_type(c) == "certificate"
	family(c) in quantum_safe_families
}

# ---------- TLS ----------

tls_version(c) := prop(c, "tlsVersion")

findings contains finding(c, "violation", "tls-obsolete-version",
	sprintf("%s 已禁用", [c.name]), basis_tls) if {
	some c in input.components
	asset_type(c) == "protocol"
	tls_version(c) in {"1.1", "1.0", "SSLv3", "SSLv2"}
}

findings contains finding(c, "warning", "tls-1.2",
	"TLS 1.2 的金鑰交換只有傳統演算法，用不了後量子金鑰交換；規劃只留 TLS 1.3", "NIST SP 800-52 Rev.2、NIST IR 8547") if {
	some c in input.components
	asset_type(c) == "protocol"
	tls_version(c) == "1.2"
}

findings contains finding(c, "violation", "tls-3des", "伺服器接受 3DES／IDEA 的 cipher suite", basis_tls) if {
	some c in input.components
	asset_type(c) == "protocol"
	prop(c, "tripleDesCiphers") == "offered"
}

findings contains finding(c, "warning", "tls-cbc", "伺服器接受 CBC 類的舊 cipher suite，建議只留 AEAD（GCM、ChaCha20-Poly1305）", basis_tls) if {
	some c in input.components
	asset_type(c) == "protocol"
	prop(c, "obsoleteCiphers") == "offered"
}

findings contains finding(c, "pass", "tls-1.3-pqc",
	"TLS 1.3，伺服器支援後量子混合金鑰交換；實際用不用取決於用戶端也要支援", "FIPS 203、NIST IR 8547") if {
	some c in input.components
	asset_type(c) == "protocol"
	tls_version(c) == "1.3"
	prop(c, "pqcKeyExchange") == "offered"
}

findings contains finding(c, "quantum-vulnerable", "tls-1.3-classical",
	"TLS 1.3，但伺服器沒有後量子金鑰交換群組：連線內容可被「先蒐集、日後解密」", basis_pqc) if {
	some c in input.components
	asset_type(c) == "protocol"
	tls_version(c) == "1.3"
	prop(c, "pqcKeyExchange") == "none"
}

# 執行期實際交握（JFR）：看得到版本與 cipher suite，看不到金鑰交換群組
findings contains finding(c, "info", "tls-1.3-observed",
	sprintf("錄製期間實際完成的交握：%s", [prop(c, "cipherSuite")]), "執行期證據（JFR）") if {
	some c in input.components
	asset_type(c) == "protocol"
	tls_version(c) == "1.3"
	prop(c, "source") == "runtime"
}

# ---------- SASL ----------

findings contains finding(c, "pass", "sasl-scram", "SCRAM：以雜湊驗證密碼，不受 Shor 演算法影響", basis_pqc) if {
	some c in input.components
	asset_type(c) == "protocol"
	startswith(prop(c, "saslMechanism"), "SCRAM-SHA-")
	not scram_weak(c)
}

scram_weak(c) if number_prop(c, "scramMinIterations") < 4096

findings contains finding(c, "warning", "sasl-scram-iterations",
	sprintf("SCRAM 迭代次數最少 %s，低於 4096", [prop(c, "scramMinIterations")]), "RFC 5802") if {
	some c in input.components
	asset_type(c) == "protocol"
	scram_weak(c)
}

findings contains finding(c, "info", "sasl-plain", "PLAIN：密碼原樣交給伺服器驗證，安全性完全靠 TLS", basis_tls) if {
	some c in input.components
	asset_type(c) == "protocol"
	prop(c, "saslMechanism") == "PLAIN"
}

findings contains finding(c, "info", "sasl-oauthbearer", "OAUTHBEARER：安全性取決於 token 的簽章演算法（另列）與 TLS", "") if {
	some c in input.components
	asset_type(c) == "protocol"
	prop(c, "saslMechanism") == "OAUTHBEARER"
}

findings contains finding(c, "unknown", "sasl-unrecognized", "規則不認得這個 SASL 機制，請人工判斷", "") if {
	some c in input.components
	asset_type(c) == "protocol"
	mechanism := prop(c, "saslMechanism")
	not startswith(mechanism, "SCRAM-SHA-")
	not mechanism in {"PLAIN", "OAUTHBEARER"}
}

# ---------- 設定檔 ----------

obsolete_protocol_names := {"TLSv1", "TLSv1.1", "SSLv3", "SSLv2Hello"}

findings contains finding(c, "violation", "config-obsolete-tls",
	sprintf("%s 啟用了 %s", [setting[0], setting[1]]), basis_tls) if {
	some c in input.components
	prop(c, "kind") == "platform-config"
	some setting in settings(c, "ssl.enabled.protocols")
	some protocol in split(setting[1], ",")
	trim_space(protocol) in obsolete_protocol_names
}

findings contains finding(c, "violation", "config-hostname-verification-off",
	sprintf("%s 是空的：關閉了主機名驗證", [setting[0]]), basis_tls) if {
	some c in input.components
	prop(c, "kind") == "platform-config"
	some setting in settings(c, "ssl.endpoint.identification.algorithm")
	trim_space(setting[1]) == ""
}

findings contains finding(c, "pass", "config-ok", "設定檔沒有啟用舊的 TLS 版本，也沒有關閉主機名驗證", basis_tls) if {
	some c in input.components
	prop(c, "kind") == "platform-config"
	not config_violation(c)
}

config_violation(c) if {
	some setting in settings(c, "ssl.enabled.protocols")
	some protocol in split(setting[1], ",")
	trim_space(protocol) in obsolete_protocol_names
}

config_violation(c) if {
	some setting in settings(c, "ssl.endpoint.identification.algorithm")
	trim_space(setting[1]) == ""
}

# JDK：這些一定要在 jdk.tls.disabledAlgorithms 裡
required_disabled := ["SSLv3", "TLSv1", "TLSv1.1", "RC4", "3DES_EDE_CBC"]

jdk_missing(c) := [name |
	some name in required_disabled
	not jdk_disabled(c, name)
]

jdk_disabled(c, name) if {
	some setting in settings(c, "jdk.tls.disabledAlgorithms")
	some item in split(setting[1], ",")
	trim_space(item) == name
}

findings contains finding(c, "violation", "jdk-weak-not-disabled",
	sprintf("java.security 沒有停用：%s", [concat("、", jdk_missing(c))]), basis_tls) if {
	some c in input.components
	prop(c, "kind") == "java-security"
	count(jdk_missing(c)) > 0
}

findings contains finding(c, "pass", "jdk-ok", "java.security 已停用 SSLv3、TLS 1.0／1.1、RC4、3DES", basis_tls) if {
	some c in input.components
	prop(c, "kind") == "java-security"
	count(jdk_missing(c)) == 0
}

findings contains finding(c, "violation", "os-crypto-legacy", "OS 的 crypto-policies 是 LEGACY：允許已不安全的演算法", basis_strength) if {
	some c in input.components
	prop(c, "kind") == "os-crypto-policy"
	startswith(prop(c, "setting:crypto-policies"), "LEGACY")
}

findings contains finding(c, "pass", "os-crypto-ok",
	sprintf("OS 的 crypto-policies：%s", [prop(c, "setting:crypto-policies")]), basis_strength) if {
	some c in input.components
	prop(c, "kind") == "os-crypto-policy"
	not startswith(prop(c, "setting:crypto-policies"), "LEGACY")
}

# keystore、私鑰檔：其他人不可讀（權限最後一碼是 0）
key_file_kinds := {"keystore", "truststore", "private-key-file"}

world_readable(c) if not endswith(prop(c, "mode"), "0")

findings contains finding(c, "violation", "key-file-permission",
	sprintf("權限 %s：其他使用者讀得到", [prop(c, "mode")]), "最小權限") if {
	some c in input.components
	prop(c, "kind") in key_file_kinds
	world_readable(c)
}

findings contains finding(c, "pass", "key-file-ok",
	sprintf("權限 %s（%s），其他使用者讀不到", [prop(c, "mode"), prop(c, "owner")]), "最小權限") if {
	some c in input.components
	prop(c, "kind") in key_file_kinds
	not world_readable(c)
}

# ---------- 函式庫 ----------

findings contains finding(c, "info", "crypto-library",
	"原廠套件帶的密碼函式庫：內部怎麼使用看不到，版本的弱點由弱點掃描負責", "盤點") if {
	some c in input.components
	prop(c, "kind") == "crypto-library"
}

# ---------- 沒有任何規則處理到的元件 ----------

covered contains f["bom-ref"] if some f in findings

findings_all contains f if some f in findings

findings_all contains finding(c, "unknown", "no-rule", "沒有規則處理這個元件，請人工判斷", "") if {
	some c in input.components
	not c["bom-ref"] in covered
}

# ---------- 給 pipeline 用的結果 ----------

count_level(level) := count({f["bom-ref"] | some f in findings_all; f.level == level})

report := {
	"findings": sort_findings,
	"counts": {
		"violation": count_level("violation"),
		"quantum-vulnerable": count_level("quantum-vulnerable"),
		"warning": count_level("warning"),
		"unknown": count_level("unknown"),
	},
	# pipeline 只在有 violation 時失敗；量子脆弱與 warning 不擋
	"compliant": count_level("violation") == 0,
}

sort_findings := sort([f | some f in findings_all])
