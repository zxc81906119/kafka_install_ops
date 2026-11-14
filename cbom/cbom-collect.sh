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
#   例：bash cbom-collect.sh                              完整盤點，原料在 ~/cbom/raw
#       bash cbom-collect.sh --roles "broker rest" --jfr 60   只盤 broker 與 REST Proxy，另外錄 60 秒
#
# 需要什麼：/opt/cbom/bin 的工具（33.3）、/opt/cbom/lib/cbom-lib.sh、/etc/cbom/cbom.conf（主機清單）、
#           ~/conf/client-admin.properties、
#           cpuser 的 ssh（讀 properties 與 /etc/confluent/ssl 的清單要 sudo，見第 33 章的 sudoers 清單）。
# 產出什麼：原料目錄；--tar 時另外印出 tar.gz。原料之後交給 cbom-report.sh build（cbom-tools.jar），每種原料由一層讀：
#   collect.env                              這次的範圍（每一層都讀；必要的欄位見 cbom-lib.sh 的 check_raw）
#   <主機>/platform-config.properties、secret-protection.properties、ssl-files.list、mds-token-public.pem
#   shared/scram-users.txt、ssh-host-keys.txt、ssh-client-key.txt        → PlatformConfigLayer
#   <主機>/java.security、java-version.txt、java-security-effective.txt、jvm-system-properties.txt、os-crypto.txt
#                                                                       → JdkSettingsLayer
#   <主機>/tls/<埠>.json（testssl.sh）                                   → TlsScanLayer
#   shared/jars/groups.txt、sbom-<雜湊>.json（syft）                     → LibraryLayer
#   shared/theia.json（cbomkit-theia 掃 <主機>/served/<埠>.pem、shared/pki/ 的憑證）→ FilesLayer
#   <主機>/jfr/service.json（有 --jfr 才有）                             → RuntimeLayer
#   <主機>/jars.sha256、ports.txt、rpm-confluent.txt 是這支腳本自己分組與找埠用的，cbom-tools 不讀。
#   <主機>/steps.done：主機上哪幾個收集步驟確實做完了（一行一個：1、2、3、4、4b、5），這支腳本自己檢查用，cbom-tools 不讀。
# 能不能重跑：可以，每次都重新收。
# 結束碼：0 成功；1 參數不對或前提不在；2 收集途中失敗。
#   沒有用 set -e：一台或一個步驟失敗時其他的照樣收完。失敗分兩種：
#     立刻停（fail 2）：某台的設定收不回來、cbomkit-theia 失敗、原料檢查（check_raw）不合格
#     記一筆繼續（note_failure）：主機上的收集步驟沒有完成、取 jar、syft、TLS 掃描沒有結果、kafka-configs、
#                                 ssh 金鑰、JFR；全部做完後（--tar 的原料也印出去之後）列出失敗的步驟並回 2
#   主機上執行的那一段（collect_host 的 1.–5.）：每一步做完後檢查「該產生的檔有沒有實際的內容」，有才在 steps.done
#   記一行；收回來之後 check_host_steps 逐步核對，少了哪一步就記一筆失敗。判斷方式與「可以合理沒有」的情況：
#     1   platform-config.properties 至少有一行設定
#     2   secret-protection.properties 有內容；這台的設定沒有用到 ${securepass:…}（沒用 Secret Protection）時不要求
#     3   ssl-files.list 有內容；清單裡有 mds-token-public.pem 的主機，公鑰也要取回（沒有這個檔的主機不要求）
#     4   java.security 有內容、java-version.txt 有版本、os-crypto.txt 三行（密碼政策、OS 版本、OpenSSL 版本）都在
#     4b  jvm-system-properties.txt 有內容（要有執行中的 Confluent 服務）、java-security-effective.txt 有安全屬性
#     5   jars.sha256、rpm-confluent.txt 有內容，ports.txt 至少一個埠
set -uo pipefail

CBOM_HOME=/opt/cbom
CONF=${CBOM_CONF:-/etc/cbom/cbom.conf}
JAVA_BIN=/opt/java/current/bin
ALL_ROLES="controller broker rest c3 shared"

roles=$ALL_ROLES
jfr_seconds=""
raw=~/cbom/raw
to_stdout=no

