package lab.cbom;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.interfaces.ECPublicKey;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 第 ③ 層（手冊第 33 章那張表的編號）：平台設定 → CBOM。只有 Confluent Platform 用這一層。
 *
 * 輸入（都不含密碼與私鑰；密碼類的值在主機上就遮掉了）：
 *   raw/&lt;主機&gt;/platform-config.properties   服務實際用的 properties 裡和密碼學有關的設定
 *   raw/&lt;主機&gt;/secret-protection.properties Secret Protection 的非機密參數（金鑰長度、迭代次數）
 *   raw/&lt;主機&gt;/mds-token-public.pem         MDS token 的驗證公鑰
 *   raw/&lt;主機&gt;/ssl-files.list               /etc/confluent/ssl 底下有哪些檔（權限、擁有者、大小）
 *   raw/shared/scram-users.txt              SCRAM 帳號的機制與迭代次數
 *   raw/shared/ssh-host-keys.txt、ssh-client-key.txt   ssh 金鑰的類型與長度
 * 產出：
 *   file 元件          每台的設定檔一筆，密碼學相關的設定放在屬性（規則會檢查 TLS 版本、主機名驗證等）
 *   protocol 元件      SASL 機制（SCRAM-SHA-512、OAUTHBEARER、PLAIN）、ssh
 *   algorithm 元件     token 簽章演算法、Secret Protection 的加密與金鑰衍生
 *   related-crypto-material 元件   MDS token 公鑰、ssh 金鑰
 * 屬性 cbom:source 都是 config。誰呼叫：Main（經 Layers）。
 *
 * 這些原料檔是收集腳本（cbom/cbom-collect.sh）在主機上整理出來的文字檔，格式寫在下面每個方法的說明裡。
 */
final class PlatformConfigLayer implements Layer {

    @Override
    public String id() {
        return "config";
    }

    @Override
    public String title() {
        return "平台設定（Confluent Platform 的 properties、SCRAM、ssh 金鑰）";
    }

    @Override
    public ObjectNode convert(Raw raw) throws IOException {
        return run(raw);
    }

    /** 每台主機的四種原料各交給一個方法；這次有收平台共用的原料（ROLES 裡有 shared）時，再處理 SCRAM 帳號與 ssh 金鑰。 */
    static ObjectNode run(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        for (Raw.Host host : raw.hosts()) {
            Path dir = raw.hostDir(host.name());
            if (!Files.isDirectory(dir)) {
                continue;
            }
            platformConfig(bom, host, Raw.lines(dir.resolve("platform-config.properties")));
            secretProtection(bom, host, Raw.lines(dir.resolve("secret-protection.properties")));
            tokenPublicKey(bom, host, dir.resolve("mds-token-public.pem"));
            keyFiles(bom, host, Raw.lines(dir.resolve("ssl-files.list")));
        }
        if (raw.hasRole("shared")) {
            scramUsers(bom, Raw.lines(raw.shared().resolve("scram-users.txt")));
            // 第三個參數：true = 主機金鑰（每行開頭多一欄主機名稱），false = 操作機的用戶端金鑰
            sshKeys(bom, Raw.lines(raw.shared().resolve("ssh-host-keys.txt")), true);
            sshKeys(bom, Raw.lines(raw.shared().resolve("ssh-client-key.txt")), false);
        }
        return bom;
    }

