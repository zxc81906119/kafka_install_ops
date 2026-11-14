package lab.cbom;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/** 盤點對象（Profile）決定用哪幾層（Layer）；檔案與映像兩層怎麼處理 cbomkit-theia 的輸出。 */
class LayersProfileTest {

    private static Raw raw(Path dir, String profileLine) throws Exception {
        Files.writeString(dir.resolve("collect.env"), String.join("\n",
            profileLine, "DOMAIN=poc.lab", "ENV=lab", "CP_VERSION=1.0.0", "COLLECTED_AT=2026-11-12T09:00:00+08:00",
            "ALL_ROLES=webapp", "ROLES=webapp", "HOSTS=app:webapp", "JFR_SECONDS=", "TOOLS=cbom-tools 1.0.0",
            "SUBJECT_NAME=crypto-lab web app", ""), StandardCharsets.UTF_8);
        Files.createDirectories(dir.resolve("shared"));
        return new Raw(dir);
    }

    private static List<ObjectNode> named(JsonNode bom, String name) {
        List<ObjectNode> found = new ArrayList<>();
        for (JsonNode component : bom.path("components")) {
            if (component.path("name").asText().equals(name)) {
                found.add((ObjectNode) component);
            }
        }
        return found;
    }

    @Test
    void profileComesFromCollectEnvAndOldMaterialMeansConfluentPlatform(@TempDir Path dir) throws Exception {
        assertEquals("cp", Profile.of(raw(dir, "# 舊的原料沒有 PROFILE")).id());
        assertEquals("cp", Profile.of(raw(dir, "PROFILE=cp")).id());
        assertEquals("webapp", Profile.of(raw(dir, "PROFILE=webapp")).id());
        Raw unknown = raw(dir, "PROFILE=mainframe");
        assertThrows(IllegalArgumentException.class, () -> Profile.of(unknown));
    }

    @Test
    void eachProfilePicksItsLayersInRegistryOrder() {
        List<String> platform = Layers.of(new ConfluentPlatformProfile().layers()).stream().map(Layer::id).toList();
        assertEquals(List.of("tls", "config", "jdk", "libraries", "runtime", "files"), platform);

        List<String> webApp = Layers.of(new WebAppProfile().layers()).stream().map(Layer::id).toList();
        assertEquals(List.of("tls", "jdk", "libraries", "runtime", "source", "files", "image"), webApp);

        assertThrows(IllegalArgumentException.class, () -> Layers.of(List.of("tls", "沒有這一層")));
    }

    @Test
    void subjectOfTheBomFollowsTheProfile(@TempDir Path dir) throws Exception {
        ObjectNode webApp = MergeCommand.run(raw(dir, "PROFILE=webapp"), List.of(), "1.7");
        assertEquals("application", webApp.path("metadata").path("component").path("type").asText());
        assertEquals("crypto-lab web app（lab）", webApp.path("metadata").path("component").path("name").asText());

        ObjectNode platform = MergeCommand.run(raw(dir, "PROFILE=cp"), List.of(), "1.7");
        assertEquals("platform", platform.path("metadata").path("component").path("type").asText());
        assertEquals("Confluent Platform（lab）", platform.path("metadata").path("component").path("name").asText());
    }

    @Test
    void secretsFoundInTheRepositoryKeepOnlyLocationAndKind(@TempDir Path dir) throws Exception {
        Raw raw = raw(dir, "PROFILE=webapp");
        // 秘密掃描找到的元件沒有 bom-ref；兩處寫死的金鑰在同一個檔，兩把私鑰在不同的檔
        Files.writeString(dir.resolve("shared/theia.json"), """
            {"components":[
              {"type":"cryptographic-asset","name":"generic-api-key",
               "evidence":{"occurrences":[{"location":"src/main/resources/application.yml","line":60}]},
               "cryptoProperties":{"assetType":"related-crypto-material","relatedCryptoMaterialProperties":{"type":"key"}}},
              {"type":"cryptographic-asset","name":"generic-api-key",
               "evidence":{"occurrences":[{"location":"src/main/resources/application.yml","line":71}]},
               "cryptoProperties":{"assetType":"related-crypto-material","relatedCryptoMaterialProperties":{"type":"key"}}},
              {"type":"cryptographic-asset","bom-ref":"a","name":"RSA-2048",
               "evidence":{"occurrences":[{"location":"src/main/resources/crypto/jwt/jwt-rs256-private.pem","line":1}]},
               "cryptoProperties":{"assetType":"related-crypto-material",
                 "relatedCryptoMaterialProperties":{"type":"private-key","size":2048}}},
              {"type":"cryptographic-asset","bom-ref":"b","name":"RSA-2048",
               "evidence":{"occurrences":[{"location":"src/main/resources/crypto/tls/server-rsa2048.key","line":1}]},
               "cryptoProperties":{"assetType":"related-crypto-material",
                 "relatedCryptoMaterialProperties":{"type":"private-key","size":2048}}}
            ]}
            """, StandardCharsets.UTF_8);

        JsonNode bom = new FilesLayer().convert(raw);

        List<ObjectNode> secrets = named(bom, "generic-api-key");
        assertEquals(1, secrets.size(), "同一個檔裡的兩處算一個元件");
        assertEquals(2, secrets.get(0).path("evidence").path("occurrences").size());
        assertEquals("src/main/resources/application.yml:60",
            secrets.get(0).path("evidence").path("occurrences").get(0).path("location").asText());
        assertEquals("secret-scan", Cdx.prop(secrets.get(0), "source"));
        assertEquals("key", Cdx.prop(secrets.get(0), "materialType"));
        assertNull(Cdx.prop(secrets.get(0), "family"), "寫死的秘密不是演算法，不算家族");

        List<ObjectNode> keys = named(bom, "RSA-2048");
        assertEquals(2, keys.size(), "不同檔的私鑰各算一個");
        assertEquals("private-key", Cdx.prop(keys.get(0), "materialType"));
        assertEquals("RSA", Cdx.prop(keys.get(0), "family"));
        assertEquals("2048", Cdx.prop(keys.get(0), "keySize"));
    }

