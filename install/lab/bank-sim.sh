#!/usr/bin/env bash
# install/lab/bank-sim.sh — lab 專用：在 Windows Git Bash 扮演「銀行」，做手把手文件裡橘色標籤的事
# where: Windows Git Bash（lab 的主控端；正式環境沒有這支，安裝腳本只會印「請銀行做」）
#
# 做什麼：每個子命令就是手把手裡一段「銀行」標籤的區塊與第 0 章建 lab 的做法，只是從 Windows 端對容器執行。
# 需要什麼：lab 已依 docs/journey-src/journey.md 第 0 章建好（~/kafka-lab，compose 專案 lab）。
# 能不能重跑：可以。已經做好的（AD 物件、OS 內容、帳號）不會重做或會蓋成同樣的內容；reset 會清掉 lab 的所有 volume。
#
#   bash bank-sim.sh landing-layout       把舊的落地區版面（8.3.2 在 rpm/、8.2.4 在 landing-extra/）整理成 rpm/ = 基底、rpm-target/ = 目標
#   bash bank-sim.sh push                 把 install/ 送到 ops02（root，/root/install）與 dl01（root）
#   bash bank-sim.sh os-content           5.1、30.5 銀行 OS 團隊備 OS 內容（拋棄式容器）：~/kafka-lab/bank-os/9.6（基底的完整套件庫）、9.8-updates（9.6 主機升 9.8 需要的更新）、9.8（兩者合併）
#   bash bank-sim.sh intake               3.2 檔案交換：落地區 → ops02 ~/landing（唯讀）
#   bash bank-sim.sh prepare              第 4 章 各主機建 cpuser＋sshd 設定＋公鑰（from=）＋安裝期 sudo、5.1 OS 套件庫＋根憑證信任、5.3 AD、5.4 NTP 與 LB
#   bash bank-sim.sh sign                 9.2 銀行 CA 簽 ops02 ~/pki/requests/*.csr → ~/pki/incoming/
#   bash bank-sim.sh os-sync              30.5 銀行把套件庫同步到 OS_TARGET_VERSION（9.8）：把 bank-os/9.8 換上 repo01 的 /os/
#   bash bank-sim.sh reset                先收監控容器，再 podman compose down -v、up -d（從零）；落地區與 dl01 保留
#   bash bank-sim.sh monitoring           17.6 監控團隊起 Prometheus、Alertmanager、Grafana、webhook 接收端
#   bash bank-sim.sh monitoring-stop      B.2 收掉 lab-mon-* 容器（設定目錄留著）
#   bash bank-sim.sh monitoring-reload    24.2 把 confluent-alerts-disk.yml 放進 Prometheus
#   bash bank-sim.sh monitoring-blackbox  22.2 起 blackbox_exporter、Prometheus 加 cert-expiry job 與憑證規則
#   bash bank-sim.sh coldboot             19.4 機房停電：全部主機同時關、同時開
#   bash bank-sim.sh ad-drill             11.2 AD 斷線演練
#   bash bank-sim.sh broker-stop <broker> 28.3 停掉一台 broker 的服務
#   bash bank-sim.sh alerts-wait [告警…]  28.3 等告警 firing
#   bash bank-sim.sh alerts-clear         28.4 等告警解除
#   bash bank-sim.sh mds-block on|off     28.6 擋掉／開回操作機連 broker 的 8090
#   bash bank-sim.sh sign-next [CA 目錄]  21.2.2 簽 ~/pki/next/requests/*.csr（預設 ca，換 CA 階段二用 ca/g2）
#   bash bank-sim.sh sign-app <憑證名稱>  27.3 只簽一張新應用程式的 CSR
#   bash bank-sim.sh lb-watch [結束訊號檔] 12.1 扮演 LB 團隊：照操作機 ~/lb-requests/ 的請求停用／恢復 REST 成員
set -euo pipefail
export MSYS_NO_PATHCONV=1

# 安裝 Podman 之前就開著的 Git Bash 找不到 podman
if ! command -v podman > /dev/null 2>&1; then
  podman_dir=$(cygpath -u "$LOCALAPPDATA")/Programs/Podman
  export PATH="$podman_dir:$PATH"
fi

LAB=${LAB:-$HOME/kafka-lab}
script_dir=$(dirname "$0")
INSTALL=$(
  if ! cd "$script_dir/.."; then
    exit 1
  fi

  pwd
)
source "$INSTALL/conf/site.env"

NODE_IMAGE=${NODE_IMAGE:-lab-node:96}   # 主機映像（手把手 0.1）；9.6 的 tag 和舊的 9.8 映像分開，才不會誤用舊映像
OS_DIR=$LAB/bank-os                     # 銀行套件庫的內容（不是我們交付的檔案，所以不在落地區）：9.6（基底）、9.8-updates（更新集合）、9.8（合併後的完整套件庫）

# 主機短名 → lab 的容器名稱
container_of() { echo "lab-$1-1"; }

# Git Bash 路徑 → podman 看得懂的 Windows 路徑
windows_path() { cygpath -m "$1"; }

# 在某台主機以 root 跑一段指令（扮演銀行的 OS 團隊）
as_root_on() { podman exec "$(container_of "$1")" bash -c "$2"; }

# 在操作機以 root 跑一段指令（人員經 PSMP 登入操作機就是 root；lab 直接 podman exec 進去）
as_root_on_ops() { podman exec -w /root "$(container_of "$OPS_HOST")" bash -c "$1"; }

announce() { printf '\n[bank] %s\n' "$*"; }

# ---------------------------------------------------------------- 落地區、install/、檔案交換

# move_if_new <檔案> <目的目錄> <說明>：目的目錄還沒有這個檔才搬過去
move_if_new() {
  local file=$1 target_dir=$2 label=$3

  if [ ! -f "$file" ]; then
    return 0
  fi

  if [ -e "$target_dir/$(basename "$file")" ]; then
    return 0
  fi

  mv "$file" "$target_dir/"
  echo "$label：$(basename "$file")"
}

