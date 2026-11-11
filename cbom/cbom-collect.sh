#!/usr/bin/env bash
# cbom-collect.sh —— 收集密碼學資產盤點（CBOM）的原料（手把手第 33 章 33.4–33.7 的同一套指令）
# where: ops02（root）；全程只讀：不取私鑰與密碼，平台主機上不放新程式。
#
#   bash cbom-collect.sh [--roles "controller broker rest c3 shared"] [--jfr 秒數] [--out 目錄] [--tar]
#     --roles   這次要盤的元件，空白或逗號隔開；預設全部（完整盤點）
#     --jfr     另外用 JFR 對每台的服務錄這麼多秒（執行期證據）；預設不錄
#     --out     原料放哪裡；預設 ~/cbom/raw（每次重新收，舊的先清掉）
#     --tar     收完把原料打成 tar.gz 印到 stdout（訊息都印到 stderr）；給 Jenkins 取回用
#
#   給 Jenkins 的受限入口（操作機不開放 root 用 ssh 登入，所以用專用帳號 cbomsvc＋一條 sudo）：
#     cbomsvc 的 authorized_keys 裡，Jenkins 那把公鑰前面加（整行不換行）
#       command="sudo /opt/cbom/bin/cbom-collect.sh --from-ssh \"$SSH_ORIGINAL_COMMAND\"",no-pty,no-port-forwarding,
#       no-agent-forwarding,no-X11-forwarding,from="<Jenkins agent 的 IP>"
#     /etc/sudoers.d/cbomsvc：cbomsvc ALL=(root) NOPASSWD: /opt/cbom/bin/cbom-collect.sh --from-ssh *
#   這把金鑰連進來只會執行這支腳本，不能開 shell。連線時帶的指令只接受這種寫法（其他一律拒絕）：
#     collect roles=controller,broker jfr=60
#
# 需要什麼：/opt/cbom/bin 的工具（33.3）、/etc/cbom/cbom.conf（主機清單）、~/conf/client-admin.properties、
#           cpuser 的 ssh（讀 properties 與 /etc/confluent/ssl 的清單要 sudo，見第 33 章的 sudoers 清單）。
# 產出什麼：原料目錄（collect.env 記這次的範圍）；--tar 時另外印出 tar.gz。
# 能不能重跑：可以，每次都重新收。
# 結束碼：0 成功；1 參數不對或前提不在；2 收集途中失敗。
set -uo pipefail

CBOM_HOME=/opt/cbom
CONF=${CBOM_CONF:-/etc/cbom/cbom.conf}
JAVA_BIN=/opt/java/current/bin
ALL_ROLES="controller broker rest c3 shared"

roles=$ALL_ROLES
jfr_seconds=""
raw=~/cbom/raw
to_stdout=no

# say <訊息>：進度訊息一律印到 stderr（stdout 留給 --tar 的資料）
say() {
  echo "$(date +%H:%M:%S) $*" >&2
}

# fail <結束碼> <訊息>
fail() {
  say "失敗：$2"
  exit "$1"
}

# parse_ssh_command <指令>：把受限金鑰帶進來的指令轉成 roles、jfr_seconds；格式不對就拒絕
#   例：「collect roles=controller,broker jfr=60」→ roles="controller broker"、jfr_seconds=60
parse_ssh_command() {
  local command=$1
  local word

  # 經 sudo 進來：家目錄固定用 root 的（~/pki、~/conf、~/cbom 都在那裡）
  export HOME=/root

  if ! echo "$command" | grep -qE '^collect( roles=[a-z0-9,]+)?( jfr=[0-9]{1,4})?$'; then
    fail 1 "這把金鑰只能執行：collect [roles=a,b] [jfr=秒數]"
  fi

  for word in $command; do
    case "$word" in
      roles=*)
        roles=$(echo "${word#roles=}" | tr ',' ' ')
        ;;
      jfr=*)
        jfr_seconds=${word#jfr=}
        ;;
    esac
  done

  to_stdout=yes
  raw=$(mktemp -d /root/cbom-raw.XXXXXX)
}

# ---------- 參數 ----------

