package lab.cbom;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

import com.fasterxml.jackson.databind.JsonNode;

/**
 * 把 CBOM 與 OPA 的判斷結果做成一頁 HTML 報告（不用 JavaScript、不連外，可以直接存檔或列印）。
 *
 * 兩種輸出：預設是單一檔（樣式寫在 HTML 裡），下載、寄送都方便；加 --external-css 時樣式另外寫成同目錄的 report.css。
 * 後者是給 Jenkins 的 HTML Publisher 用的：Jenkins 預設的安全設定（Content-Security-Policy）不允許寫在 HTML 裡的樣式，
 * 只允許同一個位置的樣式檔。
 *
 * 輸入：
 *   cbom.json       cbom-tools build 的輸出
 *   findings.json   opa eval --format json 'data.cbom.report' 的輸出（外面包的 result／expressions 會自動拆掉）
 * 報告的內容：這次的範圍、各等級的數量、PQC 的重點數字、每個等級的明細（同名同原因的併成一列，列出出現位置）。
 * 誰呼叫：Main 的 report 子指令（cbom/cbom-report.sh 與 Jenkins 的 pipeline 都經過它）。
 *
 * 這裡<b>不做合規判斷</b>：每個元件判成哪一級、原因是什麼，都是 OPA 的規則（cbom/policy/cbom.rego）決定的，
 * 這裡只負責把結果排成一頁。findings.json 裡一筆發現的樣子：
 * <pre>
 *   { "bom-ref": "algorithm:3f2a9c0d1e4b5a67", "level": "violation", "rule": "broken-algorithm",
 *     "reason": "MD5 已不安全，不可再用", "basis": "NIST SP 800-131A Rev.2" }
 * </pre>
 *
 * 一頁報告由上到下，各由哪個方法產生：
 * <pre>
 *   標題、範圍、合不合規、六個等級的數字方塊    header()
 *   「後量子遷移的重點」那張表                    highlights()
 *   盤點完整性（完整／有幾個缺口）                completeness()（在 header 的最後）
 *   六個等級各一節（一張明細表）                  section()，每個等級呼叫一次
 *   這份盤點看不到什麼                            blindSpots()；文字在各 Profile 的 blindSpots()
 *   頁尾                                          page() 的最後
 *   樣式                                          最下面的 CSS
 * </pre>
 * render() 先把元件分組成「列」（groupRows），再交給 page() 排成 HTML。
 *
 * 要改報告時改哪裡：
 * <pre>
 *   等級的中文名稱（違規、量子脆弱…）            LEVEL_LABEL
 *   等級標題下面那一行說明                        LEVEL_NOTE
 *   等級的先後、哪個比較重                        LEVELS（由重到輕；要和 cbom.rego 的六個等級一致）
 *   多一個等級                                    LEVELS、LEVEL_LABEL、LEVEL_NOTE 各加一筆，CSS 加它的顏色
 *                                                 （--名稱 變數、h2.名稱、.tile.名稱 b），規則也要會產生它
 *   「類型」欄的中文（憑證、金鑰…）              TYPE_LABEL；類型在表裡的先後是 TYPE_ORDER
 *   元件（controller、broker…）的顯示名稱        ROLE_LABEL
 *   「資產」欄顯示的名稱                          displayName()
 *   「資產」欄下面那行灰字「來源：…」            sourceLabel()（新的 Layer 用了新的來源名稱時在這裡加）
 *   明細表多一欄、少一欄                          section()：表頭那一行與每一列各加一格；
 *                                                 新欄位的資料要先在 Row 加欄位、在 groupRows() 填進去；欄寬在 CSS 的 th:nth-child
 *   哪些元件併成同一列                            groupRows() 裡的 key
 *   「後量子遷移的重點」多一項、改文字            highlights()（一項就是一個 fact(…)）
 *   最上面的標題、範圍、合規結論的文字            header()
 *   頁尾的依據                                    page() 的最後
 *   顏色、字體、欄寬                              CSS
 *   一格最多直接列幾個出現位置                    LOCATIONS_SHOWN
 * </pre>
 * 改完一定要跑 bash cbom/build.sh 與 bash cbom/golden.sh check：報告的文字只要動一個字，
 * cp-report.html、web-report.html 就會「不同」；確定是要改的才 bash cbom/golden.sh rebase。
 * 文字要放進 HTML 之前都要經過 esc()（把 &lt; &gt; &amp; 換掉），除非是這個檔裡自己寫死的字。
 */
final class ReportCommand {

    /**
     * 等級由重到輕；一個元件有多筆 finding 時取最重的當它的等級。
     * 位置愈前面愈重（violation 是第 0 個）。報告的方塊與各節也照這個順序排。
     */
    static final List<String> LEVELS = List.of("violation", "quantum-vulnerable", "warning", "unknown", "pass", "info");

    /**
     * 等級 → 報告上的中文名稱。用詞和 cbom/policy/cbom.rego 檔頭的等級表相同；要改就兩邊一起改。
     */
    private static final Map<String, String> LEVEL_LABEL = Map.of(
        "violation", "違規", "quantum-vulnerable", "量子脆弱", "warning", "警告",
        "unknown", "無法判斷", "pass", "通過", "info", "資訊");

