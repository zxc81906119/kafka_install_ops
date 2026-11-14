package lab.cbom;

import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * cbom-tools：把收集到的原料做成 CycloneDX CBOM，再把 OPA 的判斷結果做成 HTML 報告。
 * 這個類別是程式的入口：看第一個參數是哪個子指令，檢查參數個數，再呼叫對應的方法。
 * 誰呼叫：cbom/cbom-report.sh（build、report、crypto-only）；人查問題時手動下 layers、convert、merge。
 *
 * <pre>
 * java -jar cbom-tools.jar build  &lt;原料目錄&gt; &lt;cbom.json&gt; [--spec 1.7|1.6]
 * java -jar cbom-tools.jar report &lt;cbom.json&gt; &lt;findings.json&gt; &lt;report.html&gt; [--external-css]
 * </pre>
 *
 * build 一次做完「每一層轉換 → 合併 → 驗證」。要查某一層的問題時，可以分開做（結果和 build 相同）：
 * <pre>
 * java -jar cbom-tools.jar layers  &lt;原料目錄&gt;                          這份原料會用到哪幾層
 * java -jar cbom-tools.jar convert &lt;層&gt; &lt;原料目錄&gt; &lt;片段.json&gt;          只轉一層
 * java -jar cbom-tools.jar merge   &lt;原料目錄&gt; &lt;cbom.json&gt; &lt;片段.json&gt;… [--spec 1.7|1.6]
 * </pre>
 *
 * 另外一個：把 CBOM 上傳到 CBOMkit 平台之前，只留密碼學資產（原因見 cryptoOnly 的說明）：
 * <pre>
 * java -jar cbom-tools.jar crypto-only &lt;cbom.json&gt; &lt;輸出.json&gt;
 * </pre>
 *
 * 有標準答案（這個對象實際用到的密碼學資產清單）時，對答案（說明見 InventoryCheck；結果不影響結束碼）：
 * <pre>
 * java -jar cbom-tools.jar check-inventory &lt;cbom.json&gt; &lt;findings.json&gt; &lt;expected-inventory.json&gt; &lt;輸出.txt&gt;
 * </pre>
 *
 * 結束碼：0 成功；1 用法不對；2 執行失敗（訊息印在 stderr）。
 *
 * 整個流程哪一段在哪個類別：
 * <pre>
 * 原料目錄（Raw）→ 盤點對象（Profile）選出幾層 → 每層轉成元件（Layer，演算法名稱由 Algo 整理，JSON 由 Cdx 組）
 *   → 合併（MergeCommand）→ 後續處理（BomSteps）→ cbom.json
 * cbom.json ＋ OPA 的判定結果 → ReportCommand → report.html
 * </pre>
 */
public final class Main {

    /** 沒有指定 --spec 時輸出的 CycloneDX 版本。 */
    private static final String DEFAULT_SPEC = "1.7";

    private Main() {
    }