# 共用的函式：say、fail、check_raw（和 web app 的收集腳本同一份）
# shellcheck disable=SC1091
source "$CBOM_HOME/lib/cbom-lib.sh"

# 收集途中失敗、但還能繼續收其他東西的步驟，一行一個；腳本最後有任何一筆就列出來並回 2
failures=""

# note_failure <步驟>：記下一個失敗的收集步驟，印出訊息後繼續
#   例：note_failure "kb01 的 jar 掃描（syft）" → failures 多一行，stderr 印「失敗（繼續收其他的）：kb01 的 jar 掃描（syft）」
note_failure() {
  failures="$failures
  $1"
  say "失敗（繼續收其他的）：$1"
}

# parse_ssh_command <指令>：把受限金鑰帶進來的指令轉成 roles、jfr_seconds；格式不對就拒絕
#   例：「collect roles=controller,broker jfr=60」→ roles="controller broker"、jfr_seconds=60
parse_ssh_command() {
  local command=$1
  local word

  # 經 sudo 進來：家目錄固定用 root 的（~/pki、~/conf、~/cbom 都在那裡）
  export HOME=/root

  # 整行只能是 collect，後面可以有 roles=…、jfr=…（最多 4 位數）；多一個字、多一個符號都拒絕
  #   例：「collect roles=broker jfr=60」通過；「collect; id」「collect roles=../x」不通過
  if ! echo "$command" | grep -qE '^collect( roles=[a-z0-9,]+)?( jfr=[0-9]{1,4})?$'; then
    fail 1 "這把金鑰只能執行：collect [roles=a,b] [jfr=秒數]"
  fi

  for word in $command; do
    case "$word" in
      roles=*)
        # ${word#roles=}：去掉開頭的「roles=」。例：roles=controller,broker → controller,broker → controller broker
        roles=$(echo "${word#roles=}" | tr ',' ' ')
        ;;
      jfr=*)
        # 例：jfr=60 → 60
        jfr_seconds=${word#jfr=}
        ;;
    esac
  done

  # 這條路一律把原料印到 stdout，原料放暫存目錄（交出去之後在腳本最後刪掉）
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

# 前後各加一個空白再比對，才不會把名稱的一部分當成符合（" rest " 不會符合 " restx "）
for role in $roles; do
  if ! echo " $ALL_ROLES " | grep -q " $role "; then
    fail 1 "不認得的元件：$role（可以用的：$ALL_ROLES）"
  fi
done

if [ -n "$jfr_seconds" ] && ! echo "$jfr_seconds" | grep -qE '^[0-9]{1,4}$'; then
  fail 1 "--jfr 要是秒數（1 到 4 位數字，例如 --jfr 60）"
fi

if [ ! -f "$CONF" ]; then
  fail 1 "找不到 $CONF（主機清單）：照手冊 33.3 建立，或用環境變數 CBOM_CONF 指到別的檔"
fi

# cbom.conf：DOMAIN、ENV_NAME、CONTROLLERS、BROKERS、RESTS、C3_HOSTS、ADMIN_BOOTSTRAP、ADMIN_CLIENT_CONF
source "$CONF"

# ---------- 33.4 這次的範圍 ----------

# host_roles：這次要盤的每台主機與它的角色，寫成「主機:角色」，空白隔開
#   例：--roles "controller rest" → " kc01:controller kc02:controller kc03:controller rest01:rest rest02:rest"
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

# 去掉每個「:角色」，只留主機名稱
#   例：" kc01:controller kb01:broker" → " kc01 kb01"
hosts=$(echo "$host_roles" | sed -E 's/:[a-z0-9]+//g')

# 原料目錄每次重建（舊的先清掉）
rm -rf "$raw"
mkdir -p "$raw/shared"

# 各工具的版本，寫進 collect.env 的 TOOLS（報告的「怎麼收集的」一節會印出來）
# VERSIONS 裡這兩行接成一行。例：「cbom-tools 1.0.0」「cbomkit-theia 1.1.2」→「cbom-tools 1.0.0,cbomkit-theia 1.1.2」
tool_versions=$(grep -E '^(cbom-tools|cbomkit-theia) ' "$CBOM_HOME/VERSIONS" | paste -sd, -)
# testssl.sh 的版本訊息帶顏色控制碼：直接取「數字.數字.數字」
testssl_version=$("$CBOM_HOME/bin/testssl/testssl.sh" --version | grep -o '[0-9]*\.[0-9]*\.[0-9]*' | head -1)
syft_version=$("$CBOM_HOME/bin/syft" version | grep '^Version' | awk '{print $2}')
opa_version=$("$CBOM_HOME/bin/opa" version | head -1 | awk '{print $2}')

# collect.env：這次的範圍，cbom-tools 的每一層都靠它知道有哪些主機、各是什麼角色。
# JFR_SECONDS 先留空，有錄（33.7）才在最後填上秒數
cat > "$raw/collect.env" <<EOF
PROFILE=cp
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
#   例：collect_host kb01 → $raw/kb01/ 底下 platform-config.properties、ssl-files.list、java.security … 共 13 個檔
#   EOF 之間那一段是在主機上以 cpuser 執行的；設定檔沒收回來（ssh 或 sudo 不通）就整支停，回 2
#   每一步最後的「檢查」：該產生的檔有實際內容才在 steps.done 記下步驟編號（判斷方式見檔頭）；
#   不能只看檔案是不是空的，因為 echo "$變數" 在變數是空的時候也會寫出一個空行
collect_host() {
  local host=$1

  mkdir -p "$raw/$host"
  ssh "$host.$DOMAIN" bash -s <<'EOF' | tar -xf - -C "$raw/$host"
tmp=$(mktemp -d)
cd "$tmp"

# 0. 記錄「哪幾步確實做完」的檔，先建成空的
touch steps.done

# 1. 服務實際用的 properties：只留密碼學相關的設定，密碼類的值遮掉
#    產出 platform-config.properties（→ PlatformConfigLayer）
#    三個服務名稱一起問，這台有哪個就回哪個的 ExecStart；從裡面取出設定檔的路徑
#    例：「ExecStart={ path=/usr/bin/kafka-server-start ; argv[]=… /etc/confluent/kb01.server.properties ; …」
#        → /etc/confluent/kb01.server.properties
unit_exec=$(systemctl show confluent-server confluent-kafka-rest confluent-control-center -p ExecStart 2>/dev/null)
props=$(echo "$unit_exec" | grep -o '/etc/confluent[^ ;]*properties' | head -1)

# keys：設定名稱含這些字的才留（密碼學相關）；secrets：設定名稱含這些字的，值換成 <遮蔽>
keys='ssl|sasl|tls|cipher|protocol|keystore|truststore|algorithm|scram|token|secret|fips|security\.providers|listeners'
secrets='password|secret|jaas|credentials|api\.key'

# 第一行記下設定檔的路徑，後面接挑出來、遮過的設定
echo "# file=$props" > platform-config.properties
# 樣式「^[^#=]*(…)[^=]*=」：不是註解，而且等號左邊（設定名稱）含 keys 的其中一個字
#   例：「ssl.keystore.type=PKCS12」留下；「#ssl.x=1」「num.partitions=6」不留
settings=$(sudo cat "$props" | grep -E "^[^#=]*($keys)[^=]*=")
# 設定名稱含 secrets 其中一個字的行，等號以後整段換掉
#   例：「ssl.keystore.password=${securepass:…}」→「ssl.keystore.password=<遮蔽>」；「ssl.keystore.type=PKCS12」不變
echo "$settings" | sed -E "/^[^=]*($secrets)[^=]*=/ s/=.*/=<遮蔽>/" >> platform-config.properties

#    檢查：第一行「# file=…」以外，至少有一行「名稱=值」
if grep -q '^[^#].*=' platform-config.properties; then
  echo "1" >> steps.done
fi

# 2. Secret Protection 的非機密參數（金鑰長度、迭代次數；不取 salt 與密文）
#    產出 secret-protection.properties（→ PlatformConfigLayer）
metadata=$(sudo cat /etc/confluent/secrets/security.properties | grep '^_metadata\.')
echo "$metadata" | grep -vE 'salt|\.enc' > secret-protection.properties

#    檢查：這台的設定有用到 ${securepass:…}（有用 Secret Protection）才要求取到參數；沒用的主機本來就沒有，直接算完成
if echo "$settings" | grep -q 'securepass:'; then
  if grep -q '=' secret-protection.properties; then
    echo "2" >> steps.done
  fi
else
  echo "2" >> steps.done
fi

# 3. 憑證與金鑰檔：只列權限、擁有者、大小、路徑；公開的 token 公鑰取回
#    產出 ssl-files.list、mds-token-public.pem（→ PlatformConfigLayer）
#    例（ssl-files.list 的一行）：640 root:confluent 4321 /etc/confluent/ssl/kb01.keystore.p12
sudo find /etc/confluent/ssl -type f -printf '%m %u:%g %s %p\n' > ssl-files.list
sudo cat /etc/confluent/ssl/mds-token-public.pem > mds-token-public.pem

#    檢查：清單有內容。token 公鑰不是每台都有：清單裡列了這個檔的主機才要求取回（內容要有 BEGIN 那一行）
if [ -s ssl-files.list ]; then
  if grep -q '/mds-token-public\.pem$' ssl-files.list; then
    if grep -q 'BEGIN' mds-token-public.pem; then
      echo "3" >> steps.done
    fi
  else
    echo "3" >> steps.done
  fi
fi

# 4. JDK 與 OS 的密碼設定
#    產出 java.security、java-version.txt、os-crypto.txt（→ JdkSettingsLayer）
cat /opt/java/current/conf/security/java.security > java.security
/opt/java/current/bin/java -version > java-version.txt 2>&1
readlink -f /opt/java/current >> java-version.txt

update-crypto-policies --show > os-crypto.txt
cat /etc/redhat-release >> os-crypto.txt
openssl version >> os-crypto.txt

#    檢查：java.security 有內容；java-version.txt 有「version」那一行（java 執行失敗時檔裡只有錯誤訊息）；
#    os-crypto.txt 要有三行（三個指令各一行，少一行就是其中一個失敗了）
os_lines=$(wc -l < os-crypto.txt)
if [ -s java.security ] && [ "$os_lines" -ge 3 ]; then
  if grep -q ' version ' java-version.txt; then
    echo "4" >> steps.done
  fi
fi

# 4b. JDK「實際生效」的設定：檔案寫的不一定就是生效的（服務可能用 -D 指定別的設定檔）
#     產出 jvm-system-properties.txt、java-security-effective.txt（→ JdkSettingsLayer）
#     先看執行中的服務的系統屬性裡和安全有關的幾項（名稱含 password 的不取）
#     jcmd 要用服務自己的帳號執行，所以先找出這台執行中的 Confluent 服務、它的 PID 與帳號
unit=$(systemctl list-units --state=running --no-legend 'confluent-*.service' | awk '{print $1}' | head -1)
pid=$(systemctl show $unit -p MainPID --value)
user=$(ps -o user= -p $pid)

system_properties=$(sudo -u $user /opt/java/current/bin/jcmd $pid VM.system_properties 2>/dev/null)
wanted='^(java\.security\.|jdk\.tls\.|jdk\.security\.|https\.protocols|javax\.net\.ssl\.|java\.home|java\.version=)'
echo "$system_properties" | grep -E "$wanted" | grep -viE '^[^=]*password' > jvm-system-properties.txt

#     再請同一個 JDK 印出生效的安全屬性、provider 順序、TLS 啟用的版本與 cipher suite
#     服務有用 -Djava.security.properties 指定別的設定檔時，要帶同一個參數問，答案才和服務看到的一樣
#     例：「java.security.properties=/etc/kafka/fips.security」→ /etc/kafka/fips.security；沒有這一行就是空字串
override=$(grep '^java.security.properties=' jvm-system-properties.txt | cut -d= -f2-)
if [ -n "$override" ]; then
  /opt/java/current/bin/java "-Djava.security.properties=$override" -XshowSettings:security:all -version \
    > java-security-effective.txt 2>&1
else
  /opt/java/current/bin/java -XshowSettings:security:all -version > java-security-effective.txt 2>&1
fi

#     檢查：系統屬性至少取到一項（這台沒有執行中的 Confluent 服務、或 jcmd 不能用時會是空的）；
#     生效的設定裡有「Security properties」那一段（java 執行失敗時檔裡只有錯誤訊息）
if [ -s jvm-system-properties.txt ]; then
  if grep -q 'Security properties' java-security-effective.txt; then
    echo "4b" >> steps.done
  fi
fi

# 5. jar 清單的雜湊、Confluent 套件版本、監聽的埠（不含 ssh）
#    產出 jars.sha256（33.6 用來把 jar 完全相同的主機歸成一組）、ports.txt（33.5 逐埠取憑證）、
#    rpm-confluent.txt（留給人查）；這三個檔 cbom-tools 不讀
find /usr/share/java -name '*.jar' -type f -exec sha256sum {} + | sort -k2 > jars.sha256
rpm -qa 'confluent*' | sort > rpm-confluent.txt

# ss 的第 4 欄是「位址:埠」，去掉最後一個冒號以前的部分。例：「0.0.0.0:9092」「[::]:8090」→ 9092、8090
listening=$(ss -ltnH | awk '{print $4}' | sed 's/.*://')
echo "$listening" | sort -un | grep -v '^22$' > ports.txt

#    檢查：jar 清單與套件清單有內容，ports.txt 至少有一個埠號（只看是不是空檔不夠：沒有埠時也會寫出一個空行）
if [ -s jars.sha256 ] && [ -s rpm-confluent.txt ]; then
  if grep -q '[0-9]' ports.txt; then
    echo "5" >> steps.done
  fi
fi

# 6. 這幾個小檔打成 tar 從 stdout 傳回去，刪掉暫存目錄
tar -cf - .
cd /
rm -rf "$tmp"
EOF

  if [ ! -s "$raw/$host/platform-config.properties" ]; then
    fail 2 "$host 沒有收回設定（ssh 或 sudo 不通？先試 ssh $host.$DOMAIN 'sudo -n true'，再對第 33 章的 sudoers 清單）"
  fi
}

# check_host_steps <主機>：核對這台收回來的 steps.done，六個步驟少了哪一個就記一筆失敗（不停，繼續收其他的）
#   例：kb01 的 steps.done 沒有「4b」那一行 → note_failure "kb01 的收集步驟 4b（JDK 實際生效的設定）沒有完成"
#   grep -qx：整行要完全等於步驟編號（「4」不會被「4b」那一行當成符合）；steps.done 不在時每一步都算沒完成
check_host_steps() {
  local host=$1
  local step what

  for step in 1 2 3 4 4b 5; do
    if grep -qx "$step" "$raw/$host/steps.done" 2>/dev/null; then
      continue
    fi

    case "$step" in
      1) what="服務的密碼學設定" ;;
      2) what="Secret Protection 的參數" ;;
      3) what="憑證與金鑰檔清單、token 公鑰" ;;
      4) what="JDK 與 OS 的密碼設定" ;;
      4b) what="JDK 實際生效的設定" ;;
      5) what="jar 清單、套件版本、監聽的埠" ;;
    esac

    note_failure "$host 的收集步驟 $step（$what）沒有完成"
  done
}

