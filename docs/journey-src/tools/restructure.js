// restructure.js —— 2026-10-28 章節重構（redesign/chapter-restructure.md）的改寫工具。
//   node restructure.js journey <舊 journey.md> <新 journey.md> [報告檔]   重排章節、重編號、改寫內文引用
//   node restructure.js refs <檔案>... [--report 報告檔]                   只改寫其他檔案裡的章節引用（README、問題清單、腳本註解…）
//   node restructure.js map                                                 印出 舊→新 對照（章與節）
// 一次性工具：跑完後留著當對照紀錄，之後的文件都用新編號。
'use strict';
const fs = require('fs');

// ---- 章對照（整章整體搬家時）；分拆／合併的章在 sectionMap 處理 ----
const CHAPTER = { 0: '1', 1: '2', 2: '3', 4: '6', 8: '8', 9: '9', 10: '10', 11: '11', 12: '12', 13: '13', 14: '14', 15: '15', 16: '16', 17: '17', 18: '18', 19: '19', 20: '21', 21: '29', 22: '26', 25: '23', 26: '30', 27: '31' };
// 章變成節（合併進別章）：引用「第 N 章」要改成「N.M 節」
const CHAPTER_TO_SECTION = { 5: '7.1', 6: '7.2', 7: '7.3', 23: '25.1', 24: '25.2' };
// 節層級的特例（搬家、分拆）；沒列的照章對照改第一段數字
const SECTION_SPECIAL = {
  '0.5': 'A', '3.1': '第 4 章',
  '11.2': '20.2', '11.3': '11.2',
  '15.6': '20.3', '15.7': '15.6', '15.8': '20.4',
  '17.9': 'B.1', '17.10': 'B.2',
  '19.6': '20.5',
  '3.2': '5.1', '3.3': '5.2', '3.4': '5.3', '3.5': '5.4',
};
// 舊文件裡每一章實際有的節（避免把版本號、秒數當成章節；由 build 時從文件掃出來）
let KNOWN = null;

function mapSection(id) {
  // id 例：'15.6' '20.2.4' '0.5.3' '3.1.2' '23.4'
  if (SECTION_SPECIAL[id]) return SECTION_SPECIAL[id];
  const p = id.split('.');
  const [c, s, t] = p;
  if (c === '0' && s === '5' && t) return 'A.' + t;             // 0.5.k → A.k
  if (c === '3' && s === '1' && t) return '4.' + t;             // 3.1.k → 4.k
  if (c === '23') return ['25', '1', ...p.slice(1)].join('.');  // 23.k → 25.1.k
  if (c === '24') return ['25', '2', ...p.slice(1)].join('.');  // 24.k → 25.2.k
  const two = c + '.' + s;
  if (t && SECTION_SPECIAL[two]) return SECTION_SPECIAL[two] + '.' + t;   // 20.2.4 等：20→21 走 CHAPTER
  if (CHAPTER[c] !== undefined) return [CHAPTER[c], ...p.slice(1)].join('.');
  throw new Error('no mapping for section ' + id);
}
function mapChapterRef(n) {   // 「第 N 章」→ 文字（可能變成「N.M 節」）；回 null = 要人工判斷
  if (CHAPTER_TO_SECTION[n]) return CHAPTER_TO_SECTION[n] + ' 節';
  if (n === '0' || n === '3') return null;
  if (CHAPTER[n] !== undefined) return '第 ' + CHAPTER[n] + ' 章';
  throw new Error('no mapping for chapter ' + n);
}

