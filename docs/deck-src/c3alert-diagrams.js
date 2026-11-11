// Diagrams used only by the chapter 32 proposal deck (c3alert.js). Same helpers and palette as the guide's diagrams.js.
const D = require("../journey-src/diagrams");
const { svg, box, arrow, region, note, ctext, num } = D._h;

const C = {};

// Two paths, one rule file
C.paths = () => svg(900, 380, [
  region(16, 14, 868, 128, "銀行有 Prometheus", "amber"),
  box(36, 52, 160, 70, "10 台的 7071", ["JMX exporter"], "blue"),
  box(252, 52, 200, 70, "銀行的 Prometheus", ["抓取＋算規則"], "amber"),
  box(508, 52, 190, 70, "銀行的 Alertmanager", ["銀行設定"], "amber"),
  box(744, 52, 124, 70, "omnibus", ["行內事件系統"], "coral"),
  arrow(196, 87, 250, 87), arrow(452, 87, 506, 87), arrow(698, 87, 742, 87),
  box(252, 156, 200, 64, "同一份 26 條規則", ["confluent-alerts.yml"], "purple"),
  arrow(352, 156, 352, 124, null, { dash: true }), arrow(352, 220, 352, 256, null, { dash: true }),
  ctext(560, 188, "規則只維護一份，兩條路徑都用它", { size: 13, fill: "#3C3489" }),
  region(16, 236, 868, 128, "銀行沒有 Prometheus（本方案）", "teal"),
  box(36, 274, 160, 70, "10 台的 7071", ["同樣的 JMX exporter"], "blue"),
  box(252, 274, 200, 70, "C3 內建 Prometheus", ["抓取＋算規則"], "teal"),
  box(508, 274, 190, 70, "第二個 Alertmanager", ["c3-01，我們的設定"], "teal"),
  box(744, 274, 124, 70, "omnibus", ["行內事件系統"], "coral"),
  arrow(196, 309, 250, 309), arrow(452, 309, 506, 309), arrow(698, 309, 742, 309),
].join(""));

// Two kinds of data reach the C3 Prometheus; only one is used for alerts
C.sources = () => svg(900, 360, [
  box(24, 40, 150, 56, "controller ×3", ["telemetry＋JMX"], "blue"),
  box(24, 112, 150, 56, "broker ×4", ["telemetry＋JMX"], "blue"),
  box(24, 184, 150, 56, "REST Proxy ×2", ["只有 JMX"], "blue"),
  box(24, 256, 150, 56, "Control Center", ["只有 JMX"], "blue"),
  box(268, 50, 250, 76, "Telemetry（原本就有）", ["主動推 OTLP，只有 node id", "約 12 萬條"], "purple"),
  box(268, 220, 250, 76, "JMX exporter（本方案）", ["每 30 秒去抓 7071，有 hostname", "只留規則用的，約 1,000 條"], "teal"),
  // telemetry (purple): pushed by controller and broker
  arrow(174, 56, 266, 76, null, { color: "#534AB7" }), arrow(174, 128, 266, 100, null, { color: "#534AB7" }),
  // JMX (teal): every box joins one bus that feeds the exporter box
  `<path d="M174 82 H214 M174 154 H214 M174 212 H214 M174 284 H214 M214 82 V284" fill="none" stroke="#0F6E56" stroke-width="2.5"/>`,
  arrow(214, 258, 266, 258, null, { color: "#0F6E56" }),
  ctext(220, 34, "紫：主動推", { size: 11, fill: "#534AB7", anchor: "start" }),
  ctext(220, 320, "綠：Prometheus 去抓", { size: 11, fill: "#0F6E56", anchor: "start" }),
  box(586, 130, 150, 90, "C3 內建", ["Prometheus", "（c3-01）"], "gray"),
  arrow(518, 88, 584, 160), arrow(518, 258, 584, 190),
  box(770, 60, 116, 60, "C3 畫面", ["與 C3 trigger"], "purple"),
  box(770, 230, 116, 60, "26 條規則", ["送 omnibus"], "teal"),
  arrow(736, 160, 768, 90), arrow(736, 190, 768, 260),
  ctext(450, 340, "兩邊指標名稱不同（io_confluent_… vs kafka_…），規則限定 job，不會互相干擾", { size: 12 }),
].join(""));

