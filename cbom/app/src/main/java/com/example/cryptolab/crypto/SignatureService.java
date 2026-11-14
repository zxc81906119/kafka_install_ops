package com.example.cryptolab.crypto;

import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters;
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters;
import org.bouncycastle.crypto.signers.Ed25519Signer;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.MGF1ParameterSpec;
import java.security.spec.PSSParameterSpec;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 示範的類別：數位簽章。端點：{@code POST /api/lab/signature/{algorithm}}。
 * <p>
 * 這一類全部是「量子脆弱」（量子電腦的 Shor 演算法可破解 RSA 與橢圓曲線），所以這個檔沒有 [好例子]。
 * <p>
 * 這個檔裡的例子（端點名稱 → expected-inventory.json 的 id）：
 * <ul>
 *   <li>[可接受·量子脆弱] rsa-sha256 → SIG-RSA（SHA256withRSA，RSA-3072）；rsa-pss → SIG-RSA-PSS（RSA-3072）；
 *       ecdsa-p256、ecdsa-p384 → SIG-ECDSA；ed25519、ed25519-bc → SIG-ED25519（-bc 用 BouncyCastle 輕量 API）</li>
 *   <li>[壞例子·故意] rsa1024-sha1-weak → SIG-RSA-SHA1（SHA1withRSA＋RSA-1024）</li>
 * </ul>
 * 四種標記的定義、「pipeline 判定」的等級見 README.md。
 * <p>
 * <b>維護注意：</b>每個 case 都刻意直接寫出 {@code getInstance("演算法字串")}，不抽成共用 helper。
 * 原始碼 CBOM 掃描器（sonar-cryptography）是靠「呼叫點上的字串常數」辨識演算法的，
 * 改成 {@code helper(algorithmVariable)} 之後掃描器很可能就抓不到，lab 的覆蓋率結果會跟著改變。
 * 新增演算法的步驟見 README.md 的「怎麼加一個新例子」。
 */
@Service
public class SignatureService {

    public static final List<String> ALGORITHMS = List.of(
            "rsa-sha256", "rsa-pss", "ecdsa-p256", "ecdsa-p384", "ed25519", "ed25519-bc", "rsa1024-sha1-weak");

    private final KeyPair rsa3072;
    private final KeyPair rsa1024;
    private final KeyPair ecP256;
    private final KeyPair ecP384;
    private final KeyPair ed25519;
    private final Ed25519PrivateKeyParameters bcEd25519Private;
    private final Ed25519PublicKeyParameters bcEd25519Public;

    /** 簽章用的金鑰對都在 app 啟動時產生一次（不存檔，重啟就換新的）。 */
    public SignatureService() throws GeneralSecurityException {
        // [可接受·量子脆弱] RSA 金鑰對，3072 位元（約等於 128 位元的安全強度；2048 是現行最低要求）
        //   標準答案：SIG-RSA、SIG-RSA-PSS（兩項用的金鑰，沒有獨立的項目）　pipeline 判定：量子脆弱
        KeyPairGenerator rsaGen = KeyPairGenerator.getInstance("RSA");
        rsaGen.initialize(3072);
        this.rsa3072 = rsaGen.generateKeyPair();

        // [壞例子·故意] RSA 金鑰對只有 1024 位元：太短，已不合格（規則的門檻是 2048）
        //   標準答案：SIG-RSA-SHA1（那一項用的金鑰）　pipeline 判定：違規（原始碼掃描會回報 RSA-1024）
        KeyPairGenerator weakRsaGen = KeyPairGenerator.getInstance("RSA");
        weakRsaGen.initialize(1024);
        this.rsa1024 = weakRsaGen.generateKeyPair();

        // [可接受·量子脆弱] 橢圓曲線金鑰對：P-256（JCA 名稱 secp256r1）與 P-384（secp384r1），給 ECDSA 用
        //   標準答案：SIG-ECDSA（用的金鑰，沒有獨立的項目）　pipeline 判定：量子脆弱
        KeyPairGenerator ecGen = KeyPairGenerator.getInstance("EC");
        ecGen.initialize(new ECGenParameterSpec("secp256r1"));
        this.ecP256 = ecGen.generateKeyPair();

        KeyPairGenerator ec384Gen = KeyPairGenerator.getInstance("EC");
        ec384Gen.initialize(new ECGenParameterSpec("secp384r1"));
        this.ecP384 = ec384Gen.generateKeyPair();

        // [可接受·量子脆弱] Ed25519 金鑰對：一把用 JCA 產生，一把用 BouncyCastle 輕量 API 產生（給 ed25519-bc 用）
        //   標準答案：SIG-ED25519（用的金鑰，沒有獨立的項目）　pipeline 判定：量子脆弱
        this.ed25519 = KeyPairGenerator.getInstance("Ed25519").generateKeyPair();

        this.bcEd25519Private = new Ed25519PrivateKeyParameters(new SecureRandom());
        this.bcEd25519Public = bcEd25519Private.generatePublicKey();
    }

