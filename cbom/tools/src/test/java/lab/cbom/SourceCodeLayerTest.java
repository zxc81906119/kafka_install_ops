package lab.cbom;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/** 原始碼層：原始碼掃描工具（cbomkit-action）的 CBOM 轉成這邊的元件。 */
class SourceCodeLayerTest {

    private static final String COLLECT_ENV = String.join("\n",
        "DOMAIN=localhost", "ENV=weblab", "CP_VERSION=", "COLLECTED_AT=2026-11-11T23:00:00+08:00",
        "ALL_ROLES=rest", "ROLES=rest", "HOSTS=app:rest", "JFR_SECONDS=", "TOOLS=cbomkit-action 2.3.0", "");

    private static final String SCANNER_CBOM = """
        {"bomFormat":"CycloneDX","specVersion":"1.6","components":[
          {"type":"cryptographic-asset","bom-ref":"11111111-1111-1111-1111-111111111111","name":"FFDH",
           "evidence":{"occurrences":[{"location":"workspace/src/main/java/Kex.java","line":68,"additionalContext":"KeyPairGenerator#getInstance"}]},
           "cryptoProperties":{"assetType":"algorithm","algorithmProperties":{"primitive":"pke","parameterSetIdentifier":"1024"}}},
          {"type":"cryptographic-asset","bom-ref":"22222222-2222-2222-2222-222222222222","name":"AES-128-CBC-PKCS5",
           "evidence":{"occurrences":[{"location":"workspace/src/main/java/Sym.java","line":10},{"location":"workspace/src/main/java/Sym.java","line":20}]},
           "cryptoProperties":{"assetType":"algorithm","algorithmProperties":{"primitive":"block-cipher","mode":"cbc"},"oid":"2.16.840.1.101.3.4.1"}},
          {"type":"cryptographic-asset","bom-ref":"33333333-3333-3333-3333-333333333333",
           "name":"key@33333333-3333-3333-3333-333333333333",
           "evidence":{"occurrences":[{"location":"workspace/src/main/java/Sym.java","line":10}]},
           "cryptoProperties":{"assetType":"related-crypto-material","relatedCryptoMaterialProperties":{"type":"secret-key","size":128}}},
          {"type":"cryptographic-asset","bom-ref":"44444444-4444-4444-4444-444444444444",
           "name":"key@44444444-4444-4444-4444-444444444444",
           "evidence":{"occurrences":[{"location":"workspace/src/main/java/Sym.java","line":20}]},
           "cryptoProperties":{"assetType":"related-crypto-material","relatedCryptoMaterialProperties":{"type":"secret-key","size":128}}}
        ]}
        """;

    private static ObjectNode find(JsonNode bom, String name) {
        for (JsonNode component : bom.path("components")) {
            if (component.path("name").asText().equals(name)) {
                return (ObjectNode) component;
            }
        }
        return null;
    }

    @Test
    void withoutScannerOutputThereIsNoSourceLayer(@TempDir Path dir) throws Exception {
        Files.writeString(dir.resolve("collect.env"), COLLECT_ENV, StandardCharsets.UTF_8);
        assertEquals(0, SourceCodeLayer.run(new Raw(dir)).path("components").size());
    }

    @Test
    void scannerComponentsGetStableRefsLocationsAndFamilies(@TempDir Path dir) throws Exception {
        Files.writeString(dir.resolve("collect.env"), COLLECT_ENV, StandardCharsets.UTF_8);
        Files.createDirectories(dir.resolve("shared/source"));
        Files.writeString(dir.resolve("shared/source/cbom.json"), SCANNER_CBOM, StandardCharsets.UTF_8);

        JsonNode bom = SourceCodeLayer.run(new Raw(dir));
        // 兩把名稱帶亂數的金鑰是同一種、同樣長度：併成一筆，位置兩個
        assertEquals(3, bom.path("components").size());

        ObjectNode dh = find(bom, "FFDH");
        assertNotNull(dh);
        assertEquals("DH", Cdx.prop(dh, "family"));
        assertEquals("1024", Cdx.prop(dh, "keySize"));
        assertEquals("source-code", Cdx.prop(dh, "source"));
        assertEquals("src:src/main/java/Kex.java:68", dh.path("evidence").path("occurrences").get(0).path("location").asText());
        assertTrue(dh.path("bom-ref").asText().startsWith("algorithm:"));

        ObjectNode aes = find(bom, "AES-128-CBC-PKCS5");
        assertNotNull(aes);
        assertEquals("AES", Cdx.prop(aes, "family"));
        assertEquals("128", Cdx.prop(aes, "keySize"));
        assertEquals("cbc", aes.path("cryptoProperties").path("algorithmProperties").path("mode").asText());
        assertEquals(2, aes.path("evidence").path("occurrences").size());

        ObjectNode key = find(bom, "key");
        assertNotNull(key);
        assertEquals(2, key.path("evidence").path("occurrences").size());
        assertEquals(128, key.path("cryptoProperties").path("relatedCryptoMaterialProperties").path("size").asInt());
    }
}
