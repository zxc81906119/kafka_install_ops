#!/usr/bin/env bash
# install/lab/run-customer.sh —— lab：用「客戶模式」從零實跑整條遷移主線（Windows Git Bash）
# where: Windows Git Bash（lab 的主控端；正式環境沒有這支）
#
#   bash run-customer.sh                  從零（bank-sim reset）：先裝安裝基底（CP 8.2.4、C3 2.5.1、JDK 21、OS 9.6）到第 19 站驗收，
#                                         再遷移到 CP 8.3.2、C3 2.6.1、JDK 25、OS 9.8（第 29、30、31 章），每段之後都驗收
#   FROM=6 bash run-customer.sh           從第 6 段接著跑（段號在每段的 ######## 標題裡）
#   TO=15 bash run-customer.sh            跑到第 15 段（基底的驗收）就停
#   IDEMPOTENCE=1 bash run-customer.sh    基底驗收（第 15 段）後再跑一次 03–14 站，驗證重跑是安全的（原本 run-all.sh --no-reset 的用途）
#
# 做什麼：這支取代了舊的 run-upgrade-drill.sh（升級演練）與 run-all.sh：升級不再是另一件事，而是主線。
# 需要什麼：lab 已依手把手第 0 章建好（~/kafka-lab）。
# 產出什麼：lab 上一套遷移完成的平台；每段的標題、驗收與版本表印在畫面上。結束碼 0 = 全部做完。
# 能不能重跑：段 1 會清掉 lab（reset）；要接著跑用 FROM。**跑的時候不要改這支**（bash 邊讀邊跑）。
#
# 版本、JDK、OS 小版本都在 install/conf/site.env（基底 CP_VERSION 等、目標 *_TARGET_*）；這支不改它，只在遷移做完後用 29-upgrade.sh adopt 改 lab 裡那份。
#
# 與 CyberArk 唯一的關係是人員登入：人員經 PVWA 網頁＋PSMP 登入操作機就是 root，lab 無法模擬這段，
# 直接 podman exec 以 root 進 ops02。操作機到各主機一律用 cpuser＋/secure/ssh 的那把金鑰（lab 用獨立的 podman volume 模擬那個獨立 file system）。
#
# 正式環境由人做的事，這支扮演：
#   工程師        第 4 站在操作機產生金鑰對（root、0400，/secure/ssh）
#   OS 團隊       每台主機建 cpuser、sshd 設定、公鑰行（from=）、安裝期 sudo（bank-sim prepare）；備 OS 9.6 套件庫與 9.8 更新集合（bank-sim os-content）；
#                 遷移最後把套件庫同步到 9.8（bank-sim os-sync）
#   工程師        第 15 站在操作機自己產生 passphrase 與 master key，存 ~/secrets（0600）；平台的密碼與金鑰不放 CyberArk
#   LB 團隊       重啟 REST 前停用那一台（bank-sim lb-watch）
#
# 遷移期間（段 17–22 的 Confluent／JDK 遷移、段 32 的 OS 更新）各跑一段持續流量（install/tools/load.sh）：直連應用程式遺失幾筆、經 LB 的 REST 失敗幾次。
set -uo pipefail
export MSYS_NO_PATHCONV=1

# 安裝 Podman 之前就開著的 Git Bash 找不到 podman
if ! command -v podman > /dev/null 2>&1; then
  podman_dir=$(cygpath -u "$LOCALAPPDATA")/Programs/Podman
  export PATH="$podman_dir:$PATH"
fi

script_dir=$(dirname "$0")
LAB_TOOLS_DIR=$(
  if ! cd "$script_dir"; then
    exit 1
  fi

  pwd
)
LAB=${LAB:-$HOME/kafka-lab}
OPS_CONTAINER=lab-ops02-1
started_at=$(date +%s)

