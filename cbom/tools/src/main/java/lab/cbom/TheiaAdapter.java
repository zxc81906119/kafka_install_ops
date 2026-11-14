package lab.cbom;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * cbomkit-theia 的 CBOM → 這邊的元件。掃目錄（FilesLayer）與掃映像（ImageLayer）共用。
 *
 * 輸入：cbomkit-theia 輸出的 CycloneDX CBOM（components 與 dependencies）。
 * 輸出：把整理好的元件加進呼叫者給的 BOM，相依關係加進呼叫者給的 dependencies 陣列。
 * 誰呼叫：FilesLayer → addTheia；ImageLayer → addTheiaImage（先過濾，再呼叫 addTheia）。
 *
 * 為什麼要整理：theia 的元件用亂數當 bom-ref、同一張憑證在每個檔各出現一次；
 * 這裡改成由內容算 bom-ref（同一張憑證只留一筆），並把互相參照的欄位跟著改。
 *
 * theia 的一張憑證是三個元件，用 bom-ref 互相指：
 * <pre>
 *   certificate 元件                     certificateProperties.signatureAlgorithmRef → 簽章演算法元件
 *                                        certificateProperties.subjectPublicKeyRef   → 公鑰元件
 *   related-crypto-material（public-key）relatedCryptoMaterialProperties.algorithmRef → 公鑰的演算法元件
 *   algorithm 元件
 * </pre>
 * 開了秘密功能時還有另一種 related-crypto-material：私鑰（private-key）、寫死的秘密、keystore 檔。
 * 程式裡把這一種叫做「掃到的秘密」（secretFinding），和憑證帶出來的公鑰分開處理。
 *
 * 元件上寫的屬性 cbom:source：憑證、公鑰、演算法是 certificate-file；掃到的秘密是呼叫者指定的來源
 * （掃目錄 secret-scan、掃映像 image-scan）。
 */
final class TheiaAdapter {

    private TheiaAdapter() {
    }

    /** 原料裡的路徑 → {給人看的位置, 說明}；怎麼顯示由盤點對象（Profile）決定。 */
    static String[] location(String path, Raw raw) {
        return Profile.of(raw).location(path, raw);
    }

    /**
     * 整理 theia 的整份 CBOM，加進 bom 與 dependencies。分四步，每一步一個方法：
     * <pre>
     *   1. indexByOldRef       把元件照 theia 給的（亂數）bom-ref 排成一張表
     *   2. newRefs             算出每個元件的新 bom-ref（由內容算）
     *   3. rewrite             改寫每個元件：新的 bom-ref、參照、出現位置、給規則用的屬性，再併進 bom
     *   4. mergeDependencies   相依關係：參照跟著改，同一個元件的併在一起
     * </pre>
     * sourceForSecrets：掃到的秘密（私鑰、寫死的秘密、keystore 檔；theia 的 secrets 功能有開才會有）要標成哪個來源：
     * 原始碼目錄是 secret-scan，映像是 image-scan。只開憑證功能時（Confluent Platform 的盤點）不會有這類元件。
     */
    static void addTheia(ObjectNode bom, ArrayNode dependencies, JsonNode theia, Raw raw, String sourceForSecrets) {
        Map<String, JsonNode> byOldRef = indexByOldRef(theia);
        Map<String, String> newRef = newRefs(byOldRef, sourceForSecrets);
        for (JsonNode original : byOldRef.values()) {
            Cdx.add(bom, rewrite(original, byOldRef, newRef, raw, sourceForSecrets));
        }
        mergeDependencies(dependencies, theia, newRef);
    }

