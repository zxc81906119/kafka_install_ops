# Kafka 維運操作選單(OP menu)

> 2026-10-22 重新設計(redesign/README.md 第 13 節):**主機上不放任何 agent**,主機類動作用「和安裝同一個 cpuser」ssh 過去做,主機只靠 sudoers 限制;拿掉 ticket、清理日誌、docker 後端。
> 2026-10-27 主機存取改版(redesign/README.md「新做法已進手冊與腳本」):人員經 CyberArk PVWA 網頁＋PSMP 登入操作機**就是 root**,選單以 root 執行;
> 主機類動作用的 SSH 私鑰就是操作機獨立 file system 上的檔案 `/secure/ssh/cpuser_ed25519`(root、0400,和安裝同一把),**不再從 PVWA 貼進選單的 ssh-agent**;緊急模式憑證(91)仍由人從 PVWA 貼上。
> 部署走離線引進流程:在外網端打包成 `opmenu-<日期>.<sha8>.tar.gz`,隨落地區送到操作機 `~/landing/tools/opmenu/`(手把手 16.3)。

給維運人員用的文字選單:人員經 CyberArk 登入操作機(進去是 root)後,從選單執行審核過的作業,每次執行留紀錄。
**Kafka 的動作能不能做,由 Kafka 的 RBAC 依操作者本人的 AD 群組決定;主機的動作先問 MDS「本人有沒有 Operator 以上的權限」,再以 cpuser ssh 到主機,主機的 sudo 只開放逐一列出的重啟與看日誌寫法。**

> **誠實的限制**:操作者在操作機上是 root,而 `/secure/ssh` 的私鑰 root 讀得到,所以選單「碰主機前先問 MDS」這一關是**流程控管、不是硬性隔離**(root 可以直接用金鑰 ssh,繞過選單)。
> 追溯靠 **CyberArk 的登入紀錄與 PSMP 錄影**(誰在什麼時間進了 root)加上選單紀錄與主機上 cpuser 的操作紀錄;Kafka 動作的權限與稽核則由 Kafka 端依本人 AD 身分強制,繞不過。

## 結構:一個項目一個檔,選單一個檔,共用拆開

| 檔案 | 角色 |
|---|---|
| `opmenu.sh` | 進入點:載入設定與共用程式、登入、**畫選單與迴圈**(唯一會顯示選單的檔案) |
| `/etc/opmenu/opmenu.conf` | **這個環境的設定**:連線位址、主機與服務名、ssh 帳號與私鑰檔路徑、PVWA object 名稱(91)、命名規範。換環境只改這裡(範本 `opmenu.conf.example`) |
| `lib/defaults.sh` | 所有設定項目與預設值,兼說明文件;`opmenu.conf` 沒設的才用它 |
| `lib/common.sh` | 共用:項目登記(`item`、`load_items`)、紀錄、確認、輸入驗證(`v_*`)、執行流程(時窗、並行鎖、結果判斷)、主機權限閘門、ssh 私鑰檔檢查 |
| `lib/kafka.sh` | 共用:以操作者身分跑 Kafka 工具、呼叫 MDS、換 token;91 用 PVWA 取出的憑證;各項目共用的 MDS 小工具(`k_*`) |
| `lib/hosts.sh` | 共用:ssh 到各主機重啟、看日誌、磁碟、診斷;憑證到期日。**sudo 寫法固定**(見下方「sudoers」) |
| `lib/secrets/manual.sh` | 91 緊急憑證從哪裡取(`secret_get`):維運人員從 CyberArk PVWA 取出後貼上(唯一的來源)。主機用的 ssh 私鑰不經過這裡 |
| `items/<編號>-<名稱>.sh` | **每個選單項目一個檔**:第一行 `item <編號> <層級> <變更類> <需確認> "<標題>" "<說明>"`,下面 `run() { … }`。加項目 = 加一個檔,停用 = 移走檔案 |
| `tests/` | 單元測試,不需要叢集或保管庫 |

