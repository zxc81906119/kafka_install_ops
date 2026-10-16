# Kafka 維運操作選單(OP menu)

> **在本專案中的位置(2026-10-16 起)**:這個目錄是 OP menu 的正式來源,和安裝工具 cpctl 放在同一個專案。
> - 部署走離線引進流程:`windows/package-opmenu.sh` 打包成 `packages/tools/opmenu-<日期>.<sha8>.tar.gz` → `cpctl repo import` → `cpctl step 11_opmenu` 安裝到堡壘機(`/opt/opmenu`),設定檔 `/etc/opmenu/opmenu.conf` 由 cpctl 依 inventory 產生。
> - 下文提到的 `demo/rocky/`、`test-all.sh` 等,是原始開發專案(docker demo 叢集)的整合測試,不在本專案;本專案以 `test-host-gate.sh`(不需叢集)與 `cpctl verify` 的「OP menu」段落驗證。

給操作員(OP)用的文字選單:登入後只能從選單執行審核過的作業,每次執行留紀錄。
**Kafka 的動作能不能做,由 Kafka 的 RBAC 依操作者本人的 AD 群組決定;主機的動作:node 用本人帳號時由各 node 的 sudo 規則決定,node 用共用固定帳號時由選單先向 MDS 確認權限(見「共用固定帳號的情境」)。**

## 結構(可抽換實作)

| 檔案 | 角色 | 設計模式 |
|---|---|---|
| `opmenu.conf` | **這個環境的設定**:連線位址、node 與服務名、命名規範。換環境只改這裡 | |
| `opmenu.conf.example` | 正式環境(RHEL 9 VM)的設定範本 | |
| `lib/defaults.sh` | 所有設定項目與預設值,兼說明文件;`opmenu.conf` 沒設的才用它 | |
| `opmenu.sh` | 進入點 | |
| `lib/core.sh` | 固定流程:登入身分 → 選單 → ticket → 確認 → 執行 → 記錄 | Template |
| `lib/backend/docker.sh` | 測試環境:用容器跑 Kafka 工具、`docker restart` | Strategy |
| `lib/backend/vm.sh` | 正式環境:本機工具、`systemctl`、`ssh`(未實測) | Strategy |
| `lib/ticket/format.sh` / `http.sh` | ticket 怎麼驗:只檢查格式,或向開單系統查(http 為範本,未實測);`OPMENU_TICKET_CHECK` 選 | Strategy |
| `lib/actions/tier1-view.sh` … `tier4-admin.sh` | 每個選單項目:編號、層級、是否需 ticket、是否需確認、做什麼 | Command |

後端只提供固定介面(`be_kafka`、`be_mds`、`be_mds_login`、`be_bootstrap_kafka`、`be_service_restart`、`be_service_logs`、`be_clean_logs`、`be_disk_usage`、`be_cert_list`、`be_collect_diag`、`be_hosts`)。
項目只呼叫這些介面與 `OPMENU_*` 設定,不碰 docker、systemctl 或任何主機名稱。程式碼裡沒有環境值。

## 換環境要做的事

1. 複製 `opmenu.conf.example` 為 `opmenu.conf`,填入:bootstrap 位址、broker 與輔助服務清單(主機:服務名)、controller 主機、ssh 與 ticket 政策、命名規範。其餘由「設定推算」補上(見下)。
2. `OPMENU_BACKEND=vm`。
3. node 上準備 sudo 規則(只開放 `systemctl restart/status`、`journalctl`、清理日誌腳本)與 bootstrap 的包裝腳本(`OPMENU_BOOTSTRAP_WRAPPER`)。
4. 其餘檔案不用改。

## 項目

