package lab.cbom;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import com.fasterxml.jackson.databind.node.ObjectNode;

/** 盤點完整性檢查：原料「該有而沒有的」要一項一項列出來；都齊了就沒有缺口。 */
class CollectionCheckTest {

    /** 寫一個檔（上層目錄不存在就先建）。 */
    private static void write(Path file, String... lines) throws IOException {
        Files.createDirectories(file.getParent());
        Files.writeString(file, String.join("\n", lines) + "\n", StandardCharsets.UTF_8);
    }

    /**
     * Confluent Platform 的原料：兩台 broker，kb02 整台沒收到；kb01 少了一個埠的掃描、一個埠沒掃成、
     * 設定檔引用的 truststore 不在檔案清單、jar 組沒有 SBOM、沒有憑證掃描的結果。
     */
    private static Raw platformRaw(Path dir) throws IOException {
        write(dir.resolve("collect.env"),
            "PROFILE=cp", "DOMAIN=poc.lab", "ENV=lab", "ALL_ROLES=broker", "ROLES=broker",
            "HOSTS=kb01:broker kb02:broker", "JFR_SECONDS=60");
        Path kb01 = dir.resolve("kb01");
        write(kb01.resolve("platform-config.properties"),
            "# file=/etc/kafka/server.properties",
            "listeners=INTERNAL://kb01.poc.lab:9092,CLIENT://kb01.poc.lab:9094,PLAIN://kb01.poc.lab:9095",
            "advertised.listeners=INTERNAL://kb01.poc.lab:9999",
            "listener.security.protocol.map=INTERNAL:SSL,CLIENT:SASL_SSL,PLAIN:PLAINTEXT",
            "confluent.metadata.server.listeners=https://0.0.0.0:8090",
            "ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12",
            "ssl.keystore.password=<遮蔽>",
            "ssl.truststore.location=/etc/confluent/ssl/truststore.p12");
        write(kb01.resolve("ssl-files.list"), "640 root:confluent 4321 /etc/confluent/ssl/kafka-internal.p12");
        write(kb01.resolve("java.security"), "keystore.type=pkcs12");
        write(kb01.resolve("os-crypto.txt"), "DEFAULT", "Rocky Linux release 9.6 (Blue Onyx)", "OpenSSL 3.2.2 4 Jun 2024");
        write(kb01.resolve("tls/9092.json"), "[{\"id\":\"TLS1_3\",\"finding\":\"offered with final\"}]");
        write(kb01.resolve("tls/9094.json"), "[{\"id\":\"scanProblem\",\"finding\":\"connection refused\"}]");
        write(kb01.resolve("jfr/service.json"), "{\"recording\":{\"events\":[]}}");
        write(dir.resolve("shared/jars/groups.txt"), "abc123 kb01");
        return new Raw(dir);
    }

    @Test
    void everyMissingPieceOfThePlatformIsListed(@TempDir Path dir) throws IOException {
        Raw raw = platformRaw(dir);

        List<String> gaps = CollectionCheck.confluentPlatform(raw, Cdx.newBom());

        assertEquals(List.of(
            "kb01:8090（設定檔的 listener https）沒有 TLS 掃描結果",
            "kb01:9094（設定檔的 listener CLIENT）的 TLS 掃描沒掃成：connection refused",
            "kb01：設定檔引用的 /etc/confluent/ssl/truststore.p12 不在檔案清單裡（ssl-files.list）",
            "kb01：設定檔有引用 keystore，但沒有任何一張憑證元件出現在這台（沒有取到它出示的憑證）",
            "kb02：沒有這台的原料目錄",
            "jar 組 abc123（kb01）沒有函式庫清單（shared/jars/sbom-abc123.json）",
            "沒有憑證掃描的結果（shared/theia.json）"), gaps);
    }