# site_value <名稱>：repo 裡 site.env 的值（去掉行尾註解）
#   例：CP_VERSION=8.2.4   # 基底 → 8.2.4
site_value() {
  grep -m 1 -E "^$1=" "$LAB_TOOLS_DIR/../conf/site.env" | cut -d= -f2 | cut -d' ' -f1
}

# 預期的版本：讀 repo 裡的 site.env（基底與目標）
BASE_CP=$(site_value CP_VERSION)
BASE_C3=$(site_value C3_VERSION)
BASE_JDK=$(site_value JDK_MAJOR)
BASE_OS=$(site_value OS_BASE_VERSION)
TARGET_CP=$(site_value CP_TARGET_VERSION)
TARGET_C3=$(site_value C3_TARGET_VERSION)
TARGET_JDK=$(site_value JDK_TARGET_MAJOR)
TARGET_OS=$(site_value OS_TARGET_VERSION)

# bank <子命令…>：扮演銀行
bank() { bash "$LAB_TOOLS_DIR/bank-sim.sh" "$@"; }

# 扮演 LB 團隊（手把手 12.1）：腳本重啟 REST 前會寫 ~/lb-requests/ 的請求，bank-sim lb-watch 照做後回覆
LB_TEAM_STOP="$LAB/lb-watch.stop.$$"   # 每支 runner 自己的結束訊號
bash "$LAB_TOOLS_DIR/bank-sim.sh" lb-watch "$LB_TEAM_STOP" >> "$LAB/lb-watch.log" 2>&1 &
LB_TEAM_PID=$!

stop_lb_team() {
  touch "$LB_TEAM_STOP"
  kill "$LB_TEAM_PID" 2> /dev/null
}
trap stop_lb_team EXIT

# omnibus_fields_are_strings：第 32 章的測試告警送到接收端時，每個欄位都是字串（0.32.x 會改成物件、數字）
omnibus_fields_are_strings() {
  local webhook_lines first_body

  # 1. 接收端紀錄裡，第 32 章測試告警的那幾行
  webhook_lines=$(MSYS_NO_PATHCONV=1 podman logs lab-mon-webhook 2>&1 \
    | grep '^POST /c3-omnibus' \
    | grep Chapter32WithTarget)

  # 2. 取第一行，去掉 { 之前的部分，只留 JSON 本體
  first_body=$(sed 's/^[^{]*//' <<<"$webhook_lines" | head -1)

  # 3. 在容器裡用 python 看每個欄位的型別
  printf '%s\n' "$first_body" | MSYS_NO_PATHCONV=1 podman run --rm -i lab-node:96 python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
bad = [k for k, v in d.items() if not isinstance(v, str)]
print("omnibus 欄位", len(d), "個；非字串：", bad)
sys.exit(1 if bad or len(d) != 10 else 0)'
}

# stage <段號> <標題>：段號小於 FROM 或大於 TO 就略過這一段（回 1），否則印標題（回 0）
stage() {
  local number=$1
  shift

  if [ "$number" -lt "${FROM:-1}" ]; then
    return 1
  fi

  if [ "$number" -gt "${TO:-99}" ]; then
    return 1
  fi

  printf '\n######## %s %s (+%ss) ########\n' "$number" "$*" "$(( $(date +%s) - started_at ))"
}

# must <指令…>：指令失敗就結束整支（結束碼 1）
must() {
  if ! "$@"; then
    exit 1
  fi
}

# 在操作機以 root 跑 install.sh（人員經 PSMP 登入就是 root；lab 直接 podman exec）
install_on_ops() { podman exec -w /root "$OPS_CONTAINER" bash install/install.sh "$@" < /dev/null; }

# 隨時執行的站（20 以後）：直接跑那一支。step_on_ops <腳本> [參數…]
step_on_ops() {
  local script=$1
  shift
  podman exec -w /root "$OPS_CONTAINER" bash "install/steps/$script" "$@" < /dev/null
}