    /**
     * 等級 → 那一節標題下面的一行說明。內容和 cbom/policy/cbom.rego 檔頭的等級表對齊（violation 舉的例子就是那裡列的幾種）；
     * 要改就兩邊一起改。
     */
    private static final Map<String, String> LEVEL_NOTE = Map.of(
        "violation", "現在就不合格，和量子電腦無關：已破解的演算法、太短的金鑰、舊的 TLS、過期的憑證、寫死的金鑰。",
        "quantum-vulnerable", "現在安全，但量子電腦可破解。NIST IR 8547：2030 年後棄用、2035 年後禁用，要排進遷移計畫。",
        "warning", "建議改善，不影響合規結果。",
        "unknown", "規則不認得，要人看；看過後補規則。",
        "pass", "符合規則。",
        "info", "只是盤點，沒有合規判斷（例如帶了哪些密碼函式庫）。");

    /** 元件的種類（密碼學資產的 assetType，或一般元件的 type）→「類型」欄的中文。沒列在這裡的種類直接印英文。 */
    private static final Map<String, String> TYPE_LABEL = Map.of(
        "certificate", "憑證", "related-crypto-material", "金鑰", "algorithm", "演算法",
        "protocol", "協定", "file", "設定與金鑰檔", "library", "密碼函式庫", "data", "盤點檢查");

    /** 明細表裡種類的先後：憑證最前面，函式庫最後。 */
    private static final List<String> TYPE_ORDER =
        List.of("certificate", "related-crypto-material", "protocol", "algorithm", "file", "library");

    /** 一格「出現位置」最多直接列幾個；超過的收在「共 N 處」裡，點開才看得到。 */
    private static final int LOCATIONS_SHOWN = 3;

    /** 元件（collect.env 的 ROLES 用的字）→ 報告開頭「範圍」那一行的顯示名稱。沒列在這裡的直接印原字。 */
    private static final Map<String, String> ROLE_LABEL = Map.of(
        "controller", "controller", "broker", "broker", "rest", "REST Proxy", "c3", "Control Center", "shared", "平台共用");

    /** 明細表的一列：同一種資產、同樣的判斷，可能代表好幾個元件。用 TreeSet 是為了不重複、順序固定。 */
    private static final class Row {
        /** 種類（certificate、algorithm、file…），顯示時查 TYPE_LABEL。 */
        String type;
        /** 「資產」欄顯示的名稱（displayName 的結果）。 */
        String name;
        /** 這一列的等級（LEVELS 之一），決定它放在哪一節。 */
        String level;
        /** 原因（finding 的 reason）；顯示時用「；」接起來。 */
        final TreeSet<String> reasons = new TreeSet<>();
        /** 依據（finding 的 basis，例如 NIST 的文件名稱）。 */
        final TreeSet<String> basis = new TreeSet<>();
        /** 出現位置（位置＋全形空白＋說明）。 */
        final TreeSet<String> locations = new TreeSet<>();
        /** 來源（sourceLabel 的結果，例如「來源：TLS 掃描」）。 */
        final TreeSet<String> sources = new TreeSet<>();
        /** 這一列代表幾個元件；大於 1 時名稱後面顯示「× N」。 */
        int components;
    }

    private ReportCommand() {
    }

    /**
     * report 子指令：讀兩個檔，寫出報告。externalCss 是 true 時樣式不寫在 HTML 裡，另外寫成同目錄的 report.css
     * （檔名固定，HTML 裡用 href="report.css" 引用）。
     */
    static void run(Path cbomFile, Path findingsFile, Path output, boolean externalCss) throws IOException {
        JsonNode cbom = Cdx.read(cbomFile);
        JsonNode report = unwrap(Cdx.read(findingsFile));
        String html = render(cbom, report, externalCss);
        Path directory = output.toAbsolutePath().getParent();
        Files.createDirectories(directory);
        Files.writeString(output, html, StandardCharsets.UTF_8);
        if (externalCss) {
            Files.writeString(directory.resolve("report.css"), CSS, StandardCharsets.UTF_8);
        }
        System.out.println("報告寫到 " + output);
    }

    /**
     * opa eval 的輸出是 {"result":[{"expressions":[{"value": …}]}]}；拆到 value。
     * 已經是拆好的（最外層就有 findings，例如 OPA 伺服器回的或測試給的）就原樣回傳；兩種都不是就丟例外。
     */
    static JsonNode unwrap(JsonNode json) throws IOException {
        JsonNode value = json.path("result").path(0).path("expressions").path(0).path("value");
        if (!value.isMissingNode()) {
            return value;
        }
        if (json.has("findings")) {
            return json;
        }
        throw new IOException("findings 檔不是 opa eval 'data.cbom.report' 的輸出");
    }

    /** 單一檔的報告（樣式寫在 HTML 裡）。目前只有單元測試直接呼叫這一個。 */
    static String render(JsonNode cbom, JsonNode report) {
        return render(cbom, report, false);
    }

    /**
     * CBOM ＋ 判定結果 → 整頁 HTML（字串）。三步：
     * 1. 元件照 bom-ref 排成表；2. groupRows 把元件分組成明細表的列，同時數每個等級有幾個元件；3. page 排成 HTML。
     */
    static String render(JsonNode cbom, JsonNode report, boolean externalCss) {
        // bom-ref → 元件，順序照 CBOM（BomSteps.SORT 排過的）
        Map<String, JsonNode> components = new LinkedHashMap<>();
        for (JsonNode component : cbom.path("components")) {
            components.put(component.path("bom-ref").asText(), component);
        }
        // 等級 → 元件數；先把六個等級都放 0，報告才會六個都有數字
        Map<String, Integer> componentCounts = new LinkedHashMap<>();
        LEVELS.forEach(level -> componentCounts.put(level, 0));

        Map<String, Row> rows = groupRows(components, report, componentCounts);
        return page(cbom, report, externalCss, components, rows, componentCounts);
    }

