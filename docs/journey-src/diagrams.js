// Diagrams for the journey guide: small SVG helpers -> PNG (rendered by build.js with resvg).
const FONT = 'Microsoft JhengHei';
const P = { // palette (light fills, strong strokes, dark text)
  teal: ['#E1F5EE', '#0F6E56', '#085041'], amber: ['#FAEEDA', '#BA7517', '#633806'],
  gray: ['#F1EFE8', '#888780', '#444441'], purple: ['#EEEDFE', '#534AB7', '#3C3489'],
  blue: ['#E6F1FB', '#185FA5', '#0C447C'], coral: ['#FAECE7', '#993C1D', '#712B13'],
};
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function svg(w, h, body) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" font-family="${FONT}">
<defs><marker id="a" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M2 1L8 5L2 9" fill="none" stroke="#444441" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></marker></defs>
<rect width="${w}" height="${h}" fill="#FFFFFF"/>${body}</svg>`;
}
// box with title (+ up to 2 subtitle lines)
function box(x, y, w, h, title, subs = [], color = 'teal', opts = {}) {
  const [fill, stroke, text] = P[color];
  const cx = x + w / 2;
  const lines = [title, ...subs];
  const total = 20 + subs.length * 16;
  let ty = y + h / 2 - total / 2 + 10;
  let out = `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${opts.rx ?? 8}" fill="${fill}" stroke="${stroke}" stroke-width="1" ${opts.dash ? 'stroke-dasharray="5 4"' : ''}/>`;
  lines.forEach((t, i) => {
    out += `<text x="${cx}" y="${ty}" text-anchor="middle" dominant-baseline="central" font-size="${i ? 12 : 14}" font-weight="${i ? 400 : 700}" fill="${i ? stroke : text}">${esc(t)}</text>`;
    ty += i ? 16 : 20;
  });
  return out;
}
function arrow(x1, y1, x2, y2, label, opts = {}) {
  const pts = opts.via ? `M${x1} ${y1} ${opts.via.map(([x, y]) => `L${x} ${y}`).join(' ')} L${x2} ${y2}` : `M${x1} ${y1} L${x2} ${y2}`;
  let out = `<path d="${pts}" fill="none" stroke="${opts.color || '#444441'}" stroke-width="2.5" ${opts.dash ? 'stroke-dasharray="5 4"' : ''} marker-end="url(#a)"/>`;
  if (label) {
    const lx = opts.lx ?? (x1 + x2) / 2, ly = opts.ly ?? (y1 + y2) / 2 - 8;
    out += `<text x="${lx}" y="${ly}" text-anchor="middle" font-size="11" fill="#5F5E5A">${esc(label)}</text>`;
  }
  return out;
}
function region(x, y, w, h, label, color = 'gray') {
  const [, stroke, text] = P[color];
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="14" fill="none" stroke="${stroke}" stroke-width="1" stroke-dasharray="6 4"/>
<text x="${x + 14}" y="${y + 18}" font-size="13" font-weight="700" fill="${text}">${esc(label)}</text>`;
}
function note(x, y, text, size = 12) { return `<text x="${x}" y="${y}" font-size="${size}" fill="#5F5E5A">${esc(text)}</text>`; }
function legend(x, y, items) {
  let out = '', cx = x;
  for (const [color, label] of items) {
    const [fill, stroke] = P[color];
    out += `<rect x="${cx}" y="${y - 10}" width="14" height="14" rx="3" fill="${fill}" stroke="${stroke}"/>` + note(cx + 20, y + 1, label);
    cx += 24 + label.length * 13 + 24;
  }
  return out;
}

// free text (centered by default), numbered badge, heavy outline (for "the one that matters")
function ctext(x, y, t, o = {}) {
  return `<text x="${x}" y="${y}" text-anchor="${o.anchor || 'middle'}" dominant-baseline="central" font-size="${o.size || 12}" font-weight="${o.bold ? 700 : 400}" fill="${o.fill || '#5F5E5A'}">${esc(t)}</text>`;
}
function num(x, y, n, color = 'teal') {
  const [fill, stroke, text] = P[color];
  return `<circle cx="${x}" cy="${y}" r="11" fill="${stroke}"/><text x="${x}" y="${y}" text-anchor="middle" dominant-baseline="central" font-size="12" font-weight="700" fill="#FFFFFF">${esc(n)}</text>`;
}
function outline(x, y, w, h, color = 'blue', sw = 3, rx = 8) {
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${rx}" fill="none" stroke="${P[color][1]}" stroke-width="${sw}"/>`;
}

const D = {};

// 1. cast: our side vs bank side
D.cast = () => svg(760, 300, [
  region(20, 20, 300, 260, '我方（安裝團隊）', 'teal'),
  box(40, 60, 260, 56, '小安', ['新進安裝工程師，本篇主角', '所有「我方」指令由他敲'], 'teal'),
  box(40, 130, 260, 56, '操作機 ops02', ['小安工作的地方（root，連主機用 cpuser）', '安裝、設定、驗證都從這裡出發'], 'teal'),
  box(40, 200, 260, 56, '下載機 dl01', ['唯一能連外網的機器', '只用來下載與驗證'], 'teal'),
  region(360, 20, 380, 260, '銀行端（行內各團隊）', 'amber'),
  box(380, 60, 160, 56, 'OS 團隊', ['開主機、套件來源', 'JDK、帳號、sudo'], 'amber'),
  box(560, 60, 160, 56, 'AD 團隊', ['人員群組', '唯讀查詢帳號'], 'amber'),
  box(380, 130, 160, 56, 'CA 窗口', ['簽發憑證', '提供根憑證'], 'amber'),
  box(560, 130, 160, 56, '套件庫管理員', ['內部套件庫 repo01', 'NTP、負載平衡'], 'amber'),
  box(380, 200, 340, 56, '練習時這些角色由誰扮演？', ['lab 裡都是你自己，看到「銀行」標籤就切換身分', '指令一樣要敲，才不會卡住'], 'gray'),
].join(''));

// 2. environment map
D.map = () => svg(760, 400, [
  region(20, 20, 720, 110, '外網', 'gray'),
  box(40, 55, 170, 56, '下載機 dl01', ['Rocky 9，可連 Internet', '/out = 落地區'], 'teal'),
  box(260, 55, 220, 56, 'packages.confluent.io', ['Confluent 原廠 RPM 倉庫'], 'gray'),
  box(520, 55, 200, 56, 'repo1.maven.org、GitHub', ['JMX jar、官方監控檔'], 'gray'),
  arrow(210, 83, 258, 83), arrow(480, 83, 518, 83),
  region(20, 150, 720, 230, '行內（離線）', 'amber'),
  box(40, 190, 150, 56, '操作機 ops02', ['root（PSMP 登入）', '安裝起點'], 'teal'),
  box(40, 300, 150, 56, 'repo01', ['套件庫 web server', 'NTP'], 'amber'),
  box(220, 190, 160, 56, 'controller ×3', ['kc01 kc02 kc03'], 'blue'),
  box(220, 300, 160, 56, 'broker ×4', ['kb01 kb02 kb03 kb04'], 'blue'),
  box(410, 190, 150, 56, 'REST Proxy ×2', ['rest01 rest02'], 'blue'),
  box(410, 300, 150, 56, 'Control Center', ['c3-01'], 'blue'),
  box(590, 190, 130, 56, 'AD ad01', ['LDAPS 636'], 'amber'),
  box(590, 300, 130, 56, 'LB lb01', ['rest.poc.lab'], 'amber'),
  arrow(190, 218, 218, 218), arrow(190, 236, 218, 318, null, { via: [[205, 236], [205, 318]] }),
  arrow(380, 218, 408, 218), arrow(380, 328, 408, 328),
  note(40, 372, '落地區從下載機搬進來（檔案交換平台）→ 操作機 → 上架 repo01 → 各主機從 repo01 安裝'),
].join(''));

// 3. journey overview (5 stages)
D.journey = () => svg(760, 310, [
  box(20, 40, 130, 70, '2 下載與驗證', ['下載機', 'RPM、jar、公鑰、雜湊'], 'teal'),
  box(175, 40, 130, 70, '3 引進內網', ['掃描、開單', '搬到操作機'], 'amber'),
  box(330, 40, 130, 70, '4 主機存取', ['cpuser、一把金鑰', 'from=、sudoers'], 'amber'),
  box(485, 40, 130, 70, '5–6 行內準備、上架', ['套件庫、AD、CA、JDK', 'RPM 上架'], 'amber'),
  box(640, 40, 100, 70, '7–13 安裝', ['操作機出發', '11 台'], 'blue'),
  arrow(150, 75, 173, 75), arrow(305, 75, 328, 75), arrow(460, 75, 483, 75), arrow(615, 75, 638, 75),
  box(20, 140, 230, 56, '7–8 主機就緒', ['JDK、檢查、OS 調校、裝套件'], 'blue'),
  box(265, 140, 230, 56, '9–10 憑證與設定', ['CSR → 銀行簽 → 設定檔'], 'blue'),
  box(510, 140, 230, 56, '10–14 啟動與驗證', ['controller → broker → REST → C3'], 'blue'),
  arrow(250, 168, 263, 168), arrow(495, 168, 508, 168),
  box(20, 222, 400, 56, '15–19 延伸與交付', ['加密設定檔密碼、維運選單、監控、稽核日誌、驗收'], 'purple'),
  box(440, 222, 300, 56, '20–31 上線之後', ['輪替、憑證、備份、換機、license、遷移、修補'], 'gray'),
  arrow(625, 196, 215, 220, null, { via: [[625, 208], [215, 208]] }), arrow(420, 250, 438, 250),
  legend(20, 298, [['teal', '我方'], ['amber', '銀行'], ['blue', '我方，在行內主機上'], ['purple', '延伸'], ['gray', '上線後']]),
].join(''));

