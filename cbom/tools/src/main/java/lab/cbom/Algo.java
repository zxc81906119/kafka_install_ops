package lab.cbom;

import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 把各工具給的演算法名稱整理成一致的描述：家族、用途、金鑰長度、雜湊。
 *
 * 這裡只做「它是什麼」的整理，不做合不合規的判斷；判斷全部在 OPA 的規則裡（cbom/policy/cbom.rego）。
 * 同一個演算法在不同工具有不同寫法（SHA256withRSA、RSA-PSS-RSAE+SHA256、sha256WithRSAEncryption），
 * 規則只要看家族與長度就好。
 *
 * 輸入：一個名稱（字串）。來源是各個 Layer：testssl.sh 的群組與簽章名稱、JFR 事件的 algorithm、
 *       cbomkit-theia 與 cbomkit-action 的元件名稱、properties 裡的設定值。
 * 輸出：Info（家族、用途、金鑰長度、雜湊）；apply() 把它寫成元件上「cbom:」開頭的屬性，規則讀的就是這些屬性。
 * 誰呼叫：每個會產生演算法、金鑰、憑證元件的 Layer，以及 TheiaAdapter。
 *
 * <pre>
 * 例子（名稱 → 家族 / 用途 / 金鑰長度 / 雜湊）：
 *   SHA256withRSA            → RSA           / signature    / 0（不知道） / SHA-2
 *   RSA-2048                 → RSA           / signature    / 2048        / 沒有
 *   RS256（JWT 的寫法）      → RSA           / signature    / 0           / SHA-2
 *   X25519MLKEM768           → ML-KEM-hybrid / kem          / 768         / 沒有
 *   secp256r1                → ECDH          / key-agree    / 256         / 沒有
 *   AES/GCM/NoPadding        → AES           / ae           / 0           / 沒有
 *   TLS_AES_256_GCM_SHA384   → AES           / ae           / 256         / 沒有（對稱式不記雜湊）
 *   HmacSHA256               → HMAC          / mac          / 0           / SHA-2
 *   DESede/CBC/PKCS5Padding  → 3DES          / block-cipher / 168         / 沒有
 *   SHA1PRNG                 → RNG           / drbg         / 0           / 沒有
 *   SHA-1                    → SHA-1         / hash         / 160         / 沒有
 *   不認得的名稱             → unknown       / unknown      / 0           / 名稱裡看得出來的雜湊
 * </pre>
 *
 * 怎麼讀：describe() 先把名稱轉成大寫、底線換成減號，再照固定的順序一類一類問「是不是這一類」，
 * 第一個認得的就回傳。<b>順序有意義</b>：名稱裡常同時有好幾種字樣（X25519MLKEM768 同時有 X25519 與 MLKEM、
 * HmacSHA256 同時有 HMAC 與 SHA256），先問的那一類贏。
 *
 * 怎麼加一個演算法名稱或家族：
 * <pre>
 * 1. 已有的家族多一種寫法（例如某工具把 3DES 寫成 TDEA）：在那一類的方法裡（這個例子是 symmetric()）
 *    的 if 多加一個條件。
 * 2. 新的家族：在最接近的那一類方法裡加一段 if，回傳 new Info("家族", "用途", 金鑰長度, 雜湊)。
 *    用途用 CycloneDX 的 primitive 名稱：signature、kem、key-agree、pke、block-cipher、stream-cipher、ae、
 *    hash、mac、kdf、drbg、other。放的位置要想一下「名稱裡有沒有別類的字樣」，有的話要放在那一類之前。
 * 3. 新的家族要讓規則認得：在 cbom/policy/cbom.rego 開頭的名單加上家族名稱
 *    （quantum_vulnerable_families、quantum_safe_families、broken_families、symmetric_families 其中一個），
 *    否則規則會把它判成「無法判斷」。
 * 4. 在測試加一個例子（src/test 的 AlgoTest 或 ConvertersTest），跑 bash cbom/build.sh；
 *    再跑 bash cbom/golden.sh check 確認沒有改到別的名稱的結果。
 * </pre>
 */
final class Algo {

    /** family：演算法家族；primitive：CycloneDX 的用途分類；keySize：位元數（0 = 不知道）；digest：搭配的雜湊家族（沒有就 null）。 */
    record Info(String family, String primitive, int keySize, String digest) {
    }