# 落地區版面（遷移主線）：rpm/ = 安裝基底、rpm-target/ = 遷移目標、bank/ = 兩個 JDK、c3/ = 第 31 章帶進來的單一 C3 版本。
# 舊版面（8.3.2 在 rpm/、8.2.4 在 ~/kafka-lab/landing-extra/）整理成新版面；已經是新版面就什麼都不做。只搬檔案，不下載、不刪下載好的東西
landing_layout() {
  local landing=$LAB/landing extra=$LAB/landing-extra file

  announce "落地區版面：rpm/（$CP_VERSION）、rpm-target/（$CP_TARGET_VERSION）、bank/（JDK $JDK_MAJOR、$JDK_TARGET_MAJOR）"
  mkdir -p "$landing/rpm" "$landing/rpm-target" "$landing/bank"

  # 1. 目標版本的檔案如果還在 rpm/（舊版面）：搬到 rpm-target/
  for file in \
    "$landing"/rpm/*-"$CP_TARGET_VERSION"-1.* \
    "$landing"/rpm/confluent-control-center-next-gen-"$C3_TARGET_VERSION"-1.*; do
    if [ -f "$file" ]; then
      mv "$file" "$landing/rpm-target/"
      echo "rpm/ → rpm-target/：$(basename "$file")"
    fi
  done

  # 2. landing-extra（舊的升級演練起點）的 8.2.4 與 JDK 25 併進來；用不到的舊 JDK 21 小版本留在原地
  if [ -d "$extra" ]; then
    for file in "$extra"/rpm/*-"$CP_VERSION"-1.*; do
      move_if_new "$file" "$landing/rpm" "landing-extra/rpm → rpm/"
    done

    for file in "$extra"/bank/OpenJDK"$JDK_TARGET_MAJOR"U-*; do
      move_if_new "$file" "$landing/bank" "landing-extra/bank → bank/"
    done

    if ! rmdir "$extra/rpm" "$extra/bank" "$extra" 2> /dev/null; then
      echo "landing-extra 還剩 $(find "$extra" -type f | wc -l) 個檔（舊版 JDK 等，不會再用到；確認後可整個刪掉）"
    fi
  fi

  echo "rpm/ $(ls "$landing"/rpm | wc -l) 個、rpm-target/ $(ls "$landing"/rpm-target | wc -l) 個（02 站會補齊 C3 與缺的檔案）"
}

push() {
  announce "install/ → $OPS_HOST:/root/install、dl01:/root/install"

  # 1. 操作機
  as_root_on "$OPS_HOST" 'rm -rf /root/install'
  podman cp "$(windows_path "$INSTALL")" "$(container_of "$OPS_HOST"):/root/install"
  podman exec "$(container_of "$OPS_HOST")" chmod +x /root/install/install.sh
  as_root_on "$OPS_HOST" 'chmod +x /root/install/steps/*.sh'
  as_root_on "$OPS_HOST" 'ls /root/install/steps | wc -l'

  # 2. 下載機
  podman exec dl01 rm -rf /root/install
  podman cp "$(windows_path "$INSTALL")" dl01:/root/install
  podman exec dl01 bash -c 'chmod +x /root/install/steps/*.sh'
  podman exec dl01 bash -c 'ls /root/install/steps | wc -l'
}

intake() {
  announce "3.2 檔案交換：$LAB/landing → $OPS_HOST:~/landing（唯讀）"

  # 1. 選單是我方交付物（手把手 16.3）：和手冊一起給的 tar＋SHA256SUMS，lab 由 opmenu/package.sh 產生到落地區
  if ! bash "$INSTALL/../opmenu/package.sh" "$LAB/landing/tools/opmenu" > /dev/null; then
    echo "選單打包失敗"
    return 1
  fi

  # 2. 操作機上的落地區目錄（podman cp 不會自己建）、整個落地區複製過去
  podman exec "$(container_of "$OPS_HOST")" install -d -m 0700 /root/landing
  podman cp "$(windows_path "$LAB/landing")/." "$(container_of "$OPS_HOST"):/root/landing/"

  # 3. 設成唯讀；數檔案、看大小
  as_root_on "$OPS_HOST" 'chmod -R a-w /root/landing'
  as_root_on "$OPS_HOST" 'echo "$(find /root/landing -type f | wc -l) files, $(du -sh /root/landing | cut -f1)"'
}

# ---------------------------------------------------------------- OS 內容（5.1、30.5）

# 5.1 / 30.5：銀行 OS 團隊備 OS 內容。全部在拋棄式容器（$NODE_IMAGE，乾淨的 9.6）裡做，結果放 ~/kafka-lab/bank-os/（銀行的東西，不經檔案交換進操作機）：
#   bank-os/9.6          平台要用的 OS 套件（chrony、firewalld、cyrus-sasl…加相依）＋索引；用 Rocky vault 的 9.6 內容（預設的 repo 會跟著最新小版本走，不能用）
#   bank-os/9.8-updates  「9.6 主機（裝了上面那些套件）升到 9.8 要的更新」：在容器裡把 9.6 套件裝起來，再對 pub/rocky/9.8 做 dnf update --downloadonly
#   bank-os/9.8          上面兩者合併＋索引 = 銀行把套件庫同步到 9.8 之後的樣子（os-sync 用）
# 先下載、再裝工具（順序反了會漏掉工具自己的相依）。已經備好的不重做。
os_content() {
  local base=$OS_BASE_VERSION target=$OS_TARGET_VERSION

  if [ -f "$OS_DIR/$target/repodata/repomd.xml" ]; then
    if [ -f "$OS_DIR/$base/repodata/repomd.xml" ]; then
      announce "OS 內容已備好：$OS_DIR（$base、$target-updates、$target）"
      return 0
    fi
  fi

  announce "OS 內容：$base 完整套件庫、$base→$target 更新集合（拋棄式容器 lab-mig-oscontent，用完即刪）"
  rm -rf "$OS_DIR"
  mkdir -p "$OS_DIR"
  podman rm -f --ignore lab-mig-oscontent > /dev/null 2>&1

  podman run --rm -i --name lab-mig-oscontent -e BASE="$base" -e TARGET="$target" \
    -v "$(windows_path "$OS_DIR"):/out" "$NODE_IMAGE" bash -e -s <<'EOF'
base_repos="--disablerepo=* --enablerepo=vault${BASE//./}-baseos,vault${BASE//./}-appstream,vault${BASE//./}-extras"
# lint-ok: 套件清單（jq 是 OS 套件庫要提供的套件名稱，不是這裡在用 jq）
packages="chrony firewalld cyrus-sasl openssl-devel httpd mod_ssl python3-dnf-plugin-versionlock nmap-ncat jq gettext openldap-clients createrepo_c tar gzip openssl sudo openssh-server diffutils less vim-minimal bind-utils lsof procps-ng rsync bash-completion"
started_at=$(date +%s)

# 1. 下載基底的套件（鏡像站有時還沒同步好：最多試 3 次，每次隔 60 秒）
downloaded=no
for try in 1 2 3; do
  if dnf -q $base_repos download --resolve --arch x86_64 --arch noarch --destdir /out/$BASE/Packages $packages; then
    downloaded=yes
    break
  fi

  echo "鏡像站還沒同步好，60 秒後重試（第 $try 次）" >&2
  dnf -q clean metadata
  sleep 60
done

if [ $downloaded != yes ]; then
  echo "試了 3 次都下載失敗" >&2
  exit 1
fi

# 2. 工具與「已裝好這批套件的 9.6 主機」是同一件事：全部從剛下載的檔案裝（不連網）
if ! dnf -q -y --disablerepo="*" install /out/$BASE/Packages/*.rpm > /tmp/i.log 2>&1; then
  echo "裝 $BASE 套件失敗："
  tail -5 /tmp/i.log
  false
fi

createrepo_c -q /out/$BASE
echo "$BASE：$(ls /out/$BASE/Packages | wc -l) 個 RPM，$(du -sm /out/$BASE | cut -f1) MB，$(( $(date +%s) - started_at )) 秒"

# 3. 目標小版本的三個倉庫（pub/rocky/<版本>）
started_at=$(date +%s)
cat > /etc/yum.repos.d/rocky-target.repo <<REPO
[r-target-baseos]
name=Rocky $TARGET BaseOS
baseurl=https://dl.rockylinux.org/pub/rocky/$TARGET/BaseOS/\$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1
[r-target-appstream]
name=Rocky $TARGET AppStream
baseurl=https://dl.rockylinux.org/pub/rocky/$TARGET/AppStream/\$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1
[r-target-extras]
name=Rocky $TARGET extras
baseurl=https://dl.rockylinux.org/pub/rocky/$TARGET/extras/\$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
enabled=1
REPO

# 4. 基底 → 目標要的更新：只下載、不安裝
mkdir -p /out/$TARGET-updates/Packages /tmp/dl

if ! dnf -q -y --disablerepo="*" --enablerepo=r-target-baseos,r-target-appstream,r-target-extras \
    update --downloadonly --downloaddir /tmp/dl > /tmp/u.log 2>&1; then
  echo "抓 $TARGET 的更新失敗（多半是連不到 dl.rockylinux.org，稍後重跑）："
  tail -5 /tmp/u.log
  false
fi

# 5. 先複製到銀行的目錄、再建索引（下載目錄直接當套件庫時，dnf 可能把用過的 RPM 刪掉）
cp -a /tmp/dl/. /out/$TARGET-updates/Packages/
createrepo_c -q /out/$TARGET-updates
updates_rpm_count=$(ls /out/$TARGET-updates/Packages | wc -l)
updates_size_mb=$(du -sm /out/$TARGET-updates | cut -f1)
echo "$TARGET-updates：$updates_rpm_count 個 RPM，$updates_size_mb MB，$(( $(date +%s) - started_at )) 秒"

# 6. 基底的內容加上更新集合，合併成目標小版本的套件庫
mkdir -p /out/$TARGET/Packages
cp -a /out/$BASE/Packages/. /out/$TARGET/Packages/
cp -a /out/$TARGET-updates/Packages/. /out/$TARGET/Packages/
createrepo_c -q /out/$TARGET
echo "$TARGET（合併）：$(ls /out/$TARGET/Packages | wc -l) 個 RPM"
EOF
}

# 30.5（lab）：銀行把套件庫同步到 OS_TARGET_VERSION：bank-os/9.8 換上 repo01 的 /os/（正式環境是 Satellite／Nexus 同步，或 reposync 後 createrepo）
os_sync() {
  if [ ! -f "$OS_DIR/$OS_TARGET_VERSION/repodata/repomd.xml" ]; then
    echo "$OS_DIR/$OS_TARGET_VERSION 沒有：先 bash bank-sim.sh os-content"
    return 1
  fi

  announce "30.5 銀行套件庫同步到 $OS_TARGET_VERSION：$(ls "$OS_DIR/$OS_TARGET_VERSION/Packages" | wc -l) 個 RPM"
  publish_os_content "$OS_TARGET_VERSION"
  as_root_on "$REPO_HOST" 'ls /var/www/repo/os/Packages | wc -l'
}

# publish_os_content <小版本>：bank-os/<小版本> 換上 repo01 的 /os/（擁有者是部署帳號 repodeploy）
publish_os_content() {
  local version=$1

  podman exec "$(container_of "$REPO_HOST")" install -d /var/www/repo/os
  as_root_on "$REPO_HOST" 'rm -rf /var/www/repo/os/*'
  podman cp "$(windows_path "$OS_DIR/$version")/." "$(container_of "$REPO_HOST"):/var/www/repo/os/"
  podman exec "$(container_of "$REPO_HOST")" chown -R repodeploy:repodeploy /var/www/repo/os
}

# ---------------------------------------------------------------- prepare：第 4 章、5.1、5.3、5.4

# 第 4 章 OS 團隊在一台主機上做的事（以 root）：建 cpuser、sshd 設定、公鑰行、安裝期 sudo。參數：主機短名、authorized_keys 的整行
os_team_cpuser() {
  local host=$1 line=$2

  podman exec -i -e LINE="$line" -e CPID="$SSH_USER_ID" -e CPUSER="$SSH_USER" "$(container_of "$host")" bash -s <<'BANK'
set -e

# 1. 帳號：UID／GID 固定，不設密碼（useradd 預設就是鎖定）
if ! getent group "$CPUSER" > /dev/null; then
  groupadd -g "$CPID" "$CPUSER"
fi

if ! id "$CPUSER" > /dev/null 2>&1; then
  useradd -u "$CPID" -g "$CPID" -m -s /bin/bash "$CPUSER"
fi

# 2. sshd：不收密碼，只收金鑰
printf 'Match User %s\n    PasswordAuthentication no\n    AuthenticationMethods publickey\n' "$CPUSER" \
  > /etc/ssh/sshd_config.d/50-cpuser.conf
sshd -t
systemctl reload sshd

# 3. 公鑰行（目錄 0700、檔 0600、擁有者 cpuser）
install -d -m 0700 -o "$CPUSER" -g "$CPUSER" "/home/$CPUSER/.ssh"
printf '%s\n' "$LINE" > "/home/$CPUSER/.ssh/authorized_keys"
chown "$CPUSER:$CPUSER" "/home/$CPUSER/.ssh/authorized_keys"
chmod 0600 "/home/$CPUSER/.ssh/authorized_keys"

# 4. 安裝期的全權 sudo（交付時移除）
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$CPUSER" > "/etc/sudoers.d/$CPUSER"
chmod 0440 "/etc/sudoers.d/$CPUSER"
visudo -cf "/etc/sudoers.d/$CPUSER" > /dev/null
BANK
}

# 第 4 章：操作機（root）已在 /secure/ssh 產生金鑰對（第 4 站）。公鑰行 = from="<操作機 IP>,127.0.0.1,::1" + 公鑰；
# OS 團隊在每台主機（含操作機自己）建 cpuser 並放這一行；repo01 的 repodeploy 放同一行
prepare_host_access() {
  local ops_container ops_ip public_key from_addrs line host

  ops_container=$(container_of "$OPS_HOST")

  # 1. 要放的那一行：公鑰前面加 from=（只有操作機的位址能用）
  if ! public_key=$(podman exec "$ops_container" cat "$SSH_KEY.pub" 2> /dev/null); then
    echo "操作機上沒有 $SSH_KEY.pub：先跑第 4 站（bash install/install.sh --to 03）讓它產生金鑰"
    return 1
  fi

  ops_ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$ops_container")
  from_addrs=${SSH_FROM_ADDRS:-$ops_ip,127.0.0.1,::1}
  line="from=\"$from_addrs\" $public_key"

  # 2. 每台主機
  announce "第 4 章 OS 團隊：每台主機（含 $OPS_HOST）建 $SSH_USER（UID $SSH_USER_ID）、sshd 只收金鑰、公鑰行 from=\"$from_addrs\"、安裝期 sudo"

  for host in $ALL_HOSTS; do
    if os_team_cpuser "$host" "$line"; then
      printf '%s ' "$host"
    fi
  done
  echo

  # 3. 套件庫的部署帳號放同一行
  announce "第 4 章 套件庫 $REPO_HOST：$REPO_DEPLOY_USER 放同一行公鑰"
  podman exec -i -e LINE="$line" "$(container_of "$REPO_HOST")" bash -e -s <<'BANK'
install -d -m 0700 -o repodeploy -g repodeploy /home/repodeploy/.ssh
printf "%s\n" "$LINE" > /home/repodeploy/.ssh/authorized_keys
chown repodeploy:repodeploy /home/repodeploy/.ssh/authorized_keys
chmod 0600 /home/repodeploy/.ssh/authorized_keys
ls -l /home/repodeploy/.ssh/authorized_keys
BANK
}

# repo01 的 HTTPS 憑證要驗得過 ca/root.crt：手把手第 21 章演練過換 CA 的 lab，repo.crt 會是 G2／G3 簽的，用現在的 CA 重簽
prepare_repo_certificate() {
  local repo_tls=$LAB/images/web/tls

  if openssl verify \
      -CAfile "$(windows_path "$LAB/ca/root.crt")" \
      -untrusted "$(windows_path "$repo_tls/repo.crt")" \
      "$(windows_path "$repo_tls/repo.crt")" > /dev/null 2>&1; then
    return 0
  fi

  announce "5.1 套件庫管理員：repo01 的 HTTPS 憑證驗不過目前的根（之前換過 CA），用現在的 CA 重簽"
  openssl req -new -key "$(windows_path "$repo_tls/repo.key")" -out "$(windows_path "$repo_tls/repo.csr")" \
    -subj "/CN=repo01.poc.lab/O=PoC Bank/C=TW" \
    -addext "subjectAltName=DNS:repo01.poc.lab,DNS:repo01" \
    -addext "extendedKeyUsage=serverAuth" 2> /dev/null

  if bash "$LAB/ca/sign.sh" "$repo_tls/repo.csr" "$repo_tls/repo.crt"; then
    rm -f "$repo_tls/repo.csr"
  fi

  podman exec "$(container_of repo01)" systemctl restart httpd
}

# trust_root_and_add_repo <主機>：信任銀行的根憑證、指向銀行套件庫的 repo 設定、匯入套件簽章的公鑰（根憑證已經 podman cp 進去）
trust_root_and_add_repo() {
  podman exec -i -e REPO_URL="$REPO_URL" "$(container_of "$1")" bash -e -s <<'BANK'
update-ca-trust

cat > /etc/yum.repos.d/bank-os.repo <<REPO
[bank-os]
name=Bank OS packages
baseurl=$REPO_URL/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
REPO

rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
BANK
}

# 5.1：OS 套件庫（repo01 /os/）與根憑證信任
prepare_os_repo() {
  local host

  # 1. 套件庫的內容：沒有就先備
  announce "5.1 OS 套件庫（repo01 /os/）：$OS_BASE_VERSION 的完整內容（$OS_DIR/$OS_BASE_VERSION；沒有就先備）"

  if [ ! -f "$OS_DIR/$OS_BASE_VERSION/repodata/repomd.xml" ]; then
    os_content
  fi

  publish_os_content "$OS_BASE_VERSION"
  as_root_on "$REPO_HOST" 'ls /var/www/repo/os'
  as_root_on "$REPO_HOST" 'ls /var/www/repo/os/Packages | wc -l'

  # 2. 每台主機
  announce "5.1 根憑證進每台主機的信任清單 + bank-os.repo"

  for host in $ALL_HOSTS; do
    podman cp "$(windows_path "$LAB/ca/root.crt")" \
      "$(container_of "$host"):/etc/pki/ca-trust/source/anchors/bank-root.pem"

    if trust_root_and_add_repo "$host"; then
      printf '%s ' "$host"
    fi
  done
  echo
}

# 5.3 AD 團隊在 ad01 建物件：兩個密碼檔、OU、svc-mds-bind、三個群組、alice／bob／carol。印出 samba-tool 的全部輸出
AD_CREATE_OBJECTS=$(cat <<'BANK'
# good_password <密碼>：大寫、小寫、數字至少各有一個才算合格（AD 的密碼規則）
good_password() {
  if [[ ! $1 =~ [A-Z] ]]; then
    return 1
  fi

  if [[ ! $1 =~ [a-z] ]]; then
    return 1
  fi

  if [[ ! $1 =~ [0-9] ]]; then
    return 1
  fi

  return 0
}

# 1. 兩個密碼檔：bind.pass 給 svc-mds-bind、users.pass 給三個測試人員共用（已經有就沿用）
install -d -m 0700 /root/secrets

for k in bind users; do
  if [ -s /root/secrets/$k.pass ]; then
    continue
  fi

  p=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)

  while ! good_password "$p"; do
    p=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
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
  user=${pair%%:*}
  group=${pair#*:}
  samba-tool user create "$user" "$(cat /root/secrets/users.pass)" --userou="OU=Users,OU=Confluent"
  samba-tool group addmembers "$group" "$user"
done

# 6. 確認：kafka-admins 裡有 alice
samba-tool group listmembers kafka-admins
BANK
)

ad_create_objects() { podman exec "$(container_of "$AD_HOST")" bash -e -c "$AD_CREATE_OBJECTS"; }

# 5.3 LDAPS：ad01 產生 CSR → 銀行 CA 簽 → 放進 samba 的 tls/ → 停掉 samba 讓它讀新憑證
ad_ldaps_certificate() {
  local tls=/var/lib/samba/private/tls
  local ad
  ad=$(container_of "$AD_HOST")

  # 1. 申請檔（一定要帶 extendedKeyUsage，CA 的政策會檢查）；已經有就沿用
  podman exec -i "$ad" bash -s <<'BANK'
mkdir -p /root/csr
cd /root/csr

if [ ! -f ad01.csr ]; then
  openssl req -new -newkey rsa:2048 -nodes -keyout ad01.key -out ad01.csr \
    -subj "/CN=ad01.poc.lab/O=PoC Bank/C=TW" \
    -addext "subjectAltName=DNS:ad01.poc.lab,DNS:ad01" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" 2> /dev/null < /dev/null
fi

echo csr-ok
BANK

  # 2. 取回申請檔，用銀行 CA 簽
  mkdir -p "$LAB/ca/exchange"
  podman cp "$ad:/root/csr/ad01.csr" "$(windows_path "$LAB/ca/exchange/ad01.csr")"
  bash "$LAB/ca/sign.sh" "$LAB/ca/exchange/ad01.csr" "$LAB/ca/exchange/ad01-chain.crt"

  # 3. 憑證、根憑證放進 samba 的 tls/
  podman cp "$(windows_path "$LAB/ca/exchange/ad01-chain.crt")" "$ad:$tls/cert.pem"
  podman cp "$(windows_path "$LAB/ca/root.crt")" "$ad:$tls/ca.pem"

  # 4. 私鑰 0600；停掉 samba（啟動程式 2 秒後會自己再開），確認 LDAPS 出示的憑證驗得過根憑證
  podman exec -i "$ad" bash -s <<'BANK'
tls=/var/lib/samba/private/tls
cp /root/csr/ad01.key $tls/key.pem
chmod 600 $tls/key.pem
chmod 644 $tls/cert.pem $tls/ca.pem
pkill -x samba
sleep 8
openssl s_client -connect localhost:636 -CAfile $tls/ca.pem < /dev/null 2> /dev/null | grep "Verify return code"
BANK
}

# 5.3：AD 物件、LDAPS 憑證、密碼交付
prepare_ad() {
  local attempt pair source_name target_name

  announce "5.3 AD 團隊：OU、群組、svc-mds-bind、alice/bob/carol；LDAPS 憑證；密碼交付"

  # 1. 等 samba 起來：每 5 秒看一次，最多 30 次
  for attempt in $(seq 1 30); do
    if as_root_on "$AD_HOST" 'samba-tool user list > /dev/null 2>&1'; then
      break
    fi

    sleep 5
  done

  # 2. AD 物件（只留 samba-tool 輸出裡「不是 User／Added 開頭」的行，也就是 listmembers 的結果）
  if as_root_on "$AD_HOST" 'samba-tool ou list 2> /dev/null | grep -qE "^OU=Confluent(,|$)"'; then
    echo "AD 物件已存在，略過建立"
  elif ! ad_create_objects | grep -v '^User\|^Added\|^$'; then
    echo "AD 測試帳號建立失敗（看上面的 samba-tool 訊息）"
    exit 1
  fi

  # 3. LDAPS 憑證
  ad_ldaps_certificate

  # 4. 模擬「銀行 AD 團隊把帳號資訊（svc-mds-bind 的密碼、測試人員 alice／bob／carol 的密碼）交給我方」：
  #    直接放進操作機 ~/secrets（0600，root 才讀得到）。平台的密碼與金鑰只留在操作機，不經 CyberArk
  podman exec "$(container_of "$OPS_HOST")" install -d -m 0700 /root/secrets

  # 寫法：ad01 上的檔名:操作機上的檔名
  for pair in bind:ldap-bind users:ad-test-users; do
    source_name=${pair%%:*}
    target_name=${pair#*:}
    podman exec "$(container_of "$AD_HOST")" cat "/root/secrets/$source_name.pass" \
      | podman exec -i "$(container_of "$OPS_HOST")" install -m 0600 /dev/stdin "/root/secrets/$target_name.pass"
  done

  as_root_on "$OPS_HOST" 'ls -la /root/secrets | tail -n +4'
}

# 5.4：NTP（repo01 兼任）與負載平衡（lb01 nginx L4）
prepare_ntp_and_lb() {
  announce "5.4 NTP（repo01 兼任）與負載平衡（lb01 nginx L4）"

  # 1. LB 團隊停用／恢復 REST 成員的小腳本（手把手 12.1 的五步）
  install -m 0755 "$INSTALL/lab/lb-member.sh" "$LAB/lb-member.sh"

  # 2. repo01 當 NTP 伺服器：沒有上游時用本機時間，允許 lab 的網段來對時
  podman exec -i "$(container_of "$REPO_HOST")" bash -s <<'BANK'
cat > /etc/yum.repos.d/bank-os.repo <<'REPO'
[bank-os]
name=Bank OS packages
baseurl=file:///var/www/repo/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
REPO

rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

if dnf -q -y --disablerepo="*" --enablerepo=bank-os install chrony > /dev/null; then
  cat > /etc/chrony.conf <<'CONF'
local stratum 10
allow 172.35.0.0/24
driftfile /var/lib/chrony/drift
CONF
  systemctl enable --now chronyd > /dev/null 2>&1
fi

systemctl restart chronyd
sleep 2
echo "chronyd $(systemctl is-active chronyd)"
BANK

  # 3. lb01：只做 L4 轉發，TLS 和 client 憑證在 REST Proxy 上處理
  podman exec -i "$(container_of "$LB_HOST")" bash -e -s <<'BANK'
mkdir -p /etc/nginx/stream.d

cat > /etc/nginx/stream.d/cp.conf <<'CONF'
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
CONF

nginx -t 2>&1 | tail -1
nginx -s reload
BANK
}

prepare() {
  prepare_host_access
  prepare_repo_certificate
  prepare_os_repo
  prepare_ad
  prepare_ntp_and_lb
}

# ---------------------------------------------------------------- CA 窗口

sign() {
  local csr_file cert_file cert_name

  announce "9.2 CA 窗口：簽 ops02 ~/pki/requests/*.csr → ~/pki/incoming/"

  # 1. 只送回這次簽的：上一輪留下的舊憑證不能混進去
  rm -rf "$LAB/ca/exchange/signed" "$LAB/ca/exchange/requests"
  mkdir -p "$LAB/ca/exchange/signed"
  podman cp "$(container_of "$OPS_HOST"):/root/pki/requests" "$(windows_path "$LAB/ca/exchange/")"

  # 2. 逐一簽發
  for csr_file in "$LAB"/ca/exchange/requests/*.csr; do
    cert_name=$(basename "$csr_file" .csr)
    bash "$LAB/ca/sign.sh" "$csr_file" "$LAB/ca/exchange/signed/$cert_name.crt"
  done

  # 3. 簽好的放回操作機的 incoming/，數一下
  for cert_file in "$LAB"/ca/exchange/signed/*.crt; do
    podman cp "$(windows_path "$cert_file")" "$(container_of "$OPS_HOST"):/root/pki/incoming/"
  done

  as_root_on "$OPS_HOST" 'ls /root/pki/incoming | wc -l'
}

# 21.2.2：簽 ops02 ~/pki/next/requests/*.csr（換發）；參數給 CA 目錄（預設 ca，換 CA 階段二用 ca/g2）
sign_next() {
  local ca_dir=${1:-ca} csr_file cert_file cert_name

  announce "21.2.2 CA 窗口：用 $ca_dir 簽 ~/pki/next/requests/*.csr → ~/pki/next/incoming/"

  # 1. 清掉上一次的，取回操作機 next/ 裡的申請檔
  rm -rf "$LAB/ca/exchange/next"
  mkdir -p "$LAB/ca/exchange/next/signed"
  podman cp "$(container_of "$OPS_HOST"):/root/pki/next/requests" "$(windows_path "$LAB/ca/exchange/next/")"

  # 2. 逐一簽發
  for csr_file in "$LAB"/ca/exchange/next/requests/*.csr; do
    cert_name=$(basename "$csr_file" .csr)
    bash "$LAB/$ca_dir/sign.sh" "$csr_file" "$LAB/ca/exchange/next/signed/$cert_name.crt"
  done

  # 3. 簽好的放回操作機的 next/incoming/，數一下
  for cert_file in "$LAB"/ca/exchange/next/signed/*.crt; do
    podman cp "$(windows_path "$cert_file")" "$(container_of "$OPS_HOST"):/root/pki/next/incoming/"
  done

  as_root_on "$OPS_HOST" 'ls /root/pki/next/incoming | wc -l'
}

# 27.3（lab）：CA 窗口只簽一張新應用程式的 CSR（~/pki/requests/<名稱>.csr → ~/pki/incoming/<名稱>.crt），用現行的 CA
sign_app() {
  local cert_name=${1:-} current_ca="" candidate

  if [ -z "$cert_name" ]; then
    echo "用法：bank-sim.sh sign-app <憑證名稱>"
    return 1
  fi

  # 1. 平台現在信任的根（操作機的 bank-root.pem）
  mkdir -p "$LAB/ca/exchange"
  podman exec "$(container_of "$OPS_HOST")" cat /etc/pki/ca-trust/source/anchors/bank-root.pem \
    > "$LAB/ca/exchange/anchor.pem"

  # 2. 現行的 CA＝中繼憑證能被這個根驗證通過的那個目錄（21.3 換過 CA 之後是 ca/g2）；不能只看目錄存不存在
  for candidate in "$LAB/ca" "$LAB/ca/g2"; do
    if [ -f "$candidate/issuing.crt" ]; then
      if openssl verify \
          -CAfile "$(windows_path "$LAB/ca/exchange/anchor.pem")" \
          "$(windows_path "$candidate/issuing.crt")" > /dev/null 2>&1; then
        current_ca=$candidate
      fi
    fi
  done

  if [ -z "$current_ca" ]; then
    echo "沒有一個 CA 目錄的中繼憑證能被平台信任"
    return 1
  fi

  # 3. 取回 CSR、簽、把憑證放回操作機的 ~/pki/incoming/
  announce "27.3 CA 窗口：用 $(basename "$current_ca") 簽 ~/pki/requests/$cert_name.csr → ~/pki/incoming/$cert_name.crt"
  mkdir -p "$LAB/ca/exchange/requests" "$LAB/ca/exchange/signed"
  rm -f "$LAB/ca/exchange/requests/$cert_name.csr" "$LAB/ca/exchange/signed/$cert_name.crt"
  podman cp "$(container_of "$OPS_HOST"):/root/pki/requests/$cert_name.csr" \
    "$(windows_path "$LAB/ca/exchange/requests/$cert_name.csr")"
  bash "$current_ca/sign.sh" "$LAB/ca/exchange/requests/$cert_name.csr" "$LAB/ca/exchange/signed/$cert_name.crt"
  podman cp "$(windows_path "$LAB/ca/exchange/signed/$cert_name.crt")" "$(container_of "$OPS_HOST"):/root/pki/incoming/"
}

# ---------------------------------------------------------------- reset（0.6、0.9）

# compose_up_count：podman compose up -d，印出幾台 Started（lb01 第一次有時沒起來，這時結束碼不是 0）
compose_up_count() {
  podman compose -f compose.yml up -d 2>&1 | awk '/Started/ {c++} END {print c + 0}'
}

reset() {
  # 1. 監控容器接在 lab_labnet 上，不先收掉 down -v 刪不掉網路
  if ! monitoring_stop > /dev/null 2>&1; then
    echo "收 lab-mon-* 容器時有錯，down -v 可能刪不掉網路"
  fi

  announce "lab 從零：down -v（volume 全刪，落地區 $LAB/landing 保留）→ up -d"
  cd "$LAB"

  # 2. 整個拆掉
  podman compose -f compose.yml down -v --remove-orphans 2>&1 | tail -1

  # 3. 起來；lb01 第一次有時沒起來（要同時接兩個網路），再 up 一次就會補起來（手把手 0.6 的陷阱）
  if ! compose_up_count; then
    echo "第一次 up -d 有錯（通常是 lb01），再做一次"
  fi

  sleep 5

  if ! compose_up_count; then
    echo "第二次 up -d 也有錯，看 podman ps"
  fi

  # 4. 下載機不在 compose 裡，只是把它開著
  if ! podman start dl01 > /dev/null 2>&1; then
    echo "dl01 開不起來（手把手 0.7 建的）"
  fi

  # 5. 數容器：14 台加 dl01
  podman ps --format '{{.Names}}' | awk '/^lab-|^dl01$/ {c++} END {print c + 0}'
}

# ---------------------------------------------------------------- 監控（17.6、22.2、24.2）

# 17.6、B.2（lab）：收掉銀行端的監控容器（Prometheus、Alertmanager、Grafana、webhook 接收端、blackbox）；設定目錄留著
monitoring_stop() {
  podman rm -f --ignore lab-mon-prometheus lab-mon-alertmanager lab-mon-grafana lab-mon-webhook lab-mon-blackbox \
    2> /dev/null | tr '\n' ' '
  echo "（已收掉）"
}

# prometheus_ready_wait：等 Prometheus Ready：每 5 秒看一次，最多 12 次
prometheus_ready_wait() {
  local attempt

  for attempt in $(seq 1 12); do
    if grep -q Ready <<<"$(podman exec lab-mon-prometheus wget -qO- http://localhost:9090/-/ready 2> /dev/null)"; then
      break
    fi

    sleep 5
  done
}

# prometheus_rule_status：在 labnet 上起一個臨時容器，印規則數、群組名稱、載入有錯幾條
prometheus_rule_status() {
  podman run --rm -i --network lab_labnet "$NODE_IMAGE" bash -s <<'EOF'
curl -s http://lab-mon-prometheus:9090/api/v1/rules | python3 -c '
import json, sys
g = json.load(sys.stdin)["data"]["groups"]
r = [x for y in g for x in y["rules"]]
print("告警規則 %d 條（%s），載入有錯 %d 條" % (len(r), "、".join(y["name"] for y in g), sum(x["health"] != "ok" for x in r)))'
EOF
}

# prometheus_target_and_rule_status：cert-expiry 的 target 數，加上規則數
prometheus_target_and_rule_status() {
  podman run --rm -i --network lab_labnet "$NODE_IMAGE" bash -s <<'EOF'
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
}

# 17.6（lab）：銀行監控團隊用小安給的 to-bank/ 起 Prometheus、Alertmanager、Grafana，再加一個印出收到什麼的 webhook 接收端
monitoring() {
  local dir=$LAB/bank-monitoring to_bank=$LAB/bank-monitoring/to-bank add_hosts="" host host_ip

  announce "17.6 監控團隊：載入 to-bank/ 的設定，起 lab-mon-prometheus、lab-mon-alertmanager、lab-mon-grafana、lab-mon-webhook"
  monitoring_stop > /dev/null

  # 1. 每次重新做：清掉舊的，建各容器要的目錄
  rm -rf "$dir"
  mkdir -p "$dir/prometheus/confluent" "$dir/alertmanager" "$dir/webhook"
  mkdir -p "$dir/grafana/provisioning/datasources" "$dir/grafana/provisioning/dashboards"

  # 2. 從操作機取出 to-bank/
  podman cp "$(container_of "$OPS_HOST"):/root/monitoring/to-bank" "$(windows_path "$to_bank")"

  # 3. 放成各容器要的樣子：webhook 網址換成接收端容器、datasource 指向 lab 的 Prometheus
  cp "$to_bank"/prometheus/* "$dir/prometheus/confluent/"
  sed 's/WEBHOOK-RECEIVER/lab-mon-webhook/' "$to_bank/alertmanager/alertmanager.yml" \
    > "$dir/alertmanager/alertmanager.yml"
  sed 's#http://PROMETHEUS:9090#http://lab-mon-prometheus:9090#' "$to_bank/grafana/datasource-prometheus.yml" \
    > "$dir/grafana/provisioning/datasources/prometheus.yml"
  cp "$to_bank"/grafana/dashboards/* "$dir/grafana/provisioning/dashboards/"

  # 4. 行內 Prometheus 自己的 prometheus.yml：引用 scrape 設定、載入告警規則、指向 Alertmanager
  cat > "$dir/prometheus/prometheus.yml" <<'YML'
global: { scrape_interval: 30s, evaluation_interval: 30s }
scrape_config_files: [ /etc/prometheus/confluent/scrape-confluent.yml ]
rule_files: [ /etc/prometheus/confluent/confluent-alerts*.yml ]
alerting: { alertmanagers: [ { static_configs: [ { targets: [ "lab-mon-alertmanager:9093" ] } ] } ] }
YML

  # 5. webhook 接收端：收到什麼就印什麼（一行：路徑 | User-Agent | 本文）
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

  # 6. Prometheus 要認得各主機的名稱（監控容器不在 compose 裡，沒有 extra_hosts）：每台一個 --add-host
  local host_container

  for host in $KAFKA_HOSTS $RESTS $C3_HOST; do
    host_container=$(container_of "$host")
    host_ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$host_container")
    add_hosts="$add_hosts --add-host $(fqdn "$host"):$host_ip"
  done

  # 7. webhook 接收端（用主機映像跑那支 Python）
  podman run -d --restart unless-stopped --name lab-mon-webhook --network lab_labnet --memory 64m \
    -v "$(windows_path "$dir/webhook"):/w:ro" "$NODE_IMAGE" python3 -u /w/receiver.py > /dev/null

  # 8. Alertmanager（--cluster.listen-address= 留空：lab 的 172.35.x.x 不是私有位址，gossip 起不來）
  podman run -d --restart unless-stopped --name lab-mon-alertmanager --network lab_labnet --memory 128m \
    -v "$(windows_path "$dir/alertmanager/alertmanager.yml"):/etc/alertmanager/alertmanager.yml:ro" \
    prom/alertmanager:v0.34.1 --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager \
    --cluster.listen-address= > /dev/null

  # 9. Prometheus（--web.enable-lifecycle：17.8 要叫它重新載入規則）
  # shellcheck disable=SC2086  # add_hosts 是好幾個參數
  podman run -d --restart unless-stopped --name lab-mon-prometheus --network lab_labnet --memory 600m $add_hosts \
    -v "$(windows_path "$dir/prometheus/prometheus.yml"):/etc/prometheus/prometheus.yml:ro" \
    -v "$(windows_path "$dir/prometheus/confluent"):/etc/prometheus/confluent:ro" \
    prom/prometheus:v3.5.0 --config.file=/etc/prometheus/prometheus.yml --web.enable-lifecycle \
    --storage.tsdb.retention.time=1d > /dev/null

  # 10. Grafana（匿名 Admin 只為了 lab 好操作；發佈到 Windows 的 13000）
  podman run -d --restart unless-stopped --name lab-mon-grafana --network lab_labnet --memory 400m -p 13000:3000 \
    -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
    -v "$(windows_path "$dir/grafana/provisioning"):/etc/grafana/provisioning:ro" grafana/grafana:11.3.0 > /dev/null

  # 11. 等 60 秒，4 個都要是 Up
  sleep 60
  podman ps --format '{{.Names}} {{.Status}}' | grep -E 'lab-mon-(prometheus|alertmanager|grafana|webhook)' | sort

  announce "Windows 瀏覽器：Prometheus http://localhost:19090（若有發布）、Grafana http://localhost:13000（匿名 Admin，只在 lab）"
}

# 24.2（lab）：小安又給了規則檔（to-bank/prometheus/confluent-alerts-disk.yml）：放進去、重啟 Prometheus，數規則
monitoring_reload() {
  local dir=$LAB/bank-monitoring attempt status=""

  announce "24.2 監控團隊：把 to-bank/prometheus/ 的新檔放進 Prometheus，reload，確認規則載入"

  if [ ! -d "$dir/prometheus/confluent" ]; then
    echo "沒有 $dir：先跑 monitoring"
    return 1
  fi

  # 1. 規則檔從 ops02 複製到 Prometheus 掛著的資料夾（只拿這一個：別的檔 lab 已改過，例如 scrape-blackbox.yml 的 exporter 位址）
  podman cp "$(container_of "$OPS_HOST"):/root/monitoring/to-bank/prometheus/confluent-alerts-disk.yml" \
    "$(windows_path "$dir/prometheus/confluent/confluent-alerts-disk.yml")"

  # 2. rule_files 還是單一檔名的話，改成 confluent-alerts*.yml
  if ! grep -q 'confluent-alerts\*\.yml' "$dir/prometheus/prometheus.yml"; then
    sed -i 's#confluent/confluent-alerts\.yml#confluent/confluent-alerts*.yml#' "$dir/prometheus/prometheus.yml"
  fi

  # 3. 重啟 Prometheus（prometheus.yml 是單檔掛進去的，改了要 restart 才讀得到），等它 Ready
  podman restart lab-mon-prometheus > /dev/null
  prometheus_ready_wait

  # 4. 剛載入的規則 health 是 unknown，要等一次 evaluation（30 s）才是 ok：每 5 秒看一次，最多 20 次
  for attempt in $(seq 1 20); do
    status=$(prometheus_rule_status)

    if grep -q '載入有錯 0 條' <<<"$status"; then
      break
    fi

    sleep 5
  done

  echo "$status"
}

# labnet_ip <主機>：那台在 labnet 上的 IP（lb01 接兩個網段：只取 labnet 的）
labnet_ip() {
  podman inspect -f '{{(index .NetworkSettings.Networks "lab_labnet").IPAddress}}' "$(container_of "$1")"
}

# 22.2（lab）：監控團隊起 blackbox_exporter（lab-mon-blackbox），把 to-bank/prometheus 的 blackbox 設定、scrape-blackbox.yml、confluent-alerts-cert.yml 放進 Prometheus
monitoring_blackbox() {
  local dir=$LAB/bank-monitoring add_hosts="" host from_ops file attempt status="" promtool_result

  announce "22.2 監控團隊：起 lab-mon-blackbox，Prometheus 加 cert-expiry job 與憑證規則"

  if [ ! -d "$dir/prometheus/confluent" ]; then
    echo "沒有 $dir：先跑 monitoring"
    return 1
  fi

  # 1. 從操作機取出 to-bank/prometheus/
  from_ops=$(mktemp -d)
  podman cp "$(container_of "$OPS_HOST"):/root/monitoring/to-bank/prometheus" "$(windows_path "$from_ops")"

  for file in scrape-blackbox.yml confluent-alerts-cert.yml cert-expiry-rules-test.yml; do
    if [ ! -s "$from_ops/prometheus/$file" ]; then
      echo "to-bank/prometheus/$file 不存在：先跑第 22 站 files"
      return 1
    fi
  done

  # 2. 放成 lab 容器要的樣子（lab 的 scrape-blackbox.yml 指到容器名稱；正式環境是銀行自己的 exporter 位址）
  mkdir -p "$dir/blackbox"
  cp "$from_ops/prometheus/blackbox.yml" "$dir/blackbox/blackbox.yml"
  cp "$from_ops/prometheus/scrape-blackbox.yml" \
    "$from_ops/prometheus/confluent-alerts-cert.yml" \
    "$from_ops/prometheus/cert-expiry-rules-test.yml" \
    "$dir/prometheus/confluent/"
  rm -rf "$from_ops"
  sed -i 's/BLACKBOX-EXPORTER:9115/lab-mon-blackbox:9115/' "$dir/prometheus/confluent/scrape-blackbox.yml"

  # 3. exporter 要認得各主機的名稱：每台一個 --add-host
  for host in $KAFKA_HOSTS $RESTS $C3_HOST $AD_HOST $LB_HOST; do
    add_hosts="$add_hosts --add-host $(fqdn "$host"):$(labnet_ip "$host")"
  done
  add_hosts="$add_hosts --add-host $REST_VIP:$(labnet_ip "$LB_HOST")"

  # 4. 起 blackbox_exporter（舊的有的話先移除）
  podman rm -f --ignore lab-mon-blackbox > /dev/null 2>&1
  # shellcheck disable=SC2086  # add_hosts 是好幾個參數
  podman run -d --restart unless-stopped --name lab-mon-blackbox --network lab_labnet --memory 64m $add_hosts \
    -v "$(windows_path "$dir/blackbox/blackbox.yml"):/etc/blackbox_exporter/config.yml:ro" \
    -v "$(windows_path "$dir/prometheus/confluent"):/etc/prometheus/confluent:ro" \
    prom/blackbox-exporter:v0.25.0 --config.file=/etc/blackbox_exporter/config.yml > /dev/null

  # 5. Prometheus 改讀 scrape-*.yml 與 confluent-alerts*.yml（單檔 bind mount，改了要 restart），等它就緒
  local old_scrape new_scrape
  old_scrape='scrape_config_files: \[ /etc/prometheus/confluent/scrape-confluent.yml \]'
  new_scrape='scrape_config_files: [ /etc/prometheus/confluent/scrape-*.yml ]'
  sed -i \
    -e "s#$old_scrape#$new_scrape#" \
    -e 's#confluent/confluent-alerts\.yml#confluent/confluent-alerts*.yml#' \
    "$dir/prometheus/prometheus.yml"
  podman restart lab-mon-prometheus > /dev/null
  prometheus_ready_wait

  # 6. promtool test rules（在 Prometheus 容器裡跑，它自帶 promtool；-w 指定目錄，規則檔用相對路徑）
  local promtool_command
  promtool_command='promtool test rules cert-expiry-rules-test.yml 2>&1 | grep -oE "SUCCESS|FAIL" | head -1'
  promtool_result=$(podman exec -w /etc/prometheus/confluent lab-mon-prometheus sh -c "$promtool_command")
  echo "$promtool_result"

  if [ "$promtool_result" != SUCCESS ]; then
    echo "promtool test rules 沒有通過"
    return 1
  fi

  # 7. 第一次抓要等一個 scrape_interval（5 分鐘）：等到 cert-expiry 的 target 全 up、規則都 ok（最多 7 分鐘）
  for attempt in $(seq 1 42); do
    status=$(prometheus_target_and_rule_status)

    if grep -q '載入有錯 0 條' <<<"$status"; then
      if grep -qE 'target up ([0-9]+) / \1$' <<<"$status"; then
        break
      fi
    fi

    sleep 10
  done

  echo "$status"
}

# ---------------------------------------------------------------- 告警（28.2–28.4）

# 銀行 Prometheus 現在的告警：firing：…；pending：…
prometheus_alerts() {
  podman run --rm -i --network lab_labnet "$NODE_IMAGE" bash -s <<'EOF'
curl -s http://lab-mon-prometheus:9090/api/v1/alerts | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]["alerts"]
firing = sorted(set(
    x["labels"]["alertname"] + "(" + x["labels"].get("hostname", x["labels"].get("env", "")) + ")"
    for x in a if x["state"] == "firing"
))
pending = sorted(set(x["labels"]["alertname"] for x in a if x["state"] == "pending"))
print("firing：" + (", ".join(firing) or "無") + "；pending：" + (", ".join(pending) or "無"))'
EOF
}

# 28.3（lab）：等這些告警都 firing（預設 ConfluentTargetDown KafkaUnderReplicatedPartitions；最多 7 分鐘）
alerts_wait() {
  local wanted_alerts=${1:-ConfluentTargetDown KafkaUnderReplicatedPartitions} attempt status alert all_firing

  announce "28.3 監控團隊：等告警 firing（$wanted_alerts）"

  for attempt in $(seq 1 42); do
    status=$(prometheus_alerts)
    all_firing=1

    for alert in $wanted_alerts; do
      if ! grep -qE "firing：[^；]*$alert" <<<"$status"; then
        all_firing=0
      fi
    done

    if [ "$all_firing" = 1 ]; then
      break
    fi

    sleep 10
  done

  echo "等了約 $((attempt * 10)) 秒：$status"
  [ "$all_firing" = 1 ]
}

# 28.3（lab）：等告警全部解除（最多 3 分鐘）
alerts_clear() {
  local attempt status

  announce "28.3 監控團隊：等告警解除"

  for attempt in $(seq 1 18); do
    status=$(prometheus_alerts)

    if grep -q '^firing：無' <<<"$status"; then
      break
    fi

    sleep 10
  done

  echo "等了約 $((attempt * 10)) 秒：$status"
  grep -q '^firing：無' <<<"$status"
}

# ---------------------------------------------------------------- 演練：冷開機、AD 斷線、擋 MDS、停 broker

# probe <網址>：從操作機打一次，印 HTTP 狀態碼（不驗憑證；連不上時是 000）
probe() {
  podman exec "$(container_of "$OPS_HOST")" curl -sk -o /dev/null -w '%{http_code}' "$1"
}

# rest_via_lb：從操作機經 LB 打 REST Proxy（mTLS，驗銀行根憑證），印 HTTP 狀態碼
rest_via_lb() {
  podman exec "$(container_of "$OPS_HOST")" curl -s --cacert "$BANK_ROOT_CA" \
    --cert /root/pki/certs/app-legacy-billing.crt \
    --key /root/pki/keys/app-legacy-billing.key \
    -o /dev/null -w '%{http_code}' "https://$REST_VIP:8082/v3/clusters"
}

# 19.4：機房停電：全部主機同時關、同時開
coldboot() {
  local started_at attempt ready host host_fqdn broker_count first_broker
  local first_broker_container journal_command count_command retry_count

  announce "19.4 冷開機：全部 stop → start，量 broker MDS 與 C3 回來的時間"
  cd "$LAB"

  # 1. 全部停掉（模擬停電），再全部開起來：兩次都要數到 14
  podman compose -f compose.yml stop 2>&1 | grep -c Stopped
  started_at=$(date +%s)
  podman compose -f compose.yml start 2>&1 | grep -c Started

  # 2. 等每台 broker 的 MDS 都回 200：每 10 秒看一次，最多 60 次
  broker_count=$(wc -w <<<"$BROKERS")

  for attempt in $(seq 1 60); do
    ready=0

    for host in $BROKERS; do
      host_fqdn=$(fqdn "$host")

      if [ "$(probe "https://$host_fqdn:8090/v1/metadata/id")" = 200 ]; then
        ready=$((ready + 1))
      fi
    done

    if [ "$ready" = "$broker_count" ]; then
      break
    fi

    sleep 10
  done

  echo "broker 的 MDS 都回 200：$(( $(date +%s) - started_at ))s"

  # 3. 等 C3 回 200：每 10 秒看一次，最多 60 次
  for attempt in $(seq 1 60); do
    if [ "$(probe "https://$C3_FQDN:9021/")" = 200 ]; then
      break
    fi

    sleep 10
  done

  echo "C3 回 200：$(( $(date +%s) - started_at ))s"

  # 4. REST 經 LB
  echo "REST 經 LB：$(rest_via_lb)"

  # 5. 第一台 broker 的 confluent-server 這 10 分鐘內被 systemd 重試了幾次（要是 0）
  first_broker=${BROKERS%% *}
  first_broker_container=$(container_of "$first_broker")
  journal_command='journalctl -u confluent-server --since "-10min" --no-pager'
  count_command='awk "/Scheduled restart job/ {c++} END {print c + 0}"'
  retry_count=$(podman exec "$first_broker_container" bash -c "$journal_command | $count_command")
  echo "kb01 confluent-server 重試次數：$retry_count"
}

# AD 不通時，在操作機上看兩件事：alice 登不進 MDS（不是 200）、kafka-admin 用 SCRAM 從 9095 還列得到 topic。
# 連線設定自己寫（不借 ~/conf/app-orders.properties：腳本路徑要到第 19 站才有那個檔）；kafka-topics 把 Error 印在 stdout，不算進 topic 數
AD_DOWN_CHECK=$(cat <<'EOF'
export JAVA_HOME=/opt/java/current
export KAFKA_OPTS=-Dlog4j2.configurationFile=/etc/kafka/tools-log4j2.yaml
ca=/etc/pki/ca-trust/source/anchors/bank-root.pem

# 1. alice 用 AD 帳密向 MDS 要 token：AD 不通，不應該是 200
password=$(cat ~/secrets/ad-test-users.pass)
code=$(curl -s -m 20 --cacert $ca -u "alice:$password" -o /dev/null -w "%{http_code}" \
  https://kb01.poc.lab:8090/security/1.0/authenticate)
unset password
echo "alice 登入 MDS：HTTP $code（不是 200 才對）"

# 2. kafka-admin 用 SCRAM 從 9095 列 topic：照樣可以（連線設定放在暫存目錄，用完即刪）
tmp=$(mktemp -d)
admin_password=$(cat ~/secrets/kafka-admin.pass)
store_password=$(cat ~/pki/store.pass)
scram_module=org.apache.kafka.common.security.scram.ScramLoginModule
install -m 0600 /dev/null "$tmp/c.properties"
cat > "$tmp/c.properties" <<CONF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=$scram_module required username="kafka-admin" password="$admin_password";
ssl.truststore.type=PKCS12
ssl.truststore.location=/root/pki/certs/truststore.p12
ssl.truststore.password=$store_password
CONF
unset admin_password store_password

count=$(kafka-topics --bootstrap-server kb01.poc.lab:9095 --command-config "$tmp/c.properties" --list 2> /dev/null \
  | awk '!/^Error/ && !/^$/ {c++} END {print c + 0}')
echo "kafka-admin 從 9095 列 topic：$count 個"
rm -rf "$tmp"

# 3. 兩件事都對才算通過
if [ "$code" = 200 ]; then
  exit 1
fi

if [ "$count" -le 0 ]; then
  exit 1
fi
EOF
)

# AD 開回後：alice 要登得進 MDS（每 5 秒試一次，最多 12 次）
AD_BACK_CHECK=$(cat <<'EOF'
ca=/etc/pki/ca-trust/source/anchors/bank-root.pem
password=$(cat ~/secrets/ad-test-users.pass)

for attempt in $(seq 1 12); do
  code=$(curl -s -m 20 --cacert $ca -u "alice:$password" -o /dev/null -w "%{http_code}" \
    https://kb01.poc.lab:8090/security/1.0/authenticate)

  if [ "$code" = 200 ]; then
    break
  fi

  sleep 5
done

unset password
echo "AD 開回後 alice 登入 MDS：HTTP $code"

if [ "$code" != 200 ]; then
  exit 1
fi
EOF
)

# 11.2：AD 不通時，人員登不進 MDS、緊急帳號 kafka-admin（SCRAM，SystemAdmin）照樣能用；驗完把 AD 開回來（演練失敗也要開回）
ad_drill() {
  local result=0 attempt

  announce "11.2 AD 斷線演練：停 ad01 → alice 登不進、kafka-admin 仍可用 → 開回 ad01"

  # 1. 停 ad01
  podman stop "$(container_of "$AD_HOST")" > /dev/null
  echo "ad01 已停"

  # 2. 看兩件事
  if ! podman exec "$(container_of "$OPS_HOST")" bash -c "$AD_DOWN_CHECK" < /dev/null; then
    result=1
  fi

  # 3. 開回 ad01，等 LDAPS 回來：每 5 秒試一次，最多 30 次
  podman start "$(container_of "$AD_HOST")" > /dev/null
  echo "ad01 已開回"

  local ldaps_check
  ldaps_check="timeout 5 openssl s_client -connect $(fqdn "$AD_HOST"):636 < /dev/null 2> /dev/null"
  ldaps_check="$ldaps_check | grep -q 'Verify return code: 0'"

  for attempt in $(seq 1 30); do
    if as_root_on "$OPS_HOST" "$ldaps_check"; then
      break
    fi

    sleep 5
  done

  # 4. alice 又登得進去
  if ! as_root_on "$OPS_HOST" "$AD_BACK_CHECK"; then
    result=1
  fi

  return $result
}

# 28.6（lab）：網路團隊在每台 broker 擋掉操作機連 8090（runtime 規則，firewall-cmd --reload 或重開機就消失）；on|off
mds_block() {
  local action=${1:-} firewall_option action_word ops_ip rule host

  case $action in
    on)
      firewall_option=--add-rich-rule
      action_word=擋掉
      ;;
    off)
      firewall_option=--remove-rich-rule
      action_word=開回
      ;;
    *)
      echo "用法：bank-sim.sh mds-block on|off"
      return 1
      ;;
  esac

  local ops_container host_container
  ops_container=$(container_of "$OPS_HOST")
  ops_ip=$(podman exec "$ops_container" hostname -I | awk '{print $1}')
  rule="rule family=\"ipv4\" source address=\"$ops_ip\" port port=\"8090\" protocol=\"tcp\" reject"
  announce "28.6 網路團隊：$action_word $OPS_HOST（$ops_ip）連 broker 的 8090"

  for host in $BROKERS; do
    host_container=$(container_of "$host")
    echo "$host: $(podman exec "$host_container" firewall-cmd "$firewall_option=$rule")"
  done
}

# 28.3（lab）：主機團隊／意外：把一台 broker 的服務停掉（容器裡以 root 停，不經 cpuser）
broker_stop() {
  local broker=${1:-}

  if [ -z "$broker" ]; then
    echo "用法：bank-sim.sh broker-stop <broker>"
    return 1
  fi

  announce "28.3 $broker 的 confluent-server 停掉（模擬主機或服務掛了）"
  podman exec "$(container_of "$broker")" systemctl stop confluent-server
  sleep 15
  local broker_container
  broker_container=$(container_of "$broker")
  echo "$broker confluent-server：$(podman exec "$broker_container" systemctl is-active confluent-server)"
}

# ---------------------------------------------------------------- LB 團隊（12.1）

# 操作機 ~/lb-requests/ 裡還沒回覆的請求（檔名 <主機>.down 或 <主機>.up；回覆過的會有 <檔名>.done），一行一個
PENDING_LB_REQUESTS=$(cat <<'EOF'
if ! cd ~/lb-requests 2> /dev/null; then
  exit 0
fi

for request_file in *.down *.up; do
  if [ -f "$request_file" ]; then
    if [ ! -f "$request_file.done" ]; then
      echo "$request_file"
    fi
  fi
done
EOF
)

# 12.1（lab）：扮演 LB 團隊：操作機出現 ~/lb-requests/<主機>.<down|up> 就照做、回覆 .done；結束訊號檔出現就結束
lb_watch() {
  local stop_file=${1:-$LAB/lb-watch.stop} request host action

  rm -f "$stop_file"
  announce "LB 團隊待命（結束：touch $stop_file）"

  while [ ! -f "$stop_file" ]; do
    for request in $(as_root_on_ops "$PENDING_LB_REQUESTS" 2> /dev/null); do
      host=${request%.*}
      action=${request##*.}

      if bash "$LAB/lb-member.sh" "$host" "$action"; then
        as_root_on_ops "touch ~/lb-requests/$request.done"
      fi
    done

    sleep 2
  done
}

# ---------------------------------------------------------------- 子命令

case ${1:-} in
  # lint-ok: case 的選項清單，不是管線
  push|intake|prepare|sign|reset|monitoring|monitoring_stop|coldboot)
    "$1"
    ;;
  os-content)
    os_content
    ;;
  os-sync)
    os_sync
    ;;
  landing-layout)
    landing_layout
    ;;
  monitoring-stop)
    monitoring_stop
    ;;
  monitoring-reload)
    monitoring_reload
    ;;
  monitoring-blackbox)
    monitoring_blackbox
    ;;
  lb-watch)
    lb_watch "${2:-}"
    ;;
  sign-next)
    sign_next "${2:-ca}"
    ;;
  sign-app)
    sign_app "${2:-}"
    ;;
  ad-drill)
    ad_drill
    ;;
  broker-stop)
    broker_stop "${2:-}"
    ;;
  mds-block)
    mds_block "${2:-}"
    ;;
  alerts-wait)
    alerts_wait "${2:-}"
    ;;
  alerts-clear)
    alerts_clear
    ;;
  *)
    sed -n '2,29p' "$0"
    exit 1
    ;;
esac