// 4. download + verify
D.download = () => svg(760, 250, [
  box(20, 30, 200, 60, '設定 repo、匯入公鑰', ['confluent.repo', 'rpm --import'], 'teal'),
  box(260, 30, 220, 60, 'dnf download --resolve', ['指定精確版本', '相依自動帶入'], 'teal'),
  box(520, 30, 220, 60, '兩套各 11 個 RPM', ['基底 8.2.4／目標 8.3.2', '全部 confluent-*，各約 3 GB'], 'teal'),
  arrow(220, 60, 258, 60), arrow(480, 60, 518, 60),
  box(20, 130, 200, 60, 'rpm -K 驗簽章', ['每個都要 OK', '非 Confluent 相依只有 bash'], 'teal'),
  box(260, 130, 220, 60, 'jar、OS 套件清單', ['Maven sha1、官方監控檔', 'os-packages.txt'], 'teal'),
  box(520, 130, 220, 60, 'SHA256SUMS', ['72 個檔案的雜湊', '之後每一關都用它'], 'teal'),
  arrow(630, 90, 120, 128, null, { via: [[630, 110], [120, 110]] }), arrow(220, 160, 258, 160), arrow(480, 160, 518, 160),
  note(20, 225, '只帶 Confluent 的東西（RPM、監控檔）；JDK、OS 套件不下載，列清單交給銀行'),
].join(''));

// 5. into the bank + publish
D.intake = () => svg(760, 220, [
  box(20, 40, 170, 60, '落地區', ['下載機 /out', '72 個檔案'], 'teal'),
  box(230, 40, 170, 60, '掃描平台、開單', ['附 SHA256SUMS', '與驗證報告'], 'amber'),
  box(440, 40, 150, 60, '檔案交換', ['搬到操作機', '~/landing 唯讀'], 'amber'),
  box(630, 40, 110, 60, '再驗一次', ['sha256sum -c', 'rpm -K'], 'teal'),
  arrow(190, 70, 228, 70), arrow(400, 70, 438, 70), arrow(590, 70, 628, 70),
  box(230, 130, 230, 60, '建索引 createrepo_c', ['操作機 ~/repo/confluent'], 'teal'),
  box(500, 130, 240, 60, '上架 repo01', ['ssh + tar 推給 repodeploy', 'https://repo01/confluent/'], 'teal'),
  arrow(685, 100, 345, 128, null, { via: [[685, 115], [345, 115]] }), arrow(460, 160, 498, 160),
  note(20, 212, 'repo01 已有銀行自己維護的 /os/（JDK 之外的 OS 套件）；Confluent 放在 /confluent/'),
].join(''));

// 6. bank preparation
D.bankprep = () => svg(760, 300, [
  region(20, 20, 720, 260, '銀行端在安裝前要備妥的六件事（lab 裡由你扮演）', 'amber'),
  box(40, 60, 220, 60, '主機與帳號', ['11 台 RHEL 9.6 最小安裝', 'cpuser + SSH 公鑰 + sudo'], 'amber'),
  box(280, 60, 220, 60, 'OS 套件來源', ['repo01 /os/：chrony、firewalld', 'C3 前置、工具'], 'amber'),
  box(520, 60, 200, 60, 'JDK 21 與 25', ['兩個 tar 交付到操作機', '21 先裝、25 遷移時用'], 'amber'),
  box(40, 140, 220, 60, 'AD', ['群組 kafka-admins/operators/devs', '唯讀帳號 svc-mds-bind'], 'amber'),
  box(280, 140, 220, 60, '憑證', ['根憑證放進每台信任清單', 'CSR 來就簽'], 'amber'),
  box(520, 140, 200, 60, 'NTP、負載平衡', ['repo01 兼 NTP', 'lb01 → rest01/rest02'], 'amber'),
  box(40, 220, 680, 44, '安裝前檢查（第 5a 段）會逐項確認這些都到位；沒到位就先回頭找對應的銀行團隊', [], 'gray'),
].join(''));

// 7. certificate flow
D.certs = () => svg(760, 240, [
  box(20, 40, 170, 60, '產生私鑰 + CSR', ['操作機 ~/pki', '私鑰不離開行內'], 'teal'),
  box(230, 40, 150, 60, '銀行 CA 簽發', ['政策檢查 EKU/SAN', '回「憑證+中繼」'], 'amber'),
  box(420, 40, 160, 60, '匯入前檢查', ['私鑰相符、CN、SAN', 'EKU、效期、鏈'], 'teal'),
  box(620, 40, 120, 60, 'PKCS12', ['.p12 keystore', 'truststore'], 'teal'),
  arrow(190, 70, 228, 70), arrow(380, 70, 418, 70), arrow(580, 70, 618, 70),
  box(20, 140, 340, 60, '9 張：kafka-internal、cp-server', ['svc-rest、svc-c3、c3-monitoring、svc-ops、svc-backup', 'app-legacy-billing、opmenu-breakglass'], 'gray'),
  box(400, 140, 340, 60, '另外一組 MDS token 金鑰對', ['RSA 2048，不經銀行', '私鑰給 broker，公鑰給驗 token 的人'], 'gray'),
  note(20, 225, '任何一項檢查不過就退回銀行重簽，不往下做'),
].join(''));

// 8. files on a broker
D.hostfiles = () => svg(800, 300, [
  region(20, 20, 380, 260, 'broker 主機上我們放的東西', 'blue'),
  box(40, 55, 340, 44, '/etc/confluent/ssl/', ['truststore、kafka-internal、cp-server.p12、MDS 金鑰'], 'blue'),
  box(40, 110, 340, 44, '/etc/confluent/kafka/server.properties', ['root:confluent 0640，含 LDAP 綁定密碼'], 'blue'),
  box(40, 165, 340, 44, 'systemd drop-in：10-override.conf', ['/etc/systemd/system/confluent-server.service.d/'], 'blue'),
  box(40, 220, 340, 44, '/var/lib/kafka/data', ['cp-kafka:confluent 0750，格式化後有 meta.properties'], 'blue'),
  region(420, 20, 360, 260, 'RPM 自己放的（不要改）', 'gray'),
  box(435, 55, 330, 44, '/usr/bin/kafka-*', ['指令工具'], 'gray'),
  box(435, 110, 330, 44, '/etc/kafka/', ['RPM 預設設定、log4j2.yaml'], 'gray'),
  box(435, 165, 330, 44, '原廠 systemd unit，用 drop-in 覆寫', ['/usr/lib/systemd/system/confluent-server.service'], 'gray'),
  box(435, 220, 330, 44, '服務帳號 cp-kafka、群組 confluent', ['RPM 安裝時建立'], 'gray'),
].join(''));

// 9. start order
D.startup = () => svg(760, 200, [
  box(20, 40, 160, 64, '格式化儲存', ['controller 帶 initial', 'broker 觀察者'], 'blue'),
  box(215, 40, 150, 64, '啟動 controller', ['3 台', 'quorum 有 leader'], 'blue'),
  box(400, 40, 150, 64, '啟動 broker', ['4 台', 'MDS 回 200'], 'blue'),
  box(585, 40, 155, 64, 'REST → C3', ['先 REST 再 C3', '各自健康檢查'], 'blue'),
  arrow(180, 72, 213, 72), arrow(365, 72, 398, 72), arrow(550, 72, 583, 72),
  box(20, 130, 720, 44, '每一段都要確認健康才做下一段；啟動前先看 systemctl show -p ExecStart 指向我們的設定檔', [], 'coral'),
].join(''));

// 10. identities
D.identity = () => svg(760, 260, [
  box(20, 30, 200, 60, '人員', ['AD 帳密', '權限綁 AD 群組'], 'gray'),
  box(20, 110, 200, 60, '應用程式（直連）', ['SCRAM 帳密', 'app-orders、app-payments'], 'gray'),
  box(20, 190, 200, 60, '應用程式（經 REST）', ['client 憑證', 'app-legacy-billing'], 'gray'),
  box(300, 30, 180, 60, 'MDS（在 broker 上）', ['向 AD 查人員與群組', '發 token'], 'blue'),
  box(300, 110, 180, 60, 'broker CLIENT 9095', ['SCRAM-SHA-512'], 'blue'),
  box(300, 190, 180, 60, 'REST Proxy 8082', ['只收憑證，對應 principal'], 'blue'),
  box(560, 30, 180, 60, 'C3 / 操作機工具', ['帶 token 進 TOKEN 9094'], 'blue'),
  box(560, 110, 180, 60, '平台服務', ['svc-rest、svc-c3、svc-ops', '憑證換 token，不在 AD'], 'blue'),
  box(560, 190, 180, 60, 'kafka-admin', ['SCRAM，緊急備用', 'MDS 壞了才用'], 'coral'),
  arrow(220, 60, 298, 60), arrow(220, 140, 298, 140), arrow(220, 220, 298, 220),
  arrow(480, 60, 558, 60), arrow(480, 140, 558, 140, null, { dash: true }),
].join(''));

// 11. REST and C3 paths
D.edge = () => svg(760, 210, [
  box(20, 40, 150, 60, 'legacy app', ['帶 client 憑證'], 'gray'),
  box(210, 40, 150, 60, 'LB rest.poc.lab', ['L4 passthrough', 'TLS 不在這裡終結'], 'amber'),
  box(400, 40, 150, 60, 'REST Proxy', ['驗憑證 → principal', 'svc-rest 代理身分'], 'blue'),
  box(590, 40, 150, 60, 'broker TOKEN 9094', ['以 app 身分執行'], 'blue'),
  arrow(170, 70, 208, 70), arrow(360, 70, 398, 70), arrow(550, 70, 588, 70),
  box(20, 130, 150, 60, '維運人員', ['瀏覽器，AD 帳密'], 'gray'),
  box(400, 130, 150, 60, 'Control Center', ['直連 9021', 'svc-c3 憑證連 MDS'], 'blue'),
  arrow(170, 160, 398, 160, '不經負載平衡'),
  box(590, 130, 150, 60, 'Prometheus 9090', ['mTLS，收 broker 指標'], 'blue'),
  arrow(550, 160, 588, 160),
].join(''));