    /**
     * 把元件分組成明細表的列，並把每個元件算進它那個等級的數量（componentCounts 會被改）。
     *
     * 每個元件：
     * <pre>
     *   1. 找出它的所有 finding，取最重的等級（worstLevel）。沒有任何 finding 的元件算 info。
     *   2. 只收「和最重等級同級」的原因與依據；較輕的（例如同時也有 pass）不放進這一列。
     *   3. 算出這一列的鍵：等級|種類|顯示名稱|原因。鍵相同的元件併成同一列。
     *      例：四台 broker 各有一個「server.keystore.p12（keystore）」、原因都一樣 → 一列，顯示「× 4」，位置列四個。
     *      名稱相同但原因不同（例如只有一台權限不對）→ 分成兩列。
     * </pre>
     * 回傳：鍵 → 列，順序是每一列第一次出現的順序（顯示時 section() 會再排序）。
     */
    private static Map<String, Row> groupRows(Map<String, JsonNode> components, JsonNode report,
        Map<String, Integer> componentCounts) {
        // bom-ref → 這個元件的 finding
        Map<String, List<JsonNode>> byComponent = new LinkedHashMap<>();
        for (JsonNode finding : report.path("findings")) {
            byComponent.computeIfAbsent(finding.path("bom-ref").asText(), k -> new ArrayList<>()).add(finding);
        }

        Map<String, Row> rows = new LinkedHashMap<>();
        for (Map.Entry<String, JsonNode> entry : components.entrySet()) {
            JsonNode component = entry.getValue();
            List<JsonNode> findings = byComponent.getOrDefault(entry.getKey(), List.of());
            String worst = worstLevel(findings);
            componentCounts.merge(worst, 1, Integer::sum);

            // 種類：密碼學資產看 assetType，其他元件看 type
            String type = component.path("cryptoProperties").path("assetType").asText(component.path("type").asText());
            TreeSet<String> reasons = new TreeSet<>();
            TreeSet<String> basis = new TreeSet<>();
            for (JsonNode finding : findings) {
                // 只列和最重等級同級的原因；較輕的（例如同時也有 pass）不放進這一列
                if (finding.path("level").asText().equals(worst)) {
                    reasons.add(finding.path("reason").asText());
                    if (!finding.path("basis").asText().isEmpty()) {
                        basis.add(finding.path("basis").asText());
                    }
                }
            }
            String name = displayName(component, type);
            // 這個鍵決定「哪些元件併成同一列」；reasons 是排序過的集合，印出來像 [原因一, 原因二]
            String key = worst + "|" + type + "|" + name + "|" + reasons;
            Row row = rows.computeIfAbsent(key, k -> new Row());
            row.type = type;
            row.name = name;
            row.level = worst;
            row.reasons.addAll(reasons);
            row.basis.addAll(basis);
            row.components++;
            String source = Cdx.prop(component, "source");
            if (source != null) {
                row.sources.add(sourceLabel(source));
            }
            for (JsonNode occurrence : component.path("evidence").path("occurrences")) {
                // 位置後面接一個全形空白與說明（有說明才接）。例：「kb01.poc.lab:9092　伺服器支援」
                String context = occurrence.path("additionalContext").asText("");
                row.locations.add(occurrence.path("location").asText() + (context.isEmpty() ? "" : "　" + context));
            }
        }
        return rows;
    }

    /**
     * 一個元件的等級 = 它所有 finding 裡最重的；沒有 finding 回 info（最輕的）。
     * 「比較重」= 在 LEVELS 裡的位置比較前面（數字比較小）。
     * 例：同時有 pass 與 quantum-vulnerable → quantum-vulnerable；同時有 warning 與 violation → violation。
     */
    private static String worstLevel(List<JsonNode> findings) {
        String worst = "info";
        for (JsonNode finding : findings) {
            if (LEVELS.indexOf(finding.path("level").asText()) < LEVELS.indexOf(worst)) {
                worst = finding.path("level").asText();
            }
        }
        return worst;
    }

    /** 排成整頁 HTML：head（標題與樣式）、開頭（header）、重點（highlights）、六個等級各一節（section）、看不到什麼（blindSpots）、頁尾。 */
    private static String page(JsonNode cbom, JsonNode report, boolean externalCss, Map<String, JsonNode> components,
        Map<String, Row> rows, Map<String, Integer> componentCounts) {
        StringBuilder html = new StringBuilder();
        html.append("<!doctype html>\n<html lang=\"zh-Hant\">\n<head>\n<meta charset=\"utf-8\">\n")
            .append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
            .append("<title>密碼學資產合規報告</title>\n");
        // 樣式：另外一個檔（給 Jenkins），或直接寫在這一頁裡
        if (externalCss) {
            html.append("<link rel=\"stylesheet\" href=\"report.css\">\n");
        } else {
            html.append("<style>\n").append(CSS).append("</style>\n");
        }
        html.append("</head>\n<body>\n");

        // 密碼學資產 = type 是 cryptographic-asset 的元件；其餘是 file（設定與金鑰檔）與 library（函式庫）
        int cryptoAssets = 0;
        for (JsonNode component : components.values()) {
            if ("cryptographic-asset".equals(component.path("type").asText())) {
                cryptoAssets++;
            }
        }
        header(html, cbom, report, componentCounts, components.size(), cryptoAssets);
        highlights(html, components);
        for (String level : LEVELS) {
            section(html, level, rows, componentCounts.get(level));
        }
        blindSpots(html, cbom);
        html.append("<footer>判斷規則：cbom/policy/cbom.rego（OPA）。依據：NIST IR 8547、FIPS 203／204／205、")
            .append("NIST SP 800-131A Rev.2、NIST SP 800-52 Rev.2。CBOM 格式：CycloneDX ")
            .append(esc(cbom.path("specVersion").asText())).append("。</footer>\n</body>\n</html>\n");
        return html.toString();
    }

