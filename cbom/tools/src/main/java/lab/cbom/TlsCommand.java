package lab.cbom;

import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 第 ④ 層：testssl.sh 掃每個埠的結果 → CBOM。
 *
 * 輸入：raw/&lt;主機&gt;/tls/&lt;埠&gt;.json（testssl.sh --jsonfile 的輸出，一個陣列，每筆有 id、severity、finding）。
 * 產出：
 *   protocol 元件      每種「TLS 版本＋cipher suite 清單＋金鑰交換群組」一筆，出現位置是 主機:埠
 *   algorithm 元件     伺服器願意用的金鑰交換群組（X25519MLKEM768、X25519、secp256r1 …）與簽章演算法
 *
 * 記的是「伺服器支援什麼」；每條連線實際協商到哪一個，要看用戶端（那是執行期證據 JFR 的範圍）。
 * 伺服器出示的憑證不在這裡處理：收集腳本另外存成 PEM，由 cbomkit-theia 掃。
 */
final class TlsCommand {

    private TlsCommand() {
    }

    static ObjectNode run(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        for (Raw.Host host : raw.hosts()) {
            Path tlsDir = raw.hostDir(host.name()).resolve("tls");
            if (!Files.isDirectory(tlsDir)) {
                continue;
            }
            List<Path> files = new ArrayList<>();
            try (DirectoryStream<Path> stream = Files.newDirectoryStream(tlsDir, "*.json")) {
                stream.forEach(files::add);
            }
            files.sort(null);
            for (Path file : files) {
                String port = file.getFileName().toString().replace(".json", "");
                endpoint(bom, raw.fqdn(host.name()) + ":" + port, Cdx.read(file));
            }
        }
        return bom;
    }

    /** 一個埠的掃描結果。 */
    static void endpoint(ObjectNode bom, String location, JsonNode scan) {
        Map<String, String> findings = new LinkedHashMap<>();
        for (JsonNode one : scan) {
            findings.put(one.path("id").asText(), one.path("finding").asText());
        }
        if (findings.containsKey("scanProblem")) {
            return;
        }

        List<String> kems = words(findings.get("FS_KEMs"));
        List<String> curves = words(findings.get("FS_ECDHE_curves"));
        List<String> suites = words(findings.get("FS_ciphers"));

        List<String> suites13 = new ArrayList<>();
        List<String> suites12 = new ArrayList<>();
        for (String suite : suites) {
            // TLS 1.3 的 cipher suite 是 TLS_ 開頭的標準名稱；其他是 OpenSSL 對 TLS 1.2 以下的寫法
            if (suite.startsWith("TLS_")) {
                suites13.add(suite);
            } else {
                suites12.add(suite);
            }
        }

        List<String> groups13 = new ArrayList<>(kems);
        groups13.addAll(curves);

        version(bom, location, findings, "TLS1_3", "1.3", suites13, groups13);
        version(bom, location, findings, "TLS1_2", "1.2", suites12, curves);
        version(bom, location, findings, "TLS1_1", "1.1", List.of(), List.of());
        version(bom, location, findings, "TLS1", "1.0", List.of(), List.of());
        version(bom, location, findings, "SSLv3", "SSLv3", List.of(), List.of());
        version(bom, location, findings, "SSLv2", "SSLv2", List.of(), List.of());

        for (String group : groups13) {
            ObjectNode algorithm = Cdx.asset("algorithm", group, "kex|" + group);
            Algo.apply(algorithm, group);
            Cdx.prop(algorithm, "source", "tls-scan");
            Cdx.prop(algorithm, "use", "TLS 金鑰交換");
            Cdx.occurrence(algorithm, location, "伺服器支援的金鑰交換群組");
            Cdx.add(bom, algorithm);
        }

        List<String> signatures = new ArrayList<>(words(findings.get("FS_TLS13_sig_algs")));
        for (String name : words(findings.get("FS_TLS12_sig_algs"))) {
            if (!signatures.contains(name)) {
                signatures.add(name);
            }
        }
        for (String signature : signatures) {
            ObjectNode algorithm = Cdx.asset("algorithm", signature, "tls-sig|" + signature);
            Algo.apply(algorithm, signature);
            Cdx.prop(algorithm, "source", "tls-scan");
            Cdx.prop(algorithm, "use", "TLS 交握簽章");
            Cdx.occurrence(algorithm, location, "伺服器支援的簽章演算法");
            Cdx.add(bom, algorithm);
        }
    }

    private static void version(ObjectNode bom, String location, Map<String, String> findings, String id,
        String version, List<String> suites, List<String> groups) {
        String finding = findings.getOrDefault(id, "");
        if (!finding.startsWith("offered")) {
            return;
        }
        String name = version.startsWith("SSL") ? version : "TLS " + version;
        String key = "tls|" + version + "|" + String.join(",", suites) + "|" + String.join(",", groups)
            + "|" + findings.getOrDefault("cipherlist_OBSOLETED", "") + "|" + findings.getOrDefault("cipherlist_3DES_IDEA", "");
        ObjectNode protocol = Cdx.asset("protocol", name, key);
        ObjectNode properties = Cdx.crypto(protocol, "protocolProperties");
        properties.put("type", version.startsWith("SSL") ? "other" : "tls");
        properties.put("version", version);
        ArrayNode cipherSuites = properties.putArray("cipherSuites");
        for (String suite : suites) {
            ObjectNode cipherSuite = cipherSuites.addObject();
            cipherSuite.put("name", suite);
            if (!groups.isEmpty() && !suite.startsWith("DHE-")) {
                ArrayNode tlsGroups = cipherSuite.putArray("tlsGroups");
                groups.forEach(tlsGroups::add);
            }
        }
        Cdx.prop(protocol, "source", "tls-scan");
        Cdx.prop(protocol, "tlsVersion", version);
        Cdx.prop(protocol, "keyExchangeGroups", String.join(" ", groups));
        Cdx.prop(protocol, "pqcKeyExchange", groups.stream().anyMatch(g -> g.toUpperCase().contains("MLKEM")) ? "offered" : "none");
        if ("1.2".equals(version)) {
            // testssl 的分類：OBSOLETED = CBC 類、3DES_IDEA = 3DES／IDEA；記下來給規則用
            Cdx.prop(protocol, "obsoleteCiphers", offered(findings.get("cipherlist_OBSOLETED")));
            Cdx.prop(protocol, "tripleDesCiphers", offered(findings.get("cipherlist_3DES_IDEA")));
            Cdx.prop(protocol, "nonForwardSecrecyCiphers", offered(findings.get("cipherlist_STRONG_NOFS")));
        }
        Cdx.occurrence(protocol, location, "伺服器支援");
        Cdx.add(bom, protocol);
    }

    private static String offered(String finding) {
        if (finding == null) {
            return "unknown";
        }
        return finding.startsWith("offered") ? "offered" : "none";
    }

    private static List<String> words(String finding) {
        List<String> words = new ArrayList<>();
        if (finding == null) {
            return words;
        }
        for (String word : finding.trim().split("\\s+")) {
            if (!word.isEmpty() && !word.equals("--")) {
                words.add(word);
            }
        }
        return words;
    }
}