    public Map<String, Object> signAndVerify(String algorithm, String message) throws GeneralSecurityException {
        byte[] data = message.getBytes(StandardCharsets.UTF_8);
        byte[] signature;
        boolean verified;
        switch (algorithm) {
            // [可接受·量子脆弱] SHA256withRSA（RSA PKCS#1 v1.5 簽章＋SHA-256），金鑰 RSA-3072：現在安全，量子電腦可破解
            //   標準答案：SIG-RSA　pipeline 判定：量子脆弱
            case "rsa-sha256" -> {
                Signature signer = Signature.getInstance("SHA256withRSA");
                signer.initSign(rsa3072.getPrivate());
                signer.update(data);
                signature = signer.sign();
                Signature verifier = Signature.getInstance("SHA256withRSA");
                verifier.initVerify(rsa3072.getPublic());
                verifier.update(data);
                verified = verifier.verify(signature);
            }
            // [可接受·量子脆弱] RSASSA-PSS，金鑰 RSA-3072：RSA 簽章現行建議的填充方式。
            //   PSSParameterSpec 的五個參數：雜湊 SHA-256、遮罩函式 MGF1、MGF1 用的雜湊 SHA-256、
            //   32 = salt 的位元組數（和 SHA-256 的輸出一樣長）、1 = 結尾欄位（標準規定的固定值）
            //   標準答案：SIG-RSA-PSS　pipeline 判定：量子脆弱
            case "rsa-pss" -> {
                PSSParameterSpec pss = new PSSParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, 32, 1);
                Signature signer = Signature.getInstance("RSASSA-PSS");
                signer.setParameter(pss);
                signer.initSign(rsa3072.getPrivate());
                signer.update(data);
                signature = signer.sign();
                Signature verifier = Signature.getInstance("RSASSA-PSS");
                verifier.setParameter(pss);
                verifier.initVerify(rsa3072.getPublic());
                verifier.update(data);
                verified = verifier.verify(signature);
            }
            // [可接受·量子脆弱] ECDSA：P-256 配 SHA-256、P-384 配 SHA-384（雜湊長度配合曲線大小）
            //   標準答案：SIG-ECDSA（兩個 case 同一項）　pipeline 判定：量子脆弱
            case "ecdsa-p256" -> {
                Signature signer = Signature.getInstance("SHA256withECDSA");
                signer.initSign(ecP256.getPrivate());
                signer.update(data);
                signature = signer.sign();
                Signature verifier = Signature.getInstance("SHA256withECDSA");
                verifier.initVerify(ecP256.getPublic());
                verifier.update(data);
                verified = verifier.verify(signature);
            }
            case "ecdsa-p384" -> {
                Signature signer = Signature.getInstance("SHA384withECDSA");
                signer.initSign(ecP384.getPrivate());
                signer.update(data);
                signature = signer.sign();
                Signature verifier = Signature.getInstance("SHA384withECDSA");
                verifier.initVerify(ecP384.getPublic());
                verifier.update(data);
                verified = verifier.verify(signature);
            }
            // [可接受·量子脆弱] Ed25519：現代的橢圓曲線簽章。第一個 case 用 JCA，第二個用 BouncyCastle 輕量 API
            //   （Ed25519Signer.init 的 true = 簽章、false = 驗證），用來看掃描工具認不認得 BouncyCastle 的寫法
            //   標準答案：SIG-ED25519（兩個 case 同一項）　pipeline 判定：量子脆弱
            case "ed25519" -> {
                Signature signer = Signature.getInstance("Ed25519");
                signer.initSign(ed25519.getPrivate());
                signer.update(data);
                signature = signer.sign();
                Signature verifier = Signature.getInstance("Ed25519");
                verifier.initVerify(ed25519.getPublic());
                verifier.update(data);
                verified = verifier.verify(signature);
            }
            case "ed25519-bc" -> {
                Ed25519Signer signer = new Ed25519Signer();
                signer.init(true, bcEd25519Private);
                signer.update(data, 0, data.length);
                signature = signer.generateSignature();
                Ed25519Signer verifier = new Ed25519Signer();
                verifier.init(false, bcEd25519Public);
                verifier.update(data, 0, data.length);
                verified = verifier.verifySignature(signature);
            }
            // [壞例子·故意] SHA1withRSA＋RSA-1024：SHA-1 已有實際碰撞、金鑰太短
            //   標準答案：SIG-RSA-SHA1　pipeline 判定：違規
            //   （原始碼掃描只會分開回報 RSA-1024 與 SHA-1；執行期的 JFR 才看得到完整的 SHA1withRSA）
            case "rsa1024-sha1-weak" -> {
                Signature signer = Signature.getInstance("SHA1withRSA");
                signer.initSign(rsa1024.getPrivate());
                signer.update(data);
                signature = signer.sign();
                Signature verifier = Signature.getInstance("SHA1withRSA");
                verifier.initVerify(rsa1024.getPublic());
                verifier.update(data);
                verified = verifier.verify(signature);
            }
            default -> throw new IllegalArgumentException("Unsupported signature algorithm: " + algorithm);
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("algorithm", algorithm);
        result.put("signature", Base64.getEncoder().encodeToString(signature));
        result.put("verified", verified);
        result.put("quantumVulnerable", true);
        return result;
    }
}
