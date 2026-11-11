package lab.cbom;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 收集腳本產生的原料目錄。
 *
 * <pre>
 * raw/collect.env             這次收集的範圍：DOMAIN、ENV、COLLECTED_AT、ROLES（選了哪些）、ALL_ROLES（全部有哪些）、
 *                             HOSTS（主機:元件 …）
 * raw/&lt;主機&gt;/                 每台一個目錄
 * raw/shared/                 不屬於單一主機的原料（平台共用、jar 分組、cbomkit-theia 的輸出）
 * </pre>
 */
final class Raw {

    /** 一台主機：短名稱、元件（controller、broker、rest、c3）。 */
    record Host(String name, String role) {
    }

    final Path dir;
    private final Map<String, String> env = new LinkedHashMap<>();
    private final List<Host> hosts = new ArrayList<>();

    Raw(Path dir) throws IOException {
        this.dir = dir;
        Path file = dir.resolve("collect.env");
        if (!Files.isRegularFile(file)) {
            throw new IOException("找不到 " + file + "：這不是收集腳本產生的原料目錄");
        }
        for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
            int equals = line.indexOf('=');
            if (line.startsWith("#") || equals < 1) {
                continue;
            }
            env.put(line.substring(0, equals).trim(), line.substring(equals + 1).trim());
        }
        for (String pair : get("HOSTS").split("\\s+")) {
            String[] parts = pair.split(":");
            if (parts.length == 2) {
                hosts.add(new Host(parts[0], parts[1]));
            }
        }
    }

    String get(String name) {
        return env.getOrDefault(name, "");
    }

    List<Host> hosts() {
        return hosts;
    }

    String fqdn(String host) {
        return host + "." + get("DOMAIN");
    }

    /** 主機的元件；不認得的主機（例如 ops02）回 shared。 */
    String roleOf(String host) {
        for (Host one : hosts) {
            if (one.name().equals(host)) {
                return one.role();
            }
        }
        return "shared";
    }

    boolean hasRole(String role) {
        return List.of(get("ROLES").split("\\s+")).contains(role);
    }

    /** 選到的元件是不是全部。 */
    boolean fullScope() {
        return List.of(get("ROLES").split("\\s+")).containsAll(List.of(get("ALL_ROLES").split("\\s+")));
    }

    Path hostDir(String host) {
        return dir.resolve(host);
    }

    Path shared() {
        return dir.resolve("shared");
    }

    static List<String> lines(Path file) throws IOException {
        if (!Files.isRegularFile(file)) {
            return List.of();
        }
        return Files.readAllLines(file, StandardCharsets.UTF_8);
    }
}