// 13. Secret Protection: passphrase and master key stay on the ops host (root, 0600); nothing is vaulted
D.secretprotection = () => svg(800, 300, [
  region(20, 28, 250, 262, "操作機 ~/secrets（root、0600）", "amber"),
  box(36, 60, 218, 62, "passphrase", ["工程師在操作機產生", "sp-passphrase.txt；輪替時要舊的"], "amber"),
  box(36, 150, 218, 62, "master key", ["CLI 由 passphrase 產生", "master.key；也在每台 service.env"], "amber"),
  arrow(145, 150, 145, 122, null, { dash: true }),
  box(320, 40, 210, 62, "操作機（變更時段）", ["passphrase → master key", "encrypt / rotate"], "blue"),
  arrow(256, 91, 318, 71, null, { via: [[290, 91], [290, 71]] }),   // passphrase：Vault → 操作機
  box(320, 130, 210, 62, "security.properties", ["所有主機同一份密文", "0640 root:confluent"], "blue"),
  box(320, 215, 210, 62, "service.env", ["MASTER_KEY=… 只有一行", "0600 root"], "coral"),
  arrow(425, 102, 425, 128), arrow(425, 192, 425, 213, null, { dash: true }),
  box(580, 40, 200, 62, "properties", ["ssl.keystore.password=", "${securepass:…}"], "gray"),
  box(580, 130, 200, 62, "systemd drop-in", ["EnvironmentFile=service.env", "不用 Environment="], "gray"),
  box(580, 215, 200, 62, "服務啟動", ["環境變數 → 解 data key → 解密碼", "不連任何外部系統"], "gray"),
  arrow(532, 71, 578, 71, "派送"), arrow(532, 161, 578, 161, "派送"), arrow(532, 246, 578, 246, "派送"),
].join(""));

// 14. OP menu: who runs what, where the secrets come from
D.opmenu = () => svg(800, 310, [
  box(20, 50, 150, 62, "維運人員", ["經 PVWA + PSMP 登入操作機(root)", "輸入自己的 AD 帳密"], "gray"),
  box(220, 50, 200, 62, "OP menu(操作機)", ["全部項目都顯示,沒權限的做了被拒", "每步留紀錄:AD 帳號 + os=root"], "blue"),
  arrow(170, 81, 218, 81),
  box(470, 50, 150, 62, "MDS", ["AD 帳密換 token", "問:這個人能做什麼?"], "blue"),
  arrow(420, 81, 468, 81),
  box(650, 50, 130, 62, "緊急憑證檔", ["~/secrets/opmenu-breakglass.pem", "root 0600,只有 91 用"], "amber"),
  arrow(650, 60, 320, 48, "91 讀這個檔;本人先過管理員閘門", { via: [[635, 60], [635, 22], [320, 22]], lx: 478, ly: 16, dash: true }),
  box(220, 140, 200, 62, "Kafka 類項目", ["以本人身分走 LDAP listener", "RBAC 依 AD 群組決定"], "blue"),
  arrow(320, 112, 320, 138),
  box(470, 140, 150, 62, "broker", ["topic、權限、lag、稽核"], "gray"),
  arrow(420, 171, 468, 171),
  box(20, 225, 170, 62, "操作機的 ssh 私鑰", ["/secure/ssh,root 0400", "不放保管庫、不經 agent"], "gray"),
  arrow(190, 256, 218, 256),
  box(220, 225, 200, 62, "主機類項目(需 Operator)", ["ssh cpuser@主機", "sudo 逐一列出 restart / journalctl"], "blue"),
  arrow(320, 202, 320, 223),
  box(470, 225, 150, 62, "各主機", ["cpuser,無 agent", "sudoers 兩段式"], "gray"),
  arrow(420, 256, 468, 256),
].join(""));

// 17. monitoring: JMX exporter -> the bank's Prometheus / Alertmanager / Grafana
D.jmx = () => svg(820, 330, [
  region(20, 28, 270, 282, "我方裝的：四種程序 + javaagent", "blue"),
  box(36, 56, 238, 50, "controller ×3", ["官方 kafka_controller.yml"], "blue"),
  box(36, 114, 238, 50, "broker ×4", ["官方 kafka_broker.yml"], "blue"),
  box(36, 172, 238, 50, "REST Proxy ×2", ["官方 confluent_rest.yml"], "blue"),
  box(36, 230, 238, 50, "Control Center", ["我方的小規則（JVM、Streams、Jetty）"], "blue"),
  note(36, 298, ":7071 HTTPS + basic auth，憑證用這台的 keystore"),
  region(330, 28, 470, 282, "銀行提供，我方交付設定", "amber"),
  box(350, 60, 190, 62, "Prometheus", ["4 個 job、env 標籤", "21 條告警規則"], "amber"),
  box(580, 60, 200, 62, "Alertmanager", ["兩種 webhook 格式", "default JSON／自訂 JSON"], "amber"),
  arrow(540, 91, 578, 91, "告警"),
  box(350, 170, 190, 62, "Grafana", ["datasource + 32 個官方", "dashboard（佈建）"], "amber"),
  box(580, 170, 200, 62, "webhook 接收端", ["行內事件系統（omnibus）", "lab：印出收到什麼的容器"], "gray"),
  arrow(680, 122, 680, 168, "POST"),
  arrow(445, 122, 445, 168, "查詢"),
  arrow(290, 140, 348, 100, "每 30 秒抓", { lx: 316, ly: 162 }),
  box(350, 250, 430, 44, "C3 內建 Prometheus／Alertmanager：不動，只給 C3 畫面用", [], "gray", { dash: true }),
].join(""));

// 16. Audit log routing
D.audit = () => svg(800, 260, [
  box(20, 40, 170, 62, "每個 broker / controller", ["security event logger", "寫入者 User:confluent-audit"], "blue"),
  box(260, 40, 200, 62, "router(一行 JSON)", ["payments.* 的 produce/consume", "與被拒的 describe → sensitive"], "blue"),
  arrow(190, 71, 258, 71),
  box(540, 30, 240, 50, "預設 topic", ["confluent-audit-log-events,留 90 天"], "amber"),
  box(540, 100, 240, 50, "敏感 topic 的事件", ["…-log-events_sensitive,留 365 天"], "coral"),
  arrow(460, 60, 538, 55), arrow(460, 82, 538, 125),
  box(20, 150, 170, 62, "排除", ["User:kafka-internal", "User:svc-c3(雜訊)"], "gray"),
  box(260, 150, 200, 62, "密碼", ["confluent-audit 的 SCRAM 密碼", "進 Secret Protection"], "gray"),
  box(540, 180, 240, 50, "誰讀", ["稽核群組 / OP menu 43、45 / SIEM"], "gray"),
  arrow(660, 150, 660, 178, null, { dash: true }),
].join(""));

// 17. Acceptance: four groups of checks
D.acceptance = () => svg(800, 230, [
  box(20, 40, 180, 150, "平台健康", ["quorum、broker、MDS", "REST 經 LB、C3", "partition、Self-Balancing", "JMX exporter"], "blue"),
  box(220, 40, 180, 150, "安全(正向 + 反向)", ["AD 帳密對 / 錯", "RBAC 拒絕", "mTLS 無憑證 / 錯憑證", "主機無明文密碼"], "coral"),
  box(420, 40, 180, 150, "應用程式端", ["app-orders SCRAM 寫讀", "app-legacy-billing", "經 LB + REST(mTLS)寫"], "amber"),
  box(620, 40, 160, 150, "維運", ["OP menu 重啟 broker", "冷開機:全關全開", "收尾清單"], "gray"),
].join(""));

// 21. Certificate rotation: leaf renewal and the three CA phases (what is trusted / what is presented)
D.certrotate = () => svg(800, 300, [
  box(20, 30, 230, 92, "leaf 換發（每年）", ["新私鑰 + CSR → 銀行簽", "同檔名、同 keystore 密碼", "一台一台換 → 滾動重啟"], "blue"),
  note(20, 145, "truststore 只信根憑證：新舊 leaf 同時有效，不斷線"),
  box(20, 170, 160, 100, "階段一：加", ["信任：舊根 + 新根", "出示：舊 CA 簽的"], "amber"),
  arrow(180, 220, 218, 220),
  box(220, 170, 160, 100, "階段二：換", ["信任：舊根 + 新根", "出示：新 CA 簽的", "（銀行的 AD、", "套件庫也重簽）"], "coral"),
  arrow(380, 220, 418, 220),
  box(420, 170, 160, 100, "階段三：退", ["信任：只有新根", "出示：新 CA 簽的", "舊 CA 簽的一律被拒"], "teal"),
  box(300, 30, 480, 92, "每個階段都要換的信任清單", ["OS：/etc/pki/…/bank-root.pem（bundle，檔名不變）", "我方：truststore.p12（alias）、C3 的 ca.pem、OP menu 的兩份", "行內：Prometheus 的 ca.pem、應用程式的 truststore"], "gray"),
  box(620, 170, 160, 100, "階段三之前確認", ["應用程式已換新憑證", "行內 Prometheus、", "應用程式已信新根"], "gray"),
  arrow(618, 220, 582, 220, null, { dash: true }),
].join(""));