    /** 連續 3 到 5 個數字，當成長度。例：「RSA-2048」→ 2048、「FFDHE3072」→ 3072、「X448」→ 448；一、兩位的數字（例如版本號 1.2）不算。 */
    private static final Pattern DIGITS = Pattern.compile("(\\d{3,5})");

    /** SHA-2 的寫法：SHA224、SHA-256、SHA384、SHA-512（減號可有可無）；括號抓到的是長度。SHA1、SHA3-256 不符合。 */
    private static final Pattern SHA2 = Pattern.compile("SHA-?(224|256|384|512)");

    private Algo() {
    }

    /**
     * 名稱 → 描述。例子與修改方法見檔頭。
     * 下面每個方法負責一類：認得就回 Info，不認得回 null，換下一類問。
     */
    static Info describe(String rawName) {
        // 統一寫法：全部大寫、底線換成減號。例：「TLS_AES_256_GCM_SHA384」→「TLS-AES-256-GCM-SHA384」
        String name = rawName.toUpperCase(Locale.ROOT).replace('_', '-');
        // 名稱裡看得出來的雜湊（SHA256WITHRSA → SHA-2）；只有簽章、MAC、KDF 這幾類會用到
        String digest = digestOf(name);

        // 後量子與混合式（先比，名稱裡常同時有 X25519 之類的傳統字樣）
        Info info = postQuantum(name);
        if (info != null) {
            return info;
        }
        // 亂數產生器
        info = randomGenerator(name);
        if (info != null) {
            return info;
        }
        // 訊息鑑別與金鑰衍生（名稱裡有雜湊字樣，要比雜湊先比）
        info = macOrKdf(name, digest);
        if (info != null) {
            return info;
        }
        // 非對稱：簽章、金鑰交換
        info = asymmetric(name, digest);
        if (info != null) {
            return info;
        }
        // 對稱式
        info = symmetric(name);
        if (info != null) {
            return info;
        }
        // 雜湊
        info = hash(name);
        if (info != null) {
            return info;
        }
        // 輔助用的對稱式元件
        info = helper(name, digest);
        if (info != null) {
            return info;
        }
        // 都不認得：家族 unknown（規則會判成「無法判斷」，請人看過後在這裡補上）
        return new Info("unknown", "unknown", 0, digest);
    }

    /**
     * 後量子演算法：ML-KEM（金鑰封裝）、ML-DSA 與 SLH-DSA（簽章）。
     * 例：「MLKEM768」→ ML-KEM / 768；「X25519MLKEM768」「SECP256R1MLKEM768」→ ML-KEM-hybrid / 768（傳統＋後量子的混合式）。
     */
    private static Info postQuantum(String name) {
        if (name.contains("MLKEM") || name.contains("ML-KEM")) {
            // 判斷是不是混合式：名稱裡同時有傳統的曲線名稱
            boolean hybrid = name.contains("X25519") || name.contains("SECP") || name.contains("X448");
            String family;
            if (hybrid) {
                family = "ML-KEM-hybrid";
            } else {
                family = "ML-KEM";
            }
            // 參數是 KEM 後面那個數字（768、1024）；前面的 25519、256 是傳統那一半的曲線。
            // 「+ 3」是跳過「KEM」這三個字。例：「X25519MLKEM768」→ afterKem =「768」
            String afterKem = name.substring(name.indexOf("KEM") + 3);
            return new Info(family, "kem", firstNumber(afterKem), null);
        }
        if (name.contains("ML-DSA") || name.contains("MLDSA")) {
            return new Info("ML-DSA", "signature", 0, null);
        }
        if (name.contains("SLH-DSA") || name.contains("SPHINCS")) {
            return new Info("SLH-DSA", "signature", 0, null);
        }
        return null;
    }

    /**
     * 亂數產生器（NativePRNG、DRBG、SHA1PRNG…）→ 家族 RNG。
     * 名稱裡的 SHA1 只是內部用的雜湊，不當成搭配的雜湊來判（所以雜湊欄給 null）。
     */
    private static Info randomGenerator(String name) {
        if (name.contains("PRNG") || name.equals("DRBG")) {
            return new Info("RNG", "drbg", 0, null);
        }
        return null;
    }

