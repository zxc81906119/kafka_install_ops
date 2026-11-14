package lab.cbom;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/** 各層的轉換：給一小段原料，看產出的元件對不對。 */
class ConvertersTest {

    private static final Raw.Host KB01 = new Raw.Host("kb01", "broker");

    // ---------- TLS 掃描 ----------

    private static JsonNode scan(String... idAndFinding) {
        ArrayNode array = Cdx.JSON.createArrayNode();
        for (int i = 0; i < idAndFinding.length; i += 2) {
            ObjectNode one = array.addObject();
            one.put("id", idAndFinding[i]);
            one.put("finding", idAndFinding[i + 1]);
        }
        return array;
    }

    @Test
    void tlsEndpointBecomesProtocolsAndKeyExchangeGroups() {
        ObjectNode bom = Cdx.newBom();
        TlsScanLayer.endpoint(bom, "kb01.poc.lab:9092", scan(
            "SSLv3", "not offered", "TLS1", "not offered", "TLS1_1", "not offered",
            "TLS1_2", "offered", "TLS1_3", "offered with final",
            "cipherlist_3DES_IDEA", "not offered", "cipherlist_OBSOLETED", "offered",
            "FS_ciphers", "TLS_AES_256_GCM_SHA384 ECDHE-RSA-AES256-GCM-SHA384 DHE-RSA-AES256-GCM-SHA384",
            "FS_KEMs", "X25519MLKEM768", "FS_ECDHE_curves", "prime256v1 X25519",
            "FS_TLS13_sig_algs", "RSA-PSS-RSAE+SHA256"));

        ObjectNode tls13 = find(bom, "TLS 1.3");
        ObjectNode tls12 = find(bom, "TLS 1.2");
        assertEquals("offered", Cdx.prop(tls13, "pqcKeyExchange"));
        assertEquals("none", Cdx.prop(tls12, "pqcKeyExchange"));
        assertEquals("offered", Cdx.prop(tls12, "obsoleteCiphers"));
        assertEquals("none", Cdx.prop(tls12, "tripleDesCiphers"));

        JsonNode suites13 = tls13.path("cryptoProperties").path("protocolProperties").path("cipherSuites");
        assertEquals(1, suites13.size());
        assertEquals("X25519MLKEM768", suites13.get(0).path("tlsGroups").get(0).asText());

        JsonNode suites12 = tls12.path("cryptoProperties").path("protocolProperties").path("cipherSuites");
        assertEquals(2, suites12.size());
        assertFalse(suites12.get(1).has("tlsGroups"), "DHE 的 cipher suite 不用橢圓曲線群組");

        assertEquals("ML-KEM-hybrid", Cdx.prop(find(bom, "X25519MLKEM768"), "family"));
        assertEquals("ECDH", Cdx.prop(find(bom, "prime256v1"), "family"));
        assertEquals("RSA", Cdx.prop(find(bom, "RSA-PSS-RSAE+SHA256"), "family"));
        assertNull(findOrNull(bom, "TLS 1.1"), "沒開的版本不該出現");
    }

    @Test
    void sameTlsSetupOnTwoEndpointsIsOneComponentWithTwoLocations() {
        ObjectNode bom = Cdx.newBom();
        JsonNode same = scan("TLS1_3", "offered with final", "FS_ciphers", "TLS_AES_256_GCM_SHA384", "FS_KEMs", "X25519MLKEM768");
        TlsScanLayer.endpoint(bom, "kb01.poc.lab:9092", same);
        TlsScanLayer.endpoint(bom, "kb02.poc.lab:9092", same);
        ObjectNode tls13 = find(bom, "TLS 1.3");
        assertEquals(2, tls13.path("evidence").path("occurrences").size());
        assertEquals(1, count(bom, "TLS 1.3"));
    }

    @Test
    void failedScanAddsNothing() {
        ObjectNode bom = Cdx.newBom();
        TlsScanLayer.endpoint(bom, "kb01.poc.lab:1234", scan("scanProblem", "doesn't seem to be a TLS/SSL enabled server"));
        assertEquals(0, bom.path("components").size());
    }

    // ---------- 平台設定 ----------

    @Test
    void platformConfigKeepsSettingsAndFindsSaslAndTokenSignature() {
        ObjectNode bom = Cdx.newBom();
        PlatformConfigLayer.platformConfig(bom, KB01, List.of(
            "# file=/etc/confluent/kafka/server.properties",
            "ssl.enabled.protocols = TLSv1.3,TLSv1.2",
            "ssl.keystore.password =<遮蔽>",
            "listener.name.client.sasl.enabled.mechanisms = SCRAM-SHA-512",
            "listener.name.ldap.sasl.enabled.mechanisms = PLAIN",
            "confluent.metadata.server.token.signature.algorithm = RS256"));

        ObjectNode file = find(bom, "kb01:/etc/confluent/kafka/server.properties");
        assertEquals("TLSv1.3,TLSv1.2", Cdx.prop(file, "setting:ssl.enabled.protocols"));
        assertEquals("<遮蔽>", Cdx.prop(file, "setting:ssl.keystore.password"));
        assertEquals("SCRAM-SHA-512", Cdx.prop(find(bom, "SASL/SCRAM-SHA-512"), "saslMechanism"));
        assertNotNull(find(bom, "SASL/PLAIN"));
        assertEquals("RSA", Cdx.prop(find(bom, "RS256"), "family"));
    }

