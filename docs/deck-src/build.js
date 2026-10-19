// Builds the PoC presentation (.pptx). Usage: node build.js <output.pptx>
const PptxGenJS = require("pptxgenjs");
const out = process.argv[2] || "deck.pptx";

const pptx = new PptxGenJS();
pptx.layout = "LAYOUT_WIDE"; // 13.33 x 7.5 in
pptx.title = "Confluent Platform 8.3 企業版離線安裝 PoC";
pptx.author = "PoC 團隊";

// ---- design tokens
const C = {
  ink: "17213A", body: "3D4659", mute: "6B7385", line: "D9DCE3",
  bg: "F7F7F4", card: "FFFFFF", dark: "17213A",
  accent: "D9661F", accentSoft: "FBEADF", teal: "1F7A8C", tealSoft: "E1F0F3", ok: "2E7D4F",
};
const F = "Microsoft JhengHei";
const W = 13.33, M = 0.6; // margins
let page = 0;

function base(section) {
  const s = pptx.addSlide();
  s.background = { color: C.bg };
  page += 1;
  if (section) {
    s.addText(section, { x: M, y: 7.0, w: 8, h: 0.3, fontFace: F, fontSize: 11, color: C.mute });
  }
  s.addText(String(page), { x: W - M - 1, y: 7.0, w: 1, h: 0.3, fontFace: F, fontSize: 11, color: C.mute, align: "right" });
  return s;
}

function title(s, t, sub) {
  s.addText(t, { x: M, y: 0.35, w: W - 2 * M, h: 0.75, fontFace: F, fontSize: 28, bold: true, color: C.ink, valign: "middle" });
  if (sub) s.addText(sub, { x: M, y: 1.05, w: W - 2 * M, h: 0.45, fontFace: F, fontSize: 16, color: C.mute, valign: "top" });
  s.addShape(pptx.ShapeType.rect, { x: M, y: 1.55, w: 0.9, h: 0.06, fill: { color: C.accent }, line: { color: C.accent } });
}

function card(s, x, y, w, h, head, bodyText, opt = {}) {
  s.addShape(pptx.ShapeType.roundRect, {
    x, y, w, h, rectRadius: 0.08, fill: { color: opt.fill || C.card }, line: { color: opt.lineColor || C.line, width: 1 },
  });
  if (opt.bar) s.addShape(pptx.ShapeType.rect, { x, y: y + 0.12, w: 0.07, h: h - 0.24, fill: { color: opt.bar }, line: { color: opt.bar } });
  s.addText(head, { x: x + 0.22, y: y + 0.12, w: w - 0.4, h: 0.45, fontFace: F, fontSize: opt.headSize || 17, bold: true, color: opt.headColor || C.ink, valign: "top" });
  if (bodyText) {
    s.addText(bodyText, { x: x + 0.22, y: y + 0.58, w: w - 0.4, h: h - 0.7, fontFace: F, fontSize: opt.bodySize || 13, color: C.body, valign: "top", lineSpacingMultiple: 1.15 });
  }
}

function table(s, rows, opt) {
  const head = rows[0].map((t) => ({ text: t, options: { bold: true, color: "FFFFFF", fill: { color: C.dark } } }));
  const body = rows.slice(1).map((r, i) => r.map((t, j) => ({
    text: t, options: { fill: { color: i % 2 ? "FFFFFF" : "F1F2F5" }, bold: j === 0 && opt.firstBold !== false, color: j === 0 ? C.ink : C.body },
  })));
  s.addTable([head, ...body], {
    x: opt.x ?? M, y: opt.y ?? 1.85, w: opt.w ?? W - 2 * M, colW: opt.colW, fontFace: F, fontSize: opt.fontSize || 13,
    border: { type: "solid", pt: 0.5, color: C.line }, valign: "middle", margin: 0.06, rowH: opt.rowH,
  });
}

function section(no, name, line) {
  const s = pptx.addSlide();
  page += 1;
  s.background = { color: C.dark };
  s.addText(no, { x: M, y: 2.2, w: 3, h: 1.2, fontFace: F, fontSize: 66, bold: true, color: C.accent });
  s.addText(name, { x: M, y: 3.4, w: 11, h: 0.9, fontFace: F, fontSize: 36, bold: true, color: "FFFFFF" });
  s.addText(line, { x: M, y: 4.3, w: 11, h: 0.6, fontFace: F, fontSize: 18, color: "C9CFDB" });
  s.addText(String(page), { x: W - M - 1, y: 7.0, w: 1, h: 0.3, fontFace: F, fontSize: 11, color: "8C94A6", align: "right" });
  return s;
}

function chevrons(s, items, y, h, opt = {}) {
  const n = items.length, gap = 0.08, w = (W - 2 * M - gap * (n - 1)) / n;
  items.forEach((it, i) => {
    const x = M + i * (w + gap);
    s.addShape(i === 0 ? pptx.ShapeType.homePlate : pptx.ShapeType.chevron, {
      x, y, w, h, fill: { color: it.hi ? C.accent : (opt.fill || C.teal) }, line: { color: "FFFFFF", width: 0 },
    });
    s.addText(it.t, { x: x + (i === 0 ? 0.05 : 0.25), y, w: w - (i === 0 ? 0.3 : 0.5), h, margin: 0, fontFace: F, fontSize: opt.size || 14, bold: true, color: "FFFFFF", align: "center", valign: "middle" });
    if (it.d) s.addText(it.d, { x, y: y + h + 0.12, w, h: opt.dh || 2.4, fontFace: F, fontSize: opt.dsize || 12, color: C.body, valign: "top", lineSpacingMultiple: 1.15 });
  });
}

// takeaway band at the bottom of a content slide
function band(s, text, y = 5.75, h = 0.9) {
  s.addShape(pptx.ShapeType.roundRect, { x: M, y, w: W - 2 * M, h, rectRadius: 0.08, fill: { color: C.tealSoft }, line: { color: C.tealSoft } });
  s.addText(text, { x: M + 0.3, y, w: W - 2 * M - 0.6, h, fontFace: F, fontSize: 16, bold: true, color: C.teal, valign: "middle" });
}

// measured numbers: DECK_NUMBERS env, else numbers.json next to this file
const fs = require("fs");
const numFile = require("path").join(__dirname, "numbers.json");
const NUM = JSON.parse(process.env.DECK_NUMBERS || (fs.existsSync(numFile) ? fs.readFileSync(numFile, "utf8") : "{}"));
const idem = NUM.idem || "changed=0";
const VERIFY_TOTAL = NUM.verifyTotal || "37";
// OP menu test results (filled from cpctl verify output)
const OPMENU_ROWS = NUM.opmenuRows || [["(待驗證)", "—"]];

// ===================================================================== 1 cover
{
  const s = pptx.addSlide();
  page += 1;
  s.background = { color: C.dark };
  s.addShape(pptx.ShapeType.rect, { x: 0, y: 0, w: 0.25, h: 7.5, fill: { color: C.accent }, line: { color: C.accent } });
  s.addText("Confluent Platform 8.3 企業版", { x: 0.9, y: 2.0, w: 11.5, h: 0.8, fontFace: F, fontSize: 24, color: "C9CFDB" });
  s.addText("離線安裝 PoC：從零到上線的完整流程", { x: 0.9, y: 2.8, w: 11.5, h: 1.2, fontFace: F, fontSize: 40, bold: true, color: "FFFFFF" });
  s.addText("需求與決策 · 離線引進 · 自動化安裝 · 安全 · 營運強化 · 日常維運 · 驗證演練 · 上線準備", { x: 0.9, y: 4.1, w: 11.5, h: 0.5, fontFace: F, fontSize: 16, color: "C9CFDB" });
  s.addText("2026-10-16", { x: 0.9, y: 6.4, w: 4, h: 0.4, fontFace: F, fontSize: 14, color: "8C94A6" });
  s.addNotes("本簡報說明這次 PoC 從需求確認到安裝完成、再到正式營運準備的所有工作項目。重點不在指令細節，而是流程完整、每一步都有驗證。");
}

