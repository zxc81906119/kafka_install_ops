package lab.cbom;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * CycloneDX 的 JSON 小工具：建元件、加出現位置、加屬性、把同一個元件合併成一筆。
 * 誰呼叫：每個 Layer、TheiaAdapter、MergeCommand、BomSteps、ReportCommand（幾乎所有類別）。
 *
 * 一個元件長這樣（規則與報告讀的就是這些欄位）：
 * <pre>
 * {
 *   "type": "cryptographic-asset",                    密碼學資產；一般元件是 "file" 或 "library"
 *   "bom-ref": "algorithm:3f2a9c0d1e4b5a67",          身分：種類 + 冒號 + 16 個十六進位字
 *   "name": "X25519MLKEM768",
 *   "cryptoProperties": { "assetType": "algorithm", "algorithmProperties": { "primitive": "kem" } },
 *   "evidence": { "occurrences": [ { "location": "kb01.poc.lab:9092", "additionalContext": "伺服器支援的金鑰交換群組" } ] },
 *   "properties": [ { "name": "cbom:family", "value": "ML-KEM-hybrid" }, { "name": "cbom:source", "value": "tls-scan" } ]
 * }
 * </pre>
 *
 * 每個元件的 bom-ref 由「它是什麼」算出來（不是亂數），所以不同主機、不同來源看到的同一個資產
 * 會得到同一個 bom-ref，合併時只留一筆、出現位置（occurrences）累加。
 *
 * 「它是什麼」就是 asset()／plain() 的第三個參數（身分字串）：<b>兩個元件的種類與身分字串相同，就會被當成同一個資產</b>。
 * 各層用的身分字串（開頭那一段是為了讓不同層的同名東西不會撞在一起）：
 * <pre>
 *   TlsScanLayer         kex|群組名稱                            algorithm    金鑰交換群組
 *                        tls-sig|簽章名稱                        algorithm    交握簽章演算法
 *                        tls|版本|cipher suite 清單|群組清單|…   protocol     一種 TLS 設定（清單完全相同的埠併成一筆）
 *   PlatformConfigLayer  config|主機:設定檔路徑                  file         每台的設定檔各一筆
 *                        sasl|機制名稱                           protocol     properties 與 SCRAM 帳號兩處用同一個字串，刻意併成一筆
 *                        token-sig|演算法名稱                    algorithm    MDS token 簽章
 *                        secret-protection|AES|位元數            algorithm
 *                        secret-protection|PBKDF2|迭代次數       algorithm
 *                        key-alg|演算法名稱                      algorithm    公鑰用的演算法
 *                        public-key|指紋                         related-crypto-material
 *                        keyfile|主機:檔案路徑                   file         keystore、truststore、私鑰檔
 *   JdkSettingsLayer     jdk|版本|每個設定的值…                  file         設定完全相同的主機併成一筆
 *                        os-crypto|政策|OS 版本|OpenSSL 版本     file
 *   LibraryLayer         lib|名稱|版本                           library
 *   RuntimeLayer         runtime|演算法名稱|provider             algorithm
 *                        runtime-tls|TLS 版本|cipher suite       protocol
 *   SourceCodeLayer      source|演算法名稱                       algorithm
 *                        source|種類|名稱|長度                   related-crypto-material
 *   TheiaAdapter         cert-alg|名稱|OID                       algorithm    憑證用的演算法
 *                        public-key|公鑰內容的 sha256            related-crypto-material
 *                        來源名稱|種類|名稱|檔名                 related-crypto-material   私鑰、寫死的秘密、keystore 檔
 *                        cert|主體|簽發者|起日|迄日|公鑰的 bom-ref   certificate
 *                        trust-store|image|張數                  file
 *                        openssl-config|路徑                     file
 *   CollectionCheck      collection-check（固定）                data         盤點完整性檢查，每份 CBOM 一個
 * </pre>
 * 改任何一個身分字串，那一類元件的 bom-ref 全部會變（產出就變了）：要跑 bash cbom/golden.sh check。
 */
