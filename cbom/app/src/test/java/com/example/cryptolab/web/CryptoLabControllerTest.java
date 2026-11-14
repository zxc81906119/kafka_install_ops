package com.example.cryptolab.web;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.util.stream.Stream;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * API 層測試：/api/lab/{category}/{algorithm} 的每一個端點都實際呼叫一次（HTTP 層，不啟動真正的 server）。
 * 類別與演算法清單直接取自 {@link LabCategories}，所以新增演算法或類別時這裡不用改，就會自動被測到。
 */
@SpringBootTest
@AutoConfigureMockMvc
class CryptoLabControllerTest {

    @Autowired
    MockMvc mvc;

    /** 用 POST、body 為 {"input": ...} 的類別的每一個值（清單來自 LabCategories，新增類別時這裡不用改） */
    static Stream<Arguments> postEndpoints() {
        return endpoints("POST");
    }

    /** 用 GET 的類別（目前只有 token）的每一個值 */
    static Stream<Arguments> getEndpoints() {
        return endpoints("GET");
    }

    /**
     * 把 LabCategories 展開成一組一組的（類別, 值）：先留下用這個 HTTP 方法的類別，
     * 再把每個類別的每個值各變成一組，例如 ("hash", "sha256")、("hash", "md5-weak")…
     */
    private static Stream<Arguments> endpoints(String method) {
        return LabCategories.ALL.stream()
                .filter(c -> c.method().equals(method))
                .flatMap(c -> c.values().stream().map(v -> Arguments.of(c.name(), v)));
    }

    @ParameterizedTest(name = "POST /api/lab/{0}/{1}")
    @MethodSource("postEndpoints")
    void everyPostEndpointReturnsResult(String category, String algorithm) throws Exception {
        mvc.perform(post("/api/lab/{category}/{algorithm}", category, algorithm)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"input\":\"hello\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.algorithm").value(algorithm));
    }

    @ParameterizedTest(name = "GET /api/lab/{0}/{1}")
    @MethodSource("getEndpoints")
    void everyGetEndpointReturnsResult(String category, String value) throws Exception {
        mvc.perform(get("/api/lab/{category}/{value}", category, value))
                .andExpect(status().isOk());
    }

    /** 不帶 body 也要能用（會用預設的示範字串）：scripts/exercise-api.sh 就是不帶 body 打每個端點 */
    @Test
    void bodyIsOptional() throws Exception {
        mvc.perform(post("/api/lab/hash/sha256"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.hex").isNotEmpty());
    }

    /** 清單以外的演算法名稱回 400 與說明，不是 500 */
    @Test
    void unknownAlgorithmReturns400WithMessage() throws Exception {
        mvc.perform(post("/api/lab/symmetric/rot13"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("Unsupported symmetric algorithm: rot13"));
    }

    /** GET /api/lab 的目錄要列出每個類別，而且 key 的格式不能變（scripts/exercise-api.sh 靠它找出要打哪些端點） */
    @Test
    void catalogListsEveryCategory() throws Exception {
        var request = mvc.perform(get("/api/lab")).andExpect(status().isOk());
        for (LabCategories.Category c : LabCategories.ALL) {
            request.andExpect(jsonPath("$['" + c.catalogKey() + "']").isArray());
        }
        // key 的格式是 scripts/exercise-api.sh 在解析的：「方法（補空白到 4 個字）空白 路徑」
        request.andExpect(jsonPath("$['POST /api/lab/symmetric/{algorithm}']").isArray())
                .andExpect(jsonPath("$['GET  /api/lab/token/{kind}']").isArray());
    }

    @Test
    void tokenEndpointReturnsToken() throws Exception {
        mvc.perform(get("/api/lab/token/secure-random"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.token").isNotEmpty());
    }

    /** 故意放的弱憑證（標準答案 CERT-LEGACY）真的在 truststore 裡：簽章演算法要是 SHA1withRSA */
    @Test
    void tlsInfoDescribesAllBundles() throws Exception {
        mvc.perform(get("/api/lab/tls"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$['legacy-partner'].trustStore[0].signatureAlgorithm").value("SHA1withRSA"));
    }

    /** 沒有登記的路徑一律拒絕；沒帶 token 的請求會先被要求驗證身分，所以是 401（不是 404 或 403） */
    @Test
    void endpointsOutsideTheLabAreDenied() throws Exception {
        mvc.perform(get("/does-not-exist")).andExpect(status().isUnauthorized());
    }
}
