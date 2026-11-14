package com.example.cryptolab.crypto;

import org.springframework.stereotype.Service;

import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;

/**
 * 示範的類別：亂數產生器（用來產生 session token、重設密碼的 token、API key）。
 * 端點：{@code GET /api/lab/token/{kind}}。
 * <p>
 * 這個檔裡的例子（端點名稱 → expected-inventory.json 的 id；三個都對到同一項 RNG）：
 * <ul>
 *   <li>[好例子] secure-random（SecureRandom 的預設實作）、drbg（NIST SP 800-90A 的 DRBG）</li>
 *   <li>[壞例子·故意] util-random-weak（java.util.Random：可預測，不可用於安全用途）</li>
 * </ul>
 * 注意 RNG 一項同時涵蓋好例子與壞例子：java.util.Random 不經過 JCA，掃描工具看不到，
 * 所以標準答案的 RNG「找到」只代表找到 SecureRandom，不代表壞例子被抓到。
 * 四種標記的定義、「pipeline 判定」的等級見 README.md。
 */
@Service
public class TokenService {

    public static final List<String> KINDS = List.of("secure-random", "drbg", "util-random-weak");

    // [好例子] SecureRandom：作業系統提供亂數來源的安全亂數產生器
    //   標準答案：RNG　pipeline 判定：通過
    private final SecureRandom secureRandom = new SecureRandom();
    // [壞例子·故意] java.util.Random：線性同餘產生器，看到幾個輸出就能推算出後面全部的值，不可用來產生 token
    //   標準答案：RNG（同一項，但工具看不到這個壞例子）　pipeline 判定：無（找不到：不經過 JCA，只能靠程式碼審查）
    private final Random insecureRandom = new Random();

    public Map<String, Object> generate(String kind) throws NoSuchAlgorithmException {
        // 32 個位元組 = 256 位元的 token
        byte[] token = new byte[32];
        switch (kind) {
            // [好例子] 用上面宣告的 SecureRandom
            //   標準答案：RNG　pipeline 判定：通過
            case "secure-random" -> secureRandom.nextBytes(token);
            // [好例子] 指名要 DRBG（NIST SP 800-90A 規定的確定性亂數位元產生器）
            //   標準答案：RNG　pipeline 判定：通過
            case "drbg" -> SecureRandom.getInstance("DRBG").nextBytes(token);
            // [壞例子·故意] 用上面宣告的 java.util.Random（原因與標準答案見欄位宣告處）
            case "util-random-weak" -> insecureRandom.nextBytes(token);
            default -> throw new IllegalArgumentException("Unsupported token kind: " + kind);
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("kind", kind);
        result.put("token", Base64.getUrlEncoder().withoutPadding().encodeToString(token));
        result.put("cryptographicallySecure", !"util-random-weak".equals(kind));
        return result;
    }
}