# step_on_one_host <主機> <腳本> [參數…]：同上，但只做那一台（ONLY_HOSTS）
step_on_one_host() {
  local host=$1 script=$2
  shift 2
  podman exec -w /root -e ONLY_HOSTS="$host" "$OPS_CONTAINER" bash "install/steps/$script" "$@" < /dev/null
}

# 在操作機跑一段指令
on_ops() { podman exec -w /root "$OPS_CONTAINER" bash -c "$1" < /dev/null; }

# expect_wait_for_bank <rc> <站> [前置站]：install.sh 應該停在「第 <站> 站等銀行」（rc 2）。
# 給了前置站就再確認它已經做完（略過的站不會留完成標記，所以由呼叫的地方指定），不然可能是更早的站在等銀行
expect_wait_for_bank() {
  local exit_code=$1 step=$2 prerequisite_step=${3:-}

  if [ "$exit_code" != 2 ]; then
    echo "預期 $step 停在等銀行（rc 2），實際 rc=$exit_code"
    exit 1
  fi

  if [ -n "$prerequisite_step" ]; then
    if ! podman exec "$OPS_CONTAINER" bash -c "ls ~/install-logs/$prerequisite_step-*.done" > /dev/null 2>&1; then
      echo "停在等銀行，但第 $prerequisite_step 站還沒做完：停的不是第 $step 站"
      exit 1
    fi
  fi
}

# 第 19 站驗收；任何一項 FAIL 就停。$1 = 這是哪個時間點
acceptance() {
  local label=$1 output

  printf '\n-- 驗收（%s）\n' "$label"

  # 1. 跑驗收，只印結果那一行與失敗的項目
  output=$(install_on_ops --only 19 2>&1)
  grep -E '驗收：| FAIL ' <<<"$output"

  # 2. 判斷
  if grep -q ' FAIL ' <<<"$output"; then
    echo "驗收未全過（$label）"
    exit 1
  fi

  if ! grep -q '驗收：' <<<"$output"; then
    echo "找不到驗收結果（$label）"
    exit 1
  fi

  return 0
}

# 每台主機的 OS 小版本、JDK 主版號、主要套件版本（controller／broker 看 confluent-server，REST 看 confluent-kafka-rest，C3 看 control-center）
#   輸出一行一台，例：kb01 9.6 21 8.2.4
VERSION_PROBE=$(cat <<'PROBE'
for host in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh "$host.poc.lab" 'bash -s' <<'REMOTE'
. /etc/os-release
jdk=$(readlink /opt/java/current | sed 's#/opt/java/jdk-##; s#[.+].*##')

case $(hostname) in
  kc*|kb*)
    pkg=confluent-server
    ;;
  rest*)
    pkg=confluent-kafka-rest
    ;;
  *)
    pkg=confluent-control-center-next-gen
    ;;
esac

echo "$(hostname) $VERSION_ID $jdk $(rpm -q --qf '%{VERSION}' $pkg)"
REMOTE
done
PROBE
)

show_versions() {
  printf '\n-- 版本（%s）：主機 OS JDK 套件\n' "$1"
  on_ops "$VERSION_PROBE"
}

# expect_versions <CP 版本> <C3 版本> <JDK 主版號> <OS 小版本>：每台主機都照這三個參數（c3-01 的套件看 C3 版本）；不符就停
expect_versions() {
  local cp=$1 c3=$2 jdk=$3 os=$4 probe_output host host_os host_jdk host_version want_version bad=0

  # 1. 查一次
  probe_output=$(on_ops "$VERSION_PROBE")

  # 2. 逐台比對
  while read -r host host_os host_jdk host_version; do
    case $host in
      c3-01)
        want_version=$c3
        ;;
      *)
        want_version=$cp
        ;;
    esac

    if [ "$host_os $host_jdk $host_version" != "$os $jdk $want_version" ]; then
      echo "$host：OS/JDK/套件 = $host_os/$host_jdk/$host_version（預期 $os/$jdk/$want_version）"
      bad=1
    fi
  done <<<"$probe_output"

  # 3. 判斷
  if [ "$bad" != 0 ]; then
    return 1
  fi

  echo "10 台都符合：OS $os、Confluent $cp、C3 $c3、JDK $jdk"
}