    /**
     * 報告的開頭：標題、盤點對象與時間、範圍（完整或部分）、合規結論、盤點完整性、六個等級的數字方塊。
     * counts 是每個等級的元件數，total 是元件總數，cryptoAssets 是其中密碼學資產的個數。
     *
     * 判斷：
     *   完整或部分盤點：metadata 的 cbom:scope 是 full → 完整；不是 → 部分，並用粗體列出沒有盤到的元件。
     *   合不合規：用判定結果的 compliant 欄位；沒有這個欄位時，沒有任何 violation 就算合規。
     */
    private static void header(StringBuilder html, JsonNode cbom, JsonNode report, Map<String, Integer> counts, int total,
        int cryptoAssets) {
        JsonNode metadata = cbom.path("metadata");
        boolean full = "full".equals(meta(metadata, "scope"));
        boolean compliant = report.path("compliant").asBoolean(counts.get("violation") == 0);

        // 第一行：對象的名稱、版本（有才印）、盤點時間

        html.append("<h1>密碼學資產合規報告</h1>\n");
        html.append("<p class=\"sub\">").append(esc(metadata.path("component").path("name").asText()));
        if (metadata.path("component").has("version")) {
            html.append("　版本 ").append(esc(metadata.path("component").path("version").asText()));
        }
        html.append("　盤點時間 ").append(esc(metadata.path("timestamp").asText())).append("</p>\n");

        // 範圍的方框：部分盤點時 class 是 partial（CSS 會換成黃底），並多一句「沒有盤到…」
        html.append("<div class=\"scope ").append(full ? "full" : "partial").append("\"><strong>")
            .append(full ? "完整盤點" : "部分盤點").append("</strong>　範圍：").append(esc(roles(meta(metadata, "roles"))));
        if (!full) {
            html.append("　<strong>沒有盤到：").append(esc(missingRoles(metadata))).append("</strong>（這份報告不代表整個平台）");
        }
        html.append("<br>主機：").append(esc(hosts(meta(metadata, "hosts"))))
            .append("　執行期證據：").append(esc("none".equals(meta(metadata, "runtimeEvidence")) ? "沒有錄製" : meta(metadata, "runtimeEvidence")))
            .append("</div>\n");

        // 合規結論：class 是 ok（綠）或 bad（紅）
        html.append("<div class=\"verdict ").append(compliant ? "ok" : "bad").append("\">")
            .append(compliant ? "合規：沒有違規項目" : "不合規：有 " + counts.get("violation") + " 個違規項目")
            .append("<span>（量子脆弱與警告不影響這個結果，但要排進遷移計畫）</span></div>\n");

        completeness(html, cbom);

        // 六個數字方塊，每個連到下面那一節（href="#等級"，對應 section() 的 id）
        html.append("<div class=\"tiles\">\n");
        for (String level : LEVELS) {
            html.append("<a class=\"tile ").append(level).append("\" href=\"#").append(level).append("\"><b>")
                .append(counts.get(level)).append("</b>").append(LEVEL_LABEL.get(level)).append("</a>\n");
        }
        // 上面六個方塊的數字加起來是元件總數（file 與 library 也算）；另外寫出其中有幾個是密碼學資產。
        // 例：「共 151 個元件，其中密碼學資產 98 個；…」
        html.append("</div>\n<p class=\"sub\">共 ").append(total).append(" 個元件，其中密碼學資產 ").append(cryptoAssets)
            .append(" 個；數字是元件數（一個元件出現在多台主機只算一次）。</p>\n");
    }

    /**
     * 結論區的「盤點完整性」那一格：這次的原料齊不齊。資料來自 CBOM 裡 cbom:kind 是 collection-check 的那個元件
     * （CollectionCheck 產生的）：沒有缺口印「完整」；有缺口印個數並把每個缺口列出來（黃底）。
     * 舊的 CBOM 沒有這個元件時不印這一格。
     */
    private static void completeness(StringBuilder html, JsonNode cbom) {
        for (JsonNode component : cbom.path("components")) {
            if (!"collection-check".equals(Cdx.prop(component, "kind"))) {
                continue;
            }
            List<String> gaps = new ArrayList<>();
            for (JsonNode property : component.path("properties")) {
                if (property.path("name").asText().equals(Cdx.PREFIX + "gap")) {
                    gaps.add(property.path("value").asText());
                }
            }
            if (gaps.isEmpty()) {
                html.append("<div class=\"scope full\"><strong>盤點完整性：完整</strong>　該有的原料都收到了。</div>\n");
            } else {
                html.append("<div class=\"scope partial\"><strong>盤點完整性：有 ").append(gaps.size())
                    .append(" 個缺口</strong>　下面這些沒有收到，對應的部分這份報告沒有盤到：");
                for (String gap : gaps) {
                    html.append("<br>").append(esc(gap));
                }
                html.append("</div>\n");
            }
            return;
        }
    }

