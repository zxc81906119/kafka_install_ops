<!--meta
{
  "kicker": "Confluent Platform 離線安裝與遷移（8.2 → 8.3）",
  "title": "小安的安裝旅程",
  "subtitle": "手把手走一遍：從外網下載到 Control Center 亮燈，每一步誰做、敲什麼、看到什麼",
  "author": "PoC 團隊",
  "header": "Confluent Platform 安裝旅程 — 手把手",
  "facts": [["版本", "安裝基底：Confluent Platform 8.2.4、Control Center 2.5.1、Java 21、RHEL 9.6；遷移目標：8.3.2、2.6.1、Java 25、RHEL 9.8"], ["環境", "11 台 RHEL 9 主機（lab 以容器模擬，環境從零自建）"], ["對象", "第一次安裝 Confluent Kafka 的工程師"], ["日期", "2026-10-21"]]
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
| ops02 | 操作機：安裝起點，小安整天待在這裡；人員經 CyberArk（PVWA 網頁登入、PSMP 代登 ssh）登入就是 root，連各主機用 cpuser | 我方（root；連主機用 cpuser） |
| kc01、kc02、kc03 | KRaft controller | 我方安裝，銀行提供主機 |
| kb01–kb04 | Kafka broker | 同上 |
| rest01、rest02 | REST Proxy | 同上 |
| c3-01 | Control Center（含內建 Prometheus、Alertmanager，只供 C3 自己的畫面用） | 同上 |
| repo01 | 行內套件庫 web server，lab 裡兼 NTP | 銀行 |
| ad01 | 行內 AD（lab 用 Samba 模擬） | 銀行 |
| lb01 | 負載平衡（lab 用 nginx 模擬） | 銀行 |
| 行內監控（Prometheus、Alertmanager、Grafana） | 抓指標、發告警、看 dashboard；告警送到行內的事件系統（lab 用 `lab-mon-*` 四個容器模擬，第 17 章） | 銀行監控團隊 |
| PVWA | CyberArk PAM 的網頁：平台密碼（passphrase、master key 等）的正本都在這裡，人工取放；ssh 私鑰不在這裡（3.1）（lab 用 Windows 上的 `~/kafka-lab/pvwa/` 資料夾模擬） | 銀行 Secrets 團隊 |

所有主機的 FQDN 是 `<主機>.poc.lab`。

## 0.3 旅程總覽

![journey]

## 0.4 怎麼讀這本

- 稱呼：本手冊的「章」就是標題寫「第 N 站」的那一段（例如第 9 章 = 第九站），「節」是 9.1 這種小標；內文引用一律寫「第 N 章」或「N.M 節」。「操作機」就是主機名稱 ops02，內文叫操作機，指令與 `@role` 裡寫 ops02。「小安」是手冊裡的虛構新人，代表你。「行內」與「銀行」同義：行內的套件庫、AD 就是銀行準備的套件庫、AD。
- 綠色標籤 **我方**：小安敲的指令。橘色標籤 **銀行**：銀行各團隊的事，lab 裡由你代勞。
- 每個指令上方都有一行「▶ 在哪台（用哪個帳號）執行」。要換機器的那一個指令（以及每章第一個指令）會附上 lab 裡切過去的指令，例如 `docker exec -it -w /root lab-ops02-1 bash`；從一台容器換到另一台時，先 `exit` 回到 Git Bash 再切。正式環境進操作機是在 CyberArk 的 PVWA 網頁選目標、由 PSMP 代登（進去是 root）；從操作機連其他主機一律用 cpuser 的金鑰 ssh。
- 每個指令後面接「預期輸出」。看到的和預期不同就停下來，先弄懂再往下。
- 指令都是一行可以整段貼上的；多行的 `heredoc`（`<<'EOF' … EOF`）要整段一起貼。
- 密碼一律放在檔案裡（權限 0600）再讀進指令，不直接打在畫面上，也不要貼到任何對話裡。正本在 PVWA；操作機上的是作業用的副本。從 PVWA 取出貼上時一律用**不顯示的寫法**（密碼見 3.4、15.2），PSMP 的錄影才不會錄到。
- **主線是「先裝基底、再遷移」**：第 1–20 章裝的是安裝基底，第 21、26、27 章把它遷移到目標版本，每一段之後都跑第 19 章的驗收。兩組版本的來由與限制在下面「版本路徑」。
- 主線是本案客戶的情境：銀行的 CyberArk 只有 PAM（PVWA、PSMP、CPM），平台密碼由人從 PVWA 取放；操作機到各主機的 ssh 金鑰是操作機自己的，不放 CyberArk（3.1）。

- 指令很長是為了「整段貼上就能跑」。看不懂沒關係，先照做；每一章開頭說這章要做什麼，結尾說看到什麼代表成功。

> 陷阱：在各主機上（以 cpuser 登入）確認用的 `ls`、`stat` 看 `/etc/confluent/ssl`、`/var/lib/kafka` 這類 0750 的目錄要加 `sudo`，不然會 Permission denied，誤以為前一步失敗。操作機上你是 root，不需要。

### 版本路徑：安裝基底與遷移目標

下面這張圖把四層版本和遷移的先後順序畫在一起。

![versionpath]

| 層 | 安裝基底（第 1–20 章裝的） | 遷移目標（第 21、26、27 章） | 為什麼 |
|---|---|---|---|
| Confluent Platform | 8.2.4 | 8.3.2 | 第 21 章：套件滾動升級、finalize |
| Control Center | 2.5.1 | 2.6.1 | 原廠相容表：2.5.x 支援到 CP 8.2.x，2.6.x 才支援到 8.3.x，所以 CP 升 8.3 之前 C3 先升（21.3、27） |
| JDK | 21 | 25 | 8.2.x 只支援 Java 17／21，**不支援 25**，所以基底一定是 21；8.3.x 才支援 25（原廠建議版本仍是 21）（21.7） |
| OS（RHEL 9） | 9.6 | 9.8 | 第 26.5 節：小版本更新；Confluent 與 JDK 被 versionlock、tar 擋住，只動 OS 套件 |

基底的 Confluent、C3、JDK 版本寫在 `install/conf/site.env`（`CP_VERSION`、`C3_VERSION`、`JDK_MAJOR`），目標版本是同一檔的 `*_TARGET_*`。做完遷移後把基底值改成目標值（21.10），之後新增主機照第 8 章才會裝到現行版本。

**lab 的限制先講清楚**：lab 的主機是 Rocky Linux 9 的容器，不是 RHEL；容器共用 WSL2 的核心，不能真的重開機（26.5 會講怎麼替代）；Rocky 的 9.6 套件來自它的 vault 倉庫，9.8 來自現行倉庫。正式環境是銀行的 RHEL 9.x 與銀行自己的套件庫，版本以銀行實際的為準（問題清單有問）。

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
| CyberArk PAM | 銀行的特權帳號系統：管人與帳號。元件：Vault（保管庫）、PVWA（Password Vault Web Access，人用的網頁）、CPM（Central Policy Manager，定期自動換密碼）、PSMP（Privileged Session Manager for SSH，代登 ssh 並錄影）。本案只用 PAM：人員在 PVWA 網頁登入（AD 帳密＋MFA）、由 PSMP 代登進操作機（root）；平台密碼由人從 PVWA 取放；CPM 輪替 root 與 svc-mds-bind |
| cpuser | 每台主機（含操作機）同名的本機帳號，是安裝與維運的唯一 user：密碼鎖定、只收金鑰、UID／GID 都是 1500；操作機用 `/secure/ssh` 裡那一把私鑰連過去（3.1） |
| Secret Protection | Confluent 的密碼加密功能：密文留在 `security.properties`，master key 以環境變數給服務 |
| OP menu | 給維運人員的文字選單（在操作機以 root 跑）：用本人 AD 身分做 Kafka 類作業，主機類作業以 cpuser ssh（金鑰就是 `/secure/ssh` 的那把） |

### 操作機上的檔案放哪

| 目錄 | 放什麼 |
|---|---|
| `~/landing/` | 銀行送進來的檔案（唯讀）：`rpm/`（安裝基底的 RPM）、`rpm-target/`（遷移目標的 RPM）、jar、公鑰、SHA256SUMS、`bank/` 裡的兩個 JDK（21、25） |
| `~/repo/` | 要上架到套件庫的目錄（含索引） |
| `~/jdk/` | `java.sh`（profile.d 用） |
| `~/pki/` | 私鑰 `keys/`、申請單 `requests/`、銀行回覆 `incoming/`、成品 `certs/`、keystore 密碼 `store.pass` |
| `~/conf/` | 設定檔範本與產生出來的設定、client 連線設定、`kraft.env` |
| `~/secrets/` | 各種密碼檔（0600，root 擁有） |
| `/secure/ssh/` | 操作機連各主機用的 ssh 私鑰（獨立的加密 file system，root、0400；不是 `~` 底下，也不備份）。見 3.1 |

### 每一站大概要多久

| 章 | 時間 | 慢在哪 |
|---|---|---|
| 0 建 lab | 20–30 分 | 建映像檔要連外網下載 |
| 1 下載 | 60–90 分 | 兩套各約 3 GB 從外網抓；lab 的 Windows 資料夾讀寫慢 |
| 2–4 進內網、銀行準備、上架 | 30 分 | 搬 6 GB、建索引 |
| 5–8 JDK、檢查、OS 調校、裝套件 | 30 分 | 11 台逐一 dnf install |
| 9 憑證 | 15 分 | — |
| 10–13 設定、啟動、權限、REST、C3 | 40 分 | 每段啟動要等健康檢查；C3 第一次起來 1–2 分鐘 |
| 15 Secret Protection（延伸） | 30 分 | 加密、派送、滾動重啟 |
| 16 OP menu（延伸） | 20 分 | 保管庫加身分、裝選單、改 sudoers、三種身分試跑 |
| 17 監控（延伸） | 40 分 | 四種程序派送、滾動重啟（controller 與 broker 的指標要等 2 分鐘）、lab 的 Prometheus／Alertmanager／Grafana、告警測試 |
| 18 稽核日誌（延伸） | 20 分 | 帳號、加密派送、滾動重啟、製造事件 |
| 19 驗收與收尾 | 30 分 | 四組檢查；冷開機要等 3 分鐘 |
| 20 憑證輪替 | 30 分／90 分 | leaf 換發一輪一次滾動重啟；換 CA 三階段要三次 |
| 21 遷移到新版 | 70 分 | C3、套件一輪、JDK 一輪滾動重啟（每台 15 秒到 2 分鐘）；controller 要等 quorum 追上 |
| 22 license 監控 | 5 分 | — |
| 23 換 controller | 10 分 | 新的那台要追上 metadata log |
| 24 增減 broker | 40 分 | Self-Balancing 搬資料（加回後十幾分鐘才開始搬） |
| 25 日常備份 | 10 分 | — |
| 26 OS 修補與小版本更新 | 10 分（每月修補）／30 分（9.6 → 9.8） | 逐台 dnf update；要重開機的話每台多幾分鐘 |
| 27 單獨換 C3 版本 | 10 分 | C3 只有一台，畫面約 1 分鐘不能用 |

## 0.5 自己把 lab 建起來

> 這一節只有練習用的 lab 需要。正式環境的主機、AD、CA、套件庫都是銀行準備好的，直接從第 1 章開始。

@role Lab 管理員（扮演銀行） | Windows 終端（Git Bash） | 本機

這一節在你的 Windows 筆電上用 Docker 蓋出一整套模擬環境：十幾台假主機，加上扮演銀行的 AD、CA、套件庫、負載平衡。做完 0.5 之後，你就有一個可以照第 1 章以後逐章練習的環境。需要 Docker Desktop 和 Git Bash。整個 lab 放在家目錄的 `kafka-lab/`，不依賴任何現成的專案；下面每個檔案都是用 heredoc 寫出來的，整段貼到 `EOF` 即可。先開一個 Git Bash，做兩個全域設定（之後所有 Windows 端指令都在這個視窗）：

```bash
export MSYS_NO_PATHCONV=1; mkdir -p ~/kafka-lab/{images/node,images/web/tls,images/ad,images/lb,ca,landing} && cd ~/kafka-lab && pwd
```

```out
/c/Users/<你>/kafka-lab
```

> `MSYS_NO_PATHCONV=1` 是讓 Git Bash 不要把 `/out`、`/etc/...` 這類容器內路徑轉成 Windows 路徑。給 Docker 的 Windows 路徑一律用 `$(cygpath -m …)` 產生。

### 0.5.1 主機映像檔：模擬「裸機 RHEL 9」

（lab 專用）這一節建出所有主機共用的映像檔。每台主機都是同一個映像：Rocky 9.6 最小安裝 + systemd + sshd + sudo，sshd 只收金鑰、沒有密碼登入。安裝與維運用的帳號 `cpuser` 不在映像裡，和銀行開給我們的主機一樣，是第 3 章由銀行 OS 團隊建立。沒有 JDK、沒有 Confluent、公開 repo 關閉，和銀行開給我們的主機一樣。

> 重點：**Rocky 的 9.6 映像裡預設的 repo 設定指向「最新的 9.x」**（mirrorlist 用 `$releasever` = 9），不動它的話 `dnf install` 裝到的是 9.8 的套件。所以先換成 vault 的 9.6 倉庫（`dl.rockylinux.org/vault/rocky/9.6`），再 `dnf update` 到 9.6 的最新修補，主機才是乾淨的 9.6。映像、下載機、後面 3.2 銀行套件庫的內容都用同一份 vault 設定。映像的 tag 用 `lab-node:96`：舊的 9.8 映像（`lab-node:1`）不會被誤用。

```bash
cat > images/node/rocky-vault-96.repo <<'EOF'
[vault96-baseos]
name=Rocky 9.6 BaseOS (vault)
baseurl=https://dl.rockylinux.org/vault/rocky/9.6/BaseOS/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1

[vault96-appstream]
name=Rocky 9.6 AppStream (vault)
baseurl=https://dl.rockylinux.org/vault/rocky/9.6/AppStream/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1

[vault96-extras]
name=Rocky 9.6 extras (vault)
baseurl=https://dl.rockylinux.org/vault/rocky/9.6/extras/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1
EOF
cat > images/node/Dockerfile <<'EOF'
FROM rockylinux/rockylinux:9.6
COPY rocky-vault-96.repo /etc/yum.repos.d/rocky-vault-96.repo
RUN rm -f /etc/yum.repos.d/rocky.repo /etc/yum.repos.d/rocky-addons.repo /etc/yum.repos.d/rocky-devel.repo /etc/yum.repos.d/rocky-extras.repo \
    && dnf -y update \
    && dnf -y install systemd openssh-server openssh-clients sudo tar gzip openssl procps-ng nmap-ncat hostname iproute less which findutils dnf-plugins-core ca-certificates \
    && dnf clean all && rm -f /etc/yum.repos.d/*.repo.rpmnew
RUN printf 'PermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nUseDNS no\n' > /etc/ssh/sshd_config.d/10-cp.conf \
    && systemctl enable sshd \
    && systemctl mask systemd-logind.service getty.target console-getty.service systemd-udevd.service \
    && sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/*.repo
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
EOF
docker build -t lab-node:96 "$(cygpath -m "$PWD/images/node")" 2>&1 | tail -1 && docker run --rm lab-node:96 cat /etc/rocky-release
```

```out
 => => naming to docker.io/library/lab-node:96
Rocky Linux release 9.6 (Blue Onyx)
```

映像裡沒有 cpuser，也沒有 sudo 規則：帳號、sshd 設定、公鑰、安裝期的完整 sudo（對應「變更窗口內由 OS 團隊開放」，正式環境做完要收回）都在 3.1 由銀行 OS 團隊的區塊做。

### 0.5.2 銀行的套件庫 web server（repo01）

（lab 專用）這一節建出模擬銀行套件庫的網站，3.2 節與第 4 章把 OS 套件與 Confluent RPM 放上去。銀行自己管的 httpd，只有 HTTPS，唯讀；部署帳號 `repodeploy` 可以用 ssh 寫 `/var/www/repo`，沒有 sudo、沒有 `createrepo_c`：

```bash
cat > images/web/Dockerfile <<'EOF'
FROM lab-node:96
RUN dnf -y --enablerepo=vault96-baseos,vault96-appstream install httpd mod_ssl && dnf clean all \
    && sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/*.repo \
    && useradd -m -s /bin/bash repodeploy && install -d -o repodeploy -g repodeploy -m 0755 /var/www/repo \
    && rm -f /etc/httpd/conf.d/welcome.conf /etc/httpd/conf.d/ssl.conf \
    && sed -i 's/^Listen 80$/# Listen 80/' /etc/httpd/conf/httpd.conf \
    && printf 'Match User repodeploy\n    AllowTcpForwarding no\n    X11Forwarding no\n' > /etc/ssh/sshd_config.d/20-repo.conf \
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
docker build -t lab-web:96 "$(cygpath -m "$PWD/images/web")" 2>&1 | tail -1
```

```out
 => => naming to docker.io/library/lab-web:96
```

憑證 `repo.crt`、`repo.key` 等銀行 CA 建好後再簽（0.5.5）。

### 0.5.3 銀行的 AD（Samba AD DC）

（lab 專用）這一節建出模擬銀行 AD 的主機，3.4 節在裡面建群組與帳號。RHEL 系的 Samba 沒有 AD DC 功能，所以這一台用 Debian。第一次啟動時建網域 `CORP.POC.LAB`，之後只是把 samba 跑著：

```bash
cat > images/ad/Dockerfile <<'EOF'
FROM debian:12-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends samba samba-ad-dc samba-ad-provision winbind krb5-user ldb-tools ldap-utils openssh-server sudo procps ca-certificates openssl \
    && rm -rf /var/lib/apt/lists/* && rm -f /etc/samba/smb.conf
RUN install -d -m 0755 /run/sshd \
    && printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nUseDNS no\n' > /etc/ssh/sshd_config.d/10-cp.conf
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

（lab 專用）這一節建出模擬銀行負載平衡的 nginx，3.5 節設定轉發到兩台 REST Proxy。

```bash
cat > images/lb/Dockerfile <<'EOF'
FROM nginx:1.28
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server sudo procps && rm -rf /var/lib/apt/lists/* \
    && install -d -m 0755 /run/sshd /etc/nginx/stream.d \
    && printf 'PermitRootLogin no\nPasswordAuthentication no\nPubkeyAuthentication yes\nUseDNS no\n' > /etc/ssh/sshd_config.d/10-cp.conf \
    && printf '\nstream {\n    include /etc/nginx/stream.d/*.conf;\n}\n' >> /etc/nginx/nginx.conf && rm -f /etc/nginx/conf.d/default.conf \
    && printf '#!/bin/sh\n/usr/sbin/sshd\nexec nginx -g "daemon off;"\n' > /usr/local/sbin/lb-entrypoint && chmod 0755 /usr/local/sbin/lb-entrypoint
ENTRYPOINT ["/usr/local/sbin/lb-entrypoint"]
EOF
docker build -t lab-lb:1 "$(cygpath -m "$PWD/images/lb")" 2>&1 | tail -1 && docker images --format '{{.Repository}}:{{.Tag}}' | grep -cE '^lab-(node:96|web:96|ad:1|lb:1)$'
```

```out
 => => naming to docker.io/library/lab-lb:1
4
```

### 0.5.5 銀行的 CA：根憑證、簽發 CA、簽發程序

@role 銀行 CA 窗口 | Windows 終端 | 本機

（lab 專用）這一節建出模擬銀行 CA 的簽發工具，3.4 與 9.2 節用它簽憑證。正式環境這是行內 PKI；lab 裡：用 openssl 建一個兩層 CA（根 CA 離線保存，簽發 CA 簽日常憑證）：

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

（lab 專用）這一節用 docker compose 一次定義所有主機與網路，並產生共用的密碼檔。14 台主機、一個不連外的內部網路。操作機有兩個專用的 volume：`ops-home`（掛在 `/root`，操作機上的工作目錄）和 `ops-secure`（掛在 `/secure/ssh`，模擬放 ssh 私鑰的**獨立 file system**：獨立的掛載點、容器重啟還在；LUKS 加密無法在 lab 模擬，所以沒有加密）。AD 的管理員密碼放在 `secrets.env`：

```bash
cd ~/kafka-lab && [ -f secrets.env ] || { until p=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20); [[ $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] ]]; do :; done; (umask 077; printf 'AD_ADMIN_PASSWORD=%s\n' "$p" > secrets.env); unset p; }; cat > compose.yml <<'EOF'
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
  image: lab-node:96
  domainname: poc.lab
  privileged: true
  cgroup: host
  stop_signal: SIGRTMIN+3
  tmpfs: [ /run, /run/lock, "/tmp:exec,mode=1777,size=2g" ]
  volumes:
    - /sys/fs/cgroup:/sys/fs/cgroup:rw
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
      - ops-home:/root
      - ops-secure:/secure/ssh
  repo01:
    <<: *node
    image: lab-web:96
    hostname: repo01
    networks: { labnet: { ipv4_address: 172.35.0.14 } }
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
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
  ops-home:
  ops-secure:
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

（lab 專用）這一節建出第 1 章用的外網下載機 dl01。下載機要能連外網，所以不在 `labnet` 裡；它的 `/out` 掛到 `~/kafka-lab/landing`，就是落地區。下載機用的 OS repo 也停在 9.6（vault），這樣第 1 章列給銀行的 OS 套件版本才是 9.6 的：

```bash
docker run -d --name dl01 --hostname dl01 -v "$(cygpath -m "$HOME/kafka-lab/landing"):/out" lab-node:96 sleep infinity >/dev/null && docker exec dl01 bash -c 'dnf config-manager --set-enabled vault96-baseos vault96-appstream vault96-extras; curl -s -o /dev/null -w "internet: %{http_code}\n" https://packages.confluent.io/rpm/8.2/'
```

```out
internet: 200
```

### 0.5.8 進入各台機器

（lab 專用）整本手冊切換主機都用 `docker exec`；正式環境則是從操作機 ssh 到各台。之後會一直用到的三條（換主機名稱即可）：

```bash
docker exec -it dl01 bash
```

```bash
docker exec -it -w /root lab-ops02-1 bash
```

```bash
docker exec -it lab-repo01-1 bash
```

第一個是下載機（root），第二個是操作機（root），第三個是銀行的主機（root，扮演銀行時用）。

**操作機一律以 root 進**：正式環境人員是在 CyberArk 的 PVWA 網頁選操作機、按連線，由 PSMP 代登進去，進去就是 root；lab 沒有 PVWA、PSMP，用上面第二條 `docker exec` 直接進，就等於「PSMP 代登之後」的狀態。連其他主機不靠 `docker exec`，而是在操作機上用 cpuser 的金鑰 ssh（3.1）。

### 0.5.9 收工與重開

（lab 專用）暫停、繼續與重建 lab 的方法。想暫停：`cd ~/kafka-lab && docker compose -f compose.yml stop`，資料都在 volume 裡；繼續：`docker compose -f compose.yml start`。Windows 重開機後容器會自己起來（`restart: unless-stopped`），Kafka 服務設了 enable 也會自己起來；只有下載機 dl01 要手動 `docker start dl01`。操作機重開後 `/secure/ssh` 的 volume 還在，金鑰不用重放（正式環境那個加密的 file system 要先解鎖、掛載好，ssh 才連得上各主機，見 3.1）。全部清掉重來：`docker compose -f compose.yml down -v && docker rm -f dl01`（落地區 `~/kafka-lab/landing` 不會被刪）。

> 陷阱：要重跑第 0 章（重建映像、重產 CA）之前**一定先 `down -v`**。只 `down` 或直接再 `up -d` 會留下舊的 volume：操作機的 `~/pki`、`~/conf` 還是舊 CA 簽的、AD 裡帳號已存在，後面第 3、9 章會出現「鏈驗證失敗」「ou already exists」這類看似莫名的錯。

# 1. 第一站：外網下載機

![download]

**這一章在做什麼**：在唯一能連外網的下載機 dl01 上，把安裝要用的檔案抓齊、驗過簽章，整批打包成清單，下一章送進銀行內網。全部由我方（小安）做，不需要銀行配合；之後的主機都離線，缺了什麼檔案只能再回來這一章補。

小安的第一個任務：把 Confluent 的套件抓下來，而且只抓需要的。這次要抓**兩套**：安裝基底（Confluent Platform 8.2.4＋Control Center 2.5.1）放 `/out/rpm`，遷移目標（8.3.2＋2.6.1）放 `/out/rpm-target`，一次掃描、一次送進去，遷移（第 21 章）時就不用再開一次單。Java 和 OS 套件不下載，那是銀行的事（lab 的下載機只替銀行抓兩個 JDK，見 1.5）。

## 1.1 設定 Confluent repo、匯入原廠公鑰

先讓下載機信任 Confluent 的簽章公鑰、設好三個原廠 repo（8.2、8.3、Control Center），後面才能下載並驗證套件。

@role 小安 | dl01 | root

```bash
mkdir -p /out/rpm /out/rpm-target /out/gpg-keys /out/tools && curl -fsSL https://packages.confluent.io/rpm/8.2/archive.key -o /out/gpg-keys/confluent.asc && curl -fsSL https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key -o /out/gpg-keys/confluent-c3.asc && rpm --import /out/gpg-keys/confluent.asc /out/gpg-keys/confluent-c3.asc && rpm -q gpg-pubkey --qf '%{SUMMARY}\n' | grep -i confluent
```

```out
Confluent Packaging <packages@confluent.io> public key
```

指令成功時只會出現一行：三個網址（8.2、8.3、C3）給的其實是同一把公鑰（sha256 相同），8.2 和 8.3 共用，只存一份 `confluent.asc`。

```bash
cat > /etc/yum.repos.d/confluent.repo <<'EOF'
[confluent-8.2]
name=Confluent 8.2
baseurl=https://packages.confluent.io/rpm/8.2
gpgcheck=1
gpgkey=https://packages.confluent.io/rpm/8.2/archive.key
enabled=1

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
dnf list --showduplicates confluent-server confluent-control-center-next-gen | grep -E '8\.(2\.4|3\.2)|2\.(5\.1|6\.1)'
```

```out
confluent-control-center-next-gen.noarch         2.5.1-1           confluent-c3
confluent-control-center-next-gen.noarch         2.6.1-1           confluent-c3
confluent-server.noarch                          1:8.2.4-1         confluent-8.2
confluent-server.noarch                          1:8.3.2-1         confluent-8.3
```

確認 8.2.4、8.3.2、2.5.1、2.6.1 四個都在清單裡就好（grep 只留了這四行）。

> **為什麼基底的 C3 是 2.5.1，不是最新的 2.6.1**（原廠相容表，docs.confluent.io「Versions and interoperability」，2026-10-28 查）：Control Center 2.5.x 支援 Confluent Platform「7.5.11 以上、7.6.8 以上，到 8.2.x」；2.6.x 才支援「到 8.3.x」（2.6.x 的下限寫 7.5.15 以上，所以 2.6.x 也能配 8.2.x）。安裝基底是 CP 8.2.4，用 2.5 系列最新的 2.5.1，**和 CP 的相容範圍剛好對上**；遷移到 8.3 之前 C3 必須先升到 2.6.x（21.3）。2.5.1 與 2.6.1 的 RPM 只相依 bash，套件預設設定檔（`/etc/confluent-control-center/`）逐檔比對只差 `control-center-dev.properties` 多一行 `confluent.controlcenter.docs.host`（我們不用 dev 檔），所以第 13 章的 Prometheus／Alertmanager 設定兩個版本通用。

> 上一個指令第一次執行會先下載 repo 的中繼資料（幾十 MB），等一兩分鐘是正常的。

## 1.2 下載：兩套精確版本

@role 小安 | dl01 | root

`--resolve` 會把 Confluent 自己的相依一起抓；因為下載機和正式主機是同樣最小安裝，它不會多抓也不會漏抓。**每一套只開自己的 repo**（`--disablerepo='*' --enablerepo=…`）：8.2 和 8.3 的 repo 同時開著時，`--resolve` 可能把另一版的 `confluent-common` 抓進來。先抓安裝基底到 `/out/rpm`：

```bash
dnf download --resolve --arch x86_64 --arch noarch --destdir /out/rpm --disablerepo='*' --enablerepo=confluent-8.2,confluent-c3 confluent-server-8.2.4 confluent-security-8.2.4 confluent-kafka-rest-8.2.4 confluent-cli-8.2.4 confluent-control-center-next-gen-2.5.1
```

再抓遷移目標到 `/out/rpm-target`：

```bash
dnf download --resolve --arch x86_64 --arch noarch --destdir /out/rpm-target --disablerepo='*' --enablerepo=confluent-8.3,confluent-c3 confluent-server-8.3.2 confluent-security-8.3.2 confluent-kafka-rest-8.3.2 confluent-cli-8.3.2 confluent-control-center-next-gen-2.6.1
```

每套約 3 GB。lab 裡：落地區是 Windows 資料夾，最後核對檔案那段會慢（看起來像卡在 99%），耐心等它結束。

```bash
for d in rpm rpm-target; do echo "== $d"; ls /out/$d | sort; ls /out/$d | wc -l; done
```

```out
== rpm
confluent-ce-kafka-http-server-8.2.4-1.noarch.rpm
confluent-cli-8.2.4-1.x86_64.rpm
confluent-common-8.2.4-1.noarch.rpm
confluent-control-center-next-gen-2.5.1-1.noarch.rpm
confluent-kafka-rest-8.2.4-1.noarch.rpm
confluent-metadata-service-8.2.4-1.noarch.rpm
confluent-rest-utils-8.2.4-1.noarch.rpm
confluent-security-8.2.4-1.noarch.rpm
confluent-server-8.2.4-1.noarch.rpm
confluent-server-rest-8.2.4-1.noarch.rpm
confluent-telemetry-8.2.4-1.noarch.rpm
11
== rpm-target
（同樣 11 個，版本是 8.3.2 與 control-center-next-gen-2.6.1）
11
```

兩套各 11 個，全部是 `confluent-*`。

## 1.3 驗原廠簽章、確認相依

兩件事：確認每個 RPM 的簽章是 Confluent 簽的、沒被改過；確認這些 RPM 除了 bash 和 glibc 之外不依賴任何 OS 套件（這樣銀行的 OS 套件庫不用為 Confluent 額外準備東西）。

@role 小安 | dl01 | root

```bash
rpm -K /out/rpm/*.rpm /out/rpm-target/*.rpm
```

```out
/out/rpm/confluent-ce-kafka-http-server-8.2.4-1.noarch.rpm: digests signatures OK
（22 行，每一行都是 digests signatures OK）
```

Confluent 的 RPM 需要哪些非 Confluent 的東西？答案應該只有 bash 和 glibc：

```bash
rpm -qpR /out/rpm/*.rpm /out/rpm-target/*.rpm 2>/dev/null | grep -vE '^(confluent-|rpmlib\(|config\()' | sort -u | xargs -d '\n' rpm -q --whatprovides | sort -u
```

```out
bash-5.1.8-9.el9.x86_64
glibc-2.34-168.el9_6.24.x86_64
（版本號依映像而異，重點是只有這兩個）
```

## 1.4 監控用的 jar 與官方規則、給銀行的 OS 套件清單

@role 小安 | dl01 | root

第 17 章的監控需要 JMX exporter（Prometheus 用的 Java agent jar）和 Confluent 官方的規則檔，這兩樣都不是 RPM，要另外抓。先抓 jar，用 Maven Central 公布的 sha1 核對：

```bash
curl -fsSL -o /out/tools/jmx_prometheus_javaagent-1.0.1.jar https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar && [ "$(sha1sum /out/tools/jmx_prometheus_javaagent-1.0.1.jar | cut -d' ' -f1)" = "$(curl -fsSL https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar.sha1)" ] && echo jar-sha1-ok
```

```out
jar-sha1-ok
```

Confluent 官方的監控檔（exporter 規則、告警規則、Grafana dashboard）在 GitHub 的 confluentinc/jmx-monitoring-stacks（Apache-2.0）。**固定在一個 commit**（`f376263f…`，2026-05-28），不跟 main 走：第 17 章的 dashboard 與規則是照這一版的指標名稱寫的。只取要用的路徑（32 個 dashboard、告警規則、controller／broker／REST 三份 exporter 規則），jar 不拿（用上面 Maven Central 驗過的那個）。`COMMIT` 檔記下版本，之後每一關的 `SHA256SUMS` 也會涵蓋它們：

```bash
SHA=f376263fc6d7270185ab6abab9a8c379079e2a92 && mkdir -p /out/monitoring /tmp/jms-x && curl -fsSL "https://github.com/confluentinc/jmx-monitoring-stacks/archive/$SHA.tar.gz" | tar -xz -C /tmp/jms-x --wildcards '*/LICENSE' '*/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards/*' '*/jmxexporter-prometheus-grafana/assets/grafana/provisioning/datasources/*' '*/jmxexporter-prometheus-grafana/assets/prometheus/*' '*/shared-assets/jmx-exporter/kafka_broker.yml' '*/shared-assets/jmx-exporter/kafka_controller.yml' '*/shared-assets/jmx-exporter/confluent_rest.yml' && rm -rf /out/monitoring/jmx-monitoring-stacks && mv /tmp/jms-x/jmx-monitoring-stacks-* /out/monitoring/jmx-monitoring-stacks && echo "$SHA" > /out/monitoring/jmx-monitoring-stacks/COMMIT && rm -rf /tmp/jms-x && echo "commit ${SHA:0:12}: $(find /out/monitoring -type f | wc -l) 個檔，dashboard $(ls /out/monitoring/jmx-monitoring-stacks/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards/*.json | wc -l) 個"
```

```out
commit f376263fc6d7: 47 個檔，dashboard 32 個
```

平台還需要幾個 OS 套件，由銀行的套件庫提供。先確認它們都在 RHEL 標準 repo 裡、在哪個 repo，做成清單交給銀行。**版本號是下載機的 OS repo（停在 9.6，0.5.7）的內容**：銀行的套件庫之後同步到 9.8 時這幾個會更新（26.5）：

```bash
dnf -q repoquery --latest-limit 1 --qf '%{name}\t%{version}-%{release}\t%{repoid}' chrony firewalld cyrus-sasl openssl-devel python3-dnf-plugin-versionlock gettext createrepo_c | sort -u | tee /out/os-packages.txt
```

```out
chrony	4.6.1-1.el9	vault96-baseos
createrepo_c	0.20.1-2.el9	vault96-appstream
cyrus-sasl	2.1.27-21.el9	vault96-appstream
cyrus-sasl	2.1.27-21.el9	vault96-baseos
firewalld	1.3.4-15.el9_6	vault96-baseos
gettext	0.21-8.el9	vault96-baseos
openssl-devel	3.2.2-6.el9_5.1	vault96-appstream
python3-dnf-plugin-versionlock	4.3.0-20.el9	vault96-baseos
```

| 套件 | 哪些主機 | 為什麼 |
|---|---|---|
| chrony、firewalld | 全部 | 時間同步、主機防火牆 |
| cyrus-sasl、openssl-devel | C3 | 原廠文件要求的前置套件 |
| python3-dnf-plugin-versionlock | 裝 Confluent 的主機 | 鎖版本，避免 OS 例行更新把 Confluent 升掉 |
| gettext、createrepo_c | 操作機 | `envsubst` 由範本產生設定檔；建內部套件庫的索引（第 4 章） |

銀行的 OS 套件庫本來就是完整的 RHEL，這份清單只是讓銀行確認這幾個在。lab 在 3.2 自己建 `/os/` 時多放了 httpd、jq、openldap-clients 等，那是 lab 主機自己要用的工具，不是交給銀行的需求。

## 1.5 順便替銀行抓 JDK（銀行交付的檔案）

@role 銀行 OS 團隊（lab 由下載機代勞） | dl01 | root

正式環境 JDK 是銀行交付的；lab 沒有銀行，就用這台下載機從 Adoptium 抓 Temurin，連同官方的 sha256 一起放到 `/out/bank/`，當作「銀行給的檔案」。**要兩個**：JDK 21 給安裝基底（第 5 章）；JDK 25 留到遷移（21.7）才裝——8.2.x 不支援 Java 25，所以基底一定是 21，但 25 先一起帶進來，遷移時不用再送一次：

```bash
mkdir -p /out/bank && for v in 21 25; do meta=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/$v/hotspot?os=linux&architecture=x64&image_type=jdk&vendor=eclipse") && url=$(echo "$meta" | grep -o '"link": *"[^"]*\.tar\.gz"' | head -1 | cut -d'"' -f4) && sha=$(echo "$meta" | grep -o '"checksum": *"[0-9a-f]\{64\}"' | head -1 | cut -d'"' -f4) && f=$(basename "$url") && curl -fsSL -o "/out/bank/$f" "$url" && echo "$sha  $f" > "/out/bank/$f.sha256" && (cd /out/bank && sha256sum -c --quiet "$f.sha256" && echo "jdk-ok: $f"); done
```

```out
jdk-ok: OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz
jdk-ok: OpenJDK25U-jdk_x64_linux_hotspot_25.0.x_y.tar.gz
```

檔名裡的版本號跟著 Adoptium 當下的最新版走，之後的指令用 `OpenJDK21U-*`、`OpenJDK25U-*` 加萬用字元找它，不用改。

## 1.6 整批的雜湊清單

@role 小安 | dl01 | root

```bash
cd /out && find rpm rpm-target tools gpg-keys monitoring -type f | LC_ALL=C sort | xargs sha256sum > SHA256SUMS && wc -l SHA256SUMS
```

```out
72 SHA256SUMS
```

22 個 RPM（基底 11、目標 11）、1 個 jar、2 把公鑰、47 個官方監控檔（含 `COMMIT`）（JDK 是銀行的檔案，有自己的 sha256，不列在這裡）。這份 `SHA256SUMS` 之後每一關都會再用一次。下載機的工作到此結束。

# 2. 第二站：把東西送進銀行

![intake]

**這一章在做什麼**：把上一章打包好的檔案送進內網的操作機。路上有三道關：資安掃描（2.1，銀行資安）、檔案交換（2.2，銀行）、進內網後我方用 `SHA256SUMS` 再驗一次（2.3，小安）。這一章做完，操作機的 `~/landing` 就是之後所有安裝的唯一來源。

## 2.1 掃描與開單

@role 銀行 資安 | 行內掃描平台 | —

正式環境：落地區的檔案上傳到行內的惡意程式掃描平台取得 OK 報告，開單時附上安裝檔、掃描報告、`SHA256SUMS`。注意 `confluent-security`（約 1 GB）和 C3（約 1 GB）單檔都超過 1 GB，要先確認平台的大小上限；兩套合計約 6 GB。lab 裡：略過這一步。

## 2.2 檔案交換：送到操作機

下面這張圖說明落地區裡每個目錄是什麼、之後各自送去哪裡用。

![landing]

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

正式環境由行內的檔案交換平台把核准的檔案送到操作機的 `~/landing`（root 的家目錄底下）。lab 裡：用 `docker cp` 模擬這個平台；送進去之後把目錄設成唯讀（對 root 其實擋不住寫入，只是約定「落地區的檔案不改」）：

```bash
docker cp "$(cygpath -m "$HOME/kafka-lab/landing")/." lab-ops02-1:/root/landing/ && docker exec lab-ops02-1 bash -c 'chmod -R a-w /root/landing && find /root/landing -type f | wc -l && du -sh /root/landing'
```

```out
78
6.2G	/root/landing
```

78 個檔：兩套 RPM 各 11、1 個 jar、2 把公鑰、47 個官方監控檔、`SHA256SUMS`、`os-packages.txt`、`bank/` 的兩個 JDK 各兩個檔（tar 與 .sha256）。

## 2.3 進內網後再驗一次

@role 小安 | ops02 | root

這是第二道驗證（第一道是 dl01 上的 1.6）：證明搬運途中沒被動過，用的是一起送進來的 `SHA256SUMS`。看到 `72 files OK` 才往下；有任何一個檔不符就退回銀行重送，不要裝：

```bash
cd ~/landing && sha256sum -c --quiet SHA256SUMS && echo "$(wc -l < SHA256SUMS) files OK"
```

```out
72 files OK
```

接著再驗一次原廠簽章。`rpm -K` 只認 rpm 資料庫裡的公鑰，所以先把隨包送進來的公鑰匯入（22 個 RPM 都要是 `digests signatures OK`）：

```bash
rpm --import ~/landing/gpg-keys/confluent.asc ~/landing/gpg-keys/confluent-c3.asc && rpm -K ~/landing/rpm/*.rpm ~/landing/rpm-target/*.rpm
```

```out
/root/landing/rpm/confluent-ce-kafka-http-server-8.2.4-1.noarch.rpm: digests signatures OK
（22 行都 OK）
```

## 2.4 之後再帶進來的檔案

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

延伸章節還會陸續帶檔案進來：16.3 的選單套件（`tools/opmenu`）、第 27 章單獨換 C3 版本時的單一 RPM。遷移用的新版 RPM 與 JDK 25 已經在第 1、2 章一起進來了（`rpm-target/`、`bank/`），第 21 章只是把它們上架。流程和第 2 章一樣（掃描、交換、進來後驗 sha256），只是一次送一個目錄。`~/landing` 是唯讀的，所以放進去再收回寫入權限（`D` 換成要送的目錄）；操作機上已經有同名的目錄會先清掉再送，所以同一個目錄換新版也是這一條。落地區還沒有那個目錄就什麼都不做：

```bash
D=opmenu; [ -d "$HOME/kafka-lab/landing/tools/$D" ] || { echo "落地區還沒有 tools/$D（有檔案要送時再做）"; exit 0; }; docker exec lab-ops02-1 bash -c "chmod -R u+w /root/landing/tools/$D 2>/dev/null; rm -rf /root/landing/tools/$D" && docker cp "$(cygpath -m "$HOME/kafka-lab/landing/tools/$D")" lab-ops02-1:/root/landing/tools/ && docker exec lab-ops02-1 bash -c "chmod -R a-w /root/landing/tools/$D && cd /root/landing/tools/$D && ls && sha256sum -c --quiet SHA256SUMS && echo sha256-ok"
```

```out
SHA256SUMS
opmenu-20261023.0655fe43.tar.gz
sha256-ok
```

# 3. 第三站：銀行準備好了嗎

![bankprep]

**這一章在做什麼**：安裝之前，銀行各團隊要先把主機帳號、SSH 公鑰、OS 套件庫、JDK、AD、NTP、負載平衡準備好。這一章全部是銀行的工作，lab 裡由你扮演；正式環境你不做，只要確認結果（第 6 章的安裝前檢查會逐項看）。哪一項銀行還沒給，後面就會在那裡卡住。

開主機的時候，原廠對虛擬機與磁碟有幾條硬性建議，要在開單時就交代給 OS／虛擬化團隊（lab 是容器，沒有這些）：

| 項目 | 原廠建議 | 為什麼 |
|---|---|---|
| VMware vMotion、磁碟快照 | 平台主機**停用** | 原廠：用在 Kafka／KRaft 上可能造成整個叢集中斷 |
| 資料碟 | broker 的 Kafka 資料放在**獨立的磁碟**，不和 OS、應用程式日誌共用 | 寫入延遲要穩定 |
| RAID | RAID 10（或 RAID 1）優先；**不建議 RAID 5** | 重建期間效能與可靠度 |
| 檔案系統 | XFS 或 ext4 | 原廠只支援這兩種（第 6 章會檢查） |
| JDK | 完整 JDK（不是 headless／JRE） | 原廠支援排錯時需要（這本用的 Temurin tar 就是完整 JDK） |

## 3.1 安裝帳號 cpuser 與 SSH 金鑰

下面這張圖畫的是：人怎麼進操作機，操作機又怎麼連到每一台主機。

![access]

**這一節在做什麼**：先由銀行 OS 團隊在每台主機建好安裝帳號 `cpuser`，小安在操作機產生 SSH 金鑰對，OS 團隊把公鑰放進每台主機，最後驗證「只有操作機能用這把金鑰登入」。這一節把「人怎麼進操作機」和「操作機怎麼連各主機」分開（完整設計見《CyberArk 登入與主機存取設計》）：

| 項目 | 做法 |
|---|---|
| 人怎麼進操作機 | 人員用瀏覽器登入 CyberArk 的 PVWA 網頁（自己的 AD 帳密加 MFA），選操作機的目標帳號按連線，由 PSMP 代登進操作機，進去就是 **root**；全程錄影，人員不需要知道 root 的密碼。沒有另外的堡壘機 |
| 連各主機用誰 | 每台主機（含操作機自己）都有同名的本機帳號 **`cpuser`**：UID／GID 固定 1500、家目錄 `/home/cpuser`、密碼鎖定、sshd 對它關閉密碼驗證，只收金鑰。人員永遠是 AD 帳號；連主機的不是人，是操作機用金鑰代表的 cpuser |
| 金鑰 | 一組 ed25519 金鑰對，**私鑰只在操作機**：放在獨立（加密）的 file system `/secure/ssh`（名稱只是範例），擁有者 root、0400、沒有 passphrase。操作機到所有主機（含自己）都用它。**不放 CyberArk、不另外備份**：操作機重建就重新產生，由 OS 團隊重新佈署公鑰 |
| 公鑰 | OS 團隊依變更單放進每台 cpuser 的 `authorized_keys`，前面只加來源限制 `from="操作機 IP,127.0.0.1,::1"`（不加 `restrict`、`pty`） |
| sudo | 安裝與升級期 cpuser 全權（`/etc/sudoers.d/cpuser`，OS 團隊依變更單開、交付時移除）；交付後只剩 16.4 的 `cpuser-ops` |
| 追溯 | 誰在什麼時間進了操作機的 root：CyberArk 的登入紀錄與 PSMP 錄影；各主機上看到的是 cpuser 的操作紀錄 |

lab 裡：正式環境才有的三樣東西，這樣模擬：
- **沒有 PVWA、PSMP**：你用 `docker exec -it -w /root lab-ops02-1 bash` 直接以 root 進操作機，就是「PSMP 代登之後」。Windows 上的 `~/kafka-lab/pvwa/` 資料夾仍用來模擬 PVWA 裡的平台密碼（「存進 PVWA」＝放進這個資料夾，「從 PVWA 取出」＝從這個資料夾複製貼上），但**不放 ssh 私鑰**。
- **沒有 LUKS**：`/secure/ssh` 是 0.5.6 compose 裡的獨立 docker volume `ops-secure`，只模擬「獨立的 file system」（獨立掛載點、容器重啟還在），沒有加密。
- **沒有 CPM**：root 與 `svc-mds-bind` 的輪替只在正式環境。

### 3.1.1 每台主機建 cpuser（銀行 OS 團隊）

@role 銀行 OS 團隊（每台主機依變更單做；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

每台主機（含操作機）以 root 做四件事：建帳號（UID／GID 固定 1500，不設密碼，useradd 預設就是鎖定）、sshd 設定、安裝期的全權 sudo。公鑰等操作機產生金鑰後（3.1.3）再放。lab 對每個容器各跑一次：

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker exec -i lab-$h-1 bash -s <<'EOF'
groupadd -g 1500 cpuser && useradd -u 1500 -g 1500 -m -s /bin/bash cpuser
printf 'Match User cpuser\n    PasswordAuthentication no\n    AuthenticationMethods publickey\n' > /etc/ssh/sshd_config.d/50-cpuser.conf
sshd -t && systemctl reload sshd
printf 'cpuser ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/cpuser && chmod 0440 /etc/sudoers.d/cpuser && visudo -cf /etc/sudoers.d/cpuser >/dev/null
echo "$(hostname): $(id cpuser)"
EOF
done
```

```out
ops02: uid=1500(cpuser) gid=1500(cpuser) groups=1500(cpuser)
（每台一行）
```

`/etc/sudoers.d/cpuser` 是安裝與升級期的全權規則，對應「變更窗口內由 OS 團隊開放」；交付時移除，只留 16.4 的窄規則。`repodeploy` 是套件庫（repo01）的部署帳號，映像裡就有，下面和 cpuser 用同一把金鑰。

### 3.1.2 在操作機建金鑰對

@role 小安 | ops02 | root

私鑰放在獨立的 file system `/secure/ssh`（正式環境由 OS 團隊掛載並加密、備份排除這個掛載點；沒掛載好就不要建，不然私鑰會落在系統碟）。先確認它是獨立的掛載點，再建金鑰：註解帶建立日期，換金鑰時用來分辨新舊兩把（19.6）。

```bash
mountpoint /secure/ssh && install -d -m 0700 /secure/ssh && { [ -f /secure/ssh/cpuser_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "cpuser-ops-$(date +%Y%m%d)" -f /secure/ssh/cpuser_ed25519; } && chmod 0400 /secure/ssh/cpuser_ed25519 && stat -c '%U:%G %a %n' /secure/ssh /secure/ssh/cpuser_ed25519 /secure/ssh/cpuser_ed25519.pub
```

```out
/secure/ssh is a mountpoint
root:root 700 /secure/ssh
root:root 400 /secure/ssh/cpuser_ed25519
root:root 644 /secure/ssh/cpuser_ed25519.pub
```

再告訴 ssh：連 `*.poc.lab`（含操作機自己，用 `localhost` 連時 ssh 也走這條）一律用 cpuser 與這把金鑰。之後所有 `ssh kb01.poc.lab`、`scp` 都不用再帶帳號與 `-i`：

```bash
install -d -m 0700 ~/.ssh && { grep -q '^# cpuser-ops' ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config <<'EOF'
# cpuser-ops：操作機連各主機一律用 cpuser 與這把金鑰
Host *.poc.lab localhost
  User cpuser
  IdentityFile /secure/ssh/cpuser_ed25519
  IdentitiesOnly yes
EOF
} && chmod 0600 ~/.ssh/config && grep -c . ~/.ssh/config
```

```out
5
```

### 3.1.3 公鑰放進每台主機（銀行 OS 團隊）

下面這張圖列出這把金鑰相關的每個檔案放在哪裡、權限多少、誰放的。

![keyfiles]

@role 銀行 OS 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

小安把公鑰（`/secure/ssh/cpuser_ed25519.pub`，不是祕密）交給 OS 團隊。OS 團隊依變更單放進**每台主機 cpuser 的 `~/.ssh/authorized_keys`（含操作機自己）**，以及 repo01 的 repodeploy。公鑰前面只加一個選項 `from=`：只有操作機的位址能用這把金鑰（寫 IP，不寫主機名稱，避免 DNS 異常誤擋）。**整行不換行，多個來源用逗號分隔、不加空格**：

```
from="10.20.1.10,127.0.0.1,::1" ssh-ed25519 AAAA…（金鑰內容） cpuser-ops-20261027
```

操作機連自己時，sshd 看到的來源可能是操作機本身的 IP、`127.0.0.1` 或 `::1`（用 `localhost` 連時 ssh 先走 IPv6），三個都要列。lab 的操作機 IP 是 172.35.0.10。目錄 0700、檔 0600、擁有者 cpuser：

```bash
PUB=$(docker exec lab-ops02-1 cat /secure/ssh/cpuser_ed25519.pub) && LINE="from=\"172.35.0.10,127.0.0.1,::1\" $PUB" && for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker exec -e LINE="$LINE" lab-$h-1 bash -c 'install -d -m 0700 -o cpuser -g cpuser /home/cpuser/.ssh && printf "%s\n" "$LINE" > /home/cpuser/.ssh/authorized_keys && chown cpuser:cpuser /home/cpuser/.ssh/authorized_keys && chmod 0600 /home/cpuser/.ssh/authorized_keys'; done && docker exec -e LINE="$LINE" lab-repo01-1 bash -c 'install -d -m 0700 -o repodeploy -g repodeploy /home/repodeploy/.ssh && printf "%s\n" "$LINE" > /home/repodeploy/.ssh/authorized_keys && chown repodeploy:repodeploy /home/repodeploy/.ssh/authorized_keys && chmod 0600 /home/repodeploy/.ssh/authorized_keys' && echo "$LINE" | sed 's/AAAA[^ ]*/AAAA…/'
```

```out
from="172.35.0.10,127.0.0.1,::1" ssh-ed25519 AAAA… cpuser-ops-20261027
```

### 3.1.4 驗證：登得進去、密碼鎖定、sshd 只收金鑰

@role 小安 | ops02 | root

逐台連一次（第一次連線會把對方的主機金鑰記進 `known_hosts`），順便看帳號是 cpuser、UID 是 1500、有安裝期 sudo、密碼是鎖定的（`/etc/shadow` 的密碼欄以 `!` 開頭）、sshd 對 cpuser 關閉密碼驗證且只收 publickey：

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new $h.poc.lab bash -s <<'EOF'
echo "$(id -un) $(hostname) uid=$(id -u) sudo=$(sudo -n true 2>/dev/null && echo yes || echo no) 密碼欄=$(sudo getent shadow cpuser | cut -d: -f2 | cut -c1-2) sshd=$(sudo sshd -T -C user=cpuser,host=localhost,addr=127.0.0.1 | awk '/^passwordauthentication /{p=$2} /^authenticationmethods /{m=$2} END{print p, m}')"
EOF
done; ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new repodeploy@repo01.poc.lab 'hostname; ls /var/www/repo'
```

```out
Warning: Permanently added 'ops02.poc.lab' (ED25519) to the list of known hosts.
cpuser ops02 uid=1500 sudo=yes 密碼欄=!! sshd=no publickey
（每台一句 Warning 加一行）
repo01
```

清單包含操作機自己（之後的迴圈會 `ssh ops02` 檢查自己這台）。第一次連線的 `Warning: Permanently added …` 是把主機金鑰記進 `known_hosts`，不是錯誤。repo01 的 `/var/www/repo` 這時還是空的，下一站才會放東西。

### 3.1.5 驗證：別台用這把私鑰連不進來

@role 小安（把私鑰副本放到 kb01 去用，模擬私鑰被複製；lab 由 Windows 終端代做） | Windows 終端 | 本機

`from=` 的用意：就算私鑰被複製到別處，也只有操作機能用。把私鑰副本放到 kb01、從 kb01 連 kb02，應該被拒；kb02 的 sshd 日誌會寫下「不是來自允許的主機」。驗完立刻刪掉副本：

```bash
docker exec lab-ops02-1 cat /secure/ssh/cpuser_ed25519 | docker exec -i lab-kb01-1 bash -c 'cat > /tmp/copied-key && chmod 0600 /tmp/copied-key' && docker exec lab-kb01-1 ssh -F /dev/null -i /tmp/copied-key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no cpuser@kb02.poc.lab true 2>&1 | tail -1; docker exec lab-kb01-1 rm -f /tmp/copied-key; docker exec lab-kb02-1 journalctl -u sshd --no-pager -n 30 | grep -o 'not from a permitted host.*' | tail -1 | cut -c1-90
```

```out
cpuser@kb02.poc.lab: Permission denied (publickey).
not from a permitted host (host=kb01.poc.lab, ip=172.35.0.31, public key ED25…
```

> 說明：
> - **操作機重開機**：`/secure/ssh` 要先掛載（解鎖）好；沒掛載時 ssh 找不到金鑰、連不上各主機，需要有處理流程（誰解鎖、怎麼解）。lab 的 volume 重開還在。
> - **操作機重建**：重新產生金鑰對（3.1.2），由 OS 團隊重新佈署公鑰（3.1.3）；舊私鑰不備份、也找不回來。
> - **換金鑰**（人工、不中斷）見 19.6。**sudo 全權收回**見 16.4、19.5。
> - 人員進操作機就是 root，root 讀得到私鑰。防護不靠「人讀不到」，而靠：`from=`（私鑰被複製也用不了）、獨立加密的 file system 與排除備份（磁碟、快照被取走讀不出）、PVWA 的權限與 PSMP 錄影（誰在什麼時間進了 root）、主機端的 sudoers（16.4）。

## 3.2 OS 套件來源與根憑證信任

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

**這一節在做什麼**：讓每台主機能向行內的 OS 套件庫裝套件（第 5–8 章要用），並信任銀行的根憑證（之後 HTTPS 都靠它）。正式環境這是 Satellite 或 Nexus，銀行已經做好；lab 裡：用 repo01 的 `/os/` 路徑模擬。銀行的套件庫**起初是 9.6 的內容**（安裝基底，26.5 才同步到 9.8）。先在一個乾淨容器把需要的 OS 套件從 Rocky vault 的 9.6 抓下來並建索引，放在 `~/kafka-lab/bank-os/9.6`（這是銀行套件庫的內容，不是我們交付的檔案，所以不在落地區）。**先下載、再裝工具**，順序反了會漏掉工具自己的相依：

```bash
cd ~/kafka-lab && mkdir -p bank-os/9.6 && docker run --rm -v "$(cygpath -m "$PWD/bank-os/9.6"):/out" lab-node:96 bash -c '
set -e
R="--disablerepo=* --enablerepo=vault96-baseos,vault96-appstream,vault96-extras"
ok=0; for try in 1 2 3; do dnf -q $R download --resolve --arch x86_64 --arch noarch --destdir /out/Packages chrony firewalld cyrus-sasl openssl-devel httpd mod_ssl python3-dnf-plugin-versionlock nmap-ncat jq gettext openldap-clients createrepo_c tar gzip openssl sudo openssh-server diffutils less vim-minimal bind-utils lsof procps-ng rsync bash-completion && { ok=1; break; }; echo "鏡像站還沒同步好，60 秒後重試（第 $try 次）" >&2; dnf -q clean metadata; sleep 60; done; [ $ok = 1 ]
dnf -q -y --disablerepo="*" install /out/Packages/*.rpm >/dev/null
createrepo_c -q /out
ls /out/Packages | wc -l' && docker cp "$(cygpath -m "$PWD/bank-os/9.6")/." lab-repo01-1:/var/www/repo/os/ && docker exec lab-repo01-1 bash -c 'chown -R repodeploy:repodeploy /var/www/repo/os; ls /var/www/repo/os'
```

```out
71
Packages
repodata
```

數字是 9.6 的 vault 解析出來的套件數（實測 71；「已經在映像裡的套件」不會重抓，所以比完整的相依少）。裝工具那行是用剛下載的檔案裝（`--disablerepo="*"`，不連網）：容器裡因此有 `createrepo_c`，而且狀態等於「裝好這批套件的 9.6 主機」，26.5 會用同樣的方法算出升到 9.8 要的更新集合。

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

## 3.3 JDK 21 與 25：銀行交付的 tar

@role 銀行 OS 團隊 | — | —

銀行只交付壓縮檔，不裝、不設定。lab 裡那兩個檔案在 1.5 已經由下載機抓好，隨落地區一起送到了操作機的 `~/landing/bank/`，附銀行提供的 sha256。**JDK 21 是現在要裝的（第 5 章）；JDK 25 是遷移（21.7）才用**，先放著。小安先核對一次：

@role 小安 | ops02 | root

```bash
cd ~/landing/bank && sha256sum -c --quiet *.sha256 && ls
```

```out
OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz
OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz.sha256
OpenJDK25U-jdk_x64_linux_hotspot_25.0.x_y.tar.gz
OpenJDK25U-jdk_x64_linux_hotspot_25.0.x_y.tar.gz.sha256
```

## 3.4 AD：群組、唯讀查詢帳號、LDAPS 憑證

@role 銀行 AD 團隊 | ad01 | root

**這一節在做什麼**：銀行 AD 團隊建好三個群組（權限綁群組，不綁個人）、一個給 MDS 查詢用的唯讀帳號 `svc-mds-bind`、三個測試人員，並讓 AD 提供 LDAPS（加密的 LDAP）。AD 是行內的帳號目錄，第 11 章起 MDS 靠它確認「這個人屬於哪個群組」。lab 裡：用 Samba AD 模擬。

密碼先產生到檔案，用環境變數傳進指令，不打在畫面上。AD 預設的密碼複雜度要求大寫、小寫、數字至少各一，隨機抽到不符合的就重抽（不然帳號建不起來）：

```bash
install -d -m 0700 /root/secrets && for k in bind users; do until p=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20); [[ $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] ]]; do :; done; (umask 077; printf '%s' "$p" > /root/secrets/$k.pass); done; unset p; B=DC=corp,DC=poc,DC=lab; samba-tool ou create "OU=Confluent,$B" && for ou in Users Groups Service; do samba-tool ou create "OU=$ou,OU=Confluent,$B"; done && samba-tool user create svc-mds-bind "$(cat /root/secrets/bind.pass)" --userou="OU=Service,OU=Confluent" --description="read-only LDAP bind for Confluent MDS" && for g in kafka-admins kafka-operators kafka-devs; do samba-tool group add "$g" --groupou="OU=Groups,OU=Confluent"; done && for p in alice:kafka-admins bob:kafka-operators carol:kafka-devs; do u=${p%%:*}; g=${p#*:}; samba-tool user create "$u" "$(cat /root/secrets/users.pass)" --userou="OU=Users,OU=Confluent" && samba-tool group addmembers "$g" "$u" || created=no; done; [ "${created:-yes}" = yes ] && samba-tool group listmembers kafka-admins
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

@role 銀行 AD 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

AD 團隊把 svc-mds-bind 的密碼和測試人員的密碼存進 PVWA（lab：pvwa/ 資料夾）：

```bash
cd ~/kafka-lab && mkdir -p pvwa && for k in bind:ldap-bind users:ad-test-users; do (umask 077; docker exec lab-ad01-1 cat /root/secrets/${k%%:*}.pass > pvwa/${k#*:}.pass); done && ls pvwa | grep pass
```

```out
ad-test-users.pass
ldap-bind.pass
```

@role 小安（從 PVWA 取出；lab 由 Windows 終端代貼） | Windows 終端 | 本機

小安從 PVWA 取出，放進操作機的 `~/secrets/`（0700 目錄、0600 檔）。正式環境在操作機上每個檔執行一次 `(umask 077; IFS= read -rsp '貼上後按 Enter：' P && printf %s "$P" > ~/secrets/ldap-bind.pass; unset P; echo)`：`read -s` 讓貼上的密碼不顯示在畫面上（PSMP 錄影錄不到），`printf %s` 不多寫換行。lab 由 Windows 終端代貼：

```bash
docker exec lab-ops02-1 install -d -m 0700 /root/secrets && for f in ldap-bind ad-test-users; do docker exec -i lab-ops02-1 bash -c "umask 077; cat > ~/secrets/$f.pass" < ~/kafka-lab/pvwa/$f.pass; done; docker exec lab-ops02-1 ls -la /root/secrets | tail -n +4
```

```out
-rw------- 1 root root 20 … ad-test-users.pass
-rw------- 1 root root 20 … ldap-bind.pass
```

## 3.5 NTP 與負載平衡

兩件銀行的基礎服務：時間同步（NTP，憑證與 Kafka 都怕時間不準）和 REST Proxy、C3 前面的負載平衡。

@role 銀行 套件庫管理員 | repo01 | root

正式環境有行內 NTP；lab 裡：讓 repo01 兼任 NTP：

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

之後每次重啟 REST Proxy，都要先請 LB 團隊把那一台停用、重啟完再恢復（12.1）。正式環境是 LB 團隊在行內設備上停用／啟用 pool member；lab 用一支小腳本扮演：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
cat > ~/kafka-lab/lb-member.sh <<'EOF'
#!/usr/bin/env bash
# lb-member.sh <rest01|rest02> down|up|status —— lab：扮演 LB 團隊停用／恢復一台 REST Proxy
# 正式環境是 LB 團隊在行內的負載平衡設備上停用／啟用 pool member。nginx：server 後面加 down 再 reload，進行中的連線讓它跑完
h=$1 act=${2:-status}; f=/etc/nginx/stream.d/cp.conf
case $act in
  down) e="/server $h.poc.lab:8082 /{/ down;/!s/;\$/ down;/}";;
  up)   e="/server $h.poc.lab:8082 /s/ down;/;/";;
  status) e="";;
  *) echo "用法：$0 <rest01|rest02> down|up|status"; exit 2;;
esac
MSYS_NO_PATHCONV=1 docker exec lab-lb01-1 sh -c "{ [ -z '$e' ] || { sed -i '$e' $f && nginx -t -q && nginx -s reload 2>/dev/null; }; } && sleep 1 && echo \"LB：\$(grep -oE 'server rest0[12][^;]*' $f | sed -E 's/\.poc\.lab:8082 max_fails=2 fail_timeout=10s//; s/server //; s/ down/（停用）/' | paste -sd' ' -)\""
EOF
chmod +x ~/kafka-lab/lb-member.sh && bash ~/kafka-lab/lb-member.sh rest01 status
```

```out
LB：rest01 rest02
```

# 4. 第四站：上架到內部套件庫

**這一章在做什麼**：把 Confluent 的 RPM 做成一個 dnf 套件庫，放到銀行的套件庫伺服器 repo01，之後 11 台主機都用 `dnf install` 從這裡裝。前提：第 2 章的 `~/landing` 已驗過、第 3.1 節的 repodeploy 金鑰可用。這一章只放安裝基底的 RPM；遷移目標的 RPM 在 21.1 才上架。

@role 小安 | ops02 | root

repo01 只有 httpd，沒有 `createrepo_c`，所以索引在操作機建好，連 RPM 一起推上去。先從銀行套件庫裝工具：

```bash
dnf -q -y --refresh install createrepo_c && createrepo_c --version
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

**這一章在做什麼**：把銀行交付的 JDK 21 tar 解開，裝到操作機和其他 10 台主機的同一個位置。前提：3.3 已核對過 tar。Confluent 的 RPM 不含 JDK，沒有這一步後面的服務起不來。

@role 小安 | ops02 | root

![hostfiles]

銀行給的 tar 在 `~/landing/bank/`（有 21 和 25 兩個，這一章只裝 **21**：8.2.x 不支援 Java 25；25 在第 21 章遷移時才換上去）。決定：解壓到 `/opt/java/<版本目錄>`，再做一個固定的連結 `/opt/java/current` 指向它，所有設定一律寫 `/opt/java/current`，以後換版只改連結。`java`、`keytool` 用 alternatives 登記（RHEL 的標準做法），`/etc/profile.d/java.sh` 設 `JAVA_HOME`；服務自己的 systemd 設定還會再明確寫一次 `JAVA_HOME`，不受全域切換影響。

先看壓縮檔的頂層目錄名稱，並準備 `profile.d` 的檔案（`bank/` 裡同一個主版本有新舊幾版時，`sort -V | tail -1` 挑版本最新的）：

```bash
JDK_TAR=$(ls ~/landing/bank/OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1) && JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1) && echo "tar=$(basename $JDK_TAR) dir=$JDK_DIR" && install -d -m 0700 ~/jdk && cat > ~/jdk/java.sh <<'EOF'
# JDK for Confluent Platform (/opt/java/current; 21 at install, 25 after the chapter 21 migration). Services set JAVA_HOME in their systemd drop-in.
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
source ~/jdk/jdk.env && install -d -m 0755 /opt/java && tar -xzf "$JDK_TAR" -C /opt/java && chown -R root:root /opt/java && ln -sfn "/opt/java/$JDK_DIR" /opt/java/current && alternatives --install /usr/bin/java java /opt/java/current/bin/java 2100 && alternatives --install /usr/bin/keytool keytool /opt/java/current/bin/keytool 2100 && install -m 0644 ~/jdk/java.sh /etc/profile.d/java.sh && java -version 2>&1 | head -1
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

**這一章在做什麼**：在動任何東西之前，逐項確認銀行準備的環境符合條件。這一章只看不改。每一項不符都是要先回頭找銀行的事，不要自己硬裝過去；全部符合才進第 7 章。

@role 小安 | ops02 | root

**主機基本事實**（`/tmp` 不能 `noexec`、至少 2 GB）。過關條件：每台 `tmp_noexec=0`、`tmp_free` 不小於 2048、OS 版本與銀行說的一致：

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'printf "%-7s %s cpu=%s mem=%sMB tmp_free=%sMB tmp_noexec=%s\n" "$(hostname)" "$(. /etc/os-release; echo $ID-$VERSION_ID)" "$(nproc)" "$(free -m | awk "/Mem:/{print \$2}")" "$(df -m /tmp | awk "NR==2{print \$4}")" "$(findmnt -no OPTIONS /tmp | grep -c noexec)"'; done
```

```out
ops02   rocky-9.6 cpu=8 mem=10953MB tmp_free=2048MB tmp_noexec=0
（11 行，tmp_noexec 都是 0）
```

**資料碟的檔案系統**（原廠只支援 XFS、ext4；正式環境資料碟要先由主機團隊掛在 `/var/lib/kafka`，還沒掛就會看到 `/var/lib`，也就是 OS 碟）：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'd=/var/lib/kafka; [ -e $d ] || d=/var/lib; printf "%-5s %s fstype=%s free=%sGB\n" "$(hostname)" "$d" "$(df -T $d | awk "NR==2{print \$2}")" "$(df -BG --output=avail $d | tail -1 | tr -dc 0-9)"'; done
```

```out
kc01  /var/lib fstype=overlay free=712GB
（7 行；lab 是容器，所以是 overlay、和 OS 共用；正式環境要是 xfs 或 ext4，而且路徑是 /var/lib/kafka）
```

> `/tmp` 要能執行：broker 啟動時會把壓縮（snappy、zstd、lz4）的原生程式庫解壓到 `java.io.tmpdir`（預設 `/tmp`）再載入，`noexec` 的 `/tmp` 會讓用到這些壓縮的 producer／consumer 失敗。銀行的強化規範若要求 `/tmp` 一律 `noexec`，見 10.3 的 `java.io.tmpdir` 做法。

**時鐘誤差**（TLS 與 MDS token 要求 2 秒內；各台與操作機相差超過 2 秒就請銀行修 NTP）：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do echo "$h skew=$(( $(ssh $h.poc.lab date +%s) - $(date +%s) ))s"; done
```

```out
kc01 skew=0s
（都是 0 或 1）
```

**DNS、套件庫、AD 連線**。過關條件：每台 `all resolved`、`os=200`、`confluent=200`，AD 那段 `Verify return code: 0 (ok)`（代表 LDAPS 憑證鏈信任成功）：

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

**主機是乾淨的**（沒裝過 Confluent、沒有資料目錄；有殘留的舊資料會讓第 10 章的格式化出問題）：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'echo "$(hostname): confluent_pkgs=$(rpm -qa "confluent-*" | wc -l) data_dir=$([ -e /var/lib/kafka ] && echo exists || echo none)"'; done
```

```out
kc01: confluent_pkgs=0 data_dir=none
（10 行）
```

# 7. 第七站：OS 調校

**這一章在做什麼**：照 Confluent 的建議調整主機：核心參數、檔案數上限、關閉 THP（transparent hugepage）、時區、時間同步、防火牆只開需要的埠。每台逐一做，沒有順序相依，也沒有服務會被重啟。

@role 小安 | ops02 | root

10 台叢集主機都要做，操作機只做時間同步與時區。lab 裡：主機是容器，sysctl 有兩個網路參數設不進去（`errors=2`）、THP 的單元會自動跳過；正式 VM 不會有這個限制，`errors` 應該是 0。

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
| C3 | 9021、9090、7071 | 維運人員的瀏覽器；C3 自己的 Prometheus；監控 |

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'case $(hostname) in kc*) p="9093 7071";; kb*) p="9092 9094 9095 9096 8090 7071";; rest*) p="8082 7071";; c3*) p="9021 9090 7071";; esac; sudo dnf -q -y install firewalld >/dev/null && sudo systemctl enable --now firewalld >/dev/null 2>&1; for s in cockpit dhcpv6-client; do sudo firewall-cmd -q --permanent --remove-service=$s 2>/dev/null; done; for x in $p; do sudo firewall-cmd -q --permanent --add-port=$x/tcp; done; sudo firewall-cmd -q --reload && echo "$(hostname): $(sudo firewall-cmd --list-ports)"'; done
```

```out
kc01: 7071/tcp 9093/tcp
kb01: 7071/tcp 8090/tcp 9092/tcp 9094/tcp 9095/tcp 9096/tcp
rest01: 7071/tcp 8082/tcp
c3-01: 7071/tcp 9021/tcp 9090/tcp
（10 行）
```

# 8. 第八站：安裝 Confluent 套件

**這一章在做什麼**：從行內套件庫把 Confluent 的 RPM 裝到各主機（各主機只裝自己角色需要的），並鎖定版本，之後 OS 例行更新不會把它們升掉。

@role 小安 | ops02 | root

裝的是**安裝基底**（Confluent Platform 8.2.4、Control Center 2.5.1，來自 `~/landing/rpm/`）；套件庫（第 4 章）此時只有這一套。目標版本（8.3.2、2.6.1）到第 21 章才上架。

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
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01 ops02; do case $h in kc*|kb*) p="confluent-server-8.2.4 confluent-security-8.2.4";; rest*) p="confluent-kafka-rest-8.2.4 confluent-security-8.2.4";; c3*) p="confluent-control-center-next-gen-2.5.1 cyrus-sasl openssl-devel";; ops*) p="confluent-server-8.2.4 confluent-security-8.2.4 confluent-cli-8.2.4";; esac; ssh $h.poc.lab "sudo dnf -q -y --setopt=install_weak_deps=False install $p >/dev/null && echo \"\$(hostname): \$(rpm -qa 'confluent-*' | wc -l) confluent packages\""; done
```

```out
kc01: 9 confluent packages
kb01: 9 confluent packages
rest01: 4 confluent packages
c3-01: 1 confluent packages
ops02: 10 confluent packages
```

每台約一兩分鐘。鎖版本（只鎖 Confluent；C3 的兩個 OS 套件跟著 OS 修補，不鎖）。這個鎖在第 21 章遷移時由腳本先解開、換完版本再鎖回；第 26 章的 OS 更新（9.6 → 9.8）靠它確保 Confluent 不被動到：

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

**這一章在做什麼**：替平台的每個元件備好憑證。小安在操作機產生私鑰與 CSR（憑證申請單），交給銀行 CA 簽發，收回來逐張檢查，再做成 Java 用的 keystore／truststore。前提：第 3.2 節的銀行根憑證已在各主機，第 8 章套件已裝。後面第 10–13 章的 TLS 設定都用這一章的產出。

平台內部所有連線都加密，而且用憑證識別身分。小安在操作機產生私鑰和 CSR（私鑰不離開行內），銀行 CA 簽完回來，小安逐張檢查後做成 Java 用的 keystore。

## 9.1 產生私鑰與 CSR

先決定要幾張憑證、各自給誰用（下表），再一次把 9 組私鑰與 CSR 產生出來。私鑰留在操作機，只有 CSR 交給銀行。EKU（憑證用途）決定憑證能當伺服器、客戶端或兩者；SAN 是憑證適用的主機名稱，連線時名稱對不上會被拒。

@role 小安 | ops02 | root

| 名稱 | 用途 | EKU | SAN |
|---|---|---|---|
| kafka-internal | controller、broker 之間的 mTLS | serverAuth, clientAuth | kc01–03、kb01–04 |
| cp-server | 所有對外服務的**伺服器端**：client listener、MDS、REST、C3、Prometheus。只當 server 憑證，不拿去當 client 出示 | serverAuth | 全部主機、rest.poc.lab、c3.poc.lab、localhost |
| svc-rest、svc-c3、svc-ops | REST Proxy、C3、操作機向 MDS 換 token 的身分 | clientAuth | 無 |
| c3-monitoring | C3 向自己內建的 Prometheus、Alertmanager 出示的 client 身分（第 13 章）。只做這件事，**不綁任何 Kafka 角色** | clientAuth | 無 |
| app-legacy-billing | 走 REST Proxy 的應用程式 | clientAuth | 無 |
| opmenu-breakglass | 維運選單（第 16 章）緊急模式用的身分 | clientAuth | 無 |
| svc-backup | 每日備份（第 25 章）匯出叢集中繼資料的唯讀身分 | clientAuth | 無 |

```bash
install -d -m 0700 ~/pki ~/pki/keys ~/pki/requests ~/pki/incoming ~/pki/certs && (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/pki/store.pass) && cat > ~/pki/requests.txt <<'EOF'
kafka-internal     serverAuth,clientAuth  kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04
cp-server          serverAuth             kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04,rest01.poc.lab,rest01,rest02.poc.lab,rest02,c3-01.poc.lab,c3-01,ops02.poc.lab,ops02,lb01.poc.lab,lb01,rest.poc.lab,c3.poc.lab,localhost
svc-rest           clientAuth             -
svc-c3             clientAuth             -
c3-monitoring      clientAuth             -
svc-ops            clientAuth             -
app-legacy-billing clientAuth             -
opmenu-breakglass  clientAuth             -
svc-backup         clientAuth             -
EOF
while read -r name eku san; do (umask 077; openssl genrsa -out ~/pki/keys/$name.key 2048 2>/dev/null); ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku"); [ "$san" != "-" ] && ext+=(-addext "subjectAltName=$(echo "$san" | tr ',' '\n' | sed 's/^/DNS:/' | paste -sd, -)"); openssl req -new -key ~/pki/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" "${ext[@]}" -out ~/pki/requests/$name.csr && echo "$name: csr ok"; done < ~/pki/requests.txt
```

```out
kafka-internal: csr ok
（9 行）
```

送出前自己看一次 CN、SAN、EKU 是否和上表一致（銀行 CA 的政策會檢查 EKU，漏了會被退件）：

```bash
for f in ~/pki/requests/*.csr; do echo "== $(basename $f)"; openssl req -in $f -noout -subject -text | grep -E "^subject=|Alternative|Extended Key" -A1 | grep -v "^--" | sed 's/^ */  /'; done
```

## 9.2 銀行 CA 簽發

@role 銀行 CA 窗口 | Windows 終端 | 本機

正式環境是把 CSR 交給 CA 窗口，收回「憑證 + 中繼 CA」。lab 裡：用 0.5.5 建好的 `sign.sh`，9 個 CSR 一次簽完、放回操作機的 `incoming/`（簽好的放在 `signed/` 子目錄，免得和第 3 章簽給 ad01 的那張混在一起）：

```bash
cd ~/kafka-lab && mkdir -p ca/exchange/signed && docker cp lab-ops02-1:/root/pki/requests "$(cygpath -m "$PWD/ca/exchange/")" && for f in ca/exchange/requests/*.csr; do n=$(basename $f .csr); bash ca/sign.sh "$f" "ca/exchange/signed/$n.crt"; done && for f in ca/exchange/signed/*.crt; do docker cp "$(cygpath -m "$f")" lab-ops02-1:/root/pki/incoming/; done && docker exec lab-ops02-1 bash -c 'ls /root/pki/incoming | wc -l'
```

```out
signed app-legacy-billing.csr -> app-legacy-billing.crt  (CN = app-legacy-billing, O = PoC Bank, C = TW; EKU clientAuth)
（9 行）
9
```

## 9.3 匯入前檢查、做成 keystore

下面這張圖說明 keystore 和 truststore 各管什麼、兩台機器連線時互相檢查什麼。

![trust]

銀行回覆的憑證不能直接用：先拆開、逐張檢查，全部沒問題才打包成 Java 能讀的檔。這一節是小安防止「拿到錯的憑證才在啟動時才發現」的最後一關。

@role 小安 | ops02 | root

拆開回覆（第一張是 leaf，其餘是中繼）：

```bash
cd ~/pki && for n in $(awk '{print $1}' requests.txt); do awk -v n=$n 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("incoming/" n ".part" c)}' incoming/$n.crt; mv incoming/$n.part1 incoming/$n.leaf.pem; cat incoming/$n.part[2-9] > incoming/$n.issuers.pem 2>/dev/null; rm -f incoming/$n.part*; echo "$n: $(grep -c 'BEGIN CERT' incoming/$n.issuers.pem) issuer(s)"; done
```

```out
kafka-internal: 1 issuer(s)
（9 行）
```

五項檢查：私鑰相符、CN、SAN、EKU、效期，再驗整條鏈到銀行根憑證。好結果是每一行的 key、cn、san、eku、chain 都是 `ok`，days 約 364（憑證效期一年）：

```bash
cd ~/pki && while read -r name eku san; do leaf=incoming/$name.leaf.pem; k1=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16); k2=$(openssl pkey -in keys/$name.key -pubout 2>/dev/null | sha256sum | cut -c1-16); cn=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); have_san=$(openssl x509 -in $leaf -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,); want_san=$([ "$san" = "-" ] && echo "" || echo "$san" | tr ',' '\n' | sort | paste -sd,); have_eku=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' '); days=$(( ($(date -d "$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )); chain=$(openssl verify -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem -untrusted incoming/$name.issuers.pem $leaf 2>&1 | grep -c ": OK"); printf '%-19s key=%s cn=%s san=%s eku=%s days=%s chain=%s\n' $name $([ $k1 = $k2 ] && echo ok || echo MISMATCH) $([ "$cn" = "$name" ] && echo ok || echo "$cn") $([ "$have_san" = "$want_san" ] && echo ok || echo DIFF) "$have_eku" $days $([ $chain = 1 ] && echo ok || echo FAIL); done < requests.txt
```

```out
kafka-internal      key=ok cn=ok san=ok eku=TLSWebServerAuthentication,TLSWebClientAuthentication days=364 chain=ok
（9 行，全部 ok）
```

> 任何一項不是 ok 就退回銀行重簽，不往下做。

整理成正式檔案，做 PKCS12 keystore、truststore（只放銀行根憑證）、MDS token 金鑰對：

```bash
cd ~/pki && for n in $(awk '{print $1}' requests.txt); do cat incoming/$n.leaf.pem incoming/$n.issuers.pem > certs/$n.crt; openssl pkcs12 -export -name $n -inkey keys/$n.key -in certs/$n.crt -out certs/$n.p12 -passout file:store.pass && chmod 0600 certs/$n.p12; done && cp /etc/pki/ca-trust/source/anchors/bank-root.pem certs/bank-root.pem && keytool -importcert -noprompt -alias bank-root -file certs/bank-root.pem -keystore certs/truststore.p12 -storetype PKCS12 -storepass:file store.pass && (umask 077; openssl genrsa -out keys/mds-token.key 2048 2>/dev/null) && openssl rsa -in keys/mds-token.key -pubout -out certs/mds-token-public.pem 2>/dev/null && ls certs | wc -l
```

```out
Certificate was added to keystore
21
```

| 檔案 | 用途 |
|---|---|
| certs/*.crt | leaf + 中繼，給需要 PEM 的程式（curl、Prometheus） |
| certs/*.p12 | 私鑰 + 鏈，給 Java 程式當 keystore |
| certs/truststore.p12 | 只有銀行根憑證，所有元件驗對方用 |
| keys/mds-token.key、certs/mds-token-public.pem | MDS 簽 token 用的金鑰對，不經銀行 |

# 10. 第十站：controller 與 broker

![startup]

**這一章在做什麼**：把 controller（3 台）與 broker（4 台）設定好並啟動，讓 Kafka 叢集第一次跑起來。順序是：派送憑證（10.1）→ 產生並派送設定檔（10.2）→ 設定 systemd（10.3）→ 格式化儲存、先起 controller 再起 broker（10.4）。前提：第 9 章的憑證都簽好了、第 8 章套件已裝。

## 10.1 派送憑證

@role 小安 | ops02 | root

把第 9 章的 keystore 與 truststore 放到各主機。controller 4 個檔，broker 多一個 `cp-server.p12`（對外 listener 用）。目錄 root:confluent 0750，檔案 0640：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do case $h in kb*) extra=~/pki/certs/cp-server.p12;; *) extra="";; esac; scp -q ~/pki/certs/truststore.p12 ~/pki/certs/kafka-internal.p12 ~/pki/keys/mds-token.key ~/pki/certs/mds-token-public.pem $extra $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -d -o root -g root -m 0755 /etc/confluent && sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka && for f in /tmp/truststore.p12 /tmp/kafka-internal.p12 /tmp/mds-token-public.pem /tmp/cp-server.p12; do [ -f $f ] && sudo install -o root -g confluent -m 0640 $f /etc/confluent/ssl/; done; sudo install -o root -g confluent -m 0640 /tmp/mds-token.key /etc/confluent/ssl/mds-token-keypair.pem; rm -f /tmp/*.p12 /tmp/mds-token*; printf "%-6s %s files: %s\n" "$(hostname)" "$(sudo ls /etc/confluent/ssl | wc -l)" "$(sudo ls /etc/confluent/ssl | paste -sd" ")"'; done
```

```out
kc01   4 files: kafka-internal.p12 mds-token-keypair.pem mds-token-public.pem truststore.p12
kb01   5 files: cp-server.p12 kafka-internal.p12 mds-token-keypair.pem mds-token-public.pem truststore.p12
（7 行）
```

## 10.2 設定檔

下面這張圖是各個 listener 的用途，以及誰會連哪一個。

![listeners]

@role 小安 | ops02 | root

這一節產生每台的 `server.properties`（Kafka 的主要設定檔）。controller 與 broker 是同一個程式、不同設定：controller 管叢集狀態，broker 服務應用程式。設定檔用範本產生：範本裡寫 `${變數}`，由 `envsubst` 換成每台的值；密碼從檔案讀進變數，不出現在畫面上。先裝工具：

```bash
dnf -q -y install gettext >/dev/null && echo envsubst-ok
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
# metadata log (__cluster_metadata) stays here even if more log.dirs are added later (default = first log.dirs entry)
metadata.log.dir=/var/lib/kafka/data

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
# metadata log (__cluster_metadata) stays here even if more log.dirs are added later (default = first log.dirs entry)
metadata.log.dir=/var/lib/kafka/data

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

@role 小安 | ops02 | root

這一節讓 systemd 用我們的設定檔啟動服務，而不是 RPM 附的預設設定。RPM 的 `confluent-server.service` 預設讀 `/etc/kafka/server.properties`，用 drop-in 覆寫成我們的設定、`JAVA_HOME`、heap（lab 規格：controller 384m、broker 768m（官方 JMX exporter 規則每台 broker 約一萬多條序列，加上遷移期間的持續流量，512m 會 OutOfMemoryError））。**最後一定要看到 exec 指向我們的檔案**：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do case $h in kc*) heap=384m;; *) heap=768m;; esac; ssh $h.poc.lab "sudo install -d -m 0755 /etc/systemd/system/confluent-server.service.d && sudo tee /etc/systemd/system/confluent-server.service.d/10-override.conf >/dev/null <<EOF
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

> 選配：銀行規定 `/tmp` 一律 `noexec` 時（第 6 章有檢查），讓 JVM 改把原生程式庫解到資料碟上的目錄。另加一個 drop-in，用 `JAVA_TOOL_OPTIONS`（第 17 章的 javaagent 會佔用 `KAFKA_OPTS`，兩者不互相覆蓋）：
> `sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka/tmp && printf '[Service]\nEnvironment="JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=/var/lib/kafka/tmp"\n' | sudo tee /etc/systemd/system/confluent-server.service.d/15-tmpdir.conf`
> 實測（2026-10-25，kb04）：重啟後 lz4 的原生程式庫改解在 `/var/lib/kafka/tmp`，snappy／zstd／lz4 壓縮的寫入都正常；日誌開頭會多一行 `Picked up JAVA_TOOL_OPTIONS`，屬正常。REST Proxy、C3 同理（各自的資料目錄）。

> 陷阱：如果 exec 顯示的是 `/etc/kafka/server.properties`，代表 drop-in 沒生效，此時啟動會用 RPM 的預設設定起來（沒有加密、沒有認證）。處理：不要啟動，先檢查 drop-in 檔的位置與內容、執行 `systemctl daemon-reload`，再看一次 ExecStart。REST Proxy（第 12 章）與 C3（第 13 章）啟動前都要做同樣的檢查。

## 10.4 格式化、啟動

下面這張圖說明 KRaft quorum 的成員角色，以及 describe 輸出裡的 Lag 是什麼意思。

![kraft]

@role 小安 | ops02 | root

格式化是替每台建立 Kafka 的儲存目錄與身分（只做一次）。整個叢集共用一個 cluster id、每台 controller 一個 directory id；controller 用動態 quorum（可以事後增減成員）格式化，並寫入緊急備用的 SCRAM 管理帳號 `kafka-admin`；broker 格式化成觀察者（observer：不參與 quorum 投票，只讀取 metadata）。

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
Formatting dynamic metadata voter directory /var/lib/kafka/data with confluent.metadata.version 4.2-IV1A.
kc01  cluster.id=xxxxxxxxxxxxxxxxxxxxxx
…
Formatting metadata directory /var/lib/kafka/data with confluent.metadata.version 4.2-IV1A.
kb01  cluster.id=xxxxxxxxxxxxxxxxxxxxxx node.id=101
（7 台 cluster.id 相同。metadata 版本字串跟著安裝的版本走：基底 8.2.4 預期是 4.2-IV1A（features describe 顯示 CP-8.2-IV1A），遷移到 8.3.2 之後新格式化的（第 23、24 章）才是 4.3-IV0B；字串以實際為準，從零重跑時對一次）
```

格式化只做一次，重跑會被 `already formatted` 擋下，這是保護。

操作機連 controller 的 client 設定（用內部憑證），然後啟動 controller、看 quorum。好結果：3 台 controller 都在清單裡、有一個 leader、`Lag` 很小；有一台沒出現就先別啟動 broker：

```bash
(umask 077; cat > ~/conf/client-internal.properties <<EOF
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=/root/pki/certs/kafka-internal.p12
ssl.keystore.password=$(cat ~/pki/store.pass)
ssl.key.password=$(cat ~/pki/store.pass)
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
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

啟動 broker，確認註冊與 MDS。好結果：4 台 broker 都註冊成功，MDS（8090）回 200；MDS 要等 AD 查詢帳號連得上才會起來，所以慢幾十秒是正常的：

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

下面這張圖說明 svc-ops 這類身分怎麼用憑證換到 token，再進 TOKEN listener。

![tokenflow]

下面這張圖畫出一個人的權限怎麼從 AD 群組一路接到 Kafka 資源。

![rbac]

**這一章在做什麼**：叢集起來之後，建立「誰能做什麼」：操作機的管理身分、應用程式的 SCRAM 帳號、綁在 AD 群組上的 RBAC 角色（Role-Based Access Control，角色式權限）。前提：第 10 章的 broker 與 MDS 都已經正常。

@role 小安 | ops02 | root

操作機的管理 client：用 `svc-ops` 憑證向 MDS 換 token，走 TOKEN listener。`svc-ops` 是 super user。

```bash
(umask 077; cat > ~/conf/client-admin.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenCertificateLoginCallbackHandler
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required metadataServerUrls="https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090";
ssl.keystore.type=PKCS12
ssl.keystore.location=/root/pki/certs/svc-ops.p12
ssl.keystore.password=$(cat ~/pki/store.pass)
ssl.key.password=$(cat ~/pki/store.pass)
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
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

應用程式這一端的連線設定（扮演 app-orders 直連 CLIENT 9095；第 18、19 章驗證時都會用到）。密碼從 0600 檔讀，設定檔一樣是 0600：

```bash
(umask 077; printf 'security.protocol=SASL_SSL\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-orders" password="%s";\nssl.truststore.type=PKCS12\nssl.truststore.location=/root/pki/certs/truststore.p12\nssl.truststore.password=%s\n' "$(cat ~/secrets/app-orders.pass)" "$(cat ~/pki/store.pass)" > ~/conf/app-orders.properties) && echo "$(grep -c . ~/conf/app-orders.properties) lines, $(stat -c %a ~/conf/app-orders.properties)"
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

## 11.1 密碼交 Secrets 團隊保管（PVWA）

**這一節在做什麼**：把前面產生的密碼交給銀行保管。到這裡小安產生了幾組密碼，正本都要交銀行的 Secrets 團隊存進 PVWA；操作機上的 `~/secrets/`、`~/pki/store.pass` 只是作業用的副本：

| 密碼 | 誰要用 | PVWA 裡的 object（名稱依銀行慣例，以下是建議） |
|---|---|---|
| `~/pki/store.pass`（所有 keystore／truststore） | 平台工程師 | `kafka-store-password` |
| `~/secrets/kafka-admin.pass`（緊急備用的 SCRAM 管理帳號，10.4） | 平台工程師，MDS 故障時 | `kafka-admin-scram` |
| `~/secrets/app-orders.pass`、`app-payments.pass` | 各應用程式團隊 | `kafka-scram-app-orders`、`kafka-scram-app-payments` |

@role 銀行 Secrets 團隊（收下存進 PVWA；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

正式環境是小安在 PVWA 新增或更新 object、貼上內容。lab 裡：把操作機上的檔案複製進 `pvwa/` 資料夾來模擬：

```bash
cd ~/kafka-lab && (umask 077; docker exec lab-ops02-1 cat /root/pki/store.pass > pvwa/store.pass; for f in kafka-admin app-orders app-payments; do docker exec lab-ops02-1 cat /root/secrets/$f.pass > pvwa/$f.pass; done) && for f in store kafka-admin app-orders app-payments; do printf '%s ' "$f:$(wc -c < pvwa/$f.pass)"; done; echo
```

```out
store:24 kafka-admin:24 app-orders:24 app-payments:24
```

> 應用程式團隊從 PVWA 取自己的 SCRAM 密碼，放進他們的設定；這本的 `~/conf/app-orders.properties` 是小安在操作機扮演應用程式用的。密碼換了（OP menu 35 換服務密碼）就要同步更新 PVWA 的那個 object。

## 11.2 演練：緊急帳號 kafka-admin 用過就換密碼

這一節演練「緊急帳號被人用過之後怎麼收拾」。`kafka-admin` 是 MDS 故障時唯一進得去的管理身分（CLIENT 9095，SCRAM，super user）。平常沒人用；一旦有人在緊急時從 PVWA 取出來用過，這個密碼就算曝光了，**用完當天就要換**。CPM 沒有可以換 Kafka SCRAM 密碼的 plugin，所以由小安換、再交回 PVWA。平常沒有程式掛在這個帳號上，所以一個帳號直接換、不需要 A／B 兩組，也不會中斷任何服務（應用程式的 SCRAM 帳號才需要 A／B，見 OP menu 35）。

@role 小安 | ops02 | root

先模擬一次緊急使用（用 PVWA 那份密碼從 9095 登入），再換密碼：新密碼先寫暫存檔，叢集改成功才換掉 `~/secrets/kafka-admin.pass`。`kafka-configs` 出錯時會把整串設定（含密碼）印出來，所以它的輸出一律丟掉，結果用 `--describe` 和實際登入確認：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml; BS=kb01.poc.lab:9094; T=$(mktemp -d) && login() { grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $T/c.properties && printf 'sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="kafka-admin" password="%s";\n' "$(cat $1)" >> $T/c.properties && kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $T/c.properties --list >/dev/null 2>&1 && echo 登入成功 || echo 被拒; } && echo "緊急使用（目前的密碼）：$(login ~/secrets/kafka-admin.pass)" && cp -p ~/secrets/kafka-admin.pass $T/old.pass && (umask 077; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > $T/new.pass) && kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties --alter --entity-type users --entity-name kafka-admin --add-config "SCRAM-SHA-512=[iterations=8192,password=$(cat $T/new.pass)]" >/dev/null 2>&1 && install -m 0600 $T/new.pass ~/secrets/kafka-admin.pass && echo "kafka-admin: $(kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties --describe --entity-type users --entity-name kafka-admin 2>/dev/null | grep -o 'SCRAM-SHA-512=[^ ]*')" && echo "換完：新密碼 $(login ~/secrets/kafka-admin.pass)；舊密碼 $(login $T/old.pass)"; rm -rf $T
```

```out
緊急使用（目前的密碼）：登入成功
kafka-admin: SCRAM-SHA-512=iterations=8192
換完：新密碼 登入成功；舊密碼 被拒
```

> 新密碼會短暫出現在操作機的行程參數裡（`--add-config` 只吃命令列；`--add-config-file` 不接受 SCRAM 這個欄位）。能登入操作機的只有經 PSMP 進來的人員（root，全程錄影），可以接受。

@role 銀行 Secrets 團隊（更新 PVWA 的 kafka-admin-scram，舊版本保留；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && cp -p pvwa/kafka-admin.pass pvwa/kafka-admin.prev.pass && (umask 077; docker exec lab-ops02-1 cat /root/secrets/kafka-admin.pass > pvwa/kafka-admin.pass) && echo "PVWA kafka-admin-scram 已更新：$(wc -c < pvwa/kafka-admin.pass) 字元"
```

```out
PVWA kafka-admin-scram 已更新：24 字元
```

> 誰在什麼時候取用過 `kafka-admin-scram`，PVWA 的取用紀錄查得到；Kafka 那邊，稽核日誌（第 18 章）會記下 `User:kafka-admin` 做了什麼。兩邊對得上，才算這次緊急使用結案。


# 12. 第十二站：REST Proxy

![edge]

**這一章在做什麼**：安裝 REST Proxy（讓不方便直連 Kafka 的應用程式用 HTTP 存取 Kafka）在 rest01、rest02 兩台，前面由銀行的負載平衡（LB）分流。REST Proxy 沒有密碼登入，應用程式一律用 client 憑證，憑證的 CN 對應到 Kafka 的身分（principal）。前提：第 10、11 章的 broker 與 MDS 已正常、第 9 章的 `svc-rest` 與 `app-legacy-billing` 憑證已做好。

@role 小安 | ops02 | root

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

## 12.1 之後每次重啟 REST Proxy：先請 LB 團隊停用那一台

下面這張圖把五步每一步時，兩台 REST Proxy 各是什麼狀態畫出來。

![restdrain]

**這一節在做什麼**：定出之後每次重啟 REST Proxy 的標準做法（先請 LB 團隊把那一台停用，等連線排空再重啟），避免應用程式在重啟那幾秒收到錯誤。原因：nginx 社群版只有被動健康檢查（`max_fails`）：REST 重啟的那幾秒，要先有請求失敗，LB 才把它標成故障、改送另一台（遷移實測：換 JDK 時重啟 REST，經 LB 失敗 4 次）。行內的 LB 就算有主動健康檢查，也是「停了之後才發現」。所以之後**每次重啟 REST**（15、17、20、21、26 章）都照這個順序：

1. LB 團隊停用 rest01 → 2. 小安等連線排空、重啟 rest01、確認 200 → 3. LB 團隊恢復 rest01、停用 rest02 → 4. 小安重啟 rest02 → 5. LB 團隊恢復 rest02

**待銀行確認**：行內 LB 是哪一種設備、變更時段能否由 LB 團隊配合停用／恢復成員（問題清單 5.6）。

@role 小安 | ops02 | root

小安這邊寫成一支小腳本：先看那台的 8082 還有沒有從 LB 進來的連線（等到 0 才動；60 秒還有就停下，多半是 LB 還沒停用），再做重啟前要做的事（`-c` 複製檔案過去、`-b` 在那台執行，例如換證、升級套件），重啟（`-r` 改成重開機），等到 200：

```bash
cat > ~/conf/rest-restart.sh <<'EOF'
#!/usr/bin/env bash
# rest-restart.sh <rest01|rest02> [-c "本機檔案…"] [-b '在那台先執行的指令'] [-r]
# 前提：這台已經由 LB 團隊停用（lb-member.sh <主機> down）。順序：等 LB 那邊進來的連線排空 → -c 的檔案 scp 到那台的 /tmp/
# → 在那台執行 -b → 重啟 confluent-kafka-rest（-r：改成重開機）→ 等到 REST 回 200。排空等不到就停下，什麼都不做
h=$1; shift; copy=""; before=":"; reboot=0
while getopts c:b:r o; do case $o in c) copy=$OPTARG;; b) before=$OPTARG;; r) reboot=1;; *) echo "用法：$0 <主機> [-c 檔案] [-b 指令] [-r]"; exit 2;; esac; done
lb=$(getent hosts lb01.poc.lab | awk '{print $1}')
for waited in $(seq 0 2 60); do n=$(ssh $h.poc.lab "ss -Htn state established '( sport = :8082 )'" | grep -c " $lb:"); [ "$n" = 0 ] && break; sleep 2; done
[ "$n" = 0 ] || { echo "$h：60 秒後 LB 還有 $n 條連線進來，LB 團隊停用了嗎？沒有重啟"; exit 1; }
if [ -n "$copy" ]; then scp -q $copy $h.poc.lab:/tmp/ || { echo "$h：複製檔案失敗，沒有重啟"; exit 1; }; fi
ssh $h.poc.lab "$before" || { echo "$h：重啟前的步驟失敗，沒有重啟"; exit 1; }
start=$(date +%s)
# lab 的主機是容器：共用 WSL2 的核心，systemctl reboot 會失敗（Could not activate remote peer），所以 -r 在容器上改成重啟服務
if [ $reboot = 1 ] && ssh $h.poc.lab 'systemd-detect-virt -cq'; then reboot=0; echo "$h：這台是容器，不能重開機，改重啟 confluent-kafka-rest"; fi
if [ $reboot = 1 ]; then
  ssh $h.poc.lab 'sudo systemctl reboot' 2>/dev/null; sleep 15
  for i in $(seq 1 60); do ssh -o ConnectTimeout=5 $h.poc.lab true 2>/dev/null && break; sleep 5; done
else
  ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'
fi
for i in $(seq 1 60); do
  code=$(curl -s -m 5 --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://$h.poc.lab:8082/v3/clusters)
  [ "$code" = 200 ] && break; sleep 3
done
echo "$h：排空等了 ${waited} 秒，$([ $reboot = 1 ] && echo 重開機 || echo 重啟)後 REST $code（約 $(( $(date +%s) - start )) 秒）"
[ "$code" = 200 ]
EOF
chmod 0700 ~/conf/rest-restart.sh && echo rest-restart.sh ok
```

```out
rest-restart.sh ok
```

演練一次：背景每 0.2 秒經 LB 打一次 REST，照五步走完，最後數非 200 的次數：

```bash
: > /tmp/lbprobe.log; nohup bash -c 'while :; do echo "$(date +%T) $(curl -s -m 5 --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w %{http_code} https://rest.poc.lab:8082/v3/clusters)" >> /tmp/lbprobe.log; sleep 0.2; done' >/dev/null 2>&1 & echo $! > /tmp/lbprobe.pid; echo "探測開始"
```

```out
探測開始
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

```bash
kill $(cat /tmp/lbprobe.pid); sleep 1; echo "經 LB 打了 $(wc -l < /tmp/lbprobe.log) 次，非 200：$(grep -vc ' 200$' /tmp/lbprobe.log)"
```

```out
經 LB 打了 … 次，非 200：0
```

> 對照：不排空、直接重啟兩台，同樣的探測 lab 實測 68 次裡 1 次失敗（請求剛好落在重啟的那一刻）。應用程式若用長連線（HTTP keep-alive），排空會等到它們斷線為止；60 秒還沒斷，腳本停下不重啟，要和應用程式團隊確認再做。

# 13. 第十三站：Control Center

下面這張圖分清楚 C3 內建的監控元件和銀行的監控各管什麼。

![c3roles]

**這一章在做什麼**：在 c3-01 安裝 Control Center（C3，Confluent 的網頁管理介面），讓維運人員用 AD 帳號登入、看叢集狀況。前提：第 10、11 章的 broker、MDS 與 RBAC 已就緒，第 9 章的 `svc-c3` 憑證已做好。完成的樣子：瀏覽器開 9021 可以用 alice 登入，且畫面有資料。

@role 小安 | ops02 | root

C3 套件有三個服務：內建 Prometheus、Alertmanager（Go 程式，吃 PEM 檔）和 C3 本身。內建的 Prometheus、Alertmanager 是給 C3 自己的畫面用的；**監控與告警不走它們**（第 17 章用行內的 Prometheus、Alertmanager、Grafana），所以這一章只把它們設到 C3 畫面能用，不要在 C3 畫面建 alert trigger 或 action。

```bash
scp -q ~/pki/certs/truststore.p12 ~/pki/certs/cp-server.p12 ~/pki/certs/cp-server.crt ~/pki/keys/cp-server.key ~/pki/certs/c3-monitoring.p12 ~/pki/certs/c3-monitoring.crt ~/pki/keys/c3-monitoring.key ~/pki/certs/bank-root.pem ~/pki/certs/svc-c3.p12 ~/pki/certs/mds-token-public.pem c3-01.poc.lab:/tmp/ && ssh c3-01.poc.lab 'sudo install -d -o root -g root -m 0755 /etc/confluent && sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/control-center && for f in truststore.p12 cp-server.p12 cp-server.crt cp-server.key c3-monitoring.p12 c3-monitoring.crt c3-monitoring.key svc-c3.p12 mds-token-public.pem; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; sudo install -o root -g confluent -m 0640 /tmp/bank-root.pem /etc/confluent/ssl/ca.pem; rm -f /tmp/*.p12 /tmp/cp-server.* /tmp/c3-monitoring.* /tmp/bank-root.pem /tmp/mds-token-public.pem; echo "c3-01: $(sudo ls /etc/confluent/ssl | wc -l) files"'
```

```out
c3-01: 10 files
```

Prometheus、Alertmanager 的 TLS（要求 client 憑證）與設定。兩個角色用兩張憑證：它們自己對外出示的是 `cp-server`（只有 serverAuth，純 server 憑證）；C3 去連它們、Prometheus 去連 Alertmanager 時出示的是 `c3-monitoring`（只有 clientAuth，不綁任何 Kafka 角色）。這樣 `cp-server` 即使外洩，也不能拿去當 client 登入任何需要 client 憑證的服務；Prometheus／Alertmanager 的 `client_auth_type` 只驗憑證鏈與用途，不看 CN，所以不用另外設定誰能連。`*-generated.yml` 是 C3 自己會寫的檔，擁有者要是 `cp-control-center`：

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
        cert_file: /etc/confluent/ssl/c3-monitoring.crt
        key_file: /etc/confluent/ssl/c3-monitoring.key
      static_configs:
        - targets:
            - c3-01.poc.lab:9093
rule_files:
  - "recording_rules-generated.yml"
  - "trigger_rules-generated.yml"
scrape_configs:
otlp:
  promote_resource_attributes: ["host.hostname", "java.version", "kafka.broker.id", "kafka.cluster.id", "kafka.version", "type"]
storage:
  tsdb:
    out_of_order_time_window: 10m
EOF
cd /etc/confluent-control-center && sudo chown root:confluent web-config-prom.yml web-config-am.yml prometheus-generated.yml && sudo chmod 0640 web-config-prom.yml web-config-am.yml prometheus-generated.yml && sudo chown cp-control-center:confluent alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml && sudo chmod 0640 alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml && sudo install -d -m 0755 /etc/systemd/system/prometheus.service.d && printf "[Service]\nEnvironment=\"METRICS_RETENTION_DAYS=2d\"\nEnvironment=\"PROMETHEUS_HOST=0.0.0.0\"\nEnvironment=\"PROMETHEUS_PORT=9090\"\n" | sudo tee /etc/systemd/system/prometheus.service.d/10-override.conf >/dev/null && sudo systemctl daemon-reload && echo "c3-01: prometheus config ok"'
```

```out
c3-01: prometheus config ok
```

> 陷阱：`*-generated.yml` 若是 root 擁有，C3 啟動會報 `AccessDeniedException`。
>
> 陷阱：上面最後兩段（`otlp`、`storage`）是從 C3 套件預設的 `prometheus-generated-local.yml` 抄來的，**不能省**。broker 用 OTLP 把指標送進 Prometheus，`promote_resource_attributes` 才會把資源屬性 `kafka.cluster.id`、`kafka.broker.id` 變成指標標籤。沒有它，指標沒有叢集標籤，C3 畫面上依叢集、broker 篩選的圖表都比對不到資料，而畫面看起來一切正常（2026-10-26 lab 實測：補上之後 40 秒內帶標籤的資料點從 0 變成 7 萬多筆）。

> 這一章裝的 C3 是**基底的 2.5.1**。2.5.1 套件預設的 `prometheus-generated-local.yml` 就有同樣的 `otlp`、`storage` 兩段，和 2.6.1 逐字相同（2026-10-28 把兩個 RPM 的 `/etc/confluent-control-center/` 逐檔比對，唯一差別是 `control-center-dev.properties` 多一行 `confluent.controlcenter.docs.host`；`control-center.properties` 與 systemd 的三個 unit 檔相同）。所以這一章的設定在 2.5.1 與遷移後的 2.6.1 都適用，21.3 換 C3 版本時不用改設定，只要把 C3 自己寫的 4 個 generated 檔擁有者改回來。

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
confluent.controlcenter.prometheus.ssl.keystore.location=/etc/confluent/ssl/c3-monitoring.p12
confluent.controlcenter.prometheus.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.alias.name=c3-monitoring
confluent.controlcenter.alertmanager.url=https://c3-01.poc.lab:9093
confluent.controlcenter.alertmanager.config.file=/etc/confluent-control-center/alertmanager-generated.yml
confluent.controlcenter.alertmanager.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.alertmanager.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.keystore.location=/etc/confluent/ssl/c3-monitoring.p12
confluent.controlcenter.alertmanager.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.alias.name=c3-monitoring
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
ssh c3-01.poc.lab 'for u in prometheus alertmanager confluent-control-center; do sudo systemctl enable --now $u >/dev/null 2>&1; sudo systemctl restart $u; sleep 3; printf "%-26s %s\n" $u "$(systemctl is-active $u)"; done'; echo "prometheus=$(curl -s -o /dev/null -w '%{http_code}' --cert ~/pki/certs/c3-monitoring.crt --key ~/pki/keys/c3-monitoring.key https://c3-01.poc.lab:9090/-/ready)"; for i in $(seq 1 24); do c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://c3-01.poc.lab:9021/); [ "$c" = 200 ] && break; sleep 10; done; echo "c3 ui=$c after ~$((i*10))s"
```

```out
prometheus                 active
alertmanager               active
confluent-control-center   active
prometheus=200
c3 ui=200 after ~30s
（第一次啟動 30–120 秒都正常）
```

確認指標真的帶有叢集標籤（上面那個陷阱的檢查）。ops02 連不到 c3-01 的 9090（防火牆只對外開 9021），所以在 c3-01 上用它自己的憑證查：

```bash
ssh c3-01.poc.lab bash -s <<'REMOTE'
Q='count(count by (kafka_broker_id) ({kafka_broker_id=~".+"}))'
for i in $(seq 1 18); do
  n=$(sudo curl -s --cacert /etc/confluent/ssl/ca.pem --cert /etc/confluent/ssl/c3-monitoring.crt --key /etc/confluent/ssl/c3-monitoring.key --data-urlencode "query=$Q" https://c3-01.poc.lab:9090/api/v1/query | sed -n 's/.*"value":\[[0-9.]*,"\([0-9]*\)".*/\1/p')
  [ -n "$n" ] && [ "$n" -gt 0 ] && break; sleep 10
done
echo "指標帶 kafka_broker_id 標籤的節點數：${n:-0}（等了約 $((i*10)) 秒）"
REMOTE
```

```out
指標帶 kafka_broker_id 標籤的節點數：5（等了約 10 秒）
```

只要大於 0 就代表標籤有帶上來。數字會隨 telemetry 陸續送進來而增加，穩定後是 7（4 台 broker 加 3 台 controller，各自的 node id；實測剛啟動 10 秒時是 5）。**0 代表缺 `otlp` 設定，或 broker 的 telemetry 沒送進來**，C3 畫面上的圖會是空的。

lab 裡：Windows 瀏覽器開 `https://localhost:19021`（正式環境是維運人員直連 C3 的 9021），用 alice 登入（密碼在 `~/secrets/ad-test-users.pass`）。憑證是銀行 CA 簽的，瀏覽器沒裝銀行根憑證會有警告，lab 先略過。Alertmanager 的 9093 只開給同一台的 C3，從操作機連不到是正常的。

# 14. 終點：小安的檢查清單

**這一章在做什麼**：基本安裝（第 1–13 章）到此告一段落。這一章先用幾個檢查確認整套健康，再給出「出問題先看哪裡」、「做錯了怎麼重來」、「常見的坑」三張查詢表，最後交代後面章節的走法。

到這裡平台已經能用，但還不能交付。後面分兩段：

- **交付前一定要做**：第 15 章把設定檔裡的密碼加密、master key 交 CyberArk 保管；第 16 章維運選單；第 17 章監控（JMX exporter，交付行內 Prometheus、Alertmanager、Grafana 的設定）；第 18 章稽核日誌；第 22.2 的 license 到期排程、第 25 章每日備份；最後第 19 章驗收與收尾。
- **遷移到目標版本**（主線，裝完基底的下一步）：第 21 章遷移 Confluent 與 JDK（8.2.4 → 8.3.2、JDK 21 → 25，C3 2.5.1 → 2.6.1）、第 26 章 OS 小版本更新（9.6 → 9.8）；每一段之後再跑第 19 章驗收。
- **上線之後依需要**：第 20 章憑證輪替（每年）、第 23 章換 controller、第 24 章增減 broker、第 26 章每月 OS 修補、第 27 章單獨換 Control Center 版本。

@role 小安 | ops02 | root

全部做完，用這幾條確認整套是健康的：

```bash
export JAVA_HOME=/opt/java/current; for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'printf "%-5s %s\n" "$(hostname)" "$(systemctl is-active confluent-server)"'; done; kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status | grep LeaderId; for h in kb01 kb02 kb03 kb04; do printf "%s MDS=%s " $h "$(curl -s -o /dev/null -m 5 -w %{http_code} https://$h.poc.lab:8090/v1/metadata/id)"; done; echo; echo "topics: $(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list | grep -v '^_' | paste -sd' ')"; echo "rest via LB: $(curl -s -o /dev/null -m 30 -w %{http_code} --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key https://rest.poc.lab:8082/v3/clusters)"; echo "c3 ui: $(curl -s -o /dev/null -m 10 -w %{http_code} https://c3-01.poc.lab:9021/)"; echo "metrics in prometheus: $(curl -s -m 10 --cert ~/pki/certs/c3-monitoring.crt --key ~/pki/keys/c3-monitoring.key https://c3-01.poc.lab:9090/api/v1/label/__name__/values | grep -o 'confluent_kafka_server[a-z_]*' | sort -u | wc -l) kinds"
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
| 11 台主機就緒、套件裝好並鎖版本 | 設定檔密碼加密、master key 交 CyberArk（第 15 章） |
| 9 張銀行憑證、truststore、MDS token 金鑰 | 維運選單（OP menu）；稽核日誌分流與專用寫入帳號 |
| controller、broker、MDS、RBAC（人員綁 AD 群組） | 外部監控：JMX exporter（7071）與行內 Prometheus、Alertmanager、Grafana 的設定（第 17 章） |
| 應用程式 SCRAM 帳號、配額、範例 topic | 正式的端對端驗收清單 |
| REST Proxy（憑證認證，經負載平衡）、C3（含 Prometheus） | 收回安裝帳號的 sudo、移交文件；之後的憑證輪替（第 20 章）、升級（第 21 章） |

## 14.1 出問題先看哪裡

| 元件 | 主機 | 服務名稱 | 看日誌 | 健康檢查 |
|---|---|---|---|---|
| controller、broker | kc*、kb* | `confluent-server` | `sudo journalctl -u confluent-server -n 100 --no-pager` | quorum 有 leader；broker 的 `https://<host>:8090/v1/metadata/id` 回 200 |
| REST Proxy | rest* | `confluent-kafka-rest` | `sudo journalctl -u confluent-kafka-rest -n 100 --no-pager` | 帶 legacy 憑證 `curl …:8082/v3/clusters` 回 200 |
| Control Center | c3-01 | `confluent-control-center`、`prometheus`、`alertmanager` | `sudo journalctl -u confluent-control-center -n 100 --no-pager` | `https://c3-01.poc.lab:9021/` 回 200 |
| AD | ad01 | samba（entrypoint 常駐） | lab 裡：`docker logs lab-ad01-1` | `openssl s_client -connect ad01.poc.lab:636` 驗證通過 |
| 套件庫 | repo01 | `httpd` | lab 裡：`docker exec lab-repo01-1 journalctl -u httpd -n 50` | `https://repo01.poc.lab/confluent/repodata/repomd.xml` 回 200 |

任何服務起不來或行為不對，先看三件事：服務是不是 `active`、ExecStart 指向哪份設定、日誌最後 20 行的 ERROR。九成的問題在這裡。

> 陷阱：broker 是 `active`、9092 也開了，但 9094／9095／9096 和 MDS 的 8090 一直沒開，日誌最後停在 `Waiting for all of the authorizer futures to be completed`、之後沒有任何 ERROR：多半是 AD 查詢帳號（svc-mds-bind）的密碼和 AD 上的不一致。broker 第一次向 AD 查群組失敗後只會安靜地重試，不印原因。對齊密碼（`ldap-bind.pass` 與 AD 帳號）後不用重啟，它會自己接著起來。

## 14.2 做錯了怎麼重來

| 步驟 | 能不能重跑 | 怎麼做 |
|---|---|---|
| 派送憑證、設定檔、drop-in（第 10–13 章） | 可以，重跑就是覆蓋成一樣的內容 | 改完記得 `sudo systemctl restart <unit>` |
| 格式化儲存（10.4） | **不能**，`meta.properties` 存在就會拒絕 | 真要重來：停服務、`sudo rm -rf /var/lib/kafka/data/*`，所有 controller 和 broker 一起重做 |
| 憑證（第 9 章） | 可以，重新產生 CSR 再請銀行簽 | 舊的 `~/pki` 先改名保留；已經上線的環境照第 20 章換發，不要重跑第 9 章 |
| 裝套件（第 8 章） | 可以，dnf 看到已安裝就略過 | `versionlock add` 對已鎖的套件會再加一筆重複，重跑前先 `sudo dnf versionlock list` 看一下，已鎖的不要再加 |
| 整台主機重置 | lab 可以；正式環境由銀行重新交付主機 | `docker compose -f compose.yml rm -sf <host> && docker compose -f compose.yml up -d <host>`，再對那台重做：3.2（根憑證信任與 OS 套件來源）、第 5 章（JDK）、第 7 章（OS 調校）、第 8 章（套件），以及它的角色在第 10、12、13 章的派送與啟動 |

## 14.3 小安踩過的坑

| 坑 | 症狀 | 怎麼避免 |
|---|---|---|
| 服務用 RPM 預設設定起來 | REST Proxy 開成無加密 HTTP；C3 連不上 Kafka | 啟動前看 `systemctl show <unit> -p ExecStart`，一定要指向我們的設定檔 |
| `enable --now` 不重啟 | 改了設定沒生效 | 改設定後明確 `systemctl restart` |
| 確認指令沒加 `sudo` | `ls /etc/confluent/ssl` Permission denied，以為沒放進去 | 0750 的目錄要 `sudo ls`、`sudo stat` |
| 相對路徑 | `scp certs/cp-server.p12` 只在特定目錄下才找得到 | 指令裡一律寫 `~/pki/certs/…` |
| C3 比 MDS 先起來 | 9021 不回應、日誌 `Failed to fetch MDS URLs … Client has already been closed`，而且不會自己好 | drop-in 加 `ExecStartPre` 等 MDS（第 13 章已加）；broker 全部重啟過一輪後若 C3 卡住，`systemctl restart confluent-control-center` |
| lab 專用：Git Bash 的 openssl 看不懂 `/c/Users/...` | `sign.sh` 靜靜失敗、沒有產出 `.crt` | 路徑先用 `cygpath -m` 轉成 `C:/Users/...`（0.5.5 的腳本已內建） |
| lab 專用：Docker 網段撞到別的 lab | `compose up` 報 `Pool overlaps` | 換 compose.yml 的 subnet 與 extra_hosts 的 IP（0.5.6） |
| C3 的 `*-generated.yml` 是 root 擁有 | `AccessDeniedException` | 四個 generated 檔給 `cp-control-center:confluent` |
| dnf 快取太舊 | 剛上架的套件「找不到」 | 加 `--refresh` |
| lab 專用：建銀行 OS 套件庫（3.2）時先裝工具再下載 | 套件庫少了 `createrepo_c-libs` | 乾淨容器，先下載、再裝工具 |
| lab 專用：Docker VM 網路層卡死 | 所有 Java 都變慢、`docker stats` 也卡 | 任一容器 `timeout 5 ip addr` 卡住就重啟 Docker Desktop，不要查設定 |

# 15. 第十五站：Secret Protection，master key 交 CyberArk 保管

下面這張圖說明 passphrase、master key、密文三者的關係與各自放哪裡。

![keyhier]


![secretprotection]

**這一章在做什麼**：讓設定檔裡不再有明文密碼。小安用 Confluent 的 Secret Protection 把密碼加密，再把解密用的 master key 交銀行的 CyberArk 保管。前提：第 10–13 章的服務都已經起來、第 9 章的 `~/pki/store.pass` 與 `~/secrets/` 裡的密碼檔都在。這一章會**滾動重啟**所有 controller、broker、REST Proxy、C3（15.5），請在變更時段一台一台做。

設定檔裡的密碼要加密。本案客戶的 CyberArk 只有 PAM（程式不會向保管庫取值），所以用 Confluent 自己的 **Secret Protection**：密碼加密後留在主機上的 `security.properties`，解密用的 master key 由 CyberArk 保管（PVWA），啟動時經環境變數給服務。

```
passphrase ──(＋隨機 salt)──▶ master key ──▶ data key ──▶ 各個密碼的密文（security.properties）
（CyberArk 保管）              （CyberArk 保管）
                                   │
                        各主機 /etc/confluent/service.env（0600 root）→ systemd EnvironmentFile → 服務環境變數
```

| 誰 | 做什麼 |
|---|---|
| 銀行 Secrets 團隊 | PVWA 同一個 safe 開兩個 object：passphrase（銀行產生，只給平台工程師）、master key（15.2 產生後存入）；lab 用 `~/kafka-lab/pvwa/` 資料夾模擬 |
| 小安 | 取 passphrase 產 master key、交 CyberArk 保管、加密 properties、派送、滾動重啟；之後的 master key 輪替也是他 |

**為什麼兩樣都要存**（lab 實測）：master key 是 passphrase 加上一個隨機 salt 算出來的，salt 每次 `generate` 都重新產生，所以**只有 passphrase 算不回原本的 master key**；反過來，輪替 master key（15.6）時 CLI 要「目前的 master key＋舊 passphrase」兩樣都給。分成兩個 object 是為了分開授權：master key 給要啟動服務的一方（每台主機的 `service.env`），passphrase 主機不應該讀得到。

## 15.1 銀行開好兩個 object，放進 passphrase


@role 銀行 Secrets 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

PVWA 同一個 safe 裡開兩個 object：`kafka-sp-passphrase`（值由銀行產生，只授權平台工程師取用）、`kafka-sp-master-key`（先開好，15.2 產生後存入）。lab：

```bash
cd ~/kafka-lab && mkdir -p pvwa && (umask 077; [ -s pvwa/sp-passphrase.txt ] || openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > pvwa/sp-passphrase.txt) && echo "kafka-sp-passphrase: $(wc -c < pvwa/sp-passphrase.txt) chars"
```

```out
kafka-sp-passphrase: 32 chars
```

## 15.2 小安取 passphrase、產生 master key


@role 小安（從 PVWA 取出；lab 由 Windows 終端代貼） | Windows 終端 | 本機

從 PVWA 取出 passphrase，放進操作機的 0600 檔（正式環境在操作機上 `(umask 077; IFS= read -rsp '貼上後按 Enter：' P && printf %s "$P" > ~/secrets/sp-passphrase.txt; unset P; echo)`，同 3.4 不顯示的寫法；不要貼進任何對話或工單）：

```bash
docker exec -i lab-ops02-1 bash -c 'umask 077; cat > ~/secrets/sp-passphrase.txt; echo "passphrase: $(wc -c < ~/secrets/sp-passphrase.txt) chars"' < ~/kafka-lab/pvwa/sp-passphrase.txt
```

```out
passphrase: 32 chars
```


@role 小安 | ops02 | root

用 Confluent CLI 產生 master key。`security.properties` 是之後所有密文的容器：

```bash
(umask 077; confluent secret master-key generate --local-secrets-file ~/secrets/security.properties --passphrase "$(cat ~/secrets/sp-passphrase.txt)" -o yaml | awk '/master_key/{print $2}' > ~/secrets/master.key) && echo "master key: $(wc -c < ~/secrets/master.key) chars" && ls -la ~/secrets/security.properties ~/secrets/master.key
```

```out
Save the master key. It cannot be retrieved later.
master key: 45 chars
-rw------- 1 root root  45 … master.key
-rw------- 1 root root 169 … security.properties
```

> 陷阱：`--passphrase` 一定要給**值本身**（`"$(cat 檔案)"`）。Confluent CLI v4 不認 `@檔案`、也不認 `-`（stdin），會把「`@/root/secrets/sp-passphrase.txt`」這串字當成 passphrase：產生、加密、輪替表面上都成功，但銀行給的 passphrase 根本沒用到，任何拿到 `security.properties` 又猜得到路徑的人都算得出 master key；檔案一改名，下一次輪替就 `incorrect master key passphrase`（2026-10-25 lab 實測）。15.6 結尾有檢查。
>
> 給值的代價是執行那一瞬間值會出現在操作機的行程參數裡（`/proc/<pid>/cmdline`）。能登入操作機的人員都是 root（經 PVWA＋PSMP，全程錄影），`hidepid` 擋不住 root，所以這是接受的風險：靠 PVWA 的授權與 PSMP 的錄影管住「誰能進操作機」。15.8、11.2 用 `--config`／`--add-config` 帶密碼時也一樣。

「cannot be retrieved later」是 CLI 的提醒：CLI 不保存 master key，而且**再跑一次 `generate` 也拿不回同一把**（會換新的 salt，算出另一把）。所以產生之後馬上交 CyberArk 保管，確認存好了才往下派送；不能讓一把只存在操作機上的 key 上線。


@role 銀行 Secrets 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

小安把 `master.key` 的內容交 Secrets 團隊存進 PVWA 的 `kafka-sp-master-key`（新版本；舊版本保留，回滾要用）。`tr -d '\n'` 是必要的：檔尾的換行要是跟著存進去，之後取回來貼上時多一個字元，服務就解不開密文。lab：

```bash
cd ~/kafka-lab && (umask 077; docker exec lab-ops02-1 cat /root/secrets/master.key | tr -d '\n' > pvwa/master-key.txt) && echo "kafka-sp-master-key stored, hash $(sha256sum < pvwa/master-key.txt | cut -c1-12)"
```

```out
kafka-sp-master-key stored, hash 3f9c0a…（12 碼雜湊）
```

@role 小安 | ops02 | root

存好之後，記下這一把的雜湊和變更單號，雜湊要和上一步 Secrets 團隊回報的一樣；之後主機重建、輪替時都用它核對 PVWA 裡存的是不是這一把：

```bash
(umask 077; echo "$(tr -d '\n' < ~/secrets/master.key | sha256sum | cut -c1-12) CHG-xxxx" > ~/secrets/master-key.custody) && cat ~/secrets/master-key.custody
```

```out
3f9c0a… CHG-xxxx
```


> 注意：只存 passphrase 是不夠的。passphrase 遺失、master key 還在：服務照常，只是不能用 15.6 的 `rotate`；master key 遺失：服務照常（每台的 `service.env` 都有），但主機重建時拿不到；兩樣都遺失：產生新的 master key、照 15.3–15.5 從明文來源重新加密並滾動重啟（約 30 分鐘，不中斷服務）。

## 15.3 加密每台的 properties

@role 小安 | ops02 | root

先用第 10、12、13 章的方式從範本產生每台的設定（和之前完全一樣，只是這次先留在操作機、不派送），再逐檔加密所有 `password`／`credentials` 欄位。加密後原檔裡的值變成 `${securepass:…}` 參照，密文集中寫進 `security.properties`：

```bash
cd ~/conf && export STORE_PASSWORD=$(cat ~/pki/store.pass) LDAP_BIND_PASSWORD=$(cat ~/secrets/ldap-bind.pass) AUDIT_PASSWORD=$(cat ~/secrets/confluent-audit.pass 2>/dev/null) && V='${HOST_FQDN} ${NODE_ID} ${RACK} ${REST_ID} ${STORE_PASSWORD} ${LDAP_BIND_PASSWORD} ${AUDIT_PASSWORD}' && for h in kc01:1:- kc02:2:- kc03:3:- kb01:101:rack-a kb02:102:rack-a kb03:103:rack-b kb04:104:rack-b; do IFS=: read -r n id rack <<<"$h"; export HOST_FQDN=$n.poc.lab NODE_ID=$id RACK=$rack; case $n in kc*) tpl=controller.tpl;; *) tpl=broker.tpl;; esac; (umask 077; { envsubst "$V" < $tpl; echo; envsubst "$V" < common.tpl; } > $n.server.properties); done; for h in rest01 rest02; do export HOST_FQDN=$h.poc.lab REST_ID=$h; (umask 077; envsubst "$V" < kafka-rest.tpl > $h.kafka-rest.properties); done; (umask 077; envsubst "$V" < control-center.tpl > c3-01.control-center.properties); unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD; echo "沒替換到的變數：$(grep -ho '${[A-Z_]*}' *.server.properties *.kafka-rest.properties c3-01.control-center.properties | sort -u | paste -sd' ' | sed 's/^$/0 個/')"; export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key); for f in *.server.properties *.kafka-rest.properties c3-01.control-center.properties; do keys=$(grep -E '^[^#].*(password|credentials)=' $f | cut -d= -f1 | paste -sd,); confluent secret file encrypt --config-file $f --local-secrets-file ~/secrets/security.properties --remote-secrets-file /etc/confluent/secrets/security.properties --config "$keys" >/dev/null && echo "$f: $(grep -c '\${securepass:' $f) encrypted, plaintext=$(grep -cE '^[^#].*(password|credentials)=[^$]' $f)"; done; unset CONFLUENT_SECURITY_MASTER_KEY; echo "security.properties: $(grep -c '^[^_].*ENC\[' ~/secrets/security.properties) entries"
```

```out
沒替換到的變數：0 個
kb01.server.properties: 17 encrypted, plaintext=0
（broker 17、controller 11、REST 9、C3 18；做過第 18 站的話 broker 19、controller 13。10 個檔 plaintext 都是 0）
security.properties: 137 entries（做過第 18 站是 151）
```

> `${securepass:/etc/confluent/secrets/security.properties:kb01.server.properties/ssl.keystore.password}` 的最後一段是「本機檔名／欄位」，所以同一份 `security.properties` 可以放所有主機的密文，派送時每台拿同一個檔。

## 15.4 派送：properties、密文檔、master key

@role 小安 | ops02 | root

三樣東西到每台：加密後的 properties（原路徑）、`security.properties`（0640 root:confluent）、`service.env`（0600 root，只有一行 master key）。drop-in 加 `EnvironmentFile=`：

```bash
cd ~/conf && (umask 077; echo "CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)" > ~/secrets/service.env) && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do case $h in rest*) f=$h.kafka-rest.properties; dst=/etc/confluent/kafka-rest/kafka-rest.properties; u=confluent-kafka-rest;; c3*) f=c3-01.control-center.properties; dst=/etc/confluent/control-center/control-center.properties; u=confluent-control-center;; *) f=$h.server.properties; dst=/etc/confluent/kafka/server.properties; u=confluent-server;; esac; scp -q $f ~/secrets/security.properties ~/secrets/service.env $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo install -o root -g confluent -m 0640 /tmp/$f $dst && sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets && sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && sudo install -o root -g root -m 0600 /tmp/service.env /etc/confluent/service.env && rm -f /tmp/$f /tmp/security.properties /tmp/service.env && printf '[Service]\nEnvironmentFile=/etc/confluent/service.env\n' | sudo tee /etc/systemd/system/$u.service.d/20-secret-protection.conf >/dev/null && sudo systemctl daemon-reload && echo \"\$(hostname): refs=\$(sudo grep -c 'securepass:' $dst) plaintext=\$(sudo grep -cE '^[^#].*(password|credentials)=[^\$]' $dst) env=\$(systemctl show $u -p EnvironmentFiles --value | cut -d' ' -f1)\""; done; rm -f ~/secrets/service.env
```

```out
kc01: refs=11 plaintext=0 env=/etc/confluent/service.env
（10 行；refs 和上一步的 encrypted 數相同）
```

## 15.5 滾動重啟、驗證

加密過的設定要重啟才會生效。順序：controller（一台一台，等 active）→ broker（一台一台，等 MDS 回 200，每台約 20–50 秒）→ C3 → REST Proxy（先請 LB 團隊停用那一台，見 12.1）。每一台健康了才做下一台，這樣叢集一直有多數派可用。

@role 小安 | ops02 | root

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) after ~$((i*5))s"; done; ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'; for i in $(seq 1 36); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3 ui=$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) after ~$((i*5))s"; echo "alice login: $(curl -sk -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)"
```

```out
kc01 active
（3 行）
kb01 MDS=200 after ~20s
（4 行，20–50 秒）
c3 ui=200 after ~80s
alice login: 200
```


@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

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

最後確認 passphrase 真的有用上（15.2 的陷阱）：在副本上試著輪替一次，正式檔不動。兩個都要是「是」；前一個是「否」代表 master key 不是用 PVWA 那組 passphrase 產生的，照 15.7「遺失怎麼辦」重新產生、重新加密：

```bash
T=$(mktemp -d) && cp ~/secrets/security.properties $T/s && export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key) && ok=$(confluent secret file rotate --master-key --passphrase "$(cat ~/secrets/sp-passphrase.txt)" --passphrase-new "check-$(openssl rand -hex 8)" --local-secrets-file $T/s -o yaml 2>&1 </dev/null | grep -c 'Save the master key') && bad=$(confluent secret file rotate --master-key --passphrase "wrong-$(openssl rand -hex 8)" --passphrase-new "check-$(openssl rand -hex 8)" --local-secrets-file $T/s -o yaml 2>&1 </dev/null | grep -c 'incorrect master key passphrase'); unset CONFLUENT_SECURITY_MASTER_KEY; rm -rf $T; echo "目前的 passphrase 還能輪替：$([ "$ok" = 1 ] && echo 是 || echo 否)；錯的 passphrase 被拒：$([ "$bad" = 1 ] && echo 是 || echo 否)"
```

```out
目前的 passphrase 還能輪替：是；錯的 passphrase 被拒：是
```

## 15.6 演練：輪替 master key


@role 銀行 Secrets 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

銀行產生新 passphrase、更新 PVWA 的 `kafka-sp-passphrase`（舊版本保留）：

```bash
cd ~/kafka-lab && (umask 077; openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > pvwa/sp-passphrase-new.txt) && echo "new passphrase stored"
```

```out
new passphrase stored
```

@role 小安（從 PVWA 取出新 passphrase；lab 由 Windows 終端代貼） | Windows 終端 | 本機

正式環境同 15.2 不顯示的寫法，檔名換成 `sp-passphrase-new.txt`：

```bash
docker exec -i lab-ops02-1 bash -c 'umask 077; cat > ~/secrets/sp-passphrase-new.txt; echo "new passphrase: $(wc -c < ~/secrets/sp-passphrase-new.txt) chars"' < ~/kafka-lab/pvwa/sp-passphrase-new.txt
```

```out
new passphrase: 32 chars
```


@role 小安 | ops02 | root

小安手上還有舊 passphrase（`sp-passphrase.txt`），用 `rotate --master-key` 把 data key 重新包一次。密碼本身與 properties 都不動，只有 `security.properties` 和各主機的 `service.env` 要換：

```bash
cp -p ~/secrets/security.properties ~/secrets/security.properties.bak && cp -p ~/secrets/master.key ~/secrets/master.key.bak && export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key) && (umask 077; confluent secret file rotate --master-key --passphrase "$(cat ~/secrets/sp-passphrase.txt)" --passphrase-new "$(cat ~/secrets/sp-passphrase-new.txt)" --local-secrets-file ~/secrets/security.properties -o yaml | awk '/master_key/{print $2}' > ~/secrets/master.key) && unset CONFLUENT_SECURITY_MASTER_KEY && echo "master key changed: $([ "$(sha256sum < ~/secrets/master.key)" = "$(sha256sum < ~/secrets/master.key.bak)" ] && echo no || echo yes)" && mv ~/secrets/sp-passphrase-new.txt ~/secrets/sp-passphrase.txt && (umask 077; echo "CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)" > ~/secrets/service.env) && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q ~/secrets/security.properties ~/secrets/service.env $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && sudo install -o root -g root -m 0600 /tmp/service.env /etc/confluent/service.env && rm -f /tmp/security.properties /tmp/service.env && printf "%s " $(hostname)'; done; rm -f ~/secrets/service.env; echo
```

```out
Save the master key. It cannot be retrieved later.
master key changed: yes
kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
```

（精簡的 OS 沒有 `cmp`，所以用 sha256sum 比對。）

新的 master key 一樣**先交 CyberArk 保管再上線**，兩個 object 都換成新值，舊版本留著回滾用：


@role 銀行 Secrets 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && cp -p pvwa/master-key.txt pvwa/master-key.prev.txt && cp -p pvwa/sp-passphrase.txt pvwa/sp-passphrase.prev.txt && (umask 077; docker exec lab-ops02-1 cat /root/secrets/master.key | tr -d '\n' > pvwa/master-key.txt) && mv pvwa/sp-passphrase-new.txt pvwa/sp-passphrase.txt && echo "kafka-sp-master-key stored, hash $(sha256sum < pvwa/master-key.txt | cut -c1-12)（舊版本另存 .prev）"
```

```out
kafka-sp-master-key stored, hash 7d21e4…（和 15.2 那一把不同）（舊版本另存 .prev）
```

@role 小安 | ops02 | root

```bash
(umask 077; echo "$(tr -d '\n' < ~/secrets/master.key | sha256sum | cut -c1-12) CHG-yyyy" > ~/secrets/master-key.custody) && cat ~/secrets/master-key.custody
```

```out
7d21e4… CHG-yyyy
```


@role 小安 | ops02 | root

然後照 15.5 再滾動重啟一次（指令相同），每台起得來就代表新 master key 解得開：

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done; ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'; for i in $(seq 1 36); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3 ui=$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"; echo "alice login after master key rotation: $(curl -sk -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)"; rm -f ~/secrets/security.properties.bak ~/secrets/master.key.bak
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
c3 ui=200
alice login after master key rotation: 200
```


@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

輪替完照 15.5 最後那個檢查再做一次：新的 passphrase（保管庫的現行版本）＋新的 master key 要能再輪替，下一次例行輪替才不會卡住：

```bash
T=$(mktemp -d) && cp ~/secrets/security.properties $T/s && export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key) && ok=$(confluent secret file rotate --master-key --passphrase "$(cat ~/secrets/sp-passphrase.txt)" --passphrase-new "check-$(openssl rand -hex 8)" --local-secrets-file $T/s -o yaml 2>&1 </dev/null | grep -c 'Save the master key') && bad=$(confluent secret file rotate --master-key --passphrase "wrong-$(openssl rand -hex 8)" --passphrase-new "check-$(openssl rand -hex 8)" --local-secrets-file $T/s -o yaml 2>&1 </dev/null | grep -c 'incorrect master key passphrase'); unset CONFLUENT_SECURITY_MASTER_KEY; rm -rf $T; echo "目前的 passphrase 還能輪替：$([ "$ok" = 1 ] && echo 是 || echo 否)；錯的 passphrase 被拒：$([ "$bad" = 1 ] && echo 是 || echo 否)"
```

```out
目前的 passphrase 還能輪替：是；錯的 passphrase 被拒：是
```

> 回滾：在刪掉 `.bak` 之前，把 `security.properties.bak` 和 `master.key.bak` 用 15.4 的方式派送回去、再滾動重啟一次，就回到舊 master key。所以 `.bak` 要等全部驗證完才刪。

## 15.7 要跟資安說清楚的事

| 項目 | 說明 |
|---|---|
| secret zero | master key 以一行落在每台主機的 `/etc/confluent/service.env`（0600 root）。本案客戶的 CyberArk 只有 PAM（沒有 CCP），服務啟動時不能向保管庫取值，所以 master key 一定落在主機上；資安若不接受磁碟副本，要另外提出需求，不在本手冊範圍 |
| CyberArk 在這裡做什麼 | **保管與稽核，不參與執行期**：passphrase、master key 的正本與版本（重建主機、復原、輪替時取用）；誰在什麼時候取了、對應哪張變更單；以及 PSM／PSMP 控管誰能登入主機變成 root。服務啟動時不連 CyberArk |
| 擋得住什麼、擋不住什麼 | 擋得住：設定檔被複製出去（備份、工單附檔、診斷資料、`confluent` 群組的人）時看不到密碼。擋不住：這台主機上的 root（`service.env` 就在本機）。要連 root 都擋，需要啟動時向外取 master key 的機制（本案客戶沒有 CCP，做不到） |
| 遺失怎麼辦 | `rotate` 一定要**同時**有舊 passphrase 和舊 master key（環境變數），CLI 也沒有辦法從 passphrase＋`security.properties` 重新算出 master key（2026-10-25 lab 實測），所以兩個 object 都要保管。master key 遺失：從 PVWA 取回（服務啟動要它）。passphrase 遺失：服務照跑，但不能 `rotate`。缺一個又取不回：產生新的 master key、照 15.3–15.5 重新加密（不中斷服務） |
| data key | `security.properties` 裡真正加密每筆密碼的那把，被 master key 包著。**不做例行輪替**：15.6 換的是外層的 master key。懷疑外洩時，拿到舊 master key＋舊 `security.properties` 的人已經解得出明文，所以要換的是**密碼本身**（keystore 跟著第 20 章換證、SCRAM 與 AD 查詢密碼用 `update`／15.8），再照 15.3–15.5 重新加密 |
| 誰輪替 | CPM 不會自動輪替這種金鑰；由平台工程師依變更單執行 15.6，兩個 object 一起更新 |
| 密碼本身的輪替 | 另一條流程：改密碼 → `confluent secret file update`（或重新 `encrypt` 該欄位）→ 派送 → 重啟，與 master key 輪替無關。CPM 管的 AD 查詢密碼見 15.8 |

> 陷阱：做過這一章之後，若回頭照第 10、12、13 章重新產生設定並派送，會把明文密碼寫回主機；改了設定要照 15.3–15.5 重新加密、派送、重啟。

## 15.8 演練：CPM 換了 AD 查詢帳號的密碼


`svc-mds-bind` 的密碼加密後固定在 `security.properties`。CPM 一換 AD 密碼，broker 手上就是舊的：當下靠群組快取撐著，下次重啟時 MDS 起不來（14.1 的陷阱：卡在 `Waiting for all of the authorizer futures`）。所以 CPM 換完，平台要跟著做一次：從 PVWA 取新密碼 → 只更新這一個欄位的密文 → 派送 `security.properties` → 滾動重啟。

> 待銀行確認：這個帳號的 CPM 輪替要**關掉自動排程、改成依變更單觸發**（CPM 換完通知平台工程師接著做這一節），或開 A／B 兩組查詢帳號交替（CPM 只換閒置的那組，平台切過去再滾動重啟，中間沒有空窗）。手冊以「依變更單觸發、單一帳號」為準。

@role 銀行 AD 團隊（CPM 換密碼；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

正式環境這一步是 CPM：改 AD、更新 PVWA 的 object，一次完成。lab 用 samba-tool 改密碼，再寫進 pvwa/（舊值另存 `.prev`）：

```bash
docker exec lab-ad01-1 bash -c 'until P=$(openssl rand -base64 24 | tr -dc "A-Za-z0-9" | head -c 20); [[ $P =~ [A-Z] && $P =~ [a-z] && $P =~ [0-9] ]]; do :; done; samba-tool user setpassword svc-mds-bind --newpassword="$P" >/dev/null && printf "%s" "$P" > /root/secrets/bind.pass && echo "AD: password changed"' && cd ~/kafka-lab && cp -p pvwa/ldap-bind.pass pvwa/ldap-bind.prev.pass && (umask 077; docker exec lab-ad01-1 cat /root/secrets/bind.pass > pvwa/ldap-bind.pass) && echo "PVWA svc-mds-bind updated"
```

```out
AD: password changed
PVWA svc-mds-bind updated
```

@role 小安（從 PVWA 取出新密碼；lab 由 Windows 終端代貼） | Windows 終端 | 本機

正式環境同 3.4 不顯示的寫法（檔名 `ldap-bind.pass`）：

```bash
docker exec -i lab-ops02-1 bash -c 'umask 077; cat > ~/secrets/ldap-bind.pass; echo "ldap-bind.pass: $(wc -c < ~/secrets/ldap-bind.pass) chars"' < ~/kafka-lab/pvwa/ldap-bind.pass
```

```out
ldap-bind.pass: 20 chars
```

@role 小安 | ops02 | root

不用重做 15.3：`confluent secret file update` 只重算指定欄位的密文，properties 本身不動（裡面本來就是 `${securepass:…}` 參照）。controller 和 broker 共 7 個檔有這個欄位，所以 `security.properties` 裡應該剛好變 7 行：

```bash
cd ~/conf && cp -p ~/secrets/security.properties ~/secrets/security.properties.bak && export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key) && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do confluent secret file update --config-file $h.server.properties --local-secrets-file ~/secrets/security.properties --remote-secrets-file /etc/confluent/secrets/security.properties --config "ldap.java.naming.security.credentials=$(cat ~/secrets/ldap-bind.pass)" >/dev/null || echo "$h: update FAILED"; done; unset CONFLUENT_SECURITY_MASTER_KEY; d=$(grep -vxFf ~/secrets/security.properties.bak ~/secrets/security.properties); echo "changed lines: $(grep -c . <<<"$d"), of which ldap credentials: $(grep -c 'ldap.java.naming.security.credentials' <<<"$d")"
```

```out
changed lines: 7, of which ldap credentials: 7
```

> 新密碼會短暫出現在這台操作機的行程參數裡（`--config` 只吃命令列）。能登入操作機的只有經 PSMP 進來的人員（root，全程錄影），可以接受；介意的話就改走 15.3 整批重新加密。

`security.properties` 每台都是同一份，所以 10 台都派送（REST、C3 那幾行沒變，不用重啟）；只滾動重啟 controller 和 broker，再用 alice 的 AD 帳密登入 MDS 證明 bind 成功（MDS 要先用查詢帳號到 AD 找到 alice，才能驗她的密碼）：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q ~/secrets/security.properties $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && rm -f /tmp/security.properties'; done; for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done; echo "換密碼後 alice 登入 MDS：$(curl -sk -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)"; echo "kb01 ldap auth errors since restart: $(ssh kb01.poc.lab 'sudo journalctl -u confluent-server --since "$(systemctl show -p ActiveEnterTimestamp --value confluent-server)" --no-pager 2>/dev/null | grep -ci "javax.naming\|LDAP search failed"')"; echo "kb01 bind 欄位仍是密文參照：$(ssh kb01.poc.lab "sudo grep -c '^ldap.java.naming.security.credentials *= *\\\${securepass:' /etc/confluent/kafka/server.properties")"; rm -f ~/secrets/security.properties.bak
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
換密碼後 alice 登入 MDS：200
kb01 ldap auth errors since restart: 0
kb01 bind 欄位仍是密文參照：1
```

> 回滾（CPM 換錯、AD 被改回舊密碼）：刪 `.bak` 之前，把 `security.properties.bak` 派送回 10 台、再滾動重啟 controller 和 broker。
>
> CPM 換密碼之後要「取密碼 → 更新密文 → 派送 → 滾動重啟」，所以 CPM 不能悄悄換，一定要通知平台。

# 16. 第十六站：維運選單（OP menu）

![opmenu]

下面這張圖跟著一次選單操作，從登入走到記錄。

![opmenuflow]

**這一章在做什麼**：裝一個給維運人員用的文字選單（OP menu），讓他們用自己的 AD 帳號做日常作業（看狀態、重啟、看日誌、建 topic、查權限），不用記指令。前提：第 11 章的 RBAC 與 AD 群組已經建好，第 9 章的 `opmenu-breakglass` 憑證已簽發，3.1 的 cpuser 金鑰可用。名詞：選單裡每個項目有編號（例如 21 重啟、23 看日誌、91 緊急模式）；「緊急模式」就是平常用不到、用於 MDS 故障時的備用路徑（break-glass）。

平台交給維運之後，日常作業不該靠人記指令。小安帶了一個文字選單：維運人員經 CyberArk 登入操作機（進去是 root），執行選單、輸入自己的 AD 帳密，選單只顯示他有權限的項目，每一步留紀錄。重啟、看日誌這類要碰主機的動作，選單用 3.1 那把金鑰（`/secure/ssh/cpuser_ed25519`）以 cpuser ssh 過去做：金鑰就是檔案，**不再從 PVWA 取出貼進選單**；主機上不放任何代理程式，只靠 sudoers 限制 cpuser 能跑的指令（16.4：每個服務、每種寫法逐一列出）。

> **誠實的限制**：操作者在操作機上是 root，root 讀得到金鑰。所以選單「碰主機前先問 MDS：本人有沒有 Operator 以上的權限」是**流程控管，不是硬性隔離**（root 可以直接用金鑰 ssh，繞過選單）。追溯靠 CyberArk 的登入紀錄與 PSMP 錄影（誰在什麼時間進了 root），再加上選單紀錄和主機上 cpuser 的操作紀錄。**Kafka 類動作不受這個限制**：權限與稽核由 Kafka 端依本人 AD 身分強制，繞不過。

| 誰 | 做什麼 |
|---|---|
| 銀行 Secrets 團隊 | PVWA 裡一個 object：緊急模式用的憑證（16.2 小安交付）；授權給維運人員取用。（ssh 私鑰不在 PVWA） |
| 銀行 OS 團隊 | 各主機 cpuser 的 sudo 改成兩段式（16.4）；緊急主機模式的 OS 群組 `opmenu-emergency`（平常沒有成員） |
| 小安 | 交付緊急憑證、裝選單、派送設定、綁緊急身分的權限、試跑 |

選單取緊急憑證的方式：本案客戶只有 PVWA，維運人員從 PVWA 取出貼上。

## 16.1 銀行準備保管庫

**這一節在做什麼**：銀行 Secrets 團隊在 PVWA 先開好放緊急憑證的位置。PVWA 裡選單要用的 object（名稱依銀行慣例，寫進 16.3 的設定，選單會在提示裡告訴維運人員去哪裡取）：

| object | 內容 | 誰放 |
|---|---|---|
| `Safe KAFKA-OPS / opmenu-breakglass` | 緊急模式憑證（私鑰＋憑證鏈，PEM） | 小安在 16.2 交付 |

授權給維運人員（AD 群組）取用；每次取用 PVWA 都有紀錄，對得上選單紀錄裡的同一個人。lab 沒有要另外做的事。

## 16.2 交付緊急憑證、綁緊急身分的權限

**這一節在做什麼**：把緊急模式要用的身分準備好，並設定各群組的角色。第 9 章簽好備用的 `opmenu-breakglass` 憑證（私鑰＋憑證鏈，PEM）交給保管庫，再把 `User:opmenu-breakglass` 綁成 SystemAdmin，這就是選單 91（緊急模式）用的身分。

@role 銀行 Secrets 團隊（收下存進 PVWA；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && (umask 077; docker exec lab-ops02-1 bash -c 'cat /root/pki/keys/opmenu-breakglass.key /root/pki/certs/opmenu-breakglass.crt' > pvwa/opmenu-breakglass.pem) && echo "opmenu-breakglass：$(grep -c 'BEGIN' pvwa/opmenu-breakglass.pem) 段 PEM（私鑰＋憑證鏈）"
```

```out
opmenu-breakglass：3 段 PEM（私鑰＋憑證鏈）
```

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current && confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key >/dev/null 2>&1 && CID=$(curl -sk https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4) && confluent iam rbac role-binding create --principal User:opmenu-breakglass --role SystemAdmin --kafka-cluster "$CID" >/dev/null 2>&1; confluent iam rbac role-binding list --principal User:opmenu-breakglass --kafka-cluster "$CID" 2>/dev/null | tail -1
```

```out
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

## 16.3 裝選單

@role 小安 | Windows 終端 | 本機

**這一節在做什麼**：把選單套件經第 2 章的離線流程送進操作機，裝到 `/opt/opmenu` 並寫好設定。選單的原始碼是本專案的 `opmenu/`。在外網端打包（檔名帶日期與內容的雜湊，內容不同就不會蓋掉舊的），連同 SHA256SUMS 放進落地區，再照 2.4 送進來（`D=opmenu`）。落地區只留最新一版，下面的 `tar -xzf opmenu-*.tar.gz` 才不會同時解到兩個：

```bash
cd <放 opmenu/ 原始碼的目錄> && v=$(date +%Y%m%d).$(find opmenu -type f | sort | xargs cat | sha256sum | cut -c1-8) && mkdir -p ~/kafka-lab/landing/tools/opmenu && rm -f ~/kafka-lab/landing/tools/opmenu/opmenu-*.tar.gz && tar -czf ~/kafka-lab/landing/tools/opmenu/opmenu-$v.tar.gz opmenu && (cd ~/kafka-lab/landing/tools/opmenu && sha256sum opmenu-*.tar.gz > SHA256SUMS && cat SHA256SUMS)
```

```out
3f9c…  opmenu-20261024.1a2b3c4d.tar.gz
```

再把這一包送進操作機（就是 2.4 的做法，`D=opmenu`；操作機上舊的會先被清掉，不然 `opmenu-*.tar.gz` 會解到舊版）：

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

```bash
D=opmenu; [ -d "$HOME/kafka-lab/landing/tools/$D" ] || { echo "落地區還沒有 tools/$D（有檔案要送時再做）"; exit 0; }; docker exec lab-ops02-1 bash -c "chmod -R u+w /root/landing/tools/$D 2>/dev/null; rm -rf /root/landing/tools/$D" && docker cp "$(cygpath -m "$HOME/kafka-lab/landing/tools/$D")" lab-ops02-1:/root/landing/tools/ && docker exec lab-ops02-1 bash -c "chmod -R a-w /root/landing/tools/$D && cd /root/landing/tools/$D && ls && sha256sum -c --quiet SHA256SUMS && echo sha256-ok"
```

```out
SHA256SUMS
opmenu-20261028.2affc7e3.tar.gz
sha256-ok
```

@role 銀行 OS 團隊（lab 由小安代勞） | ops02 | root

選單從落地區解開到 `/opt/opmenu`（唯讀）；`/etc/opmenu/` 放設定、truststore、主機金鑰清單；`/var/log/opmenu/` 給紀錄與匯出檔。操作者都是 root，所以不需要另外的維運帳號與群組：

```bash
cd ~/landing/tools/opmenu && sha256sum -c --quiet SHA256SUMS && rm -rf /opt/opmenu && tar -xzf opmenu-*.tar.gz -C /opt && chown -R root:root /opt/opmenu && chmod -R a+rX /opt/opmenu && install -d -m 0755 /etc/opmenu /etc/opmenu/ssl && install -m 0644 ~/pki/certs/truststore.p12 /etc/opmenu/ssl/truststore.p12 && install -m 0600 ~/pki/store.pass /etc/opmenu/ssl/truststore.pass && install -m 0644 /etc/pki/ca-trust/source/anchors/bank-root.pem /etc/opmenu/ssl/ca.pem && ssh-keyscan -t ed25519 kc01.poc.lab kc02.poc.lab kc03.poc.lab kb01.poc.lab kb02.poc.lab kb03.poc.lab kb04.poc.lab rest01.poc.lab rest02.poc.lab c3-01.poc.lab 2>/dev/null | sort | install -m 0644 /dev/stdin /etc/opmenu/known_hosts && install -d -m 0750 -o root -g root /var/log/opmenu && echo "opmenu $(ls /opt/opmenu/items | wc -l) items; known_hosts $(wc -l < /etc/opmenu/known_hosts) keys"
```

```out
opmenu 27 items; known_hosts 20 keys
```

設定檔只填無法推算的值（連線位址、可重啟的服務清單、主機登入的帳號與金鑰檔、91 的 PVWA object 名稱）。`OPMENU_ALLOW_ENV_OVERRIDE=1` 只為了下面能非互動試跑，正式環境拿掉。

@role 銀行 OS 團隊（lab 由小安代勞） | ops02 | root

`OPMENU_SSH_KEY_FILE` 就是 3.1 的那把私鑰檔，選單的 ssh 直接用它（`-i`、只用這一把、不問 ssh-agent）；`OPMENU_BREAKGLASS_SECRET` 是給人看的 PVWA 位置，91 要緊急憑證時會照這個提示維運人員去取：

```bash
tee /etc/opmenu/opmenu.conf >/dev/null <<'EOF'
OPMENU_ENV_LABEL=LAB
OPMENU_BOOTSTRAP=kb01.poc.lab:9096,kb02.poc.lab:9096,kb03.poc.lab:9096,kb04.poc.lab:9096
OPMENU_CERT_DIR=/etc/opmenu/ssl
OPMENU_BROKER_SERVICES="kb01.poc.lab:confluent-server kb02.poc.lab:confluent-server kb03.poc.lab:confluent-server kb04.poc.lab:confluent-server"
OPMENU_AUX_SERVICES="rest01.poc.lab:confluent-kafka-rest rest02.poc.lab:confluent-kafka-rest c3-01.poc.lab:confluent-control-center"
OPMENU_LB_HOST="lb01.poc.lab"
OPMENU_CONTROLLER_HOSTS="kc01.poc.lab kc02.poc.lab kc03.poc.lab"
OPMENU_SSH_USER=cpuser
OPMENU_SSH_KEY_FILE=/secure/ssh/cpuser_ed25519
OPMENU_USER_FROM_OS=0
OPMENU_BREAKGLASS_SECRET="Safe KAFKA-OPS / opmenu-breakglass（PEM）"
OPMENU_LOG=/var/log/opmenu/opmenu.log
OPMENU_SYSLOG=0
OPMENU_ALLOW_ENV_OVERRIDE=1
EOF
chmod 0644 /etc/opmenu/opmenu.conf && /opt/opmenu/opmenu.sh --list | awk -F'\t' '{print $1, $5}' | head -8
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

## 16.4 各主機 cpuser 的 sudo 改成兩段式

永久只開重啟、查狀態、看日誌三件事，而且**每個服務、每種寫法逐一列出**（`/etc/sudoers.d/cpuser-ops`，0440；每台只列自己的服務）。安裝、升級時 OS 團隊依變更單另開全權（`/etc/sudoers.d/cpuser`）、做完收回。兩個要點（lab 實測）：

- sudoers 比對的是**完整的參數**：`journalctl -u confluent-server -n 5 --no-pager` 不會被只列 `journalctl -u confluent-server` 的規則放行，多帶任何參數都被拒。所以選單看日誌固定用一種寫法（遠端一律 `-n 200 --no-pager`，要看幾行在本機 `tail`），規則才列得完；日常會用到的寫法要逐一列入。
- **不要用萬用字元** `confluent-*`：sudoers 的 `*` 會比對包含空格的任意字串，`restart confluent-*` 會連 `restart confluent-server sshd` 一起放行，`status confluent-* ` 與 `journalctl -u confluent-*` 也會放行 `status confluent-server sshd`、`journalctl -D /etc` 這類寫法。

broker 或 controller 主機的 `cpuser-ops` 長這樣（REST Proxy 主機把服務名換成 `confluent-kafka-rest`，C3 換成 `confluent-control-center`）：

```
cpuser ALL=(root) NOPASSWD: /usr/bin/systemctl restart confluent-server, \
                            /usr/bin/systemctl status confluent-server, \
                            /usr/bin/journalctl -u confluent-server -n 200 --no-pager
```

選單（見 `opmenu/README.md`「sudoers」）送到主機的 sudo 只有三種：重啟（21、22、27）、看日誌（23）、收集診斷（18，逐台逐服務同一種看日誌的寫法）；看狀態（`systemctl status`）是維運人員手動用的。

@role 銀行 OS 團隊（lab 由小安代勞） | ops02 | root

lab 裡：為了之後還要做別的章節，全權那份先留著，只在 kb04 把它收掉，證明「只剩窄規則時選單仍能重啟」，同時驗證規則真的只放行列出的寫法。先把窄規則寫到每一台（同一行寫法，`visudo -cf` 檢查語法）：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do case $h in kc*|kb*) u=confluent-server;; rest*) u=confluent-kafka-rest;; c3*) u=confluent-control-center;; esac; printf 'cpuser ALL=(root) NOPASSWD: /usr/bin/systemctl restart %s, /usr/bin/systemctl status %s, /usr/bin/journalctl -u %s -n 200 --no-pager\n' $u $u $u | ssh $h.poc.lab 'sudo install -m 0440 /dev/stdin /etc/sudoers.d/cpuser-ops && sudo visudo -cf /etc/sudoers.d/cpuser-ops >/dev/null && printf "%s " $(hostname)'; done; echo
```

```out
kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
```

收掉 kb04 的全權，逐一試各種寫法（`sudo -n -l <指令>` 只問「能不能執行」，不會真的執行）：

```bash
ssh kb04.poc.lab 'sudo mv /etc/sudoers.d/cpuser /root/cpuser.sudoers.full; while read -r c; do if sudo -n -l $c >/dev/null 2>&1; then r=可以; else r=拒絕; fi; printf "%s %s\n" $r "$c"; done <<LIST
/usr/bin/systemctl restart confluent-server
/usr/bin/systemctl status confluent-server
/usr/bin/journalctl -u confluent-server -n 200 --no-pager
/usr/bin/journalctl -u confluent-server -n 5 --no-pager
/usr/bin/systemctl restart confluent-server sshd
/usr/bin/systemctl status confluent-server sshd
/usr/bin/systemctl restart sshd
/usr/bin/journalctl -D /etc
/usr/bin/ls /root
LIST'
```

```out
可以 /usr/bin/systemctl restart confluent-server
可以 /usr/bin/systemctl status confluent-server
可以 /usr/bin/journalctl -u confluent-server -n 200 --no-pager
拒絕 /usr/bin/journalctl -u confluent-server -n 5 --no-pager
拒絕 /usr/bin/systemctl restart confluent-server sshd
拒絕 /usr/bin/systemctl status confluent-server sshd
拒絕 /usr/bin/systemctl restart sshd
拒絕 /usr/bin/journalctl -D /etc
拒絕 /usr/bin/ls /root
```

## 16.5 試跑：三種身分看到的選單不一樣

@role 小安（代打 bob、carol、alice） | ops02 | root

**這一節在做什麼**：用三個不同權限的人試跑選單，確認「權限不同、看到的項目不同」。好結果：alice（SystemAdmin）看到最多項目，bob（Operator）只有健康檢查與重啟，carol（開發者）只有自己 prefix 的 topic 項目；沒權限的編號直接輸入會被擋。互動模式就是人員經 PVWA 與 PSMP 登入操作機（root）後執行 `/opt/opmenu/opmenu.sh`，輸入自己的 AD 帳密。為了把結果印在這裡，用 `--run` 非互動跑；`--run menu` 只印這個人看得到的編號：

```bash
P=$(cat ~/secrets/ad-test-users.pass); op() { local u="$1"; shift; env OPMENU_USER="$u" OPMENU_PASS="$P" OPMENU_YES=1 OPMENU_REASON="第 16 站試跑" JAVA_HOME=/opt/java/current /opt/opmenu/opmenu.sh --run "$@" 2>&1 | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g'; }; for u in bob carol alice; do printf '%-6s ' $u; op $u menu | grep '@@MENU@@' | cut -d' ' -f2-; done; unset P
```

```out
bob    10 11 12 13 14 15 16 17 18 19 21 22 23 27
carol  10 11 12 13 14 15 17 19
alice  10 11 12 13 14 15 16 17 18 19 21 22 23 27 31 32 33 34 35 36 37 41 42 43 44 45 91
```

43、45（匯出、查詢稽核紀錄）要 audit topic 的讀取權限：alice（SystemAdmin）有，bob、carol 沒有。要給稽核單位用，就把他們的 AD 群組綁 `Topic:confluent-audit-log-events`（prefix）與 `Group:audit-`（prefix）的 DeveloperRead。

bob（Operator）：健康檢查、看 kb04 的日誌（kb04 只剩窄規則；23 只列含 error／warn 字樣的行，INFO 裡有 errors 字眼也會被列出）、重啟 kb04；直接輸入他看不到的 31 會被擋。alice（SystemAdmin）：建 topic、91 緊急模式、刪 topic。

@role 小安（代打 bob、carol、alice） | ops02 | root

主機類項目（23、21）直接用 `/secure/ssh` 的金鑰，不會問任何東西。只有緊急模式（91）會提示「請到 CyberArk PVWA 取出：Safe KAFKA-OPS / opmenu-breakglass（PEM）」，維運人員從 PVWA 複製、貼上、按 `Ctrl-D`（貼上的內容不會出現在畫面）。為了把結果印在這裡，lab 用一支小腳本在虛擬終端機裡跑選單，等提示出現後把 stdin 的內容「貼」進去（沒有要貼的就給空的）：

```bash
cat > ~/conf/opmenu-try.sh <<'EOF'
#!/usr/bin/env bash
# lab：跑一次選單（--run <AD 帳號> <項目…>）；stdin 是「從 PVWA 取出要貼的內容」（沒有就給空的），提示出現後貼進虛擬終端機
person=$1; shift
password=$(cat ~/secrets/ad-test-users.pass); pasted=$(cat)
{ sleep 8; [ -n "$pasted" ] && printf '%s\n' "$pasted"; printf '\004'; } | script -q -e -c "env OPMENU_USER=$person OPMENU_PASS='$password' OPMENU_YES=1 OPMENU_REASON=第16站試跑 JAVA_HOME=/opt/java/current /opt/opmenu/opmenu.sh --run $*" /dev/null | sed 's/\x1b\[[0-9;]*m//g; s/\r//g' | grep -v '^SLF4J'
EOF
chmod 0700 ~/conf/opmenu-try.sh && P=$(cat ~/secrets/ad-test-users.pass); op() { local u="$1"; shift; env OPMENU_USER="$u" OPMENU_PASS="$P" OPMENU_YES=1 OPMENU_REASON="第 16 站試跑" JAVA_HOME=/opt/java/current /opt/opmenu/opmenu.sh --run "$@" 2>&1 | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g'; } && op bob 11 | grep -E '^-- (broker 在線:|你的 MDS token)'; op bob 31 orders.x 1 | tail -1; op alice 31 orders.optest 1 | tail -1; unset P
```

```out
-- 你的 MDS token:已用 3s,剩約 3597s
-- broker 在線:4 / 4(設定的 broker 數)
項目 31 不在你的選單內(你的 AD 群組沒有這項權限),請依變更單申請。
Created topic orders.optest.
```

@role 維運人員 bob、alice（91 的緊急憑證從 PVWA 取出貼上；lab 由 Windows 終端代貼） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && try() { docker exec -i lab-ops02-1 bash /root/conf/opmenu-try.sh "$@"; }; try bob 23 kb04.poc.lab:confluent-server 10 </dev/null | grep -E 'kb04' | tail -2 | cut -c1-100; try bob 21 kb04.poc.lab:confluent-server </dev/null | tail -1; docker exec lab-ops02-1 bash -c 'for i in $(seq 1 24); do [ "$(curl -s -o /dev/null -w "%{http_code}" https://kb04.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "kb04 MDS=$(curl -s -o /dev/null -w "%{http_code}" https://kb04.poc.lab:8090/v1/metadata/id) after ~$((i*5))s"'; try alice 91 kafka-topics --list < pvwa/opmenu-breakglass.pem | grep -c '^[a-z_]' | sed 's/^/91 緊急模式列出的 topic：/'; try alice 33 orders.optest </dev/null | grep 將執行
```

```out
Oct 25 09:57:24 kb04 kafka-server-start[2266]: [2026-10-25 09:57:24,799] INFO Updated lag of 0 group …
Oct 25 09:58:24 kb04 kafka-server-start[2266]: [2026-10-25 09:58:24,782] INFO Updated lag of 0 group …
已重啟 kb04.poc.lab 的 confluent-server
kb04 MDS=200 after ~20s
91 緊急模式列出的 topic：14
將執行:刪除 topic orders.optest,資料不可復原
```

## 16.6 收尾檢查

@role 小安 | ops02 | root

**這一節在做什麼**：確認選單用完不留下私鑰或殘留程序，紀錄檔有記到人。好結果：ssh-agent 0、私鑰檔 0、金鑰檔是 `root:root 400`。選單結束後不留東西：沒有殘留的 ssh-agent（選單根本不開 agent）、`/dev/shm` 與 `/tmp` 沒有私鑰（91 的緊急憑證用完即刪）；金鑰檔仍是 root:root 0400。紀錄每行有 AD 帳號、作業系統帳號、項目、結果；作業系統帳號在操作機上都是 root，真正的「人」是 AD 帳號那一欄（再往上追，是 CyberArk 的登入紀錄與 PSMP 錄影）：

```bash
echo "ssh-agent: $(pgrep -x ssh-agent | wc -l); private keys in /dev/shm,/tmp: $(grep -rls 'PRIVATE KEY' /dev/shm /tmp 2>/dev/null | grep -v runner.sh | wc -l); key file: $(stat -c '%U:%G %a' /secure/ssh/cpuser_ed25519)"; tail -4 /var/log/opmenu/opmenu.log | cut -c1-120
```

```out
ssh-agent: 0; private keys in /dev/shm,/tmp: 0; key file: root:root 400
2026-10-22 22:40:47 +0800 | LAB | alice | os=root | 91 breakglass | sid=1792680046-22240 | EMERGENCY | kafka-topics --li
2026-10-22 22:40:49 +0800 | LAB | alice | os=root | 91 緊急模式(以保管庫的備用憑證執行一個指令) | sid
2026-10-22 22:40:56 +0800 | LAB | alice | os=root | 33 刪除 topic | sid=1792680050-22629 | OK | orders.optest [rc=0 6s
```

@role 銀行 OS 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

16.4 為了證明「只剩窄規則時選單仍能重啟」，把 kb04 的全權 sudo 收掉了。正式環境的全權是變更時段由 OS 團隊依變更單開、做完收回；lab 後面的章節（第 17、18、20、21 章）都還要在 kb04 上安裝與派送，所以演練完把它放回去，當作「下一個變更時段開了全權」：

```bash
docker exec lab-kb04-1 bash -c 'mv /root/cpuser.sudoers.full /etc/sudoers.d/cpuser && visudo -cf /etc/sudoers.d/cpuser >/dev/null && echo "kb04: full sudo back (change window)"'
```

```out
kb04: full sudo back (change window)
```

# 17. 第十七站：監控（JMX exporter，行內 Prometheus、Alertmanager、Grafana）

![jmx]

**這一章在做什麼**：讓銀行的監控系統看得到 Confluent 各程序的狀況，並在出事時發告警。前提：第 10–13 章的服務已經起來（第 15 章是否已做不影響步驟）；這一章會**滾動重啟**所有 Java 程序（17.4），請在變更時段一台一台做。名詞：JMX 是 Java 程序對外提供指標的介面，JMX exporter 把它轉成 Prometheus 讀得懂的 HTTPS 網頁。

監控與告警的做法已定案：**每個 Java 程序掛 Prometheus 的 JMX exporter（javaagent），由銀行的 Prometheus 抓、銀行的 Alertmanager 發告警、銀行的 Grafana 看圖**。Prometheus、Alertmanager、Grafana 是銀行提供的；我方交付的是設定：exporter 規則、scrape 設定、告警規則、Alertmanager 設定、Grafana 的 datasource 與 Confluent 官方的 32 個 dashboard。

> **C3 內建的 Prometheus、Alertmanager 不動**：它們是 C3 自己的畫面（第 13 章）要用的，`otlp` 等設定照舊。但**告警與 dashboard 不走它們**，也不要在 C3 畫面建 alert trigger 或 action（Webhook、Email、PagerDuty）。原因：C3 會把那份 Alertmanager 設定重寫（C3 重啟後手改的內容被蓋掉）、webhook 內容不能自訂、而且只看得到 C3 自己收到的 telemetry（沒有主機標籤、看不到 controller 的 raft 以外的 JMX）。這幾點 2026-10-26 在 lab 逐項實測過。

| 誰 | 做什麼 |
|---|---|
| 小安 | exporter 的 jar 與 Confluent 官方規則檔已在 1.4 節帶進來；產抓取密碼、組設定、派送、滾動重啟；產給銀行的 `to-bank/`（scrape 設定、告警規則、Alertmanager 設定、Grafana 設定與 dashboard、根憑證、抓取密碼） |
| 銀行監控團隊 | 把 `to-bank/` 放進自己的 Prometheus、Alertmanager、Grafana；確認 10 個 target 都是 up、規則載入、dashboard 都在；把 webhook 指到行內的事件系統（IBM Netcool/OMNIbus，下稱 omnibus） |

四種程序各用哪份規則，抓得到什麼：

| 程序 | exporter 規則 | 抓得到什麼 |
|---|---|---|
| controller（kc01–03） | Confluent 官方 `kafka_controller.yml` | KRaft：controller 指標（`ActiveControllerCount`、`LastAppliedRecordLagMs`、`MetadataErrorCount` …）、JVM（raft 指標在三台 controller 的叢集裡沒有，見 17.10）|
| broker（kb01–04） | Confluent 官方 `kafka_broker.yml` | topic／partition／replica、request 延遲、ISR、網路與 request handler 執行緒、quota、JVM（序列數隨 topic 與 partition 數成長，3 個 partition 的 lab 約 1.2 萬條） |
| REST Proxy（rest01–02） | Confluent 官方 `confluent_rest.yml` | Jetty 與每個 REST endpoint 的請求率、錯誤率、延遲，JVM |
| Control Center（c3-01） | **我方自己寫的小規則**（官方沒有給 C3 的 exporter 設定） | JVM、Kafka Streams 狀態（`client_state`、執行緒數）、Jetty 請求率。C3 的 JVM 另外有上萬條 MBean（每個 REST endpoint、每個 RocksDB store 一串），全是雜訊，所以只放行上面幾項 |

## 17.1 抓取密碼與設定檔

@role 小安 | ops02 | root

exporter 的設定檔只存密碼的加鹽 SHA-256，不存明文；鹽整個叢集固定一個。keystore 密碼則只能明文寫在這個 YAML 裡（exporter 不支援 Secret Protection），所以檔案一律 root:confluent 0640。controller 沒有 cp-server.p12，用 kafka-internal.p12；broker、REST Proxy、C3 用 cp-server.p12。這一步只產生**標頭**（HTTPS 與帳密），規則在 17.2 接上去：

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
EOF
); done; unset SALT HASH; echo "headers: $(ls ~/monitoring | grep '^jmx-header' | tr '
' ' ')"
```

```out
headers: jmx-header-cp-server.yml jmx-header-kafka-internal.yml 
```

> 陷阱：exporter 比對雜湊時用 Java 的 `BigInteger.toString(16)`，開頭的 0 會被吃掉。雜湊剛好以 0 開頭（機率 1/16）時，帳密永遠 401；所以上面多了 `sed 's/^0*//'` 把前導 0 去掉再寫進 YAML。

## 17.2 接上 Confluent 官方的規則

@role 小安 | ops02 | root

Dashboard 是照 Confluent 官方 exporter 規則產生的指標名稱寫的，所以規則**直接用官方的檔，不自己改**（第 1.4 站帶進來，固定在 jmx-monitoring-stacks 的一個 commit，在 `~/landing/monitoring/` 下）。每台的設定 = 17.1 的標頭 + 官方規則。官方檔第一行是 YAML 文件分隔線 `---`，接在標頭後面會變成第二份文件，所以拿掉。官方檔自己帶 `startDelaySeconds: 120`（controller、broker：重啟後前兩分鐘 7071 回 200 但沒有指標）。

C3 沒有官方規則，我們寫一份小的（`rules-c3.yml`）。整段貼到 EOF：

```bash
cd ~/monitoring && rm -f alert-rules.yml ca.pem prometheus-scrape.yml rules-kafka.yml rules-rest.yml rules-jvm.yml scrape.pass
R=~/landing/monitoring/jmx-monitoring-stacks/shared-assets/jmx-exporter && echo "官方規則版本：$(cut -c1-12 ~/landing/monitoring/jmx-monitoring-stacks/COMMIT)" && for x in controller:kafka-internal:kafka_controller broker:cp-server:kafka_broker rest:cp-server:confluent_rest; do role=${x%%:*}; rest=${x#*:}; ks=${rest%%:*}; rules=${rest#*:}; (umask 077; { cat ~/monitoring/jmx-header-$ks.yml; sed '1{/^---$/d}' $R/$rules.yml; } > ~/monitoring/jmx-$role.yml); done
cat > ~/monitoring/rules-c3.yml <<'EOF'
# Control Center: Confluent has no official exporter rules for it, so this is our own, deliberately small.
# C3 is a Kafka Streams application with a Jetty/Jersey front end; its JVM exposes thousands of MBeans (one per REST endpoint,
# per RocksDB store, per client), most of them noise. Only what an alert can use is kept:
#   jvm_*, process_*   built in (heap, GC, threads, open file descriptors)
#   Kafka Streams state: client_state (0 CREATED, 1 REBALANCING, 2 RUNNING, 3 PENDING_SHUTDOWN, 4 NOT_RUNNING, 5 PENDING_ERROR, 6 ERROR), alive / failed threads
#   Jetty: request rate and error rate in front of C3's UI and API
lowercaseOutputName: true
lowercaseOutputLabelNames: true
startDelaySeconds: 0
includeObjectNames:
  - "kafka.streams:type=stream-metrics,*"
  - "kafka.rest:type=jetty-metrics"
rules:
  # the beans carry different extra keys (application-id, process-id) in no fixed order, so only pick out client-id
  - pattern: 'kafka.streams<.*client-id=([^,>]+).*><>(client-state|alive-stream-threads|failed-stream-threads): (.+)'
    name: kafka_streams_stream_metrics_$2
    type: GAUGE
    labels: { client_id: "$1" }
  - pattern: 'kafka.rest<type=jetty-metrics><>(request-rate|request-error-rate): (.+)'
    name: kafka_rest_jetty_metrics_$1
    type: GAUGE
EOF
(umask 077; cat ~/monitoring/jmx-header-cp-server.yml ~/monitoring/rules-c3.yml > ~/monitoring/jmx-c3.yml)
for f in controller broker rest c3; do printf '%-11s %4d 行  httpServer=%s lowercaseOutputName=%s
' $f $(wc -l < ~/monitoring/jmx-$f.yml) $(grep -c '^httpServer:' ~/monitoring/jmx-$f.yml) $(grep -c '^lowercaseOutputName: true' ~/monitoring/jmx-$f.yml); done
```

```out
官方規則版本：f376263fc6d7
controller   158 行  httpServer=1 lowercaseOutputName=1
broker       436 行  httpServer=1 lowercaseOutputName=1
rest          54 行  httpServer=1 lowercaseOutputName=1
c3            36 行  httpServer=1 lowercaseOutputName=1
```

官方規則版本記在 `COMMIT`，換版本（重新下載官方檔）要重做這一步並重新驗證 dashboard。

> **官方規則的一個副作用**：序列數會隨 topic 與 partition 數成長（`kafka.log`、`kafka.cluster` 的每個 partition 一條）。lab 3 個 partition 的 broker 就有 1.2 萬條；正式環境 partition 多時要請銀行監控團隊評估 Prometheus 的容量與保留天數。

## 17.3 派送 jar 與設定、掛上 javaagent

@role 小安 | ops02 | root

每台：jar 到 `/opt/jmx-exporter/`、設定檔到各元件的目錄、第四個 drop-in 把 `-javaagent` 放進環境變數：controller 與 broker 是 `KAFKA_OPTS`，REST Proxy 是 `KAFKAREST_OPTS`，C3 是 `CONTROL_CENTER_OPTS`（C3 的啟動腳本本來就會讀它，另外加的 `-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=*` 由腳本自己補，不用管）。7071 在第 7 章的防火牆已經開了（C3 的 7071 也在）：

```bash
JAR=$(ls ~/landing/tools/jmx_prometheus_javaagent-*.jar | xargs -n1 basename) && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do case $h in kc*) role=controller; cfg=/etc/confluent/kafka/jmx-exporter.yml; u=confluent-server; var=KAFKA_OPTS;; kb*) role=broker; cfg=/etc/confluent/kafka/jmx-exporter.yml; u=confluent-server; var=KAFKA_OPTS;; rest*) role=rest; cfg=/etc/confluent/kafka-rest/jmx-exporter.yml; u=confluent-kafka-rest; var=KAFKAREST_OPTS;; c3*) role=c3; cfg=/etc/confluent/control-center/jmx-exporter.yml; u=confluent-control-center; var=CONTROL_CENTER_OPTS;; esac; cp ~/monitoring/jmx-$role.yml /tmp/jmx-$h.yml && scp -q ~/landing/tools/$JAR /tmp/jmx-$h.yml $h.poc.lab:/tmp/ && rm -f /tmp/jmx-$h.yml && ssh $h.poc.lab "sudo install -d -m 0755 /opt/jmx-exporter && sudo install -m 0644 /tmp/$JAR /opt/jmx-exporter/$JAR && sudo install -o root -g confluent -m 0640 /tmp/jmx-$h.yml $cfg && rm -f /tmp/$JAR /tmp/jmx-$h.yml && printf '[Service]\nEnvironment=\"$var=-javaagent:/opt/jmx-exporter/$JAR=7071:$cfg\"\n' | sudo tee /etc/systemd/system/$u.service.d/40-jmx.conf >/dev/null && sudo systemctl daemon-reload && echo \"\$(hostname): \$(systemctl show $u -p Environment --value | tr ' ' '\n' | grep -o 'javaagent:[^ =]*' | head -1) \$(sudo wc -l $cfg | cut -d' ' -f1) lines\""; done
```

```out
kc01: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 158 lines
kc02: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 158 lines
kc03: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 158 lines
kb01: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 436 lines
kb02: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 436 lines
kb03: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 436 lines
kb04: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 436 lines
rest01: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 54 lines
rest02: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 54 lines
c3-01: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.0.1.jar 36 lines
```

> 陷阱：落地區的檔案是唯讀的（第 2 章 `chmod a-w`），這裡先 `cp` 到 `/tmp` 再 `scp`，是因為直接 `scp` 落地區的檔會連唯讀一起帶過去。流程正常跑完會 `rm -f`；若中途失敗留下唯讀檔，下一次 `scp` 會 `Permission denied`，先到那台 `rm -f /tmp/jmx*` 再重跑。
>
> 陷阱：`sudo wc -l < 檔案` 的 `<` 是用 cpuser 的身分開檔，會 `Permission denied`；要寫成 `sudo wc -l 檔案`。

## 17.4 滾動重啟、驗證端點

@role 小安 | ops02 | root

controller、broker 照順序一台一台來（REST Proxy 與 C3 在後面）：

```bash
for h in kc01 kc02 kc03; do ssh $h.poc.lab 'sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done; echo "$(hostname) $(systemctl is-active confluent-server)"'; done; for h in kb01 kb02 kb03 kb04; do ssh $h.poc.lab 'sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
```

REST Proxy 照 12.1 一台一台重啟：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

最後是 C3（它的畫面約 1 分鐘不能用）：

```bash
ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 10; done; echo "c3 ui=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) after ~$((i*10))s"
```

```out
c3 ui=200 after ~60s
```

沒帶帳密要被拒（401），帶了要看到指標；憑證鏈用銀行根憑證驗（不用 -k）。controller 與 broker 重啟後前兩分鐘指標是空的（官方規則的 `startDelaySeconds: 120`），所以每台等到有指標再算：

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem; for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do u=https://$h.poc.lab:7071/metrics; a=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert $CA $u); for i in $(seq 1 30); do m=$(curl -s --max-time 30 --cacert $CA -u "prometheus:$(cat ~/secrets/jmx-scrape.pass)" $u | grep -cE '^(kafka_|jvm_)'); [ "$m" -gt 20 ] && break; sleep 10; done; printf '%-7s anon=%s metrics=%s\n' $h $a $m; done
```

```out
kc01    anon=401 metrics=1067
kb01    anon=401 metrics=12017
rest01  anon=401 metrics=1498
c3-01   anon=401 metrics=101
（10 行，匿名都是 401；controller 約 1,000、REST 約 1,500、C3 約 100 個 kafka_／jvm_ 指標，broker 依 partition 數而定）
```

## 17.5 給銀行監控團隊的檔

@role 小安 | ops02 | root

全部放在 `~/monitoring/to-bank/`，分成三個資料夾，各給對應的銀行團隊：

| 資料夾 | 內容 | 放到哪 |
|---|---|---|
| `prometheus/` | `scrape-confluent.yml`、`confluent-alerts.yml`、`ca.pem`、`scrape.pass` | Prometheus 的 `/etc/prometheus/confluent/` |
| `alertmanager/` | `alertmanager.yml` | 併入行內 Alertmanager 的設定 |
| `grafana/` | `datasource-prometheus.yml`、`dashboards/`（32 個 JSON 加 `dashboard.yml`） | Grafana 的 `provisioning/datasources/`、`provisioning/dashboards/` |

**scrape 設定**：四個 job，名稱和標籤是官方 dashboard 寫死的（`job="kafka-broker"`、`env`、`hostname`），不要改。`env` 的值是這個環境的名字（lab 用 `lab`，客戶用 `prod`／`uat`）。抓取密碼放檔案不放設定裡。這個檔用 Prometheus 的 `scrape_config_files` 引用，不用併進 `prometheus.yml`：

```bash
rm -rf ~/monitoring/to-bank && install -d ~/monitoring/to-bank/prometheus ~/monitoring/to-bank/alertmanager ~/monitoring/to-bank/grafana/dashboards
cat > ~/monitoring/to-bank/prometheus/scrape-confluent.yml <<'EOF'
# Confluent Platform scrape jobs for the bank's Prometheus (referenced from prometheus.yml with scrape_config_files)
# Job names and the env / hostname labels are what Confluent's official Grafana dashboards query (job="kafka-broker", env=...).
# Files next to this one (/etc/prometheus/confluent/): ca.pem (bank root CA), scrape.pass (basic-auth password, 0600)
scrape_configs:
  - job_name: kafka-controller
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    basic_auth: { username: prometheus, password_file: /etc/prometheus/confluent/scrape.pass }
    static_configs: [ { targets: [ "kc01.poc.lab:7071", "kc02.poc.lab:7071", "kc03.poc.lab:7071" ], labels: { env: lab } } ]
    relabel_configs: [ { source_labels: [__address__], target_label: hostname, regex: '([^:]+)(:[0-9]+)?', replacement: '$1' } ]
  - job_name: kafka-broker
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    basic_auth: { username: prometheus, password_file: /etc/prometheus/confluent/scrape.pass }
    static_configs: [ { targets: [ "kb01.poc.lab:7071", "kb02.poc.lab:7071", "kb03.poc.lab:7071", "kb04.poc.lab:7071" ], labels: { env: lab } } ]
    relabel_configs: [ { source_labels: [__address__], target_label: hostname, regex: '([^:]+)(:[0-9]+)?', replacement: '$1' } ]
  - job_name: rest-proxy
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    basic_auth: { username: prometheus, password_file: /etc/prometheus/confluent/scrape.pass }
    static_configs: [ { targets: [ "rest01.poc.lab:7071", "rest02.poc.lab:7071" ], labels: { env: lab } } ]
    relabel_configs: [ { source_labels: [__address__], target_label: hostname, regex: '([^:]+)(:[0-9]+)?', replacement: '$1' } ]
  - job_name: control-center
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    basic_auth: { username: prometheus, password_file: /etc/prometheus/confluent/scrape.pass }
    static_configs: [ { targets: [ "c3-01.poc.lab:7071" ], labels: { env: lab } } ]
    relabel_configs: [ { source_labels: [__address__], target_label: hostname, regex: '([^:]+)(:[0-9]+)?', replacement: '$1' } ]
EOF
echo "scrape-confluent.yml: $(grep -c job_name ~/monitoring/to-bank/prometheus/scrape-confluent.yml) 個 job"
```

```out
scrape-confluent.yml: 4 個 job
```

**告警規則**：19 條，每條都有 `severity`（critical／warning）、`impact`（APPLICATION／SERVICE／INFRASTRUCTURE，對應 omnibus 規格裡的 ProblemImpact 欄位）、`summary` 與 `description`。規則的出處寫在每一條上方的註解，三類：`official`（Confluent jmx-monitoring-stacks 的 `prometheus-alerts/`，保留，必要時修正表達式）、`confluent`（Confluent 的監控指引：Monitor Kafka、KRaft metrics）、`ours`（我方新增，一定有 lab 上真的存在的指標撐著）。和官方檔的差別：

- 官方 `broker-alerts.yml` 有兩條「Broker IO Activity」用的是一個永遠小於 1 的 control-plane 指標，等於測試規則，不收；改用 request handler 的一分鐘平均閒置率。
- 官方的 `UncleanLeaderElectionsPerSec` 在 exporter 裡是累計次數，`> 0` 一旦發生過就永遠成立，改成看 10 分鐘內的增量。
- 官方的 `high_load` 要 node exporter，我們沒有；主機層的 CPU、磁碟請用銀行既有的主機監控。
- controller 的規則（`ActiveControllerCount`、offline partitions）限定 `job="kafka-controller"`；`for` 從 10 秒放寬到 1 分鐘，不然 controller 重啟會叫人。
- KRaft 另加：metadata 落後、metadata 錯誤、leader 頻繁更換（「沒有 leader」由 `KafkaActiveControllerCountNotOne` 涵蓋）。REST Proxy、C3 各加兩條，都只用 lab 驗過存在的指標。

整段貼到 EOF：

```bash
cat > ~/monitoring/to-bank/prometheus/confluent-alerts.yml <<'EOF'
# Alert rules for the bank's Prometheus. Metric names are the ones Confluent's official JMX exporter rules produce
# (jmx-monitoring-stacks, see the guide, chapter 1.4); job names match scrape-confluent.yml.
# Every rule has:  labels.severity (critical|warning)  labels.impact (APPLICATION|SERVICE|INFRASTRUCTURE, the ProblemImpact field of the bank omnibus format)
#                  annotations.summary (one line)  annotations.description (full sentence, what to look at)
# "source:" says where the rule comes from:
#   official   = Confluent jmx-monitoring-stacks prometheus-alerts/ (kept, sometimes with the expression fixed for KRaft)
#   confluent  = Confluent's monitoring guidance (docs.confluent.io "Monitor Kafka", "KRaft metrics")
#   ours       = added for this installation, backed by a metric that really exists on Confluent Server 8.3.2 / C3 2.6.1 (the migration target; re-check 17.7 after migrating from the 8.2.4 baseline)
# Thresholds and "for:" are starting points: tune them to the bank's paging policy and silence during planned restarts.
groups:
  - name: confluent-availability
    rules:
      # source: official alerts.yml (service_down), narrowed to our four jobs
      - alert: ConfluentTargetDown
        expr: up{job=~"kafka-controller|kafka-broker|rest-proxy|control-center"} == 0
        for: 2m
        labels: { severity: critical, impact: INFRASTRUCTURE }
        annotations:
          summary: "{{ $labels.hostname }} ({{ $labels.job }}) cannot be scraped"
          description: "Prometheus has not been able to scrape {{ $labels.instance }} (job {{ $labels.job }}) for 2 minutes: the service, the JMX exporter (port 7071) or the network path is down. Check systemctl status on {{ $labels.hostname }}."

  - name: kafka-broker
    rules:
      # source: official broker-alerts.yml (ActiveControllerCount != 1); ours: restricted to the controller job, 1 m instead of 10 s so a controller restart does not page
      - alert: KafkaActiveControllerCountNotOne
        expr: sum by (env) (kafka_controller_kafkacontroller_activecontrollercount{job="kafka-controller"}) != 1
        for: 1m
        labels: { severity: critical, impact: SERVICE }
        annotations:
          summary: "{{ $labels.env }}: active controller count is {{ $value }}"
          description: "The KRaft quorum of {{ $labels.env }} reports {{ $value }} active controllers (expected exactly 1). Zero means no leader (metadata cannot change), more than one means a split. Check kafka-metadata-quorum describe --status."
      # source: official broker-alerts.yml (OfflinePartitionCount > 0)
      - alert: KafkaOfflinePartitions
        expr: sum by (env) (kafka_controller_kafkacontroller_offlinepartitionscount{job="kafka-controller"}) > 0
        for: 1m
        labels: { severity: critical, impact: SERVICE }
        annotations:
          summary: "{{ $labels.env }}: {{ $value }} offline partitions"
          description: "{{ $value }} partitions in {{ $labels.env }} have no leader, so producers and consumers of those partitions fail. Look for brokers that are down: kafka-topics --describe --unavailable-partitions."
      # source: official broker-alerts.yml (UncleanLeaderElectionsPerSec > 0); ours: the exporter publishes a cumulative count, so test the increase
      - alert: KafkaUncleanLeaderElections
        expr: sum by (env) (increase(kafka_controller_controllerstats_uncleanleaderelectionspersec{job="kafka-controller"}[10m])) > 0
        labels: { severity: critical, impact: SERVICE }
        annotations:
          summary: "{{ $labels.env }}: unclean leader election"
          description: "An out-of-sync replica became leader in {{ $labels.env }} within the last 10 minutes; acknowledged messages may have been lost. Confirm unclean.leader.election.enable is false."
      # source: official broker-alerts.yml (UnderReplicatedPartitions > 0), "for" raised to 5 m (rolling restarts cause short under-replication)
      - alert: KafkaUnderReplicatedPartitions
        expr: sum by (env) (kafka_server_replicamanager_underreplicatedpartitions{job="kafka-broker"}) > 0
        for: 5m
        labels: { severity: warning, impact: SERVICE }
        annotations:
          summary: "{{ $labels.env }}: {{ $value }} under-replicated partitions"
          description: "{{ $value }} partitions of {{ $labels.env }} have fewer in-sync replicas than replicas for 5 minutes. A broker is slow, down or restarting; check kafka-topics --describe --under-replicated-partitions."
      # source: official broker-alerts.yml (UnderMinIsrPartitionCount > 0)
      - alert: KafkaUnderMinIsrPartitions
        expr: sum by (env) (kafka_cluster_partition_underminisr{job="kafka-broker"}) > 0
        for: 1m
        labels: { severity: critical, impact: SERVICE }
        annotations:
          summary: "{{ $labels.env }}: {{ $value }} partitions below min.insync.replicas"
          description: "{{ $value }} partitions of {{ $labels.env }} are below min.insync.replicas: producers with acks=all get NotEnoughReplicas errors."
      # source: confluent (ISR shrinks that are not followed by expands)
      - alert: KafkaIsrShrinkingWithoutExpand
        expr: sum by (env) (increase(kafka_server_replicamanager_isrshrinkspersec{job="kafka-broker"}[15m])) > 0 and sum by (env) (increase(kafka_server_replicamanager_isrexpandspersec{job="kafka-broker"}[15m])) == 0
        for: 5m
        labels: { severity: warning, impact: SERVICE }
        annotations:
          summary: "{{ $labels.env }}: ISR shrank and did not recover"
          description: "Replicas left the ISR of {{ $labels.env }} in the last 15 minutes and none rejoined. A follower cannot keep up: check broker disks, network and replica.lag.time.max.ms."
      # source: ours (the official rules for this are a test rule on a control-plane metric that is always below 1); the one-minute rate of the request handler pool is a real 0..1 idle ratio
      - alert: KafkaRequestHandlerBusy
        expr: avg by (instance) (kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent_oneminuterate{job="kafka-broker"}) < 0.3
        for: 10m
        labels: { severity: warning, impact: SERVICE }
        annotations:
          summary: "{{ $labels.hostname }}: request handler threads busy"
          description: "Request handler threads on {{ $labels.instance }} have been less than 30% idle for 10 minutes ({{ $value | humanizePercentage }} idle). The broker is close to saturation: look at request rate, disk latency, num.io.threads."
      # source: confluent (network processor idle ratio)
      - alert: KafkaNetworkProcessorBusy
        expr: avg by (instance) (kafka_network_socketserver_networkprocessoravgidlepercent{job="kafka-broker"}) < 0.3
        for: 10m
        labels: { severity: warning, impact: SERVICE }
        annotations:
          summary: "{{ $labels.hostname }}: network threads busy"
          description: "Network processor threads on {{ $labels.instance }} have been less than 30% idle for 10 minutes. Check connection counts and num.network.threads."
      # source: confluent (request latency); ours: Produce p99, 500 ms
      - alert: KafkaProduceLatencyHigh
        expr: max by (instance) (kafka_network_requestmetrics_totaltimems{job="kafka-broker",request="Produce",quantile="0.99"}) > 500
        for: 10m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: Produce p99 {{ $value }} ms"
          description: "99th percentile Produce request time on {{ $labels.instance }} has been above 500 ms for 10 minutes. Look at disk latency and replication delay (acks=all waits for followers)."

  - name: kraft
    rules:
      # source: ours (earlier lab work): controller applies the metadata log late
      - alert: KRaftControllerMetadataLag
        expr: max by (instance) (kafka_controller_kafkacontroller_lastappliedrecordlagms{job="kafka-controller"}) > 30000
        for: 5m
        labels: { severity: warning, impact: SERVICE }
        annotations:
          summary: "{{ $labels.hostname }}: metadata log applied {{ $value }} ms late"
          description: "{{ $labels.instance }} applies the KRaft metadata log {{ $value }} ms behind the leader for 5 minutes: the quorum is not keeping up (disk or network)."
      - alert: KRaftMetadataErrors
        expr: max by (instance) (kafka_controller_kafkacontroller_metadataerrorcount{job="kafka-controller"}) > 0
        for: 1m
        labels: { severity: critical, impact: SERVICE }
        annotations:
          summary: "{{ $labels.hostname }}: errors applying the metadata log"
          description: "{{ $labels.instance }} counted {{ $value }} errors while applying KRaft metadata records. Read /var/log/kafka on that controller."
      - alert: KRaftLeaderFlapping
        expr: sum by (env) (increase(kafka_controller_kafkacontroller_newactivecontrollerscount{job="kafka-controller"}[15m])) > 2
        labels: { severity: warning, impact: SERVICE }
        annotations:
          summary: "{{ $labels.env }}: KRaft leader changed {{ $value }} times in 15 minutes"
          description: "The active controller of {{ $labels.env }} changed more than twice in 15 minutes: unstable network, GC pauses or an overloaded controller."

  - name: rest-proxy
    rules:
      # source: ours: the REST Proxy exports one error-rate series per endpoint (kafka_rest_jersey_metrics_<endpoint>_request_error_rate); sum them
      - alert: RestProxyErrors
        expr: sum by (instance) ({__name__=~"kafka_rest_jersey_metrics_.*_request_error_rate", job="rest-proxy"}) > 1
        for: 10m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: REST Proxy returns errors"
          description: "REST Proxy {{ $labels.instance }} has returned more than 1 error response per second for 10 minutes (4xx and 5xx together). Check client certificates and the broker connection."
      - alert: RestProxyThreadPoolBusy
        expr: max by (instance) (kafka_rest_jetty_metrics_thread_pool_usage{job="rest-proxy"}) > 0.9
        for: 10m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: REST Proxy thread pool above 90%"
          description: "The Jetty thread pool of {{ $labels.instance }} has been more than 90% used for 10 minutes: requests queue up. Check client load and broker latency."

  - name: control-center
    rules:
      # source: ours: C3 is a Kafka Streams application; client-state 0 CREATED, 1 REBALANCING, 2 RUNNING, 3 PENDING_SHUTDOWN, 4 NOT_RUNNING, 5 PENDING_ERROR, 6 ERROR
      - alert: ControlCenterStreamsNotRunning
        expr: max by (instance) (kafka_streams_stream_metrics_client_state{job="control-center"}) >= 4
        for: 5m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: Control Center stopped processing"
          description: "A Kafka Streams client inside Control Center {{ $labels.instance }} is in state {{ $value }} (4 NOT_RUNNING, 5 PENDING_ERROR, 6 ERROR) for 5 minutes: the C3 screens show stale data. Read journalctl -u confluent-control-center."
      - alert: ControlCenterStreamThreadsFailed
        expr: max by (instance) (kafka_streams_stream_metrics_failed_stream_threads{job="control-center"}) > 0
        for: 1m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: Control Center stream thread failed"
          description: "Control Center {{ $labels.instance }} lost {{ $value }} stream threads. Restart it after reading the log."

  - name: jvm
    rules:
      # source: ours (earlier lab work), now for all four jobs
      - alert: JvmHeapHigh
        expr: jvm_memory_used_bytes{area="heap", job=~"kafka-controller|kafka-broker|rest-proxy|control-center"} / jvm_memory_max_bytes{area="heap", job=~"kafka-controller|kafka-broker|rest-proxy|control-center"} > 0.9
        for: 10m
        labels: { severity: warning, impact: INFRASTRUCTURE }
        annotations:
          summary: "{{ $labels.hostname }} ({{ $labels.job }}): JVM heap above 90%"
          description: "The JVM heap of {{ $labels.instance }} has been above 90% for 10 minutes ({{ $value | humanizePercentage }}). Look at GC time and consider a larger -Xmx."
      - alert: JvmFileDescriptorsHigh
        expr: process_open_fds{job=~"kafka-controller|kafka-broker|rest-proxy|control-center"} / process_max_fds{job=~"kafka-controller|kafka-broker|rest-proxy|control-center"} > 0.8
        for: 10m
        labels: { severity: warning, impact: INFRASTRUCTURE }
        annotations:
          summary: "{{ $labels.hostname }} ({{ $labels.job }}): file descriptors above 80%"
          description: "{{ $labels.instance }} uses {{ $value | humanizePercentage }} of its file descriptor limit. Check LimitNOFILE in the systemd drop-in and the number of partitions or connections."
EOF
echo "confluent-alerts.yml: $(grep -c '^      - alert:' ~/monitoring/to-bank/prometheus/confluent-alerts.yml) 條規則"
```

```out
confluent-alerts.yml: 19 條規則
```

**Alertmanager 設定**：兩個 webhook receiver 示範兩種格式，銀行留一種、刪另一種。

- `webhook-default`：Alertmanager 預設的 JSON（version 4），一次 POST 帶一個通知群組裡所有告警。
- `webhook-omnibus`：用 Alertmanager 的範本在 `payload` 組自訂 JSON，欄位照銀行 omnibus 的接收規格：`source`、`ClassName`、`origin`、`hostname`、`sub_source` 是固定值（照銀行給的規格填，範本裡的是範例值，上線前請銀行確認），`msg_catalog` 放規則的 `impact`、`msg` 放 `description`、`state` 是 OPEN／RESOLVED、`severity` 是 ERROR／PERFORMANCE（critical 對應 ERROR）、`sub_origin` 放「規則名稱：摘要」。`group_by: ['...']` 讓每筆告警自己一組，所以自訂格式永遠是一筆告警一個 POST。

自訂 JSON 的寫法有兩個陷阱（2026-10-26 實測）：`payload` 用**字串寫法**，每個值都經 `toJson`，值裡有雙引號或冒號才不會弄壞 JSON；用 map 寫法時，含 `: ` 的值會被當成 YAML 物件、像數字的字串（`"007"`）會變成數字 7。範本裡拿不到 `.GroupKey`，要編號就用告警的 `Fingerprint`。webhook 網址 `WEBHOOK-RECEIVER:8080` 換成行內的；需要認證就在 receiver 加 `http_config`。

```bash
cat > ~/monitoring/to-bank/alertmanager/alertmanager.yml <<'EOF'
# Alertmanager configuration for the bank's Alertmanager. Two webhook receivers show the two formats; keep one, delete the other.
#   webhook-default    Alertmanager's own JSON (version 4): one POST per notification group, all alerts of the group inside
#   webhook-omnibus  a custom JSON built with a template in `payload`: one flat event per alert, in the field layout of the bank omnibus format
# group_by ['...'] puts every alert in its own group, so the custom format is always exactly one alert per POST.
# Replace WEBHOOK-RECEIVER:8080 with the bank's omnibus webhook endpoint (add authentication with http_config if it needs it).
global:
  resolve_timeout: 5m
route:
  receiver: webhook-default
  group_by: ['...']
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
  routes:
    - receiver: webhook-default
      continue: true
    - receiver: webhook-omnibus
receivers:
  - name: webhook-default
    webhook_configs:
      - url: http://WEBHOOK-RECEIVER:8080/default
        send_resolved: true
  - name: webhook-omnibus
    webhook_configs:
      - url: http://WEBHOOK-RECEIVER:8080/omnibus
        send_resolved: true
        # String form + toJson: every value is escaped by toJson, so quotes or colons in a description cannot break the JSON.
        # (The map form would turn "007" into the number 7 and read "a: b" as an object.)
        payload: >-
          {"source": "TCB_DYNATRACE",
          "ClassName": "TCB_DYNATRACE_STATUS",
          "msg_catalog": {{ .CommonLabels.impact | toJson }},
          "msg": {{ .CommonAnnotations.description | toJson }},
          "state": "{{ if eq .Status "firing" }}OPEN{{ else }}RESOLVED{{ end }}",
          "severity": "{{ if eq .CommonLabels.severity "critical" }}ERROR{{ else }}PERFORMANCE{{ end }}",
          "sub_origin": {{ printf "%s: %s" .CommonLabels.alertname .CommonAnnotations.summary | toJson }},
          "origin": "dynatrace5P",
          "hostname": "twnbap1P",
          "sub_source": "PIB"}
EOF
cat > ~/monitoring/to-bank/grafana/datasource-prometheus.yml <<'EOF'
# Grafana datasource for the Confluent dashboards. The official dashboards point at a datasource with uid "Prometheus" (the guide rewrites their ${Prometheus} placeholder to that).
apiVersion: 1
datasources:
  - name: Prometheus
    uid: Prometheus
    type: prometheus
    access: proxy
    url: http://PROMETHEUS:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 30s
EOF
echo "alertmanager.yml $(wc -l < ~/monitoring/to-bank/alertmanager/alertmanager.yml) 行、datasource-prometheus.yml $(wc -l < ~/monitoring/to-bank/grafana/datasource-prometheus.yml) 行"
```

```out
alertmanager.yml 39 行、datasource-prometheus.yml 12 行
```

**Grafana**：datasource 的名字與 uid 都是 `Prometheus`（官方 dashboard 指向這個）。dashboard 用官方的 32 個 JSON 原樣複製，只修兩件事：

1. 官方 JSON 是 Grafana 匯入畫面的格式，datasource 寫成佔位符 `${Prometheus}`，檔案佈建不會替換，每個 panel 都會「datasource not found」→ 改成固定的 uid `Prometheus`。
2. 成對的 ZooKeeper 版與 KRaft 版（例如 `kafka-cluster.json` 與 `kafka-cluster-kraft.json`）用同一個 uid，Grafana 只收第一個、後面的被丟掉 → 重複的改自己的 uid 並在標題加檔名。

落地區的檔是唯讀的，複製出來要加回寫入權限。**全部 32 個都放進去**，不挑；哪些在我們的元件上有資料見 17.9，沒有對應元件的（Connect、ksqlDB、Schema Registry、Flink…）畫面就是空的，不影響其他：

```bash
D=~/landing/monitoring/jmx-monitoring-stacks/jmxexporter-prometheus-grafana/assets && cp $D/grafana/provisioning/dashboards/*.json $D/grafana/provisioning/dashboards/dashboard.yml ~/monitoring/to-bank/grafana/dashboards/ && chmod u+w ~/monitoring/to-bank/grafana/dashboards/* && python3 - <<'EOF'
import glob, json, os, collections
files = sorted(glob.glob(os.path.expanduser('~/monitoring/to-bank/grafana/dashboards/*.json')))
seen = collections.defaultdict(list)
for f in files:
    # the files are exports for the Grafana import screen: the datasource is the placeholder ${Prometheus}, which file provisioning does not fill in
    d = json.loads(open(f, encoding='utf-8').read().replace('${Prometheus}', 'Prometheus'))
    seen[d['uid']].append((f, d))
renamed = 0
for uid, group in seen.items():
    for i, (f, d) in enumerate(group):
        if i > 0:                                   # same uid as an earlier file (the ZooKeeper-era twins): give it its own
            stem = os.path.basename(f)[:-5]
            d['uid'] = (uid + '-' + stem)[:40]
            d['title'] = d['title'] + ' [' + stem + ']'
            renamed += 1
        json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('dashboards: %d, placeholder datasource fixed, uid shared with another file (renamed): %d' % (len(files), renamed))
EOF
```

```out
dashboards: 32, placeholder datasource fixed, uid shared with another file (renamed): 4
```

根憑證與抓取密碼，然後看整個資料夾。抓取密碼另外交 Secrets 團隊存進 PVWA，監控團隊從那裡取（lab 直接給檔）。**待銀行確認**（請銀行確認的事項 11.3、11.4）：行內 Prometheus 抓其他系統用哪種認證；7071 能否只放行行內 Prometheus 的來源位址（第 7 章的 firewalld 目前對所有來源開放）：

```bash
cp /etc/pki/ca-trust/source/anchors/bank-root.pem ~/monitoring/to-bank/prometheus/ca.pem && (umask 077; cp ~/secrets/jmx-scrape.pass ~/monitoring/to-bank/prometheus/scrape.pass) && cd ~/monitoring/to-bank && find . -type f ! -name '*.json' | sort && echo "dashboards: $(ls grafana/dashboards/*.json | wc -l) 個 JSON"
```

```out
./alertmanager/alertmanager.yml
./grafana/dashboards/dashboard.yml
./grafana/datasource-prometheus.yml
./prometheus/ca.pem
./prometheus/confluent-alerts.yml
./prometheus/scrape-confluent.yml
./prometheus/scrape.pass
dashboards: 32 個 JSON
```

## 17.6 銀行的 Prometheus、Alertmanager、Grafana 接上來

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

正式環境是銀行自己的三套系統，照 17.5 的表格放設定。lab 用四個容器扮演：Prometheus、Alertmanager、Grafana，加一個「webhook 接收端」（一支十行的 Python，收到什麼就印什麼，後面測告警用）。容器名稱都叫 `lab-mon-*`，接在 labnet，不在 compose 裡，所以主機名要用 `--add-host` 給 Prometheus。記憶體上限加起來約 1.2 GB。

先把 `to-bank/` 取出來，放成各容器要的樣子（webhook 網址換成接收端容器；Alertmanager 的 `--cluster.listen-address=` 留空是因為 lab 的 172.35.x.x 不是私有位址，gossip 會起不來）：

```bash
cd ~/kafka-lab && rm -rf bank-monitoring && mkdir -p bank-monitoring/prometheus/confluent bank-monitoring/alertmanager bank-monitoring/grafana/provisioning/datasources bank-monitoring/grafana/provisioning/dashboards bank-monitoring/webhook && docker cp lab-ops02-1:/root/monitoring/to-bank "$(cygpath -m "$PWD/bank-monitoring/to-bank")" && cd bank-monitoring && cp to-bank/prometheus/* prometheus/confluent/ && sed 's/WEBHOOK-RECEIVER/lab-mon-webhook/' to-bank/alertmanager/alertmanager.yml > alertmanager/alertmanager.yml && sed 's#http://PROMETHEUS:9090#http://lab-mon-prometheus:9090#' to-bank/grafana/datasource-prometheus.yml > grafana/provisioning/datasources/prometheus.yml && cp to-bank/grafana/dashboards/* grafana/provisioning/dashboards/ && echo "prometheus: $(ls prometheus/confluent | tr '\n' ' ')/ dashboards: $(ls grafana/provisioning/dashboards | wc -l) 個檔"
```

```out
prometheus: ca.pem confluent-alerts.yml scrape-confluent.yml scrape.pass / dashboards: 33 個檔
```

行內 Prometheus 自己的 `prometheus.yml`（銀行原本就有，這裡只示範要加的三行：引用 scrape 設定、載入告警規則、指向 Alertmanager），以及 webhook 接收端：

```bash
cd ~/kafka-lab/bank-monitoring && cat > prometheus/prometheus.yml <<'EOF'
global: { scrape_interval: 30s, evaluation_interval: 30s }
scrape_config_files: [ /etc/prometheus/confluent/scrape-confluent.yml ]
rule_files: [ /etc/prometheus/confluent/confluent-alerts*.yml ]
alerting: { alertmanagers: [ { static_configs: [ { targets: [ "lab-mon-alertmanager:9093" ] } ] } ] }
EOF
cat > webhook/receiver.py <<'EOF'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        print('POST %s | %s | %s' % (self.path, self.headers.get('User-Agent'), body), flush=True)
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('0.0.0.0', 8080), H).serve_forever()
EOF
echo "prometheus.yml $(wc -l < prometheus/prometheus.yml) 行、receiver.py $(wc -l < webhook/receiver.py) 行"
```

```out
prometheus.yml 4 行、receiver.py 8 行
```

起四個容器。映像檔 `prom/prometheus`、`prom/alertmanager`、`grafana/grafana` 是銀行自己的事（正式環境不是我們帶進去的），lab 從 Docker Hub 拉；webhook 接收端用 lab 的 `lab-node:96`。Grafana 開匿名 Admin 只為了 lab 好操作，並發佈到 Windows 的 13000：

```bash
cd ~/kafka-lab/bank-monitoring && W() { cygpath -m "$PWD/$1"; } && HOSTS=$(for h in kc01:21 kc02:22 kc03:23 kb01:31 kb02:32 kb03:33 kb04:34 rest01:41 rest02:42 c3-01:51; do printf -- '--add-host %s.poc.lab:172.35.0.%s ' ${h%%:*} ${h##*:}; done) && docker run -d --name lab-mon-webhook --network lab_labnet --memory 64m -v "$(W webhook):/w:ro" lab-node:96 python3 -u /w/receiver.py >/dev/null && docker run -d --name lab-mon-alertmanager --network lab_labnet --memory 128m -v "$(W alertmanager/alertmanager.yml):/etc/alertmanager/alertmanager.yml:ro" prom/alertmanager:v0.34.1 --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager --cluster.listen-address= >/dev/null && docker run -d --name lab-mon-prometheus --network lab_labnet --memory 600m $HOSTS -v "$(W prometheus/prometheus.yml):/etc/prometheus/prometheus.yml:ro" -v "$(W prometheus/confluent):/etc/prometheus/confluent:ro" prom/prometheus:v3.5.0 --config.file=/etc/prometheus/prometheus.yml --web.enable-lifecycle --storage.tsdb.retention.time=1d >/dev/null && docker run -d --name lab-mon-grafana --network lab_labnet --memory 400m -p 13000:3000 -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin -v "$(W grafana/provisioning):/etc/grafana/provisioning:ro" grafana/grafana:11.3.0 >/dev/null && sleep 60 && docker ps --format '{{.Names}} {{.Status}}' | grep -E 'lab-mon-(prometheus|alertmanager|grafana|webhook)' | sort
```

```out
lab-mon-alertmanager Up About a minute
lab-mon-grafana Up About a minute
lab-mon-prometheus Up About a minute
lab-mon-webhook Up About a minute
```

## 17.7 驗證：target、規則、dashboard

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

四件事：每個 job 有幾個 target 是 up；告警規則載入且沒有錯；Alertmanager 認得 Prometheus；Grafana 有 32 個 dashboard、datasource 連得到 Prometheus。從 lab 的容器裡用 `curl` 查（容器內有 Python 可以整理輸出）：

```bash
docker run --rm --network lab_labnet lab-node:96 bash -c 'curl -s http://lab-mon-prometheus:9090/api/v1/targets | python3 -c "
import json, sys, collections
up = collections.Counter(); total = collections.Counter()
for t in json.load(sys.stdin)[\"data\"][\"activeTargets\"]:
    total[t[\"labels\"][\"job\"]] += 1; up[t[\"labels\"][\"job\"]] += t[\"health\"] == \"up\"
for j in sorted(total): print(\"%-17s up %d / %d\" % (j, up[j], total[j]))
print(\"合計 up %d / %d\" % (sum(up.values()), sum(total.values())))"; curl -s http://lab-mon-prometheus:9090/api/v1/rules | python3 -c "
import json, sys
g = json.load(sys.stdin)[\"data\"][\"groups\"]
r = [x for y in g for x in y[\"rules\"]]
print(\"告警規則 %d 條，載入有錯 %d 條\" % (len(r), sum(x[\"health\"] != \"ok\" for x in r)))"; curl -s http://lab-mon-prometheus:9090/api/v1/alertmanagers | python3 -c "import json, sys; print(\"Prometheus 看到的 Alertmanager:\", [a[\"url\"] for a in json.load(sys.stdin)[\"data\"][\"activeAlertmanagers\"]])"; curl -s http://lab-mon-grafana:3000/api/search?type=dash-db | python3 -c "import json, sys; print(\"Grafana dashboard:\", len(json.load(sys.stdin)), \"個\")"; curl -s http://lab-mon-grafana:3000/api/datasources/uid/Prometheus/health'
```

```out
control-center    up 1 / 1
kafka-broker      up 1 / 4
kafka-controller  up 1 / 3
rest-proxy        up 1 / 2
合計 up 4 / 10
告警規則 19 條，載入有錯 0 條
Prometheus 看到的 Alertmanager: ['http://lab-mon-alertmanager:9093/api/v2/alerts']
Grafana dashboard: 32 個
{"details":{"application":"Prometheus","features":{"rulerApiEnabled":false}},"message":"Successfully queried the Prometheus API.","status":"OK"}
（上面是這次實測環境的數字：叢集沒有起來，只有補起來的 controller、broker、REST、C3 各一個程序在回應。叢集健康時 up 10 / 10）
```

Grafana 的 dashboard 真的查得到資料：用 Grafana 自己的查詢介面（`/api/ds/query`，和畫面上 panel 走同一條路）跑一個 controller 指標的查詢（active controller 數，叢集健康時是 1），`$env` 換成 `lab`：

```bash
docker run --rm --network lab_labnet lab-node:96 bash -c 'curl -s -X POST http://lab-mon-grafana:3000/api/ds/query -H "Content-Type: application/json" -d "{\"queries\":[{\"refId\":\"A\",\"datasource\":{\"type\":\"prometheus\",\"uid\":\"Prometheus\"},\"expr\":\"sum(kafka_controller_kafkacontroller_activecontrollercount{env=\\\"lab\\\", job=\\\"kafka-controller\\\"})\",\"instant\":true}],\"from\":\"now-5m\",\"to\":\"now\"}" | python3 -c "import json, sys; r = json.load(sys.stdin)[\"results\"][\"A\"]; print(\"status\", r[\"status\"], \"active controller 數 =\", r[\"frames\"][0][\"data\"][\"values\"][1][0])"'
```

```out
status 200 active controller 數 = 1
```

Windows 瀏覽器開 `http://localhost:13000` 就是 Grafana，左邊 Dashboards 底下有 32 個。

## 17.8 測告警：兩種 webhook 格式與解除

下面這張圖畫出一條告警從指標到兩種 webhook 的路徑。

![alertpath]

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

不用弄壞叢集：在 Prometheus 多放一條永遠成立的測試規則（`vector(1)`），帶著和正式規則一樣的標籤與註解（`description` 裡故意放了雙引號和冒號，看自訂 JSON 會不會被弄壞）。Prometheus 重新載入規則後，告警送到 Alertmanager，約 1 分鐘內（規則每 30 秒算一次，再加 Alertmanager 的 group_wait 10 秒）兩個 receiver 都會收到：

```bash
cd ~/kafka-lab/bank-monitoring && cat > prometheus/confluent/confluent-alerts-test.yml <<'EOF'
groups:
  - name: confluent-test
    rules:
      - alert: ConfluentTestAlert
        expr: vector(1)
        labels: { severity: critical, impact: SERVICE, env: lab, job: test, hostname: test.poc.lab, instance: "test.poc.lab:7071" }
        annotations:
          summary: "test alert from chapter 17.8"
          description: 'Test only: a "quoted" word and a colon: here, 007 stays a string.'
EOF
docker exec lab-mon-prometheus wget -q -O- --post-data='' http://localhost:9090/-/reload; sleep 70; docker logs lab-mon-webhook 2>&1 | grep -c ConfluentTestAlert
```

```out
2
```

先看**預設格式**：整包 JSON，`alerts` 是陣列（一個通知群組可能有很多筆），欄位是 Alertmanager 的 version 4：

```bash
docker logs lab-mon-webhook 2>&1 | grep '^POST /default' | grep ConfluentTestAlert | head -1 | sed 's/^POST \([^ ]*\) | \([^|]*\)| /\1 \2\n/' | docker run --rm -i lab-node:96 python3 -c "
import json, sys
head, body = sys.stdin.read().split('\n', 1)
d = json.loads(body)
print(head)
print(json.dumps({k: d[k] for k in ('version', 'status', 'receiver', 'groupKey')}, ensure_ascii=False))
a = d['alerts'][0]
print(json.dumps({'status': a['status'], 'labels': a['labels'], 'annotations': a['annotations'], 'startsAt': a['startsAt'], 'fingerprint': a['fingerprint']}, ensure_ascii=False, indent=1))"
```

```out
/default Alertmanager/0.34.1 
{"version": "4", "status": "firing", "receiver": "webhook-default", "groupKey": "{}/{}:{alertname=\"ConfluentTestAlert\", env=\"lab\", hostname=\"test.poc.lab\", impact=\"SERVICE\", instance=\"test.poc.lab:7071\", job=\"test\", severity=\"critical\"}"}
{
 "status": "firing",
 "labels": {
  "alertname": "ConfluentTestAlert",
  "env": "lab",
  "hostname": "test.poc.lab",
  "impact": "SERVICE",
  "instance": "test.poc.lab:7071",
  "job": "test",
  "severity": "critical"
 },
 "annotations": {
  "description": "Test only: a \"quoted\" word and a colon: here, 007 stays a string.",
  "summary": "test alert from chapter 17.8"
 },
 "startsAt": "2026-10-27T15:46:53.564Z",
 "fingerprint": "609b3c4e91aae071"
}
```

再看**自訂格式**：一筆告警一個扁平的 JSON，欄位是前面範本組出來的；`description` 裡的雙引號、冒號、`007` 都完整保留，JSON 沒壞：

```bash
docker logs lab-mon-webhook 2>&1 | grep '^POST /omnibus' | grep ConfluentTestAlert | head -1 | sed 's/^POST \([^ ]*\) | \([^|]*\)| /\1 \2\n/' | docker run --rm -i lab-node:96 python3 -c "
import json, sys
head, body = sys.stdin.read().split('\n', 1)
print(head)
print(json.dumps(json.loads(body), ensure_ascii=False, indent=1))"
```

```out
/omnibus Alertmanager/0.34.1 
{
 "ClassName": "TCB_DYNATRACE_STATUS",
 "hostname": "twnbap1P",
 "msg": "Test only: a \"quoted\" word and a colon: here, 007 stays a string.",
 "msg_catalog": "SERVICE",
 "origin": "dynatrace5P",
 "severity": "ERROR",
 "source": "TCB_DYNATRACE",
 "state": "OPEN",
 "sub_origin": "ConfluentTestAlert: test alert from chapter 17.8",
 "sub_source": "PIB"
}
```

解除：把測試規則拿掉、重新載入。Prometheus 對被拿掉的規則不會補送「已解除」，Alertmanager 要等告警過期（Prometheus 送的告警帶約 4 分鐘的有效期）才自己解除，再在下一輪通知送出 resolved：自訂格式的 `state` 變 `RESOLVED`，預設格式的 `status` 變 `resolved`。（真實的告警是條件消失，Prometheus 會直接送 resolved，不用等這麼久。）等 5 分鐘左右：

```bash
cd ~/kafka-lab/bank-monitoring && rm prometheus/confluent/confluent-alerts-test.yml && docker exec lab-mon-prometheus wget -q -O- --post-data='' http://localhost:9090/-/reload; sleep 290; docker logs lab-mon-webhook 2>&1 | grep ConfluentTestAlert | docker run --rm -i lab-node:96 python3 -c "import re, sys; [print(re.match(r'POST (\S+)', l).group(1).ljust(11), re.search(r'\"(?:state|status)\":\"(\w+)\"', l).group(1)) for l in sys.stdin]"
```

```out
/omnibus  OPEN
/default    firing
/default    resolved
/omnibus  RESOLVED
```

> 實際的 omnibus：接收端如果要認證（例如 API token），在 `webhook_configs` 的 `http_config` 加 `authorization`；token 放 Alertmanager 設定檔以外的檔案（`credentials_file`），不寫進 YAML。`ProblemSeverity` 的對應（這裡 critical → `ERROR`、warning → `PERFORMANCE`）是範例，照 omnibus 的定義改範本。

## 17.9 哪些 dashboard 與 panel 有資料

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

「全部 32 個都放進去」之後，要知道哪些在我們的元件上是活的。下面這段 Python 取出每個 panel 的 PromQL，dashboard 變數換成「All」，對 Prometheus 各查一次（和畫面上選 All 的結果一致），有任何一條 query 回得出序列就算「有資料」：

```bash
cd ~/kafka-lab/bank-monitoring && cat > dashboard-coverage.py <<'EOF'
#!/usr/bin/env python3
"""查官方 Grafana dashboard 的每個 panel 在我們的 Prometheus 裡有沒有資料。

用法：dashboard-coverage.py <Prometheus URL> <dashboard 目錄> [--detail] [--auth user:pass]

做法：把每個 panel 的 PromQL 取出來，dashboard 變數（$env、$instance …）換成「全部」，
$__rate_interval 等換成固定區間，對 Prometheus 做 instant query；有任何一條 query 回得出序列，這個 panel 就算有資料。
這和 Grafana 畫面上選「All」時的結果一致，但不需要開瀏覽器。只用 Python 標準函式庫。
"""
import base64, glob, json, os, re, sys, urllib.parse, urllib.request

args = [a for a in sys.argv[1:] if not a.startswith("--")]
detail = "--detail" in sys.argv
auth = None
if "--auth" in sys.argv:
    auth = sys.argv[sys.argv.index("--auth") + 1]
    args = [a for a in args if a != auth]
prom, folder = args[0].rstrip("/"), args[1]


def query(expr):
    url = prom + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    req = urllib.request.Request(url)
    if auth:
        req.add_header("Authorization", "Basic " + base64.b64encode(auth.encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
    except Exception as e:  # HTTP 400 = PromQL 不合法
        return None, str(e)
    return data["data"]["result"], None


def expand(expr):
    # 變數放在 = 比對的位置時改成 =~，換成 .* 才有意義
    expr = re.sub(r'(\w+)\s*=\s*"(\$\{?[A-Za-z_][\w.]*\}?|\[\[\w+\]\])"', r'\1=~"\2"', expr)
    expr = re.sub(r"\$__rate_interval|\$\{__rate_interval\}", "5m", expr)
    expr = re.sub(r"\$__interval|\$\{__interval\}", "1m", expr)
    expr = re.sub(r"\$__range|\$\{__range\}", "1h", expr)
    expr = re.sub(r"\$\{[A-Za-z_][\w.]*(:[a-z]+)?\}|\$[A-Za-z_]\w*|\[\[\w+\]\]", ".*", expr)
    return expr


def panels(items):
    for p in items:
        yield p
        yield from panels(p.get("panels", []))


total = {"dash": 0, "panels": 0, "data": 0}
print("%-34s %6s %6s  %s" % ("dashboard", "panels", "有資料", "沒資料的 panel"))
for f in sorted(glob.glob(os.path.join(folder, "*.json"))):
    j = json.load(open(f, encoding="utf-8"))
    n = ok = 0
    missing = []
    for p in panels(j.get("panels", [])):
        targets = [t for t in p.get("targets", []) if t.get("expr")]
        if not targets:
            continue
        n += 1
        has = False
        for t in targets:
            res, err = query(expand(t["expr"]))
            if res:
                has = True
                break
        if has:
            ok += 1
        else:
            missing.append(p.get("title", "(無標題)"))
    total["dash"] += 1; total["panels"] += n; total["data"] += ok
    print("%-34s %6d %6d  %s" % (os.path.basename(f), n, ok, ("; ".join(missing[:6]) + (" …" if len(missing) > 6 else "")) if detail else ""))
print("合計 %d 個 dashboard、%d 個 panel、%d 個有資料" % (total["dash"], total["panels"], total["data"]))
EOF
docker run --rm --network lab_labnet -v "$(cygpath -m "$PWD"):/w:ro" lab-node:96 python3 /w/dashboard-coverage.py http://lab-mon-prometheus:9090 /w/grafana/provisioning/dashboards
```

```out
dashboard                          panels    有資料  沒資料的 panel
OTel_kafkametrics.json                  5      0  
cluster-linking.json                   19     12  
confluent-audit.json                    6      5  
confluent-oracle-cdc.json              15      0  
confluent-platform-kraft.json          23      8  
confluent-platform.json                26      4  
confluent-rbac.json                    10      0  
debezium-connectors.json               34      0  
flink-jobmanager.json                  27      0  
flink-taskmanager.json                 52      0  
globalktable.json                      24      4  
kafka-cluster-kraft.json               80     75  
kafka-cluster.json                     87     72  
kafka-connect-cluster.json             54      0  
kafka-consumer.json                    25      3  
kafka-lag-exporter.json                 9      3  
kafka-producer.json                    32      3  
kafka-quotas.json                       6      0  
kafka-stream.json                      27      0  
kafka-streams-rocksdb.json             40      0  
kafka-topics-kraft.json                13     13  
kafka-topics.json                      12     10  
kafka-transaction-coordinator.json     10     10  
kraft.json                             18     18  
ksqldb-cluster.json                    38      0  
librdkafka-application.json            52      0  
mongo.json                             25      0  
replicator.json                         6      0  
rest-proxy.json                        10     10  
schema-registry-cluster.json           12      0  
tiered-storage.json                     8      3  
zookeeper-cluster.json                 11      0  
合計 32 個 dashboard、816 個 panel、253 個有資料
```

怎麼讀這張表（Confluent Server 8.3.2 與 C3 2.6.1，也就是**遷移目標**的版本；lab 單 controller、單 broker、單 REST、單 C3 的實測。**安裝基底（8.2.4／2.5.1）的指標覆蓋沒有逐一重驗**：exporter 規則是版本無關的，但哪些 MBean 有資料以 8.2.4 實際為準，遷移完成後（21.10）再跑一次 17.7、17.9 對照；**RBAC、稽核、Tiered Storage 沒開，要在正式叢集上補驗**）：

| dashboard（檔名） | 有資料／總數 | 判讀 |
|---|---|---|
| `kraft.json` | 在三台 controller 的叢集是空的 | **不可用**。這張全靠 `kafka_server_raft_metrics_*`，而三台 controller 的叢集（8.2.4 與遷移後的 8.3.2 都實測）Prometheus 裡一條 raft 指標都沒有（見 17.10 的備註）；上面表格的 18／18 是單台 controller 的拋棄式環境量到的，不適用 |
| `kafka-cluster-kraft.json` | 75／80 | **可用**（主力）。缺的 5 個：「Offline Partitions Count」——官方 query 寫 `job="kafka-broker"`，但專用 controller 的叢集裡這個指標只在 `kafka-controller` 上，所以空（告警 `KafkaOfflinePartitions` 有涵蓋）；另 4 個是 Tiered Storage（我們沒開） |
| `kafka-topics-kraft.json` | 13／13 | **可用**。topic 大小、流量、partition |
| `kafka-transaction-coordinator.json` | 10／10 | **可用** |
| `rest-proxy.json` | 10／10 | **可用**。每個 REST endpoint 的請求率、錯誤、延遲 |
| `confluent-audit.json` | 5／6 | **可用**（第 18 章稽核啟用後）；缺的是「Fallback entries」，稽核寫不進 topic 才會有值 |
| `confluent-platform-kraft.json` | 8／23 | **部分**。總覽裡 broker、controller 的部分有值；Schema Registry、Connect、ksqlDB 區塊是空的（我們沒有這些元件） |
| `kafka-topics.json`、`kafka-cluster.json`、`confluent-platform.json` | 10／12、72／87、4／26 | **用 KRaft 版就好**。這三張是 ZooKeeper 時代的版本；「Total # of Topics」「Active Controllers」「Offline Partitions」等 panel 同樣寫 `job="kafka-broker"`，在專用 controller 的 KRaft 叢集裡是空的 |
| `kafka-consumer.json`、`kafka-producer.json`、`kafka-lag-exporter.json` | 3／25、3／32、3／9 | **部分／要另外接**。這幾張要應用程式（或 lag exporter）自己掛 exporter；只有 broker 端看得到的少數 panel 有值。consumer lag 請看 C3 畫面 |
| `cluster-linking.json`、`tiered-storage.json` | 12／19、3／8 | 沒開這兩個功能，有值的是不分功能的計數（多數是 0） |
| `kafka-quotas.json` | 0／6 | **未驗證**。要有 quota 設定才有 `kafka_server_produce_byte_rate`；lab 這次的測試叢集沒設 quota（正式叢集依 `conf/apps.txt` 設了，應該有值） |
| `confluent-rbac.json` | 0／10 | **未驗證**。要有 RBAC／MDS；測試叢集沒開（正式叢集有 MDS，應該有值，要在 3 台 controller 的完整 lab 上補驗） |
| `kafka-stream.json`、`globalktable.json`、`kafka-streams-rocksdb.json` | 0／27、4／24、0／40 | **空**。這幾張看應用程式的 Kafka Streams。C3 本身是 Streams 應用，但我們只放行它的 `client_state` 與執行緒數，沒有放 RocksDB／處理率，所以這幾張對 C3 也是空的（想看 C3 的 RocksDB 要改 `rules-c3.yml`，序列數會到好幾千） |
| `kafka-connect-cluster.json`、`confluent-oracle-cdc.json`、`mongo.json`、`debezium-connectors.json`、`replicator.json` | 全 0 | **空**。沒有 Connect |
| `ksqldb-cluster.json`、`schema-registry-cluster.json` | 0／38、0／12 | **空**。沒有 ksqlDB、Schema Registry |
| `flink-jobmanager.json`、`flink-taskmanager.json`、`librdkafka-application.json`、`OTel_kafkametrics.json`、`zookeeper-cluster.json` | 全 0 | **空**。沒有 Flink、librdkafka 應用、OTel kafkametrics 來源、ZooKeeper |

## 17.10 收尾

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

驗完把 lab 的四個監控容器收掉（正式環境是銀行的系統，不收）。設定資料夾 `~/kafka-lab/bank-monitoring` 留著；重建 lab（第 0 章 `down -v`）之前一定要先收，否則容器還接在 labnet 上，網路刪不掉：

```bash
docker rm -f lab-mon-prometheus lab-mon-alertmanager lab-mon-grafana lab-mon-webhook >/dev/null && echo "lab-mon-* 已收掉：$(docker ps -a --format '{{.Names}}' | grep -c '^lab-mon-') 個剩下"
```

```out
lab-mon-* 已收掉：0 個剩下
```

> 兩件事要跟銀行講清楚：(1) exporter 的 YAML 裡有 keystore 的明文密碼，所以是 root:confluent 0640，不能再放寬；(2) consumer lag 不是 broker 的 JMX 指標，要看 C3（畫面）或另外接 lag exporter；Grafana 的 `kafka-consumer.json`、`kafka-lag-exporter.json` 要有對應來源才有資料。
>
> 監控的邊界：這一章是**主機與程序層**的監控（程序在不在、KRaft 健不健康、partition 狀態、延遲、JVM）。C3 內建 Prometheus 收的 telemetry（`confluent_kafka_server_*`）只給 C3 畫面，不抓、不告警；license 到期用 22 章的 syslog 告警；稽核事件看第 18 章。
>
> KRaft 指標：Confluent Server 的 `kafka_server_raft_metrics_*`（current_leader、number_of_voters、commit／election latency 等）**只有單台 controller（`--standalone`）的環境抓得到**。三台 controller 的叢集，不論 8.2.4 或遷移後的 8.3.2，實測 controller job 有三千多條序列，raft 指標卻是 0 條。所以 quorum 健康靠 controller 自己的四個指標：`ActiveControllerCount`（全叢集剛好 1）、`LastAppliedRecordLagMs`、`MetadataErrorCount`、`NewActiveControllersCount`（leader 更換次數）；quorum 內容用 `kafka-metadata-quorum describe --status` 看。官方 `kraft.json` 這張 dashboard 因此是空的，不引入也沒關係。

# 18. 第十八站：稽核日誌（audit log）

![audit]

**這一章在做什麼**：讓 Kafka 把「誰對什麼做了什麼」記成稽核事件，並依銀行要求分流與設定保留期。前提：第 15 章已做（密碼進 Secret Protection）、第 11 章的 RBAC 已建。這一章會**滾動重啟** controller 與 broker（18.2），請在變更時段一台一台做。

Confluent Server 內建稽核：誰、用什麼身分、對哪個 topic 做了什麼、准還是拒，每一筆都是一個事件，寫進 Kafka 自己的 topic。預設是用 broker 自己的身分寫、全部塞同一個 topic。銀行要的是：用一個**專用的低權限帳號**寫、**敏感 topic 的事件分開放、留久一點**、排除平台自己的雜訊。這一章把這三件事做上去，密碼一樣進 Secret Protection。

| 誰 | 做什麼 |
|---|---|
| 小安 | 建寫入帳號與權限、改 controller／broker 的設定（加密、派送）、滾動重啟、製造允許與拒絕的事件來驗證 |
| 銀行稽核 | 之後用 OP menu 的 43／45，或自己的 SIEM 讀這兩個 topic |

## 18.1 專用的寫入帳號

@role 小安 | ops02 | root

這一節建一個專門寫稽核事件的帳號，把權限壓到最小。`confluent-audit` 是 SCRAM 帳號，只能寫與管理 `confluent-audit-log-events` 開頭的 topic（prefix 同時涵蓋 `_sensitive`），不是 super user：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && BS=kb01.poc.lab:9094 && (umask 077; [ -s ~/secrets/confluent-audit.pass ] || openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/confluent-audit.pass) && P=$(cat ~/secrets/confluent-audit.pass) && kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties --alter --entity-type users --entity-name confluent-audit --add-config "SCRAM-SHA-512=[iterations=8192,password=$P]" >/dev/null && unset P && confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key >/dev/null 2>&1 && CID=$(curl -sk https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4) && for r in DeveloperWrite DeveloperManage; do confluent iam rbac role-binding create --principal User:confluent-audit --role $r --resource Topic:confluent-audit-log-events --prefix --kafka-cluster "$CID" >/dev/null 2>&1; done; confluent iam rbac role-binding list --principal User:confluent-audit --kafka-cluster "$CID" 2>/dev/null | tail -n +3
```

```out
  User:confluent-audit | DeveloperManage | Topic         | confluent-audit-log-events | PREFIXED
  User:confluent-audit | DeveloperWrite  | Topic         | confluent-audit-log-events | PREFIXED
```

## 18.2 設定片段：寫入者、路由、保留天數

@role 小安 | ops02 | root

這一節把稽核設定加進 controller 與 broker 共用的設定片段，決定誰寫、事件放哪個 topic、留幾天。接在 `common.tpl`（controller 與 broker 共用）後面。路由規則是一行 JSON：`payments.*` 的 produce／consume（允許與拒絕）和被拒絕的 describe 送到 `_sensitive`（留 365 天），其他送預設 topic（留 90 天），`kafka-internal`、`svc-c3` 的事件不記：

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


@role 小安 | ops02 | root

重新產生 7 台的 `server.properties`（第 15 章的流程：明文渲染 → Secret Protection 加密，新增的兩個密碼欄位會被一起加密進同一份 `security.properties`）、派送、滾動重啟。REST Proxy 與 C3 不受影響：

```bash
cd ~/conf && export STORE_PASSWORD=$(cat ~/pki/store.pass) LDAP_BIND_PASSWORD=$(cat ~/secrets/ldap-bind.pass) AUDIT_PASSWORD=$(cat ~/secrets/confluent-audit.pass) && V='${HOST_FQDN} ${NODE_ID} ${RACK} ${STORE_PASSWORD} ${LDAP_BIND_PASSWORD} ${AUDIT_PASSWORD}' && for h in kc01:1:- kc02:2:- kc03:3:- kb01:101:rack-a kb02:102:rack-a kb03:103:rack-b kb04:104:rack-b; do IFS=: read -r n id rack <<<"$h"; export HOST_FQDN=$n.poc.lab NODE_ID=$id RACK=$rack; case $n in kc*) tpl=controller.tpl;; *) tpl=broker.tpl;; esac; (umask 077; { envsubst "$V" < $tpl; echo; envsubst "$V" < common.tpl; } > $n.server.properties); done; unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD; export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key); for f in *.server.properties; do keys=$(grep -E '^[^#].*(password|credentials|jaas.config)=' $f | cut -d= -f1 | paste -sd,); confluent secret file encrypt --config-file $f --local-secrets-file ~/secrets/security.properties --remote-secrets-file /etc/confluent/secrets/security.properties --config "$keys" >/dev/null && echo "$f: $(grep -c '\${securepass:' $f) encrypted, plaintext=$(grep -cE '^[^#].*(password|credentials)=[^$]' $f)"; done; unset CONFLUENT_SECURITY_MASTER_KEY; for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do scp -q $h.server.properties ~/secrets/security.properties $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo install -o root -g confluent -m 0640 /tmp/$h.server.properties /etc/confluent/kafka/server.properties && sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties && rm -f /tmp/$h.server.properties /tmp/security.properties && printf '%s ' \$(hostname)"; done; echo
```

```out
kb01.server.properties: 22 encrypted, plaintext=0
（7 個檔；broker 22、controller 13）
kc01 kc02 kc03 kb01 kb02 kb03 kb04
```


@role 小安 | ops02 | root

滾動重啟 controller 與 broker，確認兩個稽核 topic 建好了：

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

## 18.3 製造事件、讀回來

@role 小安 | ops02 | root

這一節故意製造「允許」與「拒絕」的事件，再讀稽核 topic 確認有被記下來、而且放對 topic。alice（SystemAdmin）往 `payments.events` 寫一筆（允許、敏感 → `_sensitive`）；`app-orders` 想讀 `payments.events`（它只有 orders.* 的權限 → 拒絕、敏感 → `_sensitive`）；`app-orders` 讀自己的 `orders.events`（允許、不敏感 → 預設 topic）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && (umask 077; cat > ~/conf/client-alice.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="$(cat ~/secrets/ad-test-users.pass)";
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
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
  （… 第 16 站 OP menu 問 MDS 留下的授權事件）
```

> 三件事值得看清楚：(1) 敏感 topic 的事件在 `_sensitive`：alice 的 produce（允許）和 app-orders 想讀時的 Metadata（describe 被拒）。(2) **一般 topic 的 produce／consume 不會被記**：app-orders 讀 orders.events 沒有出現在任何 topic，因為 Confluent 預設只記「管理類」與「授權類」事件（例如上面 MDS 的 Authorize，那是第 16 章 OP menu 問權限留下的），produce／consume 只在路由裡明確列出的 topic 才記。要記全部就把 `crn:///kafka=*/topic=*` 的 produce／consume 也寫進 routes，量會很大。(3) `kafka-internal`、`svc-c3` 完全不出現。OP menu 的 43（匯出）、45（查詢）讀的就是這兩個 topic。

## 18.4 要跟稽核單位說清楚的事

| 項目 | 說明 |
|---|---|
| 寫入者 | `confluent-audit`（SCRAM，只有 audit topic 的 Write／Manage），不是 super user；密碼在 Secret Protection 裡 |
| 保留 | 預設 topic 90 天、`_sensitive` 365 天，都是 topic 的 retention；要更久就外送 SIEM |
| 誰能讀 | 綁了 audit topic DeveloperRead 的群組（lab 是 SystemAdmin 直接讀）；稽核群組用 OP menu 43／45 匯出與查詢 |
| 量 | `kafka-internal`、`svc-c3` 已排除；只有路由列出的 topic 才記 produce／consume，要擴大範圍前先估磁碟 |
| 改規則 | 改 `common.tpl` 的 router JSON → 重新加密派送 → 滾動重啟（和這一章一樣） |
| 可靠度 | 兩個 audit topic 都是 replication factor 3（lab 確認：`kafka-topics --describe`），`min.insync.replicas=1`：稽核寫入不因少一台 broker 而停；原廠建議稽核量大或要求隔離時，送到**專用的稽核叢集**（`confluent.security.event.logger.exporter.kafka.bootstrap.servers` 指過去） |

確認 replication factor（換 broker、縮減之後也看一次）：

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && for t in confluent-audit-log-events confluent-audit-log-events_sensitive; do kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --topic $t 2>/dev/null | head -1 | grep -oE 'Topic: [^[:space:]]+|ReplicationFactor: [0-9]+|min.insync.replicas=[0-9]+' | paste -sd' '; done
```

```out
Topic: confluent-audit-log-events ReplicationFactor: 3 min.insync.replicas=1
Topic: confluent-audit-log-events_sensitive ReplicationFactor: 3 min.insync.replicas=1
```

# 19. 第十九站：驗收與收尾

![acceptance]

**這一章在做什麼**：交付前把整個平台完整驗一遍，並把安裝期間留下的東西收乾淨。前提：第 1–18 章都做完（沒做的延伸章節，對應的檢查項目會是 FAIL，先確認是不是該章沒做）。通過標準：19.1–19.3 每一組都是「N / N 項通過」，沒有任何 FAIL；19.4 的重啟與冷開機要自己回來。

每一章結尾都有自己的檢查，但交付前要有一份**一次跑完、結果能附在驗收文件裡**的清單。四組：平台健康、安全（正向與反向都測）、應用程式端、維運。最後是收尾：安裝期間留在操作機與主機上的東西，哪些要留、哪些要收。

這份驗收不綁版本：裝完**安裝基底**（8.2.4）跑一次，第 21 章遷移的每一段（C3 與套件、JDK 25、finalize）之後各跑一次，第 26 章 OS 更新到 9.8 之後再跑一次，結果都要全數通過。

## 19.1 平台健康

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && ok=0; all=0; chk() { local name="$1"; shift; all=$((all+1)); if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$name"; ok=$((ok+1)); else printf 'FAIL %s\n' "$name"; fi; }; chk "controller quorum 有 leader" bash -c 'kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status | grep -q "LeaderId: *[0-9]"'; for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do chk "$h confluent-server active" ssh $h.poc.lab 'systemctl is-active -q confluent-server'; done; for h in kb01 kb02 kb03 kb04; do chk "$h MDS 8090 回 200" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) = 200 ]"; done; chk "沒有 under-replicated partition" bash -c '[ "$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions | grep -c Partition:)" = 0 ]'; chk "沒有 offline partition" bash -c '[ "$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --unavailable-partitions | grep -c Partition:)" = 0 ]'; chk "Self-Balancing 啟用" bash -c 'kafka-rebalance-cluster --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --status 2>/dev/null | grep -q "Balancer status: ENABLED"'; chk "REST Proxy 經 LB 回 200（mTLS）" bash -c "[ \$(curl -s --cacert $CA --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters) = 200 ]"; chk "Control Center 9021 回 200" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) = 200 ]"; chk "C3 的 Prometheus 有 broker 指標" bash -c "curl -s --cacert $CA --cert ~/pki/certs/c3-monitoring.crt --key ~/pki/keys/c3-monitoring.key https://c3-01.poc.lab:9090/api/v1/label/__name__/values | grep -q confluent_kafka_server"; for h in kc01 kb01 rest01 c3-01; do chk "$h JMX exporter 7071 要帳密" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://$h.poc.lab:7071/metrics) = 401 ]"; done; echo "健康：$ok / $all 項通過"
```

```out
ok   controller quorum 有 leader
ok   kc01 confluent-server active
（…）
ok   rest01 JMX exporter 7071 要帳密
ok   c3-01 JMX exporter 7071 要帳密
健康：22 / 22 項通過
```

## 19.2 安全：正向與反向

@role 小安 | ops02 | root

每一條規則都要有「該過的過、該擋的擋」：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && P=$(cat ~/secrets/ad-test-users.pass) && ok=0; all=0; chk() { local name="$1"; shift; all=$((all+1)); if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$name"; ok=$((ok+1)); else printf 'FAIL %s\n' "$name"; fi; }; mds() { curl -s --cacert $CA -u "$1:$2" -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate; }; export -f mds; export CA; chk "AD 帳密正確 → MDS 給 token" bash -c "[ \$(mds alice '$P') = 200 ]"; chk "AD 密碼錯 → 401" bash -c "[ \$(mds alice wrong-password) = 401 ]"; chk "不存在的帳號 → 401" bash -c "[ \$(mds nobody '$P') = 401 ]"; chk "carol 在自己 prefix 以外建 topic 被拒" bash -c "kafka-topics --bootstrap-server kb01.poc.lab:9096 --command-config <(sed 's/username=\"alice\"/username=\"carol\"/' ~/conf/client-alice.properties) --create --topic payments.carol-test --partitions 1 --replication-factor 3 2>&1 | grep -q 'TopicAuthorizationException'"; chk "app-orders 讀 payments.events 被拒" bash -c "kafka-console-consumer --bootstrap-server kb01.poc.lab:9095 --consumer.config ~/conf/app-orders.properties --topic payments.events --max-messages 1 --timeout-ms 8000 2>&1 | grep -q TopicAuthorizationException"; chk "REST Proxy 不帶憑證 → 連線被拒" bash -c "! curl -s --cacert $CA --max-time 10 https://rest.poc.lab:8082/v3/clusters -o /dev/null"; chk "REST Proxy 帶非 app 憑證（svc-ops）→ 401" bash -c "[ \$(curl -s --cacert $CA --cert ~/pki/certs/svc-ops.crt --key ~/pki/keys/svc-ops.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters) = 401 ]"; chk "CLIENT 9095 不帶 SASL → 失敗" bash -c "! kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config <(printf 'security.protocol=SSL\nssl.truststore.type=PKCS12\nssl.truststore.location=/root/pki/certs/truststore.p12\nssl.truststore.password=%s\n' \"\$(cat ~/pki/store.pass)\") --list 2>/dev/null"; chk "JMX exporter 匿名 → 401" bash -c "[ \$(curl -s --cacert $CA -o /dev/null -w '%{http_code}' https://kb01.poc.lab:7071/metrics) = 401 ]"; chk "用無關的 CA 驗 MDS 憑證會被拒（鏈驗證生效）" bash -c "! curl -s --max-time 10 --cacert <(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null -subj /CN=junk 2>/dev/null) https://kb01.poc.lab:8090/v1/metadata/id -o /dev/null"; for h in kb01 rest01 c3-01; do chk "$h properties 沒有明文密碼" ssh $h.poc.lab 'f=$(ls /etc/confluent/kafka/server.properties /etc/confluent/kafka-rest/kafka-rest.properties /etc/confluent/control-center/control-center.properties 2>/dev/null | head -1); [ "$(sudo grep -cE "^[^#].*(password|credentials|jaas.config)=[^$]" $f)" = 0 ]'; done; chk "kb01 磁碟上的 master key 只有 service.env 一個" ssh kb01.poc.lab 'n=$(sudo grep -rl CONFLUENT_SECURITY_MASTER_KEY= /etc/confluent /etc/systemd/system 2>/dev/null | wc -l); [ "$n" = 1 ]'; chk "各主機 /etc/confluent/ssl 是 0750" ssh kb01.poc.lab '[ "$(sudo stat -c %a /etc/confluent/ssl)" = 750 ]'; unset P; echo "安全：$ok / $all 項通過"
```

```out
ok   AD 帳密正確 → MDS 給 token
ok   AD 密碼錯 → 401
（…）
安全：15 / 15 項通過
```

> carol 的群組在第 16 章拿到 `orders.` prefix 的 DeveloperManage，所以她在自己的 prefix 裡是能建 topic 的；反向測試要用她沒有權限的 prefix。

## 19.3 應用程式端

@role 小安（扮演兩個應用程式） | ops02 | root

直連的 app-orders（SCRAM）寫一筆、讀回來；經 REST Proxy 的 app-legacy-billing（mTLS）寫一筆，再由 alice 讀出來確認真的進了 topic：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && CID=$(curl -s --cacert $CA https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4) && M="acceptance-$(date +%s)" && echo "$M" | kafka-console-producer --bootstrap-server kb01.poc.lab:9095 --producer.config ~/conf/app-orders.properties --topic orders.events >/dev/null 2>&1 && echo "app-orders SCRAM 直連寫入：ok"; kafka-console-consumer --bootstrap-server kb01.poc.lab:9095 --consumer.config ~/conf/app-orders.properties --topic orders.events --group orders-acceptance --from-beginning --timeout-ms 45000 2>/dev/null | grep -c "$M" | sed 's/^/app-orders 讀回自己寫的：/'; code=$(curl -s --cacert $CA --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "{\"value\":{\"type\":\"JSON\",\"data\":\"$M-rest\"}}" "https://rest.poc.lab:8082/v3/clusters/$CID/topics/billing.events/records"); echo "app-legacy-billing 經 LB + REST Proxy（mTLS）寫入：HTTP $code"; kafka-console-consumer --bootstrap-server kb01.poc.lab:9096 --consumer.config ~/conf/client-alice.properties --topic billing.events --group billing-acceptance --from-beginning --timeout-ms 15000 2>/dev/null | grep -c "$M-rest" | sed 's/^/alice 在 billing.events 看到那筆：/'
```

```out
app-orders SCRAM 直連寫入：ok
app-orders 讀回自己寫的：1
app-legacy-billing 經 LB + REST Proxy（mTLS）寫入：HTTP 200
alice 在 billing.events 看到那筆：1
```

## 19.4 維運：選單重啟、冷開機

**這一節在做什麼**：驗證兩件事：維運人員用選單重啟一台 broker 時叢集不中斷；整批機器同時斷電再開機時，平台自己回來。維運人員用選單重啟一台 broker（第 16 章的路徑：bob 登入選單 → MDS 確認權限 → cpuser ssh → sudo 只開的 restart），叢集不中斷。


@role 維運人員 bob（lab 由 Windows 終端代打） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && docker exec -i lab-ops02-1 bash /root/conf/opmenu-try.sh bob 21 kb03.poc.lab:confluent-server </dev/null | tail -1 && docker exec lab-ops02-1 bash -c 'for i in $(seq 1 24); do [ "$(curl -s -o /dev/null -w "%{http_code}" https://kb03.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "kb03 MDS=$(curl -s -o /dev/null -w "%{http_code}" https://kb03.poc.lab:8090/v1/metadata/id) after ~$((i*5))s; under-replicated=$(JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:)"'
```

```out
已重啟 kb03.poc.lab 的 confluent-server
kb03 MDS=200 after ~20s; under-replicated=0
```


@role Lab 管理員（扮演機房停電） | Windows 終端 | 本機

冷開機：全部主機同時關、同時開，看平台自己回來的順序與時間。lab 裡：用 `docker compose stop／start` 模擬停電。看什麼才算過：4 台 broker 的 MDS 都回 200、C3 回 200、REST 經 LB 回 200、broker 的重試次數是 0。C3 比 MDS 先起來時會等（第 13 章的 drop-in）。


@role Lab 管理員（扮演機房停電） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && MSYS_NO_PATHCONV=1 docker compose -f compose.yml stop 2>&1 | grep -c Stopped && t0=$(date +%s) && MSYS_NO_PATHCONV=1 docker compose -f compose.yml start 2>&1 | grep -c Started && probe() { docker exec lab-ops02-1 bash -c "curl -sk -o /dev/null -w '%{http_code}' $1"; }; for i in $(seq 1 60); do a=0; for h in kb01 kb02 kb03 kb04; do [ "$(probe https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && a=$((a+1)); done; [ $a = 4 ] && break; sleep 10; done; echo "4 台 broker 的 MDS 都回 200：$(( $(date +%s) - t0 ))s"; for i in $(seq 1 60); do [ "$(probe https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 10; done; echo "C3 回 200：$(( $(date +%s) - t0 ))s"; echo "REST 經 LB：$(docker exec lab-ops02-1 bash -c "curl -s --cacert /etc/pki/ca-trust/source/anchors/bank-root.pem --cert /root/pki/certs/app-legacy-billing.crt --key /root/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters")"; docker exec lab-kb01-1 bash -c 'echo "kb01 confluent-server 重試次數：$(journalctl -u confluent-server --since "-10min" --no-pager | grep -c "Scheduled restart job")"'
```

```out
14
14
4 台 broker 的 MDS 都回 200：90s
C3 回 200：150s
REST 經 LB：200
kb01 confluent-server 重試次數：0
```

master key 落地在每台的 `service.env`，開機不依賴保管庫，所以重試次數是 0。C3 在第 13 章的 drop-in 加了「等 MDS」之後約 2–3 分鐘回來；沒加之前 lab 實測是 12 分鐘（C3 比 MDS 先起來會卡住不開 9021）。

操作機也重開了。`/secure/ssh` 的 volume 還在，金鑰不用重放；正式環境那個加密的 file system 要先解鎖、掛載好，ssh 才連得上各主機（沒掛載好時 ssh 找不到金鑰檔）。確認金鑰還在、連得上各主機：

@role 小安 | ops02 | root

```bash
mountpoint /secure/ssh && stat -c '%U:%G %a %n' /secure/ssh/cpuser_ed25519 && ssh -o BatchMode=yes kb01.poc.lab hostname
```

```out
/secure/ssh is a mountpoint
root:root 400 /secure/ssh/cpuser_ed25519
kb01
```

## 19.5 收尾：安裝完成後要收的東西

**這一節在做什麼**：交付前清掉安裝期間的暫存與不再需要的權限，只留日後維運要用的。**提醒：`~/landing/rpm-target/` 與 `~/landing/bank/` 的 JDK 25 要保留到第 21 章（遷移）全部做完，不要先刪；細節見 21.1。**

@role 小安 | ops02 | root

| 留在操作機 | 收掉或交出去 |
|---|---|
| `~/conf/`（範本與產出的設定，之後改設定都從這裡）、`~/pki/`（憑證、CSR、keystore 密碼）、`~/secrets/`（0600）、`~/monitoring/` | `~/landing/`、`~/repo/` 可以刪（套件已上架；要回滾用套件庫裡的舊版）。例外：還要照第 21 章遷移的話，`~/landing/rpm-target/` 與 `~/landing/bank/` 的 JDK 25 要留到遷移完成 |
| ssh 私鑰 `/secure/ssh/cpuser_ed25519`（root、0400）留在操作機的獨立 file system；不放 CyberArk、不備份，操作機重建就重新產生並重新佈署公鑰（3.1） | `/tmp/` 裡安裝期間的暫存檔 |
| | `~/pki/keys/svc-ops.key`：安裝完成後建議移到離線保管，需要時再取回（它是 super user）；憑證輪替（第 20 章）、升級（第 21 章）前要先取回 |
| | 各主機 cpuser 的全權 sudo（`/etc/sudoers.d/cpuser`）：移除，只留 `cpuser-ops` 窄規則（lab 留著，後面章節還要用） |
| | 交給 Secrets 團隊存進 PVWA 的：store.pass、kafka-admin、應用程式 SCRAM（11.1）、master key 與 passphrase（15.2）、緊急憑證（16.2）、JMX 抓取密碼（17.5）、confluent-audit（18.1） |

```bash
rm -rf /tmp/jmx-* /tmp/*.properties 2>/dev/null; du -sh ~/landing ~/repo 2>/dev/null | tr '\n' ' '; echo; for h in kc01 kb01 rest01 c3-01; do ssh $h.poc.lab 'printf "%s: /tmp 殘留 %s 個；sudoers %s\n" $(hostname) $(ls /tmp | grep -cv "^hsperfdata\|^systemd-private\|^lib.*\.so\|^com_\|^\.") "$(sudo ls /etc/sudoers.d | tr "\n" ",")"'; done; find ~ -maxdepth 2 -type f \( -name '*.key' -o -name '*.pass' -o -name 'master.key' \) ! -perm 600 2>/dev/null | sed 's/^/權限不是 0600：/'; echo "收尾檢查完成"
```

```out
3.1G	/root/landing 2.9G	/root/repo
kc01: /tmp 殘留 0 個；sudoers cpuser,cpuser-ops,
（4 行；JVM 自己的 lib*.so、hsperfdata 不算）
收尾檢查完成
```

交付清單裡還有兩個排程要先裝好：license 到期檢查（22.2）、每日中繼資料備份（25.2–25.4）。兩個都先放在操作機的 systemd timer；**待銀行確認**：行內若有排程系統（例如 Control-M），改由它在同樣的時間呼叫同一支腳本，操作機上的 timer 就不用裝。

> 正式環境交付時再做三件 lab 不做的事：OS 團隊把各主機 `/etc/sudoers.d/cpuser`（全權）移除；把 `svc-ops.key` 移到離線保管；`~/landing`、`~/repo` 依銀行留存政策處理（套件庫才是正本）。


## 19.6 演練：換 SSH 金鑰（人工、不中斷）

下面這張圖把換金鑰五個步驟每個時間點的狀態畫成表。

![keyrotate]

金鑰長期不換是風險，所以定期人工換一次（週期見問題清單 4.6）。做法是「新舊並存」：先讓各主機同時認得新舊兩把公鑰，確認新金鑰能登入每一台，再換掉操作機上的私鑰、刪掉舊公鑰。**每個時間點操作機上都有一把能用的私鑰**，所以不中斷。全程在操作機以 root 做；cpuser 自己的 `authorized_keys` 由 cpuser 改（用舊金鑰登入去改），不需要 OS 團隊，也不動 sudo。

| 步驟 | 動作 | 此時的狀態 |
|---|---|---|
| 1 | 在操作機產生新金鑰對（`.new`），註解帶新日期 | 私鑰：舊；各主機公鑰：舊 |
| 2 | 用舊金鑰把新公鑰（`from=` 和原本一致）加進每一台，舊公鑰保留 | 私鑰：舊；各主機公鑰：舊＋新 |
| 3 | 逐台用新金鑰測試登入 | 全部通過才進行下一步 |
| 4 | 操作機的私鑰與公鑰檔**成對**換成新的 | 私鑰：新；各主機公鑰：舊＋新 |
| 5 | 用新金鑰把各主機上的舊公鑰刪除（依註解辨識），並刪除操作機上的舊私鑰 | 私鑰：新；各主機公鑰：新 |

**誠實的限制**：步驟 4 要換私鑰和 `.pub` 兩個檔，換完之前有一個極短的空窗（lab 實測約為微秒級）：剛好在這一瞬間開始的 ssh 連線，會因為私鑰與 `.pub` 不成對而失敗一次。所以步驟 4 請在**沒有其他連線作業**時進行，動作要快（兩個 `mv` 寫在同一行）。下面的演練用一個每 0.2 秒連一次 kb01 的探針量：整個換金鑰過程最多失敗 1 次（換私鑰的瞬間），其他時間 0 次。

> 新增公鑰時，`from=` 要和原本的公鑰行一致。實際執行前，先在一台非正式主機演練。換金鑰期間不要同時做安裝或升級。

@role 小安 | ops02 | root

先開探針（背景每 0.2 秒連一次 kb01，記連線數與失敗數）：

```bash
rm -f /tmp/probe.stop /tmp/probe.result; (n=0; f=0; while [ ! -f /tmp/probe.stop ]; do n=$((n+1)); ssh -o BatchMode=yes -o ConnectTimeout=3 kb01.poc.lab true 2>/dev/null || f=$((f+1)); sleep 0.2; done; echo "$n $f" > /tmp/probe.result) </dev/null >/dev/null 2>&1 &
sleep 1; echo "探針已開始"
```

```out
探針已開始
```

步驟 1–3：產生新金鑰對（註解多加時分，因為演練可能和安裝同一天，要分得出新舊）；從操作機自己的 `authorized_keys` 取出現在的 `from=`，把新公鑰行加進每一台（用舊金鑰登入）和 repo01 的 repodeploy；用新金鑰逐台測試（`-F /dev/null` 不讀 ssh config，不然 config 裡的舊金鑰會讓測試假通過）：

```bash
cd /secure/ssh && T="cpuser@ops02 cpuser@kc01 cpuser@kc02 cpuser@kc03 cpuser@kb01 cpuser@kb02 cpuser@kb03 cpuser@kb04 cpuser@rest01 cpuser@rest02 cpuser@c3-01 repodeploy@repo01" && OLD_COMMENT=$(awk '{print $3}' cpuser_ed25519.pub) && ssh-keygen -q -t ed25519 -N '' -C "cpuser-ops-$(date +%Y%m%d-%H%M)" -f cpuser_ed25519.new && chmod 0400 cpuser_ed25519.new && FROM=$(sed -n 's/^\(from="[^"]*"\) .*/\1/p' /home/cpuser/.ssh/authorized_keys | head -1) && NEWLINE="$FROM $(cat cpuser_ed25519.new.pub)" && for t in $T; do ssh $t.poc.lab "printf '%s\n' '$NEWLINE' >> ~/.ssh/authorized_keys" || echo "$t: 加新公鑰失敗"; done; ok=0; for t in $T; do ssh -F /dev/null -i cpuser_ed25519.new -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new $t.poc.lab true 2>/dev/null && ok=$((ok+1)); done; echo "舊：$OLD_COMMENT；新：$(awk '{print $3}' cpuser_ed25519.new.pub)；新金鑰登入：$ok/12 台"
```

```out
舊：cpuser-ops-20261027；新：cpuser-ops-20261028-0930；新金鑰登入：12/12 台
```

步驟 4：換私鑰。先備份舊的（`.old`，步驟 5 才刪），再成對換成新的，兩個 `mv` 連在一起：

```bash
cd /secure/ssh && cp -p cpuser_ed25519 cpuser_ed25519.old && cp -p cpuser_ed25519.pub cpuser_ed25519.old.pub && mv -f cpuser_ed25519.new cpuser_ed25519 && mv -f cpuser_ed25519.new.pub cpuser_ed25519.pub && stat -c '%a %n' cpuser_ed25519*
```

```out
400 cpuser_ed25519
400 cpuser_ed25519.old
644 cpuser_ed25519.old.pub
644 cpuser_ed25519.pub
```

步驟 5：用新金鑰把各主機上的舊公鑰行刪掉（依註解，整行比對到結尾），確認舊金鑰被拒、每台只剩一行金鑰，最後刪掉操作機上的舊私鑰：

```bash
cd /secure/ssh && T="cpuser@ops02 cpuser@kc01 cpuser@kc02 cpuser@kc03 cpuser@kb01 cpuser@kb02 cpuser@kb03 cpuser@kb04 cpuser@rest01 cpuser@rest02 cpuser@c3-01 repodeploy@repo01" && OLD_COMMENT=$(awk '{print $3}' cpuser_ed25519.old.pub) && for t in $T; do ssh $t.poc.lab "sed -i '/ $OLD_COMMENT\$/d' ~/.ssh/authorized_keys" || echo "$t: 刪舊公鑰失敗"; done; refused=$(ssh -F /dev/null -i cpuser_ed25519.old -o IdentitiesOnly=yes -o BatchMode=yes cpuser@kb01.poc.lab true 2>&1 | grep -c 'Permission denied'); lines=$(for t in $T; do ssh $t.poc.lab 'grep -c ssh-ed25519 ~/.ssh/authorized_keys'; done | sort | uniq -c | sed 's/^ *//'); rm -f cpuser_ed25519.old cpuser_ed25519.old.pub; echo "舊金鑰被拒：$refused；每台金鑰行數（台數 行數）：$lines；/secure/ssh：$(ls | paste -sd' ')"
```

```out
舊金鑰被拒：1；每台金鑰行數（台數 行數）：12 1；/secure/ssh：cpuser_ed25519 cpuser_ed25519.pub
```

停探針，看整個過程有沒有連線失敗：

```bash
touch /tmp/probe.stop; sleep 3; read n f < /tmp/probe.result; echo "探針：換金鑰全程連線 $n 次，失敗 $f 次（0 次，或 1 次且發生在步驟 4 換私鑰的瞬間）"
```

```out
探針：換金鑰全程連線 … 次，失敗 0 次（0 次，或 1 次且發生在步驟 4 換私鑰的瞬間）
```

> 這是「換金鑰」，不是「操作機重建」。操作機重建時舊私鑰不在（沒有備份），要重做 3.1.2–3.1.3：產生新金鑰對、OS 團隊重新佈署公鑰。
>
> 待銀行確認：換金鑰的週期（例如每年）與由誰執行（問題清單 4.6）。

# 20. 第二十站：憑證輪替

![certrotate]

**怎麼用這一章**：先讀 20.0，判斷銀行說的「換憑證」是下表哪一種，再跳到對應的節。只是到期前換發就做 20.1 → 20.2；銀行換 CA 才需要 20.3 或 20.4。每一次換發都要**滾動重啟**所有元件（含 REST Proxy 的 LB 停用／恢復），請在變更時段做，一台健康了才做下一台。

第 9 章簽的憑證效期一年，到期前一定要換。這一章做兩件事：每年都會遇到的 **leaf 換發**（同一個銀行 CA 重簽），以及幾年一次、銀行決定的 **換 CA**（三階段：先加新根 → 換 leaf → 移除舊根）。MDS token 金鑰不是銀行 CA 簽的、沒有到期日，不在這一章（只在外洩時才換）。

| 情境 | 多久一次 | 會不會斷線 |
|---|---|---|
| leaf 換發 | 每年，到期前一個月內 | 不會：truststore 只信根憑證，新舊 leaf 在滾動期間都被信任 |
| 換 CA | 銀行決定（幾年一次） | 不會：三階段的每一段，所有元件都同時信任新舊兩個根 |

做法的原則：
- **每次換發都產生新私鑰**，不重用舊的 CSR。
- 檔名、路徑、keystore 密碼都和原本一樣，所以 properties 一個字都不用改（Secret Protection 的密文也不用重算）。
- 新的東西先放在 `~/pki/next/`，派送完、驗證過，才換成 `~/pki/` 的正本；舊的留在 `~/pki/old-<日期>/`。
- **遷移前後都適用**：這一章在安裝基底（JDK 21）和遷移之後（JDK 25）指令完全一樣。服務信任的是自己的 `truststore.p12`，不碰 JDK 的 `cacerts`，所以換 JDK 不影響信任；`keytool` 一律走 `/opt/java/current`。lab 的順序是基底驗收完先換一次 leaf（第 21 章之前），遷移完成後的驗收會再證明新版與新 JDK 照樣接受這些憑證。

## 20.0 銀行說要換憑證時，先判斷是哪一種

銀行說「要換根」或「要換中繼」時，先問清楚三件事：**換的是哪一層**、**那一層的私鑰有沒有換**、**舊的什麼時候到期**。驗證憑證時看的是「上一層的名稱和公鑰」，不是上一層那張憑證本身，所以私鑰沒換的那一層，下面的憑證都還驗得過；工作量差很多：

| 根 | 中繼 | 我方的 leaf（server／client） | p12 裡夾帶的中繼（憑證鏈） | 信任清單 | 走哪一節 |
|---|---|---|---|---|---|
| 不動 | 不動 | 到期前換發 | 不動 | 不動 | 20.2 |
| 同私鑰續簽 | 不動 | 不動 | 不動 | 加入新根，舊的到期後再移除 | 只做 20.3 的信任清單那幾步（加入、移除） |
| 不動 | 同私鑰續簽 | 不動 | **換成新中繼** | 不動 | 20.4 的換鏈（20.4.3、20.4.4；不用 CSR） |
| 不動 | 換私鑰 | **重簽** | 重簽時一起換（銀行回覆就是新 leaf＋新中繼） | 不動 | 20.2（銀行用新中繼簽） |
| 同私鑰續簽 | 同私鑰續簽 | 不動 | **換成新中繼** | 加入新根，舊的到期後再移除 | 信任清單加入新根，再做 20.4 的換鏈 |
| 同私鑰續簽 | 換私鑰 | **重簽** | 重簽時一起換 | 加入新根，舊的到期後再移除 | 信任清單加入新根，再做 20.2 |
| 換私鑰 | 同私鑰，由新根重簽 | 不動 | **換成新中繼** | **三階段** | 20.4（三階段，階段二是換鏈；lab 實跑） |
| 換私鑰 | 換私鑰 | **重簽** | 重簽時一起換 | **三階段** | 20.3（lab 實跑） |

「重簽」和「換鏈」的差別：中繼換了私鑰，leaf 一定要重簽，銀行回覆的 PEM 本來就是新 leaf＋新中繼，做 keystore 時一起包進去，不用另外換鏈；只有中繼**沒換私鑰**、leaf 不重簽時，才需要單獨把新中繼重包進 p12（20.4）。根「同私鑰續簽」的兩列，舊根和新根的名稱與公鑰都相同，舊鏈新鏈都驗得過，信任清單加入新根只是為了舊根到期之後還有一張有效的根。

我方的信任清單只放根憑證、不放中繼，所以只要根沒換私鑰，信任清單都不用動；換鏈的過程中，出示舊鏈和新鏈的主機可以並存。只有把中繼本身放進信任清單的應用程式，才要新舊中繼並存。

比對「名稱與私鑰有沒有換」：拿銀行給的新舊兩張（根或中繼）各算一次公鑰雜湊與名稱，名稱相同、雜湊相同就是續簽：

```
for f in old-ca.pem new-ca.pem; do echo "$f: $(openssl x509 -in $f -noout -subject -nameopt compat | sed 's/subject=//')  key=$(openssl x509 -in $f -noout -pubkey | sha256sum | cut -c1-12)  到期 $(openssl x509 -in $f -noout -enddate | cut -d= -f2)"; done
```

> 實測（2026-10-24，openssl，用 lab 的模擬 CA）：同私鑰續簽的根、同私鑰續簽的中繼、兩者同時，舊 leaf 全部驗得過；根換私鑰而中繼沿用私鑰、由新根重簽時，舊 leaf 配新中繼驗得過新根，但**還沒換鏈的主機（舊 leaf 配舊中繼）在只信新根之後就驗不過**，所以三階段的「拿掉舊根」一定排在每個端點都換好鏈之後。Java 的驗證原理相同，沒有另外實測。

## 20.1 現在用的是哪一張

@role 小安 | ops02 | root

**這一節在做什麼**：換發前後各跑一次的對照。先看每張憑證的序號、剩幾天，以及各服務**實際出示**的是哪一張（換完之後用同一條指令確認每個端點都換到了）：

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

## 20.2 換發 leaf（同一個 CA）

**這一節在做什麼**：每年的例行換發。流程五步：產生新私鑰與 CSR（20.2.1）→ 銀行簽發（20.2.2）→ 檢查並做成新 keystore（20.2.3）→ 派送並滾動重啟（20.2.4）→ 確認都換好後替換正本（20.2.5）。新舊憑證在滾動期間都被信任，所以不會斷線；到 20.2.5 之前隨時可以放棄，舊的都還在原位。

### 20.2.1 新私鑰與 CSR

@role 小安 | ops02 | root

照第 9 章的 `requests.txt`（名稱、EKU、SAN 不變），每張產生新私鑰與 CSR，放 `~/pki/next/`：

```bash
install -d -m 0700 ~/pki/next ~/pki/next/keys ~/pki/next/requests ~/pki/next/incoming ~/pki/next/certs && cd ~/pki && while read -r name eku san; do (umask 077; openssl genrsa -out next/keys/$name.key 2048 2>/dev/null); ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku"); [ "$san" != "-" ] && ext+=(-addext "subjectAltName=$(echo "$san" | tr ',' '\n' | sed 's/^/DNS:/' | paste -sd, -)"); openssl req -new -key next/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" "${ext[@]}" -out next/requests/$name.csr && echo "$name: csr ok"; done < requests.txt
```

```out
kafka-internal: csr ok
（9 行）
```

### 20.2.2 銀行 CA 簽發

@role 銀行 CA 窗口 | Windows 終端 | 本機

和 9.2 一樣，只是從 `next/` 拿、放回 `next/`：

```bash
cd ~/kafka-lab && rm -rf ca/exchange/next && mkdir -p ca/exchange/next/signed && docker cp lab-ops02-1:/root/pki/next/requests "$(cygpath -m "$PWD/ca/exchange/next/")" && for f in ca/exchange/next/requests/*.csr; do n=$(basename $f .csr); bash ca/sign.sh "$f" "ca/exchange/next/signed/$n.crt"; done && for f in ca/exchange/next/signed/*.crt; do docker cp "$(cygpath -m "$f")" lab-ops02-1:/root/pki/next/incoming/; done && docker exec lab-ops02-1 bash -c 'ls /root/pki/next/incoming | wc -l'
```

```out
signed app-legacy-billing.csr -> app-legacy-billing.crt  (CN = app-legacy-billing, O = PoC Bank, C = TW; EKU clientAuth)
（9 行）
9
```

### 20.2.3 檢查、做成 keystore

@role 小安 | ops02 | root

拆 leaf 與中繼、五項檢查加憑證鏈（和 9.3 同一套），多印一欄簽發者，換 CA 時用得到：

```bash
cd ~/pki/next && for n in $(awk '{print $1}' ../requests.txt); do awk -v n=$n 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("incoming/" n ".part" c)}' incoming/$n.crt; mv incoming/$n.part1 incoming/$n.leaf.pem; cat incoming/$n.part[2-9] > incoming/$n.issuers.pem 2>/dev/null; rm -f incoming/$n.part*; done; while read -r name eku san; do leaf=incoming/$name.leaf.pem; k1=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16); k2=$(openssl pkey -in keys/$name.key -pubout 2>/dev/null | sha256sum | cut -c1-16); cn=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); have_san=$(openssl x509 -in $leaf -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,); want_san=$([ "$san" = "-" ] && echo "" || echo "$san" | tr ',' '\n' | sort | paste -sd,); have_eku=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' '); days=$(( ($(date -d "$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )); chain=$(openssl verify -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem -untrusted incoming/$name.issuers.pem $leaf 2>&1 | grep -c ": OK"); issuer=$(openssl x509 -in $leaf -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); printf '%-19s key=%s cn=%s san=%s days=%s chain=%s issuer=%s\n' $name $([ $k1 = $k2 ] && echo ok || echo MISMATCH) $([ "$cn" = "$name" ] && echo ok || echo "$cn") $([ "$have_san" = "$want_san" ] && echo ok || echo DIFF) $days $([ $chain = 1 ] && echo ok || echo FAIL) "$issuer"; done < ../requests.txt
```

```out
kafka-internal      key=ok cn=ok san=ok days=364 chain=ok issuer=PoC Bank Issuing CA 01
（9 行，全部 ok）
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

### 20.2.4 派送、滾動重啟

@role 小安 | ops02 | root

| 主機 | 換哪些檔 | 重啟 |
|---|---|---|
| controller | kafka-internal.p12 | confluent-server |
| broker | kafka-internal.p12、cp-server.p12 | confluent-server（JMX exporter 一起） |
| REST Proxy | cp-server.p12、svc-rest.p12 | confluent-kafka-rest |
| C3 | cp-server.p12、cp-server.crt／.key、c3-monitoring.p12、c3-monitoring.crt／.key、svc-c3.p12 | prometheus、alertmanager、confluent-control-center |

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
cd ~/pki/next && NEW_SRV=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2) && served() { openssl s_client -connect $1 -servername ${1%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; } && scp -q certs/cp-server.p12 certs/cp-server.crt keys/cp-server.key certs/c3-monitoring.p12 certs/c3-monitoring.crt keys/c3-monitoring.key certs/svc-c3.p12 c3-01.poc.lab:/tmp/ && ssh c3-01.poc.lab 'for f in cp-server.p12 cp-server.crt cp-server.key c3-monitoring.p12 c3-monitoring.crt c3-monitoring.key svc-c3.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/cp-server.* /tmp/c3-monitoring.* /tmp/svc-c3.p12; for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) 9021=$([ "$(served c3-01.poc.lab:9021)" = $NEW_SRV ] && echo new || echo OLD) 9090=$([ "$(served c3-01.poc.lab:9090)" = $NEW_SRV ] && echo new || echo OLD)"
```

```out
c3-01 UI=200 9021=new 9090=new
```


@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

REST Proxy 照 12.1 一台一台換：新的 `cp-server.p12`、`svc-rest.p12` 複製過去、裝好再重啟。

```bash
cd ~/pki/next && ~/conf/rest-restart.sh rest01 -c "certs/cp-server.p12 certs/svc-rest.p12" -b 'for f in cp-server.p12 svc-rest.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12'
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
cd ~/pki/next && ~/conf/rest-restart.sh rest02 -c "certs/cp-server.p12 certs/svc-rest.p12" -b 'for f in cp-server.p12 svc-rest.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12'
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

確認兩台 REST 都出示新憑證：

```bash
cd ~/pki/next && NEW_SRV=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2) && served() { openssl s_client -connect $1 -servername ${1%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; } && for h in rest01 rest02; do echo "$h 8082=$([ "$(served $h.poc.lab:8082)" = $NEW_SRV ] && echo new || echo OLD)"; done
```

```out
rest01 8082=new
rest02 8082=new
```

### 20.2.5 換成正本、交出去的那幾張

@role 小安 | ops02 | root

舊的整份留到 `~/pki/old-<日期時間>/`，新的放回正本位置。操作機自己用的 `svc-ops`、`kafka-internal`（管理 client、quorum 查詢）換成新的之後馬上試一次；緊急身分 `opmenu-breakglass` 要更新保管庫裡那份；`app-legacy-billing` 是應用程式的憑證，**交給應用程式團隊在他們的時段換**（舊的到期前都還有效）：

```bash
cd ~/pki && OLD=old-$(date +%Y%m%d-%H%M) && install -d -m 0700 $OLD/keys $OLD/certs && for n in $(awk '{print $1}' requests.txt); do mv keys/$n.key $OLD/keys/; mv certs/$n.crt certs/$n.p12 $OLD/certs/; install -m 0600 next/keys/$n.key keys/; install -m 0644 next/certs/$n.crt certs/; install -m 0600 next/certs/$n.p12 certs/; done && rm -rf next && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && echo "svc-ops 管理 client：$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list 2>/dev/null | wc -l) 個 topic" && echo "kafka-internal 查 quorum：$(kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status 2>/dev/null | grep -o 'LeaderId: *[0-9]*')" && echo "新的 app-legacy-billing（交給應用程式團隊）：REST=$(curl -s --cert certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)；舊的（還在效期內）：REST=$(curl -s --cert $OLD/certs/app-legacy-billing.crt --key $OLD/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)"
```

```out
svc-ops 管理 client：14 個 topic
kafka-internal 查 quorum：LeaderId: 1
新的 app-legacy-billing（交給應用程式團隊）：REST=200；舊的（還在效期內）：REST=200
```

緊急身分的 PEM 換了，保管庫裡那份也要換（舊的到期前都還有效）：


@role 銀行 Secrets 團隊（更新 PVWA 的 opmenu-breakglass；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && cp -p pvwa/opmenu-breakglass.pem pvwa/opmenu-breakglass.prev.pem 2>/dev/null; (umask 077; docker exec lab-ops02-1 bash -c 'cat /root/pki/keys/opmenu-breakglass.key /root/pki/certs/opmenu-breakglass.crt' > pvwa/opmenu-breakglass.pem) && echo "PVWA opmenu-breakglass 已更新，序號末 8 碼 $(openssl x509 -in pvwa/opmenu-breakglass.pem -noout -serial | tail -c 9)"
```

```out
PVWA opmenu-breakglass 已更新，序號末 8 碼 …
```


最後用 20.1 的指令再看一次：每個端點的序號都要是新的。

## 20.3 換 CA（三階段）


**這一節在做什麼**：銀行換了根憑證（新私鑰）、或換了簽發 CA 時的做法。名詞：根憑證（root）是信任的起點，簽發 CA（中繼）用它簽 leaf；lab 裡原本的根是 0.5.5 建的，20.3 換成的新 CA 叫 G2，20.4 再換成的叫 G3。

**不可逆的點**：階段三「拿掉舊根」之後，凡是還出示舊 CA 簽的憑證的，一律被拒，要退回只能重新加回舊根。所以階段二的每個端點（含銀行的 AD、套件庫，以及應用程式的憑證）都確認換好之後，才進階段三。

銀行換根憑證（或換簽發 CA）時，不能一次全換：只要有一台還不信新的根，它就會拒絕新憑證。三個階段，每段結束時所有元件都同時信任新舊兩個根：

| 階段 | 誰做 | 做什麼 | 之後的狀態 |
|---|---|---|---|
| 一、加 | 銀行 OS 團隊＋小安 | 信任清單加入新根（OS 的 `bank-root.pem` 變成兩張根的 bundle、truststore 多一個 alias、C3 的 ca.pem） | 新舊都信；憑證還是舊 CA 簽的 |
| 二、換 | 銀行 CA＋小安 | 銀行用新 CA 重簽自己的伺服器（AD、套件庫）；小安照 20.2 換發全部 leaf，改由新 CA 簽 | 新舊都信；憑證都是新 CA 簽的 |
| 三、退 | 銀行 OS 團隊＋小安 | 信任清單拿掉舊根 | 只信新的；舊 CA 簽的一律被拒 |

### 20.3.1 銀行建新 CA（lab 模擬）

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

### 20.3.2 階段一：信任清單加入新根

@role 銀行 OS 團隊 | Windows 終端 | 本機

每台主機（含操作機）的 `bank-root.pem` 換成「舊根＋新根」兩張的 bundle。檔名不變，所以所有指向它的設定（curl、操作機上的檢查）都不用改：

```bash
cd ~/kafka-lab/ca && cat root.crt g2/root.crt > bundle-g1-g2.pem && for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker cp "$(cygpath -m "$PWD/bundle-g1-g2.pem")" lab-$h-1:/root/bank-root.pem && docker exec lab-$h-1 bash -c 'install -m 0644 /root/bank-root.pem /etc/pki/ca-trust/source/anchors/bank-root.pem && rm -f /root/bank-root.pem && update-ca-trust && printf "%s:%s " $(hostname) $(grep -c "BEGIN CERT" /etc/pki/ca-trust/source/anchors/bank-root.pem)'; done; echo
```

```out
ops02:2 kc01:2 kc02:2 kc03:2 kb01:2 kb02:2 kb03:2 kb04:2 rest01:2 rest02:2 c3-01:2
```

@role 小安 | ops02 | root

先寫一支滾動重啟的小腳本，三個階段都會用（controller → broker → REST → C3，一台健康了才做下一台）：

```bash
cat > ~/conf/rolling-restart.sh <<'EOF'
#!/usr/bin/env bash
# 依序滾動重啟：controller → broker → C3；一台健康了才做下一台。REST Proxy 不在這裡：照 12.1 一台一台先從 LB 停用再重啟
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
ssh c3-01.poc.lab 'for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done'
for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done
echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"
EOF
chmod 0700 ~/conf/rolling-restart.sh && echo rolling-restart.sh ok
```

我方的信任清單：truststore 加一個 alias `bank-root-g2`；C3 的 Prometheus／Alertmanager 用的 `ca.pem`、OP menu 的兩份也換成 bundle。派送、滾動重啟：


@role 小安 | ops02 | root

```bash
cd ~/pki/certs && cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem && csplit -s -z -f /tmp/root- bank-root.pem '/BEGIN CERT/' '{*}' && keytool -importcert -noprompt -alias bank-root-g2 -file /tmp/root-01 -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass >/dev/null 2>&1; rm -f /tmp/root-*; echo "truststore：$(keytool -list -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | paste -sd' ')" && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q truststore.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/ && rm -f /tmp/truststore.p12'; done && scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem && ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem && rm -f /tmp/ca.pem' && install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12 && install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem && bash ~/conf/rolling-restart.sh
```

```out
truststore：bank-root bank-root-g2
kc01 active
（3 行）
kb01 MDS=200
（4 行）
c3-01 UI=200
```


REST Proxy 照 12.1 一台一台重啟：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

> 行內 Prometheus 抓 JMX exporter 用的 `ca.pem`（17.5 節交給銀行的那份）也要由監控團隊換成 bundle，否則階段二換完憑證就抓不到。

### 20.3.3 階段二：全部改由新 CA 簽

@role 銀行 CA 窗口 | Windows 終端 | 本機

銀行先用 G2 重簽自己的伺服器：AD 的 LDAPS、套件庫。私鑰沿用（銀行的事，lab 簡化），重啟讓它們出示新憑證：

```bash
cd ~/kafka-lab && docker cp lab-ad01-1:/root/csr/ad01.csr "$(cygpath -m "$PWD/ca/exchange/ad01-g2.csr")" && bash ca/g2/sign.sh ca/exchange/ad01-g2.csr ca/exchange/ad01-g2.crt && docker cp "$(cygpath -m "$PWD/ca/exchange/ad01-g2.crt")" lab-ad01-1:/var/lib/samba/private/tls/cert.pem && docker cp "$(cygpath -m "$PWD/ca/bundle-g1-g2.pem")" lab-ad01-1:/var/lib/samba/private/tls/ca.pem && docker exec lab-ad01-1 bash -c 'chmod 644 /var/lib/samba/private/tls/cert.pem /var/lib/samba/private/tls/ca.pem; pkill -x samba; sleep 8' && O="$(cygpath -m "$PWD/images/web/tls")" && openssl req -new -key "$O/repo.key" -out "$O/repo-g2.csr" -subj "/CN=repo01.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:repo01.poc.lab,DNS:repo01" -addext "extendedKeyUsage=serverAuth" 2>/dev/null && bash ca/g2/sign.sh images/web/tls/repo-g2.csr images/web/tls/repo.crt && rm -f images/web/tls/repo-g2.csr && docker exec lab-repo01-1 systemctl restart httpd && for ep in ad01.poc.lab:636 repo01.poc.lab:443; do echo "$ep $(docker exec lab-ops02-1 bash -c "openssl s_client -connect $ep </dev/null 2>/dev/null | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'")"; done
```

```out
signed ad01-g2.csr -> ad01-g2.crt  (CN = ad01.poc.lab, O = PoC Bank, C = TW; EKU serverAuth)
signed repo-g2.csr -> repo.crt  (…)
ad01.poc.lab:636 PoC Bank Issuing CA G2
repo01.poc.lab:443 PoC Bank Issuing CA G2
```


@role 小安 | ops02 | root

接著我方的每一張憑證都要改由 G2 簽：**把 20.2.1 到 20.2.5 整個再做一次**，唯一的差別是銀行改用 `ca/g2/sign.sh`。下面照順序列出同一組指令（`chain=ok` 是對 bundle 驗的，新根在裡面）：

**20.2.1 新私鑰與 CSR**

```bash
install -d -m 0700 ~/pki/next ~/pki/next/keys ~/pki/next/requests ~/pki/next/incoming ~/pki/next/certs && cd ~/pki && while read -r name eku san; do (umask 077; openssl genrsa -out next/keys/$name.key 2048 2>/dev/null); ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$eku"); [ "$san" != "-" ] && ext+=(-addext "subjectAltName=$(echo "$san" | tr ',' '\n' | sed 's/^/DNS:/' | paste -sd, -)"); openssl req -new -key next/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" "${ext[@]}" -out next/requests/$name.csr && echo "$name: csr ok"; done < requests.txt
```

```out
kafka-internal: csr ok
（9 行）
```

**20.2.2 銀行改用 G2 簽**

@role 銀行 CA 窗口 | Windows 終端 | 本機

```bash
cd ~/kafka-lab && rm -rf ca/exchange/next && mkdir -p ca/exchange/next/signed && docker cp lab-ops02-1:/root/pki/next/requests "$(cygpath -m "$PWD/ca/exchange/next/")" && for f in ca/exchange/next/requests/*.csr; do n=$(basename $f .csr); bash ca/g2/sign.sh "$f" "ca/exchange/next/signed/$n.crt"; done && for f in ca/exchange/next/signed/*.crt; do docker cp "$(cygpath -m "$f")" lab-ops02-1:/root/pki/next/incoming/; done && docker exec lab-ops02-1 bash -c 'ls /root/pki/next/incoming | wc -l'
```

```out
signed app-legacy-billing.csr -> app-legacy-billing.crt  (CN = app-legacy-billing, O = PoC Bank, C = TW; EKU clientAuth)
（9 行）
9
```

**20.2.3 檢查（issuer 要是 G2）**

@role 小安 | ops02 | root

```bash
cd ~/pki/next && for n in $(awk '{print $1}' ../requests.txt); do awk -v n=$n 'BEGIN{c=0} /BEGIN CERT/{c++} {print > ("incoming/" n ".part" c)}' incoming/$n.crt; mv incoming/$n.part1 incoming/$n.leaf.pem; cat incoming/$n.part[2-9] > incoming/$n.issuers.pem 2>/dev/null; rm -f incoming/$n.part*; done; while read -r name eku san; do leaf=incoming/$name.leaf.pem; k1=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16); k2=$(openssl pkey -in keys/$name.key -pubout 2>/dev/null | sha256sum | cut -c1-16); cn=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); have_san=$(openssl x509 -in $leaf -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | tr ',' '\n' | sort | paste -sd,); want_san=$([ "$san" = "-" ] && echo "" || echo "$san" | tr ',' '\n' | sort | paste -sd,); have_eku=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' '); days=$(( ($(date -d "$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )); chain=$(openssl verify -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem -untrusted incoming/$name.issuers.pem $leaf 2>&1 | grep -c ": OK"); issuer=$(openssl x509 -in $leaf -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'); printf '%-19s key=%s cn=%s san=%s days=%s chain=%s issuer=%s\n' $name $([ $k1 = $k2 ] && echo ok || echo MISMATCH) $([ "$cn" = "$name" ] && echo ok || echo "$cn") $([ "$have_san" = "$want_san" ] && echo ok || echo DIFF) $days $([ $chain = 1 ] && echo ok || echo FAIL) "$issuer"; done < ../requests.txt
```

```out
kafka-internal      key=ok cn=ok san=ok days=364 chain=ok issuer=PoC Bank Issuing CA G2
（9 行，全部 ok）
```

**20.2.3 做成 keystore**

```bash
cd ~/pki/next && for n in $(awk '{print $1}' ../requests.txt); do cat incoming/$n.leaf.pem incoming/$n.issuers.pem > certs/$n.crt; openssl pkcs12 -export -name $n -inkey keys/$n.key -in certs/$n.crt -out certs/$n.p12 -passout file:../store.pass && chmod 0600 certs/$n.p12; done; ls certs | wc -l; for n in kafka-internal cp-server; do echo "$n: old=$(openssl x509 -in ../certs/$n.crt -noout -serial | tail -c 9) new=$(openssl x509 -in certs/$n.crt -noout -serial | tail -c 9)"; done
```

```out
14
kafka-internal: old=F343BC55 new=F343BC5D
cp-server: old=F343BC54 new=F343BC5C
```

**20.2.4 派送、滾動重啟 controller 與 broker**

```bash
cd ~/pki/next && NEW_INT=$(openssl x509 -in certs/kafka-internal.crt -noout -serial | cut -d= -f2) NEW_SRV=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2) && served() { openssl s_client -connect $1 -servername ${1%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; } && for h in kc01 kc02 kc03; do scp -q certs/kafka-internal.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/kafka-internal.p12 /etc/confluent/ssl/ && rm -f /tmp/kafka-internal.p12 && sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done'; for i in $(seq 1 30); do [ "$(served $h.poc.lab:9093)" = $NEW_INT ] && break; sleep 2; done; echo "$h $(ssh $h.poc.lab systemctl is-active confluent-server) 9093=$([ "$(served $h.poc.lab:9093)" = $NEW_INT ] && echo new || echo OLD)"; done; for h in kb01 kb02 kb03 kb04; do scp -q certs/kafka-internal.p12 certs/cp-server.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'for f in kafka-internal.p12 cp-server.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12; sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) 9092=$([ "$(served $h.poc.lab:9092)" = $NEW_INT ] && echo new || echo OLD) 9095=$([ "$(served $h.poc.lab:9095)" = $NEW_SRV ] && echo new || echo OLD)"; done
```

```out
kc01 active 9093=new
（3 行）
kb01 MDS=200 9092=new 9095=new
（4 行）
```

**20.2.4 REST Proxy 與 C3**

```bash
cd ~/pki/next && NEW_SRV=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2) && served() { openssl s_client -connect $1 -servername ${1%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; } && scp -q certs/cp-server.p12 certs/cp-server.crt keys/cp-server.key certs/c3-monitoring.p12 certs/c3-monitoring.crt keys/c3-monitoring.key certs/svc-c3.p12 c3-01.poc.lab:/tmp/ && ssh c3-01.poc.lab 'for f in cp-server.p12 cp-server.crt cp-server.key c3-monitoring.p12 c3-monitoring.crt c3-monitoring.key svc-c3.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/cp-server.* /tmp/c3-monitoring.* /tmp/svc-c3.p12; for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) 9021=$([ "$(served c3-01.poc.lab:9021)" = $NEW_SRV ] && echo new || echo OLD) 9090=$([ "$(served c3-01.poc.lab:9090)" = $NEW_SRV ] && echo new || echo OLD)"
```

```out
c3-01 UI=200 9021=new 9090=new
```


@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

REST Proxy 照 12.1 一台一台換：新的 `cp-server.p12`、`svc-rest.p12` 複製過去、裝好再重啟。

```bash
cd ~/pki/next && ~/conf/rest-restart.sh rest01 -c "certs/cp-server.p12 certs/svc-rest.p12" -b 'for f in cp-server.p12 svc-rest.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12'
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
cd ~/pki/next && ~/conf/rest-restart.sh rest02 -c "certs/cp-server.p12 certs/svc-rest.p12" -b 'for f in cp-server.p12 svc-rest.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12'
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

確認兩台 REST 都出示新憑證：

```bash
cd ~/pki/next && NEW_SRV=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2) && served() { openssl s_client -connect $1 -servername ${1%:*} </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2; } && for h in rest01 rest02; do echo "$h 8082=$([ "$(served $h.poc.lab:8082)" = $NEW_SRV ] && echo new || echo OLD)"; done
```

```out
rest01 8082=new
rest02 8082=new
```

**20.2.5 換成正本**

```bash
cd ~/pki && OLD=old-$(date +%Y%m%d-%H%M) && install -d -m 0700 $OLD/keys $OLD/certs && for n in $(awk '{print $1}' requests.txt); do mv keys/$n.key $OLD/keys/; mv certs/$n.crt certs/$n.p12 $OLD/certs/; install -m 0600 next/keys/$n.key keys/; install -m 0644 next/certs/$n.crt certs/; install -m 0600 next/certs/$n.p12 certs/; done && rm -rf next && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && echo "svc-ops 管理 client：$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list 2>/dev/null | wc -l) 個 topic" && echo "kafka-internal 查 quorum：$(kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status 2>/dev/null | grep -o 'LeaderId: *[0-9]*')" && echo "新的 app-legacy-billing（交給應用程式團隊）：REST=$(curl -s --cert certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)；舊的（還在效期內）：REST=$(curl -s --cert $OLD/certs/app-legacy-billing.crt --key $OLD/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)"
```

```out
svc-ops 管理 client：14 個 topic
kafka-internal 查 quorum：LeaderId: 1
新的 app-legacy-billing（交給應用程式團隊）：REST=200；舊的（還在效期內）：REST=200
```

緊急身分的 PEM 換了，保管庫裡那份也要換（舊的到期前都還有效）：


@role 銀行 Secrets 團隊（更新 PVWA 的 opmenu-breakglass；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && cp -p pvwa/opmenu-breakglass.pem pvwa/opmenu-breakglass.prev.pem 2>/dev/null; (umask 077; docker exec lab-ops02-1 bash -c 'cat /root/pki/keys/opmenu-breakglass.key /root/pki/certs/opmenu-breakglass.crt' > pvwa/opmenu-breakglass.pem) && echo "PVWA opmenu-breakglass 已更新，序號末 8 碼 $(openssl x509 -in pvwa/opmenu-breakglass.pem -noout -serial | tail -c 9)"
```

```out
PVWA opmenu-breakglass 已更新，序號末 8 碼 …
```


> 陷阱：這一段**一定要做完才能進階段三**。只有銀行的伺服器換成 G2、我方的 leaf 還是舊 CA 簽的就拿掉舊根，broker 驗不過 controller 的憑證，整個叢集起不來（lab 實際發生過：broker 一直重啟、MDS 不回應）。

最後確認每個端點出示的都是 G2 簽的憑證，全部是才往下：

@role 小安 | ops02 | root

```bash
bad=0; for ep in kc01.poc.lab:9093 kc02.poc.lab:9093 kc03.poc.lab:9093 kb01.poc.lab:9092 kb02.poc.lab:9092 kb03.poc.lab:9092 kb04.poc.lab:9092 kb01.poc.lab:9095 kb01.poc.lab:8090 rest01.poc.lab:8082 rest02.poc.lab:8082 c3-01.poc.lab:9021 c3-01.poc.lab:9090; do i=$(openssl s_client -connect $ep </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/.*CN *= *//; s/,.*//'); [ "$i" = "PoC Bank Issuing CA G2" ] || { echo "$ep 出示的是：${i:-（沒有回應）}"; bad=1; }; done; [ $bad = 0 ] && echo "13 個端點都是 G2 簽的：可以進階段三"
```

```out
13 個端點都是 G2 簽的：可以進階段三
```

### 20.3.4 階段三：拿掉舊根

@role 銀行 OS 團隊 | Windows 終端 | 本機

```bash
cd ~/kafka-lab/ca && for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker cp "$(cygpath -m "$PWD/g2/root.crt")" lab-$h-1:/root/bank-root.pem && docker exec lab-$h-1 bash -c 'install -m 0644 /root/bank-root.pem /etc/pki/ca-trust/source/anchors/bank-root.pem && rm -f /root/bank-root.pem && update-ca-trust && printf "%s:%s " $(hostname) $(grep -c "BEGIN CERT" /etc/pki/ca-trust/source/anchors/bank-root.pem)'; done; echo; docker cp "$(cygpath -m "$PWD/g2/root.crt")" lab-ad01-1:/var/lib/samba/private/tls/ca.pem
```

```out
ops02:1 kc01:1 kc02:1 kc03:1 kb01:1 kb02:1 kb03:1 kb04:1 rest01:1 rest02:1 c3-01:1
```

@role 小安 | ops02 | root

truststore 拿掉舊的 alias、C3 與 OP menu 的 ca.pem 只留新根，派送、滾動重啟：


@role 小安 | ops02 | root

```bash
cd ~/pki/certs && cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem && keytool -delete -alias bank-root -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass && echo "truststore：$(keytool -list -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | paste -sd' ')" && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q truststore.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/ && rm -f /tmp/truststore.p12'; done && scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem && ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem && rm -f /tmp/ca.pem' && install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12 && install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem && bash ~/conf/rolling-restart.sh
```

```out
truststore：bank-root-g2
kc01 active
（滾動重啟 8 行，全部健康；REST Proxy 在下面另外做）
c3-01 UI=200
```


REST Proxy 照 12.1 一台一台重啟：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

最後反向驗證：舊 CA 簽的憑證（20.2 第一次換發留在 `old-` 底下的那張應用程式憑證）連 REST Proxy 要被拒；新的要能用；AD、套件庫照常（它們在階段二已經換成 G2）：

```bash
cd ~/pki && OLDEST=$(ls -d old-* | head -1) && echo "舊 CA 簽的 app 憑證 → REST：$(curl -s --cert $OLDEST/certs/app-legacy-billing.crt --key $OLDEST/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)（000 = TLS 直接拒絕）" && echo "新 CA 簽的 app 憑證 → REST：$(curl -s --cert certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)" && echo "alice 登入 MDS（MDS 要用 LDAPS 連 AD）：$(curl -s -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)" && echo "套件庫：$(curl -s -o /dev/null -w '%{http_code}' https://repo01.poc.lab/confluent/repodata/repomd.xml)"
```

```out
舊 CA 簽的 app 憑證 → REST：000（000 = TLS 直接拒絕）
新 CA 簽的 app 憑證 → REST：200
alice 登入 MDS（MDS 要用 LDAPS 連 AD）：200
套件庫：200
```


> 階段三之前要確認：應用程式團隊已經換上新 CA 簽的憑證（REST 走 mTLS 的那些）、行內 Prometheus 與應用程式的 truststore 都已經有新根。否則拿掉舊根的那一刻，它們就斷了。

## 20.4 換鏈：中繼沒換私鑰，只換憑證鏈

**這一節在做什麼**：處理 20.0 表裡「中繼沿用私鑰」的情況，只換 p12 裡夾帶的憑證鏈，不重簽 leaf。這一節是最複雜的一種，只有銀行明確說是這種情況才需要。20.0 表裡「中繼沿用私鑰」的那幾列：leaf 不用重簽（簽它的私鑰沒變），但每個 p12 裡夾帶的中繼要換成銀行給的新那張。不用 CSR、不用銀行簽任何東西，只是把「現在的 leaf＋新中繼」重新包成 p12、派送、滾動重啟。

這一節演練最麻煩的那一列：**銀行換根（G3，新私鑰），中繼 G2 沿用私鑰、由 G3 重簽**。信任清單一樣走三階段，階段二從「重簽 leaf」換成「換鏈」。只有中繼續簽、根不動的情況（表的第 3 列），跳過 20.4.2 和 20.4.5，只做 20.4.3、20.4.4。

| 階段 | 做什麼 | 之後的狀態 |
|---|---|---|
| 一、加 | 信任清單加入 G3 | G2、G3 都信；大家出示的還是舊鏈（中繼由 G2 簽） |
| 二、換鏈 | 銀行的伺服器、我方每一張 p12 都換成新鏈（中繼由 G3 簽） | 兩個根都信；出示的都是新鏈 |
| 三、退 | 信任清單拿掉 G2 | 只信 G3；還出示舊鏈的一律被拒 |

> 陷阱：舊鏈和新鏈的 leaf **是同一張**（同序號、同私鑰），所以 20.1 看序號分不出誰換好了。這一節改看端點出示的**第二張（中繼）是誰簽的**。

### 20.4.1 銀行建 G3、用 G3 重簽中繼（lab 模擬）

@role 銀行 CA 窗口 | Windows 終端 | 本機

新根 G3 用新私鑰；中繼沿用 G2 中繼的私鑰與名稱，改由 G3 簽。新的中繼先放 `g2/issuing-g3.crt`，階段二才換成簽發腳本用的那張：

```bash
cd ~/kafka-lab/ca && mkdir -p g3 && cd g3 && openssl genrsa -out root.key 4096 2>/dev/null && openssl req -x509 -new -key root.key -sha256 -days 7300 -out root.crt -subj "/CN=PoC Bank Root CA G3/O=PoC Bank/C=TW" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" && cd ../g2 && openssl req -new -key issuing.key -sha256 -subj "/CN=PoC Bank Issuing CA G2/O=PoC Bank/C=TW" -out issuing-g3.csr && printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' > issuing.ext && openssl x509 -req -in issuing-g3.csr -CA ../g3/root.crt -CAkey ../g3/root.key -CAcreateserial -days 3650 -sha256 -extfile issuing.ext -out issuing-g3.crt 2>/dev/null && rm -f issuing-g3.csr issuing.ext && openssl verify -CAfile ../g3/root.crt issuing-g3.crt && for f in issuing.crt issuing-g3.crt; do echo "$f: $(openssl x509 -in $f -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')（簽發者 $(openssl x509 -in $f -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')）key=$(openssl x509 -in $f -noout -pubkey | sha256sum | cut -c1-12)"; done
```

```out
issuing-g3.crt: OK
issuing.crt: PoC Bank Issuing CA G2（簽發者 PoC Bank Root CA G2）key=…
issuing-g3.crt: PoC Bank Issuing CA G2（簽發者 PoC Bank Root CA G3）key=…（和上一行相同）
```

名稱相同、key 相同、簽發者不同：就是 20.0 表的「根換私鑰，中繼同私鑰由新根重簽」。

### 20.4.2 階段一：信任清單加入 G3

@role 銀行 OS 團隊 | Windows 終端 | 本機

和 20.3.2 一樣，bundle 換成 G2＋G3（AD 的 `ca.pem` 也一起）：

```bash
cd ~/kafka-lab/ca && cat g2/root.crt g3/root.crt > bundle-g2-g3.pem && for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker cp "$(cygpath -m "$PWD/bundle-g2-g3.pem")" lab-$h-1:/root/bank-root.pem && docker exec lab-$h-1 bash -c 'install -m 0644 /root/bank-root.pem /etc/pki/ca-trust/source/anchors/bank-root.pem && rm -f /root/bank-root.pem && update-ca-trust && printf "%s:%s " $(hostname) $(grep -c "BEGIN CERT" /etc/pki/ca-trust/source/anchors/bank-root.pem)'; done; echo; docker cp "$(cygpath -m "$PWD/bundle-g2-g3.pem")" lab-ad01-1:/var/lib/samba/private/tls/ca.pem && docker exec lab-ad01-1 chmod 644 /var/lib/samba/private/tls/ca.pem
```

```out
ops02:2 kc01:2 kc02:2 kc03:2 kb01:2 kb02:2 kb03:2 kb04:2 rest01:2 rest02:2 c3-01:2
```

@role 小安 | ops02 | root

truststore 加 alias `bank-root-g3`（bundle 的第二張），C3 與 OP menu 的 ca.pem 換成 bundle，派送、滾動重啟（20.3.2 寫的那支 `rolling-restart.sh`）：


@role 小安 | ops02 | root

```bash
cd ~/pki/certs && cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem && csplit -s -z -f /tmp/root- bank-root.pem '/BEGIN CERT/' '{*}' && keytool -importcert -noprompt -alias bank-root-g3 -file /tmp/root-01 -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass >/dev/null 2>&1; rm -f /tmp/root-*; echo "truststore：$(keytool -list -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | paste -sd' ')" && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q truststore.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/ && rm -f /tmp/truststore.p12'; done && scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem && ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem && rm -f /tmp/ca.pem' && install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12 && install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem && bash ~/conf/rolling-restart.sh
```

```out
truststore：bank-root-g2 bank-root-g3
kc01 active
（滾動重啟 8 行，全部健康；REST Proxy 在下面另外做）
c3-01 UI=200
```


REST Proxy 照 12.1 一台一台重啟：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

### 20.4.3 階段二之一：銀行換上新中繼，自己的伺服器換鏈

@role 銀行 CA 窗口 | Windows 終端 | 本機

簽發腳本改用新的中繼（之後簽的 leaf 都附新鏈）；AD、套件庫的憑證檔換成「原本的 leaf＋新中繼」，重啟；新中繼交給小安（放 `~/pki/bank-issuing-new.pem`）：

```bash
cd ~/kafka-lab && mv ca/g2/issuing.crt ca/g2/issuing-under-g2.crt && cp ca/g2/issuing-g3.crt ca/g2/issuing.crt && rechain() { awk '/BEGIN CERT/{n++} n==1' "$1" > "$1.new" && cat ca/g2/issuing.crt >> "$1.new" && mv "$1.new" "$1"; } && docker cp lab-ad01-1:/var/lib/samba/private/tls/cert.pem "$(cygpath -m "$PWD/ca/exchange/ad01-cert.pem")" && rechain ca/exchange/ad01-cert.pem && docker cp "$(cygpath -m "$PWD/ca/exchange/ad01-cert.pem")" lab-ad01-1:/var/lib/samba/private/tls/cert.pem && docker exec lab-ad01-1 bash -c 'chmod 644 /var/lib/samba/private/tls/cert.pem; pkill -x samba; sleep 8' && rechain images/web/tls/repo.crt && docker exec lab-repo01-1 systemctl restart httpd && docker cp "$(cygpath -m "$PWD/ca/g2/issuing.crt")" lab-ops02-1:/root/pki/bank-issuing-new.pem && for ep in ad01.poc.lab:636 repo01.poc.lab:443; do echo "$ep 中繼的簽發者：$(docker exec lab-ops02-1 bash -c "openssl s_client -connect $ep -showcerts </dev/null 2>/dev/null | awk '/BEGIN CERT/{n++} n==2' | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'")"; done
```

```out
ad01.poc.lab:636 中繼的簽發者：PoC Bank Root CA G3
repo01.poc.lab:443 中繼的簽發者：PoC Bank Root CA G3
```


### 20.4.4 階段二之二：我方的每一張 p12 換鏈

@role 小安 | ops02 | root

先確認銀行給的真的是「同一個中繼、換了簽發者」（名稱、key 和現在 p12 裡的那張相同），再把每張「現在的 leaf＋新中繼」包成 p12，放 `~/pki/next/`。私鑰不動、keystore 密碼不動：

```bash
cd ~/pki && NEW=bank-issuing-new.pem && CUR=$(awk '/BEGIN CERT/{n++} n==2' certs/cp-server.crt) && cn() { openssl x509 -noout $1 -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/'; } && kh() { openssl x509 -noout -pubkey | sha256sum | cut -c1-12; } && echo "現在的中繼：$(cn -subject <<<"$CUR")（簽發者 $(cn -issuer <<<"$CUR")）key=$(kh <<<"$CUR")" && echo "新的中繼：  $(cn -subject < $NEW)（簽發者 $(cn -issuer < $NEW)）key=$(kh < $NEW)" && install -d -m 0700 next next/certs && for n in $(awk '{print $1}' requests.txt); do awk '/BEGIN CERT/{n++} n==1' certs/$n.crt > next/certs/$n.crt && cat $NEW >> next/certs/$n.crt && v=$(openssl verify -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem -untrusted $NEW next/certs/$n.crt 2>&1 | grep -c ': OK') && openssl pkcs12 -export -name $n -inkey keys/$n.key -in next/certs/$n.crt -out next/certs/$n.p12 -passout file:store.pass && chmod 0600 next/certs/$n.p12 && echo "$n: leaf=$(openssl x509 -in next/certs/$n.crt -noout -serial | tail -c 9)（不變） chain=$([ $v = 1 ] && echo ok || echo FAIL)"; done
```

```out
現在的中繼：PoC Bank Issuing CA G2（簽發者 PoC Bank Root CA G2）key=…
新的中繼：  PoC Bank Issuing CA G2（簽發者 PoC Bank Root CA G3）key=…（和上一行相同）
kafka-internal: leaf=7E8C05F2（不變） chain=ok
（9 行，全部 ok）
```

> 名稱或 key 不一樣，就不是換鏈：中繼換了私鑰，leaf 要重簽（走 20.2）。

派送與滾動重啟和 20.2.4 相同，只是確認的方式改成「端點出示的中繼是 G3 簽的」：

```bash
cd ~/pki/next && via() { openssl s_client -connect $1 -servername ${1%:*} -showcerts </dev/null 2>/dev/null | awk '/BEGIN CERT/{n++} n==2' | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2>/dev/null | sed 's/.*CN=\([^,]*\).*/\1/'; } && G3="PoC Bank Root CA G3" && for h in kc01 kc02 kc03; do scp -q certs/kafka-internal.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/kafka-internal.p12 /etc/confluent/ssl/ && rm -f /tmp/kafka-internal.p12 && sudo systemctl restart confluent-server; for i in $(seq 1 30); do systemctl is-active -q confluent-server && break; sleep 2; done'; for i in $(seq 1 30); do [ "$(via $h.poc.lab:9093)" = "$G3" ] && break; sleep 2; done; echo "$h $(ssh $h.poc.lab systemctl is-active confluent-server) 9093=$([ "$(via $h.poc.lab:9093)" = "$G3" ] && echo new || echo OLD)"; done; for h in kb01 kb02 kb03 kb04; do scp -q certs/kafka-internal.p12 certs/cp-server.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'for f in kafka-internal.p12 cp-server.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12; sudo systemctl restart confluent-server'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h MDS=$(curl -s -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) 9092=$([ "$(via $h.poc.lab:9092)" = "$G3" ] && echo new || echo OLD) 9095=$([ "$(via $h.poc.lab:9095)" = "$G3" ] && echo new || echo OLD)"; done
```

```out
kc01 active 9093=new
（3 行）
kb01 MDS=200 9092=new 9095=new
（4 行）
```

REST Proxy 與 C3（C3 的 `cp-server.key`、`c3-monitoring.key` 沒變，照樣一起放，指令和 20.2.4 一致）：

```bash
cd ~/pki/next && via() { openssl s_client -connect $1 -servername ${1%:*} -showcerts </dev/null 2>/dev/null | awk '/BEGIN CERT/{n++} n==2' | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2>/dev/null | sed 's/.*CN=\([^,]*\).*/\1/'; } && G3="PoC Bank Root CA G3" && scp -q certs/cp-server.p12 certs/cp-server.crt ../keys/cp-server.key certs/c3-monitoring.p12 certs/c3-monitoring.crt ../keys/c3-monitoring.key certs/svc-c3.p12 c3-01.poc.lab:/tmp/ && ssh c3-01.poc.lab 'for f in cp-server.p12 cp-server.crt cp-server.key c3-monitoring.p12 c3-monitoring.crt c3-monitoring.key svc-c3.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/cp-server.* /tmp/c3-monitoring.* /tmp/svc-c3.p12; for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done'; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) 9021=$([ "$(via c3-01.poc.lab:9021)" = "$G3" ] && echo new || echo OLD) 9090=$([ "$(via c3-01.poc.lab:9090)" = "$G3" ] && echo new || echo OLD)"
```

```out
c3-01 UI=200 9021=new 9090=new
```


@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

REST Proxy 照 12.1 一台一台換：新的 `cp-server.p12`、`svc-rest.p12` 複製過去、裝好再重啟。

```bash
cd ~/pki/next && ~/conf/rest-restart.sh rest01 -c "certs/cp-server.p12 certs/svc-rest.p12" -b 'for f in cp-server.p12 svc-rest.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12'
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
cd ~/pki/next && ~/conf/rest-restart.sh rest02 -c "certs/cp-server.p12 certs/svc-rest.p12" -b 'for f in cp-server.p12 svc-rest.p12; do sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/; done; rm -f /tmp/*.p12'
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

確認兩台 REST 都出示新憑證：

```bash
cd ~/pki/next && via() { openssl s_client -connect $1 -servername ${1%:*} -showcerts </dev/null 2>/dev/null | awk '/BEGIN CERT/{n++} n==2' | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2>/dev/null | sed 's/.*CN=\([^,]*\).*/\1/'; } && G3="PoC Bank Root CA G3" && for h in rest01 rest02; do echo "$h 8082=$([ "$(via $h.poc.lab:8082)" = "$G3" ] && echo new || echo OLD)"; done
```

```out
rest01 8082=new
rest02 8082=new
```

換成正本：私鑰不動，只換 `.crt`／`.p12`；舊的留在 `~/pki/old-<日期時間>/certs/`（階段三的反向驗證會用到）。緊急身分的 PEM 更新到保管庫；`app-legacy-billing` 的新 p12 交給應用程式團隊，**一定要在階段三之前換上**：

```bash
cd ~/pki && OLD=old-$(date +%Y%m%d-%H%M) && install -d -m 0700 $OLD/certs && for n in $(awk '{print $1}' requests.txt); do mv certs/$n.crt certs/$n.p12 $OLD/certs/; install -m 0644 next/certs/$n.crt certs/; install -m 0600 next/certs/$n.p12 certs/; done && rm -rf next && mv bank-issuing-new.pem $OLD/ && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && echo "svc-ops 管理 client：$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list 2>/dev/null | wc -l) 個 topic" && echo "kafka-internal 查 quorum：$(kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status 2>/dev/null | grep -o 'LeaderId: *[0-9]*')" && echo "app-legacy-billing 新鏈：REST=$(curl -s --cert certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)；舊鏈（G2 還信）：REST=$(curl -s --cert $OLD/certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)"
```

```out
svc-ops 管理 client：14 個 topic
kafka-internal 查 quorum：LeaderId: 1
app-legacy-billing 新鏈：REST=200；舊鏈（G2 還信）：REST=200
```

緊急身分的 PEM 換了，保管庫裡那份也要換（舊的到期前都還有效）：


@role 銀行 Secrets 團隊（更新 PVWA 的 opmenu-breakglass；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
cd ~/kafka-lab && cp -p pvwa/opmenu-breakglass.pem pvwa/opmenu-breakglass.prev.pem 2>/dev/null; (umask 077; docker exec lab-ops02-1 bash -c 'cat /root/pki/keys/opmenu-breakglass.key /root/pki/certs/opmenu-breakglass.crt' > pvwa/opmenu-breakglass.pem) && echo "PVWA opmenu-breakglass 已更新，序號末 8 碼 $(openssl x509 -in pvwa/opmenu-breakglass.pem -noout -serial | tail -c 9)"
```

```out
PVWA opmenu-breakglass 已更新，序號末 8 碼 …
```


進階段三之前，每個端點出示的中繼都要是 G3 簽的（銀行的三台也算）：

@role 小安 | ops02 | root

```bash
bad=0; for ep in kc01.poc.lab:9093 kc02.poc.lab:9093 kc03.poc.lab:9093 kb01.poc.lab:9092 kb02.poc.lab:9092 kb03.poc.lab:9092 kb04.poc.lab:9092 kb01.poc.lab:9095 kb01.poc.lab:8090 kb01.poc.lab:7071 kc01.poc.lab:7071 rest01.poc.lab:8082 rest02.poc.lab:8082 c3-01.poc.lab:9021 c3-01.poc.lab:9090 ad01.poc.lab:636 repo01.poc.lab:443; do i=$(openssl s_client -connect $ep -servername ${ep%:*} -showcerts </dev/null 2>/dev/null | awk '/BEGIN CERT/{n++} n==2' | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2>/dev/null | sed 's/.*CN=\([^,]*\).*/\1/'); [ "$i" = "PoC Bank Root CA G3" ] || { echo "$ep 中繼的簽發者：${i:-（沒有回應）}"; bad=1; }; done; [ $bad = 0 ] && echo "17 個端點都出示新鏈：可以進階段三"
```

```out
17 個端點都出示新鏈：可以進階段三
```


### 20.4.5 階段三：拿掉 G2

@role 銀行 OS 團隊 | Windows 終端 | 本機

```bash
cd ~/kafka-lab/ca && for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do docker cp "$(cygpath -m "$PWD/g3/root.crt")" lab-$h-1:/root/bank-root.pem && docker exec lab-$h-1 bash -c 'install -m 0644 /root/bank-root.pem /etc/pki/ca-trust/source/anchors/bank-root.pem && rm -f /root/bank-root.pem && update-ca-trust && printf "%s:%s " $(hostname) $(grep -c "BEGIN CERT" /etc/pki/ca-trust/source/anchors/bank-root.pem)'; done; echo; docker cp "$(cygpath -m "$PWD/g3/root.crt")" lab-ad01-1:/var/lib/samba/private/tls/ca.pem && docker exec lab-ad01-1 chmod 644 /var/lib/samba/private/tls/ca.pem
```

```out
ops02:1 kc01:1 kc02:1 kc03:1 kb01:1 kb02:1 kb03:1 kb04:1 rest01:1 rest02:1 c3-01:1
```

@role 小安 | ops02 | root

```bash
cd ~/pki/certs && cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem && keytool -delete -alias bank-root-g2 -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass && echo "truststore：$(keytool -list -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | paste -sd' ')" && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do scp -q truststore.p12 $h.poc.lab:/tmp/ && ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/ && rm -f /tmp/truststore.p12'; done && scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem && ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem && rm -f /tmp/ca.pem' && install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12 && install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem && bash ~/conf/rolling-restart.sh
```

```out
truststore：bank-root-g3
kc01 active
（滾動重啟 8 行，全部健康；REST Proxy 在下面另外做）
c3-01 UI=200
```


REST Proxy 照 12.1 一台一台重啟：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

反向驗證：**同一張 leaf、同一把私鑰**，配舊鏈（中繼由 G2 簽）要被拒，配新鏈要通過；AD、套件庫照常：

```bash
cd ~/pki && LAST=$(ls -d old-* | tail -1) && echo "舊鏈 → REST：$(curl -s --cert $LAST/certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)（000 = TLS 直接拒絕）" && echo "新鏈 → REST：$(curl -s --cert certs/app-legacy-billing.crt --key keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters)" && echo "alice 登入 MDS（MDS 要用 LDAPS 連 AD）：$(curl -s -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)" && echo "套件庫：$(curl -s -o /dev/null -w '%{http_code}' https://repo01.poc.lab/confluent/repodata/repomd.xml)"
```

```out
舊鏈 → REST：000（000 = TLS 直接拒絕）
新鏈 → REST：200
alice 登入 MDS（MDS 要用 LDAPS 連 AD）：200
套件庫：200
```


> 實測（2026-10-25，lab，接在 20.3 之後做）：三個階段 12 塊指令全部一次通過；換鏈期間 REST、MDS、C3 都維持 200，舊鏈與新鏈的應用程式憑證在階段二都能用，階段三之後舊鏈被拒。銀行端（Windows 的 openssl）算出的 key 雜湊和操作機算的不同，是 PEM 換行字元不同造成的，各自那一邊的兩行相同就對了。

> 這就是 20.0 說的「拿掉舊根一定排在每個端點都換好鏈之後」：舊鏈的 leaf 本身沒問題，被拒是因為它夾帶的中繼指向已經不信的 G2。應用程式（REST 走 mTLS 的那些）的 p12 也一樣要換鏈，否則階段三那一刻就斷。

# 21. 第二十一站：遷移到新版 Confluent 與 JDK

![upgrade]

下面這張圖把遷移每一節的先後排出來，並標出不能回頭的那一步。

![migrationflow]

安裝基底（第 1–20 章）裝的是 **Confluent Platform 8.2.4**、**Control Center 2.5.1**、**JDK 21**。這一章是主線的下一步：遷移到 **Confluent Platform 8.3.2**，C3 同時升到 **2.6.1**，並把 **JDK 21 換成 25**。順序和原因：

- **C3 先升**：原廠相容表上 C3 2.5.x 只支援到 CP 8.2.x，2.6.x 才支援到 8.3.x（2.6.x 的範圍是 7.5.15 到 8.3.x，所以 2.6.1 配著 8.2.4 也在支援範圍內）。CP 一升到 8.3，2.5.1 就落在支援範圍外，所以 C3 要在 broker 之前換（21.3）。
- **JDK 25 在 CP 升完之後才換**：8.2.x 只支援 Java 17／21，8.3.x 才支援 25；注意原廠對 8.3 的**建議**版本仍是 21，25 是「支援」，選 25 要和原廠支援確認（銀行沒有這個要求時，留在 21 就好，只做第一、三段）。C3 留在 JDK 21（原廠沒有寫 C3 2.6 支援 Java 25）。
- **OS 小版本（9.6 → 9.8）不在這一章**，是第 26 章的 26.5：Confluent 套件被 versionlock 鎖住、JDK 是 tar，OS 更新碰不到它們，所以兩條線可以分開做；本章每一段結束都跑第 19 章的驗收。

> 前提：安裝基底已經裝好並通過第 19 章驗收；目標版本的 RPM 與 JDK 25 已經在第 1、2 章隨落地區進來（`~/landing/rpm-target/`、`~/landing/bank/`），這一章 21.1 才把它們上架。第 20 章的憑證輪替做過沒做過都行，順序沒有相依。

分三段，每段結束都可以停下來驗收：

| 段 | 做什麼 | 出問題怎麼退 |
|---|---|---|
| 一 | 套件 8.2.4 → 8.3.2，JDK 維持 21。順序照原廠：C3（2.5.1 → 2.6.1）→ broker 逐台 → controller 逐台（leader 最後）→ REST Proxy → 操作機的工具 | `dnf downgrade` 回 8.2.4（21.8） |
| 二 | JDK 21 → 25：controller、broker、REST Proxy、操作機逐台切換 `/opt/java/current`；C3 留在 21 | 連結切回 21、重啟 |
| 三 | finalize：features 升到 4.3（`kafka-features upgrade --release-version 4.3`） | **不能退**：之後只有新舊版之間沒有 metadata 變更才能降版，8.3 降回去可能要從備份還原 |

要回 8.2 時順序反過來：先把 JDK 切回 21（8.2 不支援 25），再 `dnf downgrade`。所以**前兩段都驗收過才做第三段**。

**各節的順序**（照這個順序做，不要跳）：

1. 21.1 上架目標版本、升級前檢查 → 21.2 備份。
2. 第一段：21.3 C3 → 21.4 broker → 21.5 controller → 21.6 REST Proxy 與操作機工具。
3. 第二段：21.7 JDK 25（銀行不要求 25 就略過）。
4. 21.8 回滾演練：趁 finalize 之前，證明真的退得回去（kb04 退回再升回來）。
5. 21.9 第三段 finalize。**這是不能回頭的點**：做完之後叢集無法降回 8.2，要退只能靠 21.2 的備份與原廠的還原程序。
6. 21.10 確認版本、記下新基準。

每一段、每一台都要等健康（MDS 回 200、under-replicated 為 0、quorum Lag 為 0）才做下一台。

> 實測（lab，全程持續流量，2026-10-26 的升級演練，當時 C3 不動；這一版多了 C3 先升的一步，從零重跑後以新數字為準）：約 48 分鐘。直連應用程式送出 14,009 筆、讀回 14,009 筆，遺失 0；經負載平衡的 REST 2,684 次中失敗 2 次（HTTP 402，都發生在 controller 重啟的那幾秒，lab 用的是試用 license）。三段結束各跑一次第 19 章的驗收，都全數通過。

## 21.1 目標版本上架與升級前檢查

@role 小安 | ops02 | root

**這一節在做什麼**：把 8.3.2／2.6.1 的 RPM 上架到內部套件庫，並確認叢集現在是健康的，才開始升。**注意：`~/landing/rpm-target/` 與 `~/landing/bank/` 裡的 JDK 25 要保留到第 21 章全部做完（含 21.7）；19.5 的收尾不要先刪掉它們。**目標版本的 RPM 已經在落地區（`~/landing/rpm-target/`，第 2 章核對過 sha256 與簽章）。把它們加進內部套件庫：**基底版本不刪，回滾要用**，只推 `confluent/` 這個目錄：

```bash
(cd ~/landing && sha256sum -c --quiet SHA256SUMS) && cp ~/landing/rpm-target/*.rpm ~/repo/confluent/ && createrepo_c -q --update ~/repo/confluent && tar -C ~/repo -cf - confluent | ssh repodeploy@repo01.poc.lab 'tar -C /var/www/repo -xpf -' && ssh c3-01.poc.lab 'echo "套件庫裡的 confluent-server：$(sudo dnf -q --refresh --showduplicates list confluent-server 2>/dev/null | awk "/confluent-internal/{print \$2}" | sed "s/^1://; s/-1\$//" | sort -uV | paste -sd" " -)"; echo "套件庫裡的 C3：$(sudo dnf -q --showduplicates list confluent-control-center-next-gen 2>/dev/null | awk "/confluent-internal/{print \$2}" | sed "s/-1\$//" | sort -uV | paste -sd" " -)"'
```

```out
套件庫裡的 confluent-server：8.2.4 8.3.2
套件庫裡的 C3：2.5.1 2.6.1
```

確認現在的版本、quorum、套件庫裡有沒有新版、有沒有沒追上的複本，以及 8.3 已經拿掉的設定（`message.format.version` 這類留在設定檔裡，8.3 會起不來；基底的範本本來就沒有，這裡再確認一次）：

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

## 21.2 備份

@role 小安 | ops02 | root

**這一節在做什麼**：升級前留一份可以還原的備份。每台的 `/etc/confluent` 與 systemd drop-in、features 狀態、操作機的套件清單，打包回操作機（0700）。master key（`service.env`）不放進備份：master key 的正本在 CyberArk，備份檔就不必當成機敏資料保管。回滾、或 finalize 之後真的要退，都從這裡拿：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && B=~/upgrade-backup/$(date +%Y%m%d-%H%M) && install -d -m 0700 $B && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'sudo tar -czf - -C / --exclude=etc/confluent/service.env etc/confluent $(ls -d etc/systemd/system/confluent-*.service.d 2>/dev/null)' > $B/$h.tar.gz && printf '%s %s  ' $h "$(du -h $B/$h.tar.gz | cut -f1)"; done; echo; kafka-features --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties describe > $B/features.txt 2>/dev/null; rpm -qa 'confluent-*' | sort > $B/ops02-packages.txt; echo "$B"
```

```out
kc01 28K  kc02 28K  kc03 28K  kb01 32K  kb02 32K  kb03 32K  kb04 32K  rest01 28K  rest02 28K  c3-01 32K
/root/upgrade-backup/20261024-1401
```

## 21.3 第一段：Control Center 先（2.5.1 → 2.6.1）

@role 小安 | ops02 | root

**這一節在做什麼**：先升 Control Center。原廠要求 C3 比 broker、controller 先升，而且 2.5.1 不支援 8.3，所以這一步一定要先做。C3 只有一台，升級期間畫面約 1–2 分鐘不能用；broker、REST、應用程式不受影響（C3 只是看）。設定檔不用改（第 13 章的設定 2.5.1 與 2.6.1 通用）。

換版本的步驟寫成 `~/conf/c3-change.sh`，升級與回滾是同一段，只差 `dnf install` 或 `dnf downgrade`（第 27 章還會用到）：解鎖 → 換版本 → 鎖回新的版本 → `daemon-reload`（RPM 會換掉 unit 檔）→ 把 C3 自己要寫的 4 個 generated 檔改回 `cp-control-center`（RPM 換版本會把它們改回 root）→ 確認設定檔沒被動、`ExecStart` 還是指著我們的設定 → 重啟 Prometheus、Alertmanager、C3 → 等畫面 200：

```bash
cat > ~/conf/c3-change.sh <<'EOF'
#!/usr/bin/env bash
# c3-change.sh <版本> <install|downgrade>：在 c3-01 換 C3 套件版本、重啟、等畫面 200
V=$1 A=$2
ssh c3-01.poc.lab "p=/etc/confluent/control-center/control-center.properties; before=\$(sudo sha256sum \$p | cut -c1-12); sudo dnf -q versionlock delete confluent-control-center-next-gen >/dev/null; sudo dnf -q -y --refresh $A confluent-control-center-next-gen-$V >/dev/null && sudo dnf -q versionlock add confluent-control-center-next-gen-$V >/dev/null; sudo systemctl daemon-reload; cd /etc/confluent-control-center && for f in alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml; do sudo chown cp-control-center:confluent \$f && sudo chmod 0640 \$f; done; echo \"\$(rpm -q confluent-control-center-next-gen) config=\$([ \"\$before\" = \"\$(sudo sha256sum \$p | cut -c1-12)\" ] && echo same || echo CHANGED) exec=\$(systemctl show confluent-control-center -p ExecStart --value | grep -o '/etc/[^ ]*properties' | head -1) lock=\$(sudo dnf -q versionlock list | grep control-center)\"; for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart \$u; done"
for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done
echo "UI=$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://c3-01.poc.lab:9021/)（約 $((i*5)) 秒）；Prometheus 指標 $(curl -s -m 10 --cert ~/pki/certs/c3-monitoring.crt --key ~/pki/keys/c3-monitoring.key https://c3-01.poc.lab:9090/api/v1/label/__name__/values | grep -o 'confluent_kafka_server[a-z_]*' | sort -u | wc -l) 種"
EOF
chmod 0700 ~/conf/c3-change.sh && echo "C3 現在：$(ssh c3-01.poc.lab 'rpm -q confluent-control-center-next-gen')" && bash ~/conf/c3-change.sh 2.6.1 install && ssh c3-01.poc.lab 'cd /etc/confluent-control-center && echo "C3 自己寫的 4 個檔：$(sudo stat -c %U alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml | sort -u | paste -sd, -)"' && echo "alice 登入 MDS（C3 用同一套）：$(curl -s -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)"
```

```out
C3 現在：confluent-control-center-next-gen-2.5.1-1.noarch
confluent-control-center-next-gen-2.6.1-1.noarch config=same exec=/etc/confluent/control-center/control-center.properties lock=confluent-control-center-next-gen-0:2.6.1-1.*
UI=200（約 30–35 秒）；Prometheus 指標 125 種（歷史指標沒有因換版本而消失）
C3 自己寫的 4 個檔：cp-control-center
alice 登入 MDS（C3 用同一套）：200
```

> 陷阱（lab 實測，2.6.0／2.6.1 之間的換版本）：RPM 換版本（升級或退回）會把 `trigger_rules-generated.yml`、`recording_rules-generated.yml`、`prometheus-generated-local.yml` 改回 `root:root 644`。畫面照樣打得開，但之後在 C3 上改告警規則會寫不進去，所以 `c3-change.sh` 換完套件一定把這 4 個檔改回 `cp-control-center`（`prometheus-generated.yml` 是我們寫的，維持 root）。2.5.1 → 2.6.1 用的是同一段，從零重跑時再確認這個行為。

> 此時 C3（2.6.1）配著 CP 8.2.4：在原廠支援範圍內（2.6.x：7.5.15 到 8.3.x），第一段中途、也就是 broker 只升了一部分時 C3 看到的是新舊混合的叢集，這是原廠建議的順序。

## 21.4 第一段：broker 逐台

@role 小安 | ops02 | root

每台：解開 versionlock → 這台裝的每個 Confluent 套件都換成 8.3.2 → 重新鎖 → **`daemon-reload`**（RPM 升級會換掉 systemd 的 unit 檔，不 reload 就重啟，用的還是舊的定義）→ 確認設定檔沒被動、ExecStart 還指著我們的設定 → 重啟 → 等 MDS 回 200、under-replicated 回到 0 才做下一台：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && for h in kb01 kb02 kb03 kb04; do t0=$(date +%s); ssh $h.poc.lab 'before=$(sudo sha256sum /etc/confluent/kafka/server.properties | cut -c1-12); pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.3.2 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y --refresh install $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null || { echo "$(hostname) 換套件失敗" >&2; exit 1; }; sudo systemctl daemon-reload; after=$(sudo sha256sum /etc/confluent/kafka/server.properties | cut -c1-12); echo "$(hostname) $(rpm -q confluent-server) 設定檔$([ $before = $after ] && echo 沒變 || echo 被改了) exec=$(systemctl show confluent-server -p ExecStart --value | grep -o "/etc/[^ ]*properties")"; sudo systemctl restart confluent-server' || exit 1; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; for j in $(seq 1 60); do u=$(kafka-topics --bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:); [ "$u" = 0 ] && break; sleep 5; done; echo "  MDS 200（約 $((i*5)) 秒）under-replicated=$u，這台 $(( $(date +%s) - t0 )) 秒"; done
```

```out
kb01 confluent-server-8.3.2-1.noarch 設定檔沒變 exec=/etc/confluent/kafka/server.properties
  MDS 200（約 20 秒）under-replicated=0，這台 73 秒
（4 台，每台 70–110 秒）
```

> 陷阱：重啟前沒做 `daemon-reload`，systemd 會印 `The unit file … changed on disk`。設定還是我們的（drop-in 會疊上去），但下一次 reload 才會真的用新的 unit；所以每台都在重啟前 reload。

## 21.5 第一段：controller 逐台（leader 最後）

@role 小安 | ops02 | root

步驟和 broker 一樣。controller 的健康看 quorum：這台回來、`Lag` 是 0。**leader 會在過程中換人**（實測做完第二台時 leader 從 kc02 換到 kc01），所以每做一台之前都重新查一次 leader，跳過它，最後一輪才做 leader：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && Q="kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 --command-config /root/conf/client-internal.properties" && done_list="" && for round in 1 2 3; do leader=kc0$($Q describe --status 2>/dev/null | awk '/LeaderId/{print $2}'); h=""; for c in kc01 kc02 kc03; do [[ " $done_list " == *" $c "* ]] && continue; [ $c = $leader ] && [ $round -lt 3 ] && continue; h=$c; break; done; ssh $h.poc.lab 'pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.3.2 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y --refresh install $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null || { echo "$(hostname) 換套件失敗" >&2; exit 1; }; sudo systemctl daemon-reload; sudo systemctl restart confluent-server' || exit 1; sleep 10; for i in $(seq 1 60); do lag=$($Q describe --replication 2>/dev/null | awk -v id=${h#kc0} '$1==id {print $4}'); [ "$lag" = 0 ] && break; sleep 5; done; echo "$h $(ssh $h.poc.lab 'rpm -q confluent-server') Lag=$lag（這輪開始時 leader=$leader）"; done_list="$done_list $h"; done
```

```out
kc01 confluent-server-8.3.2-1.noarch Lag=0（這輪開始時 leader=kc02）
kc03 confluent-server-8.3.2-1.noarch Lag=0（這輪開始時 leader=kc01）
kc02 confluent-server-8.3.2-1.noarch Lag=0（這輪開始時 leader=kc01）
```

`describe --replication` 的欄位依序是 NodeId、DirectoryId、LogEndOffset、**Lag**、…，看的是第 4 欄。

## 21.6 第一段：REST Proxy 與操作機的工具

@role 小安 | ops02 | root

原廠要求 RBAC 環境在升 REST Proxy 之前，先讓 REST Proxy 的身分在 `_confluent-command` 有 ResourceOwner（原本只有 DeveloperRead）：

```bash
source ~/conf/kraft.env && confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key >/dev/null && confluent iam rbac role-binding create --principal User:svc-rest --role ResourceOwner --resource Topic:_confluent-command --kafka-cluster $CLUSTER_ID | grep -E 'Role|Name' | tr -s ' '
```

```out
| Role | ResourceOwner |
| Name | _confluent-command |
```

先換操作機自己的 `kafka-*` 與 `confluent` 指令：

```bash
pkgs=$(rpm -qa 'confluent-*' --qf '%{NAME}-8.3.2 '); dnf -q versionlock delete 'confluent-*' >/dev/null; dnf -q -y --refresh install $pkgs >/dev/null && dnf -q versionlock add $pkgs >/dev/null || exit 1; echo "ops02 $(rpm -q confluent-server confluent-cli | paste -sd' ')"
```

```out
ops02 confluent-server-8.3.2-1.noarch confluent-cli-8.3.2-1.x86_64
```


兩台 REST Proxy 照 12.1 一台一台換：先從 LB 停用、升級套件、重啟：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01 -b 'pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.3.2 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y --refresh install $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null || { echo "$(hostname) 換套件失敗" >&2; exit 1; }; sudo systemctl daemon-reload'
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02 -b 'pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.3.2 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y --refresh install $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null || { echo "$(hostname) 換套件失敗" >&2; exit 1; }; sudo systemctl daemon-reload'
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

```bash
for h in rest01 rest02; do echo "$h $(ssh $h.poc.lab 'rpm -q confluent-kafka-rest')"; done
```

```out
rest01 confluent-kafka-rest-8.3.2-1.noarch
rest02 confluent-kafka-rest-8.3.2-1.noarch
```

第一段結束：照第 19 章 19.1–19.3 再驗一次（實測全數通過）。這時 features 還是 8.2，隨時可以照 21.8 退回。

## 21.7 第二段：JDK 21 → 25

@role 小安 | ops02 | root

**這一節在做什麼**：把 controller、broker、REST Proxy、操作機的 JDK 從 21 換成 25（C3 不換）。前提：第一段已全部完成並驗收。和第 5 章一樣解壓到 `/opt/java/<版本目錄>`，只是把 `/opt/java/current` 切過去；所有服務的 drop-in 寫的都是 `/opt/java/current`，設定檔不用改。舊的 JDK 21 目錄留著，退回就是把連結切回去。**c3-01 不動**（原廠沒有寫 C3 2.6 支援 Java 25）。

> Java 25 在 CP 8.3 的相容表上是「支援」，原廠部署文件的建議版本仍是 21。這一段是照銀行「升 8.3 時一起換 25」的要求做；銀行沒有這個要求時，留在 21 就好（只做第一、三段）。

先 controller（每輪重查 leader、leader 最後）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1) && JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1) && echo "新 JDK：$JDK_DIR" && Q="kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 --command-config /root/conf/client-internal.properties" && done_list="" && for round in 1 2 3; do leader=kc0$($Q describe --status 2>/dev/null | awk '/LeaderId/{print $2}'); h=""; for c in kc01 kc02 kc03; do [[ " $done_list " == *" $c "* ]] && continue; [ $c = $leader ] && [ $round -lt 3 ] && continue; h=$c; break; done; scp -q "$JDK_TAR" $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo tar -xzf /tmp/$(basename $JDK_TAR) -C /opt/java && rm -f /tmp/$(basename $JDK_TAR) && sudo chown -R root:root /opt/java/$JDK_DIR && sudo ln -sfn /opt/java/$JDK_DIR /opt/java/current && sudo systemctl restart confluent-server"; sleep 10; for i in $(seq 1 60); do lag=$($Q describe --replication 2>/dev/null | awk -v id=${h#kc0} '$1==id {print $4}'); [ "$lag" = 0 ] && break; sleep 5; done; echo "$h java=$(ssh $h.poc.lab 'sudo readlink /proc/$(systemctl show confluent-server -p MainPID --value)/exe') Lag=$lag"; done_list="$done_list $h"; done
```

```out
新 JDK：jdk-25.0.5+8
kc01 java=/opt/java/jdk-25.0.5+8/bin/java Lag=0
（3 台，每台約 15 秒）
```

再 broker、操作機（REST Proxy 在下面另外做）：

```bash
JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1) && JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1) && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && for h in kb01 kb02 kb03 kb04; do case $h in kb*) unit=confluent-server; url=https://$h.poc.lab:8090/v1/metadata/id; opt="";; *) unit=confluent-kafka-rest; url=https://$h.poc.lab:8082/v3/clusters; opt="--cert $HOME/pki/certs/app-legacy-billing.crt --key $HOME/pki/keys/app-legacy-billing.key";; esac; scp -q "$JDK_TAR" $h.poc.lab:/tmp/ && ssh $h.poc.lab "sudo tar -xzf /tmp/$(basename $JDK_TAR) -C /opt/java && rm -f /tmp/$(basename $JDK_TAR) && sudo chown -R root:root /opt/java/$JDK_DIR && sudo ln -sfn /opt/java/$JDK_DIR /opt/java/current && sudo systemctl restart $unit"; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' $opt $url)" = 200 ] && break; sleep 5; done; for j in $(seq 1 60); do u=$(kafka-topics --bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:); [ "$u" = 0 ] && break; sleep 5; done; echo "$h java=$(ssh $h.poc.lab "sudo readlink /proc/\$(systemctl show $unit -p MainPID --value)/exe") 200（約 $((i*5)) 秒）under-replicated=$u"; done; sudo tar -xzf "$JDK_TAR" -C /opt/java && chown -R root:root /opt/java/$JDK_DIR && ln -sfn /opt/java/$JDK_DIR /opt/java/current && echo "ops02 $(java -version 2>&1 | head -1)"; echo "c3-01 $(ssh c3-01.poc.lab 'readlink /opt/java/current')"
```

```out
kb01 java=/opt/java/jdk-25.0.5+8/bin/java 200（約 20 秒）under-replicated=0
ops02 openjdk version "25.0.5" … LTS
c3-01 /opt/java/jdk-21.0.x+y
```


REST Proxy 照 12.1 一台一台換：先從 LB 停用、解壓新 JDK、切 `current`、重啟：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1) && JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1) && ~/conf/rest-restart.sh rest01 -c "$JDK_TAR" -b "sudo tar -xzf /tmp/$(basename $JDK_TAR) -C /opt/java && rm -f /tmp/$(basename $JDK_TAR) && sudo chown -R root:root /opt/java/$JDK_DIR && sudo ln -sfn /opt/java/$JDK_DIR /opt/java/current"
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1) && JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1) && ~/conf/rest-restart.sh rest02 -c "$JDK_TAR" -b "sudo tar -xzf /tmp/$(basename $JDK_TAR) -C /opt/java && rm -f /tmp/$(basename $JDK_TAR) && sudo chown -R root:root /opt/java/$JDK_DIR && sudo ln -sfn /opt/java/$JDK_DIR /opt/java/current"
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

```bash
for h in rest01 rest02; do echo "$h java=$(ssh $h.poc.lab 'readlink -f /opt/java/current')"; done
```

```out
rest01 java=/opt/java/jdk-25.0.5+8
rest02 java=/opt/java/jdk-25.0.5+8
```


broker 的日誌會多一則 `WARNING: A terminally deprecated method in sun.misc.Unsafe has been called`：原廠說明這只是警告，JDK 25 上照常運作。第二段結束：照第 19 章再驗一次（實測全數通過）。

## 21.8 回滾演練（finalize 之前）：kb04 退回 8.2.4，再升回去

@role 小安 | ops02 | root

**這一節在做什麼**：在 finalize 之前，實際演練一次「退回 8.2.4」，確認出事時真的退得回去，再升回來。這是 finalize 前最後一個還能退的機會。任何一段出問題、features 還沒升（`describe` 看到的還是 `CP-8.2-…`），就逐台退：先把 JDK 切回 21，再把套件 `downgrade` 回 8.2.4、重新鎖、`daemon-reload`、重啟。順序和升級相反（操作機、REST Proxy → controller → broker；C3 不用退，2.6.x 也支援 8.2.x，真的要退照第 27 章的 `c3-change.sh`）。實測拿 kb04 單台演練（其他台都是 8.3.2）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && h=kb04 && ssh $h.poc.lab 'sudo ln -sfn $(ls -d /opt/java/jdk-21* | sort -V | tail -1) /opt/java/current; pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.2.4 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y --refresh downgrade $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null || { echo "$(hostname) 換套件失敗" >&2; exit 1; }; sudo systemctl daemon-reload; sudo systemctl restart confluent-server' || exit 1; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h $(ssh $h.poc.lab 'rpm -q confluent-server; sudo readlink /proc/$(systemctl show confluent-server -p MainPID --value)/exe' | paste -sd' ') MDS 200（約 $((i*5)) 秒）"
```

```out
kb04 confluent-server-8.2.4-1.noarch /opt/java/jdk-21.0.x+y/bin/java MDS 200（約 15–20 秒）
```


演練完馬上把它升回去（和 21.4、21.7 同樣的做法，只動這一台）：

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && h=kb04 && ssh $h.poc.lab 'sudo ln -sfn $(ls -d /opt/java/jdk-25* | sort -V | tail -1) /opt/java/current; pkgs=$(rpm -qa "confluent-*" --qf "%{NAME}-8.3.2 "); sudo dnf -q versionlock delete "confluent-*" >/dev/null; sudo dnf -q -y --refresh install $pkgs >/dev/null && sudo dnf -q versionlock add $pkgs >/dev/null || { echo "$(hostname) 換套件失敗" >&2; exit 1; }; sudo systemctl daemon-reload; sudo systemctl restart confluent-server' || exit 1; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "$h $(ssh $h.poc.lab 'rpm -q confluent-server; sudo readlink /proc/$(systemctl show confluent-server -p MainPID --value)/exe' | paste -sd' ') MDS 200（約 $((i*5)) 秒）"
```

```out
kb04 confluent-server-8.3.2-1.noarch /opt/java/jdk-25.0.5+8/bin/java MDS 200（約 15–20 秒）
```

退回的那台在其他台都是 8.3.2 的叢集裡正常服務（under-replicated 回到 0）。回滾驗證完，馬上升回去（下面這一段），再往下做 finalize。

> 回滾：finalize 之後就不能用這個方法了。真的要退，得用 21.2 的備份與原廠支援的還原程序，所以 finalize 一定排在前兩段都驗收、觀察一段時間之後。

## 21.9 第三段：finalize（之後不能退回 8.2）

@role 小安 | ops02 | root

**這一節在做什麼**：把叢集的 metadata 版本（features）升到 4.3，正式啟用 8.3 的新功能。**這一步做完不能回頭**：前兩段、21.8 的回滾演練都完成並觀察一段時間後才做。先看 4.3 會把哪些 feature 升到多少，再 `--dry-run`（只預演、不真的升）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && F="kafka-features --bootstrap-server kb01.poc.lab:9094 --command-config /root/conf/client-admin.properties" && $F version-mapping --release-version 4.3 2>/dev/null && $F upgrade --release-version 4.3 --dry-run 2>/dev/null
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
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && F="kafka-features --bootstrap-server kb01.poc.lab:9094 --command-config /root/conf/client-admin.properties" && $F upgrade --release-version 4.3 2>/dev/null && $F describe 2>/dev/null | grep confluent.metadata.version | awk '{print $2, $8}'
```

```out
confluent.metadata.version was upgraded to 137.
（7 行 was upgraded）
confluent.metadata.version CP-8.3-IV0B
```

最後照第 19 章完整驗收一次。

## 21.10 遷移完成：確認版本、記下新的基準

@role 小安 | ops02 | root

**這一節在做什麼**：收尾確認，並把「新基準版本」記下來。三段都驗收過、觀察一段時間之後，用一張表確認每台主機的版本都是預期的（Confluent 與 JDK 是目標版本；C3 的 JDK 一直留在 21）：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'echo "$(hostname) java=$(readlink /opt/java/current | sed s#/opt/java/##) confluent=$(rpm -qa "confluent-*" --qf "%{VERSION}\n" | sort -u | paste -sd,) os=$(. /etc/os-release; echo $VERSION_ID)"'; done
```

```out
kc01 java=jdk-25.0.x+y confluent=8.3.2 os=9.6
（kb01–kb04、rest01、rest02 同上）
c3-01 java=jdk-21.0.x+y confluent=2.6.1 os=9.6
```

`os=9.6` 還沒動，那是第 26 章的事。**記下新的基準**：之後新增或換掉主機（第 23、24 章）要裝**現行版本**——第 5 章裝 JDK 25（`OpenJDK25U-*`）、第 8 章的版本號換成 8.3.2 與 2.6.1，不是這本書前面寫的 8.2.4／2.5.1。用 `install/` 腳本的話，改 `conf/site.env` 的 `CP_VERSION`、`C3_VERSION`、`JDK_MAJOR` 三個值就行（`21-upgrade.sh adopt` 會代改）。

# 22. 第二十二站：License 到期監控

**這一章在做什麼**：license（授權）到期前提早知道。做法：22.1 學會讀出到期日、22.2 設每天一次的自動檢查、22.3 買到正式 license 之後怎麼換上去。前提：叢集已運作（第 10 章之後任何時間都可以做）。

平台目前用的是試用 license（第 10 章 `confluent.license` 沒有設）。試用期 30 天；正式 license 一般一年一約。到期之後 broker 仍會繼續服務、只是日誌一直報錯，但**重啟時 RBAC／MDS 等安全外掛與 Control Center 起不來**，等於下一次維運重啟就停擺。原廠只在 C3 畫面（到期前 90 天開始）與 broker 日誌提醒，**沒有提供到期日的 JMX 指標**，所以行內監控要自己讀。

生效中的 license 是一個 JWT，broker 會把它存進 `_confluent-command` topic。讀出來、解開中間那段，`exp` 就是到期時間。

## 22.1 現在用的是哪一份、哪天到期

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && JWT=$(timeout 90 kafka-console-consumer --bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094 --consumer.config ~/conf/client-admin.properties --topic _confluent-command --from-beginning --timeout-ms 20000 2>/dev/null | grep -a -o 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' | tail -1) && P=$(cut -d. -f2 <<<"$JWT" | tr '_-' '/+') && while [ $(( ${#P} % 4 )) != 0 ]; do P="$P="; done && C=$(base64 -d <<<"$P" 2>/dev/null) && echo "類型：$(grep -o '"licenseType":"[^"]*"' <<<"$C" | cut -d'"' -f4)" && EXP=$(grep -o '"exp":[0-9]*' <<<"$C" | cut -d: -f2) && echo "到期：$(date -d @$EXP '+%F %T')，剩 $(( (EXP - $(date +%s)) / 86400 )) 天"; unset JWT P C EXP
```

```out
類型：trial
到期：2026-11-23 22:13:29，剩 29 天
```

> 只解開、不驗簽章：簽章由 broker 自己驗。這裡只是讀到期日給監控用。

## 22.2 每天檢查一次，寫進 syslog

@role 小安 | ops02 | root

把 22.1 寫成一支小腳本：剩不到 90 天（和 C3 的提示同一天開始）就以 `warning` 寫進 syslog，過期或讀不到就是 `err`；行內監控／SIEM 依 tag `confluent-license` 告警。結束碼 0／2／1 給銀行的排程系統用（要改由行內排程呼叫也是同一支）：

```bash
cat > ~/conf/license-check.sh <<'EOF'
#!/usr/bin/env bash
# 讀生效中的 license（_confluent-command 裡的 JWT）到期日，寫 syslog（tag confluent-license）
# 結束碼：0 正常、2 剩不到 WARN_DAYS 天、1 已過期或讀不到
WARN_DAYS=${WARN_DAYS:-90}
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
jwt=$(timeout 90 kafka-console-consumer --bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094 \
  --consumer.config /root/conf/client-admin.properties --topic _confluent-command --from-beginning --timeout-ms 20000 2>/dev/null \
  | grep -a -o 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' | tail -1)
payload=$(cut -d. -f2 <<<"$jwt" | tr '_-' '/+')
while [ $(( ${#payload} % 4 )) != 0 ]; do payload="$payload="; done
claims=$(base64 -d <<<"$payload" 2>/dev/null)
expires_at=$(grep -o '"exp":[0-9]*' <<<"$claims" | cut -d: -f2)
license_type=$(grep -o '"licenseType":"[^"]*"' <<<"$claims" | cut -d'"' -f4)
if [ -z "$expires_at" ]; then
  logger -t confluent-license -p user.err "license 讀不到（_confluent-command 沒有 JWT 或連不上 broker）"; echo "讀不到 license"; exit 1
fi
days_left=$(( (expires_at - $(date +%s)) / 86400 ))
message="license ${license_type:-unknown} 到期 $(date -d @"$expires_at" +%F)，剩 $days_left 天"
if [ "$days_left" -lt 0 ]; then logger -t confluent-license -p user.err "已過期：$message"; echo "已過期：$message"; exit 1; fi
if [ "$days_left" -lt "$WARN_DAYS" ]; then logger -t confluent-license -p user.warning "快到期：$message"; echo "快到期：$message"; exit 2; fi
logger -t confluent-license -p user.info "$message"; echo "$message"
EOF
chmod 0700 ~/conf/license-check.sh && bash ~/conf/license-check.sh; echo "rc=$?"
```

```out
快到期：license trial 到期 2026-11-23，剩 29 天
rc=2
```

試用版只有 30 天，所以 lab 一定是「快到期」（rc 2）；正式 license 剩超過 90 天時是 rc 0。

排程：操作機的 systemd timer 每天早上 8 點跑一次（以 root 身分，用的是操作機本來就有的管理 client 設定）。**待銀行確認**：行內若有排程系統（例如 Control-M），改由它在同一時間呼叫 `~/conf/license-check.sh`，看結束碼與 syslog，就不用裝這個 timer：

```bash
printf '[Unit]\nDescription=Confluent license expiry check\n\n[Service]\nType=oneshot\nEnvironment=HOME=/root\nExecStart=/root/conf/license-check.sh\nSuccessExitStatus=2\n' | tee /etc/systemd/system/confluent-license-check.service >/dev/null && printf '[Unit]\nDescription=Daily Confluent license expiry check\n\n[Timer]\nOnCalendar=*-*-* 08:00:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' | tee /etc/systemd/system/confluent-license-check.timer >/dev/null && systemctl daemon-reload && systemctl enable --now confluent-license-check.timer >/dev/null 2>&1 && systemctl start confluent-license-check.service && echo "下次執行：$(systemctl show confluent-license-check.timer -p NextElapseUSecRealtime --value)" && echo "syslog：$(journalctl -t confluent-license -n 1 --no-pager -o cat)"
```

```out
下次執行：Sun 2026-10-25 08:00:00 CST
syslog：快到期：license trial 到期 2026-11-23，剩 29 天
```

> `SuccessExitStatus=2`：「快到期」不算服務失敗（不然 systemd 會把它標成 failed，維運以為是腳本壞了）；真正要告警的是 syslog 那一行。

## 22.3 換上正式 license（lab 沒有正式 license，未實測）

@role 小安 | ops02 | root

銀行向 Confluent 買到 license 後會拿到一串 JWT（`eyJ` 開頭）。它和密碼一樣交由 Secrets 團隊放進 PVWA，小安取用時放 `~/secrets/license.jwt`（0600）。依原廠文件：

1. `~/conf/common.tpl` 的 License 區塊加 `confluent.license=${LICENSE}`（controller 與 broker 共用）；REST Proxy、C3 的範本各加一行 `confluent.license=${LICENSE}`。
2. 照第 10、12、13 章重新產生設定（`LICENSE=$(cat ~/secrets/license.jwt)` 帶進 `envsubst`）；密碼欄位照 15.3 一起加密。
3. 照 15.4、15.5 派送與滾動重啟（controller → broker → REST → C3）。
4. 用 22.1 確認：類型不再是 `trial`、到期日是合約的日期。

> 每年續約就是重做一次：換掉 `license.jwt`、重新產生、加密、滾動重啟。22.2 的告警在到期前 90 天開始，給採購流程留時間。

# 23. 第二十三站：換掉一台 controller

下面這張圖畫出換掉 kc03 的每一步，quorum 裡的成員怎麼變。

![controllerswap]

**這一章在做什麼**：controller 的主機壞了或資料碟壞了，怎麼把它換成一台新的，而不中斷叢集。順序：先看 quorum（23.1）→ 模擬壞掉（23.2，lab 專用）→ 把舊成員移出（23.3）→ 重新格式化並追上（23.4）→ 加回（23.5）。前提：其他兩台 controller 健康。

controller 的 quorum 是動態的（第 10 章用 `--initial-controllers` 格式化）：成員是「node id＋directory id」。換一台 controller，就是把舊的那組移出 quorum、把新的那組加進來，一次只動一個成員。

| 情況 | 要做的事 |
|---|---|
| 同一台主機，資料碟壞了換新 | 本章：移出舊成員 → 重新格式化（觀察者）→ 追上 → 加入 |
| 換一台新機器，沿用同一個主機名稱 | 先照第 3、5、7、8 章把新機器準備好（銀行的帳號、套件庫、JDK、OS 調校、套件；**裝現行版本**：遷移後是 JDK 25、Confluent 8.3.2，見 21.10），派送憑證與設定（第 10 章），再做本章 |
| 換成不同名稱的主機 | 另外要重簽 `kafka-internal`（SAN 列了所有主機名稱，20.2），所有節點的 `controller.quorum.bootstrap.servers` 改成新名單並滾動重啟；本章未演練 |

> 注意：一次只換一台。換的過程中 quorum 只剩兩個成員，兩個都要在才能選出 leader；這段時間重啟 kc01 或 kc02，叢集會失去多數派而停擺。處理：換完、kc03 追上並重新加入之前，不要動另外兩台。

## 23.1 換之前：看 quorum

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --replication
```

```out
NodeId  DirectoryId             LogEndOffset  Lag  LastFetchTimestamp  LastCaughtUpTimestamp  Status
1       …                       …             0    …                   …                      Leader
2       …                       …             0    …                   …                      Follower
3       …                       …             0    …                   …                      Follower
101     …                       …             0    …                   …                      Observer
（broker 101–104 都是 Observer）
```

## 23.2 模擬：kc03 的資料碟壞了

@role Lab 管理員 | Windows 終端 | 本機

正式環境是「主機團隊換了碟、掛回同一個路徑」。lab 裡：用清空資料目錄模擬：

```bash
docker exec lab-kc03-1 bash -c 'systemctl stop confluent-server && rm -rf /var/lib/kafka/data/* && echo "kc03 data: $(ls -A /var/lib/kafka/data | wc -l) files, $(stat -c %U:%G:%a /var/lib/kafka/data)"'
```

```out
kc03 data: 0 files, cp-kafka:confluent:750
```

@role 小安 | ops02 | root

這時候叢集照常（三個成員還有兩個），但 kc03 不再拉資料：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && sleep 15 && kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --replication | awk 'NR==1 || $1<100' && echo "MDS：$(curl -s -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/v1/metadata/id)"
```

```out
NodeId  DirectoryId  LogEndOffset  Lag  …  Status
1       …            …             0    …  Leader
2       …            …             0    …  Follower
3       OwqboMUaS4C4y6JYkevW7w  30349  37   …  Follower      （Lag 一直變大）
MDS：200
```

## 23.3 移出舊成員

@role 小安 | ops02 | root

舊成員是「3＋舊的 directory id」，從 23.1 的輸出取：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && Q="--bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093 --command-config $HOME/conf/client-internal.properties" && OLD_DIR=$(kafka-metadata-quorum $Q describe --replication | awk '$1==3 {print $2}') && echo "移出 3 / $OLD_DIR" && kafka-metadata-quorum $Q remove-controller --controller-id 3 --controller-directory-id $OLD_DIR && sleep 5 && kafka-metadata-quorum $Q describe --status | grep CurrentVoters | grep -o '"id": [0-9]*' | cut -d' ' -f2 | paste -sd' ' | sed 's/^/目前的成員：/'
```

```out
移出 3 / OwqboMUaS4C4y6JYkevW7w
Removed  KRaft controller 3 with directory id OwqboMUaS4C4y6JYkevW7w
目前的成員：1 2
```

## 23.4 重新格式化成觀察者、啟動、追上

@role 小安 | ops02 | root

用原本的 cluster id、`--no-initial-controllers`（以觀察者身分加入，不是自己宣告成員）。設定檔有 `${securepass:…}`（第 15 章），格式化工具也要拿得到 master key：從 `service.env` 讀：

```bash
source ~/conf/kraft.env && ssh kc03.poc.lab "sudo bash -c 'run() { set -a; . /etc/confluent/service.env; set +a; runuser -u cp-kafka -- env CONFLUENT_SECURITY_MASTER_KEY=\"\$CONFLUENT_SECURITY_MASTER_KEY\" \"\$@\"; }; run env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml kafka-storage format --cluster-id $CLUSTER_ID --config /etc/confluent/kafka/server.properties --no-initial-controllers 2>&1 | tail -1' && sudo systemctl start confluent-server && echo \"kc03 \$(systemctl is-active confluent-server) dir=\$(sudo sed -n 's/^directory.id=//p' /var/lib/kafka/data/meta.properties)\"" && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && for i in $(seq 1 60); do L=$(kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --replication 2>/dev/null | awk '$1==3'); [ "$(awk '{print $4, $NF}' <<<"$L")" = "0 Observer" ] && break; sleep 5; done; echo "kc03：$(awk '{print "Lag="$4, $NF}' <<<"$L")"
```

```out
Formatting metadata directory /var/lib/kafka/data with confluent.metadata.version 4.3-IV0B.
kc03 active dir=eELCq6OM-4WuTdfGQSmOgQ（新的 directory id，和 OLD_DIR 不同）
kc03：Lag=0 Observer
```

## 23.5 加回成員

> 實測（2026-10-25，lab）：從清空資料到重新成為成員約 5 分鐘（格式化、啟動、追上 3 萬多筆 metadata、add-controller），期間 MDS、REST、C3 都維持 200。

@role 小安 | ops02 | root

`add-controller` 要在**新的那台**上跑：工具從 `--command-config` 指到的設定找資料目錄，讀出自己的 node id 與 directory id 再去登記。用那台的 server.properties 加一行 `security.protocol=SSL`，用完就刪：

```bash
ssh kc03.poc.lab "sudo bash -c '( cat /etc/confluent/kafka/server.properties; echo security.protocol=SSL ) > /etc/confluent/kafka/add-controller.properties && chown root:confluent /etc/confluent/kafka/add-controller.properties && chmod 0640 /etc/confluent/kafka/add-controller.properties; run() { set -a; . /etc/confluent/service.env; set +a; runuser -u cp-kafka -- env CONFLUENT_SECURITY_MASTER_KEY=\"\$CONFLUENT_SECURITY_MASTER_KEY\" \"\$@\"; }; run env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093 --command-config /etc/confluent/kafka/add-controller.properties add-controller 2>&1 | grep -v WARN | tail -1; rm -f /etc/confluent/kafka/add-controller.properties'" && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && sleep 10 && kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --replication | awk 'NR==1 || $1<100'
```

```out
Added controller 3 with directory id eELCq6OM-4WuTdfGQSmOgQ and endpoints: CONTROLLER://kc03.poc.lab:9093
NodeId  DirectoryId             LogEndOffset  Lag  …  Status
2       MXVN7iSgSY6OKFf8XzxQ-Q  30989         0    …  Leader
1       fjcdbW_fTOCfGbYZur21vQ  30989         0    …  Follower
3       eELCq6OM-4WuTdfGQSmOgQ  30989         0    …  Follower
```

最後確認：kc03 的監控端點（官方規則有 `startDelaySeconds: 120`，剛啟動兩分鐘內是空的，所以等到有指標）、整體健康（第 14 章的檢查清單）：

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem && for i in $(seq 1 24); do n=$(curl -s --cacert $CA -u "prometheus:$(cat ~/secrets/jmx-scrape.pass)" https://kc03.poc.lab:7071/metrics | grep -c '^kafka_'); [ "$n" -gt 20 ] && break; sleep 10; done; echo "kc03 7071：${n}個指標" && for h in kb01 kb02 kb03 kb04; do printf "%s MDS=%s " $h "$(curl -s -o /dev/null -m 5 -w %{http_code} https://$h.poc.lab:8090/v1/metadata/id)"; done; echo
```

```out
kc03 7071：973個指標
kb01 MDS=200 kb02 MDS=200 kb03 MDS=200 kb04 MDS=200
```

# 24. 第二十四站：broker 縮減與擴充

下面這張圖畫出縮減、再擴充 kb04 的過程。

![brokerscale]

**這一章在做什麼**：拿掉一台 broker（縮減）、或加一台 broker（擴充），應用程式不中斷。順序：先做前置檢查（24.1）→ 縮減（24.2）→ 擴充（24.3）。名詞：Self-Balancing 是 Confluent 的自動資料平衡功能，負責把 partition 的 replica 搬到合適的 broker。

broker 的資料由 Self-Balancing（第 10 章 `confluent.balancer.enable=true`）搬：縮減時用 `kafka-remove-brokers` 把要拿掉的那台的 replica 全部搬走、它自己關機；擴充時空的 broker 一加入，Self-Balancing 自動把資料搬過去。

| 前提 | 原因 |
|---|---|
| 縮減後至少還有 3 台 | topic 的 replication factor 是 3 |
| 沒有 under-replicated partition | 搬資料前叢集要健康 |
| Self-Balancing 是 `ENABLED` | `kafka-remove-brokers` 靠它搬 |

lab 裡：用 kb04（node id 104）演練：先縮減、再當成一台空的新 broker 加回來。過程中持續有應用程式寫入。

## 24.1 前置檢查

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && BS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094 && A="--bootstrap-server $BS --command-config $HOME/conf/client-admin.properties" && echo "Self-Balancing：$(kafka-rebalance-cluster $A --status 2>/dev/null | grep -o 'Balancer status: [A-Z_]*')" && echo "under-replicated：$(kafka-topics $A --describe --under-replicated-partitions 2>/dev/null | grep -c 'Partition:')" && echo "kb04（104）上的 replica：$(kafka-topics $A --describe 2>/dev/null | awk '/Replicas:/ {for (i=1;i<=NF;i++) if ($i=="Replicas:") {n=split($(i+1),r,","); for (j=1;j<=n;j++) if (r[j]==104) c++}} END {print c+0}')"
```

```out
Self-Balancing：Balancer status: ENABLED
under-replicated：0
kb04（104）上的 replica：80
```

## 24.2 縮減：拿掉 kb04

@role 小安 | ops02 | root

先在背景跑一個持續寫入（app-orders 直連，acks=all，約 20 分鐘），證明搬資料期間應用程式不受影響：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && nohup kafka-producer-perf-test --topic orders.events --num-records 60000 --throughput 50 --record-size 200 --producer.config ~/conf/app-orders.properties --producer-props acks=all bootstrap.servers=kb01.poc.lab:9095,kb02.poc.lab:9095,kb03.poc.lab:9095 > ~/scale-load.log 2>&1 &
sleep 5; echo "背景寫入已開始：$(pgrep -fc ProducerPerformance) 個"
```

```out
背景寫入已開始：1 個
```

`--delete` 送出移除，之後每 30 秒看一次進度，直到 `SUCCESS`；kb04 會自己關掉 broker，接著停用服務、免得主機重開又加回來：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && A="--bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094 --command-config $HOME/conf/client-admin.properties" && kafka-remove-brokers $A --delete --broker-id 104 2>&1 | grep -v WARN | head -3 && for i in $(seq 1 60); do S=$(kafka-remove-brokers $A --describe 2>/dev/null | awk '/^Broker [0-9]+ removal status/ {on = ($2 == 104)} on'); grep -q 'removal status - SUCCESS' <<<"$S" && break; grep -q FAIL <<<"$S" && break; sleep 30; done; echo "$S" && ssh kb04.poc.lab 'sudo systemctl disable --now confluent-server >/dev/null 2>&1; echo "kb04 confluent-server：$(systemctl is-active confluent-server) / $(systemctl is-enabled confluent-server)"'
```

```out
Initiating remove brokers call...
Started remove broker task for brokers [104].
Broker 104 removal status - SUCCESS. Sub-task statuses:
  Broker Replica Exclusion: COMPLETED
  Partition Reassignment: COMPLETED
  Broker Shutdown: COMPLETED
  …（lab：80 個 replica 約 2 分鐘搬完；另一次 70 個花了 14 分鐘，因為當時 Self-Balancing 還在搬前一輪的資料）
kb04 confluent-server：inactive / disabled
```

確認：104 上沒有 replica、沒有 under-replicated、叢集裡已經沒有 104（quorum 的觀察者清單會留著 104 最後一次 fetch 的紀錄一段時間，不能拿來確認）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && A="--bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094 --command-config $HOME/conf/client-admin.properties" && echo "104 上的 replica：$(kafka-topics $A --describe 2>/dev/null | awk '/Replicas:/ {for (i=1;i<=NF;i++) if ($i=="Replicas:") {n=split($(i+1),r,","); for (j=1;j<=n;j++) if (r[j]==104) c++}} END {print c+0}')" && echo "under-replicated：$(kafka-topics $A --describe --under-replicated-partitions 2>/dev/null | grep -c 'Partition:')" && echo "叢集裡的 broker：$(kafka-broker-api-versions $A 2>/dev/null | grep -o '(id: [0-9]*' | grep -o '[0-9]*' | sort | paste -sd' ')"
```

```out
104 上的 replica：0
under-replicated：0
叢集裡的 broker：101 102 103
```

> 永久縮減時，還要把 kb04 從所有 bootstrap 名單拿掉（REST Proxy、C3、MDS URL、OP menu、應用程式的設定），重新產生並滾動重啟；名單裡留著一台不存在的主機，client 會略過它，但每次連線都多一次逾時。lab 接著要加回來，所以名單不動。

## 24.3 擴充：kb04 以空的 broker 加回

@role 小安 | ops02 | root

加回來的 broker 必須是空的（舊 replica 不能帶回來）：清空資料目錄、用同一個 cluster id 以觀察者格式化、啟動。換一台全新主機時，前面照第 3、5、7、8 章準備，憑證的 SAN 要有它的名稱（20.2）：

```bash
source ~/conf/kraft.env && ssh kb04.poc.lab "sudo bash -c 'rm -rf /var/lib/kafka/data/*; run() { set -a; . /etc/confluent/service.env; set +a; runuser -u cp-kafka -- env CONFLUENT_SECURITY_MASTER_KEY=\"\$CONFLUENT_SECURITY_MASTER_KEY\" \"\$@\"; }; run env JAVA_HOME=/opt/java/current KAFKA_HEAP_OPTS=-Xmx256m KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml kafka-storage format --cluster-id $CLUSTER_ID --config /etc/confluent/kafka/server.properties --no-initial-controllers 2>&1 | tail -1' && sudo systemctl enable --now confluent-server >/dev/null 2>&1" && for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' https://kb04.poc.lab:8090/v1/metadata/id)" = 200 ] && break; sleep 5; done; echo "kb04 MDS=$(curl -s -o /dev/null -w '%{http_code}' https://kb04.poc.lab:8090/v1/metadata/id)"
```

```out
Formatting metadata directory /var/lib/kafka/data with confluent.metadata.version 4.3-IV0B.
kb04 MDS=200
```

Self-Balancing 發現空的 broker 會自己開始搬（不用下指令）。它不是馬上動：lab 等了十幾分鐘才開始，之後分批搬、要再一段時間才平均（實測加回 30 分鐘時 101–103 各約 130、104 約 45，還在增加）。這裡等到 104 上有 replica、而且沒有 under-replicated：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && A="--bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094,kb04.poc.lab:9094 --command-config $HOME/conf/client-admin.properties" && on104() { kafka-topics $A --describe 2>/dev/null | awk '/Replicas:/ {for (i=1;i<=NF;i++) if ($i=="Replicas:") {n=split($(i+1),r,","); for (j=1;j<=n;j++) if (r[j]==104) c++}} END {print c+0}'; } && for i in $(seq 1 60); do n=$(on104); u=$(kafka-topics $A --describe --under-replicated-partitions 2>/dev/null | grep -c 'Partition:'); [ "$n" -gt 0 ] && [ "$u" = 0 ] && break; sleep 30; done; echo "104 上的 replica：$n、under-replicated：$u（約 $((i*30)) 秒）" && kafka-rebalance-cluster $A --describe 2>/dev/null | grep -iE 'status|broker' | head -5
```

```out
104 上的 replica：15、under-replicated：0（約 1050 秒）
Uneven load balance status:
  HealUnevenLoadTrigger: EMPTY_BROKER
```

背景寫入的結果（整段縮減與擴充期間，最大延遲出現在 replica 搬移時）：

```bash
for i in $(seq 1 60); do pgrep -f ProducerPerformance >/dev/null || break; sleep 10; done; tail -1 ~/scale-load.log; echo "錯誤：$(grep -ciE 'error|exception' ~/scale-load.log)"
```

```out
60000 records sent, 49.999167 records/sec (0.01 MB/sec), 10.33 ms avg latency, 1132.00 ms max latency, 10 ms 50th, 14 ms 95th, 19 ms 99th, 164 ms 99.9th.
錯誤：0
```

# 25. 第二十五站：日常備份

下面這張圖說明每天的匯出流程，以及三類備份各自的處理方式。

![backup]

**這一章在做什麼**：每天自動把叢集的「設定類」中繼資料（誰有什麼權限、有哪些 topic 與設定）匯出成文字檔，遇到誤刪時能照著重建。訊息本身不備份。順序：建專用的唯讀身分（25.1、25.2）→ 匯出腳本（25.3）→ 排程（25.4）→ 怎麼比對與還原（25.5）。

要備份的東西分成三類，各走各的路：

| 類別 | 內容 | 怎麼備 | 誰做 |
|---|---|---|---|
| 叢集中繼資料 | RBAC、ACL、topic 與設定、SCRAM 帳號清單與配額、features、broker 動態設定 | 操作機每天排程匯出（本章），保留 30 天；變更前另外手動跑一次當快照 | 小安裝好之後自動跑 |
| 各台的設定 | `/etc/confluent`、systemd drop-in、`/etc/kafka` 的 log4j2 | 銀行既有的主機備份系統（操作機的排程只匯出 Kafka 的中繼資料，不 ssh 進各台） | 銀行主機團隊 |
| 機敏資料 | `~/pki` 的私鑰、`~/secrets`、master key | **事件觸發**：安裝、換憑證、換密碼的當下交 CyberArk 保管（第 15 章 master key 的做法），不排程 | 小安＋Secrets 團隊 |

訊息本身不做檔案備份：叢集內靠 replication factor 3、`min.insync.replicas=2`；異地備援（Cluster Linking）依銀行的 RPO／RTO 另議。

匯出用的身分是新發的 `svc-backup` 憑證，**只能看、不能改、讀不到訊息內容**。不用 super user 的 `svc-ops`：排程每天自動跑，身分越小越好。

## 25.1 svc-backup 的 client 設定

@role 小安 | ops02 | root

`svc-backup` 憑證在第 9 章已經和其他憑證一起發了（`~/pki/certs/svc-backup.p12`）。client 設定從管理用的那份複製，換成 svc-backup 的 keystore：

```bash
(umask 077; sed 's#/svc-ops.p12#/svc-backup.p12#' ~/conf/client-admin.properties > ~/conf/client-backup.properties) && echo "client-backup.properties：$(grep -c svc-backup ~/conf/client-backup.properties) 處指向 svc-backup；憑證 $(openssl x509 -in ~/pki/certs/svc-backup.crt -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')，剩 $(( ($(date -d "$(openssl x509 -in ~/pki/certs/svc-backup.crt -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )) 天"
```

```out
client-backup.properties：1 處指向 svc-backup；憑證 svc-backup，剩 364 天
```

## 25.2 最小權限：SecurityAdmin＋兩條 ACL

@role 小安 | ops02 | root

lab 逐項試過（2026-10-25）：

| 要匯出的 | 需要的操作 | 給法 |
|---|---|---|
| role binding | MDS 查詢 | RBAC `SecurityAdmin`（只能看：`DescribeAccess`、`SecurityMetadata Describe`；試建 binding 回 403） |
| topic 清單與設定、partition 分布 | Topic 的 `Describe`、`DescribeConfigs` | KRaft ACL（第 10 章 `access.rule.providers` 有開 `KRAFT_ACL`） |
| SCRAM 帳號清單、配額、broker 動態設定、ACL 清單 | Cluster 的 `Describe`、`DescribeConfigs` | KRaft ACL |
| features | 不用額外權限 | — |

> 為什麼 topic 設定不用 RBAC 角色：內建角色裡有 `DescribeConfigs` 的都連帶能建立、刪除或改設定（例如 `DeveloperManage`），沒有唯讀的；`DeveloperRead` 沒有 `DescribeConfigs`，而且讀得到訊息內容。ACL 可以只給這兩個操作。

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && CID=$(curl -s https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4) && confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key >/dev/null && confluent iam rbac role-binding create --principal User:svc-backup --role SecurityAdmin --kafka-cluster $CID >/dev/null && A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties" && kafka-acls $A --add --allow-principal User:svc-backup --operation Describe --operation DescribeConfigs --topic '*' >/dev/null && kafka-acls $A --add --allow-principal User:svc-backup --operation Describe --operation DescribeConfigs --cluster >/dev/null && confluent iam rbac role-binding list --principal User:svc-backup --kafka-cluster $CID | tail -n +3 && echo "ACL：$(kafka-acls $A --list --principal User:svc-backup 2>/dev/null | grep -c 'operation=') 條"
```

```out
  User:svc-backup | SecurityAdmin | Cluster       |      |
ACL：4 條
```

反向：讀不到訊息、建不了 topic、改不了 role binding（CLI 用暫時的 HOME 登入 svc-backup，不蓋掉操作機原本的登入）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && B="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-backup.properties" && echo "讀訊息：$(kafka-console-consumer --bootstrap-server kb01.poc.lab:9094 --consumer.config ~/conf/client-backup.properties --topic orders.events --from-beginning --max-messages 1 --timeout-ms 10000 2>&1 | grep -o '[A-Za-z]*AuthorizationException' | head -1)" && echo "建 topic：$(kafka-topics $B --create --topic backup-sneak --partitions 1 --replication-factor 3 2>&1 | grep -o '[A-Za-z]*AuthorizationException' | head -1)" && CID=$(curl -s https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4) && T=$(mktemp -d) && HOME=$T confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem --certificate-only --client-cert-path ~/pki/certs/svc-backup.crt --client-key-path ~/pki/keys/svc-backup.key >/dev/null && echo "改 role binding：$(HOME=$T confluent iam rbac role-binding create --principal User:svc-backup --role SystemAdmin --kafka-cluster $CID 2>&1 | grep -o '40[0-9] [A-Za-z]*' | head -1)"; rm -rf $T
```

```out
讀訊息：GroupAuthorizationException
建 topic：TopicAuthorizationException
改 role binding：403 Forbidden
```

## 25.3 匯出腳本

@role 小安 | ops02 | root

每一項存成一個文字檔，最後算 `SHA256SUMS`（比對兩天的備份就看它）；超過 30 天的自動刪掉；成功或失敗都寫 syslog（tag `confluent-backup`）。**整段貼到 EOF**：

```bash
cat > ~/conf/metadata-backup.sh <<'EOF'
#!/usr/bin/env bash
# 每天匯出叢集中繼資料（RBAC、ACL、topic 與設定、SCRAM 帳號與配額、features、broker 動態設定）到 ~/backup/metadata/<時間>/
# 身分：svc-backup（SecurityAdmin 只能看 role binding；ACL 只有 Describe、DescribeConfigs）；沒有密碼，不讀訊息內容
# 結束碼：0 全部匯出、1 有任何一項失敗（看 syslog tag confluent-backup）
KEEP_DAYS=${KEEP_DAYS:-30}
BACKUP_ROOT=${BACKUP_ROOT:-$HOME/backup/metadata}
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094 --command-config $HOME/conf/client-backup.properties"
out=$BACKUP_ROOT/$(date +%Y%m%d-%H%M); install -d -m 0700 "$out"; failed=""
# save <檔名> <指令…>：輸出存檔；失敗或空的就記下來，錯誤訊息留在 <檔名>.err
save() { local file=$1; shift; if "$@" > "$out/$file" 2> "$out/$file.err" && [ -s "$out/$file" ]; then rm -f "$out/$file.err"; else failed="$failed $file"; fi; }
# 比對兩天的備份靠 sha256：會變的雜訊（features 的 Epoch）拿掉、ACL 與帳號清單的順序不固定所以排序
features() { kafka-features $A describe | sed 's/[[:space:]]*Epoch: [0-9]*//'; }
acls() { kafka-acls $A --list | grep . | sort; }
scram_and_quotas() { kafka-configs $A --describe --entity-type users | sort; }
save topics.txt         kafka-topics $A --describe
save topic-configs.txt  kafka-configs $A --describe --entity-type topics
save users.txt          scram_and_quotas      # SCRAM 只有機制與迭代次數，沒有密碼；配額
save broker-configs.txt kafka-configs $A --describe --entity-type brokers --entity-default
save features.txt       features
save acls.txt           acls
# RBAC：confluent CLI 用自己的 HOME，免得蓋掉操作機上原本的登入身分
export HOME_CLI=$BACKUP_ROOT/.cli; install -d -m 0700 "$HOME_CLI"
cli() { HOME=$HOME_CLI confluent "$@"; }
cluster_id=$(curl -s https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
rbac() {
  cli login --url https://kb01.poc.lab:8090 --certificate-authority-path "$HOME/pki/certs/bank-root.pem" --certificate-only \
    --client-cert-path "$HOME/pki/certs/svc-backup.crt" --client-key-path "$HOME/pki/keys/svc-backup.key" >/dev/null || return 1
  local role principal
  for principal in $(for role in $(cli iam rbac role list -o json | grep -o '"name": *"[A-Za-z]*"' | cut -d'"' -f4); do
                       cli iam rbac role-binding list --role "$role" --kafka-cluster "$cluster_id" -o json 2>/dev/null; done |
                     grep -o '"principal": *"[^"]*"' | cut -d'"' -f4 | sort -u); do
    echo "== $principal"; cli iam rbac role-binding list --principal "$principal" --kafka-cluster "$cluster_id" | tail -n +3
  done
}
save rbac.txt rbac
(cd "$out" && sha256sum -- *.txt > SHA256SUMS)
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$KEEP_DAYS" -exec rm -rf {} +
if [ -n "$failed" ]; then logger -t confluent-backup -p user.err "中繼資料匯出有失敗：$failed（$out）"; echo "失敗：$failed"; exit 1; fi
logger -t confluent-backup -p user.info "中繼資料已匯出：$out"; echo "$out"
EOF
chmod 0700 ~/conf/metadata-backup.sh && d=$(bash ~/conf/metadata-backup.sh) && echo "$d" && cd "$d" && for f in *.txt; do printf '%-18s %4s 行\n' $f $(wc -l < $f); done && echo "RBAC 的 principal：$(grep -c '^== ' rbac.txt) 個；SHA256SUMS：$(wc -l < SHA256SUMS) 個檔" && echo "密碼字樣：$(grep -ciE 'password=|salt|stored_key' *.txt | awk -F: '{s+=$2} END {print s}')"
```

```out
/root/backup/metadata/20261025-0102
acls.txt              6 行
broker-configs.txt    2 行
features.txt          8 行
rbac.txt             35 行
topic-configs.txt    66 行
topics.txt          160 行
users.txt             7 行
RBAC 的 principal：11 個；SHA256SUMS：7 個檔
密碼字樣：0
```

> `users.txt` 的 SCRAM 那幾行只有機制與迭代次數（`SCRAM-SHA-512=iterations=8192`），沒有密碼也沒有雜湊。帳號被刪掉時，這份清單告訴你要重建哪些帳號，密碼另向 Secrets 團隊取（第 15 章）。

## 25.4 每天凌晨 2 點自動跑

**待銀行確認**：行內若有排程系統，改由它每天呼叫 `~/conf/metadata-backup.sh`（結束碼 0／1），就不用裝下面的 timer。

@role 小安 | ops02 | root

```bash
printf '[Unit]\nDescription=Confluent cluster metadata export\n\n[Service]\nType=oneshot\nEnvironment=HOME=/root\nExecStart=/root/conf/metadata-backup.sh\n' | tee /etc/systemd/system/confluent-metadata-backup.service >/dev/null && printf '[Unit]\nDescription=Daily Confluent cluster metadata export\n\n[Timer]\nOnCalendar=*-*-* 02:00:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' | tee /etc/systemd/system/confluent-metadata-backup.timer >/dev/null && systemctl daemon-reload && systemctl enable --now confluent-metadata-backup.timer >/dev/null 2>&1 && systemctl start confluent-metadata-backup.service && echo "下次執行：$(systemctl show confluent-metadata-backup.timer -p NextElapseUSecRealtime --value)" && echo "syslog：$(journalctl -t confluent-backup -n 1 --no-pager -o cat)"
```

```out
下次執行：Sun 2026-10-25 02:00:00 CST
syslog：中繼資料已匯出：/root/backup/metadata/20261025-0103
```

> 備份目錄在操作機上；正式環境請銀行的主機備份系統把 `~/backup/metadata` 一起收走（裡面沒有密碼，只有清單與設定）。

## 25.5 用備份：哪裡變了

@role 小安 | ops02 | root

比對最近兩次的備份，哪些檔有變一眼看出來（精簡的 OS 沒有 `diff`，用 sha256 與 `join`）；以 topic 為例列出多出來的。

正式環境比的是「昨天」和「今天」。lab 沒有隔天，所以先造一個變化：新建 `orders.backup-demo`，等到下一分鐘再匯出一次（備份目錄以分鐘命名，同一分鐘再匯出會蓋掉前一份）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --create --if-not-exists --topic orders.backup-demo --partitions 1 --replication-factor 3 >/dev/null && last=$(ls -d ~/backup/metadata/20* | tail -1) && while [ "$(date +%Y%m%d-%H%M)" = "$(basename $last)" ]; do sleep 5; done && ~/conf/metadata-backup.sh >/dev/null && echo "新建 orders.backup-demo 後再匯出：$(basename $(ls -d ~/backup/metadata/20* | tail -1))（上一份 $(basename $last)）"
```

```out
新建 orders.backup-demo 後再匯出：20261025-0108（上一份 20261025-0107）
```

```bash
cd ~/backup/metadata && set -- $(ls -d 20* | tail -2) && echo "比對 $1 → $2" && join -1 2 -2 2 <(sort -k2 $1/SHA256SUMS) <(sort -k2 $2/SHA256SUMS) | awk '{printf "%-18s %s\n", $1, ($2 == $3 ? "相同" : "有變")}' && echo "topics.txt 多出來的：$(grep -o 'Topic: [^[:space:]]*' $2/topics.txt | sort -u | grep -vxFf <(grep -o 'Topic: [^[:space:]]*' $1/topics.txt | sort -u) | paste -sd' ')"
```

```out
比對 20261025-0107 → 20261025-0108
acls.txt           相同
broker-configs.txt 相同
features.txt       相同
rbac.txt           相同
topic-configs.txt  有變
topics.txt         有變
users.txt          相同
topics.txt 多出來的：Topic: orders.backup-demo
```

`topics.txt`、`topic-configs.txt` 每次都可能顯示「有變」：describe 的輸出含 leader、ISR 這類會隨時間變動的欄位。要看的是**多了或少了哪些 topic**（最後一行）。看完把示範用的 topic 刪掉：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml; kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --delete --topic orders.backup-demo >/dev/null 2>&1; sleep 3; echo "orders.backup-demo 還在嗎：$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list 2>/dev/null | grep -cx orders.backup-demo)"
```

```out
orders.backup-demo 還在嗎：0
```

> features 的 `Epoch` 每次都不同、ACL 與帳號清單（`users.txt`）列出的順序不固定，腳本已經拿掉與排序，否則常會顯示「有變」。

> 變更前的快照也可以由維運人員從 OP menu 44 匯出（`44 snapshot`）：以本人 AD 身分執行、檔名與內容和這裡一樣（另多一份權限清單 CSV），放在選單的輸出目錄，可以拿來和每日備份比對。

還原時拿這些檔當依據逐項重建：topic（`kafka-topics --create`，照 `topics.txt` 的 partition 數、RF 與 `topic-configs.txt` 的設定）、role binding（照 `rbac.txt` 用 `confluent iam rbac role-binding create`）、配額（`kafka-configs --alter`）。這些都由有權限的人在變更時段做，不寫成自動還原。

# 26. 第二十六站：OS 修補與小版本更新

下面這張圖把整章的順序和每台機器重複做的事畫出來。

![ospatch]

**這一章在做什麼**：銀行的作業系統要更新（每月修補，或 9.6 → 9.8 小版本）時，我方怎麼一台一台修，修完確認平台健康。前提：Confluent 套件已被 versionlock 鎖住（第 8 章）。主線上接在第 21 章之後。

銀行每月的 OS 修補照常由銀行的套件庫（Satellite／Nexus／web server）發布；平台這邊要做的只是「一台一台修、該重開就重開、健康了才做下一台」。Confluent 套件被 versionlock 鎖住（第 8 章），JDK 是 tar（第 5 章），所以 `dnf update` 只會動 OS 套件；C3 的前置套件 `cyrus-sasl`、`openssl-devel` 跟著 OS 修補走（不鎖）。

這一章處理兩種情境，**步驟完全一樣**，差別只在套件庫裡有什麼、更新量多大、幾乎一定要重開機：

| 情境 | 例子 | 更新量 | 重開機 |
|---|---|---|---|
| 每月修補 | 9.6 內的安全更新 | 幾個到幾十個套件 | 偶爾（核心、glibc、systemd 更新時） |
| **小版本更新**（主線，26.5） | RHEL 9.6 → 9.8 | 一百多個套件（lab 實測 148 個，含 glibc、systemd、openssh、openssl） | 一定（glibc、systemd、核心都換） |

主線裡這一章接在第 21 章之後：Confluent 已是 8.3.2、JDK 已是 25，現在把 OS 從安裝基底的 **9.6 更新到 9.8**。26.0 是銀行的事（把套件庫同步到 9.8），26.1–26.4 是更新本身，26.5 是驗證、重開機的限制、回滾與「別的小版本怎麼套用」。

| 順序 | 主機 | 修完之後 |
|---|---|---|
| 1 | broker 逐台 | 要重開機就重開；平台服務要重啟就重啟；等 MDS 200、沒有 under-replicated 才下一台 |
| 2 | controller 逐台，leader 最後 | 等 quorum 的 Lag 回到 0 |
| 3 | REST Proxy、C3、操作機 | REST 經 LB 200、C3 200 |

要不要重開機、要不要重啟服務，用 `dnf needs-restarting` 判斷，不靠人記：`-r` 看核心程式庫（kernel、glibc、systemd…）有沒有更新，`-s` 列出用到被更新程式庫、需要重啟的服務。JVM 自帶 TLS 實作，OS 的 openssl 更新通常不會把 Confluent 服務列進 `-s`；但 JVM 載入的 glibc 換了，**服務要重啟（或重開機）才會用到新的**。

> **lab 限制**：**lab 是容器，不能真的重開機**（核心是 WSL2 的，`systemctl reboot` 會失敗：Could not activate remote peer）；kernel 更新也不會生效，因為容器根本沒有自己的核心。26.2–26.4 的指令用 `systemd-detect-virt -c` 判斷主機是不是容器：是的話，「要重開機：是」改成重啟該主機的平台服務（讓 JVM 載入新的 glibc），正式環境才是 `sudo systemctl reboot`。這是 lab 能做到的最接近的替代，**不等於重開機的驗證**：開機順序、fstab、網卡、核心模組、systemd unit 的 enable 狀態都沒有被測到，正式環境第一次做小版本更新請排在變更窗口，並先在測試環境走一遍。

## 26.0 銀行先把套件庫同步到要更新的版本

@role 銀行 OS 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

前提：銀行的套件庫已經有這一輪要更新到的內容。每月修補是銀行例行的同步；小版本更新就是把套件庫同步到 9.8（Satellite 換 content view、Nexus 同步新的 proxy 倉庫、web server 重新 reposync，各家做法不同，從主機看都是同一個 `bank-os` repo）。我方要確認兩件事：**套件庫裡有 `rocky-release`／`redhat-release` 的 9.8**（沒有就代表只是同一小版本內的修補，不是小版本更新），以及 **`confluent-*` 不在更新清單裡**（26.1 檢查）。

lab 沒有銀行的套件庫同步，就自己做：在一個乾淨的 9.6 容器裡，把 3.2 下載的 9.6 套件裝起來（等於「裝好這批套件的 9.6 主機」），對 Rocky 的 9.8 倉庫（`pub/rocky/9.8`）做 `dnf update --downloadonly`，就得到「9.6 主機升到 9.8 要的更新集合」。把更新集合和 9.6 的內容合併、重建索引，換上 repo01 的 `/os/`。`--downloadonly` 只下載不安裝；下載的檔案先複製到銀行的目錄、再建索引：

```bash
cd ~/kafka-lab && docker run --rm -v "$(cygpath -m "$PWD/bank-os"):/out" lab-node:96 bash -c '
set -e
t0=$(date +%s)
dnf -q -y --disablerepo="*" install /out/9.6/Packages/*.rpm >/dev/null
printf "[r98-baseos]\nname=Rocky 9.8 BaseOS\nbaseurl=https://dl.rockylinux.org/pub/rocky/9.8/BaseOS/\$basearch/os/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\nenabled=1\n[r98-appstream]\nname=Rocky 9.8 AppStream\nbaseurl=https://dl.rockylinux.org/pub/rocky/9.8/AppStream/\$basearch/os/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\nenabled=1\n[r98-extras]\nname=Rocky 9.8 extras\nbaseurl=https://dl.rockylinux.org/pub/rocky/9.8/extras/\$basearch/os/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\nenabled=1\n" > /etc/yum.repos.d/rocky-98.repo
mkdir -p /out/9.8-updates/Packages /tmp/dl
dnf -q -y --disablerepo="*" --enablerepo=r98-baseos,r98-appstream,r98-extras update --downloadonly --downloaddir /tmp/dl >/dev/null 2>&1
cp -a /tmp/dl/. /out/9.8-updates/Packages/ && createrepo_c -q /out/9.8-updates
mkdir -p /out/9.8/Packages && cp -a /out/9.6/Packages/. /out/9.8/Packages/ && cp -a /out/9.8-updates/Packages/. /out/9.8/Packages/ && createrepo_c -q /out/9.8
echo "9.8 更新集合：$(ls /out/9.8-updates/Packages | wc -l) 個 RPM、$(du -sm /out/9.8-updates | cut -f1) MB（$(( $(date +%s) - t0 )) 秒）；合併後的套件庫 $(ls /out/9.8/Packages | wc -l) 個 RPM"' && docker exec lab-repo01-1 bash -c 'rm -rf /var/www/repo/os/*' && docker cp "$(cygpath -m "$PWD/bank-os/9.8")/." lab-repo01-1:/var/www/repo/os/ && docker exec lab-repo01-1 bash -c 'chown -R repodeploy:repodeploy /var/www/repo/os; echo "repo01 /os/：$(ls /var/www/repo/os/Packages | wc -l) 個 RPM；rocky-release：$(ls /var/www/repo/os/Packages | grep rocky-release)"'
```

```out
9.8 更新集合：152 個 RPM、78 MB（約 160 秒）；合併後的套件庫 223 個 RPM
repo01 /os/：223 個 RPM；rocky-release：rocky-release-9.8-1.2.el9.noarch.rpm
```

> 說明：更新集合是 152 個 RPM（148 個要更新的套件加上相依），只有 78 MB，因為這批主機的套件只有最小安裝加上平台要用的工具；真正的 RHEL 主機裝的東西多，數字會大很多，請銀行的 OS 團隊用同樣的方法（在代表性的主機上 `dnf update --downloadonly`）估算。套件庫合併後同時有 9.6 和 9.8 的版本，dnf 會挑最新的。

> 陷阱：dnf 會快取套件庫的中繼資料 48 小時，剛同步完主機可能還看到舊的清單。26.1 之後的指令都帶 `--refresh`。

## 26.1 修補前：看有哪些更新、Confluent 有沒有鎖住

@role 小安 | ops02 | root

每台印出：目前的 OS 版本、套件庫裡 release 套件的版本（小版本更新時會比目前的新）、可更新幾個、其中跟平台有關的幾個、鎖住幾個 confluent 套件，再用 `dnf upgrade --assumeno` 預覽交易（只看摘要，不執行）：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && echo "under-replicated：$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:)" && for h in kc01 kb01 rest01 c3-01 ops02; do ssh $h.poc.lab 'u=$(sudo dnf -q check-update --refresh 2>/dev/null | awk "/^[a-zA-Z0-9]/{print \$1}" | sed "s/\.[^.]*\$//"); echo "$(hostname)：OS $(. /etc/os-release; echo $VERSION_ID)，套件庫的 release 套件 $(sudo dnf -q repoquery --latest-limit 1 --qf %{version} $(rpm -q --whatprovides system-release --qf "%{NAME}\n" | head -1) 2>/dev/null | head -1)；可更新 $(grep -c . <<<"$u") 個（平台相關：$(grep -xE "glibc|systemd|openssh-server|kernel|rocky-release|redhat-release|openssl-libs" <<<"$u" | paste -sd" ")）；其中 confluent-* $(grep -c "^confluent-" <<<"$u") 個；鎖住 $(sudo dnf -q versionlock list 2>/dev/null | grep -c confluent) 個 confluent 套件"; sudo dnf upgrade --assumeno 2>&1 | grep -E "^Upgrade +[0-9]+ Package"'; done
```

```out
under-replicated：0
kc01：OS 9.6，套件庫的 release 套件 9.8；可更新 148 個（平台相關：glibc openssh-server rocky-release systemd）；其中 confluent-* 0 個；鎖住 9 個 confluent 套件
Upgrade  148 Packages
（kb01、rest01、c3-01、ops02 同上，數字依各台裝的套件而不同；confluent-* 一律 0 個）
```

> 清單裡出現 `confluent-*` 就停下來：代表 versionlock 沒鎖好，照第 8 章重新鎖。Confluent 的升級只走第 21 章。每月修補時「套件庫的 release 套件」和目前的 OS 版本相同，可更新的數量就小得多（原本實測：6 個，含 openssh-server，修補過程中 ssh 連線不斷）。

## 26.2 broker 逐台

@role 小安 | ops02 | root

每台：更新 → 看要不要重開機、哪些平台服務要重啟 → 照判斷做 → 等健康、沒有 under-replicated 才下一台：

> Rocky 的陷阱（lab 實測）：9.8 的 `rocky-repos` 更新後，預設的 repo 檔（`rocky.repo` 等，走外網 mirrorlist）被裝回來並啟用，之後每個 `dnf` 都先去連外網而報 `Failed to download metadata for repo 'baseos'`。所以更新完立刻把它們關掉（下面腳本的那一行）。銀行的 RHEL 沒有這個問題。

```bash
cat > ~/conf/os-patch-host.sh <<'EOF'
#!/usr/bin/env bash
# 在一台主機上：dnf update（Confluent 由 versionlock 擋住）→ 判斷要不要重開機、哪些平台服務要重啟
n=$(sudo dnf -q check-update --refresh 2>/dev/null | grep -c '^[a-zA-Z0-9]')
os_before=$(. /etc/os-release; echo $VERSION_ID)
sudo dnf -y -q update >/dev/null 2>&1 || { echo "$(hostname) dnf update 失敗"; exit 1; }
# Rocky 專屬：rocky-repos 套件跟著更新，會把預設的 repo 檔（走外網 mirrorlist）裝回來並啟用，離線的 lab 要再關掉；RHEL 的 redhat.repo 由訂閱管理或 Satellite 管，不需要這行
sudo sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/rocky*.repo 2>/dev/null
reboot=$(sudo dnf needs-restarting -r >/dev/null 2>&1 && echo 否 || echo 是)
services=$(sudo dnf needs-restarting -s 2>/dev/null | grep -oE 'confluent-[a-z-]+|prometheus|alertmanager' | sort -u | paste -sd, -)
echo "$(hostname) 更新 $n 個；OS $os_before>$(. /etc/os-release; echo $VERSION_ID)；要重開機：$reboot；要重啟的平台服務：${services:-無}；confluent 版本：$(rpm -qa 'confluent-*' --qf '%{VERSION}\n' | sort -u | paste -sd, -)"
EOF
cat > ~/conf/os-reboot.sh <<'EOF'
#!/usr/bin/env bash
# os-reboot.sh <主機>：重開機並等 ssh 回來。主機是容器（lab）時 systemctl reboot 不能用，改重啟該主機的平台服務
h=$1
if ssh $h.poc.lab 'systemd-detect-virt -cq'; then
  echo "  $h 是容器，不能重開機：改重啟平台服務"
  ssh $h.poc.lab 'for u in confluent-server confluent-kafka-rest confluent-control-center; do systemctl cat $u >/dev/null 2>&1 || continue; [ $u = confluent-control-center ] && sudo systemctl restart prometheus alertmanager; sudo systemctl restart $u; done'
else
  ssh $h.poc.lab 'sudo systemctl reboot' 2>/dev/null; sleep 20
  for i in $(seq 1 60); do ssh -o ConnectTimeout=5 $h.poc.lab true 2>/dev/null && break; sleep 5; done
fi
EOF
chmod 0700 ~/conf/os-patch-host.sh ~/conf/os-reboot.sh && export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && for h in kb01 kb02 kb03 kb04; do out=$(ssh $h.poc.lab bash -s < ~/conf/os-patch-host.sh); echo "$out"; case $out in *要重開機：是*) bash ~/conf/os-reboot.sh $h;; *confluent-server*) ssh $h.poc.lab 'sudo systemctl restart confluent-server';; esac; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ] && [ "$(kafka-topics --bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:)" = 0 ] && break; sleep 10; done; echo "  $h MDS=$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"; done
```

```out
kb01 更新 148 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
  kb01 是容器，不能重開機：改重啟平台服務
  kb01 MDS=200
（4 台；正式環境沒有「是容器」那行，而是重開機後等 ssh 回來，每台多幾分鐘）
```

## 26.3 controller 逐台，leader 最後

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && Q="--bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 --command-config $HOME/conf/client-internal.properties" && leader=kc0$(kafka-metadata-quorum $Q describe --status 2>/dev/null | awk '/LeaderId/{print $2}') && for h in $(echo kc01 kc02 kc03 | tr ' ' '\n' | grep -vx $leader) $leader; do out=$(ssh $h.poc.lab bash -s < ~/conf/os-patch-host.sh); echo "$out"; case $out in *要重開機：是*) bash ~/conf/os-reboot.sh $h;; *confluent-server*) ssh $h.poc.lab 'sudo systemctl restart confluent-server';; esac; id=${h#kc0}; for i in $(seq 1 60); do [ "$(kafka-metadata-quorum $Q describe --replication 2>/dev/null | awk -v id=$id '$1==id {print $4}')" = 0 ] && break; sleep 5; done; echo "  $h Lag=$(kafka-metadata-quorum $Q describe --replication 2>/dev/null | awk -v id=$id '$1==id {print $4}')$([ $h = $leader ] && echo '（leader，最後做）')"; done
```

```out
kc02 更新 148 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
  kc02 Lag=0
kc03 更新 148 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
  kc03 Lag=0
kc01 更新 148 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
  kc01 Lag=0（leader，最後做）
```

## 26.4 REST Proxy、C3、操作機

@role 小安 | ops02 | root

REST 兩台先更新套件（這時不重啟），C3 修補期間畫面短暫不能用（只有一台），操作機最後、自己修自己；REST 的重啟在下面照 12.1 做：

```bash
for h in rest01 rest02; do ssh $h.poc.lab bash -s < ~/conf/os-patch-host.sh | tee ~/conf/patch-$h.out; done; for h in c3-01; do out=$(ssh $h.poc.lab bash -s < ~/conf/os-patch-host.sh); echo "$out"; case $out in *要重開機：是*) bash ~/conf/os-reboot.sh $h;; *confluent-kafka-rest*) ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest';; *confluent-control-center*|*prometheus*|*alertmanager*) ssh $h.poc.lab 'for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done';; esac; done; for i in $(seq 1 60); do [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ] && break; sleep 5; done; echo "  REST 經 LB=$(curl -s --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters) C3=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"; bash ~/conf/os-patch-host.sh
```

```out
rest01 更新 148 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
rest02 更新 148 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
c3-01 更新 148 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：2.6.1
  REST 經 LB=200 C3=200
ops02 更新 148 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
```


REST Proxy 的套件上面已經更新（JVM 不受影響）；重啟（或要重開機的話重開機）照 12.1 一台一台來。小版本更新時兩台一定是「要重開機：是」，這五步要做（`-r` 在 lab 的容器上自動改成重啟服務）；每月修補兩台都是「要重開機：否、要重啟的平台服務：無」時可以略過：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest01 $(grep -q '要重開機：是' ~/conf/patch-rest01.out && echo -r)
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up && bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02 $(grep -q '要重開機：是' ~/conf/patch-rest02.out && echo -r)
```

```out
rest02：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

> 每月修補的實測（2026-10-25，同一小版本內，lab）：11 台各 6 個 OS 套件（含 openssh-server，修補過程中 ssh 連線不斷），Confluent 版本都沒變、不用重開機、沒有平台服務要重啟；之後第 19 章驗收全過。openssh-server 更新後 sshd 由 RPM 自己重啟，所以 `-s` 雖然會列 sshd，這裡只看平台服務。

最後照第 19 章驗收一次（19.1–19.3）。

## 26.5 小版本更新（9.6 → 9.8）：驗證、限制、回滾、換成別的小版本

@role 小安 | ops02 | root

26.0–26.4 已經把每台更新完了。這一節是小版本更新特有的收尾。**開始前的前提**（26.0、26.1 已經確認）：銀行的套件庫有 9.8 的內容；Confluent 的 versionlock 數量等於已裝的 confluent 套件數、更新清單裡沒有 `confluent-*`；JDK 是 tar，`dnf` 碰不到。

**驗證**：每台的 OS 版本是 9.8、versionlock 數量沒變、服務是 active；叢集沒有 under-replicated；REST 經 LB 與 C3 都回 200：

```bash
export JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml && for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do ssh $h.poc.lab 'echo "$(hostname) $(. /etc/os-release; echo $PRETTY_NAME) 鎖 $(sudo dnf -q versionlock list | grep -c confluent)／裝 $(rpm -qa "confluent-*" | wc -l) $(for u in confluent-server confluent-kafka-rest confluent-control-center; do systemctl cat $u >/dev/null 2>&1 && echo "$u=$(systemctl is-active $u)"; done | paste -sd" ")"'; done; echo "ops02 $(. /etc/os-release; echo $PRETTY_NAME)"; echo "under-replicated：$(kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --describe --under-replicated-partitions 2>/dev/null | grep -c Partition:)；REST 經 LB=$(curl -s --cert ~/pki/certs/app-legacy-billing.crt --key ~/pki/keys/app-legacy-billing.key -o /dev/null -w '%{http_code}' https://rest.poc.lab:8082/v3/clusters) C3=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"
```

```out
kc01 Rocky Linux 9.8 (Blue Onyx) 鎖 9／裝 9 confluent-server=active
（kc02、kc03、kb01–kb04 同上；rest01、rest02 是「鎖 4／裝 4 confluent-kafka-rest=active」；c3-01 是「鎖 1／裝 1 confluent-control-center=active」）
ops02 Rocky Linux 9.8 (Blue Onyx)
under-replicated：0；REST 經 LB=200 C3=200
```

再跑一次第 19 章的驗收（19.1–19.3），結果要全數通過。持續流量（`install/tools/load.sh`）在更新期間的數字：直連應用程式遺失幾筆、經 LB 的 REST 失敗幾次，從零重跑後以實測為準（尚無實測）；REST 照 12.1 一台一台從 LB 停用再重啟，預期和第 21 章一樣沒有失敗。

**lab 做不到的事（要老實說）**：
- 容器不能重開機，kernel 沒有更新（容器沒有自己的核心）。lab 只驗證「套件更新的指令、順序、versionlock 擋住 Confluent、服務在新的 glibc／systemd 套件下重啟後是健康的」，**沒有驗證**重開機本身：開機順序、`fstab` 掛載、網卡命名、核心模組、`systemctl enable` 過的服務是否自己起來（19.4 的冷開機演練只涵蓋「容器一起停、一起開」，不是 OS 的開機）。
- Rocky 不是 RHEL：套件名稱、`needs-restarting` 的輸出與 RHEL 相同，但訂閱管理（`subscription-manager release --set`）、Satellite content view 的行為 lab 都沒有。
- 更新集合的大小（152 個、78 MB）是這批最小安裝主機的數字，真正的 RHEL 主機不同。

**回滾**：真正可行的答案是**更新前的快照**（VM 快照、LVM 快照或裸機映像），在 26.1 之前每台先做；小版本更新途中某台出問題，就還原那一台的快照，再照 26.2–26.4 重做。不要依賴 `dnf history undo`：它對 kernel、glibc、systemd 這類核心元件不可靠，而且 Red Hat 不支援把 RHEL 小版本降回去（`dnf downgrade` 整個小版本也一樣）。controller 或 broker 的機器整台壞了，走第 23 章（換 controller）或第 24 章（broker 加回）重建，不要硬救。Confluent 這一側不用回滾：版本沒動。

**換成別的小版本（例如銀行的套件庫是 9.4 → 9.6、9.2 → 9.4）**：步驟完全一樣，只要換三個值：(1) 26.0 銀行同步的目標版本；(2) 26.1 檢查「套件庫的 release 套件」是不是你要的那一版——**套件庫如果不是釘在特定小版本（例如直接追 RHEL 9 最新），`dnf update` 會一路更新到它有的最新小版本**，不是你以為的那一版，要請銀行把套件庫（或主機的 releasever）釘住；(3) 查原廠的 OS 支援表，確認該小版本在 Confluent Platform 8.3 的支援範圍內（原廠表上 RHEL 9.x 為支援；以銀行實際的版本對表）。`install/` 的對應是 `steps/26-os-patch.sh plan｜apply｜verify <版本>`，預設的 OS 版本在 `conf/site.env` 的 `OS_BASE_VERSION`、`OS_TARGET_VERSION`。

# 27. 第二十七站：單獨更換 Control Center 版本

**這一章在做什麼**：只換 C3 的版本，不動 Confluent Platform。前提：C3 已依第 13、21.3 裝好。順序：下載驗簽（27.1）→ 送進內網上架（27.2）→ 回滾程序演練（27.3，lab 專用）→ 升級（27.4）。

Control Center（Next Gen）有自己的版號（2.x），改版比 Confluent Platform 頻繁，可以單獨更換。遷移主線裡 C3 已經在 21.3 從 2.5.1 升到 2.6.1（那是 CP 升 8.3 的前提）；這一章是**之後**的情況：C3 出新的 2.6.x 修補版、或原廠要求換版本時，單獨處理，不動 CP。和第 21 章不同的地方：

| 項目 | 說明 |
|---|---|
| 相容性 | 先查原廠的相容表：新版 C3 要支援目前的 CP 版本（2.6.x：CP 7.5.15 到 8.3.x；2.5.x 只到 8.2.x，所以**不能**把已經是 8.3 的叢集的 C3 退回 2.5.x）。CP 要升級時，**C3 先升**（21.3） |
| 停機 | 只有一台：升級期間畫面約 1–2 分鐘不能用；broker、REST、應用程式不受影響（C3 只是看） |
| 資料 | 內建 Prometheus 的歷史指標在 C3 的資料目錄，換套件不會清掉 |
| JDK | C3 留在 JDK 21（21.7） |
| 回滾 | `dnf downgrade` 回舊版（舊版的 RPM 一直留在套件庫，第 4 章） |

lab 裡：已經是原廠最新的 2.6.1（21.3 升好的），所以演練是：先把 2.6.0 帶進來、退回 2.6.0（同時驗證回滾；2.6.0 也在 CP 8.3 的支援範圍內），再照正式程序升回 2.6.1。正式環境只要把版號換成新版、跳過 27.3。

## 27.1 下載、驗簽章

@role 小安 | dl01 | root

和第 1 章一樣指定精確版本；C3 的相依（`cyrus-sasl`、`openssl-devel`）來自銀行的 OS 套件庫，已經裝過，不用 `--resolve`。下載改成「`dnf` 只印出網址、`curl` 下載」：實測 `dnf download` 把這個約 1 GB 的 RPM 下載完整之後，行程常常不會結束（連線卡住）；`curl` 沒有這個問題。下載完用 `rpm -K` 驗簽章：

```bash
V=2.6.0 && mkdir -p /out/c3 && cd /out/c3 && rm -f ./*.rpm SHA256SUMS && curl -fsS -O "$(dnf -q download --url confluent-control-center-next-gen-$V | head -1)" && rpm -K ./*.rpm && sha256sum ./*.rpm > SHA256SUMS && ls
```

```out
./confluent-control-center-next-gen-2.6.0-1.noarch.rpm: digests signatures OK
SHA256SUMS
confluent-control-center-next-gen-2.6.0-1.noarch.rpm
```

## 27.2 引進、上架

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

照 2.4 的方式送到操作機的落地區（唯讀），進來後再驗一次 sha256：

```bash
docker cp "$(cygpath -m "$HOME/kafka-lab/landing/c3")" lab-ops02-1:/root/landing/ && docker exec lab-ops02-1 bash -c "chmod -R a-w /root/landing/c3 && cd /root/landing/c3 && sha256sum -c --quiet SHA256SUMS && echo sha256-ok"
```

```out
sha256-ok
```

@role 小安 | ops02 | root

加進內部套件庫（舊版不刪，回滾要用），只推 `confluent/` 這個目錄：

```bash
cp ~/landing/c3/*.rpm ~/repo/confluent/ && createrepo_c -q --update ~/repo/confluent && tar -C ~/repo -cf - confluent | ssh repodeploy@repo01.poc.lab 'tar -C /var/www/repo -xpf -' && ssh c3-01.poc.lab 'echo "套件庫裡的 C3：$(sudo dnf -q --refresh --showduplicates list confluent-control-center-next-gen 2>/dev/null | awk "/control-center/{print \$2}" | sort -u | paste -sd" " -)"'
```

```out
套件庫裡的 C3：2.5.1-1 2.6.0-1 2.6.1-1
```

## 27.3 （lab 演練用）退回 2.6.0：也就是回滾程序

@role 小安 | ops02 | root

步驟都在 21.3 建好的 `~/conf/c3-change.sh`（解鎖 → 換版本 → 鎖回 → `daemon-reload` → 4 個 generated 檔擁有者改回 `cp-control-center` → 確認設定檔沒被動 → 重啟 Prometheus、Alertmanager、C3 → 等畫面 200）。升級與回滾是同一段，只差 `dnf install` 或 `dnf downgrade`。腳本還沒有的話（單獨跑這一章時）先照 21.3 建：

```bash
[ -x ~/conf/c3-change.sh ] && bash ~/conf/c3-change.sh 2.6.0 downgrade
```

```out
confluent-control-center-next-gen-2.6.0-1.noarch config=same exec=/etc/confluent/control-center/control-center.properties lock=confluent-control-center-next-gen-0:2.6.0-1.*
UI=200（約 30 秒）；Prometheus 指標 125 種
```

## 27.4 升級到新版

@role 小安 | ops02 | root

```bash
bash ~/conf/c3-change.sh 2.6.1 install && ssh c3-01.poc.lab 'cd /etc/confluent-control-center && echo "C3 自己寫的 4 個檔：$(sudo stat -c %U alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml prometheus-generated-local.yml | sort -u | paste -sd, -)"' && echo "alice 登入 MDS（C3 用同一套）：$(curl -s -u alice:$(cat ~/secrets/ad-test-users.pass) -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/security/1.0/authenticate)"
```

```out
confluent-control-center-next-gen-2.6.1-1.noarch config=same exec=/etc/confluent/control-center/control-center.properties lock=confluent-control-center-next-gen-0:2.6.1-1.*
UI=200（約 35 秒）；Prometheus 指標 125 種（歷史指標沒有因換版本而消失）
C3 自己寫的 4 個檔：cp-control-center
alice 登入 MDS（C3 用同一套）：200
```

> 陷阱（lab 實測）：RPM 換版本（升級或退回）會把 `trigger_rules-generated.yml`、`recording_rules-generated.yml`、`prometheus-generated-local.yml` 改回 `root:root 644`。畫面照樣打得開，但之後在 C3 上改告警規則會寫不進去，所以 `c3-change.sh` 換完套件一定把這 4 個檔改回 `cp-control-center`（`prometheus-generated.yml` 是我們寫的，維持 root）。

最後用瀏覽器登入 C3 看一眼叢集總覽（lab：`https://localhost:19021`，alice）。
