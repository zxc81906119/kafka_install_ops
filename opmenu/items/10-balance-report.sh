run_10() {
  local out; out=$(be_kafka kafka-topics --describe | grep 'Partition:')
  [ -n "$out" ] || { echo "沒有讀到 partition(沒有權限或沒有 topic)"; return 1; }
  printf '%s\n' "$out" | awk '{
    for (i=1;i<=NF;i++) { if ($i=="Leader:") l=$(i+1); if ($i=="Replicas:") r=$(i+1) }
    np++; lead[l]++; n=split(r, a, ","); for (j=1;j<=n;j++) rep[a[j]]++; if (a[1]!=l) pref[a[1]]++; brokers[l]=1; for (j=1;j<=n;j++) brokers[a[j]]=1 }
    END { nb=0; for (b in brokers) { nb++; tl+=lead[b]; tr+=rep[b] }
      printf "partition 總數 %d,broker %d 台\n", np, nb
      printf "%-10s %8s %8s %12s %10s\n", "broker id", "leader", "replica", "非preferred", "leader偏離"
      n2=0; for (b in brokers) ids[++n2]=b
      for (x=1;x<=n2;x++) for (y=x+1;y<=n2;y++) if (ids[y]+0 < ids[x]+0) { t2=ids[x]; ids[x]=ids[y]; ids[y]=t2 }
      for (x=1;x<=n2;x++) { b=ids[x]; avg=tl/nb; dev=(avg>0)?(lead[b]-avg)/avg*100:0; printf "%-10s %8d %8d %12d %9.0f%%\n", b, lead[b], rep[b], pref[b], dev }
      printf "(非preferred = 這台是 preferred leader,但目前 leader 在別台;偏離 = leader 數相對平均的百分比)\n" }'
}
