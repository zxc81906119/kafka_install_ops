#!/usr/bin/env bash
# 第 8 站：安裝 Confluent 套件 —— 原廠公鑰、內部 repo 設定、依角色 dnf install、versionlock
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"

section "每台放原廠公鑰、寫 repo 設定（gpgcheck=1）"
for h in $ALL_HOSTS; do
  rcp "$h" "$LANDING/gpg-keys/confluent.asc" "$LANDING/gpg-keys/confluent-c3.asc" || { fail "$h: scp"; continue; }
  r=$(rsh "$h" "sudo install -m 0644 /tmp/confluent.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent && sudo install -m 0644 /tmp/confluent-c3.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3 && rm -f /tmp/confluent*.asc && sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent /etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3 && printf '[confluent-internal]\nname=Confluent Platform (internal repository)\nbaseurl=$REPO_URL/confluent/\nenabled=1\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-confluent\n       file:///etc/pki/rpm-gpg/RPM-GPG-KEY-confluent-c3\n' | sudo tee /etc/yum.repos.d/confluent-internal.repo >/dev/null && echo \"\$(dnf -q repolist | grep -c confluent-internal) repo, \$(rpm -q gpg-pubkey --qf '%{SUMMARY}\n' | grep -ci confluent) keys\"")
  [ "$r" = "1 repo, 1 keys" ] && ok "$h: $r" || fail "$h: $r"
done

section "依元件安裝（每台約一兩分鐘；C3 多裝兩個 OS 前置套件，從銀行套件庫來）"
pkgs_of() {
  case $1 in
    kc*|kb*) echo "confluent-server-$CP_VERSION confluent-security-$CP_VERSION";;
    rest*)   echo "confluent-kafka-rest-$CP_VERSION confluent-security-$CP_VERSION";;
    c3*)     echo "confluent-control-center-next-gen-$C3_VERSION cyrus-sasl openssl-devel";;
    *)       echo "confluent-server-$CP_VERSION confluent-security-$CP_VERSION confluent-cli-$CP_VERSION";;   # 操作機：多 CLI
  esac
}
for h in $CLUSTER_HOSTS $OPS_HOST; do
  p=$(pkgs_of "$h")
  r=$(rsh "$h" "sudo dnf -q -y --setopt=install_weak_deps=False install $p >/dev/null && rpm -qa 'confluent-*' | wc -l") && ok "$h: $r confluent packages" || fail "$h: dnf install $p 失敗"
done

section "鎖版本（只鎖 Confluent；C3 的 cyrus-sasl、openssl-devel 跟著 OS 修補）"
for h in $ALL_HOSTS; do
  r=$(rsh "$h" 'sudo dnf -q -y install python3-dnf-plugin-versionlock >/dev/null && for p in $(rpm -qa "confluent-*"); do sudo dnf -q versionlock add "$p" >/dev/null; done; echo "$(sudo dnf -q versionlock list | grep -c confluent) locked / $(rpm -qa "confluent-*" | wc -l) installed"')
  [ "$(awk '{print $1}' <<<"$r")" = "$(awk '{print $4}' <<<"$r")" ] && ok "$h: $r" || fail "$h: $r"
done

section "RPM 建的服務帳號與群組"
for h in $BROKERS $RESTS $C3_HOST; do
  r=$(rsh "$h" 'echo "$(getent passwd cp-kafka cp-kafka-rest cp-control-center 2>/dev/null | cut -d: -f1 | paste -sd,) group=$(getent group confluent | cut -d: -f1) kafka_pkg=$(rpm -q confluent-server >/dev/null 2>&1 && echo yes || echo no)"')
  case $h in kb*) want=yes;; *) want=no;; esac
  [[ $r == *"group=confluent"* && $r == *"kafka_pkg=$want" ]] && ok "$h: $r" || fail "$h: $r"
done
finish