    @Test
    void imageLayerCountsTheTrustStoreAndDropsWhatCameFromTheSourceLayer(@TempDir Path dir) throws Exception {
        Raw raw = raw(dir, "PROFILE=webapp");
        Files.writeString(dir.resolve("shared/theia-image.json"), """
            {"components":[
              {"type":"cryptographic-asset","bom-ref":"ca1","name":"Some Root CA",
               "evidence":{"occurrences":[{"location":"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"}]},
               "cryptoProperties":{"assetType":"certificate","certificateProperties":{"subjectName":"Some Root CA"}}},
              {"type":"cryptographic-asset","bom-ref":"ca2","name":"Other Root CA",
               "evidence":{"occurrences":[{"location":"/etc/ssl/certs/ca-bundle.crt"}]},
               "cryptoProperties":{"assetType":"certificate","certificateProperties":{"subjectName":"Other Root CA"}}},
              {"type":"cryptographic-asset","bom-ref":"app","name":"app-cert",
               "evidence":{"occurrences":[{"location":"/deployments/certs/app.crt"}]},
               "cryptoProperties":{"assetType":"certificate","certificateProperties":{"subjectName":"app-cert"}}},
              {"type":"cryptographic-asset","bom-ref":"src","name":"AES-GCM",
               "evidence":{"occurrences":[{"location":"workspace/src/main/java/Sym.java","line":10}]},
               "cryptoProperties":{"assetType":"algorithm"}},
              {"type":"file","bom-ref":"conf","name":"openssl.cnf",
               "evidence":{"occurrences":[{"location":"/etc/pki/tls/openssl.cnf"}]},
               "properties":[{"name":"theia:openssl:default_md","value":"sha256"}]},
              {"type":"cryptographic-asset","name":"generic-api-key",
               "evidence":{"occurrences":[{"location":"/usr/lib/jvm/jre/conf/security/java.security","line":1034},
                                          {"location":"/etc/alternatives/jre/conf/security/java.security","line":1034}]},
               "cryptoProperties":{"assetType":"related-crypto-material","relatedCryptoMaterialProperties":{"type":"key"}}}
            ]}
            """, StandardCharsets.UTF_8);

        JsonNode bom = new ImageLayer().convert(raw);

        assertTrue(named(bom, "Some Root CA").isEmpty(), "信任庫裡的 CA 不逐張列");
        assertTrue(named(bom, "AES-GCM").isEmpty(), "用 -b 帶進去的原始碼層元件不重複收");
        assertEquals(1, named(bom, "app-cert").size());
        assertEquals("image:/deployments/certs/app.crt",
            named(bom, "app-cert").get(0).path("evidence").path("occurrences").get(0).path("location").asText());

        ObjectNode store = named(bom, "映像內建的 CA 信任庫").get(0);
        assertEquals("2", Cdx.prop(store, "certificates"));
        assertEquals("trust-store", Cdx.prop(store, "kind"));

        ObjectNode openssl = named(bom, "OpenSSL 設定 openssl.cnf").get(0);
        assertEquals("sha256", Cdx.prop(openssl, "setting:openssl.default_md"));

        ObjectNode candidate = named(bom, "generic-api-key").get(0);
        assertNotNull(candidate);
        assertEquals("image-scan", Cdx.prop(candidate, "source"));
        assertEquals(2, candidate.path("evidence").path("occurrences").size(), "同一個檔的幾條路徑併成一個元件");
    }

