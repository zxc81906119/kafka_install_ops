# 第二層:服務操作(需 ticket;需作業系統權限,由 backend 決定怎麼做,與 Kafka 的 RBAC 無關)
# 可重啟的服務清單在 opmenu.conf(OPMENU_BROKER_SERVICES、OPMENU_AUX_SERVICES);所有輸入先過 lib/validate.sh
_in_list() { local x; for x in $2; do [ "$x" = "$1" ] && return 0; done; return 1; }

reg 21 2 y y "重啟單一 broker" "一次只重啟一台;執行前檢查沒有 under-replicated 與 offline partition,否則拒絕"
act_21() {
  local svc="${1:-}"; [ -n "$svc" ] || { echo "可重啟的 broker:$OPMENU_BROKER_SERVICES"; read -r -p "要重啟的 broker: " svc; }
  v_broker_svc "$svc" || return 1
  local o rc urp off
  # 檢查本身失敗(沒權限、連不上叢集)時一律拒絕;原本用 "| grep -c" 會把失敗數成 0 而放行(2026-10-16 修正)
  o=$(be_kafka kafka-topics --describe --under-replicated-partitions 2>/dev/null); rc=$?
  [ $rc -eq 0 ] || { echo "無法檢查 under-replicated partition(權限不足或連不上叢集,rc=$rc),拒絕重啟"; return 1; }
  urp=$(grep -c "Partition:" <<< "$o")
  [ "$urp" = 0 ] || { echo "目前有 $urp 個 under-replicated partition,拒絕重啟(官方滾動重啟前提:先回到 0)"; return 1; }
  o=$(be_kafka kafka-topics --describe --unavailable-partitions 2>/dev/null); rc=$?
  [ $rc -eq 0 ] || { echo "無法檢查 offline partition(權限不足或連不上叢集,rc=$rc),拒絕重啟"; return 1; }
  off=$(grep -c "Partition:" <<< "$o")
  [ "$off" = 0 ] || { echo "目前有 $off 個 offline partition,拒絕重啟(先處理離線問題)"; return 1; }
  core_confirm "重啟 $svc(ticket $OP_TICKET);期間該台的 partition 會切換 leader" || return 1
  be_service_restart "$svc"
}

reg 22 2 y y "重啟 REST Proxy 或 C3" "影響經 REST Proxy 的 application 與管理介面的使用者"
act_22() {
  local svc="${1:-}"; [ -n "$svc" ] || { echo "可重啟的服務:$OPMENU_AUX_SERVICES"; read -r -p "要重啟的服務: " svc; }
  v_aux_svc "$svc" || return 1
  core_confirm "重啟 $svc(ticket $OP_TICKET)" || return 1
  be_service_restart "$svc"
}

reg 23 2 y n "查看服務日誌" "最近 N 行的錯誤與警告;會記錄誰看了哪台的日誌"
act_23() {
  local svc="${1:-}" n="${2:-50}"; [ -n "$svc" ] || { echo "服務:$OPMENU_BROKER_SERVICES $OPMENU_AUX_SERVICES"; read -r -p "服務: " svc; }
  v_any_svc "$svc" || return 1; v_number "$n" "行數" || return 1
  # 先取日誌與回傳碼再過濾:原本整條管線的結果是 tail 的,權限閘門拒絕或 ssh 失敗會被當成「沒有錯誤」而記 OK(2026-10-16 修正)
  local raw rc out
  raw=$(be_service_logs "$svc" "$n"); rc=$?
  [ $rc -eq 0 ] || { printf '%s\n' "$raw"; return $rc; }
  out=$(grep -i -E "ERROR|WARN" <<< "$raw" | tail -"$n"); printf '%s\n' "${out:-(最近 $n 行沒有錯誤或警告)}"
}

reg 24 2 y y "清理過期的應用程式日誌" "只刪超過 N 天的日誌檔,不碰 Kafka 的 data directory"
act_24() {
  local host="${1:-}" days="${2:-14}"; [ -n "$host" ] || { echo "node:$OPMENU_HOSTS"; read -r -p "node: " host; }
  v_host "$host" || return 1; v_number "$days" "天數" || return 1
  [ "$days" -ge "$OPMENU_MIN_LOG_KEEP_DAYS" ] || { echo "天數不可小於 $OPMENU_MIN_LOG_KEEP_DAYS"; return 1; }
  core_confirm "刪除 $host 上超過 $days 天的應用程式日誌(ticket $OP_TICKET)" || return 1
  be_clean_logs "$host" "$days"
}