final class Cdx {

    /** 全專案共用的 JSON 讀寫器；輸出有縮排（一個欄位一行），方便人看與比對。 */
    static final ObjectMapper JSON = new ObjectMapper().enable(SerializationFeature.INDENT_OUTPUT);

    /** 屬性名稱一律用這個開頭，和別的工具的屬性分開。prop() 會自動加上，呼叫時不用寫。 */
    static final String PREFIX = "cbom:";

    private Cdx() {
    }

    /** 一份空的 BOM：CycloneDX 1.7，components 是空陣列。每個 Layer 都從這個開始。 */
    static ObjectNode newBom() {
        ObjectNode bom = JSON.createObjectNode();
        bom.put("bomFormat", "CycloneDX");
        bom.put("specVersion", "1.7");
        bom.put("version", 1);
        bom.putArray("components");
        return bom;
    }

    /**
     * 建一個密碼學資產。assetType 是 CycloneDX 定的四種：algorithm、certificate、protocol、related-crypto-material。
     * name 是給人看的名稱；key 是用來算 bom-ref 的身分字串（見檔頭的表）。
     * 例：asset("algorithm", "X25519", "kex|X25519") → bom-ref 是「algorithm:」加 16 個十六進位字。
     */
    static ObjectNode asset(String assetType, String name, String key) {
        ObjectNode component = JSON.createObjectNode();
        component.put("type", "cryptographic-asset");
        component.put("bom-ref", ref(assetType, key));
        component.put("name", name);
        component.putObject("cryptoProperties").put("assetType", assetType);
        return component;
    }

    /** 建一個一般元件（type 是 file 或 library，沒有 cryptoProperties）。name、key 的意思和 asset() 相同。 */
    static ObjectNode plain(String type, String name, String key) {
        ObjectNode component = JSON.createObjectNode();
        component.put("type", type);
        component.put("bom-ref", ref(type, key));
        component.put("name", name);
        return component;
    }

    /**
     * 算 bom-ref：種類 + 冒號 + 身分字串的 SHA-256 前 16 個十六進位字（64 位元，夠分辨又不會太長）。
     * 例：ref("file", "config|kb01:/etc/kafka/server.properties") →「file:9b1c…（共 16 個字）」。
     * 同樣的 kind 與 key 永遠得到同一個結果。
     */
    static String ref(String kind, String key) {
        return kind + ":" + sha256(key).substring(0, 16);
    }

