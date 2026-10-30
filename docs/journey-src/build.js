// Builds docs/Confluent-安裝旅程-手把手.docx from journey.md (the manual's Markdown subset, plus:
//   @role 銀行 OS 團隊 | repo01 | root        -> a role badge line (who runs the next commands, where, as whom)
//   ```bash  / ```out                            -> command block / expected-output block
//   ![diagram-id]                                -> diagram from diagrams.js rendered to PNG
const fs = require('fs');
const path = require('path');
const { Resvg } = require('@resvg/resvg-js');
// 不帶參數：手把手。其他文件：node build.js <來源.md> <輸出.docx> [diagrams.js]
const D = require(process.argv[4] ? path.resolve(process.argv[4]) : './diagrams');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, LevelFormat, TableOfContents, Footer, Header, PageNumber,
  PageBreak, TabStopType, ImageRun,
} = require('docx');

const SRC = process.argv[2] ? path.resolve(process.argv[2]) : path.join(__dirname, 'journey.md');
const OUT = process.argv[3] ? path.resolve(process.argv[3]) : path.join(__dirname, '..', 'Confluent-安裝旅程-手把手.docx');

let FONT = 'Microsoft JhengHei';
const MONO = 'Consolas';
const C = { ink: '1F2937', muted: '6B7280', accent: '0F6E56', codeBg: 'F3F4F6', codeBorder: 'D1D5DB',
  outBg: 'F8FAFC', outBorder: 'CBD5E1', noteBg: 'EFF6FF', noteBar: '3B82F6', warnBg: 'FFF7ED', warnBar: 'F59E0B', headBg: 'E5E7EB',
  usBg: 'E1F5EE', usInk: '085041', bankBg: 'FAEEDA', bankInk: '633806', headInk: '1F2937' };
const PAGE_W = 11906, MARGIN = 1134, CONTENT_W = PAGE_W - 2 * MARGIN;

function runs(text, base = {}) {
  const out = [];
  const re = /(`[^`]+`|\*\*(?:(?!\*\*).)+?\*\*)/g;
  let last = 0, m;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(new TextRun({ text: text.slice(last, m.index), ...base }));
    const t = m[0];
    if (t.startsWith('`')) out.push(new TextRun({ text: t.slice(1, -1), font: MONO, size: 18, color: '9D174D', ...base, bold: base.bold }));
    else out.push(...runs(t.slice(2, -2), { ...base, bold: true }));
    last = m.index + t.length;
  }
  if (last < text.length) out.push(new TextRun({ text: text.slice(last), ...base }));
  return out;
}

function block(lines, kind) {
  const bg = kind === 'out' ? C.outBg : C.codeBg, bc = kind === 'out' ? C.outBorder : C.codeBorder;
  const b = { style: BorderStyle.SINGLE, size: 4, color: bc, space: 4 };
  const label = new Paragraph({
    spacing: { before: 80, after: 0 },
    children: [new TextRun({ text: kind === 'out' ? '預期輸出' : '指令', size: 15, color: C.muted, bold: true })],
  });
  return [label, ...lines.map((l, i) => new Paragraph({
    style: 'Code',
    shading: { type: ShadingType.CLEAR, fill: bg, color: 'auto' },
    border: { top: b, bottom: b, left: b, right: b },
    spacing: { before: 0, after: i === lines.length - 1 ? 140 : 0 },
    children: [new TextRun({ text: l.length ? l : ' ', color: kind === 'out' ? '334155' : '111827' })],
  }))];
}

