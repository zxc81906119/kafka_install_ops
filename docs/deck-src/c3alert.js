// Chapter 32 proposal deck, step 1 of 2: renders the diagram and icons and writes the slide list as JSON.
// Step 2 is the same guide-build.ps1 as the manual overview deck (company template, PowerPoint).
//   node c3alert.js <build directory>
// Unlike guide.js this deck does show configuration excerpts (code slides), so there is no command check.
const fs = require("fs");
const path = require("path");
const React = require("react");
const { renderToStaticMarkup } = require("react-dom/server");
const sharp = require("sharp");
const L = require("react-icons/lu");
const { Resvg } = require("../journey-src/node_modules/@resvg/resvg-js");
const D = require("../journey-src/diagrams");
const CD = require("./c3alert-diagrams");
const { COLOR, SLIDES, APPENDIX } = require("./c3alert-slides");

const buildDir = path.resolve(process.argv[2] || "c3alert-build");
fs.mkdirSync(buildDir, { recursive: true });

const REWORD = {
  c3alert: [
    ["第 17 章同一份 26 條", "同一份 26 條規則"],
    ["4 個 job，只留規則用的指標", "抓取、算規則"], ["prometheus-generated.yml（root）", ""],
    ["HTTPS，每 30 秒抓一次", ""], ["10 個欄位都是字串", ""],
    ["有設才送；預設格式", "有設才送"], ["不能自訂 JSON", ""], ["C3 自己寫設定", ""],
  ],
};

function renderDiagram(id) {
  const draw = CD[id] || D[id];
  if (!draw) {
    throw new Error("unknown diagram: " + id);
  }

  // The guide`s diagrams may name other chapters; the deck says what is meant instead
  let svg = draw();
  for (const [from, to] of REWORD[id] || []) {
    if (!svg.includes(from)) {
      throw new Error(`${id}: 找不到要改的字「${from}」`);
    }
    svg = svg.split(from).join(to);
  }
  const width = +/width="(\d+)"/.exec(svg)[1];
  const height = +/height="(\d+)"/.exec(svg)[1];
  const png = new Resvg(svg, { fitTo: { mode: "zoom", value: 2.5 }, font: { loadSystemFonts: true } }).render().asPng();
  const file = `d-${id}.png`;
  fs.writeFileSync(path.join(buildDir, file), png);
  return { file, ratio: width / height };
}

// White lucide icon in a filled circle, as in the manual overview deck
async function renderIcon(name, color) {
  if (!L[name]) {
    throw new Error("no icon " + name);
  }

  const file = `i-${name}-${color}.png`;
  const icon = renderToStaticMarkup(React.createElement(L[name], { size: 150, color: "#FFFFFF" }));
  const circle = `<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><circle cx="128" cy="128" r="128" fill="#${color}"/></svg>`;
  await sharp(Buffer.from(circle))
    .composite([{ input: Buffer.from(icon), left: 53, top: 53 }])
    .png()
    .toFile(path.join(buildDir, file));
  return file;
}

async function prepare(slide) {
  const color = slide.color || COLOR;
  // compact: guide-build.ps1 sizes pictures, card rows and small tables to the content (this deck only)
  const out = { kind: "content", compact: true, tag: slide.tag, color, title: slide.title, blocks: slide.blocks || [], notes: slide.notes || "" };

  if (slide.diagram) {
    Object.assign(out, renderDiagram(slide.diagram));
  }
  if (slide.table) {
    out.table = slide.table;
  }
  if (slide.code) {
    out.code = slide.code;
    out.codeFile = slide.file;
  }
  if (slide.tiles) {
    out.tiles = [];
    for (const [head, sub, icon] of slide.tiles) {
      out.tiles.push({ head, sub, icon: await renderIcon(icon, color) });
    }
  }
  return out;
}


// Appendix: the full rule file as deployed on c3-01 (install/templates/confluent-alerts.yml with target: omnibus added
// to every group), comments and annotations left out, long expressions broken at "and" / "/" (PromQL ignores the line breaks).
// Read at build time so the deck always shows the rules that are really delivered.
const RULES_FILE = path.join(__dirname, "../../install/templates/confluent-alerts.yml");
const PAGE_LINES = 27;