    /**
     * 訊息鑑別（HMAC）與金鑰衍生（HKDF、PBKDF2）；搭配的雜湊記在 digest。
     * 例：「HmacSHA256」→ HMAC / SHA-2；「PBKDF2WithHmacSHA1」→ PBKDF2 / SHA-1；
     *     「PBEWithMD5AndDES」→ PBKDF2 / MD5（JDK 的 PBE 系列都歸在 PBKDF2 這一家）。
     */
    private static Info macOrKdf(String name, String digest) {
        if (name.startsWith("HMAC") || name.contains("-HMAC")) {
            return new Info("HMAC", "mac", 0, digest);
        }
        if (name.startsWith("HKDF")) {
            return new Info("HKDF", "kdf", 0, digest);
        }
        if (name.startsWith("PBKDF2") || name.startsWith("PBE")) {
            return new Info("PBKDF2", "kdf", 0, digest);
        }
        return null;
    }

    /**
     * 非對稱式：RSA、ECDSA、EdDSA、DSA（簽章），ECDH、DH（金鑰交換），EC（只知道是橢圓曲線）。
     * 這幾段的先後也有意義：例如「ECDHE-RSA-AES256-GCM-SHA384」同時有 ECDHE、RSA、AES，第一段就判成 RSA。
     */
    private static Info asymmetric(String name, String digest) {
        // JWT 的簽章寫法：RS256、PS384（RS／PS 都是 RSA；後面三位數是 SHA-2 的長度，不是金鑰長度）
        boolean jwtShape = name.matches("RS\\d{3}|PS\\d{3}");
        if (name.contains("RSA") || jwtShape) {
            return rsa(name, digest);
        }
        // ES256 是 JWT 對 ECDSA 的寫法
        if (name.contains("ECDSA") || name.matches("ES\\d{3}")) {
            return new Info("ECDSA", "signature", keySizeOf(name), digest);
        }
        if (name.contains("ED25519") || name.contains("ED448") || name.contains("EDDSA")) {
            // 金鑰長度：Ed448 是 448，其餘（Ed25519，或只寫 EdDSA）當 255
            int size;
            if (name.contains("448")) {
                size = 448;
            } else {
                size = 255;
            }
            return new Info("EdDSA", "signature", size, null);
        }
        // 傳統的 DSA：只收「DSA」與「SHA256WITHDSA」這種結尾，避免把 ECDSA、ML-DSA 算進來（它們在前面已經回傳了）
        if (name.equals("DSA") || name.endsWith("WITHDSA")) {
            return new Info("DSA", "signature", keySizeOf(name), digest);
        }
        // 橢圓曲線金鑰交換：曲線名稱（X25519、secp256r1、prime256v1、P-256、brainpoolP256r1）或 ECDH／ECDHE
        if (name.contains("X25519") || name.contains("X448") || name.equals("XDH") || name.contains("ECDH")
            || name.startsWith("SECP") || name.startsWith("PRIME") || name.matches("P-?(256|384|521)")
            || name.startsWith("BRAINPOOL")) {
            return new Info("ECDH", "key-agree", curveSize(name), null);
        }
        // 有限體的 Diffie-Hellman：DH、DHE-…、ffdhe2048、DiffieHellman
        if (name.equals("DH") || name.startsWith("DHE") || name.startsWith("FFDHE") || name.equals("DIFFIEHELLMAN")) {
            return new Info("DH", "key-agree", keySizeOf(name), null);
        }
        // 原始碼掃描工具（sonar-cryptography）的寫法：FFDH、FFDH-2048、EC、EC-secp256r1
        if (name.startsWith("FFDH")) {
            return new Info("DH", "key-agree", keySizeOf(name), null);
        }
        if (name.equals("EC") || name.startsWith("EC-")) {
            return new Info("EC", "pke", curveSize(name), null);
        }
        return null;
    }

