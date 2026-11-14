#!/usr/bin/env node
// ============================================================================
// 產生簡報「Confluent Platform 的密碼學資產盤點」→ docs/Cbom-平台盤點.pptx（套用公司模板）
//
// 用法（在 cbom/deck 裡）：npm ci，然後 node build-cbom-platform.mjs <公司模板.pptx> [輸出.pptx]
//
// 聽眾是技術主管，而且已經聽過「Cbom 探討」（build-cbom-talk.mjs：CBOMkit 平台＋同一個 web app 的 pipeline），
// 所以這一份不重講 CBOM 與 PQC 的背景，只講「沒有原始碼的產品怎麼盤」：手冊第 33 章。不放指令。
// 呈現方式的優先順序：圖 → 表 → 文字。流程圖和手冊用同一份（docs/journey-src/diagrams.js 的 cbom）。
//
// 數字來源（不要在 SLIDES 裡直接寫數字，改 DATA）：lab Jenkins 工作 cbom 第 1 次執行（2026-11-14，10 台主機、
// CP 8.3.2、JDK 25，沒有錄執行期證據）；截圖是同一次執行的 Jenkins 畫面與報告（node cbom/deck/shots.mjs cp <report.html>）。
// ============================================================================
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createDeck, COLOR, BRAND, W, M, CONTENT_TOP } from './deck-kit.mjs';

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
if (!process.argv[2]) {
  console.error('用法：node build-cbom-platform.mjs <公司模板.pptx> [輸出.pptx]');
  process.exit(64);
}
const TEMPLATE_FILE = resolve(process.argv[2]);
const output = process.argv[3] ?? resolve(TOOLS_DIR, '..', '..', 'docs', 'Cbom-平台盤點.pptx');
const SHOTS_DIR = resolve(TOOLS_DIR, 'images', 'cbomkit');
const require = createRequire(import.meta.url);
const { Resvg } = require('@resvg/resvg-js');
const DIAGRAMS = require(resolve(TOOLS_DIR, '..', '..', 'docs', 'journey-src', 'diagrams.js'));

const DATA = {
  hosts: 10, endpoints: 37, components: 151, assets: 81, minutes: '6–11',   // components：CBOM 的元件數；assets：其中的密碼學資產
  violation: 0, quantumVulnerable: 69, warning: 3, review: 0, pass: 52, info: 27,
  pqcEndpoints: 37, tls12Endpoints: 37,
  certs: 'RSA-4096 × 2、RSA-2048 × 7',
};

const PRESENTER = 'ming';
const TALK_DATE = '2026-11';

const { pres, text, contentSlide, card, badge, icon, iconPng, table, node, arrow } =
  await createDeck({ title: 'Confluent Platform 的密碼學資產盤點', author: PRESENTER, templateFile: TEMPLATE_FILE });

/** 放一張截圖：在 box 裡等比縮放、置中，加細框；回傳實際位置（標註用） */
function img(slide, file, box, alt) {
  const buf = readFileSync(resolve(SHOTS_DIR, file));
  const pw = buf.readUInt32BE(16), ph = buf.readUInt32BE(20);
  let w = box.w, h = w * ph / pw;
  if (h > box.h) { h = box.h; w = h * pw / ph; }
  const x = box.x + (box.w - w) / 2, y = box.y;
  slide.addImage({ data: `image/png;base64,${buf.toString('base64')}`, x, y, w, h, altText: alt });
  slide.addShape(pres.shapes.RECTANGLE, { x, y, w, h, fill: { type: 'none' }, line: { color: 'C8CDD3', width: 0.75 } });
  return { x, y, w, h };
}

/** 放一張手冊的流程圖（SVG 轉成 PNG）：在 box 裡等比縮放、置中 */
function diagram(slide, id, box, alt) {
  const png = new Resvg(DIAGRAMS[id](), { fitTo: { mode: 'width', value: 2400 } }).render().asPng();
  const pw = png.readUInt32BE(16), ph = png.readUInt32BE(20);
  let w = box.w, h = w * ph / pw;
  if (h > box.h) { h = box.h; w = h * pw / ph; }
  slide.addImage({ data: `image/png;base64,${png.toString('base64')}`, x: box.x + (box.w - w) / 2, y: box.y, w, h, altText: alt });
}

const S0 = '開場', S1 = '做法', S2 = '結果', S3 = '導入';

