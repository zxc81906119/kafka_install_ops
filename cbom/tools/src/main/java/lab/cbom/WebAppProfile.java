package lab.cbom;

import java.io.IOException;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 盤點對象：web app。有原始碼、以容器映像部署，原料由 cbom/webapp/webapp-collect.sh 收（collect.env 的 PROFILE=webapp）。
 * 比 Confluent Platform 多了原始碼（source）與映像（image）兩層，少了平台設定（config）。
 */
final class WebAppProfile implements Profile {

    @Override
    public String id() {
        return "webapp";
    }

    @Override
    public List<String> layers() {
        return List.of("tls", "jdk", "libraries", "runtime", "source", "files", "image");
    }

    /**
     * CBOM 的主角：類型 application，名稱是 collect.env 的 SUBJECT_NAME（沒寫就叫「web app」）加環境名稱。
     * 版本讀的欄位叫 CP_VERSION：這個欄位名是 Confluent Platform 先用的，web app 沿用同一個名字放自己的版本
     * （webapp-collect.sh 寫的是應用程式的版本）。欄位名不能改，收集腳本與既有的原料都用它。
     */
    @Override
    public void subject(ObjectNode subject, Raw raw) {
        String name = raw.get("SUBJECT_NAME").isEmpty() ? "web app" : raw.get("SUBJECT_NAME");
        subject.put("type", "application");
        subject.put("bom-ref", "application:" + name + "-" + raw.get("ENV"));
        subject.put("name", name + "（" + raw.get("ENV") + "）");
        if (!raw.get("CP_VERSION").isEmpty()) {
            subject.put("version", raw.get("CP_VERSION"));
        }
    }


    /** theia 掃的是原始碼目錄與映像，路徑本身就是位置：原樣回傳，說明留空。 */
    @Override
    public String[] location(String path, Raw raw) {
        return new String[] {path, ""};
    }

    /**
     * web app 的函式庫包在它自己的可執行 jar 裡，目錄是 BOOT-INF/lib（Spring Boot 的可執行 jar 固定的結構）。
     * 例：libraryLocation("app", "3f9a1c0b77de") → {"app:可執行 jar 的 BOOT-INF/lib", "可執行 jar 的 sha256 前 12 碼 3f9a1c0b77de"}。
     *
     * 依據（cbom/webapp/webapp-collect.sh 的 build 步驟）：函式庫清單是建置時 cyclonedx-maven-plugin 產生的 SBOM；
     * groups.txt 只有一行「雜湊 app」，雜湊是可執行 jar 的 sha256 前 12 碼；同一支腳本從 jar 的 BOOT-INF/lib 解出相依的 jar。
     * 原料裡沒有 jar 的檔名，也沒有它部署在容器裡的路徑，所以位置只寫到「可執行 jar 的 BOOT-INF/lib」，不編路徑。
     */
    @Override
    public String[] libraryLocation(String host, String digest) {
        return new String[] {host + ":可執行 jar 的 BOOT-INF/lib", "可執行 jar 的 sha256 前 12 碼 " + digest};
    }

    /** 每一種掃描的原料都要在；有做執行期時 TLS 掃描與 JFR 也要在。檢查寫在 CollectionCheck 的檔頭。 */
    @Override
    public List<String> collectionGaps(Raw raw, JsonNode bom) throws IOException {
        return CollectionCheck.webApp(raw);
    }

    /** web app 這種盤點方法（原始碼、建置、映像、執行期四段）看不到的事。改這裡的文字，報告最後一節就跟著改。 */
    @Override
    public List<String> blindSpots() {
        return List.of(
            "相依的函式庫內部怎麼用密碼學：原始碼掃描只看這個專案自己的程式，函式庫只列得出名稱與版本。",
            "不經過 JDK 密碼學 API 的實作（例如純 Java 寫的 bcrypt、Argon2）：原始碼掃描與執行期證據認的都是 JDK 的密碼學 API，這類不會出現。",
            "沒有演算法可列的弱點（例如 JWT 的 alg=none、程式裡關掉憑證驗證）：盤點列的是「用了什麼」，列不出「該用而沒用」。",
            "用法上的錯誤（固定的 IV、寫死的 salt、重複使用的 nonce）：盤點只知道用了哪個演算法，不知道參數給得對不對。",
            "用非密碼學的亂數（java.util.Random）產生 token 或金鑰：它不是密碼學 API，不會被列出來。",
            "執行期證據只涵蓋錄製的那段時間裡實際發生的：測試流量沒有走到的功能不會出現。",
            "TLS 只掃得到掃描當時有在聽的埠；程式當用戶端連出去時用的 TLS 設定不在掃描範圍。");
    }
}
