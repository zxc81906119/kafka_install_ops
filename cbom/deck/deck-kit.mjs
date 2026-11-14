// ============================================================================
// 兩份簡報產生器共用的版面元件（build-deck.mjs、build-cbom-talk.mjs）
//
// 用法：
//   const kit = await createDeck({ title: '簡報標題', author: '作者', templateFile: '<公司模板.pptx>' });
//   const { pres, text, contentSlide, card, node, arrow, chip, table, COLOR, W, H, M, CONTENT_TOP } = kit;
//
// 提供：
//   版面    公司模板的 5 種版面配置（COVER 封面、AGENDA 大綱、DIVIDER 扉頁、CONTENT 標題及內容、CLOSING 封底）
//   配色    COLOR（取自模板右側色條：紅 BD1A21、橘 E58813、綠 309B39、藍 145D92）、BRAND、SEVERITY（嚴重度 → 顏色，和報表一致）
//   元件    text、contentSlide、sectionDivider、card、badge、table、node、arrow、chip、code、stat、icon、diagram
// 簡報專用的圖用 node()、arrow()、chip() 畫（PowerPoint 原生圖形，可以直接在 PowerPoint 裡改）；
// 手冊與簡報共用的大圖放 docs/images/*.svg，用 diagram() 放進來。
// 改這裡會同時影響兩份簡報：改完兩份都要重建並打開檢查。
// ============================================================================
import pptxgen from 'pptxgenjs';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { svgTextToPng, svgToPng } from './svg-to-png.mjs';
import { loadTemplate } from './iisi-template.mjs';

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
const IMAGES_DIR = resolve(TOOLS_DIR, 'images');
const ICON_DIR = resolve(TOOLS_DIR, 'node_modules', 'lucide-static', 'icons');

// navy 這個名稱沿用（深色的標題列、節點），值是品牌藍；標題文字照模板用黑色（ink）
export const COLOR = {
  navy: '145D92', navy2: '0F4A75', ink: '1A1A1A', body: '404040', muted: '6B6B6B', code: '1F2933',
  white: 'FFFFFF', tint: 'F1F4F8', line: 'D9D9D9',
  amber: 'E58813', amberText: '9C5A0A', amberTint: 'FDF1E2',
  blue: '145D92', blueTint: 'E6EFF7',
  red: 'BD1A21', redTint: 'FBE8E9', gold: 'C9A227', goldTint: 'FBF6DF', green: '309B39', greenTint: 'E7F4E8',
};
export const BRAND = [COLOR.red, COLOR.amber, COLOR.green, COLOR.blue];   // 模板色條的順序
export const FONT = 'Microsoft JhengHei';   // Windows / Office 內建的繁中字型
export const MONO = 'Courier New';
export const W = 13.333, H = 7.5, M = 0.6;  // 版面寬、高、左右邊界（LAYOUT_WIDE）
export const CONTENT_TOP = 1.65;            // 內容頁標題下方，內容區的起點

/** 嚴重度 → 顏色（和報表一致） */
export const SEVERITY = {
  critical: { fill: COLOR.redTint, color: COLOR.red, label: 'critical' },
  high: { fill: COLOR.amberTint, color: COLOR.amberText, label: 'high' },
  medium: { fill: COLOR.goldTint, color: '6B5A10', label: 'medium' },
  info: { fill: COLOR.greenTint, color: COLOR.green, label: 'info' },
};

// 頁尾文字、標題位置照模板的版面配置
export const TEMPLATE_TEXT = {
  footer: '智慧財產權屬資拓宏宇國際(股)公司，複製或轉載必究',
  footerBox: { x: 8.3, y: 7.09, w: 4.2, h: 0.3 },
  slideNumberBox: { x: 12.58, y: 7.09, w: 0.46, h: 0.3 },
  title: { x: 0.54, y: 0.34, w: 11.11, h: 0.67 },         // 「標題及內容」的標題
  subtitle: { x: 0.54, y: 1.02, w: 11.11, h: 0.45 },      // 「標題及內容」的副標題
};

/**
 * 一行字放得進寬 width 吋的框時，最大可以用幾 pt（不超過 maxSize）
 * 估算：中文字（全形）寬 1 em、英數半形約 0.55 em，粗體再多留 5%
 */
export function fitFontSize(value, width, maxSize) {
  const ems = [...value].reduce((sum, ch) => sum + (ch.charCodeAt(0) > 0x2E7F ? 1 : 0.55), 0) * 1.05;
  return Math.min(maxSize, Math.floor(width * 72 / ems));
}

