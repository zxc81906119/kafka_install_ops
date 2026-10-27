#!/usr/bin/env bash
# install/lab/bank-sim.sh — lab 專用：在 Windows Git Bash 扮演「銀行」，做手把手文件裡橘色標籤的事。
# 正式環境沒有這支；安裝腳本只會印「請銀行做」。lab 依 docs/journey-src/journey.md 第 0 章建好（~/kafka-lab）。
#   bash bank-sim.sh landing-layout 把舊的落地區版面（8.3.2 在 rpm/、8.2.4 在 landing-extra/）整理成 rpm/ = 基底、rpm-target/ = 目標
#   bash bank-sim.sh push      把 install/ 送到 ops02（root，/root/install）與 dl01（root）
#   bash bank-sim.sh os-content 3.2 銀行 OS 團隊備 OS 內容（拋棄式容器）：~/kafka-lab/bank-os/9.6（安裝基底的完整套件庫）、9.8-updates（9.6 主機升 9.8 需要的更新）、9.8（兩者合併的套件庫）
#   bash bank-sim.sh intake    2.2 檔案交換：落地區 → ops02 ~/landing（唯讀）
#   bash bank-sim.sh prepare   3.1 各主機建 cpuser＋sshd 設定＋公鑰（from=）＋安裝期 sudo、3.2 OS 套件庫＋根憑證信任、3.4 AD、3.5 NTP 與 LB
#   bash bank-sim.sh sign      9.2 銀行 CA 簽 ops02 ~/pki/requests/*.csr → ~/pki/incoming/
#   bash bank-sim.sh os-sync   26.5 銀行把套件庫同步到 OS_TARGET_VERSION（9.8）：把 os/9.8 換上 repo01 的 /os/
#   bash bank-sim.sh reset     down -v 後重新 up（從零）；dl01 保留
set -euo pipefail
export MSYS_NO_PATHCONV=1
LAB=${LAB:-$HOME/kafka-lab}; INSTALL=$(cd "$(dirname "$0")/.." && pwd)
source "$INSTALL/conf/site.env"
container_of() { echo "lab-$1-1"; }          # 主機短名 → lab 的容器名稱
windows_path() { cygpath -m "$1"; }       # Git Bash 路徑 → docker 看得懂的 Windows 路徑
as_root_on() { docker exec "$(container_of "$1")" bash -c "$2"; }   # 在某台主機以 root 跑一段指令（扮演銀行的 OS 團隊）
as_root_on_ops() {   # 在操作機以 root 跑一段指令（人員經 PSMP 登入操作機就是 root；lab 直接 docker exec 進去）
  docker exec -w /root "$(container_of "$OPS_HOST")" bash -c "$1"; }
announce() { printf '\n[bank] %s\n' "$*"; }
NODE_IMAGE=${NODE_IMAGE:-lab-node:96}   # 主機映像（手把手 0.5.1）；9.6 的 tag 和舊的 9.8 映像分開，才不會誤用舊映像
OS_DIR=$LAB/bank-os                     # 銀行套件庫的內容（不是我們交付的檔案，所以不在落地區）：9.6（基底）、9.8-updates（更新集合）、9.8（合併後的完整套件庫）

