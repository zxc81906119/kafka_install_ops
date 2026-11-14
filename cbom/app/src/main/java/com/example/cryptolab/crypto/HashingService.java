package com.example.cryptolab.crypto;

import com.example.cryptolab.config.LabProperties;
import org.bouncycastle.crypto.digests.SHA256Digest;
import org.bouncycastle.crypto.digests.SHA3Digest;
import org.bouncycastle.crypto.macs.HMac;
import org.bouncycastle.crypto.params.KeyParameter;
import org.springframework.stereotype.Service;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 示範的類別：雜湊與訊息鑑別碼（MAC）。端點：{@code POST /api/lab/hash/{algorithm}}。
 * <p>
 * 這個檔裡的例子（端點名稱 → expected-inventory.json 的 id）：
 * <ul>
 *   <li>[好例子] sha256、sha256-bc → HASH-SHA256；sha512 → HASH-SHA512；sha3-256、sha3-256-bc → HASH-SHA3；
 *       hmac-sha256、hmac-sha256-bc → MAC-HMAC256；hmac-sha512 → MAC-HMAC512</li>
 *   <li>[舊做法] hmac-sha1-legacy → MAC-HMACSHA1（HMAC 的用法還沒被攻破，但 SHA-1 應淘汰）</li>
 *   <li>[壞例子·故意] md5-weak → HASH-MD5；sha1-weak → HASH-SHA1；hmac-md5-weak → MAC-HMACMD5</li>
 * </ul>
 * 名稱結尾是 {@code -bc} 的用 BouncyCastle 輕量 API（不經過 JDK 的 JCA），其他用 JCA。
 * 四種標記的定義、「pipeline 判定」的等級見 README.md。
 * <p>
 * <b>維護注意：</b>每個 case 都刻意直接寫出 {@code getInstance("演算法字串")}，不抽成共用 helper。
 * 原始碼 CBOM 掃描器（sonar-cryptography）是靠「呼叫點上的字串常數」辨識演算法的，
 * 改成 {@code helper(algorithmVariable)} 之後掃描器很可能就抓不到，lab 的覆蓋率結果會跟著改變。
 * 新增演算法的步驟見 README.md 的「怎麼加一個新例子」。
 */
@Service
public class HashingService {

    public static final List<String> ALGORITHMS = List.of(
            "sha256", "sha512", "sha3-256", "sha256-bc", "sha3-256-bc",
            "hmac-sha256", "hmac-sha512", "hmac-sha256-bc", "hmac-sha1-legacy",
            "md5-weak", "sha1-weak", "hmac-md5-weak");

    private final byte[] macKey;

    public HashingService(LabProperties props) {
        // [壞例子·故意] HMAC 的金鑰是寫死在 application.yml 的 secret（lab.jwt.hmac-secret），而且和 JWT HS256 共用同一把：
        //   lab 只需要「一把寫在設定檔裡的 secret」來示範；正式環境每個用途都應該有自己的金鑰，而且不放設定檔
        //   標準答案：SECRET-YAML　pipeline 判定：違規（hardcoded-secret：秘密掃描在 application.yml 命中這把 secret）
        this.macKey = props.jwt().hmacSecret().getBytes(StandardCharsets.UTF_8);
    }

