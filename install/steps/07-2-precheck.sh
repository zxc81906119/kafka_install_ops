#!/usr/bin/env bash
# 7.2 節：安裝前檢查 —— 主機事實、資料碟、時鐘、DNS/套件庫/AD、主機乾淨。每一項不符都是先回頭找銀行的事
# where: ops02 （root）
#
# 做什麼：只讀不寫的檢查。/tmp 要可執行且 ≥ 2 GB、資料碟是 XFS 或 ext4、時鐘差 ≤ 2 秒、每台都解析得到所有主機名、
#         兩個套件庫都回 200、broker 驗得過 AD 的 LDAPS 憑證、叢集主機沒裝過 Confluent。
# 需要：第 4、5、6 站做完（套件庫要已上架，confluent=200 才會過）。
# 產出：無（只讀）。
# 重跑：安全。「主機不是全新的」只警告（讓整套可以重跑）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

section "主機基本事實（/tmp 不能 noexec、至少 2 GB）"
for host in $ALL_HOSTS; do
  # 1. 那台主機印一行事實
  facts=$(ssh_script "$host" <<'EOF'
. /etc/os-release
mem=$(free -m | awk '/Mem:/{print $2}')
tmp_free=$(df -m /tmp | awk 'NR==2{print $4}')
tmp_noexec=$(findmnt -no OPTIONS /tmp | awk '/noexec/ {c++} END {print c + 0}')
echo "$ID-$VERSION_ID cpu=$(nproc) mem=${mem}MB tmp_free=$tmp_free tmp_noexec=$tmp_noexec"
EOF
)

  # 2. 取出要判斷的兩個值。例：rocky-9.6 cpu=8 mem=10953MB tmp_free=2048 tmp_noexec=0 → 2048、0
  tmp_free_mb=$(grep -o 'tmp_free=[0-9]*' <<<"$facts" | cut -d= -f2)
  tmp_noexec=${facts##*tmp_noexec=}

  if [ "$tmp_noexec" = 0 ] && [ "${tmp_free_mb:-0}" -ge 2000 ]; then
    ok "$host $facts"
  else
    fail "$host $facts（/tmp 要可執行且 ≥ 2000 MB）"
  fi
done

section "資料碟的檔案系統（原廠只支援 XFS、ext4；資料碟要掛在 /var/lib/kafka）"
for host in $KAFKA_HOSTS; do
  # 1. 那台主機印一行。資料碟掛好了就是 /var/lib/kafka；還沒掛（目錄還不存在）就看 /var/lib
  disk_facts=$(ssh_script "$host" <<'EOF'
dir=/var/lib/kafka

if [ ! -e "$dir" ]; then
  dir=/var/lib
fi

fstype=$(df -T "$dir" | awk 'NR==2{print $2}')
free_gb=$(df -BG --output=avail "$dir" | tail -1 | tr -dc 0-9)
echo "$dir fstype=$fstype free=${free_gb}GB"
EOF
)

  # 2. 取出檔案系統。例：/var/lib fstype=overlay free=712GB → overlay
  fstype=$(grep -o 'fstype=[^ ]*' <<<"$disk_facts" | cut -d= -f2)

  case $fstype in
    xfs|ext4)
      ok "$host: $disk_facts"
      ;;
    overlay)
      warn "$host: $disk_facts（lab 的容器才會是 overlay；正式環境要是 xfs 或 ext4）"
      ;;
    *)
      fail "$host: ${disk_facts:-連不上}（要是 xfs 或 ext4）"
      ;;
  esac
done

section "時鐘誤差（TLS 與 MDS token 要求 2 秒內）"
for host in $CLUSTER_HOSTS; do
  remote_time=$(ssh_run "$host" date +%s)
  local_time=$(date +%s)
  skew_seconds=$(( remote_time - local_time ))

  if [ "${skew_seconds#-}" -le 2 ]; then
    ok "$host skew=${skew_seconds}s"
  else
    fail "$host skew=${skew_seconds}s"
  fi
done

section "DNS（用系統解析順序 getent，和程式連線時一樣）、兩個套件庫"
for host in $ALL_HOSTS; do
  result=$(ssh_script "$host" NAMES="$ALL_HOSTS $REPO_HOST $AD_HOST $LB_HOST" \
             DOMAIN="$DOMAIN" REPO_URL="$REPO_URL" <<'EOF'
# 1. 解析不到的主機名稱列出來；全部解析得到就印 all resolved
unresolved=""

for name in $NAMES; do
  if ! getent hosts "$name.$DOMAIN" >/dev/null; then
    unresolved="$unresolved $name"
  fi
done

# 2. 兩個套件庫的索引都拿得到（200）
os_repo=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$REPO_URL/os/repodata/repomd.xml")
confluent_repo=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$REPO_URL/confluent/repodata/repomd.xml")

echo "${unresolved:-all resolved} os=$os_repo confluent=$confluent_repo"
EOF
)

  if [ "$result" = "all resolved os=200 confluent=200" ]; then
    ok "$host: $result"
  else
    fail "$host: $result"
  fi
done

section "broker 驗得過 AD 的 LDAPS 憑證（MDS 要連 AD）"
for host in $BROKERS; do
  ldaps_verify=$(ssh_script "$host" AD_ADDRESS="$AD_FQDN:$AD_LDAPS_PORT" <<'EOF'
openssl s_client -connect "$AD_ADDRESS" </dev/null 2>/dev/null | grep 'Verify return code'
EOF
)

  case $ldaps_verify in
    *"0 (ok)"*)
      ok "$host: LDAPS $ldaps_verify"
      ;;
    *)
      fail "$host: LDAPS ${ldaps_verify:-連不上}"
      ;;
  esac
done

section "主機是乾淨的"
for host in $CLUSTER_HOSTS; do
  result=$(ssh_script "$host" <<'EOF'
packages=$(rpm -qa 'confluent-*' | wc -l)

if [ -e /var/lib/kafka ]; then
  data_dir=exists
else
  data_dir=none
fi

echo "confluent_pkgs=$packages data_dir=$data_dir"
EOF
)

  if [ "$result" = "confluent_pkgs=0 data_dir=none" ]; then
    ok "$host: $result"
  else
    warn "$host: $result（不是全新主機）"
  fi
done

finish_step
