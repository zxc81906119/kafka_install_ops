#!/usr/bin/env bash
# install/lab/bank-sim.sh — lab 專用：在 Windows Git Bash 扮演「銀行」，做手把手文件裡橘色標籤的事。
# 正式環境沒有這支；安裝腳本只會印「請銀行做」。lab 依 docs/journey-src/journey.md 第 0 章建好（~/kafka-lab）。
#   bash bank-sim.sh push      把 install/ 送到 ops02（cpadmin）與 dl01（root）
#   bash bank-sim.sh intake    2.2 檔案交換：落地區 → ops02 ~/landing（唯讀）
#   bash bank-sim.sh prepare   3.1 公鑰派送、3.2 OS 套件庫＋根憑證信任、3.4 AD、3.5 NTP 與 LB
#   bash bank-sim.sh sign      9.2 銀行 CA 簽 ops02 ~/pki/requests/*.csr → ~/pki/incoming/
#   bash bank-sim.sh reset     down -v 後重新 up（從零）；dl01 保留
set -euo pipefail
export MSYS_NO_PATHCONV=1
LAB=${LAB:-$HOME/kafka-lab}; INSTALL=$(cd "$(dirname "$0")/.." && pwd)
source "$INSTALL/conf/site.env"
C() { echo "lab-$1-1"; }                                   # container name
w() { cygpath -m "$1"; }
xr() { docker exec "$(C "$1")" bash -c "$2"; }               # as root
xo() { docker exec -u cpadmin -w /home/cpadmin "$(C "$OPS_HOST")" bash -c "$1"; }
say() { printf '\n[bank] %s\n' "$*"; }

push() {
  say "install/ → $OPS_HOST:/home/cpadmin/install、dl01:/root/install"
  xr "$OPS_HOST" 'rm -rf /home/cpadmin/install'; docker cp "$(w "$INSTALL")" "$(C "$OPS_HOST"):/home/cpadmin/install"
  xr "$OPS_HOST" 'chown -R cpadmin:cpadmin /home/cpadmin/install && chmod +x /home/cpadmin/install/install.sh /home/cpadmin/install/steps/*.sh && ls /home/cpadmin/install/steps | wc -l'
  docker exec dl01 rm -rf /root/install; docker cp "$(w "$INSTALL")" dl01:/root/install; docker exec dl01 bash -c 'chmod +x /root/install/steps/*.sh; ls /root/install/steps | wc -l'
}

intake() {
  say "2.2 檔案交換：$LAB/landing → $OPS_HOST:~/landing（唯讀）"
  xr "$OPS_HOST" 'install -d -o cpadmin -g cpadmin /home/cpadmin/landing'
  docker cp "$(w "$LAB/landing")/." "$(C "$OPS_HOST"):/home/cpadmin/landing/"
  xr "$OPS_HOST" 'chown -R cpadmin:cpadmin /home/cpadmin/landing && chmod -R a-w /home/cpadmin/landing && echo "$(find /home/cpadmin/landing -type f | wc -l) files, $(du -sh /home/cpadmin/landing | cut -f1)"'
}

