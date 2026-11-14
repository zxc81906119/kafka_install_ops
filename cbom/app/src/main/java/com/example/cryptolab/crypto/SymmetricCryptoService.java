package com.example.cryptolab.crypto;

import com.example.cryptolab.config.LabProperties;
import org.bouncycastle.crypto.InvalidCipherTextException;
import org.bouncycastle.crypto.engines.AESEngine;
import org.bouncycastle.crypto.modes.GCMBlockCipher;
import org.bouncycastle.crypto.modes.GCMModeCipher;
import org.bouncycastle.crypto.params.AEADParameters;
import org.bouncycastle.crypto.params.KeyParameter;
import org.springframework.stereotype.Service;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 示範的類別：對稱式加密（加密與解密用同一把金鑰）。端點：{@code POST /api/lab/symmetric/{algorithm}}。
 * <p>
 * 這個檔裡的例子（端點名稱 → expected-inventory.json 的 id）：
 * <ul>
 *   <li>[好例子] aes-gcm、aes-gcm-bc → SYM-AES-GCM（-bc 用 BouncyCastle 輕量 API）；chacha20-poly1305 → SYM-CHACHA</li>
 *   <li>[舊做法] aes-cbc → SYM-AES-CBC（AES-256-CBC＋PKCS5Padding：沒有完整性保護，容易受 padding oracle 攻擊）</li>
 *   <li>[壞例子·故意] aes-cbc-static-iv-weak → SYM-AES-CBC（固定 IV）；aes-ecb-weak → SYM-AES-ECB；
 *       des-weak → SYM-DES；3des-weak → SYM-3DES</li>
 * </ul>
 * 注意 SYM-AES-CBC 一項同時涵蓋隨機 IV（舊做法）與固定 IV（壞例子）：CBOM 只記錄演算法，看不出 IV 怎麼來的。
 * 另外 AES 金鑰寫死在 application.yml 也是壞例子（見建構子）。
 * 四種標記的定義、「pipeline 判定」的等級見 README.md。
 * <p>
 * <b>維護注意：</b>每個 case 都刻意直接寫出 {@code getInstance("演算法字串")}，不抽成共用 helper。
 * 原始碼 CBOM 掃描器（sonar-cryptography）是靠「呼叫點上的字串常數」辨識演算法的，
 * 改成 {@code helper(algorithmVariable)} 之後掃描器很可能就抓不到，lab 的覆蓋率結果會跟著改變。
 * 新增演算法的步驟見 README.md 的「怎麼加一個新例子」。
 */
@Service
public class SymmetricCryptoService {

    public static final List<String> ALGORITHMS = List.of(
            "aes-gcm", "aes-gcm-bc", "chacha20-poly1305", "aes-cbc",
            "aes-cbc-static-iv-weak", "aes-ecb-weak", "des-weak", "3des-weak");

    // [壞例子·故意] 全部是 0 的固定 IV（16 個位元組 = AES 的區塊大小）：同樣的明文每次都加密成同樣的密文開頭，
    //   攻擊者看得出哪些資料相同。給 aes-cbc-static-iv-weak 用
    //   標準答案：SYM-AES-CBC　pipeline 判定：通過（規則只看演算法是 AES，看不出 IV 是固定的）
    private static final byte[] STATIC_IV = new byte[16];

    // AES 金鑰來自設定檔（壞例子，說明在建構子）；其他三把在 app 啟動時隨機產生
    private final SecretKey aesKey;
    private final SecretKey chachaKey;
    private final SecretKey desKey;
    private final SecretKey tripleDesKey;
    // [好例子] SecureRandom：產生 IV 與 nonce 用的安全亂數
    //   標準答案：RNG　pipeline 判定：通過
    private final SecureRandom secureRandom = new SecureRandom();

    public SymmetricCryptoService(LabProperties props) throws GeneralSecurityException {
        // [壞例子·故意] AES-256 金鑰寫死在 application.yml（lab.crypto.aes-key-base64）：拿得到設定檔的人就能解密所有資料；
        //   正式環境應放在 KMS 或 Vault
        //   標準答案：SECRET-YAML　pipeline 判定：違規（hardcoded-secret：秘密掃描在 application.yml 命中這把金鑰）
        this.aesKey = new SecretKeySpec(Base64.getDecoder().decode(props.crypto().aesKeyBase64()), "AES");

        // [好例子] ChaCha20 的金鑰，256 位元（ChaCha20 只有這一種長度）
        //   標準答案：SYM-CHACHA（用的金鑰，沒有獨立的項目）　pipeline 判定：通過
        KeyGenerator chachaGen = KeyGenerator.getInstance("ChaCha20");
        chachaGen.init(256);
        this.chachaKey = chachaGen.generateKey();

        // [壞例子·故意] DES 的金鑰只有 56 位元：現在的硬體幾小時內就能把所有金鑰試完
        //   標準答案：SYM-DES　pipeline 判定：違規
        KeyGenerator desGen = KeyGenerator.getInstance("DES");
        desGen.init(56);
        this.desKey = desGen.generateKey();

        // [壞例子·故意] 3DES（JCA 的名稱是 DESede）的金鑰：168 位元 = 三把 56 位元的 DES 金鑰；3DES 已被禁用（原因見下面的 case）
        //   標準答案：SYM-3DES　pipeline 判定：違規
        KeyGenerator tripleDesGen = KeyGenerator.getInstance("DESede");
        tripleDesGen.init(168);
        this.tripleDesKey = tripleDesGen.generateKey();
    }

