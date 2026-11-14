package lab.cbom;

import java.io.IOException;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 盤點對象：Confluent Platform。沒有原始碼，原料由操作機逐台收（cbom/cbom-collect.sh；collect.env 的 PROFILE=cp 或沒寫）。
 * 用六層：TLS 掃描、平台設定、JDK 與 OS 設定、函式庫、執行期證據、檔案裡的憑證。
 */
final class ConfluentPlatformProfile implements Profile {

    @Override
    public String id() {
        return "cp";
    }

    @Override
    public List<String> layers() {
        return List.of("tls", "config", "jdk", "libraries", "runtime", "files");
    }

    /** CBOM 的主角：類型 platform，名稱「Confluent Platform（環境）」，版本是 collect.env 的 CP_VERSION。 */
    @Override
    public void subject(ObjectNode subject, Raw raw) {
        subject.put("type", "platform");
        subject.put("bom-ref", "platform:confluent-platform-" + raw.get("ENV"));
        subject.put("name", "Confluent Platform（" + raw.get("ENV") + "）");
        if (!raw.get("CP_VERSION").isEmpty()) {
            subject.put("version", raw.get("CP_VERSION"));
        }
    }

    /**
     * theia 掃的是原料目錄，拿到的路徑是收集腳本放檔的位置；這裡換回「這張憑證實際在哪裡」。
     * 回傳 {位置, 說明}。照路徑的樣子分三種（檔名是舉例）：
     * <pre>
     *   kb01/served/9092.pem   → {"kb01.poc.lab:9092", "這個埠實際出示的憑證鏈"}        第二段是 served
     *   shared/pki/kb01.crt    → {"ops02:~/pki/certs/kb01.crt", "操作機的憑證來源"}      開頭是 shared/pki
     *   kb01/ca.crt            → {"kb01:/etc/confluent/ssl/ca.crt", "主機上的憑證檔"}    只有兩段，第一段是 collect.env 的 HOSTS 裡的主機
     *   其他                   → {路徑原樣, ""}
     * </pre>
     * 「ops02:~/pki/certs」與「/etc/confluent/ssl」是這個平台固定的位置，寫死在這裡（顯示用，不會真的去讀）。
     */
    @Override
    public String[] location(String path, Raw raw) {
        String[] parts = path.replace('\\', '/').split("/");
        if (parts.length >= 3 && "served".equals(parts[1])) {
            return new String[] {raw.fqdn(parts[0]) + ":" + parts[2].replace(".pem", ""), "這個埠實際出示的憑證鏈"};
        }
        if (parts.length >= 3 && "shared".equals(parts[0]) && "pki".equals(parts[1])) {
            return new String[] {"ops02:~/pki/certs/" + parts[2], "操作機的憑證來源"};
        }
        if (parts.length == 2 && raw.hosts().stream().anyMatch(h -> h.name().equals(parts[0]))) {
            return new String[] {parts[0] + ":/etc/confluent/ssl/" + parts[1], "主機上的憑證檔"};
        }
        return new String[] {path, ""};
    }

    /**
     * Confluent 的 RPM 把 jar 裝在 /usr/share/java 底下（收集腳本 cbom-collect.sh 也是從這個目錄取 jar 清單與 jar）。
     * 例：libraryLocation("kb01", "3f9a1c0b77de") → {"kb01:/usr/share/java", "jar 組 3f9a1c0b77de"}。
     * 「jar 組」= jar 清單完全相同的一組主機，雜湊是那份清單的雜湊。
     */
    @Override
    public String[] libraryLocation(String host, String digest) {
        return new String[] {host + ":/usr/share/java", "jar 組 " + digest};
    }

    /** 用平台自己的設定當對照（設定檔說有開 TLS 的埠就要掃得到…）；十條檢查寫在 CollectionCheck 的檔頭。 */
    @Override
    public List<String> collectionGaps(Raw raw, JsonNode bom) throws IOException {
        return CollectionCheck.confluentPlatform(raw, bom);
    }

    /** Confluent Platform 這種盤點方法（沒有原始碼，只看部署出來的東西）看不到的事。改這裡的文字，報告最後一節就跟著改。 */
    @Override
    public List<String> blindSpots() {
        return List.of(
            "套件內部怎麼用密碼學：原廠的程式沒有原始碼，只列得出帶了哪些密碼函式庫與版本，看不到函式庫在裡面怎麼被使用。",
            "不經過 JDK 密碼學 API 的實作（例如函式庫自己用純 Java 寫的 bcrypt、Argon2）：執行期證據只記得到程式向 JDK 要演算法的那些呼叫。",
            "沒有演算法可列的弱點（例如 JWT 的 alg=none、程式裡關掉憑證驗證）：盤點列的是「用了什麼」，列不出「該用而沒用」。",
            "用法上的錯誤（固定的 IV、寫死的 salt、重複使用的 nonce）：從設定檔與執行期事件看不出來。",
            "執行期證據只涵蓋錄製的那段時間裡實際發生的：沒出現不代表不會用。",
            "TLS 只掃得到掃描當時有在聽、而且從操作機連得到的埠；服務當用戶端連出去時用的設定，只看得到設定檔寫的。");
    }
}