    /**
     * 最後一節「這份盤點看不到什麼」：盤點方法本身的限制（固定文字，由盤點對象提供：Profile.blindSpots）。
     * 是哪一種對象看 metadata 的 cbom:profile；舊的 CBOM 沒有這個屬性時當成 Confluent Platform。
     */
    private static void blindSpots(StringBuilder html, JsonNode cbom) {
        Profile profile = Profile.byId(meta(cbom.path("metadata"), "profile"));
        html.append("<h2>這份盤點看不到什麼</h2>\n")
            .append("<p class=\"sub\">下面這些不在這種盤點方法的範圍裡：報告裡沒有列，不代表沒有。</p>\n<ul>\n");
        for (String line : profile.blindSpots()) {
            html.append("<li>").append(esc(line)).append("</li>\n");
        }
        html.append("</ul>\n");
    }

    /**
     * 「後量子遷移的重點」那張表：後量子遷移最關心的幾個數字，直接從 CBOM 算（不看判定結果）。
     *
     * 怎麼算（端點 = 一個「主機:埠」，也就是 TLS 掃描的 protocol 元件的一個出現位置）：
     * <pre>
     *   TLS 端點                        來源是 tls-scan 的 protocol 元件的所有位置（不重複）
     *   支援後量子混合金鑰交換的端點    元件是 TLS 1.3 而且 cbom:pqcKeyExchange = offered
     *   仍接受 TLS 1.2 的端點           元件是 TLS 1.2
     *   接受 TLS 1.1 以下的端點         元件不是 1.3 也不是 1.2
     *   憑證的金鑰                      每張憑證的 cbom:keyAlgorithm 各有幾張。例：RSA-2048 × 9
     *   最早到期的憑證                  所有憑證的 notValidAfter 裡最早的，只印日期（前 10 個字，例：2027-11-05）
     *   執行期實際用到後量子金鑰交換    來源是 runtime 的演算法元件裡，家族是 ML-KEM-hybrid 的那些的名稱（沒有就寫沒有錄到）
     * </pre>
     * 注意：TLS 1.3 但不支援後量子的端點，不會算進上面第二、三、四項的任何一項（只算在端點總數裡）。
     */
    private static void highlights(StringBuilder html, Map<String, JsonNode> components) {
        Highlights found = collectHighlights(components);
        int endpoints = found.endpoints.size();

        html.append("<h2>後量子遷移的重點</h2>\n<table class=\"facts\">\n");
        fact(html, "TLS 端點（主機:埠）", endpoints + " 個");
        fact(html, "支援後量子混合金鑰交換的端點", found.pqcEndpoints.size() + " / " + endpoints
            + pqcNote(found.pqcEndpoints.size(), endpoints));
        fact(html, "仍接受 TLS 1.2 的端點", found.tls12Endpoints.size() + " / " + endpoints
            + "（TLS 1.2 用不了後量子金鑰交換）");
        fact(html, "接受 TLS 1.1 以下的端點", found.oldTlsEndpoints.size() + " 個");
        // Map 印出來是「{RSA-2048=9, ECDSA=1}」：去掉大括號、等號換成「 × 」→「RSA-2048 × 9, ECDSA × 1」
        fact(html, "憑證的金鑰", found.certificateKeys.toString().replace("{", "").replace("}", "").replace("=", " × ")
            + "（都是量子脆弱的話，身分驗證這一塊要等 CA 支援後量子簽章）");
        if (found.earliestExpiry != null) {
            fact(html, "最早到期的憑證", found.earliestExpiry.substring(0, Math.min(10, found.earliestExpiry.length())));
        }
        // 有錄到就列出實際的名稱（排序後用頓號接）。例：「有（JFR 錄到 X25519MLKEM768）」
        String runtimePqc;
        if (found.runtimePqcNames.isEmpty()) {
            runtimePqc = "沒有錄到，或這次沒有錄製";
        } else {
            runtimePqc = "有（JFR 錄到 " + String.join("、", found.runtimePqcNames) + "）";
        }
        fact(html, "執行期實際用到後量子金鑰交換", runtimePqc);
        html.append("</table>\n");
    }

    /** 「重點」表要用的數字，collectHighlights 把所有元件看過一遍收集起來。 */
    private static final class Highlights {
        /** 四個集合放的都是位置（主機:埠）；用集合是因為同一個端點會出現在好幾個元件。全部的 TLS 端點。 */
        final TreeSet<String> endpoints = new TreeSet<>();
        /** 支援後量子混合金鑰交換的端點。 */
        final TreeSet<String> pqcEndpoints = new TreeSet<>();
        /** 仍接受 TLS 1.2 的端點。 */
        final TreeSet<String> tls12Endpoints = new TreeSet<>();
        /** 接受 TLS 1.1 以下的端點。 */
        final TreeSet<String> oldTlsEndpoints = new TreeSet<>();
        /** 憑證的金鑰演算法 → 幾張，照第一次出現的順序。 */
        final Map<String, Integer> certificateKeys = new LinkedHashMap<>();
        /** 最早到期的憑證的到期日；沒有憑證是 null。 */
        String earliestExpiry = null;
        /** 執行期證據裡錄到的後量子混合金鑰交換的名稱（排序、不重複）；空的 = 沒有錄到。 */
        final TreeSet<String> runtimePqcNames = new TreeSet<>();
    }