# 每台收一次並核對步驟，印出收回幾行設定、幾個 jar（grep -vc '^#'：不算第一行的「# file=…」）
for host in $hosts; do
  collect_host "$host"
  check_host_steps "$host"
  say "$host：設定 $(grep -vc '^#' "$raw/$host/platform-config.properties") 行，jar $(wc -l < "$raw/$host/jars.sha256") 個"
done

# ---------- 33.5 每個埠出示的憑證、TLS 掃描 ----------

# save_served_chain <主機> <埠>：把這個埠出示的憑證鏈存成 PEM；不是 TLS 的埠存不到東西，略過
#   例：save_served_chain kb01 9092 → $raw/kb01/served/9092.pem（之後由 cbomkit-theia 掃進 shared/theia.json → FilesLayer）
save_served_chain() {
  local host=$1 port=$2
  local pem=$raw/$host/served/$port.pem
  local chain

  # 交握失敗（要求用戶端憑證、不是 TLS）不算錯：伺服器的憑證鏈在那之前就送出來了
  # timeout 8：不是 TLS 的埠可能不回應交握，openssl 會一直等，所以給 8 秒的上限
  # sed -n '/BEGIN/,/END/p'：只留每張憑證從 BEGIN 到 END 的那幾行，其他交握訊息丟掉
  chain=$(echo | timeout 8 openssl s_client -connect "$host.$DOMAIN:$port" -showcerts 2>/dev/null)
  echo "$chain" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "$pem"

  if [ ! -s "$pem" ]; then
    rm -f "$pem"
  fi
}