// One host: how the exporter is attached
C.exporter = () => svg(900, 380, [
  region(16, 14, 620, 352, "一台主機（例：kb01）", "blue"),
  box(36, 54, 240, 70, "40-jmx.conf（systemd drop-in）", ["在服務的環境變數加 -javaagent"], "gray"),
  box(36, 146, 240, 70, "jmx-exporter.env（root 0600）", ["keystore 密碼"], "coral"),
  box(36, 238, 240, 70, "jmx-exporter.yml（0640）", ["HTTPS 設定＋指標規則"], "gray"),
  box(330, 120, 280, 96, "confluent-server（Java）", ["JVM 裡掛 JMX exporter 1.7.0", "讀 MBean，轉成 Prometheus 指標"], "blue"),
  arrow(276, 89, 328, 140), arrow(276, 181, 328, 168), arrow(276, 273, 328, 196),
  box(400, 268, 140, 62, ":7071", ["HTTPS（這台的憑證）"], "teal"),
  arrow(470, 216, 470, 266),
  box(690, 262, 190, 74, "C3 內建 Prometheus", ["c3-01", "只驗伺服器憑證"], "teal"),
  arrow(688, 299, 542, 299),
  ctext(780, 200, "防火牆只放行 c3-01", { size: 12, fill: "#712B13" }),
  ctext(780, 90, "controller、REST Proxy、C3", { size: 12 }),
  ctext(780, 110, "同樣的做法，", { size: 12 }),
  ctext(780, 130, "只是環境變數與憑證不同", { size: 12 }),
].join(""));

// Series kept per job (lab numbers)
C.funnel = () => {
  const rows = [
    ["kafka-broker（4 台）", "約 54,400 條", "689 條"],
    ["kafka-controller（3 台）", "約 3,200 條", "60 條"],
    ["rest-proxy（2 台）", "約 3,000 條", "188 條"],
    ["control-center（1 台）", "約 2,100 條", "55 條"],
  ];
  const out = [
    ctext(150, 26, "job", { bold: true, size: 13 }), ctext(400, 26, "exporter 吐出的", { bold: true, size: 13 }),
    ctext(760, 26, "C3 留下的", { bold: true, size: 13 }),
  ];
  rows.forEach(([job, before, after], i) => {
    const y = 48 + i * 66;
    out.push(box(30, y, 240, 52, job, [], "blue"));
    out.push(box(300, y, 200, 52, before, [], "gray"));
    out.push(arrow(500, y + 26, 680, y + 26, i === 0 ? "metric_relabel：只留規則用的" : null));
    out.push(box(682, y, 160, 52, after, [], "teal"));
  });
  return svg(880, 320, out.join(""));
};

// One rule file, two destinations
C.rulesource = () => svg(900, 340, [
  box(24, 130, 250, 84, "confluent-alerts.yml", ["26 條規則（只維護這一份）", "操作機產生"], "purple"),
  box(360, 30, 230, 70, "交給銀行", ["原封不動"], "amber"),
  box(650, 30, 226, 70, "銀行的 Prometheus", ["銀行有 Prometheus 時"], "amber"),
  box(360, 240, 230, 76, "sed：每個群組加兩行", ["labels:", "  target: omnibus"], "gray"),
  box(650, 240, 226, 76, "custom-rules-confluent.yml", ["c3-01，root:confluent 0640", "C3 內建 Prometheus 讀它"], "teal"),
  arrow(274, 150, 358, 66), arrow(590, 65, 648, 65),
  arrow(274, 194, 358, 278), arrow(590, 278, 648, 278),
  ctext(612, 170, "規則一改，就重新產生 c3-01 那份並重啟 Prometheus", { size: 12 }),
].join(""));