// ---- 掃出舊文件的章節清單 ----
function scanKnown(text) {
  const known = new Set(); let fence = false;
  for (const l of text.split('\n')) {
    if (/^```/.test(l)) { fence = !fence; continue; }
    if (fence) continue;
    const m = /^#{2,3} (\d{1,2}(?:\.\d{1,2}){1,2}) /.exec(l);
    if (m) known.add(m[1]);
  }
  return known;
}

// ---- 內文引用改寫：第 N 章／站、N.M（.K）（ 節）；只改舊文件裡真的存在的節 ----
const UNIT_AFTER = /^\s?(秒|GB|MB|KB|TB|ms|倍|%|天|分|x86|版|位|個)/;
const WORD_BEFORE = /(sleep|-t|每|v|V|TLS|Java|JDK|Rocky|RHEL|版本|version|openssl|OpenJDK|Temurin|exporter|CP|C3|Confluent|Platform|Kafka|Grafana|Prometheus|Alertmanager|nginx|Samba|release-version|iterations|rsa:|<|>|<=|>=|==|!=)\s?$/;
// 「第 0 章」「第 3 章」這種分拆過的章，依前後文逐一指定
const MANUAL_FIX = [
  ['免得和第 3 章簽給 ad01 的那張混', '免得和 5.3 節簽給 ad01 的那張混'],
  ['是第 3 章由銀行 OS 團隊', '是第 4 章由銀行 OS 團隊'],
  ['要重跑第 0 章（重建映像、重產 CA）', '要重跑附錄 A（重建映像、重產 CA）'],
  ['重建 lab（第 0 章 `down -v`）', '重建 lab（附錄 A `down -v`）'],
];
function rewriteRefs(text, report, fileLabel) {
  const re = /第 (\d{1,2}) (章|站)|(?<![0-9A-Za-z.])(\d{1,2})\.(\d{1,2})(?:\.(\d{1,2}))?(?![0-9.])( ?節)?/g;
  return text.replace(re, (m, chN, chWord, a, b, c, jie, off) => {
    const before = text.slice(Math.max(0, off - 24), off), after = text.slice(off + m.length, off + m.length + 12);
    const log = (what, out) => report.push(`${fileLabel}\t${what}\t${m}\t→ ${out}\t…${before.replace(/\n/g, '⏎')}【${m}】${after.replace(/\n/g, '⏎')}…`);
    if (chN !== undefined) {
      const out = mapChapterRef(chN);
      if (out === null) { log('MANUAL', m); return m; }
      const res = chWord === '站' && /^第 /.test(out) ? out.replace(' 章', ' 站') : out;
      log('chapter', res); return res;
    }
    const id = c !== undefined ? `${a}.${b}.${c}` : `${a}.${b}`;
    if (!KNOWN.has(id)) return m;                              // 不是舊文件的節（版本號、秒數…）
    if (UNIT_AFTER.test(after) || WORD_BEFORE.test(before)) { log('SKIP-unit', m); return m; }
    let out = mapSection(id);
    if (/^第 /.test(out)) { log('section→chapter', out); return out; }           // 3.1 → 第 4 章（「節」字一併吃掉）
    out = out + (jie || '');
    log('section', out); return out;
  });
}

// ---- 中文數字 ----
const CN = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
const cn = (n) => n < 10 ? CN[n] : n < 20 ? '十' + (n % 10 ? CN[n % 10] : '') : CN[Math.floor(n / 10)] + '十' + (n % 10 ? CN[n % 10] : '');

// ---- 章節重排 ----
function splitChapters(text) {   // → { preamble, chapters: [{num, title, body}] }（body 不含標題行）；code fence 裡的 # 不算
  const lines = text.split('\n'); const chapters = []; let pre = []; let cur = null; let fence = false;
  for (const l of lines) {
    if (/^```/.test(l)) fence = !fence;
    const m = !fence && /^# (\d{1,2})\. (.*)$/.exec(l);
    if (m) { cur = { num: m[1], title: m[2], lines: [] }; chapters.push(cur); continue; }
    (cur ? cur.lines : pre).push(l);
  }
  return { preamble: pre.join('\n'), chapters: chapters.map((c) => ({ ...c, body: c.lines.join('\n') })) };
}
function splitSections(body, level) {   // 依 ## (level 2) 或 ### (level 3) 切：{ intro, sections: [{heading, body}] }
  const lines = body.split('\n'); const sections = []; let intro = []; let cur = null; let fence = false;
  const re = new RegExp('^' + '#'.repeat(level) + ' (.*)$');
  for (const l of lines) {
    if (/^```/.test(l)) fence = !fence;
    const m = !fence && re.exec(l);
    if (m) { cur = { heading: m[1], lines: [] }; sections.push(cur); continue; }
    (cur ? cur.lines : intro).push(l);
  }
  return { intro: intro.join('\n'), sections: sections.map((s) => ({ heading: s.heading, body: s.lines.join('\n') })) };
}
const H = (lvl, id, title) => `${'#'.repeat(lvl)} ${id} ${title}`;
const join = (...parts) => parts.filter((p) => p !== undefined && p !== null && p !== '').join('\n');
const trimBlank = (s) => s.replace(/^\n+/, '').replace(/\n+$/, '');
function sectionTitle(h) { return h.replace(/^\d{1,2}(?:\.\d{1,2}){1,2} /, '').replace(/^[A-Z](?:\.\d{1,2})? /, ''); }
function levelOf(line) { const m = /^(#{2,3}) /.exec(line); return m ? m[1].length : 0; }
function relevel(body, from, to) {   // 把 body 裡 from 層的標題改成 to 層（code fence 不動）
  let fence = false;
  return body.split('\n').map((l) => { if (/^```/.test(l)) fence = !fence; if (!fence && levelOf(l) === from) return '#'.repeat(to) + l.slice(from); return l; }).join('\n');
}

