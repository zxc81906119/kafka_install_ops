// Diagrams for the access design document (PSMP login -> root on the jump host -> one SSH key -> hosts -> sudoers).
// Uses the helpers exported by ../journey-src/diagrams.js; rendered to PNG by ../journey-src/build.js.
const { svg, box, arrow, region, note, P } = require('../journey-src/diagrams')._h;
// company palette: blue family (fill, stroke, text)
P.teal = ['#E6F0FB', '#046BD2', '#0C3486'];
P.blue = ['#F0F5FA', '#325BB2', '#1E293B'];
P.gray = ['#F1F5F9', '#64748B', '#334155'];

const D = {};

// 1. overview: person -> CyberArk -> operations host (root) -> hosts
D.overview = () => svg(780, 300, [
  box(20, 110, 120, 80, '人員', ['維運／安裝', 'AD 帳號'], 'gray'),
  arrow(140, 150, 188, 150, '瀏覽器登入', { ly: 138 }),
  region(190, 20, 190, 260, 'CyberArk（銀行）', 'amber'),
  box(205, 50, 160, 90, 'PVWA（網頁）', ['驗證 AD ＋ MFA', '選目標、啟動連線'], 'amber'),
  box(205, 170, 160, 90, 'PSMP', ['代登、錄影', '取出目標帳號憑證'], 'amber'),
  arrow(285, 142, 285, 168, null),
  arrow(380, 215, 428, 160, '代登', { lx: 410, ly: 205 }),
  box(430, 100, 170, 100, '操作機', ['登入後是 root', '私鑰：root 0400'], 'teal'),
  arrow(600, 150, 628, 150, null),
  region(630, 20, 130, 260, '各主機', 'blue'),
  box(640, 55, 110, 60, 'controller', ['×3'], 'blue'),
  box(640, 130, 110, 60, 'broker', ['×4'], 'blue'),
  box(640, 205, 110, 60, 'REST／C3', ['含操作機自己'], 'blue'),
  note(432, 235, 'ssh 金鑰，不輸入密碼', 12),
  note(432, 255, 'sudo 依白名單，不打密碼', 12),
].join(''));

// 2. lanes: who does what, in order
D.lanes = () => {
  const lanes = [['人員', 'gray'], ['CyberArk', 'amber'], ['操作機', 'teal'], ['各主機', 'blue']];
  const steps = [
    [0, '1 登入 PVWA 網頁'],
    [1, '2 驗證 AD ＋ MFA'],
    [0, '3 選目標、按連線'],
    [1, '4 檢查權限、取憑證'],
    [1, '5 PSMP 代登、錄影'],
    [2, '6 登入後是 root'],
    [2, '7 用私鑰 ssh 各主機'],
    [3, '8 公鑰通過、免密碼'],
    [3, '9 sudo 依白名單'],
  ];
  const lx = (l) => 20 + l * 195, bw = 175, bh = 44, y0 = 70, gap = 60;
  let out = '';
  lanes.forEach(([name, color], l) => {
    out += region(lx(l) - 6, 14, 190, 70 + steps.length * gap, '', color);
    out += box(lx(l), 24, bw, 32, name, [], color);
  });
  steps.forEach(([l, text], i) => {
    out += box(lx(l), y0 + i * gap, bw, bh, text, [], lanes[l][1]);
  });
  for (let i = 0; i < steps.length - 1; i++) {
    const [a] = steps[i], [b] = steps[i + 1];
    const ya = y0 + i * gap + bh, yb = y0 + (i + 1) * gap;
    const xa = lx(a) + bw / 2, xb = lx(b) + bw / 2;
    if (a === b) out += arrow(xa, ya, xb, yb, null);
    else out += arrow(xa, ya, xb, yb, null, { via: [[xa, ya + 8], [xb, ya + 8]] });
  }
  const h = 70 + steps.length * gap + 30;
  return svg(790, h, out);
};

