package com.example.cryptolab.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.core.io.Resource;

/**
 * 對應 {@code application.yml} 的 {@code lab:} 區塊（由 {@code @ConfigurationPropertiesScan} 自動綁定）。
 * <pre>
 * lab:
 *   jwt:
 *     issuer:              → jwt().issuer()             JWT 的 iss，SecurityConfig 也用它驗證
 *     hmac-secret:         → jwt().hmacSecret()         HS256 / HMAC 用的金鑰（刻意寫死，示範反模式）
 *     rs256-private-key:   → jwt().rs256PrivateKey()    classpath 上的 PEM 檔
 *     rs256-public-key:    → jwt().rs256PublicKey()
 *     es256-private-key:   → jwt().es256PrivateKey()
 *     es256-public-key:    → jwt().es256PublicKey()
 *     accepted-algorithms: → jwt().acceptedAlgorithms() /api/secure/** 只接受的簽章演算法
 *   crypto:
 *     aes-key-base64:      → crypto().aesKeyBase64()    AES-256 金鑰（刻意寫死，示範反模式）
 *     pbkdf2-iterations:   → crypto().pbkdf2Iterations()
 * </pre>
 * yml 用 kebab-case（{@code hmac-secret}），Java 用 camelCase（{@code hmacSecret}），Spring 會自動轉換。
 */
@ConfigurationProperties(prefix = "lab")
public record LabProperties(Jwt jwt, Crypto crypto) {

    /** application.yml 少了 lab: 區塊時，啟動就失敗並說明缺什麼（而不是之後在某個 Service 裡出現 NullPointerException） */
    public LabProperties {
        required(jwt, "lab.jwt");
        required(crypto, "lab.crypto");
    }

    public record Jwt(
            String issuer,
            String hmacSecret,
            Resource rs256PrivateKey,
            Resource rs256PublicKey,
            Resource es256PrivateKey,
            Resource es256PublicKey,
            String acceptedAlgorithms) {

        public Jwt {
            required(issuer, "lab.jwt.issuer");
            required(hmacSecret, "lab.jwt.hmac-secret");
            required(rs256PrivateKey, "lab.jwt.rs256-private-key");
            required(rs256PublicKey, "lab.jwt.rs256-public-key");
            required(es256PrivateKey, "lab.jwt.es256-private-key");
            required(es256PublicKey, "lab.jwt.es256-public-key");
            required(acceptedAlgorithms, "lab.jwt.accepted-algorithms");
        }
    }

    public record Crypto(String aesKeyBase64, int pbkdf2Iterations) {

        public Crypto {
            required(aesKeyBase64, "lab.crypto.aes-key-base64");
        }
    }

    private static void required(Object value, String yamlKey) {
        if (value == null) {
            throw new IllegalStateException("application.yml 缺少設定 " + yamlKey);
        }
    }
}
