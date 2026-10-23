# defaults.sh — 所有可調整的設定與預設值,集中在這裡。
# 實際環境請在 opmenu.conf 覆寫(opmenu.conf 先載入,這裡只填沒設定的);不要改這個檔案。
# 寫法 [ -n "${X:-}" ] || X='...' 是刻意的:避免 ${X:=...} 在值含有 } 時被截斷。
declare -A OP_SRC=()   # 每個設定的值從哪來:conf = opmenu.conf;default = 預設;derived = 登入後從 cluster 或其他設定推算(顯示在項目 19)
d() { local n="$1" v="$2"; if [ -n "${!n:-}" ]; then OP_SRC[$n]=conf; else printf -v "$n" '%s' "$v"; OP_SRC[$n]=default; fi; export "$n"; }
# 能由其他設定算出來的值:opmenu.conf 沒填才算(dd <名稱> <算出來的值>;空值視為算不出來,維持沒設定)
dd() { local n="$1" v="$2"; [ -z "${!n:-}" ] || return 0; [ -n "$v" ] || return 0; printf -v "$n" '%s' "$v"; OP_SRC[$n]=derived; export "$n"; }
_hosts_of() { local x out=" "; for x in "$@"; do x="${x%%:*}"; x="${x#https://}"; [[ "$out" == *" $x "* ]] || out+="$x "; done; echo "${out# }" | sed 's/ $//'; }   # 取主機名、去掉埠與服務名、去重

# ── 環境 ──
d OPMENU_BACKEND         vm                # 只有 vm(2026-10-22 起:操作機本機跑 Kafka 工具、ssh 到各主機)
d OPMENU_ENV_LABEL       PROD              # 畫面上的環境標示
d OPMENU_LOG             "$OPMENU_HOME/log/opmenu.log"
d OPMENU_OUT_DIR         "$(dirname "$OPMENU_LOG")"   # 18 diagnostic bundle、43 audit 匯出檔放哪裡(正式環境程式目錄唯讀,放 /var/log/opmenu)
d OPMENU_IDLE_TIMEOUT    900               # 選單閒置幾秒自動登出
d OPMENU_USER_FROM_OS    0                 # 1 = 操作者帳號固定取作業系統登入者(操作機帳號就是 AD 帳號時);0 = 操作者輸入自己的 AD 帳號(操作機用本機個人帳號 opxx 時)

