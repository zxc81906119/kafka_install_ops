package com.example.cryptolab.crypto;

import org.bouncycastle.crypto.digests.SHA256Digest;
import org.bouncycastle.crypto.generators.HKDFBytesGenerator;
import org.bouncycastle.crypto.params.HKDFParameters;
import org.springframework.stereotype.Service;

import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.OAEPParameterSpec;
import javax.crypto.spec.PSource;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.MGF1ParameterSpec;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 示範的類別：金鑰交換與金鑰包裝。端點：{@code POST /api/lab/key-exchange/{algorithm}}。
 * <p>
 * 這一類全部是「量子脆弱」，而且是後量子遷移最優先的部分：攻擊者可以現在先錄下密文，
 * 等有量子電腦再解開（harvest now, decrypt later）。所以這個檔沒有 [好例子]。
 * <p>
 * 這個檔裡的例子（端點名稱 → expected-inventory.json 的 id）：
 * <ul>
 *   <li>[可接受·量子脆弱] ecdh-p256-hkdf → KEX-ECDH＋KDF-HKDF；x25519-hkdf → KEX-X25519＋KDF-HKDF；
 *       dh-2048 → KEX-DH；rsa-oaep-wrap → KEM-RSA-OAEP</li>
 *   <li>[壞例子·故意] rsa-pkcs1-wrap-weak → KEM-RSA-PKCS1（Bleichenbacher 攻擊）；dh-1024-weak → KEX-DH（金鑰太短）</li>
 * </ul>
 * 注意 KEX-DH 一項同時涵蓋 2048（可接受）與 1024（壞例子）：標準答案「找到」不代表壞例子被分辨出來。
 * 四種標記的定義、「pipeline 判定」的等級見 README.md。
 * <p>
 * <b>維護注意：</b>每個 case 都刻意直接寫出 {@code getInstance("演算法字串")}，不抽成共用 helper。
 * 原始碼 CBOM 掃描器（sonar-cryptography）是靠「呼叫點上的字串常數」辨識演算法的，
 * 改成 {@code helper(algorithmVariable)} 之後掃描器很可能就抓不到，lab 的覆蓋率結果會跟著改變。
 * 新增演算法的步驟見 README.md 的「怎麼加一個新例子」。
 */
@Service
public class KeyExchangeService {

    public static final List<String> ALGORITHMS = List.of(
            "ecdh-p256-hkdf", "x25519-hkdf", "dh-2048", "rsa-oaep-wrap", "rsa-pkcs1-wrap-weak", "dh-1024-weak");

    private final KeyPair rsaKeyPair;

    public KeyExchangeService() throws GeneralSecurityException {
        // [可接受·量子脆弱] RSA-2048 金鑰對，app 啟動時產生一次，給下面兩個「金鑰包裝」的 case 用。
        //   2048 是金鑰的位元數（現行最低要求；低於 2048 規則判違規）
        //   標準答案：KEM-RSA-OAEP、KEM-RSA-PKCS1（兩項用的金鑰，沒有獨立的項目）　pipeline 判定：量子脆弱
        KeyPairGenerator gen = KeyPairGenerator.getInstance("RSA");
        gen.initialize(2048);
        this.rsaKeyPair = gen.generateKeyPair();
    }