function role(text) {
  const [who, where, user, note] = text.split('|').map(s => s.trim());
  const bank = /銀行|行內|OS 團隊|AD 團隊|CA|套件庫/.test(who);
  const bg = bank ? C.bankBg : C.usBg, ink = bank ? C.bankInk : C.usInk;
  const parts = [new TextRun({ text: ` ${bank ? '銀行' : '我方'} `, bold: true, color: 'FFFFFF', size: 18, shading: { type: ShadingType.CLEAR, fill: ink, color: 'auto' } }),
    new TextRun({ text: `  ${who}`, bold: true, color: ink, size: 20 })];
  if (where) parts.push(new TextRun({ text: `　在 ${where}`, color: ink, size: 20 }));
  if (user) parts.push(new TextRun({ text: `　身分 ${user}`, color: ink, size: 20 }));
  if (note) parts.push(new TextRun({ text: `　（${note}）`, bold: true, color: C.warnBar || ink, size: 20 }));   // 第四欄：例如「只在需要時做…」
  return new Paragraph({
    shading: { type: ShadingType.CLEAR, fill: bg, color: 'auto' },
    spacing: { before: 160, after: 80 }, keepNext: true,
    border: { left: { style: BorderStyle.SINGLE, size: 24, color: ink, space: 8 } },
    indent: { left: 120 },
    children: parts,
  });
}

function callout(text, warn) {
  const bar = { style: BorderStyle.SINGLE, size: 24, color: warn ? C.warnBar : C.noteBar, space: 8 };
  return new Paragraph({
    shading: { type: ShadingType.CLEAR, fill: warn ? C.warnBg : C.noteBg, color: 'auto' },
    border: { left: bar }, spacing: { before: 80, after: 140 }, indent: { left: 120 }, children: runs(text),
  });
}

function image(id) {
  const fn = D[id];
  if (!fn) throw new Error('unknown diagram: ' + id);
  const svg = fn();
  const w = +/width="(\d+)"/.exec(svg)[1], h = +/height="(\d+)"/.exec(svg)[1];
  const png = new Resvg(svg, { fitTo: { mode: 'zoom', value: 2.5 }, font: { loadSystemFonts: true } }).render().asPng();
  const maxW = CONTENT_W / 20 * 1.333; // dxa -> px at 96 dpi
  const scale = Math.min(1, maxW / w);
  return new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 120, after: 160 }, keepNext: false,
    children: [new ImageRun({ type: 'png', data: png, transformation: { width: Math.round(w * scale), height: Math.round(h * scale) } })] });
}

function table(rows) {
  const cells = rows.map(r => r.trim().replace(/^\||\|$/g, '').split(/(?<!\\)\|/).map(s => s.trim().replace(/\\\|/g, '|')));
  const header = cells[0]; const n = header.length;
  const body = cells.slice(2).map(r => Array.from({ length: n }, (_, i) => r[i] || ''));
  const w = (s) => [...s].reduce((a, ch) => a + (ch.charCodeAt(0) > 0x2e80 ? 2 : 1), 0);
  const want = header.map((h, i) => Math.min(60, Math.max(8, w(h), ...body.map(r => w(r[i] || '')))));
  const sum = want.reduce((a, b) => a + b, 0);
  const widths = want.map(x => Math.floor(CONTENT_W * x / sum));
  widths[n - 1] += CONTENT_W - widths.reduce((a, b) => a + b, 0);
  const border = { style: BorderStyle.SINGLE, size: 4, color: 'D1D5DB' };
  const borders = { top: border, bottom: border, left: border, right: border };
  const mk = (r, head) => new TableRow({ tableHeader: head, cantSplit: true,
    children: r.map((t, i) => new TableCell({ width: { size: widths[i], type: WidthType.DXA }, borders,
      shading: head ? { type: ShadingType.CLEAR, fill: C.headBg, color: 'auto' } : undefined,
      margins: { top: 50, bottom: 50, left: 90, right: 90 },
      children: [new Paragraph({ spacing: { before: 0, after: 0 }, children: runs(t || '', head ? { size: 18, bold: true, color: C.headInk } : { size: 18 }) })] })) });
  return [new Table({ width: { size: CONTENT_W, type: WidthType.DXA }, columnWidths: widths, rows: [mk(header, true), ...body.map(r => mk(r, false))] }),
    new Paragraph({ spacing: { before: 0, after: 120 }, children: [] })];
}

