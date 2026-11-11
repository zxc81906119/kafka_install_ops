package lab.cbom;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

/** 各工具給的演算法名稱 → 家族、金鑰長度、搭配的雜湊。規則靠這三樣判斷，所以每種寫法都要認得。 */
class AlgoTest {

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
