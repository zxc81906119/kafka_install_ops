#!/usr/bin/env bash
# 第 8 站：安裝 Confluent 套件 —— 原廠公鑰、內部 repo 設定、依角色 dnf install、versionlock
# where: ops02 （cpadmin）
#
# 做什麼：每台放原廠公鑰與指向內部套件庫的 .repo（gpgcheck=1）→ 依角色安裝 → 只鎖 Confluent 的版本
#         → 確認 RPM 建好了服務帳號與 confluent 群組。
# 重跑：安全。dnf 看到已安裝就略過；versionlock 只加還沒鎖的（重複 add 會多一筆，比對就不準了）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

# 每台要裝的套件（dnf 會自動帶入 confluent-common 等相依）
packages_of() {
  case $1 in
    kc*|kb*) echo "confluent-server-$CP_VERSION confluent-security-$CP_VERSION";;
    rest*)   echo "confluent-kafka-rest-$CP_VERSION confluent-security-$CP_VERSION";;
    c3*)     echo "confluent-control-center-next-gen-$C3_VERSION cyrus-sasl openssl-devel";;   # 後兩個是原廠要求的 OS 前置套件
    *)       echo "confluent-server-$CP_VERSION confluent-security-$CP_VERSION confluent-cli-$CP_VERSION";;   # 操作機：多 CLI
  esac
}

section "每台放原廠公鑰、寫內部 repo 設定"
for host in $ALL_HOSTS; do
  copy_to_tmp "$host" "$LANDING/gpg-keys/confluent.asc" "$LANDING/gpg-keys/confluent-c3.asc" || { fail "$host: scp"; continue; }
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
echo "$(dnf -q repolist | grep -c confluent-internal) repo, $(rpm -q gpg-pubkey --qf '%{SUMMARY}\n' | grep -ci confluent) keys"
EOF
)
  # 兩個 .asc 其實是同一把公鑰，所以 1 keys 是對的
  if [ "$result" = "1 repo, 1 keys" ]; then ok "$host: $result"; else fail "$host: $result"; fi
done

section "依角色安裝（每台約一兩分鐘；install_weak_deps=False 只裝真正需要的）"
for host in $CLUSTER_HOSTS $OPS_HOST; do
  packages=$(packages_of "$host")
  package_count=$(ssh_script "$host" PACKAGES="$packages" <<'EOF'
sudo dnf -q -y --setopt=install_weak_deps=False install $PACKAGES >/dev/null || exit 1
rpm -qa 'confluent-*' | wc -l
EOF
)
  if [ -n "$package_count" ]; then ok "$host: $package_count 個 confluent 套件"; else fail "$host: dnf install $packages 失敗"; fi
done

section "鎖版本（只鎖 Confluent；C3 的 cyrus-sasl、openssl-devel 跟著 OS 修補）"
for host in $ALL_HOSTS; do
  result=$(ssh_script "$host" <<'EOF'
sudo dnf -q -y install python3-dnf-plugin-versionlock >/dev/null
already_locked=$(sudo dnf -q versionlock list)
for package in $(rpm -qa 'confluent-*'); do
  package_name=${package%-*-*}                     # confluent-server-8.3.2-1.noarch → confluent-server
  grep -q "^$package_name-[0-9]*:" <<<"$already_locked" || sudo dnf -q versionlock add "$package" >/dev/null
done
echo "$(sudo dnf -q versionlock list | grep -c confluent) $(rpm -qa 'confluent-*' | wc -l)"
EOF
)
  read -r locked_count installed_count <<<"$result"
  if [ -n "$locked_count" ] && [ "$locked_count" = "$installed_count" ]; then ok "$host: $locked_count locked / $installed_count installed"
  else fail "$host: ${locked_count:-?} locked / ${installed_count:-?} installed"; fi
done

section "RPM 建的服務帳號與群組（C3 主機不應該裝到 Kafka）"
for host in $BROKERS $RESTS $C3_HOST; do
  result=$(ssh_script "$host" <<'EOF'
users=$(getent passwd cp-kafka cp-kafka-rest cp-control-center 2>/dev/null | cut -d: -f1 | paste -sd,)
echo "$users group=$(getent group confluent | cut -d: -f1) kafka_pkg=$(rpm -q confluent-server >/dev/null 2>&1 && echo yes || echo no)"
EOF
)
  case $host in kb*) expect_kafka=yes;; *) expect_kafka=no;; esac
  case $result in *"group=confluent kafka_pkg=$expect_kafka") ok "$host: $result";; *) fail "$host: $result";; esac
done
finish_step