項目只呼叫 `be_*`(kafka.sh、hosts.sh)、`k_*`、`v_*`、`core_confirm`、`core_log` 與 `OPMENU_*` 設定,不碰 ssh、systemctl 或任何主機名稱。程式碼裡沒有環境值。

## 機敏資料怎麼走

| 什麼 | 放哪 | 什麼時候取 | 落地? |
|---|---|---|---|
| 操作者的 AD 密碼 | 操作者自己 | 登入時輸入,換到 MDS token 後丟掉;Kafka 工具用的連線檔放記憶體檔案系統、離開時刪 | 否 |
| 操作機 → 各主機 cpuser 的 SSH 私鑰(`OPMENU_SSH_KEY_FILE`,預設 `/secure/ssh/cpuser_ed25519`) | 操作機自己:獨立(加密)file system、root 0400,安裝與維運共用同一把;**不放 CyberArk、不備份**(操作機重建就重新產生,OS 團隊重新佈署公鑰) | 過了權限閘門、要碰主機時檢查檔案在不在(沒掛載就擋下);ssh 直接用這個檔(`-i`、`IdentitiesOnly`、不用 ssh-agent) | 是(在獨立 file system 上,不在系統碟) |
| 91 緊急模式的 client 憑證(`OPMENU_BREAKGLASS_SECRET`,PEM) | CyberArk | 執行 91 時取到記憶體檔案系統,用完即刪;身分 `User:opmenu-breakglass` 在 MDS 綁 SystemAdmin | 否 |
| 34／35 產生的 service account 新密碼 | 操作者自己的交接檔 `OPMENU_HANDOVER_DIR`(預設 `$HOME/opmenu-handover`,操作機上是 `/root/opmenu-handover`,目錄 0700、檔 0600) | 產生時寫入,不顯示在畫面;交給 Secrets 團隊存進 PVWA 後刪除。交接目錄寫不進去就不改密碼 | **是**(暫存,交接後刪) |

## 換環境要做的事

1. 複製 `opmenu.conf.example` 為 `/etc/opmenu/opmenu.conf`,填入:bootstrap(LDAP listener)、broker 與輔助服務清單(主機:服務名)、controller 主機、PVWA object 名稱。
2. `/etc/opmenu/ssl/`:`truststore.p12`(只放銀行根憑證)、`truststore.pass`(0600 root)、`ca.pem`。
3. `/etc/opmenu/known_hosts`:各主機的 ssh 主機金鑰(`ssh-keyscan` 建,0644 root)。
4. `/var/log/opmenu/` 目錄 0750 root;`OPMENU_SYSLOG=1` 時紀錄另送 syslog(root 改得到本機紀錄檔,所以遠端 syslog 那份才是佐證)。
5. 各主機 cpuser 的 sudoers 永久規則 `/etc/sudoers.d/cpuser-ops`(安裝、升級時才另開全權 `/etc/sudoers.d/cpuser`),**逐一列出**,見下方「sudoers」。
6. 操作機的 `/secure/ssh`(獨立加密 file system)已掛載,`cpuser_ed25519` 為 root:root 0400;各主機 cpuser 的 `authorized_keys` 有對應公鑰(`from=` 只允許操作機)。
7. CyberArk:存 breakglass PEM(91 用);開給維運群組在 PVWA 取用(人工貼上,選單不連保管庫)。人員進操作機走 PVWA 網頁＋PSMP(進去是 root)。
7a. 建作業系統群組 `opmenu-emergency`(平常沒有成員),寫好事故時誰加人、事後誰移出的程序。操作者都是 root,所以「加人」就是把 root 加進群組:群組成了緊急主機模式的開關。
8. 其餘檔案不用改。

## 項目