// The white-list split: keep on one Alertmanager, drop on the other
C.split = () => svg(900, 360, [
  box(20, 50, 210, 76, "我們的規則觸發", ["帶 target: omnibus"], "teal"),
  box(20, 230, 210, 76, "C3 畫面的 trigger 觸發", ["沒有 target"], "gray"),
  box(330, 50, 230, 76, "往第二台", ["keep target=omnibus"], "purple"),
  box(330, 230, 230, 76, "往 C3 內建", ["drop target=omnibus"], "purple"),
  arrow(230, 88, 328, 88, "通過", { lx: 279, ly: 78 }),
  arrow(230, 268, 328, 268, "通過", { lx: 279, ly: 258 }),
  arrow(230, 100, 328, 248, "丟掉", { dash: true, color: "#B4B2A9", lx: 300, ly: 150 }),
  arrow(230, 256, 328, 108, "丟掉", { dash: true, color: "#B4B2A9", lx: 300, ly: 214 }),
  box(640, 50, 240, 76, "第二個 Alertmanager", ["→ omnibus（行內 JSON）"], "coral"),
  box(640, 230, 240, 76, "C3 內建 Alertmanager", ["→ C3 action（預設格式）"], "gray"),
  arrow(560, 88, 638, 88), arrow(560, 268, 638, 268),
  ctext(450, 340, "白名單：沒有標籤就不會進 omnibus；忘了加標籤不會報錯，所以由規則群組統一加", { size: 12 }),
].join(""));

// Alert labels and annotations -> omnibus fields
C.omnibusmap = () => {
  const rows = [
    ["status：firing／resolved", "state：OPEN／RESOLVED"],
    ["severity：critical／warning", "severity：ERROR／PERFORMANCE"],
    ["impact：SERVICE…", "msg_catalog"],
    ["description（完整說明）", "msg"],
    ["alertname＋summary", "sub_origin"],
    ["hostname（沒有就用 env）", "hostname"],
    ["（固定值）", "source、ClassName、sub_source、origin"],
  ];
  const out = [
    ctext(170, 22, "告警（規則的 labels、annotations）", { bold: true, size: 13 }),
    ctext(700, 22, "omnibus 的 JSON 欄位", { bold: true, size: 13 }),
  ];
  rows.forEach(([from, to], i) => {
    const y = 38 + i * 46;
    out.push(box(30, y, 280, 36, from, [], i === 6 ? "gray" : "teal"));
    out.push(arrow(310, y + 18, 538, y + 18, i === 0 ? "Alertmanager 範本＋toJson" : null));
    out.push(box(540, y, 330, 36, to, [], "coral"));
  });
  return svg(900, 370, out.join(""));
};

// Files and services on c3-01: ours vs C3's
C.files = () => svg(900, 370, [
  region(16, 14, 430, 300, "我們的（root 擁有，C3 只能讀）", "teal"),
  box(36, 52, 390, 52, "prometheus-generated.yml", [], "teal"),
  box(36, 116, 390, 52, "custom-rules-confluent.yml", [], "teal"),
  box(36, 180, 390, 52, "alertmanager-custom/alertmanager.yml", [], "teal"),
  box(36, 244, 390, 52, "alertmanager-custom.service", [], "teal"),
  region(470, 14, 414, 300, "C3 自己的（C3 會改寫）", "gray"),
  box(490, 52, 374, 52, "trigger_rules-generated.yml", [], "gray"),
  box(490, 116, 374, 52, "recording_rules-generated.yml", [], "gray"),
  box(490, 180, 374, 52, "內建 Alertmanager 設定", [], "gray"),
  box(490, 244, 374, 52, "confluent-control-center 服務", [], "gray"),
  ctext(450, 344, "C3 從 2.5.1 升到 2.6.1，我們的檔雜湊不變；C3 的檔不能手改（會被蓋掉）", { size: 12 }),
].join(""));

// Where the 26 rules come from
C.rulesources = () => svg(900, 360, [
  box(20, 30, 290, 66, "Confluent jmx-monitoring-stacks", ["官方規則，修正後採用：6 條"], "blue"),
  box(20, 112, 290, 66, "Confluent 文件", ["Monitor Kafka、KRaft metrics：5 條"], "blue"),
  box(20, 194, 290, 66, "我方建議", ["官方沒有的元件與主機層：15 條"], "teal"),
  box(400, 100, 170, 90, "26 條規則", ["每條都有 lab 上", "真的存在的指標"], "purple"),
  arrow(310, 63, 398, 125), arrow(310, 145, 398, 145), arrow(310, 227, 398, 165),
  box(20, 284, 290, 60, "Strimzi、Grafana、awesome", ["社群規則：只拿來交叉比對"], "gray"),
  arrow(310, 300, 398, 180, "比對", { dash: true, lx: 372, ly: 252 }),
  box(660, 30, 220, 66, "採用 2 條", ["Fenced broker、log dir 離線", "（與 Strimzi 等價）"], "teal"),
  box(600, 194, 280, 66, "嚴重度", ["critical 9 條（服務已受影響）", "warning 17 條（需要注意）"], "coral"),
  arrow(570, 165, 598, 220),
  ctext(770, 130, "原則：門檻要說得出理由，", { size: 12 }),
  ctext(770, 150, "不重複告警", { size: 12 }),
].join(""));