function cover() {
  pres.addSection({ title: S0 });
  const s = pres.addSlide({ masterName: 'COVER', sectionTitle: S0 });
  text(s, 'Cryptography Bill of Materials', { x: 0.5, y: 1.95, w: 6, h: 0.4, fontSize: 16, bold: true, color: COLOR.red });
  text(s, '平台軟體的\n密碼學資產盤點', { x: 0.5, y: 2.4, w: 6.2, h: 1.5, fontSize: 38, bold: true, color: COLOR.ink, valign: 'middle' });
  text(s, '以 Confluent Platform 為例', { x: 0.5, y: 3.95, w: 6, h: 0.5, fontSize: 22, bold: true, color: COLOR.navy });
  text(s, '沒有原始碼的產品怎麼盤：盤部署出來的東西', { x: 0.5, y: 4.5, w: 5.8, h: 0.45, fontSize: 15, color: COLOR.body });
  text(s, `${PRESENTER} · ${TALK_DATE}`, { x: 0.5, y: 5.1, w: 6, h: 0.35, fontSize: 14, color: COLOR.muted });
  s.addNotes('上一份簡報講的是自己開發的 app：有原始碼，可以用 CBOMkit 平台掃，也可以放進 pipeline。這一份講另一種情況：買來的平台軟體，沒有原始碼。例子是我們替銀行安裝的 Confluent Platform，數字與畫面都是 lab 實際執行的結果。');
}

