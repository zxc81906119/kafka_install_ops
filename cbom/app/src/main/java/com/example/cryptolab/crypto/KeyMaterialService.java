package com.example.cryptolab.crypto;

import com.example.cryptolab.config.LabProperties;
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo;
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo;
import org.bouncycastle.openssl.PEMParser;
import org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter;
import org.springframework.core.io.Resource;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.io.InputStreamReader;
import java.io.Reader;
import java.nio.charset.StandardCharsets;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.interfaces.ECPrivateKey;
import java.security.interfaces.ECPublicKey;
import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;

/**
 * 從 PEM 檔載入 JWT 簽章金鑰（使用 BouncyCastle bcpkix 的 PEMParser）。這個檔本身不做密碼學運算，
 * 金鑰交給 JwtService（簽發）與 config/SecurityConfig（驗證）使用。
 * <p>
 * 這個檔牽涉到的例子（expected-inventory.json 的 id）：
 * <ul>
 *   <li>[壞例子·故意] 私鑰 PEM 放在原始碼庫（src/main/resources/crypto/jwt/jwt-rs256-private.pem、jwt-es256-private.pem）：
 *       拿得到程式的人就拿得到金鑰。標準答案：KEY-JWT-PEM　pipeline 判定：違規（private-key-in-repository）</li>
 *   <li>金鑰本身是 RSA-2048 與 EC P-256，屬於 [可接受·量子脆弱]（用法見 JwtService：JWT-RS256、JWT-PS256、JWT-ES256）</li>
 *   <li>用到的函式庫 bcpkix：標準答案 LIB-BCPKIX　pipeline 判定：資訊</li>
 * </ul>
 * 盤點的觀點：金鑰檔在 CBOM 裡是 related-crypto-material，檔案的位置由 cbomkit-theia 掃原始碼目錄找到；
 * 程式中「如何使用」由原始碼掃描與執行期錄製找到。四種標記的定義見 README.md。
 */
@Service
public class KeyMaterialService {

    private final RSAPrivateKey jwtRsaPrivateKey;
    private final RSAPublicKey jwtRsaPublicKey;
    private final ECPrivateKey jwtEcPrivateKey;
    private final ECPublicKey jwtEcPublicKey;

    public KeyMaterialService(LabProperties props) {
        this.jwtRsaPrivateKey = (RSAPrivateKey) readPrivateKey(props.jwt().rs256PrivateKey());
        this.jwtRsaPublicKey = (RSAPublicKey) readPublicKey(props.jwt().rs256PublicKey());
        this.jwtEcPrivateKey = (ECPrivateKey) readPrivateKey(props.jwt().es256PrivateKey());
        this.jwtEcPublicKey = (ECPublicKey) readPublicKey(props.jwt().es256PublicKey());
    }

    public RSAPrivateKey jwtRsaPrivateKey() {
        return jwtRsaPrivateKey;
    }

    public RSAPublicKey jwtRsaPublicKey() {
        return jwtRsaPublicKey;
    }

    public ECPrivateKey jwtEcPrivateKey() {
        return jwtEcPrivateKey;
    }

    public ECPublicKey jwtEcPublicKey() {
        return jwtEcPublicKey;
    }

    private static PrivateKey readPrivateKey(Resource resource) {
        Object pem = readPem(resource);
        // 只支援 PKCS#8 格式（檔案開頭是 BEGIN PRIVATE KEY）；BEGIN RSA / EC PRIVATE KEY 是另一種格式
        if (!(pem instanceof PrivateKeyInfo keyInfo)) {
            throw new IllegalStateException(resource + " 不是 PKCS#8 私鑰（開頭應為 BEGIN PRIVATE KEY），請用 scripts/generate-key-material.sh 重新產生");
        }
        try {
            return new JcaPEMKeyConverter().getPrivateKey(keyInfo);
        } catch (IOException e) {
            throw new IllegalStateException("Cannot convert private key " + resource, e);
        }
    }

    private static PublicKey readPublicKey(Resource resource) {
        Object pem = readPem(resource);
        if (!(pem instanceof SubjectPublicKeyInfo keyInfo)) {
            throw new IllegalStateException(resource + " 不是 X.509 公鑰（開頭應為 BEGIN PUBLIC KEY），請用 scripts/generate-key-material.sh 重新產生");
        }
        try {
            return new JcaPEMKeyConverter().getPublicKey(keyInfo);
        } catch (IOException e) {
            throw new IllegalStateException("Cannot convert public key " + resource, e);
        }
    }

    private static Object readPem(Resource resource) {
        try (Reader reader = new InputStreamReader(resource.getInputStream(), StandardCharsets.US_ASCII);
             PEMParser parser = new PEMParser(reader)) {
            return parser.readObject();
        } catch (IOException e) {
            throw new IllegalStateException("Cannot read PEM " + resource, e);
        }
    }
}