# 工程師：確認操作機上的私鑰在獨立的 file system（lab：podman volume）、root:root 0400、不是系統碟的一部分
ENGINEER_KEY_CHECK=$(cat <<'EOF'
if ! mountpoint -q /secure/ssh; then
  exit 1
fi

echo "mounted: /secure/ssh"
stat -c "%U:%G %a %n" /secure/ssh/cpuser_ed25519 /secure/ssh/cpuser_ed25519.pub
EOF
)

engineer_checks_key() { podman exec "$OPS_CONTAINER" bash -c "$ENGINEER_KEY_CHECK"; }

# 手把手 31.1（dl01）：下載單一 C3 版本（演練用的 2.6.0）、驗章。已經下載過、檔案沒壞就沿用（約 1 GB，不重抓）；簽章不管怎樣都驗
C3_DRILL_DOWNLOAD=$(cat <<'EOF'
V=2.6.0
rpm=confluent-control-center-next-gen-$V-1.noarch.rpm

mkdir -p /out/c3
if ! cd /out/c3; then
  exit 1
fi

# have_copy：這個版本的 RPM 已經在這裡、而且 SHA256SUMS 對得上就印 yes，否則 no
have_copy() {
  if [ ! -f $rpm ]; then
    echo no
    return
  fi

  if ! grep -q " ./$rpm\$" SHA256SUMS 2> /dev/null; then
    echo no
    return
  fi

  if ! sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1; then
    echo no
    return
  fi

  echo yes
}

# 1. 已經下載過、檔案沒壞就沿用；否則清掉舊檔，dnf 只給下載網址、curl 下載（dnf download 下載完常常不會結束）
if [ "$(have_copy)" = yes ]; then
  echo "已經有 $rpm，sha256 對得上，不重新下載"
else
  rm -f ./*.rpm SHA256SUMS
  curl -fsS -O "$(dnf -q download --url confluent-control-center-next-gen-$V | head -1)"
  sha256sum ./*.rpm > SHA256SUMS
fi

# 2. 不管是不是沿用，簽章都驗一次
rpm -K ./*.rpm
ls
EOF
)

# 手把手 31.2（操作機）：設成唯讀、核對 sha256
C3_DRILL_VERIFY=$(cat <<'EOF'
chmod -R a-w /root/landing/c3
if ! cd /root/landing/c3; then
  exit 1
fi
sha256sum -c --quiet SHA256SUMS
echo sha256-ok
EOF
)

# 手把手 31.2（操作機）：RPM 有沒有新增相依；c3-01 上原廠要求的前置套件都在（RPM 不宣告相依，dnf 不會替你查）
C3_DRILL_PREREQUISITES=$(cat <<'EOF'
if ! cd ~/landing/c3; then
  exit 1
fi

rpm_requires=$(rpm -qpR confluent-control-center-next-gen-*.rpm | grep -vE '^(rpmlib|/)' | sort -u)
echo "RPM 宣告的相依：$(paste -sd';' - <<<"$rpm_requires")"
ssh c3-01.poc.lab 'rpm -q cyrus-sasl openssl-devel'
EOF
)

# 第 31 章 31.1–31.2：dl01 下載單一 C3 版本、驗章、送進操作機的落地區
bring_in_c3_drill_version() {
  # 1. 下載、驗章（31.1）
  if ! podman exec dl01 bash -e -c "$C3_DRILL_DOWNLOAD" < /dev/null; then
    return 1
  fi

  # 2. 送進操作機的落地區（同名的舊目錄先清掉：重跑時可能已經有）
  podman exec "$OPS_CONTAINER" bash -c 'rm -rf /root/landing/c3'
  podman exec "$OPS_CONTAINER" mkdir -p /root/landing

  if ! podman cp "$(cygpath -m "$LAB/landing/c3")" "$OPS_CONTAINER:/root/landing/"; then
    return 1
  fi

  # 3. 唯讀、核對 sha256
  if ! podman exec "$OPS_CONTAINER" bash -e -c "$C3_DRILL_VERIFY"; then
    return 1
  fi

  # 4. 相依與前置套件
  podman exec "$OPS_CONTAINER" bash -e -c "$C3_DRILL_PREREQUISITES"
}

# 段 4 的標題要說明 OS 內容是不是已經備好
if [ -d "$LAB/bank-os" ]; then
  os_content_state=已備好
else
  os_content_state="先備 9.6 套件庫與 9.8 更新集合"
fi

# ---------------------------------------------------------------- 各段
# 銀行的動作（reset、os-content、intake、prepare、sign、monitoring）失敗時不在這裡停：下一段會撞到（段 5、8 還會檢查結束碼）

if stage 1 "reset"; then
  bank reset
fi

if stage 2 "落地區版面整理（舊版面 → rpm/ 基底、rpm-target/ 目標）、push install/"; then
  if bank landing-layout; then
    bank push
  fi
fi

if stage 3 "02 download（dl01）：兩套 Confluent、兩個 JDK"; then
  must podman exec dl01 bash /root/install/steps/02-download.sh < /dev/null
fi

if stage 4 "銀行：檔案交換、OS 內容（$os_content_state）"; then
  if bank os-content; then
    bank intake
  fi
fi

if stage 5 "03–04（產生金鑰後，cpuser 還沒建，04 應停下）"; then
  install_on_ops --to 04
  expect_wait_for_bank $? 04
fi

if stage 6 "工程師：確認私鑰在 /secure/ssh（獨立 file system、root、0400）"; then
  must engineer_checks_key
fi

if stage 7 "銀行：cpuser＋公鑰（from=）＋安裝期 sudo、套件庫（OS 9.6）、根憑證、AD、NTP、LB"; then
  bank prepare
fi

if stage 8 "04–09"; then
  install_on_ops --from 04 --to 09
  expect_wait_for_bank $? 09 08
fi

if stage 9 "銀行：CA 簽發"; then
  bank sign
fi

if stage 10 "09–14"; then
  must install_on_ops --from 09 --to 14
fi

if stage 11 "11.2 AD 斷線演練：停 ad01 → alice 登不進、kafka-admin（SCRAM，SystemAdmin）仍可用 → 開回"; then
  must bank ad-drill
fi

if stage 12 "15–18（15 站由工程師在操作機產生 passphrase 與 master key，不用等任何人）"; then
  must install_on_ops --from 15 --to 18
fi

if stage 13 "銀行：行內 Prometheus 接上（17.6）"; then
  bank monitoring
fi

if stage 14 "機房：冷開機（19.4）；/secure/ssh 的 volume 還在，金鑰不用重放"; then
  must bank coldboot
  must engineer_checks_key
fi

if stage 15 "19 驗收（安裝基底：CP 8.2.4、C3 2.5.1、JDK 21、OS 9.6）"; then
  show_versions "基底"
  must expect_versions "$BASE_CP" "$BASE_C3" "$BASE_JDK" "$BASE_OS"
  acceptance "基底"

  if [ "${IDEMPOTENCE:-0}" = 1 ]; then
    printf '\n-- 重跑 03–14（驗冪等）\n'
    must install_on_ops --from 03 --to 14
  fi
fi

if stage 16 "21 憑證：status、leaf 換發（第一次停在等銀行簽）"; then
  must step_on_ops 21-cert-rotate.sh status
  step_on_ops 21-cert-rotate.sh leaf
  leaf_rc=$?

  if [ "$leaf_rc" != 2 ]; then
    echo "21 leaf 第一次應停在等銀行（rc 2）"
    exit 1
  fi

  must bank sign-next
  must step_on_ops 21-cert-rotate.sh leaf
  acceptance "憑證換發後（基底版本）"
fi

if stage 17 "遷移開始：持續流量；29 publish（目標版本上架）、plan、backup"; then
  must on_ops 'bash install/tools/load.sh start'
  must step_on_ops 29-upgrade.sh publish
  must step_on_ops 29-upgrade.sh plan
  must step_on_ops 29-upgrade.sh backup
fi

if stage 18 "29 第一段：C3 → 2.6.1、套件 → 8.3.2（JDK 仍是 21）"; then
  must step_on_ops 29-upgrade.sh packages
  acceptance "第一段：8.3.2＋JDK 21"
fi

if stage 19 "29 第二段：JDK 21 → 25"; then
  must step_on_ops 29-upgrade.sh jdk
  acceptance "第二段：8.3.2＋JDK 25"
fi

if stage 20 "29 回滾演練：kb04 回 8.2.4＋JDK 21，再升回去"; then
  must step_on_ops 29-upgrade.sh rollback kb04
  must step_on_one_host kb04 29-upgrade.sh packages
  must step_on_one_host kb04 29-upgrade.sh jdk
fi

if stage 21 "29 第三段：finalize（不帶確認要停下，帶 cluster id 才升）、adopt"; then
  if step_on_ops 29-upgrade.sh finalize 4.3; then
    echo "不帶確認竟然執行了 finalize"
    exit 1
  fi

  must on_ops 'source ~/conf/kraft.env
CONFIRM_CLUSTER_ID=$CLUSTER_ID bash install/steps/29-upgrade.sh finalize 4.3'
  must step_on_ops 29-upgrade.sh adopt
  acceptance "第三段：finalize 之後"
  show_versions "遷移後（第 29 章）"
  must expect_versions "$TARGET_CP" "$TARGET_C3" "$TARGET_JDK" "$BASE_OS"
fi

if stage 22 "持續流量結果（第 29 章這一段）"; then
  on_ops 'bash install/tools/load.sh stop'
  on_ops 'bash install/tools/load.sh report'
fi

if stage 23 "26 license：status、schedule"; then
  step_on_ops 26-license.sh status
  license_rc=$?

  # 試用版不到 90 天是 rc 2
  case $license_rc in
    0|2)
      ;;
    *)
      exit 1
      ;;
  esac

  must step_on_ops 26-license.sh schedule
fi

if stage 24 "23 日常備份：grant、run、schedule、compare"; then
  must step_on_ops 23-metadata-backup.sh grant
  must step_on_ops 23-metadata-backup.sh run
  sleep 61
  must step_on_ops 23-metadata-backup.sh schedule
  must step_on_ops 23-metadata-backup.sh compare
fi

if stage 25 "23.6 還原演練：建演練物件 → 備份 → 誤刪 → restore → 寫讀一筆 → 清掉"; then
  must step_on_ops 23-metadata-backup.sh drill
fi

if stage 26 "24 磁碟與容量：usage、alerts（銀行 monitoring-reload）、drill（retention 縮短、partition 搬離）"; then
  must step_on_ops 24-disk.sh usage
  must step_on_ops 24-disk.sh alerts
  must bank monitoring-reload
  must step_on_ops 24-disk.sh drill
fi

if stage 27 "22 憑證到期監控：files（銀行 monitoring-blackbox：exporter、cert-expiry job、規則、promtool test）、check、schedule"; then
  must step_on_ops 22-cert-expiry.sh files
  must bank monitoring-blackbox
  must step_on_ops 22-cert-expiry.sh check
  must step_on_ops 22-cert-expiry.sh schedule
fi

stage_title="28 故障排查：快照全綠 → 銀行停 kb04 → 症狀 → 告警 firing → 重啟 → 歸零、告警解除；"
stage_title="${stage_title}28.6 擋掉 8090 → 緊急主機模式、kafka-admin → 開回、換 kafka-admin 密碼"

if stage 28 "$stage_title"; then
  must step_on_ops 28-triage.sh snapshot
  must bank broker-stop kb04
  must step_on_ops 28-triage.sh drill kb04
  must bank alerts-wait
  must step_on_ops 28-triage.sh recover kb04
  must bank alerts-clear
  must step_on_ops 28-triage.sh snapshot

  # 28.6：演練失敗也要開回，所以先記下結果、開回之後才判斷
  bank mds-block on
  mds_down_rc=$?

  if [ "$mds_down_rc" = 0 ]; then
    step_on_ops 28-triage.sh mds-down
    mds_down_rc=$?
  fi

  bank mds-block off

  if [ "$mds_down_rc" != 0 ]; then
    exit 1
  fi

  must step_on_ops 28-triage.sh mds-back
fi

if stage 29 "27 新應用上線：inventory（SCRAM A／B）、shipping（憑證，銀行簽）→ 驗證 → 下線"; then
  must step_on_ops 27-onboard.sh onboard inventory scram inventory.stock:3:3
  must step_on_ops 27-onboard.sh verify inventory scram inventory.stock

  # 憑證的第一次 onboard 要停在請銀行簽（rc 2）
  step_on_ops 27-onboard.sh onboard shipping cert shipping.events:3:7
  onboard_rc=$?

  if [ "$onboard_rc" != 2 ]; then
    exit 1
  fi

  must bank sign-app app-shipping
  must step_on_ops 27-onboard.sh onboard shipping cert shipping.events:3:7
  must step_on_ops 27-onboard.sh verify shipping cert shipping.events

  must step_on_ops 27-onboard.sh retire inventory scram inventory.stock
  must step_on_ops 27-onboard.sh retire shipping cert shipping.events
fi

if stage 30 "25.1 換 controller（kc03 清空重建）"; then
  must step_on_ops 25-1-controller-replace.sh replace kc03
fi

if stage 31 "25.2 broker 縮減與擴充（kb04）"; then
  must step_on_ops 25-2-broker-scale.sh remove kb04
  must step_on_ops 25-2-broker-scale.sh add kb04
fi

if stage 32 "30 OS 小版本更新 9.6 → 9.8：銀行套件庫同步、plan、apply、verify（lab 不能真的重開機）"; then
  must on_ops 'bash install/tools/load.sh start'
  must bank os-sync
  must step_on_ops 30-os-patch.sh plan
  must step_on_ops 30-os-patch.sh apply
  must step_on_ops 30-os-patch.sh verify "$TARGET_OS"
  on_ops 'bash install/tools/load.sh stop'
  on_ops 'bash install/tools/load.sh report'
  acceptance "OS 9.8"
  show_versions "OS 更新後（第 30 章）"
  must expect_versions "$TARGET_CP" "$TARGET_C3" "$TARGET_JDK" "$TARGET_OS"
fi

if stage 33 "31 C3：帶進 2.6.0、退回、升回 2.6.1（回滾程序；2.6.x 都支援 CP 8.3）"; then
  must bring_in_c3_drill_version
  must step_on_ops 29-upgrade.sh publish c3
  must step_on_ops 29-upgrade.sh c3 2.6.0
  must step_on_ops 29-upgrade.sh c3 "$TARGET_C3"
fi

if stage 34 "32 C3 告警：第二個 Alertmanager、抓 REST Proxy、依 target 分流"; then
  must step_on_ops 32-c3-alerting.sh install
  must step_on_ops 32-c3-alerting.sh test
  must omnibus_fields_are_strings
fi

if stage 35 "19 驗收（全部做完）"; then
  acceptance "全部做完"
  install_on_ops --list
fi

exit 0
