#!/usr/bin/env bash
# install/lab/bank-sim.sh — lab 專用：在 Windows Git Bash 扮演「銀行」，做手把手文件裡橘色標籤的事。
# 正式環境沒有這支；安裝腳本只會印「請銀行做」。lab 依 docs/journey-src/journey.md 第 0 章建好（~/kafka-lab）。
#   bash bank-sim.sh push      把 install/ 送到 ops02（cpadmin）與 dl01（root）
#   bash bank-sim.sh intake    2.2 檔案交換：落地區 → ops02 ~/landing（唯讀）
#   bash bank-sim.sh prepare   3.1 公鑰派送、3.2 OS 套件庫＋根憑證信任、3.4 AD、3.5 NTP 與 LB
#   bash bank-sim.sh sign      9.2 銀行 CA 簽 ops02 ~/pki/requests/*.csr → ~/pki/incoming/
#   bash bank-sim.sh reset     down -v 後重新 up（從零）；dl01 保留
#   bash bank-sim.sh pvwa-key  客戶模式：CyberArk 產生 cpadmin 金鑰對（$LAB/pvwa/），prepare 改派這把的公鑰
set -euo pipefail
export MSYS_NO_PATHCONV=1
LAB=${LAB:-$HOME/kafka-lab}; INSTALL=$(cd "$(dirname "$0")/.." && pwd)
source "$INSTALL/conf/site.env"
container_of() { echo "lab-$1-1"; }          # 主機短名 → lab 的容器名稱
windows_path() { cygpath -m "$1"; }       # Git Bash 路徑 → docker 看得懂的 Windows 路徑
as_root_on() { docker exec "$(container_of "$1")" bash -c "$2"; }   # 在某台主機以 root 跑一段指令（扮演銀行的 OS 團隊）
as_cpadmin_on_ops() {   # 在操作機以 cpadmin 跑一段指令
  docker exec -u cpadmin -w /home/cpadmin "$(container_of "$OPS_HOST")" bash -c "$1"; }
announce() { printf '\n[bank] %s\n' "$*"; }

push() {
  announce "install/ → $OPS_HOST:/home/cpadmin/install、dl01:/root/install"
  as_root_on "$OPS_HOST" 'rm -rf /home/cpadmin/install'; docker cp "$(windows_path "$INSTALL")" "$(container_of "$OPS_HOST"):/home/cpadmin/install"
  as_root_on "$OPS_HOST" 'chown -R cpadmin:cpadmin /home/cpadmin/install && chmod +x /home/cpadmin/install/install.sh /home/cpadmin/install/steps/*.sh && ls /home/cpadmin/install/steps | wc -l'
  docker exec dl01 rm -rf /root/install; docker cp "$(windows_path "$INSTALL")" dl01:/root/install; docker exec dl01 bash -c 'chmod +x /root/install/steps/*.sh; ls /root/install/steps | wc -l'
}

intake() {
  announce "2.2 檔案交換：$LAB/landing → $OPS_HOST:~/landing（唯讀）"
  as_root_on "$OPS_HOST" 'install -d -o cpadmin -g cpadmin /home/cpadmin/landing'
  docker cp "$(windows_path "$LAB/landing")/." "$(container_of "$OPS_HOST"):/home/cpadmin/landing/"
  as_root_on "$OPS_HOST" 'chown -R cpadmin:cpadmin /home/cpadmin/landing && chmod -R a-w /home/cpadmin/landing && echo "$(find /home/cpadmin/landing -type f | wc -l) files, $(du -sh /home/cpadmin/landing | cut -f1)"'
}