| 層 | 編號 | 控管 |
|---|---|---|
| 1 值班查看 | 10 leader 與 partition 分布、11 cluster 與身分鏈健康檢查、12 topic 狀態、13 consumer lag、14 topic 設定、15 application 連線、16 磁碟、17 certificate 到期日、18 收集 diagnostics、19 生效設定 | 唯讀;需能 describe topic(實測 ops 的 Operator 不夠,見已知限制)|
| 2 服務操作 | 21 重啟 broker、22 重啟 REST Proxy 或 C3、23 看日誌、24 清理日誌、25 開始維護模式、26 結束維護模式、27 滾動重啟 broker | ticket;主機 sudo 規則;清單限制在 `OPMENU_BROKER_SERVICES` / `OPMENU_AUX_SERVICES` |
| 3 變更作業 | 31 建 topic、32 改 retention、33 刪 topic、34 新增 service account、35 更換密碼、36 重設 consumer 位置、37 下架 service account | ticket;命名規範檢查;31/32/33/36 需 ResourceOwner(Topic、Group),34/35 需 ClusterAdmin(34 綁權限另需 UserAdmin) |
| 4 授權與緊急 | 41 查看權限、42 指派或移除權限、43 匯出 audit、44 匯出權限清單、45 查詢 audit、91 緊急模式 | 41/42 需 UserAdmin(41 SecurityAdmin 亦可);43 需 audit topic 與 `audit-*` group 的 DeveloperRead;91 只允許 `OPMENU_EMERGENCY_TOOLS` 的工具,以 bootstrap 身分執行 |

各項需要的 role 是 2026-10-06 實測結果(`spike/group-roles/`);對應的 AD 群組見簡報「AD 群組對應 RBAC role」頁。

## 機制

- **身分**:操作者輸入自己的 AD 帳密(`OPMENU_USER_FROM_OS=1` 時帳號固定為作業系統登入者,只輸入密碼;vm 後端預設開);選單立刻向 MDS 換 token(之後呼叫 MDS 都用 token;帳密與 token 經 stdin 交給 curl,不出現在行程清單),並產生只有自己能讀(0600)的 Kafka 連線檔,放在記憶體檔案系統(`/dev/shm`),整個 session 期間存在、含明文密碼;離開或收到 INT/TERM/HUP 時刪除,被強制終止(KILL)時由下次啟動清掉;密碼不進紀錄。
- **ticket**(`OPMENU_TICKET_MODE`):`required` 第二層以上必填;`optional` 可填可不填;`none` 不問。ticket 怎麼驗由 `lib/ticket/<OPMENU_TICKET_CHECK>.sh` 決定(`format` 只看格式;`http` 向開單系統查單是否存在且已核准,範本未實測)。客戶沒有開單系統時用 `none` 或 `format`。
- **確認**:變更類顯示將做什麼與影響,輸入 `yes` 才執行。(雙人確認功能已於 2026-10-06 依客戶要求移除。)
- **紀錄**:`log/opmenu.log`,每行 `時間 | 環境 | 操作者 | 項目 | ticket | 結果 | 參數`;結果為 OK / DENIED / AUTH_FAIL / FAIL / ABORT / EMERGENCY。
- **閒置逾時**:`OPMENU_IDLE_TIMEOUT` 秒。

## 用法

```bash
./opmenu.sh                 # 互動選單
./opmenu.sh --list          # 列出所有項目
OPMENU_USER=gary OPMENU_PASS=... OPMENU_TICKET=CHG-2026-0001 OPMENU_YES=1 ./opmenu.sh --run 31 ops.test 1   # 非互動
./test-all.sh               # 測試環境的功能測試(需要 demo 的 gary)
./test-ticket.sh            # ticket 模式與檢查方式(含假的開單系統)
./test-user-from-os.sh      # 帳號取作業系統登入者(在容器裡以 OS 使用者 gary 執行)
```

## Rocky Linux 9 實測(`demo/rocky/`,2026-10-06)

