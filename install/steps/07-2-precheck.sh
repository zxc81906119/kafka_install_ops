#!/usr/bin/env bash
# 7.2 節：安裝前檢查 —— 主機事實、時鐘、DNS/套件庫/AD、主機乾淨。每一項不符都是先回頭找銀行的事
# where: ops02 （root）
#
# 做什麼：只讀不寫的檢查。/tmp 要可執行且 ≥ 2 GB、時鐘差 ≤ 2 秒、每台都解析得到所有主機名、
#         兩個套件庫都回 200、broker 驗得過 AD 的 LDAPS 憑證、叢集主機沒裝過 Confluent。
# 重跑：安全。「主機不是全新的」只警告（讓整套可以重跑）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

section "主機基本事實（/tmp 不能 noexec、至少 2 GB）"
for host in $ALL_HOSTS; do
  facts=$(ssh_script "$host" <<'EOF'
. /etc/os-release
echo "$ID-$VERSION_ID cpu=$(nproc) mem=$(free -m | awk '/Mem:/{print $2}')MB tmp_free=$(df -m /tmp | awk 'NR==2{print $4}') tmp_noexec=$(findmnt -no OPTIONS /tmp | grep -c noexec)"
EOF
)
  tmp_free_mb=$(sed -n 's/.*tmp_free=\([0-9]*\).*/\1/p' <<<"$facts")
  tmp_noexec=${facts##*tmp_noexec=}
  if [ "$tmp_noexec" = 0 ] && [ "${tmp_free_mb:-0}" -ge 2000 ]; then ok "$host $facts"
  else fail "$host $facts（/tmp 要可執行且 ≥ 2000 MB）"; fi
done

section "時鐘誤差（TLS 與 MDS token 要求 2 秒內）"
for host in $CLUSTER_HOSTS; do
  skew_seconds=$(( $(ssh_run "$host" date +%s) - $(date +%s) ))
  if [ "${skew_seconds#-}" -le 2 ]; then ok "$host skew=${skew_seconds}s"; else fail "$host skew=${skew_seconds}s"; fi
done

section "DNS（用系統解析順序 getent，和程式連線時一樣）、兩個套件庫"
for host in $ALL_HOSTS; do
  result=$(ssh_script "$host" NAMES="$ALL_HOSTS $REPO_HOST $AD_HOST $LB_HOST" DOMAIN="$DOMAIN" REPO_URL="$REPO_URL" <<'EOF'
unresolved=""
for name in $NAMES; do getent hosts "$name.$DOMAIN" >/dev/null || unresolved="$unresolved $name"; done
os_repo=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$REPO_URL/os/repodata/repomd.xml")
confluent_repo=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$REPO_URL/confluent/repodata/repomd.xml")
echo "${unresolved:-all resolved} os=$os_repo confluent=$confluent_repo"
EOF
)
  if [ "$result" = "all resolved os=200 confluent=200" ]; then ok "$host: $result"; else fail "$host: $result"; fi
done

section "broker 驗得過 AD 的 LDAPS 憑證（MDS 要連 AD）"
for host in $BROKERS; do
  ldaps_verify=$(ssh_script "$host" AD_ADDRESS="$AD_FQDN:$AD_LDAPS_PORT" <<'EOF'
openssl s_client -connect "$AD_ADDRESS" </dev/null 2>/dev/null | grep 'Verify return code'
EOF
)
  case $ldaps_verify in *"0 (ok)"*) ok "$host: LDAPS $ldaps_verify";; *) fail "$host: LDAPS ${ldaps_verify:-連不上}";; esac
done

section "主機是乾淨的"
for host in $CLUSTER_HOSTS; do
  result=$(ssh_script "$host" <<'EOF'
echo "confluent_pkgs=$(rpm -qa 'confluent-*' | wc -l) data_dir=$([ -e /var/lib/kafka ] && echo exists || echo none)"
EOF
)
  if [ "$result" = "confluent_pkgs=0 data_dir=none" ]; then ok "$host: $result"; else warn "$host: $result（不是全新主機）"; fi
done
finish_step
