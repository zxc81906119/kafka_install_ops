package lab.cbom;

import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 盤點完整性檢查：這次的原料「該有而沒有的」（缺口）。
 *
 * 為什麼要有：收集腳本有些步驟失敗了會繼續收其他的（某個埠沒掃成、某台沒錄到），少了原料的那一部分在 CBOM 裡就是
 * 「沒有元件」，報告看起來反而比較乾淨。這裡用原料自己當對照（設定檔說有開的，就應該掃得到），把缺的列出來。
 *
 * 輸入：原料目錄（Raw），加上各層合併好的元件（查憑證元件用）。
 * 輸出：一個元件，放進 CBOM 讓規則與報告看得到：
 * <pre>
 * { "type": "data", "bom-ref": "data:…", "name": "盤點完整性檢查",
 *   "properties": [ { "name": "cbom:source",   "value": "collection-check" },
 *                   { "name": "cbom:kind",     "value": "collection-check" },
 *                   { "name": "cbom:gapCount", "value": "1" },
 *                   { "name": "cbom:gap",      "value": "kb03:8090（設定檔的 listener https）沒有 TLS 掃描結果" } ] }
 * </pre>
 * 每個缺口一筆 cbom:gap；沒有缺口時 gapCount 是 0、沒有 cbom:gap。type 用 CycloneDX 的 data（不是密碼學資產，也不是檔案）。
 * 規則（cbom.rego）：有缺口 → collection-gap（無法判斷）；沒有 → collection-complete（通過）。
 * 誰呼叫：BomSteps.COMPLETENESS（合併之後的第一步）→ Profile.collectionGaps → 這裡的 confluentPlatform() 或 webApp()。
 *
 * Confluent Platform 的檢查（看什麼 → 對什麼）：
 * <pre>
 *   1. collect.env 的 HOSTS 每一台            → 原料目錄裡有 &lt;主機&gt;/ 目錄
 *   2. 每台                                    → 有 platform-config.properties（服務的設定）
 *   3. 每台                                    → 有 JDK 的安全設定（java-security-effective.txt 或 java.security 其中一個有內容）
 *   4. 每台                                    → 有 OS 的密碼政策（os-crypto.txt 至少三行）
 *   5. 設定檔裡每個有開 TLS 的 listener 的埠   → 有 &lt;主機&gt;/tls/&lt;埠&gt;.json，而且裡面沒有 scanProblem（testssl 沒掃成時寫的）
 *      （哪些 listener 有開 TLS 見 tlsListenerPorts）
 *   6. 設定檔引用的每個 keystore、truststore   → 出現在 ssl-files.list（/etc/confluent/ssl 的檔案清單）
 *      （名稱結尾是 keystore.location、truststore.location 的設定）
 *   7. 設定檔有引用 keystore 的主機            → 至少有一張憑證元件的出現位置在這台（「主機全名:埠」開頭）。
 *      keystore 的內容不讀（要密碼），所以對的是「這台出示的憑證有沒有收到」；truststore 沒有對應的檢查
 *   8. 每台                                    → 在 shared/jars/groups.txt 裡；每一組有 shared/jars/sbom-&lt;雜湊&gt;.json
 *   9. shared/theia.json（憑證掃描的結果）     → 存在
 *  10. collect.env 的 JFR_SECONDS 有值（有錄） → 每台有 &lt;主機&gt;/jfr/*.json
 * </pre>
 * web app 的檢查：
 * <pre>
 *   1. shared/source/cbom.json（原始碼掃描）、shared/theia.json（秘密掃描）、shared/theia-image.json（映像掃描）→ 存在
 *   2. shared/jars/groups.txt 有內容，每一組有 sbom-&lt;雜湊&gt;.json（SBOM）
 *   3. HOSTS 的每一台（只有 app）有目錄、JDK 的安全設定、OS 的密碼政策（都是從映像取的）
 *   4. JFR_SECONDS 有值（有做執行期那一段）→ 有 app/tls/*.json 而且沒有 scanProblem、有 app/jfr/*.json
 * </pre>
 * 要加一條檢查：在對應的方法裡多寫一段，缺的時候 gaps.add("哪裡：缺什麼")。文字會出現在報告與規則的原因裡，寫給人看。
 */