// 3. key pair: create and deploy
D.keydeploy = () => svg(800, 300, [
  box(20, 40, 170, 100, '1 建立金鑰對', ['操作機 root', '產生 ed25519 金鑰對'], 'teal'),
  arrow(190, 90, 218, 90, null),
  box(220, 40, 170, 100, '2 公鑰交給 OS 團隊', ['只有 .pub，不含私鑰', '走變更單'], 'amber'),
  arrow(390, 90, 418, 90, null),
  box(420, 40, 170, 100, '3 放進各主機', ['cpuser 的', 'authorized_keys'], 'amber'),
  arrow(590, 90, 618, 90, null),
  box(620, 40, 160, 100, '4 驗證', ['每台免密碼登入', '身分是 cpuser'], 'teal'),
  box(20, 175, 370, 90, '私鑰', ['只存在操作機獨立的 file system', '加密、權限 0400'], 'coral'),
  box(420, 175, 360, 90, '公鑰', ['每台主機一份，可加 from="操作機 IP"', '限制只有操作機能用這把金鑰'], 'blue'),
].join(''));

// 4. rotation: at every moment one private key works on every host
D.rotate = () => {
  const cols = [
    ['平時', '舊', '舊'],
    ['1 加新公鑰', '舊', '舊＋新'],
    ['2 逐台測新金鑰', '舊＋新', '舊＋新'],
    ['3 換成新私鑰', '新', '舊＋新'],
    ['4 刪舊公鑰', '新', '新'],
  ];
  const x = (i) => 120 + i * 134, w = 124;
  let out = box(10, 70, 100, 70, '操作機', ['私鑰'], 'teal') + box(10, 160, 100, 70, '各主機', ['authorized_keys'], 'blue');
  cols.forEach(([t, pri, pub], i) => {
    out += box(x(i), 14, w, 40, t, [], 'gray');
    out += box(x(i), 70, w, 70, pri, [], pri === '新' ? 'coral' : pri === '舊' ? 'teal' : 'purple');
    out += box(x(i), 160, w, 70, pub, [], pub === '新' ? 'coral' : pub === '舊' ? 'blue' : 'purple');
    if (i < cols.length - 1) out += arrow(x(i) + w + 1, 34, x(i + 1) - 1, 34, null);
  });
  out += box(10, 250, 780, 46, '每個時間點，操作機上至少有一把私鑰能登入全部主機 → 換金鑰不中斷', [], 'amber');
  return svg(800, 310, out);
};

// 5. sudoers: install phase vs delivered
D.sudoers = () => svg(800, 330, [
  region(20, 20, 360, 220, '安裝與升級期', 'amber'),
  box(40, 55, 320, 70, '全權規則', ['/etc/sudoers.d/cpuser', 'cpuser 免密碼執行所有指令'], 'amber'),
  note(40, 160, '範圍：安裝、升級、憑證輪替、controller 替換', 12),
  note(40, 182, '只在變更時段存在，由 OS 團隊管理', 12),
  arrow(380, 130, 418, 130, null),
  note(344, 108, '交付時移除', 12),
  region(420, 20, 360, 220, '交付後（日常維運）', 'teal'),
  box(440, 55, 320, 70, '窄規則', ['/etc/sudoers.d/cpuser-ops（0440）', '免密碼，只列下面三類'], 'teal'),
  note(440, 150, '重啟 confluent 服務', 12),
  note(440, 172, '查看 confluent 服務狀態', 12),
  note(440, 194, '查看 confluent 服務日誌', 12),
  box(20, 260, 760, 54, '要再做安裝或升級：依變更單由 OS 團隊臨時加回全權規則，做完移除', [], 'gray'),
].join(''));

// 6. where the pieces live
D.files = () => svg(800, 300, [
  region(20, 20, 370, 260, '操作機', 'teal'),
  box(40, 55, 330, 60, '/secure/ssh/cpuser_ed25519', ['私鑰，root:root 0400，獨立加密 file system'], 'coral'),
  box(40, 130, 330, 60, '/secure/ssh/cpuser_ed25519.pub', ['公鑰，用來佈署到各主機'], 'teal'),
  region(410, 20, 370, 260, '每台主機（含操作機自己）', 'blue'),
  box(430, 55, 330, 60, '~cpuser/.ssh/authorized_keys', ['公鑰，0600，可加 from='], 'blue'),
  box(430, 130, 330, 60, '/etc/sudoers.d/cpuser', ['安裝期全權，交付時移除'], 'amber'),
  box(430, 205, 330, 60, '/etc/sudoers.d/cpuser-ops', ['交付後窄規則，0440'], 'blue'),
].join(''));

module.exports = D;