function wrapExpr(line) {
  if (line.length <= 118) {
    return [line];
  }
  const indent = " ".repeat(10);
  const NL = String.fromCharCode(10);
  return line
    .split(" and ").join(NL + indent + "and ")
    .split(" / ").join(NL + indent + "/ ")
    .split(NL);
}

// Source of each rule: the same table the metric diagrams use (c3alert-diagrams.js)
function ruleSources() {
  return CD._sources;
}

function ruleLines() {
  const out = [];
  const sources = ruleSources();
  let inAnnotations = false;
  for (const line of fs.readFileSync(RULES_FILE, "utf8").split(String.fromCharCode(10))) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) {
      continue;
    }
    const indent = line.length - line.trimStart().length;
    if (inAnnotations) {
      if (indent > 8) {
        continue;
      }
      inAnnotations = false;
    }
    if (trimmed === "annotations:") {
      inAnnotations = true;
      continue;
    }
    const alert = /^      - alert: (\S+)/.exec(line);
    if (alert) {
      if (!sources[alert[1]]) {
        throw new Error("no source in the rule tables for " + alert[1]);
      }
      out.push("      # 出處：" + sources[alert[1]]);
    }
    out.push(...wrapExpr(line));
    if (/^  - name: /.test(line)) {
      out.push("    labels:", "      target: omnibus");
    }
  }
  return out;
}

// Pages break only between rules or groups; a page that starts inside a group repeats the group name as a comment
function rulePages() {
  const lines = ruleLines();
  const units = [];
  let group = "";
  for (const line of lines) {
    const g = /^  - name: (.+)$/.exec(line);
    if (g) {
      group = g[1];
    }
    // A new unit starts at each alert, unless the previous unit is only a group header (keep the header with its first rule)
    const last = units[units.length - 1];
    const headerOnly = last && !last.lines.some((l) => /^      - alert: /.test(l));
    if (units.length === 0 || /^  - name: /.test(line) || (/^      # 出處：/.test(line) && !headerOnly)) {
      units.push({ group, lines: [] });
    }
    units[units.length - 1].lines.push(line);
  }
  const pages = [];
  let page = [];
  for (const u of units) {
    if (page.length + u.lines.length > PAGE_LINES) {
      pages.push(page);
      page = /^  - name: /.test(u.lines[0]) ? [] : ["  # （" + u.group + " 群組，接上頁）"];
    }
    page.push(...u.lines);
  }
  pages.push(page);
  return pages;
}

async function main() {
  const slides = [];

  slides.push({ kind: "cover", title: "Kafka 平台告警方案", sub: "銀行沒有 Prometheus 時" });
  for (const s of SLIDES) {
    slides.push(await prepare(s));
  }

  // Appendix A: the real settings
  for (const s of APPENDIX) {
    slides.push(await prepare(s));
  }

  const pages = rulePages();
  const count = ruleLines().filter((l) => /^      - alert: /.test(l)).length;
  pages.forEach((lines, i) => {
    slides.push(Object.assign({ kind: "content", tag: `附錄 B：規則全文 ${i + 1}／${pages.length}`, color: COLOR,
      title: `附錄 B：${count} 條規則全文（${i + 1}／${pages.length}）`, blocks: [],
      notes: "c3-01 上 custom-rules-confluent.yml 的實際內容（由交給銀行的 confluent-alerts.yml 每個群組加 target 產生）。每條另有 summary、description（送 omnibus 的 sub_origin、msg），這裡省略。" },
      { code: lines.join(String.fromCharCode(10)), codeFile: "/etc/confluent-control-center/custom-rules-confluent.yml（省略原註解與 annotations；# 出處 依規則表補上）" }));
  });
  slides.push({ kind: "end", title: "謝謝", sub: "" });

  fs.writeFileSync(path.join(buildDir, "guide.json"), JSON.stringify({ slides }, null, 1), "utf8");
  console.log(`${slides.length} 張 → ${buildDir}`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
