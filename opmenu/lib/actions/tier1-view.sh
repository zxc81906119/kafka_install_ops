# 第一層:值班查看(唯讀,不需 ticket)。每個項目只用 be_* 介面與操作者身分,不碰環境細節。

_identity_chain() {
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

reg 10 1 n n "查看 leader 與 partition 分布(balance report)" "每台 broker 的 leader 數、replica 數、preferred leader 偏離;只算你看得到的 topic(需要能 describe,例如 ClusterAdmin)"
act_10() {
  local out; out=$(be_kafka kafka-topics --describe | grep 'Partition:')
  [ -n "$out" ] || { echo "沒有讀到 partition(沒有權限或沒有 topic)"; return 1; }
  printf '%s\n' "$out" | awk '{
    for (i=1;i<=NF;i++) { if ($i=="Leader:") l=$(i+1); if ($i=="Replicas:") r=$(i+1) }
    np++; lead[l]++; n=split(r, a, ","); for (j=1;j<=n;j++) rep[a[j]]++; if (a[1]!=l) pref[a[1]]++; brokers[l]=1; for (j=1;j<=n;j++) brokers[a[j]]=1 }
    END { nb=0; for (b in brokers) { nb++; tl+=lead[b]; tr+=rep[b] }
      printf "partition 總數 %d,broker %d 台\n", np, nb
      printf "%-10s %8s %8s %12s %10s\n", "broker id", "leader", "replica", "非preferred", "leader偏離"
      n2=0; for (b in brokers) ids[++n2]=b
      for (x=1;x<=n2;x++) for (y=x+1;y<=n2;y++) if (ids[y]+0 < ids[x]+0) { t2=ids[x]; ids[x]=ids[y]; ids[y]=t2 }   # broker id 由小到大
      for (x=1;x<=n2;x++) { b=ids[x]; avg=tl/nb; dev=(avg>0)?(lead[b]-avg)/avg*100:0; printf "%-10s %8d %8d %12d %9.0f%%\n", b, lead[b], rep[b], pref[b], dev }
      printf "(非preferred = 這台是 preferred leader,但目前 leader 在別台;偏離 = leader 數相對平均的百分比)\n" }'
}

reg 11 1 n n "cluster 與身分鏈健康檢查" "offline partition、under-replicated partition、各 broker 是否在線;MDS 各台狀態與延遲、你的 token 剩餘時間、controller quorum(有權限時)"
act_11() {
  echo "-- under-replicated partition(應為空):"; be_kafka kafka-topics --describe --under-replicated-partitions || return $?
  echo "-- offline partition(應為空):"; be_kafka kafka-topics --describe --unavailable-partitions || return $?
  echo "-- broker 在線清單:"; be_kafka kafka-broker-api-versions 2>&1 | grep -o -E '^[a-zA-Z0-9.-]+:[0-9]+ \(id: [0-9]+' | sort -u
  _identity_chain
}

reg 12 1 n n "列出 topic 與 partition 狀態" "只會看到你有權限的 topic"
act_12() { be_kafka kafka-topics --describe | grep -E "^Topic:|Partition:" | sed -E 's/\s+/ /g'; }

reg 13 1 n n "查看 consumer lag" "直接按 Enter 查全部(只會看到你有權限的);或輸入名稱 prefix、完整名稱"
act_13() {
  local g="${1:-}"; [ -n "$g" ] || [ $# -ge 1 ] || read -r -p "consumer group(空 = 全部;可輸入 prefix): " g
  [ -z "$g" ] || v_group "$g" || return 1
  local args=()
  if [ -z "$g" ]; then args=(--all-groups)
  else
    local list; list=$(be_kafka kafka-consumer-groups --list 2>/dev/null | grep -v '^_' | grep "^${g//./\.}")   # prefix 比對;名稱裡的 . 已跳脫
    [ -n "$list" ] || { echo "沒有名稱以 $g 開頭的 consumer group(或你沒有權限)"; return 1; }
    local x; for x in $list; do args+=(--group "$x"); done
  fi
  be_kafka kafka-consumer-groups --describe "${args[@]}" | awk '
    $1=="GROUP" { next }
    NF>=6 && $6 ~ /^[0-9-]+$/ { printf "1\t%-30s %-30s %4s  lag %s\n", $1, $2, $3, $6; if ($6 ~ /^[0-9]+$/) tot[$1]+=$6; else tot[$1]+=0 }
    END { for (g in tot) printf "2\t== %-30s 合計 lag %d\n", g, tot[g] }' | sort | cut -f2-   # 1 = 明細、2 = 合計,排序後明細在前
}

reg 14 1 n n "查看某個 topic 的設定" "retention、partition count、replication factor"
act_14() { local t="${1:-}"; [ -n "$t" ] || read -r -p "topic 名稱: " t; v_topic_ro "$t" || return 1; be_kafka kafka-configs --describe --entity-type topics --entity-name "$t" --all | grep -E "retention.ms|cleanup.policy|min.insync.replicas" | sed -E 's/\s+sensitive=.*//'; be_kafka kafka-topics --describe --topic "$t" | head -1; }

reg 15 1 n n "查看 application 連線狀況" "在線的 consumer group 與成員數"
act_15() { be_kafka kafka-consumer-groups --list | grep -v '^_' | while read -r g; do [ -n "$g" ] || continue; printf '%-30s %s\n' "$g" "$(be_kafka kafka-consumer-groups --describe --group "$g" --members 2>/dev/null | grep -c -E '^[^ ]+ +[^ ]+ +/')個成員"; done; }

reg 16 1 n n "查看磁碟與 data directory 用量" "各 node Kafka data directory"
act_16() { be_disk_usage; }

reg 17 1 n n "查看 certificate 到期日" "共用 server certificate、各 client certificate、CA"
act_17() { be_cert_list; }

reg 18 1 n n "收集 diagnostics" "把各 node 最近的日誌與 cluster 狀態打包,交給二線或原廠"
act_18() {
  local d="$OPMENU_OUT_DIR/diag-$(date +%Y%m%d-%H%M%S)-$OP_USER"
  be_collect_diag "$d" || return $?
  be_kafka kafka-topics --describe > "$d/topics.txt" 2>&1
  be_kafka kafka-consumer-groups --list > "$d/consumer-groups.txt" 2>&1
  be_disk_usage > "$d/disk.txt" 2>&1
  tar -C "$(dirname "$d")" -czf "$d.tgz" "$(basename "$d")" && rm -rf "$d"
  echo "已打包:$d.tgz($(du -h "$d.tgz" | cut -f1))"
}

reg 19 1 n n "查看生效中的設定(effective configuration)" "每個值的來源:conf = opmenu.conf、derived = 自動推算、default = 預設"
act_19() {
  local n v
  for n in BACKEND ENV_LABEL BOOTSTRAP MDS_URL KAFKA_CLUSTER_ID CERT_DIR TRUSTSTORE CA_PEM CONTROLLER_HOSTS BROKER_SERVICES AUX_SERVICES HOSTS DATA_DIR REPLICATION SSH_AUTH TICKET_MODE; do
    v="OPMENU_$n"; printf '%-20s %-9s %s\n' "$n" "${OP_SRC[$v]:-default}" "${!v:-(empty)}"
  done
}