final class CollectionCheck {

    /**
     * listener 的寫法：「名稱://位址:埠」。括號抓到的是名稱與埠。
     * 例：「INTERNAL://kb01.poc.lab:9092」→ INTERNAL、9092；「https://0.0.0.0:8090」→ https、8090。
     */
    private static final Pattern LISTENER = Pattern.compile("^([A-Za-z0-9_.-]+)://[^/,]*:(\\d+)$");

    private CollectionCheck() {
    }

    /** 把缺口做成一個元件（樣子見檔頭）。bom-ref 固定，所以每份 CBOM 最多一個。 */
    static ObjectNode component(List<String> gaps) {
        ObjectNode check = Cdx.plain("data", "盤點完整性檢查", "collection-check");
        Cdx.prop(check, "source", "collection-check");
        Cdx.prop(check, "kind", "collection-check");
        Cdx.prop(check, "gapCount", String.valueOf(gaps.size()));
        for (String gap : gaps) {
            Cdx.prop(check, "gap", gap);
        }
        return check;
    }

    /** Confluent Platform 的缺口（檢查的清單見檔頭）。bom 是各層合併好的元件。 */
    static List<String> confluentPlatform(Raw raw, JsonNode bom) throws IOException {
        List<String> gaps = new ArrayList<>();
        Map<String, List<String>> jarGroups = jarGroups(raw);
        for (Raw.Host host : raw.hosts()) {
            String name = host.name();
            Path dir = raw.hostDir(name);
            // 1. 這台的目錄
            if (!Files.isDirectory(dir)) {
                gaps.add(name + "：沒有這台的原料目錄");
                continue;
            }
            // 2. 服務的設定
            List<String> configLines = Raw.lines(dir.resolve("platform-config.properties"));
            if (configLines.isEmpty()) {
                gaps.add(name + "：沒有服務的設定（platform-config.properties）");
            }
            // 3.、4. JDK 與 OS
            jdkAndOs(gaps, name, dir);
            // 5. 有開 TLS 的 listener 都掃到了
            Map<String, String> settings = settings(configLines);
            Map<String, String> tlsPorts = tlsListenerPorts(settings);
            // 設定收到了卻一個 listeners 設定都沒有：沒辦法對照（Kafka、REST Proxy、Control Center 都一定有這個設定）
            if (!configLines.isEmpty() && !hasListenerSetting(settings)) {
                gaps.add(name + "：收到的設定裡沒有 listeners，無法對照 TLS 掃描有沒有掃齊");
            }
            for (Map.Entry<String, String> port : tlsPorts.entrySet()) {
                tlsScan(gaps, name + ":" + port.getKey() + "（設定檔的 listener " + port.getValue() + "）",
                    dir.resolve("tls").resolve(port.getKey() + ".json"));
            }
            // 6.、7. keystore、truststore
            keystores(gaps, raw, name, settings, Raw.lines(dir.resolve("ssl-files.list")), bom);
            // 8. jar 分組
            if (!inAnyGroup(jarGroups, name)) {
                gaps.add(name + "：不在 jar 分組裡（shared/jars/groups.txt），這台的函式庫沒有盤到");
            }
            // 10. 執行期證據
            if (!raw.get("JFR_SECONDS").isEmpty() && !hasJson(dir.resolve("jfr"))) {
                gaps.add(name + "：這次有錄執行期證據，但這台沒有錄製結果（jfr/*.json）");
            }
        }
        // 8. 每一組的 SBOM
        missingSboms(gaps, raw, jarGroups);
        // 9. 憑證掃描
        if (!Files.isRegularFile(raw.shared().resolve("theia.json"))) {
            gaps.add("沒有憑證掃描的結果（shared/theia.json）");
        }
        return gaps;
    }