prepare() {
  say "3.1 OS 團隊：ops02 的公鑰 → 所有主機 cpadmin 與 repo01 的 repodeploy（共用 authorized_keys.d volume）"
  xr "$OPS_HOST" 'k=$(cat /home/cpadmin/.ssh/id_ed25519.pub); install -m 0644 -o root -g root /dev/stdin /etc/ssh/authorized_keys.d/cpadmin <<<"$k"; install -m 0644 -o root -g root /dev/stdin /etc/ssh/authorized_keys.d/repodeploy <<<"$k"; ls /etc/ssh/authorized_keys.d/'

  say "3.2 OS 套件庫（repo01 /os/）：有現成的 $LAB/bank-os-repo 就直接用，沒有才從 Rocky repo 抓"
  if [ ! -f "$LAB/bank-os-repo/repodata/repomd.xml" ]; then
    docker run --rm -v "$(w "$LAB/bank-os-repo"):/out" lab-node:1 bash -c '
set -e
R="--disablerepo=* --enablerepo=baseos,appstream,extras"
dnf -q $R download --resolve --arch x86_64 --arch noarch --destdir /out/Packages java-21-openjdk-headless chrony firewalld cyrus-sasl openssl-devel httpd mod_ssl python3-dnf-plugin-versionlock nmap-ncat jq gettext openldap-clients createrepo_c tar gzip openssl sudo openssh-server diffutils less vim-minimal bind-utils lsof procps-ng rsync bash-completion
dnf -q -y $R install createrepo_c >/dev/null
createrepo_c -q /out
ls /out/Packages | wc -l'
  fi
  docker cp "$(w "$LAB/bank-os-repo")/." "$(C "$REPO_HOST"):/var/www/repo/os/"
  xr "$REPO_HOST" 'chown -R repodeploy:repodeploy /var/www/repo/os; ls /var/www/repo/os'
  say "3.2 根憑證進每台主機的信任清單 + bank-os.repo"
  for h in $ALL_HOSTS; do
    docker cp "$(w "$LAB/ca/root.crt")" "$(C "$h"):/etc/pki/ca-trust/source/anchors/bank-root.pem"
    xr "$h" 'update-ca-trust && printf "[bank-os]\nname=Bank OS packages\nbaseurl='"$REPO_URL"'/os/\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\n" > /etc/yum.repos.d/bank-os.repo && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9' && printf '%s ' "$h"
  done; echo

  say "3.4 AD 團隊：OU、群組、svc-mds-bind、alice/bob/carol；LDAPS 憑證；密碼交付"
  for i in $(seq 1 30); do xr "$AD_HOST" 'samba-tool user list >/dev/null 2>&1' && break; sleep 5; done
  if xr "$AD_HOST" 'samba-tool ou list 2>/dev/null | grep -q "^OU=Confluent,"'; then echo "AD 物件已存在，略過建立"; else
    xr "$AD_HOST" 'install -d -m 0700 /root/secrets && for k in bind users; do openssl rand -base64 24 | tr -dc "A-Za-z0-9" | head -c 20 > /root/secrets/$k.pass; done; B=DC=corp,DC=poc,DC=lab; samba-tool ou create "OU=Confluent,$B" && for ou in Users Groups Service; do samba-tool ou create "OU=$ou,OU=Confluent,$B"; done && samba-tool user create svc-mds-bind "$(cat /root/secrets/bind.pass)" --userou="OU=Service,OU=Confluent" --description="read-only LDAP bind for Confluent MDS" && for g in kafka-admins kafka-operators kafka-devs; do samba-tool group add "$g" --groupou="OU=Groups,OU=Confluent"; done && for p in alice:kafka-admins bob:kafka-operators carol:kafka-devs; do u=${p%%:*}; g=${p#*:}; samba-tool user create "$u" "$(cat /root/secrets/users.pass)" --userou="OU=Users,OU=Confluent" && samba-tool group addmembers "$g" "$u"; done; samba-tool group listmembers kafka-admins' | grep -v '^User\|^Added\|^$' || true
  fi
  xr "$AD_HOST" 'mkdir -p /root/csr && cd /root/csr && [ -f ad01.csr ] || openssl req -new -newkey rsa:2048 -nodes -keyout ad01.key -out ad01.csr -subj "/CN=ad01.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:ad01.poc.lab,DNS:ad01" -addext "keyUsage=digitalSignature,keyEncipherment" -addext "extendedKeyUsage=serverAuth" 2>/dev/null; echo csr-ok'
  mkdir -p "$LAB/ca/exchange"
  docker cp "$(C "$AD_HOST"):/root/csr/ad01.csr" "$(w "$LAB/ca/exchange/ad01.csr")"
  bash "$LAB/ca/sign.sh" "$LAB/ca/exchange/ad01.csr" "$LAB/ca/exchange/ad01-chain.crt"
  docker cp "$(w "$LAB/ca/exchange/ad01-chain.crt")" "$(C "$AD_HOST"):/var/lib/samba/private/tls/cert.pem"
  docker cp "$(w "$LAB/ca/root.crt")" "$(C "$AD_HOST"):/var/lib/samba/private/tls/ca.pem"
  xr "$AD_HOST" 'cp /root/csr/ad01.key /var/lib/samba/private/tls/key.pem && chmod 600 /var/lib/samba/private/tls/key.pem && chmod 644 /var/lib/samba/private/tls/cert.pem /var/lib/samba/private/tls/ca.pem && pkill -x samba; sleep 8; openssl s_client -connect localhost:636 -CAfile /var/lib/samba/private/tls/ca.pem </dev/null 2>/dev/null | grep "Verify return code"'
  xr "$OPS_HOST" 'install -d -o cpadmin -g cpadmin -m 0700 /home/cpadmin/secrets'
  for k in bind:ldap-bind users:ad-test-users; do
    docker exec "$(C "$AD_HOST")" cat "/root/secrets/${k%%:*}.pass" | docker exec -i "$(C "$OPS_HOST")" bash -c "umask 077; cat > /home/cpadmin/secrets/${k#*:}.pass; chown cpadmin:cpadmin /home/cpadmin/secrets/${k#*:}.pass"
  done
  xr "$OPS_HOST" 'ls -la /home/cpadmin/secrets | tail -n +4'

  say "3.5 NTP（repo01 兼任）與負載平衡（lb01 nginx L4）"
  xr "$REPO_HOST" 'printf "[bank-os]\nname=Bank OS packages\nbaseurl=file:///var/www/repo/os/\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\n" > /etc/yum.repos.d/bank-os.repo; rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9; dnf -q -y --disablerepo="*" --enablerepo=bank-os install chrony >/dev/null && printf "local stratum 10\nallow 172.35.0.0/24\ndriftfile /var/lib/chrony/drift\n" > /etc/chrony.conf && systemctl enable --now chronyd >/dev/null 2>&1; systemctl restart chronyd; sleep 2; echo "chronyd $(systemctl is-active chronyd)"'
  xr "$LB_HOST" 'mkdir -p /etc/nginx/stream.d && printf "upstream cp_rest {\n    hash \$remote_addr consistent;\n    server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s;\n    server rest02.poc.lab:8082 max_fails=2 fail_timeout=10s;\n}\nserver { listen 8082; proxy_pass cp_rest; proxy_connect_timeout 3s; proxy_timeout 10m; }\nupstream cp_c3 { server c3-01.poc.lab:9021 max_fails=2 fail_timeout=10s; }\nserver { listen 9021; proxy_pass cp_c3; proxy_connect_timeout 3s; proxy_timeout 1h; }\n" > /etc/nginx/stream.d/cp.conf && nginx -t 2>&1 | tail -1 && nginx -s reload'
}