export async function createDeck({ title, author, templateFile }) {
  const pres = new pptxgen();
  pres.layout = 'LAYOUT_WIDE';
  pres.title = title;
  pres.author = author;
  pres.theme = { headFontFace: FONT, bodyFontFace: FONT };

  // 公司模板的版面配置（名稱同模板）：背景與 logo 從模板讀出
  const template = await loadTemplate(templateFile);
  function templateLayout(name, layoutName, { footer = true } = {}) {
    const t = template[layoutName];
    if (!t) throw new Error(`模板裡找不到版面配置「${layoutName}」：${templateFile}`);
    const objects = t.images.map(img => ({ image: { ...img } }));
    if (t.logo) objects.push({ image: { data: t.logo.data, x: t.logo.x, y: t.logo.y, w: t.logo.w, h: t.logo.h, altText: '資拓宏宇 logo' } });
    if (footer) objects.push({ text: { text: TEMPLATE_TEXT.footer, options: { ...TEMPLATE_TEXT.footerBox, fontFace: FONT, fontSize: 8, color: '8C8C8C', align: 'right', valign: 'middle', margin: 0 } } });
    pres.defineSlideMaster({
      title: name,
      background: t.background ? { data: t.background } : { color: COLOR.white },
      objects,
      ...(footer ? { slideNumber: { ...TEMPLATE_TEXT.slideNumberBox, fontFace: FONT, fontSize: 9, color: '8C8C8C', align: 'right' } } : {}),
    });
  }
  templateLayout('COVER', '封面', { footer: false });
  templateLayout('AGENDA', '大綱');
  templateLayout('DIVIDER', '扉頁');
  templateLayout('CONTENT', '標題及內容');
  templateLayout('CLOSING', '封底', { footer: false });

  const text = (slide, value, opts) => slide.addText(value, { fontFace: FONT, isTextBox: true, margin: 0, valign: 'top', ...opts });

  /** 內容頁：標題＋眉標（標題下方的小字） */
  function contentSlide(section, eyebrow, slideTitle) {
    const slide = pres.addSlide({ masterName: 'CONTENT', sectionTitle: section });
    text(slide, slideTitle, { ...TEMPLATE_TEXT.title, fontSize: 30, bold: true, color: COLOR.ink, valign: 'middle', fit: 'shrink' });
    text(slide, eyebrow, { ...TEMPLATE_TEXT.subtitle, fontSize: 16, bold: true, color: COLOR.navy, valign: 'middle' });
    return slide;
  }

  /**
   * 模板「扉頁」：PART 編號、標題在灰線上方，說明在灰線下方（灰線位置同模板）
   * 標題固定一行：太長時縮小字級（最大 40pt）。不用 fit: 'shrink'，它要在 PowerPoint 裡編輯文字才會生效。
   */
  function sectionDivider(section, n, dividerTitle, sub) {
    pres.addSection({ title: section });
    const s = pres.addSlide({ masterName: 'DIVIDER', sectionTitle: section });
    const boxW = 5.86;
    text(s, `PART ${String(n).padStart(2, '0')}`, { x: 1.17, y: 1.2, w: boxW, h: 0.45, fontSize: 18, bold: true, color: BRAND[(n - 1) % BRAND.length] });
    text(s, dividerTitle, { x: 1.17, y: 1.7, w: boxW, h: 0.95, fontSize: fitFontSize(dividerTitle, boxW, 40), bold: true, color: COLOR.ink, valign: 'bottom' });
    s.addShape(pres.shapes.LINE, { x: 1.166, y: 2.704, w: 5.862, h: 0, line: { color: 'D1D1D1', width: 2.25 } });
    text(s, sub, { x: 1.17, y: 2.9, w: boxW, h: 1.2, fontSize: 18, color: COLOR.body });
    return s;
  }

  function card(slide, { x, y, w, h, fill = COLOR.tint, line = null }) {
    slide.addShape(pres.shapes.ROUNDED_RECTANGLE, {
      x, y, w, h, rectRadius: 0.12, fill: { color: fill }, line: line ? { color: line, width: 1.25 } : { type: 'none' },
    });
  }

  /** 編號圓圈 */
  function badge(slide, n, x, y, d = 0.5, fill = COLOR.amber, fontSize = d * 32) {
    slide.addShape(pres.shapes.OVAL, { x, y, w: d, h: d, fill: { color: fill }, line: { type: 'none' } });
    text(slide, String(n), { x, y, w: d, h: d, fontSize, bold: true, color: COLOR.white, align: 'center', valign: 'middle' });
  }

  // 圖示：lucide 的 SVG 換成指定顏色後轉 PNG（同一個圖示 + 顏色只轉一次）
  const iconCache = new Map();
  function iconPng(name, color) {
    const key = `${name}:${color}`;
    if (!iconCache.has(key)) {
      const svg = readFileSync(resolve(ICON_DIR, `${name}.svg`), 'utf8').replace(/currentColor/g, `#${color}`);
      iconCache.set(key, `image/png;base64,${svgTextToPng(svg, 256).png.toString('base64')}`);
    }
    return iconCache.get(key);
  }
  /** 圓形底色＋圖示 */
  function icon(slide, name, x, y, d = 0.6, fill = COLOR.navy, color = COLOR.white, alt = '') {
    slide.addShape(pres.shapes.OVAL, { x, y, w: d, h: d, fill: { color: fill }, line: { type: 'none' } });
    const p = d * 0.24;
    slide.addImage({ data: iconPng(name, color), x: x + p, y: y + p, w: d - 2 * p, h: d - 2 * p, altText: alt || name });
  }

  /** 把 docs/images 裡的 SVG 放進內容區，維持比例、水平置中 */
  function diagram(slide, name, alt, { top = CONTENT_TOP, maxH = H - CONTENT_TOP - 0.65 } = {}) {
    const { png, width, height } = svgToPng(resolve(IMAGES_DIR, `${name}.svg`), 2400);
    let w = W - 2 * M, h = w * height / width;
    if (h > maxH) { h = maxH; w = h * width / height; }
    slide.addImage({ data: `image/png;base64,${png.toString('base64')}`, x: (W - w) / 2, y: top, w, h, altText: alt });
  }

  function table(slide, header, rows, { x = M, y = CONTENT_TOP, w = W - 2 * M, colW, fontSize = 14, rowH = 0.42, firstColBold = false }) {
    const head = header.map(t => ({ text: t, options: { bold: true, color: COLOR.white, fill: { color: COLOR.navy } } }));
    const body = rows.map((r, i) => r.map((t, j) => ({ text: t, options: { fill: { color: i % 2 ? COLOR.tint : COLOR.white }, bold: firstColBold && j === 0 } })));
    slide.addTable([head, ...body], {
      x, y, w, colW, fontFace: FONT, fontSize, color: COLOR.ink, valign: 'middle',
      border: { type: 'solid', pt: 0.75, color: COLOR.line }, margin: [0.05, 0.1, 0.05, 0.1], rowH,
    });
  }

  /** 圖的節點：圓角方框，上面一行粗體標題、下面一行說明 */
  function node(slide, { x, y, w, h, title: t, sub = '', fill = COLOR.tint, line = COLOR.line, titleColor = COLOR.navy, subColor = COLOR.body, fontSize = 15, subSize = 12, align = 'center' }) {
    card(slide, { x, y, w, h, fill, line });
    text(slide, t, { x: x + 0.12, y: y + 0.08, w: w - 0.24, h: sub ? h * 0.42 : h - 0.16, fontSize, bold: true, color: titleColor, align, valign: sub ? 'bottom' : 'middle' });
    if (sub) text(slide, sub, { x: x + 0.12, y: y + h * 0.5, w: w - 0.24, h: h * 0.46, fontSize: subSize, color: subColor, align });
  }

  /** 箭頭：從 (x1, y1) 指到 (x2, y2)；label 寫在線的上方（水平線）或右邊（垂直線） */
  function arrow(slide, x1, y1, x2, y2, label = '', color = '3A4A5C') {
    slide.addShape(pres.shapes.LINE, {
      x: Math.min(x1, x2), y: Math.min(y1, y2), w: Math.abs(x2 - x1), h: Math.abs(y2 - y1),
      flipH: x2 < x1, flipV: y2 < y1, line: { color, width: 1.75, endArrowType: 'triangle' },
    });
    if (!label) return;
    const horizontal = Math.abs(x2 - x1) >= Math.abs(y2 - y1);
    text(slide, label, horizontal
      ? { x: Math.min(x1, x2) - 0.3, y: Math.min(y1, y2) - 0.34, w: Math.abs(x2 - x1) + 0.6, h: 0.3, fontSize: 11, color: COLOR.muted, align: 'center', valign: 'bottom' }
      : { x: x1 + 0.1, y: Math.min(y1, y2), w: 2.6, h: Math.abs(y2 - y1), fontSize: 11, color: COLOR.muted, valign: 'middle' });
  }

  /** 小標籤（例如一個演算法），fill / color 用來表示嚴重度 */
  function chip(slide, label, x, y, w, fill, color = COLOR.ink, h = 0.4, fontSize = 13) {
    slide.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w, h, rectRadius: h / 2, fill: { color: fill }, line: { type: 'none' } });
    text(slide, label, { x, y, w, h, fontSize, bold: true, color, align: 'center', valign: 'middle' });
  }

  /** 程式碼框（深色底、等寬字） */
  function code(slide, lines, { x, y, w, h, fontSize = 12 }) {
    card(slide, { x, y, w, h, fill: COLOR.code });
    text(slide, lines.join('\n'), { x: x + 0.25, y: y + 0.2, w: w - 0.5, h: h - 0.4, fontFace: MONO, fontSize, color: 'E6ECF5' });
  }

  /** 大數字＋說明 */
  function stat(slide, { x, y, w, big, label, color = COLOR.navy, bigSize = 40 }) {
    text(slide, big, { x, y, w, h: 0.8, fontSize: bigSize, bold: true, color, align: 'center', valign: 'bottom' });
    text(slide, label, { x, y: y + 0.85, w, h: 0.6, fontSize: 13, color: COLOR.body, align: 'center' });
  }

  return { pres, text, contentSlide, sectionDivider, card, badge, icon, iconPng, diagram, table, node, arrow, chip, code, stat };
}
