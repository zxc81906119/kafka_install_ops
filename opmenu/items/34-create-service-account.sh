# 項目 34：新增 service account（A／B 兩個 SCRAM 帳號）
#
# 做什麼：為一個應用程式建兩個 SCRAM 帳號（<名稱>-a、<名稱>-b），兩個的權限完全一樣：
#   該系統 topic prefix 的讀（＋寫），以及同 prefix 的 consumer group。密碼寫進交接檔、不顯示在畫面上。
#   應用程式先用 -a；之後輪替密碼（項目 35）時換沒在用的那個，再請應用程式切過去，不中斷。
#   任何一步失敗，就把已經建的帳號與 binding 全部收回（回滾），不留下沒人管的帳號。
# 用到的設定（opmenu.conf）：
#   OPMENU_SVC_PATTERN       帳號命名規範
#   OPMENU_SVC_PAIR          兩個帳號的字尾（預設 "-a -b"）
#   OPMENU_HANDOVER_DIR      交接檔放哪裡
# 用到的共用函式：
#   v_svc_acct、v_prefix、v_in   檢查輸入（lib/common.sh）
#   core_handover_ready      交接檔的目錄寫不寫得進去（改密碼「之前」先確認）（lib/common.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
#   be_mds、k_bind_body、k_http_ok   呼叫 MDS 建 binding、判斷 MDS 回應成功（lib/kafka.sh）
#   k_gen_pw                 產生隨機密碼（lib/kafka.sh）
#   k_unbind_user、k_disable_scram   回滾用：解除 binding、停用帳號（lib/kafka.sh）
#   core_handover_secret     把新密碼寫進交接檔（lib/common.sh）
# 改的時候要注意：
#   - 建帳號需要 ClusterAdmin；綁權限需要 UserAdmin（由 Kafka／MDS 判斷）。
#   - 建帳號時先放一個隨機密碼（不交出去），全部成功之後才產生要交付的那組，所以回滾時不會有已交付的密碼。

run_34() {
  local base="${1:-}"
  local prefix="${2:-}"
  local mode="${3:-rw}"

  # 1. 問應用程式名稱與 topic prefix
  if [ -z "$base" ]; then
    read -r -p "應用程式名稱（例 app-orders，會建 app-orders-a、app-orders-b）: " base
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

  if ! v_in "$mode" "rw ro" "模式"; then
    return 1
  fi

  # 2. 兩個帳號的名稱：名稱＋每個字尾
  local suffix accounts=""
  for suffix in $OPMENU_SVC_PAIR; do
    accounts="$accounts $base$suffix"
  done

  # 3. 交接檔寫不進去就不做（免得帳號建了、密碼卻交不出去）
  if ! core_handover_ready; then
    return 1
  fi

  # 4. 確認
  local access="讀寫"
  if [ "$mode" = ro ]; then
    access="讀取"
  fi

  if ! core_confirm "建立帳號$accounts，授權 $prefix* 的$access"; then
    return 1
  fi

  # 5. 一個一個建帳號、綁權限；失敗就停下來，記住已經建了哪些
  local account created="" failed=no

  for account in $accounts; do
    if ! _item34_create_account "$account"; then
      failed=yes
      break
    fi

    created="$created $account"

    if ! _item34_bind "$account" "$prefix" "$mode"; then
      failed=yes
      break
    fi
  done

  # 6. 有失敗：回滾已經建的，結束
  if [ "$failed" = yes ]; then
    _item34_rollback "$prefix" $created
    echo "已回滾：$created 帳號與 binding 都已移除"
    return 1
  fi

  # 7. 全部成功：才產生要交付的密碼，寫進交接檔（兩個都要交，應用程式先用第一個）
  local password

  for account in $accounts; do
    password=$(k_gen_pw)

    if ! be_kafka kafka-configs --alter \
        --add-config "SCRAM-SHA-512=[password=$password]" \
        --entity-type users \
        --entity-name "$account" > /dev/null; then
      return 1
    fi

    if ! core_handover_secret "$account" "$password"; then
      echo "$account 的新密碼交接失敗：用 35 重新產生"
      return 1
    fi
  done

  unset password
  echo "帳號$accounts 已建立；應用程式先用 $(echo $accounts | cut -d' ' -f1)"
}

# _item34_create_account <帳號>：建一個 SCRAM 帳號，先放一個不交出去的隨機密碼
_item34_create_account() {
  local account="$1"

  be_kafka kafka-configs --alter \
    --add-config "SCRAM-SHA-512=[password=$(k_gen_pw)]" \
    --entity-type users \
    --entity-name "$account" > /dev/null
}

# _item34_bind <帳號> <prefix> <rw|ro>：綁 topic prefix 的讀（rw 再加寫），以及同 prefix 的 consumer group 讀取
_item34_bind() {
  local account="$1" prefix="$2" mode="$3"
  local role topic_body group_body

  topic_body=$(k_bind_body Topic "$prefix" PREFIXED)
  group_body=$(k_bind_body Group "$prefix" PREFIXED)

  for role in DeveloperRead DeveloperWrite; do
    # 唯讀模式不給寫
    if [ "$mode" = ro ] && [ "$role" = DeveloperWrite ]; then
      continue
    fi

    if ! be_mds POST "/security/1.0/principals/User:$account/roles/$role/bindings" "$topic_body" | k_http_ok; then
      echo "$account binding $role 失敗"
      return 1
    fi
  done

  if ! be_mds POST "/security/1.0/principals/User:$account/roles/DeveloperRead/bindings" "$group_body" | k_http_ok; then
    echo "$account binding consumer group 失敗"
    return 1
  fi

  return 0
}

# _item34_rollback <prefix> <帳號…>：解除這些帳號對 prefix 的所有 binding，並停用帳號
_item34_rollback() {
  local prefix="$1"
  shift
  local account role

  for account in "$@"; do
    for role in DeveloperRead DeveloperWrite; do
      k_unbind_user "$account" "$role" Topic "$prefix"
    done

    k_unbind_user "$account" DeveloperRead Group "$prefix"
    k_disable_scram "$account" > /dev/null 2>&1
  done
}
