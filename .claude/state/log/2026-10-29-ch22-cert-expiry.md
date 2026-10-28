# 2026-10-29 第 22 章 憑證到期監控（選配；手動 → 文件 → 腳本）

## 做了什麼
- 22.1 要看哪些憑證（blackbox 探得到／探不到、操作機腳本涵蓋哪些）。
- 22.2 銀行 Prometheus：blackbox_exporter `tls` 模組（TCP＋TLS 握手、用 ca.pem 驗鏈；mTLS 的 listener 也會先出示 server 憑證，不需 client 憑證，lab 實測 24 個端點全部 probe_success 1）；
  `scrape-blackbox.yml`（每個端點一個 target、relabel 經 `/probe`）；`confluent-alerts-cert.yml` 三條（< 60 天 warning for 1h、< 14 天 critical、probe 失敗）；
  `cert-expiry-rules-test.yml` 用 `promtool test rules` 餵假序列驗三條規則（不用等一年）。規則 21 → 24 條。
- 22.3 操作機 `~/conf/cert-expiry.sh`：讀 `~/pki/certs/*.crt|*.pem`（跳過 mds-token-public.pem），syslog tag `confluent-cert`，rc 0／2／1；用 5 天與已過期的自簽憑證驗分支；timer 每天 08:10。
- 22.4 告警響了做什麼（對應第 21 章）。
- 腳本：`22-cert-expiry.sh files｜check｜schedule`、`bank-sim.sh monitoring-blackbox`（起 lab-mon-blackbox、prometheus.yml 的 scrape_config_files／rule_files 改萬用字元、restart、等 target 與規則）、
  run-customer 第 27 段（共 34 段）、templates（blackbox.yml、prometheus-scrape-blackbox.yml、confluent-alerts-cert.yml、cert-expiry-rules-test.yml、cert-expiry.sh）、問題清單 11.10、圖 D.certexpiry。

## 教訓
- `docker run … --config.file=/etc/…` 在 Git Bash 會被 MSYS 轉成 Windows 路徑：docker 指令前一律 `MSYS_NO_PATHCONV=1`（手冊 lab 區塊也加）。
- `promtool test rules` 成功時印 `  SUCCESS` 加一個空行：`tail -1` 會拿到空行，改 `grep -oE "SUCCESS|FAIL"`。
- 章節標題裡不要放反引號（run-chapter 把標題寫進 runner，反引號會被當成指令替換）。
- `openssl req -x509 -days -1` 做不出已過期的憑證；OpenSSL 3.4 以上用 `-not_before/-not_after`。
- lab 的 prometheus.yml 是單檔 bind mount：改 `scrape_config_files`／`rule_files` 要 `docker restart`。
