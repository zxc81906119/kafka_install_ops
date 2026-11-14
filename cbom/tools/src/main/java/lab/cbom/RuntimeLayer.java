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
 * 第 ⑤ 層（可選；手冊第 33 章那張表的編號）：執行期證據。JFR 錄製 → `jfr print --json` → CBOM。
 *
 * 輸入：raw/&lt;主機&gt;/jfr/*.json（收集腳本用 jcmd 對執行中的服務錄一段時間，再用 jfr print --json 轉出來）。
 * 用到的事件：
 *   jdk.SecurityProviderService   程式向 JDK 要了哪個演算法（type、algorithm、provider），附呼叫堆疊
 *   jdk.TLSHandshake              每次 TLS 交握（對方、協定版本、cipher suite）
 * 產出（屬性 cbom:source 都是 runtime）：
 *   algorithm 元件   錄製期間實際用到的演算法，屬性記 provider、次數、Kafka／Confluent 的呼叫點
 *   protocol 元件    實際完成的交握用的 TLS 版本與 cipher suite，屬性記次數與對方數
 * 誰呼叫：Main（經 Layers）。
 *
 * 只看得到錄製期間發生的事：沒出現不代表不會用，所以是補充證據，不取代其他幾層。
 * 限制（lab 實測，JDK 25.0.5、Kafka 伺服器端）：jdk.TLSHandshake 只記到 TLS 1.3 的交握，TLS 1.2 的交握成功了也沒有事件，
 * 所以不能用它找「還在用 TLS 1.2 的用戶端」；事件裡也沒有金鑰交換群組（那要看 jdk.SecurityProviderService 的 KEM）。
 *
 * 一個事件在 JSON 裡的樣子（只列用到的欄位）：
 * <pre>
 * { "type": "jdk.SecurityProviderService",
 *   "values": { "type": "Cipher", "algorithm": "AES/GCM/NoPadding", "provider": "SunJCE",
 *               "stackTrace": { "frames": [ { "method": { "type": { "name": "javax.crypto.Cipher" }, "name": "getInstance" } }, … ] } } }
 * { "type": "jdk.TLSHandshake",
 *   "values": { "peerHost": "kb02.poc.lab", "protocolVersion": "TLSv1.3", "cipherSuite": "TLS_AES_256_GCM_SHA384" } }
 * </pre>
 */
final class RuntimeLayer implements Layer {

    /**
     * 只收真正做運算的服務類型；KeyFactory、CertificateFactory 這些只是轉格式。
     * 這是 jdk.SecurityProviderService 事件的 type 欄位（JCA 的服務類型）。要多收一種就加在這裡。
     */
    private static final Set<String> SERVICE_TYPES = Set.of(
        "Cipher", "Mac", "MessageDigest", "KDF", "KEM", "KeyAgreement", "Signature", "KeyPairGenerator", "KeyGenerator",
        "SecretKeyFactory", "SecureRandom");

    /** 同一個演算法最多記幾個不同的呼叫點（太多沒有用，報告也放不下）。 */
    private static final int MAX_CALL_SITES = 5;

    @Override
    public String id() {
        return "runtime";
    }

    @Override
    public String title() {
        return "執行期證據（JFR）";
    }

    @Override
    public ObjectNode convert(Raw raw) throws IOException {
        return run(raw);
    }

