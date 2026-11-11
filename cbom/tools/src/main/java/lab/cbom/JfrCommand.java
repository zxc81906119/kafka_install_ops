package lab.cbom;

import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 第 ⑤ 層（可選）：執行期證據。JFR 錄製 → `jfr print --json` → CBOM。
 *
 * 輸入：raw/&lt;主機&gt;/jfr/*.json（收集腳本用 jcmd 對執行中的服務錄一段時間，再用 jfr print --json 轉出來）。
 * 用到的事件：
 *   jdk.SecurityProviderService   程式向 JDK 要了哪個演算法（type、algorithm、provider），附呼叫堆疊
 *   jdk.TLSHandshake              每次 TLS 交握（對方、協定版本、cipher suite）
 * 產出：
 *   algorithm 元件   錄製期間實際用到的演算法，屬性記 provider、次數、Kafka／Confluent 的呼叫點
 *   protocol 元件    實際完成的交握用的 TLS 版本與 cipher suite，屬性記次數與對方數
 *
 * 只看得到錄製期間發生的事：沒出現不代表不會用，所以是補充證據，不取代其他幾層。
 * 限制（lab 實測，JDK 25.0.5、Kafka 伺服器端）：jdk.TLSHandshake 只記到 TLS 1.3 的交握，TLS 1.2 的交握成功了也沒有事件，
 * 所以不能用它找「還在用 TLS 1.2 的用戶端」；事件裡也沒有金鑰交換群組（那要看 jdk.SecurityProviderService 的 KEM）。
 */
final class JfrCommand {

    /** 只收真正做運算的服務類型；KeyFactory、CertificateFactory 這些只是轉格式。 */
    private static final Set<String> SERVICE_TYPES = Set.of(
        "Cipher", "Mac", "MessageDigest", "KDF", "KEM", "KeyAgreement", "Signature", "KeyPairGenerator", "KeyGenerator",
        "SecretKeyFactory");

    private JfrCommand() {
    }

    static ObjectNode run(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        for (Raw.Host host : raw.hosts()) {
            Path jfrDir = raw.hostDir(host.name()).resolve("jfr");
            if (!Files.isDirectory(jfrDir)) {
                continue;
            }
            List<Path> files = new ArrayList<>();
            try (DirectoryStream<Path> stream = Files.newDirectoryStream(jfrDir, "*.json")) {
                stream.forEach(files::add);
            }
            files.sort(null);
            for (Path file : files) {
                recording(bom, host.name(), Cdx.read(file));
            }
        }
        return bom;
    }

    static void recording(ObjectNode bom, String host, JsonNode json) {
        Map<String, Integer> services = new TreeMap<>();
        Map<String, String> callSites = new TreeMap<>();
        Map<String, Integer> handshakes = new TreeMap<>();
        Map<String, Set<String>> peers = new TreeMap<>();

        for (JsonNode event : json.path("recording").path("events")) {
            JsonNode values = event.path("values");
            String type = event.path("type").asText();
            if ("jdk.SecurityProviderService".equals(type)) {
                String serviceType = values.path("type").asText();
                if (!SERVICE_TYPES.contains(serviceType)) {
                    continue;
                }
                String key = serviceType + "|" + values.path("algorithm").asText() + "|" + values.path("provider").asText();
                services.merge(key, 1, Integer::sum);
                if (!callSites.containsKey(key)) {
                    String callSite = callSite(values.path("stackTrace"));
                    if (callSite != null) {
                        callSites.put(key, callSite);
                    }
                }
            } else if ("jdk.TLSHandshake".equals(type)) {
                String key = values.path("protocolVersion").asText() + "|" + values.path("cipherSuite").asText();
                handshakes.merge(key, 1, Integer::sum);
                peers.computeIfAbsent(key, k -> new java.util.TreeSet<>()).add(values.path("peerHost").asText());
            }
        }

        for (Map.Entry<String, Integer> entry : services.entrySet()) {
            String[] parts = entry.getKey().split("\\|", 3);
            String algorithmName = parts[1];
            // 同一個演算法、同一個 provider 只記一筆；用到它的 JCA 類型都留在屬性裡
            ObjectNode algorithm = Cdx.asset("algorithm", algorithmName, "runtime|" + algorithmName + "|" + parts[2]);
            Algo.apply(algorithm, algorithmName);
            Cdx.prop(algorithm, "source", "runtime");
            Cdx.prop(algorithm, "use", "執行期實際使用");
            Cdx.prop(algorithm, "provider", parts[2]);
            Cdx.prop(algorithm, "jcaType", parts[0]);
            String callSite = callSites.get(entry.getKey());
            if (callSite != null) {
                Cdx.prop(algorithm, "callSite", callSite);
            }
            Cdx.occurrence(algorithm, host + ":JVM（" + parts[0] + "）", "錄製期間 " + entry.getValue() + " 次");
            Cdx.add(bom, algorithm);
        }

        for (Map.Entry<String, Integer> entry : handshakes.entrySet()) {
            String[] parts = entry.getKey().split("\\|", 2);
            String version = parts[0].replace("TLSv", "");
            ObjectNode protocol = Cdx.asset("protocol", "TLS " + version + "（實際交握）", "runtime-tls|" + entry.getKey());
            ObjectNode properties = Cdx.crypto(protocol, "protocolProperties");
            properties.put("type", "tls");
            properties.put("version", version);
            properties.putArray("cipherSuites").addObject().put("name", parts[1]);
            Cdx.prop(protocol, "source", "runtime");
            Cdx.prop(protocol, "tlsVersion", version);
            Cdx.prop(protocol, "cipherSuite", parts[1]);
            Cdx.occurrence(protocol, host + ":JVM",
                "錄製期間 " + entry.getValue() + " 次交握，對方 " + peers.get(entry.getKey()).size() + " 個位址");
            Cdx.add(bom, protocol);
        }
    }

    /** 堆疊裡第一個 Kafka 或 Confluent 的方法：這是原廠程式要用這個演算法的地方。 */
    private static String callSite(JsonNode stackTrace) {
        for (JsonNode frame : stackTrace.path("frames")) {
            String type = frame.path("method").path("type").path("name").asText();
            if (type.startsWith("org.apache.kafka.") || type.startsWith("io.confluent.") || type.startsWith("kafka.")) {
                String simple = type.replaceAll("\\$\\$Lambda.*", "").replaceAll("\\$\\d+$", "");
                return simple + "." + frame.path("method").path("name").asText();
            }
        }
        return null;
    }
}
