// Builds docs/Confluent-手動安裝手冊.docx from guide.md (a small Markdown subset).
// Supported: # / ## / ### headings, paragraphs, "- " bullets, "1. " numbered items,
// ```fenced code```, | pipe | tables |, "> " callouts (">!" = warning), `code`, **bold**,
// a line "[[toc]]" for the table of contents and "[[pagebreak]]".
const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, LevelFormat, TableOfContents, Footer, Header, PageNumber,
  PageBreak, TabStopType,
} = require('docx');

// 不帶參數：手動安裝手冊。其他文件共用同一套樣式：node build.js <來源.md> <輸出.docx>
const SRC = process.argv[2] ? path.resolve(process.argv[2]) : path.join(__dirname, 'guide.md');
const OUT = process.argv[3] ? path.resolve(process.argv[3]) : path.join(__dirname, '..', 'Confluent-手動安裝手冊.docx');

const FONT = 'Microsoft JhengHei';
const MONO = 'Consolas';
const C = { ink: '1F2937', muted: '6B7280', accent: '1D4ED8', codeBg: 'F3F4F6', codeBorder: 'D1D5DB',
  noteBg: 'EFF6FF', noteBar: '3B82F6', warnBg: 'FFF7ED', warnBar: 'F59E0B', headBg: 'E5E7EB' };
const PAGE_W = 11906, MARGIN = 1134, CONTENT_W = PAGE_W - 2 * MARGIN; // A4, 2 cm margins

