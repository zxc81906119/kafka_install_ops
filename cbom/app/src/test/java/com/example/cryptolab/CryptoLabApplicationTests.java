package com.example.cryptolab;

import com.example.cryptolab.crypto.HashingService;
import com.example.cryptolab.crypto.JwtService;
import com.example.cryptolab.crypto.KeyExchangeService;
import com.example.cryptolab.crypto.PasswordHashingService;
import com.example.cryptolab.crypto.SignatureService;
import com.example.cryptolab.crypto.SymmetricCryptoService;
import com.example.cryptolab.crypto.TlsInfoService;
import com.example.cryptolab.crypto.TokenService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Service 層測試：每個密碼學 Service 的每個演算法都實際算一次，檢查「結果是對的」（能解密回原文、簽章驗得過、雜湊長度正確…）。
 * <p>
 * 和 {@code web.CryptoLabControllerTest} 的分工：那邊只檢查 HTTP 層（每個端點回 200、參數錯誤回 400），
 * 這裡檢查密碼學運算本身的正確性。唯一的例外是最後的 secureEndpointAcceptsOnlyRs256：
 * 「受保護的 API 只收 RS256」要經過 Spring Security 才測得到，所以也用 MockMvc。
 * <p>
 * 這些測試保證的是「每個例子（好的與壞的）都真的跑得動」：壞例子也要能算出結果，盤點工具在執行期才錄得到它。
 * 測試不判斷好壞；好壞的標註在各 Service 的註解與 expected-inventory.json。
 * 每個測試都直接走 Service 的 ALGORITHMS／KINDS 清單，所以新增演算法時會自動被測到。
 */
@SpringBootTest
@AutoConfigureMockMvc
class CryptoLabApplicationTests {

    @Autowired PasswordHashingService passwords;
    @Autowired JwtService jwt;
    @Autowired SymmetricCryptoService symmetric;
    @Autowired HashingService hashing;
    @Autowired SignatureService signatures;
    @Autowired KeyExchangeService keyExchange;
    @Autowired TokenService tokens;
    @Autowired TlsInfoService tls;
    @Autowired MockMvc mvc;

    /** 注意：md5-weak / sha1-weak 的 verified 只是「再算一次比對」，一定是 true；這兩個是刻意的弱用法示範 */
    @Test
    void passwordAlgorithmsVerify() throws Exception {
        for (String alg : PasswordHashingService.ALGORITHMS) {
            assertThat(passwords.hashAndVerify(alg, "secret")).as(alg).containsEntry("verified", true);
        }
    }

    /** 有簽章的 JWT 都要驗得過；none-weak（沒有簽章）的 verified 必須是 false */
    @Test
    void jwtAlgorithmsVerify() throws Exception {
        for (String alg : JwtService.ALGORITHMS) {
            Map<String, Object> r = jwt.issueAndVerify(alg, "alice");
            assertThat(r.get("verified")).as(alg).isEqualTo(!"none-weak".equals(alg));
        }
    }

    /** 每個對稱式加密（含 ECB、DES 等壞例子）加密後都要能解回原文 */
    @Test
    void symmetricRoundTrips() throws Exception {
        for (String alg : SymmetricCryptoService.ALGORITHMS) {
            assertThat(symmetric.encryptAndDecrypt(alg, "plaintext")).as(alg).containsEntry("roundTripOk", true);
        }
    }

    /** 每個雜湊 / MAC 的輸出長度（bits）；新增演算法時在這裡加上它的長度 */
    private static final Map<String, Integer> HASH_BITS = Map.ofEntries(
            Map.entry("sha256", 256), Map.entry("sha512", 512), Map.entry("sha3-256", 256),
            Map.entry("sha256-bc", 256), Map.entry("sha3-256-bc", 256),
            Map.entry("hmac-sha256", 256), Map.entry("hmac-sha512", 512), Map.entry("hmac-sha256-bc", 256),
            Map.entry("hmac-sha1-legacy", 160), Map.entry("md5-weak", 128), Map.entry("sha1-weak", 160),
            Map.entry("hmac-md5-weak", 128));

    /** 先確認 HASH_BITS 沒有漏列演算法，再檢查每個雜湊的長度；hex 的字數 = 位元數 ÷ 4（一個十六進位字 4 位元） */
    @Test
    void hashesHaveTheExpectedLength() throws Exception {
        assertThat(HASH_BITS.keySet()).as("HASH_BITS 要列出 HashingService.ALGORITHMS 的每一個演算法")
                .containsExactlyInAnyOrderElementsOf(HashingService.ALGORITHMS);
        for (String alg : HashingService.ALGORITHMS) {
            Map<String, Object> r = hashing.digest(alg, "data");
            assertThat(r.get("bits")).as(alg).isEqualTo(HASH_BITS.get(alg));
            assertThat((String) r.get("hex")).as(alg).hasSize(HASH_BITS.get(alg) / 4);
        }
    }

    /** 每個簽章演算法（含 SHA1withRSA 這個壞例子）簽完都要驗得過 */
    @Test
    void signaturesVerify() throws Exception {
        for (String alg : SignatureService.ALGORITHMS) {
            assertThat(signatures.signAndVerify(alg, "msg")).as(alg).containsEntry("verified", true);
        }
    }

    /**
     * 金鑰交換類的結果有兩種欄位：金鑰交換（ECDH、X25519、DH）回 sharedSecretMatch（雙方算出的秘密相同），
     * 金鑰包裝（RSA-OAEP、PKCS1）回 unwrapOk（解開後和原本的金鑰相同）。
     * getOrDefault(a, b) 的意思是「有 sharedSecretMatch 就看它，沒有就看 unwrapOk」，兩種都必須是 true。
     */
    @Test
    void keyExchangesAgree() throws Exception {
        for (String alg : KeyExchangeService.ALGORITHMS) {
            Map<String, Object> r = keyExchange.run(alg);
            assertThat(r.getOrDefault("sharedSecretMatch", r.get("unwrapOk"))).as(alg).isEqualTo(true);
        }
    }

    /** 每種亂數來源都產生得出 token；TLS 的檢視結果要有 application.yml 設定的三個 SSL bundle */
    @Test
    void tokensAndTlsInfo() throws Exception {
        for (String kind : TokenService.KINDS) {
            assertThat(tokens.generate(kind).get("token")).as(kind).isNotNull();
        }
        assertThat(tls.describe()).containsKeys("server-rsa", "server-ec", "legacy-partner");
    }

    /**
     * /api/secure/me 只收 RS256 簽的 JWT：HS256（對稱式）、none（沒有簽章）、沒帶 token 都要回 401。
     * 這是在保證「app 會簽發弱的 token（示範用），但自己受保護的 API 不會收」。
     */
    @Test
    void secureEndpointAcceptsOnlyRs256() throws Exception {
        String rs256 = (String) jwt.issueAndVerify("RS256", "alice").get("token");
        String hs256 = (String) jwt.issueAndVerify("HS256", "alice").get("token");
        String none = (String) jwt.issueAndVerify("none-weak", "alice").get("token");

        mvc.perform(get("/api/secure/me").header("Authorization", "Bearer " + rs256))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.subject").value("alice"))
                .andExpect(jsonPath("$.algorithm").value("RS256"));
        mvc.perform(get("/api/secure/me").header("Authorization", "Bearer " + hs256))
                .andExpect(status().isUnauthorized());
        mvc.perform(get("/api/secure/me").header("Authorization", "Bearer " + none))
                .andExpect(status().isUnauthorized());
        mvc.perform(get("/api/secure/me")).andExpect(status().isUnauthorized());
    }
}
