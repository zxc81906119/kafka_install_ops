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
container_of() { echo "lab-$1-1"; }          # 主機短名 → lab 的容器名稱
windows_path() { cygpath -m "$1"; }       # Git Bash 路徑 → docker 看得懂的 Windows 路徑
as_root_on() { docker exec "$(container_of "$1")" bash -c "$2"; }   # 在某台主機以 root 跑一段指令（扮演銀行的 OS 團隊）
as_cpadmin_on_ops() {   # 在操作機以 cpadmin 跑一段指令
  docker exec -u cpadmin -w /home/cpadmin "$(container_of "$OPS_HOST")" bash -c "$1"; }
announce() { printf '\n[bank] %s\n' "$*"; }

# save_created_api_keys <policy 載入結果.json>：Conjur 對每個新建的身分回一把 API key，各存成 conjur/keys/<名稱>.key（0600）
#   poc:host:kafka/ops02 → kafka_ops02.key；poc:user:ops@kafka → ops@kafka.key。只用 grep／sed，不靠 python。
save_created_api_keys() {
  local result_file=$1 created_role role_id api_key key_name
  grep -o '"[^"]*":{[^{}]*"api_key":"[^"]*"[^{}]*}' "$result_file" | while IFS= read -r created_role; do
    role_id=$(sed 's/^"\([^"]*\)".*/\1/' <<<"$created_role")
    api_key=$(sed 's/.*"api_key":"\([^"]*\)".*/\1/' <<<"$created_role")
    key_name=$(sed 's/^[^:]*:[^:]*://; s|/|_|g' <<<"$role_id")
    (umask 077; printf '%s' "$api_key" > "$LAB/conjur/keys/$key_name.key")
    echo "$role_id"
  done
  rm -f "$result_file"
}

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

prepare() {
  announce "3.1 OS 團隊：ops02 的公鑰 → 所有主機 cpadmin 與 repo01 的 repodeploy（共用 authorized_keys.d volume）"
  as_root_on "$OPS_HOST" 'k=$(cat /home/cpadmin/.ssh/id_ed25519.pub); install -m 0644 -o root -g root /dev/stdin /etc/ssh/authorized_keys.d/cpadmin <<<"$k"; install -m 0644 -o root -g root /dev/stdin /etc/ssh/authorized_keys.d/repodeploy <<<"$k"; ls /etc/ssh/authorized_keys.d/'

  announce "3.2 OS 套件庫（repo01 /os/）：有現成的 $LAB/bank-os-repo 就直接用，沒有才從 Rocky repo 抓"
  if [ ! -f "$LAB/bank-os-repo/repodata/repomd.xml" ]; then
    docker run --rm -v "$(windows_path "$LAB/bank-os-repo"):/out" lab-node:1 bash -c '
set -e
R="--disablerepo=* --enablerepo=baseos,appstream,extras"
dnf -q $R download --resolve --arch x86_64 --arch noarch --destdir /out/Packages java-21-openjdk-headless chrony firewalld cyrus-sasl openssl-devel httpd mod_ssl python3-dnf-plugin-versionlock nmap-ncat jq gettext openldap-clients createrepo_c tar gzip openssl sudo openssh-server diffutils less vim-minimal bind-utils lsof procps-ng rsync bash-completion
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
  if as_root_on "$AD_HOST" 'samba-tool ou list 2>/dev/null | grep -q "^OU=Confluent,"'; then echo "AD 物件已存在，略過建立"; else
    as_root_on "$AD_HOST" 'install -d -m 0700 /root/secrets && for k in bind users; do openssl rand -base64 24 | tr -dc "A-Za-z0-9" | head -c 20 > /root/secrets/$k.pass; done; B=DC=corp,DC=poc,DC=lab; samba-tool ou create "OU=Confluent,$B" && for ou in Users Groups Service; do samba-tool ou create "OU=$ou,OU=Confluent,$B"; done && samba-tool user create svc-mds-bind "$(cat /root/secrets/bind.pass)" --userou="OU=Service,OU=Confluent" --description="read-only LDAP bind for Confluent MDS" && for g in kafka-admins kafka-operators kafka-devs; do samba-tool group add "$g" --groupou="OU=Groups,OU=Confluent"; done && for p in alice:kafka-admins bob:kafka-operators carol:kafka-devs; do u=${p%%:*}; g=${p#*:}; samba-tool user create "$u" "$(cat /root/secrets/users.pass)" --userou="OU=Users,OU=Confluent" && samba-tool group addmembers "$g" "$u"; done; samba-tool group listmembers kafka-admins' | grep -v '^User\|^Added\|^$' || true
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
  (cd "$LAB" && docker compose -f compose.yml -f conjur.yml down -v --remove-orphans 2>&1 | tail -1; docker compose -f compose.yml up -d 2>&1 | grep -c Started || true)
  sleep 5; (cd "$LAB" && docker compose -f compose.yml up -d 2>&1 | grep -c Started || true)   # lb01 第一次有時沒起來
  docker start dl01 >/dev/null 2>&1 || true
  docker ps --format '{{.Names}}' | grep -c '^lab-\|^dl01$'
}

