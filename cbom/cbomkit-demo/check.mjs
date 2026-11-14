// ============================================================================
// 比較兩套合規檢查對「同一份 CBOM」的結果（bash cbom/cbomkit-demo/demo.sh check 會呼叫這支）
//
//   node check.mjs           比較最新一次掃描 web app 的結果
//   node check.mjs --wait    先等掃描完成（demo.sh scan 用），再比較
//
// 做法：兩組 CBOMkit 共用資料庫，所以向兩邊的 API 問同一份 CBOM 的合規檢查（GET /api/v1/compliance/check），
//       一邊回內建規則的結果，另一邊回 OPA 規則的結果。CBOMkit 不保存合規結果，每次問都是現算的。
// 只用 Node 內建功能（node 20 以上），不需要 npm install。
//
// 誰在哪裡執行：展示的人在 Windows Git Bash，展示環境要先起來（demo.sh up）。
// 輸入：同一個目錄的 demo.conf（兩個 API 的 port、要找的 git 網址）；CBOMkit 兩組 API 的回應。
// 輸出：只印到畫面（一張「等級 × 兩套檢查」的數量表，加兩段舉例），不產生檔案。Demo 手冊引用了這些輸出，文字不要改。
// 結束碼：0 成功；1 CBOMkit 沒在跑、還沒掃描過、等不到掃描結果、或合規檢查回報錯誤（訊息會說下一步）。
// ============================================================================
import { readFileSync } from 'node:fs';

