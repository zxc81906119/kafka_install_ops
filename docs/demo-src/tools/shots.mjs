// 截展示環境的畫面給 demo 手冊用：用 DevTools 協定控制無頭 Chrome。
// 先決條件：展示環境在跑（demo.sh up --jenkins）、CBOMkit 已掃描過、Jenkins 的工作至少跑過兩次（紅、黃各一）。
// Jenkins 的密碼只從 lab 的密碼檔讀進記憶體，不印出來、不放進網址或指令列。
// 用法：node docs/demo-src/tools/shots.mjs <紅色那次的編號> <黃色那次的編號>
//   例：node docs/demo-src/tools/shots.mjs 3 4
//
// 誰在哪裡執行：維護 demo 手冊的人，Windows（要有 Chrome 與 node 22 以上：用到內建的 WebSocket 與 fetch）。
// 紅、黃兩次怎麼跑出來（Jenkins 的工作 cbom-webapp，web app 有違規項目時）：
//   紅色＝參數 GATE 有勾（預設）：有違規就失敗；黃色＝GATE 取消勾選：有違規只標成不穩定。
//   其中至少一次要填 CBOMKIT_URL（demo.sh up --jenkins 最後印的網址），第 4 步才有「pipeline 上傳的那一份」可以拍。
//   編號是 Jenkins 工作頁面左邊「#3」「#4」的數字。
// 輸出：docs/demo-src/images/ 底下 12 張 PNG 與 2 個文字檔（給 demo 手冊 docs/demo-src/demo.md 用）：
//   jenkins-login、jenkins-job、jenkins-params、jenkins-build-red、jenkins-build-yellow、jenkins-report、
//   report-webapp-violations、cbomkit-b-home、cbomkit-b-upload、cbomkit-a-home、cbomkit-overview、cbomkit-list（各一張 .png）；cbomkit-b-home.txt、cbomkit-b-upload.txt（頁面的文字）
//   每存一張印一行「ok 檔名」。
// 結束碼：0 做完；64 少了參數；1 Chrome 沒有起來。頁面沒載完、元素沒點到不會失敗，只會拍到不對的畫面：拍完要自己看圖。
// 這支寫死的值（和別處要一致）：Jenkins 的 port 18089（cbom/webapp/lab.sh）、網頁 A／B 的 port 28084／28086
// （cbom/cbomkit-demo/demo.conf）、Chrome 的安裝位置、DevTools 的 port 9334。
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const [red, yellow] = process.argv.slice(2);
if (!red || !yellow) {
  console.error('用法：node shots.mjs <紅色那次的編號> <黃色那次的編號>');
  process.exit(64);
}

// 圖存到這支腳本的上一層的 images/，也就是 docs/demo-src/images/
const scriptDir = dirname(fileURLToPath(import.meta.url));
const out = join(scriptDir, '..', 'images');
mkdirSync(out, { recursive: true });

// 三個網站在這台機器上的網址
const JENKINS = 'http://localhost:18089';
const PAGE_A = 'http://localhost:28084';
const PAGE_B = 'http://localhost:28086';

// Jenkins 報告頁的網址裡的那一段：HTML Publisher plugin 把報告名稱「CBOM 合規報告」（Jenkinsfile 的 reportName）
// 轉成網址用的寫法：英數字照舊，其他的字寫成「_」加上那個字 UTF-8 編碼的十六進位。
//   空白 → _20；合 → _e59088；規 → _e8a68f；報 → _e5a0b1；告 → _e5918a
//   改了 reportName 這裡要跟著改：在 Jenkins 點開那次執行的報告，從網址列複製 /job/cbom-webapp/<編號>/ 後面那一段
const REPORT = 'CBOM_20_e59088_e8a68f_e5a0b1_e5918a';

// Jenkins 的帳密：密碼從 lab 的密碼檔讀，組成 HTTP 的 Basic 認證標頭（「帳號:密碼」做 base64）
const passwordFile = join(homedir(), 'cbom-lab/jenkins/secrets/admin.pass');
const password = readFileSync(passwordFile, 'utf8').trim();
const authorization = 'Basic ' + Buffer.from('admin:' + password).toString('base64');

// sleep(毫秒)：等這麼久再繼續。這支沒有偵測「頁面載完了」，一律用固定的等待時間（見各步驟後面的數字）
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// 1. 啟動無頭 Chrome，開 DevTools 連線
//    --headless=new 不開視窗；--remote-debugging-port 讓這支程式可以遙控它；
//    --user-data-dir 用一個全新的暫存設定檔目錄（不碰平常用的 Chrome 的登入狀態）
const port = 9334;
const chromePath = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const profileDir = mkdtempSync(join(tmpdir(), 'demo-'));
const chrome = spawn(chromePath, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', `--remote-debugging-port=${port}`,
  `--user-data-dir=${profileDir}`, 'about:blank',
], { stdio: 'ignore' });