# ---- 延伸站的銀行動作 ----
run_as_conjur_admin() { docker run --rm --network lab_labnet -v "$(windows_path "$LAB/ca/root.crt"):/root.crt:ro" -v "$(windows_path "$LAB/conjur"):/c" lab-node:1 bash -c "$1"; }
CONJUR_ADMIN_TOKEN='T=$(curl -sS --cacert /root.crt -X POST --data-binary @/c/keys/admin.key https://conjur.poc.lab/authn/poc/admin/authenticate | base64 -w0)'

conjur() {   # 15.1：銀行建 Conjur（扮演 CyberArk）、policy、每台 host 身分、ops 身分
  announce "15.1 Secrets 團隊：Conjur（conjur.poc.lab，憑證由銀行 CA 簽）、policy kafka、11 台 host 身分、ops 使用者"
  mkdir -p "$LAB/conjur/tls" "$LAB/conjur/keys"
  if grep -q '^lab-conjur-1$' <<<"$(docker ps --format '{{.Names}}')" &&[ -s "$LAB/conjur/keys/admin.key" ]; then echo "Conjur 已在跑，略過建置"; else
    (umask 077; docker run --rm cyberark/conjur data-key generate | tr -d '\r\n' > "$LAB/conjur/data_key"; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$LAB/conjur/db.pass")
    O=$(windows_path "$LAB/conjur/tls"); openssl req -new -newkey rsa:2048 -nodes -keyout "$O/conjur.key" -out "$O/conjur.csr" -subj "/CN=conjur.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:conjur.poc.lab,DNS:conjur" -addext "keyUsage=digitalSignature,keyEncipherment" -addext "extendedKeyUsage=serverAuth" 2>/dev/null
    bash "$LAB/ca/sign.sh" "$LAB/conjur/tls/conjur.csr" "$LAB/conjur/tls/conjur.crt"
    printf 'events {}\nhttp {\n  server {\n    listen 443 ssl;\n    server_name conjur.poc.lab;\n    ssl_certificate     /etc/nginx/tls/conjur.crt;\n    ssl_certificate_key /etc/nginx/tls/conjur.key;\n    ssl_protocols TLSv1.2 TLSv1.3;\n    location / { proxy_pass http://conjur:80; proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto https; }\n  }\n}\n' > "$LAB/conjur/nginx.conf"
    (umask 077; printf 'POSTGRES_PASSWORD=%s\nDATABASE_URL=postgres://postgres:%s@conjur-db/postgres\nCONJUR_DATA_KEY=%s\nCONJUR_AUTHENTICATORS=authn\n' "$(cat "$LAB/conjur/db.pass")" "$(cat "$LAB/conjur/db.pass")" "$(cat "$LAB/conjur/data_key")" > "$LAB/conjur/conjur.env")
    cat > "$LAB/conjur.yml" <<'EOF'
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
    (cd "$LAB" && docker compose -f compose.yml -f conjur.yml up -d conjur-db conjur conjur-proxy 2>&1 | grep -c Started)
    for i in $(seq 1 30); do docker exec lab-conjur-1 conjurctl wait >/dev/null 2>&1 && break; sleep 2; done
    (umask 077; docker exec lab-conjur-1 conjurctl account create poc | grep -o 'API key for admin: .*' | awk '{print $NF}' | tr -d '\r\n' > "$LAB/conjur/keys/admin.key")
    echo "account poc created; https=$(run_as_conjur_admin 'curl -sS --cacert /root.crt -o /dev/null -w %{http_code} https://conjur.poc.lab/')"
  fi
  apps=$(grep -v '^#' "$INSTALL/conf/apps.txt" | awk '$2=="scram"{print $1}')
  { printf -- '- !policy\n  id: kafka\n  body:\n    - !user ops\n    - !layer hosts\n    - &hosts\n'; for h in $ALL_HOSTS; do printf '      - !host %s\n' "$h"; done
    printf '    - !grant\n      role: !layer hosts\n      members: *hosts\n    - &vars\n      - !variable store-password\n      - !variable ldap-bind-password\n      - !variable audit-password\n'; for a in $apps; do printf '      - !variable scram/%s\n' "$a"; done
    printf '    - !permit\n      role: !layer hosts\n      privileges: [ read, execute ]\n      resources: *vars\n    - !permit\n      role: !user ops\n      privileges: [ read, execute, update ]\n      resources: *vars\n'; } > "$LAB/conjur/kafka-policy.yml"
  run_as_conjur_admin "set -e; $CONJUR_ADMIN_TOKEN; curl -sS --cacert /root.crt -H \"Authorization: Token token=\\\"\$T\\\"\" -X PUT --data-binary @/c/kafka-policy.yml https://conjur.poc.lab/policies/poc/policy/root > /c/keys/policy-result.json"
  save_created_api_keys "$LAB/conjur/keys/policy-result.json"
  for h in $ALL_HOSTS; do
    [ -s "$LAB/conjur/keys/kafka_$h.key" ] || { echo "缺 kafka_$h.key（policy 已載過、身分已存在；要重發用 Conjur rotate API）"; continue; }
    docker cp "$(windows_path "$LAB/conjur/keys/kafka_$h.key")" "$(container_of "$h"):/root/conjur.key" && as_root_on "$h" 'g=$(getent group confluent >/dev/null && echo confluent || echo root); install -d -m 0750 -o root -g $g /etc/confluent/conjur; install -m 0640 -o root -g $g /root/conjur.key /etc/confluent/conjur/host.key && rm -f /root/conjur.key' && printf '%s ' "$h"
  done; echo
  docker cp "$(windows_path "$LAB/conjur/keys/ops@kafka.key")" "$(container_of "$OPS_HOST"):/home/cpadmin/secrets/conjur-ops.key" && as_root_on "$OPS_HOST" 'chown cpadmin:cpadmin /home/cpadmin/secrets/conjur-ops.key && chmod 0600 /home/cpadmin/secrets/conjur-ops.key && echo "ops key -> ~/secrets/conjur-ops.key"'
}

sp() {   # 16.1 + 16.8：passphrase 與 master-key 兩個變數（lab：Conjur 扮演 PAM Vault）
  announce "16.1／16.8 Secrets 團隊：變數 kafka/secret-protection/passphrase（銀行產生）、kafka/secret-protection/master-key（ops 可寫、主機可讀）"
  printf -- '- !variable secret-protection/passphrase\n- !variable secret-protection/master-key\n- !permit\n  role: !user ops\n  privileges: [ read, execute, update ]\n  resources: [ !variable secret-protection/passphrase, !variable secret-protection/master-key ]\n- !permit\n  role: !host ops02\n  privileges: [ read, execute ]\n  resource: !variable secret-protection/passphrase\n- !permit\n  role: !layer hosts\n  privileges: [ read, execute ]\n  resource: !variable secret-protection/master-key\n' > "$LAB/conjur/sp-policy.yml"
  [ -s "$LAB/conjur/keys/sp-passphrase.txt" ] || (umask 077; openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > "$LAB/conjur/keys/sp-passphrase.txt")
  run_as_conjur_admin "set -e; $CONJUR_ADMIN_TOKEN; curl -sS --cacert /root.crt -H \"Authorization: Token token=\\\"\$T\\\"\" -X POST --data-binary @/c/sp-policy.yml https://conjur.poc.lab/policies/poc/policy/kafka >/dev/null && echo 'policy: secret-protection/* added'; curl -sS --cacert /root.crt -H \"Authorization: Token token=\\\"\$T\\\"\" -X POST --data-binary @/c/keys/sp-passphrase.txt https://conjur.poc.lab/secrets/poc/variable/kafka%2Fsecret-protection%2Fpassphrase && echo 'passphrase set'"
}

opmenu() {   # 17.1：host opmenu + 兩個變數，API key 交到 ops02 root
  announce "17.1 Secrets 團隊：host kafka/opmenu、變數 kafka/ssh/cpadmin、kafka/breakglass/pem；key → ops02:/root/opmenu.key"
  printf -- '- !host opmenu\n- !variable ssh/cpadmin\n- !variable breakglass/pem\n- !permit\n  role: !host opmenu\n  privileges: [ read, execute ]\n  resources: [ !variable ssh/cpadmin, !variable breakglass/pem ]\n- !permit\n  role: !user ops\n  privileges: [ read, execute, update ]\n  resources: [ !variable ssh/cpadmin, !variable breakglass/pem ]\n' > "$LAB/conjur/opmenu-policy.yml"
  run_as_conjur_admin "set -e; $CONJUR_ADMIN_TOKEN; curl -sS --cacert /root.crt -H \"Authorization: Token token=\\\"\$T\\\"\" -X POST --data-binary @/c/opmenu-policy.yml https://conjur.poc.lab/policies/poc/policy/kafka > /c/keys/opmenu-policy.json"
  save_created_api_keys "$LAB/conjur/keys/opmenu-policy.json"
  [ -s "$LAB/conjur/keys/kafka_opmenu.key" ] && docker cp "$(windows_path "$LAB/conjur/keys/kafka_opmenu.key")" "$(container_of "$OPS_HOST"):/root/opmenu.key" && echo "opmenu host key -> ops02:/root/opmenu.key" || echo "沒有新的 opmenu key（身分已存在）"
}

prometheus() {   # 18.5：銀行的 Prometheus 接上來看 target 與規則，看完收掉
  announce "18.5 監控團隊：用 prom/prometheus 載入小安給的三個檔，看 target 與規則"
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

coldboot() {   # 20.4：機房停電：全部主機（含保管庫）同時關、同時開
  announce "20.4 冷開機：全部 stop → start，量 broker MDS 與 C3 回來的時間"
  cd "$LAB" && docker compose -f compose.yml -f conjur.yml stop 2>&1 | grep -c Stopped; t0=$(date +%s); docker compose -f compose.yml -f conjur.yml start 2>&1 | grep -c Started
  probe() { docker exec "$(container_of "$OPS_HOST")" bash -c "curl -sk -o /dev/null -w '%{http_code}' $1"; }
  for i in $(seq 1 60); do a=0; for h in $BROKERS; do [ "$(probe "https://$(fqdn "$h"):8090/v1/metadata/id")" = 200 ] && a=$((a+1)); done; [ "$a" = "$(wc -w <<<"$BROKERS")" ] && break; sleep 10; done; echo "broker 的 MDS 都回 200：$(( $(date +%s) - t0 ))s"
  for i in $(seq 1 60); do [ "$(probe "https://$C3_FQDN:9021/")" = 200 ] && break; sleep 10; done; echo "C3 回 200：$(( $(date +%s) - t0 ))s"
  docker exec "$(container_of "${BROKERS%% *}")" bash -c 'echo "kb01 confluent-server 重試次數：$(journalctl -u confluent-server --since "-10min" --no-pager | grep -c "Scheduled restart job")"'
}

sign_next() {   # 21.2.2：簽 ops02 ~/pki/next/requests/*.csr（換發）；參數給 CA 目錄（預設 ca，換 CA 階段二用 ca/g2）
  local ca_dir=${1:-ca} csr cert_name
  announce "21.2.2 CA 窗口：用 $ca_dir 簽 ~/pki/next/requests/*.csr → ~/pki/next/incoming/"
  rm -rf "$LAB/ca/exchange/next"; mkdir -p "$LAB/ca/exchange/next/signed"
  docker cp "$(container_of "$OPS_HOST"):/home/cpadmin/pki/next/requests" "$(windows_path "$LAB/ca/exchange/next/")"
  for csr in "$LAB"/ca/exchange/next/requests/*.csr; do cert_name=$(basename "$csr" .csr); bash "$LAB/$ca_dir/sign.sh" "$csr" "$LAB/ca/exchange/next/signed/$cert_name.crt"; done
  for cert_file in "$LAB"/ca/exchange/next/signed/*.crt; do docker cp "$(windows_path "$cert_file")" "$(container_of "$OPS_HOST"):/home/cpadmin/pki/next/incoming/"; done
  as_root_on "$OPS_HOST" 'chown cpadmin:cpadmin /home/cpadmin/pki/next/incoming/*; ls /home/cpadmin/pki/next/incoming | wc -l'
}

case ${1:-} in push|intake|prepare|sign|reset|conjur|sp|opmenu|prometheus|coldboot) "$1";;
  sign-next) sign_next "${2:-ca}";; *) sed -n '2,10p' "$0"; echo "  延伸：conjur（15.1）sp（16.1/16.8）opmenu（17.1）prometheus（18.5）coldboot（20.4）"; exit 1;; esac