// 讀 demo.conf 的 KEY=value，做成 conf.KEY 可以取值的物件
//   每一行用樣式 /^(\w+)=([^\s#]*)/ 比對：行首的名稱、等號、到空白或 # 為止的值；註解行與空行比不到，略過
//   例：「BUILTIN_UI_PORT=28084       # 網頁 A：內建檢查」→ conf.BUILTIN_UI_PORT = '28084'
const confText = readFileSync(new URL('./demo.conf', import.meta.url), 'utf8');
const conf = {};
for (const line of confText.split('\n')) {
  const found = line.match(/^(\w+)=([^\s#]*)/);
  if (found) {
    conf[found[1]] = found[2];
  }
}

// 兩組 CBOMkit 的 API（在這台機器上的網址）；LEVELS 是 CBOMkit 合規檢查的四種結果，也是表格列的順序
const BUILTIN = `http://localhost:${conf.BUILTIN_API_PORT}`;
const OPA = `http://localhost:${conf.OPA_API_PORT}`;
const LEVELS = ['Not Quantum Safe', 'Quantum Safe', 'Not Applicable', 'Unknown'];

// getJson(網址)：GET 這個網址，把回應的 JSON 轉成物件；HTTP 狀態不是 2xx 就丟出錯誤（訊息帶網址與狀態碼）
async function getJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url} → HTTP ${res.status}`);
  return res.json();
}

// latestScan(notBefore)：最新一份掃描 web app 的 CBOM；沒有就回 undefined
//   notBefore（毫秒的時間）：只接受這個時間之後建立的；不給就是 0，也就是全部都算
//   CBOMkit 回的是最近 20 份 CBOM 的清單，每一份有 gitUrl（掃的是哪個 repo）、createdAt（建立時間）、
//   projectIdentifier（專案名稱）、bom（CBOM 本身）
async function latestScan(notBefore = 0) {
  const stored = await getJson(`${BUILTIN}/api/v1/cbom/last/20`);

  // 只留掃我們那個 git 網址、而且夠新的
  const ours = stored.filter(c => c.gitUrl === conf.GIT_URL && c.createdAt >= notBefore);

  // 照建立時間由新到舊排，取第一份
  ours.sort((a, b) => b.createdAt - a.createdAt);
  return ours[0];
}

// compliance(api, id)：向一組 CBOMkit 問某個專案的合規檢查，回傳一張表：每個資產（bom-ref）→ { level, message }
//   回應的結構：complianceLevels 是 [{ id: 代號, label: 'Not Quantum Safe' }, …]（等級代號 → 名稱），
//               findings 是 [{ bomRef, levelId, message }, …]（每個資產判成哪個代號、原因）
async function compliance(api, id) {
  const query = `policyIdentifier=quantum_safe&projectIdentifier=${encodeURIComponent(id)}`;
  const r = await getJson(`${api}/api/v1/compliance/check?${query}`);
  if (r.error) throw new Error(`${r.complianceServiceName} 回報錯誤，看 CBOMkit API 的 log`);

  // 等級代號 → 名稱
  const label = {};
  for (const level of r.complianceLevels) {
    label[level.id] = level.label;
  }

  // 每個資產 → 等級名稱與原因
  const results = new Map();
  for (const finding of r.findings) {
    results.set(finding.bomRef, { level: label[finding.levelId], message: finding.message });
  }
  return results;
}

// count(results, level)：一套檢查的結果裡，判成這個等級的資產有幾個
function count(results, level) {
  let n = 0;
  for (const result of results.values()) {
    if (result.level === level) {
      n += 1;
    }
  }
  return n;
}

// wait(毫秒)：等這麼久再繼續
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

// ---- 主程式 ----

// 1. 找到要比較的那份 CBOM
let cbom;
try {
  if (process.argv.includes('--wait')) {
    // demo.sh scan 剛送出掃描：只接受「現在往前 5 秒」之後建立的（5 秒是留給送出掃描到這支開始執行之間的時間差），
    // 每 3 秒問一次，最多等 300 秒
    const start = Date.now() - 5000;
    for (let waited = 0; waited < 300; waited += 3) {
      cbom = await latestScan(start);
      if (cbom) {
        break;
      }
      await wait(3000);
    }
    if (!cbom) throw new Error('300 秒內沒有掃描結果，看 log：podman logs demo-builtin-api');
  } else {
    cbom = await latestScan();
    if (!cbom) throw new Error(`還沒有掃描過 ${conf.GIT_URL}：先在網頁 A 掃描，或執行 bash cbom/cbomkit-demo/demo.sh scan`);
  }
} catch (e) {
  // 連線被拒絕（e.cause.code 是 ECONNREFUSED）代表 CBOMkit 沒在跑；其他錯誤印它自己的訊息
  // 「e.cause?.code」的 ?.：e.cause 不存在時整個當成 undefined，不會出錯
  if (e.cause?.code === 'ECONNREFUSED') {
    console.error('CBOMkit 沒在跑：先執行 bash cbom/cbomkit-demo/demo.sh up');
  } else {
    console.error(e.message);
  }
  process.exit(1);
}

// 2. 這份 CBOM 裡的密碼學資產，與兩套檢查各自的結果
const assets = cbom.bom.components.filter(c => c.type === 'cryptographic-asset');
let builtin, opa;
try {
  builtin = await compliance(BUILTIN, cbom.projectIdentifier);
  opa = await compliance(OPA, cbom.projectIdentifier);
} catch (e) {
  // 最常見：OPA 剛重新啟動還沒好，或 Rego 有語法錯誤（podman logs demo-opa 看得到是哪一行）
  console.error(`${e.message}（OPA 的 log：podman logs demo-opa）`);
  process.exit(1);
}

// 3. 數量表：每個等級一列，兩套檢查各判了幾個
//    padEnd(20)：等級名稱後面補空白到 20 個字；padStart(8)、padStart(11)：數字前面補空白，靠右對齊到標題的欄位
console.log(`\nCBOM：${cbom.projectIdentifier}（${assets.length} 個密碼學資產）\n`);
console.log('等級                內建檢查   OPA 檢查');
for (const level of LEVELS) {
  const builtinCount = String(count(builtin, level)).padStart(8);
  const opaCount = String(count(opa, level)).padStart(11);
  console.log(`${level.padEnd(20)}${builtinCount}${opaCount}`);
}

// 4. 舉例：每一類列幾個不同名稱的資產

// ruleOf(o)：從 OPA 的訊息取出我們的規則名稱；訊息裡沒有就回「—」
//   樣式 /Rule '([^：']+)/：「Rule '」後面到全形冒號或單引號為止
//   例：訊息裡有「Rule 'BROKEN：…說明…'」→ 'BROKEN'
function ruleOf(o) {
  const found = o.message.match(/Rule '([^：']+)/);
  if (found) {
    return found[1];
  }
  return '—';
}

// examples(title, which, max)：印一行標題，再列出最多 max 個（預設 3）屬於這一類、名稱不重複的資產
//   which(b, o)：給內建與 OPA 對同一個資產的結果，回答這個資產屬不屬於這一類
//   注意：兩個標題的文字是照目前的規則與掃描結果寫的；規則改了、列出來的東西變了，標題要跟著改
function examples(title, which, max = 3) {
  console.log(`\n${title}`);
  const seen = new Set();
  for (const a of assets) {
    const b = builtin.get(a['bom-ref']);
    const o = opa.get(a['bom-ref']);

    // 兩邊都要有結果、屬於這一類、名稱還沒列過、還沒列滿
    if (!b || !o || !which(b, o) || seen.has(a.name) || seen.size >= max) continue;
    seen.add(a.name);
    console.log(`  ${a.name.padEnd(20)} 內建：${b.level.padEnd(17)} OPA：${o.level}（規則 ${ruleOf(o)}）`);
  }
}

examples('等級不同：對稱加密與雜湊，內建不分類，OPA 判成量子安全', (b, o) => b.level !== o.level);
examples('等級相同、原因不同：已被破解的演算法（內建只說「不分類對稱」，OPA 說出它已被破解）',
  (b, o) => ruleOf(o) === 'BROKEN');
