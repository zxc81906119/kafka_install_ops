package com.example.cryptolab.web;

import com.example.cryptolab.crypto.HashingService;
import com.example.cryptolab.crypto.JwtService;
import com.example.cryptolab.crypto.KeyExchangeService;
import com.example.cryptolab.crypto.PasswordHashingService;
import com.example.cryptolab.crypto.SignatureService;
import com.example.cryptolab.crypto.SymmetricCryptoService;
import com.example.cryptolab.crypto.TlsInfoService;
import com.example.cryptolab.crypto.TokenService;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Lab 示範端點，路徑規則是 {@code /api/lab/{category}/{algorithm}}：
 * <ul>
 *   <li>{@code category} 對應一個 Service（password → PasswordHashingService、symmetric → SymmetricCryptoService …）</li>
 *   <li>{@code algorithm} 必須是該 Service {@code ALGORITHMS} 清單裡的值，否則回 400</li>
 *   <li>POST 的 body 是 {@code {"input": "..."}}，可省略（會用預設的示範字串）</li>
 *   <li>{@code GET /api/lab} 會列出所有類別與可用的演算法</li>
 * </ul>
 * 在既有類別新增演算法不用改這個檔；新增類別時，除了這裡的 endpoint 方法，也要登記到 {@link LabCategories}
 * （步驟見 README.md 的「怎麼加一個新例子」）。
 */
@RestController
@RequestMapping("/api/lab")
public class CryptoLabController {

    public record LabInput(String input) {
        String valueOr(String fallback) {
            return input == null || input.isBlank() ? fallback : input;
        }
    }

    private final PasswordHashingService passwords;
    private final JwtService jwt;
    private final SymmetricCryptoService symmetric;
    private final HashingService hashing;
    private final SignatureService signatures;
    private final KeyExchangeService keyExchange;
    private final TokenService tokens;
    private final TlsInfoService tls;

    public CryptoLabController(PasswordHashingService passwords, JwtService jwt, SymmetricCryptoService symmetric,
                               HashingService hashing, SignatureService signatures, KeyExchangeService keyExchange,
                               TokenService tokens, TlsInfoService tls) {
        this.passwords = passwords;
        this.jwt = jwt;
        this.symmetric = symmetric;
        this.hashing = hashing;
        this.signatures = signatures;
        this.keyExchange = keyExchange;
        this.tokens = tokens;
        this.tls = tls;
    }

    /**
     * {@code GET /api/lab}：所有類別與可用的值。類別清單來自 {@link LabCategories#ALL}。
     * key 的格式（「方法 空白 路徑」）是 scripts/exercise-api.sh 在解析的，不要改。
     */
    @GetMapping
    public Map<String, Object> catalog() {
        Map<String, Object> catalog = new LinkedHashMap<>();
        LabCategories.ALL.forEach(c -> catalog.put(c.catalogKey(), c.values()));
        catalog.put("GET  /api/lab/tls", "SSL bundle / certificate / protocol info");
        catalog.put("GET  /api/secure/me", "requires Authorization: Bearer <RS256 JWT from /api/lab/jwt/RS256>");
        return catalog;
    }

    // 以下每個方法對應一個類別：把路徑上的演算法名稱交給對應的 Service。
    // input(body, "…") 的第二個參數是沒帶 body 時用的示範字串（不是真的密碼或卡號）。
    @PostMapping("/password/{algorithm}")
    public Map<String, Object> password(@PathVariable String algorithm, @RequestBody(required = false) LabInput body)
            throws Exception {
        return passwords.hashAndVerify(algorithm, input(body, "P@ssw0rd-lab"));
    }

    @PostMapping("/jwt/{algorithm}")
    public Map<String, Object> jwt(@PathVariable String algorithm, @RequestBody(required = false) LabInput body)
            throws Exception {
        return jwt.issueAndVerify(algorithm, input(body, "lab-user"));
    }

    @PostMapping("/symmetric/{algorithm}")
    public Map<String, Object> symmetric(@PathVariable String algorithm, @RequestBody(required = false) LabInput body)
            throws Exception {
        return symmetric.encryptAndDecrypt(algorithm, input(body, "card=4111-1111-1111-1111"));
    }

    @PostMapping("/hash/{algorithm}")
    public Map<String, Object> hash(@PathVariable String algorithm, @RequestBody(required = false) LabInput body)
            throws Exception {
        return hashing.digest(algorithm, input(body, "hello cbom"));
    }

    @PostMapping("/signature/{algorithm}")
    public Map<String, Object> signature(@PathVariable String algorithm, @RequestBody(required = false) LabInput body)
            throws Exception {
        return signatures.signAndVerify(algorithm, input(body, "invoice#2026-001"));
    }

    @PostMapping("/key-exchange/{algorithm}")
    public Map<String, Object> keyExchange(@PathVariable String algorithm) throws Exception {
        return keyExchange.run(algorithm);
    }

    @GetMapping("/token/{kind}")
    public Map<String, Object> token(@PathVariable String kind) throws Exception {
        return tokens.generate(kind);
    }

    @GetMapping("/tls")
    public Map<String, Object> tls() throws Exception {
        return tls.describe();
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, String>> badRequest(IllegalArgumentException e) {
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of("error", e.getMessage()));
    }

    private static String input(LabInput body, String fallback) {
        return body == null ? fallback : body.valueOr(fallback);
    }
}
