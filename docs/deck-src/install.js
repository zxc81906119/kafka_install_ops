// Builds the RPM install overview deck for bank managers (.pptx). Usage: node install.js <output.pptx>
// Install only (no day-2 operations), pictures over words, no implementation details.
const path = require("path");
const PptxGenJS = require("pptxgenjs");
const React = require("react");
const { renderToStaticMarkup } = require("react-dom/server");
const sharp = require("sharp");
const L = require("react-icons/lu");

const out = process.argv[2] || "install.pptx";
const NUM = (() => { try { return require("./numbers.json"); } catch { return {}; } })();
const VERIFY_TOTAL = NUM.verifyTotal || "55";

// ---- design tokens (same family as build.js)
const C = {
  ink: "17213A", body: "3D4659", mute: "6B7385", line: "D9DCE3", soft: "F2F4F7",
  dark: "17213A", accent: "D9661F", accentSoft: "FBEADF", teal: "1F7A8C", tealSoft: "E1F0F3",
  ok: "2E7D4F", okSoft: "E3F1E8", bad: "B23A3A", white: "FFFFFF",
};
const F = "Microsoft JhengHei";
const W = 13.33, M = 0.6;
const THEME = {
  name: "Confluent RPM Install",
  headFontFace: F, bodyFontFace: F,
  colors: {
    dk1: C.ink, lt1: C.white, dk2: C.dark, lt2: C.soft,
    accent1: C.teal, accent2: C.accent, accent3: C.ok, accent4: C.mute, accent5: "4E6E9E", accent6: C.bad,
    hlink: C.teal, folHlink: C.mute,
  },
};

const pptx = new PptxGenJS();
pptx.layout = "LAYOUT_WIDE";
pptx.title = "Confluent Platform 離線安裝流程（RPM）";
pptx.author = "PoC 團隊";
pptx.theme = { headFontFace: F, bodyFontFace: F };

pptx.defineSlideMaster({
  title: "CONTENT",
  background: { color: C.white },
  objects: [
    { placeholder: { options: { name: "title", type: "title", x: M, y: 0.95, w: W - 2 * M, h: 0.8, fontFace: F, fontSize: 30, bold: true, color: C.ink, valign: "middle", margin: 0 }, text: "" } },
    { text: { text: "Confluent Platform 離線安裝流程（RPM）", options: { x: M, y: 7.0, w: 8, h: 0.3, fontFace: F, fontSize: 11, color: C.mute, margin: 0 } } },
  ],
  slideNumber: { x: W - M - 0.6, y: 7.0, w: 0.6, h: 0.3, fontFace: F, fontSize: 11, color: C.mute, align: "right" },
});
pptx.defineSlideMaster({ title: "DARK", background: { color: C.dark } });

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
// icon inside a filled circle (the deck's motif); (cx, cy) = centre
async function badge(s, cx, cy, d, name, fill = C.teal, fg = C.white) {
  s.addShape(pptx.ShapeType.ellipse, { x: cx - d / 2, y: cy - d / 2, w: d, h: d, fill: { color: fill }, line: { color: fill } });
  const i = d * 0.56;
  s.addImage({ data: await icon(name, fg), x: cx - i / 2, y: cy - i / 2, w: i, h: i });
}
function txt(s, t, o) {
  s.addText(t, { isTextBox: true, fontFace: F, color: C.ink, margin: 0, valign: "top", ...o });
}
// text centred under a point
function under(s, cx, y, w, head, sub, o = {}) {
  txt(s, head, { x: cx - w / 2, y, w, h: 0.45, fontSize: o.headSize || 18, bold: true, align: "center", color: o.headColor || C.ink });
  if (sub) txt(s, sub, { x: cx - w / 2, y: y + 0.47, w, h: o.subH || 0.8, fontSize: o.subSize || 14, align: "center", color: C.body });
}
function arrow(s, x1, y1, x2, y2, color = C.mute, width = 2.25, dash) {
  s.addShape(pptx.ShapeType.line, {
    x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.max(Math.abs(x2 - x1), 0.001), h: Math.max(Math.abs(y2 - y1), 0.001),
    flipH: x2 < x1, flipV: (y2 < y1) !== (x2 < x1) && y1 !== y2,
    line: { color, width, endArrowType: "triangle", dashType: dash || "solid" },
  });
}
function panel(s, x, y, w, h, fill = C.soft, lineColor) {
  s.addShape(pptx.ShapeType.roundRect, { x, y, w, h, rectRadius: 0.12, fill: { color: fill }, line: { color: lineColor || fill, width: 1 } });
}

const STEPS = [
  ["下載", "LuDownload"], ["驗證", "LuShieldCheck"], ["上架", "LuDatabase"],
  ["主機準備", "LuServerCog"], ["安裝套件", "LuPackage"], ["憑證", "LuKeyRound"],
  ["設定啟動", "LuPlay"], ["權限", "LuUsers"], ["驗收", "LuListChecks"],
];
const PHASES = [["引進", 0, 3], ["準備與安裝", 3, 6], ["上線", 6, 9]];

