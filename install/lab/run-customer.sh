#!/usr/bin/env bash
# install/lab/run-customer.sh —— lab：用「客戶模式」從零實跑整條遷移主線（Windows Git Bash）
#
#   bash run-customer.sh                  從零（bank-sim reset）：先裝安裝基底（CP 8.2.4、C3 2.5.1、JDK 21、OS 9.6）到第 19 站驗收，
#                                         再遷移到 CP 8.3.2、C3 2.6.1、JDK 25、OS 9.8（第 21、26、27 章），每段之後都驗收
#   FROM=6 bash run-customer.sh           從第 6 段接著跑（段號在每段的 ######## 標題裡）
#   TO=15 bash run-customer.sh            跑到第 14 段（基底的驗收）就停
#   IDEMPOTENCE=1 bash run-customer.sh    基底裝完（第 14 站）後再跑一次 02–14，驗證重跑是安全的（原本 run-all.sh --no-reset 的用途）
#
# 這支取代了舊的 run-upgrade-drill.sh（升級演練）與 run-all.sh：升級不再是另一件事，而是主線。
# 版本、JDK、OS 小版本都在 install/conf/site.env（基底 CP_VERSION 等、目標 *_TARGET_*）；這支不改它，只在遷移做完後用 29-upgrade.sh adopt 改 lab 裡那份。
#
# 與 CyberArk 唯一的關係是人員登入：人員經 PVWA 網頁＋PSMP 登入操作機就是 root，lab 無法模擬這段，
# 直接 docker exec 以 root 進 ops02。操作機到各主機一律用 cpuser＋/secure/ssh 的那把金鑰（lab 用獨立的 docker volume 模擬那個獨立 file system）。
#
# 正式環境由人做的事，這支扮演：
#   工程師        第 4 站在操作機產生金鑰對（root、0400，/secure/ssh）
#   OS 團隊       每台主機建 cpuser、sshd 設定、公鑰行（from=）、安裝期 sudo（bank-sim prepare）；備 OS 9.6 套件庫與 9.8 更新集合（bank-sim os-content）；
#                 遷移最後把套件庫同步到 9.8（bank-sim os-sync）
#   工程師        第 15 站在操作機自己產生 passphrase 與 master key，存 ~/secrets（0600）；平台的密碼與金鑰不放 CyberArk
#   LB 團隊       重啟 REST 前停用那一台（bank-sim lb-watch）
#
# 遷移期間（段 17–22 的 Confluent／JDK 遷移、段 27 的 OS 更新）各跑一段持續流量（install/tools/load.sh）：直連應用程式遺失幾筆、經 LB 的 REST 失敗幾次。
set -uo pipefail
export MSYS_NO_PATHCONV=1
LAB_TOOLS_DIR=$(cd "$(dirname "$0")" && pwd)
BANK="bash $LAB_TOOLS_DIR/bank-sim.sh"
LAB=${LAB:-$HOME/kafka-lab}
OPS_CONTAINER=lab-ops02-1
started_at=$(date +%s)
# 預期的版本：讀 repo 裡的 site.env（基底與目標）
site_value() { grep -E "^$1=" "$LAB_TOOLS_DIR/../conf/site.env" | head -1 | cut -d= -f2 | cut -d' ' -f1; }
BASE_CP=$(site_value CP_VERSION); BASE_C3=$(site_value C3_VERSION); TARGET_CP=$(site_value CP_TARGET_VERSION); TARGET_C3=$(site_value C3_TARGET_VERSION)
BASE_JDK=$(site_value JDK_MAJOR); TARGET_JDK=$(site_value JDK_TARGET_MAJOR); BASE_OS=$(site_value OS_BASE_VERSION); TARGET_OS=$(site_value OS_TARGET_VERSION)
# 扮演 LB 團隊（手把手 12.1）：腳本重啟 REST 前會寫 ~/lb-requests/ 的請求，bank-sim lb-watch 照做後回覆
LB_TEAM_STOP="$LAB/lb-watch.stop.$$"   # 每支 runner 自己的結束訊號
bash "$LAB_TOOLS_DIR/bank-sim.sh" lb-watch "$LB_TEAM_STOP" >> "$LAB/lb-watch.log" 2>&1 &
LB_TEAM_PID=$!
trap 'touch "$LB_TEAM_STOP"; kill $LB_TEAM_PID 2>/dev/null' EXIT