    /**
     * RSA 的三個判斷：用途、雜湊、金鑰長度。
     * 例：「SHA256WITHRSA」→ signature / SHA-2 / 0；「RSA-2048」→ signature / 沒有 / 2048；
     *     「RSA/ECB/OAEPWITHSHA-256ANDMGF1PADDING」→ pke / SHA-2 / 0；「RS256」→ signature / SHA-2 / 0。
     */
    private static Info rsa(String name, String digest) {
        // 用途：名稱有 OAEP，或是 Cipher 的「RSA/ECB/PKCS1PADDING」→ 加密（pke）；其餘當簽章
        boolean encryption = name.contains("OAEP") || name.equals("RSA/ECB/PKCS1PADDING");
        String primitive;
        if (encryption) {
            primitive = "pke";
        } else {
            primitive = "signature";
        }

        // 雜湊：JWT 的 RS256／PS384／RS512 這幾個名稱裡沒有 SHA 字樣，但規格定的就是 SHA-2
        boolean jwtWithSha2 = name.matches("(RS|PS)(256|384|512)");
        String usedDigest;
        if (jwtWithSha2) {
            usedDigest = "SHA-2";
        } else {
            usedDigest = digest;
        }

        // 金鑰長度：JWT 寫法後面的三位數是雜湊長度，不是金鑰長度 → 0（不知道）；其餘從名稱裡找（RSA-2048 → 2048）
        boolean jwtShape = name.matches("(RS|PS)\\d{3}");
        int keySize;
        if (jwtShape) {
            keySize = 0;
        } else {
            keySize = keySizeOf(name);
        }
        return new Info("RSA", primitive, keySize, usedDigest);
    }

    /**
     * 對稱式加密：3DES、DES、RC4、AES、ChaCha20。
     * 3DES 要比 DES 先問（「DESEDE」也是 DES 開頭）。長度：3DES 固定 168、DES 固定 56、ChaCha20 固定 256。
     */
    private static Info symmetric(String name) {
        if (name.contains("3DES") || name.contains("DESEDE") || name.contains("TRIPLEDES")) {
            return new Info("3DES", "block-cipher", 168, null);
        }
        // 單獨的 DES：「DES」「DES/CBC/PKCS5PADDING」「DES-CBC-SHA」
        if (name.equals("DES") || name.startsWith("DES/") || name.startsWith("DES-")) {
            return new Info("DES", "block-cipher", 56, null);
        }
        if (name.contains("RC4") || name.contains("ARCFOUR")) {
            return new Info("RC4", "stream-cipher", 0, null);
        }
        if (name.contains("AES")) {
            // 用途：GCM、CCM 是「加密同時驗證」（ae）；其餘模式（CBC、CTR…）是一般的區塊加密
            String primitive;
            if (name.contains("GCM") || name.contains("CCM")) {
                primitive = "ae";
            } else {
                primitive = "block-cipher";
            }
            return new Info("AES", primitive, aesSize(name), null);
        }
        if (name.contains("CHACHA20")) {
            // 用途：搭配 Poly1305 是「加密同時驗證」（ae）；單獨的 ChaCha20 是串流加密
            String primitive;
            if (name.contains("POLY1305")) {
                primitive = "ae";
            } else {
                primitive = "stream-cipher";
            }
            return new Info("ChaCha20", primitive, 256, null);
        }
        return null;
    }

    /**
     * 雜湊：MD5／MD2／MD4（家族就是名稱本身）、SHA-1、SHA-3（含 SHAKE）、SHA-2。金鑰長度欄放的是輸出長度。
     * 例：「SHA」「SHA1」「SHA-1」→ SHA-1 / 160；「SHA-256」→ SHA-2 / 256；「SHA3-256」→ SHA-3 / 256。
     */
    private static Info hash(String name) {
        if (name.equals("MD5") || name.equals("MD2") || name.equals("MD4")) {
            return new Info(name, "hash", 0, null);
        }
        // 「SHA」是 JDK 對 SHA-1 的舊名
        if (name.matches("SHA-?1") || name.equals("SHA")) {
            return new Info("SHA-1", "hash", 160, null);
        }
        if (name.startsWith("SHA3-") || name.startsWith("SHAKE")) {
            // substring(4) 是跳過開頭的「SHA3」或「SHAK」，免得把別的數字當長度。例：「SHA3-256」→「-256」→ 256
            return new Info("SHA-3", "hash", firstNumber(name.substring(4)), null);
        }
        Matcher sha2 = SHA2.matcher(name);
        if (sha2.find() && name.startsWith("SHA")) {
            return new Info("SHA-2", "hash", Integer.parseInt(sha2.group(1)), null);
        }
        if (name.equals("SHA3")) {
            return new Info("SHA-3", "hash", 0, null);
        }
        return null;
    }