// ===================================================================== 2 executive summary
{
  const s = base("摘要");
  title(s, "結論：離線、全自動、可重跑、可升級的安裝流程已驗證可行", "以 Docker 模擬 15 台銀行主機（含堡壘機與 repo web server），所有安裝都由操作機上的 cpctl 經 SSH 完成");
  const k = [
    ["12 步", "一個指令完成安裝", "cpctl install\n執行步驟 00–11\n失敗可從中斷處續跑"],
    [VERIFY_TOTAL + " / " + VERIFY_TOTAL, "端到端驗證通過", "quorum、mTLS、SCRAM、RBAC\nAD、REST、C3、稽核\n監控、憑證、配額、OP menu"],
    ["0 筆", "演練遺失訊息", "升級、CA 輪替、銀行 CA\nbroker 擴縮、OS 修補\n全在持續流量下\n逐筆核對"],
    [idem, "重跑零變更", "在已安裝環境再跑一次\ninstall --force"],
  ];
  const w = (W - 2 * M - 0.3 * 3) / 4;
  k.forEach((v, i) => {
    const x = M + i * (w + 0.3);
    s.addShape(pptx.ShapeType.roundRect, { x, y: 2.0, w, h: 3.4, rectRadius: 0.08, fill: { color: C.card }, line: { color: C.line } });
    s.addText(v[0], { x, y: 2.2, w, h: 1.1, fontFace: F, fontSize: v[0].length > 8 ? 30 : 44, bold: true, color: C.accent, align: "center", valign: "middle" });
    s.addText(v[1], { x: x + 0.2, y: 3.35, w: w - 0.4, h: 0.5, fontFace: F, fontSize: 17, bold: true, color: C.ink, align: "center" });
    s.addText(v[2], { x: x + 0.25, y: 3.9, w: w - 0.5, h: 1.3, fontFace: F, fontSize: 13, color: C.body, align: "center", valign: "top" });
  });
  s.addShape(pptx.ShapeType.roundRect, { x: M, y: 5.75, w: W - 2 * M, h: 0.85, rectRadius: 0.08, fill: { color: C.tealSoft }, line: { color: C.tealSoft } });
  s.addText("搬到真實主機：只需修改 installer/conf/*.env（主機、網段、版本、帳號），程式碼不變", { x: M + 0.3, y: 5.75, w: W - 2 * M - 0.6, h: 0.85, fontFace: F, fontSize: 17, bold: true, color: C.teal, valign: "middle" });
  s.addNotes("四個數字：一個指令、全部驗證通過、演練零遺失、重跑零變更。最後一點是銀行最關心的：PoC 的腳本可以直接帶到正式環境，只改設定檔。");
}

// ===================================================================== 3 flow map
{
  const s = base("流程總覽");
  title(s, "全流程共九個階段，本簡報依序說明", "每個階段的產出都會成為下一階段的輸入，並且各自有驗證");
  chevrons(s, [
    { t: "1 需求決策", d: "拓樸、版本、安全" },
    { t: "2 環境模擬", d: "容器、無外網" },
    { t: "3 離線引進", d: "驗證、內部 repo" },
    { t: "4 自動安裝", d: "cpctl 00–11" },
    { t: "5 安全權限", d: "PKI、AD、RBAC" },
  ], 1.95, 0.75, { size: 15, dsize: 14, dh: 0.9 });
  chevrons(s, [
    { t: "6 營運強化", d: "加密、稽核、監控、OS" },
    { t: "7 日常維運", d: "堡壘機 OP menu" },
    { t: "8 驗證演練", d: VERIFY_TOTAL + " 項驗證、零遺失" },
    { t: "9 上線準備", d: "差異、風險、待提供", hi: true },
  ], 3.85, 0.75, { size: 16, dsize: 14, dh: 0.9 });
  band(s, "1–5 把叢集裝起來；6 補齊營運設定；7 讓日常維運可控管；8 證明它可靠；9 帶到正式環境前要討論的事", 5.8, 0.85);
  s.addNotes("九個階段。1–5 是把叢集裝起來；6 是對照官方文件補齊正式營運需要的設定；7 是堡壘機上的維運選單，讓固定帳號環境也能控管；8 是證明它可靠；9 是要帶到銀行正式環境前需要討論的事。");
}

// ===================================================================== section 1
section("01", "需求與關鍵決策", "先把拓樸、版本、安全模型和安裝方式定下來");

{
  const s = base("01 需求與決策");
  title(s, "目標：在銀行離線環境，用腳本安裝完整的企業版叢集", "PoC 不只是裝起來，而是在模擬的銀行限制下證明流程可行");
  table(s, [
    ["面向", "需求", "PoC 的做法"],
    ["拓樸", "controller ×3、broker ×4、REST Proxy ×2 + LB、C3 Next Gen ×1、操作機 ×1", "Docker 容器模擬，每台跑 systemd，與實體機一致"],
    ["離線", "部署機不能連外網", "除 LB 之外全部在 internal 網段；驗證時實測連外必定失敗"],
    ["版本", "最新版，且要有升級機制", "CP 8.3.2、C3 2.6.1、JDK 21；演練 8.2.4 → 8.3.2"],
    ["安全", "RBAC 權控；人用 AD；機器用 SCRAM；legacy 用 REST mTLS", "MDS + AD(LDAPS) + SCRAM + 共用伺服器憑證"],
    ["自動化", "Shell、冪等、可維護", "單一入口 cpctl，採設計模式，lint + 單元測試"],
    ["操作端", "Windows 11", "Windows 端腳本一律用 Git Bash 執行"],
  ], { colW: [1.5, 5.4, 5.23], fontSize: 14, rowH: 0.62 });
  s.addNotes("這張是需求與對應做法。重點：PoC 不是只裝起來，而是模擬銀行的限制——完全離線、帳號分離、權限最小化。");
}

{
  const s = base("01 需求與決策");
  title(s, "關鍵設計決策都以官方建議與銀行維運習慣為依據", "多數決策都做成可替換的策略：安裝包形式、repo 來源、憑證來源");
  table(s, [
    ["項目", "決策", "理由"],
    ["安裝包", "RPM 為主，tar.gz 為替代策略（可切換）", "原廠 GPG 簽章、內附 systemd、可接 RHEL 9 維運；tar 適合不允許第三方 RPM 的環境"],
    ["內部套件來源", "Repo adapter；本次實作 local（createrepo_c、httpd）", "銀行不一定有 Nexus；換成 Satellite、Artifactory 只改 adapter 與 URL"],
    ["Metadata 叢集", "KRaft 動態 quorum（kraft.version=1）", "controller 可線上增減與替換，不需停機"],
    ["負載平衡", "Nginx stream（L4 passthrough）+ 來源雜湊黏著", "TLS 不終結在 LB，client 憑證才能送到 REST Proxy"],
    ["作業系統", "RHEL 9 / Rocky 9", "CP 8.3 支援；PoC 以 Rocky 9 模擬"],
    ["憑證", "自建 CA（RSA 3072，CA 10 年／leaf 1 年）", "正式環境改由行內 CA 簽發，流程相同"],
    ["升級", "滾動升級：broker 先、controller 後，finalize 前可回滾", "依 CP 8.3 官方升級文件"],
  ], { colW: [1.8, 4.6, 5.73], fontSize: 13, rowH: 0.56 });
  s.addNotes("每個決策都有理由，並且大多可以替換：安裝包形式、repo 來源、憑證來源都是策略化的設計。");
}

