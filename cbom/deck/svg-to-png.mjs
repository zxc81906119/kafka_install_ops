// 把 SVG 轉成 PNG（Word 手冊與 PowerPoint 簡報共用；簡報的公司 logo 也是從模板裡的 SVG 轉的）
// 圖裡的中文用系統字型繪製：Windows 的 Microsoft JhengHei；其他系統會自動找可用的 CJK 字型。
import { readFileSync } from 'node:fs';
import { Resvg } from '@resvg/resvg-js';

/**
 * @param {string} svgText  SVG 內容
 * @param {number} width    輸出寬度（px）；建議是顯示寬度的 2 倍，投影或列印才清楚
 * @returns {{ png: Buffer, width: number, height: number }}
 */
export function svgTextToPng(svgText, width) {
  const rendered = new Resvg(svgText, {
    fitTo: { mode: 'width', value: width },
    font: { loadSystemFonts: true, defaultFontFamily: 'Microsoft JhengHei' },
  }).render();
  return { png: rendered.asPng(), width: rendered.width, height: rendered.height };
}

/** 同上，讀 SVG 檔 */
export function svgToPng(svgPath, width) {
  return svgTextToPng(readFileSync(svgPath, 'utf8'), width);
}
