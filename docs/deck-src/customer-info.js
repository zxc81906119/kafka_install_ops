// Builds the "Kafka 客戶資訊整理" deck (.pptx): content analysis + rewrite of the Desktop draft 整理 kafka 客戶資訊.pptx.
// Pictures over words; tables only where the content is a table. CyberArk follows the current design (PAM only).
// Usage: node customer-info.js <output.pptx>
const PptxGenJS = require("pptxgenjs");
const React = require("react");
const { renderToStaticMarkup } = require("react-dom/server");
const sharp = require("sharp");
const L = require("react-icons/lu");

const out = process.argv[2] || "customer-info.pptx";
const C = {
  ink: "17213A", body: "3D4659", mute: "6B7385", line: "D9DCE3", soft: "F2F4F7",
  accent: "D9661F", accentSoft: "FBEADF", teal: "1F7A8C", tealSoft: "E1F0F3", blue: "4E6E9E", blueSoft: "E6ECF5",
  ok: "2E7D4F", okSoft: "E3F1E8", bad: "B23A3A", badSoft: "F6E3E3", white: "FFFFFF", head: "155F82",
};
const F = "Microsoft JhengHei";
const W = 13.33, M = 0.6, CW = W - 2 * M;

const pptx = new PptxGenJS();
pptx.layout = "LAYOUT_WIDE";
pptx.title = "Kafka 客戶資訊整理";
pptx.author = "PoC 團隊";
pptx.theme = { headFontFace: F, bodyFontFace: F };
pptx.defineSlideMaster({
  title: "CONTENT",
  background: { color: C.white },
  objects: [
    { placeholder: { options: { name: "title", type: "title", x: M, y: 0.35, w: CW, h: 0.8, fontFace: F, fontSize: 28, bold: true, color: C.ink, valign: "middle", margin: 0 }, text: "" } },
    { text: { text: "Confluent Platform 8.3 銀行離線安裝｜客戶資訊整理", options: { x: M, y: 7.05, w: 8, h: 0.3, fontFace: F, fontSize: 11, color: C.mute, margin: 0 } } },
  ],
  slideNumber: { x: W - M - 0.6, y: 7.05, w: 0.6, h: 0.3, fontFace: F, fontSize: 11, color: C.mute, align: "right" },
});
pptx.defineSlideMaster({ title: "DARK", background: { color: C.ink } });

// ---- icons: react-icons (lucide) -> SVG -> PNG
const iconCache = {};
async function icon(name, color) {
  const key = name + color;
  if (!iconCache[key]) {
    if (!L[name]) throw new Error("no icon " + name);
    const svg = renderToStaticMarkup(React.createElement(L[name], { size: 256, color: "#" + color }));
    const png = await sharp(Buffer.from(svg)).png().toBuffer();
    iconCache[key] = "image/png;base64," + png.toString("base64");
  }
  return iconCache[key];
}
async function badge(s, cx, cy, d, name, fill = C.teal, fg = C.white) {
  s.addShape(pptx.ShapeType.ellipse, { x: cx - d / 2, y: cy - d / 2, w: d, h: d, fill: { color: fill }, line: { color: fill } });
  const i = d * 0.56;
  s.addImage({ data: await icon(name, fg), x: cx - i / 2, y: cy - i / 2, w: i, h: i });
}
const txt = (s, t, o) => s.addText(t, { isTextBox: true, fontFace: F, color: C.ink, margin: 0, valign: "top", ...o });
const panel = (s, x, y, w, h, fill = C.soft, line) =>
  s.addShape(pptx.ShapeType.roundRect, { x, y, w, h, rectRadius: 0.1, fill: { color: fill }, line: { color: line || fill, width: 1 } });
function arrow(s, x1, y1, x2, y2, color = C.mute, width = 2, dash) {
  s.addShape(pptx.ShapeType.line, {
    x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.max(Math.abs(x2 - x1), 0.001), h: Math.max(Math.abs(y2 - y1), 0.001),
    flipH: x2 < x1, flipV: (y2 < y1) !== (x2 < x1) && y1 !== y2,
    line: { color, width, endArrowType: "triangle", dashType: dash || "solid" },
  });
}
function slide(title, notes) {
  const s = pptx.addSlide({ masterName: "CONTENT" });
  s.addText(title, { placeholder: "title" });
  if (notes) s.addNotes(notes);
  return s;
}
// one-line takeaway under the title
const lead = (s, t, color = C.teal) => txt(s, t, { x: M, y: 1.18, w: CW, h: 0.45, fontSize: 17, color, bold: true });
// node: rounded box, optional icon on the left, label (+ small sub line)
async function node(s, x, y, w, h, label, o = {}) {
  panel(s, x, y, w, h, o.fill || C.soft, o.line);
  const col = o.color || C.ink;
  let tx = x + 0.12, tw = w - 0.24;
  if (o.icon) {
    const d = Math.min(h - 0.2, 0.6);
    await badge(s, x + 0.12 + d / 2, y + h / 2, d, o.icon, o.badge || col);
    tx = x + d + 0.25; tw = w - d - 0.35;
  }
  txt(s, o.sub ? [{ text: label, options: { bold: true, fontSize: o.fs || 14, color: col, breakLine: true } }, { text: o.sub, options: { fontSize: o.sfs || 11, color: C.body } }]
    : label, { x: tx, y, w: tw, h, valign: "middle", align: o.icon ? "left" : "center", fontSize: o.fs || 14, bold: !o.sub, color: col });
}
// small colored status chip
function chip(s, x, y, w, t, fill, col = C.white, h = 0.36) {
  s.addShape(pptx.ShapeType.roundRect, { x, y, w, h, rectRadius: 0.18, fill: { color: fill }, line: { color: fill } });
  txt(s, t, { x, y, w, h, fontSize: 12, bold: true, color: col, align: "center", valign: "middle" });
}
// native table
function table(s, rows, o) {
  const body = rows.map((r, ri) => r.map((c) => {
    const cell = typeof c === "string" ? { text: c } : c;
    return {
      text: cell.text,
      options: {
        fontFace: F, fontSize: o.fontSize || 13, valign: "middle", margin: [0.05, 0.1, 0.05, 0.1],
        bold: ri === 0 || cell.bold, color: ri === 0 ? C.white : (cell.color || C.ink),
        fill: { color: ri === 0 ? C.head : (cell.fill || (ri % 2 ? C.white : C.soft)) },
        align: cell.align || (ri === 0 ? "center" : "left"),
        border: { type: "solid", color: C.line, pt: 0.75 },
      },
    };
  }));
  s.addTable(body, { x: o.x ?? M, y: o.y, w: o.w ?? CW, colW: o.colW, rowH: o.rowH });
}
const B = (t) => ({ text: t, bold: true });
const G = (t) => ({ text: t, color: C.ok, bold: true });
const R = (t) => ({ text: t, color: C.bad, bold: true });
const Y = (t) => ({ text: t, color: C.accent, bold: true });

