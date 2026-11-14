package lab.cbom;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;

import com.fasterxml.jackson.databind.JsonNode;

/**
 * 對答案：拿一份「標準答案」（這個對象實際用到的密碼學資產清單）去對 CBOM 與判定結果，
 * 看每一項有沒有找到、判的等級和預期的一不一樣。這是量測，不是關卡：結果不影響結束碼。
 *
 * <pre>
 * java -jar cbom-tools.jar check-inventory &lt;cbom.json&gt; &lt;findings.json&gt; &lt;expected-inventory.json&gt; &lt;輸出.txt&gt;
 * </pre>
 * 輸入：
 *   cbom.json                 cbom-tools build 的輸出
 *   findings.json             opa eval 'data.cbom.report' 的輸出
 *   expected-inventory.json   標準答案（teaching web app 的在 cbom/app/expected-inventory.json）
 * 輸出：一份文字（寫到檔案，也印到畫面）。第一行是摘要，接著只列有問題的項目。
 * 誰呼叫：Main 的 check-inventory 子指令。
 *
 * 標準答案的一項（用得到的欄位）：
 * <pre>
 * { "id": "SYM-AES-ECB", "description": "[壞例子·故意] AES/ECB",
 *   "match": "AES.*ECB",            必填。regex，不分大小寫，比元件的名稱（只要名稱裡有一段符合就算）
 *   "kind": "crypto",               選填。比哪一種元件、比什麼（見下表）；沒寫是 crypto
 *   "assetType": "algorithm",       選填。有寫的話元件的 assetType 要相同（kind 是 library 時不看）
 *   "locationMatch": "Sym\\.java",  選填。regex，元件要有一個位置符合（kind 是 library 時不看）
 *   "expectedLevel": "violation" }  選填。預期的等級；not-detectable = 工具本來就看不到，預期找不到；
 *                                   沒寫 = 沒有預期，只報有沒有找到
 * </pre>
 * kind 決定怎麼比：
 * <pre>
 *   crypto（預設）  只看密碼學資產（type 是 cryptographic-asset）；比名稱
 *   any             每一種元件都看；比名稱，也比位置
 *   library         比 purl 整理後的「group:artifact」，或名稱
 *                   purl 的整理：去掉開頭的 pkg:maven/ 與 @ 之後的版本，第一個 / 換成 :
 *                   例：pkg:maven/org.bouncycastle/bcprov-jdk18on@1.78 → org.bouncycastle:bcprov-jdk18on
 * </pre>
 * 「名稱」＝元件的 name；協定元件另外加上它每個 cipher suite 的名稱與 tlsGroups（所以 TLS 的群組、cipher suite 也對得到）。
 * 「位置」＝屬性 cbom:callSite 的每個值，加上每個出現位置的「location 空白 additionalContext」。
 *
 * 一項的結果：
 * <pre>
 *   沒找到   沒有任何元件符合
 *   找到     實際等級 = 符合的那些元件在判定結果裡最重的等級（順序同報告：violation 最重 … info 最輕）；
 *            符合的元件都沒有任何 finding 時當成 info
 * </pre>
 */
final class InventoryCheck {

    /** 預期等級的特殊值：工具本來就看不到這一項，預期找不到。 */
    private static final String NOT_DETECTABLE = "not-detectable";

    /** 一項的比對結果。expected 是標準答案寫的 expectedLevel（沒寫是空字串）；actual 是實際等級（沒找到是 null）。 */
    record Result(String id, String description, String expected, boolean found, String actual) {
    }

    private InventoryCheck() {
    }

    /** check-inventory 子指令：讀三個檔、比對、把結果寫到 output 並印到畫面。檔案讀不到或格式不對丟例外（結束碼非 0）。 */
    static void run(Path cbomFile, Path findingsFile, Path inventoryFile, Path output) throws IOException {
        JsonNode cbom = Cdx.read(cbomFile);
        JsonNode report = ReportCommand.unwrap(Cdx.read(findingsFile));
        JsonNode inventory = Cdx.read(inventoryFile);
        if (!inventory.path("items").isArray()) {
            throw new IOException("標準答案檔沒有 items 陣列：" + inventoryFile);
        }
        String text = summary(compare(cbom, report, inventory));
        if (output.toAbsolutePath().getParent() != null) {
            Files.createDirectories(output.toAbsolutePath().getParent());
        }
        Files.writeString(output, text, StandardCharsets.UTF_8);
        System.out.print(text);
    }

