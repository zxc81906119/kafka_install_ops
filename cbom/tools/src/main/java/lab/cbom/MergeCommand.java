package lab.cbom;

import java.io.IOException;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 把各層（Layer）的結果併成一份 CBOM，再照 BomSteps.PIPELINE 一步一步處理
 * （盤點完整性、範圍、排序、metadata、驗證、版本、編號）。
 *
 * 輸入：每一層 convert() 的結果（片段，一份只有 components 與 dependencies 的 BOM），照 Layers.ALL 的順序。
 * 輸出：完整的 CBOM。
 * 誰呼叫：Main 的 build（各層剛轉好的片段）與 merge（從檔案讀回來的片段）。
 *
 * 同一個資產（同一個 bom-ref）只留一筆，出現位置累加；所以一張部署在 4 台 broker 的憑證是 1 個元件、4 個位置。
 */
final class MergeCommand {

    private MergeCommand() {
    }

    /** 合併，再照 PIPELINE 做每一步。specVersion 是 "1.7" 或 "1.6"。 */
    static ObjectNode run(Raw raw, List<JsonNode> fragments, String specVersion) throws IOException {
        ObjectNode bom = merge(fragments);
        BomStep.Context context = new BomStep.Context(raw, Profile.of(raw), specVersion);
        for (BomStep step : BomSteps.PIPELINE) {
            // 每一步回傳的 BOM 交給下一步（轉 1.6 那一步回的是新的物件）
            bom = step.apply(bom, context);
        }
        return bom;
    }

    /**
     * 元件依 bom-ref 合併（Cdx.add：先出現的留著，後面的只併出現位置與屬性）；相依關係照各層的順序接起來。
     * 片段是複製一份再併（deepCopy），不會改到傳進來的片段。沒有任何相依關係時不寫 dependencies 欄位。
     */
    static ObjectNode merge(List<JsonNode> fragments) {
        ObjectNode bom = Cdx.newBom();
        ArrayNode dependencies = Cdx.JSON.createArrayNode();
        for (JsonNode fragment : fragments) {
            for (JsonNode component : fragment.path("components")) {
                Cdx.add(bom, (ObjectNode) component.deepCopy());
            }
            for (JsonNode dependency : fragment.path("dependencies")) {
                dependencies.add(dependency.deepCopy());
            }
        }
        if (!dependencies.isEmpty()) {
            bom.set("dependencies", dependencies);
        }
        return bom;
    }
}
