// Content of the manual overview deck (guide.js renders it). Chapters of docs/journey-src/journey.md, no commands.
//   diagram slide: { ch, title, diagram, blocks: [[label, text], …], notes }  the layout follows the diagram's shape
//   native slide:  { ch, title, flow: [[head, sub, icon], …], blocks } or { ch, title, table, blocks } or { ch, title, tiles, blocks }
const PARTS = {
  intro: { name: "開場", color: "1B6CA8" },
  install: { name: "安裝篇", color: "1B6CA8" },
  ops: { name: "維運篇", color: "2E7D32" },
  migrate: { name: "升級遷移篇", color: "C96A00" },
  close: { name: "收尾", color: "B3261E" },
};

const INTRO = [
  { ch: "第 1 章", title: "銀行各團隊備環境，我方只裝平台", diagram: "cast", blocks: [
    ["在做什麼", "環境完全離線；主機、帳號、AD、憑證由銀行各團隊準備，我方裝好 Confluent、設好安全並確認健康。"],
    ["手冊怎麼標", "每一步都標明誰做、在哪台機器；銀行的事只確認結果，不代做。"],
  ], notes: "手冊第 1.1 節。" },
  { ch: "第 1 章", title: "環境地圖：只有下載機能連外網", diagram: "map", blocks: [
    ["外網", "下載機是唯一能連 Internet 的機器，檔案要先驗證再送進內網。"],
    ["操作機", "安裝與維運的起點，也是維運人員登入的地方；沒有另外的堡壘機。"],
    ["平台主機", "controller 3 台、broker 4 台、REST Proxy 2 台、Control Center 1 台。"],
  ], notes: "手冊第 1.2 節。" },
  { ch: "第 1 章", title: "主線是先裝基底，再遷移到目標版本", diagram: "versionpath", blocks: [
    ["基底", "第 2–19 章：CP 8.2.4、C3 2.5.1、JDK 21、OS 9.6。"],
    ["目標", "第 29–31 章：CP 8.3.2、C3 2.6.1、JDK 25、OS 9.8。"],
    ["為什麼", "8.2 不支援 JDK 25，基底只能用 21；C3 2.5 只支援到 CP 8.2，所以 C3 要先升。"],
  ], notes: "手冊第 1.4 節的版本路徑。8.3 支援 JDK 25，但原廠建議版本仍是 21。" },
  { ch: "第 1 章", title: "安裝旅程總覽", diagram: "journey", blocks: [
    ["基本安裝", "第 2–14 章：平台能用。"],
    ["交付前", "第 15–19 章：密碼加密、選單、監控、稽核、驗收。"],
    ["怎麼讀", "每章開頭說要做什麼，結尾說看到什麼代表成功。"],
  ], notes: "手冊第 1.3 節。" },
];

