package lab.cbom;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 第 ② 層（手冊第 33 章那張表的編號）：JDK 與 OS 的密碼設定 → CBOM。
 *
 * 輸入（每台主機一份；前兩個是「實際生效的」，有的話以它們為準）：
 *   raw/&lt;主機&gt;/java-security-effective.txt  java -XshowSettings:security:all 的輸出：JVM 實際生效的安全設定、
 *                                            TLS 啟用的版本與 cipher suite
 *   raw/&lt;主機&gt;/jvm-system-properties.txt    執行中的服務的系統屬性裡和安全有關的幾項（看有沒有用 -D 另外指定設定檔）
 *   raw/&lt;主機&gt;/java.security                JDK 的安全設定檔（停用哪些演算法、provider 順序）；
 *                                            有上面的 effective 時只拿來對照，沒有時（舊的原料）才直接用
 *   raw/&lt;主機&gt;/java-version.txt             java -version 的輸出，加上 /opt/java/current 指到的目錄（最後一行）
 *   raw/&lt;主機&gt;/os-crypto.txt                三行：crypto-policies 的等級、OS 版本、OpenSSL 版本
 * 產出（屬性 cbom:source 都是 jdk）：
 *   file 元件（cbom:kind=java-security）     每個設定寫成屬性 cbom:setting:名稱，規則讀這些屬性
 *   file 元件（cbom:kind=os-crypto-policy）  OS 的 crypto-policies
 *   內容相同的主機合併成一筆（看出現位置就知道哪台不一樣）。
 * 誰呼叫：Main（經 Layers）。Confluent Platform 與 web app 都用這一層。
 */
final class JdkSettingsLayer implements Layer {

    /**
     * java.security 裡和密碼學盤點有關的設定；值可以用反斜線續行。只有這幾個會寫進 CBOM（另外加 provider 的順序）。
     * 要多盤一個設定就加在這裡；注意加了之後身分字串會變，所有主機的這個元件 bom-ref 都會變（bash cbom/golden.sh check 會不同）。
     */
    private static final List<String> KEYS = List.of(
        "jdk.tls.disabledAlgorithms", "jdk.tls.legacyAlgorithms", "jdk.tls.namedGroups", "jdk.tls.keyLimits",
        "jdk.certpath.disabledAlgorithms", "jdk.jar.disabledAlgorithms", "jdk.security.legacyAlgorithms",
        "jdk.disabled.namedCurves", "keystore.type", "securerandom.source");

    @Override
    public String id() {
        return "jdk";
    }

    @Override
    public String title() {
        return "JDK 與 OS 的密碼設定";
    }

    @Override
    public ObjectNode convert(Raw raw) throws IOException {
        return run(raw);
    }

    /** 每台主機：讀它的五個檔，JDK 的交給 javaSecurity()，OS 的交給 osCrypto()。檔案不存在時讀到空的清單，不算錯。 */
    static ObjectNode run(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        for (Raw.Host host : raw.hosts()) {
            Path dir = raw.hostDir(host.name());
            if (!Files.isDirectory(dir)) {
                continue;
            }
            javaSecurity(bom, host, Raw.lines(dir.resolve("java.security")), Raw.lines(dir.resolve("java-version.txt")),
                Raw.lines(dir.resolve("java-security-effective.txt")), Raw.lines(dir.resolve("jvm-system-properties.txt")));
            osCrypto(bom, host, Raw.lines(dir.resolve("os-crypto.txt")));
        }
        return bom;
    }

    /** 只有設定檔、沒有「實際生效的值」時的寫法（舊的原料）。目前只有單元測試直接呼叫這一個。 */
    static void javaSecurity(ObjectNode bom, Raw.Host host, List<String> lines, List<String> versionLines) {
        javaSecurity(bom, host, lines, versionLines, List.of(), List.of());
    }

    /**
     * 還沒建成元件的草稿：一邊收屬性，一邊把同樣的內容接進身分字串。
     * 身分字串決定 bom-ref，也就決定「哪些主機併成一筆」：每個設定值都完全相同的主機，身分字串相同，就是同一個元件。
     * 所以要等所有設定都收完，才能建元件。
     */
    private static final class Draft {
        /** 身分字串，一段一段用 | 接起來。 */
        final StringBuilder identity = new StringBuilder();
        /** 要寫的屬性，照加入的順序；每筆是 {名稱, 值}。 */
        final List<String[]> properties = new ArrayList<>();

        void property(String name, String value) {
            properties.add(new String[] {name, value});
        }
    }