// 22. upgrade: three phases, rollback only before finalize
D.upgrade = () => svg(800, 300, [
  box(20, 30, 240, 120, "一：套件 8.2.4 → 8.3.2", ["JDK 維持 21", "C3 2.5.1 → 2.6.1 先，再 broker →", "controller 逐台（leader 最後）", "→ REST → 操作機"], "blue"),
  arrow(260, 90, 288, 90),
  box(290, 30, 220, 120, "二：JDK 21 → 25", ["切 /opt/java/current", "controller、broker、REST、", "操作機逐台重啟", "C3 留在 21"], "teal"),
  arrow(510, 90, 538, 90),
  box(540, 30, 240, 120, "三：finalize", ["kafka-features upgrade", "--release-version 4.3", "metadata 版本升到 8.3", "之後不能退回 8.2"], "coral"),
  box(20, 190, 490, 80, "finalize 之前都能退", ["先把 JDK 切回 21（8.2 不支援 25）→ dnf downgrade 回 8.2.4", "順序和升級相反；每段結束跑第 19 章驗收"], "amber"),
  arrow(265, 188, 265, 152, null, { dash: true }),
  box(540, 190, 240, 80, "每台的步驟", ["versionlock 解開 → 換套件 → 鎖回", "daemon-reload → 重啟 → 等健康"], "gray"),
].join(""));

// ===== concept diagrams (batch 1: access, keys, landing, versions) =====

// 第 4 章 how a person reaches the hosts: PVWA -> PSMP -> ops02 (root) -> one key -> cpuser everywhere
D.access = () => svg(800, 370, [
  box(20, 48, 130, 62, '維運人員', ['瀏覽器', '自己的 AD 帳號'], 'gray'),
  region(180, 14, 372, 124, '銀行 CyberArk（PAM）', 'amber'),
  box(196, 48, 160, 62, 'PVWA 網頁', ['AD 帳密 + MFA', '選操作機，按連線'], 'amber'),
  box(372, 48, 164, 62, 'PSMP 代登 ssh', ['全程錄影', '人員不知道 root 密碼'], 'amber'),
  box(572, 48, 208, 62, '操作機 ops02', ['進去就是 root', '安裝、維運都從這裡'], 'teal'),
  arrow(150, 79, 194, 79), arrow(356, 79, 370, 79), arrow(536, 79, 570, 79),
  box(572, 156, 208, 62, '一把 ssh 私鑰', ['/secure/ssh/cpuser_ed25519', '獨立 file system，root 0400'], 'gray'),
  arrow(676, 110, 676, 154),
  box(20, 156, 520, 62, '追溯：誰在什麼時間進了操作機的 root', ['CyberArk 的登入紀錄 + PSMP 錄影；各主機端只有 cpuser 的操作紀錄', '沒有另外的堡壘機；私鑰不放 CyberArk、不備份，操作機重建就重新產生'], 'gray', { dash: true }),
  region(20, 252, 760, 104, '每台主機（含操作機自己）：cpuser，UID 1500，密碼鎖定，sshd 只收金鑰', 'blue'),
  box(36, 282, 228, 62, 'authorized_keys', ['from="操作機 IP,127.0.0.1,::1" + 公鑰', 'OS 團隊依變更單放'], 'blue'),
  box(286, 282, 228, 62, 'sudoers 兩段', ['安裝期：cpuser 全權', '交付後：cpuser-ops 逐一列出'], 'blue'),
  box(536, 282, 228, 62, '看到什麼', ['操作紀錄是 cpuser', '真正的「人」在操作機那一層'], 'blue'),
  arrow(676, 218, 676, 250), note(690, 238, 'ssh cpuser@主機', 11),
].join(''));

// 第 4 章 where the key material and the sudo/ssh files live
D.keyfiles = () => svg(800, 390, [
  region(20, 14, 310, 332, '操作機 ops02（root）', 'teal'),
  box(34, 46, 282, 60, '/secure/ssh/', ['獨立 file system，root 0700，不備份'], 'gray'),
  box(48, 118, 254, 50, 'cpuser_ed25519（私鑰）', ['root:root 0400，沒有 passphrase'], 'coral'),
  box(48, 178, 254, 50, 'cpuser_ed25519.pub（公鑰）', ['0644，不是祕密，註解帶日期'], 'teal'),
  box(34, 244, 282, 90, '~/.ssh/config', ['Host *.poc.lab localhost', 'User cpuser', 'IdentityFile /secure/ssh/cpuser_ed25519', 'IdentitiesOnly yes'], 'gray'),
  region(430, 14, 350, 332, '每台主機（含操作機自己）', 'blue'),
  box(444, 46, 322, 60, '~/.ssh/authorized_keys（cpuser）', ['0600；只有一行：from="…" 公鑰'], 'blue'),
  box(444, 118, 322, 50, '/etc/ssh/sshd_config.d/50-cpuser.conf', ['PasswordAuthentication no，只收 publickey'], 'blue'),
  box(444, 178, 322, 50, '/etc/sudoers.d/cpuser', ['0440，安裝與升級期的全權；交付時移除'], 'amber'),
  box(444, 238, 322, 50, '/etc/sudoers.d/cpuser-ops', ['0440，交付後只留重啟、查狀態、看日誌'], 'blue'),
  box(444, 298, 322, 36, 'repo01：repodeploy 也放同一行公鑰', [], 'gray'),
  arrow(302, 203, 442, 76, null, { via: [[360, 203], [360, 76]] }),
  ctext(395, 128, 'OS 團隊', { size: 11 }), ctext(395, 144, '放進去', { size: 11 }),
  ctext(400, 366, '私鑰只留在操作機；複製到別處，from= 也擋得住', { size: 12 }),
].join(''));

// 1-2 landing zone layout: who produces what and where each directory ends up
D.landing = () => svg(800, 436, [
  region(20, 14, 330, 392, '落地區 ~/landing（進內網後唯讀）', 'teal'),
  box(36, 46, 298, 44, 'rpm/', ['安裝基底：CP 8.2.4 + C3 2.5.1，11 個 RPM'], 'teal'),
  box(36, 98, 298, 44, 'rpm-target/', ['遷移目標：CP 8.3.2 + C3 2.6.1，11 個 RPM'], 'teal'),
  box(36, 150, 298, 44, 'gpg-keys/', ['Confluent 原廠公鑰（驗 RPM 簽章用）'], 'teal'),
  box(36, 202, 298, 44, 'tools/', ['JMX exporter jar；之後 opmenu/ 也放這裡'], 'teal'),
  box(36, 254, 298, 44, 'monitoring/', ['Confluent 官方規則與 32 個 dashboard'], 'teal'),
  box(36, 306, 298, 44, 'bank/', ['JDK 21、JDK 25 的 tar + sha256'], 'amber'),
  box(36, 358, 298, 36, 'SHA256SUMS（72 個檔）', [], 'gray'),
  box(440, 46, 340, 96, '套件庫 repo01 /confluent/', ['操作機 createrepo_c 建索引後 ssh + tar 上架', '（第 6 章；遷移用的 rpm-target 在 29.1 才上架）'], 'amber'),
  box(440, 150, 340, 44, 'rpm --import', ['進內網後再驗一次簽章（3.3）'], 'gray'),
  box(440, 202, 340, 44, '各主機的 javaagent；操作機 /opt/opmenu', ['jar 派送到各 Java 主機（17.3）；選單在 16.3'], 'blue'),
  box(440, 254, 340, 44, '操作機 ~/monitoring/to-bank/', ['整理後交銀行監控團隊（17.5）'], 'teal'),
  box(440, 306, 340, 44, '各主機 /opt/java/<目錄>', ['解開後切 /opt/java/current（第 5、29.7）'], 'blue'),
  box(440, 358, 340, 36, 'sha256sum -c：進內網後驗一次（3.3）', [], 'gray'),
  arrow(334, 68, 438, 68), arrow(334, 120, 438, 120), arrow(334, 172, 438, 172), arrow(334, 224, 438, 224),
  arrow(334, 276, 438, 276), arrow(334, 328, 438, 328), arrow(334, 376, 438, 376),
  ctext(185, 422, '綠＝我方從外網帶來的；橘＝銀行提供的檔案', { size: 11 }),
  ctext(610, 422, 'repo01 /os/ 是銀行自己維護的 OS 套件，不在落地區', { size: 11 }),
].join(''));

// 1.4 version path: base vs target per layer, with the chapter that moves it
D.versionpath = () => svg(800, 330, [
  ctext(95, 24, '層', { bold: true, fill: '#444441', size: 13 }), ctext(240, 24, '安裝基底（第 1–20 章）', { bold: true, fill: '#444441', size: 13 }),
  ctext(405, 24, '誰、哪一節動它', { bold: true, fill: '#444441', size: 13 }), ctext(560, 24, '遷移目標', { bold: true, fill: '#444441', size: 13 }),
  box(20, 42, 150, 54, 'Control Center', ['最先升'], 'gray'),
  box(180, 42, 120, 54, '2.5.1', [], 'blue'), arrow(300, 69, 510, 69), ctext(405, 56, '① 29.3 節　原廠要求 C3 先升', { size: 12 }), box(510, 42, 100, 54, '2.6.1', [], 'teal'),
  note(626, 62, '2.5 只支援到 CP 8.2', 11), note(626, 80, '2.6 才支援到 8.3', 11),
  box(20, 112, 150, 54, 'Confluent Platform', ['broker、controller、REST'], 'gray'),
  box(180, 112, 120, 54, '8.2.4', [], 'blue'), arrow(300, 139, 510, 139), ctext(405, 126, '② 29.4–29.6 節　套件滾動升級', { size: 12 }), box(510, 112, 100, 54, '8.3.2', [], 'teal'),
  note(626, 132, '逐台；controller', 11), note(626, 150, 'leader 最後', 11),
  box(20, 182, 150, 54, 'JDK', ['銀行交付的 tar'], 'gray'),
  box(180, 182, 120, 54, '21', [], 'blue'), arrow(300, 209, 510, 209), ctext(405, 196, '③ 29.7 節　CP 升完才換', { size: 12 }), box(510, 182, 100, 54, '25', [], 'teal'),
  note(626, 202, '8.2 不支援 25', 11), note(626, 220, 'C3 留在 21', 11),
  box(20, 252, 150, 54, 'OS（RHEL 9）', ['銀行的套件庫'], 'gray'),
  box(180, 252, 120, 54, '9.6', [], 'blue'), arrow(300, 279, 510, 279), ctext(405, 266, '⑤ 30.5 節　小版本更新', { size: 12 }), box(510, 252, 100, 54, '9.8', [], 'teal'),
  note(626, 272, 'versionlock 鎖住 Confluent', 11), note(626, 290, 'JDK 是 tar，不受影響', 11),
  ctext(400, 322, '④ 29.9 節 finalize 排在 ③ 之後、⑤ 之前：metadata 版本升到 8.3，之後不能退回 8.2', { size: 12, fill: '#712B13' }),
].join(''));

