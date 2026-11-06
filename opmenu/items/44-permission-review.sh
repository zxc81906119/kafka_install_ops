# 項目 44：權限清單匯出與變更前快照
#
# 做什麼：
#   1) 權限清單（CSV）：OPMENU_REVIEW_ROLES 裡每一種 role，綁給了哪些 principal、綁在哪些資源上。給權限覆核用。
#   2) 變更前快照：權限清單＋叢集的 topic、topic 設定、帳號與配額、broker 動態設定、ACL、role binding、features，
#      存成一個目錄。檔名與內容和操作機的每日備份（手把手 23.3）一樣，可以直接用 sha256 比對，也能拿來還原（23.6、26.4）。
#   非互動用法：--run 44（CSV）、--run 44 snapshot（快照）
# 用到的設定（opmenu.conf）：
#   OPMENU_REVIEW_ROLES      權限清單要列哪幾種 role
#   OPMENU_OUT_DIR           匯出檔放哪裡
# 用到的共用函式：
#   be_mds、k_scope          呼叫 MDS 查 role 與 binding（lib/kafka.sh）
#   be_kafka                 用操作者本人的身分跑 Kafka 指令工具（lib/kafka.sh）
#   v_match、v_principal     檢查 MDS 回來的名稱格式（lib/common.sh）
# 改的時候要注意：
#   - 快照每個檔的格式都要和每日備份（install/steps/23-metadata-backup.sh、手把手 23.3）一字不差：
#     features 拿掉 Epoch、ACL 一條一行、清單一律 LC_ALL=C 排序。改了這裡，那邊也要一起改，否則 sha256 對不上。
#   - 要有 SecurityAdmin 或 UserAdmin 才查得到所有人的 binding（由 MDS 判斷）。

run_44() {
  local mode="${1:-}"

  # 1. 互動時問要哪一種
  if [ -z "$mode" ] && [ -t 0 ]; then
    local choice
    read -r -p "1) 只匯出權限清單 CSV  2) 變更前完整快照 [1]: " choice

    if [ "$choice" = 2 ]; then
      mode=snapshot
    fi
  fi

  # 2. 快照
  if [ "$mode" = snapshot ]; then
    _item44_snapshot
    return $?
  fi

  # 3. 只匯出權限清單
  local file
  file="$OPMENU_OUT_DIR/permission-review-$(date +%Y%m%d-%H%M%S)-$OP_USER.csv"

  if ! _item44_review_csv "$file"; then
    rm -f "$file"
    return 1
  fi

  echo "已匯出 $(_item44_csv_rows "$file") 筆權限:$file"
  return 0
}