    public Map<String, Object> digest(String algorithm, String input) throws GeneralSecurityException {
        byte[] data = input.getBytes(StandardCharsets.UTF_8);
        byte[] out = switch (algorithm) {
            // [好例子] SHA-256、SHA-512、SHA3-256（JCA 的 MessageDigest）：目前沒有已知的碰撞，量子電腦也只讓強度減半
            //   標準答案：HASH-SHA256、HASH-SHA512、HASH-SHA3（依序）　pipeline 判定：通過
            case "sha256" -> MessageDigest.getInstance("SHA-256").digest(data);
            case "sha512" -> MessageDigest.getInstance("SHA-512").digest(data);
            case "sha3-256" -> MessageDigest.getInstance("SHA3-256").digest(data);
            // [好例子] SHA-256、SHA3-256（BouncyCastle 輕量 API）：演算法同上，只是不經過 JCA，
            //   用來看掃描工具認不認得 BouncyCastle 的寫法。SHA3Digest(256) 的 256 是輸出的位元數
            //   標準答案：HASH-SHA256、HASH-SHA3（依序）　pipeline 判定：通過
            case "sha256-bc" -> {
                SHA256Digest d = new SHA256Digest();
                d.update(data, 0, data.length);
                byte[] o = new byte[d.getDigestSize()];
                d.doFinal(o, 0);
                yield o;
            }
            case "sha3-256-bc" -> {
                SHA3Digest d = new SHA3Digest(256);
                d.update(data, 0, data.length);
                byte[] o = new byte[d.getDigestSize()];
                d.doFinal(o, 0);
                yield o;
            }
            // [好例子] HmacSHA256、HmacSHA512（JCA 的 Mac）與 HMac(SHA256Digest)（BouncyCastle）：演算法本身沒問題
            //   （金鑰寫死在設定檔是另一個問題，見建構子）
            //   標準答案：MAC-HMAC256、MAC-HMAC512、MAC-HMAC256（依序）　pipeline 判定：通過
            case "hmac-sha256" -> {
                Mac mac = Mac.getInstance("HmacSHA256");
                mac.init(new SecretKeySpec(macKey, "HmacSHA256"));
                yield mac.doFinal(data);
            }
            case "hmac-sha512" -> {
                Mac mac = Mac.getInstance("HmacSHA512");
                mac.init(new SecretKeySpec(macKey, "HmacSHA512"));
                yield mac.doFinal(data);
            }
            case "hmac-sha256-bc" -> {
                HMac hmac = new HMac(new SHA256Digest());
                hmac.init(new KeyParameter(macKey));
                hmac.update(data, 0, data.length);
                byte[] o = new byte[hmac.getMacSize()];
                hmac.doFinal(o, 0);
                yield o;
            }
            // [舊做法] HmacSHA1：HMAC 的用法不受 SHA-1 碰撞影響，還沒被攻破，但 SHA-1 已在淘汰名單，新系統不要用
            //   標準答案：MAC-HMACSHA1　pipeline 判定：警告（規則 hmac-sha1：HMAC 搭 SHA-1 仍可用，但建議改 HMAC-SHA256）
            case "hmac-sha1-legacy" -> {
                Mac mac = Mac.getInstance("HmacSHA1");
                mac.init(new SecretKeySpec(macKey, "HmacSHA1"));
                yield mac.doFinal(data);
            }
            // [壞例子·故意] MD5：已有實際碰撞，幾秒內就能做出兩份雜湊相同的資料
            //   標準答案：HASH-MD5　pipeline 判定：違規
            case "md5-weak" -> MessageDigest.getInstance("MD5").digest(data);
            // [壞例子·故意] SHA-1：2017 年起已有實際碰撞（SHAttered）
            //   標準答案：HASH-SHA1　pipeline 判定：違規
            case "sha1-weak" -> MessageDigest.getInstance("SHA-1").digest(data);
            // [壞例子·故意] HmacMD5：搭配的雜湊是 MD5
            //   標準答案：MAC-HMACMD5　pipeline 判定：違規
            case "hmac-md5-weak" -> {
                Mac mac = Mac.getInstance("HmacMD5");
                mac.init(new SecretKeySpec(macKey, "HmacMD5"));
                yield mac.doFinal(data);
            }
            default -> throw new IllegalArgumentException("Unsupported hash algorithm: " + algorithm);
        };

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("algorithm", algorithm);
        result.put("hex", HexFormat.of().formatHex(out));
        result.put("bits", out.length * 8);
        return result;
    }
}
