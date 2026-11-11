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
 *
 * <pre>
 * java -jar cbom-tools.jar build  &lt;原料目錄&gt; &lt;cbom.json&gt; [--spec 1.7|1.6]
 * java -jar cbom-tools.jar report &lt;cbom.json&gt; &lt;findings.json&gt; &lt;report.html&gt; [--external-css]
 * </pre>
 *
 * 結束碼：0 成功；1 用法不對；2 執行失敗（訊息印在 stderr）。
 */
public final class Main {

    private Main() {
    }

    public static void main(String[] args) {
        // 訊息一律用 UTF-8 印出，不跟著主機的語系設定（否則中文會變成問號）
        System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.out), true, StandardCharsets.UTF_8));
        System.setErr(new PrintStream(new FileOutputStream(FileDescriptor.err), true, StandardCharsets.UTF_8));
        try {
            if (args.length >= 3 && "build".equals(args[0])) {
                String spec = "1.7";
                for (int i = 3; i + 1 < args.length; i++) {
                    if ("--spec".equals(args[i])) {
                        spec = args[i + 1];
                    }
                }
                build(Path.of(args[1]), Path.of(args[2]), spec);
                return;
            }
            if (args.length >= 4 && "report".equals(args[0])) {
                boolean externalCss = args.length > 4 && "--external-css".equals(args[4]);
                ReportCommand.run(Path.of(args[1]), Path.of(args[2]), Path.of(args[3]), externalCss);
                return;
            }
            System.err.println("用法：");
            System.err.println("  java -jar cbom-tools.jar build  <原料目錄> <cbom.json> [--spec 1.7|1.6]");
            System.err.println("  java -jar cbom-tools.jar report <cbom.json> <findings.json> <report.html> [--external-css]");
            System.exit(1);
        } catch (Exception e) {
            System.err.println("失敗：" + e.getMessage());
            System.exit(2);
        }
    }

    static void build(Path rawDir, Path output, String spec) throws Exception {
        Raw raw = new Raw(rawDir);
        List<JsonNode> fragments = new ArrayList<>();
        fragments.add(TlsCommand.run(raw));
        fragments.add(ConfigCommand.run(raw));
        fragments.add(JdkCommand.run(raw));
        fragments.add(LibsCommand.run(raw));
        fragments.add(JfrCommand.run(raw));
        ObjectNode bom = MergeCommand.run(raw, fragments, spec);
        Cdx.write(output, bom);

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
