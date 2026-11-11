// Content of the chapter 32 proposal deck (c3alert.js renders it, guide-build.ps1 fills the company template).
// Priority on every slide: diagram first, then table, then text (at most three short cards; details go to the notes).
// Each diagram is followed by its real configuration (code) or table where there is one; the full rule file is the appendix.
//   diagram slide: { title, diagram, blocks: [[label, text], …], notes }   diagram ids: c3alert-diagrams.js, then the guide's diagrams.js
//   table slide:   { title, table: { head, widths, rows }, blocks, notes }
//   tiles slide:   { title, tiles: [[head, sub, icon], …], blocks, notes }
//   code slide:    { title, file, code, blocks, notes }  code on the left (monospace), cards on the right; full width without cards
const COLOR = "1B6CA8";
const RISK = "B3261E";

// One row per rule: name, what it watches, condition, source
const RULE_HEAD = ["規則", "在監控什麼", "條件", "出處"];
const RULE_WIDTHS = [0.35, 0.31, 0.19, 0.15];

const SLIDES = [
  { tag: "結論", title: "結論：沒有行內 Prometheus 也能完整告警", tiles: [
    ["做法", "C3 內建 Prometheus 抓 10 台的 JMX exporter，第二台 Alertmanager 發 omnibus", "LuWorkflow"],
    ["規則", "26 條：Confluent 官方建議（修正後）＋我方建議", "LuListChecks"],
    ["待確認", "原廠支援範圍；omnibus JSON 的欄位值；防火牆", "LuCircleHelp"],
  ], blocks: [
    ["涵蓋", "controller、broker、REST Proxy、C3，加上 JVM 與主機 CPU。"],
    ["前提", "C3 2.6.1 之後（2.5.1 內附的 Alertmanager 會改掉欄位型別），做完不退回 2.5.x。"],
  ], notes: "先講結論：可行、已在 lab 實測，剩外部確認事項。omnibus 的欄位值是照行內提供的範例（Dynatrace 用的格式）填的，欄位值請行內確認（請銀行確認的事項 11.5、11.11）。" },

  { tag: "背景", title: "兩條路徑，同一份規則", diagram: "paths", blocks: [
    ["行內的要求", "告警進 omnibus，固定欄位的扁平 JSON，每個欄位都是字串。"],
  ], notes: "請銀行確認的事項 11.11。銀行之後若提供 Prometheus，改走上面那條，同一個告警不要兩邊都送。" },

  { tag: "為什麼不直接用 C3", title: "C3 畫面的告警不符合行內格式", table: {
    head: ["做法", "問題", "依據"],
    widths: [0.26, 0.5, 0.24],
    rows: [
      ["C3 畫面建 trigger＋action", "action 只送 Alertmanager 預設格式，webhook 內容不能自訂", "lab 實測 2026-10-26"],
      ["改 C3 內建 Alertmanager 的設定", "C3 會重寫那份設定，重啟後手改的內容被蓋掉", "lab 實測 2026-10-26"],
      ["改 C3 產生的規則檔", "trigger_rules-generated.yml 由 C3 產生，手改會被蓋掉", "lab 實測 2026-11-09"],
      ["我們另外架一套 Prometheus", "多一套要維運、要備份、要升級的系統", "未採用"],
    ] }, blocks: [], notes: "結論：不碰 C3 自己寫的檔，只在我們擁有的檔加設定，再加一個獨立的 Alertmanager。" },

  { tag: "指標來源", title: "規則建在 JMX exporter，不建在 telemetry", diagram: "sources", blocks: [], notes: "lab 實測：raft 指標沒帶 node id、多台互撞被拒收；C3 2.6.1 的 prom-trigger-queries.yml 沒有 CPU 與 Storage 的查詢（文件有列）。JMX exporter 有主機 CPU，但沒有磁碟剩餘空間。" },

  { tag: "架構", title: "整體架構：抓 10 台、規則分流、送 omnibus", diagram: "c3alert", blocks: [
    ["要注意", "規則忘了帶 target 不會報錯，只是不會通知；所以由規則群組統一加。"],
  ], notes: "全部在 c3-01 上，不新增主機。第二個 Alertmanager 用 C3 套件內附的執行檔，不另外引進軟體。" },

  { tag: "前提：JMX exporter", title: "每台 Java 程序掛 JMX exporter，聽 7071", diagram: "exporter", blocks: [], notes: "jar 版本 1.7.0（GitHub release，sha256 與 GPG 核對過）。設定檔 root:confluent 0640。實際設定見附錄 A。" },

  { tag: "只留需要的指標", title: "每個 job 只留規則用得到的指標", diagram: "funnel", blocks: [], notes: "lab 數字；broker 的序列數會隨 topic、partition 數增加，但保留的只有規則用的那幾個指標。實際設定與每個 job 保留的指標見附錄 A。" },

  { tag: "指標在量什麼", title: "KRaft：叢集的大腦", diagram: "mkraft", blocks: [], notes: "controller 的指標來自 Confluent 官方 exporter 規則（kafka_controller.yml）。fenced broker：broker 停掉、沒有心跳或還沒追上 metadata 時，controller 會把它隔離，它就不能當 leader 或 follower。" },

  { tag: "指標在量什麼", title: "副本與 ISR：資料是否安全", diagram: "mreplica", blocks: [], notes: "ISR = 跟得上 leader 的副本。少一個是 under-replicated（還能寫）；少到低於 min.insync.replicas，acks=all 的寫入就會失敗。offline partition 與 unclean 選舉是 controller 回報的。" },

  { tag: "指標在量什麼", title: "一個寫入請求在 broker 裡走過哪裡", diagram: "mrequest", blocks: [], notes: "network threads 與 request handler 閒置率太低 = broker 忙不過來；Produce 的 p99 延遲包含等 follower 複製的時間（acks=all）。主機 CPU 是 Confluent Server 自己提供的 MBean。" },

  { tag: "指標在量什麼", title: "REST Proxy、C3 與每個 Java 程序", diagram: "mapps", blocks: [], notes: "REST Proxy 的指標來自官方 confluent_rest.yml；C3 的 client 狀態與 failed threads 是我方的命名規則，其餘來自官方 kafka_streams.yml；JVM 與 process 指標是 JMX exporter 內建的。" },

  { tag: "送 omnibus", title: "告警怎麼變成 omnibus 的 10 個欄位", diagram: "omnibusmap", blocks: [
    ["一筆一個 POST", "group_by: ['...'] 不合併告警，符合行內的扁平格式。"],
    ["不會壞掉", "toJson 負責跳脫雙引號與換行，內容怎麼寫都還是合法 JSON。"],
  ], notes: "欄位值照行內提供的範例（Dynatrace 用的格式）填；範例的變數換成告警規則的對應值，對應方式是我們定的。欄位值請行內確認（請銀行確認的事項 11.5、11.11）。Alertmanager 的實際設定見附錄 A。" },

  { tag: "新增的服務與檔案", title: "c3-01 上：我們的檔與 C3 的檔分開", diagram: "files", blocks: [], notes: "prometheus-generated.yml 是安裝 C3 時就有、由我們擁有的檔，這裡多了分流、4 個抓取 job、規則檔。" },

  { tag: "規則的出處", title: "26 條規則從哪裡來", diagram: "rulesources", blocks: [], notes: "官方規則沒有正式支援的聲明，而且有寫錯的條目，所以修正後採用。C3 文件的 trigger 建議（cluster down、offline、URP、unclean）已由官方規則涵蓋。" },

  { tag: "官方規則的修正", title: "官方規則直接用會出錯，我們改了這些", table: {
    head: ["官方原本的寫法", "問題"],
    widths: [0.4, 0.6],
    rows: [
      ["Broker IO Activity（2 條）", "用永遠小於 1 的指標，等於永遠成立"],
      ["UncleanLeaderElections > 0", "指標是累計值，發生過一次就永遠成立"],
      ["ActiveControllerCount、Offline：for 10 秒", "controller 重啟就叫人"],
      ["UnderReplicatedPartitions：for 1 分鐘", "滾動重啟一定會響"],
      ["high_load（node_load1）", "要另裝 node_exporter"],
      ["service_down（up == 0）", "所有 target 都算，連不相干的也會響"],
    ] }, blocks: [], notes: "出處：confluentinc/jmx-monitoring-stacks 的 prometheus-alerts/broker-alerts.yml、alerts.yml。" },

  { tag: "未採用", title: "比對過但不採用的規則", table: {
    head: ["規則", "出處", "不採用的原因"],
    widths: [0.3, 0.27, 0.43],
    rows: [
      ["Consumer lag 過高、持續增加", "Grafana、awesome", "門檻依各應用程式而定，由應用團隊或 C3 畫面看"],
      ["Leader election rate", "C3 文件", "沒有建議門檻；滾動重啟一定會觸發"],
      ["磁碟剩餘空間", "Strimzi、官方", "JMX 沒有這個指標，要主機監控或 node_exporter"],
      ["容器重啟、容器停了", "Strimzi", "Kubernetes 專用"],
      ["ZooKeeper 相關", "Grafana、C3 文件", "KRaft 沒有 ZooKeeper"],
      ["Topic offset 變小", "awesome（Burrow）", "要另裝 Burrow；我們不刪重建 topic"],
      ["C3 自己的 consumer lag", "Kafka Streams 建議", "序列數多很多；畫面延遲由另外兩條 C3 規則涵蓋"],
    ] }, blocks: [], notes: "Strimzi 的 UnderMinIsr、OfflineLogDirectory 和我們的規則等價，不重複加。畫面延遲由 ControlCenterStreamsNotRunning、ControlCenterStreamsStalled 涵蓋。" },

  { tag: "安全", title: "每段連線都有身分或只限本機", diagram: "security", blocks: [], notes: "omnibus 端是否要認證，請銀行告知；要認證時密碼放 0600 的檔（password_file），不寫進設定。" },

  { tag: "lab 驗證", title: "停一台 broker、一台 controller 的實測", diagram: "timeline", blocks: [
    ["載入", "C3 Prometheus 抓到 10／10 台，26 條規則全部載入，沒有錯誤。"],
  ], notes: "2026-11-07 在 lab 實測（Confluent 8.3.2、C3 2.6.1）。時間是約略值：抓取 30 秒、規則 for 2 分或 5 分、通知間隔 1 分；服務啟動後 exporter 約 2 分鐘才回應。" },

  { tag: "風險", title: "還要注意的風險", color: RISK, table: {
    head: ["風險", "影響", "對策"],
    widths: [0.3, 0.34, 0.36],
    rows: [
      ["c3-01 整台掛掉", "所有告警都發不出來", "請銀行主機監控或 omnibus 端偵測 c3-01 存活"],
      ["沒有磁碟剩餘空間的告警", "磁碟滿了 broker 會停", "請銀行主機監控；log dir 離線有規則"],
    ] }, blocks: [], notes: "2.5.1 的問題在 lab 實測過：Alertmanager 0.32.2 會把 payload 算好的字串再當 YAML 解析一次。" },

  { tag: "維運", title: "之後的維運", table: {
    head: ["情況", "要做什麼"],
    widths: [0.3, 0.7],
    rows: [
      ["新增或調整告警", "改 confluent-alerts.yml，重新產生 C3 用的檔，重啟 Prometheus"],
      ["新增或移除主機", "改 prometheus-generated.yml 的 targets，重啟 Prometheus"],
      ["升級 C3", "重啟第二台，重做停機測試"],
      ["銀行之後提供 Prometheus", "改用銀行的 Prometheus；同一個告警不要兩邊都送"],
    ] }, blocks: [], notes: "請銀行確認的事項 11.11。原廠的回覆會決定這個方案能不能上線。" },
];

