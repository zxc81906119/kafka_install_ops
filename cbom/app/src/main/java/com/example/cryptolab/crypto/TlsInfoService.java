package com.example.cryptolab.crypto;

import org.springframework.boot.ssl.SslBundle;
import org.springframework.boot.ssl.SslBundles;
import org.springframework.stereotype.Service;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.PublicKey;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.security.interfaces.ECPublicKey;
import java.security.interfaces.RSAPublicKey;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 檢視 Spring Boot SSL bundles 中的憑證與 TLS 設定。端點：{@code GET /api/lab/tls}。
 * <p>
 * 這個檔只「讀出來給人看」，自己不做密碼學運算，所以沒有好壞例子；好壞在它讀的設定與憑證檔
 * （application.yml 的 spring.ssl.bundle 與 src/main/resources/crypto/，那裡有逐項的標註）：
 * <ul>
 *   <li>server-rsa：[可接受·量子脆弱] RSA-2048 憑證 → 標準答案 CERT-RSA2048</li>
 *   <li>server-ec：[可接受·量子脆弱] EC P-256 憑證 → 標準答案 CERT-EC</li>
 *   <li>legacy-partner：[壞例子·故意] RSA-1024／SHA1withRSA 的舊憑證 → 標準答案 CERT-LEGACY</li>
 * </ul>
 * 實際對外開放的 TLS 版本與金鑰交換群組（標準答案 TLS-1.3、TLS-1.2、TLS-GROUP）要等 app 跑起來，
 * 由 pipeline 的執行期那一段（testssl.sh）掃出來。四種標記的定義見 README.md。
 */
@Service
public class TlsInfoService {

    /** 要描述的 SSL bundle 名稱，必須和 application.yml 的 spring.ssl.bundle.jks.* 相同（新增 bundle 時兩邊一起改） */
    private static final List<String> BUNDLES = List.of("server-rsa", "server-ec", "legacy-partner");

    private final SslBundles sslBundles;

    public TlsInfoService(SslBundles sslBundles) {
        this.sslBundles = sslBundles;
    }

    public Map<String, Object> describe() throws Exception {
        Map<String, Object> result = new LinkedHashMap<>();
        for (String name : BUNDLES) {
            SslBundle bundle = sslBundles.getBundle(name);
            Map<String, Object> info = new LinkedHashMap<>();
            info.put("protocol", bundle.getProtocol());
            info.put("enabledProtocols", bundle.getOptions().getEnabledProtocols());
            info.put("ciphers", bundle.getOptions().getCiphers());
            info.put("keyStore", describeStore(bundle.getStores().getKeyStore()));
            info.put("trustStore", describeStore(bundle.getStores().getTrustStore()));
            result.put(name, info);
        }

        // JVM 預設的 TLS 設定（只是列出來對照，不是這個 app 自己設定的；沒有對應的標準答案項目）
        SSLContext jvmDefault = SSLContext.getDefault();
        SSLParameters params = jvmDefault.getDefaultSSLParameters();
        result.put("jvmDefaultProtocols", params.getProtocols());
        result.put("jvmDefaultCipherSuiteCount", params.getCipherSuites().length);
        return result;
    }

    private static List<Map<String, Object>> describeStore(KeyStore store) throws KeyStoreException {
        if (store == null) {
            return List.of();
        }
        List<Map<String, Object>> certs = new ArrayList<>();
        for (String alias : Collections.list(store.aliases())) {
            Certificate cert = store.getCertificate(alias);
            if (cert instanceof X509Certificate x509) {
                Map<String, Object> c = new LinkedHashMap<>();
                c.put("alias", alias);
                c.put("storeType", store.getType());
                c.put("subject", x509.getSubjectX500Principal().getName());
                c.put("signatureAlgorithm", x509.getSigAlgName());
                c.put("publicKey", describeKey(x509.getPublicKey()));
                c.put("notAfter", x509.getNotAfter().toInstant().toString());
                certs.add(c);
            }
        }
        return certs;
    }

    private static String describeKey(PublicKey key) {
        if (key instanceof RSAPublicKey rsa) {
            return "RSA-" + rsa.getModulus().bitLength();
        }
        if (key instanceof ECPublicKey ec) {
            return "EC-" + ec.getParams().getCurve().getField().getFieldSize();
        }
        return key.getAlgorithm();
    }
}
