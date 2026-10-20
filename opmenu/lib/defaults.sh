# defaults.sh — 所有可調整的設定與預設值,集中在這裡。
# 實際環境請在 opmenu.conf 覆寫(opmenu.conf 先載入,這裡只填沒設定的);不要改這個檔案。
# 寫法 [ -n "${X:-}" ] || X='...' 是刻意的:避免 ${X:=...} 在值含有 } 時被截斷。
declare -A OP_SRC=()   # 每個設定的值從哪來:conf = opmenu.conf;default = 預設;derived = 登入後從 cluster 或其他設定推算(顯示在項目 19)
d() { local n="$1" v="$2"; if [ -n "${!n:-}" ]; then OP_SRC[$n]=conf; else printf -v "$n" '%s' "$v"; OP_SRC[$n]=default; fi; export "$n"; }
# 能由其他設定算出來的值:opmenu.conf 沒填才算(dd <名稱> <算出來的值>;空值視為算不出來,維持沒設定)
dd() { local n="$1" v="$2"; [ -z "${!n:-}" ] || return 0; [ -n "$v" ] || return 0; printf -v "$n" '%s' "$v"; OP_SRC[$n]=derived; export "$n"; }
_hosts_of() { local x out=" "; for x in "$@"; do x="${x%%:*}"; x="${x#https://}"; [[ "$out" == *" $x "* ]] || out+="$x "; done; echo "${out# }" | sed 's/ $//'; }   # 取主機名、去掉埠與服務名、去重

# ── 環境 ──
d OPMENU_BACKEND         docker            # docker | vm
d OPMENU_ENV_LABEL       PROD              # 畫面上的環境標示
d OPMENU_LOG             "$OPMENU_HOME/log/opmenu.log"
d OPMENU_OUT_DIR         "$(dirname "$OPMENU_LOG")"   # 18 diagnostic bundle、43 audit 匯出檔放哪裡(正式環境程式目錄唯讀,放 /var/log/opmenu)
d OPMENU_IDLE_TIMEOUT    900               # 選單閒置幾秒自動登出
d OPMENU_USER_FROM_OS    "$([ "$OPMENU_BACKEND" = vm ] && echo 1 || echo 0)"   # 1 = 操作者帳號固定取作業系統登入者(jump host 接 AD 時),不能輸入別人的帳號;仍要輸入 AD 密碼

