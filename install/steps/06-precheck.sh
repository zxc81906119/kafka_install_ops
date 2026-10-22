#!/usr/bin/env bash
# 第 6 站：安裝前檢查 —— 主機事實、時鐘、DNS/套件庫/AD、主機乾淨。每一項不符都是先回頭找銀行的事
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"

section "主機基本事實（/tmp 不能 noexec、至少 2 GB）"
for h in $ALL_HOSTS; do
  r=$(rsh "$h" 'printf "%s cpu=%s mem=%sMB tmp_free=%sMB tmp_noexec=%s\n" "$(. /etc/os-release; echo $ID-$VERSION_ID)" "$(nproc)" "$(free -m | awk "/Mem:/{print \$2}")" "$(df -m /tmp | awk "NR==2{print \$4}")" "$(findmnt -no OPTIONS /tmp | grep -c noexec)"')
  free_mb=$(sed -n 's/.*tmp_free=\([0-9]*\)MB.*/\1/p' <<<"$r"); noexec=${r##*tmp_noexec=}
  [ "$noexec" = 0 ] && [ "${free_mb:-0}" -ge 2000 ] && ok "$h $r" || fail "$h $r（/tmp 要可執行且 ≥ 2000 MB）"
done

section "時鐘誤差（TLS 與 MDS token 要求 2 秒內）"
for h in $CLUSTER_HOSTS; do
  skew=$(( $(rsh "$h" date +%s) - $(date +%s) )); [ "${skew#-}" -le 2 ] && ok "$h skew=${skew}s" || fail "$h skew=${skew}s"
done

section "DNS、套件庫、AD 連線"
for h in $ALL_HOSTS; do
  r=$(rsh "$h" 'bad=""; for n in '"$ALL_HOSTS $REPO_HOST $AD_HOST $LB_HOST"'; do getent hosts $n.'"$DOMAIN"' >/dev/null || bad="$bad $n"; done; echo "${bad:-all resolved} os=$(curl -s -o /dev/null -m 10 -w %{http_code} '"$REPO_URL"'/os/repodata/repomd.xml) confluent=$(curl -s -o /dev/null -m 10 -w %{http_code} '"$REPO_URL"'/confluent/repodata/repomd.xml)"')
  [ "$r" = "all resolved os=200 confluent=200" ] && ok "$h: $r" || fail "$h: $r"
done
for h in $BROKERS; do
  r=$(rsh "$h" "openssl s_client -connect $AD_FQDN:$AD_LDAPS_PORT </dev/null 2>/dev/null | grep 'Verify return code'")
  [[ $r == *"0 (ok)"* ]] && ok "$h: LDAPS $r" || fail "$h: LDAPS ${r:-連不上}"
done

section "主機是乾淨的（已經裝過的話只警告，讓重跑能過）"
for h in $CLUSTER_HOSTS; do
  r=$(rsh "$h" 'echo "confluent_pkgs=$(rpm -qa "confluent-*" | wc -l) data_dir=$([ -e /var/lib/kafka ] && echo exists || echo none)"')
  [ "$r" = "confluent_pkgs=0 data_dir=none" ] && ok "$h: $r" || warn "$h: $r（不是全新主機）"
done
finish
