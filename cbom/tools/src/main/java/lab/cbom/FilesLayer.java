package lab.cbom;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 檔案裡的憑證與金鑰（手冊第 33 章那張表的第 ① 層）：cbomkit-theia 掃目錄的結果 → CBOM。
 *
 * 輸入：raw/shared/theia.json（cbomkit-theia dir 的輸出，本身就是一份 CycloneDX CBOM）。沒有這個檔就回空的 BOM。
 *   Confluent Platform：只開憑證功能，掃的是原料目錄（各主機出示的憑證、操作機的憑證來源）。
 *   web app：掃原始碼目錄，另外開秘密功能（私鑰、寫死的秘密、keystore 檔，來源標 secret-scan）。
 * 產出：certificate、algorithm、related-crypto-material 元件，以及它們之間的相依關係（dependencies）。
 * 誰呼叫：Main（經 Layers）。真正的轉換在 TheiaAdapter.addTheia（和 ImageLayer 共用）。
 */
final class FilesLayer implements Layer {

    @Override
    public String id() {
        return "files";
    }

    @Override
    public String title() {
        return "檔案裡的憑證與金鑰（cbomkit-theia dir）";
    }

    @Override
    public ObjectNode convert(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        ArrayNode dependencies = bom.putArray("dependencies");
        Path file = raw.shared().resolve("theia.json");
        if (Files.isRegularFile(file)) {
            // 最後一個參數：憑證以外找到的東西（私鑰、秘密）要標成哪個來源
            TheiaAdapter.addTheia(bom, dependencies, Cdx.read(file), raw, "secret-scan");
        }
        return bom;
    }
}
