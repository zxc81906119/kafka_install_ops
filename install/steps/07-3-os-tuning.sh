#!/usr/bin/env bash
# 7.3 節：OS 調校 —— sysctl、limits、THP、時區/journald、chrony、firewalld
# where: ops02 （root）
#
# 做什麼：叢集 10 台做全部；操作機只做時區、journald、時間同步。
#         核心參數的值在 templates/sysctl-<角色>.conf，要調就改那幾個檔。沒有服務會被重啟。
# 需要：第 4、5 站做完（OS 套件庫裝得到 chrony、firewalld；行內 NTP 可用）。
# 產出：每台的 /etc/sysctl.d/90-confluent.conf、/etc/security/limits.d/90-confluent.conf、disable-thp.service、
#       /etc/systemd/journald.conf.d/90-confluent.conf、/etc/chrony.conf、firewalld 的規則。
# 重跑：安全（都是覆蓋同樣內容）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

# role_of <主機>：這台的角色。例：role_of kb01 → broker
role_of() {
  case $1 in
    kc*)
      echo controller
      ;;
    kb*)
      echo broker
      ;;
    rest*)
      echo rest
      ;;
    c3*)
      echo c3
      ;;
    *)
      echo other
      ;;
  esac
}

# ports_of <主機>：這台防火牆要開的埠。例：ports_of kc01 → 9093 7071
ports_of() {
  case $(role_of "$1") in
    controller)
      echo "9093 7071"                       # controller 之間與 broker；JMX exporter
      ;;
    broker)
      echo "9092 9094 9095 9096 8090 7071"   # INTERNAL TOKEN CLIENT LDAP MDS；JMX exporter
      ;;
    rest)
      echo "8082 7071"                       # 負載平衡；JMX exporter
      ;;
    c3)
      echo "9021 9090 7071"                  # 瀏覽器；C3 自己的 Prometheus；JMX exporter
      ;;
  esac
}

# sorted_port_list <空白分隔的清單>：排好順序再用一個空白隔開，用來比較
#   例：sorted_port_list "9093/tcp 7071/tcp" → 7071/tcp 9093/tcp
sorted_port_list() {
  tr ' ' '\n' <<<"$1" | sort | paste -sd' '
}

section "核心參數（lab 是容器：broker 的 net.core.*mem_max 設不進去，errors=2 正常；VM 上是 0）"
for host in $CLUSTER_HOSTS; do
  # 1. 這個角色的參數檔（REST Proxy、C3 共用 sysctl-other.conf）
  sysctl_file=$TEMPLATE_DIR/sysctl-$(role_of "$host").conf

  if [ ! -f "$sysctl_file" ]; then
    sysctl_file=$TEMPLATE_DIR/sysctl-other.conf
  fi

  if ! copy_to_tmp "$host" "$sysctl_file"; then
    fail "$host: scp"
    continue
  fi

  # 2. 在那台放好、套用，數有幾個設不進去
  error_count=$(ssh_script "$host" FILE="/tmp/$(basename "$sysctl_file")" <<'EOF'
sudo install -d -m 0755 /etc/sysctl.d

if sudo install -m 0644 "$FILE" /etc/sysctl.d/90-confluent.conf; then
  rm -f "$FILE"
fi

sudo sysctl -q --system 2>&1 | awk '/sysctl:/ {count++} END {print count + 0}'
EOF
)

  ok "$host: $(basename "$sysctl_file") 套用，errors=${error_count:-0}"
done

section "程序限制（confluent 群組的 nofile／nproc）"
for host in $CLUSTER_HOSTS; do
  if ssh_script "$host" <<'EOF'
sudo tee /etc/security/limits.d/90-confluent.conf >/dev/null <<'CONF'
@confluent soft nofile 128000
@confluent hard nofile 128000
@confluent soft nproc 65536
@confluent hard nproc 65536
CONF
EOF
  then
    ok "$host: limits"
  else
    fail "$host: limits"
  fi
done