{
  const s = base("01 需求與決策");
  title(s, "身分模型：人用 AD、應用程式用 SCRAM、legacy 走 REST mTLS", "每一種身分都對應到獨立的 RBAC principal，沒有共用的高權限帳號");
  table(s, [
    ["誰", "連到哪裡", "驗證方式", "RBAC principal"],
    ["controller / broker 之間", "CONTROLLER / INTERNAL listener", "mTLS（共用內部憑證 kafka-internal）", "User:kafka-internal（super user）"],
    ["一般應用程式", "Kafka CLIENT :9095", "SASL_SSL SCRAM-SHA-512", "User:<app>"],
    ["legacy 應用程式", "REST Proxy（經 LB）", "mTLS，每個 app 一張 client 憑證", "User:<app>（REST 代理身分）"],
    ["人員", "Kafka CLI、MDS、C3", "AD 帳密（LDAPS）", "Group:<AD 群組>"],
    ["REST Proxy / C3 / cpctl", "MDS、TOKEN :9094", "各自的 client 憑證（svc-rest / svc-c3 / svc-cpctl），不是 AD 帳號", "各自獨立"],
    ["稽核日誌寫入者", "Kafka CLIENT :9095", "SCRAM（confluent-audit）", "只有稽核 topic 的寫入權"],
  ], { colW: [2.4, 2.9, 3.6, 3.23], fontSize: 13, rowH: 0.58 });
  s.addNotes("REST Proxy 只開放給 legacy app：principal 對應規則由 apps.env 自動產生且沒有 DEFAULT，其他憑證一律拒絕。impersonation 保護名單也是自動產生。");
}

// ===================================================================== section 2
section("02", "環境模擬", "用 Docker 模擬銀行主機與網路限制");

{
  const s = base("02 環境模擬");
  title(s, "15 個容器模擬銀行主機，除了 LB 之外完全無外網", "容器內跑 systemd，與實體機相同；另有堡壘機 jump01 與 repo web server repo01");
  // DMZ band
  s.addShape(pptx.ShapeType.roundRect, { x: M, y: 1.85, w: W - 2 * M, h: 1.05, rectRadius: 0.06, fill: { color: C.accentSoft }, line: { color: C.accent, dashType: "dash" } });
  s.addText("Windows 11（Git Bash）", { x: M + 0.2, y: 1.95, w: 3, h: 0.85, fontFace: F, fontSize: 15, bold: true, color: C.ink, valign: "middle" });
  s.addText("→  :8082  →", { x: 3.7, y: 1.95, w: 2.4, h: 0.85, fontFace: F, fontSize: 14, color: C.body, align: "center", valign: "middle" });
  card(s, 6.2, 1.98, 6.5, 0.8, "lb01  Nginx L4：REST（唯一可連外，代表 DMZ）", null, { headSize: 15, fill: "FFFFFF" });
  // internal network
  s.addShape(pptx.ShapeType.roundRect, { x: M, y: 3.1, w: W - 2 * M, h: 3.65, rectRadius: 0.06, fill: { color: "FFFFFF" }, line: { color: C.teal, width: 1.5 } });
  s.addText("cpnet：internal 網段 172.30.0.0/24，沒有任何外網路由", { x: M + 0.2, y: 3.15, w: 9, h: 0.4, fontFace: F, fontSize: 13, bold: true, color: C.teal });
  const boxes = [
    ["ops01 操作機", "cpctl、內部 repo 建置、NTP 來源；repo 由 repo01 提供", C.accent],
    ["ad01 AD", "Samba AD DC，LDAPS 636", C.teal],
    ["kc01–03 controller", "KRaft 動態 quorum，kc04 預留替換", C.teal],
    ["kb01–04 broker", "Confluent Server、MDS，兩個 rack", C.teal],
    ["rest01–02 REST Proxy", "mTLS + RBAC，在 LB 後方", C.teal],
    ["c3-01 Control Center", "C3 + 監控；維運直連 :9021，不經 LB", C.teal],
  ];
  boxes.forEach((b, i) => {
    const col = i % 3, row = Math.floor(i / 3);
    const w = (W - 2 * M - 0.6 - 0.3 * 2) / 3;
    card(s, M + 0.3 + col * (w + 0.3), 3.65 + row * 1.5, w, 1.3, b[0], b[1], { bar: b[2], headSize: 15, bodySize: 13 });
  });
  s.addNotes("只有 lb01 同時接兩個網路，其他節點（包含操作機）都在 internal 網段，連不到外網，所以「離線」是真的被驗證過，而不是假設。容器內跑 systemd，服務管理方式與實體機相同。");
}

{
  const s = base("02 環境模擬");
  title(s, "安裝帳號與服務帳號分離，OS 基線由腳本依角色套用", "兩者都是銀行稽核的基本檢查項目");
  card(s, M, 1.9, 5.9, 3.6, "帳號分離",
    "• 安裝帳號 cpadmin：金鑰登入、sudo 可收斂\n" +
    "• 服務帳號 cp-kafka 等：nologin、不可 SSH\n" +
    "• 設定檔 0640；資料與 log 歸服務帳號\n" +
    "• master key 等敏感檔只有 root 可讀\n" +
    "• 正式環境的 sudo 白名單交資安審核", { bar: C.accent, bodySize: 14 });
  card(s, M + 6.2, 1.9, 5.93, 3.6, "OS 基線（step 01）",
    "• sysctl、limits、journald 上限、時區\n" +
    "• THP = never；chrony 時間同步\n" +
    "• firewalld：依角色只開必要 port + ssh\n" +
    "• SELinux：檢查 enforcing、restorecon\n" +
    "• log 保留 14 天自動清除", { bar: C.teal, bodySize: 14 });
  band(s, "每一項都是先檢查再動作；容器內無法設定的（例如共用 WSL 核心的 THP）只檢查並標示 skipped");
  s.addNotes("帳號分離是銀行稽核的基本要求。OS 基線的每一項都是先檢查再動作，容器裡無法設定的（例如共用 WSL 核心的 THP）會標示 skipped，不會誤改主機。");
}

// ===================================================================== section 3
section("03", "離線軟體引進", "外網下載、驗證、交換、內部 repo、部署機——每段都可稽核");

{
  const s = base("03 離線引進");
  title(s, "離線引進五段流程，每一段都有驗證與留存", "這是建議與銀行討論的方案；檔案進來後至少被驗證四次");
  chevrons(s, [
    { t: "外網下載機", d: "download-packages.sh\n• 依版本清單下載\n• 驗原廠簽章 / checksum\n• 產出 SHA256SUMS\n  與 manifest" },
    { t: "驗證 / 掃描", d: "verify-packages.sh\n• 比對 sha256 與簽章\n• 掃描 hook（掃毒、\n  弱點掃描可接）\n• 產出驗證報告" },
    { t: "安全檔案交換", d: "PoC：唯讀掛載到 ops01\n\n正式：行內檔案\n交換平台落地區" },
    { t: "內部 repo", d: "cpctl repo import\n• 再驗 sha256 與簽章\n• httpd 唯讀提供\n• 同名不同內容拒絕\n• 報告留存稽核" },
    { t: "部署機", d: "• RPM：gpgcheck\n  + versionlock\n• tar：節點再驗 sha256\n• OS 套件也來自\n  內部 repo", hi: true },
  ], 2.0, 0.85, { size: 15, dsize: 14, dh: 2.6 });
  band(s, "周邊元件沒有例外：JMX exporter、chrony、firewalld 都走同一條引進路徑");
  s.addNotes("這是要跟銀行討論的建議方案。核心是：檔案從外網進來後，至少驗證三次（下載時、放行前、匯入 repo 時），部署機再驗一次。JMX exporter、chrony、firewalld 這類周邊元件也走同一條路，沒有例外。");
}

