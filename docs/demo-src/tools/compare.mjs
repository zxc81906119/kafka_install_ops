// 同一份 CBOM（pipeline 上傳到 CBOMkit 的那一份）在三個地方的判定對照：
//   pipeline 的 OPA（cbom.rego，六級）、CBOMkit 接 OPA（quantum_safe.rego，四種）、CBOMkit 內建檢查（四種）
// 用法：node docs/demo-src/tools/compare.mjs <findings.json> [專案名稱]
// 先決條件：展示環境在跑，pipeline 已把 CBOM 上傳到 CBOMkit。
//   例：node docs/demo-src/tools/compare.mjs ~/Downloads/findings.json
//
// 誰在哪裡執行：維護 demo 手冊的人，Windows Git Bash（node 20 以上；只用內建功能）。
// 輸入：findings.json＝Jenkins 工作 cbom-webapp 那次執行存下來的檔（執行頁面的 out/findings.json，下載下來）；
//       專案名稱＝CBOM 上傳到 CBOMkit 時用的名稱，不給就是 crypto-lab-webapp（cbom/webapp/Jenkinsfile 寫死的那個）。
// 輸出：只印到畫面：一行標題，再每種組合一行「類型 | pipeline | CBOMkit＋OPA | CBOMkit 內建 | 個數」；不產生檔案。
// 結束碼：0 成功；64 沒給 findings.json；1 檔案讀不到、CBOMkit 連不上或回錯誤、CBOMkit 裡沒有這個專案。
// 這支寫死的值：兩組 CBOMkit API 的 port 28083／28085（cbom/cbomkit-demo/demo.conf 的 BUILTIN_API_PORT、OPA_API_PORT）。
import { existsSync, readFileSync } from 'node:fs';

// 1. 參數
const findingsFile = process.argv[2];
const project = process.argv[3] ?? 'crypto-lab-webapp';
const BUILTIN = 'http://localhost:28083';
const OPA = 'http://localhost:28085';

if (!findingsFile) {
  console.error('用法：node docs/demo-src/tools/compare.mjs <findings.json> [專案名稱]');
  console.error('  findings.json 是 Jenkins 工作 cbom-webapp 那次執行存下來的 out/findings.json');
  process.exit(64);
}

if (!existsSync(findingsFile)) {
  console.error(`找不到檔案 ${findingsFile}：先從 Jenkins 那次執行的頁面下載 out/findings.json`);
  process.exit(1);
}

// 2. pipeline 的判定：每個資產（bom-ref）→ 最嚴重的那一級
//    findings.json 是 opa eval --format json 的完整回應，我們要的東西包在裡面三層：
//      { "result": [ { "expressions": [ { "value": { "findings": [ { "bom-ref": …, "level": … }, … ], … } } ] } ] }
//    result 與 expressions 都只有一筆（只問了 data.cbom.report 這一個問題），所以各取第 0 筆
const report = JSON.parse(readFileSync(findingsFile, 'utf8'));
const value = report.result[0].expressions[0].value;

// 六級由重到輕；一個資產可能中好幾條規則：取最嚴重的那一級（在 order 裡位置比較前面的）
const order = ['violation', 'quantum-vulnerable', 'warning', 'unknown', 'pass', 'info'];
const levelByRef = new Map();
for (const finding of value.findings) {
  const before = levelByRef.get(finding['bom-ref']);
  if (before === undefined || order.indexOf(finding.level) < order.indexOf(before)) {
    levelByRef.set(finding['bom-ref'], finding.level);
  }
}

// check(api)：向一組 CBOMkit 問這個專案的合規檢查（policy 名稱固定是 quantum_safe），回傳它的 JSON
//   回應裡用到的：complianceLevels＝[{ id, label }, …]（等級代號 → 名稱）；findings＝每個資產判成哪個代號
async function check(api) {
  const query = `policyIdentifier=quantum_safe&projectIdentifier=${encodeURIComponent(project)}`;
  const response = await fetch(`${api}/api/v1/compliance/check?${query}`);
  if (!response.ok) {
    throw new Error(`${api} 回 ${response.status}`);
  }

  return response.json();
}

// 3. CBOMkit 裡的那一份 CBOM：最近 20 份裡專案名稱相同的第一份（兩組共用資料庫，問哪一組都一樣）
let stored;
try {
  const response = await fetch(`${OPA}/api/v1/cbom/last/20`);
  stored = await response.json();
} catch (error) {
  console.error(`連不上 CBOMkit（${OPA}）：展示環境要先起來（bash cbom/cbomkit-demo/demo.sh up）`);
  process.exit(1);
}

const entry = stored.find((item) => item.projectIdentifier === project);
if (!entry) {
  console.error(`CBOMkit 裡沒有專案 ${project}`);
  console.error('  先讓 pipeline 上傳（Jenkins 工作的參數 CBOMKIT_URL 要填），或在第二個參數給正確的專案名稱');
  process.exit(1);
}

// 每個元件（bom-ref）→ 類型：密碼學資產用它的 assetType（algorithm、certificate …），其他元件用 type
//   「甲?.乙」：甲不存在時整個當成 undefined，不會出錯；「甲 ?? 乙」：甲是 null 或 undefined 就用乙
const typeByRef = new Map();
for (const component of entry.bom.components) {
  typeByRef.set(component['bom-ref'], component.cryptoProperties?.assetType ?? component.type);
}

// 4. 兩套合規檢查同時問（Promise.all：兩個一起送出，都回來才繼續）
let opa;
let builtin;
try {
  [opa, builtin] = await Promise.all([check(OPA), check(BUILTIN)]);
} catch (error) {
  console.error(`合規檢查失敗：${error.message}（看 log：podman logs demo-opa-api、podman logs demo-builtin-api）`);
  process.exit(1);
}

// resultByRef(回應)：一套檢查的回應 → 每個資產（bom-ref）→ 等級代號
//   欄位名稱照實際的回應是 bomRef 與 levelId；後面幾個「??」是備用的名稱（前一個沒有才用下一個）
function resultByRef(answer) {
  const map = new Map();
  for (const finding of answer.findings ?? []) {
    const ref = finding.bomRef ?? finding['bom-ref'];
    const level = finding.levelId ?? finding.level ?? finding.result;
    map.set(ref, level);
  }

  return map;
}

const opaByRef = resultByRef(opa);
const builtinByRef = resultByRef(builtin);

// label(代號)：等級代號 → 名稱（用 OPA 那一組回的對照表；查不到就把代號原樣當文字）
const labels = new Map();
for (const level of opa.complianceLevels) {
  labels.set(level.id, level.label);
}

function label(id) {
  return labels.get(id) ?? String(id);
}

// 5. 交叉表：資產類型 × pipeline 等級 → CBOMkit 兩套各判成什麼
//    每個資產組出一個「類型 | pipeline 等級 | CBOMkit＋OPA | CBOMkit 內建」的字串當 key，數相同的 key 有幾個
const rows = new Map();
for (const [ref, type] of typeByRef) {
  const pipelineLevel = levelByRef.get(ref) ?? '（沒有發現）';
  const opaLevel = label(opaByRef.get(ref));
  const builtinLevel = label(builtinByRef.get(ref));
  const key = [type, pipelineLevel, opaLevel, builtinLevel].join(' | ');
  rows.set(key, (rows.get(key) ?? 0) + 1);
}

// 照 key 的文字順序印出來
console.log(`\n資產 ${typeByRef.size} 個；類型 | pipeline | CBOMkit＋OPA | CBOMkit 內建 | 個數`);
for (const [key, count] of [...rows].sort()) {
  console.log(`${key} | ${count}`);
}
