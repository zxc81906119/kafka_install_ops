#!/usr/bin/env bash
# 第 8 站：安裝 Confluent 套件 —— 原廠公鑰、內部 repo 設定、依角色 dnf install、versionlock
# where: ops02 （root）
#
# 做什麼：每台放原廠公鑰與指向內部套件庫的 .repo（gpgcheck=1）→ 依角色安裝 → 只鎖 Confluent 的版本
#         → 確認 RPM 建好了服務帳號與 confluent 群組。
# 需要：第 6 站上架完成（套件庫此時只有安裝基底 CP_VERSION、C3_VERSION）。
# 產出：每台的 /etc/yum.repos.d/confluent-internal.repo、角色需要的 confluent 套件、versionlock。
# 重跑：安全。dnf 看到已安裝就略過；versionlock 只加還沒鎖的（重複 add 會多一筆，比對就不準了）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

# packages_of <主機>：每台要裝的套件（dnf 會自動帶入 confluent-common 等相依）
packages_of() {
  case $1 in
    kc*|kb*)
      echo "confluent-server-$CP_VERSION confluent-security-$CP_VERSION"
      ;;
    rest*)
      echo "confluent-kafka-rest-$CP_VERSION confluent-security-$CP_VERSION"
      ;;
    c3*)
      # 後兩個是原廠要求的 OS 前置套件
      echo "confluent-control-center-next-gen-$C3_VERSION cyrus-sasl openssl-devel"
      ;;
    *)
      # 操作機：多 CLI
      echo "confluent-server-$CP_VERSION confluent-security-$CP_VERSION confluent-cli-$CP_VERSION"
      ;;
  esac
}

section "每台放原廠公鑰、寫內部 repo 設定"
for host in $ALL_HOSTS; do
  # 1. 原廠公鑰送到那台的 /tmp
  if ! copy_to_tmp "$host" "$LANDING/gpg-keys/confluent.asc" "$LANDING/gpg-keys/confluent-c3.asc"; then
    fail "$host: scp"
    continue
  fi

  # 2. 在那台放公鑰、匯入、寫 repo 設定；印出看得到幾個 repo、幾把 Confluent 公鑰
  result=$(ssh_script "$host" REPO_URL="$REPO_URL" <<'EOF'
sudo install -m 0644 /tmp/confluent.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent
sudo install -m 0644 /tmp/confluent-c3.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3
rm -f /tmp/confluent.asc /tmp/confluent-c3.asc
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3

sudo tee /etc/yum.repos.d/confluent-internal.repo >/dev/null <<REPO
[confluent-internal]
name=Confluent Platform (internal repository)
baseurl=$REPO_URL/confluent/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-confluent
       file:///etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3
REPO

repos=$(dnf -q repolist | awk '/confluent-internal/ {c++} END {print c + 0}')
keys=$(rpm -q gpg-pubkey --qf '%{SUMMARY}\n' | awk 'tolower($0) ~ /confluent/ {c++} END {print c + 0}')
echo "$repos repo, $keys keys"
EOF
)

  # 兩個 .asc 其實是同一把公鑰，所以 1 keys 是對的
  if [ "$result" = "1 repo, 1 keys" ]; then
    ok "$host: $result"
  else
    fail "$host: $result"
  fi
done

section "依角色安裝（每台約一兩分鐘；install_weak_deps=False 只裝真正需要的）"
for host in $CLUSTER_HOSTS $OPS_HOST; do
  packages=$(packages_of "$host")

  package_count=$(ssh_script "$host" PACKAGES="$packages" <<'EOF'
if ! sudo dnf -q -y --setopt=install_weak_deps=False install $PACKAGES >/dev/null; then
  exit 1
fi

rpm -qa 'confluent-*' | wc -l
EOF
)

  if [ -n "$package_count" ]; then
    ok "$host: $package_count 個 confluent 套件"
  else
    fail "$host: dnf install $packages 失敗"
  fi
done

section "鎖版本（只鎖 Confluent；C3 的 cyrus-sasl、openssl-devel 跟著 OS 修補）"
for host in $ALL_HOSTS; do
  # 那台主機印一行：鎖了幾個 裝了幾個
  result=$(ssh_script "$host" <<'EOF'
sudo dnf -q -y install python3-dnf-plugin-versionlock >/dev/null

already_locked=$(sudo dnf -q versionlock list)

for package in $(rpm -qa 'confluent-*'); do
  package_name=${package%-*-*}                     # confluent-server-8.3.2-1.noarch → confluent-server

  if ! grep -q "^$package_name-[0-9]*:" <<<"$already_locked"; then
    sudo dnf -q versionlock add "$package" >/dev/null
  fi
done

locked=$(sudo dnf -q versionlock list | awk '/confluent/ {c++} END {print c + 0}')
installed=$(rpm -qa 'confluent-*' | wc -l)
echo "$locked $installed"
EOF
)

  locked_count=$(awk '{print $1}' <<<"$result")
  installed_count=$(awk '{print $2}' <<<"$result")

  if [ -n "$locked_count" ] && [ "$locked_count" = "$installed_count" ]; then
    ok "$host: $locked_count locked / $installed_count installed"
  else
    fail "$host: ${locked_count:-?} locked / ${installed_count:-?} installed"
  fi
done

section "RPM 建的服務帳號與群組（C3 主機不應該裝到 Kafka）"
for host in $BROKERS $RESTS $C3_HOST; do
  result=$(ssh_script "$host" <<'EOF'
users=$(getent passwd cp-kafka cp-kafka-rest cp-control-center 2>/dev/null | cut -d: -f1 | paste -sd,)
group=$(getent group confluent | cut -d: -f1)

if rpm -q confluent-server >/dev/null 2>&1; then
  kafka_pkg=yes
else
  kafka_pkg=no
fi

echo "$users group=$group kafka_pkg=$kafka_pkg"
EOF
)

  # 只有 broker 該有 confluent-server
  case $host in
    kb*)
      expect_kafka=yes
      ;;
    *)
      expect_kafka=no
      ;;
  esac

  case $result in
    *"group=confluent kafka_pkg=$expect_kafka")
      ok "$host: $result"
      ;;
    *)
      fail "$host: $result"
      ;;
  esac
done

finish_step