const INSTALL = [
  { ch: "第 2 章", title: "在外網把檔案抓齊、驗過簽章", diagram: "download", blocks: [
    ["在做什麼", "一次抓基底與目標兩套版本、監控元件，驗原廠簽章後產生雜湊清單。"],
    ["誰負責", "我方。JDK 和 OS 套件是銀行的事，不在這裡下載。"],
    ["完成的樣子", "一批可送進內網的檔案；遷移時不必再開一次單。"],
  ], notes: "主機都離線，缺檔案只能回到這一章補。" },
  { ch: "第 3 章", title: "送進內網要過三道關", diagram: "intake", blocks: [
    ["在做什麼", "資安掃描 → 檔案交換 → 進內網後我方用雜湊清單再驗一次。"],
    ["誰負責", "前兩關是銀行資安與檔案交換，最後一關是我方。"],
    ["完成的樣子", "操作機的落地區成為之後所有安裝的唯一來源。"],
  ], notes: "落地區進內網後設為唯讀。" },
  { ch: "第 4 章", title: "人與主機的存取分開設計", diagram: "access", blocks: [
    ["人", "經 CyberArk 的 PVWA 與 PSMP 登入操作機，進去是 root。"],
    ["機器", "操作機用一把金鑰以 cpuser 連各主機；公鑰限定來源，只有操作機能用。"],
    ["私鑰", "放獨立加密的 file system，不放 CyberArk、不備份；操作機重建就換一組。"],
  ], notes: "這是平台和 CyberArk 唯一的關係。OS 團隊建 cpuser 與佈署公鑰，我方產生金鑰對並驗證。" },
  { ch: "第 5 章", title: "安裝前，銀行要先備好這些", diagram: "bankprep", blocks: [
    ["在做什麼", "OS 套件庫與根憑證、JDK 21 與 25、AD 與 LDAPS、NTP、負載平衡。"],
    ["誰負責", "全部是銀行各團隊；我方只確認結果。"],
    ["風險", "哪一項沒給，後面就會卡在那裡；虛擬機與磁碟的建議要在開單時交代。"],
  ], notes: "lab 裡由我方扮演銀行。" },
  { ch: "第 6 章", title: "把 Confluent 套件上架到行內套件庫", flow: [
    ["落地區", "已驗過的 RPM", "LuFolderCheck"], ["建索引", "在操作機做成套件庫", "LuListTree"], ["上架", "推到套件庫主機", "LuUpload"], ["各主機安裝", "11 台都從這裡裝", "LuServer"],
  ], blocks: [
    ["為什麼在操作機建索引", "銀行的套件庫主機只有 web server，沒有建索引的工具，所以建好後連同 RPM 一起推上去。"],
    ["這時只放基底", "遷移目標的套件到第 29 章才上架。"],
  ], notes: "手冊第 6 章。" },
  { ch: "第 7 章", title: "主機準備：JDK、安裝前檢查、OS 調校", diagram: "hostfiles", blocks: [
    ["JDK", "銀行交付的 tar 裝到固定目錄，並設定給系統與服務使用。"],
    ["檢查", "DNS、套件庫、AD、時間都要通；只讀、不改東西。"],
    ["調校", "依原廠建議調 OS 參數。三節要照順序做。"],
  ], notes: "圖是這一章之後各主機會有的檔案。檢查用得到 JDK 與套件庫，所以順序不能換。" },
  { ch: "第 8 章", title: "每台只裝自己角色的套件，並鎖定版本", table: {
    head: ["主機", "安裝的元件"],
    rows: [
      ["controller、broker", "Confluent Server、安全元件"],
      ["操作機", "同上，再加 Confluent CLI"],
      ["REST Proxy", "REST Proxy、安全元件"],
      ["Control Center", "Control Center，以及兩個 OS 前置套件"],
    ],
    widths: [0.3, 0.7],
  }, blocks: [
    ["為什麼要鎖版本", "OS 例行更新不會把 Confluent 升掉。"],
    ["只鎖 Confluent 和 JDK", "C3 的兩個 OS 前置套件跟著 OS 修補走，不鎖。"],
  ], notes: "鎖定在第 29 章遷移時逐台解開、換完再鎖回。" },
  { ch: "第 9 章", title: "所有內部連線都加密，並用憑證識別身分", diagram: "certs", blocks: [
    ["在做什麼", "我方產生私鑰與 CSR，銀行 CA 簽發，收回後逐張檢查再做成 keystore。"],
    ["原則", "私鑰不離開行內。"],
    ["完成的樣子", "7 張憑證，效期一年；第 10–13 章的 TLS 都用這裡的產出。"],
  ], notes: "憑證到期前的換發在第 21 章，提前知道到期在第 22 章。" },
  { ch: "第 9 章", title: "信任鏈：每個元件都驗得過銀行的根憑證", diagram: "trust", blocks: [
    ["為什麼重要", "簽回來的憑證要先驗鏈與用途，錯一張，後面服務就起不來。"],
    ["兩種信任", "OS 的信任清單給系統工具用，Java 的 truststore 給 Confluent 用。"],
  ], notes: "手冊 9.3。" },
  { ch: "第 10 章", title: "叢集第一次跑起來：先 controller，再 broker", diagram: "startup", blocks: [
    ["順序", "派送憑證 → 設定檔 → systemd → 格式化儲存 → 啟動。"],
    ["關鍵檢查", "每段確認健康才做下一段；啟動前先確認服務讀的是我們的設定檔。"],
    ["完成的樣子", "controller 3 台、broker 4 台運作，MDS 正常。"],
  ], notes: "曾經發生服務讀到 RPM 預設設定而啟動，所以要先確認。" },
  { ch: "第 10 章", title: "KRaft：三台 controller 管理中繼資料", diagram: "kraft", blocks: [
    ["在做什麼", "以動態 quorum 建立 controller，broker 向它們註冊。"],
    ["看什麼", "quorum 有 leader、每個成員都追得上。"],
    ["之後用到", "第 25 章換 controller、第 29 章升級都依賴這個結構。"],
  ], notes: "手冊 10.4。" },
  { ch: "第 11 章", title: "誰能做什麼：每種身分怎麼連進來", diagram: "identity", blocks: [
    ["人", "用 AD 帳號；權限綁 AD 群組，不綁個人。"],
    ["應用程式", "直連用 SCRAM，經 REST Proxy 一律用 client 憑證。"],
    ["平台服務", "用憑證向 MDS 換 token，不用 AD。"],
    ["緊急帳號", "kafka-admin 用 SCRAM，AD、MDS 不通時仍可用。"],
  ], notes: "super.users 只有 kafka-internal；svc-ops、kafka-admin 都靠 RBAC 綁 SystemAdmin。" },
  { ch: "第 11 章", title: "管理身分用憑證換 token，再進叢集", diagram: "tokenflow", blocks: [
    ["在做什麼", "服務以憑證向 MDS 換 token，再連 TOKEN listener。"],
    ["好處", "不需要 super user，動作都受 RBAC 控管，稽核也記得到明確的身分。"],
  ], notes: "手冊第 11 章。" },
  { ch: "第 11 章", title: "權限從 AD 群組一路接到 Kafka 資源", diagram: "rbac", blocks: [
    ["怎麼授權", "每台 broker 依內部 topic 的 binding 自己判斷。"],
    ["群組的限制", "不支援巢狀群組，KAFKA_* 群組要直接放人；只認使用者 OU 底下的帳號。"],
    ["演練過", "AD 不通時人員登不進來，但緊急帳號仍可用。"],
  ], notes: "手冊 11.2 的 AD 斷線演練：MDS 或 AD 不通都不影響授權判斷。群組的限制見第 10 章，子群組的成員登得進來但沒有權限，也沒有錯誤訊息。" },
  { ch: "第 12 章", title: "REST Proxy：只收憑證，前面由 LB 分流", diagram: "edge", blocks: [
    ["在做什麼", "兩台 REST Proxy，讓不方便直連的應用程式用 HTTP 存取 Kafka。"],
    ["安全", "沒有密碼登入；只放行白名單上的憑證，其他回 401。"],
    ["重啟規則", "每次重啟前先請 LB 團隊停用那一台，連線排空才動。"],
  ], notes: "完成的樣子：帶正確憑證經 LB 回 200，其他憑證 401，不帶憑證被 TLS 拒絕。" },
  { ch: "第 13 章", title: "Control Center：畫面用它，告警不用它", diagram: "c3roles", blocks: [
    ["在做什麼", "維運人員用 AD 帳號登入網頁看叢集狀況。"],
    ["界線", "內建的 Prometheus 與 Alertmanager 只給 C3 畫面用；告警走銀行的監控。銀行沒有 Prometheus 時的例外見第 32 章。"],
    ["憑證", "C3 全部用自己的憑證（svc-c3），同時當伺服器與 client；連 MDS 的健康檢查也靠它。"],
    ["完成的樣子", "可以用 AD 帳號從 C3 登入，畫面有資料。"],
  ], notes: "不在 C3 畫面建 alert trigger 或 action，理由見第 17 章。驗收要帶身分登入，不能只看首頁：C3 連不上 MDS 時首頁照樣回 200。" },
  { ch: "第 14 章", title: "基本功能驗收：平台能用，但還不能交付", tiles: [
    ["7 台", "confluent-server 都在運作", "LuServer"],
    ["有 leader", "KRaft quorum 正常", "LuCrown"],
    ["4 台", "MDS 都回應正常", "LuShieldCheck"],
    ["經 LB", "REST Proxy 與 C3 都回應正常", "LuNetwork"],
  ], blocks: [
    ["同時給三張查詢表", "出問題先看哪裡、做錯了怎麼重來、前人踩過的坑。"],
    ["接下來", "交付前還要做第 15–18 章，最後跑第 19 章驗收。"],
  ], notes: "license 排程（26.2）與每日備份（第 23 章）也列為交付前要做。" },
  { ch: "第 15 章", title: "設定檔不留明文密碼", diagram: "keyhier", blocks: [
    ["在做什麼", "用 Secret Protection 加密，設定檔裡只留參照，密文另外存放。"],
    ["金鑰放哪", "master key 只放操作機與各主機 root 才讀得到的位置，不放 CyberArk。"],
    ["影響", "要滾動重啟所有服務，請在變更時段做。"],
  ], notes: "手冊 15.6 有要跟資安說清楚的事。" },
  { ch: "第 16 章", title: "OP menu：維運人員用自己的 AD 帳號操作", diagram: "opmenu", blocks: [
    ["在做什麼", "文字選單涵蓋看狀態、重啟、看日誌、建 topic、查權限，不用記指令。"],
    ["權限", "沒權限的動作會被 Kafka／MDS 拒絕，紀錄和稽核記的都是本人。"],
    ["緊急", "以 svc-ops 憑證執行，必填原因，記為 EMERGENCY。"],
  ], notes: "手冊第 16 章。" },
  { ch: "第 16 章", title: "一次操作：從登入到留下紀錄", diagram: "opmenuflow", blocks: [
    ["碰主機", "以 cpuser 連線，sudo 只放行逐一列出的動作。"],
    ["誠實的限制", "操作者是 root，碰主機前的權限檢查是流程控管，不是硬性隔離；追溯靠 PSMP 錄影。"],
    ["繞不過的", "Kafka 類動作的權限與稽核由 Kafka 端強制。"],
  ], notes: "這一點要讓資安知道。" },
  { ch: "第 17 章", title: "監控交給銀行的系統，我方交付設定", diagram: "jmx", blocks: [
    ["在做什麼", "每個 Java 程序掛 JMX exporter，由銀行的 Prometheus 抓指標。"],
    ["交付", "exporter 規則、告警規則、Alertmanager 與 Grafana 設定、官方 dashboard。"],
    ["完成的樣子", "10 個 target 都 up、規則載入、32 個 dashboard。"],
  ], notes: "指標端點只用 HTTPS，存取控制靠網路，要銀行限制來源位址。" },
  { ch: "第 17 章", title: "告警從指標一路走到銀行的通知", diagram: "alertpath", blocks: [
    ["為什麼不用 C3 的告警", "C3 會重寫設定、webhook 內容不能自訂，看到的指標也有限；這些在 lab 實測過。"],
    ["驗證", "實際觸發告警，確認兩種 webhook 格式都送達，也確認解除通知。"],
  ], notes: "手冊 17.8。" },
  { ch: "第 18 章", title: "稽核日誌：誰對什麼做了什麼", diagram: "audit", blocks: [
    ["銀行要的", "用專用低權限帳號寫入、敏感 topic 分開放並留久一點、排除平台雜訊。"],
    ["內容", "身分、對象、動作、准或拒，每一筆都是事件，寫進 Kafka 的 topic。"],
    ["影響", "要滾動重啟 controller 與 broker。"],
  ], notes: "哪些 topic 算敏感由銀行決定；lab 的 payments.* 只是例子。" },
  { ch: "第 19 章", title: "交付前的驗收，結果可以附進驗收文件", diagram: "acceptance", blocks: [
    ["四組", "平台健康、安全（正向與反向都測）、應用程式端、維運。"],
    ["標準", "每一組都全數通過；重啟與冷開機要自己恢復。"],
    ["不只跑一次", "基底跑一次，遷移每一段與 OS 更新後都再跑。"],
  ], notes: "最後是收尾：安裝期間留下的東西，哪些要留、哪些要收，例如 cpuser 的 sudo 收窄。" },
];