# _item44_snapshot：變更前快照，放在 OPMENU_OUT_DIR/snapshot-<時間>-<操作者>/
_item44_snapshot() {
  local dir failed=""

  # 1. 快照目錄（0750）
  dir="$OPMENU_OUT_DIR/snapshot-$(date +%Y%m%d-%H%M%S)-$OP_USER"

  if ! mkdir -p "$dir"; then
    return 1
  fi
  chmod 0750 "$dir"

  # 2. 權限清單
  if ! _item44_review_csv "$dir/permission-review.csv"; then
    failed="$failed permission-review.csv"
  fi

  # 3. 叢集的清單與設定（每個檔的寫法和每日備份一樣）
  if ! be_kafka kafka-topics --describe > "$dir/topics.txt"; then
    failed="$failed topics.txt"
  fi

  if ! be_kafka kafka-configs --describe --entity-type topics > "$dir/topic-configs.txt"; then
    failed="$failed topic-configs.txt"
  fi

  if ! be_kafka kafka-configs --describe --entity-type users | LC_ALL=C sort > "$dir/users.txt"; then
    failed="$failed users.txt"
  fi

  if ! be_kafka kafka-configs --describe --entity-type brokers --entity-default > "$dir/broker-configs.txt"; then
    failed="$failed broker-configs.txt"
  fi

  if ! be_kafka kafka-acls --list | _item44_acls | LC_ALL=C sort > "$dir/acls.txt"; then
    failed="$failed acls.txt"
  fi

  if ! _item44_rbac > "$dir/rbac.txt"; then
    failed="$failed rbac.txt"
  fi

  # features：Epoch 每次都不同，拿掉才比對得了
  if ! be_kafka kafka-features describe | sed 's/[[:space:]]*Epoch: [0-9]*//' > "$dir/features.txt"; then
    failed="$failed features.txt"
  fi

  # 4. 每個清單都要有內容：接了 sort 的那幾項，前面的指令失敗會被 sort 的結束碼蓋掉，所以再用「是不是空的」檢查一次
  local file
  for file in "$dir"/*.txt; do
    if [ ! -s "$file" ]; then
      failed="$failed $(basename "$file")(空的)"
    fi
  done

  # 5. 算 sha256（比對用）
  (
    if cd "$dir"; then
      sha256sum -- *.txt *.csv > SHA256SUMS
    fi
  )

  if [ -n "$failed" ]; then
    echo "快照有失敗的項目:$failed(目錄 $dir)"
    return 1
  fi

  local rows lists
  rows=$(_item44_csv_rows "$dir/permission-review.csv")
  lists=$(ls "$dir" | grep -c '\.txt$')
  echo "已匯出變更前快照($rows 筆權限,$lists 個清單):$dir"
}

# _item44_csv_rows <CSV 檔>：資料有幾筆（總行數減掉第一行標題）
_item44_csv_rows() {
  local lines
  lines=$(wc -l < "$1")
  echo $(( lines - 1 ))
}

# _item44_review_csv <輸出檔>：權限清單，一條 binding 一行
#
# 輸出，例如：
#   role,principal,resource_type,resource_name,pattern_type
#   "DeveloperRead","User:app-orders-a","Topic","orders.","PREFIXED"
#   "SystemAdmin","User:svc-ops","Cluster","",""          ← cluster 層級的 binding，沒有資源
# 失敗（查 MDS 不是 200）時印出原因、回傳 1
_item44_review_csv() {
  local file="$1"
  local scope role reply code body principal bindings role_pair resources resource

  scope=$(k_scope)

  echo "role,principal,resource_type,resource_name,pattern_type" > "$file"

  for role in $OPMENU_REVIEW_ROLES; do
    if ! v_match "$role" '^[A-Za-z]+$' "role 名稱" > /dev/null; then
      continue
    fi

    # 1. 這個 role 綁給了誰（回應的最後一行是「HTTP <狀態碼>」）
    reply=$(be_mds POST "/security/1.0/lookup/role/$role" "$scope")
    code=$(echo "$reply" | tail -1 | sed 's/^HTTP //')
    body=$(echo "$reply" | sed '$d')

    if [ "$code" != 200 ]; then
      echo "查詢 role $role 失敗(HTTP $code);需要 SecurityAdmin 或 UserAdmin"
      return 1
    fi

    # 2. 每個 principal：這個 role 綁在哪些資源上
    for principal in $(echo "$body" | grep -o '"[A-Za-z]*:[^"]*"' | tr -d '"'); do
      if ! v_principal "$principal" > /dev/null; then
        continue
      fi

      bindings=$(be_mds POST "/security/1.0/lookup/rolebindings/principal/$principal" "$scope" | sed '$d')

      # 回應裡 "<role>":[ … ] 中括號裡的那一串是資源清單；空的代表綁在 cluster 層級
      role_pair=$(echo "$bindings" | grep -o "\"$role\":\\[[^]]*\\]" | tail -1)
      resources=$(echo "$role_pair" | sed 's/^"[A-Za-z]*":\[//; s/\]$//')

      if [ -z "$resources" ]; then
        printf '"%s","%s","Cluster","",""\n' "$role" "$principal" >> "$file"
        continue
      fi

      # 資源之間是 },{ ：拆成一個資源一行再逐一印
      echo "$resources" | sed 's/},{/}\n{/g' | while IFS= read -r resource; do
        _item44_csv_line "$role" "$principal" "$resource" >> "$file"
      done
    done
  done

  return 0
}

# _item44_csv_line <role> <principal> <一個資源的 JSON>：印 CSV 的一行
#   例：_item44_csv_line DeveloperRead User:app-orders-a '{"resourceType":"Topic","name":"orders.","patternType":"PREFIXED"}'
#   →  "DeveloperRead","User:app-orders-a","Topic","orders.","PREFIXED"
_item44_csv_line() {
  local role="$1" principal="$2" resource="$3"
  local type name pattern

  type=$(echo "$resource" | grep -o '"resourceType":"[^"]*"' | cut -d'"' -f4)
  name=$(echo "$resource" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
  pattern=$(echo "$resource" | grep -o '"patternType":"[^"]*"' | cut -d'"' -f4)

  printf '"%s","%s","%s","%s","%s"\n' "$role" "$principal" "$type" "$name" "$pattern"
}

# _item44_rbac：快照的 rbac.txt，格式和每日備份一樣：
#   每個 principal 一段「== <principal>」，底下每條 binding 一行「principal|role|資源類型|名稱|比對方式」（每段內 LC_ALL=C 排序）。
#   principal 取自 MDS 的每一種 role（不只 OPMENU_REVIEW_ROLES），和每日備份用 confluent CLI 列出的是同一批。
# 輸出，例如：
#   == User:app-orders-a
#   User:app-orders-a|DeveloperRead|Group|orders-|PREFIXED
#   User:app-orders-a|DeveloperRead|Topic|orders.|PREFIXED
#   == User:svc-ops
#   User:svc-ops|SystemAdmin|Cluster||
_item44_rbac() {
  local scope roles_reply roles role role_reply principals principal

  scope=$(k_scope)

  # 1. MDS 有哪些 role
  roles_reply=$(be_mds GET /security/1.0/roles | sed '$d')
  roles=$(echo "$roles_reply" | grep -o '"name":"[A-Za-z]*"' | cut -d'"' -f4)

  if [ -z "$roles" ]; then
    return 1
  fi

  # 2. 每種 role 綁給了誰，合起來去掉重複、排序
  principals=$(
    for role in $roles; do
      role_reply=$(be_mds POST "/security/1.0/lookup/role/$role" "$scope" | sed '$d')
      echo "$role_reply" | grep -o '"[A-Za-z]*:[^"]*"' | tr -d '"'
    done | LC_ALL=C sort -u
  )

  # 3. 每個 principal 一段
  for principal in $principals; do
    if ! v_principal "$principal" > /dev/null; then
      continue
    fi

    echo "== $principal"
    _item44_bindings_of "$principal" | LC_ALL=C sort
  done
}

# _item44_bindings_of <principal>：這個 principal 的每條 binding 一行「principal|role|資源類型|名稱|比對方式」（還沒排序）
#
# MDS 的回應長這樣（每個 role 一組 "<role>":[資源,…]；cluster 層級的是空陣列）：
#   {"DeveloperRead":[{"resourceType":"Topic","name":"orders.","patternType":"PREFIXED"}],"SystemAdmin":[]}
_item44_bindings_of() {
  local principal="$1"
  local scope body pairs pair role resources

  scope=$(k_scope)
  body=$(be_mds POST "/security/1.0/lookup/rolebindings/principal/$principal" "$scope" | sed '$d')

  # 一組 "<role>":[ … ] 一行
  pairs=$(echo "$body" | grep -o '"[A-Za-z]*":\[[^]]*\]')

  echo "$pairs" | while IFS= read -r pair; do
    if [ -z "$pair" ]; then
      continue
    fi

    role=$(echo "$pair" | cut -d'"' -f2)
    resources=$(echo "$pair" | sed 's/^"[A-Za-z]*":\[//; s/\]$//')

    # 空的 = cluster 層級
    if [ -z "$resources" ]; then
      printf '%s|%s|Cluster||\n' "$principal" "$role"
      continue
    fi

    # 資源之間是 },{ ：拆成一個資源一行
    echo "$resources" | sed 's/},{/}\n{/g' | while IFS= read -r resource; do
      _item44_rbac_line "$principal" "$role" "$resource"
    done
  done
}

# _item44_rbac_line <principal> <role> <一個資源的 JSON>：印 rbac.txt 的一行
#   例：→ User:app-orders-a|DeveloperRead|Topic|orders.|PREFIXED
_item44_rbac_line() {
  local principal="$1" role="$2" resource="$3"
  local type name pattern

  type=$(echo "$resource" | grep -o '"resourceType":"[^"]*"' | cut -d'"' -f4)
  name=$(echo "$resource" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
  pattern=$(echo "$resource" | grep -o '"patternType":"[^"]*"' | cut -d'"' -f4)

  printf '%s|%s|%s|%s|%s\n' "$principal" "$role" "$type" "$name" "$pattern"
}

# _item44_acls：把 kafka-acls --list 的輸出改成一條 ACL 一行「資源類型|名稱|比對方式|principal|host|操作|ALLOW/DENY」
#   和每日備份（install/steps/23-metadata-backup.sh 的 acls）用的是同一段 awk（這裡分行排版），改的話兩邊一起改。
#
# 輸入，例如：
#   Current ACLs for resource `ResourcePattern(resourceType=TOPIC, name=*, patternType=LITERAL)`:
#       (principal=User:svc-backup, host=*, operation=DESCRIBE, permissionType=ALLOW)
# 輸出，例如：
#   TOPIC|*|LITERAL|User:svc-backup|*|DESCRIBE|ALLOW
_item44_acls() {
  awk '
    # 資源那一行：記下「資源類型|名稱|比對方式」
    /^Current ACLs for resource/ {
      s = $0
      sub(/.*resourceType=/, "", s)
      sub(/\)`:.*/, "", s)
      gsub(/, name=|, patternType=/, "|", s)
      r = s
      next
    }

    # ACL 那一行：改成「principal|host|操作|ALLOW/DENY」，前面接上資源
    /principal=/ {
      s = $0
      sub(/^[ \t]*\(principal=/, "", s)
      sub(/\)[ \t]*$/, "", s)
      # lint-ok: awk 的正規表示式，| 是「或」，不是管線
      gsub(/, host=|, operation=|, permissionType=/, "|", s)
      print r "|" s
    }
  '
}
