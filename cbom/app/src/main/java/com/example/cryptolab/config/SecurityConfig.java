package com.example.cryptolab.config;

import com.example.cryptolab.crypto.KeyMaterialService;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.web.SecurityFilterChain;

/**
 * 哪些路徑要驗證身分：
 * - /api/lab/**   ：lab 示範端點，開放存取
 * - /api/secure/**：OAuth2 Resource Server，只接受 RS256 簽章、issuer 正確的 JWT
 * <p>
 * 這個檔牽涉到的例子：驗證 JWT 用 RS256（RSA-2048 公鑰），屬於 [可接受·量子脆弱]；
 * 標準答案：JWT-RS256　pipeline 判定：量子脆弱。四種標記的定義見 README.md。
 */
@Configuration
public class SecurityConfig {

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        // 1. csrf：/api/** 不用 cookie 登入（用 Bearer token），所以關掉 CSRF 檢查，否則 POST 會被擋
        // 2. sessionManagement：不建立 session，每個請求都自己帶 token
        // 3. authorizeHttpRequests：lab 端點與三個 actuator 端點開放；/api/secure/** 要有效的 JWT；其他路徑一律拒絕
        //    （沒帶 token 的請求會先被要求驗證身分，所以測試看到的是 401，不是 403）
        // 4. oauth2ResourceServer：用下面的 jwtDecoder 驗證 Authorization: Bearer 帶來的 JWT
        http
                .csrf(csrf -> csrf.ignoringRequestMatchers("/api/**"))
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers("/api/lab/**", "/actuator/health", "/actuator/info", "/actuator/sbom/**").permitAll()
                        .requestMatchers("/api/secure/**").authenticated()
                        .anyRequest().denyAll())
                .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()));
        return http.build();
    }

    @Bean
    JwtDecoder jwtDecoder(KeyMaterialService keys, LabProperties props) {
        // 只用 RSA 公鑰驗證、只接受設定檔 lab.jwt.accepted-algorithms 寫的那一個演算法（RS256），
        // 所以 HS256 與 alg=none 的 token 都會被拒絕（測試：CryptoLabApplicationTests.secureEndpointAcceptsOnlyRs256）。
        // 驗證器另外檢查 token 的有效期與簽發者（iss 必須等於 lab.jwt.issuer）
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withPublicKey(keys.jwtRsaPublicKey())
                .signatureAlgorithm(SignatureAlgorithm.from(props.jwt().acceptedAlgorithms()))
                .build();
        decoder.setJwtValidator(new DelegatingOAuth2TokenValidator<>(
                JwtValidators.createDefaultWithIssuer(props.jwt().issuer())));
        return decoder;
    }
}