// ===== concept diagrams (batch 2: trust, listeners, kraft, token, rbac) =====

// 9.3 keystore vs truststore: who presents what, who trusts what
D.trust = () => svg(800, 350, [
  region(20, 14, 250, 262, 'kb01（出示方）', 'blue'),
  box(36, 48, 218, 84, 'keystore  cp-server.p12', ['我是誰', '私鑰 + 銀行簽的憑證 + 中繼 CA'], 'teal'),
  box(36, 150, 218, 100, 'truststore.p12', ['我信誰', '只放銀行的根憑證', '不放 leaf、不放私鑰'], 'gray'),
  region(530, 14, 250, 262, 'c3-01（驗證方）', 'blue'),
  box(546, 48, 218, 84, 'keystore  svc-c3.p12', ['我是誰', '私鑰 + 銀行簽的憑證 + 中繼 CA'], 'teal'),
  box(546, 150, 218, 100, 'truststore.p12', ['我信誰', '只放銀行的根憑證', '不放 leaf、不放私鑰'], 'gray'),
  arrow(272, 74, 528, 74), ctext(400, 62, '① 出示憑證（leaf + 中繼）', { size: 12 }),
  arrow(528, 112, 272, 112), ctext(400, 126, '② 對方也出示：雙向 TLS（mTLS）', { size: 12 }),
  box(284, 146, 232, 112, '收到的一方檢查', ['鏈能接到自己信任的根', '主機名稱在 SAN 裡', 'EKU 用途對（serverAuth／clientAuth）', '沒有過期'], 'amber'),
  box(250, 296, 300, 44, '銀行根憑證 bank-root.pem', ['放進每台的 truststore，也放進 OS 信任清單'], 'amber'),
  arrow(250, 318, 145, 252, null, { via: [[145, 318]] }), arrow(550, 318, 655, 252, null, { via: [[655, 318]] }),
].join(''));

// 10.2 listeners and ports: who connects to which door
D.listeners = () => svg(800, 330, [
  box(20, 34, 170, 56, '應用程式（直連）', ['app-orders、app-payments', 'SCRAM 帳密'], 'gray'),
  box(20, 98, 170, 48, '人員', ['OP menu、AD 帳密'], 'gray'),
  box(20, 154, 170, 96, 'C3、REST Proxy、操作機', ['svc-c3、svc-rest、svc-ops', '用憑證向 MDS 換 token', '再帶 token 進 TOKEN'], 'gray'),
  box(20, 258, 170, 44, 'broker 之間', ['以及 controller 的 MDS'], 'gray'),
  region(240, 12, 300, 300, 'broker kb01–kb04 的門', 'blue'),
  box(256, 40, 268, 44, 'CLIENT 9095', ['SASL_SSL，SCRAM-SHA-512'], 'blue'),
  box(256, 92, 268, 44, 'LDAP 9096', ['SASL_SSL，PLAIN，帳密轉去問 AD'], 'blue'),
  box(256, 144, 268, 44, 'MDS 8090', ['HTTPS：驗身分、發 token、RBAC'], 'blue'),
  box(256, 196, 268, 44, 'TOKEN 9094', ['SASL_SSL，OAUTHBEARER（MDS 發的 token）'], 'blue'),
  box(256, 248, 268, 44, 'INTERNAL 9092', ['SSL，mTLS（內部憑證）'], 'blue'),
  arrow(190, 62, 254, 62), arrow(190, 114, 254, 114), arrow(190, 166, 254, 166), arrow(190, 218, 254, 218), arrow(190, 270, 254, 270),
  box(600, 92, 180, 80, 'AD ad01', ['LDAPS 636', '查帳密、群組'], 'amber'),
  arrow(524, 114, 598, 114), arrow(524, 166, 598, 150),
  region(580, 196, 200, 116, 'controller kc01–kc03', 'blue'),
  box(594, 226, 172, 66, 'CONTROLLER 9093', ['SSL，mTLS', 'quorum 與 metadata'], 'blue'),
  arrow(524, 262, 592, 262), arrow(592, 282, 524, 282),
].join(''));

// 10.4 / 23 the KRaft quorum: voters, observers, what Lag means
D.kraft = () => svg(800, 360, [
  box(20, 56, 150, 56, 'metadata 變更', ['建 topic、role binding', 'SCRAM 帳號…'], 'gray'),
  region(210, 12, 330, 196, 'voter：controller 3 台（投票）', 'blue'),
  box(300, 44, 150, 56, 'kc01（node 1）', ['Leader：只有它收寫入'], 'blue'),
  outline(300, 44, 150, 56, 'blue', 3),
  box(226, 134, 140, 56, 'kc02（node 2）', ['Follower'], 'blue'),
  box(384, 134, 140, 56, 'kc03（node 3）', ['Follower'], 'blue'),
  arrow(170, 84, 298, 72), arrow(340, 100, 300, 132, '複寫', { lx: 306, ly: 118 }), arrow(410, 100, 450, 132, '複寫', { lx: 440, ly: 118 }),
  region(210, 232, 330, 112, 'observer：broker 4 台（不投票）', 'gray'),
  box(224, 264, 70, 56, 'kb01', ['101'], 'gray'), box(302, 264, 70, 56, 'kb02', ['102'], 'gray'),
  box(380, 264, 70, 56, 'kb03', ['103'], 'gray'), box(458, 264, 70, 56, 'kb04', ['104'], 'gray'),
  arrow(375, 208, 375, 230, '也複寫', { lx: 412, ly: 222 }),
  box(580, 12, 200, 92, '多數派', ['3 台 voter 要 2 台在', '才選得出 leader', '也才能提交寫入'], 'teal'),
  box(580, 116, 200, 104, 'Lag 怎麼算', ['leader 的 LogEndOffset', '減這台已複製的位置', 'describe --replication 第 4 欄', '0 ＝ 追上了'], 'purple'),
  box(580, 232, 200, 112, '所以重啟前', ['看 Lag 回到 0', '才做下一台', 'controller 逐台，leader 最後', '同時只動一台'], 'coral'),
].join(''));

// 11 how a certificate becomes a token (and why the MDS key pair is handed out the way it is)
D.tokenflow = () => svg(800, 346, [
  box(315, 12, 170, 58, 'mds-token-keypair.pem', ['私鑰，簽 token；kc、kb 各一份'], 'coral'),
  box(610, 12, 170, 58, 'mds-token-public.pem', ['公鑰，驗簽章；每台都放'], 'teal'),
  arrow(400, 70, 400, 100, '簽', { lx: 412, ly: 86, dash: true }), arrow(695, 70, 695, 100, '驗', { lx: 707, ly: 86, dash: true }),
  box(20, 100, 170, 96, '操作機／C3／REST', ['svc-ops、svc-c3、svc-rest', '手上是 client 憑證 .p12'], 'gray'),
  box(315, 100, 170, 96, 'MDS（broker 的 8090）', ['驗憑證，CN → principal', '用私鑰簽 token'], 'blue'),
  box(610, 100, 170, 96, 'broker TOKEN 9094', ['驗 token 的簽章', '再用 RBAC 決定能做什麼'], 'blue'),
  arrow(190, 124, 313, 124), arrow(313, 172, 192, 172),
  num(252, 110, '1'), num(252, 158, '2'),
  ctext(252, 138, '出示憑證', { size: 11 }), ctext(252, 186, '回 token（最長 1 小時）', { size: 11 }),
  arrow(105, 198, 695, 198, null, { via: [[105, 246], [695, 246]] }),
  num(400, 246, '3'), ctext(400, 264, '帶 token 進 TOKEN listener（OAUTHBEARER）', { size: 12 }),
  box(20, 284, 760, 52, '人員走另一條', ['用 AD 帳密代替憑證；MDS 去 AD（LDAPS 636）查帳密與群組，再發 token'], 'gray', { dash: true }),
].join(''));