# stage <段號> <標題>：段號小於 FROM 或大於 TO 就略過這一段（回 1），否則印標題（回 0）
stage() {
  local number=$1; shift
  [ "$number" -ge "${FROM:-1}" ] || return 1
  [ "$number" -le "${TO:-99}" ] || return 1
  printf '\n######## %s %s (+%ss) ########\n' "$number" "$*" "$(( $(date +%s) - started_at ))"
}
# 在操作機以 root 跑 install.sh（人員經 PSMP 登入就是 root；lab 直接 docker exec）
install_on_ops() { docker exec -w /root "$OPS_CONTAINER" bash install/install.sh "$@" </dev/null; }
# 隨時執行的站（20 以後）：直接跑那一支
step_on_ops() { local script=$1; shift; docker exec -w /root "$OPS_CONTAINER" bash "install/steps/$script" "$@" </dev/null; }
# 在操作機跑一行指令
on_ops() { docker exec -w /root "$OPS_CONTAINER" bash -c "$1" </dev/null; }
# expect_wait_for_bank <rc> <站> [前置站]：install.sh 應該停在「第 <站> 站等銀行」（rc 2）。
# 給了前置站就再確認它已經做完（略過的站不會留完成標記，所以由呼叫的地方指定），不然可能是更早的站在等銀行
expect_wait_for_bank() {
  local exit_code=$1 step=$2 prerequisite_step=${3:-}
  if [ "$exit_code" != 2 ]; then echo "預期 $step 停在等銀行（rc 2），實際 rc=$exit_code"; exit 1; fi
  if [ -n "$prerequisite_step" ] && ! docker exec "$OPS_CONTAINER" bash -c "ls ~/install-logs/$prerequisite_step-*.done" >/dev/null 2>&1; then
    echo "停在等銀行，但第 $prerequisite_step 站還沒做完：停的不是第 $step 站"; exit 1
  fi
}

# 第 19 站驗收；任何一項 FAIL 就停。$1 = 這是哪個時間點
acceptance() {
  local label=$1 output
  printf '\n-- 驗收（%s）\n' "$label"
  output=$(install_on_ops --only 19 2>&1); grep -E '驗收：| FAIL ' <<<"$output" || true
  grep -q ' FAIL ' <<<"$output" && { echo "驗收未全過（$label）"; exit 1; }
  grep -q '驗收：' <<<"$output" || { echo "找不到驗收結果（$label）"; exit 1; }
  return 0
}
# 每台主機的 OS 小版本、JDK 主版號、主要套件版本（controller／broker 看 confluent-server，REST 看 confluent-kafka-rest，C3 看 control-center）
VERSION_PROBE=$(cat <<'PROBE'
for host in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01; do
  ssh "$host.poc.lab" 'bash -s' <<'REMOTE'
. /etc/os-release
jdk=$(readlink /opt/java/current | sed 's#/opt/java/jdk-##; s#[.+].*##')
case $(hostname) in kc*|kb*) pkg=confluent-server;; rest*) pkg=confluent-kafka-rest;; *) pkg=confluent-control-center-next-gen;; esac
echo "$(hostname) $VERSION_ID $jdk $(rpm -q --qf '%{VERSION}' $pkg)"
REMOTE
done
PROBE
)
show_versions() { printf '\n-- 版本（%s）：主機 OS JDK 套件\n' "$1"; on_ops "$VERSION_PROBE"; }
# expect_versions <CP 版本> <C3 版本> <JDK 主版號> <OS 小版本>：c3-01 的 JDK 一直留在基底（21），其他主機照第三個參數；不符就停
expect_versions() {
  local cp=$1 c3=$2 jdk=$3 os=$4 host host_os host_jdk host_version want_version want_jdk bad=0
  while read -r host host_os host_jdk host_version; do
    case $host in c3-01) want_version=$c3; want_jdk=$BASE_JDK;; *) want_version=$cp; want_jdk=$jdk;; esac
    if [ "$host_os $host_jdk $host_version" != "$os $want_jdk $want_version" ]; then
      echo "$host：OS/JDK/套件 = $host_os/$host_jdk/$host_version（預期 $os/$want_jdk/$want_version）"; bad=1
    fi
  done < <(on_ops "$VERSION_PROBE")
  [ "$bad" = 0 ] || return 1
  echo "10 台都符合：OS $os、Confluent $cp、C3 $c3、JDK $jdk（c3-01 留在 21）"
}

# 工程師：確認操作機上的私鑰在獨立的 file system（lab：docker volume）、root:root 0400、不是系統碟的一部分
engineer_checks_key() {
  docker exec "$OPS_CONTAINER" bash -c 'mountpoint -q /secure/ssh && echo "mounted: /secure/ssh" && stat -c "%U:%G %a %n" /secure/ssh/cpuser_ed25519 /secure/ssh/cpuser_ed25519.pub'
}

