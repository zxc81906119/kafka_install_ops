# 規則的測試：opa test policy/
# 每個測試給一個很小的 CBOM，看等級與規則名稱對不對。調整門檻之後先跑這個。
package cbom_test

import data.cbom

# ---------- 組測試資料的小工具 ----------

props(pairs) := [{"name": concat("", ["cbom:", k]), "value": v} | some k, v in pairs]

algorithm(ref, name, pairs) := {
	"bom-ref": ref, "type": "cryptographic-asset", "name": name,
	"cryptoProperties": {"assetType": "algorithm"},
	"properties": props(pairs),
}

protocol(ref, name, pairs) := {
	"bom-ref": ref, "type": "cryptographic-asset", "name": name,
	"cryptoProperties": {"assetType": "protocol", "protocolProperties": {"type": "tls"}},
	"properties": props(pairs),
}

certificate(ref, name, not_after, pairs) := {
	"bom-ref": ref, "type": "cryptographic-asset", "name": name,
	"cryptoProperties": {"assetType": "certificate", "certificateProperties": {"notValidAfter": not_after}},
	"properties": props(pairs),
}

file(ref, name, pairs) := {"bom-ref": ref, "type": "file", "name": name, "properties": props(pairs)}

# 某個元件的 [等級, 規則] 集合
results(components, ref) := {[f.level, f.rule] |
	some f in cbom.report.findings with input as {"components": components}
	f["bom-ref"] == ref
}

rsa_cert := {"family": "RSA", "keySize": "2048", "keyAlgorithm": "RSA-2048", "signatureAlgorithm": "SHA256-RSA", "signatureDigest": "SHA-2"}

# ---------- 演算法 ----------

test_rsa_is_quantum_vulnerable if {
	results([algorithm("a", "RSA-2048", {"family": "RSA", "keySize": "2048"})], "a") == {["quantum-vulnerable", "quantum-vulnerable-algorithm"]}
}

test_short_rsa_is_a_violation_not_just_quantum_vulnerable if {
	results([algorithm("a", "RSA-1024", {"family": "RSA", "keySize": "1024"})], "a") == {["violation", "weak-key"]}
}

test_sha1_and_3des_are_violations if {
	results([algorithm("a", "SHA-1", {"family": "SHA-1"})], "a") == {["violation", "broken-algorithm"]}
	results([algorithm("b", "DESede", {"family": "3DES"})], "b") == {["violation", "broken-algorithm"]}
}

test_signature_with_sha1_is_a_violation if {
	["violation", "broken-digest"] in results([algorithm("a", "SHA1withRSA", {"family": "RSA", "digest": "SHA-1"})], "a")
}

# HMAC 搭 SHA-1 只是警告；HMAC 搭 MD5、PBKDF2 搭 SHA-1 仍然是違規
test_hmac_sha1_is_a_warning_not_a_violation if {
	hmac_sha1 := results([algorithm("a", "HmacSHA1", {"family": "HMAC", "digest": "SHA-1"})], "a")
	["warning", "hmac-sha1"] in hmac_sha1
	not ["violation", "broken-digest"] in hmac_sha1
	["violation", "broken-digest"] in results([algorithm("b", "HmacMD5", {"family": "HMAC", "digest": "MD5"})], "b")
	["violation", "broken-digest"] in results([algorithm("c", "PBKDF2WithHmacSHA1", {"family": "PBKDF2", "digest": "SHA-1"})], "c")
}

test_hybrid_and_ml_kem_pass if {
	results([algorithm("a", "X25519MLKEM768", {"family": "ML-KEM-hybrid"})], "a") == {["pass", "hybrid-key-exchange"]}
	results([algorithm("b", "ML-KEM-768", {"family": "ML-KEM"})], "b") == {["pass", "post-quantum-algorithm"]}
}

test_aes_128_is_acceptable_and_aes_256_passes if {
	results([algorithm("a", "AES-128-GCM", {"family": "AES", "keySize": "128"})], "a") == {["pass", "symmetric-128"]}
	results([algorithm("b", "AES-256-GCM", {"family": "AES", "keySize": "256"})], "b") == {["pass", "symmetric-ok"]}
}

