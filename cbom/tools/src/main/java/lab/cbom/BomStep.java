package lab.cbom;

import java.io.IOException;

import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 合併之後的一步處理：拿一份 BOM，回一份 BOM（可以是同一個物件）。
 *
 * 有哪些步驟、照什麼順序做：BomSteps.PIPELINE。誰呼叫：MergeCommand.run 一步一步呼叫 apply。
 */
@FunctionalInterface
interface BomStep {

    /** 每一步都拿得到的東西：原料、盤點對象、要輸出的 CycloneDX 版本（"1.7" 或 "1.6"）。 */
    record Context(Raw raw, Profile profile, String specVersion) {
    }

    /** 做這一步。出錯（例如不符合 schema）丟 IOException，整個 build 失敗。 */
    ObjectNode apply(ObjectNode bom, Context context) throws IOException;
}
