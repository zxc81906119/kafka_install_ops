package lab.cbom;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

import org.cyclonedx.Version;
import org.cyclonedx.exception.ParseException;
import org.cyclonedx.generators.BomGeneratorFactory;
import org.cyclonedx.model.Bom;
import org.cyclonedx.parsers.JsonParser;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 把各層的結果併成一份 CBOM，補上這次盤點的範圍，再用 CycloneDX 官方的 schema 驗證。
 *
 * 來源：TlsCommand、ConfigCommand、JdkCommand、LibsCommand、JfrCommand 的結果，加上 cbomkit-theia 的輸出
 * （raw/shared/theia.json：憑證、公鑰、簽章演算法）。
 * 同一個資產（同一個 bom-ref）只留一筆，出現位置累加；所以一張部署在 4 台 broker 的憑證是 1 個元件、4 個位置。
 */
final class MergeCommand {

    private MergeCommand() {
    }

    static ObjectNode run(Raw raw, List<JsonNode> fragments, String specVersion) throws IOException {
        ObjectNode bom = Cdx.newBom();
        for (JsonNode fragment : fragments) {
            for (JsonNode component : fragment.path("components")) {
                Cdx.add(bom, (ObjectNode) component.deepCopy());
            }
        }
        ArrayNode dependencies = bom.putArray("dependencies");
        Path theia = raw.shared().resolve("theia.json");
        if (Files.isRegularFile(theia)) {
            addTheia(bom, dependencies, Cdx.read(theia), raw);
        }
        if (dependencies.isEmpty()) {
            bom.remove("dependencies");
        }

        for (JsonNode component : bom.path("components")) {
            scope((ObjectNode) component, raw);
        }
        sortComponents(bom);
        metadata(bom, raw);
        return finish(bom, specVersion);
    }

