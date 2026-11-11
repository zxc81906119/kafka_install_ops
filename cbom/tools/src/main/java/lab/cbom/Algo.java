package lab.cbom;

import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 把各工具給的演算法名稱整理成一致的描述：家族、用途、金鑰長度、雜湊。
 *
 * 這裡只做「它是什麼」的整理，不做合不合規的判斷；判斷全部在 OPA 的規則裡。
 * 同一個演算法在不同工具有不同寫法（SHA256withRSA、RSA-PSS-RSAE+SHA256、sha256WithRSAEncryption），
 * 規則只要看家族與長度就好。
 */
final class Algo {

    /** family：演算法家族；primitive：CycloneDX 的用途分類；keySize：位元數（0 = 不知道）；digest：搭配的雜湊家族（沒有就 null）。 */
    record Info(String family, String primitive, int keySize, String digest) {
    }

    private static final Pattern DIGITS = Pattern.compile("(\\d{3,5})");
    private static final Pattern SHA2 = Pattern.compile("SHA-?(224|256|384|512)");

    private Algo() {
    }

    static Info describe(String rawName) {
        String name = rawName.toUpperCase(Locale.ROOT).replace('_', '-');
        String digest = digestOf(name);

        // 後量子與混合式（先比，名稱裡常同時有 X25519 之類的傳統字樣）
        if (name.contains("MLKEM") || name.contains("ML-KEM")) {
            boolean hybrid = name.contains("X25519") || name.contains("SECP") || name.contains("X448");
            // 參數是 KEM 後面那個數字（768、1024）；前面的 25519、256 是傳統那一半的曲線
            String afterKem = name.substring(name.indexOf("KEM") + 3);
            return new Info(hybrid ? "ML-KEM-hybrid" : "ML-KEM", "kem", firstNumber(afterKem), null);
        }
        if (name.contains("ML-DSA") || name.contains("MLDSA")) {
            return new Info("ML-DSA", "signature", 0, null);
        }
        if (name.contains("SLH-DSA") || name.contains("SPHINCS")) {
            return new Info("SLH-DSA", "signature", 0, null);
        }

        // 訊息鑑別與金鑰衍生（名稱裡有雜湊字樣，要比雜湊先比）
        if (name.startsWith("HMAC") || name.contains("-HMAC")) {
            return new Info("HMAC", "mac", 0, digest);
        }
        if (name.startsWith("HKDF")) {
            return new Info("HKDF", "kdf", 0, digest);
        }
        if (name.startsWith("PBKDF2") || name.startsWith("PBE")) {
            return new Info("PBKDF2", "kdf", 0, digest);
        }

        // 非對稱：簽章、金鑰交換
        if (name.contains("RSA") || name.matches("RS\\d{3}|PS\\d{3}")) {
            String primitive = name.contains("OAEP") || name.equals("RSA/ECB/PKCS1PADDING") ? "pke" : "signature";
            String jwtDigest = name.matches("(RS|PS)(256|384|512)") ? "SHA-2" : digest;
            return new Info("RSA", primitive, name.matches("(RS|PS)\\d{3}") ? 0 : keySizeOf(name), jwtDigest);
        }
        if (name.contains("ECDSA") || name.matches("ES\\d{3}")) {
            return new Info("ECDSA", "signature", keySizeOf(name), digest);
        }
        if (name.contains("ED25519") || name.contains("ED448") || name.contains("EDDSA")) {
            return new Info("EdDSA", "signature", name.contains("448") ? 448 : 255, null);
        }
        if (name.equals("DSA") || name.endsWith("WITHDSA")) {
            return new Info("DSA", "signature", keySizeOf(name), digest);
        }
        if (name.contains("X25519") || name.contains("X448") || name.equals("XDH") || name.contains("ECDH")
            || name.startsWith("SECP") || name.startsWith("PRIME") || name.matches("P-?(256|384|521)")
            || name.startsWith("BRAINPOOL")) {
            return new Info("ECDH", "key-agree", curveSize(name), null);
        }
        if (name.equals("DH") || name.startsWith("DHE") || name.startsWith("FFDHE") || name.equals("DIFFIEHELLMAN")) {
            return new Info("DH", "key-agree", keySizeOf(name), null);
        }

        // 對稱式
        if (name.contains("3DES") || name.contains("DESEDE") || name.contains("TRIPLEDES")) {
            return new Info("3DES", "block-cipher", 168, null);
        }
        if (name.equals("DES") || name.startsWith("DES/") || name.startsWith("DES-")) {
            return new Info("DES", "block-cipher", 56, null);
        }
        if (name.contains("RC4") || name.contains("ARCFOUR")) {
            return new Info("RC4", "stream-cipher", 0, null);
        }
        if (name.contains("AES")) {
            String primitive = name.contains("GCM") || name.contains("CCM") ? "ae" : "block-cipher";
            return new Info("AES", primitive, aesSize(name), null);
        }
        if (name.contains("CHACHA20")) {
            return new Info("ChaCha20", name.contains("POLY1305") ? "ae" : "stream-cipher", 256, null);
        }

        // 雜湊
        if (name.equals("MD5") || name.equals("MD2") || name.equals("MD4")) {
            return new Info(name, "hash", 0, null);
        }
        if (name.matches("SHA-?1") || name.equals("SHA")) {
            return new Info("SHA-1", "hash", 160, null);
        }
        if (name.startsWith("SHA3-") || name.startsWith("SHAKE")) {
            return new Info("SHA-3", "hash", firstNumber(name.substring(4)), null);
        }
        Matcher sha2 = SHA2.matcher(name);
        if (sha2.find() && name.startsWith("SHA")) {
            return new Info("SHA-2", "hash", Integer.parseInt(sha2.group(1)), null);
        }

        return new Info("unknown", "unknown", 0, digest);
    }

