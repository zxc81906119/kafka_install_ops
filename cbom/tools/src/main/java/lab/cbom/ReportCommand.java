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
 */
final class ReportCommand {

    /** 等級由重到輕；一個元件有多筆 finding 時取最重的當它的等級。 */
    private static final List<String> LEVELS = List.of("violation", "quantum-vulnerable", "warning", "unknown", "pass", "info");

    private static final Map<String, String> LEVEL_LABEL = Map.of(
        "violation", "違規", "quantum-vulnerable", "量子脆弱", "warning", "警告",
        "unknown", "待人工判斷", "pass", "通過", "info", "盤點資訊");

    private static final Map<String, String> LEVEL_NOTE = Map.of(
        "violation", "現在就不合格，和量子電腦無關：已不安全的演算法、過短的金鑰、舊的 TLS、過期的憑證、錯誤的檔案權限。",
        "quantum-vulnerable", "現在安全，但量子電腦可破解。NIST IR 8547：2030 年後棄用、2035 年後禁用，要排進遷移計畫。",
        "warning", "建議改善，不影響合規結果。",
        "unknown", "規則不認得，請人工判斷後補規則。",
        "pass", "符合規則。",
        "info", "盤點資訊，沒有合規判斷。");

    private static final Map<String, String> TYPE_LABEL = Map.of(
        "certificate", "憑證", "related-crypto-material", "金鑰", "algorithm", "演算法",
        "protocol", "協定", "file", "設定與金鑰檔", "library", "密碼函式庫");

    private static final Map<String, String> ROLE_LABEL = Map.of(
        "controller", "controller", "broker", "broker", "rest", "REST Proxy", "c3", "Control Center", "shared", "平台共用");

    /** 一列：同一種資產、同樣的判斷，可能代表好幾個元件。 */
    private static final class Row {
        String type;
        String name;
        String level;
        final TreeSet<String> reasons = new TreeSet<>();
        final TreeSet<String> basis = new TreeSet<>();
        final TreeSet<String> locations = new TreeSet<>();
        final TreeSet<String> sources = new TreeSet<>();
        int components;
    }

    private ReportCommand() {
    }

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

    /** opa eval 的輸出是 {"result":[{"expressions":[{"value": …}]}]}；拆到 value。 */
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

    static String render(JsonNode cbom, JsonNode report) {
        return render(cbom, report, false);
    }

    static String render(JsonNode cbom, JsonNode report, boolean externalCss) {
        Map<String, JsonNode> components = new LinkedHashMap<>();
        for (JsonNode component : cbom.path("components")) {
            components.put(component.path("bom-ref").asText(), component);
        }

        // 每個元件的 finding 與最重的等級
        Map<String, List<JsonNode>> byComponent = new LinkedHashMap<>();
        for (JsonNode finding : report.path("findings")) {
            byComponent.computeIfAbsent(finding.path("bom-ref").asText(), k -> new ArrayList<>()).add(finding);
        }
        Map<String, Row> rows = new LinkedHashMap<>();
        Map<String, Integer> componentCounts = new LinkedHashMap<>();
        LEVELS.forEach(level -> componentCounts.put(level, 0));

        for (Map.Entry<String, JsonNode> entry : components.entrySet()) {
            JsonNode component = entry.getValue();
            List<JsonNode> findings = byComponent.getOrDefault(entry.getKey(), List.of());
            String worst = "info";
            for (JsonNode finding : findings) {
                if (LEVELS.indexOf(finding.path("level").asText()) < LEVELS.indexOf(worst)) {
                    worst = finding.path("level").asText();
                }
            }
            componentCounts.merge(worst, 1, Integer::sum);

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
                String context = occurrence.path("additionalContext").asText("");
                row.locations.add(occurrence.path("location").asText() + (context.isEmpty() ? "" : "　" + context));
            }
        }

        StringBuilder html = new StringBuilder();
        html.append("<!doctype html>\n<html lang=\"zh-Hant\">\n<head>\n<meta charset=\"utf-8\">\n")
            .append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
            .append("<title>密碼學資產合規報告</title>\n");
        if (externalCss) {
            html.append("<link rel=\"stylesheet\" href=\"report.css\">\n");
        } else {
            html.append("<style>\n").append(CSS).append("</style>\n");
        }
        html.append("</head>\n<body>\n");