const OPS = [
  { ch: "第 20 章", title: "所有密碼與金鑰：什麼、多久、誰換", table: {
    head: ["項目", "多久換", "誰做"],
    rows: [
      ["緊急帳號 kafka-admin 的密碼", "每次用過就換", "平台工程師"],
      ["master key 與 passphrase", "每年（待銀行確認）；疑似外洩時", "平台工程師"],
      ["AD 查詢帳號的密碼", "依 AD 規範；換前要通知平台", "AD 團隊換、平台更新密文"],
      ["操作機的 SSH 金鑰", "每年（待銀行確認）；操作機重建時", "平台工程師＋OS 團隊"],
      ["應用程式的 SCRAM 密碼", "依應用程式團隊", "維運選單（A／B 帳號）"],
      ["服務與 client 憑證", "一年（第 21 章）", "平台工程師＋CA"],
      ["MDS token 金鑰", "不排輪替，只在外洩時換", "平台工程師"],
    ],
    widths: [0.36, 0.36, 0.28],
  }, notes: "手冊 20.1。每一節都在 lab 實跑過，正式環境依變更單執行。" },
  { ch: "第 20 章", title: "應用程式換密碼不中斷：A／B 兩個帳號", diagram: "scramab", blocks: [
    ["做法", "每個應用程式有兩個同權限帳號，只換現在沒在用的那個，再請應用程式切過去。"],
    ["誰做", "維運人員用 OP menu；手冊的手動步驟就是選單背後做的事。"],
  ], notes: "手冊 20.6。" },
  { ch: "第 21 章", title: "憑證輪替：先判斷是哪一種換法", diagram: "certrotate", blocks: [
    ["每年", "同一個 CA 重簽 leaf；每次都產生新私鑰。"],
    ["換 CA", "三階段：先加新根 → 換 leaf → 移除舊根。"],
    ["影響", "每次都要滾動重啟所有元件，一台健康了才做下一台。"],
  ], notes: "21.4 是中繼沒換私鑰時只換憑證鏈。MDS token 金鑰不是 CA 簽的，不在這一章。" },
  { ch: "第 22 章", title: "憑證到期前就要知道", diagram: "certexpiry", blocks: [
    ["為什麼", "到期那一刻 broker 之間、REST、C3、應用程式全部連不上。"],
    ["兩層", "銀行 Prometheus 探端點，60 天 warning、14 天 critical；操作機每天讀我方持有的每一張。"],
    ["待銀行", "目前沒有 blackbox_exporter，第一層列為建議。"],
  ], notes: "這章是選配；第二層與 OP menu 17 沒有前提。" },
  { ch: "第 23 章", title: "每天備份設定類中繼資料，訊息本身不備份", diagram: "backup", blocks: [
    ["備什麼", "權限、topic、設定等，每天匯出成文字檔，用專用唯讀身分。"],
    ["訊息", "叢集內靠三份副本；異地備援依銀行的 RPO／RTO 另議。"],
  ], notes: "每天凌晨 2 點，結果寫 syslog；OP menu 44 的快照格式和它相同。" },
  { ch: "第 23 章", title: "還原演練：誤刪的東西照備份重建", diagram: "restore", blocks: [
    ["演練內容", "topic、權限、帳號誤刪後，從備份重建，再寫讀一筆確認。"],
    ["比對", "備份之間可以比對出哪裡變了，變更前後也用得到。"],
  ], notes: "手冊 23.5、23.6。" },
  { ch: "第 24 章", title: "資料盤是平台裡唯一會自己長大的東西", diagram: "disk", blocks: [
    ["順序", "看用量 → 告警 → 快滿時先爭取空間，再處理根因 → 擴容與換碟。"],
    ["不要做", "手動刪資料目錄底下的檔；也不要停 broker 來省空間。"],
  ], notes: "lab 用示範 topic 實際做過：縮短 retention、搬 partition。" },
  { ch: "第 25 章", title: "換掉一台 controller，服務不中斷", diagram: "controllerswap", blocks: [
    ["做法", "移出舊成員 → 清空重建 → 以觀察者追上 → 再加回 quorum。"],
    ["規則", "一次一台；應用程式不用改設定。"],
  ], notes: "手冊 25.1。" },
  { ch: "第 25 章", title: "broker 縮減與擴充，資料自動搬移", diagram: "brokerscale", blocks: [
    ["縮減", "由 Self-Balancing 搬走資料，再移除那一台。"],
    ["擴充", "新節點空的啟動，Self-Balancing 自動搬回來。"],
  ], notes: "永久縮減後，相關設定要跟著改。手冊 25.2。" },
  { ch: "第 26 章", title: "license 到期不會立刻停，但下次重啟就停擺", flow: [
    ["讀出到期日", "原廠沒有提供 JMX 指標，要自己讀", "LuSearch"], ["每天檢查", "寫進 syslog 給監控接", "LuCalendarCheck"], ["換上正式 license", "lab 沒有正式 license，未實測", "LuBadgeCheck"],
  ], blocks: [
    ["到期的影響", "broker 繼續服務、日誌報錯；但重啟時 RBAC、MDS 與 C3 起不來。"],
    ["試用期", "30 天；正式 license 一般一年一約。"],
  ], notes: "原廠只在 C3 畫面與 broker 日誌提醒。" },
  { ch: "第 26 章", title: "測試環境試用到期：申請延長或重置叢集", diagram: "clusterreset", blocks: [
    ["先做", "申請延長；重置要先取得原廠同意。"],
    ["重置的結果", "訊息歸零、換新 cluster id；帳號、權限、topic 從備份建回來。"],
    ["只限", "測試或評估環境。"],
  ], notes: "手冊 26.4，已在 lab 實跑並驗收。" },
  { ch: "第 27 章", title: "新應用上線：從申請到下線都走同一條路", diagram: "onboard", blocks: [
    ["步驟", "申請單 → topic → 身分、權限、配額 → 交付 → 驗證 → 將來下線。"],
    ["兩種應用", "直連用 SCRAM，走 REST 用憑證並要加進白名單。"],
    ["誰做", "日常由維運人員用 OP menu。"],
  ], notes: "lab 用兩個假系統各走過一遍。" },
  { ch: "第 28 章", title: "出事時的走法：先快照，再依症狀分支", diagram: "triage", blocks: [
    ["先做", "一分鐘快照看全貌，再看那一台。"],
    ["工具", "症狀對照表、常見錯誤訊息、找原廠時要帶的 diagnostics。"],
    ["演練過", "停一台 broker：症狀、告警、恢復都走過。"],
  ], notes: "安裝期的版本在 14.1，這裡是上線後。" },
  { ch: "第 28 章", title: "MDS 不能用時，還有備用路徑", diagram: "mdsdown", blocks: [
    ["選單", "進入緊急主機模式，只開放主機類項目。"],
    ["Kafka 類操作", "改用緊急帳號 kafka-admin。"],
    ["事後", "換緊急帳號的密碼，並對稽核紀錄結案。"],
  ], notes: "手冊 28.6，已演練。" },
];