    /** 標準答案的每一項各比一次，照標準答案的順序回傳結果。 */
    static List<Result> compare(JsonNode cbom, JsonNode report, JsonNode inventory) throws IOException {
        List<Result> results = new ArrayList<>();
        for (JsonNode item : inventory.path("items")) {
            String id = item.path("id").asText();
            Pattern match = pattern(id, "match", item.path("match").asText());
            Pattern where = null;
            if (!item.path("locationMatch").asText("").isEmpty()) {
                where = pattern(id, "locationMatch", item.path("locationMatch").asText());
            }
            // 符合這一項的元件的 bom-ref
            List<String> refs = new ArrayList<>();
            for (JsonNode component : cbom.path("components")) {
                if (matches(item, match, where, component)) {
                    refs.add(component.path("bom-ref").asText());
                }
            }
            String actual = null;
            if (!refs.isEmpty()) {
                actual = worstLevel(report, refs);
            }
            results.add(new Result(id, item.path("description").asText(), item.path("expectedLevel").asText(""),
                !refs.isEmpty(), actual));
        }
        return results;
    }

    /** 把標準答案裡的 regex 編譯好（不分大小寫）；寫錯了就丟例外，訊息指出是哪一項的哪個欄位。 */
    private static Pattern pattern(String id, String field, String regex) throws IOException {
        if (regex.isEmpty()) {
            throw new IOException("標準答案的 " + id + " 沒有 " + field);
        }
        try {
            return Pattern.compile(regex, Pattern.CASE_INSENSITIVE);
        } catch (PatternSyntaxException e) {
            throw new IOException("標準答案的 " + id + " 的 " + field + " 不是合法的 regex：" + e.getMessage());
        }
    }

    /** 這個元件符不符合這一項（怎麼比見檔頭的 kind 表）。 */
    static boolean matches(JsonNode item, Pattern match, Pattern where, JsonNode component) {
        String kind = item.path("kind").asText("crypto");
        if ("library".equals(kind)) {
            String coordinates = component.path("purl").asText("")
                .replaceFirst("^pkg:maven/", "").replaceFirst("@.*$", "").replaceFirst("/", ":");
            return match.matcher(coordinates).find() || match.matcher(component.path("name").asText("")).find();
        }
        if ("crypto".equals(kind) && !"cryptographic-asset".equals(component.path("type").asText())) {
            return false;
        }
        String assetType = item.path("assetType").asText("");
        if (!assetType.isEmpty() && !assetType.equals(component.path("cryptoProperties").path("assetType").asText())) {
            return false;
        }
        List<String> candidates = names(component);
        if ("any".equals(kind)) {
            candidates.addAll(locations(component));
        }
        if (!anyMatch(match, candidates)) {
            return false;
        }
        return where == null || anyMatch(where, locations(component));
    }

    /** 清單裡有沒有任何一個字串符合 regex（字串裡有一段符合就算）。 */
    private static boolean anyMatch(Pattern pattern, List<String> texts) {
        for (String text : texts) {
            if (pattern.matcher(text).find()) {
                return true;
            }
        }
        return false;
    }

    /** 元件的「名稱」：name；協定元件再加每個 cipher suite 的名稱與它的 tlsGroups。 */
    private static List<String> names(JsonNode component) {
        List<String> names = new ArrayList<>();
        names.add(component.path("name").asText(""));
        for (JsonNode suite : component.path("cryptoProperties").path("protocolProperties").path("cipherSuites")) {
            names.add(suite.path("name").asText(""));
            for (JsonNode group : suite.path("tlsGroups")) {
                names.add(group.asText());
            }
        }
        return names;
    }

