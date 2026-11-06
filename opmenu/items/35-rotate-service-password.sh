# 項目 35：輪替 service account 的密碼（A／B 不中斷）
#
# 做什麼：應用程式有 A／B 兩個帳號（項目 34 建的）時，只換「現在沒在用」的那個帳號的密碼，
#   新密碼寫進交接檔；之後請應用程式切到那個帳號，不中斷。下次輪替就換另一個。
#   只有單一帳號的舊應用程式：改密碼會讓它的新連線立刻失敗（中斷），要明確確認才做。
# 用到的設定（opmenu.conf）：
#   OPMENU_SVC_PAIR          兩個帳號的字尾（預設 "-a -b"）
#   OPMENU_LOG               選單紀錄（用來顯示每個帳號上次輪替的時間）
# 用到的共用函式：
#   v_svc_acct               檢查帳號名稱符合命名規範（lib/common.sh）
#   core_handover_ready      交接檔的目錄寫不寫得進去（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
#   k_gen_pw                 產生隨機密碼（lib/kafka.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   core_handover_secret     把新密碼寫進交接檔（lib/common.sh）
#   _in_words                檢查一個字在不在一串字裡（lib/common.sh）
# 改的時候要注意：
#   - 建議單一帳號的應用程式先用 34 建好 A／B 再遷移，之後就不會中斷。

run_35() {
  local base="${1:-}"
  local in_use="${2:-}"

  # 1. 問應用程式名稱
  if [ -z "$base" ]; then
    read -r -p "應用程式名稱（例 app-orders）: " base
  fi

  if ! v_svc_acct "$base"; then
    return 1
  fi

  if ! core_handover_ready; then
    return 1
  fi

  # 2. 找出這個應用程式有哪幾個 A／B 帳號（有 SCRAM 憑證的才算）
  local suffix pair=""

  for suffix in $OPMENU_SVC_PAIR; do
    if _item35_has_scram "$base$suffix"; then
      pair="$pair $base$suffix"
    fi
  done

  # 3. 不到兩個：當成單一帳號處理（會中斷，要明確確認）
  if [ "$(echo $pair | wc -w)" -lt 2 ]; then
    _item35_rotate_single "$base"
    return $?
  fi

  # 4. 顯示每個帳號上次輪替的時間（選單紀錄裡最後一筆 HANDOVER）
  local account account_field last
  echo "-- 這組帳號上次輪替（選單紀錄）："

  for account in $pair; do
    # 這個帳號最後一筆 HANDOVER，再取第一欄（時間），去掉後面的空白
    account_field="| $account |"
    last=$(grep -F '| HANDOVER | ' "$OPMENU_LOG" 2>/dev/null | grep -F "$account_field" | tail -1)
    last=$(echo "$last" | cut -d'|' -f1 | sed 's/ *$//')
    printf '  %-28s %s\n' "$account" "$last"
  done

  # 5. 問應用程式現在用哪一個；要換的是另一個
  if [ -z "$in_use" ]; then
    read -r -p "應用程式現在用的是哪一個（$(echo $pair)）: " in_use
  fi

  if ! _in_words "$in_use" "$pair"; then
    echo "$in_use 不是 $(echo $pair) 其中之一"
    return 1
  fi

  local rotate=""
  for account in $pair; do
    if [ "$account" != "$in_use" ]; then
      rotate="$account"
    fi
  done

  # 6. 確認後換密碼，寫進交接檔
  if ! core_confirm "更換 $rotate 的密碼（應用程式現在用 $in_use，不受影響）"; then
    return 1
  fi

  if ! _item35_set_password "$rotate"; then
    return 1
  fi

  echo "下一步：請應用程式改用 $rotate 與新密碼；下次輪替時換 $in_use"
}

# _item35_has_scram <帳號>：這個帳號有 SCRAM 憑證就回 0
_item35_has_scram() {
  be_kafka kafka-configs --describe --entity-type users --entity-name "$1" 2>/dev/null | grep -q 'SCRAM-SHA-512='
}

# _item35_set_password <帳號>：產生新密碼、改到 Kafka、寫進交接檔
_item35_set_password() {
  local account="$1"
  local password
  password=$(k_gen_pw)

  if ! be_kafka kafka-configs --alter \
      --add-config "SCRAM-SHA-512=[password=$password]" \
      --entity-type users \
      --entity-name "$account" > /dev/null; then
    return 1
  fi

  if ! core_handover_secret "$account" "$password"; then
    echo "交接失敗：$account 的密碼已改，請再跑一次 35 重新產生"
    return 1
  fi

  unset password
  return 0
}

# _item35_rotate_single <帳號>：只有單一帳號的舊應用程式，改密碼會中斷，要明確確認
_item35_rotate_single() {
  local base="$1"

  echo "${CR}$base 沒有 A／B 兩個帳號：改密碼會讓使用 $base 的應用程式新連線立刻失敗（中斷）。${C0}"

  if ! _item35_has_scram "$base"; then
    echo "也沒有 $base 這個帳號"
    return 1
  fi

  if ! core_confirm "在中斷的情況下更換 $base 的密碼（應用程式要同時換）"; then
    return 1
  fi

  _item35_set_password "$base"
}