    /**
     * cbomkit-theia 的元件用亂數當 bom-ref，同一張憑證在每個檔案各出現一次。
     * 這裡改成由內容算出的 bom-ref（同一張憑證只留一筆），並把互相參照的欄位跟著改。
     */
    static void addTheia(ObjectNode bom, ArrayNode dependencies, JsonNode theia, Raw raw) {
        Map<String, JsonNode> byOldRef = new LinkedHashMap<>();
        for (JsonNode component : theia.path("components")) {
            byOldRef.put(component.path("bom-ref").asText(), component);
        }

        // 1. 先算演算法與公鑰的新 bom-ref（憑證的身分要用到公鑰的新 bom-ref）
        Map<String, String> newRef = new LinkedHashMap<>();
        for (JsonNode component : byOldRef.values()) {
            JsonNode crypto = component.path("cryptoProperties");
            String assetType = crypto.path("assetType").asText();
            String name = component.path("name").asText();
            if ("algorithm".equals(assetType)) {
                newRef.put(component.path("bom-ref").asText(), Cdx.ref("algorithm", "cert-alg|" + name + "|" + crypto.path("oid").asText()));
            } else if ("related-crypto-material".equals(assetType)) {
                String value = crypto.path("relatedCryptoMaterialProperties").path("value").asText(name);
                newRef.put(component.path("bom-ref").asText(), Cdx.ref("related-crypto-material", "public-key|" + Cdx.sha256(value)));
            }
        }
        for (JsonNode component : byOldRef.values()) {
            JsonNode crypto = component.path("cryptoProperties");
            if (!"certificate".equals(crypto.path("assetType").asText())) {
                continue;
            }
            JsonNode certificate = crypto.path("certificateProperties");
            String key = "cert|" + certificate.path("subjectName").asText() + "|" + certificate.path("issuerName").asText()
                + "|" + certificate.path("notValidBefore").asText() + "|" + certificate.path("notValidAfter").asText()
                + "|" + newRef.get(certificate.path("subjectPublicKeyRef").asText());
            newRef.put(component.path("bom-ref").asText(), Cdx.ref("certificate", key));
        }

        // 2. 改寫每個元件：新的 bom-ref、參照、出現位置，再併進 BOM
        for (JsonNode original : byOldRef.values()) {
            ObjectNode component = (ObjectNode) original.deepCopy();
            ObjectNode crypto = (ObjectNode) component.get("cryptoProperties");
            String assetType = crypto.path("assetType").asText();
            component.put("bom-ref", newRef.get(original.path("bom-ref").asText()));
            component.remove("evidence");
            for (JsonNode occurrence : original.path("evidence").path("occurrences")) {
                String[] where = location(occurrence.path("location").asText(), raw);
                Cdx.occurrence(component, where[0], where[1]);
            }
            Cdx.prop(component, "source", "certificate-file");

            if ("algorithm".equals(assetType)) {
                Algo.apply(component, component.path("name").asText());
            } else if ("related-crypto-material".equals(assetType)) {
                ObjectNode material = (ObjectNode) crypto.get("relatedCryptoMaterialProperties");
                remap(material, "algorithmRef", newRef);
                Algo.Info info = Algo.describe(component.path("name").asText());
                Cdx.prop(component, "family", info.family());
                if (info.keySize() > 0) {
                    Cdx.prop(component, "keySize", String.valueOf(info.keySize()));
                }
            } else if ("certificate".equals(assetType)) {
                ObjectNode certificate = (ObjectNode) crypto.get("certificateProperties");
                JsonNode signature = byOldRef.get(certificate.path("signatureAlgorithmRef").asText());
                JsonNode publicKey = byOldRef.get(certificate.path("subjectPublicKeyRef").asText());
                if (signature != null) {
                    Algo.Info info = Algo.describe(signature.path("name").asText());
                    Cdx.prop(component, "signatureAlgorithm", signature.path("name").asText());
                    Cdx.prop(component, "signatureFamily", info.family());
                    if (info.digest() != null) {
                        Cdx.prop(component, "signatureDigest", info.digest());
                    }
                }
                if (publicKey != null) {
                    Algo.Info info = Algo.describe(publicKey.path("name").asText());
                    Cdx.prop(component, "keyAlgorithm", publicKey.path("name").asText());
                    Cdx.prop(component, "family", info.family());
                    if (info.keySize() > 0) {
                        Cdx.prop(component, "keySize", String.valueOf(info.keySize()));
                    }
                }
                remap(certificate, "signatureAlgorithmRef", newRef);
                remap(certificate, "subjectPublicKeyRef", newRef);
            }
            Cdx.add(bom, component);
        }

        // 3. 相依關係：參照跟著改，同一個 ref 的併在一起
        Map<String, TreeSet<String>> merged = new TreeMap<>();
        for (JsonNode dependency : theia.path("dependencies")) {
            String ref = newRef.get(dependency.path("ref").asText());
            if (ref == null) {
                continue;
            }
            TreeSet<String> targets = merged.computeIfAbsent(ref, k -> new TreeSet<>());
            for (JsonNode target : dependency.path("dependsOn")) {
                String mapped = newRef.get(target.asText());
                if (mapped != null && !mapped.equals(ref)) {
                    targets.add(mapped);
                }
            }
        }
        for (Map.Entry<String, TreeSet<String>> entry : merged.entrySet()) {
            if (entry.getValue().isEmpty()) {
                continue;
            }
            ObjectNode dependency = dependencies.addObject();
            dependency.put("ref", entry.getKey());
            ArrayNode dependsOn = dependency.putArray("dependsOn");
            entry.getValue().forEach(dependsOn::add);
        }
    }

    private static void remap(ObjectNode node, String field, Map<String, String> newRef) {
        String mapped = newRef.get(node.path(field).asText());
        if (mapped != null) {
            node.put(field, mapped);
        } else {
            node.remove(field);
        }
    }

    /** 原料目錄裡的相對路徑 → 人看得懂的位置。回傳 {位置, 說明}。 */
    static String[] location(String path, Raw raw) {
        String[] parts = path.replace('\\', '/').split("/");
        if (parts.length >= 3 && "served".equals(parts[1])) {
            return new String[] {raw.fqdn(parts[0]) + ":" + parts[2].replace(".pem", ""), "這個埠實際出示的憑證鏈"};
        }
        if (parts.length >= 3 && "shared".equals(parts[0]) && "pki".equals(parts[1])) {
            return new String[] {"ops02:~/pki/certs/" + parts[2], "操作機的憑證來源"};
        }
        if (parts.length == 2) {
            return new String[] {parts[0] + ":/etc/confluent/ssl/" + parts[1], "主機上的憑證檔"};
        }
        return new String[] {path, ""};
    }

    /** 從出現位置算出這個資產在哪些主機、哪些元件，寫成屬性（報告與規則用）。 */
    static void scope(ObjectNode component, Raw raw) {
        TreeSet<String> hosts = new TreeSet<>();
        TreeSet<String> roles = new TreeSet<>();
        for (JsonNode occurrence : component.path("evidence").path("occurrences")) {
            String location = occurrence.path("location").asText();
            String first = location.split("[:.]", 2)[0];
            boolean known = raw.hosts().stream().anyMatch(h -> h.name().equals(first));
            if (known) {
                hosts.add(first);
                roles.add(raw.roleOf(first));
            } else {
                roles.add("shared");
            }
        }
        if (!hosts.isEmpty()) {
            Cdx.prop(component, "hosts", String.join(" ", hosts));
        }
        Cdx.prop(component, "roles", String.join(" ", roles));
    }

