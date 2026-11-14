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
 * 函式庫層（手冊第 33 章那張表的「函式庫」那一列）：syft 列出的 jar 裡，挑出密碼函式庫 → CBOM。
 *
 * 輸入：
 *   raw/shared/jars/groups.txt          每行「jar 清單雜湊 主機」；雜湊相同的主機裝的 jar 完全一樣，歸成一組
 *                                       例：「3f9a1c0b77de kb01」
 *   raw/shared/jars/sbom-&lt;雜湊&gt;.json    每組的 SBOM（CycloneDX）。Confluent Platform：每組取一台的 jar 用 syft 掃出來的；
 *                                       web app：建置時 cyclonedx-maven-plugin 產生的
 * 產出：library 元件（名稱、版本、purl），出現位置是該組的每一台主機（位置的寫法由盤點對象決定：Profile.libraryLocation）；
 *       屬性 cbom:source=library、cbom:kind=crypto-library。
 * 誰呼叫：Main（經 Layers）。Confluent Platform 與 web app 都用這一層（web app 只有一組、一台叫 app）。
 *
 * 原廠程式內部怎麼用這些函式庫看不到（Confluent Platform 沒有原始碼）；這一層回答的是「帶了哪些密碼函式庫、什麼版本」。
 */
final class LibraryLayer implements Layer {

    /**
     * 判斷是不是密碼函式庫：「名稱 + 空白 + purl」轉成小寫後，裡面出現下面任何一段字就算。新增函式庫時在這裡加（用 | 隔開）。
     * <pre>
     * 例：
     *   bcprov-jdk18on（pkg:maven/org.bouncycastle/bcprov-jdk18on@1.78）  → 是（bouncycastle、bcprov 都符合）
     *   bc-fips                                                          → 是
     *   nimbus-jose-jwt                                                  → 是（nimbus-jose）
     *   netty-tcnative-boringssl-static                                  → 是（tcnative、boringssl）
     *   kafka-clients                                                    → 不是
     * regex 的寫法：
     *   \b            字的邊界。「\bbc-fips」= bc-fips 前面不能緊接英數字；「\btink\b」= 單獨的 tink 這個字（不會抓到 tinker）
     *   corretto.?crypto   中間可以有一個任意字元：corretto-crypto、correttocrypto 都算
     *   crypto\.tink       句點要寫成 \.（com.google.crypto.tink）
     * </pre>
     */
    private static final Pattern CRYPTO_LIBRARY = Pattern.compile(
        "bouncycastle|\\bbc-fips|bcpkix|bctls|bcutil|bcprov|bcpg|conscrypt|corretto.?crypto|"
            + "crypto\\.tink|\\btink\\b|jose4j|nimbus-jose|jjwt|java-jwt|jbcrypt|bcrypt|scrypt|argon2|spring-security-crypto|"
            + "tcnative|boringssl|wildfly-openssl|commons-crypto|jasypt|kerby|kerb-crypto");

    @Override
    public String id() {
        return "libraries";
    }

    @Override
    public String title() {
        return "密碼函式庫（SBOM）";
    }

    @Override
    public ObjectNode convert(Raw raw) throws IOException {
        return run(raw);
    }

    /** 讀 groups.txt 把主機分組，每一組讀它的 SBOM，交給 group() 挑函式庫。沒有 groups.txt 或某組沒有 SBOM 都不算錯（那一組就沒有元件）。 */
    static ObjectNode run(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        // 函式庫在主機上的哪裡，由盤點對象決定（Confluent Platform 與 web app 不一樣）
        Profile profile = Profile.of(raw);
        Path dir = raw.shared().resolve("jars");
        // 雜湊 → 這一組的主機。例：{"3f9a1c0b77de": [kb01, kb02, kb03, kb04]}
        Map<String, List<String>> groups = new LinkedHashMap<>();
        for (String line : Raw.lines(dir.resolve("groups.txt"))) {
            String[] parts = line.trim().split("\\s+");
            // 剛好兩欄（雜湊、主機）才算，空行與格式不對的行略過
            if (parts.length == 2) {
                groups.computeIfAbsent(parts[0], k -> new ArrayList<>()).add(parts[1]);
            }
        }
        for (Map.Entry<String, List<String>> group : groups.entrySet()) {
            Path sbom = dir.resolve("sbom-" + group.getKey() + ".json");
            if (Files.isRegularFile(sbom)) {
                group(bom, Cdx.read(sbom), group.getValue(), group.getKey(), profile);
            }
        }
        return bom;
    }

    /**
     * 一組的 SBOM → 密碼函式庫元件。sbom 是 SBOM（CycloneDX），hosts 是這一組的主機，digest 是這一組的雜湊，
     * profile 是盤點對象（決定出現位置怎麼寫）。
     *
     * 判斷與結果：
     *   SBOM 的元件 type 不是 library → 略過
     *   名稱與 purl 都不符合 CRYPTO_LIBRARY → 略過（不是密碼函式庫）
     *   名稱或 purl 裡有 fips → 多一個屬性 cbom:fipsVariant=true（FIPS 認證的版本，例如 bc-fips）
     *   syft 不知道版本時會寫 UNKNOWN → 不寫 version 欄位
     * 同名同版本的函式庫在不同組都有時，併成一筆（身分是「lib|名稱|版本」），出現位置累加。
     */
    static void group(ObjectNode bom, JsonNode sbom, List<String> hosts, String digest, Profile profile) {
        for (JsonNode component : sbom.path("components")) {
            if (!"library".equals(component.path("type").asText())) {
                continue;
            }
            String name = component.path("name").asText();
            String purl = component.path("purl").asText("");
            // 要比對的字串：名稱與 purl 接在一起、轉小寫
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
            // 每台主機一個出現位置。例（Confluent Platform）：「kb01:/usr/share/java」，說明「jar 組 3f9a1c0b77de」
            for (String host : hosts) {
                String[] where = profile.libraryLocation(host, digest);
                Cdx.occurrence(library, where[0], where[1]);
            }
            Cdx.add(bom, library);
        }
    }
}
