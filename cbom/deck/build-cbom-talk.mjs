#!/usr/bin/env node
// ============================================================================
// 產生簡報「CBOM 工具使用」→ docs/Cbom-探討.pptx（套用公司模板）
//
// 用法（在 cbom/deck 裡）：npm ci，然後 node build-cbom-talk.mjs <公司模板.pptx> [輸出.pptx]
//       公司模板不進 git（和這個專案其他簡報一樣），建置時指定路徑；沒指定輸出就寫到 docs/Cbom-探討.pptx。
//       2026-11-11 從 untitled9（crypto-lab）的 docs/tools 搬過來；那邊的 pipeline 簡報與手冊沒有搬。
//
// 這份簡報的目的：向同事介紹 CBOM，以及怎麼用 CBOMkit 平台掃出 CBOM、看懂結果、做合規檢查（含 OPA）。
// 主線是 CBOMkit 平台；第 7 部分是補強方案：同一個 web app 放進 Jenkins 的 pipeline（cbom/webapp/，不在手冊裡）。
// 對象從頭到尾是同一個典範 web app。沒有原始碼的產品（Confluent Platform，手冊第 33 章）是另一份簡報。
//
// 公司模板的讀取與版面元件在 deck-kit.mjs。
// 呈現方式的優先順序：圖 → 表 → 文字。圖用 PowerPoint 原生圖形畫；圖示來自 lucide-static（ISC 授權）。
// 平台畫面是實際操作 CBOMkit 2.3.0 的截圖（images/cbomkit/，無頭 Chrome 1440×900、2 倍解析度、淺色主題）。
//
// 數字來源（不要在 SLIDES 裡直接寫數字，改 DATA）：
//   - 掃描與截圖（Jenkins 與報告那四張是 2026-11-14 用 node cbom/deck/shots.mjs webapp <report.html> 重拍的）：2026-11-10 在當時的 lab（CBOMkit 2.3.0）掃典範 web app，三次結果相同；
//     2026-11-12 在這個專案用 bash cbom/cbomkit-demo/demo.sh scan 重測，資產數與合規比較都相同
//   - 覆蓋率：標準答案 cbom/app/expected-inventory.json（49 項）；平台 26；pipeline 各階段累計 26 → 35 → 37 → 45
//     （2026-11-14 用對答案工具 check-inventory 的比對條件重量；先前的 27／46 是舊的比對條件多算了一項）
//   - web app 的 pipeline：lab Jenkins 工作 cbom-webapp（2026-11-14，含執行期）
// 官方依據：CycloneDX 1.6 / 1.7 JSON schema、CBOMkit 與 sonar-cryptography README、OPA 官方文件與 CNCF 專案頁、NIST IR 8547
// ============================================================================
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createDeck, COLOR, BRAND, FONT, MONO, W, H, M, CONTENT_TOP, SEVERITY, TEMPLATE_TEXT } from './deck-kit.mjs';

const TOOLS_DIR = dirname(fileURLToPath(import.meta.url));
if (!process.argv[2]) {
  console.error('用法：node build-cbom-talk.mjs <公司模板.pptx> [輸出.pptx]');
  process.exit(64);
}
const TEMPLATE_FILE = resolve(process.argv[2]);
const output = process.argv[3] ?? resolve(TOOLS_DIR, '..', '..', 'docs', 'Cbom-探討.pptx');
const SHOTS_DIR = resolve(TOOLS_DIR, 'images', 'cbomkit');
// 第 7 部分的兩張流程圖和手冊用同一份（docs/journey-src/diagrams.js），建置時才畫，不會和手冊不同步
const require = createRequire(import.meta.url);
const { Resvg } = require('@resvg/resvg-js');
const DIAGRAMS = require(resolve(TOOLS_DIR, '..', '..', 'docs', 'journey-src', 'diagrams.js'));

// ---------------------------------------------------------------------------
// 實測數據
// ---------------------------------------------------------------------------
const DATA = {
  scan: {                                  // 網頁上方那一行：142 cryptographic assets found. Scanned 1.4K lines … across 15 files …
    occurrences: 142, assets: 84,          // assets：下載的 CBOM 的元件數（手冊 Lab 13）
    files: 15, lines: '1.4K',
    scanSeconds: '1–2', totalSeconds: '5–12', // 三次實測：2s/12s、1s/6s、1s/5s
  },
  overview: { na: 45.8, unknown: 31, nqs: 23.2, types: 46, primitives: 10, functions: 8 },
  // 總覽截圖上的編號位置（相對圖片寬高的比例）：橫幅、合規圓環、泡泡圖、原語、用途
  // y > 1 表示放在圖的下方（對齊每張圖的中心），避免蓋到圖上的數字
  overviewCallouts: [[0.965, 0.32], [0.145, 1.05], [0.38, 1.05], [0.627, 1.05], [0.867, 1.05]],
  compliance: {                            // 同一份掃描結果的資產數（84 個）
    builtin: { 'Not Quantum Safe': 17, 'Quantum Safe': 0, 'Not Applicable': 25, 'Unknown': 42 },
    opa: { 'Not Quantum Safe': 17, 'Quantum Safe': 16, 'Not Applicable': 9, 'Unknown': 42 },
  },
  coverage: { detected: 26, expected: 49 },
  unknownMaterial: 41,                     // 42 個 Unknown 裡，程式裡的金鑰與 salt（沒有演算法屬性）的數量
  // 自己開發的 web app 放進 pipeline（cbom/webapp/）；數量是 OPA 的判定筆數
  webapp: {
    stages: [26, 35, 37, 45],              // 累計找到標準答案的幾項：原始碼 → ＋SBOM 與秘密掃描 → ＋映像 → ＋執行期
    assets: 170, violation: 35, quantumVulnerable: 71, warning: 3, review: 3,
  },
};

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
function diagram(slide, id, box, alt, ...args) {
  const png = new Resvg(DIAGRAMS[id](...args), { fitTo: { mode: 'width', value: 2400 } }).render().asPng();
  const pw = png.readUInt32BE(16), ph = png.readUInt32BE(20);
  let w = box.w, h = w * ph / pw;
  if (h > box.h) { h = box.h; w = h * pw / ph; }
  slide.addImage({ data: `image/png;base64,${png.toString('base64')}`, x: box.x + (box.w - w) / 2, y: box.y, w, h, altText: alt });
}

// ---------------------------------------------------------------------------
// 1–2. 版面、配色與小工具：和 build-deck.mjs 共用 deck-kit.mjs
// ---------------------------------------------------------------------------
// 講者與日期：封面與檔案屬性（作者）都用這裡的值，換講者只要改這兩行
const PRESENTER = 'ming';
const TALK_DATE = '2026-11';

const { pres, text, contentSlide, sectionDivider, card, badge, icon, iconPng, table, node, arrow, chip, code, stat } =
  await createDeck({ title: 'CBOM 工具使用', author: PRESENTER, templateFile: TEMPLATE_FILE });

// ---------------------------------------------------------------------------
// 3. SLIDES
// ---------------------------------------------------------------------------
const S0 = '開場', S1 = 'CBOM 基礎', S2 = 'CBOMkit 平台', S3 = '怎麼掃描', S4 = '怎麼看結果', S5 = '合規檢查與 OPA', S6 = '平台的限制', S7 = '補強方案與建議';

function cover() {
  pres.addSection({ title: S0 });
  const s = pres.addSlide({ masterName: 'COVER', sectionTitle: S0 });
  text(s, 'Cryptography Bill of Materials', { x: 0.5, y: 1.95, w: 6, h: 0.4, fontSize: 16, bold: true, color: COLOR.red });
  text(s, 'CBOM 工具使用', { x: 0.5, y: 2.45, w: 6, h: 1.0, fontSize: 48, bold: true, color: COLOR.ink, valign: 'middle' });
  text(s, '用 CBOMkit 掃出 CBOM、看懂結果', { x: 0.5, y: 3.5, w: 6, h: 0.5, fontSize: 22, bold: true, color: COLOR.navy });
  text(s, '掃描、看結果、合規檢查（內建與 OPA）；平台的限制與補強方案', { x: 0.5, y: 4.15, w: 5.8, h: 0.45, fontSize: 15, color: COLOR.body });
  text(s, `${PRESENTER} · ${TALK_DATE}`, { x: 0.5, y: 4.85, w: 6, h: 0.35, fontSize: 14, color: COLOR.muted });
  s.addNotes('這份簡報介紹 CBOM（密碼學物料清單），以及怎麼用 CBOMkit 平台替專案掃出 CBOM、看懂結果、做合規檢查。畫面都是實際操作 CBOMkit 的截圖，數字都是在 crypto-lab 專案上實測的。');
}