while [ $# -gt 0 ]; do
  case "$1" in
    --roles)
      roles=$(echo "$2" | tr ',' ' ')
      shift 2
      ;;
    --jfr)
      jfr_seconds=$2
      shift 2
      ;;
    --out)
      raw=$2
      shift 2
      ;;
    --tar)
      to_stdout=yes
      shift
      ;;
    --from-ssh)
      parse_ssh_command "${2:-}"
      shift 2
      ;;
    *)
      fail 1 "不認得的參數：$1"
      ;;
  esac
done

for role in $roles; do
  if ! echo " $ALL_ROLES " | grep -q " $role "; then
    fail 1 "不認得的元件：$role（可以用的：$ALL_ROLES）"
  fi
done

if [ -n "$jfr_seconds" ] && ! echo "$jfr_seconds" | grep -qE '^[0-9]{1,4}$'; then
  fail 1 "--jfr 要是秒數"
fi

if [ ! -f "$CONF" ]; then
  fail 1 "找不到 $CONF（主機清單）"
fi

# cbom.conf：DOMAIN、ENV_NAME、CONTROLLERS、BROKERS、RESTS、C3_HOSTS、ADMIN_BOOTSTRAP、ADMIN_CLIENT_CONF
source "$CONF"

# ---------- 33.4 這次的範圍 ----------

host_roles=""

if echo " $roles " | grep -q " controller "; then
  for host in $CONTROLLERS; do
    host_roles="$host_roles $host:controller"
  done
fi

if echo " $roles " | grep -q " broker "; then
  for host in $BROKERS; do
    host_roles="$host_roles $host:broker"
  done
fi

if echo " $roles " | grep -q " rest "; then
  for host in $RESTS; do
    host_roles="$host_roles $host:rest"
  done
fi

if echo " $roles " | grep -q " c3 "; then
  for host in $C3_HOSTS; do
    host_roles="$host_roles $host:c3"
  done
fi

hosts=$(echo "$host_roles" | sed -E 's/:[a-z0-9]+//g')

rm -rf "$raw"
mkdir -p "$raw/shared"

tool_versions=$(grep -E '^(cbom-tools|cbomkit-theia) ' "$CBOM_HOME/VERSIONS" | paste -sd, -)
# testssl.sh 的版本訊息帶顏色控制碼：直接取「數字.數字.數字」
testssl_version=$("$CBOM_HOME/bin/testssl/testssl.sh" --version | grep -o '[0-9]*\.[0-9]*\.[0-9]*' | head -1)
syft_version=$("$CBOM_HOME/bin/syft" version | grep '^Version' | awk '{print $2}')
opa_version=$("$CBOM_HOME/bin/opa" version | head -1 | awk '{print $2}')

cat > "$raw/collect.env" <<EOF
DOMAIN=$DOMAIN
ENV=$ENV_NAME
CP_VERSION=$(rpm -q --qf '%{VERSION}' confluent-server)
COLLECTED_AT=$(date +%Y-%m-%dT%H:%M:%S%:z)
ALL_ROLES=$ALL_ROLES
ROLES=$roles
HOSTS=$host_roles
JFR_SECONDS=
TOOLS=$tool_versions, testssl.sh $testssl_version, syft $syft_version, opa $opa_version
EOF

say "範圍：$roles；主機：$hosts"

# ---------- 33.4 每台的設定與檔案清單 ----------

# collect_host <主機>：在主機上把要的東西整理成幾個小檔，打成 tar 傳回來（主機上的暫存目錄隨即刪掉）
collect_host() {
  local host=$1

  mkdir -p "$raw/$host"
  ssh "$host.$DOMAIN" bash -s <<'EOF' | tar -xf - -C "$raw/$host"
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

# 5. jar 清單的雜湊、Confluent 套件版本、監聽的埠（不含 ssh）
find /usr/share/java -name '*.jar' -type f -exec sha256sum {} + | sort -k2 > jars.sha256
rpm -qa 'confluent*' | sort > rpm-confluent.txt
listening=$(ss -ltnH | awk '{print $4}' | sed 's/.*://')
echo "$listening" | sort -un | grep -v '^22$' > ports.txt

tar -cf - .
cd /
rm -rf "$tmp"
EOF

  if [ ! -s "$raw/$host/platform-config.properties" ]; then
    fail 2 "$host 沒有收回設定（ssh 或 sudo 不通？）"
  fi
}

for host in $hosts; do
  collect_host "$host"
  say "$host：設定 $(grep -vc '^#' "$raw/$host/platform-config.properties") 行，jar $(wc -l < "$raw/$host/jars.sha256") 個"
