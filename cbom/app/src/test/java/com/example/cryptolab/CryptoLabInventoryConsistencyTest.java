package com.example.cryptolab;

import com.example.cryptolab.web.LabCategories;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.config.BeanDefinition;
import org.springframework.context.annotation.ClassPathScanningCandidateComponentProvider;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 確保「app 實際提供的演算法」、{@link LabCategories} 與標準答案 {@value #INVENTORY}（在 pom.xml 旁邊）保持一致。
 * <ul>
 *   <li>新增演算法端點時，忘了在 expected-inventory.json 某個項目的 {@code endpoints} 加上
 *       {@code "<category>/<algorithm>"} → 失敗，並列出缺少的項目</li>
 *   <li>新增了一個有 {@code ALGORITHMS} / {@code KINDS} 清單的 Service，卻沒登記到 {@link LabCategories} → 失敗
 *       （否則 API、測試、標準答案都不會檢查到它）</li>
 * </ul>
 * <b>這個測試不管的事（要靠人檢查）：</b>
 * <ul>
 *   <li>它只看標準答案裡有 {@code endpoints} 的項目（L1，35 項）。沒有 endpoints 的 14 項
 *       （L2 函式庫、L3 憑證與金鑰檔、L4 映像、L5 TLS）改了、刪了都不會失敗</li>
 *   <li>不檢查總數是不是 49，也不檢查 {@code match}、{@code description} 寫得對不對</li>
 *   <li>不檢查程式註解裡寫的「標準答案：id」和這個檔是否一致</li>
 * </ul>
 * 這個測試不啟動 Spring（沒有 {@code @SpringBootTest}），只讀類別上的靜態清單與 JSON 檔，所以很快。
 * 新增例子的完整步驟見 README.md 的「怎麼加一個新例子」。
 */
class CryptoLabInventoryConsistencyTest {

    private static final String CRYPTO_PACKAGE = "com.example.cryptolab.crypto";
    static final String INVENTORY = "expected-inventory.json";

    @Test
    @DisplayName("每個演算法端點都寫進了標準答案，標準答案也沒有多出不存在的端點")
    void everyAlgorithmEndpointIsCoveredByExpectedInventory() throws Exception {
        String inventoryFile = INVENTORY;
        // 1. app 這邊：把每個類別的每個值組成 "類別/值"，例如 "hash/sha256"
        Set<String> appEndpoints = new TreeSet<>();
        LabCategories.ALL.forEach(c -> c.values().forEach(v -> appEndpoints.add(c.name() + "/" + v)));

        // 2. 標準答案這邊：收集每個項目的 endpoints（沒有 endpoints 的項目，item.path 會回空的，直接略過）
        Set<String> inventoryEndpoints = new HashSet<>();
        JsonNode inventory = readInventory(inventoryFile);
        for (JsonNode item : inventory.get("items")) {
            for (JsonNode endpoint : item.path("endpoints")) {
                inventoryEndpoints.add(endpoint.asString());
            }
        }

        // 3. 兩邊相減：app 有、標準答案沒有的（漏寫）；標準答案有、app 沒有的（拼錯或已刪除）。兩個都要是空的
        Set<String> missingInInventory = new TreeSet<>(appEndpoints);
        missingInInventory.removeAll(inventoryEndpoints);
        Set<String> unknownInInventory = new TreeSet<>(inventoryEndpoints);
        unknownInInventory.removeAll(appEndpoints);

        assertThat(missingInInventory)
                .as("這些端點沒有出現在 " + inventoryFile + " 任何項目的 endpoints 裡")
                .isEmpty();
        assertThat(unknownInInventory)
                .as(inventoryFile + " 列了 app 裡不存在的端點（拼錯或已刪除？）")
                .isEmpty();
    }

    @Test
    @DisplayName("每個有 ALGORITHMS / KINDS 清單的 Service 都登記在 LabCategories")
    void everyServiceListIsRegistered() throws Exception {
        // 1. 列出 crypto 套件底下所有的類別：scanner 是 Spring 提供的「掃 classpath 找類別」工具；
        //    建構子的 false = 不用預設的篩選（只找 @Component），下一行的篩選條件永遠回 true = 每個類別都要
        var scanner = new ClassPathScanningCandidateComponentProvider(false);
        scanner.addIncludeFilter((reader, factory) -> true);
        Set<String> unregistered = new TreeSet<>();
        for (BeanDefinition bean : scanner.findCandidateComponents(CRYPTO_PACKAGE)) {
            // 2. 用類別名稱載入類別，再看它有沒有叫 ALGORITHMS 或 KINDS 的公開靜態欄位（反射：執行時才用名稱去找欄位）
            Class<?> type = Class.forName(bean.getBeanClassName());
            for (String fieldName : List.of("ALGORITHMS", "KINDS")) {
                Object values = staticFieldOrNull(type, fieldName);
                // 3. 有清單的話，LabCategories.ALL 裡必須有一個類別引用它。
                //    這裡用 == 比對「同一個 List 物件」（不是比內容）：LabCategories 必須直接引用 Service 的清單，不能另外抄一份
                if (values != null && LabCategories.ALL.stream().noneMatch(c -> c.values() == values)) {
                    unregistered.add(type.getSimpleName() + "." + fieldName);
                }
            }
        }
        assertThat(unregistered)
                .as("這些清單沒有登記到 com.example.cryptolab.web.LabCategories.ALL（見 README.md 的「怎麼加一個新例子」）")
                .isEmpty();
    }

    /** 讀出類別 type 上名稱是 name 的公開靜態欄位的值；沒有這個欄位就回 null。f.get(null) 的 null = 靜態欄位不需要物件 */
    private static Object staticFieldOrNull(Class<?> type, String name) throws IllegalAccessException {
        for (Field f : type.getDeclaredFields()) {
            if (f.getName().equals(name) && Modifier.isStatic(f.getModifiers()) && Modifier.isPublic(f.getModifiers())) {
                return f.get(null);
            }
        }
        return null;
    }

    private static JsonNode readInventory(String relativePath) throws Exception {
        return JsonMapper.builder().build().readTree(Files.readString(repoFile(relativePath)));
    }

    /**
     * 找到 repo 裡的檔案：從目前目錄往上找，直到找到 pom.xml 所在的 repo 根目錄。
     * 這樣不管是 ./mvnw 在根目錄執行，或 IDE 用其他工作目錄執行，都讀得到。
     */
    private static Path repoFile(String relativePath) {
        for (Path dir = Path.of("").toAbsolutePath(); dir != null; dir = dir.getParent()) {
            Path candidate = dir.resolve(relativePath);
            if (Files.exists(dir.resolve("pom.xml")) && Files.exists(candidate)) {
                return candidate;
            }
        }
        throw new IllegalStateException("找不到 " + relativePath + "（從 " + Path.of("").toAbsolutePath() + " 往上找）");
    }
}