# scan_host <主機>：這台出示憑證的每個埠依序跑 testssl.sh
#   例：scan_host kb01 → $raw/kb01/tls/9092.json、8090.json …（→ TlsScanLayer）
#   testssl.sh 的參數：-p 支援哪些 TLS 版本、-s 標準的 cipher 類別、-f forward secrecy（含金鑰交換群組）、
#   -S 伺服器的預設與憑證資訊；--nodns none 與 --ip 讓它不查 DNS、只掃我們給的那個位址；
#   --quiet --color 0 不印橫幅與顏色控制碼（輸出進 scan.log）
#   testssl.sh 有發現項目時結束碼也不是 0，所以這裡不看結束碼；掃完之後另外檢查每個埠有沒有產生 JSON
scan_host() {
  local host=$1
  local ip pem port

  # 例：「172.35.0.21    kb01.poc.lab」→ 172.35.0.21
  ip=$(getent hosts "$host.$DOMAIN" | cut -d' ' -f1)

  for pem in "$raw/$host"/served/*.pem; do
    if [ ! -f "$pem" ]; then
      continue
    fi

    # 例：…/served/9092.pem → 9092
    port=$(basename "$pem" .pem)
    "$CBOM_HOME/bin/testssl/testssl.sh" --quiet --color 0 --nodns none --ip "$ip" -p -s -f -S \
      --jsonfile "$raw/$host/tls/$port.json" "$host.$DOMAIN:$port"
  done
}

# 每台照 ports.txt 逐埠試著取憑證鏈（取得到的才是 TLS 的埠，下面只掃這些）
for host in $hosts; do
  mkdir -p "$raw/$host/served" "$raw/$host/tls"

  for port in $(cat "$raw/$host/ports.txt"); do
    save_served_chain "$host" "$port"
  done
done

say "TLS 掃描開始（每台一個背景工作）"

# 每台各自在背景掃（同一台的埠依序掃，不同台同時進行，省時間），wait 等全部做完
for host in $hosts; do
  scan_host "$host" > "$raw/$host/tls/scan.log" 2>&1 &
done

wait
scanned=$(find "$raw" -path '*/tls/*.json' | wc -l)
say "TLS 掃描完成：$scanned 個埠"

# 背景工作的結束碼拿不到，改看結果：出示憑證的埠都應該有一份不是空的 JSON，沒有就記一筆
for host in $hosts; do
  for pem in "$raw/$host"/served/*.pem; do
    if [ ! -f "$pem" ]; then
      continue
    fi

    port=$(basename "$pem" .pem)
    if [ ! -s "$raw/$host/tls/$port.json" ]; then
      note_failure "$host:$port 的 TLS 掃描沒有結果（看 $raw/$host/tls/scan.log）"
    fi
  done
done

# ---------- 33.6 jar 分組、平台共用的資產、憑證掃描 ----------

# jar 分組（→ LibraryLayer）：jar 清單完全相同的主機歸成一組，每組只取一台的 jar 回來用 syft 掃
#   shared/jars/groups.txt        每行「組的雜湊 主機」。例：「3f9a1c0b77de kb01」
#   shared/jars/sbom-<雜湊>.json  那一組的函式庫清單（CycloneDX SBOM）
mkdir -p "$raw/shared/jars"
rm -f "$raw/shared/jars/groups.txt"

for host in $hosts; do
  # 組的雜湊：這台 jars.sha256（每個 jar 的雜湊與路徑）整份再算一次 sha256，取前 12 碼（夠分辨，檔名也短）
  digest=$(sha256sum < "$raw/$host/jars.sha256" | cut -c1-12)
  echo "$digest $host" >> "$raw/shared/jars/groups.txt"
done

if [ -f "$raw/shared/jars/groups.txt" ]; then
  for digest in $(cut -d' ' -f1 "$raw/shared/jars/groups.txt" | sort -u); do
    # 這一組的主機接成一行，取第一台當代表。例：「kb01 kb02 kb03 kb04」→ first=kb01
    members=$(grep "^$digest " "$raw/shared/jars/groups.txt" | cut -d' ' -f2 | paste -sd' ' -)
    first=$(echo "$members" | cut -d' ' -f1)

    tmp=~/cbom/tmp-jars
    rm -rf "$tmp"
    mkdir -p "$tmp"

    # 一組可能有 2 GB：暫存放磁碟，不放 /tmp
    if ! ssh "$first.$DOMAIN" "tar -C /usr/share -cf - java" | tar -C "$tmp" -xf -; then
      note_failure "jar 組 $digest：從 $first 取 /usr/share/java 失敗"
    fi

    # SYFT_CHECK_FOR_APP_UPDATE=false：離線環境，不讓 syft 連出去問有沒有新版
    if ! SYFT_CHECK_FOR_APP_UPDATE=false "$CBOM_HOME/bin/syft" scan "dir:$tmp/java" \
      -o "cyclonedx-json=$raw/shared/jars/sbom-$digest.json" -q 2>/dev/null; then
      note_failure "jar 組 $digest（$members）：syft 掃描失敗（少了 sbom-$digest.json，報告的函式庫會缺這一組）"
    fi

    rm -rf "$tmp"
    say "jar 組 $digest（$members）：掃 $first"
  done
fi

# 平台共用的資產（有選 shared 才收）：操作機上的憑證來源、SCRAM 帳號、ssh 金鑰
if echo " $roles " | grep -q " shared "; then
  mkdir -p "$raw/shared/pki"

  # 操作機的憑證來源：公開的憑證檔（含私鑰的檔一律不取）
  for file in ~/pki/certs/*.crt ~/pki/certs/*.pem; do
    if [ -f "$file" ] && ! grep -q 'PRIVATE KEY' "$file"; then
      cp "$file" "$raw/shared/pki/"
    fi
  done

  # SCRAM 帳號：只留機制與迭代次數的那幾行，沒有密碼雜湊
  #   產出 shared/scram-users.txt（→ PlatformConfigLayer）
  #   例：SCRAM credential configs for user-principal 'kafka-admin' are SCRAM-SHA-512=iterations=8192
  #   錯誤訊息丟掉（2>/dev/null）：kafka-configs 出錯時會把整份設定連密碼印出來
  if ! users=$(kafka-configs --bootstrap-server "$ADMIN_BOOTSTRAP" --command-config "$ADMIN_CLIENT_CONF" \
    --describe --entity-type users 2>/dev/null); then
    note_failure "SCRAM 帳號清單（kafka-configs 連不上 $ADMIN_BOOTSTRAP，或 $ADMIN_CLIENT_CONF 不能用）"
  fi

  echo "$users" | grep '^SCRAM credential configs' > "$raw/shared/scram-users.txt"

  # ssh 金鑰：類型、長度、指紋
  #   產出 shared/ssh-client-key.txt、shared/ssh-host-keys.txt（→ PlatformConfigLayer）
  #   例（ssh-host-keys.txt 的一行，最前面是我們加的主機名稱）：kb01 256 SHA256:Ab3… kb01.poc.lab (ED25519)
  if ! ssh-keygen -l -f /secure/ssh/cpuser_ed25519.pub > "$raw/shared/ssh-client-key.txt"; then
    note_failure "ssh 用戶端金鑰（讀不到 /secure/ssh/cpuser_ed25519.pub）"
  fi

  rm -f "$raw/shared/ssh-host-keys.txt"

  for host in $hosts; do
    # -T 5：每台最多等 5 秒；「#」開頭的是 ssh-keyscan 的說明行，不要
    keys=$(ssh-keyscan -T 5 "$host.$DOMAIN" 2>/dev/null | grep -v '^#')
    if [ -z "$keys" ]; then
      note_failure "$host 的 ssh 主機金鑰（ssh-keyscan 沒有回應）"
      continue
    fi

    echo "$keys" | ssh-keygen -l -f - | sed "s/^/$host /" >> "$raw/shared/ssh-host-keys.txt"
  done

  say "平台共用：憑證來源 $(find "$raw/shared/pki" -type f | wc -l) 個檔"
fi

# 憑證掃描（→ FilesLayer）：cbomkit-theia 掃整個原料目錄裡的憑證檔
#   （<主機>/served/<埠>.pem、shared/pki/、<主機>/mds-token-public.pem），產出 shared/theia.json
# theia 會記住第一次執行時開的功能，所以每次都明確指定：平台這邊只看憑證，不收私鑰與秘密
if ! "$CBOM_HOME/bin/cbomkit-theia" dir "$raw" -p certificates \
  > "$raw/shared/theia.json" 2> "$raw/shared/theia.log"; then
  fail 2 "cbomkit-theia 失敗，看 $raw/shared/theia.log"
fi

# ---------- 33.7（可選）執行期證據 ----------

# jfr_remote <主機> <start|dump> [事件…]：對這台執行中的 Confluent 服務啟動錄製，或匯出並停止（dump 時錄製檔印到 stdout）
#   事件名稱各是一個參數（不加引號傳過去），遠端先取走動作、其餘的用 "$@" 全部交給 jcmd
#   例：jfr_remote kb01 start jdk.TLSHandshake#enabled=true → 開始錄；jfr_remote kb01 dump > service.jfr → 取回並停止
#   maxsize=50m：錄製的資料在主機上最多佔 50 MB，超過就丟掉最舊的
#   結束碼：start 是 jcmd 的結束碼；dump 那一段最後一行是刪暫存檔，所以要看取回的檔能不能用（下面用 jfr print 判斷）
jfr_remote() {
  local host=$1 action=$2

  # 前兩個參數取走之後，"$@" 剩下的就是事件名稱
  shift 2
  ssh "$host.$DOMAIN" bash -s -- "$action" "$@" <<'EOF'
action=$1
shift

# 這台執行中的 Confluent 服務、它的 PID 與帳號；jcmd 要用服務自己的帳號執行
unit=$(systemctl list-units --state=running --no-legend 'confluent-*.service' | awk '{print $1}' | head -1)
pid=$(systemctl show $unit -p MainPID --value)
user=$(ps -o user= -p $pid)
jcmd="sudo -u $user /opt/java/current/bin/jcmd $pid"

# start：開始錄（名稱 cbom）；其他（dump）：寫成檔、停止錄製、把檔印到 stdout、刪掉
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

# 產出 <主機>/jfr/service.json（→ RuntimeLayer）：錄製期間程式向 JDK 要了哪些演算法、完成了哪些 TLS 交握
if [ -n "$jfr_seconds" ]; then
  # 這三種事件預設是關的，要明確打開；「事件名稱#enabled=true」是 jcmd JFR.start 的寫法
  events="jdk.SecurityProviderService#enabled=true jdk.TLSHandshake#enabled=true jdk.X509Certificate#enabled=true"

  for host in $hosts; do
    if ! jfr_remote "$host" start $events; then
      note_failure "$host 的 JFR 啟動（jcmd JFR.start）"
    fi
  done

  say "JFR 錄製 $jfr_seconds 秒"
  sleep "$jfr_seconds"

  for host in $hosts; do
    mkdir -p "$raw/$host/jfr"

    # 錄製檔（二進位）取回來，用操作機的 jfr 轉成 JSON，錄製檔不留
    if ! jfr_remote "$host" dump > "$raw/$host/jfr/service.jfr"; then
      note_failure "$host 的 JFR 取回（ssh 或 jcmd JFR.dump）"
    elif ! "$JAVA_BIN/jfr" print --json --events jdk.SecurityProviderService,jdk.TLSHandshake \
      "$raw/$host/jfr/service.jfr" > "$raw/$host/jfr/service.json"; then
      note_failure "$host 的 JFR 轉成 JSON（jfr print；取回的錄製檔是空的或不完整）"
    fi

    rm -f "$raw/$host/jfr/service.jfr"
  done

  # 把 collect.env 的「JFR_SECONDS=」填上這次錄的秒數。例：「JFR_SECONDS=」→「JFR_SECONDS=60」
  sed -i "s/^JFR_SECONDS=.*/JFR_SECONDS=$jfr_seconds/" "$raw/collect.env"
fi

# ---------- 檢查：原料裡不該有私鑰與沒遮到的密碼 ----------

check_raw "$raw"

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

# ---------- 途中有步驟失敗：列出來，回 2 ----------
# 放在最後：原料（少了失敗的那幾項）照樣留下或印出去，但結束碼讓呼叫的人（或 Jenkins）知道這次不完整

if [ -n "$failures" ]; then
  say "這次有步驟失敗，原料不完整（修好之後整支重跑）：$failures"
  exit 2
fi
