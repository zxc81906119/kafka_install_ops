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

# ---- 延伸站的銀行動作 ----
VAULT_RUN() { docker run --rm --network lab_labnet -v "$(w "$LAB/ca/root.crt"):/root.crt:ro" -v "$(w "$LAB/conjur"):/c" lab-node:1 bash -c "$1"; }
VAULT_ADMIN_TOKEN='T=$(curl -sS --cacert /root.crt -X POST --data-binary @/c/keys/admin.key https://conjur.poc.lab/authn/poc/admin/authenticate | base64 -w0)'

conjur() {   # 15.1：銀行建 Conjur（扮演 CyberArk）、policy、每台 host 身分、ops 身分
  say "15.1 Secrets 團隊：Conjur（conjur.poc.lab，憑證由銀行 CA 簽）、policy kafka、11 台 host 身分、ops 使用者"
  mkdir -p "$LAB/conjur/tls" "$LAB/conjur/keys"
  if docker ps --format '{{.Names}}' | grep -q '^lab-conjur-1$' && [ -s "$LAB/conjur/keys/admin.key" ]; then echo "Conjur 已在跑，略過建置"; else
    (umask 077; docker run --rm cyberark/conjur data-key generate | tr -d '\r\n' > "$LAB/conjur/data_key"; openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$LAB/conjur/db.pass")
    O=$(w "$LAB/conjur/tls"); openssl req -new -newkey rsa:2048 -nodes -keyout "$O/conjur.key" -out "$O/conjur.csr" -subj "/CN=conjur.poc.lab/O=PoC Bank/C=TW" -addext "subjectAltName=DNS:conjur.poc.lab,DNS:conjur" -addext "keyUsage=digitalSignature,keyEncipherment" -addext "extendedKeyUsage=serverAuth" 2>/dev/null
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
    echo "account poc created; https=$(VAULT_RUN 'curl -sS --cacert /root.crt -o /dev/null -w %{http_code} https://conjur.poc.lab/')"
  fi
  apps=$(grep -v '^#' "$INSTALL/conf/apps.txt" | awk '$2=="scram"{print $1}')
  { printf -- '- !policy\n  id: kafka\n  body:\n    - !user ops\n    - !layer hosts\n    - &hosts\n'; for h in $ALL_HOSTS; do printf '      - !host %s\n' "$h"; done
    printf '    - !grant\n      role: !layer hosts\n      members: *hosts\n    - &vars\n      - !variable store-password\n      - !variable ldap-bind-password\n      - !variable audit-password\n'; for a in $apps; do printf '      - !variable scram/%s\n' "$a"; done
    printf '    - !permit\n      role: !layer hosts\n      privileges: [ read, execute ]\n      resources: *vars\n    - !permit\n      role: !user ops\n      privileges: [ read, execute, update ]\n      resources: *vars\n'; } > "$LAB/conjur/kafka-policy.yml"
  VAULT_RUN "set -e; $VAULT_ADMIN_TOKEN; curl -sS --cacert /root.crt -H \"Authorization: Token token=\\\"\$T\\\"\" -X PUT --data-binary @/c/kafka-policy.yml https://conjur.poc.lab/policies/poc/policy/root > /c/keys/policy-result.json; umask 077; python3 - <<'PY'
import json; r=json.load(open(\"/c/keys/policy-result.json\"))
for k,v in r[\"created_roles\"].items():
    name=k.split(\":\")[-1].replace(\"/\",\"_\"); open(f\"/c/keys/{name}.key\",\"w\").write(v[\"api_key\"]); print(k)
PY
rm -f /c/keys/policy-result.json"
  for h in $ALL_HOSTS; do
    [ -s "$LAB/conjur/keys/kafka_$h.key" ] || { echo "缺 kafka_$h.key（policy 已載過、身分已存在；要重發用 Conjur rotate API）"; continue; }
    docker cp "$(w "$LAB/conjur/keys/kafka_$h.key")" "$(C "$h"):/root/conjur.key" && xr "$h" 'g=$(getent group confluent >/dev/null && echo confluent || echo root); install -d -m 0750 -o root -g $g /etc/confluent/conjur; install -m 0640 -o root -g $g /root/conjur.key /etc/confluent/conjur/host.key && rm -f /root/conjur.key' && printf '%s ' "$h"
  done; echo
  docker cp "$(w "$LAB/conjur/keys/ops@kafka.key")" "$(C "$OPS_HOST"):/home/cpadmin/secrets/conjur-ops.key" && xr "$OPS_HOST" 'chown cpadmin:cpadmin /home/cpadmin/secrets/conjur-ops.key && chmod 0600 /home/cpadmin/secrets/conjur-ops.key && echo "ops key -> ~/secrets/conjur-ops.key"'
}

sp() {   # 16.1 + 16.8：passphrase 與 master-key 兩個變數（lab：Conjur 扮演 PAM Vault）
  say "16.1／16.8 Secrets 團隊：變數 kafka/secret-protection/passphrase（銀行產生）、kafka/secret-protection/master-key（ops 可寫、主機可讀）"
  printf -- '- !variable secret-protection/passphrase\n- !variable secret-protection/master-key\n- !permit\n  role: !user ops\n  privileges: [ read, execute, update ]\n  resources: [ !variable secret-protection/passphrase, !variable secret-protection/master-key ]\n- !permit\n  role: !host ops02\n  privileges: [ read, execute ]\n  resource: !variable secret-protection/passphrase\n- !permit\n  role: !layer hosts\n  privileges: [ read, execute ]\n  resource: !variable secret-protection/master-key\n' > "$LAB/conjur/sp-policy.yml"
  [ -s "$LAB/conjur/keys/sp-passphrase.txt" ] || (umask 077; openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 32 > "$LAB/conjur/keys/sp-passphrase.txt")
  VAULT_RUN "set -e; $VAULT_ADMIN_TOKEN; curl -sS --cacert /root.crt -H \"Authorization: Token token=\\\"\$T\\\"\" -X POST --data-binary @/c/sp-policy.yml https://conjur.poc.lab/policies/poc/policy/kafka >/dev/null && echo 'policy: secret-protection/* added'; curl -sS --cacert /root.crt -H \"Authorization: Token token=\\\"\$T\\\"\" -X POST --data-binary @/c/keys/sp-passphrase.txt https://conjur.poc.lab/secrets/poc/variable/kafka%2Fsecret-protection%2Fpassphrase && echo 'passphrase set'"
}

opmenu() {   # 17.1：host opmenu + 兩個變數，API key 交到 ops02 root
  say "17.1 Secrets 團隊：host kafka/opmenu、變數 kafka/ssh/cpadmin、kafka/breakglass/pem；key → ops02:/root/opmenu.key"
  printf -- '- !host opmenu\n- !variable ssh/cpadmin\n- !variable breakglass/pem\n- !permit\n  role: !host opmenu\n  privileges: [ read, execute ]\n  resources: [ !variable ssh/cpadmin, !variable breakglass/pem ]\n- !permit\n  role: !user ops\n  privileges: [ read, execute, update ]\n  resources: [ !variable ssh/cpadmin, !variable breakglass/pem ]\n' > "$LAB/conjur/opmenu-policy.yml"
  VAULT_RUN "set -e; $VAULT_ADMIN_TOKEN; curl -sS --cacert /root.crt -H \"Authorization: Token token=\\\"\$T\\\"\" -X POST --data-binary @/c/opmenu-policy.yml https://conjur.poc.lab/policies/poc/policy/kafka > /c/keys/opmenu-policy.json; umask 077; python3 - <<'PY'
import json; r=json.load(open(\"/c/keys/opmenu-policy.json\"))
for k,v in r[\"created_roles\"].items(): open(\"/c/keys/kafka_opmenu.key\",\"w\").write(v[\"api_key\"]); print(k)
PY
rm -f /c/keys/opmenu-policy.json"
  [ -s "$LAB/conjur/keys/kafka_opmenu.key" ] && docker cp "$(w "$LAB/conjur/keys/kafka_opmenu.key")" "$(C "$OPS_HOST"):/root/opmenu.key" && echo "opmenu host key -> ops02:/root/opmenu.key" || echo "沒有新的 opmenu key（身分已存在）"
}

prometheus() {   # 18.5：銀行的 Prometheus 接上來看 target 與規則，看完收掉
  say "18.5 監控團隊：用 prom/prometheus 載入小安給的三個檔，看 target 與規則"
  mkdir -p "$LAB/bank-prometheus/confluent"; docker rm -f bank-prometheus >/dev/null 2>&1 || true
  for f in prometheus-scrape.yml alert-rules.yml ca.pem scrape.pass; do docker cp "$(C "$OPS_HOST"):/home/cpadmin/monitoring/$f" "$(w "$LAB/bank-prometheus/confluent/$f")"; done
  mv -f "$LAB/bank-prometheus/confluent/prometheus-scrape.yml" "$LAB/bank-prometheus/prometheus.yml"
  hosts=""; for h in $KAFKA_HOSTS $RESTS; do hosts="$hosts --add-host $(fqdn "$h"):$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(C "$h")")"; done
  # shellcheck disable=SC2086
  docker run -d --name bank-prometheus --network lab_labnet $hosts -v "$(w "$LAB/bank-prometheus/prometheus.yml"):/etc/prometheus/prometheus.yml:ro" -v "$(w "$LAB/bank-prometheus/confluent"):/etc/prometheus/confluent:ro" prom/prometheus:v3.5.0 >/dev/null
  sleep 45
  docker run --rm --network lab_labnet lab-node:1 bash -c 'curl -s http://bank-prometheus:9090/api/v1/targets | python3 -c "import json,sys; t=json.load(sys.stdin)[\"data\"][\"activeTargets\"]; print(\"targets up:\", sum(1 for x in t if x[\"health\"]==\"up\"), \"/\", len(t)); [print(\"  down:\", x[\"labels\"][\"instance\"], x[\"lastError\"][:80]) for x in t if x[\"health\"]!=\"up\"]"; curl -s http://bank-prometheus:9090/api/v1/rules | python3 -c "import json,sys; g=json.load(sys.stdin)[\"data\"][\"groups\"]; print(\"alert rules:\", sum(len(x[\"rules\"]) for x in g))"'
  docker rm -f bank-prometheus >/dev/null && echo "bank-prometheus removed"
}

coldboot() {   # 20.4：機房停電：全部主機（含保管庫）同時關、同時開
  say "20.4 冷開機：全部 stop → start，量 broker MDS 與 C3 回來的時間"
  cd "$LAB" && docker compose -f compose.yml -f conjur.yml stop 2>&1 | grep -c Stopped; t0=$(date +%s); docker compose -f compose.yml -f conjur.yml start 2>&1 | grep -c Started
  probe() { docker exec "$(C "$OPS_HOST")" bash -c "curl -sk -o /dev/null -w '%{http_code}' $1"; }
  for i in $(seq 1 60); do a=0; for h in $BROKERS; do [ "$(probe "https://$(fqdn "$h"):8090/v1/metadata/id")" = 200 ] && a=$((a+1)); done; [ "$a" = "$(wc -w <<<"$BROKERS")" ] && break; sleep 10; done; echo "broker 的 MDS 都回 200：$(( $(date +%s) - t0 ))s"
  for i in $(seq 1 60); do [ "$(probe "https://$C3_FQDN:9021/")" = 200 ] && break; sleep 10; done; echo "C3 回 200：$(( $(date +%s) - t0 ))s"
  docker exec "$(C "${BROKERS%% *}")" bash -c 'echo "kb01 confluent-server 重試次數：$(journalctl -u confluent-server --since "-10min" --no-pager | grep -c "Scheduled restart job")"'
}

case ${1:-} in push|intake|prepare|sign|reset|conjur|sp|opmenu|prometheus|coldboot) "$1";; *) sed -n '2,10p' "$0"; echo "  延伸：conjur（15.1）sp（16.1/16.8）opmenu（17.1）prometheus（18.5）coldboot（20.4）"; exit 1;; esac