# ── 批 B:維護模式(Alertmanager silence)。沒設 OPMENU_ALERTMANAGER_URL 就不出現這兩個項目 ──
if [ -n "${OPMENU_ALERTMANAGER_URL:-}" ]; then
_maint_list() { # 列出由 opmenu 建立、還在生效的 silence:id、建立者、到期時間
  be_am "$OPMENU_ALERTMANAGER_URL/api/v2/silences" | awk 'BEGIN{RS="\"id\":\""} NR>1 { id=substr($0,1,index($0,"\"")-1)
    if ($0 !~ /"state":"active"/ || $0 !~ /"createdBy":"opmenu:/) next
    match($0,/"createdBy":"[^"]*"/); by=substr($0,RSTART+13,RLENGTH-14); match($0,/"endsAt":"[^"]*"/); en=substr($0,RSTART+10,RLENGTH-11)
    printf "  %s  %s  到 %s\n", id, by, en }'
}
reg 25 2 y y "開始維護模式(Alertmanager silence)" "對指定 node 靜音告警一段時間(最長 OPMENU_MAINT_MAX_MIN 分鐘),重啟或維護前使用;記錄是誰、哪張 ticket"
act_25() {
  local host="${1:-}" mins="${2:-}"; [ -n "$host" ] || { echo "node:$OPMENU_HOSTS"; read -r -p "要靜音的 node: " host; }
  v_host "$host" || return 1
  [ -n "$mins" ] || read -r -p "分鐘數(1 到 $OPMENU_MAINT_MAX_MIN): " mins
  v_number "$mins" "分鐘數" || return 1
  [ "$mins" -ge 1 ] && [ "$mins" -le "$OPMENU_MAINT_MAX_MIN" ] || { echo "分鐘數必須在 1 到 $OPMENU_MAINT_MAX_MIN 之間"; return 1; }
  core_confirm "靜音 $host 的告警 $mins 分鐘(ticket $OP_TICKET)" || return 1
  local end body out id
  end=$(date -u -d "+$mins minutes" +%Y-%m-%dT%H:%M:%SZ)
  body=$(printf '{"matchers":[{"name":"%s","value":"^%s(:[0-9]+)?$","isRegex":true,"isEqual":true}],"startsAt":"%s","endsAt":"%s","createdBy":"opmenu:%s","comment":"ticket %s via opmenu"}' \
    "$OPMENU_MAINT_LABEL" "${host//./\\.}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$end" "$OP_USER" "$OP_TICKET")
  out=$(be_am -X POST -H 'Content-Type: application/json' -d "$body" "$OPMENU_ALERTMANAGER_URL/api/v2/silences")
  id=$(printf '%s' "$out" | grep -o '"silenceID":"[^"]*"' | cut -d'"' -f4)
  [ -n "$id" ] || { echo "建立 silence 失敗:$out"; return 1; }
  echo "維護模式已開始:$host,到 $end(UTC);silence id=$id(用項目 26 提前結束)"
}

reg 26 2 y n "結束維護模式" "提前結束由 opmenu 建立的 silence;只能結束 createdBy 是 opmenu 的"
act_26() {
  local id="${1:-}"
  if [ -z "$id" ]; then echo "目前生效中(由 opmenu 建立):"; _maint_list; read -r -p "要結束的 silence id: " id; fi
  v_match "$id" '^[0-9a-f-]{36}$' "silence id" || return 1
  be_am "$OPMENU_ALERTMANAGER_URL/api/v2/silence/$id" | grep -q '"createdBy":"opmenu:' || { echo "找不到這個 silence,或它不是由 opmenu 建立的,不處理"; return 1; }
  local code; code=$(be_am -X DELETE -o /dev/null -w '%{http_code}' "$OPMENU_ALERTMANAGER_URL/api/v2/silence/$id")
  [ "$code" = 200 ] && echo "維護模式已結束:$id" || { echo "結束失敗(HTTP $code)"; return 1; }
}
fi