// 11 RBAC: who -> group -> role binding -> resource
D.rbac = () => svg(800, 470, [
  ctext(95, 20, '身分', { bold: true, fill: '#444441', size: 13 }), ctext(285, 20, 'AD 群組（銀行 AD）', { bold: true, fill: '#444441', size: 13 }),
  ctext(500, 20, 'role binding（MDS）', { bold: true, fill: '#444441', size: 13 }), ctext(700, 20, '資源', { bold: true, fill: '#444441', size: 13 }),
  box(20, 38, 150, 54, 'alice', ['AD 帳密'], 'gray'), box(215, 38, 140, 54, 'kafka-admins', [], 'amber'),
  box(410, 38, 180, 54, 'SystemAdmin', ['Group:kafka-admins'], 'blue'), box(630, 38, 150, 54, '整個叢集', [], 'gray'),
  arrow(170, 65, 213, 65), arrow(355, 65, 408, 65), arrow(590, 65, 628, 65),
  box(20, 108, 150, 54, 'bob', ['AD 帳密'], 'gray'), box(215, 108, 140, 54, 'kafka-operators', [], 'amber'),
  box(410, 108, 180, 54, 'Operator', ['Group:kafka-operators'], 'blue'), box(630, 108, 150, 54, '整個叢集', [], 'gray'),
  arrow(170, 135, 213, 135), arrow(355, 135, 408, 135), arrow(590, 135, 628, 135),
  box(20, 178, 150, 54, 'carol', ['AD 帳密'], 'gray'), box(215, 178, 140, 54, 'kafka-devs', [], 'amber'),
  box(410, 178, 180, 54, 'DeveloperRead', ['Group:kafka-devs'], 'blue'), box(630, 178, 150, 54, 'Topic orders.*', ['Group dev-*（前綴）'], 'gray'),
  arrow(170, 205, 213, 205), arrow(355, 205, 408, 205), arrow(590, 205, 628, 205),
  box(20, 248, 150, 54, 'app-orders', ['SCRAM 帳密'], 'gray'),
  box(410, 248, 180, 54, 'DeveloperWrite／Read', ['User:app-orders'], 'blue'), box(630, 248, 150, 54, 'Topic orders.*', ['Group orders-*（前綴）'], 'gray'),
  arrow(170, 275, 408, 275, '應用程式不用群組，直接綁自己', { lx: 290, ly: 266 }), arrow(590, 275, 628, 275),
  box(20, 318, 150, 54, 'svc-c3', ['憑證 CN=svc-c3'], 'gray'),
  box(410, 318, 180, 54, 'SystemAdmin', ['User:svc-c3'], 'blue'), box(630, 318, 150, 54, '整個叢集', [], 'gray'),
  arrow(170, 345, 408, 345, '平台服務也直接綁，憑證不經 AD', { lx: 290, ly: 336 }), arrow(590, 345, 628, 345),
  box(20, 392, 760, 60, '權限綁群組，不綁個人', ['人員進出部門＝AD 團隊改群組成員，role binding 不用動', '憑證的 CN 經 ssl.principal.mapping.rules 變成 User:<CN>'], 'teal'),
].join(''));

// ===== concept diagrams (batch 3: restdrain, c3roles, keyhier, opmenuflow, alertpath) =====

// 12.1 restarting REST Proxy behind the LB: the five steps and what each member is doing
D.restdrain = () => {
  const cols = [
    ['1', 'amber', 'LB 團隊', ['停用 rest01'], ['gray', '停用'], ['blue', '接流量']],
    ['2', 'teal', '小安', ['等連線排空', '重啟 rest01，要 200'], ['purple', '重啟中'], ['blue', '接流量']],
    ['3', 'amber', 'LB 團隊', ['恢復 rest01', '停用 rest02'], ['blue', '接流量'], ['gray', '停用']],
    ['4', 'teal', '小安', ['等連線排空', '重啟 rest02，要 200'], ['blue', '接流量'], ['purple', '重啟中']],
    ['5', 'amber', 'LB 團隊', ['恢復 rest02'], ['blue', '接流量'], ['blue', '接流量']],
  ];
  let out = '';
  cols.forEach(([n, c, who, subs, a, b], i) => {
    const x = 20 + i * 152;
    out += box(x, 14, 144, 70, `${n}　${who}`, subs, c);
    out += box(x, 100, 144, 48, 'rest01', [a[1]], a[0], { dash: a[0] === 'gray' });
    out += box(x, 158, 144, 48, 'rest02', [b[1]], b[0], { dash: b[0] === 'gray' });
  });
  out += arrow(20, 236, 780, 236);
  out += ctext(400, 224, '時間', { size: 11 });
  out += box(20, 252, 760, 44, '重啟那一台之前，rest-restart.sh 先等 8082 上沒有從 LB 進來的連線', ['60 秒還有就停下、不重啟（多半是 LB 還沒停用）'], 'gray');
  out += ctext(400, 316, '實測：照這五步，經 LB 持續探測 0 次非 200；不排空、直接重啟兩台，68 次裡有 1 次失敗', { size: 12, fill: '#712B13' });
  return svg(800, 332, out);
};

// 13 / 17 what C3's built-in Prometheus/Alertmanager do versus the bank's monitoring stack
D.c3roles = () => svg(800, 392, [
  region(20, 14, 250, 300, 'c3-01：C3 內建（只給 C3 畫面）', 'blue'),
  box(36, 46, 218, 58, '內建 Prometheus :9090', ['收 OTLP（mTLS），只留 2 天'], 'blue'),
  box(36, 128, 218, 58, 'Control Center :9021', ['畫面讀它的資料', '人員的瀏覽器直連'], 'blue'),
  box(36, 214, 218, 66, '內建 Alertmanager', ['不使用', '不要在 C3 畫面建 alert trigger'], 'gray', { dash: true }),
  arrow(145, 104, 145, 126, '查', { lx: 160, ly: 118 }),
  region(295, 14, 210, 300, '各 Java 程序', 'blue'),
  box(310, 46, 180, 74, 'TelemetryReporter', ['controller、broker', '指標以 OTLP 送給 C3'], 'blue'),
  box(310, 186, 180, 94, 'JMX exporter :7071', ['controller、broker、', 'REST Proxy、C3', 'HTTPS + basic auth'], 'teal'),
  region(530, 14, 250, 300, '銀行的監控（行內）', 'amber'),
  box(546, 46, 218, 58, '行內 Prometheus', ['每 30 秒抓 :7071，4 個 job'], 'amber'),
  box(546, 128, 218, 58, '行內 Alertmanager', ['21 條規則 → webhook'], 'amber'),
  box(546, 214, 218, 66, 'Grafana', ['datasource + 32 個官方 dashboard'], 'amber'),
  arrow(310, 83, 256, 75),
  arrow(490, 233, 546, 75, null, { via: [[518, 233], [518, 75]] }),
  arrow(655, 104, 655, 126),
  box(20, 330, 760, 50, '告警與 dashboard 為什麼不走 C3 內建的', ['C3 重啟會把 Alertmanager 設定重寫、webhook 內容不能自訂、而且只看得到 telemetry（沒有主機標籤）'], 'coral'),
].join(''));

// 15 the key hierarchy of Secret Protection
D.keyhier = () => svg(800, 320, [
  box(20, 30, 150, 80, 'passphrase', ['工程師在操作機產生', '只在操作機 ~/secrets', '0600，不放 CyberArk'], 'amber'),
  box(250, 30, 150, 80, 'master key', ['CLI 產生', '操作機 ~/secrets', '每台 service.env'], 'coral'),
  box(470, 30, 130, 80, 'data key', ['用它加密', '各個密碼'], 'gray'),
  box(650, 30, 130, 80, '密文', ['security.properties', '所有主機同一份'], 'gray'),
  arrow(170, 70, 248, 70), ctext(209, 58, '＋隨機 salt', { size: 11 }),
  arrow(400, 70, 468, 70), arrow(600, 70, 648, 70),
  box(20, 140, 345, 150, '為什麼兩樣都要存', ['salt 每次產生都不同', '只有 passphrase 算不回原本的 master key', '再跑一次 generate 也拿不回同一把', '輪替（20.3）要目前的 master key＋舊 passphrase', '分開存是為了分開授權：', '主機讀得到 master key，讀不到 passphrase'], 'teal'),
  box(385, 140, 185, 60, 'service.env', ['MASTER_KEY=… 一行', '0600 root'], 'coral'),
  arrow(325, 110, 440, 138, '派送', { via: [[325, 126], [440, 126]], lx: 382, ly: 119 }),
  box(600, 140, 180, 60, '服務啟動', ['環境變數 → 解 data key', '→ 解出密碼'], 'gray'),
  arrow(570, 170, 598, 170, null, { dash: true }),
  arrow(715, 110, 715, 138),
  box(380, 224, 400, 66, '解密完全在主機本地', ['不連任何外部系統（也不連 CyberArk）', '密文外洩而 master key 沒有：打不開'], 'gray', { dash: true }),
].join(''));

// 16 the OP menu: what happens between login and a command on a host
D.opmenuflow = () => svg(800, 440, [
  box(20, 20, 230, 62, '維運人員', ['經 PVWA + PSMP 進操作機（root）', '執行 /opt/opmenu/opmenu.sh'], 'gray'), num(20, 20, '1'),
  box(285, 20, 230, 62, '輸入自己的 AD 帳密', ['選單用它向 MDS 換 token', '本人的 token，不是共用帳號'], 'blue'), num(285, 20, '2'),
  box(550, 20, 230, 62, 'MDS 換 token', ['本人的 token，之後每個動作都用它', '選單全部顯示，沒權限的做了被拒'], 'blue'), num(550, 20, '3'),
  arrow(250, 51, 283, 51), arrow(515, 51, 548, 51),
  box(20, 160, 230, 96, 'Kafka 類', ['topic、權限、lag、稽核', '以本人身分走 LDAP 9096', 'RBAC 由 Kafka 強制，繞不過'], 'blue'),
  box(285, 160, 230, 96, '主機類（要 Operator）', ['先問 MDS：本人有權限嗎', '用 /secure/ssh 的金鑰 ssh cpuser', '這一關是流程控管，不是硬性隔離'], 'blue'),
  box(550, 160, 230, 96, '91 緊急模式', ['先問 MDS：本人是不是管理員', '讀 ~/secrets/opmenu-breakglass.pem，以備用身分執行一個指令', '必填原因，記為 EMERGENCY'], 'coral'),
  arrow(665, 82, 135, 158, null, { via: [[665, 120], [135, 120]] }), arrow(665, 82, 400, 158, null, { via: [[665, 120], [400, 120]] }), arrow(665, 82, 665, 158),
  box(20, 290, 230, 62, 'broker', ['每個動作 Kafka 端記的是本人'], 'gray'),
  arrow(135, 256, 135, 288),
  box(285, 290, 230, 62, 'sudo 只放行三件事', ['restart、status、journalctl -n 200', '每種寫法逐一列出，多帶參數就拒絕'], 'amber'),
  arrow(400, 256, 400, 288),
  box(550, 290, 230, 62, '用完即丟', ['憑證副本放記憶體檔案系統，用完即刪'], 'gray'),
  arrow(665, 256, 665, 288),
  box(20, 376, 760, 44, '每一步寫一行紀錄 /var/log/opmenu/opmenu.log', ['AD 帳號 ｜ os=root ｜ 項目 ｜ 結果；再往上追是 CyberArk 登入紀錄與 PSMP 錄影'], 'teal'),
].join(''));

