#!/usr/bin/env bash
# cert-expiry.sh [目錄…]：操作機每天跑一次，讀我方持有的每一張憑證（預設 ~/pki/certs/*.crt，含不對外、blackbox 探不到的 client 憑證）與信任的根，
# 剩不到 WARN_DAYS 天以 warning 寫 syslog（tag confluent-cert），過期或讀不到是 err。結束碼：0 正常、2 有快到期、1 有過期或讀不到。
WARN_DAYS=${WARN_DAYS:-60}
dirs=${*:-/root/pki/certs}
now=$(date +%s); rc=0; n=0
for f in $(ls $(for d in $dirs; do echo "$d"/*.crt "$d"/*.pem; done) 2>/dev/null | sort -u); do
  case $f in *mds-token-public.pem) continue;; esac       # 不是 CA 簽的憑證，沒有到期日
  end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2) || true
  if [ -z "$end" ]; then logger -t confluent-cert -p user.err "讀不到憑證：$f"; echo "讀不到：$f"; rc=1; continue; fi
  n=$((n+1)); days=$(( ($(date -d "$end" +%s) - now) / 86400 )); cn=$(openssl x509 -in "$f" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')
  msg="$(basename "$f")（CN=$cn）到期 $(date -d "$end" +%F)，剩 $days 天"
  if [ "$days" -lt 0 ]; then logger -t confluent-cert -p user.err "已過期：$msg"; echo "已過期：$msg"; rc=1
  elif [ "$days" -lt "$WARN_DAYS" ]; then logger -t confluent-cert -p user.warning "快到期：$msg"; echo "快到期：$msg"; [ $rc = 0 ] && rc=2
  else echo "$msg"; fi
done
logger -t confluent-cert -p user.info "檢查了 $n 張憑證，結束碼 $rc"
echo "檢查了 $n 張憑證，結束碼 $rc"; exit $rc
