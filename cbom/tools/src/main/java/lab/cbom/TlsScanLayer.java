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
 * 第 ④ 層（手冊第 33 章那張表的編號）：testssl.sh 掃每個埠的結果 → CBOM。
 *
 * 輸入：raw/&lt;主機&gt;/tls/&lt;埠&gt;.json（testssl.sh --jsonfile 的輸出，一個陣列，每筆有 id、severity、finding）。
 * 產出（屬性 cbom:source 都是 tls-scan）：
 *   protocol 元件      每種「TLS 版本＋cipher suite 清單＋金鑰交換群組」一筆，出現位置是 主機:埠
 *   algorithm 元件     伺服器願意用的金鑰交換群組（X25519MLKEM768、X25519、secp256r1 …）與簽章演算法
 * 誰呼叫：Main（經 Layers）。
 *
 * 記的是「伺服器支援什麼」；每條連線實際協商到哪一個，要看用戶端（那是執行期證據 JFR 的範圍）。
 * 伺服器出示的憑證不在這裡處理：收集腳本另外存成 PEM，由 cbomkit-theia 掃。
 *
 * 這裡用到的 testssl 項目（id → finding 的樣子 → 我們拿來做什麼）：
 * <pre>
 *   scanProblem            有這一筆 = 這個埠沒掃成（連不上等）          → 整個埠略過
 *   TLS1_3、TLS1_2、TLS1_1、TLS1、SSLv3、SSLv2
 *                          「offered」「offered with final」＝支援；「not offered」＝不支援
 *                                                                      → 支援的版本各產生一個 protocol 元件
 *   FS_ciphers             「TLS_AES_256_GCM_SHA384 ECDHE-RSA-AES256-GCM-SHA384 …」（空白分隔）
 *                                                                      → cipher suite 清單
 *   FS_KEMs                「X25519MLKEM768」；沒有時是一句話「No KEMs offered」  → 後量子金鑰交換群組
 *   FS_ECDHE_curves        「prime256v1 secp384r1 X25519 …」            → 傳統的金鑰交換群組
 *   FS_TLS13_sig_algs、FS_TLS12_sig_algs
 *                          「RSA-PSS-RSAE+SHA256 RSA+SHA256 …」         → 簽章演算法
 *   cipherlist_OBSOLETED   「offered」或「not offered」：有沒有 CBC 類的舊 cipher
 *   cipherlist_3DES_IDEA   同上：有沒有 3DES／IDEA
 *   cipherlist_STRONG_NOFS 同上：有沒有不具前向保密（forward secrecy）的 cipher
 *                                                                      → 這三個寫成 TLS 1.2 元件的屬性給規則用
 * </pre>
 */
final class TlsScanLayer implements Layer {

    @Override
    public String id() {
        return "tls";
    }

    @Override
    public String title() {
        return "TLS 掃描（testssl.sh）";
    }

    @Override
    public ObjectNode convert(Raw raw) throws IOException {
        return run(raw);
    }