        header(html, cbom, report, componentCounts, components.size());
        highlights(html, components);
        for (String level : LEVELS) {
            section(html, level, rows, componentCounts.get(level));
        }
        html.append("<footer>判斷規則：cbom/policy/cbom.rego（OPA）。依據：NIST IR 8547、FIPS 203／204／205、")
            .append("NIST SP 800-131A Rev.2、NIST SP 800-52 Rev.2。CBOM 格式：CycloneDX ")
            .append(esc(cbom.path("specVersion").asText())).append("。</footer>\n</body>\n</html>\n");
        return html.toString();
    }

    private static void header(StringBuilder html, JsonNode cbom, JsonNode report, Map<String, Integer> counts, int total) {
        JsonNode metadata = cbom.path("metadata");
        boolean full = "full".equals(meta(metadata, "scope"));
        boolean compliant = report.path("compliant").asBoolean(counts.get("violation") == 0);

        html.append("<h1>密碼學資產合規報告</h1>\n");
        html.append("<p class=\"sub\">").append(esc(metadata.path("component").path("name").asText()));
        if (metadata.path("component").has("version")) {
            html.append("　版本 ").append(esc(metadata.path("component").path("version").asText()));
        }
        html.append("　盤點時間 ").append(esc(metadata.path("timestamp").asText())).append("</p>\n");

        html.append("<div class=\"scope ").append(full ? "full" : "partial").append("\"><strong>")
            .append(full ? "完整盤點" : "部分盤點").append("</strong>　範圍：").append(esc(roles(meta(metadata, "roles"))));
        if (!full) {
            html.append("　<strong>沒有盤到：").append(esc(missingRoles(metadata))).append("</strong>（這份報告不代表整個平台）");
        }
        html.append("<br>主機：").append(esc(hosts(meta(metadata, "hosts"))))
            .append("　執行期證據：").append(esc("none".equals(meta(metadata, "runtimeEvidence")) ? "沒有錄製" : meta(metadata, "runtimeEvidence")))
            .append("</div>\n");

        html.append("<div class=\"verdict ").append(compliant ? "ok" : "bad").append("\">")
            .append(compliant ? "合規：沒有違規項目" : "不合規：有 " + counts.get("violation") + " 個違規項目")
            .append("<span>（量子脆弱與警告不影響這個結果，但要排進遷移計畫）</span></div>\n");

        html.append("<div class=\"tiles\">\n");
        for (String level : LEVELS) {
            html.append("<a class=\"tile ").append(level).append("\" href=\"#").append(level).append("\"><b>")
                .append(counts.get(level)).append("</b>").append(LEVEL_LABEL.get(level)).append("</a>\n");
        }
        html.append("</div>\n<p class=\"sub\">共 ").append(total).append(" 個密碼學資產；數字是資產數（一個資產出現在多台主機只算一次）。</p>\n");
    }

    /** 後量子遷移最關心的幾個數字，直接從 CBOM 算。 */
    private static void highlights(StringBuilder html, Map<String, JsonNode> components) {
        TreeSet<String> endpoints = new TreeSet<>();
        TreeSet<String> pqcEndpoints = new TreeSet<>();
        TreeSet<String> tls12Endpoints = new TreeSet<>();
        TreeSet<String> oldTlsEndpoints = new TreeSet<>();
        Map<String, Integer> certificateKeys = new LinkedHashMap<>();
        String earliestExpiry = null;
        boolean runtimePqc = false;

        for (JsonNode component : components.values()) {
            String type = component.path("cryptoProperties").path("assetType").asText();
            String source = Cdx.prop(component, "source");
            if ("protocol".equals(type) && "tls-scan".equals(source)) {
                String version = Cdx.prop(component, "tlsVersion");
                for (JsonNode occurrence : component.path("evidence").path("occurrences")) {
                    String location = occurrence.path("location").asText();
                    endpoints.add(location);
                    if ("1.3".equals(version) && "offered".equals(Cdx.prop(component, "pqcKeyExchange"))) {
                        pqcEndpoints.add(location);
                    } else if ("1.2".equals(version)) {
                        tls12Endpoints.add(location);
                    } else if (!"1.3".equals(version)) {
                        oldTlsEndpoints.add(location);
                    }
                }
            }
            if ("certificate".equals(type)) {
                certificateKeys.merge(String.valueOf(Cdx.prop(component, "keyAlgorithm")), 1, Integer::sum);
                String expiry = component.path("cryptoProperties").path("certificateProperties").path("notValidAfter").asText();
                if (!expiry.isEmpty() && (earliestExpiry == null || expiry.compareTo(earliestExpiry) < 0)) {
                    earliestExpiry = expiry;
                }
            }
            if ("algorithm".equals(type) && "runtime".equals(source) && "ML-KEM-hybrid".equals(Cdx.prop(component, "family"))) {
                runtimePqc = true;
            }
        }

        html.append("<h2>後量子遷移的重點</h2>\n<table class=\"facts\">\n");
        fact(html, "TLS 端點（主機:埠）", endpoints.size() + " 個");
        fact(html, "支援後量子混合金鑰交換的端點", pqcEndpoints.size() + " / " + endpoints.size()
            + "（伺服器支援；實際用不用要看用戶端）");
        fact(html, "仍接受 TLS 1.2 的端點", tls12Endpoints.size() + " / " + endpoints.size()
            + "（TLS 1.2 用不了後量子金鑰交換）");
        fact(html, "接受 TLS 1.1 以下的端點", oldTlsEndpoints.size() + " 個");
        fact(html, "憑證的金鑰", certificateKeys.toString().replace("{", "").replace("}", "").replace("=", " × ")
            + "（都是量子脆弱的話，身分驗證這一塊要等 CA 支援後量子簽章）");
        if (earliestExpiry != null) {
            fact(html, "最早到期的憑證", earliestExpiry.substring(0, Math.min(10, earliestExpiry.length())));
        }
        fact(html, "執行期實際用到後量子金鑰交換", runtimePqc ? "有（JFR 錄到 X25519MLKEM768）" : "沒有錄到，或這次沒有錄製");
        html.append("</table>\n");
    }

    private static void fact(StringBuilder html, String label, String value) {
        html.append("<tr><th>").append(esc(label)).append("</th><td>").append(esc(value)).append("</td></tr>\n");
    }

    private static void section(StringBuilder html, String level, Map<String, Row> rows, int count) {
        List<Row> mine = new ArrayList<>();
        for (Row row : rows.values()) {
            if (row.level.equals(level)) {
                mine.add(row);
            }
        }
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

    private static void locations(StringBuilder html, TreeSet<String> locations) {
        if (locations.isEmpty()) {
            html.append("—");
            return;
        }
        int shown = 0;
        StringBuilder rest = new StringBuilder();
        for (String location : locations) {
            if (shown < 3) {
                html.append(esc(location)).append("<br>");
            } else {
                rest.append(esc(location)).append("<br>");
            }
            shown++;
        }
        if (shown > 3) {
            html.append("<details><summary>共 ").append(shown).append(" 處</summary>").append(rest).append("</details>");
        }
    }

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

    private static String sourceLabel(String source) {
        return switch (source) {
            case "tls-scan" -> "來源：TLS 掃描";
            case "config" -> "來源：平台設定";
            case "jdk" -> "來源：JDK／OS 設定";
            case "library" -> "來源：jar 清單";
            case "runtime" -> "來源：執行期證據（JFR）";
            case "certificate-file" -> "來源：憑證";
            default -> "來源：" + source;
        };
    }

    private static String typeOrder(String type) {
        return String.valueOf(List.of("certificate", "related-crypto-material", "protocol", "algorithm", "file", "library").indexOf(type));
    }

    private static String meta(JsonNode metadata, String name) {
        for (JsonNode property : metadata.path("properties")) {
            if (property.path("name").asText().equals(Cdx.PREFIX + name)) {
                return property.path("value").asText();
            }
        }
        return "";
    }

    private static String roles(String roles) {
        List<String> labels = new ArrayList<>();
        for (String role : roles.trim().split("\\s+")) {
            labels.add(ROLE_LABEL.getOrDefault(role, role));
        }
        return String.join("、", labels);
    }

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

    private static String hosts(String hosts) {
        List<String> names = new ArrayList<>();
        for (String pair : hosts.trim().split("\\s+")) {
            names.add(pair.split(":")[0]);
        }
        return names.size() + " 台（" + String.join("、", names) + "）";
    }

    static String esc(String text) {
        return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }

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
