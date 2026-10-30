item 17 1 n n "查看 certificate 與 license 到期日" "連到各服務的 TLS 端點，看它們實際出示的憑證：主旨、簽發者、到期日（換發後確認每一台都換到了）；license 的類型與到期日（讀得到 _confluent-command 就即時讀，讀不到就顯示操作機每日檢查的最後一筆）"
run() {
  be_cert_list
  echo
  local claims exp type days
  if claims=$(k_license_claims) && exp=$(printf '%s' "$claims" | grep -o '"exp":[0-9]*' | cut -d: -f2) && [ -n "$exp" ]; then
    type=$(printf '%s' "$claims" | grep -o '"licenseType":"[^"]*"' | cut -d'"' -f4); days=$(( (exp - $(date +%s)) / 86400 ))
    printf 'license：%s，到期 %s，剩 %s 天%s\n' "${type:-unknown}" "$(date -d "@$exp" +%F)" "$days" \
      "$([ "$days" -lt 0 ] && echo '  已過期 ⚠⚠' || { [ "$days" -lt "$OPMENU_LICENSE_WARN_DAYS" ] && echo "  ⚠（不到 $OPMENU_LICENSE_WARN_DAYS 天，手把手 26.3）"; })"
    return 0
  fi
  local last; last=$(journalctl -t "$OPMENU_LICENSE_SYSLOG_TAG" -n 1 --no-pager -o short-iso 2>/dev/null | grep -v '^-- ' | tail -1)
  echo "license：你讀不到 _confluent-command（要有它的 DeveloperRead），改看操作機每日檢查的最後一筆："
  echo "  ${last:-沒有紀錄（每日檢查沒有排程？見手把手 26.2）}"
}
