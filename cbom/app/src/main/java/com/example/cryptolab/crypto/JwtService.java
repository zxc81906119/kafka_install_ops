package com.example.cryptolab.crypto;

import com.example.cryptolab.config.LabProperties;
import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.JWSSigner;
import com.nimbusds.jose.JWSVerifier;
import com.nimbusds.jose.crypto.ECDSASigner;
import com.nimbusds.jose.crypto.ECDSAVerifier;
import com.nimbusds.jose.crypto.MACSigner;
import com.nimbusds.jose.crypto.MACVerifier;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.crypto.RSASSAVerifier;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.PlainJWT;
import com.nimbusds.jwt.SignedJWT;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.text.ParseException;
import java.time.Instant;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 示範的類別：JWT 的簽發與驗證（函式庫 nimbus-jose-jwt，由 spring-security-oauth2-jose 帶入）。
 * 端點：{@code POST /api/lab/jwt/{algorithm}}。
 * <p>
 * 這個檔裡的例子（端點名稱 → expected-inventory.json 的 id）：
 * <ul>
 *   <li>[好例子] HS256 → JWT-HS256（HMAC-SHA256，對稱式；演算法沒問題，但 secret 寫死在設定檔是壞例子，見建構子）</li>
 *   <li>[可接受·量子脆弱] RS256 → JWT-RS256（RSA-2048 PKCS#1 v1.5＋SHA-256）；PS256 → JWT-PS256（RSA-PSS）；
 *       ES256 → JWT-ES256（ECDSA P-256）</li>
 *   <li>[壞例子·故意] none-weak → JWT-NONE（alg=none，沒有簽章）</li>
 * </ul>
 * 盤點的觀點：這裡的演算法是透過第三方函式庫（nimbus）使用的，程式裡沒有 {@code getInstance("…")}，
 * 所以原始碼掃描看不到；要靠執行期的錄製（JFR）看到 nimbus 向 JCA 要了什麼演算法。
 * alg=none 沒有用到任何演算法，兩種方法都看不到（49 項裡 pipeline 找不到的 3 項之一，見 README.md）。
 */
@Service
public class JwtService {

    public static final List<String> ALGORITHMS = List.of("HS256", "RS256", "PS256", "ES256", "none-weak");

    private final KeyMaterialService keys;
    private final byte[] hmacSecret;
    private final String issuer;

    public JwtService(KeyMaterialService keys, LabProperties props) {
        this.keys = keys;
        // [壞例子·故意] HS256 的 secret 寫死在 application.yml（lab.jwt.hmac-secret）：拿得到設定檔的人就能偽造 token
        //   標準答案：SECRET-YAML　pipeline 判定：違規（hardcoded-secret：秘密掃描在 application.yml 命中這把 secret）
        this.hmacSecret = props.jwt().hmacSecret().getBytes(StandardCharsets.UTF_8);
        this.issuer = props.jwt().issuer();
    }

    public Map<String, Object> issueAndVerify(String algorithm, String subject) throws JOSEException, ParseException {
        // 900 秒 = token 的有效期 15 分鐘；"lab.read" 只是示範用的 scope
        JWTClaimsSet claims = new JWTClaimsSet.Builder()
                .issuer(issuer)
                .subject(subject)
                .jwtID(UUID.randomUUID().toString())
                .issueTime(new Date())
                .expirationTime(Date.from(Instant.now().plusSeconds(900)))
                .claim("scope", "lab.read")
                .build();

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("algorithm", algorithm);

        if ("none-weak".equals(algorithm)) {
            // [壞例子·故意] alg=none 的未簽章 JWT：沒有完整性保護，任何人都能竄改 claims
            //   標準答案：JWT-NONE　pipeline 判定：無（找不到：沒有演算法就沒有 CBOM 元件，只能靠程式碼審查）
            String token = new PlainJWT(claims).serialize();
            result.put("token", token);
            result.put("verified", false);
            result.put("warning", "alg=none tokens carry no integrity protection");
            return result;
        }

        // keyID 只是標示用的名稱，例如 rs256-lab
        JWSAlgorithm alg = JWSAlgorithm.parse(algorithm);
        SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(alg).keyID(algorithm.toLowerCase() + "-lab").build(), claims);
        jwt.sign(signerFor(alg));
        String token = jwt.serialize();

        SignedJWT parsed = SignedJWT.parse(token);
        result.put("token", token);
        result.put("verified", parsed.verify(verifierFor(alg)));
        result.put("claims", parsed.getJWTClaimsSet().toJSONObject());
        return result;
    }

    /** 依演算法挑簽章用的物件（驗證用的在下面的 verifierFor，兩邊的標註相同）。 */
    private JWSSigner signerFor(JWSAlgorithm alg) throws JOSEException {
        // [好例子] HS256 = HMAC-SHA256：演算法沒問題（secret 寫死的問題見建構子）
        //   標準答案：JWT-HS256　pipeline 判定：通過
        if (JWSAlgorithm.HS256.equals(alg)) {
            return new MACSigner(hmacSecret);
        }
        // [可接受·量子脆弱] RS256（SHA256withRSA）與 PS256（RSASSA-PSS），金鑰是 RSA-2048：現在安全，量子電腦可破解。
        //   私鑰 PEM 放在 repo 是另一個壞例子，見 KeyMaterialService
        //   標準答案：JWT-RS256、JWT-PS256　pipeline 判定：量子脆弱
        if (JWSAlgorithm.RS256.equals(alg) || JWSAlgorithm.PS256.equals(alg)) {
            return new RSASSASigner(keys.jwtRsaPrivateKey());
        }
        // [可接受·量子脆弱] ES256 = ECDSA P-256＋SHA-256：現在安全，量子電腦可破解
        //   標準答案：JWT-ES256　pipeline 判定：量子脆弱
        if (JWSAlgorithm.ES256.equals(alg)) {
            return new ECDSASigner(keys.jwtEcPrivateKey());
        }
        throw new IllegalArgumentException("Unsupported JWS algorithm: " + alg);
    }

    /** 依演算法挑驗證用的物件：和 signerFor 一一對應（好壞與標準答案的 id 相同，不重複寫）。 */
    private JWSVerifier verifierFor(JWSAlgorithm alg) throws JOSEException {
        if (JWSAlgorithm.HS256.equals(alg)) {
            return new MACVerifier(hmacSecret);
        }
        if (JWSAlgorithm.RS256.equals(alg) || JWSAlgorithm.PS256.equals(alg)) {
            return new RSASSAVerifier(keys.jwtRsaPublicKey());
        }
        if (JWSAlgorithm.ES256.equals(alg)) {
            return new ECDSAVerifier(keys.jwtEcPublicKey());
        }
        throw new IllegalArgumentException("Unsupported JWS algorithm: " + alg);
    }
}