    /** 把每個元件看一遍，依種類與來源交給下面三個方法之一（或都不是，略過）。 */
    private static Highlights collectHighlights(Map<String, JsonNode> components) {
        Highlights found = new Highlights();
        for (JsonNode component : components.values()) {
            String type = component.path("cryptoProperties").path("assetType").asText();
            String source = Cdx.prop(component, "source");
            if ("protocol".equals(type) && "tls-scan".equals(source)) {
                collectTlsEndpoints(found, component);
            }
            if ("certificate".equals(type)) {
                collectCertificate(found, component);
            }
            if ("algorithm".equals(type) && "runtime".equals(source) && "ML-KEM-hybrid".equals(Cdx.prop(component, "family"))) {
                found.runtimePqcNames.add(component.path("name").asText());
            }
        }
        return found;
    }

    /**
     * TLS 掃描的一個 protocol 元件：它的每個出現位置是一個端點，依這個元件的 TLS 版本分到三類之一。
     * TLS 1.3 而且有後量子金鑰交換 → pqcEndpoints；TLS 1.2 → tls12Endpoints；不是 1.3 也不是 1.2 → oldTlsEndpoints；
     * TLS 1.3 但沒有後量子金鑰交換 → 只算進 endpoints。
     */
    private static void collectTlsEndpoints(Highlights found, JsonNode component) {
        String version = Cdx.prop(component, "tlsVersion");
        for (JsonNode occurrence : component.path("evidence").path("occurrences")) {
            String location = occurrence.path("location").asText();
            found.endpoints.add(location);
            if ("1.3".equals(version) && "offered".equals(Cdx.prop(component, "pqcKeyExchange"))) {
                found.pqcEndpoints.add(location);
            } else if ("1.2".equals(version)) {
                found.tls12Endpoints.add(location);
            } else if (!"1.3".equals(version)) {
                found.oldTlsEndpoints.add(location);
            }
        }
    }

    /** 一張憑證：它的金鑰演算法那一類加一張；到期日比目前記的早就換成它。 */
    private static void collectCertificate(Highlights found, JsonNode component) {
        // 沒有 keyAlgorithm 屬性的憑證會數在「null」這個名字底下
        found.certificateKeys.merge(String.valueOf(Cdx.prop(component, "keyAlgorithm")), 1, Integer::sum);
        String expiry = component.path("cryptoProperties").path("certificateProperties").path("notValidAfter").asText();
        // 日期是 ISO 格式（2027-11-05T…），直接比字串就是比先後
        if (!expiry.isEmpty() && (found.earliestExpiry == null || expiry.compareTo(found.earliestExpiry) < 0)) {
            found.earliestExpiry = expiry;
        }
    }

    /** 「支援後量子混合金鑰交換的端點」那一列數字後面的說明：要和數字講同一件事。 */
    static String pqcNote(int supporting, int total) {
        if (total == 0) {
            return "（這次沒有掃 TLS 端點）";
        }
        if (supporting == total) {
            return "（伺服器都支援；實際用不用要看用戶端）";
        }
        if (supporting == 0) {
            return "（伺服器不支援：要先升級 JDK 或 TLS 函式庫）";
        }
        return "（其餘 " + (total - supporting) + " 個的伺服器還不支援）";
    }

    /** 「重點」表的一列：左邊是項目名稱，右邊是值（兩邊都會經過 esc）。 */
    private static void fact(StringBuilder html, String label, String value) {
        html.append("<tr><th>").append(esc(label)).append("</th><td>").append(esc(value)).append("</td></tr>\n");
    }

    /**
     * 一個等級的那一節：標題（中文名稱＋元件數）、一行說明、明細表。count 是這個等級的元件數（不是列數）。
     *
     * 這個等級沒有任何一列 → 只印「沒有。」。
     * pass 與 info 兩節預設收合（通常很長，重點是前面四節），點「展開 N 列」才看得到；列印時 CSS 會全部展開。
     * 表有四欄：類型、資產（名稱、× 個數、來源）、判斷與依據、出現位置。
     */
    private static void section(StringBuilder html, String level, Map<String, Row> rows, int count) {
        // 挑出這個等級的列
        List<Row> mine = new ArrayList<>();
        for (Row row : rows.values()) {
            if (row.level.equals(level)) {
                mine.add(row);
            }
        }
        // 排序：先照種類（TYPE_ORDER 的順序），同種類照名稱
        mine.sort((a, b) -> (typeOrder(a.type) + a.name).compareTo(typeOrder(b.type) + b.name));

        boolean collapsed = level.equals("pass") || level.equals("info");
        html.append("<h2 id=\"").append(level).append("\" class=\"").append(level).append("\">")
            .append(LEVEL_LABEL.get(level)).append("（").append(count).append("）</h2>\n")
            .append("<p class=\"sub\">").append(LEVEL_NOTE.get(level)).append("</p>\n");
        if (mine.isEmpty()) {
            html.append("<p class=\"none\">沒有。</p>\n");
            return;
        }
        if (collapsed) {
            html.append("<details><summary>展開 ").append(mine.size()).append(" 列</summary>\n");
        }
        html.append("<table>\n<tr><th>類型</th><th>資產</th><th>判斷與依據</th><th>出現位置</th></tr>\n");
        for (Row row : mine) {
            html.append("<tr><td>").append(esc(TYPE_LABEL.getOrDefault(row.type, row.type))).append("</td><td>")
                .append(esc(row.name));
            if (row.components > 1) {
                html.append(" <span class=\"count\">× ").append(row.components).append("</span>");
            }
            if (!row.sources.isEmpty()) {
                html.append("<br><span class=\"src\">").append(esc(String.join("、", row.sources))).append("</span>");
            }
            html.append("</td><td>").append(esc(String.join("；", row.reasons)));
            if (!row.basis.isEmpty()) {
                html.append("<br><span class=\"src\">依據：").append(esc(String.join("、", row.basis))).append("</span>");
            }
            html.append("</td><td>");
            locations(html, row.locations);
            html.append("</td></tr>\n");
        }
        html.append("</table>\n");
        if (collapsed) {
            html.append("</details>\n");
        }
    }