{
  const s = base("03 離線引進");
  title(s, "安裝包清單：Confluent、JDK、OS 相依與周邊元件全部離線帶入", "版本集中在 versions.env，下載腳本與安裝腳本讀同一份");
  table(s, [
    ["套件", "版本", "來源", "完整性驗證", "安裝到"],
    ["Confluent Platform（RPM）", "8.3.2、8.2.4", "packages.confluent.io/rpm", "原廠 GPG", "controller、broker、REST、ops"],
    ["Control Center Next Gen", "2.6.1", "Confluent C3 repo", "原廠 GPG", "c3-01（不裝任何 CP 套件）"],
    ["Temurin JDK", "21", "packages.adoptium.net", "原廠 GPG", "所有 Java 節點"],
    ["OS 相依（含 chrony、firewalld）", "Rocky 9", "Rocky BaseOS / AppStream", "Rocky GPG", "依相依關係"],
    ["Prometheus JMX exporter", "1.0.1", "Maven Central", "官方 sha1 + sha256", "controller、broker、REST"],
    ["tar.gz 替代策略", "CP 8.3.2 / 8.2.4、C3 2.6.1、JDK", "Confluent archive、Adoptium", "sha256（JDK 有原廠 checksum）", "INSTALL_METHOD=tar 時"],
  ], { colW: [3.0, 1.9, 2.6, 2.3, 2.33], fontSize: 13, rowH: 0.62 });
  s.addText("舊版本一律保留在內部 repo：回滾需要，而且官方會移除 EOL 版本。", { x: M, y: 6.35, w: W - 2 * M, h: 0.4, fontFace: F, fontSize: 14, color: C.teal, bold: true });
  s.addNotes("清單由 versions.env 集中管理，下載腳本也讀同一份，所以升級時只改一處。");
}

// ===================================================================== section 4
section("04", "自動化安裝", "cpctl：單一入口、冪等、可續跑、可乾跑");

{
  const s = base("04 自動化安裝");
  title(s, "cpctl 用設計模式讓腳本好維護，用 check-then-act 確保冪等", "Windows 端只負責下載與環境；所有安裝動作都在操作機上由 cpctl 執行");
  const pats = [
    ["Template Method", "步驟只寫 apply 與 verify\n共通流程由執行器負責"],
    ["Strategy", "角色、安裝方式、repo 來源\n都可替換"],
    ["Facade", "SSH、平行、重試、逾時\n集中在 remote 層"],
    ["Observer", "設定有變才重啟\n逐台通過健康檢查"],
    ["Repository", "inventory 只是資料\n日後可改接 CMDB"],
  ];
  pats.forEach((p, i) => {
    const y = 1.85 + i * 0.97;
    s.addShape(pptx.ShapeType.roundRect, { x: M, y, w: 6.3, h: 0.85, rectRadius: 0.08, fill: { color: C.card }, line: { color: C.line } });
    s.addShape(pptx.ShapeType.rect, { x: M, y: y + 0.12, w: 0.07, h: 0.61, fill: { color: C.teal }, line: { color: C.teal } });
    s.addText(p[0], { x: M + 0.22, y, w: 2.1, h: 0.85, fontFace: F, fontSize: 15, bold: true, color: C.ink, valign: "middle" });
    s.addText(p[1], { x: M + 2.45, y, w: 3.75, h: 0.85, fontFace: F, fontSize: 13, color: C.body, valign: "middle" });
  });
  card(s, M + 6.6, 1.85, 5.53, 4.75, "冪等性機制",
    "• 每個動作先檢查狀態：一致報 ok，不一致才變更並報 changed\n\n" +
    "• 設定檔以 sha256 比對，覆蓋前保留備份\n\n" +
    "• 輸入與程式都沒變且驗證通過的步驟自動跳過\n\n" +
    "• --check --diff：只列差異（密碼遮罩），不變更\n\n" +
    "• 失敗即停，修正後重跑自動略過已完成部分\n\n" +
    "• 品質：shellcheck 0 警告、19 項單元測試", { bar: C.accent, bodySize: 14 });
  s.addNotes("冪等的意思是：同一個指令跑幾次結果都一樣，第二次不會有任何變更。這讓正式環境的變更可以先 --check 審閱，再實際執行。");
}

{
  const s = base("04 自動化安裝");
  title(s, "11 個步驟由一個指令完成，任何一步失敗都能從中斷處續跑", "每一步結束都自我驗證，通過才記錄完成");
  const steps = [
    ["00", "precheck", "OS、資源、DNS、時間"], ["01", "os_baseline", "OS 參數、時間、防火牆"], ["02", "distribute", "內部 repo、GPG、安裝套件"],
    ["03", "pki", "CA、共用憑證、信任庫"], ["04", "ad_bootstrap", "LDAPS、查詢帳號、群組"], ["05", "configure", "設定、加密、滾動重啟"],
    ["06", "kraft_format", "動態 quorum 格式化"], ["07", "start_core", "controller → broker"], ["08", "security_bootstrap", "SCRAM、RBAC、topic"],
    ["09", "start_edge", "REST、C3、LB"], ["10", "verify", "端到端驗證"], ["11", "opmenu", "堡壘機維運選單"],
  ];
  const cols = 4, w = (W - 2 * M - 0.25 * (cols - 1)) / cols, h = 1.45;
  steps.forEach((st, i) => {
    const col = i % cols, row = Math.floor(i / cols);
    const x = M + col * (w + 0.25), y = 1.85 + row * (h + 0.2);
    s.addShape(pptx.ShapeType.roundRect, { x, y, w, h, rectRadius: 0.08, fill: { color: i === 10 ? C.accentSoft : C.card }, line: { color: C.line } });
    s.addText(st[0], { x: x + 0.15, y: y + 0.08, w: 0.8, h: 0.55, fontFace: F, fontSize: 24, bold: true, color: i === 10 ? C.accent : C.teal, valign: "middle" });
    s.addText(st[1], { x: x + 0.85, y: y + 0.08, w: w - 0.9, h: 0.55, fontFace: F, fontSize: 13, bold: true, color: C.ink, valign: "middle" });
    s.addText(st[2], { x: x + 0.15, y: y + 0.72, w: w - 0.3, h: 0.6, fontFace: F, fontSize: 13, color: C.body, valign: "top" });
  });
  s.addNotes("步驟順序是刻意安排的：先 OS 與套件，再憑證與 AD，然後設定、格式化、啟動、權限，最後驗證。每一步結束都會自我驗證，通過才寫 stamp。");
}

{
  const s = base("04 自動化安裝");
  title(s, "PKI：一個內部 CA、兩張共用憑證，legacy app 各一張 client 憑證", "正式環境改用行內 CA 簽發時，派送與輪替流程完全相同");
  card(s, M, 1.9, 3.9, 3.55, "內部 CA", "RSA 3072、效期 10 年\n\n簽發所有 leaf 憑證（1 年）\n\n信任庫是 bundle：輪替期間同時信任新舊 CA", { bar: C.accent, bodySize: 14 });
  card(s, M + 4.15, 1.9, 3.9, 3.55, "共用憑證", "kafka-internal：controller 與 broker 之間的 mTLS\n\ncp-server：所有對外 listener、MDS、REST、C3、LDAPS\n\nSAN 預先包含替換用的 kc04", { bar: C.teal, bodySize: 14 });
  card(s, M + 8.3, 1.9, 3.83, 3.55, "派送與信任", "PKCS12 keystore / truststore\n\nOS 與 JDK 信任庫依 CA 指紋同步增刪\n\nMDS token 私鑰只派送加密版", { bar: C.teal, bodySize: 14 });
  band(s, "共用內部憑證是需求指定；風險與輪替機制見「營運強化」與「上線準備」");
  s.addNotes("controller 與 broker 共用一張內部憑證是需求指定的；風險在後面的風險頁說明，並已提供輪替機制。正式環境改用行內 CA 時流程不變。");
}