const MIGRATE = [
  { ch: "第 29 章", title: "遷移分三段，只有最後一段不能退", diagram: "upgrade", blocks: [
    ["第一段", "C3 先升 → broker → controller（leader 最後）→ REST、操作機。"],
    ["第二段", "全部 Java 節點 JDK 21 換 25。"],
    ["第三段", "finalize：做了就不能退回 8.2。"],
  ], notes: "8.3 的原廠建議版本仍是 JDK 21，選 25 要和原廠支援確認；銀行沒要求時可以留在 21，只做第一、三段。" },
  { ch: "第 29 章", title: "每一步的先後，與不能回頭的那條線", diagram: "migrationflow", blocks: [
    ["回滾", "finalize 之前都能退：先把 JDK 切回 21，再退套件；手冊有 kb04 的演練。"],
    ["每段之後", "跑第 19 章驗收，全部通過才繼續。"],
    ["上架", "目標版本到這時才進套件庫。"],
  ], notes: "手冊 29.1–29.10。" },
  { ch: "第 30 章", title: "OS 修補：一台一台修，健康了才做下一台", diagram: "ospatch", blocks: [
    ["順序", "broker → controller（leader 最後）→ REST、C3、操作機。"],
    ["為什麼安全", "Confluent 鎖版本、JDK 是 tar，更新只動 OS 套件。"],
    ["兩種情境", "每月修補和小版本更新（9.6 → 9.8）步驟相同。"],
  ], notes: "lab 的主機是容器，不能真的重開機，改重啟平台服務。" },
  { ch: "第 31 章", title: "單獨更換 Control Center，不動平台", flow: [
    ["下載驗簽", "外網下載機", "LuDownload"], ["引進上架", "送進內網、進套件庫", "LuUpload"], ["回滾演練", "lab 專用：退回前一版", "LuUndo2"], ["升級", "換到新版並確認", "LuCircleCheck"],
  ], blocks: [
    ["什麼時候用", "C3 的版號獨立，改版比平台頻繁；出修補版或原廠要求時單獨處理。"],
    ["正式環境", "把版號換成新版，跳過回滾演練。"],
  ], notes: "手冊第 31 章。" },
  { ch: "第 32 章", title: "沒有行內 Prometheus 時的 REST Proxy 告警", diagram: "c3alert", blocks: [
    ["在做什麼", "C3 內建的 Prometheus 多抓 REST Proxy 的指標，我們的規則加上標籤，只送到另一台 Alertmanager，再發行內 omnibus 的 JSON。"],
    ["不會誤發", "C3 畫面建的 trigger 沒有這個標籤，只會到內建那台，不會進 omnibus。"],
    ["前提", "C3 升到 2.6.1 之後才做；2.5.1 附的 Alertmanager 會把字串欄位改成物件或數字。"],
  ], notes: "銀行有 Prometheus 時走第 17 章；兩章可以並存。lab 實測停一台 REST Proxy 有 OPEN 與 RESOLVED，10 個欄位都是字串。" },
];

