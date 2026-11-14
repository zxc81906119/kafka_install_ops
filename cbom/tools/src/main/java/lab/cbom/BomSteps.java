package lab.cbom;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
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
 * 各層併在一起之後要做的事，一步一個 BomStep，照 PIPELINE 的順序做（Pipes and Filters）。
 *
 * 輸入：MergeCommand.merge 併好的 BOM（只有 components 與 dependencies）。
 * 輸出：完整的 CBOM（每個元件標了範圍、排好順序、有 metadata、通過 schema 驗證、有編號）。
 * 誰呼叫：MergeCommand.run 照 PIPELINE 一步一步做；Main 的 crypto-only 另外單獨呼叫 serialNumber。
 *
 * 順序是：COMPLETENESS（盤點完整性）→ SCOPE（標範圍）→ SORT（排序）→ METADATA → VALIDATE（驗證 1.7）→ SPEC_VERSION（要 1.6 才轉）→ SERIAL（編號）。
 * 順序的理由：驗證要等內容都齊了才做；編號由整份內容算出來，所以放最後（也就是說 serialNumber 本身沒有經過 VALIDATE）。
 *
 * 要加一步（例如遮掉某些欄位）就寫一個 BomStep 放進 PIPELINE，不用動別的步驟。
 */
final class BomSteps {

    private BomSteps() {
    }

    /** 每個元件標上它在哪些主機、哪些元件（報告與規則用）。 */
    static final BomStep SCOPE = (bom, context) -> {
        for (JsonNode component : bom.path("components")) {
            scope((ObjectNode) component, context.raw());
        }
        return bom;
    };

    /** 元件照種類、名稱排序：同樣的原料每次產出相同的檔。 */
    static final BomStep SORT = (bom, context) -> {
        sortComponents(bom);
        return bom;
    };

    /** 這次盤點的時間、工具、對象、範圍。 */
    static final BomStep METADATA = (bom, context) -> {
        metadata(bom, context.raw(), context.profile());
        return bom;
    };

    /** 用 CycloneDX 官方的 1.7 schema 驗證。 */
    static final BomStep VALIDATE = (bom, context) -> {
        validate(bom);
        return bom;
    };

    /** 要 1.6 時由官方函式庫轉（1.7 才有的欄位會被拿掉，金鑰交換群組另外留在屬性裡）。 */
    static final BomStep SPEC_VERSION = (bom, context) -> specVersion(bom, context.specVersion());

    /** 這份 CBOM 的編號（serialNumber）。CBOMkit 的網頁沒有這個欄位就不顯示（2.3.0 實測）。 */
    static final BomStep SERIAL = (bom, context) -> {
        serialNumber(bom);
        return bom;
    };

    /**
     * 盤點完整性：依原料算出「該有而沒有的」，做成一個元件加進來（CollectionCheck）。
     * 放第一步：它要被標範圍、排序、驗證，和其他元件一樣。
     */
    static final BomStep COMPLETENESS = (bom, context) -> {
        List<String> gaps = context.profile().collectionGaps(context.raw(), bom);
        Cdx.add(bom, CollectionCheck.component(gaps));
        return bom;
    };

    static final List<BomStep> PIPELINE = List.of(COMPLETENESS, SCOPE, SORT, METADATA, VALIDATE, SPEC_VERSION, SERIAL);

    /**
     * 編號由內容算出來（name-based UUID）：同樣的原料每次產出相同的檔，內容不同編號就不同。
     * 內容改過之後（例如只留密碼學資產）要再算一次。
     * 結果的樣子：「urn:uuid:」加一個 UUID。先把舊的編號拿掉再算，否則舊編號也會被算進內容。
     */
    static void serialNumber(ObjectNode bom) throws IOException {
        bom.remove("serialNumber");
        byte[] content = Cdx.JSON.writeValueAsBytes(bom);
        bom.put("serialNumber", "urn:uuid:" + java.util.UUID.nameUUIDFromBytes(content));
    }