    /** 把整理結果寫進元件：CycloneDX 的 primitive 欄位，加上給規則用的屬性。 */
    static void apply(ObjectNode algorithmComponent, String rawName) {
        Info info = describe(rawName);
        ObjectNode properties = Cdx.crypto(algorithmComponent, "algorithmProperties");
        if (!properties.has("primitive")) {
            properties.put("primitive", info.primitive());
        }
        Cdx.prop(algorithmComponent, "family", info.family());
        if (info.keySize() > 0) {
            Cdx.prop(algorithmComponent, "keySize", String.valueOf(info.keySize()));
        }
        if (info.digest() != null) {
            Cdx.prop(algorithmComponent, "digest", info.digest());
        }
    }

    private static String digestOf(String name) {
        if (name.contains("MD5")) {
            return "MD5";
        }
        if (name.matches(".*SHA-?1(?!\\d).*") || name.matches(".*SHAWITH.*")) {
            return "SHA-1";
        }
        if (name.contains("SHA3-") || name.contains("SHAKE")) {
            return "SHA-3";
        }
        if (SHA2.matcher(name).find()) {
            return "SHA-2";
        }
        return null;
    }

    /** RSA-2048、「RSA 2048 bits」這類名稱裡的金鑰長度；雜湊長度（SHA256）不算。 */
    private static int keySizeOf(String name) {
        String withoutDigest = SHA2.matcher(name).replaceAll("").replaceAll("SHA3-\\d+", "");
        return firstNumber(withoutDigest);
    }

    private static int firstNumber(String text) {
        Matcher digits = DIGITS.matcher(text);
        if (digits.find()) {
            return Integer.parseInt(digits.group(1));
        }
        return 0;
    }

    private static int aesSize(String name) {
        for (int size : new int[] {256, 192, 128}) {
            if (name.contains(String.valueOf(size))) {
                return size;
            }
        }
        return 0;
    }

    private static int curveSize(String name) {
        if (name.contains("25519")) {
            return 255;
        }
        if (name.contains("448")) {
            return 448;
        }
        return firstNumber(name);
    }
}