async function main() {
  // ================================================================= 1 cover
  {
    const s = pptx.addSlide({ masterName: "DARK" });
    txt(s, "Confluent Platform 8.3 企業版｜銀行離線安裝", { x: 0.9, y: 2.0, w: 11.5, h: 0.6, fontSize: 22, color: "C9CFDB" });
    txt(s, "Kafka 客戶資訊整理", { x: 0.9, y: 2.7, w: 11.5, h: 1.1, fontSize: 48, bold: true, color: C.white });
    txt(s, "資源、版本、架構、告警、安全、憑證、CyberArk、零停機輪替", { x: 0.9, y: 3.9, w: 11.5, h: 0.5, fontSize: 20, color: "C9CFDB" });
    const ic = ["LuHardDrive", "LuCoffee", "LuLayers", "LuBell", "LuShieldCheck", "LuKeyRound", "LuVault", "LuRepeat"];
    for (let i = 0; i < ic.length; i++) await badge(s, 1.25 + i * 0.95, 5.4, 0.7, ic[i], i < 3 ? C.teal : i < 6 ? C.blue : C.accent);
    s.addNotes("以桌面的「整理 kafka 客戶資訊」為底稿：保留原有主題，修正前後不一致之處，補上 lab 實測結論，CyberArk 依與客戶討論的做法（PSMP 代登 root、一組 SSH 金鑰；暫無 CP、CCP、Conjur）重畫。待決事項集中在倒數第二頁。");
  }

  // ================================================================= 2 overview
  {
    const s = slide("八個主題：哪些已定、哪些待決", "綠色是已經可以對客戶說的結論；橘色是還需要客戶或原廠決定的。各主題後面一頁有細節。");
    const T = [
      ["LuHardDrive", "硬體資源", "原廠最小配置\n不能再縮小", 1],
      ["LuGauge", "磁碟估算", "131 GB／台\n遠小於 2 TB", 1],
      ["LuCoffee", "JDK 版本", "全部 JDK 21\nC3 對 JDK 25 待原廠", 0],
      ["LuBell", "告警 webhook", "自訂 JSON\n要選方案", 0],
      ["LuShieldCheck", "SCRAM 安全", "不存明文\n不傳明文", 1],
      ["LuKeyRound", "憑證輪替", "新舊並存\n換完才刪舊", 1],
      ["LuVault", "CyberArk", "有 PAM，無 CP／CCP\n明年才買", 1],
      ["LuRepeat", "零停機輪替", "要兩組帳密\n與 CPM 取捨待決", 0],
    ];
    const gap = 0.25, tw = (CW - gap * 3) / 4, th = 2.45;
    for (let i = 0; i < 8; i++) {
      const [ic, name, sub, done] = T[i], x = M + (i % 4) * (tw + gap), y = 1.45 + Math.floor(i / 4) * (th + gap);
      const col = done ? C.ok : C.accent;
      panel(s, x, y, tw, th, done ? C.okSoft : C.accentSoft);
      await badge(s, x + 0.6, y + 0.65, 0.8, ic, col);
      txt(s, name, { x: x + 1.15, y: y + 0.3, w: tw - 1.3, h: 0.7, fontSize: 18, bold: true, color: C.ink, valign: "middle" });
      txt(s, sub, { x: x + 0.25, y: y + 1.2, w: tw - 0.5, h: 0.75, fontSize: 14, color: C.body });
      chip(s, x + 0.25, y + th - 0.55, 0.95, done ? "已定" : "待決", col);
    }
  }

  // ================================================================= 3 hardware
  {
    const s = slide("硬體資源：以原廠建議為下限", "原簡報兩張圖沒標示環境，容易讀反，這裡合併。原廠已是最小可支援配置，再縮小原廠不 support。RAID 6 可用但有效能議題，原廠仍建議 RAID 1 或 RAID 10。Control Center 若管理超過 100,000 個 partition replica，必須用 8 cores／16 GB／200 GB。");
    lead(s, "原廠最小建議已無再縮小空間；低於它原廠不提供 support");
    table(s, [
      ["服務", "台數", "Staging（每台）", "Prod 精簡版（每台）", "原廠建議（每台）"],
      [B("KRaft Controller"), "3", "2 cores／4 GB／64 GB SSD", "4 cores／4 GB／64 GB SSD", "4 cores／4 GB／64 GB SSD"],
      [B("Broker"), "4", "8 cores／16 GB／500 GB", "8 cores／16 GB／4×1 TB SSD，RAID 10", "16 cores／32 GB／12×1 TB SSD，10GbE"],
      [B("REST Proxy"), "2", "8 cores／1 GB＋64 MB×producer＋16 MB×consumer／100 GB", "4 cores 起，記憶體算法同左", "16 cores（依附載評估）"],
      [B("Control Center"), "1", "4 cores／8 GB／200 GB", "4 cores／8 GB／200 GB SSD", "8 cores／16 GB／200 GB SSD"],
      [B("合計"), "10", "10 台", "10 台", ""],
    ], { y: 1.75, colW: [1.9, 0.8, 3.4, 3.3, 2.73], rowH: [0.42, 0.55, 0.65, 0.85, 0.55, 0.4], fontSize: 12 });
    await node(s, M, 5.75, 3.9, 1.0, "RAID 10", { icon: "LuHardDrive", fill: C.tealSoft, color: C.teal, sub: "4 TB raw ≈ 2 TB usable；資料碟與 OS 分離" });
    await node(s, M + 4.1, 5.75, 3.9, 1.0, "RAID 6 可用", { icon: "LuTriangleAlert", fill: C.accentSoft, color: C.accent, sub: "可能有效能議題；原廠仍建議 RAID 1／10" });
    await node(s, M + 8.2, 5.75, CW - 8.2, 1.0, "Staging 台數待確認", { icon: "LuCircleHelp", fill: C.badSoft, color: C.bad, sub: "硬體表 10 台，架構圖只有 7 台（第 6 頁）" });
  }

  // ================================================================= 4 disk
  {
    const s = slide("磁碟估算：每台 broker 只要 131 GB", "公式使用原廠 Excel：每日 125 萬筆、每筆 6 KB、保留 7 天、副本 3、4 台 broker、使用率 60%、RAID 10。逐項重新驗算與 Excel 一致。注意原簡報附註寫 0.58 MBps ingress，但 125 萬筆×6 KB÷86,400 秒約 0.087 MB/s，差約 6.7 倍，需確認 0.58 是尖峰值還是筆誤。");
    lead(s, "原廠 Excel 的每一項都已用公式重新驗算，數字相符");
    const steps = [["每日 125 萬筆", "× 6 KB × 7 天", C.soft, C.ink], ["保留期總量", "157.5 GB\n（含副本 3）", C.tealSoft, C.teal], ["每台 broker", "÷ 4 台\n39.4 GB", C.tealSoft, C.teal], ["含使用率 60%", "÷ 0.6\n65.6 GB", C.tealSoft, C.teal], ["含 RAID 10", "÷ 0.5\n131.3 GB", C.accentSoft, C.accent]];
    const gap = 0.45, w = (CW - gap * 4) / 5;
    steps.forEach(([h, sub, fill, col], i) => {
      const x = M + i * (w + gap);
      panel(s, x, 1.85, w, 1.6, fill);
      txt(s, h, { x, y: 1.95, w, h: 0.45, fontSize: 15, bold: true, color: col, align: "center" });
      txt(s, sub, { x, y: 2.5, w, h: 0.9, fontSize: 16, color: C.ink, align: "center" });
      if (i < 4) arrow(s, x + w + 0.05, 2.65, x + w + gap - 0.05, 2.65);
    });
    // proportion bar: needed vs raw
    txt(s, "需求與配置的比例（每台 broker）", { x: M, y: 3.85, w: CW, h: 0.4, fontSize: 17, bold: true });
    const bw = CW, by = 4.45;
    panel(s, M, by, bw, 0.7, C.soft, C.line);
    panel(s, M, by, bw / 2, 0.7, C.tealSoft, C.teal);
    s.addShape(pptx.ShapeType.rect, { x: M, y: by, w: bw * 131.25 / 4000, h: 0.7, fill: { color: C.accent }, line: { color: C.accent } });
    txt(s, "4 TB raw", { x: M + bw - 1.7, y: by, w: 1.6, h: 0.7, fontSize: 14, bold: true, color: C.mute, align: "right", valign: "middle" });
    txt(s, "2 TB usable（RAID 10）", { x: M + bw / 2 - 2.3, y: by, w: 2.2, h: 0.7, fontSize: 13, bold: true, color: C.teal, align: "right", valign: "middle" });
    txt(s, "▲ 131 GB 需求（不到可用空間的 7%）", { x: M, y: by + 0.75, w: 5, h: 0.4, fontSize: 14, bold: true, color: C.accent });
    panel(s, M, 5.95, CW, 0.8, C.badSoft);
    await badge(s, M + 0.5, 6.35, 0.5, "LuCircleHelp", C.bad);
    txt(s, "待確認：附註「0.58 MBps ingress」與 125 萬筆×6 KB 換算的 0.087 MB/s 不符；請客戶確認每日筆數與尖峰倍數", { x: M + 0.95, y: 5.95, w: CW - 1.2, h: 0.8, fontSize: 14, bold: true, color: C.bad, valign: "middle" });
  }

  // ================================================================= 5 JDK
  {
    const s = slide("JDK 版本：全部用 JDK 21", "客戶希望用 JDK 25。Confluent 8.2.x 不支援 JDK 25；8.3.x 支援，但原廠推薦的穩定版是 JDK 21。Control Center 2.6.x 的系統需求頁只寫最低 Java 17，沒有任何 JDK 25 的說明，所以「理論上支援」是推論，不是原廠承諾，需要書面確認。安裝手冊目前所有 Java 節點用 JDK 21。");
    lead(s, "建議全部 JDK 21；客戶堅持 JDK 25 時，先取得原廠書面回覆");
    const cell = (t, fill, col) => ({ text: t, bold: true, color: col, fill, align: "center" });
    table(s, [
      ["元件", "JDK 21", "JDK 25"],
      [B("Confluent Platform 8.2.x"), cell("支援（推薦）", C.okSoft, C.ok), cell("不支援", C.badSoft, C.bad)],
      [B("Confluent Platform 8.3.x"), cell("支援（推薦）", C.okSoft, C.ok), cell("支援（原廠說可使用）", C.okSoft, C.ok)],
      [B("Control Center 2.6.x"), cell("可用", C.okSoft, C.ok), cell("文件未說明", C.accentSoft, C.accent)],
    ], { y: 1.85, colW: [4.3, 3.9, 3.93], rowH: [0.45, 0.7, 0.7, 0.7], fontSize: 15 });
    // decision flow
    await node(s, M, 4.75, 3.4, 1.1, "客戶要 JDK 25？", { icon: "LuCircleHelp", fill: C.soft, color: C.ink, fs: 16 });
    arrow(s, M + 3.45, 5.3, M + 4.15, 5.3);
    await node(s, M + 4.2, 4.2, 3.9, 1.0, "否：全部 JDK 21", { icon: "LuCircleCheck", fill: C.okSoft, color: C.ok, sub: "原廠推薦" });
    await node(s, M + 4.2, 5.4, 3.9, 1.35, "是：先問原廠", { icon: "LuMessageSquare", fill: C.accentSoft, color: C.accent, sub: "C3 2.6.x 是否支援 JDK 25（書面）" });
    arrow(s, M + 8.15, 5.95, M + 8.85, 5.95);
    await node(s, M + 8.9, 5.4, CW - 8.9, 1.35, "Kafka 節點可用 25", { icon: "LuServer", fill: C.tealSoft, color: C.teal, sub: "C3 先維持 21（各節點獨立）" });
  }

  // ================================================================= 6 architecture
  {
    const s = slide("部署架構：Staging 與 Prod", "Staging 把 controller 和 broker 合併在 3 台上，再加 1 台純 broker；Prod 是 3 台專用 controller 加 4 台 broker。兩邊都有 2 台 REST Proxy（前面是 F5）、1 台 Control Center（內含 Prometheus 與 Alertmanager）、1 台操作機。");
    const env = async (x0, title, rows) => {
      txt(s, title, { x: x0, y: 1.3, w: 5.9, h: 0.45, fontSize: 20, bold: true, align: "center" });
      for (let r = 0; r < rows.length; r++) {
        const [label, n, fill, col] = rows[r], y = 1.9 + r * 0.8;
        txt(s, label, { x: x0, y, w: 1.3, h: 0.62, fontSize: 13, color: C.mute, valign: "middle" });
        const w = 4.55 / n.length - 0.08;
        n.forEach((t, i) => { panel(s, x0 + 1.35 + i * (w + 0.08), y, w, 0.62, fill); txt(s, t, { x: x0 + 1.35 + i * (w + 0.08), y, w, h: 0.62, fontSize: 12, bold: true, color: col, align: "center", valign: "middle" }); });
      }
    };
    await env(M, "Staging（合併式）", [
      ["入口", ["F5"], C.soft, C.ink], ["REST", ["rest-1", "rest-2"], C.tealSoft, C.teal],
      ["Kafka", ["broker＋ctrl", "broker＋ctrl", "broker＋ctrl"], C.accentSoft, C.accent],
      ["Kafka", ["broker"], C.accentSoft, C.accent], ["管理", ["C3＋Prometheus＋AM"], C.blueSoft, C.blue], ["維運", ["操作機"], C.soft, C.ink],
    ]);
    await env(M + 6.5, "Prod（專用 controller）", [
      ["入口", ["F5"], C.soft, C.ink], ["REST", ["rest-1", "rest-2"], C.tealSoft, C.teal],
      ["Broker", ["b1", "b2", "b3", "b4"], C.accentSoft, C.accent],
      ["Controller", ["c1", "c2", "c3"], C.accentSoft, C.accent], ["管理", ["C3＋Prometheus＋AM"], C.blueSoft, C.blue], ["維運", ["操作機"], C.soft, C.ink],
    ]);
    panel(s, M, 6.4, CW, 0.55, C.badSoft);
    txt(s, "待確認：Staging 是 7 台（此圖）還是 10 台（硬體表）？合併式的 controller 與 broker 共用主機，資源要加總", { x: M + 0.2, y: 6.4, w: CW - 0.4, h: 0.55, fontSize: 14, bold: true, color: C.bad, valign: "middle" });
  }

  // ================================================================= 7 alert path
  {
    const s = slide("告警路徑：C3 內建 Prometheus 與 Alertmanager", "原簡報兩頁的標題容易讓人以為 broker 沒有 Prometheus；實際上 C3 內建 Prometheus 與 Alertmanager，兩頁的差別只是客戶有沒有自己的外部 Prometheus。C3 的 webhook 只有預設 JSON；客戶的簡訊與 mail 平台（omnibus）要指定 JSON，所以中間需要格式轉換。");
    lead(s, "C3 的 webhook 只有預設格式；客戶要指定 JSON 就要多一層");
    const y = 2.0, h = 1.35, gap = 0.4, w = (CW - gap * 4) / 5;
    const N = [["LuServer", "Broker／Controller", "telemetry 上報", C.accentSoft, C.accent], ["LuGauge", "C3 內建 Prometheus", "觸發規則由 C3 管理", C.blueSoft, C.blue], ["LuBell", "C3 內建 Alertmanager", "webhook 預設 JSON", C.blueSoft, C.blue], ["LuWebhook", "格式轉換 gateway", "指定 JSON（需客製）", C.soft, C.ink], ["LuMessageSquare", "omnibus", "簡訊、mail", C.okSoft, C.ok]];
    for (let i = 0; i < 5; i++) {
      const x = M + i * (w + gap);
      panel(s, x, y, w, h, N[i][3]);
      await badge(s, x + w / 2, y + 0.42, 0.55, N[i][0], N[i][4]);
      txt(s, N[i][1], { x, y: y + 0.78, w, h: 0.3, fontSize: 13, bold: true, color: N[i][4], align: "center" });
      txt(s, N[i][2], { x, y: y + 1.05, w, h: 0.3, fontSize: 11, color: C.body, align: "center" });
      if (i < 4) arrow(s, x + w + 0.04, y + h / 2, x + w + gap - 0.04, y + h / 2);
    }
    txt(s, "已用 lab 驗證", { x: M, y: 3.85, w: 5, h: 0.4, fontSize: 18, bold: true, color: C.teal });
    const F3 = [
      ["LuWebhook", "介面的 webhook 只能填 URL", "不能自訂 JSON 內容", C.tealSoft, C.teal],
      ["LuRefreshCw", "手改設定檔會被蓋掉", "C3 重啟或約 1 分鐘內重寫 alertmanager-generated.yml", C.accentSoft, C.accent],
      ["LuLock", "元件之間全部 mTLS", "沒憑證、自簽憑證都被拒（下一頁）", C.okSoft, C.ok],
    ];
    const tw = (CW - 0.5) / 3;
    for (let i = 0; i < 3; i++) await node(s, M + i * (tw + 0.25), 4.35, tw, 1.35, F3[i][1], { icon: F3[i][0], fill: F3[i][3], color: F3[i][4], sub: F3[i][2], fs: 14, sfs: 12 });
    await node(s, M, 5.95, CW, 0.85, "C3 告警要生效：Prometheus 必須有 otlp 設定（promote_resource_attributes）", { icon: "LuTriangleAlert", fill: C.badSoft, color: C.bad, sub: "否則觸發規則比對不到資料；raft 指標在 Confluent Server 沒有 JMX MBean，告警改用 controller 的 LastAppliedRecordLagMs 等", fs: 14, sfs: 12 });
  }

  // ================================================================= 8 webhook options
  {
    const s = slide("Webhook 要自訂 JSON：四種做法", "方案 E 是實測成功的做法：Prometheus 的 alerting 區塊同時列兩個 Alertmanager（C3 內建與我們自建），兩邊都收到告警，C3 重啟後仍然有效。方案 C 的代價是 C3 介面之後建立的動作不會被我們自己的設定採用。客戶若已有告警平台（Dynatrace Events API、Grafana webhook 自訂 payload）可直接接。");
    lead(s, "建議：先問客戶有沒有現成告警平台；沒有才走 E");
    const rows = [
      ["A", "只用 C3", [["C3 AM", C.blueSoft, C.blue], ["預設 JSON", C.soft, C.ink], ["目標", C.okSoft, C.ok]], ["不能自訂", C.bad]],
      ["A＋D", "C3 ＋ 轉換 gateway", [["C3 AM", C.blueSoft, C.blue], ["gateway", C.accentSoft, C.accent], ["指定 JSON", C.okSoft, C.ok]], ["可以，多一台", C.ok]],
      ["C", "改 Alertmanager 設定檔", [["C3 AM\n自訂 template", C.blueSoft, C.blue], ["指定 JSON", C.okSoft, C.ok]], ["介面新建動作失效", C.accent]],
      ["E", "Prometheus 送兩個 AM", [["Prometheus", C.blueSoft, C.blue], ["C3 AM → 預設", C.soft, C.ink], ["自建 AM → 指定 JSON", C.okSoft, C.ok]], ["兩邊都生效（已實測）", C.ok]],
    ];
    for (let r = 0; r < rows.length; r++) {
      const [k, name, items, [verdict, vcol]] = rows[r], y = 1.8 + r * 1.2;
      panel(s, M, y, CW, 1.05, C.white, C.line);
      s.addShape(pptx.ShapeType.ellipse, { x: M + 0.15, y: y + 0.25, w: 0.55, h: 0.55, fill: { color: C.head }, line: { color: C.head } });
      txt(s, k, { x: M + 0.15, y: y + 0.25, w: 0.55, h: 0.55, fontSize: k.length > 1 ? 11 : 16, bold: true, color: C.white, align: "center", valign: "middle" });
      txt(s, name, { x: M + 0.85, y, w: 2.5, h: 1.05, fontSize: 14, bold: true, valign: "middle" });
      const x0 = M + 3.5, bw = 1.95, g = 0.4;
      items.forEach(([t, fill, col], i) => {
        const x = x0 + i * (bw + g), w2 = i === 2 && r === 3 ? 2.3 : bw;
        panel(s, x, y + 0.2, w2, 0.65, fill);
        txt(s, t, { x, y: y + 0.2, w: w2, h: 0.65, fontSize: 11, bold: true, color: col, align: "center", valign: "middle" });
        if (i < items.length - 1) arrow(s, x + w2 + 0.04, y + 0.52, x + w2 + g - 0.04, y + 0.52);
      });
      chip(s, W - M - 2.35, y + 0.35, 2.2, verdict, vcol, C.white, 0.38);
    }
    txt(s, "客戶若已有平台：Dynatrace Events API（規則需 description 註解與 impact 標籤）、Grafana webhook 自訂 payload 可直接接", { x: M, y: 6.65, w: CW, h: 0.35, fontSize: 12, color: C.mute });
  }

  // ================================================================= 9 mTLS
  {
    const s = slide("Prometheus、Alertmanager、C3 之間是 mTLS", "設定檔：Prometheus 的 alerting 區塊用 scheme https，帶 cp-server 憑證當 client 憑證；Alertmanager 與 Prometheus 的 web config 都設 client_auth_type: RequireAndVerifyClientCert，client_ca_file 指向銀行 CA；C3 的 Java 用 cp-server.p12 連 Alertmanager。實測在 c3-01 用 curl 打 9093。注意：驗證的只有憑證是不是銀行 CA 簽的，沒有 CN 白名單；所有元件共用同一張 cp-server 憑證；9090／9093 另有防火牆擋住其他主機。");
    lead(s, "兩個方向都要求對方出示銀行 CA 簽的憑證");
    panel(s, M, 1.8, 6.6, 3.6, C.soft);
    txt(s, "c3-01", { x: M + 0.2, y: 1.85, w: 2, h: 0.4, fontSize: 14, bold: true, color: C.mute });
    await node(s, M + 0.3, 2.5, 2.3, 1.0, "Prometheus", { icon: "LuGauge", fill: C.blueSoft, color: C.blue });
    await node(s, M + 3.9, 2.5, 2.4, 1.0, "Alertmanager", { icon: "LuBell", fill: C.blueSoft, color: C.blue });
    await node(s, M + 0.3, 4.1, 2.3, 1.0, "C3（Java）", { icon: "LuMonitor", fill: C.tealSoft, color: C.teal });
    arrow(s, M + 2.65, 3.0, M + 3.85, 3.0, C.ok, 3);
    arrow(s, M + 2.65, 4.4, M + 4.6, 3.55, C.ok, 3);
    await badge(s, M + 3.25, 2.65, 0.4, "LuLock", C.ok);
    txt(s, "mTLS", { x: M + 2.7, y: 3.1, w: 1.2, h: 0.3, fontSize: 12, bold: true, color: C.ok, align: "center" });
    txt(s, "Prometheus 自己的 :9090 也要求 client 憑證", { x: M + 0.3, y: 5.0, w: 6.0, h: 0.3, fontSize: 11, color: C.mute });
    // test results
    txt(s, "lab 實測（curl 打 Alertmanager）", { x: M + 6.9, y: 1.8, w: 5.2, h: 0.4, fontSize: 17, bold: true });
    const T = [
      ["帶 cp-server 憑證", "200 通過", C.ok], ["不帶任何憑證", "握手被拒", C.bad], ["自簽（CN 也叫 cp-server）", "握手被拒", C.bad], ["銀行 CA 簽的另一張（svc-backup）", "200 也通過", C.accent],
    ];
    T.forEach(([a, b, col], i) => {
      const y = 2.3 + i * 0.75;
      panel(s, M + 6.9, y, CW - 6.9, 0.65, C.white, C.line);
      txt(s, a, { x: M + 7.05, y, w: 3.0, h: 0.65, fontSize: 12, valign: "middle" });
      chip(s, W - M - 1.75, y + 0.15, 1.6, b, col, C.white, 0.36);
    });
    await node(s, M, 5.65, CW, 1.15, "要收緊：只讓 cp-server 通過", { icon: "LuTriangleAlert", fill: C.accentSoft, color: C.accent, sub: "Prometheus 的 web config 沒有 CN 白名單。做法：C3 內部元件用專屬 CA 簽發；或維持現狀，靠防火牆限制來源（現行 9090／9093 不對外）", fs: 15, sfs: 12 });
  }

  // ================================================================= 10 SCRAM
  {
    const s = slide("SCRAM：不存明文、不傳明文", "SCRAM 是 challenge-response 機制（RFC 5802）。Kafka 存的是 salt、storedKey、serverKey、iterations；密碼本身不存在，連線時也不送。有沒有 TLS，這兩件事都成立；TLS 防止攻擊者拿到 storedKey 後離線暴力破解，並保護資料機密性。我們的 CLIENT、LDAP、TOKEN listener 都是 SASL_SSL。SCRAM-SHA-512 目前只有 IETF draft，沒有 RFC；SHA-256 是 RFC 7677。");
    lead(s, "客戶要的兩個證明：Kafka 沒存明文，連線也沒送明文");
    // sequence diagram
    const cx = M + 0.9, sx = M + 6.1, top = 1.85;
    await badge(s, cx, top + 0.3, 0.6, "LuUsers", C.ink);
    txt(s, "Client", { x: cx - 0.8, y: top + 0.65, w: 1.6, h: 0.3, fontSize: 14, bold: true, align: "center" });
    await badge(s, sx, top + 0.3, 0.6, "LuServerCog", C.accent);
    txt(s, "Broker", { x: sx - 0.8, y: top + 0.65, w: 1.6, h: 0.3, fontSize: 14, bold: true, align: "center" });
    s.addShape(pptx.ShapeType.line, { x: cx, y: top + 1.0, w: 0.001, h: 2.6, line: { color: C.line, width: 1.5, dashType: "dash" } });
    s.addShape(pptx.ShapeType.line, { x: sx, y: top + 1.0, w: 0.001, h: 2.6, line: { color: C.line, width: 1.5, dashType: "dash" } });
    const msgs = [["① 帳號 ＋ nonce", 1, C.blue], ["② salt、iterations、nonce", -1, C.accent], ["③ proof（不是密碼）", 1, C.ok], ["④ 伺服器簽章", -1, C.accent]];
    msgs.forEach(([t, dir, col], i) => {
      const y = top + 1.3 + i * 0.62;
      if (dir > 0) arrow(s, cx + 0.05, y, sx - 0.05, y, col, 2.5); else arrow(s, sx - 0.05, y, cx + 0.05, y, col, 2.5);
      txt(s, t, { x: cx + 0.2, y: y - 0.32, w: sx - cx - 0.4, h: 0.3, fontSize: 12, bold: true, color: col, align: "center" });
    });
    // storage box
    panel(s, M + 7.3, 1.85, CW - 7.3, 3.3, C.okSoft);
    txt(s, "controller 存的欄位", { x: M + 7.5, y: 1.95, w: 4.5, h: 0.4, fontSize: 16, bold: true, color: C.ok });
    ["salt", "storedKey", "serverKey", "iterations"].forEach((f, i) => { panel(s, M + 7.5, 2.45 + i * 0.5, 2.3, 0.4, C.white, C.ok); txt(s, f, { x: M + 7.5, y: 2.45 + i * 0.5, w: 2.3, h: 0.4, fontSize: 13, bold: true, color: C.ok, align: "center", valign: "middle" }); });
    await badge(s, M + 10.8, 3.0, 0.7, "LuCircleX", C.bad);
    txt(s, "沒有密碼欄位", { x: M + 9.95, y: 3.45, w: 2.0, h: 0.4, fontSize: 13, bold: true, color: C.bad, align: "center" });
    txt(s, "lab 已在 metadata log 驗證", { x: M + 7.5, y: 4.55, w: 4.5, h: 0.35, fontSize: 12, color: C.mute });
    panel(s, M, 4.55, 6.6, 0.6, C.tealSoft);
    txt(s, "TLS（SASL_SSL）是額外保護：防離線暴力破解、保護資料；不是「不傳明文」的前提", { x: M + 0.15, y: 4.55, w: 6.3, h: 0.6, fontSize: 12, bold: true, color: C.teal, valign: "middle" });
    table(s, [
      ["給客戶的連結", "證明什麼"],
      ["docs.confluent.io/platform/current/security/authentication/sasl/scram/overview.html", "Confluent 官方：不傳明文、只存加鹽雜湊"],
      ["rfc-editor.org/info/rfc5802", "SCRAM 演算法本身"],
      ["github.com/apache/kafka …/UserScramCredentialRecord.json", "controller 儲存的資料模型：沒有明文欄位"],
    ], { y: 5.35, colW: [7.2, 4.93], rowH: [0.35, 0.45, 0.4, 0.45], fontSize: 11 });
  }

  // ================================================================= 11 PKI
  {
    const s = slide("行內 CA 與憑證輪替：新舊並存，換完才刪", "先問清楚行內 CA 是幾層：只有 root，或 root＋中繼。哪一層的私鑰換掉，就決定下面哪些憑證必須重簽。順序一律：先讓 truststore 同時信任新舊 CA，再換憑證並 rolling restart，最後才把舊 CA 從 truststore 移除。provider 模式的 Conjur provider 使用的是 JDK cacerts，不是 truststore.p12，輪替時 cacerts 也要同步加新根、最後刪舊根。");
    lead(s, "三階段：新舊 CA 並存 → 換憑證＋rolling restart → 刪舊 CA");
    // chain
    await node(s, M, 1.85, 2.4, 0.9, "Root CA", { icon: "LuLandmark", fill: C.blueSoft, color: C.blue });
    arrow(s, M + 1.2, 2.8, M + 1.2, 3.25);
    await node(s, M, 3.3, 2.4, 0.9, "中繼 CA", { icon: "LuLandmark", fill: C.blueSoft, color: C.blue });
    arrow(s, M + 2.45, 3.75, M + 3.15, 3.2);
    arrow(s, M + 2.45, 3.75, M + 3.15, 4.3);
    await node(s, M + 3.2, 2.85, 2.9, 0.75, "server 憑證 ×2", { icon: "LuKey", fill: C.tealSoft, color: C.teal, sub: "Kafka 組件共用；internal 一張", fs: 13, sfs: 10 });
    await node(s, M + 3.2, 3.85, 2.9, 0.9, "client 憑證 ×n", { icon: "LuFileKey", fill: C.tealSoft, color: C.teal, sub: "REST→MDS、C3→MDS、Prometheus→AM、應用各一張", fs: 13, sfs: 10 });
    // what must be redone
    txt(s, "CA 變動時要重做的", { x: M + 6.5, y: 1.85, w: 5.6, h: 0.4, fontSize: 17, bold: true });
    const Q = [["Root 私鑰換", "中繼 CA 重簽 → 全部憑證重簽", C.badSoft, C.bad], ["中繼私鑰換", "server 與 client 憑證重簽", C.accentSoft, C.accent], ["中繼只續簽", "憑證鏈更新即可", C.okSoft, C.ok]];
    Q.forEach(([a, b, fill, col], i) => {
      const y = 2.35 + i * 0.8;
      panel(s, M + 6.5, y, CW - 6.5, 0.68, fill);
      txt(s, a, { x: M + 6.65, y, w: 1.8, h: 0.68, fontSize: 14, bold: true, color: col, valign: "middle" });
      txt(s, b, { x: M + 8.5, y, w: CW - 8.5, h: 0.68, fontSize: 13, color: C.ink, valign: "middle" });
    });
    // three phases
    const ph = [["1 並存", "truststore 加新 CA\n（舊 CA 保留）", C.tealSoft, C.teal], ["2 換憑證", "重簽 server／client\nrolling restart", C.tealSoft, C.teal], ["3 刪舊", "truststore 移除舊 CA\n再 rolling restart", C.accentSoft, C.accent]];
    const gap = 0.5, w = (CW - gap * 2) / 3;
    ph.forEach(([h, sub, fill, col], i) => {
      const x = M + i * (w + gap);
      panel(s, x, 5.0, w, 1.25, fill);
      txt(s, h, { x, y: 5.08, w, h: 0.4, fontSize: 16, bold: true, color: col, align: "center" });
      txt(s, sub, { x, y: 5.5, w, h: 0.7, fontSize: 13, align: "center" });
      if (i < 2) arrow(s, x + w + 0.05, 5.62, x + w + gap - 0.05, 5.62);
    });
    txt(s, "要問客戶：CA 是 root 還是 root＋中繼？憑證效期？誰簽發、多久能簽好？　JDK cacerts 也要同步加／刪", { x: M, y: 6.45, w: CW, h: 0.45, fontSize: 13, bold: true, color: C.accent });
  }

  // ================================================================= 12 CyberArk: people + keys
  {
    const s = slide("CyberArk（一）：人怎麼進來、金鑰放哪", "依與客戶討論的做法：客戶有 PAM（PVWA、PSMP、CPM），目前先當作沒有 CP（Credential Provider）、CCP、Conjur，明年購買後再接。人員用自己的 AD 帳密登入 CyberArk，由 PSMP 代登進操作機，進去就是 root。操作機上只有一組 SSH 金鑰對，私鑰只有 root 看得到（0400）。從操作機 ssh 到各主機（含自己）都用這把金鑰，公鑰預先放在各主機安裝與維運 user 的 authorized_keys，登入不輸入密碼；各主機以 sudoers 限制這個 user 能跑的指令，sudo 不需密碼。能進操作機的人就是 root、就拿得到私鑰，所以追溯依據是 PSMP 的登入紀錄與錄影，主機端的風險靠 sudoers 白名單壓住。");
    lead(s, "人員用 AD 帳密進 CyberArk → PSMP 代登成 root → 一組金鑰連全部主機");
    // main path
    await node(s, M, 2.0, 1.9, 1.2, "人員", { icon: "LuUsers", fill: C.soft, color: C.ink, sub: "AD 帳密" });
    arrow(s, M + 1.95, 2.6, M + 2.55, 2.6);
    await node(s, M + 2.6, 2.0, 2.1, 1.2, "CyberArk", { icon: "LuShieldCheck", fill: C.blueSoft, color: C.blue, sub: "綁 AD\nPSMP 代登、錄影" });
    arrow(s, M + 4.75, 2.6, M + 5.35, 2.6);
    await node(s, M + 5.4, 1.75, 3.0, 1.7, "操作機 ops02", { icon: "LuSquareTerminal", fill: C.tealSoft, color: C.teal, sub: "登入後是 root\nOP menu、安裝都在這" });
    arrow(s, M + 8.45, 2.6, M + 9.05, 2.6);
    await node(s, M + 9.1, 2.0, CW - 9.1, 1.2, "各主機（含自己）", { icon: "LuServer", fill: C.soft, color: C.ink, sub: "安裝與維運 user", fs: 13 });
    txt(s, "ssh 金鑰", { x: M + 8.4, y: 2.2, w: 1.0, h: 0.3, fontSize: 10, color: C.mute, align: "center" });
    // the key pair
    txt(s, "同一組金鑰對", { x: M, y: 3.6, w: 4, h: 0.4, fontSize: 17, bold: true });
    await node(s, M, 4.1, 3.9, 1.3, "私鑰", { icon: "LuKey", fill: C.accentSoft, color: C.accent, sub: "操作機，只有 root 看得到\n檔案權限 0400" });
    arrow(s, M + 3.95, 4.75, M + 4.65, 4.75, C.accent, 2.5, "dash");
    txt(s, "公鑰預先放入", { x: M + 3.6, y: 4.3, w: 1.4, h: 0.3, fontSize: 10, color: C.mute, align: "center" });
    await node(s, M + 4.7, 4.1, 3.9, 1.3, "公鑰", { icon: "LuFileKey", fill: C.tealSoft, color: C.teal, sub: "各主機 user 的 authorized_keys\n登入不輸入密碼" });
    await node(s, M + 8.8, 4.1, CW - 8.8, 1.3, "sudoers", { icon: "LuShield", fill: C.blueSoft, color: C.blue, sub: "限制可跑的指令清單\nNOPASSWD", sfs: 11 });
    // vault side
    await node(s, M, 5.65, 5.9, 1.2, "PVWA（vault）", { icon: "LuVault", fill: C.accentSoft, color: C.accent, sub: "保管 passphrase、master key、各帳密\n目前沒有 CP／CCP／Conjur：人工放進設定", sfs: 11 });
    await node(s, M + 6.1, 5.65, 2.85, 1.2, "CPM", { icon: "LuRepeat", fill: C.blueSoft, color: C.blue, sub: "換 root、svc-mds-bind", sfs: 11 });
    await node(s, M + 9.15, 5.65, CW - 9.15, 1.2, "AD", { icon: "LuIdCard", fill: C.okSoft, color: C.ok, sub: "CyberArk、OP menu、C3 都用本人帳號", sfs: 11 });
  }

  // ================================================================= 13 CyberArk: secrets matrix
  {
    const s = slide("CyberArk（二）：機敏值誰放、誰輪替", "目前客戶先當作沒有 CP、CCP、Conjur（明年購買），所以應用程式不能向 vault 取密碼，機敏值都是 PVWA 保管、人工放進設定。CPM 仍可輪替 root 與 svc-mds-bind。cpadmin 那組 SSH 私鑰存在操作機 root 的檔案裡，不是由 SSH Key Manager 推送，所以換金鑰是人工：產生新金鑰對，先把新公鑰加進各主機，確認可登入後再移除舊公鑰，可以零停機。私鑰不放 CyberArk，也不另外備份；操作機重建時重新產生金鑰對並重新佈署公鑰。Secret Protection 的 master key 輪替需要新舊 passphrase 與舊 master key，data key 不做例行輪替。MDS token 金鑰對固定不輪替。");
    lead(s, "CPM 只自動輪替 root 與 svc-mds-bind；其餘人工");
    const auto = (t) => ({ text: t, bold: true, color: C.ok, fill: C.okSoft });
    const man = (t) => ({ text: t, bold: true, color: C.accent, fill: C.accentSoft });
    table(s, [
      ["機敏值", "正本", "誰輪替", "輪替時的影響"],
      [B("SSH 金鑰對（連各主機）"), "私鑰：操作機 root 0400", man("人工"), "新公鑰先加、確認後再刪舊公鑰，可零停機"],
      [B("root"), "PVWA", auto("CPM"), "平常不用，僅供緊急"],
      [B("svc-mds-bind（AD 唯讀）"), "PVWA", auto("CPM"), "換完要更新 broker 設定；中間有短暫視窗"],
      [B("master key、passphrase"), "PVWA", man("人工（手冊 15 章）"), "rotate 需要新舊兩者；data key 不例行輪替"],
      [B("SCRAM 應用帳密"), "PVWA", man("人工"), "零停機要 A/B 兩組（見下頁）"],
      [B("kafka-admin"), "PVWA", man("人工：用完即換"), "只在維運時段使用"],
      [B("opmenu-breakglass 憑證"), "PVWA", man("人工（憑證效期）"), "緊急才用"],
      [B("MDS token 金鑰對"), "—", man("固定，外洩才換"), "換需要整組 broker 重啟"],
    ], { y: 1.75, colW: [3.1, 2.2, 2.4, 4.43], rowH: [0.42, 0.5, 0.5, 0.55, 0.55, 0.5, 0.5, 0.5, 0.5], fontSize: 12 });
    txt(s, "CPM 沒有 Kafka plugin；明年買 CP／CCP／Conjur 後，應用程式才能自己向 vault 取值", { x: M, y: 6.5, w: CW, h: 0.4, fontSize: 14, bold: true, color: C.bad });
  }

  // ================================================================= 14 zero downtime
  {
    const s = slide("零停機輪替：要兩組帳密（a 使用、b 閒置）", "SCRAM 同一 user 同一 mechanism 只有一組密碼，覆蓋後舊密碼立即失效；AD 帳號同一時間也只有一組有效密碼。所以零停機一定要兩組：先換閒置那組的密碼，所有 client 或 broker 切過去，再換另一組。CPM 排程輪替不知道哪一組使用中，會把使用中的那組改掉，所以 A/B 帳號在 PVWA 只做保管、手動輪替。CyberArk 的 Dual Accounts 可解，但要應用程式透過 CCP／AAM 取值；MDS 把密碼寫在設定檔，不會自己去取。目前設計：svc-mds-bind 由 CPM 輪替，接受短暫視窗；A/B 是客戶要求零停機時的替代。");
    lead(s, "先換閒置那組 → 全部切過去 → 再換原本那組");
    // timeline lanes
    const x0 = M + 1.3, lw = CW - 1.3, y0 = 1.9, lh = 0.8, seg = lw / 4;
    ["a", "b"].forEach((k, r) => { txt(s, `帳號 ${k}`, { x: M, y: y0 + r * 1.05, w: 1.2, h: lh, fontSize: 15, bold: true, valign: "middle" }); panel(s, x0, y0 + r * 1.05, lw, lh, C.soft); });
    const bar = (lane, from, to, t, fill, col) => { const x = x0 + from * seg + 0.05, w = (to - from) * seg - 0.1, y = y0 + lane * 1.05 + 0.1; panel(s, x, y, w, lh - 0.2, fill); txt(s, t, { x, y, w, h: lh - 0.2, fontSize: 12, bold: true, color: col, align: "center", valign: "middle" }); };
    bar(0, 0, 2, "使用中", C.okSoft, C.ok); bar(0, 2, 3, "仍有舊連線", C.soft, C.mute); bar(0, 3, 4, "換密碼 → 閒置", C.accentSoft, C.accent);
    bar(1, 0, 1, "閒置", C.soft, C.mute); bar(1, 1, 2, "換密碼", C.accentSoft, C.accent); bar(1, 2, 4, "使用中", C.okSoft, C.ok);
    const ev = ["1 換 b 的密碼", "2 全部切到 b", "3 確認 a 無連線", "4 換 a 的密碼"];
    ev.forEach((t, i) => txt(s, t, { x: x0 + i * seg, y: y0 + 2.2, w: seg, h: 0.35, fontSize: 12, bold: true, color: C.head, align: "center" }));
    [1, 2, 3].forEach((i) => s.addShape(pptx.ShapeType.line, { x: x0 + i * seg, y: y0, w: 0.001, h: 2.2, line: { color: C.mute, width: 1, dashType: "dash" } }));
    // application to our targets
    txt(s, "套到我們的帳號", { x: M, y: 4.7, w: 5, h: 0.4, fontSize: 17, bold: true });
    const gap = 0.3, w = (CW - gap * 2) / 3;
    const cards = [
      ["LuIdCard", "svc-mds-bind", "現行設計：單帳號，CPM 換完更新 broker 設定\n零停機：建 b 帳號、broker 滾動切換，關 CPM 自動變更", C.blueSoft, C.blue],
      ["LuKeyRound", "SCRAM 應用帳號", "A/B 兩個 user（權限同步）\n或同 user 兩個 mechanism（SHA-256／512）", C.tealSoft, C.teal],
      ["LuCircleHelp", "要問客戶", "MDS 查 AD 短暫失敗能不能接受？\n有無 CCP／AAM 或 Dual Accounts？", C.badSoft, C.bad],
    ];
    for (let i = 0; i < 3; i++) {
      const x = M + i * (w + gap);
      panel(s, x, 5.15, w, 1.7, cards[i][3]);
      await badge(s, x + 0.45, 5.6, 0.55, cards[i][0], cards[i][4]);
      txt(s, cards[i][1], { x: x + 0.9, y: 5.3, w: w - 1.0, h: 0.6, fontSize: 15, bold: true, color: cards[i][4], valign: "middle" });
      txt(s, cards[i][2], { x: x + 0.2, y: 5.95, w: w - 0.4, h: 0.85, fontSize: 11, color: C.ink });
    }
  }

  // ================================================================= 15 open questions
  {
    const s = slide("待確認清單：誰要回答什麼", "把前面各頁的待決事項依對象整理成一張表，可以直接拿去跟客戶與原廠對。");
    table(s, [
      ["對象", "問題", "影響"],
      [B("客戶"), "Staging 台數與 controller 是否合併（7 或 10 台）", "硬體採購、架構圖"],
      [B("客戶"), "每日筆數、尖峰倍數（0.58 MBps 的來源）", "磁碟與網路估算"],
      [B("客戶"), "有無現成告警平台；webhook 選 A／A＋D／C／E 哪一個", "是否要第二個 Alertmanager 或 gateway"],
      [B("AD 團隊"), "svc-mds-bind 能否接受短暫失敗，或要 A/B 兩組", "輪替流程、CPM 設定"],
      [B("CA 團隊"), "CA 層級、憑證效期、誰簽發與多久", "輪替時程"],
      [B("Secrets 團隊"), "PSMP 代登成 root 的帳號與 safe 權限；明年 CP／CCP／Conjur 的導入時程", "金鑰備份、輪替自動化"],
      [B("Confluent 原廠"), "C3 2.6.x 是否支援 JDK 25（書面）", "JDK 版本"],
      [B("Confluent 原廠"), "Dynatrace OneAgent 與 Confluent 組件的支援立場", "監控整合"],
    ], { y: 1.4, colW: [2.2, 6.9, 3.03], rowH: [0.42, 0.62, 0.62, 0.72, 0.62, 0.62, 0.72, 0.62, 0.62], fontSize: 13 });
  }

  // ================================================================= 16 appendix
  {
    const s = slide("附錄：原簡報修正對照", "列出分析原簡報時發現並在本版修正的地方，方便回頭對照原檔。");
    table(s, [
      ["原簡報", "問題", "本版處理"],
      ["硬體（第 2 頁）", "兩張圖沒標環境，「Staging 左圖、prod 右圖」容易讀反", "合併成一張表"],
      ["硬體附註", "0.58 MBps 與 125 萬筆×6 KB 的 0.087 MB/s 不符", "標為待確認"],
      ["第 2、5 頁", "Staging 硬體表 10 台，架構圖只有 7 台", "並列兩種，標為待確認"],
      ["JDK（第 4 頁）", "「理論上支援」是推論，易被當成原廠承諾", "標明依據，列為原廠待辦"],
      ["告警（第 7、8 頁）", "標題「無 prometheus」不精確；「ominbus」拼字", "改依告警路徑；改 omnibus"],
      ["SCRAM（第 9 頁）", "只列連結，沒說各自證明什麼", "每個連結標用途；補 TLS 說明"],
      ["憑證（第 10 頁）", "輪替條件與步驟混在同一頁", "拆成三階段與對照"],
      ["CyberArk（第 11、12 頁）", "PVWA 誤寫為 PCWA；含 Conjur 與 CCP，客戶目前沒有", "依與客戶討論的做法重畫"],
      ["輪替（第 13 頁）", "A/B 與 CPM 的取捨沒說明", "補時序圖與決策問題"],
    ], { y: 1.4, colW: [2.6, 5.6, 3.93], rowH: [0.42, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6], fontSize: 12 });
  }

  await pptx.writeFile({ fileName: out });
  console.log("wrote " + out);
}
main().catch((e) => { console.error(e); process.exit(1); });