test_unknown_algorithm_needs_a_person if {
	results([algorithm("a", "SomethingNew", {"family": "unknown"})], "a") == {["unknown", "unrecognized-algorithm"]}
}

# ---------- 憑證 ----------

test_rsa_certificate_is_quantum_vulnerable if {
	results([certificate("c", "cp-server", "2099-01-01T00:00:00Z", rsa_cert)], "c") == {["quantum-vulnerable", "certificate-quantum-vulnerable"]}
}

test_certificate_valid_past_2035_is_flagged_as_priority if {
	some f in cbom.report.findings with input as {"components": [certificate("c", "root", "2046-11-03T00:00:00Z", rsa_cert)]}
	f.rule == "certificate-quantum-vulnerable"
	contains(f.reason, "跨過 2035 年")
}

test_expired_certificate_is_a_violation if {
	["violation", "certificate-expired"] in results([certificate("c", "old", "2020-01-01T00:00:00Z", rsa_cert)], "c")
}

test_sha1_signed_certificate_is_a_violation if {
	pairs := object.union(rsa_cert, {"signatureDigest": "SHA-1"})
	["violation", "certificate-broken-digest"] in results([certificate("c", "legacy", "2099-01-01T00:00:00Z", pairs)], "c")
}

# ---------- TLS ----------

test_tls13_with_pqc_passes_and_without_is_quantum_vulnerable if {
	results([protocol("p", "TLS 1.3", {"tlsVersion": "1.3", "pqcKeyExchange": "offered"})], "p") == {["pass", "tls-1.3-pqc"]}
	results([protocol("q", "TLS 1.3", {"tlsVersion": "1.3", "pqcKeyExchange": "none"})], "q") == {["quantum-vulnerable", "tls-1.3-classical"]}
}

test_tls12_is_a_warning_and_cbc_adds_another if {
	pairs := {"tlsVersion": "1.2", "pqcKeyExchange": "none", "obsoleteCiphers": "offered", "tripleDesCiphers": "none"}
	results([protocol("p", "TLS 1.2", pairs)], "p") == {["warning", "tls-1.2"], ["warning", "tls-cbc"]}
}

test_tls11_and_3des_are_violations if {
	results([protocol("p", "TLS 1.1", {"tlsVersion": "1.1"})], "p") == {["violation", "tls-obsolete-version"]}
	pairs := {"tlsVersion": "1.2", "tripleDesCiphers": "offered", "obsoleteCiphers": "none"}
	["violation", "tls-3des"] in results([protocol("q", "TLS 1.2", pairs)], "q")
}

test_scram_passes_unless_iterations_are_low if {
	results([protocol("p", "SASL/SCRAM-SHA-512", {"saslMechanism": "SCRAM-SHA-512", "scramMinIterations": "4096"})], "p") == {["pass", "sasl-scram"]}
	results([protocol("q", "SASL/SCRAM-SHA-512", {"saslMechanism": "SCRAM-SHA-512", "scramMinIterations": "1000"})], "q") == {["warning", "sasl-scram-iterations"]}
}

# ---------- 設定檔 ----------

test_config_enabling_tls11_is_a_violation if {
	pairs := {"kind": "platform-config", "setting:ssl.enabled.protocols": "TLSv1.3,TLSv1.1"}
	results([file("f", "kb01:server.properties", pairs)], "f") == {["violation", "config-obsolete-tls"]}
}

test_config_with_hostname_verification_off_is_a_violation if {
	pairs := {"kind": "platform-config", "setting:ssl.endpoint.identification.algorithm": ""}
	results([file("f", "kb01:server.properties", pairs)], "f") == {["violation", "config-hostname-verification-off"]}
}

test_clean_config_passes if {
	pairs := {"kind": "platform-config", "setting:ssl.enabled.protocols": "TLSv1.3,TLSv1.2", "setting:ssl.endpoint.identification.algorithm": "https"}
	results([file("f", "kb01:server.properties", pairs)], "f") == {["pass", "config-ok"]}
}

