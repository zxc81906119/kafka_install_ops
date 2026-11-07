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
const { COLOR, SLIDES } = require("./c3alert-slides");

const buildDir = path.resolve(process.argv[2] || "c3alert-build");
fs.mkdirSync(buildDir, { recursive: true });

function renderDiagram(id) {
  if (!D[id]) {
    throw new Error("unknown diagram: " + id);
  }

  const svg = D[id]();
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
  const out = { kind: "content", tag: `第 32 章｜${slide.tag}`, color, title: slide.title, blocks: slide.blocks || [], notes: slide.notes || "" };

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

async function main() {
  const slides = [];

  slides.push({ kind: "cover", title: "Kafka 平台告警方案", sub: "銀行沒有 Prometheus 時（手冊第 32 章）" });
  for (const s of SLIDES) {
    slides.push(await prepare(s));
  }
  slides.push({ kind: "end", title: "謝謝", sub: "" });

  fs.writeFileSync(path.join(buildDir, "guide.json"), JSON.stringify({ slides }, null, 1), "utf8");
  console.log(`${slides.length} 張 → ${buildDir}`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
