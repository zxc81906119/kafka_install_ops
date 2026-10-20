// Customer host checklist (Excel) generated from installer/conf/versions.env + inventory.env.
//   node build.js [out.xlsx]
// The same package lists drive cpctl: PKGS_PREREQ_* are checked by 00_precheck, the rest is installed by cpctl.
const fs = require("fs");
const path = require("path");
const ExcelJS = require("exceljs");

const ROOT = path.resolve(__dirname, "../..");
const OUT = path.resolve(process.argv[2] || path.join(ROOT, "docs", "Confluent-主機準備清單.xlsx"));

// ---- KEY=VALUE files (bash-sourceable subset: quotes, trailing comments, $VAR references)
function readEnv(file, env = {}) {
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(?:"([^"]*)"|'([^']*)'|(\S*))/);
    if (!m) continue;
    const raw = m[2] ?? m[3] ?? m[4] ?? "";
    env[m[1]] = raw.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (_, k) => env[k] ?? "");
  }
  return env;
}
const env = readEnv(path.join(ROOT, "installer/conf/inventory.env"), readEnv(path.join(ROOT, "installer/conf/versions.env")));
const list = (k) => (env[k] || "").split(/\s+/).filter(Boolean);
const count = (k) => list(k).length;

// ---- customer view of the hosts (the bank calls ops + OP menu host one machine: 操作機)
const ROLES = [
  { id: "controller", name: "KRaft controller", n: count("HOSTS_controller"), java: true, cp: list("PKGS_CONTROLLER"), note: "管理叢集 metadata，須為奇數台" },
  { id: "broker", name: "Kafka broker", n: count("HOSTS_broker"), java: true, cp: list("PKGS_BROKER"), note: "存放資料；至少 3 台" },
  { id: "rest", name: "REST Proxy", n: count("HOSTS_rest"), java: true, cp: list("PKGS_REST"), note: "放在負載平衡後面" },
  { id: "c3", name: "Control Center (C3)", n: count("HOSTS_c3"), java: true, cp: list("PKGS_C3"), note: "維運人員以瀏覽器直連" },
  { id: "ops", name: "操作機", n: count("HOSTS_ops"), java: true, cp: list("PKGS_OPS"), note: "安裝作業起點，也是 OP 選單所在主機" },
  { id: "web", name: "套件 web server（選用）", n: 1, java: false, cp: [], note: "行內沒有 Satellite、Artifactory、Nexus 時才需要" },
];
const CLUSTER = ROLES.filter((r) => r.id !== "web").map((r) => r.id);

// ---- where each package lives in RHEL 9 (checked against Rocky 9 repoquery, same layout) and why we need it
const PKG = {
  "java-21-openjdk-headless": ["AppStream", "Java 21 執行環境（Red Hat build of OpenJDK）"],
  "cyrus-sasl": ["BaseOS", "C3 前置需求（原廠文件）"],
  "openssl-devel": ["AppStream", "C3 前置需求（原廠文件）"],
  chrony: ["BaseOS", "時間同步（TLS 與 token 需要時鐘誤差 < 2 秒）"],
  firewalld: ["BaseOS", "主機防火牆，只開放必要連接埠"],
  "python3-dnf-plugin-versionlock": ["BaseOS", "鎖住 Confluent 與 JDK 版本，避免例行更新誤升級"],
  "nmap-ncat": ["AppStream", "安裝時檢查連接埠是否可連"],
  tar: ["BaseOS", "傳送安裝檔"],
  gzip: ["BaseOS", "傳送安裝檔"],
  openssl: ["BaseOS", "憑證處理"],
  sudo: ["BaseOS", "安裝帳號以受限 sudo 執行"],
  "openssh-server": ["BaseOS", "安裝與維運連線"],
  jq: ["BaseOS", "安裝程式處理 JSON"],
  gettext: ["BaseOS", "安裝程式產生設定檔（envsubst）"],
  "openldap-clients": ["BaseOS", "檢查 AD 連線與群組（ldapsearch）"],
  "createrepo_c": ["AppStream", "建立套件索引；行內用 Satellite、Artifactory、Nexus 時不需要"],
  curl: ["BaseOS", "連線檢查與下載內部套件庫檔案（curl-minimal 亦可）"],
  httpd: ["AppStream", "提供內部套件庫"],
  "mod_ssl": ["AppStream", "web server 的 HTTPS"],
};
const rows = []; // [pkg, roles[], who, lock]
const add = (pkgs, roles, who, lock) => pkgs.forEach((p) => rows.push([p, roles, who, lock]));
add(list("PKGS_PREREQ_NODE"), CLUSTER, "行內預先安裝", "否");
add(list("PKGS_PREREQ_OPS"), ["ops"], "行內預先安裝", "否");
add([env.JDK_PACKAGE], ROLES.filter((r) => r.java).map((r) => r.id), "安裝時從行內 repo 安裝", "是（換版需滾動重啟）");
add(list("PKGS_C3_OS"), ["c3"], "安裝時從行內 repo 安裝", "否（跟著 OS 修補）");
add(list("PKGS_OS_BASELINE"), CLUSTER, "安裝時從行內 repo 安裝", "否（跟著 OS 修補）");
add(["httpd", ...list("PKGS_OPS_OS")], ["web"], "行內安裝與管理", "否");
for (const [p] of rows) if (!PKG[p]) throw new Error(`no repo/purpose for ${p}: add it to PKG in build.js`);