# ── 連線 ──
d OPMENU_BOOTSTRAP       'kafka1.example.com:9096,kafka2.example.com:9096,kafka3.example.com:9096'   # broker 給人員用的 LDAP listener(AD 帳密)
d OPMENU_MDS_PORT        8090              # MDS 的埠;OPMENU_MDS_URL 沒填時,用 bootstrap 的每台主機加這個埠(https)推算
d OPMENU_MDS_URL         ''                # 可填多台(逗號分隔),逐台嘗試;空 = 由 OPMENU_BOOTSTRAP 推算
d OPMENU_KAFKA_CLUSTER_ID ''               # 空 = 登入後向 MDS 取(/v1/metadata/id,不需帳密)
d OPMENU_CERT_DIR        '/etc/opmenu/ssl'                                   # certificate 目錄;17 certificate 到期日掃這裡,下面三個檔案預設都放在這裡
d OPMENU_TLS_ENDPOINTS   ''                                             # 17 檢查哪些端點實際出示的憑證（主機:埠，空白分隔）；空 = controller 的 9093、broker 的 9092／9095／8090、REST 的 8082、C3 的 9021
d OPMENU_TRUSTSTORE      "$OPMENU_CERT_DIR/truststore.p12"                   # 操作者連線用的 truststore(只放銀行根憑證)
d OPMENU_TRUSTSTORE_PASSWORD_FILE "$OPMENU_CERT_DIR/truststore.pass"
d OPMENU_CA_PEM          "$OPMENU_CERT_DIR/ca.pem"                           # curl 呼叫 MDS 用(銀行根憑證)
if [ -z "${OPMENU_MDS_URL:-}" ]; then   # 由 bootstrap 的主機推算 MDS 位址
  _m=""; for _h in $(_hosts_of ${OPMENU_BOOTSTRAP//,/ }); do _m+="https://$_h:$OPMENU_MDS_PORT,"; done
  dd OPMENU_MDS_URL "${_m%,}"; unset _m _h
fi

# ── node 與服務 ──
d OPMENU_CONTROLLER_HOSTS ''                                            # KRaft controller 的主機(空白分隔);要 ClusterAdmin 才查得到,Operator 查不到,所以要填(沒有獨立 controller 就留空)
d OPMENU_BROKER_SERVICES ''                                             # 21 可重啟的 broker(主機:服務名);必填:這是重啟、ssh 的允許清單,不從 cluster 推算
d OPMENU_AUX_SERVICES    ''                                             # 22 可重啟的 REST Proxy / C3(主機:服務名);cluster 裡沒有這些資訊,要填
d OPMENU_HOSTS           ''                                             # node 清單;空 = BROKER_SERVICES 與 AUX_SERVICES 的主機 + OPMENU_CONTROLLER_HOSTS
d OPMENU_DATA_DIR        '/var/lib/kafka/data'                          # 16 磁碟用量看的目錄(各 broker 通常有自己的 log.dirs;不同時請填)
d OPMENU_SSH_USER        cpadmin                                        # 各主機上的帳號:和安裝同一個;sudo 只永久開 systemctl restart/status confluent-*、journalctl -u confluent-*
d OPMENU_SSH_CONTROL_PERSIST 600                                        # 同一 node 的 ssh 連線重用幾秒(ControlMaster);離開選單時全部關閉
d OPMENU_KNOWN_HOSTS     '/etc/opmenu/known_hosts'                         # 各主機的 ssh 主機金鑰(管理員用 ssh-keyscan 建,0644 root);選單只信這份,不接受新主機

# ── 機敏資料:由保管庫取,選單啟動時載入記憶體,離開時清掉(2026-10-22)──
d OPMENU_SECRETS         conjur                                         # lib/secrets/<名稱>.sh:conjur(Conjur REST,lab 用它扮演 CyberArk)| ccp(PAM 的 Central Credential Provider,範本)| manual(沒有 CCP:登入後從 PVWA 取出貼上)
d OPMENU_SSH_KEY_SECRET  'kafka/ssh/cpadmin'                            # 保管庫裡「操作機 → 各主機 cpadmin」的 SSH 私鑰(和安裝同一把);空 = 不取,改用 ~/.ssh 既有金鑰
d OPMENU_BREAKGLASS_SECRET 'kafka/breakglass/pem'                       # 91 緊急模式用的 client 憑證(私鑰 + 憑證鏈,PEM);只在執行 91 時取,用完即丟
d OPMENU_BREAKGLASS_BOOTSTRAP ''                                        # 91 連的 TOKEN listener(主機:9094,逗號分隔);空 = 由 OPMENU_BOOTSTRAP 的主機 + OPMENU_TOKEN_PORT 推算
d OPMENU_TOKEN_PORT      9094
d OPMENU_SSH_KEY_TTL     14400                                          # 取回的 SSH 私鑰在 ssh-agent 裡最多留幾秒(保險:選單被強制終止時 agent 也會到期)
d OPMENU_SSH_KEY_LOAD    auto                                           # 主機用的 SSH 私鑰何時取：login（登入就取）| on-demand（第一次做主機類項目、過了權限閘門才取）| auto（manual 來源用 on-demand，其他用 login）
# conjur:設定檔與身分檔(身分 = 這台操作機給選單用的 host 身分,正式環境換成 CCP 的 AppID)
d OPMENU_CONJUR_URL      'https://conjur.example.com'
d OPMENU_CONJUR_ACCOUNT  poc
d OPMENU_CONJUR_IDENTITY '/etc/opmenu/conjur.identity'                  # 兩行:login=host/…、api_key=…;0640 root:opmenu(操作員群組可讀、不可改)
# ccp:AppID 以 client 憑證 + 來源 IP 驗身分
d OPMENU_CCP_URL         'https://ccp.example.com/AIMWebService/api/Accounts'
d OPMENU_CCP_APPID       opmenu
d OPMENU_CCP_SAFE        Confluent
d OPMENU_CCP_CERT        '/etc/opmenu/ssl/opmenu-ccp.crt'
d OPMENU_CCP_KEY         '/etc/opmenu/ssl/opmenu-ccp.key'

# ── 規範(依客戶的命名規定調整)──
d OPMENU_TOPIC_PATTERN   '^[a-z][a-z0-9]+\.[a-z0-9.-]+$'                # topic 命名:<系統>.<名稱>
d OPMENU_SVC_PATTERN     '^[a-z][a-z0-9-]+$'                            # service account:例 app-orders
d OPMENU_SVC_PAIR        '-a -b'                                         # 34／35／37：一個應用程式兩個帳號（<名稱>-a、<名稱>-b，權限相同），輪替密碼時換「沒在用的那個」，不中斷
d OPMENU_HANDOVER_DIR    "$HOME/opmenu-handover"                       # 新密碼交接檔放哪（操作者自己的家目錄，0700／0600）；存進 PVWA 後刪掉
d OPMENU_REPLICATION     3                                              # 建 topic 的 replication factor(標準值);沒填且 broker 少於 3 台時,登入後自動降到 broker 數
d OPMENU_EMERGENCY_TOOLS 'kafka-topics kafka-configs kafka-consumer-groups kafka-acls kafka-metadata-quorum'   # 91 允許的工具
d OPMENU_AUDIT_TOPIC     confluent-audit-log-events                     # 43 匯出的 audit topic
d OPMENU_AUDIT_GROUP_PREFIX 'audit-'                                     # 43 讀 audit topic 用的 consumer group prefix(audit 群組要有這個 prefix 的 DeveloperRead)

# ── 安全(正式環境請維持預設)──
d OPMENU_PROTECTED_TOPIC_PATTERN '^(_|__|confluent-audit-log-events$|confluent-)'   # 受保護的 topic:內部、audit、平台用;32/33 等變更項目不處理
d OPMENU_GROUP_PATTERN   '^[A-Za-z0-9._-]{1,200}$'                      # consumer group 名稱允許的字元
d OPMENU_ROLES_ALLOWED   'DeveloperRead DeveloperWrite DeveloperManage ResourceOwner Operator ClusterAdmin'   # 42 可指派的 role(SystemAdmin、UserAdmin、SecurityAdmin 不經選單)
d OPMENU_EMERGENCY_ACTIONS 'kafka-topics=--list,--describe,--create,--alter,--delete kafka-configs=--describe,--alter kafka-consumer-groups=--list,--describe,--reset-offsets kafka-acls=--list kafka-metadata-quorum=describe'   # 91 每個工具允許的動作
d OPMENU_ALLOW_ENV_OVERRIDE 0        # 1 = 接受 OPMENU_USER/PASS/YES/REASON 等環境變數(只給自動化測試用);正式環境 0
d OPMENU_SYSLOG          1           # 1 = 每筆紀錄同時送 syslog(logger -t opmenu),集中保存、操作員無法改
d OPMENU_TMPDIR          "$(_t=$(mktemp -p /dev/shm 2>/dev/null) && { rm -f "$_t"; echo /dev/shm; } || echo "${TMPDIR:-/tmp}")"   # 暫存連線檔放記憶體檔案系統;真的能在 /dev/shm 建檔才用(Git Bash 有這個路徑但不能用)
d OPMENU_HOST_ACTION_AUTHZ 'Topic:__opmenu-host-ops:Describe'   # 主機類動作(重啟、日誌、磁碟、診斷)前向 MDS 確認的權限 <資源類型>:<名稱>:<操作>;預設等於「叢集層級可 describe 所有 topic」(Operator 以上),只有個別 topic 權限的人會被拒。主機用共用的 cpadmin,所以一定要檢查;空 = 不檢查
d OPMENU_EMERGENCY_GROUP 'opmenu-emergency'   # MDS 連不上時（AD 登入做不了），這個作業系統群組的人可以進「緊急主機模式」；平常群組裡沒人，事故時由 OS 團隊臨時加入。空 = 關閉
d OPMENU_EMERGENCY_ITEMS '16 18 21 22 23'     # 緊急主機模式只開放這些項目（磁碟、收集診斷、重啟 broker、重啟 REST／C3、看日誌）；Kafka 類項目都要 AD 身分，不開放
d OPMENU_TOKEN_TTL       3600       # MDS token 壽命(秒,依 MDS 設定);超過後遇到 401 會提示重新登入而不是密碼錯
# ── 動態選單:登入後用本人的 token 一次問 MDS,只顯示有權限的項目;MDS 會展開 AD 群組,所以「依 AD 群組不同」
# 而且只有 RBAC 一份設定。只影響「看得到什麼」:執行時 Kafka / MDS / 主機閘門照樣檢查,直接輸入隱藏的編號一樣會被擋。
d OPMENU_MENU_FILTER     1           # 1 = 依權限顯示;0 = 全部顯示
d OPMENU_ADMIN_AUTHZ     'Cluster:kafka-cluster:Alter'               # ADMIN:變更、權限管理、緊急模式(SystemAdmin / ClusterAdmin 才有)
d OPMENU_AUDIT_AUTHZ     'Topic:confluent-audit-log-events:Read'     # AUDIT:匯出、查詢 audit 紀錄
# 每個項目要什麼權限:<編號或第幾層*>=<HOST | ADMIN | AUDIT | - | 資源類型:名稱:操作>;沒列到的 = 不限制(查看類,Kafka 只回你看得到的)。
# HOST = OPMENU_HOST_ACTION_AUTHZ(碰主機:重啟、日誌、磁碟、診斷)。後面的設定覆蓋前面的(例 "3*=ADMIN 31=-")。
d OPMENU_MENU_AUTHZ      '16=HOST 18=HOST 2*=HOST 3*=ADMIN 41=ADMIN 42=ADMIN 43=AUDIT 44=ADMIN 45=AUDIT 91=ADMIN'

# ── 變更類項目的並行鎖與時窗 ──
d OPMENU_LOCK_DIR        "$OPMENU_OUT_DIR/opmenu.lock.d"                # 並行鎖:同一時間只允許一個人做變更類項目(只在同一台操作機有效;所在目錄要讓所有操作員可寫、不能有 sticky bit)
d OPMENU_LOCK_WAIT       0                                              # 拿不到鎖時最多等幾秒;0 = 直接拒絕
d OPMENU_CHANGE_WINDOW   ''                                             # 變更時窗,空 = 不限制。格式 "Mon-Fri 22:00-06:00;Sat,Sun 00:00-23:59"(跨午夜的算起始那天);分號分隔多段
d OPMENU_WINDOW_EXEMPT   '91'                                           # 不受時窗限制的項目(緊急模式)
d OPMENU_ROLLING_TIMEOUT 600                                            # 27 滾動重啟:每台重啟後最多等幾秒回到叢集且 under-replicated 回到 0
d OPMENU_REVIEW_ROLES    'SystemAdmin ClusterAdmin SecurityAdmin UserAdmin AuditAdmin ResourceOwner Operator DeveloperManage DeveloperWrite DeveloperRead'   # 44 權限覆核匯出要列的 role
d OPMENU_ROLLING_SETTLE  45                                             # 27 滾動重啟:每台重啟後先等幾秒才開始判斷(要超過 broker 被判定離線、ISR 縮減的時間,預設分別約 9 秒、30 秒;不等的話剛重啟時會誤判成健康)
d OPMENU_ROLLING_STABLE  2                                              # 27 滾動重啟:連續幾次檢查都健康才換下一台
if [ -z "${OPMENU_BREAKGLASS_BOOTSTRAP:-}" ]; then   # 由 bootstrap 的主機推算 TOKEN listener 位址
  _b=""; for _h in $(_hosts_of ${OPMENU_BOOTSTRAP//,/ }); do _b+="$_h:$OPMENU_TOKEN_PORT,"; done
  dd OPMENU_BREAKGLASS_BOOTSTRAP "${_b%,}"; unset _b _h
fi
