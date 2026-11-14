package com.example.cryptolab.web;

import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * 受保護的 API：只接受用 RS256 簽章的 JWT（驗證規則在 config/SecurityConfig，允許的演算法在 application.yml 的
 * lab.jwt.accepted-algorithms）。token 可以從 POST /api/lab/jwt/RS256 取得。
 */
@RestController
@RequestMapping("/api/secure")
public class SecureController {

    @GetMapping("/me")
    public Map<String, Object> me(@AuthenticationPrincipal Jwt jwt) {
        return Map.of(
                "subject", jwt.getSubject(),
                "algorithm", String.valueOf(jwt.getHeaders().get("alg")),
                "issuer", String.valueOf(jwt.getIssuer()),
                "claims", jwt.getClaims());
    }
}