// ---- inline: `code` and **bold**
function runs(text, base = {}) {
  const out = [];
  // bold may contain `code` and lone "*" (e.g. **... `confluent-*` ...**): match up to the next "**"
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

const codeBorder = { style: BorderStyle.SINGLE, size: 4, color: C.codeBorder, space: 4 };
function codeBlock(lines) {
  return lines.map((l, i) => new Paragraph({
    style: 'Code',
    shading: { type: ShadingType.CLEAR, fill: C.codeBg, color: 'auto' },
    border: { top: codeBorder, bottom: codeBorder, left: codeBorder, right: codeBorder },
    spacing: { before: i === 0 ? 60 : 0, after: i === lines.length - 1 ? 140 : 0 },
    children: [new TextRun({ text: l.length ? l : ' ' })],
  }));
}

function callout(text, warn) {
  const bar = { style: BorderStyle.SINGLE, size: 24, color: warn ? C.warnBar : C.noteBar, space: 8 };
  return new Paragraph({
    shading: { type: ShadingType.CLEAR, fill: warn ? C.warnBg : C.noteBg, color: 'auto' },
    border: { left: bar },
    spacing: { before: 80, after: 140 },
    indent: { left: 120 },
    children: runs(text),
  });
}

function table(rows) {
  // split on unescaped "|"; "\|" is a literal pipe inside a cell
  const cells = rows.map(r => r.trim().replace(/^\||\|$/g, '').split(/(?<!\\)\|/).map(s => s.trim().replace(/\\\|/g, '|')));
  const header = cells[0];
  const n = header.length;
  const body = cells.slice(2).map(r => Array.from({ length: n }, (_, i) => r[i] || '')); // skip |---| line
  // column widths ~ proportional to the longest cell (CJK counts double), clamped
  const w = (s) => [...s].reduce((a, ch) => a + (ch.charCodeAt(0) > 0x2e80 ? 2 : 1), 0);
  const want = header.map((h, i) => Math.min(60, Math.max(8, w(h), ...body.map(r => w(r[i] || '')))));
  const sum = want.reduce((a, b) => a + b, 0);
  const widths = want.map(x => Math.floor(CONTENT_W * x / sum));
  widths[n - 1] += CONTENT_W - widths.reduce((a, b) => a + b, 0);
  const border = { style: BorderStyle.SINGLE, size: 4, color: 'D1D5DB' };
  const borders = { top: border, bottom: border, left: border, right: border };
  const mk = (r, head) => new TableRow({
    tableHeader: head,
    cantSplit: true,
    children: r.map((t, i) => new TableCell({
      width: { size: widths[i], type: WidthType.DXA },
      borders,
      shading: head ? { type: ShadingType.CLEAR, fill: C.headBg, color: 'auto' } : undefined,
      margins: { top: 50, bottom: 50, left: 90, right: 90 },
      children: [new Paragraph({ spacing: { before: 0, after: 0 }, children: runs(t || '', { size: 18, bold: head }) })],
    })),
  });
  return [
    new Table({ width: { size: CONTENT_W, type: WidthType.DXA }, columnWidths: widths,
      rows: [mk(header, true), ...body.map(r => mk(r, false))] }),
    new Paragraph({ spacing: { before: 0, after: 120 }, children: [] }),
  ];
}

function parse(md) {
  const lines = md.replace(/\r/g, '').split('\n');
  const out = [];
  let i = 0, numbered = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (/^\s*```/.test(l)) {
      const ind = l.length - l.trimStart().length; // fences may be indented inside list items
      const buf = [];
      i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) {
        const x = lines[i++];
        buf.push(x.slice(Math.min(ind, x.length - x.trimStart().length)));
      }
      i++;
      out.push(...codeBlock(buf));
      continue;
    }
    if (l.startsWith('|')) {
      const buf = [];
      while (i < lines.length && lines[i].startsWith('|')) buf.push(lines[i++]);
      out.push(...table(buf));
      continue;
    }
    if (l.trim() === '[[toc]]') {
      out.push(new TableOfContents('目錄', { hyperlink: true, headingStyleRange: '1-2' }));
      i++; continue;
    }
    if (l.trim() === '[[pagebreak]]') { out.push(new Paragraph({ children: [new PageBreak()] })); i++; continue; }
    let m;
    if ((m = /^(#{1,3}) (.*)$/.exec(l))) {
      const lvl = m[1].length;
      out.push(new Paragraph({
        heading: [HeadingLevel.HEADING_1, HeadingLevel.HEADING_2, HeadingLevel.HEADING_3][lvl - 1],
        pageBreakBefore: lvl === 1 && out.length > 0,
        children: [new TextRun(m[2].replace(/`/g, ''))],   // headings keep the heading style: drop code backticks
      }));
      numbered = 0; i++; continue;
    }
    if ((m = /^\s*>(!?) ?(.*)$/.exec(l))) {
      const warn = m[1] === '!' || /^(\*\*)?(注意|警告)/.test(m[2]);
      const buf = [m[2]];
      i++;
      while (i < lines.length && /^\s*>!? ?/.test(lines[i])) buf.push(lines[i++].replace(/^\s*>!? ?/, ''));
      out.push(callout(buf.join(' '), warn));
      continue;
    }
    if ((m = /^(\s*)- (.*)$/.exec(l))) {
      out.push(new Paragraph({ numbering: { reference: 'bullets', level: m[1].length >= 2 ? 1 : 0 }, children: runs(m[2]) }));
      i++; continue;
    }
    if ((m = /^\d+\. (.*)$/.exec(l))) {
      numbered++;
      out.push(new Paragraph({ numbering: { reference: 'steps', level: 0, instance: out.length - numbered }, children: runs(m[1]) }));
      i++; continue;
    }
    if (l.trim() === '') { numbered = numbered ? numbered : 0; i++; continue; }
    // paragraph: join following plain lines
    const buf = [l];
    i++;
    while (i < lines.length && lines[i].trim() !== '' && !/^(\s*```|\||#|\s*>|\s*- |\d+\. |\[\[)/.test(lines[i])) buf.push(lines[i++]);
    // join wrapped lines: a space only between two ASCII words
    const text = buf.map(x => x.trim()).reduce((a, b) => a + (/[\x21-\x7e]$/.test(a) && /^[\x21-\x7e]/.test(b) ? ' ' : '') + b);
    out.push(new Paragraph({ children: runs(text) }));
  }
  return out;
}

function cover(meta) {
  const p = (text, opts) => new Paragraph({ alignment: AlignmentType.LEFT, ...opts, children: [new TextRun({ text, ...opts.run })] });
  return [
    new Paragraph({ spacing: { before: 2600 }, children: [] }),
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
const metaMatch = /^<!--meta\n([\s\S]*?)\n-->\n/.exec(md);
const meta = JSON.parse(metaMatch[1]);
const body = parse(md.slice(metaMatch[0].length));

const doc = new Document({
  features: { updateFields: true }, // Word fills the table of contents on open
  creator: meta.author, title: meta.title, description: meta.subtitle,
  styles: {
    default: { document: { run: { font: { ascii: FONT, eastAsia: FONT, hAnsi: FONT }, size: 21, color: C.ink },
      paragraph: { spacing: { after: 120, line: 276 } } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 34, bold: true, color: C.accent }, paragraph: { spacing: { before: 240, after: 240 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 27, bold: true, color: C.ink },
        paragraph: { spacing: { before: 360, after: 140 }, keepNext: true, outlineLevel: 1,
          border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: 'D1D5DB', space: 2 } } } },
      { id: 'Heading3', name: 'Heading 3', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 22, bold: true, color: C.accent }, paragraph: { spacing: { before: 220, after: 80 }, keepNext: true, outlineLevel: 2 } },
      { id: 'Code', name: 'Code', basedOn: 'Normal',
        run: { font: { ascii: MONO, eastAsia: FONT, hAnsi: MONO }, size: 16, color: '111827' },
        paragraph: { spacing: { before: 0, after: 0, line: 240 }, indent: { left: 80, right: 80 } } },
    ],
  },
  numbering: { config: [
    { reference: 'bullets', levels: [
      { level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 400, hanging: 260 } } } },
      { level: 1, format: LevelFormat.BULLET, text: '◦', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 800, hanging: 260 } } } } ] },
    { reference: 'steps', levels: [
      { level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT, style: { paragraph: { indent: { left: 400, hanging: 300 } } } } ] },
  ] },
  sections: [{
    properties: { titlePage: true, page: { size: { width: PAGE_W, height: 16838 }, margin: { top: 1134, bottom: 1134, left: MARGIN, right: MARGIN } } },
    headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
      children: [new TextRun({ text: meta.header, size: 16, color: C.muted })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
      children: [new TextRun({ children: [PageNumber.CURRENT, ' / ', PageNumber.TOTAL_PAGES], size: 16, color: C.muted })] })] }) },
    children: [...cover(meta), ...body],
  }],
});

Packer.toBuffer(doc).then(buf => { fs.writeFileSync(OUT, buf); console.log('wrote', OUT, buf.length, 'bytes'); });
