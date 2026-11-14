package lab.cbom;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import com.fasterxml.jackson.databind.JsonNode;

/** 對答案：標準答案的每一項有沒有找到、等級和預期的一不一樣。 */
class InventoryCheckTest {

    /** 很小的 CBOM：一個 AES/ECB（密碼學資產）、一個 TLS 協定（群組在 tlsGroups 裡）、一個函式庫、一個設定檔。 */
    private static final String CBOM = """
        {"components":[
          {"type":"cryptographic-asset","bom-ref":"a","name":"AES/ECB/PKCS5Padding",
           "cryptoProperties":{"assetType":"algorithm"},
           "properties":[{"name":"cbom:callSite","value":"demo.Sym.encrypt"}],
           "evidence":{"occurrences":[{"location":"src:src/main/java/demo/Sym.java:10","additionalContext":"Cipher#getInstance"}]}},
          {"type":"cryptographic-asset","bom-ref":"t","name":"TLS 1.3",
           "cryptoProperties":{"assetType":"protocol","protocolProperties":{"type":"tls",
             "cipherSuites":[{"name":"TLS_AES_256_GCM_SHA384","tlsGroups":["X25519MLKEM768"]}]}}},
          {"type":"library","bom-ref":"l","name":"bcprov-jdk18on","purl":"pkg:maven/org.bouncycastle/bcprov-jdk18on@1.78"},
          {"type":"file","bom-ref":"f","name":"application.yml",
           "evidence":{"occurrences":[{"location":"src/main/resources/application.yml","additionalContext":""}]}}
        ]}
        """;

    /** 判定結果：AES/ECB 同時有違規與通過（取最重的）；TLS 是通過；函式庫與設定檔沒有 finding。 */
    private static final String FINDINGS = """
        {"findings":[
          {"bom-ref":"a","level":"pass","rule":"symmetric-ok"},
          {"bom-ref":"a","level":"violation","rule":"ecb-mode"},
          {"bom-ref":"t","level":"pass","rule":"tls-1.3-pqc"}
        ]}
        """;

    private static final String INVENTORY = """
        {"items":[
          {"id":"SAME","description":"AES/ECB，預期違規","match":"aes.*ecb","expectedLevel":"violation"},
          {"id":"WRONG","description":"TLS 的群組，預期量子脆弱","match":"MLKEM768","assetType":"protocol","expectedLevel":"quantum-vulnerable"},
          {"id":"MISSING","description":"MD5，應該找得到","match":"MD5","expectedLevel":"violation"},
          {"id":"INVISIBLE","description":"Argon2，工具看不到","match":"argon2","expectedLevel":"not-detectable"},
          {"id":"SURPRISE","description":"BouncyCastle，以為看不到","kind":"library","match":"org\\\\.bouncycastle:bcprov","expectedLevel":"not-detectable"},
          {"id":"NO-EXPECTATION","description":"設定檔，沒寫預期","kind":"any","match":"application\\\\.yml"},
          {"id":"WHERE","description":"位置不符合就不算","match":"AES","locationMatch":"Other\\\\.java","expectedLevel":"violation"}
        ]}
        """;

    private static JsonNode json(String text) throws IOException {
        return Cdx.JSON.readTree(text);
    }

    @Test
    void eachItemIsFoundOrNotAndTheLevelIsCompared() throws IOException {
        List<InventoryCheck.Result> results = InventoryCheck.compare(json(CBOM), json(FINDINGS), json(INVENTORY));

        assertEquals(7, results.size());
        // 找到，等級取符合的元件裡最重的（violation），和預期相同
        assertEquals(new InventoryCheck.Result("SAME", "AES/ECB，預期違規", "violation", true, "violation"), results.get(0));
        // 名稱也包含協定的 tlsGroups；實際是 pass，和預期不同
        assertEquals("pass", results.get(1).actual());
        assertFalse(results.get(2).found());
        assertFalse(results.get(3).found());
        // 函式庫比的是 group:artifact；沒有 finding 當成 info
        assertEquals("info", results.get(4).actual());
        // kind 是 any：type 是 file 的元件也看
        assertTrue(results.get(5).found());
        // 名稱符合但位置不符合：沒找到
        assertFalse(results.get(6).found());
    }

    @Test
    void theSummaryListsOnlyTheItemsThatNeedALook() throws IOException {
        String text = InventoryCheck.summary(InventoryCheck.compare(json(CBOM), json(FINDINGS), json(INVENTORY)));

        assertTrue(text.startsWith("標準答案 7 項：找到 4 項；沒找到 3 項（其中預期看不到的 1 項）；等級相符 1 項、不符 1 項\n"), text);
        assertTrue(text.contains("沒找到（不是預期看不到的）：2 項\n  MISSING  MD5，應該找得到\n  WHERE  位置不符合就不算\n"), text);
        assertTrue(text.contains("預期看不到卻找到了：1 項\n  SURPRISE  BouncyCastle，以為看不到（實際等級 info）\n"), text);
        assertTrue(text.contains("等級不符：1 項\n  WRONG  TLS 的群組，預期量子脆弱（預期 quantum-vulnerable、實際 pass）\n"), text);
        assertFalse(text.contains("INVISIBLE"), "預期看不到、也真的沒找到的不列");
        assertFalse(text.contains("NO-EXPECTATION"), "沒寫預期等級而且找到的不列");
    }

    @Test
    void theSubcommandWritesTheSameTextToTheFile(@TempDir Path dir) throws IOException {
        Path cbom = dir.resolve("cbom.json");
        Path findings = dir.resolve("findings.json");
        Path inventory = dir.resolve("expected-inventory.json");
        Path output = dir.resolve("out/inventory-check.txt");
        Files.writeString(cbom, CBOM, StandardCharsets.UTF_8);
        // opa eval 的輸出外面包了 result／expressions，也要讀得進去
        Files.writeString(findings, "{\"result\":[{\"expressions\":[{\"value\":" + FINDINGS + "}]}]}", StandardCharsets.UTF_8);
        Files.writeString(inventory, INVENTORY, StandardCharsets.UTF_8);

        InventoryCheck.run(cbom, findings, inventory, output);

        assertTrue(Files.readString(output).startsWith("標準答案 7 項：找到 4 項"));
    }

    @Test
    void aBrokenInventoryFileIsAnError(@TempDir Path dir) throws IOException {
        Path cbom = dir.resolve("cbom.json");
        Path findings = dir.resolve("findings.json");
        Path inventory = dir.resolve("expected-inventory.json");
        Files.writeString(cbom, CBOM, StandardCharsets.UTF_8);
        Files.writeString(findings, FINDINGS, StandardCharsets.UTF_8);
        Files.writeString(inventory, "{\"description\":\"沒有 items\"}", StandardCharsets.UTF_8);

        assertThrows(IOException.class, () -> InventoryCheck.run(cbom, findings, inventory, dir.resolve("out.txt")));
        // regex 寫錯也是錯
        JsonNode badRegex = json("{\"items\":[{\"id\":\"BAD\",\"description\":\"x\",\"match\":\"(\"}]}");
        assertThrows(IOException.class, () -> InventoryCheck.compare(json(CBOM), json(FINDINGS), badRegex));
    }
}