vm 後端與作業系統層已用兩個 Rocky Linux 9 容器實測通過(23 項全部):
- `rocky-jump` jump host:Confluent 指令工具(從 cp-server 映像複製,路徑同 RPM)、Java 21、curl、ssh;操作員 `gary` 的登入殼層就是 `opmenu.sh`(`docker exec -it rocky-jump su - gary` 直接進選單);bootstrap certificate 在 `/etc/opmenu/bootstrap`,只有 `opbootstrap` 讀得到,`gary` 的 sudo 只開放 `/usr/local/sbin/opmenu-bootstrap`(`sudo -u opbootstrap`);設定檔在 `/etc/opmenu/opmenu.conf`(程式目錄唯讀掛載)。
- `rocky-node1` 假 node:systemd + sshd,`confluent-server`、`confluent-control-center` 是只寫日誌的假服務;`gary` 的 sudo 只開放 `systemctl restart/status confluent-*`、`journalctl`、`/usr/local/sbin/opmenu-clean-logs`。
- 跑法:`docker compose -f rocky/compose.yml up -d --build` 後 `bash rocky/test.sh`(在 `demo/`)。
- 正式環境與此的差異:node 上是真的 CP 服務;jump host 與 node 接 AD(本測試用本機帳號 + ssh 金鑰代替);紀錄時區要設 TZ。
- **sshd 旁路**(已實測擋下):jump host sshd 加 `Match Group opmenu` → `ForceCommand /opt/opmenu/opmenu.sh`、`AllowTcpForwarding no`、`AllowAgentForwarding no`。`ssh jump 指令`、scp、sftp 都只會進選單,原本想執行的指令記成 `BYPASS_ATTEMPT`;轉埠回 administratively prohibited。
- **ssh 到 node 的認證**(`OPMENU_SSH_AUTH`):`key`(預設)金鑰;`password` 用操作員登入選單的 AD 密碼(jump host 與 node 都接 AD 時),密碼只留在選單程序記憶體、經 `sshpass` 餵給 ssh,jump host 要裝 `sshpass`(EPEL)。兩種模式都用 ControlMaster:同一 session 同一 node 只認證一次,離開選單時連線全部關閉。node 不接 AD 時用 `OPMENU_SSH_USER=<共用維運帳號>` + 金鑰。
- **MDS 多台**:`OPMENU_MDS_URL` 逗號分隔,選單與 bootstrap 包裝腳本逐台嘗試(401/403 不換台);全部連不上時登入顯示「無法連到 MDS」、紀錄 `MDS_DOWN`。

## 安全修補(2026-10-06,批 A;回歸測試 `rocky/test-security.sh`)

| 項目 | 做法 |
|---|---|
| 輸入 allowlist | `lib/validate.sh`:主機與服務只接受設定清單內的值;數字只接受純數字;topic、consumer group、prefix、principal、AD 群組各有允許字元;重設位置只接受 earliest / latest / 時間格式。項目與後端各驗一次(後端不信任呼叫端) |
| ssh | 參數用 `--` 隔開;遠端指令只由固定字串與驗過的值組成 |
| 帳密與 token | curl 用 `-K -` 從 stdin 讀帳密與 Authorization 標頭,不進命令列。SCRAM 新密碼仍會短暫出現在 `kafka-configs` 的命令列(官方工具的檔案參數不適用 SCRAM,實測),正式環境建議 jump host 掛 `/proc` 時加 `hidepid=2` |
| 暫存連線檔 | 放 `/dev/shm`(記憶體),檔名含 pid;INT/TERM/HUP 都清;被 KILL 時由下次啟動清掉自己的殘留 |
| 紀錄 | 每個欄位去掉控制字元與分隔符,輸入不能造出另一行;加 session id、時區、回傳碼與耗時;`OPMENU_SYSLOG=1` 同時送 syslog(集中保存,操作員改不了) |
| 測試後門 | `OPMENU_USER/PASS/YES/TICKET/REASON` 環境變數只在 `OPMENU_ALLOW_ENV_OVERRIDE=1` 時有效;正式設定檔不要設 |
| 受保護 topic | `OPMENU_PROTECTED_TOPIC_PATTERN`:底線開頭、`confluent-` 開頭、audit topic,32/33 不處理 |
| 42 可指派的 role | `OPMENU_ROLES_ALLOWED`;SystemAdmin、UserAdmin、SecurityAdmin 不經選單 |
| 91 緊急模式 | `OPMENU_EMERGENCY_ACTIONS` 限定每個工具允許的動作;不得覆寫連線設定;必填原因並記錄 |
| 21 重啟前提 | 改查 under-replicated 與 offline partition 都為 0(官方滾動重啟的前提) |
| 33 刪除前檢查 | 一次描述全部 group,精確比對 topic 名稱 |
| 34 回滾 / 37 下架 | binding 失敗回滾(解除 binding、刪帳號);新增 37 下架 service account |
| 43 匯出 | 改為「最近 N 分鐘」(依事件時間過濾),不再是最舊 N 筆 |
| token 到期 | 登入超過 `OPMENU_TOKEN_TTL` 後遇到 401 提示重新登入 |