    /**
     * 一台主機的 JDK 安全設定 → 一個 file 元件「JDK 版本 的 java.security」。
     *
     * lines：java.security 檔的內容。versionLines：java-version.txt。
     * effectiveLines：java -XshowSettings:security:all 的輸出（JVM 實際生效的值；有的話以它為準，檔案的值只拿來對照）。
     * systemProperties：執行中的服務的系統屬性裡和安全有關的幾項（看有沒有用 -D 另外指定設定檔）。
     *
     * 寫出的屬性（都是 cbom: 開頭）：
     * <pre>
     *   javaVersion                         例：25.0.5 2026-10-20 LTS
     *   setting:jdk.tls.disabledAlgorithms  KEYS 裡每個有值的設定各一筆
     *   setting:security.providers          provider 的順序，空白分隔。例：SUN SunRsaSign SunEC SunJSSE …
     *   settingsFrom                        effective = 上面的值來自「實際生效的」；沒有這個屬性 = 來自設定檔
     *   differsFromFile                     實際生效的值和設定檔寫的不一樣的設定名稱（空白分隔）；都一樣就沒有這個屬性
     *   setting:tls.enabledProtocols        實際啟用的 TLS 版本，逗號分隔。例：TLSv1.3,TLSv1.2
     *   setting:tls.enabledCipherSuites     實際啟用的 cipher suite，空白分隔
     *   securityPropertiesOverride          服務用 -Djava.security.properties= 另外指定的設定檔路徑
     * </pre>
     * 兩種輸入都沒有（這台沒收到 JDK 的設定）就什麼都不產生。
     */
    static void javaSecurity(ObjectNode bom, Raw.Host host, List<String> lines, List<String> versionLines,
        List<String> effectiveLines, List<String> systemProperties) {
        if (lines.isEmpty() && effectiveLines.isEmpty()) {
            return;
        }
        Map<String, String> fromFile = parse(lines);
        Effective effective = parseEffective(effectiveLines);
        boolean hasEffective = !effective.properties().isEmpty();
        // 用哪一份設定：有實際生效的就用它，沒有才用設定檔
        Map<String, String> settings;
        if (hasEffective) {
            settings = effective.properties();
        } else {
            settings = fromFile;
        }

        // java-version.txt 第一行例：「openjdk version "25.0.5" 2026-10-20 LTS」→ 版本「25.0.5 2026-10-20 LTS」；
        // 最後一行是 JDK 的安裝目錄。例：/opt/java/jdk-25.0.5。沒有這個檔時兩個都是空字串
        String version = "";
        String home = "";
        if (!versionLines.isEmpty()) {
            version = versionLines.get(0).replace("openjdk version ", "").replace("\"", "");
            home = versionLines.get(versionLines.size() - 1);
        }

        // 先收齊屬性與身分字串（順序不能動：屬性的順序、身分字串的內容都會出現在產出裡）
        Draft draft = new Draft();
        draft.identity.append("jdk|" + version);
        draft.property("source", "jdk");
        draft.property("kind", "java-security");
        draft.property("javaVersion", version);
        addSettings(draft, settings);
        if (hasEffective) {
            addEffective(draft, fromFile, effective);
        }
        addOverride(draft, systemProperties);

        // 再建元件：身分字串齊了，bom-ref 才算得出來
        ObjectNode file = Cdx.plain("file", "JDK " + version + " 的 java.security", draft.identity.toString());
        for (String[] property : draft.properties) {
            Cdx.prop(file, property[0], property[1]);
        }
        Cdx.occurrence(file, host.name() + ":" + home + "/conf/security/java.security", host.role());
        Cdx.add(bom, file);
    }

    /**
     * KEYS 裡每個有值的設定寫成屬性「setting:名稱」，再加一筆 provider 的順序。
     * 身分字串接上「|名稱=值」…「|providers=清單」。
     */
    private static void addSettings(Draft draft, Map<String, String> settings) {
        for (String key : KEYS) {
            String value = settings.get(key);
            if (value != null) {
                draft.property("setting:" + key, value);
                draft.identity.append('|').append(key).append('=').append(value);
            }
        }
        String providers = providerList(settings);
        draft.property("setting:security.providers", providers);
        draft.identity.append("|providers=").append(providers);
    }

    /**
     * provider 的順序：設定裡是 security.provider.1、security.provider.2 … 一個一個編號，
     * 從 1 開始往下找，找到沒有的號碼為止，用空白接起來。
     * 例：security.provider.1=SUN、security.provider.2=SunRsaSign →「SUN SunRsaSign」。一個都沒有回空字串。
     */
    private static String providerList(Map<String, String> settings) {
        StringBuilder providers = new StringBuilder();
        int number = 1;
        while (settings.containsKey("security.provider." + number)) {
            if (number > 1) {
                providers.append(" ");
            }
            providers.append(settings.get("security.provider." + number));
            number++;
        }
        return providers.toString();
    }