    /**
     * 一台主機的設定 → 一個 file 元件（每個設定寫成屬性 cbom:setting:名稱），加上從設定值看得出來的 protocol、algorithm 元件。
     *
     * 輸入是 properties 的 key = value；第一行註解「# file=路徑」是設定檔在主機上的位置。例：
     * <pre>
     *   # file=/etc/kafka/server.properties
     *   ssl.enabled.protocols=TLSv1.3,TLSv1.2
     *   sasl.enabled.mechanisms=SCRAM-SHA-512,OAUTHBEARER
     *   ssl.keystore.password=&lt;遮蔽&gt;
     * </pre>
     * → file 元件「kb01:/etc/kafka/server.properties」，屬性 cbom:setting:ssl.enabled.protocols = TLSv1.3,TLSv1.2 …
     * → protocol 元件「SASL/SCRAM-SHA-512」「SASL/OAUTHBEARER」
     * TLS 版本、主機名驗證這類設定不另外產生元件：規則直接讀 file 元件的 cbom:setting:… 屬性。
     */
    static void platformConfig(ObjectNode bom, Raw.Host host, List<String> lines) {
        if (lines.isEmpty()) {
            return;
        }
        // 沒有「# file=」那一行時，位置就寫「主機:properties」
        String path = "properties";
        Map<String, String> settings = new LinkedHashMap<>();
        for (String line : lines) {
            if (line.startsWith("# file=")) {
                path = line.substring("# file=".length()).trim();
                continue;
            }
            // 以第一個等號分成名稱與值；註解與沒有等號（或等號在最前面）的行跳過
            int equals = line.indexOf('=');
            if (line.startsWith("#") || equals < 1) {
                continue;
            }
            settings.put(line.substring(0, equals).trim(), line.substring(equals + 1).trim());
        }
        String location = host.name() + ":" + path;

        ObjectNode file = Cdx.plain("file", location, "config|" + location);
        Cdx.prop(file, "source", "config");
        Cdx.prop(file, "kind", "platform-config");
        for (Map.Entry<String, String> setting : settings.entrySet()) {
            Cdx.prop(file, "setting:" + setting.getKey(), setting.getValue());
        }
        Cdx.occurrence(file, location, host.role());
        Cdx.add(bom, file);

        // 再看一遍設定：有兩類設定值本身就是一個協定或演算法，另外產生元件
        for (Map.Entry<String, String> setting : settings.entrySet()) {
            String key = setting.getKey();
            String value = setting.getValue();
            // 空的值、被遮掉的值（收集腳本把密碼類的值換成「<遮蔽>」，所以是 < 開頭）不看
            if (value.isEmpty() || value.startsWith("<")) {
                continue;
            }
            // 第一類：SASL 機制。設定名稱的結尾是下面四種之一（前面可以有 listener 的前綴，所以用 endsWith）；
            // 值可以是逗號分隔的好幾個。例：sasl.enabled.mechanisms=SCRAM-SHA-512,OAUTHBEARER → 兩個 protocol 元件
            if (key.endsWith("sasl.enabled.mechanisms") || key.endsWith("sasl.mechanism")
                || key.endsWith("sasl.mechanism.inter.broker.protocol") || key.endsWith("sasl.mechanism.controller.protocol")) {
                for (String mechanism : value.split(",")) {
                    sasl(bom, mechanism.trim(), location, key);
                }
            }
            // 第二類：MDS token（JWT）的簽章演算法。例：…token.signature.algorithm=RS256 → algorithm 元件「RS256」（家族 RSA）
            if (key.endsWith("token.signature.algorithm")) {
                ObjectNode algorithm = Cdx.asset("algorithm", value, "token-sig|" + value);
                Algo.apply(algorithm, value);
                Cdx.prop(algorithm, "source", "config");
                Cdx.prop(algorithm, "use", "MDS token 簽章（JWT）");
                Cdx.occurrence(algorithm, location, key);
                Cdx.add(bom, algorithm);
            }
        }
    }

    /**
     * 一個 SASL 機制 → protocol 元件「SASL/機制」（CycloneDX 沒有 SASL 這個協定類型，所以 type 寫 other）。
     * 身分字串是「sasl|機制」，和 scramUsers() 用的相同：同一個機制不管在幾台、幾個設定出現，加上 SCRAM 帳號的統計，都併成一筆。
     * 規則讀屬性 cbom:saslMechanism。
     */
    private static void sasl(ObjectNode bom, String mechanism, String location, String settingKey) {
        if (mechanism.isEmpty()) {
            return;
        }
        ObjectNode protocol = Cdx.asset("protocol", "SASL/" + mechanism, "sasl|" + mechanism);
        ObjectNode properties = Cdx.crypto(protocol, "protocolProperties");
        properties.put("type", "other");
        Cdx.prop(protocol, "source", "config");
        Cdx.prop(protocol, "saslMechanism", mechanism);
        Cdx.occurrence(protocol, location, settingKey);
        Cdx.add(bom, protocol);
    }