test_java_security_must_disable_old_protocols if {
	good := {"kind": "java-security", "setting:jdk.tls.disabledAlgorithms": "SSLv3, TLSv1, TLSv1.1, RC4, DES, 3DES_EDE_CBC"}
	results([file("f", "java.security", good)], "f") == {["pass", "jdk-ok"]}
	bad := {"kind": "java-security", "setting:jdk.tls.disabledAlgorithms": "SSLv3, RC4"}
	results([file("g", "java.security", bad)], "g") == {["violation", "jdk-weak-not-disabled"]}
}

test_world_readable_key_file_is_a_violation if {
	results([file("f", "cp-server.p12", {"kind": "keystore", "mode": "644", "owner": "root:confluent"})], "f") == {["violation", "key-file-permission"]}
	results([file("g", "cp-server.p12", {"kind": "keystore", "mode": "640", "owner": "root:confluent"})], "g") == {["pass", "key-file-ok"]}
}

# ---------- 整體結果 ----------

test_only_violations_make_the_result_non_compliant if {
	vulnerable := [algorithm("a", "RSA-2048", {"family": "RSA", "keySize": "2048"}), protocol("p", "TLS 1.2", {"tlsVersion": "1.2"})]
	cbom.report.compliant with input as {"components": vulnerable}
	cbom.report.counts["quantum-vulnerable"] == 1 with input as {"components": vulnerable}
	cbom.report.counts.warning == 1 with input as {"components": vulnerable}

	broken := array.concat(vulnerable, [algorithm("b", "MD5", {"family": "MD5"})])
	not cbom.report.compliant with input as {"components": broken}
	cbom.report.counts.violation == 1 with input as {"components": broken}
}

test_component_without_any_rule_is_reported_as_unknown if {
	results([{"bom-ref": "x", "type": "device", "name": "不認得的東西"}], "x") == {["unknown", "no-rule"]}
}

test_source_scanner_names_are_recognized if {
	results([algorithm("a", "EC-secp256r1", {"family": "EC", "keySize": "256"})], "a") == {["quantum-vulnerable", "quantum-vulnerable-algorithm"]}
	results([algorithm("a", "Poly1305", {"family": "Poly1305"})], "a") == {["pass", "symmetric-ok"]}
}

test_key_material_found_in_source_code_is_informational if {
	key := {
		"bom-ref": "k", "type": "cryptographic-asset", "name": "key",
		"cryptoProperties": {"assetType": "related-crypto-material"},
		"properties": [{"name": "cbom:source", "value": "source-code"}],
	}
	results([key], "k") == {["info", "source-key-material"]}
}

material(ref, name, pairs) := {
	"bom-ref": ref, "type": "cryptographic-asset", "name": name,
	"cryptoProperties": {"assetType": "related-crypto-material"},
	"properties": props(pairs),
}

test_secrets_in_the_repository_are_violations if {
	results([material("k", "generic-api-key", {"source": "secret-scan", "materialType": "key"})], "k") == {["violation", "hardcoded-secret"]}
	some f in results([material("p", "RSA-2048", {"source": "secret-scan", "materialType": "private-key", "family": "RSA", "keySize": "2048"})], "p")
	f == ["violation", "private-key-in-repository"]
}

test_secret_scan_hits_inside_the_image_need_a_human if {
	results([material("k", "generic-api-key", {"source": "image-scan", "materialType": "key"})], "k") == {["unknown", "image-secret-candidate"]}
}

test_random_generators_pass if {
	results([algorithm("r", "NativePRNG", {"family": "RNG"})], "r") == {["pass", "random-generator"]}
}

test_jdk_that_follows_the_os_policy_lists_rc4_in_parts if {
	jdk := {"bom-ref": "j", "type": "file", "name": "java.security", "properties": props({
		"kind": "java-security",
		"setting:jdk.tls.disabledAlgorithms": "TLSv1.1, TLSv1, SSLv3, 3DES_EDE_CBC, RC4_40, RC4_128",
	})}
	some f in results([jdk], "j")
	f == ["pass", "jdk-ok"]
}

# ---------- 模式與填充 ----------