    /** web app 的缺口（檢查的清單見檔頭）。 */
    static List<String> webApp(Raw raw) throws IOException {
        List<String> gaps = new ArrayList<>();
        // 1. 三種掃描的結果
        if (!Files.isRegularFile(raw.shared().resolve("source").resolve("cbom.json"))) {
            gaps.add("沒有原始碼掃描的結果（shared/source/cbom.json）");
        }
        if (!Files.isRegularFile(raw.shared().resolve("theia.json"))) {
            gaps.add("沒有秘密掃描的結果（shared/theia.json）");
        }
        if (!Files.isRegularFile(raw.shared().resolve("theia-image.json"))) {
            gaps.add("沒有映像掃描的結果（shared/theia-image.json）");
        }
        // 2. SBOM
        Map<String, List<String>> jarGroups = jarGroups(raw);
        if (jarGroups.isEmpty()) {
            gaps.add("沒有函式庫清單（shared/jars/groups.txt）");
        }
        missingSboms(gaps, raw, jarGroups);
        // 3.、4. 每一台（web app 只有 app）
        boolean runtime = !raw.get("JFR_SECONDS").isEmpty();
        for (Raw.Host host : raw.hosts()) {
            String name = host.name();
            Path dir = raw.hostDir(name);
            if (!Files.isDirectory(dir)) {
                gaps.add(name + "：沒有這台的原料目錄");
                continue;
            }
            jdkAndOs(gaps, name, dir);
            if (!runtime) {
                continue;
            }
            // 有做執行期那一段：TLS 掃描與 JFR 都要在
            List<Path> scans = jsonFiles(dir.resolve("tls"));
            if (scans.isEmpty()) {
                gaps.add(name + "：這次有做執行期，但沒有 TLS 掃描結果（tls/*.json）");
            }
            for (Path scan : scans) {
                String port = scan.getFileName().toString().replace(".json", "");
                tlsScan(gaps, name + ":" + port, scan);
            }
            if (!hasJson(dir.resolve("jfr"))) {
                gaps.add(name + "：這次有做執行期，但沒有錄製結果（jfr/*.json）");
            }
        }
        return gaps;
    }

    /** 這台有沒有 JDK 的安全設定與 OS 的密碼政策；沒有的各記一個缺口。 */
    private static void jdkAndOs(List<String> gaps, String host, Path dir) throws IOException {
        boolean effective = !Raw.lines(dir.resolve("java-security-effective.txt")).isEmpty();
        boolean file = !Raw.lines(dir.resolve("java.security")).isEmpty();
        if (!effective && !file) {
            gaps.add(host + "：沒有 JDK 的安全設定（java-security-effective.txt、java.security 都沒有）");
        }
        // 三行：政策、OS 版本、OpenSSL 版本（JdkSettingsLayer.osCrypto 少於三行就不產生元件）
        if (Raw.lines(dir.resolve("os-crypto.txt")).size() < 3) {
            gaps.add(host + "：沒有 OS 的密碼政策（os-crypto.txt）");
        }
    }

    /**
     * 一個埠的 TLS 掃描結果在不在、有沒有掃成。what 是缺口開頭的文字（哪一台的哪個埠）。
     * 沒有檔 → 「…沒有 TLS 掃描結果」；檔裡有 id 是 scanProblem 的項目（testssl 連不上、交握失敗時寫的）→「…TLS 掃描沒掃成：原因」；
     * 檔不是 JSON → 「…TLS 掃描結果讀不了」。
     */
    private static void tlsScan(List<String> gaps, String what, Path file) {
        if (!Files.isRegularFile(file)) {
            gaps.add(what + "沒有 TLS 掃描結果");
            return;
        }
        JsonNode scan;
        try {
            scan = Cdx.read(file);
        } catch (IOException e) {
            gaps.add(what + "的 TLS 掃描結果讀不了（不是 JSON）");
            return;
        }
        for (JsonNode one : scan) {
            if ("scanProblem".equals(one.path("id").asText())) {
                gaps.add(what + "的 TLS 掃描沒掃成：" + one.path("finding").asText());
                return;
            }
        }
    }

