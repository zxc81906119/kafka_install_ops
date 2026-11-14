package lab.cbom;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 容器映像：cbomkit-theia 掃映像的結果 → CBOM。只有以映像部署的對象才有（目前是 web app）。
 *
 * 輸入：raw/shared/theia-image.json（cbomkit-theia image 的輸出）。沒有這個檔就回空的 BOM。
 * 產出：映像裡的憑證與金鑰、OpenSSL 設定檔、一筆「映像內建的 CA 信任庫」（只記張數），來源標 image-scan。
 * 誰呼叫：Main（經 Layers）。留什麼、不留什麼的判斷在 TheiaAdapter.addTheiaImage。
 */
final class ImageLayer implements Layer {

    @Override
    public String id() {
        return "image";
    }

    @Override
    public String title() {
        return "容器映像（cbomkit-theia image）";
    }

    @Override
    public ObjectNode convert(Raw raw) throws IOException {
        ObjectNode bom = Cdx.newBom();
        ArrayNode dependencies = bom.putArray("dependencies");
        Path file = raw.shared().resolve("theia-image.json");
        if (Files.isRegularFile(file)) {
            TheiaAdapter.addTheiaImage(bom, dependencies, Cdx.read(file), raw);
        }
        return bom;
    }
}