    /** 第 1 步：theia 的元件照它原本的 bom-ref 排成表（舊 bom-ref → 元件），順序照 theia 的輸出。 */
    private static Map<String, JsonNode> indexByOldRef(JsonNode theia) {
        Map<String, JsonNode> byOldRef = new LinkedHashMap<>();
        int index = 0;
        for (JsonNode component : theia.path("components")) {
            index++;
            JsonNode one = component;
            // 秘密掃描找到的元件沒有 bom-ref：給一個暫時的（theia-without-ref-第幾個），否則會互相蓋掉只剩最後一筆
            if (component.path("bom-ref").asText().isEmpty()) {
                one = ((ObjectNode) component.deepCopy()).put("bom-ref", "theia-without-ref-" + index);
            }
            byOldRef.put(one.path("bom-ref").asText(), one);
        }
        return byOldRef;
    }

    /**
     * 第 2 步：算每個元件的新 bom-ref（舊 bom-ref → 新 bom-ref）。新的由「它是什麼」算，所以同一個東西只會有一個：
     * <pre>
     *   演算法       名稱 + OID                       例：SHA256-RSA + 1.2.840.113549.1.1.11
     *   公鑰         公鑰內容（value）的 SHA-256；theia 沒給內容時用名稱
     *   掃到的秘密   來源 + 種類 + 名稱 + 檔名（不含目錄）
     *   憑證         主體 + 簽發者 + 起日 + 迄日 + 公鑰的新 bom-ref
     * </pre>
     * 分兩輪：憑證的身分要用到公鑰的新 bom-ref，所以先算演算法與金鑰，再算憑證。
     * 這四種以外的元件（theia 目前不會給）沒有新 bom-ref。
     */
    private static Map<String, String> newRefs(Map<String, JsonNode> byOldRef, String sourceForSecrets) {
        Map<String, String> newRef = new LinkedHashMap<>();
        // 第一輪：演算法、公鑰、掃到的秘密
        for (JsonNode component : byOldRef.values()) {
            JsonNode crypto = component.path("cryptoProperties");
            String assetType = crypto.path("assetType").asText();
            String name = component.path("name").asText();
            String oldRef = component.path("bom-ref").asText();
            if ("algorithm".equals(assetType)) {
                newRef.put(oldRef, Cdx.ref("algorithm", "cert-alg|" + name + "|" + crypto.path("oid").asText()));
            } else if ("related-crypto-material".equals(assetType) && publicKey(crypto)) {
                String value = crypto.path("relatedCryptoMaterialProperties").path("value").asText(name);
                newRef.put(oldRef, Cdx.ref("related-crypto-material", "public-key|" + Cdx.sha256(value)));
            } else if ("related-crypto-material".equals(assetType)) {
                // 私鑰、寫死的秘密、keystore 檔：同一種東西在同一個檔名算一筆（映像裡同一個檔常有好幾條路徑）
                String type = crypto.path("relatedCryptoMaterialProperties").path("type").asText("unknown");
                // 檔名取第一個出現位置的最後一段。例：「app/config/keys/server.key」→「server.key」
                String first = component.path("evidence").path("occurrences").path(0).path("location").asText().replace('\\', '/');
                String fileName = first.substring(first.lastIndexOf('/') + 1);
                newRef.put(oldRef,
                    Cdx.ref("related-crypto-material", sourceForSecrets + "|" + type + "|" + name + "|" + fileName));
            }
        }
        // 第二輪：憑證
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
        return newRef;
    }