done

# ---------- 33.5 每個埠出示的憑證、TLS 掃描 ----------

# save_served_chain <主機> <埠>：把這個埠出示的憑證鏈存成 PEM；不是 TLS 的埠存不到東西，略過
save_served_chain() {
  local host=$1 port=$2
  local pem=$raw/$host/served/$port.pem
  local chain

  # 交握失敗（要求用戶端憑證、不是 TLS）不算錯：伺服器的憑證鏈在那之前就送出來了
  chain=$(echo | timeout 8 openssl s_client -connect "$host.$DOMAIN:$port" -showcerts 2>/dev/null)
  echo "$chain" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "$pem"

  if [ ! -s "$pem" ]; then
    rm -f "$pem"
  fi
}

# scan_host <主機>：這台出示憑證的每個埠依序跑 testssl.sh
scan_host() {
  local host=$1
  local ip pem port

  ip=$(getent hosts "$host.$DOMAIN" | cut -d' ' -f1)

  for pem in "$raw/$host"/served/*.pem; do
    if [ ! -f "$pem" ]; then
      continue
    fi

    port=$(basename "$pem" .pem)
    "$CBOM_HOME/bin/testssl/testssl.sh" --quiet --color 0 --nodns none --ip "$ip" -p -s -f -S \
      --jsonfile "$raw/$host/tls/$port.json" "$host.$DOMAIN:$port"
  done
}

for host in $hosts; do
  mkdir -p "$raw/$host/served" "$raw/$host/tls"

  for port in $(cat "$raw/$host/ports.txt"); do
    save_served_chain "$host" "$port"
  done
done

say "TLS 掃描開始（每台一個背景工作）"

for host in $hosts; do
  scan_host "$host" > "$raw/$host/tls/scan.log" 2>&1 &
done

wait
scanned=$(find "$raw" -path '*/tls/*.json' | wc -l)
say "TLS 掃描完成：$scanned 個埠"

# ---------- 33.6 jar 分組、平台共用的資產、憑證掃描 ----------

mkdir -p "$raw/shared/jars"
rm -f "$raw/shared/jars/groups.txt"

for host in $hosts; do
  digest=$(sha256sum < "$raw/$host/jars.sha256" | cut -c1-12)
  echo "$digest $host" >> "$raw/shared/jars/groups.txt"
done

if [ -f "$raw/shared/jars/groups.txt" ]; then
  for digest in $(cut -d' ' -f1 "$raw/shared/jars/groups.txt" | sort -u); do
    members=$(grep "^$digest " "$raw/shared/jars/groups.txt" | cut -d' ' -f2 | paste -sd' ' -)
    first=$(echo "$members" | cut -d' ' -f1)
    tmp=~/cbom/tmp-jars
    rm -rf "$tmp"
    mkdir -p "$tmp"

    # 一組可能有 2 GB：暫存放磁碟，不放 /tmp
    ssh "$first.$DOMAIN" "tar -C /usr/share -cf - java" | tar -C "$tmp" -xf -
    SYFT_CHECK_FOR_APP_UPDATE=false "$CBOM_HOME/bin/syft" scan "dir:$tmp/java" \
      -o "cyclonedx-json=$raw/shared/jars/sbom-$digest.json" -q 2>/dev/null
    rm -rf "$tmp"
    say "jar 組 $digest（$members）：掃 $first"
  done
fi

if echo " $roles " | grep -q " shared "; then
  mkdir -p "$raw/shared/pki"

  # 操作機的憑證來源：公開的憑證檔（含私鑰的檔一律不取）
  for file in ~/pki/certs/*.crt ~/pki/certs/*.pem; do
    if [ -f "$file" ] && ! grep -q 'PRIVATE KEY' "$file"; then
      cp "$file" "$raw/shared/pki/"
    fi
  done

  # SCRAM 帳號：只留機制與迭代次數的那幾行，沒有密碼雜湊
  users=$(kafka-configs --bootstrap-server "$ADMIN_BOOTSTRAP" --command-config "$ADMIN_CLIENT_CONF" \
    --describe --entity-type users 2>/dev/null)
  echo "$users" | grep '^SCRAM credential configs' > "$raw/shared/scram-users.txt"

  # ssh 金鑰：類型、長度、指紋
  ssh-keygen -l -f /secure/ssh/cpuser_ed25519.pub > "$raw/shared/ssh-client-key.txt"
  rm -f "$raw/shared/ssh-host-keys.txt"

  for host in $hosts; do
    keys=$(ssh-keyscan -T 5 "$host.$DOMAIN" 2>/dev/null | grep -v '^#')
    echo "$keys" | ssh-keygen -l -f - | sed "s/^/$host /" >> "$raw/shared/ssh-host-keys.txt"
  done

  say "平台共用：憑證來源 $(find "$raw/shared/pki" -type f | wc -l) 個檔"
fi

if ! "$CBOM_HOME/bin/cbomkit-theia" dir "$raw" -p certificates > "$raw/shared/theia.json" 2> "$raw/shared/theia.log"; then
  fail 2 "cbomkit-theia 失敗，看 $raw/shared/theia.log"
fi

# ---------- 33.7（可選）執行期證據 ----------

# jfr_remote <主機> <start|dump> [事件…]：對這台執行中的 Confluent 服務啟動錄製，或匯出並停止（dump 時錄製檔印到 stdout）
#   事件名稱各是一個參數（不加引號傳過去），遠端先取走動作、其餘的用 "$@" 全部交給 jcmd
jfr_remote() {
  local host=$1 action=$2
  shift 2

  ssh "$host.$DOMAIN" bash -s -- "$action" "$@" <<'EOF'
action=$1
shift
unit=$(systemctl list-units --state=running --no-legend 'confluent-*.service' | awk '{print $1}' | head -1)
pid=$(systemctl show $unit -p MainPID --value)
user=$(ps -o user= -p $pid)
jcmd="sudo -u $user /opt/java/current/bin/jcmd $pid"

if [ "$action" = start ]; then
  $jcmd JFR.start name=cbom maxsize=50m "$@" > /dev/null
else
  sudo rm -f /tmp/cbom.jfr
  $jcmd JFR.dump name=cbom filename=/tmp/cbom.jfr > /dev/null
  $jcmd JFR.stop name=cbom > /dev/null
  sudo cat /tmp/cbom.jfr
  sudo rm -f /tmp/cbom.jfr
fi
EOF
}

if [ -n "$jfr_seconds" ]; then
  events="jdk.SecurityProviderService#enabled=true jdk.TLSHandshake#enabled=true jdk.X509Certificate#enabled=true"

  for host in $hosts; do
    jfr_remote "$host" start $events
  done

  say "JFR 錄製 $jfr_seconds 秒"
  sleep "$jfr_seconds"

  for host in $hosts; do
    mkdir -p "$raw/$host/jfr"
    jfr_remote "$host" dump > "$raw/$host/jfr/service.jfr"
    "$JAVA_BIN/jfr" print --json --events jdk.SecurityProviderService,jdk.TLSHandshake \
      "$raw/$host/jfr/service.jfr" > "$raw/$host/jfr/service.json"
    rm -f "$raw/$host/jfr/service.jfr"
  done

  sed -i "s/^JFR_SECONDS=.*/JFR_SECONDS=$jfr_seconds/" "$raw/collect.env"
fi

# ---------- 檢查：原料裡不該有私鑰與沒遮到的密碼 ----------

private_keys=$(grep -rl 'PRIVATE KEY' "$raw" | wc -l)

if [ "$private_keys" != 0 ]; then
  fail 2 "原料裡有 $private_keys 個檔含私鑰，不交出去：$raw"
fi

secret_lines=$(grep -rhE '^[^=]*(password|secret|jaas|credentials)[^=]*=' "$raw" --include=platform-config.properties)
unmasked=$(echo "$secret_lines" | awk '!/=<遮蔽>/ && NF {c++} END {print c + 0}')  # lint-ok: 計數可能是 0，用 awk 才不會回 1

if [ "$unmasked" != 0 ]; then
  fail 2 "有 $unmasked 行密碼類設定沒遮到，不交出去：$raw"
fi

say "收集完成：$(du -sh "$raw" | cut -f1)，$raw"

# ---------- --tar：原料印到 stdout ----------

if [ "$to_stdout" = yes ]; then
  tar -czf - -C "$raw" .

  # 受限入口用的是暫存目錄，交出去之後就刪
  case "$raw" in
    /root/cbom-raw.*)
      rm -rf "$raw"
      ;;
  esac
fi