    /** 每台主機的 tls/ 目錄裡每個 &lt;埠&gt;.json 交給 endpoint()。檔名排序後再處理，產出的順序才固定。 */
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
            // sort(null) = 照路徑的自然順序
            files.sort(null);
            for (Path file : files) {
                // 檔名就是埠。例：9092.json → 位置「kb01.poc.lab:9092」
                String port = file.getFileName().toString().replace(".json", "");
                endpoint(bom, raw.fqdn(host.name()) + ":" + port, Cdx.read(file));
            }
        }
        return bom;
    }

    /**
     * 一個埠的掃描結果 → 這個埠支援的每個 TLS 版本各一個 protocol 元件，加上金鑰交換群組與簽章演算法的 algorithm 元件。
     * location 例：「kb01.poc.lab:9092」；scan 是 testssl 的 JSON 陣列。
     */
    static void endpoint(ObjectNode bom, String location, JsonNode scan) {
        Map<String, String> findings = findingsById(scan);
        // 這個埠沒掃成：不產生任何元件
        if (findings.containsKey("scanProblem")) {
            return;
        }

        List<String> kems = postQuantumGroups(findings);
        List<String> curves = words(findings.get("FS_ECDHE_curves"));
        List<String> suites = words(findings.get("FS_ciphers"));

        // testssl 把所有版本的 cipher suite 列在一起，這裡依名稱分成 TLS 1.3 的與 TLS 1.2 的
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

        // TLS 1.3 能用的群組 = 後量子（KEM）的在前，加上傳統曲線；TLS 1.2 只能用傳統曲線
        List<String> groups13 = new ArrayList<>(kems);
        groups13.addAll(curves);

        // 參數：testssl 的 id、我們寫的版本、這個版本的 cipher suite、這個版本能用的群組。
        // TLS 1.1 以下只記「有沒有開」（規則會判違規），不記 cipher suite
        version(bom, location, findings, "TLS1_3", "1.3", suites13, groups13);
        version(bom, location, findings, "TLS1_2", "1.2", suites12, curves);
        version(bom, location, findings, "TLS1_1", "1.1", List.of(), List.of());
        version(bom, location, findings, "TLS1", "1.0", List.of(), List.of());
        version(bom, location, findings, "SSLv3", "SSLv3", List.of(), List.of());
        version(bom, location, findings, "SSLv2", "SSLv2", List.of(), List.of());

        keyExchangeAlgorithms(bom, location, groups13);
        signatureAlgorithms(bom, location, findings);
    }

    /** testssl 的 JSON 陣列 → 「id → finding」的表，方便用 id 查。例：{"TLS1_3": "offered with final", "FS_KEMs": "X25519MLKEM768"}。 */
    private static Map<String, String> findingsById(JsonNode scan) {
        Map<String, String> findings = new LinkedHashMap<>();
        for (JsonNode one : scan) {
            findings.put(one.path("id").asText(), one.path("finding").asText());
        }
        return findings;
    }

    /**
     * 伺服器支援的後量子金鑰交換群組（FS_KEMs）。例：「X25519MLKEM768」→ [X25519MLKEM768]。
     * 伺服器沒有後量子金鑰交換時（例如 JDK 21），testssl 寫的是一句話「No KEMs offered」，不是名稱清單 → 回空的清單。
     */
    private static List<String> postQuantumGroups(Map<String, String> findings) {
        String kemFinding = findings.get("FS_KEMs");
        if (kemFinding != null && kemFinding.startsWith("No ")) {
            return new ArrayList<>();
        }
        return words(kemFinding);
    }

    /** 每個金鑰交換群組一個 algorithm 元件（同名的群組在所有埠併成一筆，位置累加）。 */
    private static void keyExchangeAlgorithms(ObjectNode bom, String location, List<String> groups) {
        for (String group : groups) {
            ObjectNode algorithm = Cdx.asset("algorithm", group, "kex|" + group);
            Algo.apply(algorithm, group);
            Cdx.prop(algorithm, "source", "tls-scan");
            Cdx.prop(algorithm, "use", "TLS 金鑰交換");
            Cdx.occurrence(algorithm, location, "伺服器支援的金鑰交換群組");
            Cdx.add(bom, algorithm);
        }
    }

    /**
     * 每個交握簽章演算法一個 algorithm 元件。
     * 清單：TLS 1.3 的（FS_TLS13_sig_algs）在前，TLS 1.2 的（FS_TLS12_sig_algs）裡沒出現過的接在後面（不重複）。
     */
    private static void signatureAlgorithms(ObjectNode bom, String location, Map<String, String> findings) {
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

    /**
     * 一個 TLS 版本的 protocol 元件；這個埠不支援這個版本（finding 不是 offered 開頭）就什麼都不做。
     *
     * id 是 testssl 的項目名稱（TLS1_3、TLS1 …），version 是我們寫進 CBOM 的版本（1.3、1.0、SSLv3 …）。
     * 元件名稱：「TLS 1.3」「TLS 1.0」「SSLv3」。CycloneDX 的協定類型：TLS 寫 tls，SSL 寫 other。
     *
     * 身分字串包含版本、cipher suite 清單、群組清單、兩個 cipherlist_ 的結果：
     * 這幾項完全相同的埠會併成同一個元件（位置累加），有任何一項不同就是另一個元件——報告因此看得出哪個埠的設定和別人不一樣。
     *
     * 寫給規則用的屬性：tlsVersion、keyExchangeGroups（空白分隔）、
     * pqcKeyExchange（群組裡有名稱含 MLKEM 的 → offered，否則 none）；
     * 只有 TLS 1.2 另外寫 obsoleteCiphers、tripleDesCiphers、nonForwardSecrecyCiphers（值見 offered()）。
     */
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
            // 每個 cipher suite 掛上它能用的群組（CycloneDX 1.7 的 tlsGroups）。
            // DHE- 開頭的（TLS 1.2 的有限體 Diffie-Hellman）不用橢圓曲線群組，所以不掛
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

    /**
     * testssl 的 finding → 三種值。沒有這一項（null）→ unknown；「offered…」開頭 → offered；其他（例如「not offered」）→ none。
     */
    private static String offered(String finding) {
        if (finding == null) {
            return "unknown";
        }
        return finding.startsWith("offered") ? "offered" : "none";
    }

    /**
     * 把 finding 用空白切成一個一個名稱；null 回空的清單。testssl 有時在清單中間放「--」當分隔，那不是名稱，略過。
     * 例：「prime256v1 secp384r1 -- X25519」→ [prime256v1, secp384r1, X25519]。
     */
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