// 17.8 the alert path: metric -> rule -> Alertmanager -> two webhook formats
D.alertpath = () => svg(800, 340, [
  box(20, 40, 130, 70, 'JMX exporter', [':7071', '各 Java 程序'], 'teal'),
  box(180, 40, 170, 70, '行內 Prometheus', ['每 30 秒抓、算規則', '條件成立 → firing'], 'amber'),
  box(380, 40, 170, 70, '行內 Alertmanager', ['依標籤分組', 'group_wait 10 秒'], 'amber'),
  arrow(150, 75, 178, 75), arrow(350, 75, 378, 75),
  box(590, 14, 190, 54, '/default', ['webhook，預設 JSON'], 'teal'),
  box(590, 82, 190, 54, '/omnibus', ['webhook，自訂 JSON'], 'purple'),
  arrow(550, 62, 588, 41), arrow(550, 88, 588, 109),
  box(20, 168, 380, 128, '預設格式（Alertmanager version 4）', ['整包 JSON，alerts 是陣列', '（一個通知群組可能有很多筆）', 'status：firing → resolved', 'labels、annotations、startsAt、fingerprint', '欄位是 Alertmanager 定的，不能改'], 'teal'),
  box(420, 168, 360, 128, '自訂格式（範本組出來的）', ['一筆告警一個扁平 JSON', 'msg_catalog、msg、sub_origin', 'severity（critical → ERROR）', 'state：OPEN → RESOLVED', '雙引號、冒號不會弄壞 JSON'], 'purple'),
  ctext(400, 318, '條件消失時 Prometheus 直接送 resolved，兩種格式都會收到「已解除」；之後送進行內事件系統', { size: 12 }),
].join(''));

// ===== concept diagrams (batch 4: keyrotate, migrationflow, controllerswap, brokerscale, backup, ospatch) =====

// 20.5 SSH key rotation: old and new coexist, there is always a working key
D.keyrotate = () => {
  const steps = [
    ['1', '產生新金鑰', ['.new，註解帶時間'], ['gray', '舊'], ['gray', '舊'], '用舊 ✓'],
    ['2', '加新公鑰', ['用舊金鑰登入去加'], ['gray', '舊'], ['purple', '舊 ＋ 新'], '用舊 ✓'],
    ['3', '逐台測新金鑰', ['12 台都通過才往下'], ['gray', '舊'], ['purple', '舊 ＋ 新'], '用舊 ✓　新也 ✓'],
    ['4', '私鑰換成新的', ['兩個 mv 連在一起'], ['teal', '新'], ['purple', '舊 ＋ 新'], '用新 ✓'],
    ['5', '刪舊公鑰', ['再刪操作機的舊私鑰'], ['teal', '新'], ['teal', '新'], '用新 ✓　舊被拒'],
  ];
  let out = ctext(20, 100, '操作機的私鑰', { anchor: 'start', size: 12, bold: true, fill: '#444441' })
    + ctext(20, 160, '各台的公鑰', { anchor: 'start', size: 12, bold: true, fill: '#444441' })
    + ctext(20, 220, '當下能登入', { anchor: 'start', size: 12, bold: true, fill: '#444441' });
  steps.forEach(([n, t, subs, a, b, c], i) => {
    const x = 120 + i * 136;
    out += box(x, 14, 128, 62, `${n}　${t}`, subs, 'teal');
    out += box(x, 84, 128, 36, a[1], [], a[0]);
    out += box(x, 144, 128, 36, b[1], [], b[0]);
    out += box(x, 204, 128, 36, c, [], 'gray');
  });
  out += outline(120 + 3 * 136, 84, 128, 36, 'coral', 2);
  out += box(20, 266, 760, 60, '唯一的風險窗口在步驟 4', ['私鑰與 .pub 成對換掉的那一瞬間（微秒級），剛好開始的 ssh 會失敗一次', '所以步驟 4 要在沒有其他連線作業時做；探針實測全程最多失敗 1 次'], 'coral');
  return svg(800, 344, out);
};

// 21 the whole migration in order, with the point of no return
D.migrationflow = () => svg(800, 460, [
  region(10, 8, 780, 258, 'finalize 之前：每一段都能退（先把 JDK 切回 21，再 dnf downgrade 回 8.2.4）', 'teal'),
  box(20, 44, 140, 58, '29.1 上架＋檢查', ['rpm-target 進套件庫', '看 under-replicated'], 'blue'),
  box(172, 44, 140, 58, '29.2 備份', ['/etc/confluent、', 'drop-in、features'], 'blue'),
  box(324, 44, 140, 58, '29.3 C3 先升', ['2.5.1 → 2.6.1', '畫面約 1–2 分鐘'], 'blue'),
  box(476, 44, 140, 58, '29.4 broker', ['逐台，等 MDS 200', 'under-replicated 0'], 'blue'),
  box(628, 44, 152, 58, '29.5 controller', ['逐台，leader 最後', '等 Lag 0'], 'blue'),
  arrow(160, 73, 170, 73), arrow(312, 73, 322, 73), arrow(464, 73, 474, 73), arrow(616, 73, 626, 73),
  box(20, 164, 140, 58, '29.6 REST＋操作機', ['REST 照 12.1 五步', '先補 svc-rest 權限'], 'blue'),
  box(172, 164, 140, 58, '驗收 第 19 章', ['第一段結束'], 'gray'),
  box(324, 164, 140, 58, '29.7 JDK 21 → 25', ['其餘逐台切換', 'C3 留在 21'], 'teal'),
  box(476, 164, 140, 58, '驗收 第 19 章', ['第二段結束'], 'gray'),
  box(628, 164, 152, 58, '29.8 回滾演練', ['kb04 退回 8.2.4', '再升回去'], 'amber'),
  arrow(704, 102, 90, 162, null, { via: [[704, 134], [90, 134]] }),
  arrow(160, 193, 170, 193), arrow(312, 193, 322, 193), arrow(464, 193, 474, 193), arrow(616, 193, 626, 193),
  region(10, 286, 780, 164, '不可逆的一步', 'coral'),
  box(20, 326, 220, 100, '觀察一段時間', ['前兩段都驗收過', '確定不退了才做下一步'], 'gray'),
  box(290, 326, 230, 100, '29.9 finalize', ['kafka-features upgrade', '--release-version 4.3', 'metadata 升到 8.3'], 'coral'),
  box(570, 326, 210, 100, '29.10 記下新基準', ['確認每台版本', '之後新增主機裝現行版本', '（8.3.2、2.6.1、JDK 25）'], 'gray'),
  arrow(240, 376, 288, 376), arrow(520, 376, 568, 376),
  arrow(704, 222, 130, 324, null, { via: [[704, 250], [130, 250], [130, 280]] }),
  ctext(250, 303, '之後不能退回 8.2（要退得用 29.2 的備份）', { size: 12, fill: '#712B13', anchor: 'start' }),
].join(''));

// 23 replacing a controller: the quorum membership at each step
D.controllerswap = () => {
  const cols = [
    ['25.1.1', '換之前', ['看 quorum'], [['blue', 'kc01', 'Leader'], ['blue', 'kc02', 'Follower'], ['blue', 'kc03', 'Follower']], 'voter 3 台，Lag 都是 0'],
    ['25.1.2', 'kc03 碟壞了', ['停服務、清空資料'], [['blue', 'kc01', 'Leader'], ['blue', 'kc02', 'Follower'], ['coral', 'kc03', '停了，Lag 變大']], '叢集照常（還有 2 台）'],
    ['25.1.3', '移出舊成員', ['remove-controller', '3＋舊 directory id'], [['blue', 'kc01', 'voter'], ['blue', 'kc02', 'voter'], ['gray', 'kc03', '不是成員']], 'voter 只剩 2 台'],
    ['25.1.4', '格式化、啟動', ['--no-initial-', 'controllers'], [['blue', 'kc01', 'voter'], ['blue', 'kc02', 'voter'], ['purple', 'kc03', 'Observer，追上到 Lag 0']], '新 directory id'],
    ['25.1.5', '加回成員', ['add-controller', '在 kc03 上跑'], [['blue', 'kc01', 'voter'], ['blue', 'kc02', 'voter'], ['blue', 'kc03', 'voter']], 'voter 3 台，完成'],
  ];
  let out = '';
  cols.forEach(([sec, t, subs, nodes, foot], i) => {
    const x = 20 + i * 152;
    out += box(x, 14, 144, 78, `${sec}　${t}`, subs, 'teal');
    nodes.forEach(([c, name, st], j) => { out += box(x, 108 + j * 56, 144, 48, name, [st], c, { dash: c === 'gray' }); });
    out += ctext(x + 72, 290, foot, { size: 11 });
  });
  out += arrow(20, 312, 780, 312);
  out += box(20, 326, 760, 50, '一次只換一台', ['只剩 2 台 voter 時，兩台都要在才選得出 leader：這段時間不要重啟 kc01、kc02'], 'coral');
  return svg(800, 392, out);
};