{
  const s = base("04 自動化安裝");
  title(s, "KRaft 動態 quorum：controller 可以線上替換，不需停機", "cpctl controller replace 把四個步驟包成一個指令，每步都有健康閘門");
  chevrons(s, [
    { t: "移除舊 voter", d: "remove-controller\n等待確認不再是 voter" },
    { t: "新節點格式化", d: "以 observer 身分加入\n（--no-initial-controllers）" },
    { t: "追上 metadata", d: "健康閘門：lag = 0" },
    { t: "加入 voter", d: "add-controller\n確認成為 voter", hi: true },
  ], 2.1, 0.9, { size: 16, dsize: 14 });
  s.addShape(pptx.ShapeType.roundRect, { x: M, y: 4.6, w: W - 2 * M, h: 1.6, rectRadius: 0.08, fill: { color: C.tealSoft }, line: { color: C.tealSoft } });
  s.addText("實測：持續流量下把 kc03 替換為 kc04（目前 quorum 為 kc01、kc02、kc04）。\n一次只變動一個 voter，每步都等 lag 歸零，全程維持多數決。擴充 3 → 5 台也走同一流程。", { x: M + 0.3, y: 4.6, w: W - 2 * M - 0.6, h: 1.6, fontFace: F, fontSize: 16, color: C.teal, valign: "middle" });
  s.addNotes("新叢集直接用 kraft.version=1（動態 quorum），所以不用靜態 voters 清單。cpctl controller replace 把這四步包成一個指令。");
}

{
  const s = base("04 自動化安裝");
  title(s, "權限 bootstrap 全部由設定檔產生，不靠手動點選", "新增一個 app 只要在 apps.env 加幾行，再執行 step 08");
  table(s, [
    ["項目", "來源設定", "產生結果"],
    ["SCRAM 帳號", "apps.env 中 APP_CHANNEL=scram 的 app", "kafka-configs 建立 SCRAM-SHA-512 憑證"],
    ["人員權限", "AD 群組對應（kafka-admins / operators / devs）", "Group: 綁定 SystemAdmin、Operator、DeveloperRead"],
    ["應用程式權限", "APP_BINDINGS_<app>", "User:<app> 逐一綁定（mTLS 不能用群組）"],
    ["服務身分（憑證）", "svc-c3（官方要求 SystemAdmin）、svc-rest、svc-cpctl", "不在 AD、沒有密碼；svc-rest 只可讀 license topic"],
    ["impersonation 保護", "super users + 所有服務身分", "自動產生，REST 不能代理這些身分"],
    ["Topic", "TOPICS（RF=3、min.insync=2）", "建立並驗證"],
  ], { colW: [2.4, 4.6, 5.13], fontSize: 14, rowH: 0.62 });
  s.addNotes("新增一個 app 只要在 apps.env 加幾行，再跑 step 08，權限就會建好；重跑不會重複建立。");
}

// ===================================================================== section 5
section("05", "營運強化", "對照官方文件自檢後補齊的正式營運設定");

{
  const s = base("05 營運強化");
  title(s, "對照官方文件自檢後，補齊 10 項正式營運需要的設定", "「裝得起來」與「能上線營運」之間的差距；全部已在持續流量下滾動套用");
  const items = [
    ["密碼加密", "設定檔無明文密碼"], ["私鑰加密", "MDS 私鑰 AES-256"], ["憑證輪替", "leaf 與 CA 三階段"],
    ["License 監控", "到期前 30 天警告"], ["Log 保留", "14 天自動清除"], ["LDAP 韌性", "多台 AD 與快取"],
    ["Telemetry 關閉", "不送往外部"], ["稽核日誌", "專用帳號、敏感分流"], ["外部監控", "exporter 與告警"], ["OS 層強化", "THP、時間、防火牆"],
  ];
  const cols = 5, w = (W - 2 * M - 0.2 * (cols - 1)) / cols;
  items.forEach((it, i) => {
    const col = i % cols, row = Math.floor(i / cols);
    const x = M + col * (w + 0.2), y = 1.95 + row * 2.3;
    s.addShape(pptx.ShapeType.roundRect, { x, y, w, h: 2.05, rectRadius: 0.08, fill: { color: C.card }, line: { color: C.line } });
    s.addShape(pptx.ShapeType.ellipse, { x: x + 0.2, y: y + 0.2, w: 0.5, h: 0.5, fill: { color: C.ok }, line: { color: C.ok } });
    s.addText("✓", { x: x + 0.2, y: y + 0.2, w: 0.5, h: 0.5, fontFace: "Segoe UI Symbol", fontSize: 16, bold: true, color: "FFFFFF", align: "center", valign: "middle" });
    s.addText(it[0], { x: x + 0.2, y: y + 0.8, w: w - 0.4, h: 0.55, fontFace: F, fontSize: 16, bold: true, color: C.ink });
    s.addText(it[1], { x: x + 0.2, y: y + 1.35, w: w - 0.4, h: 0.6, fontFace: F, fontSize: 13, color: C.body, valign: "top" });
  });
  s.addNotes("這 10 項是「裝得起來」和「能上線營運」之間的差距。每一項都已部署到 PoC 叢集，並在持續流量下滾動套用，沒有中斷。");
}

{
  const s = base("05 營運強化");
  title(s, "密碼與金鑰不以明文存在任何節點的設定檔", "銀行稽核常掃描設定檔中的明文密碼；這裡採用官方的 Secret Protection");
  card(s, M, 1.9, 6.0, 3.55, "Secret Protection",
    "• 設定檔與 JAAS 內的密碼都加密成 ${securepass:...}\n\n" +
    "• master key 只在操作機與各節點 root-only 檔案\n\n" +
    "• 內容不變就沿用加密結果，不會觸發重啟", { bar: C.accent, bodySize: 14 });
  card(s, M + 6.3, 1.9, 5.83, 3.55, "其他金鑰",
    "• MDS token 私鑰：節點只拿到 AES-256 加密版\n\n" +
    "• JMX exporter：scrape 密碼只存加鹽雜湊\n\n" +
    "• 密碼、license、私鑰、套件都不進版控", { bar: C.teal, bodySize: 14 });
  band(s, "實測：全部節點掃描 0 筆明文密碼。唯一例外是 JMX YAML 的 keystore 密碼，以 0640 權限保護");
  s.addNotes("銀行稽核常會掃描設定檔中的明文密碼。這裡的做法是官方的 Secret Protection；唯一無法加密的是 JMX exporter 的 keystore 密碼，已在風險頁註明。");
}