## 設定推算(2026-10-06)

opmenu.conf 只需要填「無法推算」的值。優先順序:**conf 有填 > 推算 > 預設**;推算不出來就明確報錯,不猜。選單項目 19 顯示每個值實際用了什麼,以及來源(conf / derived / default)。

| 設定 | 推算方式 | 備註 |
|---|---|---|
| `OPMENU_TRUSTSTORE`、`OPMENU_TRUSTSTORE_PASSWORD_FILE`、`OPMENU_CA_PEM` | 都在 `OPMENU_CERT_DIR` 底下,檔名固定 | 檔名不同才個別設定 |
| `OPMENU_MDS_URL` | bootstrap 每台主機(去重)+ `https` + `OPMENU_MDS_PORT`(預設 8091) | bootstrap 若是 VIP / DNS 別名,或 MDS 只開在部分 broker,要直接填 |
| `OPMENU_KAFKA_CLUSTER_ID` | 登入後向 MDS `/v1/metadata/id` 取(不需帳密) | 取不到就報錯 |
| `OPMENU_HOSTS` | `OPMENU_BROKER_SERVICES` 與 `OPMENU_AUX_SERVICES` 的主機 + `OPMENU_CONTROLLER_HOSTS` | 它是 ssh 的允許清單,來源是人工審過的 conf,不是叢集 |
| `OPMENU_REPLICATION` | 預設 3;沒填且 broker 少於 3 台時,降到 `OPMENU_BROKER_SERVICES` 的 broker 數 | |

**刻意不推算**(實測後撤回):broker 清單與節點清單不從叢集取(broker 掛掉後會從叢集的清單消失,正是需要重啟的那台;而且它們是重啟、ssh 的允許清單,必須是經變更管理審過的固定設定);資料目錄不讀 `log.dirs`(要 ClusterAdmin 才讀得到、不同人看到不同結果、真實 broker 常有多個目錄)。

回歸測試:`test-derive.sh`(精簡設定檔 `test-minimal.conf`)。

## 批 B、C、D 新功能(2026-10-06)

| 功能 | 說明 | 設定(預設) |
|---|---|---|
| **變更時窗** | 需 ticket 的項目只能在時窗內執行;91 緊急模式與唯讀項目不受限。格式 `Mon-Fri 22:00-06:00;Sat,Sun 00:00-23:59`,跨午夜算起始那天 | `OPMENU_CHANGE_WINDOW`(空 = 不限制)、`OPMENU_WINDOW_EXEMPT`(91) |
| **並行鎖** | 需 ticket 的項目同一時間只允許一個人執行,別人會看到誰在做什麼;持有者的行程不在了就視為過期 | `OPMENU_LOCK_DIR`、`OPMENU_LOCK_WAIT`(0)。**只在同一台跳板機有效**;目錄要讓所有操作員可寫、不能有 sticky bit |
| **25 / 26 維護模式** | 對指定 node 建立 / 提前結束 Alertmanager silence(label 用 `OPMENU_MAINT_LABEL`),最長 `OPMENU_MAINT_MAX_MIN` 分鐘;只能結束 createdBy 是 opmenu 的 | 設了 `OPMENU_ALERTMANAGER_URL` 才出現;支援 HTTPS 與 Basic 認證:帳密來源二選一——`OPMENU_ALERTMANAGER_AUTH_CMD`(執行時用指令取得,stdout 印 `帳號:密碼`,例如向 CyberArk / Conjur 取:`bash scripts/conjur.sh get-as opmenu opmenu/alertmanager-auth`,帳密不落地;第 18 章)或 `OPMENU_ALERTMANAGER_AUTH_FILE`(檔案,權限 0640 或更嚴)。建議用維護模式專用帳號,不與 C3 共用;帳密以 `curl -K -` 從 stdin 給,不出現在行程清單。Basic 沒有細部授權,有這組帳密就能對 Alertmanager 寫入 |
| **27 滾動重啟** | 依 `OPMENU_BROKER_SERVICES` 順序一台一台重啟;開始前與每台重啟後都要「所有 broker 在線、under-replicated 與 offline 為 0」才繼續,逾時或失敗就停止。不含 controller | `OPMENU_ROLLING_TIMEOUT`(600)。只有 1 台 broker 時拒絕 |
| **11 身分鏈健康(併入 cluster 健康檢查)** | MDS 逐台狀態與延遲、token 剩餘時間、broker 在線數、controller quorum(要 ClusterAdmin) | — |
| **10 leader / partition 分布** | 每台 broker 的 leader 數、replica 數、非 preferred leader 數與偏離平均的百分比 | — |
| **44 權限清單匯出** | 依 `OPMENU_REVIEW_ROLES` 列出每個 role 的 principal 與資源範圍,輸出 CSV 供定期覆核 | 需 SecurityAdmin 或 UserAdmin |
| **45 audit 查詢** | 最近 N 分鐘,可依主體、結果(ALLOWED / DENIED)篩選,畫面顯示最後 50 筆 | 需 audit topic 與 `audit-*` group 的 DeveloperRead |