    /** 元件的「位置」：屬性 cbom:callSite 的每個值，加上每個出現位置的「location 空白 additionalContext」。 */
    private static List<String> locations(JsonNode component) {
        List<String> locations = new ArrayList<>();
        for (JsonNode property : component.path("properties")) {
            if (property.path("name").asText().equals(Cdx.PREFIX + "callSite")) {
                locations.add(property.path("value").asText());
            }
        }
        for (JsonNode occurrence : component.path("evidence").path("occurrences")) {
            locations.add(occurrence.path("location").asText("") + " " + occurrence.path("additionalContext").asText(""));
        }
        return locations;
    }

    /** 這些元件在判定結果裡最重的等級（ReportCommand.LEVELS 裡位置最前面的）；都沒有 finding 回 info。 */
    private static String worstLevel(JsonNode report, List<String> refs) {
        String worst = "info";
        for (JsonNode finding : report.path("findings")) {
            if (!refs.contains(finding.path("bom-ref").asText())) {
                continue;
            }
            int level = ReportCommand.LEVELS.indexOf(finding.path("level").asText());
            // 不認得的等級（-1）不算
            if (level >= 0 && level < ReportCommand.LEVELS.indexOf(worst)) {
                worst = finding.path("level").asText();
            }
        }
        return worst;
    }

    /**
     * 結果 → 要輸出的文字。第一行摘要，之後三段只列有問題的（那一段沒有項目就不印）；都沒有問題時印「沒有要看的項目。」。
     * <pre>
     * 標準答案 49 項：找到 44 項；沒找到 5 項（其中預期看不到的 3 項）；等級相符 40 項、不符 2 項
     *
     * 沒找到（不是預期看不到的）：2 項
     *   SYM-XYZ  說明…
     *
     * 預期看不到卻找到了：1 項
     *   PWD-BCRYPT  說明…（實際等級 info）
     *
     * 等級不符：2 項
     *   SYM-AES-ECB  說明…（預期 violation、實際 pass）
     * </pre>
     * 等級相符與不符只算「有寫預期等級而且找到」的項目；沒寫 expectedLevel 的項目只算在找到或沒找到裡。
     */
    static String summary(List<Result> results) {
        List<String> missing = new ArrayList<>();
        List<String> unexpectedlyFound = new ArrayList<>();
        List<String> wrongLevel = new ArrayList<>();
        int found = 0;
        int notFound = 0;
        int notFoundAsExpected = 0;
        int sameLevel = 0;
        for (Result result : results) {
            String line = "  " + result.id() + "  " + result.description();
            boolean expectedInvisible = NOT_DETECTABLE.equals(result.expected());
            if (!result.found()) {
                notFound++;
                if (expectedInvisible) {
                    notFoundAsExpected++;
                } else {
                    missing.add(line);
                }
                continue;
            }
            found++;
            if (expectedInvisible) {
                unexpectedlyFound.add(line + "（實際等級 " + result.actual() + "）");
            } else if (result.expected().isEmpty()) {
                // 沒有預期等級：只算找到
                continue;
            } else if (result.expected().equals(result.actual())) {
                sameLevel++;
            } else {
                wrongLevel.add(line + "（預期 " + result.expected() + "、實際 " + result.actual() + "）");
            }
        }

        StringBuilder text = new StringBuilder();
        text.append("標準答案 ").append(results.size()).append(" 項：找到 ").append(found).append(" 項；沒找到 ")
            .append(notFound).append(" 項（其中預期看不到的 ").append(notFoundAsExpected).append(" 項）；等級相符 ")
            .append(sameLevel).append(" 項、不符 ").append(wrongLevel.size()).append(" 項\n");
        section(text, "沒找到（不是預期看不到的）", missing);
        section(text, "預期看不到卻找到了", unexpectedlyFound);
        section(text, "等級不符", wrongLevel);
        if (missing.isEmpty() && unexpectedlyFound.isEmpty() && wrongLevel.isEmpty()) {
            text.append("\n沒有要看的項目。\n");
        }
        return text.toString();
    }

    /** 一段：空一行、標題與項數、每項一行；沒有項目就不印。 */
    private static void section(StringBuilder text, String title, List<String> lines) {
        if (lines.isEmpty()) {
            return;
        }
        text.append("\n").append(title).append("：").append(lines.size()).append(" 項\n");
        for (String line : lines) {
            text.append(line).append("\n");
        }
    }
}