    /** platform-config.properties 的每一行 → 名稱與值（以第一個等號分開；# 開頭的行不算）。 */
    private static Map<String, String> settings(List<String> lines) {
        Map<String, String> settings = new LinkedHashMap<>();
        for (String line : lines) {
            int equals = line.indexOf('=');
            if (line.startsWith("#") || equals < 1) {
                continue;
            }
            settings.put(line.substring(0, equals).trim(), line.substring(equals + 1).trim());
        }
        return settings;
    }

    /**
     * 設定檔裡有開 TLS 的 listener：埠 → listener 的名稱（寫進缺口的文字用）。
     *
     * 看名稱結尾是 listeners 的設定（listeners、confluent.metadata.server.listeners、confluent.controlcenter.rest.listeners…；
     * advertised.listeners 是對外公告的位址，不是實際在聽的，不看）。值是逗號分隔的「名稱://位址:埠」。
     * 一個 listener 有沒有開 TLS：
     * <pre>
     *   名稱是 https                                          → 有（REST Proxy、MDS、Control Center 的寫法）
     *   Kafka 的 listener：到 listener.security.protocol.map 查它的協定（例：INTERNAL:SSL,CLIENT:SASL_SSL）；
     *   對照表裡沒有時，名稱本身就是協定（Kafka 的預設）   → 協定結尾是 SSL（SSL、SASL_SSL）就有
     *   其他（http、PLAINTEXT、SASL_PLAINTEXT）               → 沒有
     * </pre>
     * 例：listeners=INTERNAL://kb01.poc.lab:9092,CLIENT://kb01.poc.lab:9094、對照表 INTERNAL:SSL,CLIENT:SASL_SSL
     *     → {9092: "INTERNAL", 9094: "CLIENT"}。
     */
    static Map<String, String> tlsListenerPorts(Map<String, String> settings) {
        // listener 名稱（大寫）→ 協定（大寫）
        Map<String, String> protocolOf = new TreeMap<>();
        for (Map.Entry<String, String> setting : settings.entrySet()) {
            if (!setting.getKey().endsWith("listener.security.protocol.map")) {
                continue;
            }
            for (String pair : setting.getValue().split(",")) {
                String[] parts = pair.trim().split(":");
                if (parts.length == 2) {
                    protocolOf.put(parts[0].trim().toUpperCase(Locale.ROOT), parts[1].trim().toUpperCase(Locale.ROOT));
                }
            }
        }
        Map<String, String> ports = new TreeMap<>();
        for (Map.Entry<String, String> setting : settings.entrySet()) {
            String key = setting.getKey();
            if (!key.endsWith("listeners") || key.contains("advertised")) {
                continue;
            }
            for (String entry : setting.getValue().split(",")) {
                Matcher listener = LISTENER.matcher(entry.trim());
                if (!listener.matches()) {
                    continue;
                }
                String name = listener.group(1);
                String upper = name.toUpperCase(Locale.ROOT);
                String protocol = protocolOf.getOrDefault(upper, upper);
                if (protocol.equals("HTTPS") || protocol.endsWith("SSL")) {
                    ports.put(listener.group(2), name);
                }
            }
        }
        return ports;
    }

    /** 設定裡有沒有任何一個名稱結尾是 listeners 的設定（advertised 的不算）。 */
    private static boolean hasListenerSetting(Map<String, String> settings) {
        for (String key : settings.keySet()) {
            if (key.endsWith("listeners") && !key.contains("advertised")) {
                return true;
            }
        }
        return false;
    }