    /**
     * Confluent Secret Protection：AES-CBC 加密設定值，資料金鑰用 PBKDF2 從 master key 衍生（原廠文件）。
     *
     * 輸入是 security.properties 裡 _metadata 開頭的非機密欄位。例：
     * <pre>
     *   _metadata.symmetric_key.0.length=32
     *   _metadata.symmetric_key.0.iterations=1000
     * </pre>
     * → algorithm 元件「AES-256-CBC」（長度的單位是 byte，乘 8 變成位元：32 → 256）
     * → algorithm 元件「PBKDF2」，屬性 cbom:iterations = 1000
     * 沒有 length 那一行（這台沒有用 Secret Protection）就什麼都不產生。
     */
    static void secretProtection(ObjectNode bom, Raw.Host host, List<String> lines) {
        Map<String, String> metadata = new TreeMap<>();
        for (String line : lines) {
            int equals = line.indexOf('=');
            if (equals > 0) {
                metadata.put(line.substring(0, equals).trim(), line.substring(equals + 1).trim());
            }
        }
        String length = metadata.get("_metadata.symmetric_key.0.length");
        if (length == null) {
            return;
        }
        String location = host.name() + ":/etc/confluent/secrets/security.properties";
        int bits = Integer.parseInt(length) * 8;

        ObjectNode cipher = Cdx.asset("algorithm", "AES-" + bits + "-CBC", "secret-protection|AES|" + bits);
        Algo.apply(cipher, "AES-" + bits + "-CBC");
        Cdx.prop(cipher, "source", "config");
        Cdx.prop(cipher, "use", "Secret Protection 加密設定檔裡的密碼");
        Cdx.occurrence(cipher, location, "symmetric_key.length=" + length + " bytes");
        Cdx.add(bom, cipher);

        String iterations = metadata.getOrDefault("_metadata.symmetric_key.0.iterations", "");
        ObjectNode kdf = Cdx.asset("algorithm", "PBKDF2", "secret-protection|PBKDF2|" + iterations);
        Algo.apply(kdf, "PBKDF2");
        Cdx.prop(kdf, "source", "config");
        Cdx.prop(kdf, "use", "Secret Protection 從 master key 衍生資料金鑰");
        Cdx.prop(kdf, "iterations", iterations);
        Cdx.occurrence(kdf, location, "iterations=" + iterations);
        Cdx.add(bom, kdf);
    }

    /**
     * MDS token 的驗證公鑰（PEM 的 PUBLIC KEY）→ 一個演算法元件加一個公鑰元件（見 publicKey()）。
     * 檔案不存在、或內容不是「BEGIN PUBLIC KEY」的 PEM 就略過。
     *
     * 做法：去掉 PEM 的頭尾兩行與換行，剩下的 base64 解成位元組，依序當成 RSA、EC 公鑰試著讀，讀得進去的那一種就是它的演算法。
     *   RSA → 演算法 RSA，長度是模數的位元數（例：2048）
     *   EC  → 演算法 ECDSA，長度是曲線的位元數（例：256）
     *   兩種都讀不進去 → 演算法 unknown、長度 0
     * 指紋：base64 字串的 SHA-256（只是用來分辨是不是同一把，不是 ssh 那種標準指紋）。
     */
    static void tokenPublicKey(ObjectNode bom, Raw.Host host, Path pem) throws IOException {
        if (!Files.isRegularFile(pem)) {
            return;
        }
        String text = Files.readString(pem, StandardCharsets.UTF_8);
        if (!text.contains("BEGIN PUBLIC KEY")) {
            return;
        }
        // 第一個 regex 去掉「-----BEGIN PUBLIC KEY-----」「-----END PUBLIC KEY-----」這兩行，第二個去掉所有空白與換行
        String base64 = text.replaceAll("-----[A-Z ]+-----", "").replaceAll("\\s", "");
        byte[] der = Base64.getDecoder().decode(base64);
        String algorithm = "unknown";
        int bits = 0;
        for (String candidate : new String[] {"RSA", "EC"}) {
            try {
                PublicKey key = KeyFactory.getInstance(candidate).generatePublic(new X509EncodedKeySpec(der));
                if (key instanceof RSAPublicKey rsa) {
                    algorithm = "RSA";
                    bits = rsa.getModulus().bitLength();
                } else if (key instanceof ECPublicKey ec) {
                    algorithm = "ECDSA";
                    bits = ec.getParams().getCurve().getField().getFieldSize();
                }
                break;
            } catch (Exception notThisAlgorithm) {
                // 換下一種試
            }
        }
        String location = host.name() + ":/etc/confluent/ssl/mds-token-public.pem";
        publicKey(bom, algorithm, bits, Cdx.sha256(base64), "MDS token 驗證公鑰", location, "config");
    }