| 層 | 編號 | 控管 |
|---|---|---|
| 1 值班查看 | 10 leader 與 partition 分布、11 cluster 與身分鏈健康檢查、12 topic 狀態、13 consumer lag、14 topic 設定、15 application 連線、16 磁碟用量、17 certificate 到期日、18 收集 diagnostics、19 生效中的設定 | 唯讀;16、18 碰主機,需 HOST 權限 |
| 2 服務操作 | 21 重啟 broker(先檢查 under-replicated / offline)、22 重啟 REST Proxy 或 C3（REST：設了 `OPMENU_LB_HOST` 時，那台還有從 LB 進來的連線就拒絕，要先請 LB 團隊停用，手把手 12.1）、23 看日誌、27 滾動重啟 | HOST 權限(Operator 以上);21、22、27 需確認 |
| 3 變更作業 | 31 建 topic、32 改 retention、33 刪 topic、34 新增 service account、35 更換密碼、36 重設 consumer 位置、37 下架 service account | ADMIN 權限;需確認;受並行鎖與變更時窗 |
| 4 授權與緊急 | 41 查看權限、42 指派或移除權限、43 匯出 audit、44 匯出權限清單（加 snapshot 為變更前完整快照，格式同每日備份）、45 查詢 audit、91 緊急模式 | 41/42/44/91 ADMIN、43/45 AUDIT;91 必填原因、逐條記錄 |

## 各 AD 群組需要的 RBAC(2026-10-22 lab 實測)

| 群組 | 角色 | 原因 |
|---|---|---|
| 維運(例 kafka-operators) | `Operator`(cluster)＋ `DeveloperManage` on `Topic:*` | 11 健康檢查、21/27 重啟前的 under-replicated 檢查用 `kafka-topics --describe`,它對每個 topic 都要 DescribeConfigs;只有 Operator 或 DeveloperRead 會被拒。DeveloperManage 也給了建刪 topic 的能力,若銀行不接受,改給 ClusterAdmin 或由 SystemAdmin 執行這幾項 |
| 開發(例 kafka-devs) | `DeveloperRead`/`DeveloperManage` on 自己的 prefix | 12、14 要 DescribeConfigs 才看得到明細;只有 DeveloperRead 時 12 會列名稱並註明無法顯示明細 |
| 管理(例 kafka-admins) | `SystemAdmin` | 第 3、4 層與 91 |
| 稽核 | `DeveloperRead` on audit topic 與 `audit-` consumer group prefix | 43、45 |

## 機制

- **身分**:操作者輸入自己的 AD 帳密(`OPMENU_USER_FROM_OS=0`:操作機上人員是 root,不是個人帳號,所以一律自己輸入 AD 帳密);選單立刻向 MDS 換 token,之後 MDS 呼叫用 token、Kafka 工具用 AD 帳密走 LDAP listener。
- **動態選單**:登入後用本人的 token 問 MDS 一次,只顯示有權限的項目;直接輸入隱藏的編號一樣被擋並記錄。
- **主機閘門**:碰主機的介面先向 MDS 確認本人有 `OPMENU_HOST_ACTION_AUTHZ`(預設 Operator 以上),因為主機端的 cpuser 是共用帳號。操作者是 root、讀得到金鑰,所以這是流程控管、不是硬性隔離(見上方「誠實的限制」)。
- **緊急主機模式**:MDS 連不上時,作業系統群組 `OPMENU_EMERGENCY_GROUP`(預設 opmenu-emergency,平常空)的人可以進入(操作者都是 root,所以平常 root 不在群組、緊急模式關著;事故時 OS 團隊臨時把 root 加進群組,事後移出),只開放 `OPMENU_EMERGENCY_ITEMS`(16 18 21 22 23);必填原因,操作者標成「未經 AD 驗證」,紀錄 EMERGENCY_HOST;21 的叢集檢查做不了時改成警告＋確認。
- **服務帳號 A／B**(`OPMENU_SVC_PAIR`,預設 `-a -b`):34 一次建兩個同權限的帳號,應用程式先用 -a;35 只換沒在用的那個,應用程式切過去後下次再換另一個,換密碼不停機;37 兩個一起下架。
- **17 憑證到期**:看各端點實際出示的憑證(`OPMENU_TLS_ENDPOINTS`,openssl s_client),不讀主機上的檔案;換發後沒重啟會看得出來。
- **確認**:變更類顯示將做什麼與影響,輸入 `yes` 才執行。
- **紀錄**:`時間 | 環境 | AD 帳號 | os=作業系統帳號 | 項目 | sid | 結果 | 參數`;結果為 OK / DENIED / AUTH_FAIL / FAIL / BLOCKED / EMERGENCY …;沒有私鑰檔(`/secure/ssh` 沒掛載)時主機類項目記成 BLOCKED(`no ssh key file`)。`os=` 欄在操作機上都是 root,真正的人是 AD 帳號那一欄
- **並行鎖、變更時窗**(`OPMENU_LOCK_*`、`OPMENU_CHANGE_WINDOW`):變更類項目同一時間一人、只在允許時段;91 不受時窗限制。
- **閒置逾時**:`OPMENU_IDLE_TIMEOUT` 秒。

