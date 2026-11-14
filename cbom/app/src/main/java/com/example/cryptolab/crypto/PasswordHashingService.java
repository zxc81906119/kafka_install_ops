package com.example.cryptolab.crypto;

import com.example.cryptolab.config.LabProperties;
import org.springframework.security.crypto.argon2.Argon2PasswordEncoder;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.Pbkdf2PasswordEncoder;
import org.springframework.stereotype.Service;

import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 示範的類別：密碼的儲存（把使用者的密碼算成雜湊再存）。端點：{@code POST /api/lab/password/{algorithm}}。
 * <p>
 * 這個檔裡的例子（端點名稱 → expected-inventory.json 的 id）：
 * <ul>
 *   <li>[好例子] bcrypt → PWD-BCRYPT；argon2 → PWD-ARGON2；pbkdf2-spring、pbkdf2-jca → PWD-PBKDF2</li>
 *   <li>[壞例子·故意] md5-weak → HASH-MD5（沒有 salt 的 MD5）；sha1-weak → HASH-SHA1（只算一次的 SHA-1）</li>
 * </ul>
 * 盤點的觀點：bcrypt 與 argon2 是 Spring Security 的純 Java 實作（argon2 再呼叫 BouncyCastle），不經過 JDK 的 JCA，
 * 程式裡也沒有演算法字串，所以原始碼掃描與執行期錄製都看不到：它們是 49 項裡 pipeline 找不到的 3 項之中的 2 項
 * （見 README.md）。四種標記的定義、「pipeline 判定」的等級也在 README.md。
 * <p>
 * <b>維護注意：</b>每個 case 都刻意直接寫出 {@code getInstance("演算法字串")}，不抽成共用 helper。
 * 原始碼 CBOM 掃描器（sonar-cryptography）是靠「呼叫點上的字串常數」辨識演算法的，
 * 改成 {@code helper(algorithmVariable)} 之後掃描器很可能就抓不到，lab 的覆蓋率結果會跟著改變。
 * 新增演算法的步驟見 README.md 的「怎麼加一個新例子」。
 */
@Service
public class PasswordHashingService {

    public static final List<String> ALGORITHMS =
            List.of("bcrypt", "argon2", "pbkdf2-spring", "pbkdf2-jca", "md5-weak", "sha1-weak");

    // [好例子] bcrypt：故意算得慢、自帶 salt 的密碼雜湊。12 是成本參數（2 的 12 次方 = 4096 輪；每加 1 慢一倍）
    //   標準答案：PWD-BCRYPT　pipeline 判定：無（找不到：不經過 JCA）
    private final BCryptPasswordEncoder bcrypt = new BCryptPasswordEncoder(12);
    // [好例子] Argon2id：除了慢還吃記憶體，目前最建議的密碼雜湊；參數用 Spring Security 5.8 的建議值
    //   標準答案：PWD-ARGON2　pipeline 判定：無（找不到：不經過 JCA）
    private final Argon2PasswordEncoder argon2 = Argon2PasswordEncoder.defaultsForSpringSecurity_v5_8();
    // [好例子] PBKDF2（Spring 的包裝，底下是 JCA 的 PBKDF2WithHmacSHA256）；參數用 Spring Security 5.8 的建議值
    //   標準答案：PWD-PBKDF2　pipeline 判定：通過
    private final Pbkdf2PasswordEncoder pbkdf2 = Pbkdf2PasswordEncoder.defaultsForSpringSecurity_v5_8();
    // [好例子] SecureRandom：產生 salt 用的安全亂數
    //   標準答案：RNG　pipeline 判定：通過
    private final SecureRandom secureRandom = new SecureRandom();
    private final int pbkdf2Iterations;

    public PasswordHashingService(LabProperties props) {
        this.pbkdf2Iterations = props.crypto().pbkdf2Iterations();
    }

