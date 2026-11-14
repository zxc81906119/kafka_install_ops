package com.example.cryptolab.web;

import com.example.cryptolab.crypto.HashingService;
import com.example.cryptolab.crypto.JwtService;
import com.example.cryptolab.crypto.KeyExchangeService;
import com.example.cryptolab.crypto.PasswordHashingService;
import com.example.cryptolab.crypto.SignatureService;
import com.example.cryptolab.crypto.SymmetricCryptoService;
import com.example.cryptolab.crypto.TokenService;

import java.util.List;

/**
 * lab 的所有演算法類別（{@code /api/lab/{category}/{algorithm}}）只在這裡定義一次。
 * <p>
 * 誰會讀這份清單：
 * <ul>
 *   <li>{@link CryptoLabController#catalog()}：{@code GET /api/lab} 的目錄（scripts/exercise-api.sh 讀它來呼叫每一個 API）</li>
 *   <li>測試：CryptoLabControllerTest（每個端點呼叫一次）、CryptoLabInventoryConsistencyTest（和標準答案比對）</li>
 * </ul>
 * 新增類別時：在 {@link #ALL} 加一行、在 CryptoLabController 加對應的 endpoint 方法（README.md 的「怎麼加一個新例子」）。
 * 忘了加到這裡時，CryptoLabInventoryConsistencyTest 會找出「有 ALGORITHMS / KINDS 卻沒登記」的 Service 並失敗。
 */
public final class LabCategories {

    /**
     * 一個類別。
     *
     * @param name      路徑上的類別名稱，例如 {@code symmetric}
     * @param method    HTTP 方法：會用到輸入資料的是 POST（body 為 {@code {"input": ...}}），不需要輸入的是 GET
     * @param parameter 路徑變數的名稱（只用在目錄的說明上），例如 {@code algorithm}
     * @param values    可用的值，直接引用 Service 的清單（例如 {@link SymmetricCryptoService#ALGORITHMS}）
     */
    public record Category(String name, String method, String parameter, List<String> values) {

        /**
         * 目錄裡的 key，例如 {@code "POST /api/lab/symmetric/{algorithm}"}。
         * 格式是「方法 空白 路徑」，方法補空白到 4 個字（GET 後面有兩個空白），scripts/exercise-api.sh 會解析這個格式，不要改。
         */
        public String catalogKey() {
            return String.format("%-4s /api/lab/%s/{%s}", method, name, parameter);
        }
    }

    public static final List<Category> ALL = List.of(
            new Category("password", "POST", "algorithm", PasswordHashingService.ALGORITHMS),
            new Category("jwt", "POST", "algorithm", JwtService.ALGORITHMS),
            new Category("symmetric", "POST", "algorithm", SymmetricCryptoService.ALGORITHMS),
            new Category("hash", "POST", "algorithm", HashingService.ALGORITHMS),
            new Category("signature", "POST", "algorithm", SignatureService.ALGORITHMS),
            // 金鑰交換不需要輸入資料，但沿用 POST（和其他「執行一次密碼學運算」的類別一致）
            new Category("key-exchange", "POST", "algorithm", KeyExchangeService.ALGORITHMS),
            // token 只是產生亂數，沒有輸入資料，所以用 GET；清單叫 KINDS（是「種類」不是演算法）
            new Category("token", "GET", "kind", TokenService.KINDS));

    private LabCategories() {
    }
}
