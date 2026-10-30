item 44 4 n n "匯出權限清單(permission review)/變更前快照" "列出各 role 的所有 principal 與資源範圍(CSV),交給定期權限覆核;加 snapshot 再匯出 topic、設定、帳號與配額、ACL、role binding、features(變更前快照,檔名與格式同每日備份,可直接用手把手 23.6、26.4 還原);需 SecurityAdmin 或 UserAdmin"
# 把權限清單寫成 CSV;回傳寫了幾筆(印在 stdout 最後一行)
review_csv() {
  local f="$1" role p res code body rb arr o n=0 rt rn pt
  echo "role,principal,resource_type,resource_name,pattern_type" > "$f"
  for role in $OPMENU_REVIEW_ROLES; do
    v_match "$role" '^[A-Za-z]+$' "role 名稱" >/dev/null || continue
    res=$(be_mds POST "/security/1.0/lookup/role/$role" "$(k_scope)"); code="${res##*HTTP }"; body="${res%$'\n'HTTP*}"
    [ "$code" = 200 ] || { echo "查詢 role $role 失敗(HTTP $code);需要 SecurityAdmin 或 UserAdmin"; return 1; }
    for p in $(printf '%s' "$body" | grep -o '"[A-Za-z]*:[^"]*"' | tr -d '"'); do
      v_principal "$p" >/dev/null || continue
      rb=$(be_mds POST "/security/1.0/lookup/rolebindings/principal/$p" "$(k_scope)" | sed '$d')
      arr=$(printf '%s' "$rb" | sed -n 's/.*"'"$role"'":\[\([^]]*\)\].*/\1/p')
      if [ -z "$arr" ]; then printf '"%s","%s","Cluster","",""\n' "$role" "$p" >> "$f"; n=$((n+1))
      else
        while IFS= read -r o; do
          rt=$(printf '%s' "$o" | grep -o '"resourceType":"[^"]*"' | cut -d'"' -f4); rn=$(printf '%s' "$o" | grep -o '"name":"[^"]*"' | cut -d'"' -f4); pt=$(printf '%s' "$o" | grep -o '"patternType":"[^"]*"' | cut -d'"' -f4)
          printf '"%s","%s","%s","%s","%s"\n' "$role" "$p" "$rt" "$rn" "$pt" >> "$f"; n=$((n+1))
        done < <(printf '%s\n' "$arr" | sed 's/},{/}\n{/g')   # 結尾要有換行,否則最後一筆 read 讀不到
      fi
    done
  done
  echo "$n"
}
# 快照的 rbac.txt,格式同每日備份(手把手 23.3):每個 principal 一段「== <principal>」,底下每條 binding 一行 principal|role|資源類型|名稱|比對方式(排序)。
# principal 取自 MDS 的每一種 role(不只 OPMENU_REVIEW_ROLES),和每日備份用 confluent CLI 列出的是同一批
snapshot_rbac() {
  local roles r p body pair role arr o
  roles=$(be_mds GET /security/1.0/roles | sed '$d' | grep -o '"name":"[A-Za-z]*"' | cut -d'"' -f4); [ -n "$roles" ] || return 1
  for p in $(for r in $roles; do be_mds POST "/security/1.0/lookup/role/$r" "$(k_scope)" | sed '$d' | grep -o '"[A-Za-z]*:[^"]*"' | tr -d '"'; done | LC_ALL=C sort -u); do
    v_principal "$p" >/dev/null || continue
    echo "== $p"
    body=$(be_mds POST "/security/1.0/lookup/rolebindings/principal/$p" "$(k_scope)" | sed '$d')
    while IFS= read -r pair; do   # pair = "<role>":[<資源>,…];叢集層級的 binding 是空陣列
      role=$(printf '%s' "$pair" | cut -d'"' -f2); arr=$(printf '%s' "$pair" | sed 's/^"[A-Za-z]*":\[//; s/\]$//')
      if [ -z "$arr" ]; then echo "$p|$role|Cluster||"; continue; fi
      while IFS= read -r o; do
        printf '%s|%s|%s|%s|%s\n' "$p" "$role" "$(printf '%s' "$o" | grep -o '"resourceType":"[^"]*"' | cut -d'"' -f4)" \
          "$(printf '%s' "$o" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)" "$(printf '%s' "$o" | grep -o '"patternType":"[^"]*"' | cut -d'"' -f4)"
      done < <(printf '%s\n' "$arr" | sed 's/},{/}\n{/g')
    done < <(printf '%s' "$body" | grep -o '"[A-Za-z]*":\[[^]]*\]') | LC_ALL=C sort
  done
}
run() {
  local mode="${1:-}" c f d n failed=""
  if [ -z "$mode" ] && [ -t 0 ]; then read -r -p "1) 只匯出權限清單 CSV  2) 變更前完整快照 [1]: " c; [ "$c" = 2 ] && mode=snapshot; fi
  if [ "$mode" != snapshot ]; then
    f="$OPMENU_OUT_DIR/permission-review-$(date +%Y%m%d-%H%M%S)-$OP_USER.csv"
    n=$(review_csv "$f" | tail -1); [[ "$n" =~ ^[0-9]+$ ]] || { echo "$n"; rm -f "$f"; return 1; }
    echo "已匯出 $n 筆權限:$f"; return 0
  fi
  # 變更前快照:檔名與內容和每日備份(手把手 23.3)一樣,sha256 可直接比對;features 的 Epoch 拿掉、ACL 一條一行、清單一律 LC_ALL=C 排序
  d="$OPMENU_OUT_DIR/snapshot-$(date +%Y%m%d-%H%M%S)-$OP_USER"; mkdir -p "$d" && chmod 0750 "$d" || return 1
  n=$(review_csv "$d/permission-review.csv" | tail -1); [[ "$n" =~ ^[0-9]+$ ]] || failed="$failed permission-review.csv"
  be_kafka kafka-topics --describe > "$d/topics.txt" || failed="$failed topics.txt"
  be_kafka kafka-configs --describe --entity-type topics > "$d/topic-configs.txt" || failed="$failed topic-configs.txt"
  be_kafka kafka-configs --describe --entity-type users | LC_ALL=C sort > "$d/users.txt" || failed="$failed users.txt"
  be_kafka kafka-configs --describe --entity-type brokers --entity-default > "$d/broker-configs.txt" || failed="$failed broker-configs.txt"
  # ACL 一條一行:資源類型|名稱|比對方式|principal|host|操作|ALLOW/DENY
  be_kafka kafka-acls --list | awk '/^Current ACLs for resource/{s=$0; sub(/.*resourceType=/,"",s); sub(/\)`:.*/,"",s); gsub(/, name=|, patternType=/,"|",s); r=s; next} /principal=/{s=$0; sub(/^[ \t]*\(principal=/,"",s); sub(/\)[ \t]*$/,"",s); gsub(/, host=|, operation=|, permissionType=/,"|",s); print r"|"s}' | LC_ALL=C sort > "$d/acls.txt" || failed="$failed acls.txt"
  snapshot_rbac > "$d/rbac.txt" || failed="$failed rbac.txt"
  be_kafka kafka-features describe | sed 's/[[:space:]]*Epoch: [0-9]*//' > "$d/features.txt" || failed="$failed features.txt"
  for f in "$d"/*.txt; do [ -s "$f" ] || failed="$failed $(basename "$f")(空的)"; done   # 接 sort 的那幾項,前段失敗會被 sort 的結束碼遮住
  (cd "$d" && sha256sum -- *.txt *.csv > SHA256SUMS)
  [ -z "$failed" ] || { echo "快照有失敗的項目:$failed(目錄 $d)"; return 1; }
  echo "已匯出變更前快照($n 筆權限,$(ls "$d" | grep -c '\.txt$') 個清單):$d"
}