# ── 批 C:滾動重啟 ──
_cluster_counts() { # 印 "<under-replicated> <offline> <在線 broker 數>";工具失敗的欄位印 999(視為不健康)
  local o rc urp off live
  o=$(be_kafka kafka-topics --describe --under-replicated-partitions 2>/dev/null); rc=$?
  if [ $rc -eq 0 ]; then urp=$(printf '%s
' "$o" | grep -c "Partition:"); else urp=999; fi   # grep -c 計數為 0 時回傳 1,所以不能寫成 [ ] && x=$(grep -c) || x=999
  o=$(be_kafka kafka-topics --describe --unavailable-partitions 2>/dev/null); rc=$?
  if [ $rc -eq 0 ]; then off=$(printf '%s
' "$o" | grep -c "Partition:"); else off=999; fi
  o=$(be_kafka kafka-broker-api-versions 2>/dev/null); rc=$?
  if [ $rc -eq 0 ]; then live=$(printf '%s
' "$o" | grep -c '^[A-Za-z0-9._-]*:[0-9]* (id: '); else live=0; fi
  echo "$urp $off $live"
}
reg 27 2 y y "滾動重啟所有 broker" "依 OPMENU_BROKER_SERVICES 的順序一台一台重啟;每台重啟後等全部 broker 在線且 under-replicated、offline 回到 0 才換下一台;任何一步失敗就停止。不含 controller"
act_27() {
  local svcs=($OPMENU_BROKER_SERVICES) n urp off live; n=${#svcs[@]}
  [ "$n" -ge 2 ] || { echo "只有 $n 台 broker,滾動重啟沒有意義(重啟就是中斷服務),請改用項目 21"; return 1; }
  read -r urp off live <<<"$(_cluster_counts)"
  { [ "$urp" = 0 ] && [ "$off" = 0 ] && [ "$live" = "$n" ]; } || { echo "cluster 目前不健康(under-replicated=$urp offline=$off 在線 broker=$live/$n),拒絕開始"; return 1; }
  core_confirm "依序重啟 ${svcs[*]}(共 $n 台,每台等 cluster 恢復才換下一台;ticket $OP_TICKET)" || return 1
  local s i=0 waited ok
  for s in "${svcs[@]}"; do
    i=$((i+1)); echo "== [$i/$n] 重啟 $s"; core_log STEP "27 滾動重啟" "$s 開始"
    be_service_restart "$s" || { echo "重啟 $s 失敗,停止(後面的 broker 沒有動)"; core_log STEP "27 滾動重啟" "$s 失敗"; return 1; }
    echo "  先等 ${OPMENU_ROLLING_SETTLE}s(讓 broker 被判定離線、ISR 縮減,避免剛重啟時誤判健康)"; sleep "$OPMENU_ROLLING_SETTLE"
    waited=0; ok=0; good=0
    while [ "$waited" -lt "$OPMENU_ROLLING_TIMEOUT" ]; do
      read -r urp off live <<<"$(_cluster_counts)"
      if [ "$urp" = 0 ] && [ "$off" = 0 ] && [ "$live" = "$n" ]; then good=$((good+1)); [ "$good" -ge "$OPMENU_ROLLING_STABLE" ] && { ok=1; break; }; else good=0; fi
      sleep 10; waited=$((waited+10))
      echo "  等待 cluster 恢復…(${waited}s;under-replicated=$urp offline=$off 在線 $live/$n;連續健康 $good/$OPMENU_ROLLING_STABLE)"
    done
    [ $ok = 1 ] || { echo "超過 ${OPMENU_ROLLING_TIMEOUT}s cluster 沒有恢復,停止(不再重啟下一台)"; core_log STEP "27 滾動重啟" "$s 後逾時"; return 1; }
    echo "  $s 已回到 cluster,under-replicated 與 offline 都是 0"; core_log STEP "27 滾動重啟" "$s 完成"
  done
  echo "全部 $n 台 broker 已完成滾動重啟"
}
