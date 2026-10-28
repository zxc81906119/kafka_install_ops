# 2026-10-29 事故：broker 重啟後 MDS 起不來（authorizer 等 10 分鐘自殺），整個 MDS 層逐台卡死

## 經過
- 04:03 腳本版第 28 段重啟 kb04 → 8090 不開，journal 停在 `Waiting for all of the authorizer futures to be completed`；10 分鐘後
  `Authorizer did not start up within the timeout confluent.authorizer.init.timeout.ms=600000` 自殺，systemd 10 秒後再拉起，無限循環。
- 之後重啟 kb01、kb02 都一樣；只剩 kb03 的 8090 回 200，但寫 role binding 全部 502／500（master writer 卡住）。
- 走了好幾條岔路（coordinator group、`_confluent-metadata-auth` 的 ISR／min.isr、reassign、四台冷啟動）都沒用。
- 真正的原因在 **`/var/log/kafka/metadata-service.log`**（MDS 用獨立的 log4j2 appender，journal 看不到）：
  `LDAP search failed … AuthenticationException: [LDAP: error code 49 … data 52e]`＝`svc-mds-bind` 密碼錯。
- 為什麼錯：02:49 手動跑 20.4（AD 換 svc-mds-bind 密碼）時，`confluent secret file update --config-file kb01.server.properties` 把新密文寫在
  key `kb01.server.properties/ldap…` 下；但這個 lab 是腳本版裝的，第 15 站用 `kb01.properties` 加密，broker 設定檔參照 `security.properties:kb01.properties/…`
  → 多出 7 行新密文、舊 7 行原封不動；broker 靠群組快取撐到下一次重啟才爆。ops02 上用 `kb01.server.properties` 解密看起來是對的，用 broker 自己的參照名解才看出不同。
- 修法：用 `~/conf/sp/<host>.properties` 的檔名重做 update（總行數 180 → 180，只改不加）、派送 10 台、四台 broker 一起停、一起起 → 77 秒內四台 MDS 200、alice 登入 200。
  期間曾把 `_confluent-metadata-auth` 的 `min.insync.replicas` 臨時改 1，已刪掉 override 回預設 2。

## 改了什麼
- 手冊 20.4：先從每台設定檔的 `${securepass:…:<檔名>/…}` 讀出 key 名，再用該檔名 `update`；輸出多印「總行數不變」。說明密文 key＝加密時的檔名。
- 腳本第 15 站：`sp_name_of` 依角色命名（`<主機>.server.properties`／`.kafka-rest.properties`／`.control-center.properties`），和手動 15.3 一致。
- 手冊 28.1／28.4：MDS 起不來要看 `metadata-service.log`；`data 52e`＝bind 密碼錯；10 分鐘自殺循環；全卡住時四台一起停、一起起。
- CLAUDE.md 陷阱：MDS／authorizer 日誌在 `/var/log/kafka/metadata-service.log`；securepass 的 key 是加密時的檔名。

## 教訓
- 「journal 沒有 ERROR」不代表沒有錯：先看 log4j2.yaml 有哪些 appender 分流到別的檔。
- 手動與腳本必須用同一套檔名規則，否則交叉操作（腳本裝、手動維運）會埋雷。
- 不要在 writer 沒恢復時重啟更多 broker；少於兩台健康時 `_confluent-metadata-auth` 的 min.isr 會把 writer 也鎖死。
