#!/usr/bin/env bash
# ============================================================================
# 產生 lab 用的金鑰、憑證與 keystore（全部是 LAB 專用的測試素材，切勿用於正式環境）
# 刻意「好壞並存」：讓盤點工具（cbomkit-theia 的憑證與秘密掃描）與 OPA 規則有東西可以抓。
#
#: 用法：
#:   bash scripts/generate-key-material.sh    重新產生 src/main/resources/crypto/ 底下所有金鑰與憑證（會覆蓋）
#:
#: 什麼時候需要執行：憑證快到期（有效期 825 天），或要換金鑰類型時。
#:   平常不用執行：產生好的檔案已經放在 src/main/resources/crypto/（刻意放進 git，原因見 README.md）。
#: 執行之後：
#:   1. ./mvnw -B verify 確認 app 還能啟動、測試通過
#:   2. 把 src/main/resources/crypto/ 的新檔案放進 git
#:   3. bash cbom/webapp/lab.sh up 把新的原始碼放進 Jenkins，再跑一次工作 cbom-webapp
#:      （憑證與金鑰都是新的，報告裡會跟著變，這是預期的）
#: 需要：openssl、keytool（JDK 內附）
#
# openssl req 常用的參數（下面四張憑證都用到）：
#   -x509            直接產生自簽憑證（不是憑證申請檔）
#   -newkey 類型      同時產生一把新的私鑰（rsa:2048 = RSA 2048 位元；ec = 橢圓曲線，曲線用 -pkeyopt 指定）
#   -sha256／-sha1    憑證簽章用的雜湊
#   -days 天數        憑證的有效天數
#   -nodes           私鑰檔不加密碼保護（no DES；lab 的測試金鑰才這樣做）
#   -subj            憑證的主體名稱；-addext 加上主機名稱（subjectAltName）
#   -keyout／-out     私鑰檔／憑證檔要寫到哪裡
# ============================================================================

# 任何一行失敗就停（-e）、用到沒設定的變數就停（-u）、管線中任何一段失敗都算失敗（pipefail）
set -euo pipefail

# 1. 讀參數：-h 印出上面「#:」開頭的用法；不接受其他參數（結束碼 64 = 用法錯誤）
case "${1:-}" in
  -h|--help)
    sed -n 's/^#: \{0,1\}//p' "$0"
    exit 0
    ;;
  "")
    ;;
  *)
    sed -n 's/^#: \{0,1\}//p' "$0" >&2
    exit 64
    ;;
esac

# 2. 切到專案根目錄（這支腳本的上一層），下面的路徑都相對於它
cd "$(dirname "$0")/.."

# 3. 確認需要的兩個指令都在
for cmd in openssl keytool; do
  if ! command -v "$cmd" > /dev/null; then
    echo "找不到 $cmd（keytool 在 JDK 的 bin 目錄）" >&2
    exit 1
  fi
done

# 4. 輸出目錄與 keystore 的密碼
#    PASS 是 lab 專用的測試密碼，必須和 application.yml 三個 keystore／truststore 的 password 相同
OUT=src/main/resources/crypto
PASS=changeit-lab-only

# 5. 建立三個子目錄：tls（HTTPS 憑證）、jwt（JWT 簽章金鑰）、legacy（故意放的弱憑證）
mkdir -p "$OUT/tls" "$OUT/jwt" "$OUT/legacy"

# 6. Git Bash 專用：避免把 /C=TW/... 這種參數轉成 Windows 路徑
export MSYS_NO_PATHCONV=1

# 7. TLS 憑證（主要的 HTTPS 憑證）：RSA-2048＋SHA256withRSA
#    [可接受·量子脆弱]　標準答案：CERT-RSA2048
#    -days 825：825 天是瀏覽器曾經接受的 TLS 憑證最長有效期
openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
  -subj "/C=TW/O=CBOM Lab/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:crypto-lab,IP:127.0.0.1" \
  -keyout "$OUT/tls/server-rsa2048.key" -out "$OUT/tls/server-rsa2048.crt"

# 8. 把上一步的私鑰與憑證包成 PKCS12 keystore（Spring Boot 讀這個檔）；-name = keystore 裡的別名
openssl pkcs12 -export -name server -passout pass:$PASS \
  -inkey "$OUT/tls/server-rsa2048.key" -in "$OUT/tls/server-rsa2048.crt" \
  -out "$OUT/tls/server-rsa2048.p12"

# 9. TLS 憑證（替代的 SSL bundle）：EC P-256＋SHA256withECDSA
#    [可接受·量子脆弱]　標準答案：CERT-EC
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 825 -nodes \
  -subj "/C=TW/O=CBOM Lab/CN=localhost-ec" \
  -keyout "$OUT/tls/server-ec-p256.key" -out "$OUT/tls/server-ec-p256.crt"

# 10. 同第 8 步，包成 PKCS12 keystore（別名 server-ec）
openssl pkcs12 -export -name server-ec -passout pass:$PASS \
  -inkey "$OUT/tls/server-ec-p256.key" -in "$OUT/tls/server-ec-p256.crt" \
  -out "$OUT/tls/server-ec-p256.p12"

# 11. JWT 簽章金鑰 RS256：RSA-2048 私鑰（PKCS#8 格式的 PEM），再從私鑰導出公鑰
#     [壞例子·故意] 私鑰 PEM 放在原始碼庫　標準答案：KEY-JWT-PEM
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$OUT/jwt/jwt-rs256-private.pem"
openssl pkey -in "$OUT/jwt/jwt-rs256-private.pem" -pubout -out "$OUT/jwt/jwt-rs256-public.pem"

# 12. JWT 簽章金鑰 ES256：EC P-256 私鑰，再導出公鑰（同樣是 KEY-JWT-PEM）
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$OUT/jwt/jwt-es256-private.pem"
openssl pkey -in "$OUT/jwt/jwt-es256-private.pem" -pubout -out "$OUT/jwt/jwt-es256-public.pem"

# 13. 故意的弱憑證：RSA-1024＋SHA1withRSA（扮演「合作夥伴的舊憑證」）
#     [壞例子·故意] 金鑰太短、SHA-1 已有碰撞　標準答案：CERT-LEGACY
#     -days 3650：十年，舊系統常見的超長有效期（也是故意的）
openssl req -x509 -newkey rsa:1024 -sha1 -days 3650 -nodes \
  -subj "/C=TW/O=CBOM Lab/CN=legacy-partner" \
  -keyout "$OUT/legacy/legacy-rsa1024-sha1.key" -out "$OUT/legacy/legacy-rsa1024-sha1.crt"

# 14. 把弱憑證放進 JKS 格式的 truststore（舊格式，也是故意的）
#     先刪掉舊檔：keytool 遇到已經有同一個別名的 keystore 會失敗
rm -f "$OUT/legacy/legacy-truststore.jks"
keytool -importcert -noprompt -alias legacy-partner -file "$OUT/legacy/legacy-rsa1024-sha1.crt" \
  -keystore "$OUT/legacy/legacy-truststore.jks" -storetype JKS -storepass $PASS

# 15. 完成
echo "Key material generated under $OUT"