{
  const s = base("05 營運強化");
  title(s, "稽核日誌：專用低權限帳號寫入，敏感資料另外分流保存", "依官方建議不使用預設的 broker 身分寫入稽核日誌");
  chevrons(s, [
    { t: "授權事件", d: "broker、controller\n每次授權判斷\n（允許與拒絕）" },
    { t: "路由規則", d: "payments.*：讀、寫、\n被拒絕的 describe\n其他：預設 topic" },
    { t: "專用寫入者", d: "SCRAM 帳號\nconfluent-audit\n只能寫稽核 topic" },
    { t: "保存", d: "敏感 365 天\n一般 90 天\n排除內部雜訊", hi: true },
  ], 2.0, 0.85, { size: 16, dsize: 14, dh: 1.6 });
  band(s, "驗證：允許的寫入與被拒絕的存取都進入敏感稽核 topic。實作發現：被拒絕的 producer 在 metadata 階段就被擋下，所以也要記錄被拒絕的 describe", 4.9, 1.2);
  s.addNotes("官方建議稽核寫入使用低權限的專用 principal，而不是預設的 broker principal。路由與保存天數都在 conf/audit.env 調整。");
}

{
  const s = base("05 營運強化");
  title(s, "監控分兩層：C3 給人看，JMX exporter 交給行內 Prometheus 告警", "銀行通常已有集中監控；我們交付可直接載入的設定檔");
  card(s, M, 1.9, 5.9, 3.55, "Control Center（內建）",
    "• 叢集指標經 mTLS 推送到 C3 的 Prometheus\n\n" +
    "• 人員以 AD 登入，依 RBAC 看到資源\n\n" +
    "• consumer lag、topic、叢集健康；Health+ 關閉", { bar: C.teal, bodySize: 14 });
  card(s, M + 6.2, 1.9, 5.93, 3.55, "行內 Prometheus（外部）",
    "• JMX exporter：9 個節點，HTTPS + 帳密\n\n" +
    "• monitoring export：scrape 設定、9 條告警、CA\n\n" +
    "• 告警：節點失聯、副本不足、離線分區、controller、飽和、延遲、heap", { bar: C.accent, bodySize: 14 });
  band(s, "實測：以匯出設定啟動 Prometheus，9/9 target 正常、9 條規則可評估");
  s.addNotes("銀行通常已有集中監控。exporter 的 jar 也走離線引進流程。告警規則的門檻值可依行內值班政策調整。");
}

{
  const s = base("05 營運強化");
  title(s, "OS 層強化：四項設定都在不影響共用主機的前提下實測", "防火牆最容易造成中斷，所以先在不屬於 quorum 的備用節點演練");
  table(s, [
    ["項目", "正式機的行為", "PoC 容器中的行為", "驗證結果"],
    ["THP", "disable-thp.service 開機設為 never", "systemd 依 ConditionVirtualization 自動略過（不改 WSL 核心）", "回報 skipped"],
    ["時間同步", "chrony 指向行內 NTP", "ops01 當 NTP 來源；chrony 以 -x 執行不調整共用時鐘", "11 台全部同步，誤差微秒級"],
    ["防火牆", "firewalld 依角色只開必要 port + ssh；關閉 cockpit 等預設服務", "相同（只影響容器自己的網路）", "未列 port 被擋、ssh 正常；全部驗證通過"],
    ["SELinux", "檢查 enforcing，自訂路徑 restorecon", "容器沒有 SELinux", "回報 skipped"],
  ], { colW: [1.6, 3.8, 4.0, 2.73], fontSize: 13, rowH: 0.85 });
  s.addText("chrony、firewalld 由內部 os-deps repo 安裝；先在備用節點 kc03 演練，再於持續流量下套用到整個叢集。", { x: M, y: 6.25, w: W - 2 * M, h: 0.5, fontFace: F, fontSize: 14, color: C.teal, bold: true });
  s.addNotes("防火牆是最容易造成中斷的變更，所以先在不在 quorum 內的備用節點試，確認 ssh 與允許清單正確後才全面套用。");
}

// ===================================================================== section 6
// ===================================================================== section 6: OP menu
section("06", "日常維運：堡壘機上的 OP menu", "堡壘機與主機都只有固定帳號，也能做到身分可追溯、權限可控管");

{
  const s = base("06 日常維運");
  title(s, "固定帳號只負責連線，身分一律由操作者本人的 AD 帳密證明", "堡壘機與主機都不必加入 AD：驗證交給 MDS，它本來就連著 AD");
  // flow: operator -> bastion -> nodes, MDS below
  const y = 2.05, h = 1.55;
  const boxes = [
    { x: M, w: 3.2, head: "操作員", body: "經行內堡壘機產品登入\n在選單輸入自己的 AD 帳密", c: C.accent },
    { x: M + 4.45, w: 3.6, head: "堡壘機 opuser（固定帳號）", body: "登入殼層就是選單\n不能取得 shell、不能轉埠", c: C.teal },
    { x: M + 9.3, w: 2.83, head: "各主機 kafkaops", body: "只接受堡壘機連入\n只能重啟自己的服務", c: C.teal },
  ];
  boxes.forEach((b) => card(s, b.x, y, b.w, h, b.head, b.body, { bar: b.c, bodySize: 14, headSize: 16 }));
  s.addShape(pptx.ShapeType.rightArrow, { x: M + 3.35, y: y + 0.55, w: 0.95, h: 0.45, fill: { color: C.mute }, line: { color: C.mute } });
  s.addShape(pptx.ShapeType.rightArrow, { x: M + 8.2, y: y + 0.55, w: 0.95, h: 0.45, fill: { color: C.mute }, line: { color: C.mute } });
  card(s, M + 4.45, 4.1, 3.6, 1.45, "MDS（連著 AD）", "驗證帳密、展開 AD 群組\n回答「這個人能不能做」", { bar: C.accent, bodySize: 14, headSize: 16 });
  s.addShape(pptx.ShapeType.upDownArrow, { x: M + 6.05, y: 3.62, w: 0.4, h: 0.48, fill: { color: C.mute }, line: { color: C.mute } });
  card(s, M, 4.1, 3.9, 1.45, "Kafka 動作", "用本人身分連 Kafka\nRBAC 依 AD 群組決定", { bar: C.teal, bodySize: 14, headSize: 16 });
  card(s, M + 8.6, 4.1, 3.53, 1.45, "主機動作", "先問 MDS 再碰主機\nOperator 以上才放行", { bar: C.teal, bodySize: 14, headSize: 16 });
  band(s, "選單紀錄與 Kafka 稽核日誌記的都是本人，不是 opuser；紀錄另送 syslog，共用帳號改不到", 5.85, 0.8);
  s.addNotes("客戶的堡壘機與主機都只有固定帳號。重點是：作業系統帳號只負責「連得上」，「你是誰」改由 AD 帳密證明，而驗證交給 MDS——MDS 本來就要連 AD，所以堡壘機與主機都不必加入網域。");
}

{
  const s = base("06 日常維運");
  title(s, "平台變更、日常維運、緊急處理分成三條路，各用不同帳號", "能改平台的入口只有 cpctl；日常作業只能從選單做，而且依 AD 群組控管");
  table(s, [
    ["工作", "工具", "執行帳號", "誰能做、怎麼控管"],
    ["平台變更：安裝、升級、憑證輪替", "cpctl（操作機）", "cpadmin（只給 cpctl）", "平台工程師；變更時段；先看差異再執行"],
    ["日常維運：查看、重啟、日誌、topic 與權限", "OP menu（堡壘機）", "opuser → 各主機 kafkaops", "依 AD 群組；變更類必填 ticket"],
    ["緊急處理（項目 91）", "OP menu → 包裝腳本", "opbootstrap 保管的專用憑證", "必填原因；記為 EMERGENCY；可一鍵撤銷"],
  ], { colW: [3.4, 2.4, 2.9, 3.43], fontSize: 14, rowH: 0.8 });
  band(s, "OP menu 也走離線引進：打包 → sha256 → 匯入內部 repo → cpctl step 11 部署；版本由內容決定，可切回舊版", 5.4, 0.85);
  s.addNotes("這頁回答「cpadmin 之後維運也用嗎」：不用。cpadmin 只給 cpctl 做平台變更；日常維運走選單，用的是另一組固定帳號；緊急處理用專用憑證，有紀錄、可撤銷。");
}