    /**
     * 「出現位置」那一格。沒有位置印「—」；前 3 個直接列（一行一個）；超過 3 個時，其餘的收在「共 N 處」裡（N 是全部的數量）。
     */
    private static void locations(StringBuilder html, TreeSet<String> locations) {
        if (locations.isEmpty()) {
            html.append("—");
            return;
        }
        int shown = 0;
        StringBuilder rest = new StringBuilder();
        for (String location : locations) {
            if (shown < LOCATIONS_SHOWN) {
                html.append(esc(location)).append("<br>");
            } else {
                rest.append(esc(location)).append("<br>");
            }
            shown++;
        }
        if (shown > LOCATIONS_SHOWN) {
            html.append("<details><summary>共 ").append(shown).append(" 處</summary>").append(rest).append("</details>");
        }
    }

    /**
     * 「資產」欄顯示的名稱。依種類在元件名稱上加一點資訊，或去掉每台都不一樣的部分（這樣各台才併得成同一列）：
     * <pre>
     *   憑證                     名稱（金鑰演算法，到期 日期）   例：CN=kb01.poc.lab（RSA-2048，到期 2027-11-05）
     *   函式庫（有版本）         名稱 版本                       例：bcprov-jdk18on 1.78
     *   keystore、truststore、私鑰檔   只留檔名（種類）          例：kb01:/etc/confluent/ssl/server.keystore.p12 → server.keystore.p12（keystore）
     *   平台設定檔               去掉「主機:」                   例：kb01:/etc/kafka/server.properties → /etc/kafka/server.properties
     *   TLS 掃描的協定           名稱（N 個 cipher suite）       例：TLS 1.3（3 個 cipher suite）
     *   其他                     元件名稱原樣
     * </pre>
     */
    private static String displayName(JsonNode component, String type) {
        String name = component.path("name").asText();
        if ("certificate".equals(type)) {
            JsonNode certificate = component.path("cryptoProperties").path("certificateProperties");
            String expiry = certificate.path("notValidAfter").asText();
            return name + "（" + Cdx.prop(component, "keyAlgorithm") + "，到期 "
                + expiry.substring(0, Math.min(10, expiry.length())) + "）";
        }
        if ("library".equals(type) && component.has("version")) {
            return name + " " + component.path("version").asText();
        }
        if ("file".equals(type)) {
            String kind = Cdx.prop(component, "kind");
            if ("keystore".equals(kind) || "truststore".equals(kind) || "private-key-file".equals(kind)) {
                // 每台的檔名相同：用檔名當名稱，主機放在出現位置
                return name.substring(name.lastIndexOf('/') + 1) + "（" + kind + "）";
            }
            if ("platform-config".equals(kind)) {
                return name.substring(name.indexOf(':') + 1);
            }
        }
        if ("protocol".equals(type) && "tls-scan".equals(Cdx.prop(component, "source"))) {
            int suites = component.path("cryptoProperties").path("protocolProperties").path("cipherSuites").size();
            return name + "（" + suites + " 個 cipher suite）";
        }
        return name;
    }

    /**
     * 元件的 cbom:source（哪一個 Layer 產生的）→「資產」欄下面那行灰字。
     * 新的 Layer 用了新的來源名稱時在這裡加一行；沒加的會印「來源：」加英文的來源名稱。
     */
    private static String sourceLabel(String source) {
        return switch (source) {
            case "tls-scan" -> "來源：TLS 掃描";
            case "config" -> "來源：平台設定";
            case "jdk" -> "來源：JDK／OS 設定";
            case "library" -> "來源：jar 清單";
            case "runtime" -> "來源：執行期證據（JFR）";
            case "certificate-file" -> "來源：憑證";
            case "source-code" -> "來源：原始碼掃描";
            case "secret-scan" -> "來源：秘密掃描（原始碼庫）";
            case "image-scan" -> "來源：映像掃描";
            case "collection-check" -> "來源：盤點完整性檢查";
            default -> "來源：" + source;
        };
    }

    /**
     * 排序用：種類在 TYPE_ORDER 裡是第幾個，轉成字串（憑證 "0"、金鑰 "1" … 函式庫 "5"）。
     * 不在 TYPE_ORDER 裡的種類是 "-1"；因為是當字串比，"-" 排在數字前面，所以會排在最前面。
     */
    private static String typeOrder(String type) {
        return String.valueOf(TYPE_ORDER.indexOf(type));
    }

    /** 讀 metadata 的一個「cbom:名稱」屬性（BomSteps.metadata 寫的：scope、roles、allRoles、hosts、runtimeEvidence）；沒有回空字串。 */
    private static String meta(JsonNode metadata, String name) {
        for (JsonNode property : metadata.path("properties")) {
            if (property.path("name").asText().equals(Cdx.PREFIX + name)) {
                return property.path("value").asText();
            }
        }
        return "";
    }

