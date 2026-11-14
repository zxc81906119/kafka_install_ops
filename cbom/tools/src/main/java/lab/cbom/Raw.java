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
 * 收集腳本產生的原料目錄（cbom/cbom-collect.sh 或 cbom/webapp/webapp-collect.sh 的輸出）。
 * 這個類別只讀 collect.env 與提供路徑；每個工具的輸出檔由各自的 Layer 讀。誰呼叫：Main 建立，傳給每個 Layer 與 BomStep。
 *
 * <pre>
 * raw/collect.env             這次收集的範圍，一行一個「名稱=值」（# 開頭是註解）
 * raw/&lt;主機&gt;/                 每台一個目錄
 * raw/shared/                 不屬於單一主機的原料（平台共用、jar 分組、cbomkit-theia 的輸出）
 * </pre>
 *
 * collect.env 的欄位（程式用 get("名稱") 讀；沒有的欄位讀到空字串）：
 * <pre>
 *   PROFILE        盤點對象：cp 或 webapp；沒寫當成 cp（Profile.of）
 *   DOMAIN         網域，例：poc.lab（fqdn() 用）
 *   ENV            環境名稱，例：lab（CBOM 主角的名稱）
 *   COLLECTED_AT   收集時間（metadata.timestamp）
 *   ROLES          這次選了哪些元件，空白分隔，例：controller broker rest c3 shared
 *   ALL_ROLES      全部有哪些元件（和 ROLES 比，判斷是完整還是部分盤點）
 *   HOSTS          「主機:元件」的清單，空白分隔，例：kc01:controller kb01:broker rest01:rest
 *   CP_VERSION     盤點對象的版本。Confluent Platform 是 confluent-server 的版本；web app 也用這個欄位放應用程式的版本
 *   SUBJECT_NAME   只有 web app 有：CBOM 主角的名稱
 *   TOOLS          用了哪些工具，「名稱 版本, 名稱 版本」（metadata.tools）
 *   JFR_SECONDS    執行期證據錄了幾秒；空的 = 沒有錄
 * </pre>
 */
final class Raw {

    /**
     * 一台主機：短名稱、元件。元件就是 HOSTS 裡冒號後面那個字：
     * Confluent Platform 是 controller、broker、rest、c3；web app 由它的收集腳本決定。
     */
    record Host(String name, String role) {
    }

    /** 原料目錄。 */
    final Path dir;
    private final Map<String, String> env = new LinkedHashMap<>();
    private final List<Host> hosts = new ArrayList<>();

    /** 讀 collect.env；沒有這個檔就不是原料目錄，丟例外。 */
    Raw(Path dir) throws IOException {
        this.dir = dir;
        Path file = dir.resolve("collect.env");
        if (!Files.isRegularFile(file)) {
            throw new IOException("找不到 " + file + "：這不是收集腳本產生的原料目錄");
        }
        for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
            // 以第一個等號分成名稱與值；註解與沒有等號（或等號在最前面）的行跳過
            int equals = line.indexOf('=');
            if (line.startsWith("#") || equals < 1) {
                continue;
            }
            env.put(line.substring(0, equals).trim(), line.substring(equals + 1).trim());
        }
        // HOSTS 例：「kc01:controller kb01:broker」→ Host(kc01, controller)、Host(kb01, broker)；不是「名稱:元件」兩段的略過
        for (String pair : get("HOSTS").split("\\s+")) {
            String[] parts = pair.split(":");
            if (parts.length == 2) {
                hosts.add(new Host(parts[0], parts[1]));
            }
        }
    }

    /** collect.env 的一個欄位；沒有這個欄位回空字串（不會是 null）。 */
    String get(String name) {
        return env.getOrDefault(name, "");
    }

    /** 這次收集的主機，照 HOSTS 寫的順序。 */
    List<Host> hosts() {
        return hosts;
    }

    /** 短名稱 → 完整名稱。例：kb01 → kb01.poc.lab（DOMAIN=poc.lab）。 */
    String fqdn(String host) {
        return host + "." + get("DOMAIN");
    }

    /** 主機的元件；不認得的主機（例如操作機 ops02，它不在 HOSTS 裡）回 shared。 */
    String roleOf(String host) {
        for (Host one : hosts) {
            if (one.name().equals(host)) {
                return one.role();
            }
        }
        return "shared";
    }

    /** 這次有沒有選這個元件（ROLES 裡有沒有這個字）。例：hasRole("shared") = 有沒有收平台共用的原料。 */
    boolean hasRole(String role) {
        return List.of(get("ROLES").split("\\s+")).contains(role);
    }

    /** 選到的元件是不是全部（ROLES 包含 ALL_ROLES 的每一個）。是 = 完整盤點，不是 = 部分盤點。 */
    boolean fullScope() {
        return List.of(get("ROLES").split("\\s+")).containsAll(List.of(get("ALL_ROLES").split("\\s+")));
    }

    /** 某台主機的原料目錄：raw/&lt;主機&gt;。 */
    Path hostDir(String host) {
        return dir.resolve(host);
    }

    /** 不屬於單一主機的原料目錄：raw/shared。 */
    Path shared() {
        return dir.resolve("shared");
    }

    /** 讀一個文字檔的每一行（UTF-8）；檔案不存在回空的清單，不算錯（那一項原料這次沒有收）。 */
    static List<String> lines(Path file) throws IOException {
        if (!Files.isRegularFile(file)) {
            return List.of();
        }
        return Files.readAllLines(file, StandardCharsets.UTF_8);
    }
}