    public Map<String, Object> hashAndVerify(String algorithm, String password) throws GeneralSecurityException {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("algorithm", algorithm);
        switch (algorithm) {
            // 以下三個 case 用上面宣告的 Spring 編碼器（好壞與標準答案見欄位宣告處）：encode = 算雜湊，matches = 驗證
            case "bcrypt" -> {
                String hash = bcrypt.encode(password);
                result.put("hash", hash);
                result.put("verified", bcrypt.matches(password, hash));
            }
            case "argon2" -> {
                String hash = argon2.encode(password);
                result.put("hash", hash);
                result.put("verified", argon2.matches(password, hash));
            }
            case "pbkdf2-spring" -> {
                String hash = pbkdf2.encode(password);
                result.put("hash", hash);
                result.put("verified", pbkdf2.matches(password, hash));
            }
            // [好例子] PBKDF2，直接用 JCA（實際的呼叫在最下面的 pbkdf2Jca）。16 = salt 的位元組數（128 位元，每個密碼各自隨機產生）
            //   標準答案：PWD-PBKDF2　pipeline 判定：通過
            case "pbkdf2-jca" -> {
                byte[] salt = new byte[16];
                secureRandom.nextBytes(salt);
                byte[] hash = pbkdf2Jca(password, salt);
                result.put("salt", HexFormat.of().formatHex(salt));
                result.put("hash", HexFormat.of().formatHex(hash));
                result.put("iterations", pbkdf2Iterations);
                result.put("verified", MessageDigest.isEqual(hash, pbkdf2Jca(password, salt)));
            }
            // [壞例子·故意] 沒有 salt 的 MD5：算得極快，可以用彩虹表或 GPU 暴力破解；MD5 本身也已有碰撞
            //   標準答案：HASH-MD5　pipeline 判定：違規
            case "md5-weak" -> {
                MessageDigest md5 = MessageDigest.getInstance("MD5");
                byte[] hash = md5.digest(password.getBytes(StandardCharsets.UTF_8));
                result.put("hash", HexFormat.of().formatHex(hash));
                result.put("verified", MessageDigest.isEqual(hash, md5.digest(password.getBytes(StandardCharsets.UTF_8))));
                result.put("warning", "MD5 must never be used for password storage");
            }
            // [壞例子·故意] 只算一次的 SHA-1：即使加了 salt，計算成本也太低，一樣能暴力破解。8 = salt 的位元組數（也偏短）
            //   標準答案：HASH-SHA1　pipeline 判定：違規
            case "sha1-weak" -> {
                byte[] salt = new byte[8];
                secureRandom.nextBytes(salt);
                MessageDigest sha1 = MessageDigest.getInstance("SHA-1");
                sha1.update(salt);
                byte[] hash = sha1.digest(password.getBytes(StandardCharsets.UTF_8));
                sha1.update(salt);
                byte[] again = sha1.digest(password.getBytes(StandardCharsets.UTF_8));
                result.put("salt", HexFormat.of().formatHex(salt));
                result.put("hash", HexFormat.of().formatHex(hash));
                result.put("verified", MessageDigest.isEqual(hash, again));
                result.put("warning", "Single-round SHA-1 is too fast for password storage");
            }
            default -> throw new IllegalArgumentException("Unsupported password algorithm: " + algorithm);
        }
        return result;
    }

    /**
     * [好例子] PBKDF2WithHmacSHA256（JCA 的 SecretKeyFactory）：重複算很多次 HMAC-SHA256，讓暴力破解變慢。
     * 迭代次數來自 application.yml 的 lab.crypto.pbkdf2-iterations（310000）；256 = 輸出雜湊的位元數。
     * 標準答案：PWD-PBKDF2　pipeline 判定：通過（規則：迭代次數不到 10000 才是警告）
     */
    private byte[] pbkdf2Jca(String password, byte[] salt) throws GeneralSecurityException {
        PBEKeySpec spec = new PBEKeySpec(password.toCharArray(), salt, pbkdf2Iterations, 256);
        try {
            SecretKeyFactory factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256");
            return factory.generateSecret(spec).getEncoded();
        } finally {
            spec.clearPassword();
        }
    }
}
