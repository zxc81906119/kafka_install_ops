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
    const s = plainSlide("安裝範圍：一套高可用的 Kafka 平台", "畫面上每個方塊都是一台或一組主機。核心是 Kafka 叢集：3 台 controller 管理叢集、4 台 broker 存放資料，壞一台不影響服務。應用程式直連 Kafka（用專屬帳號密碼），或經負載平衡使用兩台 REST 介面。維運人員經 VDI 進來，有兩條路：用瀏覽器直接連 Control Center（不經負載平衡：它只有一台，放在負載平衡後面並不會更可靠），或登入操作機使用 OP 選單做日常維運。OP 選單和 C3 一樣用自己的 AD 帳號登入，權限依 AD 群組決定，紀錄寫的是本人而不是共用帳號；AD 或權限服務故障時，另有緊急模式可用，使用時會特別標記並記下操作人員。操作機同時是安裝作業的起點與維運人員執行 OP 選單的主機。周邊還有兩項行內既有的服務：套件庫（Satellite、Artifactory、Nexus，沒有才用 web server）與 AD。人員的權限綁在 AD 群組上，不綁個人：人員異動只要調整 AD 群組成員，平台的權限設定不用改。使用者不會直接登入 AD：帳密是輸入在 C3 或 OP 選單，由 Kafka 叢集上的權限服務向 AD 驗證、查詢所屬群組。");
    // applications -> load balancer -> REST; applications -> Kafka directly
    await badge(s, 1.25, 2.8, 0.85, "LuBot", C.ink);
    under(s, 1.25, 3.3, 1.8, "應用程式", null, { headSize: 16 });
    panel(s, 2.6, 2.3, 1.7, 1.0, C.soft, C.line);
    txt(s, "負載平衡", { x: 2.6, y: 2.3, w: 1.7, h: 1.0, fontSize: 16, bold: true, align: "center", valign: "middle" });
    arrow(s, 1.75, 2.8, 2.6, 2.8);
    arrow(s, 4.3, 2.8, 4.9, 2.8);
    // operators (via bastion / VDI) -> Control Center (browser) and the OP menu on the bastion (AD login)
    await badge(s, 1.25, 4.85, 0.85, "LuUsers", C.ink);
    under(s, 1.25, 5.35, 1.8, "維運人員", null, { headSize: 16 });
    txt(s, "經 VDI", { x: 1.9, y: 4.6, w: 2.4, h: 0.38, fontSize: 14, color: C.body, align: "center" });
    arrow(s, 1.75, 4.65, 4.9, 4.25);
    arrow(s, 1.75, 5.05, 4.9, 5.45);
    // edge services
    panel(s, 4.9, 2.15, 2.4, 1.3, C.tealSoft);
    await badge(s, 5.4, 2.8, 0.6, "LuNetwork", C.teal);
    txt(s, "REST 介面\n×2", { x: 5.8, y: 2.15, w: 1.45, h: 1.3, fontSize: 15, bold: true, valign: "middle", color: C.teal });
    panel(s, 4.9, 3.75, 2.4, 1.0, C.tealSoft);
    await badge(s, 5.4, 4.25, 0.6, "LuMonitor", C.teal);
    txt(s, "Control\nCenter", { x: 5.8, y: 3.75, w: 1.45, h: 1.0, fontSize: 15, bold: true, valign: "middle", color: C.teal });
    panel(s, 4.9, 4.95, 2.4, 1.0, C.tealSoft);
    await badge(s, 5.4, 5.45, 0.6, "LuSquareTerminal", C.teal);
    txt(s, "操作機\nOP 選單", { x: 5.8, y: 4.95, w: 1.45, h: 1.0, fontSize: 15, bold: true, valign: "middle", color: C.teal });
    // kafka cluster
    const kx = 7.9, ky = 1.95, kw = W - M - kx, kh = 3.7;
    panel(s, kx, ky, kw, kh, C.accentSoft);
    txt(s, "Kafka 叢集", { x: kx + 0.25, y: ky + 0.15, w: 3, h: 0.45, fontSize: 18, bold: true, color: C.accent });
    for (let i = 0; i < 3; i++) await badge(s, kx + 0.65 + i * 0.78, ky + 1.15, 0.62, "LuServerCog", C.accent);
    txt(s, "Controller ×3\n管理叢集", { x: kx + 3.2, y: ky + 0.75, w: 1.6, h: 0.8, fontSize: 14, bold: true, color: C.ink, valign: "middle" });
    for (let i = 0; i < 4; i++) await badge(s, kx + 0.65 + i * 0.78, ky + 2.45, 0.62, "LuServer", C.accent);
    txt(s, "Broker ×4\n存放資料", { x: kx + 3.45, y: ky + 2.05, w: 1.3, h: 0.8, fontSize: 14, bold: true, color: C.ink, valign: "middle" });
    arrow(s, 7.3, 2.8, kx, 2.8);
    arrow(s, 7.3, 4.25, kx, 4.25);
    arrow(s, 7.3, 5.45, kx, 5.45);
    arrow(s, 1.6, 3.25, kx, 3.75, C.mute, 1.5, "dash");
    // support hosts
    // the 操作機 is already drawn above (OP menu; it also runs the installation): only the other support hosts here
    const sup = [["LuDatabase", "行內套件庫"], ["LuIdCard", "行內 AD：權限綁群組"]];
    for (let i = 0; i < sup.length; i++) {
      await badge(s, 6.0 + i * 3.6, 6.45, 0.56, sup[i][0], C.mute);
      txt(s, sup[i][1], { x: 6.4 + i * 3.6, y: 6.25, w: 3.0, h: 0.4, fontSize: 14, color: C.body, valign: "middle" });
    }
    // people log in with AD credentials through C3 / the OP menu; the cluster's permission service checks them in AD
    arrow(s, 9.6, ky + kh + 0.02, 9.6, 6.15, C.mute, 1.5, "dash");
    txt(s, "登入時向 AD 驗證帳密、查群組", { x: 9.75, y: ky + kh + 0.04, w: 3.0, h: 0.42, fontSize: 12, color: C.body, valign: "middle" });
  }

  // ================================================================ 4 prerequisites
  {
    const s = plainSlide("開始前，銀行需備妥六件事", "這六項是銀行端要先準備的。最常卡關的是第二項：主機要能從行內的 RHEL 套件來源安裝作業系統套件與 Java（RHEL 自帶的 OpenJDK 21），Satellite、內部鏡像或安裝光碟都可以。AD 只需要人員群組，加上一個沒有任何管理權限的唯讀查詢帳號；平台內部的服務一律用憑證識別，不在 AD 建帳號。Confluent 套件要放進行內的內部套件庫：優先沿用行內既有的 Red Hat Satellite、JFrog Artifactory 或 Nexus 的 yum repo；行內沒有這類平台時，才另外準備一台 web server 提供。");
    const items = [
      ["LuServer", "RHEL 9 主機", "依元件準備\n規格與數量"],
      ["LuDatabase", "OS 套件來源", "含 Java\nSatellite、鏡像\n或安裝光碟"],
      ["LuIdCard", "AD", "人員群組\n＋唯讀查詢帳號"],
      ["LuServer", "內部套件庫", "Satellite、\nArtifactory、Nexus\n無則用 web server"],
      ["LuStamp", "憑證窗口", "由銀行 CA\n簽發憑證"],
      ["LuFileText", "授權檔", "Confluent\n企業版授權"],
    ];
    const gap = 0.25, cw = (W - 2 * M - gap * 5) / 6, cy = 2.2, ch = 3.9;
    for (let i = 0; i < items.length; i++) {
      const x = M + i * (cw + gap), [ic, h, b] = items[i];
      panel(s, x, cy, cw, ch, C.soft);
      await badge(s, x + cw / 2, cy + 1.0, 1.0, ic, i === 1 ? C.accent : C.teal);
      under(s, x + cw / 2, cy + 1.9, cw - 0.1, h, b, { subH: 1.0, subSize: 14, headSize: 16 });
    }
  }

  // ================================================================ 5-13 steps 1-9 (install-steps.js)
  await require("./install-steps")({ pptx, C, W, M, badge, txt, under, arrow, panel, stepSlide, icon, VERIFY_TOTAL })();

  // ================================================================ 14 responsibilities
  {
    const s = plainSlide("分工：銀行備妥環境，我方執行安裝", "實心圓是主要負責，空心圓是協助。銀行端主要負責提供環境：檔案交換、主機、OS 套件來源、AD 帳號與憑證簽發；其餘由我方執行，最後雙方共同驗收。");
    // [我方, 銀行, 銀行說明]  2 = 主責, 1 = 協助, 0 = 無
    const R = [
      [2, 0, ""], [2, 1, "資安掃描"], [2, 2, "交換、套件庫"], [2, 2, "提供主機"], [2, 1, "OS、Java"],
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
