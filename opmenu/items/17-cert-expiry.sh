# 項目 17：查看 certificate 與 license 到期日
#
# 做什麼：
#   - 連到各服務的 TLS 端點，看它們「實際出示」的憑證：主旨、簽發者、到期日（換發後確認每一台都換到了）。
#   - license 的類型與到期日：讀得到 _confluent-command 就即時讀；讀不到就顯示操作機每日檢查（手把手 26.2）的最後一筆。
# 用到的設定（opmenu.conf）：
#   OPMENU_LICENSE_WARN_DAYS     license 剩不到幾天就標警告
#   OPMENU_LICENSE_SYSLOG_TAG    每日檢查寫 syslog 用的 tag
# 用到的共用函式：
#   be_cert_list             各端點出示的憑證（lib/hosts.sh）
#   k_license_claims         讀出生效中的 license 內容（lib/kafka.sh）
# 改的時候要注意：
#   - 讀 license 要有 _confluent-command 的 DeveloperRead；沒有時不算失敗，改看每日檢查的紀錄。

run_17() {
  # 1. 各端點出示的憑證
  be_cert_list
  echo

  # 2. license：即時讀
  local claims type days
  local expires=""   # 讀不到 license 時保持空的，下面才走第 3 步（沒有初值的話 set -u 會在這裡中止）

  claims=$(k_license_claims)
  if [ $? -eq 0 ]; then
    expires=$(echo "$claims" | grep -o '"exp":[0-9]*' | cut -d: -f2)
  fi

  if [ -n "$expires" ]; then
    type=$(echo "$claims" | grep -o '"licenseType":"[^"]*"' | cut -d'"' -f4)
    days=$(( (expires - $(date +%s)) / 86400 ))

    local warning=""
    if [ "$days" -lt 0 ]; then
      warning="  已過期 ⚠⚠"
    elif [ "$days" -lt "$OPMENU_LICENSE_WARN_DAYS" ]; then
      warning="  ⚠（不到 $OPMENU_LICENSE_WARN_DAYS 天，手把手 26.3）"
    fi

    echo "license：${type:-unknown}，到期 $(date -d "@$expires" +%F)，剩 $days 天$warning"
    return 0
  fi

  # 3. 讀不到：改看操作機每日檢查寫進 syslog 的最後一筆
  local last
  last=$(journalctl -t "$OPMENU_LICENSE_SYSLOG_TAG" -n 1 --no-pager -o short-iso 2>/dev/null | grep -v '^-- ' | tail -1)

  echo "license：你讀不到 _confluent-command（要有它的 DeveloperRead），改看操作機每日檢查的最後一筆："
  if [ -n "$last" ]; then
    echo "  $last"
  else
    echo "  沒有紀錄（每日檢查沒有排程？見手把手 26.2）"
  fi
}