    /**
     * 有「實際生效的值」時多寫的幾個屬性：settingsFrom、differsFromFile、TLS 啟用的版本與 cipher suite。
     * 身分字串接上「|effective|不一樣的設定|TLS 版本|cipher suite」（三個清單都是 Java 印 List 的樣子，例：[TLSv1.3, TLSv1.2]）。
     */
    private static void addEffective(Draft draft, Map<String, String> fromFile, Effective effective) {
        draft.property("settingsFrom", "effective");
        // 檔案寫的和實際生效的不一樣：有人用別的設定檔，或這個 JDK 跟著 OS 的密碼政策走
        List<String> differs = new ArrayList<>();
        for (String key : KEYS) {
            String inFile = fromFile.get(key);
            String inEffect = effective.properties().get(key);
            // 兩邊都有值才比；比的時候不管空白（兩邊的換行與縮排不同），\s = 任何空白字元
            if (inFile != null && inEffect != null && !inFile.replaceAll("\\s", "").equals(inEffect.replaceAll("\\s", ""))) {
                differs.add(key);
            }
        }
        if (!differs.isEmpty()) {
            draft.property("differsFromFile", String.join(" ", differs));
        }
        if (!effective.protocols().isEmpty()) {
            draft.property("setting:tls.enabledProtocols", String.join(",", effective.protocols()));
            draft.property("setting:tls.enabledCipherSuites", String.join(" ", effective.cipherSuites()));
        }
        draft.identity.append("|effective|").append(differs).append('|').append(effective.protocols()).append('|').append(effective.cipherSuites());
    }

    /**
     * 服務有沒有用 -Djava.security.properties= 另外指定設定檔：系統屬性裡有這一行就記下路徑。
     * 例：「java.security.properties=/etc/kafka/extra.security」→ 屬性 securityPropertiesOverride = /etc/kafka/extra.security，
     * 身分字串接上「|override=路徑」。
     */
    private static void addOverride(Draft draft, List<String> systemProperties) {
        String prefix = "java.security.properties=";
        for (String line : systemProperties) {
            if (line.startsWith(prefix)) {
                String override = line.substring(prefix.length()).trim();
                draft.property("securityPropertiesOverride", override);
                draft.identity.append("|override=").append(override);
            }
        }
    }

    /**
     * OS 的密碼政策 → 一個 file 元件「OS 的 crypto-policies：等級」。政策、OS 版本、OpenSSL 版本都相同的主機併成一筆。
     *
     * 輸入固定三行（少於三行就略過）：
     * <pre>
     *   DEFAULT                                              update-crypto-policies --show
     *   Rocky Linux release 9.6 (Blue Onyx)                  /etc/redhat-release
     *   OpenSSL 3.2.2 4 Jun 2024 (Library: OpenSSL 3.2.2 …)   openssl version；括號那一段重複，拿掉
     * </pre>
     * 規則讀屬性 cbom:setting:crypto-policies。
     */
    static void osCrypto(ObjectNode bom, Raw.Host host, List<String> lines) {
        if (lines.size() < 3) {
            return;
        }
        String policy = lines.get(0).trim();
        String os = lines.get(1).trim();
        // regex：從「 (Library」到結尾全部拿掉
        String openssl = lines.get(2).trim().replaceAll(" \\(Library.*", "");
        ObjectNode file = Cdx.plain("file", "OS 的 crypto-policies：" + policy, "os-crypto|" + policy + "|" + os + "|" + openssl);
        Cdx.prop(file, "source", "jdk");
        Cdx.prop(file, "kind", "os-crypto-policy");
        Cdx.prop(file, "setting:crypto-policies", policy);
        Cdx.prop(file, "os", os);
        Cdx.prop(file, "openssl", openssl);
        Cdx.occurrence(file, host.name() + ":/etc/crypto-policies/config", host.role());
        Cdx.add(bom, file);
    }

    /** -XshowSettings:security:all 的三個部分裡用得到的：安全屬性、TLS 啟用的版本與 cipher suite。 */
    record Effective(Map<String, String> properties, List<String> protocols, List<String> cipherSuites) {
    }

