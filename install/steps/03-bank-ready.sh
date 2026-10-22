#!/usr/bin/env bash
# 第 3 站：銀行準備好了嗎 —— 我方只產生 ssh 金鑰；其餘是銀行各團隊的事，這裡印出清單並逐項確認
# where: ops02 （cpadmin）
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd); source "$D/conf/site.env"; source "$D/lib/log.sh"; source "$D/lib/ssh.sh"

section "3.1 操作機的 ssh 金鑰（私鑰不離開操作機；正式環境可由 CyberArk 產生與派送，指令不變）"
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "cpadmin@$OPS_HOST" -f ~/.ssh/id_ed25519
ok "公鑰：$(cat ~/.ssh/id_ed25519.pub)"

bank "3.1 OS 團隊：把上面這把公鑰放進每台主機（$ALL_HOSTS）cpadmin 的 authorized_keys，以及 $REPO_HOST 上 $REPO_DEPLOY_USER 的 authorized_keys。" \
     "3.2 OS 團隊：每台主機信任銀行根憑證（/etc/pki/ca-trust/source/anchors/bank-root.pem + update-ca-trust），並有指向 OS 套件庫的 .repo（含 os-packages.txt 列的套件）。" \
     "3.3 OS 團隊：JDK 21 的 tar 與 .sha256 放到 $LANDING/bank/。" \
     "3.4 AD 團隊：OU/群組 kafka-admins、kafka-operators、kafka-devs；唯讀 bind 帳號 $AD_BIND_DN；測試人員 alice/bob/carol；" \
     "    LDAPS 憑證由銀行 CA 簽；bind 密碼交付到 $SECRETS_DIR/ldap-bind.pass、測試人員密碼到 $SECRETS_DIR/ad-test-users.pass（0600）。" \
     "3.5 網路團隊：行內 NTP（$NTP_SERVER）可用；負載平衡 $LB_HOST 的 8082 轉到 ${RESTS// /、} 的 8082，$REST_VIP 指到它。"

section "確認 3.1：每台都能用金鑰登入（第一次會把主機金鑰記進 known_hosts）"
for h in $ALL_HOSTS; do
  got=$(rsh "$h" hostname 2>&1); [ "$got" = "$h" ] && ok "$h" || fail "$h：$got"
done
got=$(rsh_as "$REPO_DEPLOY_USER" "$REPO_HOST" hostname 2>&1); [ "$got" = "$REPO_HOST" ] && ok "$REPO_DEPLOY_USER@$REPO_HOST" || fail "$REPO_DEPLOY_USER@$REPO_HOST：$got"

section "確認 3.2：根憑證信任與 OS 套件庫"
for h in $ALL_HOSTS; do
  r=$(rsh "$h" 'test -f /etc/pki/ca-trust/source/anchors/bank-root.pem && echo anchor || echo no-anchor; curl -s -o /dev/null -m 10 -w %{http_code} '"$REPO_URL"'/os/repodata/repomd.xml' 2>&1 | paste -sd' ')
  [ "$r" = "anchor 200" ] && ok "$h：bank-root.pem 在、OS 套件庫 200" || fail "$h：$r"
done

section "確認 3.3：JDK tar 與 sha256"
if ls "$LANDING"/bank/*.tar.gz >/dev/null 2>&1 && (cd "$LANDING/bank" && sha256sum -c --quiet ./*.sha256); then ok "JDK：$(basename "$(ls "$LANDING"/bank/*.tar.gz | head -1)") sha256 相符"; else fail "JDK tar 不在 $LANDING/bank 或 sha256 不符"; fi

section "確認 3.4：LDAPS 憑證鏈、密碼檔"
v=$(openssl s_client -connect "$AD_FQDN:$AD_LDAPS_PORT" -CAfile /etc/pki/ca-trust/source/anchors/bank-root.pem </dev/null 2>/dev/null | grep "Verify return code")
[[ $v == *"0 (ok)"* ]] && ok "LDAPS $AD_FQDN:$AD_LDAPS_PORT：$v" || fail "LDAPS：${v:-連不上}"
for f in ldap-bind ad-test-users; do
  if [ -s "$SECRETS_DIR/$f.pass" ]; then m=$(stat -c %a "$SECRETS_DIR/$f.pass"); [ "$m" = 600 ] && ok "$SECRETS_DIR/$f.pass（0600）" || fail "$SECRETS_DIR/$f.pass 權限 $m，應為 600"; else fail "$SECRETS_DIR/$f.pass 不存在"; fi
done

section "確認 3.5：負載平衡在聽（REST 尚未啟動，只看 8082 有沒有開）"
nc -z -w 3 "$(fqdn "$LB_HOST")" 8082 && ok "$LB_HOST:8082 開著" || fail "$LB_HOST:8082 連不上"
getent hosts "$REST_VIP" >/dev/null && ok "$REST_VIP 解析得到" || fail "$REST_VIP 解析不到"

[ "${FAILED:-0}" = 0 ] || { log "銀行還有 $FAILED 項沒完成"; pending; }
finish