sign() {
  say "9.2 CA 窗口：簽 ops02 ~/pki/requests/*.csr → ~/pki/incoming/"
  mkdir -p "$LAB/ca/exchange/signed"; rm -rf "$LAB/ca/exchange/requests"
  docker cp "$(C "$OPS_HOST"):/home/cpadmin/pki/requests" "$(w "$LAB/ca/exchange/")"
  for f in "$LAB"/ca/exchange/requests/*.csr; do n=$(basename "$f" .csr); bash "$LAB/ca/sign.sh" "$f" "$LAB/ca/exchange/signed/$n.crt"; done
  for f in "$LAB"/ca/exchange/signed/*.crt; do docker cp "$(w "$f")" "$(C "$OPS_HOST"):/home/cpadmin/pki/incoming/"; done
  xr "$OPS_HOST" 'chown cpadmin:cpadmin /home/cpadmin/pki/incoming/*; ls /home/cpadmin/pki/incoming | wc -l'
}

reset() {
  say "lab 從零：down -v（volume 全刪，落地區 $LAB/landing 保留）→ up -d"
  (cd "$LAB" && docker compose -f compose.yml -f conjur.yml down -v --remove-orphans 2>&1 | tail -1; docker compose -f compose.yml up -d 2>&1 | grep -c Started || true)
  sleep 5; (cd "$LAB" && docker compose -f compose.yml up -d 2>&1 | grep -c Started || true)   # lb01 第一次有時沒起來
  docker start dl01 >/dev/null 2>&1 || true
  docker ps --format '{{.Names}}' | grep -c '^lab-\|^dl01$'
}

case ${1:-} in push|intake|prepare|sign|reset) "$1";; *) sed -n '2,10p' "$0"; exit 1;; esac