    @Test
    void convertEachLayerThenMergeGivesTheSameBomAsBuild(@TempDir Path dir) throws Exception {
        Path rawDir = dir.resolve("raw");
        Files.createDirectories(rawDir);
        Raw raw = raw(rawDir, "PROFILE=webapp");
        Files.createDirectories(rawDir.resolve("shared/source"));
        Files.writeString(rawDir.resolve("shared/source/cbom.json"), """
            {"components":[{"type":"cryptographic-asset","bom-ref":"x","name":"AES-128-GCM",
              "evidence":{"occurrences":[{"location":"workspace/src/main/java/Sym.java","line":10}]},
              "cryptoProperties":{"assetType":"algorithm","algorithmProperties":{"primitive":"ae"}}}]}
            """, StandardCharsets.UTF_8);
        Files.writeString(rawDir.resolve("shared/theia.json"), """
            {"components":[{"type":"cryptographic-asset","bom-ref":"k","name":"RSA-2048",
              "evidence":{"occurrences":[{"location":"src/main/resources/crypto/tls/server.key","line":1}]},
              "cryptoProperties":{"assetType":"related-crypto-material",
                "relatedCryptoMaterialProperties":{"type":"private-key","size":2048}}}]}
            """, StandardCharsets.UTF_8);

        Path whole = dir.resolve("whole.json");
        Main.build(rawDir, whole, "1.7");

        List<Path> fragments = new ArrayList<>();
        for (String id : Profile.of(raw).layers()) {
            Path fragment = dir.resolve("fragment-" + id + ".json");
            Main.convert(id, rawDir, fragment);
            fragments.add(fragment);
        }
        Path merged = dir.resolve("merged.json");
        Main.merge(rawDir, merged, fragments, "1.7");

        assertEquals(Files.readString(whole), Files.readString(merged));
        // 原始碼的演算法、秘密掃描的私鑰，加上盤點完整性檢查那一個
        assertEquals(3, Cdx.read(merged).path("components").size());
    }

    @Test
    void effectiveJdkSettingsWinOverTheFile() {
        ObjectNode bom = Cdx.newBom();
        List<String> file = List.of("jdk.tls.disabledAlgorithms=SSLv3, TLSv1", "keystore.type=pkcs12");
        List<String> effective = List.of(
            "Security settings:",
            "    Security properties:",
            "        jdk.tls.disabledAlgorithms=",
            "            SSLv3,",
            "            TLSv1,",
            "            TLSv1.1",
            "        keystore.type=pkcs12",
            "    Security TLS configuration (SunJSSE provider):",
            "        Enabled Protocols:",
            "            TLSv1.3",
            "            TLSv1.2",
            "        Enabled Cipher Suites:",
            "            TLS_AES_256_GCM_SHA384");
        JdkSettingsLayer.javaSecurity(bom, new Raw.Host("app", "webapp"), file,
            List.of("openjdk version \"21.0.13\"", "/usr/lib/jvm/java-21"), effective,
            List.of("java.security.properties=/etc/app/override.security"));

        ObjectNode jdk = (ObjectNode) bom.path("components").get(0);
        assertEquals("SSLv3, TLSv1, TLSv1.1", Cdx.prop(jdk, "setting:jdk.tls.disabledAlgorithms"));
        assertEquals("effective", Cdx.prop(jdk, "settingsFrom"));
        assertEquals("jdk.tls.disabledAlgorithms", Cdx.prop(jdk, "differsFromFile"));
        assertEquals("TLSv1.3,TLSv1.2", Cdx.prop(jdk, "setting:tls.enabledProtocols"));
        assertEquals("/etc/app/override.security", Cdx.prop(jdk, "securityPropertiesOverride"));
    }

    @Test
    void cryptoOnlyDropsComponentsWithoutCryptoProperties(@TempDir Path dir) throws Exception {
        Path input = dir.resolve("cbom.json");
        Path output = dir.resolve("crypto-only.json");
        Files.writeString(input, """
            {"bomFormat":"CycloneDX","specVersion":"1.7","components":[
              {"type":"cryptographic-asset","bom-ref":"a","name":"AES","cryptoProperties":{"assetType":"algorithm"}},
              {"type":"library","bom-ref":"l","name":"bcprov-jdk18on"},
              {"type":"file","bom-ref":"f","name":"java.security"}
            ]}
            """, StandardCharsets.UTF_8);

        Main.cryptoOnly(input, output);

        JsonNode result = Cdx.read(output);
        assertEquals(1, result.path("components").size());
        assertEquals("AES", result.path("components").get(0).path("name").asText());
        // CBOMkit 的網頁要有 serialNumber 才顯示
        assertTrue(result.path("serialNumber").asText().matches("urn:uuid:[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}"));
    }

    @Test
    void serialNumberFollowsTheContent() throws Exception {
        ObjectNode one = (ObjectNode) Cdx.JSON.readTree("{\"bomFormat\":\"CycloneDX\",\"components\":[{\"name\":\"AES\"}]}");
        ObjectNode same = one.deepCopy();
        ObjectNode other = (ObjectNode) Cdx.JSON.readTree("{\"bomFormat\":\"CycloneDX\",\"components\":[{\"name\":\"RSA\"}]}");
        BomSteps.serialNumber(one);
        BomSteps.serialNumber(same);
        BomSteps.serialNumber(same);   // 算第二次不會把舊的編號算進去
        BomSteps.serialNumber(other);

        assertEquals(one.path("serialNumber").asText(), same.path("serialNumber").asText());
        assertNotEquals(one.path("serialNumber").asText(), other.path("serialNumber").asText());
    }
}