    /**
     * 從出現位置算出這個資產在哪些主機、哪些元件，寫成屬性 cbom:hosts 與 cbom:roles（報告與規則用）。
     *
     * 判斷方法：位置的第一段（第一個冒號或句點之前）是不是 collect.env 的 HOSTS 裡的主機名稱。
     * <pre>
     *   kb01.poc.lab:9092              → 第一段 kb01，是主機 → hosts 加 kb01，roles 加它的元件（broker）
     *   kb01:/etc/kafka/server.properties → 第一段 kb01，同上
     *   ops02:~/pki/certs/ca.crt       → 第一段 ops02，不在 HOSTS 裡 → roles 加 shared（平台共用）
     *   叢集的 SCRAM 帳號              → 沒有冒號也沒有句點，整串都不是主機 → shared
     * </pre>
     * 結果例：cbom:hosts =「kb01 kb02」、cbom:roles =「broker shared」（各自排序、空白分隔）。
     * 沒有任何一個位置是主機時不寫 cbom:hosts；完全沒有出現位置的元件，cbom:roles 是空字串。
     */
    static void scope(ObjectNode component, Raw raw) {
        TreeSet<String> hosts = new TreeSet<>();
        TreeSet<String> roles = new TreeSet<>();
        for (JsonNode occurrence : component.path("evidence").path("occurrences")) {
            String location = occurrence.path("location").asText();
            // 切成最多兩段，只要第一段。[:.] = 冒號或句點
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

    /** 把 components 照 sortKey 重新排好（字串由小到大）。 */
    private static void sortComponents(ObjectNode bom) {
        List<JsonNode> components = new ArrayList<>();
        bom.path("components").forEach(components::add);
        components.sort(Comparator.comparing(BomSteps::sortKey));
        ArrayNode sorted = bom.putArray("components");
        components.forEach(sorted::add);
    }

    /**
     * 排序用的字串：種類|名稱|bom-ref。例：「certificate|CN=kb01.poc.lab|certificate:3f2a9c0d1e4b5a67」。
     * 種類：密碼學資產看 assetType（algorithm、certificate…），其他元件看 type（file、library）。
     * 最後加 bom-ref 是為了同種類又同名的元件也有固定的先後。
     */
    private static String sortKey(JsonNode component) {
        String kind = component.path("cryptoProperties").path("assetType").asText(component.path("type").asText());
        return kind + "|" + component.path("name").asText() + "|" + component.path("bom-ref").asText();
    }

    /**
     * 寫 metadata：盤點時間、用了哪些工具、這份 CBOM 講的是誰、這次的範圍。資料都來自 collect.env。
     *
     * TOOLS 的格式是「名稱 版本, 名稱 版本, …」，例：「cbom-tools 1.0.0, testssl.sh 3.2, syft 1.18.1」
     * → 三個工具元件；只有名稱沒有版本的就不寫 version。
     *
     * 範圍寫成「cbom:」開頭的屬性（報告的開頭讀這幾個）：
     * <pre>
     *   cbom:scope            full（ROLES 涵蓋了 ALL_ROLES）或 partial
     *   cbom:roles            這次選了哪些元件
     *   cbom:allRoles         全部有哪些元件
     *   cbom:hosts            「主機:元件」的清單
     *   cbom:runtimeEvidence  none（沒有錄 JFR），或「JFR 300 秒」
     *   cbom:profile          盤點對象：cp 或 webapp（報告用它決定「這份盤點看不到什麼」那一節的內容）
     * </pre>
     */
    static void metadata(ObjectNode bom, Raw raw, Profile profile) {
        ObjectNode metadata = bom.putObject("metadata");
        metadata.put("timestamp", raw.get("COLLECTED_AT"));
        ObjectNode tools = metadata.putObject("tools");
        ArrayNode toolComponents = tools.putArray("components");
        // 先用逗號切出每個工具，再用第一段空白切成「名稱」與「版本」
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
        // 這份 CBOM 講的是誰，由盤點對象決定
        profile.subject(metadata.putObject("component"), raw);
        ArrayNode properties = metadata.putArray("properties");
        property(properties, "scope", raw.fullScope() ? "full" : "partial");
        property(properties, "roles", raw.get("ROLES"));
        property(properties, "allRoles", raw.get("ALL_ROLES"));
        property(properties, "hosts", raw.get("HOSTS"));
        // JFR_SECONDS 是空的 = 這次沒有錄執行期證據
        property(properties, "runtimeEvidence", raw.get("JFR_SECONDS").isEmpty() ? "none" : "JFR " + raw.get("JFR_SECONDS") + " 秒");
        property(properties, "profile", profile.id());
    }

    /** 在 metadata 的 properties 加一筆「cbom:名稱 = 值」（metadata 的屬性不去重複，所以不用 Cdx.prop）。 */
    private static void property(ArrayNode properties, String name, String value) {
        ObjectNode property = properties.addObject();
        property.put("name", Cdx.PREFIX + name);
        property.put("value", value);
    }

    /** 用 CycloneDX 官方函式庫帶的 1.7 schema 驗證；不符合就丟例外，訊息列出前 10 個錯誤（太多列不完）。 */
    static void validate(ObjectNode bom) throws IOException {
        byte[] bytes = Cdx.JSON.writeValueAsBytes(bom);
        List<ParseException> errors = new JsonParser().validate(bytes, Version.VERSION_17);
        if (!errors.isEmpty()) {
            StringBuilder message = new StringBuilder("CBOM 不符合 CycloneDX 1.7 的 schema：");
            errors.stream().limit(10).forEach(e -> message.append("\n  ").append(e.getMessage()));
            throw new IOException(message.toString());
        }
    }

    /**
     * 要輸出的版本是 1.7：原樣回傳。是 1.6：交給官方函式庫讀進來再用 1.6 的格式寫出去，
     * 寫出來的再用 1.6 的 schema 驗一次，回傳轉好的那一份（是新的物件）。其他版本：丟例外。
     */
    static ObjectNode specVersion(ObjectNode bom, String specVersion) throws IOException {
        if ("1.7".equals(specVersion)) {
            return bom;
        }
        if (!"1.6".equals(specVersion)) {
            throw new IOException("只支援 1.7 與 1.6，不是 " + specVersion);
        }
        try {
            byte[] bytes = Cdx.JSON.writeValueAsBytes(bom);
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