# ── 連線(兩種後端共用的名稱;值依環境) ──
d OPMENU_BOOTSTRAP       'kafka1.example.com:9094,kafka2.example.com:9094,kafka3.example.com:9094'   # broker 對外埠
d OPMENU_MDS_PORT        8091              # MDS 的埠;OPMENU_MDS_URL 沒填時,用 bootstrap 的每台主機加這個埠(https)推算
d OPMENU_MDS_URL         ''                # 可填多台(逗號分隔),逐台嘗試;空 = 由 OPMENU_BOOTSTRAP 推算
d OPMENU_KAFKA_CLUSTER_ID ''               # 空 = 登入後向 MDS 取(/v1/metadata/id,不需帳密)
d OPMENU_CERT_DIR        '/etc/kafka/secrets'                          # certificate 目錄;17 certificate 到期日掃這裡,下面三個檔案預設都放在這裡
d OPMENU_TRUSTSTORE      "$OPMENU_CERT_DIR/truststore.p12"             # 操作者連線用的 truststore(在執行環境裡的路徑)
d OPMENU_TRUSTSTORE_PASSWORD_FILE "$OPMENU_CERT_DIR/truststore_creds"
d OPMENU_CA_PEM          "$OPMENU_CERT_DIR/ca.pem"                     # curl 呼叫 MDS 用
if [ -z "${OPMENU_MDS_URL:-}" ]; then   # 由 bootstrap 的主機推算 MDS 位址
  _m=""; for _h in $(_hosts_of ${OPMENU_BOOTSTRAP//,/ }); do _m+="https://$_h:$OPMENU_MDS_PORT,"; done
  dd OPMENU_MDS_URL "${_m%,}"; unset _m _h
fi

# ── node 與服務(VM 後端用;docker 後端用容器名稱) ──
d OPMENU_CONTROLLER_HOSTS ''                                            # KRaft controller 的主機(空白分隔);要 ClusterAdmin 才查得到,Operator 查不到,所以要填(沒有獨立 controller 就留空)

d OPMENU_BROKER_SERVICES ''                                             # 21 可重啟的 broker(主機:服務名);必填:這是重啟、ssh 的允許清單,不從 cluster 推算
d OPMENU_AUX_SERVICES    ''                                             # 22 可重啟的 REST Proxy / C3(主機:服務名);cluster 裡沒有這些資訊,要填
d OPMENU_HOSTS           ''                                             # node 清單;空 = BROKER_SERVICES 與 AUX_SERVICES 的主機 + OPMENU_CONTROLLER_HOSTS
d OPMENU_DATA_DIR        '/var/lib/kafka'                               # 16 磁碟用量看的目錄(各 broker 通常有自己的 log.dirs;不同時請填)
d OPMENU_SSH_USER        ''                                             # VM:空 = 用操作者本人帳號 ssh(node 接 AD);否則共用維運帳號
d OPMENU_SSH_AUTH        key                                            # VM:key = 金鑰 | password = 用登入選單的 AD 密碼(兩邊都接 AD;jump host 要裝 sshpass)
d OPMENU_SSH_CONTROL_PERSIST 600                                        # VM:同一 node 的 ssh 連線重用幾秒(ControlMaster);離開選單時全部關閉
d OPMENU_BOOTSTRAP_WRAPPER '/usr/local/sbin/opmenu-bootstrap'           # VM:經 sudo 以專用帳號使用 bootstrap certificate 的包裝腳本
d OPMENU_BOOTSTRAP_USER  'opbootstrap'                                  # VM:保管 bootstrap certificate 的專用帳號(sudo -u 這個帳號執行包裝腳本)
d OPMENU_CLEAN_LOGS_CMD  '/usr/local/sbin/opmenu-clean-logs'            # VM:node 上清理日誌的腳本(sudo 規則只開放它)

# ── docker 後端專用 ──
d OPMENU_DOCKER_NETWORK  cpsec_default
d OPMENU_DOCKER_IMAGE    confluentinc/cp-server:8.3.2
d OPMENU_DOCKER_CURL_IMAGE curlimages/curl:8.22.0
d OPMENU_DOCKER_OPENSSL_IMAGE alpine/openssl

# ── 規範(依客戶的命名與變更管理規定調整) ──
d OPMENU_TICKET_MODE     required          # ticket:required = 必填 | optional = 可填可不填 | none = 不問 ticket
d OPMENU_TICKET_CHECK    format            # ticket 怎麼驗:lib/ticket/<名稱>.sh(format = 只檢查格式;http = 向開單系統查,範本未實測);可自行新增
d OPMENU_TICKET_PATTERN  '^[A-Z]{2,5}-[0-9]{4}-[0-9]{3,6}$'            # ticket 格式,例 CHG-2026-0001(format 與 http 都會先檢查)
d OPMENU_TICKET_URL      ''                                             # http:查單的網址,ticket 接在後面;回應符合 OPMENU_TICKET_OK_PATTERN 才算核准
d OPMENU_TICKET_OK_PATTERN '"status" *: *"approved"'
d OPMENU_TOPIC_PATTERN   '^[a-z][a-z0-9]+\.[a-z0-9.-]+$'                # topic 命名:<系統>.<名稱>
d OPMENU_SVC_PATTERN     '^svc-[a-z][a-z0-9-]+$'                        # service account:svc-<系統>
d OPMENU_REPLICATION     3                                              # 建 topic 的 replication factor(標準值);沒填且 broker 少於 3 台時,登入後自動降到 broker 數
d OPMENU_MIN_LOG_KEEP_DAYS 7                                            # 24 清理日誌至少保留天數
d OPMENU_EMERGENCY_TOOLS 'kafka-topics kafka-configs kafka-consumer-groups kafka-acls kafka-metadata-quorum'   # 91 允許的工具
d OPMENU_AUDIT_TOPIC     confluent-audit-log-events                     # 43 匯出的 audit topic
d OPMENU_AUDIT_GROUP_PREFIX 'audit-'                                     # 43 讀 audit topic 用的 consumer group prefix(audit 群組要有這個 prefix 的 DeveloperRead)

# ── 安全(2026-10-06 加入;正式環境請維持預設) ──
d OPMENU_PROTECTED_TOPIC_PATTERN '^(_|__|confluent-audit-log-events$|confluent-)'   # 受保護的 topic:內部、audit、平台用;32/33 等變更項目不處理
d OPMENU_GROUP_PATTERN   '^[A-Za-z0-9._-]{1,200}$'                      # consumer group 名稱允許的字元
d OPMENU_ROLES_ALLOWED   'DeveloperRead DeveloperWrite DeveloperManage ResourceOwner Operator ClusterAdmin'   # 42 可指派的 role(SystemAdmin、UserAdmin、SecurityAdmin 不經選單)
d OPMENU_EMERGENCY_ACTIONS 'kafka-topics=--list,--describe,--create,--alter,--delete kafka-configs=--describe,--alter kafka-consumer-groups=--list,--describe,--reset-offsets kafka-acls=--list kafka-metadata-quorum=describe'   # 91 每個工具允許的動作
d OPMENU_ALLOW_ENV_OVERRIDE 0        # 1 = 接受 OPMENU_USER/PASS/YES/TICKET 等環境變數(只給自動化測試用);正式環境 0
d OPMENU_SYSLOG          1           # 1 = 每筆紀錄同時送 syslog(logger -t opmenu),集中保存、操作員無法改
d OPMENU_TMPDIR          "$(_t=$(mktemp -p /dev/shm 2>/dev/null) && { rm -f "$_t"; echo /dev/shm; } || echo "${TMPDIR:-/tmp}")"   # 暫存連線檔放記憶體檔案系統;真的能在 /dev/shm 建檔才用(Git Bash 有這個路徑但不能用)
d OPMENU_HOST_ACTION_AUTHZ 'Topic:__opmenu-host-ops:Describe'   # 主機類動作(重啟、日誌、磁碟、診斷)前向 MDS 確認的權限 <資源類型>:<名稱>:<操作>;預設等於「叢集層級可 describe 所有 topic」(Operator 以上),只有個別 topic 權限的人會被拒。node 用共用維運帳號時一定要設;空 = 不檢查
d OPMENU_TOKEN_TTL       3600       # MDS token 壽命(秒,依 MDS 設定);超過後遇到 401 會提示重新登入而不是密碼錯
# ── 動態選單(2026-10-19):登入後用本人的 token 一次問 MDS,只顯示有權限的項目;MDS 會展開 AD 群組,所以「依 AD 群組不同」
# 而且只有 RBAC 一份設定。只影響「看得到什麼」:執行時 Kafka / MDS / 主機閘門照樣檢查,直接輸入隱藏的編號一樣會被擋。
d OPMENU_MENU_FILTER     1           # 1 = 依權限顯示;0 = 全部顯示(舊行為)
d OPMENU_ADMIN_AUTHZ     'Cluster:kafka-cluster:Alter'               # ADMIN:變更、權限管理、緊急模式(SystemAdmin / ClusterAdmin 才有)
d OPMENU_AUDIT_AUTHZ     'Topic:confluent-audit-log-events:Read'     # AUDIT:匯出、查詢 audit 紀錄
# 每個項目要什麼權限:<編號或第幾層*>=<HOST | ADMIN | AUDIT | - | 資源類型:名稱:操作>;沒列到的 = 不限制(查看類,Kafka 只回你看得到的)。
# HOST = OPMENU_HOST_ACTION_AUTHZ(碰主機:重啟、日誌、磁碟、診斷、告警靜音)。後面的設定覆蓋前面的(例 "3*=ADMIN 31=-")。
d OPMENU_MENU_AUTHZ      '16=HOST 18=HOST 2*=HOST 3*=ADMIN 41=ADMIN 42=ADMIN 43=AUDIT 44=ADMIN 45=AUDIT 91=ADMIN'

# ── 批 B、C、D(2026-10-06) ──
d OPMENU_LOCK_DIR        "$OPMENU_OUT_DIR/opmenu.lock.d"                # 並行鎖:同一時間只允許一個人做需 ticket 的變更項目(只在同一台跳板機有效;所在目錄要讓所有操作員可寫、不能有 sticky bit)
d OPMENU_LOCK_WAIT       0                                              # 拿不到鎖時最多等幾秒;0 = 直接拒絕
d OPMENU_CHANGE_WINDOW   ''                                             # 變更時窗,空 = 不限制。格式 "Mon-Fri 22:00-06:00;Sat,Sun 00:00-23:59"(跨午夜的算起始那天);分號分隔多段
d OPMENU_WINDOW_EXEMPT   '91'                                           # 不受時窗限制的項目(緊急模式)
d OPMENU_ALERTMANAGER_URL ''                                            # Alertmanager 位址(例 https://am.bank.local:9093);空 = 不提供維護模式項目 25、26
d OPMENU_ALERTMANAGER_AUTH_CMD ''                                       # Alertmanager 帳密改由指令取得(stdout 印 帳號:密碼),例如向 CyberArk 取;設了就優先於 AUTH_FILE,帳密不落地
d OPMENU_ALERTMANAGER_AUTH_FILE ''                                      # Alertmanager 啟用 Basic 認證時:放 帳號:密碼 的檔案(權限 0640 或更嚴;建議用維護模式專用帳號,不與 C3 共用);空 = 不帶帳密
d OPMENU_MAINT_LABEL     instance                                       # 維護模式用哪個 alert label 對應節點(Prometheus 預設 instance)
d OPMENU_MAINT_MAX_MIN   240                                            # 維護模式最長幾分鐘
d OPMENU_ROLLING_TIMEOUT 600                                            # 27 滾動重啟:每台重啟後最多等幾秒回到叢集且 under-replicated 回到 0
d OPMENU_REVIEW_ROLES    'SystemAdmin ClusterAdmin SecurityAdmin UserAdmin AuditAdmin ResourceOwner Operator DeveloperManage DeveloperWrite DeveloperRead'   # 44 權限覆核匯出要列的 role
d OPMENU_ROLLING_SETTLE  45                                             # 27 滾動重啟:每台重啟後先等幾秒才開始判斷(要超過 broker 被判定離線、ISR 縮減的時間,預設分別約 9 秒、30 秒;不等的話剛重啟時會誤判成健康)
d OPMENU_ROLLING_STABLE  2                                              # 27 滾動重啟:連續幾次檢查都健康才換下一台