// Chrome 執行檔不在時 spawn 會發出 error 事件：記下來，下面一起回報（不接這個事件的話 node 會直接當掉）
let spawnError = null;
chrome.on('error', (error) => {
  spawnError = error;
});

// 等 Chrome 準備好：每 250 毫秒問一次 /json/version，最多 40 次（10 秒）；連不上就當作還沒好
let version = null;
for (let i = 0; i < 40 && !version && !spawnError; i++) {
  await sleep(250);
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/version`);
    version = await response.json();
  } catch {
    version = null;
  }
}

if (!version) {
  console.error(`Chrome 沒有起來（10 秒內連不上 DevTools 的 port ${port}）。`);
  if (spawnError) {
    console.error(`  啟動失敗：${spawnError.message}`);
  }
  console.error(`  檢查：Chrome 是不是裝在 ${chromePath}（不是就改這支的 chromePath）；`);
  console.error(`        port ${port} 有沒有被別的程式佔用（上次沒關掉的無頭 Chrome：工作管理員結束 chrome.exe 再試）。`);
  chrome.kill();
  process.exit(1);
}

// 連上 Chrome 的 DevTools（WebSocket）。之後每個指令都是送一則 JSON：{ id, method, params, sessionId }，
// Chrome 用同一個 id 回一則 { id, result } 或 { id, error }
const ws = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((resolve) => ws.addEventListener('open', resolve));

// waiting：已送出、還在等回應的指令。編號 → 「收到回應時要呼叫的函式」
let id = 0;
const waiting = new Map();

// 收到 Chrome 的訊息：是某個指令的回應（有 id 而且我們在等）就把結果交給那個指令，其他訊息（事件通知）不理
ws.addEventListener('message', (event) => {
  const message = JSON.parse(event.data);
  if (message.id && waiting.has(message.id)) {
    const resolve = waiting.get(message.id);
    resolve(message.result ?? message.error);
    waiting.delete(message.id);
  }
});

// send(方法, 參數, 分頁的 sessionId)：送一個 DevTools 指令，等到 Chrome 回應才回來，回傳它的結果
//   例：await send('Page.navigate', { url: 'http://localhost:18089/login' }, sessionId)
function send(method, params = {}, sessionId) {
  return new Promise((resolve) => {
    id += 1;
    waiting.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params, sessionId }));
  });
}

// 2. 一個分頁一組操作：goto、click（照畫面上的文字找）、type、shot
// openTab(headers)：開一個新分頁，回傳操作它的幾個函式。headers 有給的話，這個分頁送出的每個請求都帶上
//   （Jenkins 用它帶認證標頭）
//   goto(網址, 等幾毫秒)        開這個網址，固定等這麼久讓頁面載完
//   click(文字, 等幾毫秒, 哪一個) 點畫面上含這段文字的元素（'first' 第一個，預設；'last' 最後一個）；回傳有沒有點到
//   type(CSS 選擇器, 文字)      在那個輸入框打字
//   scrollTo(文字)              捲到以這段文字開頭的元素
//   text()                      整頁看得到的文字
//   shot(檔名, 高度)            截圖存成 images/<檔名>.png（寬 1360、預設高 900、1.5 倍解析度）
async function openTab(headers) {
  // 開一個空白分頁並接上去；之後對這個分頁下的指令都帶它的 sessionId
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Network.enable', {}, sessionId);
  if (headers) {
    await send('Network.setExtraHTTPHeaders', { headers }, sessionId);
  }

  // evaluate(一段 JavaScript 的文字)：在這個分頁的頁面裡執行，回傳它算出來的值
  //   下面 click、scrollTo 傳進去的是「(() => { … })()」：一個馬上執行的函式，裡面的 document 是頁面的，不是這支程式的
  //   ${JSON.stringify(text)}：把要找的文字安全地寫進那段程式（加上引號、處理特殊字元）
  const evaluate = async (expression) => {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, sessionId);
    return result.result?.value;
  };

  return {
    async goto(url, wait = 5000) {
      await send('Page.navigate', { url }, sessionId);
      await sleep(wait);
    },
    // 點畫面上文字符合的元素（取最裡層、看得到的那一個）；回傳有沒有點到
    //   hits：看得到（offsetParent 不是 null）而且文字含 wanted 的元素。外層的 div 也會含同樣的文字，
    //   inner：從 hits 裡去掉「裡面還包著另一個符合的元素」的，剩下最裡層的；點第一個
    async click(text, wait = 3000, which = 'first') {
      const clicked = await evaluate(`(() => {
        const wanted = ${JSON.stringify(text)};
        const hits = [...document.querySelectorAll('button, a, [role=button], div, span, p, h4, td')]
          .filter((e) => e.offsetParent !== null && e.textContent.trim().includes(wanted));
        const inner = hits.filter((e) => !hits.some((other) => other !== e && e.contains(other)));
        if (inner.length === 0) return false;
        // which 是 'last' 就點最後一個符合的，否則點第一個
        const target = ${JSON.stringify(which)} === 'last' ? inner[inner.length - 1] : inner[0];
        target.scrollIntoView({ block: 'center' });
        target.click();
        return true;
      })()`);
      await sleep(wait);
      return clicked;
    },
    async type(selector, text) {
      await evaluate(`document.querySelector(${JSON.stringify(selector)}).focus()`);
      await send('Input.insertText', { text }, sessionId);
      await sleep(500);
    },
    // 捲到「看得到、文字以 wanted 開頭」的元素；符合的有好幾個時取頁面順序最後面的那一個（.pop()）
    async scrollTo(text) {
      await evaluate(`(() => {
        const wanted = ${JSON.stringify(text)};
        const hit = [...document.querySelectorAll('h1, h2, h3, h4, h5, div, span, p')]
          .filter((e) => e.offsetParent !== null && e.textContent.trim().startsWith(wanted)).pop();
        if (hit) hit.scrollIntoView({ block: 'start' });
      })()`);
      await sleep(1000);
    },
    text: () => evaluate('document.body.innerText'),
    // 先把視窗設成固定的大小（等 0.8 秒讓頁面重新排版），再截圖；Chrome 回的是 base64 的 PNG
    async shot(name, height = 900) {
      const metrics = { width: 1360, height, deviceScaleFactor: 1.5, mobile: false };
      await send('Emulation.setDeviceMetricsOverride', metrics, sessionId);
      await sleep(800);
      const { data } = await send('Page.captureScreenshot', { format: 'png' }, sessionId);
      writeFileSync(join(out, name + '.png'), Buffer.from(data, 'base64'));
      console.log('ok', name);
    },
  };
}

// 3. Jenkins：登入頁不帶認證；其餘帶認證標頭（表單登入用程式送不過）
//    goto 的第二個參數是等頁面載完的毫秒數（3000–6000，Jenkins 的頁面比較慢的給 6 秒）；shot 的第二個參數是截圖的高度
const login = await openTab();
await login.goto(JENKINS + '/login', 3000);
await login.shot('jenkins-login', 700);

const jenkins = await openTab({ Authorization: authorization });
await jenkins.goto(JENKINS + '/job/cbom-webapp/', 6000);
await jenkins.shot('jenkins-job');
await jenkins.goto(JENKINS + '/job/cbom-webapp/build?delay=0sec', 4000);
await jenkins.shot('jenkins-params', 1000);
await jenkins.goto(`${JENKINS}/job/cbom-webapp/${red}/`, 6000);
await jenkins.shot('jenkins-build-red');
await jenkins.goto(`${JENKINS}/job/cbom-webapp/${yellow}/`, 6000);
await jenkins.shot('jenkins-build-yellow');
await jenkins.goto(`${JENKINS}/job/cbom-webapp/${yellow}/${REPORT}/`, 5000);
await jenkins.shot('jenkins-report', 1100);

// 紅色那次的報告本身（不含 Jenkins 的外框），捲到「違規」那一節：看得到每一項違規的位置與原因
await jenkins.goto(`${JENKINS}/job/cbom-webapp/${red}/${REPORT}/index.html`, 4000);
await jenkins.scrollTo('違規');
await jenkins.shot('report-webapp-violations', 1000);

// 4. CBOMkit 網頁 B：首頁的清單，再打開 pipeline 上傳的那一份
const pageB = await openTab();
await pageB.goto(PAGE_B, 6000);
await pageB.shot('cbomkit-b-home');
writeFileSync(join(out, 'cbomkit-b-home.txt'), await pageB.text());
// 清單最上面是最新的一筆（pipeline 上傳的 crypto-lab-webapp）；OPA 每次打開才計算，等久一點
const opened = await pageB.click('cryptographic assets', 25000);
console.log('打開 crypto-lab-webapp：', opened);
await pageB.shot('cbomkit-b-upload');
writeFileSync(join(out, 'cbomkit-b-upload.txt'), await pageB.text());

// 5. CBOMkit 網頁 A：首頁；再打開平台自己掃描的那一份（清單最下面那一筆），拍總覽與資產清單
const pageA = await openTab();
await pageA.goto(PAGE_A, 6000);
await pageA.shot('cbomkit-a-home');
// 清單每一筆有一個「See <筆數> cryptographic assets」的連結；頁面下方的介紹文字也有 cryptographic assets 這幾個字，
// 所以先從頁面文字找出所有連結的完整文字，取最後一個（最舊的一筆＝平台自己掃描的），再點它
const homeText = await pageA.text();
const links = homeText.match(/See d+ cryptographic assets/g) ?? [];
const scanLink = links[links.length - 1] ?? 'See';
const openedScan = await pageA.click(scanLink, 12000);
console.log('打開平台掃描的那一份：', openedScan);
await pageA.shot('cbomkit-overview');
await pageA.scrollTo('List of all assets');
await pageA.shot('cbomkit-list');

// 6. 關掉連線與無頭 Chrome（中途出錯的話這兩行不會執行，要自己在工作管理員結束 chrome.exe）
ws.close();
chrome.kill();