    /** 輔助用的對稱式元件：ChaCha20-Poly1305 的鑑別碼、RSA-PSS／OAEP 的遮罩函式（MGF1）、TLS 1.2 衍生金鑰用的 PRF（JDK 的名稱是 SunTls… 開頭）。 */
    private static Info helper(String name, String digest) {
        if (name.equals("POLY1305")) {
            return new Info("Poly1305", "mac", 0, null);
        }
        if (name.equals("MGF1")) {
            return new Info("MGF1", "other", 0, digest);
        }
        if (name.startsWith("SUNTLS")) {
            return new Info("TLS-PRF", "kdf", 0, null);
        }
        return null;
    }

    /**
     * 把整理結果寫進元件：CycloneDX 的 primitive 欄位，加上給規則用的屬性
     * （cbom:family 一定有；cbom:keySize 知道長度才有；cbom:digest 有搭配的雜湊才有；
     * cbom:mode、cbom:padding 看得出模式、填充才有，例：AES/ECB/PKCS5Padding → mode ECB、padding PKCS5）。
     * 元件原本就有 primitive 時（原始碼掃描工具給的）不蓋掉。
     */
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
        // 模式與填充：看得出來才寫。掃描工具有給的（algorithmProperties 的 mode、padding）優先，沒有才從名稱看
        String mode = modeOf(properties.path("mode").asText(""), rawName);
        if (mode != null) {
            Cdx.prop(algorithmComponent, "mode", mode);
        }
        String padding = paddingOf(properties.path("padding").asText(""), rawName);
        if (padding != null) {
            Cdx.prop(algorithmComponent, "padding", padding);
        }
    }

    /** 認得的區塊加密模式（寫進 cbom:mode 的值）。 */
    private static final java.util.List<String> MODES = java.util.List.of("ECB", "CBC", "GCM", "CCM", "CTR", "CFB", "OFB");

    /**
     * 把名稱切成一段一段（轉大寫，以英文字母與數字以外的字元為界）。
     * 例：「AES/ECB/PKCS5Padding」→ [AES, ECB, PKCS5PADDING]；「AES128-ECB-PKCS5」→ [AES128, ECB, PKCS5]；
     *     「RSA/ECB/OAEPWithSHA-256AndMGF1Padding」→ [RSA, ECB, OAEPWITHSHA, 256ANDMGF1PADDING]。
     */
    private static String[] tokens(String rawName) {
        return rawName.toUpperCase(Locale.ROOT).split("[^A-Z0-9]+");
    }

    /**
     * 區塊加密的模式（ECB、CBC、GCM…）；看不出來回 null（不猜）。
     * fromTool 是掃描工具給的 mode（CycloneDX 的寫法，小寫，例：ecb；沒有就是空字串），有而且認得就用它；
     * 否則看名稱裡有沒有一段剛好是模式的名稱。CFB8、OFB64 這種帶位元數的算 CFB、OFB。
     * <pre>
     * 例：AES/ECB/PKCS5Padding → ECB；AES128-ECB-PKCS5 → ECB；AES/GCM/NoPadding → GCM；TLS_AES_256_GCM_SHA384 → GCM；
     *     AES-256-CBC → CBC；AES → null；SHA256withRSA → null
     * </pre>
     * 注意：RSA/ECB/PKCS1Padding 也會得到 ECB。那只是 JCA 的寫法（RSA 沒有區塊模式）；
     * 規則 ecb-mode 只看區塊加密的家族（AES、DES、3DES），所以 RSA 不會被判成 ECB 違規。
     */
    static String modeOf(String fromTool, String rawName) {
        String given = fromTool.toUpperCase(Locale.ROOT);
        if (MODES.contains(given)) {
            return given;
        }
        for (String token : tokens(rawName)) {
            if (MODES.contains(token)) {
                return token;
            }
            // CFB8、OFB64：前三個字是模式
            if (token.matches("(CFB|OFB)\\d+")) {
                return token.substring(0, 3);
            }
        }
        return null;
    }

    /**
     * 填充方式；看不出來回 null（不猜）。值：PKCS1（PKCS#1 v1.5）、OAEP、PKCS5、PKCS7、NONE（NoPadding）。
     * fromTool 是掃描工具給的 padding（CycloneDX 的寫法：pkcs1v15、oaep、pkcs5、pkcs7；沒有就是空字串），認得就用它；
     * 否則看名稱裡的每一段。
     * <pre>
     * 例：RSA/ECB/PKCS1Padding → PKCS1；RSA/ECB/OAEPWithSHA-256AndMGF1Padding → OAEP；RSA-OAEP → OAEP；
     *     AES/CBC/PKCS5Padding → PKCS5；AES128-ECB-PKCS5 → PKCS5；AES/GCM/NoPadding → NONE；
     *     SHA256withRSA → null（簽章的名稱裡沒有填充）；PKCS12 → null（那是 keystore 的格式，不是填充）
     * </pre>
     */
    static String paddingOf(String fromTool, String rawName) {
        switch (fromTool.toLowerCase(Locale.ROOT)) {
            case "pkcs1v15":
                return "PKCS1";
            case "oaep":
                return "OAEP";
            case "pkcs5":
                return "PKCS5";
            case "pkcs7":
                return "PKCS7";
            default:
                break;
        }
        for (String token : tokens(rawName)) {
            if (token.startsWith("OAEP")) {
                return "OAEP";
            }
            // 剛好是 PKCS1、PKCS1PADDING、PKCS1V15 才算（PKCS12 不算）
            if (token.matches("PKCS1(PADDING|V15)?")) {
                return "PKCS1";
            }
            if (token.matches("PKCS5(PADDING)?")) {
                return "PKCS5";
            }
            if (token.matches("PKCS7(PADDING)?")) {
                return "PKCS7";
            }
            if (token.equals("NOPADDING")) {
                return "NONE";
            }
        }
        return null;
    }

    /**
     * 名稱裡看得出來的雜湊家族；看不出來回 null。name 是已經轉成大寫的名稱。
     * 例：「MD5WITHRSA」→ MD5；「SHA1WITHRSA」「SHAWITHDSA」→ SHA-1；「SHA3-256WITHRSA」→ SHA-3；「SHA256WITHRSA」→ SHA-2。
     */
    private static String digestOf(String name) {
        if (name.contains("MD5")) {
            return "MD5";
        }
        // 第一個 regex：名稱裡有「SHA1」或「SHA-1」，而且後面不再接數字（(?!\d)）；
        // 第二個：「SHAWITH…」是 JDK 對 SHA-1 的舊寫法（SHAwithDSA）
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

    /**
     * RSA-2048、「RSA 2048 bits」這類名稱裡的金鑰長度；雜湊長度（SHA256）不算。
     * 做法：先把 SHA-2、SHA-3 的字樣拿掉，再找第一個 3 到 5 位的數字。
     * 例：「RSA-2048」→ 2048；「SHA256WITHRSA」→ 0；「SHA384WITHECDSA」→ 0；「FFDH-2048」→ 2048。
     */
    private static int keySizeOf(String name) {
        String withoutDigest = SHA2.matcher(name).replaceAll("").replaceAll("SHA3-\\d+", "");
        return firstNumber(withoutDigest);
    }

    /** 字串裡第一個 3 到 5 位的數字；沒有回 0。例：「-768」→ 768；「X25519」→ 25519；「P-256」→ 256；「EC」→ 0。 */
    private static int firstNumber(String text) {
        Matcher digits = DIGITS.matcher(text);
        if (digits.find()) {
            return Integer.parseInt(digits.group(1));
        }
        return 0;
    }

    /** AES 的金鑰長度：名稱裡有 256、192、128 就是它（照這個順序找）；都沒有回 0。例：「AES-256-GCM」→ 256；「AES/GCM/NOPADDING」→ 0。 */
    private static int aesSize(String name) {
        for (int size : new int[] {256, 192, 128}) {
            if (name.contains(String.valueOf(size))) {
                return size;
            }
        }
        return 0;
    }

    /** 曲線的長度：Curve25519 當 255、Curve448 當 448，其餘取名稱裡的數字。例：「X25519」→ 255；「SECP384R1」→ 384；「ECDH」→ 0。 */
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
