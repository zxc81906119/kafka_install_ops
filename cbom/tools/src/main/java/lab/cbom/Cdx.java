package lab.cbom;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * CycloneDX 的 JSON 小工具：建元件、加出現位置、加屬性、把同一個元件合併成一筆。
 *
 * 每個元件的 bom-ref 由「它是什麼」算出來（不是亂數），所以不同主機、不同來源看到的同一個資產
 * 會得到同一個 bom-ref，合併時只留一筆、出現位置（occurrences）累加。
 */
final class Cdx {

    static final ObjectMapper JSON = new ObjectMapper().enable(SerializationFeature.INDENT_OUTPUT);

    /** 屬性名稱一律用這個開頭，和別的工具的屬性分開。 */
    static final String PREFIX = "cbom:";

    private Cdx() {
    }

    static ObjectNode newBom() {
        ObjectNode bom = JSON.createObjectNode();
        bom.put("bomFormat", "CycloneDX");
        bom.put("specVersion", "1.7");
        bom.put("version", 1);
        bom.putArray("components");
        return bom;
    }

    /** 密碼學資產（algorithm、certificate、protocol、related-crypto-material）。key 是用來算 bom-ref 的身分字串。 */
    static ObjectNode asset(String assetType, String name, String key) {
        ObjectNode component = JSON.createObjectNode();
        component.put("type", "cryptographic-asset");
        component.put("bom-ref", ref(assetType, key));
        component.put("name", name);
        component.putObject("cryptoProperties").put("assetType", assetType);
        return component;
    }

    /** 一般元件（file、library）。 */
    static ObjectNode plain(String type, String name, String key) {
        ObjectNode component = JSON.createObjectNode();
        component.put("type", type);
        component.put("bom-ref", ref(type, key));
        component.put("name", name);
        return component;
    }

    static String ref(String kind, String key) {
        return kind + ":" + sha256(key).substring(0, 16);
    }

    static String sha256(String text) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(text.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    static ObjectNode crypto(ObjectNode component, String propertiesName) {
        ObjectNode crypto = (ObjectNode) component.get("cryptoProperties");
        JsonNode existing = crypto.get(propertiesName);
        if (existing != null) {
            return (ObjectNode) existing;
        }
        return crypto.putObject(propertiesName);
    }

    /** 這個資產出現在哪裡。location 例：kb01.poc.lab:9092、kb01:/etc/confluent/kafka/server.properties。 */
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

    static String prop(JsonNode component, String name) {
        for (JsonNode one : component.path("properties")) {
            if (one.path("name").asText().equals(PREFIX + name)) {
                return one.path("value").asText();
            }
        }
        return null;
    }

    /** 放進 BOM；已經有同一個 bom-ref 時合併出現位置與屬性，不重複放。 */
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

    static void mergeInto(ObjectNode target, JsonNode source) {
        for (JsonNode occurrence : source.path("evidence").path("occurrences")) {
            occurrence(target, occurrence.path("location").asText(), occurrence.path("additionalContext").asText(""));
        }
        for (JsonNode property : source.path("properties")) {
            String name = property.path("name").asText();
            if (name.startsWith(PREFIX)) {
                prop(target, name.substring(PREFIX.length()), property.path("value").asText());
            }
        }
    }

    /** 依 bom-ref 排序後的元件表，輸出才固定。 */
    static Map<String, ObjectNode> byRef(JsonNode bom) {
        Map<String, ObjectNode> map = new LinkedHashMap<>();
        for (JsonNode component : bom.path("components")) {
            map.put(component.path("bom-ref").asText(), (ObjectNode) component);
        }
        return map;
    }

    static JsonNode read(Path file) throws IOException {
        return JSON.readTree(Files.readAllBytes(file));
    }

    static void write(Path file, JsonNode node) throws IOException {
        if (file.getParent() != null) {
            Files.createDirectories(file.getParent());
        }
        Files.write(file, JSON.writeValueAsBytes(node));
    }
}