# 第 31 章 31.1–31.2：dl01 下載單一 C3 版本（演練用的 2.6.0）、驗章、送進操作機的落地區
bring_in_c3_drill_version() {
  docker exec dl01 bash -c 'V=2.6.0 && mkdir -p /out/c3 && cd /out/c3 && rm -f ./*.rpm SHA256SUMS && curl -fsS -O "$(dnf -q download --url confluent-control-center-next-gen-$V | head -1)" && rpm -K ./*.rpm && sha256sum ./*.rpm > SHA256SUMS && ls' </dev/null || return 1
  docker exec "$OPS_CONTAINER" bash -c 'rm -rf /root/landing/c3; mkdir -p /root/landing'
  docker cp "$(cygpath -m "$LAB/landing/c3")" "$OPS_CONTAINER:/root/landing/" && docker exec "$OPS_CONTAINER" bash -c "chmod -R a-w /root/landing/c3 && cd /root/landing/c3 && sha256sum -c --quiet SHA256SUMS && echo sha256-ok" &&
  docker exec "$OPS_CONTAINER" bash -c 'cd ~/landing/c3 && echo "RPM 宣告的相依：$(rpm -qpR confluent-control-center-next-gen-*.rpm | grep -vE "^(rpmlib|/)" | sort -u | paste -sd";" -)" && ssh c3-01.poc.lab "rpm -q cyrus-sasl openssl-devel"'
}

