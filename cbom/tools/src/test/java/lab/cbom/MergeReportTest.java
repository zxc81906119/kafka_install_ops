package lab.cbom;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/** 合併（含 cbomkit-theia 的輸出）、官方 schema 驗證、範圍標示，以及報告。 */
class MergeReportTest {

    @TempDir
    Path temp;

    /** 一個小的原料目錄：只選了 broker（部分盤點），theia 的輸出放兩份位置不同的同一批憑證。 */
    private Raw raw(String roles) throws IOException {
        Path dir = temp.resolve("raw-" + roles.replace(' ', '-'));
        Files.createDirectories(dir.resolve("shared"));
        Files.writeString(dir.resolve("collect.env"), String.join("\n",
            "DOMAIN=poc.lab", "ENV=lab", "CP_VERSION=8.3.2", "COLLECTED_AT=2026-11-11T19:12:00+08:00",
            "ALL_ROLES=controller broker rest c3 shared", "ROLES=" + roles,
            "HOSTS=kb01:broker kb02:broker", "JFR_SECONDS=", "TOOLS=cbom-tools 1.0.0, testssl.sh 3.2.5", ""),
            StandardCharsets.UTF_8);

        JsonNode theia;
        try (InputStream in = getClass().getResourceAsStream("/theia-certs.json")) {
            theia = Cdx.JSON.readTree(in);
        }
        // 同一批憑證放兩次，模擬同一張憑證出現在兩台：第二份換成另一組 bom-ref（cbomkit-theia 每個檔給一組亂數）
        String secondCopy = Cdx.JSON.writeValueAsString(theia.get("components"));
        for (JsonNode component : theia.path("components")) {
            secondCopy = secondCopy.replace(component.path("bom-ref").asText(), "second-" + component.path("bom-ref").asText());
        }
        ArrayNode all = Cdx.JSON.createArrayNode();
        addAt(all, theia.get("components"), "kb01/served/9092.pem");
        addAt(all, Cdx.JSON.readTree(secondCopy), "kb02/served/9092.pem");

        ObjectNode merged = Cdx.newBom();
        merged.set("components", all);
        Cdx.write(dir.resolve("shared").resolve("theia.json"), merged);
        return new Raw(dir);
    }

    /** 把元件放進 target，出現位置改成 location（原料目錄裡的相對路徑）。 */
    private static void addAt(ArrayNode target, JsonNode components, String location) {
        for (JsonNode component : components) {
            ObjectNode copy = component.deepCopy();
            for (JsonNode occurrence : copy.path("evidence").path("occurrences")) {
                ((ObjectNode) occurrence).put("location", location);
            }
            target.add(copy);
        }
    }

    private static ObjectNode tlsFragment() {
        ObjectNode bom = Cdx.newBom();
        ArrayNode scan = Cdx.JSON.createArrayNode();
        String[] pairs = {"TLS1_3", "offered with final", "FS_ciphers", "TLS_AES_256_GCM_SHA384", "FS_KEMs", "X25519MLKEM768"};
        for (int i = 0; i < pairs.length; i += 2) {
            scan.addObject().put("id", pairs[i]).put("finding", pairs[i + 1]);
        }
        TlsCommand.endpoint(bom, "kb01.poc.lab:9092", scan);
        return bom;
    }

    @Test
    void sameCertificateOnTwoHostsIsOneComponentAndRefsStayValid() throws Exception {
        Raw raw = raw("broker");
        ObjectNode bom = MergeCommand.run(raw, List.of(tlsFragment()), "1.7");

        long certificates = 0;
        Set<String> refs = new HashSet<>();
        for (JsonNode component : bom.path("components")) {
            assertTrue(refs.add(component.path("bom-ref").asText()), "bom-ref 不可重複");
            if ("certificate".equals(component.path("cryptoProperties").path("assetType").asText())) {
                certificates++;
                assertEquals(2, component.path("evidence").path("occurrences").size(), component.path("name").asText());
                assertEquals("kb01 kb02", Cdx.prop(component, "hosts"));
                assertEquals("broker", Cdx.prop(component, "roles"));
                assertEquals("RSA", Cdx.prop(component, "family"));
            }
        }
        // 測試資料是 15 個憑證檔，其中不重複的憑證 9 張（簽發憑證在每個憑證鏈裡都出現一次）
        assertEquals(9, certificates, "兩台各 15 個憑證檔 → 9 張不重複的憑證");

        // 憑證指到的公鑰與簽章演算法都要是 BOM 裡存在的元件
        for (JsonNode component : bom.path("components")) {
            JsonNode certificate = component.path("cryptoProperties").path("certificateProperties");
            if (!certificate.isMissingNode()) {
                assertTrue(refs.contains(certificate.path("subjectPublicKeyRef").asText()));
                assertTrue(refs.contains(certificate.path("signatureAlgorithmRef").asText()));
            }
        }
        for (JsonNode dependency : bom.path("dependencies")) {
            assertTrue(refs.contains(dependency.path("ref").asText()));
            dependency.path("dependsOn").forEach(target -> assertTrue(refs.contains(target.asText())));
        }
        assertEquals("kb01.poc.lab:9092", ConvertersTest.find(bom, "TLS 1.3").path("evidence").path("occurrences").get(0).path("location").asText());
    }