const CLOSING = { ch: "手冊現況", title: "手冊的驗證狀態與 lab 驗不到的部分", tiles: [
  ["34 章", "第 0–32 章與附錄 B 都在 lab 實跑過", "LuListChecks"],
  ["手動優先", "手冊教手動步驟，腳本走同一條路", "LuRoute"],
  ["待銀行", "換金鑰週期、master key 週期等待確認", "LuMessageCircleQuestion"],
], blocks: [
  ["lab 無法模擬", "CyberArk 的 PVWA／PSMP、加密 file system（LUKS）、OS 真正重開機與 kernel 更新。"],
  ["未實測", "換上正式 license（lab 沒有正式 license）；lab 的主機是 Rocky 9，不是 RHEL。"],
], notes: "第 0 章是建 lab，只有練習需要；附錄 B 是監控覆蓋率，給銀行監控團隊參考。" };

// the contents table on slide 3
const CONTENTS = [
  { part: "install", range: "第 2–19 章", desc: "從下載套件到交付驗收", items: "2 外網下載、3 送進銀行、4 主機存取、5 銀行準備、6 上架套件庫、7 主機準備、8 安裝套件、9 憑證、10 controller 與 broker、11 帳號與權限、12 REST Proxy、13 Control Center、14 基本驗收、15 Secret Protection、16 OP menu、17 監控、18 稽核日誌、19 驗收與收尾" },
  { part: "ops", range: "第 20–28 章", desc: "上線後的例行與異常處理", items: "20 密碼與金鑰輪替、21 憑證輪替、22 憑證到期監控、23 備份與還原、24 磁碟與容量、25 節點更換與增減、26 license、27 新應用上線、28 故障排查" },
  { part: "migrate", range: "第 29–32 章", desc: "基底升到目標版本；C3 2.6.1 之後的告警", items: "29 遷移 Confluent 與 JDK、30 OS 修補與小版本更新、31 單獨更換 C3、32 銀行沒有 Prometheus 時的 REST Proxy 告警" },
];