// What the 26 rules cover
C.ruleoverview = () => {
  const cats = [
    ["可用性與主機", "6 條", ["服務停了（抓不到）", "主機 CPU、log dir 離線", "JVM：heap、fd、死結"], "coral"],
    ["controller 與 KRaft", "7 條", ["活躍 controller ≠ 1", "offline、unclean、fenced", "metadata 落後與錯誤"], "blue"],
    ["broker", "6 條", ["副本沒同步、低於 min ISR", "ISR 縮了沒回來", "執行緒太忙、寫入延遲"], "blue"],
    ["REST Proxy", "2 條", ["錯誤率", "執行緒池快滿"], "teal"],
    ["Control Center", "5 條", ["不在 RUNNING、執行緒掛了", "不再處理、儲存錯誤", "丟棄資料"], "purple"],
  ];
  const out = [];
  cats.forEach(([name, count, lines, color], i) => {
    const x = 20 + i * 176;
    out.push(box(x, 30, 164, 64, name, [count], color));
    lines.forEach((l, j) => out.push(ctext(x + 82, 124 + j * 24, l, { size: 12 })));
  });
  out.push(box(20, 216, 868, 50, "嚴重度：critical 9 條（服務已受影響），warning 17 條（需要注意）", [], "gray"));
  out.push(box(20, 280, 868, 50, "每條都帶 severity、impact、summary、description，omnibus 的欄位都從這裡來", [], "gray"));
  return svg(900, 350, out.join(""));
};

// Every connection and how it is protected
C.security = () => svg(900, 380, [
  box(20, 60, 160, 70, "10 台的 7071", ["JMX exporter"], "blue"),
  box(20, 262, 160, 70, "操作機 ops02", ["維運檢查"], "gray"),
  region(300, 14, 390, 330, "c3-01", "teal"),
  box(320, 56, 350, 76, "C3 內建 Prometheus :9090", [], "teal"),
  box(345, 214, 150, 70, "內建 AM :9093", ["C3 自己的"], "gray"),
  box(515, 214, 150, 70, "第二台 :9193", [], "coral"),
  box(730, 214, 150, 70, "omnibus", ["行內事件系統"], "coral"),
  // Prometheus pulls from the hosts
  arrow(318, 94, 182, 94),
  ctext(240, 78, "HTTPS", { size: 11 }),
  // Prometheus pushes alerts to the two Alertmanagers
  arrow(420, 132, 420, 212),
  ctext(428, 172, "svc-c3 憑證", { size: 11, anchor: "start" }),
  arrow(590, 132, 590, 212),
  // ops02 queries Prometheus
  arrow(180, 297, 330, 134, null, { via: [[330, 297]] }),
  ctext(250, 284, "client 憑證（svc-ops）", { size: 11 }),
  // second Alertmanager posts to omnibus
  arrow(665, 249, 728, 249),
  ctext(697, 234, "依銀行規定", { size: 11 }),
  ctext(450, 366, "設定檔裡沒有密碼；換憑證時第二台不用處理", { size: 12 }),
].join(""));