section "關閉 THP 的開機單元（controller／broker；容器裡由 systemd 自動略過）"
for host in $KAFKA_HOSTS; do
  if ! copy_to_tmp "$host" "$TEMPLATE_DIR/disable-thp.service"; then
    fail "$host: scp"
    continue
  fi

  if ssh_script "$host" <<'EOF'
if sudo install -m 0644 /tmp/disable-thp.service /etc/systemd/system/disable-thp.service; then
  rm -f /tmp/disable-thp.service
fi

sudo systemctl daemon-reload
sudo systemctl enable disable-thp.service >/dev/null 2>&1
EOF
  then
    ok "$host: thp unit enabled"
  else
    fail "$host: thp unit"
  fi
done

section "時區、journald 上限 1G（全部含操作機）"
for host in $ALL_HOSTS; do
  timezone=$(ssh_script "$host" <<'EOF'
# 1. 時區
sudo ln -sfn /usr/share/zoneinfo/Asia/Taipei /etc/localtime

# 2. journald 最多用 1 GB
sudo install -d /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=1G\n' | sudo tee /etc/systemd/journald.conf.d/90-confluent.conf >/dev/null
sudo systemctl restart systemd-journald

date +%Z
EOF
)

  if [ "$timezone" = CST ]; then
    ok "$host: tz=$timezone journald 1G"
  else
    fail "$host: $timezone"
  fi
done

section "時間同步（chrony 指向 $NTP_SERVER）"
for host in $ALL_HOSTS; do
  if ssh_script "$host" NTP="$NTP_SERVER" <<'EOF'
if ! sudo dnf -q -y install chrony >/dev/null; then
  exit 1
fi

printf 'server %s iburst\ndriftfile /var/lib/chrony/drift\nmakestep 1.0 3\nrtcsync\n' "$NTP" | sudo tee /etc/chrony.conf >/dev/null
sudo systemctl enable --now chronyd >/dev/null 2>&1
sudo systemctl restart chronyd
EOF
  then
    ok "$host: chrony configured"
  else
    fail "$host: chrony"
  fi
done

sleep 10   # 等 chrony 選定來源

for host in $ALL_HOSTS; do
  # chronyc sources 裡 ^* 開頭那一行的第 2 欄（來源名稱）。後面的欄位在 "[ " 有空格時會位移，不要取
  #   例：^* repo01.poc.lab  10  6  17  12  +3us[ +5us] +/- 40us → repo01.poc.lab
  selected_source=$(ssh_script "$host" <<'EOF'
chronyc sources 2>/dev/null | awk '/^\^\*/ {print $2}'
EOF
)

  if [ -n "$selected_source" ]; then
    ok "$host: $selected_source"
  else
    fail "$host: chrony 還沒選定來源"
  fi
done

section "主機防火牆（只開這台元件需要的埠，關掉預設的 cockpit、dhcpv6-client）"
for host in $CLUSTER_HOSTS; do
  wanted_ports=$(ports_of "$host")

  # 1. 在那台設定，印出開了哪些埠
  open_ports=$(ssh_script "$host" PORTS="$wanted_ports" <<'EOF'
if ! sudo dnf -q -y install firewalld >/dev/null; then
  exit 1
fi

sudo systemctl enable --now firewalld >/dev/null 2>&1

for service in cockpit dhcpv6-client; do
  sudo firewall-cmd -q --permanent --remove-service=$service 2>/dev/null
done

for port in $PORTS; do
  sudo firewall-cmd -q --permanent --add-port=$port/tcp
done

sudo firewall-cmd -q --reload
sudo firewall-cmd --list-ports
EOF
)

  # 2. 和要開的比對。每個埠加上 /tcp 再排序，例：9093 7071 → 7071/tcp 9093/tcp
  wanted_with_protocol=$(sed -E 's/([0-9]+)/\1\/tcp/g' <<<"$wanted_ports")
  expected=$(sorted_port_list "$wanted_with_protocol")
  actual=$(sorted_port_list "$open_ports")

  if [ "$actual" = "$expected" ]; then
    ok "$host: $open_ports"
  else
    fail "$host: 開的埠 [$open_ports] 和預期 [$expected] 不同"
  fi
done

finish_step
