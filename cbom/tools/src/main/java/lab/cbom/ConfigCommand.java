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
 * 第 ③ 層：平台設定 → CBOM。
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
 */
final class ConfigCommand {

    private ConfigCommand() {
    }

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
            sshKeys(bom, Raw.lines(raw.shared().resolve("ssh-host-keys.txt")), true);
            sshKeys(bom, Raw.lines(raw.shared().resolve("ssh-client-key.txt")), false);
        }
        return bom;
    }

    /** properties 的 key = value；第一行註解「# file=路徑」是設定檔在主機上的位置。 */
    static void platformConfig(ObjectNode bom, Raw.Host host, List<String> lines) {
        if (lines.isEmpty()) {
            return;
        }
        String path = "properties";
        Map<String, String> settings = new LinkedHashMap<>();
        for (String line : lines) {
            if (line.startsWith("# file=")) {
                path = line.substring("# file=".length()).trim();
                continue;
            }
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

        for (Map.Entry<String, String> setting : settings.entrySet()) {
            String key = setting.getKey();
            String value = setting.getValue();
            if (value.isEmpty() || value.startsWith("<")) {
                continue;
            }
            if (key.endsWith("sasl.enabled.mechanisms") || key.endsWith("sasl.mechanism")
                || key.endsWith("sasl.mechanism.inter.broker.protocol") || key.endsWith("sasl.mechanism.controller.protocol")) {
                for (String mechanism : value.split(",")) {
                    sasl(bom, mechanism.trim(), location, key);
                }
            }
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

    /** Confluent Secret Protection：AES-CBC 加密設定值，資料金鑰用 PBKDF2 從 master key 衍生（原廠文件）。 */
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

    /** MDS token 的驗證公鑰（PEM 的 PUBLIC KEY）。 */
    static void tokenPublicKey(ObjectNode bom, Raw.Host host, Path pem) throws IOException {
        if (!Files.isRegularFile(pem)) {
            return;
        }
        String text = Files.readString(pem, StandardCharsets.UTF_8);
        if (!text.contains("BEGIN PUBLIC KEY")) {
            return;
        }
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

    /** /etc/confluent/ssl 的檔案清單：「權限 擁有者 大小 路徑」。只記有哪些 keystore 與私鑰檔、權限對不對，不讀內容。 */
    static void keyFiles(ObjectNode bom, Raw.Host host, List<String> lines) {
        for (String line : lines) {
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
     */
    static void scramUsers(ObjectNode bom, List<String> lines) {
        Map<String, Integer> users = new TreeMap<>();
        Map<String, Integer> minIterations = new TreeMap<>();
        for (String line : lines) {
            int are = line.indexOf("' are ");
            if (are < 0) {
                continue;
            }
            for (String credential : line.substring(are + 6).split(",\\s*")) {
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

    /** ssh-keygen -l 的輸出：主機金鑰是「主機 長度 指紋 名稱 (類型)」，用戶端金鑰少第一欄。 */
    static void sshKeys(ObjectNode bom, List<String> lines, boolean hostKeys) {
        for (String line : lines) {
            String[] parts = line.trim().split("\\s+");
            int offset = hostKeys ? 1 : 0;
            if (parts.length < offset + 4) {
                continue;
            }
            int bits = Integer.parseInt(parts[offset]);
            String fingerprint = parts[offset + 1];
            String type = parts[parts.length - 1].replace("(", "").replace(")", "");
            String use = hostKeys ? "ssh 主機金鑰" : "操作機連各主機的 ssh 金鑰";
            String location = hostKeys ? parts[0] + ":sshd" : "ops02:/secure/ssh";
            publicKey(bom, type, bits, fingerprint, use, location, "config");
        }
    }
}
