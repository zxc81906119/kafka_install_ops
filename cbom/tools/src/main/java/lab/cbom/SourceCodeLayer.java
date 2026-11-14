package lab.cbom;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 原始碼層：把原始碼掃描工具（cbomkit-action，引擎是 sonar-cryptography）的 CBOM 整理成這邊的格式。
 *
 * 原料：raw/shared/source/cbom.json（沒有這個檔就沒有這一層；Confluent Platform 沒有原始碼，所以平台的盤點不會有）。
 *
 * 產出（屬性 cbom:source 都是 source-code）：
 *   algorithm 元件                程式裡呼叫的演算法，位置是「原始碼檔:行號」，說明是呼叫的 API
 *   related-crypto-material 元件  程式裡產生或設定的金鑰、salt（掃描工具只知道種類與長度）
 * 掃描工具給的其他種類（protocol 等）不收。
 * 誰呼叫：Main（經 Layers）；只有 WebAppProfile 用這一層。
 *
 * 掃描工具用亂數當 bom-ref，金鑰的名稱也帶亂數（key@亂數）；這裡改成由內容算，同一個演算法只留一筆、位置累加。
 */
final class SourceCodeLayer implements Layer {

    @Override
    public String id() {
        return "source";
    }

    @Override
    public String title() {
        return "原始碼掃描（cbomkit-action）";
    }

    @Override
    public ObjectNode convert(Raw raw) throws IOException {
        return run(raw);
    }

    /** 讀掃描工具的 CBOM，依每個元件的 assetType 分給 algorithm() 或 material()；其他種類略過。 */
    static ObjectNode run(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        Path file = raw.shared().resolve("source").resolve("cbom.json");
        if (!Files.isRegularFile(file)) {
            return bom;
        }
        for (JsonNode component : Cdx.read(file).path("components")) {
            JsonNode crypto = component.path("cryptoProperties");
            String assetType = crypto.path("assetType").asText();
            if ("algorithm".equals(assetType)) {
                algorithm(bom, component);
            } else if ("related-crypto-material".equals(assetType)) {
                material(bom, component);
            }
        }
        return bom;
    }

    /**
     * 掃描工具的一個演算法元件 → 我們的 algorithm 元件。同名的演算法併成一筆（身分是「source|名稱」）。
     * 例：名稱「AES128-GCM」→ 家族 AES、keySize 128；名稱「RSA-OAEP」、參數 2048 → 家族 RSA、keySize 2048（從參數補）。
     */
    private static void algorithm(ObjectNode bom, JsonNode original) {
        String name = original.path("name").asText();
        ObjectNode algorithm = Cdx.asset("algorithm", name, "source|" + name);
        // 掃描工具給的細節（primitive、mode、padding、參數、OID）照留
        ObjectNode crypto = (ObjectNode) algorithm.get("cryptoProperties");
        JsonNode properties = original.path("cryptoProperties").path("algorithmProperties");
        if (properties.isObject()) {
            crypto.set("algorithmProperties", properties.deepCopy());
        }
        JsonNode oid = original.path("cryptoProperties").path("oid");
        if (oid.isTextual()) {
            crypto.put("oid", oid.asText());
        }
        // 補上家族、長度、雜湊（掃描工具已經給了 primitive 的話，Algo.apply 不會蓋掉它）
        Algo.apply(algorithm, name);
        // 名稱裡沒有長度時（例如 FFDH、RSA-OAEP），用掃描工具從程式讀到的參數；只信 RSA 與 DH 的（它給橢圓曲線的數字不是曲線長度）
        // 參數要剛好是 3 到 5 位的數字（\d{3,5}，例：2048）才用
        String family = Cdx.prop(algorithm, "family");
        String parameter = properties.path("parameterSetIdentifier").asText("");
        if (Cdx.prop(algorithm, "keySize") == null && ("RSA".equals(family) || "DH".equals(family)) && parameter.matches("\\d{3,5}")) {
            Cdx.prop(algorithm, "keySize", parameter);
        }
        Cdx.prop(algorithm, "source", "source-code");
        Cdx.prop(algorithm, "use", "原始碼裡呼叫");
        occurrences(algorithm, original);
        Cdx.add(bom, algorithm);
    }

    /**
     * 掃描工具的一個金鑰材料元件（金鑰、salt、IV…）→ 我們的 related-crypto-material 元件。
     * 同種類、同名、同長度的併成一筆（身分是「source|種類|名稱|長度」）。長度是 0（不知道）就不寫 size 與 cbom:keySize。
     */
    private static void material(ObjectNode bom, JsonNode original) {
        JsonNode properties = original.path("cryptoProperties").path("relatedCryptoMaterialProperties");
        String type = properties.path("type").asText("unknown");
        int size = properties.path("size").asInt(0);
        // 名稱去掉亂數：key@3acde249-… → key。regex：@ 後面剛好 36 個十六進位字或減號（UUID 的長度），而且在結尾
        String name = original.path("name").asText().replaceAll("@[0-9a-f-]{36}$", "");
        ObjectNode material = Cdx.asset("related-crypto-material", name, "source|" + type + "|" + name + "|" + size);
        ObjectNode target = Cdx.crypto(material, "relatedCryptoMaterialProperties");
        target.put("type", type);
        if (size > 0) {
            target.put("size", size);
            Cdx.prop(material, "keySize", String.valueOf(size));
        }
        Cdx.prop(material, "source", "source-code");
        Cdx.prop(material, "use", "原始碼裡產生或設定");
        occurrences(material, original);
        Cdx.add(bom, material);
    }

    /**
     * 把掃描工具記的出現位置抄過來。位置寫成「src:路徑:行號」；路徑去掉掃描時的工作目錄名稱。
     * 例：location「workspace/src/main/java/demo/Crypto.java」、line 42 →「src:src/main/java/demo/Crypto.java:42」。
     * 沒有行號時行號寫 0。
     */
    private static void occurrences(ObjectNode component, JsonNode original) {
        for (JsonNode occurrence : original.path("evidence").path("occurrences")) {
            // 反斜線換成斜線（Windows 的路徑），再去掉開頭的「workspace/」
            String path = occurrence.path("location").asText().replace('\\', '/').replaceFirst("^workspace/", "");
            String location = "src:" + path + ":" + occurrence.path("line").asInt(0);
            Cdx.occurrence(component, location, occurrence.path("additionalContext").asText(""));
        }
    }
}