// roadmap strip at the top of every step slide; current step highlighted
function nav(s, cur) {
  const n = STEPS.length, gap = 0.06, w = (W - 2 * M - gap * (n - 1)) / n, y = 0.32, h = 0.42;
  STEPS.forEach(([t], i) => {
    const x = M + i * (w + gap), on = i === cur;
    s.addShape(i === 0 ? pptx.ShapeType.homePlate : pptx.ShapeType.chevron, {
      x, y, w, h, fill: { color: on ? C.accent : (i < cur ? C.tealSoft : C.soft) }, line: { color: C.white, width: 0 },
    });
    txt(s, `${i + 1} ${t}`, {
      x: x + 0.15, y, w: w - 0.3, h, fontSize: 12, bold: on, align: "center", valign: "middle",
      color: on ? C.white : (i < cur ? C.teal : C.mute),
    });
  });
}
function stepSlide(cur, titleText, notes) {
  const s = pptx.addSlide({ masterName: "CONTENT" });
  nav(s, cur);
  s.addText(titleText, { placeholder: "title" });
  if (notes) s.addNotes(notes);
  return s;
}
function plainSlide(titleText, notes) {
  const s = pptx.addSlide({ masterName: "CONTENT" });
  s.addText(titleText, { placeholder: "title" });
  if (notes) s.addNotes(notes);
  return s;
}