**刻意沒做**:臨時授權加 TTL(RBAC 綁的是 AD 群組,臨時授權應該是 AD 群組成員的到期,屬於 AD 流程;選單自己加到期需要排程撤銷,漏跑會留下過大權限)、partition 搬移精靈(需要 throttle 與回滾,風險高,建議先在真實叢集手動演練後再決定)。

**修正**:43 讀 audit 原本用固定 consumer group,第一次讀完會提交 offset,之後只讀得到新事件;改成每次不提交 offset 的獨立 group。回歸測試:`test-batch-bcd.sh`(加 `--rolling` 會真的重啟兩台 broker)。

## 共用固定帳號的情境(2026-10-16)

客戶的跳板機與 node 都不接 AD、只開共用固定帳號時,作業系統帳號不能當身分。做法與修補:

| 項目 | 做法 |
|---|---|
| 身分 | `OPMENU_USER_FROM_OS=0`:操作者輸入自己的 AD 帳密,由 MDS 驗證(跳板機不必接 AD);紀錄與 Kafka audit 都是本人 |
| **主機類動作的權限閘門**(新增) | 原本「主機的動作由 node 的 sudo 決定」,node 是共用帳號時任何通過 AD 驗證的人都能重啟服務。現在碰 node 前(重啟、日誌、清日誌、磁碟、診斷)先用操作者本人的 token 呼叫 MDS `PUT /security/1.0/authorize`,檢查 `OPMENU_HOST_ACTION_AUTHZ`(預設 `Topic:__opmenu-host-ops:Describe`,等於叢集層級的 Topic Describe:Operator 以上通過,只有個別 topic 權限的人被拒)。MDS 會展開 AD 群組,而且只能問自己(代別人問回 403),所以無法冒用。任何錯誤一律拒絕。以 Decorator 包在後端介面上(`core_guard_host_actions`),新增項目不會漏 |
| **21 重啟前檢查失敗即拒絕**(修正) | 原本 `be_kafka … \| grep -c "Partition:"` 在指令失敗(沒權限、連不上)時數到 0 而**放行重啟**;改為檢查回傳碼,失敗就拒絕 |
| **23 看日誌不再吞掉失敗**(修正,PoC 整合實測發現) | 原本 `be_service_logs … | grep ERROR|WARN | tail` 以 tail 的結果為準,閘門拒絕或 ssh 失敗會顯示「沒有錯誤或警告」並記 OK;改為先取回傳碼再過濾 |
| 紀錄 | 共用帳號改得到本機 `opmenu.log`,以 `OPMENU_SYSLOG=1` 轉送 SIEM 的那份為準 |

回歸測試:`test-host-gate.sh`(不需要叢集,假後端;12 項)。實測:在 Confluent Platform 8.3.2 PoC(untitled7,RPM + systemd 的真實節點)以 vm 後端整合驗證。

## 已知限制與上線前檢查(2026-10-06 夜)

