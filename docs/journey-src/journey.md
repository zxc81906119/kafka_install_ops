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

# 0. 第零站：自己把 lab 建起來（只有練習用的 lab 需要）
> 這一章只有練習用的 lab 需要。正式環境的主機、AD、CA、套件庫都是銀行準備好的，直接從第 2 章開始。

下面這張圖是這一章要蓋出來的東西：先準備 Podman（0.0），再做映像檔與銀行的 AD、CA、套件庫、LB（0.1–0.5），再用一份 compose 檔起整個 lab（0.6），最後是下載機與日常操作（0.7–0.9）。

![labbuild]

@role Lab 管理員（扮演銀行） | Windows 終端（Git Bash） | 本機

這一章在你的 Windows 筆電上用 Podman 蓋出一整套模擬環境：十幾台假主機，加上扮演銀行的 AD、CA、套件庫、負載平衡。做完這一章之後，你就有一個可以照第 2 章以後逐章練習的環境。需要 Podman（CLI 與 WSL2 上的 machine，0.0 節）和 Git Bash。整個 lab 放在家目錄的 `kafka-lab/`，不依賴任何現成的專案；下面每個檔案都是用 heredoc 寫出來的，整段貼到 `EOF` 即可。

## 0.0 Podman 與 machine

**這一節在做什麼**（lab 專用）：準備跑容器的環境。Podman 在 Windows 上是「CLI＋一台 WSL2 上的 Linux（machine）」，容器都跑在 machine 裡。前提：Windows 已啟用 WSL2。完成的樣子：machine `kafka-lab` 是 rootful、`podman-restart` 已啟用、`podman compose version` 印得出版本。

**先手動做的三件事**（只做一次）：

1. 安裝 Podman Desktop（`choco install podman-desktop`，或 `podman-desktop.io` 的官方安裝檔），第一次開啟時照它的引導安裝 Podman（它下載的是官方的 Podman 安裝檔，需要系統管理員權限）。**引導提議建立 Podman machine 時跳過**：machine 照下面的指令建（要 rootful、名稱 `kafka-lab`）。裝完**重開一個 Git Bash**，`podman` 才會在 PATH 裡。不用 Podman Desktop 的話，也可以直接裝官方 GitHub releases（`github.com/containers/podman`）的 `podman-installer-windows-amd64.msi`（核對 `shasums`、數位簽章是 Red Hat, LLC）。
2. 準備 docker-compose（`podman compose` 會呼叫它）：在 Podman Desktop 的 Compose 擴充按「Set up…」，選裝到系統（system-wide）。它從官方 GitHub（`docker/compose`）下載 docker-compose，放到 `%LOCALAPPDATA%\Microsoft\WindowsApps\docker-compose.exe`（本來就在 PATH 上）；裝完**重開一個 Git Bash**。`podman compose` 沒有另外設定時就到 PATH 上找它，不用寫 `containers.conf`。
3. WSL2 的記憶體上限：`%UserProfile%\.wslconfig` 的 `[wsl2]` 寫 `memory=11GB`（16 GB 的筆電；整個 lab 約用 9–10 GB）。改完要 `wsl --shutdown` 才生效。

接著在 Git Bash（之後所有 Windows 端指令都在這個視窗）建 rootful 的 machine（容器要用 systemd、firewalld、固定 IP，rootless 做不到；記憶體由 `.wslconfig` 統一管，不用 `--memory`），並讓 machine 重開後自動把帶 `restart` 政策的容器拉起來（`podman-restart.service`，預設是關的）：

```bash
# 1. Git Bash 不要把 /etc/... 這類容器內的路徑轉成 Windows 路徑（每開一個新的 Git Bash 都要先執行這一行）
export MSYS_NO_PATHCONV=1

# 2. lab 的目錄
mkdir -p ~/kafka-lab/images/node ~/kafka-lab/images/web/tls ~/kafka-lab/images/ad ~/kafka-lab/images/lb
mkdir -p ~/kafka-lab/ca ~/kafka-lab/landing
cd ~/kafka-lab
pwd

# 3. 建 rootful 的 machine（已經建過就跳過）
#    先看清單裡有沒有 kafka-lab。清單是空的不代表失敗：還沒建過也是空的；if 看的是這個指令有沒有成功
if machines=$(podman machine list --format '{{.Name}}'); then
  if ! echo "$machines" | grep -qx kafka-lab; then
    podman machine init kafka-lab --rootful --cpus 8 > /dev/null
  fi
else
  echo "podman machine list 失敗：先看下面的陷阱，不要往下做"
fi

# 4. 開 machine（已經在跑就跳過）
state=$(podman machine inspect kafka-lab --format '{{.State}}')
if [ "$state" != running ]; then
  podman machine start kafka-lab > /dev/null 2>&1
fi

# 5. 之後的 podman 指令都連到這台 machine 的 root
podman system connection default kafka-lab-root

# 6. machine 重開後，自動拉起帶 restart 政策的容器
podman machine ssh kafka-lab "sudo systemctl enable podman-restart.service > /dev/null 2>&1"
enabled=$(podman machine ssh kafka-lab "systemctl is-enabled podman-restart.service" | tr -d '\r')
echo "podman-restart: $enabled"

# 7. 確認：rootless 要是 false，compose 要印得出版本
echo "rootless: $(podman info --format '{{.Host.Security.Rootless}}')"
podman compose version 2>/dev/null | tail -1
```

```out
/c/Users/<你>/kafka-lab
podman-restart: enabled
rootless: false
Docker Compose version v5.x.x
```

> `MSYS_NO_PATHCONV=1` 是讓 Git Bash 不要把 `/out`、`/etc/...` 這類容器內路徑轉成 Windows 路徑。給 Podman 的 Windows 路徑一律用 `$(cygpath -m …)` 產生。
>
> machine 不會隨 Windows 自己啟動（整個 lab 很吃資源，要用時才開）：要用 lab 時先跑 `podman machine start kafka-lab`，用完 `podman machine stop kafka-lab`。
>
> `podman compose` 每次會先印一行 `>>>> Executing external compose provider "…docker-compose.exe" … <<<<`：只是提示用的是 Podman Desktop 裝的那一份，不影響結果。docker-compose 的版本跟著 Podman Desktop 的擴充更新（2026-10-31 是 v5.6.1）。
>
> 陷阱：`podman machine start` 印出 `API forwarding for Docker API clients is not available … win-sshproxy.exe failed to start` 時，`podman` 本身照常可用，但 `podman compose` 會失敗（`failed to connect to the docker API at npipe:…`）。原因是負責轉發的 `win-sshproxy` 上次被強制結束（machine 還在跑就直接關機或重開 Windows），留下一個孤兒 socket 檔 `%LOCALAPPDATA%\Temp\podman\kafka-lab-api.sock`（Windows 事件記錄裡是 `bind: Only one usage of each socket address`）；`podman machine stop` 正常結束時會自己清掉它。所以**關 Windows 之前先 `podman machine stop kafka-lab`**。已經撞到了：把那個檔刪掉（Git Bash `rm`，或 PowerShell `Remove-Item`），再依序執行 `podman machine stop kafka-lab`、`podman machine start kafka-lab`，看到 `API forwarding listening on` 就好了。

不想每次手動刪檔，可以寫一支小修復腳本放在 `~/kafka-lab/start-lab.ps1`（只用英文字元：Windows PowerShell 5.1 讀沒有 BOM 的中文 .ps1 會語法錯誤）。它在沒有 `win-sshproxy` 時刪掉那個孤兒檔；machine 已經在跑但沒有轉發就先停掉；再開 machine，結果寫在旁邊的 `start-lab.log`。平常用不到，撞到上面的警告時才跑：

```bash
cat > ~/kafka-lab/start-lab.ps1 <<'EOF'
# start-lab.ps1 - start the Podman machine kafka-lab with working Docker API forwarding (needed by podman compose).
# If Windows was shut down while the machine was running, win-sshproxy was killed and left an orphaned AF_UNIX socket
# (%LOCALAPPDATA%\Temp\podman\kafka-lab-api.sock); the next start then has no npipe and `podman compose` fails.
# This script removes that file when no win-sshproxy is running, and (re)starts the machine. Log: start-lab.log next to this file.
$ErrorActionPreference = 'Continue'
$podman = Join-Path $env:LOCALAPPDATA 'Programs\Podman\podman.exe'
if (-not (Test-Path $podman)) { $podman = 'podman' }
$sock   = Join-Path $env:LOCALAPPDATA 'Temp\podman\kafka-lab-api.sock'
$log    = Join-Path $PSScriptRoot 'start-lab.log'
function Log($m) { $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m; $line | Out-File -FilePath $log -Append -Encoding utf8; $line }

$state = (& $podman machine inspect kafka-lab --format '{{.State}}' 2>$null)
$proxy = Get-Process -Name win-sshproxy -ErrorAction SilentlyContinue
if ($state -eq 'running' -and $proxy) { Log "already running with API forwarding (win-sshproxy pid $($proxy.Id))"; exit 0 }
if (-not $proxy -and (Test-Path $sock)) { Remove-Item $sock -Force; Log "removed orphaned $sock" }
if ($state -eq 'running') { Log "running without API forwarding: stopping first"; & $podman machine stop kafka-lab 2>&1 | ForEach-Object { Log "  $_" } }
& $podman machine start kafka-lab 2>&1 | ForEach-Object { Log "  $_" }
$proxy = Get-Process -Name win-sshproxy -ErrorAction SilentlyContinue
Log ("result: machine " + (& $podman machine inspect kafka-lab --format '{{.State}}' 2>$null) + ", API forwarding " + $(if ($proxy) { "ok" } else { "MISSING" }))
EOF
echo "start-lab.ps1：$(wc -l < ~/kafka-lab/start-lab.ps1) 行"
```

```out
start-lab.ps1：19 行
```

撞到時先關掉 Podman Desktop（它也會讀 machine 的狀態檔：lab 實測同時開著時撞到一次 `Error writing machine starting state … Access is denied`，之後 `podman machine list` 一直顯示 Currently starting），再在 PowerShell 執行（或在 Git Bash 前面加 `powershell `）：`powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\kafka-lab\start-lab.ps1"`，最後一行是 `result: machine running, API forwarding ok` 就好了。

> 陷阱（lab 實測）：Windows 記憶體不夠時（可用只剩幾百 MB），`podman machine inspect`、`list` 會失敗（`wsl.exe … exit status 143`）或卡住。先關掉 Podman Desktop 和吃記憶體的程式；還是不行就 `wsl --shutdown`（會停掉所有 WSL 發行版），再 `podman machine start kafka-lab`。

> 陷阱：Podman 的安裝程式會重設 WSL，正在跑的其他 WSL 發行版（例如 Docker Desktop）會被關掉。
>
> 硬體：16 GB 記憶體的筆電（上面的 `.wslconfig` 給 WSL 11 GB）；磁碟至少留 80 GB（2026-10-31 整本跑完：machine 的 `ext4.vhdx` 約 58 GB、`~/kafka-lab` 約 7 GB）。本書在 Podman 6.1.4、Windows 11 實測。
>
> 容器重開後會不會回來：machine 重開時，`podman-restart` 只拉起有 `restart` 政策的容器。compose 建的 14 台寫了 `restart: unless-stopped`；本書另外用 `podman run` 建的 dl01（0.7）與監控容器（17.6、22.2）也都帶 `--restart unless-stopped`。

## 0.1 主機映像檔：模擬「裸機 RHEL 9」

**這一節在做什麼**（lab 專用）：建出所有主機共用的映像檔 `lab-node:96`：Rocky 9.6 最小安裝 + systemd + sshd + sudo，sshd 只收金鑰、沒有密碼登入。前提：0.0 已做完（machine 起來了、目錄已建）。完成的樣子：build 印出 `Successfully tagged localhost/lab-node:96`，接著印出 `Rocky Linux release 9.6`。

和銀行開給我們的主機一樣：沒有 JDK、沒有 Confluent、公開 repo 關閉；安裝與維運用的帳號 `cpuser` 也不在映像裡，第 4 章才由銀行 OS 團隊建立。

> 重點：**Rocky 的 9.6 映像裡預設的 repo 設定指向「最新的 9.x」**（mirrorlist 用 `$releasever` = 9），不動它的話 `dnf install` 裝到的是 9.8 的套件。所以先換成 vault 的 9.6 倉庫（`dl.rockylinux.org/vault/rocky/9.6`），再 `dnf update` 到 9.6 的最新修補，主機才是乾淨的 9.6。映像、下載機、後面 5.1 銀行套件庫的內容都用同一份 vault 設定。映像的 tag 用 `lab-node:96`：舊的 9.8 映像（`lab-node:1`）不會被誤用。

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
cat > images/node/10-cp.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UseDNS no
EOF

cat > images/node/Dockerfile <<'EOF'
FROM rockylinux/rockylinux:9.6

# 1. 只留 vault 的 9.6 倉庫（映像原本的 repo 檔指向最新的 9.x）
COPY rocky-vault-96.repo /etc/yum.repos.d/rocky-vault-96.repo
RUN rm -f /etc/yum.repos.d/rocky.repo /etc/yum.repos.d/rocky-addons.repo /etc/yum.repos.d/rocky-devel.repo /etc/yum.repos.d/rocky-extras.repo

# 2. 更新到 9.6 的最新修補，裝主機要的基本工具
RUN dnf -y update
RUN dnf -y install systemd openssh-server openssh-clients sudo tar gzip openssl procps-ng nmap-ncat hostname iproute less which findutils dnf-plugins-core ca-certificates
RUN dnf clean all
RUN rm -f /etc/yum.repos.d/*.repo.rpmnew

# 3. sshd 只收金鑰、不收密碼，開機自動啟動
COPY 10-cp.conf /etc/ssh/sshd_config.d/10-cp.conf
RUN systemctl enable sshd

# 4. 容器裡用不到的 systemd 服務關掉
RUN systemctl mask systemd-logind.service getty.target console-getty.service systemd-udevd.service

# 5. 所有 repo 關掉：和銀行的主機一樣，公開的 repo 不能用
RUN sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/*.repo

STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
EOF

# 建映像：完整的輸出寫在 images/build-node.log；成功只印最後的 Successfully tagged，失敗就印最後 20 行
if podman build -t lab-node:96 "$(cygpath -m "$PWD/images/node")" > images/build-node.log 2>&1; then
  grep "^Successfully tagged" images/build-node.log
else
  tail -20 images/build-node.log
  false
fi

podman run --rm lab-node:96 cat /etc/rocky-release
```

```out
Successfully tagged localhost/lab-node:96
Rocky Linux release 9.6 (Blue Onyx)
```

映像裡沒有 cpuser，也沒有 sudo 規則：帳號、sshd 設定、公鑰、安裝期的完整 sudo（對應「變更窗口內由 OS 團隊開放」，正式環境做完要收回）都在 第 4 章 由銀行 OS 團隊的區塊做。

## 0.2 銀行的套件庫 web server（repo01）

**這一節在做什麼**（lab 專用）：建出模擬銀行套件庫的 web server 映像 `lab-web:96`，5.1 節與第 6 章把 OS 套件與 Confluent RPM 放上去。前提：0.1 的 `lab-node:96`（這個映像以它為底）。完成的樣子：build 印出 `Successfully tagged localhost/lab-web:96`。

模擬的是銀行自己管的 httpd：只有 HTTPS，唯讀；部署帳號 `repodeploy` 可以用 ssh 寫 `/var/www/repo`，沒有 sudo、沒有 `createrepo_c`：

```bash
cat > images/web/20-repo.conf <<'EOF'
Match User repodeploy
    AllowTcpForwarding no
    X11Forwarding no
EOF

cat > images/web/Dockerfile <<'EOF'
FROM lab-node:96

# 1. 裝 httpd（只在 build 時打開 vault 的 repo）
RUN dnf -y --enablerepo=vault96-baseos,vault96-appstream install httpd mod_ssl
RUN dnf clean all

# 2. 部署帳號 repodeploy：可以寫 /var/www/repo，ssh 不能轉發
RUN useradd -m -s /bin/bash repodeploy
RUN install -d -o repodeploy -g repodeploy -m 0755 /var/www/repo
COPY 20-repo.conf /etc/ssh/sshd_config.d/20-repo.conf

# 3. 只留 HTTPS：拿掉預設的歡迎頁、預設的 ssl.conf 和 80 埠，換成下面的 repo.conf
RUN rm -f /etc/httpd/conf.d/welcome.conf /etc/httpd/conf.d/ssl.conf
RUN sed -i 's/^Listen 80$/# Listen 80/' /etc/httpd/conf/httpd.conf
COPY repo.conf /etc/httpd/conf.d/repo.conf
RUN systemctl enable httpd
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
# 建映像：完整的輸出寫在 images/build-web.log；成功只印最後的 Successfully tagged，失敗就印最後 20 行
if podman build -t lab-web:96 "$(cygpath -m "$PWD/images/web")" > images/build-web.log 2>&1; then
  grep "^Successfully tagged" images/build-web.log
else
  tail -20 images/build-web.log
  false
fi
```

```out
Successfully tagged localhost/lab-web:96
```

憑證 `repo.crt`、`repo.key` 等銀行 CA 建好後再簽（0.5）。

## 0.3 銀行的 AD（Samba AD DC）

**這一節在做什麼**（lab 專用）：建出模擬銀行 AD 的映像 `lab-ad:1`，5.3 節在裡面建群組與帳號。前提：0.0 的 machine 已起來。完成的樣子：build 印出 `Successfully tagged localhost/lab-ad:1`。

RHEL 系的 Samba 沒有 AD DC 功能，所以這一台用 Debian。第一次啟動時建網域 `CORP.POC.LAB`，之後只是把 samba 跑著：

```bash
cat > images/ad/10-cp.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
UseDNS no
EOF

cat > images/ad/Dockerfile <<'EOF'
FROM debian:12-slim
ENV DEBIAN_FRONTEND=noninteractive

# 1. 裝 Samba AD DC 與管理工具
RUN apt-get update
RUN apt-get install -y --no-install-recommends samba samba-ad-dc samba-ad-provision winbind krb5-user ldb-tools ldap-utils openssh-server sudo procps ca-certificates openssl
RUN rm -rf /var/lib/apt/lists/*

# 2. 套件附的 smb.conf 刪掉：第一次啟動建網域時會重新產生
RUN rm -f /etc/samba/smb.conf

# 3. sshd 只收金鑰
RUN install -d -m 0755 /run/sshd
COPY 10-cp.conf /etc/ssh/sshd_config.d/10-cp.conf

# 4. 啟動程式（建網域、跑 samba）
COPY entrypoint.sh /usr/local/sbin/ad-entrypoint
RUN chmod 0755 /usr/local/sbin/ad-entrypoint

VOLUME ["/var/lib/samba", "/etc/samba"]
ENTRYPOINT ["/usr/local/sbin/ad-entrypoint"]
EOF

cat > images/ad/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
# ad-entrypoint：第一次啟動時建網域，之後一直把 samba 跑著（samba 停了就 2 秒後再開）
set -euo pipefail

# 1. 這三個環境變數由 compose 給（AD_ADMIN_PASSWORD 來自 secrets.env），少一個就停
: "${AD_REALM:?}" "${AD_DOMAIN:?}" "${AD_ADMIN_PASSWORD:?}"

# 2. 還沒有網域資料庫：建網域（TLS 憑證檔之後由 5.3 放進 tls/）
if [ ! -f /var/lib/samba/private/sam.ldb ]; then
  echo "[ad] provisioning domain ${AD_REALM}"
  rm -f /etc/samba/smb.conf
  samba-tool domain provision --use-rfc2307 --realm="${AD_REALM}" --domain="${AD_DOMAIN}" --server-role=dc \
    --dns-backend=SAMBA_INTERNAL --adminpass="${AD_ADMIN_PASSWORD}" --option="dns forwarder = 127.0.0.11" \
    --option="tls enabled = yes" \
    --option="tls keyfile = tls/key.pem" \
    --option="tls certfile = tls/cert.pem" \
    --option="tls cafile = tls/ca.pem"
fi

# 3. Kerberos 設定用網域產生的那一份，再開 sshd
cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
/usr/sbin/sshd

# 4. 跑 samba；停了（例如 5.3 換憑證時 pkill）就 2 秒後再開
while true; do
  echo "[ad] starting samba"

  if ! samba --foreground --no-process-group --debug-stdout; then
    echo "[ad] samba ended with an error"
  fi

  echo "[ad] samba exited, restarting in 2s"
  sleep 2
done
EOF

# 建映像：完整的輸出寫在 images/build-ad.log；成功只印最後的 Successfully tagged，失敗就印最後 20 行
if podman build -t lab-ad:1 "$(cygpath -m "$PWD/images/ad")" > images/build-ad.log 2>&1; then
  grep "^Successfully tagged" images/build-ad.log
else
  tail -20 images/build-ad.log
  false
fi
```

```out
Successfully tagged localhost/lab-ad:1
```

## 0.4 銀行的負載平衡（nginx L4）

**這一節在做什麼**（lab 專用）：建出模擬銀行負載平衡的 nginx 映像 `lab-lb:1`，5.4 節設定轉發到兩台 REST Proxy。前提：無。完成的樣子：build 印出 `Successfully tagged localhost/lab-lb:1`，接著印出 `4`（0.1–0.4 的四個映像都在）。

```bash
cat > images/lb/10-cp.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
UseDNS no
EOF

# nginx.conf 最後要加的一段：L4（stream）轉發的設定都放在 /etc/nginx/stream.d/（5.4 節寫）
cat > images/lb/stream.conf <<'EOF'

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF

cat > images/lb/lb-entrypoint <<'EOF'
#!/bin/sh
# lb-entrypoint：先開 sshd，再讓 nginx 在前景跑
/usr/sbin/sshd
exec nginx -g "daemon off;"
EOF

cat > images/lb/Dockerfile <<'EOF'
FROM nginx:1.28

# 1. 裝 sshd（LB 團隊的人要能登入）
RUN apt-get update
RUN apt-get install -y --no-install-recommends openssh-server sudo procps
RUN rm -rf /var/lib/apt/lists/*
RUN install -d -m 0755 /run/sshd
COPY 10-cp.conf /etc/ssh/sshd_config.d/10-cp.conf

# 2. nginx：加上 stream 區塊、拿掉預設的網站
RUN install -d -m 0755 /etc/nginx/stream.d
COPY stream.conf /tmp/stream.conf
RUN cat /tmp/stream.conf >> /etc/nginx/nginx.conf
RUN rm -f /tmp/stream.conf /etc/nginx/conf.d/default.conf

# 3. 啟動程式
COPY lb-entrypoint /usr/local/sbin/lb-entrypoint
RUN chmod 0755 /usr/local/sbin/lb-entrypoint
ENTRYPOINT ["/usr/local/sbin/lb-entrypoint"]
EOF

# 建映像：完整的輸出寫在 images/build-lb.log；成功只印最後的 Successfully tagged，失敗就印最後 20 行
if podman build -t lab-lb:1 "$(cygpath -m "$PWD/images/lb")" > images/build-lb.log 2>&1; then
  grep "^Successfully tagged" images/build-lb.log
else
  tail -20 images/build-lb.log
  false
fi

# 0.1–0.4 的四個映像都在：要印出 4
podman images --format '{{.Repository}}:{{.Tag}}' | grep -cE '(^|/)lab-(node:96|web:96|ad:1|lb:1)$'
```

```out
Successfully tagged localhost/lab-lb:1
4
```

## 0.5 銀行的 CA：根憑證、簽發 CA、簽發程序

@role 銀行 CA 窗口 | Windows 終端 | 本機

**這一節在做什麼**（lab 專用）：建出模擬銀行 CA 的兩層 CA 與簽發腳本 `sign.sh`，5.3 與 9.2 節用它簽憑證。前提：Git Bash 有 `openssl`。完成的樣子：`issuing.crt: OK`、印出根憑證的指紋，之後 `sign.sh` 幫 repo01 簽出 `repo.crt`。

正式環境這是銀行 CA 窗口的行內 PKI。lab 裡：用 openssl 建一個兩層 CA（根 CA 離線保存，簽發 CA 簽日常憑證）：

```bash
cd ~/kafka-lab/ca

# 1. 根 CA：私鑰與自簽的根憑證（20 年）
openssl genrsa -out root.key 4096 2>/dev/null
openssl req -x509 -new -key root.key -sha256 -days 7300 -out root.crt \
  -subj "/CN=PoC Bank Root CA/O=PoC Bank/C=TW" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"

# 2. 簽發 CA：私鑰與憑證申請（CSR）
openssl genrsa -out issuing.key 4096 2>/dev/null
openssl req -new -key issuing.key -sha256 -subj "/CN=PoC Bank Issuing CA 01/O=PoC Bank/C=TW" -out issuing.csr

# 3. 用根 CA 簽簽發 CA（10 年；pathlen:0 = 它只能簽一般憑證，不能再簽 CA）
cat > issuing.ext <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
openssl x509 -req -in issuing.csr \
  -CA root.crt -CAkey root.key -CAcreateserial \
  -days 3650 -sha256 \
  -extfile issuing.ext \
  -out issuing.crt 2>/dev/null
rm -f issuing.csr issuing.ext

# 4. 確認：簽發 CA 驗得過根 CA；印出根憑證的指紋
openssl verify -CAfile root.crt issuing.crt
openssl x509 -in root.crt -noout -fingerprint -sha256
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
# sign.sh <csr> <out.crt> — 銀行 CA 的簽發程序（lab 用）
# 做什麼：檢查憑證申請（CSR）合不合規定；合格就用這個目錄的簽發 CA 簽一年，輸出「憑證＋簽發 CA」
# 規定：CSR 的簽章正確、RSA 至少 2048 位元、有 CN、不是申請 CA、一定要帶 EKU 而且只能是 serverAuth／clientAuth；SAN 照 CSR 裡寫的
# 改的時候要注意：Git Bash 的 openssl 是 Windows 程式，看不懂 /c/Users/... 這種路徑，所以給 openssl 的路徑都先用 to_win 轉
set -euo pipefail

# 簽發 CA 的檔案和這支腳本放在同一個目錄
script_dir=$(dirname "$0")
ca_dir=$(realpath "$script_dir")
csr=$1
out=$2

# to_win <路徑>：Git Bash 上轉成 C:/Users/... 的寫法；沒有 cygpath（Linux）就原樣印出
#   例：to_win /c/Users/me/ca → C:/Users/me/ca
to_win() {
  if command -v cygpath > /dev/null; then
    cygpath -m "$1"
  else
    echo "$1"
  fi
}

# csr_ext <標題>：CSR 裡某一個 extension 的內容（openssl 把內容印在標題的下一行）
#   例：csr_ext "Subject Alternative Name" → DNS:repo01.poc.lab, DNS:repo01
csr_ext() {
  # lint-ok: 要取標題的下一行；用 grep 的話找不到標題時 set -e 會直接停，後面的檢查印不出原因
  openssl req -in "$csr" -noout -text | awk -v h="$1" 'f {gsub(/^ +/, ""); print; exit} index($0, h) {f=1}'
}

ca_dir=$(to_win "$ca_dir")
csr=$(to_win "$csr")
out=$(to_win "$out")

# 1. CSR 的簽章要正確
if ! openssl req -in "$csr" -noout -verify > /dev/null 2>&1; then
  echo "REJECT: CSR signature invalid"
  exit 1
fi

# 2. 金鑰至少 2048 位元
# 例：Public-Key: (2048 bit) → 2048
# lint-ok: 找不到時要是空值，不能讓 set -e 停下；用 grep 會停
bits=$(openssl req -in "$csr" -noout -text | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p')
if [ "${bits:-0}" -lt 2048 ]; then
  echo "REJECT: key < 2048"
  exit 1
fi

# 3. 要有 CN
subj=$(openssl req -in "$csr" -noout -subject -nameopt oneline | sed 's/^subject= *//')
if ! echo "$subj" | grep -q "CN = "; then
  echo "REJECT: no CN"
  exit 1
fi

# 4. 不能申請 CA
basic=$(csr_ext "Basic Constraints")
if echo "$basic" | grep -q "CA:TRUE"; then
  echo "REJECT: CA requested"
  exit 1
fi

# 5. EKU 一定要有，而且只能是 serverAuth、clientAuth 或兩個都有
eku=$(csr_ext "Extended Key Usage" | sed \
  -e 's/TLS Web Server Authentication/serverAuth/' \
  -e 's/TLS Web Client Authentication/clientAuth/' \
  -e 's/, /,/g')
if [ -z "$eku" ]; then
  echo "REJECT: extended key usage must be requested"
  exit 1
fi

case "$eku" in
  serverAuth | clientAuth | serverAuth,clientAuth | clientAuth,serverAuth) ;; # lint-ok: case 的選項，不是管線
  *)
    echo "REJECT: EKU $eku not allowed"
    exit 1
    ;;
esac

# 6. 簽發用的 extension 檔：SAN 照 CSR 裡寫的（沒有就不加）
san=$(csr_ext "Subject Alternative Name" | sed 's/IP Address:/IP:/g; s/, /,/g')
ext_tmp=$(mktemp)
ext_file=$(to_win "$ext_tmp")

echo "basicConstraints=critical,CA:FALSE" > "$ext_file"
echo "keyUsage=critical,digitalSignature,keyEncipherment" >> "$ext_file"
echo "extendedKeyUsage=$eku" >> "$ext_file"
echo "subjectKeyIdentifier=hash" >> "$ext_file"
echo "authorityKeyIdentifier=keyid,issuer" >> "$ext_file"

if [ -n "$san" ]; then
  echo "subjectAltName=$san" >> "$ext_file"
fi

# 7. 簽一年；輸出的檔案是「憑證＋簽發 CA」
openssl x509 -req -in "$csr" \
  -CA "$ca_dir/issuing.crt" \
  -CAkey "$ca_dir/issuing.key" \
  -CAcreateserial \
  -days 365 -sha256 \
  -extfile "$ext_file" \
  -out "$out.tmp" 2>/dev/null
rm -f "$ext_file"

cat "$out.tmp" "$ca_dir/issuing.crt" > "$out"
rm -f "$out.tmp"

echo "signed $(basename "$csr") -> $(basename "$out")  ($subj; EKU $eku)"
EOF

chmod +x ~/kafka-lab/ca/sign.sh
echo sign.sh ok
```

用它幫 repo01 簽 HTTPS 憑證（銀行自己的伺服器，私鑰直接放到映像會掛載的目錄）：

```bash
cd ~/kafka-lab

# 1. repo01 的私鑰與憑證申請（主機名稱放在 SAN，用途只有 serverAuth）
openssl req -new -newkey rsa:3072 -nodes -keyout images/web/tls/repo.key -out images/web/tls/repo.csr \
  -subj "/CN=repo01.poc.lab/O=PoC Bank/C=TW" \
  -addext "subjectAltName=DNS:repo01.poc.lab,DNS:repo01" \
  -addext "extendedKeyUsage=serverAuth" 2>/dev/null

# 2. CA 簽發，申請檔用完就刪
bash ca/sign.sh images/web/tls/repo.csr images/web/tls/repo.crt
rm -f images/web/tls/repo.csr
```

```out
signed repo.csr -> repo.crt  (CN = repo01.poc.lab, O = PoC Bank, C = TW; EKU serverAuth)
```

## 0.6 主機清單（compose）與密碼檔

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

**這一節在做什麼**（lab 專用）：用 podman compose 一次定義所有主機與網路，並產生共用的密碼檔。前提：0.1–0.5 的四個映像與 CA 都建好。完成的樣子：`podman ps` 數出 `14` 台容器。

14 台主機、一個不連外的內部網路。操作機有兩個專用的 volume：`ops-home`（掛在 `/root`，操作機上的工作目錄）和 `ops-secure`（掛在 `/secure/ssh`，模擬放 ssh 私鑰的**獨立 file system**：獨立的掛載點、容器重啟還在；LUKS 加密無法在 lab 模擬，所以沒有加密）。AD 的管理員密碼放在 `secrets.env`：

```bash
cd ~/kafka-lab

# 1. AD 管理員密碼：20 個英數字，不合格就重產；只產生一次（已經有 secrets.env 就沿用）
if [ ! -f secrets.env ]; then
  while true; do
    ad_password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)

    # 大寫、小寫、數字至少各有一個才算合格（AD 的密碼規則）
    upper=$(echo "$ad_password" | tr -dc 'A-Z' | wc -c)
    lower=$(echo "$ad_password" | tr -dc 'a-z' | wc -c)
    digit=$(echo "$ad_password" | tr -dc '0-9' | wc -c)

    if [ "$upper" -gt 0 ] && [ "$lower" -gt 0 ] && [ "$digit" -gt 0 ]; then
      break
    fi
  done

  touch secrets.env
  chmod 600 secrets.env
  echo "AD_ADMIN_PASSWORD=$ad_password" > secrets.env
  unset ad_password
fi

# 2. 主機清單（compose 檔）
cat > compose.yml <<'EOF'
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

# 3. 起整個 lab：數出幾台 Started（要是 14）
podman compose -f compose.yml up -d 2>&1 | grep -c Started
```

```out
14
```

`labnet` 是 `internal: true`：主機連不到外網，和銀行一樣。

> 陷阱：數字若是 13，通常是 lb01 第一次沒起來（它要同時接兩個網路），再下一次同樣的 `up -d` 就會補起來。

> 陷阱：若出現 `Pool overlaps with other one on this address space`，表示這台電腦的 Podman 已有其他網路用了 172.35 或 172.36 網段（`podman network ls` 逐一 `podman network inspect` 看 Subnet）。把 compose.yml 裡 `subnet:` 和所有 `extra_hosts` 的 IP 一起換成沒人用的網段（例如 172.37.0.0/24）再 `up -d`。

lb01 多接了一個 `frontnet` 並對應 Windows 的 18082、19021，讓 Windows 的瀏覽器連得到 REST Proxy 與 C3。

## 0.7 下載機

**這一節在做什麼**（lab 專用）：建出第 2 章用的外網下載機 dl01。前提：0.1 的映像。完成的樣子：`internet: 200`（容器裡連得到外網）。

下載機要能連外網，所以不在 `labnet` 裡；它的 `/out` 掛到 `~/kafka-lab/landing`，就是落地區。下載機用的 OS repo 也停在 9.6（vault），這樣第 2 章列給銀行的 OS 套件版本才是 9.6 的：

```bash
# 1. 起下載機：/out 掛到落地區
landing=$(cygpath -m "$HOME/kafka-lab/landing")
podman run -d --restart unless-stopped \
  --name dl01 --hostname dl01 \
  -v "$landing:/out" \
  lab-node:96 sleep infinity > /dev/null

# 2. 下載機的 OS repo 也用 vault 的 9.6
podman exec dl01 dnf config-manager --set-enabled vault96-baseos vault96-appstream vault96-extras

# 3. 確認連得到外網（要是 200）
podman exec dl01 curl -s -o /dev/null -w "internet: %{http_code}\n" https://packages.confluent.io/rpm/8.2/
```

```out
internet: 200
```

## 0.8 進入各台機器

**這一節在做什麼**（lab 專用）：整本手冊在 lab 切換主機都用 `podman exec`；正式環境則是人員經 PVWA＋PSMP 進操作機，再從操作機 ssh 到各台。前提：0.6、0.7 的容器都在跑。完成的樣子：三條指令各進得到一台機器的 shell。之後會一直用到的三條（換主機名稱即可）：

```bash
podman exec -it dl01 bash
```

```bash
podman exec -it -w /root lab-ops02-1 bash
```

```bash
podman exec -it lab-repo01-1 bash
```

第一個是下載機（root），第二個是操作機（root），第三個是銀行的主機（root，扮演銀行時用）。

**操作機一律以 root 進**：正式環境人員是在 CyberArk 的 PVWA 網頁選操作機、按連線，由 PSMP 代登進去，進去就是 root；lab 沒有 PVWA、PSMP，用上面第二條 `podman exec` 直接進，就等於「PSMP 代登之後」的狀態。連其他主機不靠 `podman exec`，而是在操作機上用 cpuser 的金鑰 ssh（第 4 章）。

## 0.9 收工與重開

**這一節在做什麼**（lab 專用）：暫停、繼續與重建 lab 的方法。前提：無。完成的樣子：`stop` 之後 `podman ps` 沒有 lab 容器，`start` 之後 14 台回來、Kafka 服務自己起來。

| 要做什麼 | 指令 | 說明 |
|---|---|---|
| 暫停 | `cd ~/kafka-lab`，再 `podman compose -f compose.yml stop` | 資料都在 volume 裡 |
| 繼續 | `cd ~/kafka-lab`，再 `podman compose -f compose.yml start` | — |
| Windows 重開機後 | `podman machine start kafka-lab`（machine 不會自己開）；14 台和下載機都帶 `restart: unless-stopped`，由 `podman-restart` 自己拉起來 | Kafka 服務設了 enable 也會自己起來 |
| 關 Windows 之前 | `podman machine stop kafka-lab` | 不停就關機會留下孤兒 socket，下次 `podman compose` 壞掉（0.0 的陷阱） |
| 操作機重開後 | 不用做 | `/secure/ssh` 的 volume 還在，金鑰不用重放（正式環境那個加密的 file system 要先解鎖、掛載好，ssh 才連得上各主機，見第 4 章） |
| 全部清掉重來 | 監控容器還在就先收（B.2 節），再 `cd ~/kafka-lab`、`podman compose -f compose.yml down -v`，最後 `podman rm -f dl01` | 落地區 `~/kafka-lab/landing` 不會被刪 |
| 連 machine 和下載的檔案也清掉，從完全空白開始 | `podman machine rm -f kafka-lab`（容器、volume、映像都在 machine 裡），再 `rm -rf ~/kafka-lab`，然後從 0.0 節開始 | 第 0 章的映像、第 2 章的 RPM 與 JDK、5.1 與第 30 章的 OS 內容、第 17 章的監控映像、第 31 章的 RPM 都要重新下載。OP menu 的交付物（16.3 節）不是下載來的，要放在 `~/kafka-lab` 以外 |

> 陷阱：要重跑第 0 章（重建映像、重產 CA）之前**一定先 `down -v`**。只 `down` 或直接再 `up -d` 會留下舊的 volume：操作機的 `~/pki`、`~/conf` 還是舊 CA 簽的、AD 裡帳號已存在，後面第 5、9 章會出現「鏈驗證失敗」「ou already exists」這類看似莫名的錯。

# 1. 開場：小安接到的任務

小安剛進公司，主管丟來一句話：「下週去銀行裝 Kafka，你跟著這本走一遍。」

銀行的環境完全離線，主機連不到外網；安裝用的套件要先在外面下載、驗證、送進去；主機、帳號、AD、憑證都是銀行各團隊準備的。小安要做的，是把 Confluent Platform 裝起來、設好安全、確認每個元件都健康。

這本手冊就是他走過的路。每一步都標明**誰做**、**在哪台機器**、**敲什麼**、**應該看到什麼**。
## 1.1 登場人物

![cast]

練習的時候，銀行端的角色沒有真人，由你自己扮演。看到橘色「銀行」標籤就切換身分，指令照樣敲，這樣流程才不會卡住；正式環境這些事是銀行做的，你只要知道他們做了什麼、怎麼確認。

## 1.2 環境地圖

![map]

| 主機 | 用途 | 誰管 |
|---|---|---|
| dl01 | 外網下載機，唯一能連 Internet 的機器 | 我方 |
| ops02 | 操作機：安裝起點，小安整天待在這裡；人員經 CyberArk（PVWA 網頁登入、PSMP 代登 ssh）登入就是 root，連各主機用 cpuser | 我方（root；連主機用 cpuser） |
| kc01、kc02、kc03 | KRaft controller | 我方安裝，銀行提供主機 |
| kb01–kb04 | Kafka broker | 同上 |
| rest01、rest02 | REST Proxy | 同上 |
| c3-01 | Control Center（含內建 Prometheus、Alertmanager，供 C3 自己的畫面用；銀行沒有 Prometheus 時兼做告警，見第 32 章） | 同上 |
| repo01 | 行內套件庫 web server，lab 裡兼 NTP | 銀行 |
| ad01 | 行內 AD（lab 用 Samba 模擬） | 銀行 |
| lb01 | 負載平衡（lab 用 nginx 模擬） | 銀行 |
| 行內監控（Prometheus、Alertmanager、Grafana） | 抓指標、發告警、看 dashboard；告警送到行內的事件系統（lab 用 `lab-mon-*` 四個容器模擬，第 17 章） | 銀行監控團隊 |
| PVWA、PSMP | CyberArk PAM：人員在 PVWA 網頁登入（AD 帳密＋MFA），由 PSMP 代登進操作機，進去就是 root。**這是本案和 CyberArk 唯一的關係**：平台的密碼與金鑰不放 CyberArk（lab 沒有 PVWA、PSMP，直接 `podman exec` 以 root 進） | 銀行 Secrets 團隊 |

所有主機的 FQDN 是 `<主機>.poc.lab`。

## 1.3 旅程總覽

![journey]

## 1.4 怎麼讀這本

- 稱呼：本手冊的「章」就是標題寫「第 N 站」的那一段（例如第 9 章 = 第九站），「節」是 9.1 這種小標；內文引用一律寫「第 N 章」或「N.M 節」。「操作機」就是主機名稱 ops02，內文叫操作機，指令與 `@role` 裡寫 ops02。「小安」是手冊裡的虛構新人，代表你。「行內」與「銀行」同義：行內的套件庫、AD 就是銀行準備的套件庫、AD。
- 綠色標籤 **我方**：小安敲的指令。橘色標籤 **銀行**：銀行各團隊的事，lab 裡由你代勞。
- 每個指令上方都有一行「▶ 在哪台（用哪個帳號）執行」。要換機器的那一個指令（以及每章第一個指令）會附上 lab 裡切過去的指令，例如 `podman exec -it -w /root lab-ops02-1 bash`；從一台容器換到另一台時，先 `exit` 回到 Git Bash 再切。正式環境進操作機是在 CyberArk 的 PVWA 網頁選目標、由 PSMP 代登（進去是 root）；從操作機連其他主機一律用 cpuser 的金鑰 ssh。
- 每個指令後面接「預期輸出」。看到的和預期不同就停下來，先弄懂再往下。
- 一行一個指令，整塊貼上即可；`#` 開頭的是步驟說明，貼上也不會執行。寫檔用的 `heredoc`（`<<'EOF' … EOF`）要連同最後的 `EOF` 一起貼。
- 「先檢查、再動手」的地方拆成兩塊：前一塊看到預期輸出，才做下一塊。檢查不過時，指令會印出原因並停在那裡：最後一行的 `false` 只是讓這一塊以失敗結束，不會關掉你的終端機。
- 密碼一律放在檔案裡（權限 0600）再讀進指令，不直接打在畫面上，也不要貼到任何對話裡。平台的密碼與金鑰只放在操作機 root 才讀得到的位置（`~/secrets`、`~/pki`、`/secure/ssh`），不放 CyberArk。需要人手動輸入時一律用**不顯示的寫法**（`read -rs`），PSMP 的錄影才不會錄到。
- **主線是「先裝基底、再遷移」**：第 2–19 章裝的是安裝基底，第 29、30 章把它遷移到目標版本（C3 在 29.3 一起升；第 31 章是之後單獨換 C3 版本的程序），每一段之後都跑第 19 章的驗收。兩組版本的來由與限制在下面「版本路徑」。
- 主線是本案客戶的情境：Kafka 平台和銀行的 CyberArk 已經脫鉤，只剩「人員在 PVWA 登入、由 PSMP 代登進操作機（root）」這一件事。平台的密碼、金鑰、憑證都在操作機上由 root 保管（0600／0400），操作機到各主機的 ssh 金鑰也是操作機自己的（第 4 章）。

- 看不懂沒關係，先照做；每一塊用註解編了步驟（`# 1.`、`# 2.`），每一章開頭說這章要做什麼，結尾說看到什麼代表成功。

> 陷阱：在各主機上（以 cpuser 登入）確認用的 `ls`、`stat` 看 `/etc/confluent/ssl`、`/var/lib/kafka` 這類 0750 的目錄要加 `sudo`，不然會 Permission denied，誤以為前一步失敗。操作機上你是 root，不需要。

### 版本路徑：安裝基底與遷移目標

下面這張圖把四層版本和遷移的先後順序畫在一起。

![versionpath]

| 層 | 安裝基底（第 2–19 章裝的） | 遷移目標（第 29、30 章） | 為什麼 |
|---|---|---|---|
| Confluent Platform | 8.2.4 | 8.3.2 | 第 29 章：套件滾動升級、finalize |
| Control Center | 2.5.1 | 2.6.1 | 原廠相容表：2.5.x 支援到 CP 8.2.x，2.6.x 才支援到 8.3.x，所以 CP 升 8.3 之前 C3 先升（29.3；單獨換 C3 是第 31 章） |
| JDK | 21 | 25 | 8.2.x 只支援 Java 17／21，**不支援 25**，所以基底一定是 21；8.3.x 才支援 25（原廠建議版本仍是 21）（29.7） |
| OS（RHEL 9） | 9.6 | 9.8 | 第 30.5 節：小版本更新；Confluent 與 JDK 被 versionlock、tar 擋住，只動 OS 套件 |

版本號直接寫在這本手冊的指令裡：安裝基底是 Confluent Platform 8.2.4、Control Center 2.5.1、JDK 21，遷移目標是 8.3.2、2.6.1、JDK 25。做完遷移後，之後新增或換掉主機要裝**現行版本**（29.10 節）。

**lab 的限制先講清楚**：lab 的主機是 Rocky Linux 9 的容器，不是 RHEL；容器共用 WSL2 的核心，不能真的重開機（30.5 會講怎麼替代）；Rocky 的 9.6 套件來自它的 vault 倉庫，9.8 來自現行倉庫。正式環境是銀行的 RHEL 9.x 與銀行自己的套件庫，版本以銀行實際的為準（問題清單有問）。

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
| mTLS | 雙向 TLS：連線兩端都出示憑證。broker 之間、REST Proxy 的應用程式、C3 內建的 Prometheus 都用它；銀行的 Prometheus 抓 7071 只用 HTTPS（第 17 章） |
| token（OAUTHBEARER） | MDS 發的短期通行證；C3、REST Proxy、操作機先用憑證向 MDS 換 token，再拿 token 進 TOKEN listener |
| CSR / SAN / EKU | 憑證申請單 / 憑證適用的主機名稱清單 / 憑證用途（serverAuth 給伺服器、clientAuth 給客戶端） |
| keystore / truststore | Java 用的憑證容器：keystore 放自己的私鑰和憑證，truststore 放信任的根憑證 |
| systemd drop-in | 不改 RPM 附的服務設定，另外放一個覆寫檔（`/etc/systemd/system/<unit>.service.d/`） |
| versionlock | dnf 的鎖版本插件，避免 OS 例行更新把 Confluent 升掉 |
| 落地區 | 外網下載好的檔案暫放的地方，經掃描核准後搬進內網 |
| CyberArk PAM | 銀行的特權帳號系統：管人與帳號。元件：Vault（保管庫）、PVWA（Password Vault Web Access，人用的網頁）、CPM（Central Policy Manager，定期自動換密碼；本案不用）、PSMP（Privileged Session Manager for SSH，代登 ssh 並錄影）。本案只用到 PVWA 與 PSMP：人員在 PVWA 網頁登入（AD 帳密＋MFA）、由 PSMP 代登進操作機（root）；平台的密碼與金鑰不放 CyberArk |
| cpuser | 每台主機（含操作機）同名的本機帳號，是安裝與維運的唯一 user：密碼鎖定、只收金鑰、UID／GID 都是 1500；操作機用 `/secure/ssh` 裡那一把私鑰連過去（第 4 章） |
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
| `/secure/ssh/` | 操作機連各主機用的 ssh 私鑰（獨立的加密 file system，root、0400；不是 `~` 底下，也不備份）。見 第 4 章 |

### 每一站大概要多久

| 章 | 時間 | 慢在哪 |
|---|---|---|
| 第 0 章 建 lab | 20–30 分 | 建映像檔要連外網下載 |
| 2 下載 | 60–90 分 | 兩套各約 3 GB 從外網抓；lab 的 Windows 資料夾讀寫慢 |
| 3–6 進內網、主機存取、銀行準備、上架 | 30 分 | 搬 6 GB、建索引 |
| 7–8 JDK、檢查、OS 調校、裝套件 | 30 分 | 11 台逐一 dnf install |
| 9 憑證 | 15 分 | — |
| 10–13 設定、啟動、權限、REST、C3 | 40 分 | 每段啟動要等健康檢查；C3 第一次起來 1–2 分鐘 |
| 14 基本功能驗收 | 10 分 | — |
| 15 Secret Protection（延伸） | 30 分 | 加密、派送、滾動重啟 |
| 16 OP menu（延伸） | 20 分 | 準備緊急憑證檔、裝選單、改 sudoers、三種身分試跑（選單全顯示，沒權限的做了被拒） |
| 17 監控（延伸） | 40 分 | 四種程序派送、滾動重啟（controller 與 broker 的指標要等 2 分鐘）、lab 的 Prometheus／Alertmanager／Grafana、告警測試 |
| 18 稽核日誌（延伸） | 20 分 | 帳號、加密派送、滾動重啟、製造事件 |
| 19 驗收與收尾 | 30 分 | 四組檢查；冷開機要等 3 分鐘 |
| 20 密碼與金鑰輪替 | 40 分 | master key 輪替與 AD 查詢密碼各一輪滾動重啟；換 SSH 金鑰要逐台放公鑰 |
| 21 憑證輪替 | 30 分／90 分 | leaf 換發一輪一次滾動重啟；換 CA 三階段要三次 |
| 22 憑證到期監控（選配） | 5 分 | 銀行 Prometheus 加 blackbox 探測與告警規則、promtool 測規則 |
| 23 日常備份與還原 | 15 分 | 還原演練：建演練物件、備份、誤刪、重建、驗證 |
| 24 磁碟與容量 | 5 分 | 用量與告警；演練要縮短 retention、搬 partition |
| 25 節點更換與增減 | 50 分 | 新 controller 要追上 metadata log；Self-Balancing 搬資料（加回後十幾分鐘才開始搬） |
| 26 license 監控 | 5 分 | — |
| 27 新應用上線 | 5 分 | SCRAM（A／B）與憑證各上線一個再下線；憑證要等銀行簽 |
| 28 故障排查速查 | 15 分 | 演練：停一台 broker 等告警 firing 再恢復；擋 8090 走緊急路徑 |
| 29 遷移到新版 | 70 分 | C3、套件一輪、JDK 一輪滾動重啟（每台 15 秒到 2 分鐘）；controller 要等 quorum 追上 |
| 30 OS 修補與小版本更新 | 10 分（每月修補）／30 分（9.6 → 9.8） | 逐台 dnf update；要重開機的話每台多幾分鐘 |
| 31 單獨換 C3 版本 | 10 分 | C3 只有一台，畫面約 1 分鐘不能用 |
| 附錄 B 監控覆蓋率、收 lab 監控 | 5 分 | — |

# 2. 第二站：外網下載機

![download]

**這一章在做什麼**：在唯一能連外網的下載機 dl01 上，把安裝要用的檔案抓齊、驗過簽章，整批打包成清單，下一章送進銀行內網。全部由我方（小安）做，不需要銀行配合；之後的主機都離線，缺了什麼檔案只能再回來這一章補。

小安的第一個任務：把 Confluent 的套件抓下來，而且只抓需要的。這次要抓**兩套**：安裝基底（Confluent Platform 8.2.4＋Control Center 2.5.1）放 `/out/rpm`，遷移目標（8.3.2＋2.6.1）放 `/out/rpm-target`，一次掃描、一次送進去，遷移（第 29 章）時就不用再開一次單。Java 和 OS 套件不下載，那是銀行的事（lab 的下載機只替銀行抓兩個 JDK，見 2.5）。

## 2.1 設定 Confluent repo、匯入原廠公鑰

先讓下載機信任 Confluent 的簽章公鑰、設好三個原廠 repo（8.2、8.3、Control Center），後面才能下載並驗證套件。

@role 小安 | dl01 | root

```bash
# 1. 放下載檔案的目錄
mkdir -p /out/rpm /out/rpm-target /out/gpg-keys /out/tools

# 2. 下載 Confluent 的簽章公鑰（Confluent Platform 一個網址、C3 一個網址）
curl -fsSL https://packages.confluent.io/rpm/8.2/archive.key -o /out/gpg-keys/confluent.asc
curl -fsSL https://packages.confluent.io/confluent-control-center-next-gen/rpm/archive.key \
  -o /out/gpg-keys/confluent-c3.asc

# 3. 匯入，確認 rpm 認得它
rpm --import /out/gpg-keys/confluent.asc /out/gpg-keys/confluent-c3.asc
rpm -q gpg-pubkey --qf '%{SUMMARY}\n' | grep -i confluent
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

# 要用的四個版本都在 repo 裡
dnf list --showduplicates confluent-server confluent-control-center-next-gen | grep -E '8\.(2\.4|3\.2)|2\.(5\.1|6\.1)'
```

```out
confluent-control-center-next-gen.noarch         2.5.1-1           confluent-c3
confluent-control-center-next-gen.noarch         2.6.1-1           confluent-c3
confluent-server.noarch                          1:8.2.4-1         confluent-8.2
confluent-server.noarch                          1:8.3.2-1         confluent-8.3
```

確認 8.2.4、8.3.2、2.5.1、2.6.1 四個都在清單裡就好（grep 只留了這四行）。

> **為什麼基底的 C3 是 2.5.1，不是最新的 2.6.1**（原廠相容表，docs.confluent.io「Versions and interoperability」，2026-10-28 查）：Control Center 2.5.x 支援 Confluent Platform「7.5.11 以上、7.6.8 以上，到 8.2.x」；2.6.x 才支援「到 8.3.x」（2.6.x 的下限寫 7.5.15 以上，所以 2.6.x 也能配 8.2.x）。安裝基底是 CP 8.2.4，用 2.5 系列最新的 2.5.1，**和 CP 的相容範圍剛好對上**；遷移到 8.3 之前 C3 必須先升到 2.6.x（29.3）。2.5.1 與 2.6.1 的 RPM 只相依 bash，套件預設設定檔（`/etc/confluent-control-center/`）逐檔比對只差 `control-center-dev.properties` 多一行 `confluent.controlcenter.docs.host`（我們不用 dev 檔），所以第 13 章的 Prometheus／Alertmanager 設定兩個版本通用。

> 上一個指令第一次執行會先下載 repo 的中繼資料（幾十 MB），等一兩分鐘是正常的。

## 2.2 下載：兩套精確版本

@role 小安 | dl01 | root

`--resolve` 會把 Confluent 自己的相依一起抓；因為下載機和正式主機是同樣最小安裝，它不會多抓也不會漏抓。**每一套只開自己的 repo**（`--disablerepo='*' --enablerepo=…`）：8.2 和 8.3 的 repo 同時開著時，`--resolve` 可能把另一版的 `confluent-common` 抓進來。先抓安裝基底到 `/out/rpm`：

```bash
dnf download --resolve --arch x86_64 --arch noarch --destdir /out/rpm \
  --disablerepo='*' --enablerepo=confluent-8.2,confluent-c3 \
  confluent-server-8.2.4 \
  confluent-security-8.2.4 \
  confluent-kafka-rest-8.2.4 \
  confluent-cli-8.2.4 \
  confluent-control-center-next-gen-2.5.1
```

再抓遷移目標到 `/out/rpm-target`：

```bash
dnf download --resolve --arch x86_64 --arch noarch --destdir /out/rpm-target \
  --disablerepo='*' --enablerepo=confluent-8.3,confluent-c3 \
  confluent-server-8.3.2 \
  confluent-security-8.3.2 \
  confluent-kafka-rest-8.3.2 \
  confluent-cli-8.3.2 \
  confluent-control-center-next-gen-2.6.1
```

每套約 3 GB。lab 裡：落地區是 Windows 資料夾，最後核對檔案那段會慢（看起來像卡在 99%），耐心等它結束。

```bash
for d in rpm rpm-target; do
  echo "== $d"
  ls /out/$d | sort
  ls /out/$d | wc -l
done
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

## 2.3 驗原廠簽章、確認相依

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
# 1. 所有 RPM 宣告的相依，去掉 Confluent 自己的和 rpm 內部用的
needs=$(rpm -qpR /out/rpm/*.rpm /out/rpm-target/*.rpm 2>/dev/null \
  | grep -vE '^(confluent-|rpmlib\(|config\()' \
  | sort -u)

# 2. 這些相依由哪些 OS 套件提供
echo "$needs" | xargs -d '\n' rpm -q --whatprovides | sort -u
```

```out
bash-5.1.8-9.el9.x86_64
glibc-2.34-168.el9_6.24.x86_64
（版本號依映像而異，重點是只有這兩個）
```

## 2.4 監控用的 jar 與官方規則、給銀行的 OS 套件清單

@role 小安 | dl01 | root

第 17 章的監控需要 JMX exporter（Prometheus 用的 Java agent jar）和 Confluent 官方的規則檔，這兩樣都不是 RPM，要另外抓。先抓 jar（1.7.0，從 GitHub release），核對 release 附的 sha256 與 GPG 簽章；舊版的 jar 先刪掉，第 17 章才不會同時抓到兩個：

```bash
# 1. 版本、檔名、下載位置、簽章金鑰的指紋
version=1.7.0
jar=jmx_prometheus_javaagent-$version.jar
base=https://github.com/prometheus/jmx_exporter/releases/download/$version
signer=90E3CDDECF99D81C0309D74CCADDBDF51122242E

# 2. 舊版的 jar 刪掉；下載 jar、它的 sha256 與簽章
rm -f /out/tools/jmx_prometheus_javaagent-*.jar
curl -fsSL -o /out/tools/$jar $base/$jar
curl -fsSL -o /tmp/$jar.sha256 $base/$jar.sha256
curl -fsSL -o /tmp/$jar.asc $base/$jar.asc

# 3. 核對 sha256（對不上就刪掉 jar，不帶進行內）
actual=$(sha256sum /out/tools/$jar | cut -d' ' -f1)
expected=$(cut -c1-64 /tmp/$jar.sha256)

if [ "$actual" = "$expected" ]; then
  echo jar-sha256-ok
else
  echo "jar 的 sha256 對不上，已刪掉：不要帶進行內"
  rm -f /out/tools/$jar
  false
fi

# 4. 核對 GPG 簽章：公鑰依指紋從 keys.openpgp.org 取（簽章不對就刪掉 jar）
curl -fsSL "https://keys.openpgp.org/vks/v1/by-fingerprint/$signer" | gpg --import 2>/dev/null

if gpg --status-fd 1 --verify /tmp/$jar.asc /out/tools/$jar 2>/dev/null | grep -q "VALIDSIG $signer"; then
  echo "jar-gpg-ok（簽章金鑰 $signer）"
else
  echo "jar 的簽章不是這把金鑰，已刪掉：不要帶進行內"
  rm -f /out/tools/$jar
  false
fi

# 5. 核對用的檔案刪掉
rm -f /tmp/$jar.sha256 /tmp/$jar.asc
```

```out
jar-sha256-ok
jar-gpg-ok（簽章金鑰 90E3CDDECF99D81C0309D74CCADDBDF51122242E）
```

> 1.1 版以後的 jar 只放在 GitHub release（Maven Central 的 `io.prometheus.jmx` 停在 1.0.1）。release 附 `.sha256` 與 `.asc`：sha256 對不上、或簽章不是這把金鑰（專案維護者 Doug Hoard，指紋 `90E3 CDDE CF99 D81C 0309 D74C CADD BDF5 1122 242E`，公鑰從 keys.openpgp.org 依指紋取）就不要帶進行內。銀行資安要核對來源時，給他們這個指紋。

Confluent 官方的監控檔（exporter 規則、告警規則、Grafana dashboard）在 GitHub 的 confluentinc/jmx-monitoring-stacks（Apache-2.0）。**固定在一個 commit**（`f376263f…`，2026-05-28），不跟 main 走：第 17 章的 dashboard 與規則是照這一版的指標名稱寫的。只取要用的路徑（32 個 dashboard、告警規則、controller／broker／REST 三份 exporter 規則），jar 不拿（用上面驗過的那個）。`COMMIT` 檔記下版本，之後每一關的 `SHA256SUMS` 也會涵蓋它們：

```bash
# 1. 固定的 commit；暫時解開的目錄
commit=f376263fc6d7270185ab6abab9a8c379079e2a92
mkdir -p /out/monitoring /tmp/jms-x

# 2. 下載這個 commit 的壓縮檔，只解開要用的路徑
archive_url="https://github.com/confluentinc/jmx-monitoring-stacks/archive/$commit.tar.gz"
curl -fsSL "$archive_url" | tar -xz -C /tmp/jms-x --wildcards \
  '*/LICENSE' \
  '*/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards/*' \
  '*/jmxexporter-prometheus-grafana/assets/grafana/provisioning/datasources/*' \
  '*/jmxexporter-prometheus-grafana/assets/prometheus/*' \
  '*/shared-assets/jmx-exporter/kafka_broker.yml' \
  '*/shared-assets/jmx-exporter/kafka_controller.yml' \
  '*/shared-assets/jmx-exporter/confluent_rest.yml' \
  '*/shared-assets/jmx-exporter/kafka_streams.yml'

# 3. 換掉舊的一份，記下 commit
rm -rf /out/monitoring/jmx-monitoring-stacks
mv /tmp/jms-x/jmx-monitoring-stacks-* /out/monitoring/jmx-monitoring-stacks
echo "$commit" > /out/monitoring/jmx-monitoring-stacks/COMMIT
rm -rf /tmp/jms-x

# 4. 結果：檔案數、dashboard 數
files=$(find /out/monitoring -type f | wc -l)
grafana_dir=/out/monitoring/jmx-monitoring-stacks/jmxexporter-prometheus-grafana/assets/grafana
dashboards=$(ls $grafana_dir/provisioning/dashboards/*.json | wc -l)
echo "commit $(echo $commit | cut -c1-12): $files 個檔，dashboard $dashboards 個"
```

```out
commit f376263fc6d7: 48 個檔，dashboard 32 個
```

平台還需要幾個 OS 套件，由銀行的套件庫提供。先確認它們都在 RHEL 標準 repo 裡、在哪個 repo，做成清單交給銀行。**版本號是下載機的 OS repo（停在 9.6，0.7）的內容**：銀行的套件庫之後同步到 9.8 時這幾個會更新（30.5）：

```bash
dnf -q repoquery --latest-limit 1 --qf '%{name}\t%{version}-%{release}\t%{repoid}' \
  chrony firewalld cyrus-sasl openssl-devel python3-dnf-plugin-versionlock gettext createrepo_c \
  | sort -u \
  | tee /out/os-packages.txt
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
| gettext、createrepo_c | 操作機 | `envsubst` 由範本產生設定檔；建內部套件庫的索引（第 6 章） |

銀行的 OS 套件庫本來就是完整的 RHEL，這份清單只是讓銀行確認這幾個在。lab 在 5.1 自己建 `/os/` 時多放了 httpd、jq、openldap-clients 等，那是 lab 主機自己要用的工具，不是交給銀行的需求。

## 2.5 順便替銀行抓 JDK（銀行交付的檔案）

@role 銀行 OS 團隊（lab 由下載機代勞） | dl01 | root

正式環境 JDK 是銀行交付的；lab 沒有銀行，就用這台下載機從 Adoptium 抓 Temurin，連同官方的 sha256 一起放到 `/out/bank/`，當作「銀行給的檔案」。**要兩個**：JDK 21 給安裝基底（7.1 節）；JDK 25 留到遷移（29.7）才裝——8.2.x 不支援 Java 25，所以基底一定是 21，但 25 先一起帶進來，遷移時不用再送一次：

```bash
mkdir -p /out/bank
cd /out/bank

for v in 21 25; do
  # 1. 問 Adoptium：這一版最新的 tar 在哪裡、官方的 sha256 是多少
  query="os=linux&architecture=x64&image_type=jdk&vendor=eclipse"
  meta=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/$v/hotspot?$query")

  # 第一筆 tar.gz 的網址；例 "link": "https://…/OpenJDK21U-….tar.gz" → 第 4 個雙引號欄位就是網址
  link_field=$(echo "$meta" | grep -o '"link": *"[^"]*\.tar\.gz"' | head -1)
  url=$(echo "$link_field" | cut -d'"' -f4)

  # 第一筆 sha256；例 "checksum": "0a1b…" → 第 4 個雙引號欄位就是 sha256
  checksum_field=$(echo "$meta" | grep -o '"checksum": *"[0-9a-f]\{64\}"' | head -1)
  sha=$(echo "$checksum_field" | cut -d'"' -f4)

  file=$(basename "$url")

  # 2. 官方的 sha256 存成旁邊的 .sha256 檔；已經有同一版而且對得上就不重抓，否則下載（斷線時最多重試 3 次）
  echo "$sha  $file" > "$file.sha256"

  need_download=yes
  if [ -f "$file" ]; then
    if sha256sum -c --quiet "$file.sha256" > /dev/null 2>&1; then
      need_download=no
    fi
  fi

  if [ $need_download = yes ]; then
    curl -fsSL --retry 3 --retry-all-errors --retry-delay 5 -o "$file" "$url"
  fi

  # 3. 核對（對不上就刪掉）
  if sha256sum -c --quiet "$file.sha256"; then
    echo "jdk-ok: $file"
  else
    echo "$file 的 sha256 對不上，已刪掉"
    rm -f "$file" "$file.sha256"
    false
  fi
done
```

```out
jdk-ok: OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz
jdk-ok: OpenJDK25U-jdk_x64_linux_hotspot_25.0.x_y.tar.gz
```

檔名裡的版本號跟著 Adoptium 當下的最新版走，之後的指令用 `OpenJDK21U-*`、`OpenJDK25U-*` 加萬用字元找它，不用改。

## 2.6 整批的雜湊清單

@role 小安 | dl01 | root

```bash
cd /out

# 落地區裡我方的檔案（不含銀行的 JDK、之後才送的 tools/opmenu），排好順序算 sha256
find rpm rpm-target tools gpg-keys monitoring -type f -not -path "tools/opmenu/*" \
  | LC_ALL=C sort \
  | xargs sha256sum > SHA256SUMS
wc -l SHA256SUMS
```

```out
73 SHA256SUMS
```

22 個 RPM（基底 11、目標 11）、1 個 jar、2 把公鑰、48 個官方監控檔（含 `COMMIT`）（JDK 是銀行的檔案，有自己的 sha256，不列在這裡）。這份 `SHA256SUMS` 之後每一關都會再用一次。下載機的工作到此結束。

# 3. 第三站：把東西送進銀行

![intake]

**這一章在做什麼**：把上一章打包好的檔案送進內網的操作機。路上有三道關：資安掃描（3.1，銀行資安）、檔案交換（3.2，銀行）、進內網後我方用 `SHA256SUMS` 再驗一次（3.3，小安）。這一章做完，操作機的 `~/landing` 就是之後所有安裝的唯一來源。

## 3.1 掃描與開單

@role 銀行 資安 | 行內掃描平台 | —

正式環境：落地區的檔案上傳到行內的惡意程式掃描平台取得 OK 報告，開單時附上安裝檔、掃描報告、`SHA256SUMS`。注意 `confluent-security`（約 1 GB）和 C3（約 1 GB）單檔都超過 1 GB，要先確認平台的大小上限；兩套合計約 6 GB。lab 裡：略過這一步。

## 3.2 檔案交換：送到操作機

下面這張圖說明落地區裡每個目錄是什麼、之後各自送去哪裡用。

![landing]

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

正式環境由行內的檔案交換平台把核准的檔案送到操作機的 `~/landing`（root 的家目錄底下）。lab 裡：用 `podman cp` 模擬這個平台（`podman cp` 不會自動建立目的目錄，所以先建 `~/landing`）；送進去之後把目錄設成唯讀（對 root 其實擋不住寫入，只是約定「落地區的檔案不改」）：

```bash
# 1. 操作機上的落地區目錄（podman cp 不會自己建）
podman exec lab-ops02-1 install -d -m 0700 /root/landing

# 2. 整個落地區複製過去
landing=$(cygpath -m "$HOME/kafka-lab/landing")
podman cp "$landing/." lab-ops02-1:/root/landing/

# 3. 設成唯讀；數檔案、看大小
podman exec lab-ops02-1 chmod -R a-w /root/landing
podman exec lab-ops02-1 bash -c 'find /root/landing -type f | wc -l'
podman exec lab-ops02-1 du -sh /root/landing
```

```out
83
6.9G	/root/landing
```

79 個檔：兩套 RPM 各 11、1 個 jar、2 把公鑰、48 個官方監控檔、`SHA256SUMS`、`os-packages.txt`、`bank/` 的兩個 JDK 各兩個檔（tar 與 .sha256）。lab 重跑時落地區可能已有第 16 章的 `tools/opmenu/`、第 31 章的 `c3/`（各 2 個檔），會是 83 個。

## 3.3 進內網後再驗一次

@role 小安 | ops02 | root

這是第二道驗證（第一道是 dl01 上的 2.6）：證明搬運途中沒被動過，用的是一起送進來的 `SHA256SUMS`。看到 `73 files OK` 才往下；有任何一個檔不符就退回銀行重送，不要裝：

```bash
cd ~/landing

# 不符的檔案會一個一個列出來（--quiet：相符的不印）
if sha256sum -c --quiet SHA256SUMS; then
  echo "$(wc -l < SHA256SUMS) files OK"
else
  echo "有檔案和 SHA256SUMS 不符：退回銀行重送，不要往下做"
  false
fi
```

```out
73 files OK
```

接著再驗一次原廠簽章。`rpm -K` 只認 rpm 資料庫裡的公鑰，所以先把隨包送進來的公鑰匯入（22 個 RPM 都要是 `digests signatures OK`）：

```bash
rpm --import ~/landing/gpg-keys/confluent.asc ~/landing/gpg-keys/confluent-c3.asc
rpm -K ~/landing/rpm/*.rpm ~/landing/rpm-target/*.rpm
```

```out
/root/landing/rpm/confluent-ce-kafka-http-server-8.2.4-1.noarch.rpm: digests signatures OK
（22 行都 OK）
```

## 3.4 之後再帶進來的檔案

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

延伸章節還會陸續帶檔案進來：16.3 的選單套件（`tools/opmenu`）、第 31 章單獨換 C3 版本時的單一 RPM。遷移用的新版 RPM 與 JDK 25 已經在第 2、3 章一起進來了（`rpm-target/`、`bank/`），第 29 章只是把它們上架。流程和第 3 章一樣（掃描、交換、進來後驗 sha256），只是一次送一個目錄。`~/landing` 是唯讀的，所以放進去再收回寫入權限（`D` 換成要送的目錄）；操作機上已經有同名的目錄會先清掉再送，所以同一個目錄換新版也是這一條。落地區還沒有那個目錄就什麼都不做：

```bash
D=opmenu   # 要送的目錄（落地區 tools/ 底下）
src="$HOME/kafka-lab/landing/tools/$D"
dest=/root/landing/tools/$D

if [ ! -d "$src" ]; then
  echo "落地區還沒有 tools/$D（有檔案要送時再做）"
else
  # 1. 操作機上同名的舊目錄先清掉（落地區是唯讀的，要先打開寫入權限）
  if podman exec lab-ops02-1 test -d "$dest"; then
    podman exec lab-ops02-1 chmod -R u+w "$dest"
    podman exec lab-ops02-1 rm -rf "$dest"
  fi

  # 2. 送過去，再收回寫入權限
  podman cp "$(cygpath -m "$src")" lab-ops02-1:/root/landing/tools/
  podman exec lab-ops02-1 chmod -R a-w "$dest"

  # 3. 在操作機上核對 sha256
  podman exec lab-ops02-1 ls "$dest"

  if podman exec -w "$dest" lab-ops02-1 sha256sum -c --quiet SHA256SUMS; then
    echo sha256-ok
  else
    echo "sha256 對不上：請我方重送，不要裝"
    false
  fi
fi
```

```out
SHA256SUMS
opmenu-20261023.0655fe43.tar.gz
sha256-ok
```

# 4. 第四站：主機存取：cpuser 與 SSH 金鑰
下面這張圖畫的是：人怎麼進操作機，操作機又怎麼連到每一台主機。

![access]

**這一章在做什麼**：先由銀行 OS 團隊在每台主機建好安裝帳號 `cpuser`，小安在操作機產生 SSH 金鑰對，OS 團隊把公鑰放進每台主機，最後驗證「只有操作機能用這把金鑰登入」。這一節把「人怎麼進操作機」和「操作機怎麼連各主機」分開：

| 項目 | 做法 |
|---|---|
| 人怎麼進操作機 | 人員用瀏覽器登入 CyberArk 的 PVWA 網頁（自己的 AD 帳密加 MFA），選操作機的目標帳號按連線，由 PSMP 代登進操作機，進去就是 **root**；全程錄影，人員不需要知道 root 的密碼。沒有另外的堡壘機 |
| 連各主機用誰 | 每台主機（含操作機自己）都有同名的本機帳號 **`cpuser`**：UID／GID 固定 1500、家目錄 `/home/cpuser`、密碼鎖定、sshd 對它關閉密碼驗證，只收金鑰。人員永遠是 AD 帳號；連主機的不是人，是操作機用金鑰代表的 cpuser |
| 金鑰 | 一組 ed25519 金鑰對，**私鑰只在操作機**：放在獨立（加密）的 file system `/secure/ssh`（名稱只是範例），擁有者 root、0400、沒有 passphrase。操作機到所有主機（含自己）都用它。**不放 CyberArk、不另外備份**：操作機重建就重新產生，由 OS 團隊重新佈署公鑰 |
| 公鑰 | OS 團隊依變更單放進每台 cpuser 的 `authorized_keys`，前面只加來源限制 `from="操作機 IP,127.0.0.1,::1"`（不加 `restrict`、`pty`） |
| sudo | 安裝與升級期 cpuser 全權（`/etc/sudoers.d/cpuser`，OS 團隊依變更單開、交付時移除）；交付後只剩 16.4 的 `cpuser-ops` |
| 追溯 | 誰在什麼時間進了操作機的 root：CyberArk 的登入紀錄與 PSMP 錄影；各主機上看到的是 cpuser 的操作紀錄 |

lab 裡：正式環境才有的三樣東西，這樣模擬：
- **沒有 PVWA、PSMP**：你用 `podman exec -it -w /root lab-ops02-1 bash` 直接以 root 進操作機，就是「PSMP 代登之後」。平台的密碼與金鑰不放 CyberArk，所以 lab 也不需要模擬保管庫。
- **沒有 LUKS**：`/secure/ssh` 是 0.6 compose 裡的獨立 podman volume `ops-secure`，只模擬「獨立的 file system」（獨立掛載點、容器重啟還在），沒有加密。
- **密碼與金鑰的輪替**都是人手動做（20.2–20.6），沒有任何自動輪替。
## 4.1 每台主機建 cpuser（銀行 OS 團隊）

@role 銀行 OS 團隊（每台主機依變更單做；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

每台主機（含操作機）以 root 做三件事：建帳號（UID／GID 固定 1500，不設密碼，useradd 預設就是鎖定）、sshd 設定、安裝期的全權 sudo。公鑰等操作機產生金鑰後（4.3）再放。lab 對每個容器各跑一次：

```bash
# 每台主機上執行 EOF 之前的那一段（bash -e：其中任何一行失敗就停）
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  podman exec -i lab-$h-1 bash -e -s <<'EOF'
# 1. 帳號：UID／GID 固定 1500，不設密碼（useradd 預設就是鎖定）
groupadd -g 1500 cpuser
useradd -u 1500 -g 1500 -m -s /bin/bash cpuser

# 2. sshd：cpuser 不收密碼，只收金鑰
cat > /etc/ssh/sshd_config.d/50-cpuser.conf <<'CONF'
Match User cpuser
    PasswordAuthentication no
    AuthenticationMethods publickey
CONF
sshd -t
systemctl reload sshd

# 3. 安裝期的全權 sudo（交付時移除）
echo 'cpuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/cpuser
chmod 0440 /etc/sudoers.d/cpuser
visudo -cf /etc/sudoers.d/cpuser > /dev/null

echo "$(hostname): $(id cpuser)"
EOF
done
```

```out
ops02: uid=1500(cpuser) gid=1500(cpuser) groups=1500(cpuser)
（每台一行）
```

`/etc/sudoers.d/cpuser` 是安裝與升級期的全權規則，對應「變更窗口內由 OS 團隊開放」；交付時移除，只留 16.4 的窄規則。`repodeploy` 是套件庫（repo01）的部署帳號，映像裡就有，下面和 cpuser 用同一把金鑰。

## 4.2 在操作機建金鑰對

@role 小安 | ops02 | root

私鑰放在獨立的 file system `/secure/ssh`（正式環境由 OS 團隊掛載並加密、備份排除這個掛載點；沒掛載好就不要建，不然私鑰會落在系統碟）。先確認它是獨立的掛載點，再建金鑰：註解帶建立日期，換金鑰時用來分辨新舊兩把（20.5）。

```bash
mountpoint /secure/ssh
```

```out
/secure/ssh is a mountpoint
```

看到 `is a mountpoint` 才建金鑰（印的是 `is not a mountpoint` 就停下來，請 OS 團隊先掛好）：

```bash
# 1. 放私鑰的目錄
install -d -m 0700 /secure/ssh

# 2. 建金鑰對（已經有就不重建）；註解帶建立日期，換金鑰時用來分辨新舊（20.5）
if [ ! -f /secure/ssh/cpuser_ed25519 ]; then
  ssh-keygen -q -t ed25519 -N '' -C "cpuser-ops-$(date +%Y%m%d)" -f /secure/ssh/cpuser_ed25519
fi

chmod 0400 /secure/ssh/cpuser_ed25519

# 3. 確認擁有者與權限
stat -c '%U:%G %a %n' /secure/ssh /secure/ssh/cpuser_ed25519 /secure/ssh/cpuser_ed25519.pub
```

```out
root:root 700 /secure/ssh
root:root 400 /secure/ssh/cpuser_ed25519
root:root 644 /secure/ssh/cpuser_ed25519.pub
```

再告訴 ssh：連 `*.poc.lab`（含操作機自己，用 `localhost` 連時 ssh 也走這條）一律用 cpuser 與這把金鑰。之後所有 `ssh kb01.poc.lab`、`scp` 都不用再帶帳號與 `-i`：

```bash
install -d -m 0700 ~/.ssh

# 已經加過（有 "# cpuser-ops" 那一行）就不再加
if ! grep -q '^# cpuser-ops' ~/.ssh/config 2> /dev/null; then
  cat >> ~/.ssh/config <<'EOF'
# cpuser-ops：操作機連各主機一律用 cpuser 與這把金鑰
Host *.poc.lab localhost
  User cpuser
  IdentityFile /secure/ssh/cpuser_ed25519
  IdentitiesOnly yes
EOF
fi

chmod 0600 ~/.ssh/config
grep -c . ~/.ssh/config
```

```out
5
```

## 4.3 公鑰放進每台主機（銀行 OS 團隊）

下面這張圖列出這把金鑰相關的每個檔案放在哪裡、權限多少、誰放的。

![keyfiles]

@role 銀行 OS 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

小安把公鑰（`/secure/ssh/cpuser_ed25519.pub`，不是祕密）交給 OS 團隊。OS 團隊依變更單放進**每台主機 cpuser 的 `~/.ssh/authorized_keys`（含操作機自己）**，以及 repo01 的 repodeploy。公鑰前面只加一個選項 `from=`：只有操作機的位址能用這把金鑰（寫 IP，不寫主機名稱，避免 DNS 異常誤擋）。**整行不換行，多個來源用逗號分隔、不加空格**：

```
from="10.20.1.10,127.0.0.1,::1" ssh-ed25519 AAAA…（金鑰內容） cpuser-ops-20261027
```

操作機連自己時，sshd 看到的來源可能是操作機本身的 IP、`127.0.0.1` 或 `::1`（用 `localhost` 連時 ssh 先走 IPv6），三個都要列。lab 的操作機 IP 是 172.35.0.10。目錄 0700、檔 0600、擁有者 cpuser：

```bash
# 1. 要放的那一行：公鑰前面加 from=（只有操作機的位址能用）
pub=$(podman exec lab-ops02-1 cat /secure/ssh/cpuser_ed25519.pub)
line="from=\"172.35.0.10,127.0.0.1,::1\" $pub"

# 2. 每台主機 cpuser 的 authorized_keys（目錄 0700、檔 0600、擁有者 cpuser）
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  podman exec lab-$h-1 install -d -m 0700 -o cpuser -g cpuser /home/cpuser/.ssh
  echo "$line" | podman exec -i lab-$h-1 \
    install -m 0600 -o cpuser -g cpuser /dev/stdin /home/cpuser/.ssh/authorized_keys
done

# 3. repo01 的部署帳號 repodeploy 也用這一把
podman exec lab-repo01-1 install -d -m 0700 -o repodeploy -g repodeploy /home/repodeploy/.ssh
echo "$line" | podman exec -i lab-repo01-1 \
  install -m 0600 -o repodeploy -g repodeploy /dev/stdin /home/repodeploy/.ssh/authorized_keys

# 4. 放進去的那一行（金鑰內容省略）
echo "$line" | sed 's/AAAA[^ ]*/AAAA…/'
```

```out
from="172.35.0.10,127.0.0.1,::1" ssh-ed25519 AAAA… cpuser-ops-20261027
```

## 4.4 驗證：登得進去、密碼鎖定、sshd 只收金鑰

@role 小安 | ops02 | root

逐台連一次（第一次連線會把對方的主機金鑰記進 `known_hosts`），順便看帳號是 cpuser、UID 是 1500、有安裝期 sudo、密碼是鎖定的（`/etc/shadow` 的密碼欄以 `!` 開頭）、sshd 對 cpuser 關閉密碼驗證且只收 publickey：

```bash
# 每台主機上執行 EOF 之前的那一段，各印一行
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new $h.poc.lab bash -s <<'EOF'
# 1. 有沒有安裝期的 sudo
if sudo -n true 2> /dev/null; then
  has_sudo=yes
else
  has_sudo=no
fi

# 2. /etc/shadow 密碼欄的前兩個字（!! = 鎖定）
password_field=$(sudo getent shadow cpuser | cut -d: -f2 | cut -c1-2)

# 3. sshd 對 cpuser 實際生效的設定：要不要密碼、允許哪些驗證方式
sshd_config=$(sudo sshd -T -C user=cpuser,host=localhost,addr=127.0.0.1)
password_auth=$(echo "$sshd_config" | awk '/^passwordauthentication /{print $2}')
auth_methods=$(echo "$sshd_config" | awk '/^authenticationmethods /{print $2}')

echo "$(id -un) $(hostname) uid=$(id -u) sudo=$has_sudo 密碼欄=$password_field sshd=$password_auth $auth_methods"
EOF
done

# repo01 的部署帳號也登得進去（/var/www/repo 這時還是空的）
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new repodeploy@repo01.poc.lab 'hostname; ls /var/www/repo'
```

```out
Warning: Permanently added 'ops02.poc.lab' (ED25519) to the list of known hosts.
cpuser ops02 uid=1500 sudo=yes 密碼欄=!! sshd=no publickey
（每台一句 Warning 加一行）
repo01
```

清單包含操作機自己（之後的迴圈會 `ssh ops02` 檢查自己這台）。第一次連線的 `Warning: Permanently added …` 是把主機金鑰記進 `known_hosts`，不是錯誤。repo01 的 `/var/www/repo` 這時還是空的，下一站才會放東西。

## 4.5 驗證：別台用這把私鑰連不進來

@role 小安（把私鑰副本放到 kb01 去用，模擬私鑰被複製；lab 由 Windows 終端代做） | Windows 終端 | 本機

`from=` 的用意：就算私鑰被複製到別處，也只有操作機能用。把私鑰副本放到 kb01、從 kb01 連 kb02，應該被拒；kb02 的 sshd 日誌會寫下「不是來自允許的主機」。驗完立刻刪掉副本：

```bash
# 1. 把私鑰副本放到 kb01（模擬私鑰被複製）
podman exec lab-ops02-1 cat /secure/ssh/cpuser_ed25519 \
  | podman exec -i lab-kb01-1 install -m 0600 /dev/stdin /tmp/copied-key

# 2. 從 kb01 用這把副本連 kb02：應該被拒（失敗才是對的，所以放在 if 裡）
if podman exec lab-kb01-1 ssh -F /dev/null -i /tmp/copied-key \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  cpuser@kb02.poc.lab true 2> /tmp/ssh-result.txt; then
  result=允許
else
  result=拒絕
fi

# 3. 驗完立刻刪掉副本
podman exec lab-kb01-1 rm -f /tmp/copied-key

# 4. ssh 最後一行訊息；被允許的話就是 from= 沒有生效
tail -1 /tmp/ssh-result.txt
rm -f /tmp/ssh-result.txt

if [ "$result" = 允許 ]; then
  echo "連進去了：from= 沒有生效，檢查 kb02 的 authorized_keys"
  false
fi

# 5. kb02 的 sshd 日誌：不是來自允許的主機
sshd_log=$(podman exec lab-kb02-1 journalctl -u sshd --no-pager -n 30)
denied_line=$(echo "$sshd_log" | grep -o 'not from a permitted host.*' | tail -1)
echo "$denied_line" | cut -c1-90
```

```out
cpuser@kb02.poc.lab: Permission denied (publickey).
not from a permitted host (host=172.35.0.31, ip=172.35.0.31, required=172.35.0.10,127.0.0.
```

> 說明：
> - **操作機重開機**：`/secure/ssh` 要先掛載（解鎖）好；沒掛載時 ssh 找不到金鑰、連不上各主機，需要有處理流程（誰解鎖、怎麼解）。lab 的 volume 重開還在。
> - **操作機重建**：重新產生金鑰對（4.2），由 OS 團隊重新佈署公鑰（4.3）；舊私鑰不備份、也找不回來。
> - **換金鑰**（人工、不中斷）見 20.5。**sudo 全權收回**見 16.4、19.5。
> - 人員進操作機就是 root，root 讀得到私鑰。防護不靠「人讀不到」，而靠：`from=`（私鑰被複製也用不了）、獨立加密的 file system 與排除備份（磁碟、快照被取走讀不出）、PVWA 的登入權限與 PSMP 錄影（誰在什麼時間進了 root）、主機端的 sudoers（16.4）。

# 5. 第五站：銀行準備好了嗎：套件庫、JDK、AD、NTP、負載平衡
![bankprep]

**這一章在做什麼**：安裝之前，銀行各團隊要先把 OS 套件庫、JDK、AD、NTP、負載平衡準備好（主機帳號與 SSH 公鑰在第 4 章）。這一章全部是銀行的工作，lab 裡由你扮演；正式環境你不做，只要確認結果（7.2 節的安裝前檢查會逐項看）。哪一項銀行還沒給，後面就會在那裡卡住。

開主機的時候，原廠對虛擬機與磁碟有幾條硬性建議，要在開單時就交代給 OS／虛擬化團隊（lab 是容器，沒有這些）：

| 項目 | 原廠建議 | 為什麼 |
|---|---|---|
| VMware vMotion、磁碟快照 | 平台主機**停用** | 原廠：用在 Kafka／KRaft 上可能造成整個叢集中斷 |
| 資料碟 | broker 的 Kafka 資料放在**獨立的磁碟**，不和 OS、應用程式日誌共用 | 寫入延遲要穩定 |
| RAID | RAID 10（或 RAID 1）優先；**不建議 RAID 5** | 重建期間效能與可靠度 |
| 檔案系統 | XFS 或 ext4 | 原廠只支援這兩種（7.2 節會檢查） |
| JDK | 完整 JDK（不是 headless／JRE） | 原廠支援排錯時需要（這本用的 Temurin tar 就是完整 JDK） |
## 5.1 OS 套件來源與根憑證信任

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

**這一節在做什麼**：讓每台主機能向行內的 OS 套件庫裝套件（第 7–8 章要用），並信任銀行的根憑證（之後 HTTPS 都靠它）。正式環境這是 Satellite 或 Nexus，銀行已經做好；lab 裡：用 repo01 的 `/os/` 路徑模擬。銀行的套件庫**起初是 9.6 的內容**（安裝基底，30.5 才同步到 9.8）。先在一個乾淨容器把需要的 OS 套件從 Rocky vault 的 9.6 抓下來並建索引，放在 `~/kafka-lab/bank-os/9.6`（這是銀行套件庫的內容，不是我們交付的檔案，所以不在落地區）。**先下載、再裝工具**，順序反了會漏掉工具自己的相依：

```bash
cd ~/kafka-lab
mkdir -p bank-os/9.6
out_dir=$(cygpath -m "$PWD/bank-os/9.6")

# 1. 在乾淨的容器裡執行 EOF 之前的那一段（bash -e：其中任何一行失敗就停）；結果放在 bank-os/9.6
podman run --rm -i -v "$out_dir:/out" lab-node:96 bash -e -s <<'EOF'
# 只開 vault 的 9.6 倉庫
repos="--disablerepo=* --enablerepo=vault96-baseos,vault96-appstream,vault96-extras"
# lint-ok: 套件清單（jq 只是 lab 主機自帶的工具，手冊指令不用它）
packages="chrony firewalld cyrus-sasl openssl-devel httpd mod_ssl python3-dnf-plugin-versionlock nmap-ncat jq gettext openldap-clients createrepo_c tar gzip openssl sudo openssh-server diffutils less vim-minimal bind-utils lsof procps-ng rsync bash-completion"

# 1a. 下載（鏡像站有時還沒同步好：最多試 3 次，每次隔 60 秒）
downloaded=no
for try in 1 2 3; do
  if dnf -q $repos download --resolve --arch x86_64 --arch noarch --destdir /out/Packages $packages; then
    downloaded=yes
    break
  fi

  echo "鏡像站還沒同步好，60 秒後重試（第 $try 次）" >&2
  dnf -q clean metadata
  sleep 60
done

if [ $downloaded != yes ]; then
  echo "試了 3 次都下載失敗" >&2
  exit 1   # 結束的是容器裡的這一段，不是你的終端機
fi

# 1b. 用剛下載的檔案裝工具（不連網）：先下載、再裝，順序反了會漏掉工具自己的相依
dnf -q -y --disablerepo="*" install /out/Packages/*.rpm > /dev/null

# 1c. 建索引、數套件
createrepo_c -q /out
ls /out/Packages | wc -l
EOF

# 2. 放上 repo01 的 /os/（擁有者是部署帳號 repodeploy）
podman exec lab-repo01-1 install -d /var/www/repo/os
podman cp "$out_dir/." lab-repo01-1:/var/www/repo/os/
podman exec lab-repo01-1 chown -R repodeploy:repodeploy /var/www/repo/os
podman exec lab-repo01-1 ls /var/www/repo/os
```

```out
71
Packages
repodata
```

數字是 9.6 的 vault 解析出來的套件數（實測 71；「已經在映像裡的套件」不會重抓，所以比完整的相依少）。裝工具那行是用剛下載的檔案裝（`--disablerepo="*"`，不連網）：容器裡因此有 `createrepo_c`，而且狀態等於「裝好這批套件的 9.6 主機」，30.5 會用同樣的方法算出升到 9.8 要的更新集合。

銀行的根憑證（0.5 建的 `ca/root.crt`）放進每台主機的信任清單，並給每台一份指向套件庫的 repo 設定：

```bash
root_crt=$(cygpath -m "$HOME/kafka-lab/ca/root.crt")

for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  # 1. 信任銀行的根憑證
  podman cp "$root_crt" lab-$h-1:/etc/pki/ca-trust/source/anchors/bank-root.pem
  podman exec lab-$h-1 update-ca-trust

  # 2. 指向銀行套件庫的 repo 設定，匯入套件簽章的公鑰
  podman exec -i lab-$h-1 install -m 0644 /dev/stdin /etc/yum.repos.d/bank-os.repo <<'EOF'
[bank-os]
name=Bank OS packages
baseurl=https://repo01.poc.lab/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
EOF
  podman exec lab-$h-1 rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

  printf '%s ' "$h"
done
echo
```

```out
ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
```

正式環境的 RHEL 主機本來就信任行內 CA、也已經註冊到 Satellite，這兩件事是主機範本的一部分。

## 5.2 JDK 21 與 25：銀行交付的 tar

@role 銀行 OS 團隊 | — | —

銀行只交付壓縮檔，不裝、不設定。lab 裡那兩個檔案在 2.5 已經由下載機抓好，隨落地區一起送到了操作機的 `~/landing/bank/`，附銀行提供的 sha256。**JDK 21 是現在要裝的（7.1 節）；JDK 25 是遷移（29.7）才用**，先放著。小安先核對一次：

@role 小安 | ops02 | root

```bash
cd ~/landing/bank

if sha256sum -c --quiet *.sha256; then
  ls
else
  echo "JDK 的 sha256 對不上：請銀行重送"
  false
fi
```

```out
OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz
OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz.sha256
OpenJDK25U-jdk_x64_linux_hotspot_25.0.x_y.tar.gz
OpenJDK25U-jdk_x64_linux_hotspot_25.0.x_y.tar.gz.sha256
```

## 5.3 AD：群組、唯讀查詢帳號、LDAPS 憑證

@role 銀行 AD 團隊 | ad01 | root

**這一節在做什麼**：銀行 AD 團隊建好三個群組（權限綁群組，不綁個人）、一個給 MDS 查詢用的唯讀帳號 `svc-mds-bind`、三個測試人員，並讓 AD 提供 LDAPS（加密的 LDAP）。AD 是行內的帳號目錄，第 11 章起 MDS 靠它確認「這個人屬於哪個群組」。lab 裡：用 Samba AD 模擬。

密碼先產生到檔案，用環境變數傳進指令，不打在畫面上。AD 預設的密碼複雜度要求大寫、小寫、數字至少各一，隨機抽到不符合的就重抽（不然帳號建不起來）：

```bash
# 1. 兩個密碼檔：bind.pass 給 svc-mds-bind、users.pass 給三個測試人員共用（20 個英數字，不合格就重產）
install -d -m 0700 /root/secrets

for k in bind users; do
  while true; do
    p=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)

    # 大寫、小寫、數字至少各有一個才算合格
    upper=$(echo "$p" | tr -dc 'A-Z' | wc -c)
    lower=$(echo "$p" | tr -dc 'a-z' | wc -c)
    digit=$(echo "$p" | tr -dc '0-9' | wc -c)

    if [ "$upper" -gt 0 ] && [ "$lower" -gt 0 ] && [ "$digit" -gt 0 ]; then
      break
    fi
  done

  install -m 0600 /dev/null /root/secrets/$k.pass
  printf '%s' "$p" > /root/secrets/$k.pass
done
unset p

# 2. OU：Confluent 底下分 Users、Groups、Service
base=DC=corp,DC=poc,DC=lab
samba-tool ou create "OU=Confluent,$base"

for ou in Users Groups Service; do
  samba-tool ou create "OU=$ou,OU=Confluent,$base"
done

# 3. MDS 查詢用的唯讀帳號
samba-tool user create svc-mds-bind "$(cat /root/secrets/bind.pass)" \
  --userou="OU=Service,OU=Confluent" \
  --description="read-only LDAP bind for Confluent MDS"

# 4. 三個群組
for g in kafka-admins kafka-operators kafka-devs; do
  samba-tool group add "$g" --groupou="OU=Groups,OU=Confluent"
done

# 5. 三個測試人員，各放進一個群組（寫法：帳號:群組）
for pair in alice:kafka-admins bob:kafka-operators carol:kafka-devs; do
  user=$(echo "$pair" | cut -d: -f1)
  group=$(echo "$pair" | cut -d: -f2)

  samba-tool user create "$user" "$(cat /root/secrets/users.pass)" --userou="OU=Users,OU=Confluent"
  samba-tool group addmembers "$group" "$user"
done

# 6. 確認：kafka-admins 裡有 alice
samba-tool group listmembers kafka-admins
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
mkdir -p /root/csr
cd /root/csr

openssl req -new -newkey rsa:2048 -nodes -keyout ad01.key -out ad01.csr \
  -subj "/CN=ad01.poc.lab/O=PoC Bank/C=TW" \
  -addext "subjectAltName=DNS:ad01.poc.lab,DNS:ad01" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" 2>/dev/null
echo csr-ok
```

```out
csr-ok
```

@role 銀行 CA 窗口 | Windows 終端 | 本機

```bash
cd ~/kafka-lab
mkdir -p ca/exchange

# 1. 取回 ad01 的申請檔，用銀行 CA 簽
podman cp lab-ad01-1:/root/csr/ad01.csr "$(cygpath -m "$PWD/ca/exchange/ad01.csr")"
bash ca/sign.sh ca/exchange/ad01.csr ca/exchange/ad01-chain.crt

# 2. 憑證、根憑證、私鑰放進 samba 的 tls/（私鑰 0600）
tls=/var/lib/samba/private/tls
podman cp "$(cygpath -m "$PWD/ca/exchange/ad01-chain.crt")" lab-ad01-1:$tls/cert.pem
podman cp "$(cygpath -m "$PWD/ca/root.crt")" lab-ad01-1:$tls/ca.pem
podman exec lab-ad01-1 cp /root/csr/ad01.key $tls/key.pem
podman exec lab-ad01-1 chmod 600 $tls/key.pem
podman exec lab-ad01-1 chmod 644 $tls/cert.pem $tls/ca.pem

# 3. 停掉 samba 讓它讀新憑證（啟動程式 2 秒後會自己再開），等它起來
podman exec lab-ad01-1 pkill -x samba
sleep 8

# 4. 確認：LDAPS（636）出示的憑證驗得過根憑證
podman exec lab-ad01-1 bash -c \
  "openssl s_client -connect localhost:636 -CAfile $tls/ca.pem < /dev/null 2> /dev/null | grep 'Verify return code'"
```

```out
signed ad01.csr -> ad01-chain.crt  (CN = ad01.poc.lab, O = PoC Bank, C = TW; EKU serverAuth)
Verify return code: 0 (ok)
```

@role 銀行 AD 團隊（lab 由 Lab 管理員扮演）、小安 | Windows 終端 | 本機

AD 團隊把 svc-mds-bind 的密碼和測試人員的密碼交給小安。正式環境用銀行自己的交付方式（當面、加密郵件等），**不放進 CyberArk 或任何保管庫**。小安放進操作機的 `~/secrets/`（0700 目錄、0600 檔），每個檔在操作機上依序執行四行（以 `ldap-bind.pass` 為例）：`install -m 0600 /dev/null ~/secrets/ldap-bind.pass`（先建一個權限 0600 的空檔）、`IFS= read -rsp '貼上後按 Enter：' P`（`-s` 讓貼上的密碼不顯示在畫面上，PSMP 錄影錄不到）、`printf %s "$P" > ~/secrets/ldap-bind.pass`（`%s` 不多寫換行）、`unset P`。lab 由 Windows 終端把 ad01 上的檔直接送進操作機，不經過任何中間資料夾：

```bash
podman exec lab-ops02-1 install -d -m 0700 /root/secrets

# 寫法：ad01 上的檔名:操作機上的檔名
for pair in bind:ldap-bind users:ad-test-users; do
  src=$(echo "$pair" | cut -d: -f1)
  dst=$(echo "$pair" | cut -d: -f2)
  podman exec lab-ad01-1 cat /root/secrets/$src.pass \
    | podman exec -i lab-ops02-1 install -m 0600 /dev/stdin /root/secrets/$dst.pass
done

podman exec lab-ops02-1 ls -la /root/secrets | tail -n +4
```

```out
-rw------- 1 root root 20 … ad-test-users.pass
-rw------- 1 root root 20 … ldap-bind.pass
```

## 5.4 NTP 與負載平衡

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

# 1. 套件簽章的公鑰；從這台自己的套件庫裝 chrony
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
dnf -q -y --disablerepo="*" --enablerepo=bank-os install chrony > /dev/null

# 2. 當 NTP 伺服器：沒有上游時用本機時間，允許 lab 的網段來對時
cat > /etc/chrony.conf <<'EOF'
local stratum 10
allow 172.35.0.0/24
driftfile /var/lib/chrony/drift
EOF

# 3. 啟動，確認是 active
systemctl enable --now chronyd > /dev/null 2>&1
sleep 2
systemctl is-active chronyd
```

```out
active
```

@role 銀行 網路團隊 | lb01 | root

負載平衡只做 L4 轉發，TLS 和 client 憑證在 REST Proxy 上處理。`rest.poc.lab` 指到 lb01：

```bash
mkdir -p /etc/nginx/stream.d

cat > /etc/nginx/stream.d/cp.conf <<'EOF'
# REST Proxy：兩台，同一個來源 IP 固定到同一台
upstream cp_rest {
    hash $remote_addr consistent;
    server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s;
    server rest02.poc.lab:8082 max_fails=2 fail_timeout=10s;
}

server {
    listen 8082;
    proxy_pass cp_rest;
    proxy_connect_timeout 3s;
    proxy_timeout 10m;
}

# Control Center：一台
upstream cp_c3 {
    server c3-01.poc.lab:9021 max_fails=2 fail_timeout=10s;
}

server {
    listen 9021;
    proxy_pass cp_c3;
    proxy_connect_timeout 3s;
    proxy_timeout 1h;
}
EOF

# 檢查語法，再讓 nginx 重新讀設定
nginx -t 2>&1 | tail -1
nginx -s reload
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
# lb-member.sh <rest01|rest02> down|up|status — lab：扮演 LB 團隊停用／恢復一台 REST Proxy
# 做什麼：在 lb01 的 nginx 設定裡，那一台的 server 行加上（down）或拿掉（up）"down"，再讓 nginx 重新讀設定；status 只印目前狀態
#   正式環境是 LB 團隊在行內的負載平衡設備上停用／啟用 pool member；nginx 重新讀設定時，進行中的連線會讓它跑完
# 用到的設定：lb01 上的 /etc/nginx/stream.d/cp.conf（5.4 寫的），server 行長這樣：server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s;
# 改的時候要注意：輸出的格式（例 "LB：rest01（停用） rest02"）手冊的預期輸出有用到
export MSYS_NO_PATHCONV=1

host=$1
action=${2:-status}
conf=/etc/nginx/stream.d/cp.conf

# lb <指令...>：在 lb01 上執行一個指令
lb() {
  podman exec lab-lb01-1 "$@"
}

# 1. 停用或恢復：改那一台的 server 行
case "$action" in
  down)
    # 還沒有 down 的才加：行尾的 ";" 換成 " down;"
    lb sed -i "/server $host.poc.lab:8082 /{/ down;/!s/;\$/ down;/}" "$conf"
    ;;
  up)
    lb sed -i "/server $host.poc.lab:8082 /s/ down;/;/" "$conf"
    ;;
  status)
    ;;
  *)
    # lint-ok: 用法文字裡的 |，不是管線
    echo "用法：$0 <rest01|rest02> down|up|status"
    exit 2
    ;;
esac

# 2. 改過設定：先檢查語法，再讓 nginx 重新讀設定
if [ "$action" != status ]; then
  if ! lb nginx -t -q; then
    echo "nginx 設定有誤，沒有套用"
    exit 1
  fi

  lb nginx -s reload 2> /dev/null
fi

sleep 1

# 3. 目前狀態：每一台縮成「主機名稱」或「主機名稱（停用）」
#   例：server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s down → rest01（停用）
members=$(lb grep -oE 'server rest0[12][^;]*' "$conf" | sed -E \
  -e 's/\.poc\.lab:8082 max_fails=2 fail_timeout=10s//' \
  -e 's/server //' \
  -e 's/ down/（停用）/' | paste -sd' ' -)
echo "LB：$members"
EOF

chmod +x ~/kafka-lab/lb-member.sh
bash ~/kafka-lab/lb-member.sh rest01 status
```

```out
LB：rest01 rest02
```

# 6. 第六站：上架到內部套件庫

**這一章在做什麼**：把 Confluent 的 RPM 做成一個 dnf 套件庫，放到銀行的套件庫伺服器 repo01，之後 11 台主機都用 `dnf install` 從這裡裝。前提：第 3 章的 `~/landing` 已驗過、第 4 章的 repodeploy 金鑰可用。這一章只放安裝基底的 RPM；遷移目標的 RPM 在 29.1 才上架。

@role 小安 | ops02 | root

repo01 只有 httpd，沒有 `createrepo_c`，所以索引在操作機建好，連 RPM 一起推上去。先從銀行套件庫裝工具：

```bash
dnf -q -y --refresh install createrepo_c
createrepo_c --version
```

```out
Installed:
  createrepo_c-0.20.1-2.el9.x86_64     createrepo_c-libs-0.20.1-2.el9.x86_64
Version: 0.20.1 (Features: LegacyWeakdeps )
```

> 陷阱：dnf 快取的套件清單預設 48 小時才更新。套件庫剛上架的東西主機可能「找不到」，加 `--refresh` 強制重抓。

組目錄、建索引：

```bash
# 1. 要上架的東西：安裝基底的 RPM、原廠公鑰、jar、雜湊清單
mkdir -p ~/repo/confluent ~/repo/gpg-keys ~/repo/tools
cp ~/landing/rpm/*.rpm ~/repo/confluent/
cp ~/landing/gpg-keys/*.asc ~/repo/gpg-keys/
cp ~/landing/tools/*.jar ~/repo/tools/
cp ~/landing/SHA256SUMS ~/repo/

# 2. 建 dnf 的索引
createrepo_c ~/repo/confluent

# 3. 確認索引產生了
if [ -f ~/repo/confluent/repodata/repomd.xml ]; then
  echo repodata-ok
else
  echo "沒有產生索引（repodata/repomd.xml）"
  false
fi
```

```out
（createrepo_c 的進度訊息）
repodata-ok
```

用 tar 串流透過 ssh 推給部署帳號，只會解在 `/var/www/repo` 底下，銀行的 `os/` 不受影響：

```bash
# 1. 在操作機打包、經 ssh 交給部署帳號，在 repo01 解開
tar -C ~/repo -cf - . | ssh repodeploy@repo01.poc.lab 'tar -C /var/www/repo -xpf -'

# 2. 確認：上面有哪些目錄、confluent/ 底下有幾項（11 個 RPM ＋ repodata）
ssh repodeploy@repo01.poc.lab 'ls /var/www/repo'
ssh repodeploy@repo01.poc.lab 'ls /var/www/repo/confluent | wc -l'
```

```out
SHA256SUMS
confluent
gpg-keys
os
tools
12
```

從操作機用 HTTPS 讀讀看，預期 11 個套件：

```bash
dnf -q --repofrompath=cp-test,https://repo01.poc.lab/confluent/ --repo=cp-test --setopt=cp-test.gpgcheck=0 \
  list available | grep -c confluent
```

```out
11
```

# 7. 第七站：主機準備：JDK、安裝前檢查、OS 調校

**這一章在做什麼**：在 11 台主機上把 Confluent 需要的環境準備好：裝 JDK 21、確認 DNS／套件庫／AD／時間都通、調 OS 參數。三節各自獨立，但順序要照這個來（檢查用得到 JDK 與套件庫）。

## 7.1 JDK 21

**這一節在做什麼**：把銀行交付的 JDK 21 tar 解開，裝到操作機和其他 10 台主機的同一個位置。前提：5.2 已核對過 tar。Confluent 的 RPM 不含 JDK，沒有這一步後面的服務起不來。

@role 小安 | ops02 | root

![hostfiles]

銀行給的 tar 在 `~/landing/bank/`（有 21 和 25 兩個，這一章只裝 **21**：8.2.x 不支援 Java 25；25 在第 29 章遷移時才換上去）。決定：解壓到 `/opt/java/<版本目錄>`，再做一個固定的連結 `/opt/java/current` 指向它，所有設定一律寫 `/opt/java/current`，以後換版只改連結。`java`、`keytool` 用 alternatives 登記（RHEL 的標準做法），`/etc/profile.d/java.sh` 設 `JAVA_HOME`；服務自己的 systemd 設定還會再明確寫一次 `JAVA_HOME`，不受全域切換影響。

先看壓縮檔的頂層目錄名稱，並準備 `profile.d` 的檔案（`bank/` 裡同一個主版本有新舊幾版時，`sort -V | tail -1` 挑版本最新的）：

```bash
# 1. bank/ 裡版本最新的 JDK 21 tar，和它解開後的頂層目錄名稱
JDK_TAR=$(ls ~/landing/bank/OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1)
JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1)
echo "tar=$(basename $JDK_TAR) dir=$JDK_DIR"

# 2. 要放進 /etc/profile.d 的 java.sh
install -d -m 0700 ~/jdk
cat > ~/jdk/java.sh <<'EOF'
# JDK for Confluent Platform (/opt/java/current; 21 at install, 25 after the chapter 29 migration). Services set JAVA_HOME in their systemd drop-in.
if [ -z "$JAVA_HOME" ]; then
  export JAVA_HOME=/opt/java/current
fi
EOF

# 3. 記下這兩個變數（之後離開再回來也接得上）
echo "JDK_TAR=$JDK_TAR" > ~/jdk/jdk.env
echo "JDK_DIR=$JDK_DIR" >> ~/jdk/jdk.env
echo java.sh ok
```

```out
tar=OpenJDK21U-jdk_x64_linux_hotspot_21.0.x_y.tar.gz dir=jdk-21.0.x+y
java.sh ok
```

先在操作機本機裝一台（`jdk.env` 記住了上一步的兩個變數，之後離開再回來也接得上）：

```bash
source ~/jdk/jdk.env

# 1. 解到 /opt/java/<版本目錄>，/opt/java/current 指向它
install -d -m 0755 /opt/java
tar -xzf "$JDK_TAR" -C /opt/java
chown -R root:root /opt/java
ln -sfn "/opt/java/$JDK_DIR" /opt/java/current

# 2. 用 alternatives 登記 java、keytool（優先順序 2100）
alternatives --install /usr/bin/java java /opt/java/current/bin/java 2100
alternatives --install /usr/bin/keytool keytool /opt/java/current/bin/keytool 2100

# 3. 登入時設好 JAVA_HOME
install -m 0644 ~/jdk/java.sh /etc/profile.d/java.sh

java -version 2>&1 | head -1
```

```out
openjdk version "21.0.x" … LTS
```

其他 10 台照做：

```bash
source ~/jdk/jdk.env
tar_name=$(basename "$JDK_TAR")

for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  # 1. tar 和 java.sh 送到那台的 /tmp
  scp -q "$JDK_TAR" ~/jdk/java.sh $h.poc.lab:/tmp/

  # 2. 在那台執行 EOF 之前的那一段，和上面操作機的做法一樣（$1 = tar 檔名、$2 = 版本目錄；bash -e：任何一行失敗就停）
  ssh $h.poc.lab bash -e -s -- "$tar_name" "$JDK_DIR" <<'EOF'
sudo install -d -m 0755 /opt/java
sudo tar -xzf /tmp/$1 -C /opt/java
sudo chown -R root:root /opt/java
sudo ln -sfn /opt/java/$2 /opt/java/current

sudo alternatives --install /usr/bin/java java /opt/java/current/bin/java 2100
sudo alternatives --install /usr/bin/keytool keytool /opt/java/current/bin/keytool 2100

sudo install -m 0644 /tmp/java.sh /etc/profile.d/java.sh
rm -f /tmp/$1 /tmp/java.sh
echo "$(hostname): done"
EOF
done

# 3. 11 台都確認：java 在 PATH 上（alternatives）、登入就有 JAVA_HOME（profile.d）
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab 'echo "$(hostname): $(java -version 2>&1 | head -1) JAVA_HOME=$JAVA_HOME"'
done
```

```out
kc01: done
…
ops02: openjdk version "21.0.x" … LTS JAVA_HOME=/opt/java/current
kc01: openjdk version "21.0.x" … LTS JAVA_HOME=/opt/java/current
（11 台都有版本與 JAVA_HOME）
```

最後那行同時驗證了 alternatives（`java` 在 PATH）和 `profile.d`（`ssh host 'cmd'` 讀得到）。

## 7.2 安裝前檢查
**這一節在做什麼**：在動任何東西之前，逐項確認銀行準備的環境符合條件。這一章只看不改。每一項不符都是要先回頭找銀行的事，不要自己硬裝過去；全部符合才進 7.3 節。

@role 小安 | ops02 | root

**主機基本事實**（`/tmp` 不能 `noexec`、至少 2 GB）。過關條件：每台 `tmp_noexec=0`、`tmp_free` 不小於 2048、OS 版本與銀行說的一致：

```bash
# 每台主機上執行 EOF 之前的那一段，各印一行
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -s <<'EOF'
# OS 版本（例 rocky-9.6）
. /etc/os-release
os="$ID-$VERSION_ID"

# 記憶體、/tmp 的剩餘空間（MB）；/tmp 掛載選項裡有沒有 noexec（1 = 有）
mem=$(free -m | awk '/Mem:/{print $2}')
tmp_free=$(df -m /tmp | awk 'NR==2{print $4}')
tmp_noexec=$(findmnt -no OPTIONS /tmp | grep -c noexec)

printf "%-7s %s cpu=%s mem=%sMB tmp_free=%sMB tmp_noexec=%s\n" \
  "$(hostname)" "$os" "$(nproc)" "$mem" "$tmp_free" "$tmp_noexec"
EOF
done
```

```out
ops02   rocky-9.6 cpu=8 mem=10953MB tmp_free=2048MB tmp_noexec=0
（11 行，tmp_noexec 都是 0）
```

**資料碟的檔案系統**（原廠只支援 XFS、ext4；正式環境資料碟要先由主機團隊掛在 `/var/lib/kafka`，還沒掛就會看到 `/var/lib`，也就是 OS 碟）：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab bash -s <<'EOF'
# 資料碟掛好了就是 /var/lib/kafka；還沒掛（目錄還不存在）就看 /var/lib
dir=/var/lib/kafka
if [ ! -e $dir ]; then
  dir=/var/lib
fi

fstype=$(df -T $dir | awk 'NR==2{print $2}')
free_gb=$(df -BG --output=avail $dir | tail -1 | tr -dc 0-9)

printf "%-5s %s fstype=%s free=%sGB\n" "$(hostname)" "$dir" "$fstype" "$free_gb"
EOF
done
```

```out
kc01  /var/lib fstype=overlay free=712GB
（7 行；lab 是容器，所以是 overlay、和 OS 共用；正式環境要是 xfs 或 ext4，而且路徑是 /var/lib/kafka）
```

> `/tmp` 要能執行：broker 啟動時會把壓縮（snappy、zstd、lz4）的原生程式庫解壓到 `java.io.tmpdir`（預設 `/tmp`）再載入，`noexec` 的 `/tmp` 會讓用到這些壓縮的 producer／consumer 失敗。銀行的強化規範若要求 `/tmp` 一律 `noexec`，見 10.3 的 `java.io.tmpdir` 做法。

**時鐘誤差**（TLS 與 MDS token 要求 2 秒內；各台與操作機相差超過 2 秒就請銀行修 NTP）：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  remote=$(ssh $h.poc.lab date +%s)
  here=$(date +%s)
  echo "$h skew=$(( remote - here ))s"
done
```

```out
kc01 skew=0s
（都是 0 或 1）
```

**DNS、套件庫、AD 連線**。過關條件：每台 `all resolved`、`os=200`、`confluent=200`，AD 那段 `Verify return code: 0 (ok)`（代表 LDAPS 憑證鏈信任成功）：

```bash
# 1. 每台：所有主機名稱都解析得到、兩個套件庫的索引都拿得到（200）
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -s <<'EOF'
# 解析不到的主機名稱列出來；全部解析得到就印 all resolved
bad=""
for n in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01 repo01 ad01 lb01; do
  if ! getent hosts $n.poc.lab > /dev/null; then
    bad="$bad $n"
  fi
done

if [ -z "$bad" ]; then
  bad="all resolved"
fi

os=$(curl -s -o /dev/null -w %{http_code} https://repo01.poc.lab/os/repodata/repomd.xml)
confluent=$(curl -s -o /dev/null -w %{http_code} https://repo01.poc.lab/confluent/repodata/repomd.xml)

echo "$(hostname): $bad os=$os confluent=$confluent"
EOF
done

# 2. broker 連得到 AD 的 LDAPS，而且憑證鏈信任成功
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab bash -s <<'EOF'
verify=$(openssl s_client -connect ad01.poc.lab:636 < /dev/null 2> /dev/null | grep "Verify return code")
echo "$(hostname): $verify"
EOF
done
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
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -s <<'EOF'
packages=$(rpm -qa "confluent-*" | wc -l)

if [ -e /var/lib/kafka ]; then
  data_dir=exists
else
  data_dir=none
fi

echo "$(hostname): confluent_pkgs=$packages data_dir=$data_dir"
EOF
done
```

```out
kc01: confluent_pkgs=0 data_dir=none
（10 行）
```

## 7.3 OS 調校
**這一節在做什麼**：照 Confluent 的建議調整主機：核心參數、檔案數上限、關閉 THP（transparent hugepage）、時區、時間同步、防火牆只開需要的埠。每台逐一做，沒有順序相依，也沒有服務會被重啟。

@role 小安 | ops02 | root

10 台叢集主機都要做，操作機只做時間同步與時區。lab 裡：主機是容器，sysctl 有兩個網路參數設不進去（`errors=2`）、THP 的單元會自動跳過；正式 VM 不會有這個限制，`errors` 應該是 0。

**核心參數**：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -s <<'EOF'
# 1. 每台都有的兩行
common="net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096"

# 2. 依角色再加的（REST Proxy、C3 沒有）
case $(hostname) in
  kc*)
    extra="vm.max_map_count = 262144"
    ;;
  kb*)
    extra="vm.max_map_count = 262144
vm.swappiness = 1
vm.dirty_background_ratio = 5
vm.dirty_ratio = 60
net.core.rmem_max = 2097152
net.core.wmem_max = 2097152
net.ipv4.tcp_rmem = 4096 65536 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152"
    ;;
  *)
    extra=""
    ;;
esac

# 3. 寫進 /etc/sysctl.d/90-confluent.conf
sudo install -d -m 0755 /etc/sysctl.d
printf "# Confluent Platform\n%s\n%s\n" "$common" "$extra" | sudo tee /etc/sysctl.d/90-confluent.conf > /dev/null

# 4. 套用，數有幾個設不進去
errors=$(sudo sysctl -q --system 2>&1 | grep -c "sysctl:")
echo "$(hostname): errors=$errors"
EOF
done
```

```out
kc01: errors=0
（kc01–kc03、rest01、rest02、c3-01 都是 errors=0）
kb01: errors=2    （kb01–kb04 都是 2：容器限制 net.core.rmem_max / wmem_max；VM 上是 0）
…
```

**程序限制、THP、時區、journald**：

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -e -s <<'EOF'
# confluent 群組（服務帳號都在裡面）可開的檔案數與程序數
sudo tee /etc/security/limits.d/90-confluent.conf > /dev/null <<'LIMITS'
@confluent soft nofile 128000
@confluent hard nofile 128000
@confluent soft nproc 65536
@confluent hard nproc 65536
LIMITS

echo "$(hostname): limits ok"
EOF
done
```

```out
kc01: limits ok
（10 行）
```

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab bash -s <<'EOF'
# 開機時關掉 THP 的 systemd 單元（容器裡會自動跳過：ConditionVirtualization）
sudo tee /etc/systemd/system/disable-thp.service > /dev/null <<'UNIT'
[Unit]
Description=Disable transparent hugepages (Confluent Platform)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=confluent-server.service
ConditionVirtualization=!container

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled; \
  echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=basic.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable disable-thp.service > /dev/null 2>&1
echo "$(hostname): thp unit enabled"
EOF
done
```

```out
kc01: thp unit enabled
（7 行，只有 controller 與 broker）
```

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -e -s <<'EOF'
# 1. 時區
sudo ln -sfn /usr/share/zoneinfo/Asia/Taipei /etc/localtime

# 2. journald 最多用 1 GB
sudo install -d /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/90-confluent.conf > /dev/null <<'CONF'
[Journal]
SystemMaxUse=1G
CONF
sudo systemctl restart systemd-journald

echo "$(hostname): $(date +%Z)"
EOF
done
```

```out
ops02: CST
（11 行）
```

**時間同步**（指向行內 NTP，lab 是 repo01）：

```bash
# 1. 每台：裝 chrony、指向行內 NTP、啟動
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -e -s <<'EOF'
sudo dnf -q -y install chrony > /dev/null

sudo tee /etc/chrony.conf > /dev/null <<'CONF'
server repo01.poc.lab iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
CONF

sudo systemctl enable --now chronyd > /dev/null 2>&1
sudo systemctl restart chronyd
echo "$(hostname): chrony configured"
EOF
done

# 2. 等 10 秒讓 chrony 選定來源，再看每台選了誰（chronyc sources 裡 ^* 開頭那一行的第 2 欄）
sleep 10

for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab 'echo "$(hostname): $(chronyc sources 2> /dev/null | grep "^\^\*" | awk "{print \$2}")"'
done
```

```out
ops02: chrony configured
（11 行）
ops02: repo01.poc.lab
kc01: repo01
（11 行都有 repo01，代表已選定它當來源；顯示 repo01 或 repo01.poc.lab 都對，看那台怎麼解析名稱）
```

**主機防火牆**（只開這台元件需要的埠）：

| 元件 | 連接埠 | 誰會連進來 |
|---|---|---|
| controller | 9093、7071 | 其他 controller 與 broker；操作機（查 quorum、確認憑證。第 10 章 broker 還沒啟動時只能這樣驗）；監控 |
| broker | 9092、9094、9095、9096、8090、7071 | 9092：broker 之間、controller（metadata）、操作機（確認憑證）；token 連線；應用程式；MDS；監控 |
| REST Proxy | 8082、7071 | 負載平衡；監控 |
| C3 | 9021、9090、7071 | 維運人員的瀏覽器；C3 自己的 Prometheus；監控 |

```bash
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -s <<'EOF'
# 1. 這個角色要開的埠（同上表）
case $(hostname) in
  kc*)   ports="9093 7071" ;;
  kb*)   ports="9092 9094 9095 9096 8090 7071" ;;
  rest*) ports="8082 7071" ;;
  c3*)   ports="9021 9090 7071" ;;
esac

# 2. 裝 firewalld、開機啟動
sudo dnf -q -y install firewalld > /dev/null
sudo systemctl enable --now firewalld > /dev/null 2>&1

# 3. 拿掉預設開放的服務（本來就沒開的話會失敗，不影響）
for service in cockpit dhcpv6-client; do
  sudo firewall-cmd -q --permanent --remove-service=$service 2> /dev/null
done

# 4. 開這個角色的埠，重新載入
for port in $ports; do
  sudo firewall-cmd -q --permanent --add-port=$port/tcp
done
sudo firewall-cmd -q --reload

echo "$(hostname): $(sudo firewall-cmd --list-ports)"
EOF
done
```

```out
kc01: 7071/tcp 9093/tcp
kb01: 7071/tcp 8090/tcp 9092/tcp 9094/tcp 9095/tcp 9096/tcp
rest01: 7071/tcp 8082/tcp
c3-01: 7071/tcp 9021/tcp 9090/tcp
（10 行）
```

> 7071 是 JMX exporter（第 17 章），只做 HTTPS、**沒有帳密**，所以存取控制就靠這裡的防火牆：銀行給了行內 Prometheus 的來源位址（請銀行確認的事項 11.4）之後，把 7071 改成只放行那幾個位址（firewalld 的 rich rule），不要對所有來源開放。lab 沒有這份清單，對所有來源開放。
# 8. 第八站：安裝 Confluent 套件

**這一章在做什麼**：從行內套件庫把 Confluent 的 RPM 裝到各主機（各主機只裝自己角色需要的），並鎖定版本，之後 OS 例行更新不會把它們升掉。

@role 小安 | ops02 | root

裝的是**安裝基底**（Confluent Platform 8.2.4、Control Center 2.5.1，來自 `~/landing/rpm/`）；套件庫（第 6 章）此時只有這一套。目標版本（8.3.2、2.6.1）到第 29 章才上架。

每台放原廠公鑰、寫 repo 設定（11 台含操作機，gpgcheck 開著）：

```bash
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  # 1. 原廠公鑰送到那台的 /tmp
  scp -q ~/landing/gpg-keys/confluent.asc ~/landing/gpg-keys/confluent-c3.asc $h.poc.lab:/tmp/

  # 2. 在那台執行 EOF 之前的那一段：放公鑰、匯入、寫 repo 設定（bash -e：任何一行失敗就停）
  ssh $h.poc.lab bash -e -s <<'EOF'
sudo install -m 0644 /tmp/confluent.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent
sudo install -m 0644 /tmp/confluent-c3.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3
rm -f /tmp/confluent*.asc
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3

sudo tee /etc/yum.repos.d/confluent-internal.repo > /dev/null <<'REPO'
[confluent-internal]
name=Confluent Platform (internal repository)
baseurl=https://repo01.poc.lab/confluent/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-confluent
       file:///etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3
REPO

# 看得到幾個 repo、幾把 Confluent 公鑰
repos=$(dnf -q repolist | grep -c confluent-internal)
keys=$(rpm -q gpg-pubkey --qf "%{SUMMARY}\n" | grep -ci confluent)
echo "$(hostname): $repos repo, $keys keys"
EOF
done
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
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01 ops02; do
  # 1. 這台要裝的套件（同上表）
  case $h in
    kc* | kb*) packages="confluent-server-8.2.4 confluent-security-8.2.4" ;;
    rest*)     packages="confluent-kafka-rest-8.2.4 confluent-security-8.2.4" ;;
    c3*)       packages="confluent-control-center-next-gen-2.5.1 cyrus-sasl openssl-devel" ;;
    ops*)      packages="confluent-server-8.2.4 confluent-security-8.2.4 confluent-cli-8.2.4" ;;
  esac

  # 2. 裝，數裝好了幾個 confluent 套件
  ssh $h.poc.lab "sudo dnf -q -y --setopt=install_weak_deps=False install $packages > /dev/null"
  count=$(ssh $h.poc.lab "rpm -qa 'confluent-*' | wc -l")
  echo "$h: $count confluent packages"
done
```

```out
kc01: 9 confluent packages
kb01: 9 confluent packages
rest01: 4 confluent packages
c3-01: 1 confluent packages
ops02: 10 confluent packages
```

每台約一兩分鐘。鎖版本（只鎖 Confluent；C3 的兩個 OS 套件跟著 OS 修補，不鎖）。這個鎖在第 29 章遷移時逐台先解開、換完版本再鎖回（29.3–29.6）；第 30 章的 OS 更新（9.6 → 9.8）靠它確保 Confluent 不被動到：

```bash
# 1. 每台：裝 versionlock 插件，鎖住這台的每一個 confluent 套件
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -e -s <<'EOF'
sudo dnf -q -y install python3-dnf-plugin-versionlock > /dev/null

for package in $(rpm -qa "confluent-*"); do
  sudo dnf -q versionlock add "$package" > /dev/null
done

echo "$(hostname): $(sudo dnf -q versionlock list | grep -c confluent) locked"
EOF
done

# 2. RPM 建好的服務帳號與群組；C3 主機沒有誤裝 Kafka
for h in kb01 rest01 c3-01; do
  ssh $h.poc.lab bash -s <<'EOF'
accounts=$(getent passwd cp-kafka cp-kafka-rest cp-control-center 2> /dev/null | cut -d: -f1 | tr "\n" " ")
group=$(getent group confluent | cut -d: -f1)

if rpm -q confluent-server > /dev/null 2>&1; then
  kafka_pkg=yes
else
  kafka_pkg=no
fi

echo "$(hostname): $accounts group=$group kafka_pkg=$kafka_pkg"
EOF
done
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

**這一章在做什麼**：替平台的每個元件備好憑證。小安在操作機產生私鑰與 CSR（憑證申請單），交給銀行 CA 簽發，收回來逐張檢查，再做成 Java 用的 keystore／truststore。前提：第 5.1 節的銀行根憑證已在各主機，第 8 章套件已裝。後面第 10–13 章的 TLS 設定都用這一章的產出。

平台內部所有連線都加密，而且用憑證識別身分。小安在操作機產生私鑰和 CSR（私鑰不離開行內），銀行 CA 簽完回來，小安逐張檢查後做成 Java 用的 keystore。

## 9.1 產生私鑰與 CSR

先決定要幾張憑證、各自給誰用（下表），再一次把 7 組私鑰與 CSR 產生出來。私鑰留在操作機，只有 CSR 交給銀行。EKU（憑證用途）決定憑證能當伺服器、客戶端或兩者；SAN 是憑證適用的主機名稱，連線時名稱對不上會被拒。

@role 小安 | ops02 | root

| 名稱 | 用途 | EKU | SAN |
|---|---|---|---|
| kafka-internal | controller、broker 之間的 mTLS；controller 的 JMX exporter（7071，第 17 章；controller 沒有 cp-server） | serverAuth, clientAuth | kc01–03、kb01–04 |
| cp-server | **broker** 對外的伺服器端：client listener、MDS、broker 的 JMX exporter（7071）。只當 server 憑證，不拿去當 client 出示 | serverAuth | kb01–04、localhost |
| svc-rest | REST Proxy 自己的憑證：對外 8082 與 JMX exporter 當 server，向 MDS 換 token 當 client | serverAuth, clientAuth | rest01、rest02、rest.poc.lab、localhost |
| svc-c3 | Control Center 自己的憑證：9021、內建 Prometheus／Alertmanager、JMX exporter 當 server，向 MDS 換 token、連內建服務當 client | serverAuth, clientAuth | c3-01、c3.poc.lab、localhost |
| svc-ops | 操作機向 MDS 換 token 的身分；維運選單（第 16 章）緊急模式也用它 | clientAuth | 無 |
| app-legacy-billing | 走 REST Proxy 的應用程式 | clientAuth | 無 |
| svc-backup | 每日備份（第 23 章）匯出叢集中繼資料的唯讀身分 | clientAuth | 無 |

```bash
# 1. 目錄；keystore 的密碼（24 個英數字，檔案 0600）
install -d -m 0700 ~/pki ~/pki/keys ~/pki/requests ~/pki/incoming ~/pki/certs
install -m 0600 /dev/null ~/pki/store.pass
openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/pki/store.pass

# 2. 申請清單：名稱、EKU、SAN（- = 沒有 SAN）
cat > ~/pki/requests.txt <<'EOF'
kafka-internal     serverAuth,clientAuth  kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04
cp-server          serverAuth             kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04,localhost
svc-rest           serverAuth,clientAuth  rest01.poc.lab,rest01,rest02.poc.lab,rest02,rest.poc.lab,localhost
svc-c3             serverAuth,clientAuth  c3-01.poc.lab,c3-01,c3.poc.lab,localhost
svc-ops            clientAuth             -
app-legacy-billing clientAuth             -
svc-backup         clientAuth             -
EOF

# 3. 清單上每一張：私鑰（0600）與 CSR；有 SAN 的多加一行 subjectAltName
while read -r name eku san; do
  install -m 0600 /dev/null ~/pki/keys/$name.key
  openssl genrsa -out ~/pki/keys/$name.key 2048 2> /dev/null

  if [ "$san" = "-" ]; then
    openssl req -new -key ~/pki/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=$eku" \
      -out ~/pki/requests/$name.csr
  else
    # 換成 subjectAltName 的寫法，例：kc01.poc.lab,kc01 → DNS:kc01.poc.lab,DNS:kc01
    san_dns="DNS:$(echo "$san" | sed 's/,/,DNS:/g')"

    openssl req -new -key ~/pki/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=$eku" \
      -addext "subjectAltName=$san_dns" \
      -out ~/pki/requests/$name.csr
  fi

  echo "$name: csr ok"
done < ~/pki/requests.txt
```

```out
kafka-internal: csr ok
（7 行）
```

送出前自己看一次 CN、SAN、EKU 是否和上表一致（銀行 CA 的政策會檢查 EKU，漏了會被退件）：

```bash
for f in ~/pki/requests/*.csr; do
  echo "== $(basename $f)"

  # 只留 subject、SAN、EKU 和它們的下一行
  csr_text=$(openssl req -in $f -noout -subject -text)
  wanted="^subject=|Alternative|Extended Key"
  picked=$(echo "$csr_text" | grep -E "$wanted" -A1)
  echo "$picked" | grep -v "^--" | sed 's/^ */  /'
done
```

## 9.2 銀行 CA 簽發

@role 銀行 CA 窗口 | Windows 終端 | 本機

正式環境是把 CSR 交給 CA 窗口，收回「憑證 + 中繼 CA」。lab 裡：用 0.5 建好的 `sign.sh`，7 個 CSR 一次簽完、放回操作機的 `incoming/`（簽好的放在 `signed/` 子目錄，免得和 5.3 節簽給 ad01 的那張混在一起）：

```bash
cd ~/kafka-lab

# 1. 清掉上一次的，取回操作機上的申請檔
rm -rf ca/exchange/signed ca/exchange/requests
mkdir -p ca/exchange/signed
podman cp lab-ops02-1:/root/pki/requests "$(cygpath -m "$PWD/ca/exchange/")"

# 2. 逐一簽發
for f in ca/exchange/requests/*.csr; do
  name=$(basename $f .csr)
  bash ca/sign.sh "$f" "ca/exchange/signed/$name.crt"
done

# 3. 簽好的放回操作機的 incoming/，數一下
for f in ca/exchange/signed/*.crt; do
  podman cp "$(cygpath -m "$f")" lab-ops02-1:/root/pki/incoming/
done
podman exec lab-ops02-1 bash -c 'ls /root/pki/incoming | wc -l'
```

```out
signed app-legacy-billing.csr -> app-legacy-billing.crt  (CN = app-legacy-billing, O = PoC Bank, C = TW; EKU clientAuth)
（7 行）
9
```

## 9.3 匯入前檢查、做成 keystore

下面這張圖說明 keystore 和 truststore 各管什麼、兩台機器連線時互相檢查什麼。

![trust]

銀行回覆的憑證不能直接用：先拆開、逐張檢查，全部沒問題才打包成 Java 能讀的檔。這一節是小安防止「拿到錯的憑證才在啟動時才發現」的最後一關。

@role 小安 | ops02 | root

拆開回覆（第一張是 leaf，其餘是中繼）：

```bash
cd ~/pki

# 銀行回覆的 incoming/<名稱>.crt 拆成兩個檔
#   例：incoming/svc-ops.crt → incoming/svc-ops.leaf.pem、incoming/svc-ops.issuers.pem
for name in $(awk '{print $1}' requests.txt); do
  # leaf：從頭到第一行 END CERTIFICATE（第一張）
  sed '/END CERTIFICATE/q' incoming/$name.crt > incoming/$name.leaf.pem

  # issuers：第一行 END CERTIFICATE 之後的全部（其餘的中繼 CA）
  sed '1,/END CERTIFICATE/d' incoming/$name.crt > incoming/$name.issuers.pem

  echo "$name: $(grep -c 'BEGIN CERT' incoming/$name.issuers.pem) issuer(s)"
done
```

```out
kafka-internal: 1 issuer(s)
（7 行）
```

五項檢查：私鑰相符、CN、SAN、EKU、效期，再驗整條鏈到銀行根憑證。好結果是每一行的 key、cn、san、eku、chain 都是 `ok`，days 約 364（憑證效期一年）：

```bash
cd ~/pki

while read -r name eku san; do
  leaf=incoming/$name.leaf.pem

  # 1. 私鑰相符：憑證和私鑰的公鑰，sha256 前 16 碼一樣 = 是一對
  cert_pub=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16)
  key_pub=$(openssl pkey -in keys/$name.key -pubout 2> /dev/null | sha256sum | cut -c1-16)

  if [ "$cert_pub" = "$key_pub" ]; then
    key=ok
  else
    key=MISMATCH
  fi

  # 2. CN 就是申請的名稱（不是的話印出實際的 CN）
  cn=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname | grep -o 'CN=[^,]*' | cut -d= -f2)

  if [ "$cn" = "$name" ]; then
    cn=ok
  fi

  # 3. SAN 和申請的一樣：兩邊都排好順序再比，例 kb01,kb01.poc.lab,…（沒有 SAN 就是空的）
  cert_ext=$(openssl x509 -in $leaf -noout -ext subjectAltName 2> /dev/null | tail -n +2 | tr -d ' ')
  cert_lines=$(echo "$cert_ext" | sed 's/DNS://g' | tr ',' '\n')
  cert_san=$(echo "$cert_lines" | sort | paste -sd,)

  if [ "$san" = "-" ]; then
    wanted_san=""
  else
    wanted_lines=$(echo "$san" | tr ',' '\n')
    wanted_san=$(echo "$wanted_lines" | sort | paste -sd,)
  fi

  if [ "$cert_san" = "$wanted_san" ]; then
    san_check=ok
  else
    san_check=DIFF
  fi

  # 4. 整條鏈驗得到銀行根憑證
  if openssl verify -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem \
    -untrusted incoming/$name.issuers.pem $leaf > /dev/null 2>&1; then
    chain=ok
  else
    chain=FAIL
  fi

  # 5. 用途（例 TLSWebServerAuthentication,TLSWebClientAuthentication）與還有幾天到期
  leaf_eku=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' ')
  end=$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)
  days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))

  # 6. 一行結果（EKU 與剩幾天直接印出來看）
  printf '%-19s key=%s cn=%s san=%s eku=%s days=%s chain=%s\n' \
    $name $key "$cn" $san_check "$leaf_eku" "$days" $chain
done < requests.txt
```

```out
kafka-internal      key=ok cn=ok san=ok eku=TLSWebServerAuthentication,TLSWebClientAuthentication days=364 chain=ok
（7 行，全部 ok）
```

> 任何一項不是 ok 就退回銀行重簽，不往下做。

整理成正式檔案，做 PKCS12 keystore、truststore（只放銀行根憑證）、MDS token 金鑰對：

```bash
cd ~/pki

# 1. 每一張：正式的 PEM（leaf＋中繼）與 PKCS12 keystore（0600）
for name in $(awk '{print $1}' requests.txt); do
  cat incoming/$name.leaf.pem incoming/$name.issuers.pem > certs/$name.crt
  openssl pkcs12 -export -name $name \
    -inkey keys/$name.key \
    -in certs/$name.crt \
    -out certs/$name.p12 \
    -passout file:store.pass
  chmod 0600 certs/$name.p12
done

# 2. truststore：只放銀行根憑證
cp /etc/pki/ca-trust/source/anchors/bank-root.pem certs/bank-root.pem
keytool -importcert -noprompt -alias bank-root \
  -file certs/bank-root.pem \
  -keystore certs/truststore.p12 \
  -storetype PKCS12 \
  -storepass:file store.pass

# 3. MDS 簽 token 用的金鑰對（不經銀行；私鑰 0600）
install -m 0600 /dev/null keys/mds-token.key
openssl genrsa -out keys/mds-token.key 2048 2> /dev/null
openssl rsa -in keys/mds-token.key -pubout -out certs/mds-token-public.pem 2> /dev/null

ls certs | wc -l
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
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  # 1. 這台要的檔案：controller 4 個；broker 多一個對外 listener 用的 cp-server.p12
  files="$HOME/pki/certs/truststore.p12 $HOME/pki/certs/kafka-internal.p12"
  files="$files $HOME/pki/keys/mds-token.key $HOME/pki/certs/mds-token-public.pem"
  case $h in
    kb*) files="$files $HOME/pki/certs/cp-server.p12" ;;
  esac

  scp -q $files $h.poc.lab:/tmp/

  # 2. 在那台執行 EOF 之前的那一段：建目錄（root:confluent 0750）、放檔案（0640）（bash -e：任何一行失敗就停）
  ssh $h.poc.lab bash -e -s <<'EOF'
sudo install -d -o root -g root -m 0755 /etc/confluent
sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka

for f in /tmp/truststore.p12 /tmp/kafka-internal.p12 /tmp/mds-token-public.pem /tmp/cp-server.p12; do
  if [ -f $f ]; then
    sudo install -o root -g confluent -m 0640 $f /etc/confluent/ssl/
  fi
done

# MDS 簽 token 用的私鑰，放上去時改名成 mds-token-keypair.pem
sudo install -o root -g confluent -m 0640 /tmp/mds-token.key /etc/confluent/ssl/mds-token-keypair.pem
rm -f /tmp/*.p12 /tmp/mds-token*

# 放了幾個、哪些
file_count=$(sudo ls /etc/confluent/ssl | wc -l)
file_names=$(sudo ls /etc/confluent/ssl | paste -sd" ")
printf "%-6s %s files: %s\n" "$(hostname)" "$file_count" "$file_names"
EOF
done
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
dnf -q -y install gettext > /dev/null
echo envsubst-ok
```

共用區塊（TLS 預設、RBAC、LDAP、送指標到 C3）。**整段貼到 EOF**：

```bash
install -d -m 0700 ~/conf

cat > ~/conf/common.tpl <<'EOF'
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
super.users=User:kafka-internal
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
ldap.user.name.attribute=cn
ldap.principal.mapping=ldap
ldap.group.search.base=OU=Groups,OU=Confluent,DC=corp,DC=poc,DC=lab
ldap.group.search.scope=2
ldap.group.search.filter=(cn=kafka-*)
ldap.group.object.class=group
ldap.group.name.attribute=cn
ldap.group.member.attribute=member
ldap.group.member.attribute.pattern=CN=([^,]+),.*OU=Users,OU=Confluent,.*

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

> **群組的三個限制（lab 實測，依銀行的結構：使用者在多層 OU、群組在另一個根 OU）**：MDS 只讀群組的 `member`，用 `ldap.group.member.attribute.pattern` 取出 CN，不看完整 DN，也不查那筆是人還是群組。
> - **不支援巢狀群組**（原廠文件也這樣寫）：子群組的成員登得進來，但沒有權限，也沒有錯誤訊息。`KAFKA_*` 群組一定要直接放人。
> - **member 在 `ldap.user.search.base` 外**：那個人登不進來（401）。
> - **同名風險**：如果 pattern 只寫 `CN=([^,]+),.*`，子群組的名稱會被當成使用者；OU 外的 `CN=ABC` 在群組裡，OU 內另一個同名的 `CN=ABC` 登入就會拿到那個群組的權限（都實測過）。所以 pattern 把使用者根 OU 也寫進去（lab 是 `OU=Users,OU=Confluent`，銀行是 `OU=<使用者根 OU>`）：不符合的 member 會被**安靜略過**，不會報錯。代價是根 OU 之外的人即使在群組裡也沒有權限，看 AD 也看不出原因。


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
confluent.metadata.server.impersonation.protected.users=User:kafka-internal;User:kafka-admin;User:svc-ops;User:svc-mds-bind;User:svc-rest;User:svc-c3;User:svc-backup;User:confluent-audit

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
cd ~/conf

# 1. 密碼從檔案讀進變數；envsubst 只換下面這五個變數，範本裡其他的 $ 不動
export STORE_PASSWORD=$(cat ~/pki/store.pass)
export LDAP_BIND_PASSWORD=$(cat ~/secrets/ldap-bind.pass)
vars='${HOST_FQDN} ${NODE_ID} ${RACK} ${STORE_PASSWORD} ${LDAP_BIND_PASSWORD}'

# 寫法：主機:node.id:rack（controller 沒有 rack，寫 -）
for entry in kc01:1:- kc02:2:- kc03:3:- kb01:101:rack-a kb02:102:rack-a kb03:103:rack-b kb04:104:rack-b; do
  n=$(echo $entry | cut -d: -f1)
  export HOST_FQDN=$n.poc.lab
  export NODE_ID=$(echo $entry | cut -d: -f2)
  export RACK=$(echo $entry | cut -d: -f3)

  # 2. controller 用 controller.tpl、broker 用 broker.tpl，後面都接共用區塊（檔案 0600）
  case $n in
    kc*) tpl=controller.tpl ;;
    *)   tpl=broker.tpl ;;
  esac

  install -m 0600 /dev/null $n.server.properties
  envsubst "$vars" < $tpl > $n.server.properties
  echo >> $n.server.properties
  envsubst "$vars" < common.tpl >> $n.server.properties

  # 3. 派送（root:confluent 0640）；數行數、數有沒有沒換掉的 ${（要是 0）
  scp -q $n.server.properties $n.poc.lab:/tmp/server.properties
  ssh $n.poc.lab bash -e -s <<'EOF'
sudo install -o root -g confluent -m 0640 /tmp/server.properties /etc/confluent/kafka/server.properties
rm -f /tmp/server.properties

lines=$(sudo grep -c . /etc/confluent/kafka/server.properties)
unresolved=$(sudo awk '/\$\{/ {c++} END {print c + 0}' /etc/confluent/kafka/server.properties)
echo "$(hostname): $lines lines, unresolved=$unresolved"
EOF
done

unset STORE_PASSWORD LDAP_BIND_PASSWORD
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
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  # 1. heap（lab 規格）
  case $h in
    kc*) heap=384m ;;
    *)   heap=768m ;;
  esac

  # 2. 在那台執行 EOF 之前的那一段（$1 = heap；bash -e：任何一行失敗就停）
  ssh $h.poc.lab bash -e -s -- $heap <<'EOF'
heap=$1

# drop-in：用我們的設定檔、JAVA_HOME、heap 啟動（UNIT 沒加引號，裡面的 $heap 會換成值）
sudo install -d -m 0755 /etc/systemd/system/confluent-server.service.d
sudo tee /etc/systemd/system/confluent-server.service.d/10-override.conf > /dev/null <<UNIT
[Service]
ExecStart=
ExecStart=/usr/bin/kafka-server-start /etc/confluent/kafka/server.properties
Environment="JAVA_HOME=/opt/java/current"
Environment="KAFKA_HEAP_OPTS=-Xms$heap -Xmx$heap"
Environment="KAFKA_LOG4J_OPTS=-Dlog4j2.configurationFile=/etc/kafka/log4j2.yaml"
Environment="LOG_DIR=/var/log/kafka"
LimitNOFILE=128000
TimeoutStopSec=180
Restart=on-failure
RestartSec=10
UNIT
sudo systemctl daemon-reload

# 資料目錄、日誌目錄
sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka/data
sudo install -d -o cp-kafka -g confluent -m 0755 /var/log/kafka

# 確認：ExecStart 指向我們的設定檔；資料目錄的擁有者與權限
exec_file=$(systemctl show confluent-server -p ExecStart --value | grep -o '/etc/[^ ]*properties')
data=$(sudo stat -c %U:%G:%a /var/lib/kafka/data)
printf '%-5s heap=%s exec=%s data=%s\n' $(hostname) $heap "$exec_file" "$data"
EOF
done
```

```out
kc01  heap=384m exec=/etc/confluent/kafka/server.properties data=cp-kafka:confluent:750
（7 行）
```

> 選配：銀行規定 `/tmp` 一律 `noexec` 時（7.2 節有檢查），讓 JVM 改把原生程式庫解到資料碟上的目錄。另加一個 drop-in，用 `JAVA_TOOL_OPTIONS`（第 17 章的 javaagent 會佔用 `KAFKA_OPTS`，兩者不互相覆蓋）：
> 先建目錄 `sudo install -d -o cp-kafka -g confluent -m 0750 /var/lib/kafka/tmp`，再用 `sudo tee /etc/systemd/system/confluent-server.service.d/15-tmpdir.conf` 寫入兩行：`[Service]` 與 `Environment="JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=/var/lib/kafka/tmp"`，最後 `sudo systemctl daemon-reload` 再重啟服務。
> 實測（2026-10-25，kb04）：重啟後 lz4 的原生程式庫改解在 `/var/lib/kafka/tmp`，snappy／zstd／lz4 壓縮的寫入都正常；日誌開頭會多一行 `Picked up JAVA_TOOL_OPTIONS`，屬正常。REST Proxy、C3 同理（各自的資料目錄）。

> 陷阱：如果 exec 顯示的是 `/etc/kafka/server.properties`，代表 drop-in 沒生效，此時啟動會用 RPM 的預設設定起來（沒有加密、沒有認證）。處理：不要啟動，先檢查 drop-in 檔的位置與內容、執行 `systemctl daemon-reload`，再看一次 ExecStart。REST Proxy（第 12 章）與 C3（第 13 章）啟動前都要做同樣的檢查。

## 10.4 格式化、啟動

下面這張圖說明 KRaft quorum 的成員角色，以及 describe 輸出裡的 Lag 是什麼意思。

![kraft]

@role 小安 | ops02 | root

格式化是替每台建立 Kafka 的儲存目錄與身分（只做一次）。整個叢集共用一個 cluster id、每台 controller 一個 directory id；controller 用動態 quorum（可以事後增減成員）格式化，並寫入緊急備用的 SCRAM 管理帳號 `kafka-admin`；broker 格式化成觀察者（observer：不參與 quorum 投票，只讀取 metadata）。

```bash
export JAVA_HOME=/opt/java/current

# 1. 整個叢集一個 cluster id、每台 controller 一個 directory id（檔案 0600）
install -m 0600 /dev/null ~/conf/kraft.env
echo "CLUSTER_ID=$(kafka-storage random-uuid)" > ~/conf/kraft.env

for c in kc01 kc02 kc03; do
  echo "DIR_ID_$c=$(kafka-storage random-uuid)" >> ~/conf/kraft.env
done

# 2. 緊急備用的管理帳號 kafka-admin 的密碼（檔案 0600）
install -m 0600 /dev/null ~/secrets/kafka-admin.pass
openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/kafka-admin.pass

cat ~/conf/kraft.env
```

```out
CLUSTER_ID=xxxxxxxxxxxxxxxxxxxxxx
DIR_ID_kc01=…
DIR_ID_kc02=…
DIR_ID_kc03=…
```

```bash
source ~/conf/kraft.env

# 1. 初始的 3 台 controller，寫法：node.id@主機:埠:directory id
initial="1@kc01.poc.lab:9093:$DIR_ID_kc01,2@kc02.poc.lab:9093:$DIR_ID_kc02,3@kc03.poc.lab:9093:$DIR_ID_kc03"

# 2. controller：動態 quorum，並寫入 kafka-admin 的 SCRAM 帳號
#    在那台執行 EOF 之前的那一段（$1 = cluster id、$2 = 初始 controller）；密碼檔用完即刪，輸出裡含 scram 的行不印
for h in kc01 kc02 kc03; do
  scp -q ~/secrets/kafka-admin.pass $h.poc.lab:/tmp/ka.pass

  ssh $h.poc.lab bash -s -- "$CLUSTER_ID" "$initial" <<'EOF'
password=$(cat /tmp/ka.pass)
rm -f /tmp/ka.pass

sudo -u cp-kafka env \
  JAVA_HOME=/opt/java/current \
  KAFKA_HEAP_OPTS=-Xmx256m \
  KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
  kafka-storage format \
  --cluster-id $1 \
  --config /etc/confluent/kafka/server.properties \
  --initial-controllers $2 \
  --add-scram "SCRAM-SHA-512=[name=kafka-admin,password=$password]" 2>&1 | grep -v -i scram

printf '%-5s cluster.id=%s\n' $(hostname) "$(sudo sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)"
EOF
done

# 3. broker：格式化成觀察者（不參與 quorum 投票）（$1 = cluster id）
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab bash -s -- "$CLUSTER_ID" <<'EOF'
sudo -u cp-kafka env \
  JAVA_HOME=/opt/java/current \
  KAFKA_HEAP_OPTS=-Xmx256m \
  KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
  kafka-storage format \
  --cluster-id $1 \
  --config /etc/confluent/kafka/server.properties \
  --no-initial-controllers 2>&1 | tail -1

cluster=$(sudo sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)
node=$(sudo sed -n 's/^node.id=//p' /var/lib/kafka/data/meta.properties)
printf '%-5s cluster.id=%s node.id=%s\n' $(hostname) "$cluster" "$node"
EOF
done
```

```out
Formatting dynamic metadata voter directory /var/lib/kafka/data with confluent.metadata.version 4.2-IV1A.
kc01  cluster.id=xxxxxxxxxxxxxxxxxxxxxx
…
Formatting metadata directory /var/lib/kafka/data with confluent.metadata.version 4.2-IV1A.
kb01  cluster.id=xxxxxxxxxxxxxxxxxxxxxx node.id=101
（7 台 cluster.id 相同。metadata 版本字串跟著安裝的版本走：基底 8.2.4 預期是 4.2-IV1A（features describe 顯示 CP-8.2-IV1A），遷移到 8.3.2 之後新格式化的（25.1、25.2 節）才是 4.3-IV0B；字串以實際為準，從零重跑時對一次）
```

格式化只做一次，重跑會被 `already formatted` 擋下，這是保護。格式化 controller 時每台會多印一行 `WARN 'share' in group.coordinator.rebalance.protocols is deprecated …`：那是 8.2.4 的 `kafka-storage` 對自己預設值的提示，不是我們的設定，不影響結果。

操作機連 controller 的 client 設定（用內部憑證），然後啟動 controller、看 quorum。好結果：3 台 controller 都在清單裡、有一個 leader、`Lag` 很小；有一台沒出現就先別啟動 broker：

```bash
# 1. 操作機連 controller 的設定：用內部憑證（檔案 0600；EOF 沒加引號，裡面的 $store_password 會換成值）
store_password=$(cat ~/pki/store.pass)
install -m 0600 /dev/null ~/conf/client-internal.properties

cat > ~/conf/client-internal.properties <<EOF
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=/root/pki/certs/kafka-internal.p12
ssl.keystore.password=$store_password
ssl.key.password=$store_password
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
ssl.truststore.password=$store_password
ssl.endpoint.identification.algorithm=https
EOF
unset store_password

# 2. 啟動 3 台 controller
for h in kc01 kc02 kc03; do
  ssh $h.poc.lab 'sudo systemctl enable --now confluent-server > /dev/null 2>&1'
  sleep 1
  printf "%-5s %s\n" $h "$(ssh $h.poc.lab systemctl is-active confluent-server)"
done

# 3. 等 20 秒，看 quorum：3 台都在、有一個 leader
sleep 20
kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties describe --status | grep -E "LeaderId|CurrentVoters"
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
# 1. 啟動 4 台 broker
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo systemctl enable --now confluent-server > /dev/null 2>&1'
  sleep 1
  printf "%-5s %s\n" $h "$(ssh $h.poc.lab systemctl is-active confluent-server)"
done

# 2. 等 45 秒（MDS 要等 AD 查詢帳號連得上才會起來）
sleep 45

# 3. 4 台都以觀察者註冊到 quorum
kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties \
  describe --status | grep CurrentObservers | cut -c1-100

# 4. 每台的 MDS（8090）回 200
for h in kb01 kb02 kb03 kb04; do
  echo "$h MDS=$(curl -s -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done
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

有任何一台不是 `active`，看它的日誌：`ssh <host> 'sudo journalctl -u confluent-server -n 50 --no-pager'`。MDS（8090）一直不回 200 時，MDS 與授權器的日誌**不在 journal**，在 `/var/log/kafka/metadata-service.log`（與 `kafka-authorizer.log`）：`LDAP … data 52e` 是 `svc-mds-bind` 密碼錯，`Waiting for all of the authorizer futures` 是授權器還在等（28.4）。

# 11. 第十一站：帳號與權限

![identity]

下面這張圖說明 svc-ops 這類身分怎麼用憑證換到 token，再進 TOKEN listener。

![tokenflow]

下面這張圖畫出一個人的權限怎麼從 AD 群組一路接到 Kafka 資源（RBAC 全部的角色、範圍與資源見 11.3）。

![rbac]

**這一章在做什麼**：叢集起來之後，建立「誰能做什麼」：操作機的管理身分、應用程式的 SCRAM 帳號、綁在 AD 群組上的 RBAC 角色（Role-Based Access Control，角色式權限）。前提：第 10 章的 broker 與 MDS 都已經正常。

@role 小安 | ops02 | root

**先講清楚 super user**：第 10 章的 `super.users` 只有 `kafka-internal`（controller 與 broker 彼此用的憑證），它繞過 RBAC。人用的身分都不是 super user：操作機的 `svc-ops`、緊急用的 `kafka-admin` 都靠 RBAC 綁 `SystemAdmin`，動作受 RBAC 控管、稽核記的是明確的角色。授權由每台 broker 自己的 authorizer 依 binding 判斷（binding 在內部 topic `_confluent-metadata-auth`），MDS 的 REST 或 AD 不通都不影響授權，所以把人用的帳號設成 super user 沒有必要（11.2 會驗證）。

**bootstrap**：叢集剛起來時一條 binding 都沒有，只有 super user 能呼叫 MDS 建 binding。所以第一步用 `kafka-internal` 的憑證登入 MDS，建第一條：`User:svc-ops → SystemAdmin`。這是 `kafka-internal` 唯一一次被人拿來寫權限（走 MDS 的 8090，不經過 9092；操作機之後只用它查 quorum）：

```bash
export JAVA_HOME=/opt/java/current
source ~/conf/kraft.env

# 1. 用 kafka-internal 的憑證登入 MDS（super user；只有這一次）
confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only --client-cert-path ~/pki/certs/kafka-internal.crt --client-key-path ~/pki/keys/kafka-internal.key

# 2. 第一條 binding：svc-ops 是 SystemAdmin
confluent iam rbac role-binding create --principal User:svc-ops --role SystemAdmin --kafka-cluster "$CLUSTER_ID"

# 3. 確認
confluent iam rbac role-binding list --principal User:svc-ops --kafka-cluster "$CLUSTER_ID"
```

```out
+---------------+--------------+
| Principal     | User:svc-ops |
| Role          | SystemAdmin  |
| Resource Type | Cluster      |
+---------------+--------------+
   Principal   |    Role     | Resource Type | Name | Pattern Type  
---------------+-------------+---------------+------+---------------
  User:svc-ops | SystemAdmin | Cluster       |      |               
```

操作機的管理 client：用 `svc-ops` 憑證向 MDS 換 token，走 TOKEN listener；它的權限就是上面那條 binding。

```bash
# 1. 管理 client 的設定：用 svc-ops 憑證向 MDS 換 token（檔案 0600；EOF 沒加引號，裡面的 $store_password 會換成值）
store_password=$(cat ~/pki/store.pass)
install -m 0600 /dev/null ~/conf/client-admin.properties

cat > ~/conf/client-admin.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=io.confluent.kafka.clients.plugins.auth.token.TokenCertificateLoginCallbackHandler
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required metadataServerUrls="https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8090";
ssl.keystore.type=PKCS12
ssl.keystore.location=/root/pki/certs/svc-ops.p12
ssl.keystore.password=$store_password
ssl.key.password=$store_password
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
ssl.truststore.password=$store_password
ssl.endpoint.identification.algorithm=https
EOF
unset store_password

# 2. 列 topic（BS = 4 台 broker 的 TOKEN listener，這一章後面都會用到）
export JAVA_HOME=/opt/java/current
export BS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094,kb04.poc.lab:9094
kafka-topics --bootstrap-server $BS --command-config ~/conf/client-admin.properties --list
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
# 1. 四個應用程式帳號：產生密碼（檔案 0600），在 Kafka 建 SCRAM 憑據
for a in app-orders-a app-orders-b app-payments-a app-payments-b; do
  install -m 0600 /dev/null ~/secrets/$a.pass
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/$a.pass

  password=$(cat ~/secrets/$a.pass)
  kafka-configs \
    --bootstrap-server $BS \
    --command-config ~/conf/client-admin.properties \
    --alter \
    --entity-type users \
    --entity-name $a \
    --add-config "SCRAM-SHA-512=[iterations=8192,password=$password]" > /dev/null
  echo "$a: scram created"
done
unset password

# 2. 確認：四個帳號，加上 10.4 建的 kafka-admin，都有 SCRAM 憑據
for a in app-orders-a app-orders-b app-payments-a app-payments-b kafka-admin; do
  scram=$(kafka-configs \
    --bootstrap-server $BS \
    --command-config ~/conf/client-admin.properties \
    --describe \
    --entity-type users \
    --entity-name $a | grep -o 'SCRAM-SHA-512=[^,]*' | head -1)
  echo "$a: $scram"
done
```

```out
app-orders-a: scram created
app-orders-b: scram created
app-payments-a: scram created
app-payments-b: scram created
app-orders-a: SCRAM-SHA-512=iterations=8192
（4 個帳號）
kafka-admin: SCRAM-SHA-512=iterations=4096
```

每個直連 Kafka 的應用程式建**兩個**同權限的 SCRAM 帳號 `<app>-a`、`<app>-b`：應用程式平常用 -a，-b 閒置；換密碼時換閒置的那個、應用程式再切過去，就不會中斷（20.6 演練；OP menu 34／35 做的是同一件事）。應用程式這一端的連線設定（扮演 app-orders，用 `app-orders-a` 直連 CLIENT 9095；第 18、19 章驗證時都會用到）。密碼從 0600 檔讀，設定檔一樣是 0600：

```bash
# 密碼讀進變數，寫成設定檔（檔案 0600；EOF 沒加引號，兩個密碼變數會換成值）
password=$(cat ~/secrets/app-orders-a.pass)
store_password=$(cat ~/pki/store.pass)
install -m 0600 /dev/null ~/conf/app-orders.properties

cat > ~/conf/app-orders.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-orders-a" password="$password";
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
ssl.truststore.password=$store_password
EOF
unset password store_password

echo "$(grep -c . ~/conf/app-orders.properties) lines, $(stat -c %a ~/conf/app-orders.properties)"
```

```out
6 lines, 600
```

RBAC：人員綁 AD 群組，服務與 app 各綁最小權限：

```bash
# 1. 換成 svc-ops 登入 MDS
confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key
source ~/conf/kraft.env

# 2. binding 清單：principal、角色、資源（- = 整個 cluster）、比對方式（PREFIXED = 名稱開頭相同）
cat > ~/conf/rbac.txt <<'EOF'
Group:kafka-admins      SystemAdmin    -                                            -
Group:kafka-operators   Operator       -                                            -
Group:kafka-devs        DeveloperRead  Topic:orders.                                PREFIXED
Group:kafka-devs        DeveloperRead  Group:dev-                                   PREFIXED
User:svc-ops            SystemAdmin    -                                            -
User:kafka-admin        SystemAdmin    -                                            -
User:svc-c3             SystemAdmin    -                                            -
User:svc-rest           DeveloperRead  Topic:_confluent-license                     LITERAL
User:svc-rest           DeveloperRead  Topic:_confluent-command                     LITERAL
User:svc-rest           DeveloperRead  Topic:__internal_confluent_only_broker_info  LITERAL
User:app-orders-a       DeveloperWrite Topic:orders.                                PREFIXED
User:app-orders-b       DeveloperWrite Topic:orders.                                PREFIXED
User:app-orders-a       DeveloperRead  Topic:orders.                                PREFIXED
User:app-orders-b       DeveloperRead  Topic:orders.                                PREFIXED
User:app-orders-a       DeveloperManage Topic:orders.                               PREFIXED
User:app-orders-b       DeveloperManage Topic:orders.                               PREFIXED
User:app-orders-a       DeveloperRead  Group:orders-                                PREFIXED
User:app-orders-b       DeveloperRead  Group:orders-                                PREFIXED
User:app-payments-a     DeveloperWrite Topic:payments.                              PREFIXED
User:app-payments-b     DeveloperWrite Topic:payments.                              PREFIXED
User:app-payments-a     DeveloperRead  Topic:payments.                              PREFIXED
User:app-payments-b     DeveloperRead  Topic:payments.                              PREFIXED
User:app-legacy-billing DeveloperWrite Topic:billing.                               PREFIXED
User:app-legacy-billing DeveloperRead  Topic:billing.                               PREFIXED
User:app-legacy-billing DeveloperRead  Group:billing-                               PREFIXED
EOF

# 3. 逐條建立：整個 cluster 的不給 --resource；PREFIXED 的多加 --prefix
while read -r principal role resource pattern; do
  if [ "$resource" = "-" ]; then
    confluent iam rbac role-binding create \
      --principal "$principal" \
      --role "$role" \
      --kafka-cluster "$CLUSTER_ID" > /dev/null
    echo "ok  $principal $role"
  elif [ "$pattern" = "PREFIXED" ]; then
    confluent iam rbac role-binding create \
      --principal "$principal" \
      --role "$role" \
      --kafka-cluster "$CLUSTER_ID" \
      --resource "$resource" \
      --prefix > /dev/null
    echo "ok  $principal $role $resource $pattern"
  else
    confluent iam rbac role-binding create \
      --principal "$principal" \
      --role "$role" \
      --kafka-cluster "$CLUSTER_ID" \
      --resource "$resource" > /dev/null
    echo "ok  $principal $role $resource $pattern"
  fi
done < ~/conf/rbac.txt
```

```out
ok  Group:kafka-admins SystemAdmin
（25 行 ok；svc-ops 那條 bootstrap 已經建過，重建是 no-op）
```

配額與範例 topic：

```bash
# 1. 配額：四個 SCRAM 帳號一樣；走 REST Proxy 的 app-legacy-billing 小一點
for a in app-orders-a app-orders-b app-payments-a app-payments-b; do
  kafka-configs \
    --bootstrap-server $BS \
    --command-config ~/conf/client-admin.properties \
    --alter \
    --entity-type users \
    --entity-name $a \
    --add-config 'producer_byte_rate=5242880,consumer_byte_rate=10485760,request_percentage=50'
done

kafka-configs \
  --bootstrap-server $BS \
  --command-config ~/conf/client-admin.properties \
  --alter \
  --entity-type users \
  --entity-name app-legacy-billing \
  --add-config 'producer_byte_rate=1048576,consumer_byte_rate=2097152,request_percentage=25'

# 2. 範例 topic（寫法：名稱:partition 數）
for entry in orders.events:6 payments.events:6 billing.events:3; do
  topic=$(echo $entry | cut -d: -f1)
  partitions=$(echo $entry | cut -d: -f2)

  kafka-topics --bootstrap-server $BS --command-config ~/conf/client-admin.properties --create --if-not-exists \
    --topic $topic --partitions $partitions --replication-factor 3 --config min.insync.replicas=2 > /dev/null
  echo "topic $topic"
done
```

```out
Completed updating config for user app-orders-a.
（5 行）
topic orders.events
topic payments.events
topic billing.events
```

驗證權限真的靠 AD 群組：alice（kafka-admins）和 carol（kafka-devs）用 AD 帳密登入 MDS，看自己的角色：

```bash
password=$(cat ~/secrets/ad-test-users.pass)

for u in alice carol; do
  # 1. 用本人的 AD 帳密登入 MDS（帳密用環境變數給 confluent，不寫在參數裡）
  CONFLUENT_PLATFORM_USERNAME=$u CONFLUENT_PLATFORM_PASSWORD=$password confluent login --url https://kb01.poc.lab:8090 \
    --certificate-authority-path ~/pki/certs/bank-root.pem > /dev/null 2>&1

  # 2. 自己有哪些角色：從 JSON 取出 "role" 欄位、去掉重複，再排成一行
  roles=$(confluent iam rbac role-binding list \
    --principal User:$u \
    --kafka-cluster $CLUSTER_ID \
    -o json 2> /dev/null | grep -o '"role": *"[^"]*"' | sort -u)
  roles=$(echo "$roles" | tr '\n' ' ')
  echo "$u: $roles"
done
unset password

# 3. 換回 svc-ops
confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key > /dev/null
```

```out
alice: "role": "SystemAdmin"
carol: "role": "DeveloperRead"
```

## 11.1 密碼放在哪裡

**這一節在做什麼**：到這裡小安產生了幾組密碼，先說清楚它們放在哪裡、誰會用。本案的平台密碼與金鑰**不交給任何保管庫**（也不放 CyberArk），只放在操作機 root 才讀得到的位置；能登入操作機的人員都是經 PVWA＋PSMP 進來的 root，有登入紀錄與錄影。

| 密碼 | 放在 | 誰要用 |
|---|---|---|
| `~/pki/store.pass`（所有 keystore／truststore） | 操作機，0600 | 平台工程師 |
| `~/secrets/kafka-admin.pass`（緊急備用的 SCRAM 管理帳號，10.4） | 操作機，0600 | 平台工程師，MDS 故障時 |
| `~/secrets/app-orders-a.pass`、`-b.pass`、`app-payments-a.pass`、`-b.pass` | 操作機，0600 | 各應用程式團隊（交付方式由銀行與應用程式團隊決定，不經過平台） |

@role 小安 | ops02 | root

確認這幾個檔都只有 root 讀得到：

```bash
stat -c '%a %U %s 位元組 %n' \
  ~/pki/store.pass \
  ~/secrets/kafka-admin.pass \
  ~/secrets/app-orders-a.pass \
  ~/secrets/app-orders-b.pass \
  ~/secrets/app-payments-a.pass \
  ~/secrets/app-payments-b.pass
```

```out
600 root 24 位元組 /root/pki/store.pass
600 root 24 位元組 /root/secrets/kafka-admin.pass
600 root 24 位元組 /root/secrets/app-orders-a.pass
600 root 24 位元組 /root/secrets/app-orders-b.pass
600 root 24 位元組 /root/secrets/app-payments-a.pass
600 root 24 位元組 /root/secrets/app-payments-b.pass
```

> 這些檔案各只有一份。操作機重建時要重新產生並到叢集重設（`kafka-admin`、應用程式的 SCRAM 要用 MDS 或 `kafka-configs` 重設；keystore 要重簽或重新打包），所以操作機的備份要由銀行自己的備份機制處理，而且必須加密（已列入問題清單）。密碼換了（OP menu 35 換服務密碼）就要把新密碼交給應用程式團隊。

## 11.2 演練：AD 不通時，人員登不進，緊急帳號仍可用

**這一節在做什麼**：證明緊急帳號的設計成立。把 AD 停掉：alice 用 AD 帳密向 MDS 要 token 會失敗（MDS 驗不了密碼），`kafka-admin` 用 SCRAM 從 9095 進去照樣能列 topic（認證不靠 AD，授權看 broker 本機的 binding）。驗完把 AD 開回來，確認 alice 恢復。正式環境不會真的停 AD，這是 lab 的演練；正式環境的對應情境是 AD 故障或 LDAPS 憑證過期。

@role 銀行 AD 團隊（lab：停掉 ad01 容器） | Windows 終端 | 本機

```bash
podman stop lab-ad01-1 > /dev/null
echo "ad01 已停"
```

```out
ad01 已停
```

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
ca=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. alice 用 AD 帳密向 MDS 要 token：AD 不通，應該是 401
password=$(cat ~/secrets/ad-test-users.pass)
url=https://kb01.poc.lab:8090/security/1.0/authenticate

echo "alice 登入 MDS：HTTP $(curl -s -m 20 --cacert $ca -u "alice:$password" -o /dev/null -w '%{http_code}' $url)"
unset password

# 2. kafka-admin 用 SCRAM 從 9095 列 topic：照樣可以
#    連線設定借 app-orders 那一份，帳密那一行換成 kafka-admin（放在暫存目錄，用完即刪）
tmp=$(mktemp -d)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $tmp/c.properties

admin_password=$(cat ~/secrets/kafka-admin.pass)

cat >> $tmp/c.properties <<EOF
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="kafka-admin" password="$admin_password";
EOF
unset admin_password

count=$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9095 \
  --command-config $tmp/c.properties \
  --list 2> /dev/null | grep -vc -e '^Error' -e '^$')
echo "kafka-admin 從 9095 列 topic：$count 個"
rm -rf $tmp
```

```out
alice 登入 MDS：HTTP 401
kafka-admin 從 9095 列 topic：10 個
```

> alice 拿不到 token 是因為 MDS 要向 AD 驗她的密碼；已經拿到 token 的人在 token 到期（預設 1 小時）前不受影響。`kafka-admin` 走 SCRAM，憑據在 KRaft 中繼資料裡，所以 AD 不通照樣能登入；它能做什麼由 binding 決定（SystemAdmin）。

@role 銀行 AD 團隊（lab：開回 ad01） | Windows 終端 | 本機

```bash
podman start lab-ad01-1 > /dev/null

# 在操作機上執行的檢查：LDAPS 連得上，而且憑證驗證通過
check="timeout 5 openssl s_client -connect ad01.poc.lab:636 < /dev/null 2> /dev/null"
check="$check | grep -q 'Verify return code: 0'"

# 從操作機每 5 秒試一次 LDAPS，最多試 30 次
for i in $(seq 1 30); do
  if podman exec lab-ops02-1 bash -c "$check"; then
    break
  fi

  sleep 5
done

echo "ad01 已開回（LDAPS 約 $((i*5)) 秒後可用）"
```

```out
ad01 已開回（LDAPS 約 10 秒後可用）
```

@role 小安 | ops02 | root

```bash
ca=/etc/pki/ca-trust/source/anchors/bank-root.pem
password=$(cat ~/secrets/ad-test-users.pass)
url=https://kb01.poc.lab:8090/security/1.0/authenticate

# 每 5 秒試一次 alice 向 MDS 要 token，最多試 12 次，拿到 200 就停
for i in $(seq 1 12); do
  if [ "$(curl -s -m 20 --cacert $ca -u "alice:$password" -o /dev/null -w '%{http_code}' $url)" = 200 ]; then
    break
  fi

  sleep 5
done

echo "AD 開回後 alice 登入 MDS：HTTP $(curl -s -m 20 --cacert $ca -u "alice:$password" -o /dev/null -w '%{http_code}' $url)"
unset password
```

```out
AD 開回後 alice 登入 MDS：HTTP 200
```

## 11.3 RBAC 全貌：範圍、角色、資源

![rbacmodel]

**這一節在做什麼**：把 Confluent RBAC 的結構一次講完，之後每一章新增 binding 時回來對照。它分三層：

- **範圍（scope）**：最外層是 Kafka cluster（MDS 裡叫 `kafka-cluster`，值是 `CLUSTER_ID`）。Schema Registry、Connect、ksqlDB 各自是掛在它底下的子 cluster，有自己的 id；本平台沒有裝這三樣，所以所有 binding 都只指定 `--kafka-cluster`。REST Proxy 與 C3 不是子 cluster，它們用的就是 Kafka cluster 上的權限。
- **資源**：Kafka cluster 裡有四種：`Cluster`（叢集本身）、`Topic`、`Group`（consumer group）、`TransactionalId`。子 cluster 各有自己的資源（Schema Registry 的 `Subject`、Connect 的 `Connector`、ksqlDB 的 `KsqlCluster`）。
- **角色**：CP 內建 10 個，**不能自訂**。分兩種：綁整個 cluster 的（SystemAdmin、ClusterAdmin、UserAdmin、SecurityAdmin、AuditAdmin、Operator），binding 不能指定資源；綁資源的（ResourceOwner、DeveloperManage、DeveloperRead、DeveloperWrite），binding 一定要給資源 pattern：`LITERAL`（名字完全相同；`*` 代表全部）或 `PREFIXED`（名字開頭相同）。

@role 小安 | ops02 | root

每個角色到底給了哪些操作，以 MDS 自己的定義為準（版本升級時可能變，換版後重跑這一行）。這裡只印 Kafka cluster 的四種資源與 `SecurityMetadata`（role binding 本身）：

```bash
export JAVA_HOME=/opt/java/current

confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key > /dev/null

# 把 MDS 的角色定義（JSON）整理成一個角色一行；只留 Kafka cluster 的四種資源與 SecurityMetadata
#   例：DeveloperRead    Resource  Cluster=-  Topic=Read,Describe  Group=Read,Describe  TransactionalId=Describe
confluent iam rbac role list -o json | python3 -c '
import json, sys

keep = ["Cluster", "Topic", "Group", "TransactionalId", "SecurityMetadata"]
roles = json.load(sys.stdin)
roles.sort(key=lambda r: (r["accessPolicy"]["scopeType"], r["name"]))

for r in roles:
    p = r["accessPolicy"]
    ops = {}

    for o in p.get("allowedOperations", []):
        if o.get("resourceType") in keep:
            ops[o["resourceType"]] = ",".join(o.get("operations", [])) or "-"

    shown = ["%s=%s" % (k, ops[k]) for k in keep if k in ops]
    print("%-16s %-9s %s" % (r["name"], p["scopeType"], "  ".join(shown) or "(scope 內全部)"))
'
```

```out
AuditAdmin       Cluster   Cluster=DescribeConfigs,AlterConfigs
ClusterAdmin     Cluster   Cluster=Alter,Describe,Create,AlterConfigs,DescribeConfigs  Topic=Delete,Alter,Describe,Create,AlterConfigs,DescribeConfigs
Operator         Cluster   Topic=Describe
SecurityAdmin    Cluster   SecurityMetadata=Describe
SystemAdmin      Cluster   (scope 內全部)
UserAdmin        Cluster   Cluster=Alter,Describe  SecurityMetadata=Describe,Alter
DeveloperManage  Resource  Cluster=Create,DescribeConfigs  Topic=Delete,Describe,Create,DescribeConfigs  Group=Describe,Delete,DescribeConfigs  TransactionalId=Describe
DeveloperRead    Resource  Cluster=-  Topic=Read,Describe  Group=Read,Describe  TransactionalId=Describe
DeveloperWrite   Resource  Cluster=IdempotentWrite  Topic=Write,Describe  Group=-  TransactionalId=Write,Describe
ResourceOwner    Resource  Cluster=Describe,Alter,IdempotentWrite,AlterAccess,Create,DescribeConfigs,AlterConfigs,DescribeAccess  Topic=Delete,Read,Write,Describe,Alter,ControlCenterTriggerWrite,AlterAccess,Create,DescribeConfigs,AlterConfigs,DescribeAccess  Group=Read,Describe,Delete,ControlCenterTriggerWrite,AlterAccess,DescribeConfigs,AlterConfigs,DescribeAccess  TransactionalId=Write,Describe,AlterAccess,DescribeAccess
```

（8.3.2 實測，2026-10-29；操作的排列順序每次可能不同。）整理成表，最後一欄是本平台誰綁了這個角色：

| 角色 | 綁在 | Topic | Group | Cluster | 本平台誰綁 |
|---|---|---|---|---|---|
| SystemAdmin | 整個 cluster | 全部 | 全部 | 全部（含 role binding） | `Group:kafka-admins`、`svc-ops`、`kafka-admin`（SCRAM）、`svc-c3` |
| ClusterAdmin | 整個 cluster | 建、刪、改設定、看（**不能讀寫**） | — | 改設定、建 | 沒用 |
| UserAdmin | 整個 cluster | — | — | 管 role binding | 沒用（改權限由 SystemAdmin 做） |
| SecurityAdmin | 整個 cluster | — | — | 只能看 role binding | `svc-backup`（23.2） |
| AuditAdmin | 整個 cluster | — | — | 改稽核日誌設定 | 沒用 |
| Operator | 整個 cluster | 看（Describe） | — | — | `Group:kafka-operators` |
| ResourceOwner | 資源 | 全部，還能再授權給別人 | 全部 | — | `svc-rest` 在 `_confluent-command`（29 章） |
| DeveloperManage | 資源 | 建、刪、看設定（**不能讀寫**） | 看、刪 | — | `Group:kafka-operators` 在 `Topic:*`；`Group:kafka-devs`、app-orders 在 `orders.` |
| DeveloperRead | 資源 | 讀、看 | 加入、提交 offset、看 | — | 各應用程式在自己的 prefix；`Group:kafka-operators` 在 `Group:*` |
| DeveloperWrite | 資源 | 寫、看 | — | idempotent 寫入 | 各應用程式在自己的 prefix |

三件常被誤會的事：

- **只要 DescribeConfigs，沒有唯讀的角色**：表裡能看 topic 設定的（DeveloperManage、ClusterAdmin、ResourceOwner、SystemAdmin）都連帶能建、刪 topic；而 `kafka-topics --describe` 對每個 topic 都要 DescribeConfigs（加 `--under-replicated-partitions` 也一樣）。所以維運群組是 `DeveloperManage Topic:*`（16.2）：能建、刪，但**讀不到訊息內容**。要更窄只能用 ACL（第 23 章 svc-backup 的做法）。
- **管理類角色多半讀不到訊息**：ClusterAdmin、Operator、DeveloperManage 都沒有 Topic 的 Read；讀訊息只有 DeveloperRead、ResourceOwner、SystemAdmin。
- **權限是加總的**：一個人所屬的每個 AD 群組上的 binding 全部合起來；RBAC 沒有「拒絕」型的 binding，要收回只能刪 binding。

# 12. 第十二站：REST Proxy

![edge]

**這一章在做什麼**：在 rest01、rest02 兩台安裝 REST Proxy（讓不方便直連 Kafka 的應用程式用 HTTP 存取 Kafka），前面由銀行網路團隊的負載平衡（LB）分流。前提：第 10、11 章的 broker 與 MDS 已正常、第 9 章的 `svc-rest` 與 `app-legacy-billing` 憑證已做好。完成的樣子：帶 legacy app 憑證經 LB 打 `/v3/clusters` 回 200，其他憑證 401，不帶憑證被 TLS 直接拒絕。

@role 小安 | ops02 | root

REST Proxy 沒有密碼登入，應用程式一律用 client 憑證；憑證的 CN 對應到 Kafka 身分（principal）的規則只列出走 REST 的 app，故意不加 DEFAULT，其他憑證一律對不上。先派送憑證，兩台各要看到 4 個檔：

```bash
for h in rest01 rest02; do
  scp -q ~/pki/certs/truststore.p12 ~/pki/certs/svc-rest.p12 ~/pki/certs/mds-token-public.pem $h.poc.lab:/tmp/

  # 在那台執行 EOF 之前的那一段：建目錄（root:confluent 0750）、放檔案（0640）（bash -e：任何一行失敗就停）
  ssh $h.poc.lab bash -e -s <<'EOF'
sudo install -d -o root -g root -m 0755 /etc/confluent
sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/kafka-rest

for f in truststore.p12 svc-rest.p12 mds-token-public.pem; do
  sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/
done
rm -f /tmp/*.p12 /tmp/mds-token-public.pem

printf "%-7s %s files\n" "$(hostname)" "$(sudo ls /etc/confluent/ssl | wc -l)"
EOF
done
```

```out
rest01  3 files
rest02  3 files
```

設定檔用範本產生（兩台只差 `id` 與主機名），連同 systemd drop-in 一起派送。看最後一行：`unresolved=0` 代表範本變數都換好了，`exec=` 要指向我們的設定檔：

```bash
cat > ~/conf/kafka-rest.tpl <<'EOF'
# REST Proxy ${HOST_FQDN}
id=${REST_ID}
listeners=https://0.0.0.0:8082
advertised.listeners=https://rest.poc.lab:8082
host.name=rest.poc.lab

############################# HTTPS + mandatory client certificates #############################
ssl.keystore.type=PKCS12
ssl.keystore.location=/etc/confluent/ssl/svc-rest.p12
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

cd ~/conf
export STORE_PASSWORD=$(cat ~/pki/store.pass)

for h in rest01 rest02; do
  # 1. 這台的設定檔（兩台只差 id 與主機名稱；檔案 0600）
  export HOST_FQDN=$h.poc.lab
  export REST_ID=$h
  install -m 0600 /dev/null $h.kafka-rest.properties
  envsubst '${HOST_FQDN} ${REST_ID} ${STORE_PASSWORD}' < kafka-rest.tpl > $h.kafka-rest.properties

  # 2. 派送設定檔與 systemd drop-in，再確認（bash -e：任何一行失敗就停）
  scp -q $h.kafka-rest.properties $h.poc.lab:/tmp/kafka-rest.properties

  ssh $h.poc.lab bash -e -s <<'EOF'
sudo install -o root -g confluent -m 0640 /tmp/kafka-rest.properties /etc/confluent/kafka-rest/kafka-rest.properties
rm -f /tmp/kafka-rest.properties

sudo install -d -m 0755 /etc/systemd/system/confluent-kafka-rest.service.d
sudo tee /etc/systemd/system/confluent-kafka-rest.service.d/10-override.conf > /dev/null <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/kafka-rest-start /etc/confluent/kafka-rest/kafka-rest.properties
Environment="JAVA_HOME=/opt/java/current"
Environment="KAFKAREST_HEAP_OPTS=-Xms512m -Xmx512m"
LimitNOFILE=65536
Restart=on-failure
RestartSec=10
UNIT
sudo systemctl daemon-reload

# 確認：行數、沒換掉的 ${（要是 0）、ExecStart 指向我們的設定檔
file=/etc/confluent/kafka-rest/kafka-rest.properties
lines=$(sudo grep -c . $file)
unresolved=$(sudo awk '/\$\{/ {c++} END {print c + 0}' $file)
exec_file=$(systemctl show confluent-kafka-rest -p ExecStart --value | grep -o "/etc/[^ ]*properties")
printf "%-7s config %s lines, unresolved=%s, exec=%s\n" "$(hostname)" "$lines" "$unresolved" "$exec_file"
EOF
done

unset STORE_PASSWORD
```

```out
rest01  config 47 lines, unresolved=0, exec=/etc/confluent/kafka-rest/kafka-rest.properties
rest02  config 47 lines, unresolved=0, exec=/etc/confluent/kafka-rest/kafka-rest.properties
```

啟動並測三種情況：legacy app 憑證 200、其他憑證 401、沒憑證被 TLS 直接拒絕：

```bash
# 1. 啟動；已經在跑的也重啟一次，讓新設定生效
for h in rest01 rest02; do
  ssh $h.poc.lab 'sudo systemctl enable --now confluent-kafka-rest > /dev/null 2>&1'
  ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'
  printf "%-7s %s\n" $h "$(ssh $h.poc.lab systemctl is-active confluent-kafka-rest)"
done

# 2. 等 40 秒讓兩台起來
sleep 40

legacy="--cert $HOME/pki/certs/app-legacy-billing.crt --key $HOME/pki/keys/app-legacy-billing.key"
other="--cert $HOME/pki/certs/svc-ops.crt --key $HOME/pki/keys/svc-ops.key"

# 3. 每台三種情況：legacy app 的憑證、其他憑證、不帶憑證（印 HTTP 狀態碼；000 = TLS 就被拒絕）
for h in rest01 rest02; do
  url=https://$h.poc.lab:8082/v3/clusters

  printf '%s legacy-app=%s other-cert=%s no-cert=%s\n' \
    "$h" \
    "$(curl -s -o /dev/null -m 30 -w '%{http_code}' $legacy $url)" \
    "$(curl -s -o /dev/null -m 30 -w '%{http_code}' $other $url)" \
    "$(curl -s -o /dev/null -m 30 -w '%{http_code}' $url)"
done

# 4. 經 LB
echo "via LB: $(curl -s -o /dev/null -m 30 -w '%{http_code}' $legacy https://rest.poc.lab:8082/v3/clusters)"
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

**這一節在做什麼**：定出之後每次重啟 REST Proxy 的標準做法（先請 LB 團隊把那一台停用，等連線排空再重啟），避免應用程式在重啟那幾秒收到錯誤。原因：nginx 社群版只有被動健康檢查（`max_fails`）：REST 重啟的那幾秒，要先有請求失敗，LB 才把它標成故障、改送另一台（遷移實測：換 JDK 時重啟 REST，經 LB 失敗 4 次）。行內的 LB 就算有主動健康檢查，也是「停了之後才發現」。所以之後**每次重啟 REST**（15、17、20、21、26、29、30 章）都照這個順序：

1. LB 團隊停用 rest01 → 2. 小安等連線排空、重啟 rest01、確認 200 → 3. LB 團隊恢復 rest01、停用 rest02 → 4. 小安重啟 rest02 → 5. LB 團隊恢復 rest02

**待銀行確認**：行內 LB 是哪一種設備、變更時段能否由 LB 團隊配合停用／恢復成員（問題清單 5.6）。

@role 小安 | ops02 | root

小安這邊寫成一支小腳本：先看那台的 8082 還有沒有從 LB 進來的連線（等到 0 才動；60 秒還有就停下，多半是 LB 還沒停用），再做重啟前要做的事（`-c` 複製檔案過去、`-b` 在那台執行，例如換證、升級套件），重啟（`-r` 改成重開機），等到 200：

```bash
cat > ~/conf/rest-restart.sh <<'EOF'
#!/usr/bin/env bash
# rest-restart.sh <rest01|rest02> [-c "本機檔案…"] [-b '在那台先執行的指令'] [-r]
# 做什麼：安全地重啟一台 REST Proxy：等 LB 那邊進來的連線排空 → -c 的檔案 scp 到那台的 /tmp/ → 在那台執行 -b
#   → 重啟 confluent-kafka-rest（-r：改成重開機）→ 等到 REST 回 200。排空等不到就停下，什麼都不做
# 前提：這台已經由 LB 團隊停用（lb-member.sh <主機> down）
# 用到的檔案：操作機的 ~/pki/certs/app-legacy-billing.crt 與它的私鑰（用來打 /v3/clusters 確認回 200）
# 改的時候要注意：最後一行輸出（例「rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）」）手冊的預期輸出有用到；結束碼 0 = REST 回 200

host=$1
shift
copy=""
before=":"
reboot=0

# 1. 參數
while getopts c:b:r option; do
  case $option in
    c) copy=$OPTARG ;;
    b) before=$OPTARG ;;
    r) reboot=1 ;;
    *)
      echo "用法：$0 <主機> [-c 檔案] [-b 指令] [-r]"
      exit 2
      ;;
  esac
done

# lb_connections：這台 8082 上從 LB 進來、還連著的連線數
lb_ip=$(getent hosts lb01.poc.lab | awk '{print $1}')

lb_connections() {
  ssh $host.poc.lab "ss -Htn state established '( sport = :8082 )'" | grep -c " $lb_ip:"
}

# 2. 等連線排空：每 2 秒看一次，最多等 60 秒
for waited in $(seq 0 2 60); do
  count=$(lb_connections)

  if [ "$count" = 0 ]; then
    break
  fi

  sleep 2
done

if [ "$count" != 0 ]; then
  echo "$host：60 秒後 LB 還有 $count 條連線進來，LB 團隊停用了嗎？沒有重啟"
  exit 1
fi

# 3. 重啟前：複製檔案、在那台執行指令（任何一個失敗就不重啟）
if [ -n "$copy" ]; then
  if ! scp -q $copy $host.poc.lab:/tmp/; then
    echo "$host：複製檔案失敗，沒有重啟"
    exit 1
  fi
fi

if ! ssh $host.poc.lab "$before"; then
  echo "$host：重啟前的步驟失敗，沒有重啟"
  exit 1
fi

start=$(date +%s)

# 4. 重啟服務（-r：重開機）
#    lab 的主機是容器：共用 WSL2 的核心，systemctl reboot 會失敗（Could not activate remote peer），所以 -r 在容器上改成重啟服務
if [ $reboot = 1 ]; then
  if ssh $host.poc.lab 'systemd-detect-virt -cq'; then
    reboot=0
    echo "$host：這台是容器，不能重開機，改重啟 confluent-kafka-rest"
  fi
fi

if [ $reboot = 1 ]; then
  ssh $host.poc.lab 'sudo systemctl reboot' 2> /dev/null
  sleep 15

  # 等它開回來：每 5 秒試一次 ssh，最多試 60 次
  for i in $(seq 1 60); do
    if ssh -o ConnectTimeout=5 $host.poc.lab true 2> /dev/null; then
      break
    fi

    sleep 5
  done
else
  ssh $host.poc.lab 'sudo systemctl restart confluent-kafka-rest'
fi

# 5. 等 REST 回 200：每 3 秒試一次，最多試 60 次
for i in $(seq 1 60); do
  code=$(curl -s -m 5 \
    --cert ~/pki/certs/app-legacy-billing.crt \
    --key ~/pki/keys/app-legacy-billing.key \
    -o /dev/null -w '%{http_code}' \
    https://$host.poc.lab:8082/v3/clusters)

  if [ "$code" = 200 ]; then
    break
  fi

  sleep 3
done

# 6. 結果；不是 200 就以失敗結束
if [ $reboot = 1 ]; then
  action=重開機
else
  action=重啟
fi

echo "$host：排空等了 ${waited} 秒，${action}後 REST $code（約 $(( $(date +%s) - start )) 秒）"

if [ "$code" != 200 ]; then
  exit 1
fi
EOF

chmod 0700 ~/conf/rest-restart.sh
echo rest-restart.sh ok
```

```out
rest-restart.sh ok
```

演練一次：背景每 0.2 秒經 LB 打一次 REST，照五步走完，最後數非 200 的次數：

```bash
# 1. 探測程式：每 0.2 秒經 LB 打一次 REST，一行一筆「時間 狀態碼」寫進 /tmp/lbprobe.log
cat > /tmp/lbprobe.sh <<'EOF'
while true; do
  code=$(curl -s -m 5 \
    --cert ~/pki/certs/app-legacy-billing.crt \
    --key ~/pki/keys/app-legacy-billing.key \
    -o /dev/null -w %{http_code} \
    https://rest.poc.lab:8082/v3/clusters)
  echo "$(date +%T) $code" >> /tmp/lbprobe.log
  sleep 0.2
done
EOF

# 2. 清掉上一次的紀錄，放到背景跑（程序編號記在 /tmp/lbprobe.pid，最後用它停掉）
rm -f /tmp/lbprobe.log
nohup bash /tmp/lbprobe.sh > /dev/null 2>&1 &
echo $! > /tmp/lbprobe.pid
echo "探測開始"
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
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
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
# 1. 停掉探測
kill $(cat /tmp/lbprobe.pid)
sleep 1

# 2. 一共打了幾次、幾次不是 200（第 2 欄是狀態碼）
total=$(wc -l < /tmp/lbprobe.log)
failed=$(awk '$2 != 200 {c++} END {print c + 0}' /tmp/lbprobe.log)
echo "經 LB 打了 $total 次，非 200：$failed"
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

C3 套件有三個服務：內建 Prometheus、Alertmanager（Go 程式，吃 PEM 檔）和 C3 本身。內建的 Prometheus、Alertmanager 是給 C3 自己的畫面用的；**監控與告警不走它們**（第 17 章用行內的 Prometheus、Alertmanager、Grafana），所以這一章只把它們設到 C3 畫面能用，不要在 C3 畫面建 alert trigger 或 action。銀行沒有 Prometheus 時，第 32 章讓內建的 Prometheus 多抓 10 台的 7071、套第 17 章同一份規則，再由另一個 Alertmanager 送 omnibus（C3 畫面的部分不變）。

```bash
scp -q ~/pki/certs/truststore.p12 ~/pki/certs/svc-c3.p12 ~/pki/certs/svc-c3.crt ~/pki/keys/svc-c3.key \
  ~/pki/certs/bank-root.pem ~/pki/certs/mds-token-public.pem \
  c3-01.poc.lab:/tmp/

# 在 c3-01 執行 EOF 之前的那一段：建目錄（root:confluent 0750）、放檔案（0640）（bash -e：任何一行失敗就停）
ssh c3-01.poc.lab bash -e -s <<'EOF'
sudo install -d -o root -g root -m 0755 /etc/confluent
sudo install -d -o root -g confluent -m 0750 /etc/confluent/ssl /etc/confluent/control-center

for f in truststore.p12 svc-c3.p12 svc-c3.crt svc-c3.key mds-token-public.pem; do
  sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/
done

# 銀行根憑證：Prometheus、Alertmanager 要 PEM 檔，放成 ca.pem
sudo install -o root -g confluent -m 0640 /tmp/bank-root.pem /etc/confluent/ssl/ca.pem
rm -f /tmp/*.p12 /tmp/svc-c3.* /tmp/bank-root.pem /tmp/mds-token-public.pem

echo "c3-01: $(sudo ls /etc/confluent/ssl | wc -l) files"
EOF
```

```out
c3-01: 6 files
```

接著是內建 Prometheus、Alertmanager 的 TLS（要求 client 憑證）與設定。C3 這台只有一張憑證，全部用自己的 `svc-c3`：

| 誰、對誰 | 出示的憑證 | 說明 |
|---|---|---|
| C3 9021、Prometheus、Alertmanager、JMX exporter（當 server） | `svc-c3` | 同時有 serverAuth 與 clientAuth |
| C3（Java）連 MDS、Prometheus、Alertmanager，Prometheus（Go）連 Alertmanager（當 client） | `svc-c3` | 同一張 |

> 陷阱（lab 實測，C3 2.5.1）：C3 的健康檢查（連 MDS、9090、9093）拿 **REST listener 的 keystore**（`confluent.controlcenter.rest.ssl.keystore.*`）當 client 憑證，`confluent.metadata.ssl.*`、`prometheus.ssl.*` 在這條路徑沒有作用。如果 REST listener 放只有 serverAuth 的憑證，對方會以 `certificate specifies an incompatible key usage` 拒絕，C3 判定 MDS 全部不健康：**AD 使用者登入與所有 API 都失敗（500／502，`failed to connect to any MDS server`），但服務 active、首頁照樣 200**。所以 C3 的 REST keystore 一定要用同時有兩種用途的 `svc-c3`，而且驗收要帶身分呼叫 C3（這一章最後一步）。

> 取捨：`svc-c3` 是 SystemAdmin，它的私鑰以 PEM 檔放在 c3-01（`root:confluent 0640`，Prometheus、Alertmanager 是 Go 程式，只吃 PEM），能讀這個檔的人就有 SystemAdmin 權限。這台的 root 與 `confluent` 群組要納入管制。

Prometheus／Alertmanager 的 `client_auth_type` 只驗憑證鏈與用途，不看 CN，所以不用另外設定誰能連。`*-generated.yml` 是 C3 自己會寫的檔，擁有者要是 `cp-control-center`：

```bash
# 在 c3-01 執行 EOF 之前的那一段（bash -e：任何一行失敗就停）
ssh c3-01.poc.lab bash -e -s <<'EOF'
cd /etc/confluent-control-center

# 1. Prometheus 與 Alertmanager 的 TLS：svc-c3 當 server 憑證，要求 client 出示銀行簽的憑證（兩個服務用同一份）
sudo tee web-config-prom.yml > /dev/null <<'WEB'
tls_server_config:
  cert_file: /etc/confluent/ssl/svc-c3.crt
  key_file: /etc/confluent/ssl/svc-c3.key
  client_ca_file: /etc/confluent/ssl/ca.pem
  client_auth_type: RequireAndVerifyClientCert
  min_version: TLS12
WEB
sudo cp web-config-prom.yml web-config-am.yml

# 2. 內建 Prometheus 的設定（最後的 otlp、storage 兩段不能省，見下面的陷阱）
sudo tee prometheus-generated.yml > /dev/null <<'PROM'
global:
  scrape_interval: 60s
  evaluation_interval: 60s
alerting:
  alertmanagers:
    - scheme: https
      tls_config:
        ca_file: /etc/confluent/ssl/ca.pem
        cert_file: /etc/confluent/ssl/svc-c3.crt
        key_file: /etc/confluent/ssl/svc-c3.key
      static_configs:
        - targets:
            - c3-01.poc.lab:9093
rule_files:
  - "recording_rules-generated.yml"
  - "trigger_rules-generated.yml"
scrape_configs:
otlp:
  promote_resource_attributes:
    - "host.hostname"
    - "java.version"
    - "kafka.broker.id"
    - "kafka.cluster.id"
    - "kafka.version"
    - "type"
storage:
  tsdb:
    out_of_order_time_window: 10m
PROM

echo "c3-01: prometheus files written"
EOF
```

```out
c3-01: prometheus files written
```

再設定這些檔案的擁有者與權限，寫 Prometheus 的 systemd drop-in：

```bash
# 在 c3-01 執行 EOF 之前的那一段（bash -e：任何一行失敗就停）
ssh c3-01.poc.lab bash -e -s <<'EOF'
cd /etc/confluent-control-center

# 3. 擁有者與權限：我們寫的三個給 root；C3 自己會改寫的 4 個 generated 檔給 cp-control-center
sudo chown root:confluent web-config-prom.yml web-config-am.yml prometheus-generated.yml
sudo chmod 0640 web-config-prom.yml web-config-am.yml prometheus-generated.yml
generated="alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml"
generated="$generated prometheus-generated-local.yml"
sudo chown cp-control-center:confluent $generated
sudo chmod 0640 $generated

# 4. Prometheus 的 drop-in：資料保留 2 天、聽 9090
sudo install -d -m 0755 /etc/systemd/system/prometheus.service.d
sudo tee /etc/systemd/system/prometheus.service.d/10-override.conf > /dev/null <<'UNIT'
[Service]
Environment="METRICS_RETENTION_DAYS=2d"
Environment="PROMETHEUS_HOST=0.0.0.0"
Environment="PROMETHEUS_PORT=9090"
UNIT
sudo systemctl daemon-reload

echo "c3-01: prometheus config ok"
EOF
```

```out
c3-01: prometheus config ok
```

> 陷阱：`*-generated.yml` 若是 root 擁有，C3 啟動會報 `AccessDeniedException`。
>
> 陷阱：上面最後兩段（`otlp`、`storage`）是從 C3 套件預設的 `prometheus-generated-local.yml` 抄來的，**不能省**。broker 用 OTLP 把指標送進 Prometheus，`promote_resource_attributes` 才會把資源屬性 `kafka.cluster.id`、`kafka.broker.id` 變成指標標籤。沒有它，指標沒有叢集標籤，C3 畫面上依叢集、broker 篩選的圖表都比對不到資料，而畫面看起來一切正常（2026-10-26 lab 實測：補上之後 40 秒內帶標籤的資料點從 0 變成 7 萬多筆）。

> 這一章裝的 C3 是**基底的 2.5.1**。2.5.1 套件預設的 `prometheus-generated-local.yml` 就有同樣的 `otlp`、`storage` 兩段，和 2.6.1 逐字相同（2026-10-28 把兩個 RPM 的 `/etc/confluent-control-center/` 逐檔比對，唯一差別是 `control-center-dev.properties` 多一行 `confluent.controlcenter.docs.host`；`control-center.properties` 與 systemd 的三個 unit 檔相同）。
>
> 所以這一章的設定在 2.5.1 與遷移後的 2.6.1 都適用：29.3 換 C3 版本時不用改設定，只要把 C3 自己寫的 4 個 generated 檔擁有者改回來。

C3 設定檔（整段貼到 EOF）。一樣看最後一行的 `unresolved=0` 與 `exec=`：

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
confluent.controlcenter.rest.ssl.keystore.location=/etc/confluent/ssl/svc-c3.p12
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
confluent.controlcenter.prometheus.ssl.keystore.location=/etc/confluent/ssl/svc-c3.p12
confluent.controlcenter.prometheus.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.prometheus.alias.name=svc-c3
confluent.controlcenter.alertmanager.url=https://c3-01.poc.lab:9093
confluent.controlcenter.alertmanager.config.file=/etc/confluent-control-center/alertmanager-generated.yml
confluent.controlcenter.alertmanager.ssl.truststore.location=/etc/confluent/ssl/truststore.p12
confluent.controlcenter.alertmanager.ssl.truststore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.keystore.location=/etc/confluent/ssl/svc-c3.p12
confluent.controlcenter.alertmanager.ssl.keystore.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.ssl.key.password=${STORE_PASSWORD}
confluent.controlcenter.alertmanager.alias.name=svc-c3
EOF

cd ~/conf

# 1. 設定檔（檔案 0600）
export STORE_PASSWORD=$(cat ~/pki/store.pass)
install -m 0600 /dev/null c3-01.control-center.properties
envsubst '${STORE_PASSWORD}' < control-center.tpl > c3-01.control-center.properties
unset STORE_PASSWORD

# 2. 派送設定檔、建資料目錄、systemd drop-in，再確認（bash -e：任何一行失敗就停）
scp -q c3-01.control-center.properties c3-01.poc.lab:/tmp/control-center.properties

ssh c3-01.poc.lab bash -e -s <<'EOF'
sudo install -o root -g confluent -m 0640 \
  /tmp/control-center.properties \
  /etc/confluent/control-center/control-center.properties
rm -f /tmp/control-center.properties
sudo install -d -o cp-control-center -g confluent -m 0750 /var/lib/confluent/control-center

# drop-in：等 MDS 起來才啟動（ExecStartPre），用我們的設定檔
sudo install -d -m 0755 /etc/systemd/system/confluent-control-center.service.d
sudo tee /etc/systemd/system/confluent-control-center.service.d/10-override.conf > /dev/null <<'UNIT'
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
UNIT
sudo systemctl daemon-reload

# 確認：行數、沒換掉的 ${（要是 0）、ExecStart 指向我們的設定檔
file=/etc/confluent/control-center/control-center.properties
lines=$(sudo grep -c . $file)
unresolved=$(sudo awk '/\$\{/ {c++} END {print c + 0}' $file)
exec_file=$(systemctl show confluent-control-center -p ExecStart --value | grep -o "/etc/[^ ]*properties")
echo "c3-01: config $lines lines, unresolved=$unresolved, exec=$exec_file"
EOF
```

```out
c3-01: config 64 lines, unresolved=0, exec=/etc/confluent/control-center/control-center.properties
```

依序啟動，等 UI：

```bash
# 1. 在 c3-01 依序啟動 Prometheus、Alertmanager、C3（已經在跑的也重啟）
ssh c3-01.poc.lab bash -s <<'EOF'
for unit in prometheus alertmanager confluent-control-center; do
  sudo systemctl enable --now $unit > /dev/null 2>&1
  sudo systemctl restart $unit
  sleep 3
  printf "%-26s %s\n" $unit "$(systemctl is-active $unit)"
done
EOF

# 2. 內建 Prometheus 就緒（它要求 client 憑證，從操作機用 svc-ops 的）
echo "prometheus=$(curl -s -o /dev/null -w '%{http_code}' \
  --cert ~/pki/certs/svc-ops.crt \
  --key ~/pki/keys/svc-ops.key \
  https://c3-01.poc.lab:9090/-/ready)"

# 3. 等 C3 畫面回 200：每 10 秒試一次，最多試 24 次（還連不上時狀態碼是 000）
for i in $(seq 1 24); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 10
done

echo "c3 ui=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://c3-01.poc.lab:9021/) after ~$((i*10))s"

# 4. alice 真的從 C3 登入（首頁不經過 MDS，只看 200 抓不到；C3 起來後健康檢查還要一點時間，最多等 60 秒）
password=$(cat ~/secrets/ad-test-users.pass)
url=https://c3-01.poc.lab:9021/api/metadata/security/1.0/authenticate

for i in $(seq 1 12); do
  if [ "$(curl -s -u "alice:$password" -o /dev/null -m 30 -w '%{http_code}' $url)" = 200 ]; then
    break
  fi

  sleep 5
done

echo "alice 從 C3 登入：$(curl -s -u "alice:$password" -o /dev/null -m 30 -w '%{http_code}' $url)"
unset password
```

```out
prometheus                 active
alertmanager               active
confluent-control-center   active
prometheus=200
c3 ui=200 after ~30s
alice 從 C3 登入：200
（第一次啟動 30–120 秒都正常）
```

確認指標真的帶有叢集標籤（上面那個陷阱的檢查）。內建 Prometheus 的 9090 要求 client 憑證（只認銀行簽、有 clientAuth 的憑證），所以在 c3-01 上用它自己的 `svc-c3` 憑證查：

```bash
ssh c3-01.poc.lab bash -s <<'REMOTE'
# 有幾個 node id 的指標帶 kafka_broker_id 標籤
query='count(count by (kafka_broker_id) ({kafka_broker_id=~".+"}))'

# 每 10 秒問一次內建 Prometheus，最多問 18 次；大於 0 就停（查不到結果時當成 0）
#   回應裡要的那一段長這樣："value":[1793000000.123,"7"]，用 " 切開的第 4 欄就是 7
n=0
for i in $(seq 1 18); do
  answer=$(sudo curl -s \
    --cacert /etc/confluent/ssl/ca.pem \
    --cert /etc/confluent/ssl/svc-c3.crt \
    --key /etc/confluent/ssl/svc-c3.key \
    --data-urlencode "query=$query" \
    https://c3-01.poc.lab:9090/api/v1/query | grep -o '"value":\[[0-9.]*,"[0-9]*"' | cut -d'"' -f4)

  if [ -n "$answer" ]; then
    n=$answer
  fi

  if [ "$n" -gt 0 ]; then
    break
  fi

  sleep 10
done

echo "指標帶 kafka_broker_id 標籤的節點數：$n（等了約 $((i*10)) 秒）"
REMOTE
```

```out
指標帶 kafka_broker_id 標籤的節點數：7（等了約 10 秒）
```

只要大於 0 就代表標籤有帶上來。數字會隨 telemetry 陸續送進來而增加，穩定後是 7（4 台 broker 加 3 台 controller，各自的 node id；telemetry 還沒全部送到時會小於 7，實測看過 5）。**0 代表缺 `otlp` 設定，或 broker 的 telemetry 沒送進來**，C3 畫面上的圖會是空的。

lab 裡：Windows 瀏覽器開 `https://localhost:19021`（正式環境是維運人員直連 C3 的 9021），用 alice 登入（密碼在 `~/secrets/ad-test-users.pass`）。憑證是銀行 CA 簽的，瀏覽器沒裝銀行根憑證會有警告，lab 先略過。Alertmanager 的 9093 只開給同一台的 C3，從操作機連不到是正常的。

# 14. 第十四站：基本功能驗收（小安的檢查清單）

**這一章在做什麼**：基本安裝（第 2–13 章）到此告一段落。前提：第 13 章的 C3 已經能登入。這一章先用一條指令確認整套健康，再給出「出問題先看哪裡」、「做錯了怎麼重來」、「常見的坑」三張查詢表，最後交代後面章節的走法。完成的樣子：7 台 `confluent-server` 都 `active`、quorum 有 leader、4 台 MDS 回 200、REST Proxy 經 LB 與 C3 畫面都回 200。

到這裡平台已經能用，但還不能交付。後面分兩段：

- **交付前一定要做**：第 15 章把設定檔裡的密碼加密（master key 只放操作機與各主機）；第 16 章維運選單；第 17 章監控（JMX exporter，交付行內 Prometheus、Alertmanager、Grafana 的設定）；第 18 章稽核日誌；第 26.2 的 license 到期排程、第 23 章每日備份；最後第 19 章驗收與收尾。
- **遷移到目標版本**（主線，裝完基底的下一步）：第 29 章遷移 Confluent 與 JDK（8.2.4 → 8.3.2、JDK 21 → 25，C3 2.5.1 → 2.6.1）、第 30 章 OS 小版本更新（9.6 → 9.8）；每一段之後再跑第 19 章驗收。
- **上線之後依需要**：第 21 章憑證輪替（每年）、25.1 節換 controller、25.2 節增減 broker、第 30 章每月 OS 修補、第 31 章單獨換 Control Center 版本。

@role 小安 | ops02 | root

一條指令跑完所有檢查；看每行最後的狀態：服務要 `active`、HTTP 要 200、`LeaderId` 要有數字、`topics` 要列得出第 11 章建的 topic：

```bash
export JAVA_HOME=/opt/java/current

# 1. 7 台 confluent-server
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  printf "%-5s %s\n" $h "$(ssh $h.poc.lab systemctl is-active confluent-server)"
done

# 2. quorum 有 leader
kafka-metadata-quorum \
  --bootstrap-controller kc01.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties \
  describe --status | grep LeaderId

# 3. 4 台 MDS（印在同一行）
for h in kb01 kb02 kb03 kb04; do
  printf "%s MDS=%s " $h "$(curl -s -o /dev/null -m 5 -w %{http_code} https://$h.poc.lab:8090/v1/metadata/id)"
done
echo

# 4. 第 11 章建的 topic（_ 開頭的內部 topic 不列）
topics=$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --list | grep -v '^_' | paste -sd' ')
echo "topics: $topics"

# 5. REST Proxy 經 LB、C3 畫面
echo "rest via LB: $(curl -s -o /dev/null -m 30 -w %{http_code} \
  --cert ~/pki/certs/app-legacy-billing.crt \
  --key ~/pki/keys/app-legacy-billing.key \
  https://rest.poc.lab:8082/v3/clusters)"
echo "c3 ui: $(curl -s -o /dev/null -m 10 -w %{http_code} https://c3-01.poc.lab:9021/)"

# 首頁不經過 MDS，只看 200 抓不到登入壞掉；這裡用 alice 真的從 C3 登入
alice_pass=$(cat ~/secrets/ad-test-users.pass)
echo "c3 login: $(curl -s -o /dev/null -m 30 -w %{http_code} \
  -u "alice:$alice_pass" \
  https://c3-01.poc.lab:9021/api/metadata/security/1.0/authenticate)"

# 6. 內建 Prometheus 收到幾種 Confluent 的指標
all_names=$(curl -s -m 10 \
  --cert ~/pki/certs/svc-ops.crt \
  --key ~/pki/keys/svc-ops.key \
  https://c3-01.poc.lab:9090/api/v1/label/__name__/values)
kinds=$(echo "$all_names" | grep -o 'confluent_kafka_server[a-z_]*' | sort -u)
echo "metrics in prometheus: $(echo "$kinds" | wc -l) kinds"
```

```out
kc01  active
（7 行 active）
LeaderId:               1
kb01 MDS=200 kb02 MDS=200 kb03 MDS=200 kb04 MDS=200
topics: billing.events confluent-audit-log-events orders.events payments.events poc-cluster-2-5-1-10-AlertHistoryStore-changelog …
rest via LB: 200
c3 ui: 200
c3 login: 200
metrics in prometheus: 111 kinds
（C3 起來後會自己建幾個 poc-cluster-… 開頭的 topic；metrics 種類 100 多種都正常）
```

| 已完成 | 還沒做（之後的旅程） |
|---|---|
| 11 台主機就緒、套件裝好並鎖版本 | 設定檔密碼加密、master key 只放操作機與各主機（第 15 章） |
| 7 張銀行憑證、truststore、MDS token 金鑰 | 維運選單（OP menu）；稽核日誌分流與專用寫入帳號 |
| controller、broker、MDS、RBAC（人員綁 AD 群組） | 外部監控：JMX exporter（7071）與行內 Prometheus、Alertmanager、Grafana 的設定（第 17 章） |
| 應用程式 SCRAM 帳號、配額、範例 topic | 正式的端對端驗收清單 |
| REST Proxy（憑證認證，經負載平衡）、C3（含 Prometheus） | 收回安裝帳號的 sudo、移交文件；之後的憑證輪替（第 21 章）、升級（第 29 章） |

## 14.1 出問題先看哪裡

| 元件 | 主機 | 服務名稱 | 看日誌 | 健康檢查 |
|---|---|---|---|---|
| controller、broker | kc*、kb* | `confluent-server` | `sudo journalctl -u confluent-server -n 100 --no-pager`；MDS 與授權器另在 `/var/log/kafka/metadata-service.log`、`kafka-authorizer.log`（不在 journal） | quorum 有 leader；broker 的 `https://<host>:8090/v1/metadata/id` 回 200 |
| REST Proxy | rest* | `confluent-kafka-rest` | `sudo journalctl -u confluent-kafka-rest -n 100 --no-pager` | 帶 legacy 憑證 `curl …:8082/v3/clusters` 回 200 |
| Control Center | c3-01 | `confluent-control-center`、`prometheus`、`alertmanager` | `sudo journalctl -u confluent-control-center -n 100 --no-pager` | `https://c3-01.poc.lab:9021/` 回 200，且 alice 從 C3 登入回 200（首頁不經過 MDS，見第 13 章） |
| AD | ad01 | samba（entrypoint 常駐） | lab 裡：`podman logs lab-ad01-1` | `openssl s_client -connect ad01.poc.lab:636` 驗證通過 |
| 套件庫 | repo01 | `httpd` | lab 裡：`podman exec lab-repo01-1 journalctl -u httpd -n 50` | `https://repo01.poc.lab/confluent/repodata/repomd.xml` 回 200 |

任何服務起不來或行為不對，先看三件事：服務是不是 `active`、ExecStart 指向哪份設定、日誌最後 20 行的 ERROR。九成的問題在這裡。

> 陷阱：broker 是 `active`、9092 也開了，但 9094／9095／9096 和 MDS 的 8090 一直沒開，日誌最後停在 `Waiting for all of the authorizer futures to be completed`、之後沒有任何 ERROR：多半是 AD 查詢帳號（svc-mds-bind）的密碼和 AD 上的不一致。broker 第一次向 AD 查群組失敗後只會安靜地重試，不印原因。對齊密碼（`ldap-bind.pass` 與 AD 帳號）後不用重啟，它會自己接著起來。

## 14.2 做錯了怎麼重來

| 步驟 | 能不能重跑 | 怎麼做 |
|---|---|---|
| 派送憑證、設定檔、drop-in（第 10–13 章） | 可以，重跑就是覆蓋成一樣的內容 | 改完記得 `sudo systemctl restart <unit>` |
| 格式化儲存（10.4） | **不能**，`meta.properties` 存在就會拒絕 | 真要重來：停服務、`sudo find /var/lib/kafka/data -mindepth 1 -delete`（不要用 `rm -rf …/*`：經 ssh 時萬用字元由 cpuser 展開、讀不到 0750 的目錄，什麼都沒刪；也刪不到 `.kafka_cleanshutdown`），所有 controller 和 broker 一起重做（26.4 是完整做法） |
| 憑證（第 9 章） | 可以，重新產生 CSR 再請銀行簽 | 舊的 `~/pki` 先改名保留；已經上線的環境照第 21 章換發，不要重跑第 9 章 |
| 裝套件（第 8 章） | 可以，dnf 看到已安裝就略過 | `versionlock add` 對已鎖的套件會再加一筆重複，重跑前先 `sudo dnf versionlock list` 看一下，已鎖的不要再加 |
| 整台主機重置 | lab 可以；正式環境由銀行重新交付主機 | 先 `podman compose -f compose.yml rm -sf <host>`，再 `podman compose -f compose.yml up -d <host>`，然後對那台重做：5.1（根憑證信任與 OS 套件來源）、7.1 節（JDK）、7.3 節（OS 調校）、第 8 章（套件），以及它的角色在第 10、12、13 章的派送與啟動 |

## 14.3 小安踩過的坑

| 坑 | 症狀 | 怎麼避免 |
|---|---|---|
| 服務用 RPM 預設設定起來 | REST Proxy 開成無加密 HTTP；C3 連不上 Kafka | 啟動前看 `systemctl show <unit> -p ExecStart`，一定要指向我們的設定檔 |
| `enable --now` 不重啟 | 改了設定沒生效 | 改設定後明確 `systemctl restart` |
| 確認指令沒加 `sudo` | `ls /etc/confluent/ssl` Permission denied，以為沒放進去 | 0750 的目錄要 `sudo ls`、`sudo stat` |
| 相對路徑 | `scp certs/cp-server.p12` 只在特定目錄下才找得到 | 指令裡一律寫 `~/pki/certs/…` |
| C3 比 MDS 先起來 | 9021 不回應、日誌 `Failed to fetch MDS URLs … Client has already been closed`，而且不會自己好 | drop-in 加 `ExecStartPre` 等 MDS（第 13 章已加）；broker 全部重啟過一輪後若 C3 卡住，`systemctl restart confluent-control-center` |
| lab 專用：Git Bash 的 openssl 看不懂 `/c/Users/...` | `sign.sh` 靜靜失敗、沒有產出 `.crt` | 路徑先用 `cygpath -m` 轉成 `C:/Users/...`（0.5 的腳本已內建） |
| lab 專用：Podman 網段撞到別的 lab | `compose up` 報 `Pool overlaps` | 換 compose.yml 的 subnet 與 extra_hosts 的 IP（0.6） |
| C3 的 `*-generated.yml` 是 root 擁有 | `AccessDeniedException` | 四個 generated 檔給 `cp-control-center:confluent` |
| dnf 快取太舊 | 剛上架的套件「找不到」 | 加 `--refresh` |
| lab 專用：建銀行 OS 套件庫（5.1）時先裝工具再下載 | 套件庫少了 `createrepo_c-libs` | 乾淨容器，先下載、再裝工具 |
| lab 專用：WSL VM 網路層卡死 | 所有 Java 都變慢、`podman stats` 也卡 | 任一容器 `timeout 5 ip addr` 卡住就重啟 machine（依序 `podman machine stop kafka-lab`、`podman machine start kafka-lab`），不要查設定 |

# 15. 第十五站：Secret Protection，加密設定檔裡的密碼

下面這張圖說明 passphrase、master key、密文三者的關係與各自放哪裡。

![keyhier]

![secretprotection]

**這一章在做什麼**：讓設定檔裡不再有明文密碼。小安用 Confluent 的 Secret Protection 把密碼加密，解密用的 master key 只放在操作機與各主機 root 才讀得到的位置（不放 CyberArk）。前提：第 10–13 章的服務都已經起來、第 9 章的 `~/pki/store.pass` 與 `~/secrets/` 裡的密碼檔都在。這一章會**滾動重啟**所有 controller、broker、REST Proxy、C3（15.5），請在變更時段一台一台做。

設定檔裡的密碼要加密。本案沒有可以在服務啟動時取值的保管庫，所以用 Confluent 自己的 **Secret Protection**：密碼加密後留在主機上的 `security.properties`，解密用的 master key 放在各主機的 `/etc/confluent/service.env`（0600 root），啟動時經環境變數給服務。

```
passphrase ──(＋隨機 salt)──▶ master key ──▶ data key ──▶ 各個密碼的密文（security.properties）
（操作機，0600）               （操作機與各主機，0600）
                                   │
                        各主機 /etc/confluent/service.env（0600 root）→ systemd EnvironmentFile → 服務環境變數
```

| 誰 | 做什麼 |
|---|---|
| 小安 | 產生 passphrase 與 master key、加密 properties、派送、滾動重啟；之後的 master key 輪替也是他 |

**為什麼兩樣都要存**（lab 實測）：master key 是 passphrase 加上一個隨機 salt 算出來的，salt 每次 `generate` 都重新產生，所以**只有 passphrase 算不回原本的 master key**；反過來，輪替 master key（20.3）時 CLI 要「目前的 master key＋舊 passphrase」兩樣都給。兩樣放的地方不同：master key 要給啟動服務的一方（每台主機的 `service.env`），passphrase 主機不應該讀得到，所以只放操作機。

## 15.1 產生 passphrase

@role 小安 | ops02 | root

passphrase 由小安在操作機產生，放進 0600 的檔（已經有就不重產）：

```bash
# 已經有（而且不是空的）就不重產
if [ ! -s ~/secrets/sp-passphrase.txt ]; then
  install -m 0600 /dev/null ~/secrets/sp-passphrase.txt
  openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > ~/secrets/sp-passphrase.txt
fi

echo "passphrase: $(wc -c < ~/secrets/sp-passphrase.txt) chars"
```

```out
passphrase: 32 chars
```

## 15.2 產生 master key

@role 小安 | ops02 | root

用 Confluent CLI 產生 master key。`security.properties` 是之後所有密文的容器：

```bash
# 1. 產生 master key（存進 master.key，0600）；security.properties 由 CLI 建立
install -m 0600 /dev/null ~/secrets/master.key
confluent secret master-key generate --local-secrets-file ~/secrets/security.properties \
  --passphrase "$(cat ~/secrets/sp-passphrase.txt)" -o yaml | awk '/master_key/{print $2}' > ~/secrets/master.key

# 2. CLI 建的 security.properties 也改成只有 root 讀得到
chmod 0600 ~/secrets/security.properties

# 3. 確認
echo "master key: $(wc -c < ~/secrets/master.key) chars"
ls -la ~/secrets/security.properties ~/secrets/master.key
```

```out
Save the master key. It cannot be retrieved later.
master key: 45 chars
-rw------- 1 root root  45 … master.key
-rw------- 1 root root 169 … security.properties
```

> 陷阱：`--passphrase` 一定要給**值本身**（`"$(cat 檔案)"`）。Confluent CLI v4 不認 `@檔案`、也不認 `-`（stdin），會把「`@/root/secrets/sp-passphrase.txt`」這串字當成 passphrase：產生、加密、輪替表面上都成功，但自己產生的 passphrase 根本沒用到，任何拿到 `security.properties` 又猜得到路徑的人都算得出 master key；檔案一改名，下一次輪替就 `incorrect master key passphrase`（2026-10-25 lab 實測）。20.3 結尾有檢查。
>
> 給值的代價是執行那一瞬間值會出現在操作機的行程參數裡（`/proc/<pid>/cmdline`）。能登入操作機的人員都是 root（經 PVWA＋PSMP，全程錄影），`hidepid` 擋不住 root，所以這是接受的風險：靠 PVWA 的登入授權與 PSMP 的錄影管住「誰能進操作機」。20.4、20.2 用 `--config`／`--add-config` 帶密碼時也一樣。

「cannot be retrieved later」是 CLI 的提醒：CLI 不保存 master key，而且**再跑一次 `generate` 也拿不回同一把**（會換新的 salt，算出另一把）。所以產生之後馬上確認 `master.key` 存好了（0600）、記下它的雜湊，才往下派送。

@role 小安 | ops02 | root

記下這一把的雜湊和變更單號；之後主機重建、輪替時都用它核對手上的是不是這一把：

```bash
# master key 的 sha256 前 12 碼，加上變更單號（檔案 0600）
fingerprint=$(tr -d '\n' < ~/secrets/master.key | sha256sum | cut -c1-12)
install -m 0600 /dev/null ~/secrets/master-key.custody
echo "$fingerprint CHG-xxxx" > ~/secrets/master-key.custody

cat ~/secrets/master-key.custody
```

```out
3f9c0a… CHG-xxxx
```

> 注意：兩樣都只放在操作機（master key 另外在每台主機的 `service.env`），操作機的備份由銀行的備份機制處理並加密（已列入問題清單）。passphrase 遺失、master key 還在：服務照常，只是不能用 20.3 的 `rotate`；master key 遺失（操作機掉了）：服務照常，從任一台的 `service.env` 取回即可；兩樣都遺失：產生新的 master key、照 15.3–15.5 從明文來源重新加密並滾動重啟（約 30 分鐘，不中斷服務）。

## 15.3 加密每台的 properties

@role 小安 | ops02 | root

先用第 10、12、13 章的方式從範本產生每台的設定（和之前完全一樣，只是這次先留在操作機、不派送），再逐檔加密所有 `password`／`credentials` 欄位。加密後原檔裡的值變成 `${securepass:…}` 參照，密文集中寫進 `security.properties`：

```bash
cd ~/conf

# 1. 密碼讀進變數（稽核帳號的密碼第 18 章才有，還沒有就是空的）；envsubst 只換下面這些變數
export STORE_PASSWORD=$(cat ~/pki/store.pass)
export LDAP_BIND_PASSWORD=$(cat ~/secrets/ldap-bind.pass)
export AUDIT_PASSWORD=$(cat ~/secrets/confluent-audit.pass 2> /dev/null)
vars='${HOST_FQDN} ${NODE_ID} ${RACK} ${REST_ID} ${STORE_PASSWORD} ${LDAP_BIND_PASSWORD} ${AUDIT_PASSWORD}'

# 2. controller、broker：和 10.2 一樣產生（寫法：主機:node.id:rack；檔案 0600）
for entry in kc01:1:- kc02:2:- kc03:3:- kb01:101:rack-a kb02:102:rack-a kb03:103:rack-b kb04:104:rack-b; do
  n=$(echo $entry | cut -d: -f1)
  export HOST_FQDN=$n.poc.lab
  export NODE_ID=$(echo $entry | cut -d: -f2)
  export RACK=$(echo $entry | cut -d: -f3)

  case $n in
    kc*) tpl=controller.tpl ;;
    *)   tpl=broker.tpl ;;
  esac

  install -m 0600 /dev/null $n.server.properties
  envsubst "$vars" < $tpl > $n.server.properties
  echo >> $n.server.properties
  envsubst "$vars" < common.tpl >> $n.server.properties
done

# 3. REST Proxy 兩台、C3：和 12、13 章一樣產生
for h in rest01 rest02; do
  export HOST_FQDN=$h.poc.lab
  export REST_ID=$h
  install -m 0600 /dev/null $h.kafka-rest.properties
  envsubst "$vars" < kafka-rest.tpl > $h.kafka-rest.properties
done

install -m 0600 /dev/null c3-01.control-center.properties
envsubst "$vars" < control-center.tpl > c3-01.control-center.properties

unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD

# 4. 有沒有沒換掉的變數（要是 0 個）
left=$(grep -ho '${[A-Z_]*}' \
  *.server.properties \
  *.kafka-rest.properties \
  c3-01.control-center.properties | sort -u | paste -sd' ')
if [ -z "$left" ]; then
  left="0 個"
fi
echo "沒替換到的變數：$left"
```

```out
沒替換到的變數：0 個
```

再逐檔加密，最後看 `security.properties` 裡的密文筆數：

```bash
cd ~/conf

# 1. 逐檔加密所有 password／credentials 欄位：原檔的值換成 ${securepass:…} 參照，密文寫進 security.properties
#    --config 要的是「欄位名稱,欄位名稱,…」；--remote-secrets-file 是密文檔放在主機上的路徑
export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)

for f in *.server.properties *.kafka-rest.properties c3-01.control-center.properties; do
  keys=$(grep -E '^[^#].*(password|credentials)=' $f | cut -d= -f1 | paste -sd,)

  confluent secret file encrypt --config-file $f --local-secrets-file ~/secrets/security.properties \
    --remote-secrets-file /etc/confluent/secrets/security.properties --config "$keys" > /dev/null

  # 加密了幾個、還剩幾個明文密碼（要是 0）
  encrypted=$(grep -c '\${securepass:' $f)
  plaintext=$(awk '/^[^#].*(password|credentials)=[^$]/ {c++} END {print c + 0}' $f)
  echo "$f: $encrypted encrypted, plaintext=$plaintext"
done

unset CONFLUENT_SECURITY_MASTER_KEY

# 2. security.properties 裡的密文筆數（_ 開頭的是 metadata，不算）
echo "security.properties: $(grep -c '^[^_].*ENC\[' ~/secrets/security.properties) entries"
```

```out
kb01.server.properties: 17 encrypted, plaintext=0
（broker 17、controller 11、REST 9、C3 18；做過第 18 站的話 broker 19、controller 13。10 個檔 plaintext 都是 0）
security.properties: 137 entries（做過第 18 站是 151）
```

> `${securepass:/etc/confluent/secrets/security.properties:kb01.server.properties/ssl.keystore.password}` 的最後一段是「本機檔名／欄位」，所以同一份 `security.properties` 可以放所有主機的密文，派送時每台拿同一個檔。

## 15.4 派送：properties、密文檔、master key

@role 小安 | ops02 | root

三樣東西到每台：加密後的 properties（原路徑）、`security.properties`（0640 root:confluent）、`service.env`（0600 root，只有一行 master key）。drop-in 加 `EnvironmentFile=`：

```bash
cd ~/conf

# 1. 要放到每台的 service.env：一行 master key（在操作機上暫存 0600，派送完就刪）
install -m 0600 /dev/null ~/secrets/service.env
echo "CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)" > ~/secrets/service.env

for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  # 2. 這台的設定檔、它在主機上的路徑、systemd 服務名稱
  case $h in
    rest*)
      file=$h.kafka-rest.properties
      dest=/etc/confluent/kafka-rest/kafka-rest.properties
      unit=confluent-kafka-rest
      ;;
    c3*)
      file=c3-01.control-center.properties
      dest=/etc/confluent/control-center/control-center.properties
      unit=confluent-control-center
      ;;
    *)
      file=$h.server.properties
      dest=/etc/confluent/kafka/server.properties
      unit=confluent-server
      ;;
  esac

  # 3. 三樣東西送過去，在那台執行 EOF 之前的那一段（$1 = 設定檔名、$2 = 路徑、$3 = 服務；bash -e：任何一行失敗就停）
  scp -q $file ~/secrets/security.properties ~/secrets/service.env $h.poc.lab:/tmp/

  ssh $h.poc.lab bash -e -s -- $file $dest $unit <<'EOF'
file=$1
dest=$2
unit=$3

# 加密後的設定檔（原路徑）、密文檔（0640 root:confluent）、master key（0600 root）
sudo install -o root -g confluent -m 0640 /tmp/$file $dest
sudo install -d -o root -g confluent -m 0750 /etc/confluent/secrets
sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties
sudo install -o root -g root -m 0600 /tmp/service.env /etc/confluent/service.env
rm -f /tmp/$file /tmp/security.properties /tmp/service.env

# drop-in：啟動時從 service.env 讀 master key
sudo tee /etc/systemd/system/$unit.service.d/20-secret-protection.conf > /dev/null <<'UNIT'
[Service]
EnvironmentFile=/etc/confluent/service.env
UNIT
sudo systemctl daemon-reload

# 確認：參照數、還剩幾個明文密碼（要是 0）、EnvironmentFile
refs=$(sudo grep -c 'securepass:' $dest)
plaintext=$(sudo awk '/^[^#].*(password|credentials)=[^$]/ {c++} END {print c + 0}' $dest)
env_file=$(systemctl show $unit -p EnvironmentFiles --value | cut -d' ' -f1)
echo "$(hostname): refs=$refs plaintext=$plaintext env=$env_file"
EOF
done

# 4. 刪掉操作機上的暫存（master key 本來就在 ~/secrets/master.key）
rm -f ~/secrets/service.env
```

```out
kc01: refs=11 plaintext=0 env=/etc/confluent/service.env
（10 行；refs 和上一步的 encrypted 數相同）
```

## 15.5 滾動重啟、驗證

加密過的設定要重啟才會生效。順序：controller（一台一台，等 active）→ broker（一台一台，等 MDS 回 200，每台約 20–50 秒）→ C3 → REST Proxy（先請 LB 團隊停用那一台，見 12.1）。每一台健康了才做下一台，這樣叢集一直有多數派可用。

@role 小安 | ops02 | root

```bash
# 1. controller：一台一台重啟，等到 active（在那台每 2 秒看一次，最多 30 次）
for h in kc01 kc02 kc03; do
  ssh $h.poc.lab bash -s <<'EOF'
sudo systemctl restart confluent-server

for i in $(seq 1 30); do
  if systemctl is-active -q confluent-server; then
    break
  fi

  sleep 2
done

echo "$(hostname) $(systemctl is-active confluent-server)"
EOF
done

# 2. broker：一台一台重啟，等 MDS 回 200（每 5 秒看一次，最多 60 次）
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  for i in $(seq 1 60); do
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id) after ~$((i*5))s"
done

# 3. C3：重啟，等畫面回 200（每 5 秒看一次，最多 36 次）
ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'

for i in $(seq 1 36); do
  if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 5
done

echo "c3 ui=$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) after ~$((i*5))s"

# 4. alice 用 AD 帳密登入 MDS（MDS 用解密後的 AD 查詢密碼去驗）
password=$(cat ~/secrets/ad-test-users.pass)
url=https://kb01.poc.lab:8090/security/1.0/authenticate
echo "alice login: $(curl -sk -u alice:$password -o /dev/null -w '%{http_code}' $url)"
unset password
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
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
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
ssh kb01.poc.lab bash -s <<'EOF'
# 1. systemctl show 的 Environment 裡沒有 master key
echo "in systemctl show: $(systemctl show confluent-server -p Environment --value | grep -c MASTER_KEY)"

# 2. 設定檔與密文檔裡各出現幾次 MASTER_KEY 這個字
files="/etc/confluent/kafka/server.properties /etc/confluent/secrets/security.properties"
echo "in properties: $(sudo grep -rc MASTER_KEY $files | paste -sd,)"

# 3. service.env 只有 root 讀得到
echo "service.env: $(sudo stat -c "%U:%G %a" /etc/confluent/service.env)"
EOF
```

```out
in systemctl show: 0
in properties: /etc/confluent/kafka/server.properties:0,/etc/confluent/secrets/security.properties:1
service.env: root:root 600
```

`security.properties` 裡那 1 筆是 `_metadata.symmetric_key.0.envvar=CONFLUENT_SECURITY_MASTER_KEY`，記的是「去哪個環境變數找 master key」，不是 key 本身。檔案開頭幾行 `_metadata.*` 是鹽、迭代次數，和被 master key 包起來的 data key。

最後確認 passphrase 真的有用上（15.2 的陷阱）：在副本上試著輪替一次，正式檔不動。兩個都要是「是」；前一個是「否」代表 master key 不是用 `sp-passphrase.txt` 這組 passphrase 產生的，照 15.6「遺失怎麼辦」重新產生、重新加密：

```bash
# 在副本上試，正式的 security.properties 不動（暫存目錄用完即刪）
tmp=$(mktemp -d)
cp ~/secrets/security.properties $tmp/s
export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)

# 目前的 passphrase、錯的 passphrase（亂數）、兩次都用的新 passphrase（亂數）
passphrase=$(cat ~/secrets/sp-passphrase.txt)
wrong_passphrase="wrong-$(openssl rand -hex 8)"
new_passphrase="check-$(openssl rand -hex 8)"

# 1. 用目前的 passphrase 輪替：要成功（輸出裡有 Save the master key）
ok=$(confluent secret file rotate \
  --master-key \
  --passphrase "$passphrase" \
  --passphrase-new "$new_passphrase" \
  --local-secrets-file $tmp/s \
  -o yaml 2>&1 < /dev/null | awk '/Save the master key/ {c++} END {print c + 0}')

# 2. 用錯的 passphrase 輪替：要被拒（輸出裡有 incorrect master key passphrase）
bad=$(confluent secret file rotate \
  --master-key \
  --passphrase "$wrong_passphrase" \
  --passphrase-new "$new_passphrase" \
  --local-secrets-file $tmp/s \
  -o yaml 2>&1 < /dev/null | awk '/incorrect master key passphrase/ {c++} END {print c + 0}')

unset CONFLUENT_SECURITY_MASTER_KEY passphrase wrong_passphrase new_passphrase
rm -rf $tmp

# 3. 結果：兩個都要是「是」
if [ "$ok" = 1 ]; then
  ok_text=是
else
  ok_text=否
fi

if [ "$bad" = 1 ]; then
  bad_text=是
else
  bad_text=否
fi

echo "目前的 passphrase 還能輪替：$ok_text；錯的 passphrase 被拒：$bad_text"
```

```out
目前的 passphrase 還能輪替：是；錯的 passphrase 被拒：是
```

## 15.6 要跟資安說清楚的事

| 項目 | 說明 |
|---|---|
| secret zero | master key 以一行落在每台主機的 `/etc/confluent/service.env`（0600 root）。本案沒有可以在服務啟動時取值的保管庫，所以 master key 一定落在主機上；資安若不接受磁碟副本，要另外提出需求，不在本手冊範圍 |
| CyberArk 在這裡做什麼 | **只管誰能登入操作機**：人員在 PVWA 登入、由 PSMP 代登成 root，有登入紀錄與錄影。passphrase、master key 不放 CyberArk，服務啟動時也不連 CyberArk |
| 擋得住什麼、擋不住什麼 | 擋得住：設定檔被複製出去（備份、工單附檔、診斷資料、`confluent` 群組的人）時看不到密碼。擋不住：這台主機上的 root（`service.env` 就在本機）。要連 root 都擋，需要啟動時向外取 master key 的機制（本案客戶沒有 CCP，做不到） |
| 遺失怎麼辦 | `rotate` 一定要**同時**有舊 passphrase 和舊 master key（環境變數），CLI 也沒有辦法從 passphrase＋`security.properties` 重新算出 master key（2026-10-25 lab 實測），所以兩樣都要留好（操作機的備份由銀行的備份機制處理並加密）。master key 遺失（操作機掉了）：從任一台主機的 `service.env` 取回。passphrase 遺失：服務照跑，但不能 `rotate`。缺一個又取不回：產生新的 master key、照 15.3–15.5 重新加密（不中斷服務） |
| data key | `security.properties` 裡真正加密每筆密碼的那把，被 master key 包著。**不做例行輪替**：20.3 換的是外層的 master key。懷疑外洩時，拿到舊 master key＋舊 `security.properties` 的人已經解得出明文，所以要換的是**密碼本身**（keystore 跟著第 21 章換證、SCRAM 與 AD 查詢密碼用 `update`／20.4），再照 15.3–15.5 重新加密 |
| 誰輪替 | 沒有任何自動輪替；由平台工程師依變更單執行 20.3 |
| 密碼本身的輪替 | 另一條流程：改密碼 → `confluent secret file update`（或重新 `encrypt` 該欄位）→ 派送 → 重啟，與 master key 輪替無關。AD 查詢密碼見 20.4 |

> 陷阱：做過這一章之後，若回頭照第 10、12、13 章重新產生設定並派送，會把明文密碼寫回主機；改了設定要照 15.3–15.5 重新加密、派送、重啟。

# 16. 第十六站：維運選單（OP menu）

![opmenu]

下面這張圖跟著一次選單操作，從登入走到記錄。

![opmenuflow]

**這一章在做什麼**：裝一個給維運人員用的文字選單（OP menu），讓他們用自己的 AD 帳號做日常作業（看狀態、重啟、看日誌、建 topic、查權限），不用記指令。前提：第 11 章的 RBAC 與 AD 群組已經建好，第 9 章的 `svc-ops` 憑證已簽發，第 4 章 的 cpuser 金鑰可用。名詞：選單裡每個項目有編號（例如 21 重啟、23 看日誌、91 緊急模式）；「緊急模式」（91）是平常用不到的備用路徑（break-glass）：本人的 AD 身分處理不了時（例如 AD 不通），改用緊急憑證 `svc-ops` 做，必填原因、記為 EMERGENCY。它要向 MDS 換 token，所以 **MDS 也不通時 91 用不了**：選單會直接進「緊急主機模式」（不看群組，只開放磁碟、診斷、重啟、看日誌這些主機類項目），Kafka 類操作改用 28.6 的 `kafka-admin`（SCRAM，不經 MDS）。

平台交給維運之後，日常作業不該靠人記指令。小安帶了一個文字選單：維運人員經 CyberArk 登入操作機（進去是 root），執行選單、輸入自己的 AD 帳密，選單把所有項目都列出來，做了沒有權限的會被 Kafka／MDS 拒絕（依本人的 AD 群組），每一步留紀錄。重啟、看日誌這類要碰主機的動作，選單用 第 4 章 那把金鑰（`/secure/ssh/cpuser_ed25519`）以 cpuser ssh 過去做：金鑰就是檔案，**不再從 PVWA 取出貼進選單**；主機上不放任何代理程式，只靠 sudoers 限制 cpuser 能跑的指令（16.4：每個服務、每種寫法逐一列出）。

> **誠實的限制**：操作者在操作機上是 root，root 讀得到金鑰。所以選單「碰主機前先問 MDS：本人有沒有 Operator 以上的權限」是**流程控管，不是硬性隔離**（root 可以直接用金鑰 ssh，繞過選單）。追溯靠 CyberArk 的登入紀錄與 PSMP 錄影（誰在什麼時間進了 root），再加上選單紀錄和主機上 cpuser 的操作紀錄。**Kafka 類動作不受這個限制**：權限與稽核由 Kafka 端依本人 AD 身分強制，繞不過。

| 誰 | 做什麼 |
|---|---|
| 銀行 OS 團隊 | 各主機 cpuser 的 sudo 改成兩段式（16.4） |
| 小安 | 準備緊急憑證檔、裝選單、派送設定、綁緊急身分的權限、試跑 |

選單取緊急憑證的方式：緊急憑證放在操作機的 `~/secrets/svc-ops.pem`（0600，只有 root 讀得到），91 直接讀這個檔，沒有從別處取出貼上的動作。操作者本來就是 root，所以 91 的把關是「必填原因、記為 EMERGENCY 的稽核記錄」，不是讓人拿不到憑證。

## 16.1 緊急憑證放在哪裡

**這一節在做什麼**：說明選單 91（緊急模式）用的憑證放在哪裡。銀行沒有要準備的東西：緊急模式用操作機自己的 `svc-ops`（第 9 章簽的，已經是 SystemAdmin），16.2 由小安整理成一個 PEM 檔放在操作機：

| 檔案 | 內容 | 權限 |
|---|---|---|
| `~/secrets/svc-ops.pem` | 緊急模式憑證（私鑰＋憑證鏈，PEM） | 0600，root |

選單 91 啟動時檢查這個檔必須是自己的、權限 0600 或 0400，否則拒絕執行。

## 16.2 交付緊急憑證

**這一節在做什麼**：把緊急模式要用的身分準備好，並設定各群組的角色。`svc-ops` 的憑證（私鑰＋憑證鏈）整理成 `~/secrets/svc-ops.pem`。它在第 11 章已經綁成 SystemAdmin，不用另外綁。緊急操作在 Kafka 稽核日誌裡記成 `svc-ops`，要分辨是不是緊急操作，看選單的 EMERGENCY 紀錄（含操作者與原因）、CyberArk 登入紀錄與 PSMP 錄影。這就是選單 91（緊急模式）用的身分。

@role 小安 | ops02 | root

```bash
# 私鑰＋憑證鏈接成一個 PEM 檔（0600）
install -m 0600 /dev/null ~/secrets/svc-ops.pem
cat ~/pki/keys/svc-ops.key ~/pki/certs/svc-ops.crt > ~/secrets/svc-ops.pem

echo "svc-ops：$(grep -c 'BEGIN' ~/secrets/svc-ops.pem) 段 PEM（私鑰＋憑證鏈）"
```

```out
svc-ops：3 段 PEM（私鑰＋憑證鏈）
```

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current

# 1. svc-ops 登入 MDS；cluster id 問 MDS
confluent login \
  --url https://kb01.poc.lab:8090 \
  --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only \
  --client-cert-path ~/pki/certs/svc-ops.crt \
  --client-key-path ~/pki/keys/svc-ops.key > /dev/null 2>&1
cluster_id=$(curl -sk https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

# 2. 確認：svc-ops 已經是 SystemAdmin（第 11 章綁的）
confluent iam rbac role-binding list --principal User:svc-ops --kafka-cluster "$cluster_id" 2> /dev/null | tail -1
```

```out
  User:svc-ops | SystemAdmin | Cluster       |      |
```

維運群組要能跑健康檢查與重啟前的檢查（`kafka-topics --describe` 對每個 topic 都要 DescribeConfigs），只有 Operator 不夠；開發群組在自己的 prefix 上也要 DescribeConfigs 才看得到 topic 明細：

```bash
export JAVA_HOME=/opt/java/current
cluster_id=$(curl -sk https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

# 1. 維運群組：所有 topic 的 DeveloperManage（看得到設定）、所有 consumer group 的 DeveloperRead
confluent iam rbac role-binding create \
  --principal Group:kafka-operators \
  --role DeveloperManage \
  --resource 'Topic:*' \
  --kafka-cluster "$cluster_id" > /dev/null 2>&1

confluent iam rbac role-binding create \
  --principal Group:kafka-operators \
  --role DeveloperRead \
  --resource 'Group:*' \
  --kafka-cluster "$cluster_id" > /dev/null 2>&1

# 2. 開發群組：自己的 prefix（orders.）的 DeveloperManage
confluent iam rbac role-binding create \
  --principal Group:kafka-devs \
  --role DeveloperManage \
  --resource Topic:orders. \
  --prefix \
  --kafka-cluster "$cluster_id" > /dev/null 2>&1

# 3. 確認維運群組的 binding（表頭兩行不印）
confluent iam rbac role-binding list \
  --principal Group:kafka-operators \
  --kafka-cluster "$cluster_id" 2> /dev/null | tail -n +3
```

```out
  Group:kafka-operators | DeveloperManage | Topic         | *    | LITERAL
  Group:kafka-operators | DeveloperRead   | Group         | *    | LITERAL
  Group:kafka-operators | Operator        | Cluster       |      |
```

> 為什麼是 `DeveloperManage Topic:*`：`kafka-topics --describe` 對每個 topic 都要 DescribeConfigs（加 `--under-replicated-partitions` 也一樣，authorizer 日誌看得到），而 RBAC 內建角色裡有 DescribeConfigs 的都連帶能建、刪 topic（MDS 的角色定義：`DeveloperManage` = Create、Delete、Describe、DescribeConfigs；`DeveloperRead` = Describe、Read；`Operator` = Describe），CP 也不能自訂角色。所以維運群組**能建、刪 topic**，但**讀不到訊息內容**（`DeveloperManage` 沒有 Read）。2026-10-28 曾改成 `DeveloperRead`，結果 11 健康檢查、21／27 重啟前檢查都被 Kafka 拒絕，而且反而讀得到所有 topic 的訊息，2026-10-29 改回。銀行若不接受維運能建刪 topic，只能用 ACL 單獨補 DescribeConfigs（第 23 章 svc-backup 的做法）。

## 16.3 裝選單

@role 小安 | Windows 終端 | 本機

**這一節在做什麼**：把選單套件經第 3 章的離線流程送進操作機，裝到 `/opt/opmenu` 並寫好設定。選單是我方的**交付物**，和這本手冊一起給：`opmenu-<日期>.<雜湊>.tar.gz` 與它的 `SHA256SUMS` 兩個檔（檔名帶日期與內容的雜湊，內容不同就不會蓋掉舊的）。把它們複製進落地區的 `tools/opmenu/`、核對雜湊，再照 3.4 送進來（`D=opmenu`）。落地區只留最新一版，下面的 `tar -xzf opmenu-*.tar.gz` 才不會同時解到兩個（`<交付物的目錄>` 換成你放這兩個檔的地方）：

```bash
D="<交付物的目錄>"
dest=~/kafka-lab/landing/tools/opmenu

# 1. 落地區只留最新一版：先刪掉舊的，再複製進來
mkdir -p $dest
rm -f $dest/opmenu-*.tar.gz $dest/SHA256SUMS
cp "$D"/opmenu-*.tar.gz "$D"/SHA256SUMS $dest/

# 2. 核對雜湊
cd $dest
sha256sum -c SHA256SUMS
```

```out
opmenu-20261029.1a2b3c4d.tar.gz: OK
```

> 正式環境同樣是這兩個檔，經銀行的檔案交換平台進落地區（第 3 章）。雜湊對不上就不要裝，請我方重送。

再把這一包送進操作機（就是 3.4 的做法，`D=opmenu`；操作機上舊的會先被清掉，不然 `opmenu-*.tar.gz` 會解到舊版）：

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

```bash
D=opmenu   # 要送的目錄（落地區 tools/ 底下）
src="$HOME/kafka-lab/landing/tools/$D"
dest=/root/landing/tools/$D

if [ ! -d "$src" ]; then
  echo "落地區還沒有 tools/$D（有檔案要送時再做）"
else
  # 1. 操作機上同名的舊目錄先清掉（落地區是唯讀的，要先打開寫入權限）
  if podman exec lab-ops02-1 test -d "$dest"; then
    podman exec lab-ops02-1 chmod -R u+w "$dest"
    podman exec lab-ops02-1 rm -rf "$dest"
  fi

  # 2. 送過去，再收回寫入權限
  podman cp "$(cygpath -m "$src")" lab-ops02-1:/root/landing/tools/
  podman exec lab-ops02-1 chmod -R a-w "$dest"

  # 3. 在操作機上核對 sha256
  podman exec lab-ops02-1 ls "$dest"

  if podman exec -w "$dest" lab-ops02-1 sha256sum -c --quiet SHA256SUMS; then
    echo sha256-ok
  else
    echo "sha256 對不上：請我方重送，不要裝"
    false
  fi
fi
```

```out
SHA256SUMS
opmenu-20261028.2affc7e3.tar.gz
sha256-ok
```

@role 銀行 OS 團隊（lab 由小安代勞） | ops02 | root

選單從落地區解開到 `/opt/opmenu`（唯讀）；`/etc/opmenu/` 放設定、truststore、主機金鑰清單；`/var/log/opmenu/` 給紀錄與匯出檔。操作者都是 root，所以不需要另外的維運帳號與群組：

先在操作機上再核對一次雜湊：

```bash
cd ~/landing/tools/opmenu

if sha256sum -c --quiet SHA256SUMS; then
  echo sha256-ok
else
  echo "雜湊對不上：不要裝，請我方重送"
  false
fi
```

```out
sha256-ok
```

看到 `sha256-ok` 才裝（舊的 `/opt/opmenu` 會整個換掉）：

```bash
# 1. 換掉選單程式：先刪掉舊目錄，再解開新的（擁有者 root，大家可讀不可寫）
rm -rf /opt/opmenu
tar -xzf ~/landing/tools/opmenu/opmenu-*.tar.gz -C /opt
chown -R root:root /opt/opmenu
chmod -R a+rX /opt/opmenu

# 2. 設定目錄與 TLS 檔案（truststore 的密碼檔 0600）
install -d -m 0755 /etc/opmenu /etc/opmenu/ssl
install -m 0644 ~/pki/certs/truststore.p12 /etc/opmenu/ssl/truststore.p12
install -m 0600 ~/pki/store.pass /etc/opmenu/ssl/truststore.pass
install -m 0644 /etc/pki/ca-trust/source/anchors/bank-root.pem /etc/opmenu/ssl/ca.pem

# 3. 各主機的 ssh 主機金鑰：選單只信這份清單（只留金鑰行，# 開頭的註解行不要）
hosts="kc01.poc.lab kc02.poc.lab kc03.poc.lab"
hosts="$hosts kb01.poc.lab kb02.poc.lab kb03.poc.lab kb04.poc.lab"
hosts="$hosts rest01.poc.lab rest02.poc.lab c3-01.poc.lab"

host_keys=$(ssh-keyscan -t ed25519 $hosts 2> /dev/null | grep -v "^#" | sort)
echo "$host_keys" | install -m 0644 /dev/stdin /etc/opmenu/known_hosts

# 4. 紀錄與匯出檔的目錄
install -d -m 0750 -o root -g root /var/log/opmenu

# 5. 結果：項目數、主機金鑰數
echo "opmenu $(ls /opt/opmenu/items/*.sh | wc -l) items; known_hosts $(wc -l < /etc/opmenu/known_hosts) keys"
```

```out
opmenu 27 items; known_hosts 10 keys
```

設定檔只填無法推算的值（連線位址、可重啟的服務清單、主機登入的帳號與金鑰檔、91 的緊急憑證檔路徑）。`OPMENU_ALLOW_ENV_OVERRIDE=1` 只為了下面能非互動試跑，正式環境拿掉。

@role 銀行 OS 團隊（lab 由小安代勞） | ops02 | root

`OPMENU_SSH_KEY_FILE` 就是 第 4 章 的那把私鑰檔，選單的 ssh 直接用它（`-i`、只用這一把、不問 ssh-agent）；`OPMENU_BREAKGLASS_PEM` 是 91 讀的緊急憑證檔（必須是自己的檔、權限 0600 或 0400）：

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
OPMENU_BREAKGLASS_PEM=/root/secrets/svc-ops.pem
OPMENU_LOG=/var/log/opmenu/opmenu.log
OPMENU_SYSLOG=0
OPMENU_ALLOW_ENV_OVERRIDE=1
OPMENU_INTERNAL_GROUP_PATTERN='^(_|ConfluentTelemetryReporterSampler|console-consumer-|poc-cluster)'
EOF
chmod 0644 /etc/opmenu/opmenu.conf

# 選單讀得到設定：列出前 8 個項目（第 1 欄編號、第 5 欄標題）
/opt/opmenu/opmenu.sh --list | cut -f1,5 --output-delimiter=' ' | head -8
```

```out
10 查看 leader 與 partition 分布(balance report)
11 cluster 與身分鏈健康檢查
12 列出 topic 與 partition 狀態
13 查看 consumer group(lag 與成員數)
14 查看某個 topic 的設定
15 查看配額(quota)
16 查看磁碟與 data directory 用量
17 查看 certificate 與 license 到期日
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
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  # 1. 這台的服務
  case $h in
    kc* | kb*) unit=confluent-server ;;
    rest*)     unit=confluent-kafka-rest ;;
    c3*)       unit=confluent-control-center ;;
  esac

  # 2. 規則：重啟、查狀態、看日誌，各只開一種寫法
  rule="cpuser ALL=(root) NOPASSWD: /usr/bin/systemctl restart $unit"
  rule="$rule, /usr/bin/systemctl status $unit"
  rule="$rule, /usr/bin/journalctl -u $unit -n 200 --no-pager"

  # 3. 寫進那台的 /etc/sudoers.d/cpuser-ops（0440），再用 visudo 檢查語法
  echo "$rule" | ssh $h.poc.lab 'sudo install -m 0440 /dev/stdin /etc/sudoers.d/cpuser-ops'
  ssh $h.poc.lab 'sudo visudo -cf /etc/sudoers.d/cpuser-ops > /dev/null'

  printf "%s " $h
done
echo
```

```out
kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
```

收掉 kb04 的全權，逐一試各種寫法（`sudo -n -l <指令>` 只問「能不能執行」，不會真的執行）：

```bash
ssh kb04.poc.lab bash -s <<'EOF'
# 1. 收掉全權（先移到 /root，16.6 再放回去）
sudo mv /etc/sudoers.d/cpuser /root/cpuser.sudoers.full

# 2. 逐一問「能不能執行」；LIST 之前的每一行是一種寫法
while read -r command; do
  if sudo -n -l $command > /dev/null 2>&1; then
    result=可以
  else
    result=拒絕
  fi

  printf "%s %s\n" $result "$command"
done <<'LIST'
/usr/bin/systemctl restart confluent-server
/usr/bin/systemctl status confluent-server
/usr/bin/journalctl -u confluent-server -n 200 --no-pager
/usr/bin/journalctl -u confluent-server -n 5 --no-pager
/usr/bin/systemctl restart confluent-server sshd
/usr/bin/systemctl status confluent-server sshd
/usr/bin/systemctl restart sshd
/usr/bin/journalctl -D /etc
/usr/bin/ls /root
LIST
EOF
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

## 16.5 試跑：選單全部顯示，沒權限的做了被拒

@role 小安（代打 bob、carol、alice） | ops02 | root

**這一節在做什麼**：用三個不同權限的人試跑選單。選單**不依權限過濾**，每個人看到的項目一樣；要做什麼直接選，Kafka 類動作以本人身分執行，沒權限的由 Kafka／MDS 依 RBAC 拒絕並記成 DENIED。選單和 MDS 之間：登入時用本人 AD 帳密向 MDS 換 token（只有這一次用 basic auth，不用 confluent CLI），之後呼叫 MDS 都帶 token；token 用超過 55 分鐘，下一個動作開始前會自動用本次登入的帳密換新（紀錄記 `TOKEN_RENEWED`），換不到就請操作者重新登入。操作機本身從不連 AD：AD 帳密都由 broker（MDS 與 LDAP listener 9096）去驗（2026-10-29 實測：操作機把 AD 的路由黑洞掉，選單照常登入與操作）。只有兩種項目選單自己會先問 MDS：碰主機的（16、18、21、22、23、27，要 Operator 以上）和 91 緊急模式（以備用憑證執行，Kafka 檢查的是備用身分不是本人，所以本人要先是管理員）。好結果：bob、carol、alice 看到同一份選單；bob 建 topic 被 Kafka 拒絕、進 91 被擋，alice 都能做。互動模式就是人員經 PVWA 與 PSMP 登入操作機（root）後執行 `/opt/opmenu/opmenu.sh`，輸入自己的 AD 帳密。為了把結果印在這裡，用 `--run` 非互動跑；`--run menu` 印選單上的編號：

```bash
# 非互動跑選單要的環境變數（密碼從檔案讀）；每次執行只換 OPMENU_USER
export OPMENU_PASS=$(cat ~/secrets/ad-test-users.pass)
export OPMENU_YES=1
export OPMENU_REASON="第 16 站試跑"
export JAVA_HOME=/opt/java/current

# 三個人各印一行：選單上看得到的編號（output 是拿掉 SLF4J 雜訊與顏色碼之後的輸出）
for u in bob carol alice; do
  printf '%-6s ' $u

  output=$(OPMENU_USER=$u /opt/opmenu/opmenu.sh --run menu 2>&1 | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
  echo "$output" | grep '@@MENU@@' | cut -d' ' -f2-
done

unset OPMENU_PASS OPMENU_YES OPMENU_REASON
```

```out
bob    10 11 12 13 14 15 16 17 18 19 21 22 23 27 31 32 33 34 35 36 37 38 41 42 43 44 91
carol  10 11 12 13 14 15 16 17 18 19 21 22 23 27 31 32 33 34 35 36 37 38 41 42 43 44 91
alice  10 11 12 13 14 15 16 17 18 19 21 22 23 27 31 32 33 34 35 36 37 38 41 42 43 44 91
```

三個人看到的一樣。43（查詢稽核紀錄，篩選後可存檔交給稽核）做了會不會成功，看那個人有沒有 audit topic 的讀取權限：alice（SystemAdmin）有，bob、carol 沒有（第 18 章裝好稽核日誌後示範）；要給稽核單位用，就把他們的 AD 群組綁 `Topic:confluent-audit-log-events`（prefix）與 `Group:audit-`（prefix）的 DeveloperRead。

bob（Operator）：健康檢查、看 kb04 的日誌（kb04 只剩窄規則；23 只列含 error／warn 字樣的行，INFO 裡有 errors 字眼也會被列出）、重啟 kb04；建、刪 topic 可以（`DeveloperManage`，見 16.2），但讀不到訊息內容；改權限（42）會被 MDS 拒絕、91 會被管理員閘門擋下。alice（SystemAdmin）：建 topic、91 緊急模式、刪 topic。

@role 小安（代打 bob、carol、alice） | ops02 | root

主機類項目（23、21）直接用 `/secure/ssh` 的金鑰，不會問任何東西。緊急模式（91）讀 `~/secrets/svc-ops.pem`，不會問你要貼什麼；它要求輸入原因，並記為 EMERGENCY。為了把結果印在這裡，lab 用一支小腳本跑選單（`--run <AD 帳號> <項目…>`）：

```bash
cat > ~/conf/opmenu-try.sh <<'EOF'
#!/usr/bin/env bash
# lab：跑一次選單（opmenu-try.sh <AD 帳號> <項目…>）；91 的緊急憑證直接讀 ~/secrets/svc-ops.pem，不需要貼上
person=$1
shift
password=$(cat ~/secrets/ad-test-users.pass)

env OPMENU_USER=$person OPMENU_PASS="$password" OPMENU_YES=1 OPMENU_REASON=第16站試跑 JAVA_HOME=/opt/java/current \
  /opt/opmenu/opmenu.sh --run "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g; s/\r//g' | grep -v '^SLF4J'
EOF
chmod 0700 ~/conf/opmenu-try.sh

# 非互動跑選單要的環境變數（同上一塊）；output 是拿掉 SLF4J 雜訊與顏色碼之後的輸出
export OPMENU_PASS=$(cat ~/secrets/ad-test-users.pass)
export OPMENU_YES=1
export OPMENU_REASON="第 16 站試跑"
export JAVA_HOME=/opt/java/current

# 1. bob（Operator）：健康檢查看得到 broker 與自己的 token
output=$(OPMENU_USER=bob /opt/opmenu/opmenu.sh --run 11 2>&1 | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | grep -E '^-- (broker 在線:|你的 MDS token)'

# 2. bob 改權限：被 MDS 拒絕
output=$(OPMENU_USER=bob /opt/opmenu/opmenu.sh --run 42 add kafka-devs DeveloperRead Topic orders. 2>&1 \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | tail -1

# 3. bob 進 91：被管理員閘門擋下
output=$(OPMENU_USER=bob /opt/opmenu/opmenu.sh --run 91 kafka-topics --list 2>&1 \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | tail -1

# 4. alice（SystemAdmin）建 topic
output=$(OPMENU_USER=alice /opt/opmenu/opmenu.sh --run 31 orders.optest 1 2>&1 \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | tail -1

unset OPMENU_PASS OPMENU_YES OPMENU_REASON
```

```out
-- 你的 MDS token:已用 3s,剩約 3597s
-- broker 在線:4 / 4(設定的 broker 數)
Kafka 拒絕:你的群組沒有這項權限,請依變更單申請。
Authorization failed:這個項目以備用身分執行,需要本人有管理員權限(Cluster:kafka-cluster:Alter),你的群組沒有;請依變更單申請。
Created topic orders.optest.
```

@role 維運人員 bob、alice（91 讀操作機上的緊急憑證檔；lab 由 Windows 終端代打） | Windows 終端 | 本機

```bash
# 每個項目都是在操作機跑一次 opmenu-try.sh <AD 帳號> <項目…>（不給它 stdin，選單不會停下來等輸入）

# 1. bob 看 kb04 的日誌（只留最後兩行，每行前 100 字）
lines=$(podman exec -i lab-ops02-1 bash /root/conf/opmenu-try.sh bob 23 kb04.poc.lab:confluent-server 10 < /dev/null \
  | grep -E 'kb04' | tail -2)
echo "$lines" | cut -c1-100

# 2. bob 重啟 kb04（kb04 只剩窄規則）
podman exec -i lab-ops02-1 bash /root/conf/opmenu-try.sh bob 21 kb04.poc.lab:confluent-server < /dev/null | tail -1

# 3. 在操作機等 kb04 的 MDS 回 200：每 5 秒試一次，最多 24 次
podman exec -i lab-ops02-1 bash -s <<'EOF'
for i in $(seq 1 24); do
  code=$(curl -s -o /dev/null -w "%{http_code}" https://kb04.poc.lab:8090/v1/metadata/id)

  if [ "$code" = 200 ]; then
    break
  fi

  sleep 5
done

echo "kb04 MDS=$code after ~$((i*5))s"
EOF

# 4. alice 用 91 緊急模式列 topic，數有幾個
count=$(podman exec -i lab-ops02-1 bash /root/conf/opmenu-try.sh alice 91 kafka-topics --list < /dev/null \
  | grep -c '^[a-z_]')
echo "91 緊急模式列出的 topic：$count"

# 5. alice 刪掉剛才建的 topic（只看「將執行」那一行）
podman exec -i lab-ops02-1 bash /root/conf/opmenu-try.sh alice 33 orders.optest < /dev/null | grep 將執行
```

```out
Oct 25 09:57:24 kb04 kafka-server-start[2266]: [2026-10-25 09:57:24,799] INFO Updated lag of 0 group …
Oct 25 09:58:24 kb04 kafka-server-start[2266]: [2026-10-25 09:58:24,782] INFO Updated lag of 0 group …
已重啟 kb04.poc.lab 的 confluent-server
kb04 MDS=200 after ~20s
91 緊急模式列出的 topic：14
將執行:刪除 topic orders.optest,資料不可復原
```

@role 維運人員 alice（kafka-admins）；lab 由小安代打 | ops02 | root

換應用程式 SCRAM 密碼用 35：告訴它應用程式現在用哪一個帳號，它只換另一個（A／B，20.6 是背後的手動步驟）；新密碼寫在操作者的交接檔，交出去後 `shred`。這裡用 app-payments 示範（app-orders 留給第 19 章驗收與 20.6）：

```bash
password=$(cat ~/secrets/ad-test-users.pass)

# 1. alice 用 35 換 app-payments 的密碼：應用程式現在用 -a，所以換 -b
output=$(env OPMENU_USER=alice OPMENU_PASS="$password" OPMENU_YES=1 OPMENU_REASON="第 16 站試跑" \
  JAVA_HOME=/opt/java/current \
  /opt/opmenu/opmenu.sh --run 35 app-payments app-payments-a 2>&1 \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')

unset password

#    只留三行重點；交接檔名裡的時間換成 <時間>
echo "$output" | grep -E '將執行|新密碼已寫到|下一步' | sed -E 's/-[0-9]{8}-[0-9]{6}.pass/-<時間>.pass/g'

# 2. 這裡只是示範：交接檔直接 shred（正式環境是交給應用程式團隊之後才刪）
shred -u ~/opmenu-handover/app-payments-b-*.pass
echo "交接檔已 shred"
```

```out
將執行:更換 app-payments-b 的密碼（應用程式現在用 app-payments-a，不受影響）
新密碼已寫到 /root/opmenu-handover/app-payments-b-<時間>.pass（只有你讀得到）。請照應用程式團隊的交付方式交出去，完成後刪除：shred -u /root/opmenu-handover/app-payments-b-<時間>.pass
下一步：請應用程式改用 app-payments-b 與新密碼；下次輪替時換 app-payments-a
交接檔已 shred
```

@role 維運人員 bob、alice；lab 由小安代打 | ops02 | root

值班常看的三項：13 每個 consumer group 的合計 lag 和**在線成員數**（0 個成員 = 應用程式沒在跑，lag 會一直長）；15 每個帳號的配額；17 除了各端點的憑證，也列 license 的到期日。調配額用 38（第 3 層，受並行鎖與變更時窗管制）：先顯示目前的值，值填 `-` 是拿掉那一項。配額要叢集層級的 `DescribeConfigs`／`AlterConfigs`，所以維運的 bob 看不到、也改不了，管理的 alice 可以。license 存在 `_confluent-command`，讀得到的人（alice）即時讀；讀不到的人，17 改顯示操作機每天檢查（26.2）記進 syslog 的最後一筆。這裡先開一個 60 秒的 consumer，讓 13 看得到在線成員：

```bash
# 1. 背景開一個 60 秒的 consumer（app-orders-a，group orders-optest），等 20 秒讓它加入
JAVA_HOME=/opt/java/current KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml timeout 60 \
  kafka-console-consumer --bootstrap-server kb01.poc.lab:9095 --consumer.config ~/conf/app-orders.properties \
  --topic orders.events --group orders-optest > /dev/null 2>&1 &
sleep 20

# 非互動跑選單要的環境變數（同上；不給選單 stdin）；output 是拿掉 SLF4J 雜訊與顏色碼之後的輸出
export OPMENU_PASS=$(cat ~/secrets/ad-test-users.pass)
export OPMENU_YES=1
export OPMENU_REASON="第 16 站試跑"
export JAVA_HOME=/opt/java/current

# 2. bob：13 看得到這個 group 的成員
output=$(OPMENU_USER=bob /opt/opmenu/opmenu.sh --run 13 orders-optest 2>&1 < /dev/null \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | grep '^=='

# 15 看全部配額被拒
output=$(OPMENU_USER=bob /opt/opmenu/opmenu.sh --run 15 "" 2>&1 < /dev/null \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | tail -1

# 3. alice：15 看一個帳號
output=$(OPMENU_USER=alice /opt/opmenu/opmenu.sh --run 15 app-orders-b 2>&1 < /dev/null \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | tail -1

# 38 改配額
output=$(OPMENU_USER=alice /opt/opmenu/opmenu.sh --run 38 app-orders-b \
  producer_byte_rate=4194304,request_percentage=- 2>&1 < /dev/null \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | grep -E '^(目前|將執行|改後)'

# 再改回原來的值
output=$(OPMENU_USER=alice /opt/opmenu/opmenu.sh --run 38 app-orders-b \
  producer_byte_rate=5242880,request_percentage=50 2>&1 < /dev/null \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | grep '^改後'

# 4. alice：17 的 license 那一行
output=$(OPMENU_USER=alice /opt/opmenu/opmenu.sh --run 17 2>&1 < /dev/null \
  | grep -v '^SLF4J' | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | grep '^license'

unset OPMENU_PASS OPMENU_YES OPMENU_REASON
```

```out
== orders-optest                  合計 lag 0,在線成員 1 個
Kafka 拒絕:你的群組沒有這項權限,請依變更單申請。
app-orders-b                 producer_byte_rate=5242880 consumer_byte_rate=10485760 request_percentage=50
目前:app-orders-b                 producer_byte_rate=5242880 consumer_byte_rate=10485760 request_percentage=50
將執行:帳號 app-orders-b 的配額:設定 producer_byte_rate=4194304;拿掉 request_percentage
改後:app-orders-b                 producer_byte_rate=4194304 consumer_byte_rate=10485760
改後:app-orders-b                 producer_byte_rate=5242880 consumer_byte_rate=10485760 request_percentage=50
license：trial，到期 2026-11-29，剩 29 天  ⚠（不到 90 天，手把手 26.3）
```

> 13 查全部時不列平台內部的 group（`OPMENU_INTERNAL_GROUP_PATTERN`：C3 遙測、工具的臨時 group，以及 C3 自己的 group，lab 的 C3 名稱是 `poc-cluster`，寫在 16.3 的 `opmenu.conf`）；這些 group 沒有在線成員、lag 動輒十幾萬，混在裡面會被誤認成應用程式落後。

## 16.6 收尾檢查

@role 小安 | ops02 | root

**這一節在做什麼**：確認選單用完不留下私鑰或殘留程序，紀錄檔有記到人。好結果：ssh-agent 0、私鑰檔 0、金鑰檔是 `root:root 400`。選單結束後不留東西：沒有殘留的 ssh-agent（選單根本不開 agent）、`/dev/shm` 與 `/tmp` 沒有私鑰（91 的緊急憑證用完即刪）；金鑰檔仍是 root:root 0400。紀錄每行有 AD 帳號、作業系統帳號、項目、結果；作業系統帳號在操作機上都是 root，真正的「人」是 AD 帳號那一欄（再往上追，是 CyberArk 的登入紀錄與 PSMP 錄影）：

```bash
# 1. 沒有 ssh-agent；/dev/shm、/tmp 裡沒有私鑰（lab 自動實跑用的 runner.sh 不算）；金鑰檔還是 root 0400
agents=$(pgrep -x ssh-agent | wc -l)
keys=$(grep -rls 'PRIVATE KEY' /dev/shm /tmp 2> /dev/null | grep -v runner.sh | wc -l)
key_file=$(stat -c '%U:%G %a' /secure/ssh/cpuser_ed25519)
echo "ssh-agent: $agents; private keys in /dev/shm,/tmp: $keys; key file: $key_file"

# 2. 選單紀錄的最後 4 行
tail -4 /var/log/opmenu/opmenu.log | cut -c1-120
```

```out
ssh-agent: 0; private keys in /dev/shm,/tmp: 0; key file: root:root 400
2026-11-05 23:49:57 +0800 | LAB | alice | os=root | 15 查看配額(quota) | sid=1793893792-9179 | OK | app-orders-b [rc
2026-11-05 23:50:15 +0800 | LAB | alice | os=root | 38 調整配額(quota) | sid=1793893797-9377 | OK | app-orders-b pro
2026-11-05 23:50:23 +0800 | LAB | alice | os=root | 38 調整配額(quota) | sid=1793893815-9749 | OK | app-orders-b pro
2026-11-05 23:50:52 +0800 | LAB | alice | os=root | 17 查看 certificate 與 license 到期日 | sid=1793893823-10074 |
（最後 4 筆是 16.5 最後做的幾項：查看與調整配額、查看到期日）
```

@role 銀行 OS 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

16.4 為了證明「只剩窄規則時選單仍能重啟」，把 kb04 的全權 sudo 收掉了。正式環境的全權是變更時段由 OS 團隊依變更單開、做完收回；lab 後面的章節（第 17、18、20、21、29 章）都還要在 kb04 上安裝與派送，所以演練完把它放回去，當作「下一個變更時段開了全權」：

```bash
podman exec lab-kb04-1 mv /root/cpuser.sudoers.full /etc/sudoers.d/cpuser
podman exec lab-kb04-1 visudo -cf /etc/sudoers.d/cpuser > /dev/null
echo "kb04: full sudo back (change window)"
```

```out
kb04: full sudo back (change window)
```

# 17. 第十七站：監控（JMX exporter，行內 Prometheus、Alertmanager、Grafana）

![jmx]

**這一章在做什麼**：讓銀行的監控系統看得到 Confluent 各程序的狀況，並在出事時發告警。前提：第 10–13 章的服務已經起來（第 15 章是否已做不影響步驟）；這一章會**滾動重啟**所有 Java 程序（17.4），請在變更時段一台一台做。完成的樣子：10 台的 7071 用 HTTPS 拿得到指標、憑證鏈驗得過，不加密的 HTTP 連不上（17.4）；銀行的 Prometheus 上 10 個 target 都 up、告警規則載入、Grafana 有 32 個 dashboard（17.7）。名詞：JMX 是 Java 程序對外提供指標的介面，JMX exporter 把它轉成 Prometheus 讀得懂的 HTTPS 網頁。

監控與告警的做法已定案：**每個 Java 程序掛 Prometheus 的 JMX exporter（javaagent），由銀行的 Prometheus 抓、銀行的 Alertmanager 發告警、銀行的 Grafana 看圖**。Prometheus、Alertmanager、Grafana 是銀行提供的；我方交付的是設定：exporter 規則、scrape 設定、告警規則、Alertmanager 設定、Grafana 的 datasource 與 Confluent 官方的 32 個 dashboard。

> **這一章是銀行有提供 Prometheus、Alertmanager、Grafana 時的做法**；銀行沒有提供時，告警改走 C3 內建的 Prometheus 加我們的第二個 Alertmanager（第 32 章），抓同樣 10 台、用同一份 26 條規則；兩條路徑擇一，同一個告警不要兩邊都送 omnibus。

> **C3 內建的 Prometheus、Alertmanager 不動**：它們是 C3 自己的畫面（第 13 章）要用的，`otlp` 等設定照舊。但**告警與 dashboard 不走它們**，也不要在 C3 畫面建 alert trigger 或 action（Webhook、Email、PagerDuty）。原因：C3 會把那份 Alertmanager 設定重寫（C3 重啟後手改的內容被蓋掉）、webhook 內容不能自訂、而且只看得到 C3 自己收到的 telemetry（沒有主機標籤、controller 幾乎沒有指標）。這幾點 2026-10-26 在 lab 逐項實測過。

| 誰 | 做什麼 |
|---|---|
| 小安 | exporter 的 jar 與 Confluent 官方規則檔已在 2.4 節帶進來；組設定、派送、滾動重啟；產給銀行的 `to-bank/`（scrape 設定、告警規則、Alertmanager 設定、Grafana 設定與 dashboard、根憑證） |
| 銀行監控團隊 | 把 `to-bank/` 放進自己的 Prometheus、Alertmanager、Grafana；確認 10 個 target 都是 up、規則載入、dashboard 都在；把 webhook 指到行內的事件系統（IBM Netcool/OMNIbus，下稱 omnibus） |

四種程序各用哪份規則，抓得到什麼：

| 程序 | exporter 規則 | 抓得到什麼 |
|---|---|---|
| controller（kc01–03） | Confluent 官方 `kafka_controller.yml` | KRaft：controller 指標（`ActiveControllerCount`、`LastAppliedRecordLagMs`、`MetadataErrorCount` …）、JVM（raft 指標在三台 controller 的叢集裡沒有，見 B.2）|
| broker（kb01–04） | Confluent 官方 `kafka_broker.yml` | topic／partition／replica、request 延遲、ISR、網路與 request handler 執行緒、quota、JVM（序列數隨 topic 與 partition 數成長，3 個 partition 的 lab 約 1.2–1.4 萬條） |
| REST Proxy（rest01–02） | Confluent 官方 `confluent_rest.yml` | Jetty 與每個 REST endpoint 的請求率、錯誤率、延遲，JVM |
| Control Center（c3-01） | **我方的開頭幾條＋官方 `kafka_streams.yml` 的規則**（官方沒有給 C3 本身的 exporter 設定） | JVM、Kafka Streams（client、thread、task、處理節點）、RocksDB state store（`AlertHistoryStore`、`commander`），約 2,100 條，名稱和官方 Streams／RocksDB dashboard 對得上。不收 C3 自己的 consumer／producer 與每個 REST endpoint（上萬條），也不收 Jetty（C3 2.6.1 上全是 0、沒有錯誤率） |

## 17.1 設定檔的標頭：HTTPS

@role 小安 | ops02 | root

7071 只做 **HTTPS**，不要求帳密、也不要求 client 憑證（2026-10-31 定案）：指標只能讀、不能改任何東西，內容沒有訊息也沒有密碼，所以不另外發一組要交給銀行、要同步輪替的抓取密碼。誰連得到 7071 就讀得到，所以**存取控制靠網路**：7071 只放行行內 Prometheus 的來源位址（請銀行確認的事項 11.4；7.3 節的 firewalld 目前對所有來源開放）。keystore 密碼不寫進 YAML：exporter（1.4 起）讀得到 `${環境變數}`，YAML 裡寫 `${JMX_KEYSTORE_PASSWORD}`，值放在每台的 `/etc/confluent/jmx-exporter.env`（root 0600），由 systemd drop-in 的 `EnvironmentFile` 帶進服務（`ps` 看不到；只有 root 與服務本身讀得到）。YAML 是 root:confluent 0640。

keystore 依角色不同：controller 用 `kafka-internal.p12`，broker 用 `cp-server.p12`，REST Proxy 用 `svc-rest.p12`，C3 用 `svc-c3.p12`。這一步只產生四份**標頭**（HTTPS），規則在 17.2 接上去：

```bash
install -d -m 0700 ~/monitoring

# 舊版（basic auth）留下的密碼檔，有的話刪掉
rm -f ~/secrets/jmx-scrape.pass ~/secrets/jmx-scrape.salt

# 1. 四份標頭（0600）：controller 用 kafka-internal.p12、broker 用 cp-server.p12、REST 用 svc-rest.p12、C3 用 svc-c3.p12
#    EOF 沒加引號：$ks 會換成值；\${JMX_KEYSTORE_PASSWORD} 原樣留著，給 exporter 從環境變數讀
for ks in cp-server kafka-internal svc-c3 svc-rest; do
  install -m 0600 /dev/null ~/monitoring/jmx-header-$ks.yml
  cat > ~/monitoring/jmx-header-$ks.yml <<EOF
# Prometheus JMX exporter: HTTPS with this host's certificate, no authentication (only the bank's Prometheus may reach 7071: firewall).
# No plaintext password in this file: the keystore password comes from JMX_KEYSTORE_PASSWORD (systemd EnvironmentFile /etc/confluent/jmx-exporter.env, root 0600)
httpServer:
  ssl:
    keyStore:
      filename: /etc/confluent/ssl/$ks.p12
      password: \${JMX_KEYSTORE_PASSWORD}
      type: PKCS12
    certificate:
      alias: $ks
EOF
done

# 2. keystore 密碼的環境檔（0600）
install -m 0600 /dev/null ~/monitoring/jmx-exporter.env
echo "JMX_KEYSTORE_PASSWORD=$(cat ~/pki/store.pass)" > ~/monitoring/jmx-exporter.env

# 3. 確認：四份標頭、環境檔 0600、YAML 裡的密碼是變數、沒有 authentication: 設定（要是 0；註解裡的字不算）
headers=$(ls ~/monitoring | grep '^jmx-header' | tr '\n' ' ')
env_mode=$(stat -c %a ~/monitoring/jmx-exporter.env)
password_line=$(grep -h 'password:' ~/monitoring/jmx-header-*.yml | sort -u | sed 's/^ *//')
auth=$(awk '/^ *authentication:/ {c++} END {print c + 0}' ~/monitoring/jmx-header-*.yml)
echo "headers: $headers；jmx-exporter.env $env_mode；YAML 裡的 keystore 密碼：$password_line；authentication：$auth"
```

```out
headers: jmx-header-cp-server.yml jmx-header-kafka-internal.yml jmx-header-svc-c3.yml jmx-header-svc-rest.yml ；jmx-exporter.env 600；YAML 裡的 keystore 密碼：password: ${JMX_KEYSTORE_PASSWORD}；authentication：0
```

> 從零安裝的環境沒有 `~/secrets/jmx-scrape.pass`、`jmx-scrape.salt` 是正常的；上面的 `rm -f` 只是清掉 10-30 以前（7071 還用 basic auth 時）裝過的環境留下的檔，不存在也不會出錯。

## 17.2 接上 Confluent 官方的規則

@role 小安 | ops02 | root

Dashboard 是照 Confluent 官方 exporter 規則產生的指標名稱寫的，所以規則**直接用官方的檔，不自己改**（2.4 節帶進來，固定在 jmx-monitoring-stacks 的一個 commit，在 `~/landing/monitoring/` 下）。每台的設定 = 17.1 的標頭 + 官方規則。

兩個細節：官方檔第一行是 YAML 文件分隔線 `---`，接在標頭後面會變成第二份文件，所以拿掉；官方檔自己帶 `startDelaySeconds: 120`（controller、broker 重啟後前兩分鐘 7071 回 200 但沒有指標）。

C3 本身沒有官方規則，但它是一個 Kafka Streams 應用程式：只收 `kafka.streams:*`，規則用官方的 `kafka_streams.yml`（2.4 節帶進來的），前面放我們自己的幾條（`rules-c3.yml`）。原因：C3 的 `stream-metrics`、`stream-thread-metrics` MBean 多帶一個 `process-id`，官方規則會把那個 UUID 拼進指標名稱（每次重啟名稱就變，告警寫不了），所以 `client-state`、`alive-stream-threads`、`failed-stream-threads`、`thread-state` 由我們先命名（官方規則還會把執行緒數放進標籤，數字一變就多一條序列）；`stream-topic-metrics` 有四個 key，官方規則會把 `processor-node-id` 塞進 `task_id`。exporter 用第一條比對到的規則，所以順序要對。整段貼到 EOF；最後每個角色一行，`httpServer=1`、`lowercaseOutputName=1` 代表標頭和規則都接上了：

```bash
cd ~/monitoring

# 舊版（basic auth 時代）留下的檔，有的話刪掉
rm -f alert-rules.yml ca.pem prometheus-scrape.yml rules-kafka.yml rules-rest.yml rules-jvm.yml scrape.pass

# 1. 官方規則的位置與版本
official=~/landing/monitoring/jmx-monitoring-stacks/shared-assets/jmx-exporter
echo "官方規則版本：$(cut -c1-12 ~/landing/monitoring/jmx-monitoring-stacks/COMMIT)"

# 2. controller、broker、REST Proxy：標頭＋官方規則（官方檔第一行的 --- 拿掉；檔案 0600）
#    寫法：角色:用哪份標頭:官方規則檔名
for entry in controller:kafka-internal:kafka_controller broker:cp-server:kafka_broker rest:svc-rest:confluent_rest; do
  role=$(echo $entry | cut -d: -f1)
  keystore=$(echo $entry | cut -d: -f2)
  rules=$(echo $entry | cut -d: -f3)

  install -m 0600 /dev/null ~/monitoring/jmx-$role.yml
  cat ~/monitoring/jmx-header-$keystore.yml > ~/monitoring/jmx-$role.yml
  sed '1{/^---$/d}' $official/$rules.yml >> ~/monitoring/jmx-$role.yml
done

# 3. C3：我們自己的開頭幾條
cat > ~/monitoring/rules-c3.yml <<'EOF'
# Control Center: a Kafka Streams application (Confluent has no exporter rules for C3 itself).
# Kafka Streams and RocksDB: Confluent's official kafka_streams.yml rules are appended below this head (same metric names as the
# official kafka-stream.json / kafka-streams-rocksdb.json dashboards); only kafka.streams:* is collected, not C3's own consumers/producers
# (their lag would show screen delay, but costs many series) and not C3's Jetty beans (all 0 on C3 2.6.1, no error rate).
# About 2,000 series in the lab (C3 2.6.1: 13 stream threads, 12 tasks, state stores AlertHistoryStore and commander).
# Our rules come first (the exporter uses the first rule that matches):
#   client-state, recording-level, alive-stream-threads, failed-stream-threads, thread-state: C3's stream-metrics and stream-thread-metrics beans also carry process-id;
#     the official rules would put that UUID into the
#     metric name (a new name after every restart), so they are named here: client-state 0 CREATED, 1 REBALANCING, 2 RUNNING,
#     3 PENDING_SHUTDOWN, 4 NOT_RUNNING, 5 PENDING_ERROR, 6 ERROR; thread-state 4 RUNNING, 6 DEAD
#     (and turn alive-/failed-stream-threads into a label, a new series whenever the number changes)
#   stream-topic-metrics has four keys; the official rules would put processor-node-id into task_id
lowercaseOutputName: true
lowercaseOutputLabelNames: true
startDelaySeconds: 0
includeObjectNames:
  - "kafka.streams:*"
excludeObjectNames:
  - "kafka.streams:type=kafka-metrics-count"
rules:
  - pattern: 'kafka.streams<type=stream-metrics.*client-id=([^,>]+).*><>(client-state|recording-level|alive-stream-threads|failed-stream-threads): (.+)'
    name: kafka_streams_stream_metrics_$2
    type: GAUGE
    labels: { client_id: "$1" }
  - pattern: 'kafka.streams<type=stream-thread-metrics.*thread-id=([^,>]+).*><>(thread-state): (.+)'
    name: kafka_streams_stream_thread_metrics_$2
    type: GAUGE
    labels: { thread_id: "$1" }
  - pattern: 'kafka.streams<type=stream-topic-metrics, thread-id=(.+), task-id=(.+), processor-node-id=(.+), topic=(.+)><>(.+):'
    name: kafka_streams_stream_topic_metrics_$5
    type: GAUGE
    labels: { thread_id: "$1", task_id: "$2", processor_node_id: "$3", topic: "$4" }
EOF

# 4. C3 的設定：標頭＋我們的開頭＋官方 kafka_streams.yml 的規則（只取 rules: 底下那些；檔案 0600）
install -m 0600 /dev/null ~/monitoring/jmx-c3.yml
cat ~/monitoring/jmx-header-svc-c3.yml ~/monitoring/rules-c3.yml > ~/monitoring/jmx-c3.yml
sed -n '/^rules:/,$p' $official/kafka_streams.yml | tail -n +2 >> ~/monitoring/jmx-c3.yml

# 5. 每個角色一行：行數；httpServer 與 lowercaseOutputName 都是 1 = 標頭和規則都接上了
for f in controller broker rest c3; do
  file=~/monitoring/jmx-$f.yml
  printf '%-11s %4d 行  httpServer=%s lowercaseOutputName=%s\n' \
    $f \
    $(wc -l < $file) \
    $(grep -c '^httpServer:' $file) \
    $(grep -c '^lowercaseOutputName: true' $file)
done
```

```out
官方規則版本：f376263fc6d7
controller   153 行  httpServer=1 lowercaseOutputName=1
broker       431 行  httpServer=1 lowercaseOutputName=1
rest          49 行  httpServer=1 lowercaseOutputName=1
c3           126 行  httpServer=1 lowercaseOutputName=1
```

官方規則版本記在 `COMMIT`，換版本（重新下載官方檔）要重做這一步並重新驗證 dashboard。

> **官方規則的一個副作用**：序列數會隨 topic 與 partition 數成長（`kafka.log`、`kafka.cluster` 的每個 partition 一條）。lab 3 個 partition 的 broker 就有約 1.2–1.4 萬條；正式環境 partition 多時要請銀行監控團隊評估 Prometheus 的容量與保留天數。

## 17.3 派送 jar 與設定、掛上 javaagent

@role 小安 | ops02 | root

每台放四樣東西：jar 到 `/opt/jmx-exporter/`（舊版的 jar 先刪）、設定檔到各元件的目錄、keystore 密碼的環境檔 `/etc/confluent/jmx-exporter.env`（root 0600）、第四個 drop-in 用 `EnvironmentFile` 讀那個檔，並把 `-javaagent` 放進環境變數。環境變數依角色不同：controller 與 broker 是 `KAFKA_OPTS`，REST Proxy 是 `KAFKAREST_OPTS`，C3 是 `CONTROL_CENTER_OPTS`（C3 的啟動腳本本來就會讀它，另外加的 `-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=*` 由腳本自己補，不用管）。7071 在 7.3 節的防火牆已經開了（C3 的 7071 也在）。

分兩塊對 10 台做完。第一塊把 jar、設定檔、環境檔送到每台，印出送完的主機：

```bash
jar=$(ls ~/landing/tools/jmx_prometheus_javaagent-*.jar | xargs -n1 basename)

for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  # 1. 這台的角色（決定用哪一份設定檔）
  case $h in
    kc*)
      role=controller
      ;;
    kb*)
      role=broker
      ;;
    rest*)
      role=rest
      ;;
    c3*)
      role=c3
      ;;
  esac

  # 2. 這台的設定檔與環境檔先複製到 /tmp（環境檔 0600），和 jar 一起送過去，再刪掉 /tmp 的副本
  cp ~/monitoring/jmx-$role.yml /tmp/jmx-$h.yml
  install -m 0600 ~/monitoring/jmx-exporter.env /tmp/jmx-$h.env
  scp -q ~/landing/tools/$jar /tmp/jmx-$h.yml /tmp/jmx-$h.env $h.poc.lab:/tmp/
  rm -f /tmp/jmx-$h.yml /tmp/jmx-$h.env

  printf '%s ' $h
done
echo
```

```out
kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
```

第二塊到每台裝好、掛上 javaagent；每行要看到 `javaagent:` 的 jar 路徑，行數要和 17.2 產生的設定檔相同：

```bash
jar=$(ls ~/landing/tools/jmx_prometheus_javaagent-*.jar | xargs -n1 basename)

for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  # 1. 這台的設定檔放哪、服務名稱、放 javaagent 的環境變數
  case $h in
    kc*|kb*)
      cfg=/etc/confluent/kafka/jmx-exporter.yml
      unit=confluent-server
      var=KAFKA_OPTS
      ;;
    rest*)
      cfg=/etc/confluent/kafka-rest/jmx-exporter.yml
      unit=confluent-kafka-rest
      var=KAFKAREST_OPTS
      ;;
    c3*)
      cfg=/etc/confluent/control-center/jmx-exporter.yml
      unit=confluent-control-center
      var=CONTROL_CENTER_OPTS
      ;;
  esac

  # 2. 在那台執行 EOF 之前的那一段（$1 jar 檔名、$2 主機、$3 設定檔路徑、$4 服務、$5 環境變數名；bash -e：任何一行失敗就停）
  ssh $h.poc.lab bash -e -s -- $jar $h $cfg $unit $var <<'EOF'
jar=$1
host=$2
cfg=$3
unit=$4
var=$5

# jar（舊版先刪）、設定檔（root:confluent 0640）、keystore 密碼的環境檔（root 0600）
sudo install -d -m 0755 /opt/jmx-exporter
sudo rm -f /opt/jmx-exporter/jmx_prometheus_javaagent-*.jar
sudo install -m 0644 /tmp/$jar /opt/jmx-exporter/$jar
sudo install -o root -g confluent -m 0640 /tmp/jmx-$host.yml $cfg
sudo install -o root -g root -m 0600 /tmp/jmx-$host.env /etc/confluent/jmx-exporter.env
rm -f /tmp/$jar /tmp/jmx-$host.yml /tmp/jmx-$host.env

# drop-in：讀環境檔，在 $var 裡掛 javaagent（聽 7071；UNIT 沒加引號，裡面的變數會換成值）
sudo tee /etc/systemd/system/$unit.service.d/40-jmx.conf > /dev/null <<UNIT
[Service]
EnvironmentFile=/etc/confluent/jmx-exporter.env
Environment="$var=-javaagent:/opt/jmx-exporter/$jar=7071:$cfg"
UNIT
sudo systemctl daemon-reload

# 確認：javaagent 的 jar 路徑、設定檔行數、環境檔權限
agent=$(systemctl show $unit -p Environment --value | grep -o 'javaagent:[^ =]*' | head -1)
lines=$(sudo wc -l $cfg | cut -d' ' -f1)
echo "$(hostname): $agent $lines lines env=$(sudo stat -c %a /etc/confluent/jmx-exporter.env)"
EOF
done
```

```out
kc01: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 153 lines env=600
kc02: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 153 lines env=600
kc03: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 153 lines env=600
kb01: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 431 lines env=600
kb02: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 431 lines env=600
kb03: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 431 lines env=600
kb04: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 431 lines env=600
rest01: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 49 lines env=600
rest02: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 49 lines env=600
c3-01: javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.7.0.jar 126 lines env=600
```

> 陷阱：落地區的檔案是唯讀的（第 3 章 `chmod a-w`），這裡先 `cp` 到 `/tmp` 再 `scp`，是因為直接 `scp` 落地區的檔會連唯讀一起帶過去。流程正常跑完會 `rm -f`；若中途失敗留下唯讀檔，下一次 `scp` 會 `Permission denied`，先到那台 `rm -f /tmp/jmx*` 再重跑。
>
> 陷阱：`sudo wc -l < 檔案` 的 `<` 是用 cpuser 的身分開檔，會 `Permission denied`；要寫成 `sudo wc -l 檔案`。

## 17.4 滾動重啟、驗證端點

@role 小安 | ops02 | root

controller、broker 照順序一台一台來（REST Proxy 與 C3 在後面）：

```bash
# 1. controller：一台一台重啟，等到 active（在那台每 2 秒看一次，最多 30 次）
for h in kc01 kc02 kc03; do
  ssh $h.poc.lab bash -s <<'EOF'
sudo systemctl restart confluent-server

for i in $(seq 1 30); do
  if systemctl is-active -q confluent-server; then
    break
  fi

  sleep 2
done

echo "$(hostname) $(systemctl is-active confluent-server)"
EOF
done

# 2. broker：一台一台重啟，等 MDS（8090）回 200（每 5 秒看一次，最多 60 次）
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  for i in $(seq 1 60); do
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done
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
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
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
# 1. 重啟 C3
ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'

# 2. 等畫面回 200（還連不上時是 000）：每 10 秒試一次，最多 60 次
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 10
done

echo "c3 ui=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/) after ~$((i*10))s"

# 3. alice 真的從 C3 登入（首頁不經過 MDS，只看 200 抓不到；C3 起來後健康檢查還要一點時間，最多等 60 秒）
alice_pass=$(cat ~/secrets/ad-test-users.pass)
login_url=https://c3-01.poc.lab:9021/api/metadata/security/1.0/authenticate

for i in $(seq 1 12); do
  if [ "$(curl -s -u "alice:$alice_pass" -o /dev/null -m 30 -w '%{http_code}' $login_url)" = 200 ]; then
    break
  fi

  sleep 5
done

echo "alice 從 C3 登入：$(curl -s -u "alice:$alice_pass" -o /dev/null -m 30 -w '%{http_code}' $login_url)"
unset alice_pass
```

```out
c3 ui=200 after ~60s
alice 從 C3 登入：200
```

HTTPS 要拿得到指標，憑證鏈用銀行根憑證驗（不用 -k）；不加密的 `http://` 要連不上（`000`）。controller 與 broker 重啟後前兩分鐘指標是空的（官方規則的 `startDelaySeconds: 120`），所以每台等到有指標再算：

```bash
ca=/etc/pki/ca-trust/source/anchors/bank-root.pem

for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  url=https://$h.poc.lab:7071/metrics

  # 1. 等到有指標（kafka_、jvm_ 開頭的行超過 20 行才算；連不上就是 0）：每 10 秒試一次，最多 30 次
  for i in $(seq 1 30); do
    count=$(curl -s --max-time 30 --cacert $ca $url | awk '/^(kafka_|jvm_)/ {c++} END {print c + 0}')

    if [ "$count" -gt 20 ]; then
      break
    fi

    sleep 10
  done

  # 2. https 用銀行根憑證驗（不用 -k）要是 200；不加密的 http 要連不上（000）
  printf '%-7s https=%s http=%s metrics=%s\n' \
    $h \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert $ca $url)" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://$h.poc.lab:7071/metrics)" \
    $count
done
```

```out
kc01    https=200 http=000 metrics=1067
kb01    https=200 http=000 metrics=11787
rest01  https=200 http=000 metrics=1498
c3-01   https=200 http=000 metrics=2115
（10 行，https 都是 200、http 都是 000；controller 約 1,000、REST 約 1,500、C3 約 2,000 個 kafka_／jvm_ 指標，broker 依 partition 數而定）
```

> 不信任銀行根憑證的 client 連 7071 會在 TLS 那一關失敗（`curl: (60) SSL certificate problem: unable to get local issuer certificate`）；銀行 Prometheus 的 scrape 設定裡要帶 17.5 的 `ca.pem`。

## 17.5 給銀行監控團隊的檔

@role 小安 | ops02 | root

全部放在 `~/monitoring/to-bank/`，分成三個資料夾，各給對應的銀行團隊：

| 資料夾 | 內容 | 放到哪 |
|---|---|---|
| `prometheus/` | `scrape-confluent.yml`、`confluent-alerts.yml`、`ca.pem` | Prometheus 的 `/etc/prometheus/confluent/` |
| `alertmanager/` | `alertmanager.yml` | 併入行內 Alertmanager 的設定 |
| `grafana/` | `datasource-prometheus.yml`、`dashboards/`（32 個 JSON 加 `dashboard.yml`） | Grafana 的 `provisioning/datasources/`、`provisioning/dashboards/` |

**scrape 設定**：四個 job，名稱和標籤是官方 dashboard 寫死的（`job="kafka-broker"`、`env`、`hostname`），不要改。`env` 的值是這個環境的名字（lab 用 `lab`，客戶用 `prod`／`uat`）。7071 只做 HTTPS，所以每個 job 只有 `scheme: https` 和驗銀行根憑證的 `tls_config`，沒有帳密。這個檔用 Prometheus 的 `scrape_config_files` 引用，不用併進 `prometheus.yml`：

```bash
# 每次重新產生：先清掉整個 to-bank/，再建三個資料夾
rm -rf ~/monitoring/to-bank
install -d ~/monitoring/to-bank/prometheus ~/monitoring/to-bank/alertmanager ~/monitoring/to-bank/grafana/dashboards

cat > ~/monitoring/to-bank/prometheus/scrape-confluent.yml <<'EOF'
# Confluent Platform scrape jobs for the bank's Prometheus (referenced from prometheus.yml with scrape_config_files)
# Job names and the env / hostname labels are what Confluent's official Grafana dashboards query (job="kafka-broker", env=...).
# Files next to this one (/etc/prometheus/confluent/): ca.pem (bank root CA). 7071 is HTTPS only, no credentials: only this Prometheus may reach it (firewall).
scrape_configs:
  - job_name: kafka-controller
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    static_configs: [ { targets: [ "kc01.poc.lab:7071", "kc02.poc.lab:7071", "kc03.poc.lab:7071" ], labels: { env: lab } } ]
    relabel_configs: [ { source_labels: [__address__], target_label: hostname, regex: '([^:]+)(:[0-9]+)?', replacement: '$1' } ]
  - job_name: kafka-broker
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    static_configs: [ { targets: [ "kb01.poc.lab:7071", "kb02.poc.lab:7071", "kb03.poc.lab:7071", "kb04.poc.lab:7071" ], labels: { env: lab } } ]
    relabel_configs: [ { source_labels: [__address__], target_label: hostname, regex: '([^:]+)(:[0-9]+)?', replacement: '$1' } ]
  - job_name: rest-proxy
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    static_configs: [ { targets: [ "rest01.poc.lab:7071", "rest02.poc.lab:7071" ], labels: { env: lab } } ]
    relabel_configs: [ { source_labels: [__address__], target_label: hostname, regex: '([^:]+)(:[0-9]+)?', replacement: '$1' } ]
  - job_name: control-center
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config: { ca_file: /etc/prometheus/confluent/ca.pem }
    static_configs: [ { targets: [ "c3-01.poc.lab:7071" ], labels: { env: lab } } ]
    relabel_configs: [ { source_labels: [__address__], target_label: hostname, regex: '([^:]+)(:[0-9]+)?', replacement: '$1' } ]
EOF

echo "scrape-confluent.yml: $(grep -c job_name ~/monitoring/to-bank/prometheus/scrape-confluent.yml) 個 job"
```

```out
scrape-confluent.yml: 4 個 job
```

**告警規則**：26 條，每條都有 `severity`（critical／warning）、`impact`（APPLICATION／SERVICE／INFRASTRUCTURE，對應 omnibus 規格裡的 ProblemImpact 欄位）、`summary` 與 `description`。規則的出處寫在每一條上方的註解，三類：`official`（Confluent jmx-monitoring-stacks 的 `prometheus-alerts/`，保留，必要時修正表達式）、`confluent`（Confluent 的監控指引：Monitor Kafka、KRaft metrics）、`ours`（我方新增，一定有 lab 上真的存在的指標撐著）。和官方檔的差別：

- 官方 `broker-alerts.yml` 有兩條「Broker IO Activity」用的是一個永遠小於 1 的 control-plane 指標，等於測試規則，不收；改用 request handler 的一分鐘平均閒置率。
- 官方的 `UncleanLeaderElectionsPerSec` 在 exporter 裡是累計次數，`> 0` 一旦發生過就永遠成立，改成看 10 分鐘內的增量。
- 官方的 `high_load` 要 node exporter，我們沒有；改用 Confluent Server 自己的主機 CPU 指標（`KafkaHostCpuHigh`，`host` 群組）。磁碟剩餘空間 JMX 沒有，請用銀行既有的主機監控（第 24 章給範例）。
- 另外加：KRaft 的 fenced broker（Confluent KRaft 指標文件的 `FencedBrokerCount`）、log dir 離線（原本在第 24 章，Strimzi 也有同樣的規則）、JVM 執行緒死結。第 32 章（銀行沒有 Prometheus）用同一份規則，所以這裡的規則兩條路徑共用。
- controller 的規則（`ActiveControllerCount`、offline partitions）限定 `job="kafka-controller"`；`for` 從 10 秒放寬到 1 分鐘，不然 controller 重啟會叫人。
- KRaft 另加：metadata 落後、metadata 錯誤、leader 頻繁更換（「沒有 leader」由 `KafkaActiveControllerCountNotOne` 涵蓋）。REST Proxy 加兩條，C3 加五條（Streams 停了、thread 掛了、thread 不再 poll、RocksDB 背景錯誤、丟棄紀錄），都只用 lab 驗過存在的指標。
- 照 `max by (instance)` 聚合的規則都多帶 `hostname`（`by (instance, hostname)`），不然 summary 裡的 `{{ $labels.hostname }}` 會是空的。

整段貼到 EOF：

```bash
cat > ~/monitoring/to-bank/prometheus/confluent-alerts.yml <<'EOF'
# Alert rules for the bank's Prometheus. Metric names are the ones Confluent's official JMX exporter rules produce
# (jmx-monitoring-stacks, see the guide, chapter 2.4); job names match scrape-confluent.yml.
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
        expr: avg by (instance, hostname) (kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent_oneminuterate{job="kafka-broker"}) < 0.3
        for: 10m
        labels: { severity: warning, impact: SERVICE }
        annotations:
          summary: "{{ $labels.hostname }}: request handler threads busy"
          description: "Request handler threads on {{ $labels.instance }} have been less than 30% idle for 10 minutes ({{ $value | humanizePercentage }} idle). The broker is close to saturation: look at request rate, disk latency, num.io.threads."
      # source: confluent (network processor idle ratio)
      - alert: KafkaNetworkProcessorBusy
        expr: avg by (instance, hostname) (kafka_network_socketserver_networkprocessoravgidlepercent{job="kafka-broker"}) < 0.3
        for: 10m
        labels: { severity: warning, impact: SERVICE }
        annotations:
          summary: "{{ $labels.hostname }}: network threads busy"
          description: "Network processor threads on {{ $labels.instance }} have been less than 30% idle for 10 minutes. Check connection counts and num.network.threads."
      # source: confluent (request latency); ours: Produce p99, 500 ms, only while the broker really serves Produce requests:
      # the p99 is a Yammer histogram that changes only when new requests arrive, so after traffic stops it keeps the last slow value forever
      - alert: KafkaProduceLatencyHigh
        expr: max by (instance, hostname) (kafka_network_requestmetrics_totaltimems{job="kafka-broker",request="Produce",quantile="0.99"}) > 500 and on (instance) sum by (instance) (rate(kafka_network_requestmetrics_requestspersec{job="kafka-broker",request="Produce"}[10m])) > 1
        for: 10m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: Produce p99 {{ $value }} ms"
          description: "99th percentile Produce request time on {{ $labels.instance }} has been above 500 ms for 10 minutes. Look at disk latency and replication delay (acks=all waits for followers)."
      # source: ours (Strimzi has the same check as OfflineLogDirectoryCount): one series per log dir on Confluent Server 8.2.4 / 8.3.2.
      # With a single log.dirs the broker shuts itself down when the directory fails, so ConfluentTargetDown fires too; this rule names the directory.
      - alert: KafkaLogDirOffline
        expr: max by (hostname, logdirectory) (kafka_log_logmanager_logdirectoryoffline{job="kafka-broker"}) > 0
        for: 1m
        labels: { severity: critical, impact: SERVICE }
        annotations:
          summary: "{{ $labels.hostname }}: log directory {{ $labels.logdirectory }} offline"
          description: "Broker {{ $labels.hostname }} reports its log directory {{ $labels.logdirectory }} offline (disk error or full file system). Its partitions moved to other leaders; check dmesg, df -h and the broker log, then repair or replace the disk (guide 24.4)."

  - name: kraft
    rules:
      # source: ours (earlier lab work): controller applies the metadata log late
      - alert: KRaftControllerMetadataLag
        expr: max by (instance, hostname) (kafka_controller_kafkacontroller_lastappliedrecordlagms{job="kafka-controller"}) > 30000
        for: 5m
        labels: { severity: warning, impact: SERVICE }
        annotations:
          summary: "{{ $labels.hostname }}: metadata log applied {{ $value }} ms late"
          description: "{{ $labels.instance }} applies the KRaft metadata log {{ $value }} ms behind the leader for 5 minutes: the quorum is not keeping up (disk or network)."
      - alert: KRaftMetadataErrors
        expr: max by (instance, hostname) (kafka_controller_kafkacontroller_metadataerrorcount{job="kafka-controller"}) > 0
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
      # source: confluent (KRaft metrics: FencedBrokerCount): a fenced broker runs but may not lead or follow partitions
      - alert: KafkaFencedBrokers
        expr: max by (env) (kafka_controller_kafkacontroller_fencedbrokercount{job="kafka-controller"}) > 0
        for: 5m
        labels: { severity: critical, impact: SERVICE }
        annotations:
          summary: "{{ $labels.env }}: {{ $value }} fenced brokers"
          description: "The KRaft controller reports {{ $value }} fenced brokers in {{ $labels.env }} for 5 minutes: they are stopped, or run but cannot serve partitions (no heartbeat to the controller, or still catching up the metadata log). Check the broker logs and kafka-metadata-quorum describe --status."

  - name: rest-proxy
    rules:
      # source: ours: the REST Proxy exports one error-rate series per endpoint (kafka_rest_jersey_metrics_<endpoint>_request_error_rate); sum them
      - alert: RestProxyErrors
        expr: sum by (instance, hostname) ({__name__=~"kafka_rest_jersey_metrics_.*_request_error_rate", job="rest-proxy"}) > 1
        for: 10m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: REST Proxy returns errors"
          description: "REST Proxy {{ $labels.instance }} has returned more than 1 error response per second for 10 minutes (4xx and 5xx together). Check client certificates and the broker connection."
      - alert: RestProxyThreadPoolBusy
        expr: max by (instance, hostname) (kafka_rest_jetty_metrics_thread_pool_usage{job="rest-proxy"}) > 0.9
        for: 10m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: REST Proxy thread pool above 90%"
          description: "The Jetty thread pool of {{ $labels.instance }} has been more than 90% used for 10 minutes: requests queue up. Check client load and broker latency."

  - name: control-center
    rules:
      # source: ours: C3 is a Kafka Streams application; client-state 0 CREATED, 1 REBALANCING, 2 RUNNING, 3 PENDING_SHUTDOWN, 4 NOT_RUNNING, 5 PENDING_ERROR, 6 ERROR
      # Not RUNNING for 15 minutes (stuck in REBALANCING or CREATED stalls the screens as much as ERROR does); short rebalances after a restart are normal
      - alert: ControlCenterStreamsNotRunning
        expr: max by (instance, hostname, client_id) (kafka_streams_stream_metrics_client_state{job="control-center"}) != 2
        for: 15m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: Control Center stopped processing"
          description: "A Kafka Streams client inside Control Center {{ $labels.instance }} has not been RUNNING for 15 minutes (state {{ $value }}: 1 REBALANCING, 4 NOT_RUNNING, 5 PENDING_ERROR, 6 ERROR): the C3 screens show stale data. Read journalctl -u confluent-control-center."
      # failed-stream-threads counts failures since start (it stays above 0 even when a thread is replaced), so test the increase
      - alert: ControlCenterStreamThreadsFailed
        expr: max by (instance, hostname) (delta(kafka_streams_stream_metrics_failed_stream_threads{job="control-center"}[15m])) > 0
        for: 0m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: Control Center stream thread failed"
          description: "{{ $value }} Kafka Streams threads of Control Center {{ $labels.instance }} failed in the last 15 minutes (uncaught exception). Read journalctl -u confluent-control-center; restart it if alive threads stay below normal."
      # source: ours: an idle stream thread still polls about 10 times a second (lab), so a poll rate of 0 means the thread is stuck
      - alert: ControlCenterStreamsStalled
        expr: min by (instance, hostname) (kafka_streams_stream_thread_metrics_poll_rate{job="control-center"}) == 0
        for: 10m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: Control Center stream thread stopped polling"
          description: "At least one Kafka Streams thread inside Control Center {{ $labels.instance }} has not polled for 10 minutes: the C3 screens stop updating. Read journalctl -u confluent-control-center, then restart it."
      # source: ours: RocksDB property metric (recording level INFO); the counter only grows, so any increase is an error
      - alert: ControlCenterRocksDBBackgroundErrors
        expr: max by (instance, hostname, rocksdb_state_id) (delta(kafka_streams_stream_state_metrics_background_errors{job="control-center"}[15m])) > 0
        for: 0m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: Control Center state store {{ $labels.rocksdb_state_id }} had RocksDB errors"
          description: "RocksDB background errors (flush or compaction) in state store {{ $labels.rocksdb_state_id }} of Control Center {{ $labels.instance }} in the last 15 minutes. Check the disk of c3-01 (full or read-only) and the C3 log."
      # source: ours: task-level dropped-records (recording level INFO): records C3 could not process (deserialization, expired windows)
      - alert: ControlCenterDroppedRecords
        expr: sum by (instance, hostname) (kafka_streams_stream_task_metrics_dropped_records_rate{job="control-center"}) > 0
        for: 10m
        labels: { severity: warning, impact: APPLICATION }
        annotations:
          summary: "{{ $labels.hostname }}: Control Center is dropping records"
          description: "Control Center {{ $labels.instance }} has been dropping {{ $value }} records per second for 10 minutes: some monitoring data will be missing from the C3 screens. Read the C3 log for the reason."

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
      # source: ours (standard JVM practice): deadlocked threads never recover by themselves
      - alert: JvmThreadsDeadlocked
        expr: max by (hostname, job) (jvm_threads_deadlocked{job=~"kafka-controller|kafka-broker|rest-proxy|control-center"}) > 0
        for: 5m
        labels: { severity: critical, impact: INFRASTRUCTURE }
        annotations:
          summary: "{{ $labels.hostname }} ({{ $labels.job }}): JVM threads deadlocked"
          description: "{{ $value }} threads of {{ $labels.hostname }} ({{ $labels.job }}) are deadlocked for 5 minutes. Take a thread dump (jcmd <pid> Thread.print) and restart the service."

  - name: host
    rules:
      # source: ours, replaces the official high_load (node_load1, needs node_exporter): Confluent Server's own host CPU gauge
      # (kafka.server:type=KafkaServer,name=linux-system-cpu-utilization-1m, percent 0-100). Duplicates the bank's host monitoring if it has one.
      - alert: KafkaHostCpuHigh
        expr: max by (hostname, job) (kafka_server_kafkaserver_linux_system_cpu_utilization_1m{job=~"kafka-controller|kafka-broker"}) > 80
        for: 10m
        labels: { severity: warning, impact: INFRASTRUCTURE }
        annotations:
          summary: "{{ $labels.hostname }}: host CPU above 80%"
          description: "The host {{ $labels.hostname }} ({{ $labels.job }}) has used more than 80% CPU for 10 minutes ({{ $value }}%). Look for other processes on the host, request rate and GC time."
EOF

echo "confluent-alerts.yml: $(grep -c '^      - alert:' ~/monitoring/to-bank/prometheus/confluent-alerts.yml) 條規則"
```

```out
confluent-alerts.yml: 26 條規則
```

**Alertmanager 設定**：兩個 webhook receiver 示範兩種格式，銀行留一種、刪另一種。

- `webhook-default`：Alertmanager 預設的 JSON（version 4），一次 POST 帶一個通知群組裡所有告警。
- `webhook-omnibus`：用 Alertmanager 的範本在 `payload` 組自訂 JSON，欄位照銀行 omnibus 的接收規格（對應見下表）。`group_by: ['...']` 讓每筆告警自己一組，所以自訂格式永遠是一筆告警一個 POST。

| omnibus 欄位 | 放什麼 |
|---|---|
| `source`、`ClassName`、`origin`、`hostname`、`sub_source` | 固定值；範本裡的是範例值，照銀行給的規格填，上線前請銀行監控團隊確認 |
| `msg_catalog` | 規則的 `impact` |
| `msg` | 規則的 `description` |
| `state` | OPEN／RESOLVED |
| `severity` | ERROR／PERFORMANCE（critical 對應 ERROR） |
| `sub_origin` | 「規則名稱：摘要」 |

自訂 JSON 的寫法有兩個陷阱（2026-10-26 實測）：`payload` 用**字串寫法**，每個值都經 `toJson`，值裡有雙引號或冒號才不會弄壞 JSON；用 map 寫法時，含 `: ` 的值會被當成 YAML 物件、像數字的字串（`"007"`）會變成數字 7。範本裡拿不到 `.GroupKey`，要編號就用告警的 `Fingerprint`。

webhook 網址 `WEBHOOK-RECEIVER:8080` 由銀行監控團隊換成行內的；需要認證就在 receiver 加 `http_config`。整段貼到 EOF：

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

alertmanager_lines=$(wc -l < ~/monitoring/to-bank/alertmanager/alertmanager.yml)
datasource_lines=$(wc -l < ~/monitoring/to-bank/grafana/datasource-prometheus.yml)
echo "alertmanager.yml $alertmanager_lines 行、datasource-prometheus.yml $datasource_lines 行"
```

```out
alertmanager.yml 39 行、datasource-prometheus.yml 12 行
```

**Grafana**：datasource 的名字與 uid 都是 `Prometheus`（官方 dashboard 指向這個）。dashboard 用官方的 32 個 JSON 原樣複製，只修兩件事：

1. 官方 JSON 是 Grafana 匯入畫面的格式，datasource 寫成佔位符 `${Prometheus}`，檔案佈建不會替換，每個 panel 都會「datasource not found」→ 改成固定的 uid `Prometheus`。
2. 成對的 ZooKeeper 版與 KRaft 版（例如 `kafka-cluster.json` 與 `kafka-cluster-kraft.json`）用同一個 uid，Grafana 只收第一個、後面的被丟掉 → 重複的改自己的 uid 並在標題加檔名。

落地區的檔是唯讀的，複製出來要加回寫入權限。**全部 32 個都放進去**，不挑；哪些在我們的元件上有資料見 B.1，沒有對應元件的（Connect、ksqlDB、Schema Registry、Flink…）畫面就是空的，不影響其他：

```bash
# 1. 官方的 32 個 dashboard 和 dashboard.yml 複製出來（落地區的檔是唯讀的，加回寫入權限）
assets=~/landing/monitoring/jmx-monitoring-stacks/jmxexporter-prometheus-grafana/assets
dashboards=$assets/grafana/provisioning/dashboards
cp $dashboards/*.json $dashboards/dashboard.yml ~/monitoring/to-bank/grafana/dashboards/
chmod u+w ~/monitoring/to-bank/grafana/dashboards/*

# 2. 修兩件事（datasource 佔位符、重複的 uid）：用 EOF 之前的那段 Python 改每個 JSON
python3 - <<'EOF'
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
        # same uid as an earlier file (the ZooKeeper-era twins): give it its own
        if i > 0:
            stem = os.path.basename(f)[:-5]
            d['uid'] = (uid + '-' + stem)[:40]
            d['title'] = d['title'] + ' [' + stem + ']'
            renamed += 1
        json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('dashboards: %d, placeholder datasource fixed, uid shared with another file (renamed): %d'
      % (len(files), renamed))
EOF
```

```out
dashboards: 32, placeholder datasource fixed, uid shared with another file (renamed): 4
```

根憑證，然後看整個資料夾。7071 沒有帳密，所以沒有密碼要交給銀行。**待銀行確認**（請銀行確認的事項 11.4）：7071 只放行行內 Prometheus 的來源位址（7.3 節的 firewalld 目前對所有來源開放）；這是 7071 唯一的存取控制：

```bash
# 1. 銀行根憑證（銀行的 Prometheus 驗 7071 用）；舊版留下的抓取密碼檔，有的話刪掉
cp /etc/pki/ca-trust/source/anchors/bank-root.pem ~/monitoring/to-bank/prometheus/ca.pem
rm -f ~/monitoring/to-bank/prometheus/scrape.pass

# 2. 整個資料夾有哪些檔（dashboard 的 JSON 只數個數）
cd ~/monitoring/to-bank
find . -type f ! -name '*.json' | sort
echo "dashboards: $(ls grafana/dashboards/*.json | wc -l) 個 JSON"
```

```out
./alertmanager/alertmanager.yml
./grafana/dashboards/dashboard.yml
./grafana/datasource-prometheus.yml
./prometheus/ca.pem
./prometheus/confluent-alerts.yml
./prometheus/scrape-confluent.yml
dashboards: 32 個 JSON
```

## 17.6 銀行的 Prometheus、Alertmanager、Grafana 接上來

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

正式環境是銀行監控團隊把 17.5 的 `to-bank/` 放進自己的三套系統（放哪裡見 17.5 的表格）；這一節其餘都是 lab 專用。

（lab 專用）lab 用四個容器扮演：Prometheus、Alertmanager、Grafana，加一個「webhook 接收端」（一支十行的 Python，收到什麼就印什麼，17.8 測告警用）。容器名稱都叫 `lab-mon-*`，接在 labnet，不在 compose 裡，所以主機名要用 `--add-host` 給 Prometheus。記憶體上限加起來約 1.2 GB。

先把 `to-bank/` 取出來，放成各容器要的樣子（webhook 網址換成接收端容器；Alertmanager 的 `--cluster.listen-address=` 留空是因為 lab 的 172.35.x.x 不是私有位址，gossip 會起不來）：

```bash
cd ~/kafka-lab

# 1. 每次重新做：清掉舊的，建各容器要的目錄
rm -rf bank-monitoring
mkdir -p bank-monitoring/prometheus/confluent bank-monitoring/alertmanager bank-monitoring/webhook
mkdir -p bank-monitoring/grafana/provisioning/datasources bank-monitoring/grafana/provisioning/dashboards

# 2. 從操作機取出 to-bank/
podman cp lab-ops02-1:/root/monitoring/to-bank "$(cygpath -m "$PWD/bank-monitoring/to-bank")"
cd bank-monitoring

# 3. 放成各容器要的樣子：webhook 網址換成接收端容器、datasource 指向 lab 的 Prometheus
cp to-bank/prometheus/* prometheus/confluent/
sed 's/WEBHOOK-RECEIVER/lab-mon-webhook/' to-bank/alertmanager/alertmanager.yml > alertmanager/alertmanager.yml
sed 's#http://PROMETHEUS:9090#http://lab-mon-prometheus:9090#' to-bank/grafana/datasource-prometheus.yml \
  > grafana/provisioning/datasources/prometheus.yml
cp to-bank/grafana/dashboards/* grafana/provisioning/dashboards/

confluent_files=$(ls prometheus/confluent | tr '\n' ' ')
dashboard_count=$(ls grafana/provisioning/dashboards | wc -l)
echo "prometheus: $confluent_files/ dashboards: $dashboard_count 個檔"
```

```out
prometheus: ca.pem confluent-alerts.yml scrape-confluent.yml / dashboards: 33 個檔
```

（lab 專用）行內 Prometheus 自己的 `prometheus.yml` 銀行原本就有，這裡只示範要加的三行：引用 scrape 設定、載入告警規則、指向 Alertmanager。一起寫出 webhook 接收端：

```bash
cd ~/kafka-lab/bank-monitoring

cat > prometheus/prometheus.yml <<'EOF'
global: { scrape_interval: 30s, evaluation_interval: 30s }
scrape_config_files: [ /etc/prometheus/confluent/scrape-confluent.yml ]
rule_files: [ /etc/prometheus/confluent/confluent-alerts*.yml ]
alerting: { alertmanagers: [ { static_configs: [ { targets: [ "lab-mon-alertmanager:9093" ] } ] } ] }
EOF

# webhook 接收端：收到什麼就印什麼（一行：路徑 | User-Agent | 本文）
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

（lab 專用）起四個容器。映像檔 `prom/prometheus`、`prom/alertmanager`、`grafana/grafana` 是銀行自己的事（正式環境不是我們帶進去的），lab 從 Docker Hub 拉；webhook 接收端用 lab 的 `lab-node:96`。Grafana 開匿名 Admin 只為了 lab 好操作，並發佈到 Windows 的 13000。最後要看到 4 個 `lab-mon-*` 容器都是 `Up`：

```bash
cd ~/kafka-lab/bank-monitoring

# 給 podman 的路徑要是 Windows 路徑（C:/Users/...），所以下面的 -v 都先用 cygpath -m 轉過

# 1. Prometheus 要認得各主機的名稱（監控容器不在 compose 裡，沒有 extra_hosts）：每台一個 --add-host
#    寫法：主機:IP 的最後一段
hosts=""
for entry in kc01:21 kc02:22 kc03:23 kb01:31 kb02:32 kb03:33 kb04:34 rest01:41 rest02:42 c3-01:51; do
  name=$(echo $entry | cut -d: -f1)
  last=$(echo $entry | cut -d: -f2)
  hosts="$hosts --add-host $name.poc.lab:172.35.0.$last"
done

# 2. webhook 接收端（用 lab-node:96 跑那支 Python）
podman run -d --restart unless-stopped --name lab-mon-webhook --network lab_labnet --memory 64m \
  -v "$(cygpath -m "$PWD/webhook"):/w:ro" lab-node:96 python3 -u /w/receiver.py > /dev/null

# 3. Alertmanager（--cluster.listen-address= 留空：lab 的 172.35.x.x 不是私有位址，gossip 起不來）
podman run -d --restart unless-stopped --name lab-mon-alertmanager --network lab_labnet --memory 128m \
  -v "$(cygpath -m "$PWD/alertmanager/alertmanager.yml"):/etc/alertmanager/alertmanager.yml:ro" \
  prom/alertmanager:v0.34.1 \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/alertmanager \
  --cluster.listen-address= > /dev/null

# 4. Prometheus（--web.enable-lifecycle：17.8 要叫它重新載入規則）
podman run -d --restart unless-stopped --name lab-mon-prometheus --network lab_labnet --memory 600m $hosts \
  -v "$(cygpath -m "$PWD/prometheus/prometheus.yml"):/etc/prometheus/prometheus.yml:ro" \
  -v "$(cygpath -m "$PWD/prometheus/confluent"):/etc/prometheus/confluent:ro" \
  prom/prometheus:v3.5.0 \
  --config.file=/etc/prometheus/prometheus.yml \
  --web.enable-lifecycle \
  --storage.tsdb.retention.time=1d > /dev/null

# 5. Grafana（匿名 Admin 只為了 lab 好操作；發佈到 Windows 的 13000）
podman run -d --restart unless-stopped --name lab-mon-grafana --network lab_labnet --memory 400m -p 13000:3000 \
  -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
  -v "$(cygpath -m "$PWD/grafana/provisioning"):/etc/grafana/provisioning:ro" grafana/grafana:11.3.0 > /dev/null

# 6. 等 60 秒，4 個都要是 Up
sleep 60
podman ps --format '{{.Names}} {{.Status}}' | grep -E 'lab-mon-(prometheus|alertmanager|grafana|webhook)' | sort
```

```out
lab-mon-alertmanager Up About a minute
lab-mon-grafana Up About a minute
lab-mon-prometheus Up About a minute
lab-mon-webhook Up About a minute
```

## 17.7 驗證：target、規則、dashboard

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

正式環境由銀行監控團隊在自己的三套系統上看同樣四件事：每個 job 有幾個 target 是 up（10 個都要 up）；告警規則載入且沒有錯；Alertmanager 認得 Prometheus；Grafana 有 32 個 dashboard、datasource 連得到 Prometheus。lab 裡：從監控容器裡用 `curl` 查（容器內有 Python 可以整理輸出）：

```bash
# 在 labnet 上起一個臨時容器，執行 EOF 之前的那一段（每段的 Python 只是把 JSON 整理成幾行字）
podman run --rm -i --network lab_labnet lab-node:96 bash -s <<'EOF'
prometheus=http://lab-mon-prometheus:9090
grafana=http://lab-mon-grafana:3000

# 1. 每個 job 有幾個 target 是 up
curl -s $prometheus/api/v1/targets | python3 -c '
import json, sys, collections
up = collections.Counter(); total = collections.Counter()
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    total[t["labels"]["job"]] += 1; up[t["labels"]["job"]] += t["health"] == "up"
for j in sorted(total): print("%-17s up %d / %d" % (j, up[j], total[j]))
print("合計 up %d / %d" % (sum(up.values()), sum(total.values())))'

# 2. 告警規則：幾條、幾條載入有錯
curl -s $prometheus/api/v1/rules | python3 -c '
import json, sys
g = json.load(sys.stdin)["data"]["groups"]
r = [x for y in g for x in y["rules"]]
print("告警規則 %d 條，載入有錯 %d 條" % (len(r), sum(x["health"] != "ok" for x in r)))'

# 3. Prometheus 認得的 Alertmanager
curl -s $prometheus/api/v1/alertmanagers | python3 -c '
import json, sys
print("Prometheus 看到的 Alertmanager:", [a["url"] for a in json.load(sys.stdin)["data"]["activeAlertmanagers"]])'

# 4. Grafana：幾個 dashboard、datasource 連不連得到 Prometheus
curl -s "$grafana/api/search?type=dash-db" | python3 -c '
import json, sys
print("Grafana dashboard:", len(json.load(sys.stdin)), "個")'

curl -s $grafana/api/datasources/uid/Prometheus/health
EOF
```

```out
control-center    up 1 / 1
kafka-broker      up 4 / 4
kafka-controller  up 3 / 3
rest-proxy        up 2 / 2
合計 up 10 / 10
告警規則 26 條，載入有錯 0 條
Prometheus 看到的 Alertmanager: ['http://lab-mon-alertmanager:9093/api/v2/alerts']
Grafana dashboard: 32 個
{"details":{"application":"Prometheus","features":{"rulerApiEnabled":false}},"message":"Successfully queried the Prometheus API.","status":"OK"}
```

Grafana 的 dashboard 真的查得到資料：用 Grafana 自己的查詢介面（`/api/ds/query`，和畫面上 panel 走同一條路）跑一個 controller 指標的查詢（active controller 數，叢集健康時是 1），`$env` 換成 `lab`：

```bash
# 在 labnet 上起一個臨時容器，執行 EOF 之前的那一段
podman run --rm -i --network lab_labnet lab-node:96 bash -s <<'EOF'
# 1. 查詢內容（JSON）：active controller 數的即時值
query='{
  "queries": [
    {
      "refId": "A",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "expr": "sum(kafka_controller_kafkacontroller_activecontrollercount{env=\"lab\", job=\"kafka-controller\"})",
      "instant": true
    }
  ],
  "from": "now-5m",
  "to": "now"
}'

# 2. 送給 Grafana，印出狀態與查到的值
curl -s -X POST http://lab-mon-grafana:3000/api/ds/query -H "Content-Type: application/json" -d "$query" | python3 -c '
import json, sys
r = json.load(sys.stdin)["results"]["A"]
print("status", r["status"], "active controller 數 =", r["frames"][0]["data"]["values"][1][0])'
EOF
```

```out
status 200 active controller 數 = 1
```

lab 裡：Windows 瀏覽器開 `http://localhost:13000` 就是 Grafana，左邊 Dashboards 底下有 32 個。

## 17.8 測告警：兩種 webhook 格式與解除

下面這張圖畫出一條告警從指標到兩種 webhook 的路徑。

![alertpath]

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

不用弄壞叢集：在 Prometheus 多放一條永遠成立的測試規則（`vector(1)`），帶著和正式規則一樣的標籤與註解（`description` 裡故意放了雙引號和冒號，看自訂 JSON 會不會被弄壞）。Prometheus 重新載入規則後，告警送到 Alertmanager，約 1 分鐘內（規則每 30 秒算一次，再加 Alertmanager 的 group_wait 10 秒）兩個 receiver 都會收到。這裡的 Prometheus 與接收端是 lab 的容器；正式環境由銀行監控團隊在自己的 Prometheus 上做同樣的事：

```bash
cd ~/kafka-lab/bank-monitoring

# 0. 記下開始的時間（UTC）：之後只讀這個時間以後的接收端日誌，重測時才不會讀到上一次的通知
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 1. 測試規則：永遠成立
cat > prometheus/confluent/confluent-alerts-test.yml <<'EOF'
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

# 2. 叫 Prometheus 重新載入規則，等 70 秒
podman exec lab-mon-prometheus wget -q -O- --post-data='' http://localhost:9090/-/reload
sleep 70

# 3. 接收端收到幾次（兩個 receiver 各一次）
podman logs --since "$since" lab-mon-webhook 2>&1 | grep -c ConfluentTestAlert
```

```out
2
```

先看**預設格式**：整包 JSON，`alerts` 是陣列（一個通知群組可能有很多筆），欄位是 Alertmanager 的 version 4：

```bash
# 1. 接收端日誌裡第一筆送到 /default 的測試告警
#    日誌一行長這樣：POST /default | Alertmanager/0.34.1 | {"version":"4",…}
test_posts=$(podman logs --since "$since" lab-mon-webhook 2>&1 | grep ConfluentTestAlert)
post=$(echo "$test_posts" | grep "^POST /default" | head -1)

# 2. 拆開：路徑、User-Agent（前後各帶一個空白）、JSON 本文
post_path=$(echo "$post" | cut -d' ' -f2)
agent=$(echo "$post" | cut -d'|' -f2)
body=$(echo "$post" | cut -d'|' -f3-)

# 3. 第一行印「路徑 User-Agent」，JSON 本文整理成重點欄位（Python 在 lab-node:96 裡跑）
printf '%s%s\n%s\n' "$post_path" "$agent" "$body" | podman run --rm -i lab-node:96 python3 -c '
import json, sys
head, body = sys.stdin.read().split("\n", 1)
d = json.loads(body)
print(head)
print(json.dumps({k: d[k] for k in ("version", "status", "receiver", "groupKey")}, ensure_ascii=False))
a = d["alerts"][0]
print(json.dumps({"status": a["status"], "labels": a["labels"], "annotations": a["annotations"],
                  "startsAt": a["startsAt"], "fingerprint": a["fingerprint"]}, ensure_ascii=False, indent=1))'
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
# 1. 接收端日誌裡第一筆送到 /omnibus 的測試告警
test_posts=$(podman logs --since "$since" lab-mon-webhook 2>&1 | grep ConfluentTestAlert)
post=$(echo "$test_posts" | grep "^POST /omnibus" | head -1)

# 2. 拆開：路徑、User-Agent（前後各帶一個空白）、JSON 本文
post_path=$(echo "$post" | cut -d' ' -f2)
agent=$(echo "$post" | cut -d'|' -f2)
body=$(echo "$post" | cut -d'|' -f3-)

# 3. 第一行印「路徑 User-Agent」，JSON 本文排版後印出（Python 在 lab-node:96 裡跑）
printf '%s%s\n%s\n' "$post_path" "$agent" "$body" | podman run --rm -i lab-node:96 python3 -c '
import json, sys
head, body = sys.stdin.read().split("\n", 1)
print(head)
print(json.dumps(json.loads(body), ensure_ascii=False, indent=1))'
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
cd ~/kafka-lab/bank-monitoring

# 1. 拿掉測試規則、叫 Prometheus 重新載入，等約 5 分鐘（告警過期之後才送 resolved）
rm prometheus/confluent/confluent-alerts-test.yml
podman exec lab-mon-prometheus wget -q -O- --post-data='' http://localhost:9090/-/reload
sleep 290

# 2. 接收端收到的每一筆測試告警：路徑與狀態（Python 在 lab-node:96 裡跑；since 是這一節開頭記下的時間）
test_posts=$(podman logs --since "$since" lab-mon-webhook 2>&1 | grep ConfluentTestAlert)
echo "$test_posts" | podman run --rm -i lab-node:96 python3 -c '
import re, sys
for line in sys.stdin:
    path = re.match(r"POST (\S+)", line).group(1)
    state = re.search(r"\"(?:state|status)\":\"(\w+)\"", line).group(1)
    print(path.ljust(11), state)'
```

```out
/omnibus    OPEN
/default    firing
/omnibus    RESOLVED
/default    resolved
（兩個 receiver 的先後每次不同；每個 receiver 都要有一行開啟、一行解除）
```

> 實際的 omnibus：接收端如果要認證（例如 API token），在 `webhook_configs` 的 `http_config` 加 `authorization`；token 放 Alertmanager 設定檔以外的檔案（`credentials_file`），不寫進 YAML。`ProblemSeverity` 的對應（這裡 critical → `ERROR`、warning → `PERFORMANCE`）是範例，照 omnibus 的定義改範本。

# 18. 第十八站：稽核日誌（audit log）

![audit]

**這一章在做什麼**：讓 Kafka 把「誰對什麼做了什麼」記成稽核事件，並依銀行要求分流與設定保留期。前提：第 15 章已做（密碼進 Secret Protection）、第 11 章的 RBAC 已建。這一章會**滾動重啟** controller 與 broker（18.2），請在變更時段一台一台做。

Confluent Server 內建稽核：誰、用什麼身分、對哪個 topic 做了什麼、准還是拒，每一筆都是一個事件，寫進 Kafka 自己的 topic。預設是用 broker 自己的身分寫、全部塞同一個 topic。銀行要的是：用一個**專用的低權限帳號**寫、**敏感 topic 的事件分開放、留久一點**、排除平台自己的雜訊。這一章把這三件事做上去，密碼一樣進 Secret Protection。

| 誰 | 做什麼 |
|---|---|
| 小安 | 建寫入帳號與權限、改 controller／broker 的設定（加密、派送）、滾動重啟、製造允許與拒絕的事件來驗證 |
| 銀行稽核 | 之後用 OP menu 的 43（查詢、篩選後存檔），或自己的 SIEM 讀這兩個 topic |

## 18.1 專用的寫入帳號

@role 小安 | ops02 | root

這一節建一個專門寫稽核事件的帳號，把權限壓到最小。`confluent-audit` 是 SCRAM 帳號，只能寫與管理 `confluent-audit-log-events` 開頭的 topic（prefix 同時涵蓋 `_sensitive`），不是 super user：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
BS=kb01.poc.lab:9094

# 1. 寫入帳號的密碼（已經有就沿用；檔案 0600）
if [ ! -s ~/secrets/confluent-audit.pass ]; then
  install -m 0600 /dev/null ~/secrets/confluent-audit.pass
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/confluent-audit.pass
fi

# 2. 建 SCRAM 帳號
password=$(cat ~/secrets/confluent-audit.pass)
kafka-configs \
  --bootstrap-server $BS \
  --command-config ~/conf/client-admin.properties \
  --alter \
  --entity-type users \
  --entity-name confluent-audit \
  --add-config "SCRAM-SHA-512=[iterations=8192,password=$password]" > /dev/null
unset password

# 3. 權限：audit topic prefix 的寫入與管理（svc-ops 登入 MDS 來綁）
confluent login \
  --url https://kb01.poc.lab:8090 \
  --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only \
  --client-cert-path ~/pki/certs/svc-ops.crt \
  --client-key-path ~/pki/keys/svc-ops.key > /dev/null 2>&1
cluster_id=$(curl -sk https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

for role in DeveloperWrite DeveloperManage; do
  confluent iam rbac role-binding create \
    --principal User:confluent-audit \
    --role $role \
    --resource Topic:confluent-audit-log-events \
    --prefix \
    --kafka-cluster "$cluster_id" > /dev/null 2>&1
done

# 4. 確認（表頭兩行不印）
confluent iam rbac role-binding list \
  --principal User:confluent-audit \
  --kafka-cluster "$cluster_id" 2> /dev/null | tail -n +3
```

```out
  User:confluent-audit | DeveloperManage | Topic         | confluent-audit-log-events | PREFIXED
  User:confluent-audit | DeveloperWrite  | Topic         | confluent-audit-log-events | PREFIXED
```

## 18.2 設定片段：寫入者、路由、保留天數

@role 小安 | ops02 | root

這一節把稽核設定加進 controller 與 broker 共用的設定片段，決定誰寫、事件放哪個 topic、留幾天。接在 `common.tpl`（controller 與 broker 共用）後面。路由規則是一行 JSON：`payments.*` 的 produce／consume（允許與拒絕）和被拒絕的 describe 送到 `_sensitive`（留 365 天），其他送預設 topic（留 90 天），`kafka-internal`、`svc-c3` 的事件不記：

```bash
cd ~/conf

# 改之前留一份（不含稽核設定的共用區塊）
cp common.tpl common.tpl.plain.pre-audit

# 接在 common.tpl 後面
cat >> common.tpl <<'EOF'

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
cd ~/conf

# 1. 密碼讀進變數；envsubst 只換下面這些變數
export STORE_PASSWORD=$(cat ~/pki/store.pass)
export LDAP_BIND_PASSWORD=$(cat ~/secrets/ldap-bind.pass)
export AUDIT_PASSWORD=$(cat ~/secrets/confluent-audit.pass)
vars='${HOST_FQDN} ${NODE_ID} ${RACK} ${STORE_PASSWORD} ${LDAP_BIND_PASSWORD} ${AUDIT_PASSWORD}'

# 2. 7 台的 server.properties：和 10.2 一樣產生（寫法：主機:node.id:rack；檔案 0600）
for entry in kc01:1:- kc02:2:- kc03:3:- kb01:101:rack-a kb02:102:rack-a kb03:103:rack-b kb04:104:rack-b; do
  n=$(echo $entry | cut -d: -f1)
  export HOST_FQDN=$n.poc.lab
  export NODE_ID=$(echo $entry | cut -d: -f2)
  export RACK=$(echo $entry | cut -d: -f3)

  case $n in
    kc*) tpl=controller.tpl ;;
    *)   tpl=broker.tpl ;;
  esac

  install -m 0600 /dev/null $n.server.properties
  envsubst "$vars" < $tpl > $n.server.properties
  echo >> $n.server.properties
  envsubst "$vars" < common.tpl >> $n.server.properties
done

unset STORE_PASSWORD LDAP_BIND_PASSWORD AUDIT_PASSWORD

# 3. 加密：這次多了 jaas.config 這種欄位（裡面有 confluent-audit 的密碼）
export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)

for f in *.server.properties; do
  keys=$(grep -E '^[^#].*(password|credentials|jaas.config)=' $f | cut -d= -f1 | paste -sd,)

  confluent secret file encrypt --config-file $f --local-secrets-file ~/secrets/security.properties \
    --remote-secrets-file /etc/confluent/secrets/security.properties --config "$keys" > /dev/null

  encrypted=$(grep -c '\${securepass:' $f)
  plaintext=$(awk '/^[^#].*(password|credentials)=[^$]/ {c++} END {print c + 0}' $f)
  echo "$f: $encrypted encrypted, plaintext=$plaintext"
done

unset CONFLUENT_SECURITY_MASTER_KEY

# 4. 派送：設定檔與密文檔（root:confluent 0640）；在那台執行 EOF 之前的那一段（$1 = 主機；bash -e）
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  scp -q $h.server.properties ~/secrets/security.properties $h.poc.lab:/tmp/

  ssh $h.poc.lab bash -e -s -- $h <<'EOF'
sudo install -o root -g confluent -m 0640 /tmp/$1.server.properties /etc/confluent/kafka/server.properties
sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties
rm -f /tmp/$1.server.properties /tmp/security.properties
EOF

  printf '%s ' $h
done
echo
```

```out
kb01.server.properties: 22 encrypted, plaintext=0
（7 個檔；broker 22、controller 13）
kc01 kc02 kc03 kb01 kb02 kb03 kb04
```

@role 小安 | ops02 | root

滾動重啟 controller 與 broker，確認兩個稽核 topic 建好了：

```bash
# 1. controller：一台一台重啟，等到 active（在那台每 2 秒看一次，最多 30 次）
for h in kc01 kc02 kc03; do
  ssh $h.poc.lab bash -s <<'EOF'
sudo systemctl restart confluent-server

for i in $(seq 1 30); do
  if systemctl is-active -q confluent-server; then
    break
  fi

  sleep 2
done

echo "$(hostname) $(systemctl is-active confluent-server)"
EOF
done

# 2. broker：一台一台重啟，等 MDS（8090）回 200（每 5 秒看一次，最多 60 次）
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  for i in $(seq 1 60); do
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done

# 3. 等 20 秒，兩個稽核 topic 都建好了
sleep 20
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list | grep audit
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
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. alice 的連線設定：AD 帳密走 LDAP listener 9096（檔案 0600；EOF 沒加引號，兩個密碼變數會換成值）
password=$(cat ~/secrets/ad-test-users.pass)
store_password=$(cat ~/pki/store.pass)
install -m 0600 /dev/null ~/conf/client-alice.properties

cat > ~/conf/client-alice.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="alice" password="$password";
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
ssl.truststore.password=$store_password
EOF
unset password store_password

# 2. alice 往 payments.events 寫一筆（允許、敏感）
echo "audit-test-$(date +%s)" | kafka-console-producer \
  --bootstrap-server kb01.poc.lab:9096 \
  --producer.config ~/conf/client-alice.properties \
  --topic payments.events > /dev/null 2>&1
echo "alice: produced to payments.events"

# 3. app-orders 讀 payments.events（沒有權限：拒絕、敏感）
denied=$(kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9095 \
  --consumer.config ~/conf/app-orders.properties \
  --topic payments.events \
  --group orders-sneak \
  --max-messages 1 \
  --timeout-ms 10000 2>&1 | grep -o 'TopicAuthorizationException\|not authorized' | head -1)
echo "app-orders on payments.events: $denied"

# 4. app-orders 讀自己的 orders.events（允許、不敏感）
read_count=$(kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9095 \
  --consumer.config ~/conf/app-orders.properties \
  --topic orders.events \
  --group orders-audit-check \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 15000 2> /dev/null | wc -l)
echo "app-orders on orders.events: read $read_count"
```

```out
alice: produced to payments.events
app-orders on payments.events: TopicAuthorizationException
app-orders on orders.events: read 1
```

等幾秒讓事件寫進去，再用 alice 讀兩個 audit topic，按「主體／方法／資源／准拒」統計（只列這幾個測試身分）：

```bash
sleep 10
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 兩個稽核 topic 各讀一遍（從頭讀，20 秒沒有新的就停）
# Python 讀 stdin 的稽核事件（一行一個 JSON），印總數，並依「主體／方法／資源／准拒」統計幾個測試身分的事件
for t in confluent-audit-log-events_sensitive confluent-audit-log-events; do
  echo "== $t"
  kafka-console-consumer \
    --bootstrap-server kb01.poc.lab:9096 \
    --consumer.config ~/conf/client-alice.properties \
    --topic $t \
    --from-beginning \
    --timeout-ms 20000 2> /dev/null | python3 -c '
import sys, json, collections
c = collections.Counter(); tot = 0
for line in sys.stdin:
    try: e = json.loads(line)["data"]
    except Exception: continue
    tot += 1
    p = e.get("authenticationInfo", {}).get("principal", "?"); m = e.get("methodName", "?").split(".")[-1]
    a = e.get("authorizationInfo", {}); g = a.get("granted"); r = a.get("resourceName", "")
    if p in ("User:alice", "User:app-orders-a", "User:bob", "User:carol"):
        c[(p, m, r[:28], "ALLOWED" if g else "DENIED")] += 1
print("  total events:", tot)
for k, v in sorted(c.items()): print("  %-16s %-10s %-28s %-8s x%d" % (k[0], k[1], k[2], k[3], v))
'
done
```

```out
== confluent-audit-log-events_sensitive
  total events: 2
  User:alice       Produce    payments.events              ALLOWED  x1
  User:app-orders-a Metadata   payments.events              DENIED   x1
== confluent-audit-log-events
  total events: 247
  User:alice       Authorize  kafka-cluster                ALLOWED  x1
  User:bob         Authorize  __opmenu-host-ops            ALLOWED  x2
  User:bob         Authorize  kafka-cluster                DENIED   x1
  （… 第 16 站 OP menu 問 MDS 留下的授權事件）
```

> 三件事值得看清楚：(1) 敏感 topic 的事件在 `_sensitive`：alice 的 produce（允許）和 app-orders 想讀時的 Metadata（describe 被拒）。(2) **一般 topic 的 produce／consume 不會被記**：app-orders 讀 orders.events 沒有出現在任何 topic，因為 Confluent 預設只記「管理類」與「授權類」事件（例如上面 MDS 的 Authorize，那是第 16 章 OP menu 問權限留下的），produce／consume 只在路由裡明確列出的 topic 才記。要記全部就把 `crn:///kafka=*/topic=*` 的 produce／consume 也寫進 routes，量會很大。(3) `kafka-internal`、`svc-c3` 完全不出現。

@role 稽核單位（lab：alice 代打；carol 沒有讀取權限） | ops02 | root

稽核單位平常用 OP menu 的 43：先選看哪一個稽核 topic，再依主體、結果篩最近 N 分鐘的事件，畫面顯示最後 50 筆（時間換成本地時間），要交出去就存成檔案（`/var/log/opmenu/audit-<時間>-<操作者>.jsonl`，0600）。三個選擇：**一般**（`confluent-audit-log-events`：管理類、授權類事件，預設）、**敏感**（`_sensitive`：18.2 路由規則點名的敏感 topic 的讀寫）、**兩個都看**（依時間合併）。非互動時第 5 個參數是 `normal`、`sensitive` 或 `all`。讀取權限一個 prefix 綁定就涵蓋兩個 topic。下面篩出第 16 站 bob 被擋下的兩件事（42 改權限、91 緊急模式）並存檔；再看敏感 topic 裡 app-orders-a 想讀 `payments.events` 被拒的事件；carol 沒有稽核 topic 的讀取權限，被 Kafka 拒絕：

```bash
password=$(cat ~/secrets/ad-test-users.pass)

# 下面每一步都是用那個人的帳密非互動跑一次選單（同第 16 章），濾掉 SLF4J 訊息與顏色碼

# 1. 一般 topic：最近 240 分鐘 bob 被拒的事件，存檔（檔名裡的時間換成 <時間>）
output=$(env OPMENU_USER=alice OPMENU_PASS="$password" OPMENU_YES=1 JAVA_HOME=/opt/java/current \
  /opt/opmenu/opmenu.sh --run 43 240 bob DENIED save 2>&1 < /dev/null \
  | grep -v '^SLF4J' \
  | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | grep -E '符合|DENIED$|已匯出' | sed -E 's/audit-[0-9]{8}-[0-9]{6}/audit-<時間>/'

# 2. 敏感 topic：app-orders-a 的事件（只印第一行與最後一行）
output=$(env OPMENU_USER=alice OPMENU_PASS="$password" OPMENU_YES=1 JAVA_HOME=/opt/java/current \
  /opt/opmenu/opmenu.sh --run 43 240 app-orders-a - - sensitive 2>&1 < /dev/null \
  | grep -v '^SLF4J' \
  | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | grep -E '符合|payments' | sed -n '1p;$p'

# 3. carol 沒有讀取權限：被 Kafka 拒絕
output=$(env OPMENU_USER=carol OPMENU_PASS="$password" OPMENU_YES=1 JAVA_HOME=/opt/java/current \
  /opt/opmenu/opmenu.sh --run 43 240 2>&1 < /dev/null \
  | grep -v '^SLF4J' \
  | sed 's/\x1b\[[0-9;]*m//g')
echo "$output" | tail -1

unset password
```

```out
最近 240 分鐘符合 2 筆(confluent-audit-log-events)(主體 User:bob)(結果 DENIED);顯示最後 50 筆:
2026-10-30 18:20:52 User:bob         mds.Authorize        AlterAccess    orders.                    DENIED
2026-10-30 18:20:52 User:bob         mds.Authorize        Alter          kafka-cluster              DENIED
已匯出 2 筆:/var/log/opmenu/audit-<時間>-alice.jsonl
最近 240 分鐘符合 8 筆(confluent-audit-log-events_sensitive)(主體 User:app-orders-a);顯示最後 50 筆:
2026-10-30 20:29:14 User:app-orders-a kafka.Metadata       Describe       payments.events            DENIED
Kafka 拒絕:你的群組沒有這項權限,請依變更單申請。
```

## 18.4 要跟稽核單位說清楚的事

| 項目 | 說明 |
|---|---|
| 寫入者 | `confluent-audit`（SCRAM，只有 audit topic 的 Write／Manage），不是 super user；密碼在 Secret Protection 裡 |
| 保留 | 預設 topic 90 天、`_sensitive` 365 天，都是 topic 的 retention；要更久就外送 SIEM |
| 誰能讀 | 綁了 audit topic DeveloperRead 的群組（lab 是 SystemAdmin 直接讀）；稽核群組用 OP menu 43 查詢與匯出 |
| 量 | `kafka-internal`、`svc-c3` 已排除；只有路由列出的 topic 才記 produce／consume，要擴大範圍前先估磁碟 |
| 改規則 | 改 `common.tpl` 的 router JSON → 重新加密派送 → 滾動重啟（和這一章一樣） |
| 可靠度 | 兩個 audit topic 都是 replication factor 3（lab 確認：`kafka-topics --describe`），`min.insync.replicas=1`：稽核寫入不因少一台 broker 而停；原廠建議稽核量大或要求隔離時，送到**專用的稽核叢集**（`confluent.security.event.logger.exporter.kafka.bootstrap.servers` 指過去） |

確認 replication factor（換 broker、縮減之後也看一次）：

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 每個 topic 的第一行（總覽），只取名稱、replication factor、min.insync.replicas
for t in confluent-audit-log-events confluent-audit-log-events_sensitive; do
  overview=$(kafka-topics \
    --bootstrap-server kb01.poc.lab:9094 \
    --command-config ~/conf/client-admin.properties \
    --describe \
    --topic $t 2> /dev/null | head -1)
  echo "$overview" | grep -oE 'Topic: [^[:space:]]+|ReplicationFactor: [0-9]+|min.insync.replicas=[0-9]+' | paste -sd' '
done
```

```out
Topic: confluent-audit-log-events ReplicationFactor: 3 min.insync.replicas=1
Topic: confluent-audit-log-events_sensitive ReplicationFactor: 3 min.insync.replicas=1
```

# 19. 第十九站：驗收與收尾

![acceptance]

**這一章在做什麼**：交付前把整個平台完整驗一遍，並把安裝期間留下的東西收乾淨。前提：第 2–18 章都做完（沒做的延伸章節，對應的檢查項目會是 FAIL，先確認是不是該章沒做）。通過標準：19.1–19.3 每一組都是「N / N 項通過」，沒有任何 FAIL；19.4 的重啟與冷開機要自己回來。

每一章結尾都有自己的檢查，但交付前要有一份**一次跑完、結果能附在驗收文件裡**的清單。四組：平台健康、安全（正向與反向都測）、應用程式端、維運。最後是收尾：安裝期間留在操作機與主機上的東西，哪些要留、哪些要收。

這份驗收不綁版本：裝完**安裝基底**（8.2.4）跑一次，第 29 章遷移的每一段（C3 與套件、JDK 25、finalize）之後各跑一次，第 30 章 OS 更新到 9.8 之後再跑一次，結果都要全數通過。

## 19.1 平台健康

@role 小安 | ops02 | root

每一項都是同樣的寫法：`all` 加 1，判斷，通過就 `ok` 加 1 並印 `ok`，沒過就印 `FAIL`。判斷時不印指令本身的輸出。`all`、`ok` 跨塊延續，這一節的幾塊要在同一個 shell 接著貼。

先看 KRaft、服務與 MDS：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
ca=/etc/pki/ca-trust/source/anchors/bank-root.pem
ok=0
all=0

# 1. controller quorum 有 leader
all=$((all + 1))

if kafka-metadata-quorum \
  --bootstrap-controller kc01.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties \
  describe --status 2> /dev/null | grep -q "LeaderId: *[0-9]"; then
  echo "ok   controller quorum 有 leader"
  ok=$((ok + 1))
else
  echo "FAIL controller quorum 有 leader"
fi

# 2. 7 台 confluent-server
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  all=$((all + 1))

  if ssh $h.poc.lab 'systemctl is-active -q confluent-server' > /dev/null 2>&1; then
    echo "ok   $h confluent-server active"
    ok=$((ok + 1))
  else
    echo "FAIL $h confluent-server active"
  fi
done

# 3. 4 台 MDS（連不上時狀態碼是 000）
for h in kb01 kb02 kb03 kb04; do
  all=$((all + 1))
  url=https://$h.poc.lab:8090/v1/metadata/id

  if [ "$(curl -s --cacert $ca -o /dev/null -w '%{http_code}' --max-time 10 $url)" = 200 ]; then
    echo "ok   $h MDS 8090 回 200"
    ok=$((ok + 1))
  else
    echo "FAIL $h MDS 8090 回 200"
  fi
done
```

```out
ok   controller quorum 有 leader
ok   kc01 confluent-server active
（…）
ok   kb04 MDS 8090 回 200
```

partition 與 Self-Balancing：

```bash
# 4. 沒有 under-replicated partition：kafka-topics --describe 加這個選項時，列不出任何 partition
all=$((all + 1))
count=$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --describe --under-replicated-partitions 2> /dev/null | awk '/Partition:/ {c++} END {print c + 0}')

if [ "$count" = 0 ]; then
  echo "ok   沒有 under-replicated partition"
  ok=$((ok + 1))
else
  echo "FAIL 沒有 under-replicated partition"
fi

# 5. 沒有 offline partition（做法同上）
all=$((all + 1))
count=$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --describe --unavailable-partitions 2> /dev/null | awk '/Partition:/ {c++} END {print c + 0}')

if [ "$count" = 0 ]; then
  echo "ok   沒有 offline partition"
  ok=$((ok + 1))
else
  echo "FAIL 沒有 offline partition"
fi

# 6. Self-Balancing 是啟用的
all=$((all + 1))

if kafka-rebalance-cluster \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --status 2> /dev/null | grep -q "Balancer status: ENABLED"; then
  echo "ok   Self-Balancing 啟用"
  ok=$((ok + 1))
else
  echo "FAIL Self-Balancing 啟用"
fi
```

```out
ok   沒有 under-replicated partition
ok   沒有 offline partition
ok   Self-Balancing 啟用
```

REST Proxy、C3、JMX exporter，最後印這一組的統計：

```bash
# 7. REST Proxy 經 LB（mTLS）
all=$((all + 1))

if [ "$(curl -s --cacert $ca -o /dev/null -w '%{http_code}' --max-time 10 \
  --cert ~/pki/certs/app-legacy-billing.crt \
  --key ~/pki/keys/app-legacy-billing.key \
  https://rest.poc.lab:8082/v3/clusters)" = 200 ]; then
  echo "ok   REST Proxy 經 LB 回 200（mTLS）"
  ok=$((ok + 1))
else
  echo "FAIL REST Proxy 經 LB 回 200（mTLS）"
fi

# 8. Control Center 畫面
all=$((all + 1))

if [ "$(curl -s --cacert $ca -o /dev/null -w '%{http_code}' --max-time 10 https://c3-01.poc.lab:9021/)" = 200 ]; then
  echo "ok   Control Center 9021 回 200"
  ok=$((ok + 1))
else
  echo "FAIL Control Center 9021 回 200"
fi

# 9. C3 內建的 Prometheus 有 broker 的指標
all=$((all + 1))

if curl -s --cacert $ca \
  --cert ~/pki/certs/svc-ops.crt \
  --key ~/pki/keys/svc-ops.key \
  https://c3-01.poc.lab:9090/api/v1/label/__name__/values | grep -q confluent_kafka_server; then
  echo "ok   C3 的 Prometheus 有 broker 指標"
  ok=$((ok + 1))
else
  echo "FAIL C3 的 Prometheus 有 broker 指標"
fi

# 10. JMX exporter：7071 用 HTTPS 回 200，不加密的 HTTP 連不上（000）
for h in kc01 kb01 rest01 c3-01; do
  all=$((all + 1))
  https_url=https://$h.poc.lab:7071/metrics
  http_url=http://$h.poc.lab:7071/metrics

  if [ "$(curl -s --cacert $ca -o /dev/null -w '%{http_code}' --max-time 10 $https_url)" = 200 ] && \
     [ "$(curl -s --cacert $ca -o /dev/null -w '%{http_code}' --max-time 10 $http_url)" = 000 ]; then
    echo "ok   $h JMX exporter 7071 只走 HTTPS"
    ok=$((ok + 1))
  else
    echo "FAIL $h JMX exporter 7071 只走 HTTPS"
  fi
done

echo "健康：$ok / $all 項通過"
```

```out
ok   REST Proxy 經 LB 回 200（mTLS）
ok   Control Center 9021 回 200
ok   C3 的 Prometheus 有 broker 指標
ok   kc01 JMX exporter 7071 只走 HTTPS
（…）
ok   rest01 JMX exporter 7071 只走 HTTPS
ok   c3-01 JMX exporter 7071 只走 HTTPS
健康：22 / 22 項通過
```

## 19.2 安全：正向與反向

@role 小安 | ops02 | root

每一條規則都要有「該過的過、該擋的擋」。寫法和 19.1 相同；「被拒」的檢查，被拒才算通過。`all`、`ok` 跨塊延續，這一節的幾塊要在同一個 shell 接著貼。

先看 AD 身分（MDS 去 AD 驗帳密）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
ca=/etc/pki/ca-trust/source/anchors/bank-root.pem
password=$(cat ~/secrets/ad-test-users.pass)
ok=0
all=0

# 向 MDS 要 token 的網址
mds_url=https://kb01.poc.lab:8090/security/1.0/authenticate

# 1. 帳密正確：要 200
all=$((all + 1))

if [ "$(curl -s --cacert $ca -u "alice:$password" -o /dev/null -w '%{http_code}' $mds_url)" = 200 ]; then
  echo "ok   AD 帳密正確 → MDS 給 token"
  ok=$((ok + 1))
else
  echo "FAIL AD 帳密正確 → MDS 給 token"
fi

# 2. 密碼錯：要 401
all=$((all + 1))

if [ "$(curl -s --cacert $ca -u "alice:wrong-password" -o /dev/null -w '%{http_code}' $mds_url)" = 401 ]; then
  echo "ok   AD 密碼錯 → 401"
  ok=$((ok + 1))
else
  echo "FAIL AD 密碼錯 → 401"
fi

# 3. 帳號不存在：要 401
all=$((all + 1))

if [ "$(curl -s --cacert $ca -u "nobody:$password" -o /dev/null -w '%{http_code}' $mds_url)" = 401 ]; then
  echo "ok   不存在的帳號 → 401"
  ok=$((ok + 1))
else
  echo "FAIL 不存在的帳號 → 401"
fi
```

```out
ok   AD 帳密正確 → MDS 給 token
ok   AD 密碼錯 → 401
ok   不存在的帳號 → 401
```

Kafka 的授權：

```bash
# 4. carol 在自己 prefix 以外（payments.）建 topic，要被 Kafka 拒絕
#    連線設定借 alice 那一份，帳號換成 carol（測試帳號共用同一個密碼；暫存檔用完即刪）
all=$((all + 1))
conf=$(mktemp)
cat ~/conf/client-alice.properties 2> /dev/null | sed 's/username="alice"/username="carol"/' > $conf

if kafka-topics \
  --bootstrap-server kb01.poc.lab:9096 \
  --command-config $conf \
  --create \
  --topic payments.carol-test \
  --partitions 1 \
  --replication-factor 3 2>&1 | grep -q TopicAuthorizationException; then
  echo "ok   carol 在自己 prefix 以外建 topic 被拒"
  ok=$((ok + 1))
else
  echo "FAIL carol 在自己 prefix 以外建 topic 被拒"
fi

rm -f $conf

# 5. app-orders 讀 payments.events，要被拒絕
all=$((all + 1))

if kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9095 \
  --consumer.config ~/conf/app-orders.properties \
  --topic payments.events \
  --max-messages 1 \
  --timeout-ms 8000 2>&1 | grep -q TopicAuthorizationException; then
  echo "ok   app-orders 讀 payments.events 被拒"
  ok=$((ok + 1))
else
  echo "FAIL app-orders 讀 payments.events 被拒"
fi
```

```out
ok   carol 在自己 prefix 以外建 topic 被拒
ok   app-orders 讀 payments.events 被拒
```

連線方式：

```bash
# 6. 不帶 client 憑證連 REST Proxy：TLS 那一關就要失敗
all=$((all + 1))

if ! curl -s --cacert $ca --max-time 10 https://rest.poc.lab:8082/v3/clusters -o /dev/null; then
  echo "ok   REST Proxy 不帶憑證 → 連線被拒"
  ok=$((ok + 1))
else
  echo "FAIL REST Proxy 不帶憑證 → 連線被拒"
fi

# 7. 帶非 app 憑證（svc-ops）連 REST Proxy：要 401
all=$((all + 1))

if [ "$(curl -s --cacert $ca -o /dev/null -w '%{http_code}' --max-time 10 \
  --cert ~/pki/certs/svc-ops.crt \
  --key ~/pki/keys/svc-ops.key \
  https://rest.poc.lab:8082/v3/clusters)" = 401 ]; then
  echo "ok   REST Proxy 帶非 app 憑證（svc-ops）→ 401"
  ok=$((ok + 1))
else
  echo "FAIL REST Proxy 帶非 app 憑證（svc-ops）→ 401"
fi

# 8. 連 9095 只做 TLS、不做 SASL：要失敗（暫存設定檔用完即刪）
all=$((all + 1))
conf=$(mktemp)
echo "security.protocol=SSL" > $conf
echo "ssl.truststore.type=PKCS12" >> $conf
echo "ssl.truststore.location=/root/pki/certs/truststore.p12" >> $conf
echo "ssl.truststore.password=$(cat ~/pki/store.pass)" >> $conf

if ! kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $conf --list > /dev/null 2>&1; then
  echo "ok   CLIENT 9095 不帶 SASL → 失敗"
  ok=$((ok + 1))
else
  echo "FAIL CLIENT 9095 不帶 SASL → 失敗"
fi

rm -f $conf
```

```out
ok   REST Proxy 不帶憑證 → 連線被拒
ok   REST Proxy 帶非 app 憑證（svc-ops）→ 401
ok   CLIENT 9095 不帶 SASL → 失敗
```

不加密的 JMX 與憑證鏈驗證：

```bash
# 9. JMX exporter 不加密的 HTTP：要連不上（000）
all=$((all + 1))

url=http://kb01.poc.lab:7071/metrics

if [ "$(curl -s --cacert $ca -o /dev/null -w '%{http_code}' --max-time 10 $url)" = 000 ]; then
  echo "ok   JMX exporter 不加密的 HTTP → 連不上"
  ok=$((ok + 1))
else
  echo "FAIL JMX exporter 不加密的 HTTP → 連不上"
fi

# 10. 用一張無關的自簽 CA 去驗 MDS 的憑證：要失敗（代表 client 端的鏈驗證有效；暫存檔用完即刪）
all=$((all + 1))
junk=$(mktemp)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout /dev/null \
  -subj /CN=junk \
  -out $junk 2> /dev/null

if ! curl -s --max-time 10 --cacert $junk https://kb01.poc.lab:8090/v1/metadata/id -o /dev/null; then
  echo "ok   用無關的 CA 驗 MDS 憑證會被拒（鏈驗證生效）"
  ok=$((ok + 1))
else
  echo "FAIL 用無關的 CA 驗 MDS 憑證會被拒（鏈驗證生效）"
fi

rm -f $junk
```

```out
ok   JMX exporter 不加密的 HTTP → 連不上
ok   用無關的 CA 驗 MDS 憑證會被拒（鏈驗證生效）
```

機敏資料與檔案權限：

```bash
# 11. 3 台的設定檔裡沒有明文密碼（在那台執行 EOF 之前的那一段；最後一行的結果決定通過與否）
for h in kb01 rest01 c3-01; do
  all=$((all + 1))

  if ssh $h.poc.lab bash -s > /dev/null 2>&1 <<'EOF'; then
file=$(ls /etc/confluent/kafka/server.properties \
  /etc/confluent/kafka-rest/kafka-rest.properties \
  /etc/confluent/control-center/control-center.properties 2> /dev/null | head -1)
count=$(sudo awk '/^[^#].*(password|credentials|jaas.config)=[^$]/ {c++} END {print c + 0}' $file)
[ "$count" = 0 ]
EOF
    echo "ok   $h properties 沒有明文密碼"
    ok=$((ok + 1))
  else
    echo "FAIL $h properties 沒有明文密碼"
  fi
done

# 12. kb01 的 /etc/confluent、/etc/systemd/system 底下，只有 service.env 一個檔有 master key
all=$((all + 1))

if ssh kb01.poc.lab bash -s > /dev/null 2>&1 <<'EOF'; then
count=$(sudo grep -rl CONFLUENT_SECURITY_MASTER_KEY= /etc/confluent /etc/systemd/system 2> /dev/null | wc -l)
[ "$count" = 1 ]
EOF
  echo "ok   kb01 磁碟上的 master key 只有 service.env 一個"
  ok=$((ok + 1))
else
  echo "FAIL kb01 磁碟上的 master key 只有 service.env 一個"
fi

# 13. kb01 的 /etc/confluent/ssl 是 0750
all=$((all + 1))

if ssh kb01.poc.lab '[ "$(sudo stat -c %a /etc/confluent/ssl)" = 750 ]' > /dev/null 2>&1; then
  echo "ok   各主機 /etc/confluent/ssl 是 0750"
  ok=$((ok + 1))
else
  echo "FAIL 各主機 /etc/confluent/ssl 是 0750"
fi
```

```out
ok   kb01 properties 沒有明文密碼
ok   rest01 properties 沒有明文密碼
ok   c3-01 properties 沒有明文密碼
ok   kb01 磁碟上的 master key 只有 service.env 一個
ok   各主機 /etc/confluent/ssl 是 0750
```

憑證用途與 C3 登入，最後印這一組的統計：

```bash
# 14. cp-server 只有 serverAuth；拿它當 client 憑證連 C3 的 Prometheus 要被拒，svc-ops 則連得上
#     三件事都要對：passed 從 yes 開始，哪一件不對就改成 no
all=$((all + 1))
passed=yes
ready_url=https://c3-01.poc.lab:9090/-/ready
eku=$(openssl x509 -in ~/pki/certs/cp-server.crt -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' ')

if [ "$eku" != TLSWebServerAuthentication ]; then
  passed=no
fi

if ! curl -sf -m 15 --cacert $ca \
  --cert ~/pki/certs/svc-ops.crt \
  --key ~/pki/keys/svc-ops.key \
  $ready_url > /dev/null 2>&1; then
  passed=no
fi

if curl -sf -m 15 --cacert $ca \
  --cert ~/pki/certs/cp-server.crt \
  --key ~/pki/keys/cp-server.key \
  $ready_url > /dev/null 2>&1; then
  passed=no
fi

if [ "$passed" = yes ]; then
  echo "ok   cp-server 只有 serverAuth，拿它當 client 憑證連 C3 的 Prometheus 被拒（svc-ops 則能連）"
  ok=$((ok + 1))
else
  echo "FAIL cp-server 只有 serverAuth，拿它當 client 憑證連 C3 的 Prometheus 被拒（svc-ops 則能連）"
fi

# 15. alice 真的從 C3 登入（首頁不經過 MDS，只看 200 抓不到 C3 連不上 MDS 的問題）
all=$((all + 1))
c3_login_url=https://c3-01.poc.lab:9021/api/metadata/security/1.0/authenticate

if [ "$(curl -s -o /dev/null -m 30 -w '%{http_code}' -u "alice:$password" $c3_login_url)" = 200 ]; then
  echo "ok   alice 能從 C3 登入（C3 連得到 MDS）"
  ok=$((ok + 1))
else
  echo "FAIL alice 能從 C3 登入（C3 連得到 MDS）"
fi

unset password
echo "安全：$ok / $all 項通過"
```

```out
ok   cp-server 只有 serverAuth，拿它當 client 憑證連 C3 的 Prometheus 被拒（svc-ops 則能連）
ok   alice 能從 C3 登入（C3 連得到 MDS）
安全：17 / 17 項通過
```

> carol 的群組在第 16 章拿到 `orders.` prefix 的 DeveloperManage，所以她在自己的 prefix 裡是能建 topic 的；反向測試要用她沒有權限的 prefix。

## 19.3 應用程式端

@role 小安（扮演兩個應用程式） | ops02 | root

直連的 app-orders（SCRAM）寫一筆、讀回來；經 REST Proxy 的 app-legacy-billing（mTLS）寫一筆，再由 alice 讀出來確認真的進了 topic：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
ca=/etc/pki/ca-trust/source/anchors/bank-root.pem
cluster_id=$(curl -s --cacert $ca https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
message="acceptance-$(date +%s)"   # 這次驗收的訊息，讀回時用它找

# 1. app-orders（SCRAM 直連 9095）寫一筆
echo "$message" | kafka-console-producer \
  --bootstrap-server kb01.poc.lab:9095 \
  --producer.config ~/conf/app-orders.properties \
  --topic orders.events > /dev/null 2>&1
echo "app-orders SCRAM 直連寫入：ok"

# 2. app-orders 讀回自己寫的那筆（從頭讀，最多等 45 秒）
kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9095 \
  --consumer.config ~/conf/app-orders.properties \
  --topic orders.events \
  --group orders-acceptance \
  --from-beginning \
  --timeout-ms 45000 2> /dev/null | grep -c "$message" | sed 's/^/app-orders 讀回自己寫的：/'

# 3. app-legacy-billing 用自己的憑證經 LB + REST Proxy（mTLS）寫一筆到 billing.events，印 HTTP 狀態碼
body="{\"value\":{\"type\":\"JSON\",\"data\":\"$message-rest\"}}"
echo "app-legacy-billing 經 LB + REST Proxy（mTLS）寫入：HTTP $(curl -s --cacert $ca \
  --cert ~/pki/certs/app-legacy-billing.crt \
  --key ~/pki/keys/app-legacy-billing.key \
  -o /dev/null -w '%{http_code}' \
  -X POST \
  -H 'Content-Type: application/json' \
  -d "$body" \
  "https://rest.poc.lab:8082/v3/clusters/$cluster_id/topics/billing.events/records")"

# 4. alice 在 billing.events 讀到那一筆
kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9096 \
  --consumer.config ~/conf/client-alice.properties \
  --topic billing.events \
  --group billing-acceptance \
  --from-beginning \
  --timeout-ms 15000 2> /dev/null | grep -c "$message-rest" | sed 's/^/alice 在 billing.events 看到那筆：/'
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
# 1. bob 用選單重啟 kb03（不給選單 stdin，它不會停下來等輸入）
podman exec -i lab-ops02-1 bash /root/conf/opmenu-try.sh bob 21 kb03.poc.lab:confluent-server < /dev/null | tail -1

# 2. 在操作機執行 EOF 之前的那一段：等 kb03 的 MDS 回 200，再數 under-replicated partition
podman exec -i lab-ops02-1 bash -s <<'EOF'
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# kb03 的 MDS（8090）網址
mds_url=https://kb03.poc.lab:8090/v1/metadata/id

# 每 5 秒看一次，最多 24 次
for i in $(seq 1 24); do
  if [ "$(curl -s -o /dev/null -w "%{http_code}" $mds_url)" = 200 ]; then
    break
  fi

  sleep 5
done

under=$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --describe \
  --under-replicated-partitions 2> /dev/null | grep -c Partition:)
echo "kb03 MDS=$(curl -s -o /dev/null -w "%{http_code}" $mds_url) after ~$((i*5))s; under-replicated=$under"
EOF
```

```out
已重啟 kb03.poc.lab 的 confluent-server
kb03 MDS=200 after ~20s; under-replicated=0
```

@role Lab 管理員（扮演機房停電） | Windows 終端 | 本機

冷開機：全部主機同時關、同時開，看平台自己回來的順序與時間。lab 裡：用 `podman compose stop／start` 模擬停電。看什麼才算過：4 台 broker 的 MDS 都回 200、C3 回 200、REST 經 LB 回 200、broker 的重試次數是 0。C3 比 MDS 先起來時會等（第 13 章的 drop-in）。

@role Lab 管理員（扮演機房停電） | Windows 終端 | 本機

```bash
cd ~/kafka-lab

# 這一塊的檢查都是從操作機打一次，看 HTTP 狀態碼（連不上時是 000）

# 1. 全部停掉（模擬停電），再全部開起來：兩次都要數到 14
podman compose -f compose.yml stop 2>&1 | grep -c Stopped
t0=$(date +%s)
podman compose -f compose.yml start 2>&1 | grep -c Started

# 2. 等 4 台 broker 的 MDS 都回 200（不驗憑證）：每 10 秒看一次，最多 60 次
for i in $(seq 1 60); do
  ready=0

  for h in kb01 kb02 kb03 kb04; do
    url=https://$h.poc.lab:8090/v1/metadata/id

    if [ "$(podman exec lab-ops02-1 curl -sk -o /dev/null -w '%{http_code}' $url)" = 200 ]; then
      ready=$((ready + 1))
    fi
  done

  if [ $ready = 4 ]; then
    break
  fi

  sleep 10
done

echo "4 台 broker 的 MDS 都回 200：$(( $(date +%s) - t0 ))s"

# 3. 等 C3 回 200（不驗憑證）：每 10 秒看一次，最多 60 次
for i in $(seq 1 60); do
  if [ "$(podman exec lab-ops02-1 curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 10
done

echo "C3 回 200：$(( $(date +%s) - t0 ))s"

# 4. REST 經 LB（mTLS，驗銀行根憑證）
echo "REST 經 LB：$(podman exec lab-ops02-1 curl -s \
  --cacert /etc/pki/ca-trust/source/anchors/bank-root.pem \
  --cert /root/pki/certs/app-legacy-billing.crt \
  --key /root/pki/keys/app-legacy-billing.key \
  -o /dev/null -w '%{http_code}' \
  https://rest.poc.lab:8082/v3/clusters)"

# 5. kb01 的 confluent-server 這 10 分鐘內被 systemd 重試了幾次（要是 0）；在 kb01 執行 EOF 之前的那一段
podman exec -i lab-kb01-1 bash -s <<'EOF'
count=$(journalctl -u confluent-server --since "-10min" --no-pager | grep -c "Scheduled restart job")
echo "kb01 confluent-server 重試次數：$count"
EOF
```

```out
14
14
4 台 broker 的 MDS 都回 200：90s
C3 回 200：150s
REST 經 LB：200
kb01 confluent-server 重試次數：0
```

master key 落地在每台的 `service.env`，開機不連任何外部系統，所以重試次數是 0。C3 在第 13 章的 drop-in 加了「等 MDS」之後約 2–3 分鐘回來；沒加之前 lab 實測是 12 分鐘（C3 比 MDS 先起來會卡住不開 9021）。

操作機也重開了。`/secure/ssh` 的 volume 還在，金鑰不用重放；正式環境那個加密的 file system 要先解鎖、掛載好，ssh 才連得上各主機（沒掛載好時 ssh 找不到金鑰檔）。確認金鑰還在、連得上各主機：

@role 小安 | ops02 | root

```bash
mountpoint /secure/ssh
stat -c '%U:%G %a %n' /secure/ssh/cpuser_ed25519
ssh -o BatchMode=yes kb01.poc.lab hostname
```

```out
/secure/ssh is a mountpoint
root:root 400 /secure/ssh/cpuser_ed25519
kb01
```

## 19.5 收尾：安裝完成後要收的東西

**這一節在做什麼**：交付前清掉安裝期間的暫存與不再需要的權限，只留日後維運要用的。**提醒：`~/landing/rpm-target/` 與 `~/landing/bank/` 的 JDK 25 要保留到第 29 章（遷移）全部做完，不要先刪；細節見 29.1。**

@role 小安 | ops02 | root

| 留在操作機 | 收掉或交出去 |
|---|---|
| `~/conf/`（範本與產出的設定，之後改設定都從這裡）、`~/pki/`（憑證、CSR、keystore 密碼；含綁 SystemAdmin 的 `svc-ops.key`，和其他金鑰一樣只放這裡、0600）、`~/secrets/`（0600）、`~/monitoring/` | `~/landing/`、`~/repo/` 可以刪（套件已上架；要回滾用套件庫裡的舊版）。例外：還要照第 29 章遷移的話，`~/landing/rpm-target/` 與 `~/landing/bank/` 的 JDK 25 要留到遷移完成 |
| ssh 私鑰 `/secure/ssh/cpuser_ed25519`（root、0400）留在操作機的獨立 file system；不放 CyberArk、不備份，操作機重建就重新產生並重新佈署公鑰（第 4 章） | `/tmp/` 裡安裝期間的暫存檔 |
| | 各主機 cpuser 的全權 sudo（`/etc/sudoers.d/cpuser`）：移除，只留 `cpuser-ops` 窄規則（lab 留著，後面章節還要用） |
| | 平台的密碼與金鑰只留在操作機 root 才讀得到的位置：`~/secrets`（passphrase、master key、kafka-admin、應用程式 SCRAM、緊急憑證、confluent-audit 等，11.1、15.2、16.2、18.1）、`~/pki`、`/secure/ssh`；不放 CyberArk。操作機的備份交銀行的備份機制並加密（`/secure/ssh` 的私鑰依 第 4 章 不備份） |

```bash
# 1. 操作機 /tmp 裡安裝期間的暫存
rm -rf /tmp/jmx-* /tmp/*.properties

# 2. 還沒刪的落地區與上架目錄有多大
du -sh ~/landing ~/repo 2> /dev/null | tr '\n' ' '
echo

# 3. 各主機：/tmp 的殘留（JVM 自己的 hsperfdata、lib*.so 等不算）、sudoers.d 裡有哪些檔
for h in kc01 kb01 rest01 c3-01; do
  ssh $h.poc.lab bash -s <<'EOF'
leftover=$(ls /tmp | grep -cv '^hsperfdata\|^systemd-private\|^lib.*\.so\|^com_\|^\.')
sudoers=$(sudo ls /etc/sudoers.d | tr "\n" ",")
printf "%s: /tmp 殘留 %s 個；sudoers %s\n" $(hostname) $leftover "$sudoers"
EOF
done

# 4. 家目錄底下的金鑰與密碼檔都要是 0600（不是的會一個一個列出來）
find ~ -maxdepth 2 -type f \( -name '*.key' -o -name '*.pass' -o -name 'master.key' \) ! -perm 600 2> /dev/null \
  | sed 's/^/權限不是 0600：/'
echo "收尾檢查完成"
```

```out
6.9G	/root/landing 2.9G	/root/repo
kc01: /tmp 殘留 0 個；sudoers cpuser,cpuser-ops,
（4 行；JVM 自己的 lib*.so、hsperfdata 不算）
收尾檢查完成
```

交付清單裡還有兩個排程要先裝好：license 到期檢查（26.2）、每日中繼資料備份（23.2–23.4）。兩個都先放在操作機的 systemd timer；**待銀行確認**：行內若有排程系統（例如 Control-M），改由它在同樣的時間呼叫同一支腳本，操作機上的 timer 就不用裝。

> 正式環境交付時再做兩件 lab 不做的事：OS 團隊把各主機 `/etc/sudoers.d/cpuser`（全權）移除；`~/landing`、`~/repo` 依銀行留存政策處理（套件庫才是正本）。`svc-ops.key` 留在操作機的 `~/pki`（不移到離線保管，2026-10-31 定案）：誰在什麼時間進了操作機的 root，靠 PVWA 的登入紀錄與 PSMP 錄影追；它在叢集上做的事，Kafka 的稽核日誌記成 `User:svc-ops`。

# 20. 第二十站：密碼與金鑰輪替

**這一章在做什麼**：把平台上所有「會過期、會外洩、要定期換」的密碼與金鑰集中在一章：什麼時候換、誰換、怎麼換到不中斷。憑證另成一章（第 21 章）。每一節都是在 lab 實跑過的演練，正式環境依變更單執行。

## 20.1 總表：什麼、多久、誰做

| 項目 | 放在哪 | 多久換一次 | 誰做 | 怎麼換 |
|---|---|---|---|---|
| 緊急 SCRAM 帳號 `kafka-admin` 的密碼 | 操作機 `~/secrets/kafka-admin.pass` | 每次用過就換 | 平台工程師 | 20.2 |
| Secret Protection 的 master key（與 passphrase） | 操作機 `~/secrets`、各主機 `service.env` | 每年（待銀行確認，問題清單 8.6）；疑似外洩時 | 平台工程師 | 20.3 |
| AD 查詢帳號 `svc-mds-bind` 的密碼 | AD；密文在各主機 `security.properties` | 依銀行 AD 規範；換前一定要通知平台 | AD 團隊換、平台更新密文 | 20.4 |
| 操作機到各主機的 SSH 金鑰 | 操作機 `/secure/ssh` | 每年（待銀行確認，問題清單 4.6）；操作機重建 | 平台工程師＋OS 團隊 | 20.5 |
| 應用程式的 SCRAM 密碼 | 操作機產生、交應用程式團隊 | 依應用程式團隊 | 維運選單 35（A／B 兩個帳號，換閒置的那個） | 20.6 |
| 服務憑證（kafka-internal、cp-server…）與 client 憑證 | 操作機 `~/pki` | 一年（CA 簽發效期） | 平台工程師＋CA | 第 21 章 |
| MDS token 金鑰對 | 各主機 `mds-token-keypair.pem` | 不排輪替，只在外洩時換 | 平台工程師 | 不在本手冊（見設計紀錄） |

## 20.2 緊急帳號 kafka-admin 用過就換密碼

這一節演練「緊急帳號被人用過之後怎麼收拾」。`kafka-admin` 是 AD 或 MDS 不通時仍進得去的管理身分（CLIENT 9095，SCRAM；RBAC 綁 SystemAdmin，不是 super user）：SCRAM 憑據存在 KRaft 中繼資料、授權由 broker 本機的 binding 判斷，兩者都不經 MDS 的 REST 或 AD（11.2 驗證）。平常沒人用；一旦有人在緊急時從操作機取出來用過，這個密碼就算曝光了，**用完當天就要換**。由小安直接在操作機換，換完存回 `~/secrets/kafka-admin.pass`。平常沒有程式掛在這個帳號上，所以一個帳號直接換、不需要 A／B 兩組，也不會中斷任何服務（應用程式的 SCRAM 帳號才需要 A／B，見 OP menu 35）。

@role 小安 | ops02 | root

先模擬一次緊急使用：用 `~/secrets/kafka-admin.pass` 以 `kafka-admin` 從 9095 登入、列 topic（連線設定借 app-orders 那一份，帳密那一行換掉）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
tmp=$(mktemp -d)   # 暫存目錄：連線設定放這裡，最後刪掉
login_module=org.apache.kafka.common.security.scram.ScramLoginModule

# 1. 連線設定：app-orders 那一份，帳密換成 kafka-admin 目前的密碼
password=$(cat ~/secrets/kafka-admin.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $tmp/c.properties
echo "sasl.jaas.config=$login_module required username=\"kafka-admin\" password=\"$password\";" >> $tmp/c.properties
unset password

# 2. 從 9095 列 topic，看登不登得進
if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $tmp/c.properties --list > /dev/null 2>&1; then
  result=登入成功
else
  result=被拒
fi

echo "緊急使用（目前的密碼）：$result"

rm -rf $tmp
```

```out
緊急使用（目前的密碼）：登入成功
```

再換密碼：新密碼先寫暫存檔，叢集改成功才換掉 `~/secrets/kafka-admin.pass`。`kafka-configs` 出錯時會把整串設定（含密碼）印出來，所以它的輸出一律丟掉，結果用 `--describe` 和實際登入確認：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
BS=kb01.poc.lab:9094
tmp=$(mktemp -d)   # 暫存目錄：新舊密碼與連線設定都放這裡，最後刪掉
login_module=org.apache.kafka.common.security.scram.ScramLoginModule

# 1. 留一份舊密碼，產生新密碼（0600）
cp -p ~/secrets/kafka-admin.pass $tmp/old.pass
install -m 0600 /dev/null $tmp/new.pass
openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > $tmp/new.pass

# 2. 叢集改成功，才換掉 ~/secrets/kafka-admin.pass（kafka-configs 出錯會把密碼印出來，所以輸出全丟）
if kafka-configs \
  --bootstrap-server $BS \
  --command-config ~/conf/client-admin.properties \
  --alter --entity-type users --entity-name kafka-admin \
  --add-config "SCRAM-SHA-512=[iterations=8192,password=$(cat $tmp/new.pass)]" > /dev/null 2>&1; then
  install -m 0600 $tmp/new.pass ~/secrets/kafka-admin.pass
else
  echo "叢集改密碼失敗：~/secrets/kafka-admin.pass 沒有換"
  rm -rf $tmp
  false
fi

# 3. 確認 SCRAM 憑據還在
echo "kafka-admin: $(kafka-configs \
  --bootstrap-server $BS \
  --command-config ~/conf/client-admin.properties \
  --describe --entity-type users --entity-name kafka-admin 2> /dev/null | grep -o 'SCRAM-SHA-512=[^ ]*')"

# 4. 新密碼要登得進
password=$(cat ~/secrets/kafka-admin.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $tmp/c.properties
echo "sasl.jaas.config=$login_module required username=\"kafka-admin\" password=\"$password\";" >> $tmp/c.properties

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $tmp/c.properties --list > /dev/null 2>&1; then
  new_result=登入成功
else
  new_result=被拒
fi

# 5. 舊密碼要被拒
password=$(cat $tmp/old.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $tmp/c.properties
echo "sasl.jaas.config=$login_module required username=\"kafka-admin\" password=\"$password\";" >> $tmp/c.properties

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $tmp/c.properties --list > /dev/null 2>&1; then
  old_result=登入成功
else
  old_result=被拒
fi

unset password
echo "換完：新密碼 $new_result；舊密碼 $old_result"

rm -rf $tmp
```

```out
kafka-admin: SCRAM-SHA-512=iterations=8192
換完：新密碼 登入成功；舊密碼 被拒
```

> 新密碼會短暫出現在操作機的行程參數裡（`--add-config` 只吃命令列；`--add-config-file` 不接受 SCRAM 這個欄位）。能登入操作機的只有經 PSMP 進來的人員（root，全程錄影），可以接受。

> 誰在什麼時候用 `kafka-admin` 登入，Kafka 的稽核日誌（第 18 章）會記下 `User:kafka-admin` 做了什麼；誰在什麼時間進了操作機，看 CyberArk 的登入紀錄與 PSMP 錄影。兩邊對得上，才算這次緊急使用結案。

## 20.3 輪替 master key

@role 小安 | ops02 | root

先產生新 passphrase（舊的留著，`rotate` 要同時給舊的）：

```bash
install -m 0600 /dev/null ~/secrets/sp-passphrase-new.txt
openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > ~/secrets/sp-passphrase-new.txt

echo "new passphrase: $(wc -c < ~/secrets/sp-passphrase-new.txt) chars"
```

```out
new passphrase: 32 chars
```

@role 小安 | ops02 | root

小安手上還有舊 passphrase（`sp-passphrase.txt`），用 `rotate --master-key` 把 data key 重新包一次。密碼本身與 properties 都不動，只有 `security.properties` 和各主機的 `service.env` 要換：

```bash
# 1. 回滾用：留一份目前的密文檔與 master key（全部驗證完才刪）
cp -p ~/secrets/security.properties ~/secrets/security.properties.bak
cp -p ~/secrets/master.key ~/secrets/master.key.bak

# 2. rotate：給目前的 master key（環境變數）與舊 passphrase，換成新 passphrase 算出的新 master key（寫回 master.key）
export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)
confluent secret file rotate --master-key \
  --passphrase "$(cat ~/secrets/sp-passphrase.txt)" \
  --passphrase-new "$(cat ~/secrets/sp-passphrase-new.txt)" \
  --local-secrets-file ~/secrets/security.properties \
  -o yaml | awk '/master_key/{print $2}' > ~/secrets/master.key
unset CONFLUENT_SECURITY_MASTER_KEY

# CLI 重寫的 security.properties 也保持只有 root 讀得到
chmod 0600 ~/secrets/security.properties

# 3. master key 真的換了（和 .bak 的 sha256 不同）
if [ "$(sha256sum < ~/secrets/master.key)" = "$(sha256sum < ~/secrets/master.key.bak)" ]; then
  echo "master key changed: no（沒有換成功，不要派送）"
  false
else
  echo "master key changed: yes"
fi

# 4. passphrase：舊的另存 .prev，新的換成現行檔
cp -p ~/secrets/sp-passphrase.txt ~/secrets/sp-passphrase.prev.txt
mv ~/secrets/sp-passphrase-new.txt ~/secrets/sp-passphrase.txt

# 5. 派送密文檔與 service.env 到 10 台（service.env 在操作機上暫存 0600，派送完刪掉）
install -m 0600 /dev/null ~/secrets/service.env
echo "CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)" > ~/secrets/service.env

for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  scp -q ~/secrets/security.properties ~/secrets/service.env $h.poc.lab:/tmp/

  ssh $h.poc.lab bash -e -s <<'EOF'
sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties
sudo install -o root -g root -m 0600 /tmp/service.env /etc/confluent/service.env
rm -f /tmp/security.properties /tmp/service.env
EOF

  printf "%s " $h
done

rm -f ~/secrets/service.env
echo
```

```out
Save the master key. It cannot be retrieved later.
master key changed: yes
kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
```

（精簡的 OS 沒有 `cmp`，所以用 sha256sum 比對。）

上一步已經把舊 passphrase 另存 `.prev`、新的換成現行檔（舊 master key 在 `master.key.bak`，回滾要用）。記下新 master key 的雜湊和變更單號：

@role 小安 | ops02 | root

```bash
# 新 master key 的 sha256 前 12 碼，加上變更單號（檔案 0600）
fingerprint=$(tr -d '\n' < ~/secrets/master.key | sha256sum | cut -c1-12)
install -m 0600 /dev/null ~/secrets/master-key.custody
echo "$fingerprint CHG-yyyy" > ~/secrets/master-key.custody

cat ~/secrets/master-key.custody
```

```out
7d21e4… CHG-yyyy
```

@role 小安 | ops02 | root

然後照 15.5 再滾動重啟一次（指令相同），每台起得來就代表新 master key 解得開。先是 controller 和 broker：

```bash
# 1. controller：一台一台重啟，等到 active（在那台每 2 秒看一次，最多 30 次）
for h in kc01 kc02 kc03; do
  ssh $h.poc.lab bash -s <<'EOF'
sudo systemctl restart confluent-server

for i in $(seq 1 30); do
  if systemctl is-active -q confluent-server; then
    break
  fi

  sleep 2
done

echo "$(hostname) $(systemctl is-active confluent-server)"
EOF
done

# 2. broker：一台一台重啟，等 MDS（8090）回 200（每 5 秒看一次，最多 60 次）
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  for i in $(seq 1 60); do
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
```

再來是 C3，最後用 alice 確認 MDS 解得開 AD 查詢密碼；都起得來才刪回滾用的 `.bak`：

```bash
# 1. C3：重啟，等畫面回 200（每 5 秒看一次，最多 36 次）
ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'

for i in $(seq 1 36); do
  if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 5
done

echo "c3 ui=$(curl -sk -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"

# 2. alice 用 AD 帳密登入 MDS（MDS 要用新 master key 解出的 AD 查詢密碼）
password=$(cat ~/secrets/ad-test-users.pass)
echo "alice login after master key rotation: $(curl -sk -o /dev/null -w '%{http_code}' \
  -u "alice:$password" \
  https://kb01.poc.lab:8090/security/1.0/authenticate)"
unset password

# 3. 都起得來，回滾用的 .bak 才刪
rm -f ~/secrets/security.properties.bak ~/secrets/master.key.bak
```

```out
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
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
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

輪替完照 15.5 最後那個檢查再做一次：新的 passphrase（`sp-passphrase.txt` 現在是新的那一份）＋新的 master key 要能再輪替，下一次例行輪替才不會卡住：

```bash
# 在副本上試，正式的 security.properties 不動（暫存目錄用完即刪）
tmp=$(mktemp -d)
cp ~/secrets/security.properties $tmp/s
export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)

# 這次測試用的 passphrase（目前的、錯的、兩次測試各自的新值）
current_passphrase=$(cat ~/secrets/sp-passphrase.txt)
wrong_passphrase=wrong-$(openssl rand -hex 8)
new_passphrase_1=check-$(openssl rand -hex 8)
new_passphrase_2=check-$(openssl rand -hex 8)

# 1. 用目前的 passphrase 輪替：要成功（輸出裡有 Save the master key）
ok=$(confluent secret file rotate --master-key \
  --passphrase "$current_passphrase" \
  --passphrase-new "$new_passphrase_1" \
  --local-secrets-file $tmp/s \
  -o yaml 2>&1 < /dev/null | awk '/Save the master key/ {c++} END {print c + 0}')

# 2. 用錯的 passphrase 輪替：要被拒（輸出裡有 incorrect master key passphrase）
bad=$(confluent secret file rotate --master-key \
  --passphrase "$wrong_passphrase" \
  --passphrase-new "$new_passphrase_2" \
  --local-secrets-file $tmp/s \
  -o yaml 2>&1 < /dev/null | awk '/incorrect master key passphrase/ {c++} END {print c + 0}')

unset CONFLUENT_SECURITY_MASTER_KEY current_passphrase wrong_passphrase new_passphrase_1 new_passphrase_2
rm -rf $tmp

# 3. 結果：兩個都要是「是」
if [ "$ok" = 1 ]; then
  ok_text=是
else
  ok_text=否
fi

if [ "$bad" = 1 ]; then
  bad_text=是
else
  bad_text=否
fi

echo "目前的 passphrase 還能輪替：$ok_text；錯的 passphrase 被拒：$bad_text"
```

```out
目前的 passphrase 還能輪替：是；錯的 passphrase 被拒：是
```

> 回滾：在刪掉 `.bak` 之前，把 `security.properties.bak` 和 `master.key.bak` 用 15.4 的方式派送回去、再滾動重啟一次，就回到舊 master key。所以 `.bak` 要等全部驗證完才刪。

## 20.4 AD 查詢帳號的密碼換了

`svc-mds-bind` 的密碼加密後固定在 `security.properties`。AD 團隊一換 AD 的密碼，broker 手上就是舊的：當下靠群組快取撐著，下次重啟時 MDS 起不來（14.1 的陷阱：卡在 `Waiting for all of the authorizer futures`）。所以 AD 換完，平台要跟著做一次：拿到新密碼 → 只更新這一個欄位的密文 → 派送 `security.properties` → 滾動重啟。

> 換密碼是人手動做、沒有自動排程；一定要先通知平台。想要零空窗，可以開 A／B 兩組查詢帳號交替（AD 只換閒置的那組，平台切過去再滾動重啟）。手冊以「依變更單、單一帳號」為準。

@role 銀行 AD 團隊（換密碼；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

AD 團隊在 AD 改密碼，把新密碼交給小安（交付方式同 5.3，不放保管庫）。lab 用 samba-tool 改密碼：

```bash
# 在 ad01 執行 EOF 之前的那一段（bash -e：任何一行失敗就停）
podman exec -i lab-ad01-1 bash -e -s <<'EOF'
# 1. 新密碼：20 個英數字；大寫、小寫、數字至少各有一個才算合格（同 0.6），不合格就重產
while true; do
  p=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)

  upper=$(echo "$p" | tr -dc 'A-Z' | wc -c)
  lower=$(echo "$p" | tr -dc 'a-z' | wc -c)
  digit=$(echo "$p" | tr -dc '0-9' | wc -c)

  if [ "$upper" -gt 0 ] && [ "$lower" -gt 0 ] && [ "$digit" -gt 0 ]; then
    break
  fi
done

# 2. 改 AD 的密碼，新密碼存進 /root/secrets/bind.pass（交給平台用）
samba-tool user setpassword svc-mds-bind --newpassword="$p" > /dev/null
printf "%s" "$p" > /root/secrets/bind.pass
unset p

echo "AD: password changed"
EOF
```

```out
AD: password changed
```

@role 小安（收到新密碼；lab 由 Windows 終端代遞） | Windows 終端 | 本機

正式環境同 5.3 不顯示的寫法（檔名 `ldap-bind.pass`，舊的先另存 `ldap-bind.prev.pass`）。lab：

```bash
# 1. 操作機上舊的密碼另存 .prev
podman exec lab-ops02-1 cp -p /root/secrets/ldap-bind.pass /root/secrets/ldap-bind.prev.pass

# 2. ad01 上的新密碼直接送進操作機（0600），不經過任何中間資料夾
podman exec lab-ad01-1 cat /root/secrets/bind.pass \
  | podman exec -i lab-ops02-1 install -m 0600 /dev/stdin /root/secrets/ldap-bind.pass

podman exec lab-ops02-1 bash -c 'echo "ldap-bind.pass: $(wc -c < /root/secrets/ldap-bind.pass) chars"'
```

```out
ldap-bind.pass: 20 chars
```

@role 小安 | ops02 | root

不用重做 15.3：`confluent secret file update` 只重算指定欄位的密文，properties 本身不動（裡面本來就是 `${securepass:…}` 參照）。**密文的 key 是「加密時的檔名／欄位」**（`${securepass:…:kb01.server.properties/ldap…}` 的最後一段），`update` 也用 `--config-file` 的檔名當 key：檔名對不上就會**多出 7 行新密文、舊的 7 行原封不動**，broker 讀到的還是舊密碼——當下沒事（群組快取撐著），下一次重啟 MDS 就卡在 `Waiting for all of the authorizer futures`（2026-10-29 lab 真的踩到：腳本版第 15 站用 `kb01.properties` 加密、手動 20.4 用 `kb01.server.properties` 更新）。所以先從每台設定檔的參照讀出 key 名，再用那個檔名更新；controller 和 broker 共 7 個檔有這個欄位，所以 `security.properties` 剛好變 7 行、總行數不變：

```bash
cd ~/conf

# 1. 回滾用：留一份目前的密文檔（全部驗證完才刪）
cp -p ~/secrets/security.properties ~/secrets/security.properties.bak

export CONFLUENT_SECURITY_MASTER_KEY=$(cat ~/secrets/master.key)
new_password=$(cat ~/secrets/ldap-bind.pass)
tmp=$(mktemp -d)
failed=no

for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  # 2. 這台設定檔的參照用的 key 名（${securepass:…security.properties:<key 名>/欄位} 裡的 <key 名>），例 kb01.server.properties
  key=$(ssh $h.poc.lab \
    "sudo grep -o 'security.properties:[^/]*' /etc/confluent/kafka/server.properties | head -1 | cut -d: -f2")

  # 3. 用同名的檔案，只更新 AD 查詢密碼這一個欄位的密文
  cp $h.server.properties $tmp/$key

  if confluent secret file update \
    --config-file $tmp/$key \
    --local-secrets-file ~/secrets/security.properties \
    --remote-secrets-file /etc/confluent/secrets/security.properties \
    --config "ldap.java.naming.security.credentials=$new_password" > /dev/null; then
    echo "$h: key=$key"
  else
    echo "$h: update FAILED"
    failed=yes
  fi
done

rm -rf $tmp
unset CONFLUENT_SECURITY_MASTER_KEY new_password
chmod 0600 ~/secrets/security.properties

# 4. 確認：改到的行數（要是 7，全部是 ldap 的密碼），總行數不變
changed=$(grep -vxFf ~/secrets/security.properties.bak ~/secrets/security.properties)
changed_count=$(echo "$changed" | grep -c .)
ldap_count=$(echo "$changed" | grep -c 'ldap.java.naming.security.credentials')
before=$(grep -c . ~/secrets/security.properties.bak)
after=$(grep -c . ~/secrets/security.properties)
echo "changed lines: $changed_count, of which ldap credentials: $ldap_count；總行數 $before → $after（要相同）"

if [ $failed = yes ]; then
  echo "有主機更新失敗：先不要派送，查原因（回滾用 security.properties.bak）"
  false
fi
```

```out
kc01: key=kc01.server.properties
（7 行）
changed lines: 7, of which ldap credentials: 7；總行數 170 → 170（要相同）
```

> 新密碼會短暫出現在這台操作機的行程參數裡（`--config` 只吃命令列）。能登入操作機的只有經 PSMP 進來的人員（root，全程錄影），可以接受；介意的話就改走 15.3 整批重新加密。

`security.properties` 每台都是同一份，所以 10 台都派送（REST、C3 那幾行沒變，不用重啟）；只滾動重啟 controller 和 broker：

```bash
# 1. 密文檔派送到 10 台
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  scp -q ~/secrets/security.properties $h.poc.lab:/tmp/
  ssh $h.poc.lab \
    'sudo install -o root -g confluent -m 0640 /tmp/security.properties /etc/confluent/secrets/security.properties'
  ssh $h.poc.lab 'rm -f /tmp/security.properties'
done

# 2. controller：一台一台重啟，等到 active（在那台每 2 秒看一次，最多 30 次）
for h in kc01 kc02 kc03; do
  ssh $h.poc.lab bash -s <<'EOF'
sudo systemctl restart confluent-server

for i in $(seq 1 30); do
  if systemctl is-active -q confluent-server; then
    break
  fi

  sleep 2
done

echo "$(hostname) $(systemctl is-active confluent-server)"
EOF
done

# 3. broker：一台一台重啟，等 MDS（8090）回 200（每 5 秒看一次，最多 60 次）
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  for i in $(seq 1 60); do
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done
```

```out
kc01 active
（3 行）
kb01 MDS=200
（4 行）
```

再用 alice 的 AD 帳密登入 MDS 證明 bind 成功（MDS 要先用查詢帳號到 AD 找到 alice，才能驗她的密碼）；都正常才刪回滾用的 `.bak`：

```bash
# 1. alice 用 AD 帳密登入 MDS（MDS 先用新的查詢密碼到 AD 找到 alice，才能驗她的密碼）
password=$(cat ~/secrets/ad-test-users.pass)
echo "換密碼後 alice 登入 MDS：$(curl -sk -o /dev/null -w '%{http_code}' \
  -u "alice:$password" \
  https://kb01.poc.lab:8090/security/1.0/authenticate)"
unset password

# 2. kb01：這次啟動以來沒有 LDAP 錯誤；設定檔裡 bind 的欄位仍是密文參照（在 kb01 執行 EOF 之前的那一段）
ssh kb01.poc.lab bash -s <<'EOF'
since=$(systemctl show -p ActiveEnterTimestamp --value confluent-server)
errors=$(sudo journalctl -u confluent-server --since "$since" --no-pager 2> /dev/null \
  | grep -ci "javax.naming\|LDAP search failed")
echo "kb01 ldap auth errors since restart: $errors"

refs=$(sudo grep -c '^ldap.java.naming.security.credentials *= *\${securepass:' /etc/confluent/kafka/server.properties)
echo "kb01 bind 欄位仍是密文參照：$refs"
EOF

# 3. 都正常，回滾用的 .bak 才刪
rm -f ~/secrets/security.properties.bak
```

```out
換密碼後 alice 登入 MDS：200
kb01 ldap auth errors since restart: 0
kb01 bind 欄位仍是密文參照：1
```

> 回滾（換錯、AD 被改回舊密碼）：刪 `.bak` 之前，把 `security.properties.bak` 派送回 10 台、再滾動重啟 controller 和 broker。
>
> AD 換密碼之後平台要做「更新密文 → 派送 → 滾動重啟」，所以不能悄悄換，一定要通知平台。

## 20.5 換 SSH 金鑰（人工、不中斷）

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

**誠實的限制**：步驟 4 要換私鑰和 `.pub` 兩個檔，換完之前有一個極短的空窗（lab 實測約為微秒級）：剛好在這一瞬間開始的 ssh 連線，會因為私鑰與 `.pub` 不成對而失敗一次。所以步驟 4 請在**沒有其他連線作業**時進行，動作要快（兩個 `mv` 寫在同一塊、一前一後緊接著，整塊一起貼上）。下面的演練用一個每 0.2 秒連一次 kb01 的探針量：整個換金鑰過程最多失敗 1 次（換私鑰的瞬間），其他時間 0 次。

> 新增公鑰時，`from=` 要和原本的公鑰行一致。實際執行前，先在一台非正式主機演練。換金鑰期間不要同時做安裝或升級。

@role 小安 | ops02 | root

先開探針（背景每 0.2 秒連一次 kb01，記連線數與失敗數）：

```bash
# 1. 探針程式：每 0.2 秒 ssh 到 kb01 一次，直到 /tmp/probe.stop 出現；最後把「連線次數 失敗次數」寫進 /tmp/probe.result
cat > /tmp/probe.sh <<'EOF'
n=0
f=0

while [ ! -f /tmp/probe.stop ]; do
  n=$((n + 1))

  if ! ssh -o BatchMode=yes -o ConnectTimeout=3 kb01.poc.lab true 2> /dev/null; then
    f=$((f + 1))
  fi

  sleep 0.2
done

echo "$n $f" > /tmp/probe.result
EOF

# 2. 清掉上一次的，放到背景跑
rm -f /tmp/probe.stop /tmp/probe.result
bash /tmp/probe.sh < /dev/null > /dev/null 2>&1 &
sleep 1
echo "探針已開始"
```

```out
探針已開始
```

步驟 1–3：產生新金鑰對（註解多加時分，因為演練可能和安裝同一天，要分得出新舊）；從操作機自己的 `authorized_keys` 取出現在的 `from=`，把新公鑰行加進每一台（用舊金鑰登入）和 repo01 的 repodeploy；用新金鑰逐台測試（`-F /dev/null` 不讀 ssh config，不然 config 裡的舊金鑰會讓測試假通過）：

```bash
cd /secure/ssh

# 要換的 12 個登入對象：每台的 cpuser，加上 repo01 的 repodeploy
targets="cpuser@ops02"
targets="$targets cpuser@kc01 cpuser@kc02 cpuser@kc03"
targets="$targets cpuser@kb01 cpuser@kb02 cpuser@kb03 cpuser@kb04"
targets="$targets cpuser@rest01 cpuser@rest02 cpuser@c3-01 repodeploy@repo01"
old_comment=$(awk '{print $3}' cpuser_ed25519.pub)

# 1. 新金鑰對（註解帶日期與時分）
ssh-keygen -q -t ed25519 -N '' -C "cpuser-ops-$(date +%Y%m%d-%H%M)" -f cpuser_ed25519.new
chmod 0400 cpuser_ed25519.new

# 2. 新公鑰行：from= 照操作機自己 authorized_keys 裡的那一段；用舊金鑰登入，加到每一台的最後面（舊的保留）
from=$(grep -o '^from="[^"]*"' /home/cpuser/.ssh/authorized_keys | head -1)
new_line="$from $(cat cpuser_ed25519.new.pub)"

for t in $targets; do
  if ! echo "$new_line" | ssh $t.poc.lab 'cat >> ~/.ssh/authorized_keys'; then
    echo "$t: 加新公鑰失敗"
  fi
done

# 3. 用新金鑰逐台試登入（-F /dev/null：不讀 ssh config，不然 config 裡的舊金鑰會讓測試假通過）
ok=0
for t in $targets; do
  if ssh -F /dev/null -i cpuser_ed25519.new \
    -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    $t.poc.lab true 2> /dev/null; then
    ok=$((ok + 1))
  fi
done

echo "舊：$old_comment；新：$(awk '{print $3}' cpuser_ed25519.new.pub)；新金鑰登入：$ok/12 台"
```

```out
舊：cpuser-ops-20261027；新：cpuser-ops-20261028-0930；新金鑰登入：12/12 台
```

步驟 4：換私鑰。先備份舊的（`.old`，步驟 5 才刪），再成對換成新的，兩個 `mv` 連在一起：

```bash
cd /secure/ssh

# 1. 舊的先備份成 .old（步驟 5 才刪）
cp -p cpuser_ed25519 cpuser_ed25519.old
cp -p cpuser_ed25519.pub cpuser_ed25519.old.pub

# 2. 私鑰與公鑰檔成對換成新的（兩個 mv 緊接著）
mv -f cpuser_ed25519.new cpuser_ed25519
mv -f cpuser_ed25519.new.pub cpuser_ed25519.pub

stat -c '%a %n' cpuser_ed25519*
```

```out
400 cpuser_ed25519
400 cpuser_ed25519.old
644 cpuser_ed25519.old.pub
644 cpuser_ed25519.pub
```

步驟 5：用新金鑰把各主機上的舊公鑰行刪掉（依註解，整行比對到結尾），確認舊金鑰被拒、每台只剩一行金鑰，最後刪掉操作機上的舊私鑰：

```bash
cd /secure/ssh

targets="cpuser@ops02"
targets="$targets cpuser@kc01 cpuser@kc02 cpuser@kc03"
targets="$targets cpuser@kb01 cpuser@kb02 cpuser@kb03 cpuser@kb04"
targets="$targets cpuser@rest01 cpuser@rest02 cpuser@c3-01 repodeploy@repo01"
old_comment=$(awk '{print $3}' cpuser_ed25519.old.pub)

# 1. 用新金鑰登入每一台，刪掉舊公鑰那一行（以註解比對到行尾）
for t in $targets; do
  if ! ssh $t.poc.lab "sed -i '/ $old_comment\$/d' ~/.ssh/authorized_keys"; then
    echo "$t: 刪舊公鑰失敗"
  fi
done

# 2. 舊金鑰要被拒
refused=$(ssh -F /dev/null -i cpuser_ed25519.old -o IdentitiesOnly=yes -o BatchMode=yes \
  cpuser@kb01.poc.lab true 2>&1 | grep -c 'Permission denied')

# 3. 每台剩幾行金鑰（統計成「台數 行數」，要是 12 1）
rm -f /tmp/key-lines.txt
for t in $targets; do
  ssh $t.poc.lab 'grep -c ssh-ed25519 ~/.ssh/authorized_keys' >> /tmp/key-lines.txt
done
lines=$(sort /tmp/key-lines.txt | uniq -c | sed 's/^ *//')
rm -f /tmp/key-lines.txt

# 4. 刪掉操作機上的舊私鑰
rm -f cpuser_ed25519.old cpuser_ed25519.old.pub

echo "舊金鑰被拒：$refused；每台金鑰行數（台數 行數）：$lines；/secure/ssh：$(ls | paste -sd' ')"
```

```out
舊金鑰被拒：1；每台金鑰行數（台數 行數）：12 1；/secure/ssh：cpuser_ed25519 cpuser_ed25519.pub
```

停探針，看整個過程有沒有連線失敗：

```bash
# 叫探針停下，等它寫出結果（「連線次數 失敗次數」）
touch /tmp/probe.stop
sleep 3
read n f < /tmp/probe.result

echo "探針：換金鑰全程連線 $n 次，失敗 $f 次（0 次，或 1 次且發生在步驟 4 換私鑰的瞬間）"
```

```out
探針：換金鑰全程連線 … 次，失敗 0 次（0 次，或 1 次且發生在步驟 4 換私鑰的瞬間）
```

> 這是「換金鑰」，不是「操作機重建」。操作機重建時舊私鑰不在（沒有備份），要重做 4.2–4.3：產生新金鑰對、OS 團隊重新佈署公鑰。
>
> 待銀行確認：換金鑰的週期（例如每年）與由誰執行（問題清單 4.6）。

## 20.6 應用程式的 SCRAM 密碼：A／B 兩個帳號輪替，不中斷

下面這張圖把 A／B 輪替的四個時間點畫出來：換的永遠是閒置的那一個。

![scramab]

**這一節在做什麼**：每個直連 Kafka 的應用程式有 `<app>-a`、`<app>-b` 兩個同權限的帳號（第 11 章建的）。換密碼時只換應用程式**沒在用**的那一個，應用程式再改設定切過去；寫入從頭到尾不中斷。前提：第 11 章的兩個帳號都在、`~/conf/app-orders.properties`（扮演應用程式）用的是 -a。完成的樣子：-b 的新密碼能登入、舊密碼被拒、-a 的背景寫入 0 錯誤、切到 -b 後能寫讀。正式環境由維運人員用 OP menu 35 做（16.5 有一次），這一節是它背後的手動步驟。

@role 小安 | ops02 | root

先看現況：應用程式用 -a，兩個帳號都登得進去。再讓 -a 在背景持續寫入（每秒 5 筆、600 筆，代表正在跑的應用程式）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

login_module=org.apache.kafka.common.security.scram.ScramLoginModule
conf=$(mktemp)   # 連線設定借 app-orders 那一份，帳密那一行換掉（暫存檔用完即刪）

# 1. 現況：應用程式用哪個帳號
using=$(grep -o 'username="[^"]*"' ~/conf/app-orders.properties)

# 2. -a 登得進嗎：用這組帳密從 9095 列 topic
password=$(cat ~/secrets/app-orders-a.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $conf
echo "sasl.jaas.config=$login_module required username=\"app-orders-a\" password=\"$password\";" >> $conf

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $conf --list > /dev/null 2>&1; then
  a_result=成功
else
  a_result=被拒
fi

# 3. -b 登得進嗎：同上
password=$(cat ~/secrets/app-orders-b.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $conf
echo "sasl.jaas.config=$login_module required username=\"app-orders-b\" password=\"$password\";" >> $conf

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $conf --list > /dev/null 2>&1; then
  b_result=成功
else
  b_result=被拒
fi

unset password
rm -f $conf
echo "應用程式用 $using；-a 登入：$a_result；-b 登入：$b_result"

# 4. 背景用 -a 持續寫入（每秒 5 筆、共 600 筆），代表正在跑的應用程式
nohup kafka-producer-perf-test \
  --topic orders.events \
  --num-records 600 --throughput 5 --record-size 100 \
  --producer.config ~/conf/app-orders.properties \
  --producer-props bootstrap.servers=kb01.poc.lab:9095 acks=all > /tmp/ab-load.log 2>&1 &
sleep 5
echo "背景寫入已開始（-a）"
```

```out
應用程式用 username="app-orders-a"；-a 登入：成功；-b 登入：成功
背景寫入已開始（-a）
```

換閒置的 -b：新密碼先寫暫存檔，叢集改成功才換掉 `~/secrets/app-orders-b.pass`；接著驗三件事：-b 新密碼登得進、舊密碼被拒、-a 完全不受影響：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
login_module=org.apache.kafka.common.security.scram.ScramLoginModule

# 1. 舊密碼留一份、產生新密碼（放在暫存目錄，0600）
tmp=$(mktemp -d)
cp -p ~/secrets/app-orders-b.pass $tmp/old.pass
install -m 0600 /dev/null $tmp/new.pass
openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > $tmp/new.pass

# 2. 叢集改成功，才換掉 ~/secrets/app-orders-b.pass（kafka-configs 出錯會把密碼印出來，所以輸出全丟）
if kafka-configs \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --alter --entity-type users --entity-name app-orders-b \
  --add-config "SCRAM-SHA-512=[iterations=8192,password=$(cat $tmp/new.pass)]" > /dev/null 2>&1; then
  install -m 0600 $tmp/new.pass ~/secrets/app-orders-b.pass
else
  echo "叢集改密碼失敗：~/secrets/app-orders-b.pass 沒有換"
  rm -rf $tmp
  false
fi

# 3. 驗第一件：-b 新密碼登得進（連線設定借 app-orders 那一份，帳密那一行換掉）
password=$(cat ~/secrets/app-orders-b.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $tmp/c.properties
echo "sasl.jaas.config=$login_module required username=\"app-orders-b\" password=\"$password\";" >> $tmp/c.properties

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $tmp/c.properties --list > /dev/null 2>&1; then
  new_result=成功
else
  new_result=被拒
fi

# 4. 驗第二件：-b 舊密碼被拒
password=$(cat $tmp/old.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $tmp/c.properties
echo "sasl.jaas.config=$login_module required username=\"app-orders-b\" password=\"$password\";" >> $tmp/c.properties

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $tmp/c.properties --list > /dev/null 2>&1; then
  old_result=成功
else
  old_result=被拒
fi

# 5. 驗第三件：-a 不受影響
password=$(cat ~/secrets/app-orders-a.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $tmp/c.properties
echo "sasl.jaas.config=$login_module required username=\"app-orders-a\" password=\"$password\";" >> $tmp/c.properties

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $tmp/c.properties --list > /dev/null 2>&1; then
  a_result=成功
else
  a_result=被拒
fi

unset password
echo "換完 -b：新密碼 $new_result；舊密碼 $old_result；-a 仍 $a_result"

rm -rf $tmp
```

```out
換完 -b：新密碼 成功；舊密碼 被拒；-a 仍 成功
```

> 新密碼交給應用程式團隊的方式和 11.1 一樣（不經平台保管庫）；用 OP menu 35 做的話，新密碼寫在操作者的交接檔。

應用程式切到 -b：正式環境是應用程式改設定、滾動重啟（新連線用 -b，舊連線自然收掉）。lab 等背景寫入跑完、看 -a 這段 0 錯誤，再把 `app-orders.properties` 改成 -b，寫一筆、讀回一筆：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 等背景寫入跑完（每 5 秒看一次，最多 60 次）；-a 這段的筆數與錯誤數
for i in $(seq 1 60); do
  if ! pgrep -f ProducerPerformance > /dev/null; then
    break
  fi

  sleep 5
done

sent=$(tail -1 /tmp/ab-load.log | grep -o '[0-9]* records sent')
errors=$(awk 'tolower($0) ~ /error|exception/ {c++} END {print c + 0}' /tmp/ab-load.log)
echo "-a 的流量：$sent，錯誤 $errors 筆"

# 2. 應用程式改用 -b：連線設定照第 11 章重寫一次，帳號與密碼換成 -b（檔案本來就是 0600）
password=$(cat ~/secrets/app-orders-b.pass)
store_password=$(cat ~/pki/store.pass)

cat > ~/conf/app-orders.properties <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-orders-b" password="$password";
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
ssl.truststore.password=$store_password
EOF
unset password store_password

# 3. 用 -b 寫一筆、讀回來
message="switch-$(date +%s)"
echo "$message" | kafka-console-producer \
  --bootstrap-server kb01.poc.lab:9095 \
  --producer.config ~/conf/app-orders.properties \
  --topic orders.events > /dev/null 2>&1

group=orders-ab-$(date +%s)
read_back=$(kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9095 \
  --consumer.config ~/conf/app-orders.properties \
  --topic orders.events \
  --group $group \
  --from-beginning --max-messages 5000 --timeout-ms 30000 2> /dev/null | grep -c "^$message$")
echo "切到 -b 後寫一筆：ok；讀回：$read_back"

echo "現在應用程式用 $(grep -o 'username="[^"]*"' ~/conf/app-orders.properties)；下次輪替換 -a"
```

```out
-a 的流量：600 records sent，錯誤 0 筆
切到 -b 後寫一筆：ok；讀回：1
現在應用程式用 username="app-orders-b"；下次輪替換 -a
```

> 下一次輪替就是同樣三步倒過來：換 -a 的密碼 → 應用程式切回 -a。兩個帳號的權限（第 11 章的 binding、配額）一模一樣，應用程式只改帳密。只有一個帳號的舊應用程式（例如沿用單一帳號的系統）換密碼一定會中斷，要先用 OP menu 34 建一對再遷移；走 REST Proxy 的應用程式用的是憑證，不在這一節（第 21 章）。

# 21. 第二十一站：憑證輪替

![certrotate]

**怎麼用這一章**：先讀 21.0，判斷銀行說的「換憑證」是下表哪一種，再跳到對應的節。只是到期前換發就做 21.1 → 21.2；銀行換 CA 才需要 21.3 或 21.4。每一次換發都要**滾動重啟**所有元件（含 REST Proxy 的 LB 停用／恢復），請在變更時段做，一台健康了才做下一台。

第 9 章簽的憑證效期一年，到期前一定要換。這一章做兩件事：每年都會遇到的 **leaf 換發**（同一個銀行 CA 重簽），以及幾年一次、銀行決定的 **換 CA**（三階段：先加新根 → 換 leaf → 移除舊根）。MDS token 金鑰不是銀行 CA 簽的、沒有到期日，不在這一章（只在外洩時才換）。

| 情境 | 多久一次 | 會不會斷線 |
|---|---|---|
| leaf 換發 | 每年，到期前一個月內 | 不會：truststore 只信根憑證，新舊 leaf 在滾動期間都被信任 |
| 換 CA | 銀行決定（幾年一次） | 不會：三階段的每一段，所有元件都同時信任新舊兩個根 |

做法的原則：
- **每次換發都產生新私鑰**，不重用舊的 CSR。
- 檔名、路徑、keystore 密碼都和原本一樣，所以 properties 一個字都不用改（Secret Protection 的密文也不用重算）。
- 新的東西先放在 `~/pki/next/`，派送完、驗證過，才換成 `~/pki/` 的正本；舊的留在 `~/pki/old-<日期>/`。
- **遷移前後都適用**：這一章在安裝基底（JDK 21）和遷移之後（JDK 25）指令完全一樣。服務信任的是自己的 `truststore.p12`，不碰 JDK 的 `cacerts`，所以換 JDK 不影響信任；`keytool` 一律走 `/opt/java/current`。lab 的順序是基底驗收完先換一次 leaf（第 29 章之前），遷移完成後的驗收會再證明新版與新 JDK 照樣接受這些憑證。

## 21.0 銀行說要換憑證時，先判斷是哪一種

銀行說「要換根」或「要換中繼」時，先問清楚三件事：**換的是哪一層**、**那一層的私鑰有沒有換**、**舊的什麼時候到期**。驗證憑證時看的是「上一層的名稱和公鑰」，不是上一層那張憑證本身，所以私鑰沒換的那一層，下面的憑證都還驗得過；工作量差很多：

| 根 | 中繼 | 我方的 leaf（server／client） | p12 裡夾帶的中繼（憑證鏈） | 信任清單 | 走哪一節 |
|---|---|---|---|---|---|
| 不動 | 不動 | 到期前換發 | 不動 | 不動 | 21.2 |
| 同私鑰續簽 | 不動 | 不動 | 不動 | 加入新根，舊的到期後再移除 | 只做 21.3 的信任清單那幾步（加入、移除） |
| 不動 | 同私鑰續簽 | 不動 | **換成新中繼** | 不動 | 21.4 的換鏈（21.4.3、21.4.4；不用 CSR） |
| 不動 | 換私鑰 | **重簽** | 重簽時一起換（銀行回覆就是新 leaf＋新中繼） | 不動 | 21.2（銀行用新中繼簽） |
| 同私鑰續簽 | 同私鑰續簽 | 不動 | **換成新中繼** | 加入新根，舊的到期後再移除 | 信任清單加入新根，再做 21.4 的換鏈 |
| 同私鑰續簽 | 換私鑰 | **重簽** | 重簽時一起換 | 加入新根，舊的到期後再移除 | 信任清單加入新根，再做 21.2 |
| 換私鑰 | 同私鑰，由新根重簽 | 不動 | **換成新中繼** | **三階段** | 21.4（三階段，階段二是換鏈；lab 實跑） |
| 換私鑰 | 換私鑰 | **重簽** | 重簽時一起換 | **三階段** | 21.3（lab 實跑） |

「重簽」和「換鏈」的差別：中繼換了私鑰，leaf 一定要重簽，銀行回覆的 PEM 本來就是新 leaf＋新中繼，做 keystore 時一起包進去，不用另外換鏈；只有中繼**沒換私鑰**、leaf 不重簽時，才需要單獨把新中繼重包進 p12（21.4）。根「同私鑰續簽」的兩列，舊根和新根的名稱與公鑰都相同，舊鏈新鏈都驗得過，信任清單加入新根只是為了舊根到期之後還有一張有效的根。

我方的信任清單只放根憑證、不放中繼，所以只要根沒換私鑰，信任清單都不用動；換鏈的過程中，出示舊鏈和新鏈的主機可以並存。只有把中繼本身放進信任清單的應用程式，才要新舊中繼並存。

比對「名稱與私鑰有沒有換」：拿銀行給的新舊兩張（根或中繼）各算一次公鑰雜湊與名稱，名稱相同、雜湊相同就是續簽：

```
for f in old-ca.pem new-ca.pem; do
  ca_name=$(openssl x509 -in $f -noout -subject -nameopt compat | sed 's/subject=//')
  ca_key=$(openssl x509 -in $f -noout -pubkey | sha256sum | cut -c1-12)
  ca_end=$(openssl x509 -in $f -noout -enddate | cut -d= -f2)
  echo "$f: $ca_name  key=$ca_key  到期 $ca_end"
done
```

> 實測（2026-10-24，openssl，用 lab 的模擬 CA）：同私鑰續簽的根、同私鑰續簽的中繼、兩者同時，舊 leaf 全部驗得過；根換私鑰而中繼沿用私鑰、由新根重簽時，舊 leaf 配新中繼驗得過新根，但**還沒換鏈的主機（舊 leaf 配舊中繼）在只信新根之後就驗不過**，所以三階段的「拿掉舊根」一定排在每個端點都換好鏈之後。Java 的驗證原理相同，沒有另外實測。

## 21.1 現在用的是哪一張

@role 小安 | ops02 | root

**這一節在做什麼**：換發前後各跑一次的對照。先看每張憑證的序號、剩幾天，以及各服務**實際出示**的是哪一張（換完之後用同一條指令確認每個端點都換到了）：

```bash
cd ~/pki

# 1. 操作機上每張憑證的序號（末 8 碼）、還剩幾天
for name in $(awk '{print $1}' requests.txt); do
  serial=$(openssl x509 -in certs/$name.crt -noout -serial | cut -d= -f2 | tail -c 9)
  end=$(openssl x509 -in certs/$name.crt -noout -enddate | cut -d= -f2)
  days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
  printf '%-19s serial=%s days=%s\n' $name "$serial" "$days"
done

# 2. 各端點實際出示的是哪一張，印「序號末 8 碼 CN」（連不上就印空的）
#    例：kb01.poc.lab:9095 → F343BC54 cp-server
echo "-- 各端點出示的憑證（序號末 8 碼）"

endpoints="kc01.poc.lab:9093 kb01.poc.lab:9092 kb01.poc.lab:9095 kb01.poc.lab:8090 kb01.poc.lab:7071 kc01.poc.lab:7071"
endpoints="$endpoints rest01.poc.lab:8082 rest01.poc.lab:7071"
endpoints="$endpoints c3-01.poc.lab:9021 c3-01.poc.lab:9090 c3-01.poc.lab:7071"

for ep in $endpoints; do
  host=$(echo $ep | cut -d: -f1)

  if pem=$(openssl s_client -connect $ep -servername $host < /dev/null 2> /dev/null | openssl x509 2> /dev/null); then
    serial=$(echo "$pem" | openssl x509 -noout -serial | tail -c 9)

    # 從主旨取 CN，例：subject=CN=cp-server,O=PoC Bank,C=TW → cp-server
    cn=$(echo "$pem" | openssl x509 -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')

    printf '%-22s %s\n' $ep "$serial $cn"
  else
    printf '%-22s %s\n' $ep ""
  fi
done
```

```out
kafka-internal      serial=F343BC55 days=364
cp-server           serial=F343BC54 days=364
（7 行）
-- 各端點出示的憑證（序號末 8 碼）
kc01.poc.lab:9093      F343BC55 kafka-internal
kb01.poc.lab:9092      F343BC55 kafka-internal
kb01.poc.lab:9095      F343BC54 cp-server
（11 行：controller 的 9093、7071 與 broker 的 9092 是 kafka-internal；broker 的 9095、8090、7071 是 cp-server；REST 的 8082、7071 是 svc-rest；C3 的 9021、9090、7071 是 svc-c3）
```

> 要求 client 憑證的埠（9092、9093、9090）沒有帶憑證也看得到伺服器出示的那張，握手才會在之後失敗；這裡只看伺服器那一張。

## 21.2 換發 leaf（同一個 CA）

**這一節在做什麼**：每年的例行換發。流程五步：產生新私鑰與 CSR（21.2.1）→ 銀行簽發（21.2.2）→ 檢查並做成新 keystore（21.2.3）→ 派送並滾動重啟（21.2.4）→ 確認都換好後替換正本（21.2.5）。新舊憑證在滾動期間都被信任，所以不會斷線；到 21.2.5 之前隨時可以放棄，舊的都還在原位。

### 21.2.1 新私鑰與 CSR

@role 小安 | ops02 | root

照第 9 章的 `requests.txt`（名稱、EKU、SAN 不變），每張產生新私鑰與 CSR，放 `~/pki/next/`：

```bash
install -d -m 0700 ~/pki/next ~/pki/next/keys ~/pki/next/requests ~/pki/next/incoming ~/pki/next/certs
cd ~/pki

# 清單上每一張：新私鑰（0600）與 CSR，放在 next/；有 SAN 的多加一行 subjectAltName
while read -r name eku san; do
  install -m 0600 /dev/null next/keys/$name.key
  openssl genrsa -out next/keys/$name.key 2048 2> /dev/null

  if [ "$san" = "-" ]; then
    openssl req -new -key next/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=$eku" \
      -out next/requests/$name.csr
  else
    # SAN 換成 subjectAltName 的寫法（同 9.1），例：kc01.poc.lab,kc01 → DNS:kc01.poc.lab,DNS:kc01
    dns_list=DNS:$(echo "$san" | sed 's/,/,DNS:/g')

    openssl req -new -key next/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=$eku" \
      -addext "subjectAltName=$dns_list" \
      -out next/requests/$name.csr
  fi

  echo "$name: csr ok"
done < requests.txt
```

```out
kafka-internal: csr ok
（7 行）
```

### 21.2.2 銀行 CA 簽發

@role 銀行 CA 窗口 | Windows 終端 | 本機

和 9.2 一樣，只是從 `next/` 拿、放回 `next/`：

```bash
cd ~/kafka-lab

# 1. 清掉上一次的，取回操作機 next/ 裡的申請檔
rm -rf ca/exchange/next
mkdir -p ca/exchange/next/signed
podman cp lab-ops02-1:/root/pki/next/requests "$(cygpath -m "$PWD/ca/exchange/next/")"

# 2. 逐一簽發
for f in ca/exchange/next/requests/*.csr; do
  name=$(basename $f .csr)
  bash ca/sign.sh "$f" "ca/exchange/next/signed/$name.crt"
done

# 3. 簽好的放回操作機的 next/incoming/，數一下
for f in ca/exchange/next/signed/*.crt; do
  podman cp "$(cygpath -m "$f")" lab-ops02-1:/root/pki/next/incoming/
done
podman exec lab-ops02-1 bash -c 'ls /root/pki/next/incoming | wc -l'
```

```out
signed app-legacy-billing.csr -> app-legacy-billing.crt  (CN = app-legacy-billing, O = PoC Bank, C = TW; EKU clientAuth)
（7 行）
9
```

### 21.2.3 檢查、做成 keystore

@role 小安 | ops02 | root

拆 leaf 與中繼、五項檢查加憑證鏈（和 9.3 同一套），多印一欄簽發者，換 CA 時用得到：

```bash
cd ~/pki/next
anchor=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. 拆開每一張回覆（同 9.3）：第一行到第一個 END CERTIFICATE 是 leaf，後面全部是中繼 CA（issuers）
for name in $(awk '{print $1}' ../requests.txt); do
  sed -n '1,/END CERT/p' incoming/$name.crt > incoming/$name.leaf.pem
  sed '1,/END CERT/d' incoming/$name.crt > incoming/$name.issuers.pem
done

# 2. 每一張：私鑰相符、CN、SAN、整條鏈驗得到銀行根憑證；印剩幾天與簽發者
while read -r name eku san; do
  leaf=incoming/$name.leaf.pem

  # 私鑰：憑證和私鑰算出的公鑰 sha256 前 16 碼一樣 = 是一對
  cert_pub=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16)
  key_pub=$(openssl pkey -in keys/$name.key -pubout 2> /dev/null | sha256sum | cut -c1-16)

  if [ "$cert_pub" = "$key_pub" ]; then
    key=ok
  else
    key=MISMATCH
  fi

  # CN，例：subject=CN=kafka-internal,O=PoC Bank,C=TW → kafka-internal
  cn=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')
  if [ "$cn" = "$name" ]; then
    cn=ok
  fi

  # SAN：憑證裡的與清單上的都排序、用逗號接起來再比；清單寫 - 表示沒有 SAN
  #   例：憑證裡的 DNS:kc01.poc.lab, DNS:kc01 → kc01,kc01.poc.lab
  san_line=$(openssl x509 -in $leaf -noout -ext subjectAltName 2> /dev/null | tail -n +2)
  san_sorted=$(echo "$san_line" | sed 's/ //g; s/DNS://g; s/,/\n/g' | sort)
  san_in_cert=$(echo "$san_sorted" | paste -sd,)

  san_wanted=""
  if [ "$san" != "-" ]; then
    san_sorted=$(echo "$san" | tr ',' '\n' | sort)
    san_wanted=$(echo "$san_sorted" | paste -sd,)
  fi

  if [ "$san_in_cert" = "$san_wanted" ]; then
    san_check=ok
  else
    san_check=DIFF
  fi

  if openssl verify -CAfile $anchor -untrusted incoming/$name.issuers.pem $leaf > /dev/null 2>&1; then
    chain=ok
  else
    chain=FAIL
  fi

  # 還有幾天到期、簽發者的 CN（例 PoC Bank Issuing CA 01）
  end=$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)
  days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
  issuer=$(openssl x509 -in $leaf -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')

  printf '%-19s key=%s cn=%s san=%s days=%s chain=%s issuer=%s\n' $name $key "$cn" $san_check "$days" $chain "$issuer"
done < ../requests.txt
```

```out
kafka-internal      key=ok cn=ok san=ok days=364 chain=ok issuer=PoC Bank Issuing CA 01
（9 行，全部 ok）
```

做成 p12（**同一個 keystore 密碼**，所以 properties 不用改）：

```bash
cd ~/pki/next

# 1. 每一張：正式的 PEM（leaf＋中繼）與 PKCS12 keystore（0600；密碼和原本的一樣）
for name in $(awk '{print $1}' ../requests.txt); do
  cat incoming/$name.leaf.pem incoming/$name.issuers.pem > certs/$name.crt

  openssl pkcs12 -export -name $name \
    -inkey keys/$name.key \
    -in certs/$name.crt \
    -out certs/$name.p12 \
    -passout file:../store.pass

  chmod 0600 certs/$name.p12
done

ls certs | wc -l

# 2. 兩張最常用的：舊的與新的序號（末 8 碼）
for name in kafka-internal cp-server; do
  old_serial=$(openssl x509 -in ../certs/$name.crt -noout -serial | tail -c 9)
  new_serial=$(openssl x509 -in certs/$name.crt -noout -serial | tail -c 9)
  echo "$name: old=$old_serial new=$new_serial"
done
```

```out
14
kafka-internal: old=F343BC55 new=F343BC5D
cp-server: old=F343BC54 new=F343BC5C
```

### 21.2.4 派送、滾動重啟

@role 小安 | ops02 | root

| 主機 | 換哪些檔 | 重啟 |
|---|---|---|
| controller | kafka-internal.p12 | confluent-server |
| broker | kafka-internal.p12、cp-server.p12 | confluent-server |
| REST Proxy | svc-rest.p12 | confluent-kafka-rest |
| C3 | svc-c3.p12、svc-c3.crt／.key | prometheus、alertmanager、confluent-control-center |

每台的 7071（JMX exporter，第 17 章）是服務裡的 javaagent，讀同一個 keystore（controller 用 `kafka-internal.p12`，broker 用 `cp-server.p12`，REST 用 `svc-rest.p12`，C3 用 `svc-c3.p12`）：服務重啟就一起換，不用另外處理；換完用 21.1 的指令看 7071 也是新序號。

一台一台：放檔 → 重啟 → 等健康 → 確認那台出示的是新序號，才做下一台：

```bash
cd ~/pki/next

# 新憑證的完整序號，用來比對 9093 出示的是不是新的
new_internal=$(openssl x509 -in certs/kafka-internal.crt -noout -serial | cut -d= -f2)

# controller：放新的 kafka-internal.p12、重啟、等 active，再等 9093 出示新序號（在那台執行 EOF 之前的那一段）
for h in kc01 kc02 kc03; do
  scp -q certs/kafka-internal.p12 $h.poc.lab:/tmp/

  ssh $h.poc.lab bash -s <<'EOF'
sudo install -o root -g confluent -m 0640 /tmp/kafka-internal.p12 /etc/confluent/ssl/
rm -f /tmp/kafka-internal.p12
sudo systemctl restart confluent-server

for i in $(seq 1 30); do
  if systemctl is-active -q confluent-server; then
    break
  fi

  sleep 2
done
EOF

  # 9093 實際出示的憑證序號（還沒開始聽時是空的）：每 2 秒看一次，最多 30 次
  for i in $(seq 1 30); do
    served=$(openssl s_client -connect $h.poc.lab:9093 -servername $h.poc.lab < /dev/null 2> /dev/null \
      | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

    if [ "$served" = "$new_internal" ]; then
      break
    fi

    sleep 2
  done

  # 出示的是新序號就印 new，否則印 OLD
  if [ "$served" = "$new_internal" ]; then
    result=new
  else
    result=OLD
  fi

  echo "$h $(ssh $h.poc.lab systemctl is-active confluent-server) 9093=$result"
done
```

```out
kc01 active 9093=new
（3 行）
```

> 陷阱：controller 的 `systemctl is-active` 變成 active 之後，9093 還要幾秒才開始聽。這時去看出示的憑證會拿到空的，看起來像「還是舊的」。所以上面是等到它出示新序號才往下。

broker 接著做，同樣一台健康了才做下一台：

```bash
cd ~/pki/next

# 新憑證的完整序號，用來比對各端點出示的是不是新的
new_internal=$(openssl x509 -in certs/kafka-internal.crt -noout -serial | cut -d= -f2)
new_server=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2)

# broker：放兩個 p12、重啟、等 MDS 回 200；看 9092（kafka-internal）與 9095（cp-server）
for h in kb01 kb02 kb03 kb04; do
  scp -q certs/kafka-internal.p12 certs/cp-server.p12 $h.poc.lab:/tmp/

  ssh $h.poc.lab bash -s <<'EOF'
for f in kafka-internal.p12 cp-server.p12; do
  sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/
done

rm -f /tmp/*.p12
sudo systemctl restart confluent-server
EOF

  # 等那台 MDS（8090）回 200：每 5 秒看一次，最多 60 次
  for i in $(seq 1 60); do
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  # 9092 出示的是新序號就印 new，否則印 OLD
  served=$(openssl s_client -connect $h.poc.lab:9092 -servername $h.poc.lab < /dev/null 2> /dev/null \
    | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

  if [ "$served" = "$new_internal" ]; then
    result_9092=new
  else
    result_9092=OLD
  fi

  # 9095 同樣
  served=$(openssl s_client -connect $h.poc.lab:9095 -servername $h.poc.lab < /dev/null 2> /dev/null \
    | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

  if [ "$served" = "$new_server" ]; then
    result_9095=new
  else
    result_9095=OLD
  fi

  mds_url=https://$h.poc.lab:8090/v1/metadata/id
  echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' $mds_url) 9092=$result_9092 9095=$result_9095"
done
```

```out
kb01 MDS=200 9092=new 9095=new
（4 行）
```

REST Proxy 與 C3（REST 的健康檢查用應用程式的**舊**憑證，證明舊 leaf 在換發期間仍然有效）：

```bash
cd ~/pki/next
new_c3=$(openssl x509 -in certs/svc-c3.crt -noout -serial | cut -d= -f2)

# 1. C3：送新的檔，在 c3-01 執行 EOF 之前的那一段：放檔、依序重啟三個服務
scp -q certs/svc-c3.p12 certs/svc-c3.crt keys/svc-c3.key c3-01.poc.lab:/tmp/

ssh c3-01.poc.lab bash -s <<'EOF'
for f in svc-c3.p12 svc-c3.crt svc-c3.key; do
  sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/
done

rm -f /tmp/svc-c3.*

for unit in prometheus alertmanager confluent-control-center; do
  sudo systemctl restart $unit
done
EOF

# 2. 等畫面回 200（每 5 秒看一次，最多 60 次）
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 5
done

# 3. 看 9021、9090 出示的是不是新的
served=$(openssl s_client -connect c3-01.poc.lab:9021 -servername c3-01.poc.lab < /dev/null 2> /dev/null \
  | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

if [ "$served" = "$new_c3" ]; then
  result_9021=new
else
  result_9021=OLD
fi

served=$(openssl s_client -connect c3-01.poc.lab:9090 -servername c3-01.poc.lab < /dev/null 2> /dev/null \
  | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

if [ "$served" = "$new_c3" ]; then
  result_9090=new
else
  result_9090=OLD
fi

c3_url=https://c3-01.poc.lab:9021/
echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' $c3_url) 9021=$result_9021 9090=$result_9090"
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

REST Proxy 照 12.1 一台一台換：新的 `svc-rest.p12` 複製過去、裝好再重啟。

```bash
cd ~/pki/next

# 重啟前在那台要執行的指令：放新的 p12、刪掉 /tmp 的副本（set -e：任何一行失敗就不重啟）
before='set -e
sudo install -o root -g confluent -m 0640 /tmp/svc-rest.p12 /etc/confluent/ssl/
rm -f /tmp/svc-rest.p12'

~/conf/rest-restart.sh rest01 -c "certs/svc-rest.p12" -b "$before"
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
cd ~/pki/next

# 重啟前在那台要執行的指令（同 rest01）
before='set -e
sudo install -o root -g confluent -m 0640 /tmp/svc-rest.p12 /etc/confluent/ssl/
rm -f /tmp/svc-rest.p12'

~/conf/rest-restart.sh rest02 -c "certs/svc-rest.p12" -b "$before"
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
cd ~/pki/next
new_rest=$(openssl x509 -in certs/svc-rest.crt -noout -serial | cut -d= -f2)

for h in rest01 rest02; do
  # 那個端點實際出示的憑證序號
  served=$(openssl s_client -connect $h.poc.lab:8082 -servername $h.poc.lab < /dev/null 2> /dev/null \
    | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

  if [ "$served" = "$new_rest" ]; then
    echo "$h 8082=new"
  else
    echo "$h 8082=OLD"
  fi
done
```

```out
rest01 8082=new
rest02 8082=new
```

### 21.2.5 換成正本、交出去的那幾張

@role 小安 | ops02 | root

舊的整份留到 `~/pki/old-<日期時間>/`，新的放回正本位置。操作機自己用的 `svc-ops`、`kafka-internal`（管理 client、quorum 查詢）換成新的之後馬上試一次；緊急身分 `svc-ops` 要換掉操作機上的 `~/secrets/svc-ops.pem`（新私鑰＋新憑證鏈，root 0600；選單 91 直接讀這個檔）；`app-legacy-billing` 是應用程式的憑證，**交給應用程式團隊在他們的時段換**（舊的到期前都還有效）：

```bash
cd ~/pki
old=old-$(date +%Y%m%d-%H%M)

# 1. 舊的整份搬到 old-<日期時間>/，新的放回正本位置（私鑰與 p12 0600）
install -d -m 0700 $old/keys $old/certs

for name in $(awk '{print $1}' requests.txt); do
  mv keys/$name.key $old/keys/
  mv certs/$name.crt certs/$name.p12 $old/certs/
  install -m 0600 next/keys/$name.key keys/
  install -m 0644 next/certs/$name.crt certs/
  install -m 0600 next/certs/$name.p12 certs/
done

rm -rf next

# 2. 操作機自己用的兩個身分馬上試：svc-ops（管理 client）、kafka-internal（查 quorum）
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

echo "svc-ops 管理 client：$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --list 2> /dev/null | wc -l) 個 topic"

echo "kafka-internal 查 quorum：$(kafka-metadata-quorum \
  --bootstrap-controller kc01.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties \
  describe --status 2> /dev/null | grep -o 'LeaderId: *[0-9]*')"

# 3. app-legacy-billing：新的（交給應用程式團隊）與舊的（還在效期內）都能用；經 LB 打 REST，印 HTTP 狀態碼（同一行）
rest_url=https://rest.poc.lab:8082/v3/clusters

printf '新的 app-legacy-billing（交給應用程式團隊）：REST=%s' "$(curl -s -o /dev/null -w '%{http_code}' \
  --cert certs/app-legacy-billing.crt \
  --key keys/app-legacy-billing.key \
  $rest_url)"

printf '；舊的（還在效期內）：REST=%s\n' "$(curl -s -o /dev/null -w '%{http_code}' \
  --cert $old/certs/app-legacy-billing.crt \
  --key $old/keys/app-legacy-billing.key \
  $rest_url)"
```

```out
svc-ops 管理 client：14 個 topic
kafka-internal 查 quorum：LeaderId: 1
新的 app-legacy-billing（交給應用程式團隊）：REST=200；舊的（還在效期內）：REST=200
```

`svc-ops` 的憑證換了，緊急模式用的 PEM 操作機上的 `~/secrets/svc-ops.pem` 也要換（舊的另存 `.prev`，到期前都還有效）：

@role 小安 | ops02 | root

```bash
# 1. 舊的另存 .prev（到期前都還有效）
if [ -f ~/secrets/svc-ops.pem ]; then
  cp -p ~/secrets/svc-ops.pem ~/secrets/svc-ops.prev.pem
fi

# 2. 新的：私鑰＋憑證鏈接成一個 PEM 檔（0600）
install -m 0600 /dev/null ~/secrets/svc-ops.pem
cat ~/pki/keys/svc-ops.key ~/pki/certs/svc-ops.crt > ~/secrets/svc-ops.pem

echo "svc-ops 已更新，序號末 8 碼 $(openssl x509 -in ~/secrets/svc-ops.pem -noout -serial | tail -c 9)"
```

```out
svc-ops 已更新，序號末 8 碼 …
```

最後用 21.1 的指令再看一次：每個端點的序號都要是新的。

## 21.3 換 CA（三階段）

**這一節在做什麼**：銀行換了根憑證（新私鑰）、或換了簽發 CA 時的做法。前提：21.2 的換發已經做過一次（這一節會把它整個再做一次），第 17 章的監控已接上（銀行 Prometheus 的 `ca.pem` 也要跟著換）。完成的樣子：每個端點出示的憑證 issuer 都是新 CA，舊 CA 簽的憑證連 REST Proxy 被拒。名詞：根憑證（root）是信任的起點，簽發 CA（中繼）用它簽 leaf；lab 裡原本的根是 0.5 建的，21.3 換成的新 CA 叫 G2，21.4 再換成的叫 G3。

**不可逆的點**：階段三「拿掉舊根」之後，凡是還出示舊 CA 簽的憑證的，一律被拒，要退回只能重新加回舊根。所以階段二的每個端點（含銀行的 AD、套件庫，以及應用程式的憑證）都確認換好之後，才進階段三。

銀行換根憑證（或換簽發 CA）時，不能一次全換：只要有一台還不信新的根，它就會拒絕新憑證。三個階段，每段結束時所有元件都同時信任新舊兩個根：

| 階段 | 誰做 | 做什麼 | 之後的狀態 |
|---|---|---|---|
| 一、加 | 銀行 OS 團隊＋小安 | 信任清單加入新根（OS 的 `bank-root.pem` 變成兩張根的 bundle、truststore 多一個 alias、C3 的 ca.pem） | 新舊都信；憑證還是舊 CA 簽的 |
| 二、換 | 銀行 CA＋小安 | 銀行用新 CA 重簽自己的伺服器（AD、套件庫）；小安照 21.2 換發全部 leaf，改由新 CA 簽 | 新舊都信；憑證都是新 CA 簽的 |
| 三、退 | 銀行 OS 團隊＋小安 | 信任清單拿掉舊根 | 只信新的；舊 CA 簽的一律被拒 |

### 21.3.1 銀行建新 CA（lab 模擬）

@role 銀行 CA 窗口 | Windows 終端 | 本機

（lab 專用）正式環境是銀行 CA 窗口建好新 CA、公布新根的指紋。lab 裡：和 0.5 一樣的做法，名字換成 G2，放在 `ca/g2/`；簽發腳本複製一份（它用自己所在目錄的簽發 CA）：

```bash
cd ~/kafka-lab/ca
mkdir -p g2
cd g2

# 1. 新根 CA G2：私鑰與自簽的根憑證（20 年）
openssl genrsa -out root.key 4096 2> /dev/null
openssl req -x509 -new -key root.key -sha256 -days 7300 -out root.crt \
  -subj "/CN=PoC Bank Root CA G2/O=PoC Bank/C=TW" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"

# 2. 新簽發 CA G2，由新根簽（10 年；pathlen:0）
openssl genrsa -out issuing.key 4096 2> /dev/null
openssl req -new -key issuing.key -sha256 -subj "/CN=PoC Bank Issuing CA G2/O=PoC Bank/C=TW" -out issuing.csr

cat > issuing.ext <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
openssl x509 -req -in issuing.csr -CA root.crt -CAkey root.key -CAcreateserial \
  -days 3650 -sha256 -extfile issuing.ext -out issuing.crt 2> /dev/null
rm -f issuing.csr issuing.ext

# 3. 簽發腳本複製一份（它用自己所在目錄的簽發 CA）
cp ../sign.sh sign.sh

# 4. 確認：簽發 CA 驗得過新根；印出新根的名稱與指紋
openssl verify -CAfile root.crt issuing.crt
openssl x509 -in root.crt -noout -subject -fingerprint -sha256
```

```out
issuing.crt: OK
subject=CN=PoC Bank Root CA G2, O=PoC Bank, C=TW
sha256 Fingerprint=…
```

### 21.3.2 階段一：信任清單加入新根

@role 銀行 OS 團隊 | Windows 終端 | 本機

每台主機（含操作機）的 `bank-root.pem` 換成「舊根＋新根」兩張的 bundle。檔名不變，所以所有指向它的設定（curl、操作機上的檢查）都不用改：

```bash
cd ~/kafka-lab/ca

# 1. 舊根＋新根兩張接成一個 bundle
cat root.crt g2/root.crt > bundle-g1-g2.pem
bundle=$(cygpath -m "$PWD/bundle-g1-g2.pem")

# 2. 每台主機的 bank-root.pem 換成 bundle（檔名不變）、更新 OS 信任清單；印出裡面有幾張根
anchor=/etc/pki/ca-trust/source/anchors/bank-root.pem

for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  podman cp "$bundle" lab-$h-1:/root/bank-root.pem
  podman exec lab-$h-1 install -m 0644 /root/bank-root.pem $anchor
  podman exec lab-$h-1 rm -f /root/bank-root.pem
  podman exec lab-$h-1 update-ca-trust
  printf "%s:%s " $h "$(podman exec lab-$h-1 grep -c 'BEGIN CERT' $anchor)"
done
echo
```

```out
ops02:2 kc01:2 kc02:2 kc03:2 kb01:2 kb02:2 kb03:2 kb04:2 rest01:2 rest02:2 c3-01:2
```

@role 小安 | ops02 | root

先寫一支滾動重啟的小腳本 `rolling-restart.sh`，三個階段都會用（controller → broker → C3，一台健康了才做下一台；REST Proxy 不在裡面，照 12.1 另外做）：

```bash
cat > ~/conf/rolling-restart.sh <<'EOF'
#!/usr/bin/env bash
# rolling-restart.sh — 依序滾動重啟 controller → broker → C3；一台健康了才做下一台
# REST Proxy 不在這裡：照 12.1 一台一台先從 LB 停用再重啟
# 用到：操作機到各主機的 ssh（cpuser）；健康檢查用 OS 的信任清單（curl 不帶 --cacert）
# 改的時候要注意：輸出（kc01 active、kb01 MDS=200、c3-01 UI=200）手冊的預期輸出有用到

# mds_code <主機>：那台 MDS（8090）的 HTTP 狀態碼
mds_code() {
  curl -s -o /dev/null -w '%{http_code}' https://$1.poc.lab:8090/v1/metadata/id
}

# c3_code：C3 畫面的 HTTP 狀態碼
c3_code() {
  curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/
}

# 1. controller：重啟，等 9093 回應 TLS（每 2 秒試一次，最多 30 次）
for h in kc01 kc02 kc03; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  for i in $(seq 1 30); do
    if openssl s_client -connect $h.poc.lab:9093 < /dev/null > /dev/null 2>&1; then
      break
    fi

    sleep 2
  done

  echo "$h $(ssh $h.poc.lab systemctl is-active confluent-server)"
done

# 2. broker：重啟，等 MDS 回 200（每 5 秒看一次，最多 60 次）
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  for i in $(seq 1 60); do
    if [ "$(mds_code $h)" = 200 ]; then
      break
    fi

    sleep 5
  done

  echo "$h MDS=$(mds_code $h)"
done

# 3. C3：依序重啟三個服務，等畫面回 200（每 5 秒看一次，最多 60 次）
for unit in prometheus alertmanager confluent-control-center; do
  ssh c3-01.poc.lab "sudo systemctl restart $unit"
done

for i in $(seq 1 60); do
  if [ "$(c3_code)" = 200 ]; then
    break
  fi

  sleep 5
done

echo "c3-01 UI=$(c3_code)"
EOF

chmod 0700 ~/conf/rolling-restart.sh
echo rolling-restart.sh ok
```

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

行內 Prometheus 抓 JMX exporter 用的 `ca.pem`（17.5 交給監控團隊的那份）換成新舊兩個根的 bundle，重啟 Prometheus，確認 10 個 target 都回到 up。少了這一步，換完憑證之後 Prometheus 就抓不到任何指標（lab 實測：覆蓋率變 0／816）：

```bash
# 1. 銀行 Prometheus 的 ca.pem 換成新舊兩個根的 bundle，重啟 Prometheus
cp ~/kafka-lab/ca/bundle-g1-g2.pem ~/kafka-lab/bank-monitoring/prometheus/confluent/ca.pem
podman restart lab-mon-prometheus > /dev/null

# 2. 等 10 個 target 都回到 up：每 10 秒看一次，最多 12 次
for i in $(seq 1 12); do
  # Prometheus 上 health 是 up 的 target 數
  up=$(podman exec lab-mon-prometheus wget -qO- http://localhost:9090/api/v1/targets 2> /dev/null \
    | grep -o '"health":"up"' | wc -l)

  if [ "$up" = 10 ]; then
    break
  fi

  sleep 10
done

echo "Prometheus target up：$up / 10（約 $((i*10)) 秒）"
```

```out
Prometheus target up：10 / 10（約 70 秒）
```

@role 小安 | ops02 | root

我方的信任清單：truststore 加一個 alias `bank-root-g2`；17.5 交給銀行的 `to-bank/prometheus/ca.pem` 也一起換（之後重新交付 `to-bank/` 才不會把舊根帶回去，Prometheus 會全部抓不到）；C3 的 Prometheus／Alertmanager 用的 `ca.pem`、OP menu 的兩份也換成 bundle。派送、滾動重啟：

```bash
cd ~/pki/certs

# 1. 操作機 OS 信任清單裡的 bundle 複製一份到這裡；交給銀行的 to-bank/ 也換成它
cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem
cp bank-root.pem ~/monitoring/to-bank/prometheus/ca.pem

# 2. truststore 加一個 alias bank-root-g2：bundle 切開後，/tmp/root-00 是舊根、/tmp/root-01 是新根
csplit -s -z -f /tmp/root- bank-root.pem '/BEGIN CERT/' '{*}'

if ! keytool -importcert -noprompt -alias bank-root-g2 -file /tmp/root-01 \
  -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass > /dev/null 2>&1; then
  echo "（bank-root-g2 沒有加進去：可能已經在 truststore 裡，看下一行）"
fi

rm -f /tmp/root-*
aliases=$(keytool -list \
  -keystore truststore.p12 \
  -storetype PKCS12 \
  -storepass:file ../store.pass 2> /dev/null | grep trustedCertEntry | cut -d, -f1)
echo "truststore：$(echo "$aliases" | paste -sd' ')"

# 3. 派送：truststore 到 10 台
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  scp -q truststore.p12 $h.poc.lab:/tmp/
  ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/'
  ssh $h.poc.lab 'rm -f /tmp/truststore.p12'
done

# 4. C3 的 Prometheus／Alertmanager 用的 ca.pem
scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem
ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem'
ssh c3-01.poc.lab 'rm -f /tmp/ca.pem'

# 5. OP menu 的兩份
install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12
install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem

# 6. 滾動重啟（controller → broker → C3）
bash ~/conf/rolling-restart.sh
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
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
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

### 21.3.3 階段二：全部改由新 CA 簽

@role 銀行 CA 窗口 | Windows 終端 | 本機

銀行 CA 窗口先用 G2 重簽銀行自己的伺服器：AD 的 LDAPS、套件庫。私鑰要不要換是銀行的事（lab 裡簡化成沿用），重啟讓它們出示新憑證：

```bash
cd ~/kafka-lab
tls=/var/lib/samba/private/tls

# 1. AD：用原本的 CSR 請 G2 重簽，新憑證與 bundle 放進 samba 的 tls/，停掉 samba 讓它重讀（啟動程式會自己再開）
podman cp lab-ad01-1:/root/csr/ad01.csr "$(cygpath -m "$PWD/ca/exchange/ad01-g2.csr")"
bash ca/g2/sign.sh ca/exchange/ad01-g2.csr ca/exchange/ad01-g2.crt
podman cp "$(cygpath -m "$PWD/ca/exchange/ad01-g2.crt")" lab-ad01-1:$tls/cert.pem
podman cp "$(cygpath -m "$PWD/ca/bundle-g1-g2.pem")" lab-ad01-1:$tls/ca.pem
podman exec lab-ad01-1 chmod 644 $tls/cert.pem $tls/ca.pem
podman exec lab-ad01-1 pkill -x samba
sleep 8

# 2. 套件庫 repo01：沿用私鑰產生新 CSR，請 G2 簽，重啟 httpd
web_tls=$(cygpath -m "$PWD/images/web/tls")
openssl req -new -key "$web_tls/repo.key" -out "$web_tls/repo-g2.csr" \
  -subj "/CN=repo01.poc.lab/O=PoC Bank/C=TW" \
  -addext "subjectAltName=DNS:repo01.poc.lab,DNS:repo01" \
  -addext "extendedKeyUsage=serverAuth" 2> /dev/null
bash ca/g2/sign.sh images/web/tls/repo-g2.csr images/web/tls/repo.crt
rm -f images/web/tls/repo-g2.csr
podman exec lab-repo01-1 systemctl restart httpd

# 3. 從操作機看兩台出示的憑證是誰簽的
# 3. 從操作機看兩台出示的憑證是誰簽的（在操作機執行 EOF 之前的那一段，$1 是主機:埠）
for ep in ad01.poc.lab:636 repo01.poc.lab:443; do
  issuer=$(podman exec -i lab-ops02-1 bash -s -- $ep <<'EOF'
openssl s_client -connect $1 < /dev/null 2> /dev/null \
  | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname \
  | sed 's/.*CN=//; s/,.*//'
EOF
)

  echo "$ep $issuer"
done
```

```out
signed ad01-g2.csr -> ad01-g2.crt  (CN = ad01.poc.lab, O = PoC Bank, C = TW; EKU serverAuth)
signed repo-g2.csr -> repo.crt  (…)
ad01.poc.lab:636 PoC Bank Issuing CA G2
repo01.poc.lab:443 PoC Bank Issuing CA G2
```

@role 小安 | ops02 | root

接著我方的每一張憑證都要改由 G2 簽：**把 21.2.1 到 21.2.5 整個再做一次**，唯一的差別是銀行 CA 窗口改用 `ca/g2/sign.sh`。下面照順序列出同一組指令，不再逐段解釋（`chain=ok` 是對 bundle 驗的，新根在裡面）：

**21.2.1 新私鑰與 CSR**

```bash
install -d -m 0700 ~/pki/next ~/pki/next/keys ~/pki/next/requests ~/pki/next/incoming ~/pki/next/certs
cd ~/pki

# 清單上每一張：新私鑰（0600）與 CSR，放在 next/；有 SAN 的多加一行 subjectAltName
while read -r name eku san; do
  install -m 0600 /dev/null next/keys/$name.key
  openssl genrsa -out next/keys/$name.key 2048 2> /dev/null

  if [ "$san" = "-" ]; then
    openssl req -new -key next/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=$eku" \
      -out next/requests/$name.csr
  else
    # SAN 換成 subjectAltName 的寫法（同 9.1），例：kc01.poc.lab,kc01 → DNS:kc01.poc.lab,DNS:kc01
    dns_list=DNS:$(echo "$san" | sed 's/,/,DNS:/g')

    openssl req -new -key next/keys/$name.key -sha256 -subj "/CN=$name/O=PoC Bank/C=TW" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
      -addext "extendedKeyUsage=$eku" \
      -addext "subjectAltName=$dns_list" \
      -out next/requests/$name.csr
  fi

  echo "$name: csr ok"
done < requests.txt
```

```out
kafka-internal: csr ok
（7 行）
```

**21.2.2 銀行改用 G2 簽**

@role 銀行 CA 窗口 | Windows 終端 | 本機

```bash
cd ~/kafka-lab

# 1. 清掉上一次的，取回操作機 next/ 裡的申請檔
rm -rf ca/exchange/next
mkdir -p ca/exchange/next/signed
podman cp lab-ops02-1:/root/pki/next/requests "$(cygpath -m "$PWD/ca/exchange/next/")"

# 2. 逐一簽發：這次用 G2 的簽發 CA
for f in ca/exchange/next/requests/*.csr; do
  name=$(basename $f .csr)
  bash ca/g2/sign.sh "$f" "ca/exchange/next/signed/$name.crt"
done

# 3. 簽好的放回操作機的 next/incoming/，數一下
for f in ca/exchange/next/signed/*.crt; do
  podman cp "$(cygpath -m "$f")" lab-ops02-1:/root/pki/next/incoming/
done
podman exec lab-ops02-1 bash -c 'ls /root/pki/next/incoming | wc -l'
```

```out
signed app-legacy-billing.csr -> app-legacy-billing.crt  (CN = app-legacy-billing, O = PoC Bank, C = TW; EKU clientAuth)
（7 行）
9
```

**21.2.3 檢查（issuer 要是 G2）**

@role 小安 | ops02 | root

```bash
cd ~/pki/next
anchor=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. 拆開每一張回覆（同 9.3）：第一行到第一個 END CERTIFICATE 是 leaf，後面全部是中繼 CA（issuers）
for name in $(awk '{print $1}' ../requests.txt); do
  sed -n '1,/END CERT/p' incoming/$name.crt > incoming/$name.leaf.pem
  sed '1,/END CERT/d' incoming/$name.crt > incoming/$name.issuers.pem
done

# 2. 每一張：私鑰相符、CN、SAN、整條鏈驗得到銀行根憑證；印剩幾天與簽發者
while read -r name eku san; do
  leaf=incoming/$name.leaf.pem

  # 私鑰：憑證和私鑰算出的公鑰 sha256 前 16 碼一樣 = 是一對
  cert_pub=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16)
  key_pub=$(openssl pkey -in keys/$name.key -pubout 2> /dev/null | sha256sum | cut -c1-16)

  if [ "$cert_pub" = "$key_pub" ]; then
    key=ok
  else
    key=MISMATCH
  fi

  # CN，例：subject=CN=kafka-internal,O=PoC Bank,C=TW → kafka-internal
  cn=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')
  if [ "$cn" = "$name" ]; then
    cn=ok
  fi

  # SAN：憑證裡的與清單上的都排序、用逗號接起來再比；清單寫 - 表示沒有 SAN
  #   例：憑證裡的 DNS:kc01.poc.lab, DNS:kc01 → kc01,kc01.poc.lab
  san_line=$(openssl x509 -in $leaf -noout -ext subjectAltName 2> /dev/null | tail -n +2)
  san_sorted=$(echo "$san_line" | sed 's/ //g; s/DNS://g; s/,/\n/g' | sort)
  san_in_cert=$(echo "$san_sorted" | paste -sd,)

  san_wanted=""
  if [ "$san" != "-" ]; then
    san_sorted=$(echo "$san" | tr ',' '\n' | sort)
    san_wanted=$(echo "$san_sorted" | paste -sd,)
  fi

  if [ "$san_in_cert" = "$san_wanted" ]; then
    san_check=ok
  else
    san_check=DIFF
  fi

  if openssl verify -CAfile $anchor -untrusted incoming/$name.issuers.pem $leaf > /dev/null 2>&1; then
    chain=ok
  else
    chain=FAIL
  fi

  # 還有幾天到期、簽發者的 CN（例 PoC Bank Issuing CA 01）
  end=$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)
  days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
  issuer=$(openssl x509 -in $leaf -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')

  printf '%-19s key=%s cn=%s san=%s days=%s chain=%s issuer=%s\n' $name $key "$cn" $san_check "$days" $chain "$issuer"
done < ../requests.txt
```

```out
kafka-internal      key=ok cn=ok san=ok days=364 chain=ok issuer=PoC Bank Issuing CA G2
（9 行，全部 ok）
```

**21.2.3 做成 keystore**

```bash
cd ~/pki/next

# 1. 每一張：正式的 PEM（leaf＋中繼）與 PKCS12 keystore（0600；密碼和原本的一樣）
for name in $(awk '{print $1}' ../requests.txt); do
  cat incoming/$name.leaf.pem incoming/$name.issuers.pem > certs/$name.crt

  openssl pkcs12 -export -name $name \
    -inkey keys/$name.key \
    -in certs/$name.crt \
    -out certs/$name.p12 \
    -passout file:../store.pass

  chmod 0600 certs/$name.p12
done

ls certs | wc -l

# 2. 兩張最常用的：舊的與新的序號（末 8 碼）
for name in kafka-internal cp-server; do
  old_serial=$(openssl x509 -in ../certs/$name.crt -noout -serial | tail -c 9)
  new_serial=$(openssl x509 -in certs/$name.crt -noout -serial | tail -c 9)
  echo "$name: old=$old_serial new=$new_serial"
done
```

```out
14
kafka-internal: old=F343BC55 new=F343BC5D
cp-server: old=F343BC54 new=F343BC5C
```

**21.2.4 派送、滾動重啟 controller 與 broker**

```bash
cd ~/pki/next

# 新憑證的完整序號，用來比對 9093 出示的是不是新的
new_internal=$(openssl x509 -in certs/kafka-internal.crt -noout -serial | cut -d= -f2)

# controller：放新的 kafka-internal.p12、重啟、等 active，再等 9093 出示新序號（在那台執行 EOF 之前的那一段）
for h in kc01 kc02 kc03; do
  scp -q certs/kafka-internal.p12 $h.poc.lab:/tmp/

  ssh $h.poc.lab bash -s <<'EOF'
sudo install -o root -g confluent -m 0640 /tmp/kafka-internal.p12 /etc/confluent/ssl/
rm -f /tmp/kafka-internal.p12
sudo systemctl restart confluent-server

for i in $(seq 1 30); do
  if systemctl is-active -q confluent-server; then
    break
  fi

  sleep 2
done
EOF

  # 9093 實際出示的憑證序號（還沒開始聽時是空的）：每 2 秒看一次，最多 30 次
  for i in $(seq 1 30); do
    served=$(openssl s_client -connect $h.poc.lab:9093 -servername $h.poc.lab < /dev/null 2> /dev/null \
      | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

    if [ "$served" = "$new_internal" ]; then
      break
    fi

    sleep 2
  done

  # 出示的是新序號就印 new，否則印 OLD
  if [ "$served" = "$new_internal" ]; then
    result=new
  else
    result=OLD
  fi

  echo "$h $(ssh $h.poc.lab systemctl is-active confluent-server) 9093=$result"
done
```

```out
kc01 active 9093=new
（3 行）
```

broker 接著做，同樣一台健康了才做下一台：

```bash
cd ~/pki/next

# 新憑證的完整序號，用來比對各端點出示的是不是新的
new_internal=$(openssl x509 -in certs/kafka-internal.crt -noout -serial | cut -d= -f2)
new_server=$(openssl x509 -in certs/cp-server.crt -noout -serial | cut -d= -f2)

# broker：放兩個 p12、重啟、等 MDS 回 200；看 9092（kafka-internal）與 9095（cp-server）
for h in kb01 kb02 kb03 kb04; do
  scp -q certs/kafka-internal.p12 certs/cp-server.p12 $h.poc.lab:/tmp/

  ssh $h.poc.lab bash -s <<'EOF'
for f in kafka-internal.p12 cp-server.p12; do
  sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/
done

rm -f /tmp/*.p12
sudo systemctl restart confluent-server
EOF

  # 等那台 MDS（8090）回 200：每 5 秒看一次，最多 60 次
  for i in $(seq 1 60); do
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  # 9092 出示的是新序號就印 new，否則印 OLD
  served=$(openssl s_client -connect $h.poc.lab:9092 -servername $h.poc.lab < /dev/null 2> /dev/null \
    | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

  if [ "$served" = "$new_internal" ]; then
    result_9092=new
  else
    result_9092=OLD
  fi

  # 9095 同樣
  served=$(openssl s_client -connect $h.poc.lab:9095 -servername $h.poc.lab < /dev/null 2> /dev/null \
    | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

  if [ "$served" = "$new_server" ]; then
    result_9095=new
  else
    result_9095=OLD
  fi

  mds_url=https://$h.poc.lab:8090/v1/metadata/id
  echo "$h MDS=$(curl -sk -o /dev/null -w '%{http_code}' $mds_url) 9092=$result_9092 9095=$result_9095"
done
```

```out
kb01 MDS=200 9092=new 9095=new
（4 行）
```

**21.2.4 REST Proxy 與 C3**

```bash
cd ~/pki/next
new_c3=$(openssl x509 -in certs/svc-c3.crt -noout -serial | cut -d= -f2)

# 1. C3：送新的檔，在 c3-01 執行 EOF 之前的那一段：放檔、依序重啟三個服務
scp -q certs/svc-c3.p12 certs/svc-c3.crt keys/svc-c3.key c3-01.poc.lab:/tmp/

ssh c3-01.poc.lab bash -s <<'EOF'
for f in svc-c3.p12 svc-c3.crt svc-c3.key; do
  sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/
done

rm -f /tmp/svc-c3.*

for unit in prometheus alertmanager confluent-control-center; do
  sudo systemctl restart $unit
done
EOF

# 2. 等畫面回 200（每 5 秒看一次，最多 60 次）
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 5
done

# 3. 看 9021、9090 出示的是不是新的
served=$(openssl s_client -connect c3-01.poc.lab:9021 -servername c3-01.poc.lab < /dev/null 2> /dev/null \
  | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

if [ "$served" = "$new_c3" ]; then
  result_9021=new
else
  result_9021=OLD
fi

served=$(openssl s_client -connect c3-01.poc.lab:9090 -servername c3-01.poc.lab < /dev/null 2> /dev/null \
  | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

if [ "$served" = "$new_c3" ]; then
  result_9090=new
else
  result_9090=OLD
fi

c3_url=https://c3-01.poc.lab:9021/
echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' $c3_url) 9021=$result_9021 9090=$result_9090"
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

REST Proxy 照 12.1 一台一台換：新的 `svc-rest.p12` 複製過去、裝好再重啟。

```bash
cd ~/pki/next

# 重啟前在那台要執行的指令：放新的 p12、刪掉 /tmp 的副本（set -e：任何一行失敗就不重啟）
before='set -e
sudo install -o root -g confluent -m 0640 /tmp/svc-rest.p12 /etc/confluent/ssl/
rm -f /tmp/svc-rest.p12'

~/conf/rest-restart.sh rest01 -c "certs/svc-rest.p12" -b "$before"
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
cd ~/pki/next

# 重啟前在那台要執行的指令（同 rest01）
before='set -e
sudo install -o root -g confluent -m 0640 /tmp/svc-rest.p12 /etc/confluent/ssl/
rm -f /tmp/svc-rest.p12'

~/conf/rest-restart.sh rest02 -c "certs/svc-rest.p12" -b "$before"
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
cd ~/pki/next
new_rest=$(openssl x509 -in certs/svc-rest.crt -noout -serial | cut -d= -f2)

for h in rest01 rest02; do
  # 那個端點實際出示的憑證序號
  served=$(openssl s_client -connect $h.poc.lab:8082 -servername $h.poc.lab < /dev/null 2> /dev/null \
    | openssl x509 -noout -serial 2> /dev/null | cut -d= -f2)

  if [ "$served" = "$new_rest" ]; then
    echo "$h 8082=new"
  else
    echo "$h 8082=OLD"
  fi
done
```

```out
rest01 8082=new
rest02 8082=new
```

**21.2.5 換成正本**

```bash
cd ~/pki
old=old-$(date +%Y%m%d-%H%M)

# 1. 舊的整份搬到 old-<日期時間>/，新的放回正本位置（私鑰與 p12 0600）
install -d -m 0700 $old/keys $old/certs

for name in $(awk '{print $1}' requests.txt); do
  mv keys/$name.key $old/keys/
  mv certs/$name.crt certs/$name.p12 $old/certs/
  install -m 0600 next/keys/$name.key keys/
  install -m 0644 next/certs/$name.crt certs/
  install -m 0600 next/certs/$name.p12 certs/
done

rm -rf next

# 2. 操作機自己用的兩個身分馬上試：svc-ops（管理 client）、kafka-internal（查 quorum）
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

echo "svc-ops 管理 client：$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --list 2> /dev/null | wc -l) 個 topic"

echo "kafka-internal 查 quorum：$(kafka-metadata-quorum \
  --bootstrap-controller kc01.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties \
  describe --status 2> /dev/null | grep -o 'LeaderId: *[0-9]*')"

# 3. app-legacy-billing：新的（交給應用程式團隊）與舊的（還在效期內）都能用；經 LB 打 REST，印 HTTP 狀態碼（同一行）
rest_url=https://rest.poc.lab:8082/v3/clusters

printf '新的 app-legacy-billing（交給應用程式團隊）：REST=%s' "$(curl -s -o /dev/null -w '%{http_code}' \
  --cert certs/app-legacy-billing.crt \
  --key keys/app-legacy-billing.key \
  $rest_url)"

printf '；舊的（還在效期內）：REST=%s\n' "$(curl -s -o /dev/null -w '%{http_code}' \
  --cert $old/certs/app-legacy-billing.crt \
  --key $old/keys/app-legacy-billing.key \
  $rest_url)"
```

```out
svc-ops 管理 client：14 個 topic
kafka-internal 查 quorum：LeaderId: 1
新的 app-legacy-billing（交給應用程式團隊）：REST=200；舊的（還在效期內）：REST=200
```

`svc-ops` 的憑證換了，緊急模式用的 PEM 操作機上的 `~/secrets/svc-ops.pem` 也要換（舊的另存 `.prev`，到期前都還有效）：

@role 小安 | ops02 | root

```bash
# 1. 舊的另存 .prev（到期前都還有效）
if [ -f ~/secrets/svc-ops.pem ]; then
  cp -p ~/secrets/svc-ops.pem ~/secrets/svc-ops.prev.pem
fi

# 2. 新的：私鑰＋憑證鏈接成一個 PEM 檔（0600）
install -m 0600 /dev/null ~/secrets/svc-ops.pem
cat ~/pki/keys/svc-ops.key ~/pki/certs/svc-ops.crt > ~/secrets/svc-ops.pem

echo "svc-ops 已更新，序號末 8 碼 $(openssl x509 -in ~/secrets/svc-ops.pem -noout -serial | tail -c 9)"
```

```out
svc-ops 已更新，序號末 8 碼 …
```

> 陷阱：這一段**一定要做完才能進階段三**。只有銀行的伺服器換成 G2、我方的 leaf 還是舊 CA 簽的就拿掉舊根，broker 驗不過 controller 的憑證，整個叢集起不來（lab 實際發生過：broker 一直重啟、MDS 不回應）。

最後確認每個端點出示的都是 G2 簽的憑證，全部是才往下：

@role 小安 | ops02 | root

```bash
# 不是 G2 簽的端點一個一個列出來
endpoints="kc01.poc.lab:9093 kc02.poc.lab:9093 kc03.poc.lab:9093"
endpoints="$endpoints kb01.poc.lab:9092 kb02.poc.lab:9092 kb03.poc.lab:9092 kb04.poc.lab:9092"
endpoints="$endpoints kb01.poc.lab:9095 kb01.poc.lab:8090 kb01.poc.lab:7071 kc01.poc.lab:7071"
endpoints="$endpoints rest01.poc.lab:8082 rest02.poc.lab:8082 rest01.poc.lab:7071"
endpoints="$endpoints c3-01.poc.lab:9021 c3-01.poc.lab:9090 c3-01.poc.lab:7071"

bad=0
for ep in $endpoints; do
  # 那個端點出示的憑證是誰簽的（簽發者的 CN；沒有回應就是空的）
  issuer=$(openssl s_client -connect $ep < /dev/null 2> /dev/null \
    | openssl x509 -noout -issuer 2> /dev/null | sed 's/.*CN *= *//; s/,.*//')

  if [ "$issuer" != "PoC Bank Issuing CA G2" ]; then
    if [ -z "$issuer" ]; then
      issuer="（沒有回應）"
    fi

    echo "$ep 出示的是：$issuer"
    bad=1
  fi
done

if [ $bad = 0 ]; then
  echo "17 個端點都是 G2 簽的：可以進階段三"
else
  echo "還有端點不是 G2 簽的：不要進階段三"
  false
fi
```

```out
17 個端點都是 G2 簽的：可以進階段三
```

### 21.3.4 階段三：拿掉舊根

@role 銀行 OS 團隊 | Windows 終端 | 本機

```bash
cd ~/kafka-lab/ca
new_root=$(cygpath -m "$PWD/g2/root.crt")
anchor=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. 每台主機的 bank-root.pem 換成只有新根 G2、更新 OS 信任清單；印出裡面有幾張根
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  podman cp "$new_root" lab-$h-1:/root/bank-root.pem
  podman exec lab-$h-1 install -m 0644 /root/bank-root.pem $anchor
  podman exec lab-$h-1 rm -f /root/bank-root.pem
  podman exec lab-$h-1 update-ca-trust
  printf "%s:%s " $h "$(podman exec lab-$h-1 grep -c 'BEGIN CERT' $anchor)"
done
echo

# 2. AD 的 ca.pem 也只留新根
podman cp "$new_root" lab-ad01-1:/var/lib/samba/private/tls/ca.pem
```

```out
ops02:1 kc01:1 kc02:1 kc03:1 kb01:1 kb02:1 kb03:1 kb04:1 rest01:1 rest02:1 c3-01:1
```

@role 小安 | ops02 | root

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

行內 Prometheus 抓 JMX exporter 用的 `ca.pem`（17.5 交給監控團隊的那份）換成只有新根 G2，重啟 Prometheus，確認 10 個 target 都回到 up。少了這一步，換完憑證之後 Prometheus 就抓不到任何指標（lab 實測：覆蓋率變 0／816）：

```bash
# 1. 銀行 Prometheus 的 ca.pem 換成只有新根 G2，重啟 Prometheus
cp ~/kafka-lab/ca/g2/root.crt ~/kafka-lab/bank-monitoring/prometheus/confluent/ca.pem
podman restart lab-mon-prometheus > /dev/null

# 2. 等 10 個 target 都回到 up：每 10 秒看一次，最多 12 次
for i in $(seq 1 12); do
  # Prometheus 上 health 是 up 的 target 數
  up=$(podman exec lab-mon-prometheus wget -qO- http://localhost:9090/api/v1/targets 2> /dev/null \
    | grep -o '"health":"up"' | wc -l)

  if [ "$up" = 10 ]; then
    break
  fi

  sleep 10
done

echo "Prometheus target up：$up / 10（約 $((i*10)) 秒）"
```

```out
Prometheus target up：10 / 10（約 70 秒）
```

@role 小安 | ops02 | root

truststore 拿掉舊的 alias、C3 與 OP menu 的 ca.pem、`to-bank/prometheus/ca.pem` 只留新根，派送、滾動重啟：

```bash
cd ~/pki/certs

# 1. 操作機 OS 信任清單（現在只有新根）複製一份到這裡；交給銀行的 to-bank/ 也換成它
cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem
cp bank-root.pem ~/monitoring/to-bank/prometheus/ca.pem

# 2. truststore 拿掉舊根的 alias bank-root
keytool -delete -alias bank-root -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass
aliases=$(keytool -list \
  -keystore truststore.p12 \
  -storetype PKCS12 \
  -storepass:file ../store.pass 2> /dev/null | grep trustedCertEntry | cut -d, -f1)
echo "truststore：$(echo "$aliases" | paste -sd' ')"

# 3. 派送：truststore 到 10 台
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  scp -q truststore.p12 $h.poc.lab:/tmp/
  ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/'
  ssh $h.poc.lab 'rm -f /tmp/truststore.p12'
done

# 4. C3 的 Prometheus／Alertmanager 用的 ca.pem
scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem
ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem'
ssh c3-01.poc.lab 'rm -f /tmp/ca.pem'

# 5. OP menu 的兩份
install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12
install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem

# 6. 滾動重啟（controller → broker → C3）
bash ~/conf/rolling-restart.sh
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
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
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

最後反向驗證：舊 CA 簽的憑證（21.2 第一次換發留在 `old-` 底下的那張應用程式憑證）連 REST Proxy 要被拒；新的要能用；AD、套件庫照常（它們在階段二已經換成 G2）：

```bash
cd ~/pki
oldest=$(ls -d old-* | head -1)   # 21.2 第一次換發留下的那一份（舊 CA 簽的）

# 1. 舊 CA 簽的 app 憑證要被拒、新的要能用；用這組 client 憑證經 LB 打 REST，印 HTTP 狀態碼（000 = TLS 就被拒絕）
rest_url=https://rest.poc.lab:8082/v3/clusters

echo "舊 CA 簽的 app 憑證 → REST：$(curl -s -o /dev/null -w '%{http_code}' \
  --cert $oldest/certs/app-legacy-billing.crt \
  --key $oldest/keys/app-legacy-billing.key \
  $rest_url)（000 = TLS 直接拒絕）"

echo "新 CA 簽的 app 憑證 → REST：$(curl -s -o /dev/null -w '%{http_code}' \
  --cert certs/app-legacy-billing.crt \
  --key keys/app-legacy-billing.key \
  $rest_url)"

# 2. AD、套件庫照常（它們在階段二已經換成 G2）
password=$(cat ~/secrets/ad-test-users.pass)
echo "alice 登入 MDS（MDS 要用 LDAPS 連 AD）：$(curl -s -o /dev/null -w '%{http_code}' \
  -u alice:$password \
  https://kb01.poc.lab:8090/security/1.0/authenticate)"
unset password

echo "套件庫：$(curl -s -o /dev/null -w '%{http_code}' https://repo01.poc.lab/confluent/repodata/repomd.xml)"
```

```out
舊 CA 簽的 app 憑證 → REST：000（000 = TLS 直接拒絕）
新 CA 簽的 app 憑證 → REST：200
alice 登入 MDS（MDS 要用 LDAPS 連 AD）：200
套件庫：200
```

> 階段三之前要確認：應用程式團隊已經換上新 CA 簽的憑證（REST 走 mTLS 的那些）、行內 Prometheus 與應用程式的 truststore 都已經有新根。否則拿掉舊根的那一刻，它們就斷了。

## 21.4 換鏈：中繼沒換私鑰，只換憑證鏈

**這一節在做什麼**：處理 21.0 表裡「中繼沿用私鑰」的那幾列：leaf 不用重簽（簽它的私鑰沒變），只把每個 p12 裡夾帶的中繼換成銀行給的新那張。不用 CSR、不用銀行簽任何東西，只是把「現在的 leaf＋新中繼」重新包成 p12、派送、滾動重啟。前提：21.3 做過（這一節接在 G2 之後），且已照 21.0 的表判斷出是哪一列。完成的樣子：每個端點出示的第二張（中繼）都是 G3 簽的；同一張 leaf 配舊鏈連 REST Proxy 被拒、配新鏈通過。這是最複雜的一種，只有銀行明確說是這種情況才需要。

這一節演練最麻煩的那一列：**銀行換根（G3，新私鑰），中繼 G2 沿用私鑰、由 G3 重簽**。信任清單一樣走三階段，階段二從「重簽 leaf」換成「換鏈」。只有中繼續簽、根不動的情況（表的第 3 列），跳過 21.4.2 和 21.4.5，只做 21.4.3、21.4.4。

| 階段 | 做什麼 | 之後的狀態 |
|---|---|---|
| 一、加 | 信任清單加入 G3 | G2、G3 都信；大家出示的還是舊鏈（中繼由 G2 簽） |
| 二、換鏈 | 銀行的伺服器、我方每一張 p12 都換成新鏈（中繼由 G3 簽） | 兩個根都信；出示的都是新鏈 |
| 三、退 | 信任清單拿掉 G2 | 只信 G3；還出示舊鏈的一律被拒 |

> 陷阱：舊鏈和新鏈的 leaf **是同一張**（同序號、同私鑰），所以 21.1 看序號分不出誰換好了。這一節改看端點出示的**第二張（中繼）是誰簽的**。

### 21.4.1 銀行建 G3、用 G3 重簽中繼（lab 模擬）

@role 銀行 CA 窗口 | Windows 終端 | 本機

（lab 專用）正式環境這是銀行 CA 窗口的事，交給小安的只有新根與新的中繼憑證。lab 裡：新根 G3 用新私鑰；中繼沿用 G2 中繼的私鑰與名稱，改由 G3 簽。新的中繼先放 `g2/issuing-g3.crt`，階段二才換成簽發腳本用的那張：

```bash
cd ~/kafka-lab/ca
mkdir -p g3
cd g3

# 1. 新根 G3（新私鑰）
openssl genrsa -out root.key 4096 2> /dev/null
openssl req -x509 -new -key root.key -sha256 -days 7300 -out root.crt \
  -subj "/CN=PoC Bank Root CA G3/O=PoC Bank/C=TW" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"

# 2. 中繼沿用 G2 中繼的私鑰與名稱，改由 G3 簽；新的中繼先放 g2/issuing-g3.crt
cd ../g2
openssl req -new -key issuing.key -sha256 -subj "/CN=PoC Bank Issuing CA G2/O=PoC Bank/C=TW" -out issuing-g3.csr

cat > issuing.ext <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
openssl x509 -req -in issuing-g3.csr -CA ../g3/root.crt -CAkey ../g3/root.key -CAcreateserial \
  -days 3650 -sha256 -extfile issuing.ext -out issuing-g3.crt 2> /dev/null
rm -f issuing-g3.csr issuing.ext

# 3. 確認：新中繼驗得過 G3；新舊兩張中繼的名稱、簽發者、公鑰雜湊
openssl verify -CAfile ../g3/root.crt issuing-g3.crt

for f in issuing.crt issuing-g3.crt; do
  subject=$(openssl x509 -in $f -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')
  issuer=$(openssl x509 -in $f -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')
  key=$(openssl x509 -in $f -noout -pubkey | sha256sum | cut -c1-12)
  echo "$f: $subject（簽發者 $issuer）key=$key"
done
```

```out
issuing-g3.crt: OK
issuing.crt: PoC Bank Issuing CA G2（簽發者 PoC Bank Root CA G2）key=…
issuing-g3.crt: PoC Bank Issuing CA G2（簽發者 PoC Bank Root CA G3）key=…（和上一行相同）
```

名稱相同、key 相同、簽發者不同：就是 21.0 表的「根換私鑰，中繼同私鑰由新根重簽」。

### 21.4.2 階段一：信任清單加入 G3

@role 銀行 OS 團隊 | Windows 終端 | 本機

和 21.3.2 一樣，bundle 換成 G2＋G3（AD 的 `ca.pem` 也一起）：

```bash
cd ~/kafka-lab/ca

# 1. G2＋G3 兩張接成一個 bundle
cat g2/root.crt g3/root.crt > bundle-g2-g3.pem
bundle=$(cygpath -m "$PWD/bundle-g2-g3.pem")
anchor=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 2. 每台主機的 bank-root.pem 換成 bundle、更新 OS 信任清單；印出裡面有幾張根
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  podman cp "$bundle" lab-$h-1:/root/bank-root.pem
  podman exec lab-$h-1 install -m 0644 /root/bank-root.pem $anchor
  podman exec lab-$h-1 rm -f /root/bank-root.pem
  podman exec lab-$h-1 update-ca-trust
  printf "%s:%s " $h "$(podman exec lab-$h-1 grep -c 'BEGIN CERT' $anchor)"
done
echo

# 3. AD 的 ca.pem 也換成 bundle
podman cp "$bundle" lab-ad01-1:/var/lib/samba/private/tls/ca.pem
podman exec lab-ad01-1 chmod 644 /var/lib/samba/private/tls/ca.pem
```

```out
ops02:2 kc01:2 kc02:2 kc03:2 kb01:2 kb02:2 kb03:2 kb04:2 rest01:2 rest02:2 c3-01:2
```

@role 小安 | ops02 | root

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

行內 Prometheus 抓 JMX exporter 用的 `ca.pem`（17.5 交給監控團隊的那份）換成G2＋G3 的 bundle，重啟 Prometheus，確認 10 個 target 都回到 up。少了這一步，換完憑證之後 Prometheus 就抓不到任何指標（lab 實測：覆蓋率變 0／816）：

```bash
# 1. 銀行 Prometheus 的 ca.pem 換成 G2＋G3 的 bundle，重啟 Prometheus
cp ~/kafka-lab/ca/bundle-g2-g3.pem ~/kafka-lab/bank-monitoring/prometheus/confluent/ca.pem
podman restart lab-mon-prometheus > /dev/null

# 2. 等 10 個 target 都回到 up：每 10 秒看一次，最多 12 次
for i in $(seq 1 12); do
  # Prometheus 上 health 是 up 的 target 數
  up=$(podman exec lab-mon-prometheus wget -qO- http://localhost:9090/api/v1/targets 2> /dev/null \
    | grep -o '"health":"up"' | wc -l)

  if [ "$up" = 10 ]; then
    break
  fi

  sleep 10
done

echo "Prometheus target up：$up / 10（約 $((i*10)) 秒）"
```

```out
Prometheus target up：10 / 10（約 70 秒）
```

@role 小安 | ops02 | root

truststore 加 alias `bank-root-g3`（bundle 的第二張），C3 與 OP menu 的 ca.pem 換成 bundle，派送、滾動重啟（21.3.2 寫的那支 `rolling-restart.sh`）：

```bash
cd ~/pki/certs

# 1. 操作機 OS 信任清單裡的 bundle（G2＋G3）複製一份到這裡；交給銀行的 to-bank/ 也換成它
cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem
cp bank-root.pem ~/monitoring/to-bank/prometheus/ca.pem

# 2. truststore 加一個 alias bank-root-g3：bundle 切開後，/tmp/root-01 是第二張（G3）
csplit -s -z -f /tmp/root- bank-root.pem '/BEGIN CERT/' '{*}'

if ! keytool -importcert -noprompt -alias bank-root-g3 -file /tmp/root-01 \
  -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass > /dev/null 2>&1; then
  echo "（bank-root-g3 沒有加進去：可能已經在 truststore 裡，看下一行）"
fi

rm -f /tmp/root-*
aliases=$(keytool -list \
  -keystore truststore.p12 \
  -storetype PKCS12 \
  -storepass:file ../store.pass 2> /dev/null | grep trustedCertEntry | cut -d, -f1)
echo "truststore：$(echo "$aliases" | paste -sd' ')"

# 3. 派送：truststore 到 10 台
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  scp -q truststore.p12 $h.poc.lab:/tmp/
  ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/'
  ssh $h.poc.lab 'rm -f /tmp/truststore.p12'
done

# 4. C3 的 Prometheus／Alertmanager 用的 ca.pem
scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem
ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem'
ssh c3-01.poc.lab 'rm -f /tmp/ca.pem'

# 5. OP menu 的兩份
install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12
install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem

# 6. 滾動重啟（controller → broker → C3）
bash ~/conf/rolling-restart.sh
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
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
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

### 21.4.3 階段二之一：銀行換上新中繼，自己的伺服器換鏈

@role 銀行 CA 窗口 | Windows 終端 | 本機

銀行 CA 窗口把簽發腳本改用新的中繼（之後簽的 leaf 都附新鏈）；AD、套件庫的憑證檔換成「原本的 leaf＋新中繼」，重啟；新中繼交給小安（放 `~/pki/bank-issuing-new.pem`）：

```bash
cd ~/kafka-lab

# 1. 簽發腳本改用新中繼：舊的（G2 簽的）改名留著，G3 簽的那張換成 issuing.crt
mv ca/g2/issuing.crt ca/g2/issuing-under-g2.crt
cp ca/g2/issuing-g3.crt ca/g2/issuing.crt

# 2. AD：取回現在的憑證檔、換鏈（只留第一張 leaf，後面接上新中繼）、放回去，停掉 samba 讓它重讀（啟動程式會自己再開）
tls=/var/lib/samba/private/tls
ad_cert=ca/exchange/ad01-cert.pem

podman cp lab-ad01-1:$tls/cert.pem "$(cygpath -m "$PWD/$ad_cert")"

sed -n '1,/END CERT/p' $ad_cert > $ad_cert.new
cat ca/g2/issuing.crt >> $ad_cert.new
mv $ad_cert.new $ad_cert

podman cp "$(cygpath -m "$PWD/$ad_cert")" lab-ad01-1:$tls/cert.pem
podman exec lab-ad01-1 chmod 644 $tls/cert.pem
podman exec lab-ad01-1 pkill -x samba
sleep 8

# 3. 套件庫：一樣換鏈（只留第一張 leaf，後面接上新中繼），重啟 httpd
repo_cert=images/web/tls/repo.crt

sed -n '1,/END CERT/p' $repo_cert > $repo_cert.new
cat ca/g2/issuing.crt >> $repo_cert.new
mv $repo_cert.new $repo_cert

podman exec lab-repo01-1 systemctl restart httpd

# 4. 新中繼交給小安
podman cp "$(cygpath -m "$PWD/ca/g2/issuing.crt")" lab-ops02-1:/root/pki/bank-issuing-new.pem

# 5. 從操作機看兩台出示的中繼（第二張）是誰簽的（在操作機執行 EOF 之前的那一段，$1 是主機:埠）
#    拿掉第一張（leaf，第一個 END CERTIFICATE 之前），剩下的第一張就是中繼
for ep in ad01.poc.lab:636 repo01.poc.lab:443; do
  issuer=$(podman exec -i lab-ops02-1 bash -s -- $ep <<'EOF'
after_leaf=$(openssl s_client -connect $1 -showcerts < /dev/null 2> /dev/null | sed '1,/END CERT/d')

echo "$after_leaf" \
  | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname \
  | sed 's/.*CN=//; s/,.*//'
EOF
)

  echo "$ep 中繼的簽發者：$issuer"
done
```

```out
ad01.poc.lab:636 中繼的簽發者：PoC Bank Root CA G3
repo01.poc.lab:443 中繼的簽發者：PoC Bank Root CA G3
```

### 21.4.4 階段二之二：我方的每一張 p12 換鏈

@role 小安 | ops02 | root

先確認銀行給的真的是「同一個中繼、換了簽發者」（名稱、key 和現在 p12 裡的那張相同），再把每張「現在的 leaf＋新中繼」包成 p12，放 `~/pki/next/`。私鑰不動、keystore 密碼不動：

```bash
cd ~/pki
new=bank-issuing-new.pem
anchor=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. 現在 p12 裡的中繼（cp-server.crt 的第二張）和銀行給的新中繼：名稱、key 要相同，只差簽發者
#    拿掉第一張（leaf，第一個 END CERTIFICATE 之前），剩下的就是中繼
current=/tmp/current-issuing.pem
sed '1,/END CERT/d' certs/cp-server.crt > $current

subject=$(openssl x509 -in $current -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')
issuer=$(openssl x509 -in $current -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')
key=$(openssl x509 -in $current -noout -pubkey | sha256sum | cut -c1-12)
echo "現在的中繼：$subject（簽發者 $issuer）key=$key"
rm -f $current

subject=$(openssl x509 -in $new -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')
issuer=$(openssl x509 -in $new -noout -issuer -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')
key=$(openssl x509 -in $new -noout -pubkey | sha256sum | cut -c1-12)
echo "新的中繼：  $subject（簽發者 $issuer）key=$key"

# 2. 每一張：「現在的 leaf＋新中繼」、驗鏈、包成 p12（私鑰與 keystore 密碼都不動），放在 next/certs/
install -d -m 0700 next next/certs

for name in $(awk '{print $1}' requests.txt); do
  sed -n '1,/END CERT/p' certs/$name.crt > next/certs/$name.crt
  cat $new >> next/certs/$name.crt

  if openssl verify -CAfile $anchor -untrusted $new next/certs/$name.crt > /dev/null 2>&1; then
    chain=ok
  else
    chain=FAIL
  fi

  openssl pkcs12 -export -name $name \
    -inkey keys/$name.key \
    -in next/certs/$name.crt \
    -out next/certs/$name.p12 \
    -passout file:store.pass

  chmod 0600 next/certs/$name.p12

  echo "$name: leaf=$(openssl x509 -in next/certs/$name.crt -noout -serial | tail -c 9)（不變） chain=$chain"
done
```

```out
現在的中繼：PoC Bank Issuing CA G2（簽發者 PoC Bank Root CA G2）key=…
新的中繼：  PoC Bank Issuing CA G2（簽發者 PoC Bank Root CA G3）key=…（和上一行相同）
kafka-internal: leaf=7E8C05F2（不變） chain=ok
（9 行，全部 ok）
```

> 名稱或 key 不一樣，就不是換鏈：中繼換了私鑰，leaf 要重簽（走 21.2）。

派送與滾動重啟和 21.2.4 相同，只是確認的方式改成「端點出示的中繼是 G3 簽的」：

```bash
cd ~/pki/next
g3="PoC Bank Root CA G3"

# controller：放新的 kafka-internal.p12、重啟、等 active，再等 9093 出示新鏈（在那台執行 EOF 之前的那一段）
for h in kc01 kc02 kc03; do
  scp -q certs/kafka-internal.p12 $h.poc.lab:/tmp/

  ssh $h.poc.lab bash -s <<'EOF'
sudo install -o root -g confluent -m 0640 /tmp/kafka-internal.p12 /etc/confluent/ssl/
rm -f /tmp/kafka-internal.p12
sudo systemctl restart confluent-server

for i in $(seq 1 30); do
  if systemctl is-active -q confluent-server; then
    break
  fi

  sleep 2
done
EOF

  # 9093 出示的第二張（中繼）是誰簽的：拿掉第一張 leaf，剩下的第一張就是中繼；每 2 秒看一次，最多 30 次
  for i in $(seq 1 30); do
    after_leaf=$(openssl s_client -connect $h.poc.lab:9093 -servername $h.poc.lab -showcerts \
      < /dev/null 2> /dev/null | sed '1,/END CERT/d')
    issuer=$(echo "$after_leaf" | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2> /dev/null \
      | sed 's/.*CN=//; s/,.*//')

    if [ "$issuer" = "$g3" ]; then
      break
    fi

    sleep 2
  done

  # 中繼是 G3 簽的（新鏈）就印 new，否則印 OLD
  if [ "$issuer" = "$g3" ]; then
    result=new
  else
    result=OLD
  fi

  echo "$h $(ssh $h.poc.lab systemctl is-active confluent-server) 9093=$result"
done
```

```out
kc01 active 9093=new
（3 行）
```

broker 接著做，同樣一台健康了才做下一台：

```bash
cd ~/pki/next
g3="PoC Bank Root CA G3"

# broker：放兩個 p12、重啟、等 MDS 回 200；看 9092 與 9095 出示的鏈
for h in kb01 kb02 kb03 kb04; do
  scp -q certs/kafka-internal.p12 certs/cp-server.p12 $h.poc.lab:/tmp/

  ssh $h.poc.lab bash -s <<'EOF'
for f in kafka-internal.p12 cp-server.p12; do
  sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/
done

rm -f /tmp/*.p12
sudo systemctl restart confluent-server
EOF

  # 等那台 MDS（8090）回 200：每 5 秒看一次，最多 60 次
  for i in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  # 9092 出示的第二張（中繼）是 G3 簽的（新鏈）就印 new，否則印 OLD
  after_leaf=$(openssl s_client -connect $h.poc.lab:9092 -servername $h.poc.lab -showcerts \
    < /dev/null 2> /dev/null | sed '1,/END CERT/d')
  issuer=$(echo "$after_leaf" | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2> /dev/null \
    | sed 's/.*CN=//; s/,.*//')

  if [ "$issuer" = "$g3" ]; then
    result_9092=new
  else
    result_9092=OLD
  fi

  # 9095 同樣
  after_leaf=$(openssl s_client -connect $h.poc.lab:9095 -servername $h.poc.lab -showcerts \
    < /dev/null 2> /dev/null | sed '1,/END CERT/d')
  issuer=$(echo "$after_leaf" | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2> /dev/null \
    | sed 's/.*CN=//; s/,.*//')

  if [ "$issuer" = "$g3" ]; then
    result_9095=new
  else
    result_9095=OLD
  fi

  mds_url=https://$h.poc.lab:8090/v1/metadata/id
  echo "$h MDS=$(curl -s -o /dev/null -w '%{http_code}' $mds_url) 9092=$result_9092 9095=$result_9095"
done
```

```out
kb01 MDS=200 9092=new 9095=new
（4 行）
```

REST Proxy 與 C3（C3 的 `svc-c3.key` 沒變，照樣一起放，指令和 21.2.4 一致）：

```bash
cd ~/pki/next
g3="PoC Bank Root CA G3"

# 1. C3：送新鏈的檔（兩把私鑰沒變，照樣一起放），在 c3-01 執行 EOF 之前的那一段：放檔、依序重啟三個服務
scp -q certs/svc-c3.p12 certs/svc-c3.crt ../keys/svc-c3.key c3-01.poc.lab:/tmp/

ssh c3-01.poc.lab bash -s <<'EOF'
for f in svc-c3.p12 svc-c3.crt svc-c3.key; do
  sudo install -o root -g confluent -m 0640 /tmp/$f /etc/confluent/ssl/
done

rm -f /tmp/svc-c3.*

for unit in prometheus alertmanager confluent-control-center; do
  sudo systemctl restart $unit
done
EOF

# 2. 等畫面回 200（每 5 秒看一次，最多 60 次）
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 5
done

# 3. 看 9021、9090 出示的鏈：第二張（中繼）是 G3 簽的（新鏈）就印 new，否則印 OLD
after_leaf=$(openssl s_client -connect c3-01.poc.lab:9021 -servername c3-01.poc.lab -showcerts \
  < /dev/null 2> /dev/null | sed '1,/END CERT/d')
issuer=$(echo "$after_leaf" | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2> /dev/null \
  | sed 's/.*CN=//; s/,.*//')

if [ "$issuer" = "$g3" ]; then
  result_9021=new
else
  result_9021=OLD
fi

after_leaf=$(openssl s_client -connect c3-01.poc.lab:9090 -servername c3-01.poc.lab -showcerts \
  < /dev/null 2> /dev/null | sed '1,/END CERT/d')
issuer=$(echo "$after_leaf" | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2> /dev/null \
  | sed 's/.*CN=//; s/,.*//')

if [ "$issuer" = "$g3" ]; then
  result_9090=new
else
  result_9090=OLD
fi

c3_url=https://c3-01.poc.lab:9021/
echo "c3-01 UI=$(curl -s -o /dev/null -w '%{http_code}' $c3_url) 9021=$result_9021 9090=$result_9090"
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

REST Proxy 照 12.1 一台一台換：新的 `svc-rest.p12` 複製過去、裝好再重啟。

```bash
cd ~/pki/next

# 重啟前在那台要執行的指令：放新的 p12、刪掉 /tmp 的副本（set -e：任何一行失敗就不重啟）
before='set -e
sudo install -o root -g confluent -m 0640 /tmp/svc-rest.p12 /etc/confluent/ssl/
rm -f /tmp/svc-rest.p12'

~/conf/rest-restart.sh rest01 -c "certs/svc-rest.p12" -b "$before"
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
cd ~/pki/next

# 重啟前在那台要執行的指令（同 rest01）
before='set -e
sudo install -o root -g confluent -m 0640 /tmp/svc-rest.p12 /etc/confluent/ssl/
rm -f /tmp/svc-rest.p12'

~/conf/rest-restart.sh rest02 -c "certs/svc-rest.p12" -b "$before"
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
cd ~/pki/next
g3="PoC Bank Root CA G3"

for h in rest01 rest02; do
  # 那個端點出示的第二張（中繼）是誰簽的：拿掉第一張 leaf，剩下的第一張就是中繼
  after_leaf=$(openssl s_client -connect $h.poc.lab:8082 -servername $h.poc.lab -showcerts \
    < /dev/null 2> /dev/null | sed '1,/END CERT/d')
  issuer=$(echo "$after_leaf" | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2> /dev/null \
    | sed 's/.*CN=//; s/,.*//')

  if [ "$issuer" = "$g3" ]; then
    echo "$h 8082=new"
  else
    echo "$h 8082=OLD"
  fi
done
```

```out
rest01 8082=new
rest02 8082=new
```

換成正本：私鑰不動，只換 `.crt`／`.p12`；舊的留在 `~/pki/old-<日期時間>/certs/`（階段三的反向驗證會用到）。緊急身分的 PEM 換到 `~/secrets/svc-ops.pem`；`app-legacy-billing` 的新 p12 交給應用程式團隊，**一定要在階段三之前換上**：

```bash
cd ~/pki
old=old-$(date +%Y%m%d-%H%M)

# 1. 舊的 .crt／.p12 搬到 old-<日期時間>/certs/（私鑰不動），新的放回正本位置；銀行給的新中繼也收進 old-…/
install -d -m 0700 $old/certs

for name in $(awk '{print $1}' requests.txt); do
  mv certs/$name.crt certs/$name.p12 $old/certs/
  install -m 0644 next/certs/$name.crt certs/
  install -m 0600 next/certs/$name.p12 certs/
done

rm -rf next
mv bank-issuing-new.pem $old/

# 2. 操作機自己用的兩個身分馬上試：svc-ops（管理 client）、kafka-internal（查 quorum）
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

echo "svc-ops 管理 client：$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --list 2> /dev/null | wc -l) 個 topic"

echo "kafka-internal 查 quorum：$(kafka-metadata-quorum \
  --bootstrap-controller kc01.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties \
  describe --status 2> /dev/null | grep -o 'LeaderId: *[0-9]*')"

# 3. app-legacy-billing：同一把私鑰，新鏈與舊鏈（G2 還在信任清單裡）都能用；經 LB 打 REST，印 HTTP 狀態碼（同一行）
rest_url=https://rest.poc.lab:8082/v3/clusters

printf 'app-legacy-billing 新鏈：REST=%s' "$(curl -s -o /dev/null -w '%{http_code}' \
  --cert certs/app-legacy-billing.crt \
  --key keys/app-legacy-billing.key \
  $rest_url)"

printf '；舊鏈（G2 還信）：REST=%s\n' "$(curl -s -o /dev/null -w '%{http_code}' \
  --cert $old/certs/app-legacy-billing.crt \
  --key keys/app-legacy-billing.key \
  $rest_url)"
```

```out
svc-ops 管理 client：14 個 topic
kafka-internal 查 quorum：LeaderId: 1
app-legacy-billing 新鏈：REST=200；舊鏈（G2 還信）：REST=200
```

`svc-ops` 的憑證換了，緊急模式用的 PEM 操作機上的 `~/secrets/svc-ops.pem` 也要換（舊的另存 `.prev`，到期前都還有效）：

@role 小安 | ops02 | root

```bash
# 1. 舊的另存 .prev（到期前都還有效）
if [ -f ~/secrets/svc-ops.pem ]; then
  cp -p ~/secrets/svc-ops.pem ~/secrets/svc-ops.prev.pem
fi

# 2. 新的：私鑰＋憑證鏈接成一個 PEM 檔（0600）
install -m 0600 /dev/null ~/secrets/svc-ops.pem
cat ~/pki/keys/svc-ops.key ~/pki/certs/svc-ops.crt > ~/secrets/svc-ops.pem

echo "svc-ops 已更新，序號末 8 碼 $(openssl x509 -in ~/secrets/svc-ops.pem -noout -serial | tail -c 9)"
```

```out
svc-ops 已更新，序號末 8 碼 …
```

進階段三之前，每個端點出示的中繼都要是 G3 簽的（銀行的三台也算）：

@role 小安 | ops02 | root

```bash
# 中繼不是 G3 簽的端點一個一個列出來（銀行的 AD、套件庫也算）
endpoints="kc01.poc.lab:9093 kc02.poc.lab:9093 kc03.poc.lab:9093"
endpoints="$endpoints kb01.poc.lab:9092 kb02.poc.lab:9092 kb03.poc.lab:9092 kb04.poc.lab:9092"
endpoints="$endpoints kb01.poc.lab:9095 kb01.poc.lab:8090 kb01.poc.lab:7071 kc01.poc.lab:7071"
endpoints="$endpoints rest01.poc.lab:8082 rest02.poc.lab:8082 rest01.poc.lab:7071"
endpoints="$endpoints c3-01.poc.lab:9021 c3-01.poc.lab:9090 c3-01.poc.lab:7071"
endpoints="$endpoints ad01.poc.lab:636 repo01.poc.lab:443"

bad=0
for ep in $endpoints; do
  # 那個端點出示的第二張（中繼）是誰簽的（沒有回應就是空的）：拿掉第一張 leaf，剩下的第一張就是中繼
  host=$(echo $ep | cut -d: -f1)
  after_leaf=$(openssl s_client -connect $ep -servername $host -showcerts < /dev/null 2> /dev/null \
    | sed '1,/END CERT/d')
  issuer=$(echo "$after_leaf" | openssl x509 -noout -issuer -nameopt sep_comma_plus,sname 2> /dev/null \
    | sed 's/.*CN=//; s/,.*//')

  if [ "$issuer" != "PoC Bank Root CA G3" ]; then
    if [ -z "$issuer" ]; then
      issuer="（沒有回應）"
    fi

    echo "$ep 中繼的簽發者：$issuer"
    bad=1
  fi
done

if [ $bad = 0 ]; then
  echo "19 個端點都出示新鏈：可以進階段三"
else
  echo "還有端點出示舊鏈：不要進階段三"
  false
fi
```

```out
19 個端點都出示新鏈：可以進階段三
```

### 21.4.5 階段三：拿掉 G2

@role 銀行 OS 團隊 | Windows 終端 | 本機

```bash
cd ~/kafka-lab/ca
new_root=$(cygpath -m "$PWD/g3/root.crt")
anchor=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. 每台主機的 bank-root.pem 換成只有 G3、更新 OS 信任清單；印出裡面有幾張根
for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  podman cp "$new_root" lab-$h-1:/root/bank-root.pem
  podman exec lab-$h-1 install -m 0644 /root/bank-root.pem $anchor
  podman exec lab-$h-1 rm -f /root/bank-root.pem
  podman exec lab-$h-1 update-ca-trust
  printf "%s:%s " $h "$(podman exec lab-$h-1 grep -c 'BEGIN CERT' $anchor)"
done
echo

# 2. AD 的 ca.pem 也只留 G3
podman cp "$new_root" lab-ad01-1:/var/lib/samba/private/tls/ca.pem
podman exec lab-ad01-1 chmod 644 /var/lib/samba/private/tls/ca.pem
```

```out
ops02:1 kc01:1 kc02:1 kc03:1 kb01:1 kb02:1 kb03:1 kb04:1 rest01:1 rest02:1 c3-01:1
```

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

行內 Prometheus 抓 JMX exporter 用的 `ca.pem`（17.5 交給監控團隊的那份）換成只有 G3，重啟 Prometheus，確認 10 個 target 都回到 up。少了這一步，換完憑證之後 Prometheus 就抓不到任何指標（lab 實測：覆蓋率變 0／816）：

```bash
# 1. 銀行 Prometheus 的 ca.pem 換成只有 G3，重啟 Prometheus
cp ~/kafka-lab/ca/g3/root.crt ~/kafka-lab/bank-monitoring/prometheus/confluent/ca.pem
podman restart lab-mon-prometheus > /dev/null

# 2. 等 10 個 target 都回到 up：每 10 秒看一次，最多 12 次
for i in $(seq 1 12); do
  # Prometheus 上 health 是 up 的 target 數
  up=$(podman exec lab-mon-prometheus wget -qO- http://localhost:9090/api/v1/targets 2> /dev/null \
    | grep -o '"health":"up"' | wc -l)

  if [ "$up" = 10 ]; then
    break
  fi

  sleep 10
done

echo "Prometheus target up：$up / 10（約 $((i*10)) 秒）"
```

```out
Prometheus target up：10 / 10（約 70 秒）
```
@role 小安 | ops02 | root

```bash
cd ~/pki/certs

# 1. 操作機 OS 信任清單（現在只有 G3）複製一份到這裡；交給銀行的 to-bank/ 也換成它
cp /etc/pki/ca-trust/source/anchors/bank-root.pem bank-root.pem
cp bank-root.pem ~/monitoring/to-bank/prometheus/ca.pem

# 2. truststore 拿掉 G2 的 alias bank-root-g2
keytool -delete -alias bank-root-g2 -keystore truststore.p12 -storetype PKCS12 -storepass:file ../store.pass
aliases=$(keytool -list \
  -keystore truststore.p12 \
  -storetype PKCS12 \
  -storepass:file ../store.pass 2> /dev/null | grep trustedCertEntry | cut -d, -f1)
echo "truststore：$(echo "$aliases" | paste -sd' ')"

# 3. 派送：truststore 到 10 台
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  scp -q truststore.p12 $h.poc.lab:/tmp/
  ssh $h.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/truststore.p12 /etc/confluent/ssl/'
  ssh $h.poc.lab 'rm -f /tmp/truststore.p12'
done

# 4. C3 的 Prometheus／Alertmanager 用的 ca.pem
scp -q bank-root.pem c3-01.poc.lab:/tmp/ca.pem
ssh c3-01.poc.lab 'sudo install -o root -g confluent -m 0640 /tmp/ca.pem /etc/confluent/ssl/ca.pem'
ssh c3-01.poc.lab 'rm -f /tmp/ca.pem'

# 5. OP menu 的兩份
install -m 0644 truststore.p12 /etc/opmenu/ssl/truststore.p12
install -m 0644 bank-root.pem /etc/opmenu/ssl/ca.pem

# 6. 滾動重啟（controller → broker → C3）
bash ~/conf/rolling-restart.sh
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
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
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
cd ~/pki
last=$(ls -d old-* | tail -1)   # 21.4.4 換鏈時留下的那一份（舊鏈）

# 1. 同一張 leaf、同一把私鑰：配舊鏈要被拒、配新鏈要通過；經 LB 打 REST，印 HTTP 狀態碼（000 = TLS 就被拒絕）
rest_url=https://rest.poc.lab:8082/v3/clusters

echo "舊鏈 → REST：$(curl -s -o /dev/null -w '%{http_code}' \
  --cert $last/certs/app-legacy-billing.crt \
  --key keys/app-legacy-billing.key \
  $rest_url)（000 = TLS 直接拒絕）"

echo "新鏈 → REST：$(curl -s -o /dev/null -w '%{http_code}' \
  --cert certs/app-legacy-billing.crt \
  --key keys/app-legacy-billing.key \
  $rest_url)"

# 2. AD、套件庫照常
password=$(cat ~/secrets/ad-test-users.pass)
echo "alice 登入 MDS（MDS 要用 LDAPS 連 AD）：$(curl -s -o /dev/null -w '%{http_code}' \
  -u alice:$password \
  https://kb01.poc.lab:8090/security/1.0/authenticate)"
unset password

echo "套件庫：$(curl -s -o /dev/null -w '%{http_code}' https://repo01.poc.lab/confluent/repodata/repomd.xml)"
```

```out
舊鏈 → REST：000（000 = TLS 直接拒絕）
新鏈 → REST：200
alice 登入 MDS（MDS 要用 LDAPS 連 AD）：200
套件庫：200
```

> 實測（2026-10-25，lab，接在 21.3 之後做）：三個階段 12 塊指令全部一次通過；換鏈期間 REST、MDS、C3 都維持 200，舊鏈與新鏈的應用程式憑證在階段二都能用，階段三之後舊鏈被拒。銀行端（Windows 的 openssl）算出的 key 雜湊和操作機算的不同，是 PEM 換行字元不同造成的，各自那一邊的兩行相同就對了。

> 這就是 21.0 說的「拿掉舊根一定排在每個端點都換好鏈之後」：舊鏈的 leaf 本身沒問題，被拒是因為它夾帶的中繼指向已經不信的 G2。應用程式（REST 走 mTLS 的那些）的 p12 也一樣要換鏈，否則階段三那一刻就斷。

# 22. 第二十二站：憑證到期監控（選配）

下面這張圖是兩層監控加上選單：銀行 Prometheus 用 blackbox_exporter 探每個端點「實際出示」的憑證；操作機每天讀我方持有的每一張；OP menu 17 隨時看。

![certexpiry]

**這一章在做什麼**：第 9 章的憑證一年到期（9.3 看到 `days=364`），到期那一刻 broker 之間、REST Proxy、C3、應用程式全部連不上；第 21 章是怎麼換，這一章是**怎麼提前知道**。做兩層：22.2 銀行 Prometheus 的 blackbox_exporter 探平台的每個 TLS 端點，剩 60 天 warning、14 天 critical；22.3 操作機每天一次讀 `~/pki/certs` 全部憑證（含 blackbox 看不到、不對外的 client 憑證與信任的根），寫 syslog。客戶目前沒有 blackbox_exporter，22.2 列為建議（問題清單 11.10）；22.3 與選單 17 沒有前提。lab 兩層都建、都驗。前提：第 17 章接上了、第 9 章的憑證在 `~/pki/certs`。完成的樣子：Prometheus 的 `cert-expiry` job 24 個 target 全 up、規則 29 條（第 17 章 26 條加這一章 3 條）、`promtool test rules` 通過；操作機腳本列出每張憑證剩幾天、timer 裝好。

## 22.1 要看哪些憑證

@role 小安 | ops02 | root

| 憑證 | 誰出示 | blackbox 探得到？ | 操作機腳本 |
|---|---|---|---|
| `kafka-internal` | controller 9093、broker 9092 | 探得到（mTLS 的 listener 也會先出示自己的憑證） | 有 |
| `cp-server`、`svc-rest`、`svc-c3` | broker 9094／9095／8090（cp-server；9096 是同一張，不另外探）、REST 8082 兩台＋LB（svc-rest）、C3 9021（svc-c3） | 探得到 | 有 |
| 同上兩張（7071 與 C3 9090） | 每台的 7071（JMX exporter，第 17 章：各用該元件自己的那張）、C3 內建 Prometheus 9090 | 不另外探：和上面兩列是同一張憑證、同一個到期日；7071 過期時銀行 Prometheus 本來就抓不到，`ConfluentTargetDown` 會響 | 有（同一個檔） |
| `svc-ops`、`svc-backup`、app 憑證 | client 憑證，不對外 | 探不到 | 有（`~/pki/certs/*.crt`） |
| 銀行根、中繼（truststore；`bank-root.pem`） | — | 探到的是鏈裡最早到期的那一張（`probe_ssl_earliest_cert_expiry`） | 有（`bank-root.pem`） |
| AD 的 LDAPS 憑證 | ad01 636 | 探得到（銀行的，順便看；它到期 MDS 就查不到 AD） | 無 |

## 22.2 銀行 Prometheus：blackbox_exporter 探端點

@role 小安 | ops02 | root

給銀行監控團隊四個檔，放到 17.5 的 `to-bank/prometheus/`：blackbox 的模組設定（TCP＋TLS 握手、用銀行根驗鏈）、Prometheus 的 scrape 檔（每個端點一個 target，經 exporter 的 `/probe`）、規則（三條）、規則的單元測試。exporter 的位址 `BLACKBOX-EXPORTER:9115` 由銀行換成自己的；lab 之後換成容器名稱：

```bash
cd ~/monitoring/to-bank/prometheus

# 1. blackbox 的模組：TCP 連上後做 TLS 握手，用銀行根驗憑證鏈
cat > blackbox.yml <<'EOF'
modules:
  tls:
    prober: tcp
    timeout: 10s
    tcp:
      tls: true
      tls_config:
        ca_file: /etc/prometheus/confluent/ca.pem
EOF

# 2. 要探的端點，組成 YAML 清單的寫法："主機:埠", "主機:埠", …
targets=""
for h in kc01 kc02 kc03; do
  targets="$targets\"$h.poc.lab:9093\", "
done

for h in kb01 kb02 kb03 kb04; do
  targets="$targets\"$h.poc.lab:9092\", \"$h.poc.lab:9094\", \"$h.poc.lab:9095\", \"$h.poc.lab:8090\", "
done

targets="$targets\"rest01.poc.lab:8082\", \"rest02.poc.lab:8082\", \"rest.poc.lab:8082\", "
targets="$targets\"c3-01.poc.lab:9021\", \"ad01.poc.lab:636\""

# 3. scrape 設定：每個端點一個 target，經 exporter 的 /probe（EOF 沒加引號：$targets 會換成上面那一串）
cat > scrape-blackbox.yml <<EOF
scrape_configs:
  - job_name: cert-expiry
    metrics_path: /probe
    params: { module: [ tls ] }
    scrape_interval: 5m
    scrape_timeout: 30s
    static_configs: [ { targets: [ $targets ], labels: { env: lab } } ]
    relabel_configs:
      - { source_labels: [__address__], target_label: __param_target }
      - { source_labels: [__param_target], target_label: instance }
      - { target_label: __address__, replacement: BLACKBOX-EXPORTER:9115 }
EOF

# 4. 確認：scrape 檔裡有幾個端點、blackbox.yml 有幾個模組
endpoints=$(grep -o '"[^"]*:[0-9]*"' scrape-blackbox.yml | wc -l)
modules=$(awk '/prober/ {c++} END {print c + 0}' blackbox.yml)
echo "scrape-blackbox.yml：$endpoints 個端點；blackbox.yml：$modules 個模組"
```

```out
scrape-blackbox.yml：24 個端點；blackbox.yml：1 個模組
```

規則：`probe_ssl_earliest_cert_expiry` 是端點出示的鏈裡最早到期那張的 unix 時間；剩不到 60 天 warning（`for: 1h`，避免 exporter 抖一下就叫人）、不到 14 天 critical；`probe_success` 0 是探不到（服務掛了、或憑證已經不被信任）。整段貼到 EOF：

```bash
cat > ~/monitoring/to-bank/prometheus/confluent-alerts-cert.yml <<'EOF'
# Certificate expiry rules for the bank's Prometheus (guide, chapter 22.2). Needs the blackbox_exporter job in scrape-blackbox.yml
# (job="cert-expiry", one target per TLS endpoint). Loaded next to confluent-alerts.yml (rule_files: confluent-alerts*.yml).
groups:
  - name: cert-expiry
    rules:
      # source: ours. probe_ssl_earliest_cert_expiry = expiry (unix time) of the earliest-expiring certificate in the chain the endpoint presented.
      - alert: CertificateExpiringSoon
        expr: (probe_ssl_earliest_cert_expiry{job="cert-expiry"} - time()) / 86400 < 60
        for: 1h
        labels: { severity: warning, impact: INFRASTRUCTURE }
        annotations:
          summary: "{{ $labels.instance }}: certificate expires in {{ $value | printf \"%.0f\" }} days"
          description: "The certificate presented by {{ $labels.instance }} expires in {{ $value | printf \"%.0f\" }} days. Plan the renewal now (guide chapter 21: leaf 21.2, CA 21.3, chain 21.4); the whole cluster shares cp-server / kafka-internal, so one alert usually means all endpoints."
      - alert: CertificateExpiringCritical
        expr: (probe_ssl_earliest_cert_expiry{job="cert-expiry"} - time()) / 86400 < 14
        for: 10m
        labels: { severity: critical, impact: SERVICE }
        annotations:
          summary: "{{ $labels.instance }}: certificate expires in {{ $value | printf \"%.0f\" }} days"
          description: "Less than 14 days left on the certificate presented by {{ $labels.instance }}. When it expires every TLS client (brokers between themselves, REST Proxy, C3, applications) stops connecting. Renew immediately (guide chapter 21)."
      # source: ours. The probe itself failed: endpoint down, TLS handshake broken (expired / untrusted certificate), or the exporter cannot reach it.
      - alert: CertificateProbeFailed
        expr: probe_success{job="cert-expiry"} == 0
        for: 10m
        labels: { severity: warning, impact: INFRASTRUCTURE }
        annotations:
          summary: "{{ $labels.instance }}: TLS probe failed"
          description: "blackbox_exporter could not complete a TLS handshake with {{ $labels.instance }} for 10 minutes: the service is down (see ConfluentTargetDown) or its certificate is no longer valid for the bank root CA the exporter trusts (expired, or the CA changed: guide 21.3)."
EOF

rules_file=~/monitoring/to-bank/prometheus/confluent-alerts-cert.yml
echo "confluent-alerts-cert.yml: $(grep -c '^      - alert:' $rules_file) 條規則"
```

```out
confluent-alerts-cert.yml: 3 條規則
```

規則不用等一年才知道對不對：Prometheus 自帶的 `promtool test rules` 餵假的時間序列（400 天、30 天、5 天、探不到）看三條規則各自要不要響。這個檔也交給銀行，他們改閾值後自己重測：

```bash
cat > ~/monitoring/to-bank/prometheus/cert-expiry-rules-test.yml <<'EOF'
rule_files:
  - confluent-alerts-cert.yml
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'probe_ssl_earliest_cert_expiry{job="cert-expiry", instance="a.poc.lab:9094", env="lab"}'
        values: '34560000x90'
      - series: 'probe_ssl_earliest_cert_expiry{job="cert-expiry", instance="b.poc.lab:9094", env="lab"}'
        values: '2592000x90'
      - series: 'probe_ssl_earliest_cert_expiry{job="cert-expiry", instance="c.poc.lab:9094", env="lab"}'
        values: '432000x90'
      - series: 'probe_success{job="cert-expiry", instance="d.poc.lab:9094", env="lab"}'
        values: '0x90'
    alert_rule_test:
      - eval_time: 61m
        alertname: CertificateExpiringSoon
        exp_alerts:
          - exp_labels: { severity: warning, impact: INFRASTRUCTURE, job: cert-expiry, instance: "b.poc.lab:9094", env: lab }
            exp_annotations: { summary: "b.poc.lab:9094: certificate expires in 30 days", description: "The certificate presented by b.poc.lab:9094 expires in 30 days. Plan the renewal now (guide chapter 21: leaf 21.2, CA 21.3, chain 21.4); the whole cluster shares cp-server / kafka-internal, so one alert usually means all endpoints." }
          - exp_labels: { severity: warning, impact: INFRASTRUCTURE, job: cert-expiry, instance: "c.poc.lab:9094", env: lab }
            exp_annotations: { summary: "c.poc.lab:9094: certificate expires in 5 days", description: "The certificate presented by c.poc.lab:9094 expires in 5 days. Plan the renewal now (guide chapter 21: leaf 21.2, CA 21.3, chain 21.4); the whole cluster shares cp-server / kafka-internal, so one alert usually means all endpoints." }
      - eval_time: 11m
        alertname: CertificateExpiringCritical
        exp_alerts:
          - exp_labels: { severity: critical, impact: SERVICE, job: cert-expiry, instance: "c.poc.lab:9094", env: lab }
            exp_annotations: { summary: "c.poc.lab:9094: certificate expires in 5 days", description: "Less than 14 days left on the certificate presented by c.poc.lab:9094. When it expires every TLS client (brokers between themselves, REST Proxy, C3, applications) stops connecting. Renew immediately (guide chapter 21)." }
      - eval_time: 11m
        alertname: CertificateProbeFailed
        exp_alerts:
          - exp_labels: { severity: warning, impact: INFRASTRUCTURE, job: cert-expiry, instance: "d.poc.lab:9094", env: lab }
            exp_annotations: { summary: "d.poc.lab:9094: TLS probe failed", description: "blackbox_exporter could not complete a TLS handshake with d.poc.lab:9094 for 10 minutes: the service is down (see ConfluentTargetDown) or its certificate is no longer valid for the bank root CA the exporter trusts (expired, or the CA changed: guide 21.3)." }
EOF
ls ~/monitoring/to-bank/prometheus/
```

```out
blackbox.yml
ca.pem
cert-expiry-rules-test.yml
confluent-alerts-cert.yml
confluent-alerts.yml
scrape-blackbox.yml
scrape-confluent.yml
```

（第 24 章做完後會再多一個 `confluent-alerts-disk.yml`。）

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

正式環境：銀行起自己的 blackbox_exporter（映像檔 `prom/blackbox-exporter`，和 Prometheus 一樣是銀行的），`scrape-blackbox.yml` 放進 `scrape_config_files`、規則放進 `rule_files`，先 `promtool test rules`。lab：exporter 用容器 `lab-mon-blackbox`（主機名稱要 `--add-host`，和 17.6 的 Prometheus 一樣），`prometheus.yml` 的 `scrape_config_files` 改成 `scrape-*.yml`（單檔 bind mount，改了要 restart）：

```bash
cd ~/kafka-lab/bank-monitoring
mkdir -p blackbox

# 1. 從操作機取出 to-bank/prometheus/，放成 lab 容器要的樣子（exporter 的位址換成容器名稱）
podman cp lab-ops02-1:/root/monitoring/to-bank/prometheus "$(cygpath -m "$PWD/to-bank-prom")"
cp to-bank-prom/blackbox.yml blackbox/
cp to-bank-prom/scrape-blackbox.yml prometheus/confluent/
cp to-bank-prom/confluent-alerts-cert.yml prometheus/confluent/
cp to-bank-prom/cert-expiry-rules-test.yml prometheus/confluent/
rm -rf to-bank-prom
sed -i 's/BLACKBOX-EXPORTER:9115/lab-mon-blackbox:9115/' prometheus/confluent/scrape-blackbox.yml

# 2. exporter 要認得各主機的名稱：每台一個 --add-host（寫法：主機:IP 的最後一段）
hosts=""
entries="kc01:21 kc02:22 kc03:23 kb01:31 kb02:32 kb03:33 kb04:34"
entries="$entries rest01:41 rest02:42 c3-01:51 ad01:11 lb01:12 rest:12"

for entry in $entries; do
  name=$(echo $entry | cut -d: -f1)
  last=$(echo $entry | cut -d: -f2)
  hosts="$hosts --add-host $name.poc.lab:172.35.0.$last"
done

# 3. 起 blackbox_exporter（舊的有的話先移除）
blackbox_conf=$(cygpath -m "$PWD/blackbox/blackbox.yml")
confluent_dir=$(cygpath -m "$PWD/prometheus/confluent")

podman rm -f --ignore lab-mon-blackbox > /dev/null
podman run -d --restart unless-stopped \
  --name lab-mon-blackbox \
  --network lab_labnet \
  --memory 64m \
  $hosts \
  -v "$blackbox_conf:/etc/blackbox_exporter/config.yml:ro" \
  -v "$confluent_dir:/etc/prometheus/confluent:ro" \
  prom/blackbox-exporter:v0.25.0 \
  --config.file=/etc/blackbox_exporter/config.yml > /dev/null

# 4. Prometheus 改讀 scrape-*.yml 與 confluent-alerts*.yml，重啟，等它就緒（每 5 秒看一次，最多 12 次）
old_scrape='scrape_config_files: \[ /etc/prometheus/confluent/scrape-confluent.yml \]'
new_scrape='scrape_config_files: [ /etc/prometheus/confluent/scrape-*.yml ]'
sed -i "s#$old_scrape#$new_scrape#" prometheus/prometheus.yml
sed -i 's#confluent/confluent-alerts\.yml#confluent/confluent-alerts*.yml#' prometheus/prometheus.yml
podman restart lab-mon-prometheus > /dev/null

for i in $(seq 1 12); do
  if podman exec lab-mon-prometheus wget -qO- http://localhost:9090/-/ready 2> /dev/null | grep -q Ready; then
    break
  fi

  sleep 5
done

blackbox_state=$(podman inspect -f '{{.State.Status}}' lab-mon-blackbox)
wildcard_lines=$(awk '/scrape-\*.yml/ {c++} END {print c + 0}' prometheus/prometheus.yml)
echo "lab-mon-blackbox：$blackbox_state；prometheus.yml：$wildcard_lines 行用萬用字元"
```

```out
lab-mon-blackbox：running；prometheus.yml：1 行用萬用字元
```

驗三件事：`promtool test rules` 通過（在 Prometheus 容器裡跑，它自帶 promtool）、`cert-expiry` 的 target 全 up（第一次抓要等一個 `scrape_interval`，最多 5 分鐘）、規則 29 條載入沒錯：

```bash
# 1. promtool test rules（在 Prometheus 容器裡跑，它自帶 promtool）
podman exec -w /etc/prometheus/confluent lab-mon-prometheus sh -c \
  'promtool test rules cert-expiry-rules-test.yml 2>&1 | grep -oE "SUCCESS|FAIL" | head -1'

# 2. 等 24 個 target 全 up、規則載入沒錯：每 10 秒看一次，最多 36 次（第一次抓要等一個 scrape_interval）
#    每一次都在 labnet 上起一個臨時容器（執行 EOF 之前的那一段），印 cert-expiry 的 target 數與規則數
for i in $(seq 1 36); do
  status=$(podman run --rm -i --network lab_labnet lab-node:96 bash -s <<'EOF'
curl -s http://lab-mon-prometheus:9090/api/v1/targets | python3 -c '
import json, sys
t = [x for x in json.load(sys.stdin)["data"]["activeTargets"] if x["labels"]["job"] == "cert-expiry"]
print("cert-expiry target up %d / %d" % (sum(x["health"] == "up" for x in t), len(t)))'

curl -s http://lab-mon-prometheus:9090/api/v1/rules | python3 -c '
import json, sys
g = json.load(sys.stdin)["data"]["groups"]
r = [x for y in g for x in y["rules"]]
print("告警規則 %d 條（%s），載入有錯 %d 條" % (len(r), "、".join(y["name"] for y in g), sum(x["health"] != "ok" for x in r)))'
EOF
)

  if echo "$status" | grep -q "target up 24 / 24"; then
    if echo "$status" | grep -q "載入有錯 0 條"; then
      break
    fi
  fi

  sleep 10
done

echo "$status"
```

```out
SUCCESS
cert-expiry target up 24 / 24
告警規則 29 條（cert-expiry、confluent-availability、control-center、host、jvm、kafka-broker、kraft、rest-proxy），載入有錯 0 條
```

每個端點真的探到了什麼：剩幾天、哪一張（Grafana 做一張表就是同一個查詢）：

```bash
# 在 labnet 上起一個臨時容器，執行 EOF 之前的那一段：問 Prometheus 每個端點剩幾天，排好印出
podman run --rm -i --network lab_labnet lab-node:96 bash -s <<'EOF'
query='(probe_ssl_earliest_cert_expiry{job="cert-expiry"} - time()) / 86400'
curl -s --data-urlencode "query=$query" http://lab-mon-prometheus:9090/api/v1/query | python3 -c '
import json, sys
rs = sorted(json.load(sys.stdin)["data"]["result"], key=lambda r: r["metric"]["instance"])
for r in rs: print("%-24s 剩 %3d 天" % (r["metric"]["instance"], float(r["value"][1])))
print("合計 %d 個端點" % len(rs))'
EOF
```

```out
ad01.poc.lab:636         剩 364 天
c3-01.poc.lab:9021       剩 364 天
（…）
rest.poc.lab:8082        剩 364 天
合計 24 個端點
```

> 第 21 章換發之後，這張表就是「每一台都換到了嗎」的證據（21.2.5 用 `openssl s_client` 逐台看的是同一件事）。換 CA（21.3）時 exporter 用的 `ca.pem` 要跟著換，否則 `CertificateProbeFailed` 會全部響——21.3／21.4 已經有換 Prometheus `ca.pem` 的步驟，blackbox 讀同一個檔。

## 22.3 操作機每天讀一次我方持有的憑證

@role 小安 | ops02 | root

blackbox 看不到 client 憑證（svc-ops、svc-backup、app 的），它們到期一樣會出事（備份停、選單登不進、REST 應用程式被拒）。操作機上這支小腳本和 26.2 的 license 檢查同一個樣子：每張憑證剩幾天，剩不到 60 天 `warning` 寫 syslog（tag `confluent-cert`），過期或讀不到 `err`；結束碼 0／2／1：

```bash
cat > ~/conf/cert-expiry.sh <<'EOF'
#!/usr/bin/env bash
# cert-expiry.sh [目錄…] — 每天檢查一次我方持有的憑證還剩幾天
# 做什麼：讀每一張憑證（預設 ~/pki/certs 的 *.crt、*.pem，含不對外、blackbox 探不到的 client 憑證）與信任的根，
#   剩不到 WARN_DAYS 天寫 syslog warning（tag confluent-cert），過期或讀不到寫 err
# 用到的設定：環境變數 WARN_DAYS（預設 60）
# 結束碼：0 正常、2 有快到期、1 有過期或讀不到（systemd 那邊用 SuccessExitStatus=2，快到期不算服務失敗）
# 改的時候要注意：輸出與 syslog 的文字（「快到期：…」「已過期：…」「檢查了 N 張憑證，結束碼 N」）手冊的預期輸出有用到

warn_days=${WARN_DAYS:-60}
dirs=${*:-/root/pki/certs}
now=$(date +%s)
rc=0
count=0

# cert_files：要檢查的檔案：每個目錄的 *.crt、*.pem，排好順序、去掉重複
cert_files() {
  local d
  for d in $dirs; do
    ls "$d"/*.crt "$d"/*.pem 2> /dev/null
  done | sort -u
}

for f in $(cert_files); do
  # MDS token 的公鑰不是 CA 簽的憑證，沒有到期日
  case $f in
    *mds-token-public.pem) continue ;;
  esac

  # 1. 到期日；讀不到就記 err，換下一張
  end=$(openssl x509 -in "$f" -noout -enddate 2> /dev/null | cut -d= -f2)

  if [ -z "$end" ]; then
    logger -t confluent-cert -p user.err "讀不到憑證：$f"
    echo "讀不到：$f"
    rc=1
    continue
  fi

  # 2. 剩幾天、CN
  count=$((count + 1))
  days=$(( ($(date -d "$end" +%s) - now) / 86400 ))
  # 主旨裡的 CN，例：subject=C=TW,O=Bank,CN=svc-ops → svc-ops
  cn=$(openssl x509 -in "$f" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=//; s/,.*//')
  msg="$(basename "$f")（CN=$cn）到期 $(date -d "$end" +%F)，剩 $days 天"

  # 3. 過期 → err；快到期 → warning（結束碼還是 0 的話改成 2）；其他照印
  if [ "$days" -lt 0 ]; then
    logger -t confluent-cert -p user.err "已過期：$msg"
    echo "已過期：$msg"
    rc=1
  elif [ "$days" -lt "$warn_days" ]; then
    logger -t confluent-cert -p user.warning "快到期：$msg"
    echo "快到期：$msg"

    if [ $rc = 0 ]; then
      rc=2
    fi
  else
    echo "$msg"
  fi
done

logger -t confluent-cert -p user.info "檢查了 $count 張憑證，結束碼 $rc"
echo "檢查了 $count 張憑證，結束碼 $rc"
exit $rc
EOF

chmod 0700 ~/conf/cert-expiry.sh

# 試跑一次（結束碼 2 = 有快到期，不算失敗，所以用 if 接住結束碼）
if bash ~/conf/cert-expiry.sh; then
  rc=0
else
  rc=$?
fi
echo "rc=$rc"
```

```out
app-legacy-billing.crt（CN=app-legacy-billing）到期 2027-10-28，剩 364 天
（…每張一行：7 張平台憑證加銀行根憑證）
檢查了 8 張憑證，結束碼 0
rc=0
```

閾值和過期的分支也要試過才算：拿一個暫存目錄放一張 5 天到期的自簽憑證和一張已過期的，跑同一支腳本，看 rc 與 syslog。已過期的那張用 `openssl ca -startdate／-enddate` 指定起訖日（`openssl req -x509` 的 `-not_after` 要 OpenSSL 3.4 以上，OS 9.6 是 3.2.2；暫存的 CA 檔放在子目錄 `ca/`，腳本不會掃到）。任何一張沒做出來，整段就停下，不會只測到一張：

```bash
tmp=$(mktemp -d)
mkdir $tmp/ca

# 1. 5 天後到期的自簽憑證
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout $tmp/k.key \
  -subj "/CN=soon-test" \
  -days 5 \
  -out $tmp/soon.crt 2> /dev/null

# 2. 已經過期的憑證：用 openssl ca 指定起訖日（暫存的 CA 檔放在子目錄 ca/，腳本不會掃到；EOF 沒加引號，$tmp 會換成值）
openssl req -new -newkey rsa:2048 -nodes -keyout $tmp/ca/k2.key -subj "/CN=expired-test" -out $tmp/ca/e.csr 2> /dev/null
touch $tmp/ca/index.txt
echo 01 > $tmp/ca/serial

cat > $tmp/ca/ca.cnf <<EOF
[ca]
default_ca=c
[c]
database=$tmp/ca/index.txt
new_certs_dir=$tmp/ca
serial=$tmp/ca/serial
default_md=sha256
policy=p
[p]
commonName=supplied
EOF

openssl ca -batch -config $tmp/ca/ca.cnf -selfsign -keyfile $tmp/ca/k2.key -in $tmp/ca/e.csr \
  -startdate 20260101000000Z -enddate 20260110000000Z -notext -out $tmp/expired.crt 2> /dev/null

# 3. 對這個暫存目錄跑腳本：要看到一張已過期、一張快到期，結束碼 1
if bash ~/conf/cert-expiry.sh $tmp; then
  rc=0
else
  rc=$?
fi
echo "rc=$rc"
rm -rf $tmp

# 4. syslog 裡最近的三筆
echo "syslog 最近三筆如下"
journalctl -t confluent-cert -n 3 --no-pager -o cat
```

```out
已過期：expired.crt（CN=expired-test）到期 2026-01-10，剩 -291 天
快到期：soon.crt（CN=soon-test）到期 2026-11-03，剩 4 天
檢查了 2 張憑證，結束碼 1
rc=1
syslog 最近三筆如下
已過期：expired.crt（CN=expired-test）到期 2026-01-10，剩 -291 天
快到期：soon.crt（CN=soon-test）到期 2026-11-03，剩 4 天
檢查了 2 張憑證，結束碼 1
```

排程：和 26.2 一樣的 systemd timer，每天 08:10（license 是 08:00）。行內有排程系統就改由它呼叫 `~/conf/cert-expiry.sh`，看結束碼與 syslog：

```bash
# 1. service：跑一次腳本（結束碼 2 = 有快到期，不算服務失敗）
cat > /etc/systemd/system/confluent-cert-expiry.service <<'EOF'
[Unit]
Description=Confluent certificate expiry check

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/root/conf/cert-expiry.sh
SuccessExitStatus=2
EOF

# 2. timer：每天 08:10（關機錯過的，開機後補跑）
cat > /etc/systemd/system/confluent-cert-expiry.timer <<'EOF'
[Unit]
Description=Daily Confluent certificate expiry check

[Timer]
OnCalendar=*-*-* 08:10:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 3. 啟用 timer，並馬上跑一次
systemctl daemon-reload
systemctl enable --now confluent-cert-expiry.timer > /dev/null 2>&1
systemctl start confluent-cert-expiry.service

echo "下次執行：$(systemctl show confluent-cert-expiry.timer -p NextElapseUSecRealtime --value)"
echo "syslog：$(journalctl -t confluent-cert -n 1 --no-pager -o cat)"
```

```out
下次執行：Thu 2026-10-30 08:10:00 CST
syslog：檢查了 8 張憑證，結束碼 0
```

## 22.4 告警響了做什麼

@role 維運人員 | ops02 | root

| 訊號 | 意思 | 做什麼 |
|---|---|---|
| `CertificateExpiringSoon`（剩 < 60 天）或 syslog `快到期` | 該排換發了 | 第 21 章：同一個 CA 換 leaf（21.2）；銀行說要換根或中繼才是 21.3／21.4。整個平台共用 `cp-server`、`kafka-internal`，一條告警通常代表全部 |
| `CertificateExpiringCritical`（< 14 天） | 來不及走正常變更流程就要出事 | 立刻換；換不及就先和銀行 CA 要一張短效的 |
| `CertificateProbeFailed` | 探不到：服務掛了（看 `ConfluentTargetDown`）或憑證已經不被 exporter 信任（過期、換了 CA 沒更新 `ca.pem`） | 先 28.2 快照分辨是服務還是憑證 |
| 選單 17 顯示「剩不到 30 天」 | 維運人員隨時能看；30 天是選單畫面的提醒色，排換發以上面 60 天的告警為準 | — |

> 誰負責看：規則與 syslog 都進銀行的監控／SIEM，告警到平台維運；換發是平台的變更單，CA 窗口要先排。不要把「到期日」只記在某個人的行事曆。


# 23. 第二十三站：日常備份與還原

下面這張圖說明每天的匯出流程，以及三類備份各自的處理方式。

![backup]

**這一章在做什麼**：每天自動把叢集的「設定類」中繼資料（誰有什麼權限、有哪些 topic 與設定）匯出成文字檔，遇到誤刪時能照著重建。訊息本身不備份。前提：第 9 章已發 `svc-backup` 憑證、第 10 章的 `access.rule.providers` 有開 `KRAFT_ACL`。順序：建專用的唯讀身分（23.1、23.2）→ 匯出腳本（23.3）→ 排程（23.4）→ 怎麼比對（23.5）→ 還原演練（23.6）。完成的樣子：`~/backup/metadata/<時間>/` 每天多一份、每個檔都有內容，syslog 有 tag `confluent-backup` 的成功紀錄。

要備份的東西分成三類，各走各的路：

| 類別 | 內容 | 怎麼備 | 誰做 |
|---|---|---|---|
| 叢集中繼資料 | RBAC、ACL、topic 與設定、SCRAM 帳號清單與配額、features、broker 動態設定 | 操作機每天排程匯出（本章），保留 30 天；變更前另外手動跑一次當快照 | 小安裝好之後自動跑 |
| 各台的設定 | `/etc/confluent`、systemd drop-in、`/etc/kafka` 的 log4j2 | 銀行既有的主機備份系統（操作機的排程只匯出 Kafka 的中繼資料，不 ssh 進各台） | 銀行主機團隊 |
| 機敏資料 | `~/pki` 的私鑰、`~/secrets`、master key | **不在這支排程裡**：由銀行的備份機制備份操作機的 `~/pki`、`~/secrets`（要加密）；`/secure/ssh` 的私鑰依第 4 章不備份 | 銀行備份團隊 |

訊息本身不做檔案備份：叢集內靠 replication factor 3、`min.insync.replicas=2`；異地備援（Cluster Linking）依銀行的 RPO／RTO 另議。

匯出用的身分是新發的 `svc-backup` 憑證，**只能看、不能改、讀不到訊息內容**。不用 SystemAdmin 的 `svc-ops`：排程每天自動跑，身分越小越好。

## 23.1 svc-backup 的 client 設定

@role 小安 | ops02 | root

`svc-backup` 憑證在第 9 章已經和其他憑證一起發了（`~/pki/certs/svc-backup.p12`）。client 設定從管理用的那份複製，換成 svc-backup 的 keystore：

```bash
# 1. 管理用的那份複製一份，keystore 換成 svc-backup 的（檔案 0600）
install -m 0600 /dev/null ~/conf/client-backup.properties
sed 's#/svc-ops.p12#/svc-backup.p12#' ~/conf/client-admin.properties > ~/conf/client-backup.properties

# 2. 確認：指向 svc-backup 的地方、憑證的 CN、剩幾天
crt=~/pki/certs/svc-backup.crt
pointing=$(awk '/svc-backup/ {c++} END {print c + 0}' ~/conf/client-backup.properties)

# 主旨裡的 CN，例：subject=C=TW,O=Bank,CN=svc-backup → svc-backup
cn=$(openssl x509 -in $crt -noout -subject -nameopt sep_comma_plus,sname | grep -o 'CN=[^,]*' | cut -d= -f2)

# 到期日換算成還有幾天
end=$(openssl x509 -in $crt -noout -enddate | cut -d= -f2)
days_left=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))

echo "client-backup.properties：$pointing 處指向 svc-backup；憑證 $cn，剩 $days_left 天"
```

```out
client-backup.properties：1 處指向 svc-backup；憑證 svc-backup，剩 364 天
```

## 23.2 最小權限：SecurityAdmin＋兩條 ACL

@role 小安 | ops02 | root

每一項要什麼權限、怎麼給（lab 逐項試過，2026-10-25）：

| 要匯出的 | 需要的操作 | 給法 |
|---|---|---|
| role binding | MDS 查詢 | RBAC `SecurityAdmin`（只能看：`DescribeAccess`、`SecurityMetadata Describe`；試建 binding 回 403） |
| topic 清單與設定、partition 分布 | Topic 的 `Describe`、`DescribeConfigs` | KRaft ACL（第 10 章 `access.rule.providers` 有開 `KRAFT_ACL`） |
| SCRAM 帳號清單、配額、broker 動態設定、ACL 清單 | Cluster 的 `Describe`、`DescribeConfigs` | KRaft ACL |
| features | 不用額外權限 | — |

> 為什麼 topic 設定不用 RBAC 角色：內建角色裡有 `DescribeConfigs` 的都連帶能建立、刪除或改設定（例如 `DeveloperManage`），沒有唯讀的；`DeveloperRead` 沒有 `DescribeConfigs`，而且讀得到訊息內容。ACL 可以只給這兩個操作。

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
cluster_id=$(curl -s https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

# 1. svc-ops 登入 MDS，給 svc-backup 綁 SecurityAdmin（只能看 role binding）
confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key > /dev/null
confluent iam rbac role-binding create \
  --principal User:svc-backup \
  --role SecurityAdmin \
  --kafka-cluster $cluster_id > /dev/null

# 2. 兩條 ACL：所有 topic、cluster 本身的 Describe 與 DescribeConfigs
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"
kafka-acls $A --add --allow-principal User:svc-backup \
  --operation Describe --operation DescribeConfigs \
  --topic '*' > /dev/null
kafka-acls $A --add --allow-principal User:svc-backup \
  --operation Describe --operation DescribeConfigs \
  --cluster > /dev/null

# 3. 確認（binding 表頭兩行不印；ACL 數「operation=」的行）
confluent iam rbac role-binding list --principal User:svc-backup --kafka-cluster $cluster_id | tail -n +3
echo "ACL：$(kafka-acls $A --list --principal User:svc-backup 2> /dev/null | grep -c 'operation=') 條"
```

```out
  User:svc-backup | SecurityAdmin | Cluster       |      |
ACL：4 條
```

反向：讀不到訊息、建不了 topic、改不了 role binding（CLI 用暫時的 HOME 登入 svc-backup，不蓋掉操作機原本的登入）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
B="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-backup.properties"

# 1. 讀訊息：要被拒
echo "讀訊息：$(kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9094 \
  --consumer.config ~/conf/client-backup.properties \
  --topic orders.events \
  --from-beginning --max-messages 1 --timeout-ms 10000 2>&1 | grep -o '[A-Za-z]*AuthorizationException' | head -1)"

# 2. 建 topic：要被拒
echo "建 topic：$(kafka-topics $B --create \
  --topic backup-sneak \
  --partitions 1 --replication-factor 3 2>&1 | grep -o '[A-Za-z]*AuthorizationException' | head -1)"

# 3. 改 role binding：要被拒（confluent CLI 用暫時的 HOME 登入 svc-backup，不蓋掉操作機原本的登入；用完即刪）
cluster_id=$(curl -s https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
tmp=$(mktemp -d)

HOME=$tmp confluent login --url https://kb01.poc.lab:8090 \
  --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only \
  --client-cert-path ~/pki/certs/svc-backup.crt \
  --client-key-path ~/pki/keys/svc-backup.key > /dev/null
echo "改 role binding：$(HOME=$tmp confluent iam rbac role-binding create \
  --principal User:svc-backup \
  --role SystemAdmin \
  --kafka-cluster $cluster_id 2>&1 | grep -o '40[0-9] [A-Za-z]*' | head -1)"

rm -rf $tmp
```

```out
讀訊息：GroupAuthorizationException
建 topic：TopicAuthorizationException
改 role binding：403 Forbidden
```

## 23.3 匯出腳本

@role 小安 | ops02 | root

每一項存成一個文字檔，最後算 `SHA256SUMS`（比對兩天的備份就看它）；超過 30 天的自動刪掉；成功或失敗都寫 syslog（tag `confluent-backup`）。**整段貼到 EOF**：

```bash
cat > ~/conf/metadata-backup.sh <<'EOF'
#!/usr/bin/env bash
# metadata-backup.sh — 每天匯出叢集中繼資料到 ~/backup/metadata/<時間>/
# 做什麼：RBAC、ACL、topic 與設定、SCRAM 帳號與配額、features、broker 動態設定，每一項存成一個文字檔，最後算 SHA256SUMS；
#   超過 KEEP_DAYS 天的舊備份刪掉；成功或失敗都寫 syslog（tag confluent-backup）；成功時最後一行印出這次的備份目錄
# 身分：svc-backup（SecurityAdmin 只能看 role binding；ACL 只有 Describe、DescribeConfigs）；沒有密碼，不讀訊息內容
# 用到的設定：環境變數 KEEP_DAYS（預設 30）、BACKUP_ROOT（預設 ~/backup/metadata）；~/conf/client-backup.properties（23.1）
# 結束碼：0 全部匯出、1 有任何一項失敗（看 syslog tag confluent-backup）
# 改的時候要注意：各檔內容的格式（features 拿掉 Epoch、ACL 一條一行、排序一律 LC_ALL=C、rbac.txt 去掉對齊空白）要和
#   OP menu 44 的快照一模一樣（23.5 用 sha256 互相比對）；26.4 的 cluster-restore-all.sh 也照這個格式讀

keep_days=${KEEP_DAYS:-30}
backup_root=${BACKUP_ROOT:-$HOME/backup/metadata}
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
brokers=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094
A="--bootstrap-server $brokers --command-config $HOME/conf/client-backup.properties"

out=$backup_root/$(date +%Y%m%d-%H%M)
install -d -m 0700 "$out"
failed=""

# save <檔名> <指令…>：指令的輸出存成 <檔名>；失敗或是空的就記下來，錯誤訊息留在 <檔名>.err
#   例：save topics.txt kafka-topics $A --describe → 寫出 $out/topics.txt
save() {
  local file=$1
  shift

  if "$@" > "$out/$file" 2> "$out/$file.err"; then
    if [ -s "$out/$file" ]; then
      rm -f "$out/$file.err"
      return
    fi
  fi

  failed="$failed $file"
}

# features：features 清單，拿掉每次都不同的 Epoch
#   例：Feature: metadata.version	FinalizedVersionLevel: 27	Epoch: 1234
#       → Feature: metadata.version	FinalizedVersionLevel: 27
features() {
  kafka-features $A describe | sed 's/[[:space:]]*Epoch: [0-9]*//'
}

# acls：ACL 一條一行：資源類型|名稱|比對方式|principal|host|操作|ALLOW/DENY，排好順序（26.4 的 cluster-restore-all.sh 照這個格式建回來）
#   kafka-acls --list 的輸入，一個資源標題底下有多條 ACL：
#     Current ACLs for resource `ResourcePattern(resourceType=TOPIC, name=*, patternType=LITERAL)`:
#         (principal=User:svc-backup, host=*, operation=DESCRIBE, permissionType=ALLOW)
#   輸出：TOPIC|*|LITERAL|User:svc-backup|*|DESCRIBE|ALLOW
acls() {
  kafka-acls $A --list | awk '
    /^Current ACLs for resource/ {
      # 資源標題：留下 TOPIC|*|LITERAL 記在 r，給底下每一條 ACL 用
      s = $0
      sub(/.*resourceType=/, "", s)
      sub(/\)`:.*/, "", s)
      gsub(/, name=|, patternType=/, "|", s)
      r = s
      next
    }

    /principal=/ {
      # 一條 ACL：留下 User:svc-backup|*|DESCRIBE|ALLOW，前面接上資源
      s = $0
      sub(/^[ \t]*\(principal=/, "", s)
      sub(/\)[ \t]*$/, "", s)
      gsub(/, host=|, operation=|, permissionType=/, "|", s) # lint-ok: awk 的 | 不是管線
      print r "|" s
    }
  ' | LC_ALL=C sort
}

# scram_and_quotas：每個帳號的 SCRAM（只有機制與迭代次數，沒有密碼）與配額，排好順序
#   例：SCRAM credential configs for user-principal 'app-restore' are SCRAM-SHA-512=iterations=8192
scram_and_quotas() {
  kafka-configs $A --describe --entity-type users | LC_ALL=C sort
}

# 1. 六個用 Kafka 工具匯出的檔
save topics.txt         kafka-topics $A --describe
save topic-configs.txt  kafka-configs $A --describe --entity-type topics
save users.txt          scram_and_quotas
save broker-configs.txt kafka-configs $A --describe --entity-type brokers --entity-default
save features.txt       features
save acls.txt           acls

# 2. RBAC：confluent CLI 用自己的 HOME，免得蓋掉操作機上原本的登入身分
export HOME_CLI=$backup_root/.cli
install -d -m 0700 "$HOME_CLI"

# cli <參數…>：用這支腳本自己的 HOME 跑 confluent，例：cli iam rbac role list -o json
cli() {
  HOME=$HOME_CLI confluent "$@"
}

cluster_id=$(curl -s https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

# clean_table：把 confluent 的表格去掉對齊空白、排好順序（從標準輸入讀）
#   例：「  User:alice | DeveloperRead | Topic | orders | LITERAL 」→「User:alice|DeveloperRead|Topic|orders|LITERAL」
clean_table() {
  sed 's/ *| */|/g; s/^ *//; s/ *$//' | LC_ALL=C sort
}

# rbac：每個有 binding 的 principal 一段：「== principal」，底下是它的每一條 binding（去掉表格對齊空白、排好順序）
#   例：== User:alice
#       User:alice|DeveloperRead|Topic|orders|LITERAL
rbac() {
  local roles role principals principal list

  # 2a. svc-backup 登入 MDS
  if ! cli login --url https://kb01.poc.lab:8090 \
    --certificate-authority-path "$HOME/pki/certs/bank-root.pem" \
    --certificate-only \
    --client-cert-path "$HOME/pki/certs/svc-backup.crt" \
    --client-key-path "$HOME/pki/keys/svc-backup.key" > /dev/null; then
    return 1
  fi

  # 2b. 每個角色的 binding 裡出現過的 principal（排序、去掉重複）
  roles=$(cli iam rbac role list -o json | grep -o '"name": *"[A-Za-z]*"' | cut -d'"' -f4)
  list=$(mktemp)

  for role in $roles; do
    cli iam rbac role-binding list --role "$role" --kafka-cluster "$cluster_id" -o json 2> /dev/null >> $list
  done

  principals=$(grep -o '"principal": *"[^"]*"' $list | cut -d'"' -f4 | LC_ALL=C sort -u)
  rm -f $list

  # 2c. 每個 principal 一段
  for principal in $principals; do
    echo "== $principal"
    cli iam rbac role-binding list --principal "$principal" --kafka-cluster "$cluster_id" | tail -n +3 | clean_table
  done
}

save rbac.txt rbac

# 3. 這次每個檔的 sha256（比對兩天的備份就看它）
cd "$out"
sha256sum -- *.txt > SHA256SUMS
cd - > /dev/null

# 4. 刪掉超過 keep_days 天的舊備份
find "$backup_root" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +"$keep_days" -exec rm -rf {} +

# 5. 結果寫 syslog：有失敗就以 1 結束；成功印出備份目錄
if [ -n "$failed" ]; then
  logger -t confluent-backup -p user.err "中繼資料匯出有失敗：$failed（$out）"
  echo "失敗：$failed"
  exit 1
fi

logger -t confluent-backup -p user.info "中繼資料已匯出：$out"
echo "$out"
EOF

chmod 0700 ~/conf/metadata-backup.sh

# 試跑一次：最後一行是這次的備份目錄
d=$(bash ~/conf/metadata-backup.sh)
echo "$d"
cd "$d"

# 每個檔幾行；RBAC 有幾個 principal；SHA256SUMS 收了幾個檔；有沒有任何像密碼的字（要是 0）
for f in *.txt; do
  printf '%-18s %4s 行\n' $f $(wc -l < $f)
done

echo "RBAC 的 principal：$(grep -c '^== ' rbac.txt) 個；SHA256SUMS：$(wc -l < SHA256SUMS) 個檔"
echo "密碼字樣：$(cat *.txt | grep -ciE 'password=|salt|stored_key')"
```

```out
/root/backup/metadata/20261025-0102
acls.txt              4 行
broker-configs.txt    2 行
features.txt          8 行
rbac.txt             45 行
topic-configs.txt    66 行
topics.txt          160 行
users.txt            11 行
RBAC 的 principal：14 個；SHA256SUMS：7 個檔
密碼字樣：0
```

> `users.txt` 的 SCRAM 那幾行只有機制與迭代次數（`SCRAM-SHA-512=iterations=8192`），沒有密碼也沒有雜湊。帳號被刪掉時，這份清單只說要重建哪些帳號，密碼在操作機的 `~/secrets`（11.1）。

## 23.4 每天凌晨 2 點自動跑

**待銀行確認**：行內若有排程系統，改由它每天呼叫 `~/conf/metadata-backup.sh`（結束碼 0／1），就不用裝下面的 timer。

@role 小安 | ops02 | root

```bash
# 1. service：跑一次匯出
cat > /etc/systemd/system/confluent-metadata-backup.service <<'EOF'
[Unit]
Description=Confluent cluster metadata export

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/root/conf/metadata-backup.sh
EOF

# 2. timer：每天 02:00（關機錯過的，開機後補跑）
cat > /etc/systemd/system/confluent-metadata-backup.timer <<'EOF'
[Unit]
Description=Daily Confluent cluster metadata export

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 3. 啟用 timer，並馬上跑一次
systemctl daemon-reload
systemctl enable --now confluent-metadata-backup.timer > /dev/null 2>&1
systemctl start confluent-metadata-backup.service

echo "下次執行：$(systemctl show confluent-metadata-backup.timer -p NextElapseUSecRealtime --value)"
echo "syslog：$(journalctl -t confluent-backup -n 1 --no-pager -o cat)"
```

```out
下次執行：Sun 2026-10-25 02:00:00 CST
syslog：中繼資料已匯出：/root/backup/metadata/20261025-0103
```

> 備份目錄在操作機上；正式環境請銀行的主機備份系統把 `~/backup/metadata` 一起收走（裡面沒有密碼，只有清單與設定）。

## 23.5 用備份：哪裡變了

@role 小安 | ops02 | root

比對最近兩次的備份，哪些檔有變一眼看出來（精簡的 OS 沒有 `diff`，用 sha256 與 `join`）；以 topic 為例列出多出來的。

正式環境比的是「昨天」和「今天」。（lab 專用）lab 沒有隔天，所以先造一個變化：新建 `orders.backup-demo`，等到下一分鐘再匯出一次（備份目錄以分鐘命名，同一分鐘再匯出會蓋掉前一份）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 造一個變化：新建 orders.backup-demo
kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --create --if-not-exists \
  --topic orders.backup-demo \
  --partitions 1 --replication-factor 3 > /dev/null

# 2. 等到下一分鐘再匯出一次（備份目錄以分鐘命名，同一分鐘再匯出會蓋掉前一份）
last=$(ls -d ~/backup/metadata/20* | tail -1)

while [ "$(date +%Y%m%d-%H%M)" = "$(basename $last)" ]; do
  sleep 5
done

~/conf/metadata-backup.sh > /dev/null

newest=$(ls -d ~/backup/metadata/20* | tail -1)
echo "新建 orders.backup-demo 後再匯出：$(basename $newest)（上一份 $(basename $last)）"
```

```out
新建 orders.backup-demo 後再匯出：20261025-0108（上一份 20261025-0107）
```

```bash
cd ~/backup/metadata

# 最近的兩份
older=$(ls -d 20* | tail -2 | head -1)
newer=$(ls -d 20* | tail -1)
echo "比對 $older → $newer"

# 1. 每個檔：依檔名把兩份 SHA256SUMS 接起來（每行：檔名 舊 sha256 新 sha256），sha256 相同還是有變
sort -k2 $older/SHA256SUMS > /tmp/sums-older
sort -k2 $newer/SHA256SUMS > /tmp/sums-newer
join -1 2 -2 2 /tmp/sums-older /tmp/sums-newer > /tmp/sums-joined

while read -r name older_sum newer_sum; do
  if [ "$older_sum" = "$newer_sum" ]; then
    result=相同
  else
    result=有變
  fi

  printf '%-18s %s\n' "$name" "$result"
done < /tmp/sums-joined

# 2. topics.txt 多出來的 topic
grep -o 'Topic: [^[:space:]]*' $older/topics.txt | sort -u > /tmp/topics-older
grep -o 'Topic: [^[:space:]]*' $newer/topics.txt | sort -u > /tmp/topics-newer
echo "topics.txt 多出來的：$(grep -vxFf /tmp/topics-older /tmp/topics-newer | paste -sd' ')"

rm -f /tmp/sums-older /tmp/sums-newer /tmp/sums-joined /tmp/topics-older /tmp/topics-newer
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
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --delete --topic orders.backup-demo > /dev/null 2>&1
sleep 3

echo "orders.backup-demo 還在嗎：$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --list 2> /dev/null | grep -cx orders.backup-demo)"
```

```out
orders.backup-demo 還在嗎：0
```

> features 的 `Epoch` 每次都不同、ACL、帳號清單（`users.txt`）與 role binding 列出的順序不固定，腳本已經拿掉與排序（一律 `LC_ALL=C`，不受操作機語系影響；`rbac.txt` 另外去掉表格的對齊空白，欄位用 `|` 分開），否則常會顯示「有變」。

變更前的快照也可以由維運人員從 OP menu 44 匯出（`44 snapshot`）：以本人 AD 身分執行（要 SecurityAdmin 或 UserAdmin），放在選單的輸出目錄，檔名與內容和這裡一樣（另多一份權限清單 CSV），所以 23.6、26.4 的還原程式也能直接拿它來還原。`rbac.txt` 由選單直接問 MDS 產生，每日備份則用 confluent CLI 列；兩邊都去掉表格的對齊空白、每個 principal 底下的 binding 用 `LC_ALL=C` 排序，所以逐位元組相同。先匯出一份新的備份、馬上拍一次快照，兩份比對（上面最新的那份備份還帶著剛刪掉的示範 topic，拿它比會顯示 topic 兩個檔不同）：

@role 維運人員 alice（lab 由小安代打） | ops02 | root

```bash
# 1. 新匯出一份備份
b=$(~/conf/metadata-backup.sh)

# 2. alice 從 OP menu 44 拍一次快照（只印最後一行）
#    sed 拿掉終端機的顏色碼，再把檔名裡的時間換成 <時間>，例：snapshot-20261025-010203-alice → snapshot-<時間>-alice
password=$(cat ~/secrets/ad-test-users.pass)
env OPMENU_USER=alice OPMENU_PASS="$password" OPMENU_YES=1 JAVA_HOME=/opt/java/current \
  /opt/opmenu/opmenu.sh --run 44 snapshot 2>&1 < /dev/null \
  | tail -1 \
  | sed 's/\x1b\[[0-9;]*m//g; s/[0-9]\{8\}-[0-9]\{6\}/<時間>/'
unset password

# 3. 最新的快照和剛才的備份逐檔比 sha256
s=$(ls -dt /var/log/opmenu/snapshot-* | head -1)

for path in $b/*.txt; do
  f=$(basename $path)

  if [ "$(sha256sum < $b/$f)" = "$(sha256sum < $s/$f)" ]; then
    result=相同
  else
    result=不同
  fi

  printf '%-18s %s\n' $f $result
done
```

```out
已匯出變更前快照(31 筆權限,7 個清單):/var/log/opmenu/snapshot-<時間>-alice
acls.txt           相同
broker-configs.txt 相同
features.txt       相同
rbac.txt           相同
topic-configs.txt  相同
topics.txt         相同
users.txt          相同
```

> `topics.txt`、`topic-configs.txt` 和 23.5 一樣，中間有 leader 或 ISR 變動時會顯示「不同」，那不代表快照錯了；其他五個檔應該都相同。

還原時拿這些檔當依據逐項重建：topic（`kafka-topics --create`，照 `topics.txt` 的 partition 數、RF 與 `topic-configs.txt` 的設定）、role binding（照 `rbac.txt` 用 `confluent iam rbac role-binding create`）、配額（`kafka-configs --alter`）。這些都由有權限的人在變更時段做，不寫成自動還原。

## 23.6 還原演練：誤刪的 topic、權限、帳號從備份重建

下面這張圖說明備份裡的哪個檔重建哪一樣東西，以及備份裡沒有的東西。

![restore]

**這一節在做什麼**：證明 23.3 的備份真的能用。情境是最常見的「誤刪」：一個 topic（含它的 retention 設定）、一個應用程式的 SCRAM 帳號（含配額）和它的 role binding 被刪掉，從最近一份備份把三樣都重建回來，再用那個帳號寫一筆、讀回一筆。前提：23.3 的備份腳本已就緒、`~/secrets/` 有該帳號的密碼檔（備份裡沒有密碼）。完成的樣子：describe 的 partition 數、RF、retention 與備份一致，role binding 條數一致，帳號能從 9095 寫讀。整個叢集沒了的情況不是這一節：那是第 8–13 章重裝，再用這一節的三條路把中繼資料倒回去（訊息內容靠 replication factor 3，不在備份裡）。

@role 小安 | ops02 | root

先建演練用的三樣東西（topic 帶一個動態設定、帳號帶配額、三條 binding），再備份一次：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config /root/conf/client-admin.properties"

# 1. topic：3 個 partition，帶一個動態設定（retention 1 小時）；topic 名稱有點號的那句 WARNING 不印
kafka-topics $A --create --if-not-exists \
  --topic orders.restore-demo \
  --partitions 3 --replication-factor 3 \
  --config retention.ms=3600000 2> /dev/null | grep -v WARNING

# 2. 帳號：密碼檔（已經有就沿用；0600）、SCRAM、配額
if [ ! -s ~/secrets/app-restore.pass ]; then
  install -m 0600 /dev/null ~/secrets/app-restore.pass
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/app-restore.pass
fi

kafka-configs $A --alter --entity-type users --entity-name app-restore \
  --add-config "SCRAM-SHA-512=[iterations=8192,password=$(cat ~/secrets/app-restore.pass)]" > /dev/null
kafka-configs $A --alter --entity-type users --entity-name app-restore \
  --add-config 'producer_byte_rate=1048576,consumer_byte_rate=2097152,request_percentage=25' > /dev/null

# 3. 三條 binding（svc-ops 登入 MDS）
source ~/conf/kraft.env
confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key > /dev/null

for role in DeveloperRead DeveloperWrite; do
  confluent iam rbac role-binding create \
    --principal User:app-restore \
    --role $role \
    --resource Topic:orders.restore-demo \
    --kafka-cluster $CLUSTER_ID > /dev/null
done

confluent iam rbac role-binding create \
  --principal User:app-restore \
  --role DeveloperRead \
  --resource Group:restore- --prefix \
  --kafka-cluster $CLUSTER_ID > /dev/null

echo "演練物件：topic、帳號（含配額）、binding $(confluent iam rbac role-binding list \
  --principal User:app-restore \
  --kafka-cluster $CLUSTER_ID | grep -c app-restore) 條"

# 4. 備份一次，確認三樣都在備份裡
d=$(bash ~/conf/metadata-backup.sh)
echo "備份：$d"
grep -c "app-restore\|orders.restore-demo" $d/topics.txt $d/rbac.txt $d/users.txt
```

```out
Created topic orders.restore-demo.
演練物件：topic、帳號（含配額）、binding 3 條
備份：/root/backup/metadata/20261029-0220
/root/backup/metadata/20261029-0220/topics.txt:4
/root/backup/metadata/20261029-0220/rbac.txt:4
/root/backup/metadata/20261029-0220/users.txt:2
```

誤刪（三樣各自刪；SCRAM 憑據和配額要分開刪，合在一起 `kafka-configs` 會整句拒絕）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config /root/conf/client-admin.properties"
source ~/conf/kraft.env

# 1. 刪 topic
kafka-topics $A --delete --topic orders.restore-demo

# 2. 刪三條 binding
for role in DeveloperRead DeveloperWrite; do
  confluent iam rbac role-binding delete \
    --principal User:app-restore \
    --role $role \
    --resource Topic:orders.restore-demo \
    --kafka-cluster $CLUSTER_ID --force > /dev/null
done

confluent iam rbac role-binding delete \
  --principal User:app-restore \
  --role DeveloperRead \
  --resource Group:restore- --prefix \
  --kafka-cluster $CLUSTER_ID --force > /dev/null

# 3. 刪帳號：SCRAM 憑據和配額分開刪
kafka-configs $A --alter --entity-type users --entity-name app-restore \
  --delete-config SCRAM-SHA-512 > /dev/null
kafka-configs $A --alter --entity-type users --entity-name app-restore \
  --delete-config producer_byte_rate,consumer_byte_rate,request_percentage > /dev/null

# 4. 三樣都沒了（用 awk 數：數到 0 是正常結果，不能讓指令以失敗結束）
topic_left=$(kafka-topics $A --list | awk '/^orders.restore-demo$/ {c++} END {print c + 0}')
binding_left=$(confluent iam rbac role-binding list \
  --principal User:app-restore \
  --kafka-cluster $CLUSTER_ID | awk '/app-restore/ {c++} END {print c + 0}')
setting_left=$(kafka-configs $A --describe \
  --entity-type users --entity-name app-restore | awk '/./ {c++} END {print c + 0}')
echo "topic 還在：$topic_left；binding：$binding_left；帳號設定：$setting_left"
```

```out
topic 還在：0；binding：0；帳號設定：0
```

還原寫成一支小腳本 `metadata-restore.sh <備份目錄> <topic> <帳號>`：topic 的 partition 數與 RF 從 `topics.txt` 那一行讀、動態設定從 `topic-configs.txt`；role binding 照 `rbac.txt` 裡該 principal 的每一行建；SCRAM 的迭代次數與配額從 `users.txt`，密碼從 `~/secrets/<帳號>.pass`。最後自己驗證。**整段貼到 EOF**：

```bash
cat > ~/conf/metadata-restore.sh <<'EOF'
#!/usr/bin/env bash
# metadata-restore.sh <備份目錄> <topic 名稱|-> <帳號|-> — 從 23.3 的備份重建
# 做什麼：一個 topic（partition 數、RF、動態設定）、一個帳號的 role binding、那個帳號的 SCRAM（含配額）；最後自己驗證
#   參數寫 - 代表那一項不做
# 用到的檔案：備份目錄的 topics.txt、topic-configs.txt、rbac.txt、users.txt；密碼不在備份裡，帳號的密碼讀 ~/secrets/<帳號>.pass（0600）
# 改的時候要注意：讀檔的格式要和 metadata-backup.sh 寫出來的一致；MDS 寫入只在 50003（not the current leader）時再送一次（28.4）
set -f   # 關掉萬用字元展開：rbac.txt 裡有 Topic:* 這種名稱

backup=$1
topic=$2
user=$3

if [ -z "$topic" ]; then
  topic=-
fi

if [ -z "$user" ]; then
  user=-
fi

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config /root/conf/client-admin.properties"
source ~/conf/kraft.env

if [ ! -d "$backup" ]; then
  echo "沒有備份目錄 $backup"
  exit 1
fi

# ---- 1. topic ----
if [ "$topic" != - ]; then
  # topics.txt 裡這個 topic 的第一行：PartitionCount 與 ReplicationFactor
  #   例：Topic: orders.restore-demo	TopicId: x	PartitionCount: 3	ReplicationFactor: 3 → partitions=3、rf=3
  line=$(grep -P "^Topic: $topic\t" "$backup/topics.txt" | head -1)
  partitions=$(echo "$line" | grep -o 'PartitionCount: [0-9]*' | cut -d' ' -f2)
  rf=$(echo "$line" | grep -o 'ReplicationFactor: [0-9]*' | cut -d' ' -f2)

  if [ -z "$partitions" ]; then
    echo "備份裡沒有 topic $topic"
    exit 1
  fi

  # 動態設定：topic-configs.txt 裡「Dynamic configs for topic <名稱> are:」底下那幾行的第一欄（key=value）
  #   例：  retention.ms=3600000 sensitive=false synonyms=… → retention.ms=3600000
  configs=$(awk -v t="$topic" '
    $0 == "Dynamic configs for topic " t " are:" { p = 1; next }
    /^Dynamic configs/ { p = 0 }
    p { print $1 }
  ' "$backup/topic-configs.txt")
  config_args=""
  config_count=0

  for kv in $configs; do
    config_args="$config_args --config $kv"
    config_count=$((config_count + 1))
  done

  if kafka-topics $A --create --topic "$topic" \
    --partitions "$partitions" --replication-factor "$rf" $config_args > /dev/null; then
    echo "topic $topic：partitions=$partitions rf=$rf 動態設定 $config_count 個"
  fi
fi

# ---- 2. role binding 與 SCRAM 帳號 ----
if [ "$user" != - ]; then
  confluent login --url https://kb01.poc.lab:8090 \
    --certificate-authority-path ~/pki/certs/bank-root.pem \
    --certificate-only \
    --client-cert-path ~/pki/certs/svc-ops.crt \
    --client-key-path ~/pki/keys/svc-ops.key > /dev/null

  # create_binding <參數…>：建一條 binding；只有 50003（auth topic 的 leader 剛搬家，MDS 內部的 producer 不重試）才再送一次
  #   例：create_binding --principal User:app-restore --role DeveloperRead --kafka-cluster "$CLUSTER_ID"
  create_binding() {
    local result

    if result=$(confluent iam rbac role-binding create "$@" 2>&1); then
      return 0
    fi

    if echo "$result" | grep -q "not the current leader"; then
      confluent iam rbac role-binding create "$@" > /dev/null 2>&1
      return
    fi

    return 1
  }

  # rbac.txt 裡這個帳號那一段（「== User:<帳號>」到下一個「== 」之前）；一行一條：principal|角色|資源類型|資源名稱|比對方式
  #   例：User:app-restore|DeveloperRead|Group|restore-|PREFIXED
  bindings=$(mktemp)
  awk -v u="User:$user" '
    $0 == "== " u { p = 1; next }
    /^== / { p = 0 }
    p
  ' "$backup/rbac.txt" > $bindings
  count=0

  while IFS='|' read -r principal role rtype rname pattern; do
    # 去掉每一欄前後的空白
    principal=$(echo $principal)
    role=$(echo $role)
    rtype=$(echo $rtype)
    rname=$(echo $rname)
    pattern=$(echo $pattern)

    # 整個 cluster 的不給 --resource；PREFIXED 的多加 --prefix
    if [ -z "$rname" ]; then
      if create_binding --principal "$principal" --role "$role" --kafka-cluster "$CLUSTER_ID"; then
        count=$((count + 1))
      fi
    elif [ "$pattern" = PREFIXED ]; then
      if create_binding --principal "$principal" --role "$role" --kafka-cluster "$CLUSTER_ID" \
        --resource "$rtype:$rname" --prefix; then
        count=$((count + 1))
      fi
    else
      if create_binding --principal "$principal" --role "$role" --kafka-cluster "$CLUSTER_ID" \
        --resource "$rtype:$rname"; then
        count=$((count + 1))
      fi
    fi
  done < $bindings

  rm -f $bindings
  echo "role binding：$count 條"

  # SCRAM 的迭代次數（沒有就用 8192）與配額：users.txt 裡這個帳號的那兩行
  scram_line=$(grep "SCRAM credential configs for user-principal '$user'" "$backup/users.txt")
  iterations=$(echo "$scram_line" | grep -o 'iterations=[0-9]*' | head -1)
  if [ -z "$iterations" ]; then
    iterations=iterations=8192
  fi

  # 配額：去掉句子開頭與數字的 .0、逗號後的空白
  #   例：Quota configs for user-principal 'a' are consumer_byte_rate=2097152.0, request_percentage=25.0
  #       → consumer_byte_rate=2097152,request_percentage=25
  quota=$(grep "Quota configs for user-principal '$user'" "$backup/users.txt" | sed 's/.* are //; s/\.0\b//g; s/, /,/g')

  if [ ! -s ~/secrets/$user.pass ]; then
    echo "沒有 ~/secrets/$user.pass：密碼不在備份裡，先放密碼檔"
    exit 1
  fi

  if kafka-configs $A --alter --entity-type users --entity-name "$user" \
    --add-config "SCRAM-SHA-512=[$iterations,password=$(cat ~/secrets/$user.pass)]" > /dev/null; then
    echo "SCRAM $user：$iterations"
  fi

  if [ -n "$quota" ]; then
    if kafka-configs $A --alter --entity-type users --entity-name "$user" --add-config "$quota" > /dev/null; then
      echo "配額：$quota"
    fi
  fi
fi

# ---- 3. 驗證 ----
if [ "$topic" != - ]; then
  # 第一行的 PartitionCount 與 ReplicationFactor，例：PartitionCount: 3 ReplicationFactor: 3
  summary=$(kafka-topics $A --describe --topic $topic \
    | head -1 \
    | grep -o 'PartitionCount: [0-9]*.ReplicationFactor: [0-9]*' \
    | tr '\t' ' ')

  # 動態設定 key=value，逗號接起來，例：retention.ms=3600000
  topic_configs=$(kafka-configs $A --describe --entity-type topics --entity-name $topic \
    | grep -o '^  [a-z.]*=[^ ]*' \
    | tr -d ' ' \
    | paste -sd, -)
  echo "describe：$summary；$topic_configs"
fi

if [ "$user" != - ]; then
  binding_count=$(confluent iam rbac role-binding list \
    --principal User:$user \
    --kafka-cluster $CLUSTER_ID | grep -c "User:$user")
  setting_count=$(kafka-configs $A --describe --entity-type users --entity-name $user | grep -c .)
  echo "binding：$binding_count 條；帳號設定：$setting_count 行"
fi
EOF

chmod 0700 ~/conf/metadata-restore.sh

# 用最新的一份備份重建
latest=$(ls -d ~/backup/metadata/20* | tail -1)
bash ~/conf/metadata-restore.sh "$latest" orders.restore-demo app-restore
```

```out
topic orders.restore-demo：partitions=3 rf=3 動態設定 1 個
role binding：3 條
SCRAM app-restore：iterations=8192
配額：consumer_byte_rate=2097152,request_percentage=25,producer_byte_rate=1048576
describe：PartitionCount: 3 ReplicationFactor: 3；retention.ms=3600000
binding：3 條；帳號設定：2 行
```

最後用重建的帳號寫一筆、讀回一筆（走 SCRAM 的 9095），證明帳號、密碼、權限、topic 四樣都回來了；看完把演練物件清掉：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config /root/conf/client-admin.properties"
source ~/conf/kraft.env

# 1. 用重建的帳號從 9095 寫一筆、讀回來（連線設定借 app-orders 那一份，帳密換成 app-restore；暫存檔用完即刪）
conf=$(mktemp)
login_module=org.apache.kafka.common.security.scram.ScramLoginModule
password=$(cat ~/secrets/app-restore.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $conf
echo "sasl.jaas.config=$login_module required username=\"app-restore\" password=\"$password\";" >> $conf
unset password

echo "restore-$(date +%s)" | kafka-console-producer \
  --bootstrap-server kb01.poc.lab:9095 \
  --producer.config $conf \
  --topic orders.restore-demo > /dev/null 2>&1

echo "app-restore 寫一筆：ok；讀回：$(kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9095 \
  --consumer.config $conf \
  --topic orders.restore-demo \
  --group restore-check \
  --from-beginning --max-messages 1 --timeout-ms 20000 2> /dev/null | grep -c restore-)"
rm -f $conf

# 2. 清掉演練物件：topic、三條 binding、帳號（SCRAM 與配額分開刪）、密碼檔
kafka-topics $A --delete --topic orders.restore-demo

for role in DeveloperRead DeveloperWrite; do
  confluent iam rbac role-binding delete \
    --principal User:app-restore \
    --role $role \
    --resource Topic:orders.restore-demo \
    --kafka-cluster $CLUSTER_ID --force > /dev/null
done

confluent iam rbac role-binding delete \
  --principal User:app-restore \
  --role DeveloperRead \
  --resource Group:restore- --prefix \
  --kafka-cluster $CLUSTER_ID --force > /dev/null

kafka-configs $A --alter --entity-type users --entity-name app-restore \
  --delete-config SCRAM-SHA-512 > /dev/null
kafka-configs $A --alter --entity-type users --entity-name app-restore \
  --delete-config producer_byte_rate,consumer_byte_rate,request_percentage > /dev/null
rm -f ~/secrets/app-restore.pass

echo "演練物件已清掉"
```

```out
app-restore 寫一筆：ok；讀回：1
演練物件已清掉
```

> 正式環境誤刪時：先用 23.5 的比對找出「少了什麼」，再對每一樣跑 `metadata-restore.sh`（topic 和帳號可以分開給 `-`）。ACL 不在這支裡：`acls.txt` 一條一行（資源類型|名稱|比對方式|principal|host|操作|ALLOW/DENY），照那一行用 `kafka-acls --add` 重建（26.4 的 `cluster-restore-all.sh` 第 5 段就是這樣讀的）。帳號的密碼還原後和刪前相同（都來自 `~/secrets`），應用程式不用改設定。

# 24. 第二十四站：磁碟與容量

下面這張圖是這一章的地圖：用量在哪裡看（24.1）、資料盤有哪三種告警訊號（24.2）、快滿時照什麼順序做（24.3）。

![disk]

**這一章在做什麼**：broker 的資料盤（`log.dirs=/var/lib/kafka/data`，第 10 章）是平台裡唯一會自己長大的東西：topic 沒設 retention、應用程式流量變大、replication factor 3 讓每筆訊息存三份。這一章把「看用量 → 告警 → 快滿時的處理 → 擴容與換碟」走一遍，24.3 在 lab 用一個示範 topic 真的做：寫 5 MB、縮短 retention 看 segment 被刪、再把 partition 搬到別台 broker。前提：第 14 章的檢查正常、第 17 章的監控已接上（24.2 要多給一個規則檔）。完成的樣子：24.1 印得出每台 broker 的合計與最大的 topic；銀行 Prometheus 多載入一個規則檔（多 1 條：第 17 章做完是 26 → 27 條，做過第 22 章是 29 → 30 條）；示範 topic 縮短 retention 後三個 replica 都變 0、partition 搬離 kb01 後 kb01 上的目錄消失。

## 24.1 看用量：哪台 broker、哪個 topic 吃多少

@role 小安 | ops02 | root

Kafka 自己知道每個 partition 在每台 broker 占多少位元組（`kafka-log-dirs`，走管理 listener，不用 ssh 進主機；維運人員用 OP menu 也能查）。輸出的最後一行是 JSON，用 python 整理成「每台合計、partition 數、最大的三個 topic」：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# kafka-log-dirs 的最後一行是 JSON；python 整理成每台一行
kafka-log-dirs \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --describe 2> /dev/null | tail -1 | python3 -c '
import json, sys, collections
d = json.load(sys.stdin)
for b in sorted(d["brokers"], key=lambda b: b["broker"]):
    for ld in b["logDirs"]:
        by = collections.Counter()
        for p in ld["partitions"]:
            by[p["partition"].rsplit("-", 1)[0]] += p["size"]
        top = ", ".join("%s %.1f MB" % (t, s / 1048576) for t, s in by.most_common(3))
        total = sum(by.values()) / 1048576
        count = len(ld["partitions"])
        print("broker %s %s: %.1f MB, %d partitions; 最大: %s" % (b["broker"], ld["logDir"], total, count, top))'
```

```out
broker 101 /var/lib/kafka/data: 9.1 MB, 150 partitions; 最大: _confluent-telemetry-metrics 8.0 MB, __consumer_offsets 0.4 MB, orders.load 0.2 MB
broker 102 /var/lib/kafka/data: 11.5 MB, 154 partitions; 最大: _confluent-telemetry-metrics 10.1 MB, __consumer_offsets 0.4 MB, orders.load 0.3 MB
broker 103 /var/lib/kafka/data: 10.7 MB, 150 partitions; 最大: _confluent-telemetry-metrics 9.5 MB, __consumer_offsets 0.3 MB, orders.load 0.2 MB
broker 104 /var/lib/kafka/data: 3.3 MB, 149 partitions; 最大: _confluent-telemetry-metrics 2.7 MB, __consumer_offsets 0.2 MB, orders.events 0.1 MB
```

lab 裡最大的是 `_confluent-telemetry-metrics`（Confluent 自己的 telemetry topic，retention 由它自己管）；正式環境看的是應用程式的 topic，而且數字會是 GB 起跳。正式環境有多個 `log.dirs` 時每個目錄各一行。

資料盤本身還剩多少，用 `df` 看每台 broker。`/var/lib/kafka/data` 是 0750，但 `df` 看的是掛載點 `/var/lib/kafka`，cpuser 不用 sudo：

```bash
# 每台一行：用了多少 / 總共多少（百分比）掛在哪裡
#   df 的最後一行：檔案系統 總共 已用 剩餘 百分比 掛載點，例：/dev/sda1 1007G 149G 807G 16% /
for h in kb01 kb02 kb03 kb04; do
  line=$(ssh $h.poc.lab 'df -h /var/lib/kafka' | tail -1)
  read -r _ size used _ percent mount <<< "$line"
  echo "$h: $used 用 / $size（$percent）掛在 $mount"
done
```

```out
kb01: 149G 用 / 1007G（16%）掛在 /
kb02: 149G 用 / 1007G（16%）掛在 /
kb03: 149G 用 / 1007G（16%）掛在 /
kb04: 149G 用 / 1007G（16%）掛在 /
```

（lab 是容器，資料盤是和 OS 共用的 overlay，所以四台都顯示整個根目錄；正式環境 `/var/lib/kafka` 是獨立的 XFS 掛載點，7.2 有檢查，每台會各自不同。）

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

同樣的數字銀行 Prometheus 也有：第 17 章的 exporter 規則把每個 partition 的大小變成 `kafka_log_log_size`，可以依 topic 加總、畫趨勢；`kafka_log_logmanager_logdirectoryoffline` 是每台 broker 的 log dir 是否離線（0 正常）。lab 從容器裡查（`__cluster_metadata` 是 KRaft 的 metadata log，每台 broker 都有一份，不是 topic；`topk` 會把它一起列出來）：

```bash
# 在 labnet 上起一個臨時容器，執行 EOF 之前的那一段
podman run --rm -i --network lab_labnet lab-node:96 bash -s <<'EOF'
# 1. 依 topic 加總、最大的三個
curl -s --data-urlencode "query=topk(3, sum by (topic) (kafka_log_log_size))" \
  http://lab-mon-prometheus:9090/api/v1/query | python3 -c '
import json, sys
for r in json.load(sys.stdin)["data"]["result"]:
    print("%-32s %.1f MB（三個 replica 合計）" % (r["metric"]["topic"], float(r["value"][1]) / 1048576))'

# 2. log dir 沒有離線的 broker 數
curl -s --data-urlencode 'query=count(kafka_log_logmanager_logdirectoryoffline{job="kafka-broker"} == 0)' \
  http://lab-mon-prometheus:9090/api/v1/query | python3 -c '
import json, sys
print("log dir 正常的 broker：%s / 4" % json.load(sys.stdin)["data"]["result"][0]["value"][1])'
EOF
```

```out
_confluent-telemetry-metrics     30.1 MB（三個 replica 合計）
__cluster_metadata               17.4 MB（三個 replica 合計）
__consumer_offsets               1.2 MB（三個 replica 合計）
log dir 正常的 broker：4 / 4
```

## 24.2 告警：資料盤的三種訊號

@role 小安 | ops02 | root

| 訊號 | 誰的指標 | 規則 | 意思 |
|---|---|---|---|
| log dir 離線 | 我方 JMX exporter：`kafka_log_logmanager_logdirectoryoffline` | `KafkaLogDirOffline`（第 17 章既有） | 磁碟壞了或滿到寫不進去；只有一個 `log.dirs` 時 broker 會自己停掉，`ConfluentTargetDown` 也會響 |
| 資料盤用量超過 80% | 銀行主機監控（node_exporter 的 `node_filesystem_*`） | `KafkaDataDiskFillingUp`（這一節給**範例**，mountpoint、job 由銀行改） | 滿之前就通知，照 24.3 處理；滿了 broker 就停 |
| broker 停了 | 第 17 章既有 | `ConfluentTargetDown`、`KafkaUnderReplicatedPartitions` | 磁碟事件的後果，不是原因 |

Kafka 的 JMX 沒有「磁碟剩多少」這種指標（它只知道自己寫了多少），所以用量告警一定靠主機層：銀行既有的 node_exporter（或其他主機監控）。log dir 離線的規則已在第 17 章的 `confluent-alerts.yml`；這裡給的是用量的範例規則，放在第二個規則檔，和 17.5 的 `confluent-alerts.yml` 放在一起；17.6 的 `rule_files` 用的是 `confluent-alerts*.yml`，新檔放進去 reload 就會載入。整段貼到 EOF：

```bash
cat > ~/monitoring/to-bank/prometheus/confluent-alerts-disk.yml <<'EOF'
# Disk and capacity rules for the bank's Prometheus (guide, chapter 24.2). Loaded next to confluent-alerts.yml
# (rule_files: /etc/prometheus/confluent/confluent-alerts*.yml). Same label conventions as confluent-alerts.yml.
groups:
  - name: kafka-disk
    rules:
      # source: ours, EXAMPLE for the bank's host monitoring: needs node_exporter on the brokers (the bank's, not ours; the lab has none, so this rule never fires there).
      # Adjust mountpoint, job and threshold to the bank's node_exporter setup; the point is to page before the disk is full, not after.
      - alert: KafkaDataDiskFillingUp
        expr: (1 - node_filesystem_avail_bytes{mountpoint="/var/lib/kafka"} / node_filesystem_size_bytes{mountpoint="/var/lib/kafka"}) > 0.80
        for: 15m
        labels: { severity: warning, impact: INFRASTRUCTURE }
        annotations:
          summary: "{{ $labels.instance }}: Kafka data disk above 80%"
          description: "The data disk of {{ $labels.instance }} is {{ $value | humanizePercentage }} full. Follow guide 24.3: find the biggest topics (kafka-log-dirs), shorten retention or move partitions, then grow the disk (24.4). At 100% the broker stops."
EOF

rules_file=~/monitoring/to-bank/prometheus/confluent-alerts-disk.yml
echo "confluent-alerts-disk.yml: $(grep -c '^      - alert:' $rules_file) 條規則"
```

```out
confluent-alerts-disk.yml: 1 條規則
```

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

正式環境是銀行監控團隊把這個檔放到 `/etc/prometheus/confluent/`、reload Prometheus，再把 `KafkaDataDiskFillingUp` 的 mountpoint 與 job 改成行內 node_exporter 的寫法。lab：複製進 `bank-monitoring/prometheus/confluent/`（Prometheus 容器唯讀掛著這個資料夾）；`prometheus.yml` 的 `rule_files` 若還是單一檔名就改成 `confluent-alerts*.yml`（17.6 的寫法）；`prometheus.yml` 是以單檔掛進容器的，改了要 `podman restart` 才讀得到（正式環境是 reload）。剛載入的規則 health 是 unknown，要等過一次 evaluation（30 秒）才變 ok，所以數規則前最多等 100 秒：

```bash
cd ~/kafka-lab/bank-monitoring

# 1. 規則檔從 ops02 複製到 Prometheus 掛著的資料夾
target_file=$(cygpath -m "$PWD/prometheus/confluent/confluent-alerts-disk.yml")
podman cp lab-ops02-1:/root/monitoring/to-bank/prometheus/confluent-alerts-disk.yml "$target_file"

# 2. rule_files 還是單一檔名的話，改成 confluent-alerts*.yml
if ! grep -q 'confluent-alerts\*\.yml' prometheus/prometheus.yml; then
  sed -i 's#confluent/confluent-alerts\.yml#confluent/confluent-alerts*.yml#' prometheus/prometheus.yml
fi

# 3. 重啟 Prometheus（prometheus.yml 是單檔掛進去的），等它 Ready：每 5 秒看一次，最多 12 次
podman restart lab-mon-prometheus > /dev/null

for i in $(seq 1 12); do
  if podman exec lab-mon-prometheus wget -qO- http://localhost:9090/-/ready 2> /dev/null | grep -q Ready; then
    break
  fi

  sleep 5
done

# 4. 等新規則過一次 evaluation（health 從 unknown 變 ok）：每 5 秒看一次，最多 20 次
#    每一次都在 labnet 上起一個臨時容器（執行 EOF 之前的那一段），印規則數、群組名稱、載入有錯幾條
for i in $(seq 1 20); do
  status=$(podman run --rm -i --network lab_labnet lab-node:96 bash -s <<'EOF'
curl -s http://lab-mon-prometheus:9090/api/v1/rules | python3 -c '
import json, sys
g = json.load(sys.stdin)["data"]["groups"]
r = [x for y in g for x in y["rules"]]
print("告警規則 %d 條（%s），載入有錯 %d 條" % (len(r), "、".join(y["name"] for y in g), sum(x["health"] != "ok" for x in r)))'
EOF
)

  if echo "$status" | grep -q '載入有錯 0 條'; then
    break
  fi

  sleep 5
done

echo "$status"
```

```out
告警規則 30 條（cert-expiry、kafka-disk、confluent-availability、control-center、host、jvm、kafka-broker、kraft、rest-proxy），載入有錯 0 條
```

> lab 沒有 node_exporter，`KafkaDataDiskFillingUp` 的查詢永遠是空的，規則載入正常但不會響；`KafkaLogDirOffline` 的指標四台 broker 都有（24.1 查過是 0）。磁碟真的壞掉沒辦法在 lab 演，這一條靠規則載入與指標存在來確認。

## 24.3 快滿時：先爭取空間，再處理根因

@role 小安 | ops02 | root

資料盤用量告警響了（或 24.1 看到某台快滿），依序做，每一步做完都回 24.1 看一次：

| 順序 | 動作 | 指令 | 注意 |
|---|---|---|---|
| ① | 找最大的 topic | 24.1 的 `kafka-log-dirs` | 通常是沒設 retention 的 topic（預設 `log.retention.hours=168`，7 天）或流量突然變大的 topic |
| ② | 縮短 retention | `kafka-configs --alter --entity-type topics --entity-name <topic> --add-config retention.ms=<毫秒>`（或 `retention.bytes`） | 只刪**關掉的** segment，現用的那個不刪；broker 每 `log.retention.check.interval.ms`（預設 5 分鐘）檢查一次才真的刪。事後記得改回來（`--delete-config retention.ms` 回到 broker 預設） |
| ③ | 精準刪到某個 offset | `kafka-delete-records --offset-json-file`（指定 topic、partition、offset） | 應用程式確定不再讀這段才做；也是等下一次檢查才釋放空間（lab 實測 kb03 13 秒、kb01 4 分半） |
| ④ | 把 partition 搬離那台 | `kafka-reassign-partitions --execute`（下面示範） | 搬的時候是一份完整的複製流量，正式環境加 `--throttle <bytes/s>`；搬完舊 broker 上的目錄自己消失 |
| ⑤ | 加 broker、擴容 | 25.2.3、24.4 | Self-Balancing 會把 partition 搬到新 broker |

不要做的事：手動 `rm` `/var/lib/kafka/data` 底下的檔（broker 會壞、replica 掉出 ISR），也不要停 broker 來「省空間」（它的 partition 只是換別台繼續長）。

lab 用一個示範 topic 走 ②、④：segment 設成 1 MB（預設 1 GB，這樣才看得到 segment 被刪），寫 50000 筆 × 100 B，三個 replica 各 5 MB 多：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"

# 1. 示範 topic：1 個 partition、3 份 replica、segment 1 MB
kafka-topics $A --create --if-not-exists \
  --topic orders.disk-demo \
  --partitions 1 --replication-factor 3 \
  --config segment.bytes=1048576 > /dev/null 2>&1

# 2. 寫 50000 筆 × 100 B（從 9095 用 app-orders 的帳號）
kafka-producer-perf-test \
  --topic orders.disk-demo \
  --num-records 50000 --throughput -1 --record-size 100 \
  --producer.config ~/conf/app-orders.properties \
  --producer-props bootstrap.servers=kb01.poc.lab:9095 2>&1 | tail -1 | grep -o '^[0-9]* records sent'

# 3. 每個 replica 多大，例：broker 101 5370 KB, broker 102 5370 KB, broker 103 5370 KB
sleep 3
size=$(kafka-log-dirs $A --describe --topic-list orders.disk-demo 2> /dev/null | tail -1 | python3 -c '
import json, sys
d = json.load(sys.stdin)
sizes = []
for b in sorted(d["brokers"], key=lambda b: b["broker"]):
    for ld in b["logDirs"]:
        for p in ld["partitions"]:
            sizes.append("broker %s %d KB" % (b["broker"], p["size"] // 1024))
print(", ".join(sizes))')
echo "寫入後：$size"

# 4. replica 在哪幾台
echo "replica 在：$(kafka-topics $A --describe --topic orders.disk-demo 2> /dev/null | grep -o 'Replicas: [0-9,]*')"
```

```out
50000 records sent
寫入後：broker 101 5370 KB, broker 102 5370 KB, broker 103 5370 KB
replica 在：Replicas: 101,103,102
```

② 縮短 retention 到 60 秒。改完 Kafka 不會馬上刪：要等 broker 的 retention 檢查（每 5 分鐘），輪到時連現用的 segment 也會被關掉、刪掉（資料都超過 60 秒了），所以三個 replica 最後都是 0。這裡每 10 秒看一次、最多等 7 分鐘：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"

# 1. retention 改成 60 秒
kafka-configs $A --alter \
  --entity-type topics --entity-name orders.disk-demo \
  --add-config retention.ms=60000 > /dev/null 2>&1
echo "retention.ms=60000 已設 $(date +%T)"

# 2. 等 broker 的 retention 檢查把三個 replica 都刪到 1 MB 以下：每 10 秒看一次，最多 42 次（7 分鐘）
#    size 的樣子，例：broker 101 5370 KB, broker 102 5370 KB, broker 103 5370 KB
for i in $(seq 1 42); do
  size=$(kafka-log-dirs $A --describe --topic-list orders.disk-demo 2> /dev/null | tail -1 | python3 -c '
import json, sys
d = json.load(sys.stdin)
sizes = []
for b in sorted(d["brokers"], key=lambda b: b["broker"]):
    for ld in b["logDirs"]:
        for p in ld["partitions"]:
            sizes.append("broker %s %d KB" % (b["broker"], p["size"] // 1024))
print(", ".join(sizes))')

  if ! echo "$size" | grep -qE '[1-9][0-9]{3} KB'; then
    break
  fi

  sleep 10
done

echo "等了約 $((i * 10)) 秒：$size"

# 3. 改回 broker 預設
kafka-configs $A --alter \
  --entity-type topics --entity-name orders.disk-demo \
  --delete-config retention.ms > /dev/null 2>&1
echo "retention.ms 已改回 broker 預設"
```

```out
retention.ms=60000 已設 03:12:25
等了約 220 秒：broker 101 0 KB, broker 102 0 KB, broker 103 0 KB
retention.ms 已改回 broker 預設
```

④ 把 partition 搬離 kb01（broker 101）。再寫一次 50000 筆讓它有東西可搬，寫一個 reassignment JSON 指定新的 replica 名單 `102,103,104`，`--execute` 開始、`--verify` 等到 completed；搬完 kb01 上的 partition 目錄自己消失（lab 5 MB 三秒就好；正式環境 GB 級要加 `--throttle`）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"
json=~/conf/disk-demo-reassign.json

# 1. 再寫 50000 筆，讓它有東西可搬
kafka-producer-perf-test \
  --topic orders.disk-demo \
  --num-records 50000 --throughput -1 --record-size 100 \
  --producer.config ~/conf/app-orders.properties \
  --producer-props bootstrap.servers=kb01.poc.lab:9095 > /dev/null 2>&1
sleep 3

# 2. 搬之前每個 replica 多大，例：broker 101 5370 KB, broker 102 5370 KB, broker 103 5370 KB
size=$(kafka-log-dirs $A --describe --topic-list orders.disk-demo 2> /dev/null | tail -1 | python3 -c '
import json, sys
d = json.load(sys.stdin)
sizes = []
for b in sorted(d["brokers"], key=lambda b: b["broker"]):
    for ld in b["logDirs"]:
        for p in ld["partitions"]:
            sizes.append("broker %s %d KB" % (b["broker"], p["size"] // 1024))
print(", ".join(sizes))')
echo "搬之前：$size"

# 3. reassignment JSON：partition 0 的新 replica 名單是 102,103,104（kb01 = 101 不在裡面）
cat > $json <<'EOF'
{"version":1,"partitions":[{"topic":"orders.disk-demo","partition":0,"replicas":[102,103,104]}]}
EOF

# 4. 開始搬
kafka-reassign-partitions $A --reassignment-json-file $json --execute 2>&1 | grep -E '^Successfully|^Error'
```

```out
搬之前：broker 101 5370 KB, broker 102 5370 KB, broker 103 5370 KB
Successfully started partition reassignment for orders.disk-demo-0
```

等它搬完，再看 replica 的位置和 kb01 上的目錄：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"
json=~/conf/disk-demo-reassign.json

# 1. 等 --verify 說 completed：每 5 秒看一次，最多 30 次
t0=$(date +%s)

for i in $(seq 1 30); do
  if kafka-reassign-partitions $A --reassignment-json-file $json --verify 2> /dev/null | grep -q 'is completed'; then
    break
  fi

  sleep 5
done

# 2. 搬完每個 replica 多大、在哪幾台
size=$(kafka-log-dirs $A --describe --topic-list orders.disk-demo 2> /dev/null | tail -1 | python3 -c '
import json, sys
d = json.load(sys.stdin)
sizes = []
for b in sorted(d["brokers"], key=lambda b: b["broker"]):
    for ld in b["logDirs"]:
        for p in ld["partitions"]:
            sizes.append("broker %s %d KB" % (b["broker"], p["size"] // 1024))
print(", ".join(sizes))')
echo "搬完（$(( $(date +%s) - t0 )) 秒）：$size"
echo "replica 在：$(kafka-topics $A --describe --topic orders.disk-demo 2> /dev/null | grep -o 'Replicas: [0-9,]*')"

# 3. kb01 上那個 partition 的目錄還在不在（資料目錄是 0750，要 sudo find；名稱完全相同才算）
sleep 5
count=$(ssh kb01.poc.lab 'sudo find /var/lib/kafka/data -maxdepth 1 -name orders.disk-demo-0' | wc -l)

if [ "$count" = 0 ]; then
  echo "kb01 上的目錄：不存在"
else
  echo "kb01 上的目錄：還在"
fi
```

```out
搬完（3 秒）：broker 102 5370 KB, broker 103 5370 KB, broker 104 5370 KB
replica 在：Replicas: 102,103,104
kb01 上的目錄：不存在
```

清掉示範 topic（正式環境當然不做這步；要搬一整台 broker 的所有 partition 時，用 25.2.2 的 `kafka-remove-brokers` 讓 Self-Balancing 搬，不要自己寫幾百行 JSON）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --delete --topic orders.disk-demo
rm -f ~/conf/disk-demo-reassign.json
echo "orders.disk-demo 已刪"
```

```out
orders.disk-demo 已刪
```

## 24.4 擴容與換碟

@role 小安 | ops02 | root

| 情況 | 誰做 | 怎麼做 | broker 要停嗎 |
|---|---|---|---|
| 資料盤放大（VM 磁碟加大） | 銀行 OS 團隊 | LVM：`lvextend` + `xfs_growfs /var/lib/kafka`（XFS 只能線上放大，不能縮） | 不用；做完 24.1 的 `df` 確認 |
| 同一台 broker 換資料碟 | OS 團隊換碟、我方做 25.2 | 25.2.2 `kafka-remove-brokers` 把 partition 搬走 → 停服務、換碟、掛回 `/var/lib/kafka` → 25.2.3 以空的 broker 加回，Self-Balancing 搬回 | 停這一台，叢集不中斷 |
| controller 換資料碟 | 同上，照 25.1 | 移出 quorum → 換碟 → 重新格式化（觀察者）→ 加回 | 停這一台 |
| 整體不夠：加 broker | 我方＋OS 團隊 | 新主機照 4、5、7、8、10 章準備，25.2.3 加入 | 不用 |

容量估算（請銀行確認的事項 4.1 的磁碟規格用）：每台 broker 的資料盤 ≈ 每天寫入量 × retention 天數 × replication factor ÷ broker 數 × 1.3（30% 餘裕給 segment 滾動、compaction、搬 partition 時的暫時兩份）。寫入量與 retention 是應用程式團隊要給的數字（請銀行確認的事項 12.2）；上線後用銀行 Prometheus 的 `kafka_log_log_size` 看趨勢，提前三個月知道什麼時候要擴。lab 是容器、資料盤和 OS 共用，放大磁碟與換碟沒辦法演，只演 25.1／25.2 的搬遷程序。


# 25. 第二十五站：節點更換與增減

**這一章在做什麼**：兩種會動到叢集成員的作業：換掉一台 controller（25.1）、縮減與擴充 broker（25.2）。兩者都在服務不中斷的前提下做，應用程式不用改設定。前提：第 14 章的檢查全部正常、第 15 章已做（格式化新節點時要讀 master key）。完成的樣子：quorum 三個成員都在、沒有 under-replicated partition、第 14 章的檢查仍全部正常。

## 25.1 換掉一台 controller

下面這張圖畫出換掉 kc03 的每一步，quorum 裡的成員怎麼變。

![controllerswap]

**這一節在做什麼**：controller 的主機壞了或資料碟壞了，怎麼把它換成一台新的，而不中斷叢集。順序：先看 quorum（25.1.1）→ 模擬壞掉（25.1.2，lab 專用）→ 把舊成員移出（25.1.3）→ 重新格式化並追上（25.1.4）→ 加回（25.1.5）。前提：其他兩台 controller 健康。

controller 的 quorum 是動態的（第 10 章用 `--initial-controllers` 格式化）：成員是「node id＋directory id」。換一台 controller，就是把舊的那組移出 quorum、把新的那組加進來，一次只動一個成員。

| 情況 | 要做的事 |
|---|---|
| 同一台主機，資料碟壞了換新 | 本章：移出舊成員 → 重新格式化（觀察者）→ 追上 → 加入 |
| 換一台新機器，沿用同一個主機名稱 | 先照第 4、5、7、8 章把新機器準備好（銀行的帳號、套件庫、JDK、OS 調校、套件；**裝現行版本**：遷移後是 JDK 25、Confluent 8.3.2，見 29.10），派送憑證與設定（第 10 章），再做本章 |
| 換成不同名稱的主機 | 另外要重簽 `kafka-internal`（SAN 列了所有主機名稱，21.2），所有節點的 `controller.quorum.bootstrap.servers` 改成新名單並滾動重啟；本章未演練 |

> 注意：一次只換一台。換的過程中 quorum 只剩兩個成員，兩個都要在才能選出 leader；這段時間重啟 kc01 或 kc02，叢集會失去多數派而停擺。處理：換完、kc03 追上並重新加入之前，不要動另外兩台。

### 25.1.1 換之前：看 quorum

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

kafka-metadata-quorum \
  --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties \
  describe --replication
```

```out
NodeId  DirectoryId             LogEndOffset  Lag  LastFetchTimestamp  LastCaughtUpTimestamp  Status
1       …                       …             0    …                   …                      Leader
2       …                       …             0    …                   …                      Follower
3       …                       …             0    …                   …                      Follower
101     …                       …             0    …                   …                      Observer
（broker 101–104 都是 Observer）
```

### 25.1.2 模擬：kc03 的資料碟壞了

@role Lab 管理員 | Windows 終端 | 本機

正式環境是銀行主機團隊換了碟、掛回同一個路徑。lab 裡：用清空資料目錄模擬（用 `find -mindepth 1 -delete`：`rm -rf <目錄>/*` 會漏掉 `.kafka_cleanshutdown` 這類點開頭的檔）：

```bash
# 在 kc03 容器裡執行 EOF 之前的那一段
podman exec -i lab-kc03-1 bash -e -s <<'EOF'
# 1. 停服務
systemctl stop confluent-server

# 2. 清空資料目錄（含點開頭的檔）
find /var/lib/kafka/data -mindepth 1 -delete

# 3. 剩幾個檔、目錄的擁有者與權限
echo "kc03 data: $(ls -A /var/lib/kafka/data | wc -l) files, $(stat -c %U:%G:%a /var/lib/kafka/data)"
EOF
```

```out
kc03 data: 0 files, cp-kafka:confluent:750
```

@role 小安 | ops02 | root

這時候叢集照常（三個成員還有兩個），但 kc03 不再拉資料：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 等 15 秒，看 kc01、kc02 眼中的 quorum（只留標題列和 controller：node id 1、2 位數；broker 是 101 起跳）
sleep 15
kafka-metadata-quorum \
  --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties \
  describe --replication | awk '/^(NodeId|[0-9][0-9]?[[:space:]])/ {print $0}'

# 2. 叢集照常：MDS 還回 200
echo "MDS：$(curl -s -o /dev/null -w '%{http_code}' https://kb01.poc.lab:8090/v1/metadata/id)"
```

```out
NodeId  DirectoryId  LogEndOffset  Lag  …  Status
1       …            …             0    …  Leader
2       …            …             0    …  Follower
3       OwqboMUaS4C4y6JYkevW7w  30349  37   …  Follower      （Lag 一直變大）
MDS：200
```

### 25.1.3 移出舊成員

@role 小安 | ops02 | root

舊成員是「3＋舊的 directory id」，從 25.1.1 的輸出取：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
Q="--bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093 --command-config $HOME/conf/client-internal.properties"

# 1. 舊成員的 directory id（node id 3 那一行的第二欄）
OLD_DIR=$(kafka-metadata-quorum $Q describe --replication | grep '^3[[:space:]]' | awk '{print $2}')
echo "移出 3 / $OLD_DIR"

# 2. 移出 quorum
kafka-metadata-quorum $Q remove-controller --controller-id 3 --controller-directory-id $OLD_DIR

# 3. 目前的成員（CurrentVoters 那一行裡的 id）
sleep 5
voter_line=$(kafka-metadata-quorum $Q describe --status | awk '/CurrentVoters/ {print $0}')
voter_ids=$(echo "$voter_line" | grep -o '"id": [0-9]*' | cut -d' ' -f2)
echo "目前的成員：$(echo "$voter_ids" | paste -sd' ')"
```

```out
移出 3 / OwqboMUaS4C4y6JYkevW7w
Removed  KRaft controller 3 with directory id OwqboMUaS4C4y6JYkevW7w
目前的成員：1 2
```

### 25.1.4 重新格式化成觀察者、啟動、追上

@role 小安 | ops02 | root

用原本的 cluster id、`--no-initial-controllers`（以觀察者身分加入，不是自己宣告成員）。設定檔有 `${securepass:…}`（第 15 章），格式化工具也要拿得到 master key：從 `service.env` 讀：

```bash
source ~/conf/kraft.env

# 1. 在 kc03 上以 root 執行 EOF 之前的那一段（$1 = cluster id）：以觀察者格式化、啟動、印新的 directory id
ssh kc03.poc.lab sudo bash -e -s -- $CLUSTER_ID <<'EOF'
# 讀 master key（設定檔有 ${securepass:…}，第 15 章，格式化工具也要拿得到）
set -a
. /etc/confluent/service.env
set +a

# 以 cp-kafka 身分格式化（只看最後一行）
runuser -u cp-kafka -- env \
  CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" \
  JAVA_HOME=/opt/java/current \
  KAFKA_HEAP_OPTS=-Xmx256m \
  KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
  kafka-storage format \
    --cluster-id $1 \
    --config /etc/confluent/kafka/server.properties \
    --no-initial-controllers 2>&1 | tail -1

systemctl start confluent-server
new_dir=$(sed -n 's/^directory.id=//p' /var/lib/kafka/data/meta.properties)
echo "kc03 $(systemctl is-active confluent-server) dir=$new_dir"
EOF

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
Q="--bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093 --command-config $HOME/conf/client-internal.properties"

# 2. 等 kc03 追上（Lag 0、Observer）：每 5 秒看一次，最多 60 次
#    describe 的欄位：NodeId DirectoryId LogEndOffset Lag … Status；取 node id 3 那一行的第 4 欄與最後一欄
for i in $(seq 1 60); do
  kc03_line=$(kafka-metadata-quorum $Q describe --replication 2> /dev/null | awk '/^3[[:space:]]/ {print $0}')
  lag=$(echo "$kc03_line" | awk '{print $4}')
  state=$(echo "$kc03_line" | awk '{print $NF}')

  if [ "$lag $state" = "0 Observer" ]; then
    break
  fi

  sleep 5
done

echo "kc03：Lag=$lag $state"
```

```out
Formatting metadata directory /var/lib/kafka/data with confluent.metadata.version 4.2-IV1A.
kc03 active dir=eELCq6OM-4WuTdfGQSmOgQ（新的 directory id，和 OLD_DIR 不同）
kc03：Lag=0 Observer
```

### 25.1.5 加回成員

> 實測（2026-10-25，lab）：從清空資料到重新成為成員約 5 分鐘（格式化、啟動、追上 3 萬多筆 metadata、add-controller），期間 MDS、REST、C3 都維持 200。

@role 小安 | ops02 | root

`add-controller` 要在**新的那台**上跑：工具從 `--command-config` 指到的設定找資料目錄，讀出自己的 node id 與 directory id 再去登記。用那台的 server.properties 加一行 `security.protocol=SSL`，用完就刪：

```bash
# 1. 在 kc03 上以 root 執行 EOF 之前的那一段
ssh kc03.poc.lab sudo bash -e -s <<'EOF'
# 讀 master key（設定檔有 ${securepass:…}，第 15 章）
set -a
. /etc/confluent/service.env
set +a

# 這台的 server.properties 加一行 security.protocol=SSL，當 add-controller 的 --command-config（0640 root:confluent，用完就刪）
conf=/etc/confluent/kafka/add-controller.properties
install -m 0640 -o root -g confluent /dev/null $conf
cat /etc/confluent/kafka/server.properties > $conf
echo security.protocol=SSL >> $conf

# 以 cp-kafka 身分登記（WARN 不看，只看最後一行）
runuser -u cp-kafka -- env \
  CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" \
  JAVA_HOME=/opt/java/current \
  KAFKA_HEAP_OPTS=-Xmx256m \
  KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
  kafka-metadata-quorum \
    --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093 \
    --command-config $conf \
    add-controller 2>&1 | grep -v WARN | tail -1

rm -f $conf
EOF

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 2. 三個成員都在（只留標題列和 controller：node id 1、2 位數）
sleep 10
kafka-metadata-quorum \
  --bootstrap-controller kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties \
  describe --replication | awk '/^(NodeId|[0-9][0-9]?[[:space:]])/ {print $0}'
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
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. 等 kc03 的監控端點有指標（kafka_ 開頭的超過 20 個）：每 10 秒看一次，最多 24 次
for i in $(seq 1 24); do
  metrics=$(curl -s --cacert $CA https://kc03.poc.lab:7071/metrics | awk '/^kafka_/ {c++} END {print c + 0}')

  if [ "$metrics" -gt 20 ]; then
    break
  fi

  sleep 10
done

echo "kc03 7071：${metrics}個指標"

# 2. 四台 MDS（8090）的 HTTP 狀態碼
for h in kb01 kb02 kb03 kb04; do
  printf "%s MDS=%s " $h "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done
echo
```

```out
kc03 7071：973個指標
kb01 MDS=200 kb02 MDS=200 kb03 MDS=200 kb04 MDS=200
```

## 25.2 broker 縮減與擴充
下面這張圖畫出縮減、再擴充 kb04 的過程。

![brokerscale]

**這一節在做什麼**：拿掉一台 broker（縮減）、或加一台 broker（擴充），應用程式不中斷。順序：先做前置檢查（25.2.1）→ 縮減（25.2.2）→ 擴充（25.2.3）。名詞：Self-Balancing 是 Confluent 的自動資料平衡功能，負責把 partition 的 replica 搬到合適的 broker。

broker 的資料由 Self-Balancing（第 10 章 `confluent.balancer.enable=true`）搬：縮減時用 `kafka-remove-brokers` 把要拿掉的那台的 replica 全部搬走、它自己關機；擴充時空的 broker 一加入，Self-Balancing 自動把資料搬過去。

| 前提 | 原因 |
|---|---|
| 縮減後至少還有 3 台 | topic 的 replication factor 是 3 |
| 沒有 under-replicated partition | 搬資料前叢集要健康 |
| Self-Balancing 是 `ENABLED` | `kafka-remove-brokers` 靠它搬 |

lab 裡：用 kb04（node id 104）演練：先縮減、再當成一台空的新 broker 加回來。過程中持續有應用程式寫入。

### 25.2.1 前置檢查

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
BROKERS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094
A="--bootstrap-server $BROKERS --command-config $HOME/conf/client-admin.properties"

# 1. Self-Balancing 的狀態
echo "Self-Balancing：$(kafka-rebalance-cluster $A --status 2> /dev/null | grep -o 'Balancer status: [A-Z_]*')"

# 2. under-replicated 的 partition 數
under=$(kafka-topics $A --describe --under-replicated-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')
echo "under-replicated：$under"

# 3. replica 名單裡有 104 的 partition 數（名單的樣子：Replicas: 101,102,104）
on_104=$(kafka-topics $A --describe 2> /dev/null \
  | grep -oE 'Replicas: [0-9,]+' \
  | awk '/[ ,]104(,|$)/ {c++} END {print c + 0}')
echo "kb04（104）上的 replica：$on_104"
```

```out
Self-Balancing：Balancer status: ENABLED
under-replicated：0
kb04（104）上的 replica：80
```

### 25.2.2 縮減：拿掉 kb04

@role 小安 | ops02 | root

先在背景跑一個持續寫入（app-orders 直連，acks=all，約 20 分鐘），證明搬資料期間應用程式不受影響：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 背景寫入 60000 筆、每秒 50 筆（輸出寫到 ~/scale-load.log，最後一塊看結果）
nohup kafka-producer-perf-test \
  --topic orders.events \
  --num-records 60000 \
  --throughput 50 \
  --record-size 200 \
  --producer.config ~/conf/app-orders.properties \
  --producer-props acks=all bootstrap.servers=kb01.poc.lab:9095,kb02.poc.lab:9095,kb03.poc.lab:9095 \
  > ~/scale-load.log 2>&1 &

# 2. 確認它在跑
sleep 5
echo "背景寫入已開始：$(pgrep -fc ProducerPerformance) 個"
```

```out
背景寫入已開始：1 個
```

`--delete` 送出移除，之後每 30 秒看一次進度，直到 `SUCCESS`；kb04 會自己關掉 broker，接著停用服務、免得主機重開又加回來：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
BROKERS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094
A="--bootstrap-server $BROKERS --command-config $HOME/conf/client-admin.properties"

# 1. 送出移除
kafka-remove-brokers $A --delete --broker-id 104 2>&1 | grep -v WARN | head -3

# 2. 等到 SUCCESS（或 FAIL）：每 30 秒看一次，最多 60 次
#    --describe 一台 broker 一段，開頭是「Broker 104 removal status - …」；只留 104 那一段（到下一台的開頭之前）
for i in $(seq 1 60); do
  status=$(kafka-remove-brokers $A --describe 2> /dev/null \
    | sed -n '/^Broker 104 /,/^Broker [0-9]/{ /^Broker [0-9]/!p; /^Broker 104 /p; }')

  if echo "$status" | grep -q 'removal status - SUCCESS'; then
    break
  fi

  if echo "$status" | grep -q FAIL; then
    break
  fi

  sleep 30
done

echo "$status"

# 3. kb04 已經自己關掉 broker；停用服務，免得主機重開又加回來
ssh kb04.poc.lab 'sudo systemctl disable --now confluent-server > /dev/null 2>&1'
printf 'kb04 confluent-server：%s / %s\n' \
  "$(ssh kb04.poc.lab systemctl is-active confluent-server)" \
  "$(ssh kb04.poc.lab systemctl is-enabled confluent-server)"
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
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
BROKERS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094
A="--bootstrap-server $BROKERS --command-config $HOME/conf/client-admin.properties"

# 1. replica 名單裡有 104 的 partition 數（名單的樣子：Replicas: 101,102,104）
on_104=$(kafka-topics $A --describe 2> /dev/null \
  | grep -oE 'Replicas: [0-9,]+' \
  | awk '/[ ,]104(,|$)/ {c++} END {print c + 0}')
echo "104 上的 replica：$on_104"

# 2. under-replicated 的 partition 數
under=$(kafka-topics $A --describe --under-replicated-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')
echo "under-replicated：$under"

# 3. 叢集裡的 broker（輸出每台一行，帶「(id: 101」）
broker_ids=$(kafka-broker-api-versions $A 2> /dev/null | grep -o '(id: [0-9]*' | cut -d' ' -f2)
echo "叢集裡的 broker：$(echo "$broker_ids" | sort | paste -sd' ')"
```

```out
104 上的 replica：0
under-replicated：0
叢集裡的 broker：101 102 103
```

> 永久縮減時，還要把 kb04 從所有 bootstrap 名單拿掉（REST Proxy、C3、MDS URL、OP menu、應用程式的設定），重新產生並滾動重啟；名單裡留著一台不存在的主機，client 會略過它，但每次連線都多一次逾時。lab 接著要加回來，所以名單不動。

### 25.2.3 擴充：kb04 以空的 broker 加回

@role 小安 | ops02 | root

加回來的 broker 必須是空的（舊 replica 不能帶回來）：清空資料目錄、用同一個 cluster id 以觀察者格式化、啟動。換一台全新主機時，前面照第 4、5、7、8 章準備，憑證的 SAN 要有它的名稱（21.2）：

```bash
source ~/conf/kraft.env

# 1. 在 kb04 上以 root 執行 EOF 之前的那一段（$1 = cluster id）：清空資料目錄、以觀察者格式化、啟用並啟動
ssh kb04.poc.lab sudo bash -e -s -- $CLUSTER_ID <<'EOF'
# 讀 master key（設定檔有 ${securepass:…}，第 15 章，格式化工具也要拿得到）
set -a
. /etc/confluent/service.env
set +a

find /var/lib/kafka/data -mindepth 1 -delete

# 以 cp-kafka 身分格式化（只看最後一行）
runuser -u cp-kafka -- env \
  CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" \
  JAVA_HOME=/opt/java/current \
  KAFKA_HEAP_OPTS=-Xmx256m \
  KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
  kafka-storage format \
    --cluster-id $1 \
    --config /etc/confluent/kafka/server.properties \
    --no-initial-controllers 2>&1 | tail -1

systemctl enable --now confluent-server > /dev/null 2>&1
EOF

# 2. 等 kb04 的 MDS 回 200：每 5 秒看一次，最多 60 次
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' https://kb04.poc.lab:8090/v1/metadata/id)" = 200 ]; then
    break
  fi

  sleep 5
done

echo "kb04 MDS=$(curl -s -o /dev/null -w '%{http_code}' https://kb04.poc.lab:8090/v1/metadata/id)"
```

```out
Formatting metadata directory /var/lib/kafka/data with confluent.metadata.version 4.2-IV1A.
kb04 MDS=200
```

（版本字串跟著裝的版本走：基底 8.2.4 是 `4.2-IV1A`，遷移到 8.3.2 之後換節點是 `4.3-IV0B`。）

Self-Balancing 發現空的 broker 會自己開始搬（不用下指令）。它不是馬上動：lab 等了十幾分鐘才開始，之後分批搬、要再一段時間才平均（實測加回 30 分鐘時 101–103 各約 130、104 約 45，還在增加）。這裡等到 104 上有 replica、而且沒有 under-replicated：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
BROKERS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094,kb04.poc.lab:9094
A="--bootstrap-server $BROKERS --command-config $HOME/conf/client-admin.properties"

# 1. 等 104 上有 replica、而且沒有 under-replicated：每 30 秒看一次，最多 60 次
#    名單的樣子：Replicas: 101,102,104
for i in $(seq 1 60); do
  n=$(kafka-topics $A --describe 2> /dev/null \
    | grep -oE 'Replicas: [0-9,]+' \
    | awk '/[ ,]104(,|$)/ {c++} END {print c + 0}')
  u=$(kafka-topics $A --describe --under-replicated-partitions 2> /dev/null \
    | awk '/Partition:/ {c++} END {print c + 0}')

  if [ "$n" -gt 0 ]; then
    if [ "$u" = 0 ]; then
      break
    fi
  fi

  sleep 30
done

echo "104 上的 replica：$n、under-replicated：$u（約 $((i * 30)) 秒）"

# 2. Self-Balancing 為什麼在搬（EMPTY_BROKER = 發現空的 broker）
kafka-rebalance-cluster $A --describe 2> /dev/null | grep -iE 'status|broker' | head -5
```

```out
104 上的 replica：15、under-replicated：0（約 1050 秒）
Uneven load balance status:
  HealUnevenLoadTrigger: EMPTY_BROKER
```

背景寫入的結果（整段縮減與擴充期間，最大延遲出現在 replica 搬移時）：

```bash
# 1. 等背景寫入結束：每 10 秒看一次，最多 60 次
for i in $(seq 1 60); do
  if ! pgrep -f ProducerPerformance > /dev/null; then
    break
  fi

  sleep 10
done

# 2. 最後一行是總結；再數 ERROR 行與 leader 搬家時的重試警告
tail -1 ~/scale-load.log
errors=$(awk '/\] ERROR / {c++} END {print c + 0}' ~/scale-load.log)
retries=$(awk '/NOT_LEADER_OR_FOLLOWER/ {c++} END {print c + 0}' ~/scale-load.log)
echo "錯誤（ERROR 行）：$errors；leader 搬家時的重試警告（WARN，會自動重送）：$retries"
```

```out
60000 records sent, 49.996584 records/sec (0.01 MB/sec), 9.60 ms avg latency, 750.00 ms max latency, 9 ms 50th, 14 ms 95th, 22 ms 99th, 70 ms 99.9th.
錯誤（ERROR 行）：0；leader 搬家時的重試警告（WARN，會自動重送）：2
```

6 萬筆全部送出就是沒有遺失；重試警告是 replica 搬移、leader 換台的那一刻，producer 自己重送成功（`retries` 預設無限）。

# 26. 第二十六站：License 到期監控與每日檢查

**這一章在做什麼**：license（授權）到期前提早知道。做法：26.1 學會讀出到期日、26.2 設每天一次的自動檢查、26.3 買到正式 license 之後怎麼換上去。前提：叢集已運作（第 10 章之後任何時間都可以做）。完成的樣子：26.1 印得出到期日，操作機的 syslog 每天多一行 tag `confluent-license`。

平台目前用的是試用 license（第 10 章 `confluent.license` 沒有設）。試用期 30 天；正式 license 一般一年一約。到期之後 broker 仍會繼續服務、只是日誌一直報錯，但**重啟時 RBAC／MDS 等安全外掛與 Control Center 起不來**，等於下一次維運重啟就停擺。原廠只在 C3 畫面（到期前 90 天開始）與 broker 日誌提醒，**沒有提供到期日的 JMX 指標**，所以行內監控要自己讀。

生效中的 license 是一個 JWT，broker 會把它存進 `_confluent-command` topic。讀出來、解開中間那段，`exp` 就是到期時間。

## 26.1 現在用的是哪一份、哪天到期

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 從 _confluent-command 讀出最後一個 JWT（eyJ 開頭、三段用點隔開）
jwt=$(timeout 90 kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094 \
  --consumer.config ~/conf/client-admin.properties \
  --topic _confluent-command \
  --from-beginning \
  --timeout-ms 20000 2> /dev/null \
  | grep -a -o 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' \
  | tail -1)

# 2. 中間那段是 base64url：換回一般 base64 的字元、補 = 到 4 的倍數，再解開
payload=$(echo "$jwt" | cut -d. -f2 | tr '_-' '/+')

while [ $(( ${#payload} % 4 )) != 0 ]; do
  payload="$payload="
done

claims=$(echo "$payload" | base64 -d 2> /dev/null)

# 3. 類型與到期時間（exp 是 Unix 秒數）
echo "類型：$(echo "$claims" | grep -o '"licenseType":"[^"]*"' | cut -d'"' -f4)"
expires_at=$(echo "$claims" | grep -o '"exp":[0-9]*' | cut -d: -f2)
echo "到期：$(date -d @$expires_at '+%F %T')，剩 $(( (expires_at - $(date +%s)) / 86400 )) 天"

unset jwt payload claims expires_at
```

```out
類型：trial
到期：2026-11-23 22:13:29，剩 29 天
```

> 只解開、不驗簽章：簽章由 broker 自己驗。這裡只是讀到期日給監控用。

## 26.2 每天檢查一次，寫進 syslog

@role 小安 | ops02 | root

把 26.1 寫成一支小腳本：剩不到 90 天（和 C3 的提示同一天開始）就以 `warning` 寫進 syslog，過期或讀不到就是 `err`；銀行監控團隊的監控／SIEM 依 tag `confluent-license` 告警。結束碼 0／2／1 給銀行的排程系統用（要改由行內排程呼叫也是同一支）。跑完看印出的到期日與結束碼：

```bash
cat > ~/conf/license-check.sh <<'EOF'
#!/usr/bin/env bash
# license-check.sh — 讀生效中的 license 到期日，寫 syslog（tag confluent-license）
# 做什麼：從 _confluent-command 讀最後一個 JWT，解開中間那段取 exp（到期時間）與 licenseType
# 結束碼：0 正常、2 剩不到 WARN_DAYS 天（預設 90）、1 已過期或讀不到
# 改的時候要注意：結束碼給銀行的排程系統與 systemd（SuccessExitStatus=2）用，不要改它的意思

if [ -z "$WARN_DAYS" ]; then
  WARN_DAYS=90
fi

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 最後一個 JWT
jwt=$(timeout 90 kafka-console-consumer --bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094 \
  --consumer.config /root/conf/client-admin.properties \
  --topic _confluent-command \
  --from-beginning \
  --timeout-ms 20000 2> /dev/null \
  | grep -a -o 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' | tail -1)

# 2. 中間那段 base64url → base64、補 = 到 4 的倍數、解開
payload=$(echo "$jwt" | cut -d. -f2 | tr '_-' '/+')

while [ $(( ${#payload} % 4 )) != 0 ]; do
  payload="$payload="
done

claims=$(echo "$payload" | base64 -d 2> /dev/null)
expires_at=$(echo "$claims" | grep -o '"exp":[0-9]*' | cut -d: -f2)
license_type=$(echo "$claims" | grep -o '"licenseType":"[^"]*"' | cut -d'"' -f4)

if [ -z "$license_type" ]; then
  license_type=unknown
fi

# 3. 讀不到 → err、結束碼 1
if [ -z "$expires_at" ]; then
  logger -t confluent-license -p user.err "license 讀不到（_confluent-command 沒有 JWT 或連不上 broker）"
  echo "讀不到 license"
  exit 1
fi

days_left=$(( (expires_at - $(date +%s)) / 86400 ))
message="license $license_type 到期 $(date -d @"$expires_at" +%F)，剩 $days_left 天"

# 4. 已過期 → err、1；剩不到 WARN_DAYS 天 → warning、2；其他 → info、0
if [ "$days_left" -lt 0 ]; then
  logger -t confluent-license -p user.err "已過期：$message"
  echo "已過期：$message"
  exit 1
fi

if [ "$days_left" -lt "$WARN_DAYS" ]; then
  logger -t confluent-license -p user.warning "快到期：$message"
  echo "快到期：$message"
  exit 2
fi

logger -t confluent-license -p user.info "$message"
echo "$message"
EOF

chmod 0700 ~/conf/license-check.sh

# 跑一次；結束碼 2（快到期）也是正常的結果，所以接住它再印
if bash ~/conf/license-check.sh; then
  rc=0
else
  rc=$?
fi

echo "rc=$rc"
```

```out
快到期：license trial 到期 2026-11-23，剩 29 天
rc=2
```

試用版只有 30 天，所以 lab 一定是「快到期」（rc 2）；正式 license 剩超過 90 天時是 rc 0。

排程：操作機的 systemd timer 每天早上 8 點跑一次（以 root 身分，用的是操作機本來就有的管理 client 設定）。**待銀行確認**：行內若有排程系統（例如 Control-M），改由它在同一時間呼叫 `~/conf/license-check.sh`，看結束碼與 syslog，就不用裝這個 timer：

```bash
# 1. service：跑一次 license-check.sh；結束碼 2（快到期）不算失敗
cat > /etc/systemd/system/confluent-license-check.service <<'EOF'
[Unit]
Description=Confluent license expiry check

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/root/conf/license-check.sh
SuccessExitStatus=2
EOF

# 2. timer：每天 08:00；關機錯過的話開機後補跑（Persistent）
cat > /etc/systemd/system/confluent-license-check.timer <<'EOF'
[Unit]
Description=Daily Confluent license expiry check

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 3. 啟用 timer，並立刻跑一次
systemctl daemon-reload
systemctl enable --now confluent-license-check.timer > /dev/null 2>&1
systemctl start confluent-license-check.service

# 4. 下次什麼時候跑、syslog 最新的一行
echo "下次執行：$(systemctl show confluent-license-check.timer -p NextElapseUSecRealtime --value)"
echo "syslog：$(journalctl -t confluent-license -n 1 --no-pager -o cat)"
```

```out
下次執行：Sun 2026-10-25 08:00:00 CST
syslog：快到期：license trial 到期 2026-11-23，剩 29 天
```

> `SuccessExitStatus=2`：「快到期」不算服務失敗（不然 systemd 會把它標成 failed，維運以為是腳本壞了）；真正要告警的是 syslog 那一行。

## 26.3 換上正式 license（lab 沒有正式 license，未實測）

@role 小安 | ops02 | root

銀行向 Confluent 買到 license 後會拿到一串 JWT（`eyJ` 開頭）。銀行把它交給小安，小安放 `~/secrets/license.jwt`（0600，不放 CyberArk）。依原廠文件：

1. `~/conf/common.tpl` 的 License 區塊加 `confluent.license=${LICENSE}`（controller 與 broker 共用）；REST Proxy、C3 的範本各加一行 `confluent.license=${LICENSE}`。
2. 照第 10、12、13 章重新產生設定（`LICENSE=$(cat ~/secrets/license.jwt)` 帶進 `envsubst`）；密碼欄位照 15.3 一起加密。
3. 照 15.4、15.5 派送與滾動重啟（controller → broker → REST → C3）。
4. 用 26.1 確認：類型不再是 `trial`、到期日是合約的日期。

> 每年續約就是重做一次：換掉 `license.jwt`、重新產生、加密、滾動重啟。26.2 的告警在到期前 90 天開始，給採購流程留時間。

## 26.4 試用期到期：申請延長，或重置測試環境的叢集

![clusterreset]

**這一節在做什麼**：試用期（30 天，從叢集第一次啟動算起）快到了、正式 license 還沒買到時怎麼辦。**第一選擇是請原廠延長評估**：請銀行或我方的 Confluent 業務窗口申請臨時的評估 license，拿到後照 26.3 換上，不用重置、不丟資料。原廠來不及給、而且這是**測試或評估環境**時，才用這一節的「重置」：清空叢集、用新的 cluster id 重新格式化（試用期重新算 30 天），再從 23.3 的備份把 topic、權限、帳號建回來。

> 先講清楚授權：試用 license 是給評估用的。重置只用在採購前的測試／評估環境，**做之前先取得原廠同意（留 email）**；正式環境、以及採購後長期存在的 UAT／SIT 都要有 license（買的時候一起談），不能用重置延長試用。

**會清空的**：訊息內容、consumer 讀到的位置（重置後依應用程式的 `auto.offset.reset` 從頭或從尾開始）、**稽核 topic 裡的舊紀錄**（要留就先用選單 43 匯出）、C3 的 Streams 狀態（自動重建）。RBAC、SCRAM 帳號、配額、ACL 也會清空，由第 7 步從備份建回來；**SCRAM 用 `~/secrets` 裡原本的密碼，應用程式不用換密碼、不用改設定**。**不受影響的**：OS、套件、JDK、憑證、Secret Protection、各台設定檔與 drop-in、監控設定——第 10 章之後的設定都在，只是資料歸零。

**前提**：停服務、清資料要**安裝期的 sudo**（交付後的 `cpuser-ops` 不允許），請 OS 團隊照變更單臨時開、做完收回；23.3 的備份腳本已就緒；通知應用程式團隊停機時段（重置期間整個叢集不能用，lab 實測約 15 分鐘）。

這一節的指令只在需要時才做，整本照打實跑時不執行（會清空叢集，後面的章節就沒得跑了）；每一塊都在 lab 照原文實跑過（2026-10-30）。

@role 小安 | ops02 | root | 只在需要時做（會清空叢集，整本實跑不執行）

第 1 步：用 23.3 的腳本備份一次，記下這份備份的路徑；同時確認每個 SCRAM 帳號在 `~/secrets` 都有密碼檔（沒有的帳號重置後要另外發新密碼給應用程式團隊）：

```bash
# 1. 備份一次，路徑記在 ~/conf/reset-from.txt（第 7 步用）
d=$(bash ~/conf/metadata-backup.sh)
echo "$d" > ~/conf/reset-from.txt
echo "重置前的備份：$d"

# 2. 備份裡有多少東西
printf 'topic %s 個；principal %s 個；SCRAM 帳號 %s 個；ACL %s 條\n' \
  "$(grep -c '^Topic:' $d/topics.txt)" \
  "$(grep -c '^== ' $d/rbac.txt)" \
  "$(grep -c 'SCRAM credential configs' $d/users.txt)" \
  "$(grep -c '|' $d/acls.txt)"

# 3. 每個 SCRAM 帳號在 ~/secrets 有沒有密碼檔
missing=""

for u in $(grep -o "SCRAM credential configs for user-principal '[^']*'" $d/users.txt | cut -d"'" -f2); do
  if [ ! -s ~/secrets/$u.pass ]; then
    missing="$missing $u"
  fi
done

if [ -z "$missing" ]; then
  missing=無
fi

echo "缺密碼檔的 SCRAM 帳號：$missing"
```

```out
重置前的備份：/root/backup/metadata/20261030-1637
topic 18 個；principal 15 個；SCRAM 帳號 6 個；ACL 4 條
缺密碼檔的 SCRAM 帳號：無
```

> 列出來的帳號先對一下 27.6：**已經下線的帳號**（密碼被覆寫成隨機值、密碼檔已刪，帳號留著讓稽核日誌對得上人）也會出現在這裡，它們本來就不該建回來，不用補密碼檔。lab 做過第 27 章時會看到 `app-inventory-a app-inventory-b`，第 7 步也會把它們列在「沒有密碼檔」（2026-11-02 實測）。還在用的帳號出現在這裡，才要另外發新密碼。

第 2 步：停掉所有服務（C3 → REST Proxy → broker → controller）。Java 程式收到停止訊號時以 143 結束，systemd 會標成 `failed`，所以順手 `reset-failed`，結果應該全部是 `inactive`：

```bash
# 1. 依序停：C3 → REST Proxy → broker → controller
#    Java 收到停止訊號以 143 結束、被標成 failed，所以每台都接著 reset-failed
ssh c3-01.poc.lab 'sudo systemctl stop confluent-control-center'
ssh c3-01.poc.lab 'sudo systemctl reset-failed confluent-control-center'

for h in rest01 rest02; do
  ssh $h.poc.lab 'sudo systemctl stop confluent-kafka-rest'
  ssh $h.poc.lab 'sudo systemctl reset-failed confluent-kafka-rest'
done

for h in kb01 kb02 kb03 kb04 kc01 kc02 kc03; do
  ssh $h.poc.lab 'sudo systemctl stop confluent-server'
  ssh $h.poc.lab 'sudo systemctl reset-failed confluent-server'
done

# 2. 每台啟用中的 Confluent 服務現在的狀態（應該全部 inactive；每台執行 EOF 之前的那一段）
for h in c3-01 rest01 rest02 kb01 kb02 kb03 kb04 kc01 kc02 kc03; do
  ssh $h.poc.lab bash -s <<'EOF'
states=""

for u in confluent-server confluent-kafka-rest confluent-control-center; do
  if systemctl is-enabled -q $u 2> /dev/null; then
    states="$states $u=$(systemctl is-active $u)"
  fi
done

printf "%-7s%s\n" "$(hostname)" "$states"
EOF
done
```

```out
c3-01   confluent-control-center=inactive
rest01  confluent-kafka-rest=inactive
rest02  confluent-kafka-rest=inactive
kb01    confluent-server=inactive
（kb02–kb04、kc01–kc03 同樣是 confluent-server=inactive）
```

第 3 步：清空 controller 與 broker 的資料目錄，以及 C3 的 Streams 狀態（`/var/lib/confluent/control-center/` 底下數字開頭的目錄；`prometheus`、`alertmanager` 是 C3 畫面的歷史，留著）。用 `find … -delete`：`rm -rf data/*` 刪不到隱藏檔 `.kafka_cleanshutdown`，而萬用字元由 cpuser 的 shell 展開時讀不到 0750 的目錄、什麼都不刪也不報錯：

```bash
# 1. controller 與 broker 的資料目錄（find -delete 連點開頭的檔一起刪）
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo find /var/lib/kafka/data -mindepth 1 -delete'
  echo "$h：/var/lib/kafka/data 剩 $(ssh $h.poc.lab 'sudo find /var/lib/kafka/data -mindepth 1' | wc -l) 個"
done

# 2. C3 的 Streams 狀態：數字開頭的目錄（prometheus、alertmanager 是畫面的歷史，留著）
c3_dir=/var/lib/confluent/control-center
ssh c3-01.poc.lab "sudo find $c3_dir -mindepth 1 -maxdepth 1 -name '[0-9]*' -exec rm -rf {} +"
left=$(ssh c3-01.poc.lab "sudo find $c3_dir -mindepth 1 -maxdepth 1 -name '[0-9]*'" | wc -l)
echo "c3-01：Streams 狀態目錄剩 $left 個（prometheus、alertmanager 留著）"
```

```out
kc01：/var/lib/kafka/data 剩 0 個
（kc02、kc03、kb01–kb04 同樣剩 0 個）
c3-01：Streams 狀態目錄剩 0 個（prometheus、alertmanager 留著）
```

第 4 步：新的 cluster id、新的 controller directory id（舊的 `kraft.env` 另存），重新格式化。做過第 15 章之後 `server.properties` 裡是密文，格式化要帶 master key（和 25.1、25.2 同一個寫法）；controller 一起寫入 `kafka-admin`（沿用原本的密碼檔）：

```bash
export JAVA_HOME=/opt/java/current

# 1. 舊的 kraft.env 另存
cp -p ~/conf/kraft.env ~/conf/kraft.env.before-reset-$(date +%Y%m%d-%H%M)

# 2. 新的 cluster id 與三個 controller 的 directory id（0600）
install -m 0600 /dev/null ~/conf/kraft.env
echo "CLUSTER_ID=$(kafka-storage random-uuid)" >> ~/conf/kraft.env

for c in kc01 kc02 kc03; do
  echo "DIR_ID_$c=$(kafka-storage random-uuid)" >> ~/conf/kraft.env
done

source ~/conf/kraft.env
IC="1@kc01.poc.lab:9093:$DIR_ID_kc01,2@kc02.poc.lab:9093:$DIR_ID_kc02,3@kc03.poc.lab:9093:$DIR_ID_kc03"

# 3. controller：格式化並寫入 kafka-admin（密碼檔先 scp 到那台，讀完就刪）
#    每台以 root 執行 EOF 之前的那一段（$1 = cluster id、$2 = 初始成員）
for h in kc01 kc02 kc03; do
  scp -q ~/secrets/kafka-admin.pass $h.poc.lab:/tmp/ka.pass
  ssh $h.poc.lab sudo bash -e -s -- $CLUSTER_ID $IC <<'EOF'
# 讀 master key（設定檔有 ${securepass:…}，第 15 章，格式化工具也要拿得到）
set -a
. /etc/confluent/service.env
set +a

password=$(cat /tmp/ka.pass)
rm -f /tmp/ka.pass

# 以 cp-kafka 身分格式化（有 scram 字樣的行不印，只看最後一行）
runuser -u cp-kafka -- env \
  CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" \
  JAVA_HOME=/opt/java/current \
  KAFKA_HEAP_OPTS=-Xmx256m \
  KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
  kafka-storage format \
    --cluster-id $1 \
    --config /etc/confluent/kafka/server.properties \
    --initial-controllers $2 \
    --add-scram "SCRAM-SHA-512=[name=kafka-admin,password=$password]" 2>&1 | grep -v -i scram | tail -1

printf '%-5s cluster.id=%s\n' $(hostname) "$(sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)"
EOF
done
```

```out
Formatting dynamic metadata voter directory /var/lib/kafka/data with confluent.metadata.version 4.2-IV1A.
kc01  cluster.id=xxxxxxxxxxxxxxxxxxxxxx
…
```

@role 小安 | ops02 | root | 只在需要時做（會清空叢集，整本實跑不執行）

接著格式化 broker，再對一下新舊 cluster id：

```bash
source ~/conf/kraft.env

# 4. broker：以觀察者格式化；每台以 root 執行 EOF 之前的那一段（$1 = cluster id）
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab sudo bash -e -s -- $CLUSTER_ID <<'EOF'
# 讀 master key（設定檔有 ${securepass:…}，第 15 章，格式化工具也要拿得到）
set -a
. /etc/confluent/service.env
set +a

# 以 cp-kafka 身分格式化（只看最後一行）
runuser -u cp-kafka -- env \
  CONFLUENT_SECURITY_MASTER_KEY="$CONFLUENT_SECURITY_MASTER_KEY" \
  JAVA_HOME=/opt/java/current \
  KAFKA_HEAP_OPTS=-Xmx256m \
  KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml \
  kafka-storage format \
    --cluster-id $1 \
    --config /etc/confluent/kafka/server.properties \
    --no-initial-controllers 2>&1 | tail -1

printf '%-5s cluster.id=%s\n' $(hostname) "$(sed -n 's/^cluster.id=//p' /var/lib/kafka/data/meta.properties)"
EOF
done

# 5. 新舊 cluster id（舊的從最新一份另存的 kraft.env 讀）
old_env=$(ls -t ~/conf/kraft.env.before-reset-* | head -1)
old_id=$(grep CLUSTER_ID $old_env | cut -d= -f2)
echo "新的 cluster id：$CLUSTER_ID（舊的：$old_id）"
```

```out
Formatting metadata directory /var/lib/kafka/data with confluent.metadata.version 4.2-IV1A.
kb01  cluster.id=xxxxxxxxxxxxxxxxxxxxxx
…
新的 cluster id：xxxxxxxxxxxxxxxxxxxxxx（舊的：yyyyyyyyyyyyyyyyyyyyyy）
```

（metadata 版本字串跟著安裝的版本走：8.2.4 是 4.2-IV1A，遷移到 8.3.2 之後是 4.3-IV0B。）

第 5 步：啟動 controller、確認 quorum；再啟動 broker，等四台的 MDS 都回 200，MDS 看到的要是新的 cluster id：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem
CONTROLLERS=kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093
Q="--bootstrap-controller $CONTROLLERS --command-config $HOME/conf/client-internal.properties"

# 1. 啟動 controller，等 quorum 有 leader：每 5 秒看一次，最多 30 次
for h in kc01 kc02 kc03; do
  ssh $h.poc.lab 'sudo systemctl start confluent-server'
done

for i in $(seq 1 30); do
  if kafka-metadata-quorum $Q describe --status 2> /dev/null | grep -q '^LeaderId: *[0-9]'; then
    break
  fi

  sleep 5
done

# 只看這三行；CurrentVoters 裡的 directoryId、endpoints 太長，拿掉
kafka-metadata-quorum $Q describe --status 2> /dev/null \
  | grep -E '^(ClusterId|LeaderId|CurrentVoters)' \
  | sed 's/"directoryId"[^}]*//g; s/"endpoints"[^}]*//g'

# 2. 啟動 broker，等四台 MDS 都回 200：每 5 秒看一次，最多 60 次
for h in kb01 kb02 kb03 kb04; do
  ssh $h.poc.lab 'sudo systemctl start confluent-server'
done

for i in $(seq 1 60); do
  # 這一輪有幾台回 200
  ready=0

  for b in kb01 kb02 kb03 kb04; do
    url=https://$b.poc.lab:8090/v1/metadata/id

    if [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' --cacert $CA $url)" = 200 ]; then
      ready=$((ready + 1))
    fi
  done

  if [ "$ready" = 4 ]; then
    break
  fi

  sleep 5
done

# 3. MDS 看到的要是新的 cluster id
mds_cluster=$(curl -s --cacert $CA https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
echo "broker 的 MDS 回 200：$ready / 4（約 $((i * 5)) 秒）；MDS 看到的 cluster id：$mds_cluster"
```

```out
ClusterId:              xxxxxxxxxxxxxxxxxxxxxx
LeaderId:               2
CurrentVoters:          [{"id": 1, }, {"id": 2, }, {"id": 3, }]
broker 的 MDS 回 200：4 / 4（約 45 秒）；MDS 看到的 cluster id：xxxxxxxxxxxxxxxxxxxxxx
```

第 6 步：叢集剛起來一條 binding 都沒有，和第 11 章一樣，用 `kafka-internal` 的憑證建第一條 `User:svc-ops → SystemAdmin`：

```bash
export JAVA_HOME=/opt/java/current
source ~/conf/kraft.env

# 1. 用 kafka-internal 的憑證登入 MDS（super.users 只有它，叢集剛起來時只有它能寫 binding）
confluent login \
  --url https://kb01.poc.lab:8090 \
  --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only \
  --client-cert-path ~/pki/certs/kafka-internal.crt \
  --client-key-path ~/pki/keys/kafka-internal.key > /dev/null

# 2. 第一條 binding，然後列出來看
confluent iam rbac role-binding create \
  --principal User:svc-ops \
  --role SystemAdmin \
  --kafka-cluster "$CLUSTER_ID" > /dev/null
confluent iam rbac role-binding list --principal User:svc-ops --kafka-cluster "$CLUSTER_ID" | tail -n +3
```

```out
  User:svc-ops | SystemAdmin | Cluster       |      |
```

第 7 步：從第 1 步的備份全部建回來。寫成一支小腳本 `cluster-restore-all.sh`：應用程式 topic（名稱有「.」、不是底線開頭，也就是命名規範 `<系統>.<名稱>` 的；內部 topic、稽核 topic、C3 的 topic 由平台自己重建）連同 partition 數、RF、動態設定；**全部** role binding（AD 群組、憑證身分、應用程式）；SCRAM 帳號（迭代次數照備份、密碼讀 `~/secrets`）；配額；ACL；broker 動態設定。和 23.6 的 `metadata-restore.sh` 不同的是範圍：那支一次還原一個 topic、一個帳號，這支全部。**整段貼到 EOF**：

```bash
cat > ~/conf/cluster-restore-all.sh <<'EOF'
#!/usr/bin/env bash
# cluster-restore-all.sh <備份目錄> — 叢集重置（26.4）之後，從 23.3 的備份全部建回來
# 做什麼：應用程式 topic（partition 數、RF、動態設定）、全部 role binding、SCRAM 帳號（密碼用 ~/secrets 原本的）、配額、ACL、broker 動態設定
# 不還原的：底線開頭的內部 topic、稽核 topic、C3 的內部 topic（平台自己重建）；訊息內容與 consumer 讀到的位置（備份裡本來就沒有）
# 結束碼：0 全部建回來、1 有東西沒建回來（失敗的那一項會印出來）
# 改的時候要注意：讀檔的格式要和 metadata-backup.sh 寫出來的一致；MDS 寫入只在 50003（not the current leader）時再送一次（28.4）
set -f   # 關掉萬用字元展開：備份裡有 Topic:* 這種名稱，不能被 shell 換成檔名

backup=$1

if [ ! -d "$backup" ]; then
  echo "用法：cluster-restore-all.sh <備份目錄>"
  exit 1
fi

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config /root/conf/client-admin.properties"
source ~/conf/kraft.env
bad=0

# ---- 1. 應用程式 topic：名稱有「.」、不是底線開頭（命名規範 <系統>.<名稱>）----
topic_count=0

for topic in $(grep -oP '^Topic: \K[^\t]+' "$backup/topics.txt" | grep '\.' | grep -v '^_'); do
  # topics.txt 裡這個 topic 的第一行：PartitionCount 與 ReplicationFactor
  line=$(grep -P "^Topic: $topic\t" "$backup/topics.txt" | head -1)
  partitions=$(echo "$line" | grep -o 'PartitionCount: [0-9]*' | cut -d' ' -f2)
  rf=$(echo "$line" | grep -o 'ReplicationFactor: [0-9]*' | cut -d' ' -f2)

  # 動態設定：topic-configs.txt 裡「Dynamic configs for topic <名稱> are:」底下那幾行的第一欄（key=value）
  config_args=""

  config_lines=$(awk -v t="$topic" '
    $0 == "Dynamic configs for topic " t " are:" { p = 1; next }
    /^Dynamic configs/ { p = 0 }
    p { print $1 }
  ' "$backup/topic-configs.txt")

  for kv in $config_lines; do
    config_args="$config_args --config $kv"
  done

  if kafka-topics $A --create --if-not-exists \
    --topic "$topic" \
    --partitions "$partitions" \
    --replication-factor "$rf" \
    $config_args > /dev/null 2>&1; then
    topic_count=$((topic_count + 1))
  else
    echo "topic $topic 失敗"
    bad=1
  fi
done

echo "topic：$topic_count 個"

# ---- 2. role binding：rbac.txt 裡每個 principal 的每一行（一行一條：principal|角色|資源類型|資源名稱|比對方式）----
if ! confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only \
  --client-cert-path ~/pki/certs/svc-ops.crt \
  --client-key-path ~/pki/keys/svc-ops.key > /dev/null; then
  echo "svc-ops 登不進 MDS（第 6 步做了嗎？）"
  exit 1
fi

# create_binding <參數…>：建一條 binding；只有 50003（auth topic 的 leader 剛搬家，MDS 內部的 producer 不重試）才再送一次
create_binding() {
  local result

  if result=$(confluent iam rbac role-binding create "$@" 2>&1); then
    return 0
  fi

  if echo "$result" | grep -q "not the current leader"; then
    confluent iam rbac role-binding create "$@" > /dev/null 2>&1
    return
  fi

  return 1
}

# restore_binding <principal> <角色> <資源類型> <資源名稱> <比對方式>：整個 cluster 的不給 --resource；PREFIXED 的多加 --prefix
restore_binding() {
  if [ -z "$4" ]; then
    create_binding --principal "$1" --role "$2" --kafka-cluster "$CLUSTER_ID"
  elif [ "$5" = PREFIXED ]; then
    create_binding --principal "$1" --role "$2" --kafka-cluster "$CLUSTER_ID" --resource "$3:$4" --prefix
  else
    create_binding --principal "$1" --role "$2" --kafka-cluster "$CLUSTER_ID" --resource "$3:$4"
  fi
}

binding_count=0
bindings=$(mktemp)
grep -v '^== ' "$backup/rbac.txt" > $bindings

while IFS='|' read -r principal role rtype rname pattern; do
  # 去掉每一欄前後的空白
  principal=$(echo $principal)
  role=$(echo $role)
  rtype=$(echo $rtype)
  rname=$(echo $rname)
  pattern=$(echo $pattern)

  # 空行或缺欄位的行跳過
  if [ -z "$principal" ]; then
    continue
  fi

  if [ -z "$role" ]; then
    continue
  fi

  if restore_binding "$principal" "$role" "$rtype" "$rname" "$pattern"; then
    binding_count=$((binding_count + 1))
  else
    echo "binding 失敗：$principal $role $rtype:$rname"
    bad=1
  fi
done < $bindings

rm -f $bindings
echo "role binding：$binding_count 條"

# ---- 3. SCRAM 帳號：迭代次數照備份（沒有就 8192）、密碼讀 ~/secrets/<帳號>.pass；沒有密碼檔的列出來，要另外發新密碼 ----
scram_count=0
missing=""

for user in $(grep -o "SCRAM credential configs for user-principal '[^']*'" "$backup/users.txt" | cut -d"'" -f2); do
  iterations=$(grep "SCRAM credential configs for user-principal '$user'" "$backup/users.txt" \
    | grep -o 'iterations=[0-9]*' \
    | head -1)

  if [ -z "$iterations" ]; then
    iterations=iterations=8192
  fi

  if [ ! -s ~/secrets/$user.pass ]; then
    missing="$missing $user"
    continue
  fi

  # 出錯時 kafka-configs 會印出密碼，所以輸出丟掉
  user_password=$(cat ~/secrets/$user.pass)

  if kafka-configs $A --alter --entity-type users --entity-name "$user" \
    --add-config "SCRAM-SHA-512=[$iterations,password=$user_password]" > /dev/null 2>&1; then
    scram_count=$((scram_count + 1))
  else
    echo "SCRAM $user 失敗"
    bad=1
  fi
done

if [ -z "$missing" ]; then
  missing=" 無"
fi

echo "SCRAM 帳號：$scram_count 個；沒有密碼檔：$missing"

# ---- 4. 配額（有些是只用憑證的帳號，沒有 SCRAM 也有配額）：一行一個「帳號 key=value,key=value」----
quota_count=0
quotas=$(mktemp)
grep "^Quota configs for user-principal" "$backup/users.txt" | sed \
  -e "s/^Quota configs for user-principal '//" \
  -e "s/' are / /" \
  -e 's/\.0\b//g' \
  -e 's/, /,/g' > $quotas

while read -r user quota; do
  if kafka-configs $A --alter --entity-type users --entity-name "$user" --add-config "$quota" > /dev/null 2>&1; then
    quota_count=$((quota_count + 1))
  else
    echo "配額 $user 失敗"
    bad=1
  fi
done < $quotas

rm -f $quotas
echo "配額：$quota_count 個帳號"

# ---- 5. ACL：acls.txt 一行一條：資源類型|名稱|比對方式|principal|host|操作|ALLOW/DENY ----
acl_count=0

while IFS='|' read -r rtype name pat principal host op perm; do
  if [ -z "$op" ]; then
    continue
  fi

  # 資源
  case $rtype in
    TOPIC)
      resource="--topic $name"
      ;;
    GROUP)
      resource="--group $name"
      ;;
    CLUSTER)
      resource="--cluster"
      ;;
    TRANSACTIONAL_ID)
      resource="--transactional-id $name"
      ;;
    *)
      echo "不認得的資源類型 $rtype"
      bad=1
      continue
      ;;
  esac

  if [ "$pat" = PREFIXED ]; then
    resource="$resource --resource-pattern-type prefixed"
  fi

  # 操作：備份裡是 DESCRIBE_CONFIGS 這種寫法，kafka-acls 要 DescribeConfigs
  operation=$(awk -v s="$op" '
    BEGIN {
      n = split(tolower(s), a, "_")

      for (i = 1; i <= n; i++) {
        printf "%s", toupper(substr(a[i], 1, 1)) substr(a[i], 2)
      }
    }
  ')

  # 誰：ALLOW 或 DENY；host 不是 * 才指定
  if [ "$perm" = DENY ]; then
    who="--deny-principal $principal"

    if [ "$host" != '*' ]; then
      who="$who --deny-host $host"
    fi
  else
    who="--allow-principal $principal"

    if [ "$host" != '*' ]; then
      who="$who --allow-host $host"
    fi
  fi

  if kafka-acls $A --add $who --operation "$operation" $resource > /dev/null 2>&1; then
    acl_count=$((acl_count + 1))
  else
    echo "ACL 失敗：$rtype:$name $principal $op"
    bad=1
  fi
done < "$backup/acls.txt"

echo "ACL：$acl_count 條"

# ---- 6. broker 動態設定（叢集層級的預設值）----
default_count=0

config_lines=$(awk '
  /^Default configs for brokers/ { p = 1; next }
  p { print $1 }
' "$backup/broker-configs.txt")

for kv in $config_lines; do
  if kafka-configs $A --alter --entity-type brokers --entity-default --add-config "$kv" > /dev/null 2>&1; then
    default_count=$((default_count + 1))
  else
    echo "broker 設定 $kv 失敗"
    bad=1
  fi
done

echo "broker 動態設定：$default_count 個"

exit $bad
EOF

chmod 0700 ~/conf/cluster-restore-all.sh

# 用第 1 步記下的那份備份（SLF4J 的警告行不印）
bash ~/conf/cluster-restore-all.sh "$(cat ~/conf/reset-from.txt)" 2>&1 | grep -v '^SLF4J'
```

```out
topic：5 個
role binding：33 條
SCRAM 帳號：6 個；沒有密碼檔： 無
配額：5 個帳號
ACL：4 條
broker 動態設定：1 個
```

> 陷阱（lab 實測）：備份的 `rbac.txt` 裡有 `Topic:*` 這種名稱，腳本開頭的 `set -f` 不能拿掉：少了它，`*` 會被 shell 換成當前目錄的檔名，那條 binding 就建錯（23.6 的 `metadata-restore.sh` 也加了）。

第 8 步：啟動 REST Proxy 與 C3，確認經 LB 的 REST 與 C3 都回 200，並用 26.1 的讀法看 license：類型 `trial`、到期日是今天加 30 天：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 經 LB 的 REST Proxy 用 app-legacy-billing 的憑證
REST_CERT="--cert $HOME/pki/certs/app-legacy-billing.crt --key $HOME/pki/keys/app-legacy-billing.key"

# 1. 啟動 REST Proxy 與 C3
for h in rest01 rest02; do
  ssh $h.poc.lab 'sudo systemctl start confluent-kafka-rest'
done

ssh c3-01.poc.lab 'sudo systemctl start confluent-control-center'

# 2. 等兩個都回 200：每 5 秒看一次，最多 60 次
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' $REST_CERT https://rest.poc.lab:8082/v3/clusters)" = 200 ]; then
    if [ "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
      break
    fi
  fi

  sleep 5
done

printf 'REST 經 LB=%s C3=%s（約 %s 秒）\n' \
  "$(curl -s -o /dev/null -w '%{http_code}' $REST_CERT https://rest.poc.lab:8082/v3/clusters)" \
  "$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)" \
  "$((i * 5))"

# 3. license：26.1 的讀法
jwt=$(kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9094 \
  --consumer.config ~/conf/client-admin.properties \
  --topic _confluent-command \
  --from-beginning \
  --timeout-ms 20000 2> /dev/null \
  | grep -a -o 'eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*' \
  | tail -1)
payload=$(echo "$jwt" | cut -d. -f2 | tr '_-' '/+')

while [ $(( ${#payload} % 4 )) != 0 ]; do
  payload="$payload="
done

claims=$(echo "$payload" | base64 -d 2> /dev/null)
license_type=$(echo "$claims" | grep -o '"licenseType":"[^"]*"' | cut -d'"' -f4)
expires_at=$(echo "$claims" | grep -o '"exp":[0-9]*' | cut -d: -f2)
echo "license：$license_type，到期 $(date -d @$expires_at '+%F %T')，剩 $(( (expires_at - $(date +%s)) / 86400 )) 天"

unset jwt payload claims license_type expires_at
```

```out
REST 經 LB=200 C3=200（約 55 秒）
license：trial，到期 2026-11-29 16:42:33，剩 29 天
```

最後照第 19 章驗收（19.1–19.3：健康、安全、應用程式寫讀）。lab 實測：健康 22／22、安全 16／16，app-orders 用原本的密碼直連寫讀、app-legacy-billing 經 LB 寫入、alice 經 AD 群組讀得到，都過。做完請 OS 團隊收回安裝期的 sudo。

> 26.2 的每日檢查會在新的試用期剩不到 90 天時就開始告警（試用本來就只有 30 天），這是預期的；它要提醒的是「正式 license 還沒到」。

# 27. 第二十七站：新應用上線

下面這張圖是一個新應用程式從申請到上線、到下線的七步，和兩種應用程式（直連 SCRAM、走 REST 憑證）各自不同的地方。

![onboard]

**這一章在做什麼**：第 11、12 章建的是安裝時的範例應用程式；正式環境之後每一個新系統都要走同一條路：申請單（27.1）→ 建 topic（27.2）→ 身分、權限、配額（27.3）→ 交付（27.4）→ 驗證（27.5）→ 將來下線（27.6）。日常由維運人員用 OP menu 31／34／42 做，這一章是選單背後的手動指令，lab 用兩個假的系統走一遍：`app-inventory` 直連（SCRAM A／B）、`app-shipping` 走 REST Proxy（憑證）。前提：第 11 章的 `client-admin.properties`、第 9 章的 `~/pki`、第 12 章的 REST Proxy 都在。完成的樣子：兩個系統各寫一筆、讀回一筆（走 REST 的那個要先進 REST Proxy 的 CN 白名單、照 12.1 重啟兩台）；下線後帳號登不進、binding 0 條、topic 刪掉、`~/pki` 沒留下 app-shipping。

## 27.1 申請單：應用程式團隊要給什麼

@role 應用程式團隊 → 維運人員 | — | —

| 欄位 | 例子 | 用在哪 |
|---|---|---|
| 系統代號 | `inventory`、`shipping` | topic 前綴 `<系統>.`、consumer group 前綴 `<系統>-`、帳號名 `app-<系統>` |
| topic 清單：名稱、partition 數、保留天數 | `inventory.stock` 3 個 partition、3 天 | 27.2；partition 數決定消費者最多幾個平行；RF 固定 3、`min.insync.replicas` 固定 2，不開放申請 |
| 連線方式 | 直連 Kafka（SCRAM）或走 REST Proxy（憑證） | 27.3：SCRAM 給 A／B 兩個帳號；REST 給一張 client 憑證（REST 只收憑證） |
| 讀、寫哪些 topic；要不要自己建 topic | 讀寫 `inventory.*`、不建 | role binding 的 role：`DeveloperRead`／`DeveloperWrite`，要自己建才給 `DeveloperManage` |
| 流量（每秒 MB、請求數） | 寫 5 MB/s、讀 10 MB/s | 配額 `producer_byte_rate`、`consumer_byte_rate`、`request_percentage`（每台 broker） |
| 聯絡人、環境、上線日 | — | 交付對象；稽核日誌（第 18 章）查得到是誰 |

兩種連線方式的差別：直連用 Kafka 原生協定（9095，SASL_SSL＋SCRAM-SHA-512），consumer group 自己管；走 REST 只有 HTTP produce／consume，身分是憑證的 CN，沒有密碼可換、憑證到期前要換發（第 21 章）。沒有第三種：REST 不開密碼登入，直連不發憑證給應用程式。

## 27.2 建 topic

@role 維運人員 | ops02 | root

命名 `<系統>.<名稱>`；RF 3、`min.insync.replicas=2` 是 broker 預設（第 10 章），不在這裡改；保留天數照申請單。選單 31 做的就是這個：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"

# 1. 兩個 topic：3 個 partition、RF 3；保留天數照申請單（inventory 3 天、shipping 7 天）
kafka-topics $A --create --if-not-exists \
  --topic inventory.stock \
  --partitions 3 \
  --replication-factor 3 \
  --config retention.ms=259200000 > /dev/null
kafka-topics $A --create --if-not-exists \
  --topic shipping.events \
  --partitions 3 \
  --replication-factor 3 \
  --config retention.ms=604800000 > /dev/null

# 2. 看 partition 數、RF、retention
for t in inventory.stock shipping.events; do
  first_line=$(kafka-topics $A --describe --topic $t | head -1)
  summary=$(echo "$first_line" | grep -oE 'PartitionCount: [0-9]+\s+ReplicationFactor: [0-9]+' | tr -s '\t' ' ')
  retention=$(kafka-configs $A --describe --entity-type topics --entity-name $t \
    | grep -oE 'retention.ms=[0-9]+' \
    | head -1)
  echo "$t: $summary，retention $retention"
done
```

```out
inventory.stock: PartitionCount: 3 ReplicationFactor: 3，retention retention.ms=259200000
shipping.events: PartitionCount: 3 ReplicationFactor: 3，retention retention.ms=604800000
```

## 27.3 身分、權限、配額

@role 維運人員 | ops02 | root

**直連的系統：A／B 兩個 SCRAM 帳號**（第 11 章的做法，選單 34 一次做完）。密碼各自產生、各自一個 0600 檔；兩個帳號權限一模一樣：`inventory.` 前綴的讀寫、`inventory-` 前綴的 consumer group；配額照申請單，兩個帳號都設：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"
source ~/conf/kraft.env

# svc-ops 登入 MDS（建 binding 用）
confluent login \
  --url https://kb01.poc.lab:8090 \
  --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only \
  --client-cert-path ~/pki/certs/svc-ops.crt \
  --client-key-path ~/pki/keys/svc-ops.key > /dev/null

for a in app-inventory-a app-inventory-b; do
  # 1. 密碼檔（0600）
  install -m 0600 /dev/null ~/secrets/$a.pass
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/$a.pass

  # 2. SCRAM 帳號與配額（kafka-configs 出錯時會印出密碼，所以輸出丟掉）
  kafka-configs $A --alter --entity-type users --entity-name $a \
    --add-config "SCRAM-SHA-512=[iterations=8192,password=$(cat ~/secrets/$a.pass)]" > /dev/null 2>&1
  kafka-configs $A --alter --entity-type users --entity-name $a \
    --add-config 'producer_byte_rate=5242880,consumer_byte_rate=10485760,request_percentage=50' > /dev/null 2>&1

  # 3. 三條 binding：inventory. 前綴的寫與讀、inventory- 前綴的 consumer group
  for role in DeveloperWrite DeveloperRead; do
    confluent iam rbac role-binding create \
      --principal User:$a \
      --role $role \
      --resource Topic:inventory. \
      --prefix \
      --kafka-cluster $CLUSTER_ID > /dev/null
  done
  confluent iam rbac role-binding create \
    --principal User:$a \
    --role DeveloperRead \
    --resource Group:inventory- \
    --prefix \
    --kafka-cluster $CLUSTER_ID > /dev/null

  # 4. 確認：SCRAM 迭代次數、配額、binding 條數
  scram=$(kafka-configs $A --describe --entity-type users --entity-name $a 2> /dev/null \
    | grep -o 'SCRAM-SHA-512=iterations=[0-9]*' \
    | head -1)
  quota=$(kafka-configs $A --describe --entity-type users --entity-name $a 2> /dev/null \
    | grep -o 'producer_byte_rate=[0-9.]*' \
    | head -1)
  binding_count=$(confluent iam rbac role-binding list --principal User:$a --kafka-cluster $CLUSTER_ID -o json \
    | awk '/"role"/ {c++} END {print c + 0}')
  echo "$a: SCRAM $scram，配額 $quota，binding $binding_count 條"
done
```

```out
app-inventory-a: SCRAM SCRAM-SHA-512=iterations=8192，配額 producer_byte_rate=5242880.0，binding 3 條
app-inventory-b: SCRAM SCRAM-SHA-512=iterations=8192，配額 producer_byte_rate=5242880.0，binding 3 條
```

**走 REST 的系統：一張 client 憑證**。和第 9 章一樣：操作機產私鑰與 CSR（CN 就是帳號名，EKU `clientAuth`），加進 `~/pki/requests.txt`（之後第 21 章換發時才會一起算進去），送銀行 CA 簽：

```bash
cd ~/pki

# 1. 加進 requests.txt（已經有就不加；第 21 章換發時才會一起算進去）
if ! grep -q '^app-shipping ' requests.txt; then
  echo 'app-shipping       clientAuth             -' >> requests.txt
fi

# 2. 私鑰（0600）
install -m 0600 /dev/null keys/app-shipping.key
openssl genrsa -out keys/app-shipping.key 2048 2> /dev/null

# 3. CSR：CN 就是帳號名，EKU clientAuth
openssl req -new -key keys/app-shipping.key -sha256 -subj "/CN=app-shipping/O=PoC Bank/C=TW" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=clientAuth" \
  -out requests/app-shipping.csr

echo "app-shipping: csr ok；$(openssl req -in requests/app-shipping.csr -noout -subject)"
```

```out
app-shipping: csr ok；subject=CN=app-shipping, O=PoC Bank, C=TW
```

@role 銀行 CA 窗口（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

正式環境走 9.2 一樣的管道（檔案交換平台送 CSR、收回憑證鏈）。lab：只簽這一張，放回 `~/pki/incoming/`；用**現行**的 CA：不是看目錄存不存在，而是看哪個目錄的中繼憑證能被平台現在信任的根（操作機的 `bank-root.pem`）驗證通過（21.3 換過 CA 之後是 `ca/g2`；21.4 換鏈之後中繼改由 G3 簽，仍在 `ca/g2`；沒換過是 `ca`）：

```bash
cd ~/kafka-lab

# 1. 平台現在信任的根（操作機的 bank-root.pem）
podman exec lab-ops02-1 cat /etc/pki/ca-trust/source/anchors/bank-root.pem > ca/exchange/anchor.pem

# 2. 哪個 CA 目錄的中繼憑證能被這個根驗證通過，就用哪個
d=""

for c in ca ca/g2; do
  if [ -f $c/issuing.crt ]; then
    anchor=$(cygpath -m ca/exchange/anchor.pem)
    issuing=$(cygpath -m $c/issuing.crt)

    if openssl verify -CAfile "$anchor" "$issuing" > /dev/null 2>&1; then
      d=$c
    fi
  fi
done

if [ -z "$d" ]; then
  echo "沒有一個 CA 目錄的中繼憑證能被平台信任"
  false
fi

# 3. 取回 CSR、簽、把憑證放回操作機的 ~/pki/incoming/
mkdir -p ca/exchange/requests ca/exchange/signed
podman cp lab-ops02-1:/root/pki/requests/app-shipping.csr "$(cygpath -m "$PWD/ca/exchange/requests/app-shipping.csr")"
bash $d/sign.sh ca/exchange/requests/app-shipping.csr ca/exchange/signed/app-shipping.crt | sed "s/  (.*//"
podman cp "$(cygpath -m "$PWD/ca/exchange/signed/app-shipping.crt")" lab-ops02-1:/root/pki/incoming/
echo "用 $d 簽"
```

```out
signed app-shipping.csr -> app-shipping.crt
用 ca/g2 簽
```

@role 維運人員 | ops02 | root

收回來照 9.3 檢查（公鑰對得上私鑰、CN、EKU、鏈驗證、天數），做成 `.crt`（leaf＋中繼）和交給應用程式的 `.p12`。這個 p12 用**它自己的密碼**（`~/secrets/app-shipping-p12.pass`），不用平台的 `store.pass`：

```bash
cd ~/pki
n=app-shipping
leaf=incoming/$n.leaf.pem

# 1. 拆開回覆（同 9.3）：第一張是 leaf，其餘是中繼 CA
sed '/END CERTIFICATE/q' incoming/$n.crt > $leaf
sed '1,/END CERTIFICATE/d' incoming/$n.crt > incoming/$n.issuers.pem

# 2. 私鑰相符：憑證和私鑰的公鑰 sha256 前 16 碼一樣，才是一對
cert_pub=$(openssl x509 -in $leaf -pubkey -noout | sha256sum | cut -c1-16)
key_pub=$(openssl pkey -in keys/$n.key -pubout 2> /dev/null | sha256sum | cut -c1-16)

if [ "$cert_pub" = "$key_pub" ]; then
  key=ok
else
  key=MISMATCH
fi

# 3. CN 要等於帳號名（主旨的樣子：subject=CN=app-shipping,O=PoC Bank,C=TW）
subject=$(openssl x509 -in $leaf -noout -subject -nameopt sep_comma_plus,sname)
cn=$(echo "$subject" | grep -o 'CN=[^,]*' | cut -d= -f2)

if [ "$cn" = "$n" ]; then
  cn=ok
fi

# 4. 鏈要驗得到銀行根憑證
if openssl verify \
  -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem \
  -untrusted incoming/$n.issuers.pem \
  $leaf > /dev/null 2>&1; then
  chain=ok
else
  chain=FAIL
fi

# 5. EKU（用途，例 TLSWebClientAuthentication）與還有幾天到期，直接印出來看
eku=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage | tail -n +2 | tr -d ' ')
end_date=$(openssl x509 -in $leaf -noout -enddate | cut -d= -f2)
end_epoch=$(date -d "$end_date" +%s)
days=$(( (end_epoch - $(date +%s)) / 86400 ))

printf '%s key=%s cn=%s eku=%s days=%s chain=%s\n' $n $key "$cn" "$eku" "$days" $chain
```

```out
app-shipping key=ok cn=ok eku=TLSWebClientAuthentication days=364 chain=ok
```

檢查都過了，再做正式的 PEM 和交給應用程式的 p12：

```bash
cd ~/pki
n=app-shipping

# 1. 正式的 PEM（leaf＋中繼）
cat incoming/$n.leaf.pem incoming/$n.issuers.pem > certs/$n.crt

# 2. 交給應用程式的 p12：用它自己的密碼（0600），不用平台的 store.pass
install -m 0600 /dev/null ~/secrets/$n-p12.pass
openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/secrets/$n-p12.pass
openssl pkcs12 -export \
  -name $n \
  -inkey keys/$n.key \
  -in certs/$n.crt \
  -out certs/$n.p12 \
  -passout file:$HOME/secrets/$n-p12.pass
chmod 0600 certs/$n.p12

echo "certs/$n.crt、certs/$n.p12 做好（p12 密碼 ~/secrets/$n-p12.pass）"
```

```out
certs/app-shipping.crt、certs/app-shipping.p12 做好（p12 密碼 ~/secrets/app-shipping-p12.pass）
```

憑證的身分是 `User:app-shipping`（CN）。綁 `shipping.` 前綴的讀寫，配額一樣設在這個 principal 上（REST Proxy 用應用程式的身分向 Kafka 寫，配額照樣算）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"
source ~/conf/kraft.env

# 1. 兩條 binding：shipping. 前綴的寫與讀
for role in DeveloperWrite DeveloperRead; do
  confluent iam rbac role-binding create \
    --principal User:app-shipping \
    --role $role \
    --resource Topic:shipping. \
    --prefix \
    --kafka-cluster $CLUSTER_ID > /dev/null
done

# 2. 配額
kafka-configs $A --alter --entity-type users --entity-name app-shipping \
  --add-config 'producer_byte_rate=1048576,consumer_byte_rate=2097152,request_percentage=25' > /dev/null 2>&1

# 3. 確認
quota=$(kafka-configs $A --describe --entity-type users --entity-name app-shipping 2> /dev/null \
  | grep -o 'producer_byte_rate=[0-9.]*' \
  | head -1)
binding_count=$(confluent iam rbac role-binding list --principal User:app-shipping --kafka-cluster $CLUSTER_ID -o json \
  | awk '/"role"/ {c++} END {print c + 0}')
echo "app-shipping: binding $binding_count 條，配額 $quota"
```

```out
app-shipping: binding 2 條，配額 producer_byte_rate=1048576.0
```

**REST Proxy 的白名單**：REST Proxy 不是看到任何銀行簽的憑證都放行，第 12 章的 `auth.ssl.principal.mapping.rules` 只把**列在規則裡的 CN** 對應成 principal（來源是安裝時的 `apps.txt`），其他憑證一律 401（19.2 驗過：svc-ops 的憑證也進不來）。所以新 REST 應用程式還要把 CN 加進兩台 REST 的規則，再照 12.1 一台一台重啟（規則不是密碼欄位，直接改各台的設定檔就好；操作機上的副本一起改，下次第 12 章重派送才不會蓋掉）：

```bash
# sed 規則：principal.mapping.rules 那一行的 CN=(…) 裡還沒有 app-shipping 就加上去
#   例：CN=(app-legacy-billing) → CN=(app-legacy-billing|app-shipping)；已經有就不動
rule='/principal\.mapping\.rules/ { /\(app-shipping[)|]|\|app-shipping[)|]/! s/CN=\(([^)]*)\)/CN=(\1|app-shipping)/ }'

for h in rest01 rest02; do
  # 1. 那台的設定檔
  ssh $h.poc.lab "sudo sed -i -E '$rule' /etc/confluent/kafka-rest/kafka-rest.properties"

  # 2. 操作機上的副本（有哪個改哪個；下次第 12 章重派送才不會蓋掉）
  for f in ~/conf/$h.kafka-rest.properties ~/conf/sp/$h.kafka-rest.properties ~/conf/sp/$h.properties; do
    if [ -f $f ]; then
      sed -i -E "$rule" $f
    fi
  done

  # 3. 看結果
  echo "$h: $(ssh $h.poc.lab "sudo grep -o 'CN=([^)]*)' /etc/confluent/kafka-rest/kafka-rest.properties | sort -u")"
done
```

```out
rest01: CN=(app-legacy-billing|app-shipping)
rest02: CN=(app-legacy-billing|app-shipping)
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 維運人員 | ops02 | root

```bash
~/conf/rest-restart.sh rest01
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 維運人員 | ops02 | root

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

> 腳本版（`27-onboard.sh onboard <系統> cert`）是把應用程式加進 `conf/apps.txt` 再重跑第 12 站：規則由範本重新產生、兩台 REST 重啟。正式環境也可以這樣做，但重啟一定要照 12.1 先請 LB 團隊停用那一台。

## 27.4 交付

@role 維運人員 | ops02 | root

| 給誰 | 什麼 | 怎麼給 |
|---|---|---|
| 直連的系統 | `app-inventory-a`、`-b` 的密碼、bootstrap `kb01..kb04:9095`、銀行根憑證（truststore 用）、SASL 設定範例 | 密碼寫進交接檔（0600，只有本人讀得到），走銀行的機敏資料交付管道給應用程式團隊，交完刪；選單 34 自動寫交接檔 |
| 走 REST 的系統 | `app-shipping.p12`、它的密碼（另一個管道）、銀行根憑證、網址 `https://rest.poc.lab:8082` | 同上；p12 和密碼分開送 |
| 稽核 | 申請單編號、建了什麼（topic、帳號、binding、配額）、交給誰 | 變更單；Kafka 稽核日誌（第 18 章）記得到之後每一次存取 |

lab 把交接檔寫出來看格式（內容不印到畫面）：

```bash
install -d -m 0700 ~/handover

# 1. 直連系統的交接檔（0600）：bootstrap、協定、兩個帳號的密碼；畫面不印內容
f=~/handover/app-inventory-$(date +%F).txt
bootstrap=kb01.poc.lab:9095,kb02.poc.lab:9095,kb03.poc.lab:9095,kb04.poc.lab:9095
install -m 0600 /dev/null $f
echo "app-inventory（$(date +%F)）：bootstrap $bootstrap；SASL_SSL／SCRAM-SHA-512；平常用 -a" >> $f

for a in app-inventory-a app-inventory-b; do
  echo "$a $(cat ~/secrets/$a.pass)" >> $f
done

# 2. 走 REST 的系統：p12 與銀行根憑證；p12 的密碼放另一個檔（分開送）
install -d -m 0700 ~/handover/app-shipping
install -m 0600 ~/pki/certs/app-shipping.p12 ~/pki/certs/bank-root.pem ~/handover/app-shipping/
install -m 0600 /dev/null ~/handover/app-shipping/README-password.txt
echo "p12 密碼另送：$(cat ~/secrets/app-shipping-p12.pass)" > ~/handover/app-shipping/README-password.txt

# 3. 檔案清單：權限、擁有者、大小、名稱
find ~/handover -type f -printf '%m %u %s %P\n' | sort -k4
```

```out
600 root 238 app-inventory-2026-10-29.txt
600 root 44 app-shipping/README-password.txt
600 root 4444 app-shipping/app-shipping.p12
600 root 1976 app-shipping/bank-root.pem
```

## 27.5 驗證：用該身分寫一筆、讀一筆

@role 維運人員 | ops02 | root

直連：拿 `-a` 的密碼做一份暫存的 client 設定（和 11 章的 `app-orders.properties` 同格式），寫一筆到 `inventory.stock`、用 `inventory-` 前綴的 group 讀回；走 REST：用 `app-shipping` 的憑證經 LB POST 一筆到 `shipping.events`。注意 REST v3 的 produce **一律回 HTTP 200**，成功或被拒要看回應 JSON 的 `error_code`（200 成功、40301 沒權限）。兩個都做完，稽核日誌（第 18 章）會看到這兩個身分：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. 暫存的 client 設定（mktemp 是 0600，用完即刪）：app-inventory-a 的帳密，格式同第 11 章的 app-orders.properties
conf=$(mktemp)
cat > $conf <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-inventory-a" password="$(cat ~/secrets/app-inventory-a.pass)";
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
ssl.truststore.password=$(cat ~/pki/store.pass)
EOF

# 2. 直連：寫一筆到 inventory.stock，用 inventory- 前綴的 group 讀回（讀回：讀到這一筆的行數）
msg="onboard-$(date +%s)"
echo "$msg" | kafka-console-producer \
  --bootstrap-server kb01.poc.lab:9095 \
  --producer.config $conf \
  --topic inventory.stock > /dev/null 2>&1
echo "app-inventory-a 寫入 inventory.stock：ok；讀回：$(kafka-console-consumer \
  --bootstrap-server kb01.poc.lab:9095 \
  --consumer.config $conf \
  --topic inventory.stock \
  --group inventory-check \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 30000 2> /dev/null | grep -c "^$msg$")"
rm -f $conf

# 3. 走 REST：經 LB POST 一筆；v3 produce 一律回 HTTP 200，成功或被拒看回應 JSON 的 error_code
#    error_code 例：200（成功）、40301（沒權限）
cluster_id=$(curl -s --cacert $CA https://kb01.poc.lab:8090/v1/metadata/id | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
SHIPPING_CERT="--cert $HOME/pki/certs/app-shipping.crt --key $HOME/pki/keys/app-shipping.key"
TOPICS_URL=https://rest.poc.lab:8082/v3/clusters/$cluster_id/topics

# 寫自己的 topic
own_topic=$(curl -s --cacert $CA $SHIPPING_CERT -X POST -H 'Content-Type: application/json' \
  -d "{\"value\":{\"type\":\"JSON\",\"data\":\"$msg-rest\"}}" \
  "$TOPICS_URL/shipping.events/records" \
  | grep -o '"error_code":[0-9]*' \
  | cut -d: -f2)

# 寫別人的 topic（應被拒）
other_topic=$(curl -s --cacert $CA $SHIPPING_CERT -X POST -H 'Content-Type: application/json' \
  -d "{\"value\":{\"type\":\"JSON\",\"data\":\"x\"}}" \
  "$TOPICS_URL/inventory.stock/records" \
  | grep -o '"error_code":[0-9]*' \
  | cut -d: -f2)

echo "app-shipping 經 REST 寫入 shipping.events：error_code $own_topic；寫別人的 topic：error_code $other_topic（應被拒：40301）"
```

```out
app-inventory-a 寫入 inventory.stock：ok；讀回：1
app-shipping 經 REST 寫入 shipping.events：error_code 200；寫別人的 topic：error_code 40301（應被拒：40301）
```

## 27.6 下線

@role 維運人員 | ops02 | root

系統退役時反過來做（選單 37 做前兩步）：解除 binding → SCRAM 密碼覆寫成隨機值（帳號留著，稽核日誌裡的名字才查得到；配額一起拿掉）→ 憑證：從 `requests.txt` 拿掉、私鑰與憑證刪掉、到期不續（REST 的授權靠 binding，拿掉就進不來；REST 白名單裡的 CN 留著無害，下次照 12.1 重啟 REST 時一併拿掉）→ topic 等保留期過了再刪（lab 直接刪）。最後確認：舊密碼登不進、binding 0 條、topic 不在。分三塊做，前兩塊沒有輸出：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"
source ~/conf/kraft.env

# 最後要證明舊密碼登不進：先記住
old=$(cat ~/secrets/app-inventory-a.pass)

# 1. 三個帳號：解除每一條 binding、拿掉配額
for p in app-inventory-a app-inventory-b app-shipping; do
  # 這個帳號的 binding，一行一條「角色|資源類型|名稱|比對方式」，例：DeveloperRead|Topic|inventory.|PREFIXED
  list=$(mktemp)
  confluent iam rbac role-binding list --principal User:$p --kafka-cluster $CLUSTER_ID -o json | python3 -c '
import json, sys
for b in json.load(sys.stdin):
    print("|".join([b["role"], b.get("resource_type", ""), b.get("name", ""), b.get("pattern_type", "")]))' > $list

  while IFS='|' read -r role rtype rname pattern; do
    # 這條 binding 的參數；PREFIXED 的多加 --prefix
    binding="--principal User:$p --role $role --resource $rtype:$rname --kafka-cluster $CLUSTER_ID"

    if [ "$pattern" = PREFIXED ]; then
      binding="$binding --prefix"
    fi

    # 刪；只有 50003（auth topic 的 leader 剛搬家，見 28.4）才再送一次，其他錯誤印出來並停下
    if ! result=$(confluent iam rbac role-binding delete $binding --force 2>&1); then
      if echo "$result" | grep -q "not the current leader"; then
        confluent iam rbac role-binding delete $binding --force > /dev/null 2>&1
      else
        echo "$result"
        false
      fi
    fi
  done < $list

  rm -f $list
  kafka-configs $A --alter --entity-type users --entity-name $p \
    --delete-config producer_byte_rate,consumer_byte_rate,request_percentage > /dev/null 2>&1
done
```

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"

# 2. 兩個 SCRAM 帳號：密碼覆寫成隨機值（帳號留著，稽核日誌裡的名字才查得到）、刪掉密碼檔
for a in app-inventory-a app-inventory-b; do
  random_pass=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)
  kafka-configs $A --alter --entity-type users --entity-name $a \
    --add-config "SCRAM-SHA-512=[iterations=8192,password=$random_pass]" > /dev/null 2>&1
  rm -f ~/secrets/$a.pass
done

unset random_pass

# 3. 憑證：從 requests.txt 拿掉、私鑰與憑證刪掉（到期不續）；交接檔一起刪
cd ~/pki
sed -i '/^app-shipping /d' requests.txt
rm -f keys/app-shipping.key requests/app-shipping.csr incoming/app-shipping.*
rm -f certs/app-shipping.crt certs/app-shipping.p12 ~/secrets/app-shipping-p12.pass
rm -rf ~/handover/app-inventory-*.txt ~/handover/app-shipping

# 4. topic（正式環境等保留期過了再刪）
for t in inventory.stock shipping.events; do
  kafka-topics $A --delete --topic $t > /dev/null 2>&1
done
```

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
A="--bootstrap-server kb01.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"
source ~/conf/kraft.env

# 5. 舊密碼還登不登得進（$old 是第一塊記住的舊密碼；暫存的 client 設定用完即刪）
conf=$(mktemp)
cat > $conf <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-inventory-a" password="$old";
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
ssl.truststore.password=$(cat ~/pki/store.pass)
EOF

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $conf --list > /dev/null 2>&1; then
  login=成功
else
  login=被拒
fi

rm -f $conf
unset old

# 6. 三個帳號剩幾條 binding
binding_total=0

for p in app-inventory-a app-inventory-b app-shipping; do
  n=$(confluent iam rbac role-binding list --principal User:$p --kafka-cluster $CLUSTER_ID -o json \
    | awk '/"role"/ {c++} END {print c + 0}')
  binding_total=$((binding_total + n))
done

# 7. topic 與 ~/pki 的殘留
topics_left=$(kafka-topics $A --list 2> /dev/null | awk '/^(inventory|shipping)\./ {c++} END {print c + 0}')
pki_left=$(ls ~/pki/keys ~/pki/certs | awk '/app-shipping/ {c++} END {print c + 0}')

echo "舊密碼登入：$login；binding：$binding_total 條；topic：$topics_left；pki 殘留：$pki_left"
```

```out
舊密碼登入：被拒；binding：0 條；topic：0；pki 殘留：0
```

> 每條刪除失敗時，只有 `50003 … not the current leader` 會再送一次（auth topic 的 leader 剛搬家，見 28.4）；其他錯誤不重試，讓你看得到。
>
> 正式環境不要急著刪 topic：先只拿掉 binding（沒人寫得進、讀得到），等申請單寫的保留期過了、確認沒有下游還在讀（選單 13 看 consumer lag），再用選單 33 刪。帳號不刪：稽核日誌裡的 principal 才對得上人。


# 28. 第二十八站：故障排查速查

下面這張圖是出事時的走法：先快照、再看那一台的三件事、然後依症狀分支，處理完回到快照，解不掉就收集 diagnostics。

![triage]

**這一章在做什麼**：安裝期的「出問題先看哪裡」在 14.1；這一章是**上線後**的版本：告警響了或有人回報，依症狀查表（28.1），先跑一分鐘快照（28.2），用 lab 演一次最常見的「一台 broker 掉了」（28.3），再列常見錯誤訊息的意思（28.4）、要找原廠時帶什麼（28.5），以及 MDS 不能用時的備用路徑（28.6）。前提：第 17 章的監控接著、第 16 章的選單裝好。完成的樣子：快照在健康叢集全綠；演練裡 kb04 停掉 → 快照看到 3／4 台、under-replicated、MDS 連不上，銀行 Prometheus 三條告警 firing（`ConfluentTargetDown`、`KafkaUnderReplicatedPartitions`、`KafkaFencedBrokers`）→ 重啟 → 歸零、告警解除。

## 28.1 速查表：症狀 → 看什麼 → 做什麼

@role 維運人員 | ops02 | root

每一列都是「先看哪個告警或指令，再做哪一章／哪個選單」。選單編號是第 16 章的 OP menu。

| 症狀（告警名稱，第 17 章；沒有行內 Prometheus 時第 32 章送的是同一份） | 先看 | 處理 | 詳細 |
|---|---|---|---|
| 一台 broker 掉了（`ConfluentTargetDown` + `KafkaUnderReplicatedPartitions` + `KafkaFencedBrokers`） | 28.2 快照：broker 在線 3／4、under-replicated > 0；那台 `systemctl is-active`、日誌最後 20 行 | 選單 21 重啟那一台（或 `ssh <host> sudo systemctl restart confluent-server`）；主機或資料碟壞了 → 25.2 remove、換、add | 28.3 演練 |
| 沒有 leader、寫入失敗（`KafkaActiveControllerCountNotOne`、`KafkaOfflinePartitions`、`KafkaUnderMinIsrPartitions`） | `kafka-metadata-quorum describe --status` 的 LeaderId；offline partition 清單 | controller 少於兩台活著就先救 controller（重啟；起不來 → 25.1 換）；offline 是 broker 問題（上一列） | 25.1 |
| ISR 一直縮、延遲高（`KafkaIsrShrinkingWithoutExpand`、`KafkaProduceLatencyHigh`、`KafkaRequestHandlerBusy`） | 哪台 broker 慢：`kafka-topics --under-replicated-partitions` 看缺的是哪個 broker id；那台的磁碟延遲、GC（`JvmHeapHigh`）、網路 | 磁碟或網路由銀行主機團隊；heap 不夠改 drop-in 的 `-Xmx` 滾動重啟（選單 27） | 第 24 章（磁碟） |
| 人員登不進 MDS／選單（HTTP 401；AD 636 不通） | `openssl s_client -connect ad01.poc.lab:636`；broker 日誌 `LdapException`；`svc-mds-bind` 密碼是否被 AD 換了 | AD 不通：應用程式（SCRAM／憑證）不受影響，等 AD；非得動平台用 `kafka-admin` 緊急帳號（11.2）；密碼換了：更新密文、派送、滾動重啟（20.4） | 11.2、20.4 |
| 憑證過期或快過期（client 看到 `certificate has expired`、`SSLHandshakeException`） | 選單 17（各端點實際出示的憑證到期日）；`openssl s_client … \| openssl x509 -enddate` | 21 章換發（leaf／CA／鏈三種）；truststore 裡的 CA 也會過期 | 21、22 |
| REST Proxy 經 LB 失敗（`RestProxyErrors`；client 回 502／503） | 單台 `curl https://rest0N:8082/v3/clusters` 分出 LB 還是 REST；LB 的 pool member 狀態；client 憑證對不對（REST 只收憑證） | 單台壞：選單 22 重啟那台；LB：請 LB 團隊（12.1） | 12.1 |
| C3 畫面空白或是舊資料（`ControlCenterStreamsNotRunning`、`ControlCenterStreamThreadsFailed`、`ControlCenterStreamsStalled`；`ControlCenterRocksDBBackgroundErrors` 先看 c3-01 的磁碟） | `journalctl -u confluent-control-center`；是不是 broker 剛全部重啟過（C3 比 MDS 先起來會卡住，14.3） | 選單 22 重啟 C3；它的內建 Prometheus 滿了會讓畫面慢（13 章 `METRICS_RETENTION_DAYS`） | 13、14.3 |
| 磁碟滿或快滿（`KafkaDataDiskFillingUp`、`KafkaLogDirOffline`） | 24.1：哪台、哪個 topic | 24.3：縮 retention、搬 partition、擴容 | 24 |
| MDS 起不來（broker `active` 但 8090／9094 不開；10 分鐘後 `Authorizer did not start up within the timeout` 自殺、systemd 再拉起） | journal 停在 `Waiting for all of the authorizer futures`；**真正的原因在 `/var/log/kafka/metadata-service.log`**（MDS 的 log4j2 appender 另外寫檔）：`LDAP search failed … error code 49 … data 52e` = `svc-mds-bind` 密碼和 AD 不一致（20.4 換密碼時密文 key 名對不上也會這樣） | 對齊密碼（20.4 的更新方式）、派送、重啟；全部 broker 都卡住就四台一起停、一起起 | 14.1、20.4 |
| 應用程式被拒（`TopicAuthorizationException`、`SaslAuthenticationException`） | 選單 41 看該帳號的權限；選單 43 查稽核日誌誰被拒 | 權限：選單 42；密碼錯：20.6 換閒置帳號再切 | 18、20.6 |
| 服務起不來、起來又死（`Scheduled restart job`） | 三件事：`is-active`、`systemctl show -p ExecStart` 指向我們的設定、日誌最後 20 行 ERROR | 設定被改壞：從 29.2 的備份或操作機 `~/conf` 重派（10–13 章的派送可重跑） | 14.2 |

## 28.2 一分鐘快照：出事先跑這一段

@role 維運人員 | ops02 | root

六個數字一次看完：quorum 有沒有 leader、幾台 broker 在線、under-replicated 與 offline 幾個、每台 broker 的 MDS 回不回 200、REST 經 LB 與 C3 回不回 200（選單 11 做的是同一件事；這裡是它背後的指令）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
BROKERS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094
A="--bootstrap-server $BROKERS --command-config $HOME/conf/client-admin.properties"
CONTROLLERS=kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093
Q="--bootstrap-controller $CONTROLLERS --command-config $HOME/conf/client-internal.properties"

# 1. quorum 的 leader（空白 = controller 沒有 leader，最嚴重）
echo "quorum：$(kafka-metadata-quorum $Q describe --status 2> /dev/null | grep -E '^LeaderId' | tr -s ' ')"

# 2. 哪幾台 broker 在線
online=$(kafka-broker-api-versions $A 2> /dev/null | grep -oE '^[a-z0-9.]+:9094' | sort)
echo "broker 在線：$(echo "$online" | paste -sd' ')"

# 3. under-replicated 與 offline 的 partition 數
under=$(kafka-topics $A --describe --under-replicated-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')
offline=$(kafka-topics $A --describe --unavailable-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')
echo "under-replicated：$under；offline：$offline"

# 4. 每台 broker 的 MDS（8090）的 HTTP 狀態碼；連不上是 000
# （用 printf 印，不存進變數：連不上時 curl 的結束碼不是 0，存進變數會讓那一行算失敗）
printf "MDS："

for h in kb01 kb02 kb03 kb04; do
  printf "%s=%s " $h "$(curl -sk -m 5 -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done

echo

# 5. REST 經 LB（用 app-legacy-billing 的憑證）與 C3
REST_CERT="--cert $HOME/pki/certs/app-legacy-billing.crt --key $HOME/pki/keys/app-legacy-billing.key"
printf 'REST 經 LB：%s；C3：%s\n' \
  "$(curl -s -m 30 -o /dev/null -w '%{http_code}' $REST_CERT https://rest.poc.lab:8082/v3/clusters)" \
  "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"
```

```out
quorum：LeaderId: 2
broker 在線：kb01.poc.lab:9094 kb02.poc.lab:9094 kb03.poc.lab:9094 kb04.poc.lab:9094
under-replicated：0；offline：0
MDS：kb01=200 kb02=200 kb03=200 kb04=200
REST 經 LB：200；C3：200
```

bootstrap 給三台 broker 是故意的：出事時 kb01 可能就是掛掉的那台。`LeaderId` 空白代表 controller 沒有 leader，那是最嚴重的情況，先救 controller。

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

同時看 Alertmanager／Prometheus 現在有哪些告警（正式環境看 Alertmanager 畫面或 omnibus；lab 查 Prometheus 的 API，`firing` 是已過 `for` 時間、`pending` 是條件成立但還在等）：

```bash
# 在 labnet 上起一個臨時容器，執行 EOF 之前的那一段：firing 的告警（附主機或 env）與 pending 的告警名稱
podman run --rm -i --network lab_labnet lab-node:96 bash -s <<'EOF'
curl -s http://lab-mon-prometheus:9090/api/v1/alerts | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]["alerts"]
firing = sorted(set(
    x["labels"]["alertname"] + "(" + x["labels"].get("hostname", x["labels"].get("env", "")) + ")"
    for x in a if x["state"] == "firing"))
pending = sorted(set(x["labels"]["alertname"] for x in a if x["state"] == "pending"))
print("firing：" + (", ".join(firing) or "無") + "；pending：" + (", ".join(pending) or "無"))'
EOF
```

```out
firing：無；pending：JvmHeapHigh
（pending 那一欄每次不同：lab 的 controller heap 小，常看到 JvmHeapHigh；也可能是無）
```

（lab 的 `JvmHeapHigh` 常常 pending：lab 給 controller 的 heap 小，kc02 的 heap 在 80–90% 徘徊、偶爾過 90% 但撐不到 `for` 的 10 分鐘；正式環境 heap 在第 10 章的 drop-in 依主機規格（請銀行確認的事項 4.1）給足就不會。pending 不會送到 Alertmanager。）

## 28.3 演練：一台 broker 掉了

@role 銀行 OS 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

lab 把 kb04 的服務直接停掉，當作主機或服務掛了（正式環境是主機團隊或告警通知你）：

```bash
# 1. 停掉 kb04 的服務
podman exec lab-kb04-1 systemctl stop confluent-server

# 2. 15 秒後看它的狀態
sleep 15
echo "kb04 confluent-server：$(podman exec lab-kb04-1 systemctl is-active confluent-server) $(date +%T)"
```

```out
kb04 confluent-server：failed 03:35:36
```

> `systemctl stop` 後狀態是 `failed` 不是 `inactive`：Kafka 收到 SIGTERM 以 143 結束，RPM 的 unit 沒把 143 列為正常結束碼。看到 `failed` 先看日誌最後幾行是 `shut down completed` 還是 ERROR，前者只是被停掉。

@role 維運人員 | ops02 | root

快照：broker 在線剩三台、under-replicated 不是 0（kb04 上的 replica 都不同步）、kb04 的 MDS 連不上（000）；REST 與 C3 照常，應用程式只要 `acks=all` 與 `min.insync.replicas=2` 都還寫得進。再看那一台的三件事（`is-active`、日誌最後幾行）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
BROKERS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094
A="--bootstrap-server $BROKERS --command-config $HOME/conf/client-admin.properties"

# 1. 快照（28.2 的前幾項）；多印一個 under-replicated 的 partition，看缺的是哪個 broker id
online=$(kafka-broker-api-versions $A 2> /dev/null | grep -oE '^[a-z0-9.]+:9094' | sort)
echo "broker 在線：$(echo "$online" | paste -sd' ')"

under=$(kafka-topics $A --describe --under-replicated-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')
offline=$(kafka-topics $A --describe --unavailable-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')
missing=$(kafka-topics $A --describe --under-replicated-partitions 2> /dev/null \
  | grep -oE 'Replicas: [0-9,]+\s+Isr: [0-9,]+' \
  | head -1)
echo "under-replicated：$under；offline：$offline；缺的 broker：$missing"

# （用 printf 印，不存進變數：連不上時 curl 的結束碼不是 0，存進變數會讓那一行算失敗；連不上是 000）
printf "MDS："

for h in kb01 kb02 kb03 kb04; do
  printf "%s=%s " $h "$(curl -sk -m 5 -o /dev/null -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done

echo

REST_CERT="--cert $HOME/pki/certs/app-legacy-billing.crt --key $HOME/pki/keys/app-legacy-billing.key"
printf 'REST 經 LB：%s；C3：%s\n' \
  "$(curl -s -m 30 -o /dev/null -w '%{http_code}' $REST_CERT https://rest.poc.lab:8082/v3/clusters)" \
  "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"

# 2. 那一台：服務狀態、日誌最後一行（前 120 字）
#    is-active 在服務沒起來時結束碼不是 0，所以同樣放在 printf 的參數裡
last_log=$(ssh kb04.poc.lab 'sudo journalctl -u confluent-server -n 200 --no-pager' | tail -1 | cut -c1-120)
printf 'kb04：%s；日誌最後一行：%s\n' "$(ssh kb04.poc.lab systemctl is-active confluent-server)" "$last_log"
```

```out
broker 在線：kb01.poc.lab:9094 kb02.poc.lab:9094 kb03.poc.lab:9094
under-replicated：149；offline：0；缺的 broker：Replicas: 101,102,104	Isr: 101,102
MDS：kb01=200 kb02=200 kb03=200 kb04=000
REST 經 LB：200；C3：200
kb04：failed；日誌最後一行：Oct 29 03:35:36 kb04 systemd[1]: confluent-server.service: Consumed 7min 22.983s CPU time.
```

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

告警：`ConfluentTargetDown` 2 分鐘後 firing、`KafkaUnderReplicatedPartitions` 與 `KafkaFencedBrokers` 5 分鐘後 firing（`for` 是故意放寬的，滾動重啟時才不會叫人；兩條 5 分鐘的差不多同時響）。lab 每 10 秒看一次、最多等 7 分鐘：

```bash
# 等 KafkaUnderReplicatedPartitions 變 firing：每 10 秒看一次，最多 42 次（7 分鐘）
for i in $(seq 1 42); do
  # 在 labnet 上起一個臨時容器（執行 EOF 之前的那一段），印 firing（附主機或 env）與 pending 的告警（同 28.2）
  status=$(podman run --rm -i --network lab_labnet lab-node:96 bash -s <<'EOF'
curl -s http://lab-mon-prometheus:9090/api/v1/alerts | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]["alerts"]
firing = sorted(set(
    x["labels"]["alertname"] + "(" + x["labels"].get("hostname", x["labels"].get("env", "")) + ")"
    for x in a if x["state"] == "firing"))
pending = sorted(set(x["labels"]["alertname"] for x in a if x["state"] == "pending"))
print("firing：" + (", ".join(firing) or "無") + "；pending：" + (", ".join(pending) or "無"))'
EOF
  )

  if echo "$status" | grep -qE 'firing：[^；]*KafkaUnderReplicatedPartitions'; then
    break
  fi

  sleep 10
done

echo "等了約 $((i * 10)) 秒：$status"
```

```out
等了約 280 秒：firing：ConfluentTargetDown(kb04.poc.lab), KafkaFencedBrokers(lab), KafkaUnderReplicatedPartitions(lab)；pending：CertificateProbeFailed
（pending 那一欄每次不同：CertificateProbeFailed、JvmHeapHigh 都可能出現，也可能是無）
```

`CertificateProbeFailed` 是第 22 章 blackbox 探 kb04 的 TLS 失敗，它的 `for` 是 10 分鐘，所以這時還是 pending；broker 停超過 10 分鐘它也會 firing，說的是同一件事（看 `ConfluentTargetDown` 就知道是服務停了，不是憑證壞了）。

@role 維運人員 | ops02 | root

處理：重啟那一台（選單 21 做的就是這個；`cpuser-ops` 的 sudo 只允許這個寫法），等 under-replicated 歸零、kb04 的 MDS 回 200：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
BROKERS=kb01.poc.lab:9094,kb02.poc.lab:9094,kb03.poc.lab:9094
A="--bootstrap-server $BROKERS --command-config $HOME/conf/client-admin.properties"

# 1. 重啟那一台
ssh kb04.poc.lab 'sudo systemctl restart confluent-server'
echo "kb04：$(ssh kb04.poc.lab systemctl is-active confluent-server)"

# 2. 等 under-replicated 歸零、kb04 的 MDS 回 200：每 10 秒看一次，最多 30 次
for i in $(seq 1 30); do
  under=$(kafka-topics $A --describe --under-replicated-partitions 2> /dev/null \
    | awk '/Partition:/ {c++} END {print c + 0}')

  if [ "$under" = 0 ]; then
    if [ "$(curl -sk -m 5 -o /dev/null -w '%{http_code}' https://kb04.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi
  fi

  sleep 10
done

under=$(kafka-topics $A --describe --under-replicated-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')
online=$(kafka-broker-api-versions $A 2> /dev/null | grep -oE '^[a-z0-9.]+:9094' | wc -l)
printf '等了約 %s 秒：under-replicated %s、kb04 MDS %s；broker 在線：%s / 4\n' \
  "$((i * 10))" \
  "$under" \
  "$(curl -sk -m 5 -o /dev/null -w '%{http_code}' https://kb04.poc.lab:8090/v1/metadata/id)" \
  "$online"
```

```out
kb04：active
等了約 20 秒：under-replicated 0、kb04 MDS 200；broker 在線：4 / 4
```

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

告警自己解除（條件不成立就從 firing 消失，Alertmanager 送 resolved）：

```bash
# 等 firing 變成無：每 10 秒看一次，最多 18 次
for i in $(seq 1 18); do
  # 在 labnet 上起一個臨時容器（執行 EOF 之前的那一段），印現在 firing 的告警名稱
  status=$(podman run --rm -i --network lab_labnet lab-node:96 bash -s <<'EOF'
curl -s http://lab-mon-prometheus:9090/api/v1/alerts | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]["alerts"]
print("firing：" + (", ".join(sorted(set(x["labels"]["alertname"] for x in a if x["state"] == "firing"))) or "無"))'
EOF
  )

  if echo "$status" | grep -q '^firing：無'; then
    break
  fi

  sleep 10
done

echo "等了約 $((i * 10)) 秒：$status"
```

```out
等了約 140 秒：firing：無
```

> 起不來怎麼辦：日誌說資料目錄壞了（`KafkaStorageException`、`LogDirectoryOffline`）就是換碟，走 25.2（先 remove 讓 Self-Balancing 搬走，換完 add 回來）；說 `meta.properties` 不符是有人重新格式化過，同樣走 25.2 以空的 broker 加回。一次只動一台：第二台 broker 也掉的話 RF 3 的 partition 會 under-min-ISR，寫入開始失敗。

## 28.4 常見錯誤訊息對照

@role 維運人員 | ops02 | root

| 看到的訊息 | 在哪裡 | 意思 | 處理 |
|---|---|---|---|
| `Waiting for all of the authorizer futures to be completed` 之後沒下文（10 分鐘後 `Authorizer did not start up within the timeout`） | broker journal | authorizer 等 MDS 的 writer 初始化；原因要看 `/var/log/kafka/metadata-service.log`：`LDAP search failed … data 52e` 是 `svc-mds-bind` 密碼不對（AD 換了、或 20.4 更新的密文 key 名不對）；AD 不通是 `CommunicationException` | 14.1 陷阱；20.4；11.2 |
| `50003 … not the current leader`（建／刪 role binding 時） | confluent CLI、選單 34／42 | MDS 寫 `_confluent-metadata-auth` 的內部 producer 不重試（`retries=0`），leader 資訊最多 5 分鐘才更新；broker 重啟後 auth topic 的 leader 會被自動搬回偏好的 broker，搬家後第一筆寫入就送錯地方。MDS 是好的 | 同一個指令再跑一次（這次失敗已讓它更新 leader）；**只有這個錯誤**可以這樣做，腳本也只對它重試一次 |
| `Failed to fetch MDS URLs … Client has already been closed` | C3 日誌 | C3 比 MDS 先起來 | 重啟 C3（14.3） |
| `TopicAuthorizationException: Not authorized to access topics` | 應用程式／稽核日誌 | 帳號沒有那個 topic 的 role binding 或 ACL | 選單 41 看、42 給 |
| `SaslAuthenticationException: Authentication failed` | 應用程式 | SCRAM 帳號或密碼錯（換密碼時換到正在用的那個） | 20.6：換閒置帳號、應用程式再切 |
| `SSLHandshakeException` / `certificate has expired` / `unable to find valid certification path` | 應用程式、REST、C3 | 憑證過期、對方的 CA 不在自己的 truststore | 21 章；選單 17 看到期日 |
| `NotEnoughReplicasException` | 應用程式（`acks=all`） | ISR 少於 `min.insync.replicas`（兩台 broker 掉了） | 先救 broker（28.3） |
| `KafkaStorageException` / `LogDirectoryOffline` | broker 日誌 | 資料碟壞或滿 | 24 章、25.2 換碟 |
| `Scheduled restart job, restart counter is at N` | journalctl | 服務起來就死，systemd 一直重試 | 三件事：ExecStart、設定、日誌第一個 ERROR（14.2） |
| `HTTP 401` 登 MDS | 選單、confluent CLI | AD 帳密錯、AD 不通、token 過期（1 小時） | 重新登入；AD 不通看 11.2 |
| `Pool overlaps`、`timeout 5 ip addr` 卡住 | lab 專用 | Podman 網段或 WSL VM 網路層問題 | 14.3 |

## 28.5 自己解不掉：收集 diagnostics

@role 維運人員 | ops02 | root

要找二線或原廠時帶這些（選單 18 一次打包：各台最近 200 行日誌、`kafka-topics --describe`、consumer groups、磁碟用量）。原廠通常還會要：broker 的設定檔（去掉密碼：Secret Protection 的密文本來就不是明文）、`kafka-metadata-quorum describe --replication`、告警時間軸（Alertmanager）、變更單（最近動過什麼）。密碼、私鑰、master key 永遠不交出去。


## 28.6 MDS 的 8090 不能用時

![mdsdown]

**這一節在做什麼**：操作機連不到任何一台 MDS（8090）時，人員的 AD 登入做不了，選單進不去，91 緊急憑證也換不到 token。常見原因是防火牆規則改壞了，或 MDS 全掛了（看 28.4 的 `Waiting for all of the authorizer futures`）。這時還有兩扇門：主機類的工作（看日誌、重啟服務）走選單的**緊急主機模式**，Kafka 類的工作（topic、設定、SCRAM 帳號）走 **`kafka-admin`**（SCRAM，9095）。兩者都不經 MDS、不經 AD，授權由 broker 本機的 binding 判斷（11.2 驗證過）。做不到的是改 role binding；MDS 全掛時人員也登不進 C3，經 REST Proxy 的應用程式也會受影響（REST Proxy 要經 MDS 取得權限，見第 12 章）。

lab 用「網路團隊在 broker 上擋掉操作機連 8090」模擬（只加 runtime 規則，`firewall-cmd --reload` 或重開機就消失）；broker 之間、REST Proxy、C3 連 MDS 都不受影響。

@role 銀行網路團隊（lab 由 Windows 終端代打） | Windows 終端 | 本機

```bash
# 每台 broker 加一條 runtime 規則：擋操作機（172.35.0.10）連 8090
rule='rule family="ipv4" source address="172.35.0.10" port port="8090" protocol="tcp" reject'

for h in kb01 kb02 kb03 kb04; do
  echo "$h: $(podman exec lab-$h-1 firewall-cmd --add-rich-rule="$rule")"
done
```

```out
kb01: success
kb02: success
kb03: success
kb04: success
```

@role 維運人員 bob | ops02 | root

8090 不通、9095 還通；選單的 AD 登入失敗，畫面指向這一節，並直接進入緊急主機模式（11 不在開放的項目裡，所以這裡只看前四行）。`~/conf/opmenu-try.sh` 是 16.5 建的 lab 試跑小腳本，沒有它這一段會停下：

```bash
# 這一段要 16.5 建的試跑小腳本
if [ ! -x ~/conf/opmenu-try.sh ]; then
  echo "沒有 ~/conf/opmenu-try.sh（16.5 建的）"
  false
fi

CA=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. 每台 broker：8090（MDS）與 9095（SCRAM）
for h in kb01 kb02 kb03 kb04; do
  # 9095：TCP 連得上是「通」，否則「不通」
  if timeout 5 bash -c "< /dev/tcp/$h.poc.lab/9095" 2> /dev/null; then
    port_9095=通
  else
    port_9095=不通
  fi

  printf '%s 8090=%s 9095=%s\n' $h \
    "$(curl -s -m 5 -o /dev/null -w '%{http_code}' --cacert $CA https://$h.poc.lab:8090/v1/metadata/id)" \
    "$port_9095"
done

# 2. bob 用選單 11：AD 登入失敗，進入緊急主機模式（只看前四行，每行前 120 個字元）
bash ~/conf/opmenu-try.sh bob 11 | head -4 | cut -c1-120
```

```out
kb01 8090=000 9095=通
kb02 8090=000 9095=通
kb03 8090=000 9095=通
kb04 8090=000 9095=通
MDS 全部連不上:https://kb01.poc.lab:8090,https://kb02.poc.lab:8090,https://kb03.poc.lab:8090,https://kb04.poc.lab:8
無法連到 MDS（Kafka 的權限服務），AD 登入做不了。
Kafka 類的緊急操作（topic、設定、SCRAM 帳號）改用手把手 28.6 的 kafka-admin（SCRAM,9095,不經 MDS 
已進入緊急主機模式：只能做 16 18 21 22 23（看日誌、磁碟、收集診斷、重啟服務）；每一步
（每行只印前 120 個字元）
```

**主機類：緊急主機模式**。不看任何群組（2026-10-29 定案：操作者都是經 PSMP 登入的 root，作業系統群組擋不住，root 能自己加入），只開放 16、18、21、22、23，必填原因，身分記成「未經 AD 驗證」、每一步記 EMERGENCY_HOST；Kafka 類項目會被擋下。追溯靠這些紀錄加上 CyberArk 登入紀錄與 PSMP 錄影：

```bash
# 1. 23 看 kb04 的日誌：主機類，開放
if bash ~/conf/opmenu-try.sh bob 23 kb04.poc.lab:confluent-server 3 | grep -q "kb04 kafka-server-start"; then
  echo "23 看 kb04 日誌：OK"
fi

# 2. 31 建 topic：Kafka 類，被擋下
bash ~/conf/opmenu-try.sh bob 31 orders.em 1 | tail -1

# 3. 選單紀錄的最後三筆：身分、動作、結果
tail -3 /var/log/opmenu/opmenu.log | cut -d'|' -f3,5,7
```

```out
23 看 kb04 日誌：OK
項目 31 在緊急主機模式不開放(只能做 OPMENU_EMERGENCY_ITEMS 列的主機類項目)。Kafka 類操作改用手把手 28.6 的 kafka-admin。
 bob | login | MDS_DOWN
 bob(緊急,未經AD驗證) | login | EMERGENCY_HOST
 bob(緊急,未經AD驗證) | 31 建立 topic | DENIED
```

> 21（重啟 broker）在緊急主機模式下做不了 under-replicated／offline 檢查（那要 Kafka 的權限），會改成警告並要求確認。

**Kafka 類：`kafka-admin`**。

@role 小安 | ops02 | root

設定檔放暫存目錄、用完刪掉，密碼不印出來。這裡示範查狀態、建 topic、改 retention、刪 topic；SCRAM 帳號的建立與換密碼（20.6）也一樣走 9095：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 暫存的連線設定：借 app-orders 那一份，帳密換成 kafka-admin（暫存目錄最後刪掉；密碼不印）
tmp=$(mktemp -d)
conf=$tmp/admin.properties
scram_module=org.apache.kafka.common.security.scram.ScramLoginModule
password=$(cat ~/secrets/kafka-admin.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $conf
echo "sasl.jaas.config=$scram_module required username=\"kafka-admin\" password=\"$password\";" >> $conf
unset password
A="--bootstrap-server kb01.poc.lab:9095,kb02.poc.lab:9095 --command-config $conf"

# 2. 查狀態
topic_count=$(kafka-topics $A --list | wc -l)
under=$(kafka-topics $A --describe --under-replicated-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')
offline=$(kafka-topics $A --describe --unavailable-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')
echo "topic 數：$topic_count；under-replicated：$under；offline：$offline"

# 3. 建 topic、改 retention、刪 topic
kafka-topics $A --create --topic orders.mds-down --partitions 3 --replication-factor 3 > /dev/null 2>&1
echo "建立 orders.mds-down：OK"

kafka-configs $A --alter --entity-type topics --entity-name orders.mds-down \
  --add-config retention.ms=86400000 > /dev/null 2>&1
kafka-configs $A --describe --entity-type topics --entity-name orders.mds-down | grep -o 'retention.ms=[0-9]*' | head -1

kafka-topics $A --delete --topic orders.mds-down
echo "刪除 orders.mds-down：OK"

rm -rf $tmp
```

```out
topic 數：14；under-replicated：0；offline：0
建立 orders.mds-down：OK
retention.ms=86400000
刪除 orders.mds-down：OK
```

> 誰在什麼時候用了 `kafka-admin`，Kafka 稽核日誌（第 18 章）記成 `User:kafka-admin`；要和 CyberArk 登入紀錄、PSMP 錄影對起來才知道是哪個人。

**恢復**：網路團隊開回 8090；確認選單照常登入（AD 登入成功就不會再進緊急主機模式）；最後照 20.2 換 `kafka-admin` 的密碼（同一行指令）。

@role 銀行網路團隊（lab 由 Windows 終端代打） | Windows 終端 | 本機

```bash
# 每台 broker 拿掉那條 runtime 規則
rule='rule family="ipv4" source address="172.35.0.10" port port="8090" protocol="tcp" reject'

for h in kb01 kb02 kb03 kb04; do
  echo "$h: $(podman exec lab-$h-1 firewall-cmd --remove-rich-rule="$rule")"
done
```

```out
kb01: success
kb02: success
kb03: success
kb04: success
```

@role 小安 | ops02 | root

```bash
CA=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. 四台的 8090 回來了
for h in kb01 kb02 kb03 kb04; do
  printf '%s 8090=%s  ' $h \
    "$(curl -s -m 5 -o /dev/null -w '%{http_code}' --cacert $CA https://$h.poc.lab:8090/v1/metadata/id)"
done
echo

# 2. bob 用選單 11：AD 登入成功（不再進緊急主機模式），看 token 與 broker 在線兩行
bash ~/conf/opmenu-try.sh bob 11 | grep -E '^-- (你的 MDS token|broker 在線:)'
```

```out
kb01 8090=200  kb02 8090=200  kb03 8090=200  kb04 8090=200  
-- 你的 MDS token:已用 9s,剩約 3591s
-- broker 在線:4 / 4(設定的 broker 數)
```

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
tmp=$(mktemp -d)   # 暫存目錄：新舊密碼與連線設定都放這裡，最後刪掉
conf=$tmp/c.properties
scram_module=org.apache.kafka.common.security.scram.ScramLoginModule

# 1. 模擬一次緊急使用：用目前的密碼以 kafka-admin 從 9095 列 topic（連線設定借 app-orders 那一份，帳密那一行換掉）
password=$(cat ~/secrets/kafka-admin.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $conf
echo "sasl.jaas.config=$scram_module required username=\"kafka-admin\" password=\"$password\";" >> $conf
unset password

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $conf --list > /dev/null 2>&1; then
  echo "緊急使用（目前的密碼）：登入成功"
else
  echo "緊急使用（目前的密碼）：被拒"
fi
```

```out
緊急使用（目前的密碼）：登入成功
```

用完照 20.2 換掉密碼，確認新密碼登得進、舊密碼被拒（`$tmp`、`$conf`、`$scram_module` 沿用上一塊的）：

```bash
BS=kb01.poc.lab:9094

# 2. 留一份舊密碼，產生新密碼（0600）
cp -p ~/secrets/kafka-admin.pass $tmp/old.pass
install -m 0600 /dev/null $tmp/new.pass
openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > $tmp/new.pass

# 3. 叢集改成功，才換掉 ~/secrets/kafka-admin.pass（kafka-configs 出錯會把密碼印出來，所以輸出全丟）
if kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties \
  --alter --entity-type users --entity-name kafka-admin \
  --add-config "SCRAM-SHA-512=[iterations=8192,password=$(cat $tmp/new.pass)]" > /dev/null 2>&1; then
  install -m 0600 $tmp/new.pass ~/secrets/kafka-admin.pass
else
  echo "叢集改密碼失敗：~/secrets/kafka-admin.pass 沒有換"
  rm -rf $tmp
  false
fi

# 4. 確認：SCRAM 憑據還在
echo "kafka-admin: $(kafka-configs --bootstrap-server $BS --command-config ~/conf/client-admin.properties \
  --describe --entity-type users --entity-name kafka-admin 2> /dev/null | grep -o 'SCRAM-SHA-512=[^ ]*')"

# 5. 新密碼登得進嗎
password=$(cat ~/secrets/kafka-admin.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $conf
echo "sasl.jaas.config=$scram_module required username=\"kafka-admin\" password=\"$password\";" >> $conf

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $conf --list > /dev/null 2>&1; then
  new_result=登入成功
else
  new_result=被拒
fi

# 6. 舊密碼應該被拒
password=$(cat $tmp/old.pass)
grep -v '^sasl.jaas.config' ~/conf/app-orders.properties > $conf
echo "sasl.jaas.config=$scram_module required username=\"kafka-admin\" password=\"$password\";" >> $conf
unset password

if kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config $conf --list > /dev/null 2>&1; then
  old_result=登入成功
else
  old_result=被拒
fi

echo "換完：新密碼 $new_result；舊密碼 $old_result"

rm -rf $tmp
```

```out
kafka-admin: SCRAM-SHA-512=iterations=8192
換完：新密碼 登入成功；舊密碼 被拒
```

# 29. 第二十九站：遷移到新版 Confluent 與 JDK

![upgrade]

下面這張圖把遷移每一節的先後排出來，並標出不能回頭的那一步。

![migrationflow]

安裝基底（第 2–19 章）裝的是 **Confluent Platform 8.2.4**、**Control Center 2.5.1**、**JDK 21**。這一章是主線的下一步：遷移到 **Confluent Platform 8.3.2**，C3 同時升到 **2.6.1**，並把 **JDK 21 換成 25**。順序和原因：

- **C3 先升**：原廠相容表上 C3 2.5.x 只支援到 CP 8.2.x，2.6.x 才支援到 8.3.x（2.6.x 的範圍是 7.5.15 到 8.3.x，所以 2.6.1 配著 8.2.4 也在支援範圍內）。CP 一升到 8.3，2.5.1 就落在支援範圍外，所以 C3 要在 broker 之前換（29.3）。
- **JDK 25 在 CP 升完之後才換**：8.2.x 只支援 Java 17／21，8.3.x 才支援 25；注意原廠對 8.3 的**建議**版本仍是 21，25 是「支援」，選 25 要和原廠支援確認（銀行沒有這個要求時，留在 21 就好，只做第一、三段）。C3 也一起換成 JDK 25（2026-10-28 定案：全部 Java 節點同一個版本；C3 2.6 的需求是 Java 17 以上，lab 實測 2.6.1 在 25 上正常）。
- **OS 小版本（9.6 → 9.8）不在這一章**，是第 30 章的 30.5：Confluent 套件被 versionlock 鎖住、JDK 是 tar，OS 更新碰不到它們，所以兩條線可以分開做；本章每一段結束都跑第 19 章的驗收。

> 前提：安裝基底已經裝好並通過第 19 章驗收；目標版本的 RPM 與 JDK 25 已經在第 2、3 章隨落地區進來（`~/landing/rpm-target/`、`~/landing/bank/`），這一章 29.1 才把它們上架。第 21 章的憑證輪替做過沒做過都行，順序沒有相依。

分三段，每段結束都可以停下來驗收：

| 段 | 做什麼 | 出問題怎麼退 |
|---|---|---|
| 一 | 套件 8.2.4 → 8.3.2，JDK 維持 21。順序照原廠：C3（2.5.1 → 2.6.1）→ broker 逐台 → controller 逐台（leader 最後）→ 操作機的工具 → REST Proxy | `dnf downgrade` 回 8.2.4（29.8） |
| 二 | JDK 21 → 25：controller、broker、REST Proxy、C3、操作機逐台切換 `/opt/java/current` | 連結切回 21、重啟 |
| 三 | finalize：features 升到 4.3（`kafka-features upgrade --release-version 4.3`） | **不能退**：之後只有新舊版之間沒有 metadata 變更才能降版，8.3 降回去可能要從備份還原 |

要回 8.2 時順序反過來：先把 JDK 切回 21（8.2 不支援 25），再 `dnf downgrade`。所以**前兩段都驗收過才做第三段**。

**各節的順序**（照這個順序做，不要跳）：

1. 29.1 上架目標版本、升級前檢查 → 29.2 備份。
2. 第一段：29.3 C3 → 29.4 broker → 29.5 controller → 29.6 REST Proxy 與操作機工具。
3. 第二段：29.7 JDK 25（銀行不要求 25 就略過）。
4. 29.8 回滾演練：趁 finalize 之前，證明真的退得回去（kb04 退回再升回來）。
5. 29.9 第三段 finalize。**這是不能回頭的點**：做完之後叢集無法降回 8.2，要退只能靠 29.2 的備份與原廠的還原程序。
6. 29.10 確認版本、記下新基準。

每一段、每一台都要等健康（MDS 回 200、under-replicated 為 0、quorum Lag 為 0）才做下一台。

> 實測（lab，全程持續流量，2026-11-09 從零重跑，含 C3 先升的一步）：約 36 分鐘。直連應用程式送出 10,348 筆、讀回 10,348 筆，遺失 0；經負載平衡的 REST 1,918 次，失敗 0 次（2026-10-26 那次演練曾有 2 次 HTTP 402，發生在 controller 重啟的那幾秒，lab 用的是試用 license）。三段結束各跑一次第 19 章的驗收，都全數通過。

## 29.1 目標版本上架與升級前檢查

@role 小安 | ops02 | root

**這一節在做什麼**：把 8.3.2／2.6.1 的 RPM 上架到內部套件庫，並確認叢集現在是健康的，才開始升。**注意：`~/landing/rpm-target/` 與 `~/landing/bank/` 裡的 JDK 25 要保留到第 29 章全部做完（含 29.7）；19.5 的收尾不要先刪掉它們。**目標版本的 RPM 已經在落地區（`~/landing/rpm-target/`，第 3 章核對過 sha256 與簽章）。把它們加進內部套件庫：**基底版本不刪，回滾要用**，只推 `confluent/` 這個目錄：

```bash
# 1. 目標版本的 RPM 再核對一次 sha256（第 3 章核對過）
cd ~/landing
grep " rpm-target/" SHA256SUMS | sha256sum -c --quiet
cd ~

# 2. 加進內部套件庫的 confluent/（基底版本不刪，回滾要用），更新索引
cp ~/landing/rpm-target/*.rpm ~/repo/confluent/
createrepo_c -q --update ~/repo/confluent

# 3. 只推 confluent/ 這個目錄到 repo01
tar -C ~/repo -cf - confluent | ssh repodeploy@repo01.poc.lab 'tar -C /var/www/repo -xpf -'

# 4. 從 c3-01 看套件庫裡有哪些版本（執行 EOF 之前的那一段）
ssh c3-01.poc.lab bash -s <<'EOF'
# confluent-server：套件庫 confluent-internal 裡有哪些版本（--refresh：剛推上去）
list=$(sudo dnf -q --refresh --showduplicates list confluent-server 2> /dev/null)
raw=$(echo "$list" | awk '/confluent-internal/ {print $2}')

# 版本欄長這樣：1:8.3.2-1，去掉頭尾變成 8.3.2
versions=$(echo "$raw" | sed 's/^1://; s/-1$//' | sort -uV)
echo "套件庫裡的 confluent-server：$(echo "$versions" | paste -sd' ' -)"

# C3：同樣的做法
list=$(sudo dnf -q --refresh --showduplicates list confluent-control-center-next-gen 2> /dev/null)
raw=$(echo "$list" | awk '/confluent-internal/ {print $2}')
versions=$(echo "$raw" | sed 's/^1://; s/-1$//' | sort -uV)
echo "套件庫裡的 C3：$(echo "$versions" | paste -sd' ' -)"
EOF
```

```out
套件庫裡的 confluent-server：8.2.4 8.3.2
套件庫裡的 C3：2.5.1 2.6.1
```

確認現在的版本、quorum、套件庫裡有沒有新版、有沒有沒追上的複本，以及 8.3 已經拿掉的設定（`message.format.version` 這類留在設定檔裡，8.3 會起不來；基底的範本本來就沒有，這裡再確認一次）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 現在的 features（metadata 版本）
kafka-features \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  describe 2> /dev/null | grep confluent.metadata.version | tr -s ' \t' ' '

# 2. quorum 有 leader
kafka-metadata-quorum \
  --bootstrap-controller kc01.poc.lab:9093 \
  --command-config ~/conf/client-internal.properties \
  describe --status 2> /dev/null | grep LeaderId

# 3. 套件庫裡有新版（@ 開頭的是這台裝著的）
dnf -q --refresh list --showduplicates confluent-server 2> /dev/null | grep confluent-internal | tr -s ' '

# 4. 沒有沒追上的複本
echo "under-replicated: $(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --describe --under-replicated-partitions 2> /dev/null | awk '/Partition:/ {c++} END {print c + 0}')"

# 5. 8.3 拿掉的設定：每台 server.properties 裡有幾行（要全部是 0）
removed='message.format.version|message.downconversion.enable'
removed="$removed|message.timestamp.difference.max.ms|log.message.format.version"

for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04; do
  printf '%s:%s ' $h "$(ssh $h.poc.lab "sudo grep -cE '^($removed)' /etc/confluent/kafka/server.properties")"
done
echo
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

## 29.2 備份

@role 小安 | ops02 | root

**這一節在做什麼**：升級前留一份可以還原的備份。每台的 `/etc/confluent` 與 systemd drop-in、features 狀態、操作機的套件清單，打包回操作機（0700）。master key（`service.env`）不放進備份：master key 只放在操作機的 `~/secrets`（root 0600，備份由銀行的備份機制處理並加密）與各主機的 `service.env`，不放 CyberArk；這份備份不含它，就不必當成機敏資料保管。回滾、或 finalize 之後真的要退，都從這裡拿：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
B=~/upgrade-backup/$(date +%Y%m%d-%H%M)
install -d -m 0700 $B

# 1. 每台的 /etc/confluent 與 systemd drop-in，打包回操作機（service.env 不放進來；每台執行 EOF 之前的那一段）
#    drop-in 目錄用絕對路徑找、再去掉開頭的 /（tar 用 -C /，要相對路徑）
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -s > $B/$h.tar.gz <<'EOF'
dropins=$(ls -d /etc/systemd/system/confluent-*.service.d 2> /dev/null | cut -c2-)
sudo tar -czf - -C / --exclude=etc/confluent/service.env etc/confluent $dropins
EOF

  printf '%s %s  ' $h "$(du -h $B/$h.tar.gz | cut -f1)"
done
echo

# 2. features 狀態、操作機的套件清單
kafka-features \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  describe > $B/features.txt 2> /dev/null
rpm -qa 'confluent-*' | sort > $B/ops02-packages.txt
echo "$B"
```

```out
kc01 28K  kc02 28K  kc03 28K  kb01 32K  kb02 32K  kb03 32K  kb04 32K  rest01 28K  rest02 28K  c3-01 36K
/root/upgrade-backup/20261101-2356
```

## 29.3 第一段：Control Center 先（2.5.1 → 2.6.1）

@role 小安 | ops02 | root

**這一節在做什麼**：先升 Control Center。原廠要求 C3 比 broker、controller 先升，而且 2.5.1 不支援 8.3，所以這一步一定要先做。C3 只有一台，升級期間畫面約 1–2 分鐘不能用；broker、REST、應用程式不受影響（C3 只是看）。設定檔不用改（第 13 章的設定 2.5.1 與 2.6.1 通用）。

換版本的步驟寫成 `~/conf/c3-change.sh`，升級與回滾是同一段，只差 `dnf install` 或 `dnf downgrade`（第 31 章還會用到）：解鎖 → 換版本 → 鎖回新的版本 → `daemon-reload`（RPM 會換掉 unit 檔）→ 把 C3 自己要寫的 4 個 generated 檔改回 `cp-control-center`（RPM 換版本會把它們改回 root）→ 確認設定檔沒被動、`ExecStart` 還是指著我們的設定 → 重啟 Prometheus、Alertmanager、C3 → 等畫面 200：

```bash
cat > ~/conf/c3-change.sh <<'EOF'
#!/usr/bin/env bash
# c3-change.sh <版本> <install|downgrade> — 在 c3-01 換 C3 套件的版本、重啟、等畫面 200
# 做什麼：解鎖 → 換版本 → 鎖回新版本 → daemon-reload → C3 自己寫的 4 個 generated 檔改回 cp-control-center
#   → 印一行（版本、設定檔有沒有被動、ExecStart、versionlock）→ 重啟 Prometheus、Alertmanager、C3 → 等畫面 200
# 結束碼：0 畫面回 200；1 換套件失敗或畫面沒回來
# 改的時候要注意：29.3 升級、第 31 章退回都用它；印出來的兩行手冊的預期輸出有用到

version=$1
action=$2

# 1. 在 c3-01 上執行 REMOTE 之前的那一段（$1 = 版本、$2 = install 或 downgrade）
if ! ssh c3-01.poc.lab bash -s -- $version $action <<'REMOTE'
p=/etc/confluent/control-center/control-center.properties
before=$(sudo sha256sum $p | cut -c1-12)

# 解鎖、換版本、鎖回新版本
sudo dnf -q versionlock delete confluent-control-center-next-gen > /dev/null

if ! sudo dnf -q -y --refresh $2 confluent-control-center-next-gen-$1 > /dev/null; then
  echo "c3-01 換套件失敗（versionlock 已解開）"
  exit 1
fi

sudo dnf -q versionlock add confluent-control-center-next-gen-$1 > /dev/null

# RPM 換掉了 unit 檔：重新載入
sudo systemctl daemon-reload

# C3 自己要寫的 4 個 generated 檔：RPM 換版本會把它們改回 root，改回 cp-control-center
cd /etc/confluent-control-center

generated_files="alertmanager-generated.yml trigger_rules-generated.yml recording_rules-generated.yml"
generated_files="$generated_files prometheus-generated-local.yml"

for f in $generated_files; do
  sudo chown cp-control-center:confluent $f
  sudo chmod 0640 $f
done

# 一行結果：版本、設定檔有沒有被動、ExecStart 指向的設定檔、versionlock
if [ "$before" = "$(sudo sha256sum $p | cut -c1-12)" ]; then
  config=same
else
  config=CHANGED
fi

c3_version=$(rpm -q confluent-control-center-next-gen)
exec_start=$(systemctl show confluent-control-center -p ExecStart --value)
exec_path=$(echo "$exec_start" | grep -o '/etc/[^ ]*properties' | head -1)
lock_lines=$(sudo dnf -q versionlock list)

echo "$c3_version config=$config exec=$exec_path lock=$(echo "$lock_lines" | grep control-center)"

# 重啟 C3 內建的 Prometheus、Alertmanager 與 C3
for u in prometheus alertmanager confluent-control-center; do
  sudo systemctl restart $u
done
REMOTE
then
  exit 1
fi

# ui_code：C3 畫面的 HTTP 狀態碼
ui_code() {
  curl -s -o /dev/null -m 5 -w '%{http_code}' https://c3-01.poc.lab:9021/
}

# 2. 等畫面 200：每 5 秒看一次，最多 60 次
for i in $(seq 1 60); do
  if [ "$(ui_code)" = 200 ]; then
    break
  fi

  sleep 5
done

# 3. 畫面與 C3 內建 Prometheus 的指標種類數（歷史指標不該因換版本而消失）
# 連不上時指標種類算 0，不讓這一行中止
if ! all_names=$(curl -s -m 10 \
  --cert ~/pki/certs/svc-ops.crt \
  --key ~/pki/keys/svc-ops.key \
  https://c3-01.poc.lab:9090/api/v1/label/__name__/values); then
  all_names=""
fi

kinds=$(echo "$all_names" | grep -o 'confluent_kafka_server[a-z_]*' | sort -u)

echo "UI=$(ui_code)（約 $((i * 5)) 秒）；Prometheus 指標 $(echo "$kinds" | grep -c .) 種"

if [ "$(ui_code)" != 200 ]; then
  exit 1
fi
EOF

chmod 0700 ~/conf/c3-change.sh

# 1. 換之前的版本
echo "C3 現在：$(ssh c3-01.poc.lab 'rpm -q confluent-control-center-next-gen')"

# 2. 升到 2.6.1
bash ~/conf/c3-change.sh 2.6.1 install

# 3. C3 自己寫的 4 個檔，擁有者都是 cp-control-center
files="alertmanager-generated.yml trigger_rules-generated.yml"
files="$files recording_rules-generated.yml prometheus-generated-local.yml"
owners=$(ssh c3-01.poc.lab "cd /etc/confluent-control-center; sudo stat -c %U $files" | sort -u | paste -sd, -)
echo "C3 自己寫的 4 個檔：$owners"

# 4. alice 真的從 C3 登入（首頁不經過 MDS，只看 200 抓不到；C3 起來後健康檢查還要一點時間，最多等 60 秒）
alice_pass=$(cat ~/secrets/ad-test-users.pass)
login_url=https://c3-01.poc.lab:9021/api/metadata/security/1.0/authenticate

for i in $(seq 1 12); do
  if [ "$(curl -s -u "alice:$alice_pass" -o /dev/null -m 30 -w '%{http_code}' "$login_url")" = 200 ]; then
    break
  fi

  sleep 5
done

echo "alice 從 C3 登入：$(curl -s -u "alice:$alice_pass" -o /dev/null -m 30 -w '%{http_code}' "$login_url")"
```

```out
C3 現在：confluent-control-center-next-gen-2.5.1-1.noarch
confluent-control-center-next-gen-2.6.1-1.noarch config=same exec=/etc/confluent/control-center/control-center.properties lock=confluent-control-center-next-gen-0:2.6.1-1.*
UI=200（約 30–35 秒）；Prometheus 指標 125 種（歷史指標沒有因換版本而消失）
C3 自己寫的 4 個檔：cp-control-center
alice 從 C3 登入：200
```

> 陷阱（lab 實測，2.6.0／2.6.1 之間的換版本）：RPM 換版本（升級或退回）會把 `trigger_rules-generated.yml`、`recording_rules-generated.yml`、`prometheus-generated-local.yml` 改回 `root:root 644`（還有 `alertmanager-generated.yml`）。畫面照樣打得開，但之後在 C3 上改告警規則會寫不進去，所以 `c3-change.sh` 換完套件一定把這 4 個檔改回 `cp-control-center`（`prometheus-generated.yml` 是我們寫的，維持 root）。2.5.1 → 2.6.1 也一樣（上面的 out）。

> 此時 C3（2.6.1）配著 CP 8.2.4：在原廠支援範圍內（2.6.x：7.5.15 到 8.3.x），第一段中途、也就是 broker 只升了一部分時 C3 看到的是新舊混合的叢集，這是原廠建議的順序。

## 29.4 第一段：broker 逐台

@role 小安 | ops02 | root

每台：解開 versionlock → 這台裝的每個 Confluent 套件都換成 8.3.2 → 重新鎖 → **`daemon-reload`**（RPM 升級會換掉 systemd 的 unit 檔，不 reload 就重啟，用的還是舊的定義）→ 確認設定檔沒被動、ExecStart 還指著我們的設定 → 重啟 → 等 MDS 回 200、under-replicated 回到 0 才做下一台。換套件那幾步（解鎖、換版本、重新鎖、`daemon-reload`）寫成小腳本 `~/conf/pkg-swap.sh`，29.5、29.6、29.8 也用它：用 `ssh <主機> bash -s -- 8.3.2 install < ~/conf/pkg-swap.sh` 送到那台執行：

```bash
# 1. 換套件的步驟寫成小腳本：29.4–29.8 的 broker、controller、REST Proxy、操作機都用它
cat > ~/conf/pkg-swap.sh <<'EOF'
#!/usr/bin/env bash
# pkg-swap.sh <版本> <install|downgrade> — 把這台裝著的每個 Confluent 套件換成 <版本>
# 做什麼：解開 versionlock → dnf install（或 downgrade）每個 confluent-* 套件的 <版本> → 用新版本重新鎖 → daemon-reload
# 在哪裡跑：各主機上以 cpuser 執行（用 sudo）：ssh <主機> bash -s -- 8.3.2 install < ~/conf/pkg-swap.sh；操作機上 root 直接 bash 它
# 結束碼：0 換好；1 換套件失敗（versionlock 已解開，要手動處理）
# 改的時候要注意：不重啟服務，由呼叫的一方重啟（REST Proxy 要先從 LB 停用）

version=$1
action=$2

# 1. 這台裝著的 Confluent 套件，換成這個版本的名稱，例：confluent-server-8.3.2 confluent-cli-8.3.2
packages=$(rpm -qa 'confluent-*' --qf "%{NAME}-$version ")

# 2. 解鎖、換版本、用新版本重新鎖
sudo dnf -q versionlock delete 'confluent-*' > /dev/null

if ! sudo dnf -q -y --refresh $action $packages > /dev/null; then
  echo "$(hostname) 換套件失敗（versionlock 已解開）" >&2
  exit 1
fi

sudo dnf -q versionlock add $packages > /dev/null

# 3. RPM 換掉了 systemd 的 unit 檔：重新載入，重啟時才會用新的定義
sudo systemctl daemon-reload
EOF

chmod 0700 ~/conf/pkg-swap.sh

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
admin="--bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"

for h in kb01 kb02 kb03 kb04; do
  t0=$(date +%s)

  # 2. 換套件前後比 server.properties 的 sha256 前 12 碼（確認 RPM 沒動我們的設定）；換套件
  before=$(ssh $h.poc.lab 'sudo sha256sum /etc/confluent/kafka/server.properties' | cut -c1-12)
  ssh $h.poc.lab bash -s -- 8.3.2 install < ~/conf/pkg-swap.sh
  after=$(ssh $h.poc.lab 'sudo sha256sum /etc/confluent/kafka/server.properties' | cut -c1-12)

  # 3. 設定檔沒被動、ExecStart 還指著我們的設定
  if [ "$before" = "$after" ]; then
    config=沒變
  else
    config=被改了
  fi

  echo "$h $(ssh $h.poc.lab 'rpm -q confluent-server') 設定檔$config exec=$(ssh $h.poc.lab \
    'systemctl show confluent-server -p ExecStart --value' | grep -o '/etc/[^ ]*properties')"

  # 4. 重啟
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  # 5. 等 MDS 回 200、under-replicated 回到 0：各每 5 秒看一次，最多 60 次
  for i in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  for j in $(seq 1 60); do
    under=$(kafka-topics $admin --describe --under-replicated-partitions 2> /dev/null \
      | awk '/Partition:/ {c++} END {print c + 0}')

    if [ "$under" = 0 ]; then
      break
    fi

    sleep 5
  done

  echo "  MDS 200（約 $((i * 5)) 秒）under-replicated=$under，這台 $(( $(date +%s) - t0 )) 秒"
done
```

```out
kb01 confluent-server-8.3.2-1.noarch 設定檔沒變 exec=/etc/confluent/kafka/server.properties
  MDS 200（約 20 秒）under-replicated=0，這台 73 秒
（4 台，每台 70–110 秒）
```

> 陷阱：重啟前沒做 `daemon-reload`，systemd 會印 `The unit file … changed on disk`。設定還是我們的（drop-in 會疊上去），但下一次 reload 才會真的用新的 unit；所以每台都在重啟前 reload。

## 29.5 第一段：controller 逐台（leader 最後）

@role 小安 | ops02 | root

步驟和 broker 一樣。controller 的健康看 quorum：這台回來、`Lag` 是 0。**leader 會在過程中換人**（實測做完第二台時 leader 從 kc02 換到 kc01），所以每做一台之前都重新查一次 leader，跳過它，最後一輪才做 leader：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
controllers=kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093
Q="kafka-metadata-quorum --bootstrap-controller $controllers --command-config /root/conf/client-internal.properties"

done_list=""

for round in 1 2 3; do
  # 1. 每一輪重新查 leader（做的過程中 leader 會換人），例：kc02
  leader=kc0$($Q describe --status 2> /dev/null | awk '/LeaderId/ {print $2}')

  # 2. 這一輪做哪台：跳過做完的；前兩輪也跳過 leader
  h=""

  for c in kc01 kc02 kc03; do
    if [[ " $done_list " == *" $c "* ]]; then
      continue
    fi

    if [ $c = $leader ]; then
      if [ $round -lt 3 ]; then
        continue
      fi
    fi

    h=$c
    break
  done

  # 3. 換套件、重啟
  ssh $h.poc.lab bash -s -- 8.3.2 install < ~/conf/pkg-swap.sh
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  # 4. 等這台的 Lag 回到 0：每 5 秒看一次，最多 60 次
  #    describe --replication 每台一行，kc01 的 NodeId 是 1：找開頭是這個 NodeId 的那一行，取第 4 欄
  id=${h#kc0}
  sleep 10

  for i in $(seq 1 60); do
    lag=$($Q describe --replication 2> /dev/null \
      | grep -E "^[[:space:]]*$id[[:space:]]" | awk '{print $4}')

    if [ "$lag" = 0 ]; then
      break
    fi

    sleep 5
  done

  echo "$h $(ssh $h.poc.lab 'rpm -q confluent-server') Lag=$lag（這輪開始時 leader=$leader）"
  done_list="$done_list $h"
done
```

```out
kc01 confluent-server-8.3.2-1.noarch Lag=0（這輪開始時 leader=kc02）
kc03 confluent-server-8.3.2-1.noarch Lag=0（這輪開始時 leader=kc01）
kc02 confluent-server-8.3.2-1.noarch Lag=0（這輪開始時 leader=kc01）
```

`describe --replication` 的欄位依序是 NodeId、DirectoryId、LogEndOffset、**Lag**、…，看的是第 4 欄。

## 29.6 第一段：REST Proxy 與操作機的工具

@role 小安 | ops02 | root

原廠要求 RBAC 環境在升 REST Proxy 之前，先讓 REST Proxy 的身分在 `_confluent-command` 有 ResourceOwner（原本只有 DeveloperRead）：

```bash
source ~/conf/kraft.env

# svc-ops 登入 MDS，給 svc-rest 在 _confluent-command 的 ResourceOwner
confluent login --url https://kb01.poc.lab:8090 --certificate-authority-path ~/pki/certs/bank-root.pem \
  --certificate-only --client-cert-path ~/pki/certs/svc-ops.crt --client-key-path ~/pki/keys/svc-ops.key > /dev/null
result=$(confluent iam rbac role-binding create \
  --principal User:svc-rest \
  --role ResourceOwner \
  --resource Topic:_confluent-command \
  --kafka-cluster $CLUSTER_ID 2>&1)

# 剛逐台重啟過 broker：auth topic 的 leader 剛搬家，第一筆寫入常回 50003（見 28.4）；只有這個錯誤再送一次
if echo "$result" | grep -q "not the current leader"; then
  result=$(confluent iam rbac role-binding create \
    --principal User:svc-rest \
    --role ResourceOwner \
    --resource Topic:_confluent-command \
    --kafka-cluster $CLUSTER_ID 2>&1)
fi

# 成功只印兩行；其他錯誤整段印出來，停下來看
if echo "$result" | grep -q "ResourceOwner"; then
  echo "$result" | grep -E 'Role|Name' | tr -s ' '
else
  echo "$result"
fi
```

```out
| Role | ResourceOwner |
| Name | _confluent-command |
```

先換操作機自己的 `kafka-*` 與 `confluent` 指令：

```bash
# 操作機自己（root）：同一支小腳本，在本機跑
bash ~/conf/pkg-swap.sh 8.3.2 install
echo "ops02 $(rpm -q confluent-server confluent-cli | paste -sd' ')"
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
# -c：先把小腳本複製到那台的 /tmp/；-b：重啟前在那台執行它
~/conf/rest-restart.sh rest01 -c ~/conf/pkg-swap.sh -b 'bash /tmp/pkg-swap.sh 8.3.2 install'
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
~/conf/rest-restart.sh rest02 -c ~/conf/pkg-swap.sh -b 'bash /tmp/pkg-swap.sh 8.3.2 install'
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
for h in rest01 rest02; do
  echo "$h $(ssh $h.poc.lab 'rpm -q confluent-kafka-rest')"
done
```

```out
rest01 confluent-kafka-rest-8.3.2-1.noarch
rest02 confluent-kafka-rest-8.3.2-1.noarch
```

第一段結束：照第 19 章 19.1–19.3 再驗一次（實測全數通過）。這時 features 還是 8.2，隨時可以照 29.8 退回。

## 29.7 第二段：JDK 21 → 25

@role 小安 | ops02 | root

**這一節在做什麼**：把 controller、broker、REST Proxy、C3、操作機的 JDK 全部從 21 換成 25。前提：第一段已全部完成並驗收。和 7.1 節一樣解壓到 `/opt/java/<版本目錄>`，只是把 `/opt/java/current` 切過去；所有服務的 drop-in 寫的都是 `/opt/java/current`，設定檔不用改。舊的 JDK 21 目錄留著，退回就是把連結切回去。解壓與切連結寫成小腳本 `~/conf/jdk-switch.sh`（tar 先 scp 到那台的 `/tmp/`），每一台都用它。C3 也換：原廠對 Control Center 只寫「最低 Java 17」、沒有明列 25 的測試結果，本案決定全部節點一致用 25（上線前請向原廠支援確認）；C3 只有一台，重啟時畫面約 1 分鐘不能用。

> Java 25 在 CP 8.3 的相容表上是「支援」，原廠部署文件的建議版本仍是 21。這一段是照銀行「升 8.3 時一起換 25」的要求做；銀行沒有這個要求時，留在 21 就好（只做第一、三段）。

先 controller（每輪重查 leader、leader 最後）：

```bash
# 1. 切 JDK 的步驟寫成小腳本：controller、broker、REST Proxy、C3、操作機都用它
cat > ~/conf/jdk-switch.sh <<'EOF'
#!/usr/bin/env bash
# jdk-switch.sh <tar 檔名> — 把 /tmp/<tar 檔名> 解到 /opt/java，/opt/java/current 指過去
# 做什麼：解壓到 /opt/java/<tar 裡的頂層目錄> → 刪掉 /tmp 的 tar → 擁有者改 root → 切 current（舊的 JDK 目錄留著，退回就是切回去）
# 在哪裡跑：各主機上以 cpuser 執行（用 sudo）；tar 要先 scp 到那台的 /tmp/
# 結束碼：0 切好；非 0 某一步失敗（current 沒切）
# 改的時候要注意：不重啟服務；所有 drop-in 寫的都是 /opt/java/current，切完重啟就用新的 JDK
set -e

tarball=/tmp/$1

# tar 裡的頂層目錄，例：jdk-25.0.5+8
dir=$(tar -tzf $tarball | head -1 | cut -d/ -f1)

sudo tar -xzf $tarball -C /opt/java
rm -f $tarball
sudo chown -R root:root /opt/java/$dir
sudo ln -sfn /opt/java/$dir /opt/java/current
EOF

chmod 0700 ~/conf/jdk-switch.sh

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
controllers=kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093
Q="kafka-metadata-quorum --bootstrap-controller $controllers --command-config /root/conf/client-internal.properties"

# 2. 銀行給的 JDK 25 tar（有好幾個就取最新的）
JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1)
echo "新 JDK：$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1)"

# 在那台查：confluent-server 正在跑的 java 執行檔
java_cmd='sudo readlink /proc/$(systemctl show confluent-server -p MainPID --value)/exe'

done_list=""

for round in 1 2 3; do
  # 3. 這一輪做哪台（同 29.5）：重新查 leader；跳過做完的；前兩輪也跳過 leader
  leader=kc0$($Q describe --status 2> /dev/null | awk '/LeaderId/ {print $2}')
  h=""

  for c in kc01 kc02 kc03; do
    if [[ " $done_list " == *" $c "* ]]; then
      continue
    fi

    if [ $c = $leader ]; then
      if [ $round -lt 3 ]; then
        continue
      fi
    fi

    h=$c
    break
  done

  # 4. 送 tar、切 JDK、重啟
  scp -q "$JDK_TAR" $h.poc.lab:/tmp/
  ssh $h.poc.lab bash -s -- $(basename $JDK_TAR) < ~/conf/jdk-switch.sh
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  # 5. 等這台的 Lag 回到 0（describe --replication 開頭是這個 NodeId 的那一行，第 4 欄）
  id=${h#kc0}
  sleep 10

  for i in $(seq 1 60); do
    lag=$($Q describe --replication 2> /dev/null \
      | grep -E "^[[:space:]]*$id[[:space:]]" | awk '{print $4}')

    if [ "$lag" = 0 ]; then
      break
    fi

    sleep 5
  done

  echo "$h java=$(ssh $h.poc.lab "$java_cmd") Lag=$lag"
  done_list="$done_list $h"
done
```

```out
新 JDK：jdk-25.0.5+8
kc01 java=/opt/java/jdk-25.0.5+8/bin/java Lag=0
（3 台，每台約 15 秒）
```

再 broker（逐台重啟，應用程式不受影響；操作機、C3、REST Proxy 在下面另外做）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1)
admin="--bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"

# 在那台查：confluent-server 正在跑的 java 執行檔
java_cmd='sudo readlink /proc/$(systemctl show confluent-server -p MainPID --value)/exe'

# broker 逐台：送 tar、切 JDK、重啟，等 MDS 200、under-replicated 回到 0
for h in kb01 kb02 kb03 kb04; do
  scp -q "$JDK_TAR" $h.poc.lab:/tmp/
  ssh $h.poc.lab bash -s -- $(basename $JDK_TAR) < ~/conf/jdk-switch.sh
  ssh $h.poc.lab 'sudo systemctl restart confluent-server'

  for i in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      break
    fi

    sleep 5
  done

  for j in $(seq 1 60); do
    under=$(kafka-topics $admin --describe --under-replicated-partitions 2> /dev/null \
      | awk '/Partition:/ {c++} END {print c + 0}')

    if [ "$under" = 0 ]; then
      break
    fi

    sleep 5
  done

  echo "$h java=$(ssh $h.poc.lab "$java_cmd") 200（約 $((i * 5)) 秒）under-replicated=$under"
done
```

```out
kb01 java=/opt/java/jdk-25.0.5+8/bin/java 200（約 20 秒）under-replicated=0
```

再操作機、C3（C3 重啟期間畫面不能用）：

```bash
JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1)

# 1. 操作機自己（root）：tar 放到 /tmp 再用同一支小腳本
cp "$JDK_TAR" /tmp/
bash ~/conf/jdk-switch.sh $(basename $JDK_TAR)
echo "ops02 $(java -version 2>&1 | head -1)"

# 2. C3：送 tar、切 JDK、重啟，等畫面 200
scp -q "$JDK_TAR" c3-01.poc.lab:/tmp/
ssh c3-01.poc.lab bash -s -- $(basename $JDK_TAR) < ~/conf/jdk-switch.sh
ssh c3-01.poc.lab 'sudo systemctl restart confluent-control-center'

for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 5
done

# 3. C3 正在跑的 java 執行檔
java_cmd='sudo readlink /proc/$(systemctl show confluent-control-center -p MainPID --value)/exe'
echo "c3-01 java=$(ssh c3-01.poc.lab "$java_cmd") 200（約 $((i * 5)) 秒）"
```

```out
ops02 openjdk version "25.0.5" … LTS
c3-01 java=/opt/java/jdk-25.0.5+8/bin/java 200（約 60 秒）
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
JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1)

# -c：tar 與小腳本先複製到那台的 /tmp/；-b：重啟前在那台切 JDK
~/conf/rest-restart.sh rest01 -c "$JDK_TAR $HOME/conf/jdk-switch.sh" -b "bash /tmp/jdk-switch.sh $(basename $JDK_TAR)"
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up
bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
JDK_TAR=$(ls ~/landing/bank/OpenJDK25U-jdk_x64_linux_hotspot_*.tar.gz | sort -V | tail -1)

~/conf/rest-restart.sh rest02 -c "$JDK_TAR $HOME/conf/jdk-switch.sh" -b "bash /tmp/jdk-switch.sh $(basename $JDK_TAR)"
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
for h in rest01 rest02; do
  echo "$h java=$(ssh $h.poc.lab 'readlink -f /opt/java/current')"
done
```

```out
rest01 java=/opt/java/jdk-25.0.5+8
rest02 java=/opt/java/jdk-25.0.5+8
```

broker 的日誌會多一則 `WARNING: A terminally deprecated method in sun.misc.Unsafe has been called`：原廠說明這只是警告，JDK 25 上照常運作。第二段結束：照第 19 章再驗一次（實測全數通過）。

## 29.8 回滾演練（finalize 之前）：kb04 退回 8.2.4，再升回去

@role 小安 | ops02 | root

**這一節在做什麼**：在 finalize 之前，實際演練一次「退回 8.2.4」，確認出事時真的退得回去，再升回來。這是 finalize 前最後一個還能退的機會。任何一段出問題、features 還沒升（`describe` 看到的還是 `CP-8.2-…`），就逐台退：先把 JDK 切回 21，再把套件 `downgrade` 回 8.2.4、重新鎖、`daemon-reload`、重啟。順序和升級相反（操作機、REST Proxy → controller → broker；C3 不用退，2.6.x 也支援 8.2.x，真的要退照第 31 章的 `c3-change.sh`）。實測拿 kb04 單台演練（其他台都是 8.3.2）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
h=kb04

# 1. JDK 先切回 21（8.2 不支援 25；21 的目錄還在）
ssh $h.poc.lab 'sudo ln -sfn $(ls -d /opt/java/jdk-21* | sort -V | tail -1) /opt/java/current'

# 2. 套件退回 8.2.4（同一支小腳本，downgrade）、重啟
ssh $h.poc.lab bash -s -- 8.2.4 downgrade < ~/conf/pkg-swap.sh
ssh $h.poc.lab 'sudo systemctl restart confluent-server'

# 3. 等 MDS 回 200：每 5 秒看一次，最多 60 次
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
    break
  fi

  sleep 5
done

# 4. 版本、正在跑的 java 執行檔
java_cmd='sudo readlink /proc/$(systemctl show confluent-server -p MainPID --value)/exe'
echo "$h $(ssh $h.poc.lab 'rpm -q confluent-server') $(ssh $h.poc.lab "$java_cmd") MDS 200（約 $((i * 5)) 秒）"
```

```out
kb04 confluent-server-8.2.4-1.noarch /opt/java/jdk-21.0.x+y/bin/java MDS 200（約 15–20 秒）
```

演練完馬上把它升回去（和 29.4、29.7 同樣的做法，只動這一台）：

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
h=kb04

# 1. JDK 切回 25（目錄還在）
ssh $h.poc.lab 'sudo ln -sfn $(ls -d /opt/java/jdk-25* | sort -V | tail -1) /opt/java/current'

# 2. 套件升回 8.3.2、重啟
ssh $h.poc.lab bash -s -- 8.3.2 install < ~/conf/pkg-swap.sh
ssh $h.poc.lab 'sudo systemctl restart confluent-server'

# 3. 等 MDS 回 200
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
    break
  fi

  sleep 5
done

# 4. 版本、正在跑的 java 執行檔
java_cmd='sudo readlink /proc/$(systemctl show confluent-server -p MainPID --value)/exe'
echo "$h $(ssh $h.poc.lab 'rpm -q confluent-server') $(ssh $h.poc.lab "$java_cmd") MDS 200（約 $((i * 5)) 秒）"
```

```out
kb04 confluent-server-8.3.2-1.noarch /opt/java/jdk-25.0.5+8/bin/java MDS 200（約 15–20 秒）
```

退回的那台在其他台都是 8.3.2 的叢集裡正常服務（MDS 回 200）；上面已經把它升回 8.3.2、JDK 25，接著做 finalize。

> 回滾：finalize 之後就不能用這個方法了。真的要退，得用 29.2 的備份與原廠支援的還原程序，所以 finalize 一定排在前兩段都驗收、觀察一段時間之後。

## 29.9 第三段：finalize（之後不能退回 8.2）

@role 小安 | ops02 | root

**這一節在做什麼**：把叢集的 metadata 版本（features）升到 4.3，正式啟用 8.3 的新功能。**這一步做完不能回頭**：前兩段、29.8 的回滾演練都完成並觀察一段時間後才做。先看 4.3 會把哪些 feature 升到多少，再 `--dry-run`（只預演、不真的升）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
F="kafka-features --bootstrap-server kb01.poc.lab:9094 --command-config /root/conf/client-admin.properties"

# 1. 4.3 會把哪些 feature 升到多少
$F version-mapping --release-version 4.3 2> /dev/null

# 2. 只預演、不真的升
$F upgrade --release-version 4.3 --dry-run 2> /dev/null
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
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
F="kafka-features --bootstrap-server kb01.poc.lab:9094 --command-config /root/conf/client-admin.properties"

# 1. 正式升（做完不能回頭）
$F upgrade --release-version 4.3 2> /dev/null

# 2. 現在的 metadata 版本：那一行的第 2 欄是 feature 名稱、第 8 欄是版本
line=$($F describe 2> /dev/null | grep confluent.metadata.version | tr -s ' \t' ' ')
echo "$line" | cut -d' ' -f2,8
```

```out
confluent.metadata.version was upgraded to 137.
（7 行 was upgraded）
confluent.metadata.version CP-8.3-IV0B
```

最後照第 19 章完整驗收一次。

## 29.10 遷移完成：確認版本、記下新的基準

@role 小安 | ops02 | root

**這一節在做什麼**：收尾確認，並把「新基準版本」記下來。三段都驗收過、觀察一段時間之後，用一張表確認每台主機的版本都是預期的（Confluent 與 JDK 都是目標版本，C3 也是 JDK 25）：

```bash
# 每台一行：JDK 目錄、Confluent 套件的版本、OS 版本（每台執行 EOF 之前的那一段）
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -s <<'EOF'
java=$(readlink /opt/java/current | sed s#/opt/java/##)
confluent=$(rpm -qa "confluent-*" --qf "%{VERSION}\n" | sort -u | paste -sd,)
. /etc/os-release
echo "$(hostname) java=$java confluent=$confluent os=$VERSION_ID"
EOF
done
```

```out
kc01 java=jdk-25.0.x+y confluent=8.3.2 os=9.6
（kb01–kb04、rest01、rest02 同上）
c3-01 java=jdk-25.0.5+8 confluent=2.6.1 os=9.6
```

`os=9.6` 還沒動，那是第 30 章的事。**記下新的基準**：之後新增或換掉主機（25.1、25.2 節）要裝**現行版本**——7.1 節裝 JDK 25（`OpenJDK25U-*`）、第 8 章的版本號換成 8.3.2 與 2.6.1，不是這本書前面寫的 8.2.4／2.5.1。用 `install/` 腳本的話，改 `conf/site.env` 的 `CP_VERSION`、`C3_VERSION`、`JDK_MAJOR` 三個值就行（`29-upgrade.sh adopt` 會代改）。

# 30. 第三十站：OS 修補與小版本更新

下面這張圖把整章的順序和每台機器重複做的事畫出來。

![ospatch]

**這一章在做什麼**：銀行的作業系統要更新（每月修補，或 9.6 → 9.8 小版本）時，我方怎麼一台一台修，修完確認平台健康。前提：Confluent 套件已被 versionlock 鎖住（第 8 章）。主線上接在第 29 章之後。

銀行每月的 OS 修補照常由銀行的套件庫（Satellite／Nexus／web server）發布；平台這邊要做的只是「一台一台修、該重開就重開、健康了才做下一台」。Confluent 套件被 versionlock 鎖住（第 8 章），JDK 是 tar（7.1 節），所以 `dnf update` 只會動 OS 套件；C3 的前置套件 `cyrus-sasl`、`openssl-devel` 跟著 OS 修補走（不鎖）。

這一章處理兩種情境，**步驟完全一樣**，差別只在套件庫裡有什麼、更新量多大、幾乎一定要重開機：

| 情境 | 例子 | 更新量 | 重開機 |
|---|---|---|---|
| 每月修補 | 9.6 內的安全更新 | 幾個到幾十個套件 | 偶爾（核心、glibc、systemd 更新時） |
| **小版本更新**（主線，30.5） | RHEL 9.6 → 9.8 | 一百多個套件（lab 實測 120–126 個，依主機而異，含 glibc、systemd、openssh、openssl） | 一定（glibc、systemd、核心都換） |

主線裡這一章接在第 29 章之後：Confluent 已是 8.3.2、JDK 已是 25，現在把 OS 從安裝基底的 **9.6 更新到 9.8**。30.0 是銀行的事（把套件庫同步到 9.8），30.1–30.4 是更新本身，30.5 是驗證、重開機的限制、回滾與「別的小版本怎麼套用」。

| 順序 | 主機 | 修完之後 |
|---|---|---|
| 1 | broker 逐台 | 要重開機就重開；平台服務要重啟就重啟；等 MDS 200、沒有 under-replicated 才下一台 |
| 2 | controller 逐台，leader 最後 | 等 quorum 的 Lag 回到 0 |
| 3 | REST Proxy、C3、操作機 | REST 經 LB 200、C3 200 |

要不要重開機、要不要重啟服務，用 `dnf needs-restarting` 判斷，不靠人記：`-r` 看核心程式庫（kernel、glibc、systemd…）有沒有更新，`-s` 列出用到被更新程式庫、需要重啟的服務。JVM 自帶 TLS 實作，OS 的 openssl 更新通常不會把 Confluent 服務列進 `-s`；但 JVM 載入的 glibc 換了，**服務要重啟（或重開機）才會用到新的**。

> **lab 限制**：**lab 是容器，不能真的重開機**（核心是 WSL2 的，`systemctl reboot` 會失敗：Could not activate remote peer）；kernel 更新也不會生效，因為容器根本沒有自己的核心。30.2–30.4 的指令用 `systemd-detect-virt -c` 判斷主機是不是容器：是的話，「要重開機：是」改成重啟該主機的平台服務（讓 JVM 載入新的 glibc），正式環境才是 `sudo systemctl reboot`。這是 lab 能做到的最接近的替代，**不等於重開機的驗證**：開機順序、fstab、網卡、核心模組、systemd unit 的 enable 狀態都沒有被測到，正式環境第一次做小版本更新請排在變更窗口，並先在測試環境走一遍。

## 30.0 銀行先把套件庫同步到要更新的版本

@role 銀行 OS 團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

前提：銀行的套件庫已經有這一輪要更新到的內容。每月修補是銀行例行的同步；小版本更新就是把套件庫同步到 9.8（Satellite 換 content view、Nexus 同步新的 proxy 倉庫、web server 重新 reposync，各家做法不同，從主機看都是同一個 `bank-os` repo）。我方要確認兩件事：**套件庫裡有 `rocky-release`／`redhat-release` 的 9.8**（沒有就代表只是同一小版本內的修補，不是小版本更新），以及 **`confluent-*` 不在更新清單裡**（30.1 檢查）。

lab 沒有銀行的套件庫同步，就自己做：在一個乾淨的 9.6 容器裡，把 5.1 下載的 9.6 套件裝起來（等於「裝好這批套件的 9.6 主機」），對 Rocky 的 9.8 倉庫（`pub/rocky/9.8`）做 `dnf update --downloadonly`，就得到「9.6 主機升到 9.8 要的更新集合」。把更新集合和 9.6 的內容合併、重建索引，換上 repo01 的 `/os/`。`--downloadonly` 只下載不安裝；下載的檔案先複製到銀行的目錄、再建索引：

```bash
cd ~/kafka-lab

# 1. 在一個乾淨的 9.6 容器裡做更新集合（bank-os 掛成 /out；執行 EOF 之前的那一段）
podman run --rm -i -v "$(cygpath -m "$PWD/bank-os"):/out" lab-node:96 bash -e -s <<'EOF'
t0=$(date +%s)

# 1-1. 裝上 9.6 的套件：等於「裝好這批套件的 9.6 主機」
if ! dnf -q -y --disablerepo="*" install /out/9.6/Packages/*.rpm > /tmp/i.log 2>&1; then
  echo "裝 9.6 套件失敗："
  tail -5 /tmp/i.log
  false
fi

# 1-2. Rocky 9.8 的三個倉庫（pub/rocky/9.8）
cat > /etc/yum.repos.d/rocky-98.repo <<'REPO'
[r98-baseos]
name=Rocky 9.8 BaseOS
baseurl=https://dl.rockylinux.org/pub/rocky/9.8/BaseOS/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1
[r98-appstream]
name=Rocky 9.8 AppStream
baseurl=https://dl.rockylinux.org/pub/rocky/9.8/AppStream/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1
[r98-extras]
name=Rocky 9.8 extras
baseurl=https://dl.rockylinux.org/pub/rocky/9.8/extras/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1
REPO

# 1-3. 9.6 → 9.8 要的更新：只下載、不安裝
mkdir -p /out/9.8-updates/Packages /tmp/dl

if ! dnf -q -y --disablerepo="*" --enablerepo=r98-baseos,r98-appstream,r98-extras \
  update --downloadonly --downloaddir /tmp/dl > /tmp/u.log 2>&1; then
  echo "抓 9.8 的更新失敗（多半是連不到 dl.rockylinux.org，稍後重跑這一段）："
  tail -5 /tmp/u.log
  false
fi

# 1-4. 先複製到銀行的目錄、再建索引（下載目錄直接當套件庫時，dnf 可能把用過的 RPM 刪掉）
cp -a /tmp/dl/. /out/9.8-updates/Packages/
createrepo_c -q /out/9.8-updates

# 1-5. 9.6 的內容加上更新集合，合併成 9.8 的套件庫
mkdir -p /out/9.8/Packages
cp -a /out/9.6/Packages/. /out/9.8/Packages/
cp -a /out/9.8-updates/Packages/. /out/9.8/Packages/
createrepo_c -q /out/9.8

updates_count=$(ls /out/9.8-updates/Packages | wc -l)
updates_mb=$(du -sm /out/9.8-updates | cut -f1)
merged_count=$(ls /out/9.8/Packages | wc -l)
echo "9.8 更新集合：$updates_count 個 RPM、$updates_mb MB（$(( $(date +%s) - t0 )) 秒）；合併後的套件庫 $merged_count 個 RPM"
EOF
```

```out
9.8 更新集合：155 個 RPM、80 MB（約 100–250 秒）；合併後的套件庫 226 個 RPM
```

把合併好的內容換上 repo01 的 `/os/`：

```bash
cd ~/kafka-lab

# 1. 換上 repo01 的 /os/
podman exec lab-repo01-1 bash -c 'rm -rf /var/www/repo/os/*'
podman cp "$(cygpath -m "$PWD/bank-os/9.8")/." lab-repo01-1:/var/www/repo/os/

# 2. 擁有者改回 repodeploy，看 RPM 數與 release 套件（在 repo01 執行 EOF 之前的那一段）
podman exec -i lab-repo01-1 bash -s <<'EOF'
chown -R repodeploy:repodeploy /var/www/repo/os
count=$(ls /var/www/repo/os/Packages | wc -l)
release=$(ls /var/www/repo/os/Packages | grep rocky-release)
echo "repo01 /os/：$count 個 RPM；rocky-release：$release"
EOF
```

```out
repo01 /os/：226 個 RPM；rocky-release：rocky-release-9.8-1.2.el9.noarch.rpm
```

> 說明：更新集合是 155 個 RPM（124 個要更新的套件加上相依，2026-11-08 從 Rocky 9.8 鏡像實測，11-01 是 156 個、10-30 是 154 個；鏡像更新後數字會變），只有 80 MB，因為這批主機的套件只有最小安裝加上平台要用的工具；真正的 RHEL 主機裝的東西多，數字會大很多，請銀行的 OS 團隊用同樣的方法（在代表性的主機上 `dnf update --downloadonly`）估算。套件庫合併後同時有 9.6 和 9.8 的版本，dnf 會挑最新的。

> 陷阱：dnf 會快取套件庫的中繼資料 48 小時，剛同步完主機可能還看到舊的清單。30.1 之後的指令都帶 `--refresh`。

## 30.1 修補前：看有哪些更新、Confluent 有沒有鎖住

@role 小安 | ops02 | root

每台印出：目前的 OS 版本、套件庫裡 release 套件的版本（小版本更新時會比目前的新）、可更新幾個、其中跟平台有關的幾個、鎖住幾個 confluent 套件；再比對**主版本**（套件庫是 10.x 就停，見下面的保險），一致才用 `dnf upgrade --assumeno` 預覽交易（只看摘要，不執行）：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 開始前叢集是健康的
echo "under-replicated：$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --describe --under-replicated-partitions 2> /dev/null | awk '/Partition:/ {c++} END {print c + 0}')"

# 2. 每種主機挑一台看（只看不改；每台執行 EOF 之前的那一段）
for h in kc01 kb01 rest01 c3-01 ops02; do
  ssh $h.poc.lab bash -s <<'EOF'
# 可更新的套件名稱，一行一個、去掉架構，例：glibc
updates=$(mktemp)
sudo dnf -q check-update --refresh 2> /dev/null | awk '/^[a-zA-Z0-9]/ {print $1}' | sed 's/\.[^.]*$//' > $updates

# 目前的 OS 版本、套件庫裡 release 套件（rocky-release 或 redhat-release）的版本
. /etc/os-release
current=$VERSION_ID
release_pkg=$(rpm -q --whatprovides system-release --qf "%{NAME}\n" | head -1)
available=$(sudo dnf -q repoquery --latest-limit 1 --qf %{version} $release_pkg 2> /dev/null | head -1)

# 一行摘要：可更新幾個、其中平台相關的、confluent-* 幾個（要是 0）、鎖住幾個 confluent 套件
platform_pkgs='glibc|systemd|openssh-server|kernel|rocky-release|redhat-release|openssl-libs'
platform=$(grep -xE "$platform_pkgs" $updates | paste -sd" ")
update_count=$(grep -c . $updates)
confluent_updates=$(grep -c "^confluent-" $updates)
locked=$(sudo dnf -q versionlock list 2> /dev/null | grep -c confluent)
summary="可更新 $update_count 個（平台相關：$platform）；其中 confluent-* $confluent_updates 個"
echo "$(hostname)：OS $current，套件庫的 release 套件 $available；$summary；鎖住 $locked 個 confluent 套件"
rm -f $updates

# 主版本不一致就停；一致才預覽交易（--assumeno：只看摘要，不執行）
stop=no

if [ -n "$available" ]; then
  if [ "${available%%.*}" != "${current%%.*}" ]; then
    stop=yes
  fi
fi

if [ $stop = yes ]; then
  echo "  停：套件庫是 ${available%%.*}.x 的內容，不是 ${current%%.*}.x（小版本更新只能在同一主版本內）"
else
  echo "  主版本一致（${current%%.*}.x → $available）"
  sudo dnf upgrade --assumeno 2>&1 | grep -E "^Upgrade +[0-9]+ Package"
fi
EOF
done
```

```out
under-replicated：0
kc01：OS 9.6，套件庫的 release 套件 9.8；可更新 124 個（平台相關：glibc openssh-server openssl-libs rocky-release systemd）；其中 confluent-* 0 個；鎖住 9 個 confluent 套件
  主版本一致（9.x → 9.8）
Upgrade  124 Packages
（kb01、rest01、c3-01、ops02 同上，數字依各台裝的套件而不同；confluent-* 一律 0 個）
```

> 清單裡出現 `confluent-*` 就停下來：代表 versionlock 沒鎖好，照第 8 章重新鎖。Confluent 的升級只走第 29 章。每月修補時「套件庫的 release 套件」和目前的 OS 版本相同，可更新的數量就小得多（原本實測：6 個，含 openssh-server，修補過程中 ssh 連線不斷）。

> **主版本的保險**：上面每台都比對了「套件庫裡 release 套件的主版本」和「目前的主版本」。銀行的套件庫若同步錯了（content view 混到 RHEL 10 的內容、Nexus 指到 10 的上游），`dnf update` 會把 9.x 主機一路升到 10——那不是小版本更新，是大版本升級，Confluent 的支援矩陣、JDK、OS 調校全部要重來。看到 `停：套件庫是 10.x 的內容` 就不要動，請 OS 團隊修套件庫（問題清單 3.6）。lab 沒有 10 的內容，用唯一能連外網的 dl01 對 Rocky 10 的公開倉庫跑同一個判斷，證明它真的會停：

@role 小安 | dl01 | root

```bash
# 1. 目前的 OS 版本
current=$(. /etc/os-release; echo $VERSION_ID)

# 2. Rocky 10 公開倉庫裡 release 套件的版本
available=$(timeout 120 dnf -q repoquery \
  --repofrompath=r10,https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/ \
  --repo=r10 \
  --latest-limit 1 \
  --qf "%{version}" \
  rocky-release 2> /dev/null | head -1)
echo "目前 $current；那個套件庫的 release 套件 $available"

# 3. 同一個判斷：主版本不一致就停
if [ "${available%%.*}" != "${current%%.*}" ]; then
  echo "停：套件庫是 ${available%%.*}.x 的內容，不是 ${current%%.*}.x（小版本更新只能在同一主版本內）"
else
  echo "主版本一致"
fi
```

```out
目前 9.6；那個套件庫的 release 套件 10.2
停：套件庫是 10.x 的內容，不是 9.x（小版本更新只能在同一主版本內）
```

## 30.2 broker 逐台

@role 小安 | ops02 | root

每台：更新 → 看要不要重開機、哪些平台服務要重啟 → 照判斷做 → 等健康、沒有 under-replicated 才下一台：

> Rocky 的陷阱（lab 實測）：9.8 的 `rocky-repos` 更新後，預設的 repo 檔（`rocky.repo` 等，走外網 mirrorlist）被裝回來並啟用，之後每個 `dnf` 都先去連外網而報 `Failed to download metadata for repo 'baseos'`。所以更新完立刻把它們關掉（下面腳本的那一行）。銀行的 RHEL 沒有這個問題。

```bash
# 1. 一台主機的更新步驟（30.2–30.4 每台都用）
cat > ~/conf/os-patch-host.sh <<'EOF'
#!/usr/bin/env bash
# os-patch-host.sh — 在一台主機上做 OS 更新，判斷要不要重開機、哪些平台服務要重啟（本身不重開、不重啟）
# 在哪裡跑：各主機上以 cpuser 執行（用 sudo）：ssh <主機> bash -s < ~/conf/os-patch-host.sh；操作機上 root 直接 bash 它
# 做什麼：數可更新的套件 → dnf update（Confluent 由 versionlock 擋住）→ 關掉 Rocky 裝回來的預設 repo 檔 → needs-restarting 判斷
#   → 印一行，例：kb01 更新 124 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
# 結束碼：0 更新完；1 dnf update 失敗（訊息印在 stderr）
# 改的時候要注意：呼叫的一方看那一行的「要重開機：是」與服務名稱決定下一步

# 1. 更新前：可更新幾個、OS 版本
count=$(sudo dnf -q check-update --refresh 2> /dev/null | awk '/^[a-zA-Z0-9]/ {c++} END {print c + 0}')
os_before=$(. /etc/os-release; echo $VERSION_ID)

# 2. 更新
if ! sudo dnf -y -q update > /dev/null 2>&1; then
  echo "$(hostname) dnf update 失敗" >&2
  exit 1
fi

# 3. Rocky 專屬：rocky-repos 套件跟著更新，會把預設的 repo 檔（走外網 mirrorlist）裝回來並啟用，離線的 lab 要再關掉
#    RHEL 的 redhat.repo 由訂閱管理或 Satellite 管，不需要這行
sudo sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/rocky*.repo 2> /dev/null

# 4. 要不要重開機（needs-restarting -r：結束碼 0 = 不用）、哪些平台服務要重啟
if sudo dnf needs-restarting -r > /dev/null 2>&1; then
  reboot=否
else
  reboot=是
fi

# 要重啟的服務名稱（排序、去重複），再接成逗號分隔：例 confluent-server,prometheus
matched=$(sudo dnf needs-restarting -s 2> /dev/null | grep -oE 'confluent-[a-z-]+|prometheus|alertmanager' | sort -u)
services=$(echo "$matched" | paste -sd, -)

if [ -z "$services" ]; then
  services=無
fi

# 5. 一行結果
os_after=$(. /etc/os-release; echo "$VERSION_ID")
confluent_versions=$(rpm -qa 'confluent-*' --qf '%{VERSION}\n' | sort -u | paste -sd, -)

echo "$(hostname) 更新 $count 個；OS $os_before>$os_after；要重開機：$reboot；要重啟的平台服務：$services；confluent 版本：$confluent_versions"
EOF

# 2. 重開機（lab 的容器改成重啟平台服務）
cat > ~/conf/os-reboot.sh <<'EOF'
#!/usr/bin/env bash
# os-reboot.sh <主機> — 重開機並等 ssh 回來；主機是容器（lab）時 systemctl reboot 不能用，改重啟那台的平台服務
# 做什麼（容器）：只重啟 enabled 的 unit，和真的開機一樣：kc／kb 裝了 confluent-server 也會帶進 confluent-kafka-rest，
#   它是 disabled，不能被叫起來；C3 先重啟它內建的 Prometheus 與 Alertmanager
# 改的時候要注意：不等服務健康，由呼叫的一方等

host=$1

if ssh $host.poc.lab 'systemd-detect-virt -cq'; then
  echo "  $host 是容器，不能重開機：改重啟平台服務"

  # 在那台執行 REMOTE 之前的那一段
  ssh $host.poc.lab bash -s <<'REMOTE'
for u in confluent-server confluent-kafka-rest confluent-control-center; do
  if ! systemctl is-enabled -q $u 2> /dev/null; then
    continue
  fi

  if [ $u = confluent-control-center ]; then
    sudo systemctl restart prometheus alertmanager
  fi

  sudo systemctl restart $u
done
REMOTE
else
  ssh $host.poc.lab 'sudo systemctl reboot' 2> /dev/null
  sleep 20

  # 等它開回來：每 5 秒試一次 ssh，最多 60 次
  for i in $(seq 1 60); do
    if ssh -o ConnectTimeout=5 $host.poc.lab true 2> /dev/null; then
      break
    fi

    sleep 5
  done
fi
EOF

chmod 0700 ~/conf/os-patch-host.sh ~/conf/os-reboot.sh

export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
admin="--bootstrap-server kb01.poc.lab:9094,kb02.poc.lab:9094 --command-config $HOME/conf/client-admin.properties"

for h in kb01 kb02 kb03 kb04; do
  # 3. 更新這台，印出判斷
  result=$(ssh $h.poc.lab bash -s < ~/conf/os-patch-host.sh)
  echo "$result"

  # 4. 照判斷做：要重開機就重開（lab 的容器改重啟平台服務）；只有 confluent-server 要重啟就重啟它
  if echo "$result" | grep -q '要重開機：是'; then
    bash ~/conf/os-reboot.sh $h
  elif echo "$result" | grep -q 'confluent-server'; then
    ssh $h.poc.lab 'sudo systemctl restart confluent-server'
  fi

  # 5. 等 MDS 回 200、沒有 under-replicated：每 10 秒看一次，最多 60 次
  for i in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)" = 200 ]; then
      under=$(kafka-topics $admin --describe --under-replicated-partitions 2> /dev/null \
        | awk '/Partition:/ {c++} END {print c + 0}')

      if [ "$under" = 0 ]; then
        break
      fi
    fi

    sleep 10
  done

  echo "  $h MDS=$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://$h.poc.lab:8090/v1/metadata/id)"
done
```

```out
kb01 更新 124 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
  kb01 是容器，不能重開機：改重啟平台服務
  kb01 MDS=200
（4 台；正式環境沒有「是容器」那行，而是重開機後等 ssh 回來，每台多幾分鐘）
```

## 30.3 controller 逐台，leader 最後

@role 小安 | ops02 | root

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
controllers=kc01.poc.lab:9093,kc02.poc.lab:9093,kc03.poc.lab:9093
Q="--bootstrap-controller $controllers --command-config $HOME/conf/client-internal.properties"

# 1. 順序：另外兩台、leader 最後
leader=kc0$(kafka-metadata-quorum $Q describe --status 2> /dev/null | awk '/LeaderId/ {print $2}')
order=""

for c in kc01 kc02 kc03; do
  if [ $c != $leader ]; then
    order="$order $c"
  fi
done

order="$order $leader"

for h in $order; do
  # 2. 更新、照判斷做
  result=$(ssh $h.poc.lab bash -s < ~/conf/os-patch-host.sh)
  echo "$result"

  if echo "$result" | grep -q '要重開機：是'; then
    bash ~/conf/os-reboot.sh $h
  elif echo "$result" | grep -q 'confluent-server'; then
    ssh $h.poc.lab 'sudo systemctl restart confluent-server'
  fi

  # 3. 等這台的 Lag 回到 0：每 5 秒看一次，最多 60 次
  #    describe --replication 每台一行，kc01 的 NodeId 是 1：找開頭是這個 NodeId 的那一行，取第 4 欄
  id=${h#kc0}

  for i in $(seq 1 60); do
    lag=$(kafka-metadata-quorum $Q describe --replication 2> /dev/null \
      | grep -E "^[[:space:]]*$id[[:space:]]" | awk '{print $4}')

    if [ "$lag" = 0 ]; then
      break
    fi

    sleep 5
  done

  if [ $h = $leader ]; then
    note='（leader，最後做）'
  else
    note=""
  fi

  echo "  $h Lag=$lag$note"
done
```

```out
kc02 更新 124 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
  kc02 Lag=0
kc03 更新 124 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
  kc03 Lag=0
kc01 更新 124 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
  kc01 Lag=0（leader，最後做）
```

## 30.4 REST Proxy、C3、操作機

@role 小安 | ops02 | root

順序是 REST 一台做完再換下一台 → C3 → 操作機。每台都是「更新、照判斷重開或重啟、確認健康」做完整才換下一台；操作機排最後，因為它要重開機時，其他主機的工作都要先做完（這段指令就是在它上面跑的）。

先更新 rest01，結果存起來，下面重啟時看要不要 `-r`：

```bash
ssh rest01.poc.lab bash -s < ~/conf/os-patch-host.sh > ~/conf/patch-rest01.out
cat ~/conf/patch-rest01.out
```

```out
rest01 更新 124 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
```

套件更新不影響跑著的 JVM；重啟（或要重開機的話重開機）照 12.1 的步驟。小版本更新時一定是「要重開機：是」，下面三塊要做（`-r` 在 lab 的容器上自動改成重啟服務）；每月修補看到「要重開機：否、要重啟的平台服務：無」時，這台可以略過：

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 down
```

```out
LB：rest01（停用） rest02
```

@role 小安 | ops02 | root

```bash
# 剛才存下的結果是「要重開機：是」就加 -r（lab 的容器上 rest-restart.sh 會自己改成重啟服務）
if grep -q '要重開機：是' ~/conf/patch-rest01.out; then
  ~/conf/rest-restart.sh rest01 -r
else
  ~/conf/rest-restart.sh rest01
fi
```

```out
rest01：排空等了 0 秒，重啟後 REST 200（約 10 秒）
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest01 up
```

```out
LB：rest01 rest02
```

@role 小安 | ops02 | root

換 rest02，一樣先更新：

```bash
ssh rest02.poc.lab bash -s < ~/conf/os-patch-host.sh > ~/conf/patch-rest02.out
cat ~/conf/patch-rest02.out
```

```out
rest02 更新 124 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
```

@role 銀行 網路團隊（LB；lab 由 Lab 管理員扮演） | Windows 終端 | 本機

```bash
bash ~/kafka-lab/lb-member.sh rest02 down
```

```out
LB：rest01 rest02（停用）
```

@role 小安 | ops02 | root

```bash
if grep -q '要重開機：是' ~/conf/patch-rest02.out; then
  ~/conf/rest-restart.sh rest02 -r
else
  ~/conf/rest-restart.sh rest02
fi
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

接著是 C3（只有一台，修補期間畫面短暫不能用），操作機最後、自己修自己：

```bash
# 1. C3：更新、照判斷做（要重開機就重開；C3 的服務要重啟就三個依序重啟）
result=$(ssh c3-01.poc.lab bash -s < ~/conf/os-patch-host.sh)
echo "$result"

if echo "$result" | grep -q '要重開機：是'; then
  bash ~/conf/os-reboot.sh c3-01
elif echo "$result" | grep -qE 'confluent-control-center|prometheus|alertmanager'; then
  for u in prometheus alertmanager confluent-control-center; do
    ssh c3-01.poc.lab "sudo systemctl restart $u"
  done
fi

# 2. 等 C3 畫面 200：每 5 秒看一次，最多 60 次；再看 REST 經 LB 與 C3
for i in $(seq 1 60); do
  if [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://c3-01.poc.lab:9021/)" = 200 ]; then
    break
  fi

  sleep 5
done

echo "  REST 經 LB=$(curl -s \
  --cert ~/pki/certs/app-legacy-billing.crt \
  --key ~/pki/keys/app-legacy-billing.key \
  -o /dev/null -w '%{http_code}' \
  https://rest.poc.lab:8082/v3/clusters) C3=$(curl -s -o /dev/null -m 5 -w '%{http_code}' https://c3-01.poc.lab:9021/)"

# 3. 操作機最後、自己修自己（root 直接跑）；要重開機的話，等這一節和驗收都做完再重開
bash ~/conf/os-patch-host.sh
```

```out
c3-01 更新 126 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：2.6.1
  REST 經 LB=200 C3=200
ops02 更新 120 個；OS 9.6>9.8；要重開機：是；要重啟的平台服務：無；confluent 版本：8.3.2
```

> 每月修補的實測（2026-10-25，同一小版本內，lab）：11 台各 6 個 OS 套件（含 openssh-server，修補過程中 ssh 連線不斷），Confluent 版本都沒變、不用重開機、沒有平台服務要重啟；之後第 19 章驗收全過。openssh-server 更新後 sshd 由 RPM 自己重啟，所以 `-s` 雖然會列 sshd，這裡只看平台服務。

最後照第 19 章驗收一次（19.1–19.3）。

## 30.5 小版本更新（9.6 → 9.8）：驗證、限制、回滾、換成別的小版本

@role 小安 | ops02 | root

30.0–30.4 已經把每台更新完了。這一節是小版本更新特有的收尾。**開始前的前提**（30.0、30.1 已經確認）：銀行的套件庫有 9.8 的內容；Confluent 的 versionlock 數量等於已裝的 confluent 套件數、更新清單裡沒有 `confluent-*`；JDK 是 tar，`dnf` 碰不到。

**驗證**：每台的 OS 版本是 9.8、versionlock 數量沒變、服務是 active；叢集沒有 under-replicated；REST 經 LB 與 C3 都回 200：

```bash
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml

# 1. 每台：OS 名稱、versionlock 鎖了幾個／裝了幾個 confluent 套件、啟用中（或執行中）的 Confluent 服務（每台執行 EOF 之前的那一段）
for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh $h.poc.lab bash -s <<'EOF'
. /etc/os-release
states=""

for u in confluent-server confluent-kafka-rest confluent-control-center; do
  if systemctl is-enabled -q $u 2> /dev/null; then
    states="$states $u=$(systemctl is-active $u)"
  elif systemctl is-active -q $u 2> /dev/null; then
    states="$states $u=$(systemctl is-active $u)"
  fi
done

locked=$(sudo dnf -q versionlock list | grep -c confluent)
installed=$(rpm -qa "confluent-*" | wc -l)
echo "$(hostname) $PRETTY_NAME 鎖 $locked／裝 $installed$states"
EOF
done

# 2. 操作機
echo "ops02 $(. /etc/os-release; echo $PRETTY_NAME)"

# 3. 叢集：沒有 under-replicated；REST 經 LB 與 C3 都回 200
echo "under-replicated：$(kafka-topics \
  --bootstrap-server kb01.poc.lab:9094 \
  --command-config ~/conf/client-admin.properties \
  --describe --under-replicated-partitions 2> /dev/null \
  | awk '/Partition:/ {c++} END {print c + 0}')；REST 經 LB=$(curl -s \
  --cert ~/pki/certs/app-legacy-billing.crt \
  --key ~/pki/keys/app-legacy-billing.key \
  -o /dev/null -w '%{http_code}' \
  https://rest.poc.lab:8082/v3/clusters) C3=$(curl -s -o /dev/null -w '%{http_code}' https://c3-01.poc.lab:9021/)"
```

```out
kc01 Rocky Linux 9.8 (Blue Onyx) 鎖 9／裝 9 confluent-server=active
（kc02、kc03、kb01–kb04 同上；rest01、rest02 是「鎖 4／裝 4 confluent-kafka-rest=active」；c3-01 是「鎖 1／裝 1 confluent-control-center=active」）
ops02 Rocky Linux 9.8 (Blue Onyx)
under-replicated：0；REST 經 LB=200 C3=200
```

再跑一次第 19 章的驗收（19.1–19.3），結果要全數通過。持續流量（直連應用程式的背景寫入、經 LB 的 REST 呼叫）在更新期間的數字（lab，2026-11-09 從零重跑，約 15 分鐘）：直連應用程式送出 3,261 筆、讀回 3,261 筆，遺失 0；經 LB 的 REST 605 次，失敗 0 次（REST 照 12.1 一台一台從 LB 停用再重啟）。

**lab 做不到的事（要老實說）**：
- 容器不能重開機，kernel 沒有更新（容器沒有自己的核心）。lab 只驗證「套件更新的指令、順序、versionlock 擋住 Confluent、服務在新的 glibc／systemd 套件下重啟後是健康的」，**沒有驗證**重開機本身：開機順序、`fstab` 掛載、網卡命名、核心模組、`systemctl enable` 過的服務是否自己起來（19.4 的冷開機演練只涵蓋「容器一起停、一起開」，不是 OS 的開機）。
- Rocky 不是 RHEL：套件名稱、`needs-restarting` 的輸出與 RHEL 相同，但訂閱管理（`subscription-manager release --set`）、Satellite content view 的行為 lab 都沒有。
- 更新集合的大小（30.0 印出的 RPM 數與 MB）是這批最小安裝主機的數字，真正的 RHEL 主機不同。

**回滾**：真正可行的答案是**更新前的快照**（VM 快照、LVM 快照或裸機映像），在 30.1 之前每台先做；小版本更新途中某台出問題，就還原那一台的快照，再照 30.2–30.4 重做。不要依賴 `dnf history undo`：它對 kernel、glibc、systemd 這類核心元件不可靠，而且 Red Hat 不支援把 RHEL 小版本降回去（`dnf downgrade` 整個小版本也一樣）。controller 或 broker 的機器整台壞了，走 25.1 節（換 controller）或 25.2 節（broker 加回）重建，不要硬救。Confluent 這一側不用回滾：版本沒動。

**換成別的小版本（例如銀行的套件庫是 9.4 → 9.6、9.2 → 9.4）**：步驟完全一樣，只要換三個值：(1) 30.0 銀行同步的目標版本；(2) 30.1 檢查「套件庫的 release 套件」是不是你要的那一版——**套件庫如果不是釘在特定小版本（例如直接追 RHEL 9 最新），`dnf update` 會一路更新到它有的最新小版本**，不是你以為的那一版，要請銀行把套件庫（或主機的 releasever）釘住；(3) 查原廠的 OS 支援表，確認該小版本在 Confluent Platform 8.3 的支援範圍內（原廠表上 RHEL 9.x 為支援；以銀行實際的版本對表）。`install/` 的對應是 `steps/30-os-patch.sh plan｜apply｜verify <版本>`，預設的 OS 版本在 `conf/site.env` 的 `OS_BASE_VERSION`、`OS_TARGET_VERSION`。

# 31. 第三十一站：單獨更換 Control Center 版本

**這一章在做什麼**：只換 C3 的版本，不動 Confluent Platform。前提：C3 已依第 13、29.3 裝好。順序：下載驗簽（31.1）→ 送進內網上架（31.2）→ 回滾程序演練（31.3，lab 專用）→ 升級（31.4）。

Control Center（Next Gen）有自己的版號（2.x），改版比 Confluent Platform 頻繁，可以單獨更換。遷移主線裡 C3 已經在 29.3 從 2.5.1 升到 2.6.1（那是 CP 升 8.3 的前提）；這一章是**之後**的情況：C3 出新的 2.6.x 修補版、或原廠要求換版本時，單獨處理，不動 CP。和第 29 章不同的地方：

| 項目 | 說明 |
|---|---|
| 相容性 | 先查原廠的相容表：新版 C3 要支援目前的 CP 版本（2.6.x：CP 7.5.15 到 8.3.x；2.5.x 只到 8.2.x，所以**不能**把已經是 8.3 的叢集的 C3 退回 2.5.x）。CP 要升級時，**C3 先升**（29.3） |
| 停機 | 只有一台：升級期間畫面約 1–2 分鐘不能用；broker、REST、應用程式不受影響（C3 只是看） |
| 資料 | 內建 Prometheus 的歷史指標在 C3 的資料目錄，換套件不會清掉 |
| JDK | 和其他節點一樣是 JDK 25（29.7）。原廠對 Control Center 只寫「最低 Java 17」，沒有明列 25，上線前向原廠支援確認 |
| 回滾 | `dnf downgrade` 回舊版（舊版的 RPM 一直留在套件庫，第 6 章） |

lab 裡：已經是原廠最新的 2.6.1（29.3 升好的），所以演練是：先把 2.6.0 帶進來、退回 2.6.0（同時驗證回滾；2.6.0 也在 CP 8.3 的支援範圍內），再照正式程序升回 2.6.1。正式環境只要把版號換成新版、跳過 31.3。

## 31.1 下載、驗簽章

@role 小安 | dl01 | root

和第 2 章一樣指定精確版本；C3 的 RPM **沒有宣告任何真實的相依**（實測 `rpm -qpR` 只有 `/bin/sh`、`bash` 和自己的設定），所以 `dnf` 不會替它檢查或帶入什麼，`--resolve` 也沒有東西可解。原廠文件要求的前置套件 `cyrus-sasl`、`openssl-devel` 來自銀行的 OS 套件庫、在 7.3 節已經裝好，是否還在要自己檢查（31.2 最後一步）。下載改成「`dnf` 只印出網址、`curl` 下載」：實測 `dnf download` 把這個約 1 GB 的 RPM 下載完整之後，行程常常不會結束（連線卡住）；`curl` 沒有這個問題。下載完用 `rpm -K` 驗簽章：

```bash
V=2.6.0
rpm=confluent-control-center-next-gen-$V-1.noarch.rpm

mkdir -p /out/c3
cd /out/c3

# 1. 已經下載過、檔案沒壞就沿用（約 1 GB，不重抓）：這個版本的 RPM 在這裡、而且 SHA256SUMS 對得上
have_copy=no

if [ -f $rpm ]; then
  if grep -q " ./$rpm\$" SHA256SUMS 2> /dev/null; then
    if sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1; then
      have_copy=yes
    fi
  fi
fi

# 否則清掉舊檔，dnf 只給下載網址、curl 下載
if [ $have_copy = yes ]; then
  echo "已經有 $rpm，sha256 對得上，不重新下載"
else
  rm -f ./*.rpm SHA256SUMS
  curl -fsS -O "$(dnf -q download --url confluent-control-center-next-gen-$V | head -1)"
  sha256sum ./*.rpm > SHA256SUMS
fi

# 2. 不管是不是沿用，簽章都驗一次
rpm -K ./*.rpm
ls
```

```out
已經有 confluent-control-center-next-gen-2.6.0-1.noarch.rpm，sha256 對得上，不重新下載
./confluent-control-center-next-gen-2.6.0-1.noarch.rpm: digests signatures OK
SHA256SUMS
confluent-control-center-next-gen-2.6.0-1.noarch.rpm
（第一次做時沒有「已經有」那一行，而是下載約 1 GB）
```

## 31.2 引進、上架

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

照 3.4 的方式送到操作機的落地區（唯讀），進來後再驗一次 sha256：

```bash
# 1. 送進操作機的落地區
podman cp "$(cygpath -m "$HOME/kafka-lab/landing/c3")" lab-ops02-1:/root/landing/

# 2. 在操作機上設成唯讀、核對 sha256（執行 EOF 之前的那一段）
podman exec -i lab-ops02-1 bash -e -s <<'EOF'
chmod -R a-w /root/landing/c3
cd /root/landing/c3
sha256sum -c --quiet SHA256SUMS
echo sha256-ok
EOF
```

```out
sha256-ok
```

@role 小安 | ops02 | root

先確認新版 RPM 有沒有新增相依，以及 c3-01 上原廠要求的前置套件都在（RPM 不宣告相依，`dnf` 不會替你查）：

```bash
cd ~/landing/c3

# 1. RPM 宣告的相依（不含 rpmlib 與檔案路徑）
deps=$(rpm -qpR confluent-control-center-next-gen-*.rpm | grep -vE '^(rpmlib|/)' | sort -u)
echo "RPM 宣告的相依：$(echo "$deps" | paste -sd';' -)"

# 2. c3-01 上已經裝了這兩個
ssh c3-01.poc.lab 'rpm -q cyrus-sasl openssl-devel'
```

```out
RPM 宣告的相依：config(confluent-control-center-next-gen) = 2.6.0-1
cyrus-sasl-2.1.27-22.el9_7.x86_64
openssl-devel-3.5.8-2.el9_8.x86_64
```

> 如果「RPM 宣告的相依」多出別的套件，或兩個前置套件有一個顯示 `is not installed`，先請銀行 OS 團隊把它放進套件庫並安裝，再往下做。

@role 小安 | ops02 | root

加進內部套件庫（舊版不刪，回滾要用），只推 `confluent/` 這個目錄：

```bash
# 1. 加進內部套件庫的 confluent/、更新索引
cp ~/landing/c3/*.rpm ~/repo/confluent/
createrepo_c -q --update ~/repo/confluent

# 2. 只推 confluent/ 這個目錄到 repo01
tar -C ~/repo -cf - confluent | ssh repodeploy@repo01.poc.lab 'tar -C /var/www/repo -xpf -'

# 3. 從 c3-01 看套件庫裡有哪些 C3 版本（--refresh：剛推上去；執行 EOF 之前的那一段）
ssh c3-01.poc.lab bash -s <<'EOF'
list=$(sudo dnf -q --refresh --showduplicates list confluent-control-center-next-gen 2> /dev/null)
versions=$(echo "$list" | awk '/control-center/ {print $2}' | sort -u)
echo "套件庫裡的 C3：$(echo "$versions" | paste -sd' ' -)"
EOF
```

```out
套件庫裡的 C3：2.5.1-1 2.6.0-1 2.6.1-1
```

## 31.3 （lab 演練用）退回 2.6.0：也就是回滾程序

@role 小安 | ops02 | root

步驟都在 29.3 建好的 `~/conf/c3-change.sh`（解鎖 → 換版本 → 鎖回 → `daemon-reload` → 4 個 generated 檔擁有者改回 `cp-control-center` → 確認設定檔沒被動 → 重啟 Prometheus、Alertmanager、C3 → 等畫面 200）。升級與回滾是同一段，只差 `dnf install` 或 `dnf downgrade`。腳本還沒有的話（單獨跑這一章時）先照 29.3 建：

```bash
# 腳本要先有（29.3 建的）
if [ ! -x ~/conf/c3-change.sh ]; then
  echo "沒有 ~/conf/c3-change.sh：先照 29.3 建"
  false
fi

bash ~/conf/c3-change.sh 2.6.0 downgrade
```

```out
confluent-control-center-next-gen-2.6.0-1.noarch config=same exec=/etc/confluent/control-center/control-center.properties lock=confluent-control-center-next-gen-0:2.6.0-1.*
UI=200（約 30 秒）；Prometheus 指標 125 種
```

## 31.4 升級到新版

@role 小安 | ops02 | root

```bash
# 1. 升到 2.6.1
bash ~/conf/c3-change.sh 2.6.1 install

# 2. C3 自己寫的 4 個檔，擁有者都是 cp-control-center
files="alertmanager-generated.yml trigger_rules-generated.yml"
files="$files recording_rules-generated.yml prometheus-generated-local.yml"
owners=$(ssh c3-01.poc.lab "cd /etc/confluent-control-center; sudo stat -c %U $files" | sort -u | paste -sd, -)
echo "C3 自己寫的 4 個檔：$owners"

# 3. alice 真的從 C3 登入（首頁不經過 MDS，只看 200 抓不到；C3 起來後健康檢查還要一點時間，最多等 60 秒）
alice_pass=$(cat ~/secrets/ad-test-users.pass)
login_url=https://c3-01.poc.lab:9021/api/metadata/security/1.0/authenticate

for i in $(seq 1 12); do
  if [ "$(curl -s -u "alice:$alice_pass" -o /dev/null -m 30 -w '%{http_code}' "$login_url")" = 200 ]; then
    break
  fi

  sleep 5
done

echo "alice 從 C3 登入：$(curl -s -u "alice:$alice_pass" -o /dev/null -m 30 -w '%{http_code}' "$login_url")"
```

```out
confluent-control-center-next-gen-2.6.1-1.noarch config=same exec=/etc/confluent/control-center/control-center.properties lock=confluent-control-center-next-gen-0:2.6.1-1.*
UI=200（約 35 秒）；Prometheus 指標 125 種（歷史指標沒有因換版本而消失）
C3 自己寫的 4 個檔：cp-control-center
alice 從 C3 登入：200
```

> 陷阱（lab 實測）：RPM 換版本（升級或退回）會把 `trigger_rules-generated.yml`、`recording_rules-generated.yml`、`prometheus-generated-local.yml` 改回 `root:root 644`（還有 `alertmanager-generated.yml`）。畫面照樣打得開，但之後在 C3 上改告警規則會寫不進去，所以 `c3-change.sh` 換完套件一定把這 4 個檔改回 `cp-control-center`（`prometheus-generated.yml` 是我們寫的，維持 root）。

最後用瀏覽器登入 C3 看一眼叢集總覽（lab：`https://localhost:19021`，alice）。

# 32. 第三十二站：銀行沒有 Prometheus 時的告警

![c3alert]

**這一章在做什麼**：銀行不一定提供 Prometheus、Alertmanager（第 17 章的前提）。沒有的話，告警改走 C3 內建的 Prometheus：它照第 17 章的方式抓 10 台的 7071（JMX exporter），套用**第 17 章同一份規則**（26 條），再由我們自己的第二個 Alertmanager 用行內規定的 JSON 格式送給 omnibus。前提：C3 已經是 2.6.1（29.3），第 17 章的 JMX exporter 與 17.5 的規則檔已經做好。完成的樣子：C3 的 Prometheus 抓得到 10 台；我們的規則只送第二個 Alertmanager；C3 畫面建的 trigger 只送 C3 內建的 Alertmanager；停一台 broker、一台 controller，omnibus 收到 OPEN 與 RESOLVED，每個欄位都是字串。

| 來源 | 規則在哪 | 帶的 label | 送到哪 | 通知格式 |
|---|---|---|---|---|
| 我們的規則（第 17 章那份） | `custom-rules-confluent.yml`（root，C3 改不動） | `target: omnibus`（規則群組層級統一加） | 第二個 Alertmanager（127.0.0.1:9193） | 行內 omnibus JSON |
| C3 畫面的 trigger | `trigger_rules-generated.yml`（C3 自己寫） | `rule_created_by`，沒有 `target` | C3 內建 Alertmanager（9093） | C3 的 action（Alertmanager 預設格式） |

**為什麼抓 JMX exporter，不用 C3 已經收到的 telemetry**（lab 實測）：telemetry 只帶 node id、沒有主機名稱；controller 幾乎沒有指標（raft 指標沒帶 node id，多台互撞被拒收）；REST Proxy 不送 telemetry；指標名稱（`io_confluent_…`）和官方規則（`kafka_…`）不同；C3 2.6.1 的 trigger 查詢裡也沒有 CPU 與磁碟。JMX exporter 第 17 章已經裝在 10 台上，job 名稱與 `env`、`hostname` 標籤照第 17 章，規則就能原封不動套用；兩邊的指標名稱不同，不會互相干擾 C3 畫面。telemetry 照舊給 C3 畫面用。

**只留需要的指標**：一台 broker 的 exporter 約 1.4 萬條序列，全收會壓到 C3 自己的 Prometheus。每個 job 用 `metric_relabel_configs` 只保留規則用得到的指標（lab：10 台合計約 1,000 條；C3 本身約 12 萬條）。以後規則用到新的指標，要把名稱加進對應 job 的清單，不然那條規則永遠沒有資料（不會有錯誤訊息）。

**分流怎麼做**：Prometheus 的 `alerting.alertmanagers` 每一台可以有自己的 `alert_relabel_configs`。內建那台 `drop` 掉 `target=omnibus`，第二台只 `keep` `target=omnibus`。這是白名單：沒有這個 label 的告警不會送到 omnibus，所以之後有人在 C3 畫面建 trigger 也不會誤發。**忘了加 label 的規則不會有錯誤訊息，只是不會通知**，所以由每個規則群組的 `labels` 統一加上。

> 版本前提（lab 實測）：第二個 Alertmanager 用 C3 2.6.1 內附的執行檔（0.34.0）。C3 2.5.1 內附的 0.32.2 會把 `payload` 算好的字串再當 YAML 解析一次：`a: b` 變物件、`123` 變數字、`true` 變布林、`007` 變 `7`，不符合行內格式，所以**基底的 2.5.1 階段不要開這個方案**，也不要在做完這一章之後把 C3 退回 2.5.x。

> 原廠支援：原廠文件寫 C3 不支援客戶自管的 Prometheus、Alertmanager，也要求不要手動啟動內建的程序。這一章另外開一個程序、讓內建 Prometheus 多抓 10 台，上線前要問原廠。`origin`、`hostname` 的填法也還要銀行確認（請銀行確認事項 11.11）。防火牆：第 17 章 7071 只開給銀行的 Prometheus，這一章要請銀行網路團隊改開給 c3-01。

> 單點：發告警的 Prometheus 和第二個 Alertmanager 都在 c3-01，c3-01 整台掛掉時所有告警都發不出來。請銀行的主機監控或 omnibus 端偵測 c3-01 是否還活著。

## 32.1 確認前提

@role 小安 | ops02 | root

```bash
ssh c3-01.poc.lab bash -s <<'EOF'
echo "C3：$(rpm -q confluent-control-center-next-gen)"
am=/usr/libexec/confluent-control-center/linux_amd64/alertmanager/alertmanager-amd64
$am --version 2>&1 | head -1 | cut -d'(' -f1
EOF
```

```out
C3：confluent-control-center-next-gen-2.6.1-1.noarch
alertmanager, version 0.34.0 
```

## 32.2 第二個 Alertmanager

@role 小安 | ops02 | root

設定檔、資料目錄、服務都是獨立的，C3 不會碰。只聽 127.0.0.1，叢集功能關掉（C3 內建的那台已經佔了 9094）。`group_by: ['...']` 讓每筆告警自成一個通知，一個 POST 一筆，符合行內的扁平格式。`toJson` 負責跳脫雙引號與換行。`hostname`：主機層的告警（帶 `hostname` 標籤）填主機名；整個叢集的告警（例如 under-replicated、fenced broker，只有 `env`）填環境名稱。

lab 的接收端是 `lab-mon-webhook`（17.6）；正式環境換成銀行給的 omnibus 位址。

```bash
# 在 c3-01 執行 EOF 之前的那一段（bash -e：任何一行失敗就停）
ssh c3-01.poc.lab bash -e -s <<'EOF'
sudo install -d -o root -g confluent -m 0750 /etc/confluent/alertmanager-custom
sudo install -d -o cp-control-center -g confluent -m 0750 /var/lib/alertmanager-custom

# 1. 設定檔：只有一個 receiver，所有收到的告警都送 omnibus
sudo tee /etc/confluent/alertmanager-custom/alertmanager.yml > /dev/null <<'AM'
global:
  resolve_timeout: 5m
route:
  receiver: omnibus
  group_by: ['...']
  group_wait: 5s
  group_interval: 1m
  repeat_interval: 4h
receivers:
  - name: omnibus
    webhook_configs:
      - url: http://lab-mon-webhook:8080/c3-omnibus
        send_resolved: true
        payload: >-
          {"source": "TCB_DYNATRACE",
          "ClassName": "TCB_DYNATRACE_STATUS",
          "msg_catalog": {{ .CommonLabels.impact | toJson }},
          "msg": {{ .CommonAnnotations.description | toJson }},
          "state": "{{ if eq .Status "firing" }}OPEN{{ else }}RESOLVED{{ end }}",
          "severity": "{{ if eq .CommonLabels.severity "critical" }}ERROR{{ else }}PERFORMANCE{{ end }}",
          "sub_origin": {{ printf "%s: %s" .CommonLabels.alertname .CommonAnnotations.summary | toJson }},
          "origin": "c3-embedded",
          "hostname": {{ if .CommonLabels.hostname }}{{ .CommonLabels.hostname | toJson }}
          {{ else }}{{ .CommonLabels.env | toJson }}{{ end }},
          "sub_source": "PIB"}
AM
sudo chown root:confluent /etc/confluent/alertmanager-custom/alertmanager.yml
sudo chmod 0640 /etc/confluent/alertmanager-custom/alertmanager.yml

# 2. systemd 服務：用 C3 內附的執行檔（C3 升級時跟著換版本）
sudo tee /etc/systemd/system/alertmanager-custom.service > /dev/null <<'UNIT'
[Unit]
Description=Second Alertmanager (custom JSON webhook), fed by the Control Center embedded Prometheus
After=network-online.target
[Service]
User=cp-control-center
Group=confluent
ExecStart=/usr/libexec/confluent-control-center/linux_amd64/alertmanager/alertmanager-amd64 \
  --config.file=/etc/confluent/alertmanager-custom/alertmanager.yml \
  --storage.path=/var/lib/alertmanager-custom \
  --web.listen-address=127.0.0.1:9193 \
  --cluster.listen-address=
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now alertmanager-custom > /dev/null 2>&1
sleep 3

echo "alertmanager-custom $(systemctl is-active alertmanager-custom)，版本 $(curl -s -m 5 \
  127.0.0.1:9193/api/v2/status | grep -o '"version":"[^"]*"')"
EOF
```

```out
alertmanager-custom active，版本 "version":"0.34.0"
```

## 32.3 Prometheus：抓 10 台、放規則、分流

@role 小安 | ops02 | root

先把第 17 章的規則檔（17.5 產生的 `confluent-alerts.yml`）複製一份，每個規則群組加上 `target: omnibus`，放到 c3-01。規則只在第 17 章維護；改了規則就重做這一塊：

```bash
# 1. 每個群組的 name 那一行後面加兩行（sed 的 a：在那一行之後加一行）：labels: 和 target: omnibus
install -d ~/monitoring/c3-path
rules_17=~/monitoring/to-bank/prometheus/confluent-alerts.yml
rules_c3=~/monitoring/c3-path/custom-rules-confluent.yml
sed -e '/^  - name: /a\    labels:' -e '/^  - name: /a\      target: omnibus' $rules_17 > $rules_c3

# 2. 三個數字要對得上：群組數、帶 target 的群組數，以及規則數（和 17.5 一樣）
groups=$(grep -c '^  - name:' $rules_c3)
targets=$(grep -c 'target: omnibus' $rules_c3)
rules=$(grep -c '^      - alert:' $rules_c3)
echo "群組 $groups，帶 target $targets，規則 $rules"

# 3. 放到 c3-01（root 擁有，C3 只能讀）
dest=/etc/confluent-control-center/custom-rules-confluent.yml
scp -q $rules_c3 c3-01.poc.lab:/tmp/custom-rules-confluent.yml
ssh c3-01.poc.lab sudo install -o root -g confluent -m 0640 /tmp/custom-rules-confluent.yml $dest
ssh c3-01.poc.lab rm /tmp/custom-rules-confluent.yml
```

```out
群組 7，帶 target 7，規則 26
```

再寫 Prometheus 設定。`prometheus-generated.yml` 是第 13 章我們自己寫的（root，C3 只能讀，**C3 不會改它**），RPM 從 2.5.1 升到 2.6.1 也沒有動它（lab 實測雜湊不變）。這裡比第 13 章多：兩台 Alertmanager 的分流、4 個抓取 job（名稱、`env`、`hostname` 照 17.5 的 `scrape-confluent.yml`；`env` 用同一個環境名）、我們的規則檔。每個 job 的 `metric_relabel_configs`：一類指標一段，符合的打上暫時的標記 `__tmp_keep`，最後只留有標記的，再把標記拿掉：

```bash
# 在 c3-01 執行 EOF 之前的那一段（bash -e：任何一行失敗就停）
ssh c3-01.poc.lab bash -e -s <<'EOF'
cd /etc/confluent-control-center

# 1. Prometheus 設定
sudo tee prometheus-generated.yml > /dev/null <<'PROM'
global:
  scrape_interval: 60s
  evaluation_interval: 60s
alerting:
  alertmanagers:
    - scheme: https
      tls_config:
        ca_file: /etc/confluent/ssl/ca.pem
        cert_file: /etc/confluent/ssl/svc-c3.crt
        key_file: /etc/confluent/ssl/svc-c3.key
      static_configs:
        - targets:
            - c3-01.poc.lab:9093
      alert_relabel_configs:
        - source_labels: [target]
          regex: omnibus
          action: drop
    - scheme: http
      static_configs:
        - targets:
            - 127.0.0.1:9193
      alert_relabel_configs:
        - source_labels: [target]
          regex: omnibus
          action: keep
rule_files:
  - "recording_rules-generated.yml"
  - "trigger_rules-generated.yml"
  - "custom-rules-confluent.yml"
scrape_configs:
  - job_name: kafka-controller
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config:
      ca_file: /etc/confluent/ssl/ca.pem
    static_configs:
      - targets: ["kc01.poc.lab:7071", "kc02.poc.lab:7071", "kc03.poc.lab:7071"]
        labels: { env: lab }
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+)(:[0-9]+)?'
        target_label: hostname
        replacement: '$1'
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'kafka_controller_kafkacontroller_(activecontrollercount|offlinepartitionscount|fencedbrokercount)'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_controller_kafkacontroller_(lastappliedrecordlagms|metadataerrorcount|newactivecontrollerscount)'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_controller_controllerstats_uncleanleaderelectionspersec'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_server_kafkaserver_linux_system_cpu_utilization_1m'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'jvm_memory_(used|max)_bytes|jvm_threads_deadlocked|process_(open|max)_fds'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__tmp_keep]
        regex: 'yes'
        action: keep
      - regex: __tmp_keep
        action: labeldrop
  - job_name: kafka-broker
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config:
      ca_file: /etc/confluent/ssl/ca.pem
    static_configs:
      - targets: ["kb01.poc.lab:7071", "kb02.poc.lab:7071", "kb03.poc.lab:7071", "kb04.poc.lab:7071"]
        labels: { env: lab }
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+)(:[0-9]+)?'
        target_label: hostname
        replacement: '$1'
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'kafka_server_replicamanager_(underreplicatedpartitions|isrshrinkspersec|isrexpandspersec)'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_cluster_partition_underminisr|kafka_log_logmanager_logdirectoryoffline'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent_oneminuterate'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_network_socketserver_networkprocessoravgidlepercent'
        target_label: __tmp_keep
        replacement: 'yes'
      # Produce 的延遲與請求數：只留 request="Produce"（其他請求種類丟掉）
      - source_labels: [__name__, request]
        regex: 'kafka_network_requestmetrics_(totaltimems|requestspersec);Produce'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_server_kafkaserver_linux_system_cpu_utilization_1m'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'jvm_memory_(used|max)_bytes|jvm_threads_deadlocked|process_(open|max)_fds'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__tmp_keep]
        regex: 'yes'
        action: keep
      - regex: __tmp_keep
        action: labeldrop
  - job_name: rest-proxy
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config:
      ca_file: /etc/confluent/ssl/ca.pem
    static_configs:
      - targets: ["rest01.poc.lab:7071", "rest02.poc.lab:7071"]
        labels: { env: lab }
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+)(:[0-9]+)?'
        target_label: hostname
        replacement: '$1'
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'kafka_rest_jersey_metrics_.*_request_error_rate|kafka_rest_jetty_metrics_thread_pool_usage'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'jvm_memory_(used|max)_bytes|jvm_threads_deadlocked|process_(open|max)_fds'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__tmp_keep]
        regex: 'yes'
        action: keep
      - regex: __tmp_keep
        action: labeldrop
  - job_name: control-center
    scheme: https
    scrape_interval: 30s
    scrape_timeout: 25s
    tls_config:
      ca_file: /etc/confluent/ssl/ca.pem
    static_configs:
      - targets: ["c3-01.poc.lab:7071"]
        labels: { env: lab }
    relabel_configs:
      - source_labels: [__address__]
        regex: '([^:]+)(:[0-9]+)?'
        target_label: hostname
        replacement: '$1'
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'kafka_streams_stream_metrics_(client_state|failed_stream_threads)'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_streams_stream_thread_metrics_poll_rate'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_streams_stream_state_metrics_background_errors'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'kafka_streams_stream_task_metrics_dropped_records_rate'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__name__]
        regex: 'jvm_memory_(used|max)_bytes|jvm_threads_deadlocked|process_(open|max)_fds'
        target_label: __tmp_keep
        replacement: 'yes'
      - source_labels: [__tmp_keep]
        regex: 'yes'
        action: keep
      - regex: __tmp_keep
        action: labeldrop
otlp:
  promote_resource_attributes:
    - "host.hostname"
    - "java.version"
    - "kafka.broker.id"
    - "kafka.cluster.id"
    - "kafka.version"
    - "type"
storage:
  tsdb:
    out_of_order_time_window: 10m
PROM

sudo chown root:confluent prometheus-generated.yml
sudo chmod 0640 prometheus-generated.yml

# 2. 重啟 Prometheus（C3 會自己重連）
sudo systemctl restart prometheus
echo "prometheus $(systemctl is-active prometheus)"
EOF
```

```out
prometheus active
```

確認 10 台都抓到、每個 job 留下的序列數、規則全部載入、連著兩台 Alertmanager（C3 內建的 Prometheus 要求 client 憑證，從操作機用 svc-ops 的）。剛載入的規則 health 是 unknown，要等過一次 evaluation（60 秒）才變 ok：

```bash
prom=https://c3-01.poc.lab:9090/api/v1
jobs='job=~"kafka-controller|kafka-broker|rest-proxy|control-center"'

# 1. 等 10 台都抓到（抓取間隔 30 秒，最多等 3 分鐘）：回應裡有 "value":[時間,"10"]，取出引號裡的數字
for i in $(seq 1 18); do
  up=$(curl -s -m 10 --cert ~/pki/certs/svc-ops.crt --key ~/pki/keys/svc-ops.key \
    -G $prom/query --data-urlencode "query=count(up{$jobs} == 1)" \
    | grep -o '"value":\[[^]]*\]' | cut -d'"' -f4)

  if [ "$up" = 10 ]; then
    break
  fi

  sleep 10
done

echo "抓到 $up / 10 台"

# 2. 每個 job 留下幾條序列：回應裡的 "job":"x"},"value":[時間,"n"] 印成「x n」
series=$(curl -s -m 10 --cert ~/pki/certs/svc-ops.crt --key ~/pki/keys/svc-ops.key \
  -G $prom/query --data-urlencode "query=count by (job) ({$jobs})" \
  | grep -o '"job":"[^"]*"},"value":\[[^]]*\]' | sed 's/"job":"//; s/"},"value":\[[0-9.]*,"/ /; s/"\]//')
echo "$series" | sort

# 3. 規則：等全部 health 都是 ok（最多等 2 分鐘），印告警規則數與不是 ok 的數目
for i in $(seq 1 12); do
  rules=$(curl -s -m 10 --cert ~/pki/certs/svc-ops.crt --key ~/pki/keys/svc-ops.key $prom/rules)
  alerting=$(echo "$rules" | grep -o '"type":"alerting"' | wc -l)
  # health 的總數減掉 ok 的數目（grep -c 數到 0 時結束碼是 1，不用它）
  health_all=$(echo "$rules" | grep -o '"health":"[a-z]*"' | wc -l)
  health_ok=$(echo "$rules" | grep -o '"health":"ok"' | wc -l)
  not_ok=$((health_all - health_ok))

  if [ "$not_ok" = 0 ]; then
    break
  fi

  sleep 10
done

echo "告警規則 $alerting 條，health 不是 ok 的 $not_ok 條"

# 4. Prometheus 連著兩台 Alertmanager（排序後印，順序才固定）
urls=$(curl -s -m 10 --cert ~/pki/certs/svc-ops.crt --key ~/pki/keys/svc-ops.key \
  $prom/alertmanagers | grep -o '"url":"[^"]*"' | sed 's/"url"://')
echo "$urls" | sort
```

```out
抓到 10 / 10 台
control-center 55
kafka-broker 689
kafka-controller 60
rest-proxy 188
告警規則 26 條，health 不是 ok 的 0 條
"http://127.0.0.1:9193/api/v2/alerts"
"https://c3-01.poc.lab:9093/api/v2/alerts"
```

序列數隨 topic、partition 數與 REST endpoint 數變化（broker 的 `kafka_cluster_partition_underminisr` 每個 partition 一條）；重點是合計在千條左右，不是一台上萬條。

## 32.4 測告警：停一台 broker、一台 controller

同時停 kb04 與 kc03：其他 3 台 broker、2 台 controller 撐著，應用程式不受影響（replication factor 3、`min.insync.replicas` 2）。預期 4 筆告警：`ConfluentTargetDown` 兩台各一筆（2 分鐘），`KafkaUnderReplicatedPartitions` 與 `KafkaFencedBrokers`（5 分鐘）。

@role 小安 | ops02 | root

```bash
ssh kb04.poc.lab sudo systemctl stop confluent-server
ssh kc03.poc.lab sudo systemctl stop confluent-server
```

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

接收端看到的內容（抓取＋規則 `for`，最多等 10 分鐘）：

```bash
# Python（在 lab-node:96 裡跑）：收到的每筆 JSON 印一行（排序過）：狀態、sub_origin、hostname，以及是不是每個欄位都是字串
py='
import json, sys
lines = []
for line in sys.stdin:
    d = json.loads(line)
    strings = all(isinstance(v, str) for v in d.values())
    kind = "全部字串" if strings else "有非字串"
    lines.append("%s | %s | %s | 欄位 %d 個，%s" % (d["state"], d["sub_origin"], d["hostname"], len(d), kind))  # lint-ok: Python 字串裡的 |
print("\n".join(sorted(lines)))
'
names='ConfluentTargetDown|KafkaUnderReplicatedPartitions|KafkaFencedBrokers'

# 只讀現在以後的接收端日誌（UTC）：重測時才不會讀到上一次的通知；停機是上一塊剛做的，告警最快 2 分鐘後才會來
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 等 4 筆 OPEN：每 15 秒看一次，最多 40 次
for i in $(seq 1 40); do
  # 接收端日誌裡這三種告警，去掉 { 之前的字，只留 JSON
  logs=$(podman logs --since "$since" lab-mon-webhook 2>&1)
  json=$(echo "$logs" | grep -E "^POST /c3-omnibus.*($names)" | sed 's/^[^{]*//')

  # 用 printf 不多加換行：還沒有資料時，Python 讀到的就是空的
  result=$(printf '%s' "$json" | podman run --rm -i lab-node:96 python3 -c "$py")

  if [ "$(echo "$result" | grep -c '^OPEN')" -ge 4 ]; then
    break
  fi

  sleep 15
done

echo "$result"
```

```out
OPEN | ConfluentTargetDown: kb04.poc.lab (kafka-broker) cannot be scraped | kb04.poc.lab | 欄位 10 個，全部字串
OPEN | ConfluentTargetDown: kc03.poc.lab (kafka-controller) cannot be scraped | kc03.poc.lab | 欄位 10 個，全部字串
OPEN | KafkaFencedBrokers: lab: 1 fenced brokers | lab | 欄位 10 個，全部字串
OPEN | KafkaUnderReplicatedPartitions: lab: 43 under-replicated partitions | lab | 欄位 10 個，全部字串
```

主機層的告警 `hostname` 是主機名；叢集層級的填環境名稱 `lab`。

@role 小安 | ops02 | root

開回來：

```bash
ssh kc03.poc.lab sudo systemctl start confluent-server
ssh kb04.poc.lab sudo systemctl start confluent-server
kc03_state=$(ssh kc03.poc.lab systemctl is-active confluent-server)
kb04_state=$(ssh kb04.poc.lab systemctl is-active confluent-server)
echo "kc03 $kc03_state，kb04 $kb04_state"
```

```out
kc03 active，kb04 active
```

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

等 4 筆 RESOLVED（exporter 在服務啟動後約 2 分鐘才回應，加上規則與通知間隔，最多等 10 分鐘）。`py`、`names`、`since` 沿用上一塊：

```bash
# 每 15 秒看一次，最多 40 次
for i in $(seq 1 40); do
  logs=$(podman logs --since "$since" lab-mon-webhook 2>&1)
  json=$(echo "$logs" | grep -E "^POST /c3-omnibus.*($names)" | sed 's/^[^{]*//')
  result=$(printf '%s' "$json" | podman run --rm -i lab-node:96 python3 -c "$py")

  if [ "$(echo "$result" | grep -c '^RESOLVED')" -ge 4 ]; then
    break
  fi

  sleep 15
done

echo "$result" | grep '^RESOLVED'
```

```out
RESOLVED | ConfluentTargetDown: kb04.poc.lab (kafka-broker) cannot be scraped | kb04.poc.lab | 欄位 10 個，全部字串
RESOLVED | ConfluentTargetDown: kc03.poc.lab (kafka-controller) cannot be scraped | kc03.poc.lab | 欄位 10 個，全部字串
RESOLVED | KafkaFencedBrokers: lab: 1 fenced brokers | lab | 欄位 10 個，全部字串
RESOLVED | KafkaUnderReplicatedPartitions: lab: 43 under-replicated partitions | lab | 欄位 10 個，全部字串
```

REST Proxy 停掉一樣由 `ConfluentTargetDown` 通知（job `rest-proxy`）；要測的話先把那台從負載平衡拿掉（`lb-member.sh rest01 down`）。

## 32.5 C3 畫面的 trigger 不會進 omnibus

@role 小安 | ops02 | root

用 C3 的 API 建一個一定成立的 trigger（和畫面建的相同），確認它只到內建那台，再刪掉。C3 的 API 要 MDS 的 token；token 留在變數裡，不印出來。

```bash
# 1. alice 的 token（回應裡的 "auth_token":"xxx"，取引號裡的 xxx）；之後呼叫 C3 都帶它
alice_pass=$(cat ~/secrets/ad-test-users.pass)
token=$(curl -s -m 10 -u "alice:$alice_pass" https://kb01.poc.lab:8090/security/1.0/authenticate \
  | grep -o '"auth_token":"[^"]*"' | cut -d'"' -f4)
auth="Authorization: Bearer $token"
json_type='Content-Type: application/json'
c3=https://c3-01.poc.lab:9021

# 2. 建 trigger：有 broker 收資料就成立
clusters=$(curl -s -m 30 -H "$auth" -H "$json_type" $c3/2.0/clusters/kafka \
  | grep -o '"clusterId":"[^"]*"' | cut -d'"' -f4)
cluster=$(echo "$clusters" | tail -1)

body=$(cat <<JSON
{
  "name": "chapter32-test",
  "clusterId": "$cluster",
  "brokerClusters": { "brokerClusters": ["$cluster"] },
  "brokerMetric": "BROKER_BYTES_IN",
  "condition": "GREATER_THAN",
  "longValue": 0
}
JSON
)

guids=$(curl -s -m 30 -H "$auth" -H "$json_type" -X POST $c3/2.0/alerts/triggers -d "$body" \
  | grep -o '"guid":"[^"]*"' | cut -d'"' -f4)
guid=$(echo "$guids" | tail -1)

# 3. 看兩台 Alertmanager（每 10 秒看一次，最多 3 分鐘）；到 c3-01 上問
for i in $(seq 1 18); do
  result=$(ssh c3-01.poc.lab bash -s <<'EOF'
# C3 的告警名稱是「trigger 名稱$$guid」，所以比對 annotation 的 trigger 名稱
# 第二台：trigger 名稱去重複，多個用逗號接起來
names=$(curl -s -m 5 127.0.0.1:9193/api/v2/alerts | grep -o '"trigger":"chapter32-test"' | sed 's/"trigger"://')
second=$(echo "$names" | sort -u | paste -sd, -)

# 內建那台：同樣的做法
names=$(sudo curl -s -m 5 \
  --cacert /etc/confluent/ssl/ca.pem \
  --cert /etc/confluent/ssl/svc-c3.crt \
  --key /etc/confluent/ssl/svc-c3.key \
  https://c3-01.poc.lab:9093/api/v2/alerts | grep -o '"trigger":"chapter32-test"' | sed 's/"trigger"://')
builtin=$(echo "$names" | sort -u | paste -sd, -)

echo "第二台=[$second] 內建=[$builtin]"
EOF
  )

  if echo "$result" | grep -q 'chapter32-test'; then
    break
  fi

  sleep 10
done

echo "$result"
```

```out
第二台=[] 內建=["chapter32-test"]
```

只到內建那台。把 trigger 刪掉，再確認 C3 沒有動到我們的檔：

```bash
# 1. 刪掉 trigger、丟掉 token
trigger_url=$c3/2.0/alerts/triggers/$guid
echo "刪除 trigger：$(curl -s -m 30 -H "$auth" -H "$json_type" -o /dev/null -w '%{http_code}' -X DELETE $trigger_url)"
unset token auth alice_pass

# 2. C3 沒有動到我們的檔
ssh c3-01.poc.lab bash -s <<'EOF'
cd /etc/confluent-control-center
sudo stat -c "%n %U" prometheus-generated.yml custom-rules-confluent.yml
EOF
```

```out
刪除 trigger：200
prometheus-generated.yml root
custom-rules-confluent.yml root
```

> 實測（C3 2.6.1）：C3 的 trigger 帶 `rule_created_by: c3-10`、沒有 `target`；如果也建了 action，通知由內建 Alertmanager 送出，內容是 Alertmanager 預設格式，C3 不能自訂 JSON（第 17 章開頭）。要讓某個 C3 trigger 也進 omnibus，C3 自己寫的規則檔不能手改（會被蓋掉），要改用我們的規則寫一條等價的。

## 32.6 之後要注意

| 情況 | 要做什麼 |
|---|---|
| 新增或調整告警 | 改第 17 章的規則檔（17.5），重做 32.3 第一塊，`sudo systemctl restart prometheus`；規則用到新的指標時，把名稱加進 `prometheus-generated.yml` 對應 job 的保留清單 |
| 新增、移除主機（第 25 章） | 改 `prometheus-generated.yml` 的 targets，`sudo systemctl restart prometheus` |
| 升級 C3（29.3、31.4） | `c3-change.sh` 不會動這些檔（lab 實測雜湊不變）；第二台用內附的執行檔，換完 `sudo systemctl restart alertmanager-custom`，並用 32.4 再測一次 |
| 換憑證（第 21 章） | 第二台只聽 127.0.0.1、走 HTTP，沒有憑證；抓 7071 只驗伺服器憑證（銀行根憑證不變就不用處理） |
| omnibus 位址或認證改了 | 改 `alertmanager.yml`，`sudo systemctl restart alertmanager-custom`；要認證時加 `http_config` |
| 銀行之後提供了 Prometheus | 改走第 17 章；同一個告警不要兩邊都送 omnibus（把 `rule_files` 的 `custom-rules-confluent.yml` 拿掉） |

# 33. 第三十三站：密碼學資產盤點（CBOM）與合規報告

![cbom]

**這一章在做什麼**：把平台用到的密碼學資產（憑證、金鑰、演算法、TLS 設定、密碼函式庫）盤點成一份 **CBOM**（Cryptography Bill of Materials，CycloneDX 格式），用 OPA 依規則判斷，產出一頁 HTML 的合規報告。目的是後量子密碼（PQC）遷移的盤點：哪些資產是量子電腦破解得了的、在哪幾台、要先處理哪些。完成的樣子：操作機上有 `cbom.json`、`findings.json`、`report.html` 三個檔，報告開頭寫明這次盤了哪些元件、有沒有違規。

Confluent Platform 是原廠產品，我們沒有原始碼，所以不能用掃原始碼的工具；盤的是**部署出來的東西**，分五層：

| 層 | 盤什麼 | 怎麼取得 | 工具 |
|---|---|---|---|
| ① 憑證與金鑰 | 每個埠實際出示的憑證鏈、操作機的憑證來源、MDS token 公鑰、ssh 金鑰 | 從操作機連每個埠；讀公開的憑證檔 | cbomkit-theia（PQCA）、cbom-tools |
| ② JDK 與 OS 設定 | `java.security` 停用了哪些演算法、OS 的 crypto-policies | 讀各台的檔 | cbom-tools |
| ③ 平台設定 | properties 裡的 TLS 版本、SASL 機制、token 簽章、Secret Protection | 讀各台的 properties（密碼類的值在主機上先遮掉） | cbom-tools |
| ④ 實際連線 | 每個埠支援的 TLS 版本、cipher suite、金鑰交換群組 | 從操作機掃 | testssl.sh |
| 函式庫 | 原廠 jar 裡帶了哪些密碼函式庫、什麼版本 | 各台的 jar 清單雜湊相同的歸一組，每組掃一台 | syft |
| ⑤ 執行期證據（可選） | 服務執行時實際用了哪些演算法、由哪段程式呼叫 | 用 JDK 內建的 JFR 對執行中的服務錄一段時間 | jcmd、jfr |

**每一台都收**，不是每種元件挑一台：盤點要抓的正是「某一台和別台不一樣」。同一個資產在 CBOM 裡只記一筆，附上出現在哪幾台。

**全程只讀**：不取私鑰、不取密碼（properties 裡密碼類的值在主機上就換成 `<遮蔽>` 才傳回）、平台主機上不放任何新程式（只跑系統本來就有的指令）。

**判斷分六級**（規則在 `policy/cbom.rego`，門檻要調整改這個檔就好）：

| 等級 | 意思 | 影響合規結果 |
|---|---|---|
| 違規 | 現在就不合格，和量子電腦無關：SHA-1、3DES、RSA 小於 2048、TLS 1.1 以下、過期的憑證、金鑰檔權限太鬆 | 有任何一個就是不合規 |
| 量子脆弱 | 現在安全，但量子電腦可破解：RSA、ECDSA、ECDH 等。NIST IR 8547：2030 年後棄用、2035 年後禁用 | 不影響，但要排進遷移計畫 |
| 警告 | 建議改善：還接受 TLS 1.2、CBC 類的 cipher suite | 不影響 |
| 待人工判斷 | 規則不認得 | 不影響 |
| 通過 | 後量子演算法、混合式金鑰交換、AES、SHA-2 等 | — |
| 盤點資訊 | 只是列出來，例如帶了哪些密碼函式庫 | — |

> 預期的結果：現在的憑證都是 RSA，所以「量子脆弱」一定有不少，這是事實、不是工具的問題。報告的用途是盤點與排遷移的優先序，不是拿到「全部通過」。金鑰交換則比較好：JDK 25.0.5 的 TLS 1.3 預設就支援後量子混合金鑰交換（`X25519MLKEM768`），所以遷移到 JDK 25 之後，broker 之間與用新版 JDK 的用戶端已經在用；實際用不用取決於用戶端也要支援。

> 限制：(1) 原廠程式內部怎麼用密碼學，只盤得到函式庫與執行期證據，完整的要向原廠要 SBOM／CBOM。(2) 執行期證據只看得到錄製期間發生的事。(3) CBOM 列出所有端點與演算法，本身是敏感資料，存放位置與誰能看要照銀行的規定。

## 33.1 下載工具

@role 小安 | dl01 | root

三個原廠有發行執行檔的工具在下載機抓，各自核對原廠提供的雜湊：OPA（規則判斷）、syft（列出 jar）、testssl.sh（掃 TLS）。testssl.sh 的 release 沒有附雜湊檔，用下面寫的雜湊核對（我方 2026-11-11 下載 3.2.5 時算的；換版本時要重算並更新這一行）。

```bash
# 1. 版本與放的位置（落地區的 tools/cbom）
opa_version=1.22.3
syft_version=1.57.1
testssl_version=3.2.5
testssl_sha256=23bb53d50ae093b89631e9fff547c087f632bf35f7a3d7dc78dd4ffff56cd779
dest=/out/tools/cbom
mkdir -p $dest
rm -f $dest/opa_linux_amd64 $dest/syft_*.tar.gz $dest/testssl.sh-*.tar.gz

# 2. OPA：release 附 .sha256
opa_base=https://github.com/open-policy-agent/opa/releases/download/v$opa_version
curl -fsSL -o $dest/opa_linux_amd64 $opa_base/opa_linux_amd64
curl -fsSL -o /tmp/opa.sha256 $opa_base/opa_linux_amd64.sha256
expected=$(cut -d' ' -f1 /tmp/opa.sha256)
actual=$(sha256sum $dest/opa_linux_amd64 | cut -d' ' -f1)

if [ "$actual" = "$expected" ]; then
  echo "opa $opa_version sha256-ok"
else
  echo "opa 的 sha256 對不上，已刪掉：不要帶進行內"
  rm -f $dest/opa_linux_amd64
  false
fi

# 3. syft：release 附 checksums.txt（每行「雜湊  檔名」）
syft_tar=syft_${syft_version}_linux_amd64.tar.gz
syft_base=https://github.com/anchore/syft/releases/download/v$syft_version
curl -fsSL -o $dest/$syft_tar $syft_base/$syft_tar
curl -fsSL -o /tmp/syft.sums $syft_base/syft_${syft_version}_checksums.txt
expected=$(grep " $syft_tar\$" /tmp/syft.sums | cut -d' ' -f1)
actual=$(sha256sum $dest/$syft_tar | cut -d' ' -f1)

if [ "$actual" = "$expected" ]; then
  echo "syft $syft_version sha256-ok"
else
  echo "syft 的 sha256 對不上，已刪掉：不要帶進行內"
  rm -f $dest/$syft_tar
  false
fi

# 4. testssl.sh：GitHub 的版本原始碼包，和上面寫的雜湊比
testssl_tar=testssl.sh-$testssl_version.tar.gz
curl -fsSL -o $dest/$testssl_tar https://github.com/testssl/testssl.sh/archive/refs/tags/v$testssl_version.tar.gz
actual=$(sha256sum $dest/$testssl_tar | cut -d' ' -f1)

if [ "$actual" = "$testssl_sha256" ]; then
  echo "testssl.sh $testssl_version sha256-ok"
else
  echo "testssl.sh 的 sha256 對不上，已刪掉：不要帶進行內"
  rm -f $dest/$testssl_tar
  false
fi

rm -f /tmp/opa.sha256 /tmp/syft.sums
```

```out
opa 1.22.3 sha256-ok
syft 1.57.1 sha256-ok
testssl.sh 3.2.5 sha256-ok
```

## 33.2 我方的交付物進落地區，整批送進操作機

@role 小安 | Windows 終端 | 本機

另外兩樣是我方的**交付物**，和這本手冊一起給：`cbom-kit-<日期>.<雜湊>.tar.gz` 與它的 `SHA256SUMS`。裡面是 `cbom-tools.jar`（把原料做成 CBOM、把判斷結果做成報告，需要 JDK 17 以上）、`cbomkit-theia`（PQCA 的工具，原廠只發行原始碼與容器映像，我方從 1.1.2 的原始碼編成靜態執行檔）、`policy/`（OPA 的規則與規則的測試）、`cbom-collect.sh`（33.4–33.7 的同一套收集指令包成的腳本，33.10 的 Jenkins 用）、`VERSIONS`（各元件的版本與雜湊）。把它們複製進落地區的 `tools/cbom/`、核對雜湊，再替整個目錄產生一份 `SHA256SUMS`（`<CBOM 交付物的目錄>` 換成你放這兩個檔的地方）：

```bash
D="<CBOM 交付物的目錄>"
dest=~/kafka-lab/landing/tools/cbom

# 1. 落地區只留最新一版的交付物
mkdir -p $dest
rm -f $dest/cbom-kit-*.tar.gz $dest/SHA256SUMS
cp "$D"/cbom-kit-*.tar.gz $dest/

# 2. 用交付物自己的 SHA256SUMS 核對
cd $dest
sha256sum -c "$D/SHA256SUMS"

# 3. 整個目錄（交付物＋33.1 下載的三個工具）產生一份 SHA256SUMS，進內網後用它核對
sha256sum cbom-kit-*.tar.gz opa_linux_amd64 syft_*.tar.gz testssl.sh-*.tar.gz > SHA256SUMS
wc -l < SHA256SUMS
```

```out
cbom-kit-20261111.8aaca17b.tar.gz: OK
4
```

> 正式環境同樣是這幾個檔，經銀行的檔案交換平台進落地區（第 3 章）。雜湊對不上就不要裝。

整包送進操作機（就是 3.4 的做法，`D=cbom`）：

@role Lab 管理員（扮演銀行） | Windows 終端 | 本機

```bash
D=cbom   # 要送的目錄（落地區 tools/ 底下）
src="$HOME/kafka-lab/landing/tools/$D"
dest=/root/landing/tools/$D

# 1. 操作機上同名的舊目錄先清掉（落地區是唯讀的，要先打開寫入權限）
if podman exec lab-ops02-1 test -d "$dest"; then
  podman exec lab-ops02-1 chmod -R u+w "$dest"
  podman exec lab-ops02-1 rm -rf "$dest"
fi

# 2. 送過去，再收回寫入權限
podman cp "$(cygpath -m "$src")" lab-ops02-1:/root/landing/tools/
podman exec lab-ops02-1 chmod -R a-w "$dest"

# 3. 在操作機上核對 sha256
if podman exec -w "$dest" lab-ops02-1 sha256sum -c --quiet SHA256SUMS; then
  echo sha256-ok
else
  echo "sha256 對不上：請重送，不要裝"
  false
fi
```

```out
sha256-ok
```

## 33.3 裝到操作機

@role 小安 | ops02 | root

工具都裝在 `/opt/cbom`：`bin/` 放執行檔，`policy/` 放規則。testssl.sh 一定要有 DNS 查詢工具（`dig`），所以從銀行的 OS 套件庫裝 `bind-utils`。裝完跑規則的測試，確認規則檔和 OPA 的版本合得來。

```bash
# 1. 清掉舊的，解開交付物（cbom-kit/ 底下的東西直接放進 /opt/cbom）
rm -rf /opt/cbom
mkdir -p /opt/cbom/bin
cd ~/landing/tools/cbom
tar -xzf cbom-kit-*.tar.gz -C /opt/cbom --strip-components=1
mv /opt/cbom/cbom-tools.jar /opt/cbom/bin/

# 執行檔的權限在這裡明確設定：交付物經過檔案交換之後，壓縮檔裡的執行權限不一定還在
install -m 755 /opt/cbom/cbomkit-theia /opt/cbom/bin/cbomkit-theia
install -m 755 /opt/cbom/cbom-collect.sh /opt/cbom/bin/cbom-collect.sh
rm -f /opt/cbom/cbomkit-theia /opt/cbom/cbom-collect.sh

# 2. 三個原廠工具
install -m 755 opa_linux_amd64 /opt/cbom/bin/opa
tar -xzf syft_*.tar.gz -C /opt/cbom/bin syft
mkdir -p /opt/cbom/bin/testssl
tar -xzf testssl.sh-*.tar.gz -C /opt/cbom/bin/testssl --strip-components=1

# 3. testssl.sh 需要的 DNS 工具（OS 套件，來自銀行的套件庫）
dnf -y -q install bind-utils

# 4. 確認每個都能執行
/opt/cbom/bin/opa version | head -1
/opt/cbom/bin/syft version | grep '^Version'
testssl_version=$(/opt/cbom/bin/testssl/testssl.sh --version | grep -o '[0-9]*\.[0-9]*\.[0-9]*' | head -1)
echo "testssl.sh $testssl_version"
/opt/cbom/bin/cbomkit-theia --help | grep -c 'CBOMkit-theia analyzes'
/opt/java/current/bin/java -jar /opt/cbom/bin/cbom-tools.jar 2>&1 | head -1
rpm -q bind-utils

# 5. 規則的測試（調整規則之後也先跑這個）
/opt/cbom/bin/opa test /opt/cbom/policy/
```

```out
Version: 1.22.3
Version:       1.57.1
testssl.sh 3.2.5
1
用法：
bind-utils-9.16.23-40.el9_8.13.x86_64
PASS: 22/22
```

## 33.4 收集：這次的範圍、每台的設定與檔案清單

@role 小安 | ops02 | root

原料都收到 `~/cbom/raw`（每次重新收，舊的先清掉）。先決定這次的範圍：`roles` 可以只寫其中幾個，例如只盤 broker 就寫 `roles="broker"`；沒有全選的話，報告開頭會標成「部分盤點」。`shared` 是不屬於單一元件的資產（銀行的根憑證與簽發憑證、SCRAM 帳號、ssh 金鑰、操作機的憑證來源）。

```bash
# 1. 這次要盤哪些元件（全部＝完整盤點）
roles="controller broker rest c3 shared"
domain=poc.lab
raw=~/cbom/raw
rm -rf $raw
mkdir -p $raw/shared

# 2. 依選的元件列出主機（「主機:元件」）
host_roles=""

if echo " $roles " | grep -q " controller "; then
  host_roles="$host_roles kc01:controller kc02:controller kc03:controller"
fi

if echo " $roles " | grep -q " broker "; then
  host_roles="$host_roles kb01:broker kb02:broker kb03:broker kb04:broker"
fi

if echo " $roles " | grep -q " rest "; then
  host_roles="$host_roles rest01:rest rest02:rest"
fi

if echo " $roles " | grep -q " c3 "; then
  host_roles="$host_roles c3-01:c3"
fi

# 只留主機名（kc01:controller → kc01）
hosts=$(echo "$host_roles" | sed -E 's/:[a-z0-9]+//g')

# 3. 記下這次的範圍：cbom-tools 與報告都讀這個檔
cat > $raw/collect.env <<EOF
DOMAIN=$domain
ENV=lab
CP_VERSION=$(rpm -q --qf '%{VERSION}' confluent-server)
COLLECTED_AT=$(date +%Y-%m-%dT%H:%M:%S%:z)
ALL_ROLES=controller broker rest c3 shared
ROLES=$roles
HOSTS=$host_roles
JFR_SECONDS=
TOOLS=$(grep -E '^(cbom-tools|cbomkit-theia) ' /opt/cbom/VERSIONS | paste -sd, -), testssl.sh 3.2.5, syft 1.57.1, opa 1.22.3
EOF

echo "主機：$hosts"
grep -E '^(ROLES|CP_VERSION|TOOLS)=' $raw/collect.env
```

```out
主機： kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01
CP_VERSION=8.3.2
ROLES=controller broker rest c3 shared
TOOLS=cbom-tools 1.0.0,cbomkit-theia 1.1.2, testssl.sh 3.2.5, syft 1.57.1, opa 1.22.3
```

每一台送一段腳本過去：在主機上把要的東西整理成幾個小檔，打成 tar 傳回來，主機上的暫存目錄隨即刪掉。properties 裡只取和密碼學有關的設定鍵，密碼類的值在主機上就換成 `<遮蔽>`。`hosts`、`domain`、`raw`、`roles` 沿用上一塊（33.4 到 33.8 在同一個終端機做完）。

```bash
for host in $hosts; do
  mkdir -p $raw/$host

  ssh $host.$domain bash -s <<'EOF' | tar -xf - -C $raw/$host
tmp=$(mktemp -d)
cd "$tmp"

# 1. 服務實際用的 properties：只留密碼學相關的設定，密碼類的值遮掉
unit_exec=$(systemctl show confluent-server confluent-kafka-rest confluent-control-center -p ExecStart 2>/dev/null)
props=$(echo "$unit_exec" | grep -o '/etc/confluent[^ ;]*properties' | head -1)
keys='ssl|sasl|tls|cipher|protocol|keystore|truststore|algorithm|scram|token|secret|fips|security\.providers|listeners'
secrets='password|secret|jaas|credentials|api\.key'
echo "# file=$props" > platform-config.properties
settings=$(sudo cat "$props" | grep -E "^[^#=]*($keys)[^=]*=")
echo "$settings" | sed -E "/^[^=]*($secrets)[^=]*=/ s/=.*/=<遮蔽>/" >> platform-config.properties

# 2. Secret Protection 的非機密參數（金鑰長度、迭代次數；不取 salt 與密文）
metadata=$(sudo cat /etc/confluent/secrets/security.properties | grep '^_metadata\.')
echo "$metadata" | grep -vE 'salt|\.enc' > secret-protection.properties

# 3. 憑證與金鑰檔：只列權限、擁有者、大小、路徑；公開的 token 公鑰取回
sudo find /etc/confluent/ssl -type f -printf '%m %u:%g %s %p\n' > ssl-files.list
sudo cat /etc/confluent/ssl/mds-token-public.pem > mds-token-public.pem

# 4. JDK 與 OS 的密碼設定
cat /opt/java/current/conf/security/java.security > java.security
/opt/java/current/bin/java -version > java-version.txt 2>&1
readlink -f /opt/java/current >> java-version.txt
update-crypto-policies --show > os-crypto.txt
cat /etc/redhat-release >> os-crypto.txt
openssl version >> os-crypto.txt

# 5. jar 清單的雜湊（之後用來分組）、Confluent 套件版本、監聽的埠（不含 ssh）
find /usr/share/java -name '*.jar' -type f -exec sha256sum {} + | sort -k2 > jars.sha256
rpm -qa 'confluent*' | sort > rpm-confluent.txt
listening=$(ss -ltnH | awk '{print $4}' | sed 's/.*://')
echo "$listening" | sort -un | grep -v '^22$' > ports.txt

tar -cf - .
cd /
rm -rf "$tmp"
EOF

  files=$(ls $raw/$host | wc -l)
  settings=$(grep -vc '^#' $raw/$host/platform-config.properties)
  jars=$(wc -l < $raw/$host/jars.sha256)
  echo "$host：$files 個檔，設定 $settings 行，jar $jars 個"
done
```

```out
kc01：10 個檔，設定 42 行，jar 2818 個
kc02：10 個檔，設定 42 行，jar 2818 個
kc03：10 個檔，設定 42 行，jar 2818 個
kb01：10 個檔，設定 72 行，jar 2818 個
kb02：10 個檔，設定 72 行，jar 2818 個
kb03：10 個檔，設定 72 行，jar 2818 個
kb04：10 個檔，設定 72 行，jar 2818 個
rest01：10 個檔，設定 32 行，jar 1809 個
rest02：10 個檔，設定 32 行，jar 1809 個
c3-01：10 個檔，設定 43 行，jar 1019 個
```

收回來的東西不該有私鑰，密碼類的設定都該是遮過的。檢查一次：

```bash
private_keys=$(grep -rl 'PRIVATE KEY' $raw | wc -l)
secret_lines=$(grep -rhE '^[^=]*(password|secret|jaas|credentials)[^=]*=' $raw --include=platform-config.properties)
unmasked=$(echo "$secret_lines" | awk '!/=<遮蔽>/ {c++} END {print c + 0}')
echo "含私鑰的檔：$private_keys 個；沒遮到的密碼類設定：$unmasked 行；原料大小 $(du -sh $raw | cut -f1)"
```

```out
含私鑰的檔：0 個；沒遮到的密碼類設定：0 行；原料大小 4.3M
```

## 33.5 收集：每個埠出示的憑證、TLS 掃描

@role 小安 | ops02 | root

從操作機連每台的每個監聽埠，把伺服器出示的憑證鏈存下來（之後交給 cbomkit-theia）。要求用戶端憑證的埠交握不會完成，但伺服器的憑證鏈在那之前就送出來了，一樣存得到；不是 TLS 的埠（例如 JMX 的隨機埠）存不到東西，略過。

```bash
for host in $hosts; do
  mkdir -p $raw/$host/served

  for port in $(cat $raw/$host/ports.txt); do
    pem=$raw/$host/served/$port.pem

    # 交握失敗（要求用戶端憑證、不是 TLS）不算錯：能存到憑證鏈就存
    if echo | timeout 8 openssl s_client -connect $host.$domain:$port -showcerts > /tmp/cbom-chain.txt 2>/dev/null; then
      handshake=ok
    else
      handshake=failed
    fi

    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' /tmp/cbom-chain.txt > $pem

    if [ ! -s $pem ]; then
      rm -f $pem
    fi
  done

  listening=$(wc -l < $raw/$host/ports.txt)
  served=$(ls $raw/$host/served | wc -l)
  served_ports=$(ls $raw/$host/served | sed 's/.pem//' | paste -sd' ' -)
  echo "$host：監聽 $listening 個埠，出示憑證的 $served 個（$served_ports）"
done

rm -f /tmp/cbom-chain.txt
```

```out
kc01：監聽 3 個埠，出示憑證的 2 個（7071 9093）
kc02：監聽 3 個埠，出示憑證的 2 個（7071 9093）
kc03：監聽 3 個埠，出示憑證的 2 個（7071 9093）
kb01：監聽 7 個埠，出示憑證的 6 個（7071 8090 9092 9094 9095 9096）
kb02：監聽 7 個埠，出示憑證的 6 個（7071 8090 9092 9094 9095 9096）
kb03：監聽 7 個埠，出示憑證的 6 個（7071 8090 9092 9094 9095 9096）
kb04：監聽 7 個埠，出示憑證的 6 個（7071 8090 9092 9094 9095 9096）
rest01：監聽 3 個埠，出示憑證的 2 個（7071 8082）
rest02：監聽 3 個埠，出示憑證的 2 個（7071 8082）
c3-01：監聽 6 個埠，出示憑證的 3 個（7071 9021 9090）
```

對出示憑證的每個埠跑 testssl.sh，看它支援哪些 TLS 版本、cipher suite、金鑰交換群組。一個埠約 1 分鐘，所以每台主機各開一個背景工作同時掃，lab 的 10 台約 4 分鐘。testssl.sh 只做交握，不送資料，不影響服務。

```bash
start=$(date +%s)

for host in $hosts; do
  mkdir -p $raw/$host/tls
  ip=$(getent hosts $host.$domain | cut -d' ' -f1)

  # 這台的每個埠依序掃；整台放到背景，和其他主機同時進行
  (
    for pem in $raw/$host/served/*.pem; do
      port=$(basename $pem .pem)
      /opt/cbom/bin/testssl/testssl.sh --quiet --color 0 --nodns none --ip $ip -p -s -f -S \
        --jsonfile $raw/$host/tls/$port.json $host.$domain:$port
    done
  ) > $raw/$host/tls/scan.log 2>&1 &
done

wait
scanned=$(ls $raw/*/tls/*.json | wc -l)
failed=$(grep -l '"scanProblem"' $raw/*/tls/*.json | wc -l)
echo "掃了 $scanned 個埠，掃不了的 $failed 個（約 $(( $(date +%s) - start )) 秒）"
```

```out
掃了 37 個埠，掃不了的 0 個（約 240 秒）
```

## 33.6 收集：jar 分組、平台共用的資產、憑證掃描

@role 小安 | ops02 | root

每台的 jar 有幾百 MB，全部搬回來太浪費。33.4 已經收回每台 jar 清單的雜湊：清單完全相同的主機歸成一組，每組只取一台的 jar 回操作機，用 syft 列出來，掃完就刪。正常情況是 controller 與 broker 一組（裝的是同一套 RPM）、REST Proxy 一組、C3 一組；升級做到一半、某台還是舊版時，它會自己成一組被單獨掃，報告看得出來。

```bash
mkdir -p $raw/shared/jars
rm -f $raw/shared/jars/groups.txt

# 1. 每台一行「清單雜湊前 12 碼 主機」
for host in $hosts; do
  digest=$(sha256sum < $raw/$host/jars.sha256 | cut -c1-12)
  echo "$digest $host" >> $raw/shared/jars/groups.txt
done

# 2. 每一組取第一台的 jar 回來掃（暫存放磁碟，不放 /tmp：一組可能有 2 GB）
for digest in $(cut -d' ' -f1 $raw/shared/jars/groups.txt | sort -u); do
  members=$(grep "^$digest " $raw/shared/jars/groups.txt | cut -d' ' -f2 | paste -sd' ' -)
  first=$(echo "$members" | cut -d' ' -f1)
  tmp=~/cbom/tmp-jars
  rm -rf $tmp
  mkdir -p $tmp

  ssh $first.$domain "tar -C /usr/share -cf - java" | tar -C $tmp -xf -
  SYFT_CHECK_FOR_APP_UPDATE=false /opt/cbom/bin/syft scan dir:$tmp/java \
    -o cyclonedx-json=$raw/shared/jars/sbom-$digest.json -q 2>/dev/null

  echo "組 $digest（$members）：取 $first 的 jar $(du -sh $tmp | cut -f1)"
  rm -rf $tmp
done
```

```out
組 60ff3024640f（kc01 kc02 kc03 kb01 kb02 kb03 kb04）：取 kc01 的 jar 2.1G
組 650ce6cfe64f（c3-01）：取 c3-01 的 jar 837M
組 ea89dcc9eadc（rest01 rest02）：取 rest01 的 jar 1.4G
```

平台共用的資產（`roles` 有 `shared` 才收）：操作機的憑證來源只取公開的 `.crt`／`.pem`，不取 `.p12` 與私鑰；SCRAM 帳號只取機制與迭代次數，不取雜湊；ssh 金鑰只取類型、長度、指紋。

```bash
if echo " $roles " | grep -q " shared "; then
  mkdir -p $raw/shared/pki

  # 1. 操作機的憑證來源：公開的憑證檔（含私鑰的檔一律不取）
  for file in ~/pki/certs/*.crt ~/pki/certs/*.pem; do
    if ! grep -q 'PRIVATE KEY' $file; then
      cp $file $raw/shared/pki/
    fi
  done

  # 2. SCRAM 帳號：kafka-configs 的輸出裡只留 SCRAM 的那幾行（機制與迭代次數，沒有密碼雜湊）
  users=$(kafka-configs --bootstrap-server kb01.$domain:9094 --command-config ~/conf/client-admin.properties \
    --describe --entity-type users 2>/dev/null)
  echo "$users" | grep '^SCRAM credential configs' > $raw/shared/scram-users.txt

  # 3. ssh 金鑰：操作機連各台用的那把，與每台的主機金鑰（ssh-keygen -l 印長度、指紋、類型）
  ssh-keygen -l -f /secure/ssh/cpuser_ed25519.pub > $raw/shared/ssh-client-key.txt
  rm -f $raw/shared/ssh-host-keys.txt

  for host in $hosts; do
    keys=$(ssh-keyscan -T 5 $host.$domain 2>/dev/null | grep -v '^#')
    echo "$keys" | ssh-keygen -l -f - | sed "s/^/$host /" >> $raw/shared/ssh-host-keys.txt
  done

  certs=$(ls $raw/shared/pki | wc -l)
  scram_users=$(wc -l < $raw/shared/scram-users.txt)
  host_keys=$(wc -l < $raw/shared/ssh-host-keys.txt)
  echo "憑證來源 $certs 個檔，SCRAM 帳號 $scram_users 個，ssh 主機金鑰 $host_keys 把"
fi
```

```out
憑證來源 9 個檔，SCRAM 帳號 8 個，ssh 主機金鑰 30 把
```

最後用 cbomkit-theia 掃整包原料裡的憑證檔（每個埠出示的憑證鏈、操作機的憑證來源），產出憑證、公鑰、簽章演算法：

```bash
/opt/cbom/bin/cbomkit-theia dir $raw -p certificates > $raw/shared/theia.json 2> $raw/shared/theia.log
grep -o 'numberOfDetectedCertificates=[0-9]*' $raw/shared/theia.log
du -sh $raw | cut -f1
```

```out
numberOfDetectedCertificates=89
25M
```

> `theia.log` 裡會有幾行 `x509: malformed certificate`：那是 `mds-token-public.pem`（公鑰，不是憑證），cbomkit-theia 讀不了；這把公鑰由 cbom-tools 另外處理。

## 33.7 （可選）執行期證據：用 JFR 錄一段

@role 小安 | ops02 | root

前面幾層回答「設定成什麼、支援什麼」；這一節回答「**執行時實際用了什麼**」：對執行中的服務用 JDK 內建的 `jcmd` 啟動 JFR 錄製，只開密碼學相關的事件，錄一段時間後取回，用 `jfr print --json` 轉成 JSON。不用重啟服務，不用在主機上放新程式。看得到原廠程式實際向 JDK 要了哪些演算法（連呼叫它的程式都有），以及有沒有連線真的用了後量子金鑰交換。

不想做就跳過這一節，CBOM 與報告照樣產得出來，只是報告會寫「執行期證據：沒有錄製」。

> 限制（lab 實測）：只看得到錄製期間發生的事；`jdk.TLSHandshake` 只記 TLS 1.3 的交握，TLS 1.2 的交握成功了也沒有事件，所以不能用它找還在用 TLS 1.2 的用戶端。錄製檔含連線對象的位址（不含金鑰），屬於敏感資料。這是對正式環境服務的操作，要先經銀行同意。

```bash
seconds=60
events="jdk.SecurityProviderService#enabled=true jdk.TLSHandshake#enabled=true jdk.X509Certificate#enabled=true"

# 1. 每台啟動錄製（jcmd 要用服務自己的帳號執行；三個事件名稱各是一個參數，遠端用 "$@" 全部收下）
for host in $hosts; do
  ssh $host.$domain bash -s -- $events <<'EOF'
unit=$(systemctl list-units --state=running --no-legend 'confluent-*.service' | awk '{print $1}' | head -1)
pid=$(systemctl show $unit -p MainPID --value)
user=$(ps -o user= -p $pid)
sudo -u $user /opt/java/current/bin/jcmd $pid JFR.start name=cbom maxsize=50m "$@" > /dev/null
echo "$(hostname -s)：$unit（pid $pid，$user）開始錄"
EOF
done

# 2. 錄製期間平台照常運作；這裡等設定的秒數
sleep $seconds
```

```out
kc01：confluent-server.service（pid 27，cp-kafka）開始錄
kc02：confluent-server.service（pid 27，cp-kafka）開始錄
kc03：confluent-server.service（pid 27，cp-kafka）開始錄
kb01：confluent-server.service（pid 27，cp-kafka）開始錄
kb02：confluent-server.service（pid 27，cp-kafka）開始錄
kb03：confluent-server.service（pid 27，cp-kafka）開始錄
kb04：confluent-server.service（pid 27，cp-kafka）開始錄
rest01：confluent-kafka-rest.service（pid 27，cp-kafka-rest）開始錄
rest02：confluent-kafka-rest.service（pid 27，cp-kafka-rest）開始錄
c3-01：confluent-control-center.service（pid 62，cp-control-center）開始錄
```

停止錄製、取回、轉成 JSON，主機上的錄製檔隨即刪掉；最後把錄了幾秒記進 `collect.env`：

```bash
for host in $hosts; do
  mkdir -p $raw/$host/jfr

  # 1. 匯出並停止錄製，把錄製檔傳回來，主機上的刪掉
  ssh $host.$domain bash -s > $raw/$host/jfr/service.jfr <<'EOF'
unit=$(systemctl list-units --state=running --no-legend 'confluent-*.service' | awk '{print $1}' | head -1)
pid=$(systemctl show $unit -p MainPID --value)
user=$(ps -o user= -p $pid)
sudo rm -f /tmp/cbom.jfr
sudo -u $user /opt/java/current/bin/jcmd $pid JFR.dump name=cbom filename=/tmp/cbom.jfr > /dev/null
sudo -u $user /opt/java/current/bin/jcmd $pid JFR.stop name=cbom > /dev/null
sudo cat /tmp/cbom.jfr
sudo rm -f /tmp/cbom.jfr
EOF

  # 2. 轉成 JSON（只取用得到的事件），原始的錄製檔刪掉
  /opt/java/current/bin/jfr print --json --events jdk.SecurityProviderService,jdk.TLSHandshake \
    $raw/$host/jfr/service.jfr > $raw/$host/jfr/service.json
  rm -f $raw/$host/jfr/service.jfr

  requests=$(grep -o '"jdk.SecurityProviderService"' $raw/$host/jfr/service.json | wc -l)
  handshakes=$(grep -o '"jdk.TLSHandshake"' $raw/$host/jfr/service.json | wc -l)
  echo "$host：演算法請求 $requests 筆，TLS 交握 $handshakes 筆"
done

sed -i "s/^JFR_SECONDS=.*/JFR_SECONDS=$seconds/" $raw/collect.env
```

```out
kc01：演算法請求 0 筆，TLS 交握 0 筆
kc02：演算法請求 0 筆，TLS 交握 0 筆
kc03：演算法請求 0 筆，TLS 交握 0 筆
kb01：演算法請求 480 筆，TLS 交握 5 筆
kb02：演算法請求 282 筆，TLS 交握 3 筆
kb03：演算法請求 480 筆，TLS 交握 5 筆
kb04：演算法請求 282 筆，TLS 交握 3 筆
rest01：演算法請求 2 筆，TLS 交握 0 筆
rest02：演算法請求 2 筆，TLS 交握 0 筆
c3-01：演算法請求 0 筆，TLS 交握 0 筆
（數字隨錄製期間的連線量而不同）
```

> 0 筆不是錯：這 60 秒內那個服務沒有建立新的連線、也沒有向 JDK 要新的演算法（controller 之間是長時間保持的連線）。要看到更多，就在有流量的時段錄，或錄久一點。

## 33.8 產生 CBOM、用 OPA 判斷、產出報告

@role 小安 | ops02 | root

三個指令：`cbom-tools build` 把原料併成一份 CBOM 並用 CycloneDX 官方的 schema 驗證；`opa eval` 依規則判斷；`cbom-tools report` 做成 HTML。產出在 `~/cbom/out`。

```bash
out=~/cbom/out
rm -rf $out
mkdir -p $out
java=/opt/java/current/bin/java
opa=/opt/cbom/bin/opa
policy=/opt/cbom/policy/

# 1. 原料 → CBOM（預設 CycloneDX 1.7；接收的系統只收 1.6 時在最後加 --spec 1.6）
$java -jar /opt/cbom/bin/cbom-tools.jar build $raw $out/cbom.json

# 2. 依規則判斷
$opa eval --data $policy --input $out/cbom.json --format json 'data.cbom.report' > $out/findings.json

# 3. 報告
$java -jar /opt/cbom/bin/cbom-tools.jar report $out/cbom.json $out/findings.json $out/report.html
```

```out
CBOM（CycloneDX 1.7）：168 個元件 {algorithm=39, certificate=9, file=44, library=25, protocol=10, related-crypto-material=41}
範圍：完整（controller broker rest c3 shared）
已通過官方 schema 驗證，寫到 /root/cbom/out/cbom.json
報告寫到 /root/cbom/out/report.html
```

合規結果與各等級的數量（自動化時用這兩行決定要不要讓工作失敗：只有 `compliant` 是 `false` 才算失敗）：

```bash
$opa eval --data $policy --input $out/cbom.json --format raw 'data.cbom.report.compliant'
echo
$opa eval --data $policy --input $out/cbom.json --format raw 'data.cbom.report.counts'
echo
ls $out
```

```out
true
{"quantum-vulnerable":72,"unknown":0,"violation":0,"warning":3}
cbom.json
findings.json
report.html
```

> 數字隨環境不同：憑證張數、ssh 金鑰、有沒有做 33.7 都會影響。lab 的結果是違規 0、量子脆弱 72（9 張憑證、41 把金鑰、22 個演算法，都是 RSA 與橢圓曲線）、警告 3（三組 TLS 1.2 的設定）；執行期看到的演算法每次錄到的不一樣，所以元件數與量子脆弱的數字會差幾個。

## 33.9 取回報告

@role Lab 管理員 | Windows 終端 | 本機

lab 把三個檔從操作機複製出來，用瀏覽器開 `report.html`（單一檔，不連外）。正式環境照銀行的檔案交換流程取出，或由 33.10 的 Jenkins 提供下載。

```bash
dest=~/kafka-lab/cbom-out
mkdir -p $dest

for file in cbom.json findings.json report.html; do
  podman cp lab-ops02-1:/root/cbom/out/$file "$(cygpath -m $dest/$file)"
done

ls $dest
grep -o '<div class="verdict [a-z]*">[^<]*' $dest/report.html | cut -d'>' -f2
grep -o '<strong>[^<]*盤點</strong>' $dest/report.html
```

```out
cbom.json
findings.json
report.html
合規：沒有違規項目
<strong>完整盤點</strong>
```

怎麼讀這份報告：

| 區塊 | 看什麼 |
|---|---|
| 範圍 | 「完整盤點」還是「部分盤點」；部分盤點會寫沒盤到哪些元件，這種報告不代表整個平台 |
| 合規結論 | 有沒有違規。量子脆弱與警告不影響這一行 |
| 後量子遷移的重點 | 幾個端點支援後量子金鑰交換、幾個還接受 TLS 1.2、憑證是什麼金鑰、執行期有沒有真的用到後量子金鑰交換 |
| 違規 | 要立刻處理，每一列有原因、依據、出現在哪幾台 |
| 量子脆弱 | 遷移計畫的清單。寫「優先處理」的是有效期跨過 2030 或 2035 年的憑證 |
| 警告、待人工判斷 | 排改善；待人工判斷的看過之後把規則補進 `cbom.rego` |
| 通過、盤點資訊 | 預設收合；函式庫清單在盤點資訊裡 |

## 33.10 用 Jenkins 自動執行

**這一節在做什麼**：把 33.4–33.8 交給 Jenkins：在畫面上勾選這次要盤的元件、按執行，跑完在同一頁看報告、下載 `cbom.json`、`findings.json`、`report.html`，每次執行的結果都留著。pipeline（交付物裡的 `Jenkinsfile`）只是依序呼叫前面用過的程式，沒有自己的邏輯，所以同樣的事不靠 Jenkins 也能照 33.4–33.8 手動做。

| 步驟 | 在哪裡執行 | 做什麼 |
|---|---|---|
| 收集 | 操作機 | Jenkins 用一把**受限的 ssh 金鑰**連進來，只能執行 `cbom-collect.sh`（33.4–33.7 的同一套指令包成的腳本），原料從這條連線傳回 Jenkins |
| 產生、判斷、報告 | Jenkins | `cbom-tools build` → `opa test`＋`opa eval` → `cbom-tools report` |
| 結果 | Jenkins | 只有「違規」讓這次執行失敗；量子脆弱與警告不擋 |

**Jenkins 拿不到操作機的 shell，也不持有平台的任何金鑰。** 操作機不開放 root 用 ssh 登入，所以收集的入口是一個專用帳號 `cbomsvc`（密碼鎖定、只收金鑰，和 `cpuser` 同樣的做法）：Jenkins 的公鑰在它的 `authorized_keys` 裡被 `command=` 固定成只能執行一個指令、`from=` 限定只收 Jenkins 的 IP；那個指令用 sudo 執行收集腳本，sudoers 只開這一條。連線時帶的字串只接受 `collect roles=… jfr=…` 這種寫法，其他一律拒絕，所以金鑰外洩最多只能再做一次盤點。

Jenkins 是銀行的；lab 用容器扮演。銀行的 Jenkins 要有 Credentials Binding、SSH Credentials、HTML Publisher 三個 plugin，執行的 agent 上要有 JDK 17 以上、`/opt/cbom/bin` 的 `cbom-tools.jar` 與 `opa`、`/opt/cbom/policy`、ssh、curl、tar。

> 報告有兩份、內容相同：`report.html` 是單一檔（樣式寫在檔案裡），下載、寄送用；Jenkins 畫面上那份把樣式放在另一個檔。原因是 Jenkins 預設的安全設定（Content-Security-Policy）不允許寫在 HTML 裡的樣式，硬要顯示單一檔的那份版面會全掉；不要為了這個去放寬 Jenkins 的安全設定。

@role Lab 管理員（扮演銀行的 Jenkins 管理員） | Windows 終端 | 本機

先準備 lab 的 Jenkins 要用的檔案，都放在 `~/kafka-lab/jenkins`：一把專用的金鑰、管理員密碼（隨機產生，存檔不顯示）、agent 要用的工具（從落地區的交付物解出來）：

```bash
dir=~/kafka-lab/jenkins
mkdir -p $dir/secrets $dir/init.groovy.d $dir/cbom/bin

# 1. Jenkins 專用的 ssh 金鑰（已經有就不重產）；公鑰之後交給操作機
if [ ! -f $dir/secrets/cbom_collect_ed25519 ]; then
  ssh-keygen -q -t ed25519 -N '' -C "jenkins-cbom-$(date +%Y%m%d)" -f $dir/secrets/cbom_collect_ed25519
fi

# 2. 管理員密碼：24 個字的亂數，寫進檔案，不印出來（Windows 上 openssl 的輸出帶 \r，要一起去掉）
if [ ! -f $dir/secrets/admin.pass ]; then
  openssl rand -base64 18 | tr -d '\r\n' > $dir/secrets/admin.pass
fi

# 3. agent 要用的工具：交付物裡的 cbom-tools.jar、policy、Jenkinsfile，加上 OPA
src=~/kafka-lab/landing/tools/cbom
tar -xzf $src/cbom-kit-*.tar.gz -C $dir/cbom --strip-components=1
mv $dir/cbom/cbom-tools.jar $dir/cbom/bin/cbom-tools.jar
cp $src/opa_linux_amd64 $dir/cbom/bin/opa

# 4. 把公鑰送到操作機，給 OS 團隊放進 cbomsvc 的 authorized_keys
podman cp "$(cygpath -m $dir/secrets/cbom_collect_ed25519.pub)" lab-ops02-1:/tmp/jenkins-cbom.pub

ls $dir/cbom $dir/cbom/bin
echo "密碼檔 $(wc -c < $dir/secrets/admin.pass) 個字"
```

```out
/c/Users/<你>/kafka-lab/jenkins/cbom:
Jenkinsfile
VERSIONS
bin
cbom-collect.sh
cbomkit-theia
policy

/c/Users/<你>/kafka-lab/jenkins/cbom/bin:
cbom-tools.jar
opa
密碼檔 24 個字
```

@role 銀行 OS 團隊（lab 由小安代勞） | ops02 | root

操作機這一端：收集腳本要讀的主機清單 `/etc/cbom/cbom.conf`、專用帳號 `cbomsvc`、受限的公鑰、那一條 sudo。`172.35.0.70` 是 lab 裡 Jenkins 的 IP，正式環境換成銀行 Jenkins agent 的 IP。

```bash
jenkins_ip=172.35.0.70

# 1. 收集腳本的主機清單（短名稱，空白隔開）與管理用的連線
mkdir -p /etc/cbom
cat > /etc/cbom/cbom.conf <<'EOF'
DOMAIN=poc.lab
ENV_NAME=lab
CONTROLLERS="kc01 kc02 kc03"
BROKERS="kb01 kb02 kb03 kb04"
RESTS="rest01 rest02"
C3_HOSTS="c3-01"
ADMIN_BOOTSTRAP=kb01.poc.lab:9094
ADMIN_CLIENT_CONF=/root/conf/client-admin.properties
EOF
chmod 644 /etc/cbom/cbom.conf

# 2. 專用帳號：密碼鎖定、只收金鑰
if ! id cbomsvc > /dev/null 2>&1; then
  useradd -m -s /bin/bash cbomsvc
fi

passwd -l cbomsvc > /dev/null

# 3. Jenkins 的公鑰：連進來只會執行收集腳本，只收 Jenkins 的 IP（整行不換行）
install -d -m 700 -o cbomsvc -g cbomsvc /home/cbomsvc/.ssh
forced='sudo /opt/cbom/bin/cbom-collect.sh --from-ssh \"$SSH_ORIGINAL_COMMAND\"'
options="command=\"$forced\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,from=\"$jenkins_ip\""
echo "$options $(cat /tmp/jenkins-cbom.pub)" > /home/cbomsvc/.ssh/authorized_keys
chown cbomsvc:cbomsvc /home/cbomsvc/.ssh/authorized_keys
chmod 600 /home/cbomsvc/.ssh/authorized_keys
rm -f /tmp/jenkins-cbom.pub

# 4. sudo 只開這一條
echo 'cbomsvc ALL=(root) NOPASSWD: /opt/cbom/bin/cbom-collect.sh --from-ssh *' > /etc/sudoers.d/cbomsvc
chmod 440 /etc/sudoers.d/cbomsvc
visudo -cf /etc/sudoers.d/cbomsvc
sudo -l -U cbomsvc | tail -1
cut -d' ' -f1-5 /home/cbomsvc/.ssh/authorized_keys | cut -c1-120
```

```out
/etc/sudoers.d/cbomsvc: parsed OK
    (root) NOPASSWD: /opt/cbom/bin/cbom-collect.sh --from-ssh *
command="sudo /opt/cbom/bin/cbom-collect.sh --from-ssh \"$SSH_ORIGINAL_COMMAND\"",no-pty,no-port-forwarding,no-agent-forw
```

收集腳本會拒絕不認得的元件，也拒絕夾帶其他指令的字串。直接在操作機上試（這兩行都應該被拒絕，所以包在 `if` 裡）：

```bash
if /opt/cbom/bin/cbom-collect.sh --from-ssh 'collect roles=broker; id' 2> /tmp/cbom-reject.txt; then
  echo "不該成功"
else
  echo "夾帶其他指令：拒絕（$(cut -d' ' -f2- /tmp/cbom-reject.txt)）"
fi

if /opt/cbom/bin/cbom-collect.sh --roles nothing 2> /tmp/cbom-reject.txt; then
  echo "不該成功"
else
  echo "不認得的元件：拒絕（$(cut -d' ' -f2- /tmp/cbom-reject.txt)）"
fi

rm -f /tmp/cbom-reject.txt
```

```out
夾帶其他指令：拒絕（失敗：這把金鑰只能執行：collect [roles=a,b] [jfr=秒數]）
不認得的元件：拒絕（失敗：不認得的元件：nothing（可以用的：controller broker rest c3 shared））
```

@role Lab 管理員（扮演銀行的 Jenkins 管理員） | Windows 終端 | 本機

lab 的 Jenkins 映像：官方 LTS 加這條 pipeline 需要的 plugin。啟動時由 `init.groovy.d` 的腳本自動建立管理員帳號、credential `cbom-collect-key`（那把受限金鑰，使用者 `cbomsvc`）、工作 `cbom`（內容是交付物的 `Jenkinsfile`）；正式環境由銀行的 Jenkins 管理員在畫面上做同樣三件事。

```bash
dir=~/kafka-lab/jenkins

cat > $dir/Containerfile <<'EOF'
# lab 的 Jenkins（扮演銀行的 Jenkins）：官方 LTS 映像＋這條 pipeline 需要的 plugin
FROM docker.io/jenkins/jenkins:2.580.2-lts-jdk21
RUN jenkins-plugin-cli --plugins workflow-aggregator credentials-binding ssh-credentials htmlpublisher timestamper
# 不跑安裝精靈：帳號、credential、工作由 init.groovy.d 的腳本在啟動時建立
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Xmx640m"
COPY init.groovy.d/ /usr/share/jenkins/ref/init.groovy.d/
EOF

cat > $dir/init.groovy.d/cbom.groovy <<'EOF'
// lab 的 Jenkins 啟動時自動設定：管理員 admin、credential cbom-collect-key、工作 cbom
import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey
import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.domains.Domain
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy
import hudson.security.HudsonPrivateSecurityRealm
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import org.jenkinsci.plugins.workflow.job.WorkflowJob

def jenkins = Jenkins.get()

def realm = new HudsonPrivateSecurityRealm(false)
realm.createAccount('admin', new File('/run/lab/admin.pass').text.trim())
jenkins.setSecurityRealm(realm)
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
jenkins.setAuthorizationStrategy(strategy)

def store = SystemCredentialsProvider.getInstance().getStore()
def existing = store.getCredentials(Domain.global()).find { it.id == 'cbom-collect-key' }
if (existing != null) {
  store.removeCredentials(Domain.global(), existing)
}
def key = new BasicSSHUserPrivateKey.DirectEntryPrivateKeySource(new File('/run/lab/cbom_collect_ed25519').text)
store.addCredentials(Domain.global(),
  new BasicSSHUserPrivateKey(CredentialsScope.GLOBAL, 'cbom-collect-key', 'cbomsvc', key, '', '操作機的 CBOM 收集入口（受限金鑰）'))

def job = jenkins.getItem('cbom')
if (job == null) {
  job = jenkins.createProject(WorkflowJob, 'cbom')
}
job.setDefinition(new CpsFlowDefinition(new File('/opt/cbom/Jenkinsfile').text, true))
job.save()
jenkins.save()
println 'lab：admin、cbom-collect-key、工作 cbom 已設定'
EOF

podman build -q -t lab-jenkins:1 -f "$(cygpath -m $dir/Containerfile)" "$(cygpath -m $dir)" > /dev/null
podman images --format '{{.Repository}}:{{.Tag}}' | grep '/lab-jenkins:'
```

```out
localhost/lab-jenkins:1
```

啟動。lab 的內部網路 `lab_labnet` 是隔離的（不對外、不做埠對應），所以 Jenkins 和 lb01 一樣接兩個網路：`lab_labnet`（固定 IP，連操作機）與 `lab_frontnet`（把 8080 對應到 Windows 的 18088，給瀏覽器用）。起來之後把操作機的主機金鑰記進 Jenkins 的 `known_hosts`。

```bash
dir=~/kafka-lab/jenkins

# 1. 舊的容器先收掉再啟動
if podman container exists lab-jenkins; then
  podman rm -f lab-jenkins > /dev/null
fi

podman run -d --name lab-jenkins \
  --network lab_labnet:ip=172.35.0.70 --network lab_frontnet \
  --add-host ops02.poc.lab:172.35.0.10 -p 18088:8080 -m 1200m \
  -v "$(cygpath -m $dir/secrets):/run/lab:ro" \
  -v "$(cygpath -m $dir/cbom):/opt/cbom:ro" \
  lab-jenkins:1 > /dev/null

# 2. 等登入頁回 200：每 5 秒看一次，最多 3 分鐘
for i in $(seq 1 36); do
  if curl -s -f -m 4 http://localhost:18088/login > /dev/null; then
    break
  fi

  sleep 5
done

# 3. 操作機的主機金鑰記進 Jenkins 的 known_hosts（之後 ssh 才不會問）
podman exec -i lab-jenkins bash -s <<'EOF'
mkdir -p ~/.ssh
chmod 700 ~/.ssh
keys=$(ssh-keyscan -T 5 ops02.poc.lab 2>/dev/null)
echo "$keys" | grep -v '^#' > ~/.ssh/known_hosts
echo "known_hosts $(wc -l < ~/.ssh/known_hosts) 行"
EOF

podman logs lab-jenkins 2>&1 | grep '^lab：'
```

```out
known_hosts 3 行
lab：admin、cbom-collect-key、工作 cbom 已設定
```

執行工作。這裡用 Jenkins 的 API 觸發與等待，和在畫面上按按鈕是同一件事。工作剛建好、還沒執行過時，Jenkins 還不知道它有參數（參數寫在 `Jenkinsfile` 裡，跑過一次才登記），所以第一次用不帶參數的 `build`，全部是預設值（全選、不錄 JFR）；畫面上第一次也只有「Build Now」，跑過一次才變成「Build with Parameters」。lab 的 10 台約 7–11 分鐘（Jenkins 剛啟動、lab 記憶體吃緊時比較慢）。

```bash
base=http://localhost:18088
pass=$(cat ~/kafka-lab/jenkins/secrets/admin.pass)
# Windows 版的 curl 不認得 /tmp、/dev/null：檔名用 cygpath 轉成 Windows 的寫法，要丟掉的輸出用 > /dev/null（由 shell 處理）
cookies=$(cygpath -m /tmp/cbom-jenkins-cookies.txt)

# 1. Jenkins 的 API 要帶 crumb（防跨站請求）；同一個 cookie 檔之後都用
crumb_json=$(curl -s -c $cookies -u "admin:$pass" $base/crumbIssuer/api/json)
crumb=$(echo "$crumb_json" | grep -o '"crumb":"[^"]*"' | cut -d'"' -f4)

# 2. 記下下一次執行的編號，再觸發（第一次執行：不帶參數的 build）
job_json=$(curl -s -b $cookies -u "admin:$pass" $base/job/cbom/api/json)
number=$(echo "$job_json" | grep -o '"nextBuildNumber":[0-9]*' | cut -d: -f2)
curl -s -b $cookies -u "admin:$pass" -H "Jenkins-Crumb: $crumb" -X POST $base/job/cbom/build > /dev/null

# 3. 等這次執行結束：每 10 秒看一次，最多 20 分鐘
for i in $(seq 1 120); do
  build_json=$(curl -s -b $cookies -u "admin:$pass" $base/job/cbom/$number/api/json)

  if echo "$build_json" | grep -q '"result":"[A-Z]*"'; then
    break
  fi

  sleep 10
done

echo "第 $number 次執行：$(echo "$build_json" | grep -o '"result":"[A-Z]*"')（約 $(( i * 10 )) 秒）"

# 4. 這次執行的重點訊息
log=$(curl -s -b $cookies -u "admin:$pass" $base/job/cbom/$number/consoleText)
echo "$log" | grep -o '這次的範圍.*'
echo "$log" | grep -o 'CBOM（CycloneDX.*'
echo "$log" | grep -o 'PASS: .*'
echo "$log" | grep -o '合規：.*'
```

```out
第 1 次執行："result":"SUCCESS"（約 670 秒）
這次的範圍：controller,broker,rest,c3,shared；執行期證據：不錄
CBOM（CycloneDX 1.7）：150 個元件 {algorithm=23, certificate=9, file=44, library=25, protocol=8, related-crypto-material=41}
PASS: 22/22
合規：沒有違規項目 {"quantum-vulnerable":69,"unknown":0,"violation":0,"warning":3}
```

> 這次沒有錄 JFR，所以元件比 33.8 少（沒有執行期看到的演算法），量子脆弱也少幾個。

三個產出都能從這次執行下載；Jenkins 畫面上的報告用的是樣式放在另一個檔的那一份（`base`、`pass`、`cookies`、`number` 沿用上一塊）：

```bash
dest=~/kafka-lab/cbom-out/jenkins-$number
mkdir -p $dest

# 1. 下載三個產出
for file in cbom.json findings.json report.html; do
  curl -s -f -b $cookies -u "admin:$pass" $base/job/cbom/$number/artifact/out/$file > $dest/$file
done

ls $dest

# 2. 畫面上的報告頁與它的樣式檔（HTML Publisher 把報告名稱編碼成這個路徑）
report=$base/job/cbom/$number/CBOM_20_e59088_e8a68f_e5a0b1_e5918a
curl -s -f -b $cookies -u "admin:$pass" $report/index.html > /tmp/cbom-index.html
curl -s -f -b $cookies -u "admin:$pass" $report/report.css > /tmp/cbom-report.css
linked=$(grep -o 'href="report.css"' /tmp/cbom-index.html | wc -l)
inline=$(grep -o '<style' /tmp/cbom-index.html | wc -l)
echo "報告頁：引用樣式檔 $linked 處，寫在 HTML 裡的樣式 $inline 處"
echo "樣式檔：$(grep -c 'font-family' /tmp/cbom-report.css) 行字型設定（讀得到）"
rm -f /tmp/cbom-index.html /tmp/cbom-report.css
```

```out
cbom.json
findings.json
report.html
報告頁：引用樣式檔 1 處，寫在 HTML 裡的樣式 0 處
樣式檔：1 行字型設定（讀得到）
```

再跑一次部分範圍：只盤 broker，加上 20 秒的執行期證據。跑過一次之後參數已經登記，這次用 `buildWithParameters`；參數就是畫面上那幾個勾選框的名稱（`base`、`pass`、`cookies`、`crumb` 沿用）：

```bash
job_json=$(curl -s -b $cookies -u "admin:$pass" $base/job/cbom/api/json)
number=$(echo "$job_json" | grep -o '"nextBuildNumber":[0-9]*' | cut -d: -f2)
params="CONTROLLER=false&BROKER=true&REST_PROXY=false&CONTROL_CENTER=false&SHARED=false"
params="$params&RUNTIME_EVIDENCE=true&JFR_SECONDS=20"
curl -s -b $cookies -u "admin:$pass" -H "Jenkins-Crumb: $crumb" -X POST \
  --data "$params" $base/job/cbom/buildWithParameters > /dev/null

for i in $(seq 1 120); do
  build_json=$(curl -s -b $cookies -u "admin:$pass" $base/job/cbom/$number/api/json)

  if echo "$build_json" | grep -q '"result":"[A-Z]*"'; then
    break
  fi

  sleep 10
done

echo "第 $number 次執行：$(echo "$build_json" | grep -o '"result":"[A-Z]*"')"
curl -s -f -b $cookies -u "admin:$pass" $base/job/cbom/$number/artifact/out/report.html > /tmp/cbom-partial.html
grep -o '<strong>[^<]*盤點</strong>' /tmp/cbom-partial.html
grep -o '沒有盤到：[^<]*' /tmp/cbom-partial.html
grep -o '執行期證據：[^<]*' /tmp/cbom-partial.html
rm -f /tmp/cbom-partial.html $cookies
```

```out
第 2 次執行："result":"SUCCESS"
<strong>部分盤點</strong>
沒有盤到：controller、REST Proxy、Control Center、平台共用
執行期證據：JFR 20 秒
```

在瀏覽器看：Windows 開 `http://localhost:18088`，帳號 `admin`，密碼在 `~/kafka-lab/jenkins/secrets/admin.pass`。

| 要做什麼 | 在哪裡 |
|---|---|
| 執行 | 工作 `cbom` → 左邊「Build with Parameters」→ 勾選範圍 → Build（工作第一次執行時是「Build Now」） |
| 看報告 | 那一次執行 → 左邊「CBOM 合規報告」 |
| 下載 | 那一次執行的頁面上方「Build Artifacts」：`cbom.json`、`findings.json`、`report.html` |
| 看結果摘要 | 執行清單上每一次的說明：範圍與各等級的數量 |
| 之前的結果 | 最近 30 次執行都留著（`Jenkinsfile` 的 `buildDiscarder`） |

> lab 的 Jenkins 接在 lab 的網路上：要拆 lab（`podman compose down -v`）之前先 `podman rm -f lab-jenkins`，否則網路刪不掉（和第 17 章的 `lab-mon-*` 一樣）。附錄 B.2 的收尾會一起收掉。

## 33.11 交付之後：權限、排程、要確認的事

**cpuser 的 sudo**：安裝期 `cpuser` 有完整的 sudo，交付後只剩 `cpuser-ops` 逐條列出的指令（第 16、19 章）。收集要讀幾個只有 root 讀得到的檔，所以交付後要請 OS 團隊在每台的 `/etc/sudoers.d/cpuser-ops` 加這幾條唯讀的指令（寫法要和收集腳本用的完全一樣，sudoers 比對整個參數）。lab 做這一章時還留著安裝期的 sudo，這幾條在收窄後的 sudoers 下還沒有實測，交付前要在收窄後的環境再跑一次 33.4：

| 主機 | 要加的指令 |
|---|---|
| controller、broker | `/usr/bin/cat /etc/confluent/kafka/server.properties` |
| REST Proxy | `/usr/bin/cat /etc/confluent/kafka-rest/kafka-rest.properties` |
| Control Center | `/usr/bin/cat /etc/confluent/control-center/control-center.properties` |
| 全部 | `/usr/bin/cat /etc/confluent/secrets/security.properties` |
| 全部 | `/usr/bin/cat /etc/confluent/ssl/mds-token-public.pem` |
| 全部 | `/usr/bin/find /etc/confluent/ssl -type f -printf …`（列出金鑰檔的權限、擁有者、大小、路徑，不讀內容；格式字串那一段在 sudoers 的寫法和 OS 團隊定） |

執行期證據（33.7）另外要以服務的帳號執行 `jcmd`，而且 pid 每次重啟都不同，沒辦法逐條寫死；要做的話和 OS 團隊定一個包好的小腳本（只接受 start／dump），sudoers 開那支腳本。沒有這幾條 sudo 時收集腳本會在那一台停下來，不會交出不完整的原料。

**多久做一次**：憑證換發、升級、OS 修補之後各做一次；平常每季一次。Jenkins 可以排程（工作的 Build periodically），執行期證據不要排進定期執行。

**結果怎麼用**：

| 報告上的 | 怎麼處理 |
|---|---|
| 違規 | 當成事件處理：照報告列的主機與原因修正，再跑一次確認歸零 |
| 量子脆弱：憑證 | 等銀行的 CA 能簽後量子演算法的憑證再換；有效期跨過 2030／2035 年的優先（通常是根憑證與簽發憑證，由 CA 團隊規劃） |
| 量子脆弱：金鑰交換 | 伺服器端 JDK 25 已經支援混合金鑰交換；盤點**用戶端**（應用程式的 JDK、librdkafka 版本）是否支援 |
| 警告：TLS 1.2 | 確認所有用戶端都能用 TLS 1.3 之後，把 `ssl.enabled.protocols` 改成只留 `TLSv1.3` |

**要向銀行確認**（已列入「請銀行確認的事項」）：行內 Jenkins 的版本與 plugin、agent 能不能連操作機的 22 埠、可否建立 `cbomsvc` 帳號與那一條 sudo、CBOM 與報告的存放位置與誰能看、接收 CBOM 的系統支援 CycloneDX 1.6 還是 1.7、有沒有指定的後量子規範、執行期證據（JFR）能不能在正式環境做。**要向原廠確認**：Confluent Platform 的 SBOM／CBOM、後量子路線圖。

# B. 附錄 B：監控的覆蓋率，與 lab 監控容器的收尾

這兩節是第 17 章的延伸：B.1 量官方 dashboard 在我們這套元件上有多少 panel 有資料（給銀行監控團隊參考），B.2 是 lab 專用的收尾（正式環境的 Prometheus 是銀行的，不收）。放在最後，是因為量覆蓋率要等整條路（含遷移）跑完才有完整的數字。

## B.1 哪些 dashboard 與 panel 有資料

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

「全部 32 個都放進去」之後，要知道哪些在我們的元件上是活的。下面這段 Python 取出每個 panel 的 PromQL，dashboard 變數換成「All」，對 Prometheus 各查一次（和畫面上選 All 的結果一致），有任何一條 query 回得出序列就算「有資料」：

```bash
cd ~/kafka-lab/bank-monitoring

# 1. 查覆蓋率的小程式（Python，只用標準函式庫）
cat > dashboard-coverage.py <<'EOF'
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

# 2. 在 labnet 上的臨時容器裡跑（這個資料夾唯讀掛成 /w）
podman run --rm --network lab_labnet \
  -v "$(cygpath -m "$PWD"):/w:ro" \
  lab-node:96 \
  python3 /w/dashboard-coverage.py http://lab-mon-prometheus:9090 /w/grafana/provisioning/dashboards
```

```out
dashboard                          panels    有資料  沒資料的 panel
OTel_kafkametrics.json                  5      0  
cluster-linking.json                   19     12  
confluent-audit.json                    6      0  
confluent-oracle-cdc.json              15      0  
confluent-platform-kraft.json          23      8  
confluent-platform.json                26      4  
confluent-rbac.json                    10      7  
debezium-connectors.json               34      0  
flink-jobmanager.json                  27      0  
flink-taskmanager.json                 52      0  
globalktable.json                      24     13  
kafka-cluster-kraft.json               80     67  
kafka-cluster.json                     87     64  
kafka-connect-cluster.json             54      0  
kafka-consumer.json                    25      3  
kafka-lag-exporter.json                 9      3  
kafka-producer.json                    32      3  
kafka-quotas.json                       6      0  
kafka-stream.json                      27     23  
kafka-streams-rocksdb.json             40     39  
kafka-topics-kraft.json                13     13  
kafka-topics.json                      12     10  
kafka-transaction-coordinator.json     10      0  
kraft.json                             18     10  
ksqldb-cluster.json                    38      0  
librdkafka-application.json            52      0  
mongo.json                             25      0  
replicator.json                         6      0  
rest-proxy.json                        10     10  
schema-registry-cluster.json           12      0  
tiered-storage.json                     8      3  
zookeeper-cluster.json                 11      0  
合計 32 個 dashboard、816 個 panel、292 個有資料
```

怎麼讀這張表（2026-10-29 在**遷移完成後**的 lab 實測；2026-10-31 在 Podman 上從零重跑到遷移、OS 9.8 之後再量，數字完全相同；2026-11-08 從零重跑時 C3 的 Streams 規則已調整（17.2），只有 `kafka-stream.json`、`globalktable.json` 少了執行緒數的 panel（見下表），其餘相同——Confluent Server 8.3.2、C3 2.6.1，3 台 controller、4 台 broker、2 台 REST Proxy、1 台 C3，第 18 章的稽核已開。和安裝基底 8.2.4／C3 2.5.1 時量的比，只有 C3 Streams 那三張變了（17.2 改收 Kafka Streams），其餘各列相同；**Tiered Storage 沒開，要在正式叢集上補驗**）：

| dashboard（檔名） | 有資料／總數 | 判讀 |
|---|---|---|
| `kraft.json` | 10／18 | **部分**。有值的 panel 用的是不靠 raft 的指標；空的 8 個全靠 `kafka_server_raft_metrics_*`：Health、Current Leader、Current Epoch、Maximum time spent on electing a new leader、Append Records Rate、Average time spent to commit an entry in the raft log、Fetch Record Rate（兩個），因為三台 controller 的叢集 Prometheus 裡沒有任何 raft 指標（見 B.2 的備註）。看 quorum 用 `kafka-metadata-quorum describe --status` |
| `kafka-cluster-kraft.json` | 67／80 | **可用**（主力）。這輪缺 13 個，其中能確定原因的有：「Offline Partitions Count」——官方 query 寫 `job="kafka-broker"`，但專用 controller 的叢集裡這個指標只在 `kafka-controller` 上，所以空（告警 `KafkaOfflinePartitions` 有涵蓋）；另 4 個是 Tiered Storage（我們沒開） |
| `kafka-topics-kraft.json` | 13／13 | **可用**。topic 大小、流量、partition |
| `kafka-transaction-coordinator.json` | 0／10 | **空**。這輪沒有應用程式使用交易（transaction），coordinator 沒有活動；有交易型應用之後再看 |
| `rest-proxy.json` | 10／10 | **可用**。每個 REST endpoint 的請求率、錯誤、延遲 |
| `confluent-audit.json` | 0／6（第 18 章稽核已啟用） | **空**。官方規則要的 MBean `kafka.server:type=confluent-audit-metrics` 在 8.3.2 的 broker 上不存在（2026-10-31 用 jshell attach 到 broker 列出全部 5,452 個 MBean 確認），稽核只以 producer `confluent-event-logger` 出現；稽核是否在寫看第 18 章的 topic 與選單 43。之前寫的「啟用後 5／6」無法重現，已刪 |
| `confluent-platform-kraft.json` | 8／23 | **部分**。總覽裡 broker、controller 的部分有值；Schema Registry、Connect、ksqlDB 區塊是空的（我們沒有這些元件） |
| `kafka-topics.json`、`kafka-cluster.json`、`confluent-platform.json` | 10／12、64／87、4／26 | **用 KRaft 版就好**。這三張是 ZooKeeper 時代的版本；「Total # of Topics」「Active Controllers」「Offline Partitions」等 panel 同樣寫 `job="kafka-broker"`，在專用 controller 的 KRaft 叢集裡是空的 |
| `kafka-consumer.json`、`kafka-producer.json`、`kafka-lag-exporter.json` | 3／25、3／32、3／9 | **部分／要另外接**。這幾張要應用程式（或 lag exporter）自己掛 exporter；只有 broker 端看得到的少數 panel 有值。consumer lag 請看 C3 畫面 |
| `cluster-linking.json`、`tiered-storage.json` | 12／19、3／8 | 沒開這兩個功能，有值的是不分功能的計數（多數是 0） |
| `kafka-quotas.json` | 0／6 | **有流量才有值**。`kafka_server_produce_byte_rate{user=…}` 這類序列來自 `kafka.server:type=Produce,user=…`，只在設了配額的帳號正在傳資料時存在，閒置約一小時就消失；lab 量的時候沒有應用程式流量（設了配額的帳號都在，2026-10-31 確認 MBean 也不在）。正式叢集有流量時應該有值，上線後再看一次 |
| `confluent-rbac.json` | 7／10 | **大部分可用**。MDS 與 RBAC 開著，授權相關的計數有值；其餘 3 個沒有查明原因 |
| `kafka-stream.json`、`globalktable.json`、`kafka-streams-rocksdb.json` | 23／27、13／24、39／40 | **C3 自己的 Kafka Streams**（17.2：C3 收 `kafka.streams:*`，套官方 `kafka_streams.yml` 規則，約 2,100 條序列）。選 `job=control-center` 就看到 C3 的 thread、task、RocksDB store（`AlertHistoryStore`、`commander`）。空的 panel 有兩種：`task_created_total`、`number_file_errors_total` 是 JMX exporter 1.x 會把 gauge 名稱結尾的 `_total` 拿掉（OpenMetrics 規定 `_total` 只給 counter），官方 dashboard 還用舊名；「Alive Stream Threads」「Failed Stream Threads」「Alive/Failed Stream Threads」三個是官方規則把執行緒數放在**標籤**裡（數字一變就多一條新序列，舊的留到過期），我們的 `rules-c3.yml` 改成數值指標 `kafka_streams_stream_metrics_alive_stream_threads`／`_failed_stream_threads`，告警 `ControlCenterStreamThreadsFailed` 用的就是它，要看這個數字直接在 Grafana 查這兩個指標。globalktable 其他空的 10 個是 C3 沒有用到的 GlobalKTable、cache 類指標。銀行目前沒有自己的 Kafka Streams 應用（2026-10-30 確認），所以這幾張看的只有 C3；之後若有，應用程式掛同一份規則就能看 |
| `kafka-connect-cluster.json`、`confluent-oracle-cdc.json`、`mongo.json`、`debezium-connectors.json`、`replicator.json` | 全 0 | **空**。沒有 Connect |
| `ksqldb-cluster.json`、`schema-registry-cluster.json` | 0／38、0／12 | **空**。沒有 ksqlDB、Schema Registry |
| `flink-jobmanager.json`、`flink-taskmanager.json`、`librdkafka-application.json`、`OTel_kafkametrics.json`、`zookeeper-cluster.json` | 全 0 | **空**。沒有 Flink、librdkafka 應用、OTel kafkametrics 來源、ZooKeeper |

## B.2 收尾：收掉 lab 的監控容器與 Jenkins

@role 銀行監控團隊（lab 由 Lab 管理員扮演） | Windows 終端 | 本機

驗完把 lab 的五個監控容器收掉（第 17 章的四個加上第 22 章的 blackbox）（正式環境是銀行的系統，不收）。設定資料夾 `~/kafka-lab/bank-monitoring` 留著；重建 lab（第 0 章 `down -v`）之前一定要先收，否則容器還接在 labnet 上，網路刪不掉：

```bash
podman rm -f lab-mon-prometheus lab-mon-alertmanager lab-mon-grafana lab-mon-webhook lab-mon-blackbox > /dev/null
echo "lab-mon-* 已收掉：$(podman ps -a --format '{{.Names}}' | grep -c '^lab-mon-') 個剩下"

# 第 33 章的 lab Jenkins 也接在 lab 的網路上（沒做 33.10 就沒有這個容器，--ignore 讓它不算錯）
podman rm -f --ignore lab-jenkins > /dev/null
echo "lab-jenkins 已收掉：$(podman ps -a --format '{{.Names}}' | grep -c '^lab-jenkins$') 個剩下"
```

```out
lab-mon-* 已收掉：0 個剩下
lab-jenkins 已收掉：0 個剩下
```

> 兩件事要跟銀行講清楚：(1) exporter 的 YAML 沒有明文密碼（keystore 密碼在 root 0600 的 `/etc/confluent/jmx-exporter.env`，YAML 裡也沒有帳密：7071 只做 HTTPS，存取控制靠防火牆只放行 Prometheus），YAML 維持 root:confluent 0640；(2) consumer lag 不是 broker 的 JMX 指標，要看 C3（畫面）或另外接 lag exporter；Grafana 的 `kafka-consumer.json`、`kafka-lag-exporter.json` 要有對應來源才有資料。
>
> 監控的邊界：這一章是**主機與程序層**的監控（程序在不在、KRaft 健不健康、partition 狀態、延遲、JVM）。C3 內建 Prometheus 收的 telemetry（`confluent_kafka_server_*`）只給 C3 畫面，不拿來告警（銀行沒有 Prometheus 時，第 32 章讓內建 Prometheus 改抓 JMX exporter 來告警）；license 到期用第 26 章、憑證到期用第 22 章的 syslog 告警；稽核事件看第 18 章。
>
> KRaft 指標：Confluent Server 的 `kafka_server_raft_metrics_*`（current_leader、number_of_voters、commit／election latency 等）**只有單台 controller（`--standalone`）的環境抓得到**。三台 controller 的叢集，不論 8.2.4 或遷移後的 8.3.2，實測 controller job 有三千多條序列，raft 指標卻是 0 條。所以 quorum 健康靠 controller 自己的四個指標：`ActiveControllerCount`（全叢集剛好 1）、`LastAppliedRecordLagMs`、`MetadataErrorCount`、`NewActiveControllersCount`（leader 更換次數）；quorum 內容用 `kafka-metadata-quorum describe --status` 看。官方 `kraft.json` 這張 dashboard 因此只有一部分有值（實測 10／18），其餘靠 raft 指標的 panel 是空的。

