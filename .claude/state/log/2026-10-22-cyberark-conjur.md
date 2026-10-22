# 2026-10-22 — CyberArk Conjur／Secret Protection 實作（journey 第 15、16 章）

- 設計定案（redesign/README.md 第 11 節）：客戶端安裝期經 PSMP 以 cpadmin 登操作機、腳本開頭打 CCP 取各主機 cpadmin 私鑰進 ssh-agent；維運期 opxx 用銀行自己的 OP menu；AD bind 與 app SCRAM 都用 A／B 兩組帳號輪替；
  Confluent 的 csid-secrets-providers 只接 Conjur，不接 CCP；只有 PAM 的銀行用 Secret Protection（master key 交 CyberArk）。
- lab：使用者中午自己重跑第 0 章（沒 down -v）→ 我 `down -v` 從零重建第 0–14 章（85 區塊全過），journey 0.5.9 加「重跑前一定 down -v」陷阱。
- 第 15 章（Conjur OSS 扮演 CyberArk，在 ~/kafka-lab/conjur.yml，conjur.poc.lab 172.35.0.15，憑證由模擬銀行 CA 簽）實跑通過：policy、host 身分、provider jar（從原始碼 Maven 建，只帶 4 個 jar）、
  五個範本改 `${cyberark:path:path}`、CLASSPATH drop-in、滾動重啟、AD bind 密碼輪替演練、app 端兩種拿法（REST 取字串／client config provider）。
  踩到：docker cp 進 /tmp 看不到（tmpfs）；curl `@~` 不展開；只改三個範本 → broker listener 密碼沒換（keystore password incorrect）；
  C3 的啟動腳本只看 CONTROL_CENTER_CLASSPATH；provider 每個設定物件都重新初始化一次，日誌很吵。
- 第 16 章（Secret Protection，passphrase 存 Conjur 代替 PAM Vault，service.env 派送，master key 輪替演練）：草稿完成，實跑中。
- 待辦：16 跑完後把 15、16 併入 journey.md（15 已 append）、更新 0.4 時間表／名詞、diagrams（conjur 已加）、重建 docx。
- 第 16 章實跑通過（9 區塊）：passphrase 存 Conjur → ops02 以 host 身分取 → `confluent secret master-key generate -o yaml`、`file encrypt`（10 個 properties、137 筆密文）→ 派送 security.properties／service.env（EnvironmentFile）→ 滾動重啟全 200 → master key 輪替（`file rotate --master-key`）再滾動一次全 200。
  踩到：`grep -c '=ENC['` 數不到（格式是 `key = ENC[...]`，且 _metadata 行也有 ENC）；精簡 OS 沒有 cmp；security.properties 裡 `_metadata.symmetric_key.0.envvar` 會命中 MASTER_KEY 字串（不是 key 本身）。
- journey.md：15、16 章併入；0.4 名詞小抄與時間表補 CyberArk／config provider／Secret Protection；第 14 站開頭註明 15、16 為延伸站、二選一；diagrams.js 加 conjur、secretprotection 兩張圖；docx 重建。
- lab 現況：`lab` 專案 14 台 + conjur-db／conjur／conjur-proxy + dl01；平台目前是 **Secret Protection 模式**（第 16 章結束狀態，Conjur provider 的 drop-in 已移除）。
- 16.8 Summon（選配）實跑通過：dl01 抓 summon v0.13.1 + summon-conjur v0.9.3（核對原廠 SHA256SUMS）；每台 /etc/conjur.conf + /etc/conjur.identity（netrc，0640 root:confluent，用第 15 章的 host API key）+ /etc/confluent/secrets.yml；
  drop-in 30-summon.conf 把 ExecStart 包成 `summon -p summon-conjur -f secrets.yml <原啟動腳本>`，拿掉 20-secret-protection.conf 與 service.env；滾動重啟全 200；kb01 主程序是 summon、java 子程序環境有 MASTER_KEY、磁碟 0 個檔。
  踩到：master.key 檔尾換行會被一起存進 Conjur → 值不符；寫入前 `tr -d '\n'`。
- 1.4 給銀行的 OS 套件清單補 gettext、createrepo_c（操作機要用）。
- lab 現況：平台在 **Secret Protection + Summon 模式**（沒有 service.env）。
- 2026-10-22 晚：OP menu 依第 13 節定案改寫並重排（opmenu/）：無主機 agent、cpadmin ssh（私鑰從 Conjur 進 ssh-agent）、兩段式 sudoers、91 用保管庫 PEM 憑證、known_hosts 唯讀；
  結構：opmenu.sh（選單）＋ lib/{common,kafka,hosts}.sh ＋ lib/secrets/{conjur,ccp}.sh ＋ items/ 一項一檔 ＋ tests/。
  lab 實測（ops02 建 op01、/etc/opmenu/*、Conjur host kafka/opmenu）：三身分動態選單、23/16/21/22/27/91 成功、kb04 窄 sudoers 下重啟與看日誌可、無殘留。
  RBAC 發現：kafka-topics --describe 需 DescribeConfigs → 維運群組加 DeveloperManage Topic:*；kafka-devs 加 DeveloperManage Topic:orders.*（lab 綁好）。
  lab 現況：`lab` 在跑（含 Conjur、dl01），平台 Secret Protection + Summon 模式，op01/opmenu 已部署在 ops02。
- 2026-10-22 深夜：journey 第 17 站「維運選單」實跑通過並併入（保管庫身分與兩個值、裝選單、兩段式 sudoers、bob/carol/alice 試跑、收尾檢查）；diagrams 加 opmenu；docx 重建。
  OP menu 打包：windows/package-opmenu.sh → packages/tools/opmenu-20261022.5b4cdd00.tar.gz（landing/tools/opmenu）。
  待辦順序（使用者定）：2 audit log 路由 + JMX exporter（HTTPS + basic auth + scrape 設定）→ 1 驗收清單（平台健康、安全、應用程式端、維運）＋ 22 收尾 → 4 安裝腳本重寫（照手把手一章一支）。