    @Test
    void scramUsersRecordTheLowestIterationCount() {
        ObjectNode bom = Cdx.newBom();
        PlatformConfigLayer.scramUsers(bom, List.of(
            "SCRAM credential configs for user-principal 'kafka-admin' are SCRAM-SHA-512=iterations=8192",
            "SCRAM credential configs for user-principal 'app-orders-a' are SCRAM-SHA-512=iterations=4096",
            "Quota configs for user-principal 'app-orders-a' are producer_byte_rate=5242880.0"));
        ObjectNode scram = find(bom, "SASL/SCRAM-SHA-512");
        assertEquals("2", Cdx.prop(scram, "scramUsers"));
        assertEquals("4096", Cdx.prop(scram, "scramMinIterations"));
    }

    @Test
    void sshKeysBecomeKeyMaterialWithAlgorithm() {
        ObjectNode bom = Cdx.newBom();
        PlatformConfigLayer.sshKeys(bom, List.of(
            "kc01 3072 SHA256:aaa kc01.poc.lab (RSA)",
            "kc01 256 SHA256:bbb kc01.poc.lab (ED25519)"), true);
        PlatformConfigLayer.sshKeys(bom, List.of("256 SHA256:ccc cpuser-ops-20261109 (ED25519)"), false);

        ObjectNode rsa = find(bom, "ssh 主機金鑰（RSA-3072）");
        assertEquals("3072", Cdx.prop(rsa, "keySize"));
        assertEquals("RSA", Cdx.prop(rsa, "family"));
        assertEquals("kc01:sshd", rsa.path("evidence").path("occurrences").get(0).path("location").asText());
        assertEquals("EdDSA", Cdx.prop(find(bom, "操作機連各主機的 ssh 金鑰（ED25519-256）"), "family"));
    }

    @Test
    void secretProtectionReportsKeyLengthInBits() {
        ObjectNode bom = Cdx.newBom();
        PlatformConfigLayer.secretProtection(bom, KB01, List.of(
            "_metadata.symmetric_key.0.length = 32",
            "_metadata.symmetric_key.0.iterations = 10000"));
        assertEquals("256", Cdx.prop(find(bom, "AES-256-CBC"), "keySize"));
        assertEquals("10000", Cdx.prop(find(bom, "PBKDF2"), "iterations"));
    }

    @Test
    void keyFilesRecordModeButSkipPublicFiles() {
        ObjectNode bom = Cdx.newBom();
        PlatformConfigLayer.keyFiles(bom, KB01, List.of(
            "640 root:confluent 4518 /etc/confluent/ssl/cp-server.p12",
            "640 root:confluent 1766 /etc/confluent/ssl/truststore.p12",
            "640 root:confluent 1704 /etc/confluent/ssl/mds-token-keypair.pem",
            "640 root:confluent 451 /etc/confluent/ssl/mds-token-public.pem"));
        assertEquals(3, bom.path("components").size());
        assertEquals("keystore", Cdx.prop(find(bom, "kb01:/etc/confluent/ssl/cp-server.p12"), "kind"));
        assertEquals("truststore", Cdx.prop(find(bom, "kb01:/etc/confluent/ssl/truststore.p12"), "kind"));
        assertEquals("640", Cdx.prop(find(bom, "kb01:/etc/confluent/ssl/mds-token-keypair.pem"), "mode"));
    }

    // ---------- JDK ----------

    @Test
    void javaSecurityJoinsContinuedLinesAndMergesIdenticalHosts() {
        List<String> lines = List.of(
            "# 註解",
            "security.provider.1=SUN",
            "security.provider.2=SunJCE",
            "jdk.tls.disabledAlgorithms=SSLv3, TLSv1, TLSv1.1, \\",
            "    RC4, 3DES_EDE_CBC",
            "keystore.type=pkcs12");
        Map<String, String> settings = JdkSettingsLayer.parse(lines);
        assertEquals("SSLv3, TLSv1, TLSv1.1, RC4, 3DES_EDE_CBC", settings.get("jdk.tls.disabledAlgorithms"));

        ObjectNode bom = Cdx.newBom();
        List<String> version = List.of("openjdk version \"25.0.5\" 2026-10-20 LTS", "/opt/java/jdk-25.0.5+8");
        JdkSettingsLayer.javaSecurity(bom, KB01, lines, version);
        JdkSettingsLayer.javaSecurity(bom, new Raw.Host("kb02", "broker"), lines, version);
        assertEquals(1, bom.path("components").size(), "內容相同的主機併成一筆");
        JsonNode file = bom.path("components").get(0);
        assertEquals(2, file.path("evidence").path("occurrences").size());
        assertEquals("SUN SunJCE", Cdx.prop(file, "setting:security.providers"));
    }

    // ---------- 函式庫 ----------

