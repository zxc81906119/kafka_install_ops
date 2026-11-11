package lab.cbom;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 第 ② 層：JDK 與 OS 的密碼設定 → CBOM。
 *
 * 輸入：
 *   raw/&lt;主機&gt;/java.security     JDK 的安全設定檔（停用哪些演算法、provider 順序）
 *   raw/&lt;主機&gt;/java-version.txt  java -version 的輸出，加上 /opt/java/current 指到的目錄
 *   raw/&lt;主機&gt;/os-crypto.txt     crypto-policies 的等級、OS 版本、OpenSSL 版本
 * 產出：file 元件，內容相同的主機合併成一筆（看出現位置就知道哪台不一樣）。
 */
final class JdkCommand {

    /** java.security 裡和密碼學盤點有關的設定；值可以用反斜線續行。 */
    private static final List<String> KEYS = List.of(
        "jdk.tls.disabledAlgorithms", "jdk.tls.legacyAlgorithms", "jdk.tls.namedGroups", "jdk.tls.keyLimits",
        "jdk.certpath.disabledAlgorithms", "jdk.jar.disabledAlgorithms", "jdk.security.legacyAlgorithms",
        "jdk.disabled.namedCurves", "keystore.type", "securerandom.source");

    private JdkCommand() {
    }

    static ObjectNode run(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        for (Raw.Host host : raw.hosts()) {
            Path dir = raw.hostDir(host.name());
            if (!Files.isDirectory(dir)) {
                continue;
            }
            javaSecurity(bom, host, Raw.lines(dir.resolve("java.security")), Raw.lines(dir.resolve("java-version.txt")));
            osCrypto(bom, host, Raw.lines(dir.resolve("os-crypto.txt")));
        }
        return bom;
    }

    static void javaSecurity(ObjectNode bom, Raw.Host host, List<String> lines, List<String> versionLines) {
        if (lines.isEmpty()) {
            return;
        }
        Map<String, String> settings = parse(lines);
        String version = versionLines.isEmpty() ? "" : versionLines.get(0).replace("openjdk version ", "").replace("\"", "");
        String home = versionLines.isEmpty() ? "" : versionLines.get(versionLines.size() - 1);

        StringBuilder identity = new StringBuilder("jdk|" + version);
        ObjectNode file = Cdx.plain("file", "JDK " + version + " 的 java.security", "placeholder");
        Cdx.prop(file, "source", "jdk");
        Cdx.prop(file, "kind", "java-security");
        Cdx.prop(file, "javaVersion", version);
        for (String key : KEYS) {
            String value = settings.get(key);
            if (value != null) {
                Cdx.prop(file, "setting:" + key, value);
                identity.append('|').append(key).append('=').append(value);
            }
        }
        StringBuilder providers = new StringBuilder();
        for (int i = 1; settings.containsKey("security.provider." + i); i++) {
            providers.append(i > 1 ? " " : "").append(settings.get("security.provider." + i));
        }
        Cdx.prop(file, "setting:security.providers", providers.toString());
        identity.append("|providers=").append(providers);

        file.put("bom-ref", Cdx.ref("file", identity.toString()));
        Cdx.occurrence(file, host.name() + ":" + home + "/conf/security/java.security", host.role());
        Cdx.add(bom, file);
    }

    static void osCrypto(ObjectNode bom, Raw.Host host, List<String> lines) {
        if (lines.size() < 3) {
            return;
        }
        String policy = lines.get(0).trim();
        String os = lines.get(1).trim();
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

    /** key=value，行尾反斜線表示下一行接續；# 開頭是註解。 */
    static Map<String, String> parse(List<String> lines) {
        Map<String, String> settings = new LinkedHashMap<>();
        StringBuilder pending = new StringBuilder();
        for (String raw : lines) {
            String line = raw.trim();
            if (pending.length() == 0 && (line.startsWith("#") || line.isEmpty())) {
                continue;
            }
            if (line.endsWith("\\")) {
                pending.append(line, 0, line.length() - 1).append(' ');
                continue;
            }
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