    /** 加密的結果：iv（GCM / ChaCha20 是 nonce；ECB 沒有，是空陣列）與密文 */
    private record Sealed(byte[] iv, byte[] ciphertext) {
    }

    /** AEAD 模式（GCM）的附加驗證資料：不加密、但會被驗證，解密時必須相同 */
    private static final byte[] AAD = "crypto-lab".getBytes(StandardCharsets.UTF_8);

    public Map<String, Object> encryptAndDecrypt(String algorithm, String plaintext) throws Exception {
        byte[] data = plaintext.getBytes(StandardCharsets.UTF_8);
        Sealed sealed;
        byte[] decrypted;
        switch (algorithm) {
            // [好例子] AES-256-GCM：同時加密與驗證完整性（AEAD），現行建議的寫法。第一個 case 用 JCA，
            //   第二個用 BouncyCastle 輕量 API（實際的呼叫在最下面的 bouncyCastleGcm）。
            //   12 = nonce 的位元組數（96 位元，GCM 的建議長度，每次加密都要換新的）；128 = 驗證標籤的位元數（最長、最安全）
            //   標準答案：SYM-AES-GCM（兩個 case 同一項）　pipeline 判定：通過
            case "aes-gcm" -> {
                byte[] iv = randomBytes(12);
                Cipher enc = Cipher.getInstance("AES/GCM/NoPadding");
                enc.init(Cipher.ENCRYPT_MODE, aesKey, new GCMParameterSpec(128, iv));
                enc.updateAAD(AAD);
                byte[] ct = enc.doFinal(data);
                Cipher dec = Cipher.getInstance("AES/GCM/NoPadding");
                dec.init(Cipher.DECRYPT_MODE, aesKey, new GCMParameterSpec(128, iv));
                dec.updateAAD(AAD);
                decrypted = dec.doFinal(ct);
                sealed = new Sealed(iv, ct);
            }
            case "aes-gcm-bc" -> {
                byte[] iv = randomBytes(12);
                byte[] ct = bouncyCastleGcm(true, iv, data);
                decrypted = bouncyCastleGcm(false, iv, ct);
                sealed = new Sealed(iv, ct);
            }
            // [好例子] ChaCha20-Poly1305：另一種 AEAD，沒有 AES 硬體加速的裝置上比較快。12 = nonce 的位元組數（規格固定）
            //   標準答案：SYM-CHACHA　pipeline 判定：通過
            case "chacha20-poly1305" -> {
                byte[] nonce = randomBytes(12);
                Cipher enc = Cipher.getInstance("ChaCha20-Poly1305");
                enc.init(Cipher.ENCRYPT_MODE, chachaKey, new IvParameterSpec(nonce));
                byte[] ct = enc.doFinal(data);
                Cipher dec = Cipher.getInstance("ChaCha20-Poly1305");
                dec.init(Cipher.DECRYPT_MODE, chachaKey, new IvParameterSpec(nonce));
                decrypted = dec.doFinal(ct);
                sealed = new Sealed(nonce, ct);
            }
            // [舊做法] AES-256-CBC＋PKCS5Padding，IV 每次隨機：還沒被破解，但只加密、不驗證完整性，
            //   解密端若洩漏「填充對不對」就會被 padding oracle 攻擊；新系統改用 GCM。16 = IV 的位元組數（AES 的區塊大小）
            //   標準答案：SYM-AES-CBC　pipeline 判定：通過（規則只看演算法是 AES，不看模式）
            case "aes-cbc" -> {
                byte[] iv = randomBytes(16);
                Cipher enc = Cipher.getInstance("AES/CBC/PKCS5Padding");
                enc.init(Cipher.ENCRYPT_MODE, aesKey, new IvParameterSpec(iv));
                byte[] ct = enc.doFinal(data);
                Cipher dec = Cipher.getInstance("AES/CBC/PKCS5Padding");
                dec.init(Cipher.DECRYPT_MODE, aesKey, new IvParameterSpec(iv));
                decrypted = dec.doFinal(ct);
                sealed = new Sealed(iv, ct);
            }
            // [壞例子·故意] AES-CBC 配固定的全零 IV（上面的 STATIC_IV）：寫法和 aes-cbc 一樣，只差 IV 不是隨機的
            //   標準答案：SYM-AES-CBC（和 aes-cbc 同一項）　pipeline 判定：通過
            //   （「用法」的問題：CBOM 只記錄演算法，盤點工具與規則都看不出 IV 是固定的，要靠程式碼審查）
            case "aes-cbc-static-iv-weak" -> {
                Cipher enc = Cipher.getInstance("AES/CBC/PKCS5Padding");
                enc.init(Cipher.ENCRYPT_MODE, aesKey, new IvParameterSpec(STATIC_IV));
                byte[] ct = enc.doFinal(data);
                Cipher dec = Cipher.getInstance("AES/CBC/PKCS5Padding");
                dec.init(Cipher.DECRYPT_MODE, aesKey, new IvParameterSpec(STATIC_IV));
                decrypted = dec.doFinal(ct);
                sealed = new Sealed(STATIC_IV, ct);
            }
            // [壞例子·故意] AES-ECB：每個區塊各自加密、沒有 IV，相同的明文區塊會變成相同的密文區塊，看得出資料的樣式
            //   標準答案：SYM-AES-ECB　pipeline 判定：通過（規則只看演算法是 AES，不看模式，所以不會判違規）
            case "aes-ecb-weak" -> {
                Cipher enc = Cipher.getInstance("AES/ECB/PKCS5Padding");
                enc.init(Cipher.ENCRYPT_MODE, aesKey);
                byte[] ct = enc.doFinal(data);
                Cipher dec = Cipher.getInstance("AES/ECB/PKCS5Padding");
                dec.init(Cipher.DECRYPT_MODE, aesKey);
                decrypted = dec.doFinal(ct);
                sealed = new Sealed(new byte[0], ct);
            }
            // [壞例子·故意] DES：金鑰只有 56 位元，可以暴力破解。8 = IV 的位元組數（DES 的區塊大小）
            //   標準答案：SYM-DES　pipeline 判定：違規
            case "des-weak" -> {
                byte[] iv = randomBytes(8);
                Cipher enc = Cipher.getInstance("DES/CBC/PKCS5Padding");
                enc.init(Cipher.ENCRYPT_MODE, desKey, new IvParameterSpec(iv));
                byte[] ct = enc.doFinal(data);
                Cipher dec = Cipher.getInstance("DES/CBC/PKCS5Padding");
                dec.init(Cipher.DECRYPT_MODE, desKey, new IvParameterSpec(iv));
                decrypted = dec.doFinal(ct);
                sealed = new Sealed(iv, ct);
            }
            // [壞例子·故意] 3DES（DESede）：區塊只有 64 位元，同一把金鑰加密大量資料後會出現碰撞（Sweet32 攻擊），已被禁用。
            //   8 = IV 的位元組數（區塊大小）
            //   標準答案：SYM-3DES　pipeline 判定：違規
            case "3des-weak" -> {
                byte[] iv = randomBytes(8);
                Cipher enc = Cipher.getInstance("DESede/CBC/PKCS5Padding");
                enc.init(Cipher.ENCRYPT_MODE, tripleDesKey, new IvParameterSpec(iv));
                byte[] ct = enc.doFinal(data);
                Cipher dec = Cipher.getInstance("DESede/CBC/PKCS5Padding");
                dec.init(Cipher.DECRYPT_MODE, tripleDesKey, new IvParameterSpec(iv));
                decrypted = dec.doFinal(ct);
                sealed = new Sealed(iv, ct);
            }
            default -> throw new IllegalArgumentException("Unsupported symmetric algorithm: " + algorithm);
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("algorithm", algorithm);
        result.put("iv", Base64.getEncoder().encodeToString(sealed.iv()));
        result.put("ciphertext", Base64.getEncoder().encodeToString(sealed.ciphertext()));
        result.put("roundTripOk", Arrays.equals(data, decrypted));
        return result;
    }

    /**
     * [好例子] AES-256-GCM，BouncyCastle 輕量 API 的寫法（給 aes-gcm-bc 用；這裡沒有附加驗證資料）。
     * encrypt：true = 加密、false = 解密；128 = 驗證標籤的位元數。
     * 輸出的緩衝區先照最大可能的長度配置，最後依實際寫入的長度（len）裁切。
     * 標準答案：SYM-AES-GCM　pipeline 判定：通過
     */
    private byte[] bouncyCastleGcm(boolean encrypt, byte[] iv, byte[] input) throws InvalidCipherTextException {
        GCMModeCipher gcm = GCMBlockCipher.newInstance(AESEngine.newInstance());
        gcm.init(encrypt, new AEADParameters(new KeyParameter(aesKey.getEncoded()), 128, iv));
        byte[] out = new byte[gcm.getOutputSize(input.length)];
        int len = gcm.processBytes(input, 0, input.length, out, 0);
        len += gcm.doFinal(out, len);
        return Arrays.copyOf(out, len);
    }

    /** 用 SecureRandom 產生 length 個位元組的亂數（IV、nonce 用）。 */
    private byte[] randomBytes(int length) {
        byte[] bytes = new byte[length];
        secureRandom.nextBytes(bytes);
        return bytes;
    }
}
