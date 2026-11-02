#!/usr/bin/env bash
# 7.1 節：JDK（安裝基底 JDK_MAJOR，預設 21） —— 銀行給的 tar 解到 /opt/java/<版本>，/opt/java/current 指過去，alternatives + profile.d
# where: ops02 （root）
#
# 做什麼：所有設定一律寫 /opt/java/current，以後換版只改這個連結；java、keytool 用 alternatives 登記（RHEL 標準做法）；
#         /etc/profile.d/java.sh 設 JAVA_HOME（服務的 systemd drop-in 另外再寫一次，不受全域切換影響）。
# 需要：$LANDING/bank/ 裡的 JDK tar 與 .sha256（銀行交付，第 5 站已確認）。
# 產出：每台的 /opt/java/<版本>、/opt/java/current、/etc/profile.d/java.sh。
# 重跑：安全（已解過的版本目錄不重解）。
set -uo pipefail
source "$(dirname "$0")/../conf/site.env"
source "$INSTALL_DIR/lib/log.sh"
source "$INSTALL_DIR/lib/ssh.sh"

# jdk_checksum_ok <tar 的完整路徑>：用旁邊的 .sha256 核對（sha256sum 要在 bank/ 裡跑）
jdk_checksum_ok() {
  (
    if ! cd "$LANDING/bank"; then
      exit 1
    fi

    sha256sum -c --quiet "$(basename "$1").sha256"
  )
}

section "壓縮檔與頂層目錄"
# bank/ 裡有基底（21）與遷移目標（25，第 29 章才用）兩個主版本，之後的 JDK 修補也放這裡：只挑 JDK_MAJOR 的，依版本號排序挑最新的
JDK_TAR=$(ls "$LANDING"/bank/OpenJDK"${JDK_MAJOR}"U-jdk_x64_linux_hotspot_*.tar.gz 2>/dev/null | sort -V | tail -1)

if [ -z "$JDK_TAR" ]; then
  die "$LANDING/bank 裡沒有 JDK tar"
fi

if ! jdk_checksum_ok "$JDK_TAR"; then
  die "JDK sha256 不符"
fi

JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1)   # 例如 jdk-21.0.13+9
ok "tar=$(basename "$JDK_TAR") dir=$JDK_DIR"

# 每台主機上要做的事（操作機本機與遠端共用這一段）。
# 參數：TAR = tar 的位置、DIR = 頂層目錄名；CLEANUP=1 時裝完刪掉 TAR（遠端 /tmp 的複本；落地區的原檔不能刪）
INSTALL_JDK=$(cat <<'EOF'
set -e

# 1. 解到 /opt/java/<版本目錄>，/opt/java/current 指向它
sudo install -d -m 0755 /opt/java

if [ ! -d "/opt/java/$DIR" ]; then
  sudo tar -xzf "$TAR" -C /opt/java
fi

sudo chown -R root:root /opt/java
sudo ln -sfn "/opt/java/$DIR" /opt/java/current

# 2. 用 alternatives 登記 java、keytool（優先順序 2100）
sudo alternatives --install /usr/bin/java java /opt/java/current/bin/java 2100
sudo alternatives --install /usr/bin/keytool keytool /opt/java/current/bin/keytool 2100

# 3. 登入時設好 JAVA_HOME
sudo install -m 0644 /tmp/java.sh /etc/profile.d/java.sh
rm -f /tmp/java.sh

# 4. 送過來的 tar 刪掉
if [ "${CLEANUP:-0}" = 1 ]; then
  rm -f "$TAR"
fi
EOF
)

section "操作機本機"
install -m 0644 "$TEMPLATE_DIR/java.sh" /tmp/java.sh

if TAR=$JDK_TAR DIR=$JDK_DIR bash -c "$INSTALL_JDK"; then
  ok "$OPS_HOST: $(java -version 2>&1 | head -1)"
else
  die "操作機 JDK 安裝失敗"
fi

section "其他主機：${CLUSTER_HOSTS// /、}"
for host in $CLUSTER_HOSTS; do
  # 1. tar 和 java.sh 送到那台的 /tmp
  if ! copy_to_tmp "$host" "$JDK_TAR" "$TEMPLATE_DIR/java.sh"; then
    fail "$host: scp 失敗"
    continue
  fi

  # 2. 在那台裝
  if ssh_script "$host" TAR="/tmp/$(basename "$JDK_TAR")" DIR="$JDK_DIR" CLEANUP=1 <<<"$INSTALL_JDK"; then
    ok "$host: done"
  else
    fail "$host: 安裝失敗"
  fi
done

section "驗證：java 在 PATH（alternatives）、ssh 進去讀得到 JAVA_HOME（profile.d）"
for host in $ALL_HOSTS; do
  result=$(ssh_script "$host" <<'EOF'
echo "$(java -version 2>&1 | head -1) JAVA_HOME=$JAVA_HOME"
EOF
)

  case $result in
    *"version \"$JDK_MAJOR"*"JAVA_HOME=/opt/java/current")
      ok "$host: $result"
      ;;
    *)
      fail "$host: $result"
      ;;
  esac
done

finish_step
