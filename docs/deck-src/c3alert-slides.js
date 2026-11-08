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
    ["待確認", "原廠支援範圍；omnibus 的 origin、hostname 填法；防火牆", "LuCircleHelp"],
  ], blocks: [
    ["涵蓋", "controller、broker、REST Proxy、C3，加上 JVM 與主機 CPU。"],
    ["前提", "C3 2.6.1 之後（2.5.1 內附的 Alertmanager 會改掉欄位型別）。"],
  ], notes: "手冊第 32 章。先講結論：可行、已在 lab 實測，剩外部確認事項。" },

  { tag: "背景", title: "兩條路徑，同一份規則", diagram: "paths", blocks: [
    ["行內的要求", "告警進 omnibus，固定欄位的扁平 JSON，每個欄位都是字串。"],
    ["本方案", "銀行沒有 Prometheus 時，由 C3 內建的 Prometheus 接手抓取與算規則。"],
    ["一份規則", "兩條路徑用同一份 26 條，驗過一次兩邊都成立。"],
  ], notes: "請銀行確認的事項 11.11。銀行之後若提供 Prometheus，改走上面那條，同一個告警不要兩邊都送。" },

  { tag: "為什麼不直接用 C3", title: "C3 畫面的告警不符合行內格式", table: {
    head: ["做法", "問題", "依據"],
    widths: [0.26, 0.5, 0.24],
    rows: [
      ["C3 畫面建 trigger＋action", "action 只送 Alertmanager 預設格式，webhook 內容不能自訂", "lab 實測 2026-10-26"],
      ["改 C3 內建 Alertmanager 的設定", "C3 會重寫那份設定，重啟後手改的內容被蓋掉", "lab 實測 2026-10-26"],
      ["改 C3 產生的規則檔", "trigger_rules-generated.yml 由 C3 產生，手改會被蓋掉", "手冊 32.5"],
      ["我們另外架一套 Prometheus", "多一套要維運、要備份、要升級的系統", "未採用"],
    ] }, blocks: [], notes: "結論：不碰 C3 自己寫的檔，只在我們擁有的檔加設定，再加一個獨立的 Alertmanager。" },

  { tag: "指標來源", title: "規則建在 JMX exporter，不建在 telemetry", diagram: "sources", blocks: [
    ["telemetry", "只有 node id、controller 幾乎沒有、REST 不送；名稱和官方規則不同。"],
    ["JMX exporter", "有主機名、4 種程序都有，官方規則直接套用。"],
    ["telemetry 照舊", "C3 畫面靠它，不能關；只是不拿來發告警。"],
  ], notes: "lab 實測：raft 指標沒帶 node id、多台互撞被拒收；C3 2.6.1 的 prom-trigger-queries.yml 沒有 CPU 與 Storage 的查詢（文件有列）。JMX exporter 有主機 CPU，但沒有磁碟剩餘空間。" },

  { tag: "架構", title: "整體架構：抓 10 台、規則分流、送 omnibus", diagram: "c3alert", blocks: [
    ["抓取", "每 30 秒抓 10 台的 7071（HTTPS），只留規則用的指標。"],
    ["分流", "帶 target: omnibus 的只送第二台。"],
    ["發送", "第二台轉成行內的扁平 JSON 送 omnibus。"],
  ], notes: "全部在 c3-01 上，不新增主機。第二個 Alertmanager 用 C3 套件內附的執行檔，不另外引進軟體。" },

  { tag: "前提：JMX exporter", title: "每台 Java 程序掛 JMX exporter，聽 7071", diagram: "exporter", blocks: [
    ["怎麼掛", "systemd drop-in 在服務的環境變數加 -javaagent。"],
    ["只做 HTTPS", "不要帳密也不要 client 憑證，存取控制靠防火牆。"],
    ["密碼不落地", "keystore 密碼放 root 0600 的環境檔。"],
  ], notes: "jar 版本 1.7.0（GitHub release，sha256 與 GPG 核對過）。設定檔 root:confluent 0640。" },

  { tag: "前提：JMX exporter", title: "exporter 的實際設定（broker 為例）", file: "/etc/systemd/system/confluent-server.service.d/40-jmx.conf", code: [
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

  { tag: "前提：JMX exporter", title: "四種程序各自的 exporter 設定", table: {
    head: ["程序", "環境變數", "設定檔", "憑證", "指標規則"],
    widths: [0.15, 0.17, 0.32, 0.14, 0.22],
    rows: [
      ["controller ×3", "KAFKA_OPTS", "/etc/confluent/kafka/jmx-exporter.yml", "kafka-internal", "官方 kafka_controller.yml"],
      ["broker ×4", "KAFKA_OPTS", "/etc/confluent/kafka/jmx-exporter.yml", "cp-server", "官方 kafka_broker.yml"],
      ["REST Proxy ×2", "KAFKAREST_OPTS", "/etc/confluent/kafka-rest/jmx-exporter.yml", "svc-rest", "官方 confluent_rest.yml"],
      ["Control Center", "CONTROL_CENTER_OPTS", "/etc/confluent/control-center/jmx-exporter.yml", "svc-c3", "我方開頭＋官方 kafka_streams.yml"],
    ] }, blocks: [], notes: "官方規則是 Confluent jmx-monitoring-stacks 固定 commit 的檔，指標名稱和官方 dashboard、告警規則一致。C3 加開頭的原因：官方規則會把 process-id 放進指標名稱、把執行緒數放進標籤；我方先命名 client-state、alive／failed-stream-threads、thread-state。C3 只收 kafka.streams:*（約 2,100 條），不收 C3 自己的 consumer／producer 與 Jetty。" },

  { tag: "只留需要的指標", title: "每個 job 只留規則用得到的指標", diagram: "funnel", blocks: [
    ["怎麼做", "metric_relabel_configs：符合的打標記，最後只留有標記的。"],
    ["效果", "C3 Prometheus 的負擔幾乎不變。"],
  ], notes: "lab 數字；broker 的序列數會隨 topic、partition 數增加，但保留的只有規則用的那幾個指標。" },

  { tag: "只留需要的指標", title: "Prometheus 的實際設定（節選）", file: "/etc/confluent-control-center/prometheus-generated.yml", code: [
    "scrape_configs:",
    "  - job_name: kafka-broker       # 和銀行 Prometheus 同名",
    "    scheme: https",
    "    scrape_interval: 30s",
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
    "      - …（一類指標一段，下一頁列出全部）",
    "      - source_labels: [__tmp_keep]",
    "        regex: 'yes'",
    "        action: keep             # 其他丟掉",
    "  - job_name: kafka-controller   # 同樣的寫法",
    "  - job_name: rest-proxy",
    "  - job_name: control-center",
  ].join("\n"), blocks: [
    ["名稱一致", "job 名稱與 env、hostname 標籤和銀行 Prometheus 一樣，規則才能原封不動套用。"],
    ["沒動的部分", "分流、otlp、C3 原本的規則檔照舊。"],
  ], notes: "lab 實測序列數：broker 712、REST 188、C3 61、controller 60；C3 Prometheus 本身約 11.8 萬條（C3 自己的 telemetry）。" },

  { tag: "只留需要的指標", title: "每個 job 保留的指標", table: {
    head: ["job", "保留的指標（其餘丟掉）"],
    widths: [0.17, 0.83],
    rows: [
      ["kafka-controller", "kafkacontroller 的 activecontrollercount、offlinepartitionscount、fencedbrokercount、lastappliedrecordlagms、metadataerrorcount、newactivecontrollerscount；controllerstats_uncleanleaderelectionspersec"],
      ["kafka-broker", "replicamanager 的 underreplicatedpartitions、isrshrinkspersec、isrexpandspersec；cluster_partition_underminisr；logmanager_logdirectoryoffline；requesthandleravgidlepercent_oneminuterate；networkprocessoravgidlepercent；requestmetrics 的 totaltimems、requestspersec（只留 request=Produce）"],
      ["rest-proxy", "kafka_rest_jersey_metrics_*_request_error_rate；kafka_rest_jetty_metrics_thread_pool_usage"],
      ["control-center", "kafka_streams 的 client_state、failed_stream_threads、poll_rate、background_errors、dropped_records_rate"],
      ["四個都留", "linux_system_cpu_utilization_1m（controller、broker）；jvm_memory_used／max_bytes、jvm_threads_deadlocked、process_open／max_fds"],
    ] }, blocks: [], notes: "規則用到新的指標時，要把名稱加進對應 job，否則那條規則沒有資料（不會報錯）。" },

  { tag: "規則從哪來", title: "一份規則檔，兩個去處", diagram: "rulesource", blocks: [
    ["一份規則", "只維護 confluent-alerts.yml；本方案用它產生，不會兩邊不一致。"],
    ["為什麼在群組加", "新增規則不用逐條記得加 target。"],
  ], notes: "規則檔由操作機產生再放到 c3-01；confluent-alerts.yml 一改，就重新產生一次並重啟 Prometheus。" },

  { tag: "規則從哪來", title: "規則檔的實際產生方式", file: "操作機：confluent-alerts.yml → custom-rules-confluent.yml（全文見附錄）", code: [
    "# 每個群組的 name 後面加兩行",
    "sed -e '/^  - name: /a\\    labels:' \\",
    "    -e '/^  - name: /a\\      target: omnibus' \\",
    "  confluent-alerts.yml > custom-rules-confluent.yml",
    "",
    "groups:",
    "  - name: kafka-broker",
    "    labels:",
    "      target: omnibus          # 群組裡每條都帶",
    "    rules:",
    "      - alert: KafkaUnderReplicatedPartitions",
    "        expr: sum by (env) (",
    "          kafka_server_replicamanager_underreplicatedpartitions",
    "          {job=\"kafka-broker\"}) > 0",
    "        for: 5m",
    "        labels:",
    "          severity: warning    # → omnibus severity",
    "          impact: SERVICE      # → omnibus msg_catalog",
  ].join("\n"), blocks: [
    ["每條都有", "severity、impact、summary、description，omnibus 欄位都從這裡來。"],
    ["放到哪", "c3-01 的 /etc/confluent-control-center/，root:confluent 0640。"],
  ], notes: "附錄有 26 條的全文。" },

  { tag: "分流", title: "分流是白名單：帶標籤才進 omnibus", diagram: "split", blocks: [
    ["怎麼分", "每台 Alertmanager 各有 alert_relabel_configs：一台 keep、一台 drop。"],
    ["好處", "C3 畫面建的 trigger 不會誤發到 omnibus。"],
  ], notes: "白名單比黑名單穩：C3 的標籤格式可能隨版本改變。我們的規則在 custom-rules-confluent.yml（root 擁有）；C3 的 trigger 在 trigger_rules-generated.yml（C3 寫），帶 rule_created_by、沒有 target。" },

  { tag: "送 omnibus", title: "告警怎麼變成 omnibus 的 10 個欄位", diagram: "omnibusmap", blocks: [
    ["一筆一個 POST", "group_by: ['...'] 不合併告警，符合行內的扁平格式。"],
    ["不會壞掉", "toJson 負責跳脫雙引號與換行，每個欄位都是字串。"],
  ], notes: "固定值：source TCB_DYNATRACE、ClassName TCB_DYNATRACE_STATUS、sub_source PIB；origin 暫填 c3-embedded（待銀行確認）。hostname：主機層的告警填主機名；整個叢集的告警（例如 offline partition）填環境名稱（待銀行確認）。行內給的格式原本是 Dynatrace 的變數，對應方式是我們定的，列在請銀行確認的事項 11.11。" },

  { tag: "送 omnibus", title: "Alertmanager 的實際設定（節選）", file: "/etc/confluent/alertmanager-custom/alertmanager.yml", code: [
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

  { tag: "新增的服務與檔案", title: "c3-01 上：我們的檔與 C3 的檔分開", diagram: "files", blocks: [
    ["只多這些", "一個服務、三個檔案（prometheus-generated.yml 是原本就有、我們擁有的檔）。"],
    ["C3 改不動", "root 擁有，C3 只能讀；C3 升級後雜湊不變。"],
  ], notes: "prometheus-generated.yml 是第 13 章就有的檔，這裡多了分流、4 個抓取 job、規則檔。" },

  { tag: "規則的出處", title: "26 條規則從哪裡來", diagram: "rulesources", blocks: [
    ["官方為主", "Confluent 的規則修正後採用，再補官方沒有的元件。"],
    ["只採用合理的", "社群規則只比對；門檻說不出理由、會重複的不收。"],
  ], notes: "官方規則沒有正式支援的聲明，而且有寫錯的條目，所以修正後採用。C3 文件的 trigger 建議（cluster down、offline、URP、unclean）已由官方規則涵蓋。" },

  { tag: "規則總覽", title: "26 條規則涵蓋什麼", diagram: "ruleoverview", blocks: [], notes: "接下來四頁逐條列出，附錄有全文。" },

  { tag: "規則 1／4", title: "可用性與主機：服務停了、資源快用完", table: {
    head: RULE_HEAD, widths: RULE_WIDTHS,
    rows: [
      ["ConfluentTargetDown", "抓不到某台的 7071：服務或主機停了", "持續 2 分鐘", "官方（修正）"],
      ["KafkaHostCpuHigh", "controller、broker 主機 CPU", "> 80%，10 分鐘", "我方"],
      ["KafkaLogDirOffline", "broker 的資料目錄離線（磁碟壞或滿）", "> 0，1 分鐘", "我方"],
      ["JvmHeapHigh", "Java 記憶體快用完", "> 90%，10 分鐘", "我方"],
      ["JvmFileDescriptorsHigh", "可開檔案數快用完", "> 80%，10 分鐘", "我方"],
      ["JvmThreadsDeadlocked", "執行緒死結，不會自己恢復", "> 0，5 分鐘", "我方"],
    ] }, blocks: [], notes: "官方的 service_down 是所有 up==0，我們限定 4 個 job、2 分鐘。官方的 high_load 要 node_exporter，改用 Confluent Server 自己的主機 CPU 指標。" },

  { tag: "規則 2／4", title: "controller 與 KRaft：叢集的大腦是否健康", table: {
    head: RULE_HEAD, widths: RULE_WIDTHS,
    rows: [
      ["KafkaActiveControllerCountNotOne", "活躍 controller 不是剛好 1 個", "≠ 1，1 分鐘", "官方（修正）"],
      ["KafkaOfflinePartitions", "partition 沒有 leader，不能讀寫", "> 0，1 分鐘", "官方"],
      ["KafkaUncleanLeaderElections", "不同步的副本當上 leader，可能掉資料", "10 分鐘內有增加", "官方（修正）"],
      ["KafkaFencedBrokers", "broker 在跑但被 controller 隔離", "> 0，5 分鐘", "Confluent 文件"],
      ["KRaftControllerMetadataLag", "controller 套用 metadata 落後", "> 30 秒，5 分鐘", "我方"],
      ["KRaftMetadataErrors", "套用 metadata 出錯", "> 0，1 分鐘", "我方"],
      ["KRaftLeaderFlapping", "controller leader 頻繁更換", "15 分鐘 > 2 次", "我方"],
    ] }, blocks: [], notes: "KafkaFencedBrokers：Confluent 的 KRaft 指標文件列了 FencedBrokerCount，broker 停掉或跟不上 metadata 時會被隔離。" },

  { tag: "規則 3／4", title: "broker：資料是否安全、是否忙不過來", table: {
    head: RULE_HEAD, widths: RULE_WIDTHS,
    rows: [
      ["KafkaUnderReplicatedPartitions", "副本沒有全部同步", "> 0，5 分鐘", "官方（修正）"],
      ["KafkaUnderMinIsrPartitions", "同步副本少於 min.insync，acks=all 寫不進去", "> 0，1 分鐘", "官方"],
      ["KafkaIsrShrinkingWithoutExpand", "副本掉出同步後沒有回來", "15 分鐘只減不增", "Confluent 文件"],
      ["KafkaRequestHandlerBusy", "處理請求的執行緒太忙", "閒置 < 30%，10 分鐘", "Confluent 文件"],
      ["KafkaNetworkProcessorBusy", "網路執行緒太忙", "閒置 < 30%，10 分鐘", "Confluent 文件"],
      ["KafkaProduceLatencyHigh", "寫入延遲（p99）", "> 500 ms，10 分鐘", "Confluent 文件"],
    ] }, blocks: [], notes: "Request handler 取代官方兩條「Broker IO Activity」（官方用的是永遠小於 1 的 control-plane 指標，等於永遠成立）。Produce 延遲只在真的有寫入時判斷，避免沒流量時卡在舊值。" },

  { tag: "規則 4／4", title: "REST Proxy 與 C3：應用程式入口與管理畫面", table: {
    head: RULE_HEAD, widths: RULE_WIDTHS,
    rows: [
      ["RestProxyErrors", "REST 回錯誤（4xx、5xx）", "> 1 次／秒，10 分鐘", "我方"],
      ["RestProxyThreadPoolBusy", "REST 的執行緒池快滿", "> 90%，10 分鐘", "我方"],
      ["ControlCenterStreamsNotRunning", "C3 內部處理不在 RUNNING，畫面停在舊資料", "非 RUNNING，15 分鐘", "我方"],
      ["ControlCenterStreamThreadsFailed", "C3 內部執行緒掛了", "15 分鐘內有增加", "我方"],
      ["ControlCenterStreamsStalled", "C3 內部執行緒不再處理", "poll = 0，10 分鐘", "我方"],
      ["ControlCenterRocksDBBackgroundErrors", "C3 本地儲存出錯", "15 分鐘內有增加", "我方"],
      ["ControlCenterDroppedRecords", "C3 丟棄監控資料", "> 0，10 分鐘", "我方"],
    ] }, blocks: [], notes: "REST Proxy 與 C3 官方都沒有規則；這些都只用 lab 驗過存在的指標。REST Proxy 停掉由 ConfluentTargetDown 涵蓋。C3 的規則在 c3-01 整台掛掉時發不出來。C3 兩條依 Kafka Streams 的建議調整：盯 RUNNING（卡在 REBALANCING 也算）；failed-stream-threads 是累計值，改看增加量。" },

  { tag: "官方規則的修正", title: "官方規則直接用會出錯，我們改了這些", table: {
    head: ["官方規則", "問題", "我們的做法"],
    widths: [0.28, 0.38, 0.34],
    rows: [
      ["Broker IO Activity（2 條）", "用永遠小於 1 的指標，等於永遠成立", "改用 request handler 一分鐘閒置率"],
      ["UncleanLeaderElections > 0", "指標是累計值，發生過一次就永遠成立", "改看 10 分鐘內的增加量"],
      ["ActiveControllerCount、Offline", "for 10 秒，controller 重啟就叫人", "放寬到 1 分鐘，限定 controller"],
      ["UnderReplicatedPartitions", "for 1 分鐘，滾動重啟一定會響", "放寬到 5 分鐘"],
      ["high_load", "要 node_exporter", "改用 Confluent Server 的主機 CPU"],
      ["service_down（up == 0）", "所有 target 都算", "限定 4 個 job、2 分鐘"],
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

  { tag: "安全", title: "每段連線都有身分或只限本機", diagram: "security", blocks: [
    ["防火牆", "7071 原本只放行銀行的 Prometheus；本方案改放行 c3-01。"],
    ["換憑證時", "第二台沒有憑證，第 21 章的輪替不用處理它。"],
  ], notes: "omnibus 端是否要認證，請銀行告知；要認證時密碼放 0600 的檔（password_file），不寫進設定。" },

  { tag: "lab 驗證", title: "停一台 broker、一台 controller 的實測", diagram: "timeline", blocks: [
    ["結果", "4 筆 OPEN、4 筆 RESOLVED，hostname 正確，10 個欄位都是字串。"],
  ], notes: "2026-11-07 在 lab 實測（Confluent 8.3.2、C3 2.6.1）。時間是約略值：抓取 30 秒、規則 for 2 分或 5 分、通知間隔 1 分；服務啟動後 exporter 約 2 分鐘才回應。" },

  { tag: "lab 驗證", title: "其他實測結果", table: {
    head: ["測試", "結果"],
    widths: [0.42, 0.58],
    rows: [
      ["C3 Prometheus 抓 10 台 7071", "10／10 up；26 條規則全部載入，沒有錯誤"],
      ["只留需要的指標", "4 個 job 合計約 1,000 條序列"],
      ["和 C3 原有指標比對", "telemetry 是 io_confluent_ 開頭，不撞名"],
      ["C3 畫面的 trigger", "只到內建那台，omnibus 沒有收到"],
      ["C3 從 2.5.1 升到 2.6.1", "我們的設定檔雜湊不變"],
    ] }, blocks: [], notes: "手冊第 32 章與腳本 32-c3-alerting.sh 都在 lab 跑過。" },

  { tag: "風險", title: "版本前提與風險", color: RISK, table: {
    head: ["風險", "影響", "對策"],
    widths: [0.3, 0.34, 0.36],
    rows: [
      ["原廠文件寫 C3 不支援客戶自管的 Prometheus／Alertmanager", "出問題時原廠可能不受理", "上線前向原廠確認；不改 C3 自己的檔"],
      ["c3-01 整台掛掉", "所有告警都發不出來", "請銀行主機監控或 omnibus 端偵測 c3-01 存活"],
      ["C3 2.5.1 內附的 Alertmanager", "007 變 7、a: b 變物件", "只在 C3 2.6.1 之後啟用，做完不退回"],
      ["沒有磁碟剩餘空間的告警", "磁碟滿了 broker 會停", "請銀行主機監控；log dir 離線有規則"],
      ["C3 Prometheus 負擔變大", "可能拖慢 C3 畫面", "只留需要的指標（約 1,000 條）"],
    ] }, blocks: [], notes: "2.5.1 的問題在 lab 實測過：Alertmanager 0.32.2 會把 payload 算好的字串再當 YAML 解析一次。" },

  { tag: "維運與待決", title: "之後的維運與待確認事項", table: {
    head: ["情況", "要做什麼"],
    widths: [0.3, 0.7],
    rows: [
      ["新增或調整告警", "改 confluent-alerts.yml，重新產生 C3 用的檔，重啟 Prometheus"],
      ["新增或移除主機", "改 prometheus-generated.yml 的 targets，重啟 Prometheus"],
      ["升級 C3", "我們的檔不受影響；重啟第二台，重做停機測試"],
      ["銀行之後提供 Prometheus", "改用銀行的 Prometheus（同一份規則）；同一個告警不要兩邊都送"],
      ["請原廠確認", "C3 內建 Prometheus 多抓 10 台、另開一個 Alertmanager 是否在支援範圍"],
      ["請銀行確認", "origin、hostname 的填法；omnibus 位址與認證；c3-01 → 7071 防火牆"],
    ] }, blocks: [], notes: "請銀行確認的事項 11.11。原廠的回覆會決定這個方案能不能上線。" },
];

module.exports = { COLOR, SLIDES };