# 帶用途（primitive）的演算法元件：rsa-pkcs1-encryption 要看它是加密（pke）還是簽章（signature）
algorithm_for(ref, name, primitive, pairs) := {
	"bom-ref": ref, "type": "cryptographic-asset", "name": name,
	"cryptoProperties": {"assetType": "algorithm", "algorithmProperties": {"primitive": primitive}},
	"properties": props(pairs),
}

test_aes_ecb_is_a_violation if {
	["violation", "ecb-mode"] in results([algorithm("a", "AES/ECB/PKCS5Padding", {"family": "AES", "mode": "ECB", "padding": "PKCS5"})], "a")
}

test_aes_gcm_is_not_ecb if {
	results([algorithm("a", "AES/GCM/NoPadding", {"family": "AES", "mode": "GCM", "padding": "NONE"})], "a") == {["pass", "symmetric-ok"]}
}

test_rsa_ecb_is_only_the_jca_spelling_not_ecb_mode if {
	found := results([algorithm_for("a", "RSA/ECB/OAEPWithSHA-256AndMGF1Padding", "pke", {"family": "RSA", "mode": "ECB", "padding": "OAEP"})], "a")
	found == {["quantum-vulnerable", "quantum-vulnerable-algorithm"]}
}

test_rsa_pkcs1_encryption_is_a_violation_and_still_quantum_vulnerable if {
	found := results([algorithm_for("a", "RSA/ECB/PKCS1Padding", "pke", {"family": "RSA", "mode": "ECB", "padding": "PKCS1"})], "a")
	found == {["violation", "rsa-pkcs1-encryption"], ["quantum-vulnerable", "quantum-vulnerable-algorithm"]}
}

test_rsa_oaep_encryption_is_not_pkcs1 if {
	not ["violation", "rsa-pkcs1-encryption"] in results([algorithm_for("a", "RSA-OAEP", "pke", {"family": "RSA", "padding": "OAEP"})], "a")
}

test_rsa_signature_with_pkcs1_is_not_the_encryption_rule if {
	# SHA256withRSA：名稱裡沒有填充，用途是簽章
	results([algorithm_for("a", "SHA256withRSA", "signature", {"family": "RSA", "digest": "SHA-2"})], "a") == {["quantum-vulnerable", "quantum-vulnerable-algorithm"]}
	# RSASSA-PKCS1-v1_5：填充是 PKCS1，但用途是簽章，一樣不中
	not ["violation", "rsa-pkcs1-encryption"] in results([algorithm_for("b", "RSASSA-PKCS1-v1_5", "signature", {"family": "RSA", "padding": "PKCS1"})], "b")
}

# ---------- 盤點完整性 ----------

# 完整性檢查的元件：gaps 是缺口的清單
collection_check(gaps) := {
	"bom-ref": "data:check", "type": "data", "name": "盤點完整性檢查",
	"properties": array.concat(
		[{"name": "cbom:kind", "value": "collection-check"}, {"name": "cbom:gapCount", "value": sprintf("%d", [count(gaps)])}],
		[{"name": "cbom:gap", "value": gap} | some gap in gaps]
	),
}

test_collection_without_gaps_passes if {
	results([collection_check([])], "data:check") == {["pass", "collection-complete"]}
}

test_collection_gaps_need_a_person_and_the_reason_lists_them if {
	components := [collection_check(["kb01:9092 沒有 TLS 掃描結果", "kb02：沒有這台的原料目錄"])]
	results(components, "data:check") == {["unknown", "collection-gap"]}
	some f in cbom.report.findings with input as {"components": components}
	f.rule == "collection-gap"
	f.reason == "盤點有 2 個缺口：kb01:9092 沒有 TLS 掃描結果；kb02：沒有這台的原料目錄"
}

test_more_than_five_gaps_lists_the_first_five_and_the_total if {
	components := [collection_check(["g1", "g2", "g3", "g4", "g5", "g6", "g7"])]
	some f in cbom.report.findings with input as {"components": components}
	f.rule == "collection-gap"
	f.reason == "盤點有 7 個缺口，前 5 個：g1；g2；g3；g4；g5"
}