    /** 程式的入口：設定輸出的編碼，執行子指令，決定結束碼（0 成功、1 用法不對、2 執行失敗）。 */
    public static void main(String[] args) {
        // 訊息一律用 UTF-8 印出，不跟著主機的語系設定（否則中文會變成問號）
        System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.out), true, StandardCharsets.UTF_8));
        System.setErr(new PrintStream(new FileOutputStream(FileDescriptor.err), true, StandardCharsets.UTF_8));
        try {
            boolean known = runSubcommand(args);
            if (!known) {
                // 不認得的子指令，或參數個數不對：印用法，結束碼 1
                printUsage();
                System.exit(1);
            }
        } catch (Exception e) {
            System.err.println("失敗：" + e.getMessage());
            System.exit(2);
        }
    }

    /**
     * 看 args[0] 是哪個子指令、參數個數對不對，對了就執行並回 true；都不符合回 false（由 main 印用法）。
     * 每個 if 是一個子指令：後面的數字是「連同子指令名稱至少（或剛好）要幾個參數」。
     */
    private static boolean runSubcommand(String[] args) throws Exception {
        if (args.length >= 3 && "build".equals(args[0])) {
            // 第 4 個參數起（索引 3）是選項；build 只認 --spec，其他多給的參數不理會
            String spec = specOption(args, 3, new ArrayList<>());
            build(Path.of(args[1]), Path.of(args[2]), spec);
            return true;
        }
        if (args.length >= 4 && "report".equals(args[0])) {
            // --external-css 只認第 5 個參數（索引 4）
            boolean externalCss = args.length > 4 && "--external-css".equals(args[4]);
            ReportCommand.run(Path.of(args[1]), Path.of(args[2]), Path.of(args[3]), externalCss);
            return true;
        }
        if (args.length == 3 && "crypto-only".equals(args[0])) {
            cryptoOnly(Path.of(args[1]), Path.of(args[2]));
            return true;
        }
        if (args.length == 5 && "check-inventory".equals(args[0])) {
            InventoryCheck.run(Path.of(args[1]), Path.of(args[2]), Path.of(args[3]), Path.of(args[4]));
            return true;
        }
        if (args.length == 2 && "layers".equals(args[0])) {
            layers(Path.of(args[1]));
            return true;
        }
        if (args.length == 4 && "convert".equals(args[0])) {
            convert(args[1], Path.of(args[2]), Path.of(args[3]));
            return true;
        }
        if (args.length >= 4 && "merge".equals(args[0])) {
            // 第 4 個參數起：--spec 與它的值是選項，其餘每一個都是片段檔
            List<String> fragmentNames = new ArrayList<>();
            String spec = specOption(args, 3, fragmentNames);
            List<Path> fragments = new ArrayList<>();
            for (String name : fragmentNames) {
                fragments.add(Path.of(name));
            }
            merge(Path.of(args[1]), Path.of(args[2]), fragments, spec);
            return true;
        }
        return false;
    }

    /** 把用法印到 stderr。加了子指令或選項時，這裡與檔頭的說明要一起改。 */
    private static void printUsage() {
        System.err.println("用法：");
        System.err.println("  java -jar cbom-tools.jar build  <原料目錄> <cbom.json> [--spec 1.7|1.6]");
        System.err.println("  java -jar cbom-tools.jar report <cbom.json> <findings.json> <report.html> [--external-css]");
        System.err.println("選用：");
        System.err.println("  java -jar cbom-tools.jar layers  <原料目錄>                     這份原料會用到哪幾層");
        System.err.println("  java -jar cbom-tools.jar convert <層> <原料目錄> <片段.json>     只轉一層");
        System.err.println("  java -jar cbom-tools.jar merge   <原料目錄> <cbom.json> <片段.json>… [--spec 1.7|1.6]");
        System.err.println("  java -jar cbom-tools.jar crypto-only <cbom.json> <輸出.json>     只留密碼學資產（給 CBOMkit 平台）");
        System.err.println("  java -jar cbom-tools.jar check-inventory <cbom.json> <findings.json> <標準答案.json> <輸出.txt>");
        System.err.println("                                                                   對答案：找到幾項、等級對不對");
    }

    /**
     * 從 args[from] 開始找「--spec 值」，回傳那個值；沒有就是 1.7。不是 --spec 的參數照順序放進 others。
     * <pre>
     * 例（from = 3）：
     *   build raw out.json --spec 1.6            → 回 "1.6"，others 是空的
     *   merge raw out.json a.json --spec 1.6 b.json → 回 "1.6"，others = [a.json, b.json]
     *   merge raw out.json a.json                → 回 "1.7"，others = [a.json]
     * </pre>
     * 寫了兩次 --spec 時以後面的為準。--spec 是最後一個參數（後面沒有值）時不當成選項，照一般參數放進 others。
     * 值對不對（只能是 1.7、1.6）不在這裡檢查，由 BomSteps.specVersion 檢查。
     */
    static String specOption(String[] args, int from, List<String> others) {
        String spec = DEFAULT_SPEC;
        for (int i = from; i < args.length; i++) {
            boolean hasValue = i + 1 < args.length;
            if ("--spec".equals(args[i]) && hasValue) {
                spec = args[i + 1];
                // 值已經用掉了，跳過它
                i++;
            } else {
                others.add(args[i]);
            }
        }
        return spec;
    }

    /**
     * 只留密碼學資產（有 cryptoProperties 的元件）。CBOMkit 平台內建的合規檢查遇到 file、library 這類
     * 沒有 cryptoProperties 的元件會出錯（2.3.0 實測），上傳給它之前先濾掉；完整的那份照舊留著。
     */
    static void cryptoOnly(Path input, Path output) throws Exception {
        ObjectNode bom = (ObjectNode) Cdx.read(input);
        com.fasterxml.jackson.databind.node.ArrayNode kept = Cdx.JSON.createArrayNode();
        int dropped = 0;
        for (JsonNode component : bom.path("components")) {
            if (component.has("cryptoProperties")) {
                kept.add(component);
            } else {
                dropped++;
            }
        }
        bom.set("components", kept);
        // 內容變了，編號重算（CBOMkit 的網頁要有 serialNumber 才顯示）
        BomSteps.serialNumber(bom);
        Cdx.write(output, bom);
        System.out.println("只留密碼學資產：" + kept.size() + " 個（拿掉 " + dropped + " 個 file、library），寫到 " + output);
    }

    /** 印出這份原料的盤點對象，以及它會用到的每一層（一行一層：id、Tab、說明）。 */
    static void layers(Path rawDir) throws Exception {
        Raw raw = new Raw(rawDir);
        Profile profile = Profile.of(raw);
        System.out.println("盤點對象：" + profile.id());
        for (Layer layer : Layers.of(profile.layers())) {
            System.out.println(layer.id() + "\t" + layer.title());
        }
    }

    /** 只轉一層：結果是一份只有那一層元件的片段，還沒有標範圍、沒有 metadata。layerId 是 Layer.id()，例如 tls。 */
    static void convert(String layerId, Path rawDir, Path output) throws Exception {
        Raw raw = new Raw(rawDir);
        Layer layer = Layers.of(List.of(layerId)).get(0);
        ObjectNode fragment = layer.convert(raw);
        Cdx.write(output, fragment);
        System.out.println(layer.id() + "（" + layer.title() + "）：" + fragment.path("components").size() + " 個元件，寫到 " + output);
    }

    /** 把 convert 的片段併成完整的 CBOM；片段照盤點對象的各層順序給，結果就和 build 相同。 */
    static void merge(Path rawDir, Path output, List<Path> fragmentFiles, String spec) throws Exception {
        Raw raw = new Raw(rawDir);
        List<JsonNode> fragments = new ArrayList<>();
        for (Path file : fragmentFiles) {
            fragments.add(Cdx.read(file));
        }
        ObjectNode bom = MergeCommand.run(raw, fragments, spec);
        Cdx.write(output, bom);
        System.out.println("CBOM（CycloneDX " + spec + "）：" + bom.path("components").size() + " 個元件，寫到 " + output);
    }

    /**
     * 主要的子指令：原料目錄 → 完整的 CBOM 檔。做完印三行摘要：
     * 各種元件的數量（例：{algorithm=41, certificate=9, file=30, …}）、範圍、寫到哪裡。
     */
    static void build(Path rawDir, Path output, String spec) throws Exception {
        Raw raw = new Raw(rawDir);
        List<JsonNode> fragments = new ArrayList<>();
        // 盤點對象決定用哪幾層；每一層把自己那個工具的輸出轉成元件
        for (Layer layer : Layers.of(Profile.of(raw).layers())) {
            fragments.add(layer.convert(raw));
        }
        ObjectNode bom = MergeCommand.run(raw, fragments, spec);
        Cdx.write(output, bom);

        // 數每一種元件有幾個。種類：密碼學資產看 assetType，其他元件看 type（和 BomSteps.sortKey 同一個算法）
        Map<String, Integer> counts = new TreeMap<>();
        for (JsonNode component : bom.path("components")) {
            String kind = component.path("cryptoProperties").path("assetType").asText(component.path("type").asText());
            counts.merge(kind, 1, Integer::sum);
        }
        System.out.println("CBOM（CycloneDX " + spec + "）：" + bom.path("components").size() + " 個元件 " + counts);
        System.out.println("範圍：" + (raw.fullScope() ? "完整" : "部分") + "（" + raw.get("ROLES") + "）");
        System.out.println("已通過官方 schema 驗證，寫到 " + output);
    }
}