    @Test
    void onlyCryptoLibrariesAreKept() {
        ObjectNode sbom = Cdx.newBom();
        ArrayNode components = (ArrayNode) sbom.get("components");
        library(components, "bc-fips", "2.1.2", "pkg:maven/org.bouncycastle/bc-fips@2.1.2");
        library(components, "jackson-databind", "2.22.1", "pkg:maven/com.fasterxml.jackson.core/jackson-databind@2.22.1");
        library(components, "tink", "1.12.0", "pkg:maven/com.google.crypto.tink/tink@1.12.0");

        ObjectNode bom = Cdx.newBom();
        LibraryLayer.group(bom, sbom, List.of("kb01", "kb02"), "abc123", new ConfluentPlatformProfile());
        assertEquals(2, bom.path("components").size());
        ObjectNode bc = find(bom, "bc-fips");
        assertEquals("true", Cdx.prop(bc, "fipsVariant"));
        assertEquals(2, bc.path("evidence").path("occurrences").size());
        assertEquals("kb01:/usr/share/java", bc.path("evidence").path("occurrences").get(0).path("location").asText());
        assertEquals("jar 組 abc123", bc.path("evidence").path("occurrences").get(0).path("additionalContext").asText());
        assertNull(findOrNull(bom, "jackson-databind"));

        // web app：函式庫在可執行 jar 裡，不是 /usr/share/java
        ObjectNode webBom = Cdx.newBom();
        LibraryLayer.group(webBom, sbom, List.of("app"), "abc123", new WebAppProfile());
        JsonNode webOccurrence = find(webBom, "bc-fips").path("evidence").path("occurrences").get(0);
        assertEquals("app:可執行 jar 的 BOOT-INF/lib", webOccurrence.path("location").asText());
        assertEquals("可執行 jar 的 sha256 前 12 碼 abc123", webOccurrence.path("additionalContext").asText());
    }

    private static void library(ArrayNode components, String name, String version, String purl) {
        ObjectNode one = components.addObject();
        one.put("type", "library");
        one.put("name", name);
        one.put("version", version);
        one.put("purl", purl);
    }

    // ---------- 執行期證據 ----------

    @Test
    void jfrCountsAlgorithmsAndFindsTheKafkaCallSite() throws Exception {
        String json = """
            {"recording":{"events":[
              {"type":"jdk.SecurityProviderService","values":{"type":"KEM","algorithm":"X25519MLKEM768","provider":"SunJCE",
                "stackTrace":{"frames":[
                  {"method":{"type":{"name":"sun.security.ssl.KAKeyDerivation"},"name":"t13DeriveKey"}},
                  {"method":{"type":{"name":"org.apache.kafka.common.network.SslTransportLayer"},"name":"handshake"}}]}}},
              {"type":"jdk.SecurityProviderService","values":{"type":"KEM","algorithm":"X25519MLKEM768","provider":"SunJCE"}},
              {"type":"jdk.SecurityProviderService","values":{"type":"KeyFactory","algorithm":"RSA","provider":"SunRsaSign"}},
              {"type":"jdk.TLSHandshake","values":{"peerHost":"172.35.0.10","protocolVersion":"TLSv1.3","cipherSuite":"TLS_AES_256_GCM_SHA384"}},
              {"type":"jdk.TLSHandshake","values":{"peerHost":"172.35.0.51","protocolVersion":"TLSv1.3","cipherSuite":"TLS_AES_256_GCM_SHA384"}}
            ]}}""";
        ObjectNode bom = Cdx.newBom();
        RuntimeLayer.recording(bom, "kb01", Cdx.JSON.readTree(json));

        ObjectNode kem = find(bom, "X25519MLKEM768");
        assertEquals("runtime", Cdx.prop(kem, "source"));
        assertEquals("org.apache.kafka.common.network.SslTransportLayer.handshake", Cdx.prop(kem, "callSite"));
        assertTrue(kem.path("evidence").path("occurrences").get(0).path("additionalContext").asText().contains("2 次"));
        assertNull(findOrNull(bom, "RSA"), "KeyFactory 只是轉格式，不算實際運算");

        ObjectNode handshake = find(bom, "TLS 1.3（實際交握）");
        assertTrue(handshake.path("evidence").path("occurrences").get(0).path("additionalContext").asText().contains("2 次交握，對方 2 個位址"));
    }

    // ---------- 小工具 ----------

    static ObjectNode find(JsonNode bom, String name) {
        ObjectNode found = findOrNull(bom, name);
        assertNotNull(found, "找不到元件 " + name + "；有的是 " + names(bom));
        return found;
    }

    static ObjectNode findOrNull(JsonNode bom, String name) {
        for (JsonNode component : bom.path("components")) {
            if (component.path("name").asText().equals(name)) {
                return (ObjectNode) component;
            }
        }
        return null;
    }

    static int count(JsonNode bom, String name) {
        int count = 0;
        for (JsonNode component : bom.path("components")) {
            if (component.path("name").asText().equals(name)) {
                count++;
            }
        }
        return count;
    }

    private static List<String> names(JsonNode bom) {
        List<String> names = new ArrayList<>();
        bom.path("components").forEach(c -> names.add(c.path("name").asText()));
        return names;
    }
}