// The stop test on a time line (lab, approximate minutes)
C.timeline = () => {
  const x0 = 100, x1 = 860, minutes = 12;
  const at = (m) => x0 + (x1 - x0) * m / minutes;
  const out = [`<line x1="${x0}" y1="138" x2="${x1}" y2="138" stroke="#888780" stroke-width="2"/>`];
  for (let m = 0; m <= minutes; m += 2) {
    out.push(`<line x1="${at(m)}" y1="132" x2="${at(m)}" y2="144" stroke="#888780" stroke-width="2"/>`);
    out.push(ctext(at(m), 160, `${m} 分`, { size: 11 }));
  }
  const ev = [
    [0, "停 kb04、kc03", "", "gray", "up"],
    [2.5, "OPEN", "抓不到 ×2", "coral", "down"],
    [6, "OPEN", "URP、fenced", "coral", "up"],
    [7, "開回來", "", "gray", "down"],
    [9, "RESOLVED", "URP、fenced", "teal", "up"],
    [10.5, "RESOLVED", "抓不到 ×2", "teal", "down"],
  ];
  ev.forEach(([m, t, s, color, side], i) => {
    const x = at(m);
    const y = side === "up" ? 18 : 188;
    out.push(`<line x1="${x}" y1="${side === "up" ? y + 58 : 138}" x2="${x}" y2="${side === "up" ? 138 : y}" stroke="#B4B2A9" stroke-width="1.5" stroke-dasharray="4 3"/>`);
    out.push(box(x - 62, y, 124, 58, t, s ? [s] : [], color));
    out.push(num(x, 138, String(i + 1), color === "gray" ? "teal" : color));
  });
  out.push(ctext(460, 274, "8 筆通知的 10 個欄位都是字串；exporter 在服務啟動後約 2 分鐘才回應，所以「抓不到」最後解除", { size: 12 }));
  return svg(920, 292, out.join(""));
};

// ---- What the metrics measure: each metric drawn where it is measured, with its alert rule and threshold ----
// Source of every rule (also used for the "# 出處" lines of the rule appendix)
const RULE_SOURCES = {
  ConfluentTargetDown: "官方（修正）",
  KafkaHostCpuHigh: "我方",
  KafkaLogDirOffline: "我方",
  JvmHeapHigh: "我方",
  JvmFileDescriptorsHigh: "我方",
  JvmThreadsDeadlocked: "我方",
  KafkaActiveControllerCountNotOne: "官方（修正）",
  KafkaOfflinePartitions: "官方",
  KafkaUncleanLeaderElections: "官方（修正）",
  KafkaFencedBrokers: "Confluent 文件",
  KRaftControllerMetadataLag: "我方",
  KRaftMetadataErrors: "我方",
  KRaftLeaderFlapping: "我方",
  KafkaUnderReplicatedPartitions: "官方（修正）",
  KafkaUnderMinIsrPartitions: "官方",
  KafkaIsrShrinkingWithoutExpand: "Confluent 文件",
  KafkaRequestHandlerBusy: "Confluent 文件",
  KafkaNetworkProcessorBusy: "Confluent 文件",
  KafkaProduceLatencyHigh: "Confluent 文件",
  RestProxyErrors: "我方",
  RestProxyThreadPoolBusy: "我方",
  ControlCenterStreamsNotRunning: "我方",
  ControlCenterStreamThreadsFailed: "我方",
  ControlCenterStreamsStalled: "我方",
  ControlCenterRocksDBBackgroundErrors: "我方",
  ControlCenterDroppedRecords: "我方",
};
const rule = (name) => {
  if (!RULE_SOURCES[name]) {
    throw new Error("no source for rule " + name);
  }
  return `${name}｜${RULE_SOURCES[name]}`;
};
// A metric tag: metric name, the alert condition, the rule and its source
function tag(x, y, w, name, cond, ruleName, color = "amber") {
  return box(x, y, w, 58, name, [cond, rule(ruleName)], color);
}
const PTR = { dash: true, color: "#BA7517" };

// KRaft control plane: the quorum and the metadata it hands to the brokers
C.mkraft = () => svg(900, 400, [
  region(16, 14, 430, 250, "KRaft quorum（controller ×3）", "blue"),
  box(40, 56, 120, 64, "kc01", ["active（leader）"], "blue"),
  box(176, 56, 120, 64, "kc02", ["follower"], "gray"),
  box(312, 56, 120, 64, "kc03", ["follower"], "gray"),
  box(40, 160, 392, 50, "metadata log", ["topic、partition、broker 註冊…每個變更一筆紀錄"], "blue"),
  arrow(100, 120, 100, 158), arrow(236, 120, 236, 158), arrow(372, 120, 372, 158),
  region(16, 284, 430, 102, "broker ×4（從 controller 拿 metadata）", "teal"),
  box(36, 316, 90, 50, "kb01", [], "teal"), box(140, 316, 90, 50, "kb02", [], "teal"),
  box(244, 316, 90, 50, "kb03", [], "teal"),
  box(348, 316, 90, 50, "kb04", ["fenced"], "coral", { dash: true }),
  arrow(236, 210, 236, 314, null, { dash: true }),
  tag(480, 14, 400, "activecontrollercount", "全叢集加總 ≠ 1（沒有 leader 或分裂），1 分鐘", "KafkaActiveControllerCountNotOne"),
  tag(480, 78, 400, "newactivecontrollerscount", "leader 換手：15 分鐘 > 2 次", "KRaftLeaderFlapping"),
  tag(480, 142, 400, "lastappliedrecordlagms", "套用 metadata 落後 > 30 秒，5 分鐘", "KRaftControllerMetadataLag"),
  tag(480, 206, 400, "metadataerrorcount", "套用 metadata 出錯 > 0，1 分鐘", "KRaftMetadataErrors"),
  tag(480, 312, 400, "fencedbrokercount", "被隔離的 broker > 0，5 分鐘", "KafkaFencedBrokers"),
  arrow(478, 43, 448, 43, null, PTR), arrow(478, 107, 448, 107, null, PTR),
  arrow(478, 171, 434, 182, null, PTR), arrow(478, 235, 434, 200, null, PTR),
  arrow(478, 341, 440, 341, null, PTR),
].join(""));