    /** 元件清單 → 顯示用的文字。例：「controller broker rest c3 shared」→「controller、broker、REST Proxy、Control Center、平台共用」。 */
    private static String roles(String roles) {
        List<String> labels = new ArrayList<>();
        for (String role : roles.trim().split("\\s+")) {
            labels.add(ROLE_LABEL.getOrDefault(role, role));
        }
        return String.join("、", labels);
    }

    /** 部分盤點時沒有盤到的元件：allRoles 裡有、roles 裡沒有的，用「、」接起來（顯示名稱查 ROLE_LABEL）。 */
    private static String missingRoles(JsonNode metadata) {
        List<String> selected = List.of(meta(metadata, "roles").trim().split("\\s+"));
        List<String> missing = new ArrayList<>();
        for (String role : meta(metadata, "allRoles").trim().split("\\s+")) {
            if (!selected.contains(role)) {
                missing.add(ROLE_LABEL.getOrDefault(role, role));
            }
        }
        return String.join("、", missing);
    }

    /** 「主機:元件」的清單 → 台數與主機名稱。例：「kc01:controller kb01:broker」→「2 台（kc01、kb01）」。 */
    private static String hosts(String hosts) {
        List<String> names = new ArrayList<>();
        for (String pair : hosts.trim().split("\\s+")) {
            names.add(pair.split(":")[0]);
        }
        return names.size() + " 台（" + String.join("、", names) + "）";
    }

    /**
     * 把文字裡對 HTML 有特殊意義的四個字元換掉，放進頁面才不會被當成標籤。
     * 例：「&lt;遮蔽&gt;」的 &lt; 換成 &amp;lt;。&amp; 要第一個換（否則會把後面換出來的 &amp; 再換一次）。
     */
    static String esc(String text) {
        return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }

    /**
     * 樣式。顏色集中在最上面的 :root（--violation 等六個等級各一個顏色）；
     * 等級的 class 名稱就是等級的英文（h2.violation、.tile.violation）。
     * 最後兩行：畫面窄於 720px 時表格欄寬改成自動；列印時把收合的部分全部展開。
     */
    private static final String CSS = """
        :root { --ink:#1f2933; --muted:#52606d; --line:#d9e2ec; --bg:#f5f7fa;
                --violation:#b42318; --quantum:#b54708; --warning:#946200; --unknown:#5925dc; --pass:#067647; --info:#175cd3; }
        * { box-sizing: border-box; }
        body { font-family: "Noto Sans TC", "Microsoft JhengHei", system-ui, sans-serif; color: var(--ink); background: #fff;
               margin: 0 auto; padding: 24px 16px 48px; max-width: 1180px; line-height: 1.55; font-size: 15px; }
        h1 { font-size: 26px; margin: 0 0 4px; }
        h2 { font-size: 19px; margin: 34px 0 4px; padding-left: 10px; border-left: 5px solid var(--line); }
        h2.violation { border-color: var(--violation); } h2.quantum-vulnerable { border-color: var(--quantum); }
        h2.warning { border-color: var(--warning); } h2.unknown { border-color: var(--unknown); }
        h2.pass { border-color: var(--pass); } h2.info { border-color: var(--info); }
        .sub { color: var(--muted); margin: 2px 0 12px; font-size: 14px; }
        .none { color: var(--muted); }
        .scope { border: 1px solid var(--line); border-radius: 8px; padding: 10px 14px; margin: 14px 0; background: var(--bg); }
        .scope.partial { border-color: var(--quantum); background: #fffaeb; }
        .verdict { border-radius: 8px; padding: 12px 14px; font-size: 18px; font-weight: 700; margin: 14px 0; }
        .verdict span { font-size: 13px; font-weight: 400; margin-left: 8px; }
        .verdict.ok { background: #ecfdf3; color: var(--pass); } .verdict.bad { background: #fef3f2; color: var(--violation); }
        .tiles { display: flex; flex-wrap: wrap; gap: 10px; margin: 14px 0 4px; }
        .tile { flex: 1 1 140px; border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; text-decoration: none;
                color: var(--ink); background: #fff; }
        .tile b { display: block; font-size: 28px; line-height: 1.2; }
        .tile.violation b { color: var(--violation); } .tile.quantum-vulnerable b { color: var(--quantum); }
        .tile.warning b { color: var(--warning); } .tile.unknown b { color: var(--unknown); }
        .tile.pass b { color: var(--pass); } .tile.info b { color: var(--info); }
        table { border-collapse: collapse; width: 100%; margin: 8px 0; table-layout: fixed; }
        th, td { border: 1px solid var(--line); padding: 7px 9px; text-align: left; vertical-align: top; overflow-wrap: anywhere; }
        th { background: var(--bg); font-weight: 600; }
        table.facts th { width: 300px; }
        table:not(.facts) th:nth-child(1) { width: 96px; } table:not(.facts) th:nth-child(2) { width: 27%; }
        table:not(.facts) th:nth-child(4) { width: 30%; }
        .count { color: var(--muted); font-size: 13px; }
        .src { color: var(--muted); font-size: 13px; }
        details summary { cursor: pointer; color: var(--info); }
        footer { margin-top: 36px; padding-top: 12px; border-top: 1px solid var(--line); color: var(--muted); font-size: 13px; }
        @media (max-width: 720px) { table { table-layout: auto; } table.facts th { width: auto; } }
        @media print { details { display: block; } details > summary { display: none; } body { max-width: none; } }
        """;
}
