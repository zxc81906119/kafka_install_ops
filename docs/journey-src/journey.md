<!--meta
{
  "kicker": "Confluent Platform 8.3 離線安裝",
  "title": "小安的安裝旅程",
  "subtitle": "手把手走一遍：從外網下載到 Control Center 亮燈，每一步誰做、敲什麼、看到什麼",
  "author": "PoC 團隊",
  "header": "Confluent Platform 安裝旅程 — 手把手",
  "facts": [["版本", "Confluent Platform 8.3.2、Control Center 2.6.1、Java 21"], ["環境", "11 台 RHEL 9 主機（lab 以容器模擬，環境從零自建）"], ["對象", "第一次安裝 Confluent Kafka 的工程師"], ["日期", "2026-10-21"]]
}
-->
[[toc]]

# 0. 開場：小安接到的任務

小安剛進公司，主管丟來一句話：「下週去銀行裝 Kafka，你跟著這本走一遍。」

銀行的環境完全離線，主機連不到外網；安裝用的套件要先在外面下載、驗證、送進去；主機、帳號、AD、憑證都是銀行各團隊準備的。小安要做的，是把 Confluent Platform 裝起來、設好安全、確認每個元件都健康。

這本手冊就是他走過的路。每一步都標明**誰做**、**在哪台機器**、**敲什麼**、**應該看到什麼**。

## 0.1 登場人物

![cast]

練習的時候，銀行端的角色沒有真人，由你自己扮演。看到橘色「銀行」標籤就切換身分，指令照樣敲，這樣流程才不會卡住；正式環境這些事是銀行做的，你只要知道他們做了什麼、怎麼確認。

## 0.2 環境地圖

![map]

| 主機 | 用途 | 誰管 |
|---|---|---|
| dl01 | 外網下載機，唯一能連 Internet 的機器 | 我方 |
| ops02 | 操作機：安裝起點，小安整天待在這裡 | 我方（帳號 cpadmin） |
| kc01、kc02、kc03 | KRaft controller | 我方安裝，銀行提供主機 |
| kb01–kb04 | Kafka broker | 同上 |
| rest01、rest02 | REST Proxy | 同上 |
| c3-01 | Control Center（含內建 Prometheus、Alertmanager） | 同上 |
| repo01 | 行內套件庫 web server，lab 裡兼 NTP | 銀行 |
| ad01 | 行內 AD（lab 用 Samba 模擬） | 銀行 |
| lb01 | 負載平衡（lab 用 nginx 模擬） | 銀行 |

所有主機的 FQDN 是 `<主機>.poc.lab`。

## 0.3 旅程總覽

![journey]

## 0.4 怎麼讀這本

- 綠色標籤 **我方**：小安敲的指令。橘色標籤 **銀行**：銀行各團隊的事，lab 裡由你代勞。
- 每個指令上方都有一行「▶ 在哪台（用哪個帳號）執行」。要換機器的那一個指令（以及每章第一個指令）會附上 lab 裡切過去的指令，例如 `docker exec -it -u cpadmin -w /home/cpadmin lab-ops02-1 bash`；從一台容器換到另一台時，先 `exit` 回到 Git Bash 再切。正式環境則是經 CyberArk 代登（PSMP）ssh 進那台主機。
- 每個指令後面接「預期輸出」。看到的和預期不同就停下來，先弄懂再往下。
- 指令都是一行可以整段貼上的；多行的 `heredoc`（`<<'EOF' … EOF`）要整段一起貼。
- 密碼一律放在檔案裡（權限 0600）再讀進指令，不直接打在畫面上，也不要貼到任何對話裡。

- 指令很長是為了「整段貼上就能跑」。看不懂沒關係，先照做；每一站開頭說這站要做什麼，結尾說看到什麼代表成功。

> 陷阱：確認用的 `ls`、`stat` 看 `/etc/confluent/ssl`、`/var/lib/kafka` 這類 0750 的目錄要加 `sudo`，不然會 Permission denied，誤以為前一步失敗。

### 名詞小抄（看到不懂的回來查）

| 名詞 | 一句話 |
|---|---|
| controller / broker | controller 管叢集（誰是老大、有哪些 topic）；broker 存資料、服務應用程式。兩者都是 Kafka 程式，只是設定不同 |
| KRaft、quorum | Kafka 自己的共識機制，取代 ZooKeeper；3 台 controller 投票選 leader，叫 quorum |
| listener | broker 開的一個「門」，每個門用不同的認證方式。broker 有 4 個：INTERNAL（broker 之間）、TOKEN、CLIENT、LDAP；controller 另有 CONTROLLER（quorum 之間） |
| MDS | Metadata Service，跑在 broker 上的權限服務：驗 AD 帳密、查群組、發 token、管 RBAC |
| RBAC、role binding | 權限控管：把「角色」（例如 SystemAdmin）綁到「身分」（AD 群組或 User:xxx）上 |
| principal | 平台看到的身分名稱，例如 User:app-orders、Group:kafka-admins |
| SCRAM | 帳號密碼式的認證，密碼存在 Kafka 裡；給直連的應用程式用 |
| mTLS | 雙向 TLS：連線兩端都出示憑證。broker 之間、Prometheus 都用它 |
| token（OAUTHBEARER） | MDS 發的短期通行證；C3、REST Proxy、操作機先用憑證向 MDS 換 token，再拿 token 進 TOKEN listener |
| CSR / SAN / EKU | 憑證申請單 / 憑證適用的主機名稱清單 / 憑證用途（serverAuth 給伺服器、clientAuth 給客戶端） |
| keystore / truststore | Java 用的憑證容器：keystore 放自己的私鑰和憑證，truststore 放信任的根憑證 |
| systemd drop-in | 不改 RPM 附的服務設定，另外放一個覆寫檔（`/etc/systemd/system/<unit>.service.d/`） |
| versionlock | dnf 的鎖版本插件，避免 OS 例行更新把 Confluent 升掉 |
| 落地區 | 外網下載好的檔案暫放的地方，經掃描核准後搬進內網 |
| CyberArk PAM／Conjur／CCP | 銀行的特權帳號與機敏資料系統：PAM 管人與帳號（Vault、PVWA、CPM、PSMP），Conjur 給程式拿 secret，CCP 是 PAM 給程式拿密碼的 REST 入口 |
| config provider | Kafka 的擴充點：properties 裡寫 `${provider:路徑:key}`，啟動時由 provider 去外面取值 |
| Secret Protection | Confluent 的密碼加密功能：密文留在 `security.properties`，master key 以環境變數給服務 |
| OP menu | 給維運人員的文字選單：用本人 AD 身分做 Kafka 類作業，主機類作業以 cpadmin ssh、金鑰從保管庫取 |

### 操作機上的檔案放哪

| 目錄 | 放什麼 |
|---|---|
| `~/landing/` | 銀行送進來的檔案（唯讀）：RPM、jar、公鑰、SHA256SUMS、`bank/` 裡的 JDK |
| `~/repo/` | 要上架到套件庫的目錄（含索引） |
| `~/jdk/` | `java.sh`（profile.d 用） |
| `~/pki/` | 私鑰 `keys/`、申請單 `requests/`、銀行回覆 `incoming/`、成品 `certs/`、keystore 密碼 `store.pass` |
| `~/conf/` | 設定檔範本與產生出來的設定、client 連線設定、`kraft.env` |
| `~/secrets/` | 各種密碼檔（0600），只有 cpadmin 讀得到 |

### 每一站大概要多久

| 站 | 時間 | 慢在哪 |
|---|---|---|
| 0 建 lab | 20–30 分 | 建映像檔要連外網下載 |
| 1 下載 | 30–60 分 | 3 GB 從外網抓；lab 的 Windows 資料夾讀寫慢 |
| 2–4 進內網、銀行準備、上架 | 20 分 | 搬 3 GB、建索引 |
| 5–8 JDK、檢查、OS 調校、裝套件 | 30 分 | 11 台逐一 dnf install |
| 9 憑證 | 15 分 | — |
| 10–13 設定、啟動、權限、REST、C3 | 40 分 | 每段啟動要等健康檢查；C3 第一次起來 1–2 分鐘 |
| 15 Conjur（延伸） | 40 分 | 下載機建 jar 要 15–20 分；之後是改設定與滾動重啟 |
| 16 Secret Protection（延伸） | 30 分 | 加密、派送、滾動重啟；16.8 Summon、16.9 AD 密碼改注入各再滾一輪 |
| 17 OP menu（延伸） | 20 分 | 保管庫加身分、裝選單、改 sudoers、三種身分試跑 |
| 18 JMX exporter（延伸） | 20 分 | 派送、滾動重啟、行內 Prometheus 驗證 |
| 19 稽核日誌（延伸） | 20 分 | 帳號、加密派送、滾動重啟、製造事件 |
| 20 驗收與收尾 | 30 分 | 四組檢查；冷開機要等 3 分鐘 |
| 21 憑證輪替 | 30 分／90 分 | leaf 換發一輪一次滾動重啟；換 CA 三階段要三次 |
| 22 升級 | 50 分 | 套件一輪、JDK 一輪滾動重啟（每台 15 秒到 2 分鐘）；controller 要等 quorum 追上 |

## 0.5 自己把 lab 建起來

@role Lab 管理員（扮演銀行） | Windows 終端（Git Bash） | 本機

需要 Docker Desktop 和 Git Bash。整個 lab 放在家目錄的 `kafka-lab/`，不依賴任何現成的專案；下面每個檔案都是用 heredoc 寫出來的，整段貼到 `EOF` 即可。先開一個 Git Bash，做兩個全域設定（之後所有 Windows 端指令都在這個視窗）：

```bash
export MSYS_NO_PATHCONV=1; mkdir -p ~/kafka-lab/{images/node,images/web/tls,images/ad,images/lb,ca,landing,bank-os-repo} && cd ~/kafka-lab && pwd
```

```out
/c/Users/<你>/kafka-lab
```

> `MSYS_NO_PATHCONV=1` 是讓 Git Bash 不要把 `/out`、`/etc/...` 這類容器內路徑轉成 Windows 路徑。給 Docker 的 Windows 路徑一律用 `$(cygpath -m …)` 產生。

### 0.5.1 主機映像檔：模擬「裸機 RHEL 9」

每台主機都是同一個映像：Rocky 9 最小安裝 + systemd + sshd + sudo，帳號 `cpadmin` 只能用金鑰登入。沒有 JDK、沒有 Confluent、公開 repo 關閉，和銀行開給我們的主機一樣。

```bash
cat > images/node/Dockerfile <<'EOF'
FROM rockylinux/rockylinux:9.8
RUN dnf -y install systemd openssh-server openssh-clients sudo tar gzip openssl procps-ng nmap-ncat hostname iproute less which findutils dnf-plugins-core ca-certificates \
    && dnf clean all && rm -f /etc/yum.repos.d/*.repo.rpmnew
RUN useradd -m -s /bin/bash cpadmin && install -d -m 0755 /etc/ssh/authorized_keys.d \
    && printf 'PermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%%u\nUseDNS no\n' > /etc/ssh/sshd_config.d/10-cp.conf \
    && printf 'cpadmin ALL=(ALL) NOPASSWD: ALL\nDefaults:cpadmin !requiretty\n' > /etc/sudoers.d/cpadmin && chmod 0440 /etc/sudoers.d/cpadmin \
    && systemctl enable sshd \
    && systemctl mask systemd-logind.service getty.target console-getty.service systemd-udevd.service \
    && sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/*.repo
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
EOF
docker build -t lab-node:1 "$(cygpath -m "$PWD/images/node")" 2>&1 | tail -1
```

```out
 => => naming to docker.io/library/lab-node:1
```

`sudoers` 給 cpadmin 完整 sudo，對應「變更窗口內由 OS 團隊開放」；正式環境做完要收回。

### 0.5.2 銀行的套件庫 web server（repo01）

銀行自己管的 httpd，只有 HTTPS，唯讀；部署帳號 `repodeploy` 可以用 ssh 寫 `/var/www/repo`，沒有 sudo、沒有 `createrepo_c`：

```bash
cat > images/web/Dockerfile <<'EOF'
FROM lab-node:1
RUN dnf -y --enablerepo=baseos,appstream install httpd mod_ssl && dnf clean all \
    && sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/*.repo \
    && rm -f /etc/sudoers.d/cpadmin \
    && useradd -m -s /bin/bash repodeploy && install -d -o repodeploy -g repodeploy -m 0755 /var/www/repo \
    && rm -f /etc/httpd/conf.d/welcome.conf /etc/httpd/conf.d/ssl.conf \
    && sed -i 's/^Listen 80$/# Listen 80/' /etc/httpd/conf/httpd.conf \
    && printf 'Match User repodeploy\n    AuthorizedKeysFile /etc/ssh/authorized_keys.d/repodeploy\n    AllowTcpForwarding no\n    X11Forwarding no\n' > /etc/ssh/sshd_config.d/20-repo.conf \
    && systemctl enable httpd
COPY repo.conf /etc/httpd/conf.d/repo.conf
EOF
cat > images/web/repo.conf <<'EOF'
Listen 443 https
<VirtualHost *:443>
    ServerName repo01.poc.lab
    SSLEngine on
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLCertificateFile /etc/pki/repo-tls/repo.crt
    SSLCertificateKeyFile /etc/pki/repo-tls/repo.key
    DocumentRoot "/var/www/repo"
    <Directory "/var/www/repo">
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
        <LimitExcept GET HEAD OPTIONS>
            Require all denied
        </LimitExcept>
    </Directory>
</VirtualHost>
EOF
docker build -t lab-web:1 "$(cygpath -m "$PWD/images/web")" 2>&1 | tail -1
```

```out
 => => naming to docker.io/library/lab-web:1
```

憑證 `repo.crt`、`repo.key` 等銀行 CA 建好後再簽（0.5.5）。

### 0.5.3 銀行的 AD（Samba AD DC）

RHEL 系的 Samba 沒有 AD DC 功能，所以這一台用 Debian。第一次啟動時建網域 `CORP.POC.LAB`，之後只是把 samba 跑著：

```bash
cat > images/ad/Dockerfile <<'EOF'
FROM debian:12-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends samba samba-ad-dc samba-ad-provision winbind krb5-user ldb-tools ldap-utils openssh-server sudo procps ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/* && rm -f /etc/samba/smb.conf
RUN useradd -m -s /bin/bash cpadmin && install -d -m 0755 /etc/ssh/authorized_keys.d /run/sshd \
    && echo 'cpadmin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/cpadmin && chmod 0440 /etc/sudoers.d/cpadmin \
    && printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%%u\nUseDNS no\n' > /etc/ssh/sshd_config.d/10-cp.conf
COPY entrypoint.sh /usr/local/sbin/ad-entrypoint
RUN chmod 0755 /usr/local/sbin/ad-entrypoint
VOLUME ["/var/lib/samba", "/etc/samba"]
ENTRYPOINT ["/usr/local/sbin/ad-entrypoint"]
EOF
cat > images/ad/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${AD_REALM:?}" "${AD_DOMAIN:?}" "${AD_ADMIN_PASSWORD:?}"
if [[ ! -f /var/lib/samba/private/sam.ldb ]]; then
  echo "[ad] provisioning domain ${AD_REALM}"
  rm -f /etc/samba/smb.conf
  samba-tool domain provision --use-rfc2307 --realm="${AD_REALM}" --domain="${AD_DOMAIN}" --server-role=dc \
    --dns-backend=SAMBA_INTERNAL --adminpass="${AD_ADMIN_PASSWORD}" --option="dns forwarder = 127.0.0.11" \
    --option="tls enabled = yes" --option="tls keyfile = tls/key.pem" --option="tls certfile = tls/cert.pem" --option="tls cafile = tls/ca.pem"
fi
cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
/usr/sbin/sshd
while true; do
  echo "[ad] starting samba"
  samba --foreground --no-process-group --debug-stdout || true
  echo "[ad] samba exited, restarting in 2s"; sleep 2
done
EOF
docker build -t lab-ad:1 "$(cygpath -m "$PWD/images/ad")" 2>&1 | tail -1
```

```out
 => => naming to docker.io/library/lab-ad:1
```

### 0.5.4 銀行的負載平衡（nginx L4）

```bash
cat > images/lb/Dockerfile <<'EOF'
FROM nginx:1.28
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server sudo procps && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash cpadmin && install -d -m 0755 /etc/ssh/authorized_keys.d /run/sshd /etc/nginx/stream.d \
    && echo 'cpadmin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/cpadmin && chmod 0440 /etc/sudoers.d/cpadmin \
    && printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nAuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%%u\nUseDNS no\n' > /etc/ssh/sshd_config.d/10-cp.conf \
    && printf '\nstream {\n    include /etc/nginx/stream.d/*.conf;\n}\n' >> /etc/nginx/nginx.conf && rm -f /etc/nginx/conf.d/default.conf \
    && printf '#!/bin/sh\n/usr/sbin/sshd\nexec nginx -g "daemon off;"\n' > /usr/local/sbin/lb-entrypoint && chmod 0755 /usr/local/sbin/lb-entrypoint
ENTRYPOINT ["/usr/local/sbin/lb-entrypoint"]
EOF
docker build -t lab-lb:1 "$(cygpath -m "$PWD/images/lb")" 2>&1 | tail -1 && docker images --format '{{.Repository}}:{{.Tag}}' | grep -c '^lab-'
```

```out
 => => naming to docker.io/library/lab-lb:1
4
```

### 0.5.5 銀行的 CA：根憑證、簽發 CA、簽發程序

@role 銀行 CA 窗口 | Windows 終端 | 本機

正式環境這是行內 PKI；lab 用 openssl 建一個兩層 CA（根 CA 離線保存，簽發 CA 簽日常憑證）：

```bash
cd ~/kafka-lab/ca && openssl genrsa -out root.key 4096 2>/dev/null && openssl req -x509 -new -key root.key -sha256 -days 7300 -out root.crt -subj "/CN=PoC Bank Root CA/O=PoC Bank/C=TW" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" && openssl genrsa -out issuing.key 4096 2>/dev/null && openssl req -new -key issuing.key -sha256 -subj "/CN=PoC Bank Issuing CA 01/O=PoC Bank/C=TW" -out issuing.csr && printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' > issuing.ext && openssl x509 -req -in issuing.csr -CA root.crt -CAkey root.key -CAcreateserial -days 3650 -sha256 -extfile issuing.ext -out issuing.crt 2>/dev/null && rm -f issuing.csr issuing.ext && openssl verify -CAfile root.crt issuing.crt && openssl x509 -in root.crt -noout -fingerprint -sha256
```

```out
issuing.crt: OK
sha256 Fingerprint=…
```

指紋是銀行會另外公布的資訊，之後我方匯入根憑證時用來核對。

簽發程序寫成一支小腳本 `sign.sh`：檢查 CSR（RSA ≥ 2048、有 CN、不是 CA、必須帶 EKU 且只允許 serverAuth／clientAuth），照 CSR 裡的 SAN 和 EKU 簽一年，回傳「憑證 + 簽發 CA」。Git Bash 的 `openssl` 是 Windows 原生程式，看不懂 `/c/Users/...` 這種路徑，所以腳本裡用 `cygpath -m` 轉成 `C:/Users/...`：

```bash
cat > ~/kafka-lab/ca/sign.sh <<'EOF'
#!/usr/bin/env bash
# sign.sh <csr> <out.crt>  - the bank's issuing policy
set -euo pipefail
d=$(cd "$(dirname "$0")" && pwd); csr=$1; out=$2
# Git Bash: openssl is a native Windows build, so hand it Windows-style paths (no-op on Linux)
command -v cygpath >/dev/null && { d=$(cygpath -m "$d"); csr=$(cygpath -m "$csr"); out=$(cygpath -m "$out"); }
tmpf() { local t; t=$(mktemp); command -v cygpath >/dev/null && t=$(cygpath -m "$t"); echo "$t"; }
ext() { openssl req -in "$csr" -noout -text | awk -v h="$1" 'f {gsub(/^ +/, ""); print; exit} index($0, h) {f=1}'; }
openssl req -in "$csr" -noout -verify >/dev/null 2>&1 || { echo "REJECT: CSR signature invalid"; exit 1; }
bits=$(openssl req -in "$csr" -noout -text | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p'); [ "${bits:-0}" -ge 2048 ] || { echo "REJECT: key < 2048"; exit 1; }
subj=$(openssl req -in "$csr" -noout -subject -nameopt oneline | sed 's/^subject= *//'); [[ $subj == *"CN = "* ]] || { echo "REJECT: no CN"; exit 1; }
[[ $(ext "Basic Constraints") == *CA:TRUE* ]] && { echo "REJECT: CA requested"; exit 1; }
san=$(ext "Subject Alternative Name" | sed 's/IP Address:/IP:/g; s/, /,/g')
eku=$(ext "Extended Key Usage" | sed 's/TLS Web Server Authentication/serverAuth/; s/TLS Web Client Authentication/clientAuth/; s/, /,/g')
[ -n "$eku" ] || { echo "REJECT: extended key usage must be requested"; exit 1; }
[[ $eku =~ ^(serverAuth|clientAuth)(,(serverAuth|clientAuth))?$ ]] || { echo "REJECT: EKU $eku not allowed"; exit 1; }
e=$(tmpf); { printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=%s\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n' "$eku"; [ -n "$san" ] && printf 'subjectAltName=%s\n' "$san"; } > "$e"
openssl x509 -req -in "$csr" -CA "$d/issuing.crt" -CAkey "$d/issuing.key" -CAcreateserial -days 365 -sha256 -extfile "$e" -out "$out.tmp" 2>/dev/null
rm -f "$e"; cat "$out.tmp" "$d/issuing.crt" > "$out"; rm -f "$out.tmp"
echo "signed $(basename "$csr") -> $(basename "$out")  ($subj; EKU $eku)"
EOF
chmod +x ~/kafka-lab/ca/sign.sh && echo sign.sh ok
```

用它幫 repo01 簽 HTTPS 憑證（銀行自己的伺服器，私鑰直接放到映像會掛載的目錄）：

```bash
cd ~/kafka-lab && openssl req -new -newkey rsa:3072 -nodes -keyout images/web/tls/repo.key -out images/web/tls/repo.csr -subj "/CN=repo01.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:repo01.poc.lab,DNS:repo01" -addext "extendedKeyUsage=serverAuth" 2>/dev/null && bash ca/sign.sh images/web/tls/repo.csr images/web/tls/repo.crt && rm -f images/web/tls/repo.csr
```

```out
signed repo.csr -> repo.crt  (CN = repo01.poc.lab, O = PoC Bank, C = TW; EKU serverAuth)
```

### 0.5.6 主機清單（compose）與密碼檔

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

14 台主機、一個不連外的內部網路。所有主機共用一個 `authorized_keys.d` volume（模擬 OS 團隊統一派送公鑰）。AD 的管理員密碼放在 `secrets.env`：

```bash
cd ~/kafka-lab && [ -f secrets.env ] || printf 'AD_ADMIN_PASSWORD=%s\n' "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)" > secrets.env; cat > compose.yml <<'EOF'
name: lab
x-hosts: &hosts
  - "ops02.poc.lab=172.35.0.10"
  - "ops02=172.35.0.10"
  - "ad01.poc.lab=172.35.0.11"
  - "ad01=172.35.0.11"
  - "lb01.poc.lab=172.35.0.12"
  - "lb01=172.35.0.12"
  - "rest.poc.lab=172.35.0.12"
  - "c3.poc.lab=172.35.0.12"
  - "repo01.poc.lab=172.35.0.14"
  - "repo01=172.35.0.14"
  - "kc01.poc.lab=172.35.0.21"
  - "kc01=172.35.0.21"
  - "kc02.poc.lab=172.35.0.22"
  - "kc02=172.35.0.22"
  - "kc03.poc.lab=172.35.0.23"
  - "kc03=172.35.0.23"
  - "kb01.poc.lab=172.35.0.31"
  - "kb01=172.35.0.31"
  - "kb02.poc.lab=172.35.0.32"
  - "kb02=172.35.0.32"
  - "kb03.poc.lab=172.35.0.33"
  - "kb03=172.35.0.33"
  - "kb04.poc.lab=172.35.0.34"
  - "kb04=172.35.0.34"
  - "rest01.poc.lab=172.35.0.41"
  - "rest01=172.35.0.41"
  - "rest02.poc.lab=172.35.0.42"
  - "rest02=172.35.0.42"
  - "c3-01.poc.lab=172.35.0.51"
  - "c3-01=172.35.0.51"
x-node: &node
  image: lab-node:1
  domainname: poc.lab
  privileged: true
  cgroup: host
  stop_signal: SIGRTMIN+3
  tmpfs: [ /run, /run/lock, "/tmp:exec,mode=1777,size=2g" ]
  volumes:
    - /sys/fs/cgroup:/sys/fs/cgroup:rw
    - ssh-keys:/etc/ssh/authorized_keys.d:ro
  extra_hosts: *hosts
  environment: { TZ: Asia/Taipei }
  ulimits: { nofile: { soft: 128000, hard: 128000 }, nproc: 65536 }
  restart: unless-stopped
services:
  ops02:
    <<: *node
    hostname: ops02
    networks: { labnet: { ipv4_address: 172.35.0.10 } }
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - ssh-keys:/etc/ssh/authorized_keys.d
      - ops-home:/home/cpadmin
  repo01:
    <<: *node
    image: lab-web:1
    hostname: repo01
    networks: { labnet: { ipv4_address: 172.35.0.14 } }
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
      - ssh-keys:/etc/ssh/authorized_keys.d:ro
      - ./images/web/tls:/etc/pki/repo-tls:ro
      - repo-web:/var/www/repo
  ad01:
    image: lab-ad:1
    hostname: ad01
    domainname: poc.lab
    privileged: true
    networks: { labnet: { ipv4_address: 172.35.0.11 } }
    extra_hosts: *hosts
    env_file: secrets.env
    environment: { AD_REALM: CORP.POC.LAB, AD_DOMAIN: CORP, TZ: Asia/Taipei }
    volumes:
      - ssh-keys:/etc/ssh/authorized_keys.d:ro
      - ad-data:/var/lib/samba
      - ad-etc:/etc/samba
    restart: unless-stopped
  lb01:
    image: lab-lb:1
    hostname: lb01
    domainname: poc.lab
    networks:
      labnet: { ipv4_address: 172.35.0.12 }
      frontnet: { ipv4_address: 172.36.0.12 }
    ports: [ "18082:8082", "19021:9021" ]
    extra_hosts: *hosts
    environment: { TZ: Asia/Taipei }
    volumes:
      - ssh-keys:/etc/ssh/authorized_keys.d:ro
    restart: unless-stopped
  kc01: { <<: *node, hostname: kc01, networks: { labnet: { ipv4_address: 172.35.0.21 } } }
  kc02: { <<: *node, hostname: kc02, networks: { labnet: { ipv4_address: 172.35.0.22 } } }
  kc03: { <<: *node, hostname: kc03, networks: { labnet: { ipv4_address: 172.35.0.23 } } }
  kb01: { <<: *node, hostname: kb01, networks: { labnet: { ipv4_address: 172.35.0.31 } } }
  kb02: { <<: *node, hostname: kb02, networks: { labnet: { ipv4_address: 172.35.0.32 } } }
  kb03: { <<: *node, hostname: kb03, networks: { labnet: { ipv4_address: 172.35.0.33 } } }
  kb04: { <<: *node, hostname: kb04, networks: { labnet: { ipv4_address: 172.35.0.34 } } }
  rest01: { <<: *node, hostname: rest01, networks: { labnet: { ipv4_address: 172.35.0.41 } } }
  rest02: { <<: *node, hostname: rest02, networks: { labnet: { ipv4_address: 172.35.0.42 } } }
  c3-01:
    <<: *node
    hostname: c3-01
    ulimits: { nofile: { soft: 65536, hard: 65536 } }
    networks: { labnet: { ipv4_address: 172.35.0.51 } }
networks:
  labnet:
    internal: true
    ipam: { config: [ { subnet: 172.35.0.0/24 } ] }
  frontnet:
    ipam: { config: [ { subnet: 172.36.0.0/24 } ] }
volumes:
  ssh-keys:
  ops-home:
  repo-web:
  ad-data:
  ad-etc:
EOF
docker compose -f compose.yml up -d 2>&1 | grep -c Started
```

```out
14
```

`labnet` 是 `internal: true`：主機連不到外網，和銀行一樣。

> 陷阱：數字若是 13，通常是 lb01 第一次沒起來（它要同時接兩個網路），再下一次同樣的 `up -d` 就會補起來。

> 陷阱：若出現 `Pool overlaps with other one on this address space`，表示這台電腦已有其他 Docker 網路用了 172.35 或 172.36 網段（`docker network ls` 逐一 `docker network inspect` 看 Subnet）。把 compose.yml 裡 `subnet:` 和所有 `extra_hosts` 的 IP 一起換成沒人用的網段（例如 172.37.0.0/24）再 `up -d`。lb01 多接了一個 `frontnet` 並對應 Windows 的 18082、19021，讓你的瀏覽器連得到 C3。

### 0.5.7 下載機

下載機要能連外網，所以不在 `labnet` 裡；它的 `/out` 掛到 `~/kafka-lab/landing`，就是落地區：

```bash
docker run -d --name dl01 --hostname dl01 -v "$(cygpath -m "$HOME/kafka-lab/landing"):/out" lab-node:1 sleep infinity >/dev/null && docker exec dl01 bash -c 'dnf config-manager --set-enabled baseos appstream extras; curl -s -o /dev/null -w "internet: %{http_code}\n" https://packages.confluent.io/rpm/8.3/'
```

```out
internet: 200
```

### 0.5.8 進入各台機器

之後會一直用到的三條（換主機名稱即可）：

```bash
docker exec -it dl01 bash
```

```bash
docker exec -it -u cpadmin -w /home/cpadmin lab-ops02-1 bash
```

```bash
docker exec -it lab-repo01-1 bash
```

第一個是下載機（root），第二個是操作機（cpadmin），第三個是銀行的主機（root，扮演銀行時用）。「銀行」標籤但主機是 ops02 的步驟（例如 3.1 放公鑰），要用 root 進 ops02：

```bash
docker exec -it lab-ops02-1 bash
```

### 0.5.9 收工與重開

想暫停：`cd ~/kafka-lab && docker compose -f compose.yml stop`，資料都在 volume 裡；繼續：`docker compose -f compose.yml start`。Windows 重開機後容器會自己起來（`restart: unless-stopped`），Kafka 服務設了 enable 也會自己起來；只有下載機 dl01 要手動 `docker start dl01`。全部清掉重來：`docker compose -f compose.yml down -v && docker rm -f dl01`（落地區 `~/kafka-lab/landing` 不會被刪）。

> 陷阱：要重跑第 0 章（重建映像、重產 CA）之前**一定先 `down -v`**。只 `down` 或直接再 `up -d` 會留下舊的 volume：ops02 的 `~/pki`、`~/conf` 還是舊 CA 簽的、AD 裡帳號已存在，後面第 3、9 站會出現「鏈驗證失敗」「ou already exists」這類看似莫名的錯。

# 1. 第一站：外網下載機

![download]

小安的第一個任務：把 Confluent 的套件抓下來，而且只抓需要的。Java 和 OS 套件不下載，那是銀行的事。

## 1.1 設定 Confluent repo、匯入原廠公鑰

@role 小安 | dl01 | root

```bash
mkdir -p /out/rpm /out/gpg-keys /out/tools && curl -fsSL https://packages.confluent.io/rpm/8.3/archive.key -o /out/gpg-keys/confluent.asc && curl -fsSL https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key -o /out/gpg-keys/confluent-c3.asc && rpm --import /out/gpg-keys/confluent.asc /out/gpg-keys/confluent-c3.asc && rpm -q gpg-pubkey --qf '%{SUMMARY}\n' | grep -i confluent
```

```out
Confluent Packaging <packages@confluent.io> public key
```

兩個網址給的其實是同一把公鑰，所以只會出現一行。

```bash
cat > /etc/yum.repos.d/confluent.repo <<'EOF'
[confluent-8.3]
name=Confluent 8.3
baseurl=https://packages.confluent.io/rpm/8.3
gpgcheck=1
gpgkey=https://packages.confluent.io/rpm/8.3/archive.key
enabled=1

[confluent-c3]
name=Confluent Control Center next-gen
baseurl=https://packages.confluent.io/confluent-control-center-next-gen/rpm/
gpgcheck=1
gpgkey=https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key
enabled=1
EOF
dnf list --showduplicates confluent-server confluent-control-center-next-gen | grep -E '8\.3\.|2\.6\.'
```

```out
confluent-control-center-next-gen.noarch         2.6.0-1           confluent-c3
confluent-control-center-next-gen.noarch         2.6.1-1           confluent-c3
confluent-server.noarch                          1:8.3.0-1         confluent-8.3
confluent-server.noarch                          1:8.3.1-1         confluent-8.3
confluent-server.noarch                          1:8.3.2-1         confluent-8.3
```

會列出同一主版的所有小版本，確認 8.3.2 和 2.6.1 在清單裡就好。

> 第一次執行會先下載 repo 的中繼資料（幾十 MB），等一兩分鐘是正常的。

## 1.2 下載：指定精確版本

@role 小安 | dl01 | root

`--resolve` 會把 Confluent 自己的相依一起抓；因為下載機和正式主機是同版、同樣最小安裝，它不會多抓也不會漏抓。

```bash
dnf download --resolve --arch x86_64 --arch noarch --destdir /out/rpm confluent-server-8.3.2 confluent-security-8.3.2 confluent-kafka-rest-8.3.2 confluent-cli-8.3.2 confluent-control-center-next-gen-2.6.1
```

約 3 GB，lab 裡因為落地區是 Windows 資料夾，最後核對檔案那段會慢（看起來像卡在 99%），耐心等它結束。

```bash
ls /out/rpm | sort && ls /out/rpm | wc -l
```

```out
confluent-ce-kafka-http-server-8.3.2-1.noarch.rpm
confluent-cli-8.3.2-1.x86_64.rpm
confluent-common-8.3.2-1.noarch.rpm
confluent-control-center-next-gen-2.6.1-1.noarch.rpm
confluent-kafka-rest-8.3.2-1.noarch.rpm
confluent-metadata-service-8.3.2-1.noarch.rpm
confluent-rest-utils-8.3.2-1.noarch.rpm
confluent-security-8.3.2-1.noarch.rpm
confluent-server-8.3.2-1.noarch.rpm
confluent-server-rest-8.3.2-1.noarch.rpm
confluent-telemetry-8.3.2-1.noarch.rpm
11
```

11 個，全部是 `confluent-*`。

## 1.3 驗原廠簽章、確認相依

@role 小安 | dl01 | root

```bash
rpm -K /out/rpm/*.rpm
```

```out
/out/rpm/confluent-ce-kafka-http-server-8.3.2-1.noarch.rpm: digests signatures OK
（每一行都是 digests signatures OK）
```

Confluent 的 RPM 需要哪些非 Confluent 的東西？答案應該只有 bash 和 glibc：

```bash
rpm -qpR /out/rpm/*.rpm 2>/dev/null | grep -vE '^(confluent-|rpmlib\(|config\()' | sort -u | xargs -d '\n' rpm -q --whatprovides | sort -u
```

```out
bash-5.1.8-9.el9.x86_64
glibc-2.34-168.el9_8.x86_64
（版本號依映像而異，重點是只有這兩個）
```

## 1.4 監控用的 jar、給銀行的 OS 套件清單

@role 小安 | dl01 | root

JMX exporter 不是 RPM，用 Maven Central 的 sha1 核對：

```bash
curl -fsSL -o /out/tools/jmx_prometheus_javaagent-1.0.1.jar https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar && [ "$(sha1sum /out/tools/jmx_prometheus_javaagent-1.0.1.jar | cut -d' ' -f1)" = "$(curl -fsSL https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar.sha1)" ] && echo jar-sha1-ok
```

```out
jar-sha1-ok
```

平台還需要幾個 OS 套件，由銀行的套件庫提供。先確認它們都在 RHEL 標準 repo 裡、在哪個 repo，做成清單交給銀行：

```bash
dnf -q repoquery --latest-limit 1 --qf '%{name}\t%{version}-%{release}\t%{repoid}' chrony firewalld cyrus-sasl openssl-devel python3-dnf-plugin-versionlock gettext createrepo_c | sort -u | tee /out/os-packages.txt
```

```out
chrony	4.8-1.el9	baseos
createrepo_c	0.20.1-4.el9	appstream
cyrus-sasl	2.1.27-22.el9_7	appstream
cyrus-sasl	2.1.27-22.el9_7	baseos
firewalld	1.3.4-20.el9_8	baseos
gettext	0.21-8.el9	baseos
openssl-devel	3.5.8-2.el9_8	appstream
python3-dnf-plugin-versionlock	4.3.0-26.el9	baseos
```

| 套件 | 哪些主機 | 為什麼 |
|---|---|---|
| chrony、firewalld | 全部 | 時間同步、主機防火牆 |
| cyrus-sasl、openssl-devel | C3 | 原廠文件要求的前置套件 |
| python3-dnf-plugin-versionlock | 裝 Confluent 的主機 | 鎖版本，避免 OS 例行更新把 Confluent 升掉 |
| gettext、createrepo_c | 操作機 | `envsubst` 由範本產生設定檔；建內部套件庫的索引（第 4 站） |

銀行的 OS 套件庫本來就是完整的 RHEL，這份清單只是讓銀行確認這幾個在。lab 在 3.2 自己建 `/os/` 時多放了 httpd、jq、openldap-clients 等，那是 lab 主機自己要用的工具，不是交給銀行的需求。

## 1.5 順便替銀行抓 JDK（銀行交付的檔案）

@role 銀行 OS 團隊（lab 由下載機代勞） | dl01 | root

正式環境 JDK 是銀行交付的；lab 沒有銀行，就用這台下載機從 Adoptium 抓最新的 Temurin 21，連同官方的 sha256 一起放到 `/out/bank/`，當作「銀行給的檔案」：

```bash
mkdir -p /out/bank && meta=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/21/hotspot?os=linux&architecture=x64&image_type=jdk&vendor=eclipse") && url=$(echo "$meta" | grep -o '"link": *"[^"]*\.tar\.gz"' | head -1 | cut -d'"' -f4) && sha=$(echo "$meta" | grep -o '"checksum": *"[0-9a-f]\{64\}"' | head -1 | cut -d'"' -f4) && f=$(basename "$url") && curl -fsSL -o "/out/bank/$f" "$url" && echo "$sha  $f" > "/out/bank/$f.sha256" && (cd /out/bank && sha256sum -c --quiet "$f.sha256" && echo "jdk-ok: $f")
```

```out
jdk-ok: OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz
```

檔名裡的版本號跟著 Adoptium 當下的最新版走，之後的指令都用萬用字元找它，不用改。

## 1.6 整批的雜湊清單

@role 小安 | dl01 | root

```bash
cd /out && find rpm tools gpg-keys -type f | LC_ALL=C sort | xargs sha256sum > SHA256SUMS && wc -l SHA256SUMS
```

```out
14 SHA256SUMS
```

11 個 RPM、1 個 jar、2 把公鑰（JDK 是銀行的檔案，有自己的 sha256，不列在這裡）。這份 `SHA256SUMS` 之後每一關都會再用一次。下載機的工作到此結束。

# 2. 第二站：把東西送進銀行

![intake]

## 2.1 掃描與開單

@role 銀行 資安 | 行內掃描平台 | —

正式環境：落地區的檔案上傳到行內的惡意程式掃描平台取得 OK 報告，開單時附上安裝檔、掃描報告、`SHA256SUMS`。注意 `confluent-security`（1.13 GB）和 C3（1.0 GB）單檔都超過 1 GB，要先確認平台的大小上限。lab 裡略過。

## 2.2 檔案交換：送到操作機

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

正式環境由行內的檔案交換平台把核准的檔案送到操作機。lab 用 `docker cp` 模擬，送到 cpadmin 的 `~/landing`，唯讀：

```bash
docker cp "$(cygpath -m "$HOME/kafka-lab/landing")/." lab-ops02-1:/home/cpadmin/landing/ && docker exec lab-ops02-1 bash -c 'chown -R cpadmin:cpadmin /home/cpadmin/landing && chmod -R a-w /home/cpadmin/landing && find /home/cpadmin/landing -type f | wc -l && du -sh /home/cpadmin/landing'
```

```out
18
3.1G	/home/cpadmin/landing
```

## 2.3 進內網後再驗一次

@role 小安 | ops02 | cpadmin

這是第二關，目的是證明搬運途中沒被動過，用的是一起送進來的 `SHA256SUMS`：

```bash
cd ~/landing && sha256sum -c --quiet SHA256SUMS && echo "$(wc -l < SHA256SUMS) files OK"
```

```out
14 files OK
```

`rpm -K` 只認 rpm 資料庫裡的公鑰，所以要先匯入：

```bash
sudo rpm --import ~/landing/gpg-keys/confluent.asc ~/landing/gpg-keys/confluent-c3.asc && rpm -K ~/landing/rpm/*.rpm
```

```out
/home/cpadmin/landing/rpm/confluent-ce-kafka-http-server-8.3.2-1.noarch.rpm: digests signatures OK
（11 行都 OK）
```

## 2.4 之後再帶進來的檔案

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

延伸章節還會陸續帶檔案進來：15.3 建的 provider jar（`tools/csid`）、16.8 的 Summon（`tools/summon`）、17.3 的選單套件（`tools/opmenu`）、第 22 章的新版 RPM 與 JDK。流程和第 2 站一樣（掃描、交換、進來後驗 sha256），只是一次送一個目錄。`~/landing` 是唯讀的，所以由 root 放進去再收回寫入權限（`D` 換成要送的目錄）：

```bash
D=opmenu && docker cp "$(cygpath -m "$HOME/kafka-lab/landing/tools/$D")" lab-ops02-1:/home/cpadmin/landing/tools/ && docker exec lab-ops02-1 bash -c "chown -R cpadmin:cpadmin /home/cpadmin/landing/tools/$D && chmod -R a-w /home/cpadmin/landing/tools/$D && cd /home/cpadmin/landing/tools/$D && ls && sha256sum -c --quiet SHA256SUMS && echo sha256-ok"
```

```out
SHA256SUMS
opmenu-20261023.0655fe43.tar.gz
sha256-ok
```

# 3. 第三站：銀行準備好了嗎

![bankprep]

小安在等的時候，銀行各團隊在做自己的事。這一章全部是銀行的工作，lab 裡由你扮演。正式環境只要確認結果（第 6 章的安裝前檢查會逐項看）。

開主機的時候，原廠對虛擬機與磁碟有幾條硬性建議，要在開單時就交代給 OS／虛擬化團隊（lab 是容器，沒有這些）：

| 項目 | 原廠建議 | 為什麼 |
|---|---|---|
| VMware vMotion、磁碟快照 | 平台主機**停用** | 原廠：用在 Kafka／KRaft 上可能造成整個叢集中斷 |
| 資料碟 | broker 的 Kafka 資料放在**獨立的磁碟**，不和 OS、應用程式日誌共用 | 寫入延遲要穩定 |
| RAID | RAID 10（或 RAID 1）優先；**不建議 RAID 5** | 重建期間效能與可靠度 |
| 檔案系統 | XFS 或 ext4 | 原廠只支援這兩種（第 6 章會檢查） |
| JDK | 完整 JDK（不是 headless／JRE） | 原廠支援排錯時需要（這本用的 Temurin tar 就是完整 JDK） |

## 3.1 安裝帳號與 SSH 金鑰

@role 小安 | ops02 | cpadmin

每台主機都已經有 `cpadmin` 帳號（主機範本開出來就有）。小安產生操作機的金鑰，把公鑰交給銀行：

```bash
ssh-keygen -q -t ed25519 -N '' -C "cpadmin@ops02" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub
```

```out
ssh-ed25519 AAAA…… cpadmin@ops02
```

@role 銀行 OS 團隊 | ops02 | root

用 root 進 ops02（`docker exec -it lab-ops02-1 bash`，不是 cpadmin 那條）。正式環境是 OS 團隊把公鑰**逐台**放進每台主機 cpadmin 的 `~/.ssh/authorized_keys`（或由 CyberArk 的 SSH 金鑰管理推送）。

lab 只要在 ops02 寫一次，11 台同時生效，靠的是第 0 章的兩個安排：

- **同一個目錄掛在每台主機上**：`compose.yml` 把 volume `ssh-keys` 掛到每台的 `/etc/ssh/authorized_keys.d`，只有 ops02 可寫，其他主機唯讀（`:ro`）。
- **sshd 會讀這個目錄**：每台的 sshd 設定 `AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u`，cpadmin 登入時除了家目錄的 `authorized_keys`，也看 `/etc/ssh/authorized_keys.d/cpadmin`。

所以下面寫進 `/etc/ssh/authorized_keys.d/cpadmin`，等於一次放進所有主機的 cpadmin；再下一步從 ops02 逐台 `ssh` 就是在驗證這件事。`repodeploy` 是套件庫（repo01）的部署帳號，也用同一把：

```bash
k=$(cat /home/cpadmin/.ssh/id_ed25519.pub); install -m 0644 -o root -g root /dev/stdin /etc/ssh/authorized_keys.d/cpadmin <<<"$k"; install -m 0644 -o root -g root /dev/stdin /etc/ssh/authorized_keys.d/repodeploy <<<"$k"; ls -la /etc/ssh/authorized_keys.d/
```

```out
-rw-r--r-- 1 root root   95 … cpadmin
-rw-r--r-- 1 root root   95 … repodeploy
```

> 正式環境有 CyberArk 的話：金鑰對由 CyberArk 產生、公鑰由它推到各主機、私鑰在變更窗口從 PVWA 取出放到操作機。指令不變，只是金鑰的來源不同。

@role 小安 | ops02 | cpadmin

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new $h.poc.lab hostname; done; ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new repodeploy@repo01.poc.lab 'hostname; ls /var/www/repo'
```

```out
Warning: Permanently added 'ops02.poc.lab' (ED25519) to the list of known hosts.
ops02
（每台一句 Warning 加一行主機名）
c3-01
repo01
```

清單包含操作機自己（之後的迴圈會 `ssh ops02` 檢查自己這台）。第一次連線會印 `Warning: Permanently added …`，那是把對方的主機金鑰記進 `known_hosts`，不是錯誤。repo01 的 `/var/www/repo` 這時還是空的，下一站才會放東西。

## 3.2 OS 套件來源與根憑證信任

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

正式環境這是 Satellite 或 Nexus；lab 用 repo01 的 `/os/` 路徑模擬。先在一個乾淨容器把需要的 OS 套件抓下來並建索引。**先下載、再裝工具**，順序反了會漏掉工具自己的相依：

```bash
cd ~/kafka-lab && docker run --rm -v "$(cygpath -m "$PWD/bank-os-repo"):/out" lab-node:1 bash -c '
set -e
R="--disablerepo=* --enablerepo=baseos,appstream,extras"
dnf -q $R download --resolve --arch x86_64 --arch noarch --destdir /out/Packages chrony firewalld cyrus-sasl openssl-devel httpd mod_ssl python3-dnf-plugin-versionlock nmap-ncat jq gettext openldap-clients createrepo_c tar gzip openssl sudo openssh-server diffutils less vim-minimal bind-utils lsof procps-ng rsync bash-completion
dnf -q -y $R install createrepo_c >/dev/null
createrepo_c -q /out
ls /out/Packages | wc -l' && docker cp "$(cygpath -m "$PWD/bank-os-repo")/." lab-repo01-1:/var/www/repo/os/ && docker exec lab-repo01-1 bash -c 'chown -R repodeploy:repodeploy /var/www/repo/os; ls /var/www/repo/os'
```

```out
88
Packages
repodata
```

數字是當下 Rocky repo 解析出來的套件數，約 85–90 都正常。

銀行的根憑證（0.5.5 建的 `ca/root.crt`）放進每台主機的信任清單，並給每台一份指向套件庫的 repo 設定：

```bash
ROOT="$(cygpath -m "$HOME/kafka-lab/ca/root.crt")"; for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker cp "$ROOT" lab-$h-1:/etc/pki/ca-trust/source/anchors/bank-root.pem && docker exec lab-$h-1 bash -c 'update-ca-trust && cat > /etc/yum.repos.d/bank-os.repo <<EOF
[bank-os]
name=Bank OS packages
baseurl=https://repo01.poc.lab/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
EOF
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9' && printf '%s ' "$h"; done; echo
```

```out
ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
```

正式環境的 RHEL 主機本來就信任行內 CA、也已經註冊到 Satellite，這兩件事是主機範本的一部分。

## 3.3 JDK 21：銀行交付的 tar

@role 銀行 OS 團隊 | — | —

銀行只交付壓縮檔，不裝、不設定。lab 裡那個檔案在 1.5 已經由下載機抓好，隨落地區一起送到了操作機的 `~/landing/bank/`，附銀行提供的 sha256。小安先核對一次：

@role 小安 | ops02 | cpadmin

```bash
cd ~/landing/bank && sha256sum -c --quiet *.sha256 && ls
```

```out
OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz
OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz.sha256
```

## 3.4 AD：群組、唯讀查詢帳號、LDAPS 憑證

@role 銀行 AD 團隊 | ad01 | root

密碼先產生到檔案，用環境變數傳進指令，不打在畫面上：

```bash
install -d -m 0700 /root/secrets && for k in bind users; do openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20 > /root/secrets/$k.pass; done; B=DC=corp,DC=poc,DC=lab; samba-tool ou create "OU=Confluent,$B" && for ou in Users Groups Service; do samba-tool ou create "OU=$ou,OU=Confluent,$B"; done && samba-tool user create svc-mds-bind "$(cat /root/secrets/bind.pass)" --userou="OU=Service,OU=Confluent" --description="read-only LDAP bind for Confluent MDS" && for g in kafka-admins kafka-operators kafka-devs; do samba-tool group add "$g" --groupou="OU=Groups,OU=Confluent"; done && for p in alice:kafka-admins bob:kafka-operators carol:kafka-devs; do u=${p%%:*}; g=${p#*:}; samba-tool user create "$u" "$(cat /root/secrets/users.pass)" --userou="OU=Users,OU=Confluent" && samba-tool group addmembers "$g" "$u"; done; samba-tool group listmembers kafka-admins
```

```out
Added ou "OU=Confluent,DC=corp,DC=poc,DC=lab"
（Added ou / User added / Added group / Added members 共 13 行）
alice
```

| 物件 | 用途 |
|---|---|
| 群組 kafka-admins / kafka-operators / kafka-devs | 人員的權限綁這三個群組，不綁個人 |
| svc-mds-bind | MDS 用來向 AD 查人員與群組的唯讀帳號，沒有任何管理權限 |
| alice / bob / carol | 測試人員，各在一個群組 |

LDAPS 的憑證要由銀行 CA 簽。先在 ad01 產生 CSR（一定要帶 `extendedKeyUsage`，CA 的政策會檢查）：

```bash
mkdir -p /root/csr && cd /root/csr && openssl req -new -newkey rsa:2048 -nodes -keyout ad01.key -out ad01.csr -subj "/CN=ad01.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:ad01.poc.lab,DNS:ad01" -addext "keyUsage=digitalSignature,keyEncipherment" -addext "extendedKeyUsage=serverAuth" 2>/dev/null && echo csr-ok
```

```out
csr-ok
```

@role 銀行 CA 窗口 | Windows 終端 | 本機

```bash
cd ~/kafka-lab && mkdir -p ca/exchange && docker cp lab-ad01-1:/root/csr/ad01.csr "$(cygpath -m "$PWD/ca/exchange/ad01.csr")" && bash ca/sign.sh ca/exchange/ad01.csr ca/exchange/ad01-chain.crt && docker cp "$(cygpath -m "$PWD/ca/exchange/ad01-chain.crt")" lab-ad01-1:/var/lib/samba/private/tls/cert.pem && docker cp "$(cygpath -m "$PWD/ca/root.crt")" lab-ad01-1:/var/lib/samba/private/tls/ca.pem && docker exec lab-ad01-1 bash -c 'cp /root/csr/ad01.key /var/lib/samba/private/tls/key.pem && chmod 600 /var/lib/samba/private/tls/key.pem && chmod 644 /var/lib/samba/private/tls/cert.pem /var/lib/samba/private/tls/ca.pem && pkill -x samba; sleep 8; openssl s_client -connect localhost:636 -CAfile /var/lib/samba/private/tls/ca.pem </dev/null 2>/dev/null | grep "Verify return code"'
```

```out
signed ad01.csr -> ad01-chain.crt  (CN = ad01.poc.lab, O = PoC Bank, C = TW; EKU serverAuth)
Verify return code: 0 (ok)
```

最後把 svc-mds-bind 的密碼和測試人員的密碼交給小安（正式環境走密碼交付流程，lab 直接放到操作機）：

```bash
docker exec lab-ops02-1 install -d -o cpadmin -g cpadmin -m 0700 /home/cpadmin/secrets && for k in bind:ldap-bind users:ad-test-users; do docker exec lab-ad01-1 cat /root/secrets/${k%%:*}.pass | docker exec -i lab-ops02-1 bash -c "umask 077; cat > /home/cpadmin/secrets/${k#*:}.pass; chown cpadmin:cpadmin /home/cpadmin/secrets/${k#*:}.pass"; done; docker exec lab-ops02-1 ls -la /home/cpadmin/secrets
```

```out
-rw------- 1 cpadmin cpadmin 20 … ad-test-users.pass
-rw------- 1 cpadmin cpadmin 20 … ldap-bind.pass
```

## 3.5 NTP 與負載平衡

@role 銀行 套件庫管理員 | repo01 | root

正式環境有行內 NTP；lab 讓 repo01 兼任：

```bash
cat > /etc/yum.repos.d/bank-os.repo <<'EOF'
[bank-os]
name=Bank OS packages
baseurl=file:///var/www/repo/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
EOF
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9; dnf -q -y --disablerepo="*" --enablerepo=bank-os install chrony >/dev/null && printf 'local stratum 10\nallow 172.35.0.0/24\ndriftfile /var/lib/chrony/drift\n' > /etc/chrony.conf && systemctl enable --now chronyd >/dev/null 2>&1; sleep 2; systemctl is-active chronyd
```

```out
active
```

@role 銀行 網路團隊 | lb01 | root

負載平衡只做 L4 轉發，TLS 和 client 憑證在 REST Proxy 上處理。`rest.poc.lab` 指到 lb01：

```bash
mkdir -p /etc/nginx/stream.d && cat > /etc/nginx/stream.d/cp.conf <<'EOF'
upstream cp_rest {
    hash $remote_addr consistent;
    server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s;
    server rest02.poc.lab:8082 max_fails=2 fail_timeout=10s;
}
server { listen 8082; proxy_pass cp_rest; proxy_connect_timeout 3s; proxy_timeout 10m; }
upstream cp_c3 { server c3-01.poc.lab:9021 max_fails=2 fail_timeout=10s; }
server { listen 9021; proxy_pass cp_c3; proxy_connect_timeout 3s; proxy_timeout 1h; }
EOF
nginx -t 2>&1 | tail -1 && nginx -s reload
```

```out
nginx: configuration file /etc/nginx/nginx.conf test is successful
2026/10/21 23:55:07 [notice] 42#42: signal process started
```

C3 那段只是讓 Windows 瀏覽器透過 lab 的連接埠對應連到 C3；正式環境維運人員直連 C3。

# 4. 第四站：上架到內部套件庫

@role 小安 | ops02 | cpadmin

repo01 只有 httpd，沒有 `createrepo_c`，所以索引在操作機建好，連 RPM 一起推上去。先從銀行套件庫裝工具：

```bash
sudo dnf -q -y --refresh install createrepo_c && createrepo_c --version
```

```out
Version: 0.20.1 …
```

> 陷阱：dnf 快取的套件清單預設 48 小時才更新。套件庫剛上架的東西主機可能「找不到」，加 `--refresh` 強制重抓。

組目錄、建索引：

```bash
mkdir -p ~/repo/confluent ~/repo/gpg-keys ~/repo/tools && cp ~/landing/rpm/*.rpm ~/repo/confluent/ && cp ~/landing/gpg-keys/*.asc ~/repo/gpg-keys/ && cp ~/landing/tools/*.jar ~/repo/tools/ && cp ~/landing/SHA256SUMS ~/repo/ && createrepo_c ~/repo/confluent && test -f ~/repo/confluent/repodata/repomd.xml && echo repodata-ok
```

```out
（createrepo_c 的進度訊息）
repodata-ok
```

用 tar 串流透過 ssh 推給部署帳號，只會解在 `/var/www/repo` 底下，銀行的 `os/` 不受影響：

```bash
tar -C ~/repo -cf - . | ssh repodeploy@repo01.poc.lab 'tar -C /var/www/repo -xpf -' && ssh repodeploy@repo01.poc.lab 'ls /var/www/repo; ls /var/www/repo/confluent | wc -l'
```

```out
SHA256SUMS  confluent  gpg-keys  os  tools
12
```

從操作機用 HTTPS 讀讀看，預期 11 個套件：

```bash
dnf -q --repofrompath=cp-test,https://repo01.poc.lab/confluent/ --repo=cp-test --setopt=cp-test.gpgcheck=0 list available | grep -c confluent
```

```out
11
```

# 5. 第五站：JDK 21

@role 小安 | ops02 | cpadmin

![hostfiles]

銀行給的 tar 在 `~/landing/bank/`。決定：解壓到 `/opt/java/<版本目錄>`，再做一個固定的連結 `/opt/java/current` 指向它，所有設定一律寫 `/opt/java/current`，以後換版只改連結。`java`、`keytool` 用 alternatives 登記（RHEL 的標準做法），`/etc/profile.d/java.sh` 設 `JAVA_HOME`；服務自己的 systemd 設定還會再明確寫一次 `JAVA_HOME`，不受全域切換影響。

先看壓縮檔的頂層目錄名稱，並準備 `profile.d` 的檔案（`bank/` 裡有新舊幾版時，`sort -V | tail -1` 挑版本最新的）：

```bash
JDK_TAR=$(ls ~/landing/bank/OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1) && JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1) && echo "tar=$(basename $JDK_TAR) dir=$JDK_DIR" && install -d -m 0700 ~/jdk && cat > ~/jdk/java.sh <<'EOF'
# JDK 21 for Confluent Platform (/opt/java/current). Services set JAVA_HOME in their systemd drop-in.
[ -n "$JAVA_HOME" ] || export JAVA_HOME=/opt/java/current
EOF
printf 'JDK_TAR=%s
JDK_DIR=%s
' "$JDK_TAR" "$JDK_DIR" > ~/jdk/jdk.env && echo java.sh ok
```

```out
tar=OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz dir=jdk-21.0.x+y
java.sh ok
```

先在操作機本機裝一台（`jdk.env` 記住了上一步的兩個變數，之後離開再回來也接得上）：

```bash
source ~/jdk/jdk.env && sudo install -d -m 0755 /opt/java && sudo tar -xzf "$JDK_TAR" -C /opt/java && sudo chown -R root:root /opt/java && sudo ln -sfn "/opt/java/$JDK_DIR" /opt/java/current && sudo alternatives --install /usr/bin/java java /opt/java/current/bin/java 2100 && sudo alternatives --install /usr/bin/keytool keytool /opt/java/current/bin/keytool 2100 && sudo install -m 0644 ~/jdk/java.sh /etc/profile.d/java.sh && java -version 2>&1 | head -1
```

```out
openjdk version "21.0.x" … LTS
```

其他 10 台照做：

```bash
source ~/jdk/jdk.env && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q "$JDK_TAR" ~/jdk/java.sh $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo install -d -m 0755 /opt/java && sudo tar -xzf /tmp/$(basename $JDK_TAR) -C /opt/java && sudo chown -R root:root /opt/java && sudo ln -sfn /opt/java/$JDK_DIR /opt/java/current && sudo alternatives --install /usr/bin/java java /opt/java/current/bin/java 2100 && sudo alternatives --install /usr/bin/keytool keytool /opt/java/current/bin/keytool 2100 && sudo install -m 0644 /tmp/java.sh /etc/profile.d/java.sh && rm -f /tmp/$(basename $JDK_TAR) /tmp/java.sh && echo \"\$(hostname): done\""; done; for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'echo "$(hostname): $(java -version 2>&1 | head -1) JAVA_HOME=$JAVA_HOME"'; done
```

```out
kc01: done
…
ops02: openjdk version "21.0.x" … LTS JAVA_HOME=/opt/java/current
kc01: openjdk version "21.0.x" … LTS JAVA_HOME=/opt/java/current
（11 台都有版本與 JAVA_HOME）
```

最後那行同時驗證了 alternatives（`java` 在 PATH）和 `profile.d`（`ssh host 'cmd'` 讀得到）。

# 6. 第六站：安裝前檢查

@role 小安 | ops02 | cpadmin

動任何東西之前，先確認銀行準備的環境符合條件。每一項不符都是要先回頭找銀行的事。

**主機基本事實**（`/tmp` 不能 `noexec`、至少 2 GB）：

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'printf "%-7s %s cpu=%s mem=%sMB tmp_free=%sMB tmp_noexec=%s\n" "$(hostname)" "$(. /etc/os-release; echo $ID-$VERSION_ID)" "$(nproc)" "$(free -m | awk "/Mem:/{print \$2}")" "$(df -m /tmp | awk "NR==2{print \$4}")" "$(findmnt -no OPTIONS /tmp | grep -c noexec)"'; done
```

```out
ops02   rocky-9.8 cpu=8 mem=10953MB tmp_free=2048MB tmp_noexec=0
（11 行，tmp_noexec 都是 0）
```

**時鐘誤差**（TLS 與 MDS token 要求 2 秒內）：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do echo "$h skew=$(( $(ssh $h.poc.lab date +%s) - $(date +%s) ))s"; done
```

```out
kc01 skew=0s
（都是 0 或 1）
```

**DNS、套件庫、AD 連線**：

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'bad=""; for n in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01 repo01 ad01 lb01; do getent hosts $n.poc.lab >/dev/null || bad="$bad $n"; done; echo "$(hostname): ${bad:-all resolved} os=$(curl -s -o /dev/null -w %{http_code} https://repo01.poc.lab/os/repodata/repomd.xml) confluent=$(curl -s -o /dev/null -w %{http_code} https://repo01.poc.lab/confluent/repodata/repomd.xml)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'echo "$(hostname): $(openssl s_client -connect ad01.poc.lab:636 </dev/null 2>/dev/null | grep "Verify return code")"'; done
```

```out
ops02: all resolved os=200 confluent=200
（11 行）
kb01: Verify return code: 0 (ok)
（4 行）
```

`curl` 沒有指定 CA 就能驗過，是因為銀行根憑證已在每台的 OS 信任清單裡。`getent hosts` 用的是系統解析順序（先 `/etc/hosts` 再 DNS），和程式連線時的行為一致。

**主機是乾淨的**：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'echo "$(hostname): confluent_pkgs=$(rpm -qa "confluent-*" | wc -l) data_dir=$([ -e /var/lib/kafka ] && echo exists || echo none)"'; done
```

```out
kc01: confluent_pkgs=0 data_dir=none
（10 行）
```

# 7. 第七站：OS 調校

@role 小安 | ops02 | cpadmin

10 台叢集主機要做，操作機只做時間同步。lab 是容器，sysctl 有兩個網路參數設不進去、THP 的單元會自動跳過，正式 VM 不會有這個限制。

**核心參數**：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'case $(hostname) in kc*) extra="vm.max_map_count = 262144";; kb*) extra="vm.max_map_count = 262144
vm.swappiness = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 60
net.core.rmem_max = 2097152
net.core.wmem_max = 2097152
net.ipv4.tcp_rmem = 4096 65536 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152";; *) extra="";; esac; sudo install -d -m 0755 /etc/sysctl.d && printf "# Confluent Platform\nnet.core.somaxconn = 4096\nnet.ipv4.tcp_max_syn_backlog = 4096\n%s\n" "$extra" | sudo tee /etc/sysctl.d/90-confluent.conf >/dev/null; sudo sysctl -q --system 2>&1 | grep -c "sysctl:" | sed "s/^/$(hostname): errors=/"'; done
```

```out
kc01: errors=0
kb01: errors=2    （容器限制：net.core.rmem_max / wmem_max；VM 上是 0）
…
```

**程序限制、THP、時區、journald**：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'printf "@confluent soft nofile 128000\n@confluent hard nofile 128000\n@confluent soft nproc 65536\n@confluent hard nproc 65536\n" | sudo tee /etc/security/limits.d/90-confluent.conf >/dev/null && echo "$(hostname): limits ok"'; done
```

```out
kc01: limits ok
（10 行）
```

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo tee /etc/systemd/system/disable-thp.service >/dev/null <<EOF
[Unit]
Description=Disable transparent hugepages (Confluent Platform)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=confluent-server.service
ConditionVirtualization=!container

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=basic.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable disable-thp.service >/dev/null 2>&1; echo "$(hostname): thp unit enabled"'; done
```

```out
kc01: thp unit enabled
（7 行，只有 controller 與 broker）
```

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'sudo ln -sfn /usr/share/zoneinfo/Asia/Taipei /etc/localtime && sudo install -d /etc/systemd/journald.conf.d && printf "[Journal]\nSystemMaxUse=1G\n" | sudo tee /etc/systemd/journald.conf.d/90-confluent.conf >/dev/null && sudo systemctl restart systemd-journald && echo "$(hostname): $(date +%Z)"'; done
```

```out
ops02: CST
（11 行）
```

**時間同步**（指向行內 NTP，lab 是 repo01）：

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'sudo dnf -q -y install chrony >/dev/null && printf "server repo01.poc.lab iburst\ndriftfile /var/lib/chrony/drift\nmakestep 1.0 3\nrtcsync\n" | sudo tee /etc/chrony.conf >/dev/null && sudo systemctl enable --now chronyd >/dev/null 2>&1 && sudo systemctl restart chronyd && echo "$(hostname): chrony configured"'; done; sleep 10; for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'echo "$(hostname): $(chronyc sources 2>/dev/null | grep "^\^\*" | awk "{print \$2, \$7}")"'; done
```

```out
ops02: chrony configured
（11 行）
ops02: repo01.poc.lab +3217ns[+5448ns]
kc01: repo01 -65ns[+3833ns]
（11 行都有 repo01，代表已選定來源；偏移是奈秒等級）
```

**主機防火牆**（只開這台元件需要的埠）：

| 元件 | 連接埠 | 誰會連進來 |
|---|---|---|
| controller | 9093、7071 | 其他 controller 與 broker；監控 |
| broker | 9092、9094、9095、9096、8090、7071 | broker 之間；token 連線；應用程式；MDS；監控 |
| REST Proxy | 8082、7071 | 負載平衡；監控 |
| C3 | 9021、9090 | 維運人員的瀏覽器；C3 自己的 Prometheus |

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'case $(hostname) in kc*) p="9093 7071";; kb*) p="9092 9094 9095 9096 8090 7071";; rest*) p="8082 7071";; c3*) p="9021 9090";; esac; sudo dnf -q -y install firewalld >/dev/null && sudo systemctl enable --now firewalld >/dev/null 2>&1; for s in cockpit dhcpv6-client; do sudo firewall-cmd -q --permanent --remove-service=$s 2>/dev/null; done; for x in $p; do sudo firewall-cmd -q --permanent --add-port=$x/tcp; done; sudo firewall-cmd -q --reload && echo "$(hostname): $(sudo firewall-cmd --list-ports)"'; done
```

```out
kc01: 7071/tcp 9093/tcp
kb01: 7071/tcp 8090/tcp 9092/tcp 9094/tcp 9095/tcp 9096/tcp
rest01: 7071/tcp 8082/tcp
c3-01: 9021/tcp 9090/tcp
（10 行）
```

# 8. 第八站：安裝 Confluent 套件

@role 小安 | ops02 | cpadmin

每台放原廠公鑰、寫 repo 設定（11 台含操作機，gpgcheck 開著）：

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q ~/landing/gpg-keys/confluent.asc ~/landing/gpg-keys/confluent-c3.asc $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -m 0644 /tmp/confluent.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent && sudo install -m 0644 /tmp/confluent-c3.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3 && rm -f /tmp/confluent*.asc && sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3 && sudo tee /etc/yum.repos.d/confluent-internal.repo >/dev/null <<EOF
[confluent-internal]
name=Confluent Platform (internal repository)
baseurl=https://repo01.poc.lab/confluent/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-confluent
       file:///etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3
EOF
echo "$(hostname): $(dnf -q repolist | grep -c confluent-internal) repo, $(rpm -q gpg-pubkey --qf "%{SUMMARY}\n" | grep -ci confluent) keys"'; done
```

```out
ops02: 1 repo, 1 keys
（11 行；兩個 .asc 是同一把公鑰，所以 1 keys 是對的）
```

依元件安裝。`--setopt=install_weak_deps=False` 只裝真正需要的；C3 要多裝兩個 OS 前置套件，它們從銀行套件庫來：

| 主機 | 直接安裝 | dnf 自動帶入 |
|---|---|---|
| controller、broker | confluent-server、confluent-security | confluent-common、telemetry、metadata-service、server-rest、ce-kafka-http-server、kafka-rest、rest-utils |
| 操作機 | 同上 + confluent-cli | 同上 |
| REST Proxy | confluent-kafka-rest、confluent-security | confluent-common、rest-utils |
| C3 | confluent-control-center-next-gen + cyrus-sasl、openssl-devel | 無 |

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01 ops02; do case $h in kc*|kb*) p="confluent-server-8.3.2 confluent-security-8.3.2";; rest*) p="confluent-kafka-rest-8.3.2 confluent-security-8.3.2";; c3*) p="confluent-control-center-next-gen-2.6.1 cyrus-sasl openssl-devel";; ops*) p="confluent-server-8.3.2 confluent-security-8.3.2 confluent-cli-8.3.2";; esac; ssh $h.poc.lab "sudo dnf -q -y --setopt=install_weak_deps=False install $p >/dev/null && echo \"\$(hostname): \$(rpm -qa 'confluent-*' | wc -l) confluent packages\""; done
```

```out
kc01: 9 confluent packages
kb01: 9 confluent packages
rest01: 4 confluent packages
c3-01: 1 confluent packages
ops02: 10 confluent packages
```

每台約一兩分鐘。鎖版本（只鎖 Confluent；C3 的兩個 OS 套件跟著 OS 修補，不鎖）：

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'sudo dnf -q -y install python3-dnf-plugin-versionlock >/dev/null && for p in $(rpm -qa "confluent-*"); do sudo dnf -q versionlock add "$p" >/dev/null; done; echo "$(hostname): $(sudo dnf -q versionlock list | grep -c confluent) locked"'; done; for h in kb01 rest01 c3-01; do ssh $h.poc.lab 'echo "$(hostname): $(getent passwd cp-kafka cp-kafka-rest cp-control-center 2>/dev/null | cut -d: -f1 | tr "\n" " ") group=$(getent group confluent | cut -d: -f1) kafka_pkg=$(rpm -q confluent-server >/dev/null 2>&1 && echo yes || echo no)"'; done
```

```out
ops02: 10 locked
（11 行）
kb01: cp-kafka cp-kafka-rest  group=confluent kafka_pkg=yes
rest01: cp-kafka-rest  group=confluent kafka_pkg=no
c3-01: cp-control-center  group=confluent kafka_pkg=no
```

RPM 建好了服務帳號（`cp-kafka` 等）和群組 `confluent`；C3 主機沒有誤裝 Kafka。

# 9. 第九站：憑證

![certs]

平台內部所有連線都加密，而且用憑證識別身分。小安在操作機產生私鑰和 CSR（私鑰不離開行內），銀行 CA 簽完回來，小安逐張檢查後做成 Java 用的 keystore。

## 9.1 產生私鑰與 CSR

@role 小安 | ops02 | cpadmin

| 名稱 | 用途 | EKU | SAN |
|---|---|---|---|
| kafka-internal | controller、broker 之間的 mTLS | serverAuth, clientAuth | kc01–03、kb01–04 |
| cp-server | 所有對外服務：client listener、MDS、REST、C3、Prometheus | serverAuth, clientAuth | 全部主機、rest.poc.lab、c3.poc.lab、localhost |
| svc-rest、svc-c3、svc-ops | REST Proxy、C3、操作機向 MDS 換 token 的身分 | clientAuth | 無 |
| app-legacy-billing | 走 REST Proxy 的應用程式 | clientAuth | 無 |
| opmenu-breakglass | 維運選單（第 17 章）緊急模式用的身分 | clientAuth | 無 |

```bash
install -d -m 0700 ~/pki ~/pki/keys ~/pki/requests ~/pki/incoming ~/pki/certs && (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/pki/store.pass) && cat > ~/pki/requests.txt <<'EOF'
kafka-internal     serverAuth,clientAuth  kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04
cp-server          serverAuth,clientAuth  kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04,rest01.poc.lab,rest01,rest02.poc.lab,rest02,c3-01.poc.lab,c3-01,ops02.poc.lab,ops02,lb01.poc.lab,lb01,rest.poc.lab,c3.poc.lab,localhost
svc-rest           clientAuth             -
svc-c3             clientAuth             -
svc-ops            clientAuth             -
app-legacy-billing clientAuth             -
opmenu-breakglass  clientAuth             -
EOF
while read -r name eku san; do (umask 077; openssl genrsa -out ~/pki/keys/$name.key 2048 2>/dev/null); ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku"); [ "$san" != "-" ] && ext+=(-addext "subjectAltName=$(echo "$san" | tr ',' '\n' | sed 's/^/DNS:/' | paste -sd, -)"); openssl req -new -key ~/pki/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" "${ext[@]}" -out ~/pki/requests/$name.csr && echo "$name: csr ok"; done < ~/pki/requests.txt
```

```out
kafka-internal: csr ok
（7 行）
```

送出前自己看一次 CN、SAN、EKU：

```bash
for f in ~/pki/requests/*.csr; do echo "== $(basename $f)"; openssl req -in $f -noout -subject -text | grep -E "^subject=|Alternative|Extended Key" -A1 | grep -v "^--" | sed 's/^ */  /'; done
```

## 9.2 銀行 CA 簽發

@role 銀行 CA 窗口 | Windows 終端 | 本機

正式環境是把 CSR 交給 CA 窗口，收回「憑證 + 中繼 CA」。lab 用 0.5.5 建好的 `sign.sh`，7 個 CSR 一次簽完、放回操作機的 `incoming/`（簽好的放在 `signed/` 子目錄，免得和第 3 站簽給 ad01 的那張混在一起）：

```bash
cd ~/kafka-lab && mkdir -p ca/exchange/signed && docker cp lab-ops02-1:/home/cpadmin/pki/requests "$(cygpath -m "$PWD/ca/exchange/")" && for f in ca/exchange/requests/*.csr; do n=$(basename $f .csr); bash ca/sign.sh "$f" "ca/exchange/signed/$n.crt"; done && for f in ca/exchange/signed/*.crt; do docker cp "$(cygpath -m "$f")" lab-ops02-1:/home/cpadmin/pki/incoming/; done && docker exec lab-ops02-1 bash -c 'chown cpadmin:cpadmin /home/cpadmin/pki/incoming/*; ls /home/cpadmin/pki/incoming | wc -l'
```

```out
signed app-legacy-billing.csr -> app-legacy-billing.crt  (CN = app-legacy-billing, O = PoC Bank, C = TW; EKU clientAuth)
（7 行）
7
```

## 9.3 匯入前檢查、做成 keystore

@role 小安 | ops02 | cpadmin

拆開回覆（第一張是 leaf，其餘是中繼）：

```bash
cd ~/pki && for n in $(awk '{print $1}' requests.txt); do awk -v n=$n 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("incoming/" n ".part" c)}' incoming/$n.crt; mv incoming/$n.part1 incoming/$n.leaf.pem; cat incoming/$n.part[2-9] > incoming/$n.issuers.pem 2>/dev/null; rm -f incoming/$n.part*; echo "$n: $(grep -c 'BEGIN CERT' incoming/$n.issuers.pem) issuer(s)"; done
```

```out
kafka-internal: 1 issuer(s)
（7 行）
```

五項檢查：私鑰相符、CN、SAN、EKU、效期，再驗整條鏈到銀行根憑證：

```bash
cd ~/pki && while read -r name eku san; do leaf=incoming/$name.leaf.pem; k1=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16); k2=$(openssl pkey -in keys/$name.key -pubout 2>/dev/null | sha256sum | cut -c1-16); cn=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); have_san=$(openssl x509 -in $leaf -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,); want_san=$([ "$san" = "-" ] && echo "" || echo "$san" | tr ',' '\n' | sort | paste -sd,); have_eku=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' '); days=$(( ($(date -d "$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )); chain=$(openssl verify -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem -untrusted incoming/$name.issuers.pem $leaf 2>&1 | grep -c ": OK"); printf '%-19s key=%s cn=%s san=%s eku=%s days=%s chain=%s\n' $name $([ $k1 = $k2 ] && echo ok || echo MISMATCH) $([ "$cn" = "$name" ] && echo ok || echo "$cn") $([ "$have_san" = "$want_san" ] && echo ok || echo DIFF) "$have_eku" $days $([ $chain = 1 ] && echo ok || echo FAIL); done < requests.txt
```

```out
kafka-internal      key=ok cn=ok san=ok eku=TLSWebServerAuthentication,TLSWebClientAuthentication days=364 chain=ok
（7 行，全部 ok）
```

> 任何一項不是 ok 就退回銀行重簽，不往下做。

整理成正式檔案，做 PKCS12 keystore、truststore（只放銀行根憑證）、MDS token 金鑰對：

```bash
cd ~/pki && for n in $(awk '{print $1}' requests.txt); do cat incoming/$n.leaf.pem incoming/$n.issuers.pem > certs/$n.crt; openssl pkcs12 -export -name $n -inkey keys/$n.key -in certs/$n.crt -out certs/$n.p12 -passout file:store.pass && chmod 0600 certs/$n.p12; done && cp /etc/pki/ca-trust/source/anchors/bank-root.pem certs/bank-root.pem && keytool -importcert -noprompt -alias bank-root -file certs/bank-root.pem -keystore certs/truststore.p12 -storetype PKCS12 -storepass:file store.pass && (umask 077; openssl genrsa -out keys/mds-token.key 2048 2>/dev/null) && openssl rsa -in keys/mds-token.key -pubout -out certs/mds-token-public.pem 2>/dev/null && ls certs | wc -l
```

```out
Certificate was added to keystore
17
```

| 檔案 | 用途 |
|---|---|
| certs/*.crt | leaf + 中繼，給需要 PEM 的程式（curl、Prometheus） |
| certs/*.p12 | 私鑰 + 鏈，給 Java 程式當 keystore |
| certs/truststore.p12 | 只有銀行根憑證，所有元件驗對方用 |
| keys/mds-token.key、certs/mds-token-public.pem | MDS 簽 token 用的金鑰對，不經銀行 |

# 10. 第十站：controller 與 broker

![startup]

## 10.1 派送憑證

@role 小安 | ops02 | cpadmin

controller 4 個檔，broker 多一個 `cp-server.p12`（對外 listener 用）。目錄 root:confluent 0750，檔案 0640：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do case $h in kb*) extra=~/pki/certs/cp-server.p12;; *) extra="";; esac; scp -q ~/pki/certs/truststore.p12 ~/pki/certs/kafka-internal.p12 ~/pki/keys/mds-token.key ~/pki/certs/mds-token-public.pem $extra $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -d -o root -g root -m 0755 /etc/confluent && sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka && for f in /tmp/truststore.p12 /tmp/kafka-internal.p12 /tmp/mds-token-public.pem /tmp/cp-server.p12; do [ -f $f ] && sudo install -o root -g confluent -m 0640 $f /etc/confluent/ssl/; done; sudo install -o root -g confluent -m 0640 /tmp/mds-token.key /etc/confluent/ssl/mds-token-keypair.pem; rm -f /tmp/*.p12 /tmp/mds-token*; printf "%-6s %s files: %s\n" "$(hostname)" "$(sudo ls /etc/confluent/ssl | wc -l)" "$(sudo ls /etc/confluent/ssl | paste -sd" ")"'; done
```

```out
kc01   4 files: kafka-internal.p12 mds-token-keypair.pem mds-token-public.pem truststore.p12
kb01   5 files: cp-server.p12 kafka-internal.p12 mds-token-keypair.pem mds-token-public.pem truststore.p12
（7 行）
```

## 10.2 設定檔

@role 小安 | ops02 | cpadmin

設定檔用範本產生：範本裡寫 `${變數}`，由 `envsubst` 換成每台的值；密碼從檔案讀進變數，不出現在畫面上。先裝工具：

```bash
sudo dnf -q -y install gettext >/dev/null && echo envsubst-ok
```

共用區塊（TLS 預設、RBAC、LDAP、送指標到 C3）。**整段貼到 EOF**：

```bash
install -d -m 0700 ~/conf && cat > ~/conf/common.tpl <<'EOF'
############################# TLS defaults: shared internal certificate (CONTROLLER / INTERNAL) #############################
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
ssl.keystore.password=${STORE_PASSWORD}
ssl.key.password=${STORE_PASSWORD}
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ssl.truststore.password=${STORE_PASSWORD}
ssl.client.auth=required
ssl.endpoint.identification.algorithm=https
ssl.enabled.protocols=TLSv1.3,TLSv1.2
ssl.principal.mapping.rules=RULE:.*CN=([a-zA-Z0-9._-]+).*$/$1/,DEFAULT

############################# Authorization (RBAC via MDS + KRaft ACLs) #############################
authorizer.class.name=io.confluent.kafka.security.authorizer.ConfluentServerAuthorizer
confluent.authorizer.access.rule.providers=KRAFT_ACL,CONFLUENT
super.users=User:kafka-internal;User:kafka-admin;User:svc-ops
allow.everyone.if.no.acl.found=false
confluent.metadata.server.token.key.path=/etc/confluent/ssl/mds-token-keypair.pem
confluent.metadata.topic.replication.factor=3

############################# License #############################
# confluent.license not set: evaluation mode
confluent.license.topic.replication.factor=3

############################# Self-Balancing Clusters #############################
confluent.balancer.enable=true
confluent.balancer.topic.replication.factor=3

############################# Identity provider (Active Directory over LDAPS) #############################
ldap.java.naming.factory.initial=com.sun.jndi.ldap.LdapCtxFactory
ldap.com.sun.jndi.ldap.connect.timeout=3000
ldap.com.sun.jndi.ldap.read.timeout=5000
ldap.java.naming.provider.url=ldaps://ad01.poc.lab:636
ldap.refresh.interval.ms=60000
ldap.retry.timeout.ms=86400000
ldap.java.naming.security.protocol=SSL
ldap.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ldap.ssl.truststore.password=${STORE_PASSWORD}
ldap.ssl.truststore.type=PKCS12
ldap.java.naming.security.authentication=simple
ldap.java.naming.security.principal=CN=svc-mds-bind,OU=Service,OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.java.naming.security.credentials=${LDAP_BIND_PASSWORD}
ldap.search.mode=GROUPS
ldap.user.search.base=OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.user.search.scope=2
ldap.user.object.class=user
ldap.user.name.attribute=sAMAccountName
ldap.group.search.base=OU=Groups,OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.group.search.scope=2
ldap.group.object.class=group
ldap.group.name.attribute=cn
ldap.group.member.attribute=member
ldap.group.member.attribute.pattern=CN=([^,]+),.*

############################# Metrics to Control Center (Prometheus OTLP receiver, mTLS) #############################
metric.reporters=io.confluent.telemetry.reporter.TelemetryReporter
confluent.telemetry.exporter._c3.type=http
confluent.telemetry.exporter._c3.enabled=true
confluent.telemetry.exporter._c3.metrics.include=io.confluent.kafka.server.request.(?!.*delta).*|io.confluent.kafka.server.server.broker.state|io.confluent.kafka.server.replica.manager.leader.count|io.confluent.kafka.server.request.queue.size|io.confluent.kafka.server.broker.topic.failed.produce.requests.rate.1.min|io.confluent.kafka.server.tier.archiver.total.lag|io.confluent.kafka.server.request.total.time.ms.p99|io.confluent.kafka.server.broker.topic.failed.fetch.requests.rate.1.min|io.confluent.kafka.server.broker.topic.total.fetch.requests.rate.1.min|io.confluent.kafka.server.partition.caught.up.replicas.count|io.confluent.kafka.server.partition.observer.replicas.count|io.confluent.kafka.server.tier.tasks.num.partitions.in.error|io.confluent.kafka.server.broker.topic.bytes.out.rate.1.min|io.confluent.kafka.server.request.total.time.ms.p95|io.confluent.kafka.server.controller.active.controller.count|io.confluent.kafka.server.session.expire.listener.zookeeper.disconnects.total|io.confluent.kafka.server.request.total.time.ms.p999|io.confluent.kafka.server.controller.active.broker.count|io.confluent.kafka.server.request.handler.pool.request.handler.avg.idle.percent.rate.1.min|io.confluent.kafka.server.session.expire.listener.zookeeper.disconnects.rate.1.min|io.confluent.kafka.server.controller.unclean.leader.elections.rate.1.min|io.confluent.kafka.server.replica.manager.partition.count|io.confluent.kafka.server.controller.unclean.leader.elections.total|io.confluent.kafka.server.partition.replicas.count|io.confluent.kafka.server.broker.topic.total.produce.requests.rate.1.min|io.confluent.kafka.server.controller.offline.partitions.count|io.confluent.kafka.server.socket.server.network.processor.avg.idle.percent|io.confluent.kafka.server.partition.under.replicated|io.confluent.kafka.server.log.log.start.offset|io.confluent.kafka.server.log.tier.size|io.confluent.kafka.server.log.size|io.confluent.kafka.server.tier.fetcher.bytes.fetched.total|io.confluent.kafka.server.request.total.time.ms.p50|io.confluent.kafka.server.tenant.consumer.lag.offsets|io.confluent.kafka.server.session.expire.listener.zookeeper.expires.rate.1.min|io.confluent.kafka.server.log.log.end.offset|io.confluent.kafka.server.broker.topic.bytes.in.rate.1.min|io.confluent.kafka.server.partition.under.min.isr|io.confluent.kafka.server.partition.in.sync.replicas.count|io.confluent.telemetry.http.exporter.batches.dropped|io.confluent.telemetry.http.exporter.items.total|io.confluent.telemetry.http.exporter.items.succeeded|io.confluent.telemetry.http.exporter.send.time.total.millis|io.confluent.kafka.server.controller.leader.election.rate.(?!.*delta).*|io.confluent.telemetry.http.exporter.batches.failed
confluent.telemetry.exporter._c3.client.base.url=https://c3-01.poc.lab:9090/api/v1/otlp
confluent.telemetry.exporter._c3.client.compression=gzip
confluent.telemetry.exporter._c3.api.key=dummy
confluent.telemetry.exporter._c3.api.secret=dummy
confluent.telemetry.exporter._c3.https.ssl.keystore.type=PKCS12
confluent.telemetry.exporter._c3.https.ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
confluent.telemetry.exporter._c3.https.ssl.keystore.password=${STORE_PASSWORD}
confluent.telemetry.exporter._c3.https.ssl.key.password=${STORE_PASSWORD}
confluent.telemetry.exporter._c3.https.ssl.truststore.type=PKCS12
confluent.telemetry.exporter._c3.https.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.telemetry.exporter._c3.https.ssl.truststore.password=${STORE_PASSWORD}
confluent.telemetry.exporter._c3.https.ssl.protocol=TLSv1.3
confluent.telemetry.exporter._c3.buffer.pending.batches.max=80
confluent.telemetry.exporter._c3.buffer.batch.items.max=4000
confluent.telemetry.exporter._c3.buffer.inflight.submissions.max=10
confluent.telemetry.metrics.collector.interval.ms=60000
confluent.telemetry.remoteconfig._confluent.enabled=false
confluent.telemetry.enabled=false
confluent.consumer.lag.emitter.enabled=true
EOF
echo common.tpl ok
```

controller 範本：

```bash
cat > ~/conf/controller.tpl <<'EOF'
# KRaft controller ${HOST_FQDN}
process.roles=controller
node.id=${NODE_ID}
controller.quorum.bootstrap.servers=kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093
controller.listener.names=CONTROLLER
listeners=CONTROLLER://${HOST_FQDN}:9093
advertised.listeners=CONTROLLER://${HOST_FQDN}:9093
listener.security.protocol.map=CONTROLLER:SSL,INTERNAL:SSL
inter.broker.listener.name=INTERNAL
log.dirs=/var/lib/kafka/data

############################# MDS on KRaft controllers #############################
confluent.metadata.server.kraft.controller.enabled=true
confluent.metadata.bootstrap.servers=kb01.poc.lab:9092,kb02.poc.lab:9092,kb03.poc.lab:9092,kb04.poc.lab:9092
confluent.metadata.security.protocol=SSL
confluent.metadata.ssl.keystore.type=PKCS12
confluent.metadata.ssl.keystore.location=/etc/confluent/ssl/kafka-internal.p12
confluent.metadata.ssl.keystore.password=${STORE_PASSWORD}
confluent.metadata.ssl.key.password=${STORE_PASSWORD}
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=${STORE_PASSWORD}
EOF
echo controller.tpl ok
```

broker 範本（四個 listener：內部 mTLS、TOKEN、CLIENT 給應用程式、LDAP 給人員；MDS 在 8090）：

```bash
cat > ~/conf/broker.tpl <<'EOF'
# broker ${HOST_FQDN}
process.roles=broker
node.id=${NODE_ID}
broker.rack=${RACK}
controller.quorum.bootstrap.servers=kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093
controller.listener.names=CONTROLLER
log.dirs=/var/lib/kafka/data

############################# Listeners #############################
listeners=INTERNAL://${HOST_FQDN}:9092,TOKEN://${HOST_FQDN}:9094,CLIENT://${HOST_FQDN}:9095,LDAP://${HOST_FQDN}:9096
advertised.listeners=INTERNAL://${HOST_FQDN}:9092,TOKEN://${HOST_FQDN}:9094,CLIENT://${HOST_FQDN}:9095,LDAP://${HOST_FQDN}:9096
listener.security.protocol.map=CONTROLLER:SSL,INTERNAL:SSL,TOKEN:SASL_SSL,CLIENT:SASL_SSL,LDAP:SASL_SSL
inter.broker.listener.name=INTERNAL
principal.builder.class=io.confluent.kafka.security.authenticator.OAuthKafkaPrincipalBuilder

############################# External listeners: shared server certificate #############################
listener.name.token.ssl.keystore.type=PKCS12
listener.name.token.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
listener.name.token.ssl.keystore.password=${STORE_PASSWORD}
listener.name.token.ssl.key.password=${STORE_PASSWORD}
listener.name.token.ssl.client.auth=none
listener.name.client.ssl.keystore.type=PKCS12
listener.name.client.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
listener.name.client.ssl.keystore.password=${STORE_PASSWORD}
listener.name.client.ssl.key.password=${STORE_PASSWORD}
listener.name.client.ssl.client.auth=none
listener.name.ldap.ssl.keystore.type=PKCS12
listener.name.ldap.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
listener.name.ldap.ssl.keystore.password=${STORE_PASSWORD}
listener.name.ldap.ssl.key.password=${STORE_PASSWORD}
listener.name.ldap.ssl.client.auth=none

# TOKEN: MDS-issued OAuth bearer tokens
listener.name.token.sasl.enabled.mechanisms=OAUTHBEARER
listener.name.token.oauthbearer.sasl.server.callback.handler.class=io.confluent.kafka.server.plugins.auth.token.TokenBearerValidatorCallbackHandler
listener.name.token.oauthbearer.sasl.login.callback.handler.class=io.confluent.kafka.server.plugins.auth.token.TokenBearerServerLoginCallbackHandler
listener.name.token.oauthbearer.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required publicKeyPath="/etc/confluent/ssl/mds-token-public.pem";
listener.name.token.principal.builder.class=io.confluent.kafka.security.authenticator.OAuthKafkaPrincipalBuilder

# CLIENT: SCRAM credentials stored in the KRaft metadata log
listener.name.client.sasl.enabled.mechanisms=SCRAM-SHA-512
listener.name.client.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required;

# LDAP: username/password checked against Active Directory
listener.name.ldap.sasl.enabled.mechanisms=PLAIN
listener.name.ldap.plain.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required;
listener.name.ldap.plain.sasl.server.callback.handler.class=io.confluent.security.auth.provider.ldap.LdapAuthenticateCallbackHandler

############################# Metadata Service (MDS) #############################
confluent.metadata.server.listeners=https://0.0.0.0:8090
confluent.metadata.server.advertised.listeners=https://${HOST_FQDN}:8090
confluent.metadata.server.ssl.keystore.type=PKCS12
confluent.metadata.server.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.metadata.server.ssl.keystore.password=${STORE_PASSWORD}
confluent.metadata.server.ssl.key.password=${STORE_PASSWORD}
confluent.metadata.server.ssl.truststore.type=PKCS12
confluent.metadata.server.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.server.ssl.truststore.password=${STORE_PASSWORD}
confluent.metadata.server.ssl.client.authentication=REQUESTED
confluent.metadata.server.auth.ssl.principal.mapping.rules=RULE:.*CN=([a-zA-Z0-9._-]+).*$/$1/,DEFAULT
confluent.metadata.server.authentication.method=BEARER
confluent.metadata.server.user.store=LDAP
confluent.metadata.server.token.signature.algorithm=RS256
confluent.metadata.server.token.max.lifetime.ms=3600000
confluent.metadata.server.impersonation.super.users=User:svc-rest
confluent.metadata.server.impersonation.protected.users=User:kafka-internal;User:kafka-admin;User:svc-ops;User:svc-mds-bind;User:svc-rest;User:svc-c3;User:opmenu-breakglass

############################# Cluster defaults #############################
default.replication.factor=3
min.insync.replicas=2
num.partitions=3
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
unclean.leader.election.enable=false
auto.create.topics.enable=false
confluent.cluster.link.enable=false
EOF
echo broker.tpl ok
```

產生每台的 `server.properties` 並派送（root:confluent 0640）：

```bash
cd ~/conf && export STORE_PASSWORD=$(cat ~/pki/store.pass) LDAP_BIND_PASSWORD=$(cat ~/secrets/ldap-bind.pass) && V='${HOST_FQDN} ${NODE_ID} ${RACK} ${STORE_PASSWORD} ${LDAP_BIND_PASSWORD}' && for h in kc01:1:- kc02:2:- kc03:3:- kb01:101:rack-a kb02:102:rack-a kb03:103:rack-b kb04:104:rack-b; do IFS=: read -r n id rack <<<"$h"; export HOST_FQDN=$n.poc.lab NODE_ID=$id RACK=$rack; case $n in kc*) tpl=controller.tpl;; *) tpl=broker.tpl;; esac; (umask 077; { envsubst "$V" < $tpl; echo; envsubst "$V" < common.tpl; } > $n.server.properties); scp -q $n.server.properties $n.poc.lab:/tmp/server.properties && ssh $n.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/server.properties /etc/confluent/kafka/server.properties && rm -f /tmp/server.properties && echo "$(hostname): $(sudo grep -c . /etc/confluent/kafka/server.properties) lines, unresolved=$(sudo grep -c "\${" /etc/confluent/kafka/server.properties)"'; done; unset STORE_PASSWORD LDAP_BIND_PASSWORD
```

```out
kc01: 95 lines, unresolved=0
kb01: 144 lines, unresolved=0
（7 行，行數略有出入沒關係，unresolved 都要是 0）
```

## 10.3 systemd 與目錄

@role 小安 | ops02 | cpadmin

RPM 的 `confluent-server.service` 預設讀 `/etc/kafka/server.properties`，用 drop-in 覆寫成我們的設定、`JAVA_HOME`、heap（lab 規格：controller 384m、broker 512m）。**最後一定要看到 exec 指向我們的檔案**：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do case $h in kc*) heap=384m;; *) heap=512m;; esac; ssh $h.poc.lab "sudo install -d -m 0755 /etc/systemd/system/confluent-server.service.d && sudo tee /etc/systemd/system/confluent-server.service.d/10-override.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/kafka-server-start /etc/confluent/kafka/server.properties
Environment=\"JAVA_HOME=/opt/java/current\"
Environment=\"KAFKA_HEAP_OPTS=-Xms$heap -Xmx$heap\"
Environment=\"KAFKA_LOG4J_OPTS=-Dlog4j2.configurationFile=/etc/kafka/log4j2.yaml\"
Environment=\"LOG_DIR=/var/log/kafka\"
LimitNOFILE=128000
TimeoutStopSec=180
Restart=on-failure
RestartSec=10
EOF
sudo systemctl daemon-reload && sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka/data && sudo install -d -o cp-kafka -g confluent -m 0755 /var/log/kafka && printf '%-5s heap=%s exec=%s data=%s\n' \$(hostname) $heap \"\$(systemctl show confluent-server -p ExecStart --value | grep -o '/etc/[^ ]*properties')\" \"\$(sudo stat -c %U:%G:%a /var/lib/kafka/data)\""; done
```

```out
kc01  heap=384m exec=/etc/confluent/kafka/server.properties data=cp-kafka:confluent:750
（7 行）
```

> 陷阱：如果 exec 顯示的是 `/etc/kafka/server.properties`，代表 drop-in 沒生效。此時啟動會用 RPM 的預設設定起來（沒有加密、沒有認證）。小安在 REST Proxy 和 C3 都踩過這個坑。

## 10.4 格式化、啟動

@role 小安 | ops02 | cpadmin

cluster id 一個、每台 controller 一個 directory id；controller 用動態 quorum 格式化，並寫入緊急備用的 SCRAM 管理帳號 `kafka-admin`；broker 格式化成觀察者。

```bash
export JAVA_HOME=/opt/java/current && (umask 077; { echo "CLUSTER_ID=$(kafka-storage random-uuid)"; for c in kc01 kc02 kc03; do echo "DIR_ID_$c=$(kafka-storage random-uuid)"; done; } > ~/conf/kraft.env; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/kafka-admin.pass) && cat ~/conf/kraft.env
```

```out
CLUSTER_ID=xxxxxxxxxxxxxxxxxxxxxx
DIR_ID_kc01=…
DIR_ID_kc02=…
DIR_ID_kc03=…
```

```bash
source ~/conf/kraft.env && IC="1@kc01.poc.lab:9093:$DIR_ID_kc01,2@kc02.poc.lab:9093:$DIR_ID_kc02,3@kc03.poc.lab:9093:$DIR_ID_kc03" && for h in kc01 kc02 kc03; do scp -q ~/secrets/kafka-admin.pass $h.poc.lab:/tmp/ka.pass && ssh $h.poc.lab "P=\$(cat /tmp/ka.pass); rm -f /tmp/ka.pass; sudo -u cp-kafka env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml kafka-storage format --cluster-id $CLUSTER_ID --config /etc/confluent/kafka/server.properties --initial-controllers $IC --add-scram \"SCRAM-SHA-512=[name=kafka-admin,password=\$P]\" 2>&1 | grep -v -i scram; printf '%-5s cluster.id=%s\n' \$(hostname) \"\$(sudo sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)\""; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab "sudo -u cp-kafka env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml kafka-storage format --cluster-id $CLUSTER_ID --config /etc/confluent/kafka/server.properties --no-initial-controllers 2>&1 | tail -1; printf '%-5s cluster.id=%s node.id=%s\n' \$(hostname) \"\$(sudo sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)\" \"\$(sudo sed -n 's/^node.id=//p' /var/lib/kafka/data/meta.properties)\""; done
```

```out
Formatting dynamic metadata voter directory /var/lib/kafka/data with confluent.metadata.version 4.3-IV0B.
kc01  cluster.id=xxxxxxxxxxxxxxxxxxxxxx
…
Formatting metadata directory /var/lib/kafka/data with confluent.metadata.version 4.3-IV0B.
kb01  cluster.id=xxxxxxxxxxxxxxxxxxxxxx node.id=101
（7 台 cluster.id 相同）
```

格式化只做一次，重跑會被 `already formatted` 擋下，這是保護。

操作機連 controller 的 client 設定（用內部憑證），然後啟動 controller、看 quorum：

```bash
(umask 077; cat > ~/conf/client-internal.properties <<EOF
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=/home/cpadmin/pki/certs/kafka-internal.p12
ssl.keystore.password=$(cat ~/pki/store.pass)
ssl.key.password=$(cat ~/pki/store.pass)
ssl.truststore.type=PKCS12
ssl.truststore.location=/home/cpadmin/pki/certs/truststore.p12
ssl.truststore.password=$(cat ~/pki/store.pass)
ssl.endpoint.identification.algorithm=https
EOF
) && for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl enable --now confluent-server >/dev/null 2>&1; sleep 1; printf "%-5s %s\n" "$(hostname)" "$(systemctl is-active confluent-server)"'; done; sleep 20; kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status | grep -E "LeaderId|CurrentVoters"
```

```out
kc01  active
kc02  active
kc03  active
LeaderId:               1
CurrentVoters:          [{"id": 1, …}, {"id": 2, …}, {"id": 3, …}]
```

啟動 broker，確認註冊與 MDS：

```bash
for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl enable --now confluent-server >/dev/null 2>&1; sleep 1; printf "%-5s %s\n" "$(hostname)" "$(systemctl is-active confluent-server)"'; done; sleep 45; kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status | grep CurrentObservers | cut -c1-100; for h in kb01 kb02 kb03 kb04; do echo "$h MDS=$(curl -s -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done
```

```out
kb01  active
…
CurrentObservers:       [{"id": 103, …}, {"id": 102, …}, …]
kb01 MDS=200
kb02 MDS=200
kb03 MDS=200
kb04 MDS=200
```

有任何一台不是 `active`，看它的日誌：`ssh <host> 'sudo journalctl -u confluent-server -n 50 --no-pager'`。

# 11. 第十一站：帳號與權限

![identity]

@role 小安 | ops02 | cpadmin

操作機的管理 client：用 `svc-ops` 憑證向 MDS 換 token，走 TOKEN listener。`svc-ops` 是 super user。

```bash
(umask 077; cat > ~/conf/client-admin.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenCertificateLoginCallbackHandler
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required metadataServerUrls="https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090";
ssl.keystore.type=PKCS12
ssl.keystore.location=/home/cpadmin/pki/certs/svc-ops.p12
ssl.keystore.password=$(cat ~/pki/store.pass)
ssl.key.password=$(cat ~/pki/store.pass)
ssl.truststore.type=PKCS12
ssl.truststore.location=/home/cpadmin/pki/certs/truststore.p12
ssl.truststore.password=$(cat ~/pki/store.pass)
ssl.endpoint.identification.algorithm=https
EOF
) && export JAVA_HOME=/opt/java/current BS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094,kb04.poc.lab:9094 && kafka-topics --bootstrap-server $BS --command-config ~/conf/client-admin.properties --list
```

```out
__consumer_offsets
__internal_confluent_only_broker_info
_confluent-command
_confluent-metadata-auth
confluent-audit-log-events
```

列得出來就代表「憑證 → MDS token → TOKEN listener」這條路通了。

應用程式的 SCRAM 帳號（直連 Kafka 的 app）：

```bash
for a in app-orders app-payments; do (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/$a.pass); P=$(cat ~/secrets/$a.pass); kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties --alter --entity-type users --entity-name $a --add-config "SCRAM-SHA-512=[iterations=8192,password=$P]" >/dev/null && echo "$a: scram created"; done; unset P; for a in app-orders app-payments kafka-admin; do echo "$a: $(kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties --describe --entity-type users --entity-name $a | grep -o 'SCRAM-SHA-512=[^,]*' | head -1)"; done
```

```out
app-orders: scram created
app-payments: scram created
app-orders: SCRAM-SHA-512=iterations=8192
app-payments: SCRAM-SHA-512=iterations=8192
kafka-admin: SCRAM-SHA-512=iterations=4096
```

應用程式這一端的連線設定（扮演 app-orders 直連 CLIENT 9095；第 15、19、20 章驗證時都會用到）。密碼從 0600 檔讀，設定檔一樣是 0600：

```bash
(umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-orders" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=/home/cpadmin/pki/certs/truststore.p12\nssl.truststore.password=%s\n' "$(cat ~/secrets/app-orders.pass)" "$(cat ~/pki/store.pass)" > ~/conf/app-orders.properties) && echo "$(grep -c . ~/conf/app-orders.properties) lines, $(stat -c %a ~/conf/app-orders.properties)"
```

```out
6 lines, 600
```

RBAC：人員綁 AD 群組，服務與 app 各綁最小權限：

```bash
confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key && source ~/conf/kraft.env && cat > ~/conf/rbac.txt <<'EOF'
Group:kafka-admins      SystemAdmin    -                                            -
Group:kafka-operators   Operator       -                                            -
Group:kafka-devs        DeveloperRead  Topic:orders.                                PREFIXED
Group:kafka-devs        DeveloperRead  Group:dev-                                   PREFIXED
User:svc-c3             SystemAdmin    -                                            -
User:svc-rest           DeveloperRead  Topic:_confluent-license                     LITERAL
User:svc-rest           DeveloperRead  Topic:_confluent-command                     LITERAL
User:svc-rest           DeveloperRead  Topic:__internal_confluent_only_broker_info  LITERAL
User:app-orders         DeveloperWrite Topic:orders.                                PREFIXED
User:app-orders         DeveloperRead  Topic:orders.                                PREFIXED
User:app-orders         DeveloperManage Topic:orders.                               PREFIXED
User:app-orders         DeveloperRead  Group:orders-                                PREFIXED
User:app-payments       DeveloperWrite Topic:payments.                              PREFIXED
User:app-payments       DeveloperRead  Topic:payments.                              PREFIXED
User:app-legacy-billing DeveloperWrite Topic:billing.                               PREFIXED
User:app-legacy-billing DeveloperRead  Topic:billing.                               PREFIXED
User:app-legacy-billing DeveloperRead  Group:billing-                               PREFIXED
EOF
while read -r p role res pat; do args=(--principal "$p" --role "$role" --kafka-cluster "$CLUSTER_ID"); [ "$res" != "-" ] && args+=(--resource "$res"); [ "$pat" = "PREFIXED" ] && args+=(--prefix); confluent iam rbac role-binding create "${args[@]}" >/dev/null && echo "ok  $p $role ${res#-} ${pat#-}"; done < ~/conf/rbac.txt
```

```out
ok  Group:kafka-admins SystemAdmin
（17 行 ok）
```

配額與範例 topic：

```bash
kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties --alter --entity-type users --entity-name app-orders --add-config 'producer_byte_rate=5242880,consumer_byte_rate=10485760,request_percentage=50' && kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties --alter --entity-type users --entity-name app-payments --add-config 'producer_byte_rate=5242880,consumer_byte_rate=10485760,request_percentage=50' && kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties --alter --entity-type users --entity-name app-legacy-billing --add-config 'producer_byte_rate=1048576,consumer_byte_rate=2097152,request_percentage=25' && for t in orders.events:6 payments.events:6 billing.events:3; do kafka-topics --bootstrap-server $BS --command-config ~/conf/client-admin.properties --create --if-not-exists --topic ${t%%:*} --partitions ${t#*:} --replication-factor 3 --config min.insync.replicas=2 >/dev/null && echo "topic ${t%%:*}"; done
```

```out
Completed updating config for user app-orders.
（3 行）
topic orders.events
topic payments.events
topic billing.events
```

驗證權限真的靠 AD 群組：alice（kafka-admins）和 carol（kafka-devs）用 AD 帳密登入 MDS，看自己的角色：

```bash
for u in alice carol; do CONFLUENT_PLATFORM_USERNAME=$u CONFLUENT_PLATFORM_PASSWORD=$(cat ~/secrets/ad-test-users.pass) confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem >/dev/null 2>&1 && echo "$u: $(confluent iam rbac role-binding list --principal User:$u --kafka-cluster $CLUSTER_ID -o json 2>/dev/null | grep -o '"role": *"[^"]*"' | sort -u | tr '\n' ' ')"; done; confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key >/dev/null
```

```out
alice: "role": "SystemAdmin"
carol: "role": "DeveloperRead"
```

# 12. 第十二站：REST Proxy

![edge]

@role 小安 | ops02 | cpadmin

REST Proxy 只接受 client 憑證，憑證的 CN 對應到 principal 的規則只列出走 REST 的 app，故意不加 DEFAULT，其他憑證一律對不上。

```bash
for h in rest01 rest02; do scp -q ~/pki/certs/truststore.p12 ~/pki/certs/cp-server.p12 ~/pki/certs/svc-rest.p12 ~/pki/certs/mds-token-public.pem $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -d -o root -g root -m 0755 /etc/confluent && sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka-rest && for f in truststore.p12 cp-server.p12 svc-rest.p12 mds-token-public.pem; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12 /tmp/mds-token-public.pem; printf "%-7s %s files\n" "$(hostname)" "$(sudo ls /etc/confluent/ssl | wc -l)"'; done
```

```out
rest01  4 files
rest02  4 files
```

```bash
cat > ~/conf/kafka-rest.tpl <<'EOF'
# REST Proxy ${HOST_FQDN}
id=${REST_ID}
listeners=https://0.0.0.0:8082
advertised.listeners=https://rest.poc.lab:8082
host.name=rest.poc.lab

############################# HTTPS + mandatory client certificates #############################
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
ssl.keystore.password=${STORE_PASSWORD}
ssl.key.password=${STORE_PASSWORD}
ssl.truststore.type=PKCS12
ssl.truststore.location=/etc/confluent/ssl/truststore.p12
ssl.truststore.password=${STORE_PASSWORD}
ssl.client.authentication=REQUIRED
ssl.enabled.protocols=TLSv1.3,TLSv1.2

############################# RBAC: authenticate by certificate, act as that principal #############################
kafka.rest.resource.extension.class=io.confluent.kafkarest.security.KafkaRestSecurityResourceExtension
rest.servlet.initializor.classes=io.confluent.common.security.jetty.initializer.AuthenticationHandler
confluent.rest.auth.propagate.method=SSL
confluent.rest.auth.ssl.principal.mapping.rules=RULE:.*CN=(app-legacy-billing)([^a-zA-Z0-9._-].*)?$/$1/
auth.ssl.principal.mapping.rules=RULE:.*CN=(app-legacy-billing)([^a-zA-Z0-9._-].*)?$/$1/
public.key.path=/etc/confluent/ssl/mds-token-public.pem

# MDS: REST Proxy authenticates with its own client certificate (User:svc-rest)
confluent.metadata.bootstrap.server.urls=https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090
confluent.metadata.ssl.keystore.type=PKCS12
confluent.metadata.ssl.keystore.location=/etc/confluent/ssl/svc-rest.p12
confluent.metadata.ssl.keystore.password=${STORE_PASSWORD}
confluent.metadata.ssl.key.password=${STORE_PASSWORD}
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=${STORE_PASSWORD}

############################# Kafka client (TOKEN listener, impersonated principal) #############################
bootstrap.servers=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094,kb04.poc.lab:9094
client.security.protocol=SASL_SSL
client.sasl.mechanism=OAUTHBEARER
client.sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenCertificateLoginCallbackHandler
client.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required metadataServerUrls="https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090";
client.ssl.keystore.type=PKCS12
client.ssl.keystore.location=/etc/confluent/ssl/svc-rest.p12
client.ssl.keystore.password=${STORE_PASSWORD}
client.ssl.key.password=${STORE_PASSWORD}
client.ssl.truststore.type=PKCS12
client.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
client.ssl.truststore.password=${STORE_PASSWORD}
client.ssl.endpoint.identification.algorithm=https

consumer.threads=8
consumer.instance.timeout.ms=300000
EOF
cd ~/conf && export STORE_PASSWORD=$(cat ~/pki/store.pass) && for h in rest01 rest02; do export HOST_FQDN=$h.poc.lab REST_ID=$h; (umask 077; envsubst '${HOST_FQDN} ${REST_ID} ${STORE_PASSWORD}' < kafka-rest.tpl > $h.kafka-rest.properties); scp -q $h.kafka-rest.properties $h.poc.lab:/tmp/kafka-rest.properties && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/kafka-rest.properties /etc/confluent/kafka-rest/kafka-rest.properties && rm -f /tmp/kafka-rest.properties && sudo install -d -m 0755 /etc/systemd/system/confluent-kafka-rest.service.d && sudo tee /etc/systemd/system/confluent-kafka-rest.service.d/10-override.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/kafka-rest-start /etc/confluent/kafka-rest/kafka-rest.properties
Environment="JAVA_HOME=/opt/java/current"
Environment="KAFKAREST_HEAP_OPTS=-Xms512m -Xmx512m"
LimitNOFILE=65536
Restart=on-failure
RestartSec=10
EOF
sudo systemctl daemon-reload && printf "%-7s config %s lines, unresolved=%s, exec=%s\n" "$(hostname)" "$(sudo grep -c . /etc/confluent/kafka-rest/kafka-rest.properties)" "$(sudo grep -c "\${" /etc/confluent/kafka-rest/kafka-rest.properties)" "$(systemctl show confluent-kafka-rest -p ExecStart --value | grep -o "/etc/[^ ]*properties")"'; done; unset STORE_PASSWORD
```

```out
rest01  config 47 lines, unresolved=0, exec=/etc/confluent/kafka-rest/kafka-rest.properties
rest02  config 47 lines, unresolved=0, exec=/etc/confluent/kafka-rest/kafka-rest.properties
```

啟動並測三種情況：legacy app 憑證 200、其他憑證 401、沒憑證被 TLS 直接拒絕：

```bash
for h in rest01 rest02; do ssh $h.poc.lab 'sudo systemctl enable --now confluent-kafka-rest >/dev/null 2>&1; sudo systemctl restart confluent-kafka-rest; printf "%-7s %s\n" "$(hostname)" "$(systemctl is-active confluent-kafka-rest)"'; done; sleep 40; for h in rest01 rest02; do echo "$h legacy-app=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key https://$h.poc.lab:8082/v3/clusters) other-cert=$(curl -s -o /dev/null -m 30 -w '%{http_code}' --cert ~/pki/certs/svc-ops.crt --key ~/pki/keys/svc-ops.key https://$h.poc.lab:8082/v3/clusters) no-cert=$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)"; done; echo "via LB: $(curl -s -o /dev/null -m 30 -w '%{http_code}' --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key https://rest.poc.lab:8082/v3/clusters)"
```

```out
rest01  active
rest02  active
rest01 legacy-app=200 other-cert=401 no-cert=000
rest02 legacy-app=200 other-cert=401 no-cert=000
via LB: 200
```

> 陷阱：`enable --now` 對已經在跑的服務不會重啟。設定改了要明確 `restart`，所以上面多了一行。

# 13. 第十三站：Control Center

@role 小安 | ops02 | cpadmin

C3 套件有三個服務：內建 Prometheus、Alertmanager（Go 程式，吃 PEM 檔）和 C3 本身。

```bash
scp -q ~/pki/certs/truststore.p12 ~/pki/certs/cp-server.p12 ~/pki/certs/cp-server.crt ~/pki/keys/cp-server.key ~/pki/certs/bank-root.pem ~/pki/certs/svc-c3.p12 ~/pki/certs/mds-token-public.pem c3-01.poc.lab:/tmp/ && ssh c3-01.poc.lab 'sudo install -d -o root -g root -m 0755 /etc/confluent && sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/control-center && for f in truststore.p12 cp-server.p12 cp-server.crt cp-server.key svc-c3.p12 mds-token-public.pem; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; sudo install -o root -g confluent -m 0640 /tmp/bank-root.pem /etc/confluent/ssl/ca.pem; rm -f /tmp/*.p12 /tmp/cp-server.* /tmp/bank-root.pem /tmp/mds-token-public.pem; echo "c3-01: $(sudo ls /etc/confluent/ssl | wc -l) files"'
```

```out
c3-01: 7 files
```

Prometheus、Alertmanager 的 TLS（要求 client 憑證）與設定。`*-generated.yml` 是 C3 自己會寫的檔，擁有者要是 `cp-control-center`：

```bash
ssh c3-01.poc.lab 'sudo tee /etc/confluent-control-center/web-config-prom.yml >/dev/null <<EOF
tls_server_config:
  cert_file: /etc/confluent/ssl/cp-server.crt
  key_file: /etc/confluent/ssl/cp-server.key
  client_ca_file: /etc/confluent/ssl/ca.pem
  client_auth_type: RequireAndVerifyClientCert
  min_version: TLS12
EOF
sudo cp /etc/confluent-control-center/web-config-prom.yml /etc/confluent-control-center/web-config-am.yml && sudo tee /etc/confluent-control-center/prometheus-generated.yml >/dev/null <<EOF
global:
  scrape_interval: 60s
  evaluation_interval: 60s
alerting:
  alertmanagers:
    - scheme: https
      tls_config:
        ca_file: /etc/confluent/ssl/ca.pem
        cert_file: /etc/confluent/ssl/cp-server.crt
        key_file: /etc/confluent/ssl/cp-server.key
      static_configs:
        - targets:
            - c3-01.poc.lab:9093
rule_files:
  - "recording_rules-generated.yml"
  - "trigger_rules-generated.yml"
scrape_configs:
EOF
cd /etc/confluent-control-center && sudo chown root:confluent web-config-prom.yml web-config-am.yml prometheus-generated.yml && sudo chmod 0640 web-config-prom.yml web-config-am.yml prometheus-generated.yml && sudo chown cp-control-center:confluent alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml && sudo chmod 0640 alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml && sudo install -d -m 0755 /etc/systemd/system/prometheus.service.d && printf "[Service]\nEnvironment=\"METRICS_RETENTION_DAYS=2d\"\nEnvironment=\"PROMETHEUS_HOST=0.0.0.0\"\nEnvironment=\"PROMETHEUS_PORT=9090\"\n" | sudo tee /etc/systemd/system/prometheus.service.d/10-override.conf >/dev/null && sudo systemctl daemon-reload && echo "c3-01: prometheus config ok"'
```

```out
c3-01: prometheus config ok
```

> 陷阱：`*-generated.yml` 若是 root 擁有，C3 啟動會報 `AccessDeniedException`。

C3 設定檔（整段貼到 EOF）：

```bash
cat > ~/conf/control-center.tpl <<'EOF'
confluent.controlcenter.id=10
confluent.controlcenter.name=poc-cluster
confluent.controlcenter.data.dir=/var/lib/confluent/control-center
confluent.controlcenter.internal.topics.replication=3
confluent.controlcenter.command.topic.replication=3
# confluent.license not set: evaluation mode

############################# Kafka connection (TOKEN listener, MDS tokens as svc-c3) #############################
bootstrap.servers=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094,kb04.poc.lab:9094
confluent.controlcenter.streams.security.protocol=SASL_SSL
confluent.controlcenter.streams.sasl.mechanism=OAUTHBEARER
confluent.controlcenter.streams.sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenCertificateLoginCallbackHandler
confluent.controlcenter.streams.sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required metadataServerUrls="https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090";
confluent.controlcenter.streams.ssl.keystore.type=PKCS12
confluent.controlcenter.streams.ssl.keystore.location=/etc/confluent/ssl/svc-c3.p12
confluent.controlcenter.streams.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.streams.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.streams.ssl.truststore.type=PKCS12
confluent.controlcenter.streams.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.streams.ssl.truststore.password=${STORE_PASSWORD}

############################# RBAC (humans log in with AD credentials through MDS) #############################
confluent.metadata.bootstrap.server.urls=https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090
confluent.controlcenter.rest.proxy.ssl.keystore.type=PKCS12
confluent.controlcenter.rest.proxy.ssl.keystore.location=/etc/confluent/ssl/svc-c3.p12
confluent.controlcenter.rest.proxy.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.rest.proxy.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.rest.proxy.ssl.truststore.type=PKCS12
confluent.controlcenter.rest.proxy.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.rest.proxy.ssl.truststore.password=${STORE_PASSWORD}
confluent.metadata.ssl.keystore.type=PKCS12
confluent.metadata.ssl.keystore.location=/etc/confluent/ssl/svc-c3.p12
confluent.metadata.ssl.keystore.password=${STORE_PASSWORD}
confluent.metadata.ssl.key.password=${STORE_PASSWORD}
confluent.metadata.ssl.truststore.type=PKCS12
confluent.metadata.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.metadata.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.rest.authentication.method=BEARER
public.key.path=/etc/confluent/ssl/mds-token-public.pem

############################# HTTPS UI #############################
confluent.controlcenter.rest.listeners=https://0.0.0.0:9021
confluent.controlcenter.rest.ssl.keystore.type=PKCS12
confluent.controlcenter.rest.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.rest.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.rest.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.rest.ssl.truststore.type=PKCS12
confluent.controlcenter.rest.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.rest.ssl.truststore.password=${STORE_PASSWORD}

############################# Embedded Prometheus / Alertmanager (mTLS) #############################
confluent.controlcenter.prometheus.enable=true
confluent.controlcenter.prometheus.url=https://c3-01.poc.lab:9090
confluent.controlcenter.prometheus.rules.file=/etc/confluent-control-center/trigger_rules-generated.yml
confluent.controlcenter.prometheus.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.prometheus.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.prometheus.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.alias.name=cp-server
confluent.controlcenter.alertmanager.url=https://c3-01.poc.lab:9093
confluent.controlcenter.alertmanager.config.file=/etc/confluent-control-center/alertmanager-generated.yml
confluent.controlcenter.alertmanager.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.alertmanager.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.keystore.location=/etc/confluent/ssl/cp-server.p12
confluent.controlcenter.alertmanager.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.alias.name=cp-server
EOF
cd ~/conf && export STORE_PASSWORD=$(cat ~/pki/store.pass) && (umask 077; envsubst '${STORE_PASSWORD}' < control-center.tpl > c3-01.control-center.properties) && unset STORE_PASSWORD && scp -q c3-01.control-center.properties c3-01.poc.lab:/tmp/control-center.properties && ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/control-center.properties /etc/confluent/control-center/control-center.properties && rm -f /tmp/control-center.properties && sudo install -d -o cp-control-center -g confluent -m 0750 /var/lib/confluent/control-center && sudo install -d -m 0755 /etc/systemd/system/confluent-control-center.service.d && sudo tee /etc/systemd/system/confluent-control-center.service.d/10-override.conf >/dev/null <<EOF
[Service]
TimeoutStartSec=420
ExecStartPre=/bin/bash -c "until curl -sk -o /dev/null https://kb01.poc.lab:8090/v1/metadata/id; do sleep 5; done"
ExecStart=
ExecStart=/usr/bin/control-center-start /etc/confluent/control-center/control-center.properties
Environment="JAVA_HOME=/opt/java/current"
Environment="CONTROL_CENTER_HEAP_OPTS=-Xms1536m -Xmx1536m"
LimitNOFILE=65536
Restart=on-failure
RestartSec=10
EOF
sudo systemctl daemon-reload && echo "c3-01: config $(sudo grep -c . /etc/confluent/control-center/control-center.properties) lines, unresolved=$(sudo grep -c "\${" /etc/confluent/control-center/control-center.properties), exec=$(systemctl show confluent-control-center -p ExecStart --value | grep -o "/etc/[^ ]*properties")"'
```

```out
c3-01: config 64 lines, unresolved=0, exec=/etc/confluent/control-center/control-center.properties
```

依序啟動，等 UI：

```bash
ssh c3-01.poc.lab 'for u in prometheus alertmanager confluent-control-center; do sudo systemctl enable --now $u >/dev/null 2>&1; sudo systemctl restart $u; sleep 3; printf "%-26s %s\n" $u "$(systemctl is-active $u)"; done'; echo "prometheus=$(curl -s -o /dev/null -w '%{http_code}' --cert ~/pki/certs/cp-server.crt --key ~/pki/keys/cp-server.key https://c3-01.poc.lab:9090/-/ready)"; for i in $(seq 1 24); do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://c3-01.poc.lab:9021/); [ "$c" = 200 ] && break; sleep 10; done; echo "c3 ui=$c after ~$((i*10))s"
```

```out
prometheus                 active
alertmanager               active
confluent-control-center   active
prometheus=200
c3 ui=200 after ~30s
（第一次啟動 30–120 秒都正常）
```

Windows 瀏覽器開 `https://localhost:19021`，用 alice 登入（密碼在 `~/secrets/ad-test-users.pass`）。憑證是銀行 CA 簽的，瀏覽器沒裝銀行根憑證會有警告，lab 先略過。Alertmanager 的 9093 只開給同一台的 C3，從操作機連不到是正常的。

# 14. 終點：小安的檢查清單

到這裡平台已經能用。後面是**延伸站**：第 15、16 站把密碼搬進銀行的 CyberArk（二選一，看銀行有沒有 Conjur）；第 17 站裝維運選單；第 18 站讓行內 Prometheus 抓指標；第 19 站稽核日誌。第 20 站是交付前一次跑完的驗收與收尾清單。第 21 站是之後每年都會用到的憑證輪替；第 22 站是升級 Confluent 與 JDK。

@role 小安 | ops02 | cpadmin

全部做完，用這幾條確認整套是健康的：

```bash
export JAVA_HOME=/opt/java/current; for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'printf "%-5s %s\n" "$(hostname)" "$(systemctl is-active confluent-server)"'; done; kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status | grep LeaderId; for h in kb01 kb02 kb03 kb04; do printf "%s MDS=%s " $h "$(curl -s -o /dev/null -m 5 -w %{http_code} https://$h.poc.lab:8090/v1/metadata/id)"; done; echo; echo "topics: $(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list | grep -v '^_' | paste -sd' ')"; echo "rest via LB: $(curl -s -o /dev/null -m 30 -w %{http_code} --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key https://rest.poc.lab:8082/v3/clusters)"; echo "c3 ui: $(curl -s -o /dev/null -m 10 -w %{http_code} https://c3-01.poc.lab:9021/)"; echo "metrics in prometheus: $(curl -s -m 10 --cert ~/pki/certs/cp-server.crt --key ~/pki/keys/cp-server.key https://c3-01.poc.lab:9090/api/v1/label/__name__/values | grep -o 'confluent_kafka_server[a-z_]*' | sort -u | wc -l) kinds"
```

```out
kc01  active
（7 行 active）
LeaderId:               1
kb01 MDS=200 kb02 MDS=200 kb03 MDS=200 kb04 MDS=200
topics: billing.events confluent-audit-log-events orders.events payments.events poc-cluster-2-6-1-10-AlertHistoryStore-changelog …
rest via LB: 200
c3 ui: 200
metrics in prometheus: 111 kinds
（C3 起來後會自己建幾個 poc-cluster-… 開頭的 topic；metrics 種類 100 多種都正常）
```

| 已完成 | 還沒做（之後的旅程） |
|---|---|
| 11 台主機就緒、套件裝好並鎖版本 | 設定檔密碼交保管庫（第 15 章 Conjur 或第 16 章 Secret Protection，二選一） |
| 7 張銀行憑證、truststore、MDS token 金鑰 | 維運選單（OP menu）；稽核日誌分流與專用寫入帳號 |
| controller、broker、MDS、RBAC（人員綁 AD 群組） | 外部監控的 JMX exporter（7071） |
| 應用程式 SCRAM 帳號、配額、範例 topic | 正式的端對端驗收清單 |
| REST Proxy（憑證認證，經負載平衡）、C3（含 Prometheus） | 收回安裝帳號的 sudo、移交文件；之後的憑證輪替（第 21 章）、升級（第 22 章） |

## 14.1 出問題先看哪裡

| 元件 | 主機 | 服務名稱 | 看日誌 | 健康檢查 |
|---|---|---|---|---|
| controller、broker | kc*、kb* | `confluent-server` | `sudo journalctl -u confluent-server -n 100 --no-pager` | quorum 有 leader；broker 的 `https://<host>:8090/v1/metadata/id` 回 200 |
| REST Proxy | rest* | `confluent-kafka-rest` | `sudo journalctl -u confluent-kafka-rest -n 100 --no-pager` | 帶 legacy 憑證 `curl …:8082/v3/clusters` 回 200 |
| Control Center | c3-01 | `confluent-control-center`、`prometheus`、`alertmanager` | `sudo journalctl -u confluent-control-center -n 100 --no-pager` | `https://c3-01.poc.lab:9021/` 回 200 |
| AD | ad01 | samba（entrypoint 常駐） | `docker logs lab-ad01-1` | `openssl s_client -connect ad01.poc.lab:636` 驗證通過 |
| 套件庫 | repo01 | `httpd` | `docker exec lab-repo01-1 journalctl -u httpd -n 50` | `https://repo01.poc.lab/confluent/repodata/repomd.xml` 回 200 |

先看三件事：服務是不是 `active`、ExecStart 指向哪份設定、日誌最後 20 行的 ERROR。九成的問題在這裡。

> 陷阱：broker 是 `active`、9092 也開了，但 9094／9095／9096 和 MDS 的 8090 一直沒開，日誌最後停在 `Waiting for all of the authorizer futures to be completed`、之後沒有任何 ERROR：多半是 AD 查詢帳號（svc-mds-bind）的密碼和 AD 上的不一致。broker 第一次向 AD 查群組失敗後只會安靜地重試，不印原因。對齊密碼（`ldap-bind.pass` 與 AD 帳號）後不用重啟，它會自己接著起來。

## 14.2 做錯了怎麼重來

| 步驟 | 能不能重跑 | 怎麼做 |
|---|---|---|
| 派送憑證、設定檔、drop-in（10–13 站） | 可以，重跑就是覆蓋成一樣的內容 | 改完記得 `sudo systemctl restart <unit>` |
| 格式化儲存（10.4） | **不能**，`meta.properties` 存在就會拒絕 | 真要重來：停服務、`sudo rm -rf /var/lib/kafka/data/*`，所有 controller 和 broker 一起重做 |
| 憑證（9 站） | 可以，重新產生 CSR 再請銀行簽 | 舊的 `~/pki` 先改名保留；已經上線的環境照第 21 站換發，不要重跑第 9 站 |
| 裝套件（8 站） | 可以，dnf 看到已安裝就略過 | `versionlock add` 對已鎖的套件會再加一筆重複，重跑前先 `sudo dnf versionlock list` 看一下，已鎖的不要再加 |
| 整台主機重置 | lab 可以 | `docker compose -f compose.yml rm -sf <host> && docker compose -f compose.yml up -d <host>`，再對那台重做：3.2（根憑證信任與 OS 套件來源）、第 5 站（JDK）、第 7 站（OS 調校）、第 8 站（套件），以及它的角色在第 10、12、13 站的派送與啟動 |

## 14.3 小安踩過的坑

| 坑 | 症狀 | 怎麼避免 |
|---|---|---|
| 服務用 RPM 預設設定起來 | REST Proxy 開成無加密 HTTP；C3 連不上 Kafka | 啟動前看 `systemctl show <unit> -p ExecStart`，一定要指向我們的設定檔 |
| `enable --now` 不重啟 | 改了設定沒生效 | 改設定後明確 `systemctl restart` |
| 確認指令沒加 `sudo` | `ls /etc/confluent/ssl` Permission denied，以為沒放進去 | 0750 的目錄要 `sudo ls`、`sudo stat` |
| 相對路徑 | `scp certs/cp-server.p12` 只在特定目錄下才找得到 | 指令裡一律寫 `~/pki/certs/…` |
| C3 比 MDS 先起來 | 9021 不回應、日誌 `Failed to fetch MDS URLs … Client has already been closed`，而且不會自己好 | drop-in 加 `ExecStartPre` 等 MDS（第 13 站已加）；broker 全部重啟過一輪後若 C3 卡住，`systemctl restart confluent-control-center` |
| Git Bash 的 openssl 看不懂 `/c/Users/...` | `sign.sh` 靜靜失敗、沒有產出 `.crt` | 路徑先用 `cygpath -m` 轉成 `C:/Users/...`（0.5.5 的腳本已內建） |
| Docker 網段撞到別的 lab | `compose up` 報 `Pool overlaps` | 換 compose.yml 的 subnet 與 extra_hosts 的 IP（0.5.6） |
| C3 的 `*-generated.yml` 是 root 擁有 | `AccessDeniedException` | 四個 generated 檔給 `cp-control-center:confluent` |
| dnf 快取太舊 | 剛上架的套件「找不到」 | 加 `--refresh` |
| 建銀行 OS 套件庫（3.2）時先裝工具再下載 | 套件庫少了 `createrepo_c-libs` | 乾淨容器，先下載、再裝工具 |
| lab 專用：Docker VM 網路層卡死 | 所有 Java 都變慢、`docker stats` 也卡 | 任一容器 `timeout 5 ip addr` 卡住就重啟 Docker Desktop，不要查設定 |




# 15. 第十五站：把密碼搬進 CyberArk Conjur

![conjur]

到第 13 站為止，平台能跑，但 keystore 密碼和 AD 查詢帳號的密碼是以明文寫在各主機的 properties 裡（0640、只有 root 和 confluent 群組讀得到）。銀行的規範是機敏資料一律放 CyberArk。這一站把它們搬進銀行的 Conjur，properties 裡只留下「去 Conjur 拿哪一個值」的參照，服務啟動時才取回來。

| 誰 | 做什麼 |
|---|---|
| 銀行 Secrets 團隊 | 建 Conjur、寫 policy（哪些主機能讀哪些值）、把每台主機的 API key 和一個給小安寫值用的身分交給小安 |
| 小安 | 把值寫進 Conjur、派送 provider jar、改 properties、滾動重啟、驗證 |

兩個誠實的提醒：Confluent 的 CyberArk provider（`csid-secrets-providers`）只接 **Conjur** 的 API，只有 PAM 沒有 Conjur 的銀行用不到它；而且它是 CSID 的社群專案，不在 Confluent Platform 的正式支援範圍。

## 15.1 銀行建 Conjur

@role 銀行 Secrets 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

Conjur OSS 本身只講 HTTP，前面放一個 nginx 做 TLS，憑證一樣由銀行 CA 簽；資料放 PostgreSQL。三個容器接在既有的 `labnet` 上，主機名 `conjur.poc.lab`。

先產 TLS 憑證與 Conjur 的 data key（加密資料庫內容用的主金鑰，**遺失就全部解不開**）：

```bash
cd ~/kafka-lab && mkdir -p conjur/tls conjur/keys && (umask 077; docker run --rm cyberark/conjur data-key generate | tr -d '\r\n' > conjur/data_key; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > conjur/db.pass) && O="$(cygpath -m "$PWD/conjur/tls")" && MSYS_NO_PATHCONV=1 openssl req -new -newkey rsa:2048 -nodes -keyout "$O/conjur.key" -out "$O/conjur.csr" -subj "/CN=conjur.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:conjur.poc.lab,DNS:conjur" -addext "keyUsage=digitalSignature,keyEncipherment" -addext "extendedKeyUsage=serverAuth" 2>/dev/null && bash ca/sign.sh conjur/tls/conjur.csr conjur/tls/conjur.crt && ls conjur conjur/tls
```

```out
signed conjur.csr -> conjur.crt  (CN = conjur.poc.lab, O = PoC Bank, C = TW; EKU serverAuth)
data_key  db.pass  keys  tls
conjur.crt  conjur.csr  conjur.key
```

nginx 設定、環境檔（密碼只在 0600 檔裡）、compose：

```bash
cd ~/kafka-lab && cat > conjur/nginx.conf <<'EOF'
events {}
http {
  server {
    listen 443 ssl;
    server_name conjur.poc.lab;
    ssl_certificate     /etc/nginx/tls/conjur.crt;
    ssl_certificate_key /etc/nginx/tls/conjur.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { proxy_pass http://conjur:80; proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto https; }
  }
}
EOF
(umask 077; printf 'POSTGRES_PASSWORD=%s\nDATABASE_URL=postgres://postgres:%s@conjur-db/postgres\nCONJUR_DATA_KEY=%s\nCONJUR_AUTHENTICATORS=authn\n' "$(cat conjur/db.pass)" "$(cat conjur/db.pass)" "$(cat conjur/data_key)" > conjur/conjur.env)
cat > conjur.yml <<'EOF'
services:
  conjur-db:
    image: postgres:15
    env_file: conjur/conjur.env
    networks: [ labnet ]
    volumes: [ conjur-db:/var/lib/postgresql/data ]
    restart: unless-stopped
  conjur:
    image: cyberark/conjur:latest
    command: server
    env_file: conjur/conjur.env
    networks: [ labnet ]
    depends_on: [ conjur-db ]
    restart: unless-stopped
  conjur-proxy:
    image: nginx:1.28-alpine
    networks:
      labnet: { ipv4_address: 172.35.0.15, aliases: [ conjur.poc.lab, conjur-proxy ] }
    volumes:
      - ./conjur/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conjur/tls:/etc/nginx/tls:ro
    depends_on: [ conjur ]
    restart: unless-stopped
volumes:
  conjur-db:
EOF
MSYS_NO_PATHCONV=1 docker compose -f compose.yml -f conjur.yml up -d conjur-db conjur conjur-proxy 2>&1 | grep -c Started
```

```out
3
```

建立帳戶 `poc`（輸出含 admin 的 API key，存檔不印出）：

```bash
cd ~/kafka-lab && for i in $(seq 1 30); do docker exec lab-conjur-1 conjurctl wait >/dev/null 2>&1 && break; sleep 2; done; (umask 077; docker exec lab-conjur-1 conjurctl account create poc | grep -o 'API key for admin: .*' | awk '{print $NF}' | tr -d '\r\n' > conjur/keys/admin.key) && wc -c < conjur/keys/admin.key && docker run --rm --network lab_labnet -v "$(cygpath -m "$PWD/ca/root.crt"):/root.crt:ro" lab-node:1 curl -sS --cacert /root.crt -o /dev/null -w "conjur https=%{http_code}
" https://conjur.poc.lab/
```

```out
Created new account 'poc'
53
conjur https=200
```

最後一行同時證明了 TLS 憑證鏈（銀行根憑證簽的）和 nginx 到 Conjur 的轉發都通。

寫 policy：一個 `kafka` 區，11 台主機各一個 host 身分、一個給小安的 `ops` 使用者、三個變數。主機只能讀（`read`、`execute`），`ops` 能寫（`update`）。載入後 Conjur 回每個新身分的 API key，拆成一檔一把：

```bash
cd ~/kafka-lab && cat > conjur/kafka-policy.yml <<'EOF'
- !policy
  id: kafka
  body:
    - !user ops
    - !layer hosts
    - &hosts
      - !host ops02
      - !host kc01
      - !host kc02
      - !host kc03
      - !host kb01
      - !host kb02
      - !host kb03
      - !host kb04
      - !host rest01
      - !host rest02
      - !host c3-01
    - !grant
      role: !layer hosts
      members: *hosts
    - &vars
      - !variable store-password
      - !variable ldap-bind-password
      - !variable scram/app-orders
    - !permit
      role: !layer hosts
      privileges: [ read, execute ]
      resources: *vars
    - !permit
      role: !user ops
      privileges: [ read, execute, update ]
      resources: *vars
EOF
docker run --rm --network lab_labnet -v "$(cygpath -m "$PWD/ca/root.crt"):/root.crt:ro" -v "$(cygpath -m "$PWD/conjur"):/c" lab-node:1 bash -c 'set -e; T=$(curl -sS --cacert /root.crt -X POST --data-binary @/c/keys/admin.key https://conjur.poc.lab/authn/poc/admin/authenticate | base64 -w0); curl -sS --cacert /root.crt -H "Authorization: Token token=\"$T\"" -X PUT --data-binary @/c/kafka-policy.yml https://conjur.poc.lab/policies/poc/policy/root > /c/keys/policy-result.json; umask 077; python3 - <<PY
import json; r=json.load(open("/c/keys/policy-result.json"))
for k,v in r["created_roles"].items():
    name=k.split(":")[-1].replace("/","_"); open(f"/c/keys/{name}.key","w").write(v["api_key"])
    print(k)
PY
rm -f /c/keys/policy-result.json; ls /c/keys'
```

```out
poc:user:ops@kafka
poc:host:kafka/ops02
poc:host:kafka/kc01
（共 12 個身分）
admin.key  kafka_c3-01.key  kafka_kb01.key … ops@kafka.key
```

交給小安：每台主機自己的 API key 放到該主機（0600 root），`ops` 的 key 放到 ops02 的 `~/secrets/`。正式環境這一步是 PVWA 或 CCP，lab 用 `docker cp`：

```bash
cd ~/kafka-lab && for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker cp "$(cygpath -m "$PWD/conjur/keys/kafka_$h.key")" lab-$h-1:/root/conjur.key && docker exec lab-$h-1 bash -c 'install -d -m 0750 -o root -g $(getent group confluent >/dev/null && echo confluent || echo root) /etc/confluent/conjur; install -m 0640 -o root -g $(getent group confluent >/dev/null && echo confluent || echo root) /root/conjur.key /etc/confluent/conjur/host.key && rm -f /root/conjur.key && printf "%s " $(hostname)'; done; echo; docker cp "$(cygpath -m "$PWD/conjur/keys/ops@kafka.key")" lab-ops02-1:/home/cpadmin/secrets/conjur-ops.key && docker exec lab-ops02-1 bash -c 'chown cpadmin:cpadmin /home/cpadmin/secrets/conjur-ops.key && chmod 0600 /home/cpadmin/secrets/conjur-ops.key && ls -la /home/cpadmin/secrets/conjur-ops.key'
```

```out
ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
-rw------- 1 cpadmin cpadmin 52 … conjur-ops.key
```

> 陷阱：`docker cp` 進容器時不要放 `/tmp`。這些主機的 systemd 把 `/tmp` 掛成 tmpfs，`docker cp` 寫到的是被蓋住的底層目錄，容器裡的程序看不到檔案。放 `/root/` 再 `install` 到定位就好。

## 15.2 小安把值寫進 Conjur

@role 小安 | ops02 | cpadmin

用 `ops` 身分換 token，把目前在用的三個密碼寫進去（值從既有的 0600 檔讀，不出現在畫面上），再以 kb01 的 host 身分讀一次確認主機真的拿得到：

```bash
cd ~ && CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && T=$(curl -sS --cacert $CA -X POST --data-binary @$HOME/secrets/conjur-ops.key https://conjur.poc.lab/authn/poc/ops%40kafka/authenticate | base64 -w0) && for kv in store-password:pki/store.pass ldap-bind-password:secrets/ldap-bind.pass scram%2Fapp-orders:secrets/app-orders.pass; do curl -sS --cacert $CA -H "Authorization: Token token=\"$T\"" -X POST --data-binary @"$HOME/${kv#*:}" "https://conjur.poc.lab/secrets/poc/variable/kafka%2F${kv%%:*}" && echo "set kafka/${kv%%:*}"; done; unset T; HT=$(ssh kb01.poc.lab 'sudo cat /etc/confluent/conjur/host.key' | curl -sS --cacert $CA -X POST --data-binary @- https://conjur.poc.lab/authn/poc/host%2Fkafka%2Fkb01/authenticate | base64 -w0) && [ "$(curl -sS --cacert $CA -H "Authorization: Token token=\"$HT\"" https://conjur.poc.lab/secrets/poc/variable/kafka%2Fstore-password)" = "$(cat ~/pki/store.pass)" ] && echo "kb01 reads store-password: match"; unset HT
```

```out
set kafka/store-password
set kafka/ldap-bind-password
set kafka/scram%2Fapp-orders
kb01 reads store-password: match
```

## 15.3 下載機建 provider jar，派送、讓 JDK 信任銀行根憑證

@role 小安 | dl01 | root

provider 不是 RPM，Confluent 也沒有放到 Maven Central 或 GitHub release，只有原始碼和 Confluent Hub 的打包方式。所以在下載機用 Maven 從原始碼建（第一次要抓相依套件，約 15–20 分鐘），產出 Confluent Hub 格式的 zip，再從裡面挑出主機上**沒有**的 jar。挑的原因：zip 裡的 Jersey、HK2、Jakarta 等相依，Confluent Server 本來就有（而且版本更新），CLASSPATH 又排在最前面，全部放進去會把 Kafka 自己的蓋掉。

```bash
dnf -q -y install maven-openjdk21 git python3 unzip >/dev/null && mkdir -p ~/.m2 && cat > ~/.m2/settings.xml <<EOF
<settings><profiles><profile><id>confluent</id><activation><activeByDefault>true</activeByDefault></activation>
<repositories><repository><id>confluent</id><url>https://packages.confluent.io/maven/</url></repository></repositories>
<pluginRepositories><pluginRepository><id>confluent</id><url>https://packages.confluent.io/maven/</url></pluginRepository></pluginRepositories>
</profile></profiles></settings>
EOF
cd /tmp && rm -rf csid-secrets-providers && git clone -q --depth 1 https://github.com/confluentinc/csid-secrets-providers.git && cd csid-secrets-providers && git log -1 --format="commit %h %cd" && python3 - <<EOF
import re
p="pom.xml"; s=open(p).read(); s=re.sub(r"<extensions>.*?</extensions>","",s,flags=re.S); open(p,"w").write(s)
EOF
mvn -q -B -pl common,cyberark -am -DskipTests package 2>&1 | grep -E "BUILD|ERROR" | head -5; mkdir -p /out/tools/csid && unzip -q -j -o cyberark/target/components/packages/confluentinc-csid-secrets-provider-cyberark-*.zip "*/lib/csid-secrets-provider-*.jar" "*/lib/conjur-api-*.jar" -d /out/tools/csid && (cd /out/tools/csid && sha256sum *.jar > SHA256SUMS && ls)
```

```out
commit 7130a02 Thu Sep 24 22:41:32 2026 +0000
SHA256SUMS
conjur-api-3.1.2.jar
csid-secrets-provider-annotations-1.0.53-SNAPSHOT.jar
csid-secrets-provider-common-1.0.53-SNAPSHOT.jar
csid-secrets-provider-cyberark-1.0.53-SNAPSHOT.jar
```

> root pom 裡有一個只給 Confluent 內部發布用的 S3 外掛（`aws-maven`），公開 repo 抓不到，所以先把 `<extensions>` 段拿掉再建。zip 裡其他 20 個 jar（jersey、hk2、jakarta、gson、joda-time、javassist、commons-codec）主機上都已經有，不要帶。

這四個檔連同既有的 SHA256SUMS 一起走第 2 站的流程進內網；lab 照 2.4 送到操作機（`D=csid`）。

@role 小安 | ops02 | cpadmin

每台 Java 主機放到 `/usr/share/java/cp-secrets/`。另外 provider 連 Conjur 走 JVM 預設的信任庫，所以要把銀行根憑證匯進 JDK 的 `cacerts`（Kafka 自己的 TLS 用的是 truststore.p12，不受影響）：

```bash
ls ~/landing/tools/csid | wc -l && for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'sudo install -d -m 0755 /usr/share/java/cp-secrets' && scp -q ~/landing/tools/csid/*.jar $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -m 0644 /tmp/*.jar /usr/share/java/cp-secrets/ && rm -f /tmp/*.jar && sudo /opt/java/current/bin/keytool -importcert -noprompt -cacerts -storepass changeit -alias bank-root -file /etc/pki/ca-trust/source/anchors/bank-root.pem >/dev/null 2>&1; echo "$(hostname): $(ls /usr/share/java/cp-secrets | wc -l) jars, cacerts=$(/opt/java/current/bin/keytool -list -cacerts -storepass changeit -alias bank-root >/dev/null 2>&1 && echo ok || echo missing)"'; done
```

```out
5
ops02: 4 jars, cacerts=ok
（11 行，操作機也裝，之後扮演應用程式）
```

## 15.4 properties 只留參照

@role 小安 | ops02 | cpadmin

三個範本（common.tpl、kafka-rest.tpl、control-center.tpl）加上 provider 設定，並把 `${STORE_PASSWORD}`、`${LDAP_BIND_PASSWORD}` 換成 Conjur 的參照。參照的寫法是 `${cyberark:<變數路徑>:<變數路徑>}`：第一段是 provider 名稱，第二段是要取的變數，第三段是結果裡的 key，這個 provider 的結果 key 就等於變數路徑，所以寫兩次。

每台的 host 身分和 API key 各不同，所以多兩個範本變數 `HOST_SHORT`、`CONJUR_API_KEY`：

```bash
cd ~/conf && cat > conjur.tpl <<'EOF'

############################# Secrets from the bank's CyberArk Conjur #############################
config.providers=cyberark
config.providers.cyberark.class=io.confluent.csid.config.provider.cyberark.CyberArkConfigProvider
config.providers.cyberark.param.cyberark.url=https://conjur.poc.lab
config.providers.cyberark.param.cyberark.account=poc
config.providers.cyberark.param.cyberark.auth.username=host/kafka/${HOST_SHORT}
config.providers.cyberark.param.cyberark.auth.apikey=${CONJUR_API_KEY}
config.providers.cyberark.param.polling.enabled=false
EOF
for t in common controller broker kafka-rest control-center; do cp -n $t.tpl $t.tpl.plain; sed -e 's|\${STORE_PASSWORD}|${cyberark:kafka/store-password:kafka/store-password}|g' -e 's|\${LDAP_BIND_PASSWORD}|${cyberark:kafka/ldap-bind-password:kafka/ldap-bind-password}|g' $t.tpl.plain > $t.tpl; case $t in common|kafka-rest|control-center) cat conjur.tpl >> $t.tpl;; esac; done; grep -c 'cyberark' common.tpl controller.tpl broker.tpl kafka-rest.tpl control-center.tpl; grep -lE 'STORE_PASSWORD|LDAP_BIND_PASSWORD' *.tpl | wc -l
```

```out
common.tpl:N
controller.tpl:N
broker.tpl:N
kafka-rest.tpl:N
control-center.tpl:N
0
```

最後的 0 是「還留著 `${STORE_PASSWORD}` 的範本數」。小安第一次只改了三個範本，broker 範本裡 listener 專用的 `listener.name.token.ssl.keystore.password` 沒換到，broker 起來就報 `keystore password was incorrect`，所以這個檢查一定要是 0。

重新產生設定並派送。多出來的兩個變數：`HOST_SHORT` 是 Conjur 裡的 host 名稱，`CONJUR_API_KEY` 從該主機自己的 `/etc/confluent/conjur/host.key` 讀。`unresolved` 的檢查要排除 `${cyberark:…}`，那是故意留給 provider 的：

```bash
cd ~/conf && V='${HOST_FQDN} ${NODE_ID} ${RACK} ${HOST_SHORT} ${CONJUR_API_KEY}' && for h in kc01:1:- kc02:2:- kc03:3:- kb01:101:rack-a kb02:102:rack-a kb03:103:rack-b kb04:104:rack-b; do IFS=: read -r n id rack <<<"$h"; export HOST_FQDN=$n.poc.lab NODE_ID=$id RACK=$rack HOST_SHORT=$n CONJUR_API_KEY=$(ssh $n.poc.lab 'sudo cat /etc/confluent/conjur/host.key'); case $n in kc*) tpl=controller.tpl;; *) tpl=broker.tpl;; esac; (umask 077; { envsubst "$V" < $tpl; echo; envsubst "$V" < common.tpl; } > $n.server.properties); scp -q $n.server.properties $n.poc.lab:/tmp/server.properties && ssh $n.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/server.properties /etc/confluent/kafka/server.properties && rm -f /tmp/server.properties && echo "$(hostname): refs=$(sudo grep -c "\${cyberark:" /etc/confluent/kafka/server.properties) unresolved=$(sudo grep "\${" /etc/confluent/kafka/server.properties | grep -vc "\${cyberark:")"'; done; unset CONJUR_API_KEY; echo "plaintext store password left in rendered files: $(grep -lF "$(cat ~/pki/store.pass)" *.server.properties | wc -l)"
```

```out
kc01: refs=11 unresolved=0
（3 行 controller）
kb01: refs=17 unresolved=0
（4 行 broker）
plaintext store password left in rendered files: 0
```

REST Proxy 與 C3 同樣重做：

```bash
cd ~/conf && for h in rest01 rest02; do export HOST_FQDN=$h.poc.lab REST_ID=$h HOST_SHORT=$h CONJUR_API_KEY=$(ssh $h.poc.lab 'sudo cat /etc/confluent/conjur/host.key'); (umask 077; envsubst '${HOST_FQDN} ${REST_ID} ${HOST_SHORT} ${CONJUR_API_KEY}' < kafka-rest.tpl > $h.kafka-rest.properties); scp -q $h.kafka-rest.properties $h.poc.lab:/tmp/kafka-rest.properties && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/kafka-rest.properties /etc/confluent/kafka-rest/kafka-rest.properties && rm -f /tmp/kafka-rest.properties && echo "$(hostname): refs=$(sudo grep -c "\${cyberark:" /etc/confluent/kafka-rest/kafka-rest.properties) unresolved=$(sudo grep "\${" /etc/confluent/kafka-rest/kafka-rest.properties | grep -vc "\${cyberark:")"'; done; export HOST_SHORT=c3-01 CONJUR_API_KEY=$(ssh c3-01.poc.lab 'sudo cat /etc/confluent/conjur/host.key'); (umask 077; envsubst '${HOST_SHORT} ${CONJUR_API_KEY}' < control-center.tpl > c3-01.control-center.properties); unset CONJUR_API_KEY; scp -q c3-01.control-center.properties c3-01.poc.lab:/tmp/control-center.properties && ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/control-center.properties /etc/confluent/control-center/control-center.properties && rm -f /tmp/control-center.properties && echo "c3-01: refs=$(sudo grep -c "\${cyberark:" /etc/confluent/control-center/control-center.properties) unresolved=$(sudo grep "\${" /etc/confluent/control-center/control-center.properties | grep -vc "\${cyberark:")"'; echo "plaintext store password left in rendered files: $(grep -lF "$(cat ~/pki/store.pass)" *.kafka-rest.properties c3-01.control-center.properties | wc -l)"
```

```out
rest01: refs=9 unresolved=0
rest02: refs=9 unresolved=0
c3-01: refs=18 unresolved=0
plaintext store password left in rendered files: 0
```

## 15.5 讓服務載入 jar，滾動重啟

@role 小安 | ops02 | cpadmin

jar 透過環境變數讓啟動腳本帶進去，用第二個 drop-in 檔，不碰第 10 站寫好的 `10-override.conf`。Kafka 和 REST Proxy 的啟動腳本看的是 `CLASSPATH`（放最前面），Control Center 的腳本只看 `CONTROL_CENTER_CLASSPATH`（自己的 jar 排前面）；小安第一次兩邊都寫 `CLASSPATH`，C3 就報 `ClassNotFoundException`：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do case $h in rest*) u=confluent-kafka-rest; v=CLASSPATH;; c3*) u=confluent-control-center; v=CONTROL_CENTER_CLASSPATH;; *) u=confluent-server; v=CLASSPATH;; esac; ssh $h.poc.lab "sudo tee /etc/systemd/system/$u.service.d/20-conjur.conf >/dev/null <<EOF
[Service]
Environment=\"$v=/usr/share/java/cp-secrets/*\"
EOF
sudo systemctl daemon-reload && echo \"\$(hostname): \$(systemctl show $u -p Environment --value | tr ' ' '\n' | grep CLASSPATH)\""; done
```

```out
kc01: "CLASSPATH=/usr/share/java/cp-secrets/*"
（10 行；c3-01 那行是 CONTROL_CENTER_CLASSPATH。引號是 systemd 顯示含 `*` 的值時自己加的）
```

一台一台重啟，每台等健康再做下一台（controller 等 active、broker 等 MDS 回 200）：

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) after ~$((i*5))s"; done
```

```out
kc01 active
kc02 active
kc03 active
kb01 MDS=200 after ~80s
（4 行，20–80 秒都正常）
```

```bash
for h in rest01 rest02; do ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'; for i in $(seq 1 30); do [ "$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)" = 200 ] && break; sleep 5; done; echo "$h REST=$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)"; done; ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3 ui=$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) after ~$((i*5))s"
```

```out
rest01 REST=200
rest02 REST=200
c3 ui=200 after ~120s
```

## 15.6 驗證：主機上沒有明文、provider 真的有去 Conjur

@role 小安 | ops02 | cpadmin

```bash
for h in kb01 rest01 c3-01; do case $h in rest*) f=/etc/confluent/kafka-rest/kafka-rest.properties; u=confluent-kafka-rest;; c3*) f=/etc/confluent/control-center/control-center.properties; u=confluent-control-center;; *) f=/etc/confluent/kafka/server.properties; u=confluent-server;; esac; ssh $h.poc.lab "echo \"\$(hostname): plaintext=\$(sudo grep -cE '^[^#].*(password|credentials)=[^\$]' $f) refs=\$(sudo grep -c '\\\${cyberark:' $f) provider_log=\$(sudo journalctl -u $u --since '-10min' --no-pager | grep -ci 'cyberark')\""; done; echo "alice login: $(curl -sk -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)"
```

```out
kb01: plaintext=0 refs=17 provider_log=1980
rest01: plaintext=0 refs=9 provider_log=111
c3-01: plaintext=0 refs=18 provider_log=48
alice login: 200
```

`provider_log` 的數字很大，因為 Kafka 每建立一個設定物件就重新初始化 provider 一次（每次都向 Conjur 認證、取值），broker 啟動一次會做幾百次。功能沒問題但日誌很吵，正式環境可在 log4j2.yaml 把 `io.confluent.csid` 設成 WARN。

這個 `plaintext` 的 grep 只看 `password=`／`credentials=` 後面不是 `$` 的行，所以沒算到 `config.providers.cyberark.param.cyberark.auth.apikey=` 那一行，也就是「開保管庫的那把鑰匙」。它一定要落地一份（檔案 0640、只有 root 和 confluent 讀得到），這是任何保管庫方案都躲不掉的 secret zero；銀行若要求更進一步，就把 Conjur 的 authenticator 換成憑證（authn-cert），讓這把鑰匙變成主機既有的憑證。

## 15.7 演練：換 AD 查詢帳號的密碼

@role 銀行 AD 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

有了 Conjur，輪替就是「改 AD、改 Conjur 的值、滾動重啟 controller 與 broker」三步，properties 一個字都不用動。先由 AD 團隊改密碼並交給小安（lab 直接寫進 ops02 的檔）：

```bash
docker exec lab-ad01-1 bash -c 'P=$(openssl rand -base64 24 | tr -dc "A-Za-z0-9" | head -c 20); samba-tool user setpassword svc-mds-bind --newpassword="$P" >/dev/null && printf "%s" "$P" > /root/secrets/bind.pass && echo "AD: password changed"' && docker exec lab-ad01-1 cat /root/secrets/bind.pass | docker exec -i -u cpadmin lab-ops02-1 bash -c 'umask 077; cat > ~/secrets/ldap-bind.pass; echo "ops02: new bind password saved"'
```

```out
AD: password changed
ops02: new bind password saved
```

@role 小安 | ops02 | cpadmin

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && T=$(curl -sS --cacert $CA -X POST --data-binary @$HOME/secrets/conjur-ops.key https://conjur.poc.lab/authn/poc/ops%40kafka/authenticate | base64 -w0) && curl -sS --cacert $CA -H "Authorization: Token token=\"$T\"" -X POST --data-binary @"$HOME/secrets/ldap-bind.pass" https://conjur.poc.lab/secrets/poc/variable/kafka%2Fldap-bind-password && unset T && echo "conjur: kafka/ldap-bind-password updated" && for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done && for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done; echo "alice login after rotation: $(curl -sk -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)"
```

```out
conjur: kafka/ldap-bind-password updated
kc01 active
（controller 3 行）
kb01 MDS=200
（broker 4 行）
alice login after rotation: 200
```

> 這裡滾動重啟期間，還沒重啟的 broker 用舊密碼 bind 會失敗（AD 已經改了）。正式環境用兩組帳號 A／B 交替就沒有這個空窗：CPM 先改閒置的 B，Conjur 的值換成 B 的帳密，滾動重啟，最後才改 A。

## 15.8 應用程式這一端：拿 SCRAM 密碼連 broker

@role 小安（扮演應用程式） | ops02 | cpadmin

應用程式不會碰 broker 的設定，它只需要自己的 SCRAM 密碼。兩種拿法都驗一次。

**拿法一：app 自己向 Conjur 要密碼**（對應正式環境打 CCP 或 Conjur REST；會覆蓋第 11 章那份 `app-orders.properties`，內容一樣，只是密碼改從 Conjur 取）。ops02 用自己的 host 身分取 `kafka/scram/app-orders`，組成 client 設定，走 CLIENT 9095 寫一筆、讀一筆：

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && HT=$(sudo cat /etc/confluent/conjur/host.key | curl -sS --cacert $CA -X POST --data-binary @- https://conjur.poc.lab/authn/poc/host%2Fkafka%2Fops02/authenticate | base64 -w0) && P=$(curl -sS --cacert $CA -H "Authorization: Token token=\"$HT\"" https://conjur.poc.lab/secrets/poc/variable/kafka%2Fscram%2Fapp-orders) && unset HT && (umask 077; cat > ~/conf/app-orders.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-orders" password="$P";
ssl.truststore.type=PKCS12
ssl.truststore.location=/home/cpadmin/pki/certs/truststore.p12
ssl.truststore.password=$(cat ~/pki/store.pass)
EOF
) && unset P && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && BS=kb01.poc.lab:9095 && echo "hello-from-conjur-$(date +%s)" | kafka-console-producer --bootstrap-server $BS --producer.config ~/conf/app-orders.properties --topic orders.events >/dev/null && kafka-console-consumer --bootstrap-server $BS --consumer.config ~/conf/app-orders.properties --topic orders.events --group orders-conjur-check --from-beginning --max-messages 1 --timeout-ms 20000 2>/dev/null | tail -1
```

```out
hello-from-conjur-1792669175
```

**拿法二：Kafka client 自己的 config provider**。設定檔裡不放密碼，只放參照；CLI 工具就是 kafka-clients，帶上同一組 jar 就能解：

```bash
(umask 077; cat > ~/conf/app-orders-provider.properties <<EOF
config.providers=cyberark
config.providers.cyberark.class=io.confluent.csid.config.provider.cyberark.CyberArkConfigProvider
config.providers.cyberark.param.cyberark.url=https://conjur.poc.lab
config.providers.cyberark.param.cyberark.account=poc
config.providers.cyberark.param.cyberark.auth.username=host/kafka/ops02
config.providers.cyberark.param.cyberark.auth.apikey=$(sudo cat /etc/confluent/conjur/host.key)
config.providers.cyberark.param.polling.enabled=false
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-orders" password="\${cyberark:kafka/scram/app-orders:kafka/scram/app-orders}";
ssl.truststore.type=PKCS12
ssl.truststore.location=/home/cpadmin/pki/certs/truststore.p12
ssl.truststore.password=$(cat ~/pki/store.pass)
EOF
) && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml CLASSPATH="/usr/share/java/cp-secrets/*" && BS=kb01.poc.lab:9095 && echo "hello-via-provider-$(date +%s)" | kafka-console-producer --bootstrap-server $BS --producer.config ~/conf/app-orders-provider.properties --topic orders.events >/dev/null && kafka-console-consumer --bootstrap-server $BS --consumer.config ~/conf/app-orders-provider.properties --topic orders.events --group orders-provider-check --from-beginning --max-messages 2 --timeout-ms 20000 2>/dev/null | tail -1; unset CLASSPATH; grep -c "cyberark:" ~/conf/app-orders-provider.properties
```

```out
hello-via-provider-1792669189
1
```

兩種拿法對 broker 來說沒有差別，broker 看到的都是 `User:app-orders` 用 SCRAM-SHA-512 進來。差別在 app 團隊：拿法一是他們既有的「向 CyberArk 要字串」流程，拿法二是連程式都不用改、只改設定檔。

# 16. 第十六站：Secret Protection，master key 交 CyberArk 保管

![secretprotection]

第 15 站需要 Conjur。銀行若只有 PAM（沒有 Conjur），broker 沒有原廠 provider 可以用，改走 Confluent 自己的 **Secret Protection**：密碼加密後留在主機上的 `security.properties`，解密用的 master key 由 CyberArk 保管，啟動時經環境變數給服務。它和第 15 站是**二選一**；這一站從第 10 站的明文範本（第 15 站留下的 `*.tpl.plain`）重新開始。

```
passphrase ──(＋隨機 salt)──▶ master key ──▶ data key ──▶ 各個密碼的密文（security.properties）
（CyberArk 保管）              （CyberArk 保管）
                                   │
                        各主機 /etc/confluent/service.env（0600 root）→ systemd EnvironmentFile → 服務環境變數
```

| 誰 | 做什麼 |
|---|---|
| 銀行 Secrets 團隊 | 同一個 safe 開兩個 object：passphrase（銀行產生，只給平台工程師）、master key（16.2 產生後存入）；lab 用 Conjur 扮演 PAM Vault |
| 小安 | 取 passphrase 產 master key、交 CyberArk 保管、加密 properties、派送、滾動重啟；之後的 master key 輪替也是他 |

**為什麼兩樣都要存**（lab 實測）：master key 是 passphrase 加上一個隨機 salt 算出來的，salt 每次 `generate` 都重新產生，所以**只有 passphrase 算不回原本的 master key**；反過來，輪替 master key（16.6）時 CLI 要「目前的 master key＋舊 passphrase」兩樣都給。分成兩個 object 是為了分開授權：master key 給要啟動服務的一方（16.8 時是每台主機），passphrase 主機不應該讀得到。

lab 裡沒有 PAM，所以「向 CyberArk 取 passphrase」這個動作用第 15 站的 Conjur 代替；正式環境換成 PVWA 或 CCP，取回來的字串一樣。**所以 lab 即使選這一站，也要先做 15.1（建 Conjur、各主機與 ops 的身分）**；15.2 以後的步驟不用做。

## 16.1 銀行開好兩個 object，放進 passphrase

@role 銀行 Secrets 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

在既有的 `kafka` policy 底下加兩個變數：passphrase 只給 `ops` 使用者和操作機的 host 身分讀，值由銀行產生；master key 先開好空的、給 `ops` 寫，16.2 產生後由小安存入：

```bash
cd ~/kafka-lab && cat > conjur/sp-policy.yml <<'EOF'
- !variable secret-protection/passphrase
- !variable secret-protection/master-key
- !permit
  role: !user ops
  privileges: [ read, execute ]
  resource: !variable secret-protection/passphrase
- !permit
  role: !host ops02
  privileges: [ read, execute ]
  resource: !variable secret-protection/passphrase
- !permit
  role: !user ops
  privileges: [ read, execute, update ]
  resource: !variable secret-protection/master-key
EOF
(umask 077; openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > conjur/keys/sp-passphrase.txt) && docker run --rm --network lab_labnet -v "$(cygpath -m "$PWD/ca/root.crt"):/root.crt:ro" -v "$(cygpath -m "$PWD/conjur"):/c" lab-node:1 bash -c 'set -e; T=$(curl -sS --cacert /root.crt -X POST --data-binary @/c/keys/admin.key https://conjur.poc.lab/authn/poc/admin/authenticate | base64 -w0); curl -sS --cacert /root.crt -H "Authorization: Token token=\"$T\"" -X POST --data-binary @/c/sp-policy.yml https://conjur.poc.lab/policies/poc/policy/kafka >/dev/null && echo "policy: variables kafka/secret-protection/passphrase, master-key added"; curl -sS --cacert /root.crt -H "Authorization: Token token=\"$T\"" -X POST --data-binary @/c/keys/sp-passphrase.txt https://conjur.poc.lab/secrets/poc/variable/kafka%2Fsecret-protection%2Fpassphrase && echo "value set"'
```

```out
policy: variables kafka/secret-protection/passphrase, master-key added
value set
```

## 16.2 小安取 passphrase、產生 master key

@role 小安 | ops02 | cpadmin

用操作機的 host 身分取回 passphrase（只進 0600 檔，不印），再用 Confluent CLI 產生 master key。`security.properties` 是之後所有密文的容器：

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && HT=$(sudo cat /etc/confluent/conjur/host.key | curl -sS --cacert $CA -X POST --data-binary @- https://conjur.poc.lab/authn/poc/host%2Fkafka%2Fops02/authenticate | base64 -w0) && (umask 077; curl -sS --cacert $CA -H "Authorization: Token token=\"$HT\"" https://conjur.poc.lab/secrets/poc/variable/kafka%2Fsecret-protection%2Fpassphrase > ~/secrets/sp-passphrase.txt) && unset HT && echo "passphrase: $(wc -c < ~/secrets/sp-passphrase.txt) chars" && (umask 077; confluent secret master-key generate --local-secrets-file ~/secrets/security.properties --passphrase @"$HOME/secrets/sp-passphrase.txt" -o yaml | awk '/master_key/{print $2}' > ~/secrets/master.key) && echo "master key: $(wc -c < ~/secrets/master.key) chars" && ls -la ~/secrets/security.properties ~/secrets/master.key
```

```out
passphrase: 32 chars
Save the master key. It cannot be retrieved later.
master key: 45 chars
-rw------- 1 cpadmin cpadmin  45 … master.key
-rw------- 1 cpadmin cpadmin 169 … security.properties
```

「cannot be retrieved later」是 CLI 的提醒：CLI 不保存 master key，而且**再跑一次 `generate` 也拿不回同一把**（會換新的 salt，算出另一把）。所以產生之後馬上交 CyberArk 保管，確認存好了才往下派送；不能讓一把只存在操作機上的 key 上線。

lab：用 `ops` 身分寫進 16.1 開好的變數。`tr -d '\n'` 是必要的：`master.key` 檔尾有換行，原樣送進去的話之後取回的值會多一個換行字元，服務就解不開密文。

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && T=$(curl -sS --cacert $CA -X POST --data-binary @$HOME/secrets/conjur-ops.key https://conjur.poc.lab/authn/poc/ops%40kafka/authenticate | base64 -w0) && tr -d '\n' < ~/secrets/master.key | curl -sS --cacert $CA -H "Authorization: Token token=\"$T\"" -X POST --data-binary @- https://conjur.poc.lab/secrets/poc/variable/kafka%2Fsecret-protection%2Fmaster-key && unset T && echo "master key stored, hash $(tr -d '\n' < ~/secrets/master.key | sha256sum | cut -c1-12)"
```

```out
master key stored, hash 3f9c0a…（12 碼雜湊，之後用來核對保管的是不是這一把）
```

正式環境（只有 PVWA、程式碰不到保管庫）：小安把 `master.key` 的內容交 Secrets 團隊存進 PVWA 的 master key object（新版本；舊版本保留，回滾要用），存好後記下單號和這一把的雜湊，再往下做：

```bash
(umask 077; echo "$(tr -d '\n' < ~/secrets/master.key | sha256sum | cut -c1-12) CHG-xxxx" > ~/secrets/master-key.custody) && cat ~/secrets/master-key.custody
```

> 注意：只存 passphrase 是不夠的。passphrase 遺失、master key 還在：服務照常，只是不能用 16.6 的 `rotate`；master key 遺失：服務照常（每台的 `service.env` 都有），但主機重建時拿不到；兩樣都遺失：產生新的 master key、照 16.3–16.5 從明文來源重新加密並滾動重啟（約 30 分鐘，不中斷服務）。

## 16.3 加密每台的 properties

@role 小安 | ops02 | cpadmin

先用第 10、12、13 站的方式從明文範本產生每台的設定（和之前完全一樣，只是範本來源是 `.plain`），再逐檔加密所有 `password`／`credentials` 欄位。加密後原檔裡的值變成 `${securepass:…}` 參照，密文集中寫進 `security.properties`：

```bash
cd ~/conf && for t in common controller broker kafka-rest control-center; do [ -f $t.tpl.plain ] && cp $t.tpl.plain $t.tpl; done; export STORE_PASSWORD=$(cat ~/pki/store.pass) LDAP_BIND_PASSWORD=$(cat ~/secrets/ldap-bind.pass) && V='${HOST_FQDN} ${NODE_ID} ${RACK} ${REST_ID} ${STORE_PASSWORD} ${LDAP_BIND_PASSWORD}' && for h in kc01:1:- kc02:2:- kc03:3:- kb01:101:rack-a kb02:102:rack-a kb03:103:rack-b kb04:104:rack-b; do IFS=: read -r n id rack <<<"$h"; export HOST_FQDN=$n.poc.lab NODE_ID=$id RACK=$rack; case $n in kc*) tpl=controller.tpl;; *) tpl=broker.tpl;; esac; (umask 077; { envsubst "$V" < $tpl; echo; envsubst "$V" < common.tpl; } > $n.server.properties); done; for h in rest01 rest02; do export HOST_FQDN=$h.poc.lab REST_ID=$h; (umask 077; envsubst "$V" < kafka-rest.tpl > $h.kafka-rest.properties); done; (umask 077; envsubst "$V" < control-center.tpl > c3-01.control-center.properties); unset STORE_PASSWORD LDAP_BIND_PASSWORD; export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key); for f in *.server.properties *.kafka-rest.properties c3-01.control-center.properties; do keys=$(grep -E '^[^#].*(password|credentials)=' $f | cut -d= -f1 | paste -sd,); confluent secret file encrypt --config-file $f --local-secrets-file ~/secrets/security.properties --remote-secrets-file /etc/confluent/secrets/security.properties --config "$keys" >/dev/null && echo "$f: $(grep -c '\${securepass:' $f) encrypted, plaintext=$(grep -cE '^[^#].*(password|credentials)=[^$]' $f)"; done; unset CONFLUENT_SECURITY_MASTER_KEY; echo "security.properties: $(grep -c '^[^_].*ENC\[' ~/secrets/security.properties) entries"
```

```out
kb01.server.properties: 17 encrypted, plaintext=0
（broker 17、controller 11、REST 9、C3 18；10 個檔 plaintext 都是 0）
security.properties: 137 entries
```

> `${securepass:/etc/confluent/secrets/security.properties:kb01.server.properties/ssl.keystore.password}` 的最後一段是「本機檔名／欄位」，所以同一份 `security.properties` 可以放所有主機的密文，派送時每台拿同一個檔。

## 16.4 派送：properties、密文檔、master key

@role 小安 | ops02 | cpadmin

三樣東西到每台：加密後的 properties（原路徑）、`security.properties`（0640 root:confluent）、`service.env`（0600 root，只有一行 master key）。drop-in 加 `EnvironmentFile=`；若剛做過第 15 站，順手把 provider 的 drop-in 拿掉：

```bash
cd ~/conf && (umask 077; echo "CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)" > ~/secrets/service.env) && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do case $h in rest*) f=$h.kafka-rest.properties; dst=/etc/confluent/kafka-rest/kafka-rest.properties; u=confluent-kafka-rest;; c3*) f=c3-01.control-center.properties; dst=/etc/confluent/control-center/control-center.properties; u=confluent-control-center;; *) f=$h.server.properties; dst=/etc/confluent/kafka/server.properties; u=confluent-server;; esac; scp -q $f ~/secrets/security.properties ~/secrets/service.env $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo install -o root -g confluent -m 0640 /tmp/$f $dst && sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets && sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && sudo install -o root -g root -m 0600 /tmp/service.env /etc/confluent/service.env && rm -f /tmp/$f /tmp/security.properties /tmp/service.env && sudo rm -f /etc/systemd/system/$u.service.d/20-conjur.conf && printf '[Service]\nEnvironmentFile=/etc/confluent/service.env\n' | sudo tee /etc/systemd/system/$u.service.d/20-secret-protection.conf >/dev/null && sudo systemctl daemon-reload && echo \"\$(hostname): refs=\$(sudo grep -c 'securepass:' $dst) plaintext=\$(sudo grep -cE '^[^#].*(password|credentials)=[^\$]' $dst) env=\$(systemctl show $u -p EnvironmentFiles --value | cut -d' ' -f1)\""; done; rm -f ~/secrets/service.env
```

```out
kc01: refs=11 plaintext=0 env=/etc/confluent/service.env
（10 行；refs 和上一步的 encrypted 數相同）
```

## 16.5 滾動重啟、驗證

@role 小安 | ops02 | cpadmin

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) after ~$((i*5))s"; done; for h in rest01 rest02; do ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'; for i in $(seq 1 30); do [ "$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)" = 200 ] && break; sleep 5; done; echo "$h REST=$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)"; done; ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'; for i in $(seq 1 36); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3 ui=$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) after ~$((i*5))s"; echo "alice login: $(curl -sk -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)"
```

```out
kc01 active
（3 行）
kb01 MDS=200 after ~20s
（4 行，20–50 秒）
rest01 REST=200
rest02 REST=200
c3 ui=200 after ~80s
alice login: 200
```

master key 不會出現在 `systemctl show`（它在 EnvironmentFile 裡，不是 `Environment=`），也不在任何 properties：

```bash
ssh kb01.poc.lab 'echo "in systemctl show: $(systemctl show confluent-server -p Environment --value | grep -c MASTER_KEY)"; echo "in properties: $(sudo grep -rc MASTER_KEY /etc/confluent/kafka/server.properties /etc/confluent/secrets/security.properties | paste -sd,)"; echo "service.env: $(sudo stat -c "%U:%G %a" /etc/confluent/service.env)"'
```

```out
in systemctl show: 0
in properties: /etc/confluent/kafka/server.properties:0,/etc/confluent/secrets/security.properties:1
service.env: root:root 600
```

`security.properties` 裡那 1 筆是 `_metadata.symmetric_key.0.envvar=CONFLUENT_SECURITY_MASTER_KEY`，記的是「去哪個環境變數找 master key」，不是 key 本身。檔案開頭幾行 `_metadata.*` 是鹽、迭代次數，和被 master key 包起來的 data key。

## 16.6 演練：輪替 master key

@role 銀行 Secrets 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

銀行產生新 passphrase、放進保管庫（舊值 Conjur 會留版本）：

```bash
cd ~/kafka-lab && (umask 077; openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > conjur/keys/sp-passphrase-new.txt) && docker run --rm --network lab_labnet -v "$(cygpath -m "$PWD/ca/root.crt"):/root.crt:ro" -v "$(cygpath -m "$PWD/conjur"):/c" lab-node:1 bash -c 'T=$(curl -sS --cacert /root.crt -X POST --data-binary @/c/keys/admin.key https://conjur.poc.lab/authn/poc/admin/authenticate | base64 -w0); curl -sS --cacert /root.crt -H "Authorization: Token token=\"$T\"" -X POST --data-binary @/c/keys/sp-passphrase-new.txt https://conjur.poc.lab/secrets/poc/variable/kafka%2Fsecret-protection%2Fpassphrase && echo "new passphrase stored"'
```

```out
new passphrase stored
```

@role 小安 | ops02 | cpadmin

小安手上還有舊 passphrase（`sp-passphrase.txt`），取新的，用 `rotate --master-key` 把 data key 重新包一次。密碼本身與 properties 都不動，只有 `security.properties` 和各主機的 `service.env` 要換：

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && HT=$(sudo cat /etc/confluent/conjur/host.key | curl -sS --cacert $CA -X POST --data-binary @- https://conjur.poc.lab/authn/poc/host%2Fkafka%2Fops02/authenticate | base64 -w0) && (umask 077; curl -sS --cacert $CA -H "Authorization: Token token=\"$HT\"" https://conjur.poc.lab/secrets/poc/variable/kafka%2Fsecret-protection%2Fpassphrase > ~/secrets/sp-passphrase-new.txt) && unset HT && cp -p ~/secrets/security.properties ~/secrets/security.properties.bak && cp -p ~/secrets/master.key ~/secrets/master.key.bak && export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key) && (umask 077; confluent secret file rotate --master-key --passphrase @"$HOME/secrets/sp-passphrase.txt" --passphrase-new @"$HOME/secrets/sp-passphrase-new.txt" --local-secrets-file ~/secrets/security.properties -o yaml | awk '/master_key/{print $2}' > ~/secrets/master.key) && unset CONFLUENT_SECURITY_MASTER_KEY && echo "master key changed: $([ "$(sha256sum < ~/secrets/master.key)" = "$(sha256sum < ~/secrets/master.key.bak)" ] && echo no || echo yes)" && mv ~/secrets/sp-passphrase-new.txt ~/secrets/sp-passphrase.txt && (umask 077; echo "CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)" > ~/secrets/service.env) && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q ~/secrets/security.properties ~/secrets/service.env $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && sudo install -o root -g root -m 0600 /tmp/service.env /etc/confluent/service.env && rm -f /tmp/security.properties /tmp/service.env && printf "%s " $(hostname)'; done; rm -f ~/secrets/service.env; echo
```

```out
Save the master key. It cannot be retrieved later.
master key changed: yes
kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
```

（精簡的 OS 沒有 `cmp`，所以用 sha256sum 比對。）

新的 master key 一樣**先交 CyberArk 保管再上線**（指令同 16.2；正式環境照樣由 Secrets 團隊存進 PVWA、小安記單號）。保管庫裡兩個 object 這時都是新值，舊版本留著回滾用：

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && T=$(curl -sS --cacert $CA -X POST --data-binary @$HOME/secrets/conjur-ops.key https://conjur.poc.lab/authn/poc/ops%40kafka/authenticate | base64 -w0) && tr -d '\n' < ~/secrets/master.key | curl -sS --cacert $CA -H "Authorization: Token token=\"$T\"" -X POST --data-binary @- https://conjur.poc.lab/secrets/poc/variable/kafka%2Fsecret-protection%2Fmaster-key && unset T && echo "master key stored, hash $(tr -d '\n' < ~/secrets/master.key | sha256sum | cut -c1-12)"
```

```out
master key stored, hash 7d21e4…（和 16.2 那一把不同）
```

然後照 16.5 再滾動重啟一次（指令相同），每台起得來就代表新 master key 解得開：

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done; for h in rest01 rest02; do ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'; for i in $(seq 1 30); do [ "$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)" = 200 ] && break; sleep 5; done; echo "$h REST=$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)"; done; ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'; for i in $(seq 1 36); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3 ui=$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"; echo "alice login after master key rotation: $(curl -sk -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)"; rm -f ~/secrets/security.properties.bak ~/secrets/master.key.bak
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
rest01 REST=200
rest02 REST=200
c3 ui=200
alice login after master key rotation: 200
```

> 回滾：在刪掉 `.bak` 之前，把 `security.properties.bak` 和 `master.key.bak` 用 16.4 的方式派送回去、再滾動重啟一次，就回到舊 master key。所以 `.bak` 要等全部驗證完才刪。

## 16.7 要跟資安說清楚的事

| 項目 | 說明 |
|---|---|
| secret zero | master key 以一行落在每台主機的 `/etc/confluent/service.env`（0600 root）。資安若不接受磁碟副本，改用 `ExecStartPre` 在啟動前向 CCP 取 master key 寫到 `/run`（tmpfs），代價是啟動時 CyberArk 要在線 |
| CyberArk 在這裡做什麼（只有 PAM 時） | **保管與稽核，不參與執行期**：passphrase、master key 的正本與版本（重建主機、復原、輪替時取用）；誰在什麼時候取了、對應哪張變更單；以及 PSM／PSMP 控管誰能登入主機變成 root。服務啟動時不連 CyberArk |
| 擋得住什麼、擋不住什麼 | 擋得住：設定檔被複製出去（備份、工單附檔、診斷資料、`confluent` 群組的人）時看不到密碼。擋不住：這台主機上的 root（`service.env` 就在本機）。要連 root 都擋，需要啟動時向外取 master key 的機制（CCP 或 Conjur＋16.8） |
| 遺失怎麼辦 | master key 從 CyberArk 取回；passphrase 遺失只影響 `rotate`；兩樣都遺失就產生新的 master key、照 16.3–16.5 重新加密（不中斷服務） |
| 誰輪替 | CPM 不會自動輪替這種金鑰；由平台工程師依變更單執行 16.6，兩個 object 一起更新 |
| 密碼本身的輪替 | 另一條流程：改密碼 → `confluent secret file update`（或重新 `encrypt` 該欄位）→ 派送 → 重啟。與 master key 輪替無關 |
| 和第 15 站的差別 | 不依賴外部系統在線、原廠正式支援、不用 jar；但密碼是加密落地而不是啟動時取 |

> 陷阱：做過這一站之後，若回頭照第 10、12、13 站重新產生設定並派送，會把明文密碼寫回主機；改了設定要照 16.3–16.5 重新加密、派送、重啟。

## 16.8 選配：用 Summon 讓 master key 不落地

@role 銀行 Secrets 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

16.4 的 `service.env` 是整個方案裡唯一落地的 master key。CyberArk 的開源工具 **Summon** 可以把它拿掉：服務啟動時 Summon 先向保管庫取值、塞進子程序的環境變數，再執行真正的啟動腳本，磁碟上只剩「主機向保管庫認證用的身分」。代價是服務啟動時保管庫要在線。

master key 在 16.2 已經存進保管庫；銀行這裡只要讓每台主機讀得到它（passphrase 仍然只有平台工程師讀得到）：

```bash
cd ~/kafka-lab && cat > conjur/mk-policy.yml <<'EOF'
- !permit
  role: !layer hosts
  privileges: [ read, execute ]
  resource: !variable secret-protection/master-key
EOF
docker run --rm --network lab_labnet -v "$(cygpath -m "$PWD/ca/root.crt"):/root.crt:ro" -v "$(cygpath -m "$PWD/conjur"):/c" lab-node:1 bash -c 'set -e; T=$(curl -sS --cacert /root.crt -X POST --data-binary @/c/keys/admin.key https://conjur.poc.lab/authn/poc/admin/authenticate | base64 -w0); curl -sS --cacert /root.crt -H "Authorization: Token token=\"$T\"" -X POST --data-binary @/c/mk-policy.yml https://conjur.poc.lab/policies/poc/policy/kafka >/dev/null && echo "policy: hosts can read kafka/secret-protection/master-key"'
```

```out
policy: hosts can read kafka/secret-protection/master-key
```

@role 小安 | dl01 | root

Summon 和它的 Conjur provider 都是單一執行檔，從 GitHub release 抓並核對原廠的 SHA256，放進落地區：

```bash
mkdir -p /out/tools/summon && cd /out/tools/summon && curl -fsSL -o summon-linux-amd64.tar.gz https://github.com/cyberark/summon/releases/download/v0.13.1/summon-linux-amd64.tar.gz && curl -fsSL https://github.com/cyberark/summon/releases/download/v0.13.1/SHA256SUMS.txt | grep -F summon-linux-amd64.tar.gz | sha256sum -c - && curl -fsSL -o summon-conjur-linux-amd64.tar.gz https://github.com/cyberark/summon-conjur/releases/download/v0.9.3/summon-conjur-linux-amd64.tar.gz && curl -fsSL https://github.com/cyberark/summon-conjur/releases/download/v0.9.3/SHA256SUMS.txt | grep -F summon-conjur-linux-amd64.tar.gz | sha256sum -c - && sha256sum *.tar.gz > SHA256SUMS && ls
```

```out
summon-linux-amd64.tar.gz: OK
summon-conjur-linux-amd64.tar.gz: OK
SHA256SUMS
summon-conjur-linux-amd64.tar.gz
summon-linux-amd64.tar.gz
```

@role 小安 | ops02 | cpadmin

每台 Java 主機：裝兩個執行檔、寫 Conjur 的設定與身分（身分檔就是第 15 站發的 host API key，0640 root:confluent，服務帳號讀得到）、寫 `secrets.yml`（哪個環境變數對應哪個變數），然後以服務帳號試跑一次 Summon，確認取得到值而且和 `service.env` 裡的一樣：

```bash
cd ~/landing/tools/summon && sha256sum -c --quiet SHA256SUMS && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do case $h in rest*) svc=cp-kafka-rest;; c3*) svc=cp-control-center;; *) svc=cp-kafka;; esac; scp -q *.tar.gz $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo install -d -m 0755 /usr/local/lib/summon && sudo tar -xzf /tmp/summon-linux-amd64.tar.gz -C /usr/local/bin summon && sudo tar -xzf /tmp/summon-conjur-linux-amd64.tar.gz -C /usr/local/lib/summon summon-conjur && rm -f /tmp/summon*.tar.gz && sudo chmod 0755 /usr/local/bin/summon /usr/local/lib/summon/summon-conjur && printf 'appliance_url: https://conjur.poc.lab\naccount: poc\ncert_file: /etc/pki/ca-trust/source/anchors/bank-root.pem\nnetrc_path: /etc/conjur.identity\n' | sudo tee /etc/conjur.conf >/dev/null && printf 'machine https://conjur.poc.lab/authn\n  login host/kafka/$h\n  password %s\n' \"\$(sudo cat /etc/confluent/conjur/host.key)\" | sudo install -m 0640 -o root -g confluent /dev/stdin /etc/conjur.identity && printf 'CONFLUENT_SECURITY_MASTER_KEY: !var kafka/secret-protection/master-key\n' | sudo tee /etc/confluent/secrets.yml >/dev/null && a=\$(sudo -u $svc /usr/local/bin/summon -p /usr/local/lib/summon/summon-conjur -f /etc/confluent/secrets.yml printenv CONFLUENT_SECURITY_MASTER_KEY | sha256sum | cut -c1-12) && b=\$(sudo sed -n s/^CONFLUENT_SECURITY_MASTER_KEY=//p /etc/confluent/service.env | sha256sum | cut -c1-12) && echo \"\$(hostname): summon \$(/usr/local/bin/summon --version | awk '{print \$3}' | cut -d- -f1) as $svc: \$([ \$a = \$b ] && echo key-matches || echo MISMATCH)\""; done
```

```out
kc01: summon 0.13.1 as cp-kafka: key-matches
（10 行）
```

換啟動方式：第三個 drop-in 把 `ExecStart` 改成「Summon 包住原本的啟動腳本」，拿掉 16.4 的 `EnvironmentFile` drop-in，刪掉 `service.env`：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do case $h in rest*) u=confluent-kafka-rest; cmd="/usr/bin/kafka-rest-start /etc/confluent/kafka-rest/kafka-rest.properties";; c3*) u=confluent-control-center; cmd="/usr/bin/control-center-start /etc/confluent/control-center/control-center.properties";; *) u=confluent-server; cmd="/usr/bin/kafka-server-start /etc/confluent/kafka/server.properties";; esac; ssh $h.poc.lab "sudo tee /etc/systemd/system/$u.service.d/30-summon.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/summon -p /usr/local/lib/summon/summon-conjur -f /etc/confluent/secrets.yml $cmd
EOF
sudo rm -f /etc/systemd/system/$u.service.d/20-secret-protection.conf /etc/confluent/service.env && sudo systemctl daemon-reload && echo \"\$(hostname): exec=\$(systemctl show $u -p ExecStart --value | grep -o 'path=[^ ]*' | head -1 | cut -d= -f2) service.env=\$(sudo test -e /etc/confluent/service.env && echo present || echo gone)\""; done
```

```out
kc01: exec=/usr/local/bin/summon service.env=gone
（10 行）
```

滾動重啟，然後從程序的環境變數證明 master key 在那裡、磁碟上卻沒有：

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done; for h in rest01 rest02; do ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'; for i in $(seq 1 30); do [ "$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)" = 200 ] && break; sleep 5; done; echo "$h REST=$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)"; done; ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3 ui=$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"; ssh kb01.poc.lab 'p=$(systemctl show confluent-server -p MainPID --value); echo "kb01 main pid $p = $(ps -o comm= -p $p); java child has MASTER_KEY in env: $(sudo cat /proc/$(pgrep -P $p java)/environ | tr "\0" "\n" | grep -c "^CONFLUENT_SECURITY_MASTER_KEY=") ; on disk: $(sudo grep -rl CONFLUENT_SECURITY_MASTER_KEY= /etc/confluent /etc/systemd/system 2>/dev/null | wc -l) files"'
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
rest01 REST=200
rest02 REST=200
c3 ui=200
kb01 main pid 7764 = summon; java child has MASTER_KEY in env: 1 ; on disk: 0 files
```

主程序是 Summon，Java 是它的子程序，`systemctl stop` 送的訊號 Summon 會轉給子程序，停機和原本一樣。現在主機上和 master key 有關的只剩 `/etc/conjur.identity`（主機的 Conjur 身分）：這就是 secret zero，和第 15 站的 host API key 是同一把。

> 什麼時候不要用 Summon：如果銀行要求「保管庫故障時平台仍能重啟」，就留在 16.4 的 `service.env` 作法。兩者的差別只有啟動時要不要連得到保管庫。

## 16.9 選配：AD 查詢密碼不凍在密文裡，啟動時從保管庫注入

@role 小安 | ops02 | cpadmin

Secret Protection 有一個本質上的脫鉤：密碼加密後「凍」在 `security.properties`，CyberArk 只是保存一份副本。CPM 替 AD 查詢帳號（`svc-mds-bind`）換了密碼，broker 不會知道，一定要有人重算密文、派送、滾動重啟。對 keystore 這類我們自己管的密碼沒差；對由 CPM 管的 AD 密碼，可以換一條路：**不加密它，啟動時由 Summon 從保管庫取回放進環境變數，properties 用 Kafka 內建的 `EnvVarConfigProvider` 讀環境變數**。不需要任何額外的 jar，`securepass` 和 `env` 兩個 provider 並存，各管各的欄位。

```
CPM 換密碼 ──▶ AD                                 broker 啟動
            └─▶ 保管庫 kafka/ldap-bind-password ──▶ Summon 取值 → 環境變數 LDAP_BIND_PASSWORD ──▶ ${env:LDAP_BIND_PASSWORD}
                                                    （master key 也是同一趟 Summon 給的）
```

保管庫裡要有這個值（15.2 寫過；只做過 16 沒做 15.2 的話這一行會補上，值相同就是覆蓋）：

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && T=$(curl -sS --cacert $CA -X POST --data-binary @$HOME/secrets/conjur-ops.key https://conjur.poc.lab/authn/poc/ops%40kafka/authenticate | base64 -w0) && tr -d '\n' < ~/secrets/ldap-bind.pass | curl -sS --cacert $CA -H "Authorization: Token token=\"$T\"" -X POST --data-binary @- https://conjur.poc.lab/secrets/poc/variable/kafka%2Fldap-bind-password && unset T && echo "conjur: kafka/ldap-bind-password set"
```

```out
conjur: kafka/ldap-bind-password set
```

7 台 controller 與 broker（LDAP 設定在共用區塊，兩種都有）：`secrets.yml` 多一行、properties 三處改法（`confluent secret` 改寫過的檔是 `key = value`，等號兩邊有空白，sed 要容許）——`config.providers` 加上 `env`、宣告 `env` 的 class、`ldap.java.naming.security.credentials` 從 `${securepass:…}` 改成 `${env:LDAP_BIND_PASSWORD}`。改完以服務帳號試跑 Summon，確認取回的值和操作機手上的一樣：

```bash
B=$(tr -d '\n' < ~/secrets/ldap-bind.pass | sha256sum | cut -c1-12) && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do ssh $h.poc.lab "grep -q '^LDAP_BIND_PASSWORD:' /etc/confluent/secrets.yml || echo 'LDAP_BIND_PASSWORD: !var kafka/ldap-bind-password' | sudo tee -a /etc/confluent/secrets.yml >/dev/null; f=/etc/confluent/kafka/server.properties; sudo sed -i -e 's|^config.providers *=.*|config.providers = securepass,env|' -e '/^config.providers.env.class *=/d' -e 's|^ldap.java.naming.security.credentials *=.*|ldap.java.naming.security.credentials = \${env:LDAP_BIND_PASSWORD}|' \$f && echo 'config.providers.env.class = org.apache.kafka.common.config.provider.EnvVarConfigProvider' | sudo tee -a \$f >/dev/null && a=\$(sudo -u cp-kafka /usr/local/bin/summon -p /usr/local/lib/summon/summon-conjur -f /etc/confluent/secrets.yml printenv LDAP_BIND_PASSWORD | tr -d '\n' | sha256sum | cut -c1-12) && echo \"\$(hostname): providers=\$(sudo grep '^config.providers *=' \$f | sed 's/.*= *//') env-refs=\$(sudo grep -c 'env:LDAP_BIND_PASSWORD' \$f) securepass-refs=\$(sudo grep -c 'securepass:' \$f) summon-value=\$([ \$a = $B ] && echo matches || echo MISMATCH)\""; done
```

```out
kc01: providers=securepass,env env-refs=1 securepass-refs=10 summon-value=matches
kb01: providers=securepass,env env-refs=1 securepass-refs=16 summon-value=matches
（7 行；securepass 的參照比 16.3 少 1 個，就是搬去 env 的那個）
```

滾動重啟 controller、broker。驗證要挑一個**非得用查詢帳號不可**的動作：alice 登入只用她自己的帳密，群組快取也撐得住，看不出 bind 有沒有成功；重啟後快取是空的，alice 透過 LDAP listener 建 topic 時，MDS 必須先用查詢帳號到 AD 找出她的群組才會放行。再從 kb01 的程序環境證明密碼在環境變數裡、日誌沒有 LDAP 認證錯誤：

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done; export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml; [ -f ~/conf/client-alice.properties ] || (umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=PLAIN\nsasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=/home/cpadmin/pki/certs/truststore.p12\nssl.truststore.password=%s\n' "$(cat ~/secrets/ad-test-users.pass)" "$(cat ~/pki/store.pass)" > ~/conf/client-alice.properties); t=ldap-check-$(date +%s); echo "alice（群組 kafka-admins）建 topic：$(kafka-topics --bootstrap-server kb01.poc.lab:9096 --command-config ~/conf/client-alice.properties --create --topic $t --partitions 1 --replication-factor 3 2>&1 | grep -o 'Created topic\|TopicAuthorizationException' | head -1)"; kafka-topics --bootstrap-server kb01.poc.lab:9096 --command-config ~/conf/client-alice.properties --delete --topic $t >/dev/null 2>&1; ssh kb01.poc.lab 'p=$(systemctl show confluent-server -p MainPID --value); echo "kb01 java env has LDAP_BIND_PASSWORD: $(sudo cat /proc/$(pgrep -P $p java)/environ | tr "\0" "\n" | grep -c "^LDAP_BIND_PASSWORD="); credentials line: $(sudo grep "^ldap.java.naming.security.credentials" /etc/confluent/kafka/server.properties | sed "s/^[^=]*= *//"); ldap auth errors since restart: $(sudo journalctl -u confluent-server --since -5min --no-pager 2>/dev/null | grep -ci "AuthenticationException\|LDAP search failed")"'
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
alice（群組 kafka-admins）建 topic：Created topic
kb01 java env has LDAP_BIND_PASSWORD: 1; credentials line: ${env:LDAP_BIND_PASSWORD}; ldap auth errors since restart: 0
```

`security.properties` 裡舊的 `ldap.java.naming.security.credentials` 密文還在，只是沒有人參照它；下次 `confluent secret file remove` 清掉即可。

### 演練：CPM 換了 AD 密碼，平台怎麼跟上

@role 銀行 AD 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

正式環境這一步是 CPM：改 AD、更新保管庫，一次完成。lab 用 samba-tool 改密碼、再寫進 Conjur；小安這次**什麼都不用拿**：

```bash
docker exec lab-ad01-1 bash -c 'P=$(openssl rand -base64 24 | tr -dc "A-Za-z0-9" | head -c 20); samba-tool user setpassword svc-mds-bind --newpassword="$P" >/dev/null && printf "%s" "$P" > /root/secrets/bind.pass && echo "AD: password changed"' && cd ~/kafka-lab && docker exec lab-ad01-1 cat /root/secrets/bind.pass > conjur/keys/bind-new.txt && docker run --rm --network lab_labnet -v "$(cygpath -m "$PWD/ca/root.crt"):/root.crt:ro" -v "$(cygpath -m "$PWD/conjur"):/c" lab-node:1 bash -c 'T=$(curl -sS --cacert /root.crt -X POST --data-binary @/c/keys/admin.key https://conjur.poc.lab/authn/poc/admin/authenticate | base64 -w0); curl -sS --cacert /root.crt -H "Authorization: Token token=\"$T\"" -X POST --data-binary @/c/keys/bind-new.txt https://conjur.poc.lab/secrets/poc/variable/kafka%2Fldap-bind-password && echo "vault: kafka/ldap-bind-password updated"'; rm -f conjur/keys/bind-new.txt
```

```out
AD: password changed
vault: kafka/ldap-bind-password updated
```

@role 小安 | ops02 | cpadmin

不重算密文、不派送任何檔案，只滾動重啟；起來的那台就拿到新密碼。操作機本地的 `ldap-bind.pass` 已經是舊的，順手從保管庫取回更新（之後 16.3 若重做加密才會用到）：

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done; export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml; t=ldap-rotated-$(date +%s); echo "換密碼後 alice 建 topic：$(kafka-topics --bootstrap-server kb01.poc.lab:9096 --command-config ~/conf/client-alice.properties --create --topic $t --partitions 1 --replication-factor 3 2>&1 | grep -o 'Created topic\|TopicAuthorizationException' | head -1)"; kafka-topics --bootstrap-server kb01.poc.lab:9096 --command-config ~/conf/client-alice.properties --delete --topic $t >/dev/null 2>&1; echo "kb01 ldap auth errors since restart: $(ssh kb01.poc.lab 'sudo journalctl -u confluent-server --since -5min --no-pager 2>/dev/null | grep -ci "AuthenticationException\|LDAP search failed"')"; CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && HT=$(sudo cat /etc/confluent/conjur/host.key | curl -sS --cacert $CA -X POST --data-binary @- https://conjur.poc.lab/authn/poc/host%2Fkafka%2Fops02/authenticate | base64 -w0) && (umask 077; curl -sS --cacert $CA -H "Authorization: Token token=\"$HT\"" https://conjur.poc.lab/secrets/poc/variable/kafka%2Fldap-bind-password > ~/secrets/ldap-bind.pass) && unset HT && echo "ops02: ldap-bind.pass refreshed from vault"
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
換密碼後 alice 建 topic：Created topic
kb01 ldap auth errors since restart: 0
ops02: ldap-bind.pass refreshed from vault
```

> 和 15.7 一樣的提醒：滾動重啟期間，還沒重啟的 broker 用舊密碼 bind 會失敗，靠 AD 群組快取撐著。正式環境用 A／B 兩組查詢帳號交替，CPM 只准輪替閒置的那組，就沒有這個空窗。

| 密碼 | 誰管輪替 | 放法 | 換了之後要做什麼 |
|---|---|---|---|
| keystore、truststore | 我們（換憑證時） | Secret Protection 密文 | 重算密文、派送、滾動重啟（16.3–16.5） |
| AD 查詢帳號 | CPM | 保管庫 → Summon → `${env:…}` | 只滾動重啟 |
| master key | 我們（依變更單） | 保管庫 → Summon | 16.6 + 16.8 的寫回保管庫，滾動重啟 |

# 17. 第十七站：維運選單（OP menu）

![opmenu]

平台交給維運之後，日常作業不該靠人記指令。小安帶了一個文字選單：維運人員用自己的本機帳號登入操作機，輸入 AD 帳密，選單只顯示他有權限的項目，每一步留紀錄。重啟、看日誌這類要碰主機的動作，選單以 cpadmin ssh 過去做，私鑰在選單啟動時從銀行的保管庫取進 ssh-agent，不落地；主機上不放任何代理程式，只靠 sudoers 限制 cpadmin 能跑的指令。

| 誰 | 做什麼 |
|---|---|
| 銀行 Secrets 團隊 | 在保管庫開一個給選單用的身分，放兩個值：cpadmin 的 SSH 私鑰、緊急模式用的憑證 |
| 銀行 OS 團隊 | 操作機上建維運人員的本機帳號（lab 用 op01）；各主機 cpadmin 的 sudo 改成兩段式 |
| 小安 | 把值寫進保管庫、裝選單、派送設定、綁緊急身分的權限、試跑 |

lab 一樣用第 15.1 建的 Conjur 扮演 CyberArk（沒做第 15 章的話先做 15.1）。正式環境依銀行有什麼換來源：有 CCP 用 `ccp.sh`；**只有 PVWA（本案客戶）用 `manual`**：維運人員做主機類項目時，從 PVWA 取出私鑰貼進選單，選單只放進自己的 ssh-agent、不落地。

## 17.1 銀行開保管庫身分與兩個變數

@role 銀行 Secrets 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && cat > conjur/opmenu-policy.yml <<'EOF'
- !host opmenu
- !variable ssh/cpadmin
- !variable breakglass/pem
- !permit
  role: !host opmenu
  privileges: [ read, execute ]
  resources: [ !variable ssh/cpadmin, !variable breakglass/pem ]
- !permit
  role: !user ops
  privileges: [ read, execute, update ]
  resources: [ !variable ssh/cpadmin, !variable breakglass/pem ]
EOF
docker run --rm --network lab_labnet -v "$(cygpath -m "$PWD/ca/root.crt"):/root.crt:ro" -v "$(cygpath -m "$PWD/conjur"):/c" lab-node:1 bash -c 'set -e; T=$(curl -sS --cacert /root.crt -X POST --data-binary @/c/keys/admin.key https://conjur.poc.lab/authn/poc/admin/authenticate | base64 -w0); curl -sS --cacert /root.crt -H "Authorization: Token token=\"$T\"" -X POST --data-binary @/c/opmenu-policy.yml https://conjur.poc.lab/policies/poc/policy/kafka > /c/keys/opmenu-policy.json; umask 077; python3 - <<PY
import json; r=json.load(open("/c/keys/opmenu-policy.json"))
for k,v in r["created_roles"].items(): open("/c/keys/kafka_opmenu.key","w").write(v["api_key"]); print(k)
PY
rm -f /c/keys/opmenu-policy.json' && docker cp "$(cygpath -m "$PWD/conjur/keys/kafka_opmenu.key")" lab-ops02-1:/root/opmenu.key && echo "opmenu host key delivered to ops02 (root)"
```

```out
poc:host:kafka/opmenu
opmenu host key delivered to ops02 (root)
```

> 重複載入同一份 policy 是安全的：已存在的身分不會重發 API key（`created_roles` 會是空的），要重發用 Conjur 的 rotate API。

## 17.2 小安把值寫進保管庫、綁緊急身分的權限

@role 小安 | ops02 | cpadmin

兩個值：操作機 → 各主機的 cpadmin 私鑰（第 3.1 站那把；正式環境是 CPM 產生的那把），以及第 9 站簽好備用的 `opmenu-breakglass` 憑證（私鑰 + 憑證鏈，PEM）。然後把 `User:opmenu-breakglass` 綁成 SystemAdmin，這就是 91 緊急模式用的身分：

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && T=$(curl -sS --cacert $CA -X POST --data-binary @$HOME/secrets/conjur-ops.key https://conjur.poc.lab/authn/poc/ops%40kafka/authenticate | base64 -w0) && curl -sS --cacert $CA -H "Authorization: Token token=\"$T\"" -X POST --data-binary @$HOME/.ssh/id_ed25519 https://conjur.poc.lab/secrets/poc/variable/kafka%2Fssh%2Fcpadmin && echo "ssh key stored" && cat ~/pki/keys/opmenu-breakglass.key ~/pki/certs/opmenu-breakglass.crt | curl -sS --cacert $CA -H "Authorization: Token token=\"$T\"" -X POST --data-binary @- https://conjur.poc.lab/secrets/poc/variable/kafka%2Fbreakglass%2Fpem && echo "breakglass pem stored"; unset T; export JAVA_HOME=/opt/java/current && confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key >/dev/null 2>&1 && CID=$(curl -sk https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4) && confluent iam rbac role-binding create --principal User:opmenu-breakglass --role SystemAdmin --kafka-cluster "$CID" >/dev/null 2>&1; confluent iam rbac role-binding list --principal User:opmenu-breakglass --kafka-cluster "$CID" 2>/dev/null | tail -1
```

```out
ssh key stored
breakglass pem stored
  User:opmenu-breakglass | SystemAdmin | Cluster       |      |
```

維運群組要能跑健康檢查與重啟前的檢查（`kafka-topics --describe` 對每個 topic 都要 DescribeConfigs），只有 Operator 不夠；開發群組在自己的 prefix 上也要 DescribeConfigs 才看得到 topic 明細：

```bash
export JAVA_HOME=/opt/java/current && CID=$(curl -sk https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4) && confluent iam rbac role-binding create --principal Group:kafka-operators --role DeveloperManage --resource 'Topic:*' --kafka-cluster "$CID" >/dev/null 2>&1; confluent iam rbac role-binding create --principal Group:kafka-operators --role DeveloperRead --resource 'Group:*' --kafka-cluster "$CID" >/dev/null 2>&1; confluent iam rbac role-binding create --principal Group:kafka-devs --role DeveloperManage --resource Topic:orders. --prefix --kafka-cluster "$CID" >/dev/null 2>&1; confluent iam rbac role-binding list --principal Group:kafka-operators --kafka-cluster "$CID" 2>/dev/null | tail -n +3
```

```out
  Group:kafka-operators | DeveloperManage | Topic         | *    | LITERAL
  Group:kafka-operators | DeveloperRead   | Group         | *    | LITERAL
  Group:kafka-operators | Operator        | Cluster       |      |
```

> `DeveloperManage Topic:*` 同時給了建刪 topic 的能力。銀行若不接受，改給 ClusterAdmin，或規定健康檢查由管理員做。

## 17.3 裝選單

@role 小安 | Windows 終端 | 本機

選單的原始碼是本專案的 `opmenu/`。在外網端打包（檔名帶日期與內容的雜湊，內容不同就不會蓋掉舊的），連同 SHA256SUMS 放進落地區，再照 2.4 送進來（`D=opmenu`）。落地區只留最新一版，下面的 `tar -xzf opmenu-*.tar.gz` 才不會同時解到兩個：

```bash
cd <放 opmenu/ 原始碼的目錄> && v=$(date +%Y%m%d).$(find opmenu -type f | sort | xargs cat | sha256sum | cut -c1-8) && mkdir -p ~/kafka-lab/landing/tools/opmenu && rm -f ~/kafka-lab/landing/tools/opmenu/opmenu-*.tar.gz && tar -czf ~/kafka-lab/landing/tools/opmenu/opmenu-$v.tar.gz opmenu && (cd ~/kafka-lab/landing/tools/opmenu && sha256sum opmenu-*.tar.gz > SHA256SUMS && cat SHA256SUMS)
```

```out
3f9c…  opmenu-20261024.1a2b3c4d.tar.gz
```

@role 銀行 OS 團隊（lab 由小安用 sudo 代勞） | ops02 | cpadmin

維運人員的本機帳號（op01）與 `opmenu` 群組；選單從落地區解開到 `/opt/opmenu`（唯讀）；`/etc/opmenu/` 放設定、保管庫身分、truststore、主機金鑰清單；`/var/log/opmenu/` 給紀錄與匯出檔：

```bash
cd ~/landing/tools/opmenu && sha256sum -c --quiet SHA256SUMS && sudo groupadd -f opmenu && (id op01 >/dev/null 2>&1 || sudo useradd -m -s /bin/bash -G opmenu op01) && sudo rm -rf /opt/opmenu && sudo tar -xzf opmenu-*.tar.gz -C /opt && sudo chown -R root:root /opt/opmenu && sudo chmod -R a+rX /opt/opmenu && sudo install -d -m 0755 /etc/opmenu /etc/opmenu/ssl && sudo bash -c 'printf "login=host/kafka/opmenu\napi_key=%s\n" "$(cat /root/opmenu.key)" | install -m 0640 -o root -g opmenu /dev/stdin /etc/opmenu/conjur.identity && rm -f /root/opmenu.key' && sudo install -m 0644 ~/pki/certs/truststore.p12 /etc/opmenu/ssl/truststore.p12 && sudo install -m 0640 -g opmenu ~/pki/store.pass /etc/opmenu/ssl/truststore.pass && sudo install -m 0644 /etc/pki/ca-trust/source/anchors/bank-root.pem /etc/opmenu/ssl/ca.pem && ssh-keyscan -t ed25519 kc01.poc.lab kc02.poc.lab kc03.poc.lab kb01.poc.lab kb02.poc.lab kb03.poc.lab kb04.poc.lab rest01.poc.lab rest02.poc.lab c3-01.poc.lab 2>/dev/null | sort | sudo install -m 0644 /dev/stdin /etc/opmenu/known_hosts && sudo install -d -m 2775 -o root -g opmenu /var/log/opmenu && echo "opmenu $(ls /opt/opmenu/items | wc -l) items; known_hosts $(wc -l < /etc/opmenu/known_hosts) keys; $(id op01)"
```

```out
opmenu 27 items; known_hosts 20 keys; uid=1001(op01) gid=1002(op01) groups=1002(op01),1001(opmenu)
```

設定檔只填無法推算的值（連線位址、可重啟的服務清單、保管庫）。`OPMENU_ALLOW_ENV_OVERRIDE=1` 只為了下面能非互動試跑，正式環境拿掉：

```bash
sudo tee /etc/opmenu/opmenu.conf >/dev/null <<'EOF'
OPMENU_ENV_LABEL=LAB
OPMENU_BOOTSTRAP=kb01.poc.lab:9096,kb02.poc.lab:9096,kb03.poc.lab:9096,kb04.poc.lab:9096
OPMENU_CERT_DIR=/etc/opmenu/ssl
OPMENU_BROKER_SERVICES="kb01.poc.lab:confluent-server kb02.poc.lab:confluent-server kb03.poc.lab:confluent-server kb04.poc.lab:confluent-server"
OPMENU_AUX_SERVICES="rest01.poc.lab:confluent-kafka-rest rest02.poc.lab:confluent-kafka-rest c3-01.poc.lab:confluent-control-center"
OPMENU_CONTROLLER_HOSTS="kc01.poc.lab kc02.poc.lab kc03.poc.lab"
OPMENU_SSH_USER=cpadmin
OPMENU_USER_FROM_OS=0
OPMENU_SECRETS=conjur
OPMENU_CONJUR_URL=https://conjur.poc.lab
OPMENU_CONJUR_ACCOUNT=poc
OPMENU_CONJUR_IDENTITY=/etc/opmenu/conjur.identity
OPMENU_SSH_KEY_SECRET=kafka/ssh/cpadmin
OPMENU_BREAKGLASS_SECRET=kafka/breakglass/pem
OPMENU_LOG=/var/log/opmenu/opmenu.log
OPMENU_SYSLOG=0
OPMENU_ALLOW_ENV_OVERRIDE=1
EOF
sudo chmod 0644 /etc/opmenu/opmenu.conf && sudo runuser -u op01 -- /opt/opmenu/opmenu.sh --list | awk -F'\t' '{print $1, $5}' | head -8
```

```out
10 查看 leader 與 partition 分布(balance report)
11 cluster 與身分鏈健康檢查
12 列出 topic 與 partition 狀態
13 查看 consumer lag
14 查看某個 topic 的設定
15 查看 application 連線狀況
16 查看磁碟與 data directory 用量
17 查看 certificate 到期日
```

## 17.4 各主機 cpadmin 的 sudo 改成兩段式

@role 銀行 OS 團隊（lab 由小安用 sudo 代勞） | ops02 | cpadmin

永久只開重啟、查狀態、看日誌三件事；安裝、升級時 OS 團隊依變更單另開全權、做完收回。lab 為了之後還要做別的章節，全權那份先留著，用 kb04 證明「只剩窄規則時選單仍能重啟」：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'printf "cpadmin ALL=(root) NOPASSWD: /usr/bin/systemctl restart confluent-*, /usr/bin/systemctl status confluent-*, /usr/bin/journalctl -u confluent-*\n" | sudo install -m 0440 /dev/stdin /etc/sudoers.d/cpadmin-ops && sudo visudo -cf /etc/sudoers.d/cpadmin-ops >/dev/null && printf "%s " $(hostname)'; done; echo; ssh kb04.poc.lab 'sudo mv /etc/sudoers.d/cpadmin /root/cpadmin.sudoers.full; sudo -n ls /root >/dev/null 2>&1 && echo "kb04: full sudo STILL on" || echo "kb04: only the narrow rules now (sudo ls denied)"'
```

```out
kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
kb04: only the narrow rules now (sudo ls denied)
```

## 17.5 試跑：三種身分看到的選單不一樣

@role 小安（代打 bob、carol、alice；以 sudo 切成 op01 執行） | ops02 | cpadmin

互動模式就是 `op01` 登入後執行 `/opt/opmenu/opmenu.sh`，輸入自己的 AD 帳密。為了把結果印在這裡，用 `--run` 非互動跑；`--run menu` 只印這個人看得到的編號：

```bash
P=$(cat ~/secrets/ad-test-users.pass); op() { local u="$1"; shift; sudo env OPMENU_USER="$u" OPMENU_PASS="$P" OPMENU_YES=1 OPMENU_REASON="第 17 站試跑" JAVA_HOME=/opt/java/current HOME=/home/op01 runuser -p -u op01 -- /opt/opmenu/opmenu.sh --run "$@" 2>&1 | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g'; }; for u in bob carol alice; do printf '%-6s ' $u; op $u menu | grep '@@MENU@@' | cut -d' ' -f2-; done; unset P
```

```out
bob    10 11 12 13 14 15 16 17 18 19 21 22 23 27 43 45
carol  10 11 12 13 14 15 17 19
alice  10 11 12 13 14 15 16 17 18 19 21 22 23 27 31 32 33 34 35 36 37 41 42 43 44 45 91
```

bob（Operator）：健康檢查、看 kb04 的日誌（kb04 只剩窄規則；23 只列含 error／warn 字樣的行，INFO 裡有 errors 字眼也會被列出）、重啟 kb04；直接輸入他看不到的 31 會被擋：

```bash
P=$(cat ~/secrets/ad-test-users.pass); op() { local u="$1"; shift; sudo env OPMENU_USER="$u" OPMENU_PASS="$P" OPMENU_YES=1 JAVA_HOME=/opt/java/current HOME=/home/op01 runuser -p -u op01 -- /opt/opmenu/opmenu.sh --run "$@" 2>&1 | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g'; }; op bob 11 | grep -E '^-- (broker 在線:|你的 MDS token)'; op bob 23 kb04.poc.lab:confluent-server 10 | tail -1 | cut -c1-80; op bob 21 kb04.poc.lab:confluent-server | tail -1; for i in $(seq 1 24); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://kb04.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "kb04 MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://kb04.poc.lab:8090/v1/metadata/id) after ~$((i*5))s"; op bob 31 orders.x 1 | tail -1; unset P
```

```out
-- 你的 MDS token:已用 3s,剩約 3597s
-- broker 在線:4 / 4(設定的 broker 數)
Oct 22 22:40:15 kb04 summon[1078]（做過 16.8 時行首是 summon，沒做是 kafka-server-start）: [2026-10-22 22:40:15,683] INFO Updated lag of 0 groups, …
已重啟 kb04.poc.lab 的 confluent-server
kb04 MDS=200 after ~20s
項目 31 不在你的選單內(你的 AD 群組沒有這項權限),請依變更單申請。
```

alice（SystemAdmin）：建 topic、91 緊急模式（憑證從保管庫取、用完即丟）、刪 topic：

```bash
P=$(cat ~/secrets/ad-test-users.pass); op() { local u="$1"; shift; sudo env OPMENU_USER="$u" OPMENU_PASS="$P" OPMENU_YES=1 OPMENU_REASON="第 17 站試跑" JAVA_HOME=/opt/java/current HOME=/home/op01 runuser -p -u op01 -- /opt/opmenu/opmenu.sh --run "$@" 2>&1 | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g'; }; op alice 31 orders.optest 1 | tail -1; op alice 91 kafka-topics --list | grep -c '^[a-z_]'; op alice 33 orders.optest | grep 將執行; unset P
```

```out
Created topic orders.optest.
14
將執行:刪除 topic orders.optest,資料不可復原
```

## 17.6 收尾檢查

@role 小安 | ops02 | cpadmin

選單結束後不留東西：沒有 ssh-agent、磁碟上沒有私鑰；op01 讀得到保管庫身分檔（0640 root:opmenu）、讀不到 cpadmin 的檔案；紀錄每行有 AD 帳號、作業系統帳號、項目、結果：

```bash
echo "ssh-agent: $(pgrep -x ssh-agent | wc -l); private keys on disk: $(sudo grep -rls 'PRIVATE KEY' /home/op01 /dev/shm /tmp 2>/dev/null | grep -v runner.sh | wc -l); op01 reads identity: $(sudo runuser -u op01 -- cat /etc/opmenu/conjur.identity >/dev/null 2>&1 && echo yes || echo no); op01 reads cpadmin secrets: $(sudo runuser -u op01 -- ls ~/secrets >/dev/null 2>&1 && echo YES || echo no)"; sudo tail -4 /var/log/opmenu/opmenu.log | cut -c1-120; ssh kb04.poc.lab 'sudo mv /root/cpadmin.sudoers.full /etc/sudoers.d/cpadmin 2>/dev/null; echo "kb04 full sudo restored for the rest of the lab"'
```

```out
ssh-agent: 0; private keys on disk: 0; op01 reads identity: yes; op01 reads cpadmin secrets: no
2026-10-22 22:40:47 +0800 | LAB | alice | os=op01 | 91 breakglass | sid=1792680046-22240 | EMERGENCY | kafka-topics --li
2026-10-22 22:40:49 +0800 | LAB | alice | os=op01 | 91 緊急模式(以保管庫的備用憑證執行一個指令) | sid
2026-10-22 22:40:50 +0800 | LAB | alice | os=op01 | login | sid=1792680050-22629 | SSH_KEY_LOADED | kafka/ssh/cpadmin tt
2026-10-22 22:40:56 +0800 | LAB | alice | os=op01 | 33 刪除 topic | sid=1792680050-22629 | OK | orders.optest [rc=0 6s
kb04 full sudo restored for the rest of the lab
```

> 最後一行只是 lab 的事：後面的章節還需要 cpadmin 的全權。正式環境各主機只留 `cpadmin-ops` 那份窄規則。

@role 銀行 OS 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

17.4 為了證明「只剩窄規則時選單仍能重啟」，把 kb04 的全權 sudo 收掉了。正式環境的全權是變更時段由 OS 團隊依變更單開、做完收回；lab 後面的章節（第 18、19、21、22 章）都還要在 kb04 上安裝與派送，所以演練完把它放回去，當作「下一個變更時段開了全權」：

```bash
docker exec lab-kb04-1 bash -c 'mv /root/cpadmin.sudoers.full /etc/sudoers.d/cpadmin && visudo -cf /etc/sudoers.d/cpadmin >/dev/null && echo "kb04: full sudo back (change window)"'
```

```out
kb04: full sudo back (change window)
```

# 18. 第十八站：讓行內的 Prometheus 抓指標（JMX exporter）

![jmx]

C3 有自己的 Prometheus，但那是給 C3 用的。銀行的監控中心要自己的 Prometheus 抓每台 controller、broker、REST Proxy 的指標，再接自己的告警。做法是在每個 Java 程序掛 Prometheus 的 JMX exporter（javaagent），在 7071 開一個 HTTPS 端點，basic auth 保護；行內 Prometheus 拿我們產生的 scrape 設定與告警規則去接。

| 誰 | 做什麼 |
|---|---|
| 小安 | exporter jar 已在第 1.4 站帶進來；產抓取密碼、設定檔，派送、滾動重啟；產給銀行的 scrape 設定、告警規則、根憑證 |
| 銀行監控團隊 | 把三個檔放進自己的 Prometheus，確認 9 個 target 都是 up |

## 18.1 抓取密碼與設定檔

@role 小安 | ops02 | cpadmin

exporter 的設定檔只存密碼的加鹽 SHA-256，不存明文；鹽整個叢集固定一個。keystore 密碼則只能明文寫在這個 YAML 裡（exporter 不支援 Secret Protection），所以檔案一律 root:confluent 0640。controller 沒有 cp-server.p12，用 kafka-internal.p12：

```bash
install -d -m 0700 ~/monitoring && (umask 077; [ -s ~/secrets/jmx-scrape.pass ] || openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/jmx-scrape.pass; [ -s ~/secrets/jmx-scrape.salt ] || openssl rand -hex 16 > ~/secrets/jmx-scrape.salt) && SALT=$(cat ~/secrets/jmx-scrape.salt) && HASH=$(printf '%s:%s' "$SALT" "$(cat ~/secrets/jmx-scrape.pass)" | sha256sum | cut -d' ' -f1 | sed 's/^0*//') && for ks in cp-server kafka-internal; do (umask 077; cat > ~/monitoring/jmx-header-$ks.yml <<EOF
# Prometheus JMX exporter: HTTPS with this host's certificate, basic auth with a salted SHA-256 (no plaintext scrape password here)
httpServer:
  ssl:
    keyStore:
      filename: /etc/confluent/ssl/$ks.p12
      password: $(cat ~/pki/store.pass)
      type: PKCS12
    certificate:
      alias: $ks
  authentication:
    basic:
      username: prometheus
      passwordHash: $HASH
      algorithm: SHA-256
      salt: $SALT
lowercaseOutputName: true
lowercaseOutputLabelNames: true
EOF
); done; unset SALT HASH; echo "headers: $(ls ~/monitoring | tr '
' ' ')"
```

```out
headers: jmx-header-cp-server.yml jmx-header-kafka-internal.yml 
```

> 陷阱：exporter 比對雜湊時用 Java 的 `BigInteger.toString(16)`，開頭的 0 會被吃掉。雜湊剛好以 0 開頭（機率 1/16）時，帳密永遠 401；所以上面多了 `sed 's/^0*//'` 把前導 0 去掉再寫進 YAML。

要抓哪些 MBean、改成什麼名字，controller／broker 一份、REST Proxy 一份。**整段貼到 EOF**：

```bash
cat > ~/monitoring/rules-kafka.yml <<'EOF'
# Confluent Server (controllers + brokers): only the MBean domains alerting and capacity planning need
# (JVM metrics jvm_* come from the exporter's built-in collectors)
includeObjectNames:
  - "kafka.server:*"
  - "kafka.controller:*"
  - "kafka.network:type=RequestMetrics,name=RequestsPerSec,*"
  - "kafka.network:type=RequestMetrics,name=TotalTimeMs,*"
  - "kafka.network:type=SocketServer,*"
  - "kafka.log:type=LogFlushStats,*"
excludeObjectNames:
  - "kafka.server:type=*,clientId=*,*"
rules:
  # ...PerSec meters -> counters
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+)PerSec\w*, (.+)=(.+), (.+)=(.+)><>Count'
    name: kafka_$1_$2_$3_total
    type: COUNTER
    labels: { "$4": "$5", "$6": "$7" }
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+)PerSec\w*, (.+)=(.+)><>Count'
    name: kafka_$1_$2_$3_total
    type: COUNTER
    labels: { "$4": "$5" }
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+)PerSec\w*><>Count'
    name: kafka_$1_$2_$3_total
    type: COUNTER
  # meters without PerSec: RequestHandlerAvgIdlePercent (0..1, one-minute rate)
  - pattern: 'kafka.server<type=KafkaRequestHandlerPool, name=RequestHandlerAvgIdlePercent><>OneMinuteRate'
    name: kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent
    type: GAUGE
  # request latency percentiles
  - pattern: 'kafka.network<type=RequestMetrics, name=TotalTimeMs, request=(.+)><>(\d+)thPercentile'
    name: kafka_network_requestmetrics_totaltimems
    type: GAUGE
    labels: { request: "$1", quantile: "0.$2" }
  # gauges: UnderReplicatedPartitions, ActiveControllerCount, OfflinePartitionsCount, ...
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+), (.+)=(.+)><>Value'
    name: kafka_$1_$2_$3
    type: GAUGE
    labels: { "$4": "$5" }
  - pattern: 'kafka.(\w+)<type=(.+), name=(.+)><>Value'
    name: kafka_$1_$2_$3
    type: GAUGE
  - pattern: 'kafka.network<type=SocketServer><>([a-z-]+): (.+)'
    name: kafka_network_socketserver_$1
    type: GAUGE
EOF
cat > ~/monitoring/rules-rest.yml <<'EOF'
# REST Proxy: Jetty / REST request metrics + JVM
includeObjectNames:
  - "kafka.rest:type=jetty-metrics,*"
  - "kafka.rest:type=jersey-metrics,*"
rules:
  - pattern: 'kafka.rest<type=jetty-metrics><>([a-z-]+): (.+)'
    name: kafka_rest_jetty_$1
    type: GAUGE
  - pattern: 'kafka.rest<type=jersey-metrics><>([a-z0-9.-]+): (.+)'
    name: kafka_rest_jersey_$1
    type: GAUGE
EOF
echo "rules: kafka $(grep -c pattern ~/monitoring/rules-kafka.yml) patterns, rest $(grep -c pattern ~/monitoring/rules-rest.yml) patterns"
```

```out
rules: kafka 8 patterns, rest 2 patterns
```

## 18.2 派送 jar 與設定、掛上 javaagent

@role 小安 | ops02 | cpadmin

每台：jar 到 `/opt/jmx-exporter/`、設定檔 = 標頭 + 規則、第四個 drop-in 把 `-javaagent` 放進 `KAFKA_OPTS`（REST Proxy 是 `KAFKAREST_OPTS`）。7071 在第 7 站的防火牆已經開了：

```bash
JAR=$(ls ~/landing/tools/jmx_prometheus_javaagent-*.jar | xargs -n1 basename) && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02; do case $h in kc*) ks=kafka-internal; rules=rules-kafka; cfg=/etc/confluent/kafka/jmx-exporter.yml; u=confluent-server; var=KAFKA_OPTS;; kb*) ks=cp-server; rules=rules-kafka; cfg=/etc/confluent/kafka/jmx-exporter.yml; u=confluent-server; var=KAFKA_OPTS;; rest*) ks=cp-server; rules=rules-rest; cfg=/etc/confluent/kafka-rest/jmx-exporter.yml; u=confluent-kafka-rest; var=KAFKAREST_OPTS;; esac; cat ~/monitoring/jmx-header-$ks.yml ~/monitoring/$rules.yml > /tmp/jmx-$h.yml && scp -q ~/landing/tools/$JAR /tmp/jmx-$h.yml $h.poc.lab:/tmp/ && rm -f /tmp/jmx-$h.yml && ssh $h.poc.lab "sudo install -d -m 0755 /opt/jmx-exporter && sudo install -m 0644 /tmp/$JAR /opt/jmx-exporter/$JAR && sudo install -o root -g confluent -m 0640 /tmp/jmx-$h.yml $cfg && rm -f /tmp/$JAR /tmp/jmx-$h.yml && printf '[Service]\nEnvironment=\"$var=-javaagent:/opt/jmx-exporter/$JAR=7071:$cfg\"\n' | sudo tee /etc/systemd/system/$u.service.d/40-jmx.conf >/dev/null && sudo systemctl daemon-reload && echo \"\$(hostname): \$(systemctl show $u -p Environment --value | tr ' ' '\\n' | grep -o 'javaagent:[^ =]*' | head -1) \$(sudo wc -l $cfg | cut -d' ' -f1) lines\""; done
```

```out
kc01: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 61 lines
（9 行；REST Proxy 是 28 lines）
```

> 陷阱：落地區的檔案是唯讀的（第 2 站 `chmod a-w`），`scp` 到 `/tmp` 會連唯讀一起帶過去。流程正常跑完會 `rm -f`；若中途失敗留下唯讀檔，下一次 `scp` 會 `Permission denied`，先到那台 `rm -f /tmp/jmx*` 再重跑。

## 18.3 滾動重啟、驗證端點

@role 小安 | ops02 | cpadmin

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done; for h in rest01 rest02; do ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'; for i in $(seq 1 30); do [ "$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)" = 200 ] && break; sleep 5; done; echo "$h REST=$(curl -sk --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)"; done
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
rest01 REST=200
rest02 REST=200
```

沒帶帳密要被拒（401），帶了要看到指標；憑證鏈用銀行根憑證驗（不用 -k）：

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem; for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02; do u=https://$h.poc.lab:7071/metrics; a=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert $CA $u); m=$(curl -s --max-time 20 --cacert $CA -u "prometheus:$(cat ~/secrets/jmx-scrape.pass)" $u | grep -cE '^(kafka_|jvm_)'); printf '%-7s anon=%s metrics=%s\n' $h $a $m; done
```

```out
kc01    anon=401 metrics=681
kb01    anon=401 metrics=1054
rest01  anon=401 metrics=920
（9 行，anon 都是 401；controller 約 680、broker 約 1000、REST 約 920 個指標）
```

## 18.4 給銀行監控團隊的三個檔

@role 小安 | ops02 | cpadmin

scrape 設定（三個 job、HTTPS、basic auth 的密碼放檔案不放設定裡）、告警規則、根憑證；抓取密碼另外經保管庫交付（lab 直接給檔）：

```bash
cat > ~/monitoring/prometheus-scrape.yml <<'EOF'
# Confluent Platform targets for the bank's Prometheus (merge under scrape_configs)
# Files next to prometheus.yml: confluent/ca.pem (bank root CA), confluent/scrape.pass (basic-auth password, 0600)
scrape_configs:
  - job_name: confluent-controller
    scheme: https
    scrape_interval: 30s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    basic_auth: { username: prometheus, password_file: /etc/prometheus/confluent/scrape.pass }
    static_configs: [ { targets: [ "kc01.poc.lab:7071", "kc02.poc.lab:7071", "kc03.poc.lab:7071" ] } ]
  - job_name: confluent-broker
    scheme: https
    scrape_interval: 30s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    basic_auth: { username: prometheus, password_file: /etc/prometheus/confluent/scrape.pass }
    static_configs: [ { targets: [ "kb01.poc.lab:7071", "kb02.poc.lab:7071", "kb03.poc.lab:7071", "kb04.poc.lab:7071" ] } ]
  - job_name: confluent-rest
    scheme: https
    scrape_interval: 30s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    basic_auth: { username: prometheus, password_file: /etc/prometheus/confluent/scrape.pass }
    static_configs: [ { targets: [ "rest01.poc.lab:7071", "rest02.poc.lab:7071" ] } ]
rule_files: [ /etc/prometheus/confluent/alert-rules.yml ]
EOF
cat > ~/monitoring/alert-rules.yml <<'EOF'
# alert rules for the bank's Prometheus (metrics from the JMX exporter javaagent).
# Thresholds follow Confluent's monitoring guidance; tune "for:" to the bank's paging policy.
# Consumer-group lag is not a broker JMX metric: use Control Center (built in) or a lag exporter.
groups:
  - name: confluent-platform
    rules:
      - alert: KafkaTargetDown
        expr: up{job=~"confluent-.*"} == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "{{ $labels.instance }} ({{ $labels.job }}) cannot be scraped"
      - alert: KafkaUnderReplicatedPartitions
        expr: sum by (instance) (kafka_server_replicamanager_underreplicatedpartitions) > 0
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }}: {{ $value }} under-replicated partitions"
      - alert: KafkaUnderMinIsrPartitions
        expr: sum by (instance) (kafka_server_replicamanager_underminisrpartitioncount) > 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "{{ $labels.instance }}: partitions below min.insync.replicas (producers with acks=all fail)"
      - alert: KafkaOfflinePartitions
        expr: max(kafka_controller_kafkacontroller_offlinepartitionscount) > 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "{{ $value }} partitions have no leader"
      - alert: KafkaActiveControllerCount
        expr: sum(kafka_controller_kafkacontroller_activecontrollercount{job="confluent-controller"}) != 1
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "KRaft active controller count is {{ $value }} (expected exactly 1)"
      - alert: KafkaRequestHandlerSaturated
        expr: avg by (instance) (kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent) < 0.3
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }}: request handler threads less than 30% idle"
      - alert: KafkaNetworkProcessorSaturated
        expr: avg by (instance) (kafka_network_socketserver_networkprocessoravgidlepercent) < 0.3
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }}: network threads less than 30% idle"
      - alert: KafkaProduceLatencyHigh
        expr: max by (instance) (kafka_network_requestmetrics_totaltimems{request="Produce",quantile="0.99"}) > 500
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }}: produce p99 {{ $value }} ms"
      - alert: JvmHeapHigh
        expr: jvm_memory_used_bytes{area="heap"} / jvm_memory_max_bytes{area="heap"} > 0.9
        for: 10m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.instance }}: JVM heap above 90%"
EOF
cp /etc/pki/ca-trust/source/anchors/bank-root.pem ~/monitoring/ca.pem && (umask 077; cp ~/secrets/jmx-scrape.pass ~/monitoring/scrape.pass) && echo "for the bank: $(ls ~/monitoring | grep -vE 'jmx-header|rules-' | tr '\n' ' ')"
```

```out
for the bank: alert-rules.yml ca.pem prometheus-scrape.yml scrape.pass
```

## 18.5 銀行的 Prometheus 接上來

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

lab 用一個 Prometheus 容器當「行內 Prometheus」，接在 labnet（這個容器不在 compose 裡，主機名要用 `--add-host` 給它），載入小安給的三個檔，等一輪抓取後看 9 個 target 的狀態與規則是否載入：

```bash
cd ~/kafka-lab && mkdir -p bank-prometheus/confluent && for f in prometheus-scrape.yml alert-rules.yml ca.pem scrape.pass; do docker cp lab-ops02-1:/home/cpadmin/monitoring/$f "$(cygpath -m "$PWD/bank-prometheus/confluent/$f")"; done && mv bank-prometheus/confluent/prometheus-scrape.yml bank-prometheus/prometheus.yml && MSYS_NO_PATHCONV=1 docker run -d --name bank-prometheus --network lab_labnet --add-host kc01.poc.lab:172.35.0.21 --add-host kc02.poc.lab:172.35.0.22 --add-host kc03.poc.lab:172.35.0.23 --add-host kb01.poc.lab:172.35.0.31 --add-host kb02.poc.lab:172.35.0.32 --add-host kb03.poc.lab:172.35.0.33 --add-host kb04.poc.lab:172.35.0.34 --add-host rest01.poc.lab:172.35.0.41 --add-host rest02.poc.lab:172.35.0.42 -v "$(cygpath -m "$PWD/bank-prometheus/prometheus.yml"):/etc/prometheus/prometheus.yml:ro" -v "$(cygpath -m "$PWD/bank-prometheus/confluent"):/etc/prometheus/confluent:ro" prom/prometheus:v3.5.0 >/dev/null && sleep 45 && docker run --rm --network lab_labnet lab-node:1 bash -c 'curl -s http://bank-prometheus:9090/api/v1/targets | python3 -c "import json,sys; t=json.load(sys.stdin)[\"data\"][\"activeTargets\"]; print(\"targets up:\", sum(1 for x in t if x[\"health\"]==\"up\"), \"/\", len(t)); [print(\"  down:\", x[\"labels\"][\"instance\"], x[\"lastError\"][:80]) for x in t if x[\"health\"]!=\"up\"]"; curl -s http://bank-prometheus:9090/api/v1/rules | python3 -c "import json,sys; g=json.load(sys.stdin)[\"data\"][\"groups\"]; print(\"alert rules:\", sum(len(x[\"rules\"]) for x in g))"; curl -s "http://bank-prometheus:9090/api/v1/query?query=kafka_server_replicamanager_underreplicatedpartitions" | python3 -c "import json,sys; r=json.load(sys.stdin)[\"data\"][\"result\"]; print(\"under-replicated per broker:\", [x[\"value\"][1] for x in r])"'
```

```out
targets up: 9 / 9
alert rules: 9
under-replicated per broker: ['0', '0', '0', '0']
```

看完就收掉（正式環境這台是銀行的，不會收）：

```bash
docker rm -f bank-prometheus >/dev/null && echo "bank-prometheus removed"
```

```out
bank-prometheus removed
```

> 兩件事要跟銀行講清楚：(1) exporter 的 YAML 裡有 keystore 的明文密碼，所以是 root:confluent 0640，不能再放寬；(2) consumer lag 不是 broker 的 JMX 指標，要看 C3 或另外接 lag exporter。

# 19. 第十九站：稽核日誌（audit log）

![audit]

Confluent Server 內建稽核：誰、用什麼身分、對哪個 topic 做了什麼、准還是拒，每一筆都是一個事件，寫進 Kafka 自己的 topic。預設是用 broker 自己的身分寫、全部塞同一個 topic。銀行要的是：用一個**專用的低權限帳號**寫、**敏感 topic 的事件分開放、留久一點**、排除平台自己的雜訊。這一站把這三件事做上去，密碼一樣進 Secret Protection。

| 誰 | 做什麼 |
|---|---|
| 小安 | 建寫入帳號與權限、改 controller／broker 的設定（加密、派送）、滾動重啟、製造允許與拒絕的事件來驗證 |
| 銀行稽核 | 之後用 OP menu 的 43／45，或自己的 SIEM 讀這兩個 topic |

## 19.1 專用的寫入帳號

@role 小安 | ops02 | cpadmin

`confluent-audit` 是 SCRAM 帳號，只能寫與管理 `confluent-audit-log-events` 開頭的 topic（prefix 同時涵蓋 `_sensitive`），不是 super user：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && BS=kb01.poc.lab:9094 && (umask 077; [ -s ~/secrets/confluent-audit.pass ] || openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/confluent-audit.pass) && P=$(cat ~/secrets/confluent-audit.pass) && kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties --alter --entity-type users --entity-name confluent-audit --add-config "SCRAM-SHA-512=[iterations=8192,password=$P]" >/dev/null && unset P && confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key >/dev/null 2>&1 && CID=$(curl -sk https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4) && for r in DeveloperWrite DeveloperManage; do confluent iam rbac role-binding create --principal User:confluent-audit --role $r --resource Topic:confluent-audit-log-events --prefix --kafka-cluster "$CID" >/dev/null 2>&1; done; confluent iam rbac role-binding list --principal User:confluent-audit --kafka-cluster "$CID" 2>/dev/null | tail -n +3
```

```out
  User:confluent-audit | DeveloperManage | Topic         | confluent-audit-log-events | PREFIXED
  User:confluent-audit | DeveloperWrite  | Topic         | confluent-audit-log-events | PREFIXED
```

## 19.2 設定片段：寫入者、路由、保留天數

@role 小安 | ops02 | cpadmin

接在 `common.tpl`（controller 與 broker 共用）後面。路由規則是一行 JSON：`payments.*` 的 produce／consume（允許與拒絕）和被拒絕的 describe 送到 `_sensitive`（留 365 天），其他送預設 topic（留 90 天），`kafka-internal`、`svc-c3` 的事件不記：

```bash
cd ~/conf && cp common.tpl common.tpl.plain.pre-audit && cat >> common.tpl <<'EOF'

############################# Audit log: dedicated low-privilege writer, sensitive topics routed separately #############################
confluent.security.event.logger.enable=true
confluent.security.event.logger.exporter.kafka.bootstrap.servers=kb01.poc.lab:9095,kb02.poc.lab:9095,kb03.poc.lab:9095,kb04.poc.lab:9095
confluent.security.event.logger.exporter.kafka.security.protocol=SASL_SSL
confluent.security.event.logger.exporter.kafka.sasl.mechanism=SCRAM-SHA-512
confluent.security.event.logger.exporter.kafka.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="confluent-audit" password="${AUDIT_PASSWORD}";
confluent.security.event.logger.exporter.kafka.ssl.truststore.type=PKCS12
confluent.security.event.logger.exporter.kafka.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.security.event.logger.exporter.kafka.ssl.truststore.password=${STORE_PASSWORD}
confluent.security.event.logger.exporter.kafka.topic.replicas=3
confluent.security.event.logger.exporter.kafka.topic.retention.ms=7776000000
confluent.security.event.router.config={"destinations":{"topics":{"confluent-audit-log-events":{"retention_ms":7776000000},"confluent-audit-log-events_sensitive":{"retention_ms":31536000000}}},"default_topics":{"allowed":"confluent-audit-log-events","denied":"confluent-audit-log-events"},"excluded_principals":["User:kafka-internal","User:svc-c3"],"routes":{"crn:///kafka=*/topic=payments.*":{"produce":{"allowed":"confluent-audit-log-events_sensitive","denied":"confluent-audit-log-events_sensitive"},"consume":{"allowed":"confluent-audit-log-events_sensitive","denied":"confluent-audit-log-events_sensitive"},"describe":{"allowed":"","denied":"confluent-audit-log-events_sensitive"}}}}
EOF
grep -c 'security.event' common.tpl
```

```out
11
```

重新產生 7 台的 `server.properties`（第 16 站的流程：明文渲染 → Secret Protection 加密，新增的兩個密碼欄位會被一起加密進同一份 `security.properties`）、派送、滾動重啟。REST Proxy 與 C3 不受影響：

```bash
cd ~/conf && export STORE_PASSWORD=$(cat ~/pki/store.pass) LDAP_BIND_PASSWORD=$(cat ~/secrets/ldap-bind.pass) AUDIT_PASSWORD=$(cat ~/secrets/confluent-audit.pass) && V='${HOST_FQDN} ${NODE_ID} ${RACK} ${STORE_PASSWORD} ${LDAP_BIND_PASSWORD} ${AUDIT_PASSWORD}' && for h in kc01:1:- kc02:2:- kc03:3:- kb01:101:rack-a kb02:102:rack-a kb03:103:rack-b kb04:104:rack-b; do IFS=: read -r n id rack <<<"$h"; export HOST_FQDN=$n.poc.lab NODE_ID=$id RACK=$rack; case $n in kc*) tpl=controller.tpl;; *) tpl=broker.tpl;; esac; (umask 077; { envsubst "$V" < $tpl; echo; envsubst "$V" < common.tpl; } > $n.server.properties); done; unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD; export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key); for f in *.server.properties; do keys=$(grep -E '^[^#].*(password|credentials|jaas.config)=' $f | cut -d= -f1 | paste -sd,); confluent secret file encrypt --config-file $f --local-secrets-file ~/secrets/security.properties --remote-secrets-file /etc/confluent/secrets/security.properties --config "$keys" >/dev/null && echo "$f: $(grep -c '\${securepass:' $f) encrypted, plaintext=$(grep -cE '^[^#].*(password|credentials)=[^$]' $f)"; done; unset CONFLUENT_SECURITY_MASTER_KEY; for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do scp -q $h.server.properties ~/secrets/security.properties $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo install -o root -g confluent -m 0640 /tmp/$h.server.properties /etc/confluent/kafka/server.properties && sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && rm -f /tmp/$h.server.properties /tmp/security.properties && printf '%s ' \$(hostname)"; done; echo
```

```out
kb01.server.properties: 22 encrypted, plaintext=0
（7 個檔；broker 22、controller 13）
kc01 kc02 kc03 kb01 kb02 kb03 kb04
```

做過 16.9 的話（AD 查詢密碼改由 Summon 注入）：剛才從範本重新產生的設定又把它加密回密文了，重啟前照 16.9 改回 `${env:LDAP_BIND_PASSWORD}`。沒做 16.9 的主機（`secrets.yml` 裡沒有這個變數）直接略過，不會有輸出：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do ssh $h.poc.lab "sudo grep -q '^LDAP_BIND_PASSWORD:' /etc/confluent/secrets.yml 2>/dev/null || exit 0; f=/etc/confluent/kafka/server.properties; sudo sed -i -e 's|^config.providers *=.*|config.providers = securepass,env|' -e '/^config.providers.env.class *=/d' -e 's|^ldap.java.naming.security.credentials *=.*|ldap.java.naming.security.credentials = \${env:LDAP_BIND_PASSWORD}|' \$f && echo 'config.providers.env.class = org.apache.kafka.common.config.provider.EnvVarConfigProvider' | sudo tee -a \$f >/dev/null && echo \"\$(hostname): \$(sudo grep '^ldap.java.naming.security.credentials' \$f)\""; done
```

```out
kc01: ldap.java.naming.security.credentials = ${env:LDAP_BIND_PASSWORD}
（做過 16.9 時 7 行；沒做時沒有輸出）
```

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done; sleep 20; export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list | grep audit
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
confluent-audit-log-events
confluent-audit-log-events_sensitive
```

## 19.3 製造事件、讀回來

@role 小安 | ops02 | cpadmin

alice（SystemAdmin）往 `payments.events` 寫一筆（允許、敏感 → `_sensitive`）；`app-orders` 想讀 `payments.events`（它只有 orders.* 的權限 → 拒絕、敏感 → `_sensitive`）；`app-orders` 讀自己的 `orders.events`（允許、不敏感 → 預設 topic）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && (umask 077; cat > ~/conf/client-alice.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="$(cat ~/secrets/ad-test-users.pass)";
ssl.truststore.type=PKCS12
ssl.truststore.location=/home/cpadmin/pki/certs/truststore.p12
ssl.truststore.password=$(cat ~/pki/store.pass)
EOF
) && echo "audit-test-$(date +%s)" | kafka-console-producer --bootstrap-server kb01.poc.lab:9096 --producer.config ~/conf/client-alice.properties --topic payments.events >/dev/null 2>&1 && echo "alice: produced to payments.events"; kafka-console-consumer --bootstrap-server kb01.poc.lab:9095 --consumer.config ~/conf/app-orders.properties --topic payments.events --group orders-sneak --max-messages 1 --timeout-ms 10000 2>&1 | grep -o 'TopicAuthorizationException\|not authorized' | head -1 | sed 's/^/app-orders on payments.events: /'; kafka-console-consumer --bootstrap-server kb01.poc.lab:9095 --consumer.config ~/conf/app-orders.properties --topic orders.events --group orders-audit-check --from-beginning --max-messages 1 --timeout-ms 15000 2>/dev/null | wc -l | sed 's/^/app-orders on orders.events: read /'
```

```out
alice: produced to payments.events
app-orders on payments.events: TopicAuthorizationException
app-orders on orders.events: read 1
```

等幾秒讓事件寫進去，再用 alice 讀兩個 audit topic，按「主體／方法／資源／准拒」統計（只列這幾個測試身分）：

```bash
sleep 10; export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && for t in confluent-audit-log-events_sensitive confluent-audit-log-events; do echo "== $t"; kafka-console-consumer --bootstrap-server kb01.poc.lab:9096 --consumer.config ~/conf/client-alice.properties --topic $t --from-beginning --timeout-ms 20000 2>/dev/null | python3 -c '
import sys, json, collections
c = collections.Counter(); tot = 0
for line in sys.stdin:
    try: e = json.loads(line)["data"]
    except Exception: continue
    tot += 1
    p = e.get("authenticationInfo", {}).get("principal", "?"); m = e.get("methodName", "?").split(".")[-1]
    a = e.get("authorizationInfo", {}); g = a.get("granted"); r = a.get("resourceName", "")
    if p in ("User:alice", "User:app-orders", "User:bob", "User:carol"): c[(p, m, r[:28], "ALLOWED" if g else "DENIED")] += 1
print("  total events:", tot)
for k, v in sorted(c.items()): print("  %-16s %-10s %-28s %-8s x%d" % (k[0], k[1], k[2], k[3], v))
'; done
```

```out
== confluent-audit-log-events_sensitive
  total events: 2
  User:alice       Produce    payments.events              ALLOWED  x1
  User:app-orders  Metadata   payments.events              DENIED   x1
== confluent-audit-log-events
  total events: 247
  User:alice       Authorize  __opmenu-host-ops            ALLOWED  x28
  User:alice       Authorize  kafka-cluster                ALLOWED  x26
  User:bob         Authorize  kafka-cluster                DENIED   x27
  User:carol       Authorize  __opmenu-host-ops            DENIED   x12
  （… 第 17 站 OP menu 問 MDS 留下的授權事件）
```

> 三件事值得看清楚：(1) 敏感 topic 的事件在 `_sensitive`：alice 的 produce（允許）和 app-orders 想讀時的 Metadata（describe 被拒）。(2) **一般 topic 的 produce／consume 不會被記**：app-orders 讀 orders.events 沒有出現在任何 topic，因為 Confluent 預設只記「管理類」與「授權類」事件（例如上面 MDS 的 Authorize，那是第 17 站 OP menu 問權限留下的），produce／consume 只在路由裡明確列出的 topic 才記。要記全部就把 `crn:///kafka=*/topic=*` 的 produce／consume 也寫進 routes，量會很大。(3) `kafka-internal`、`svc-c3` 完全不出現。OP menu 的 43（匯出）、45（查詢）讀的就是這兩個 topic。

## 19.4 要跟稽核單位說清楚的事

| 項目 | 說明 |
|---|---|
| 寫入者 | `confluent-audit`（SCRAM，只有 audit topic 的 Write／Manage），不是 super user；密碼在 Secret Protection 裡 |
| 保留 | 預設 topic 90 天、`_sensitive` 365 天，都是 topic 的 retention；要更久就外送 SIEM |
| 誰能讀 | 綁了 audit topic DeveloperRead 的群組（lab 是 SystemAdmin 直接讀）；稽核群組用 OP menu 43／45 匯出與查詢 |
| 量 | `kafka-internal`、`svc-c3` 已排除；只有路由列出的 topic 才記 produce／consume，要擴大範圍前先估磁碟 |
| 改規則 | 改 `common.tpl` 的 router JSON → 重新加密派送 → 滾動重啟（和這一站一樣） |

# 20. 第二十站：驗收與收尾

![acceptance]

每一站結尾都有自己的檢查，但交付前要有一份**一次跑完、結果能附在驗收文件裡**的清單。四組：平台健康、安全（正向與反向都測）、應用程式端、維運。最後是收尾：安裝期間留在操作機與主機上的東西，哪些要留、哪些要收。

## 20.1 平台健康

@role 小安 | ops02 | cpadmin

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && ok=0; all=0; chk() { local name="$1"; shift; all=$((all+1)); if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$name"; ok=$((ok+1)); else printf 'FAIL %s\n' "$name"; fi; }; chk "controller quorum 有 leader" bash -c 'kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status | grep -q "LeaderId: *[0-9]"'; for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do chk "$h confluent-server active" ssh $h.poc.lab 'systemctl is-active -q confluent-server'; done; for h in kb01 kb02 kb03 kb04; do chk "$h MDS 8090 回 200" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) = 200 ]"; done; chk "沒有 under-replicated partition" bash -c '[ "$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions | grep -c Partition:)" = 0 ]'; chk "沒有 offline partition" bash -c '[ "$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --unavailable-partitions | grep -c Partition:)" = 0 ]'; chk "Self-Balancing 啟用" bash -c 'kafka-rebalance-cluster --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --status 2>/dev/null | grep -q "Balancer status: ENABLED"'; chk "REST Proxy 經 LB 回 200（mTLS）" bash -c "[ \$(curl -s --cacert $CA --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters) = 200 ]"; chk "Control Center 9021 回 200" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) = 200 ]"; chk "C3 的 Prometheus 有 broker 指標" bash -c "curl -s --cacert $CA --cert ~/pki/certs/cp-server.crt --key ~/pki/keys/cp-server.key https://c3-01.poc.lab:9090/api/v1/label/__name__/values | grep -q confluent_kafka_server"; for h in kc01 kb01 rest01; do chk "$h JMX exporter 7071 要帳密" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://$h.poc.lab:7071/metrics) = 401 ]"; done; echo "健康：$ok / $all 項通過"
```

```out
ok   controller quorum 有 leader
ok   kc01 confluent-server active
（…）
ok   rest01 JMX exporter 7071 要帳密
健康：21 / 21 項通過
```

## 20.2 安全：正向與反向

@role 小安 | ops02 | cpadmin

每一條規則都要有「該過的過、該擋的擋」：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && P=$(cat ~/secrets/ad-test-users.pass) && ok=0; all=0; chk() { local name="$1"; shift; all=$((all+1)); if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$name"; ok=$((ok+1)); else printf 'FAIL %s\n' "$name"; fi; }; mds() { curl -s --cacert $CA -u "$1:$2" -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate; }; export -f mds; export CA; chk "AD 帳密正確 → MDS 給 token" bash -c "[ \$(mds alice '$P') = 200 ]"; chk "AD 密碼錯 → 401" bash -c "[ \$(mds alice wrong-password) = 401 ]"; chk "不存在的帳號 → 401" bash -c "[ \$(mds nobody '$P') = 401 ]"; chk "carol 在自己 prefix 以外建 topic 被拒" bash -c "kafka-topics --bootstrap-server kb01.poc.lab:9096 --command-config <(sed 's/username=\"alice\"/username=\"carol\"/' ~/conf/client-alice.properties) --create --topic payments.carol-test --partitions 1 --replication-factor 3 2>&1 | grep -q 'TopicAuthorizationException'"; chk "app-orders 讀 payments.events 被拒" bash -c "kafka-console-consumer --bootstrap-server kb01.poc.lab:9095 --consumer.config ~/conf/app-orders.properties --topic payments.events --max-messages 1 --timeout-ms 8000 2>&1 | grep -q TopicAuthorizationException"; chk "REST Proxy 不帶憑證 → 連線被拒" bash -c "! curl -s --cacert $CA --max-time 10 https://rest.poc.lab:8082/v3/clusters -o /dev/null"; chk "REST Proxy 帶非 app 憑證（svc-ops）→ 401" bash -c "[ \$(curl -s --cacert $CA --cert ~/pki/certs/svc-ops.crt --key ~/pki/keys/svc-ops.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters) = 401 ]"; chk "CLIENT 9095 不帶 SASL → 失敗" bash -c "! kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config <(printf 'security.protocol=SSL\nssl.truststore.type=PKCS12\nssl.truststore.location=/home/cpadmin/pki/certs/truststore.p12\nssl.truststore.password=%s\n' \"\$(cat ~/pki/store.pass)\") --list 2>/dev/null"; chk "JMX exporter 匿名 → 401" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://kb01.poc.lab:7071/metrics) = 401 ]"; chk "用無關的 CA 驗 MDS 憑證會被拒（鏈驗證生效）" bash -c "! curl -s --max-time 10 --cacert <(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null -subj /CN=junk 2>/dev/null) https://kb01.poc.lab:8090/v1/metadata/id -o /dev/null"; for h in kb01 rest01 c3-01; do chk "$h properties 沒有明文密碼" ssh $h.poc.lab 'f=$(ls /etc/confluent/kafka/server.properties /etc/confluent/kafka-rest/kafka-rest.properties /etc/confluent/control-center/control-center.properties 2>/dev/null | head -1); [ "$(sudo grep -cE "^[^#].*(password|credentials|jaas.config)=[^$]" $f)" = 0 ]'; done; chk "kb01 磁碟上的 master key：做了 16.8 是 0 個檔，沒做是 1 個（service.env）" ssh kb01.poc.lab 'n=$(sudo grep -rl CONFLUENT_SECURITY_MASTER_KEY= /etc/confluent /etc/systemd/system 2>/dev/null | wc -l); if sudo grep -q CONFLUENT_SECURITY_MASTER_KEY /etc/confluent/secrets.yml 2>/dev/null; then [ "$n" = 0 ]; else [ "$n" = 1 ]; fi'; chk "各主機 /etc/confluent/ssl 是 0750" ssh kb01.poc.lab '[ "$(sudo stat -c %a /etc/confluent/ssl)" = 750 ]'; unset P; echo "安全：$ok / $all 項通過"
```

```out
ok   AD 帳密正確 → MDS 給 token
ok   AD 密碼錯 → 401
（…）
安全：15 / 15 項通過
```

> carol 的群組在第 17 站拿到 `orders.` prefix 的 DeveloperManage，所以她在自己的 prefix 裡是能建 topic 的；反向測試要用她沒有權限的 prefix。

## 20.3 應用程式端

@role 小安（扮演兩個應用程式） | ops02 | cpadmin

直連的 app-orders（SCRAM）寫一筆、讀回來；經 REST Proxy 的 app-legacy-billing（mTLS）寫一筆，再由 alice 讀出來確認真的進了 topic：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && CID=$(curl -s --cacert $CA https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4) && M="acceptance-$(date +%s)" && echo "$M" | kafka-console-producer --bootstrap-server kb01.poc.lab:9095 --producer.config ~/conf/app-orders.properties --topic orders.events >/dev/null 2>&1 && echo "app-orders SCRAM 直連寫入：ok"; kafka-console-consumer --bootstrap-server kb01.poc.lab:9095 --consumer.config ~/conf/app-orders.properties --topic orders.events --group orders-acceptance --from-beginning --timeout-ms 15000 2>/dev/null | grep -c "$M" | sed 's/^/app-orders 讀回自己寫的：/'; code=$(curl -s --cacert $CA --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "{\"value\":{\"type\":\"JSON\",\"data\":\"$M-rest\"}}" "https://rest.poc.lab:8082/v3/clusters/$CID/topics/billing.events/records"); echo "app-legacy-billing 經 LB + REST Proxy（mTLS）寫入：HTTP $code"; kafka-console-consumer --bootstrap-server kb01.poc.lab:9096 --consumer.config ~/conf/client-alice.properties --topic billing.events --group billing-acceptance --from-beginning --timeout-ms 15000 2>/dev/null | grep -c "$M-rest" | sed 's/^/alice 在 billing.events 看到那筆：/'
```

```out
app-orders SCRAM 直連寫入：ok
app-orders 讀回自己寫的：1
app-legacy-billing 經 LB + REST Proxy（mTLS）寫入：HTTP 200
alice 在 billing.events 看到那筆：1
```

## 20.4 維運：選單重啟、冷開機

@role 小安（代打 bob） | ops02 | cpadmin

維運人員用選單重啟一台 broker（第 17 站的路徑：bob → MDS 確認權限 → cpadmin ssh → sudo 只開的 restart），叢集不中斷：

```bash
P=$(cat ~/secrets/ad-test-users.pass); sudo env OPMENU_USER=bob OPMENU_PASS="$P" OPMENU_YES=1 JAVA_HOME=/opt/java/current HOME=/home/op01 runuser -p -u op01 -- /opt/opmenu/opmenu.sh --run 21 kb03.poc.lab:confluent-server 2>&1 | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g' | tail -1; unset P; for i in $(seq 1 24); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://kb03.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "kb03 MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://kb03.poc.lab:8090/v1/metadata/id) after ~$((i*5))s; under-replicated=$(JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:)"
```

```out
已重啟 kb03.poc.lab 的 confluent-server
kb03 MDS=200 after ~20s; under-replicated=0
```

@role Lab 管理員（扮演機房停電） | Windows 終端 | 本機

冷開機：全部主機同時關、同時開，看平台自己回來的順序與時間。重點是 broker 依賴保管庫（Summon 向 Conjur 取 master key），Conjur 比 broker 慢起來時 broker 會先失敗、靠 systemd 的 `Restart=on-failure` 每 10 秒重試；C3 比 MDS 先起來會等。lab 一併把 Conjur 關掉再開，就是最壞情況：

```bash
cd ~/kafka-lab && MSYS_NO_PATHCONV=1 docker compose -f compose.yml -f conjur.yml stop 2>&1 | grep -c Stopped && t0=$(date +%s) && MSYS_NO_PATHCONV=1 docker compose -f compose.yml -f conjur.yml start 2>&1 | grep -c Started && probe() { docker exec lab-ops02-1 bash -c "curl -sk -o /dev/null -w '%{http_code}' $1"; }; for i in $(seq 1 60); do a=0; for h in kb01 kb02 kb03 kb04; do [ "$(probe https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && a=$((a+1)); done; [ $a = 4 ] && break; sleep 10; done; echo "4 台 broker 的 MDS 都回 200：$(( $(date +%s) - t0 ))s"; for i in $(seq 1 60); do [ "$(probe https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 10; done; echo "C3 回 200：$(( $(date +%s) - t0 ))s"; echo "REST 經 LB：$(docker exec lab-ops02-1 bash -c "curl -s --cacert /etc/pki/ca-trust/source/anchors/bank-root.pem --cert /home/cpadmin/pki/certs/app-legacy-billing.crt --key /home/cpadmin/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters")"; docker exec lab-kb01-1 bash -c 'echo "kb01 confluent-server 重試次數：$(journalctl -u confluent-server --since "-10min" --no-pager | grep -c "Scheduled restart job")"'
```

```out
17
17
4 台 broker 的 MDS 都回 200：90s
C3 回 200：154s
REST 經 LB：200
kb01 confluent-server 重試次數：2
```

> 重試 2 次就是 broker 比 Conjur 先起來、Summon 取不到 master key，systemd 每 10 秒再試，Conjur 起來後就過了（做過 16.8 才會這樣；master key 落地 `service.env` 時開機不依賴保管庫，重試次數是 0）。C3 在第 13 站的 drop-in 加了「等 MDS」之後 154 秒回來；沒加之前 lab 實測是 12 分鐘（C3 比 MDS 先起來會卡住不開 9021）。

## 20.5 收尾：安裝完成後要收的東西

@role 小安 | ops02 | cpadmin

| 留在操作機 | 收掉或交出去 |
|---|---|
| `~/conf/`（範本與產出的設定，之後改設定都從這裡）、`~/pki/`（憑證、CSR、keystore 密碼）、`~/secrets/`（0600）、`~/monitoring/` | `~/landing/`、`~/repo/` 可以刪（套件已上架；要回滾用套件庫裡的舊版） |
| `~/.ssh/id_ed25519`（lab）：正式環境改由 CyberArk 保管，操作機不留 | `/tmp/` 裡安裝期間的暫存檔 |
| | `~/pki/keys/svc-ops.key`：安裝完成後建議移到離線保管，需要時再取回（它是 super user）；憑證輪替（第 21 章）、升級（第 22 章）前要先取回 |
| | 各主機 cpadmin 的全權 sudo：改回只留 `cpadmin-ops` 窄規則（lab 留著，後面章節還要用） |

```bash
rm -rf /tmp/jmx-* /tmp/*.properties 2>/dev/null; du -sh ~/landing ~/repo 2>/dev/null | tr '\n' ' '; echo; for h in kc01 kb01 rest01 c3-01; do ssh $h.poc.lab 'printf "%s: /tmp 殘留 %s 個；sudoers %s\n" $(hostname) $(ls /tmp | grep -cv "^hsperfdata\|^systemd-private\|^lib.*\.so\|^com_\|^\.") "$(sudo ls /etc/sudoers.d | tr "\n" ",")"'; done; find ~ -maxdepth 2 -type f \( -name '*.key' -o -name '*.pass' -o -name 'master.key' \) ! -perm 600 2>/dev/null | sed 's/^/權限不是 0600：/'; echo "收尾檢查完成"
```

```out
3.1G	/home/cpadmin/landing 2.9G	/home/cpadmin/repo
kc01: /tmp 殘留 0 個；sudoers cpadmin,cpadmin-ops,
（4 行；JVM 自己的 lib*.so、hsperfdata 不算）
收尾檢查完成
```

> 正式環境交付時再做三件 lab 不做的事：OS 團隊把各主機 `/etc/sudoers.d/cpadmin`（全權）移除；把 `svc-ops.key` 移到離線保管；`~/landing`、`~/repo` 依銀行留存政策處理（套件庫才是正本）。


# 21. 第二十一站：憑證輪替

![certrotate]

第 9 站簽的憑證效期一年，到期前一定要換。這一站做兩件事：每年都會遇到的 **leaf 換發**（同一個銀行 CA 重簽），以及幾年一次、銀行決定的 **換 CA**（三階段：先加新根 → 換 leaf → 移除舊根）。MDS token 金鑰不是銀行 CA 簽的、沒有到期日，不在這一站（只在外洩時才換）。

| 情境 | 多久一次 | 會不會斷線 |
|---|---|---|
| leaf 換發 | 每年，到期前一個月內 | 不會：truststore 只信根憑證，新舊 leaf 在滾動期間都被信任 |
| 換 CA | 銀行決定（幾年一次） | 不會：三階段的每一段，所有元件都同時信任新舊兩個根 |

做法的原則：
- **每次換發都產生新私鑰**，不重用舊的 CSR。
- 檔名、路徑、keystore 密碼都和原本一樣，所以 properties 一個字都不用改（Secret Protection 的密文也不用重算）。
- 新的東西先放在 `~/pki/next/`，派送完、驗證過，才換成 `~/pki/` 的正本；舊的留在 `~/pki/old-<日期>/`。

## 21.0 銀行說要換憑證時，先判斷是哪一種

銀行說「要換根」或「要換中繼」時，先問清楚三件事：**換的是哪一層**、**那一層的私鑰有沒有換**、**舊的什麼時候到期**。驗證憑證時看的是「上一層的名稱和公鑰」，不是上一層那張憑證本身，所以私鑰沒換的那一層，下面的憑證都還驗得過；工作量差很多：

| 根 | 中繼 | 我方的 leaf（server／client） | p12 裡夾帶的中繼（憑證鏈） | 信任清單 | 走哪一節 |
|---|---|---|---|---|---|
| 不動 | 不動 | 到期前換發 | 不動 | 不動 | 21.2 |
| 同私鑰續簽 | 不動 | 不動 | 不動 | 加入新根，舊的到期後再移除 | 只做 21.3 的信任清單那幾步（加入、移除） |
| 不動 | 同私鑰續簽 | 不動 | **換成新中繼** | 不動 | 重包每個 p12、滾動重啟（不用 CSR） |
| 不動 | 換私鑰 | **重簽** | 換成新中繼 | 不動 | 21.2（銀行用新中繼簽） |
| 換私鑰 | 同私鑰，由新根重簽 | 不動 | **換成新中繼** | **三階段** | 21.3，但階段二只要重包 p12 |
| 換私鑰 | 換私鑰 | **重簽** | 換成新中繼 | **三階段** | 21.3（本章演練的就是這種） |

我方的信任清單只放根憑證、不放中繼，所以只要根沒換私鑰，信任清單都不用動；換鏈的過程中，出示舊鏈和新鏈的主機可以並存。只有把中繼本身放進信任清單的應用程式，才要新舊中繼並存。

比對「名稱與私鑰有沒有換」：拿銀行給的新舊兩張（根或中繼）各算一次公鑰雜湊與名稱，名稱相同、雜湊相同就是續簽：

```
for f in old-ca.pem new-ca.pem; do echo "$f: $(openssl x509 -in $f -noout -subject -nameopt compat | sed 's/subject=//')  key=$(openssl x509 -in $f -noout -pubkey | sha256sum | cut -c1-12)  到期 $(openssl x509 -in $f -noout -enddate | cut -d= -f2)"; done
```

> 實測（2026-10-24，openssl，用 lab 的模擬 CA）：同私鑰續簽的根、同私鑰續簽的中繼、兩者同時，舊 leaf 全部驗得過；根換私鑰而中繼沿用私鑰、由新根重簽時，舊 leaf 配新中繼驗得過新根，但**還沒換鏈的主機（舊 leaf 配舊中繼）在只信新根之後就驗不過**，所以三階段的「拿掉舊根」一定排在每個端點都換好鏈之後。Java 的驗證原理相同，沒有另外實測。

## 21.1 現在用的是哪一張

@role 小安 | ops02 | cpadmin

每張憑證的序號、剩幾天，以及各服務**實際出示**的是哪一張（換完之後用同一條指令確認每個端點都換到了）：

```bash
cd ~/pki && for n in $(awk '{print $1}' requests.txt); do printf '%-19s serial=%s days=%s\n' $n "$(openssl x509 -in certs/$n.crt -noout -serial | cut -d= -f2 | tail -c 9)" $(( ($(date -d "$(openssl x509 -in certs/$n.crt -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )); done; echo "-- 各端點出示的憑證（序號末 8 碼）"; for ep in kc01.poc.lab:9093 kb01.poc.lab:9092 kb01.poc.lab:9095 kb01.poc.lab:8090 kb01.poc.lab:7071 rest01.poc.lab:8082 c3-01.poc.lab:9021 c3-01.poc.lab:9090; do printf '%-22s %s\n' $ep "$(openssl s_client -connect $ep -servername ${ep%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial -subject -nameopt sep_comma_plus,sname 2>/dev/null | sed 's/serial=//; s/subject=.*CN=\([^,]*\).*/\1/' | paste -sd' ' | sed 's/^\(.*\)\(........\) \(.*\)$/\2 \3/')"; done
```

```out
kafka-internal      serial=F343BC55 days=364
cp-server           serial=F343BC54 days=364
（7 行）
-- 各端點出示的憑證（序號末 8 碼）
kc01.poc.lab:9093      F343BC55 kafka-internal
kb01.poc.lab:9092      F343BC55 kafka-internal
kb01.poc.lab:9095      F343BC54 cp-server
（8 行：controller 與 broker 之間是 kafka-internal，其他對外的都是 cp-server）
```

> 要求 client 憑證的埠（9092、9093、9090）沒有帶憑證也看得到伺服器出示的那張，握手才會在之後失敗；這裡只看伺服器那一張。

## 21.2 換發 leaf（同一個 CA）

### 21.2.1 新私鑰與 CSR

@role 小安 | ops02 | cpadmin

照第 9 站的 `requests.txt`（名稱、EKU、SAN 不變），每張產生新私鑰與 CSR，放 `~/pki/next/`：

```bash
install -d -m 0700 ~/pki/next ~/pki/next/keys ~/pki/next/requests ~/pki/next/incoming ~/pki/next/certs && cd ~/pki && while read -r name eku san; do (umask 077; openssl genrsa -out next/keys/$name.key 2048 2>/dev/null); ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku"); [ "$san" != "-" ] && ext+=(-addext "subjectAltName=$(echo "$san" | tr ',' '\n' | sed 's/^/DNS:/' | paste -sd, -)"); openssl req -new -key next/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" "${ext[@]}" -out next/requests/$name.csr && echo "$name: csr ok"; done < requests.txt
```

```out
kafka-internal: csr ok
（7 行）
```

### 21.2.2 銀行 CA 簽發

@role 銀行 CA 窗口 | Windows 終端 | 本機

和 9.2 一樣，只是從 `next/` 拿、放回 `next/`：

```bash
cd ~/kafka-lab && rm -rf ca/exchange/next && mkdir -p ca/exchange/next/signed && docker cp lab-ops02-1:/home/cpadmin/pki/next/requests "$(cygpath -m "$PWD/ca/exchange/next/")" && for f in ca/exchange/next/requests/*.csr; do n=$(basename $f .csr); bash ca/sign.sh "$f" "ca/exchange/next/signed/$n.crt"; done && for f in ca/exchange/next/signed/*.crt; do docker cp "$(cygpath -m "$f")" lab-ops02-1:/home/cpadmin/pki/next/incoming/; done && docker exec lab-ops02-1 bash -c 'chown cpadmin:cpadmin /home/cpadmin/pki/next/incoming/*; ls /home/cpadmin/pki/next/incoming | wc -l'
```

```out
signed app-legacy-billing.csr -> app-legacy-billing.crt  (CN = app-legacy-billing, O = PoC Bank, C = TW; EKU clientAuth)
（7 行）
7
```

### 21.2.3 檢查、做成 keystore

@role 小安 | ops02 | cpadmin

拆 leaf 與中繼、五項檢查加憑證鏈（和 9.3 同一套），多印一欄簽發者，換 CA 時用得到：

```bash
cd ~/pki/next && for n in $(awk '{print $1}' ../requests.txt); do awk -v n=$n 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("incoming/" n ".part" c)}' incoming/$n.crt; mv incoming/$n.part1 incoming/$n.leaf.pem; cat incoming/$n.part[2-9] > incoming/$n.issuers.pem 2>/dev/null; rm -f incoming/$n.part*; done; while read -r name eku san; do leaf=incoming/$name.leaf.pem; k1=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16); k2=$(openssl pkey -in keys/$name.key -pubout 2>/dev/null | sha256sum | cut -c1-16); cn=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); have_san=$(openssl x509 -in $leaf -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,); want_san=$([ "$san" = "-" ] && echo "" || echo "$san" | tr ',' '\n' | sort | paste -sd,); have_eku=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' '); days=$(( ($(date -d "$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )); chain=$(openssl verify -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem -untrusted incoming/$name.issuers.pem $leaf 2>&1 | grep -c ": OK"); issuer=$(openssl x509 -in $leaf -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); printf '%-19s key=%s cn=%s san=%s days=%s chain=%s issuer=%s\n' $name $([ $k1 = $k2 ] && echo ok || echo MISMATCH) $([ "$cn" = "$name" ] && echo ok || echo "$cn") $([ "$have_san" = "$want_san" ] && echo ok || echo DIFF) $days $([ $chain = 1 ] && echo ok || echo FAIL) "$issuer"; done < ../requests.txt
```

```out
kafka-internal      key=ok cn=ok san=ok days=364 chain=ok issuer=PoC Bank Issuing CA 01
（7 行，全部 ok）
```

做成 p12（**同一個 keystore 密碼**，所以 properties 不用改）：

```bash
cd ~/pki/next && for n in $(awk '{print $1}' ../requests.txt); do cat incoming/$n.leaf.pem incoming/$n.issuers.pem > certs/$n.crt; openssl pkcs12 -export -name $n -inkey keys/$n.key -in certs/$n.crt -out certs/$n.p12 -passout file:../store.pass && chmod 0600 certs/$n.p12; done; ls certs | wc -l; for n in kafka-internal cp-server; do echo "$n: old=$(openssl x509 -in ../certs/$n.crt -noout -serial | tail -c 9) new=$(openssl x509 -in certs/$n.crt -noout -serial | tail -c 9)"; done
```

```out
14
kafka-internal: old=F343BC55 new=F343BC5D
cp-server: old=F343BC54 new=F343BC5C
```

### 21.2.4 派送、滾動重啟

@role 小安 | ops02 | cpadmin

| 主機 | 換哪些檔 | 重啟 |
|---|---|---|
| controller | kafka-internal.p12 | confluent-server |
| broker | kafka-internal.p12、cp-server.p12 | confluent-server（JMX exporter 一起） |
| REST Proxy | cp-server.p12、svc-rest.p12 | confluent-kafka-rest |
| C3 | cp-server.p12、cp-server.crt／.key、svc-c3.p12 | prometheus、alertmanager、confluent-control-center |

一台一台：放檔 → 重啟 → 等健康 → 確認那台出示的是新序號，才做下一台：

```bash
cd ~/pki/next && NEW_INT=$(openssl x509 -in certs/kafka-internal.crt -noout -serial | cut -d= -f2) NEW_SRV=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2) && served() { openssl s_client -connect $1 -servername ${1%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; } && for h in kc01 kc02 kc03; do scp -q certs/kafka-internal.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/kafka-internal.p12 /etc/confluent/ssl/ && rm -f /tmp/kafka-internal.p12 && sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done'; for i in $(seq 1 30); do [ "$(served $h.poc.lab:9093)" = $NEW_INT ] && break; sleep 2; done; echo "$h $(ssh $h.poc.lab systemctl is-active confluent-server) 9093=$([ "$(served $h.poc.lab:9093)" = $NEW_INT ] && echo new || echo OLD)"; done; for h in kb01 kb02 kb03 kb04; do scp -q certs/kafka-internal.p12 certs/cp-server.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'for f in kafka-internal.p12 cp-server.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12; sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) 9092=$([ "$(served $h.poc.lab:9092)" = $NEW_INT ] && echo new || echo OLD) 9095=$([ "$(served $h.poc.lab:9095)" = $NEW_SRV ] && echo new || echo OLD)"; done
```

```out
kc01 active 9093=new
（3 行）
kb01 MDS=200 9092=new 9095=new
（4 行）
```

> 陷阱：controller 的 `systemctl is-active` 變成 active 之後，9093 還要幾秒才開始聽。這時去看出示的憑證會拿到空的，看起來像「還是舊的」。所以上面是等到它出示新序號才往下。

REST Proxy 與 C3（REST 的健康檢查用應用程式的**舊**憑證，證明舊 leaf 在換發期間仍然有效）：

```bash
cd ~/pki/next && NEW_SRV=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2) && served() { openssl s_client -connect $1 -servername ${1%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; } && for h in rest01 rest02; do scp -q certs/cp-server.p12 certs/svc-rest.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'for f in cp-server.p12 svc-rest.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12; sudo systemctl restart confluent-kafka-rest'; for i in $(seq 1 30); do [ "$(curl -s --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)" = 200 ] && break; sleep 5; done; echo "$h REST=$(curl -s --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters) 8082=$([ "$(served $h.poc.lab:8082)" = $NEW_SRV ] && echo new || echo OLD)"; done; scp -q certs/cp-server.p12 certs/cp-server.crt keys/cp-server.key certs/svc-c3.p12 c3-01.poc.lab:/tmp/ && ssh c3-01.poc.lab 'for f in cp-server.p12 cp-server.crt cp-server.key svc-c3.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/cp-server.* /tmp/svc-c3.p12; for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) 9021=$([ "$(served c3-01.poc.lab:9021)" = $NEW_SRV ] && echo new || echo OLD) 9090=$([ "$(served c3-01.poc.lab:9090)" = $NEW_SRV ] && echo new || echo OLD)"
```

```out
rest01 REST=200 8082=new
rest02 REST=200 8082=new
c3-01 UI=200 9021=new 9090=new
```

### 21.2.5 換成正本、交出去的那幾張

@role 小安 | ops02 | cpadmin

舊的整份留到 `~/pki/old-<日期時間>/`，新的放回正本位置。操作機自己用的 `svc-ops`、`kafka-internal`（管理 client、quorum 查詢）換成新的之後馬上試一次；緊急身分 `opmenu-breakglass` 要更新保管庫裡那份；`app-legacy-billing` 是應用程式的憑證，**交給應用程式團隊在他們的時段換**（舊的到期前都還有效）：

```bash
cd ~/pki && OLD=old-$(date +%Y%m%d-%H%M) && install -d -m 0700 $OLD/keys $OLD/certs && for n in $(awk '{print $1}' requests.txt); do mv keys/$n.key $OLD/keys/; mv certs/$n.crt certs/$n.p12 $OLD/certs/; install -m 0600 next/keys/$n.key keys/; install -m 0644 next/certs/$n.crt certs/; install -m 0600 next/certs/$n.p12 certs/; done && rm -rf next && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && echo "svc-ops 管理 client：$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list 2>/dev/null | wc -l) 個 topic" && echo "kafka-internal 查 quorum：$(kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status 2>/dev/null | grep -o 'LeaderId: *[0-9]*')" && CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && T=$(curl -sS --cacert $CA -X POST --data-binary @$HOME/secrets/conjur-ops.key https://conjur.poc.lab/authn/poc/ops%40kafka/authenticate | base64 -w0) && cat keys/opmenu-breakglass.key certs/opmenu-breakglass.crt | curl -sS --cacert $CA -H "Authorization: Token token=\"$T\"" -X POST --data-binary @- https://conjur.poc.lab/secrets/poc/variable/kafka%2Fbreakglass%2Fpem && unset T && echo "breakglass：保管庫已更新" && echo "新的 app-legacy-billing（交給應用程式團隊）：REST=$(curl -s --cert certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)；舊的（還在效期內）：REST=$(curl -s --cert $OLD/certs/app-legacy-billing.crt --key $OLD/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)"
```

```out
svc-ops 管理 client：14 個 topic
kafka-internal 查 quorum：LeaderId: 1
breakglass：保管庫已更新
新的 app-legacy-billing（交給應用程式團隊）：REST=200；舊的（還在效期內）：REST=200
```

> 沒有 CCP 的銀行：breakglass 那一步改成把新的 PEM 交給 Secrets 團隊放進 PVWA（取代舊的那個 object）。

最後用 21.1 的指令再看一次：每個端點的序號都要是新的。

## 21.3 換 CA（三階段）

> 走第 15 章（Conjur provider）的環境還多一份信任清單：各台 **JDK 的 `cacerts`**（15.3 匯入的銀行根，provider 連 Conjur 用）。階段一要把新根也匯進去（另一個 alias），階段三刪掉舊根的 alias。走第 16 章的不受影響（本章的 lab 是第 16 章路徑，這一條沒有實測）。

銀行換根憑證（或換簽發 CA）時，不能一次全換：只要有一台還不信新的根，它就會拒絕新憑證。三個階段，每段結束時所有元件都同時信任新舊兩個根：

| 階段 | 誰做 | 做什麼 | 之後的狀態 |
|---|---|---|---|
| 一、加 | 銀行 OS 團隊＋小安 | 信任清單加入新根（OS 的 `bank-root.pem` 變成兩張根的 bundle、truststore 多一個 alias、C3 的 ca.pem） | 新舊都信；憑證還是舊 CA 簽的 |
| 二、換 | 銀行 CA＋小安 | 銀行用新 CA 重簽自己的伺服器（AD、套件庫、保管庫）；小安照 21.2 換發全部 leaf，改由新 CA 簽 | 新舊都信；憑證都是新 CA 簽的 |
| 三、退 | 銀行 OS 團隊＋小安 | 信任清單拿掉舊根 | 只信新的；舊 CA 簽的一律被拒 |

### 21.3.1 銀行建新 CA（lab 模擬）

@role 銀行 CA 窗口 | Windows 終端 | 本機

和 0.5.5 一樣的做法，名字換成 G2，放在 `ca/g2/`；簽發腳本複製一份（它用自己所在目錄的簽發 CA）：

```bash
cd ~/kafka-lab/ca && mkdir -p g2 && cd g2 && openssl genrsa -out root.key 4096 2>/dev/null && openssl req -x509 -new -key root.key -sha256 -days 7300 -out root.crt -subj "/CN=PoC Bank Root CA G2/O=PoC Bank/C=TW" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" && openssl genrsa -out issuing.key 4096 2>/dev/null && openssl req -new -key issuing.key -sha256 -subj "/CN=PoC Bank Issuing CA G2/O=PoC Bank/C=TW" -out issuing.csr && printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' > issuing.ext && openssl x509 -req -in issuing.csr -CA root.crt -CAkey root.key -CAcreateserial -days 3650 -sha256 -extfile issuing.ext -out issuing.crt 2>/dev/null && rm -f issuing.csr issuing.ext && cp ../sign.sh sign.sh && openssl verify -CAfile root.crt issuing.crt && openssl x509 -in root.crt -noout -subject -fingerprint -sha256
```

```out
issuing.crt: OK
subject=CN = PoC Bank Root CA G2, O = PoC Bank, C = TW
sha256 Fingerprint=…
```

### 21.3.2 階段一：信任清單加入新根

@role 銀行 OS 團隊 | Windows 終端 | 本機

每台主機（含操作機）的 `bank-root.pem` 換成「舊根＋新根」兩張的 bundle。檔名不變，所以所有指向它的設定（curl、Summon 的 `cert_file`、操作機上的檢查）都不用改：

```bash
cd ~/kafka-lab/ca && cat root.crt g2/root.crt > bundle-g1-g2.pem && for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker cp "$(cygpath -m "$PWD/bundle-g1-g2.pem")" lab-$h-1:/root/bank-root.pem && docker exec lab-$h-1 bash -c 'install -m 0644 /root/bank-root.pem /etc/pki/ca-trust/source/anchors/bank-root.pem && rm -f /root/bank-root.pem && update-ca-trust && printf "%s:%s " $(hostname) $(grep -c "BEGIN CERT" /etc/pki/ca-trust/source/anchors/bank-root.pem)'; done; echo
```

```out
ops02:2 kc01:2 kc02:2 kc03:2 kb01:2 kb02:2 kb03:2 kb04:2 rest01:2 rest02:2 c3-01:2
```

@role 小安 | ops02 | cpadmin

先寫一支滾動重啟的小腳本，三個階段都會用（controller → broker → REST → C3，一台健康了才做下一台）：

```bash
cat > ~/conf/rolling-restart.sh <<'EOF'
#!/usr/bin/env bash
# 依序滾動重啟：controller → broker → REST Proxy → C3；一台健康了才做下一台
APP_CERT=(--cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key)
for h in kc01 kc02 kc03; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'
  for i in $(seq 1 30); do openssl s_client -connect $h.poc.lab:9093 </dev/null >/dev/null 2>&1 && break; sleep 2; done
  echo "$h $(ssh $h.poc.lab systemctl is-active confluent-server)"
done
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'
  for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done
  echo "$h MDS=$(curl -s -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done
for h in rest01 rest02; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'
  for i in $(seq 1 30); do [ "$(curl -s "${APP_CERT[@]}" -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)" = 200 ] && break; sleep 5; done
  echo "$h REST=$(curl -s "${APP_CERT[@]}" -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)"
done
ssh c3-01.poc.lab 'for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done'
for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done
echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"
EOF
chmod 0700 ~/conf/rolling-restart.sh && echo rolling-restart.sh ok
```

我方的信任清單：truststore 加一個 alias `bank-root-g2`；C3 的 Prometheus／Alertmanager 用的 `ca.pem`、OP menu 的兩份也換成 bundle。派送、滾動重啟：

```bash
cd ~/pki/certs && cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem && csplit -s -z -f /tmp/root- bank-root.pem '/BEGIN CERT/' '{*}' && keytool -importcert -noprompt -alias bank-root-g2 -file /tmp/root-01 -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass >/dev/null 2>&1; rm -f /tmp/root-*; echo "truststore：$(keytool -list -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | paste -sd' ')" && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q truststore.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/ && rm -f /tmp/truststore.p12'; done && scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem && ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem && rm -f /tmp/ca.pem' && sudo install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12 && sudo install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem && bash ~/conf/rolling-restart.sh
```

```out
truststore：bank-root bank-root-g2
kc01 active
（3 行）
kb01 MDS=200
（4 行）
rest01 REST=200
rest02 REST=200
c3-01 UI=200
```

> 行內 Prometheus 抓 JMX exporter 用的 `ca.pem`（第 18.4 站交給銀行的那份）也要由監控團隊換成 bundle，否則階段二換完憑證就抓不到。

### 21.3.3 階段二：全部改由新 CA 簽

@role 銀行 CA 窗口 | Windows 終端 | 本機

銀行先用 G2 重簽自己的伺服器：AD 的 LDAPS、套件庫、保管庫。私鑰沿用（銀行的事，lab 簡化），重啟讓它們出示新憑證：

```bash
cd ~/kafka-lab && docker cp lab-ad01-1:/root/csr/ad01.csr "$(cygpath -m "$PWD/ca/exchange/ad01-g2.csr")" && bash ca/g2/sign.sh ca/exchange/ad01-g2.csr ca/exchange/ad01-g2.crt && docker cp "$(cygpath -m "$PWD/ca/exchange/ad01-g2.crt")" lab-ad01-1:/var/lib/samba/private/tls/cert.pem && docker cp "$(cygpath -m "$PWD/ca/bundle-g1-g2.pem")" lab-ad01-1:/var/lib/samba/private/tls/ca.pem && docker exec lab-ad01-1 bash -c 'chmod 644 /var/lib/samba/private/tls/cert.pem /var/lib/samba/private/tls/ca.pem; pkill -x samba; sleep 8' && O="$(cygpath -m "$PWD/images/web/tls")" && openssl req -new -key "$O/repo.key" -out "$O/repo-g2.csr" -subj "/CN=repo01.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:repo01.poc.lab,DNS:repo01" -addext "extendedKeyUsage=serverAuth" 2>/dev/null && bash ca/g2/sign.sh images/web/tls/repo-g2.csr images/web/tls/repo.crt && rm -f images/web/tls/repo-g2.csr && docker exec lab-repo01-1 systemctl restart httpd && C="$(cygpath -m "$PWD/conjur/tls")" && openssl req -new -key "$C/conjur.key" -out "$C/conjur-g2.csr" -subj "/CN=conjur.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:conjur.poc.lab,DNS:conjur" -addext "extendedKeyUsage=serverAuth" 2>/dev/null && bash ca/g2/sign.sh conjur/tls/conjur-g2.csr conjur/tls/conjur.crt && rm -f conjur/tls/conjur-g2.csr && docker restart lab-conjur-proxy-1 >/dev/null && sleep 3 && for ep in ad01.poc.lab:636 repo01.poc.lab:443 conjur.poc.lab:443; do echo "$ep $(docker exec lab-ops02-1 bash -c "openssl s_client -connect $ep </dev/null 2>/dev/null | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'")"; done
```

```out
signed ad01-g2.csr -> ad01-g2.crt  (CN = ad01.poc.lab, O = PoC Bank, C = TW; EKU serverAuth)
signed repo-g2.csr -> repo.crt  (…)
signed conjur-g2.csr -> conjur.crt  (…)
ad01.poc.lab:636 PoC Bank Issuing CA G2
repo01.poc.lab:443 PoC Bank Issuing CA G2
conjur.poc.lab:443 PoC Bank Issuing CA G2
```

@role 小安 | ops02 | cpadmin

接著我方的每一張憑證都要改由 G2 簽：**把 21.2.1 到 21.2.5 整個再做一次**，唯一的差別是銀行改用 `ca/g2/sign.sh`。下面照順序列出同一組指令（`chain=ok` 是對 bundle 驗的，新根在裡面）：

**21.2.1 新私鑰與 CSR**

```bash
install -d -m 0700 ~/pki/next ~/pki/next/keys ~/pki/next/requests ~/pki/next/incoming ~/pki/next/certs && cd ~/pki && while read -r name eku san; do (umask 077; openssl genrsa -out next/keys/$name.key 2048 2>/dev/null); ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku"); [ "$san" != "-" ] && ext+=(-addext "subjectAltName=$(echo "$san" | tr ',' '\n' | sed 's/^/DNS:/' | paste -sd, -)"); openssl req -new -key next/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" "${ext[@]}" -out next/requests/$name.csr && echo "$name: csr ok"; done < requests.txt
```

```out
kafka-internal: csr ok
（7 行）
```

**21.2.2 銀行改用 G2 簽**

@role 銀行 CA 窗口 | Windows 終端 | 本機

```bash
cd ~/kafka-lab && rm -rf ca/exchange/next && mkdir -p ca/exchange/next/signed && docker cp lab-ops02-1:/home/cpadmin/pki/next/requests "$(cygpath -m "$PWD/ca/exchange/next/")" && for f in ca/exchange/next/requests/*.csr; do n=$(basename $f .csr); bash ca/g2/sign.sh "$f" "ca/exchange/next/signed/$n.crt"; done && for f in ca/exchange/next/signed/*.crt; do docker cp "$(cygpath -m "$f")" lab-ops02-1:/home/cpadmin/pki/next/incoming/; done && docker exec lab-ops02-1 bash -c 'chown cpadmin:cpadmin /home/cpadmin/pki/next/incoming/*; ls /home/cpadmin/pki/next/incoming | wc -l'
```

```out
signed app-legacy-billing.csr -> app-legacy-billing.crt  (CN = app-legacy-billing, O = PoC Bank, C = TW; EKU clientAuth)
（7 行）
7
```

**21.2.3 檢查（issuer 要是 G2）**

@role 小安 | ops02 | cpadmin

```bash
cd ~/pki/next && for n in $(awk '{print $1}' ../requests.txt); do awk -v n=$n 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("incoming/" n ".part" c)}' incoming/$n.crt; mv incoming/$n.part1 incoming/$n.leaf.pem; cat incoming/$n.part[2-9] > incoming/$n.issuers.pem 2>/dev/null; rm -f incoming/$n.part*; done; while read -r name eku san; do leaf=incoming/$name.leaf.pem; k1=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16); k2=$(openssl pkey -in keys/$name.key -pubout 2>/dev/null | sha256sum | cut -c1-16); cn=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); have_san=$(openssl x509 -in $leaf -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,); want_san=$([ "$san" = "-" ] && echo "" || echo "$san" | tr ',' '\n' | sort | paste -sd,); have_eku=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' '); days=$(( ($(date -d "$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )); chain=$(openssl verify -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem -untrusted incoming/$name.issuers.pem $leaf 2>&1 | grep -c ": OK"); issuer=$(openssl x509 -in $leaf -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); printf '%-19s key=%s cn=%s san=%s days=%s chain=%s issuer=%s\n' $name $([ $k1 = $k2 ] && echo ok || echo MISMATCH) $([ "$cn" = "$name" ] && echo ok || echo "$cn") $([ "$have_san" = "$want_san" ] && echo ok || echo DIFF) $days $([ $chain = 1 ] && echo ok || echo FAIL) "$issuer"; done < ../requests.txt
```

```out
kafka-internal      key=ok cn=ok san=ok days=364 chain=ok issuer=PoC Bank Issuing CA G2
（7 行，全部 ok）
```

**21.2.3 做成 keystore**

```bash
cd ~/pki/next && for n in $(awk '{print $1}' ../requests.txt); do cat incoming/$n.leaf.pem incoming/$n.issuers.pem > certs/$n.crt; openssl pkcs12 -export -name $n -inkey keys/$n.key -in certs/$n.crt -out certs/$n.p12 -passout file:../store.pass && chmod 0600 certs/$n.p12; done; ls certs | wc -l; for n in kafka-internal cp-server; do echo "$n: old=$(openssl x509 -in ../certs/$n.crt -noout -serial | tail -c 9) new=$(openssl x509 -in certs/$n.crt -noout -serial | tail -c 9)"; done
```

```out
14
kafka-internal: old=F343BC55 new=F343BC5D
cp-server: old=F343BC54 new=F343BC5C
```

**21.2.4 派送、滾動重啟 controller 與 broker**

```bash
cd ~/pki/next && NEW_INT=$(openssl x509 -in certs/kafka-internal.crt -noout -serial | cut -d= -f2) NEW_SRV=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2) && served() { openssl s_client -connect $1 -servername ${1%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; } && for h in kc01 kc02 kc03; do scp -q certs/kafka-internal.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/kafka-internal.p12 /etc/confluent/ssl/ && rm -f /tmp/kafka-internal.p12 && sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done'; for i in $(seq 1 30); do [ "$(served $h.poc.lab:9093)" = $NEW_INT ] && break; sleep 2; done; echo "$h $(ssh $h.poc.lab systemctl is-active confluent-server) 9093=$([ "$(served $h.poc.lab:9093)" = $NEW_INT ] && echo new || echo OLD)"; done; for h in kb01 kb02 kb03 kb04; do scp -q certs/kafka-internal.p12 certs/cp-server.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'for f in kafka-internal.p12 cp-server.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12; sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) 9092=$([ "$(served $h.poc.lab:9092)" = $NEW_INT ] && echo new || echo OLD) 9095=$([ "$(served $h.poc.lab:9095)" = $NEW_SRV ] && echo new || echo OLD)"; done
```

```out
kc01 active 9093=new
（3 行）
kb01 MDS=200 9092=new 9095=new
（4 行）
```

**21.2.4 REST Proxy 與 C3**

```bash
cd ~/pki/next && NEW_SRV=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2) && served() { openssl s_client -connect $1 -servername ${1%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; } && for h in rest01 rest02; do scp -q certs/cp-server.p12 certs/svc-rest.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'for f in cp-server.p12 svc-rest.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12; sudo systemctl restart confluent-kafka-rest'; for i in $(seq 1 30); do [ "$(curl -s --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)" = 200 ] && break; sleep 5; done; echo "$h REST=$(curl -s --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters) 8082=$([ "$(served $h.poc.lab:8082)" = $NEW_SRV ] && echo new || echo OLD)"; done; scp -q certs/cp-server.p12 certs/cp-server.crt keys/cp-server.key certs/svc-c3.p12 c3-01.poc.lab:/tmp/ && ssh c3-01.poc.lab 'for f in cp-server.p12 cp-server.crt cp-server.key svc-c3.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/cp-server.* /tmp/svc-c3.p12; for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) 9021=$([ "$(served c3-01.poc.lab:9021)" = $NEW_SRV ] && echo new || echo OLD) 9090=$([ "$(served c3-01.poc.lab:9090)" = $NEW_SRV ] && echo new || echo OLD)"
```

```out
rest01 REST=200 8082=new
rest02 REST=200 8082=new
c3-01 UI=200 9021=new 9090=new
```

**21.2.5 換成正本**

```bash
cd ~/pki && OLD=old-$(date +%Y%m%d-%H%M) && install -d -m 0700 $OLD/keys $OLD/certs && for n in $(awk '{print $1}' requests.txt); do mv keys/$n.key $OLD/keys/; mv certs/$n.crt certs/$n.p12 $OLD/certs/; install -m 0600 next/keys/$n.key keys/; install -m 0644 next/certs/$n.crt certs/; install -m 0600 next/certs/$n.p12 certs/; done && rm -rf next && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && echo "svc-ops 管理 client：$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list 2>/dev/null | wc -l) 個 topic" && echo "kafka-internal 查 quorum：$(kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status 2>/dev/null | grep -o 'LeaderId: *[0-9]*')" && CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && T=$(curl -sS --cacert $CA -X POST --data-binary @$HOME/secrets/conjur-ops.key https://conjur.poc.lab/authn/poc/ops%40kafka/authenticate | base64 -w0) && cat keys/opmenu-breakglass.key certs/opmenu-breakglass.crt | curl -sS --cacert $CA -H "Authorization: Token token=\"$T\"" -X POST --data-binary @- https://conjur.poc.lab/secrets/poc/variable/kafka%2Fbreakglass%2Fpem && unset T && echo "breakglass：保管庫已更新" && echo "新的 app-legacy-billing（交給應用程式團隊）：REST=$(curl -s --cert certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)；舊的（還在效期內）：REST=$(curl -s --cert $OLD/certs/app-legacy-billing.crt --key $OLD/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)"
```

```out
svc-ops 管理 client：14 個 topic
kafka-internal 查 quorum：LeaderId: 1
breakglass：保管庫已更新
新的 app-legacy-billing（交給應用程式團隊）：REST=200；舊的（還在效期內）：REST=200
```

> 陷阱：這一段**一定要做完才能進階段三**。只有銀行的伺服器換成 G2、我方的 leaf 還是舊 CA 簽的就拿掉舊根，broker 驗不過 controller 的憑證，整個叢集起不來（lab 實際發生過：broker 一直重啟、MDS 不回應）。

最後確認每個端點出示的都是 G2 簽的憑證，全部是才往下：

```bash
bad=0; for ep in kc01.poc.lab:9093 kc02.poc.lab:9093 kc03.poc.lab:9093 kb01.poc.lab:9092 kb02.poc.lab:9092 kb03.poc.lab:9092 kb04.poc.lab:9092 kb01.poc.lab:9095 kb01.poc.lab:8090 rest01.poc.lab:8082 rest02.poc.lab:8082 c3-01.poc.lab:9021 c3-01.poc.lab:9090; do i=$(openssl s_client -connect $ep </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/.*CN *= *//; s/,.*//'); [ "$i" = "PoC Bank Issuing CA G2" ] || { echo "$ep 出示的是：${i:-（沒有回應）}"; bad=1; }; done; [ $bad = 0 ] && echo "13 個端點都是 G2 簽的：可以進階段三"
```

```out
13 個端點都是 G2 簽的：可以進階段三
```

### 21.3.4 階段三：拿掉舊根

@role 銀行 OS 團隊 | Windows 終端 | 本機

```bash
cd ~/kafka-lab/ca && for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker cp "$(cygpath -m "$PWD/g2/root.crt")" lab-$h-1:/root/bank-root.pem && docker exec lab-$h-1 bash -c 'install -m 0644 /root/bank-root.pem /etc/pki/ca-trust/source/anchors/bank-root.pem && rm -f /root/bank-root.pem && update-ca-trust && printf "%s:%s " $(hostname) $(grep -c "BEGIN CERT" /etc/pki/ca-trust/source/anchors/bank-root.pem)'; done; echo; docker cp "$(cygpath -m "$PWD/g2/root.crt")" lab-ad01-1:/var/lib/samba/private/tls/ca.pem
```

```out
ops02:1 kc01:1 kc02:1 kc03:1 kb01:1 kb02:1 kb03:1 kb04:1 rest01:1 rest02:1 c3-01:1
```

@role 小安 | ops02 | cpadmin

truststore 拿掉舊的 alias、C3 與 OP menu 的 ca.pem 只留新根，派送、滾動重啟：

```bash
cd ~/pki/certs && cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem && keytool -delete -alias bank-root -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass && echo "truststore：$(keytool -list -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | paste -sd' ')" && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q truststore.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/ && rm -f /tmp/truststore.p12'; done && scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem && ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem && rm -f /tmp/ca.pem' && sudo install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12 && sudo install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem && bash ~/conf/rolling-restart.sh
```

```out
truststore：bank-root-g2
kc01 active
（滾動重啟 10 行，全部健康）
c3-01 UI=200
```

最後反向驗證：舊 CA 簽的憑證（21.2 第一次換發留在 `old-` 底下的那張應用程式憑證）連 REST Proxy 要被拒；新的要能用；AD、套件庫、保管庫照常（它們在階段二已經換成 G2）：

```bash
cd ~/pki && OLDEST=$(ls -d old-* | head -1) && echo "舊 CA 簽的 app 憑證 → REST：$(curl -s --cert $OLDEST/certs/app-legacy-billing.crt --key $OLDEST/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)（000 = TLS 直接拒絕）" && echo "新 CA 簽的 app 憑證 → REST：$(curl -s --cert certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)" && echo "alice 登入 MDS（MDS 要用 LDAPS 連 AD）：$(curl -s -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)" && echo "套件庫：$(curl -s -o /dev/null -w '%{http_code}' https://repo01.poc.lab/confluent/repodata/repomd.xml)、保管庫：$(curl -s -o /dev/null -w '%{http_code}' https://conjur.poc.lab/)"
```

```out
舊 CA 簽的 app 憑證 → REST：000（000 = TLS 直接拒絕）
新 CA 簽的 app 憑證 → REST：200
alice 登入 MDS（MDS 要用 LDAPS 連 AD）：200
套件庫：200、保管庫：200
```

> 階段三之前要確認：應用程式團隊已經換上新 CA 簽的憑證（REST 走 mTLS 的那些）、行內 Prometheus 與應用程式的 truststore 都已經有新根。否則拿掉舊根的那一刻，它們就斷了。

# 22. 第二十二站：升級 Confluent 與 JDK

![upgrade]

平台上線之後，Confluent 每季會出新版，JDK 也會跟著更新。這一站用一次真實的情境走完：**Confluent Platform 8.2.4 → 8.3.2**，同時把 **JDK 21 換成 25**（8.3 才支援 Java 25，8.2 不支援；注意原廠對 8.3 的**建議**版本仍是 21，25 是「支援」，選 25 要和原廠支援確認）。Control Center 這次版本不變（2.6.1 支援 7.5.15 到 8.3.x），維持 JDK 21。

> 本章的前提：要有一套**舊版**才有東西可升。照書做下來的是 8.3.2，演練時從第 1 章重來一次，把各章指令裡的 `8.3.2` 換成 `8.2.4`（第 1.2 節下載、第 8 章安裝與 versionlock），C3 維持 2.6.1；套件庫裡兩個版本都留著。

分三段，每段結束都可以停下來驗收：

| 段 | 做什麼 | 出問題怎麼退 |
|---|---|---|
| 一 | 套件 8.2.4 → 8.3.2，JDK 維持 21。順序照原廠：C3 → broker 逐台 → controller 逐台（leader 最後）→ REST Proxy → 操作機的工具 | `dnf downgrade` 回 8.2.4（22.9） |
| 二 | JDK 21 → 25：controller、broker、REST Proxy、操作機逐台切換 `/opt/java/current`；C3 留在 21 | 連結切回 21、重啟 |
| 三 | finalize：features 升到 4.3（`kafka-features upgrade --release-version 4.3`） | **不能退**：之後只有新舊版之間沒有 metadata 變更才能降版，8.3 降回去可能要從備份還原 |

要回 8.2 時順序反過來：先把 JDK 切回 21（8.2 不支援 25），再 `dnf downgrade`。所以**前兩段都驗收過才做第三段**。

> 實測（lab，客戶模式，全程持續流量）：約 48 分鐘。直連應用程式送出 14,009 筆、讀回 14,009 筆，遺失 0；經負載平衡的 REST 2,684 次中失敗 2 次（HTTP 402，都發生在 controller 重啟的那幾秒，lab 用的是試用 license）。三段結束各跑一次第 20 章的驗收，都全數通過。

## 22.1 升級前檢查

@role 小安 | ops02 | cpadmin

確認現在的版本、quorum、套件庫裡有沒有新版、有沒有沒追上的複本，以及 8.3 已經拿掉的設定（`message.format.version` 這類留在設定檔裡，8.3 會起不來）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && kafka-features --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties describe 2>/dev/null | grep confluent.metadata.version | tr -s ' \t' ' ' && kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status 2>/dev/null | grep LeaderId && dnf -q --refresh list --showduplicates confluent-server 2>/dev/null | grep confluent-internal | tr -s ' ' && echo "under-replicated: $(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:)" && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do printf '%s:%s ' $h "$(ssh $h.poc.lab 'sudo grep -cE "^(message.format.version|message.downconversion.enable|message.timestamp.difference.max.ms|log.message.format.version)" /etc/confluent/kafka/server.properties')"; done; echo
```

```out
Feature: confluent.metadata.version SupportedMinVersion: CP-7.3-IV3 SupportedMaxVersion: CP-8.2-IV1A FinalizedVersionLevel: CP-8.2-IV1A Epoch: …
LeaderId:               2
confluent-server.noarch 1:8.2.4-1 @confluent-internal
confluent-server.noarch 1:8.2.4-1 confluent-internal
confluent-server.noarch 1:8.3.2-1 confluent-internal
under-replicated: 0
kc01:0 kc02:0 kc03:0 kb01:0 kb02:0 kb03:0 kb04:0
```

新版的 RPM 和 JDK 照第 1–4 站的流程帶進來：下載機抓 `confluent-*-8.3.2`、照 1.5 把 `latest/21` 換成 `latest/25` 抓 JDK 25 交給銀行、掃描交換、上架。套件庫裡**舊版要留著**，回滾要用。

## 22.2 備份

@role 小安 | ops02 | cpadmin

每台的 `/etc/confluent` 與 systemd drop-in、features 狀態、操作機的套件清單，打包回操作機（0700）。master key（`service.env`）與保管庫的主機身分（`/etc/confluent/conjur/`）不放進備份：master key 的正本在 CyberArk，身分由保管庫重發，備份檔就不必當成機敏資料保管。回滾、或 finalize 之後真的要退，都從這裡拿：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && B=~/upgrade-backup/$(date +%Y%m%d-%H%M) && install -d -m 0700 $B && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'sudo tar -czf - -C / --exclude=etc/confluent/service.env --exclude=etc/confluent/conjur etc/confluent $(ls -d etc/systemd/system/confluent-*.service.d 2>/dev/null)' > $B/$h.tar.gz && printf '%s %s  ' $h "$(du -h $B/$h.tar.gz | cut -f1)"; done; echo; kafka-features --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties describe > $B/features.txt 2>/dev/null; rpm -qa 'confluent-*' | sort > $B/ops02-packages.txt; echo "$B"
```

```out
kc01 28K  kc02 28K  kc03 28K  kb01 32K  kb02 32K  kb03 32K  kb04 32K  rest01 28K  rest02 28K  c3-01 32K
/home/cpadmin/upgrade-backup/20261024-1401
```

## 22.3 第一段：Control Center 先

@role 小安 | ops02 | cpadmin

原廠要求 C3 比 broker、controller 先升。這次 C3 版本不變，只要確認它活著、版本在 8.3 的相容範圍內（2.6.x 支援到 8.3.x）。C3 有新版時就在這一步照 22.4 的方式換套件、重啟。

```bash
ssh c3-01.poc.lab 'rpm -q confluent-control-center-next-gen; systemctl is-active confluent-control-center'; echo "UI=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"
```

```out
confluent-control-center-next-gen-2.6.1-1.noarch
active
UI=200
```

## 22.4 第一段：broker 逐台

@role 小安 | ops02 | cpadmin

每台：解開 versionlock → 這台裝的每個 Confluent 套件都換成 8.3.2 → 重新鎖 → **`daemon-reload`**（RPM 升級會換掉 systemd 的 unit 檔，不 reload 就重啟，用的還是舊的定義）→ 確認設定檔沒被動、ExecStart 還指著我們的設定 → 重啟 → 等 MDS 回 200、under-replicated 回到 0 才做下一台：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && for h in kb01 kb02 kb03 kb04; do t0=$(date +%s); ssh $h.poc.lab 'before=$(sudo sha256sum /etc/confluent/kafka/server.properties | cut -c1-12); pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.3.2 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y install $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null; sudo systemctl daemon-reload; after=$(sudo sha256sum /etc/confluent/kafka/server.properties | cut -c1-12); echo "$(hostname) $(rpm -q confluent-server) 設定檔$([ $before = $after ] && echo 沒變 || echo 被改了) exec=$(systemctl show confluent-server -p ExecStart --value | grep -o "/etc/[^ ]*properties")"; sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; for j in $(seq 1 60); do u=$(kafka-topics --bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:); [ "$u" = 0 ] && break; sleep 5; done; echo "  MDS 200（約 $((i*5)) 秒）under-replicated=$u，這台 $(( $(date +%s) - t0 )) 秒"; done
```

```out
kb01 confluent-server-8.3.2-1.noarch 設定檔沒變 exec=/etc/confluent/kafka/server.properties
  MDS 200（約 20 秒）under-replicated=0，這台 73 秒
（4 台，每台 70–110 秒）
```

> 陷阱：重啟前沒做 `daemon-reload`，systemd 會印 `The unit file … changed on disk`。設定還是我們的（drop-in 會疊上去），但下一次 reload 才會真的用新的 unit；所以每台都在重啟前 reload。

## 22.5 第一段：controller 逐台（leader 最後）

@role 小安 | ops02 | cpadmin

步驟和 broker 一樣。controller 的健康看 quorum：這台回來、`Lag` 是 0。**leader 會在過程中換人**（實測做完第二台時 leader 從 kc02 換到 kc01），所以每做一台之前都重新查一次 leader，跳過它，最後一輪才做 leader：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && Q="kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 --command-config /home/cpadmin/conf/client-internal.properties" && done_list="" && for round in 1 2 3; do leader=kc0$($Q describe --status 2>/dev/null | awk '/LeaderId/{print $2}'); h=""; for c in kc01 kc02 kc03; do [[ " $done_list " == *" $c "* ]] && continue; [ $c = $leader ] && [ $round -lt 3 ] && continue; h=$c; break; done; ssh $h.poc.lab 'pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.3.2 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y install $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null; sudo systemctl daemon-reload; sudo systemctl restart confluent-server'; sleep 10; for i in $(seq 1 60); do lag=$($Q describe --replication 2>/dev/null | awk -v id=${h#kc0} '$1==id {print $4}'); [ "$lag" = 0 ] && break; sleep 5; done; echo "$h $(ssh $h.poc.lab 'rpm -q confluent-server') Lag=$lag（這輪開始時 leader=$leader）"; done_list="$done_list $h"; done
```

```out
kc01 confluent-server-8.3.2-1.noarch Lag=0（這輪開始時 leader=kc02）
kc03 confluent-server-8.3.2-1.noarch Lag=0（這輪開始時 leader=kc01）
kc02 confluent-server-8.3.2-1.noarch Lag=0（這輪開始時 leader=kc01）
```

`describe --replication` 的欄位依序是 NodeId、DirectoryId、LogEndOffset、**Lag**、…，看的是第 4 欄。

## 22.6 第一段：REST Proxy 與操作機的工具

@role 小安 | ops02 | cpadmin

原廠要求 RBAC 環境在升 REST Proxy 之前，先讓 REST Proxy 的身分在 `_confluent-command` 有 ResourceOwner（原本只有 DeveloperRead）：

```bash
source ~/conf/kraft.env && confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key >/dev/null && confluent iam rbac role-binding create --principal User:svc-rest --role ResourceOwner --resource Topic:_confluent-command --kafka-cluster $CLUSTER_ID | grep -E 'Role|Name' | tr -s ' '
```

```out
| Role | ResourceOwner |
| Name | _confluent-command |
```

兩台 REST Proxy 一台一台換（負載平衡會把流量送到另一台），最後是操作機自己的 `kafka-*` 與 `confluent` 指令：

```bash
for h in rest01 rest02; do ssh $h.poc.lab 'pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.3.2 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y install $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null; sudo systemctl daemon-reload; sudo systemctl restart confluent-kafka-rest'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key https://$h.poc.lab:8082/v3/clusters)" = 200 ] && break; sleep 5; done; echo "$h $(ssh $h.poc.lab 'rpm -q confluent-kafka-rest') REST 200（約 $((i*5)) 秒）"; done; pkgs=$(rpm -qa 'confluent-*' --qf '%{NAME}-8.3.2 '); sudo dnf -q versionlock delete 'confluent-*' >/dev/null; sudo dnf -q -y install $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null; echo "ops02 $(rpm -q confluent-server confluent-cli | paste -sd' ')"
```

```out
rest01 confluent-kafka-rest-8.3.2-1.noarch REST 200（約 15 秒）
rest02 confluent-kafka-rest-8.3.2-1.noarch REST 200（約 15 秒）
ops02 confluent-server-8.3.2-1.noarch confluent-cli-8.3.2-1.x86_64
```

第一段結束：照第 20 章 20.1–20.3 再驗一次（實測全數通過）。這時 features 還是 8.2，隨時可以照 22.9 退回。

## 22.7 第二段：JDK 21 → 25

@role 小安 | ops02 | cpadmin

和第 5 站一樣解壓到 `/opt/java/<版本目錄>`，只是把 `/opt/java/current` 切過去；所有服務的 drop-in 寫的都是 `/opt/java/current`，設定檔不用改。舊的 JDK 21 目錄留著，退回就是把連結切回去。**c3-01 不動**（原廠沒有寫 C3 2.6 支援 Java 25）。

先 controller（每輪重查 leader、leader 最後）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1) && JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1) && echo "新 JDK：$JDK_DIR" && Q="kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 --command-config /home/cpadmin/conf/client-internal.properties" && done_list="" && for round in 1 2 3; do leader=kc0$($Q describe --status 2>/dev/null | awk '/LeaderId/{print $2}'); h=""; for c in kc01 kc02 kc03; do [[ " $done_list " == *" $c "* ]] && continue; [ $c = $leader ] && [ $round -lt 3 ] && continue; h=$c; break; done; scp -q "$JDK_TAR" $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo tar -xzf /tmp/$(basename $JDK_TAR) -C /opt/java && rm -f /tmp/$(basename $JDK_TAR) && sudo chown -R root:root /opt/java/$JDK_DIR && sudo ln -sfn /opt/java/$JDK_DIR /opt/java/current && sudo systemctl restart confluent-server"; sleep 10; for i in $(seq 1 60); do lag=$($Q describe --replication 2>/dev/null | awk -v id=${h#kc0} '$1==id {print $4}'); [ "$lag" = 0 ] && break; sleep 5; done; echo "$h java=$(ssh $h.poc.lab 'sudo readlink /proc/$(systemctl show confluent-server -p MainPID --value)/exe') Lag=$lag"; done_list="$done_list $h"; done
```

```out
新 JDK：jdk-25.0.5+8
kc01 java=/opt/java/jdk-25.0.5+8/bin/java Lag=0
（3 台，每台約 15 秒）
```

再 broker、REST Proxy、操作機：

```bash
JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1) && JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1) && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && for h in kb01 kb02 kb03 kb04 rest01 rest02; do case $h in kb*) unit=confluent-server; url=https://$h.poc.lab:8090/v1/metadata/id; opt="";; *) unit=confluent-kafka-rest; url=https://$h.poc.lab:8082/v3/clusters; opt="--cert $HOME/pki/certs/app-legacy-billing.crt --key $HOME/pki/keys/app-legacy-billing.key";; esac; scp -q "$JDK_TAR" $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo tar -xzf /tmp/$(basename $JDK_TAR) -C /opt/java && rm -f /tmp/$(basename $JDK_TAR) && sudo chown -R root:root /opt/java/$JDK_DIR && sudo ln -sfn /opt/java/$JDK_DIR /opt/java/current && sudo systemctl restart $unit"; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' $opt $url)" = 200 ] && break; sleep 5; done; for j in $(seq 1 60); do u=$(kafka-topics --bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:); [ "$u" = 0 ] && break; sleep 5; done; echo "$h java=$(ssh $h.poc.lab "sudo readlink /proc/\$(systemctl show $unit -p MainPID --value)/exe") 200（約 $((i*5)) 秒）under-replicated=$u"; done; sudo tar -xzf "$JDK_TAR" -C /opt/java && sudo chown -R root:root /opt/java/$JDK_DIR && sudo ln -sfn /opt/java/$JDK_DIR /opt/java/current && echo "ops02 $(java -version 2>&1 | head -1)"; echo "c3-01 $(ssh c3-01.poc.lab 'readlink /opt/java/current')"
```

```out
kb01 java=/opt/java/jdk-25.0.5+8/bin/java 200（約 20 秒）under-replicated=0
（broker 4 台、REST 2 台）
ops02 openjdk version "25.0.5" … LTS
c3-01 /opt/java/jdk-21.0.x+y
```

> 陷阱：走第 15 章（Conjur provider）的環境，provider 連 Conjur 靠的是 **JDK 自己的 `cacerts`**（15.3 匯入了銀行根）。新解壓的 JDK 25 沒有那份匯入，重啟前要照 15.3 對 `/opt/java/<新目錄>/lib/security/cacerts` 再匯一次，否則服務連不到 Conjur。走第 16 章的不受影響（本輪 lab 是第 16 章路徑，這一條沒有實測）。

broker 的日誌會多一則 `WARNING: A terminally deprecated method in sun.misc.Unsafe has been called`：原廠說明這只是警告，JDK 25 上照常運作。第二段結束：照第 20 章再驗一次（實測全數通過）。

## 22.8 第三段：finalize（之後不能退回 8.2）

@role 小安 | ops02 | cpadmin

先看 4.3 會把哪些 feature 升到多少，再 `--dry-run`：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && F="kafka-features --bootstrap-server kb01.poc.lab:9094 --command-config /home/cpadmin/conf/client-admin.properties" && $F version-mapping --release-version 4.3 2>/dev/null && $F upgrade --release-version 4.3 --dry-run 2>/dev/null
```

```out
confluent.metadata.version=137 (4.3)
kraft.version=1
transaction.version=2
group.version=1
eligible.leader.replicas.version=1
share.version=1
streams.version=1
confluent.metadata.version can be upgraded to 137.
（7 行 can be upgraded）
```

除了 metadata 版本，4.3 也一併開啟 eligible leader replicas、share groups、streams 的新協定。確定前兩段都驗過了，正式升：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && F="kafka-features --bootstrap-server kb01.poc.lab:9094 --command-config /home/cpadmin/conf/client-admin.properties" && $F upgrade --release-version 4.3 2>/dev/null && $F describe 2>/dev/null | grep confluent.metadata.version | awk '{print $2, $8}'
```

```out
confluent.metadata.version was upgraded to 137.
（7 行 was upgraded）
confluent.metadata.version CP-8.3-IV0B
```

最後照第 20 章完整驗收一次。

## 22.9 回滾（finalize 之前）

@role 小安 | ops02 | cpadmin

任何一段出問題、features 還沒升（`describe` 看到的還是 `CP-8.2-…`），就逐台退：先把 JDK 切回 21，再把套件 `downgrade` 回 8.2.4、重新鎖、`daemon-reload`、重啟。順序和升級相反（操作機、REST Proxy → controller → broker，C3 最後）。實測拿 kb04 單台演練（其他台都是 8.3.2）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && h=kb04 && ssh $h.poc.lab 'sudo ln -sfn $(ls -d /opt/java/jdk-21* | sort -V | tail -1) /opt/java/current; pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.2.4 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y downgrade $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null; sudo systemctl daemon-reload; sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h $(ssh $h.poc.lab 'rpm -q confluent-server; sudo readlink /proc/$(systemctl show confluent-server -p MainPID --value)/exe' | paste -sd' ') MDS 200（約 $((i*5)) 秒）"
```

```out
kb04 confluent-server-8.2.4-1.noarch /opt/java/jdk-21.0.x+y/bin/java MDS 200（約 15–20 秒）
```

退回的那台在其他台都是 8.3.2 的叢集裡正常服務（under-replicated 回到 0）。演練完再照 22.4、22.7 把它升回去。

> 回滾：finalize 之後就不能用這個方法了。真的要退，得用 22.2 的備份與原廠支援的還原程序，所以 finalize 一定排在前兩段都驗收、觀察一段時間之後。