// Replication: one partition, its leader, its followers and the in-sync set
C.mreplica = () => svg(900, 366, [
  region(16, 14, 470, 300, "partition orders-0（replication factor 3、min.insync.replicas 2）", "teal"),
  box(40, 64, 130, 70, "kb01", ["leader", "收寫入"], "teal"),
  box(196, 64, 130, 70, "kb02", ["follower", "跟上了 → 在 ISR"], "teal"),
  box(352, 64, 120, 70, "kb03", ["follower", "落後 → 離開 ISR"], "coral", { dash: true }),
  arrow(170, 99, 194, 99), arrow(326, 99, 350, 99, null, { dash: true }),
  `<rect x="34" y="150" width="298" height="40" rx="8" fill="none" stroke="#0F6E56" stroke-width="2"/>`,
  ctext(183, 170, "ISR（同步中的副本）= kb01、kb02", { size: 12, fill: "#085041", bold: true }),
  box(40, 214, 200, 76, "資料盤 /var/lib/kafka", ["壞掉或滿了 → log dir 離線", "這台的 partition 換 leader"], "gray"),
  box(262, 214, 210, 76, "沒有 leader 時", ["partition 不能讀寫（offline）", "從落後的副本選 = unclean"], "coral"),
  tag(510, 14, 370, "underreplicatedpartitions", "ISR 比副本少 > 0，5 分鐘", "KafkaUnderReplicatedPartitions"),
  tag(510, 76, 370, "underminisr", "ISR < min.insync（acks=all 寫不進去），1 分鐘", "KafkaUnderMinIsrPartitions", "coral"),
  tag(510, 138, 370, "isrshrinkspersec / isrexpandspersec", "15 分鐘內只縮不擴", "KafkaIsrShrinkingWithoutExpand"),
  tag(510, 214, 370, "logdirectoryoffline", "資料目錄離線 > 0，1 分鐘", "KafkaLogDirOffline", "coral"),
  box(510, 276, 370, 74, "offlinepartitionscount / uncleanleaderelections", ["沒有 leader > 0，1 分鐘；unclean 10 分鐘內有增加",
    rule("KafkaOfflinePartitions"), rule("KafkaUncleanLeaderElections")], "coral"),
  arrow(508, 43, 334, 164, null, Object.assign({ via: [[494, 43], [494, 164]] }, PTR)),
  arrow(508, 105, 334, 178, null, Object.assign({ via: [[500, 105], [500, 178]] }, PTR)),
  arrow(508, 167, 474, 110, null, PTR),
  arrow(508, 243, 140, 292, null, Object.assign({ via: [[490, 243], [490, 302], [140, 302]] }, PTR)),
  arrow(508, 313, 474, 262, null, PTR),
].join(""));

// Rule name and source on two lines, for the narrower boxes
const ruleLines2 = (name) => {
  rule(name);
  return [name, "出處：" + RULE_SOURCES[name]];
};