// 每個 ```bash 指令塊上方的「在哪執行」：取自最近的 @role；換了主機（或每章第一塊）再附上 lab 裡切過去的指令
const ENTER = {
  'ops02|root': 'docker exec -it -w /root lab-ops02-1 bash',
  'dl01|root': 'docker exec -it dl01 bash',
  'repo01|root': 'docker exec -it lab-repo01-1 bash',
  'lb01|root': 'docker exec -it lab-lb01-1 bash',
  'ad01|root': 'docker exec -it lab-ad01-1 bash',
};
function placeLine(roleText, changed, fromContainer) {
  const [who, where = '', user = ''] = roleText.split('|').map(s => s.trim());
  const bank = /銀行|行內|OS 團隊|AD 團隊|CA|套件庫/.test(who);
  const ink = bank ? C.bankInk : C.usInk;
  const windows = /^Windows/.test(where);
  const children = [new TextRun({ text: windows ? '▶ 在 Windows 的 Git Bash 執行' : `▶ 在 ${where}（${user}）執行`, bold: true, color: ink, size: 18 })];
  if (changed) {
    const enter = ENTER[`${where}|${user}`];
    if (windows) children.push(new TextRun({ text: '　換機器：還在容器裡的話先 exit，回到 Git Bash', color: ink, size: 18 }));
    else if (enter) children.push(new TextRun({ text: fromContainer ? '　換機器：先 exit 回到 Git Bash，再執行 ' : '　換機器：在 Git Bash 執行 ', color: ink, size: 18 }),
      new TextRun({ text: enter, font: 'Consolas', color: ink, size: 18 }));
  }
  return new Paragraph({ spacing: { before: 100, after: 40 }, keepNext: true, children });
}

