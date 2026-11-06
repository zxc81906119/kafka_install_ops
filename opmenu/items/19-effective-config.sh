# 項目 19：查看生效中的選單設定
#
# 做什麼：印出主要設定的值，以及每個值是從哪裡來的（opmenu.conf 設的、預設值、或登入後推算的）。
# 用到的設定：下面清單裡的每一個 OPMENU_*
# 用到的共用函式：沒有（OP_SRC 由 lib/defaults.sh 記下每個設定的來源）
# 改的時候要注意：
#   - 想多印哪個設定，就把名稱（去掉 OPMENU_ 開頭）加進下面的清單。
#   - 不要把密碼類的設定加進來（這裡會原樣印出）。

run_19() {
  local name variable

  for name in \
    ENV_LABEL BOOTSTRAP MDS_URL BREAKGLASS_BOOTSTRAP KAFKA_CLUSTER_ID \
    CERT_DIR TRUSTSTORE CA_PEM \
    CONTROLLER_HOSTS BROKER_SERVICES AUX_SERVICES HOSTS DATA_DIR REPLICATION \
    SSH_USER KNOWN_HOSTS SSH_KEY_SECRET BREAKGLASS_PEM CHANGE_WINDOW
  do
    variable="OPMENU_$name"

    # ${!variable}：取「名稱存在 variable 裡的那個變數」的值，例如 variable=OPMENU_HOSTS 就取 $OPMENU_HOSTS
    printf '%-22s %-9s %s\n' "$name" "${OP_SRC[$variable]:-default}" "${!variable:-(empty)}"
  done
}