{
  const s = base("06 日常維運");
  title(s, "實測：同一個共用帳號，不同的人得到不同的權限", "在 PoC 的模擬堡壘機上，以固定帳號 opuser 執行，換不同的 AD 帳號登入選單");
  table(s, [
    ["測試", "結果"],
    ...OPMENU_ROWS,
  ], { colW: [8.3, 3.83], fontSize: 13, rowH: 0.5, firstBold: false });
  s.addNotes("整合前審查 OP menu 時另外修了兩個問題：主機類動作原本由主機 sudo 決定，共用帳號下任何能登入的人都能重啟服務，現在先問 MDS；項目 21 的安全檢查失敗時原本會放行重啟，現在一律拒絕。");
}

section("07", "驗證與演練", "用持續流量證明：安裝、升級、回滾、輪替都不會遺失資料");

{
  const s = base("07 驗證與演練");
  title(s, VERIFY_TOTAL + " 項端到端驗證全數通過", "不只測「能用」，也測「該被拒絕的確實被拒絕」");
  const g = [
    ["KRaft", "leader、3 voters 帶 directory id、kraft.version=1"], ["Broker", "4 台註冊、rack 感知"],
    ["內部 mTLS", "無憑證被拒、共用憑證可通"], ["SCRAM + RBAC", "有權限可讀寫、無權限被拒、錯誤密碼被拒"],
    ["AD", "群組權限生效、MDS token、錯誤密碼 401"], ["REST Proxy", "legacy 可寫、無權限 40301、非 legacy 憑證被拒、LB 切換"],
    ["C3 / 監控", "C3 有 metrics、Prometheus 需 mTLS、9 個 exporter"], ["稽核", "允許與拒絕事件進入敏感 topic、寫入者非 super user"],
    ["離線 / 套件", "節點連外失敗、版本已鎖定、C3 主機無 CP 套件"], ["憑證 / OP menu", "服務出示目前憑證；選單依 AD 群組放行、失敗即拒絕"],
  ];
  const cols = 2, w = (W - 2 * M - 0.3) / cols, h = 0.88;
  g.forEach((it, i) => {
    const col = i % cols, row = Math.floor(i / cols);
    const x = M + col * (w + 0.3), y = 1.85 + row * (h + 0.1);
    s.addShape(pptx.ShapeType.roundRect, { x, y, w, h, rectRadius: 0.06, fill: { color: C.card }, line: { color: C.line } });
    s.addText(it[0], { x: x + 0.2, y, w: 2.2, h, fontFace: F, fontSize: 15, bold: true, color: C.teal, valign: "middle" });
    s.addText(it[1], { x: x + 2.4, y, w: w - 2.6, h, fontFace: F, fontSize: 13, color: C.body, valign: "middle" });
  });
  s.addNotes("驗證不只測「能用」，也測「該被拒絕的有被拒絕」：未授權、錯誤密碼、錯誤憑證、連外網，都必須失敗才算通過。");
}

{
  const s = base("07 驗證與演練");
  title(s, "變更演練都在持續流量下進行，逐筆核對的訊息遺失為 0", "流量工具以 acks=all 寫入有序號的訊息並經 LB 呼叫 REST；事後依 producer ID 逐筆比對序號");
  table(s, [
    ["演練", "內容", "流量（SCRAM 寫入）", "遺失", "REST（成功 / 失敗）"],
    ["版本升級", "8.2.4 → 8.3.2，回滾一台後再升回，finalize", "3,572 + 4,161 筆（兩個 producer）", "0", "未量到*"],
    ["leaf 憑證輪替", "kafka-internal、cp-server 重簽與滾動重啟", "1,210 筆", "0", "214 / 0"],
    ["內部 CA 輪替", "add → switch → retire（照手冊手動）", "1,525 / 1,383 / 1,501 筆", "0", "791 / 0"],
    ["遷移到銀行 CA", "信任銀行 root → 改由銀行簽發 → 移除內部 CA（手動）", "1,415 + 3,015 筆", "0", "797 / 0"],
    ["銀行換 root", "G1 → G2 三階段（cpctl）", "2,171 + 4,530 筆", "0", "1,204 / 0"],
    ["broker 縮減 / 擴充", "kafka-remove-brokers，重新加入由 SBC 搬回（cpctl / 手動）", "6,795 / 9,974 筆", "0", "3,065 / 0"],
    ["OS 修補滾動", "broker → controller（leader 最後）→ REST（先摘除）→ C3", "1,929 筆", "0", "335 / 0"],
  ], { colW: [2.4, 4.6, 2.6, 0.8, 1.73], fontSize: 12, rowH: 0.5 });
  s.addText("* 升級那次的 REST 量測工具在第一次失敗時就停止計數（已修正）；升級的 REST 步驟與輪替時的摘除程序相同，後者手動實測 5 個階段都是 0 失敗。", { x: M, y: 6.35, w: W - 2 * M, h: 0.4, fontFace: F, fontSize: 11, color: C.mute });
  s.addNotes("只列出事後能逐筆核對的演練（手冊附錄 A.3–A.6）：負載工具只計算本次寫入的訊息，或在 broker 上依 producer ID 逐筆比對。早期以舊版量測工具做的演練（tar 升級、controller 替換、營運設定上線）不再引用。");
}

{
  const s = base("07 驗證與演練");
  title(s, "冪等性驗收：在已安裝的環境重跑整套安裝，沒有任何變更", "重跑安全，才能把它當成日常維運工具，而不是一次性的安裝腳本");
  s.addShape(pptx.ShapeType.roundRect, { x: 3.2, y: 2.1, w: 6.9, h: 2.2, rectRadius: 0.1, fill: { color: C.card }, line: { color: C.line } });
  s.addText(idem, { x: 3.2, y: 2.2, w: 6.9, h: 1.3, fontFace: F, fontSize: 54, bold: true, color: C.accent, align: "center", valign: "middle" });
  s.addText("cpctl install --force（忽略 stamp，每一步都實際檢查）", { x: 3.2, y: 3.45, w: 6.9, h: 0.6, fontFace: F, fontSize: 16, color: C.body, align: "center" });
  const meaning = [["放心重跑", "正式環境重跑不會改動任何東西"], ["偵測漂移", "有人手動改設定，重跑會修正回來"], ["變更可審閱", "先用 --check --diff 看差異再執行"]];
  meaning.forEach((m, i) => {
    const w = (W - 2 * M - 0.3 * 2) / 3, x = M + i * (w + 0.3);
    card(s, x, 4.7, w, 1.5, m[0], m[1], { bar: C.teal, bodySize: 14 });
  });
  s.addNotes("冪等性是自動化能否在銀行使用的關鍵：重跑安全，才敢把它當成日常維運工具，而不是一次性的安裝腳本。");
}