// 24 shrinking and growing the broker set
D.brokerscale = () => {
  const colX = [20, 285, 550];
  const cols = [
    ['縮減前', ['4 台都有資料'], ['blue', 'kb04（104）', '80 個 replica'], '前置檢查（25.2.1）', ['Self-Balancing ENABLED', '沒有 under-replicated', '縮減後至少還有 3 台'], 'gray'],
    ['縮減（25.2.2）', ['kafka-remove-brokers', '--delete --broker-id 104'], ['gray', 'kb04（104）', '0 個 replica，服務停用'], '要等到 SUCCESS', ['Replica Exclusion', '→ Partition Reassignment', '→ Broker Shutdown'], 'amber'],
    ['擴充（25.2.3）', ['清空資料、format、啟動', '--no-initial-controllers'], ['purple', 'kb04（104）', '空的，Self-Balancing 來搬'], '不是馬上搬', ['lab 等十幾分鐘才開始', '之後分批搬，要再一段時間', '等到 104 上有 replica'], 'gray'],
  ];
  let out = '';
  cols.forEach(([t, subs, kb4, bt, bsubs, bc], i) => {
    const x = colX[i];
    out += box(x, 14, 230, 62, t, subs, 'teal');
    ['kb01', 'kb02', 'kb03'].forEach((n, j) => { out += box(x, 90 + j * 44, 230, 38, `${n}（${101 + j}）`, [], 'blue'); });
    out += box(x, 222, 230, 48, kb4[1], [kb4[2]], kb4[0], { dash: kb4[0] === 'gray' });
    out += box(x, 284, 230, 80, bt, bsubs, bc);
  });
  out += arrow(250, 45, 283, 45) + arrow(515, 45, 548, 45);
  return svg(800, 380, out);
};

// 25 daily metadata backup and the three kinds of things to back up
D.backup = () => svg(800, 420, [
  box(20, 30, 190, 70, 'systemd timer', ['每天 02:00', 'metadata-backup.sh'], 'teal'),
  box(250, 30, 200, 70, 'svc-backup 憑證', ['只能看、讀不到訊息', 'SecurityAdmin + 2 條 ACL'], 'teal'),
  box(490, 30, 290, 70, 'Kafka 叢集（MDS + broker）', ['回答：role binding、topic 與設定、', 'ACL、SCRAM 帳號清單、配額、features'], 'blue'),
  arrow(210, 65, 248, 65), arrow(450, 65, 488, 65),
  box(20, 140, 400, 104, '~/backup/metadata/<時間>/（留 30 天）', ['topics、topic-configs、users、broker-configs', 'features、acls、rbac：7 個 .txt + SHA256SUMS', '沒有密碼；成功或失敗都寫 syslog（confluent-backup）'], 'teal'),
  arrow(115, 100, 115, 138),
  box(450, 140, 330, 104, '怎麼用', ['比對最近兩份的 sha256，看哪個檔有變', '多了或少了哪些 topic', '還原：照檔案逐項重建，由人在變更時段做', '不寫成自動還原'], 'gray'),
  arrow(420, 192, 448, 192),
  region(10, 262, 780, 148, '要備份的分三類，各走各的路', 'gray'),
  box(20, 296, 240, 98, '叢集中繼資料', ['操作機每天排程（上面）', '變更前再手動匯出一份'], 'teal'),
  box(280, 296, 240, 98, '各台的設定', ['/etc/confluent、drop-in', '銀行既有的主機備份系統', '操作機不 ssh 進各台'], 'amber'),
  box(540, 296, 240, 98, '機敏資料', ['操作機 ~/secrets、~/pki', '銀行的備份機制備份操作機（加密）', '/secure/ssh 的私鑰不備份'], 'coral'),
].join(''));

// 26 OS patching / minor-version update: order, and the loop on each host
D.ospatch = () => svg(800, 400, [
  box(20, 20, 230, 62, '30.0 銀行同步套件庫', ['repo01 /os/ 放進 9.8 的內容', '（每月修補就是例行同步）'], 'amber'),
  box(285, 20, 200, 62, '更新前先做快照', ['每台，回滾靠它', '不要靠 dnf history undo'], 'amber'),
  box(520, 20, 260, 62, '30.1 檢查', ['套件庫有 9.8 的 release 套件', '更新清單裡 confluent-* 是 0 個'], 'teal'),
  arrow(250, 51, 283, 51), arrow(485, 51, 518, 51),
  box(20, 118, 170, 62, '30.2 broker', ['逐台', 'MDS 200、無 under-rep.'], 'blue'),
  box(217, 118, 170, 62, '30.3 controller', ['逐台，leader 最後', '等 Lag 0'], 'blue'),
  box(414, 118, 190, 62, '30.4 REST、C3、操作機', ['REST 照 12.1 五步', '操作機最後，自己修自己'], 'blue'),
  box(631, 118, 149, 62, '驗收 第 19 章', ['19.1–19.3'], 'gray'),
  arrow(190, 149, 215, 149), arrow(387, 149, 412, 149), arrow(604, 149, 629, 149),
  arrow(650, 82, 105, 116, null, { via: [[650, 100], [105, 100]] }),
  region(20, 206, 760, 124, '每一台的迴圈（30.2–30.4 都一樣）', 'blue'),
  box(36, 238, 160, 78, 'dnf update', ['--refresh', 'Confluent 被 versionlock', '鎖住，不會動'], 'blue'),
  box(226, 238, 160, 78, 'needs-restarting', ['-r：要不要重開機', '-s：哪些服務要重啟'], 'blue'),
  box(416, 238, 160, 78, '重開機或重啟服務', ['正式：systemctl reboot', 'lab 容器：重啟平台服務'], 'blue'),
  box(606, 238, 158, 78, '等健康才下一台', ['broker：MDS 200', '且 under-replicated 0', 'controller：Lag 0'], 'blue'),
  arrow(196, 277, 224, 277), arrow(386, 277, 414, 277), arrow(576, 277, 604, 277),
  box(20, 346, 760, 44, 'JDK 是 tar，Confluent 被鎖版本：dnf update 只動 OS 套件', ['Confluent 的版本只走第 29 章；小版本更新（9.6 → 9.8）一定要重開機'], 'gray'),
].join(''));


// 21 restore drill (23.6): which backup file rebuilds what, and what a backup cannot give back
D.restore = () => svg(800, 420, [
  region(10, 14, 200, 300, '最近一份備份 ~/backup/metadata/<時間>/', 'gray'),
  box(24, 48, 172, 44, 'topics.txt', ['partition 數、RF'], 'teal'),
  box(24, 100, 172, 44, 'topic-configs.txt', ['retention 等動態設定'], 'teal'),
  box(24, 152, 172, 44, 'rbac.txt', ['每個 principal 的 binding'], 'purple'),
  box(24, 204, 172, 44, 'users.txt', ['SCRAM 帳號清單、配額'], 'amber'),
  box(24, 256, 172, 44, 'acls.txt、broker-configs、features', ['演練不含；照樣可重建'], 'gray', { dash: true }),
  box(270, 48, 230, 96, '重建 topic', ['kafka-topics --create', '--partitions／--replication-factor', 'kafka-configs --alter --add-config'], 'teal'),
  box(270, 152, 230, 44, '重建 role binding', ['confluent iam rbac role-binding create'], 'purple'),
  box(270, 204, 230, 96, '重建 SCRAM 帳號', ['kafka-configs --alter --add-config', 'SCRAM-SHA-512=[password=…]＋配額', '密碼來自操作機 ~/secrets（備份沒有）'], 'amber'),
  arrow(196, 70, 268, 80), arrow(196, 122, 268, 110), arrow(196, 174, 268, 174), arrow(196, 226, 268, 236),
  box(560, 48, 220, 96, '驗證', ['describe：partition、RF、設定一致', 'role-binding list：條數一致', '帳號從 9095 寫一筆、讀回一筆'], 'blue'),
  arrow(500, 96, 558, 96), arrow(500, 174, 558, 110), arrow(500, 252, 558, 130),
  box(560, 204, 220, 96, '整個叢集沒了？', ['第 8–13 章重裝', '再照這三條路把中繼資料倒回去', '訊息內容靠 RF 3，不在備份裡'], 'coral', { dash: true }),
  box(10, 334, 770, 70, '備份裡沒有的東西', ['訊息內容（靠 replication factor 3）、SCRAM 密碼（操作機 ~/secrets，銀行備份機制）、各主機的設定檔與憑證（29.2 的備份、銀行主機備份）', '所以還原演練的範圍是「中繼資料」：topic、權限、帳號'], 'gray'),
].join(''));

// 22 application SCRAM rotation with an A/B pair (20.6)
D.scramab = () => svg(800, 360, [
  box(20, 30, 170, 90, '① 平常', ['應用程式用 app-x-a', 'app-x-b 閒置（同樣權限）'], 'teal'), num(20, 30, '1'),
  box(220, 30, 170, 90, '② 換 -b 的密碼', ['kafka-configs --alter', 'SCRAM-SHA-512=[password=新]', '應用程式完全不受影響'], 'amber'), num(220, 30, '2'),
  box(420, 30, 170, 90, '③ 應用程式切到 -b', ['改設定、滾動重啟應用', '新連線用 -b，舊連線自然收掉', '流量不中斷'], 'blue'), num(420, 30, '3'),
  box(620, 30, 160, 90, '④ 下次換 -a', ['-a 現在閒置', '同樣的步驟倒過來'], 'gray'), num(620, 30, '4'),
  arrow(190, 75, 218, 75), arrow(390, 75, 418, 75), arrow(590, 75, 618, 75),
  box(20, 160, 370, 80, '密碼怎麼交付', ['新密碼寫進操作者的交接檔（0600，只有本人讀得到）', '交應用程式團隊，交接後刪；不顯示在畫面、不進紀錄'], 'purple'),
  box(410, 160, 370, 80, '驗證', ['-b 新密碼登入成功、-b 舊密碼被拒', '-a 的流量期間 0 錯誤；切換後 -b 寫一筆讀回一筆'], 'blue'),
  box(20, 262, 760, 76, '誰做', ['維運選單 34 建 A／B 一對、35 換「現在沒在用的那個」（kafka-admins）；手動步驟＝選單背後做的事', '單一帳號的舊應用（例如 app-legacy-billing 走憑證、不是 SCRAM）不適用；先用 34 建一對再遷移'], 'gray'),
].join(''));

// helpers for other document builders (non-enumerable, so build.js still sees only diagrams)
Object.defineProperty(D, "_h", { value: { svg, box, arrow, region, note, legend, P, esc } });
module.exports = D;
