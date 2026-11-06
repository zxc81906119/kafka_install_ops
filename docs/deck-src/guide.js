// Manual overview deck, step 1 of 2: renders the diagrams and icons and writes the slide list as JSON.
// Step 2 (guide-build.ps1) opens the company template in PowerPoint and fills it, so the template's own layouts are used.
//   node guide.js <build directory>
const fs = require("fs");
const path = require("path");
const React = require("react");
const { renderToStaticMarkup } = require("react-dom/server");
const sharp = require("sharp");
const L = require("react-icons/lu");
const { Resvg } = require("../journey-src/node_modules/@resvg/resvg-js");
const D = require("../journey-src/diagrams");
const { PARTS, INTRO, INSTALL, OPS, MIGRATE, CLOSING, CONTENTS, REWORD } = require("./guide-slides");

const buildDir = path.resolve(process.argv[2] || "guide-build");
fs.mkdirSync(buildDir, { recursive: true });

// Anything that still reads like a command stops the build: the deck must not show commands.
const COMMAND = /\b(dnf (download|update|install|downgrade|history)|rpm (-K|--import)|systemctl \w|journalctl \S|kafka-(topics|configs|features|log-dirs|reassign-partitions|remove-brokers)\b|confluent (iam|secret)|createrepo_c|curl \d|ssh cpuser)|--[a-z]+-[a-z]+|\w+-[a-z]+\.sh\b/;

function checkNoCommand(where, text) {
  const hit = COMMAND.exec(text);
  if (hit) {
    throw new Error(`${where}: 還有指令「${hit[0]}」`);
  }
}

// One diagram to PNG, with the commands reworded. Returns its file name and width/height ratio.
function renderDiagram(id) {
  if (!D[id]) {
    throw new Error("unknown diagram: " + id);
  }

  let svg = D[id]();
  for (const [from, to] of REWORD[id] || []) {
    if (!svg.includes(from)) {
      throw new Error(`${id}: 找不到要改的字「${from}」`);
    }
    svg = svg.split(from).join(to);
  }

  const labels = [...svg.matchAll(/<text[^>]*>([\s\S]*?)<\/text>/g)].map((m) => m[1].replace(/<[^>]+>/g, "")).join("\n");
  checkNoCommand(`圖 ${id}`, labels);

  const width = +/width="(\d+)"/.exec(svg)[1];
  const height = +/height="(\d+)"/.exec(svg)[1];
  const png = new Resvg(svg, { fitTo: { mode: "zoom", value: 2.5 }, font: { loadSystemFonts: true } }).render().asPng();
  const file = `d-${id}.png`;
  fs.writeFileSync(path.join(buildDir, file), png);
  return { file, ratio: width / height };
}

// One icon: white lucide icon in a filled circle, the deck's motif.
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

async function prepare(slide, part) {
  const color = PARTS[part].color;
  const out = { kind: "content", tag: part === "close" ? slide.ch : `${slide.ch}｜${PARTS[part].name}`, color, title: slide.title, blocks: slide.blocks || [], notes: slide.notes || "" };

  checkNoCommand(slide.title, JSON.stringify(slide));

  if (slide.diagram) {
    Object.assign(out, renderDiagram(slide.diagram));
  }
  if (slide.table) {
    out.table = slide.table;
  }
  if (slide.flow) {
    out.flow = [];
    for (const [head, sub, icon] of slide.flow) {
      out.flow.push({ head, sub, icon: await renderIcon(icon, color) });
    }
  }
  if (slide.tiles) {
    out.tiles = [];
    for (const [head, sub, icon] of slide.tiles) {
      out.tiles.push({ head, sub, icon: await renderIcon(icon, color) });
    }
  }
  return out;
}

async function main() {
  const slides = [];

  slides.push({ kind: "cover", title: "Confluent Platform 手冊導覽", sub: "離線銀行環境的安裝、維運與升級遷移" });
  slides.push({ kind: "outline", title: "大綱", items: ["開場：任務、環境與版本路徑", "安裝篇：第 2–19 章", "維運篇：第 20–28 章", "升級遷移篇：第 29–32 章", "手冊的驗證狀態"] });
  slides.push({
    kind: "contents", tag: "手冊全貌", title: "手冊分成三篇，每一步都標明誰做、在哪台", color: PARTS.install.color,
    rows: CONTENTS.map((c) => ({ name: PARTS[c.part].name, color: PARTS[c.part].color, range: c.range, desc: c.desc, items: c.items })),
    foot: "第 0 章建 lab（只有練習需要）、第 1 章開場、附錄 B 是監控覆蓋率",
    notes: "手冊是手動指令優先，install/ 的腳本走同一條路。",
  });

  for (const s of INTRO) slides.push(await prepare(s, "intro"));

  slides.push({ kind: "divider", title: "安裝篇", sub: "第 2–19 章\n從下載套件到交付驗收，裝的是基底版本" });
  for (const s of INSTALL) slides.push(await prepare(s, "install"));

  slides.push({ kind: "divider", title: "維運篇", sub: "第 20–28 章\n上線後的輪替、監控、備份、節點與故障處理" });
  for (const s of OPS) slides.push(await prepare(s, "ops"));

  slides.push({ kind: "divider", title: "升級遷移篇", sub: "第 29–32 章\n從基底遷移到目標版本，每一段都再驗收" });
  for (const s of MIGRATE) slides.push(await prepare(s, "migrate"));

  slides.push(await prepare(CLOSING, "close"));
  slides.push({ kind: "end", title: "謝謝", sub: "" });

  fs.writeFileSync(path.join(buildDir, "guide.json"), JSON.stringify({ slides }, null, 1), "utf8");
  console.log(`${slides.length} 張 → ${buildDir}`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
