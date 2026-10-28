#!/usr/bin/env bash
# 7.1 節：JDK（安裝基底 JDK_MAJOR，預設 21） —— 銀行給的 tar 解到 /opt/java/<版本>，/opt/java/current 指過去，alternatives + profile.d
# where: ops02 （root）
#
# 做什麼：所有設定一律寫 /opt/java/current，以後換版只改這個連結；java、keytool 用 alternatives 登記（RHEL 標準做法）；
#         /etc/profile.d/java.sh 設 JAVA_HOME（服務的 systemd drop-in 另外再寫一次，不受全域切換影響）。
# 需要：$LANDING/bank/ 裡的 JDK tar 與 .sha256（銀行交付，第 5 站已確認）。
# 重跑：安全（已解過的版本目錄不重解）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

section "壓縮檔與頂層目錄"
# bank/ 裡有基底（21）與遷移目標（25，第 29 章才用）兩個主版本，之後的 JDK 修補也放這裡：只挑 JDK_MAJOR 的，依版本號排序挑最新的
JDK_TAR=$(ls "$LANDING"/bank/OpenJDK"${JDK_MAJOR}"U-jdk_x64_linux_hotspot_*.tar.gz 2>/dev/null | sort -V | tail -1)
[ -n "$JDK_TAR" ] || die "$LANDING/bank 裡沒有 JDK tar"
(cd "$LANDING/bank" && sha256sum -c --quiet "$(basename "$JDK_TAR").sha256") || die "JDK sha256 不符"
JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1)   # 例如 jdk-21.0.13+9
ok "tar=$(basename "$JDK_TAR") dir=$JDK_DIR"

# 每台主機上要做的事（操作機本機與遠端共用這一段）。
# 參數：TAR = tar 的位置、DIR = 頂層目錄名；CLEANUP=1 時裝完刪掉 TAR（遠端 /tmp 的複本；落地區的原檔不能刪）
INSTALL_JDK=$(cat <<'EOF'
set -e
sudo install -d -m 0755 /opt/java
[ -d "/opt/java/$DIR" ] || sudo tar -xzf "$TAR" -C /opt/java
sudo chown -R root:root /opt/java
sudo ln -sfn "/opt/java/$DIR" /opt/java/current
sudo alternatives --install /usr/bin/java java /opt/java/current/bin/java 2100
sudo alternatives --install /usr/bin/keytool keytool /opt/java/current/bin/keytool 2100
sudo install -m 0644 /tmp/java.sh /etc/profile.d/java.sh
rm -f /tmp/java.sh
if [ "${CLEANUP:-0}" = 1 ]; then rm -f "$TAR"; fi
EOF
)

section "操作機本機"
install -m 0644 "$TEMPLATE_DIR/java.sh" /tmp/java.sh
if TAR=$JDK_TAR DIR=$JDK_DIR bash -c "$INSTALL_JDK"; then ok "$OPS_HOST: $(java -version 2>&1 | head -1)"
else die "操作機 JDK 安裝失敗"; fi

section "其他主機：${CLUSTER_HOSTS// /、}"
for host in $CLUSTER_HOSTS; do
  copy_to_tmp "$host" "$JDK_TAR" "$TEMPLATE_DIR/java.sh" || { fail "$host: scp 失敗"; continue; }
  if ssh_script "$host" TAR="/tmp/$(basename "$JDK_TAR")" DIR="$JDK_DIR" CLEANUP=1 <<<"$INSTALL_JDK"; then ok "$host: done"
  else fail "$host: 安裝失敗"; fi
done

section "驗證：java 在 PATH（alternatives）、ssh 進去讀得到 JAVA_HOME（profile.d）"
for host in $ALL_HOSTS; do
  result=$(ssh_script "$host" <<'EOF'
echo "$(java -version 2>&1 | head -1) JAVA_HOME=$JAVA_HOME"
EOF
)
  case $result in
    *"version \"$JDK_MAJOR"*"JAVA_HOME=/opt/java/current") ok "$host: $result";;
    *) fail "$host: $result";;
  esac
done
finish_step