    /**
     * 第 3 步：改寫一個元件（回傳改好的複本，不動原本的）。
     * 共同的部分：換成新的 bom-ref；出現位置換成給人看的位置（Profile 決定）；寫 cbom:source。
     * 之後依種類補上給規則用的屬性：演算法 → Algo.apply；金鑰與秘密 → describeMaterial；憑證 → describeCertificate。
     */
    private static ObjectNode rewrite(JsonNode original, Map<String, JsonNode> byOldRef, Map<String, String> newRef,
        Raw raw, String sourceForSecrets) {
        ObjectNode component = (ObjectNode) original.deepCopy();
        ObjectNode crypto = (ObjectNode) component.get("cryptoProperties");
        String assetType = crypto.path("assetType").asText();
        component.put("bom-ref", newRef.get(original.path("bom-ref").asText()));
        // 判斷是不是「掃到的秘密」：是金鑰材料，但不是憑證帶出來的公鑰（也就是私鑰、寫死的秘密、keystore 檔）
        boolean secretFinding = "related-crypto-material".equals(assetType) && !publicKey(crypto);

        // 出現位置重寫：theia 記的是原料裡的路徑，換成給人看的位置
        component.remove("evidence");
        for (JsonNode occurrence : original.path("evidence").path("occurrences")) {
            String[] where = location(occurrence.path("location").asText(), raw);
            int line = occurrence.path("line").asInt(0);
            // 掃到的秘密有行號時，位置後面加「:行號」（例：src/main/resources/application.yml:12）；憑證類不加
            String place;
            if (secretFinding && line > 0) {
                place = where[0] + ":" + line;
            } else {
                place = where[0];
            }
            Cdx.occurrence(component, place, where[1]);
        }
        // 來源：掃到的秘密用呼叫者指定的（secret-scan 或 image-scan），其餘是 certificate-file
        String source;
        if (secretFinding) {
            source = sourceForSecrets;
        } else {
            source = "certificate-file";
        }
        Cdx.prop(component, "source", source);

        if ("algorithm".equals(assetType)) {
            Algo.apply(component, component.path("name").asText());
        } else if ("related-crypto-material".equals(assetType)) {
            describeMaterial(component, crypto, newRef, secretFinding);
        } else if ("certificate".equals(assetType)) {
            describeCertificate(component, crypto, byOldRef, newRef);
        }
        return component;
    }

    /**
     * 金鑰材料（公鑰，或掃到的秘密）：algorithmRef 換成新的 bom-ref，再寫給規則用的屬性。
     * <pre>
     *   掃到的秘密                → cbom:materialType = 種類（private-key、secret-key、password …）
     *   公鑰、私鑰                → cbom:family、cbom:keySize（從名稱整理，名稱是演算法：RSA-2048、ECDSA）
     *   寫死的秘密、keystore 檔   → 不寫家族（它們的名稱不是演算法）
     * </pre>
     */
    private static void describeMaterial(ObjectNode component, ObjectNode crypto, Map<String, String> newRef,
        boolean secretFinding) {
        ObjectNode material = (ObjectNode) crypto.get("relatedCryptoMaterialProperties");
        remap(material, "algorithmRef", newRef);
        String type = material.path("type").asText("unknown");
        if (secretFinding) {
            Cdx.prop(component, "materialType", type);
        }
        // 公鑰與私鑰的名稱是演算法（RSA-2048、ECDSA）；寫死的秘密與 keystore 檔的名稱不是，不算家族
        if (!secretFinding || "private-key".equals(type)) {
            Algo.Info info = Algo.describe(component.path("name").asText());
            Cdx.prop(component, "family", info.family());
            if (info.keySize() > 0) {
                Cdx.prop(component, "keySize", String.valueOf(info.keySize()));
            }
        }
    }