    /** 每台主機的 jfr/ 目錄裡每個 *.json（一個服務一個檔）交給 recording()。檔名排序後再處理，產出的順序才固定。 */
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
            // sort(null) = 照路徑的自然順序
            files.sort(null);
            for (Path file : files) {
                recording(bom, host.name(), Cdx.read(file));
            }
        }
        return bom;
    }

    /**
     * 一份錄製 → 元件。分兩段：先把事件數一遍（同樣的事件會出現幾千次，只要種類與次數），再把每一種寫成一個元件。
     *
     * 計數用「幾個欄位用 | 接起來」的字串當鍵，寫元件時再切開：
     * <pre>
     *   演算法：服務類型|演算法|provider      例：「Cipher|AES/GCM/NoPadding|SunJCE」→ 3 次
     *   交握：  協定版本|cipher suite          例：「TLSv1.3|TLS_AES_256_GCM_SHA384」→ 120 次、對方 3 個位址
     * </pre>
     */
    static void recording(ObjectNode bom, String host, JsonNode json) {
        Counts counts = countEvents(json);
        algorithmComponents(bom, host, counts);
        handshakeComponents(bom, host, counts);
    }

    /** 一份錄製數出來的結果。四張表的鍵都是「幾個欄位用 | 接起來」的字串；用 TreeMap／TreeSet 是為了順序固定。 */
    private static final class Counts {
        /** 「服務類型|演算法|provider」→ 出現幾次。 */
        final Map<String, Integer> services = new TreeMap<>();
        /** 「服務類型|演算法|provider」→ 呼叫點（最多 MAX_CALL_SITES 個）。 */
        final Map<String, Set<String>> callSites = new TreeMap<>();
        /** 「協定版本|cipher suite」→ 交握幾次。 */
        final Map<String, Integer> handshakes = new TreeMap<>();
        /** 「協定版本|cipher suite」→ 對方的位址。 */
        final Map<String, Set<String>> peers = new TreeMap<>();
    }

    /** 第一段：把錄製裡的事件數一遍。只看 jdk.SecurityProviderService 與 jdk.TLSHandshake 兩種事件，其他略過。 */
    private static Counts countEvents(JsonNode json) {
        Counts counts = new Counts();
        for (JsonNode event : json.path("recording").path("events")) {
            JsonNode values = event.path("values");
            String type = event.path("type").asText();
            if ("jdk.SecurityProviderService".equals(type)) {
                countService(counts, values);
            } else if ("jdk.TLSHandshake".equals(type)) {
                countHandshake(counts, values);
            }
        }
        return counts;
    }

    /** 一個「程式向 JDK 要演算法」的事件：次數加一，並記下是誰要的（呼叫點）。 */
    private static void countService(Counts counts, JsonNode values) {
        String serviceType = values.path("type").asText();
        // 不是做運算的服務類型（見 SERVICE_TYPES）→ 不收
        if (!SERVICE_TYPES.contains(serviceType)) {
            return;
        }
        String key = serviceType + "|" + values.path("algorithm").asText() + "|" + values.path("provider").asText();
        counts.services.merge(key, 1, Integer::sum);
        // 同一個演算法可能有好幾個地方在用（例如自己的程式與 JWT 函式庫）：最多記 5 個不同的
        String callSite = callSite(values.path("stackTrace"));
        if (callSite != null) {
            Set<String> known = counts.callSites.computeIfAbsent(key, k -> new java.util.TreeSet<>());
            if (known.size() < MAX_CALL_SITES) {
                known.add(callSite);
            }
        }
    }

    /** 一個 TLS 交握的事件：次數加一，並記下對方的位址。 */
    private static void countHandshake(Counts counts, JsonNode values) {
        String key = values.path("protocolVersion").asText() + "|" + values.path("cipherSuite").asText();
        counts.handshakes.merge(key, 1, Integer::sum);
        counts.peers.computeIfAbsent(key, k -> new java.util.TreeSet<>()).add(values.path("peerHost").asText());
    }

    /** 第二段之一：每一種「服務類型＋演算法＋provider」→ 一個 algorithm 元件，出現位置是「主機:JVM（服務類型）」。 */
    private static void algorithmComponents(ObjectNode bom, String host, Counts counts) {
        for (Map.Entry<String, Integer> entry : counts.services.entrySet()) {
            // 把鍵切回三段：parts[0] 服務類型、parts[1] 演算法、parts[2] provider。
            // 限制切成 3 段，演算法名稱裡的斜線不受影響（名稱裡不會有 |）
            String[] parts = entry.getKey().split("\\|", 3);
            String algorithmName = parts[1];
            // 同一個演算法、同一個 provider 只記一筆；用到它的 JCA 類型都留在屬性裡
            // （身分字串沒有服務類型，所以 Cipher 與 KeyGenerator 都用 AES 時是同一個元件，cbom:jcaType 有兩筆）
            ObjectNode algorithm = Cdx.asset("algorithm", algorithmName, "runtime|" + algorithmName + "|" + parts[2]);
            Algo.apply(algorithm, algorithmName);
            Cdx.prop(algorithm, "source", "runtime");
            Cdx.prop(algorithm, "use", "執行期實際使用");
            Cdx.prop(algorithm, "provider", parts[2]);
            Cdx.prop(algorithm, "jcaType", parts[0]);
            for (String callSite : counts.callSites.getOrDefault(entry.getKey(), Set.of())) {
                Cdx.prop(algorithm, "callSite", callSite);
            }
            Cdx.occurrence(algorithm, host + ":JVM（" + parts[0] + "）", "錄製期間 " + entry.getValue() + " 次");
            Cdx.add(bom, algorithm);
        }
    }

    /** 第二段之二：每一種「協定版本＋cipher suite」→ 一個 protocol 元件「TLS 版本（實際交握）」，出現位置是「主機:JVM」。 */
    private static void handshakeComponents(ObjectNode bom, String host, Counts counts) {
        for (Map.Entry<String, Integer> entry : counts.handshakes.entrySet()) {
            // parts[0] 協定版本（TLSv1.3）、parts[1] cipher suite
            String[] parts = entry.getKey().split("\\|", 2);
            // 「TLSv1.3」→「1.3」，和 TlsScanLayer 寫的版本同一種寫法
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
                "錄製期間 " + entry.getValue() + " 次交握，對方 " + counts.peers.get(entry.getKey()).size() + " 個位址");
            Cdx.add(bom, protocol);
        }
    }

    /**
     * 是誰要用這個演算法：堆疊裡第一個 Kafka 或 Confluent 的方法（原廠程式）；
     * 都沒有時（不是 Confluent Platform 的程式，例如一般的 web app）取第一個不屬於 JDK 的方法，通常是應用程式或它用的函式庫。
     * 整個堆疊都是 JDK 的方法時回 null（不記呼叫點）。
     *
     * 回傳「類別.方法」。例：「org.apache.kafka.common.security.ssl.DefaultSslEngineFactory.createSSLContext」。
     * 類別名稱會先整理：內部的 lambda 與匿名類別的尾巴拿掉，
     * 例：「io.confluent.Foo$$Lambda/0x0000…」→「io.confluent.Foo」、「kafka.server.Bar$1」→「kafka.server.Bar」。
     */
    private static String callSite(JsonNode stackTrace) {
        String firstOutsideJdk = null;
        for (JsonNode frame : stackTrace.path("frames")) {
            // 類別名稱在 JDK 21 的 jfr print --json 是 java/security/Provider，統一成用點分隔
            String type = frame.path("method").path("type").path("name").asText().replace('/', '.');
            // 第一個 regex：「$$Lambda」和它後面全部拿掉；第二個：結尾的「$數字」（匿名類別）拿掉
            String simple = type.replaceAll("\\$\\$Lambda.*", "").replaceAll("\\$\\d+$", "");
            String method = simple + "." + frame.path("method").path("name").asText();
            // 原廠程式的套件開頭
            if (type.startsWith("org.apache.kafka.") || type.startsWith("io.confluent.") || type.startsWith("kafka.")) {
                return method;
            }
            // JDK 自己的套件開頭
            boolean jdk = type.startsWith("java.") || type.startsWith("javax.") || type.startsWith("jdk.")
                || type.startsWith("sun.") || type.startsWith("com.sun.");
            if (firstOutsideJdk == null && !jdk && !type.isEmpty()) {
                firstOutsideJdk = method;
            }
        }
        return firstOutsideJdk;
    }
}
