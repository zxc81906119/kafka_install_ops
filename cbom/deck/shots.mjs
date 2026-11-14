// 截兩份簡報（Cbom 探討、Cbom 平台盤點）用的 Jenkins 與報告畫面：用 DevTools 協定控制無頭 Chrome。
// Jenkins 的密碼只從 lab 的密碼檔讀進記憶體，不印出來、不放進網址或指令列。
//
// 用法（Windows，在專案的根目錄；node 22 以上、要有 Chrome）：
//   node cbom/deck/shots.mjs webapp <web app 的 report.html>      cbom-jenkins（port 18089）要在跑
//   node cbom/deck/shots.mjs cp <Confluent Platform 的 report.html>   lab-jenkins（port 18088）要在跑
// report.html 是那一次建置的產出檔（Jenkins 工作頁的「建構產出檔案」下載，或從容器複製出來）。
//
// 輸出：cbom/deck/images/cbomkit/ 底下四張 PNG（2 倍解析度）：
//   webapp：jenkins-webapp-params、jenkins-webapp-job、report-webapp、report-webapp-violations
//   cp    ：jenkins-cp-params、jenkins-cp-job、report-cp、report-cp-qv
//   每存一張印一行「ok 檔名」。
// 結束碼：0 做完；64 參數不對；1 Chrome 沒有起來。頁面沒載完不會失敗，只會拍到不對的畫面：拍完要自己看圖。
// 簡報上的編號標註是照圖的比例放的（build-cbom-talk.mjs、build-cbom-platform.mjs 的 reportGuide 與 jenkinsWebapp）：
// 報告的版面有變、或 web app 的工作不是剛好兩次建置（紅、黃各一）時，標註的位置要跟著調。
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const [subject, reportFile] = process.argv.slice(2);
const SUBJECTS = {
  webapp: {
    base: 'http://localhost:18089', job: 'cbom-webapp', passFile: 'cbom-lab/jenkins/secrets/admin.pass',
    params: { w: 975, h: 820 }, jobPage: { w: 750, h: 740 },
    report: { name: 'report-webapp', w: 1210, h: 690 },
    section: { name: 'report-webapp-violations', heading: '違規', w: 1210, h: 450 },
  },
  cp: {
    base: 'http://localhost:18088', job: 'cbom', passFile: 'kafka-lab/jenkins/secrets/admin.pass',
    params: { w: 975, h: 600 }, jobPage: { w: 730, h: 780 },
    report: { name: 'report-cp', w: 1185, h: 700 },
    section: { name: 'report-cp-qv', heading: '量子脆弱', w: 1185, h: 555 },
  },
};
const conf = SUBJECTS[subject];
if (!conf || !reportFile) {
  console.error('用法：node cbom/deck/shots.mjs webapp|cp <report.html>');
  process.exit(64);
}

const OUT = join(dirname(fileURLToPath(import.meta.url)), 'images', 'cbomkit');
const password = readFileSync(join(homedir(), conf.passFile), 'utf8').trim();
const authorization = 'Basic ' + Buffer.from('admin:' + password).toString('base64');

// 1. 啟動無頭 Chrome，開 DevTools 連線
const port = 9335;
const chrome = spawn('C:/Program Files/Google/Chrome/Application/chrome.exe', [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', `--remote-debugging-port=${port}`,
  `--user-data-dir=${mkdtempSync(join(tmpdir(), 'deck-'))}`, 'about:blank',
], { stdio: 'ignore' });
let version;
for (let i = 0; i < 40 && !version; i++) {
  await new Promise((r) => setTimeout(r, 250));
  version = await fetch(`http://127.0.0.1:${port}/json/version`).then((r) => r.json()).catch(() => null);
}
if (!version) {
  console.error('Chrome 沒有起來');
  process.exit(1);
}
const ws = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0;
const waiting = new Map();
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && waiting.has(m.id)) {
    waiting.get(m.id)(m.result ?? m.error);
    waiting.delete(m.id);
  }
});
const send = (method, params = {}, sessionId) => new Promise((r) => {
  waiting.set(++id, r);
  ws.send(JSON.stringify({ id, method, params, sessionId }));
});

// 開一個分頁；headers 有給就每個請求都帶（Jenkins 的基本認證）
async function openTab(headers) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  if (headers) {
    await send('Network.enable', {}, sessionId);
    await send('Network.setExtraHTTPHeaders', { headers }, sessionId);
  }
  return sessionId;
}

// 開網址、等它畫完、拍一塊（左上角 x=0、y=top，寬 w 高 h）
async function shot(sessionId, name, url, box, top = 0, viewWidth = 1440) {
  await send('Emulation.setDeviceMetricsOverride', { width: viewWidth, height: 1000, deviceScaleFactor: 2, mobile: false }, sessionId);
  await send('Page.navigate', { url }, sessionId);
  await new Promise((r) => setTimeout(r, 6000));
  let y = top;
  if (typeof top === 'string') {
    // top 是標題文字：找到開頭是這幾個字的 h2，從它上面一點開始拍
    const expression = `(() => { const h = [...document.querySelectorAll('h2')].find((e) => e.textContent.trim().startsWith(${JSON.stringify(top)})); return h ? h.getBoundingClientRect().top + window.scrollY - 8 : -1; })()`;
    const { result } = await send('Runtime.evaluate', { expression, returnByValue: true }, sessionId);
    y = result.value;
    if (y < 0) {
      console.log('找不到標題：' + top);
      y = 0;
    }
  }
  const clip = { x: 0, y, width: box.w, height: box.h, scale: 1 };
  const { data } = await send('Page.captureScreenshot', { format: 'png', clip, captureBeyondViewport: true }, sessionId);
  writeFileSync(join(OUT, name + '.png'), Buffer.from(data, 'base64'));
  console.log('ok', name);
}

// 2. Jenkins：參數頁、工作頁
const jenkins = await openTab({ Authorization: authorization });
await shot(jenkins, `jenkins-${subject}-params`, `${conf.base}/job/${conf.job}/build?delay=0sec`, conf.params);
await shot(jenkins, `jenkins-${subject}-job`, `${conf.base}/job/${conf.job}/`, conf.jobPage);

// 3. 報告：上半部、指定等級的清單開頭（視窗寬度就是要拍的寬度，報告會照這個寬度排版）
const report = await openTab();
const reportUrl = pathToFileURL(resolve(reportFile)).href;
await shot(report, conf.report.name, reportUrl, conf.report, 0, conf.report.w);
await shot(report, conf.section.name, reportUrl, conf.section, conf.section.heading, conf.section.w);

ws.close();
chrome.kill();
