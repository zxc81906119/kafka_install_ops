package com.example.cryptolab;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * CBOM lab 的教材 app：每一種密碼學用法都有一個 Service（crypto/），由 web/CryptoLabController 提供 API。
 * {@code @ConfigurationPropertiesScan} 讓 config/LabProperties 自動綁定 application.yml 的 lab: 區塊。
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class CryptoLabApplication {

    public static void main(String[] args) {
        SpringApplication.run(CryptoLabApplication.class, args);
    }
}