// Request path inside a broker: where time and threads go
C.mrequest = () => svg(900, 440, [
  box(20, 90, 110, 70, "producer", ["acks=all"], "gray"),
  region(150, 20, 730, 220, "一台 broker 處理一個 Produce 請求", "blue"),
  box(170, 90, 140, 70, "network threads", ["收請求、回結果"], "blue"),
  box(330, 90, 110, 70, "request", ["queue"], "gray"),
  box(460, 90, 150, 70, "request handler", ["寫入 log"], "blue"),
  box(630, 90, 230, 70, "等 follower 複製", ["acks=all 要 ISR 都寫到"], "teal"),
  arrow(130, 125, 168, 125), arrow(310, 125, 328, 125), arrow(440, 125, 458, 125), arrow(610, 125, 628, 125),
  `<path d="M745 160 V200 H240 V162" fill="none" stroke="#444441" stroke-width="2.5" marker-end="url(#a)"/>`,
  ctext(492, 214, "回應：從收到到送出，這段總時間就是 totaltimems", { size: 12 }),
  box(20, 256, 280, 82, "networkprocessoravgidlepercent", ["閒置 < 30%，10 分鐘", ...ruleLines2("KafkaNetworkProcessorBusy")], "amber"),
  box(310, 256, 280, 82, "requesthandleravgidlepercent", ["閒置 < 30%，10 分鐘", ...ruleLines2("KafkaRequestHandlerBusy")], "amber"),
  box(600, 256, 280, 98, "totaltimems（Produce p99）", ["> 500 ms，10 分鐘", "且 requestspersec > 1 才判斷", ...ruleLines2("KafkaProduceLatencyHigh")], "coral"),
  arrow(160, 254, 236, 162, null, PTR),
  arrow(450, 254, 530, 162, null, PTR),
  arrow(740, 254, 745, 226, null, PTR),
  box(20, 364, 570, 66, "主機 CPU（linux_system_cpu_utilization_1m）", ["> 80%，10 分鐘（controller 也看）", rule("KafkaHostCpuHigh")], "amber"),
].join(""));

// REST Proxy, Control Center and every JVM
C.mapps = () => svg(900, 480, [
  region(16, 14, 280, 286, "REST Proxy ×2", "teal"),
  box(36, 50, 240, 88, "Jetty 執行緒池", ["thread_pool_usage > 90%，10 分鐘", ...ruleLines2("RestProxyThreadPoolBusy")], "teal"),
  box(36, 150, 240, 88, "回應的錯誤率", ["4xx＋5xx > 1 次／秒，10 分鐘", ...ruleLines2("RestProxyErrors")], "teal"),
  ctext(156, 272, "停掉 → 抓不到（見下方 up）", { size: 12 }),
  region(312, 14, 572, 286, "Control Center（Kafka Streams 程式）", "purple"),
  box(332, 50, 262, 88, "Streams client 狀態", ["不是 RUNNING，15 分鐘", ...ruleLines2("ControlCenterStreamsNotRunning")], "purple"),
  box(608, 50, 262, 88, "stream threads 的 poll", ["poll_rate = 0 = 卡住，10 分鐘", ...ruleLines2("ControlCenterStreamsStalled")], "purple"),
  box(332, 148, 262, 88, "掛掉的 threads", ["failed_stream_threads 15 分鐘內增加", ...ruleLines2("ControlCenterStreamThreadsFailed")], "purple"),
  box(608, 148, 262, 88, "RocksDB 本地儲存", ["background_errors 15 分鐘內增加", ...ruleLines2("ControlCenterRocksDBBackgroundErrors")], "purple"),
  box(332, 246, 538, 46, "丟棄的監控資料：dropped_records_rate > 0，10 分鐘", [rule("ControlCenterDroppedRecords")], "purple"),
  region(16, 316, 868, 150, "每一個 Java 程序（10 台都有）", "coral"),
  box(36, 350, 196, 102, "抓得到嗎", ["up = 0，2 分鐘", "服務或主機停了", ...ruleLines2("ConfluentTargetDown")], "coral"),
  box(248, 350, 196, 102, "Java 記憶體", ["heap used／max", "> 90%，10 分鐘", ...ruleLines2("JvmHeapHigh")], "coral"),
  box(460, 350, 196, 102, "可開檔案數", ["open／max fds", "> 80%，10 分鐘", ...ruleLines2("JvmFileDescriptorsHigh")], "coral"),
  box(672, 350, 196, 102, "執行緒死結", ["jvm_threads_deadlocked", "> 0，5 分鐘", ...ruleLines2("JvmThreadsDeadlocked")], "coral"),
].join(""));

Object.defineProperty(C, "_sources", { value: RULE_SOURCES });

module.exports = C;