    /**
     * 第 6、7 條：設定檔引用的 keystore、truststore。
     * 例：ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12 → 這個路徑要在 ssl-files.list 的第四欄出現。
     * 值是空的或被遮掉的（&lt; 開頭）不看。同一個檔被好幾個設定引用只檢查一次。
     */
    private static void keystores(List<String> gaps, Raw raw, String host, Map<String, String> settings,
        List<String> fileList, JsonNode bom) {
        // /etc/confluent/ssl 底下實際有的檔（ssl-files.list 每行「權限 擁有者 大小 路徑」的第四欄）
        TreeSet<String> existing = new TreeSet<>();
        for (String line : fileList) {
            String[] parts = line.trim().split("\\s+", 4);
            if (parts.length == 4) {
                existing.add(parts[3]);
            }
        }
        TreeSet<String> referenced = new TreeSet<>();
        boolean usesKeystore = false;
        for (Map.Entry<String, String> setting : settings.entrySet()) {
            String key = setting.getKey();
            String path = setting.getValue();
            boolean keystore = key.endsWith("keystore.location");
            boolean truststore = key.endsWith("truststore.location");
            if ((!keystore && !truststore) || path.isEmpty() || path.startsWith("<")) {
                continue;
            }
            if (keystore) {
                usesKeystore = true;
            }
            referenced.add(path);
        }
        for (String path : referenced) {
            if (!existing.contains(path)) {
                gaps.add(host + "：設定檔引用的 " + path + " 不在檔案清單裡（ssl-files.list）");
            }
        }
        // 第 7 條：這台有用 keystore，就應該收得到它出示的憑證
        if (usesKeystore && !hasCertificateAt(bom, raw.fqdn(host) + ":")) {
            gaps.add(host + "：設定檔有引用 keystore，但沒有任何一張憑證元件出現在這台（沒有取到它出示的憑證）");
        }
    }

    /** 有沒有憑證元件的出現位置是 prefix 開頭的。例：prefix =「kb01.poc.lab:」。 */
    private static boolean hasCertificateAt(JsonNode bom, String prefix) {
        for (JsonNode component : bom.path("components")) {
            if (!"certificate".equals(component.path("cryptoProperties").path("assetType").asText())) {
                continue;
            }
            for (JsonNode occurrence : component.path("evidence").path("occurrences")) {
                if (occurrence.path("location").asText().startsWith(prefix)) {
                    return true;
                }
            }
        }
        return false;
    }

    /** shared/jars/groups.txt（每行「雜湊 主機」）→ 雜湊 → 那一組的主機。沒有這個檔回空的表。 */
    private static Map<String, List<String>> jarGroups(Raw raw) throws IOException {
        Map<String, List<String>> groups = new LinkedHashMap<>();
        for (String line : Raw.lines(raw.shared().resolve("jars").resolve("groups.txt"))) {
            String[] parts = line.trim().split("\\s+");
            if (parts.length == 2) {
                groups.computeIfAbsent(parts[0], k -> new ArrayList<>()).add(parts[1]);
            }
        }
        return groups;
    }

    /** 這台主機有沒有在任何一組裡。 */
    private static boolean inAnyGroup(Map<String, List<String>> groups, String host) {
        for (List<String> members : groups.values()) {
            if (members.contains(host)) {
                return true;
            }
        }
        return false;
    }

    /** 每一組都要有它的 SBOM；沒有的記一個缺口（列出那一組的主機）。 */
    private static void missingSboms(List<String> gaps, Raw raw, Map<String, List<String>> groups) {
        for (Map.Entry<String, List<String>> group : groups.entrySet()) {
            Path sbom = raw.shared().resolve("jars").resolve("sbom-" + group.getKey() + ".json");
            if (!Files.isRegularFile(sbom)) {
                gaps.add("jar 組 " + group.getKey() + "（" + String.join("、", group.getValue())
                    + "）沒有函式庫清單（shared/jars/sbom-" + group.getKey() + ".json）");
            }
        }
    }

    /** 目錄裡的 *.json，照檔名排序；目錄不存在回空的清單。 */
    private static List<Path> jsonFiles(Path dir) throws IOException {
        List<Path> files = new ArrayList<>();
        if (!Files.isDirectory(dir)) {
            return files;
        }
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(dir, "*.json")) {
            stream.forEach(files::add);
        }
        files.sort(null);
        return files;
    }

    /** 目錄裡有沒有任何一個 *.json。 */
    private static boolean hasJson(Path dir) throws IOException {
        return !jsonFiles(dir).isEmpty();
    }
}
