# 項目 37：下架 service account
#
# 做什麼：應用程式退役時，解除它的帳號（A／B 兩個，或舊的單一帳號）對 topic prefix 的所有 binding，並停用帳號
#   （SCRAM 密碼覆寫成沒人知道的隨機值）。帳號本身留著，稽核日誌裡的名字才查得到。
# 用到的設定（opmenu.conf）：
#   OPMENU_SVC_PAIR          兩個帳號的字尾（預設 "-a -b"）
# 用到的共用函式：
#   v_svc_acct、v_prefix     檢查輸入（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
#   be_mds、k_scope          呼叫 MDS 查 binding（lib/kafka.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   k_unbind_user            解除一條 binding（lib/kafka.sh）
#   k_disable_scram          停用帳號（lib/kafka.sh）
# 改的時候要注意：
#   - 不用 --delete-config 刪 SCRAM 憑證：實測刪掉之後，下一次重啟 broker 會失敗（見 k_disable_scram 的說明）。

run_37() {
  local base="${1:-}"
  local prefix="${2:-}"

  # 1. 問應用程式名稱與 topic prefix
  if [ -z "$base" ]; then
    read -r -p "應用程式名稱（例 app-orders）: " base
  fi

  if [ -z "$prefix" ]; then
    read -r -p "topic prefix（例 orders.）: " prefix
  fi

  if ! v_svc_acct "$base"; then
    return 1
  fi

  if ! v_prefix "$prefix"; then
    return 1
  fi

  # 2. 找出要下架的帳號：有 A／B 就是那兩個，都沒有就是單一帳號
  local suffix accounts=""

  for suffix in $OPMENU_SVC_PAIR; do
    if be_kafka kafka-configs --describe --entity-type users --entity-name "$base$suffix" 2>/dev/null | grep -q 'SCRAM-SHA-512='; then
      accounts="$accounts $base$suffix"
    fi
  done

  if [ -z "$accounts" ]; then
    accounts="$base"
  fi

  # 3. 先列出每個帳號目前的 binding（去掉最後一行 HTTP 狀態）
  local account

  for account in $accounts; do
    echo "-- $account 目前的 binding："
    be_mds POST "/security/1.0/lookup/rolebindings/principal/User:$account" "$(k_scope)" | sed '$d'
  done

  # 4. 確認
  if ! core_confirm "解除$accounts 對 $prefix* 的 binding 並停用；使用這些帳號的 application 會立刻無法連線"; then
    return 1
  fi

  # 5. 一個一個解除 binding、停用
  local role

  for account in $accounts; do
    for role in DeveloperRead DeveloperWrite; do
      k_unbind_user "$account" "$role" Topic "$prefix"
    done

    k_unbind_user "$account" DeveloperRead Group "$prefix"

    if k_disable_scram "$account" > /dev/null; then
      echo "帳號 $account 已下架"
    fi
  done
}
