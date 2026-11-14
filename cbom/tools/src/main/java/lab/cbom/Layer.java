package lab.cbom;

import java.io.IOException;

import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * 一層盤點：把一個工具的輸出（原料目錄裡的檔）轉成 CBOM 的元件。
 *
 * 每個工具一個實作（Adapter）；全部登記在 Layers，由盤點對象（Profile）決定用哪幾層（Strategy）。
 * 誰呼叫：Main 的 build 與 convert。
 *
 * 現有的 Layer（id → 類別 → 讀哪個工具的輸出）：
 * <pre>
 *   tls        TlsScanLayer         testssl.sh 掃每個埠的 JSON
 *   config     PlatformConfigLayer  收集腳本整理的 properties、SCRAM 帳號、ssh 金鑰
 *   jdk        JdkSettingsLayer     java.security、java -XshowSettings、crypto-policies
 *   libraries  LibraryLayer         syft 的 SBOM
 *   runtime    RuntimeLayer         jfr print --json
 *   source     SourceCodeLayer      cbomkit-action 的 CBOM
 *   files      FilesLayer           cbomkit-theia 掃目錄的 CBOM
 *   image      ImageLayer           cbomkit-theia 掃映像的 CBOM
 * </pre>
 * 有幾個類別的檔頭寫「第 ②、③、④、⑤ 層」：那是手冊第 33 章開頭那張表的編號（給人看的分法），
 * 不是 Layers.ALL 的順序，也不是這裡的 id。
 *
 * 要換工具或加一層（加一種原料）：
 * <pre>
 * 1. 寫一個 Layer：id()、title()、convert()。元件用 Cdx.asset／Cdx.plain 建，
 *    每個元件都要 Cdx.prop(元件, "source", "來源名稱") 與至少一個 Cdx.occurrence(位置)；
 *    演算法、金鑰類的元件再呼叫 Algo.apply 補上家族與長度。可以照 SourceCodeLayer（最短的一個）抄。
 * 2. 登記到 Layers.ALL（位置就是合併的順序），再把 id 加進用得到它的 Profile 的 layers()。
 * 3. 來源名稱是新的：在 ReportCommand.sourceLabel 加一行中文名稱（沒加也不會錯，報告會直接印英文的來源名稱）。
 * 4. 規則要不要認得這個來源：cbom/policy/cbom.rego 裡有些規則用 prop(c, "source") == "…" 判斷，
 *    看需不需要為新的來源加規則；新元件沒有任何規則認得時，報告會把它歸在「資訊」或「無法判斷」。
 * 5. 收集腳本要把這個工具的輸出放進原料目錄（cbom/cbom-collect.sh 或 cbom/webapp/webapp-collect.sh）。
 * 6. 驗證：bash cbom/build.sh（編譯＋單元測試），再 bash cbom/golden.sh check。
 *    基準的原料裡沒有新工具的輸出，所以八個檔應該都相同（表示沒有改到原本的產出）；
 *    有不同就是改到了別層，或合併順序變了。產出的改變確定是預期的，才 bash cbom/golden.sh rebase。
 * </pre>
 */
interface Layer {

    /** 短名稱，Profile 用它指定要哪幾層；也是 cbom-tools convert 的第一個參數。 */
    String id();

    /** 給人看的說明（cbom-tools layers 會印出來）。 */
    String title();

    /** 原料 → 元件（components，可以帶 dependencies）。這一層沒有原料時回空的 BOM，不算錯。 */
    ObjectNode convert(Raw raw) throws IOException;
}