    /**
     * 憑證：把它指到的簽章演算法與公鑰的資訊直接寫在憑證元件上（規則與報告只看憑證這一個元件就夠），再把兩個參照換成新的 bom-ref。
     * <pre>
     *   cbom:signatureAlgorithm   簽章演算法的名稱。例：SHA256-RSA
     *   cbom:signatureFamily      它的家族。例：RSA
     *   cbom:signatureDigest      它用的雜湊。例：SHA-2（看不出來就不寫）
     *   cbom:keyAlgorithm         公鑰的名稱。例：RSA-2048
     *   cbom:family、cbom:keySize 公鑰的家族與長度。例：RSA、2048
     * </pre>
     * 找不到它指的元件（theia 沒給）就不寫那一組屬性。
     */
    private static void describeCertificate(ObjectNode component, ObjectNode crypto, Map<String, JsonNode> byOldRef,
        Map<String, String> newRef) {
        ObjectNode certificate = (ObjectNode) crypto.get("certificateProperties");
        // 這時參照還是舊的 bom-ref，所以用 byOldRef 查
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

    /**
     * 第 4 步：相依關係（「誰用到誰」，例如憑證 → 它的簽章演算法與公鑰）。
     * 參照換成新的 bom-ref；好幾個舊元件變成同一個新元件時，它們的 dependsOn 併在一起（排序、不重複）。
     * 略過：對不到新 bom-ref 的、指到自己的、併完之後 dependsOn 是空的。
     */
    private static void mergeDependencies(ArrayNode dependencies, JsonNode theia, Map<String, String> newRef) {
        // 新 bom-ref → 它用到的新 bom-ref。TreeMap／TreeSet：輸出的順序固定
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

    /** 這個金鑰材料是不是公鑰（relatedCryptoMaterialProperties.type 是 public-key）。 */
    private static boolean publicKey(JsonNode crypto) {
        return "public-key".equals(crypto.path("relatedCryptoMaterialProperties").path("type").asText());
    }

    /**
     * 映像內建的 CA 信任庫與 OS 的憑證目錄：上千張公開的 CA 憑證，不逐張列，只記張數。
     * 路徑符合下面兩種之一就算（開頭的 / 可有可無）：
     * <pre>
     *   在 etc/pki/、etc/ssl/、usr/share/pki/、usr/share/ca-certificates/ 底下
     *       例：etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem、/etc/ssl/certs/ca-certificates.crt
     *   結尾是 /lib/security/cacerts（JDK 自己的信任庫）
     *       例：opt/java/openjdk/lib/security/cacerts
     * </pre>
     */
    private static final java.util.regex.Pattern SYSTEM_STORE = java.util.regex.Pattern.compile(
        "^/?(etc/pki|etc/ssl|usr/share/pki|usr/share/ca-certificates)/.*|.*/lib/security/cacerts$");

    /**
     * cbomkit-theia 掃容器映像的結果（raw/shared/theia-image.json）。
     * 留下：OpenSSL 設定檔、信任庫以外的憑證與金鑰、秘密掃描命中的檔（多半是誤判，交給人看）。
     * 不留：CA 信任庫的內容（只記張數）、用 -b 帶進去又原樣出來的原始碼層元件（位置是 workspace/ 開頭）。
     *
     * 每個元件照順序問四件事，第一個成立的決定它的去向：
     * <pre>
     *   1. 沒有出現位置，或每個位置都是 workspace/ 開頭          → 丟掉（原始碼層已經有了）
     *   2. 元件的 type 是 file（theia 的 OpenSSL 設定檔）         → 轉成我們的 file 元件（opensslConfig）
     *   3. 每個位置都在系統的信任庫裡（SYSTEM_STORE）            → 丟掉；是憑證的話張數加一
     *   4. 其他                                                  → 留下，位置前面加「image:/」，交給 addTheia 整理
     * </pre>
     * 最後張數大於 0 時加一個 file 元件「映像內建的 CA 信任庫」（cbom:kind=trust-store、cbom:certificates=張數）。
     */
    static void addTheiaImage(ObjectNode bom, ArrayNode dependencies, JsonNode theia, Raw raw) {
        // 留下來的元件先放在一份只有 components 的 BOM，最後一次交給 addTheia（相依關係這裡不帶，映像的不留）
        ObjectNode filtered = Cdx.JSON.createObjectNode();
        ArrayNode kept = filtered.putArray("components");
        int caCertificates = 0;
        for (JsonNode component : theia.path("components")) {
            List<String> locations = new ArrayList<>();
            for (JsonNode occurrence : component.path("evidence").path("occurrences")) {
                locations.add(occurrence.path("location").asText().replace('\\', '/'));
            }
            if (locations.isEmpty() || locations.stream().allMatch(l -> l.startsWith("workspace/"))) {
                continue;
            }
            if ("file".equals(component.path("type").asText())) {
                opensslConfig(bom, component, locations);
                continue;
            }
            if (locations.stream().allMatch(l -> SYSTEM_STORE.matcher(l).matches())) {
                if ("certificate".equals(component.path("cryptoProperties").path("assetType").asText())) {
                    caCertificates++;
                }
                continue;
            }
            ObjectNode copy = (ObjectNode) component.deepCopy();
            for (JsonNode occurrence : copy.path("evidence").path("occurrences")) {
                String location = occurrence.path("location").asText().replace('\\', '/');
                ((ObjectNode) occurrence).put("location", imageLocation(location));
            }
            kept.add(copy);
        }
        addTheia(bom, dependencies, filtered, raw, "image-scan");
        if (caCertificates > 0) {
            // 張數也放進身分字串：張數不同的映像是不同的元件
            ObjectNode store = Cdx.plain("file", "映像內建的 CA 信任庫", "trust-store|image|" + caCertificates);
            Cdx.prop(store, "source", "image-scan");
            Cdx.prop(store, "kind", "trust-store");
            Cdx.prop(store, "certificates", String.valueOf(caCertificates));
            // 位置固定寫 image:/etc/pki/ca-trust（代表「系統的信任庫」，不是每張憑證實際的路徑）
            Cdx.occurrence(store, "image:/etc/pki/ca-trust", caCertificates + " 張 CA 憑證，不逐張列出");
            Cdx.add(bom, store);
        }
    }

    /**
     * 映像裡的路徑 → 位置。前面加「image:」，路徑一律以 / 開頭。
     * 例：「etc/ssl/openssl.cnf」→「image:/etc/ssl/openssl.cnf」；「/app/keys/tls.key」→「image:/app/keys/tls.key」。
     */
    private static String imageLocation(String path) {
        if (path.startsWith("/")) {
            return "image:" + path;
        }
        return "image:/" + path;
    }

    /**
     * theia 的 OpenSSL 設定檔元件 → 我們的 file 元件「OpenSSL 設定 檔名」（cbom:kind=openssl-config）。
     * theia 把設定寫成「theia:openssl:名稱」的屬性，這裡改成「cbom:setting:openssl.名稱」，其他屬性不抄。
     * 例：theia:openssl:MinProtocol = TLSv1.2 → cbom:setting:openssl.MinProtocol = TLSv1.2。
     */
    private static void opensslConfig(ObjectNode bom, JsonNode component, List<String> locations) {
        String first = locations.get(0);
        ObjectNode file = Cdx.plain("file", "OpenSSL 設定 " + first.substring(first.lastIndexOf('/') + 1), "openssl-config|" + first);
        Cdx.prop(file, "source", "image-scan");
        Cdx.prop(file, "kind", "openssl-config");
        String theiaPrefix = "theia:openssl:";
        for (JsonNode property : component.path("properties")) {
            String name = property.path("name").asText();
            if (name.startsWith(theiaPrefix)) {
                Cdx.prop(file, "setting:openssl." + name.substring(theiaPrefix.length()), property.path("value").asText());
            }
        }
        for (String location : locations) {
            Cdx.occurrence(file, imageLocation(location), "");
        }
        Cdx.add(bom, file);
    }

    /**
     * 把一個參照欄位換成新的 bom-ref；對不到新的（它指的元件不在這份 CBOM 裡）就把欄位拿掉，免得留下指不到東西的參照。
     * 例：remap(certificate, "subjectPublicKeyRef", newRef)。
     */
    private static void remap(ObjectNode node, String field, Map<String, String> newRef) {
        String mapped = newRef.get(node.path(field).asText());
        if (mapped != null) {
            node.put(field, mapped);
        } else {
            node.remove(field);
        }
    }
}