    /**
     * 一把公鑰 → 兩個元件：
     *   algorithm 元件                它用的演算法，名稱「演算法-長度」（例：RSA-2048、ED25519-256；長度 0 時只有演算法名稱）。
     *                                 同名的在所有主機併成一筆。
     *   related-crypto-material 元件  這把公鑰本身（type = public-key），用 algorithmRef 指到上面那個演算法元件。
     *                                 身分是指紋：同一把金鑰出現在幾個地方都只有一筆。
     * 參數：algorithm 演算法名稱、bits 長度（0 = 不知道）、fingerprint 指紋、use 用途（也當元件名稱的前半與位置的說明）、
     *       location 出現位置、source 寫進 cbom:source 的來源名稱。
     * 公鑰元件也寫 cbom:family 與 cbom:keySize，規則才能直接判斷這把金鑰夠不夠長、是不是量子脆弱。
     * 屬性 cbom:fingerprint 只留指紋的前 16 個字（顯示用）。
     */
    private static void publicKey(ObjectNode bom, String algorithm, int bits, String fingerprint, String use,
        String location, String source) {
        String algorithmName = algorithm + (bits > 0 ? "-" + bits : "");
        ObjectNode algorithmComponent = Cdx.asset("algorithm", algorithmName, "key-alg|" + algorithmName);
        Algo.apply(algorithmComponent, algorithmName);
        Cdx.prop(algorithmComponent, "source", source);
        Cdx.prop(algorithmComponent, "use", use);
        Cdx.occurrence(algorithmComponent, location, use);
        Cdx.add(bom, algorithmComponent);

        ObjectNode key = Cdx.asset("related-crypto-material", use + "（" + algorithmName + "）", "public-key|" + fingerprint);
        ObjectNode properties = Cdx.crypto(key, "relatedCryptoMaterialProperties");
        properties.put("type", "public-key");
        properties.put("algorithmRef", algorithmComponent.get("bom-ref").asText());
        if (bits > 0) {
            properties.put("size", bits);
        }
        Cdx.prop(key, "source", source);
        Cdx.prop(key, "use", use);
        Cdx.prop(key, "fingerprint", fingerprint.substring(0, Math.min(16, fingerprint.length())));
        Algo.Info info = Algo.describe(algorithmName);
        Cdx.prop(key, "family", info.family());
        if (bits > 0) {
            Cdx.prop(key, "keySize", String.valueOf(bits));
        }
        Cdx.occurrence(key, location, use);
        Cdx.add(bom, key);
    }

    /**
     * /etc/confluent/ssl 的檔案清單：「權限 擁有者 大小 路徑」。只記有哪些 keystore 與私鑰檔、權限對不對，不讀內容。
     * 例：「640 cp-kafka:confluent 4096 /etc/confluent/ssl/kb01.keystore.p12」
     *
     * 依檔名判斷是哪一種（寫進屬性 cbom:kind），判不出來的檔（.crt、.pem 憑證等）略過：
     *   結尾是 .p12／.jks／.bcfks，路徑裡有 truststore → truststore
     *   結尾是 .p12／.jks／.bcfks，其他                 → keystore
     *   結尾是 .key，或路徑裡有 keypair               → private-key-file
     * 每台的每個檔各一個 file 元件，屬性 cbom:mode（權限）、cbom:owner（擁有者）給規則檢查。
     */
    static void keyFiles(ObjectNode bom, Raw.Host host, List<String> lines) {
        for (String line : lines) {
            // 用空白切成最多 4 欄：parts[0] 權限、parts[1] 擁有者、parts[2] 大小（沒用到）、parts[3] 路徑
            String[] parts = line.trim().split("\\s+", 4);
            if (parts.length < 4) {
                continue;
            }
            String path = parts[3];
            String location = host.name() + ":" + path;
            String kind;
            if (path.endsWith(".p12") || path.endsWith(".jks") || path.endsWith(".bcfks")) {
                kind = path.contains("truststore") ? "truststore" : "keystore";
            } else if (path.endsWith(".key") || path.contains("keypair")) {
                kind = "private-key-file";
            } else {
                continue;
            }
            ObjectNode file = Cdx.plain("file", location, "keyfile|" + location);
            Cdx.prop(file, "source", "config");
            Cdx.prop(file, "kind", kind);
            Cdx.prop(file, "mode", parts[0]);
            Cdx.prop(file, "owner", parts[1]);
            Cdx.occurrence(file, location, kind);
            Cdx.add(bom, file);
        }
    }