// Commands inside the manual's diagrams, reworded for this deck (the manual's own diagrams stay as they are).
const REWORD = {
  download: [["rpm --import", "匯入原廠公鑰"], ["dnf download --resolve", "下載套件與相依"], ["rpm -K 驗簽章", "驗原廠簽章"]],
  intake: [["rpm -K", "驗簽章"], ["建索引 createrepo_c", "建套件庫索引"], ["ssh + tar 推給 repodeploy", "推到套件庫主機"]],
  startup: [["啟動前先看 systemctl show -p ExecStart 指向我們的設定檔", "啟動前先確認服務讀的是我們的設定檔"]],
  opmenu: [["ssh cpuser@主機", "以 cpuser 連主機"], ["sudo 逐一列出可用的指令", "sudo 只放行逐一列出的動作"]],
  upgrade: [["kafka-features upgrade", "升級 metadata 版本"], ["--release-version 4.3", "（目標 4.3）"], ["dnf downgrade 回 8.2.4", "套件退回 8.2.4"], ["daemon-reload → 重啟", "重新載入 → 重啟"]],
  access: [["ssh cpuser@主機", "以 cpuser 連主機"]],
  kraft: [["describe --replication 第 4 欄", "查 quorum 的複寫狀態"]],
  opmenuflow: [["執行 /opt/opmenu/opmenu.sh", "啟動選單"], ["用 /secure/ssh 的金鑰 ssh cpuser", "用同一把金鑰以 cpuser 連主機"], ["restart、status、journalctl -n 200", "重啟、看狀態、看日誌"]],
  migrationflow: [["dnf downgrade 回 8.2.4", "套件退回 8.2.4"], ["kafka-features upgrade", "升級 metadata 版本"], ["--release-version 4.3", "（目標 4.3）"]],
  controllerswap: [["--no-initial-", "以觀察者"], [">controllers<", ">格式化<"]],
  c3alert: [["job: rest-proxy；prometheus-generated.yml", "多抓 REST Proxy 的指標"], ["custom-rules-rest.yml", "我方的告警規則"], ["trigger_rules-", "C3 畫面建的"], [">generated.yml<", "><"], ["alert_relabel_configs", "依標籤分流"], ["127.0.0.1:9193，C3 內附 0.34.0", "C3 內附的另一份"]],
  brokerscale: [["kafka-remove-brokers", "由 Self-Balancing 搬走"], ["--delete --broker-id 104", "（以 kb04 為例）"], ["--no-initial-controllers", "以觀察者格式化"]],
  backup: [["metadata-backup.sh", "每日匯出"]],
  ospatch: [["不要靠 dnf history undo", "不要靠套件回退"], ["dnf update 只動", "更新只動"], ["dnf update", "更新 OS 套件"], ["--refresh", "（重讀索引）"], ["正式：systemctl reboot", "正式：重開機"], [">needs-restarting<", ">判斷影響範圍<"], ["-r：要不要重開機", "要不要重開機"], ["-s：哪些服務要重啟", "哪些服務要重啟"]],
  restore: [["kafka-topics --create", "重建 topic"], ["--partitions／--replication-factor", "partition 數與副本數照備份"], ["kafka-configs --alter --add-config", "把設定寫回去"], ["iam rbac role-binding create", "建回 role binding"]],
  scramab: [["kafka-configs --alter", "改密碼"]],
  disk: [["kafka-log-dirs --describe", "查 log dir 用量"], ["kafka-configs 改 retention", "縮短 retention"], ["kafka-reassign-partitions", "搬移 partition"], ["手動 rm /var/lib/kafka/data 底下的檔", "手動刪資料目錄底下的檔"]],
  triage: [["systemctl is-active", "服務狀態"], ["journalctl 最後 20 行的 ERROR", "日誌最後的 ERROR"], ["單台 curl 8082", "單台直接測 8082"]],
  onboard: [["kafka-topics --create", "建 topic"], ["kafka-configs 配額", "設配額"]],
  certexpiry: [["cert-expiry.sh 讀", "讀"]],
  rbacmodel: [["（--schema-registry-cluster 等）", ""]],
};

module.exports = { PARTS, INTRO, INSTALL, OPS, MIGRATE, CLOSING, CONTENTS, REWORD };