# 落地區版面（遷移主線）：rpm/ = 安裝基底、rpm-target/ = 遷移目標、bank/ = 兩個 JDK、c3/ = 第 27 章帶進來的單一 C3 版本、os/ = 銀行套件庫的內容（lab 才有）。
# 舊版面（8.3.2 在 rpm/、8.2.4 在 ~/kafka-lab/landing-extra/）整理成新版面；已經是新版面就什麼都不做。只搬檔案，不下載、不刪下載好的東西
landing_layout() {
  local landing=$LAB/landing extra=$LAB/landing-extra file
  announce "落地區版面：rpm/（$CP_VERSION）、rpm-target/（$CP_TARGET_VERSION）、bank/（JDK $JDK_MAJOR、$JDK_TARGET_MAJOR）"
  mkdir -p "$landing/rpm" "$landing/rpm-target" "$landing/bank"
  # 目標版本的檔案如果還在 rpm/（舊版面）：搬到 rpm-target/
  for file in "$landing"/rpm/*-"$CP_TARGET_VERSION"-1.* "$landing"/rpm/confluent-control-center-next-gen-"$C3_TARGET_VERSION"-1.*; do
    [ -f "$file" ] && mv "$file" "$landing/rpm-target/" && echo "rpm/ → rpm-target/：$(basename "$file")"
  done
  # landing-extra（舊的升級演練起點）的 8.2.4 與 JDK 25 併進來；用不到的舊 JDK 21 小版本留在原地
  if [ -d "$extra" ]; then
    for file in "$extra"/rpm/*-"$CP_VERSION"-1.*; do [ -f "$file" ] && [ ! -e "$landing/rpm/$(basename "$file")" ] && mv "$file" "$landing/rpm/" && echo "landing-extra/rpm → rpm/：$(basename "$file")"; done
    for file in "$extra"/bank/OpenJDK"$JDK_TARGET_MAJOR"U-*; do [ -f "$file" ] && [ ! -e "$landing/bank/$(basename "$file")" ] && mv "$file" "$landing/bank/" && echo "landing-extra/bank → bank/：$(basename "$file")"; done
    rmdir "$extra/rpm" "$extra/bank" "$extra" 2>/dev/null || echo "landing-extra 還剩 $(find "$extra" -type f | wc -l) 個檔（舊版 JDK 等，不會再用到；確認後可整個刪掉）"
  fi
  echo "rpm/ $(ls "$landing"/rpm | wc -l) 個、rpm-target/ $(ls "$landing"/rpm-target | wc -l) 個（01 站會補齊 C3 與缺的檔案）"
}

push() {
  announce "install/ → $OPS_HOST:/root/install、dl01:/root/install"
  as_root_on "$OPS_HOST" 'rm -rf /root/install'; docker cp "$(windows_path "$INSTALL")" "$(container_of "$OPS_HOST"):/root/install"
  as_root_on "$OPS_HOST" 'chmod +x /root/install/install.sh /root/install/steps/*.sh && ls /root/install/steps | wc -l'
  docker exec dl01 rm -rf /root/install; docker cp "$(windows_path "$INSTALL")" dl01:/root/install; docker exec dl01 bash -c 'chmod +x /root/install/steps/*.sh; ls /root/install/steps | wc -l'
}

intake() {
  announce "2.2 檔案交換：$LAB/landing → $OPS_HOST:~/landing（唯讀）"
  as_root_on "$OPS_HOST" 'install -d /root/landing'
  docker cp "$(windows_path "$LAB/landing")/." "$(container_of "$OPS_HOST"):/root/landing/"
  as_root_on "$OPS_HOST" 'chmod -R a-w /root/landing && echo "$(find /root/landing -type f | wc -l) files, $(du -sh /root/landing | cut -f1)"'
}

PVWA_DIR=$LAB/pvwa   # PVWA 資料夾：lab 用它扮演 PVWA（平台密碼的正本；ssh 私鑰不放這裡）

# 3.1 OS 團隊在一台主機上做的事（以 root）：建 cpuser、sshd 設定、公鑰行、安裝期 sudo。參數：主機短名、authorized_keys 的整行
os_team_cpuser() {
  local host=$1 line=$2
  docker exec -i -e LINE="$line" -e CPID="$SSH_USER_ID" -e CPUSER="$SSH_USER" "$(container_of "$host")" bash -s <<'BANK'
set -e
getent group "$CPUSER" >/dev/null || groupadd -g "$CPID" "$CPUSER"
id "$CPUSER" >/dev/null 2>&1 || useradd -u "$CPID" -g "$CPID" -m -s /bin/bash "$CPUSER"
printf 'Match User %s\n    PasswordAuthentication no\n    AuthenticationMethods publickey\n' "$CPUSER" > /etc/ssh/sshd_config.d/50-cpuser.conf
sshd -t && systemctl reload sshd
install -d -m 0700 -o "$CPUSER" -g "$CPUSER" "/home/$CPUSER/.ssh"
printf '%s\n' "$LINE" > "/home/$CPUSER/.ssh/authorized_keys"
chown "$CPUSER:$CPUSER" "/home/$CPUSER/.ssh/authorized_keys"; chmod 0600 "/home/$CPUSER/.ssh/authorized_keys"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$CPUSER" > "/etc/sudoers.d/$CPUSER"; chmod 0440 "/etc/sudoers.d/$CPUSER"; visudo -cf "/etc/sudoers.d/$CPUSER" >/dev/null
BANK
}

# 3.2 / 26.5：銀行 OS 團隊備 OS 內容。全部在拋棄式容器（$NODE_IMAGE，乾淨的 9.6）裡做，結果放 ~/kafka-lab/bank-os/（銀行的東西，不經檔案交換進操作機）：
#   os/9.6          平台要用的 OS 套件（chrony、firewalld、cyrus-sasl…加相依）＋索引；用 Rocky vault 的 9.6 內容（預設的 repo 會跟著最新小版本走，不能用）
#   os/9.8-updates  「9.6 主機（裝了上面那些套件）升到 9.8 要的更新」：在容器裡把 9.6 套件裝起來，再對 pub/rocky/9.8 做 dnf update --downloadonly
#   os/9.8          上面兩者合併＋索引 = 銀行把套件庫同步到 9.8 之後的樣子（os-sync 用）
# 先下載、再裝工具（順序反了會漏掉工具自己的相依）。已經備好的不重做。
os_content() {
  local base=$OS_BASE_VERSION target=$OS_TARGET_VERSION
  if [ -f "$OS_DIR/$target/repodata/repomd.xml" ] && [ -f "$OS_DIR/$base/repodata/repomd.xml" ]; then announce "OS 內容已備好：$OS_DIR（$base、$target-updates、$target）"; return 0; fi
  announce "OS 內容：$base 完整套件庫、$base→$target 更新集合（拋棄式容器 lab-mig-oscontent，用完即刪）"
  rm -rf "$OS_DIR"; mkdir -p "$OS_DIR"
  docker rm -f lab-mig-oscontent >/dev/null 2>&1
  docker run --rm --name lab-mig-oscontent -e BASE="$base" -e TARGET="$target" -v "$(windows_path "$OS_DIR"):/out" "$NODE_IMAGE" bash -c '
set -e
BASE_REPOS="--disablerepo=* --enablerepo=vault${BASE//./}-baseos,vault${BASE//./}-appstream,vault${BASE//./}-extras"
t0=$(date +%s)
ok=0; for try in 1 2 3; do dnf -q $BASE_REPOS download --resolve --arch x86_64 --arch noarch --destdir /out/$BASE/Packages chrony firewalld cyrus-sasl openssl-devel httpd mod_ssl python3-dnf-plugin-versionlock nmap-ncat jq gettext openldap-clients createrepo_c tar gzip openssl sudo openssh-server diffutils less vim-minimal bind-utils lsof procps-ng rsync bash-completion && { ok=1; break; }; echo "鏡像站還沒同步好，60 秒後重試（第 $try 次）" >&2; dnf -q clean metadata; sleep 60; done; [ $ok = 1 ]
# 工具與「已裝好這批套件的 9.6 主機」是同一件事：全部從剛下載的檔案裝
dnf -q -y --disablerepo="*" install /out/$BASE/Packages/*.rpm >/dev/null 2>&1
createrepo_c -q /out/$BASE
echo "$BASE：$(ls /out/$BASE/Packages | wc -l) 個 RPM，$(du -sm /out/$BASE | cut -f1) MB，$(( $(date +%s) - t0 )) 秒"
t0=$(date +%s)
printf "[r-target-baseos]\nname=Rocky $TARGET BaseOS\nbaseurl=https://dl.rockylinux.org/pub/rocky/$TARGET/BaseOS/\$basearch/os/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\nenabled=1\n[r-target-appstream]\nname=Rocky $TARGET AppStream\nbaseurl=https://dl.rockylinux.org/pub/rocky/$TARGET/AppStream/\$basearch/os/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\nenabled=1\n[r-target-extras]\nname=Rocky $TARGET extras\nbaseurl=https://dl.rockylinux.org/pub/rocky/$TARGET/extras/\$basearch/os/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\nenabled=1\n" > /etc/yum.repos.d/rocky-target.repo
TARGET_REPOS="--disablerepo=* --enablerepo=r-target-baseos,r-target-appstream,r-target-extras"
mkdir -p /out/$TARGET-updates/Packages /tmp/dl
# keepcache：dnf 裝完會把下載的檔從下載目錄刪掉；這裡只下載不安裝，仍然先複製一份再建索引
dnf -q -y $TARGET_REPOS --setopt=keepcache=1 update --downloadonly --downloaddir /tmp/dl >/dev/null 2>&1
cp -a /tmp/dl/. /out/$TARGET-updates/Packages/
createrepo_c -q /out/$TARGET-updates
echo "$TARGET-updates：$(ls /out/$TARGET-updates/Packages | wc -l) 個 RPM，$(du -sm /out/$TARGET-updates | cut -f1) MB，$(( $(date +%s) - t0 )) 秒"
mkdir -p /out/$TARGET/Packages && cp -a /out/$BASE/Packages/. /out/$TARGET/Packages/ && cp -a /out/$TARGET-updates/Packages/. /out/$TARGET/Packages/ && createrepo_c -q /out/$TARGET
echo "$TARGET（合併）：$(ls /out/$TARGET/Packages | wc -l) 個 RPM"'
}

# 26.5（lab）：銀行把套件庫同步到 OS_TARGET_VERSION：os/9.8 換上 repo01 的 /os/（正式環境是 Satellite／Nexus 同步，或 reposync 後 createrepo）
os_sync() {
  [ -f "$OS_DIR/$OS_TARGET_VERSION/repodata/repomd.xml" ] || { echo "$OS_DIR/$OS_TARGET_VERSION 沒有：先 bash bank-sim.sh os-content"; return 1; }
  announce "26.5 銀行套件庫同步到 $OS_TARGET_VERSION：$(ls "$OS_DIR/$OS_TARGET_VERSION/Packages" | wc -l) 個 RPM"
  as_root_on "$REPO_HOST" 'rm -rf /var/www/repo/os/*'
  docker cp "$(windows_path "$OS_DIR/$OS_TARGET_VERSION")/." "$(container_of "$REPO_HOST"):/var/www/repo/os/"
  as_root_on "$REPO_HOST" 'chown -R repodeploy:repodeploy /var/www/repo/os; ls /var/www/repo/os/Packages | wc -l'
}

prepare() {
  # 3.1：操作機（root）已在 /secure/ssh 產生金鑰對（第 3 站）。公鑰行 = from="<操作機 IP>,127.0.0.1,::1" + 公鑰；
  # OS 團隊在每台主機（含操作機自己）建 cpuser 並放這一行；repo01 的 repodeploy 放同一行
  local ops_ip public_key from_addrs line host
  public_key=$(docker exec "$(container_of "$OPS_HOST")" cat "$SSH_KEY.pub" 2>/dev/null) || { echo "操作機上沒有 $SSH_KEY.pub：先跑第 3 站（bash install/install.sh --to 03）讓它產生金鑰"; return 1; }
  ops_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(container_of "$OPS_HOST")")
  from_addrs=${SSH_FROM_ADDRS:-$ops_ip,127.0.0.1,::1}
  line="from=\"$from_addrs\" $public_key"
  announce "3.1 OS 團隊：每台主機（含 $OPS_HOST）建 $SSH_USER（UID $SSH_USER_ID）、sshd 只收金鑰、公鑰行 from=\"$from_addrs\"、安裝期 sudo"
  for host in $ALL_HOSTS; do os_team_cpuser "$host" "$line" && printf '%s ' "$host"; done; echo
  announce "3.1 套件庫 $REPO_HOST：$REPO_DEPLOY_USER 放同一行公鑰"
  docker exec -i -e LINE="$line" "$(container_of "$REPO_HOST")" bash -c 'install -d -m 0700 -o repodeploy -g repodeploy /home/repodeploy/.ssh && printf "%s\n" "$LINE" > /home/repodeploy/.ssh/authorized_keys && chown repodeploy:repodeploy /home/repodeploy/.ssh/authorized_keys && chmod 0600 /home/repodeploy/.ssh/authorized_keys && ls -l /home/repodeploy/.ssh/authorized_keys'

  # repo01 的 HTTPS 憑證要驗得過 ca/root.crt：手把手第 20 章演練過換 CA 的 lab，repo.crt 會是 G2／G3 簽的，用現在的 CA 重簽
  local repo_tls=$LAB/images/web/tls
  if ! openssl verify -CAfile "$(windows_path "$LAB/ca/root.crt")" -untrusted "$(windows_path "$repo_tls/repo.crt")" "$(windows_path "$repo_tls/repo.crt")" >/dev/null 2>&1; then
    announce "3.2 套件庫管理員：repo01 的 HTTPS 憑證驗不過目前的根（之前換過 CA），用現在的 CA 重簽"
    openssl req -new -key "$(windows_path "$repo_tls/repo.key")" -out "$(windows_path "$repo_tls/repo.csr")" -subj "/CN=repo01.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:repo01.poc.lab,DNS:repo01" -addext "extendedKeyUsage=serverAuth" 2>/dev/null
    bash "$LAB/ca/sign.sh" "$repo_tls/repo.csr" "$repo_tls/repo.crt" && rm -f "$repo_tls/repo.csr"
    docker exec "$(container_of repo01)" systemctl restart httpd
  fi

  announce "3.2 OS 套件庫（repo01 /os/）：$OS_BASE_VERSION 的完整內容（$OS_DIR/$OS_BASE_VERSION；沒有就先備）"
  [ -f "$OS_DIR/$OS_BASE_VERSION/repodata/repomd.xml" ] || os_content
  as_root_on "$REPO_HOST" 'rm -rf /var/www/repo/os/*'
  docker cp "$(windows_path "$OS_DIR/$OS_BASE_VERSION")/." "$(container_of "$REPO_HOST"):/var/www/repo/os/"
  as_root_on "$REPO_HOST" 'chown -R repodeploy:repodeploy /var/www/repo/os; ls /var/www/repo/os; ls /var/www/repo/os/Packages | wc -l'
  announce "3.2 根憑證進每台主機的信任清單 + bank-os.repo"
  for h in $ALL_HOSTS; do
    docker cp "$(windows_path "$LAB/ca/root.crt")" "$(container_of "$h"):/etc/pki/ca-trust/source/anchors/bank-root.pem"
    as_root_on "$h" 'update-ca-trust && printf "[bank-os]\nname=Bank OS packages\nbaseurl='"$REPO_URL"'/os/\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\n" > /etc/yum.repos.d/bank-os.repo && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9' && printf '%s ' "$h"
  done; echo

  announce "3.4 AD 團隊：OU、群組、svc-mds-bind、alice/bob/carol；LDAPS 憑證；密碼交付"
  for i in $(seq 1 30); do as_root_on "$AD_HOST" 'samba-tool user list >/dev/null 2>&1' && break; sleep 5; done
  if as_root_on "$AD_HOST" 'samba-tool ou list 2>/dev/null | grep -qE "^OU=Confluent(,|$)"'; then echo "AD 物件已存在，略過建立"; else
    as_root_on "$AD_HOST" 'install -d -m 0700 /root/secrets && for k in bind users; do [ -s /root/secrets/$k.pass ] && continue; until p=$(openssl rand -base64 24 | tr -dc "A-Za-z0-9" | head -c 20); [[ $p =~ [A-Z] && $p =~ [a-z] && $p =~ [0-9] ]]; do :; done; (umask 077; printf "%s" "$p" > /root/secrets/$k.pass); done; B=DC=corp,DC=poc,DC=lab; samba-tool ou create "OU=Confluent,$B" && for ou in Users Groups Service; do samba-tool ou create "OU=$ou,OU=Confluent,$B"; done && samba-tool user create svc-mds-bind "$(cat /root/secrets/bind.pass)" --userou="OU=Service,OU=Confluent" --description="read-only LDAP bind for Confluent MDS" && for g in kafka-admins kafka-operators kafka-devs; do samba-tool group add "$g" --groupou="OU=Groups,OU=Confluent"; done && for p in alice:kafka-admins bob:kafka-operators carol:kafka-devs; do u=${p%%:*}; g=${p#*:}; samba-tool user create "$u" "$(cat /root/secrets/users.pass)" --userou="OU=Users,OU=Confluent" && samba-tool group addmembers "$g" "$u" || exit 1; done; samba-tool group listmembers kafka-admins' | grep -v '^User\|^Added\|^$' || { echo "AD 測試帳號建立失敗（看上面的 samba-tool 訊息）"; exit 1; }
  fi
  as_root_on "$AD_HOST" 'mkdir -p /root/csr && cd /root/csr && [ -f ad01.csr ] || openssl req -new -newkey rsa:2048 -nodes -keyout ad01.key -out ad01.csr -subj "/CN=ad01.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:ad01.poc.lab,DNS:ad01" -addext "keyUsage=digitalSignature,keyEncipherment" -addext "extendedKeyUsage=serverAuth" 2>/dev/null; echo csr-ok'
  mkdir -p "$LAB/ca/exchange"
  docker cp "$(container_of "$AD_HOST"):/root/csr/ad01.csr" "$(windows_path "$LAB/ca/exchange/ad01.csr")"
  bash "$LAB/ca/sign.sh" "$LAB/ca/exchange/ad01.csr" "$LAB/ca/exchange/ad01-chain.crt"
  docker cp "$(windows_path "$LAB/ca/exchange/ad01-chain.crt")" "$(container_of "$AD_HOST"):/var/lib/samba/private/tls/cert.pem"
  docker cp "$(windows_path "$LAB/ca/root.crt")" "$(container_of "$AD_HOST"):/var/lib/samba/private/tls/ca.pem"
  as_root_on "$AD_HOST" 'cp /root/csr/ad01.key /var/lib/samba/private/tls/key.pem && chmod 600 /var/lib/samba/private/tls/key.pem && chmod 644 /var/lib/samba/private/tls/cert.pem /var/lib/samba/private/tls/ca.pem && pkill -x samba; sleep 8; openssl s_client -connect localhost:636 -CAfile /var/lib/samba/private/tls/ca.pem </dev/null 2>/dev/null | grep "Verify return code"'
  as_root_on "$OPS_HOST" 'install -d -m 0700 /root/secrets'
  for k in bind:ldap-bind users:ad-test-users; do
    docker exec "$(container_of "$AD_HOST")" cat "/root/secrets/${k%%:*}.pass" | docker exec -i "$(container_of "$OPS_HOST")" bash -c "umask 077; cat > /root/secrets/${k#*:}.pass"
  done
  as_root_on "$OPS_HOST" 'ls -la /root/secrets | tail -n +4'

  announce "3.5 NTP（repo01 兼任）與負載平衡（lb01 nginx L4）"
  install -m 0755 "$INSTALL/lab/lb-member.sh" "$LAB/lb-member.sh"   # 3.5：LB 團隊停用／恢復 REST 成員（手把手 12.1 的五步）
  as_root_on "$REPO_HOST" 'printf "[bank-os]\nname=Bank OS packages\nbaseurl=file:///var/www/repo/os/\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\n" > /etc/yum.repos.d/bank-os.repo; rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9; dnf -q -y --disablerepo="*" --enablerepo=bank-os install chrony >/dev/null && printf "local stratum 10\nallow 172.35.0.0/24\ndriftfile /var/lib/chrony/drift\n" > /etc/chrony.conf && systemctl enable --now chronyd >/dev/null 2>&1; systemctl restart chronyd; sleep 2; echo "chronyd $(systemctl is-active chronyd)"'
  as_root_on "$LB_HOST" 'mkdir -p /etc/nginx/stream.d && printf "upstream cp_rest {\n    hash \$remote_addr consistent;\n    server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s;\n    server rest02.poc.lab:8082 max_fails=2 fail_timeout=10s;\n}\nserver { listen 8082; proxy_pass cp_rest; proxy_connect_timeout 3s; proxy_timeout 10m; }\nupstream cp_c3 { server c3-01.poc.lab:9021 max_fails=2 fail_timeout=10s; }\nserver { listen 9021; proxy_pass cp_c3; proxy_connect_timeout 3s; proxy_timeout 1h; }\n" > /etc/nginx/stream.d/cp.conf && nginx -t 2>&1 | tail -1 && nginx -s reload'
}

sign() {
  announce "9.2 CA 窗口：簽 ops02 ~/pki/requests/*.csr → ~/pki/incoming/"
  mkdir -p "$LAB/ca/exchange/signed"; rm -rf "$LAB/ca/exchange/requests"
  docker cp "$(container_of "$OPS_HOST"):/root/pki/requests" "$(windows_path "$LAB/ca/exchange/")"
  for f in "$LAB"/ca/exchange/requests/*.csr; do n=$(basename "$f" .csr); bash "$LAB/ca/sign.sh" "$f" "$LAB/ca/exchange/signed/$n.crt"; done
  for f in "$LAB"/ca/exchange/signed/*.crt; do docker cp "$(windows_path "$f")" "$(container_of "$OPS_HOST"):/root/pki/incoming/"; done
  as_root_on "$OPS_HOST" 'ls /root/pki/incoming | wc -l'
}

reset() {
  monitoring_stop >/dev/null 2>&1 || true   # 監控容器接在 lab_labnet 上，不先收掉 down -v 刪不掉網路
  announce "lab 從零：down -v（volume 全刪，落地區 $LAB/landing 保留）→ up -d"
  (cd "$LAB" && docker compose -f compose.yml down -v --remove-orphans 2>&1 | tail -1; docker compose -f compose.yml up -d 2>&1 | grep -c Started || true)
  sleep 5; (cd "$LAB" && docker compose -f compose.yml up -d 2>&1 | grep -c Started || true)   # lb01 第一次有時沒起來
  docker start dl01 >/dev/null 2>&1 || true
  docker ps --format '{{.Names}}' | grep -c '^lab-\|^dl01$'
}

monitoring_stop() {   # 17.6（lab）：收掉銀行端的監控容器（Prometheus、Alertmanager、Grafana、webhook 接收端）；設定目錄留著
  docker rm -f lab-mon-prometheus lab-mon-alertmanager lab-mon-grafana lab-mon-webhook 2>/dev/null | tr '\n' ' '; echo "（已收掉）"
}

monitoring() {   # 17.6（lab）：銀行監控團隊用小安給的 to-bank/ 起 Prometheus、Alertmanager、Grafana，再加一個印出收到什麼的 webhook 接收端
  announce "17.6 監控團隊：載入 to-bank/ 的設定，起 lab-mon-prometheus、lab-mon-alertmanager、lab-mon-grafana、lab-mon-webhook"
  local dir=$LAB/bank-monitoring hosts="" h tmp
  monitoring_stop >/dev/null
  rm -rf "$dir"; mkdir -p "$dir"/prometheus/confluent "$dir"/alertmanager "$dir"/grafana/provisioning/{datasources,dashboards} "$dir"/webhook
  tmp=$dir/to-bank; docker cp "$(container_of "$OPS_HOST"):/root/monitoring/to-bank" "$(windows_path "$tmp")"
  cp "$tmp"/prometheus/* "$dir/prometheus/confluent/"
  sed 's/WEBHOOK-RECEIVER/lab-mon-webhook/' "$tmp/alertmanager/alertmanager.yml" > "$dir/alertmanager/alertmanager.yml"
  sed 's#http://PROMETHEUS:9090#http://lab-mon-prometheus:9090#' "$tmp/grafana/datasource-prometheus.yml" > "$dir/grafana/provisioning/datasources/prometheus.yml"
  cp "$tmp"/grafana/dashboards/* "$dir/grafana/provisioning/dashboards/"
  cat > "$dir/prometheus/prometheus.yml" <<'YML'
global: { scrape_interval: 30s, evaluation_interval: 30s }
scrape_config_files: [ /etc/prometheus/confluent/scrape-confluent.yml ]
rule_files: [ /etc/prometheus/confluent/confluent-alerts.yml ]
alerting: { alertmanagers: [ { static_configs: [ { targets: [ "lab-mon-alertmanager:9093" ] } ] } ] }
YML
  cat > "$dir/webhook/receiver.py" <<'PY'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        print('POST %s | %s | %s' % (self.path, self.headers.get('User-Agent'), body), flush=True)
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('0.0.0.0', 8080), H).serve_forever()
PY
  # 主機名稱 → 容器 IP（Prometheus 容器不在 compose 裡，要自己給）
  for h in $KAFKA_HOSTS $RESTS $C3_HOST; do hosts="$hosts --add-host $(fqdn "$h"):$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(container_of "$h")")"; done
  docker run -d --name lab-mon-webhook --network lab_labnet --memory 64m -v "$(windows_path "$dir/webhook"):/w:ro" $NODE_IMAGE python3 -u /w/receiver.py >/dev/null
  docker run -d --name lab-mon-alertmanager --network lab_labnet --memory 128m -v "$(windows_path "$dir/alertmanager/alertmanager.yml"):/etc/alertmanager/alertmanager.yml:ro" prom/alertmanager:v0.34.1 --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager --cluster.listen-address= >/dev/null
  # shellcheck disable=SC2086
  docker run -d --name lab-mon-prometheus --network lab_labnet --memory 600m $hosts -v "$(windows_path "$dir/prometheus/prometheus.yml"):/etc/prometheus/prometheus.yml:ro" -v "$(windows_path "$dir/prometheus/confluent"):/etc/prometheus/confluent:ro" prom/prometheus:v3.5.0 --config.file=/etc/prometheus/prometheus.yml --web.enable-lifecycle --storage.tsdb.retention.time=1d >/dev/null
  docker run -d --name lab-mon-grafana --network lab_labnet --memory 400m -p 13000:3000 -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin -v "$(windows_path "$dir/grafana/provisioning"):/etc/grafana/provisioning:ro" grafana/grafana:11.3.0 >/dev/null
  announce "Windows 瀏覽器：Prometheus http://localhost:19090（若有發布）、Grafana http://localhost:13000（匿名 Admin，只在 lab）"
}

coldboot() {   # 19.4：機房停電：全部主機同時關、同時開
  announce "19.4 冷開機：全部 stop → start，量 broker MDS 與 C3 回來的時間"
  cd "$LAB" && docker compose -f compose.yml stop 2>&1 | grep -c Stopped; t0=$(date +%s); docker compose -f compose.yml start 2>&1 | grep -c Started
  probe() { docker exec "$(container_of "$OPS_HOST")" bash -c "curl -sk -o /dev/null -w '%{http_code}' $1"; }
  for i in $(seq 1 60); do a=0; for h in $BROKERS; do [ "$(probe "https://$(fqdn "$h"):8090/v1/metadata/id")" = 200 ] && a=$((a+1)); done; [ "$a" = "$(wc -w <<<"$BROKERS")" ] && break; sleep 10; done; echo "broker 的 MDS 都回 200：$(( $(date +%s) - t0 ))s"
  for i in $(seq 1 60); do [ "$(probe "https://$C3_FQDN:9021/")" = 200 ] && break; sleep 10; done; echo "C3 回 200：$(( $(date +%s) - t0 ))s"
  docker exec "$(container_of "${BROKERS%% *}")" bash -c 'echo "kb01 confluent-server 重試次數：$(journalctl -u confluent-server --since "-10min" --no-pager | grep -c "Scheduled restart job")"'
}

sign_next() {   # 20.2.2：簽 ops02 ~/pki/next/requests/*.csr（換發）；參數給 CA 目錄（預設 ca，換 CA 階段二用 ca/g2）
  local ca_dir=${1:-ca} csr cert_name
  announce "20.2.2 CA 窗口：用 $ca_dir 簽 ~/pki/next/requests/*.csr → ~/pki/next/incoming/"
  rm -rf "$LAB/ca/exchange/next"; mkdir -p "$LAB/ca/exchange/next/signed"
  docker cp "$(container_of "$OPS_HOST"):/root/pki/next/requests" "$(windows_path "$LAB/ca/exchange/next/")"
  for csr in "$LAB"/ca/exchange/next/requests/*.csr; do cert_name=$(basename "$csr" .csr); bash "$LAB/$ca_dir/sign.sh" "$csr" "$LAB/ca/exchange/next/signed/$cert_name.crt"; done
  for cert_file in "$LAB"/ca/exchange/next/signed/*.crt; do docker cp "$(windows_path "$cert_file")" "$(container_of "$OPS_HOST"):/root/pki/next/incoming/"; done
  as_root_on "$OPS_HOST" 'ls /root/pki/next/incoming | wc -l'
}

lb_watch() {   # 12.1（lab）：扮演 LB 團隊：操作機出現 ~/lb-requests/<主機>.<down|up> 就照做、回覆 .done；$LAB/lb-watch.stop 出現就結束
  local request host action stop_file=${1:-$LAB/lb-watch.stop}
  rm -f "$stop_file"; announce "LB 團隊待命（結束：touch $stop_file）"
  while [ ! -f "$stop_file" ]; do
    for request in $(as_root_on_ops 'cd ~/lb-requests 2>/dev/null && for f in *.down *.up; do [ -f "$f" ] && [ ! -f "$f.done" ] && echo "$f"; done' 2>/dev/null); do
      host=${request%.*}; action=${request##*.}
      bash "$LAB/lb-member.sh" "$host" "$action" && as_root_on_ops "touch ~/lb-requests/$request.done"
    done
    sleep 2
  done
}

case ${1:-} in push|intake|prepare|sign|reset|monitoring|monitoring_stop|coldboot) "$1";;
  os-content) os_content;;
  os-sync) os_sync;;
  landing-layout) landing_layout;;
  monitoring-stop) monitoring_stop;;
  lb-watch) lb_watch "${2:-}";;
  sign-next) sign_next "${2:-ca}";; *) sed -n '2,15p' "$0"; echo "  延伸：monitoring（17.6）monitoring-stop coldboot（19.4）sign-next lb-watch"; exit 1;; esac