function restructure(oldText, report) {
  KNOWN = scanKnown(oldText);
  const { preamble, chapters } = splitChapters(oldText);
  const byNum = Object.fromEntries(chapters.map((c) => [c.num, c]));
  const need = (n) => { if (!byNum[n]) throw new Error('missing chapter ' + n); return byNum[n]; };
  // 先把每一章的 body 做引用改寫（含 ##/### 標題的編號），之後只搬動、不再改數字
  const R = (s, label) => rewriteRefs(s, report, label);
  const out = [];
  out.push(R(preamble, 'preamble'));

  // 1 開場（舊 0，不含 0.5）
  { const c = need('0'); const S = splitSections(c.body, 2);
    const keep = S.sections.filter((s) => !/^0\.5 /.test(s.heading));
    out.push(H(1, '1.', '開場：小安接到的任務'), R(c.body.split('\n## 0.1 ')[0].replace(/\n+$/, ''), 'ch0 intro'));
    for (const s of keep) out.push(R(H(2, s.heading.split(' ')[0], sectionTitle(s.heading)), 'ch0 h'), R(s.body, 'ch0 ' + s.heading)); }
  // 2、3（舊 1、2）
  for (const [o, n, t] of [['1', '2', '外網下載機'], ['2', '3', '把東西送進銀行']]) { const c = need(o); out.push(H(1, n + '.', `第${cn(+n)}站：${t}`), R(c.body, 'ch' + o)); }
  // 4 主機存取（舊 3.1）、5 銀行要提供的東西（舊 3 的開頭＋3.2–3.5）
  { const c = need('3'); const S = splitSections(c.body, 2);
    const s31 = S.sections.find((s) => /^3\.1 /.test(s.heading)); const rest = S.sections.filter((s) => !/^3\.1 /.test(s.heading));
    const sub = splitSections(s31.body, 3);
    out.push(H(1, '4.', '第四站：主機存取：cpuser 與 SSH 金鑰'), R(trimBlank(sub.intro), 'ch3.1 intro'));
    for (const s of sub.sections) out.push(R(H(2, s.heading.split(' ')[0], sectionTitle(s.heading)), 'ch3.1 h'), R(s.body, 'ch3.1 ' + s.heading));
    out.push(H(1, '5.', '第五站：銀行準備好了嗎：套件庫、JDK、AD、NTP、負載平衡'), R(trimBlank(S.intro), 'ch3 intro'));
    for (const s of rest) out.push(R(H(2, s.heading.split(' ')[0], sectionTitle(s.heading)), 'ch3 h'), R(s.body, 'ch3 ' + s.heading)); }
  // 6 上架（舊 4）
  { const c = need('4'); out.push(H(1, '6.', '第六站：上架到內部套件庫'), R(c.body, 'ch4')); }
  // 7 主機準備（舊 5、6、7）
  { out.push(H(1, '7.', '第七站：主機準備：JDK、安裝前檢查、OS 調校'), '', '**這一章在做什麼**：在 11 台主機上把 Confluent 需要的環境準備好：裝 JDK 21、確認 DNS／套件庫／AD／時間都通、調 OS 參數。三節各自獨立，但順序要照這個來（檢查用得到 JDK 與套件庫）。');
    for (const [o, k, t] of [['5', '7.1', 'JDK 21'], ['6', '7.2', '安裝前檢查'], ['7', '7.3', 'OS 調校']]) { const c = need(o); out.push('', H(2, k, t), R(trimBlank(c.body), 'ch' + o)); } }
  // 8–13 原樣
  for (const [n, t] of [['8', '安裝 Confluent 套件'], ['9', '憑證'], ['10', 'controller 與 broker'], ['11', '帳號與權限'], ['12', 'REST Proxy'], ['13', 'Control Center']]) {
    const c = need(n); let body = c.body;
    if (n === '11') { const S = splitSections(body, 2); const keep = S.sections.filter((s) => !/^11\.2 /.test(s.heading)); body = join(S.intro, ...keep.map((s) => join(H(2, s.heading.split(' ')[0], sectionTitle(s.heading)), s.body))); }
    out.push(H(1, n + '.', `第${cn(+n)}站：${t}`), R(body, 'ch' + n)); }
  // 14 改名
  { const c = need('14'); out.push(H(1, '14.', '第十四站：基本功能驗收（小安的檢查清單）'), R(c.body, 'ch14')); }
  // 15（拿掉 15.6、15.8）、16、17（拿掉 17.9、17.10）、18、19（拿掉 19.6）
  const moved = {};
  for (const [n, t, drop] of [['15', 'Secret Protection，加密設定檔裡的密碼', ['15.6', '15.8']], ['16', '維運選單（OP menu）', []], ['17', '監控（JMX exporter，行內 Prometheus、Alertmanager、Grafana）', ['17.9', '17.10']], ['18', '稽核日誌（audit log）', []], ['19', '驛收與收尾', ['19.6']]]) {
    const c = need(n); const S = splitSections(c.body, 2);
    const keep = []; for (const s of S.sections) { const id = s.heading.split(' ')[0]; if (drop.includes(id)) moved[id] = s; else keep.push(s); }
    const body = join(S.intro, ...keep.map((s) => join(H(2, s.heading.split(' ')[0], sectionTitle(s.heading)), s.body)));
    out.push(H(1, n + '.', `第${cn(+n)}站：${t.replace('驛收', '驗收')}`), R(body, 'ch' + n)); }
  { const c = need('11'); const S = splitSections(c.body, 2); moved['11.2'] = S.sections.find((s) => /^11\.2 /.test(s.heading)); }
  // 20 密碼與金鑰輪替（新）：總表 ＋ 舊 11.2、15.6、15.8、19.6
  out.push(H(1, '20.', '第二十站：密碼與金鑰輪替'), '',
    '**這一章在做什麼**：把平台上所有「會過期、會外洩、要定期換」的密碼與金鑰集中在一章：什麼時候換、誰換、怎麼換到不中斷。憑證另成一章（第 21 章）。每一節都是在 lab 實跑過的演練，正式環境依變更單執行。', '',
    '## 20.1 總表：什麼、多久、誰做', '',
    '| 項目 | 放在哪 | 多久換一次 | 誰做 | 怎麼換 |', '|---|---|---|---|---|',
    '| 緊急 SCRAM 帳號 `kafka-admin` 的密碼 | 操作機 `~/secrets/kafka-admin.pass` | 每次用過就換 | 平台工程師 | 20.2 |',
    '| Secret Protection 的 master key（與 passphrase） | 操作機 `~/secrets`、各主機 `service.env` | 每年；保管人異動 | 平台工程師 | 20.3 |',
    '| AD 查詢帳號 `svc-mds-bind` 的密碼 | AD；密文在各主機 `security.properties` | 依銀行 AD 規範；換前一定要通知平台 | AD 團隊換、平台更新密文 | 20.4 |',
    '| 操作機到各主機的 SSH 金鑰 | 操作機 `/secure/ssh` | 依銀行規範（待確認）；操作機重建 | 平台工程師＋OS 團隊 | 20.5 |',
    '| 應用程式的 SCRAM 密碼 | 操作機產生、交應用程式團隊 | 依應用程式團隊 | 維運選單 34／35（A／B 兩組不中斷） | 第 16 章 |',
    '| 服務憑證（kafka-internal、cp-server…）與 client 憑證 | 操作機 `~/pki` | 一年（CA 簽發效期） | 平台工程師＋CA | 第 21 章 |',
    '| MDS token 金鑰對 | 各主機 `mds-token-keypair.pem` | 不排輪替，只在外洩時換 | 平台工程師 | 不在本手冊（見設計紀錄） |', '');
  for (const [id, newId, t] of [['11.2', '20.2', '緊急帳號 kafka-admin 用過就換密碼'], ['15.6', '20.3', '輪替 master key'], ['15.8', '20.4', 'AD 查詢帳號的密碼換了'], ['19.6', '20.5', '換 SSH 金鑰（人工、不中斷）']]) {
    const s = moved[id]; if (!s) throw new Error('moved section missing ' + id);
    out.push(H(2, newId, t), R(s.body, 'moved ' + id)); }
  // 21 憑證輪替（舊 20）
  { const c = need('20'); out.push(H(1, '21.', '第二十一站：憑證輪替'), R(c.body, 'ch20')); }
  // 22 憑證到期監控（新，待補）
  out.push(H(1, '22.', '第二十二站：憑證到期監控（選配）'), '', '**這一章在做什麼**（待補）：用銀行 Prometheus 的 blackbox_exporter 探每個 TLS 端點實際出示的憑證，剩 60 天告警、剩 30 天升級；操作機每天另跑一支小腳本讀 `~/pki/certs/*.crt` 的到期日（涵蓋我方持有、不對外的 client 憑證）。客戶目前沒有這段，列為建議；寫法、lab 驗證與腳本見 `redesign/README.md`「憑證到期監控」。', '');
  // 23 備份與還原（舊 25 ＋ 待補的還原）
  { const c = need('25'); out.push(H(1, '23.', '第二十三站：日常備份與還原'), R(c.body, 'ch25'), '', '## 23.6 還原演練（待補）', '', '**這一節在做什麼**（待補）：把 23.3 匯出的中繼資料（RBAC、ACL、topic 與設定、SCRAM 帳號清單、配額）還原到一個乾淨的叢集並驗證。先手動在 lab 走一次，再做成腳本。', ''); }
  // 24 磁碟與容量（新，待補）
  out.push(H(1, '24.', '第二十四站：磁碟與容量'), '', '**這一章在做什麼**（待補）：broker 資料盤使用率的告警（第 17 章的規則補一條）、快滿時怎麼處理（retention、搬 partition）、換資料碟與擴容的程序。先手動在 lab 走一次，再做成腳本。', '');
  // 25 節點更換與增減（舊 23、24）
  { const c23 = need('23'), c24 = need('24');
    out.push(H(1, '25.', '第二十五站：節點更換與增減'), '', '**這一章在做什麼**：兩種會動到叢集成員的作業：換掉一台 controller（25.1）、縮減與擴充 broker（25.2）。兩者都在服務不中斷的前提下做，應用程式不用改設定。');
    for (const [c, k, t] of [[c23, '25.1', '換掉一台 controller'], [c24, '25.2', 'broker 縮減與擴充']]) {
      const S = splitSections(c.body, 2);
      out.push('', H(2, k, t), R(trimBlank(S.intro), 'ch' + c.num + ' intro'));
      for (const s of S.sections) out.push('', R(H(3, s.heading.split(' ')[0], sectionTitle(s.heading)), 'ch' + c.num + ' h'), R(s.body, 'ch' + c.num + ' ' + s.heading)); } }
  // 26 License（舊 22）
  { const c = need('22'); out.push(H(1, '26.', '第二十六站：License 到期監控與每日檢查'), R(c.body, 'ch22')); }
  // 27、28（新，待補）
  out.push(H(1, '27.', '第二十七站：新應用上線'), '', '**這一章在做什麼**（待補）：一個新應用程式從申請到上線的完整流程：topic 命名與建立、SCRAM 帳號或 client 憑證、RBAC／ACL、配額、交付密碼或憑證給應用程式團隊、驗證讀寫；日常用維運選單（第 16 章）的 31／34／42 做，這一章把流程串起來。', '');
  out.push(H(1, '28.', '第二十八站：故障排查速查'), '', '**這一章在做什麼**（待補）：常見症狀對應「看哪個指標、跑哪個指令、怎麼處理」：broker 離線、ISR 縮小、leader 選舉卡住、under-replicated 不歸零、憑證過期、AD 不通、MDS 起不來、C3 畫面空白、REST 經 LB 失敗、磁碟滿。', '');
  // 29 遷移（舊 21）、30 OS（舊 26）、31 C3（舊 27）
  for (const [o, n, t] of [['21', '29', '遷移到新版 Confluent 與 JDK'], ['26', '30', 'OS 修補與小版本更新'], ['27', '31', '單獨更換 Control Center 版本']]) { const c = need(o); out.push(H(1, n + '.', `第${cn(+n)}站：${t}`), R(c.body, 'ch' + o)); }
  // 附錄 A 建 lab（舊 0.5）
  { const c = need('0'); const S = splitSections(c.body, 2); const s05 = S.sections.find((s) => /^0\.5 /.test(s.heading)); const sub = splitSections(s05.body, 3);
    out.push(H(1, 'A.', '附錄 A：自己把 lab 建起來'), R(trimBlank(sub.intro), 'ch0.5 intro'));
    for (const s of sub.sections) out.push(R(H(2, s.heading.split(' ')[0], sectionTitle(s.heading)), 'ch0.5 h'), R(s.body, 'ch0.5 ' + s.heading)); }
  // 附錄 B 監控覆蓋率與 lab 收尾（舊 17.9、17.10）
  out.push(H(1, 'B.', '附錄 B：監控的覆蓋率，與 lab 監控容器的收尾'), '', '這兩節是第 17 章的延伸：B.1 量官方 dashboard 在我們這套元件上有多少 panel 有資料（給銀行監控團隊參考），B.2 是 lab 專用的收尾（正式環境的 Prometheus 是銀行的，不收）。放在最後，是因為量覆蓋率要等整條路（含遷移）跑完才有完整的數字。');
  for (const [id, newId, t] of [['17.9', 'B.1', '哪些 dashboard 與 panel 有資料'], ['17.10', 'B.2', '收尾：收掉 lab 的監控容器']]) { const s = moved[id]; out.push('', H(2, newId, t), R(s.body, 'moved ' + id)); }
  return out.join('\n').replace(/\n{3,}/g, '\n\n') + '\n';
}

