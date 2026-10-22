#!/usr/bin/env bash
# 第 7 站：OS 調校 —— sysctl、limits、THP、時區/journald、chrony、firewalld（叢集 10 台；操作機只做時間同步與時區）
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"

role_of() { case $1 in kc*) echo controller;; kb*) echo broker;; rest*) echo rest;; c3*) echo c3;; *) echo other;; esac; }

section "核心參數（lab 容器裡 broker 的 net.core.*mem_max 設不進去，errors=2 正常；VM 上是 0）"
for h in $CLUSTER_HOSTS; do
  case $(role_of "$h") in
    controller) extra="vm.max_map_count = 262144";;
    broker) extra=$'vm.max_map_count = 262144\nvm.swappiness = 1\nvm.dirty_background_ratio = 5\nvm.dirty_ratio = 60\nnet.core.rmem_max = 2097152\nnet.core.wmem_max = 2097152\nnet.ipv4.tcp_rmem = 4096 65536 2097152\nnet.ipv4.tcp_wmem = 4096 65536 2097152';;
    *) extra="";;
  esac
  r=$(printf '# Confluent Platform\nnet.core.somaxconn = 4096\nnet.ipv4.tcp_max_syn_backlog = 4096\n%s\n' "$extra" | rsh "$h" 'sudo install -d -m 0755 /etc/sysctl.d && sudo tee /etc/sysctl.d/90-confluent.conf >/dev/null && sudo sysctl -q --system 2>&1 | grep -c "sysctl:"')
  ok "$h: sysctl errors=${r:-0}"
done

section "程序限制、THP（controller/broker）、時區、journald"
for h in $CLUSTER_HOSTS; do
  rsh "$h" 'printf "@confluent soft nofile 128000\n@confluent hard nofile 128000\n@confluent soft nproc 65536\n@confluent hard nproc 65536\n" | sudo tee /etc/security/limits.d/90-confluent.conf >/dev/null' && ok "$h: limits" || fail "$h: limits"
done
for h in $KAFKA_HOSTS; do
  rsh "$h" 'sudo tee /etc/systemd/system/disable-thp.service >/dev/null' < "$D/templates/disable-thp.service" && rsh "$h" 'sudo systemctl daemon-reload && sudo systemctl enable disable-thp.service >/dev/null 2>&1; echo ok' >/dev/null && ok "$h: thp unit enabled" || fail "$h: thp unit"
done
for h in $ALL_HOSTS; do
  r=$(rsh "$h" 'sudo ln -sfn /usr/share/zoneinfo/Asia/Taipei /etc/localtime && sudo install -d /etc/systemd/journald.conf.d && printf "[Journal]\nSystemMaxUse=1G\n" | sudo tee /etc/systemd/journald.conf.d/90-confluent.conf >/dev/null && sudo systemctl restart systemd-journald && date +%Z')
  [ "$r" = CST ] && ok "$h: tz=$r journald 1G" || fail "$h: $r"
done

section "時間同步（指向 $NTP_SERVER）"
for h in $ALL_HOSTS; do
  rsh "$h" "sudo dnf -q -y install chrony >/dev/null && printf 'server $NTP_SERVER iburst\ndriftfile /var/lib/chrony/drift\nmakestep 1.0 3\nrtcsync\n' | sudo tee /etc/chrony.conf >/dev/null && sudo systemctl enable --now chronyd >/dev/null 2>&1; sudo systemctl restart chronyd" && ok "$h: chrony configured" || fail "$h: chrony"
done
sleep 10
for h in $ALL_HOSTS; do
  r=$(rsh "$h" 'chronyc sources 2>/dev/null | grep "^\^\*" | awk "{print \$2, \$7}"'); [ -n "$r" ] && ok "$h: $r" || fail "$h: chrony 還沒選定來源"
done

section "主機防火牆（只開這台元件需要的埠）"
for h in $CLUSTER_HOSTS; do
  case $(role_of "$h") in controller) p="9093 7071";; broker) p="9092 9094 9095 9096 8090 7071";; rest) p="8082 7071";; c3) p="9021 9090";; esac
  r=$(rsh "$h" "sudo dnf -q -y install firewalld >/dev/null && sudo systemctl enable --now firewalld >/dev/null 2>&1; for s in cockpit dhcpv6-client; do sudo firewall-cmd -q --permanent --remove-service=\$s 2>/dev/null; done; for x in $p; do sudo firewall-cmd -q --permanent --add-port=\$x/tcp; done; sudo firewall-cmd -q --reload && sudo firewall-cmd --list-ports")
  want=$(for x in $p; do echo "$x/tcp"; done | sort | paste -sd' '); have=$(tr ' ' '\n' <<<"$r" | sort | paste -sd' ')
  [ "$have" = "$want" ] && ok "$h: $r" || fail "$h: 開的埠 [$r] 和預期 [$want] 不同"
done
finish