## sudoers:每個服務、每種寫法逐一列出

sudoers 比對的是**完整的參數**:`journalctl -u confluent-server -n 5 --no-pager` 不會被 `journalctl -u confluent-server` 放行;而萬用字元 `*` 會連空格一起比對,
`restart confluent-*` 也會放行 `restart confluent-server sshd`(lab 實測)。所以選單送到主機的 sudo 寫法**固定**,規則逐一列出(`/etc/sudoers.d/cpuser-ops`,0440,`visudo -cf` 檢查;每台只列自己的服務):

| 選單做的事 | 送到主機的 sudo 指令(唯一寫法) |
|---|---|
| 21、22、27 重啟 | `sudo -n systemctl restart <服務>`(重啟後的 `systemctl is-active <服務>` 不需要 sudo) |
| 23 看日誌 | `sudo -n journalctl -u <服務> -n 200 --no-pager`(遠端行數固定 200;要看幾行由本機的 `tail -n <N>` 截,超過 200 行就當 200 行) |
| 18 收集診斷 | 逐台、逐服務 `sudo -n journalctl -u <服務> -n 200 --no-pager`(controller 主機只有 confluent-server;不再用 `confluent-*`) |
| (手動)看狀態 | `sudo systemctl status <服務>`(選單不用,列給維運人員手動) |

`<服務>` 只會是 `confluent-server`(controller、broker)、`confluent-kafka-rest`(REST Proxy)、`confluent-control-center`(C3)三種。
`tests/test-sudo-forms.sh` 檢查選單送出的每一種 sudo 寫法都在這份清單裡;改了寫法要同步改 `install/steps/16-opmenu.sh` 的規則與手把手 16.4。

## 用法

```bash
/opt/opmenu/opmenu.sh                 # 互動選單
/opt/opmenu/opmenu.sh --list          # 列出所有項目
OPMENU_USER=alice OPMENU_PASS=... OPMENU_YES=1 /opt/opmenu/opmenu.sh --run 31 orders.test 1   # 非互動(需 OPMENU_ALLOW_ENV_OVERRIDE=1)
tests/test-host-gate.sh tests/test-menu-filter.sh tests/test-ssh-key.sh tests/test-sudo-forms.sh   # 單元測試,不需要叢集或保管庫
bash ~/install/lab/opmenu-items-test.sh   # lab 全項目回歸(ops02 root;會重啟 kb03、rest02、滾動重啟全部 broker,約 10 分鐘)
bash ~/install/lab/opmenu-hostkey-test.sh # lab:私鑰檔缺少時被擋、sudoers 只放行列出的寫法(用臨時帳號驗,不動 cpuser 的全權規則)
```

lab 實測紀錄見 `redesign/README.md` 第 13 節與 `.claude/state/log/`。