// ---- main ----
const [, , mode, ...args] = process.argv;
if (mode === 'map') {
  console.log('章：', JSON.stringify(CHAPTER), '\n章→節：', JSON.stringify(CHAPTER_TO_SECTION), '\n節特例：', JSON.stringify(SECTION_SPECIAL, null, 0));
} else if (mode === 'journey') {
  const [inp, outp, rep] = args; const report = [];
  const text = fs.readFileSync(inp, 'utf8');
  let result = restructure(text, report);
  for (const [x, y] of MANUAL_FIX) { if (result.split(x).length !== 2) throw new Error('MANUAL_FIX not unique: ' + x); result = result.replace(x, () => y); }
  fs.writeFileSync(outp, result);
  if (rep) fs.writeFileSync(rep, report.join('\n') + '\n');
  const counts = {}; for (const r of report) { const k = r.split('\t')[1]; counts[k] = (counts[k] || 0) + 1; }
  console.log('wrote', outp, 'rewrites:', JSON.stringify(counts));
} else if (mode === 'refs') {
  const ri = args.indexOf('--report'); const rep = ri >= 0 ? args[ri + 1] : null; const files = args.filter((a, i) => a !== '--report' && i !== ri + 1);
  const known = args.indexOf('--known'); // 用舊 journey.md 掃節清單：node restructure.js refs --known old.md 檔案…
  if (known >= 0) { KNOWN = scanKnown(fs.readFileSync(args[known + 1], 'utf8')); files.splice(files.indexOf('--known'), 2); } else throw new Error('refs 要帶 --known <舊 journey.md>');
  const report = [];
  for (const f of files) { const s = fs.readFileSync(f, 'utf8'); const t = rewriteRefs(s, report, f); if (t !== s) fs.writeFileSync(f, t); }
  if (rep) fs.writeFileSync(rep, report.join('\n') + '\n');
  const counts = {}; for (const r of report) { const k = r.split('\t')[1]; counts[k] = (counts[k] || 0) + 1; }
  console.log('files:', files.length, 'rewrites:', JSON.stringify(counts));
} else { console.error('usage: restructure.js journey|refs|map …'); process.exit(1); }