    /**
     * 解析 java -XshowSettings:security:all 的輸出。輸出的樣子（縮排有意義）：
     * <pre>
     * Security settings:
     *     Security properties:
     *         jdk.tls.disabledAlgorithms=
     *             SSLv3,
     *             TLSv1,
     *         keystore.type=pkcs12
     *     Security TLS configuration (SunJSSE provider):
     *         Enabled Protocols:
     *             TLSv1.3
     *         Enabled Cipher Suites:
     *             TLS_AES_256_GCM_SHA384
     * </pre>
     * 靠每一行前面有幾個空白分辨它是什麼：
     * <pre>
     *   4 個空白      段落的標題（Security properties、Security TLS …）；其他段落不看
     *   8 個空白      properties 段：一個「名稱=值」；TLS 段：清單的標題（Enabled Protocols、Enabled Cipher Suites）
     *   超過 8 個     properties 段：上一個設定的值的下一行，用一個空白接在後面；TLS 段：清單裡的一項
     * </pre>
     * 上面的例子 → properties = {jdk.tls.disabledAlgorithms: "SSLv3, TLSv1,", keystore.type: "pkcs12"}、
     * protocols = [TLSv1.3]、cipherSuites = [TLS_AES_256_GCM_SHA384]。
     */
    static Effective parseEffective(List<String> lines) {
        Map<String, String> properties = new LinkedHashMap<>();
        List<String> protocols = new ArrayList<>();
        List<String> cipherSuites = new ArrayList<>();
        // 現在在哪一段："properties"、"tls"，或 ""（不看的段落）
        String section = "";
        // TLS 段裡現在在哪個清單："protocols"、"suites"，或 ""
        String list = "";
        // properties 段裡上一個設定的名稱（續行要接到它的值後面）
        String key = null;
        for (String line : lines) {
            if (line.isBlank()) {
                continue;
            }
            // 這一行前面有幾個空白
            int indent = line.length() - line.stripLeading().length();
            String text = line.trim();
            if (indent == 4) {
                // 段落的標題：決定接下來是哪一段
                if (text.startsWith("Security properties")) {
                    section = "properties";
                } else if (text.startsWith("Security TLS")) {
                    section = "tls";
                } else {
                    section = "";
                }
                key = null;
                list = "";
            } else if ("properties".equals(section) && indent == 8) {
                // 一個設定：第一個等號之前是名稱，之後是值（值可以是空的，內容在後面幾行）
                int equals = text.indexOf('=');
                if (equals > 0) {
                    key = text.substring(0, equals).trim();
                    properties.put(key, text.substring(equals + 1).trim());
                }
            } else if ("properties".equals(section) && indent > 8 && key != null) {
                // 續行：接在上一個設定的值後面，連續的空白縮成一個
                properties.put(key, (properties.get(key) + " " + text).trim().replaceAll("\\s+", " "));
            } else if ("tls".equals(section) && indent == 8) {
                // 清單的標題：決定接下來的項目放進哪個清單
                if (text.startsWith("Enabled Protocols")) {
                    list = "protocols";
                } else if (text.startsWith("Enabled Cipher Suites")) {
                    list = "suites";
                } else {
                    list = "";
                }
            } else if ("tls".equals(section) && indent > 8) {
                if ("protocols".equals(list)) {
                    protocols.add(text);
                } else if ("suites".equals(list)) {
                    cipherSuites.add(text);
                }
            }
        }
        return new Effective(properties, protocols, cipherSuites);
    }

    /**
     * 解析 java.security 檔：key=value，行尾反斜線表示下一行接續；# 開頭是註解。值裡連續的空白縮成一個。
     * <pre>
     * 例：
     *   # 註解
     *   jdk.tls.disabledAlgorithms=SSLv3, TLSv1, \
     *       TLSv1.1, RC4
     *   keystore.type=pkcs12
     * → {jdk.tls.disabledAlgorithms: "SSLv3, TLSv1, TLSv1.1, RC4", keystore.type: "pkcs12"}
     * </pre>
     */
    static Map<String, String> parse(List<String> lines) {
        Map<String, String> settings = new LinkedHashMap<>();
        // 還沒結束的那一個設定（前面幾行以反斜線結尾，內容先放在這裡）
        StringBuilder pending = new StringBuilder();
        for (String raw : lines) {
            String line = raw.trim();
            // 註解與空行跳過；但正在接續行的時候不跳（續行的內容可能剛好是 # 開頭）
            if (pending.length() == 0 && (line.startsWith("#") || line.isEmpty())) {
                continue;
            }
            // 行尾是反斜線：去掉它，這一行先存起來，等下一行
            if (line.endsWith("\\")) {
                pending.append(line, 0, line.length() - 1).append(' ');
                continue;
            }
            // 一個設定結束了：把存起來的幾行接成一整行，以第一個等號分成名稱與值
            pending.append(line);
            String whole = pending.toString();
            pending.setLength(0);
            int equals = whole.indexOf('=');
            if (equals > 0) {
                settings.put(whole.substring(0, equals).trim(), whole.substring(equals + 1).trim().replaceAll("\\s+", " "));
            }
        }
        return settings;
    }
}