    public Map<String, Object> run(String algorithm) throws GeneralSecurityException {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("algorithm", algorithm);
        switch (algorithm) {
            // [可接受·量子脆弱] ECDH，曲線 P-256（JCA 的名稱是 secp256r1）；雙方各產生一把金鑰對，
            //   算出共享秘密後用 HKDF 導出對稱金鑰（agree 的最後一個參數 true = 要做 HKDF）
            //   標準答案：KEX-ECDH、KDF-HKDF　pipeline 判定：量子脆弱（HKDF 本身：通過）
            case "ecdh-p256-hkdf" -> {
                KeyPairGenerator gen = KeyPairGenerator.getInstance("EC");
                gen.initialize(new ECGenParameterSpec("secp256r1"));
                agree(result, "ECDH", gen.generateKeyPair(), gen.generateKeyPair(), true);
            }
            // [可接受·量子脆弱] X25519（JCA 的 KeyAgreement 名稱是 XDH）＋ HKDF：現代的橢圓曲線金鑰交換
            //   標準答案：KEX-X25519、KDF-HKDF　pipeline 判定：量子脆弱（HKDF 本身：通過）
            case "x25519-hkdf" -> {
                KeyPairGenerator gen = KeyPairGenerator.getInstance("X25519");
                agree(result, "XDH", gen.generateKeyPair(), gen.generateKeyPair(), true);
            }
            // [可接受·量子脆弱] 傳統的 Diffie-Hellman，2048 位元（現行最低要求）。
            //   DH 的雙方必須用同一組參數（質數 p 與底數 g），所以 bob 的產生器直接拿 alice 公鑰裡的參數來初始化。
            //   agree 的最後一個參數 false = 不做 HKDF，只比對雙方算出的共享秘密
            //   標準答案：KEX-DH　pipeline 判定：量子脆弱
            case "dh-2048" -> {
                KeyPairGenerator gen = KeyPairGenerator.getInstance("DH");
                gen.initialize(2048);
                KeyPair alice = gen.generateKeyPair();
                KeyPairGenerator bobGen = KeyPairGenerator.getInstance("DH");
                bobGen.initialize(((javax.crypto.interfaces.DHPublicKey) alice.getPublic()).getParams());
                agree(result, "DH", alice, bobGen.generateKeyPair(), false);
            }
            // [壞例子·故意] Diffie-Hellman 1024 位元：金鑰太短，有國家級資源的攻擊者算得出來（Logjam 攻擊的等級）。
            //   寫法和上面的 dh-2048 完全一樣，只差 initialize 的數字
            //   標準答案：KEX-DH（和 dh-2048 同一項）　pipeline 判定：違規（weak-key：DH 金鑰 1024 位元太短；執行期有錄到這個長度）
            case "dh-1024-weak" -> {
                KeyPairGenerator gen = KeyPairGenerator.getInstance("DH");
                gen.initialize(1024);
                KeyPair alice = gen.generateKeyPair();
                KeyPairGenerator bobGen = KeyPairGenerator.getInstance("DH");
                bobGen.initialize(((javax.crypto.interfaces.DHPublicKey) alice.getPublic()).getParams());
                agree(result, "DH", alice, bobGen.generateKeyPair(), false);
            }
            // [可接受·量子脆弱] RSA-OAEP 包裝一把 AES-256 資料金鑰：OAEP 是現行建議的 RSA 加密填充方式。
            //   OAEPParameterSpec 的四個參數：雜湊 SHA-256、遮罩函式 MGF1、MGF1 用的雜湊 SHA-256、標籤用預設（空的）。
            //   演算法字串裡的 ECB 只是 JCA 的固定寫法，RSA 沒有區塊模式
            //   標準答案：KEM-RSA-OAEP　pipeline 判定：量子脆弱
            case "rsa-oaep-wrap" -> {
                SecretKey dataKey = newAesKey();
                OAEPParameterSpec oaep = new OAEPParameterSpec(
                        "SHA-256", "MGF1", MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT);
                Cipher wrap = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding");
                wrap.init(Cipher.WRAP_MODE, rsaKeyPair.getPublic(), oaep);
                byte[] wrapped = wrap.wrap(dataKey);
                Cipher unwrap = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding");
                unwrap.init(Cipher.UNWRAP_MODE, rsaKeyPair.getPrivate(), oaep);
                SecretKey recovered = (SecretKey) unwrap.unwrap(wrapped, "AES", Cipher.SECRET_KEY);
                result.put("wrappedKey", Base64.getEncoder().encodeToString(wrapped));
                result.put("unwrapOk", Arrays.equals(dataKey.getEncoded(), recovered.getEncoded()));
            }
            // [壞例子·故意] RSA PKCS#1 v1.5 加密（PKCS1Padding）：解密端只要洩漏「填充對不對」，
            //   攻擊者就能逐步解出內容（Bleichenbacher 攻擊）；應改用上面的 OAEP
            //   標準答案：KEM-RSA-PKCS1　pipeline 判定：量子脆弱（規則只看 RSA 與金鑰長度，不看填充方式，所以不會判違規）
            case "rsa-pkcs1-wrap-weak" -> {
                SecretKey dataKey = newAesKey();
                Cipher wrap = Cipher.getInstance("RSA/ECB/PKCS1Padding");
                wrap.init(Cipher.WRAP_MODE, rsaKeyPair.getPublic());
                byte[] wrapped = wrap.wrap(dataKey);
                Cipher unwrap = Cipher.getInstance("RSA/ECB/PKCS1Padding");
                unwrap.init(Cipher.UNWRAP_MODE, rsaKeyPair.getPrivate());
                SecretKey recovered = (SecretKey) unwrap.unwrap(wrapped, "AES", Cipher.SECRET_KEY);
                result.put("wrappedKey", Base64.getEncoder().encodeToString(wrapped));
                result.put("unwrapOk", Arrays.equals(dataKey.getEncoded(), recovered.getEncoded()));
            }
            default -> throw new IllegalArgumentException("Unsupported key exchange algorithm: " + algorithm);
        }
        result.put("quantumVulnerable", true);
        return result;
    }

