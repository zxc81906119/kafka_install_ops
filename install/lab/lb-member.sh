#!/usr/bin/env bash
# lb-member.sh <rest01|rest02> down|up|status —— lab：扮演 LB 團隊停用／恢復一台 REST Proxy
# 正式環境是 LB 團隊在行內的負載平衡設備上停用／啟用 pool member。nginx：server 後面加 down 再 reload，進行中的連線讓它跑完
h=$1 act=${2:-status}; f=/etc/nginx/stream.d/cp.conf
case $act in
  down) e="/server $h.poc.lab:8082 /{/ down;/!s/;\$/ down;/}";;
  up)   e="/server $h.poc.lab:8082 /s/ down;/;/";;
  status) e="";;
  *) echo "用法：$0 <rest01|rest02> down|up|status"; exit 2;;
esac
MSYS_NO_PATHCONV=1 docker exec lab-lb01-1 sh -c "{ [ -z '$e' ] || { sed -i '$e' $f && nginx -t -q && nginx -s reload 2>/dev/null; }; } && sleep 1 && echo \"LB：\$(grep -oE 'server rest0[12][^;]*' $f | sed -E 's/\.poc\.lab:8082 max_fails=2 fail_timeout=10s//; s/server //; s/ down/（停用）/' | paste -sd' ' -)\""
