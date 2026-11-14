# policies.quantum_safe 的測試（demo/cbomkit；複製自 policy/cbomkit/quantum_safe_test.rego）
package policies.quantum_safe_test

import data.policies.quantum_safe
import rego.v1

algo(ref, name, primitive) := {
	"type": "cryptographic-asset", "bom-ref": ref, "name": name,
	"cryptoProperties": {"assetType": "algorithm", "algorithmProperties": {"primitive": primitive}},
}

cbom := {"components": [
	algo("a1", "SHA-1", "hash"),
	algo("a2", "AES-256-GCM", "ae"),
	algo("a3", "RSA-2048", "pke"),
	algo("a4", "ML-KEM-768", "kem"),
	algo("a5", "AES-128-ECB-PKCS5", "block-cipher"),
	{"type": "cryptographic-asset", "bom-ref": "c1", "name": "legacy-partner",
	 "cryptoProperties": {"assetType": "certificate", "certificateProperties": {"signatureAlgorithmRef": "s1"}}},
	algo("s1", "SHA1-RSA", "signature"),
	{"type": "cryptographic-asset", "bom-ref": "p1", "name": "TLSv1.3", "cryptoProperties": {"assetType": "protocol"}},
	{"type": "cryptographic-asset", "bom-ref": "k1", "name": "key@1234", "cryptoProperties": {"assetType": "related-crypto-material"}},
	# uuid 裡剛好有 "ec"：不能被當成橢圓曲線金鑰
	{"type": "cryptographic-asset", "bom-ref": "k2", "name": "key@0e96d3e7-2151-45b6-b750-24d0ecdcfe85", "cryptoProperties": {"assetType": "related-crypto-material"}},
	{"type": "library", "bom-ref": "lib1", "name": "bcprov"},
]}

result_of(ref) := r if {
	some f in quantum_safe.findings with input as cbom
	f["bom-ref"] == ref
	r := f.result
}

test_broken_algorithms_are_na_with_reason if {
	result_of("a1") == "na"
	result_of("a5") == "na"
	some f in quantum_safe.findings with input as cbom
	f["bom-ref"] == "a1"
	startswith(f.rule, "BROKEN")
}

test_symmetric_is_quantum_safe if result_of("a2") == "quantum-safe"

test_asymmetric_is_quantum_vulnerable if result_of("a3") == "quantum-vulnerable"

test_pqc_is_quantum_safe if result_of("a4") == "quantum-safe"

test_certificate_follows_its_signature_algorithm if result_of("c1") == "quantum-vulnerable"

test_tls_is_quantum_vulnerable if result_of("p1") == "quantum-vulnerable"

test_unclassified_material_is_unknown if result_of("k1") == "unknown"

test_uuid_in_name_does_not_match if result_of("k2") == "unknown"

test_libraries_are_ignored if {
	findings := quantum_safe.findings with input as cbom
	every f in findings { f["bom-ref"] != "lib1" }
}

# 「package 只能輸出 findings」這條規則在 Rego 測試裡驗證不了（測試看得到函式，REST 回應看不到），
# 由 bash demo/cbomkit/demo.sh check 實際呼叫 CBOMkit 驗證。

test_every_finding_has_required_fields if {
	findings := quantum_safe.findings with input as cbom
	every f in findings {
		f.rule
		f.result in {"quantum-safe", "quantum-vulnerable", "na", "unknown"}
		f["bom-ref"]
	}
}

# JFR 等工具用 JCA 的完整名稱 "DiffieHellman"（沒有 primitive 也要判成量子脆弱）
test_diffie_hellman_full_name_is_quantum_vulnerable if {
	some f in quantum_safe.findings with input as {"components": [algo("d1", "DiffieHellman", "")]}
	f.result == "quantum-vulnerable"
}

# 混合式金鑰交換（例如 TLS 的 X25519MLKEM768，名稱沒有連字號）含後量子成分：判成 quantum-safe，不是 quantum-vulnerable
test_hybrid_kem_is_quantum_safe if {
	some f in quantum_safe.findings with input as {"components": [algo("h1", "X25519MLKEM768", "kem")]}
	f.result == "quantum-safe"
}
