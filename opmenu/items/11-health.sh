item 11 1 n n "cluster 與身分鏈健康檢查" "offline partition、under-replicated partition、各 broker 是否在線;MDS 各台狀態與延遲、你的 token 剩餘時間、controller quorum(有權限時)"
run() {
  echo "-- under-replicated partition(應為空):"; be_kafka kafka-topics --describe --under-replicated-partitions || return $?
  echo "-- offline partition(應為空):"; be_kafka kafka-topics --describe --unavailable-partitions || return $?
  echo "-- broker 在線清單:"; be_kafka kafka-broker-api-versions 2>&1 | grep -o -E '^[a-zA-Z0-9.-]+:[0-9]+ \(id: [0-9]+' | sort -u
  local u out code t rem n live
  echo "-- MDS(OPMENU_MDS_URL,逐台):"
  for u in ${OPMENU_MDS_URL//,/ }; do
    out=$(be_http -o /dev/null -w '%{http_code} %{time_total}' "$u/v1/metadata/id" 2>/dev/null) || out="連不上"
    code="${out%% *}"; printf '  %-40s %s\n' "$u" "$([ "$code" = 200 ] && echo "正常(${out##* }s)" || echo "異常($out)")"
  done
  t=$(( $(date +%s) - ${OP_TOKEN_AT:-$(date +%s)} )); rem=$(( ${OPMENU_TOKEN_TTL:-3600} - t ))
  echo "-- 你的 MDS token:已用 ${t}s,剩約 $([ $rem -gt 0 ] && echo "${rem}s" || echo "0s(已到期,請重新登入)")"
  n=$(printf '%s\n' $OPMENU_BROKER_SERVICES | wc -l)
  live=$(be_kafka kafka-broker-api-versions 2>/dev/null | grep -c '^[A-Za-z0-9._-]*:[0-9]* (id: ')
  echo "-- broker 在線:$live / $n(設定的 broker 數)$([ "$live" -lt "$n" ] && echo '  ← 有 broker 不在線')"
  echo "-- controller quorum(需要 ClusterAdmin):"
  out=$(be_kafka kafka-metadata-quorum describe --status 2>&1)
  if printf '%s' "$out" | grep -q -i 'AuthorizationException'; then echo "  (沒有權限,略過)"
  else printf '%s\n' "$out" | grep -E 'LeaderId|CurrentVoters|HighWatermark' | sed 's/^/  /'; fi
  echo "-- AD:登入時已通過 MDS 驗證,代表當時 MDS 到 AD 這段可用;之後若要重新確認請重新登入"
}