    /** 字串的 SHA-256，寫成 64 個小寫十六進位字。這裡只拿來做識別（bom-ref、指紋），不是安全用途。 */
    static String sha256(String text) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(text.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * 取出密碼學資產的細節物件（cryptoProperties 底下的那一塊），沒有就建一個空的；拿到之後直接 put 欄位。
     * propertiesName 依資產種類是：algorithmProperties、protocolProperties、certificateProperties、
     * relatedCryptoMaterialProperties。只能用在 asset() 建的元件（plain() 的元件沒有 cryptoProperties）。
     * 例：Cdx.crypto(protocol, "protocolProperties").put("type", "tls")。
     */
    static ObjectNode crypto(ObjectNode component, String propertiesName) {
        ObjectNode crypto = (ObjectNode) component.get("cryptoProperties");
        JsonNode existing = crypto.get(propertiesName);
        if (existing != null) {
            return (ObjectNode) existing;
        }
        return crypto.putObject(propertiesName);
    }

    /**
     * 記一個出現位置：這個資產出現在哪裡。location 例：kb01.poc.lab:9092、kb01:/etc/confluent/kafka/server.properties。
     * context 是補充說明（寫進 additionalContext；null 或空字串就不寫）。
     * 同一個 location 已經記過就不再加（說明以先記的為準）。
     */
    static void occurrence(ObjectNode component, String location, String context) {
        ObjectNode evidence = (ObjectNode) component.get("evidence");
        if (evidence == null) {
            evidence = component.putObject("evidence");
        }
        ArrayNode occurrences = (ArrayNode) evidence.get("occurrences");
        if (occurrences == null) {
            occurrences = evidence.putArray("occurrences");
        }
        for (JsonNode one : occurrences) {
            if (location.equals(one.path("location").asText())) {
                return;
            }
        }
        ObjectNode occurrence = occurrences.addObject();
        occurrence.put("location", location);
        if (context != null && !context.isEmpty()) {
            occurrence.put("additionalContext", context);
        }
    }

    /**
     * 寫一個屬性（給規則與報告讀的資料）。名稱會自動加上「cbom:」。
     * 例：prop(c, "family", "RSA") → properties 多一筆 {"name": "cbom:family", "value": "RSA"}。
     * value 是 null 就什麼都不做；同名同值已經有了就不重複加。
     * 注意：同名不同值會<b>各留一筆</b>（不是覆寫），例如同一個演算法的兩個 callSite。
     */
    static void prop(ObjectNode component, String name, String value) {
        if (value == null) {
            return;
        }
        ArrayNode properties = (ArrayNode) component.get("properties");
        if (properties == null) {
            properties = component.putArray("properties");
        }
        for (JsonNode one : properties) {
            if (one.path("name").asText().equals(PREFIX + name) && one.path("value").asText().equals(value)) {
                return;
            }
        }
        ObjectNode property = properties.addObject();
        property.put("name", PREFIX + name);
        property.put("value", value);
    }

    /**
     * 讀一個屬性（兩個參數的 prop 是讀，三個參數的是寫）。名稱不用寫「cbom:」。
     * 例：prop(c, "family") →「RSA」。沒有這個屬性回 null；同名有好幾筆時回第一筆。
     */
    static String prop(JsonNode component, String name) {
        for (JsonNode one : component.path("properties")) {
            if (one.path("name").asText().equals(PREFIX + name)) {
                return one.path("value").asText();
            }
        }
        return null;
    }

    /**
     * 把元件放進 BOM；已經有同一個 bom-ref 時不重複放，只把新元件的出現位置與屬性併到原有的那一筆
     * （名稱、cryptoProperties 等其他欄位以先放的為準）。
     */
    static void add(ObjectNode bom, ObjectNode component) {
        ArrayNode components = (ArrayNode) bom.get("components");
        String ref = component.get("bom-ref").asText();
        for (JsonNode existing : components) {
            if (existing.get("bom-ref").asText().equals(ref)) {
                mergeInto((ObjectNode) existing, component);
                return;
            }
        }
        components.add(component);
    }

    /** 把 source 的出現位置與「cbom:」開頭的屬性併到 target（別的工具的屬性不併）。 */
    static void mergeInto(ObjectNode target, JsonNode source) {
        for (JsonNode occurrence : source.path("evidence").path("occurrences")) {
            occurrence(target, occurrence.path("location").asText(), occurrence.path("additionalContext").asText(""));
        }
        for (JsonNode property : source.path("properties")) {
            String name = property.path("name").asText();
            if (name.startsWith(PREFIX)) {
                // prop() 會自己加上 PREFIX，所以先把它去掉
                prop(target, name.substring(PREFIX.length()), property.path("value").asText());
            }
        }
    }

    /** 讀一個 JSON 檔。 */
    static JsonNode read(Path file) throws IOException {
        return JSON.readTree(Files.readAllBytes(file));
    }

    /** 寫一個 JSON 檔（UTF-8、有縮排）；上層目錄不存在就先建。 */
    static void write(Path file, JsonNode node) throws IOException {
        if (file.getParent() != null) {
            Files.createDirectories(file.getParent());
        }
        Files.write(file, JSON.writeValueAsBytes(node));
    }
}