// Appendix A: the real settings, after the main part (user, 2026-11-08: settings can go to the back)
const APPENDIX = [
  { tag: "附錄 A：設定", title: "exporter 的實際設定（broker 為例）", file: "/etc/systemd/system/confluent-server.service.d/40-jmx.conf", code: [
    "[Service]",
    "EnvironmentFile=/etc/confluent/jmx-exporter.env",
    "Environment=\"KAFKA_OPTS=-javaagent:/opt/jmx-exporter/",
    "  jmx_prometheus_javaagent-1.7.0.jar=7071:",
    "  /etc/confluent/kafka/jmx-exporter.yml\"",
    "# ↑ Environment= 實際是一行，這裡為了版面拆開",
    "",
    "# /etc/confluent/kafka/jmx-exporter.yml 的開頭（HTTPS）",
    "httpServer:",
    "  ssl:",
    "    keyStore:",
    "      filename: /etc/confluent/ssl/cp-server.p12",
    "      password: ${JMX_KEYSTORE_PASSWORD}  # 從環境檔讀",
    "      type: PKCS12",
    "    certificate:",
    "      alias: cp-server",
    "lowercaseOutputName: true",
    "rules:                         # 接 Confluent 官方規則",
    "  - pattern: …",
  ].join("\n"), blocks: [
    ["環境檔", "/etc/confluent/jmx-exporter.env（root 0600）只有 JMX_KEYSTORE_PASSWORD。"],
    ["指標規則", "接在 HTTPS 設定後面，是 Confluent 官方的規則檔。"],
  ], notes: "controller 用同樣的 KAFKA_OPTS，REST Proxy 用 KAFKAREST_OPTS，C3 用 CONTROL_CENTER_OPTS（見下一頁）。" },

  { tag: "附錄 A：設定", title: "四種程序各自的 exporter 設定", table: {
    head: ["程序", "環境變數", "設定檔", "憑證", "指標規則"],
    widths: [0.15, 0.17, 0.32, 0.14, 0.22],
    rows: [
      ["controller ×3", "KAFKA_OPTS", "/etc/confluent/kafka/jmx-exporter.yml", "kafka-internal", "官方 kafka_controller.yml"],
      ["broker ×4", "KAFKA_OPTS", "/etc/confluent/kafka/jmx-exporter.yml", "cp-server", "官方 kafka_broker.yml"],
      ["REST Proxy ×2", "KAFKAREST_OPTS", "/etc/confluent/kafka-rest/jmx-exporter.yml", "svc-rest", "官方 confluent_rest.yml"],
      ["Control Center", "CONTROL_CENTER_OPTS", "/etc/confluent/control-center/jmx-exporter.yml", "svc-c3", "我方開頭＋官方 kafka_streams.yml"],
    ] }, blocks: [], notes: "官方規則是 Confluent jmx-monitoring-stacks 固定 commit 的檔，指標名稱和官方 dashboard、告警規則一致。C3 加開頭的原因：官方規則會把 process-id 放進指標名稱、把執行緒數放進標籤；我方先命名 client-state、alive／failed-stream-threads、thread-state。C3 只收 kafka.streams:*（約 2,100 條），不收 C3 自己的 consumer／producer 與 Jetty。" },

  { tag: "附錄 A：設定", title: "Prometheus 的實際設定（節選）：抓取", file: "/etc/confluent-control-center/prometheus-generated.yml", code: [
    "scrape_configs:",
    "  - job_name: kafka-broker       # 和銀行 Prometheus 同名",
    "    scheme: https",
    "    scrape_interval: 30s",
    "    tls_config:",
    "      ca_file: /etc/confluent/ssl/ca.pem",
    "    static_configs:",
    "      - targets: [kb01…kb04.poc.lab:7071]",
    "        labels: { env: lab }",
    "    relabel_configs:              # hostname = 主機名",
    "      - source_labels: [__address__]",
    "        regex: '([^:]+)(:[0-9]+)?'",
    "        target_label: hostname",
    "    metric_relabel_configs:       # 只留規則用的",
    "      - source_labels: [__name__]",
    "        regex: 'kafka_server_replicamanager_(…)'",
    "        target_label: __tmp_keep",
    "        replacement: 'yes'",
    "      - …（一類指標一段，見「每個 job 保留的指標與來源」）",
    "      - source_labels: [__tmp_keep]",
    "        regex: 'yes'",
    "        action: keep             # 其他丟掉",
    "  - job_name: kafka-controller   # 同樣的寫法",
    "  - job_name: rest-proxy",
    "  - job_name: control-center",
  ].join("\n"), blocks: [
    ["名稱一致", "job 名稱與 env、hostname 標籤和銀行 Prometheus 一樣，規則才能原封不動套用。"],
    ["沒動的部分", "otlp、C3 原本的規則檔照舊；送告警的分流見下一頁。"],
  ], notes: "lab 實測序列數：broker 689、REST 188、C3 55、controller 60；C3 Prometheus 本身約 11.8 萬條（C3 自己的 telemetry）。" },

  { tag: "附錄 A：設定", title: "Prometheus 送告警的分流設定", file: "/etc/confluent-control-center/prometheus-generated.yml（alerting 段）", code: [
    "alerting:",
    "  alertmanagers:",
    "    - scheme: https              # ① C3 內建 Alertmanager（C3 畫面用）",
    "      tls_config:",
    "        ca_file: /etc/confluent/ssl/ca.pem",
    "        cert_file: /etc/confluent/ssl/svc-c3.crt",
    "        key_file: /etc/confluent/ssl/svc-c3.key",
    "      static_configs:",
    "        - targets: [c3-01.poc.lab:9093]",
    "      alert_relabel_configs:",
    "        - source_labels: [target]",
    "          regex: omnibus",
    "          action: drop           # 帶 target=omnibus 的不送這台",
    "    - scheme: http               # ② 第二個 Alertmanager（只聽本機）",
    "      static_configs:",
    "        - targets: [127.0.0.1:9193]",
    "      alert_relabel_configs:",
    "        - source_labels: [target]",
    "          regex: omnibus",
    "          action: keep           # 只收 target=omnibus 的",
  ].join("\n"), blocks: [
    ["怎麼分", "我們的 26 條規則都帶 target=omnibus（見「規則檔：每個群組帶 target: omnibus」），只送第二台；C3 畫面建的 trigger 沒有這個標籤，只到內建那台。"],
    ["為什麼不送兩台", "內建那台由 C3 管理，不接 omnibus；兩台都收會重複通知。"],
  ], notes: "alert_relabel_configs 是每個 Alertmanager 各自的過濾：同一條告警依標籤決定送哪一台。lab 實測：停 kb04、kc03 的 4 筆告警只出現在第二台；C3 trigger 只出現在內建那台。" },

  { tag: "附錄 A：設定", title: "每個 job 保留的指標與來源", table: {
    head: ["job", "保留的指標（其餘丟掉）", "指標來源"],
    widths: [0.15, 0.6, 0.25],
    rows: [
      ["kafka-controller", "kafkacontroller 的 activecontrollercount、offlinepartitionscount、fencedbrokercount、lastappliedrecordlagms、metadataerrorcount、newactivecontrollerscount；controllerstats_uncleanleaderelectionspersec", "Confluent 官方 exporter 規則（kafka_controller.yml）"],
      ["kafka-broker", "replicamanager 的 underreplicatedpartitions、isrshrinkspersec、isrexpandspersec；cluster_partition_underminisr；logdirectoryoffline；requesthandleravgidlepercent；networkprocessoravgidlepercent；Produce 的 totaltimems、requestspersec", "Confluent 官方 exporter 規則（kafka_broker.yml）"],
      ["rest-proxy", "jersey 的 *_request_error_rate；jetty 的 thread_pool_usage", "Confluent 官方 exporter 規則（confluent_rest.yml）"],
      ["control-center", "kafka_streams 的 poll_rate、background_errors、dropped_records_rate", "Confluent 官方 exporter 規則（kafka_streams.yml）"],
      ["control-center", "kafka_streams 的 client_state、failed_stream_threads", "我方為 C3 加的命名規則"],
      ["controller、broker", "kafka_server_kafkaserver_linux_system_cpu_utilization_1m", "Confluent Server 自己提供（KafkaServer MBean）"],
      ["四個都留", "jvm_memory_used／max_bytes、jvm_threads_deadlocked、process_open／max_fds", "JMX exporter 內建（JVM、process）"],
    ] }, blocks: [], notes: "四種指標來源：Confluent 官方 exporter 規則（jmx-monitoring-stacks 固定 commit）、Confluent Server 自己提供的 MBean、JMX exporter 內建的 JVM 與 process 指標、我方為 C3 加的命名規則。規則用到新的指標時，要把名稱加進對應 job，否則那條規則沒有資料（不會報錯）。" },

  { tag: "附錄 A：設定", title: "規則檔：每個群組帶 target: omnibus", file: "/etc/confluent-control-center/custom-rules-confluent.yml（全文見附錄 B）", code: [
    "groups:",
    "  - name: kafka-broker",
    "    labels:",
    "      target: omnibus          # 群組裡每條都帶，分流靠它",
    "    rules:",
    "      - alert: KafkaUnderReplicatedPartitions",
    "        expr: sum by (env) (",
    "          kafka_server_replicamanager_underreplicatedpartitions",
    "          {job=\"kafka-broker\"}) > 0",
    "        for: 5m",
    "        labels:",
    "          severity: warning    # → omnibus severity",
    "          impact: SERVICE      # → omnibus msg_catalog",
    "        annotations:",
    "          summary: …           # → omnibus sub_origin",
    "          description: …       # → omnibus msg",
  ].join("\n"), blocks: [
    ["和銀行 Prometheus 同一份", "26 條規則和交給銀行 Prometheus 的完全相同，只在每個群組多了 target 標籤。"],
    ["放到哪", "c3-01 的 /etc/confluent-control-center/，root:confluent 0640。"],
  ], notes: "target 標籤加在群組上，群組裡每一條規則都自動帶到；新增規則時不用每條記得加。附錄 B 有 26 條的全文。" },

  { tag: "附錄 A：設定", title: "第二個 Alertmanager 的實際設定（節選）", file: "/etc/confluent/alertmanager-custom/alertmanager.yml", code: [
    "route:",
    "  receiver: omnibus",
    "  group_by: ['...']          # 每筆告警自成一個通知",
    "  group_wait: 5s",
    "  repeat_interval: 4h",
    "receivers:",
    "  - name: omnibus",
    "    webhook_configs:",
    "      - url: <omnibus 位址>",
    "        send_resolved: true    # 恢復時送 RESOLVED",
    "        payload: >-",
    "          {\"source\": \"TCB_DYNATRACE\",",
    "           \"msg\": {{ .CommonAnnotations.description | toJson }},",
    "           \"state\": \"{{ if eq .Status \"firing\" }}OPEN",
    "                    {{ else }}RESOLVED{{ end }}\",",
    "           \"hostname\": {{ if .CommonLabels.hostname }}…",
    "                       {{ else }}{{ .CommonLabels.env … }},",
    "           … 共 10 個欄位}",
  ].join("\n"), blocks: [
    ["服務", "alertmanager-custom.service，只聽 127.0.0.1:9193，叢集功能關閉。"],
    ["執行檔", "C3 套件內附的 Alertmanager 0.34.0。"],
  ], notes: "lab 的 url 是模擬接收端 lab-mon-webhook；正式環境換成銀行給的位址，要認證時加 http_config。叢集功能關閉是因為 C3 內建的 Alertmanager 已經佔用 9094。" },

];

module.exports = { COLOR, SLIDES, APPENDIX };
