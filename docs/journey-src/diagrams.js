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
<defs><marker id="a" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M2 1L8 5L2 9" fill="none" stroke="#444441" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></marker></defs>
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
  let out = `<path d="${pts}" fill="none" stroke="${opts.color || '#444441'}" stroke-width="1.5" ${opts.dash ? 'stroke-dasharray="5 4"' : ''} marker-end="url(#a)"/>`;
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

const D = {};

// 1. cast: our side vs bank side
D.cast = () => svg(760, 300, [
  region(20, 20, 300, 260, '我方（安裝團隊）', 'teal'),
  box(40, 60, 260, 56, '小安', ['新進安裝工程師，本篇主角', '所有「我方」指令由他敲'], 'teal'),
  box(40, 130, 260, 56, '操作機 ops02', ['小安工作的地方（帳號 cpadmin）', '安裝、設定、驗證都從這裡出發'], 'teal'),
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
  box(520, 55, 200, 56, 'repo1.maven.org', ['JMX exporter jar'], 'gray'),
  arrow(210, 83, 258, 83), arrow(480, 83, 518, 83),
  region(20, 150, 720, 230, '行內（離線）', 'amber'),
  box(40, 190, 150, 56, '操作機 ops02', ['cpadmin', '安裝起點'], 'teal'),
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
D.journey = () => svg(760, 230, [
  box(20, 40, 130, 70, '1 下載', ['下載機', 'RPM、jar、公鑰'], 'teal'),
  box(175, 40, 130, 70, '2 驗證', ['雜湊、簽章', '產生 SHA256SUMS'], 'teal'),
  box(330, 40, 130, 70, '3 引進內網', ['掃描、開單', '搬到操作機'], 'amber'),
  box(485, 40, 130, 70, '4 行內準備', ['套件庫、AD、CA', 'JDK、帳號'], 'amber'),
  box(640, 40, 100, 70, '5 安裝', ['操作機出發', '11 台'], 'blue'),
  arrow(150, 75, 173, 75), arrow(305, 75, 328, 75), arrow(460, 75, 483, 75), arrow(615, 75, 638, 75),
  box(20, 140, 230, 56, '5a 主機就緒', ['檢查、OS 調校、裝套件'], 'blue'),
  box(265, 140, 230, 56, '5b 憑證與設定', ['CSR → 銀行簽 → 設定檔'], 'blue'),
  box(510, 140, 230, 56, '5c 啟動與驗證', ['controller → broker → REST → C3'], 'blue'),
  arrow(250, 168, 263, 168), arrow(495, 168, 508, 168),
  legend(20, 218, [['teal', '我方'], ['amber', '銀行'], ['blue', '我方，在行內主機上']]),
].join(''));

// 4. download + verify
D.download = () => svg(760, 250, [
  box(20, 30, 200, 60, '設定 repo、匯入公鑰', ['confluent.repo', 'rpm --import'], 'teal'),
  box(260, 30, 220, 60, 'dnf download --resolve', ['指定精確版本', '相依自動帶入'], 'teal'),
  box(520, 30, 220, 60, '11 個 RPM 到齊', ['全部 confluent-*', '約 3 GB'], 'teal'),
  arrow(220, 60, 258, 60), arrow(480, 60, 518, 60),
  box(20, 130, 200, 60, 'rpm -K 驗簽章', ['每個都要 OK', '非 Confluent 相依只有 bash'], 'teal'),
  box(260, 130, 220, 60, 'jar、OS 套件清單', ['Maven sha1 核對', 'os-packages.txt'], 'teal'),
  box(520, 130, 220, 60, 'SHA256SUMS', ['14 個檔案的雜湊', '之後每一關都用它'], 'teal'),
  arrow(630, 90, 120, 128, null, { via: [[630, 110], [120, 110]] }), arrow(220, 160, 258, 160), arrow(480, 160, 518, 160),
  note(20, 225, '只帶 Confluent 的東西；JDK、OS 套件不下載，列清單交給銀行'),
].join(''));

// 5. into the bank + publish
D.intake = () => svg(760, 220, [
  box(20, 40, 170, 60, '落地區', ['下載機 /out', '14 個檔案'], 'teal'),
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
  box(40, 60, 220, 60, '主機與帳號', ['11 台 RHEL 9 最小安裝', 'cpadmin + SSH 金鑰 + sudo'], 'amber'),
  box(280, 60, 220, 60, 'OS 套件來源', ['repo01 /os/：chrony、firewalld', 'C3 前置、工具'], 'amber'),
  box(520, 60, 200, 60, 'JDK 21', ['交付 tar 到操作機', '由我方安裝'], 'amber'),
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
  box(20, 140, 340, 60, '7 張：kafka-internal、cp-server', ['svc-rest、svc-c3、svc-ops', 'app-legacy-billing、opmenu-breakglass'], 'gray'),
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

// 12. Secrets in the bank's Conjur
D.conjur = () => svg(800, 310, [
  region(20, 28, 290, 262, "銀行 CyberArk", "amber"),
  box(36, 58, 258, 62, "Conjur（Secrets Manager）", ["policy：誰能讀哪個值", "kafka/store-password 等 3 個變數"], "amber"),
  box(36, 136, 258, 62, "PAM Vault + CPM", ["真實來源，CPM 負責輪替", "Vault Synchronizer 同步進 Conjur"], "amber"),
  box(36, 214, 258, 62, "每台主機一個 host 身分", ["host/kafka/kb01 … 各一把 API key", "只能 read，不能 update"], "amber"),
  arrow(165, 136, 165, 122, null, { dash: true }),
  box(400, 50, 210, 62, "server.properties", ["ssl.keystore.password=", "${cyberark:…store-password…}"], "blue"),
  box(400, 130, 210, 62, "config.providers=cyberark", ["csid-secrets-providers jar", "CLASSPATH 由 drop-in 帶入"], "blue"),
  box(400, 210, 210, 62, "服務啟動時", ["1 用 host 身分認證，拿 token", "2 取值填進設定，才開 listener"], "blue"),
  arrow(398, 241, 296, 89, "HTTPS（銀行 CA）", { via: [[352, 241], [352, 89]], lx: 352, ly: 170 }),
  box(640, 50, 140, 62, "小安（ops 身分）", ["把值寫進 Conjur", "可以 update"], "gray"),
  arrow(710, 48, 165, 56, null, { dash: true, via: [[710, 14], [165, 14]] }),
  box(640, 130, 140, 62, "輪替", ["改 AD／CyberArk 的值", "滾動重啟，不改檔"], "gray"),
  box(640, 210, 140, 62, "secret zero", ["host API key 落地 0640", "或改用憑證 authn-cert"], "coral"),
  arrow(638, 241, 612, 241, null, { dash: true }),
].join(""));

// 13. Secret Protection with the master key in the vault
D.secretprotection = () => svg(800, 300, [
  region(20, 28, 250, 262, "銀行 CyberArk（PAM）", "amber"),
  box(36, 60, 218, 62, "Vault：passphrase", ["版本保留，可回滾", "取用要變更單、留紀錄"], "amber"),
  box(36, 150, 218, 62, "PVWA / CCP", ["人取或操作機取", "lab 用 Conjur 代替"], "amber"),
  arrow(145, 150, 145, 122, null, { dash: true }),
  box(320, 40, 210, 62, "操作機（變更時段）", ["取 passphrase → master key", "encrypt / rotate，用完刪"], "blue"),
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
  box(20, 50, 150, 62, "維運人員", ["本機帳號 op01 登入操作機", "輸入自己的 AD 帳密"], "gray"),
  box(220, 50, 200, 62, "OP menu(操作機)", ["只顯示本人有權限的項目", "每步留紀錄:AD 帳號 + os 帳號"], "blue"),
  arrow(170, 81, 218, 81),
  box(470, 50, 150, 62, "MDS", ["AD 帳密換 token", "問:這個人能做什麼?"], "blue"),
  arrow(420, 81, 468, 81),
  box(650, 50, 130, 62, "CyberArk", ["cpadmin SSH 私鑰", "breakglass 憑證"], "amber"),
  arrow(650, 60, 320, 48, "啟動時取 SSH 私鑰進 ssh-agent;91 時取憑證,用完即丟", { via: [[635, 60], [635, 22], [320, 22]], lx: 478, ly: 16, dash: true }),
  box(220, 140, 200, 62, "Kafka 類項目", ["以本人身分走 LDAP listener", "RBAC 依 AD 群組決定"], "blue"),
  arrow(320, 112, 320, 138),
  box(470, 140, 150, 62, "broker", ["topic、權限、lag、稽核"], "gray"),
  arrow(420, 171, 468, 171),
  box(220, 225, 200, 62, "主機類項目(需 Operator)", ["ssh cpadmin@主機", "sudo 只開 restart / journalctl"], "blue"),
  arrow(320, 202, 320, 223),
  box(470, 225, 150, 62, "各主機", ["cpadmin,無 agent", "sudoers 兩段式"], "gray"),
  arrow(420, 256, 468, 256),
].join(""));

// 15. JMX exporter for the bank's Prometheus
D.jmx = () => svg(800, 250, [
  region(20, 28, 300, 200, "每台 controller / broker / REST", "blue"),
  box(40, 60, 260, 62, "Java 程序 + javaagent", ["-javaagent:jmx_prometheus_javaagent.jar", "讀 /etc/confluent/<元件>/jmx-exporter.yml"], "blue"),
  box(40, 140, 260, 62, ":7071 HTTPS + basic auth", ["憑證 = 這台的 keystore", "密碼只存加鹽 SHA-256"], "blue"),
  arrow(170, 122, 170, 138),
  box(380, 60, 180, 62, "操作機產三個檔", ["prometheus-scrape.yml", "alert-rules.yml、ca.pem"], "gray"),
  box(600, 60, 180, 62, "行內 Prometheus", ["三個 job、HTTPS、密碼檔", "9 條告警規則"], "amber"),
  arrow(560, 91, 598, 91, "交付"),
  arrow(690, 122, 302, 171, "每 30 秒抓 /metrics", { via: [[690, 136], [340, 136], [340, 171]], lx: 515, ly: 152 }),
  box(600, 165, 180, 62, "Alertmanager / SIEM", ["銀行既有", "lag 另看 C3"], "amber"),
  arrow(740, 122, 740, 163, null, { dash: true }),
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
  box(220, 170, 160, 100, "階段二：換", ["信任：舊根 + 新根", "出示：新 CA 簽的", "（銀行的 AD、套件庫、", "保管庫也重簽）"], "coral"),
  arrow(380, 220, 418, 220),
  box(420, 170, 160, 100, "階段三：退", ["信任：只有新根", "出示：新 CA 簽的", "舊 CA 簽的一律被拒"], "teal"),
  box(300, 30, 480, 92, "每個階段都要換的信任清單", ["OS：/etc/pki/…/bank-root.pem（bundle，檔名不變）", "我方：truststore.p12（alias）、C3 的 ca.pem、OP menu 的兩份", "行內：Prometheus 的 ca.pem、應用程式的 truststore"], "gray"),
  box(620, 170, 160, 100, "階段三之前確認", ["應用程式已換新憑證", "行內 Prometheus、", "應用程式已信新根"], "gray"),
  arrow(618, 220, 582, 220, null, { dash: true }),
].join(""));

module.exports = D;