function parse(md) {
  const lines = md.replace(/\r/g, '').split('\n');
  const out = []; let i = 0, numbered = 0;
  let currentRole = '', lastPlace = '';
  while (i < lines.length) {
    const l = lines[i]; let m;
    if ((m = /^\s*```(\w*)/.exec(l))) {
      const kind = m[1] === 'out' ? 'out' : 'cmd';
      if (m[1] === 'bash' && currentRole) {
        const [, where = '', user = ''] = currentRole.split('|').map(s => s.trim());
        const place = `${where}|${user}`;
        out.push(placeLine(currentRole, place !== lastPlace, lastPlace !== '' && !/^Windows/.test(lastPlace)));
        lastPlace = place;
      }
      const ind = l.length - l.trimStart().length; const buf = []; i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) { const x = lines[i++]; buf.push(x.slice(Math.min(ind, x.length - x.trimStart().length))); }
      i++; out.push(...block(buf, kind)); continue;
    }
    if (/^@role /.test(l)) currentRole = l.slice(6);
    if (/^# /.test(l)) lastPlace = '';   // 每章第一塊都附上切換指令（讀者可能從這一章開始讀）
    if (l.startsWith('|')) { const buf = []; while (i < lines.length && lines[i].startsWith('|')) buf.push(lines[i++]); out.push(...table(buf)); continue; }
    if (l.trim() === '[[toc]]') { out.push(new TableOfContents('目錄', { hyperlink: true, headingStyleRange: '1-2' })); i++; continue; }
    if (l.trim() === '[[pagebreak]]') { out.push(new Paragraph({ children: [new PageBreak()] })); i++; continue; }
    if ((m = /^@role (.*)$/.exec(l))) { out.push(role(m[1])); i++; continue; }
    if ((m = /^!\[([\w-]+)\]\s*$/.exec(l))) { out.push(image(m[1])); i++; continue; }
    if ((m = /^(#{1,3}) (.*)$/.exec(l))) {
      const lvl = m[1].length;
      out.push(new Paragraph({ heading: [HeadingLevel.HEADING_1, HeadingLevel.HEADING_2, HeadingLevel.HEADING_3][lvl - 1],
        pageBreakBefore: lvl === 1 && out.length > 0, children: [new TextRun(m[2].replace(/`/g, ''))] }));
      numbered = 0; i++; continue;
    }
    if ((m = /^\s*>(!?) ?(.*)$/.exec(l))) {
      const warn = m[1] === '!' || /^(\*\*)?(注意|警告|陷阱)/.test(m[2]); const buf = [m[2]]; i++;
      while (i < lines.length && /^\s*>!? ?/.test(lines[i])) buf.push(lines[i++].replace(/^\s*>!? ?/, ''));
      out.push(callout(buf.join(' '), warn)); continue;
    }
    if ((m = /^(\s*)- (.*)$/.exec(l))) { out.push(new Paragraph({ numbering: { reference: 'bullets', level: m[1].length >= 2 ? 1 : 0 }, children: runs(m[2]) })); i++; continue; }
    if ((m = /^\d+\. (.*)$/.exec(l))) { numbered++; out.push(new Paragraph({ numbering: { reference: 'steps', level: 0, instance: out.length - numbered }, children: runs(m[1]) })); i++; continue; }
    if (l.trim() === '') { i++; continue; }
    const buf = [l]; i++;
    while (i < lines.length && lines[i].trim() !== '' && !/^(\s*```|\||#|\s*>|\s*- |\d+\. |\[\[|@role|!\[)/.test(lines[i])) buf.push(lines[i++]);
    const text = buf.map(x => x.trim()).reduce((a, b) => a + (/[\x21-\x7e]$/.test(a) && /^[\x21-\x7e]/.test(b) ? ' ' : '') + b);
    out.push(new Paragraph({ children: runs(text) }));
  }
  return out;
}

function cover(meta) {
  const p = (text, opts) => new Paragraph({ alignment: AlignmentType.LEFT, ...opts, children: [new TextRun({ text, ...opts.run })] });
  return [
    ...(meta.logo ? [new Paragraph({ spacing: { after: 120 }, children: [new ImageRun({ type: 'png', data: fs.readFileSync(path.resolve(path.dirname(SRC), meta.logo)), transformation: { width: 82, height: 74 } })] })] : []),
    ...(meta.company ? [p(meta.company, { spacing: { before: 0, after: 0 }, run: { color: C.accent, size: 30, bold: true } }),
      new Paragraph({ border: { bottom: { style: BorderStyle.SINGLE, size: 24, color: C.brand || C.accent, space: 1 } }, spacing: { after: 0 }, children: [] })] : []),
    new Paragraph({ spacing: { before: meta.company ? 2000 : 2600 }, children: [] }),
    p(meta.kicker, { spacing: { after: 200 }, run: { color: C.accent, size: 24, bold: true } }),
    p(meta.title, { spacing: { after: 240 }, run: { size: 52, bold: true, color: C.ink } }),
    p(meta.subtitle, { spacing: { after: 600 }, run: { size: 26, color: C.muted } }),
    new Paragraph({ border: { bottom: { style: BorderStyle.SINGLE, size: 8, color: C.accent, space: 1 } }, spacing: { after: 300 }, children: [] }),
    ...meta.facts.map(f => new Paragraph({ spacing: { after: 80 }, indent: { left: 1800, hanging: 1800 }, tabStops: [{ type: TabStopType.LEFT, position: 1800 }],
      children: [new TextRun({ text: f[0], color: C.muted, size: 20 }), new TextRun({ text: '\t' + f[1], size: 20 })] })),
    new Paragraph({ children: [new PageBreak()] }),
  ];
}

const md = fs.readFileSync(SRC, 'utf8');
// XML 1.0 不允許 tab／換行以外的控制字元（例如貼進指令裡的 ESC）：Word 遇到會說「記憶體不足」而打不開，所以這裡就擋下並指出行號
{
  const bad = md.split('\n').map((line, i) => [i + 1, line]).filter(([, line]) => /[\x00-\x08\x0B\x0C\x0E-\x1F]/.test(line));
  if (bad.length) {
    for (const [n, line] of bad) console.error(`journey.md:${n} 有控制字元 ${[...line].filter((c) => c.charCodeAt(0) < 32 && !'\t\r'.includes(c)).map((c) => '\\x' + c.charCodeAt(0).toString(16).padStart(2, '0')).join(' ')}（改寫成可見的寫法，例如 \\x1b）`);
    process.exit(1);
  }
}
// 程式碼區塊（```）要成對；多一個會把後面整段當成指令，run-chapter.js 就找不到之後的章（2026-10-29 踩過）
{
  let open = 0; const ids = [];
  md.split('\n').forEach((line, i) => {
    if (/^```/.test(line)) open = open ? 0 : i + 1;
    const m = !open && /^# ([0-9]{1,2}|[A-Z])\. /.exec(line); if (m) ids.push(m[1]);
  });
  const want = [...Array(32).keys()].map(String).concat('B');
  const missing = want.filter((id) => !ids.includes(id));
  if (open || missing.length) {
    if (open) console.error(`journey.md:${open} 開了 \`\`\` 沒有關`);
    if (missing.length) console.error(`找不到這些章（多半是前面的 \`\`\` 沒成對）：${missing.join(' ')}`);
    process.exit(1);
  }
}
const metaMatch = /^<!--meta\n([\s\S]*?)\n-->\n/.exec(md);
const meta = JSON.parse(metaMatch[1]);
if (meta.theme) { Object.assign(C, meta.theme.colors || {}); if (meta.theme.font) FONT = meta.theme.font; }
const body = parse(md.slice(metaMatch[0].length));

const doc = new Document({
  features: { updateFields: true }, creator: meta.author, title: meta.title, description: meta.subtitle,
  styles: {
    default: { document: { run: { font: { ascii: FONT, eastAsia: FONT, hAnsi: FONT }, size: 21, color: C.ink }, paragraph: { spacing: { after: 120, line: 276 } } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { size: 34, bold: true, color: C.accent }, paragraph: { spacing: { before: 240, after: 240 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { size: 27, bold: true, color: C.ink },
        paragraph: { spacing: { before: 360, after: 140 }, keepNext: true, outlineLevel: 1, border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: 'D1D5DB', space: 2 } } } },
      { id: 'Heading3', name: 'Heading 3', basedOn: 'Normal', next: 'Normal', quickFormat: true, run: { size: 22, bold: true, color: C.accent }, paragraph: { spacing: { before: 220, after: 80 }, keepNext: true, outlineLevel: 2 } },
      { id: 'Code', name: 'Code', basedOn: 'Normal', run: { font: { ascii: MONO, eastAsia: FONT, hAnsi: MONO }, size: 16, color: '111827' }, paragraph: { spacing: { before: 0, after: 0, line: 240 }, indent: { left: 80, right: 80 } } },
    ],
  },
  numbering: { config: [
    { reference: 'bullets', levels: [
      { level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 400, hanging: 260 } } } },
      { level: 1, format: LevelFormat.BULLET, text: '◦', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 800, hanging: 260 } } } } ] },
    { reference: 'steps', levels: [ { level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 400, hanging: 300 } } } } ] },
  ] },
  sections: [{
    properties: { titlePage: true, page: { size: { width: PAGE_W, height: 16838 }, margin: { top: 1134, bottom: 1134, left: MARGIN, right: MARGIN } } },
    headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [new TextRun({ text: meta.header, size: 16, color: C.muted })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: meta.company ? AlignmentType.LEFT : AlignmentType.CENTER, tabStops: [{ type: TabStopType.RIGHT, position: CONTENT_W }], children: [...(meta.company ? [new TextRun({ text: meta.company, size: 16, color: C.muted }), new TextRun({ text: '\t', size: 16 })] : []), new TextRun({ children: [PageNumber.CURRENT, ' / ', PageNumber.TOTAL_PAGES], size: 16, color: C.muted })] })] }) },
    children: [...cover(meta), ...body],
  }],
});

Packer.toBuffer(doc).then(buf => { fs.writeFileSync(OUT, buf); console.log('wrote', OUT, buf.length, 'bytes'); });