    @Test
    void scopeIsPartialUnlessEveryRoleWasSelected() throws Exception {
        assertEquals("partial", scopeOf(MergeCommand.run(raw("broker"), List.of(), "1.7")));
        assertEquals("full", scopeOf(MergeCommand.run(raw("controller broker rest c3 shared"), List.of(), "1.7")));
    }

    private static String scopeOf(JsonNode bom) {
        for (JsonNode property : bom.path("metadata").path("properties")) {
            if (property.path("name").asText().equals("cbom:scope")) {
                return property.path("value").asText();
            }
        }
        return "";
    }

    @Test
    void version16DropsTlsGroupsButKeepsThemInProperties() throws Exception {
        ObjectNode bom = MergeCommand.run(raw("broker"), List.of(tlsFragment()), "1.6");
        assertEquals("1.6", bom.path("specVersion").asText());
        ObjectNode tls13 = ConvertersTest.find(bom, "TLS 1.3");
        assertFalse(tls13.path("cryptoProperties").path("protocolProperties").path("cipherSuites").get(0).has("tlsGroups"));
        assertEquals("X25519MLKEM768", Cdx.prop(tls13, "keyExchangeGroups"));
        assertEquals("offered", Cdx.prop(tls13, "pqcKeyExchange"));
    }

    @Test
    void unsupportedSpecVersionIsRejected() throws Exception {
        Raw raw = raw("broker");
        assertThrows(IOException.class, () -> MergeCommand.run(raw, List.of(), "1.5"));
    }

    @Test
    void reportShowsPartialScopeVerdictAndEscapesHtml() throws Exception {
        ObjectNode bom = MergeCommand.run(raw("broker"), List.of(tlsFragment()), "1.7");
        ObjectNode tls13 = ConvertersTest.find(bom, "TLS 1.3");

        ObjectNode report = Cdx.JSON.createObjectNode();
        report.put("compliant", false);
        ArrayNode findings = report.putArray("findings");
        ObjectNode finding = findings.addObject();
        finding.put("bom-ref", tls13.path("bom-ref").asText());
        finding.put("level", "violation");
        finding.put("reason", "測試 <b>原因</b>");
        finding.put("basis", "NIST SP 800-52 Rev.2");

        String html = ReportCommand.render(bom, report);
        assertTrue(html.contains("部分盤點"));
        assertTrue(html.contains("沒有盤到：controller、REST Proxy、Control Center、平台共用"));
        assertTrue(html.contains("不合規：有 1 個違規項目"));
        assertTrue(html.contains("測試 &lt;b&gt;原因&lt;/b&gt;"), "原因裡的 HTML 要跳脫");
        assertFalse(html.contains("<b>原因</b>"));
        assertTrue(html.contains("支援後量子混合金鑰交換的端點</th><td>1 / 1"));
        assertTrue(html.contains("<style>"), "預設是單一檔，樣式寫在 HTML 裡");

        // 給 Jenkins 的版本：不能有寫在 HTML 裡的樣式（Jenkins 預設的安全設定會擋）
        String external = ReportCommand.render(bom, report, true);
        assertFalse(external.contains("<style"));
        assertFalse(external.contains(" style="));
        assertTrue(external.contains("<link rel=\"stylesheet\" href=\"report.css\">"));
    }

    @Test
    void reportAcceptsTheWrapperThatOpaEvalPrints() throws Exception {
        JsonNode wrapped = Cdx.JSON.readTree("{\"result\":[{\"expressions\":[{\"value\":{\"compliant\":true,\"findings\":[]}}]}]}");
        assertTrue(ReportCommand.unwrap(wrapped).path("compliant").asBoolean());
        assertThrows(IOException.class, () -> ReportCommand.unwrap(Cdx.JSON.readTree("{\"other\":1}")));
    }
}
