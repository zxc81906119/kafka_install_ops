# C3 client 憑證（2026-11-05）
- alias 對照：合併 keystore、拿掉 NewSunX509、只留 prometheus／alertmanager 的 alias.name → 失敗：9021 改出示 svc-c3（只有 clientAuth），API 連不上（000）；健康檢查倒是用 svc-c3 通過。結論：alias.name 不能讓 server 端維持 cp-server。
- REST Proxy 8.2.4 沒有這個問題：連 MDS 是 svc-rest，帶 client 憑證 `/v3/clusters` 200（rest01、rest02、LB），不帶被拒。
- 使用者偏好（尚未定案、尚未測）：C3 自己的憑證同時有 server、client 用途，C3 全部用它，不用 cp-server。
- lab：已還原 NewSunX509 版（/var/tmp/c3test/cp-plus-svc.p12），根因與前段測試見 log/2026-11-03-lab-wiped.md。

## 定案與 lab 驗證（使用者 2026-11-05）
- 定案：C3、REST Proxy 各用自己的憑證同時當 server 與 client（`svc-c3`、`svc-rest` 的 EKU serverAuth,clientAuth；CN 不變，RBAC 不用改）；JMX exporter 跟著換。C3 內建 Prometheus、Alertmanager 的 server 端維持 cp-server，避免 svc-c3 多一份明文 PEM 私鑰。cp-server 仍只有 serverAuth。
- SAN：svc-c3 = c3-01.poc.lab,c3-01,c3.poc.lab,localhost；svc-rest = rest01／rest02（含短名）,rest.poc.lab,localhost。
- lab 8.2.4 實測：9021、C3 7071 出示 svc-c3；rest01／02、rest.poc.lab 的 8082 與 7071 出示 svc-rest；9090 維持 cp-server。C3 登入代理、/2.0/clusters/kafka、/2.0/alerts/triggers 都 200，不需要 NewSunX509。REST 帶 client 憑證 200（兩台＋LB），不帶被拒。兩邊 Prometheus 抓 7071 都 up=1。
- 舊檔：ops02 `~/pki/before-reissue/`；各主機 `/var/tmp/*before*`、`/var/tmp/c3test/`（只是測試用，可清）。cp-server.p12 還留在 REST、C3 主機。
- 待做：C3 2.6.1／REST 8.3.2 再驗；瀏覽器實際登入；C3 trigger 測試；改手冊（第 7 章憑證清單、第 13 章、REST 章、第 21 章輪替）、腳本、問題清單 6.x；加帶身分呼叫 C3 API 的驗收。

## 更新（使用者 2026-11-05）
- 改定案：C3 內建 Prometheus、Alertmanager 的 server 端也用 svc-c3（取代前面「維持 cp-server」）。c3-01 不再放 cp-server；代價是 svc-c3（SystemAdmin）私鑰以 PEM 檔放在主機上（root:confluent 0640）。c3-monitoring 維持不動（Prometheus 連 Alertmanager 的 client）。
- lab：web-config-prom.yml、web-config-am.yml 已改；cp-server.* 移到 /var/tmp/c3-before-own/。

## 使用者同意照建議進行（2026-11-05）
- 告警方案與第 17 章並存（銀行提供 Prometheus 走第 17 章，沒有提供走 C3 方案）；主線維持先裝基底 2.5.1 再遷移，omnibus 告警在 C3 換成 2.6.1 之後才開。
- 步驟：收尾 8.2.4 → 驗 2.6.1 → 驗告警方案 → C3 trigger → 改文件 → 改腳本 → 手冊從零實跑 → 腳本版實跑。commit 等使用者指示。

## 第 1–4 步結果（lab，C3 2.6.1，CP 仍 8.2.4）
- REST 主機移開 cp-server.*：兩台＋LB 帶 client 憑證 200。
- 手冊 29.3 的 c3-change.sh 升到 2.6.1：rc=0；我們改的 10 個檔（prometheus-generated.yml、規則、web-config、properties、jmx、第二台設定與 unit、drop-in）雜湊全部不變；Prometheus 3.14.0、Alertmanager 0.34.0；憑證與帶身分 API 都正常。
- 第二台改用內附 0.34.0（`/usr/libexec/confluent-control-center/linux_amd64/alertmanager/alertmanager-amd64`）：停 rest01 88 秒 OPEN、開回 60 秒 RESOLVED，全部字串，內建 9093 沒收到。
- 真 C3 trigger＋action（API 建）：告警帶 `rule_created_by: c3-10`、沒有 target；只到內建 9093，webhook 由 action 送出（User-Agent 0.34.0，C3 預設格式）；第二台 0 筆、omnibus 0 筆；prometheus-generated.yml 雜湊不變。測試 trigger／action 已刪。
- C3 log `Failed to fetch MDS URLs … Client has already been closed`：登入用的暫時 RestClient 關閉後背景刷新造成，登入都成功，判斷為雜訊。
- CP／REST 8.3.2、JDK 25 不在這輪手動驗，靠最後從零實跑。