{
  const s = base("07 驗證與演練");
  title(s, "驗證與審查實際抓到的問題，修正後都加了防止再發生的檢查", "自我驗證、lint 規則、重跑驗收與端到端驗證，在這次工作中都發揮了作用；沒有任何訊息遺失");
  table(s, [
    ["發現的問題", "被誰攔下", "處理"],
    ["CA 輪替時發現兩張已不受管的舊 app 憑證", "retire 前置檢查拒絕執行", "自動封存不受管憑證後再 retire"],
    ["Shell 管線競態讓檢查隨機誤判，曾誤封存伺服器憑證", "step 03 自我驗證失敗、停止派送", "從封存還原（與節點一致）；全面改寫並新增 lint 規則"],
    ["精簡 OS 缺少 cmp / diff，比對永遠判定「不同」", "重跑驗收出現非預期的 changed", "改用 sha256 比對"],
    ["被拒絕的 producer 不產生 Produce 稽核事件", "稽核驗證項目失敗", "路由加入被拒絕的 describe"],
    ["部署機套件快取過期，找不到新匯入的套件", "kc03 備用節點演練", "安裝時強制更新 repo metadata"],
    ["OP menu：共用帳號任何人可重啟；檢查失敗仍放行", "整合前的程式審查", "加入 MDS 權限閘門、改為失敗即拒絕，並補測試"],
    ["OP menu：看日誌被拒絕時仍顯示「沒有錯誤」並記成功", "PoC 整合驗證項目失敗", "先取回傳碼再過濾，並補測試"],
    ["整個環境冷開機時 C3 比 MDS 先起而卡住", "驗證項目：C3 介面無回應", "C3 啟動前先等 MDS（最多 5 分鐘）"],
  ], { colW: [4.6, 3.6, 3.93], fontSize: 12, rowH: 0.52 });
  s.addNotes("這頁的目的不是列錯誤，而是說明自動化的安全機制確實有效：大多數問題在影響叢集之前就被攔下；C3 冷開機的問題是驗證項目抓到的（期間 C3 介面無法使用，資料不受影響）。每一項修正後都加了防止再發生的檢查。");
}

// ===================================================================== section 7
section("08", "上線準備", "從 PoC 移到正式環境需要調整與確認的事項");

{
  const s = base("08 上線準備");
  title(s, "PoC 與正式環境的差異都集中在設定檔，程式不需修改", "差異是「環境」而不是「程式」：同一套腳本，只差設定");
  table(s, [
    ["項目", "PoC", "正式環境"],
    ["主機", "Docker 容器", "實體機 / VM，修改 inventory.env"],
    ["AD", "Samba 模擬，由 cpctl 建帳號", "PROFILE=prod：AD 團隊依申請單建立，cpctl 只檢查"],
    ["憑證", "自建 CA", "行內 CA 簽發，放入 PKI 目錄，輪替流程相同"],
    ["sudo", "cpadmin 完整 sudo", "依 sudoers 白名單範本由資安審核"],
    ["heap / retention", "PoC 縮小值", "PROFILE=prod（官方建議值）"],
    ["核心參數、THP、SELinux", "容器只檢查、標示 skipped", "實際寫入並生效"],
    ["時間 / 防火牆", "ops01 提供 NTP；容器內 firewalld", "行內 NTP；依網路防火牆政策調整"],
    ["License", "試用（2026-11-13 到期）", "放入 conf/license.txt"],
  ], { colW: [2.6, 4.2, 5.33], fontSize: 13, rowH: 0.55 });
  s.addNotes("差異都是「環境」而不是「程式」。這也是設計目標：同一套腳本，PoC 與正式環境只差設定。");
}

{
  const s = base("08 上線準備");
  title(s, "已知風險都有對應的緩解措施", "最需要和銀行資安討論的是共用內部憑證與 bootstrap 帳號");
  table(s, [
    ["風險", "影響", "緩解"],
    ["kafka-internal 由所有節點共用且為 super user", "任一台私鑰外洩 = 叢集權限外洩", "權限 0640、cpctl certs rotate 可隨時輪替；正式可改每台一張"],
    ["svc-cpctl 為 bootstrap super user", "持有私鑰即 super user", "私鑰 0600；安裝後移到離線保管，需要時取回"],
    ["License 為試用", "到期後功能受限", "license status 監控，30 天前警告；上線前放入正式 license"],
    ["JMX keystore 密碼需明文", "設定檔含密碼", "檔案 0640 root:confluent；scrape 密碼只存雜湊"],
    ["Nginx 開源版只有被動健康檢查", "故障切換需等連線失敗", "max_fails / fail_timeout；實測切換時間"],
    ["raft 指標無 JMX", "外部監控看不到 quorum 細節", "以 ActiveControllerCount 告警，細節用 cpctl verify"],
  ], { colW: [3.6, 3.0, 5.53], fontSize: 13, rowH: 0.66 });
  s.addNotes("這些風險在 README 也有記錄。最需要和銀行資安討論的是共用內部憑證，以及 bootstrap 帳號的停用流程。");
}

{
  const s = base("08 上線準備");
  title(s, "下一步：需要銀行提供或確認的事項", "前兩項已準備好詢問客戶的說法");
  const asks = [
    ["軟體引進 SOP", "外網下載機、掃描要求、檔案交換平台、放行簽核（例如：要掃哪些項目、誰簽核）"],
    ["操作控制機", "一台可 SSH 到所有部署機的操作機"],
    ["主機與網路", "主機清單、網段、DNS、防火牆開通（port 清單已可產出）"],
    ["AD", "人員群組 + 一個唯讀查詢帳號、LDAPS 憑證鏈"],
    ["憑證", "行內 CA 簽發流程與效期規範"],
    ["時間與監控", "行內 NTP、Prometheus / Alertmanager 對接窗口"],
    ["License", "正式 license 與到期管理窗口"],
    ["堡壘機", "固定帳號的登入方式、操作錄影保留期間、可否部署 OP menu"],
  ];
  asks.forEach((a, i) => {
    const y = 1.85 + i * 0.6;
    s.addShape(pptx.ShapeType.ellipse, { x: M, y: y + 0.1, w: 0.42, h: 0.42, fill: { color: C.accent }, line: { color: C.accent } });
    s.addText(String(i + 1), { x: M, y: y + 0.1, w: 0.42, h: 0.42, fontFace: F, fontSize: 14, bold: true, color: "FFFFFF", align: "center", valign: "middle" });
    s.addText(a[0], { x: M + 0.6, y, w: 2.6, h: 0.62, fontFace: F, fontSize: 16, bold: true, color: C.ink, valign: "middle" });
    s.addText(a[1], { x: M + 3.3, y, w: W - 2 * M - 3.3, h: 0.62, fontFace: F, fontSize: 14, color: C.body, valign: "middle" });
  });
  s.addNotes("前兩項是已經準備好要詢問客戶的問題：引進 SOP（只舉例說明我們指的是哪些項目），以及請他們提供一台操作控制機。");
}

// ===================================================================== appendix
{
  const s = base("附錄");
  title(s, "附錄：cpctl 常用指令", "完整說明見專案 README");
  table(s, [
    ["指令", "用途"],
    ["cpctl repo import | verify | list", "落地區 → 內部 repo；驗證；列出"],
    ["cpctl install [--from NN] [--check --diff]", "完整安裝 / 續跑 / 乾跑"],
    ["cpctl step NN_name", "單一步驟"],
    ["cpctl verify / status", "端到端驗證 / 步驟與服務狀態"],
    ["cpctl upgrade plan|backup|stage|rolling|finalize|rollback --to <ver>", "滾動升級與回滾"],
    ["cpctl controller replace --old kc03 --host kc04", "動態 quorum 成員替換"],
    ["cpctl certs status | rotate | rotate-ca --phase add|switch|retire", "憑證狀態、輪替、CA 輪替"],
    ["cpctl license status / monitoring export|check", "License 到期 / 外部監控交付與檢查"],
  ], { colW: [6.6, 5.53], fontSize: 13, rowH: 0.56, firstBold: false });
  s.addNotes("完整說明在專案 README。");
}

pptx.writeFile({ fileName: out }).then((f) => console.log("written " + f));