    @Test
    void aCertificateSeenOnTheHostAnswersTheKeystoreCheck(@TempDir Path dir) throws IOException {
        Raw raw = platformRaw(dir);
        ObjectNode bom = Cdx.newBom();
        ObjectNode certificate = Cdx.asset("certificate", "kafka-internal", "cert|test");
        Cdx.occurrence(certificate, "kb01.poc.lab:9092", "這個埠實際出示的憑證鏈");
        Cdx.add(bom, certificate);

        List<String> gaps = CollectionCheck.confluentPlatform(raw, bom);

        for (String gap : gaps) {
            assertFalse(gap.contains("沒有任何一張憑證元件"), gap);
        }
    }

    @Test
    void onlyListenersWithTlsAreExpectedToBeScanned() {
        Map<String, String> settings = new LinkedHashMap<>();
        settings.put("listeners", "INTERNAL://kb01.poc.lab:9092,PLAIN://kb01.poc.lab:9095,SASL_SSL://kb01.poc.lab:9096");
        settings.put("advertised.listeners", "INTERNAL://kb01.poc.lab:9999");
        settings.put("listener.security.protocol.map", "INTERNAL:SSL,PLAIN:PLAINTEXT");
        settings.put("confluent.controlcenter.rest.listeners", "https://0.0.0.0:9021,http://0.0.0.0:9022");

        Map<String, String> ports = CollectionCheck.tlsListenerPorts(settings);

        // 9096：對照表裡沒有這個名稱時，名稱本身就是協定（SASL_SSL）
        assertEquals(Map.of("9092", "INTERNAL", "9096", "SASL_SSL", "9021", "https"), ports);
    }

    @Test
    void aCompleteWebAppHasNoGaps(@TempDir Path dir) throws IOException {
        write(dir.resolve("collect.env"),
            "PROFILE=webapp", "DOMAIN=poc.lab", "ENV=lab", "ALL_ROLES=webapp", "ROLES=webapp", "HOSTS=app:webapp", "JFR_SECONDS=95");
        write(dir.resolve("shared/source/cbom.json"), "{\"components\":[]}");
        write(dir.resolve("shared/theia.json"), "{\"components\":[]}");
        write(dir.resolve("shared/theia-image.json"), "{\"components\":[]}");
        write(dir.resolve("shared/jars/groups.txt"), "abc123 app");
        write(dir.resolve("shared/jars/sbom-abc123.json"), "{\"components\":[]}");
        write(dir.resolve("app/java-security-effective.txt"), "Security settings:");
        write(dir.resolve("app/os-crypto.txt"), "DEFAULT", "Red Hat Enterprise Linux release 9.6", "OpenSSL 3.2.2 4 Jun 2024");
        write(dir.resolve("app/tls/8443.json"), "[{\"id\":\"TLS1_3\",\"finding\":\"offered with final\"}]");
        write(dir.resolve("app/jfr/service.json"), "{\"recording\":{\"events\":[]}}");
        Raw raw = new Raw(dir);

        assertEquals(List.of(), CollectionCheck.webApp(raw));

        // 少了映像掃描與錄製結果：各一個缺口
        Files.delete(dir.resolve("shared/theia-image.json"));
        Files.delete(dir.resolve("app/jfr/service.json"));
        assertEquals(List.of(
            "沒有映像掃描的結果（shared/theia-image.json）",
            "app：這次有做執行期，但沒有錄製結果（jfr/*.json）"), CollectionCheck.webApp(raw));
    }

    @Test
    void theCheckBecomesOneComponentWithOnePropertyPerGap() {
        ObjectNode complete = CollectionCheck.component(List.of());
        assertEquals("data", complete.path("type").asText());
        assertEquals("collection-check", Cdx.prop(complete, "kind"));
        assertEquals("0", Cdx.prop(complete, "gapCount"));
        assertNull(Cdx.prop(complete, "gap"));

        ObjectNode withGaps = CollectionCheck.component(List.of("kb02：沒有這台的原料目錄", "沒有憑證掃描的結果（shared/theia.json）"));
        assertEquals("2", Cdx.prop(withGaps, "gapCount"));
        assertEquals("kb02：沒有這台的原料目錄", Cdx.prop(withGaps, "gap"));
        assertEquals(complete.path("bom-ref").asText(), withGaps.path("bom-ref").asText(), "bom-ref 固定：每份 CBOM 只有一個");
    }
}
