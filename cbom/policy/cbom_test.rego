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