async function main() {
  // ================================================================ 1 cover
  {
    const s = pptx.addSlide({ masterName: "DARK" });
    txt(s, "Confluent Platform 8.3 企業版", { x: 0.9, y: 2.0, w: 11.5, h: 0.6, fontSize: 24, color: "C9CFDB" });
    txt(s, "離線安裝流程（RPM）", { x: 0.9, y: 2.7, w: 11.5, h: 1.1, fontSize: 48, bold: true, color: C.white });
    txt(s, "從套件引進到驗收上線，九個步驟", { x: 0.9, y: 3.9, w: 11.5, h: 0.5, fontSize: 20, color: "C9CFDB" });
    const icons = STEPS.map((x) => x[1]);
    for (let i = 0; i < icons.length; i++) await badge(s, 1.25 + i * 0.95, 5.4, 0.7, icons[i], i < 3 ? C.teal : i < 6 ? "4E6E9E" : C.accent);
    s.addNotes("這份簡報只談安裝：從原廠套件引進行內，到整套平台驗收通過。日常維運另案說明。");
  }

  // ================================================================ 2 overview
  {
    const s = plainSlide("九個步驟，全程不連外網", "九個步驟分成三段：先把軟體安全地引進行內，再準備主機並安裝，最後設定、上線、驗收。除了第一步在外網下載，其餘全部在行內離線完成。");
    const gap = 0.3, pw = (W - 2 * M - gap * 2) / 3, py = 2.15, ph = 3.9;
    const fills = [C.tealSoft, "E6ECF5", C.accentSoft], ink = [C.teal, "4E6E9E", C.accent];
    for (let p = 0; p < 3; p++) {
      const [name, a, b] = PHASES[p], px = M + p * (pw + gap);
      panel(s, px, py, pw, ph, fills[p]);
      txt(s, name, { x: px + 0.3, y: py + 0.25, w: pw - 0.6, h: 0.5, fontSize: 20, bold: true, color: ink[p] });
      const step = pw / 3;
      for (let i = a; i < b; i++) {
        const cx = px + step * (i - a) + step / 2;
        await badge(s, cx, py + 1.75, 0.95, STEPS[i][1], ink[p]);
        txt(s, String(i + 1), { x: cx - 0.6, y: py + 2.4, w: 1.2, h: 0.4, fontSize: 14, bold: true, align: "center", color: ink[p] });
        txt(s, STEPS[i][0], { x: cx - 0.65, y: py + 2.8, w: 1.3, h: 0.45, fontSize: 17, bold: true, align: "center" });
        if (i < b - 1) arrow(s, cx + 0.58, py + 1.75, cx + step - 0.58, py + 1.75, ink[p], 1.75);
      }
      if (p < 2) arrow(s, px + pw + 0.02, py + 1.75, px + pw + gap - 0.02, py + 1.75, C.mute, 2.5);
    }
    await badge(s, M + 0.3, 6.5, 0.42, "LuWifiOff", C.ink);
    txt(s, "只有第 1 步在外網；第 2 步起全部在行內離線完成", { x: M + 0.65, y: 6.3, w: 10, h: 0.4, fontSize: 15, color: C.body, valign: "middle" });
  }

  // ================================================================ 3 architecture
  {
    const s = plainSlide("安裝範圍：一套高可用的 Kafka 平台", "畫面上每個方塊都是一台或一組主機。核心是 Kafka 叢集：3 台 controller 管理叢集、4 台 broker 存放資料，壞一台不影響服務。人員從 Control Center 管理，應用程式直連 Kafka 或經 REST 介面。所有安裝動作都由操作機執行。");
    // actors
    await badge(s, 1.25, 2.75, 0.85, "LuUsers", C.ink);
    under(s, 1.25, 3.25, 1.8, "人員", null, { headSize: 16 });
    await badge(s, 1.25, 4.75, 0.85, "LuBot", C.ink);
    under(s, 1.25, 5.25, 1.8, "應用程式", null, { headSize: 16 });
    // load balancer
    panel(s, 2.6, 3.25, 1.7, 1.0, C.soft, C.line);
    txt(s, "負載平衡", { x: 2.6, y: 3.25, w: 1.7, h: 1.0, fontSize: 16, bold: true, align: "center", valign: "middle" });
    arrow(s, 1.75, 2.85, 2.6, 3.55);
    arrow(s, 1.75, 4.65, 2.6, 3.95);
    // edge services
    panel(s, 4.9, 2.15, 2.4, 1.3, C.tealSoft);
    await badge(s, 5.4, 2.8, 0.6, "LuNetwork", C.teal);
    txt(s, "REST 介面\n×2", { x: 5.8, y: 2.15, w: 1.45, h: 1.3, fontSize: 15, bold: true, valign: "middle", color: C.teal });
    panel(s, 4.9, 4.0, 2.4, 1.15, C.tealSoft);
    await badge(s, 5.4, 4.575, 0.6, "LuMonitor", C.teal);
    txt(s, "Control\nCenter", { x: 5.8, y: 4.0, w: 1.45, h: 1.15, fontSize: 15, bold: true, valign: "middle", color: C.teal });
    arrow(s, 4.3, 3.55, 4.9, 2.95);
    arrow(s, 4.3, 3.95, 4.9, 4.45);
    // kafka cluster
    const kx = 7.9, ky = 1.95, kw = W - M - kx, kh = 3.6;
    panel(s, kx, ky, kw, kh, C.accentSoft);
    txt(s, "Kafka 叢集", { x: kx + 0.25, y: ky + 0.15, w: 3, h: 0.45, fontSize: 18, bold: true, color: C.accent });
    for (let i = 0; i < 3; i++) await badge(s, kx + 0.65 + i * 0.78, ky + 1.15, 0.62, "LuServerCog", C.accent);
    txt(s, "Controller ×3\n管理叢集", { x: kx + 3.2, y: ky + 0.75, w: 1.6, h: 0.8, fontSize: 14, bold: true, color: C.ink, valign: "middle" });
    for (let i = 0; i < 4; i++) await badge(s, kx + 0.65 + i * 0.78, ky + 2.45, 0.62, "LuServer", C.accent);
    txt(s, "Broker ×4\n存放資料", { x: kx + 3.45, y: ky + 2.05, w: 1.3, h: 0.8, fontSize: 14, bold: true, color: C.ink, valign: "middle" });
    arrow(s, 7.3, 2.8, kx, 2.8);
    arrow(s, 7.3, 4.575, kx, 4.575);
    arrow(s, 1.75, 5.15, kx, 5.4, C.mute, 1.5, "dash");
    // support hosts
    await badge(s, 3.0, 6.2, 0.6, "LuLaptop", C.mute);
    txt(s, "操作機：執行全部安裝", { x: 3.4, y: 6.0, w: 3.6, h: 0.4, fontSize: 14, color: C.body, valign: "middle" });
    await badge(s, 8.3, 6.2, 0.6, "LuIdCard", C.mute);
    txt(s, "行內 AD：人員身分", { x: 8.7, y: 6.0, w: 3.6, h: 0.4, fontSize: 14, color: C.body, valign: "middle" });
  }

  // ================================================================ 4 prerequisites
  {
    const s = plainSlide("開始前，銀行需備妥五件事", "這五項是銀行端要先準備的。最常卡關的是第二項：主機要能從行內的 RHEL 套件來源安裝作業系統套件，Satellite、內部鏡像或安裝光碟都可以。AD 只需要人員群組，加上一個沒有任何管理權限的唯讀查詢帳號；平台內部的服務一律用憑證識別，不在 AD 建帳號。");
    const items = [
      ["LuServer", "RHEL 9 主機", "依角色準備\n規格與數量"],
      ["LuDatabase", "OS 套件來源", "Satellite、鏡像\n或安裝光碟"],
      ["LuIdCard", "AD", "人員群組\n＋唯讀查詢帳號"],
      ["LuStamp", "憑證窗口", "由銀行 CA\n簽發憑證"],
      ["LuFileText", "授權檔", "Confluent\n企業版授權"],
    ];
    const gap = 0.3, cw = (W - 2 * M - gap * 4) / 5, cy = 2.2, ch = 3.9;
    for (let i = 0; i < items.length; i++) {
      const x = M + i * (cw + gap), [ic, h, b] = items[i];
      panel(s, x, cy, cw, ch, C.soft);
      await badge(s, x + cw / 2, cy + 1.0, 1.1, ic, i === 1 ? C.accent : C.teal);
      under(s, x + cw / 2, cy + 1.9, cw - 0.2, h, b, { subH: 1.0, subSize: 15 });
    }
  }

  // ================================================================ 5 step 1 download
  {
    const s = stepSlide(0, "只帶原廠套件，OS 套件由行內提供", "在可連外的下載機取得原廠套件：Confluent 與 Java，都帶有原廠簽章。作業系統需要的套件不由我們帶入，只列出套件名稱，交給行內 OS 團隊從既有來源提供，這樣版本與修補都在行內原本的管理流程內。");
    await badge(s, 2.0, 3.9, 1.7, "LuGlobe", C.teal);
    under(s, 2.0, 4.95, 2.6, "外網下載機", "唯一可連外的一步");
    const rows = [
      ["LuPackage", "Confluent 套件", "原廠簽章", C.accent, C.accentSoft, false],
      ["LuCoffee", "Java 套件", "原廠簽章", C.accent, C.accentSoft, false],
      ["LuListChecks", "OS 套件清單", "只列名稱，交給行內 OS 團隊", C.teal, C.white, true],
    ];
    for (let i = 0; i < rows.length; i++) {
      const [ic, h, b, col, fill, dashed] = rows[i], y = 2.15 + i * 1.5;
      s.addShape(pptx.ShapeType.roundRect, { x: 5.2, y, w: 7.5, h: 1.15, rectRadius: 0.12, fill: { color: fill }, line: { color: dashed ? C.teal : fill, width: 1.5, dashType: dashed ? "dash" : "solid" } });
      await badge(s, 5.85, y + 0.575, 0.75, ic, col);
      txt(s, h, { x: 6.5, y: y + 0.15, w: 5.9, h: 0.45, fontSize: 19, bold: true });
      txt(s, b, { x: 6.5, y: y + 0.6, w: 5.9, h: 0.4, fontSize: 15, color: C.body });
      arrow(s, 3.0, 3.9, 5.2, y + 0.575, C.mute, 1.75, dashed ? "dash" : "solid");
    }
  }

  // ================================================================ 6 step 2 verify
  {
    const s = stepSlide(1, "三道檢查全部通過才放行", "每個檔案都要通過三道檢查：原廠簽章確認來源、指紋比對確認內容沒有被改過、再交給行內資安掃描。任何一項不通過就退回，不會進入行內。");
    const cy = 3.7;
    await badge(s, 1.3, cy, 1.15, "LuPackage", C.mute);
    under(s, 1.3, cy + 0.75, 2.0, "下載的套件", null, { headSize: 16 });
    const checks = [["LuShieldCheck", "簽章", "來源是原廠"], ["LuFingerprint", "指紋", "內容未被竄改"], ["LuScanSearch", "掃描", "行內資安規範"]];
    for (let i = 0; i < 3; i++) {
      const cx = 3.6 + i * 2.2;
      await badge(s, cx, cy, 1.15, checks[i][0], C.teal);
      under(s, cx, cy + 0.75, 2.0, checks[i][1], checks[i][2], { headSize: 17 });
      arrow(s, cx - 1.6 + (i === 0 ? 0 : 0.05), cy, cx - 0.65, cy);
    }
    // gate
    s.addShape(pptx.ShapeType.diamond, { x: 9.15, y: cy - 0.75, w: 1.5, h: 1.5, fill: { color: C.accentSoft }, line: { color: C.accent, width: 1.5 } });
    txt(s, "全部\n通過？", { x: 9.15, y: cy - 0.75, w: 1.5, h: 1.5, fontSize: 15, bold: true, align: "center", valign: "middle", color: C.accent });
    arrow(s, 8.5, cy, 9.15, cy);
    arrow(s, 10.65, cy - 0.1, 11.4, cy - 1.15, C.ok);
    arrow(s, 10.65, cy + 0.1, 11.4, cy + 1.15, C.bad);
    await badge(s, 11.95, cy - 1.35, 0.85, "LuCircleCheck", C.ok);
    txt(s, "放行", { x: 11.45, y: cy - 0.85, w: 1.0, h: 0.4, fontSize: 17, bold: true, align: "center", color: C.ok });
    await badge(s, 11.95, cy + 1.15, 0.85, "LuCircleX", C.bad);
    txt(s, "退回", { x: 11.45, y: cy + 1.65, w: 1.0, h: 0.4, fontSize: 17, bold: true, align: "center", color: C.bad });
  }

  // ================================================================ 7 step 3 exchange + publish
  {
    const s = stepSlide(2, "只有驗證過的檔案能進內網", "驗證過的檔案經行內既有的檔案交換平台進入內網，再上架到內部套件庫。上架時會再驗一次，同名但內容不同的檔案會被拒絕。之後所有主機都只從這個套件庫安裝。");
    const zones = [
      [M, 3.5, "外網區", "可連外", "LuLaptop", "下載與驗證", C.soft, C.mute],
      [M + 3.85, 3.5, "行內檔案交換", "依行內規範", "LuArrowRightLeft", "傳遞檔案", "E6ECF5", "4E6E9E"],
      [M + 7.7, W - 2 * M - 7.7, "內網", "完全不連外", "LuDatabase", "內部套件庫", C.tealSoft, C.teal],
    ];
    for (let i = 0; i < zones.length; i++) {
      const [x, w, name, sub, ic, label, fill, col] = zones[i];
      panel(s, x, 2.1, w, 4.1, fill);
      txt(s, name, { x: x + 0.3, y: 2.3, w: w - 0.6, h: 0.45, fontSize: 19, bold: true, color: col });
      txt(s, sub, { x: x + 0.3, y: 2.75, w: w - 0.6, h: 0.4, fontSize: 14, color: C.body });
      await badge(s, x + w / 2, 4.15, 1.25, ic, col);
      under(s, x + w / 2, 5.0, w - 0.4, label, null, { headSize: 17 });
    }
    for (let i = 0; i < 2; i++) arrow(s, zones[i][0] + zones[i][1] / 2 + 0.75, 4.15, zones[i + 1][0] + zones[i + 1][1] / 2 - 0.75, 4.15, C.ink, 2.5);
    const zx = zones[2][0], zw = zones[2][1];
    await badge(s, zx + zw - 0.55, 2.55, 0.55, "LuWifiOff", C.teal);
    await badge(s, zx + zw / 2 + 0.75, 3.6, 0.5, "LuShieldCheck", C.ok);
    txt(s, "上架前再驗一次", { x: zx + 0.3, y: 5.55, w: zw - 0.6, h: 0.4, fontSize: 14, align: "center", color: C.ok, bold: true });
  }

  // ================================================================ 8 step 4 host baseline
  {
    const s = stepSlide(3, "每台主機設定一致", "安裝 Kafka 之前，先把每台主機的作業系統設定調成一致：系統參數、時間同步、防火牆、服務專用帳號、信任行內憑證、安全設定。全部依同一份標準套用，可以重複執行，結果不變。");
    const cx = W / 2, cy = 4.15;
    const left = [["LuSlidersHorizontal", "系統參數"], ["LuClock", "時間同步"], ["LuBrickWall", "防火牆"]];
    const right = [["LuUserCog", "服務帳號"], ["LuBadgeCheck", "信任憑證"], ["LuShield", "安全設定"]];
    for (let i = 0; i < 3; i++) {
      const y = 2.5 + i * 1.6;
      s.addShape(pptx.ShapeType.line, { x: 3.4, y: Math.min(y, cy), w: cx - 0.9 - 3.4, h: Math.max(Math.abs(cy - y), 0.001), flipV: y > cy, line: { color: C.line, width: 1.5 } });
      s.addShape(pptx.ShapeType.line, { x: cx + 0.9, y: Math.min(y, cy), w: W - 3.4 - cx - 0.9, h: Math.max(Math.abs(cy - y), 0.001), flipV: y < cy, line: { color: C.line, width: 1.5 } });
      await badge(s, 3.0, y, 0.8, left[i][0], C.teal);
      txt(s, left[i][1], { x: M, y: y - 0.25, w: 1.95, h: 0.5, fontSize: 18, bold: true, align: "right", valign: "middle" });
      await badge(s, W - 3.0, y, 0.8, right[i][0], C.teal);
      txt(s, right[i][1], { x: W - 2.45, y: y - 0.25, w: 1.95, h: 0.5, fontSize: 18, bold: true, valign: "middle" });
    }
    await badge(s, cx, cy, 1.8, "LuServer", C.accent);
    under(s, cx, cy + 1.05, 3.0, "每一台都相同", "可重複執行，結果不變", { headSize: 18 });
  }

  // ================================================================ 9 step 5 install packages
  {
    const s = stepSlide(4, "先試算，通過才安裝，裝完鎖定版本", "安裝前先試算：系統會算出每台主機要裝哪些套件、缺不缺東西，但不會真的安裝。試算通過才正式安裝，而且只裝指定的版本。裝完把版本鎖定，日後作業系統例行更新時，不會把 Kafka 一起誤升級。");
    const steps = [
      ["LuDatabase", "內部套件庫", "原廠套件\n＋ 行內 OS 套件", C.teal],
      ["LuCalculator", "試算", "算出要裝什麼\n不動主機", C.accent],
      ["LuPackage", "安裝", "只裝指定版本", C.teal],
      ["LuLock", "鎖定版本", "例行更新\n不會誤升級", C.teal],
    ];
    const sx = 1.7, step = (W - 2 * sx) / 3, cy = 3.25;
    for (let i = 0; i < steps.length; i++) {
      const cx = sx + i * step, [ic, h, b, col] = steps[i];
      await badge(s, cx, cy, 1.3, ic, col);
      under(s, cx, cy + 0.85, 2.6, h, b, { headSize: 19, subSize: 15 });
      if (i < 3) arrow(s, cx + 0.8, cy, cx + step - 0.8, cy, C.ink, 2.5);
    }
    // per-role chips
    const roles = ["Controller", "Broker", "REST 介面", "Control Center", "操作機"];
    txt(s, "每台主機依角色安裝需要的套件", { x: M, y: 5.45, w: W - 2 * M, h: 0.4, fontSize: 15, color: C.body, align: "center" });
    const cw = 2.0, gap = 0.25, tot = roles.length * cw + (roles.length - 1) * gap, x0 = (W - tot) / 2;
    roles.forEach((r, i) => {
      s.addShape(pptx.ShapeType.roundRect, { x: x0 + i * (cw + gap), y: 5.95, w: cw, h: 0.55, rectRadius: 0.27, fill: { color: C.soft }, line: { color: C.line } });
      txt(s, r, { x: x0 + i * (cw + gap), y: 5.95, w: cw, h: 0.55, fontSize: 14, bold: true, align: "center", valign: "middle" });
    });
  }

  // ================================================================ 10 step 6 certificates
  {
    const s = stepSlide(5, "憑證由銀行 CA 簽發，匯入前先檢查", "平台之間的連線全部加密，需要憑證。我們在行內產生申請單送給銀行 CA，私鑰不離開行內。銀行 CA 簽發後，匯入前會先自動檢查名稱、用途、效期與憑證鏈，確認無誤才部署到各主機。");
    const laneX = M, laneW = W - 2 * M;
    panel(s, laneX, 2.05, laneW, 1.95, C.soft);
    panel(s, laneX, 4.2, laneW, 1.95, C.accentSoft);
    txt(s, "我方", { x: laneX + 0.25, y: 2.15, w: 1.2, h: 0.4, fontSize: 16, bold: true, color: C.teal });
    txt(s, "銀行 CA", { x: laneX + 0.25, y: 4.3, w: 1.5, h: 0.4, fontSize: 16, bold: true, color: C.accent });
    const pts = [
      [2.9, 3.0, "LuFileText", "產生申請單", C.teal],
      [5.6, 5.15, "LuStamp", "簽發憑證", C.accent],
      [8.3, 3.0, "LuSearchCheck", "匯入前檢查", C.teal],
      [11.0, 3.0, "LuServer", "部署到主機", C.teal],
    ];
    for (let i = 0; i < pts.length; i++) {
      const [cx, cy, ic, h, col] = pts[i];
      await badge(s, cx, cy - 0.2, 0.95, ic, col);
      txt(s, h, { x: cx - 1.2, y: cy + 0.35, w: 2.4, h: 0.45, fontSize: 17, bold: true, align: "center" });
      if (i < pts.length - 1) {
        const [nx, ny] = pts[i + 1];
        if (ny === cy) arrow(s, cx + 0.6, cy - 0.2, nx - 0.6, ny - 0.2, C.ink);
        else arrow(s, cx + 0.55, cy + 0.05, nx - 0.55, ny - 0.45, C.ink);
      }
    }
    await badge(s, M + 0.3, 6.5, 0.42, "LuKeyRound", C.ink);
    txt(s, "私鑰留在行內，只送出申請單", { x: M + 0.65, y: 6.3, w: 8, h: 0.4, fontSize: 15, color: C.body, valign: "middle" });
  }

  // ================================================================ 11 step 7 configure + start
  {
    const s = stepSlide(6, "依序啟動，健康才進下一段", "設定檔依角色產生並派送，密碼加密保存。啟動有固定順序：先啟動管理叢集的 controller，確認健康後再啟動存放資料的 broker，最後才啟動對外的 REST 介面與 Control Center。每一段都要通過健康檢查才會繼續。");
    const stages = [
      ["Controller", ["LuServerCog", "LuServerCog", "LuServerCog"], C.accent],
      ["Broker", ["LuServer", "LuServer", "LuServer", "LuServer"], C.accent],
      ["REST 介面 ／ Control Center", ["LuNetwork", "LuNetwork", "LuMonitor"], C.teal],
    ];
    const sw = 3.1, gapW = 1.45, sx = M, sy = 2.35, sh = 2.7;
    for (let i = 0; i < stages.length; i++) {
      const [name, ics, col] = stages[i], n = ics.length, x = sx + i * (sw + gapW);
      panel(s, x, sy, sw, sh, i < 2 ? C.accentSoft : C.tealSoft);
      txt(s, `${i + 1}`, { x: x + 0.25, y: sy + 0.2, w: 0.6, h: 0.5, fontSize: 22, bold: true, color: col });
      txt(s, name, { x: x + 0.25, y: sy + 0.75, w: sw - 0.4, h: 0.45, fontSize: 16, bold: true });
      const d = 0.6, g = 0.12, tw = n * d + (n - 1) * g;
      for (let k = 0; k < n; k++) await badge(s, x + (sw - tw) / 2 + d / 2 + k * (d + g), sy + 1.85, d, ics[k], col);
      if (i < 2) {
        const hx = x + sw + gapW / 2;
        await badge(s, hx, sy + sh / 2, 0.8, "LuHeartPulse", C.ok);
        txt(s, "健康檢查", { x: hx - 0.7, y: sy + sh / 2 + 0.5, w: 1.4, h: 0.4, fontSize: 14, bold: true, align: "center", color: C.ok });
        arrow(s, x + sw + 0.05, sy + sh / 2, hx - 0.45, sy + sh / 2, C.ok, 1.75);
        arrow(s, hx + 0.45, sy + sh / 2, x + sw + gapW - 0.05, sy + sh / 2, C.ok, 1.75);
      }
    }
    await badge(s, M + 0.3, 5.75, 0.42, "LuLockKeyhole", C.ink);
    txt(s, "設定檔依角色產生，密碼加密保存", { x: M + 0.65, y: 5.55, w: 8, h: 0.4, fontSize: 15, color: C.body, valign: "middle" });
    await badge(s, M + 0.3, 6.4, 0.42, "LuCircleX", C.ink);
    txt(s, "任何一段不健康就停止，修正後可從中斷處繼續", { x: M + 0.65, y: 6.2, w: 10, h: 0.4, fontSize: 15, color: C.body, valign: "middle" });
  }

  // ================================================================ 12 step 8 access
  {
    const s = stepSlide(7, "人與程式分開認證，權限一律控管", "人員用行內 AD 帳號登入，權限依 AD 群組決定；應用程式各自有專屬帳號或憑證，只拿得到自己需要的資料。所有連線都加密，所有存取都經過權限控管並留下稽核紀錄。");
    await badge(s, 1.6, 2.95, 1.1, "LuUsers", C.teal);
    txt(s, "人員", { x: 2.35, y: 2.55, w: 2.5, h: 0.45, fontSize: 19, bold: true });
    txt(s, "行內 AD 帳號登入", { x: 2.35, y: 3.0, w: 2.6, h: 0.4, fontSize: 15, color: C.body });
    await badge(s, 1.6, 5.05, 1.1, "LuBot", C.teal);
    txt(s, "應用程式", { x: 2.35, y: 4.65, w: 2.5, h: 0.45, fontSize: 19, bold: true });
    txt(s, "專屬帳號或憑證", { x: 2.35, y: 5.1, w: 2.6, h: 0.4, fontSize: 15, color: C.body });
    const gx = 6.85, gy = 4.0;
    arrow(s, 5.0, 2.95, gx - 0.95, gy - 0.35, C.ink);
    arrow(s, 5.0, 5.05, gx - 0.95, gy + 0.35, C.ink);
    await badge(s, gx, gy, 1.7, "LuShieldCheck", C.accent);
    under(s, gx, gy + 0.95, 3.2, "權限控管", "依角色授權\n存取全部留紀錄", { headSize: 19 });
    arrow(s, gx + 0.95, gy, 10.15, gy, C.ink, 2.5);
    await badge(s, 11.1, gy, 1.5, "LuLayers", C.ink);
    under(s, 11.1, gy + 0.85, 2.4, "Kafka 平台", null, { headSize: 18 });
    s.addShape(pptx.ShapeType.roundRect, { x: 9.6, y: 2.05, w: W - M - 9.6, h: 0.6, rectRadius: 0.3, fill: { color: C.okSoft }, line: { color: C.okSoft } });
    await badge(s, 9.95, 2.35, 0.42, "LuLock", C.ok);
    txt(s, "所有連線加密", { x: 10.25, y: 2.05, w: 2.4, h: 0.6, fontSize: 15, bold: true, color: C.ok, valign: "middle" });
  }

  // ================================================================ 13 step 9 acceptance
  {
    const s = stepSlide(8, "逐項驗收，全數通過才算完成", `安裝的最後一步是自動驗收，共 ${VERIFY_TOTAL} 項，涵蓋叢集運作、加密連線、身分與權限、高可用切換、監控與離線隔離。全部通過才算安裝完成。另外，同一份設定再執行一次安裝，結果是零變更，代表流程可以安全地重複執行。`);
    panel(s, M, 2.15, 3.6, 4.2, C.accentSoft);
    txt(s, VERIFY_TOTAL, { x: M, y: 2.6, w: 3.6, h: 1.5, fontSize: 80, bold: true, align: "center", valign: "middle", color: C.accent });
    txt(s, "項驗收", { x: M, y: 4.1, w: 3.6, h: 0.5, fontSize: 20, bold: true, align: "center" });
    txt(s, "全數通過", { x: M, y: 4.65, w: 3.6, h: 0.5, fontSize: 20, bold: true, align: "center", color: C.ok });
    txt(s, "再執行一次安裝：零變更", { x: M + 0.2, y: 5.45, w: 3.2, h: 0.5, fontSize: 14, align: "center", color: C.body });
    const tiles = [
      ["LuActivity", "叢集運作"], ["LuLock", "加密連線"], ["LuIdCard", "身分與權限"],
      ["LuRefreshCw", "高可用切換"], ["LuChartLine", "監控"], ["LuWifiOff", "離線隔離"],
    ];
    const gx = M + 3.9, gw = W - M - gx, tw = (gw - 0.3 * 2) / 3, th = (4.2 - 0.3) / 2;
    for (let i = 0; i < tiles.length; i++) {
      const x = gx + (i % 3) * (tw + 0.3), y = 2.15 + Math.floor(i / 3) * (th + 0.3);
      panel(s, x, y, tw, th, C.soft);
      await badge(s, x + tw / 2, y + 0.75, 0.85, tiles[i][0], C.teal);
      txt(s, tiles[i][1], { x, y: y + 1.3, w: tw, h: 0.45, fontSize: 18, bold: true, align: "center" });
      s.addImage({ data: await icon("LuCircleCheck", C.ok), x: x + tw - 0.55, y: y + 0.2, w: 0.35, h: 0.35 });
    }
  }

  // ================================================================ 14 responsibilities
  {
    const s = plainSlide("分工：銀行備妥環境，我方執行安裝", "實心圓是主要負責，空心圓是協助。銀行端主要負責提供環境：檔案交換、主機、OS 套件來源、AD 帳號與憑證簽發；其餘由我方執行，最後雙方共同驗收。");
    // [我方, 銀行, 銀行說明]  2 = 主責, 1 = 協助, 0 = 無
    const R = [
      [2, 0, ""], [2, 1, "資安掃描"], [2, 2, "檔案交換"], [2, 2, "提供主機"], [2, 1, "OS 套件"],
      [1, 2, "CA 簽發"], [2, 0, ""], [2, 1, "AD 群組"], [2, 2, "共同驗收"],
    ];
    const lx = M, lw = 1.5, cx0 = lx + lw, cw = (W - M - cx0) / 9, top = 1.95;
    for (let i = 0; i < 9; i++) {
      const x = cx0 + i * cw, col = i < 3 ? C.teal : i < 6 ? "4E6E9E" : C.accent;
      await badge(s, x + cw / 2, top + 0.4, 0.62, STEPS[i][1], col);
      txt(s, `${i + 1} ${STEPS[i][0]}`, { x, y: top + 0.8, w: cw, h: 0.4, fontSize: 13, bold: true, align: "center" });
    }
    const rows = [["我方", 0], ["銀行", 1]];
    for (const [name, r] of rows) {
      const y = top + 1.4 + r * 1.5;
      panel(s, lx, y, W - 2 * M, 1.3, r === 0 ? C.tealSoft : C.accentSoft);
      txt(s, name, { x: lx + 0.25, y, w: lw - 0.3, h: 1.3, fontSize: 20, bold: true, valign: "middle", color: r === 0 ? C.teal : C.accent });
      for (let i = 0; i < 9; i++) {
        const v = R[i][r], x = cx0 + i * cw + cw / 2, col = r === 0 ? C.teal : C.accent;
        if (v) s.addShape(pptx.ShapeType.ellipse, { x: x - 0.2, y: y + 0.25, w: 0.4, h: 0.4, fill: { color: v === 2 ? col : C.white }, line: { color: col, width: 2.25 } });
        if (r === 1 && R[i][2]) txt(s, R[i][2], { x: x - cw / 2, y: y + 0.75, w: cw, h: 0.4, fontSize: 13, align: "center", color: C.body });
      }
    }
    const ly = 6.3;
    s.addShape(pptx.ShapeType.ellipse, { x: M, y: ly + 0.05, w: 0.3, h: 0.3, fill: { color: C.ink }, line: { color: C.ink, width: 2 } });
    txt(s, "主要負責", { x: M + 0.4, y: ly, w: 1.5, h: 0.4, fontSize: 14, valign: "middle", color: C.body });
    s.addShape(pptx.ShapeType.ellipse, { x: M + 2.0, y: ly + 0.05, w: 0.3, h: 0.3, fill: { color: C.white }, line: { color: C.ink, width: 2 } });
    txt(s, "協助", { x: M + 2.4, y: ly, w: 1.5, h: 0.4, fontSize: 14, valign: "middle", color: C.body });
  }

  await pptx.writeFile({ fileName: out });
  // optional: write THEME colors into the deck theme (all slide colors are explicit hex, so this is cosmetic)
  const themer = process.env.PPTX_SKILL_DIR && path.join(process.env.PPTX_SKILL_DIR, "scripts", "apply_theme.js");
  if (themer && require("fs").existsSync(themer)) await require(themer).applyTheme(out, THEME);
  console.log("wrote " + out);
}

main().catch((e) => { console.error(e); process.exit(1); });
