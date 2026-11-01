#!/usr/bin/env bash
# cert-expiry.sh [目錄…] — 每天檢查一次我方持有的憑證還剩幾天
# 做什麼：讀每一張憑證（預設 ~/pki/certs 的 *.crt、*.pem，含不對外、blackbox 探不到的 client 憑證）與信任的根，
#   剩不到 WARN_DAYS 天寫 syslog warning（tag confluent-cert），過期或讀不到寫 err
# 用到的設定：環境變數 WARN_DAYS（預設 60）
# 結束碼：0 正常、2 有快到期、1 有過期或讀不到（systemd 那邊用 SuccessExitStatus=2，快到期不算服務失敗）
# 改的時候要注意：輸出與 syslog 的文字（「快到期：…」「已過期：…」「檢查了 N 張憑證，結束碼 N」）手冊的預期輸出有用到

warn_days=${WARN_DAYS:-60}
dirs=${*:-/root/pki/certs}
now=$(date +%s)
rc=0
count=0

# cert_files：要檢查的檔案：每個目錄的 *.crt、*.pem，排好順序、去掉重複
cert_files() {
  local d
  for d in $dirs; do
    ls "$d"/*.crt "$d"/*.pem 2> /dev/null
  done | sort -u
}

for f in $(cert_files); do
  # MDS token 的公鑰不是 CA 簽的憑證，沒有到期日
  case $f in
    *mds-token-public.pem) continue ;;
  esac

  # 1. 到期日；讀不到就記 err，換下一張
  end=$(openssl x509 -in "$f" -noout -enddate 2> /dev/null | cut -d= -f2)

  if [ -z "$end" ]; then
    logger -t confluent-cert -p user.err "讀不到憑證：$f"
    echo "讀不到：$f"
    rc=1
    continue
  fi

  # 2. 剩幾天、CN
  count=$((count + 1))
  days=$(( ($(date -d "$end" +%s) - now) / 86400 ))
  cn=$(openssl x509 -in "$f" -noout -subject -nameopt sep_comma_plus,sname | sed 's/.*CN=\([^,]*\).*/\1/')
  msg="$(basename "$f")（CN=$cn）到期 $(date -d "$end" +%F)，剩 $days 天"

  # 3. 過期 → err；快到期 → warning（結束碼還是 0 的話改成 2）；其他照印
  if [ "$days" -lt 0 ]; then
    logger -t confluent-cert -p user.err "已過期：$msg"
    echo "已過期：$msg"
    rc=1
  elif [ "$days" -lt "$warn_days" ]; then
    logger -t confluent-cert -p user.warning "快到期：$msg"
    echo "快到期：$msg"

    if [ $rc = 0 ]; then
      rc=2
    fi
  else
    echo "$msg"
  fi
done

logger -t confluent-cert -p user.info "檢查了 $count 張憑證，結束碼 $rc"
echo "檢查了 $count 張憑證，結束碼 $rc"
exit $rc
