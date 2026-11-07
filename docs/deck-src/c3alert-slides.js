// Content of the chapter 32 proposal deck (c3alert.js renders it, guide-build.ps1 fills the company template).
// For a technical manager: conclusion first, why JMX, architecture, the key lines of each config file,
// every alert rule (what it watches, where it comes from), lab evidence, risks and open items.
//   diagram slide: { title, diagram, blocks: [[label, text], …], notes }
//   table slide:   { title, table: { head, widths, rows }, blocks, notes }
//   tiles slide:   { title, tiles: [[head, sub, icon], …], blocks, notes }
//   code slide:    { title, file, code, blocks, notes }  code on the left (monospace), cards on the right
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
    ["涵蓋", "controller、broker、REST Proxy、C3，加上 JVM 與主機 CPU；和第 17 章用同一份規則。"],
    ["只在 C3 2.6.1 之後", "C3 2.5.1 內附的 Alertmanager 會把字串改成數字或物件，所以要等遷移完成。"],
  ], notes: "手冊第 32 章。先講結論：可行、已在 lab 實測，剩外部確認事項。" },

  { tag: "背景", title: "銀行沒有 Prometheus 時，誰抓、誰發告警", table: {
    head: ["", "銀行有提供（第 17 章）", "銀行沒有提供（第 32 章）"],
    widths: [0.18, 0.41, 0.41],
    rows: [
      ["誰抓指標", "銀行的 Prometheus 抓 10 台的 7071", "C3 內建的 Prometheus 抓同樣 10 台的 7071"],
      ["告警規則", "第 17 章的 26 條", "同一份 26 條（每個群組加 target 標籤）"],
      ["誰發告警", "銀行的 Alertmanager", "我們的第二個 Alertmanager（在 c3-01）"],
      ["送到哪", "omnibus", "omnibus（行內規定的扁平 JSON）"],
    ] }, blocks: [
    ["行內的要求", "告警要進 omnibus，而且是固定欄位的扁平 JSON，每個欄位都是字串。"],
    ["同一份規則", "兩條路徑用同一份規則，lab 驗過一次就兩邊成立，不用維護兩套。"],
  ], notes: "請銀行確認的事項 11.11。" },

  { tag: "為什麼不直接用 C3", title: "C3 畫面的告警不符合行內格式", table: {
    head: ["做法", "問題", "依據"],
    widths: [0.26, 0.5, 0.24],
    rows: [
      ["C3 畫面建 trigger＋action", "action 只送 Alertmanager 預設格式，webhook 內容不能自訂", "lab 實測 2026-10-26"],
      ["改 C3 內建 Alertmanager 的設定", "C3 會重寫那份設定，重啟後手改的內容被蓋掉", "lab 實測 2026-10-26"],
      ["改 C3 產生的規則檔", "trigger_rules-generated.yml 由 C3 產生，手改會被蓋掉", "手冊 32.5"],
      ["我們另外架一套 Prometheus", "多一套要維運、要備份、要升級的系統", "未採用"],
    ] }, blocks: [
    ["結論", "不碰 C3 自己寫的檔，只在我們擁有的檔加設定，再加一個獨立的 Alertmanager。"],
  ], notes: "前三項都在 lab 試過。另架一套 Prometheus 等於替銀行維運一套監控系統，不是我們的範圍。" },

  { tag: "指標來源", title: "規則建在 JMX exporter，不建在 telemetry", table: {
    head: ["", "C3 已收的 telemetry", "JMX exporter（採用）"],
    widths: [0.2, 0.4, 0.4],
    rows: [
      ["分辨主機", "只有 node id，沒有主機名稱", "有 hostname"],
      ["controller", "幾乎沒有；raft 指標沒帶 node id 被拒收", "齊全（活躍 controller、metadata 落後、fenced broker）"],
      ["REST Proxy", "沒有（REST 不送 telemetry）", "有"],
      ["官方規則", "名稱不同，要全部重寫", "jmx-monitoring-stacks 的規則直接套用"],
      ["CPU、磁碟", "C3 2.6.1 的 trigger 查詢裡也沒有", "有主機 CPU；磁碟剩餘空間沒有"],
    ] }, blocks: [
    ["telemetry 照舊", "C3 畫面靠它，不能關；只是不拿來發告警。"],
  ], notes: "lab 實測：C3 Prometheus 裡 telemetry 指標都是 io_confluent_ 開頭，JMX exporter 是 kafka_、jvm_，不會撞名。C3 2.6.1 的 prom-trigger-queries.yml 沒有 CPU 與 Storage 的查詢（文件有列）。" },

  { tag: "架構", title: "整體架構：抓 10 台、規則分流、送 omnibus", diagram: "c3alert", blocks: [
    ["抓取", "C3 內建 Prometheus 每 30 秒抓 10 台的 7071（HTTPS），只留規則用得到的指標。"],
    ["分流", "我們的規則帶 target: omnibus，只送第二台；C3 畫面的 trigger 只送內建那台。"],
    ["發送", "第二台把每筆告警轉成行內的扁平 JSON 送 omnibus。"],
  ], notes: "全部在 c3-01 上，不新增主機。第二個 Alertmanager 用 C3 套件內附的執行檔，不另外引進軟體。" },

  { tag: "分流", title: "分流是白名單：帶標籤才進 omnibus", table: {
    head: ["來源", "規則檔", "帶的標籤", "送到"],
    widths: [0.2, 0.32, 0.26, 0.22],
    rows: [
      ["我們的規則（26 條）", "custom-rules-confluent.yml（root 擁有）", "target: omnibus", "第二台 → omnibus"],
      ["C3 畫面的 trigger", "trigger_rules-generated.yml（C3 寫）", "rule_created_by，沒有 target", "C3 內建那台"],
    ] }, blocks: [
    ["怎麼分", "Prometheus 對每台 Alertmanager 各有 alert_relabel_configs：內建那台 drop、第二台 keep。"],
    ["好處", "有人在 C3 畫面建 trigger，也不會誤發到 omnibus。"],
    ["要注意", "規則忘了加標籤不會報錯，只是不會通知；所以由規則群組統一加。"],
  ], notes: "白名單比黑名單穩：C3 的標籤格式可能隨版本改變。" },

  { tag: "新增的服務與檔案", title: "只多一個服務、三個檔案", table: {
    head: ["項目", "內容", "擁有者／權限"],
    widths: [0.33, 0.45, 0.22],
    rows: [
      ["alertmanager-custom.service", "第二個 Alertmanager；只聽 127.0.0.1:9193，叢集功能關閉", "以 cp-control-center 執行"],
      ["alertmanager-custom/alertmanager.yml", "omnibus 位址與 JSON 格式", "root:confluent 0640"],
      ["prometheus-generated.yml", "第 13 章就有的檔，多分流、抓取 4 個 job、規則檔", "root:confluent 0640"],
      ["custom-rules-confluent.yml", "第 17 章的 26 條，每個群組加 target", "root:confluent 0640"],
    ] }, blocks: [
    ["C3 改不動", "檔案是 root 擁有，C3 只能讀；C3 從 2.5.1 升 2.6.1 後雜湊不變。"],
  ], notes: "叢集功能關閉是因為 C3 內建的 Alertmanager 已經佔用 9094。" },

  { tag: "設定檔 1／3", title: "Prometheus：抓 4 個 job，只留需要的指標", file: "/etc/confluent-control-center/prometheus-generated.yml（節選）", code: [
    "scrape_configs:",
    "  - job_name: kafka-broker       # 名稱與標籤同第 17 章",
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
    "      - …（一類指標一段）",
    "      - source_labels: [__tmp_keep]",
    "        regex: 'yes'",
    "        action: keep             # 其他丟掉",
    "  - job_name: kafka-controller   # 同上",
    "  - job_name: rest-proxy",
    "  - job_name: control-center",
  ].join("\n"), blocks: [
    ["同第 17 章", "job 名稱、env、hostname 和銀行 Prometheus 的設定一樣，規則才能原封不動套用。"],
    ["只留需要的", "一台 broker 原本約 1.4 萬條序列；只留規則用的，10 台合計約 1,000 條。"],
    ["沒動的部分", "分流、otlp、C3 原本的規則檔照舊。"],
  ], notes: "lab 實測序列數：broker 712、REST 188、C3 61、controller 60；C3 Prometheus 本身原有約 11.8 萬條（C3 自己的 telemetry）。完整內容見手冊 32.3。" },

  { tag: "設定檔 2／3", title: "規則：第 17 章的檔，每個群組加標籤", file: "custom-rules-confluent.yml（由第 17 章的檔產生）", code: [
    "# 操作機：每個群組的 name 後面加兩行",
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
    ["一份規則", "規則只在第 17 章維護；第 32 章用同一份產生，不會兩邊不一致。"],
    ["為什麼在群組加", "新增規則不用逐條記得加 target，漏加就收不到通知的風險變小。"],
    ["每條都有", "severity、impact、summary、description，omnibus 欄位都從這裡來。"],
  ], notes: "規則檔由操作機產生再放到 c3-01；第 17 章的規則一改，就重新產生一次（手冊 32.3 第一塊）。" },

  { tag: "設定檔 3／3", title: "Alertmanager：一筆告警一個 POST", file: "/etc/confluent/alertmanager-custom/alertmanager.yml（節選）", code: [
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
    ["group_by: ['...']", "不合併告警，一個 POST 一筆，符合行內的扁平格式。"],
    ["toJson", "負責雙引號與換行的跳脫，內容再怎麼寫都還是合法 JSON。"],
    ["hostname", "主機層的告警填主機名；整個叢集的告警（例如 offline partition）填環境名稱。"],
  ], notes: "lab 的 url 是模擬接收端 lab-mon-webhook；正式環境換成銀行給的位址。" },

  { tag: "規則的出處", title: "規則的出處與挑選原則", table: {
    head: ["來源", "內容", "怎麼用"],
    widths: [0.3, 0.42, 0.28],
    rows: [
      ["Confluent jmx-monitoring-stacks", "官方 GitHub 的 prometheus-alerts（broker 7 條、service_down）", "採用，有錯的修正"],
      ["Confluent 文件", "Monitor Kafka、KRaft metrics 列的指標與門檻", "採用"],
      ["C3 文件", "trigger 的建議：cluster down、offline、URP、unclean", "已由上面涵蓋"],
      ["我方建議", "REST Proxy、C3、JVM、CPU、log dir：官方沒有規則的元件", "採用，指標都 lab 驗過"],
      ["Strimzi、Grafana、awesome-prometheus-alerts", "社群的 Kafka 規則", "只用來交叉比對"],
    ] }, blocks: [
    ["原則", "每條都要有 lab 上真的存在的指標；門檻要能說出理由；不重複告警。"],
  ], notes: "官方規則沒有正式支援的聲明，而且有寫錯的條目，所以我們修正後採用。" },

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
    ] }, blocks: [], notes: "KafkaFencedBrokers 是這次新增：Confluent 的 KRaft 指標文件列了 FencedBrokerCount，broker 停掉或跟不上 metadata 時會被隔離。" },

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
      ["C3 自己的 consumer lag", "Kafka Streams 建議", "要收 C3 的 consumer 指標，序列數多很多；畫面延遲由「非 RUNNING」「不再處理」兩條涵蓋"],
    ] }, blocks: [], notes: "Strimzi 的 UnderMinIsr、OfflineLogDirectory 和我們的規則等價，不重複加。" },

  { tag: "omnibus 欄位", title: "送給 omnibus 的 10 個欄位", table: {
    head: ["欄位", "內容", "來源"],
    widths: [0.22, 0.44, 0.34],
    rows: [
      ["source／ClassName／sub_source", "TCB_DYNATRACE／TCB_DYNATRACE_STATUS／PIB", "行內給的固定值"],
      ["state", "OPEN 或 RESOLVED", "告警狀態"],
      ["severity", "critical → ERROR，warning → PERFORMANCE", "規則的 severity"],
      ["msg_catalog", "SERVICE、APPLICATION、INFRASTRUCTURE", "規則的 impact"],
      ["msg", "完整說明與處理方向", "規則的 description"],
      ["sub_origin", "規則名稱: 摘要", "alertname＋summary"],
      ["origin", "暫填 c3-embedded", "待銀行確認"],
      ["hostname", "主機名；叢集層級的填環境名稱", "hostname 或 env（待銀行確認）"],
    ] }, blocks: [], notes: "行內給的格式原本是 Dynatrace 的變數，對應方式是我們定的，列在請銀行確認的事項 11.11。" },

  { tag: "安全", title: "每段連線都有身分或只限本機", table: {
    head: ["連線", "怎麼保護"],
    widths: [0.36, 0.64],
    rows: [
      ["Prometheus → 10 台的 7071", "HTTPS，驗各主機的伺服器憑證；防火牆只開給 c3-01"],
      ["Prometheus → C3 內建 Alertmanager 9093", "mTLS，用 C3 的 svc-c3 憑證"],
      ["Prometheus → 第二台 9193", "只聽 127.0.0.1，外部連不到，不需要憑證"],
      ["操作機查 Prometheus 9090", "要 client 憑證（svc-ops）"],
      ["第二台 → omnibus", "依銀行規定；要認證時加 http_config"],
    ] }, blocks: [
    ["換憑證時", "第二台沒有憑證，第 21 章的輪替不用處理它。"],
    ["防火牆", "第 17 章 7071 只開給銀行 Prometheus；這個方案要改開給 c3-01。"],
  ], notes: "omnibus 端是否要認證，請銀行告知。" },

  { tag: "lab 驗證", title: "lab 實測結果", table: {
    head: ["測試", "結果"],
    widths: [0.42, 0.58],
    rows: [
      ["C3 Prometheus 抓 10 台 7071", "10／10 up；26 條規則全部載入，沒有錯誤"],
      ["只留需要的指標", "4 個 job 合計約 1,000 條序列"],
      ["和 C3 原有指標比對", "telemetry 是 io_confluent_ 開頭，不撞名"],
      ["停一台 broker、一台 controller", "4 筆 OPEN：兩台各一筆抓不到、under-replicated、fenced broker"],
      ["兩台開回來", "4 筆 RESOLVED；10 個欄位全部是字串，hostname 正確"],
      ["C3 畫面的 trigger", "只到內建那台，omnibus 沒有收到（2026-11-05 實測）"],
    ] }, blocks: [], notes: "2026-11-07 在 lab 實測（Confluent 8.3.2、C3 2.6.1）。" },

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
      ["新增或調整告警", "改第 17 章的規則檔，重新產生 C3 用的檔，重啟 Prometheus"],
      ["新增或移除主機", "改 prometheus-generated.yml 的 targets，重啟 Prometheus"],
      ["升級 C3", "我們的檔不受影響；重啟第二台，重做停機測試"],
      ["銀行之後提供 Prometheus", "改走第 17 章；同一個告警不要兩邊都送"],
    ] }, blocks: [
    ["請原廠確認", "C3 內建 Prometheus 多抓 10 台、另開一個 Alertmanager 是否在支援範圍。"],
    ["請銀行確認", "origin、hostname 的填法；omnibus 位址與認證；c3-01 → 7071 防火牆。"],
  ], notes: "請銀行確認的事項 11.11。原廠的回覆會決定這個方案能不能上線。" },
];

module.exports = { COLOR, SLIDES };