stage 1 "reset" && { $BANK reset; }
stage 2 "落地區版面整理（舊版面 → rpm/ 基底、rpm-target/ 目標）、push install/" && { $BANK landing-layout && $BANK push; }
stage 3 "02 download（dl01）：兩套 Confluent、兩個 JDK" && { docker exec dl01 bash /root/install/steps/02-download.sh </dev/null || exit 1; }
stage 4 "銀行：檔案交換、OS 內容（$([ -d "$LAB/bank-os" ] && echo 已備好 || echo 先備 9.6 套件庫與 9.8 更新集合)）" && { $BANK os-content && $BANK intake; }
stage 5 "03–04（產生金鑰後，cpuser 還沒建，04 應停下）" && { install_on_ops --to 04; expect_wait_for_bank $? 04; }
stage 6 "工程師：確認私鑰在 /secure/ssh（獨立 file system、root、0400）" && { engineer_checks_key || exit 1; }
stage 7 "銀行：cpuser＋公鑰（from=）＋安裝期 sudo、套件庫（OS 9.6）、根憑證、AD、NTP、LB" && { $BANK prepare; }
stage 8 "04–09" && { install_on_ops --from 04 --to 09; expect_wait_for_bank $? 09 08; }
stage 9 "銀行：CA 簽發" && { $BANK sign; }
stage 10 "09–14" && { install_on_ops --from 09 --to 14 || exit 1; }
stage 11 "11.2 AD 斷線演練：停 ad01 → alice 登不進、kafka-admin（SCRAM，SystemAdmin）仍可用 → 開回" && { $BANK ad-drill || exit 1; }
stage 12 "15–18（15 站由工程師在操作機產生 passphrase 與 master key，不用等任何人）" && { install_on_ops --from 15 --to 18 || exit 1; }
stage 13 "銀行：行內 Prometheus 接上（17.6）" && { $BANK monitoring; }
stage 14 "機房：冷開機（19.4）；/secure/ssh 的 volume 還在，金鑰不用重放" && { $BANK coldboot && engineer_checks_key || exit 1; }
stage 15 "19 驗收（安裝基底：CP 8.2.4、C3 2.5.1、JDK 21、OS 9.6）" && {
  show_versions "基底"
  expect_versions "$BASE_CP" "$BASE_C3" "$BASE_JDK" "$BASE_OS" || exit 1
  acceptance "基底"
  if [ "${IDEMPOTENCE:-0}" = 1 ]; then
    printf '\n-- 重跑 03–14（驗冪等）\n'; install_on_ops --from 03 --to 14 || exit 1
  fi
}
stage 16 "21 憑證：status、leaf 換發（第一次停在等銀行簽）" && {
  step_on_ops 21-cert-rotate.sh status || exit 1
  step_on_ops 21-cert-rotate.sh leaf; [ $? = 2 ] || { echo "21 leaf 第一次應停在等銀行（rc 2）"; exit 1; }
  $BANK sign-next && step_on_ops 21-cert-rotate.sh leaf || exit 1
  acceptance "憑證換發後（基底版本）"
}
stage 17 "遷移開始：持續流量；29 publish（目標版本上架）、plan、backup" && {
  on_ops 'bash install/tools/load.sh start' || exit 1
  step_on_ops 29-upgrade.sh publish && step_on_ops 29-upgrade.sh plan && step_on_ops 29-upgrade.sh backup || exit 1
}
stage 18 "29 第一段：C3 → 2.6.1、套件 → 8.3.2（JDK 仍是 21）" && { step_on_ops 29-upgrade.sh packages || exit 1; acceptance "第一段：8.3.2＋JDK 21"; }
stage 19 "29 第二段：JDK 21 → 25" && { step_on_ops 29-upgrade.sh jdk || exit 1; acceptance "第二段：8.3.2＋JDK 25"; }
stage 20 "29 回滾演練：kb04 回 8.2.4＋JDK 21，再升回去" && {
  step_on_ops 29-upgrade.sh rollback kb04 || exit 1
  docker exec -w /root -e ONLY_HOSTS=kb04 "$OPS_CONTAINER" bash install/steps/29-upgrade.sh packages </dev/null || exit 1
  docker exec -w /root -e ONLY_HOSTS=kb04 "$OPS_CONTAINER" bash install/steps/29-upgrade.sh jdk </dev/null || exit 1
}
stage 21 "29 第三段：finalize（不帶確認要停下，帶 cluster id 才升）、adopt" && {
  if step_on_ops 29-upgrade.sh finalize 4.3; then echo "不帶確認竟然執行了 finalize"; exit 1; fi
  on_ops 'source ~/conf/kraft.env; CONFIRM_CLUSTER_ID=$CLUSTER_ID bash install/steps/29-upgrade.sh finalize 4.3' || exit 1
  step_on_ops 29-upgrade.sh adopt || exit 1
  acceptance "第三段：finalize 之後"
  show_versions "遷移後（第 29 章）"
  expect_versions "$TARGET_CP" "$TARGET_C3" "$TARGET_JDK" "$BASE_OS" || exit 1
}
stage 22 "持續流量結果（第 29 章這一段）" && { on_ops 'bash install/tools/load.sh stop; bash install/tools/load.sh report'; }
stage 23 "26 license：status、schedule" && {
  step_on_ops 26-license.sh status; rc=$?; [ $rc = 0 ] || [ $rc = 2 ] || exit 1   # 試用版不到 90 天是 rc 2
  step_on_ops 26-license.sh schedule || exit 1
}
stage 24 "23 日常備份：grant、run、schedule、compare" && {
  step_on_ops 23-metadata-backup.sh grant && step_on_ops 23-metadata-backup.sh run || exit 1
  sleep 61; step_on_ops 23-metadata-backup.sh schedule && step_on_ops 23-metadata-backup.sh compare || exit 1
}
stage 25 "25.1 換 controller（kc03 清空重建）" && { step_on_ops 25-1-controller-replace.sh replace kc03 || exit 1; }
stage 26 "25.2 broker 縮減與擴充（kb04）" && { step_on_ops 25-2-broker-scale.sh remove kb04 && step_on_ops 25-2-broker-scale.sh add kb04 || exit 1; }
stage 27 "30 OS 小版本更新 9.6 → 9.8：銀行套件庫同步、plan、apply、verify（lab 不能真的重開機）" && {
  on_ops 'bash install/tools/load.sh start' || exit 1
  $BANK os-sync || exit 1
  step_on_ops 30-os-patch.sh plan || exit 1
  step_on_ops 30-os-patch.sh apply || exit 1
  step_on_ops 30-os-patch.sh verify "$TARGET_OS" || exit 1
  on_ops 'bash install/tools/load.sh stop; bash install/tools/load.sh report'
  acceptance "OS 9.8"
  show_versions "OS 更新後（第 30 章）"
  expect_versions "$TARGET_CP" "$TARGET_C3" "$TARGET_JDK" "$TARGET_OS" || exit 1
}
stage 28 "31 C3：帶進 2.6.0、退回、升回 2.6.1（回滾程序；2.6.x 都支援 CP 8.3）" && {
  bring_in_c3_drill_version || exit 1
  step_on_ops 29-upgrade.sh publish c3 || exit 1
  step_on_ops 29-upgrade.sh c3 2.6.0 && step_on_ops 29-upgrade.sh c3 "$TARGET_C3" || exit 1
}
stage 29 "19 驗收（全部做完）" && { acceptance "全部做完"; install_on_ops --list; }
# TO= 讓最後幾段被略過時，最後一個 stage 會回 1；走到這裡就是成功
exit 0