## 全跑前的環境問題（2026-11-05）
- 開機時 `win-sshproxy failed to start`（殘留 socket，2026-11-03 那次留下）→ `podman compose` 不能用，舊 lab 沒拆掉。照 CLAUDE.md 停 machine、刪 socket、開 machine。
- 之後 compose 建網路失敗 `subnet 172.35.0.0/24 is already used`：VM 裡殘留橋接 podman2（網路物件已不在）。`podman machine ssh kafka-lab sudo ip link del podman2` 解決。

## 使用者定案（2026-11-05）：拿掉 c3-monitoring
- Prometheus 連 Alertmanager 也用 svc-c3（Alertmanager 只驗憑證鏈與用途，不看 CN）；操作機連 9090 的檢查改用 svc-ops；憑證 9 張 → 8 張。
- 等這輪手冊全跑結束再改（手冊 13、14、19、21、29、32，憑證清單，腳本 09、13、19、21、32，prometheus 模板，問題清單 6.2），之後用腳本版與手冊相關章節驗證。

## 使用者定案（2026-11-05）：OP menu 緊急模式改用 svc-ops
- 拿掉 opmenu-breakglass；項目 91 讀 `~/secrets/svc-ops.pem`（0600，由 svc-ops 的私鑰與憑證產生）。憑證 7 張：kafka-internal、cp-server、svc-rest、svc-c3、svc-ops、app-legacy-billing、svc-backup。
- 取捨：Kafka 稽核日誌不再能單獨辨識緊急操作；靠選單 EMERGENCY 紀錄（含原因，送 syslog）、CyberArk 登入紀錄、PSMP 錄影。
- 等這輪手冊全跑結束再和 c3-monitoring 一起改。

## AD 待辦（使用者 2026-11-05 同意，等手冊全跑結束再做；全跑期間不動手冊與腳本）
- 原廠文件：不支援巢狀 LDAP 群組。手冊第 10 章寫限制與症狀；問題清單第 7 節明確要求 KAFKA_* 直接放人、cn 是否全行唯一、member 會不會在 TCBUsers 外。
- 測試（lab，放進範例的多層 OU）：全大寫帳號從 C3、OP menu 登入與權限；member 是子群組（子群組名被當使用者、子群組成員沒權限）；member 在 user search base 外；search base 內外同名是否繼承權限。
- 測 `ldap.group.member.attribute.pattern=CN=([^,]+),.*OU=<使用者根 OU>,.*`：不符合的 member 是略過還是報錯。會略過就採用，使用者根 OU 放 site.env（lab 的值依 lab 結構）。

## AD 情境實測結果（2026-11-05，lab 8.2.4，Samba，帳號放多層 OU）
- 舊 pattern：ZZCASEUSER 三種大小寫 MDS／C3 都 200、sub=ZZCASEUSER、ALLOWED；子群組成員 DENIED；CN 與子群組同名的使用者 ALLOWED；search base 外 401；內外同 CN，內部那個 ALLOWED（sAMAccountName 登入 401）。
- 新 pattern（只在 kb01 試）：直接成員 ALLOWED，同名與子群組同名都 DENIED，OU 外的 alice DENIED；不符合的 member 安靜略過，沒有新的 LDAP 錯誤。
- OP menu：ZZCASEUSER／zzcaseuser／ZzCaseUser 都通過碰主機的權限檢查（到輸入階段），紀錄都是 ZZCASEUSER。

## WSL 卡住（2026-11-05 11:5x）
- 症狀：`podman machine inspect` 偶爾失敗（wsl.exe exit 143），手冊 0.0 以為 machine 不存在去 init，停在 `already exists`；Windows 可用記憶體只剩 0.2 GB、Podman Desktop 開著。使用者要求重啟 WSL：`wsl --shutdown`、殺 win-sshproxy、machine stop/刪 socket/start 後恢復。清理時 compose.yml 已被刪，手動移除 lab 容器、volume、網路。

## 9092／9093（使用者 2026-11-05 定案 A）
- 操作機保留連 9093、9092；白名單做法等銀行回覆問題清單 5.8，這輪全跑不動防火牆。手冊 7.3 表格與第 11 章 bootstrap 的文字已改（只改說明，下一次實跑前不影響指令）。
