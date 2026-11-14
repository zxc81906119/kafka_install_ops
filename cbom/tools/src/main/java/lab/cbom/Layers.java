package lab.cbom;

import java.util.ArrayList;
import java.util.List;

/**
 * 所有的 Layer 都登記在這裡（註冊表）。順序就是合併的順序。
 *
 * 順序會影響產出：同一個資產（同一個 bom-ref）在兩層都出現時，留的是先登記那一層的元件，
 * 後面的只把出現位置與屬性併進去（Cdx.add）。所以不要隨便調整順序；調了要跑 bash cbom/golden.sh check。
 * 誰呼叫：Main（build、layers、convert）。
 */
final class Layers {

    static final List<Layer> ALL = List.of(
        new TlsScanLayer(),
        new PlatformConfigLayer(),
        new JdkSettingsLayer(),
        new LibraryLayer(),
        new RuntimeLayer(),
        new SourceCodeLayer(),
        new FilesLayer(),
        new ImageLayer());

    private Layers() {
    }

    /**
     * 照登記的順序挑出指定的幾層；指定了沒登記的名稱是程式寫錯，直接丟例外。
     * 例：of(["files", "tls"]) → [TlsScanLayer, FilesLayer]（照 ALL 的順序，不是照參數的順序）。
     */
    static List<Layer> of(List<String> ids) {
        List<Layer> chosen = new ArrayList<>();
        for (Layer layer : ALL) {
            if (ids.contains(layer.id())) {
                chosen.add(layer);
            }
        }
        // 挑到的數量和指定的不一樣 = 有名稱沒登記
        if (chosen.size() != ids.size()) {
            throw new IllegalArgumentException("有沒登記的 Layer：" + ids);
        }
        return chosen;
    }
}
