// ============================================================================
// 讀取公司簡報模板（docs/presentations/IISI_PPT_Template_2026_淺色版.pptx），給 build-deck.mjs 套用。
//
// 模板的品牌元素都是圖片：全版背景（PNG）、右側色條（PNG 裁切後的一小條）、logo（SVG）。
// 這裡依「版面配置名稱」（封面、大綱、扉頁、標題及內容、封底…）找出每張圖片、它的位置與裁切，
// 簡報就不用另外存一份圖片：模板換新版時，只要替換 .pptx 檔、重跑 npm run build:deck。
//
// 文字的位置、字型、大小不從模板讀（寫在 build-deck.mjs 的 TEMPLATE_TEXT），因為簡報的內容版面是自己排的。
// ============================================================================
import { readFileSync } from 'node:fs';
import JSZip from 'jszip';
import { svgTextToPng } from './svg-to-png.mjs';

const EMU_PER_INCH = 914400;
const inch = emu => Number(emu) / EMU_PER_INCH;
const SLIDE_W = 13.333;

/** 讀 rels 檔：rId → 目標檔名（例如 rId2 → ppt/media/image3.png） */
function readRels(xml, baseDir) {
  const map = {};
  for (const m of xml.matchAll(/<Relationship [^>]*Id="([^"]+)"[^>]*Target="([^"]+)"/g)) {
    map[m[1]] = new URL(m[2], `file:///${baseDir}/`).pathname.slice(1);
  }
  return map;
}

/** PNG 的寬高（IHDR） */
const pngSize = buf => ({ width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) });

/**
 * 依 <a:srcRect>（l/t/r/b，單位是 1/1000 %）裁切 PNG。沒有裁切就原樣回傳。
 * 用 resvg 畫一個 viewBox 只框住保留區域的 SVG，不必另外裝影像處理套件。
 */
function cropPng(buf, rect) {
  if (!rect) return buf;
  const { width, height } = pngSize(buf);
  const l = (rect.l ?? 0) / 100000 * width, t = (rect.t ?? 0) / 100000 * height;
  const w = width - l - (rect.r ?? 0) / 100000 * width, h = height - t - (rect.b ?? 0) / 100000 * height;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="${l} ${t} ${w} ${h}" width="${w}" height="${h}">`
    + `<image width="${width}" height="${height}" xlink:href="data:image/png;base64,${buf.toString('base64')}"/></svg>`;
  return svgTextToPng(svg, Math.max(1, Math.round(w))).png;
}

/**
 * @returns {Promise<Object<string, { background?: string, images: Array<{ data, x, y, w, h }>, logo?: { data, x, y, w, h } }>>}
 *   key 是版面配置名稱；data 是 pptxgenjs 用的 "image/png;base64,…"。
 *   background：放在 (0,0) 的全版圖片；images：其他位置的圖片（例如右側色條）；logo：SVG 轉成的 PNG。
 */
export async function loadTemplate(path) {
  const zip = await JSZip.loadAsync(readFileSync(path));
  const layouts = {};
  const layoutFiles = Object.keys(zip.files).filter(f => /^ppt\/slideLayouts\/slideLayout\d+\.xml$/.test(f));

  for (const file of layoutFiles) {
    const xml = await zip.file(file).async('string');
    const name = xml.match(/<p:cSld name="([^"]+)"/)?.[1];
    if (!name) continue;
    const relsFile = file.replace('slideLayouts/', 'slideLayouts/_rels/') + '.rels';
    const rels = readRels(await zip.file(relsFile).async('string'), 'ppt/slideLayouts');
    const layout = { images: [] };

    for (const pic of xml.split('<p:pic>').slice(1).map(p => p.split('</p:pic>')[0])) {
      const targets = [...pic.matchAll(/r:embed="([^"]+)"/g)].map(m => rels[m[1]]).filter(Boolean);
      const svg = targets.find(t => t.endsWith('.svg'));
      const png = targets.find(t => t.endsWith('.png'));
      const xfrm = pic.match(/<a:off x="(\d+)" y="(\d+)"\/>\s*<a:ext cx="(\d+)" cy="(\d+)"\/>/);
      if (!xfrm) continue;
      const box = { x: inch(xfrm[1]), y: inch(xfrm[2]), w: inch(xfrm[3]), h: inch(xfrm[4]) };
      const srcRect = pic.match(/<a:srcRect([^/]*)\/>/)?.[1];
      const rect = srcRect ? Object.fromEntries([...srcRect.matchAll(/(\w)="(-?\d+)"/g)].map(m => [m[1], Number(m[2])])) : null;

      if (svg) {
        const { png: logoPng } = svgTextToPng(await zip.file(svg).async('string'), Math.round(box.w * 600));
        layout.logo = { data: `image/png;base64,${logoPng.toString('base64')}`, ...box };
      } else if (png) {
        const data = `image/png;base64,${cropPng(await zip.file(png).async('nodebuffer'), rect).toString('base64')}`;
        const fullSlide = box.x < 0.01 && box.y < 0.01 && box.w > SLIDE_W - 0.05;
        if (fullSlide) layout.background = data;
        else layout.images.push({ data, ...box });
      }
    }
    layouts[name] = layout;
  }
  return layouts;
}
