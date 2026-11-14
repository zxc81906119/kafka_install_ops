# policies.quantum_safe 用的輔助值（不能放在 policies.quantum_safe 裡，見該檔說明）
package lib.cbomkit

import rego.v1

assets := [c | some c in input.components; c.type == "cryptographic-asset"]

by_ref := {c["bom-ref"]: c | some c in assets}
