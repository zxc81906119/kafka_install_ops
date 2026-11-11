package lab.cbom;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 函式庫層：syft 列出的 jar 裡，挑出密碼函式庫 → CBOM。
 *
 * 輸入：
 *   raw/shared/jars/groups.txt          每行「jar 清單雜湊 主機」；雜湊相同的主機裝的 jar 完全一樣，歸成一組
 *   raw/shared/jars/sbom-&lt;雜湊&gt;.json    每組取一台用 syft 掃出來的 SBOM（CycloneDX）
 * 產出：library 元件（名稱、版本、purl），出現位置是該組的每一台主機。
 *
 * 原廠程式內部怎麼用這些函式庫看不到（沒有原始碼）；這一層回答的是「帶了哪些密碼函式庫、什麼版本」。
 */
final class LibsCommand {

    /** 名稱或 purl 符合就算密碼函式庫。新增函式庫時在這裡加。 */
    private static final Pattern CRYPTO_LIBRARY = Pattern.compile(
        "bouncycastle|\\bbc-fips|bcpkix|bctls|bcutil|bcprov|bcpg|conscrypt|corretto.?crypto|"
            + "crypto\\.tink|\\btink\\b|jose4j|nimbus-jose|jjwt|java-jwt|jbcrypt|bcrypt|scrypt|argon2|"
            + "tcnative|boringssl|wildfly-openssl|commons-crypto|jasypt|kerby|kerb-crypto");

    private LibsCommand() {
    }

    static ObjectNode run(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        Path dir = raw.shared().resolve("jars");
        Map<String, List<String>> groups = new LinkedHashMap<>();
        for (String line : Raw.lines(dir.resolve("groups.txt"))) {
            String[] parts = line.trim().split("\\s+");
            if (parts.length == 2) {
                groups.computeIfAbsent(parts[0], k -> new ArrayList<>()).add(parts[1]);
            }
        }
        for (Map.Entry<String, List<String>> group : groups.entrySet()) {
            Path sbom = dir.resolve("sbom-" + group.getKey() + ".json");
            if (Files.isRegularFile(sbom)) {
                group(bom, Cdx.read(sbom), group.getValue(), group.getKey());
            }
        }
        return bom;
    }

    static void group(ObjectNode bom, JsonNode sbom, List<String> hosts, String digest) {
        for (JsonNode component : sbom.path("components")) {
            if (!"library".equals(component.path("type").asText())) {
                continue;
            }
            String name = component.path("name").asText();
            String purl = component.path("purl").asText("");
            String haystack = (name + " " + purl).toLowerCase(Locale.ROOT);
            if (!CRYPTO_LIBRARY.matcher(haystack).find()) {
                continue;
            }
            String version = component.path("version").asText("");
            ObjectNode library = Cdx.plain("library", name, "lib|" + name + "|" + version);
            if (!version.isEmpty() && !"UNKNOWN".equals(version)) {
                library.put("version", version);
            }
            if (!purl.isEmpty()) {
                library.put("purl", purl);
            }
            Cdx.prop(library, "source", "library");
            Cdx.prop(library, "kind", "crypto-library");
            if (haystack.contains("fips")) {
                Cdx.prop(library, "fipsVariant", "true");
            }
            for (String host : hosts) {
                Cdx.occurrence(library, host + ":/usr/share/java", "jar 組 " + digest);
            }
            Cdx.add(bom, library);
        }
    }
}
