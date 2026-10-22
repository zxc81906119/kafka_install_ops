#!/usr/bin/env bash
# 第 5 站：JDK 21 —— 銀行給的 tar 解到 /opt/java/<版本>，/opt/java/current 指過去，alternatives + profile.d
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"

section "壓縮檔與頂層目錄"
JDK_TAR=$(ls "$LANDING"/bank/OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz 2>/dev/null | head -1); [ -n "$JDK_TAR" ] || die "$LANDING/bank 裡沒有 JDK tar"
(cd "$LANDING/bank" && sha256sum -c --quiet "$(basename "$JDK_TAR").sha256") || die "JDK sha256 不符"
JDK_DIR=$(tar -tzf "$JDK_TAR" | head -1 | cut -d/ -f1)
ok "tar=$(basename "$JDK_TAR") dir=$JDK_DIR"

# 遠端安裝指令（每台一樣；已解過的目錄不重解）
REMOTE_INSTALL='T=$1; DIR=$2; sudo install -d -m 0755 /opt/java && { [ -d /opt/java/$DIR ] || sudo tar -xzf "$T" -C /opt/java; } && sudo chown -R root:root /opt/java && sudo ln -sfn /opt/java/$DIR /opt/java/current && sudo alternatives --install /usr/bin/java java /opt/java/current/bin/java 2100 && sudo alternatives --install /usr/bin/keytool keytool /opt/java/current/bin/keytool 2100 && sudo install -m 0644 /tmp/java.sh /etc/profile.d/java.sh'

section "操作機本機"
install -m 0644 "$D/templates/java.sh" /tmp/java.sh
bash -c "$REMOTE_INSTALL" _ "$JDK_TAR" "$JDK_DIR" && rm -f /tmp/java.sh && ok "$OPS_HOST: $(java -version 2>&1 | head -1)" || die "操作機 JDK 安裝失敗"

section "其他 ${CLUSTER_HOSTS// /、}"
for h in $CLUSTER_HOSTS; do
  rcp "$h" "$JDK_TAR" "$D/templates/java.sh" || { fail "$h: scp 失敗"; continue; }
  rsh "$h" "bash -c '$REMOTE_INSTALL' _ /tmp/$(basename "$JDK_TAR") $JDK_DIR && rm -f /tmp/$(basename "$JDK_TAR") /tmp/java.sh" && ok "$h: done" || fail "$h: 安裝失敗"
done

section "驗證：alternatives（java 在 PATH）與 profile.d（ssh 非互動 shell 讀得到 JAVA_HOME）"
for h in $ALL_HOSTS; do
  r=$(rsh "$h" 'echo "$(java -version 2>&1 | head -1) JAVA_HOME=$JAVA_HOME"')
  [[ $r == *'version "21'* && $r == *"JAVA_HOME=/opt/java/current"* ]] && ok "$h: $r" || fail "$h: $r"
done
finish