function agenda() {
  const s = pres.addSlide({ masterName: 'AGENDA', sectionTitle: S0 });
  text(s, '大綱', { ...TEMPLATE_TEXT.title, fontSize: 32, bold: true, color: COLOR.ink, valign: 'middle' });
  const parts = [
    [S1, '是什麼、格式、資產類型'],
    [S2, '平台的三個部分、架構'],
    [S3, '貼上網址、掃描結果'],
    [S4, '總覽、清單、細節、下載'],
    [S5, '內建規則、OPA 是什麼與怎麼接'],
    [S6, '能做到與做不到'],
    [S7, '把盤點放進 pipeline、怎麼看報告、導入建議'],
  ];
  const x = 7.3, y0 = 1.3, rowH = 0.78;
  parts.forEach(([t, d], i) => {
    const y = y0 + i * rowH;
    badge(s, String(i + 1).padStart(2, '0'), x, y, 0.62, [COLOR.red, COLOR.amber, COLOR.green, COLOR.blue, COLOR.red, COLOR.amber, COLOR.green][i], 17);
    text(s, t, { x: x + 0.82, y: y - 0.04, w: 4.6, h: 0.38, fontSize: 19, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, d, { x: x + 0.82, y: y + 0.34, w: 4.6, h: 0.3, fontSize: 13, color: COLOR.muted, valign: 'middle' });
  });
  s.addNotes('分七個部分：CBOM 基礎；CBOMkit 平台的三個部分與架構；怎麼掃描；怎麼看結果；合規檢查與 OPA；平台的限制；最後是補強方案與導入建議。');
}

function summary() {
  const s = contentSlide(S0, '重點摘要', '三件事看懂這份簡報');
  const cw = (W - 2 * M - 0.6) / 3, ch = 3.55, y = CONTENT_TOP + 0.1;
  const items = [
    { ic: 'file-badge', fill: COLOR.red, head: 'CBOM 是什麼', big: '1.6+', label: 'CycloneDX 版本', note: '記錄演算法、憑證、協定、金鑰素材，\n以及它們在哪裡被找到' },
    { ic: 'scan-search', fill: COLOR.amber, head: '用 CBOMkit 掃描', big: String(DATA.scan.assets), label: `個密碼學資產，約 ${DATA.scan.totalSeconds} 秒`, note: '貼上 git 網址就能掃，\n總覽、清單、細節一次看到' },
    { ic: 'scale', fill: COLOR.green, head: '合規檢查', big: 'OPA', label: '把檢查規則換成公司自己的', note: '內建規則只看「量子安全」，\n已被破解的 MD5、SHA-1 不會標出來' },
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
  text(s, `平台只看原始碼（實測找到 ${DATA.coverage.detected}／${DATA.coverage.expected} 項）；同一個 app 放進 pipeline 可以找到 ${DATA.webapp.stages[3]} 項（第 7 部分）`,
    { x: M + 0.3, y: y + ch + 0.3, w: W - 2 * M - 0.6, h: 0.7, fontSize: 15, bold: true, color: COLOR.navy, valign: 'middle' });
  s.addNotes(`先講結論。第一，CBOM 是密碼學的成分表，用 CycloneDX 1.6 以上的格式。第二，用 CBOMkit 平台貼上 git 網址，約 ${DATA.scan.totalSeconds} 秒就掃完，這個專案找到 ${DATA.scan.assets} 個密碼學資產，網頁上有總覽、清單和細節。第三，平台內建的合規檢查只看量子安全，已經被破解的 MD5、SHA-1 不會被標出來；接上 OPA 就能用公司自己的規則，例如同一份結果有 ${DATA.compliance.opa['Quantum Safe']} 個對稱演算法改判成 Quantum Safe，已破解的另外標出原因。`);
}


// ---------------- PART 01：CBOM 基礎 ----------------
function whatIsCbom() {
  const s = contentSlide(S1, 'CBOM 是什麼', 'CBOM：系統裡「密碼學資產」的成分表');
  // 上方：SBOM vs CBOM
  const y0 = CONTENT_TOP;
  node(s, { x: M, y: y0, w: 5.6, h: 1.05, title: 'SBOM：用了哪些套件', sub: '主要是第三方套件，例如 BouncyCastle 1.86', fill: COLOR.white, titleColor: COLOR.muted, subColor: COLOR.muted, fontSize: 16, subSize: 12.5 });
  arrow(s, M + 5.7, y0 + 0.52, M + 6.5, y0 + 0.52, '再往裡面看');
  node(s, { x: M + 6.6, y: y0, w: W - 2 * M - 6.6, h: 1.05, title: 'CBOM：用了哪些密碼學、在哪裡、強度如何', sub: '例如 AES-256-GCM 在哪個檔案第幾行、TLS 開了哪些 cipher suite', fill: COLOR.blueTint, line: COLOR.blue, titleColor: COLOR.blue, fontSize: 16, subSize: 12.5 });
  // 下方：記錄的五類內容
  text(s, '主要記錄的內容', { x: M, y: y0 + 1.35, w: 6, h: 0.4, fontSize: 17, bold: true, color: COLOR.ink });
  const kinds = [
    { ic: 'cpu', t: '演算法', d: 'AES-256-GCM\nRSA-2048、SHA-256\n模式、填充、曲線' },
    { ic: 'key-round', t: '金鑰與密碼素材', d: '金鑰、salt、IV、token\n長度、狀態、到期日\n保管方式（HSM）' },
    { ic: 'network', t: '協定與 cipher suite', d: 'TLS 1.3、SSH、IPsec\n協定版本\n啟用的 cipher suite' },
    { ic: 'file-badge', t: '數位憑證', d: '主體、發行者\n有效期限\n簽章演算法' },
    { ic: 'library', t: '密碼學函式庫', d: 'BouncyCastle 等\n記成 library 元件\n用 provides 連到演算法' },
  ];
  const gap = 0.2, kw = (W - 2 * M - gap * 4) / 5, ky = y0 + 1.85, kh = 2.4;
  kinds.forEach((k, i) => {
    const x = M + i * (kw + gap);
    card(s, { x, y: ky, w: kw, h: kh });
    icon(s, k.ic, x + (kw - 0.7) / 2, ky + 0.2, 0.7, [COLOR.navy, COLOR.amber, COLOR.green, COLOR.red, COLOR.navy2][i]);
    text(s, k.t, { x: x + 0.15, y: ky + 1.0, w: kw - 0.3, h: 0.45, fontSize: 16, bold: true, color: COLOR.ink, align: 'center', valign: 'middle' });
    text(s, k.d, { x: x + 0.2, y: ky + 1.5, w: kw - 0.4, h: 0.85, fontSize: 12.5, color: COLOR.body, align: 'center' });
  });
  // CBOM 的範圍：不只第三方套件
  const by = ky + kh + 0.2, bh = 0.62;
  card(s, { x: M, y: by, w: W - 2 * M, h: bh, fill: COLOR.blueTint });
  icon(s, 'scan-search', M + 0.2, by + (bh - 0.42) / 2, 0.42, COLOR.navy);
  text(s, [
    { text: 'CBOM 不只看第三方套件：', options: { bold: true, color: COLOR.navy } },
    { text: '自己寫的程式碼、套件內部、設定檔與金鑰、執行環境、網路協定裡的密碼學都算', options: { color: COLOR.body } },
  ], { x: M + 0.8, y: by, w: W - 2 * M - 1.0, h: bh, fontSize: 14, valign: 'middle' });
  s.addNotes('SBOM 是套件清單，主要列第三方套件的名稱與版本，拿來查漏洞、管授權。CBOM 再往裡面看，記錄系統用了哪些密碼學、在哪裡、強度如何，而且不只看第三方套件：自己寫的程式碼、套件內部、設定檔裡的金鑰與憑證、執行環境的設定、網路協定開了哪些 cipher，都在 CBOM 的範圍裡。主要記錄五類內容：演算法；金鑰、salt、IV、token 這類密碼素材，包含長度、狀態、到期日與保管方式；協定與 cipher suite；數位憑證；以及密碼學函式庫。原稿把函式庫列成資產的一種，依 CycloneDX 規格，函式庫是一般的 library 元件，透過 dependencies 的 provides 欄位指出它提供了哪些演算法，不是 cryptographic-asset 的四種類型之一。');
}

function whyNow() {
  const s = contentSlide(S1, '為什麼現在要做', '三個目的，最急的是後量子密碼（PQC）遷移');
  const lw = 6.3;
  const goals = [
    { ic: 'atom', fill: COLOR.red, t: 'PQC 遷移', d: '找出會被量子電腦破解的公鑰演算法（RSA、ECC、DH），排定替換順序' },
    { ic: 'shield-alert', fill: COLOR.amber, t: '汰換已不安全的演算法', d: 'DES、3DES、MD5、SHA-1、RSA-1024、ECB 模式，現在就該換' },
    { ic: 'timer', fill: COLOR.green, t: '憑證與金鑰管理', d: '掌握憑證到期日、金鑰放在哪裡，避免過期中斷或外洩' },
  ];
  goals.forEach((g, i) => {
    const y = CONTENT_TOP + i * 1.25;
    icon(s, g.ic, M, y, 0.75, g.fill);
    text(s, g.t, { x: M + 1.0, y: y - 0.02, w: lw - 1.0, h: 0.42, fontSize: 18, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, g.d, { x: M + 1.0, y: y + 0.42, w: lw - 1.0, h: 0.65, fontSize: 13.5, color: COLOR.body });
  });
  card(s, { x: M, y: CONTENT_TOP + 3.85, w: lw, h: 1.0, fill: COLOR.blueTint });
  text(s, [
    { text: '密碼敏捷性（crypto agility）', options: { bold: true, color: COLOR.navy } },
    { text: '是「能快速換掉演算法」的能力。CBOM 讓你知道要換哪裡，是做到敏捷性的前提。', options: { color: COLOR.body } },
  ], { x: M + 0.25, y: CONTENT_TOP + 3.85, w: lw - 0.5, h: 1.0, fontSize: 13, valign: 'middle' });

  // 右側：時程
  const rx = M + lw + 0.6, rw = W - rx - M;
  text(s, '時程（NIST）', { x: rx, y: CONTENT_TOP, w: rw, h: 0.4, fontSize: 18, bold: true, color: COLOR.ink });
  const steps = [
    { year: '2024', t: 'PQC 標準發布', d: 'FIPS 203 ML-KEM、204 ML-DSA、205 SLH-DSA', fill: COLOR.green },
    { year: '現在', t: '先收集、日後解密', d: '今天的加密流量可能被存下來，等量子電腦成熟再解', fill: COLOR.red },
    { year: '2030', t: 'RSA／ECC／DH deprecated', d: '還能用但要評估風險，趁這段時間完成遷移（NIST IR 8547）', fill: COLOR.amber },
    { year: '2035', t: 'RSA／ECC／DH disallowed', d: '所有量子脆弱的公鑰演算法不得再使用（NIST IR 8547）', fill: COLOR.amber },
  ];
  steps.forEach((st, i) => {
    const y = CONTENT_TOP + 0.55 + i * 1.08;
    badge(s, st.year, rx, y, 0.85, st.fill, 15);
    if (i < steps.length - 1) arrow(s, rx + 0.425, y + 0.87, rx + 0.425, y + 1.06);
    text(s, st.t, { x: rx + 1.05, y: y + 0.02, w: rw - 1.05, h: 0.4, fontSize: 16, bold: true, color: COLOR.ink });
    text(s, st.d, { x: rx + 1.05, y: y + 0.43, w: rw - 1.05, h: 0.4, fontSize: 12.5, color: COLOR.muted });
  });
  s.addNotes('做 CBOM 有三個目的。最急的是 PQC 遷移：量子電腦會用 Shor 演算法破解 RSA、ECC、DH，攻擊者可以先收集今天的加密流量、日後再解密。NIST 在 2024 年 8 月發布三個 PQC 標準（FIPS 203、204、205）；NIST IR 8547 正式版（2026 年 10 月 27 日發布）的時程是：所有量子脆弱的公鑰演算法 2030 年後 deprecated、2035 年後 disallowed，不分金鑰長度（2024 年的草案原本只把 112 位元強度的排在 2030，正式版改成全部）。2030 到 2035 這段是留給風險較低、有舊系統包袱的應用；美國聯邦的高價值系統另有更早的期限。採用混合式（傳統加後量子）不在禁用的範圍內。第二是汰換已經不安全的演算法。第三是憑證與金鑰管理。原稿把「盤點弱演算法」寫成密碼敏捷性，修正一下：密碼敏捷性指的是能快速換掉演算法的能力，CBOM 是它的前提。');
}

function format() {
  const s = contentSlide(S1, 'CBOM 格式', 'CycloneDX 1.6 起原生支援 CBOM');
  // 左：重點表
  const lw = 6.2;
  table(s, ['項目', '內容'], [
    ['標準', 'OWASP CycloneDX（ECMA-424 國際標準）'],
    ['版本', '1.6 起支援密碼學；目前最新 1.7（2025-10）'],
    ['檔案格式', 'JSON、XML、Protocol Buffers'],
    ['新增元件類型', 'cryptographic-asset'],
    ['描述方式', 'cryptoProperties：類型、演算法、模式…'],
    ['SBOM＋CBOM', '可以放在同一份檔案（套件與密碼學一起）'],
  ], { x: M, y: CONTENT_TOP, w: lw, colW: [1.7, lw - 1.7], fontSize: 13.5, rowH: 0.55, firstColBold: true });

  // 右：一份 BOM 的結構
  const rx = M + lw + 0.5, rw = W - rx - M;
  node(s, { x: rx + rw / 2 - 1.3, y: CONTENT_TOP, w: 2.6, h: 0.6, title: 'BOM（一個 JSON 檔）', fill: COLOR.navy, line: COLOR.navy, titleColor: COLOR.white, fontSize: 14 });
  const cols = [
    { t: 'metadata', d: '時間、工具' },
    { t: 'components', d: '所有元件' },
    { t: 'dependencies', d: 'dependsOn／provides' },
  ];
  const cw = (rw - 0.3) / 3, cy = CONTENT_TOP + 1.15;
  s.addShape(pres.shapes.LINE, { x: rx + cw / 2, y: CONTENT_TOP + 0.88, w: rw - cw, h: 0, line: { color: '3A4A5C', width: 1.5 } });
  s.addShape(pres.shapes.LINE, { x: rx + rw / 2, y: CONTENT_TOP + 0.6, w: 0, h: 0.28, line: { color: '3A4A5C', width: 1.5 } });
  cols.forEach((c, i) => {
    const x = rx + i * (cw + 0.15);
    arrow(s, x + cw / 2, CONTENT_TOP + 0.88, x + cw / 2, cy - 0.02);
    node(s, { x, y: cy, w: cw, h: 0.95, title: c.t, sub: c.d, fill: i === 1 ? COLOR.blueTint : COLOR.tint, line: i === 1 ? COLOR.blue : COLOR.line, fontSize: 13.5, subSize: 11 });
  });
  const cx = rx + cw + 0.15;
  arrow(s, cx + cw / 2, cy + 0.97, cx + cw / 2, cy + 1.3);
  node(s, { x: rx, y: cy + 1.35, w: rw / 2 - 0.1, h: 1.1, title: 'library', sub: '一般套件（有 purl）\n→ 查 CVE', fill: COLOR.white, fontSize: 14, subSize: 11.5 });
  node(s, { x: rx + rw / 2 + 0.1, y: cy + 1.35, w: rw / 2 - 0.1, h: 1.1, title: 'cryptographic-asset', sub: 'cryptoProperties＋evidence\n→ 密碼學規則', fill: COLOR.amberTint, line: COLOR.amber, titleColor: COLOR.amberText, fontSize: 14, subSize: 11.5 });
  text(s, '依據：CycloneDX 1.6／1.7 官方 JSON schema', { x: rx, y: cy + 2.65, w: rw, h: 0.3, fontSize: 11, color: COLOR.muted });
  s.addNotes('CBOM 沒有另外的檔案格式，就是 OWASP CycloneDX，也是 Ecma 國際標準 ECMA-424。1.6 版開始原生支援密碼學，目前最新是 2025 年 10 月的 1.7，所以原稿寫「1.6 以上（含）」是對的。檔案可以是 JSON、XML 或 Protocol Buffers。1.6 新增 cryptographic-asset 這種元件，用 cryptoProperties 描述細節。右邊是一份 BOM 的結構：components 裡可以同時有一般套件（library，有 purl，拿來查 CVE）和密碼學資產，所以 SBOM 和 CBOM 可以放在同一份檔案。');
}

function example() {
  const s = contentSlide(S1, 'CBOM 範例', '一個演算法資產長什麼樣子');
  // CBOMkit 掃本專案、下載的 CBOM 裡的 MD5（省略部分欄位）；編號標在對應的那一行旁邊
  const lines = [
    '{',
    '  "bomFormat": "CycloneDX",',
    '  "specVersion": "1.6",',
    '  "components": [{',
    '    "type": "cryptographic-asset",',
    '    "name": "MD5",',
    '    "cryptoProperties": {',
    '      "assetType": "algorithm",',
    '      "algorithmProperties": {',
    '        "primitive": "hash",',
    '        "parameterSetIdentifier": "128",',
    '        "cryptoFunctions": ["digest"] } },',
    '    "evidence": { "occurrences": [',
    '      { "location": "src/…/HashingService.java",',
    '        "line": 93,',
    '        "additionalContext": "MessageDigest#getInstance" },',
    '      { "location": "src/…/HashingService.java", "line": 96 },',
    '      …（共 4 個位置）] }',
    '  }]',
    '}',
  ];
  const cx = M, cy = CONTENT_TOP, cw = 7.5, chh = 4.75, fs = 12.5;
  code(s, lines, { x: cx, y: cy, w: cw, h: chh, fontSize: fs });
  const LH = fs * 1.2 / 72;                    // 一行的高度（吋）
  const marks = [[4, COLOR.red], [6, COLOR.amber], [12, COLOR.green]];   // 第幾行（從 0 算）
  marks.forEach(([ln, c], i) => badge(s, i + 1, cx + cw - 0.6, cy + 0.2 + ln * LH + LH / 2 - 0.19, 0.38, c, 13));
  const rx = cx + cw + 0.45, rw = W - rx - M;
  const items = [
    { c: COLOR.red, t: '這是什麼', d: 'type＝cryptographic-asset\n（CycloneDX 1.6 新增的元件類型）\nname＝演算法名稱' },
    { c: COLOR.amber, t: '強度與用途', d: 'assetType＝algorithm、primitive＝hash\nparameterSetIdentifier＝128（輸出長度）\ncryptoFunctions＝digest' },
    { c: COLOR.green, t: '在哪裡', d: 'evidence：每個出現位置\n（檔案、行號、呼叫的 API）\n這筆 MD5 在 4 個地方用到' },
  ];
  items.forEach((it, i) => {
    const y = cy + i * 1.55;
    badge(s, i + 1, rx, y, 0.42, it.c, 14);
    text(s, it.t, { x: rx + 0.6, y: y - 0.02, w: rw - 0.6, h: 0.45, fontSize: 16, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, it.d, { x: rx + 0.6, y: y + 0.45, w: rw - 0.6, h: 1.0, fontSize: 12.5, color: COLOR.body });
  });
  text(s, 'CBOMkit 掃本專案、下載的 CBOM 裡的一筆（省略部分欄位）', { x: cx, y: cy + chh + 0.12, w: cw, h: 0.3, fontSize: 11, color: COLOR.muted });
  s.addNotes('這是用 CBOMkit 掃我們專案、下載下來的 CBOM 裡的一筆 MD5，分三塊看。第一塊是「這是什麼」：type 是 cryptographic-asset，這是 CycloneDX 1.6 新增的元件類型，name 是演算法名稱。第二塊是「強度與用途」：cryptoProperties 裡的 assetType 是 algorithm，primitive 是 hash，parameterSetIdentifier 128 是輸出長度，cryptoFunctions 是 digest。第三塊是「在哪裡」：evidence 記錄每個出現位置的檔案、行號和呼叫的 API，這筆 MD5 在 4 個地方用到。有位置，才知道要去哪裡改。原稿的 AES-256-GCM 範例也是同樣的結構，只是沒有 evidence。');
}

function assetTypes() {
  const s = contentSlide(S1, '資產類型', '四種 assetType 與主要欄位');
  const types = [
    { ic: 'cpu', fill: COLOR.navy, k: 'algorithm', t: '演算法', f: ['primitive：ae、hash、signature、kem…', 'mode（cbc、gcm…）、padding、curve', 'parameterSetIdentifier（例如金鑰長度）', 'nistQuantumSecurityLevel（量子安全等級）'] },
    { ic: 'file-badge', fill: COLOR.amber, k: 'certificate', t: '數位憑證', f: ['subjectName、issuerName', 'notValidBefore／notValidAfter（有效期限）', 'signatureAlgorithmRef（指向演算法資產）', 'certificateFormat（例如 X.509）'] },
    { ic: 'network', fill: COLOR.green, k: 'protocol', t: '通訊協定', f: ['type：tls、ssh、ipsec、ike、sstp、wpa', 'version（例如 1.3）', 'cipherSuites（每個 suite 指向演算法）', 'ikev2TransformTypes（IPsec）'] },
    { ic: 'key-round', fill: COLOR.red, k: 'related-crypto-material', t: '相關密碼素材', f: ['type：private-key、secret-key、salt、IV、token…', 'state：active、compromised、destroyed…', 'size、creationDate、expirationDate', 'securedBy：保管方式（HSM、TPM、Software）'] },
  ];
  const gap = 0.3, cw = (W - 2 * M - gap) / 2, ch = 2.35;
  types.forEach((t, i) => {
    const x = M + (i % 2) * (cw + gap), y = CONTENT_TOP + Math.floor(i / 2) * (ch + 0.25);
    card(s, { x, y, w: cw, h: ch });
    icon(s, t.ic, x + 0.25, y + 0.25, 0.65, t.fill);
    text(s, [{ text: t.k, options: { bold: true, color: COLOR.ink } }, { text: `  ${t.t}`, options: { color: COLOR.muted } }],
      { x: x + 1.1, y: y + 0.25, w: cw - 1.3, h: 0.65, fontSize: 17, valign: 'middle' });
    text(s, t.f.map((f, j) => ({ text: f, options: { bullet: true, breakLine: j < t.f.length - 1 } })),
      { x: x + 1.1, y: y + 0.95, w: cw - 1.3, h: ch - 1.05, fontSize: 12.5, color: COLOR.body, paraSpaceAfter: 3 });
  });
  text(s, '欄位名稱依 CycloneDX 1.6 JSON schema；1.7 另外增加憑證狀態、指紋與更多協定（dtls、quic…）',
    { x: M, y: CONTENT_TOP + 2 * ch + 0.35, w: W - 2 * M, h: 0.3, fontSize: 11, color: COLOR.muted });
  s.addNotes('assetType 只有四種：algorithm、certificate、protocol、related-crypto-material。這頁的欄位名稱都對照過官方 JSON schema。和原稿相比的修正：演算法的「原語」欄位叫 primitive，值是 ae、hash、signature、kem 這類；憑證欄位是 subjectName、issuerName、notValidBefore／After，簽章演算法用參照指向另一個演算法資產；協定的 type 是 tls、ssh、ipsec、ike、sstp、wpa；密碼素材的 type 包含金鑰、salt、IV、token，state 記錄生命週期，原稿說的「儲存位置」對應的是 securedBy，記錄保管機制（HSM、TPM 等），不是檔案位置；檔案位置記在每個元件的 evidence。');
}

// ---------------- PART 02：CBOMkit 平台 ----------------
function cbomkitFamily() {
  const s = contentSlide(S2, 'CBOMkit 平台', 'CBOMkit：掃描、檢視、檢查 CBOM 的開源平台');
  const lw = 8.3;
  card(s, { x: M, y: CONTENT_TOP, w: lw, h: 4.6, fill: COLOR.blueTint, line: COLOR.blue });
  icon(s, 'server', M + 0.25, CONTENT_TOP + 0.2, 0.55, COLOR.navy);
  text(s, 'CBOMkit 平台（容器部署，網頁＋API）', { x: M + 0.95, y: CONTENT_TOP + 0.2, w: lw - 1.2, h: 0.55, fontSize: 16, bold: true, color: COLOR.navy, valign: 'middle' });
  const pw = (lw - 0.5 - 0.3) / 3, py = CONTENT_TOP + 0.95, ph = 2.9;
  [
    { ic: 'scan-search', fill: COLOR.red, t: '掃描', sub: 'hyperion', d: '貼上 git 網址，平台 clone 原始碼、分析，產生 CBOM' },
    { ic: 'eye', fill: COLOR.amber, t: '檢視', sub: 'coeus', d: '總覽圖表、資產清單、每個資產的位置與細節；也可以上傳 CBOM 來看' },
    { ic: 'scale', fill: COLOR.green, t: '合規檢查', sub: 'quantum-safe（概念驗證）', d: '內建規則判斷量子安全；也可以改接 OPA，用自己的規則' },
  ].forEach((p, i) => {
    const x = M + 0.25 + i * (pw + 0.15);
    card(s, { x, y: py, w: pw, h: ph, fill: COLOR.white, line: COLOR.line });
    icon(s, p.ic, x + (pw - 0.65) / 2, py + 0.25, 0.65, p.fill);
    text(s, p.t, { x, y: py + 1.0, w: pw, h: 0.4, fontSize: 16, bold: true, color: COLOR.ink, align: 'center', valign: 'middle' });
    text(s, p.sub, { x, y: py + 1.4, w: pw, h: 0.3, fontSize: 11.5, color: COLOR.muted, align: 'center' });
    text(s, p.d, { x: x + 0.2, y: py + 1.8, w: pw - 0.4, h: 1.0, fontSize: 12, color: COLOR.body, align: 'center' });
  });
  text(s, '同一個專案還有 CBOMkit-theia（掃目錄與映像裡的憑證、金鑰）與 CBOMkit-action（放進 pipeline 掃），不在網頁平台裡', { x: M + 0.25, y: CONTENT_TOP + 4.0, w: lw - 0.5, h: 0.4, fontSize: 11.5, color: COLOR.muted });
  const rx = M + lw + 0.4, rw = W - rx - M;
  text(s, '原始碼掃描支援的語言', { x: rx, y: CONTENT_TOP, w: rw, h: 0.4, fontSize: 15, bold: true, color: COLOR.ink });
  table(s, ['語言', '函式庫'], [
    ['Java', 'JCA、BouncyCastle（light-weight API）'],
    ['Python', 'pyca/cryptography'],
    ['Go', '標準函式庫 crypto'],
    ['C#', '開發中（尚不建議正式使用）'],
  ], { x: rx, y: CONTENT_TOP + 0.5, w: rw, colW: [0.9, rw - 0.9], fontSize: 12.5, rowH: 0.5, firstColBold: true });
  text(s, '維護：Linux Foundation PQCA\n（後量子密碼聯盟）\n原由 IBM Research 開發', { x: rx, y: CONTENT_TOP + 3.25, w: rw, h: 0.9, fontSize: 12, color: COLOR.muted });
  s.addNotes('原稿寫「IBM CBOMkit」，現在 CBOMkit 由 Linux Foundation 底下的 PQCA（後量子密碼聯盟）維護，原本是 IBM Research 開發的（網頁左上角仍顯示 IBM Research）。平台有三個部分：掃描、檢視、合規檢查，後面三個部分就依這個順序介紹。掃描引擎是 sonar-cryptography。原始碼掃描支援 Java、Python、Go，C# 還在開發中。');
}

function architecture() {
  const s = contentSlide(S2, '架構', 'CBOMkit 的架構：前端、API 伺服器、資料庫');
  const top = CONTENT_TOP + 0.05;
  // 左：使用者 → 網頁前端
  const ux = M, uw = 1.55, uy = top + 1.45, uh = 1.4;
  card(s, { x: ux, y: uy, w: uw, h: uh, fill: COLOR.white, line: COLOR.line });
  icon(s, 'user', ux + (uw - 0.6) / 2, uy + 0.15, 0.6, COLOR.muted);
  text(s, '使用者\n（瀏覽器）', { x: ux, y: uy + 0.8, w: uw, h: 0.55, fontSize: 12.5, color: COLOR.body, align: 'center' });

  const fx = ux + uw + 0.6, fw = 2.6, fy = top + 0.95, fh = 2.4;
  card(s, { x: fx, y: fy, w: fw, h: fh, fill: COLOR.blueTint, line: COLOR.blue });
  icon(s, 'monitor', fx + 0.2, fy + 0.2, 0.55, COLOR.navy);
  text(s, '網頁前端', { x: fx + 0.85, y: fy + 0.2, w: fw - 0.95, h: 0.55, fontSize: 16, bold: true, color: COLOR.navy, valign: 'middle' });
  text(s, [
    { text: '瀏覽已存的 CBOM', options: { bullet: true, breakLine: true } },
    { text: '發起掃描', options: { bullet: true, breakLine: true } },
    { text: '上傳 CBOM 來看', options: { bullet: true } },
  ], { x: fx + 0.2, y: fy + 0.9, w: fw - 0.4, h: 1.0, fontSize: 12.5, color: COLOR.body, paraSpaceAfter: 2 });
  text(s, '可單獨部署成檢視器（coeus）', { x: fx + 0.2, y: fy + 1.9, w: fw - 0.4, h: 0.4, fontSize: 11, color: COLOR.muted });
  arrow(s, ux + uw + 0.05, uy + uh / 2, fx - 0.05, uy + uh / 2);

  // 中：API 伺服器（核心）
  const ax = fx + fw + 1.25, aw = 3.3, ay = top, ah = 4.55;
  card(s, { x: ax, y: ay, w: aw, h: ah, fill: COLOR.navy });
  s.addImage({ data: iconPng('server', COLOR.white), x: ax + 0.25, y: ay + 0.22, w: 0.5, h: 0.5, altText: 'API 伺服器' });
  text(s, 'API 伺服器（核心）', { x: ax + 0.9, y: ay + 0.2, w: aw - 1.0, h: 0.55, fontSize: 16, bold: true, color: COLOR.white, valign: 'middle' });
  const inner = [
    { t: 'REST API／WebSocket', d: '查詢、上傳、合規檢查\n掃描進度即時回報' },
    { t: '掃描（hyperion）', d: 'clone git repo\n用 sonar-cryptography 分析' },
    { t: '合規檢查', d: '內建 quantum_safe\n或轉給外部 OPA' },
  ];
  inner.forEach((n, i) => node(s, { x: ax + 0.25, y: ay + 0.95 + i * 1.18, w: aw - 0.5, h: 1.05, title: n.t, sub: n.d, fill: COLOR.white, line: COLOR.white, fontSize: 13.5, subSize: 11 }));
  // 前端 ⇄ API
  const midY = fy + fh / 2;
  arrow(s, fx + fw + 0.05, midY - 0.3, ax - 0.05, midY - 0.3, 'REST API');
  arrow(s, ax - 0.05, midY + 0.35, fx + fw + 0.05, midY + 0.35);
  text(s, 'WebSocket\n（掃描進度）', { x: fx + fw, y: midY + 0.45, w: ax - fx - fw, h: 0.55, fontSize: 11, color: COLOR.muted, align: 'center' });

  // 右：git repo、資料庫、OPA（選用）
  const rx = ax + aw + 0.7, rw = W - rx - M, rh = 1.2;
  const right = [
    { ic: 'git-branch', fill: COLOR.amber, t: 'git repo', d: '掃描時 clone\n（帳密不會儲存）', y: ay + 0.2, label: 'clone' },
    { ic: 'database', fill: COLOR.green, t: '資料庫', d: 'PostgreSQL\n儲存每次的 CBOM', y: ay + 1.7, label: '存取' },
    { ic: 'scale', fill: COLOR.red, t: 'OPA（選用）', d: '外部合規檢查\n（ext-compliance）', y: ay + 3.2, label: '' },
  ];
  right.forEach((r, i) => {
    const dashed = i === 2;
    s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: rx, y: r.y, w: rw, h: rh, rectRadius: 0.12, fill: { color: COLOR.white }, line: { color: dashed ? COLOR.red : COLOR.line, width: 1.25, dashType: dashed ? 'dash' : 'solid' } });
    icon(s, r.ic, rx + 0.15, r.y + 0.15, 0.45, r.fill);
    text(s, r.t, { x: rx + 0.7, y: r.y + 0.12, w: rw - 0.8, h: 0.45, fontSize: 13.5, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, r.d, { x: rx + 0.15, y: r.y + 0.62, w: rw - 0.25, h: 0.55, fontSize: 10.5, color: COLOR.body });
    const yy = r.y + rh / 2;
    if (dashed) {
      s.addShape(pres.shapes.LINE, { x: ax + aw + 0.05, y: yy, w: rx - ax - aw - 0.1, h: 0, line: { color: COLOR.red, width: 1.5, dashType: 'dash', endArrowType: 'triangle' } });
    } else {
      arrow(s, ax + aw + 0.05, yy, rx - 0.05, yy, r.label);
    }
  });
  text(s, '依據：CBOMkit 官方 README 的 Architecture；lab 實際執行的容器：cbomkit-frontend 與 cbomkit（API）2.3.0、PostgreSQL 16',
    { x: M, y: top + ah + 0.25, w: W - 2 * M, h: 0.35, fontSize: 11, color: COLOR.muted });
  s.addNotes('CBOMkit 的架構很簡單，官方說明就是三個元件：網頁前端、API 伺服器、資料庫。使用者在瀏覽器操作前端，前端可以瀏覽已存的 CBOM、發起掃描、上傳 CBOM；只想看 CBOM 的話，前端也可以單獨部署成檢視器 coeus。前端透過 REST API 和 API 伺服器溝通，掃描時另外開一條 WebSocket，即時回報掃描進度。API 伺服器是核心：掃描時它去 clone git repo，用 sonar-cryptography 分析產生 CBOM，存進 PostgreSQL 資料庫；合規檢查也在這裡做，預設用內建的 quantum_safe，設定之後可以改轉給外部的 OPA，這就是後面第 5 部分會講的。');
}

// ---------------- PART 03：怎麼掃描 ----------------
function scanSteps() {
  const s = contentSlide(S3, '掃描', '貼上 git 網址，按 Scan');
  const iw = 7.2;
  img(s, 'cbomkit-generate.png', { x: M, y: CONTENT_TOP, w: iw, h: 4.6 }, 'CBOMkit 首頁的 Generate a new CBOM 區塊：輸入 git 網址、Advanced options 的分支與子目錄');
  const rx = M + iw + 0.45, rw = W - rx - M;
  const steps = [
    ['貼上網址', 'git 網址（http/https）或 Package URL（purl）'],
    ['Advanced options（選填）', 'Scan：分支、只掃某個子目錄\nAuthentication：私有 repo 的帳密或 token'],
    ['按 Scan', '平台 clone 原始碼，用 sonar-cryptography\n分析（不會先 build）'],
    ['看結果', '出現 Scan finished，下方是總覽與清單'],
  ];
  steps.forEach(([t, d], i) => {
    const y = CONTENT_TOP + i * 1.18;
    badge(s, i + 1, rx, y, 0.5, BRAND[i], 16);
    text(s, t, { x: rx + 0.7, y: y - 0.02, w: rw - 0.7, h: 0.4, fontSize: 15, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, d, { x: rx + 0.7, y: y + 0.38, w: rw - 0.7, h: 0.7, fontSize: 12, color: COLOR.body });
  });
  text(s, '平台要連得到這個 git 網址：本機或內網的 repo，要先放到平台連得到的 git 伺服器。（本簡報的截圖拍攝於 2026-11-10 的 lab）',{ x: M, y: CONTENT_TOP + 4.75, w: W - 2 * M, h: 0.35, fontSize: 11.5, color: COLOR.muted });
  s.addNotes('掃描只要三步：貼上 git 網址、需要的話打開 Advanced options 指定分支或子目錄、按 Scan。私有 repo 在 Authentication 分頁填帳密或 token，官方說明這些資訊只用來 clone，不會儲存或記錄。注意平台只接受 http 或 https 的 git 網址，而且不會先 build，官方提醒 Java 有些型別可能解析不到，結果會比較不完整。我們的 repo 在本機，所以 lab 先用一支腳本把 main 分支放到臨時的 http git 伺服器，平台才連得到。');
}

function scanResult() {
  const s = contentSlide(S3, '掃描結果', `約 ${DATA.scan.totalSeconds} 秒完成，同一份結果有兩個數字`);
  const S = DATA.scan;
  const stats = [
    { ic: 'map-pin', big: String(S.occurrences), label: '個出現位置\n（網頁上的 cryptographic assets found）', fill: COLOR.navy },
    { ic: 'file-json', big: String(S.assets), label: '個密碼學資產\n（下載的 CBOM 裡的元件數）', fill: COLOR.green },
    { ic: 'file-code', big: `${S.files} 個檔`, label: `${S.lines} 行程式碼`, fill: COLOR.amber },
    { ic: 'timer', big: `${S.scanSeconds} 秒`, label: `掃描本身\n（含 clone 共 ${S.totalSeconds} 秒）`, fill: COLOR.red },
  ];
  const cw = (W - 2 * M - 0.9) / 4;
  stats.forEach((st, i) => {
    const x = M + i * (cw + 0.3);
    card(s, { x, y: CONTENT_TOP, w: cw, h: 2.55 });
    icon(s, st.ic, x + (cw - 0.65) / 2, CONTENT_TOP + 0.2, 0.65, st.fill);
    text(s, st.big, { x, y: CONTENT_TOP + 0.95, w: cw, h: 0.75, fontSize: 32, bold: true, color: st.fill, align: 'center', valign: 'middle' });
    text(s, st.label, { x: x + 0.15, y: CONTENT_TOP + 1.72, w: cw - 0.3, h: 0.75, fontSize: 12.5, color: COLOR.body, align: 'center' });
  });
  const by = CONTENT_TOP + 2.85;
  card(s, { x: M, y: by, w: W - 2 * M, h: 1.75, fill: COLOR.blueTint });
  icon(s, 'info', M + 0.3, by + 0.3, 0.55, COLOR.navy);
  text(s, `${S.occurrences} 和 ${S.assets} 為什麼不一樣`, { x: M + 1.05, y: by + 0.25, w: W - 2 * M - 1.3, h: 0.5, fontSize: 16, bold: true, color: COLOR.navy, valign: 'middle' });
  text(s, `網頁把同一個演算法在不同位置的每次出現都算一筆（例如 SHA-1 在 4 個地方用到就是 4 筆）；下載的 CBOM 把同一個演算法合成一個元件，位置記在 evidence 裡。結果上方也會列出 gitUrl、分支與 commit，方便追溯。秒數是這個小專案（${S.files} 個檔）的結果，不能直接外推到大專案。`,
    { x: M + 1.05, y: by + 0.75, w: W - 2 * M - 1.3, h: 0.9, fontSize: 13, color: COLOR.body });
  s.addNotes(`掃描這個專案約 ${S.totalSeconds} 秒完成（三次實測，掃描本身 ${S.scanSeconds} 秒，其餘是 clone）。要注意網頁上的 ${S.occurrences} 是出現次數，同一個演算法在不同位置各算一次；下載的 CBOM 是 ${S.assets} 個元件，同一個演算法只有一個元件，位置都記在 evidence。和別人比數字時要講清楚是哪一個。`);
}

// ---------------- PART 04：怎麼看結果 ----------------
function overview() {
  const s = contentSlide(S4, '總覽', '一眼看懂：合規狀態與四張圖');
  const box = { x: M, y: CONTENT_TOP - 0.05, w: 8.4, h: 4.75 };
  const r = img(s, 'cbomkit-overview.png', box, 'CBOMkit 掃描結果總覽：合規橫幅與四張圖（合規比例、資產種類、原語、用途）');
  // 編號標在圖上（位置是相對圖片的比例，對照截圖調整）
  DATA.overviewCallouts.forEach(([fx, fy], i) => badge(s, i + 1, r.x + r.w * fx - 0.2, r.y + r.h * fy - 0.2, 0.4, COLOR.red, 13));
  const rx = M + 8.9, rw = W - rx - M;
  const items = [
    ['合規橫幅', '這份 CBOM 是否符合 quantum_safe；下方寫是哪個合規服務算的'],
    ['合規比例', `四種結果的比例；用 ${DATA.scan.occurrences} 個出現位置算，不是 ${DATA.scan.assets} 個資產`],
    ['資產種類', '每個泡泡是一種資產，越大出現越多'],
    ['原語（primitive）', 'hash、pke、block-cipher、mac…'],
    ['用途（function）', 'digest、keygen、encrypt、sign…'],
  ];
  items.forEach(([t, d], i) => {
    const y = CONTENT_TOP + i * 0.98;
    badge(s, i + 1, rx, y, 0.4, COLOR.red, 13);
    text(s, t, { x: rx + 0.55, y: y - 0.04, w: rw - 0.55, h: 0.4, fontSize: 14, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, d, { x: rx + 0.55, y: y + 0.36, w: rw - 0.55, h: 0.55, fontSize: 11.5, color: COLOR.body });
  });
  const O = DATA.overview;
  s.addNotes(`掃完後最上面是總覽。橫幅說這份 CBOM 不符合 quantum_safe，下面一行寫是哪個合規服務算的，內建的是 Basic Backend Compliance Service。第一張圓環是合規比例：這次 Not Applicable ${O.na}%、Unknown ${O.unknown}%、Not Quantum Safe ${O.nqs}%，沒有 Quantum Safe。泡泡圖是 ${O.types} 種資產；後兩張是 ${O.primitives} 種原語和 ${O.functions} 種用途。比例是用出現次數（${DATA.scan.occurrences}）算的。`);
}

function assetList() {
  const s = contentSlide(S4, '資產清單', '每一列是一個出現位置，點 ↗ 看細節');
  const iw = 7.6;
  img(s, 'cbomkit-list.png', { x: M, y: CONTENT_TOP, w: iw, h: 4.7 }, 'CBOMkit 的 List of all assets：資產名稱、類型、原語、位置，以及 Download CBOM 按鈕');
  const rx = M + iw + 0.45, rw = W - rx - M;
  const items = [
    { ic: 'shield-question', fill: COLOR.navy, t: '開頭的圖示＝合規分類', d: '滑過去會顯示原因，例如 SHA-1：Not Applicable' },
    { ic: 'table', fill: COLOR.green, t: '名稱、類型、原語', d: '例如 Algorithm、Hash Function\n每頁可選 10–100 筆' },
    { ic: 'map-pin', fill: COLOR.amber, t: 'Location＝檔名:行號', d: '要連到原始碼，得先指定 commit 或分支' },
    { ic: 'download', fill: COLOR.red, t: 'Download CBOM', d: '把這次結果存成 CycloneDX JSON' },
  ];
  items.forEach((it, i) => {
    const y = CONTENT_TOP + i * 1.18;
    icon(s, it.ic, rx, y, 0.55, it.fill);
    text(s, it.t, { x: rx + 0.75, y: y - 0.04, w: rw - 0.75, h: 0.4, fontSize: 14, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, it.d, { x: rx + 0.75, y: y + 0.36, w: rw - 0.75, h: 0.7, fontSize: 12, color: COLOR.body });
  });
  s.addNotes('總覽下面是資產清單，每一列是一個出現位置。最前面的圖示代表合規分類，滑過去會顯示原因。Location 是檔名和行號；要點過去看原始碼，得先用清單右上角的設定指定 commit 或分支，而且瀏覽器要連得到那個 repo。右上角的 Download CBOM 可以把這次的結果存成 CycloneDX 檔。');
}

function details() {
  const s = contentSlide(S4, '資產細節', '細節頁：程式位置、合規原因、原始欄位');
  // 細節對話框分成三段：Code（程式片段）、Compliance（分類與原因）、Specification（原始欄位）；這裡放大 Compliance
  const iw = 7.3, ih = 2.25, rx = M + iw + 0.45, rw = W - rx - M;
  const shots = [
    ['cbomkit-detail-sha1-compliance.png', 'SHA-1：Not Applicable', '「對稱原語，量子安全分類不適用」\n（為什麼已被破解的 SHA-1 沒被標出來，第 5 部分說明）', COLOR.amber],
    ['cbomkit-detail-ecdh-compliance.png', 'ECDH：Not Quantum Safe', '「非對稱原語，而且不在量子安全的白名單裡」', COLOR.red],
  ];
  shots.forEach(([f, t, d, c], i) => {
    const y = CONTENT_TOP + i * (ih + 0.25);
    img(s, f, { x: M, y, w: iw, h: ih }, `CBOMkit 資產細節的 Compliance 區塊：${t}`);
    chip(s, t, rx, y + 0.1, rw, c, COLOR.white, 0.45, 14);
    text(s, d, { x: rx, y: y + 0.7, w: rw, h: 1.2, fontSize: 13, color: COLOR.body });
  });
  text(s, '細節頁另外兩段：Code（指定分支或 commit、且瀏覽器連得到 repo 時顯示程式片段）、Specification（CBOM 裡的原始欄位）',
    { x: M, y: CONTENT_TOP + 2 * ih + 0.4, w: W - 2 * M, h: 0.4, fontSize: 11.5, color: COLOR.muted });
  s.addNotes('點清單右邊的箭頭打開細節。上面是 Code，指定分支或 commit 而且瀏覽器連得到 repo 時，會顯示程式片段；我們的 repo 在 lab 內網，所以這裡只顯示提示。中間的 Compliance 是分類與原因：SHA-1 是 Not Applicable，因為它是對稱原語；ECDH 是 Not Quantum Safe，因為它是非對稱、而且不在量子安全白名單裡。重點：SHA-1 其實已經被破解了，但內建檢查只看量子安全，不會標出來。最下面的 Specification 是這筆資產在 CBOM 裡的原始欄位。');
}

function downloadUpload() {
  const s = contentSlide(S4, '下載與上傳', '結果可以下載保存，也能上傳回來看');
  const y = CONTENT_TOP + 0.2, h = 1.5;
  node(s, { x: M, y, w: 3.2, h, title: 'CBOMkit 掃描結果', sub: '網頁上的總覽與清單', fill: COLOR.blueTint, line: COLOR.blue, fontSize: 15 });
  arrow(s, M + 3.25, y + h / 2, M + 4.45, y + h / 2, 'Download CBOM');
  node(s, { x: M + 4.5, y, w: 3.4, h, title: 'cbom.json', sub: `平台輸出 CycloneDX 1.6\n${DATA.scan.assets} 個密碼學資產`, fill: COLOR.tint, fontSize: 15 });
  arrow(s, M + 7.95, y + h / 2, M + 9.05, y + h / 2, '存檔、分享');
  node(s, { x: M + 9.1, y, w: W - 2 * M - 9.1, h, title: '其他工具／版本控制', sub: '比對、保存歷史', fill: COLOR.white, fontSize: 15 });
  const y2 = y + h + 0.6;
  node(s, { x: M, y: y2, w: 3.2, h, title: '之前下載或別人給的 CBOM', sub: 'CycloneDX 1.6 或 1.7 的 JSON', fill: COLOR.tint, fontSize: 15 });
  arrow(s, M + 3.25, y2 + h / 2, M + 4.45, y2 + h / 2, 'Upload a CBOM');
  node(s, { x: M + 4.5, y: y2, w: 3.4, h, title: '同樣的總覽與清單', sub: '拖進首頁的上傳區即可', fill: COLOR.blueTint, line: COLOR.blue, fontSize: 15 });
  card(s, { x: M + 8.25, y: y2, w: W - 2 * M - 8.25, h, fill: COLOR.amberTint });
  icon(s, 'triangle-alert', M + 8.45, y2 + 0.2, 0.5, COLOR.amber);
  text(s, '混了沒有 cryptoProperties 的一般套件時，內建檢查會出錯（實測 HTTP 500）；接 OPA 的不會。保險起見上傳前只留密碼學資產',
    { x: M + 9.1, y: y2 + 0.12, w: W - 2 * M - 9.3, h: h - 0.24, fontSize: 12, color: COLOR.body, valign: 'middle' });
  s.addNotes(`結果可以下載成 CycloneDX 檔，這次是 ${DATA.scan.assets} 個密碼學資產，可以存檔或交給別的工具。反過來，之前下載的、或別人給的 CBOM 檔，也可以拖進首頁的 Upload a CBOM，用同樣的畫面看。1.6 和 1.7 的檔都收（實測）。要注意：混了一般套件元件時，內建的合規檢查會回 HTTP 500，接 OPA 的那一組不會；保險起見上傳前只留密碼學資產。`);
}

// ---------------- PART 05：合規檢查與 OPA ----------------
function builtinCheck() {
  const s = contentSlide(S5, '內建合規檢查', '內建的 quantum_safe：一套寫死的規則');
  const lw = 7.6;
  table(s, ['依序判斷（第一個符合的決定）', '結果'], [
    [`沒有演算法屬性（憑證、金鑰、協定）；這次 42 個裡 ${DATA.unknownMaterial} 個是程式裡的金鑰與 salt`, 'Unknown'],
    ['CBOM 寫了 nistQuantumSecurityLevel > 0', 'Quantum Safe'],
    ['OID 在 18 個後量子 OID 白名單，或名稱含 ml-kem／ml-dsa／slh-dsa', 'Quantum Safe'],
    ['非對稱原語（signature、key-agree、kem、pke）', 'Not Quantum Safe'],
    ['原語不明', 'Unknown'],
    ['其他（對稱加密、雜湊、MAC…）', 'Not Applicable'],
  ], { x: M, y: CONTENT_TOP, w: lw, colW: [5.4, lw - 5.4], fontSize: 12.5, rowH: 0.58 });
  text(s, '依據：CBOMkit 2.3.0 實測與官方 README（「checks the quantum safety of asymmetric algorithms」）', { x: M, y: CONTENT_TOP + 4.2, w: lw, h: 0.4, fontSize: 11, color: COLOR.muted });
  const rx = M + lw + 0.45, rw = W - rx - M;
  card(s, { x: rx, y: CONTENT_TOP, w: rw, h: 4.55, fill: COLOR.redTint });
  icon(s, 'eye-off', rx + 0.3, CONTENT_TOP + 0.3, 0.6, COLOR.red);
  text(s, '盲點', { x: rx + 1.1, y: CONTENT_TOP + 0.3, w: rw - 1.3, h: 0.6, fontSize: 18, bold: true, color: COLOR.red, valign: 'middle' });
  text(s, [
    { text: '只判斷「量子安全」', options: { bold: true, breakLine: true } },
    { text: 'MD5、SHA-1、DES、ECB 這些已經被破解或不安全的，都是 Not Applicable，不會被標出來', options: { breakLine: true } },
    { text: ' ', options: { breakLine: true } },
    { text: '規則不能改', options: { bold: true, breakLine: true } },
    { text: '公司要加「金鑰長度」「內部禁用清單」，內建檢查做不到', options: {} },
  ], { x: rx + 0.3, y: CONTENT_TOP + 1.1, w: rw - 0.6, h: 3.3, fontSize: 13, color: COLOR.body });
  s.addNotes(`平台內建的檢查叫 quantum_safe，官方說明把它定位成概念驗證，是一套寫死的規則，不需要設定，也不能改。它依序判斷：沒有演算法屬性的是 Unknown；有寫量子安全等級、或在後量子白名單裡的是 Quantum Safe；非對稱的是 Not Quantum Safe；其他對稱加密、雜湊一律 Not Applicable。這次有一半的資產是 Unknown，不是掃描失敗：其中 ${DATA.unknownMaterial} 個是程式裡產生的金鑰與 salt，它們本身沒有演算法屬性，規則無從判斷；接 OPA 之後這一類也還是 Unknown。盲點有兩個：它只看量子安全，所以已經被破解的 MD5、SHA-1、DES 都不會被標出來；而且規則不能改。要解決這兩點，就要換成自己的規則，也就是下一頁的 OPA。`);
}

function whatIsOpa() {
  const s = contentSlide(S5, 'OPA 是什麼', 'Open Policy Agent：把「判斷規則」從程式裡拿出來');
  // 上方：運作方式
  const y = CONTENT_TOP + 0.05, h = 1.15;
  node(s, { x: M, y, w: 3.0, h, title: '應用程式', sub: '例如 CBOMkit', fill: COLOR.blueTint, line: COLOR.blue, fontSize: 15 });
  arrow(s, M + 3.05, y + h / 2, M + 4.55, y + h / 2, 'input（JSON）');
  node(s, { x: M + 4.6, y, w: 3.6, h, title: 'OPA', sub: '用 Rego 寫的規則', fill: COLOR.navy, line: COLOR.navy, titleColor: COLOR.white, subColor: 'C9D4E5', fontSize: 17 });
  arrow(s, M + 8.25, y + h / 2, M + 9.75, y + h / 2, '判定結果（JSON）');
  node(s, { x: M + 9.8, y, w: W - 2 * M - 9.8, h, title: '應用程式照結果做', sub: '顯示分類、擋下…', fill: COLOR.blueTint, line: COLOR.blue, fontSize: 14 });
  // 下方：三張卡
  const cards = [
    { ic: 'scale', fill: COLOR.navy, t: '是什麼', lines: ['開源、通用的 policy 引擎', '規則用 Rego 寫（宣告式語言）', '「決策」和「執行」分開：程式不寫死規則，問 OPA 再照做'] },
    { ic: 'circle-help', fill: COLOR.amber, t: '為什麼需要', lines: ['內建規則不能改；公司規則（已破解、金鑰長度、禁用清單）要自己定', '規則獨立成檔：可測試（opa test）、可審查、可版本控制', '同一份規則可以給多個系統用'] },
    { ic: 'badge-check', fill: COLOR.green, t: '是不是業界標準', lines: ['CNCF 畢業專案（2021-01-29），和 Kubernetes 同一等級', 'Kubernetes Gatekeeper、Envoy、Terraform、CI/CD 都在用', 'policy as code 的事實標準；但不是 ISO／NIST 那種正式標準'] },
  ];
  const gap = 0.3, cw = (W - 2 * M - 2 * gap) / 3, cy = CONTENT_TOP + 1.55, ch = 3.25;
  cards.forEach((c, i) => {
    const x = M + i * (cw + gap);
    card(s, { x, y: cy, w: cw, h: ch });
    icon(s, c.ic, x + 0.25, cy + 0.25, 0.6, c.fill);
    text(s, c.t, { x: x + 1.0, y: cy + 0.25, w: cw - 1.2, h: 0.6, fontSize: 17, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, c.lines.map((l, j) => ({ text: l, options: { bullet: true, breakLine: j < c.lines.length - 1 } })),
      { x: x + 0.25, y: cy + 1.0, w: cw - 0.5, h: ch - 1.15, fontSize: 12.5, color: COLOR.body, paraSpaceAfter: 6 });
  });
  s.addNotes('OPA，Open Policy Agent，是開源、通用的 policy 引擎，規則用一種叫 Rego 的宣告式語言寫。核心概念是把「決策」和「執行」分開：應用程式不把規則寫死，而是把資料用 JSON 送給 OPA，OPA 依規則回傳判定結果，應用程式再照結果做事。為什麼需要：CBOMkit 內建的規則不能改，而公司通常有自己的規則，例如已被破解的演算法、金鑰長度、內部禁用清單；規則獨立成檔也可以寫測試、做 code review、版本控制。是不是業界標準：OPA 是 CNCF 的畢業專案，2021 年 1 月畢業，和 Kubernetes 同一個成熟度等級，Kubernetes 的 Gatekeeper、Envoy、Terraform、CI/CD 都廣泛使用，可以說是 policy as code 的事實標準；但它不是 ISO 或 NIST 那種由標準組織制定的正式標準。');
}

function opaHow() {
  const s = contentSlide(S5, 'CBOMkit 接 OPA', '設定一個網址，合規檢查就改用自己的 Rego');
  const lw = 5.3;
  node(s, { x: M, y: CONTENT_TOP, w: lw, h: 0.95, title: 'CBOMkit API', sub: '設定 CBOMKIT_OPA_API_BASE＝OPA 網址', fill: COLOR.blueTint, line: COLOR.blue, fontSize: 15, subSize: 12 });
  arrow(s, M + lw / 2, CONTENT_TOP + 1.0, M + lw / 2, CONTENT_TOP + 1.45, '送出整份 CBOM');
  node(s, { x: M, y: CONTENT_TOP + 1.5, w: lw, h: 1.15, title: 'OPA：policies.quantum_safe', sub: '每個資產回傳一筆 finding（rule、result、bom-ref）\nresult 只能是 quantum-safe／quantum-vulnerable\n／na／unknown', fill: COLOR.white, fontSize: 15, subSize: 11.5 });
  text(s, [
    { text: '官方 make ext-compliance 會一起啟動 OPA', options: { bullet: true, breakLine: true } },
    { text: '第一次使用時選定並快取：改設定要重啟 API', options: { bullet: true, breakLine: true } },
    { text: '連不到 OPA 或格式不對，會自動改回內建檢查', options: { bullet: true } },
  ], { x: M, y: CONTENT_TOP + 2.85, w: lw, h: 1.3, fontSize: 12.5, color: COLOR.body, paraSpaceAfter: 4 });
  const rx = M + lw + 0.45, rw = W - rx - M;
  code(s, [
    'package policies.quantum_safe',
    '',
    '# 由上往下，第一個符合的決定',
    'decision(c) := {"rule": "PQC", "result": "quantum-safe"} if {',
    '    pqc(c)',
    '} else := {"rule": "BROKEN：已被破解", "result": "na"} if {',
    '    broken(c)',
    '} else := {"rule": "ASYMMETRIC", "result": "quantum-vulnerable"} if {',
    '    asymmetric(c)',
    '} else := {"rule": "SYMMETRIC", "result": "quantum-safe"} if {',
    '    symmetric(c)',
    '} else := {"rule": "UNKNOWN", "result": "unknown"}',
    '',
    'findings contains f if {',
    '    some c in assets',
    '    f := object.union(decision(c), {"bom-ref": c["bom-ref"]})',
    '}',
  ], { x: rx, y: CONTENT_TOP, w: rw, h: 4.25, fontSize: 10 });
  text(s, '簡化自 cbom/cbomkit-demo/policy/quantum_safe.rego（附 opa test 測試）', { x: rx, y: CONTENT_TOP + 4.35, w: rw, h: 0.3, fontSize: 11, color: COLOR.muted });
  s.addNotes('CBOMkit 接 OPA 只要設定 CBOMKIT_OPA_API_BASE。平台會把整份 CBOM 送到 OPA 的 policies.quantum_safe，OPA 對每個資產回傳一筆 finding，結果只能是四種值之一。右邊是我們寫的規則簡化版：由上往下判斷，後量子演算法是 quantum-safe，已被破解的給 na 並在 rule 裡寫原因，非對稱的是 quantum-vulnerable，128 位元以上的對稱演算法是 quantum-safe。要注意三點：官方 make ext-compliance 會一起啟動 OPA；服務第一次使用就選定並快取，改設定要重啟；OPA 連不到時會悄悄改回內建檢查。');
}

function opaResult() {
  const s = contentSlide(S5, '接 OPA 的結果', '同一份掃描結果，換成自己的規則');
  const iw = 6.4;
  const r1 = img(s, 'cbomkit-opa-overview.png', { x: M, y: CONTENT_TOP, w: iw, h: 3.0 }, '接 OPA 後的 CBOMkit 總覽：合規來源變成 Open Policy Agent Compliance Service');
  img(s, 'cbomkit-opa-detail-sha1-compliance.png', { x: M, y: r1.y + r1.h + 0.15, w: iw, h: 1.75 }, '接 OPA 後 SHA-1 的細節：原因顯示自訂規則 BROKEN');
  const rx = M + iw + 0.4, rw = W - rx - M, C = DATA.compliance;
  const levels = Object.keys(C.builtin);
  s.addChart(pres.charts.BAR, [
    { name: '內建檢查', labels: levels, values: levels.map(l => C.builtin[l]) },
    { name: '接 OPA', labels: levels, values: levels.map(l => C.opa[l]) },
  ], {
    x: rx, y: CONTENT_TOP, w: rw, h: 3.0, barDir: 'col', barGapWidthPct: 60,
    showTitle: true, title: `每種結果的資產數（${DATA.scan.assets} 個資產）`, titleFontSize: 12, titleColor: COLOR.ink, titleFontFace: FONT,
    chartColors: [COLOR.line, COLOR.navy], showValue: true, dataLabelPosition: 'outEnd', dataLabelFontSize: 10, dataLabelColor: COLOR.ink, dataLabelFontFace: FONT,
    catAxisLabelColor: COLOR.body, catAxisLabelFontSize: 10, catAxisLabelFontFace: FONT, valAxisHidden: true,
    valGridLine: { style: 'none' }, catGridLine: { style: 'none' }, showLegend: true, legendPos: 'b', legendFontSize: 10, legendFontFace: FONT,
  });
  card(s, { x: rx, y: CONTENT_TOP + 3.15, w: rw, h: 1.5, fill: COLOR.amberTint });
  text(s, [
    { text: '能做到：', options: { bold: true, color: COLOR.amberText } },
    { text: `對稱加密、雜湊改判 Quantum Safe（0 → ${C.opa['Quantum Safe']}），只剩已破解的留在 Not Applicable\n`, options: { color: COLOR.body } },
    { text: '限制：', options: { bold: true, color: COLOR.amberText } },
    { text: '只有四種結果，「已被破解」只能寫在原因裡；打開時才計算、不保存\n', options: { color: COLOR.body } },
    { text: '看哪裡：', options: { bold: true, color: COLOR.amberText } },
    { text: '左下角的標籤文字是網頁寫死的，要看原因欄（Rule …）', options: { color: COLOR.body } },
  ], { x: rx + 0.2, y: CONTENT_TOP + 3.15, w: rw - 0.4, h: 1.5, fontSize: 11, valign: 'middle' });
  s.addNotes(`這是同一份掃描結果，在接了 OPA 的 CBOMkit 上打開。橫幅的來源變成 Open Policy Agent Compliance Service。右邊比較每種結果的資產數：內建檢查把對稱加密和雜湊都算 Not Applicable（${C.builtin['Not Applicable']}），接上我們的規則後，${C.opa['Quantum Safe']} 個 128 位元以上的對稱演算法改判 Quantum Safe，只剩已被破解的 ${C.opa['Not Applicable']} 個留在 Not Applicable，細節頁會顯示我們寫的原因。限制是 CBOMkit 只接受四種結果，「已被破解」放不進獨立的等級；結果每次打開才計算，不會保存。`);
}

// ---------------- PART 06：限制與建議 ----------------
function limits() {
  const s = contentSlide(S6, '能做到與做不到', '平台適合快速盤點原始碼；要知道它看不到什麼');
  const gap = 0.3, cw = (W - 2 * M - gap) / 2, ch = 3.75;
  const cols = [
    { ic: 'circle-check', fill: COLOR.green, tint: COLOR.greenTint, t: '平台能做到', items: ['貼網址掃原始碼（Java、Python、Go）', '圖形化總覽、每個資產的位置與原因', '合規分類（內建，或接 OPA 用自己的規則）', '下載、上傳 CBOM', '保存每次的掃描結果'] },
    { ic: 'circle-x', fill: COLOR.red, tint: COLOR.redTint, t: '平台看不到／做不到', items: ['設定檔裡的金鑰、憑證、寫死的 secret（要另外跑 CBOMkit-theia）', '容器映像檔、主機上的設定（同上）', '實際開放的 TLS 版本與 cipher', '執行時才決定的密碼學（例如透過函式庫呼叫）', '依結果擋下有問題的變更'] },
  ];
  cols.forEach((c, i) => {
    const x = M + i * (cw + gap);
    card(s, { x, y: CONTENT_TOP, w: cw, h: ch, fill: c.tint });
    icon(s, c.ic, x + 0.3, CONTENT_TOP + 0.25, 0.6, c.fill);
    text(s, c.t, { x: x + 1.1, y: CONTENT_TOP + 0.25, w: cw - 1.3, h: 0.6, fontSize: 18, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, c.items.map((t, j) => ({ text: t, options: { bullet: true, breakLine: j < c.items.length - 1 } })),
      { x: x + 0.35, y: CONTENT_TOP + 1.05, w: cw - 0.7, h: ch - 1.2, fontSize: 14, color: COLOR.body, paraSpaceAfter: 8 });
  });
  card(s, { x: M, y: CONTENT_TOP + ch + 0.25, w: W - 2 * M, h: 0.65, fill: COLOR.blueTint });
  text(s, `實測：我們人工列了這個專案實際用到的 ${DATA.coverage.expected} 項密碼學，平台掃描找到 ${DATA.coverage.detected} 項；寫死的 secret、repo 裡的私鑰都沒找到 → 第 7 部分怎麼補`,
    { x: M + 0.3, y: CONTENT_TOP + ch + 0.25, w: W - 2 * M - 0.6, h: 0.65, fontSize: 13.5, bold: true, color: COLOR.navy, valign: 'middle' });
  s.addNotes(`平台很適合快速看程式裡用了哪些密碼學：貼網址就能掃，有總覽、位置與原因，可以接 OPA，也能下載、上傳、保存結果。但要知道它的範圍：它只看原始碼。設定檔裡的金鑰與憑證、映像檔、實際開放的 TLS、執行時才決定的密碼學都看不到，也不能依結果擋下有問題的變更。我們事先人工列了 ${DATA.coverage.expected} 項這個專案實際用到的密碼學，平台掃描找到 ${DATA.coverage.detected} 項；寫死在設定檔的 secret 和 repo 裡的私鑰都沒找到。所以平台的結果是「原始碼這一部分」的盤點，不是全部。同一個專案的 CBOMkit-theia 可以掃設定檔與映像，但它是另外的命令列工具，不在網頁平台裡。下一部分講怎麼補。`);
}

// ---------------- PART 07：補強方案與建議 ----------------
function scenarios() {
  const s = contentSlide(S7, '兩種做法', '同一個 app：平台掃一次，或把盤點放進 pipeline');
  const WA = DATA.webapp;
  table(s, ['', '只用 CBOMkit 平台', '放進 pipeline（Jenkins）'], [
    ['怎麼做', '在網頁貼上 git 網址，按 Scan', '每次建置自動跑，不用人操作'],
    ['盤得到', '程式裡呼叫的演算法', '加上：函式庫、repo 裡的金鑰與秘密、\n映像的設定、實際的 TLS、執行期用到的演算法'],
    ['lab 實測', `標準答案 ${DATA.coverage.detected}／${DATA.coverage.expected} 項`, `標準答案 ${WA.stages[3]}／${DATA.coverage.expected} 項`],
    ['判定', '四種結果（量子安全與否）', '六個等級：「已不安全」是獨立的違規'],
    ['能不能當關卡', '不能', '能：有違規就讓建置失敗'],
    ['產出', '網頁、cbom.json', 'cbom.json、一頁 HTML 報告'],
  ], { x: M, y: CONTENT_TOP, w: W - 2 * M, colW: [1.9, 4.6, 5.633], fontSize: 13, rowH: 0.58, firstColBold: true });
  const by = CONTENT_TOP + 4.25;
  card(s, { x: M, y: by, w: W - 2 * M, h: 0.7, fill: COLOR.blueTint });
  icon(s, 'info', M + 0.2, by + 0.14, 0.42, COLOR.navy);
  text(s, [
    { text: '官方也這樣建議：', options: { bold: true, color: COLOR.navy } },
    { text: '平台掃描時不先建置，結果可能不完整；要更準，把掃描放進 pipeline、建置之後再掃（CBOMkit README）', options: { color: COLOR.body } },
  ], { x: M + 0.8, y: by, w: W - 2 * M - 1.0, h: 0.7, fontSize: 13, valign: 'middle' });
  s.addNotes(`平台只看原始碼，所以我們把同一個 app 的盤點放進 Jenkins 的 pipeline，當成補強。差別在這張表：平台要人去網頁貼網址，pipeline 是每次建置自動跑；平台只盤得到程式裡呼叫的演算法，pipeline 還能盤到函式庫、repo 裡的金鑰與秘密、映像的設定、實際的 TLS 和執行期用到的演算法。同一個 app、同一份標準答案，平台找到 ${DATA.coverage.detected} 項，pipeline 找到 ${WA.stages[3]} 項。判定也不同：pipeline 分六個等級，「已不安全」是獨立的違規，而且有違規可以讓建置失敗。CBOMkit 官方的說明也提醒：平台掃描不先建置，結果可能不完整，建議放進 pipeline 在建置之後掃。另外補充一句：沒有原始碼的產品，例如買來的平台軟體，平台和這條 pipeline 都用不上，那是另一種做法，有另一份簡報說明。`);
}

function webappFlow() {
  const s = contentSlide(S7, 'pipeline 的流程', '照 app 的生命週期分三段：建置時、部署物、執行期');
  diagram(s, 'cbomweb', { x: M, y: CONTENT_TOP - 0.05, w: W - 2 * M, h: 4.5 }, 'web app 的盤點流程：建置時、部署物、執行期三段收集，再合併、判斷、產出報告',
    '合併、判斷、報告');
  text(s, '原始碼掃描用的就是 CBOMkit-action（和平台同一個引擎），差別是在建置之後掃，並且加上其他幾段',
    { x: M, y: CONTENT_TOP + 4.55, w: W - 2 * M, h: 0.35, fontSize: 12, color: COLOR.muted });
  s.addNotes('放進 pipeline 之後，盤點照 app 的生命週期分三段。建置時：建置本身產生 SBOM，知道用了哪些密碼函式庫；原始碼掃描用 CBOMkit-action，和平台是同一個引擎，但在建置之後掃；再用 CBOMkit-theia 掃 repo 裡的憑證、私鑰和寫死的秘密。部署物：把 app 建成映像，掃映像裡的 OpenSSL 設定和信任庫，讀映像裡 JDK 與 OS 的密碼設定。執行期是選用的：用同一個映像把 app 跑起來，把端點打一輪，掃 TLS，用 JDK 內建的 JFR 記錄實際用到的演算法。三段的結果合併成一份 CBOM，用 OPA 判斷，產出報告。建置時與部署物兩段不需要 app 在跑，每次建置都能做。');
}

function webappCoverage() {
  const s = contentSlide(S7, '每一段補了什麼', `同一個 app：平台找到 ${DATA.coverage.detected} 項，pipeline 找到 ${DATA.webapp.stages[3]} 項`);
  const st = DATA.webapp.stages, lw = 5.6;
  const labels = ['原始碼掃描\n（＝平台）', '＋SBOM、\n秘密掃描', '＋映像', '＋執行期'];
  s.addChart(pres.charts.BAR, [{ name: '找到的項目（累計）', labels, values: st }], {
    x: M, y: CONTENT_TOP, w: lw, h: 4.2, barDir: 'col', barGapWidthPct: 55,
    chartColors: [COLOR.navy], showValue: true, dataLabelPosition: 'outEnd', dataLabelFontSize: 14, dataLabelColor: COLOR.ink, dataLabelFontFace: FONT,
    catAxisLabelColor: COLOR.body, catAxisLabelFontSize: 11, catAxisLabelFontFace: FONT, valAxisHidden: true, valAxisMaxVal: DATA.coverage.expected, valAxisMinVal: 0,
    valGridLine: { style: 'none' }, catGridLine: { style: 'none' }, showLegend: false,
  });
  text(s, `累計找到標準答案的幾項（共 ${DATA.coverage.expected} 項）`, { x: M, y: CONTENT_TOP + 4.25, w: lw, h: 0.3, fontSize: 11, color: COLOR.muted, align: 'center' });
  const rx = M + lw + 0.4, rw = W - rx - M;
  table(s, ['階段', '多找到', '例子'], [
    ['原始碼掃描', String(st[0]), '模式與填充（AES-CBC、RSA-OAEP）：\n只有它看得到'],
    ['＋SBOM、秘密掃描', `＋${st[1] - st[0]}`, '密碼函式庫、憑證、repo 裡的私鑰、\n設定檔寫死的金鑰'],
    ['＋映像', `＋${st[2] - st[1]}`, '映像裡的 OpenSSL 設定、JDK 的安全設定'],
    ['＋執行期', `＋${st[3] - st[2]}`, 'JWT 函式庫代為呼叫的簽章、亂數產生器、\n實際開放的 TLS 1.2／1.3'],
    ['都找不到', String(DATA.coverage.expected - st[3]), 'bcrypt、Argon2（不經 JDK 的 API）、JWT 的 alg=none、\nRSA 加密的 PKCS#1 v1.5 填充（工具沒回報）'],
  ], { x: rx, y: CONTENT_TOP, w: rw, colW: [1.75, 0.85, rw - 2.6], fontSize: 11.5, rowH: 0.74, firstColBold: true });
  s.addNotes(`這頁回答「平台漏掉的那一半怎麼補」。同一個 app、同一份 ${DATA.coverage.expected} 項的標準答案：只做原始碼掃描是 ${st[0]} 項，和平台一樣；加上建置產生的 SBOM 和秘密掃描到 ${st[1]} 項，多的是密碼函式庫、憑證、放在 repo 裡的私鑰、設定檔寫死的金鑰；加上映像到 ${st[2]} 項；加上執行期到 ${st[3]} 項，多的是函式庫代為呼叫的演算法，例如 JWT 函式庫的簽章，原始碼裡沒有那個字串，只有執行期看得到。反過來，加密的模式與填充只有原始碼掃描看得到，所以各段是互補的，不是誰取代誰。最後 ${DATA.coverage.expected - st[3]} 項都找不到：bcrypt、Argon2 是純 Java 實作，不經過 JDK 的密碼學 API；JWT 的 alg=none 沒有演算法，就沒有東西可以列；RSA 加密用 PKCS#1 v1.5 填充那一項，掃描工具只回報 RSA-2048、沒有回報填充方式，所以分不出來。這類要靠程式碼審查。每次建置會自動對一次標準答案，結果在產出檔 inventory-check.txt。`);
}

function webappGate() {
  const s = contentSlide(S7, '判定與關卡', '六個等級：「已不安全」和「量子脆弱」分開，違規才擋');
  const iw = 5.7;
  img(s, 'report-webapp.png', { x: M, y: CONTENT_TOP, w: iw, h: 4.2 }, 'web app 的合規報告：不合規，各等級的數量，以及後量子遷移的重點');
  text(s, 'pipeline 產出的一頁 HTML 報告（Jenkins 上可以直接看、可以下載）', { x: M, y: CONTENT_TOP + 4.25, w: iw, h: 0.3, fontSize: 11, color: COLOR.muted });
  const rx = M + iw + 0.4, rw = W - rx - M;
  table(s, ['找到的東西', '平台（四種結果）', 'pipeline（六級）'], [
    ['MD5、SHA-1、DES', 'Not Applicable', '違規'],
    ['RSA-1024', 'Not Quantum Safe\n（和 RSA-4096 同一類）', '違規：金鑰太短'],
    ['私鑰放在 repo、寫死的金鑰', '看不到', '違規'],
    ['RSA、ECDSA、ECDH', 'Not Quantum Safe', '量子脆弱'],
    ['還接受 TLS 1.2', '看不到', '警告'],
    ['AES-256、SHA-256', 'Not Applicable\n（接 OPA 可改判）', '通過'],
  ], { x: rx, y: CONTENT_TOP, w: rw, colW: [2.25, 2.1, rw - 4.35], fontSize: 11.5, rowH: 0.56, firstColBold: true });
  card(s, { x: rx, y: CONTENT_TOP + 4.3, w: rw, h: 0.6, fill: COLOR.amberTint });
  text(s, `只有「違規」讓建置失敗（這個 app 有 ${DATA.webapp.violation} 個）；量子脆弱排進遷移計畫，不擋。舊專案可以先關掉關卡`,
    { x: rx + 0.2, y: CONTENT_TOP + 4.3, w: rw - 0.4, h: 0.6, fontSize: 11.5, color: COLOR.body, valign: 'middle' });
  s.addNotes(`第 5 部分提到平台只接受四種結果，已被破解的演算法只能放在 Not Applicable。pipeline 用自己的規則，分六個等級：違規、量子脆弱、警告、無法判斷、通過、資訊。差別在表上：MD5、SHA-1、DES 在平台是 Not Applicable，在這裡是違規；RSA-1024 在平台和 RSA-4096 都是 Not Quantum Safe，在這裡因為金鑰太短是違規；私鑰放在 repo 平台看不到，這裡是違規。只有違規會讓建置失敗，量子脆弱不擋，因為現在的憑證幾乎都是 RSA，那是要排進遷移計畫的事。這個 app 刻意放了弱點，有 ${DATA.webapp.violation} 個違規，所以關卡開著時建置失敗。既有的專案一開始可以把關卡關掉，只把結果標成不穩定，清完違規再打開。左邊是報告的畫面；報告上的數字是資產數，一個資產可能有不只一筆判定。`);
}

function reportGuide() {
  const s = contentSlide(S7, '怎麼看報告', '先看橫幅過不過，再看違規要修什麼，最後排遷移');
  const iw = 6.9;
  const top = img(s, 'report-webapp.png', { x: M, y: CONTENT_TOP - 0.05, w: iw, h: 3.2 }, '合規報告的上半部：範圍、判定橫幅、各等級的數量、後量子遷移的重點');
  const low = img(s, 'report-webapp-violations.png', { x: M, y: top.y + top.h + 0.12, w: iw, h: 1.55 }, '合規報告的違規清單：類型、資產、判斷與依據、出現位置');
  // 編號標在圖的右緣（位置是相對圖片高度的比例，對照截圖調整）
  [[0.2], [0.305], [0.505], [0.8]].forEach(([fy], i) => badge(s, i + 1, top.x + top.w - 0.2, top.y + top.h * fy - 0.19, 0.38, COLOR.red, 13));
  badge(s, 5, low.x + low.w - 0.2, low.y + 0.12, 0.38, COLOR.red, 13);
  const rx = M + iw + 0.55, rw = W - rx - M;
  const items = [
    ['範圍', '盤了誰、完整還是部分盤點、有沒有執行期證據'],
    ['判定橫幅', '合規或不合規；只有「違規」會讓它變成不合規'],
    ['六個數字', '違規、量子脆弱、警告、無法判斷、通過、資訊，各有幾個資產'],
    ['後量子遷移的重點', '幾個 TLS 端點支援後量子金鑰交換、憑證用什麼金鑰、最早到期的憑證'],
    ['各等級的清單', '一列一個資產：是什麼、為什麼這樣判、依據哪份標準、出現在哪個檔的第幾行'],
  ];
  items.forEach(([head, body], i) => {
    const y = CONTENT_TOP + i * 0.95;
    badge(s, i + 1, rx, y, 0.4, COLOR.red, 13);
    text(s, head, { x: rx + 0.55, y: y - 0.04, w: rw - 0.55, h: 0.4, fontSize: 14, bold: true, color: COLOR.ink, valign: 'middle' });
    text(s, body, { x: rx + 0.55, y: y + 0.36, w: rw - 0.55, h: 0.55, fontSize: 11.5, color: COLOR.body });
  });
  s.addNotes(`這是 pipeline 產出的那一頁報告，照編號看。第一塊是範圍：這次盤的是誰、是完整還是部分盤點、有沒有執行期證據。第二塊是判定橫幅：合規或不合規，只有違規會讓它變成不合規，量子脆弱和警告都不影響。第三塊是六個數字，是資產的數量。第四塊是後量子遷移的重點：幾個 TLS 端點支援後量子金鑰交換，這個 app 是零，因為它用的 JDK 21 還沒有；憑證用什麼金鑰；最早到期的憑證是哪一天。第五塊是各等級的清單，違規排最前面，一列一個資產，寫出它是什麼、為什麼這樣判、依據哪一份標準、出現在哪個檔的第幾行，所以拿到報告就知道要去改哪裡。看的順序：先看橫幅知道過不過，再看違規清單知道要修什麼，最後看後量子重點和量子脆弱的清單，排進遷移計畫。這個 app 有 ${DATA.webapp.violation} 個違規，是刻意放的。`);
}

/** 兩張 Jenkins 的截圖並排：左邊執行前的參數，右邊執行後的結果 */
function jenkinsWebapp() {
  const s = contentSlide(S7, 'Jenkins 上的樣子', '一個工作：執行期可以勾選，關卡可以開關');
  const lw = 6.2, gap = 0.35, h = 4.45;
  img(s, 'jenkins-webapp-params.png', { x: M, y: CONTENT_TOP, w: lw, h }, 'Jenkins 工作 cbom-webapp 的參數頁：git 來源、執行期、關卡、CycloneDX 版本、CBOMkit 網址');
  const job = img(s, 'jenkins-webapp-job.png', { x: M + lw + gap, y: CONTENT_TOP, w: W - 2 * M - lw - gap, h }, 'Jenkins 工作 cbom-webapp 的工作頁：可下載的四個檔，以及每次執行的結果摘要');
  // 標註兩次執行（位置是相對截圖寬高的比例）：紅色那次不是工具出錯，是關卡擋下
  [[0.742, COLOR.amber, COLOR.amberTint, '#3 黃：關卡關著，只標示'], [0.877, COLOR.red, COLOR.redTint, '#1 紅：關卡擋下（預期）']].forEach(([fy, line, fill, label]) => {
    const cy = job.y + job.h * fy, bx = job.x + job.w * 0.52, bw = job.w * 0.46, bh = 0.4;
    arrow(s, bx, cy, job.x + job.w * 0.455, cy, '', line);
    card(s, { x: bx, y: cy - bh / 2, w: bw, h: bh, fill, line });
    text(s, label, { x: bx + 0.08, y: cy - bh / 2, w: bw - 0.16, h: bh, fontSize: 10.5, bold: true, color: COLOR.ink, align: 'center', valign: 'middle' });
  });
  text(s, '左：執行前的參數。右：執行後，四個檔可以下載（CBOM、判定、對答案的結果、報告）；每次執行的說明列出各等級的數量（紅色＝關卡擋下，黃色＝關卡關著只標示）',
    { x: M, y: CONTENT_TOP + h + 0.12, w: W - 2 * M, h: 0.5, fontSize: 12, color: COLOR.muted });
  s.addNotes('這是 lab 的 Jenkins 實際的畫面；現場不重跑，因為一次要四到六分鐘。左邊是執行前的參數：可以指定 app 的 git 網址；RUNTIME_EVIDENCE 勾了才會把 app 跑起來做 TLS 掃描和 JFR；GATE 是關卡，預設開著。右邊是執行後：最上面四個檔可以直接下載，其中 inventory-check.txt 是每次建置自動和標準答案比對的結果，左下的清單是每一次執行，說明欄列出各等級的數量。第一次是紅色，因為關卡開著而這個 app 有違規；另一次加了執行期、關掉關卡，是黃色，表示有違規但只標示不擋。左邊選單的「CBOM 合規報告」點進去就是上一頁那份報告。');
}

function together() {
  const s = contentSlide(S7, '怎麼搭配', 'pipeline 產出 CBOM 與報告；平台當檢視器');
  const y = CONTENT_TOP + 0.8, h = 1.15;
  node(s, { x: M, y, w: 3.3, h, title: 'pipeline（Jenkins）', sub: '建置、原始碼掃描、秘密、映像、執行期', fill: COLOR.blueTint, line: COLOR.blue, fontSize: 14, subSize: 11 });
  arrow(s, M + 3.35, y + h / 2, M + 4.15, y + h / 2);
  node(s, { x: M + 4.2, y, w: 2.7, h, title: '一份 CBOM', sub: 'CycloneDX 1.7\n官方 schema 驗證', fill: COLOR.navy, line: COLOR.navy, titleColor: COLOR.white, subColor: 'C9D4E5', fontSize: 14, subSize: 11 });
  const ox = M + 7.75, ow = W - ox - M;
  node(s, { x: ox, y: y - 0.75, w: ow, h, title: 'OPA（cbom.rego，六個等級）', sub: 'HTML 報告、Jenkins 關卡', fill: COLOR.amberTint, line: COLOR.amber, titleColor: COLOR.amberText, fontSize: 14, subSize: 11.5 });
  node(s, { x: ox, y: y + 0.75, w: ow, h, title: 'CBOMkit 平台（選用）', sub: '上傳只含密碼學資產的那一份；\n網頁上看總覽與位置', fill: COLOR.white, fontSize: 14, subSize: 11.5 });
  arrow(s, M + 6.95, y + h / 2 - 0.15, ox - 0.05, y - 0.75 + h / 2);
  arrow(s, M + 6.95, y + h / 2 + 0.15, ox - 0.05, y + 0.75 + h / 2);
  const ty = y + h + 1.05;
  table(s, ['', '平台上的規則', 'pipeline 的規則'], [
    ['檔案', 'quantum_safe.rego', 'cbom.rego'],
    ['結果', '四種（平台只接受這四種）', '六個等級，只有違規算不合規'],
  ], { x: M, y: ty, w: W - 2 * M, colW: [1.3, 5.4, W - 2 * M - 6.7], fontSize: 12, rowH: 0.45, firstColBold: true });
  text(s, '兩份規則目前是分開的：要不要整併成一份、由誰維護，是導入時要決定的事', { x: M, y: ty + 1.5, w: W - 2 * M, h: 0.35, fontSize: 12.5, bold: true, color: COLOR.navy });
  s.addNotes('平台和 pipeline 不是二選一。pipeline 每次建置產出一份 CBOM，用 OPA 判斷，產出報告，並且當成關卡。平台在這裡可以當檢視器：把 pipeline 產出的 CBOM 上傳上去，在網頁上看總覽和每個資產的位置；上傳前只留密碼學資產，原因在第 4 部分講過。要誠實說明的一點：平台上的規則和 pipeline 的規則目前是兩份。平台只接受四種結果，pipeline 有六個等級，所以不能直接共用。要不要整併、由誰維護，是導入時要決定的。');
}

function recommend() {
  const s = contentSlide(S7, '建議', '分三步導入：先看全貌，再放進 pipeline，最後打開關卡');
  const steps = [
    { ic: 'scan-search', t: '平台掃一次', d: '貼網址掃描，和團隊一起看：用了哪些演算法、哪些不是量子安全' },
    { ic: 'history', t: '進 pipeline', d: '每次建置都盤，先不擋：只出報告，把既有的違規清掉' },
    { ic: 'scale', t: '打開關卡', d: '規則和資安定案之後打開：之後有新的違規，建置就失敗' },
  ];
  const gap = 0.12, cw = (W - 2 * M - gap * 2) / 3, y = CONTENT_TOP + 0.1;
  steps.forEach((st, i) => {
    const x = M + i * (cw + gap);
    s.addShape(pres.shapes.CHEVRON, { x, y, w: cw, h: 1.1, fill: { color: BRAND[i] }, line: { type: 'none' } });
    s.addImage({ data: iconPng(st.ic, COLOR.white), x: x + 0.65, y: y + 0.3, w: 0.5, h: 0.5, altText: st.t });
    text(s, `${i + 1}  ${st.t}`, { x: x + 1.25, y, w: cw - 1.7, h: 1.1, fontSize: 20, bold: true, color: COLOR.white, valign: 'middle' });
    text(s, st.d, { x: x + 0.3, y: y + 1.3, w: cw - 0.6, h: 0.8, fontSize: 13.5, color: COLOR.body, align: 'center' });
  });
  const ny = CONTENT_TOP + 2.55;
  card(s, { x: M, y: ny, w: W - 2 * M, h: 2.2 });
  icon(s, 'rocket', M + 0.3, ny + 0.25, 0.6, COLOR.navy);
  text(s, '下一步', { x: M + 1.1, y: ny + 0.25, w: 4, h: 0.6, fontSize: 18, bold: true, color: COLOR.ink, valign: 'middle' });
  text(s, [
    { text: '和資安單位定好規則（哪些算違規、金鑰長度下限），寫成 Rego 並加測試；決定兩份規則要不要整併', options: { bullet: true, breakLine: true } },
    { text: 'pipeline 需要有容器引擎的 Jenkins agent，以及內部的 registry 與套件庫', options: { bullet: true, breakLine: true } },
    { text: 'PQC：lab 實測 JDK 25 的 TLS 預設就支援 X25519MLKEM768，JDK 21 沒有 → 先盤各系統的 JDK 版本', options: { bullet: true } },
  ], { x: M + 1.1, y: ny + 0.9, w: W - 2 * M - 1.4, h: 1.2, fontSize: 14, color: COLOR.body, paraSpaceAfter: 4 });
  s.addNotes('建議分三步。第一步用平台掃一次，門檻最低，適合和團隊一起看全貌。第二步把盤點放進 pipeline，每次建置都跑，但關卡先關著，只出報告，讓團隊把既有的違規清掉。第三步，規則和資安單位定案、違規清完之後打開關卡，之後有新的違規建置就會失敗。下一步要做的事：和資安單位定規則，並決定平台和 pipeline 的兩份規則要不要整併；pipeline 需要有容器引擎的 Jenkins agent 和內部的 registry 與套件庫，要先和管理團隊確認；後量子的部分，lab 實測 JDK 25 的 TLS 預設就支援混合金鑰交換，JDK 21 沒有，所以可以先盤各系統的 JDK 版本。');
}

function closing() {
  const s = pres.addSlide({ masterName: 'CLOSING', sectionTitle: S7 });
  text(s, '謝謝聆聽', { x: 0.5, y: 2.61, w: 6, h: 1.14, fontSize: 48, bold: true, color: COLOR.ink, valign: 'middle' });
  text(s, '問題與討論', { x: 0.5, y: 3.75, w: 6, h: 0.6, fontSize: 24, color: COLOR.navy });
  s.addNotes('開放提問。');
}

// 依序產生
cover(); agenda(); summary();
sectionDivider(S1, 1, 'CBOM 基礎', '是什麼、為什麼現在做\nCycloneDX 格式與四種資產類型').addNotes('第一部分：CBOM 的基礎。');
whatIsCbom(); whyNow(); format(); example(); assetTypes();
sectionDivider(S2, 2, 'CBOMkit 平台', '平台的三個部分\n架構').addNotes('第二部分：CBOMkit 平台。');
cbomkitFamily(); architecture();
sectionDivider(S3, 3, '怎麼掃描', '貼上 git 網址\n掃描結果的數字').addNotes('第三部分：怎麼掃描。');
scanSteps(); scanResult();
sectionDivider(S4, 4, '怎麼看結果', '總覽、資產清單、細節\n下載與上傳').addNotes('第四部分：怎麼看結果。');
overview(); assetList(); details(); downloadUpload();
sectionDivider(S5, 5, '合規檢查與 OPA', '內建的 quantum_safe\nOPA 是什麼、怎麼接、結果').addNotes('第五部分：合規檢查與 OPA。');
builtinCheck(); whatIsOpa(); opaHow(); opaResult();
sectionDivider(S6, 6, '平台的限制', '能做到與做不到\n實測找到多少').addNotes('第六部分：平台的限制。');
limits();
sectionDivider(S7, 7, '補強方案與建議', '把盤點放進 pipeline\n怎麼看報告、導入建議').addNotes('最後：把同一個 app 的盤點放進 pipeline，以及導入建議。');
scenarios(); webappFlow(); webappCoverage(); webappGate(); reportGuide(); jenkinsWebapp(); together(); recommend(); closing();

await pres.writeFile({ fileName: output });
console.log(`Wrote ${output}`);