// confluent-* pulled in by the RPMs' Requires (rpm -qpR on the 8.3.x packages)
const CP_DEPS = {
  "confluent-server": ["confluent-ce-kafka-http-server", "confluent-metadata-service", "confluent-server-rest", "confluent-telemetry"],
  "confluent-security": ["confluent-common"],
  "confluent-kafka-rest": ["confluent-rest-utils"],
};

// ---- styling
const FONT = "Arial";
const C = { head: "1F4E79", headText: "FFFFFF", input: "FFF2CC", example: "808080", band: "F2F2F2", border: "BFBFBF" };
const thin = { style: "thin", color: { argb: C.border } };
const box = { top: thin, left: thin, bottom: thin, right: thin };

function sheet(wb, name, cols) {
  const ws = wb.addWorksheet(name, { views: [{ state: "frozen", ySplit: 1 }] });
  ws.columns = cols.map(([header, width]) => ({ header, width }));
  const h = ws.getRow(1);
  h.height = 22;
  h.eachCell((c) => {
    c.font = { name: FONT, bold: true, color: { argb: C.headText } };
    c.fill = { type: "pattern", pattern: "solid", fgColor: { argb: C.head } };
    c.alignment = { vertical: "middle", horizontal: "center", wrapText: true };
    c.border = box;
  });
  return ws;
}
function body(ws, from) {
  for (let r = from; r <= ws.rowCount; r++) {
    ws.getRow(r).eachCell({ includeEmpty: true }, (c) => {
      c.font = { name: FONT, ...(c.font || {}), name: FONT };
      c.alignment = { vertical: "top", wrapText: true, ...(c.alignment || {}) };
      c.border = box;
    });
  }
}
const input = (c) => { c.fill = { type: "pattern", pattern: "solid", fgColor: { argb: C.input } }; };