# 客戶模式（SSH_KEY_SOURCE=agent）：cpadmin 的金鑰對由 CyberArk 產生，lab 放在 $LAB/pvwa/ 扮演 PVWA 裡的那個 object
PVWA_DIR=$LAB/pvwa
pvwa_key() {
  announce "CyberArk：產生 cpadmin（操作機 → 各主機）的金鑰對，私鑰留在 PVWA（$PVWA_DIR，0600）"
  mkdir -p "$PVWA_DIR"
  [ -f "$PVWA_DIR/cpadmin_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C "cpadmin@$OPS_HOST (cyberark)" -f "$PVWA_DIR/cpadmin_ed25519"
  chmod 600 "$PVWA_DIR/cpadmin_ed25519"; cat "$PVWA_DIR/cpadmin_ed25519.pub"
}

prepare() {
  # 公鑰：看操作機 site.env 的 SSH_KEY_SOURCE——agent（客戶模式）用 CyberArk 產生的那把（pvwa_key），
  # 其他用操作機自己產生的（lab 模式，第 3 站）。不能只看 pvwa/ 有沒有金鑰：前一輪客戶模式留下的那把會被誤用
  local key_source
  key_source=$(as_root_on "$OPS_HOST" "sed -n 's/^SSH_KEY_SOURCE=\\([a-z]*\\).*/\\1/p' /home/cpadmin/install/conf/site.env" 2>/dev/null)
  if [ "$key_source" = agent ] && [ -f "$PVWA_DIR/cpadmin_ed25519.pub" ]; then
    announce "3.1 OS 團隊（SSH Key Manager）：CyberArk 的 cpadmin 公鑰 → 所有主機 cpadmin 與 repo01 的 repodeploy"
    # 用 stdin 送（ops02 的 /tmp 是 tmpfs，docker cp 寫進去容器裡看不到）
    docker exec -i "$(container_of "$OPS_HOST")" bash -c 'cat > /tmp/cpadmin-cyberark.pub' < "$PVWA_DIR/cpadmin_ed25519.pub"
    public_key_source=/tmp/cpadmin-cyberark.pub
  else
    announce "3.1 OS 團隊：ops02 的公鑰 → 所有主機 cpadmin 與 repo01 的 repodeploy（共用 authorized_keys.d volume）"
    public_key_source=/home/cpadmin/.ssh/id_ed25519.pub
  fi
  as_root_on "$OPS_HOST" 'k=$(cat '"$public_key_source"'); install -m 0644 -o root -g root /dev/stdin /etc/ssh/authorized_keys.d/cpadmin <<<"$k"; install -m 0644 -o root -g root /dev/stdin /etc/ssh/authorized_keys.d/repodeploy <<<"$k"; ls /etc/ssh/authorized_keys.d/'

  # repo01 的 HTTPS 憑證要驗得過 ca/root.crt：手把手第 20 章演練過換 CA 的 lab，repo.crt 會是 G2／G3 簽的，用現在的 CA 重簽
  local repo_tls=$LAB/images/web/tls
  if ! openssl verify -CAfile "$(windows_path "$LAB/ca/root.crt")" -untrusted "$(windows_path "$repo_tls/repo.crt")" "$(windows_path "$repo_tls/repo.crt")" >/dev/null 2>&1; then
    announce "3.2 套件庫管理員：repo01 的 HTTPS 憑證驗不過目前的根（之前換過 CA），用現在的 CA 重簽"
    openssl req -new -key "$(windows_path "$repo_tls/repo.key")" -out "$(windows_path "$repo_tls/repo.csr")" -subj "/CN=repo01.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:repo01.poc.lab,DNS:repo01" -addext "extendedKeyUsage=serverAuth" 2>/dev/null
    bash "$LAB/ca/sign.sh" "$repo_tls/repo.csr" "$repo_tls/repo.crt" && rm -f "$repo_tls/repo.csr"
    docker exec "$(container_of repo01)" systemctl restart httpd
  fi

  announce "3.2 OS 套件庫（repo01 /os/）：有現成的 $LAB/bank-os-repo 就直接用，沒有才從 Rocky repo 抓"
  if [ ! -f "$LAB/bank-os-repo/repodata/repomd.xml" ]; then
    docker run --rm -v "$(windows_path "$LAB/bank-os-repo"):/out" lab-node:1 bash -c '
set -e
R="--disablerepo=* --enablerepo=baseos,appstream,extras"
ok=0; for try in 1 2 3; do dnf -q $R download --resolve --arch x86_64 --arch noarch --destdir /out/Packages chrony firewalld cyrus-sasl openssl-devel httpd mod_ssl python3-dnf-plugin-versionlock nmap-ncat jq gettext openldap-clients createrepo_c tar gzip openssl sudo openssh-server diffutils less vim-minimal bind-utils lsof procps-ng rsync bash-completion && { ok=1; break; }; echo "鏡像站還沒同步好，60 秒後重試（第 $try 次）" >&2; dnf -q clean metadata; sleep 60; done; [ $ok = 1 ]
dnf -q -y $R install createrepo_c >/dev/null
createrepo_c -q /out
ls /out/Packages | wc -l'
  fi
  docker cp "$(windows_path "$LAB/bank-os-repo")/." "$(container_of "$REPO_HOST"):/var/www/repo/os/"
  as_root_on "$REPO_HOST" 'chown -R repodeploy:repodeploy /var/www/repo/os; ls /var/www/repo/os'
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
  as_root_on "$OPS_HOST" 'install -d -o cpadmin -g cpadmin -m 0700 /home/cpadmin/secrets'
  for k in bind:ldap-bind users:ad-test-users; do
    docker exec "$(container_of "$AD_HOST")" cat "/root/secrets/${k%%:*}.pass" | docker exec -i "$(container_of "$OPS_HOST")" bash -c "umask 077; cat > /home/cpadmin/secrets/${k#*:}.pass; chown cpadmin:cpadmin /home/cpadmin/secrets/${k#*:}.pass"
  done
  as_root_on "$OPS_HOST" 'ls -la /home/cpadmin/secrets | tail -n +4'

  announce "3.5 NTP（repo01 兼任）與負載平衡（lb01 nginx L4）"
  install -m 0755 "$INSTALL/lab/lb-member.sh" "$LAB/lb-member.sh"   # 3.5：LB 團隊停用／恢復 REST 成員（手把手 12.1 的五步）
  as_root_on "$REPO_HOST" 'printf "[bank-os]\nname=Bank OS packages\nbaseurl=file:///var/www/repo/os/\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9\n" > /etc/yum.repos.d/bank-os.repo; rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9; dnf -q -y --disablerepo="*" --enablerepo=bank-os install chrony >/dev/null && printf "local stratum 10\nallow 172.35.0.0/24\ndriftfile /var/lib/chrony/drift\n" > /etc/chrony.conf && systemctl enable --now chronyd >/dev/null 2>&1; systemctl restart chronyd; sleep 2; echo "chronyd $(systemctl is-active chronyd)"'
  as_root_on "$LB_HOST" 'mkdir -p /etc/nginx/stream.d && printf "upstream cp_rest {\n    hash \$remote_addr consistent;\n    server rest01.poc.lab:8082 max_fails=2 fail_timeout=10s;\n    server rest02.poc.lab:8082 max_fails=2 fail_timeout=10s;\n}\nserver { listen 8082; proxy_pass cp_rest; proxy_connect_timeout 3s; proxy_timeout 10m; }\nupstream cp_c3 { server c3-01.poc.lab:9021 max_fails=2 fail_timeout=10s; }\nserver { listen 9021; proxy_pass cp_c3; proxy_connect_timeout 3s; proxy_timeout 1h; }\n" > /etc/nginx/stream.d/cp.conf && nginx -t 2>&1 | tail -1 && nginx -s reload'
}

sign() {
  announce "9.2 CA 窗口：簽 ops02 ~/pki/requests/*.csr → ~/pki/incoming/"
  mkdir -p "$LAB/ca/exchange/signed"; rm -rf "$LAB/ca/exchange/requests"
  docker cp "$(container_of "$OPS_HOST"):/home/cpadmin/pki/requests" "$(windows_path "$LAB/ca/exchange/")"
  for f in "$LAB"/ca/exchange/requests/*.csr; do n=$(basename "$f" .csr); bash "$LAB/ca/sign.sh" "$f" "$LAB/ca/exchange/signed/$n.crt"; done
  for f in "$LAB"/ca/exchange/signed/*.crt; do docker cp "$(windows_path "$f")" "$(container_of "$OPS_HOST"):/home/cpadmin/pki/incoming/"; done
  as_root_on "$OPS_HOST" 'chown cpadmin:cpadmin /home/cpadmin/pki/incoming/*; ls /home/cpadmin/pki/incoming | wc -l'
}

reset() {
  announce "lab 從零：down -v（volume 全刪，落地區 $LAB/landing 保留）→ up -d"
  (cd "$LAB" && docker compose -f compose.yml down -v --remove-orphans 2>&1 | tail -1; docker compose -f compose.yml up -d 2>&1 | grep -c Started || true)
  sleep 5; (cd "$LAB" && docker compose -f compose.yml up -d 2>&1 | grep -c Started || true)   # lb01 第一次有時沒起來
  docker start dl01 >/dev/null 2>&1 || true
  docker ps --format '{{.Names}}' | grep -c '^lab-\|^dl01$'
}

prometheus() {   # 17.5：銀行的 Prometheus 接上來看 target 與規則，看完收掉
  announce "17.5 監控團隊：用 prom/prometheus 載入小安給的三個檔，看 target 與規則"
  mkdir -p "$LAB/bank-prometheus/confluent"; docker rm -f bank-prometheus >/dev/null 2>&1 || true
  for f in prometheus-scrape.yml alert-rules.yml ca.pem scrape.pass; do docker cp "$(container_of "$OPS_HOST"):/home/cpadmin/monitoring/$f" "$(windows_path "$LAB/bank-prometheus/confluent/$f")"; done
  mv -f "$LAB/bank-prometheus/confluent/prometheus-scrape.yml" "$LAB/bank-prometheus/prometheus.yml"
  hosts=""; for h in $KAFKA_HOSTS $RESTS; do hosts="$hosts --add-host $(fqdn "$h"):$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(container_of "$h")")"; done
  # shellcheck disable=SC2086
  docker run -d --name bank-prometheus --network lab_labnet $hosts -v "$(windows_path "$LAB/bank-prometheus/prometheus.yml"):/etc/prometheus/prometheus.yml:ro" -v "$(windows_path "$LAB/bank-prometheus/confluent"):/etc/prometheus/confluent:ro" prom/prometheus:v3.5.0 >/dev/null
  sleep 45
  targets_json=$(docker run --rm --network lab_labnet lab-node:1 curl -s http://bank-prometheus:9090/api/v1/targets)
  rules_json=$(docker run --rm --network lab_labnet lab-node:1 curl -s http://bank-prometheus:9090/api/v1/rules)
  targets_up=$(grep -o '"health":"up"' <<<"$targets_json" | wc -l)
  targets_total=$(grep -o '"health":"[a-z]*"' <<<"$targets_json" | wc -l)
  echo "targets up: $targets_up / $targets_total"
  echo "alert rules: $(grep -o '"type":"alerting"' <<<"$rules_json" | wc -l)"
  docker rm -f bank-prometheus >/dev/null && echo "bank-prometheus removed"
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
  docker cp "$(container_of "$OPS_HOST"):/home/cpadmin/pki/next/requests" "$(windows_path "$LAB/ca/exchange/next/")"
  for csr in "$LAB"/ca/exchange/next/requests/*.csr; do cert_name=$(basename "$csr" .csr); bash "$LAB/$ca_dir/sign.sh" "$csr" "$LAB/ca/exchange/next/signed/$cert_name.crt"; done
  for cert_file in "$LAB"/ca/exchange/next/signed/*.crt; do docker cp "$(windows_path "$cert_file")" "$(container_of "$OPS_HOST"):/home/cpadmin/pki/next/incoming/"; done
  as_root_on "$OPS_HOST" 'chown cpadmin:cpadmin /home/cpadmin/pki/next/incoming/*; ls /home/cpadmin/pki/next/incoming | wc -l'
}

lb_watch() {   # 12.1（lab）：扮演 LB 團隊：操作機出現 ~/lb-requests/<主機>.<down|up> 就照做、回覆 .done；$LAB/lb-watch.stop 出現就結束
  local request host action stop_file=${1:-$LAB/lb-watch.stop}
  rm -f "$stop_file"; announce "LB 團隊待命（結束：touch $stop_file）"
  while [ ! -f "$stop_file" ]; do
    for request in $(as_cpadmin_on_ops 'cd ~/lb-requests 2>/dev/null && for f in *.down *.up; do [ -f "$f" ] && [ ! -f "$f.done" ] && echo "$f"; done' 2>/dev/null); do
      host=${request%.*}; action=${request##*.}
      bash "$LAB/lb-member.sh" "$host" "$action" && as_cpadmin_on_ops "touch ~/lb-requests/$request.done"
    done
    sleep 2
  done
}

case ${1:-} in push|intake|prepare|sign|reset|prometheus|coldboot) "$1";;
  lb-watch) lb_watch "${2:-}";;
  sign-next) sign_next "${2:-ca}";; pvwa-key) pvwa_key;; *) sed -n '2,11p' "$0"; echo "  延伸：prometheus（17.5）coldboot（19.4）sign-next pvwa-key lb-watch"; exit 1;; esac
