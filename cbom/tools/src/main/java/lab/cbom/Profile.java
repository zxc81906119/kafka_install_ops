package lab.cbom;

import java.io.IOException;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 盤點對象。不同的對象差在這幾件事，都集中在這裡：用哪幾層、CBOM 的主角怎麼寫、原料裡的路徑怎麼顯示成位置、函式庫放在哪裡、
 * 原料該有哪些（盤點完整性）、這種盤點方法看不到什麼。
 * 收集腳本在 collect.env 寫 PROFILE=cp 或 PROFILE=webapp；沒寫當成 cp（舊的原料）。
 *
 * 現有兩種：ConfluentPlatformProfile（cp）、WebAppProfile（webapp）。
 * 誰呼叫：Main（決定用哪幾層）、MergeCommand 與 BomSteps.METADATA（寫主角）、TheiaAdapter（顯示位置）、LibraryLayer（函式庫的位置）。
 * 要加一種對象：寫一個 Profile，加進 of() 的判斷。
 */
interface Profile {

    /** collect.env 的 PROFILE 值：cp 或 webapp。 */
    String id();

    /** 要用的 Layer（Layers 裡登記的 id）。寫的順序沒有影響，合併一律照 Layers.ALL 的順序。 */
    List<String> layers();

    /** 寫 metadata.component：這份 CBOM 講的是誰（類型、名稱、版本）。subject 是已經建好的空物件，把欄位填進去。 */
    void subject(ObjectNode subject, Raw raw);

    /**
     * 原料目錄裡的相對路徑 → 兩個字串的陣列：[0] 給人看的位置、[1] 說明（沒有就是空字串）。
     * 例（cp）：「kb01/served/9092.pem」→ {"kb01.poc.lab:9092", "這個埠實際出示的憑證鏈"}。
     */
    String[] location(String path, Raw raw);

    /**
     * 密碼函式庫（LibraryLayer 的元件）在這台主機上的哪裡 → 兩個字串的陣列：[0] 位置、[1] 說明。
     * host 是 groups.txt 裡的主機名稱，digest 是那一組的雜湊（groups.txt 的第一欄）。
     * SBOM 只列出有哪些函式庫，沒有每個 jar 的路徑，所以這裡給的是「這種對象的函式庫固定放在哪裡」。
     */
    String[] libraryLocation(String host, String digest);

    /**
     * 盤點完整性：這次的原料「該有而沒有的」，一個缺口一句話（給人看的）；都齊了回空的清單。
     * bom 是各層合併好的元件。每種對象檢查什麼寫在 CollectionCheck 的檔頭。
     */
    List<String> collectionGaps(Raw raw, JsonNode bom) throws IOException;

    /** 「這份盤點看不到什麼」：報告最後一節的固定文字，一點一句。盤點方法本身的限制，和這次收得齊不齊無關。 */
    List<String> blindSpots();

    /** 依 collect.env 的 PROFILE 選出盤點對象；不認得的值丟例外。 */
    static Profile of(Raw raw) {
        return byId(raw.get("PROFILE"));
    }

    /** id → 盤點對象。空字串當成 cp（舊的原料沒有 PROFILE）；不認得的值丟例外。報告用 CBOM 裡記的 cbom:profile 呼叫這一個。 */
    static Profile byId(String id) {
        if (id.isEmpty() || "cp".equals(id)) {
            return new ConfluentPlatformProfile();
        }
        if ("webapp".equals(id)) {
            return new WebAppProfile();
        }
        throw new IllegalArgumentException("collect.env 的 PROFILE 不認得：" + id + "（可以是 cp、webapp）");
    }
}