function summary() {
  const s = contentSlide(S0, '重點摘要', '三件事看懂這份簡報');
  const cw = (W - 2 * M - 0.6) / 3, ch = 3.55, y = CONTENT_TOP + 0.1;
  const items = [
    { ic: 'package-search', fill: COLOR.red, head: '盤部署出來的東西', big: '5 層', label: '憑證、設定、連線、函式庫、執行期', note: '沒有原始碼，掃原始碼的工具用不上；\n改盤主機上實際在跑的東西' },
    { ic: 'shield-check', fill: COLOR.amber, head: '全程只讀', big: `${DATA.hosts} 台`, label: `每一台都收，約 ${DATA.minutes} 分鐘`, note: '不取私鑰與密碼、主機上不放新程式；\nJenkins 不持有平台的任何金鑰' },
    { ic: 'scale', fill: COLOR.green, head: 'lab 的結果', big: `${DATA.violation} 違規`, label: `量子脆弱 ${DATA.quantumVulnerable}、警告 ${DATA.warning}`, note: '憑證都是 RSA，要等 CA；\n金鑰交換伺服器端已經支援後量子' },
  ];
  items.forEach((it, i) => {
    const x = M + i * (cw + 0.3);
    card(s, { x, y, w: cw, h: ch });
    icon(s, it.ic, x + 0.3, y + 0.3, 0.65, it.fill);
    text(s, it.head, { x: x + 1.1, y: y + 0.3, w: cw - 1.3, h: 0.65, fontSize: 17, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, it.big, { x: x + 0.3, y: y + 1.15, w: cw - 0.6, h: 0.9, fontSize: 44, bold: true, color: it.fill, valign: 'middle' });
    text(s, it.label, { x: x + 0.3, y: y + 2.05, w: cw - 0.6, h: 0.35, fontSize: 14, bold: true, color: COLOR.body });
    text(s, it.note, { x: x + 0.3, y: y + 2.5, w: cw - 0.6, h: 0.9, fontSize: 13, color: COLOR.muted });
  });
  card(s, { x: M, y: y + ch + 0.3, w: W - 2 * M, h: 0.7, fill: COLOR.blueTint, line: COLOR.blue });
  text(s, '報告的用途是盤點與排遷移的優先序，不是拿到「全部通過」：現在的憑證都是 RSA，量子脆弱一定有',
    { x: M + 0.3, y: y + ch + 0.3, w: W - 2 * M - 0.6, h: 0.7, fontSize: 15, bold: true, color: COLOR.navy, valign: 'middle' });
  s.addNotes(`先講結論。第一，平台軟體沒有原始碼，所以盤的是部署出來的東西，分五層。第二，全程只讀：不取私鑰與密碼，平台主機上不放任何新程式，Jenkins 也不持有平台的金鑰；${DATA.hosts} 台主機每一台都收，一次大約 ${DATA.minutes} 分鐘。第三，lab 的結果是 ${DATA.violation} 個違規、${DATA.quantumVulnerable} 個量子脆弱、${DATA.warning} 個警告。量子脆弱多是預期的，因為現在的憑證都是 RSA；這份報告的用途是排遷移的優先序。`);
}

function whyDifferent() {
  pres.addSection({ title: S1 });
  const s = contentSlide(S1, '為什麼換做法', '沒有原始碼：盤的是部署出來的東西');
  table(s, ['', '自己開發的 app（上一份簡報）', '買來的平台軟體（這一份）'], [
    ['手上有什麼', '原始碼、建置過程、映像', '只有安裝好的主機'],
    ['主要的盤法', '建置時掃原始碼', '到每台主機上收實際的設定與憑證，掃每個埠'],
    ['什麼時候盤', '每次建置', '憑證換發、升級、修補之後；平常每季一次'],
    ['違規時', '讓建置失敗', '當成事件處理，修正後再盤一次'],
    ['程式內部怎麼用密碼學', '原始碼掃描看得到', '只看得到函式庫與執行期證據；完整的要向原廠要'],
    ['後半段', '合併成一份 CBOM、OPA 規則（六個等級）、一頁報告', '相同：同一套工具、同一份規則、同樣格式的報告'],
  ], { x: M, y: CONTENT_TOP, w: W - 2 * M, colW: [2.6, 4.4, W - 2 * M - 7.0], fontSize: 13, rowH: 0.6, firstColBold: true });
  s.addNotes('和上一份簡報對照。自己開發的 app，原始碼、建置過程、映像都在我們手上，所以主要在建置時掃。買來的平台軟體，我們手上只有安裝好的主機，所以改成到每台主機上收實際的設定與憑證，並且掃每個埠。時機也不同：不是每次建置，而是憑證換發、升級、修補之後，平常每季一次。違規時不是讓建置失敗，而是當成事件處理。要先講清楚的限制：原廠程式內部怎麼用密碼學，我們只看得到它帶了哪些函式庫，以及執行期實際用到的演算法；完整的要向原廠要。後半段則完全相同：合併成一份 CBOM、同一份規則、同樣格式的報告。');
}

function layers() {
  const s = contentSlide(S1, '盤什麼', '五層，加上函式庫：每一層回答一個問題');
  table(s, ['層', '回答的問題', '怎麼取得', '工具'], [
    ['① 憑證與金鑰', '每個埠實際出示哪張憑證？金鑰多長、何時到期？', '從操作機連每個埠；讀公開的憑證檔', 'cbomkit-theia'],
    ['② JDK 與 OS 設定', '停用了哪些演算法？TLS 啟用哪些版本？', '請各台的 JDK 印出實際生效的值，和設定檔對照', 'JDK 本身'],
    ['③ 平台設定', 'TLS 版本、登入機制、token 簽章怎麼設的？', '讀各台的設定檔（密碼類的值在主機上先遮掉）', '系統指令'],
    ['④ 實際連線', '每個埠真的接受哪些 TLS 版本與 cipher suite？', '從操作機掃', 'testssl.sh'],
    ['函式庫', '原廠帶了哪些密碼函式庫、什麼版本？', 'jar 清單相同的主機歸一組，每組掃一台', 'syft'],
    ['⑤ 執行期（可選）', '服務執行時實際用了哪些演算法？', '用 JDK 內建的 JFR 錄一段時間', 'jcmd、jfr'],
  ], { x: M, y: CONTENT_TOP, w: W - 2 * M, colW: [2.2, 4.3, 4.133, 1.5], fontSize: 12.5, rowH: 0.6, firstColBold: true });
  const by = CONTENT_TOP + 4.4;
  card(s, { x: M, y: by, w: W - 2 * M, h: 0.6, fill: COLOR.blueTint });
  text(s, '設定檔寫的（③）和實際開放的（④）分開盤：兩邊不一致，正是盤點要抓的事', { x: M + 0.3, y: by, w: W - 2 * M - 0.6, h: 0.6, fontSize: 13.5, bold: true, color: COLOR.navy, valign: 'middle' });
  s.addNotes('盤的東西分五層，再加上函式庫，每一層回答一個問題。第一層是憑證與金鑰：每個埠實際出示哪張憑證、金鑰多長、何時到期。第二層是 JDK 與作業系統的設定：停用了哪些演算法、TLS 啟用哪些版本；做法是請每台的 JDK 自己印出實際生效的值，再和設定檔對照。第三層是平台自己的設定檔，密碼類的值在主機上就先遮掉才傳回來。第四層是實際連線：從操作機掃每個埠，看它真的接受哪些 TLS 版本。函式庫看原廠帶了哪些密碼函式庫。第五層是執行期證據，可選，用 JDK 內建的 JFR 錄一段。第三層和第四層刻意分開：設定檔寫的和實際開放的如果不一致，正是盤點要抓出來的。工具都是開源的現成工具，加上 JDK 與系統本來就有的指令。');
}

function flow() {
  const s = contentSlide(S1, '流程', '操作機收集、合併、判斷、出報告');
  diagram(s, 'cbom', { x: M, y: CONTENT_TOP - 0.1, w: W - 2 * M, h: 4.75 }, '流程圖：平台主機每台都收，操作機上分層收集後合併成 cbom.json，用 OPA 判斷成 findings.json，再產出 report.html');
  text(s, '同一個資產在 CBOM 裡只記一筆，附上出現在哪幾台；合併後用 CycloneDX 官方的 schema 驗證',
    { x: M, y: CONTENT_TOP + 4.75, w: W - 2 * M, h: 0.35, fontSize: 12, color: COLOR.muted });
  s.addNotes('流程從左到右。左邊是平台主機：controller、broker、REST Proxy、Control Center，每一台都收。中間是操作機：分層收集，然後三個步驟。第一步合併成一份 CBOM，同一個資產只記一筆，附上出現在哪幾台，並且用 CycloneDX 官方的 schema 驗證。第二步用 OPA 依規則判斷，分六個等級。第三步產出一頁 HTML 的報告。右邊是產出給誰：Jenkins 上可以勾選範圍、執行、下載；cbom.json 可以交給客戶自己的盤點系統；報告用來排遷移計畫。');
}

function principles() {
  const s = contentSlide(S1, '三個原則', '對正式環境的影響降到最低');
  const gap = 0.3, cw = (W - 2 * M - gap * 2) / 3, ch = 3.4, y = CONTENT_TOP + 0.1;
  const items = [
    { ic: 'eye', fill: COLOR.green, tint: COLOR.greenTint, t: '全程只讀', lines: ['不取私鑰', '設定檔裡密碼類的值，在主機上就換成「遮蔽」才傳回', '不改任何設定'] },
    { ic: 'server', fill: COLOR.blue, tint: COLOR.blueTint, t: '主機上不放新程式', lines: ['平台主機只跑系統本來就有的指令', '工具都裝在操作機', 'TLS 掃描從操作機發起'] },
    { ic: 'layers', fill: COLOR.amber, tint: COLOR.amberTint, t: '每一台都收', lines: ['不是每種元件挑一台', '要抓的正是「某一台和別台不一樣」', '可以只勾選部分元件，報告會標成部分盤點'] },
  ];
  items.forEach((it, i) => {
    const x = M + i * (cw + gap);
    card(s, { x, y, w: cw, h: ch, fill: it.tint });
    icon(s, it.ic, x + 0.3, y + 0.3, 0.6, it.fill);
    text(s, it.t, { x: x + 1.1, y: y + 0.3, w: cw - 1.3, h: 0.6, fontSize: 18, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, it.lines.map((t, j) => ({ text: t, options: { bullet: true, breakLine: j < it.lines.length - 1 } })),
      { x: x + 0.35, y: y + 1.15, w: cw - 0.7, h: ch - 1.3, fontSize: 14, color: COLOR.body, paraSpaceAfter: 8 });
  });
  const by = y + ch + 0.3;
  card(s, { x: M, y: by, w: W - 2 * M, h: 0.7 });
  text(s, [
    { text: '例外要先同意：', options: { bold: true, color: COLOR.navy } },
    { text: '執行期證據（JFR）是對執行中的服務錄製，預設不做，要先經銀行同意才勾選', options: { color: COLOR.body } },
  ], { x: M + 0.3, y: by, w: W - 2 * M - 0.6, h: 0.7, fontSize: 13.5, valign: 'middle' });
  s.addNotes('因為對象是正式環境，設計上守三個原則。第一，全程只讀：不取私鑰；設定檔裡密碼類的值，在主機上就換成遮蔽兩個字才傳回來，所以原料裡沒有密碼；不改任何設定。第二，平台主機上不放新程式：主機上只跑系統本來就有的指令，工具都裝在操作機，TLS 掃描也從操作機發起。第三，每一台都收，不是每種元件挑一台，因為盤點要抓的正是某一台和別台不一樣。唯一的例外是執行期證據：它要對執行中的服務錄製，所以預設不做，要先經過銀行同意。');
}

function jenkinsSplit() {
  const s = contentSlide(S1, 'Jenkins 與操作機的分工', 'Jenkins 只觸發與出報告，不持有平台的任何金鑰');
  const y = CONTENT_TOP + 0.35, h = 1.5;
  const jw = 3.3, ow = 3.6, hw = 3.0;
  const ox = M + jw + 1.35, hx = W - M - hw;
  node(s, { x: M, y, w: jw, h, title: 'Jenkins', sub: '勾選範圍、觸發\n合併、OPA、報告、保存', fill: COLOR.blueTint, line: COLOR.blue, fontSize: 16, subSize: 12 });
  node(s, { x: ox, y, w: ow, h, title: '操作機', sub: '收集腳本\n平台的金鑰與憑證只在這裡', fill: COLOR.navy, line: COLOR.navy, titleColor: COLOR.white, subColor: 'C9D4E5', fontSize: 16, subSize: 12 });
  node(s, { x: hx, y, w: hw, h, title: `平台主機 ×${DATA.hosts}`, sub: '唯讀的系統指令\n各埠的 TLS', fill: COLOR.white, fontSize: 16, subSize: 12 });
  arrow(s, M + jw + 0.05, y + 0.5, ox - 0.05, y + 0.5, '① 觸發');
  arrow(s, ox - 0.05, y + 1.0, M + jw + 0.05, y + 1.0, '② 原料（已遮蔽）');
  arrow(s, ox + ow + 0.05, y + h / 2, hx - 0.05, y + h / 2);
  const ty = y + h + 0.5;
  table(s, ['控管', '做法'], [
    ['Jenkins 連操作機', '專用帳號與一把 ssh 金鑰；這把金鑰在操作機上被限制成只能觸發收集、取回原料，不能開 shell'],
    ['Jenkins 拿到的東西', '遮蔽過的設定、公開的憑證、掃描結果；沒有私鑰、沒有密碼'],
    ['平台主機的權限', '交付後只多開幾條唯讀指令的 sudo，逐條列出'],
  ], { x: M, y: ty, w: W - 2 * M, colW: [2.8, W - 2 * M - 2.8], fontSize: 12.5, rowH: 0.52, firstColBold: true });
  s.addNotes('自動化用 Jenkins，但分工刻意切開。Jenkins 負責勾選範圍、觸發，以及拿到原料之後的合併、判斷、報告與保存。真正到主機上收集的是操作機，因為平台的金鑰與憑證本來就只在操作機上。Jenkins 連操作機用一個專用帳號和一把 ssh 金鑰，這把金鑰在操作機上被限制成只能做兩件事：觸發收集、取回原料，不能開 shell。Jenkins 拿到的原料是遮蔽過的設定、公開的憑證和掃描結果，沒有私鑰、沒有密碼。所以就算 Jenkins 被入侵，拿不到平台的金鑰。平台主機這一邊，交付之後只需要多開幾條唯讀指令的 sudo。');
}

function result() {
  pres.addSection({ title: S2 });
  const s = contentSlide(S2, 'lab 的結果', `${DATA.hosts} 台主機、${DATA.endpoints} 個 TLS 端點、${DATA.assets} 個密碼學資產`);
  const levels = [
    [String(DATA.violation), '違規', COLOR.red], [String(DATA.quantumVulnerable), '量子脆弱', COLOR.amber], [String(DATA.warning), '警告', COLOR.amberText ?? COLOR.amber],
    [String(DATA.review), '無法判斷', COLOR.blue], [String(DATA.pass), '通過', COLOR.green], [String(DATA.info), '資訊', COLOR.navy],
  ];
  const gap = 0.15, cw = (W - 2 * M - gap * 5) / 6, y = CONTENT_TOP;
  levels.forEach(([big, label, color], i) => {
    const x = M + i * (cw + gap);
    card(s, { x, y, w: cw, h: 1.15, fill: COLOR.white, line: 'C8CDD3' });
    text(s, big, { x: x + 0.2, y: y + 0.08, w: cw - 0.4, h: 0.65, fontSize: 30, bold: true, color, valign: 'middle' });
    text(s, label, { x: x + 0.2, y: y + 0.72, w: cw - 0.4, h: 0.35, fontSize: 12.5, color: COLOR.body });
  });
  table(s, ['看到什麼', '意思', '怎麼處理'], [
    [`憑證 9 張都是 RSA（${DATA.certs}）`, '量子脆弱：2030 年後棄用、2035 年後禁用（NIST IR 8547）', '等銀行的 CA 能簽後量子憑證；有效期跨過 2035 年的根憑證與簽發憑證優先'],
    [`${DATA.pqcEndpoints}／${DATA.endpoints} 個端點支援後量子混合金鑰交換`, 'JDK 25 的 TLS 1.3 預設就有 X25519MLKEM768', '伺服器端已就緒；接著盤用戶端支不支援'],
    [`${DATA.tls12Endpoints}／${DATA.endpoints} 個端點仍接受 TLS 1.2`, '警告：TLS 1.2 用不了後量子金鑰交換', '確認用戶端都能用 TLS 1.3 之後關掉'],
    ['接受 CBC 類的舊 cipher suite', '警告：建議只留 AEAD', '和上一項一起調整'],
  ], { x: M, y: y + 1.45, w: W - 2 * M, colW: [4.0, 4.3, W - 2 * M - 8.3], fontSize: 12, rowH: 0.62, firstColBold: true });
  s.addNotes(`這是 lab 實際的結果：${DATA.hosts} 台主機、${DATA.endpoints} 個 TLS 端點，合併後 ${DATA.components} 個元件，其中密碼學資產 ${DATA.assets} 個。違規是零，表示沒有已經不安全的東西：沒有 SHA-1、沒有過短的金鑰、沒有 TLS 1.1 以下、沒有過期的憑證。量子脆弱 ${DATA.quantumVulnerable} 個，主要是憑證：九張都是 RSA。這是事實，不是工具的問題，要等銀行的 CA 能簽後量子演算法的憑證才換得掉；其中有效期跨過 2035 年的根憑證和簽發憑證要優先規劃。好消息在金鑰交換：${DATA.endpoints} 個端點全部支援後量子混合金鑰交換，因為 JDK 25 的 TLS 1.3 預設就有；這也是我們把平台遷移到 JDK 25 的附帶好處。伺服器端就緒之後，下一步是盤用戶端。警告有三類，都和 TLS 1.2 與舊的 cipher suite 有關，等確認用戶端都能用 TLS 1.3 之後可以一起關掉。`);
}

function reportGuide() {
  const s = contentSlide(S2, '怎麼看報告', '先看橫幅過不過，再看遷移重點，最後看清單在哪幾台');
  const iw = 6.9;
  const top = img(s, 'report-cp.png', { x: M, y: CONTENT_TOP - 0.05, w: iw, h: 3.0 }, '合規報告的上半部：範圍與主機、合規的橫幅、各等級的數量、後量子遷移的重點');
  const low = img(s, 'report-cp-qv.png', { x: M, y: top.y + top.h + 0.12, w: iw, h: 1.75 }, '合規報告的量子脆弱清單：憑證、判斷與依據、出現在哪些主機的哪個埠');
  [0.2, 0.305, 0.505, 0.8].forEach((fy, i) => badge(s, i + 1, top.x + top.w - 0.2, top.y + top.h * fy - 0.19, 0.38, COLOR.red, 13));
  badge(s, 5, low.x + low.w - 0.2, low.y + 0.12, 0.38, COLOR.red, 13);
  const rx = M + iw + 0.55, rw = W - rx - M;
  const items = [
    ['範圍', '盤了哪些元件、哪幾台；沒有全選會標成「部分盤點」'],
    ['判定橫幅', '合規或不合規；只有「違規」會讓它變成不合規'],
    ['六個數字', '元件數：同一個元件出現在多台主機只算一次；上面一行「盤點完整性」說該收的原料有沒有收齊'],
    ['後量子遷移的重點', '幾個端點支援後量子金鑰交換、還接受 TLS 1.2 的有幾個、憑證用什麼金鑰、最早到期日'],
    ['各等級的清單', '一列一個資產：為什麼這樣判、依據哪份標準、出現在哪幾台的哪個埠或哪個檔'],
  ];
  items.forEach(([head, body], i) => {
    const y = CONTENT_TOP + i * 0.95;
    badge(s, i + 1, rx, y, 0.4, COLOR.red, 13);
    text(s, head, { x: rx + 0.55, y: y - 0.04, w: rw - 0.55, h: 0.4, fontSize: 14, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, body, { x: rx + 0.55, y: y + 0.36, w: rw - 0.55, h: 0.55, fontSize: 11.5, color: COLOR.body });
  });
  s.addNotes('報告的格式和上一份簡報的 web app 相同，照編號看。第一塊是範圍：這次盤了哪些元件、哪幾台主機、有沒有錄執行期證據；如果沒有全選，這裡會標成部分盤點。第二塊是判定橫幅，這一份是合規，因為沒有違規；量子脆弱和警告不影響它。第三塊是六個數字，算的是資產數，同一個資產出現在多台主機只算一次。第四塊是後量子遷移的重點，主管最該看的就是這一塊：幾個端點支援後量子金鑰交換、還有幾個接受 TLS 1.2、憑證用什麼金鑰、最早哪一天到期。第五塊是各等級的清單，一列一個資產，最右邊一欄列出它出現在哪幾台的哪個埠或哪個檔，所以拿到報告就知道要去哪幾台處理。');
}

function jenkinsShots() {
  const s = contentSlide(S2, 'Jenkins 上的樣子', '依元件勾選範圍；結果與報告留在 Jenkins');
  const lw = 6.4, gap = 0.35, h = 4.45;
  img(s, 'jenkins-cp-params.png', { x: M, y: CONTENT_TOP, w: lw, h }, 'Jenkins 工作 cbom 的參數頁：controller、broker、REST Proxy、Control Center、平台共用各一個勾選框，另有執行期證據');
  img(s, 'jenkins-cp-job.png', { x: M + lw + gap, y: CONTENT_TOP, w: W - 2 * M - lw - gap, h }, 'Jenkins 工作 cbom 的工作頁：可下載的三個檔，以及這次執行的結果摘要');
  text(s, '左：要盤哪些元件用勾的；執行期證據另外勾，預設不做。右：三個檔可以下載，每次執行的說明列出範圍與各等級的數量',
    { x: M, y: CONTENT_TOP + h + 0.12, w: W - 2 * M, h: 0.5, fontSize: 12, color: COLOR.muted });
  s.addNotes(`這是 lab 的 Jenkins 實際的畫面。左邊是執行前的參數：controller、broker、REST Proxy、Control Center、平台共用的資產各一個勾選框，可以全選，也可以只盤其中幾種；執行期證據另外一個勾選框，預設不勾。右邊是執行後：最上面三個檔可以直接下載，分別是 CBOM、判斷結果和報告；左下是每一次執行，說明欄列出這次的範圍和各等級的數量。左邊選單的「CBOM 合規報告」點進去就是上一頁那份報告。全部 ${DATA.hosts} 台盤一次大約 ${DATA.minutes} 分鐘，也可以設成定期執行。`);
}

function operate() {
  pres.addSection({ title: S3 });
  const s = contentSlide(S3, '交付之後', '什麼時候盤、結果怎麼用');
  const lw = 4.3;
  card(s, { x: M, y: CONTENT_TOP, w: lw, h: 4.4 });
  icon(s, 'calendar-clock', M + 0.3, CONTENT_TOP + 0.25, 0.6, COLOR.navy);
  text(s, '什麼時候盤', { x: M + 1.1, y: CONTENT_TOP + 0.25, w: lw - 1.3, h: 0.6, fontSize: 18, bold: true, color: COLOR.ink, valign: 'middle' });
  text(s, ['憑證換發之後', '平台升級之後', 'OS 或 JDK 修補之後', '平常每季一次（Jenkins 可以排程）'].map((t, j, a) => ({ text: t, options: { bullet: true, breakLine: j < a.length - 1 } })),
    { x: M + 0.35, y: CONTENT_TOP + 1.1, w: lw - 0.7, h: 2.0, fontSize: 14, color: COLOR.body, paraSpaceAfter: 8 });
  text(s, '執行期證據不排進定期執行', { x: M + 0.35, y: CONTENT_TOP + 3.6, w: lw - 0.7, h: 0.5, fontSize: 12.5, color: COLOR.muted });
  const rx = M + lw + 0.35, rw = W - rx - M;
  table(s, ['報告上的', '怎麼處理'], [
    ['違規', '當成事件處理：照報告列的主機與原因修正，再盤一次確認歸零'],
    ['量子脆弱：憑證', '等銀行的 CA 能簽後量子憑證再換；有效期跨過 2030／2035 年的優先'],
    ['量子脆弱：金鑰交換', '伺服器端已支援混合金鑰交換；盤用戶端（應用程式的 JDK、函式庫版本）'],
    ['警告：TLS 1.2', '確認所有用戶端都能用 TLS 1.3 之後，設定改成只留 TLS 1.3'],
    ['無法判斷', '規則不認得的：人看過之後補進規則'],
  ], { x: rx, y: CONTENT_TOP, w: rw, colW: [2.3, rw - 2.3], fontSize: 12.5, rowH: 0.73, firstColBold: true });
  s.addNotes('交付之後怎麼用。什麼時候盤：憑證換發、平台升級、作業系統或 JDK 修補之後各做一次，因為這三種變更都會改變密碼學的設定；平常每季一次，Jenkins 可以排程。執行期證據不要排進定期執行。結果怎麼用：違規當成事件處理，修正之後再盤一次確認歸零。量子脆弱分兩種：憑證要等銀行的 CA，先處理有效期跨過 2030 和 2035 年的；金鑰交換伺服器端已經支援，所以工作在用戶端，要盤應用程式用的 JDK 和函式庫版本。TLS 1.2 的警告，等確認所有用戶端都能用 TLS 1.3 之後關掉。無法判斷的，人看過之後補進規則。');
}

function limitsAndAsk() {
  const s = contentSlide(S3, '限制與要確認的事', '要先知道它看不到什麼，以及導入前要和銀行定的事');
  const gap = 0.3, cw = (W - 2 * M - gap) / 2, ch = 4.45;
  const cols = [
    { ic: 'circle-alert', fill: COLOR.amber, tint: COLOR.amberTint, t: '限制', items: [
      '原廠程式內部怎麼用密碼學：只盤得到函式庫與執行期證據，完整的要向原廠要 SBOM／CBOM',
      '執行期證據只看得到錄製期間發生的事',
      'CBOM 列出所有端點與演算法，本身是敏感資料',
      'lab 的主機是容器：OS 層的設定在正式環境要再驗一次'] },
    { ic: 'clipboard-list', fill: COLOR.blue, tint: COLOR.blueTint, t: '導入前要和銀行確認', items: [
      '行內 Jenkins 的版本，執行工作的節點能不能連操作機',
      '可否建立專用帳號，以及那幾條唯讀的 sudo',
      'CBOM 與報告放哪裡、誰能看',
      '接收 CBOM 的系統支援 CycloneDX 1.6 還是 1.7',
      '有沒有指定的後量子規範與金鑰長度下限',
      '能不能在正式環境錄執行期證據'] },
  ];
  cols.forEach((c, i) => {
    const x = M + i * (cw + gap);
    card(s, { x, y: CONTENT_TOP, w: cw, h: ch, fill: c.tint });
    icon(s, c.ic, x + 0.3, CONTENT_TOP + 0.25, 0.6, c.fill);
    text(s, c.t, { x: x + 1.1, y: CONTENT_TOP + 0.25, w: cw - 1.3, h: 0.6, fontSize: 18, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, c.items.map((t, j) => ({ text: t, options: { bullet: true, breakLine: j < c.items.length - 1 } })),
      { x: x + 0.35, y: CONTENT_TOP + 1.05, w: cw - 0.7, h: ch - 1.2, fontSize: 13.5, color: COLOR.body, paraSpaceAfter: 7 });
  });
  s.addNotes('最後是限制，以及導入前要確認的事。限制有四點。第一，原廠程式內部怎麼用密碼學，我們只盤得到它帶的函式庫和執行期證據，完整的要向原廠要 SBOM 或 CBOM。第二，執行期證據只看得到錄製期間發生的事。第三，CBOM 列出所有端點與演算法，本身就是敏感資料，存放位置和誰能看要照銀行的規定。第四，lab 的主機是容器，作業系統層的設定在正式環境要再驗一次。導入前要和銀行確認的事在右邊：Jenkins 的版本與連線、專用帳號與 sudo、CBOM 放哪裡與誰能看、接收的系統支援哪個版本的格式、有沒有指定的後量子規範，以及能不能在正式環境錄執行期證據。這些都已經列在給銀行的確認事項裡。');
}

function closing() {
  const s = pres.addSlide({ masterName: 'CLOSING', sectionTitle: S3 });
  text(s, '謝謝聆聽', { x: 0.5, y: 2.61, w: 6, h: 1.14, fontSize: 48, bold: true, color: COLOR.ink, valign: 'middle' });
  text(s, '問題與討論', { x: 0.5, y: 3.75, w: 6, h: 0.6, fontSize: 24, color: COLOR.navy });
  s.addNotes('開放提問。');
}

cover(); summary();
whyDifferent(); layers(); flow(); principles(); jenkinsSplit();
result(); reportGuide(); jenkinsShots();
operate(); limitsAndAsk(); closing();

await pres.writeFile({ fileName: output });
console.log(`Wrote ${output}`);