    private static void sortComponents(ObjectNode bom) {
        List<JsonNode> components = new ArrayList<>();
        bom.path("components").forEach(components::add);
        components.sort((a, b) -> {
            String left = a.path("cryptoProperties").path("assetType").asText(a.path("type").asText()) + "|" + a.path("name").asText() + "|" + a.path("bom-ref").asText();
            String right = b.path("cryptoProperties").path("assetType").asText(b.path("type").asText()) + "|" + b.path("name").asText() + "|" + b.path("bom-ref").asText();
            return left.compareTo(right);
        });
        ArrayNode sorted = bom.putArray("components");
        components.forEach(sorted::add);
    }

    static void metadata(ObjectNode bom, Raw raw) {
        ObjectNode metadata = bom.putObject("metadata");
        metadata.put("timestamp", raw.get("COLLECTED_AT"));
        ObjectNode tools = metadata.putObject("tools");
        ArrayNode toolComponents = tools.putArray("components");
        for (String tool : raw.get("TOOLS").split(",\\s*")) {
            String[] parts = tool.trim().split("\\s+", 2);
            if (parts[0].isEmpty()) {
                continue;
            }
            ObjectNode one = toolComponents.addObject();
            one.put("type", "application");
            one.put("name", parts[0]);
            if (parts.length > 1) {
                one.put("version", parts[1]);
            }
        }
        ObjectNode subject = metadata.putObject("component");
        subject.put("type", "platform");
        subject.put("bom-ref", "platform:confluent-platform-" + raw.get("ENV"));
        subject.put("name", "Confluent Platform（" + raw.get("ENV") + "）");
        if (!raw.get("CP_VERSION").isEmpty()) {
            subject.put("version", raw.get("CP_VERSION"));
        }
        ArrayNode properties = metadata.putArray("properties");
        property(properties, "scope", raw.fullScope() ? "full" : "partial");
        property(properties, "roles", raw.get("ROLES"));
        property(properties, "allRoles", raw.get("ALL_ROLES"));
        property(properties, "hosts", raw.get("HOSTS"));
        property(properties, "runtimeEvidence", raw.get("JFR_SECONDS").isEmpty() ? "none" : "JFR " + raw.get("JFR_SECONDS") + " 秒");
    }

    private static void property(ArrayNode properties, String name, String value) {
        ObjectNode property = properties.addObject();
        property.put("name", Cdx.PREFIX + name);
        property.put("value", value);
    }

    /** 用官方 schema 驗證；要 1.6 時由官方函式庫轉（1.7 才有的欄位會被拿掉，金鑰交換群組另外留在屬性裡）。 */
    static ObjectNode finish(ObjectNode bom, String specVersion) throws IOException {
        byte[] bytes = Cdx.JSON.writeValueAsBytes(bom);
        List<ParseException> errors = new JsonParser().validate(bytes, Version.VERSION_17);
        if (!errors.isEmpty()) {
            StringBuilder message = new StringBuilder("CBOM 不符合 CycloneDX 1.7 的 schema：");
            errors.stream().limit(10).forEach(e -> message.append("\n  ").append(e.getMessage()));
            throw new IOException(message.toString());
        }
        if ("1.7".equals(specVersion)) {
            return bom;
        }
        if (!"1.6".equals(specVersion)) {
            throw new IOException("只支援 1.7 與 1.6，不是 " + specVersion);
        }
        try {
            Bom model = new JsonParser().parse(bytes);
            String json = BomGeneratorFactory.createJson(Version.VERSION_16, model).toJsonString();
            List<ParseException> errors16 = new JsonParser().validate(json.getBytes(StandardCharsets.UTF_8), Version.VERSION_16);
            if (!errors16.isEmpty()) {
                throw new IOException("轉成 1.6 之後不符合 schema：" + errors16.get(0).getMessage());
            }
            return (ObjectNode) Cdx.JSON.readTree(json);
        } catch (ParseException | org.cyclonedx.exception.GeneratorException e) {
            throw new IOException("轉成 CycloneDX 1.6 失敗：" + e.getMessage(), e);
        }
    }
}
