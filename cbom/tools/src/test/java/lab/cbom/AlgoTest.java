package lab.cbom;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

/** 各工具給的演算法名稱 → 家族、金鑰長度、搭配的雜湊。規則靠這三樣判斷，所以每種寫法都要認得。 */
class AlgoTest {

    /** 模式與填充：看得出來才給，看不出來是 null（不猜）。規則 ecb-mode、rsa-pkcs1-encryption 靠這兩個判斷。 */
    @ParameterizedTest(name = "{0} → mode {1}、padding {2}")
    @CsvSource(nullValues = "-", value = {
        // 名稱,                                    模式, 填充
        "AES/ECB/PKCS5Padding,                      ECB,  PKCS5",
        "AES128-ECB-PKCS5,                          ECB,  PKCS5",
        "AES/CBC/PKCS5Padding,                      CBC,  PKCS5",
        "AES/GCM/NoPadding,                         GCM,  NONE",
        "AES-256-CBC,                               CBC,  -",
        "TLS_AES_256_GCM_SHA384,                    GCM,  -",
        "AES/CFB8/NoPadding,                        CFB,  NONE",
        "AES,                                       -,    -",
        "RSA/ECB/PKCS1Padding,                      ECB,  PKCS1",
        "RSA/ECB/OAEPWithSHA-256AndMGF1Padding,     ECB,  OAEP",
        "RSA-OAEP,                                  -,    OAEP",
        "RSASSA-PKCS1-v1_5,                         -,    PKCS1",
        "SHA256withRSA,                             -,    -",
        "PKCS12,                                    -,    -",
    })
    void modeAndPaddingComeFromTheName(String name, String mode, String padding) {
        assertEquals(mode, Algo.modeOf("", name));
        assertEquals(padding, Algo.paddingOf("", name));
    }

    /** 掃描工具有給 mode、padding 時（CycloneDX 的小寫寫法）以它為準；給的是不認得的值就回頭看名稱。 */
    @org.junit.jupiter.api.Test
    void modeAndPaddingFromTheScannerWin() {
        assertEquals("ECB", Algo.modeOf("ecb", "AES128"));
        assertEquals("PKCS1", Algo.paddingOf("pkcs1v15", "RSA-2048"));
        assertEquals("CBC", Algo.modeOf("other", "AES-256-CBC"));
        assertEquals(null, Algo.paddingOf("unknown", "RSA-2048"));
    }

    /** apply 把模式與填充寫成屬性；RSA/ECB/PKCS1Padding 的用途是加密（pke）。 */
    @org.junit.jupiter.api.Test
    void applyWritesModeAndPadding() {
        com.fasterxml.jackson.databind.node.ObjectNode ecb = Cdx.asset("algorithm", "AES/ECB/PKCS5Padding", "t|1");
        Algo.apply(ecb, "AES/ECB/PKCS5Padding");
        assertEquals("AES", Cdx.prop(ecb, "family"));
        assertEquals("ECB", Cdx.prop(ecb, "mode"));
        assertEquals("PKCS5", Cdx.prop(ecb, "padding"));

        com.fasterxml.jackson.databind.node.ObjectNode rsa = Cdx.asset("algorithm", "RSA/ECB/PKCS1Padding", "t|2");
        Algo.apply(rsa, "RSA/ECB/PKCS1Padding");
        assertEquals("PKCS1", Cdx.prop(rsa, "padding"));
        assertEquals("pke", rsa.path("cryptoProperties").path("algorithmProperties").path("primitive").asText());

        com.fasterxml.jackson.databind.node.ObjectNode signature = Cdx.asset("algorithm", "SHA256withRSA", "t|3");
        Algo.apply(signature, "SHA256withRSA");
        assertEquals(null, Cdx.prop(signature, "mode"));
        assertEquals(null, Cdx.prop(signature, "padding"));
    }

    @ParameterizedTest(name = "{0} → {1} {2} {3}")
    @CsvSource(nullValues = "-", value = {
        // 名稱,                家族,           長度, 雜湊
        "X25519MLKEM768,        ML-KEM-hybrid,  768,  -",
        "SecP256r1MLKEM768,     ML-KEM-hybrid,  768,  -",
        "ML-KEM-768,            ML-KEM,         768,  -",
        "ML-KEM,                ML-KEM,         0,    -",
        "ML-DSA-65,             ML-DSA,         0,    -",
        "RSA-2048,              RSA,            2048, -",
        "RSA-1024,              RSA,            1024, -",
        "SHA256-RSA,            RSA,            0,    SHA-2",
        "SHA256withRSA,         RSA,            0,    SHA-2",
        "SHA1withRSA,           RSA,            0,    SHA-1",
        "MD5withRSA,            RSA,            0,    MD5",
        "RSA-PSS-RSAE+SHA384,   RSA,            0,    SHA-2",
        "RSA+SHA384,            RSA,            0,    SHA-2",
        "RSASSA-PSS,            RSA,            0,    -",
        "RS256,                 RSA,            0,    SHA-2",
        "ECDSA-256,             ECDSA,          256,  -",
        "SHA256withECDSA,       ECDSA,          0,    SHA-2",
        "ED25519-256,           EdDSA,          255,  -",
        "X25519,                ECDH,           255,  -",
        "X448,                  ECDH,           448,  -",
        "prime256v1,            ECDH,           256,  -",
        "secp384r1,             ECDH,           384,  -",
        "XDH,                   ECDH,           0,    -",
        "DH,                    DH,             0,    -",
        "ffdhe2048,             DH,             2048, -",
        "AES-256-CBC,           AES,            256,  -",
        "AES/GCM/NoPadding,     AES,            0,    -",
        "AES_128_GCM,           AES,            128,  -",
        "DESede/CBC/PKCS5Padding, 3DES,         168,  -",
        "RC4,                   RC4,            0,    -",
        "SHA-384,               SHA-2,          384,  -",
        "SHA256,                SHA-2,          256,  -",
        "SHA3-256,              SHA-3,          256,  -",
        "SHA-1,                 SHA-1,          160,  -",
        "MD5,                   MD5,            0,    -",
        "HmacSHA384,            HMAC,           0,    SHA-2",
        "HKDF-SHA384,           HKDF,           0,    SHA-2",
        "PBKDF2,                PBKDF2,         0,    -",
        "SomethingNew,          unknown,        0,    -",
    })
    void describes(String name, String family, int keySize, String digest) {
        Algo.Info info = Algo.describe(name);
        assertEquals(family, info.family(), "家族");
        assertEquals(keySize, info.keySize(), "長度");
        assertEquals(digest, info.digest(), "雜湊");
    }
}