(async () => {
  const wb = new ExcelJS.Workbook();
  wb.creator = "Confluent PoC";
  wb.created = new Date();
  const today = new Date().toISOString().slice(0, 10);

  // ================================================================ 說明
  {
    const ws = wb.addWorksheet("說明");
    ws.columns = [{ width: 22 }, { width: 90 }];
    const lines = [
      ["Confluent Platform 主機準備清單", ""],
      ["版本", `Confluent Platform ${env.CP_VERSION}、Control Center ${env.C3_VERSION}、Java ${env.JDK_MAJOR}（${env.JDK_PACKAGE}）`],
      ["產生日期", today],
      ["", ""],
      ["用途", "列出安裝前每種主機要準備的項目，與行內 RHEL 套件來源（BaseOS、AppStream）需要提供的套件。Confluent 原廠套件由我方帶入，不在本清單的行內準備範圍。"],
      ["怎麼填", "黃色儲存格請行內填寫：「主機清單」填主機名稱與 IP；「OS 套件」的「行內確認」選擇已提供或待補。灰色斜體列是填寫範例，不必保留。"],
      ["「行內預先安裝」", "安裝程式執行前就要裝好（RHEL 最小安裝可能沒有）。安裝前檢查會逐台確認，缺少就停止並列出缺哪些。"],
      ["「安裝時從行內 repo 安裝」", "由我方在安裝時以 dnf 從行內 RHEL repo 安裝，行內只要確認 repo 內有這些套件。若行內規定 OS 套件須由 OS 團隊安裝，請改為預先安裝。"],
      ["鎖版本", "只鎖 Confluent 與 JDK（JDK 換版要安排滾動重啟）。其他 OS 套件不鎖，跟著行內 OS 修補流程更新。"],
      ["來源", "由安裝程式設定檔 installer/conf/versions.env 與 inventory.env 產生；安裝程式實際安裝與檢查的內容與本清單一致。"],
    ];
    lines.forEach((l) => ws.addRow(l));
    ws.getCell("A1").font = { name: FONT, bold: true, size: 16, color: { argb: C.head } };
    for (let r = 2; r <= ws.rowCount; r++) {
      ws.getCell(`A${r}`).font = { name: FONT, bold: true };
      ws.getCell(`B${r}`).font = { name: FONT };
      ws.getCell(`B${r}`).alignment = { wrapText: true, vertical: "top" };
      ws.getCell(`A${r}`).alignment = { vertical: "top", wrapText: true };
    }
    const lg = ws.addRow(["圖例", "黃色 = 行內填寫"]);
    input(lg.getCell(2));
    lg.getCell(1).font = { name: FONT, bold: true };
    lg.getCell(2).font = { name: FONT };
  }

  // ================================================================ 主機清單
  {
    const ws = sheet(wb, "主機清單", [["主機用途", 24], ["數量", 8], ["我方安裝的 Confluent 套件", 40], ["主機名稱（行內填）", 26], ["IP（行內填）", 18], ["說明", 40]]);
    const ex = ws.addRow(["範例：Kafka broker", 1, "confluent-server、confluent-security", "kafka-b01.bank.local", "10.20.30.41", "填寫範例，可刪除"]);
    ex.eachCell((c) => { c.font = { name: FONT, italic: true, color: { argb: C.example } }; });
    const first = ws.rowCount + 1;
    for (const r of ROLES) {
      const row = ws.addRow([r.name, r.n, r.cp.join("、") || "（無）", "", "", r.note]);
      input(row.getCell(4));
      input(row.getCell(5));
    }
    const last = ws.rowCount;
    const total = ws.addRow(["合計（不含選用的 web server）", { formula: `SUM(B${first}:B${last - 1})`, result: ROLES.slice(0, -1).reduce((a, r) => a + r.n, 0) }, "", "", "", "數量可依需求調整"]);
    total.font = { name: FONT, bold: true };
    body(ws, 2);
    ex.eachCell((c) => { c.font = { name: FONT, italic: true, color: { argb: C.example } }; });
    total.eachCell((c) => { c.font = { name: FONT, bold: true }; });
    ws.getColumn(2).alignment = { horizontal: "center", vertical: "top" };
  }

  // ================================================================ OS 套件
  {
    const roleCols = ROLES.map((r) => [r.name.replace("（選用）", "\n（選用）"), 12]);
    const ws = sheet(wb, "OS 套件", [["套件", 30], ["RHEL repo", 12], ["用途", 40], ...roleCols, ["由誰安裝", 18], ["鎖版本", 18], ["行內確認", 12]]);
    ws.getRow(1).height = 36;
    const confirmCol = 3 + ROLES.length + 3;
    rows.forEach(([p, roles, who, lock], i) => {
      const row = ws.addRow([p, PKG[p][0], PKG[p][1], ...ROLES.map((r) => (roles.includes(r.id) ? "✓" : "")), who, lock, ""]);
      const c = row.getCell(confirmCol);
      input(c);
      c.dataValidation = { type: "list", allowBlank: true, formulae: ['"已提供,待補"'] };
      if (i % 2) row.eachCell({ includeEmpty: true }, (cell, n) => { if (n !== confirmCol) cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: C.band } }; });
    });
    body(ws, 2);
    for (let n = 4; n < 4 + ROLES.length; n++) ws.getColumn(n).alignment = { horizontal: "center", vertical: "top" };
    const note = ws.addRow([]);
    const n2 = ws.addRow(["檢查方式：在主機上執行 dnf info <套件>，能顯示套件資訊即表示行內 repo 有提供。"]);
    n2.getCell(1).font = { name: FONT, italic: true };
    ws.mergeCells(n2.number, 1, n2.number, confirmCol);
    void note;
  }

  // ================================================================ Confluent 套件（我方帶入）
  {
    const ws = sheet(wb, "Confluent 套件（我方帶入）", [["主機用途", 24], ["直接安裝", 40], ["自動帶入的 Confluent 相依", 52], ["版本", 12], ["鎖版本", 10]]);
    for (const r of ROLES.filter((x) => x.cp.length)) {
      const deps = [...new Set(r.cp.flatMap((p) => CP_DEPS[p] || []))];
      const ver = r.id === "c3" ? env.C3_VERSION : env.CP_VERSION;
      ws.addRow([r.name, r.cp.join("\n"), deps.join("\n") || "（無）", ver, "是"]);
    }
    body(ws, 2);
    const n = ws.addRow(["說明：Confluent 原廠 RPM 只依賴 Confluent 自己的套件（rpm -qpR 確認），不會要求 Java 或其他 OS 套件，所以 OS 端需求另列於「OS 套件」。這些檔案經行內掃描與開單流程帶入，放在內部套件庫。"]);
    ws.mergeCells(n.number, 1, n.number, 5);
    n.getCell(1).font = { name: FONT, italic: true };
    n.getCell(1).alignment = { wrapText: true };
    n.height = 36;
  }

  await wb.xlsx.writeFile(OUT);
  console.log("wrote", OUT, `${rows.length} OS package rows`);
})().catch((e) => { console.error(e); process.exit(1); });
