# 項目 38：調整配額
#
# 做什麼：設定或拿掉一個帳號的配額。一次可以改好幾項，例如 producer_byte_rate=1048576,request_percentage=25；
#   值填 - 代表拿掉那一項。改之前、改之後各印一次目前的配額。
#   非互動用法：--run 38 <帳號> <項目=值[,項目=值…]>
# 用到的設定（opmenu.conf）：
#   OPMENU_QUOTA_KEYS        可以改的配額項目
# 用到的共用函式：
#   v_svc_acct、v_in、v_number、v_fail   檢查輸入（lib/common.sh）
#   k_quota_lines            讀配額，整理成一行（lib/kafka.sh）
#   core_confirm             請操作者輸入 yes 確認（lib/common.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
# 改的時候要注意：
#   - 設定（--add-config）和拿掉（--delete-config）要分成兩次指令；合在一起 kafka-configs 會整句拒絕。

run_38() {
  local account="${1:-}"
  local changes="${2:-}"

  # 1. 問帳號，印目前的配額
  if [ -z "$account" ]; then
    read -r -p "帳號: " account
  fi

  if ! v_svc_acct "$account"; then
    return 1
  fi

  local current
  current=$(k_quota_lines "$account")
  if [ $? -ne 0 ]; then
    return 1
  fi

  echo "目前:${current:-(沒有設定配額)}"

  # 2. 問要改哪些項目
  if [ -z "$changes" ]; then
    read -r -p "要改的項目(例 producer_byte_rate=1048576,request_percentage=25;值填 - 拿掉): " changes
  fi

  if [ -z "$changes" ]; then
    echo "沒有要改的項目"
    return 1
  fi

  # 3. 逐項檢查，分成「要設定的」和「要拿掉的」兩串（用逗號接起來）
  local item key value to_set="" to_remove=""

  for item in $(echo "$changes" | tr ',' ' '); do
    if ! echo "$item" | grep -q '='; then
      v_fail "要寫成 項目=值:$item"
      return 1
    fi

    key=$(echo "$item" | cut -d= -f1)
    value=$(echo "$item" | cut -d= -f2-)

    if ! v_in "$key" "$OPMENU_QUOTA_KEYS" "配額項目"; then
      return 1
    fi

    if [ "$value" = - ]; then
      to_remove=$(_item38_append "$to_remove" "$key")
    else
      if ! v_number "$value" "$key 的值"; then
        return 1
      fi
      to_set=$(_item38_append "$to_set" "$key=$value")
    fi
  done

  # 4. 確認
  local summary=""
  if [ -n "$to_set" ]; then
    summary="設定 $to_set"
  fi
  if [ -n "$to_remove" ]; then
    if [ -n "$summary" ]; then
      summary="$summary;"
    fi
    summary="${summary}拿掉 $to_remove"
  fi

  if ! core_confirm "帳號 $account 的配額:$summary"; then
    return 1
  fi

  # 5. 設定與拿掉分兩次做
  if [ -n "$to_set" ]; then
    if ! be_kafka kafka-configs --alter --entity-type users --entity-name "$account" --add-config "$to_set"; then
      return 1
    fi
  fi

  if [ -n "$to_remove" ]; then
    if ! be_kafka kafka-configs --alter --entity-type users --entity-name "$account" --delete-config "$to_remove"; then
      return 1
    fi
  fi

  # 6. 印改後的配額
  current=$(k_quota_lines "$account")
  if [ $? -ne 0 ]; then
    return 1
  fi

  echo "改後:${current:-(沒有設定配額)}"
}

# _item38_append <已有的> <新的>：用逗號接起來；已有的是空的就只印新的
#   例：_item38_append "" "a=1" → a=1；_item38_append "a=1" "b=2" → a=1,b=2
_item38_append() {
  if [ -z "$1" ]; then
    echo "$2"
  else
    echo "$1,$2"
  fi
}