**已知限制**
- **環境變數覆蓋**:`OPMENU_*` 設定的優先順序是 conf > 環境變數 > 預設(`OPMENU_USER/PASS/YES/TICKET/REASON` 例外,正式設定下一律忽略)。若操作員能在啟動選單前設定環境變數(例如 `OPMENU_TICKET_MODE=none`、`OPMENU_CHANGE_WINDOW=`),就能繞過政策。正式環境選單是登入殼層,操作員沒有這個管道;sshd 預設只接受 `LANG`、`LC_*`(RHEL 預設值,客戶實際設定未驗證)。**上線時請確認 sshd 的 `AcceptEnv` 不含 `OPMENU_*`,且 `PermitUserEnvironment no`。** 要徹底解決需要改成「正式環境一律忽略環境變數」,會連帶要改所有測試腳本,未做。
- **並行鎖只在同一台跳板機有效**。多台跳板機要把 `OPMENU_LOCK_DIR` 放在共用檔案系統。
- **滾動重啟不含 controller**(controller 的服務名與重啟順序沒有在真實 CP 節點驗證)。判斷「健康」用的是:重啟後先等 `OPMENU_ROLLING_SETTLE` 秒,再連續 `OPMENU_ROLLING_STABLE` 次檢查「全部 broker 在線、under-replicated 與 offline 為 0」;沒有逐台確認 ISR 成員。
- **維護模式**目前只支援不需認證的 Alertmanager。
- 部署環境以 docker demo 為準(使用者決定,2026-10-07),不另外在真實 CP 節點(RPM、systemd)驗證重啟行為、SELinux、`hidepid=2`;Rocky 9 容器是 vm 後端的模擬。

**上線前檢查**
1. `opmenu.conf` 只填:bootstrap、`OPMENU_BROKER_SERVICES`、`OPMENU_AUX_SERVICES`、`OPMENU_CONTROLLER_HOSTS`、ssh 與 ticket 政策、命名規範(見 `opmenu.conf.example`)。
2. 登入後先看項目 19:cluster ID、MDS 位址、節點清單、副本數是不是你預期的值。
3. `OPMENU_ALLOW_ENV_OVERRIDE` 必須是 0(或不設)。
4. 跳板機上 `OPMENU_LOCK_DIR` 的上層目錄(預設 `OPMENU_OUT_DIR`)要讓所有操作員可寫。
5. 要用維護模式再填 `OPMENU_ALERTMANAGER_URL`(Alertmanager 有 Basic 就加 `OPMENU_ALERTMANAGER_AUTH_FILE`);要限制變更時段再填 `OPMENU_CHANGE_WINDOW`。
6. 跑一次 `test-derive.sh`(推算)與 `test-batch-bcd.sh`(新功能)確認環境無誤(需要 demo 或等同的測試叢集)。

**角色與群組對齊(2026-10-07)**:demo 的 AD 群組已對齊簡報的 7 組(`orders-read`、`ops`、`topic-admin`、`cluster-admin`、`rbac-admin`、`security`、`breakglass`,另有示範用的 `orders-write`),使用者名稱改為 CN(大寫,例如 GARY),組長 GARY 不再是 SystemAdmin,而是 `cluster-admin`、`topic-admin`、`rbac-admin`、`security` 四組。實測結果:
- **`ops`(Operator)單獨做不了 `kafka-topics --describe`**(`TopicAuthorizationException`),只能列出 topic 清單。所以依賴 describe 的項目(10 leader 分布、11 健康檢查的 partition 檢查、27 滾動重啟)需要 `topic-admin`(ResourceOwner)或等同權限;只屬於 `ops` 的人跑這幾項會被拒。這回答了「Operator 能不能做健康檢查」。
- `topic-admin`(ResourceOwner Topic*、Group*)是**強角色**:能建/刪 topic、讀資料,並且能在自己的 Topic* 範圍內改授權(實測 204)。所以只在需要時臨時加入,事後收回(第 11 章)。
- `rbac-admin`(UserAdmin)只能改授權,不能建 topic、不能讀資料。

**滾動重啟遇到 broker 起不來(實測 2026-10-07)**:叢集連續跑了一整天(metadata 約 13000 筆)後,broker1 重啟時因 SCRAM 憑證還沒載入、authorizer 用 SCRAM 連自己失敗(`SaslAuthenticationException`)而啟動退出,再啟動一次也一樣。原因是推測(metadata 變長、重放變慢),未確認。27 滾動重啟的行為符合設計:它偵測到 broker1 沒有回到 cluster,等到 `OPMENU_ROLLING_TIMEOUT` 逾時就停止,**沒有動後面的 broker**,所以服務沒有中斷。恢復方式:看該節點日誌找原因;demo 用冷啟動(`docker compose down -v` 後 `scripts/up.sh`)重建。