    /**
     * kafka-configs --describe --entity-type users 的輸出裡 SCRAM 的那幾行：
     * 「SCRAM credential configs for user-principal 'kafka-admin' are SCRAM-SHA-512=iterations=8192」。
     * 只有機制與迭代次數，沒有密碼雜湊。
     *
     * 每種機制產生（或併進）一個 protocol 元件「SASL/機制」，屬性：
     *   cbom:scramUsers          用這個機制的帳號有幾個（一個帳號同時有兩種機制時，兩邊各算一次）
     *   cbom:scramMinIterations  這些帳號裡最少的迭代次數（規則檢查夠不夠）
     * 例：上面那一行 → SASL/SCRAM-SHA-512，scramUsers = 1，scramMinIterations = 8192。
     */
    static void scramUsers(ObjectNode bom, List<String> lines) {
        Map<String, Integer> users = new TreeMap<>();
        Map<String, Integer> minIterations = new TreeMap<>();
        for (String line : lines) {
            // 只看有「' are 」的行（帳號名稱的右引號＋ are ）；它後面才是機制的清單
            String marker = "' are ";
            int are = line.indexOf(marker);
            if (are < 0) {
                continue;
            }
            // 一個帳號可以有好幾種機制，用逗號隔開：「SCRAM-SHA-256=iterations=4096, SCRAM-SHA-512=iterations=8192」
            for (String credential : line.substring(are + marker.length()).split(",\\s*")) {
                // 用等號切成三段：pieces[0] 機制、pieces[1] 固定是 iterations、pieces[2] 次數
                String[] pieces = credential.split("=");
                if (pieces.length < 3 || !pieces[0].startsWith("SCRAM-")) {
                    continue;
                }
                String mechanism = pieces[0];
                int iterations = Integer.parseInt(pieces[2].trim());
                users.merge(mechanism, 1, Integer::sum);
                minIterations.merge(mechanism, iterations, Math::min);
            }
        }
        for (Map.Entry<String, Integer> entry : users.entrySet()) {
            String mechanism = entry.getKey();
            ObjectNode protocol = Cdx.asset("protocol", "SASL/" + mechanism, "sasl|" + mechanism);
            Cdx.crypto(protocol, "protocolProperties").put("type", "other");
            Cdx.prop(protocol, "source", "config");
            Cdx.prop(protocol, "saslMechanism", mechanism);
            Cdx.prop(protocol, "scramUsers", String.valueOf(entry.getValue()));
            Cdx.prop(protocol, "scramMinIterations", String.valueOf(minIterations.get(mechanism)));
            Cdx.occurrence(protocol, "叢集的 SCRAM 帳號", entry.getValue() + " 個帳號，迭代次數最少 " + minIterations.get(mechanism));
            Cdx.add(bom, protocol);
        }
    }

    /**
     * ssh 金鑰 → 每把一個演算法元件加一個公鑰元件（見 publicKey()）。
     *
     * 輸入是 ssh-keygen -l 的輸出：主機金鑰是「主機 長度 指紋 名稱 (類型)」，用戶端金鑰少第一欄。例：
     * <pre>
     *   主機金鑰：  kb01 256 SHA256:AbCd…xyz kb01.poc.lab (ED25519)
     *   用戶端金鑰：256 SHA256:AbCd…xyz cpuser@ops02 (ED25519)
     * </pre>
     * → 演算法元件「ED25519-256」（家族 EdDSA）、公鑰元件，位置是「kb01:sshd」或「ops02:/secure/ssh」
     * （後者是操作機放 ssh 私鑰的固定位置，寫死在這裡，顯示用）。
     */
    static void sshKeys(ObjectNode bom, List<String> lines, boolean hostKeys) {
        for (String line : lines) {
            String[] parts = line.trim().split("\\s+");
            // 主機金鑰多了開頭的主機名稱，後面的欄位都往後一格
            int offset = hostKeys ? 1 : 0;
            // 至少要有：長度、指紋、名稱、(類型) 四欄
            if (parts.length < offset + 4) {
                continue;
            }
            int bits = Integer.parseInt(parts[offset]);
            String fingerprint = parts[offset + 1];
            // 類型在最後一欄，去掉括號：「(ED25519)」→「ED25519」
            String type = parts[parts.length - 1].replace("(", "").replace(")", "");
            String use = hostKeys ? "ssh 主機金鑰" : "操作機連各主機的 ssh 金鑰";
            String location = hostKeys ? parts[0] + ":sshd" : "ops02:/secure/ssh";
            publicKey(bom, type, bits, fingerprint, use, location, "config");
        }
    }
}
