item 44 4 n n "匯出權限清單(permission review)" "列出各 role 的所有 principal 與資源範圍(CSV),交給定期權限覆核;需 SecurityAdmin 或 UserAdmin"
run() {
  local f="$OPMENU_OUT_DIR/permission-review-$(date +%Y%m%d-%H%M%S)-$OP_USER.csv" role p res code body rb arr o n=0 rt rn pt
  echo "role,principal,resource_type,resource_name,pattern_type" > "$f"
  for role in $OPMENU_REVIEW_ROLES; do
    v_match "$role" '^[A-Za-z]+$' "role 名稱" >/dev/null || continue
    res=$(be_mds POST "/security/1.0/lookup/role/$role" "$(k_scope)"); code="${res##*HTTP }"; body="${res%$'\n'HTTP*}"
    [ "$code" = 200 ] || { echo "查詢 role $role 失敗(HTTP $code);需要 SecurityAdmin 或 UserAdmin"; rm -f "$f"; return 1; }
    for p in $(printf '%s' "$body" | grep -o '"[A-Za-z]*:[^"]*"' | tr -d '"'); do
      v_principal "$p" >/dev/null || continue
      rb=$(be_mds POST "/security/1.0/lookup/rolebindings/principal/$p" "$(k_scope)" | sed '$d')
      arr=$(printf '%s' "$rb" | sed -n 's/.*"'"$role"'":\[\([^]]*\)\].*/\1/p')
      if [ -z "$arr" ]; then printf '"%s","%s","Cluster","",""\n' "$role" "$p" >> "$f"; n=$((n+1))
      else
        while IFS= read -r o; do
          rt=$(printf '%s' "$o" | grep -o '"resourceType":"[^"]*"' | cut -d'"' -f4); rn=$(printf '%s' "$o" | grep -o '"name":"[^"]*"' | cut -d'"' -f4); pt=$(printf '%s' "$o" | grep -o '"patternType":"[^"]*"' | cut -d'"' -f4)
          printf '"%s","%s","%s","%s","%s"\n' "$role" "$p" "$rt" "$rn" "$pt" >> "$f"; n=$((n+1))
        done < <(printf '%s' "$arr" | sed 's/},{/}\n{/g')
      fi
    done
  done
  echo "已匯出 $n 筆權限:$f"
}