    /**
     * 模擬雙方（alice、bob）做一次金鑰交換：各自用「自己的私鑰＋對方的公鑰」算出共享秘密，兩邊應該相同。
     *
     * @param agreementAlg JCA 的 KeyAgreement 名稱：ECDH、XDH 或 DH。這裡用變數而不是字串常數，
     *                     所以原始碼掃描在這一行看不到演算法；掃描靠的是呼叫端 case 裡的 KeyPairGenerator.getInstance("…")
     * @param useHkdf      true = 再用 HKDF-SHA256 把共享秘密導出成對稱金鑰（共享秘密不能直接當金鑰用）
     */
    private static void agree(Map<String, Object> result, String agreementAlg,
                              KeyPair alice, KeyPair bob, boolean useHkdf) throws GeneralSecurityException {
        // 好壞與標準答案由呼叫端的 case 決定（KEX-ECDH、KEX-X25519、KEX-DH），這裡不重複標
        KeyAgreement a = KeyAgreement.getInstance(agreementAlg);
        a.init(alice.getPrivate());
        a.doPhase(bob.getPublic(), true);
        byte[] aliceSecret = a.generateSecret();

        KeyAgreement b = KeyAgreement.getInstance(agreementAlg);
        b.init(bob.getPrivate());
        b.doPhase(alice.getPublic(), true);
        byte[] bobSecret = b.generateSecret();

        result.put("sharedSecretMatch", Arrays.equals(aliceSecret, bobSecret));
        result.put("sharedSecretBits", aliceSecret.length * 8);
        if (useHkdf) {
            result.put("derivedKeyHex", HexFormat.of().formatHex(hkdfSha256(aliceSecret)));
        }
    }

    /**
     * HKDF-SHA256（BouncyCastle 輕量 API）把共享秘密導出成 256-bit 對稱金鑰。
     * <p>
     * [好例子] HKDF-SHA256：標準的金鑰衍生函式。32 是輸出的位元組數（= 256 位元的金鑰）。
     * salt 與 info 是寫死的字串：HKDF 的 salt 不必保密，info 用來區分用途，固定值可以接受（和密碼雜湊的 salt 不同）。
     * 標準答案：KDF-HKDF　pipeline 判定：通過
     */
    private static byte[] hkdfSha256(byte[] ikm) {
        HKDFBytesGenerator hkdf = new HKDFBytesGenerator(new SHA256Digest());
        hkdf.init(new HKDFParameters(ikm, "crypto-lab-salt".getBytes(StandardCharsets.UTF_8),
                "crypto-lab session key".getBytes(StandardCharsets.UTF_8)));
        byte[] okm = new byte[32];
        hkdf.generateBytes(okm, 0, okm.length);
        return okm;
    }

    /**
     * 產生一把隨機的 AES-256 資料金鑰，給兩個「金鑰包裝」的 case 當作被包裝的對象。
     * <p>
     * [好例子] AES 256 位元的金鑰（256 是位元數）。
     * 標準答案：無（只是被包裝的資料，沒有獨立的項目）　pipeline 判定：通過
     */
    private static SecretKey newAesKey() throws GeneralSecurityException {
        KeyGenerator gen = KeyGenerator.getInstance("AES");
        gen.init(256);
        return gen.generateKey();
    }
}
